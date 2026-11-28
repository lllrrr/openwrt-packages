#!/bin/sh
# AdGuard Home 管理中心 - 公共函数库
# 本文件只被插件内的其他脚本引用，请不要直接执行。

CONF="adguardhome_lite"
AGH_SHARE="/usr/share/adguardhome-lite"
AGH_RUN="/var/run/adguardhome_lite"
AGH_UPDATE_LOG="/var/run/adguardhome_lite_update.log"
AGH_ACTION_LOG="/var/run/adguardhome_lite_action.log"

# 加载 OpenWrt 的 UCI shell 函数库
if [ -f /lib/functions.sh ]; then
    . /lib/functions.sh
fi

# 统一日志：级别 + 原因码 + 说明，供面板按级别/原因过滤
# 用法：log_event info dns_applied "说明" / log_event error config_check_failed "说明"
log_event() {
    _lev="$1"
    _reason="$2"
    shift 2
    case "$_lev" in
        error) _prio="user.err" ; _tag="ERROR" ;;
        warn) _prio="user.warning" ; _tag="WARN" ;;
        *) _lev="info" ; _prio="user.info" ; _tag="INFO" ;;
    esac
    logger -t adguardhome_lite -p "$_prio" "[$_tag] $_reason: $*" 2>/dev/null
    echo "[$(date '+%H:%M:%S')] [$_tag] $_reason: $*"
}

# 兼容旧调用点
log_msg() {
    log_event info general "$*"
}

# 持久化关键状态到 /etc/adguardhome_lite/state，重启后仍可排查上次失败原因。
# 采用「临时文件 + rename」原子写入，避免掉电留下半截内容。
state_write() {
    _st_dir="/etc/adguardhome_lite/state"
    _st_key="$1"
    _st_val="$2"
    case "$_st_key" in
        ''|*[!a-z0-9_]*) return 1 ;;
    esac
    mkdir -p "$_st_dir" 2>/dev/null || return 1
    _st_tmp="$_st_dir/.${_st_key}.$$"
    printf '%s\n' "$_st_val" > "$_st_tmp" 2>/dev/null || return 1
    chmod 600 "$_st_tmp" 2>/dev/null
    mv -f "$_st_tmp" "$_st_dir/$_st_key" 2>/dev/null || {
        rm -f "$_st_tmp" 2>/dev/null
        return 1
    }
    return 0
}

# 读取插件配置。所有变量均使用全局变量，供调用脚本直接使用。
load_conf() {
    if command -v config_load >/dev/null 2>&1; then
        config_load "$CONF" 2>/dev/null
    fi

    config_get enabled "main" enabled "0"
    config_get dns_mode "main" dns_mode "takeover"
    config_get webport "main" webport "13800"
    config_get webaddr "main" webaddr "0.0.0.0"
    case "$webaddr" in
        0.0.0.0|127.0.0.1) ;;
        *) webaddr="0.0.0.0" ;;
    esac
    config_get binpath "main" binpath "/usr/bin/AdGuardHome/AdGuardHome"
    config_get configpath "main" config "/etc/AdGuardHome.yaml"
    config_get workdir "main" workdir "/etc/AdGuardHome"
    config_get channel "main" channel "stable"
    config_get github_proxy "main" github_proxy "gh-proxy.org"
    config_get adminuser "main" adminuser "admin"
    # 兜底值与模板内置哈希（admin123）对应，仅在老配置缺字段时命中
    config_get adminpass "main" adminpass "admin123"
    config_get cache_enabled "main" cache_enabled ""
    config_get cache_size_mb "main" cache_size_mb ""
    config_get cache_ttl_min "main" cache_ttl_min ""
    config_get cache_ttl_max "main" cache_ttl_max ""
    config_get cache_optimistic "main" cache_optimistic ""
    config_get upstream_source "main" upstream_source "auto"
    config_get upstream_custom "main" upstream_custom ""
    config_get dns_crypto "main" dns_crypto "off"
    config_get dns_crypto_custom "main" dns_crypto_custom ""
    config_get mode_applied "main" mode_applied "none"

    # Clash 的 DNS 端口（默认 7874），用于串联模式的上游
    clash_dns_port="$(uci -q get openclash.config.dns_port 2>/dev/null)"
    case "$clash_dns_port" in
        ''|*[!0-9]*) clash_dns_port="7874" ;;
    esac

    case "$dns_mode" in
        takeover|passwall) dnsport="53" ;;
        clashfirst) dnsport="5335" ;;
        *) dnsport="5333" ;;
    esac
}

# PassWall / PassWall2 是否启用（停止后 UCI 会置 0，残留 nft 表不能作为判断依据）
passwall_enabled() {
    [ "$(uci -q get passwall2.@global[0].enabled 2>/dev/null)" = "1" ] && return 0
    [ "$(uci -q get passwall.@global[0].enabled 2>/dev/null)" = "1" ]
}

# 输出当前生效的 PassWall 运行时变量文件；尚未启动时无输出。
# 两者都装时以 PassWall2 为准，避免读到 PassWall 1.x 的残留文件。
passwall_runtime_var() {
    if [ "$(uci -q get passwall2.@global[0].enabled 2>/dev/null)" = "1" ]; then
        for _pwv in /tmp/etc/passwall2/var /tmp/etc/passwall2_tmp/var; do
            [ -f "$_pwv" ] && { echo "$_pwv"; return 0; }
        done
    else
        for _pwv in /tmp/etc/passwall/var /tmp/etc/passwall_tmp/var; do
            [ -f "$_pwv" ] && { echo "$_pwv"; return 0; }
        done
    fi
    return 1
}

# PassWall 的 DNS 端口由 get_new_port 动态分配：
#   PassWall 1.x 从 11400 起，变量名 ACL_default_dns_port；
#   PassWall 2.x 从 2001 起，默认 ACL 的变量名为 ACL_acl_default_dns_port。
# 运行时变量不存在（尚未启动）时按各自起始端口推断。
passwall_dns_port() {
    _pwv="$(passwall_runtime_var)"
    if [ -n "$_pwv" ]; then
        for _pwk in ACL_acl_default_dns_port ACL_default_dns_port; do
            _pwp=$(awk -F= -v k="$_pwk" '$1==k{print $2; exit}' "$_pwv" 2>/dev/null | tr -d "\"'[:space:]")
            case "$_pwp" in
                ''|*[!0-9]*) _pwp="" ;;
                *) echo "$_pwp"; return 0 ;;
            esac
        done
    fi

    if [ "$(uci -q get passwall2.@global[0].enabled 2>/dev/null)" = "1" ]; then
        echo "2001"
    else
        echo "11400"
    fi
}

# 部分固件把 network.lan.ipaddr 存成 CIDR（10.0.0.1/24），
# 直接拼进上游会变成非法地址 10.0.0.1/24:11400，AdGuard Home 启动即崩溃。
lan_ipv4() {
    _lip="$(uci -q get network.lan.ipaddr 2>/dev/null)"
    _lip="${_lip%%/*}"
    echo "$_lip"
}

# PassWall 模式下 AdGuard Home 的上游：交给 PassWall 自己的 DNS 做分流与去污染。
# PassWall 未启用时回退到本机 DNSMasq（1745），避免上游指向不存在的端口导致断网。
# 注意：PassWall 自带的 dnsmasq 开了 local-service，只回答局域网来源的查询，
# 用 127.0.0.1 会被拒绝（表现为只有缓存能解析、新域名全部失败），所以这里用局域网 IP。
passwall_upstream_dns() {
    if passwall_enabled; then
        _pw_port="$(passwall_dns_port)"
        # UCI 仍为启用、但进程已被停掉（/etc/init.d/passwall stop 不改 enabled）
        # 时该端口无人监听，继续指向它会让全网查询 SERVFAIL，必须回退到 DNSMasq。
        if [ -n "$_pw_port" ] && port_listening "$_pw_port"; then
            _pw_ip="$(lan_ipv4)"
            [ -n "$_pw_ip" ] || _pw_ip="127.0.0.1"
            echo "$_pw_ip:$_pw_port"
            return 0
        fi
    fi
    echo "127.0.0.1:1745"
}

# 加密上游地址：预设值或用户自定义；关闭时返回空
dns_crypto_url() {
    case "$dns_crypto" in
        alidns) echo "https://dns.alidns.com/dns-query" ;;
        dnspod) echo "https://doh.pub/dns-query" ;;
        cloudflare) echo "https://cloudflare-dns.com/dns-query" ;;
        custom) echo "$dns_crypto_custom" ;;
        *) echo "" ;;
    esac
}

# DNSMasq 实际 DNS 端口；UCI 未显式设置时 OpenWrt 默认 53
dnsmasq_port() {
    _dmp="$(uci -q get dhcp.@dnsmasq[0].port 2>/dev/null)"
    case "$_dmp" in
        ''|*[!0-9]*) _dmp="53" ;;
    esac
    echo "$_dmp"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# DNS 接管动作互斥锁。apply 与 revert 会同时改写 DNSMasq 端口、DHCP option 6、
# nft 规则和 mode_applied，并发执行时后完成的一方会用自己的旧快照覆盖，
# 实测会留下「mode_applied=takeover 但 53 无监听」的断网状态。
# 锁随进程退出自动释放；子脚本通过 AGH_LOCK_HELD 继承，避免自锁。
AGH_LOCK_FILE="/var/run/adguardhome_lite_dnsmode.lock"

lock_action() {
    [ "$AGH_LOCK_HELD" = "1" ] && return 0
    AGH_LOCK_HELD=1
    export AGH_LOCK_HELD

    # 没有 flock 时退化为无锁：宁可并发也不要让用户卡住无法应用设置
    have_cmd flock || return 0
    mkdir -p /var/run 2>/dev/null
    exec 8>"$AGH_LOCK_FILE" 2>/dev/null || return 0

    # BusyBox flock 没有 -w，用轮询实现带超时的等待
    _lk_i=0
    while ! flock -n 8; do
        _lk_i=$(( _lk_i + 1 ))
        if [ "$_lk_i" -ge 20 ]; then
            log_event warn dns_mode_busy "等待其它 DNS 接管任务超时，本次操作已跳过。"
            AGH_LOCK_HELD=""
            return 1
        fi
        sleep 1
    done
    return 0
}

# 不参与接管的接口列表（空格分隔）。
# 只做字符校验，不校验网卡是否存在：nft 的 iifname 是字符串匹配，
# 接口稍后创建（如 wg0）也能直接命中，无需重新生成规则。
bypass_ifaces() {
    _bi=""
    for _i in $(uci -q get "$CONF.main.bypass_ifaces" 2>/dev/null); do
        case "$_i" in
            ''|*[!A-Za-z0-9_.-]*)
                log_msg "忽略非法的排除接口名：$_i" >&2
                continue
                ;;
        esac
        [ "${#_i}" -le 15 ] || { log_msg "忽略超长接口名：$_i" >&2; continue; }
        _bi="$_bi $_i"
    done
    echo "${_bi# }"
}

# 不参与接管的客户端列表，按协议族拆成 BYPASS_V4 / BYPASS_V6
bypass_clients() {
    BYPASS_V4=""
    BYPASS_V6=""
    for _c in $(uci -q get "$CONF.main.bypass_clients" 2>/dev/null); do
        case "$_c" in
            ''|*[!0-9A-Fa-f:./]*)
                log_msg "忽略非法的排除客户端地址：$_c" >&2
                continue
                ;;
        esac
        case "$_c" in
            *:*) BYPASS_V6="$BYPASS_V6 $_c" ;;
            *.*) BYPASS_V4="$BYPASS_V4 $_c" ;;
        esac
    done
    BYPASS_V4="${BYPASS_V4# }"
    BYPASS_V6="${BYPASS_V6# }"
}

# 解析 IPv4 地址；可指定公共 DNS，用于绕过 Clash 等 fake-IP DNS
resolve_ipv4() {
    _rhost="$1"
    _rdns="$2"

    if [ -n "$_rdns" ]; then
        _rout=$(nslookup "$_rhost" "$_rdns" 2>/dev/null)
    else
        _rout=$(nslookup "$_rhost" 2>/dev/null)
    fi

    echo "$_rout" | awk '$1 == "Address:" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }'
}

# 下载进度只写到标准输出（供 LuCI 进度日志显示），不写系统日志，避免刷屏
log_progress() {
    echo "[$(date '+%H:%M:%S')] $*"
}

# 带进度显示的 curl 下载：后台执行 curl，前台每 2 秒读取已下载大小。
# 参数：URL、输出路径、其余参数原样传给 curl。
curl_with_progress() {
    _cp_url="$1"
    _cp_out="$2"
    shift 2

    _cp_rc="/tmp/adguardhome_lite_dl_$$.rc"
    rm -f "$_cp_rc" "$_cp_out"

    # 先探测文件大小；部分反代不返回 Content-Length，此时只显示已下载大小
    _cp_total=$(curl -fsIL --connect-timeout 5 -m 8 "$@" "$_cp_url" 2>/dev/null | tr -d '\r' \
        | awk 'tolower($1) == "content-length:" { v = $2 + 0 } END { print v + 0 }')

    ( curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 2 "$@" -o "$_cp_out" "$_cp_url"; echo $? > "$_cp_rc" ) &

    _cp_start=$(date +%s)
    _cp_last_pct=-1
    _cp_last_log=$_cp_start

    while [ ! -s "$_cp_rc" ]; do
        sleep 2
        [ -s "$_cp_rc" ] && break

        _cp_size=0
        if [ -f "$_cp_out" ]; then
            _cp_size=$(wc -c < "$_cp_out" 2>/dev/null | tr -d ' ')
            [ -n "$_cp_size" ] || _cp_size=0
        fi

        if [ "$_cp_total" -gt 0 ]; then
            _cp_pct=$(( _cp_size * 100 / _cp_total ))
            [ "$_cp_pct" -gt 100 ] && _cp_pct=100
            if [ "$_cp_pct" != "$_cp_last_pct" ]; then
                log_progress "下载进度：${_cp_pct}%（$(( _cp_size / 1024 ))KB / $(( _cp_total / 1024 ))KB）"
                _cp_last_pct="$_cp_pct"
            fi
        else
            _cp_now=$(date +%s)
            if [ $(( _cp_now - _cp_last_log )) -ge 3 ]; then
                log_progress "下载进度：已下载 $(( _cp_size / 1024 ))KB（$(( _cp_now - _cp_start )) 秒）"
                _cp_last_log="$_cp_now"
            fi
        fi
    done

    _cp_code=$(cat "$_cp_rc" 2>/dev/null)
    rm -f "$_cp_rc"

    _cp_elapsed=$(( $(date +%s) - _cp_start ))
    _cp_size=0
    if [ -f "$_cp_out" ]; then
        _cp_size=$(wc -c < "$_cp_out" 2>/dev/null | tr -d ' ')
        [ -n "$_cp_size" ] || _cp_size=0
    fi
    if [ "$_cp_code" = "0" ] && [ "$_cp_size" -gt 0 ]; then
        log_msg "下载完成：$(( _cp_size / 1024 ))KB，用时 ${_cp_elapsed} 秒"
    fi

    return "${_cp_code:-1}"
}

# 下载文件；OpenWrt 上按可用性自动选择下载器
# 如果检测到 fake-IP DNS（198.18.0.0/16 等），使用 curl --resolve 指定真实 IP，
# 避免 Clash 的 fake-IP 路由异常导致下载超时。
download_file() {
    _url="$1"
    _out="$2"

    if have_cmd curl; then
        _scheme="${_url%%://*}"
        _rest="${_url#*://}"
        _hostport="${_rest%%/*}"
        _host="${_hostport%%:*}"
        _port="443"
        [ "$_scheme" = "http" ] && _port="80"
        case "$_hostport" in
            *:*) _port="${_hostport##*:}" ;;
        esac

        _resolve_opts=""
        if [ -n "$_host" ]; then
            _sys_ip=$(resolve_ipv4 "$_host")
            _real_ip=""

            # fake-IP 或系统 DNS 解析失败时，改用公共 DNS 获取真实 IP
            case "$_sys_ip" in
                198.18.*|198.19.*|"")
                    _real_ip=$(resolve_ipv4 "$_host" "223.5.5.5")
                    [ -n "$_real_ip" ] || _real_ip=$(resolve_ipv4 "$_host" "119.29.29.29")
                    case "$_real_ip" in
                        198.18.*|198.19.*) _real_ip="" ;;
                    esac
                    ;;
            esac

            if [ -n "$_real_ip" ]; then
                _resolve_opts="--resolve $_host:$_port:$_real_ip"
                log_msg "检测到 fake-IP DNS，使用真实 IP 下载：$_host -> $_real_ip"

                # GitHub 下载可能跳转到这些域名，提前映射真实 IP
                for _rh in objects.githubusercontent.com release-assets.githubusercontent.com; do
                    _rip=$(resolve_ipv4 "$_rh" "223.5.5.5")
                    case "$_rip" in
                        198.18.*|198.19.*|"") _rip="" ;;
                    esac
                    [ -n "$_rip" ] && _resolve_opts="$_resolve_opts --resolve $_rh:443:$_rip"
                done
            fi
        fi

        if [ -n "$_resolve_opts" ]; then
            curl_with_progress "$_url" "$_out" $_resolve_opts
        else
            curl_with_progress "$_url" "$_out"
        fi
    elif have_cmd wget-ssl; then
        wget-ssl -q --timeout=15 --tries=2 -O "$_out" "$_url"
    elif have_cmd wget; then
        wget -q -T 15 -O "$_out" "$_url"
    elif have_cmd uclient-fetch; then
        uclient-fetch -q -T 15 -O "$_out" "$_url"
    else
        return 127
    fi
}

# 根据设备 CPU 架构匹配 AdGuard Home 官方发布包后缀
# 优先使用 opkg 的架构信息，因为部分 MIPS 设备 uname -m 无法区分大小端
detect_agh_arch() {
    _opkg_arch=$(opkg info kernel 2>/dev/null | awk -F '[: _]' '/^Architecture:/ {print $2; exit}')

    case "$_opkg_arch" in
        mipsel|mipsle) echo "mipsle_softfloat"; return ;;
        mips64el|mips64le) echo "mips64le_softfloat"; return ;;
        mips64) echo "mips64_softfloat"; return ;;
        mips) echo "mips_softfloat"; return ;;
        aarch64|arm64) echo "arm64"; return ;;
        x86_64|amd64) echo "amd64"; return ;;
        i386|i486|i586|i686) echo "386"; return ;;
        riscv64) echo "riscv64"; return ;;
        ppc64le) echo "ppc64le"; return ;;
    esac

    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64) echo "amd64" ;;
        i386|i486|i586|i686|x86) echo "386" ;;
        aarch64|arm64) echo "arm64" ;;
        armv8l|armv7l|armv7) echo "armv7" ;;
        armv6l|armv6) echo "armv6" ;;
        armv5tel|armv5l|armv5|arm) echo "armv5" ;;
        mips64el|mips64le) echo "mips64le_softfloat" ;;
        mips64) echo "mips64_softfloat" ;;
        mipsel|mipsle) echo "mipsle_softfloat" ;;
        mips) echo "mips_softfloat" ;;
        riscv64) echo "riscv64" ;;
        ppc64le|powerpc64le) echo "ppc64le" ;;
        *) echo "" ;;
    esac
}

# 获取目录可用空间（单位：KB）
free_kb() {
    df -k "$1" 2>/dev/null | awk 'NR==2 {gsub(/[^0-9].*/, "", $4); print $4 + 0}'
}

check_agh_config() {
    [ -x "$binpath" ] || return 0
    [ -f "$configpath" ] || return 1
    "$binpath" --check-config -c "$configpath" >/var/run/adguardhome_lite_check.log 2>&1
}

is_agh_running() {
    [ -n "$binpath" ] || return 1

    if have_cmd pgrep; then
        pgrep -f "$binpath" >/dev/null 2>&1 && return 0
    fi

    ps w 2>/dev/null | grep -v grep | grep -F "$binpath" >/dev/null 2>&1
}

# 强制结束残留的 AdGuard Home 进程（procd 停止失败或手动启动时使用）
force_stop_agh() {
    is_agh_running || return 0

    log_msg "检测到残留 AdGuard Home 进程，正在强制结束..."
    if have_cmd pgrep; then
        _pids=$(pgrep -f "$binpath" 2>/dev/null)
    else
        _pids=$(ps w 2>/dev/null | grep -v grep | grep -F "$binpath" | awk '{print $1}')
    fi

    for _pid in $_pids; do
        [ "$_pid" = "$$" ] && continue
        kill "$_pid" 2>/dev/null
    done

    sleep 2
    is_agh_running || return 0

    if have_cmd pgrep; then
        _pids=$(pgrep -f "$binpath" 2>/dev/null)
    else
        _pids=$(ps w 2>/dev/null | grep -v grep | grep -F "$binpath" | awk '{print $1}')
    fi
    for _pid in $_pids; do
        [ "$_pid" = "$$" ] && continue
        kill -9 "$_pid" 2>/dev/null
    done
}

restart_dnsmasq() {
    if [ -x /etc/init.d/dnsmasq ]; then
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
    fi
}

# 判断本机是否有进程监听指定端口（TCP 或 UDP）
port_listening() {
    _lp="$1"
    [ -n "$_lp" ] || return 1
    netstat -lntu 2>/dev/null | grep -qE "[:.]${_lp}[[:space:]]"
}

# 本机发出的 DNS 查询是否被其它插件的 nat_output 规则劫持（Clash/PassWall 常见）。
# 命中时 nslookup 127.0.0.1 打到的是劫持目标而不是本机 DNS 服务，
# 不能用来判断 DNSMasq/AdGuard Home 是否正常，否则会误报断网。
local_dns_hijack_port() {
    have_cmd nft || return 0
    _lh_port="${1:-53}"
    _lh_line=$(nft list ruleset 2>/dev/null \
        | grep -E "oif \"lo\".*dport ${_lh_port} .*redirect to :[0-9]+" | head -n 1)
    [ -n "$_lh_line" ] || return 0
    echo "$_lh_line" | sed -n 's/.*redirect to :\([0-9][0-9]*\).*/\1/p'
}

# WAN 下发的上游 DNS（排除本机回环与 fake-IP 地址）
wan_dns_servers() {
    [ -s /tmp/resolv.conf.d/resolv.conf.auto ] || return 0
    awk '/^nameserver /{print $2}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null \
        | grep -vE '^(127\.|::1|0\.0\.0\.0|fe80|198\.18\.)' \
        | head -n 2 | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# 计算可用于 AdGuard Home 的外部上游 DNS，避免指向自身或已停止的服务。
# 优先 Clash DNS，其次 WAN 下发的 DNS，最后才回退公共 DNS。
detect_upstream_dns() {
    if port_listening "$clash_dns_port"; then
        echo "127.0.0.1:$clash_dns_port"
        return
    fi

    _wan_dns="$(wan_dns_servers)"
    if [ -n "$_wan_dns" ]; then
        echo "$_wan_dns"
        return
    fi

    echo "223.5.5.5 119.29.29.29"
}

# “Clash 前置”模式使用的真实上游：AdGuard Home 位于 Clash 之后，
# 上游必须是真实 DNS，绝不能是 Clash（7874）或本机 53，否则会形成查询环。
detect_real_upstream_dns() {
    _wan_dns="$(wan_dns_servers)"
    if [ -n "$_wan_dns" ]; then
        echo "$_wan_dns"
        return
    fi

    echo "223.5.5.5 119.29.29.29"
}

# Clash 是否仍在劫持 53 端口（返回重定向目标端口）
# 兼容两种规则写法：redirect to :7874 和 dnat [ip] to 127.0.0.1:7874
openclash_hijack_port() {
    have_cmd nft || return 0

    _oc_line=$(nft list chain inet fw4 dstnat 2>/dev/null | grep 'Clash DNS Hijack' | head -n 1)
    [ -n "$_oc_line" ] || return 0

    _oc_port=$(echo "$_oc_line" | sed -n 's/.*redirect to :\([0-9][0-9]*\).*/\1/p')
    if [ -z "$_oc_port" ]; then
        _oc_port=$(echo "$_oc_line" | sed -n 's/.*dnat.*:\([0-9][0-9]*\).*/\1/p')
    fi
    echo "$_oc_port"
}

# DNSMasq 实际读取的 conf-dir：优先从 OpenWrt 生成的临时配置解析，
# 回退到 /tmp/dnsmasq.d（与 Clash 使用的位置一致）。
dnsmasq_confdir() {
    _dcd=""
    for _dcf in /tmp/etc/dnsmasq.conf.*; do
        [ -f "$_dcf" ] || continue
        _dcv=$(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' "$_dcf" 2>/dev/null | head -n 1)
        if [ -n "$_dcv" ]; then
            _dcd="$_dcv"
            break
        fi
    done
    [ -n "$_dcd" ] || _dcd="/tmp/dnsmasq.d"
    echo "$_dcd"
}

# dnsmasq 2.86 起支持 server=/#/，旧版本只能用 server=/./ 表示所有域名
dnsmasq_hash_rule_supported() {
    _dvv=$(dnsmasq --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -n 1)
    [ -n "$_dvv" ] || return 0

    _dvmaj=${_dvv%%.*}
    _dvrest=${_dvv#*.}
    _dvmin=${_dvrest%%.*}
    [ "$_dvmaj" -ge 3 ] 2>/dev/null && return 0
    if [ "$_dvmaj" -eq 2 ] 2>/dev/null && [ "$_dvmin" -ge 86 ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# Clash 串联模式：在 DNSMasq 的 conf-dir 写入带标记的默认转发规则，
# 让 DNSMasq 把域名查询交给 AdGuard Home。
# 不再写 /etc/dnsmasq.conf：OpenWrt 上该文件不会被 DNSMasq 读取。
OC_CONF="/etc/dnsmasq.conf"
OC_FILE="adguardhome-lite.conf"
OC_BEGIN="# BEGIN adguardhome-lite-openclash"
OC_END="# END adguardhome-lite-openclash"

oc_conf_path() {
    echo "$(dnsmasq_confdir)/$OC_FILE"
}

openclash_forward_present() {
    _ocp="$(oc_conf_path)"
    [ -f "$_ocp" ] && grep -qF "$OC_BEGIN" "$_ocp" && return 0
    [ -f "$OC_CONF" ] && grep -qF "$OC_BEGIN" "$OC_CONF" && return 0
    return 1
}

openclash_forward_del() {
    _ocp="$(oc_conf_path)"
    [ -f "$_ocp" ] && rm -f "$_ocp"

    [ -f "$OC_CONF" ] || return 0
    grep -qF "$OC_BEGIN" "$OC_CONF" || return 0

    awk -v b="$OC_BEGIN" -v e="$OC_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip != 1 { print }
    ' "$OC_CONF" > "$OC_CONF.tmp.$$" && mv -f "$OC_CONF.tmp.$$" "$OC_CONF"
}

# 读取 YAML 中某个两空格缩进的列表，返回空格分隔的一行
yaml_get_list() {
    _file="$1"
    _key="$2"
    [ -f "$_file" ] || return 1

    awk -v k="$_key" '
        $0 ~ "^  " k ":" {
            line = $0
            sub("^  " k ":[[:space:]]*", "", line)
            sub(/[[:space:]]+#.*$/, "", line)

            # 行内写法：bootstrap_dns: [1.1.1.1, 8.8.8.8] / []
            if (line ~ /^\[/) {
                sub(/^\[/, "", line)
                sub(/\][[:space:]]*$/, "", line)
                if (line !~ /^[[:space:]]*$/) {
                    n = split(line, parts, ",")
                    for (i = 1; i <= n; i++) {
                        v = parts[i]
                        gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", v)
                        if (v != "") print v
                    }
                }
                exit
            }

            # 单行标量写法
            if (line != "") {
                gsub(/"/, "", line)
                print line
                exit
            }

            inlist = 1
            next
        }
        inlist == 1 && /^    - / { sub(/^    - /, ""); print; next }
        { if (inlist == 1) inlist = 0 }
    ' "$_file" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# 修改 YAML 中某个两空格缩进的标量，例如 dns.port、http.address
yaml_set_scalar() {
    _file="$1"
    _key="$2"
    _value="$3"
    [ -f "$_file" ] || return 1

    awk -v k="$_key" -v v="$_value" '
        $0 ~ "^  " k ":" { print "  " k ": " v; next }
        { print }
    ' "$_file" > "$_file.tmp.$$" && mv -f "$_file.tmp.$$" "$_file"
}

# 替换 YAML 中某个两空格缩进的列表（列表项为四空格 "- "）
yaml_set_list() {
    _file="$1"
    _key="$2"
    _values="$3"
    [ -f "$_file" ] || return 1

    awk -v k="$_key" -v vals="$_values" '
        BEGIN { n = split(vals, a, " ") }
        $0 ~ "^  " k ":" {
            if (n == 0 || vals == "") {
                print "  " k ": []"
                skip = 1
                next
            }
            print "  " k ":"
            for (i = 1; i <= n; i++) print "    - " a[i]
            skip = 1
            next
        }
        skip == 1 && /^    - / { next }
        { skip = 0; print }
    ' "$_file" > "$_file.tmp.$$" && mv -f "$_file.tmp.$$" "$_file"
}

# 修正 ratelimit_whitelist 格式：AdGuard Home 只接受单个 IP，不接受 CIDR。
# 旧版本曾写入 127.0.0.0/8、::1/128，会导致 --check-config 失败、服务无法启动。
yaml_fix_ratelimit_whitelist() {
    _file="$1"
    [ -f "$_file" ] || return 1
    grep -q 'ratelimit_whitelist' "$_file" 2>/dev/null || return 0

    awk '
        /^  ratelimit_whitelist:/ { inblk = 1; print; next }
        inblk && /^    - / {
            gsub(/127\.0\.0\.0\/8/, "127.0.0.1")
            gsub(/::1\/128/, "::1")
            print
            next
        }
        inblk { inblk = 0 }
        { print }
    ' "$_file" > "$_file.tmp.$$" && mv -f "$_file.tmp.$$" "$_file"
}

# 读取 YAML 中某个两空格缩进的标量
yaml_get_scalar() {
    _file="$1"
    _key="$2"
    [ -f "$_file" ] || return 1

    awk -v k="$_key" '
        $0 ~ "^  " k ":" {
            line = $0
            sub("^  " k ":[[:space:]]*", "", line)
            sub(/[[:space:]]+#.*$/, "", line)
            gsub(/"/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
    ' "$_file"
}

# 读取 YAML 中顶格（0 缩进）的标量，例如 http_proxy
yaml_get_root_scalar() {
    _file="$1"
    _key="$2"
    [ -f "$_file" ] || return 1

    awk -v k="$_key" '
        $0 ~ "^" k ":" {
            line = $0
            sub("^" k ":[[:space:]]*", "", line)
            gsub(/"/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
    ' "$_file"
}

# 修改 YAML 中顶格（0 缩进）的标量，例如 http_proxy
yaml_set_root_scalar() {
    _file="$1"
    _key="$2"
    _value="$3"
    [ -f "$_file" ] || return 1

    awk -v k="$_key" -v v="$_value" '
        $0 ~ "^" k ":" { print k ": \"" v "\""; next }
        { print }
    ' "$_file" > "$_file.tmp.$$" && mv -f "$_file.tmp.$$" "$_file"
}

# 读取 YAML 缓存配置，输出 enabled|size_mb|ttl_min|ttl_max|optimistic。
# YAML 缺少 cache_enabled 等字段时返回非 0，避免把空配置误判成外部修改。
cache_yaml_signature() {
    _cs_file="$1"
    [ -s "$_cs_file" ] || return 1

    _cs_enabled="$(yaml_get_scalar "$_cs_file" "cache_enabled" 2>/dev/null)"
    case "$_cs_enabled" in
        true) _cs_enabled=1 ;;
        false) _cs_enabled=0 ;;
        *) return 1 ;;
    esac

    _cs_size=16
    _cs_raw="$(yaml_get_scalar "$_cs_file" "cache_size" 2>/dev/null)"
    case "$_cs_raw" in
        ''|*[!0-9]*) ;;
        *)
            _cs_mb=$(( _cs_raw / 1048576 ))
            [ "$_cs_mb" -ge 1 ] 2>/dev/null && _cs_size="$_cs_mb"
            ;;
    esac

    _cs_min=0
    _cs_raw="$(yaml_get_scalar "$_cs_file" "cache_ttl_min" 2>/dev/null)"
    case "$_cs_raw" in ''|*[!0-9]*) ;; *) _cs_min="$_cs_raw" ;; esac

    _cs_max=0
    _cs_raw="$(yaml_get_scalar "$_cs_file" "cache_ttl_max" 2>/dev/null)"
    case "$_cs_raw" in ''|*[!0-9]*) ;; *) _cs_max="$_cs_raw" ;; esac

    _cs_opt=0
    _cs_raw="$(yaml_get_scalar "$_cs_file" "cache_optimistic" 2>/dev/null)"
    case "$_cs_raw" in
        true) _cs_opt=1 ;;
        false) _cs_opt=0 ;;
    esac

    echo "$_cs_enabled|$_cs_size|$_cs_min|$_cs_max|$_cs_opt"
}

# 老版本升级：UCI 没有缓存选项时，沿用当前 YAML 状态，避免覆盖用户选择。
migrate_cache_conf() {
    [ -n "$cache_enabled" ] && return 0

    cache_enabled=1
    cache_size_mb=16
    cache_ttl_min=0
    cache_ttl_max=0
    cache_optimistic=0

    if [ -s "$configpath" ]; then
        _mc_raw="$(yaml_get_scalar "$configpath" "cache_enabled" 2>/dev/null)"
        case "$_mc_raw" in
            true) cache_enabled=1 ;;
            false) cache_enabled=0 ;;
        esac

        _mc_raw="$(yaml_get_scalar "$configpath" "cache_size" 2>/dev/null)"
        case "$_mc_raw" in
            ''|*[!0-9]*) ;;
            *)
                _mc_mb=$(( _mc_raw / 1048576 ))
                [ "$_mc_mb" -ge 1 ] 2>/dev/null && cache_size_mb="$_mc_mb"
                ;;
        esac

        _mc_raw="$(yaml_get_scalar "$configpath" "cache_ttl_min" 2>/dev/null)"
        case "$_mc_raw" in
            ''|*[!0-9]*) ;;
            *) cache_ttl_min="$_mc_raw" ;;
        esac

        _mc_raw="$(yaml_get_scalar "$configpath" "cache_ttl_max" 2>/dev/null)"
        case "$_mc_raw" in
            ''|*[!0-9]*) ;;
            *) cache_ttl_max="$_mc_raw" ;;
        esac

        _mc_raw="$(yaml_get_scalar "$configpath" "cache_optimistic" 2>/dev/null)"
        case "$_mc_raw" in
            true) cache_optimistic=1 ;;
            false) cache_optimistic=0 ;;
        esac
    fi

    uci -q set "$CONF.main.cache_enabled=$cache_enabled"
    uci -q set "$CONF.main.cache_size_mb=$cache_size_mb"
    uci -q set "$CONF.main.cache_ttl_min=$cache_ttl_min"
    uci -q set "$CONF.main.cache_ttl_max=$cache_ttl_max"
    uci -q set "$CONF.main.cache_optimistic=$cache_optimistic"
    uci -q commit "$CONF" 2>/dev/null

    if [ "$cache_enabled" = "1" ]; then
        log_msg "已迁移 DNS 缓存配置：开启（${cache_size_mb}MB，TTL ${cache_ttl_min}-${cache_ttl_max}，乐观缓存 ${cache_optimistic}）。"
    else
        log_msg "已迁移 DNS 缓存配置：关闭。"
    fi
}

###
# 过滤列表下载走 Clash 的 HTTP 代理：国内直连 GitHub 常被重置，
# 交给 Clash 代理后 AGH 才能正常更新规则。
###
detect_http_proxy() {
    _hp="$(uci -q get openclash.config.http_port 2>/dev/null)"
    case "$_hp" in
        ''|*[!0-9]*) _hp="" ;;
    esac
    if [ -n "$_hp" ] && port_listening "$_hp"; then
        echo "http://127.0.0.1:$_hp"
        return
    fi
    echo ""
}

###
# Clash 前置（clashfirst）模式：让 Clash 的 DNS 上游只指向 AdGuard Home
###

clashfirst_disable_upstream() {
    _nds_sid="$1"
    config_get _nds_grp "$_nds_sid" group ""
    # nameserver 和 fallback 都会给 Clash 提供绕过 AdGuard Home 的解析路径
    case "$_nds_grp" in
        nameserver|fallback) ;;
        *) return 0 ;;
    esac
    config_get_bool _nds_en "$_nds_sid" enabled 1
    [ "$_nds_en" = "0" ] && return 0

    uci -q set "openclash.$_nds_sid.enabled=0"
    _oc_disabled="$_oc_disabled $_nds_sid"
}

# 关闭 Clash 原有 nameserver 组，仅保留指向 AdGuard Home 的上游。
# 返回值：0 成功；2 未安装 Clash；3 Clash 版本不支持自定义 DNS。
# 注：UCI 键仍沿用 oc_* 前缀，改名会让旧设备上已保存的 Clash 上游记录失去引用，
# 导致 restore 删不掉那条 dns_servers，从而形成查询环，故键名保持不变。
clashfirst_clash_apply() {
    uci -q get openclash.config >/dev/null 2>&1 || return 2
    uci -q get openclash.config.enable_custom_dns >/dev/null 2>&1 || return 3

    # 清理上一次可能残留的设置（不重启 Clash）
    clashfirst_clash_restore >/dev/null 2>&1

    _old_cd=$(uci -q get openclash.config.enable_custom_dns)
    [ -n "$_old_cd" ] || _old_cd="0"
    _old_wan=$(uci -q get openclash.config.append_wan_dns)
    [ -n "$_old_wan" ] || _old_wan="0"

    _oc_disabled=""
    config_load openclash 2>/dev/null
    config_foreach clashfirst_disable_upstream dns_servers

    _sid=$(uci add openclash dns_servers) || return 1
    # 注意不要写成 foo='bar'，否则引号会进入 UCI 值，Clash 读不到合法值
    uci -q set "openclash.$_sid.group=nameserver"
    uci -q set "openclash.$_sid.ip=127.0.0.1"
    uci -q set "openclash.$_sid.port=$dnsport"
    uci -q set "openclash.$_sid.type=udp"
    uci -q set "openclash.$_sid.enabled=1"
    uci -q set openclash.config.enable_custom_dns=1
    # 不再追加 WAN DNS，否则 Clash 会同时查询运营商 DNS，部分查询绕过过滤
    uci -q set openclash.config.append_wan_dns=0

    uci -q set "$CONF.main.oc_agh_sid=$_sid"
    uci -q set "$CONF.main.oc_old_custom_dns=$_old_cd"
    uci -q set "$CONF.main.oc_old_append_wan_dns=$_old_wan"
    uci -q set "$CONF.main.oc_disabled_sids=$_oc_disabled"

    uci -q commit openclash 2>/dev/null
    uci -q commit "$CONF" 2>/dev/null
    return 0
}

# 恢复 Clash 的原有 DNS 上游设置
clashfirst_clash_restore() {
    _r_sid=$(uci -q get "$CONF.main.oc_agh_sid")
    _r_sids=$(uci -q get "$CONF.main.oc_disabled_sids")
    _r_old=$(uci -q get "$CONF.main.oc_old_custom_dns")
    _r_wan=$(uci -q get "$CONF.main.oc_old_append_wan_dns")

    [ -n "$_r_sid" ] || [ -n "$_r_sids" ] || [ -n "$_r_old" ] || [ -n "$_r_wan" ] || return 0

    [ -n "$_r_sid" ] && uci -q delete "openclash.$_r_sid"
    for _r_s in $_r_sids; do
        uci -q set "openclash.$_r_s.enabled=1"
    done
    if [ -n "$_r_old" ]; then
        uci -q set "openclash.config.enable_custom_dns=$_r_old"
    fi
    if [ -n "$_r_wan" ]; then
        uci -q set "openclash.config.append_wan_dns=$_r_wan"
    fi

    uci -q delete "$CONF.main.oc_agh_sid"
    uci -q delete "$CONF.main.oc_disabled_sids"
    uci -q delete "$CONF.main.oc_old_custom_dns"
    uci -q delete "$CONF.main.oc_old_append_wan_dns"

    uci -q commit openclash 2>/dev/null
    uci -q commit "$CONF" 2>/dev/null
    return 0
}

# 让 Clash 重新生成 DNS 配置使自定义上游生效；仅在 Clash 已运行时重启。
clashfirst_clash_refresh() {
    # Clash 的“快速启动”会在配置未变时跳过 yml_change.sh，
    # 导致自定义上游不生效；无论 Clash 是否在运行，都要先让缓存失效。
    rm -f /tmp/openclash.change /tmp/openclash_tpl_cache

    pidof clash >/dev/null 2>&1 || return 0
    [ -x /etc/init.d/openclash ] || return 0

    log_msg "正在重启 Clash 以应用自定义上游 DNS..."
    /etc/init.d/openclash restart >/dev/null 2>&1
    return 0
}
