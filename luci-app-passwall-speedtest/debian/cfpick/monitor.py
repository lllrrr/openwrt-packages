"""Background health monitor for a worker's chosen result.

After a run commits a node's best row, ``engine.run`` spawns one detached
``cfpick monitor --node NAME`` process per successful node (see
``spawn_successful``).  The monitor re-probes that result once per interval
(default 60s):

* a node with a DDNS domain is probed through the domain, resolved to the
  address the published record points at (the success IP is preferred when
  the record still contains it);
* every other node is probed at the best IP in ``result.csv``.

A probe uses the normal throw-away core + SOCKS path but ignores the selection
thresholds (latency_min/latency_max/loss_max): those decide which IP to keep,
not whether the already chosen one still answers.  ``failures`` consecutive
failed checks trigger the retest chain from ``cfpick monitor-retest``: a quick
retest (latency screening stops once ``download_count`` candidates pass, then
the download stage) followed by one normal retest whatever the quick result
was.  If neither pass produced a fresh result (the current IP/candidates are
dead), a third round re-fetches the normal candidate source instead of only
re-testing the stale rows.  The monitor then exits so the retest can take the
worker lock and, if a pass succeeds, spawn a new monitor.  The monitor also exits as soon
as a task takes that worker's lock, which is what "until the worker is
triggered again" means.

Monitor processes are intentionally lightweight and stateless across process
restarts: ``result.csv`` is the source of truth for the target, so a monitor
that survives a task (or starts late) always tests the latest committed row.
"""

import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from . import config, core, engine, lock, paths, result, tasklog
from .log import Logger

MONITOR_LOCK_DIR = paths.STATE_DIR / ".monitor-locks"
MONITOR_STATE_DIR = paths.STATE_DIR / ".monitor-state"


# ── process/lock helpers ─────────────────────────────────────────────────
def _lock_id(name):
    return hashlib.sha1(str(name).encode("utf-8")).hexdigest()[:16]


def _lock_path(name):
    return MONITOR_LOCK_DIR / (_lock_id(name) + ".lock")


def _state_path(name):
    return MONITOR_STATE_DIR / (_lock_id(name) + ".json")


def _read_int(path):
    try:
        return int(Path(path).read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return 0


def _pid_alive(pid):
    """True only for a live ``cfpick monitor`` process.

    The command-line token matters: PIDs are reused, and a stale lock must not
    be mistaken for a running monitor.  Non-Linux development falls back to
    ``os.kill(pid, 0)``.
    """
    if not pid:
        return False
    proc = Path("/proc") / str(int(pid))
    if proc.exists():
        try:
            cmdline = (proc / "cmdline").read_bytes().replace(b"\x00", b" ")
        except OSError:
            return False
        return b"cfpick" in cmdline and b"monitor" in cmdline
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, SystemError, ValueError):
        # Windows development raises SystemError for a foreign pid instead of
        # the POSIX ESRCH OSError.
        return False


def _lock_age(path):
    try:
        return time.time() - path.stat().st_mtime
    except OSError:
        return 0.0


def alive_monitors():
    """Map node name -> {pid, started} for live monitor processes."""
    out = {}
    if not MONITOR_LOCK_DIR.is_dir():
        return out
    for path in MONITOR_LOCK_DIR.iterdir():
        if not path.is_dir():
            continue
        pid = _read_int(path / "pid")
        if not _pid_alive(pid):
            # A lock that has just been mkdir'd but not yet got its pid file is
            # being created by another process; never reap that window.
            if not pid and _lock_age(path) < 10:
                continue
            shutil.rmtree(path, ignore_errors=True)
            continue
        try:
            name = (path / "name").read_text(encoding="utf-8").strip()
        except OSError:
            name = ""
        if name:
            out[name] = {"pid": pid, "started": _read_int(path / "started")}
    return out


def _acquire(name):
    MONITOR_LOCK_DIR.mkdir(parents=True, exist_ok=True)
    path = _lock_path(name)
    for _ in range(3):
        try:
            path.mkdir()
            (path / "pid").write_text(str(os.getpid()), encoding="utf-8")
            (path / "started").write_text(str(int(time.time())), encoding="utf-8")
            (path / "name").write_text(name, encoding="utf-8")
            return True
        except FileExistsError:
            owner = _read_int(path / "pid")
            if _pid_alive(owner):
                return False
            if not owner and _lock_age(path) < 10:
                return False  # another process is between mkdir and pid write
            shutil.rmtree(path, ignore_errors=True)
        except OSError:
            return False
    return False


def _release(name):
    path = _lock_path(name)
    if _read_int(path / "pid") == os.getpid():
        shutil.rmtree(path, ignore_errors=True)


def _worker_busy(name):
    """True while a real run holds this node's worker lock."""
    return name in lock.worker_states()


def stop_for(names, logger=None):
    """End monitors of nodes that are about to be tested by a new task."""
    for name in names or []:
        path = _lock_path(name)
        pid = _read_int(path / "pid")
        if not pid or pid == os.getpid() or not _pid_alive(pid):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
            if logger:
                logger.log("节点 %s 已被新任务触发，停止其后台监测" % name)
        except OSError:
            pass


# ── state for the web UI ─────────────────────────────────────────────────
def _write_state(name, target, ok, latency, failures, since):
    path = _state_path(name)
    payload = {
        "node": name,
        "kind": target.get("kind", ""),
        "target": target.get("label", ""),
        "ip": target.get("ip") or "",
        "latency": round(float(latency or 0.0), 2),
        "ok": bool(ok),
        "failures": int(failures),
        "checked_at": int(time.time()),
        "since": int(since),
        "pid": os.getpid(),
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = Path(str(path) + ".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass


def _read_state(name):
    try:
        with open(_state_path(name), "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _remove_state(name):
    try:
        _state_path(name).unlink()
    except OSError:
        pass


def status():
    """Live monitor information keyed by node name (for /api/status)."""
    out = {}
    for name, info in alive_monitors().items():
        entry = dict(info)
        entry.update(_read_state(name))
        out[name] = entry
    return out


# ── target selection ─────────────────────────────────────────────────────
def _find_node(cfg, name):
    for item in cfg.get("nodes", []):
        if not item.get("enabled", True):
            continue
        if (item.get("name") or "").strip() == name:
            return item
    return None


def _find_row(name):
    rows, _ = result.read_result()
    for row in rows:
        if row.node == name or (row.node_id and row.node_id == name):
            return row
    return None


def target_for(cfg, name):
    """Return the endpoint this worker's successful result points at.

    ``None`` means there is nothing to monitor (node removed/disabled or no
    committed row yet).  A DDNS node's target is its domain; the expected IP
    is carried along so a record that still contains the committed row is
    preferred over other addresses the domain may resolve to.
    """
    node = _find_node(cfg, name)
    if node is None:
        return None
    row = _find_row(name)
    if row is None or not row.ip:
        return None
    domain = (node.get("ddns_domain") or "").strip()
    if domain and (cfg.get("ddns") or {}).get("enabled"):
        return {"kind": "domain", "domain": domain, "label": domain,
                "ip": None, "expected": row.ip}
    return {"kind": "ip", "label": row.ip, "ip": row.ip, "expected": row.ip}


def resolve_host(domain):
    """Resolve a DDNS domain to IPs, IPv4 first, de-duplicated."""
    try:
        infos = socket.getaddrinfo(domain, None, proto=socket.IPPROTO_TCP)
    except (OSError, UnicodeError):
        return []
    ipv4 = []
    ipv6 = []
    for family, _type, _proto, _canon, sockaddr in infos:
        address = sockaddr[0] if sockaddr else ""
        if not address:
            continue
        bucket = ipv4 if family == socket.AF_INET else ipv6
        if address not in bucket:
            bucket.append(address)
    return ipv4 + ipv6


def _resolve_target(target):
    """Fill in ``target['ip']``; return an error text on failure.

    A DDNS record that was just updated is often still served as an empty/
    stale answer from the local resolver's negative cache.  That is not a
    node failure: probe the committed best IP until the domain catches up,
    otherwise the monitor would trigger a retest every minute forever.
    """
    if target["kind"] != "domain":
        return ""
    addresses = resolve_host(target["domain"])
    expected = target.get("expected") or ""
    if not addresses:
        if expected:
            target["ip"] = expected
            target["dns_pending"] = True
            return ""
        return "域名无解析"
    if expected and expected not in addresses:
        target["ip"] = expected
        target["dns_pending"] = True
        return ""
    target["ip"] = expected if expected in addresses else addresses[0]
    return ""


# ── probing ──────────────────────────────────────────────────────────────
class _Current:
    """Holder shared with the SIGTERM handler so probes are cleaned up."""
    engine = None


def _check(cfg, name, target, logger):
    """Probe one target.  Returns (ok, latency_ms, detail)."""
    error = _resolve_target(target)
    if error:
        return False, 0.0, error
    if target.get("dns_pending"):
        logger.log("监测 [%s] 域名解析未跟上最新结果，先测已发布 IP %s" % (
            name, target.get("ip") or ""))
    try:
        binary, core_type = core.ensure_core(cfg)
    except core.CoreError as exc:
        return False, 0.0, str(exc)

    instance = engine.Engine(
        cfg, logger, "retest", binary, core_type,
        _workdir(), node_names=[name], full_run=False)
    _Current.engine = instance
    try:
        nodes = instance._nodes()
        instance._assign_ports(nodes)
        keep, _sent, _recv, _loss, avg, reason = instance._probe_ip(
            nodes[0], target["ip"],
            "m%d" % (int(time.time() * 1000) % 100000),
            apply_filters=False)
    except (engine.EngineError, core.CoreError) as exc:
        return False, 0.0, str(exc)
    finally:
        instance.stop_all_cores()
        _Current.engine = None
    if not keep:
        return False, avg, reason or "探测失败"
    return True, avg, ""


# ── spawning ─────────────────────────────────────────────────────────────
def _child_env():
    env = os.environ.copy()
    env["CFPICK_APP_DIR"] = str(paths.APP_DIR)
    env["CFPICK_STATE_DIR"] = str(paths.STATE_DIR)
    env["CFPICK_CONFIG_DIR"] = str(paths.CONFIG_DIR)
    env["CFPICK_CONFIG"] = str(paths.CONFIG_FILE)
    env["CFPICK_LOG_DIR"] = str(paths.LOG_DIR)
    env["PYTHONPATH"] = str(paths.APP_DIR) + (
        os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    return env


def _spawn_detached(command, log):
    paths.SPAWN_LOG.parent.mkdir(parents=True, exist_ok=True)
    handle = open(paths.SPAWN_LOG, "ab", buffering=0)
    try:
        return subprocess.Popen(
            command,
            cwd=str(paths.APP_DIR),
            env=_child_env(),
            stdin=subprocess.DEVNULL,
            stdout=handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        handle.close()


def spawn(name, logger=None):
    """Spawn the monitor for one node unless it is disabled/already running."""
    cfg = config.load()
    if not cfg["monitor"]["enabled"]:
        return False
    if _worker_busy(name):
        return False
    if name in alive_monitors():
        return False
    try:
        process = _spawn_detached(
            [sys.executable, "-m", "cfpick", "monitor", "--node", name], logger)
    except OSError as exc:
        if logger:
            logger.log("无法启动节点 %s 的后台监测: %s" % (name, exc))
        return False
    if logger:
        logger.log("节点 %s 已成功后监测启动（PID %d，每 %ds 复测一次）" % (
            name, process.pid, cfg["monitor"]["interval"]))
    return True


def spawn_successful(details, logger=None):
    """Start monitors for the nodes a run committed successfully."""
    cfg = config.load()
    if not cfg["monitor"]["enabled"]:
        return []
    started = []
    for entry in details or []:
        if entry.get("status") != "ok":
            continue
        name = str(entry.get("node") or "").strip()
        if name and spawn(name, logger):
            started.append(name)
    return started


def _spawn_retest(name, logger):
    try:
        process = _spawn_detached(
            [sys.executable, "-m", "cfpick", "monitor-retest", "--node", name], logger)
    except OSError as exc:
        logger.log("监测触发复测失败 [%s]: %s" % (name, exc))
        return False
    logger.log("已触发节点 %s 的快速复测 + 正常复测（PID %d）" % (name, process.pid))
    return True


# ── the monitor loop ─────────────────────────────────────────────────────
def _sleep(seconds, name):
    """Sleep, but return False as soon as a task takes the worker lock."""
    deadline = time.time() + max(1, int(seconds))
    while time.time() < deadline:
        if _worker_busy(name):
            return False
        time.sleep(min(1.0, max(0.05, deadline - time.time())))
    return True


def _workdir():
    return paths.STATE_DIR / ("monitor.%d" % os.getpid())


def _reap_workdirs():
    """Remove work dirs left by monitors that died without cleanup."""
    try:
        directories = list(paths.STATE_DIR.glob("monitor.*"))
    except OSError:
        return
    for directory in directories:
        if not directory.is_dir() or directory == _workdir():
            continue
        try:
            pid = int(directory.name.split(".", 1)[1])
        except (IndexError, ValueError):
            continue
        if not _pid_alive(pid):
            shutil.rmtree(directory, ignore_errors=True)


def watch(name):
    """Run one node's monitor until a task triggers it or a retest is due."""
    cfg = config.load()
    if not cfg["monitor"]["enabled"]:
        return 0
    if not _acquire(name):
        return 0

    _reap_workdirs()
    logger = Logger(paths.MONITOR_LOG)
    started = int(time.time())
    failures = 0

    def _terminate(signum, _frame):
        logger.log("监测 [%s] 收到终止信号（%s），退出" % (name, signum))
        if _Current.engine is not None:
            _Current.engine.stop_all_cores()
        raise SystemExit(0)

    old_term = None
    try:
        old_term = signal.signal(signal.SIGTERM, _terminate)
    except (ValueError, OSError):
        pass

    logger.log("后台监测开始 [%s]：每 %ds 复测一次成功结果的延迟，连续 %d 次失败触发复测" % (
        name, cfg["monitor"]["interval"], cfg["monitor"]["failures"]))
    last_signature = None
    try:
        while True:
            cfg = config.load()
            settings = cfg["monitor"]
            if not settings["enabled"]:
                logger.log("监测 [%s] 已关闭，退出" % name)
                break
            if _worker_busy(name):
                logger.log("监测 [%s] worker 已被新任务触发，退出监测" % name)
                break
            target = target_for(cfg, name)
            if target is None:
                logger.log("监测 [%s] 节点已删除/停用或没有可监测的结果，退出" % name)
                break
            # A task may have committed a new result while this monitor was
            # sleeping (too short to catch the worker lock).  Follow the new
            # target and give it a fresh failure budget.
            signature = (target.get("kind"), target.get("label"),
                         target.get("expected"))
            if last_signature is not None and signature != last_signature:
                logger.log("监测 [%s] 成功结果已更新（%s），失败计数清零" % (
                    name, target.get("label") or ""))
                failures = 0
            last_signature = signature

            if lock.download_active_by_other(os.getpid()):
                logger.log("监测 [%s] 其他任务正在下载实测，本轮跳过" % name)
            else:
                ok, latency, detail = _check(cfg, name, target, logger)
                failures = 0 if ok else failures + 1
                _write_state(name, target, ok, latency, failures, started)
                logger.size_guard()
                label = target.get("label") or name
                if ok:
                    logger.log("监测 [%s] %s 延迟 %.2fms [正常]" % (
                        name, label, latency))
                else:
                    logger.log("监测 [%s] %s 失败（连续 %d/%d 次）%s" % (
                        name, label, failures, settings["failures"],
                        (": " + detail) if detail else ""))
                    tasklog.event(
                        "monitor_fail",
                        "监测 %s 失败（连续 %d/%d 次）%s" % (
                            name, failures, settings["failures"],
                            (": " + detail) if detail else ""))
                    if failures >= settings["failures"]:
                        if _spawn_retest(name, logger):
                            tasklog.event(
                                "monitor_retest",
                                "监测 %s 连续 %d 次失败，触发该 worker 复测" % (
                                    name, failures))
                            break
                        # Spawn failed: keep monitoring and try again next round.

            if not _sleep(settings["interval"], name):
                logger.log("监测 [%s] worker 已被新任务触发，退出监测" % name)
                break
    except SystemExit:
        raise
    except Exception as exc:  # a monitor bug must not leave a stale lock
        logger.log("监测 [%s] 异常退出: %s" % (name, exc))
    finally:
        _Current.engine = None
        if old_term is not None:
            try:
                signal.signal(signal.SIGTERM, old_term)
            except (ValueError, OSError):
                pass
        _remove_state(name)
        _release(name)
        shutil.rmtree(_workdir(), ignore_errors=True)
        logger.log("后台监测结束 [%s]" % name)
    return 0
