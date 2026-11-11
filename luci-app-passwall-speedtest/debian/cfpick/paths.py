"""Filesystem layout.

All locations can be overridden with environment variables so the same code
runs from a git checkout (development / tests) and from an installed copy
under /opt/cfpick.
"""

import os
import time
from pathlib import Path


def _path(env, default):
    value = os.environ.get(env)
    return Path(value).expanduser() if value else Path(default)


# Directory containing the ``cfpick`` package (the "debian" directory in
# a source checkout, or /opt/cfpick after install.sh).
APP_DIR = _path("CFPICK_APP_DIR", Path(__file__).resolve().parent.parent)

STATE_DIR = _path("CFPICK_STATE_DIR", "/var/lib/cfpick")
CONFIG_DIR = _path("CFPICK_CONFIG_DIR", "/etc/cfpick")
CONFIG_FILE = _path("CFPICK_CONFIG", CONFIG_DIR / "config.json")
LOG_DIR = _path("CFPICK_LOG_DIR", "/var/log/cfpick")

CORE_DIR = STATE_DIR / "core"
CORE_BINARIES = {
    "mihomo": CORE_DIR / "mihomo",
    "xray": CORE_DIR / "xray",
}
CORE_VERSION_FILES = {
    "mihomo": CORE_DIR / "mihomo.version",
    "xray": CORE_DIR / "xray.version",
}

RESULT_FILE = STATE_DIR / "result.csv"
RESULT_JSON = STATE_DIR / "result.json"
BEST_JSON = STATE_DIR / "best.json"
HISTORY_FILE = STATE_DIR / "history.csv"
# Structured run/event history for the console's task log tab (see tasklog.py).
TASKLOG_FILE = STATE_DIR / "tasklog.tsv"
ONLINE_CACHE = STATE_DIR / "online_raw.txt"
# 运行日志按天分文件（speedtest-YYYY-MM-DD.log）；speedtest.log 仅作旧路径保留。
RUN_LOG_PREFIX = "speedtest"
RUN_LOG = LOG_DIR / "speedtest.log"
SPAWN_LOG = LOG_DIR / "spawn.log"
CORE_UPDATE_LOG = LOG_DIR / "core-update.log"
DDNS_LOG = LOG_DIR / "ddns.log"
# 成功结果的后台监测（每分钟复测一次延迟）；与测速日志分开，便于排查。
MONITOR_LOG = LOG_DIR / "monitor.log"
LAST_LOG = STATE_DIR / "last.log"
STATE_FILE = STATE_DIR / "state.json"
RUN_LOCK_DIR = STATE_DIR / ".run.lock"
STOP_FILE = STATE_DIR / "stop.request"
UPDATE_STATE = STATE_DIR / "update-app.json"
UPDATE_LOG = LOG_DIR / "update-app.log"

# Git checkout created by debian/deploy.sh; the Web "update app" button pulls
# this checkout and re-installs from it.
SOURCE_DIR = _path("CFPICK_SRC_DIR", "/opt/cfpick-src")

WEB_DIR = APP_DIR / "web"
BUILTIN_DIR = APP_DIR / "data"


def ensure_dirs():
    for directory in (STATE_DIR, CONFIG_DIR, LOG_DIR, CORE_DIR):
        directory.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(CONFIG_DIR, 0o700)
    except OSError:
        pass


def run_log_path(when=None):
    """Today's run log (one file per day)."""
    stamp = time.localtime(when) if when is not None else time.localtime()
    return LOG_DIR / ("%s-%s.log" % (RUN_LOG_PREFIX, time.strftime("%Y-%m-%d", stamp)))


def prune_run_logs(keep=10):
    """Keep the newest ``keep`` daily run logs."""
    try:
        files = sorted(LOG_DIR.glob(RUN_LOG_PREFIX + "-*.log"))
    except OSError:
        return
    if keep <= 0:
        return
    for path in files[:-keep]:
        try:
            path.unlink()
        except OSError:
            pass
