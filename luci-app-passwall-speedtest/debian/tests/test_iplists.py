import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
