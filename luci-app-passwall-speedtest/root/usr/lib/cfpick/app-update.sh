#!/bin/sh
# Online update for the LuCI package.
#
# Fetches the latest GitHub release, downloads the matching opkg/apk asset and
# installs it.  This script is copied to /tmp and run detached because the
# package upgrade (or the rpcd restart afterwards) would otherwise interrupt
# the LuCI RPC call that started it.
#
# Status is written to /tmp/cfpick-app-update.json for the web UI to poll; the
# full log stays in /tmp/cfpick-app-update.log.

set -u

REPO="urbanescavenger/CFPick"
API="https://api.github.com/repos/$REPO/releases/latest"
WORK=/tmp/cfpick-app-update
STATUS=/tmp/cfpick-app-update.json
LOG=/tmp/cfpick-app-update.log
PIDFILE=/tmp/cfpick-app-update.pid

echo $$ > "$PIDFILE"
: > "$LOG"

say() {
    echo "$(date '+%H:%M:%S') $*" >> "$LOG"
}

write_status() {
    # $1 updating, $2 ok, $3 message, $4 version
    python3 - "$1" "$2" "$3" "$4" >/dev/null 2>&1 <<'PY'
import json
import sys
import time

updating, ok, message, version = sys.argv[1:5]
json.dump({
    "updating": updating == "1",
    "ok": ok == "1",
    "message": message,
    "version": version,
    "updated_at": int(time.time()),
}, open("/tmp/cfpick-app-update.json", "w"))
PY
}

fail() {
    say "FAILED: $*"
    write_status 0 0 "更新失败：$*" ""
    rm -f "$PIDFILE"
    exit 1
}

mkdir -p "$WORK" || fail "无法创建临时目录"
rm -f "$WORK"/* 2>/dev/null

write_status 1 0 "正在获取最新版本" ""
say "fetching $API"
curl -fsSL --max-time 30 -o "$WORK/release.json" "$API" || fail "无法访问 GitHub API"
[ -s "$WORK/release.json" ] || fail "GitHub API 返回为空"

if command -v opkg >/dev/null 2>&1; then
    MANAGER=opkg
    APP_RE='^luci-app-cfpick_.*_all\.ipk$'
    I18N_RE='^luci-i18n-cfpick-zh-cn_.*_all\.ipk$'
    I18N_INSTALLED=0
    opkg list-installed 2>/dev/null | grep -q '^luci-i18n-cfpick-zh-cn ' && I18N_INSTALLED=1
elif command -v apk >/dev/null 2>&1; then
    MANAGER=apk
    APP_RE='^luci-app-cfpick-.*\.apk$'
    I18N_RE='^luci-i18n-cfpick-zh-cn-.*\.apk$'
    I18N_INSTALLED=0
    apk info -e luci-i18n-cfpick-zh-cn >/dev/null 2>&1 && I18N_INSTALLED=1
else
    fail "找不到 opkg 或 apk"
fi

PARSED=$(python3 - "$WORK/release.json" "$I18N_INSTALLED" "$APP_RE" "$I18N_RE" <<'PY'
import json
import re
import sys

path, i18n_installed, app_re, i18n_re = sys.argv[1:5]
data = json.load(open(path))
assets = data.get("assets") or []


def find(pattern):
    rx = re.compile(pattern)
    for asset in assets:
        name = str(asset.get("name") or "")
        if rx.match(name):
            return name, str(asset.get("browser_download_url") or "")
    return "", ""


app_name, app_url = find(app_re)
i18n_name, i18n_url = find(i18n_re) if i18n_installed == "1" else ("", "")
print(str(data.get("tag_name") or ""))
print(app_name)
print(app_url)
print(i18n_name)
print(i18n_url)
PY
) || fail "解析 Release 资源失败"

TAG=$(echo "$PARSED" | sed -n '1p')
APP_NAME=$(echo "$PARSED" | sed -n '2p')
APP_URL=$(echo "$PARSED" | sed -n '3p')
I18N_NAME=$(echo "$PARSED" | sed -n '4p')
I18N_URL=$(echo "$PARSED" | sed -n '5p')

[ -n "$APP_URL" ] || fail "Release 中没有找到 $MANAGER 安装包"
[ -n "$TAG" ] || TAG="latest"

write_status 1 0 "正在下载 $TAG" "$TAG"
say "download $APP_NAME"
APP_FILE="$WORK/$APP_NAME"
curl -fL --max-time 120 -o "$APP_FILE" "$APP_URL" >> "$LOG" 2>&1 || fail "下载 $APP_NAME 失败"
[ -s "$APP_FILE" ] || fail "下载的安装包为空"

PKG_FILES="$APP_FILE"
if [ -n "$I18N_URL" ]; then
    say "download $I18N_NAME"
    I18N_FILE="$WORK/$I18N_NAME"
    curl -fL --max-time 120 -o "$I18N_FILE" "$I18N_URL" >> "$LOG" 2>&1 || say "i18n 下载失败，继续更新主程序"
    if [ -s "$I18N_FILE" ]; then
        PKG_FILES="$PKG_FILES $I18N_FILE"
    fi
fi

write_status 1 0 "正在安装 $TAG" "$TAG"
say "installing $PKG_FILES"
if [ "$MANAGER" = "opkg" ]; then
    # shellcheck disable=SC2086
    opkg install --force-reinstall --force-overwrite --force-downgrade $PKG_FILES >> "$LOG" 2>&1 \
        || fail "opkg 安装失败"
else
    # shellcheck disable=SC2086
    apk add --allow-untrusted --force-overwrite $PKG_FILES >> "$LOG" 2>&1 \
        || fail "apk 安装失败"
fi

say "reloading services"
/etc/init.d/rpcd restart >> "$LOG" 2>&1 || true
if [ -x /etc/init.d/cfpick-web ]; then
    /etc/init.d/cfpick-web restart >> "$LOG" 2>&1 || true
fi
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null || true

write_status 0 1 "更新完成" "$TAG"
say "done: $TAG"
rm -f "$PIDFILE"
