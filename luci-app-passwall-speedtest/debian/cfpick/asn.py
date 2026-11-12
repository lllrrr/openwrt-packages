"""ASN / datacenter lookup for the standalone console.

The OpenWrt edition learns ASN prefixes from Team Cymru DNS and keeps two
small tables under ``/etc/cfpick``.  This module does the same with the Python
standard library only, storing the tables in the state directory:

* ``asn-prefixes.tsv``  CIDR <tab> ASN <tab> country code
* ``providers.tsv``     ASN <tab> provider name

A seed copy ships in ``data/`` so an existing history renders immediately;
unknown IPs are resolved lazily through ``origin.asn.cymru.com`` (and the AS
name through ``AS<asn>.asn.cymru.com``) and cached for later requests.
"""

import ipaddress
import random
import socket
import struct
import threading
from pathlib import Path

from . import paths

DNS_TIMEOUT = 1.5
DEFAULT_RESOLVERS = ("1.1.1.1", "8.8.8.8")

_lock = threading.RLock()
_prefixes = None          # [(network, asn, cc)]
_prefix_mtime = None
_providers = None         # {asn: name}
_provider_mtime = None
_ip_cache = {}            # ip -> {"asn", "asn_name", "asn_cc"} | None
_dns_cache = {}           # query name -> [TXT strings]
_tables_ready = False
_read_only = False


def reset_cache():
    """Drop in-memory tables (tests and after manual table edits)."""
    global _prefixes, _prefix_mtime, _providers, _provider_mtime, _tables_ready, _read_only
    with _lock:
        _prefixes = None
        _prefix_mtime = None
        _providers = None
        _provider_mtime = None
        _tables_ready = False
        _read_only = False
        _ip_cache.clear()
        _dns_cache.clear()


def _copy_seed(seed, target):
    try:
        if seed.is_file() and not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(seed.read_bytes())
    except OSError:
        pass


def _merge_seed(seed, target):
    """Append seed lines missing from the learned table (upgrades)."""
    if not seed.is_file():
        return
    try:
        existing = set()
        if target.exists():
            existing = set(target.read_text(encoding="utf-8", errors="replace").splitlines())
        additions = []
        for line in seed.read_text(encoding="utf-8", errors="replace").splitlines():
            text = line.strip()
            if text and not text.startswith("#") and text not in existing:
                additions.append(text)
        if additions:
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "a", encoding="utf-8") as handle:
                handle.write("\n".join(additions) + "\n")
    except OSError:
        pass


def ensure_tables():
    global _tables_ready, _read_only
    with _lock:
        if _tables_ready:
            return
        try:
            paths.STATE_DIR.mkdir(parents=True, exist_ok=True)
        except OSError:
            # Tests and unusual read-only installs still resolve the bundled
            # seed; they just cannot persist newly learned prefixes.
            _read_only = True
            _tables_ready = True
            return
        _copy_seed(paths.ASN_PROVIDERS_SEED, paths.ASN_PROVIDERS_FILE)
        _copy_seed(paths.ASN_PREFIX_SEED, paths.ASN_PREFIX_FILE)
        _merge_seed(paths.ASN_PROVIDERS_SEED, paths.ASN_PROVIDERS_FILE)
        _merge_seed(paths.ASN_PREFIX_SEED, paths.ASN_PREFIX_FILE)
        _tables_ready = True


def _table_path(runtime, seed):
    """Prefer the learned table; fall back to the bundled seed."""
    if runtime.exists():
        return runtime
    return seed


def _mtime(path):
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def _load_prefixes():
    global _prefixes, _prefix_mtime
    ensure_tables()
    table = _table_path(paths.ASN_PREFIX_FILE, paths.ASN_PREFIX_SEED)
    stamp = _mtime(table)
    with _lock:
        if _prefixes is not None and stamp == _prefix_mtime:
            return _prefixes
        rows = []
        try:
            lines = table.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            lines = []
        for line in lines:
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            parts = text.split("\t")
            if len(parts) < 2:
                continue
            try:
                network = ipaddress.ip_network(parts[0], strict=False)
            except ValueError:
                continue
            rows.append((network, parts[1].strip(), (parts[2].strip() if len(parts) > 2 else "")))
        _prefixes = rows
        _prefix_mtime = stamp
        return rows


def _load_providers():
    global _providers, _provider_mtime
    ensure_tables()
    table = _table_path(paths.ASN_PROVIDERS_FILE, paths.ASN_PROVIDERS_SEED)
    stamp = _mtime(table)
    with _lock:
        if _providers is not None and stamp == _provider_mtime:
            return _providers
        names = {}
        try:
            lines = table.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            lines = []
        for line in lines:
            parts = line.strip().split("\t")
            if len(parts) >= 2 and parts[0] and parts[1]:
                names[parts[0].strip()] = parts[1].strip()
        _providers = names
        _provider_mtime = stamp
        return names


def lookup(ip):
    """Return ``{"asn", "asn_name", "asn_cc"}`` from the cached tables."""
    text = str(ip or "").strip()
    if not text:
        return None
    try:
        address = ipaddress.ip_address(text)
    except ValueError:
        return None
    with _lock:
        if text in _ip_cache:
            return dict(_ip_cache[text]) if _ip_cache[text] else None
    best = None
    for network, asn, cc in _load_prefixes():
        if network.version == address.version and address in network:
            if best is None or network.prefixlen > best[0].prefixlen:
                best = (network, asn, cc)
    if best is None:
        with _lock:
            _ip_cache[text] = None
        return None
    names = _load_providers()
    info = {
        "asn": "AS" + best[1],
        "asn_name": names.get(best[1], ""),
        "asn_cc": best[2],
    }
    with _lock:
        _ip_cache[text] = info
    return dict(info)


def _append_prefix(prefix, asn, cc):
    if _read_only:
        return
    line = "%s\t%s\t%s" % (prefix, asn, cc)
    with _lock:
        try:
            if paths.ASN_PREFIX_FILE.exists():
                existing = paths.ASN_PREFIX_FILE.read_text(encoding="utf-8", errors="replace")
                if line in existing.splitlines():
                    return
            with open(paths.ASN_PREFIX_FILE, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        except OSError:
            pass
        global _prefix_mtime
        _prefix_mtime = None


def _append_provider(asn, name):
    if _read_only or not asn or not name:
        return
    line = "%s\t%s" % (asn, name)
    with _lock:
        try:
            if paths.ASN_PROVIDERS_FILE.exists():
                existing = paths.ASN_PROVIDERS_FILE.read_text(encoding="utf-8", errors="replace")
                for row in existing.splitlines():
                    parts = row.split("\t")
                    if len(parts) >= 2 and parts[0] == asn:
                        return
            with open(paths.ASN_PROVIDERS_FILE, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        except OSError:
            pass
        global _provider_mtime
        _provider_mtime = None


# ── minimal DNS TXT client (stdlib only) ─────────────────────────────────
def _resolvers():
    servers = []
    try:
        text = Path("/etc/resolv.conf").read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "nameserver":
            server = parts[1].strip()
            if server:
                servers.append(server)
    return servers or list(DEFAULT_RESOLVERS)


def _encode_name(name):
    out = bytearray()
    for label in str(name).rstrip(".").split("."):
        if not label:
            continue
        raw = label.encode("idna")
        if len(raw) > 63:
            raise ValueError("DNS label too long")
        out.append(len(raw))
        out.extend(raw)
    out.append(0)
    return bytes(out)


def _read_name(data, offset):
    labels = []
    next_offset = offset
    jumped = False
    while offset < len(data):
        length = data[offset]
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(data):
                break
            pointer = ((length & 0x3F) << 8) | data[offset + 1]
            if not jumped:
                next_offset = offset + 2
            offset = pointer
            jumped = True
            continue
        if length == 0:
            if not jumped:
                next_offset = offset + 1
            break
        if offset + 1 + length > len(data):
            break
        labels.append(data[offset + 1:offset + 1 + length].decode("ascii", "replace"))
        offset += 1 + length
        if not jumped:
            next_offset = offset
    return ".".join(labels), next_offset


def _parse_txt_response(data, query_id):
    if len(data) < 12:
        return []
    ident, flags, qdcount, ancount, _ns, _ar = struct.unpack("!HHHHHH", data[:12])
    if ident != query_id:
        return []
    offset = 12
    for _ in range(qdcount):
        _name, offset = _read_name(data, offset)
        offset += 4
    texts = []
    for _ in range(ancount):
        _name, offset = _read_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, _rclass, _ttl, rdlength = struct.unpack("!HHIH", data[offset:offset + 10])
        offset += 10
        rdata = data[offset:offset + rdlength]
        offset += rdlength
        if rtype != 16:
            continue
        chunks = []
        pos = 0
        while pos < len(rdata):
            size = rdata[pos]
            pos += 1
            chunks.append(rdata[pos:pos + size].decode("utf-8", "replace"))
            pos += size
        if chunks:
            texts.append("".join(chunks))
    return texts


def _dns_query_txt(name, timeout=DNS_TIMEOUT):
    with _lock:
        if name in _dns_cache:
            return list(_dns_cache[name])
    query_id = random.randint(0, 0xFFFF)
    question = _encode_name(name) + struct.pack("!HH", 16, 1)
    packet = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0) + question
    for server in _resolvers():
        try:
            family = socket.AF_INET6 if ":" in server else socket.AF_INET
            sock = socket.socket(family, socket.SOCK_DGRAM)
            sock.settimeout(timeout)
            try:
                sock.sendto(packet, (server, 53))
                data, _addr = sock.recvfrom(4096)
            finally:
                sock.close()
            texts = _parse_txt_response(data, query_id)
            if texts:
                with _lock:
                    _dns_cache[name] = list(texts)
                return texts
        except (OSError, ValueError):
            continue
    with _lock:
        _dns_cache[name] = []
    return []


def _origin_query(ip):
    try:
        address = ipaddress.ip_address(str(ip).strip())
    except ValueError:
        return None
    if address.version == 4:
        name = ".".join(reversed(str(address).split("."))) + ".origin.asn.cymru.com"
    else:
        nibbles = address.exploded.replace(":", "")
        name = ".".join(reversed(list(nibbles))) + ".origin6.asn.cymru.com"
    for text in _dns_query_txt(name):
        parts = [part.strip() for part in text.split("|")]
        if len(parts) >= 3 and parts[0].isdigit():
            return {
                "asn": parts[0],
                "prefix": parts[1] or ("%s/32" % address if address.version == 4 else "%s/128" % address),
                "cc": parts[2],
            }
    return None


def _name_query(asn):
    for text in _dns_query_txt("AS%s.asn.cymru.com" % asn):
        parts = [part.strip() for part in text.split("|")]
        if len(parts) >= 5 and parts[4]:
            return parts[4]
        if len(parts) >= 2 and parts[1]:
            return parts[1]
    return ""


def _learn_ip(ip):
    info = lookup(ip)
    if info:
        return info
    origin = _origin_query(ip)
    if not origin:
        with _lock:
            _ip_cache[str(ip)] = None
        return None
    name = _load_providers().get(origin["asn"], "")
    if not name:
        name = _name_query(origin["asn"])
        if name:
            _append_provider(origin["asn"], name)
    _append_prefix(origin["prefix"], origin["asn"], origin["cc"])
    info = {
        "asn": "AS" + origin["asn"],
        "asn_name": name,
        "asn_cc": origin["cc"],
    }
    with _lock:
        _ip_cache[str(ip)] = info
    return info


def backfill_ips(ips, max_workers=8, max_lookups=0):
    """Resolve uncached IPs in parallel; returns the number of new records."""
    ensure_tables()
    if _read_only:
        # Without a writable cache every request would hit DNS again.
        return 0
    unique = []
    seen = set()
    for ip in ips or []:
        text = str(ip or "").strip()
        if not text or text in seen:
            continue
        seen.add(text)
        with _lock:
            # Positive and negative results both stay cached for this process;
            # otherwise unknown IPs would re-query DNS on every page refresh.
            if text in _ip_cache:
                continue
        unique.append(text)
    if max_lookups and max_lookups > 0:
        unique = unique[:max_lookups]
    if not unique:
        return 0
    from concurrent.futures import ThreadPoolExecutor
    learned = 0
    with ThreadPoolExecutor(max_workers=max(1, min(max_workers, len(unique)))) as pool:
        for info in pool.map(_learn_ip, unique):
            if info:
                learned += 1
    return learned


def enrich_rows(rows, learn=False, max_lookups=0, max_workers=8):
    """Fill ``asn`` / ``asn_name`` / ``asn_cc`` on dict rows in place."""
    if not rows:
        return rows
    if learn:
        missing = [row.get("ip") for row in rows
                   if isinstance(row, dict) and not row.get("asn")]
        backfill_ips(missing, max_workers=max_workers, max_lookups=max_lookups)
    for row in rows:
        if not isinstance(row, dict):
            continue
        info = lookup(row.get("ip"))
        if info:
            row["asn"] = info["asn"]
            row["asn_name"] = info["asn_name"]
            row["asn_cc"] = info["asn_cc"]
    return rows


def label(ip):
    """Human-readable datacenter label used by logs."""
    info = lookup(ip)
    if not info:
        return ""
    text = "%s %s" % (info["asn"], info["asn_name"]) if info["asn_name"] else info["asn"]
    if info["asn_cc"]:
        text += " [%s]" % info["asn_cc"]
    return text
