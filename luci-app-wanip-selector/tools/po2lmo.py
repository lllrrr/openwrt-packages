#!/usr/bin/env python3
"""
Compile a gettext .po file into LuCI's .lmo binary translation format.

This is a drop-in replacement for the po2lmo host tool that ships with the
OpenWrt SDK, so translations can be built without a full SDK checkout.

Format, reverse engineered from files shipped by luci-base and verified byte
for byte against them:

    [ string data      ]  values concatenated, no separators,
                          zero padded to a multiple of 4
    [ index entries    ]  16 bytes each, big endian, sorted by key:
                              uint32 key      SuperFastHash of the msgid
                              uint32 count    number of variants, 1 in practice
                              uint32 offset   start of the value in the data area
                              uint32 length   length of the value in bytes
    [ uint32           ]  offset where the index begins

Usage:
    python3 tools/po2lmo.py input.po output.lmo

SPDX-License-Identifier: MIT
"""

import re
import struct
import sys

MASK = 0xFFFFFFFF


# --------------------------------------------------------------------- hash

def _u16(buf, i):
    return buf[i] | (buf[i + 1] << 8)


def sfh_hash(data):
    """Paul Hsieh's SuperFastHash, matching LuCI's sfh_hash()."""
    if isinstance(data, str):
        data = data.encode("utf-8")

    length = len(data)
    if length <= 0:
        return 0

    h = length & MASK
    rem = length & 3
    i = 0

    for _ in range(length >> 2):
        h = (h + _u16(data, i)) & MASK
        tmp = ((_u16(data, i + 2) << 11) ^ h) & MASK
        h = ((h << 16) & MASK) ^ tmp
        i += 4
        h = (h + (h >> 11)) & MASK

    if rem == 3:
        h = (h + _u16(data, i)) & MASK
        h ^= (h << 16) & MASK
        h ^= (data[i + 2] << 18) & MASK
        h = (h + (h >> 11)) & MASK
    elif rem == 2:
        h = (h + _u16(data, i)) & MASK
        h ^= (h << 11) & MASK
        h = (h + (h >> 17)) & MASK
    elif rem == 1:
        h = (h + data[i]) & MASK
        h ^= (h << 10) & MASK
        h = (h + (h >> 1)) & MASK

    h ^= (h << 3) & MASK
    h = (h + (h >> 5)) & MASK
    h ^= (h << 4) & MASK
    h = (h + (h >> 17)) & MASK
    h ^= (h << 25) & MASK
    h = (h + (h >> 6)) & MASK
    return h


# ----------------------------------------------------------------- po parser

_ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r",
    '"': '"', "\\": "\\", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
}


def _unquote(line):
    """Turn one quoted po fragment into its literal text."""
    m = re.search(r'"(.*)"\s*$', line)
    if not m:
        return ""
    raw = m.group(1)
    out = []
    i = 0
    while i < len(raw):
        c = raw[i]
        if c == "\\" and i + 1 < len(raw):
            nxt = raw[i + 1]
            out.append(_ESCAPES.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def parse_po(text):
    """Return a list of (msgid, msgstr) with header and empty entries dropped."""
    entries = []
    msgid = msgstr = None
    state = None

    for line in text.splitlines():
        stripped = line.strip()

        if not stripped or stripped.startswith("#"):
            continue

        if stripped.startswith("msgctxt"):
            # context qualified strings are not used by this project
            state = "skip"
            continue

        if stripped.startswith("msgid_plural"):
            state = "skip"
            continue

        if stripped.startswith("msgid"):
            if msgid is not None and msgstr:
                entries.append((msgid, msgstr))
            msgid = _unquote(stripped)
            msgstr = ""
            state = "id"
            continue

        if stripped.startswith("msgstr["):
            # only the first plural form is kept
            state = "str" if stripped.startswith("msgstr[0]") else "skip"
            if state == "str":
                msgstr = _unquote(stripped)
            continue

        if stripped.startswith("msgstr"):
            msgstr = _unquote(stripped)
            state = "str"
            continue

        if stripped.startswith('"'):
            if state == "id":
                msgid += _unquote(stripped)
            elif state == "str":
                msgstr += _unquote(stripped)
            continue

    if msgid is not None and msgstr:
        entries.append((msgid, msgstr))

    return [(k, v) for k, v in entries if k and v]


# -------------------------------------------------------------- lmo writer

def build_lmo(entries):
    """Build the .lmo bytes.

    entries: iterable of (key_hash, value_bytes) or (key_hash, value_bytes,
    count), in the order the strings appear in the source file.

    Two layout rules matter, both taken from the files shipped by luci-base:

      * every value is individually zero padded so the next one starts on a
        4 byte boundary, so all offsets are multiples of 4
      * the data area keeps the source order, while the index is sorted by key
    """
    values = {}
    counts = {}
    order = []

    for item in entries:
        key, value = item[0], item[1]
        count = item[2] if len(item) > 2 else 1
        if isinstance(value, str):
            value = value.encode("utf-8")
        if not value:
            continue
        if key not in values:
            order.append(key)
        values[key] = value
        counts[key] = count

    data = bytearray()
    placement = {}
    for key in order:
        value = values[key]
        placement[key] = (len(data), len(value))
        data += value
        while len(data) % 4:
            data.append(0)

    index_offset = len(data)
    out = bytearray(data)
    for key in sorted(placement):
        offset, length = placement[key]
        out += struct.pack(">IIII", key, counts[key], offset, length)
    out += struct.pack(">I", index_offset)
    return bytes(out)


def compile_po(text):
    pairs = parse_po(text)
    return build_lmo(
        (sfh_hash(msgid), msgstr.encode("utf-8")) for msgid, msgstr in pairs
    ), len(pairs)


# ------------------------------------------------------------------ reader
# Only needed by the self test, but useful for inspecting shipped files.

def parse_lmo(blob):
    """Return a list of (key, count, value_bytes)."""
    index_offset = struct.unpack(">I", blob[-4:])[0]
    out = []
    pos = index_offset
    while pos + 16 <= len(blob) - 4:
        key, count, offset, length = struct.unpack(">IIII", blob[pos:pos + 16])
        out.append((key, count, blob[offset:offset + length]))
        pos += 16
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 1

    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        blob, count = compile_po(fh.read())

    with open(sys.argv[2], "wb") as fh:
        fh.write(blob)

    print("compiled %d strings into %s (%d bytes)"
          % (count, sys.argv[2], len(blob)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
