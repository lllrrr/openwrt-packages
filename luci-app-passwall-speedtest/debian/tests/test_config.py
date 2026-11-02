import os
import tempfile
import unittest
from pathlib import Path

from cfpick import config, paths


class NormalizeTests(unittest.TestCase):
    def test_defaults(self):
        cfg = config.normalize({})
        self.assertEqual(cfg["ip_source"], "builtin_ipv4")
        self.assertEqual(cfg["probes"], 3)
        self.assertEqual(cfg["download_count"], 5)
        # 延迟含节点自身 RTT，默认不设上限，避免远端节点全被丢弃。
        self.assertEqual(cfg["latency_max"], 0)
        self.assertEqual(len(cfg["ip_lists"]), 5)
        self.assertTrue(cfg["ip_lists"][0]["enabled"])
        self.assertFalse(cfg["ip_lists"][1]["enabled"])
        self.assertEqual(cfg["web"]["port"], 8787)

    def test_clamps(self):
        cfg = config.normalize({
            "probes": 99,
            "download_count": 0,
            "test_count": 0,
            "loss_max": 5,
            "web": {"port": 99999},
        })
        self.assertEqual(cfg["probes"], 5)
        self.assertEqual(cfg["download_count"], 1)
        self.assertEqual(cfg["test_count"], 1)
        self.assertEqual(cfg["loss_max"], 1.0)
        self.assertEqual(cfg["web"]["port"], 65535)

    def test_node_names_are_unique(self):
        cfg = config.normalize({"nodes": [
            {"name": "same", "link": "vless://a@b:443#x"},
            {"name": "same", "link": "vless://c@d:443#y"},
            {"name": "", "link": "vless://e@f:443#z"},
            {"name": "no-link", "link": ""},
        ]})
        names = [node["name"] for node in cfg["nodes"]]
        self.assertEqual(names, ["same", "same-2", "node3"])

    def test_invalid_cron_falls_back(self):
        cfg = config.normalize({"schedule": {"custom_cron": "bad"}})
        self.assertEqual(cfg["schedule"]["custom_cron"], "0 3 * * *")

    def test_cron_validation(self):
        valid = [
            "0 3 * * *",
            "*/30 * * * *",
            "0 */6 * * *",
            "0 3 1 * *",
            "0 3 * * mon-fri",
            "5,10 0-6/2 * * 0",
            "0 0 1 jan,jul *",
            "0 3 * * 7",
        ]
        invalid = [
            "0 3 * *",          # only four fields
            "60 3 * * *",       # minute out of range
            "0 24 * * *",       # hour out of range
            "0 3 32 * *",       # day out of range
            "0 3 * 13 *",       # month out of range
            "0 3 * * 8",        # weekday out of range
            "0 3 * * ?",        # Quartz-only token
            "*/0 * * * *",      # zero step
            "1-5-7 * * * *",    # malformed range
            "0 3 * * * *",      # six fields
        ]
        for expression in valid:
            self.assertTrue(config.valid_cron(expression), expression)
        for expression in invalid:
            self.assertFalse(config.valid_cron(expression), expression)

    def test_schedule_defaults_and_legacy_interval(self):
        default = config.normalize({})
        self.assertTrue(default["schedule"]["custom_enabled"])
        self.assertEqual(default["schedule"]["custom_cron"], "0 3 * * *")
        # Old configs with only ``hour`` keep the interval semantics.
        legacy = config.normalize({"schedule": {"hour": 6}})
        self.assertFalse(legacy["schedule"]["custom_enabled"])
        self.assertEqual(legacy["schedule"]["hour"], 6)

    def test_fullwidth_input_is_normalized(self):
        # Chinese IMEs in full-width mode produce "１２" for "12".
        cfg = config.normalize({
            "nodes": [{
                "name": "jp", "link": "vless://u@h:443#jp",
                "ddns_domain": "ＪＰ．ＥＸＡＭＰＬＥ．ＣＯＭ",
            }],
            "schedule": {
                "custom_enabled": True,
                "custom_cron": "0 １２ * * *",
            },
        })
        self.assertEqual(cfg["schedule"]["custom_cron"], "0 12 * * *")
        self.assertEqual(cfg["nodes"][0]["ddns_domain"], "jp.example.com")

        cfg = config.normalize({"schedule": {
            "custom_enabled": True,
            "custom_cron": "0 1，2 * * *",
        }})
        self.assertEqual(cfg["schedule"]["custom_cron"], "0 1,2 * * *")

    def test_invalid_structured_cron_falls_back(self):
        cfg = config.normalize({"schedule": {
            "custom_enabled": True,
            "custom_cron": "0 99 * * *",
        }})
        self.assertEqual(cfg["schedule"]["custom_cron"], "0 3 * * *")

    def test_regions_normalized(self):
        cfg = config.normalize({"ip_lists": [
            {"enabled": True, "regions": "jp, sg  jp"},
        ]})
        self.assertEqual(cfg["ip_lists"][0]["regions"], ["JP", "SG"])

    def test_core_type(self):
        self.assertEqual(config.normalize({})["core"]["type"], "mihomo")
        self.assertEqual(config.normalize({"core": {"type": "xray"}})["core"]["type"], "xray")
        self.assertEqual(config.normalize({"core": {"type": "bogus"}})["core"]["type"], "mihomo")

    def test_core_paths(self):
        cfg = config.normalize({"core": {"paths": {"mihomo": "/a", "xray": "/b"}}})
        self.assertEqual(cfg["core"]["paths"], {"mihomo": "/a", "xray": "/b"})
        # Old single-path config migrates to the selected core only.
        cfg = config.normalize({"core": {"type": "xray", "path": "/opt/xray"}})
        self.assertEqual(cfg["core"]["paths"]["xray"], "/opt/xray")
        self.assertEqual(cfg["core"]["paths"]["mihomo"], "")


class SaveLoadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self._config_dir = paths.CONFIG_DIR
        self._config_file = paths.CONFIG_FILE
        paths.CONFIG_DIR = self.root
        paths.CONFIG_FILE = self.root / "config.json"

    def tearDown(self):
        paths.CONFIG_DIR = self._config_dir
        paths.CONFIG_FILE = self._config_file
        self.tmp.cleanup()

    def test_roundtrip_and_mode(self):
        cfg = config.normalize({"nodes": [{"name": "n", "link": "vless://u@h:443#n"}]})
        config.save(cfg)
        loaded = config.load()
        self.assertEqual(loaded["nodes"][0]["name"], "n")
        if os.name != "nt":
            mode = (self.root / "config.json").stat().st_mode & 0o777
            self.assertEqual(mode, 0o600)

    def test_load_creates_file(self):
        loaded = config.load()
        self.assertTrue((self.root / "config.json").exists())
        self.assertEqual(loaded["ip_source"], "builtin_ipv4")


if __name__ == "__main__":
    unittest.main()
