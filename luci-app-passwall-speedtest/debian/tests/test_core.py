import base64
import json
import socket
import tempfile
import unittest
from pathlib import Path

from cfpick import core, links
from cfpick.miniyaml import dumps


class MiniYamlTests(unittest.TestCase):
    def test_nested_structures(self):
        text = dumps({
            "socks-port": 48900,
            "proxies": [{
                "name": "cfpick",
                "type": "vless",
                "server": "1.2.3.4",
                "reality-opts": {"public-key": "abc", "short-id": "12"},
                "udp": True,
            }],
            "rules": ["MATCH,cfpick"],
        })
        self.assertIn("socks-port: 48900", text)
        self.assertIn('server: "1.2.3.4"', text)
        self.assertIn('public-key: "abc"', text)
        self.assertIn("- name: \"cfpick\"", text)
        self.assertIn("- \"MATCH,cfpick\"", text)


class CoreConfigTests(unittest.TestCase):
    def setUp(self):
        self.parsed = links.parse_link(
            "vless://uuid@origin.example.com:443?security=tls&sni=edge.example.com#n")

    def test_build_config_replaces_server(self):
        proxy = self.parsed.proxy_for_ip("9.9.9.9")
        payload = core.build_config(proxy, 48900)
        self.assertEqual(payload["socks-port"], 48900)
        self.assertEqual(payload["proxies"][0]["server"], "9.9.9.9")
        self.assertEqual(payload["proxies"][0]["name"], "cfpick")
        self.assertEqual(payload["rules"], ["MATCH,cfpick"])
        # PassWall on OpenWrt returns packets carrying this mark, so the test
        # core is not proxied a second time by the router's global node.
        self.assertEqual(payload["routing-mark"], 255)
        self.assertFalse(payload["dns"]["enable"])

    def test_write_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cfg.yaml"
            core.write_config(path, self.parsed.proxy_for_ip("9.9.9.9"), 49000)
            text = path.read_text(encoding="utf-8")
            self.assertIn('server: "9.9.9.9"', text)
            self.assertIn("socks-port: 49000", text)

    def test_free_port(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            busy = sock.getsockname()[1]
            port = core.free_port(busy)
            self.assertNotEqual(port, busy)
            self.assertGreater(port, 0)

    def test_nonexistent_core(self):
        with self.assertRaises(core.CoreError):
            core.ensure_core({"core": {"path": "/nonexistent/mihomo"}})

    def test_route_mark_can_be_disabled(self):
        import os
        from unittest import mock
        proxy = self.parsed.proxy_for_ip("9.9.9.9")
        with mock.patch.dict(os.environ, {"CFPICK_MARK": "0"}):
            xray = core.build_config(proxy, 48900, core_type="xray")
            self.assertNotIn("sockopt", xray["outbounds"][0]["streamSettings"])
            mihomo = core.build_config(proxy, 48900)
            self.assertNotIn("routing-mark", mihomo)

    def test_custom_dns(self):
        payload = core.build_config(self.parsed.proxy_for_ip("9.9.9.9"), 48900,
                                    dns_nameserver="223.5.5.5")
        self.assertTrue(payload["dns"]["enable"])
        self.assertEqual(payload["dns"]["nameserver"], ["223.5.5.5"])

    def test_xray_vless_tls_json(self):
        proxy = self.parsed.proxy_for_ip("9.9.9.9")
        payload = core.build_config(proxy, 48900, core_type="xray")
        self.assertEqual(payload["inbounds"][0]["protocol"], "socks")
        self.assertEqual(payload["inbounds"][0]["port"], 48900)
        outbound = payload["outbounds"][0]
        self.assertEqual(outbound["protocol"], "vless")
        self.assertEqual(outbound["settings"]["vnext"][0]["address"], "9.9.9.9")
        self.assertEqual(outbound["streamSettings"]["security"], "tls")
        self.assertEqual(outbound["streamSettings"]["tlsSettings"]["serverName"],
                         "edge.example.com")
        self.assertEqual(outbound["streamSettings"]["sockopt"], {"mark": 255})

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cfg.json"
            core.write_config(path, proxy, 48900, core_type="xray")
            import json
            loaded = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(loaded["outbounds"][0]["settings"]["vnext"][0]["address"], "9.9.9.9")

    def test_xray_reality(self):
        parsed = links.parse_link(
            "vless://uuid@host:443?security=reality&sni=www.example.com"
            "&pbk=PUBLICKEY&sid=abcd&type=tcp&flow=xtls-rprx-vision#r")
        payload = core.build_config(parsed.proxy_for_ip("1.2.3.4"), 48900, core_type="xray")
        stream = payload["outbounds"][0]["streamSettings"]
        self.assertEqual(stream["security"], "reality")
        self.assertEqual(stream["realitySettings"]["publicKey"], "PUBLICKEY")
        self.assertEqual(payload["outbounds"][0]["settings"]["vnext"][0]["users"][0]["flow"],
                         "xtls-rprx-vision")

    def test_xray_trojan_forces_tls(self):
        parsed = links.parse_link("trojan://secret@edge.example.com:443?sni=edge.example.com#t")
        payload = core.build_config(parsed.proxy_for_ip("1.2.3.4"), 48900, core_type="xray")
        stream = payload["outbounds"][0]["streamSettings"]
        self.assertEqual(stream["security"], "tls")
        self.assertEqual(stream["tlsSettings"]["serverName"], "edge.example.com")

    def test_xray_ws(self):
        parsed = links.parse_link(
            "vless://uuid@host:443?security=tls&sni=edge.example.com&type=ws"
            "&host=cdn.example.com&path=%2Fws#w")
        payload = core.build_config(parsed.proxy_for_ip("1.2.3.4"), 48900, core_type="xray")
        stream = payload["outbounds"][0]["streamSettings"]
        self.assertEqual(stream["network"], "ws")
        self.assertEqual(stream["wsSettings"]["path"], "/ws")
        self.assertEqual(stream["wsSettings"]["host"], "cdn.example.com")

    def _vmess_xhttp_link(self):
        payload = {
            "v": "2", "ps": "xhttp", "add": "bag.example.com", "port": 443,
            "id": "11111111-2222-3333-4444-555555555555", "aid": "0",
            "net": "xhttp", "type": "none", "host": "", "path": "/abc",
            "mode": "stream-up", "tls": "tls", "sni": "sni.example.com",
            "alpn": "h2,http/1.1",
        }
        raw = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
        return "vmess://" + raw

    def test_xray_vmess_xhttp(self):
        parsed = links.parse_link(self._vmess_xhttp_link())
        core.validate_proxy(parsed.proxy, "xray")
        payload = core.build_config(parsed.proxy_for_ip("1.2.3.4"), 48900, core_type="xray")
        outbound = payload["outbounds"][0]
        stream = outbound["streamSettings"]
        self.assertEqual(outbound["protocol"], "vmess")
        self.assertEqual(stream["network"], "xhttp")
        self.assertEqual(stream["xhttpSettings"]["path"], "/abc")
        self.assertEqual(stream["xhttpSettings"]["mode"], "stream-up")
        self.assertEqual(stream["tlsSettings"]["serverName"], "sni.example.com")
        self.assertEqual(stream["tlsSettings"]["alpn"], ["h2", "http/1.1"])

    def test_mihomo_xhttp_restriction(self):
        parsed = links.parse_link(self._vmess_xhttp_link())
        with self.assertRaises(core.CoreError):
            core.validate_proxy(parsed.proxy, "mihomo")
        vless = links.parse_link(
            "vless://uuid@edge.example.com:443?security=tls&sni=edge.example.com"
            "&type=xhttp&host=cdn.example.com&path=%2Fx&mode=stream-up#x")
        core.validate_proxy(vless.proxy, "mihomo")

    def test_xray_vless_xhttp(self):
        parsed = links.parse_link(
            "vless://uuid@edge.example.com:443?security=tls&sni=edge.example.com"
            "&type=xhttp&host=cdn.example.com&path=%2Fx&mode=stream-up#x")
        payload = core.build_config(parsed.proxy_for_ip("1.2.3.4"), 48900, core_type="xray")
        stream = payload["outbounds"][0]["streamSettings"]
        self.assertEqual(stream["network"], "xhttp")
        self.assertEqual(stream["xhttpSettings"],
                         {"path": "/x", "host": "cdn.example.com", "mode": "stream-up"})

    def test_xray_ss_protocol_name(self):
        parsed = links.parse_link(
            "ss://YWVzLTI1Ni1nY206c2VjcmV0@edge.example.com:8388#s")
        payload = core.build_config(parsed.proxy_for_ip("1.2.3.4"), 48900, core_type="xray")
        self.assertEqual(payload["outbounds"][0]["protocol"], "shadowsocks")
        self.assertEqual(payload["outbounds"][0]["settings"]["servers"][0]["method"],
                         "aes-256-gcm")

    def test_xray_rejects_http_transport(self):
        parsed = links.parse_link(
            "vless://uuid@host:443?security=tls&sni=edge.example.com"
            "&type=h2&host=cdn.example.com&path=%2Fh2#h2")
        with self.assertRaises(core.CoreError):
            core.validate_proxy(parsed.proxy, "xray")

    def test_xray_rejects_hysteria2(self):
        parsed = links.parse_link("hysteria2://secret@hy.example.com:443#h")
        with self.assertRaises(core.CoreError):
            core.validate_proxy(parsed.proxy, "xray")

    def test_xray_rejects_ss_plugin(self):
        parsed = links.parse_link(
            "ss://YWVzLTI1Ni1nY206c2VjcmV0@edge.example.com:8388/"
            "?plugin=obfs-local%3Bobfs%3Dhttp#s")
        with self.assertRaises(core.CoreError):
            core.validate_proxy(parsed.proxy, "xray")

    def test_mihomo_accepts_all_supported(self):
        for link in (
            "hysteria2://secret@hy.example.com:443#h",
            "ss://YWVzLTI1Ni1nY206c2VjcmV0@edge.example.com:8388/"
            "?plugin=obfs-local%3Bobfs%3Dhttp#s",
        ):
            core.validate_proxy(links.parse_link(link).proxy, "mihomo")


class AssetSelectionTests(unittest.TestCase):
    ASSETS = [
        {"name": "mihomo-linux-amd64-v1.19.33.gz", "browser_download_url": "plain"},
        {"name": "mihomo-linux-amd64-v1-v1.19.33.gz", "browser_download_url": "v1"},
        {"name": "mihomo-linux-amd64-compatible-v1.19.33.gz", "browser_download_url": "compat"},
        {"name": "mihomo-linux-amd64-v1-go120-v1.19.33.gz", "browser_download_url": "go120"},
        {"name": "mihomo-linux-amd64-v1.19.33.deb", "browser_download_url": "deb"},
        {"name": "mihomo-linux-arm64-v1.19.33.gz", "browser_download_url": "arm"},
    ]

    def test_amd64_prefers_compatible(self):
        asset = core._pick_mihomo_asset(self.ASSETS, "amd64", "v1.19.33")
        self.assertEqual(asset["browser_download_url"], "compat")

    def test_amd64_skips_go_build(self):
        assets = [item for item in self.ASSETS if "go120" not in item["name"]]
        asset = core._pick_mihomo_asset(assets, "amd64", "v1.19.33")
        self.assertNotEqual(asset["browser_download_url"], "go120")

    def test_arm64(self):
        asset = core._pick_mihomo_asset(self.ASSETS, "arm64", "v1.19.33")
        self.assertEqual(asset["browser_download_url"], "arm")

    def test_missing_arch(self):
        with self.assertRaises(core.CoreError):
            core._pick_mihomo_asset(self.ASSETS, "riscv64", "v1.19.33")

    def test_invalid_tag_rejected_before_network(self):
        with self.assertRaises(core.CoreError):
            core._github_release("XTLS/Xray-core", "../../etc/passwd")

    def test_xray_assets(self):
        assets = [
            {"name": "Xray-linux-64.zip", "browser_download_url": "amd64"},
            {"name": "Xray-linux-arm64-v8a.zip", "browser_download_url": "arm64"},
            {"name": "Xray-linux-arm32-v7a.zip", "browser_download_url": "armv7"},
            {"name": "Xray-source.zip", "browser_download_url": "source"},
        ]
        self.assertEqual(core._pick_xray_asset(assets, "amd64")["browser_download_url"], "amd64")
        self.assertEqual(core._pick_xray_asset(assets, "arm64")["browser_download_url"], "arm64")
        self.assertEqual(core._pick_xray_asset(assets, "armv7")["browser_download_url"], "armv7")
        with self.assertRaises(core.CoreError):
            core._pick_xray_asset(assets, "riscv64")


if __name__ == "__main__":
    unittest.main()
