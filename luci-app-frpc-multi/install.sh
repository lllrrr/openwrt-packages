#!/bin/sh
# OpenWrt one-command installer: native dependencies + compatible FRPC core if required.
set -eu
REPO=https://github.com/myc2002/luci-app-frpc-multi
TAG=v1.0.0-r11
VERSION=1.0.0-r11
PKG=luci-app-frpc-multi
[ "$(id -u)" = 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
ARCH=$(uname -m)
case "$ARCH" in
 aarch64|arm64)
  FRP_ARCH=arm64
  CORE_SHA=196ddaa51b716c2e99aeb2916b0a2bf55bb317494c4acdcefab36c383de950ba ;;
 x86_64|amd64)
  FRP_ARCH=amd64
  CORE_SHA=317a17a7adac2e6bed2d7a83dc077da91ced0d110e1636373ece8ae5ac8b578b ;;
 *) echo "不支持的架构：$ARCH" >&2; exit 2 ;;
esac
MODE=${FRPC_MULTI_PKG_MODE:-auto}
if [ "$MODE" = apk ] || { [ "$MODE" = auto ] && command -v apk >/dev/null 2>&1 && [ -d /etc/apk ]; }; then
 # Pure scripts: OpenWrt package architecture names differ from Alpine/uname.
 MODE=apk; FILE="$PKG-$VERSION-noarch.apk"
elif [ "$MODE" = opkg ] || { [ "$MODE" = auto ] && command -v opkg >/dev/null 2>&1; }; then
 MODE=opkg; FILE="${PKG}_${VERSION}_all.ipk"
else
 echo '未检测到 OpenWrt apk/opkg。' >&2; exit 3
fi
command -v sha256sum >/dev/null 2>&1 || { echo '缺少 sha256sum，请先安装。' >&2; exit 4; }
T=$(mktemp -d /tmp/frpc-multi-install.XXXXXX)
trap 'rm -rf "$T"' EXIT HUP INT TERM
fetch() {
 if command -v wget >/dev/null 2>&1; then wget -O "$2" "$1"
 elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -O "$2" "$1"
 elif command -v curl >/dev/null 2>&1; then curl -fL --retry 2 -o "$2" "$1"
 else echo '缺少 HTTPS 下载工具。' >&2; return 1; fi
}
BASE="$REPO/releases/download/$TAG"
fetch "$BASE/SHA256SUMS" "$T/SHA256SUMS"
fetch "$BASE/$FILE" "$T/$FILE"
# Verify only the selected asset, fail closed on missing or duplicate checksum.
EXPECTED=''
while read -r digest name rest; do
 if [ "$name" = "$FILE" ]; then
  [ -z "$EXPECTED" ] || { echo '校验表存在重复文件名。' >&2; exit 5; }
  EXPECTED=$digest
 fi
done < "$T/SHA256SUMS"
[ ${#EXPECTED} = 64 ] || { echo '未找到合法包校验值。' >&2; exit 5; }
printf '%s  %s\n' "$EXPECTED" "$T/$FILE" | sha256sum -c -
echo "安装 $MODE / $ARCH 插件和系统依赖（包括 frpc）…"
if [ "$MODE" = apk ]; then
 apk update
 apk add --allow-untrusted "$T/$FILE"
else
 opkg update
 opkg install "$T/$FILE"
fi
# Verify the features actually used by the plugin instead of guessing from version strings.
cat > "$T/probe.toml" <<'EOF'
serverAddr = "127.0.0.1"
serverPort = 1
loginFailExit = false
log.disablePrintColor = true
webServer.addr = "127.0.0.1"
webServer.port = 27499
webServer.user = "probe"
webServer.password = "probe"
[[proxies]]
name = "capability-probe"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 60099
EOF
CORE=/usr/bin/frpc
[ ! -x /usr/lib/frpc-multi/frpc ] || CORE=/usr/lib/frpc-multi/frpc
if ! "$CORE" verify -c "$T/probe.toml" > "$T/verify.log" 2>&1; then
 echo '系统 frpc 不支持所需 TOML/verify 配置，下载官方 0.66.0 独立内核（不覆盖 /usr/bin/frpc）。'
 ARCHIVE="frp_0.66.0_linux_$FRP_ARCH.tar.gz"
 fetch "https://github.com/fatedier/frp/releases/download/v0.66.0/$ARCHIVE" "$T/$ARCHIVE"
 printf '%s  %s\n' "$CORE_SHA" "$T/$ARCHIVE" | sha256sum -c -
 tar -xzf "$T/$ARCHIVE" -C "$T" "frp_0.66.0_linux_$FRP_ARCH/frpc"
 NEW="$T/frp_0.66.0_linux_$FRP_ARCH/frpc"
 chmod 755 "$NEW"
 "$NEW" verify -c "$T/probe.toml"
 mkdir -p /usr/lib/frpc-multi
 cp "$NEW" /usr/lib/frpc-multi/frpc.new
 chmod 755 /usr/lib/frpc-multi/frpc.new
 mv /usr/lib/frpc-multi/frpc.new /usr/lib/frpc-multi/frpc
 CORE=/usr/lib/frpc-multi/frpc
 # Keep the independent core across sysupgrade if the user chooses to retain settings.
 mkdir -p /lib/upgrade/keep.d
 printf '/usr/lib/frpc-multi/frpc\n' > /lib/upgrade/keep.d/frpc-multi-core
fi
/etc/init.d/frpc-multi reload
printf '安装完成：frpc %s；请打开 LuCI → 服务 → frp 多客户端。\n' "$("$CORE" -v)"
