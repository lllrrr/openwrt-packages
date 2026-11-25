#!/bin/sh
# AdGuard Home 管理中心 - DNS 接管看护
# 由 procd 作为独立实例运行；AGH 连续 30 秒无法运行时回退 DNS 接管，避免全网无 DNS。
# 家长控制开启期间每 5 分钟探测一次 AdGuard 服务端，连不上时自动关闭家长控制。
# 不调用 init.d 的停止动作，避免从看护进程递归获取 rc.common 的 procd 锁。

. /usr/share/adguardhome-lite/common.sh

DEAD=0

PARENTAL_URL="https://family.adguard-dns.com/dns-query"
PARENTAL_CACHE="/var/run/adguardhome_lite_parental_probe"
# 开启家长控制期间的最大探测间隔；掉线后最多这么久就能发现
PARENTAL_INTERVAL=30

# 家长控制会把查询送到 AdGuard 服务端判定，连不上时会导致全网无 DNS。
# 开启期间每隔 PARENTAL_INTERVAL 秒探测一次，不通就自动关闭；关闭时不做任何事。
check_parental() {
    grep -q '^  parental_enabled:[[:space:]]*true' "$configpath" 2>/dev/null || {
        [ -f "$PARENTAL_CACHE" ] && rm -f "$PARENTAL_CACHE"
        return 0
    }

    # 缓存有效期内直接复用上次结果，避免每轮循环都阻塞在探测上
    _now="$(date +%s)"
    _mtime="$(stat -c %Y "$PARENTAL_CACHE" 2>/dev/null || echo 0)"
    if [ -f "$PARENTAL_CACHE" ] && [ $(( _now - _mtime )) -lt "$PARENTAL_INTERVAL" ]; then
        [ "$(cat "$PARENTAL_CACHE" 2>/dev/null)" = "fail" ] || return 0
    else
        _code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$PARENTAL_URL" 2>/dev/null)"
        if [ -n "$_code" ] && [ "$_code" != "000" ]; then
            printf 'ok\n' > "$PARENTAL_CACHE"
            return 0
        fi
        printf 'fail\n' > "$PARENTAL_CACHE"
    fi

    # 凭据放 0600 的临时 netrc，避免密码出现在进程参数里
    _netrc="/tmp/adguardhome_lite_parental.netrc.$$"
    ( umask 077; printf 'machine 127.0.0.1\nlogin %s\npassword %s\n' "$adminuser" "$adminpass" > "$_netrc" )
    _rc="$(curl -s -o /dev/null -m 10 -w '%{http_code}' --netrc-file "$_netrc" \
        -X POST "http://127.0.0.1:${webport}/control/parental/disable" 2>/dev/null)"
    rm -f "$_netrc"

    if [ "$_rc" = "200" ]; then
        # 关闭成功后写 ok，等 AGH 落盘期间不再重复关闭
        printf 'ok\n' > "$PARENTAL_CACHE"
        log_event warn parental_auto_disabled "无法连接 AdGuard 家长控制服务（family.adguard-dns.com），已自动关闭家长控制以避免断网。"
    fi
}

# PassWall 的 DNS 端口由 get_new_port 动态分配，重启、切换 DNS 方案或增删 ACL 后可能变化。
# 当前上游仍由插件管理时自动跟随，用户自定义的上游不动；端口没变时什么都不做。
# 注意：AdGuard Home 的 SIGHUP 不会应用上游 DNS 的变更（实测仍查旧端口并报 connection refused），
# 必须结束进程让 procd 用新配置重新拉起，DNS 中断约 10 秒。
PSW_SYNC_INTERVAL=10
PSW_SYNC_LAST=0

sync_passwall_upstream() {
    [ "$dns_mode" = "passwall" ] || return 0
    [ "$upstream_source" = "custom" ] && return 0
    passwall_enabled || return 0

    _exp="$(passwall_upstream_dns)"
    case "$_exp" in
        ''|*:) return 0 ;;
    esac
    _cur="$(yaml_get_list "$configpath" "upstream_dns")"
    _auto="$(uci -q get "$CONF.main.auto_upstream" 2>/dev/null)"
    [ -n "$_cur" ] || return 0
    # 上游已偏离插件记录的值，说明是用户手填的，不再接管
    [ "$_cur" = "$_auto" ] || return 0
    [ "$_cur" != "$_exp" ] || return 0

    yaml_set_list "$configpath" "upstream_dns" "$_exp" || return 0
    uci -q set "$CONF.main.auto_upstream=$_exp"
    uci -q commit "$CONF" 2>/dev/null

    # SIGHUP 只重载过滤规则等配置，上游 DNS 不会生效，必须重启进程；
    # 这里结束 AdGuard Home，由 procd 的 respawn 用新配置拉起。
    _pid="$(pidof AdGuardHome)"
    if [ -n "$_pid" ]; then
        # 给本轮重启留出时间，避免启动稍慢时触发下面的 30 秒回退
        DEAD=0
        kill "$_pid" 2>/dev/null
    fi

    log_event warn passwall_upstream_follow "检测到 PassWall DNS 端口变化，AdGuard Home 上游已自动更新为 $_exp。"
}

while true; do
    sleep 5
    load_conf

    # 用户主动停止或已回退时不动作，但保持进程存活，避免 procd 反复拉起
    if [ "$enabled" != "1" ] || [ "$mode_applied" = "none" ]; then
        DEAD=0
        continue
    fi

    if is_agh_running; then
        check_parental
        _now="$(date +%s)"
        if [ $(( _now - PSW_SYNC_LAST )) -ge "$PSW_SYNC_INTERVAL" ]; then
            PSW_SYNC_LAST="$_now"
            sync_passwall_upstream
        fi
        DEAD=0
        continue
    fi

    DEAD=$(( DEAD + 5 ))
    [ "$DEAD" -lt 30 ] && continue

    log_event error agh_not_running "AdGuard Home 连续 30 秒未运行，正在回退 DNS 接管并恢复 DNSMasq..."
    state_write last_fallback "agh_not_running_30s"

    if ! /usr/share/adguardhome-lite/dns_mode.sh revert; then
        log_event error dns_revert_failed "DNS 接管回退失败，稍后重试。"
        DEAD=0
        continue
    fi

    restart_dnsmasq
    state_write last_fallback "reverted:agh_not_running_30s:$(date '+%Y-%m-%dT%H:%M:%S')"

    # 等价于 init.d stop，但由 ubus 直接删除服务，procd 会同时结束本看护实例
    ubus call service delete '{"name":"adguardhome_lite"}' >/dev/null 2>&1
    exit 0
done
