import json
import tempfile
import unittest
from pathlib import Path

from cfpick import paths, result


class RowTests(unittest.TestCase):
    def test_sort_by_speed_then_latency(self):
        rows = [
            result.Row(ip="1.1.1.1", latency=10, speed=0),
            result.Row(ip="2.2.2.2", latency=80, speed=5.5),
            result.Row(ip="3.3.3.3", latency=30, speed=5.5),
        ]
        ordered = result.sort_rows(rows)
        self.assertEqual([row.ip for row in ordered], ["3.3.3.3", "2.2.2.2", "1.1.1.1"])

    def test_sort_by_latency(self):
        rows = [
            result.Row(ip="1.1.1.1", latency=30),
            result.Row(ip="2.2.2.2", latency=10),
        ]
        self.assertEqual([row.ip for row in result.sort_rows(rows, "latency")],
                         ["2.2.2.2", "1.1.1.1"])


class FileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.result_file = self.root / "result.csv"
        self.history_file = self.root / "history.csv"

    def tearDown(self):
        self.tmp.cleanup()

    def make_rows(self):
        return [
            result.Row(ip="1.1.1.1", sent=3, recv=3, loss=0.0, latency=20.5,
                       speed=8.25, region="JP", node="node-a"),
            result.Row(ip="2.2.2.2", sent=3, recv=2, loss=0.33, latency=40.0,
                       speed=0.0, region="SG", node="node-b"),
        ]

    def test_write_read_roundtrip(self):
        rows = self.make_rows()
        result.write_result(self.result_file, rows, "2026-01-02 03:04:05")
        read, when = result.read_result(self.result_file)
        self.assertEqual(when, "2026-01-02 03:04:05")
        self.assertEqual(len(read), 2)
        self.assertEqual(read[0].ip, "1.1.1.1")
        self.assertAlmostEqual(read[0].speed, 8.25)
        self.assertEqual(read[1].node, "node-b")

    def test_legacy_seven_columns(self):
        self.result_file.write_text(
            "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码\n"
            "1.1.1.1,3,3,0.00,20.00,0.00,JP\n", encoding="utf-8")
        rows, _ = result.read_result(self.result_file)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].node, "")

    def test_history_roundtrip(self):
        rows = result.sort_rows(self.make_rows())
        result.append_history(rows, "2026-01-02 03:04:05", self.history_file)
        history = result.parse_history(self.history_file)
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["ip"], "1.1.1.1")
        self.assertEqual(len(history[0]["nodes"]), 2)

    def test_best_view_groups_by_node(self):
        text = result.best_view(result.sort_rows(self.make_rows()), "2026-01-02 03:04:05")
        self.assertIn("# ── node-a", text)
        self.assertIn("# ── node-b", text)
        self.assertIn("# Speed test time: 2026-01-02 03:04:05", text)

    def test_export_json(self):
        rows = result.sort_rows(self.make_rows())
        payload = result.export_json(rows, "t", self.root / "result.json", self.root / "best.json")
        self.assertEqual(payload["best"]["ip"], "1.1.1.1")
        loaded = json.loads((self.root / "result.json").read_text(encoding="utf-8"))
        self.assertEqual(len(loaded["rows"]), 2)
        best = json.loads((self.root / "best.json").read_text(encoding="utf-8"))
        self.assertNotIn("rows", best)
        self.assertEqual(best["best"]["ip"], "1.1.1.1")

    def test_history_fallback_from_rotations(self):
        rows = self.make_rows()
        result.write_result(self.result_file, rows, "2026-01-02 03:04:05")
        old = Path(str(self.result_file) + ".1")
        result.write_result(old, rows, "2026-01-01 00:00:00")
        original = paths.RESULT_FILE
        try:
            paths.RESULT_FILE = self.result_file
            runs = result.history_from_result_files()
        finally:
            paths.RESULT_FILE = original
        self.assertEqual([run["time"] for run in runs],
                         ["2026-01-02 03:04:05", "2026-01-01 00:00:00"])


if __name__ == "__main__":
    unittest.main()
