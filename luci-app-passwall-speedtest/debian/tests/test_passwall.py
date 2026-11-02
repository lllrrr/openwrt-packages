import unittest
from unittest import mock

from cfpick import core, links, passwall


VMESS_XHTTP = {
    "type": "Xray", "protocol": "vmess", "address": "172.237.6.212",
    "port": "443", "uuid": "2a104414-bc6e-4f0a-aad7-8549a70ae3de",
    "security": "auto", "tls": "1", "tls_serverName": "vpst.example.com",
    "alpn": "h3,h2,http/1.1", "transport": "xhttp", "xhttp_path": "/abc",
    "xhttp_mode": "stream-up", "fingerprint": "chrome", "remarks": "vps xhttp",
}

VLESS_WS = {
    "type": "Xray", "protocol": "vless", "address": "edt2.example.com",
    "port": "443", "uuid": "612cf24d-fdee-4b9c-825c-65af76040564",
    "tls": "1", "tls_serverName": "edt2.example.com", "transport": "ws",
    "ws_path": "/", "ws_host": "edt2.example.com", "fingerprint": "chrome",
    "encryption": "none", "remarks": "edgetunnel",
}

VLESS_REALITY = {
    "type": "Xray", "protocol": "vless", "address": "bag.example.com",
    "port": "27469", "uuid": "7c237106-d50b-4608-fe66-c158f8911705",
    "tls": "1", "reality": "1", "tls_serverName": "www.example.com",
    "reality_publicKey": "PUBKEY", "reality_shortId": "abcd",
    "fingerprint": "chrome", "transport": "raw", "encryption": "none",
    "remarks": "reality",
}


class LinkConversionTests(unittest.TestCase):
    def _link(self, data):
        with mock.patch.object(passwall, "_uci_show", return_value=data):
            return passwall.node_link("node1")

    def test_vmess_xhttp(self):
        parsed = links.parse_link(self._link(VMESS_XHTTP))
        proxy = parsed.proxy_for_ip("1.2.3.4")
        self.assertEqual(proxy["type"], "vmess")
        self.assertEqual(proxy["network"], "xhttp")
        self.assertEqual(proxy["servername"], "vpst.example.com")
        self.assertEqual(proxy["xhttp-opts"]["mode"], "stream-up")
        self.assertEqual(proxy["xhttp-opts"]["path"], "/abc")

    def test_vless_ws(self):
        parsed = links.parse_link(self._link(VLESS_WS))
        proxy = parsed.proxy_for_ip("1.2.3.4")
        self.assertEqual(proxy["type"], "vless")
        self.assertEqual(proxy["network"], "ws")
        self.assertEqual(proxy["ws-opts"]["headers"]["Host"], "edt2.example.com")
        self.assertEqual(proxy["servername"], "edt2.example.com")

    def test_vless_reality(self):
        parsed = links.parse_link(self._link(VLESS_REALITY))
        proxy = parsed.proxy_for_ip("1.2.3.4")
        self.assertEqual(proxy["reality-opts"]["public-key"], "PUBKEY")
        self.assertEqual(proxy["reality-opts"]["short-id"], "abcd")
        core.validate_proxy(proxy, "xray")
        core.validate_proxy(proxy, "mihomo")

    def test_mihomo_rejects_vless_encryption(self):
        data = dict(VLESS_WS)
        data["encryption"] = "mlkem768x25519plus.native.0rtt.abc"
        parsed = links.parse_link(self._link(data))
        proxy = parsed.proxy_for_ip("1.2.3.4")
        with self.assertRaises(core.CoreError):
            core.validate_proxy(proxy, "mihomo")
        core.validate_proxy(proxy, "xray")

    def test_unsupported_protocol(self):
        with self.assertRaises(links.LinkError):
            self._link({"protocol": "wireguard", "address": "1.2.3.4", "port": 1})


class UciSettingsTests(unittest.TestCase):
    def test_standalone_config(self):
        with mock.patch.object(passwall, "_uci_config", return_value={
                "global": {"standalone_enabled": "1", "standalone_core": "mihomo"}}):
            self.assertEqual(passwall.standalone_config(),
                             {"enabled": True, "core": "mihomo"})

    def test_ddns_config(self):
        with mock.patch.object(passwall, "_uci_config", return_value={
                "global": {
                    "ddns_enabled": "1", "ddns_api_token": "t",
                    "ddns_zone_name": "example.com", "ddns_ttl": "120",
                    "ddns_ip_count": "3", "ddns_proxied": "1",
                }}):
            cfg = passwall.ddns_config()
        self.assertTrue(cfg["enabled"])
        self.assertEqual(cfg["ip_count"], 3)
        self.assertEqual(cfg["ttl"], 120)
        self.assertEqual(cfg["cloudflare"]["zone_name"], "example.com")
        self.assertTrue(cfg["cloudflare"]["proxied"])

    def test_node_ip_ddns_uses_remarks(self):
        with mock.patch.object(passwall, "_uci_config", return_value={
                "@node_ip[0]": {"node": "abc", "ddns_domain": "jp.example.com"},
                "@node_ip[1]": {"node": "def", "ddns_domain": "  "},
        }), mock.patch.object(passwall, "_uci_get_raw",
                              return_value="JP, node"):
            nodes = passwall.node_ip_ddns()
        self.assertEqual(nodes, [{"node": "abc", "name": "JP  node",
                                  "domain": "jp.example.com"}])


if __name__ == "__main__":
    unittest.main()
