#!/bin/sh
# Build a standard OpenWrt ipk package (tar.gz outer container).
# NOTE: outer container MUST be tar.gz, not ar — BusyBox opkg on QWRT etc.
# has no 'ar' applet and fails with 'Malformed package file' on ar ipk.
# Format regression was introduced in v0.3.30 and reverted in v0.3.33.

set -eu
umask 022

BASE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$BASE/Makefile")"
RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$BASE/Makefile")"
CONTROL_VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "$BASE/CONTROL/control")"
[ "$CONTROL_VERSION" = "${VERSION}-${RELEASE}" ] || { echo "ERROR: CONTROL/control is $CONTROL_VERSION, expected ${VERSION}-${RELEASE}" >&2; exit 1; }
OUT="$BASE/releases/luci-app-route-tool_${VERSION}-${RELEASE}_all.ipk"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/route-tool-ipk.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT HUP INT TERM

mkdir -p "$STAGE/control" "$STAGE/data" "$BASE/releases"
cp "$BASE/CONTROL/control" \
   "$BASE/CONTROL/postinst" \
   "$BASE/CONTROL/prerm" \
   "$BASE/CONTROL/postrm" \
   "$STAGE/control/"
chmod 755 "$STAGE/control/postinst" "$STAGE/control/prerm" "$STAGE/control/postrm"
cp -a "$BASE/files/." "$STAGE/data/"
find "$STAGE/data" -name '*.orig' -delete
printf '2.0\n' > "$STAGE/debian-binary"

tar --owner=0 --group=0 --numeric-owner -C "$STAGE/control" -czf "$STAGE/control.tar.gz" .
tar --owner=0 --group=0 --numeric-owner -C "$STAGE/data" -czf "$STAGE/data.tar.gz" .
rm -f "$OUT"
(cd "$STAGE" && tar -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz)

tar tzf "$OUT" | grep -qx './debian-binary'
tar tzf "$OUT" | grep -qx './control.tar.gz'
tar tzf "$OUT" | grep -qx './data.tar.gz'

SIZE="$(wc -c < "$OUT")"
SHA256="$(sha256sum "$OUT" | awk '{print $1}')"
printf 'IPK built: %s\nSize: %s bytes\nSHA256: %s\n' "$OUT" "$SIZE" "$SHA256"
