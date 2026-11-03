"""Parsing and read-only listing of crontabs."""

import unittest
from unittest import mock

from cfpick import cron
SAMPLE = """\
# comment line
SHELL=/bin/sh

# >>> cfpick >>>
0 */24 * * * /usr/local/bin/cfpick run start >/dev/null 2>&1
# <<< cfpick <<<

@reboot /usr/bin/warmup --flag value
0 3 * * 4 echo weekly
"""


class ParseTextTests(unittest.TestCase):
    def test_kinds_markers_and_schedule(self):
        entries = cron.parse_text(SAMPLE, "root", managed=True)
        self.assertEqual([entry["kind"] for entry in entries],
                         ["comment", "env", "cron", "cron", "cron"])
        # Marker lines themselves are not tasks.
        self.assertNotIn(cron.BEGIN, [entry["line"] for entry in entries])
        self.assertNotIn(cron.END, [entry["line"] for entry in entries])

        managed = [entry for entry in entries if entry["managed"]]
        self.assertEqual(len(managed), 1)
        self.assertEqual(managed[0]["schedule"], "0 */24 * * *")
        self.assertEqual(managed[0]["command"],
                         "/usr/local/bin/cfpick run start >/dev/null 2>&1")

        reboot = entries[3]
        self.assertEqual((reboot["schedule"], reboot["command"]),
                         ("@reboot", "/usr/bin/warmup --flag value"))
        weekly = entries[4]
        self.assertEqual((weekly["schedule"], weekly["command"]),
                         ("0 3 * * 4", "echo weekly"))

    def test_non_managed_source_marks_nothing(self):
        entries = cron.parse_text(SAMPLE, "/etc/crontab")
        self.assertFalse(any(entry["managed"] for entry in entries))

    def test_comment_and_env_keep_raw_text(self):
        entries = cron.parse_text(SAMPLE, "root")
        self.assertEqual(entries[0]["command"], "# comment line")
        self.assertEqual(entries[1]["command"], "SHELL=/bin/sh")
        self.assertEqual(entries[0]["schedule"], "")

    def test_short_line_has_no_command(self):
        self.assertEqual(cron.split_line("0 3 * * *"), ("0 3 * * *", ""))
        self.assertEqual(cron.split_line(""), ("", ""))


class BuildLineTests(unittest.TestCase):
    def test_custom_expression(self):
        with mock.patch.object(cron, "cli_command", return_value="/usr/local/bin/cfpick"):
            line = cron.build_line({
                "custom_enabled": True,
                "custom_cron": "15 4 * * 1",
            })
        self.assertEqual(line,
                         "15 4 * * 1 /usr/local/bin/cfpick run start >/dev/null 2>&1")

    def test_legacy_hour_interval(self):
        with mock.patch.object(cron, "cli_command", return_value="/usr/local/bin/cfpick"):
            line = cron.build_line({"custom_enabled": False, "hour": 6})
        self.assertEqual(line,
                         "0 */6 * * * /usr/local/bin/cfpick run start >/dev/null 2>&1")

    def test_main_task_always_runs_every_node(self):
        # Only the extra tasks can select nodes; the managed start line never
        # carries --node flags.
        with mock.patch.object(cron, "cli_command", return_value="/usr/local/bin/cfpick"):
            line = cron.build_line({
                "custom_enabled": True,
                "custom_cron": "0 3 * * *",
                "nodes": ["jp 01", "hk"],
            })
        self.assertEqual(
            line,
            "0 3 * * * /usr/local/bin/cfpick run start >/dev/null 2>&1")

    def test_parse_node_flags(self):
        entry = cron.parse_task(
            "0 3 * * * /usr/local/bin/cfpick run start "
            "--node=jp%2001 --node=hk >/dev/null 2>&1", "root")
        self.assertEqual(entry["nodes"], ["jp 01", "hk"])

    def test_command_nodes_accepts_space_form(self):
        self.assertEqual(
            cron.command_nodes("/x/cfpick run retest --node 'jp 01' --node=hk"),
            ["jp 01", "hk"])
        self.assertEqual(cron.command_nodes("/x/cfpick run retest"), [])


class ListTasksTests(unittest.TestCase):
    def _snapshot(self, text, files=None, which="/usr/bin/crontab"):
        with mock.patch.object(cron, "_read_crontab", return_value=text), \
                mock.patch.object(cron, "_read_file", return_value=""), \
                mock.patch.object(cron, "_list_files", return_value=files or []), \
                mock.patch.object(cron, "_current_user", return_value="root"), \
                mock.patch.object(cron, "_disabled", return_value=False), \
                mock.patch.object(cron.shutil, "which", return_value=which):
            return cron.list_tasks()

    def test_legacy_block_lists_as_normal_tasks(self):
        text = (cron.BEGIN + "\n"
                "0 3 * * * /usr/local/bin/cfpick run start >/dev/null 2>&1\n"
                + cron.END + "\n")
        data = self._snapshot(text)
        self.assertTrue(data["installed"])
        self.assertNotIn("managed", data)
        self.assertEqual(len(data["entries"]), 1)
        self.assertEqual(data["entries"][0]["source"], "root")
        self.assertEqual(data["errors"], [])
        self.assertTrue(data["writable"])
        self.assertTrue(data["run_command"].endswith(" run"))
        self.assertEqual(len(data["tasks"]), 1)
        self.assertEqual(data["tasks"][0]["schedule"], "0 3 * * *")
        self.assertNotIn("managed", data["tasks"][0])

    def test_empty_crontab(self):
        data = self._snapshot("")
        self.assertTrue(data["installed"])
        self.assertEqual(data["entries"], [])
        self.assertEqual(data["tasks"], [])

    def test_missing_crontab_reports_error(self):
        with mock.patch.object(cron, "_read_crontab",
                               side_effect=cron.CronError("未安装 crontab")), \
                mock.patch.object(cron, "_read_file", return_value=""), \
                mock.patch.object(cron, "_list_files", return_value=[]), \
                mock.patch.object(cron, "_current_user", return_value="root"), \
                mock.patch.object(cron.shutil, "which", return_value=None):
            data = cron.list_tasks()
        self.assertFalse(data["installed"])
        self.assertEqual(data["tasks"], [])
        self.assertIn("未安装 crontab", data["errors"][0])


class TaskModelTests(unittest.TestCase):
    def test_schedule_validation(self):
        self.assertTrue(cron.valid_schedule("0 3 * * *"))
        self.assertTrue(cron.valid_schedule("@reboot"))
        self.assertTrue(cron.valid_schedule("０ １２ * * *"))
        self.assertFalse(cron.valid_schedule("0 3 * *"))
        self.assertFalse(cron.valid_schedule("0 3 * * * *"))

    def test_parse_task(self):
        entry = cron.parse_task(
            cron.DISABLED_PREFIX + "0 3 * * * /usr/local/bin/cfpick run retest",
            "root", writable=True)
        self.assertTrue(entry["related"])
        self.assertTrue(entry["disabled"])
        self.assertTrue(entry["writable"])
        self.assertEqual(entry["schedule"], "0 3 * * *")
        self.assertEqual(entry["command"], "/usr/local/bin/cfpick run retest")
        self.assertFalse(cron.parse_task("0 3 * * * echo hi", "root")["related"])
        self.assertIsNone(cron.parse_task("# plain comment", "root"))
        self.assertIsNone(cron.parse_task("SHELL=/bin/sh", "root"))

    def test_collect_related_ignores_legacy_markers(self):
        text = "\n".join([
            cron.BEGIN,
            "0 3 * * * /usr/local/bin/cfpick run start >/dev/null 2>&1",
            cron.END,
            "0 4 * * * /usr/local/bin/cfpick run test",
            "0 5 * * * /usr/bin/other",
        ])
        tasks = cron._collect_related(text, "root", writable=True)
        self.assertEqual([task["command"] for task in tasks], [
            "/usr/local/bin/cfpick run start >/dev/null 2>&1",
            "/usr/local/bin/cfpick run test",
        ])
        self.assertTrue(all("managed" not in task for task in tasks))


class TaskWriteTests(unittest.TestCase):
    def setUp(self):
        self.lines = [
            cron.BEGIN,
            "0 3 * * * /usr/local/bin/cfpick run start >/dev/null 2>&1",
            cron.END,
            "0 4 * * * /usr/local/bin/cfpick run retest",
            "0 5 * * * /usr/bin/other",
        ]
        self.written = ""

    def _text(self):
        return "\n".join(self.lines) + "\n"

    def _write(self, text):
        self.written = text

    def _patches(self):
        return (
            mock.patch.multiple(
                cron,
                _read_crontab=mock.Mock(return_value=self._text()),
                _write_crontab=mock.Mock(side_effect=self._write),
                _disabled=mock.Mock(return_value=False),
                _current_user=mock.Mock(return_value="root"),
            ),
            mock.patch.object(cron.shutil, "which", return_value="/usr/bin/crontab"),
        )

    def test_save_updates_schedule_and_mode(self):
        first, second = self._patches()
        with first, second:
            cron.save_task(self.lines[3], "@daily", enabled=True, mode="test")
        self.assertIn("@daily /usr/local/bin/cfpick run test", self.written)
        self.assertNotIn("0 4 * * * /usr/local/bin/cfpick run retest",
                         self.written.splitlines())

    def test_save_disables_task(self):
        first, second = self._patches()
        with first, second:
            cron.save_task(self.lines[3], "0 4 * * *", enabled=False)
        self.assertIn(cron.DISABLED_PREFIX +
                      "0 4 * * * /usr/local/bin/cfpick run retest",
                      self.written.splitlines())

    def test_save_updates_legacy_block_line(self):
        first, second = self._patches()
        with first, second:
            cron.save_task(self.lines[1], "0 4 * * *", enabled=True)
        self.assertIn(
            "0 4 * * * /usr/local/bin/cfpick run start >/dev/null 2>&1",
            self.written.splitlines())

    def test_delete_removes_task(self):
        first, second = self._patches()
        with first, second:
            cron.delete_task(self.lines[3])
        self.assertNotIn(self.lines[3], self.written.splitlines())
        self.assertIn(self.lines[4], self.written.splitlines())

    def test_add_appends_task(self):
        first, second = self._patches()
        with first, second:
            cron.add_task("15 6 * * *", "replace")
        self.assertTrue(self.written.rstrip().endswith(
            "15 6 * * * %s run replace" % cron.cli_command()))

    def test_add_appends_start_task(self):
        # The panel offers start for every added task, so the crontab manager
        # must accept it alongside retest/test/replace.
        first, second = self._patches()
        with first, second:
            cron.add_task("0 */6 * * *", "start")
        self.assertTrue(self.written.rstrip().endswith(
            "0 */6 * * * %s run start" % cron.cli_command()))

    def test_save_switches_task_to_start(self):
        first, second = self._patches()
        with first, second:
            cron.save_task(self.lines[3], "0 4 * * *", enabled=True,
                           mode="start")
        self.assertIn("0 4 * * * /usr/local/bin/cfpick run start",
                      self.written.splitlines())

    def test_add_rejects_duplicate(self):
        self.lines.append("15 6 * * * %s run replace" % cron.cli_command())
        first, second = self._patches()
        with first, second, self.assertRaises(cron.CronError):
            cron.add_task("15 6 * * *", "replace")

    def test_invalid_schedule_rejected(self):
        first, second = self._patches()
        with first, second, self.assertRaises(cron.CronError):
            cron.add_task("0 3 * *", "retest")

    def test_add_with_nodes(self):
        first, second = self._patches()
        with first, second:
            cron.add_task("15 6 * * *", "retest", nodes=["jp 01", "hk"])
        self.assertTrue(self.written.rstrip().endswith(
            "15 6 * * * " + cron.cli_command() +
            " run retest --node=jp%2001 --node=hk"))

    def test_save_updates_nodes_and_keeps_redirection(self):
        self.lines[3] = ("0 4 * * * /usr/local/bin/cfpick run retest "
                         "--node=old >/dev/null 2>&1")
        first, second = self._patches()
        with first, second:
            cron.save_task(self.lines[3], "0 4 * * *", enabled=True,
                           nodes=["new", "other node"])
        self.assertIn("0 4 * * * /usr/local/bin/cfpick run retest "
                      "--node=new --node=other%20node >/dev/null 2>&1",
                      self.written.splitlines())

    def test_save_empty_nodes_clears_selection(self):
        self.lines[3] = ("0 4 * * * /usr/local/bin/cfpick run retest "
                         "--node=old >/dev/null 2>&1")
        first, second = self._patches()
        with first, second:
            cron.save_task(self.lines[3], "0 4 * * *", enabled=True, nodes=[])
        self.assertIn("0 4 * * * /usr/local/bin/cfpick run retest >/dev/null 2>&1",
                      self.written.splitlines())

    def test_prune_removes_one_deleted_node(self):
        self.lines[3] = ("0 4 * * * /usr/local/bin/cfpick run retest "
                         "--node=a --node=b >/dev/null 2>&1")
        first, second = self._patches()
        with first, second:
            report = cron.prune_nodes(["a"])
        self.assertEqual(report["removed"], ["a"])
        self.assertFalse(report["deleted"])
        self.assertIn("0 4 * * * /usr/local/bin/cfpick run retest --node=b >/dev/null 2>&1",
                      self.written.splitlines())

    def test_prune_deletes_task_when_selection_empties(self):
        self.lines[3] = "0 4 * * * /usr/local/bin/cfpick run retest --node=a"
        first, second = self._patches()
        with first, second:
            report = cron.prune_nodes(["a"])
        self.assertEqual(len(report["deleted"]), 1)
        self.assertNotIn(self.lines[3], self.written.splitlines())

    def test_prune_renames_node(self):
        self.lines[3] = "0 4 * * * /usr/local/bin/cfpick run retest --node=old"
        first, second = self._patches()
        with first, second:
            report = cron.prune_nodes(["old"], {"old": "new"})
        self.assertEqual(report["renamed"], ["old→new"])
        self.assertIn("0 4 * * * /usr/local/bin/cfpick run retest --node=new",
                      self.written.splitlines())

    def test_prune_updates_legacy_block_task(self):
        self.lines[1] = ("0 3 * * * /usr/local/bin/cfpick run start "
                         "--node=a --node=b >/dev/null 2>&1")
        first, second = self._patches()
        with first, second:
            report = cron.prune_nodes(["a"])
        self.assertEqual(report["removed"], ["a"])
        self.assertIn("0 3 * * * /usr/local/bin/cfpick run start "
                      "--node=b >/dev/null 2>&1", self.written.splitlines())


if __name__ == "__main__":
    unittest.main()
