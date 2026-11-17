"""本机联网判定（稳定参考地址）与断网挂起等待。

测速探测失败 / 监测失败有两种原因：节点侧真的坏了，或者只是本机断网（光猫、
上游掉线）。后者不该把候选 IP 全测成假死结果，也不该计入监测失败阈值。用一
个稳定的公共参考地址（netcheck_target，默认阿里 DNS 223.5.5.5）直连判定本机
联网——注意这是绕过代理的本机探测，参考地址不响应才视本机断网：

* ping（ICMP）与向该地址发一次 DNS 查询（UDP/53）两种方式都不通才算断网，
  部分环境禁 ICMP，主流参考地址都是公共 DNS；
* 单次失败可能只是瞬时丢包，两种方式连试两轮；
* offline() 结果缓存 10 秒，避免几千个候选 IP 的高频探测把 ping 打爆。

wait_online() 在断网期间把任务挂起：测速入口、探测循环与下载阶段都经它等待
网络恢复后原样继续；等待期间收到停止请求则返回 False。定时任务与手动操作最
终都只在测速这一层拦（cron 层不加）：运行锁在挂起期间保持，后续触发直接被
锁挡掉，不会堆排队列。
"""

import shutil
import socket
import struct
import subprocess
import time

CHECK_CACHE_SECONDS = 10.0
PING_TIMEOUT = 2
DNS_TIMEOUT = 3
WAIT_POLL_SECONDS = 5.0

DEFAULT_TARGET = "223.5.5.5"

# 查询名固定一个：能得到应答（哪怕 NXDOMAIN）就说明参考地址可达。
_DNS_QUERY_NAME = "one.one.one.one"


def _dns_query_packet():
    parts = bytearray(struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0))
    for label in _DNS_QUERY_NAME.split("."):
        parts += bytes([len(label)]) + label.encode("ascii")
    parts += b"\x00" + struct.pack(">HH", 1, 1)  # QTYPE=A, QCLASS=IN
    return bytes(parts)


def enabled(cfg):
    """断网判定开关（monitor.netcheck_enabled，默认开）。"""
    monitor = (cfg or {}).get("monitor") or {}
    return bool(monitor.get("netcheck_enabled", True))


def target(cfg):
    """稳定参考地址（monitor.netcheck_target，默认阿里 DNS 223.5.5.5）。"""
    monitor = (cfg or {}).get("monitor") or {}
    value = str(monitor.get("netcheck_target") or DEFAULT_TARGET).strip()
    return value or DEFAULT_TARGET


def _icmp_ok(host):
    """ping 一次；没有 ping 命令（少见）按失败处理。"""
    if shutil.which("ping") is None:
        return False
    try:
        probe = subprocess.run(
            ["ping", "-c", "1", "-W", str(PING_TIMEOUT), host],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, ValueError):
        return False
    return probe.returncode == 0


def _dns_ok(host):
    """向 host:53 发一次最小化 A 查询，收到应答（哪怕 NXDOMAIN）即视为可达。"""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(DNS_TIMEOUT)
            sock.sendto(_dns_query_packet(), (host, 53))
            data, _addr = sock.recvfrom(512)
    except (OSError, UnicodeError):
        # host 是带 unicode 的主机名时 sendto 的解析失败也落在这里。
        return False
    return len(data) >= 12  # 至少一个完整 DNS 头


def _offline_now(host):
    """一次完整判定：两种方式连试两轮都不通才算断网。"""
    for attempt in (1, 2):
        if _icmp_ok(host) or _dns_ok(host):
            return False
        if attempt == 1:
            time.sleep(1)
    return True


_cache = {"expires": 0.0, "offline": True, "target": ""}
_logged_offline = False


def offline(cfg, force=False):
    """本机是否断网（True=断网）。未启用判定、结果缓存期间直接返回缓存值。"""
    global _logged_offline
    if not enabled(cfg):
        _logged_offline = False
        return False
    host = target(cfg)
    now = time.time()
    if not force and _cache["target"] == host and now < _cache["expires"]:
        return _cache["offline"]
    offline_now = _offline_now(host)
    _cache.update({"expires": now + CHECK_CACHE_SECONDS,
                   "offline": offline_now, "target": host})
    if not offline_now:
        _logged_offline = False
    return offline_now


def wait_online(cfg, logger=None, stop=None):
    """断网时挂起等待网络恢复。返回 True=已联网；False=等待期间收到停止。

    恢复/挂起状态只播报一次（每个断网回合一次），探测循环里高频调用不会刷屏。
    """
    global _logged_offline
    if not offline(cfg):
        return True
    host = target(cfg)
    if not _logged_offline:
        _logged_offline = True
        if logger:
            logger.log("稳定参考 %s 无响应，判定本机断网，挂起等待网络恢复" % host)
    while offline(cfg):
        if stop is not None and stop():
            if logger:
                logger.log("断网等待期间收到停止请求，退出")
            return False
        time.sleep(WAIT_POLL_SECONDS)
    _logged_offline = False
    if logger:
        logger.log("网络已恢复，继续测速")
    return True
