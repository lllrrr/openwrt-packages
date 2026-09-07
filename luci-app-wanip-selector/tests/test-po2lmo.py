#!/usr/bin/env python3
"""
Tests for tools/po2lmo.py.

The hash vectors below are not invented: they were read out of the
base.zh-cn.lmo shipped by luci-base on a live OpenWrt 24.10 router, so they
pin our implementation to the one LuCI actually uses. The layout rules are
likewise taken from real files, which this implementation reproduces byte for
byte.

Run:  python3 tests/test-po2lmo.py

SPDX-License-Identifier: MIT
"""

import os
import struct
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tools"))

from po2lmo import build_lmo, compile_po, parse_lmo, parse_po, sfh_hash

FAIL = []
PASS = [0]


def check(desc, expected, actual):
    if expected == actual:
        PASS[0] += 1
        print("  ok   %s" % desc)
    else:
        FAIL.append(desc)
        print("  FAIL %s\n       want %r\n       got  %r" % (desc, expected, actual))


# Golden values taken from a shipped luci-base catalogue.
GOLDEN = {
    "Save":          0x219966C7,
    "Cancel":        0xAE5DEB3A,
    "Network":       0xE54695B9,
    "Hostname":      0xD5A3A8D6,
    "Password":      0x8F9289A4,
    "Username":      0x418F93E9,
    "Interface":     0xD3E54C60,
    "Firewall":      0x34F9DA4C,
    "Reboot":        0xC755FF17,
    "Status":        0x663359C9,
    "Enable":        0x78C2105B,
    "Save & Apply":  0x610BEED4,
    "Protocol":      0x35559A6F,
}

print("--- sfh_hash against values read from a shipped luci-base catalogue ---")
for text, expected in GOLDEN.items():
    check("sfh_hash(%r)" % text, expected, sfh_hash(text))

print("--- sfh_hash edge cases ---")
check("empty string hashes to 0", 0, sfh_hash(""))
# every remainder branch of the algorithm, lengths 1..4 mod 4
for text in ("a", "ab", "abc", "abcd", "abcde"):
    h = sfh_hash(text)
    check("sfh_hash(%r) stays in 32 bits" % text, True, 0 <= h <= 0xFFFFFFFF)
check("hash is stable across calls", sfh_hash("Network"), sfh_hash("Network"))
check("utf-8 input is accepted", sfh_hash("保存".encode("utf-8")),
      sfh_hash("保存"))

print("--- po parsing ---")
PO = '''
msgid ""
msgstr "Content-Type: text/plain; charset=UTF-8\\n"

# a comment
msgid "Simple"
msgstr "简单"

msgid "Multi"
"line source"
msgstr "多行"
"译文"

msgid "With \\"quotes\\" and \\\\ backslash"
msgstr "引号"

msgid "Untranslated"
msgstr ""
'''
entries = dict(parse_po(PO))
check("header entry is dropped", False, "" in entries)
check("simple entry", "简单", entries.get("Simple"))
check("multi line msgid is joined", True, "Multiline source" in entries)
check("multi line msgstr is joined", "多行译文",
      entries.get("Multiline source"))
check("escapes are decoded",
      "引号", entries.get('With "quotes" and \\ backslash'))
check("empty msgstr is skipped", False, "Untranslated" in entries)
check("entry count", 3, len(entries))

print("--- lmo layout ---")
blob = build_lmo([
    (sfh_hash("bbb"), "x" * 5),      # 5 bytes, needs 3 bytes of padding
    (sfh_hash("aaa"), "yy"),         # 2 bytes, needs 2 bytes of padding
    (sfh_hash("ccc"), "z" * 4),      # already aligned
])
index_offset = struct.unpack(">I", blob[-4:])[0]
raw = []
pos = index_offset
while pos + 16 <= len(blob) - 4:
    raw.append(struct.unpack(">IIII", blob[pos:pos + 16]))
    pos += 16

check("three entries were written", 3, len(raw))
check("every offset is 4 byte aligned", True, all(o % 4 == 0 for _, _, o, _ in raw))
check("index is sorted by key", True,
      all(raw[i][0] <= raw[i + 1][0] for i in range(len(raw) - 1)))
check("count field is 1", [1, 1, 1], [c for _, c, _, _ in raw])
check("data area keeps source order", [0, 8, 12],
      [o for _, _, o, _ in sorted(raw, key=lambda e: e[2])])
check("lengths exclude padding", sorted([5, 2, 4]),
      sorted([l for _, _, _, l in raw]))
check("total size", index_offset + len(raw) * 16 + 4, len(blob))

print("--- round trip ---")
table = {k: v for k, _, v in parse_lmo(blob)}
check("bbb reads back", b"xxxxx", table[sfh_hash("bbb")])
check("aaa reads back", b"yy", table[sfh_hash("aaa")])
check("ccc reads back", b"zzzz", table[sfh_hash("ccc")])

print("--- compile_po end to end ---")
blob, count = compile_po(PO)
check("compiled entry count", 3, count)
table = {k: v for k, _, v in parse_lmo(blob)}
check("compiled lookup", "简单".encode("utf-8"), table[sfh_hash("Simple")])

print("--- duplicate keys ---")
blob = build_lmo([(1, "first"), (1, "second")])
table = {k: v for k, _, v in parse_lmo(blob)}
check("later duplicate wins", b"second", table[1])
check("only one entry is kept", 1, len(table))

print()
print("passed %d, failed %d" % (PASS[0], len(FAIL)))
sys.exit(1 if FAIL else 0)
