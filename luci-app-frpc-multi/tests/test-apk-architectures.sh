#!/bin/sh
# Offline architecture/extraction tests only. Stubs are NOT runtime dependencies.
set -eu
A=${APK3:?set APK3 to an apk v3 executable}
PKG=${1:?absolute APK path}
T=$(mktemp -d /tmp/frpc-apk-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/empty" "$T/roots"
"$A" mkpkg -I name:frpc-test-deps -I version:1.0.0-r0 \
 -I arch:noarch -I description:test-only-dependency-stub -I license:MIT \
 -I 'provides:frpc=1.0.0 luci-base=1.0.0 rpcd-mod-ucode=1.0.0 ucode-mod-uci=1.0.0 ucode-mod-ubus=1.0.0 ucode-mod-fs=1.0.0 ucode-mod-socket=1.0.0' \
 -F "$T/empty" -o "$T/deps.apk"
"$A" mkpkg -I name:frpc-wrong-arch -I version:1.0.0-r0 \
 -I arch:aarch64 -I description:negative-arch-test -I license:MIT \
 -F "$T/empty" -o "$T/negative.apk"
for ARCH in aarch64_generic aarch64_cortex-a53 x86_64; do
 R="$T/roots/$ARCH"; mkdir -p "$R"
 "$A" --root "$R" --arch "$ARCH" --no-network --allow-untrusted --no-scripts add --initdb "$T/deps.apk"
 "$A" --root "$R" --arch "$ARCH" --no-network --allow-untrusted --no-scripts --simulate add "$PKG"
 "$A" --root "$R" --arch "$ARCH" --no-network --allow-untrusted --no-scripts add "$PKG"
 "$A" --root "$R" --arch "$ARCH" --no-network info -e luci-app-frpc-multi
 test -f "$R/www/luci-static/resources/view/frpc-multi.js"
 test "$(stat -c %a "$R/etc/config/frpc_multi")" = 600
 test "$(stat -c %a "$R/etc/init.d/frpc-multi")" = 755
 if "$A" --root "$R" --arch "$ARCH" --no-network --allow-untrusted --no-scripts --simulate add "$T/negative.apk" > "$T/negative.log" 2>&1; then
  echo 'FAIL: wrong architecture unexpectedly accepted' >&2; exit 1
 fi
 rg 'uninstallable|incompatible' "$T/negative.log" >/dev/null
 echo "PASS real APK v3: $ARCH accepts noarch; rejects aarch64; files and permissions correct"
done
 echo 'Fixture dependencies only; no real feeds or post-install/init scripts tested.'
