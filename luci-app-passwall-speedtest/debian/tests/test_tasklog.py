import tempfile
import unittest
from pathlib import Path

from cfpick import tasklog


class TaskLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "tasklog.tsv"

    def tearDown(self):
        self.tmp.cleanup()

    def test_roundtrip_newest_first(self):
        tasklog.start("start", ["node-a", "node-b"], path=self.path)
        details = [
            {"node": "node-a", "ip": "1.1.1.1", "latency": 20.5,
             "speed": 8.25, "status": "ok", "method": "ddns"},
            {"node": "node-b", "status": "fail", "method": "-"},
        ]
        tasklog.result("start", "ok", node="node-a", ip="1.1.1.1",
                       latency=20.5, speed=8.25, ddns="更新 1",
                       message=tasklog.result_message("start", "ok", details),
                       details=tasklog.format_details(details),
                       path=self.path)
        entries = tasklog.parse(path=self.path)
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[0]["kind"], "result")
        self.assertEqual(entries[0]["node"], "node-a")
        self.assertEqual(entries[0]["ip"], "1.1.1.1")
        self.assertAlmostEqual(entries[0]["latency"], 20.5)
        self.assertAlmostEqual(entries[0]["speed"], 8.25)
        self.assertEqual(entries[0]["ddns"], "更新 1")
        self.assertEqual(entries[0]["message"],
                         "测速任务成功：成功 1 · 失败 1 · 异常 0")
        self.assertEqual(len(entries[0]["details"]), 2)
        self.assertEqual(entries[0]["details"][1]["node"], "node-b")
        self.assertEqual(entries[1]["kind"], "start")
        self.assertIn("node-a", entries[1]["message"])
        self.assertEqual(entries[1]["details"], [])

    def test_details_roundtrip_and_counts(self):
        details = [
            {"node": "node-a", "ip": "1.1.1.1", "latency": 20.5,
             "speed": 8.25, "status": "ok", "method": "ddns"},
            {"node": "node|b", "status": "fail", "method": "-"},
            {"node": "node-c", "status": "abnormal", "method": "-"},
        ]
        parsed = tasklog.parse_details(tasklog.format_details(details))
        self.assertEqual([entry["node"] for entry in parsed],
                         ["node-a", "node b", "node-c"])
        self.assertEqual(tasklog.summarize(parsed), (1, 1, 1))
        self.assertEqual(
            tasklog.result_message("retest", "stopped", parsed),
            "复测任务已停止：成功 1 · 失败 1 · 异常 1")

    def test_old_ten_column_line_still_parses(self):
        self.path.write_text(
            "2026-01-02 03:04:05\tresult\tstart\tok\tnode-a\t1.1.1.1\t"
            "20.50\t8.25\t-\t任务完成\n", encoding="utf-8")
        entries = tasklog.parse(path=self.path)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["details"], [])

    def test_tabs_and_newlines_do_not_break_fields(self):
        tasklog.event("download_retest", "a\tb\nc", nodes="node-a",
                      path=self.path)
        entries = tasklog.parse(path=self.path)
        self.assertEqual(entries[0]["message"], "a b c")
        self.assertEqual(entries[0]["mode"], "download_retest")

    def test_trim_keeps_last_lines(self):
        original = tasklog.MAX_LINES
        tasklog.MAX_LINES = 3
        try:
            for index in range(6):
                tasklog.event("all_filtered", "event %d" % index, path=self.path)
        finally:
            tasklog.MAX_LINES = original
        lines = self.path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 3)
        entries = tasklog.parse(path=self.path)
        self.assertEqual(entries[0]["message"], "event 5")

    def test_ddns_label(self):
        self.assertEqual(tasklog.ddns_label({
            "enabled": True, "created": 1, "updated": 2, "unchanged": 0,
            "failed": 0,
        }), "新建 1，更新 2")
        self.assertEqual(tasklog.ddns_label({"enabled": False}), "未启用")
        self.assertEqual(tasklog.ddns_label(None), "")

    def test_parse_missing_file(self):
        self.assertEqual(tasklog.parse(path=self.path), [])


if __name__ == "__main__":
    unittest.main()
