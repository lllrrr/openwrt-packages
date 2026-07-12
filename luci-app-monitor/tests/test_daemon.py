import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / "root/usr/libexec/internet-monitor/daemon"
FUNCTIONS = ROOT / "tests/fixtures/functions.sh"
FIXTURE_BIN = ROOT / "tests/fixtures/bin"


class DaemonStateMachineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = Path(self.temp.name, "runtime")
        self.persist = Path(self.temp.name, "persist")
        self.env = os.environ.copy()
        self.env.update(
            {
                "INTERNET_MONITOR_FUNCTIONS_LIB": str(FUNCTIONS),
                "INTERNET_MONITOR_RUNTIME_DIR": str(self.runtime),
                "INTERNET_MONITOR_PERSIST_DIR": str(self.persist),
                "PATH": f"{FIXTURE_BIN}:{self.env['PATH']}",
                "TEST_FAILURE_THRESHOLD": "3",
                "TEST_RECOVERY_THRESHOLD": "2",
                "TEST_QUORUM": "2",
            }
        )

    def run_probe(self, *, ping=True, http=True):
        env = self.env.copy()
        env["TEST_PING_OK"] = "1" if ping else "0"
        env["TEST_HTTP_OK"] = "1" if http else "0"
        result = subprocess.run(
            ["sh", str(DAEMON), "--once"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        fields = (self.runtime / "state.tsv").read_text(encoding="utf-8").rstrip("\n").split("\t")
        self.assertEqual(len(fields), 12)
        return fields

    def event_lines(self):
        lines = []
        for path in (
            self.persist / "events.tsv",
            self.runtime / "events.pending.tsv",
        ):
            if path.exists():
                lines.extend(path.read_text(encoding="utf-8").splitlines())
        return lines

    def run_daemon_briefly(self, env=None):
        process = subprocess.Popen(
            ["sh", str(DAEMON)],
            env=env or self.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        try:
            time.sleep(0.35)
            process.terminate()
            process.wait(timeout=3)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)

    def test_online_probe_writes_target_and_sample_records(self):
        fields = self.run_probe()
        self.assertEqual(fields[0], "online")
        self.assertEqual(fields[3:7], ["2", "2", "2", "27"])

        targets = (self.runtime / "targets.tsv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(targets), 2)
        self.assertIn("\tTest ICMP\ticmp\t198.51.100.1\tipv4\t1\t12\tReply received", targets[0])
        self.assertIn("\tTest HTTP\thttp\thttps://example.test/generate_204\tauto\t1\t42\tHTTP 204", targets[1])

        samples = (self.runtime / "samples.tsv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(samples), 1)
        self.assertEqual(samples[0].split("\t")[1:], ["online", "27"])

    def test_failure_and_recovery_are_debounced(self):
        self.assertEqual(self.run_probe()[0], "online")
        first_failure = self.run_probe(ping=False, http=False)
        second_failure = self.run_probe(ping=False, http=False)
        third_failure = self.run_probe(ping=False, http=False)
        first_recovery = self.run_probe()
        second_recovery = self.run_probe()

        self.assertEqual(first_failure[0], "degraded")
        self.assertEqual(first_failure[7], "1")
        self.assertEqual(second_failure[0], "degraded")
        self.assertEqual(second_failure[7], "2")
        self.assertEqual(third_failure[0], "offline")
        self.assertEqual(third_failure[7], "3")
        self.assertEqual(first_recovery[0], "offline")
        self.assertEqual(first_recovery[8], "1")
        self.assertEqual(second_recovery[0], "online")
        self.assertEqual(second_recovery[8], "0")

        events = self.event_lines()
        self.assertEqual(
            [line.split("\t")[1] for line in events],
            ["online", "offline", "online"],
        )
        ids = [line.split("\t")[3] for line in events]
        self.assertTrue(all(ids))
        self.assertEqual(len(ids), len(set(ids)))

    def test_failed_probe_during_recovery_remains_offline(self):
        self.run_probe()
        self.run_probe(ping=False, http=False)
        self.run_probe(ping=False, http=False)
        self.assertEqual(self.run_probe(ping=False, http=False)[0], "offline")

        first_recovery = self.run_probe()
        failed_again = self.run_probe(ping=False, http=False)
        self.assertEqual(first_recovery[0], "offline")
        self.assertEqual(first_recovery[8], "1")
        self.assertEqual(failed_again[0], "offline")
        self.assertEqual(failed_again[8], "0")

    def test_unknown_boundaries_do_not_extend_availability(self):
        self.assertEqual(self.run_probe()[0], "online")
        self.env["TEST_NO_TARGETS"] = "1"
        self.assertEqual(self.run_probe()[0], "unknown")
        self.env["TEST_NO_TARGETS"] = "0"
        self.assertEqual(self.run_probe()[0], "online")
        self.assertEqual(
            [line.split("\t")[1] for line in self.event_lines()],
            ["online", "unknown", "online"],
        )

    def test_overlong_interval_falls_back_instead_of_busy_looping(self):
        env = self.env.copy()
        env["TEST_INTERVAL"] = "9" * 30
        self.run_daemon_briefly(env)

        samples = (self.runtime / "samples.tsv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(samples), 1)

    def test_stale_state_is_bounded_by_unknown_events_on_respawn(self):
        self.run_probe()
        self.run_daemon_briefly()
        self.assertEqual(
            [line.split("\t")[1] for line in self.event_lines()],
            ["online", "unknown", "online", "unknown"],
        )
        self.assertFalse((self.runtime / "state.tsv").exists())
        self.assertFalse((self.runtime / "targets.tsv").exists())

    def test_quorum_failure_is_not_hidden_by_one_success(self):
        fields = self.run_probe(ping=True, http=False)
        self.assertEqual(fields[0], "degraded")
        self.assertEqual(fields[3:6], ["1", "2", "2"])
        self.assertIn("Test HTTP", fields[10])

    def test_http_rules_accept_spaces_and_url_scheme_is_case_insensitive(self):
        self.env["TEST_HTTP_CODE"] = "404"
        self.env["TEST_EXPECTED_CODES"] = "404, 503"
        self.env["TEST_HTTP_ADDRESS"] = "HTTPS://example.test/status"
        fields = self.run_probe()
        self.assertEqual(fields[0], "online")
        targets = (self.runtime / "targets.tsv").read_text(encoding="utf-8")
        self.assertIn("\t1\t42\tHTTP 404", targets)

    def test_enabled_targets_above_limit_are_reported(self):
        self.env["TEST_EXTRA_TARGETS"] = "64"
        fields = self.run_probe()
        self.assertEqual(fields[4], "64")
        self.assertEqual(fields[11], "2")
        self.assertIn("2 enabled targets ignored (limit 64)", fields[10])
        targets = (self.runtime / "targets.tsv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(targets), 64)
        self.assertIn("2 enabled targets ignored (limit 64)", targets[0])

    def test_request_file_queued_before_sleep_runs_an_immediate_cycle(self):
        self.runtime.mkdir(parents=True)
        (self.runtime / "probe.request").write_text("queued\n", encoding="utf-8")
        self.run_daemon_briefly()
        samples = (self.runtime / "samples.tsv").read_text(encoding="utf-8").splitlines()
        self.assertGreaterEqual(len(samples), 2)
        self.assertFalse((self.runtime / "probe.request").exists())

    def test_event_merge_deduplicates_ids_and_clamps_legacy_clock_rollback(self):
        self.runtime.mkdir(parents=True)
        self.persist.mkdir(parents=True)
        now = int(time.time())
        first = now - 300
        latest = now - 100
        legacy = now - 250
        rollback = now - 200
        (self.persist / "events.tsv").write_text(
            f"{first}\tonline\tinitial\tid-a\n"
            f"{latest}\toffline\tdown\tid-b\n"
            f"{legacy}\tdegraded\tlegacy available\n",
            encoding="utf-8",
        )
        (self.runtime / "events.pending.tsv").write_text(
            f"{first}\tonline\tinitial\tid-a\n"
            f"{latest}\toffline\tdown\tid-b\n"
            f"{legacy}\tdegraded\tlegacy available\n"
            f"{rollback}\tonline\tclock moved back\tid-c\n",
            encoding="utf-8",
        )
        self.run_daemon_briefly()
        events = self.event_lines()
        self.assertEqual(sum(line.endswith("\tid-a") for line in events), 1)
        self.assertEqual(sum(line.endswith("\tid-b") for line in events), 1)
        self.assertEqual(sum("legacy available" in line for line in events), 1)
        self.assertEqual(sum(line.endswith("\tid-c") for line in events), 1)
        timestamps = [int(line.split("\t", 1)[0]) for line in events]
        self.assertEqual(timestamps, sorted(timestamps))
        id_c = next(line for line in events if line.endswith("\tid-c"))
        self.assertEqual(id_c.split("\t", 1)[0], str(latest))

    def test_pruning_keeps_last_boundary_before_retention_window(self):
        self.persist.mkdir(parents=True)
        now = int(time.time())
        day = 86400
        (self.persist / "events.tsv").write_text(
            f"{now - 40 * day}\tonline\told-a\tid-old-a\n"
            f"{now - 39 * day}\toffline\told-b\tid-old-b\n"
            f"{now - 38 * day}\tonline\told-c\tid-old-c\n",
            encoding="utf-8",
        )
        self.run_daemon_briefly()
        events = "\n".join(self.event_lines())
        self.assertNotIn("id-old-a", events)
        self.assertNotIn("id-old-b", events)
        self.assertIn("id-old-c", events)

    def test_clear_preserves_current_state_as_new_history_origin(self):
        self.run_probe()
        result = subprocess.run(
            ["sh", str(DAEMON), "--clear"],
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.runtime / "samples.tsv").exists())
        events = (self.persist / "events.tsv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].split("\t")[1:3], ["online", "History cleared"])
        self.assertEqual(len(events[0].split("\t")), 4)
        state_generation = (self.runtime / "state.tsv").read_text(encoding="utf-8").split("\t")[9]
        target_generation = (self.runtime / "targets.tsv").read_text(encoding="utf-8").split("\t", 1)[0]
        self.assertEqual(state_generation, target_generation)


if __name__ == "__main__":
    unittest.main()
