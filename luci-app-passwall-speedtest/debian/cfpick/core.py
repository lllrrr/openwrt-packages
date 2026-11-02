"""Proxy core modules (mihomo / Xray-core).

Each core is a standalone binary managed under ``/var/lib/cfpick/core``
and upgradable on its own: ``cfpick update-core --type xray`` or the Web UI's
Core tab.  For every candidate IP the engine asks the active core to build a
throw-away config whose proxy server is that IP, starts one process with a
private SOCKS port, probes it with curl, then stops it.

Node links are parsed once by :mod:`cfpick.links` into a neutral mihomo
style dict; :func:`build_mihomo_config` emits Clash YAML and
:func:`build_xray_config` converts the same dict into an Xray JSON outbound.
"""

import gzip
import json
import os
import platform
import re
import shutil
import socket
import stat
import subprocess
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

from . import paths
from .miniyaml import dumps as yaml_dumps

CORE_TYPES = ("mihomo", "xray")
CORE_LABELS = {
    "mihomo": "mihomo (Clash.Meta)",
    "xray": "Xray-core",
}
CORE_REPOS = {
    "mihomo": "MetaCubeX/mihomo",
    "xray": "XTLS/Xray-core",
}
USER_AGENT = "cfpick/1.0 (+https://github.com/urbanescavenger/CFPick)"
_ARCH_ALIASES = {
    "x86_64": "amd64",
    "amd64": "amd64",
    "aarch64": "arm64",
    "arm64": "arm64",
    "armv7l": "armv7",
    "armv6l": "armv6",
    "i386": "386",
    "i686": "386",
}
_XRAY_ASSETS = {
    "amd64": "Xray-linux-64.zip",
    "arm64": "Xray-linux-arm64-v8a.zip",
    "armv7": "Xray-linux-arm32-v7a.zip",
    "armv6": "Xray-linux-arm32-v6.zip",
    "armv5": "Xray-linux-arm32-v5.zip",
    "386": "Xray-linux-32.zip",
    "riscv64": "Xray-linux-riscv64.zip",
    "loong64": "Xray-linux-loong64.zip",
    "s390x": "Xray-linux-s390x.zip",
    "ppc64le": "Xray-linux-ppc64le.zip",
    "ppc64": "Xray-linux-ppc64.zip",
    "mips32": "Xray-linux-mips32.zip",
    "mips32le": "Xray-linux-mips32le.zip",
    "mips64": "Xray-linux-mips64.zip",
    "mips64le": "Xray-linux-mips64le.zip",
}


class CoreError(RuntimeError):
    pass


def normalize_type(value):
    value = (value or "").strip().lower()
    return value if value in CORE_TYPES else "mihomo"


def _route_mark():
    """SO_MARK applied to the core's outbound sockets.

    On OpenWrt with PassWall the router's own traffic is transparently
    proxied unless the socket carries the mark PassWall itself uses
    (``meta mark 255 return`` in its OUTPUT chains).  Marking our outbound
    connection keeps the test single-hop: local SOCKS -> node, instead of
    local SOCKS -> node -> global PassWall node.  On a plain Debian host no
    rule matches the mark and it is harmless.  ``CFPICK_MARK=0`` disables it.
    """
    try:
        value = int(os.environ.get("CFPICK_MARK", "255"))
    except (TypeError, ValueError):
        value = 255
    return value if 0 <= value <= 0xFFFFFFFF else 255


def active_type(cfg=None):
    return normalize_type(((cfg or {}).get("core") or {}).get("type"))


def _arch():
    machine = platform.machine().lower()
    return _ARCH_ALIASES.get(machine, machine)


def _managed_binary(core_type):
    return paths.CORE_BINARIES[normalize_type(core_type)]


# Distribution-provided binaries (OpenWrt/PassWall, Debian packages).  Used
# only when the managed copy under CFPICK_STATE_DIR/core is absent.
_SYSTEM_BINARIES = {
    "mihomo": ("/usr/bin/mihomo", "/usr/libexec/mihomo-core", "/usr/bin/mihomo-meta"),
    "xray": ("/usr/bin/xray", "/usr/bin/xray-core"),
}


def _version_file(core_type):
    return paths.CORE_VERSION_FILES[normalize_type(core_type)]


def _executable(path):
    try:
        return Path(path).exists() and os.access(str(path), os.X_OK)
    except OSError:
        return False


def core_binary(cfg=None, core_type=None):
    """Return the binary path for a core, or None when it is not installed."""
    cfg = cfg or {}
    core_cfg = cfg.get("core") or {}
    chosen = normalize_type(core_type or core_cfg.get("type"))
    configured_paths = core_cfg.get("paths") if isinstance(core_cfg.get("paths"), dict) else {}
    configured = configured_paths.get(chosen, "")
    if not configured and core_cfg.get("path") and chosen == active_type(cfg):
        configured = core_cfg.get("path", "")
    if configured:
        path = Path(str(configured)).expanduser()
        return path if _executable(path) else None
    managed = _managed_binary(chosen)
    if _executable(managed):
        return managed
    # OpenWrt: PassWall (or another package) may already ship a core.  Reuse
    # it instead of downloading a second copy; a managed core still wins so
    # the Web "内核" page can upgrade independently.
    for candidate in _SYSTEM_BINARIES.get(chosen, ()):
        path = Path(candidate)
        if _executable(path):
            return path
    return None


_version_cache = {}


def _core_version(binary, core_type):
    if not binary or not Path(binary).exists():
        return ""
    path = Path(binary)
    try:
        stat_info = path.stat()
    except OSError:
        return ""
    chosen = normalize_type(core_type)
    cache_key = (str(path.resolve()), chosen)
    cached = _version_cache.get(cache_key)
    if cached and cached[0] == stat_info.st_mtime and cached[1] == stat_info.st_size:
        return cached[2]

    command = [str(path), "-v"] if chosen == "mihomo" else [str(path), "version"]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return ""
    text = result.stdout.decode("utf-8", "replace").strip()
    version = text.splitlines()[0] if text else ""
    _version_cache[cache_key] = (stat_info.st_mtime, stat_info.st_size, version)
    return version


def _release_tag(text):
    match = re.search(r"v?(\d+\.\d+\.\d+)", text or "")
    return ("v" + match.group(1)) if match else ""


def core_info(cfg=None, core_type=None):
    cfg = cfg or {}
    chosen = normalize_type(core_type or ((cfg.get("core") or {}).get("type")))
    binary = core_binary(cfg, chosen)
    managed = binary is not None and Path(binary) == _managed_binary(chosen)
    version = ""
    if managed:
        try:
            version = _version_file(chosen).read_text(encoding="utf-8").strip()
        except OSError:
            version = ""
    if not version and binary:
        version = _core_version(binary, chosen)
    return {
        "type": chosen,
        "label": CORE_LABELS[chosen],
        "installed": binary is not None,
        "path": str(binary or _managed_binary(chosen)),
        "managed": managed,
        "version": version,
        "release": _release_tag(version),
    }


def all_core_info(cfg=None):
    cfg = cfg or {}
    return {
        "active": active_type(cfg),
        "cores": {chosen: core_info(cfg, chosen) for chosen in CORE_TYPES},
    }


def ensure_core(cfg=None):
    """Return ``(binary, core_type)`` for the configured active core."""
    chosen = active_type(cfg)
    binary = core_binary(cfg, chosen)
    if not binary:
        raise CoreError(
            "%s 内核未安装：请在 Web「内核」页安装，或运行 `cfpick update-core --type %s`"
            % (CORE_LABELS[chosen], chosen)
        )
    return binary, chosen


# ── downloads / upgrades ────────────────────────────────────────────────
def _request_json(url):
    request = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def _github_release(repo, tag=None):
    if tag:
        tag = str(tag).strip()
        if not re.match(r"^v?[A-Za-z0-9][A-Za-z0-9._-]*$", tag):
            raise CoreError("版本标签不合法: %s" % tag)
        if not tag.startswith("v"):
            tag = "v" + tag
        url = "https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag)
    else:
        url = "https://api.github.com/repos/%s/releases/latest" % repo
    try:
        return _request_json(url)
    except (urllib.error.URLError, ValueError, OSError) as exc:
        raise CoreError("无法查询 GitHub releases: %s" % exc)


def _pick_mihomo_asset(assets, arch, tag):
    suffix = "-%s.gz" % tag
    names = [item.get("name", "") for item in assets]
    by_name = {item.get("name", ""): item for item in assets}

    def matches(name):
        return name.startswith("mihomo-linux-%s" % arch) and name.endswith(suffix)

    candidates = [name for name in names if matches(name) and "go1" not in name]
    if not candidates:
        candidates = [name for name in names
                      if name.startswith("mihomo-linux-%s" % arch)
                      and name.endswith(".gz") and "go1" not in name]

    def rank(name):
        if arch == "amd64":
            if "compatible" in name:
                return 0
            if "-v1-" in name:
                return 1
            if "-v2-" in name:
                return 3
            if "-v3-" in name:
                return 4
            return 2
        if "-v1-" in name:
            return 1
        return 2

    if not candidates:
        raise CoreError("没有找到适用于 linux/%s 的 mihomo 资产（tag %s）" % (arch, tag))
    candidates.sort(key=rank)
    return by_name[candidates[0]]


def _pick_xray_asset(assets, arch):
    wanted = _XRAY_ASSETS.get(arch)
    by_name = {item.get("name", ""): item for item in assets}
    if wanted and wanted in by_name:
        return by_name[wanted]
    # Fall back to any linux zip whose name mentions the architecture.
    for name, item in by_name.items():
        if name.startswith("Xray-linux-") and name.endswith(".zip") and arch in name:
            return item
    raise CoreError("没有找到适用于 linux/%s 的 Xray 资产（期望 %s）"
                    % (arch, wanted or ("Xray-linux-%s.zip" % arch)))


def _download(url, destination, timeout=180):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response, open(destination, "wb") as handle:
        shutil.copyfileobj(response, handle, length=256 * 1024)


def _extract_mihomo(archive, destination):
    with gzip.open(archive, "rb") as source, open(destination, "wb") as target:
        shutil.copyfileobj(source, target, length=256 * 1024)


def _extract_xray(archive, destination):
    try:
        with zipfile.ZipFile(archive) as bundle:
            names = bundle.namelist()
            entry = next((name for name in names
                          if name.rsplit("/", 1)[-1] == "xray"), None)
            if not entry:
                raise CoreError("Xray 压缩包中没有找到 xray 二进制：%s" % names[:8])
            if bundle.getinfo(entry).file_size > 200 * 1024 * 1024:
                raise CoreError("Xray 二进制异常偏大，拒绝解压")
            with bundle.open(entry) as source, open(destination, "wb") as target:
                shutil.copyfileobj(source, target, length=256 * 1024)
    except zipfile.BadZipFile as exc:
        raise CoreError("Xray 压缩包损坏: %s" % exc)


def update_core(core_type="mihomo", tag=None, log=None):
    """Download or upgrade a managed core.  Returns its info dict."""
    log = log or (lambda message: None)
    chosen = normalize_type(core_type)
    arch = _arch()
    paths.CORE_DIR.mkdir(parents=True, exist_ok=True)
    # Clean leftovers from an interrupted previous update.
    for pattern in (".core.*", "*.new"):
        for stale in paths.CORE_DIR.glob(pattern):
            try:
                stale.unlink()
            except OSError:
                pass

    release = _github_release(CORE_REPOS[chosen], tag or None)
    resolved_tag = release.get("tag_name", "")
    if not resolved_tag:
        raise CoreError("GitHub 响应缺少 tag_name")

    if chosen == "mihomo":
        asset = _pick_mihomo_asset(release.get("assets", []), arch, resolved_tag)
        extractor = _extract_mihomo
    else:
        asset = _pick_xray_asset(release.get("assets", []), arch)
        extractor = _extract_xray

    log("下载 %s %s（%s）..." % (CORE_LABELS[chosen], resolved_tag, asset.get("name", "")))
    suffix = ".zip" if chosen == "xray" else ".gz"
    fd, archive_name = tempfile.mkstemp(prefix=".core.", suffix=suffix, dir=str(paths.CORE_DIR))
    os.close(fd)
    archive = Path(archive_name)
    target = _managed_binary(chosen)
    tmp_bin = Path(str(target) + ".new")
    try:
        _download(asset.get("browser_download_url", ""), archive)
        extractor(archive, tmp_bin)
        if not tmp_bin.exists() or tmp_bin.stat().st_size < 1024 * 1024:
            raise CoreError("下载的内核文件异常偏小")
        os.chmod(tmp_bin, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP
                 | stat.S_IROTH | stat.S_IXOTH)
        version = _core_version(tmp_bin, chosen)
        if not version:
            raise CoreError("下载的内核无法运行（架构不匹配？）")
        os.replace(tmp_bin, target)
        _version_file(chosen).write_text(resolved_tag + "\n", encoding="utf-8")
        log("%s 内核已更新到 %s（%s）" % (CORE_LABELS[chosen], resolved_tag, version))
    finally:
        for leftover in (archive, tmp_bin):
            try:
                if leftover.exists():
                    leftover.unlink()
            except OSError:
                pass

    return core_info(None, chosen)


# ── node compatibility ──────────────────────────────────────────────────
def validate_proxy(proxy, core_type="mihomo"):
    """Raise CoreError when the active core cannot carry this proxy."""
    chosen = normalize_type(core_type)
    proxy_type = str(proxy.get("type", "")).lower()
    network = str(proxy.get("network") or "tcp").lower()
    if chosen == "mihomo":
        # mihomo's XHTTP transport currently covers VLESS only.  A VMess/Trojan
        # xhttp node must use the Xray core.
        if network == "xhttp" and proxy_type != "vless":
            raise CoreError(
                "mihomo 当前仅支持 VLESS 的 xhttp；这个 %s xhttp 节点请改用 Xray 内核"
                % (proxy_type or "未知"))
        # VLESS encryption (e.g. mlkem768x25519plus) is an Xray extension that
        # mihomo does not understand.  Fall back to Xray for these nodes.
        encryption = str(proxy.get("encryption") or "").strip().lower()
        if encryption and encryption != "none":
            raise CoreError(
                "mihomo 不支持该 VLESS encryption（%s），请改用 Xray 内核" % encryption)
        return
    if proxy_type not in ("vless", "vmess", "trojan", "ss"):
        raise CoreError("xray 内核不支持 %s 节点，请改用 mihomo 内核" % (proxy_type or "未知"))
    if proxy_type == "ss" and proxy.get("plugin"):
        raise CoreError("xray 内核不支持带 plugin（obfs / v2ray-plugin）的 SS 节点，请改用 mihomo")
    if network in ("h2", "http"):
        raise CoreError("Xray 26 已移除 HTTP/2 传输，请改用 mihomo 内核")
    if network not in ("tcp", "ws", "grpc", "xhttp"):
        raise CoreError("xray 内核不支持 %s 传输，请改用 mihomo 内核" % network)


# ── config generation ──────────────────────────────────────────────────
def build_mihomo_config(proxy, socks_port, dns_nameserver=""):
    proxy = dict(proxy)
    proxy["name"] = "cfpick"
    config = {
        "socks-port": int(socks_port),
        "allow-lan": False,
        "bind-address": "127.0.0.1",
        "mode": "rule",
        "log-level": "warning",
        "ipv6": True,
        "profile": {
            "store-selected": False,
            "store-fake-ip": False,
        },
        "proxies": [proxy],
        "rules": ["MATCH,cfpick"],
    }
    mark = _route_mark()
    if mark:
        config["routing-mark"] = mark
    if dns_nameserver:
        config["dns"] = {
            "enable": True,
            "ipv6": True,
            "nameserver": [dns_nameserver],
        }
    else:
        config["dns"] = {"enable": False}
    return config


def _xray_stream(proxy, force_tls=False):
    network = str(proxy.get("network") or "tcp").lower()
    if network == "h2":
        network = "http"
    if network not in ("tcp", "ws", "grpc", "http", "xhttp"):
        raise CoreError("xray 不支持 %s 传输" % network)

    sni = (proxy.get("servername") or proxy.get("sni") or "").strip()
    fingerprint = (proxy.get("client-fingerprint") or "chrome").strip()
    alpn = proxy["alpn"] if isinstance(proxy.get("alpn"), list) else []
    security = "none"
    stream = {"network": network, "security": security}

    if proxy.get("reality-opts"):
        reality = proxy["reality-opts"] or {}
        public_key = reality.get("public-key", "")
        if not public_key:
            raise CoreError("REALITY 节点缺少 public key")
        if not sni:
            raise CoreError("REALITY 节点缺少 serverName/sni")
        stream["security"] = "reality"
        stream["realitySettings"] = {
            "serverName": sni,
            "fingerprint": fingerprint,
            "publicKey": public_key,
            "shortId": reality.get("short-id", ""),
            "spiderX": reality.get("spx", "/"),
        }
    elif proxy.get("tls") or force_tls:
        # Xray 26.x removed ``allowInsecure`` (migrated to certificate pinning /
        # name verification, which needs a hash we do not have from a share
        # link).  Omit it; self-signed nodes should use mihomo instead.
        tls = {"fingerprint": fingerprint}
        if sni:
            tls["serverName"] = sni
        if alpn:
            tls["alpn"] = alpn
        stream["security"] = "tls"
        stream["tlsSettings"] = tls

    if network == "ws":
        ws = proxy.get("ws-opts") or {}
        ws_settings = {"path": ws.get("path") or "/"}
        headers = ws.get("headers") or {}
        host_header = headers.get("Host") or headers.get("host")
        if host_header:
            # Xray 26.x prefers the independent ``host`` field over headers.
            ws_settings["host"] = host_header
        stream["wsSettings"] = ws_settings
    elif network == "grpc":
        grpc = proxy.get("grpc-opts") or {}
        stream["grpcSettings"] = {"serviceName": grpc.get("grpc-service-name", "")}
    elif network == "http":
        http = proxy.get("h2-opts") or proxy.get("http-opts") or {}
        path = http.get("path") or "/"
        if isinstance(path, list):
            path = path[0] if path else "/"
        http_settings = {"path": path}
        host = http.get("host")
        if not host:
            headers = http.get("headers") or {}
            host = headers.get("Host") or headers.get("host")
        if isinstance(host, str):
            host = [host]
        if host:
            http_settings["host"] = host
        stream["httpSettings"] = http_settings
    elif network == "xhttp":
        xhttp = proxy.get("xhttp-opts") or {}
        xhttp_settings = {"path": xhttp.get("path") or "/"}
        if xhttp.get("host"):
            xhttp_settings["host"] = xhttp["host"]
        if xhttp.get("mode"):
            xhttp_settings["mode"] = xhttp["mode"]
        if xhttp.get("extra"):
            xhttp_settings["extra"] = xhttp["extra"]
        stream["xhttpSettings"] = xhttp_settings

    mark = _route_mark()
    if mark:
        # Xray outbound-only field: SO_MARK for the socket that connects to
        # the proxy server.  See _route_mark() for why this matters on OpenWrt.
        stream["sockopt"] = {"mark": mark}
    return stream


def _xray_outbound(proxy):
    validate_proxy(proxy, "xray")
    proxy_type = str(proxy.get("type", "")).lower()
    server = str(proxy.get("server", ""))
    port = int(proxy.get("port", 0))
    if not server or not port:
        raise CoreError("节点缺少 server/port")

    stream = _xray_stream(proxy, force_tls=(proxy_type == "trojan"))
    outbound = {
        "tag": "proxy",
        # Xray calls the protocol "shadowsocks"; the share-link scheme is "ss".
        "protocol": "shadowsocks" if proxy_type == "ss" else proxy_type,
        "streamSettings": stream,
    }

    if proxy_type == "vless":
        user = {
            "id": str(proxy.get("uuid", "")),
            "encryption": str(proxy.get("encryption") or "none"),
        }
        flow = proxy.get("flow")
        if flow:
            user["flow"] = flow
        outbound["settings"] = {
            "vnext": [{"address": server, "port": port, "users": [user]}],
        }
    elif proxy_type == "vmess":
        outbound["settings"] = {
            "vnext": [{
                "address": server,
                "port": port,
                "users": [{
                    "id": str(proxy.get("uuid", "")),
                    "alterId": int(proxy.get("alterId", 0) or 0),
                    "security": str(proxy.get("cipher") or "auto"),
                }],
            }],
        }
    elif proxy_type == "trojan":
        outbound["settings"] = {
            "servers": [{
                "address": server,
                "port": port,
                "password": str(proxy.get("password", "")),
            }],
        }
    elif proxy_type == "ss":
        outbound["settings"] = {
            "servers": [{
                "address": server,
                "port": port,
                "method": str(proxy.get("cipher", "")),
                "password": str(proxy.get("password", "")),
            }],
        }
    if not outbound.get("settings"):
        raise CoreError("xray 无法转换该节点")
    return outbound


def build_xray_config(proxy, socks_port, dns_nameserver=""):
    config = {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": int(socks_port),
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": False},
        }],
        "outbounds": [_xray_outbound(proxy)],
    }
    if dns_nameserver:
        config["dns"] = {"servers": [dns_nameserver]}
    return config


def build_config(proxy, socks_port, dns_nameserver="", core_type="mihomo"):
    if normalize_type(core_type) == "xray":
        return build_xray_config(proxy, socks_port, dns_nameserver)
    return build_mihomo_config(proxy, socks_port, dns_nameserver)


def write_config(path, proxy, socks_port, dns_nameserver="", core_type="mihomo"):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    chosen = normalize_type(core_type)
    payload = build_config(proxy, socks_port, dns_nameserver, chosen)
    if chosen == "xray":
        text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    else:
        text = yaml_dumps(payload)
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)
    return path


# ── process management ─────────────────────────────────────────────────
class CoreProcess:
    def __init__(self, proc, log_handle):
        self.proc = proc
        self._log_handle = log_handle

    def stop(self):
        proc = self.proc
        try:
            if proc.poll() is None:
                if hasattr(os, "killpg"):
                    try:
                        os.killpg(os.getpgid(proc.pid), 15)
                    except OSError:
                        proc.terminate()
                else:
                    proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    if hasattr(os, "killpg"):
                        try:
                            os.killpg(os.getpgid(proc.pid), 9)
                        except OSError:
                            proc.kill()
                    else:
                        proc.kill()
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        pass
        finally:
            try:
                self._log_handle.close()
            except OSError:
                pass


def start_core(binary, core_type, proxy, ip, socks_port, workdir, core_log,
               dns_nameserver="", config_name=""):
    """Start one core process bound to a private SOCKS port.

    Returns ``(CoreProcess, config_path)`` so the caller can verify that the
    generated config really points at the candidate IP.
    """
    chosen = normalize_type(core_type)
    workdir = Path(workdir).resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    default_name = "config-%d.%s" % (int(socks_port), "json" if chosen == "xray" else "yaml")
    config_path = (workdir / (config_name or default_name)).resolve()
    candidate = dict(proxy)
    candidate["server"] = ip
    try:
        write_config(config_path, candidate, socks_port, dns_nameserver, chosen)
    except OSError as exc:
        raise CoreError("无法写入内核配置 %s: %s" % (config_path, exc))
    try:
        log_handle = open(core_log, "ab", buffering=0)
    except OSError as exc:
        raise CoreError("无法打开内核日志 %s: %s" % (core_log, exc))

    binary_path = str(Path(binary).resolve())
    if chosen == "xray":
        command = [binary_path, "run", "-c", str(config_path)]
    else:
        command = [binary_path, "-f", str(config_path), "-d", str(workdir)]
    try:
        proc = subprocess.Popen(
            command,
            cwd=str(workdir),
            stdin=subprocess.DEVNULL,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    except OSError as exc:
        log_handle.close()
        raise CoreError("无法启动 %s: %s" % (CORE_LABELS[chosen], exc))
    return CoreProcess(proc, log_handle), config_path


def free_port(preferred):
    """Return the first free TCP port at or after ``preferred``."""
    for port in range(int(preferred), int(preferred) + 500):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise CoreError("no free local port near %d" % preferred)


def find_curl():
    return shutil.which("curl") or "/usr/bin/curl"
