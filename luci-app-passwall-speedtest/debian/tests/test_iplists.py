import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

from cfpick import iplists


class FileListTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "ip.txt"

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, text):
        self.path.write_text(text, encoding="utf-8")

    def test_cidr_and_plain_and_ports(self):
        self.write("1.2.3.0/30\n5.6.7.8\n# comment\n9.9.9.9:8443#JP\n")
        values = iplists.load_file(self.path, all_ip=False, limit=10)
        self.assertIn("5.6.7.8", values)
        self.assertIn("9.9.9.9", values)
        self.assertEqual(len(values), 3)
        self.assertTrue(any(value.startswith("1.2.3.") for value in values))

    def test_all_ips_in_small_network(self):
        self.write("10.0.0.0/30\n")
        values = iplists.load_file(self.path, all_ip=True, limit=10)
        self.assertEqual(values, ["10.0.0.1", "10.0.0.2"])

    def test_limit(self):
        self.write("10.0.0.0/16\n")
        values = iplists.load_file(self.path, all_ip=True, limit=7)
        self.assertEqual(len(values), 7)

    def test_invalid_lines_ignored(self):
        self.write("not-an-ip\n5.6.7.8\n")
        values = iplists.load_file(self.path)
        self.assertEqual(values, ["5.6.7.8"])

    def test_missing_file(self):
        with self.assertRaises(iplists.IpListError):
            iplists.load_file(Path(self.tmp.name) / "nope.txt")


class LatencyCapTests(unittest.TestCase):
    def test_list_cap_overrides_global(self):
        cfg = {
            "latency_max": 300,
            "ip_lists": [
                {"enabled": True, "latency_max": 120},
                {"enabled": False, "latency_max": 0},
            ],
        }
        self.assertEqual(iplists.node_latency_max(cfg, {"ip_list": "list1"}), 120)
        self.assertEqual(iplists.node_latency_max(cfg, {"ip_list": "list2"}), 300)

    def test_default_enabled_list(self):
        cfg = {"latency_max": 0, "ip_lists": [
            {"enabled": False, "latency_max": 99},
            {"enabled": True, "latency_max": 150},
        ]}
        self.assertEqual(iplists.node_latency_max(cfg, {}), 150)

    def test_zero_falls_back_to_global(self):
        cfg = {"latency_max": 250,
               "ip_lists": [{"enabled": True, "latency_max": 0}]}
        self.assertEqual(iplists.node_latency_max(cfg, {"ip_list": "list1"}), 250)


class OnlineTests(unittest.TestCase):
    def test_build_lists_filters_port_and_region(self):
        entries = [
            ("1.1.1.1", 443, "JP"),
            ("1.1.1.2", 443, "SG"),
            ("1.1.1.3", 443, "US"),
            ("1.1.1.4", 8443, "JP"),
        ]
        settings = [
            {"enabled": True, "name": "asia", "regions": ["JP", "SG"], "port": 443},
            {"enabled": True, "name": "alt", "regions": [], "port": 8443},
            {"enabled": False, "name": "", "regions": [], "port": 443},
        ]
        lists = iplists.build_online_lists(entries, settings, None)
        self.assertEqual(lists["list1"], ["1.1.1.1", "1.1.1.2"])
        self.assertEqual(lists["list2"], ["1.1.1.4"])
        self.assertNotIn("list3", lists)
        self.assertEqual(lists["_fallback"], ["1.1.1.1", "1.1.1.2", "1.1.1.3"])

    def test_default_list(self):
        settings = [
            {"enabled": False},
            {"enabled": True},
        ]
        self.assertEqual(iplists.default_list(settings), "list2")


class _Log:
    def __init__(self):
        self.lines = []

    def log(self, message):
        self.lines.append(str(message))


class RetestFallbackTests(unittest.TestCase):
    """复测只有 0/1 个候选的 worker 应退回普通测速重新取列表。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "ip.txt"
        self.path.write_text("5.6.7.8\n9.9.9.9\n", encoding="utf-8")
        self.cfg = {
            "ip_source": "custom",
            "custom_ip_file": str(self.path),
            "custom_allip": False,
            "test_count": 30,
            "ip_lists": [],
            "ip_online_url": "",
        }
        self.log = _Log()

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def node(name, server):
        return {"name": name, "ip_list": "", "ddns_domain": "",
                "parsed": types.SimpleNamespace(server=server)}

    def select(self, nodes, rows):
        with mock.patch("cfpick.iplists.result.read_result",
                        return_value=(rows, None)):
            return iplists.select(self.cfg, nodes, "retest", self.log)

    def test_two_candidates_stay_retest(self):
        nodes = [self.node("A", "2.2.2.2")]
        rows = [types.SimpleNamespace(node="A", ip="1.1.1.1")]
        chosen = self.select(nodes, rows)
        self.assertEqual(chosen.source, "retest")
        self.assertEqual(chosen.per_node["A"], ["2.2.2.2", "1.1.1.1"])
        self.assertFalse(any("普通测速" in line for line in self.log.lines))

    def test_single_candidate_falls_back_to_list(self):
        nodes = [self.node("A", "1.1.1.1")]
        rows = [types.SimpleNamespace(node="A", ip="1.1.1.1")]
        chosen = self.select(nodes, rows)
        self.assertEqual(chosen.per_node["A"], ["5.6.7.8", "9.9.9.9"])
        self.assertTrue(any("改为普通测速" in line for line in self.log.lines))

    def test_no_candidate_falls_back_to_list(self):
        nodes = [self.node("A", "example.com")]
        chosen = self.select(nodes, [])
        self.assertEqual(chosen.per_node["A"], ["5.6.7.8", "9.9.9.9"])

    def test_sparse_worker_does_not_affect_others(self):
        nodes = [self.node("A", "1.1.1.1"), self.node("B", "3.3.3.3")]
        rows = [
            types.SimpleNamespace(node="A", ip="1.1.1.1"),
            types.SimpleNamespace(node="B", ip="3.3.3.3"),
            types.SimpleNamespace(node="B", ip="4.4.4.4"),
        ]
        chosen = self.select(nodes, rows)
        self.assertEqual(chosen.per_node["A"], ["5.6.7.8", "9.9.9.9"])
        self.assertEqual(chosen.per_node["B"], ["3.3.3.3", "4.4.4.4"])

    def test_refresh_uses_normal_list_in_retest_mode(self):
        nodes = [self.node("A", "2.2.2.2")]
        rows = [types.SimpleNamespace(node="A", ip="1.1.1.1")]
        with mock.patch("cfpick.iplists.result.read_result") as reader:
            chosen = iplists.select(self.cfg, nodes, "retest", self.log,
                                    refresh=True)
            reader.assert_not_called()
        self.assertEqual(chosen.shared, ["5.6.7.8", "9.9.9.9"])

    def test_start_mode_unchanged(self):
        nodes = [self.node("A", "1.1.1.1")]
        with mock.patch("cfpick.iplists.result.read_result") as reader:
            chosen = iplists.select(self.cfg, nodes, "start", self.log)
            reader.assert_not_called()
        self.assertEqual(chosen.shared, ["5.6.7.8", "9.9.9.9"])


if __name__ == "__main__":
    unittest.main()
