#!/bin/sh
# AdGuard Home 管理中心 - 修改面板密码
# 说明：密码哈希由浏览器端 bcrypt 计算，脚本只负责写入 YAML 并重启服务。

. /usr/share/adguardhome-lite/common.sh

HASHFILE="/var/run/adguardhome_lite_new_hash"
PASSFILE="/var/run/adguardhome_lite_new_pass"
TMPFILE=""

cleanup() {
    rm -f "$HASHFILE" "$PASSFILE"
    [ -n "$TMPFILE" ] && rm -f "$TMPFILE"
}

die() {
    log_msg "错误：$*"
    exit 1
}

trap cleanup EXIT

load_conf

hash=$(cat "$HASHFILE" 2>/dev/null | tr -d '\r\n')
pass=$(cat "$PASSFILE" 2>/dev/null)

[ -n "$hash" ] || die "未收到新的密码哈希。"
[ -n "$pass" ] || die "新密码为空。"

case "$hash" in
    '$2a$'*|'$2b$'*|'$2y$'*) ;;
    *) die "密码哈希格式不正确。" ;;
esac

# bcrypt 哈希长度通常为 60 左右，过短说明数据异常
[ ${#hash} -ge 50 ] || die "密码哈希长度异常。"

[ -s "$configpath" ] || die "配置文件不存在，请先启用服务。"

was_running="0"
is_agh_running && was_running="1"

log_msg "正在停止服务并写入新密码..."
/etc/init.d/adguardhome_lite stop >/dev/null 2>&1

cp -f "$configpath" "$configpath.bak" 2>/dev/null

TMPFILE="$configpath.tmp.$$"
awk -v hash="$hash" '
    BEGIN { done = 0; inusers = 0 }
    /^users:/ { inusers = 1; print; next }
    inusers && /^    password:/ {
        print "    password: " hash
        done = 1
        next
    }
    inusers && /^[^ ]/ { inusers = 0 }
    { print }
    END { if (done != 1) exit 1 }
' "$configpath" > "$TMPFILE"

if [ $? -ne 0 ]; then
    die "未找到 users.password 配置项，无法修改密码。"
fi

mv -f "$TMPFILE" "$configpath" || die "写入配置文件失败。"
TMPFILE=""

if ! check_agh_config; then
    log_msg "$(cat /var/run/adguardhome_lite_check.log 2>/dev/null)"
    cp -f "$configpath.bak" "$configpath" 2>/dev/null
    [ "$was_running" = "1" ] && /etc/init.d/adguardhome_lite start >/dev/null 2>&1
    die "新配置校验失败，已恢复原密码。"
fi

# 明文密码必须保留：AGH 只存 bcrypt 哈希且不可逆，插件调用本机 API 需要原文。
# 因此这里收紧配置文件权限，保证只有 root 能读到。
uci -q set "$CONF.main.adminpass=$pass"
uci -q commit "$CONF" 2>/dev/null
chmod 600 "/etc/config/$CONF" 2>/dev/null

if [ "$was_running" = "1" ]; then
    log_msg "正在重新启动服务..."
    /etc/init.d/adguardhome_lite start >/dev/null 2>&1
else
    log_msg "服务当前未运行，新密码将在下次启动时生效。"
fi

log_msg "面板密码修改成功。"
exit 0
