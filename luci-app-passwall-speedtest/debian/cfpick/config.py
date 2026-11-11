"""Configuration file handling.

The config is a single JSON document (default /etc/cfpick/config.json).
It is deliberately plain JSON so it can be edited by hand as well as from the
web UI.  :func:`normalize` fills defaults and clamps values; unknown keys are
preserved so a newer UI writing extra fields does not lose them.
"""

import copy
import json
import os
import re
import tempfile
from pathlib import Path

from . import paths

REGION_CODES = [
    "JP", "SG", "KR", "HK", "TW", "TH", "VN", "ID", "PH", "MY",
    "IN", "KH", "DE", "NL", "FR", "GB", "FI", "SE", "CH", "RU",
    "TR", "UA", "US", "CA", "BR", "AU", "AE", "ZA",
]

DEFAULT_CONFIG = {
    "ip_source": "builtin_ipv4",          # builtin_ipv4 | builtin_ipv6 | online | custom_file
    # 可填多个地址（空格/换行分隔），逐个下载后合并；第一个失败会继续用后面的。
    # 自己的合并库（CFIP 仓库每小时生成）已包含 CM 源，保留 CM 作为 GitHub
    # 不可达时的兜底。
    "ip_online_url": ("https://raw.githubusercontent.com/urbanescavenger/"
                      "Cloudflare-IP/main/ip_libs.txt "
                      "https://zip.cm.edu.kg/all.txt"),
    # 界面上取消勾选的源存在这里，只为回显，不参与测速。
    "ip_online_disabled": "",
    "custom_ip_file": "",
    "custom_allip": False,
    "ip_lists": [
        {"enabled": True, "name": "JP/SG/KR", "regions": ["JP", "SG", "KR"],
         "port": 443, "latency_max": 0},
        {"enabled": False, "name": "", "regions": [], "port": 443, "latency_max": 0},
        {"enabled": False, "name": "", "regions": [], "port": 443, "latency_max": 0},
        {"enabled": False, "name": "", "regions": [], "port": 443, "latency_max": 0},
        {"enabled": False, "name": "", "regions": [], "port": 443, "latency_max": 0},
    ],
    # 延迟是 curl 经内核 SOCKS 测到的全链路 time_pretransfer，天然包含节点
    # 自身 RTT；远端节点常常 >200ms，默认卡上限会把所有候选全部丢弃，故默认不限。
    "latency_max": 0,
    "latency_min": 40,
    "loss_max": 0.2,
    "probe_url": "https://www.google.com/generate_204",
    "test_count": 30,
    "probe_timeout": 5,
    "probes": 3,
    "max_workers": 5,
    "download_enabled": True,
    "download_count": 5,
    "download_url": "https://speed.cloudflare.com/__down?bytes=10000000",
    "download_time": 10,
    "iterate_enabled": False,
    "iterate_minutes": 30,
    # 每轮收敛后剩余候选 ≤ 此数量即保存结果、该节点提前结束。
    # 与 download_count 相互独立：下载实测仍按自己的候选数执行。
    "iterate_converge_count": 5,
    # 成功后监测：worker 取得有效结果后，派生一个后台进程每分钟复测一次这个
    # 成功结果的延迟；连续 failures 次失败即触发该 worker 的复测（默认 1 次）。节点填了
    # DDNS 域名时测域名（解析到发布 IP）。worker 被下一次任务占用时监测退出。
    "monitor": {
        "enabled": True,
        "interval": 60,
        "failures": 1,
    },
    "nodes": [],
    "core": {
        "type": "mihomo",
        "paths": {"mihomo": "", "xray": ""},
        "dns_nameserver": "",
    },
    "ddns": {
        "enabled": False,
        "provider": "cloudflare",
        "ip_count": 1,
        "ttl": 300,
        "cloudflare": {
            "api_token": "",
            "zone_id": "",
            "zone_name": "",
            "proxied": False,
        },
    },
    "schedule": {
        "enabled": False,
        "custom_enabled": True,
        "custom_cron": "0 3 * * *",
        "hour": 24,
    },
    "web": {
        "listen": "127.0.0.1",
        "port": 8787,
        "token": "",
    },
    "export": {
        "csv": True,
        "json": True,
    },
}


def _as_bool(value, default=False):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        text = value.strip().lower()
        if text in ("1", "true", "yes", "on"):
            return True
        if text in ("0", "false", "no", "off", ""):
            return False
    return default


def _as_int(value, default, minimum=None, maximum=None):
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    if minimum is not None and number < minimum:
        number = minimum
    if maximum is not None and number > maximum:
        number = maximum
    return number


def _as_float(value, default, minimum=None, maximum=None):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    if minimum is not None and number < minimum:
        number = minimum
    if maximum is not None and number > maximum:
        number = maximum
    return number


def _clean_text(value, default=""):
    if value is None:
        return default
    return str(value).strip()


def _halfwidth(value):
    """Convert full-width ASCII forms that Chinese IMEs produce.

    Typing ``12`` with an IME in full-width mode yields ``１２`` (U+FF11
    U+FF12), which looks like ``1 2`` and would otherwise fail cron
    validation.  U+3000 (ideographic space) becomes a normal space.
    """
    out = []
    for char in str(value or ""):
        code = ord(char)
        if 0xFF01 <= code <= 0xFF5E:
            out.append(chr(code - 0xFEE0))
        elif code == 0x3000:
            out.append(" ")
        else:
            out.append(char)
    return "".join(out)


def _clean_domain(value):
    """Hostnames are stored lower-case and without the trailing root dot."""
    text = _halfwidth(_clean_text(value)).lower().replace("。", ".")
    return text.rstrip(".")


def _ttl(value):
    ttl = _as_int(value, 300, 1, 86400)
    # Cloudflare accepts 1 ("auto") or 60-86400; clamp the meaningless gap.
    return 60 if ttl != 1 and ttl < 60 else ttl


def _clean_name(value, fallback):
    name = _clean_text(value)
    name = re.sub(r"[\r\n,]+", " ", name)
    return name or fallback


def _normalize_regions(value):
    if isinstance(value, str):
        tokens = re.split(r"[\s,]+", value)
    elif isinstance(value, (list, tuple)):
        tokens = []
        for item in value:
            tokens.extend(re.split(r"[\s,]+", str(item)))
    else:
        tokens = []
    out = []
    for token in tokens:
        code = token.strip().upper()
        if code and code not in out:
            out.append(code)
    return out


def _normalize_ip_lists(value):
    source = value if isinstance(value, list) else []
    out = []
    for index in range(5):
        item = source[index] if index < len(source) and isinstance(source[index], dict) else {}
        out.append({
            "enabled": _as_bool(item.get("enabled"), index == 0),
            "name": _clean_text(item.get("name")),
            "regions": _normalize_regions(item.get("regions")),
            "port": _as_int(item.get("port"), 443, 1, 65535),
            # Per-list latency cap (ms); 0 inherits the global latency_max.
            # Regions differ: JP/HK can be tight while US/EU needs headroom.
            "latency_max": _as_int(item.get("latency_max"), 0, 0, 60000),
        })
    return out


def _normalize_nodes(value):
    source = value if isinstance(value, list) else []
    out = []
    for index, item in enumerate(source):
        if not isinstance(item, dict):
            continue
        link = _clean_text(item.get("link"))
        if not link:
            continue
        out.append({
            "name": _clean_name(item.get("name"), "node%d" % (index + 1)),
            "link": link,
            "ip_list": _clean_text(item.get("ip_list")),
            "ddns_domain": _clean_domain(item.get("ddns_domain")),
            "enabled": _as_bool(item.get("enabled"), True),
        })
    # make names unique; duplicate names would merge two workers' results
    seen = {}
    for node in out:
        base = node["name"]
        count = seen.get(base, 0)
        if count:
            node["name"] = "%s-%d" % (base, count + 1)
        seen[base] = count + 1
    return out


_MONTH_NAMES = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
}
_WEEKDAY_NAMES = {
    "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
}
# (minimum, maximum, allowed names) for minute/hour/day/month/weekday.
_CRON_FIELDS = (
    (0, 59, None),
    (0, 23, None),
    (1, 31, None),
    (1, 12, _MONTH_NAMES),
    (0, 7, _WEEKDAY_NAMES),
)


def _cron_value(token, minimum, maximum, names):
    token = token.lower()
    if names and token in names:
        return names[token]
    if token.isdigit():
        value = int(token)
        return value if minimum <= value <= maximum else None
    return None


def _valid_cron_field(part, minimum, maximum, names=None):
    if not part or not re.match(r"^[0-9A-Za-z*/,?-]+$", part):
        return False
    for item in part.split(","):
        if not item:
            return False
        base, separator, step = item.partition("/")
        if separator and (not step.isdigit() or int(step) <= 0):
            return False
        if base == "*":
            continue
        if "-" in base:
            start, _, end = base.partition("-")
            first = _cron_value(start, minimum, maximum, names)
            last = _cron_value(end, minimum, maximum, names)
            if first is None or last is None or first > last:
                return False
        elif _cron_value(base, minimum, maximum, names) is None:
            return False
    return True


def valid_cron(expr):
    """Validate a standard five-field crontab expression.

    Supports ``*``, numbers, names (jan/dec, sun/sat), ranges, lists and
    steps (``*/5``, ``mon-fri/2``).  Quartz-only tokens such as ``?`` are
    rejected because Debian's cron would not understand them.
    """
    parts = str(expr or "").split()
    if len(parts) != 5:
        return False
    return all(_valid_cron_field(part, *field)
               for part, field in zip(parts, _CRON_FIELDS))


def normalize(data):
    cfg = copy.deepcopy(DEFAULT_CONFIG)
    if isinstance(data, dict):
        for key, value in data.items():
            if key not in ("ip_lists", "nodes", "core", "schedule", "web", "export",
                           "ddns", "monitor"):
                cfg[key] = value

    cfg["ip_source"] = _clean_text(cfg.get("ip_source"), "builtin_ipv4")
    if cfg["ip_source"] not in ("builtin_ipv4", "builtin_ipv6", "online", "custom_file"):
        cfg["ip_source"] = "builtin_ipv4"
    # 在线源支持多个地址（空格/换行/逗号分隔），统一归一成空格分隔。
    online_urls = [item for item in
                   re.split(r"[\s,]+", _clean_text(cfg.get("ip_online_url")))
                   if item.startswith(("http://", "https://"))]
    cfg["ip_online_url"] = " ".join(online_urls) or DEFAULT_CONFIG["ip_online_url"]
    cfg["ip_online_disabled"] = " ".join(
        item for item in re.split(r"[\s,]+", _clean_text(cfg.get("ip_online_disabled")))
        if item.startswith(("http://", "https://")))
    cfg["custom_ip_file"] = _clean_text(cfg.get("custom_ip_file"))
    cfg["custom_allip"] = _as_bool(cfg.get("custom_allip"), False)

    cfg["ip_lists"] = _normalize_ip_lists(data.get("ip_lists") if isinstance(data, dict) else None)
    cfg["latency_max"] = _as_int(cfg.get("latency_max"), 0, 0, 60000)
    cfg["latency_min"] = _as_int(cfg.get("latency_min"), 40, 0, 60000)
    cfg["loss_max"] = _as_float(cfg.get("loss_max"), 0.2, 0.0, 1.0)
    cfg["probe_url"] = _clean_text(cfg.get("probe_url"), DEFAULT_CONFIG["probe_url"])
    cfg["test_count"] = _as_int(cfg.get("test_count"), 30, 1, 100000)
    cfg["probe_timeout"] = _as_int(cfg.get("probe_timeout"), 5, 1, 120)
    cfg["probes"] = _as_int(cfg.get("probes"), 3, 1, 5)
    cfg["max_workers"] = _as_int(cfg.get("max_workers"), 5, 0, 128)
    cfg["download_enabled"] = _as_bool(cfg.get("download_enabled"), True)
    cfg["download_count"] = _as_int(cfg.get("download_count"), 5, 1, 10)
    cfg["download_url"] = _clean_text(cfg.get("download_url"), DEFAULT_CONFIG["download_url"])
    cfg["download_time"] = _as_int(cfg.get("download_time"), 10, 1, 60)
    cfg["iterate_enabled"] = _as_bool(cfg.get("iterate_enabled"), False)
    cfg["iterate_minutes"] = _as_int(cfg.get("iterate_minutes"), 30, 1, 10080)
    cfg["iterate_converge_count"] = _as_int(
        cfg.get("iterate_converge_count"), 5, 1, 3000)

    monitor = data.get("monitor") if isinstance(data, dict) and isinstance(data.get("monitor"), dict) else {}
    cfg["monitor"] = {
        "enabled": _as_bool(monitor.get("enabled"), True),
        # 每分钟一次是默认节奏；下限 10s 防止误配把节点当成压力测试目标。
        "interval": _as_int(monitor.get("interval"), 60, 10, 3600),
        "failures": _as_int(monitor.get("failures"), 1, 1, 10),
    }

    cfg["nodes"] = _normalize_nodes(data.get("nodes") if isinstance(data, dict) else None)

    core = data.get("core") if isinstance(data, dict) and isinstance(data.get("core"), dict) else {}
    core_type = _clean_text(core.get("type"), "mihomo").lower()
    if core_type not in ("mihomo", "xray"):
        core_type = "mihomo"
    configured_paths = core.get("paths") if isinstance(core.get("paths"), dict) else {}
    # ``path`` was the single-core field in the first iteration of this branch;
    # migrate it to the selected core's per-module path.
    legacy_path = _clean_text(core.get("path"))
    cfg["core"] = {
        "type": core_type,
        "paths": {
            "mihomo": _clean_text(configured_paths.get("mihomo"))
            or (legacy_path if core_type == "mihomo" else ""),
            "xray": _clean_text(configured_paths.get("xray"))
            or (legacy_path if core_type == "xray" else ""),
        },
        "dns_nameserver": _clean_text(core.get("dns_nameserver")),
    }

    ddns = data.get("ddns") if isinstance(data, dict) and isinstance(data.get("ddns"), dict) else {}
    cloudflare = ddns.get("cloudflare") if isinstance(ddns.get("cloudflare"), dict) else {}
    cfg["ddns"] = {
        "enabled": _as_bool(ddns.get("enabled"), False),
        # Only Cloudflare is implemented; keep the field so the schema can grow.
        "provider": "cloudflare",
        "ip_count": _as_int(ddns.get("ip_count"), 1, 1, 10),
        "ttl": _ttl(ddns.get("ttl", 300)),
        "cloudflare": {
            "api_token": _clean_text(cloudflare.get("api_token")),
            "zone_id": _clean_text(cloudflare.get("zone_id")),
            "zone_name": _clean_domain(cloudflare.get("zone_name")),
            "proxied": _as_bool(cloudflare.get("proxied"), False),
        },
    }

    schedule = data.get("schedule") if isinstance(data, dict) and isinstance(data.get("schedule"), dict) else {}
    # A config that only has the old ``hour`` field keeps interval semantics;
    # anything else defaults to the five-field expression.
    legacy_interval = "custom_enabled" not in schedule and "hour" in schedule
    custom_cron = _clean_text(_halfwidth(schedule.get("custom_cron")),
                              DEFAULT_CONFIG["schedule"]["custom_cron"])
    custom_cron = " ".join(custom_cron.split())
    if not valid_cron(custom_cron):
        custom_cron = DEFAULT_CONFIG["schedule"]["custom_cron"]
    cfg["schedule"] = {
        "enabled": _as_bool(schedule.get("enabled"), False),
        "custom_enabled": _as_bool(schedule.get("custom_enabled"), not legacy_interval),
        "custom_cron": custom_cron,
        "hour": _as_int(schedule.get("hour"), 24, 1, 24),
    }

    web = data.get("web") if isinstance(data, dict) and isinstance(data.get("web"), dict) else {}
    cfg["web"] = {
        "listen": _clean_text(web.get("listen"), "127.0.0.1") or "127.0.0.1",
        "port": _as_int(web.get("port"), 8787, 1, 65535),
        "token": _clean_text(web.get("token")),
    }

    export = data.get("export") if isinstance(data, dict) and isinstance(data.get("export"), dict) else {}
    cfg["export"] = {
        "csv": _as_bool(export.get("csv"), True),
        "json": _as_bool(export.get("json"), True),
    }

    return cfg


def load(create=True):
    path = paths.CONFIG_FILE
    data = {}
    if path.exists():
        try:
            with open(path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            data = {}
    cfg = normalize(data)
    if create and not path.exists():
        try:
            save(cfg)
        except OSError:
            pass
    return cfg


def save(cfg):
    cfg = normalize(cfg)
    path = Path(paths.CONFIG_FILE)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(cfg, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
    return cfg
