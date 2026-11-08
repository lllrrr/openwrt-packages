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


if __name__ == "__main__":
    unittest.main()
