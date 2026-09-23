#!/usr/bin/env python3
"""校验 OpenWrt 25.12 的 apk 产物是不是 apk-tools 3 的 ADB 容器。

为什么要专门校验格式
--------------------
OpenWrt 25.12 起包格式换成了 apk-tools 3 的 ADB 容器。它和下面两种格式
同名 `.apk`，但互不兼容，混用会让 ImageBuilder 的索引（`apk mkndx`）与
设备上的 `apk add` 直接失败：

  * ipk —— ar 归档，文件头 `!<arch>`
  * apk-tools 2.x 包 —— 双 gzip 流，文件头 `\\x1f\\x8b`

ADB 容器长这样（实测官方 `luci-app-sqm`、自建 `luci-app-natmap` /
`luci-app-mihomo`、上游 `mihomo` 二进制包四者一致）::

    41 44 42 2e 70 63 6b 67   "ADB.pckg"         段头
    88 0a 00 00 00 00 00 00   u64 LE = 20 + N    整个 pckg 段的长度
    74 0a 00 e0               u32 LE，低 24 位 = N（段内容长度）
    06 6d 69 68 6f 6d 6f      <长度><字符串> 元数据字段序列
    0a 31 2e 31 39 2e 33 31   比如 name="mihomo"、version="1.19.31-r2" …
    85 01 4d 69 68 6f 6d 6f   description 长度是 2 字节小端（0x0185 = 389）
    ...
    (元数据之后是依赖表、文件条目与文件内容，均为明文)

整段（除前 4 字节）是一整个 raw deflate 流。元数据字段顺序固定为
name / version / description / arch / license / origin / maintainer / url /
…，本脚本只需要前四个。

长度前缀的宽度规则（来自 apk-tools `src/adb.c` 的 `adb_w_blob_vec`）::

    sz > 0xffff  ->  ADB_TYPE_BLOB_32   4 字节小端
    sz > 0xff    ->  ADB_TYPE_BLOB_16   2 字节小端
    sz > 0       ->  ADB_TYPE_BLOB_8    1 字节

要点：**数据流里没有类型标签字节**，宽度完全由内容长度决定
（类型标签存在段尾的 valdb 里，本脚本不去解析它）。所以 description
这种可能超 255 字节的字段，宽度得靠「后面的 arch / license 字段能否
自洽解析」来反推——见 `read_meta`。

用法
----
    check-apk.py 包.apk ...
    check-apk.py --contains etc/init.d/oxidns 包.apk
    check-apk.py --name luci-app-oxidns --arch noarch 包.apk
    check-apk.py --same-version 应用包.apk 翻译包.apk

对每个包校验内容并打印一行 `name=… version=… arch=…`；
任一包不合规即以非 0 退出。`--name` / `--arch` / `--contains` 可重复给出，
作为额外的断言；`--same-version` 要求所有给定包的 version 完全相同
（应用包与它的翻译包应当由同一个 PKG_PO_VERSION 定版）。
"""

import argparse
import os
import re
import sys
import zlib

# 段头 8 字节 + 8 字节长度 + 4 字节标志 = 元数据字段起始偏移
_HEAD_LEN = 8
_META_OFFSET = 20

# name / version 一定是短字符串（OpenWrt 的包名与版本号到不了 256 字节），
# 用 1 字节长度读。description 可能超 255 字节，宽度待定。
_SHORT_FIELDS = ("name", "version")

# 用来判定 description 的长度宽度取得对不对。
# 宽度取错会把游标停在 description 正文中间，从那里读出来的「arch」
# 是英文散文（含空格或句点），过不了 _ARCH_RE —— 这是主判据；
# 再要求紧随其后的那个字段也是一段干净的短 ASCII，作为二次确认
# （apk 里字段可以缺省，所以只要求「像一段字符串」，不假定它是 license）。
_ARCH_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
_NEXT_FIELD_RE = re.compile(r"^[ -~]{1,64}$")

# description 宽度的候选顺序（绝大多数包是 1 字节；长描述是 2 字节）
_WIDTHS = (1, 2, 4)


class ApkError(Exception):
    pass


def load_adb_payload(path):
    """读取文件并解出 ADB 段内容。"""
    with open(path, "rb") as fh:
        raw = fh.read()
    if not raw:
        raise ApkError("空文件")

    if raw[:3] != b"ADB":
        head = raw[:16]
        hint = ""
        if raw[:7] == b"!<arch>":
            hint = "（这是 ipk / ar 归档，不是 25.12 的 apk）"
        elif raw[:2] == b"\x1f\x8b":
            hint = "（gzip 流：apk-tools 2.x 的包或 gzip 过的 tar，25.12 不认这种）"
        elif raw[:2] == b"PK":
            hint = "（这是 zip 归档）"
        raise ApkError("不是 ADB 容器%s，文件头 %r" % (hint, head))

    decomp = zlib.decompressobj(-15)
    try:
        payload = decomp.decompress(raw[4:]) + decomp.flush()
    except zlib.error as exc:
        raise ApkError("ADB 段解压失败：%s" % exc)
    if not payload:
        raise ApkError("ADB 段解压后为空")
    return payload


def _blob(payload, pos, width):
    """按 width 字节小端读长度，取出该字段的内容，返回 (bytes, 新游标)。"""
    if pos + width > len(payload):
        raise ApkError("元数据在偏移 %d 处被截断" % pos)
    size = int.from_bytes(payload[pos:pos + width], "little")
    start = pos + width
    end = start + size
    if end > len(payload):
        raise ApkError("字段越界（偏移 %d，长度 %d）" % (pos, size))
    return payload[start:end], end


def _printable_ascii(raw, key):
    """元数据里的短字段必须是一行可打印 ASCII，否则说明游标错位了。"""
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        raise ApkError("字段 %s 不是 ASCII：%r" % (key, raw[:32]))
    if not text or any(c < " " or c > "~" for c in text):
        raise ApkError("字段 %s 含不可打印字符：%r" % (key, raw[:32]))
    return text


def read_meta(payload):
    """读出元数据头的前四个字段。

    只走前四个：OpenWrt 的构建系统保证 name / version / description / arch
    都在（PKG_DESCRIPTION 缺失会直接编译失败），且顺序固定。再往后的字段
    可能缺省（实测 sirpdboy 的包就没有 license），按位置硬走会失配，所以
    不碰。

    name / version 按 1 字节长度读；description 的宽度未知，逐个候选试，
    用紧跟其后的 arch 字段能否干净解析来定夺。自洽即采纳。
    """
    if payload[:_HEAD_LEN] != b"ADB.pckg":
        raise ApkError("不是 ADB 的 pckg 段（段头 %r）" % payload[:_HEAD_LEN])

    # 段头自洽：u64@8 应该等于 20 + 段内容长度，段内容长度是 u32@16 的低 24 位
    if len(payload) >= _META_OFFSET:
        total = int.from_bytes(payload[8:16], "little")
        content = int.from_bytes(payload[16:20], "little") & 0xFFFFFF
        if total != _META_OFFSET + content:
            raise ApkError("pckg 段头不自洽：u64@8=%d，20+%d=%d"
                           % (total, content, _META_OFFSET + content))

    pos = _META_OFFSET
    meta = {}
    for key in _SHORT_FIELDS:
        raw, pos = _blob(payload, pos, 1)
        meta[key] = _printable_ascii(raw, key)

    for width in _WIDTHS:
        try:
            desc, after_desc = _blob(payload, pos, width)
            arch, after_arch = _blob(payload, after_desc, 1)
            nxt, _ = _blob(payload, after_arch, 1)
            arch = _printable_ascii(arch, "arch")
            nxt = _printable_ascii(nxt, "arch 后面的字段")
        except ApkError:
            continue
        if _ARCH_RE.match(arch) and _NEXT_FIELD_RE.match(nxt):
            meta["description"] = desc.decode("utf-8", "replace")
            meta["arch"] = arch
            return meta

    raise ApkError("无法确定 description 的长度编码（游标 %d），"
                   "格式可能已变，请重新核对" % pos)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="校验 apk 是 apk-tools 3 的 ADB 容器，并断言名称/架构/成员。")
    parser.add_argument("packages", nargs="+", metavar="包.apk")
    parser.add_argument("--name", action="append", default=[],
                        help="断言 pkgname（可重复；每个都要在某个包上命中）")
    parser.add_argument("--arch", action="append", default=[],
                        help="断言 arch（可重复；每个都要在某个包上命中）")
    parser.add_argument("--contains", action="append", default=[],
                        help="断言包内含该路径/字符串（可重复；每个都要在某个包上命中）")
    parser.add_argument("--same-version", action="store_true",
                        help="要求所有包的 version 完全相同")
    args = parser.parse_args(argv)

    missing = list(args.name)
    missing_arch = list(args.arch)
    missing_member = list(args.contains)
    seen_versions = {}

    failed = False
    for path in args.packages:
        if not os.path.isfile(path):
            print("FAIL %s: 文件不存在" % path)
            failed = True
            continue
        try:
            payload = load_adb_payload(path)
            meta = read_meta(payload)
        except ApkError as exc:
            print("FAIL %s: %s" % (os.path.basename(path), exc))
            failed = True
            continue

        size = os.path.getsize(path)
        print("OK   %-46s %8d B  name=%s version=%s arch=%s"
              % (os.path.basename(path), size,
                 meta["name"], meta["version"], meta["arch"]))

        seen_versions[meta["version"]] = seen_versions.get(meta["version"], [])
        seen_versions[meta["version"]].append(meta["name"])

        if meta["name"] in missing:
            missing.remove(meta["name"])
        if meta["arch"] in missing_arch:
            missing_arch.remove(meta["arch"])
        for token in list(missing_member):
            if token.encode("utf-8") in payload:
                missing_member.remove(token)

    if args.same_version and len(seen_versions) > 1:
        print("FAIL 各包 version 不一致：")
        for ver in sorted(seen_versions):
            print("   %s <- %s" % (ver, ", ".join(sorted(seen_versions[ver]))))
        print("     应用包与翻译包应当由同一个 PKG_PO_VERSION 定版"
              "（Makefile 里 `PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)`）")
        failed = True

    if missing:
        print("FAIL 没有任何包提供 pkgname: %s" % ", ".join(missing))
        failed = True
    if missing_arch:
        print("FAIL 没有任何包的 arch 是: %s" % ", ".join(missing_arch))
        failed = True
    if missing_member:
        print("FAIL 任何包里都找不到这些成员: %s" % ", ".join(missing_member))
        failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
