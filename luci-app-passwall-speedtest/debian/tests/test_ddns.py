import json
import unittest
import urllib.parse

from cfpick import config, ddns
from cfpick.result import Row


def make_cfg(**overrides):
    data = {
        "nodes": [
            {"name": "jp", "link": "vless://u@host:443#jp",
             "ddns_domain": "jp.example.com"},
            {"name": "us", "link": "vless://u@host:443#us",
             "ddns_domain": ""},
        ],
        "ddns": {
            "enabled": True,
            "ip_count": 1,
            "ttl": 300,
            "cloudflare": {
                "api_token": "token",
                "zone_id": "",
                "zone_name": "example.com",
                "proxied": False,
            },
        },
    }
    data.update(overrides)
    return config.normalize(data)


def make_rows(entries):
    return [Row(ip=ip, latency=latency, speed=speed, node=node)
            for node, ip, latency, speed in entries]


class FakeTransport:
    """Minimal in-memory Cloudflare API for tests."""

    def __init__(self, zones=None, records=None):
        self.zones = {"example.com": "zone1"} if zones is None else dict(zones)
        self.records = {} if records is None else records
        self.calls = []
        self._next_id = 1

    def __call__(self, url, method, headers, body, timeout):
        parts = urllib.parse.urlsplit(url)
        path = parts.path[len("/client/v4"):]
        query = urllib.parse.parse_qs(parts.query)
        self.calls.append((method, path, body))
        if path == "/zones":
            name = (query.get("name") or [""])[0]
            zone_id = self.zones.get(name)
            result = [{"id": zone_id, "name": name}] if zone_id else []
            return 200, {"success": True, "result": result,
                         "result_info": {"total_pages": 1}}
        if path.endswith("/dns_records") and method == "GET":
            zone_id = path.split("/")[2]
            name = (query.get("name") or [""])[0]
            records = [record for (zid, rname), items in self.records.items()
                       if zid == zone_id and rname == name for record in items]
            return 200, {"success": True, "result": records,
                         "result_info": {"total_pages": 1}}
        if path.endswith("/dns_records") and method == "POST":
            zone_id = path.split("/")[2]
            record = dict(body or {})
            record["id"] = "rec%d" % self._next_id
            self._next_id += 1
            key = (zone_id, record["name"])
            self.records.setdefault(key, []).append(record)
            return 200, {"success": True, "result": record}
        if "/dns_records/" in path and method == "PUT":
            zone_id, record_id = path.split("/")[2], path.split("/")[4]
            for key, items in self.records.items():
                if key[0] != zone_id:
                    continue
                for index, record in enumerate(items):
                    if record.get("id") == record_id:
                        updated = dict(record)
                        updated.update(body or {})
                        items[index] = updated
                        return 200, {"success": True, "result": updated}
            return 404, {"success": False, "errors": [{"code": 81044,
                                                       "message": "Record not found"}]}
        return 404, {"success": False, "errors": [{"code": 7000,
                                                   "message": "unknown path"}]}


class DdnsTests(unittest.TestCase):
    def test_defaults_are_opt_in(self):
        cfg = config.normalize({})
        self.assertFalse(cfg["ddns"]["enabled"])
        self.assertEqual(cfg["ddns"]["provider"], "cloudflare")
        self.assertEqual(cfg["ddns"]["ip_count"], 1)
        self.assertEqual(cfg["ddns"]["ttl"], 300)
        self.assertEqual(cfg["nodes"], [])

    def test_ttl_clamp_and_domain_normalization(self):
        cfg = config.normalize({
            "nodes": [{"name": "n", "link": "vless://u@h:443#n",
                       "ddns_domain": "  JP.Example.COM. "}],
            "ddns": {"ttl": 30, "ip_count": 99},
        })
        self.assertEqual(cfg["nodes"][0]["ddns_domain"], "jp.example.com")
        self.assertEqual(cfg["ddns"]["ttl"], 60)
        self.assertEqual(cfg["ddns"]["ip_count"], 10)
        self.assertEqual(config.normalize({"ddns": {"ttl": 1}})["ddns"]["ttl"], 1)

    def test_preview_only_lists_nodes_with_domain(self):
        cfg = make_cfg()
        rows = make_rows([("jp", "1.1.1.1", 10, 5.0),
                          ("us", "2.2.2.2", 20, 4.0)])
        preview = ddns.preview(cfg, cfg["nodes"], rows)
        self.assertTrue(preview["enabled"])
        self.assertEqual(preview["error"], "")
        self.assertEqual(len(preview["nodes"]), 1)
        self.assertEqual(preview["nodes"][0]["domain"], "jp.example.com")
        self.assertEqual(preview["nodes"][0]["ips"], ["1.1.1.1"])

    def test_bare_subdomain_uses_configured_zone(self):
        cfg = make_cfg()
        cfg["nodes"][0]["ddns_domain"] = "jp"
        preview = ddns.preview(cfg, cfg["nodes"],
                               make_rows([("jp", "1.1.1.1", 10, 5.0)]))
        self.assertEqual(preview["nodes"][0]["domain"], "jp.example.com")
        self.assertEqual(preview["nodes"][0]["error"], "")

    def test_preview_skips_disabled_nodes(self):
        cfg = make_cfg()
        cfg["nodes"][0]["enabled"] = False
        preview = ddns.preview(cfg, cfg["nodes"],
                               make_rows([("jp", "1.1.1.1", 10, 5.0)]))
        self.assertEqual(preview["nodes"], [])

    def test_preview_without_token_reports_error(self):
        cfg = make_cfg(ddns={"enabled": True, "cloudflare": {}})
        preview = ddns.preview(cfg, cfg["nodes"], [])
        self.assertIn("Token", preview["error"])

    def test_apply_creates_missing_record(self):
        cfg = make_cfg()
        transport = FakeTransport()
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "5.6.7.8", 12, 8.0)]),
                            client=client)
        self.assertTrue(report["ok"], report)
        self.assertEqual(report["created"], 1)
        record = transport.records[("zone1", "jp.example.com")][0]
        self.assertEqual(record["type"], "A")
        self.assertEqual(record["content"], "5.6.7.8")
        self.assertFalse(record["proxied"])

    def test_apply_updates_existing_record_idempotently(self):
        cfg = make_cfg()
        transport = FakeTransport(records={
            ("zone1", "jp.example.com"): [{
                "id": "rec-old", "type": "A", "name": "jp.example.com",
                "content": "1.1.1.1", "ttl": 300, "proxied": False,
            }],
        })
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "9.9.9.9", 12, 8.0)]),
                            client=client)
        self.assertEqual(report["updated"], 1)
        self.assertEqual(report["created"], 0)
        self.assertEqual(transport.records[("zone1", "jp.example.com")][0]["id"],
                         "rec-old")
        self.assertEqual(transport.records[("zone1", "jp.example.com")][0]["content"],
                         "9.9.9.9")

        # Same IP again: no PUT/POST at all.
        before = len(transport.calls)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "9.9.9.9", 12, 8.0)]),
                            client=client)
        self.assertEqual(report["unchanged"], 1)
        self.assertEqual(report["updated"], 0)
        mutations = [call for call in transport.calls[before:]
                     if call[0] in ("PUT", "POST")]
        self.assertEqual(mutations, [])

    def test_apply_ipv6_uses_aaaa(self):
        cfg = make_cfg()
        transport = FakeTransport()
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "2606:4700::1", 12, 8.0)]),
                            client=client)
        self.assertEqual(report["created"], 1)
        self.assertEqual(transport.records[("zone1", "jp.example.com")][0]["type"],
                         "AAAA")

    def test_apply_keeps_multiple_ips_in_order_and_count(self):
        cfg = make_cfg(ddns={
            "enabled": True, "ip_count": 2,
            "cloudflare": {"api_token": "token", "zone_name": "example.com"},
        })
        transport = FakeTransport()
        client = ddns.CloudflareClient("token", transport=transport)
        rows = make_rows([
            ("jp", "1.1.1.1", 10, 9.0),
            ("jp", "2.2.2.2", 11, 8.0),
            ("jp", "3.3.3.3", 12, 7.0),
        ])
        ddns.apply(cfg, cfg["nodes"], rows, client=client)
        contents = [record["content"] for record
                    in transport.records[("zone1", "jp.example.com")]]
        self.assertEqual(contents, ["1.1.1.1", "2.2.2.2"])

    def test_zone_is_derived_from_domain(self):
        cfg = make_cfg(ddns={
            "enabled": True,
            "cloudflare": {"api_token": "token"},
        })
        transport = FakeTransport(zones={"example.com": "zone1"})
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "1.1.1.1", 10, 2.0)]),
                            client=client)
        self.assertTrue(report["ok"], report)
        zone_queries = [call for call in transport.calls
                        if call[0] == "GET" and call[1] == "/zones"]
        # The exact hostname is tried first, then its parent domain.
        self.assertLessEqual(len(zone_queries), 2)
        self.assertGreaterEqual(len(zone_queries), 1)
        self.assertEqual(
            transport.records[("zone1", "jp.example.com")][0]["content"], "1.1.1.1")

    def test_missing_zone_is_reported(self):
        cfg = make_cfg(ddns={
            "enabled": True,
            "cloudflare": {"api_token": "token"},
        })
        transport = FakeTransport(zones={})
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "1.1.1.1", 10, 2.0)]),
                            client=client)
        self.assertFalse(report["ok"])
        self.assertIn("Zone", report["nodes"][0]["error"])

    def test_missing_token_does_not_call_api(self):
        cfg = make_cfg(ddns={"enabled": True, "cloudflare": {}})
        transport = FakeTransport()
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "1.1.1.1", 10, 2.0)]),
                            client=client)
        self.assertFalse(report["ok"])
        self.assertIn("Token", report["error"])
        self.assertEqual(transport.calls, [])

    def test_failure_on_one_node_does_not_stop_others(self):
        cfg = make_cfg(ddns={
            "enabled": True,
            "cloudflare": {"api_token": "token"},
        })
        cfg["nodes"][1]["ddns_domain"] = "broken.example.net"
        transport = FakeTransport(zones={"example.com": "zone1"})
        client = ddns.CloudflareClient("token", transport=transport)
        rows = make_rows([("jp", "1.1.1.1", 10, 2.0),
                          ("us", "2.2.2.2", 11, 1.0)])
        report = ddns.apply(cfg, cfg["nodes"], rows, client=client)
        self.assertFalse(report["ok"])
        self.assertEqual(report["failed"], 1)
        self.assertEqual(len(report["nodes"]), 2)
        self.assertEqual(transport.records[("zone1", "jp.example.com")][0]["content"],
                         "1.1.1.1")

    def test_disabled_is_noop(self):
        cfg = make_cfg(ddns={"enabled": False, "cloudflare": {"api_token": "token"}})
        transport = FakeTransport()
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "1.1.1.1", 10, 2.0)]),
                            client=client)
        self.assertFalse(report["enabled"])
        self.assertEqual(report["nodes"], [])
        self.assertEqual(transport.calls, [])

    def test_proxied_record_is_disabled_for_opt_ip_writes(self):
        cfg = make_cfg()
        transport = FakeTransport(records={
            ("zone1", "jp.example.com"): [{
                "id": "rec1", "type": "A", "name": "jp.example.com",
                "content": "1.1.1.1", "ttl": 300, "proxied": True,
            }],
        })
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "1.1.1.1", 10, 2.0)]),
                            client=client)
        self.assertEqual(report["updated"], 1)
        self.assertFalse(transport.records[("zone1", "jp.example.com")][0]["proxied"])

    def test_api_error_message_is_surfaced(self):
        cfg = make_cfg()

        class ErrorTransport:
            def __init__(self):
                self.calls = []

            def __call__(self, url, method, headers, body, timeout):
                self.calls.append((method, url, body))
                if "/zones?" in url:
                    return 200, {"success": True,
                                 "result": [{"id": "zone1", "name": "example.com"}],
                                 "result_info": {"total_pages": 1}}
                return 403, {"success": False, "errors": [
                    {"code": 9109, "message": "Invalid access token"}]}

        transport = ErrorTransport()
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "1.1.1.1", 10, 2.0)]),
                            client=client)
        self.assertFalse(report["ok"])
        self.assertIn("Invalid access token", report["nodes"][0]["error"])

    def test_domain_outside_configured_zone_is_rejected(self):
        cfg = make_cfg()  # ddns.cloudflare.zone_name == example.com
        cfg["nodes"][0]["ddns_domain"] = "jp.other.net"
        transport = FakeTransport()
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "1.1.1.1", 10, 2.0)]),
                            client=client)
        self.assertFalse(report["ok"])
        self.assertIn("Zone", report["nodes"][0]["error"])
        self.assertEqual(transport.calls, [])

    def test_bad_domain_is_reported_without_network(self):
        cfg = make_cfg()
        cfg["nodes"][0]["ddns_domain"] = "not a domain"
        transport = FakeTransport()
        client = ddns.CloudflareClient("token", transport=transport)
        report = ddns.apply(cfg, cfg["nodes"],
                            make_rows([("jp", "1.1.1.1", 10, 2.0)]),
                            client=client)
        self.assertFalse(report["ok"])
        self.assertIn("格式", report["nodes"][0]["error"])
        self.assertEqual(transport.calls, [])


if __name__ == "__main__":
    unittest.main()
