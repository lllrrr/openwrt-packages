#!/usr/bin/env python3
"""Build luci-app-trusted_<ver>_all.ipk without an OpenWrt SDK.

IPK layout (verified against opkg 2025-11-05 on ImmortalWRT SNAPSHOT):
  the .ipk is a gzip-compressed tar archive whose members are
  debian-binary, control.tar.gz and data.tar.gz.

  A flat "debian-binary + control.tar.gz + data.tar.gz" concatenation is
  rejected by that opkg build ("Malformed package file"), so do not
  "simplify" the outer container back to a cat.

  control.tar.gz  : ./control ./conffiles ./postinst ./prerm
  data.tar.gz    : ./etc ./usr ./www payload, owner root:root, mode preserved

  Timestamps are real (not 0).  uhttpd answers static resources with
  "Last-Modified: <mtime>" and no Cache-Control, so an mtime of 0 makes
  browsers treat every LuCI view as fresh for decades and they keep serving
  a cached copy after an upgrade.

Translation catalogs are compiled here, not by the SDK: LuCI reads
/usr/lib/lua/luci/i18n/<domain>.<lang>.lmo and that directory carries no
source .po at build time.  The writer below is a byte-for-byte port of
luci's po2lmo (SFH hash + value blob + big-endian index + 4 byte trailer),
verified against a compiled po2lmo on 2026-10-26.
"""

import gzip
import io
import os
import re
import struct
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = os.path.join(HERE, "files")
CONTROL = os.path.join(HERE, "control")

PKG = "luci-app-trusted"
VER = "1.3.0-1"
OUT = os.path.join(HERE, f"{PKG}_{VER}_all.ipk")

BLOCK = 10240  # GNU tar blocking factor, matches SDK-built packages
MTIME = int(time.time())

# po/<lang>/<domain>.po -> /usr/lib/lua/luci/i18n/<domain>.<code>.lmo
# LuCI builds the file name as <po basename>.<language>.lmo and loads every
# *.zh-cn.lmo out of that directory.  The language code is the LuCI value with
# underscores turned into dashes; the two Chinese variants keep the aliases
# that luci.mk uses (LUCI_LC_ALIAS), otherwise zh_Hans would become zh-hans
# and LuCI would never look for it.
I18N_DIR = os.path.join(HERE, "po")
I18N_TARGET = "./usr/lib/lua/luci/i18n/"

LC_ALIAS = {
    "zh_hans": "zh-cn",
    "zh_hant": "zh-tw",
}

U32 = 0xFFFFFFFF


def tar_bytes(members, fmt=tarfile.GNU_FORMAT):
    """members: list of (arcname, data_or_None, mode, is_dir)"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=fmt) as tar:
        for arc, data, mode, is_dir in members:
            info = tarfile.TarInfo(arc)
            info.mtime = MTIME
            info.mode = mode
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            if is_dir:
                info.type = tarfile.DIRTYPE
                info.size = 0
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    raw = buf.getvalue()
    if len(raw) % BLOCK:
        raw += b"\x00" * (BLOCK - len(raw) % BLOCK)
    return raw


def gz(raw):
    return gzip.compress(raw, mtime=0)


# --------------------------------------------------------------- po -> lmo ---

def sfh_hash(data, init):
    """SuperFastHash, as used by lmo_canon_hash() in luci's lib/lmo.c."""
    if not data:
        return 0

    h = init & U32
    rem = len(data) & 3
    chunks = len(data) >> 2
    i = 0

    for _ in range(chunks):
        h = (h + (data[i] | (data[i + 1] << 8))) & U32
        tmp = (((data[i + 2] | (data[i + 3] << 8)) << 11) ^ h) & U32
        h = ((h << 16) ^ tmp) & U32
        i += 4
        h = (h + (h >> 11)) & U32

    if rem == 3:
        h = (h + (data[i] | (data[i + 1] << 8))) & U32
        h = (h ^ (h << 16)) & U32
        b = data[i + 2] - 256 if data[i + 2] > 127 else data[i + 2]
        h = (h ^ (b << 18)) & U32
        h = (h + (h >> 11)) & U32
    elif rem == 2:
        h = (h + (data[i] | (data[i + 1] << 8))) & U32
        h = (h ^ (h << 11)) & U32
        h = (h + (h >> 17)) & U32
    elif rem == 1:
        b = data[i] - 256 if data[i] > 127 else data[i]
        h = (h + b) & U32
        h = (h ^ (h << 10)) & U32
        h = (h + (h >> 1)) & U32

    h = (h ^ (h << 3)) & U32
    h = (h + (h >> 5)) & U32
    h = (h ^ (h << 4)) & U32
    h = (h + (h >> 17)) & U32
    h = (h ^ (h << 25)) & U32
    h = (h + (h >> 6)) & U32
    return h


def po_unquote(s):
    s = s.strip()
    if not s.startswith('"'):
        return ""
    body = s[1:s.rfind('"')]
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            n = body[i + 1]
            out.append({"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def po_entries(text):
    """Split a .po file the way po2lmo does.

    An entry starts at msgctxt or msgid and ends at the next msgctxt/msgid or
    at EOF.  Blank lines do not end an entry.  Fuzzy entries are kept, because
    po2lmo skips the marker line rather than the entry.
    """
    entries = []
    cur = None
    field = None
    pending_fuzzy = False

    def flush():
        nonlocal cur
        if cur is not None and cur.get("id") is not None:
            entries.append(cur)
        cur = None

    for raw in text.split("\n"):
        line = raw.rstrip()

        if not line.strip():
            continue

        if line.startswith("#"):
            if "fuzzy" in line:
                pending_fuzzy = True
            continue

        m = re.match(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+(".*")$', line)
        if m:
            key, val = m.group(1), po_unquote(m.group(2))

            if key in ("msgctxt", "msgid"):
                if cur is not None and cur.get("id") is not None:
                    flush()
                if cur is None:
                    cur = {"id": None, "fuzzy": pending_fuzzy}
                    pending_fuzzy = False
            if cur is None:
                cur = {"id": None, "fuzzy": False}

            if key == "msgctxt":
                cur["ctxt"] = val
                field = "ctxt"
            elif key == "msgid":
                cur["id"] = val
                field = "id"
            elif key == "msgid_plural":
                cur["id_plural"] = val
                field = "id_plural"
            elif key == "msgstr":
                cur["str"] = val
                field = "str"
            else:
                idx = int(key[7:-1])
                cur.setdefault("plurals", {})[idx] = val
                field = ("plural", idx)
            continue

        if line.lstrip().startswith('"'):
            val = po_unquote(line)
            if isinstance(field, tuple):
                cur["plurals"][field[1]] += val
            elif field in ("str", "id", "ctxt", "id_plural"):
                cur[field] = cur.get(field, "") + val

    flush()
    return entries


def po_to_lmo(path):
    """Return (lmo_bytes, entry_count)."""
    with open(path, encoding="utf-8") as f:
        entries = po_entries(f.read())

    values = bytearray()
    index = []

    for e in entries:
        key = e["id"]
        if e.get("ctxt"):
            key = e["ctxt"] + "\x01" + key

        val = e.get("str", "")
        if not val:
            continue

        # The header entry carries the Plural-Forms formula under key id 0.
        if e["id"] == "" and "Plural-Forms: " in val:
            m = re.search(r"Plural-Forms: ([^\n]*)", val)
            b = m.group(1).encode("utf-8")
            index.append((0, 0, len(values), len(b)))
            values += b
            values += b"\x00" * ((4 - len(b) % 4) % 4)
            continue

        kb = key.encode("utf-8")
        vb = val.encode("utf-8")
        key_id = sfh_hash(kb, len(kb))
        val_id = sfh_hash(vb, len(vb))

        # Untranslated entries hash to themselves and are not stored.
        if key_id == val_id:
            continue

        index.append((key_id, 1, len(values), len(vb)))
        values += vb
        values += b"\x00" * ((4 - len(vb) % 4) % 4)

    index.sort(key=lambda x: x[0])

    out = bytes(values)
    for key_id, val_id, off, length in index:
        out += struct.pack(">IIII", key_id, val_id, off, length)
    out += struct.pack(">I", len(values))
    return out, len(index)


def lc_code(lang):
    """LuCI file name suffix for a po/ directory name."""
    key = lang.lower()
    return LC_ALIAS.get(key, key.replace("_", "-"))


def i18n_members():
    """Compile every po/<lang>/*.po into the package payload."""
    if not os.path.isdir(I18N_DIR):
        return [], []

    members = [(I18N_TARGET, None, 0o755, True)]
    built = []

    for lang in sorted(os.listdir(I18N_DIR)):
        lang_dir = os.path.join(I18N_DIR, lang)
        if lang == "templates" or not os.path.isdir(lang_dir):
            continue
        for name in sorted(os.listdir(lang_dir)):
            if not name.endswith(".po"):
                continue
            data, count = po_to_lmo(os.path.join(lang_dir, name))
            arc = I18N_TARGET + f"{os.path.splitext(name)[0]}.{lc_code(lang)}.lmo"
            members.append((arc, data, 0o644, False))
            built.append((arc, count))

    return members, built


# ------------------------------------------------------------------ package ---

def control_targz():
    members = [("./", None, 0o755, True)]
    for name, mode in [
        ("./control", 0o644),
        ("./conffiles", 0o644),
        ("./postinst", 0o755),
        ("./prerm", 0o755),
        ("./postrm", 0o755),
    ]:
        src = os.path.join(CONTROL, os.path.basename(name))
        if not os.path.exists(src):
            continue
        with open(src, "rb") as f:
            members.append((name, f.read(), mode, False))
    return gz(tar_bytes(members))


def data_targz(extra=()):
    members = [("./", None, 0o755, True)]
    for base in ("etc", "usr", "www"):
        src = os.path.join(FILES, base)
        for root, dirs, files in os.walk(src):
            dirs.sort()
            rel = os.path.relpath(root, FILES).replace(os.sep, "/")
            members.append(("./" + rel + "/", None, 0o755, True))
            for name in sorted(files):
                full = os.path.join(root, name)
                arc = "./" + os.path.relpath(full, FILES).replace(os.sep, "/")
                with open(full, "rb") as f:
                    data = f.read()
                members.append((arc, data, os.stat(full).st_mode & 0o777, False))
    members.extend(extra)
    return gz(tar_bytes(members))


def main():
    ctl = control_targz()
    extra, built = i18n_members()
    dat = data_targz(extra)

    inner = tar_bytes(
        [
            ("debian-binary", b"2.0\n", 0o644, False),
            ("control.tar.gz", ctl, 0o644, False),
            ("data.tar.gz", dat, 0o644, False),
        ]
    )

    with open(OUT, "wb") as f:
        f.write(gz(inner))

    print(f"built: {OUT} ({os.path.getsize(OUT)} bytes)")
    for arc, count in built:
        print(f"i18n:  {arc} ({count} entries)")
    print("--- control.tar.gz ---")
    with tarfile.open(fileobj=io.BytesIO(ctl), mode="r:gz") as t:
        for m in t.getmembers():
            print(f"  {oct(m.mode)[2:]:>4} {m.name}")
    print("--- data.tar.gz ---")
    with tarfile.open(fileobj=io.BytesIO(dat), mode="r:gz") as t:
        for m in t.getmembers():
            kind = "d" if m.isdir() else "-"
            print(f"  {kind}{oct(m.mode)[2:]:>4} {m.name}")


if __name__ == "__main__":
    main()
