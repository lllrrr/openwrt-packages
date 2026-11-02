"""Idempotent crontab management.

Only the block between the two markers is owned by this application; every
other crontab line is preserved byte-for-byte.
"""

import os
import re
import shutil
import subprocess
import sys

BEGIN = "# >>> cfpick >>>"
END = "# <<< cfpick <<<"

# Read-only snapshot sources for the "already scheduled tasks" panel.
USER_CRON_DIRS = ("/var/spool/cron/crontabs", "/var/spool/cron", "/etc/crontabs")
PERIODIC_DIRS = (
    ("/etc/cron.hourly", "每小时"),
    ("/etc/cron.daily", "每天"),
    ("/etc/cron.weekly", "每周"),
    ("/etc/cron.monthly", "每月"),
)
MAX_ENTRIES = 500


def _disabled():
    """Dev/test switch: never touch the real crontab."""
    return os.environ.get("CFPICK_SKIP_CRON") == "1"


class CronError(RuntimeError):
    pass


def cli_command():
    configured = os.environ.get("CFPICK_BIN", "")
    if configured:
        return configured
    for installed in ("/usr/local/bin/cfpick", "/usr/bin/cfpick"):
        if os.access(installed, os.X_OK):
            return installed
    # Development fallback: an absolute Python invocation.
    return "%s -m cfpick" % shlex_quote(sys.executable)


def shlex_quote(value):
    if not value or any(ch in value for ch in " \t'\""):
        return "'" + value.replace("'", "'\\''") + "'"
    return value


def build_line(settings):
    if settings.get("custom_enabled"):
        expression = settings.get("custom_cron", "0 3 * * *").strip()
    else:
        hour = int(settings.get("hour", 24) or 24)
        expression = "0 */%d * * *" % hour
    return "%s %s run start >/dev/null 2>&1" % (expression, cli_command())


def _read_crontab():
    if _disabled():
        return ""
    executable = shutil.which("crontab")
    if not executable:
        raise CronError("未安装 crontab（apt install cron）")
    completed = subprocess.run([executable, "-l"], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=15)
    if completed.returncode not in (0, 1):
        raise CronError("读取 crontab 失败（crontab -l 返回 %d）" % completed.returncode)
    return completed.stdout.decode("utf-8", "replace")


def _write_crontab(text):
    if _disabled():
        return
    executable = shutil.which("crontab")
    if not executable:
        raise CronError("未安装 crontab（apt install cron）")
    completed = subprocess.run([executable, "-"], input=text.encode("utf-8"),
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               timeout=15)
    if completed.returncode != 0:
        raise CronError("写入 crontab 失败: %s" %
                        completed.stderr.decode("utf-8", "replace").strip())


def _strip_block(text):
    kept = []
    inside = False
    for line in text.splitlines():
        if line.strip() == BEGIN:
            inside = True
            continue
        if line.strip() == END:
            inside = False
            continue
        if not inside:
            kept.append(line)
    return kept


def apply(settings):
    """Install/remove the managed block.  Returns (enabled, line)."""
    lines = _strip_block(_read_crontab())
    if settings.get("enabled"):
        line = build_line(settings)
        lines.extend(["", BEGIN, line, END])
    else:
        line = ""
        while lines and not lines[-1].strip():
            lines.pop()
    text = "\n".join(lines) + ("\n" if lines else "")
    _write_crontab(text)
    return bool(settings.get("enabled")), line


def current():
    try:
        lines = _read_crontab().splitlines()
    except CronError:
        return {"installed": False, "line": ""}
    inside = False
    found = ""
    for line in lines:
        if line.strip() == BEGIN:
            inside = True
            continue
        if line.strip() == END:
            inside = False
            continue
        if inside and line.strip() and not found:
            found = line.strip()
    return {"installed": bool(found), "line": found}


# ── read-only listing for the web panel ─────────────────────────────────

def _classify(line):
    if line.startswith("#"):
        return "comment"
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*=", line):
        return "env"
    return "cron"


def split_line(line):
    """Split a cron line into (schedule, command) for display.

    Handles both five-field entries and shortcuts such as ``@reboot``.  Lines
    with fewer than six fields get an empty command instead of a guess.
    """
    parts = line.split()
    if not parts:
        return "", ""
    if parts[0].startswith("@"):
        return parts[0], " ".join(parts[1:])
    if len(parts) >= 6:
        return " ".join(parts[:5]), " ".join(parts[5:])
    return line, ""


def parse_text(text, source, managed=False):
    """Parse one crontab file into entries, marking the managed block."""
    entries = []
    inside = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line == BEGIN:
            inside = True
            continue
        if line == END:
            inside = False
            continue
        kind = _classify(line)
        schedule, command = split_line(line)
        entries.append({
            "source": source,
            "kind": kind,
            "schedule": schedule if kind == "cron" else "",
            "command": command if kind == "cron" else line,
            "line": line,
            "managed": bool(managed and inside and kind == "cron"),
        })
    return entries


def _current_user():
    try:
        import pwd
    except ImportError:  # development on Windows
        return os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, OSError):
        return ""


def _read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def _list_files(directory, executables=False):
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    found = []
    for name in names:
        if name.startswith("."):
            continue
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            continue
        if executables and not os.access(path, os.X_OK):
            continue
        found.append(name)
    return found


def list_tasks():
    """Snapshot every cron source on the machine without modifying anything."""
    entries = []
    errors = []

    try:
        user_text = _read_crontab()
    except CronError as exc:
        user_text = ""
        errors.append(str(exc))
    user = _current_user()
    entries.extend(parse_text(user_text, user or "当前用户", managed=True))

    seen = {user} if user else set()
    for directory in USER_CRON_DIRS:
        for name in _list_files(directory):
            if name in seen:
                continue
            text = _read_file(os.path.join(directory, name))
            if not text:
                continue  # unreadable for non-root or empty; skip silently
            seen.add(name)
            entries.extend(parse_text(text, "用户 " + name))

    text = _read_file("/etc/crontab")
    if text:
        entries.extend(parse_text(text, "/etc/crontab"))

    for name in _list_files("/etc/cron.d"):
        # Debian's cron ignores names containing dots or ending in '~'.
        if "." in name or name.endswith("~"):
            continue
        text = _read_file(os.path.join("/etc/cron.d", name))
        if text:
            entries.extend(parse_text(text, "/etc/cron.d/" + name))

    for directory, label in PERIODIC_DIRS:
        for name in _list_files(directory, executables=True):
            entries.append({
                "source": directory,
                "kind": "script",
                "schedule": label,
                "command": name,
                "line": name,
                "managed": False,
            })

    if len(entries) > MAX_ENTRIES:
        del entries[MAX_ENTRIES:]
        errors.append("任务过多，仅显示前 %d 项" % MAX_ENTRIES)

    managed_line = ""
    inside = False
    for raw in user_text.splitlines():
        line = raw.strip()
        if line == BEGIN:
            inside = True
        elif line == END:
            inside = False
        elif inside and line and not managed_line:
            managed_line = line

    return {
        "installed": bool(shutil.which("crontab")),
        "managed": {"enabled": bool(managed_line), "line": managed_line},
        "entries": entries,
        "errors": errors,
    }
