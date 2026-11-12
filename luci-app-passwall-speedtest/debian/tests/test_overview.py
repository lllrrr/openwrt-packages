import tempfile
import unittest
from pathlib import Path
from unittest import mock

from cfpick import config, result, web


class LinkIdentityTests(unittest.TestCase):
    def test_fragment_and_whitespace_do_not_change_identity(self):
        base = "vless://uuid@example.com:443?type=ws&security=tls"
        self.assertEqual(config.node_id_for_link(base),
                         config.node_id_for_link("  " + base + "#old name  "))
        self.assertNotEqual(config.node_id_for_link(base),
                            config.node_id_for_link(base.replace(":443", ":8443")))

    def test_normalized_nodes_carry_id(self):
        cfg = config.normalize({
            "nodes": [{"name": "a", "link": "trojan://pw@example.com:443#a"}],
        })
        self.assertEqual(cfg["nodes"][0]["id"],
                         config.node_id_for_link("trojan://pw@example.com:443"))

    def test_duplicate_normalized_links_are_reported(self):
        nodes = [
            {"name": "a", "link": "trojan://pw@example.com:443#a"},
            {"name": "b", "link": "trojan://pw@example.com:443#b"},
        ]
        self.assertEqual(config.duplicate_link_names(nodes), [("a", "b")])


class HistoryPruneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "history.csv"

    def tearDown(self):
        self.tmp.cleanup()

    def test_prune_drops_removed_nodes_and_empty_runs(self):
        rows = [
            result.Row(ip="1.1.1.1", latency=10, speed=1, node="a", node_id="L-a"),
            result.Row(ip="2.2.2.2", latency=20, speed=2, node="b", node_id="L-b"),
        ]
        result.append_history([rows[0]], "2026-01-01 10:00:00", path=self.path)
        result.append_history([rows[1]], "2026-01-01 11:00:00", path=self.path)

        result.prune_history(["L-b"], ["b"], path=self.path)
        runs = result.parse_history(self.path)
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["time"], "2026-01-01 11:00:00")
        self.assertEqual([row["node"] for row in runs[0]["nodes"]], ["b"])

    def test_legacy_rows_match_by_name(self):
        result.append_history(
            [result.Row(ip="1.1.1.1", latency=10, speed=1, node="a")],
            "2026-01-01 10:00:00", path=self.path)
        result.prune_history(["L-a"], ["a"], path=self.path)
        self.assertEqual(len(result.parse_history(self.path)), 1)


class DownloadsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "downloads.tsv"

    def tearDown(self):
        self.tmp.cleanup()

    def test_roundtrip_and_best_status(self):
        entries = [{
            "node": "a", "node_id": "L-a", "ip": "1.1.1.1", "latency": 12.5,
            "loss": 0.0, "speed": 8.25, "asn": "AS13335",
            "asn_name": "Cloudflare, Inc.", "asn_cc": "US", "status": "best",
        }]
        result.append_downloads(entries, "2026-01-01 10:00:00",
                                 "2026-01-01 10:00:10", path=self.path)
        rows = result.parse_downloads(path=self.path)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["node_id"], "L-a")
        self.assertEqual(rows[0]["asn"], "AS13335")
        self.assertEqual(rows[0]["status"], "best")

    def test_append_downloads_unwritable_is_noop(self):
        blocker = Path(self.tmp.name) / "blocker"
        blocker.write_text("not a directory", encoding="utf-8")
        result.append_downloads([{
            "node": "a", "node_id": "L-a", "ip": "1.1.1.1",
            "latency": 1, "loss": 0, "speed": 1, "status": "best",
        }], "2026-01-01 10:00:00", "2026-01-01 10:00:10",
            path=blocker / "nested" / "downloads.tsv")

    def test_merge_result_replaces_by_id(self):
        path = Path(self.tmp.name) / "result.csv"
        result.write_result(path, [
            result.Row(ip="1.1.1.1", node="renamed", node_id="L-a"),
            result.Row(ip="2.2.2.2", node="b", node_id="L-b"),
        ])
        merged = result.merge_result(
            [result.Row(ip="3.3.3.3", node="renamed", node_id="L-a")],
            ["renamed"], path=path, node_ids=["L-a"])
        self.assertEqual(sorted(row.ip for row in merged), ["2.2.2.2", "3.3.3.3"])


class ConsoleFilterTests(unittest.TestCase):
    def setUp(self):
        self.cfg = config.normalize({"nodes": [{
            "name": "新名字",
            "link": "trojan://pw@example.com:443#old",
        }]})
        self.node_id = self.cfg["nodes"][0]["id"]

    def test_legacy_history_row_follows_current_name(self):
        history = [{
            "time": "2026-01-01 10:00:00",
            "nodes": [
                {"node": "新名字", "node_id": "", "ip": "1.1.1.1",
                 "latency": 10, "speed": 2, "region": "JP"},
                {"node": "已删除", "node_id": "L-gone", "ip": "2.2.2.2",
                 "latency": 20, "speed": 1, "region": "US"},
            ],
        }]
        with mock.patch.object(web.asn, "enrich_rows", side_effect=lambda row, **kw: row):
            out = web._history_for_console(self.cfg, history)
        self.assertEqual(len(out), 1)
        self.assertEqual([row["node"] for row in out[0]["nodes"]], ["新名字"])
        self.assertEqual(out[0]["nodes"][0]["node_id"], self.node_id)

    def test_downloads_drop_removed_nodes(self):
        rows = [
            {"node": "新名字", "node_id": "", "ip": "1.1.1.1"},
            {"node": "已删除", "node_id": "L-gone", "ip": "2.2.2.2"},
        ]
        with mock.patch.object(web.asn, "enrich_rows", side_effect=lambda row, **kw: row):
            out = web._downloads_for_console(self.cfg, rows)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["node_id"], self.node_id)
        self.assertEqual(out[0]["node"], "新名字")


if __name__ == "__main__":
    unittest.main()
