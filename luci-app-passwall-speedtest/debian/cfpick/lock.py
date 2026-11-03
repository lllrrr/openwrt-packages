"""Per-node run locks, run registry and the global download queue.

A run locks only the nodes it will test.  Two runs may probe disjoint nodes at
the same time; a node already in use is skipped (the rest of the run continues).
The download/write-back stage is serialized by one global commit lock, so two
downloads never fight over the same WAN bandwidth.

Every lock is a directory holding ``pid`` (and ``started``); the owner is
considered alive only when its process is a ``cfpick run`` process.  A lock
whose owner is gone (kill -9 / power loss) is taken over by the next run.
"""

import hashlib
import json
import os
import shutil
import time
from pathlib import Path

from . import paths

WORKER_LOCK_DIR = paths.STATE_DIR / ".worker-locks"
RUN_REGISTRY = paths.STATE_DIR / ".runs"
COMMIT_LOCK_DIR = paths.STATE_DIR / ".commit.lock"
RUN_PID_FILE = paths.STATE_DIR / "current_run"
COMMIT_WAIT_SECONDS = 4 * 3600


def _pid_alive(pid):
    if not pid:
        return False
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    proc = Path("/proc") / str(pid)
    if not proc.exists():
        return False
    try:
        cmdline = (proc / "cmdline").read_bytes().replace(b"\x00", b" ")
    except OSError:
        # Non-Linux (development on Windows): fall back to os.kill(pid, 0).
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    # Only an actual ``cfpick run`` process owns a lock; the web server also
    # runs as ``python3 -m cfpick serve``.
    return b"cfpick" in cmdline and b" run " in (cmdline + b" ")


def _lock_owner(path):
    try:
        return int((path / "pid").read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return 0


def _lock_started(path):
    try:
        return int((path / "started").read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return 0


def _owner_alive(path):
    return _pid_alive(_lock_owner(path))


def _take_lock(path, cap, log, label):
    """Atomically take a mkdir lock.  Returns False when a live owner holds it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    attempts = 0
    while True:
        try:
            path.mkdir()
            (path / "pid").write_text(str(os.getpid()), encoding="utf-8")
            (path / "started").write_text(str(int(time.time())), encoding="utf-8")
            return True
        except FileExistsError:
            pass
        except OSError:
            return False

        pid = _lock_owner(path)
        if _owner_alive(path):
            started = _lock_started(path)
            age = int(time.time()) - started if started else 0
            if started and age > cap:
                log.log("%s 的锁已持有 %ds 超过上限 %ds（PID %s 疑似僵死），接管" % (
                    label, age, cap, pid))
            else:
                return False
        else:
            log.log("%s 的锁为残留（PID %s 已不存在），接管" % (label, pid or "未知"))

        shutil.rmtree(path, ignore_errors=True)
        attempts += 1
        if attempts >= 3:
            return False


def _lock_id(name):
    return hashlib.sha1(str(name).encode("utf-8")).hexdigest()[:16]


def _legacy_pid():
    """PID of a run from before per-node locks (global .run.lock)."""
    try:
        pid = int((paths.RUN_LOCK_DIR / "pid").read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    return pid if _pid_alive(pid) else None


def run_pids():
    """All live cfpick run PIDs, including legacy global-lock runs."""
    pids = []
    if RUN_REGISTRY.is_dir():
        for entry in RUN_REGISTRY.iterdir():
            try:
                pid = int(entry.name)
            except ValueError:
                continue
            if _pid_alive(pid) and pid not in pids:
                pids.append(pid)
    legacy = _legacy_pid()
    if legacy and legacy not in pids:
        pids.append(legacy)
    return pids


def other_runs_active():
    return any(pid != os.getpid() for pid in run_pids())


def current_run_pid():
    pids = run_pids()
    return pids[0] if pids else None


def is_running():
    return bool(run_pids())


class RunLock:
    def __init__(self, logger):
        self.log = logger
        self.pid = os.getpid()
        self.run_dir = None
        self.node_names = []
        self._locks = []

    def acquire(self, iterate=False, iterate_minutes=30, nodes=None):
        paths.STATE_DIR.mkdir(parents=True, exist_ok=True)
        requested = []
        for name in nodes or []:
            name = str(name or "").strip()
            if name and name not in requested:
                requested.append(name)
        if not requested:
            self.log.log("没有可用的待测节点，本次跳过")
            return False

        cap = iterate_minutes * 60 + 1800 if iterate else 43200
        acquired = []
        for name in sorted(requested):
            path = WORKER_LOCK_DIR / (_lock_id(name) + ".lock")
            if _take_lock(path, cap, self.log, "节点 %s" % name):
                try:
                    (path / "name").write_text(name, encoding="utf-8")
                except OSError:
                    pass
                acquired.append(name)
            else:
                self.log.log("节点 %s 正在被另一个任务使用，本次跳过该节点（其余节点继续）" % name)

        if not acquired:
            self.log.log("所选节点都在使用，本次跳过")
            return False

        self.node_names = acquired
        self._locks = [WORKER_LOCK_DIR / (_lock_id(name) + ".lock") for name in acquired]
        self.run_dir = paths.STATE_DIR / ("run.%d" % self.pid)
        shutil.rmtree(self.run_dir, ignore_errors=True)
        try:
            self.run_dir.mkdir(parents=True, exist_ok=True)
        except OSError:
            self._release_node_locks()
            return False

        self._reap_stale_run_dirs()
        try:
            RUN_REGISTRY.mkdir(parents=True, exist_ok=True)
            (RUN_REGISTRY / str(self.pid)).write_text(
                "dir=%s\nnodes=%s\nstarted=%d\n" % (
                    self.run_dir, ",".join(acquired), int(time.time())),
                encoding="utf-8")
            RUN_PID_FILE.write_text(str(self.pid), encoding="utf-8")
        except OSError:
            pass
        return True

    def _release_node_locks(self):
        for path in self._locks:
            if _lock_owner(path) == self.pid:
                shutil.rmtree(path, ignore_errors=True)
        self._locks = []
        self.node_names = []

    def release(self):
        self._release_node_locks()
        if self.run_dir:
            shutil.rmtree(self.run_dir, ignore_errors=True)
        self.run_dir = None
        try:
            (RUN_REGISTRY / str(self.pid)).unlink()
        except OSError:
            pass
        try:
            if RUN_PID_FILE.read_text(encoding="utf-8").strip() == str(self.pid):
                RUN_PID_FILE.unlink()
        except OSError:
            pass

    def _reap_stale_run_dirs(self):
        for directory in paths.STATE_DIR.glob("run.*"):
            if not directory.is_dir() or directory == self.run_dir:
                continue
            try:
                pid = int(directory.name.split(".", 1)[1])
            except (IndexError, ValueError):
                continue
            if not _pid_alive(pid):
                shutil.rmtree(directory, ignore_errors=True)


# ── download / write-back queue ──────────────────────────────────────────
def acquire_commit(logger, timeout=COMMIT_WAIT_SECONDS):
    """Wait for the global download slot.  Stop does not abort this wait:
    a run that finished probing still completes its own download."""
    paths.STATE_DIR.mkdir(parents=True, exist_ok=True)
    waited = 0
    while True:
        try:
            COMMIT_LOCK_DIR.mkdir()
            (COMMIT_LOCK_DIR / "pid").write_text(str(os.getpid()), encoding="utf-8")
            (COMMIT_LOCK_DIR / "started").write_text(str(int(time.time())), encoding="utf-8")
            return True
        except FileExistsError:
            pass
        except OSError:
            return False

        pid = _lock_owner(COMMIT_LOCK_DIR)
        if _owner_alive(COMMIT_LOCK_DIR):
            started = _lock_started(COMMIT_LOCK_DIR)
            age = int(time.time()) - started if started else 0
            if started and age > 43200:
                logger.log("下载锁已持有 %ds（PID %s 疑似僵死），接管" % (age, pid))
            else:
                waited += 1
                if waited % 30 == 0:
                    logger.log("等待其他任务完成下载/写回（已等待 %ds，PID %s）" % (waited, pid))
                if waited >= timeout:
                    logger.log("等待下载锁超过 %d 秒，本次放弃" % timeout)
                    return False
                time.sleep(1)
                continue
        else:
            logger.log("下载锁为残留（PID %s 已不存在），接管" % (pid or "未知"))
        shutil.rmtree(COMMIT_LOCK_DIR, ignore_errors=True)


def release_commit():
    if _lock_owner(COMMIT_LOCK_DIR) == os.getpid():
        shutil.rmtree(COMMIT_LOCK_DIR, ignore_errors=True)


def download_active_by_other(pid=None):
    """True while another run holds the download slot (probes should pause)."""
    if not COMMIT_LOCK_DIR.exists():
        return False
    pid = os.getpid() if pid is None else pid
    owner = _lock_owner(COMMIT_LOCK_DIR)
    return bool(owner and owner != pid and _owner_alive(COMMIT_LOCK_DIR))


# ── shared state ─────────────────────────────────────────────────────────
def read_state():
    try:
        with open(paths.STATE_FILE, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_state(**fields):
    state = read_state()
    state.update(fields)
    state["updated_at"] = int(time.time())
    paths.STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(paths.STATE_FILE) + ".tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(state, handle, ensure_ascii=False)
        os.replace(tmp, paths.STATE_FILE)
    except OSError:
        pass
    return state


def request_stop():
    paths.STATE_DIR.mkdir(parents=True, exist_ok=True)
    paths.STOP_FILE.touch()


def clear_stop():
    try:
        paths.STOP_FILE.unlink()
    except OSError:
        pass


def stop_requested():
    return paths.STOP_FILE.exists()
