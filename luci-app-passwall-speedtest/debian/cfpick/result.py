"""Result CSV/JSON, history archive and presentation helpers.

The CSV layout matches the OpenWrt version:

    IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码,节点,节点ID

``节点`` is the display name (passwall remarks); ``节点ID`` is the stable
passwall section id.  Matching (retest candidates, history, DDNS) uses the id
when present so that renaming a node's remarks does not orphan its results.
Legacy files without the last column still parse, with the id left empty.
The final ``# Speed test time: ...`` line is kept at the end of the file.
"""

import csv
import io
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path

from . import paths

HEADER = ["IP 地址", "已发送", "已接收", "丢包率", "平均延迟", "下载速度(MB/s)", "地区码", "节点", "节点ID"]
TIME_PREFIX = "# Speed test time:"
HISTORY_MAX_LINES = 5000
DOWNLOADS_HEADER = [
    "run_ts", "done_ts", "node", "node_id", "ip", "latency",
    "loss", "speed", "asn", "asn_name", "cc", "status",
]
DOWNLOADS_MAX_LINES = 50000


@dataclass
class Row:
    ip: str
    sent: int = 0
    recv: int = 0
    loss: float = 1.0
    latency: float = 0.0
    speed: float = 0.0
    region: str = ""
    node: str = ""
    node_id: str = ""

    def fields(self):
        return [
            self.ip,
            str(self.sent),
            str(self.recv),
            "%.2f" % self.loss,
            "%.2f" % self.latency,
            "%.2f" % self.speed,
            self.region,
            self.node,
            self.node_id,
        ]

    def as_dict(self):
        return {
            "ip": self.ip,
            "sent": self.sent,
            "recv": self.recv,
            "loss": round(self.loss, 4),
            "latency": round(self.latency, 2),
            "speed": round(self.speed, 2),
            "region": self.region,
            "node": self.node,
            "node_id": self.node_id,
        }


def sort_rows(rows, mode="speed"):
    if mode == "latency":
        return sorted(rows, key=lambda row: (row.latency, row.ip))
    return sorted(rows, key=lambda row: (-row.speed, row.latency, row.ip))


def merge_result(rows, node_names, path=None, node_ids=None):
    """Replace only the given nodes' rows, keeping other concurrent runs' rows.

    ``node_ids`` is the link-derived identity used by current rows.  Legacy
    rows have no id, so their display name is still matched as a fallback.
    """
    existing, _ = read_result(path)
    names = {str(name) for name in node_names if name}
    ids = {str(node_id) for node_id in (node_ids or []) if node_id}
    kept = []
    for row in existing:
        if row.node_id and row.node_id in ids:
            continue
        # Also drop legacy/old-id rows that still carry this display name;
        # otherwise a link edit with the same name leaves duplicate rows.
        if row.node in names:
            continue
        kept.append(row)
    return sort_rows(kept + list(rows), "speed")


def _parse_row(parts):
    if len(parts) < 7:
        return None
    ip = (parts[0] or "").strip()
    if not ip or ip.startswith("#") or ip == HEADER[0]:
        return None

    def number(value, default=0.0):
        try:
            return float(str(value).strip())
        except (TypeError, ValueError):
            return default

    try:
        sent = int(float(str(parts[1]).strip() or 0))
        recv = int(float(str(parts[2]).strip() or 0))
    except (TypeError, ValueError):
        sent = recv = 0
    return Row(
        ip=ip,
        sent=sent,
        recv=recv,
        loss=number(parts[3], 1.0),
        latency=number(parts[4], 0.0),
        speed=number(parts[5], 0.0),
        region=(parts[6] or "").strip(),
        node=(parts[7] or "").strip() if len(parts) >= 8 else "",
        node_id=(parts[8] or "").strip() if len(parts) >= 9 else "",
    )


def read_result(path=None):
    path = Path(path or paths.RESULT_FILE)
    rows = []
    when = ""
    if not path.exists():
        return rows, when
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as handle:
        for line in handle:
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            if line.startswith("#"):
                if line.startswith(TIME_PREFIX):
                    when = line[len(TIME_PREFIX):].strip()
                continue
            try:
                parts = next(csv.reader([line]))
            except (csv.Error, StopIteration):
                continue
            row = _parse_row(parts)
            if row:
                rows.append(row)
    return rows, when


def _csv_text(rows, when=None, include_header=True):
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    if include_header:
        writer.writerow(HEADER)
    for row in rows:
        writer.writerow(row.fields())
    if when:
        buffer.write("%s %s\n" % (TIME_PREFIX, when))
    return buffer.getvalue()


def write_result(path, rows, when=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = _csv_text(rows, when)
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    return path


def rotate_results(path=None, keep=9):
    path = Path(path or paths.RESULT_FILE)
    if not path.exists():
        return
    oldest = Path(str(path) + ".%d" % keep)
    try:
        if oldest.exists():
            oldest.unlink()
        for index in range(keep - 1, 0, -1):
            source = Path(str(path) + ".%d" % index)
            if source.exists():
                os.replace(source, str(path) + ".%d" % (index + 1))
        os.replace(path, str(path) + ".1")
    except OSError:
        pass


def _node_key(row):
    """Stable node identity: passwall section id, else display name."""
    return row.node_id or row.node


def node_best_rows(rows):
    """First (best) row per node, in global result order."""
    seen = set()
    out = []
    for row in rows:
        key = _node_key(row)
        if key and key not in seen:
            seen.add(key)
            out.append(row)
    return out


def append_history(rows, when, path=None, max_lines=HISTORY_MAX_LINES):
    path = Path(path or paths.HISTORY_FILE)
    path.parent.mkdir(parents=True, exist_ok=True)
    best = node_best_rows(rows)
    if not best:
        return
    block = ["%s %s" % (TIME_PREFIX, when)]
    for row in best:
        block.append(",".join(row.fields()))
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(block) + "\n")
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        if len(lines) > max_lines:
            tmp = Path(str(path) + ".tmp")
            tmp.write_text("\n".join(lines[-max_lines:]) + "\n", encoding="utf-8")
            os.replace(tmp, path)
    except OSError:
        pass


def prune_history(keep_ids, keep_names, path=None):
    """Drop history rows whose node no longer exists.

    Legacy rows (written before link identities) have no id and are kept only
    when their display name still belongs to a configured node.  Runs whose
    rows all disappeared are removed as a whole.
    """
    path = Path(path or paths.HISTORY_FILE)
    if not path.exists():
        return
    ids = {str(value) for value in (keep_ids or []) if value}
    names = {str(value) for value in (keep_names or []) if value}
    blocks = []
    current = None
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return
    for line in lines:
        text = line.rstrip("\r\n")
        if not text.strip():
            continue
        if text.startswith(TIME_PREFIX):
            current = [text, []]
            blocks.append(current)
            continue
        if current is None:
            continue
        try:
            parts = next(csv.reader([text]))
        except (csv.Error, StopIteration):
            continue
        row = _parse_row(parts)
        if not row:
            continue
        key = _node_key(row)
        if key in ids or (not row.node_id and row.node in names):
            current[1].append(text)
    out = []
    for header, rows in blocks:
        if rows:
            out.append(header)
            out.extend(rows)
    tmp = Path(str(path) + ".tmp")
    try:
        tmp.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        try:
            tmp.unlink()
        except OSError:
            pass


def parse_downloads(limit=4000, path=None):
    """Read the tail of downloads.tsv as dictionaries for the overview card."""
    path = Path(path or paths.DOWNLOADS_FILE)
    if not path.exists():
        return []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    if limit and limit > 0:
        lines = lines[-limit:]
    out = []
    for line in lines:
        text = line.rstrip("\r\n")
        if not text.strip() or text.startswith("#"):
            continue
        parts = text.split("\t")
        if len(parts) < 12:
            continue
        try:
            latency = float(parts[5] or 0)
            loss = float(parts[6] or 0)
            speed = float(parts[7] or 0)
        except ValueError:
            latency = loss = speed = 0.0
        out.append({
            "run_ts": parts[0],
            "done_ts": parts[1],
            "node": parts[2],
            "node_id": parts[3],
            "ip": parts[4],
            "latency": round(latency, 2),
            "loss": round(loss, 4),
            "speed": round(speed, 2),
            "asn": ("AS" + parts[8]) if parts[8] else "",
            "asn_name": parts[9],
            "asn_cc": parts[10],
            "status": parts[11],
        })
    return out


def append_downloads(entries, run_ts, done_ts, path=None,
                     max_lines=DOWNLOADS_MAX_LINES):
    """Append one download-stage batch, trimming the file by line count."""
    if not entries:
        return
    path = Path(path or paths.DOWNLOADS_FILE)
    lines = []
    for entry in entries:
        asn_text = str(entry.get("asn") or "")
        if asn_text.upper().startswith("AS"):
            asn_text = asn_text[2:]
        lines.append("\t".join([
            str(run_ts or done_ts or ""),
            str(done_ts or ""),
            str(entry.get("node") or ""),
            str(entry.get("node_id") or ""),
            str(entry.get("ip") or ""),
            "%.2f" % float(entry.get("latency") or 0),
            "%.2f" % float(entry.get("loss") or 0),
            "%.2f" % float(entry.get("speed") or 0),
            asn_text,
            str(entry.get("asn_name") or ""),
            str(entry.get("asn_cc") or ""),
            str(entry.get("status") or ""),
        ]))
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            if path.stat().st_size == 0:
                handle.write("# " + "\t".join(DOWNLOADS_HEADER) + "\n")
            handle.write("\n".join(lines) + "\n")
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            count = sum(1 for _ in handle)
        if max_lines and count > max_lines:
            all_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            keep = all_lines[0:1] + all_lines[-(max_lines - 1):]
            tmp = Path(str(path) + ".tmp")
            tmp.write_text("\n".join(keep) + "\n", encoding="utf-8")
            os.replace(tmp, path)
    except OSError:
        pass


def parse_history(path=None):
    path = Path(path or paths.HISTORY_FILE)
    runs = []
    if not path.exists():
        return runs
    current = None
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as handle:
        for line in handle:
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            if line.startswith(TIME_PREFIX):
                current = {"time": line[len(TIME_PREFIX):].strip(), "best": None, "nodes": [], "seen": set()}
                runs.append(current)
                continue
            if current is None:
                continue
            try:
                parts = next(csv.reader([line]))
            except (csv.Error, StopIteration):
                continue
            row = _parse_row(parts)
            if not row:
                continue
            if current["best"] is None:
                current["best"] = row
            key = _node_key(row)
            if key and key not in current["seen"]:
                current["seen"].add(key)
                current["nodes"].append(row)
    out = []
    for run in runs:
        if run["best"] is None:
            continue
        best = run["best"]
        out.append({
            "time": run["time"],
            "ip": best.ip,
            "latency": round(best.latency, 2),
            "speed": round(best.speed, 2),
            "region": best.region,
            "nodes": [row.as_dict() for row in run["nodes"]],
        })
    return out


def best_view(rows, when=""):
    """Grouped plain-text view used by the UI's Best IP panel."""
    if not rows:
        return ""
    groups = {}
    order = []
    labels = {}
    for row in rows:
        key = _node_key(row)
        if key not in groups:
            groups[key] = []
            labels[key] = row.node
            order.append(key)
        groups[key].append(row)

    lines = [",".join(HEADER)]
    for key in order:
        name = labels.get(key) or key
        node_rows = groups[key]
        best = node_rows[0]
        extra = " / %.2f MB/s" % best.speed if best.speed > 0 else ""
        lines.append("# ── %s：最优 %s / %.2fms%s，共 %d 条 ──" % (
            name or "(无节点)", best.ip, best.latency, extra, len(node_rows)))
        for row in node_rows:
            lines.append(",".join(row.fields()))
    if when:
        lines.append("%s %s" % (TIME_PREFIX, when))
    return "\n".join(lines)


def history_from_result_files():
    """Fallback chart history from result.csv and its .1...9 rotations."""
    runs = []
    candidates = [paths.RESULT_FILE] + [Path(str(paths.RESULT_FILE) + ".%d" % index)
                                       for index in range(1, 10)]
    for path in candidates:
        rows, when = read_result(path)
        if not rows or not when:
            continue
        best = rows[0]
        runs.append({
            "time": when,
            "ip": best.ip,
            "latency": round(best.latency, 2),
            "speed": round(best.speed, 2),
            "region": best.region,
            "nodes": [row.as_dict() for row in node_best_rows(rows)],
        })
    runs.sort(key=lambda run: run["time"], reverse=True)
    return runs


def build_payload(rows, when=""):
    best = rows[0] if rows else None
    return {
        "generated_at": when,
        "best": best.as_dict() if best else None,
        "nodes": [row.as_dict() for row in node_best_rows(rows)],
        "rows": [row.as_dict() for row in rows],
    }


def export_json(rows, when, result_path=None, best_path=None):
    payload = build_payload(rows, when)
    documents = [
        (result_path or paths.RESULT_JSON, payload),
        (best_path or paths.BEST_JSON, {
            "generated_at": when,
            "best": payload["best"],
            "nodes": payload["nodes"],
        }),
    ]
    for path, document in documents:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = Path(str(path) + ".tmp")
        tmp.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    return payload


def now_text():
    return time.strftime("%Y-%m-%d %H:%M:%S")
