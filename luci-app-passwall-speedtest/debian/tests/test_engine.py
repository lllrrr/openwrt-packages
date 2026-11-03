"""Engine node selection: empty means every enabled node."""

import unittest
from types import SimpleNamespace
from unittest import mock

from cfpick import engine


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


if __name__ == "__main__":
    unittest.main()
