#!/bin/sh
# Build APK (Alpine apk arch: aarch64 + x86_64) and IPK (script-only payload, Architecture: all).
set -eu
VER=${VER:-1.0.0-r8}
SRC=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
OUT=${OUT:-$SRC/dist}
mkdir -p "$OUT"
command -v docker >/dev/null 2>&1 || { echo "需要 Docker 才能构建 APK" >&2; exit 1; }
# Build APK metadata separately for each supported OpenWrt apk architecture.
for SPEC in 'aarch64 aarch64' 'x86_64 x86_64'; do
    set -- $SPEC; LABEL=$1; APK_ARCH=$2
    APK_ARCH=$APK_ARCH VER=$VER sh "$SRC/build-apk.sh" "$SRC" "$OUT"
    mv "$OUT/luci-app-frpc-multi-$VER.apk" "$OUT/luci-app-frpc-multi-$VER-$LABEL.apk"
done
# Generate a generic script-only IPK, then label duplicate downloadable files by target arch.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root" "$T/scripts"
cp -a "$SRC/root/." "$T/root/"
cp "$SRC/scripts/post-install" "$SRC/scripts/pre-deinstall" "$T/scripts/"
python3 "$SRC/scripts/make-ipk.py" --root "$T/root" --out "$T" --scripts "$T/scripts" --version "$VER" --arch all --license 'Apache-2.0 and GPL-2.0-only'
for A in aarch64_generic x86_64; do
    cp "$T/luci-app-frpc-multi_${VER}_all.ipk" "$OUT/luci-app-frpc-multi_${VER}_$A.ipk"
done
(cd "$OUT" && sha256sum luci-app-frpc-multi-$VER-*.apk luci-app-frpc-multi_$VER-*.ipk > SHA256SUMS)
cat "$OUT/SHA256SUMS"
