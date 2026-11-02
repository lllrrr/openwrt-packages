"""Write each node's best IPs back to Cloudflare DNS.

The Debian port still only exports results by default.  DDNS is the one opt-in
write-back: a node may carry its own ``ddns_domain`` (a full hostname), and
after a run that node's best IPs are written to the hostname's A/AAAA records.
Nodes without a domain are speed-tested only and never touch DNS.

Only the Cloudflare API is implemented.  Requests deliberately bypass any
``http_proxy`` environment, because the API call must not depend on the proxy
setup being tested.
"""

import ipaddress
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.cloudflare.com/client/v4"
USER_AGENT = "cfpick/1.0 (+https://github.com/urbanescavenger/CFPick)"
TOKEN_MASK = "***"
_HOSTNAME_RE = re.compile(
    r"^(?=.{1,253}$)"
    r"([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)


class DdnsError(RuntimeError):
    pass


def _now():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def _clean_domain(value):
    return str(value or "").strip().lower().rstrip(".")


def _error_text(status, payload):
    messages = []
    if isinstance(payload, dict):
        for item in payload.get("errors") or []:
            if not isinstance(item, dict):
                continue
            code = item.get("code")
            message = str(item.get("message") or "").strip()
            messages.append(("%s %s" % (code, message)).strip())
    if not messages:
        messages.append("HTTP %s" % status if status else "未知错误")
    return "；".join(messages)


def _http_transport(url, method, headers, body, timeout):
    """Return ``(status, payload)``.  HTTP errors keep Cloudflare's JSON body."""
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    # Do not inherit http_proxy/https_proxy: the DNS API should work even when
    # the machine has no working system proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as response:
            raw = response.read()
            status = getattr(response, "status", 200)
    except urllib.error.HTTPError as exc:
        raw = exc.read() or b""
        status = exc.code
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise DdnsError("Cloudflare API 连接失败: %s" % exc)
    try:
        payload = json.loads(raw.decode("utf-8", "replace")) if raw else {}
    except ValueError:
        raise DdnsError("Cloudflare API 返回了无法解析的响应（HTTP %s）" % status)
    return status, payload


class CloudflareClient:
    def __init__(self, token, timeout=15, transport=None):
        self.token = token
        self.timeout = int(timeout)
        self._transport = transport or _http_transport
        self._zone_cache = {}

    def _call_raw(self, method, path, body=None):
        headers = {
            "Authorization": "Bearer %s" % self.token,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }
        status, payload = self._transport(API_BASE + path, method, headers, body, self.timeout)
        if not isinstance(payload, dict):
            raise DdnsError("Cloudflare API 返回格式异常（HTTP %s）" % status)
        if not payload.get("success"):
            raise DdnsError(_error_text(status, payload))
        return payload

    def _call(self, method, path, body=None):
        return self._call_raw(method, path, body).get("result")

    def zone_id(self, zone_id="", zone_name="", domain=""):
        """Resolve the zone for a hostname; ``zone_id`` wins when configured."""
        if zone_id:
            return zone_id
        candidates = [zone_name] if zone_name else _zone_candidates(domain)
        for candidate in candidates:
            key = candidate.lower()
            if key in self._zone_cache:
                return self._zone_cache[key]
            query = urllib.parse.urlencode({"name": candidate, "per_page": 50})
            payload = self._call_raw("GET", "/zones?" + query)
            for zone in payload.get("result") or []:
                if str(zone.get("name", "")).lower() == key and zone.get("id"):
                    self._zone_cache[key] = str(zone["id"])
                    return str(zone["id"])
        raise DdnsError(
            "找不到域名 %s 所属的 Cloudflare Zone，请填写 Zone ID 或 Zone 名称"
            % (zone_name or domain))

    def list_records(self, zone_id, name):
        records = []
        page = 1
        while True:
            query = urllib.parse.urlencode({"name": name, "per_page": 100, "page": page})
            payload = self._call_raw(
                "GET", "/zones/%s/dns_records?%s" % (zone_id, query))
            records.extend(payload.get("result") or [])
            info = payload.get("result_info") or {}
            try:
                total = int(info.get("total_pages") or 1)
            except (TypeError, ValueError):
                total = 1
            if page >= total:
                return records
            page += 1

    def update_record(self, zone_id, record_id, **fields):
        return self._call(
            "PUT", "/zones/%s/dns_records/%s" % (zone_id, record_id), fields)

    def create_record(self, zone_id, **fields):
        return self._call("POST", "/zones/%s/dns_records" % zone_id, fields)


def _zone_candidates(domain):
    labels = [part for part in _clean_domain(domain).split(".") if part]
    return [".".join(labels[index:]) for index in range(0, max(0, len(labels) - 1))]


def _record_differs(record, ttl, proxied):
    try:
        current_ttl = int(record.get("ttl", 0))
    except (TypeError, ValueError):
        current_ttl = 0
    return current_ttl != int(ttl) or bool(record.get("proxied")) != bool(proxied)


def _select(cfg, nodes, rows):
    """Return the per-node write plan without touching the network."""
    ddns_cfg = cfg.get("ddns") or {}
    try:
        count = int(ddns_cfg.get("ip_count") or 1)
    except (TypeError, ValueError):
        count = 1
    count = max(1, min(count, 10))

    by_node = {}
    for row in rows:
        if row.node:
            by_node.setdefault(row.node, []).append(row)

    zone_name = _clean_domain((ddns_cfg.get("cloudflare") or {}).get("zone_name"))
    planned = []
    for node in nodes:
        if node.get("enabled") is False:
            continue
        domain = _clean_domain(node.get("ddns_domain"))
        if not domain:
            # No domain configured: speed test only, never write DNS.
            continue
        # Accept a bare label ("jp") when a zone name is configured.
        if zone_name and "." not in domain:
            domain = "%s.%s" % (domain, zone_name)
        name = str(node.get("name") or "")
        entry = {
            "node": name,
            "domain": domain,
            "ips": [],
            "types": {},
            "error": "",
        }
        if not _HOSTNAME_RE.match(domain):
            entry["error"] = "DDNS 域名格式不正确"
            planned.append(entry)
            continue
        if zone_name and domain != zone_name and not domain.endswith("." + zone_name):
            entry["error"] = "域名不在配置的 Zone %s 内" % zone_name
            planned.append(entry)
            continue
        selected = by_node.get(name) or []
        selected = selected[:count]
        if not selected:
            entry["error"] = "本次没有可用结果"
            planned.append(entry)
            continue
        groups = {}
        for row in selected:
            try:
                version = ipaddress.ip_address(str(row.ip)).version
            except ValueError:
                continue
            record_type = "AAAA" if version == 6 else "A"
            groups.setdefault(record_type, []).append(str(row.ip))
        entry["types"] = groups
        entry["ips"] = [str(row.ip) for row in selected]
        if not groups:
            entry["error"] = "没有可写入的 IP"
        planned.append(entry)
    return planned


def preview(cfg, nodes, rows, when=""):
    """Describe what a run would write; safe to call without credentials."""
    ddns_cfg = cfg.get("ddns") or {}
    cloudflare = ddns_cfg.get("cloudflare") or {}
    error = ""
    if not str(cloudflare.get("api_token") or "").strip():
        error = "未配置 Cloudflare API Token"
    planned = _select(cfg, nodes, rows)
    if not planned and not error:
        error = "没有节点配置 DDNS 域名（这些节点只测速）"
    return {
        "enabled": bool(ddns_cfg.get("enabled")),
        "provider": "cloudflare",
        "at": when or "",
        "nodes": planned,
        "error": error,
    }


def apply(cfg, nodes, rows, log=None, client=None, when=""):
    """Write each configured node's best IPs to Cloudflare DNS.

    Returns a JSON-friendly report.  Callers must treat failures as non-fatal:
    a DNS error never invalidates a speed-test result.
    """
    log = log or (lambda message: None)
    ddns_cfg = cfg.get("ddns") or {}
    cloudflare = ddns_cfg.get("cloudflare") or {}
    report = {
        "enabled": bool(ddns_cfg.get("enabled")),
        "provider": "cloudflare",
        "at": when or _now(),
        "ok": True,
        "nodes": [],
        "updated": 0,
        "created": 0,
        "unchanged": 0,
        "failed": 0,
        "error": "",
    }
    if not report["enabled"]:
        return report

    token = str(cloudflare.get("api_token") or "").strip()
    planned = _select(cfg, nodes, rows)
    if not token:
        report.update(ok=False, error="未配置 Cloudflare API Token")
        log("DDNS 写入失败: %s" % report["error"])
        return report
    if not planned:
        report["message"] = "没有节点配置 DDNS 域名，跳过"
        log("DDNS: 没有节点配置 DDNS 域名，跳过")
        return report

    try:
        ttl = int(ddns_cfg.get("ttl") or 300)
    except (TypeError, ValueError):
        ttl = 300
    proxied = bool(cloudflare.get("proxied"))
    # Cloudflare requires TTL=1 (automatic) for proxied records; it ignores
    # the value otherwise.
    if proxied:
        ttl = 1
    zone_id_cfg = str(cloudflare.get("zone_id") or "").strip()
    zone_name = _clean_domain(cloudflare.get("zone_name"))
    api = client or CloudflareClient(token)

    for item in planned:
        entry = {
            "node": item["node"],
            "domain": item["domain"],
            "ips": item["ips"],
            "types": item["types"],
            "created": 0,
            "updated": 0,
            "unchanged": 0,
            "extra": 0,
            "error": item.get("error", ""),
        }
        if entry["error"]:
            report["failed"] += 1
            report["nodes"].append(entry)
            log("DDNS [%s] %s: %s" % (entry["node"], entry["domain"], entry["error"]))
            continue
        try:
            zone_id = api.zone_id(zone_id_cfg, zone_name, entry["domain"])
            existing = api.list_records(zone_id, entry["domain"])
            for record_type, ips in sorted(item["types"].items()):
                counts = _apply_records(
                    api, zone_id, entry["domain"], record_type, ips,
                    ttl, proxied, existing, log)
                for key in ("created", "updated", "unchanged", "extra"):
                    entry[key] += counts[key]
            for key in ("created", "updated", "unchanged"):
                report[key] += entry[key]
            if entry["created"] or entry["updated"] or entry["unchanged"]:
                log("DDNS [%s] %s: %s（新建 %d / 更新 %d / 无变化 %d%s）" % (
                    entry["node"], entry["domain"],
                    " ".join(entry["ips"]),
                    entry["created"], entry["updated"], entry["unchanged"],
                    "，另有 %d 条旧记录未动" % entry["extra"] if entry["extra"] else ""))
        except DdnsError as exc:
            entry["error"] = str(exc)
            report["failed"] += 1
            log("DDNS [%s] %s 写入失败: %s" % (entry["node"], entry["domain"], exc))
        report["nodes"].append(entry)

    if report["failed"]:
        report["ok"] = False
        report["error"] = "%d 个节点写入失败" % report["failed"]
    return report


def _apply_records(api, zone_id, name, record_type, ips, ttl, proxied, existing, log):
    records = [record for record in existing if record.get("type") == record_type]
    records.sort(key=lambda record: str(record.get("id", "")))
    counts = {"created": 0, "updated": 0, "unchanged": 0, "extra": 0}
    used = set()
    pending = []

    # Keep records whose content already matches (and only fix TTL/proxied when
    # needed); everything else is rewritten in place before creating new ones.
    for ip in ips:
        match = next((record for record in records
                      if str(record.get("id")) not in used
                      and record.get("content") == ip
                      and not _record_differs(record, ttl, proxied)), None)
        if match is not None:
            used.add(str(match.get("id")))
            counts["unchanged"] += 1
        else:
            pending.append(ip)

    for ip in pending:
        record = next((item for item in records
                       if str(item.get("id")) not in used), None)
        fields = {"type": record_type, "name": name, "content": ip,
                  "ttl": int(ttl), "proxied": bool(proxied)}
        if record is None:
            api.create_record(zone_id, **fields)
            counts["created"] += 1
            continue
        used.add(str(record.get("id")))
        if record.get("proxied") and not proxied:
            log("DDNS %s: %s 记录原为橙云代理，已改为 DNS only" % (name, record_type))
        api.update_record(zone_id, str(record.get("id")), **fields)
        counts["updated"] += 1

    counts["extra"] = len([record for record in records
                           if str(record.get("id")) not in used])
    if counts["extra"]:
        log("DDNS %s: 还有 %d 条旧的 %s 记录未使用，未自动删除" % (
            name, counts["extra"], record_type))
    return counts
