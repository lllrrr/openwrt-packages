import os
import shlex
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RPCD = ROOT / "root/usr/libexec/rpcd/luci.internet-monitor"
FUNCTIONS = ROOT / "tests/fixtures/functions.sh"
JSHN_TRACE = ROOT / "tests/fixtures/jshn-trace.sh"
INIT_STUB = ROOT / "tests/fixtures/bin/logger"


class RpcSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = Path(self.temp.name, "runtime")
        self.persist = Path(self.temp.name, "persist")
        self.runtime.mkdir()
        self.persist.mkdir()
        self.history_jshn = Path(self.temp.name, "jshn-history.sh")
        self.history_jshn.write_text(
            f". {shlex.quote(str(JSHN_TRACE))}\n"
            "json_get_var() {\n"
            "\tcase \"$2\" in\n"
            "\t\thours) eval \"$1=\\${TEST_RPC_HOURS:-24}\" ;;\n"
            "\t\t*) eval \"$1=\" ;;\n"
            "\tesac\n"
            "}\n",
            encoding="utf-8",
        )
        self.env = os.environ.copy()
        self.env.update(
            {
                "INTERNET_MONITOR_FUNCTIONS_LIB": str(FUNCTIONS),
                "INTERNET_MONITOR_JSHN_LIB": str(JSHN_TRACE),
                "INTERNET_MONITOR_RUNTIME_DIR": str(self.runtime),
                "INTERNET_MONITOR_PERSIST_DIR": str(self.persist),
                "INTERNET_MONITOR_SNAPSHOT_RETRY_DELAY": "0",
                "INTERNET_MONITOR_INIT_SCRIPT": str(INIT_STUB),
            }
        )

    def run_status(self):
        return self.run_rpc("getStatus")

    def run_rpc(self, method, *, env=None, input_text=None):
        result = subprocess.run(
            ["sh", str(RPCD), "call", method],
            env=env or self.env,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def run_history(self, hours=24):
        env = self.env.copy()
        env["INTERNET_MONITOR_JSHN_LIB"] = str(self.history_jshn)
        env["TEST_RPC_HOURS"] = str(hours)
        return self.run_rpc("getHistory", env=env, input_text="{}\n")

    @staticmethod
    def trace_values(lines, kind, key):
        prefix = f"{kind}\t{key}\t"
        return [line[len(prefix) :] for line in lines if line.startswith(prefix)]

    @staticmethod
    def trace_objects(lines, array_name):
        objects = []
        current = None
        inside = False
        for line in lines:
            if line == f"array\t{array_name}":
                inside = True
                continue
            if not inside:
                continue
            if line == "close-array":
                break
            if line == "object\t":
                current = {}
                continue
            if line == "close-object":
                if current is not None:
                    objects.append(current)
                current = None
                continue
            if current is not None:
                fields = line.split("\t", 2)
                if len(fields) == 3:
                    current[fields[1]] = fields[2]
        return objects

    def write_state(self, *, generation="gen-a", total=1, ignored=0, updated=None):
        updated = updated or int(time.time())
        (self.runtime / "state.tsv").write_text(
            f"online\t{updated}\t{updated}\t{total}\t{total}\t{total}\t12\t0\t0\t"
            f"{generation}\ttest snapshot\t{ignored}\n",
            encoding="utf-8",
        )

    def test_generation_mismatch_fails_closed_then_recovers(self):
        self.write_state()
        (self.runtime / "targets.tsv").write_text(
            "gen-b\tleak-target\tLeak\ticmp\t192.0.2.1\tipv4\t1\t12\tReply\n",
            encoding="utf-8",
        )
        lines = self.run_status()
        self.assertEqual(self.trace_values(lines, "boolean", "snapshot_consistent"), ["0"])
        self.assertEqual(self.trace_values(lines, "string", "state"), ["unknown"])
        self.assertEqual(self.trace_values(lines, "int", "total"), ["0"])
        self.assertNotIn("leak-target", "\n".join(lines))

        (self.runtime / "targets.tsv").write_text(
            "gen-a\tstable-target\tStable\ticmp\t192.0.2.2\tipv4\t1\t12\tReply\n",
            encoding="utf-8",
        )
        lines = self.run_status()
        self.assertEqual(self.trace_values(lines, "boolean", "snapshot_consistent"), ["1"])
        self.assertEqual(self.trace_values(lines, "string", "state"), ["online"])
        self.assertIn("stable-target", "\n".join(lines))

    def test_snapshot_exposes_target_limit_metadata(self):
        self.write_state(ignored=2)
        (self.runtime / "targets.tsv").write_text(
            "gen-a\tstable-target\tStable\ticmp\t192.0.2.2\tipv4\t1\t12\tReply\n",
            encoding="utf-8",
        )
        lines = self.run_status()
        self.assertEqual(self.trace_values(lines, "int", "target_limit"), ["64"])
        self.assertEqual(self.trace_values(lines, "int", "targets_truncated"), ["2"])
        self.assertEqual(self.trace_values(lines, "int", "configured_total"), ["3"])

    def test_clock_rollback_and_nonadjacent_duplicate_do_not_overcount(self):
        now = int(time.time())
        self.write_state(total=0, updated=now)
        (self.runtime / "targets.tsv").write_text("", encoding="utf-8")
        (self.persist / "started_at").write_text(f"{now - 100000}\n", encoding="utf-8")
        (self.persist / "events.tsv").write_text(
            f"{now - 100000}\tonline\tstart\tid-a\n"
            f"{now - 500}\toffline\tdown\tid-b\n"
            f"{now - 400}\tunknown\tstop\tid-c\n",
            encoding="utf-8",
        )
        (self.runtime / "events.pending.tsv").write_text(
            f"{now - 1000}\tonline\trollback\tid-d\n"
            f"{now - 100000}\tonline\tduplicate\tid-a\n",
            encoding="utf-8",
        )
        lines = self.run_status()
        monitored = [int(value) for value in self.trace_values(lines, "int", "monitored")]
        downtime = [int(value) for value in self.trace_values(lines, "int", "downtime")]
        self.assertEqual(len(monitored), 3)
        self.assertLessEqual(monitored[0], 86400)
        self.assertTrue(all(value >= 0 for value in monitored + downtime))

    def test_run_probe_atomically_queues_request_even_without_signal_command(self):
        lines = self.run_rpc("runProbe")
        self.assertEqual(self.trace_values(lines, "boolean", "ok"), ["1"])
        self.assertTrue((self.runtime / "probe.request").is_file())
        self.assertFalse(list(self.runtime.glob("probe.request.tmp.*")))

    def test_history_points_preserve_state_and_latency_columns(self):
        sample_time = int(time.time()) // 300 * 300 + 1
        (self.persist / "started_at").write_text(f"{sample_time}\n", encoding="utf-8")
        (self.persist / "events.tsv").write_text(
            f"{sample_time}\tonline\tinitial availability\tid-start\n",
            encoding="utf-8",
        )
        (self.runtime / "samples.tsv").write_text(
            f"{sample_time}\tonline\t27\n",
            encoding="utf-8",
        )
        points = self.trace_objects(self.run_history(), "points")
        point = {int(item["timestamp"]): item for item in points}[sample_time]
        self.assertEqual(point["state"], "online")
        self.assertEqual(point["latency_ms"], "27")

    def test_history_without_events_or_samples_remains_empty(self):
        points = self.trace_objects(self.run_history(), "points")
        self.assertEqual(points, [])

    def test_history_reconstructs_pre_reboot_timeline_and_preserves_unknown_gap(self):
        anchor = int(time.time()) // 300 * 300
        started = anchor - 4 * 3600
        unknown_at = anchor - 3 * 3600 + 60
        recovered_at = anchor - 2 * 3600 + 60
        recovery_sample = recovered_at + 30
        detailed_sample = recovered_at // 300 * 300 + 310
        (self.persist / "started_at").write_text(f"{started}\n", encoding="utf-8")
        (self.persist / "events.tsv").write_text(
            f"{started}\tdegraded\tinitial availability\tid-start\n"
            f"{unknown_at}\tunknown\treboot gap\tid-stop\n"
            f"{recovered_at}\tonline\tmonitoring resumed\tid-resume\n",
            encoding="utf-8",
        )
        (self.runtime / "samples.tsv").write_text(
            f"{recovery_sample}\tonline\t31\n"
            f"{detailed_sample}\tdegraded\t43\n",
            encoding="utf-8",
        )

        points = {
            int(item["timestamp"]): item
            for item in self.trace_objects(self.run_history(), "points")
        }
        self.assertEqual(points[started]["state"], "online")
        self.assertEqual(points[unknown_at // 300 * 300 + 300]["state"], "unknown")
        recovery_slot = recovered_at // 300 * 300
        self.assertEqual(points[recovery_slot]["state"], "unknown")
        self.assertEqual(points[recovery_slot]["latency_ms"], "-1")
        detailed_slot = detailed_sample // 300 * 300
        self.assertEqual(points[detailed_slot]["state"], "degraded")
        self.assertEqual(points[detailed_slot]["latency_ms"], "43")
        self.assertEqual(points[detailed_slot + 300]["state"], "online")

    def test_history_does_not_hide_outage_boundary_with_later_online_sample(self):
        anchor = int(time.time()) // 300 * 300
        started = anchor - 3600
        offline_at = anchor - 1200 + 30
        recovered_at = offline_at + 60
        sample_time = recovered_at + 30
        (self.persist / "started_at").write_text(f"{started}\n", encoding="utf-8")
        (self.persist / "events.tsv").write_text(
            f"{started}\tonline\tinitial availability\tid-start\n"
            f"{offline_at}\toffline\tconfirmed outage\tid-down\n"
            f"{recovered_at}\tonline\trecovered\tid-up\n",
            encoding="utf-8",
        )
        (self.runtime / "samples.tsv").write_text(
            f"{sample_time}\tonline\t19\n",
            encoding="utf-8",
        )

        points = {
            int(item["timestamp"]): item
            for item in self.trace_objects(self.run_history(), "points")
        }
        boundary = offline_at // 300 * 300
        self.assertEqual(points[boundary]["state"], "offline")
        self.assertEqual(points[boundary]["latency_ms"], "-1")

    def test_history_uses_half_open_right_boundary(self):
        boundary = (int(time.time()) // 300 + 2) * 300
        started = boundary - 600
        (self.persist / "started_at").write_text(f"{started}\n", encoding="utf-8")
        (self.persist / "events.tsv").write_text(
            f"{started}\tonline\tinitial availability\tid-start\n"
            f"{boundary}\toffline\tnew outage at generated time\tid-end\n",
            encoding="utf-8",
        )

        lines = self.run_history()
        generated_at = int(self.trace_values(lines, "int", "generated_at")[0])
        points = self.trace_objects(lines, "points")
        timestamps = [int(item["timestamp"]) for item in points]

        self.assertEqual(generated_at, boundary)
        self.assertEqual(timestamps, [started, started + 300])
        self.assertTrue(all(item["state"] == "online" for item in points))

    def test_history_samples_rank_unknown_above_success_in_same_bucket(self):
        slot = (int(time.time()) // 300 + 2) * 300
        (self.persist / "started_at").write_text(f"{slot}\n", encoding="utf-8")
        (self.runtime / "samples.tsv").write_text(
            f"{slot + 10}\tonline\t25\n"
            f"{slot + 20}\tunknown\t-1\n"
            f"{slot + 40}\tonline\t30\n",
            encoding="utf-8",
        )

        points = self.trace_objects(self.run_history(), "points")

        self.assertEqual(len(points), 1)
        self.assertEqual(int(points[0]["timestamp"]), slot)
        self.assertEqual(points[0]["state"], "unknown")

    def test_history_bucket_widths_cover_supported_ranges(self):
        anchor = int(time.time()) // 3600 * 3600
        started = anchor - 31 * 86400
        (self.persist / "started_at").write_text(f"{started}\n", encoding="utf-8")
        (self.persist / "events.tsv").write_text(
            f"{started}\tonline\tinitial availability\tid-start\n",
            encoding="utf-8",
        )

        for hours, width in ((24, 300), (168, 900), (720, 3600)):
            with self.subTest(hours=hours):
                lines = self.run_history(hours)
                self.assertEqual(self.trace_values(lines, "int", "hours"), [str(hours)])
                timestamps = [
                    int(item["timestamp"])
                    for item in self.trace_objects(lines, "points")
                ]
                generated_at = int(self.trace_values(lines, "int", "generated_at")[0])
                cutoff = generated_at - hours * 3600
                self.assertGreater(len(timestamps), 1)
                self.assertEqual(timestamps[0], cutoff)
                self.assertTrue(all(timestamp % width == 0 for timestamp in timestamps[1:]))
                self.assertLessEqual(timestamps[1] - timestamps[0], width)
                self.assertTrue(
                    all(
                        right - left == width
                        for left, right in zip(timestamps[1:], timestamps[2:])
                    )
                )


if __name__ == "__main__":
    unittest.main()
