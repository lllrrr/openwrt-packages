"""Candidate Cloudflare IP sources.

Sources mirror the OpenWrt version:
  * built-in IPv4 / IPv6 CIDR list (expanded: one random IP per /24, or every
    address in a /24 when ``custom_allip`` is on)
  * online CM source (``IP:PORT#CC``), filtered per list by port + country
  * custom file (same formats, CIDRs supported)
  * retest mode: reuse the current result.csv rows per node
"""

import ipaddress
import os
import random
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List

from . import paths, result

ONLINE_LINE = re.compile(r"^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)#([A-Za-z0-9]+)$")
MIN_ONLINE_LINES = 50
USER_AGENT = "cfpick/1.0"


class IpListError(RuntimeError):
    pass


@dataclass
class CandidateSet:
    source: str
    shared: List[str] = field(default_factory=list)
    per_node: Dict[str, List[str]] = field(default_factory=dict)
    lists: Dict[str, List[str]] = field(default_factory=dict)
    limit: int = 30

    def for_node(self, node_name, ip_list=""):
        if self.per_node:
            candidates = self.per_node.get(node_name, [])
        else:
            candidates = self.shared
        return candidates[:self.limit]


def _random_in(network):
    count = network.num_addresses
    if count <= 2:
        return network.network_address
    return network.network_address + random.randrange(1, count)


def _expand_network(network, all_ip, limit):
    """Yield candidate addresses from a CIDR, at most ``limit`` of them."""
    produced = 0
    if network.version == 4:
        if all_ip:
            # Every usable address, walking /24 blocks first so the sample
            # stays broad across the prefix (the count is capped by limit).
            blocks = (network.subnets(new_prefix=24)
                      if network.prefixlen < 24 else [network])
            for block in blocks:
                for address in block.hosts():
                    yield str(address)
                    produced += 1
                    if produced >= limit:
                        return
        elif network.prefixlen <= 24:
            for block in network.subnets(new_prefix=24):
                yield str(_random_in(block))
                produced += 1
                if produced >= limit:
                    return
        else:
            yield str(_random_in(network))
        return

    # IPv6: one address per /64 keeps the sample spread across the prefix.
    if network.prefixlen <= 64:
        for block in network.subnets(new_prefix=64):
            yield str(_random_in(block))
            produced += 1
            if produced >= limit:
                return
    else:
        yield str(_random_in(network))


def _tokens_from_line(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    match = ONLINE_LINE.match(line)
    if match:
        return match.group(1)
    # Tolerate "IP:PORT" / "IP#CC" lines in custom files.
    head = line.split("#", 1)[0]
    if re.match(r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$", head):
        return head.split(":", 1)[0]
    return line


def load_file(path, all_ip=False, limit=30, logger=None):
    path = Path(path)
    if not path.exists():
        raise IpListError("IP 列表文件不存在: %s" % path)

    out = []
    seen = set()
    invalid = 0
    expanded = 0
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            token = _tokens_from_line(raw)
            if not token:
                continue
            try:
                if "/" in token:
                    network = ipaddress.ip_network(token, strict=False)
                    for address in _expand_network(network, all_ip, limit):
                        if address not in seen:
                            seen.add(address)
                            out.append(address)
                        expanded += 1
                        if len(out) >= limit:
                            break
                    if len(out) >= limit:
                        break
                    continue
                address = str(ipaddress.ip_address(token))
            except ValueError:
                invalid += 1
                continue
            if address not in seen:
                seen.add(address)
                out.append(address)
            if len(out) >= limit:
                break

    if logger:
        logger.log("候选 IP 列表就绪: %s -> %d 个候选%s%s" % (
            path, len(out),
            "（展开自 CIDR）" if expanded else "",
            "，忽略 %d 行无效内容" % invalid if invalid else ""))
    if not out:
        raise IpListError("IP 列表为空: %s" % path)
    return out


def _fetch_text(url, timeout, logger):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def fetch_online(url, logger, timeout=30, retries=3):
    """Download and validate the CM source. Returns [(ip, port, region)]."""
    text = ""
    last_error = ""
    for attempt in range(1, retries + 1):
        try:
            logger.log("下载在线 CM IP 列表: %s" % url)
            text = _fetch_text(url, timeout, logger)
            if text.strip():
                break
            last_error = "响应为空"
        except (urllib.error.URLError, OSError) as exc:
            last_error = str(exc)
        if attempt < retries:
            logger.log("下载失败(第 %d 次): %s,重试..." % (attempt, last_error))

    entries = []
    if text.strip():
        seen = set()
        for line in text.splitlines():
            match = ONLINE_LINE.match(line.strip())
            if not match:
                continue
            key = (match.group(1), int(match.group(2)), match.group(3))
            if key not in seen:
                seen.add(key)
                entries.append(key)
        ipv4_443 = {ip for ip, port, _ in entries if port == 443}
        if len(ipv4_443) < MIN_ONLINE_LINES:
            logger.log("在线 IP 行数过少 (%d < %d)，疑似源异常" % (len(ipv4_443), MIN_ONLINE_LINES))
            entries = []
    else:
        logger.log("在线列表下载失败: %s" % last_error)

    if not entries:
        if paths.ONLINE_CACHE.exists():
            logger.log("回退到上次缓存的在线 IP 列表: %s" % paths.ONLINE_CACHE)
            cached = []
            for line in paths.ONLINE_CACHE.read_text(encoding="utf-8", errors="replace").splitlines():
                match = ONLINE_LINE.match(line.strip())
                if match:
                    cached.append((match.group(1), int(match.group(2)), match.group(3)))
            entries = cached
        if not entries:
            raise IpListError("在线 CM IP 列表下载失败且无可用缓存")

    paths.STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(paths.ONLINE_CACHE) + ".tmp")
    tmp.write_text("\n".join("%s:%d#%s" % item for item in entries) + "\n", encoding="utf-8")
    os.replace(tmp, paths.ONLINE_CACHE)

    logger.log("在线 CM 原始列表就绪: %d 条 IP:PORT#CC" % len(entries))
    return entries


def build_online_lists(entries, ip_lists, logger):
    lists = {}
    all_443 = sorted({ip for ip, port, _ in entries if port == 443})
    for index, settings in enumerate(ip_lists, start=1):
        name = "list%d" % index
        if not settings.get("enabled"):
            continue
        port = int(settings.get("port", 443))
        regions = settings.get("regions") or []
        wanted = set(regions)
        ips = sorted({
            ip for ip, entry_port, region in entries
            if entry_port == port and (not wanted or region.upper() in wanted)
        })
        lists[name] = ips
        if logger:
            logger.log("CM IP 列表 %s 就绪: %d 个 IP（端口 %s，regions: %s）" % (
                name, len(ips), port, " ".join(regions) if regions else "全部"))
    lists["_fallback"] = all_443
    return lists


def default_list(ip_lists):
    for index, settings in enumerate(ip_lists, start=1):
        if settings.get("enabled"):
            return "list%d" % index
    return ""


def retest_candidates(cfg, nodes, logger):
    rows, _ = result.read_result()
    per_node = {}
    for node in nodes:
        ips = []
        server = node["parsed"].server
        try:
            ipaddress.ip_address(server)
            ips.append(server)
        except ValueError:
            pass
        for row in rows:
            if row.node == node["name"]:
                ips.append(row.ip)
        deduped = []
        for ip in ips:
            if ip and ip not in deduped:
                deduped.append(ip)
        per_node[node["name"]] = deduped[:cfg["test_count"]]
    total = sum(len(value) for value in per_node.values())
    if total == 0:
        raise IpListError("复测模式没有候选 IP：当前 result.csv 为空且节点地址不是 IP")
    logger.log("复测模式：候选来自现有 result.csv / 节点原始地址（不重新下载在线列表），共 %d 个" % total)
    return CandidateSet(source="retest", per_node=per_node, limit=cfg["test_count"])


def select(cfg, nodes, mode, logger):
    if mode == "retest":
        return retest_candidates(cfg, nodes, logger)

    if cfg["ip_source"] == "online":
        entries = fetch_online(cfg["ip_online_url"], logger)
        lists = build_online_lists(entries, cfg["ip_lists"], logger)
        fallback = default_list(cfg["ip_lists"])
        per_node = {}
        for node in nodes:
            chosen = node.get("ip_list") or fallback
            if chosen and chosen in lists:
                ips = lists[chosen]
            else:
                ips = lists.get("_fallback", [])
            per_node[node["name"]] = ips
            logger.log("worker [%s] 使用 CM 列表 %s（%d 个候选，最多测 %d 个）" % (
                node["name"], chosen or "全部 :443", len(ips), cfg["test_count"]))
        return CandidateSet(source="online", per_node=per_node,
                            lists={k: v for k, v in lists.items() if not k.startswith("_")},
                            limit=cfg["test_count"])

    if cfg["ip_source"] == "builtin_ipv4":
        path = paths.BUILTIN_DIR / "ip.txt"
    elif cfg["ip_source"] == "builtin_ipv6":
        path = paths.BUILTIN_DIR / "ipv6.txt"
    else:
        path = Path(cfg["custom_ip_file"] or "")
        if not str(path) or not cfg["custom_ip_file"]:
            raise IpListError("自定义 IP 列表文件未填写")
    shared = load_file(path, all_ip=cfg["custom_allip"], limit=cfg["test_count"], logger=logger)
    return CandidateSet(source=cfg["ip_source"], shared=shared, limit=cfg["test_count"])
