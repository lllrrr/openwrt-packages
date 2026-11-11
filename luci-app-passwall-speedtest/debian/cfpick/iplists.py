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

from . import paths, result, tasklog

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


def split_urls(value):
    """`ip_online_url` 允许空格/换行/逗号分隔多个地址。"""
    return [item for item in re.split(r"[\s,]+", value or "") if item]


def _parse_online_text(text):
    entries, seen = [], set()
    for line in text.splitlines():
        match = ONLINE_LINE.match(line.strip())
        if not match:
            continue
        key = (match.group(1), int(match.group(2)), match.group(3))
        if key not in seen:
            seen.add(key)
            entries.append(key)
    return entries


def fetch_online(value, logger, timeout=30, retries=3):
    """Download every configured online source. Returns [(ip, port, region)].

    ``value`` may hold several space separated URLs (our merged library plus
    the CM source as a fallback, for example).  A source that fails or yields
    no valid line is skipped; the run only fails when every source is empty
    and there is no cache to fall back to.
    """
    urls = split_urls(value)
    if not urls:
        raise IpListError("在线源地址为空")

    entries, seen = [], set()
    for url in urls:
        text = ""
        last_error = ""
        for attempt in range(1, retries + 1):
            try:
                logger.log("下载在线 IP 列表: %s" % url)
                text = _fetch_text(url, timeout, logger)
                if text.strip():
                    break
                last_error = "响应为空"
            except (urllib.error.URLError, OSError) as exc:
                last_error = str(exc)
            if attempt < retries:
                logger.log("下载失败(第 %d 次): %s,重试..." % (attempt, last_error))

        parsed = _parse_online_text(text) if text.strip() else []
        if not parsed:
            logger.log("在线源无有效条目，跳过: %s（%s）" % (url, last_error or "空响应"))
            continue
        added = 0
        for item in parsed:
            if item not in seen:
                seen.add(item)
                entries.append(item)
                added += 1
        logger.log("在线源就绪: %d 条（新增 %d） <- %s" % (len(parsed), added, url))

    if entries:
        ipv4_443 = {ip for ip, port, _ in entries if port == 443}
        if len(ipv4_443) < MIN_ONLINE_LINES:
            logger.log("在线 IP 行数偏少 (%d < %d)，继续使用" % (len(ipv4_443), MIN_ONLINE_LINES))

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


def node_latency_max(cfg, node):
    """Effective latency cap (ms) for a node, 0 meaning unlimited.

    A CM list can carry its own cap because regions differ: JP/HK can be kept
    under ~120ms while US/EU candidates are usually slower.  A positive
    per-list value overrides the global ``latency_max``; 0 inherits it.
    """
    lists = cfg.get("ip_lists") or []
    chosen = str(node.get("ip_list") or "").strip()
    if not chosen:
        for index, item in enumerate(lists):
            if item.get("enabled"):
                chosen = "list%d" % (index + 1)
                break
    if chosen.startswith("list"):
        try:
            index = int(chosen[4:]) - 1
        except ValueError:
            index = -1
        if 0 <= index < len(lists):
            try:
                limit = int(lists[index].get("latency_max") or 0)
            except (TypeError, ValueError):
                limit = 0
            if limit > 0:
                return limit
    try:
        return int(cfg.get("latency_max") or 0)
    except (TypeError, ValueError):
        return 0


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
    logger.log("复测模式：候选来自现有 result.csv / 节点原始地址（不重新下载在线列表），共 %d 个" % total)
    return CandidateSet(source="retest", per_node=per_node, limit=cfg["test_count"])


def select(cfg, nodes, mode, logger, refresh=False):
    """Pick candidate IPs for a run.

    ``refresh`` forces the normal source even in retest mode: the third round
    after a monitor failure re-fetches the online/file list instead of only
    re-testing the current (possibly dead) rows.
    """
    if mode != "retest" or refresh:
        return _normal_candidates(cfg, nodes, logger)

    candidates = retest_candidates(cfg, nodes, logger)
    # 复测只有 0/1 个候选时，这个 worker 实际上没法“择优”，一旦那一个 IP
    # 失效就会一直失败。对这些 worker 退回普通测速：按配置的 IP 来源重新
    # 拉取列表（在线 CM 源会重新下载），其余 worker 仍走复测。
    sparse = [node for node in nodes
              if len(candidates.per_node.get(node["name"], [])) <= 1]
    if not sparse:
        return candidates

    logger.log("复测候选不足 2 个的 worker: %s；改为普通测速并重新拉取列表 IP" % (
        "、".join(node["name"] for node in sparse)))
    tasklog.event(
        "candidate_refresh",
        "复测候选不足 2 个（%s），清空后改为普通测速重新拉取列表" % (
            "、".join(node["name"] for node in sparse)))
    normal = _normal_candidates(cfg, sparse, logger)
    for node in sparse:
        name = node["name"]
        before = len(candidates.per_node.get(name, []))
        # 普通测速可能是共享列表（内置/自定义文件），用 for_node 统一取。
        candidates.per_node[name] = list(normal.for_node(name))
        logger.log("worker [%s] 复测只有 %d 个候选，已改用普通测速候选（%d 个）" % (
            name, before, len(candidates.per_node[name])))

    if not any(candidates.per_node.values()):
        raise IpListError("复测候选不足且普通测速也没有取到候选 IP")
    return candidates


def _normal_candidates(cfg, nodes, logger):
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
