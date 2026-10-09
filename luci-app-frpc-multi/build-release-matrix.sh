#!/bin/sh
# Script-only packages: APK noarch and IPK all. CPU-specific frpc stays separate.
set -eu
VER=${VER:-1.0.0-r11}
SRC=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
OUT=${OUT:-$SRC/dist}
mkdir -p "$OUT"
if [ -z "${APK_MKPKG:-}" ]; then
 command -v docker >/dev/null 2>&1 || { echo "需要 Docker 或 APK_MKPKG=apk-v3 路径" >&2; exit 1; }
fi
APK_ARCH=noarch VER=$VER sh "$SRC/build-apk.sh" "$SRC" "$OUT"
mv "$OUT/luci-app-frpc-multi-$VER.apk" "$OUT/luci-app-frpc-multi-$VER-noarch.apk"
# Generate a generic script-only IPK, then label duplicate downloadable files by target arch.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root" "$T/scripts"
cp -a "$SRC/root/." "$T/root/"
cp "$SRC/scripts/post-install" "$SRC/scripts/pre-deinstall" "$T/scripts/"
python3 "$SRC/scripts/make-ipk.py" --root "$T/root" --out "$T" --scripts "$T/scripts" --version "$VER" --arch all --license 'Apache-2.0 and GPL-2.0-only'
cp "$T/luci-app-frpc-multi_${VER}_all.ipk" "$OUT/luci-app-frpc-multi_${VER}_all.ipk"
(cd "$OUT" && sha256sum luci-app-frpc-multi-$VER-*.apk luci-app-frpc-multi_${VER}_*.ipk > SHA256SUMS)
cat "$OUT/SHA256SUMS"
