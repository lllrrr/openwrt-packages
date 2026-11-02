"""Parse proxy share links into mihomo proxy dictionaries.

Supported: vless://, vmess://, trojan://, ss://, hysteria2:// (hy2://).
The engine replaces the ``server`` field with a candidate Cloudflare IP for
every probe/download, exactly like the OpenWrt version rewrites a PassWall
node's ``address``.
"""

import base64
import copy
import json
from dataclasses import dataclass
from typing import Any, Dict
from urllib.parse import parse_qs, unquote, urlsplit


class LinkError(ValueError):
    pass


def _decode_base64(text):
    text = unquote(text.strip())
    text = text.replace("-", "+").replace("_", "/")
    text += "=" * (-len(text) % 4)
    try:
        return base64.b64decode(text).decode("utf-8", "replace")
    except (ValueError, TypeError):
        raise LinkError("invalid base64 payload")


def _truthy(value, default=False):
    if value is None:
        return default
    text = str(value).strip().lower()
    if text in ("1", "true", "yes", "on"):
        return True
    if text in ("0", "false", "no", "off", ""):
        return False
    return default


def _q(query, *names, default=""):
    for name in names:
        values = query.get(name)
        if values:
            value = values[0].strip()
            if value:
                return unquote(value)
    return default


def _split_host_port(host, port):
    if not host:
        raise LinkError("missing server address")
    host = str(host).strip().strip("[]")
    try:
        port = int(port)
    except (TypeError, ValueError):
        raise LinkError("missing or invalid port")
    if not 1 <= port <= 65535:
        raise LinkError("port out of range")
    return host, port


def _alpn(query):
    value = _q(query, "alpn")
    return [item for item in value.split(",") if item] if value else []


def _transport(proxy, network, query):
    network = (network or "tcp").lower()
    if network in ("tcp", "raw"):
        return
    if network == "ws":
        path = _q(query, "path", default="/") or "/"
        host = _q(query, "host")
        opts = {"path": path}
        if host:
            opts["headers"] = {"Host": host}
        proxy["network"] = "ws"
        proxy["ws-opts"] = opts
    elif network == "grpc":
        service = _q(query, "serviceName", "servicename") or _q(query, "path")
        proxy["network"] = "grpc"
        proxy["grpc-opts"] = {"grpc-service-name": service}
    elif network in ("h2", "http"):
        path = _q(query, "path", default="/") or "/"
        host = _q(query, "host")
        if network == "h2":
            opts = {"path": path}
            if host:
                opts["host"] = [host]
            proxy["network"] = "h2"
            proxy["h2-opts"] = opts
        else:
            opts = {"path": [path]}
            if host:
                opts["headers"] = {"Host": [host]}
            proxy["network"] = "http"
            proxy["http-opts"] = opts
    elif network == "xhttp":
        opts = {"path": _q(query, "path", default="/") or "/",
                "mode": _q(query, "mode", default="auto") or "auto"}
        host = _q(query, "host")
        if host:
            opts["host"] = host
        extra = _q(query, "extra")
        if extra:
            try:
                parsed_extra = json.loads(extra)
                if isinstance(parsed_extra, dict) and parsed_extra:
                    opts["extra"] = parsed_extra
            except ValueError:
                pass
        proxy["network"] = "xhttp"
        proxy["xhttp-opts"] = opts
    else:
        # Keep the raw value; the active core decides whether it is supported.
        proxy["network"] = network


def _parse_vless(link):
    parsed = urlsplit(link)
    query = parse_qs(parsed.query, keep_blank_values=True)
    uuid = unquote(parsed.username or "")
    if not uuid:
        raise LinkError("vless link has no uuid")
    host, port = _split_host_port(parsed.hostname, parsed.port)

    proxy = {
        "name": "vless",
        "type": "vless",
        "server": host,
        "port": port,
        "uuid": uuid,
        "udp": True,
    }
    encryption = _q(query, "encryption")
    if encryption and encryption != "none":
        proxy["encryption"] = encryption
    flow = _q(query, "flow")
    if flow:
        proxy["flow"] = flow

    security = _q(query, "security", default="none").lower()
    sni = _q(query, "sni", "peer", "host")
    if security in ("tls", "reality", "xtls"):
        proxy["tls"] = True
        if sni:
            proxy["servername"] = sni
    fingerprint = _q(query, "fp")
    if fingerprint:
        proxy["client-fingerprint"] = fingerprint
    if _truthy(_q(query, "allowInsecure", "insecure", "skip-cert-verify")):
        proxy["skip-cert-verify"] = True
    alpn = _alpn(query)
    if alpn:
        proxy["alpn"] = alpn
    if security == "reality":
        public_key = _q(query, "pbk", "public-key")
        if not public_key:
            raise LinkError("REALITY link has no public key (pbk)")
        reality = {"public-key": public_key}
        short_id = _q(query, "sid", "short-id")
        if short_id:
            reality["short-id"] = short_id
        proxy["reality-opts"] = reality

    _transport(proxy, _q(query, "type", default="tcp"), query)
    return proxy, parsed.fragment


def _parse_vmess(link):
    payload = link[len("vmess://"):]
    try:
        data = json.loads(_decode_base64(payload))
    except ValueError:
        raise LinkError("vmess link is not a base64 JSON payload")
    if not isinstance(data, dict):
        raise LinkError("vmess payload is not an object")
    host, port = _split_host_port(str(data.get("add", "")), data.get("port"))
    uuid = str(data.get("id", "")).strip()
    if not uuid:
        raise LinkError("vmess link has no uuid")

    proxy = {
        "name": "vmess",
        "type": "vmess",
        "server": host,
        "port": port,
        "uuid": uuid,
        "alterId": int(data.get("aid") or 0),
        "cipher": str(data.get("scy") or "auto"),
        "udp": True,
    }
    network = str(data.get("net") or "tcp")
    tls = str(data.get("tls") or "").lower()
    if tls in ("tls", "reality"):
        proxy["tls"] = True
        sni = str(data.get("sni") or data.get("host") or "")
        if sni:
            proxy["servername"] = sni
    fingerprint = str(data.get("fp") or "")
    if fingerprint:
        proxy["client-fingerprint"] = fingerprint
    alpn = str(data.get("alpn") or "")
    if alpn:
        proxy["alpn"] = [item for item in alpn.split(",") if item]

    if network == "ws":
        opts = {"path": str(data.get("path") or "/")}
        host_header = str(data.get("host") or "")
        if host_header:
            opts["headers"] = {"Host": host_header}
        proxy["network"] = "ws"
        proxy["ws-opts"] = opts
    elif network == "grpc":
        proxy["network"] = "grpc"
        proxy["grpc-opts"] = {"grpc-service-name": str(data.get("path") or "")}
    elif network == "xhttp":
        opts = {
            "path": str(data.get("path") or "/"),
            "mode": str(data.get("mode") or "auto"),
        }
        host_header = str(data.get("host") or data.get("authority") or "")
        if host_header:
            opts["host"] = host_header
        extra = data.get("extra")
        if isinstance(extra, str) and extra:
            try:
                extra = json.loads(extra)
            except ValueError:
                extra = None
        if isinstance(extra, dict) and extra:
            opts["extra"] = extra
        proxy["network"] = "xhttp"
        proxy["xhttp-opts"] = opts
    elif network in ("h2", "http"):
        proxy["network"] = network
    elif network:
        proxy["network"] = network
    return proxy, str(data.get("ps") or "")


def _parse_trojan(link):
    parsed = urlsplit(link)
    query = parse_qs(parsed.query, keep_blank_values=True)
    password = unquote(parsed.username or "")
    if not password:
        raise LinkError("trojan link has no password")
    host, port = _split_host_port(parsed.hostname, parsed.port)

    proxy = {
        "name": "trojan",
        "type": "trojan",
        "server": host,
        "port": port,
        "password": password,
        "udp": True,
    }
    sni = _q(query, "sni", "peer", "host")
    if sni:
        proxy["sni"] = sni
    if _truthy(_q(query, "allowInsecure", "insecure", "skip-cert-verify")):
        proxy["skip-cert-verify"] = True
    alpn = _alpn(query)
    if alpn:
        proxy["alpn"] = alpn
    _transport(proxy, _q(query, "type", default="tcp"), query)
    return proxy, parsed.fragment


def _parse_ss(link):
    body = link[len("ss://"):]
    fragment = ""
    if "#" in body:
        body, fragment = body.split("#", 1)
        fragment = unquote(fragment)
    if "?" in body:
        body, query_string = body.split("?", 1)
    else:
        query_string = ""
    query = parse_qs(query_string, keep_blank_values=True)

    if "@" in body:
        userinfo, hostpart = body.rsplit("@", 1)
        if ":" not in userinfo:
            userinfo = _decode_base64(userinfo)
        if ":" not in userinfo:
            raise LinkError("ss userinfo is not method:password")
        method, password = userinfo.split(":", 1)
        parsed = urlsplit("ss://" + hostpart)
        host, port = _split_host_port(parsed.hostname, parsed.port)
    else:
        decoded = _decode_base64(body).strip()
        # Legacy form: method:password@host:port
        if "@" not in decoded:
            raise LinkError("ss link has no server part")
        userinfo, hostpart = decoded.rsplit("@", 1)
        if ":" not in userinfo:
            raise LinkError("ss userinfo is not method:password")
        method, password = userinfo.split(":", 1)
        parsed = urlsplit("ss://" + hostpart)
        host, port = _split_host_port(parsed.hostname, parsed.port)

    method = unquote(method).strip()
    password = unquote(password)
    if not method:
        raise LinkError("ss link has no cipher")

    proxy = {
        "name": "ss",
        "type": "ss",
        "server": host,
        "port": port,
        "cipher": method,
        "password": password,
        "udp": True,
    }
    plugin = _q(query, "plugin")
    if plugin:
        parts = [item for item in plugin.split(";") if item]
        name = parts[0].lower()
        opts = {}
        for item in parts[1:]:
            if "=" in item:
                key, value = item.split("=", 1)
                opts[key.strip()] = value.strip()
            else:
                opts[item.strip()] = True
        if name in ("obfs-local", "simple-obfs", "obfs"):
            proxy["plugin"] = "obfs"
            plugin_opts = {"mode": opts.get("obfs", "http")}
            host_opt = opts.get("obfs-host")
            if host_opt:
                plugin_opts["host"] = host_opt
            proxy["plugin-opts"] = plugin_opts
        elif name == "v2ray-plugin":
            proxy["plugin"] = "v2ray-plugin"
            plugin_opts = {"mode": opts.get("mode", "websocket")}
            for key, dest in (("host", "host"), ("path", "path")):
                if opts.get(key):
                    plugin_opts[dest] = opts[key]
            if opts.get("tls"):
                plugin_opts["tls"] = True
            proxy["plugin-opts"] = plugin_opts
        else:
            proxy["plugin"] = name
            proxy["plugin-opts"] = {k: v for k, v in opts.items() if v is not True}
    return proxy, fragment


def _parse_hysteria2(link):
    parsed = urlsplit(link)
    query = parse_qs(parsed.query, keep_blank_values=True)
    password = unquote(parsed.username or "")
    if not password:
        raise LinkError("hysteria2 link has no password")
    host, port = _split_host_port(parsed.hostname, parsed.port)

    proxy = {
        "name": "hysteria2",
        "type": "hysteria2",
        "server": host,
        "port": port,
        "password": password,
    }
    sni = _q(query, "sni", "peer")
    if sni:
        proxy["sni"] = sni
    if _truthy(_q(query, "insecure", "allowInsecure")):
        proxy["skip-cert-verify"] = True
    obfs = _q(query, "obfs")
    if obfs and obfs != "none":
        proxy["obfs"] = obfs
        obfs_password = _q(query, "obfs-password")
        if obfs_password:
            proxy["obfs-password"] = obfs_password
    alpn = _alpn(query)
    if alpn:
        proxy["alpn"] = alpn
    for key in ("up", "down"):
        value = _q(query, key)
        if value:
            proxy[key] = value
    return proxy, parsed.fragment


_PARSERS = {
    "vless": _parse_vless,
    "vmess": _parse_vmess,
    "trojan": _parse_trojan,
    "ss": _parse_ss,
    "hysteria2": _parse_hysteria2,
    "hy2": _parse_hysteria2,
}


@dataclass
class ParsedLink:
    name: str
    type: str
    server: str
    port: int
    proxy: Dict[str, Any]

    def proxy_for_ip(self, ip):
        proxy = copy.deepcopy(self.proxy)
        proxy["server"] = ip
        proxy["name"] = "cfpick"
        return proxy


def parse_link(link):
    link = (link or "").strip()
    if not link:
        raise LinkError("empty link")
    scheme = link.split("://", 1)[0].lower() if "://" in link else ""
    parser = _PARSERS.get(scheme)
    if not parser:
        raise LinkError("unsupported scheme %r" % (scheme or "(none)"))
    proxy, name = parser(link)
    proxy_type = str(proxy.get("type", scheme))
    if not name:
        name = "%s-%s:%s" % (proxy_type, proxy.get("server"), proxy.get("port"))
    return ParsedLink(
        name=name.strip(),
        type=proxy_type,
        server=str(proxy.get("server")),
        port=int(proxy.get("port")),
        proxy=proxy,
    )


