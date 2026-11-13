"""成功结果的后台监测：目标选择、失败计数与触发复测。"""

import unittest
from unittest import mock

from cfpick import config, monitor, result


class FakeLogger:
    def __init__(self):
        self.lines = []

    def log(self, message):
        self.lines.append(message)

    def persist(self, _path):
        pass

    def size_guard(self, _limit=None):
        pass


def cfg_with(nodes, ddns=False, monitor_cfg=None):
    data = {
        "nodes": nodes,
        "ddns": {"enabled": ddns, "provider": "cloudflare"},
        "monitor": monitor_cfg or {"enabled": True, "interval": 60, "failures": 3},
    }
    return config.normalize(data)


class TargetTests(unittest.TestCase):
    def setUp(self):
        self.rows = [
            result.Row(ip="1.2.3.4", latency=42.0, node="a", node_id="a"),
            result.Row(ip="5.6.7.8", latency=60.0, node="b", node_id="b"),
        ]
        patcher = mock.patch.object(monitor.result, "read_result",
                                    return_value=(self.rows, "now"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_plain_node_uses_result_ip(self):
        cfg = cfg_with([{"name": "a", "link": "vless://u@1.1.1.1:443#a",
                         "enabled": True}])
        target = monitor.target_for(cfg, "a")
        self.assertEqual(target["kind"], "ip")
        self.assertEqual(target["ip"], "1.2.3.4")
        self.assertEqual(target["label"], "1.2.3.4")

    def test_ddns_node_uses_domain(self):
        cfg = cfg_with([{"name": "b", "link": "vless://u@1.1.1.1:443#b",
                         "enabled": True, "ddns_domain": "JP.Example.com."}],
                       ddns=True)
        target = monitor.target_for(cfg, "b")
        self.assertEqual(target["kind"], "domain")
        self.assertEqual(target["domain"], "jp.example.com")
        self.assertEqual(target["expected"], "5.6.7.8")
        self.assertIsNone(target["ip"])

    def test_ddns_disabled_falls_back_to_ip(self):
        cfg = cfg_with([{"name": "b", "link": "vless://u@1.1.1.1:443#b",
                         "enabled": True, "ddns_domain": "jp.example.com"}],
                       ddns=False)
        self.assertEqual(monitor.target_for(cfg, "b")["kind"], "ip")

    def test_removed_or_unknown_node_has_no_target(self):
        cfg = cfg_with([])
        self.assertIsNone(monitor.target_for(cfg, "a"))


class ResolveTests(unittest.TestCase):
    def test_prefers_the_committed_ip(self):
        target = {"kind": "domain", "domain": "jp.example.com",
                  "expected": "1.2.3.4", "ip": None}
        with mock.patch.object(monitor, "resolve_host",
                               return_value=["9.9.9.9", "1.2.3.4"]):
            self.assertEqual(monitor._resolve_target(target), "")
        self.assertEqual(target["ip"], "1.2.3.4")

    def test_stale_dns_falls_back_to_committed_ip(self):
        target = {"kind": "domain", "domain": "jp.example.com",
                  "expected": "1.2.3.4", "ip": None}
        with mock.patch.object(monitor, "resolve_host",
                               return_value=["9.9.9.9"]):
            self.assertEqual(monitor._resolve_target(target), "")
        self.assertEqual(target["ip"], "1.2.3.4")
        self.assertTrue(target.get("dns_pending"))

    def test_no_dns_answer_falls_back_to_committed_ip(self):
        target = {"kind": "domain", "domain": "jp.example.com",
                  "expected": "1.2.3.4", "ip": None}
        with mock.patch.object(monitor, "resolve_host", return_value=[]):
            self.assertEqual(monitor._resolve_target(target), "")
        self.assertEqual(target["ip"], "1.2.3.4")
        self.assertTrue(target.get("dns_pending"))

    def test_no_dns_and_no_committed_ip_still_fails(self):
        target = {"kind": "domain", "domain": "jp.example.com",
                  "expected": "", "ip": None}
        with mock.patch.object(monitor, "resolve_host", return_value=[]):
            self.assertEqual(monitor._resolve_target(target), "域名无解析")
        self.assertIsNone(target["ip"])

    def test_ip_target_needs_no_dns(self):
        target = {"kind": "ip", "label": "1.2.3.4", "ip": "1.2.3.4",
                  "expected": "1.2.3.4"}
        self.assertEqual(monitor._resolve_target(target), "")
        self.assertEqual(target["ip"], "1.2.3.4")


class WatchTests(unittest.TestCase):
    """Run the loop with the probe/config layers mocked out."""

    def setUp(self):
        self.log = FakeLogger()
        self.cfg = cfg_with([{"name": "a", "link": "vless://u@1.1.1.1:443#a",
                              "enabled": True}])
        self.target = {"kind": "ip", "label": "1.2.3.4", "ip": "1.2.3.4",
                       "expected": "1.2.3.4"}
        self.patches = [
            mock.patch.object(config, "load", return_value=self.cfg),
            mock.patch.object(monitor, "Logger", return_value=self.log),
            mock.patch.object(monitor, "_acquire", return_value=True),
            mock.patch.object(monitor, "_release"),
            mock.patch.object(monitor, "_remove_state"),
            mock.patch.object(monitor, "_write_state"),
            mock.patch.object(monitor, "target_for", return_value=self.target),
            mock.patch.object(monitor, "_worker_busy", return_value=False),
            mock.patch.object(monitor.lock, "download_active_by_other",
                              return_value=False),
            mock.patch.object(monitor.tasklog, "event"),
            mock.patch.object(monitor, "_spawn_retest", return_value=True),
        ]
        self.mocks = {}
        for patcher in self.patches:
            self.mocks[patcher.attribute] = patcher.start()
            self.addCleanup(patcher.stop)

    def test_three_failures_trigger_one_retest(self):
        check = mock.patch.object(
            monitor, "_check", return_value=(False, 0.0, "探测未全部成功（0/3 次）"))
        sleep = mock.patch.object(monitor, "_sleep", return_value=True)
        check.start()
        sleep.start()
        self.addCleanup(check.stop)
        self.addCleanup(sleep.stop)

        monitor.watch("a")

        self.assertEqual(self.mocks["_spawn_retest"].call_count, 1)
        self.mocks["_spawn_retest"].assert_called_with("a", mock.ANY)
        # 每失败一次记一条事件，达到阈值再记一条「触发复测」。
        self.assertEqual(self.mocks["event"].call_count, 4)
        self.assertTrue(any("连续 3/3 次" in line for line in self.log.lines))
        self.assertEqual(self.mocks["_release"].call_count, 1)

    def test_single_failure_triggers_retest_when_threshold_is_one(self):
        # 默认阈值是 1：一次失败就复测，不再等连续 3 次。
        self.cfg["monitor"]["failures"] = 1
        check = mock.patch.object(
            monitor, "_check", return_value=(False, 0.0, "探测失败"))
        sleep = mock.patch.object(monitor, "_sleep", return_value=True)
        check.start()
        sleep.start()
        self.addCleanup(check.stop)
        self.addCleanup(sleep.stop)

        monitor.watch("a")

        self.assertEqual(self.mocks["_spawn_retest"].call_count, 1)
        self.assertTrue(any("连续 1/1 次" in line for line in self.log.lines))
        self.assertEqual(self.mocks["event"].call_count, 2)

    def test_success_is_logged_and_resets_failures(self):
        results = [(False, 0.0, "x"), (True, 45.2, ""), (False, 0.0, "x"),
                   (False, 0.0, "x")]
        check = mock.patch.object(monitor, "_check", side_effect=results)
        # 每次成功/失败后都继续，第四次失败后 _worker_busy 让循环结束。
        sleep = mock.patch.object(monitor, "_sleep", return_value=True)
        busy = mock.patch.object(
            monitor, "_worker_busy",
            side_effect=[False, False, False, False, True])
        check.start()
        sleep.start()
        busy.start()
        self.addCleanup(check.stop)
        self.addCleanup(sleep.stop)
        self.addCleanup(busy.stop)

        monitor.watch("a")

        self.assertEqual(self.mocks["_spawn_retest"].call_count, 0)
        self.assertTrue(any("45.20ms [正常]" in line for line in self.log.lines))

    def test_busy_worker_exits_before_probing(self):
        busy = mock.patch.object(monitor, "_worker_busy", return_value=True)
        check = mock.patch.object(monitor, "_check")
        busy.start()
        check_mock = check.start()
        self.addCleanup(busy.stop)
        self.addCleanup(check.stop)

        monitor.watch("a")

        check_mock.assert_not_called()
        self.mocks["_release"].assert_called_once_with("a")

    def test_disabled_monitor_does_not_take_the_lock(self):
        self.cfg = cfg_with([{"name": "a", "link": "vless://u@1.1.1.1:443#a",
                              "enabled": True}],
                            monitor_cfg={"enabled": False})
        with mock.patch.object(config, "load", return_value=self.cfg):
            monitor.watch("a")
        self.assertEqual(self.mocks["_acquire"].call_count, 0)


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.cfg = cfg_with([{"name": "a", "link": "vless://u@1.1.1.1:443#a",
                              "enabled": True}])
        self.log = FakeLogger()

    def test_probe_ignores_selection_thresholds(self):
        fake_engine = mock.Mock()
        fake_engine._nodes.return_value = [{"name": "a", "slot": 1}]
        fake_engine._probe_ip.return_value = (1, 3, 3, 0.0, 45.2, "")
        with mock.patch.object(monitor.core, "ensure_core",
                               return_value=("/bin/true", "mihomo")), \
             mock.patch.object(monitor.engine, "Engine", return_value=fake_engine) as ctor:
            ok, latency, detail = monitor._check(
                self.cfg, "a", {"kind": "ip", "label": "1.2.3.4",
                                "ip": "1.2.3.4", "expected": "1.2.3.4"}, self.log)
        self.assertTrue(ok)
        self.assertEqual(latency, 45.2)
        self.assertEqual(detail, "")
        self.assertFalse(fake_engine._probe_ip.call_args.kwargs["apply_filters"])
        self.assertEqual(ctor.call_args.kwargs["node_names"], ["a"])
        fake_engine.stop_all_cores.assert_called_once()

    def test_unresolvable_domain_without_result_never_starts_a_core(self):
        # 没有已发布 IP 兜底时才判 DNS 失败；有 expected 时改用 expected 探测。
        target = {"kind": "domain", "domain": "jp.example.com",
                  "expected": "", "ip": None}
        with mock.patch.object(monitor, "resolve_host", return_value=[]), \
             mock.patch.object(monitor.core, "ensure_core") as ensure:
            ok, latency, detail = monitor._check(
                self.cfg, "a", target, self.log)
        self.assertFalse(ok)
        self.assertEqual(detail, "域名无解析")
        ensure.assert_not_called()

    def test_missing_core_is_reported(self):
        with mock.patch.object(monitor.core, "ensure_core",
                               side_effect=monitor.core.CoreError("未安装")):
            ok, _latency, detail = monitor._check(
                self.cfg, "a", {"kind": "ip", "label": "1.2.3.4",
                                "ip": "1.2.3.4", "expected": "1.2.3.4"}, self.log)
        self.assertFalse(ok)
        self.assertIn("未安装", detail)


class SpawnTests(unittest.TestCase):
    def setUp(self):
        self.cfg = cfg_with([{"name": "a", "link": "vless://u@1.1.1.1:443#a",
                              "enabled": True}])
        self.patches = [
            mock.patch.object(config, "load", return_value=self.cfg),
            mock.patch.object(monitor, "alive_monitors", return_value={}),
            mock.patch.object(monitor, "_worker_busy", return_value=False),
            mock.patch.object(monitor, "_spawn_detached",
                              return_value=mock.Mock(pid=321)),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_only_successful_nodes_spawn(self):
        details = [
            {"node": "a", "status": "ok"},
            {"node": "b", "status": "fail"},
            {"node": "c", "status": "abnormal"},
        ]
        started = monitor.spawn_successful(details, FakeLogger())
        self.assertEqual(started, ["a"])

    def test_existing_monitor_is_not_duplicated(self):
        with mock.patch.object(monitor, "alive_monitors",
                               return_value={"a": {"pid": 1, "started": 0}}):
            self.assertFalse(monitor.spawn("a"))

    def test_monitor_disabled_spawns_nothing(self):
        self.cfg["monitor"]["enabled"] = False
        self.assertEqual(monitor.spawn_successful(
            [{"node": "a", "status": "ok"}]), [])


class ConfigTests(unittest.TestCase):
    def test_defaults(self):
        settings = config.normalize({})["monitor"]
        self.assertTrue(settings["enabled"])
        self.assertEqual(settings["interval"], 60)
        self.assertEqual(settings["failures"], 3)

    def test_clamps(self):
        settings = config.normalize({"monitor": {
            "enabled": "no", "interval": 1, "failures": 99}})["monitor"]
        self.assertFalse(settings["enabled"])
        self.assertEqual(settings["interval"], 10)
        self.assertEqual(settings["failures"], 10)


if __name__ == "__main__":
    unittest.main()
