"""Single-run lock and shared run state.

Only one full run may be active at a time: cron overlap, repeated UI clicks and
a manual SSH run would otherwise fight over the same proxy ports and result
files.  A stale lock (kill -9 / power loss) is taken over when its PID is gone
or its age exceeds the configured budget.
"""

import json
import os
import shutil
import time
from pathlib import Path

from . import paths


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
    # The web server also runs as ``python3 -m cfpick serve``; only a
    # process with the ``run`` sub-command is an actual speed test.
    return b"cfpick" in cmdline and b" run " in (cmdline + b" ")


def current_run_pid():
    pid_file = paths.RUN_LOCK_DIR / "pid"
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    return pid if _pid_alive(pid) else None


def is_running():
    return current_run_pid() is not None


class RunLock:
    def __init__(self, logger):
        self.log = logger
        self.pid = os.getpid()
        self.run_dir = None

    def acquire(self, iterate=False, iterate_minutes=30):
        paths.STATE_DIR.mkdir(parents=True, exist_ok=True)
        attempts = 0
        while True:
            try:
                paths.RUN_LOCK_DIR.mkdir()
                (paths.RUN_LOCK_DIR / "pid").write_text(str(self.pid), encoding="utf-8")
                (paths.RUN_LOCK_DIR / "started").write_text(str(int(time.time())), encoding="utf-8")
                self.run_dir = paths.STATE_DIR / ("run.%d" % self.pid)
                shutil.rmtree(self.run_dir, ignore_errors=True)
                self.run_dir.mkdir(parents=True, exist_ok=True)
                self._reap_stale_run_dirs()
                return True
            except FileExistsError:
                pass
            except OSError:
                shutil.rmtree(paths.RUN_LOCK_DIR, ignore_errors=True)
                return False

            try:
                pid = int((paths.RUN_LOCK_DIR / "pid").read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                pid = 0
            if _pid_alive(pid):
                try:
                    started = int((paths.RUN_LOCK_DIR / "started").read_text(encoding="utf-8").strip())
                except (OSError, ValueError):
                    started = 0
                cap = iterate_minutes * 60 + 1800 if iterate else 43200
                age = int(time.time()) - started
                if started and age > cap:
                    self.log.log("运行锁已持有 %ds 超过上限 %ds（PID %s 疑似僵死），接管" % (age, cap, pid))
                else:
                    self.log.log("已有测速在运行（PID %s），本次跳过" % pid)
                    return False
            else:
                self.log.log("运行锁为残留（PID %s 已不存在），接管" % (pid or "未知"))

            shutil.rmtree(paths.RUN_LOCK_DIR, ignore_errors=True)
            attempts += 1
            if attempts >= 3:
                self.log.log("运行锁接管失败，本次跳过")
                return False

    def release(self):
        try:
            owner = (paths.RUN_LOCK_DIR / "pid").read_text(encoding="utf-8").strip()
        except OSError:
            owner = ""
        if owner and owner != str(self.pid):
            return
        if self.run_dir:
            shutil.rmtree(self.run_dir, ignore_errors=True)
        shutil.rmtree(paths.RUN_LOCK_DIR, ignore_errors=True)
        self.run_dir = None

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
