"""Convert a PassWall UCI node into a share link.

The OpenWrt standalone engine reuses the worker nodes selected in the
operations console instead of keeping a second, separate node list.  PassWall
stores nodes in UCI; :func:`node_link` maps the fields that its own Xray /
sing-box generators use back to a share link, which the existing
:mod:`cfpick.links` parser (and therefore both the mihomo and Xray config
builders) understands.

Only the protocols and transports supported by the link parser are mapped.
Anything else raises :class:`cfpick.links.LinkError`; the caller then
falls back to PassWall's ``run_socks`` for that node, so the unified test keeps
working even for exotic nodes.
"""

import base64
import json
import subprocess
from urllib.parse import quote, urlencode

from .links import LinkError


def _uci_show(node_id):
    if not node_id:
        raise LinkError("empty passwall node id")
    try:
        output = subprocess.check_output(
            ["uci", "-q", "show", "passwall." + node_id],
            stderr=subprocess.DEVNULL, timeout=10).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as exc:
        raise LinkError("无法读取 PassWall 节点 %s: %s" % (node_id, exc))
    data = {}
    for line in output.splitlines():
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.rsplit(".", 1)[-1]
        value = value.strip()
        if len(value) >= 2 and value[0] in "'\"" and value[-1] == value[0]:
            value = value[1:-1]
        # `uci show` repeats list options; keep the first value.
        data.setdefault(key, value)
    return data


def _pick(data, *keys, default=""):
    for key in keys:
        value = data.get(key)
        if value is not None and str(value).strip() != "":
            return str(value).strip()
    return default


def _transport(data):
    value = (_pick(data, "transport") or "raw").lower()
    return {"raw": "tcp", "tcp": "tcp"}.get(value, value)


def _security(data):
    if _pick(data, "reality") == "1":
        return "reality"
    if _pick(data, "tls") == "1":
        return "tls"
    return "none"


def _alpn(data):
    value = _pick(data, "alpn")
    return "" if value in ("", "default") else value


def _query(data):
    """Transport + TLS query parameters shared by vless/trojan."""
    transport = _transport(data)
    query = {"type": transport}
    host = _pick(data, "ws_host", "xhttp_host", "httpupgrade_host", "grpc_host")
    if transport == "ws":
        query["path"] = _pick(data, "ws_path", default="/") or "/"
        if host:
            query["host"] = host
    elif transport == "xhttp":
        query["path"] = _pick(data, "xhttp_path", default="/") or "/"
        mode = _pick(data, "xhttp_mode")
        if mode:
            query["mode"] = mode
        if host:
            query["host"] = host
    elif transport == "grpc":
        service = _pick(data, "grpc_serviceName", "grpc_service_name")
        if service:
            query["serviceName"] = service
    elif transport in ("h2", "http"):
        query["path"] = _pick(data, "http_path", default="/") or "/"
        if host:
            query["host"] = host
    return query


def _vless(data):
    uuid = _pick(data, "uuid")
    if not uuid:
        raise LinkError("PassWall VLESS 节点缺少 uuid")
    query = _query(data)
    security = _security(data)
    query["security"] = security
    query["encryption"] = _pick(data, "encryption", default="none") or "none"
    sni = _pick(data, "tls_serverName", "sni")
    if sni:
        query["sni"] = sni
    fingerprint = _pick(data, "fingerprint")
    if fingerprint:
        query["fp"] = fingerprint
    alpn = _alpn(data)
    if alpn:
        query["alpn"] = alpn
    if _pick(data, "tls_allowInsecure") == "1":
        query["allowInsecure"] = "1"
    flow = _pick(data, "flow")
    if flow:
        query["flow"] = flow
    if security == "reality":
        public_key = _pick(data, "reality_publicKey")
        if not public_key:
            raise LinkError("PassWall REALITY 节点缺少 reality_publicKey")
        query["pbk"] = public_key
        short_id = _pick(data, "reality_shortId")
        if short_id:
            query["sid"] = short_id
        spider = _pick(data, "reality_spiderX")
        if spider:
            query["spx"] = spider
    name = quote(_pick(data, "remarks", default="passwall"), safe="")
    return "vless://%s@%s:%s?%s#%s" % (
        quote(uuid, safe=""), _address(data), _port(data), urlencode(query), name)


def _vmess(data):
    uuid = _pick(data, "uuid")
    if not uuid:
        raise LinkError("PassWall VMess 节点缺少 uuid")
    payload = {
        "v": "2",
        "ps": _pick(data, "remarks", default="passwall"),
        "add": _address(data),
        "port": str(_port(data)),
        "id": uuid,
        "aid": _pick(data, "alterId", "aid", default="0") or "0",
        "scy": _pick(data, "security", default="auto") or "auto",
        "net": _transport(data),
        "type": "none",
    }
    host = _pick(data, "ws_host", "xhttp_host", "httpupgrade_host", "grpc_host")
    if host:
        payload["host"] = host
    transport = _transport(data)
    if transport == "ws":
        payload["path"] = _pick(data, "ws_path", default="/") or "/"
    elif transport == "xhttp":
        payload["path"] = _pick(data, "xhttp_path", default="/") or "/"
        mode = _pick(data, "xhttp_mode")
        if mode:
            payload["mode"] = mode
    elif transport == "grpc":
        payload["path"] = _pick(data, "grpc_serviceName", "grpc_service_name")
    elif transport in ("h2", "http"):
        payload["path"] = _pick(data, "http_path", default="/") or "/"
    security = _security(data)
    if security != "none":
        payload["tls"] = "tls" if security == "tls" else security
    sni = _pick(data, "tls_serverName", "sni")
    if sni:
        payload["sni"] = sni
    alpn = _alpn(data)
    if alpn:
        payload["alpn"] = alpn
    fingerprint = _pick(data, "fingerprint")
    if fingerprint:
        payload["fp"] = fingerprint
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return "vmess://" + base64.b64encode(raw).decode("ascii")


def _trojan(data):
    password = _pick(data, "password", "uuid")
    if not password:
        raise LinkError("PassWall Trojan 节点缺少 password")
    query = _query(data)
    query["security"] = _security(data)
    sni = _pick(data, "tls_serverName", "sni")
    if sni:
        query["sni"] = sni
    fingerprint = _pick(data, "fingerprint")
    if fingerprint:
        query["fp"] = fingerprint
    alpn = _alpn(data)
    if alpn:
        query["alpn"] = alpn
    name = quote(_pick(data, "remarks", default="passwall"), safe="")
    return "trojan://%s@%s:%s?%s#%s" % (
        quote(password, safe=""), _address(data), _port(data), urlencode(query), name)


def _shadowsocks(data):
    method = _pick(data, "method")
    password = _pick(data, "password")
    if not method:
        raise LinkError("PassWall Shadowsocks 节点缺少 method")
    userinfo = base64.urlsafe_b64encode(
        ("%s:%s" % (method, password)).encode("utf-8")).decode("ascii").rstrip("=")
    query = {}
    plugin = _pick(data, "plugin")
    if plugin:
        parts = [plugin]
        plugin_opts = _pick(data, "plugin_opts", "plugin_opts_str")
        if plugin_opts:
            parts.append(plugin_opts.lstrip(";"))
        query["plugin"] = ";".join(parts)
    name = quote(_pick(data, "remarks", default="passwall"), safe="")
    suffix = ("?" + urlencode(query)) if query else ""
    return "ss://%s@%s:%s%s#%s" % (
        userinfo, _address(data), _port(data), suffix, name)


def _hysteria2(data):
    password = _pick(data, "password", "uuid")
    if not password:
        raise LinkError("PassWall Hysteria2 节点缺少 password")
    query = {}
    sni = _pick(data, "tls_serverName", "sni")
    if sni:
        query["sni"] = sni
    obfs = _pick(data, "hysteria2_obfs", "obfs")
    if obfs and obfs != "none":
        query["obfs"] = obfs
        obfs_password = _pick(data, "hysteria2_obfs_password", "obfs_password")
        if obfs_password:
            query["obfs-password"] = obfs_password
    alpn = _alpn(data)
    if alpn:
        query["alpn"] = alpn
    name = quote(_pick(data, "remarks", default="passwall"), safe="")
    return "hysteria2://%s@%s:%s?%s#%s" % (
        quote(password, safe=""), _address(data), _port(data), urlencode(query), name)


def _address(data):
    value = _pick(data, "address")
    if not value:
        raise LinkError("PassWall 节点缺少 address")
    return value.strip("[]")


def _port(data):
    value = _pick(data, "port")
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise LinkError("PassWall 节点缺少合法 port")
    if not 1 <= number <= 65535:
        raise LinkError("PassWall 节点 port 超出范围")
    return number


_PROTOCOLS = {
    "vless": _vless,
    "vmess": _vmess,
    "trojan": _trojan,
    "shadowsocks": _shadowsocks,
    "ss": _shadowsocks,
    "hysteria2": _hysteria2,
}


def node_link(node_id):
    """Return a share link for a PassWall UCI node, or raise LinkError."""
    data = _uci_show(node_id)
    protocol = (_pick(data, "protocol") or "").lower()
    builder = _PROTOCOLS.get(protocol)
    if builder is None:
        raise LinkError("PassWall 节点 %s 的协议 %s 暂不支持独立内核"
                        % (node_id, protocol or "(none)"))
    return builder(data)


CONFIG = "cfpick"


def _uci_get_raw(config, section, option, default=""):
    try:
        output = subprocess.check_output(
            ["uci", "-q", "get", "%s.%s.%s" % (config, section, option)],
            stderr=subprocess.DEVNULL, timeout=10).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return default
    value = output.strip()
    return value if value != "" else default


def uci_get(section, option, default=""):
    """Read one option from the package's UCI config."""
    return _uci_get_raw(CONFIG, section, option, default)


def _uci_config():
    """Return ``{section: {option: value}}`` for the package config."""
    try:
        output = subprocess.check_output(
            ["uci", "-q", "show", CONFIG],
            stderr=subprocess.DEVNULL, timeout=10).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return {}
    data = {}
    for line in output.splitlines():
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key[len(CONFIG) + 1:] if key.startswith(CONFIG + ".") else key
        section, _, option = key.partition(".")
        if not option:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] in "'\"" and value[-1] == value[0]:
            value = value[1:-1]
        data.setdefault(section, {}).setdefault(option, value)
    return data


def _enabled(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def standalone_config():
    data = _uci_config().get("global", {})
    return {
        "enabled": _enabled(data.get("standalone_enabled", "0")),
        "core": "mihomo" if data.get("standalone_core") == "mihomo" else "xray",
    }


def ddns_config():
    data = _uci_config().get("global", {})
    try:
        ip_count = int(data.get("ddns_ip_count", "1") or "1")
    except (TypeError, ValueError):
        ip_count = 1
    try:
        ttl = int(data.get("ddns_ttl", "300") or "300")
    except (TypeError, ValueError):
        ttl = 300
    return {
        "enabled": _enabled(data.get("ddns_enabled", "0")),
        "ip_count": max(1, min(ip_count, 10)),
        "ttl": ttl,
        "cloudflare": {
            "api_token": data.get("ddns_api_token", ""),
            "zone_id": data.get("ddns_zone_id", ""),
            "zone_name": data.get("ddns_zone_name", ""),
            "proxied": _enabled(data.get("ddns_proxied", "0")),
        },
    }


def node_ip_ddns():
    """Return ``[{node, name, domain}]`` for workers with a DDNS domain.

    ``name`` is the node's remarks with commas replaced by spaces, matching
    the node column written to the shell pipeline's result.csv.
    """
    data = _uci_config()
    out = []
    for section, options in data.items():
        if not section.startswith("@node_ip["):
            continue
        node = str(options.get("node", "")).strip()
        domain = str(options.get("ddns_domain", "")).strip().lower().rstrip(".")
        if not node or not domain:
            continue
        remarks = _uci_get_raw("passwall", node, "remarks", "")
        name = remarks.replace(",", " ") or node
        out.append({"node": node, "name": name, "domain": domain})
    return out


def node_info(node_id):
    """Small summary used by callers/tests (never includes secrets)."""
    data = _uci_show(node_id)
    return {
        "id": node_id,
        "protocol": _pick(data, "protocol"),
        "type": _pick(data, "type"),
        "address": _pick(data, "address"),
        "port": _pick(data, "port"),
        "remarks": _pick(data, "remarks"),
    }
