#!/usr/bin/env python3
"""
Build installable .ipk packages for luci-app-wanip-selector without the
OpenWrt SDK.

Two packages are produced, following the layout used by the official LuCI
feed:

    luci-app-wanip-selector          the application, English strings
    luci-i18n-wanip-selector-zh-cn   the Simplified Chinese translation

An OpenWrt .ipk is a gzipped tar holding three members, in this order:

    ./debian-binary     the text "2.0\\n"
    ./data.tar.gz       the files as they land on the router
    ./control.tar.gz    package metadata (control, conffiles, postinst)

Note this is not the ar archive Debian uses; opkg rejects that layout with
"Malformed package file". The format above matches OpenWrt's ipkg-build and
was confirmed against packages shipped on a live router.

Everything is produced here rather than shelling out to tar, so the result
is byte for byte identical on Windows, Linux and CI, and the Unix permission
bits are correct even when the source tree lives on a filesystem that cannot
store them.

Usage:
    python3 tools/build-ipk.py [--version 1.0.0] [--release 1] [--out dist]

SPDX-License-Identifier: MIT
"""

import argparse
import gzip
import io
import os
import sys
import tarfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from po2lmo import compile_po                                  # noqa: E402

APP = "luci-app-wanip-selector"
BASENAME = "wanip-selector"
MAINTAINER = "System32X-code <System32_zyc@outlook.com>"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (path in repo, path on device, mode)
APP_FILES = [
    ("root/etc/config/wanip_selector",
     "./etc/config/wanip_selector", 0o644),
    ("root/etc/init.d/wanip_selector",
     "./etc/init.d/wanip_selector", 0o755),
    ("root/etc/hotplug.d/iface/99-wanip-selector",
     "./etc/hotplug.d/iface/99-wanip-selector", 0o755),
    ("root/etc/uci-defaults/99-luci-app-wanip-selector",
     "./etc/uci-defaults/99-luci-app-wanip-selector", 0o755),
    ("root/usr/sbin/wanip-selector",
     "./usr/sbin/wanip-selector", 0o755),
    ("root/usr/share/luci/menu.d/luci-app-wanip-selector.json",
     "./usr/share/luci/menu.d/luci-app-wanip-selector.json", 0o644),
    ("root/usr/share/rpcd/acl.d/luci-app-wanip-selector.json",
     "./usr/share/rpcd/acl.d/luci-app-wanip-selector.json", 0o644),
    ("htdocs/luci-static/resources/view/wanip_selector/overview.js",
     "./www/luci-static/resources/view/wanip_selector/overview.js", 0o644),
]

# LuCI language code -> (po file, name shown in the language dropdown)
LANGUAGES = {
    "zh-cn": ("po/zh_Hans/wanip-selector.po", "简体中文 (Simplified Chinese)"),
}

CONFFILES = "/etc/config/wanip_selector\n"

LUCI_CACHE_CLEAR = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
\trm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
\t/etc/init.d/rpcd reload >/dev/null 2>&1
}
exit 0
"""

# The application also has to run its uci-defaults script, which registers the
# service with procd. opkg only does that automatically for packages built by
# the OpenWrt buildroot, so it is done explicitly here.
APP_POSTINST = """#!/bin/sh
UCI_DEFAULT=/etc/uci-defaults/99-luci-app-wanip-selector
[ -n "${IPKG_INSTROOT}" ] || {
\trm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
\t/etc/init.d/rpcd reload >/dev/null 2>&1
\t[ -f "$UCI_DEFAULT" ] && {
\t\t( . "$UCI_DEFAULT" ) >/dev/null 2>&1 && rm -f "$UCI_DEFAULT"
\t}
}
exit 0
"""

APP_PRERM = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
\t/etc/init.d/wanip_selector stop >/dev/null 2>&1
\t/etc/init.d/wanip_selector disable >/dev/null 2>&1
}
exit 0
"""

APP_DESCRIPTION = (
    " Redial a WAN interface until its public IPv4 address falls inside\n"
    " (or outside) a configurable set of address pools. Useful when an ISP\n"
    " hands out addresses from several pools of very different quality.\n"
)


# ------------------------------------------------------------- archive bits

def tar_gz(entries):
    """entries: list of (arcname, bytes, mode). Returns gzipped tar bytes."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        seen = set()
        for arcname, payload, mode in entries:
            parts = arcname.strip("./").split("/")[:-1]
            for i in range(len(parts)):
                d = "./" + "/".join(parts[: i + 1])
                if d in seen:
                    continue
                seen.add(d)
                ti = tarfile.TarInfo(d)
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                ti.mtime = 0
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = "root"
                tf.addfile(ti)

            ti = tarfile.TarInfo(arcname)
            ti.size = len(payload)
            ti.mode = mode
            ti.mtime = 0
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            tf.addfile(ti, io.BytesIO(payload))

    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


def container(members):
    """Wrap the three package members into the outer archive.

    OpenWrt's ipkg-build produces a gzipped tar here, not the ar archive used
    by Debian, and opkg rejects an ar file with "Malformed package file".
    Member order matches ipkg-build: debian-binary, data.tar.gz, control.tar.gz.
    """
    return tar_gz([(name, payload, 0o644) for name, payload in members])


def make_ipk(name, version, depends, description, data_entries,
             conffiles=None, postinst=None, prerm=None):
    installed = sum(len(payload) for _, payload, _ in data_entries)

    control = (
        "Package: %s\n"
        "Version: %s\n"
        "Depends: %s\n"
        "Source: package/%s\n"
        "SourceName: %s\n"
        "License: MIT\n"
        "Section: luci\n"
        "SourceDateEpoch: %d\n"
        "Maintainer: %s\n"
        "Architecture: all\n"
        "Installed-Size: %d\n"
        "Description: %s\n"
        % (name, version, depends, name, name, int(time.time()),
           MAINTAINER, installed, description.strip().splitlines()[0])
    )
    body = "\n".join(description.strip().splitlines()[1:])
    if body:
        control += body + "\n"

    ctl = [("./control", control.encode("utf-8"), 0o644)]
    if conffiles:
        ctl.append(("./conffiles", conffiles.encode("utf-8"), 0o644))
    if postinst:
        ctl.append(("./postinst", postinst.encode("utf-8"), 0o755))
    if prerm:
        ctl.append(("./prerm", prerm.encode("utf-8"), 0o755))

    return container([
        ("./debian-binary",  b"2.0\n"),
        ("./data.tar.gz",    tar_gz(data_entries)),
        ("./control.tar.gz", tar_gz(ctl)),
    ]), installed


# ------------------------------------------------------------------- build

def read_repo_file(rel, executable_check=False):
    full = os.path.join(ROOT, rel)
    if not os.path.isfile(full):
        raise SystemExit("ERROR: missing file %s" % rel)
    with open(full, "rb") as fh:
        payload = fh.read()
    if executable_check and b"\r\n" in payload:
        raise SystemExit(
            "ERROR: %s has CRLF line endings, shell scripts must use LF" % rel)
    return payload


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="1.0.0")
    ap.add_argument("--release", default="1")
    ap.add_argument("--out", default="dist")
    args = ap.parse_args()

    version = "%s-%s" % (args.version, args.release)
    outdir = os.path.join(ROOT, args.out)
    os.makedirs(outdir, exist_ok=True)
    built = []

    # ---- application package -------------------------------------------
    data = []
    for src, dst, mode in APP_FILES:
        payload = read_repo_file(src, executable_check=(mode == 0o755))
        data.append((dst, payload, mode))

    blob, size = make_ipk(
        APP, version, "libc, luci-base, jsonfilter",
        "LuCI support for WAN IP Selector\n" + APP_DESCRIPTION,
        data, conffiles=CONFFILES,
        postinst=APP_POSTINST, prerm=APP_PRERM)

    path = os.path.join(outdir, "%s_%s_all.ipk" % (APP, version))
    with open(path, "wb") as fh:
        fh.write(blob)
    built.append((os.path.basename(path), len(data), size, len(blob)))

    # ---- translation packages -------------------------------------------
    for lang, (po_rel, pretty) in sorted(LANGUAGES.items()):
        po_text = read_repo_file(po_rel).decode("utf-8")
        lmo, count = compile_po(po_text)
        if count == 0:
            print("WARNING: %s has no usable strings, skipping" % po_rel)
            continue

        pkg = "luci-i18n-%s-%s" % (BASENAME, lang)
        uci_defaults = (
            "uci set luci.languages.%s='%s'; uci commit luci\n"
            % (lang.replace("-", "_"), pretty)
        )

        data = [
            ("./usr/lib/lua/luci/i18n/%s.%s.lmo" % (BASENAME, lang), lmo, 0o644),
            ("./etc/uci-defaults/%s" % pkg, uci_defaults.encode("utf-8"), 0o755),
        ]

        blob, size = make_ipk(
            pkg, version, "libc, %s" % APP,
            "%s translation for %s\n"
            " Adds the %s interface translation for the WAN IP Selector.\n"
            % (pretty, APP, pretty),
            data, postinst=LUCI_CACHE_CLEAR)

        path = os.path.join(outdir, "%s_%s_all.ipk" % (pkg, version))
        with open(path, "wb") as fh:
            fh.write(blob)
        built.append((os.path.basename(path), count, size, len(blob)))

    # ---- summary ---------------------------------------------------------
    print("built %d package(s) in %s/" % (len(built), args.out))
    for name, items, size, packed in built:
        print("  %-46s %5d entries  %6d B installed  %6d B packed"
              % (name, items, size, packed))

    print("\ninstall both on the router:")
    print("  scp -P <port> %s/*.ipk root@<router>:/tmp/" % args.out)
    print("  ssh -p <port> root@<router> "
          "'opkg install /tmp/luci-app-wanip-selector_*.ipk "
          "/tmp/luci-i18n-*.ipk'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
