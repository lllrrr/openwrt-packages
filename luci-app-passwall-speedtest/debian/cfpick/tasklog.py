"""Structured task history for the console's task log tab.

Every run appends a compact tab-separated line, so the OpenWrt shell engine
(``cfpick.sh``) can write the same file without a JSON library and both
consoles can read it with a two-line parser::

    time \t kind \t mode \t status \t node \t ip \t latency \t speed \t ddns \t message

``kind`` is ``start`` (a run began), ``result`` (a run finished) or ``event``
(a notable mid-run decision, e.g. "all downloads failed, running one more
round").  ``mode`` carries the run mode for start/result and the event type
for events.

Writes are best-effort: a task log problem must never fail a speed test.
"""

import os
import threading
import time
from pathlib import Path

from . import paths

FIELDS = 11       # fields written per line (11th is the per-node details)
MIN_FIELDS = 10   # older files have no details column; keep reading them
MAX_LINES = 400
# Worker threads may report events concurrently; serialize append + trim so a
# trim cannot rewrite the file while another line is being appended.
_lock = threading.Lock()

MODE_LABELS = {
    "start": "测速",
    "test": "测速",
    "retest": "复测",
    # 监测失败后的第一遍：凑够下载候选即停，随后紧跟一次正常复测。
    "retest_quick": "快速复测",
    # 两遍复测都没有新结果时的第三轮：刷新为普通测速候选。
    "retest_refresh": "正常测试",
}

STATUS_LABELS = {
    "ok": "成功",
    "failed": "失败",
    "stopped": "已停止",
    "running": "进行中",
}


def _clean(value):
    return str(value if value is not None else "").replace(
        "\t", " ").replace("\r", " ").replace("\n", " ").strip()


def _number(value):
    try:
        return "%.2f" % float(value)
    except (TypeError, ValueError):
        return ""


def _write(record, path=None):
    target = Path(path or paths.TASKLOG_FILE)
    with _lock:
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "a", encoding="utf-8") as handle:
                handle.write("\t".join(record) + "\n")
        except OSError:
            return record
        _trim(target)
    return record


def _trim(target):
    try:
        lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return
    if len(lines) <= MAX_LINES:
        return
    tmp = Path(str(target) + ".tmp")
    try:
        tmp.write_text("\n".join(lines[-MAX_LINES:]) + "\n", encoding="utf-8")
        os.replace(tmp, target)
    except OSError:
        try:
            tmp.unlink()
        except OSError:
            pass


def _clean_name(value):
    return str(value or "").replace("|", " ").replace(";", " ").replace(
        "\t", " ").replace("\r", " ").replace("\n", " ").strip()


def format_details(entries):
    """Serialize per-node results into one TSV-safe field.

    Entry format: ``node|ip|latency|speed|status|method`` joined by ``;``.
    ``status`` is ok / fail / abnormal; ``method`` is writeback / ddns / -.
    """
    parts = []
    for entry in entries or []:
        parts.append("|".join([
            _clean_name(entry.get("node")),
            _clean(entry.get("ip")),
            _number(entry.get("latency")),
            _number(entry.get("speed")),
            _clean(entry.get("status")),
            _clean(entry.get("method") or "-"),
        ]))
    return ";".join(parts)


def parse_details(text):
    entries = []
    for item in str(text or "").split(";"):
        parts = item.split("|")
        if len(parts) < 6 or not parts[0].strip():
            continue
        try:
            latency = float(parts[2])
        except (TypeError, ValueError):
            latency = 0.0
        try:
            speed = float(parts[3])
        except (TypeError, ValueError):
            speed = 0.0
        entries.append({
            "node": parts[0].strip(),
            "ip": parts[1],
            "latency": latency,
            "speed": speed,
            "status": parts[4],
            "method": parts[5],
        })
    return entries


def summarize(entries):
    ok = sum(1 for entry in entries if entry.get("status") == "ok")
    failed = sum(1 for entry in entries if entry.get("status") == "fail")
    abnormal = sum(1 for entry in entries if entry.get("status") == "abnormal")
    return ok, failed, abnormal


def result_message(mode, status, entries):
    label = MODE_LABELS.get(mode, "测速")
    verb = {"ok": "成功", "stopped": "已停止", "failed": "失败"}.get(
        status, "结束")
    ok, failed, abnormal = summarize(entries)
    return "%s任务%s：成功 %d · 失败 %d · 异常 %d" % (
        label, verb, ok, failed, abnormal)


def record(kind, mode="", status="", node="", ip="", latency="", speed="",
           ddns="", message="", details="", path=None):
    """Append one entry; returns the cleaned field list."""
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    fields = [_clean(part) for part in (
        stamp, kind, mode, status, node, ip, latency, speed, ddns, message,
        _clean(details))]
    return _write(fields, path)


def start(mode, nodes=(), path=None):
    names = [str(name).strip() for name in (nodes or []) if str(name).strip()]
    label = MODE_LABELS.get(mode, mode or "测速")
    if names:
        shown = "、".join(names[:6]) + ("…" if len(names) > 6 else "")
        message = "%s开始：%s" % (label, shown)
    else:
        message = "%s开始" % label
    return record("start", mode=mode, status="running", message=message, path=path)


def result(mode, status, node="", ip="", latency=0, speed=0, ddns="",
           message="", details="", path=None):
    label = MODE_LABELS.get(mode, mode or "测速")
    if not message:
        message = "%s%s" % (label, STATUS_LABELS.get(status, status or ""))
    return record("result", mode=mode, status=status, node=node, ip=ip,
                  latency=_number(latency), speed=_number(speed), ddns=ddns,
                  message=message, details=details, path=path)


def event(kind, message, nodes="", path=None):
    return record("event", mode=kind, status="info", node=nodes,
                  message=message, path=path)


def ddns_label(report):
    """Short human-readable DDNS outcome for the task row."""
    if not isinstance(report, dict):
        return ""
    if not report.get("enabled", True):
        return "未启用"
    parts = []
    for key, label in (("created", "新建"), ("updated", "更新"),
                       ("unchanged", "无变化")):
        count = int(report.get(key) or 0)
        if count:
            parts.append("%s %d" % (label, count))
    failed = int(report.get("failed") or 0)
    if failed:
        parts.append("失败 %d" % failed)
    if not parts:
        parts.append(report.get("message") or "无节点")
    return "，".join(parts)


def parse(path=None, limit=None):
    """Read entries newest-first.  Malformed lines are ignored."""
    target = Path(path or paths.TASKLOG_FILE)
    entries = []
    try:
        with open(target, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                parts = line.rstrip("\r\n").split("\t")
                if len(parts) < MIN_FIELDS:
                    continue
                try:
                    latency = float(parts[6])
                except (TypeError, ValueError):
                    latency = 0.0
                try:
                    speed = float(parts[7])
                except (TypeError, ValueError):
                    speed = 0.0
                entries.append({
                    "time": parts[0],
                    "kind": parts[1],
                    "mode": parts[2],
                    "status": parts[3],
                    "node": parts[4],
                    "ip": parts[5],
                    "latency": latency,
                    "speed": speed,
                    "ddns": parts[8],
                    "message": parts[9],
                    "details": parse_details(parts[10]) if len(parts) > 10 else [],
                })
    except OSError:
        return []
    entries.reverse()
    if limit:
        entries = entries[:int(limit)]
    return entries
