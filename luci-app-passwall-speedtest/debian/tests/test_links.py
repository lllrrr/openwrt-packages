import base64
import json
import unittest

from cfpick import links


def b64(value):
    if isinstance(value, str):
        value = value.encode()
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


class VlessTests(unittest.TestCase):
    def test_reality_tcp(self):
        link = ("vless://11111111-2222-3333-4444-555555555555@cf.example.com:443"
                "?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome"
                "&pbk=PUBLICKEY&sid=abcd&type=tcp&flow=xtls-rprx-vision#JP-01")
        parsed = links.parse_link(link)
        self.assertEqual(parsed.name, "JP-01")
        self.assertEqual(parsed.type, "vless")
        self.assertEqual(parsed.server, "cf.example.com")
        self.assertEqual(parsed.port, 443)
        self.assertTrue(parsed.proxy["tls"])
        self.assertEqual(parsed.proxy["servername"], "www.microsoft.com")
        self.assertEqual(parsed.proxy["flow"], "xtls-rprx-vision")
        self.assertEqual(parsed.proxy["reality-opts"]["public-key"], "PUBLICKEY")
        self.assertEqual(parsed.proxy["reality-opts"]["short-id"], "abcd")

    def test_websocket_host_and_path(self):
        link = ("vless://uuid@origin.example.com:8443?encryption=none&security=tls"
                "&sni=edge.example.com&fp=firefox&type=ws&host=cdn.example.com"
                "&path=%2Fws%3Fed%3D2048#WS")
        parsed = links.parse_link(link)
        self.assertEqual(parsed.proxy["network"], "ws")
        self.assertEqual(parsed.proxy["ws-opts"]["path"], "/ws?ed=2048")
        self.assertEqual(parsed.proxy["ws-opts"]["headers"]["Host"], "cdn.example.com")
        self.assertEqual(parsed.proxy["client-fingerprint"], "firefox")

    def test_missing_reality_key(self):
        with self.assertRaises(links.LinkError):
            links.parse_link("vless://uuid@host:443?security=reality&sni=x#bad")

    def test_proxy_for_ip(self):
        parsed = links.parse_link("vless://uuid@host:443?security=tls#n")
        proxy = parsed.proxy_for_ip("1.2.3.4")
        self.assertEqual(proxy["server"], "1.2.3.4")
        self.assertEqual(proxy["name"], "cfpick")
        self.assertEqual(parsed.proxy["server"], "host")


class VmessTests(unittest.TestCase):
    def test_ws_tls_json(self):
        payload = {
            "v": "2", "ps": "VM", "add": "origin.example.com", "port": "443",
            "id": "11111111-2222-3333-4444-555555555555", "aid": "0",
            "scy": "auto", "net": "ws", "type": "none", "host": "cdn.example.com",
            "path": "/ray", "tls": "tls", "sni": "edge.example.com",
        }
        parsed = links.parse_link("vmess://" + b64(json.dumps(payload)))
        self.assertEqual(parsed.name, "VM")
        self.assertEqual(parsed.proxy["type"], "vmess")
        self.assertEqual(parsed.proxy["alterId"], 0)
        self.assertTrue(parsed.proxy["tls"])
        self.assertEqual(parsed.proxy["network"], "ws")
        self.assertEqual(parsed.proxy["ws-opts"]["path"], "/ray")
        self.assertEqual(parsed.proxy["ws-opts"]["headers"]["Host"], "cdn.example.com")


class TrojanTests(unittest.TestCase):
    def test_grpc(self):
        parsed = links.parse_link(
            "trojan://secret@edge.example.com:8443?sni=edge.example.com"
            "&type=grpc&serviceName=grpcsvc&allowInsecure=1#TR")
        self.assertEqual(parsed.proxy["password"], "secret")
        self.assertTrue(parsed.proxy["skip-cert-verify"])
        self.assertEqual(parsed.proxy["network"], "grpc")
        self.assertEqual(parsed.proxy["grpc-opts"]["grpc-service-name"], "grpcsvc")


class ShadowsocksTests(unittest.TestCase):
    def test_sip002_with_obfs(self):
        userinfo = b64("aes-256-gcm:secret")
        parsed = links.parse_link(
            "ss://%s@edge.example.com:8388/?plugin=obfs-local%%3Bobfs%%3Dhttp"
            "%%3Bobfs-host%%3Dbing.com#SS" % userinfo)
        self.assertEqual(parsed.proxy["cipher"], "aes-256-gcm")
        self.assertEqual(parsed.proxy["password"], "secret")
        self.assertEqual(parsed.proxy["plugin"], "obfs")
        self.assertEqual(parsed.proxy["plugin-opts"]["mode"], "http")
        self.assertEqual(parsed.proxy["plugin-opts"]["host"], "bing.com")

    def test_legacy_base64(self):
        payload = b64("chacha20-ietf-poly1305:pass@edge.example.com:8388")
        parsed = links.parse_link("ss://" + payload + "#legacy")
        self.assertEqual(parsed.name, "legacy")
        self.assertEqual(parsed.server, "edge.example.com")
        self.assertEqual(parsed.port, 8388)


class Hysteria2Tests(unittest.TestCase):
    def test_basic(self):
        parsed = links.parse_link(
            "hysteria2://secret@hy.example.com:443?sni=hy.example.com"
            "&insecure=1&obfs=salamander&obfs-password=ob#HY")
        self.assertEqual(parsed.proxy["type"], "hysteria2")
        self.assertEqual(parsed.proxy["password"], "secret")
        self.assertTrue(parsed.proxy["skip-cert-verify"])
        self.assertEqual(parsed.proxy["obfs"], "salamander")
        self.assertEqual(parsed.proxy["obfs-password"], "ob")


class XhttpTests(unittest.TestCase):
    def test_vmess_xhttp(self):
        payload = {
            "v": "2", "ps": "xhttp", "add": "bag.example.com", "port": 443,
            "id": "11111111-2222-3333-4444-555555555555", "aid": "0",
            "net": "xhttp", "type": "none", "host": "", "path": "/abc",
            "mode": "stream-up", "tls": "tls", "sni": "sni.example.com",
            "alpn": "h2,http/1.1",
        }
        parsed = links.parse_link("vmess://" + b64(json.dumps(payload)))
        proxy = parsed.proxy
        self.assertEqual(proxy["network"], "xhttp")
        self.assertEqual(proxy["xhttp-opts"]["path"], "/abc")
        self.assertEqual(proxy["xhttp-opts"]["mode"], "stream-up")
        self.assertNotIn("host", proxy["xhttp-opts"])
        self.assertEqual(proxy["servername"], "sni.example.com")
        self.assertEqual(proxy["alpn"], ["h2", "http/1.1"])

    def test_vless_xhttp(self):
        parsed = links.parse_link(
            "vless://uuid@edge.example.com:443?encryption=none&security=tls"
            "&sni=edge.example.com&type=xhttp&host=cdn.example.com"
            "&path=%2Fxhttp&mode=stream-up&alpn=h2%2Chttp%2F1.1#x")
        proxy = parsed.proxy
        self.assertEqual(proxy["network"], "xhttp")
        self.assertEqual(proxy["xhttp-opts"],
                         {"path": "/xhttp", "mode": "stream-up", "host": "cdn.example.com"})
        self.assertEqual(proxy["alpn"], ["h2", "http/1.1"])


class InvalidTests(unittest.TestCase):
    def test_unsupported(self):
        with self.assertRaises(links.LinkError):
            links.parse_link("http://example.com")

    def test_empty(self):
        with self.assertRaises(links.LinkError):
            links.parse_link("")

    def test_trojan_without_password(self):
        with self.assertRaises(links.LinkError):
            links.parse_link("trojan://edge.example.com:443#x")


if __name__ == "__main__":
    unittest.main()
