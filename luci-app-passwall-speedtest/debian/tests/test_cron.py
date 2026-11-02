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


class ListTasksTests(unittest.TestCase):
    def _snapshot(self, text, files=None, which="/usr/bin/crontab"):
        with mock.patch.object(cron, "_read_crontab", return_value=text), \
                mock.patch.object(cron, "_read_file", return_value=""), \
                mock.patch.object(cron, "_list_files", return_value=files or []), \
                mock.patch.object(cron, "_current_user", return_value="root"), \
                mock.patch.object(cron.shutil, "which", return_value=which):
            return cron.list_tasks()

    def test_managed_block(self):
        text = (cron.BEGIN + "\n"
                "0 3 * * * /usr/local/bin/cfpick run start >/dev/null 2>&1\n"
                + cron.END + "\n")
        data = self._snapshot(text)
        self.assertTrue(data["installed"])
        self.assertEqual(data["managed"],
                         {"enabled": True,
                          "line": "0 3 * * * /usr/local/bin/cfpick run start "
                                  ">/dev/null 2>&1"})
        self.assertEqual(len(data["entries"]), 1)
        self.assertTrue(data["entries"][0]["managed"])
        self.assertEqual(data["entries"][0]["source"], "root")
        self.assertEqual(data["errors"], [])

    def test_empty_crontab(self):
        data = self._snapshot("")
        self.assertTrue(data["installed"])
        self.assertFalse(data["managed"]["enabled"])
        self.assertEqual(data["managed"]["line"], "")
        self.assertEqual(data["entries"], [])

    def test_missing_crontab_reports_error(self):
        with mock.patch.object(cron, "_read_crontab",
                               side_effect=cron.CronError("未安装 crontab")), \
                mock.patch.object(cron, "_read_file", return_value=""), \
                mock.patch.object(cron, "_list_files", return_value=[]), \
                mock.patch.object(cron, "_current_user", return_value="root"), \
                mock.patch.object(cron.shutil, "which", return_value=None):
            data = cron.list_tasks()
        self.assertFalse(data["installed"])
        self.assertFalse(data["managed"]["enabled"])
        self.assertIn("未安装 crontab", data["errors"][0])


if __name__ == "__main__":
    unittest.main()
