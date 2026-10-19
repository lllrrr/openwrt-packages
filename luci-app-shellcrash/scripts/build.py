#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构建 luci-app-shellcrash 的安装包（纯 Python 标准库，跨平台）。

一次产出三种格式：
  1. .ipk    —— OpenWrt 24.10 及更早（opkg）
  2. .apk    —— OpenWrt / ImmortalWrt 25.12 及以后（apk-tools 3）
  3. .tar.gz —— 手动安装包（任何版本通用）

三种格式均为架构无关（ipk 为 all，apk 为 noarch），在 aarch64 / x86_64 / mips / arm 等目标上直接通用。
"""

import argparse
import gzip
import hashlib
import io
import os
import sys
import tarfile
import time

# ----------------------------------------------------------------- 包元信息

PKG_NAME = "luci-app-shellcrash"
PKG_VERSION = "1.0.0"
PKG_RELEASE = "1"
PKG_LICENSE = "GPL-3.0-or-later"
PKG_MAINTAINER = "hhCodingCat"
PKG_URL = "https://github.com/hhCodingCat/luci-app-shellcrash"

PKG_DESCRIPTION = (
    "LuCI support for ShellCrash - Modern Web UI for ShellCrash on OpenWrt / ImmortalWrt\n"
    " Provides service status monitoring, start/stop/restart, autostart toggle, Clash API\n"
    " runtime mode & log switching, Web Dashboard launcher (Zashboard / Metacubexd), latency\n"
    " connectivity tests, subscription management, and offline ShellCrash initialization."
)

PKG_DEPENDS = ["luci-base", "curl", "ca-bundle"]

MTIME = int(os.environ.get("SOURCE_DATE_EPOCH", time.time()))

# ------------------------------------------------------------------ 控制脚本

POSTINST = """#!/bin/sh
if [ -x /etc/uci-defaults/99-luci-app-shellcrash ]; then
\t/etc/uci-defaults/99-luci-app-shellcrash
\trm -f /etc/uci-defaults/99-luci-app-shellcrash
fi
chmod 755 /usr/libexec/luci-app-shellcrash/ctl.sh 2>/dev/null
chmod 755 /usr/libexec/luci-app-shellcrash/dashboard.sh 2>/dev/null
rm -f /tmp/luci-indexcache 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload 2>/dev/null
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd reload 2>/dev/null
exit 0
"""

PRERM = """#!/bin/sh
rm -f /tmp/luci-indexcache 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null
exit 0
"""

CONFFILES = "/etc/config/shellcrash\n"


def die(msg):
    sys.stderr.write("错误：%s\n" % msg)
    sys.exit(1)


def file_mode(rel):
    rel = rel.replace("\\", "/")
    if rel.endswith(".sh"):
        return 0o755
    if rel.startswith("etc/uci-defaults/") or rel.startswith("etc/init.d/"):
        return 0o755
    if rel.startswith("usr/libexec/"):
        return 0o755
    return 0o644


def collect(src_root):
    entries = []
    for sub, prefix in (("root", ""), ("htdocs", "www/")):
        base = os.path.join(src_root, sub)
        if not os.path.isdir(base):
            die("找不到目录：%s" % base)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, base).replace("\\", "/")
                entries.append((prefix + rel, full))
    return sorted(entries, key=lambda x: x[0])


def normalize(info):
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = MTIME
    return info


def tar_used_length(raw):
    pos = 0
    n = len(raw)
    while pos + 512 <= n:
        block = raw[pos:pos + 512]
        if block == b"\0" * 512:
            break
        size_field = block[124:136].split(b"\0")[0].strip()
        size = 0
        try:
            size = int(size_field, 8) if size_field else 0
        except ValueError:
            die("内部错误：无法解析 tar 成员长度字段 %r" % size_field)
        pos += 512 + ((size + 511) // 512) * 512
    return pos


def tar_bytes(build, end_of_archive=True, pad_record=True, pax=False):
    buf = io.BytesIO()
    fmt = tarfile.PAX_FORMAT if pax else tarfile.GNU_FORMAT
    with tarfile.open(fileobj=buf, mode="w", format=fmt) as tf:
        build(tf)
    raw = buf.getvalue()
    used = tar_used_length(raw)

    if end_of_archive:
        out = raw[:used] + b"\0" * 1024
        if pad_record:
            rem = len(out) % 10240
            if rem:
                out += b"\0" * (10240 - rem)
    else:
        out = raw[:used]

    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", compresslevel=9, mtime=0) as fh:
        fh.write(out)
    return gz.getvalue()


def build_data_tar(entries, dot_prefix, end_of_archive=True, apk_checksums=False):
    def build(tf):
        dirs_added = set()

        def add_dir(arc):
            arc = arc.rstrip("/")
            if not arc or arc in dirs_added:
                return
            parts = arc.split("/")
            for i in range(1, len(parts) + 1):
                partial = "/".join(parts[:i])
                if partial in dirs_added:
                    continue
                info = tarfile.TarInfo(partial)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                normalize(info)
                tf.addfile(info)
                dirs_added.add(partial)

        for rel, full in entries:
            arc = ("./" + rel) if dot_prefix else rel
            add_dir(os.path.dirname(arc))
            with open(full, "rb") as fh:
                data = fh.read()
            info = tarfile.TarInfo(arc)
            info.size = len(data)
            info.mode = file_mode(rel)
            if apk_checksums:
                info.pax_headers = {
                    "APK-TOOLS.checksum.SHA1": hashlib.sha1(data).hexdigest()
                }
            normalize(info)
            tf.addfile(info, io.BytesIO(data))

    return tar_bytes(build, end_of_archive=end_of_archive, pax=apk_checksums)


def add_text_member(tf, arc, text, mode=0o644):
    data = text.encode("utf-8") if isinstance(text, str) else text
    info = tarfile.TarInfo(arc)
    info.size = len(data)
    info.mode = mode
    normalize(info)
    tf.addfile(info, io.BytesIO(data))


def build_ipk(src_root, out_dir):
    entries = collect(src_root)
    total = sum(os.path.getsize(p) for _, p in entries)
    installed_size = max(1, (total + 1023) // 1024)

    control = (
        "Package: %s\n"
        "Version: %s-%s\n"
        "Depends: libc, %s\n"
        "Source: package/%s\n"
        "SourceName: %s\n"
        "License: %s\n"
        "Section: luci\n"
        "Architecture: all\n"
        "Installed-Size: %d\n"
        "Description: %s\n"
    ) % (
        PKG_NAME, PKG_VERSION, PKG_RELEASE, ", ".join(PKG_DEPENDS),
        PKG_NAME, PKG_NAME, PKG_LICENSE, installed_size, PKG_DESCRIPTION,
    )

    def build_control(tf):
        add_text_member(tf, "./control", control)
        add_text_member(tf, "./conffiles", CONFFILES)
        add_text_member(tf, "./postinst", POSTINST, 0o755)
        add_text_member(tf, "./prerm", PRERM, 0o755)

    control_tar = tar_bytes(build_control)
    data_tar = build_data_tar(entries, dot_prefix=True)

    name = "%s_%s-%s_all.ipk" % (PKG_NAME, PKG_VERSION, PKG_RELEASE)
    path = os.path.join(out_dir, name)

    def build_outer(tf):
        for arc, content in (
            ("./debian-binary", b"2.0\n"),
            ("./control.tar.gz", control_tar),
            ("./data.tar.gz", data_tar),
        ):
            info = tarfile.TarInfo(arc)
            info.size = len(content)
            info.mode = 0o644
            normalize(info)
            tf.addfile(info, io.BytesIO(content))

    with open(path, "wb") as fh:
        fh.write(tar_bytes(build_outer))

    return path, len(entries)


def build_apk(src_root, out_dir, arch="noarch"):
    entries = collect(src_root)
    installed_size = sum(os.path.getsize(p) for _, p in entries)

    data_tar = build_data_tar(entries, dot_prefix=False,
                              end_of_archive=True, apk_checksums=True)
    datahash = hashlib.sha256(data_tar).hexdigest()

    pkginfo_lines = [
        "# Generated by luci-app-shellcrash build.py",
        "pkgname = %s" % PKG_NAME,
        "pkgver = %s-r%s" % (PKG_VERSION, PKG_RELEASE),
        "pkgdesc = %s" % PKG_DESCRIPTION.split("\n")[0],
        "url = %s" % PKG_URL,
        "builddate = %d" % MTIME,
        "packager = %s" % PKG_MAINTAINER,
        "size = %d" % installed_size,
        "arch = %s" % arch,
        "origin = %s" % PKG_NAME,
        "license = %s" % PKG_LICENSE,
        "datahash = %s" % datahash,
    ]
    for dep in PKG_DEPENDS:
        pkginfo_lines.append("depend = %s" % dep)

    def build_control(tf):
        add_text_member(tf, ".PKGINFO", "\n".join(pkginfo_lines) + "\n")
        add_text_member(tf, ".post-install", POSTINST, 0o755)
        add_text_member(tf, ".post-upgrade", POSTINST, 0o755)
        add_text_member(tf, ".post-deinstall", PRERM, 0o755)

    control_tar = tar_bytes(build_control, end_of_archive=False)

    name = "%s-%s-r%s.apk" % (PKG_NAME, PKG_VERSION, PKG_RELEASE)
    path = os.path.join(out_dir, name)

    with open(path, "wb") as fh:
        fh.write(control_tar)
        fh.write(data_tar)

    return path, len(entries)


def build_rootfs_tar(src_root, out_dir):
    entries = collect(src_root)

    def build(tf):
        dirs_added = set()

        def add_dir(arc):
            arc = arc.rstrip("/")
            if not arc or arc in dirs_added:
                return
            parts = arc.split("/")
            for i in range(1, len(parts) + 1):
                partial = "/".join(parts[:i])
                if partial in dirs_added:
                    continue
                info = tarfile.TarInfo(partial)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                normalize(info)
                tf.addfile(info)
                dirs_added.add(partial)

        for rel, full in entries:
            add_dir(os.path.dirname(rel))
            with open(full, "rb") as fh:
                data = fh.read()
            info = tarfile.TarInfo(rel)
            info.size = len(data)
            info.mode = file_mode(rel)
            normalize(info)
            tf.addfile(info, io.BytesIO(data))

    name = "%s-%s-rootfs.tar.gz" % (PKG_NAME, PKG_VERSION)
    path = os.path.join(out_dir, name)
    with open(path, "wb") as fh:
        fh.write(tar_bytes(build))
    return path, len(entries)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_src = os.path.dirname(here)

    ap = argparse.ArgumentParser(description="构建 luci-app-shellcrash 安装包")
    ap.add_argument("--src", default=default_src, help="包根目录（含 root/ 与 htdocs/）")
    ap.add_argument("--out", default=os.path.join(default_src, "dist"), help="输出目录")
    ap.add_argument("--format", default="all",
                    choices=["all", "ipk", "apk", "tar"], help="构建哪种格式")
    ap.add_argument("--apk-arch", default="noarch",
                    help="apk 的 arch 字段。默认 noarch（架构无关）")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    if not os.path.isdir(os.path.join(src, "root")):
        die("--src 指向的目录里没有 root/：%s" % src)

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    results = []
    if args.format in ("all", "ipk"):
        results.append(("ipk",) + build_ipk(src, out_dir))
    if args.format in ("all", "apk"):
        results.append(("apk",) + build_apk(src, out_dir, arch=args.apk_arch))
    if args.format in ("all", "tar"):
        results.append(("tar",) + build_rootfs_tar(src, out_dir))

    print("=" * 72)
    for kind, path, count in results:
        size = os.path.getsize(path)
        print("[%s] %s" % (kind, os.path.basename(path)))
        print("      路径   : %s" % path)
        print("      大小   : %d 字节（%.1f KiB）" % (size, size / 1024.0))
        print("      文件数 : %d" % count)
        print("      SHA256 : %s" % sha256(path))
    print("=" * 72)

    with open(os.path.join(out_dir, "SHA256SUMS"), "w", encoding="utf-8") as fh:
        for _, path, _ in results:
            fh.write("%s  %s\n" % (sha256(path), os.path.basename(path)))
    print("校验和已写入 %s" % os.path.join(out_dir, "SHA256SUMS"))


if __name__ == "__main__":
    main()
