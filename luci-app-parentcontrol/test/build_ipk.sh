#!/bin/sh
# 本地组 ipk。用法： sh test/build_ipk.sh [输出目录]（默认 /tmp）
#
# 为什么需要这个脚本：
#  - 本仓库的 GitHub Actions 从未真正跑起来（见报告 §I.1），发布只能本地组包；
#  - OpenWrt 的 .ipk 是 **gzip 压缩的 tar**，**不是 `ar` 归档**。用 `ar rc` 组出来的包
#    会被 opkg-lede 报 `Malformed package file`（踩过）。
#  - 包内成员顺序与官方包一致：./debian-binary ./data.tar.gz ./control.tar.gz
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${1:-/tmp}
NAME=luci-app-parentcontrol
VER=$(sed -n 's/^PKG_VERSION:=//p' "$REPO/Makefile")
REL=$(sed -n 's/^PKG_RELEASE:=//p' "$REPO/Makefile")
FULL="$VER-$REL"
[ -n "$VER" ] && [ -n "$REL" ] || { echo "Makefile 里读不到 PKG_VERSION/PKG_RELEASE" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM

# ---- data：root/ 铺到 /，luasrc/ 铺到 /usr/lib/lua/luci/ ----
mkdir -p "$STAGE/data/usr/lib/lua/luci"
cp -a "$REPO/root/." "$STAGE/data/"
cp -a "$REPO/luasrc/." "$STAGE/data/usr/lib/lua/luci/"
find "$STAGE/data" -name '._*' -delete 2>/dev/null || true
find "$STAGE/data" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/data/etc/init.d/parentcontrol"
SIZE=$(du -sk "$STAGE/data" | awk '{print $1}')

# ---- control ----
mkdir -p "$STAGE/ctl"
cat > "$STAGE/ctl/control" <<EOF
Package: $NAME
Version: $FULL
Depends: libc, iptables-mod-filter, kmod-ipt-filter, luci-lua-runtime
Source: $NAME
SourceName: $NAME
License: Apache-2.0
Section: luci
Maintainer: neohob
Architecture: all
Installed-Size: $SIZE
Description: LuCI support for Parent Control (parentcontrol)
EOF
printf '/etc/config/parentcontrol\n' > "$STAGE/ctl/conffiles"
cat > "$STAGE/ctl/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF
cat > "$STAGE/ctl/prerm" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF
chmod 755 "$STAGE/ctl/postinst" "$STAGE/ctl/prerm"

# ---- 三个成员 ----
# 固定 mtime 使构建可复现（否则每次组包 md5 都不同）：优先 SOURCE_DATE_EPOCH，
# 其次取 HEAD 提交时间，最后退到 0。
# 注：macOS 的 bsdtar 不支持 `--mtime`，故用 python 统一 touch。
MT=${SOURCE_DATE_EPOCH:-$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || echo 0)}
[ -n "$MT" ] || MT=0
freeze() {
	python3 - "$1" "$MT" <<'PY'
import os, sys
root, mt = sys.argv[1], int(sys.argv[2])
try:
    os.utime(root, (mt, mt))
except OSError:
    pass
for dp, dns, fns in os.walk(root):
    for n in dns + fns:
        try:
            os.utime(os.path.join(dp, n), (mt, mt))
        except OSError:
            pass
PY
}
TAROPTS='--format=ustar --no-xattrs --owner=0 --group=0 --numeric-owner'
# 注：libarchive 的 `tar -z` 会把 **当前时间** 写进 gzip 头，导致 md5 不可复现，
# 故一律先出未压缩 tar，再用 `gzip -n -9` 压（-n = 不写名字与时间戳）。
freeze "$STAGE/data"
# shellcheck disable=SC2086
(cd "$STAGE/data" && COPYFILE_DISABLE=1 tar $TAROPTS -cf "$STAGE/data.tar" .)
gzip -n -9 -c "$STAGE/data.tar" > "$STAGE/data.tar.gz"
rm -f "$STAGE/data.tar"
freeze "$STAGE/ctl"
# shellcheck disable=SC2086
(cd "$STAGE/ctl" && COPYFILE_DISABLE=1 tar $TAROPTS -cf "$STAGE/control.tar" .)
gzip -n -9 -c "$STAGE/control.tar" > "$STAGE/control.tar.gz"
rm -f "$STAGE/control.tar"
printf '2.0\n' > "$STAGE/debian-binary"

mkdir -p "$OUT"
IPK="$OUT/${NAME}_${FULL}_all.ipk"
freeze "$STAGE"
# shellcheck disable=SC2086
(cd "$STAGE" && COPYFILE_DISABLE=1 tar $TAROPTS -cf "$STAGE/ipk.tar" ./debian-binary ./data.tar.gz ./control.tar.gz)
gzip -n -9 -c "$STAGE/ipk.tar" > "$IPK"
rm -f "$STAGE/ipk.tar"

printf 'built: %s\n' "$IPK"
printf '  version: %s-   files: %s   size: %s B\n' "$FULL" \
	"$(find "$STAGE/data" -type f | wc -l | tr -d ' ')" "$(wc -c < "$IPK" | tr -d ' ')"
md5sum "$IPK" 2>/dev/null || md5 -r "$IPK"
