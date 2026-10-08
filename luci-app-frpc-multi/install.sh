#!/bin/sh
# One-command installer for luci-app-frpc-multi v1.0.0-r8.
# Detects apk/opkg and CPU architecture; asks the native package manager to resolve frpc.
set -eu

REPO='https://github.com/myc2002/luci-app-frpc-multi'
TAG='v1.0.0-r8'
PKG='luci-app-frpc-multi'

if [ "$(id -u)" != 0 ]; then
    echo '请用 root 身份运行。' >&2
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64) APK_ARCH=aarch64; IPK_ARCH=aarch64_generic ;;
    x86_64|amd64)  APK_ARCH=x86_64;         IPK_ARCH=x86_64 ;;
    *) echo "不支持的 CPU 架构：$ARCH（仅支持 arm64/aarch64 和 x86_64）" >&2; exit 2 ;;
esac

MODE=${FRPC_MULTI_PKG_MODE:-auto}
if [ "$MODE" = apk ] || { [ "$MODE" = auto ] && command -v apk >/dev/null 2>&1 && [ -d /etc/apk ]; }; then
    URL="$REPO/releases/download/$TAG/$PKG-1.0.0-r8-$APK_ARCH.apk"
    echo "检测到 apk + $ARCH，更新软件源并安装 $PKG 与依赖 frpc …"
    apk update
    exec apk add --allow-untrusted "$URL"
elif [ "$MODE" = opkg ] || { [ "$MODE" = auto ] && command -v opkg >/dev/null 2>&1; }; then
    URL="$REPO/releases/download/$TAG/${PKG}_1.0.0-r8_${IPK_ARCH}.ipk"
    echo "检测到 opkg + $ARCH，更新软件源并安装 $PKG 与依赖 frpc …"
    opkg update
    exec opkg install "$URL"
else
    echo '未检测到 apk 或 opkg。此安装器仅支持 OpenWrt / iStoreOS。' >&2
    exit 3
fi
