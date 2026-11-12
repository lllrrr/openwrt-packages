"""Engine node selection and download-retry behaviour."""

import shutil
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

from cfpick import engine, iplists, result


class FakeLogger:
    def __init__(self):
        self.lines = []

    def log(self, message):
        self.lines.append(message)

    def size_guard(self, _limit=None):
        pass


def make_engine(nodes, selected):
    return engine.Engine(
        {"nodes": nodes}, FakeLogger(), "start", "/bin/true", "mihomo",
        "/tmp/cfpick-test", node_names=selected)


class NodeSelectionTests(unittest.TestCase):
    def setUp(self):
        self.nodes = [
            {"name": "a", "link": "vless://u@1.1.1.1:443#a", "enabled": True},
            {"name": "b", "link": "vless://u@2.2.2.2:443#b", "enabled": True},
            {"name": "off", "link": "vless://u@3.3.3.3:443#off", "enabled": False},
        ]
        self._parse = mock.patch.object(
            engine.links, "parse_link",
            side_effect=lambda link: SimpleNamespace(
                proxy={"type": "vless"}, name=link.rsplit("#", 1)[-1]))
        self._validate = mock.patch.object(
            engine.core, "validate_proxy", return_value=None)
        self._parse.start()
        self._validate.start()

    def tearDown(self):
        self._parse.stop()
        self._validate.stop()

    def test_empty_selection_keeps_every_enabled_node(self):
        names = [node["name"] for node in make_engine(self.nodes, None)._nodes()]
        self.assertEqual(names, ["a", "b"])

    def test_selection_limits_and_renumbers_slots(self):
        nodes = make_engine(self.nodes, ["b"])._nodes()
        self.assertEqual([node["name"] for node in nodes], ["b"])
        # Slots drive SOCKS ports/work dirs; a filtered list must stay dense.
        self.assertEqual(nodes[0]["slot"], 1)

    def test_missing_selection_raises_engine_error(self):
        with self.assertRaises(engine.EngineError):
            make_engine(self.nodes, ["nope"])._nodes()

    def test_selected_disabled_node_is_not_runnable(self):
        with self.assertRaises(engine.EngineError):
            make_engine(self.nodes, ["off"])._nodes()


class DownloadRetryTests(unittest.TestCase):
    """下载全部失败的节点在其他节点下载结束后复测一轮。"""

    def setUp(self):
        self.cfg = {
            "nodes": [],
            "download_enabled": True,
            "download_count": 3,
            "download_url": "https://example.test/dl",
            "download_time": 1,
            "iterate_enabled": False,
        }
        self.log = mock.Mock()
        # _download_stage 会写全局 state（/var/lib/cfpick），测试里不需要真实落盘。
        state = mock.patch.object(engine.lock, "write_state")
        state.start()
        self.addCleanup(state.stop)
        self.eng = engine.Engine(self.cfg, self.log, "start", "/bin/true",
                                 "mihomo", tempfile.mkdtemp())
        self.node = {"name": "a", "slot": 1, "ip_list": "",
                     "parsed": SimpleNamespace(server="1.1.1.1")}

    def tearDown(self):
        shutil.rmtree(self.eng.run_dir, ignore_errors=True)

    @staticmethod
    def row(ip):
        return result.Row(ip=ip, latency=10)

    def test_all_downloads_failed_marks_node(self):
        rows_by_node = {"a": [self.row("1.1.1.1")]}
        with mock.patch.object(engine.Engine, "_download_one", return_value=0.0):
            failed = self.eng._download_stage([self.node], rows_by_node)
        self.assertEqual([node["name"] for node in failed], ["a"])

    def test_successful_download_not_marked(self):
        rows_by_node = {"a": [self.row("1.1.1.1")]}
        with mock.patch.object(engine.Engine, "_download_one", return_value=5.0):
            failed = self.eng._download_stage([self.node], rows_by_node)
        self.assertEqual(failed, [])

    def test_retest_replaces_rows_when_download_succeeds(self):
        rows_by_node = {"a": [self.row("1.1.1.1")]}
        candidates = iplists.CandidateSet(
            source="retest", per_node={"a": ["2.2.2.2"]})
        with mock.patch.object(engine.iplists, "retest_candidates",
                               return_value=candidates), \
             mock.patch.object(engine.Engine, "_latency_worker",
                               return_value=[self.row("2.2.2.2")]), \
             mock.patch.object(engine.Engine, "_download_one", return_value=5.0):
            self.eng._retest_download_failures([self.node], rows_by_node)
        self.assertEqual([row.ip for row in rows_by_node["a"]], ["2.2.2.2"])

    def test_retest_keeps_original_when_download_still_fails(self):
        original = [self.row("1.1.1.1")]
        rows_by_node = {"a": original}
        candidates = iplists.CandidateSet(
            source="retest", per_node={"a": ["2.2.2.2"]})
        with mock.patch.object(engine.iplists, "retest_candidates",
                               return_value=candidates), \
             mock.patch.object(engine.Engine, "_latency_worker",
                               return_value=[self.row("2.2.2.2")]), \
             mock.patch.object(engine.Engine, "_download_one", return_value=0.0):
            self.eng._retest_download_failures([self.node], rows_by_node)
        self.assertIs(rows_by_node["a"], original)

    def test_user_stop_skips_retest(self):
        self.eng.stop_source = "user"
        with mock.patch.object(engine.iplists, "retest_candidates") as reader:
            self.eng._retest_download_failures([self.node], {})
            reader.assert_not_called()

    def test_quick_latency_worker_stops_after_candidate_count(self):
        candidates = SimpleNamespace(
            for_node=lambda _name, _list: ["1.1.1.1", "2.2.2.2", "3.3.3.3"])
        log = FakeLogger()
        # 下载开启时只靠延迟通过不算有效；本测试只验证早停，关掉下载。
        eng = engine.Engine(dict(self.cfg, download_enabled=False), log,
                            "retest", "/bin/true", "mihomo", self.eng.run_dir)
        with mock.patch.object(engine.Engine, "_probe_ip",
                               return_value=(1, 3, 3, 0.0, 10.0, "")), \
             mock.patch.object(engine.lock, "download_active_by_other",
                               return_value=False):
            rows = eng._latency_worker(self.node, candidates, stop_after=2)
        self.assertEqual([row.ip for row in rows], ["1.1.1.1", "2.2.2.2"])
        self.assertEqual(eng.fresh_nodes, {"a"})
        self.assertTrue(any("已凑够 2 个下载候选" in line for line in log.lines))

    def test_download_success_marks_node_fresh(self):
        eng = engine.Engine(dict(self.cfg), self.log, "retest", "/bin/true",
                            "mihomo", self.eng.run_dir)
        with mock.patch.object(engine.Engine, "_download_one", return_value=5.0):
            _rows, kept, _details = eng._download_phase(self.node, [self.row("1.1.1.1")])
        self.assertEqual(kept, 1)
        self.assertIn("a", eng.fresh_nodes)

    def test_stale_only_result_clears_the_node(self):
        self.eng.fresh_nodes = set()
        rows_by_node = {"a": [self.row("1.1.1.1")]}
        with mock.patch.object(engine.lock, "write_state"), \
             mock.patch.object(engine.result, "append_history") as append, \
             mock.patch.object(engine.result, "merge_result",
                               return_value=[]) as merge, \
             mock.patch.object(engine.result, "write_result") as write, \
             mock.patch.object(engine.result, "export_json") as export:
            ok = self.eng._commit([self.node], rows_by_node)
        self.assertFalse(ok)
        append.assert_not_called()
        merge.assert_called_once_with([], ["a"], node_ids=[""])
        write.assert_called_once()
        export.assert_called_once()

    def test_quick_ignores_iterate_mode(self):
        cfg = dict(self.cfg, iterate_enabled=True)
        eng = engine.Engine(cfg, self.log, "retest", "/bin/true", "mihomo",
                            self.eng.run_dir, quick=True)
        self.assertFalse(eng._iterate_mode())
        cfg["iterate_enabled"] = False
        self.assertFalse(eng._iterate_mode())


class MonitorRetestChainTests(unittest.TestCase):
    """监测失败后的复测链：先快速复测，再正常复测。"""

    def setUp(self):
        from cfpick import __main__ as cli

        self.cli = cli
        self.args = SimpleNamespace(node="a")

    def test_quick_then_normal_then_refresh_when_both_fail(self):
        with mock.patch.object(self.cli.engine, "run",
                               side_effect=[1, 1, 0]) as run, \
             mock.patch.object(self.cli.lock, "stop_requested", return_value=False):
            rc = self.cli.cmd_monitor_retest(self.args)
        self.assertEqual(rc, 0)
        self.assertEqual(run.call_args_list, [
            mock.call("retest", node_names=["a"], quick=True),
            mock.call("retest", node_names=["a"]),
            mock.call("retest", node_names=["a"], refresh=True),
        ])

    def test_successful_normal_pass_skips_refresh(self):
        with mock.patch.object(self.cli.engine, "run",
                               side_effect=[1, 0]) as run, \
             mock.patch.object(self.cli.lock, "stop_requested", return_value=False):
            rc = self.cli.cmd_monitor_retest(self.args)
        self.assertEqual(rc, 0)
        self.assertEqual(run.call_args_list, [
            mock.call("retest", node_names=["a"], quick=True),
            mock.call("retest", node_names=["a"]),
        ])

    def test_user_stop_skips_the_following_passes(self):
        with mock.patch.object(self.cli.engine, "run", return_value=1) as run, \
             mock.patch.object(self.cli.lock, "stop_requested", return_value=True):
            rc = self.cli.cmd_monitor_retest(self.args)
        self.assertEqual(rc, 1)
        run.assert_called_once_with("retest", node_names=["a"], quick=True)


class DatacenterPreservationTests(unittest.TestCase):
    """每个机房（ASN）至少一个代表进入下载实测，当前最优 IP 保送。"""

    def setUp(self):
        self.cfg = {
            "nodes": [],
            "download_enabled": True,
            "download_count": 2,
            "download_url": "https://example.test/dl",
            "download_time": 1,
            "iterate_enabled": False,
            "probe_url": "https://example.test/probe",
            "probe_timeout": 1,
            "probes": 1,
            "latency_max": 100,
            "latency_min": 0,
            "loss_max": 0.2,
            "ip_lists": [],
        }
        self.log = FakeLogger()
        self.eng = engine.Engine(self.cfg, self.log, "start", "/bin/true",
                                 "mihomo", tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.eng.run_dir, True)
        self.node = {"name": "a", "id": "id-a", "slot": 1, "ip_list": "",
                     "parsed": SimpleNamespace(server="1.1.1.1")}

    @staticmethod
    def row(ip, latency):
        return result.Row(ip=ip, latency=latency, sent=3, recv=3, loss=0.0)

    def _download_ips(self, rows, asn_map):
        with mock.patch.object(engine.Engine, "_current_best_ip", return_value=""), \
             mock.patch.object(engine.asn, "lookup",
                               side_effect=lambda ip: {"asn": asn_map[ip]}), \
             mock.patch.object(engine.Engine, "_download_one",
                               return_value=5.0) as download:
            self.eng._download_phase(self.node, rows)
        return [call.args[1] for call in download.call_args_list]

    def test_one_representative_per_asn_enters_download(self):
        rows = [self.row("1.1.1.1", 10), self.row("1.1.1.2", 11),
                self.row("2.2.2.2", 12), self.row("3.3.3.3", 13)]
        asn_map = {"1.1.1.1": "AS1", "1.1.1.2": "AS1",
                   "2.2.2.2": "AS2", "3.3.3.3": "AS3"}
        # download_count=2, but three datacenters need representatives.
        self.assertEqual(
            self._download_ips(rows, asn_map),
            ["1.1.1.1", "2.2.2.2", "3.3.3.3", "1.1.1.2"])
        self.assertTrue(any("共 3 个机房代表" in line for line in self.log.lines))

    def test_configured_count_still_applies_without_extra_datacenters(self):
        rows = [self.row("1.1.1.1", 10), self.row("1.1.1.2", 11),
                self.row("1.1.1.3", 12), self.row("2.2.2.2", 13),
                self.row("1.1.1.4", 14), self.row("1.1.1.5", 15)]
        asn_map = {"1.1.1.1": "AS1", "1.1.1.2": "AS1", "1.1.1.3": "AS1",
                   "2.2.2.2": "AS2", "1.1.1.4": "AS1", "1.1.1.5": "AS1"}
        cfg = dict(self.cfg, download_count=5)
        self.eng.cfg = cfg
        # 2 representatives need only 3 slots; the configured 5 still apply.
        self.assertEqual(len(self._download_ips(rows, asn_map)), 5)

    def test_current_best_is_tested_even_when_not_in_rows(self):
        self.cfg["download_count"] = 5
        with mock.patch.object(engine.Engine, "_current_best_ip",
                               return_value="9.9.9.9"), \
             mock.patch.object(engine.Engine, "_previous_row", return_value=None), \
             mock.patch.object(engine.asn, "lookup", return_value=None), \
             mock.patch.object(engine.Engine, "_download_one",
                               return_value=5.0) as download:
            self.eng._download_phase(self.node, [self.row("1.1.1.1", 10)])
        self.assertEqual([call.args[1] for call in download.call_args_list],
                         ["9.9.9.9", "1.1.1.1"])
        self.assertTrue(any("不在本轮候选内，直接补测" in line
                            for line in self.log.lines))

    def test_current_best_enters_download_with_no_latency_rows(self):
        # 延迟探测一个都没保留时，当前已发布的最优 IP 仍要直接进下载列表。
        self.cfg["download_count"] = 5
        with mock.patch.object(engine.Engine, "_current_best_ip",
                               return_value="9.9.9.9"), \
             mock.patch.object(engine.Engine, "_previous_row", return_value=None), \
             mock.patch.object(engine.asn, "lookup", return_value=None), \
             mock.patch.object(engine.Engine, "_download_one",
                               return_value=5.0) as download:
            _rows, kept, details = self.eng._download_phase(self.node, [])
        self.assertEqual([call.args[1] for call in download.call_args_list],
                         ["9.9.9.9"])
        self.assertEqual(kept, 1)
        self.assertIn("a", self.eng.fresh_nodes)
        self.assertEqual(details[0]["ip"], "9.9.9.9")

    def test_no_rows_and_no_current_best_skips_downloads(self):
        with mock.patch.object(engine.Engine, "_current_best_ip",
                               return_value=""), \
             mock.patch.object(engine.Engine, "_download_one") as download:
            rows, kept, details = self.eng._download_phase(self.node, [])
        self.assertEqual((rows, kept, details), ([], 0, []))
        download.assert_not_called()

    def test_filter_keeps_first_asn_rep_over_threshold(self):
        with mock.patch.object(engine.asn, "lookup",
                               side_effect=lambda ip: {"asn": "AS1" if ip.startswith("1.") else "AS2"}):
            seen = set()
            keep, reason = self.eng._filter_candidate(
                self.node, "1.1.1.1", 500.0, 0.0, seen_asns=seen)
            self.assertEqual((keep, reason), (1, "机房代表"))
            # Same datacenter again: thresholds apply (500ms > 100ms cap).
            keep, _reason = self.eng._filter_candidate(
                self.node, "1.1.1.2", 500.0, 0.0, seen_asns=seen)
            self.assertEqual(keep, 0)
            # A different datacenter still gets its representative slot.
            keep, reason = self.eng._filter_candidate(
                self.node, "2.2.2.2", 500.0, 0.0, seen_asns=seen)
            self.assertEqual((keep, reason), (1, "机房代表"))

    def test_filter_skips_thresholds_for_current_best_asn(self):
        with mock.patch.object(engine.asn, "lookup", return_value={"asn": "AS1"}):
            keep, reason = self.eng._filter_candidate(
                self.node, "1.1.1.2", 500.0, 0.0,
                current_ip="1.1.1.1", current_asn="AS1", seen_asns={"AS1"})
        self.assertEqual((keep, reason), (1, "当前最优同机房"))

    def test_current_best_ip_matches_by_stable_id_first(self):
        rows = [result.Row(ip="1.1.1.1", node="renamed", node_id="id-a"),
                result.Row(ip="2.2.2.2", node="a")]
        with mock.patch.object(engine.result, "read_result",
                               return_value=(rows, "")):
            self.assertEqual(self.eng._current_best_ip(self.node), "1.1.1.1")
            self.assertEqual(
                self.eng._current_best_ip({"name": "a", "id": ""}), "2.2.2.2")


if __name__ == "__main__":
    unittest.main()
