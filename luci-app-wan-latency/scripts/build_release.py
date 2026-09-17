#!/usr/bin/env python3
import gzip, hashlib, io, os, shutil, stat, tarfile, time, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.3.0"
RELEASE = "1"
OUT = ROOT / "dist"

EXECUTABLES = {
    "etc/init.d/wan-latency", "usr/libexec/wan-latency-api",
    "usr/sbin/wan-latencyd", "usr/sbin/wan-latency-probe",
    "usr/libexec/wan-latency-higoos-install",
}

def tar_gz_bytes(files_root=None, virtual=None):
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tf:
            if files_root:
                for path in sorted(files_root.rglob("*"), key=lambda p: p.as_posix()):
                    rel = path.relative_to(files_root).as_posix()
                    info = tarfile.TarInfo("./" + rel)
                    info.mtime = 0
                    if path.is_dir():
                        info.type = tarfile.DIRTYPE; info.mode = 0o755
                        tf.addfile(info)
                    else:
                        data = path.read_bytes(); info.size = len(data)
                        info.mode = 0o755 if rel in EXECUTABLES else 0o644
                        tf.addfile(info, io.BytesIO(data))
            for name, (content, mode) in sorted((virtual or {}).items()):
                data = content.encode() if isinstance(content, str) else content
                info = tarfile.TarInfo("./" + name); info.size = len(data); info.mode = mode; info.mtime = 0
                tf.addfile(info, io.BytesIO(data))
    return raw.getvalue()

def ar_member(name, data):
    stamp = "0"; header = f"{name + '/':<16}{stamp:<12}{'0':<6}{'0':<6}{'100644':<8}{len(data):<10}`\n".encode()
    return header + data + (b"\n" if len(data) % 2 else b"")

def outer_ipk(data_tar, control_tar):
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tf:
            for name, data in (("debian-binary", b"2.0\n"), ("data.tar.gz", data_tar), ("control.tar.gz", control_tar)):
                info = tarfile.TarInfo("./" + name); info.size = len(data); info.mode = 0o644; info.mtime = 0
                tf.addfile(info, io.BytesIO(data))
    return raw.getvalue()

def build_ipk(name, data_root, depends, description, conffiles="", postinst="", prerm=""):
    filename = f"{name}_{VERSION}-{RELEASE}_all.ipk"
    control = f"Package: {name}\nVersion: {VERSION}-{RELEASE}\nArchitecture: all\nMaintainer: xiaokeikei\nSection: luci\nPriority: optional\nDepends: {depends}\nDescription: {description}\n"
    controls = {"control": (control, 0o644)}
    if conffiles: controls["conffiles"] = (conffiles, 0o644)
    if postinst: controls["postinst"] = (postinst, 0o755)
    if prerm: controls["prerm"] = (prerm, 0o755)
    blob = outer_ipk(tar_gz_bytes(files_root=data_root), tar_gz_bytes(virtual=controls))
    (OUT / filename).write_bytes(blob)
    return filename

def build_run(main_ipk, higo_ipk):
    payload = tar_gz_bytes(virtual={main_ipk: ((OUT / main_ipk).read_bytes(), 0o644), higo_ipk: ((OUT / higo_ipk).read_bytes(), 0o644)})
    header = f'''#!/bin/sh
set -eu
fail() {{ echo "Error: $*" >&2; exit 1; }}
[ "$(id -u)" = "0" ] || fail "run this installer as root"
[ -f /etc/openwrt_release ] || fail "this installer is only for OpenWrt-compatible systems"
missing=""
for p in luci-base lua luci-lib-nixio cgi-io rpcd-mod-file curl ip-full; do
  opkg status "$p" 2>/dev/null | grep -q '^Status:.* installed' || missing="$missing $p"
done
[ -z "$missing" ] || fail "missing packages:$missing (run: opkg update && opkg install$missing)"
work="$(mktemp -d /tmp/wan-latency-install.XXXXXX)"
trap 'rm -rf "$work"' EXIT INT TERM
line="$(awk '/^__PAYLOAD_BELOW__$/ {{ print NR + 1; exit }}' "$0")"
tail -n "+$line" "$0" | gzip -dc | tar -xf - -C "$work"
opkg install "$work/{main_ipk}"
if [ -f /www/higoros/index.html ] && grep -Eq 'Hiveton HigoOS|HigoOS' /www/higoros/index.html; then
  opkg install "$work/{higo_ipk}"
  echo "HigoOS integration installed"
else
  echo "Generic OpenWrt installation completed (HigoOS integration skipped)"
fi
exit 0
__PAYLOAD_BELOW__
'''.encode()
    name = f"luci-app-wan-latency-{VERSION}-{RELEASE}.run"
    (OUT / name).write_bytes(header + payload)
    return name

def source_zip():
    name = f"luci-app-wan-latency-{VERSION}-{RELEASE}-source.zip"
    prefix = f"luci-app-wan-latency-{VERSION}/"
    with zipfile.ZipFile(OUT / name, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(ROOT.rglob("*"), key=lambda x: x.as_posix()):
            rel = p.relative_to(ROOT)
            if not p.is_file() or ".git" in rel.parts or (rel.parts and rel.parts[0] in {"dist", "work"}): continue
            z.write(p, prefix + rel.as_posix())
    return name

def main():
    if OUT.exists(): shutil.rmtree(OUT)
    OUT.mkdir()
    main_ipk = build_ipk(
        "luci-app-wan-latency", ROOT / "files",
        "luci-base, lua, luci-lib-nixio, cgi-io, rpcd-mod-file, curl, ip-full",
        "WAN latency monitor for LuCI",
        "/etc/config/wan-latency\n",
        "#!/bin/sh\n[ -n \"$IPKG_INSTROOT\" ] || { mkdir -p /www/wan-latency; /etc/init.d/wan-latency enable; /etc/init.d/wan-latency restart; rm -f /www/cgi-bin/wan-latency /tmp/luci-indexcache; /etc/init.d/rpcd restart; /etc/init.d/uhttpd reload; }\nexit 0\n",
        "#!/bin/sh\n[ -n \"$IPKG_INSTROOT\" ] || /etc/init.d/wan-latency stop\nexit 0\n")
    higo_ipk = build_ipk(
        "luci-app-wan-latency-higoos", ROOT / "higoos" / "files",
        "luci-app-wan-latency (= 1.3.0-1)", "HigoOS native integration for WAN latency monitor",
        postinst="#!/bin/sh\n[ -n \"$IPKG_INSTROOT\" ] || /usr/libexec/wan-latency-higoos-install install\nexit 0\n",
        prerm="#!/bin/sh\n[ -n \"$IPKG_INSTROOT\" ] || /usr/libexec/wan-latency-higoos-install remove\nexit 0\n")
    names = [main_ipk, higo_ipk, build_run(main_ipk, higo_ipk), source_zip()]
    sums = []
    for name in names:
        sums.append(hashlib.sha256((OUT / name).read_bytes()).hexdigest() + "  " + name)
    (OUT / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8", newline="\n")
    shutil.copy2(ROOT / "RELEASE_NOTES.md", OUT / "RELEASE_NOTES.md")
    print("\n".join(str(OUT / n) for n in names + ["SHA256SUMS", "RELEASE_NOTES.md"]))

if __name__ == "__main__": main()
