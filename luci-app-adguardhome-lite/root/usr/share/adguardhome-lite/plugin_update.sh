#!/bin/sh
# AdGuard Home 管理中心 - 插件在线更新
# 用法：plugin_update.sh <版本> <cn|github> <source|package> [force]
# 结果：$RUN_plugin_update.code（0=成功）；过程写入 $RUN_plugin_update.log

RUN="/var/run/adguardhome_lite"
LOG="${RUN}_plugin_update.log"
CODE="${RUN}_plugin_update.code"
RUNNING="${RUN}_plugin_update.running"
LOCK="${RUN}_plugin_update.lock"
SHARE_DIR="/usr/share/adguardhome-lite"
SOURCE_MARK="$SHARE_DIR/install_source"

# 更新会覆盖本脚本自身，先复制到 /tmp 再执行
case "$0" in
    /tmp/agh_plugin_update.*) ;;
    *)
        if ! cp -f "$0" "/tmp/agh_plugin_update.$$" 2>/dev/null; then
            echo 1 > "$CODE"
            exit 1
        fi
        exec sh "/tmp/agh_plugin_update.$$" "$@"
        ;;
esac

. /usr/share/adguardhome-lite/common.sh
load_conf

VER="${1:-}"
CHANNEL="${2:-cn}"
METHOD="${3:-source}"
FORCE="${4:-0}"
if [ "$METHOD" = "source" ]; then
    METHOD_LABEL="通用模式"
else
    METHOD_LABEL="安装包模式"
fi

REPO="Ozero-top/luci-app-adguardhome-lite"
GITHUB="https://github.com/$REPO"
REL="$GITHUB/releases/download/v$VER"
JSD="https://cdn.jsdelivr.net/gh/$REPO@dist"

# 跟随面板里的 GitHub 反代设置，避免这里写死与设置不一致
proxy_host=""
case "$github_proxy" in
    gh-proxy.org|ghproxy.cc|ghproxy.com|ghfast.top) proxy_host="$github_proxy" ;;
esac
PREL=""
PGIT=""
if [ -n "$proxy_host" ]; then
    PREL="https://$proxy_host/$REL"
    PGIT="https://$proxy_host/$GITHUB"
fi

TMP=""
cleanup() {
    rm -rf "$LOCK"
    rm -f "$RUNNING"
    [ -n "$TMP" ] && rm -rf "$TMP"
    case "$0" in
        /tmp/agh_plugin_update.*) rm -f "$0" ;;
    esac
}
trap cleanup EXIT INT TERM

say() {
    log_progress "$*"
}

fail() {
    say "更新失败：$*"
    echo 1 > "$CODE"
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# 防止并发更新；异常退出留下的锁超过 30 分钟自动清理
lock_age() {
    _mt="$(stat -c %Y "$LOCK" 2>/dev/null || echo "")"
    [ -n "$_mt" ] || _mt="$(date -r "$LOCK" +%s 2>/dev/null || echo "")"
    [ -n "$_mt" ] || { echo 0; return; }
    echo $(( $(date +%s) - _mt ))
}

if ! mkdir "$LOCK" 2>/dev/null; then
    if [ "$(lock_age)" -gt 1800 ]; then
        rm -rf "$LOCK"
        if ! mkdir "$LOCK" 2>/dev/null; then
            say "已有更新任务在运行，请稍后再试。"
            echo 1 > "$CODE"
            exit 1
        fi
    else
        say "已有更新任务在运行，请稍后再试。"
        echo 1 > "$CODE"
        exit 1
    fi
fi
: > "$RUNNING"

case "$VER" in
    ''|*[!0-9A-Za-z.-]*) fail "目标版本无效：$VER" ;;
esac
case "$CHANNEL" in cn|github) ;; *) CHANNEL="cn" ;; esac
case "$METHOD" in source|package) ;; *) METHOD="source" ;; esac

TMP="$(mktemp -d /tmp/agh_plugin_update.XXXXXX 2>/dev/null)" || fail "创建临时目录失败"

case "$CHANNEL" in
    github)
        ASSET_MIRRORS="$REL $PREL $JSD"
        SRC_MIRRORS="$GITHUB $PGIT"
        ;;
    *)
        ASSET_MIRRORS="$JSD $PREL $REL"
        SRC_MIRRORS="$PGIT $GITHUB"
        ;;
esac

say "开始更新插件：v$VER（渠道：$CHANNEL，方式：$METHOD_LABEL）"
[ "$FORCE" = "1" ] && say "强制更新/降级模式"

backup_config() {
    [ "$FORCE" = "1" ] || return 0
    if [ -f /etc/config/adguardhome_lite ]; then
        cp -p /etc/config/adguardhome_lite /etc/config/adguardhome_lite.bak 2>/dev/null \
            && say "已备份配置：/etc/config/adguardhome_lite.bak"
    fi
}

# 按渠道顺序下载，失败自动切换节点
mval() {
    sed -n "s/^$1=//p" "$MANIFEST" 2>/dev/null | head -n 1
}

clear_caches() {
    rm -f "${RUN}_plugin_version" "${RUN}_plugin_update" 2>/dev/null
    rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
    rm -rf /tmp/luci-modulecache 2>/dev/null
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1
    if [ "$1" != "norestart" ] && [ "$(uci -q get adguardhome_lite.main.enabled 2>/dev/null)" = "1" ]; then
        say "重启 AdGuard Home 服务..."
        /etc/init.d/adguardhome_lite restart >/dev/null 2>&1
    fi
}

# ===== 通用模式的安全网：更新前快照、更新后校验、失败自动回滚 =====
WAS_RUNNING=0
TOUCHED=0
is_agh_running && WAS_RUNNING=1

ROLLBACK="$TMP/rollback.tar.gz"
ROLLBACK_LIST="$TMP/rollback.list"

snapshot_files() {
    : > "$ROLLBACK_LIST"
    for _p in \
        etc/init.d/adguardhome_lite \
        etc/uci-defaults/50_luci-adguardhome-lite \
        usr/share/adguardhome-lite \
        usr/lib/lua/luci/controller/adguardhome_lite.lua \
        usr/lib/lua/luci/model/adguardhome_lite \
        usr/lib/lua/luci/view/adguardhome_lite \
        www/luci-static/resources/adguardhome-lite; do
        [ -e "/$_p" ] && printf '%s\n' "$_p" >> "$ROLLBACK_LIST"
    done
    [ -s "$ROLLBACK_LIST" ] || return 0
    tar -czf "$ROLLBACK" -C / -T "$ROLLBACK_LIST" 2>/dev/null \
        || say "备份当前插件文件失败，本次更新无法自动回滚"
}

rollback_files() {
    [ -s "$ROLLBACK" ] || { say "没有可用的回滚快照"; return 1; }
    say "正在回滚到更新前的插件文件..."
    tar -xzf "$ROLLBACK" -C / || return 1
    return 0
}

health_check() {
    for _f in /etc/init.d/adguardhome_lite \
              /usr/lib/lua/luci/controller/adguardhome_lite.lua \
              /usr/lib/lua/luci/view/adguardhome_lite/panel.htm \
              /www/luci-static/resources/adguardhome-lite/panel.js \
              /usr/share/adguardhome-lite/dns_mode.sh \
              /usr/share/adguardhome-lite/apply_settings.sh; do
        [ -s "$_f" ] || { say "更新后文件缺失：$_f"; return 1; }
    done
    for _f in /usr/share/adguardhome-lite/*.sh /etc/init.d/adguardhome_lite; do
        sh -n "$_f" 2>/dev/null || { say "更新后脚本语法错误：$_f"; return 1; }
    done
    if have luac; then
        luac -p /usr/lib/lua/luci/controller/adguardhome_lite.lua 2>/dev/null \
            || { say "更新后 Lua 语法错误：controller"; return 1; }
    fi
    return 0
}

# 只在更新前服务在运行、且启用状态下验证启动；启动失败才判定新版本有问题
verify_running() {
    [ "$(uci -q get adguardhome_lite.main.enabled 2>/dev/null)" = "1" ] || return 0
    say "重启 AdGuard Home 验证新版本..."
    /etc/init.d/adguardhome_lite restart >/dev/null 2>&1
    _vi=0
    while [ "$_vi" -lt 15 ]; do
        sleep 1
        is_agh_running && return 0
        _vi=$((_vi + 1))
    done
    [ "$WAS_RUNNING" = "1" ] && return 1
    say "服务未运行（更新前也未运行），跳过回滚"
    return 0
}

install_package() {
    MANIFEST="$TMP/manifest-$VER.txt"
    say "读取更新清单..."
    ok=0
    for _base in $ASSET_MIRRORS; do
        say "清单节点：$_base"
        if download_file "$_base/manifest-$VER.txt" "$MANIFEST" && [ -s "$MANIFEST" ]; then
            _ver="$(mval version)"
            [ "$_ver" = "$VER" ] && { ok=1; break; }
            say "清单版本不匹配：$_ver"
        fi
    done
    [ "$ok" = "1" ] || { say "获取更新清单失败"; return 1; }

    if have apk; then
        PM="apk"
        NAME="$(mval apk)"
        SHA="$(mval apk_sha256)"
        # apk 不能安装 ipk，缺 apk 资产时直接回退通用模式
        ALT_NAME=""
        ALT_SHA=""
    elif have opkg; then
        PM="opkg"
        NAME="$(mval modern)"
        SHA="$(mval modern_sha256)"
        ALT_NAME="$(mval legacy)"
        ALT_SHA="$(mval legacy_sha256)"
    else
        say "未找到 opkg 或 apk"
        return 1
    fi

    try_pkg() {
        _name="$1"
        _sha="$2"
        [ -n "$_name" ] || return 1
        _file="$TMP/$_name"
        for _base in $ASSET_MIRRORS; do
            say "安装包节点：$_base"
            if ! download_file "$_base/$_name" "$_file" || [ ! -s "$_file" ]; then
                say "该节点失败，切换下一个"
                continue
            fi
            _actual="$(sha256sum "$_file" 2>/dev/null | awk '{print $1}')"
            if [ "$_actual" != "$_sha" ]; then
                say "校验失败，切换下一个节点"
                continue
            fi
            say "校验通过：$_name"
            if [ "$PM" = "apk" ]; then
                if [ "$FORCE" = "1" ]; then
                    apk add --allow-untrusted --allow-downgrade "$_file" 2>/dev/null \
                        || apk add --allow-untrusted --force-overwrite "$_file" 2>/dev/null \
                        || apk add --allow-untrusted "$_file"
                else
                    apk add --allow-untrusted "$_file" 2>/dev/null \
                        || apk add --allow-untrusted --force-overwrite "$_file"
                fi
            else
                if [ "$FORCE" = "1" ]; then
                    opkg install --force-reinstall --force-downgrade "$_file"
                else
                    opkg install --force-reinstall "$_file"
                fi
            fi
            return $?
        done
        return 1
    }

    if try_pkg "$NAME" "$SHA"; then
        rm -f "$SOURCE_MARK"
        return 0
    fi
    if [ -n "$ALT_NAME" ] && [ "$ALT_NAME" != "$NAME" ]; then
        say "主安装包失败，尝试备用包：$ALT_NAME"
        if try_pkg "$ALT_NAME" "$ALT_SHA"; then
            rm -f "$SOURCE_MARK"
            return 0
        fi
    fi
    return 1
}

install_source() {
    say "下载插件文件包..."
    _tar="$TMP/src.tar.gz"
    _ok=0
    for _base in $SRC_MIRRORS; do
        say "文件包节点：$_base"
        if download_file "$_base/archive/refs/tags/v$VER.tar.gz" "$_tar"; then
            [ -s "$_tar" ] && { _ok=1; break; }
        fi
    done
    [ "$_ok" = "1" ] || { say "插件文件包下载失败"; return 1; }

    mkdir -p "$TMP/src" || return 1
    tar -xzf "$_tar" -C "$TMP/src" || { say "插件文件包解压失败"; return 1; }
    _src="$(find "$TMP/src" -maxdepth 5 -type d -name 'luci-app-adguardhome-lite' -path '*/src/*' | head -n 1)"
    [ -n "$_src" ] && [ -d "$_src/root" ] || { say "插件文件包结构不完整"; return 1; }

    say "备份现有配置..."
    _keep=""
    if [ -f /etc/config/adguardhome_lite ]; then
        _keep="$TMP/keep_adguardhome_lite"
        cp -p /etc/config/adguardhome_lite "$_keep" || return 1
    fi

    # 这些目录完全由插件维护，整体重铺可以清掉旧版本遗留的模块和静态资源
    say "清理旧版本残留文件..."
    TOUCHED=1
    rm -rf /usr/lib/lua/luci/view/adguardhome_lite \
           /usr/lib/lua/luci/model/adguardhome_lite \
           /www/luci-static/resources/adguardhome-lite \
           /usr/share/adguardhome-lite
    rm -f /usr/lib/lua/luci/controller/adguardhome_lite.lua

    say "覆盖插件文件..."
    cp -a "$_src/root/." / || return 1
    mkdir -p /usr/lib/lua/luci /www/luci-static/resources
    cp -a "$_src/luasrc/." /usr/lib/lua/luci/ || return 1
    cp -a "$_src/htdocs/." /www/ || return 1

    if [ -n "$_keep" ] && [ -f "$_keep" ]; then
        cp -p "$_keep" /etc/config/adguardhome_lite
    fi

    chmod 755 /etc/init.d/adguardhome_lite /etc/uci-defaults/50_luci-adguardhome-lite 2>/dev/null
    chmod 755 /usr/share/adguardhome-lite/*.sh 2>/dev/null
    chmod 644 /usr/share/adguardhome-lite/AdGuardHome.yaml.template 2>/dev/null
    [ -x /etc/uci-defaults/50_luci-adguardhome-lite ] && /etc/uci-defaults/50_luci-adguardhome-lite >/dev/null 2>&1
    printf '%s\n' "$VER" > "$SHARE_DIR/install_version" 2>/dev/null
    : > "$SOURCE_MARK" 2>/dev/null
    return 0
}

backup_config
snapshot_files

if [ "$METHOD" = "package" ]; then
    if install_package; then
        clear_caches
        say "更新完成：v$VER（安装包模式）"
        echo 0 > "$CODE"
        exit 0
    fi
    say "安装包模式失败，自动改用通用模式"
fi

if install_source; then
    if ! health_check; then
        rollback_files
        fail "新版本文件校验未通过，已回滚到更新前的版本"
    fi
    clear_caches norestart
    if ! verify_running; then
        rollback_files
        /etc/init.d/adguardhome_lite restart >/dev/null 2>&1
        fail "新版本无法启动，已回滚到更新前的版本"
    fi
    say "更新完成：v$VER（通用模式）"
    echo 0 > "$CODE"
    exit 0
fi

# 覆盖文件阶段失败也要恢复，避免只更新了一半文件
[ "$TOUCHED" = "1" ] && rollback_files
fail "所有更新方式均失败，请查看日志或手动下载安装包"
