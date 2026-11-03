"""Idempotent crontab management.

Only the block between the two markers is owned by this application; every
other crontab line is preserved byte-for-byte.
"""

import os
import re
import shlex
import shutil
import subprocess
import sys
from urllib.parse import quote, unquote

BEGIN = "# >>> cfpick >>>"
END = "# <<< cfpick <<<"
# Marker for a task disabled from the web panel.  The original schedule and
# command stay on the line, so the panel can show and re-enable it.
DISABLED_PREFIX = "# [cfpick-disabled] "
RUN_MODES = ("start", "retest", "test", "replace")
# Cron lines select nodes with ``--node=<percent-encoded-name>``.  Encoding
# keeps names with spaces/quotes shell-safe without any quoting rules of our
# own, so the flag can be removed again with a plain regex.
NODE_FLAG = "--node"
SCHEDULE_ALIASES = {
    "@reboot", "@hourly", "@daily", "@weekly", "@monthly",
    "@yearly", "@annually", "@midnight",
}

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


def encode_node_name(name):
    return quote(str(name or ""), safe="")


def decode_node_name(value):
    try:
        return unquote(str(value or ""))
    except (TypeError, ValueError):
        return str(value or "")


def node_flags(nodes):
    """Append-able ``--node=…`` flags for a node selection."""
    flags = []
    for name in nodes or []:
        name = str(name or "").strip()
        if name and name not in flags:
            flags.append(name)
    return "".join(" %s=%s" % (NODE_FLAG, encode_node_name(name))
                   for name in flags)


def build_line(settings):
    if settings.get("custom_enabled"):
        expression = settings.get("custom_cron", "0 3 * * *").strip()
    else:
        hour = int(settings.get("hour", 24) or 24)
        expression = "0 */%d * * *" % hour
    # The main scheduled run always tests every enabled node; only the
    # additional tasks in the panel can carry a node selection.
    return "%s %s run start >/dev/null 2>&1" % (expression, cli_command())


# ── related-task model for the web panel ───────────────────────────────
def normalize_schedule(value):
    """Collapse whitespace and convert full-width IME characters."""
    out = []
    for char in str(value or ""):
        code = ord(char)
        if 0xFF01 <= code <= 0xFF5E:
            out.append(chr(code - 0xFEE0))
        elif code == 0x3000:
            out.append(" ")
        else:
            out.append(char)
    return " ".join("".join(out).split())


def valid_schedule(value):
    expression = normalize_schedule(value)
    if expression in SCHEDULE_ALIASES:
        return True
    parts = expression.split()
    if len(parts) != 5:
        return False
    return all(re.match(r"^[0-9A-Za-z*,/-]+$", part) for part in parts)


def is_related(command):
    """A task belongs to this program when its command references cfpick."""
    return "cfpick" in (command or "")


def _command_suffix(line, count):
    """Return the line after ``count`` whitespace-separated fields.

    Keeping the original command text means a schedule edit never rewrites
    quoting or redirections inside the command.
    """
    index = 0
    size = len(line)
    for _ in range(count):
        while index < size and line[index] in " \t":
            index += 1
        while index < size and line[index] not in " \t":
            index += 1
    while index < size and line[index] in " \t":
        index += 1
    return line[index:]


def parse_task(raw, source, writable=False):
    """Parse one crontab line into the panel's related-task model."""
    line = (raw or "").strip()
    if not line:
        return None
    disabled = line.startswith(DISABLED_PREFIX)
    if disabled:
        line = line[len(DISABLED_PREFIX):].strip()
    elif line.startswith("#"):
        return None
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*=", line):
        return None

    parts = line.split()
    if not parts:
        return None
    if parts[0].startswith("@"):
        schedule = parts[0]
        command = _command_suffix(line, 1)
    elif len(parts) >= 6:
        schedule = " ".join(parts[:5])
        command = _command_suffix(line, 5)
    else:
        return None
    command = command.strip()
    if not command:
        return None
    return {
        "source": source,
        "schedule": schedule,
        "command": command,
        "line": (DISABLED_PREFIX + line) if disabled else line,
        "related": is_related(command),
        "nodes": command_nodes(command),
        "disabled": disabled,
        "writable": bool(writable),
    }


def _collect_related(text, source, writable=False):
    tasks = []
    for raw in text.splitlines():
        entry = parse_task(raw, source, writable=writable)
        if entry is None or not entry["related"]:
            continue
        tasks.append(entry)
    return tasks


def _writable_required():
    if _disabled():
        raise CronError("当前环境禁止修改 crontab（CFPICK_SKIP_CRON=1）")
    if not shutil.which("crontab"):
        raise CronError("未安装 crontab（apt install cron）")


def _user_task(line):
    """Locate an editable related task in the current user's crontab."""
    _writable_required()
    target = (line or "").strip()
    if not target:
        raise CronError("缺少任务行")
    lines = _read_crontab().splitlines()
    for index, raw in enumerate(lines):
        stripped = raw.strip()
        if stripped in (BEGIN, END):
            continue
        if stripped != target:
            continue
        entry = parse_task(raw, _current_user() or "当前用户", writable=True)
        if entry is None or not entry["related"]:
            raise CronError("只能修改本程序相关的任务")
        return lines, index, entry
    raise CronError("任务已被修改，请刷新后重试")


_MODE_RE = re.compile(
    r"^(.*?\bcfpick(?:\.sh)?)(\s+)run\s+(start|retest|test|replace)\b(.*)$")
_NODE_EQ_RE = re.compile(r"\s*--node=(?:'[^']*'|\"[^\"]*\"|\S+)")
_NODE_SPACE_RE = re.compile(r"\s*--node\s+(?:'[^']*'|\"[^\"]*\"|\S+)")


def command_nodes(command):
    """Node names selected by ``--node`` flags in a task command."""
    try:
        tokens = shlex.split(command or "", posix=True)
    except ValueError:
        return []
    names = []
    for index, token in enumerate(tokens):
        value = ""
        if token == NODE_FLAG and index + 1 < len(tokens):
            value = tokens[index + 1]
        elif token.startswith(NODE_FLAG + "="):
            value = token.split("=", 1)[1]
        if value:
            name = decode_node_name(value).strip()
            if name and name not in names:
                names.append(name)
    return names


def _strip_node_flags(text):
    return _NODE_SPACE_RE.sub("", _NODE_EQ_RE.sub("", text or "")).strip()


def _replace_nodes(command, nodes):
    """Rewrite the node selection of a ``cfpick run`` command."""
    match = _MODE_RE.match(command or "")
    if match is None:
        raise CronError("该任务不支持选择节点")
    head = match.group(1) + match.group(2) + "run " + match.group(3)
    rest = _strip_node_flags(match.group(4))
    return head + node_flags(nodes) + ((" " + rest) if rest else "")


def _replace_mode(command, mode):
    if mode not in RUN_MODES:
        raise CronError("不支持的任务类型")
    match = _MODE_RE.match(command or "")
    if match is None:
        raise CronError("该任务不支持修改任务类型")
    # 所有任务都是普通 crontab 行，start/retest/test/replace 可以互相切换。
    return match.group(1) + match.group(2) + "run " + mode + match.group(4)


def save_task(line, schedule, enabled=True, mode="", nodes=None):
    lines, index, entry = _user_task(line)
    schedule = normalize_schedule(schedule)
    if not valid_schedule(schedule):
        raise CronError("计划必须是合法的五段 cron 表达式或 @reboot 等简写")

    command = entry["command"]
    if mode:
        command = _replace_mode(command, mode)
    if nodes is not None:
        command = _replace_nodes(command, nodes)

    updated = schedule + " " + command
    if not enabled:
        updated = DISABLED_PREFIX + updated
    lines[index] = updated
    _write_crontab("\n".join(lines) + "\n")
    return True


def delete_task(line):
    lines, index, _entry = _user_task(line)
    del lines[index]
    _write_crontab("\n".join(lines) + ("\n" if lines else ""))
    return True


def prune_nodes(changed, renames=None):
    """Drop (or rename) node references in related tasks.

    ``changed`` holds node names that no longer exist; ``renames`` maps an old
    name to the new one so a rename keeps the task's selection.  A task whose
    selection becomes empty is deleted: an empty selection means "run every
    node", and silently widening a task is worse than removing it.
    """
    changed = {str(name) for name in (changed or []) if name}
    renames = dict(renames or {})
    report = {"removed": [], "renamed": [], "deleted": []}
    if not changed and not renames:
        return report

    _writable_required()
    lines = _read_crontab().splitlines()
    inside = False
    kept = []
    changed_text = False
    for raw in lines:
        stripped = raw.strip()
        if stripped == BEGIN:
            inside = True
            kept.append(raw)
            continue
        if stripped == END:
            inside = False
            kept.append(raw)
            continue
        entry = parse_task(raw, _current_user() or "当前用户", writable=True)
        if entry is None or not entry["related"] or not entry["nodes"]:
            kept.append(raw)
            continue

        remaining = []
        removed_here = []
        renamed_here = []
        for name in entry["nodes"]:
            replacement = renames.get(name)
            if replacement and replacement != name:
                renamed_here.append((name, replacement))
                name = replacement
            elif name in changed:
                removed_here.append(name)
                continue
            if name and name not in remaining:
                remaining.append(name)
        if not removed_here and not renamed_here:
            kept.append(raw)
            continue

        report["removed"].extend(removed_here)
        report["renamed"].extend("%s→%s" % pair for pair in renamed_here)
        if not remaining:
            report["deleted"].append(stripped)
            changed_text = True
            continue
        try:
            command = _replace_nodes(entry["command"], remaining)
        except CronError:
            kept.append(raw)
            continue
        updated = entry["schedule"] + " " + command
        if entry["disabled"]:
            updated = DISABLED_PREFIX + updated
        kept.append(updated)
        changed_text = True

    if changed_text:
        _write_crontab("\n".join(kept) + ("\n" if kept else ""))
    return report


def add_task(schedule, mode="retest", nodes=None):
    _writable_required()
    if mode not in RUN_MODES:
        raise CronError("不支持的任务类型")
    schedule = normalize_schedule(schedule)
    if not valid_schedule(schedule):
        raise CronError("计划必须是合法的五段 cron 表达式或 @reboot 等简写")

    line = schedule + " " + cli_command() + " run " + mode + node_flags(nodes)
    lines = _read_crontab().splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if line in [raw.strip() for raw in lines]:
        raise CronError("相同任务已存在")
    lines.append(line)
    _write_crontab("\n".join(lines) + "\n")
    return line


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
    """First enabled related task, for the status card.

    Scheduled tasks are ordinary crontab lines; there is no managed block.
    """
    try:
        lines = _read_crontab().splitlines()
    except CronError:
        return {"installed": False, "line": ""}
    found = ""
    for line in lines:
        entry = parse_task(line, "", writable=False)
        if entry is None or not entry["related"] or entry["disabled"]:
            continue
        found = entry["line"]
        break
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
    """Snapshot every cron source plus the panel's related-task list."""
    entries = []
    tasks = []
    errors = []
    installed = bool(shutil.which("crontab"))

    try:
        user_text = _read_crontab()
    except CronError as exc:
        user_text = ""
        errors.append(str(exc))
    user = _current_user()
    entries.extend(parse_text(user_text, user or "当前用户", managed=True))
    writable = installed and not _disabled()
    tasks.extend(_collect_related(user_text, user or "当前用户", writable=writable))

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
            tasks.extend(_collect_related(text, "用户 " + name))

    text = _read_file("/etc/crontab")
    if text:
        entries.extend(parse_text(text, "/etc/crontab"))
        tasks.extend(_collect_related(text, "/etc/crontab"))

    for name in _list_files("/etc/cron.d"):
        # Debian's cron ignores names containing dots or ending in '~'.
        if "." in name or name.endswith("~"):
            continue
        text = _read_file(os.path.join("/etc/cron.d", name))
        if text:
            source = "/etc/cron.d/" + name
            entries.extend(parse_text(text, source))
            tasks.extend(_collect_related(text, source))

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

    return {
        "installed": installed,
        "entries": entries,
        "tasks": tasks,
        "writable": writable,
        "run_command": cli_command() + " run",
        "errors": errors,
    }
