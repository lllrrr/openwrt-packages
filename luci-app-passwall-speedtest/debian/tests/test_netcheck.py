"""断网判定（稳定参考地址）与挂起等待。"""

import unittest
from unittest import mock

from cfpick import config, netcheck


def _cfg(**monitor):
    data = {"monitor": dict({"enabled": True, "interval": 60, "failures": 3}, **monitor)}
    return config.normalize(data)


class _FakeLogger:
    def __init__(self):
        self.lines = []

    def log(self, message):
        self.lines.append(message)


class ConfigTests(unittest.TestCase):
    def test_defaults(self):
        cfg = config.normalize({})
        self.assertTrue(cfg["monitor"]["netcheck_enabled"])
        self.assertEqual(cfg["monitor"]["netcheck_target"], "223.5.5.5")

    def test_override(self):
        cfg = config.normalize({
            "monitor": {"netcheck_enabled": False, "netcheck_target": "8.8.8.8"}})
        self.assertFalse(cfg["monitor"]["netcheck_enabled"])
        self.assertEqual(cfg["monitor"]["netcheck_target"], "8.8.8.8")

    def test_empty_target_falls_back(self):
        cfg = config.normalize({"monitor": {"netcheck_target": "  "}})
        self.assertEqual(cfg["monitor"]["netcheck_target"], "223.5.5.5")


class ProbeTests(unittest.TestCase):
    def setUp(self):
        # 每个用例独立的缓存状态；默认 stub：双探针全通（在线）。
        self._reset()

    def tearDown(self):
        self._reset()

    def _reset(self):
        netcheck._cache.update({"expires": 0.0, "offline": True, "target": ""})
        netcheck._logged_offline = False
        icmp_patcher = mock.patch.object(netcheck, "_icmp_ok", return_value=True)
        dns_patcher = mock.patch.object(netcheck, "_dns_ok", return_value=True)
        icmp_patcher.start()
        dns_patcher.start()
        self.addCleanup(icmp_patcher.stop)
        self.addCleanup(dns_patcher.stop)

    def test_online_when_both_probes_work(self):
        self.assertFalse(netcheck.offline(_cfg()))
        # 结果已缓存：第二次调用不再实测（stub 改为失败也仍读缓存值）。
        self.assertFalse(netcheck.offline(_cfg()))

    def test_offline_when_both_probes_fail(self):
        with mock.patch.object(netcheck, "_icmp_ok", return_value=False), \
             mock.patch.object(netcheck, "_dns_ok", return_value=False), \
             mock.patch.object(netcheck.time, "sleep"):
            self.assertTrue(netcheck.offline(_cfg(), force=True))

    def test_one_probe_enough(self):
        # 禁 ICMP 的环境里 DNS 可达也判在线；反过来 ping 通也在线。
        with mock.patch.object(netcheck, "_icmp_ok", return_value=False), \
             mock.patch.object(netcheck.time, "sleep"):
            self.assertFalse(netcheck.offline(_cfg(), force=True))
        with mock.patch.object(netcheck, "_dns_ok", return_value=False), \
             mock.patch.object(netcheck.time, "sleep"):
            self.assertFalse(netcheck.offline(_cfg(), force=True))

    def test_disabled_is_always_online(self):
        self.assertFalse(netcheck.offline(_cfg(netcheck_enabled=False)))

    def test_disabled_resets_logged_flag(self):
        with mock.patch.object(netcheck, "_icmp_ok", return_value=False), \
             mock.patch.object(netcheck, "_dns_ok", return_value=False), \
             mock.patch.object(netcheck.time, "sleep"):
            cfg = _cfg()
            self.assertTrue(netcheck.offline(cfg, force=True))
        netcheck._logged_offline = True
        netcheck.offline(_cfg(netcheck_enabled=False))
        self.assertFalse(netcheck._logged_offline)

    def test_cache_hit_within_window(self):
        calls = {"icmp": 0}

        def counting_icmp(_host):
            calls["icmp"] += 1
            return True

        with mock.patch.object(netcheck, "_icmp_ok", side_effect=counting_icmp):
            cfg = _cfg()
            netcheck.offline(cfg)
            netcheck.offline(cfg)
        self.assertEqual(calls["icmp"], 1)


class WaitOnlineTests(unittest.TestCase):
    def setUp(self):
        netcheck._cache.update({"expires": 0.0, "offline": True, "target": ""})
        netcheck._logged_offline = False

    def tearDown(self):
        netcheck._cache.update({"expires": 0.0, "offline": True, "target": ""})
        netcheck._logged_offline = False

    def test_returns_true_when_online(self):
        with mock.patch.object(netcheck, "_icmp_ok", return_value=True):
            self.assertTrue(netcheck.wait_online(_cfg()))

    def test_waits_until_recovered(self):
        """断网 → 两次轮询后网络恢复 → 返回 True，全程有播报。"""
        logger = _FakeLogger()
        sequence = [True, True, False]  # 首查断网 → 进入循环仍断网 → 第三次恢复
        state = {"calls": 0}

        def fake_offline(_cfg, force=False):
            index = state["calls"]
            state["calls"] += 1
            return sequence[index] if index < len(sequence) else False

        with mock.patch.object(netcheck, "offline", side_effect=fake_offline), \
             mock.patch.object(netcheck.time, "sleep"):
            self.assertTrue(netcheck.wait_online(_cfg(), logger))
        self.assertEqual(len(logger.lines), 2)  # 挂起播报 + 恢复播报
        self.assertIn("挂起等待网络恢复", logger.lines[0])
        self.assertIn("网络已恢复", logger.lines[1])

    def test_stop_during_wait_returns_false(self):
        logger = _FakeLogger()
        with mock.patch.object(netcheck, "_icmp_ok", return_value=False), \
             mock.patch.object(netcheck, "_dns_ok", return_value=False), \
             mock.patch.object(netcheck.time, "sleep"):
            self.assertFalse(netcheck.wait_online(_cfg(), logger,
                                                  stop=lambda: True))
        self.assertTrue(any("停止" in line for line in logger.lines))


if __name__ == "__main__":
    unittest.main()
