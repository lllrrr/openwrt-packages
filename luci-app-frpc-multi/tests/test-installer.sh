#!/bin/sh
set -eu
SRC=${1:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)/install.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/apk/etc/apk" "$T/opkg" "$T/log"
cat > "$T/bin/uname" <<'EOF'
#!/bin/sh
echo "$TEST_ARCH"
EOF
cat > "$T/bin/apk" <<'EOF'
#!/bin/sh
echo "apk $*" >> "$TEST_LOG"
[ "$1" = update ] && exit 0
[ "$1" = add ] && { echo "$*" | grep -q 'aarch64\.apk\|x86_64\.apk'; exit $?; }
exit 19
EOF
cat > "$T/bin/opkg" <<'EOF'
#!/bin/sh
echo "opkg $*" >> "$TEST_LOG"
[ "$1" = update ] && exit 0
[ "$1" = install ] && { echo "$*" | grep -q '_aarch64_generic\.ipk\|_x86_64\.ipk'; exit $?; }
exit 19
EOF
chmod +x "$T/bin/"*
for spec in 'apk aarch64' 'apk x86_64' 'opkg aarch64' 'opkg x86_64'; do
 set -- $spec; mode=$1; arch=$2; : > "$T/log/$mode-$arch"
 mkdir -p "$T/root"; path="$T/bin:$PATH"
 TEST_ARCH=$arch TEST_LOG="$T/log/$mode-$arch" FRPC_MULTI_PKG_MODE=$mode PATH=$path "$SRC" >/dev/null
 line=$(tail -1 "$T/log/$mode-$arch")
 case "$mode/$arch" in
  apk/aarch64) echo "$line" | grep -q '1.0.0-r8-aarch64.apk' ;;
  apk/x86_64) echo "$line" | grep -q '1.0.0-r8-x86_64.apk' ;;
  opkg/aarch64) echo "$line" | grep -q '1.0.0-r8_aarch64_generic.ipk' ;;
  opkg/x86_64) echo "$line" | grep -q '1.0.0-r8_x86_64.ipk' ;;
 esac
 echo "PASS $mode $arch: $line"

done
set +e
TEST_ARCH=armv7 TEST_LOG="$T/log/unsupported" PATH="$T/bin:$PATH" "$SRC" >/dev/null 2>&1
rc=$?
set -e
[ $rc -eq 2 ] && echo 'PASS unsupported architecture rejected' || { echo 'FAIL unsupported architecture'; exit 1; }
