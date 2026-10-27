#!/bin/sh

LOG_FILE='/tmp/passwall-speedtest.log'
PERSIST_LOG='/etc/config/passwall-speedtest.log'
RESULT_DIR='/tmp/passwall-speedtest'
IP_FILE="$RESULT_DIR/result.csv"
# ── 单实例运行锁与会话私有状态目录 ───────────────────────────
# 触发来源(cron 表达式写成 `* 19 * * 4` 时一小时能触发几十次、UI 连点、SSH 手敲)可能同时
# 拉起多个整跑进程。它们共用同一批 passwall worker 节点和同一份中间状态文件，会互相改写
# address、互删完成标记(如 result.csv.tmp.*.done)、互相触发「首完成即停」，最后各自拿到
# 残缺结果；失败路径还会整份还原 passwall 快照，把别人刚写回的 IP 一并抹掉。
# 故：① 整跑入口抢一把单实例锁；② 全部中间状态下沉到按主进程 PID 命名的会话目录 RUN_DIR。
# 共享产物(result.csv / result.csv.N / history.csv / 日志)是给 UI 看的，仍留在原路径。
RUN_LOCK_DIR="$RESULT_DIR/.run.lock"
RUN_PID_FILE="$RESULT_DIR/current_run"
RUN_DIR=""
IPV4_TXT='/usr/share/passwall-speedtest/ip.txt'
IPV6_TXT='/usr/share/passwall-speedtest/ipv6.txt'

SCRIPT_DIR='/usr/bin/passwall-speedtest'

# 迭代模式：单节点候选收敛到 ≤ 此数量即保存结果提前结束（继续复测收益小）
ITERATE_KEEP_MAX=3

# 下载实测快速死亡：起测后 DL_FAST_FAIL_TIME 秒内平均下载不足 DL_FAST_FAIL_BYTES
# 即中止并判失败（curl --speed-limit/--speed-time），别让慢/死 IP 白等满单 IP 时限。
DL_FAST_FAIL_BYTES=1048576
DL_FAST_FAIL_TIME=5
DL_FAST_FAIL_BPS=$((DL_FAST_FAIL_BYTES / DL_FAST_FAIL_TIME))

# 复测模式（retest）：候选只取当前 result.csv + 各节点当前 address，不重新下载在线列表
RETEST_FROM_RESULT=0

function get_global_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get passwall-speedtest.global.$1`' 2>/dev/null
        shift
    done
}

function get_servers_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get passwall-speedtest.servers.$1`' 2>/dev/null
        shift
    done
}

echolog() {
    local d="$(date "+%Y-%m-%d %H:%M:%S")"
    echo -e "$d: $*"
    echo -e "$d: $*" >>$LOG_FILE
}

# 抢整跑单实例锁。成功返回 0 并建好会话目录 RUN_DIR；已有整跑在跑则返回 1（调用方跳过本次）。
# 会话目录名用主进程 PID：worker 都是 fork 出来的子 shell，$$ 仍是主进程 PID
# （NODE_TEST_FLAG_BASE 也依赖这一点），故整个会话内取值稳定。
run_lock_acquire() {
    local _pid _alive _started _now _cap _tries=0
    mkdir -p "$RESULT_DIR" 2>/dev/null || { echolog "无法创建 $RESULT_DIR，本次跳过"; return 1; }
    while :; do
        if mkdir "$RUN_LOCK_DIR" 2>/dev/null; then
            echo "$$" > "$RUN_LOCK_DIR/pid"
            date +%s > "$RUN_LOCK_DIR/started"
            RUN_DIR="$RESULT_DIR/run.$$"
            rm -rf "$RUN_DIR" 2>/dev/null
            if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
                echolog "创建会话目录 $RUN_DIR 失败，本次跳过"
                rm -rf "$RUN_LOCK_DIR"; RUN_DIR=""
                return 1
            fi
            echo "$$" > "$RUN_PID_FILE"
            reap_stale_run_dirs
            return 0
        fi
        # 锁已存在：持有者还活着就谦让；已被 kill -9 / 断电 / 崩溃带走时接管。
        # cmdline 比对既排除「PID 被无关进程复用」的假存活，也让未被收尸的僵尸
        # (kill -9 后父进程还没 wait) 被正确判为已死——僵尸的 cmdline 是空的。
        # 前提：脚本按本名调用（cron/SSH/UI 都是全路径调用），不要改名或换成别名。
        _pid="$(cat "$RUN_LOCK_DIR/pid" 2>/dev/null)"
        _alive=0
        if [ -n "$_pid" ] && [ -d "/proc/$_pid" ] && \
           grep -q 'passwall-speedtest\.sh' "/proc/$_pid/cmdline" 2>/dev/null; then
            _alive=1
        fi
        if [ "$_alive" = "1" ]; then
            # 兜底：锁龄超过该配置允许的最长运行时间仍不释放 → 视为僵死会话接管。
            # 迭代模式有硬上限 iterate_minutes；普通模式无硬上限，给 12 小时。
            _started="$(cat "$RUN_LOCK_DIR/started" 2>/dev/null)"
            case "$_started" in ''|*[!0-9]*) _started=0 ;; esac
            _now="$(date +%s)"
            if [ "${iterate_enabled:-0}" = "1" ] && [ "${iterate_minutes:-0}" -ge 1 ] 2>/dev/null; then
                _cap=$(( iterate_minutes * 60 + 1800 ))
            else
                _cap=43200
            fi
            if [ "$_started" -gt 0 ] && [ $((_now - _started)) -gt "$_cap" ]; then
                echolog "运行锁已持有 $((_now - _started))s 超过上限 ${_cap}s（PID ${_pid} 疑似僵死），接管"
            else
                return 1
            fi
        else
            echolog "运行锁为残留（PID ${_pid:-未知} 已不存在），接管"
        fi
        rm -rf "$RUN_LOCK_DIR"
        _tries=$((_tries + 1))
        [ "$_tries" -lt 3 ] || { echolog "运行锁接管失败，本次跳过"; return 1; }
    done
}

# 释放运行锁并删掉本会话目录。非持有者调用是 no-op（避免误删接管者的锁）。
run_lock_release() {
    [ "$(cat "$RUN_LOCK_DIR/pid" 2>/dev/null)" = "$$" ] || { RUN_DIR=""; return 0; }
    [ -n "$RUN_DIR" ] && rm -rf "$RUN_DIR" 2>/dev/null
    rm -f "$RUN_PID_FILE" 2>/dev/null
    rm -rf "$RUN_LOCK_DIR" 2>/dev/null
    RUN_DIR=""
    return 0
}

# 清掉上次异常退出留下的会话目录（进程已不在），防 /tmp 内存盘被 IP 列表/结果文件撑满。
reap_stale_run_dirs() {
    local _d _p
    for _d in "$RESULT_DIR"/run.*; do
        [ -d "$_d" ] || continue
        _p="${_d##*/run.}"
        [ "$_p" = "$$" ] && continue
        [ -d "/proc/$_p" ] && continue
        rm -rf "$_d" 2>/dev/null
    done
    return 0
}

function read_config(){
    get_global_config "enabled" "custom_cron_enabled" "custom_cron" "tl" "tll" "tlr" "ip_source" "custom_ip_file" "custom_allip" "ip_online_url" "ip_online_regions" "node_test_node" "stable_node" "node_test_url" "node_test_count" "node_test_timeout" "node_test_probes" "node_test_threads" "download_test_enabled" "download_test_count" "download_test_url" "download_test_time" "iterate_enabled" "iterate_minutes"
    get_servers_config "ssr_services" "ssr_enabled" "passwall_enabled" "passwall_services" "passwall2_enabled" "passwall2_services" "bypass_enabled" "bypass_services" "vssr_enabled" "vssr_services" "DNS_enabled" "AliDNS_ip_count" "HOST_enabled" "MosDNS_enabled" "MosDNS_ip_count" "openclash_restart" "AstraDNS_enabled" "AstraDNS_config" "AstraDNS_bin"
    # 五个 CM 备选 IP 列表（ip_list 命名段 list1..list5）
    local _n
    for _n in 1 2 3 4 5; do
        eval "list${_n}_enabled=\$(uci get passwall-speedtest.list${_n}.enabled 2>/dev/null)"
        eval "list${_n}_name=\$(uci get passwall-speedtest.list${_n}.name 2>/dev/null)"
        eval "list${_n}_regions=\$(uci get passwall-speedtest.list${_n}.regions 2>/dev/null)"
        eval "list${_n}_port=\$(uci get passwall-speedtest.list${_n}.port 2>/dev/null)"
    done
}

# 迁移：旧配置只有全局 ip_online_regions、无 ip_list 段时，把它写入 list1 作为默认列表。
# 仅在 ip_source==online 且 list1_regions 为空且 ip_online_regions 非空时执行一次。
function migrate_ip_online_regions(){
    [ "${ip_source:-}" = "online" ] || return 0
    [ -n "${ip_online_regions:-}" ] || return 0
    [ -z "${list1_regions:-}" ] || return 0
    uci set passwall-speedtest.list1.enabled='1'
    uci set passwall-speedtest.list1.regions="${ip_online_regions}"
    uci commit passwall-speedtest
    list1_enabled=1
    list1_regions="${ip_online_regions}"
    echolog "迁移：将旧 ip_online_regions (${ip_online_regions}) 写入 list1 作为默认 CM IP 列表"
}

# 读取 node_ip 段（匿名段）→ 建 nodeid→ip_list 映射，存入 shell 变量 node_ip_list_<nodeid>。
# 用 `uci show` 解析，避免 config_load 扰动 passwall 自身的配置加载状态（config_n_get 依赖它）。
# node id 形如 cfg0a1b2c，是合法 shell 变量后缀。
NODE_IP_MAP_LOADED=0
NODE_IP_WORKERS=""
function read_node_ip_map(){
    [ "$NODE_IP_MAP_LOADED" = "1" ] && return 0
    NODE_IP_WORKERS=""
    local line _node=""
    while IFS= read -r line; do
        # 形如 passwall-speedtest.@node_ip[N].node='cfg0a1b2c' / .ip_list='list2'
        case "$line" in
            *".node="*)
                _node="${line#*.node=}"
                _node="${_node#\'}"; _node="${_node%\'}"
                # 每行 node 字段 = 一个待测 worker 节点（统一表的 worker 来源）
                [ -n "$_node" ] && NODE_IP_WORKERS="$NODE_IP_WORKERS $_node"
                ;;
            *".ip_list="*)
                local _list="${line#*.ip_list=}"
                _list="${_list#\'}"; _list="${_list%\'}"
                if [ -n "$_node" ]; then
                    eval "node_ip_list_${_node}=\${_list:-}"
                fi
                _node=""
                ;;
        esac
    done <<EOF
$(uci show passwall-speedtest 2>/dev/null | grep '@node_ip\[')
EOF
    NODE_IP_WORKERS="${NODE_IP_WORKERS# }"
    NODE_IP_MAP_LOADED=1
}

# 计算默认列表 = 数字序第一个 enabled=1 的 ip_list（list1..list5）。无启用则空。
# 必须在主 shell（非 command substitution）里调一次，结果存 DEFAULT_IP_LIST 供 resolve_node_list 复用。
DEFAULT_IP_LIST=""
function compute_default_ip_list(){
    [ -n "$DEFAULT_IP_LIST" ] && return 0
    local _n _e
    for _n in 1 2 3 4 5; do
        eval "_e=\${list${_n}_enabled:-0}"
        if [ "$_e" = "1" ]; then DEFAULT_IP_LIST="list${_n}"; break; fi
    done
}

# 返回某 passwall worker 节点应使用的列表 id（list1..list5），或空（→ 调用方走全量 :443）。
# 优先 node_ip 段显式指派（且该列表 enabled=1）；否则回退 DEFAULT_IP_LIST。
# 本函数无副作用、无 echolog，可在 command substitution 内安全调用。
function resolve_node_list(){
    local nodeid="$1"
    local _v _e
    eval "_v=\${node_ip_list_${nodeid}:-}"
    if [ -n "$_v" ]; then
        eval "_e=\${list${_v#list}_enabled:-0}"
        [ "$_e" = "1" ] && { echo "$_v"; return 0; }
    fi
    echo "$DEFAULT_IP_LIST"
}

# 滚动归档上一次运行的日志，最多保留 5 份（/tmp 内存盘，重启即清，不写 flash）。
# .log.1 = 上一次运行，.log.5 = 最旧；本次运行写 .log 本体。SSH 查看：cat /tmp/passwall-speedtest.log.1
function rotate_log_files(){
    local i
    [ -f "$LOG_FILE" ] || return 0
    rm -f "${LOG_FILE}.5"
    for i in 4 3 2 1; do
        [ -f "${LOG_FILE}.$i" ] && mv -f "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
    done
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

# 日志超限滚动：单次长跑（迭代模式逐 IP 打进度行）会把 .log 撑到数 MB~数十 MB，
# 拖慢 LuCI 日志页首次加载。超 10MB 就滚动归档（echolog 按路径追加，rename 后自动写新文件）。
# 在 worker 每 IP 循环里调用（每次探测 5~10s 一回，wc -c 开销可忽略）。
function log_size_guard(){
    [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 10485760 ] && rotate_log_files && \
        echolog "日志已超 10MB，滚动归档到 .log.1"
    return 0
}

function rotate_result_files(){
    # 滚动保存result.csv文件，最多保存10个版本
    if [ -f "$IP_FILE" ]; then
        # 删除最旧的文件 (.9)
        [ -f "${IP_FILE}.9" ] && rm -f "${IP_FILE}.9"

        # 从.8到.1逐级重命名
        for i in 8 7 6 5 4 3 2 1; do
            if [ -f "${IP_FILE}.$i" ]; then
                mv "${IP_FILE}.$i" "${IP_FILE}.$((i+1))"
            fi
        done

        # 将当前的result.csv重命名为result.csv.1
        mv "$IP_FILE" "${IP_FILE}.1"
    fi
}

function first_result_ip(){
    sed -n '2,$p' "$1" 2>/dev/null | grep -v '^#' | awk -F, 'NF >= 7 && $1 != "" { print $1; exit }'
}

# ── 复测现有最优 IP（retest 入口）─────────────────────────────
# 不重新下载在线列表：候选 = 各节点当前 address + 当前 result.csv 中该节点的行。
# 用于对「已经优选出来的一小撮 IP」做一轮延迟 + 下载实测，快速确认/重排，
# 不必再拉 1~2 万条 CM 源。每个待测节点的候选写入 RUN_DIR/retest_ips_<node>.txt。
build_retest_list_one() {
    # 注意：不能写成 local nodeid="$1" out="...${nodeid}..." —— shell 会先展开整条 local
    # 命令的所有 RHS 再赋值，${nodeid} 此时还未定义（set -u 下直接报 unbound variable）。
    local nodeid="$1" maxn="$2"
    local out="${RUN_DIR}/retest_ips_${nodeid}.txt"
    local remarks addr tmp="${out}.tmp"
    remarks=$(uci -q get "passwall.${nodeid}.remarks" 2>/dev/null)
    remarks="${remarks//,/ }"
    addr=$(uci -q get "passwall.${nodeid}.address" 2>/dev/null)
    : > "$tmp" 2>/dev/null || return 1
    # 当前已应用的地址通常就是上次的最优选，放在最前面一起复测；非 IP（域名等）跳过
    case "$addr" in
        ''|*[!0-9a-fA-F:.]*) ;;
        *) echo "$addr" >> "$tmp" ;;
    esac
    if [ -f "$IP_FILE" ] && [ -n "$remarks" ]; then
        sed -n '2,$p' "$IP_FILE" 2>/dev/null | grep -av '^#' | \
            awk -F, -v n="$remarks" 'NF>=8 && $1!="" && $8==n {print $1}' >> "$tmp"
    fi
    awk '!seen[$0]++' "$tmp" | head -n "$maxn" > "$out"
    rm -f "$tmp"
    [ -s "$out" ]
}

# 为所有可能的待测节点建复测候选文件。返回 0 = 至少一个节点有候选。
# 节点来源：node_ip 段的 worker + 旧 passwall_services + 单节点回退 node_test_node。
build_retest_ip_lists() {
    local maxn="$1" _w _seen="" _any=0
    for _w in ${NODE_IP_WORKERS:-} ${passwall_services:-} ${node_test_node:-}; do
        [ -n "$_w" ] || continue
        case " $_seen " in *" $_w "*) continue ;; esac
        _seen="$_seen $_w"
        build_retest_list_one "$_w" "$maxn" && _any=1
    done
    [ "$_any" = "1" ]
}

# 持久历史：把每次合并的「各节点最优」追加到 /etc/passwall-speedtest/history.csv。
# /tmp 下的 result.csv.* 是内存盘（重启即清）且仅 10 份，图表的长期历史依赖此文件。
# 格式与 result.csv 兼容：每块以 "# Speed test time: ..." 开头，其后为该次各节点最优行
# （全局延迟升序中每节点首次出现的行），每次 ≤ 待测节点数行。行数超限尾部修剪。
HISTORY_DIR=/etc/passwall-speedtest
HISTORY_MAX_LINES=5000
function append_persistent_history(){
    local mfile="$1"
    [ -f "$mfile" ] || return 0
    if mkdir -p "$HISTORY_DIR" 2>/dev/null; then
        {
            grep -a '^# Speed test time:' "$mfile" | head -n1
            sed -n '2,$p' "$mfile" | grep -av '^#' | awk -F, 'NF>=8 && $1!="" && $8!="" && !seen[$8]++'
        } >> "$HISTORY_DIR/history.csv"
        if [ "$(wc -l < "$HISTORY_DIR/history.csv")" -gt "$HISTORY_MAX_LINES" ]; then
            tail -n "$HISTORY_MAX_LINES" "$HISTORY_DIR/history.csv" \
                > "$HISTORY_DIR/history.csv.new" && mv -f "$HISTORY_DIR/history.csv.new" "$HISTORY_DIR/history.csv"
        fi
        echolog "已归档本次各节点最优到 $HISTORY_DIR/history.csv"
    else
        echolog "警告：$HISTORY_DIR 不可写，本次结果未持久归档"
    fi
}

# 排序结果数据行，表头保留在首行。
# 默认排序：下载速度（第 6 列）降序，速度相同或都为 0（未做下载实测）时按延迟升序 ——
#   有真实下载速度时“最快=吞吐最高”，没有时自然退化为“最快=延迟最低”。
# 第二参数 mode=latency 时仅按延迟升序排：用于下载实测之前挑出延迟最优的 N 个候选。
# 用 awk 自实现排序，不依赖 sort 的 -k/-n 浮点修饰符（某些 busybox sort 会忽略 -k 键
# 退化为整行字典序，导致选错最优 IP）。
function sort_result(){
    local file="$1"
    local mode="${2:-}"
    [ -s "$file" ] || return 0
    local header
    header=$(sed -n '1p' "$file" 2>/dev/null)
    {
        [ -n "$header" ] && echo "$header"
        sed '1d' "$file" 2>/dev/null | grep -v '^#' | \
        awk -F, -v mode="$mode" '
            { dl[NR]=($6=="")?0:($6+0); lat[NR]=($5=="")?0:($5+0); line[NR]=$0 }
            END {
                n=NR
                for (i=2;i<=n;i++) {
                    dk=dl[i]; lk=lat[i]; b=line[i]; j=i-1
                    while (j>=1 && cmp(dk,lk,dl[j],lat[j],mode)) { dl[j+1]=dl[j]; lat[j+1]=lat[j]; line[j+1]=line[j]; j-- }
                    dl[j+1]=dk; lat[j+1]=lk; line[j+1]=b
                }
                for (i=1;i<=n;i++) print line[i]
            }
            function cmp(dk,lk,dj,lj,mode) {
                if (mode=="latency") return (lk<lj)
                if (dk!=dj) return (dk>dj)
                return (lk<lj)
            }'
    } > "${file}.sorted" 2>/dev/null
    [ -s "${file}.sorted" ] && mv -f "${file}.sorted" "$file" || rm -f "${file}.sorted"
}

# 从在线 CM 源下载原始候选列表。源格式: IP:PORT#国家码 (如 1.2.3.4:443#JP)
# 输出两份：
#   ONLINE_RAW_FULL = 全部端口的 IP:PORT#CC 行（去重），供 build_ip_list_file 按各列表的
#                     端口 + 国家过滤（源里通常只有 CF 的 443/8443/2053/2083/2087/2096）；
#   ONLINE_RAW      = 仅 :443、去端口去重的纯 IP，用于 sanity 校验（行数下限、格式占比），
#                     同时作为「无启用列表」时的兜底候选（语义与引入端口过滤前一致）。
# 端口/国家白名单过滤由 build_ip_list_file 按各 ip_list 分别做（一次下载、多次过滤）。
# 带下载重试、空检查、行数下限、格式校验(参考仓库根 update_cf_ip.sh)。
# 注意:本函数会被 node_speed_test 直接调用(不在 $(...) 内),故 echolog 的 stdout 日志安全；
# 路径不通过 echo 返回,避免被 command substitution 捕获日志行污染变量。
ONLINE_RAW=""
ONLINE_RAW_FULL=""
function fetch_online_raw(){
    ONLINE_RAW=""; ONLINE_RAW_FULL=""
    local src="${ip_online_url:-https://zip.cm.edu.kg/all.txt}"
    local timeout=30
    local min_lines="${CF_MIN_LINES:-50}"
    local out_full="${RUN_DIR}/ip_online_full.txt"
    local out="${RUN_DIR}/ip_online_raw.txt"
    local tmp
    tmp="$(mktemp "${RUN_DIR}/ip_online.XXXXXX")" || { echolog "创建在线 IP 临时文件失败"; return 1; }

    echolog "下载在线 CM IP 列表(原始): $src"
    local ok=0 i
    for i in 1 2 3; do
        if curl -fsSL --max-time "$timeout" -o "$tmp" "$src" 2>/dev/null; then ok=1; break; fi
        [ "$i" = 3 ] || echolog "下载失败(第 $i 次),重试..."
    done
    [ "$ok" = 1 ] || { echolog "下载失败(重试 3 次): $src"; rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { echolog "下载内容为空"; rm -f "$tmp"; return 1; }

    # 全端口的 IP:PORT#CC 行（去重）→ ONLINE_RAW_FULL，供各列表按端口 + 国家过滤
    { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+#' "$tmp" | sort -u || true; } > "${out_full}.tmp"
    # 仅 :443 去端口去重的纯 IP → sanity 校验 + 无启用列表时的兜底（与端口过滤引入前一致）
    { grep ':443#' "${out_full}.tmp" | sed 's/:.*//' | sort -u || true; } > "${out}.tmp"

    local lines good
    lines=$(wc -l < "${out}.tmp" | tr -d ' ')
    if [ "$lines" -lt "$min_lines" ]; then
        echolog "在线 IP 行数过少 ($lines < $min_lines),疑似源异常,中止"
        rm -f "$tmp" "${out}.tmp" "${out_full}.tmp"; return 1
    fi
    good=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${out}.tmp" || true)
    if [ "$good" -lt $((lines * 9 / 10)) ]; then
        echolog "在线 IP 格式异常,合法行 $good/$lines 不足 90%,中止"
        rm -f "$tmp" "${out}.tmp" "${out_full}.tmp"; return 1
    fi

    mkdir -p "$RESULT_DIR"
    local full_lines
    full_lines=$(wc -l < "${out_full}.tmp" | tr -d ' ')
    mv -f "${out_full}.tmp" "$out_full"
    mv -f "${out}.tmp" "$out"
    rm -f "$tmp"
    ONLINE_RAW_FULL="$out_full"
    ONLINE_RAW="$out"
    echolog "在线 CM 原始列表就绪: 全端口 $full_lines 行 -> $out_full (其中 :443 纯 IP $lines 个 -> $out)"
    return 0
}

# 按 listN 的 端口 + regions 从 ONLINE_RAW_FULL 过滤出该列表的候选 IP，写入 RUN_DIR/ip_list_<N>.txt。
# 端口取 listN.port（默认 443，非法值同默认）；regions 为空 = 该端口全部国家。
# 不对过滤后文件再跑行数下限检查（窄国家/冷门端口可能合法 <50 行；
# worker 自己的 [ $total -gt 0 ] 会处理空列表）。
function build_ip_list_file(){
    local n="$1"
    local regions _port
    eval "regions=\${list${n}_regions:-}"
    eval "_port=\${list${n}_port:-}"
    case "$_port" in ''|*[!0-9]*) _port=443 ;; esac
    [ "$_port" -ge 1 ] 2>/dev/null && [ "$_port" -le 65535 ] 2>/dev/null || _port=443
    local out="${RUN_DIR}/ip_list_${n}.txt"
    local full="${ONLINE_RAW_FULL:-}"
    [ -n "$full" ] && [ -f "$full" ] || { echolog "在线原始(带国家码)文件缺失，无法过滤 list${n}"; return 1; }

    if [ -n "$regions" ]; then
        local re
        re=$(printf '%s' "$regions" | sed 's/[[:space:],]/|/g')
        { grep -E ":${_port}#($re)$" "$full" | sed 's/:.*//' | sort -u || true; } > "$out"
    else
        { grep -E ":${_port}#" "$full" | sed 's/:.*//' | sort -u || true; } > "$out"
    fi
    local lines
    lines=$(wc -l < "$out" | tr -d ' ')
    echolog "CM IP 列表 list${n} 就绪: ${lines} 行 (端口 ${_port}, regions: ${regions:-全部}) -> $out"
    return 0
}

function select_ip_file(){
    case "${ip_source:-}" in
        builtin_ipv4)
            echo "$IPV4_TXT"
            ;;
        builtin_ipv6)
            echo "$IPV6_TXT"
            ;;
        custom_file)
            if [ -n "${custom_ip_file:-}" ]; then
                echo "$custom_ip_file"
            else
                echolog "Custom IP list file is empty, fallback to built-in IPv4 list" >/dev/null
                echo "$IPV4_TXT"
            fi
            ;;
        "")
            echo "$IPV4_TXT"
            ;;
        *)
            echolog "Unknown IP list source: ${ip_source}, fallback to built-in IPv4 list" >/dev/null
            echo "$IPV4_TXT"
            ;;
    esac
}

function speed_test(){
    # 会话目录由运行锁建立（run_lock_acquire）；此处只做防御性检查，
    # 避免 RUN_DIR 为空时中间状态落到根目录下。
    [ -n "$RUN_DIR" ] || { echolog "内部错误：未持有运行锁就调用 speed_test，中止"; return 1; }
    # 日志只在整次测速入口处理一次：上次运行日志滚动归档为 .log.1~.log.5
    # （须在拿到运行锁之后再轮转：否则被跳过的本次会把在跑会话的日志轮转走）
    rotate_log_files
    # 走节点测速：把候选 CF IP 写进 passwall 节点 address，用 passwall app.sh run_socks
    # 拉本地 SOCKS，curl -I 取 time_pretransfer 测延迟，多 worker 并行、多 probe fail-fast。
    # 结果写回各 passwall worker 节点。
    local _rc=0
    # 候选来源（RETEST_FROM_RESULT）与调度方式（单轮 / 限时迭代）相互独立：
    # 复测同样可以按 iterate_enabled 进入各节点收敛循环，候选取自 retest_ips_<node>.txt。
    if [ "${iterate_enabled:-0}" = "1" ]; then
        case "${iterate_minutes:-}" in ''|*[!0-9]*) echolog "迭代测速时长无效，中止"; return 1 ;; esac
        [ "${iterate_minutes}" -ge 1 ] 2>/dev/null || { echolog "迭代测速时长须 ≥1 分钟，中止"; return 1; }
        [ "${RETEST_FROM_RESULT:-0}" = "1" ] && \
            echolog "════ 复测现有最优 IP（候选来自 result.csv / 节点当前 address，限时迭代，不重新下载在线列表）════"
        iterate_speed_test
        _rc=$?
    elif [ "${RETEST_FROM_RESULT:-0}" = "1" ]; then
        # 复测现有最优 IP：单轮延迟 + 下载实测
        echolog "════ 复测现有最优 IP（一轮延迟 + 下载实测，不重新下载在线列表）════"
        node_speed_test
        _rc=$?
    else
        node_speed_test
        _rc=$?
    fi
    # 持久日志：本次运行结束（无论成败）把 /tmp 日志覆盖到配置同目录，重启不丢
    cp -f "$LOG_FILE" "$PERSIST_LOG" 2>/dev/null
    return $_rc
}

# ── 时间盒迭代测速 ──────────────────────────────────────────
# 计时模式：不与普通模式共用「全局第 N 轮」编排——每个待测节点是一个独立收敛循环
# （见 node_iterate_worker）：第 1 遍测自己的初始候选，此后每遍只保留通过 IP 作为
# 下一遍候选，逐遍收敛出「最稳定基础上延迟最低」的集合，直到 NT_ITER_DEADLINE。
# 整个运行期间各节点中途不写 result.csv、不写回 passwall；计时结束（或 UI 停止）
# 后由 node_speed_test 的合并段一次性取各节点剩余通过集中的最优写回。
function iterate_speed_test(){
    ITERATE_MODE=1
    # RUN_DIR 是本次新建的会话目录，不会残留上次运行的停止标志/收敛候选列表
    NT_ITER_DEADLINE=$(( $(date +%s) + iterate_minutes * 60 ))
    local started=$(date +%s)
    echolog "════ 限时迭代测速开始（时长上限 ${iterate_minutes} 分钟，各待测节点独立收敛）════"
    node_speed_test
    local rc=$?
    echolog "════ 迭代测速结束（累计 $(( $(date +%s) - started ))s，各节点已写回其最终最优 IP）════"
    return $rc
}

# ── 走节点测速 ──────────────────────────────────────────────
# 把每个候选 CF IP 临时写进一个 passwall 节点的 address，再用 passwall 式
# URL 测速（拉起该节点本地 SOCKS → curl -I 探测 → 取 time_pretransfer 得毫秒）
# 按延迟选最优 IP，测完把最优 IP 留在该节点 address。只测延迟，不测下载带宽。
#
# 多线程：若第三方设置里选了 passwall 节点（passwall_services），这些真节点作并行 worker，
# 每个 worker 通过自己的链路测全部候选 IP、各写各的真最优；并发上限 node_test_threads。
# 不克隆节点（历史 temp-clone 方案因 clone 漏 SNI/Host 字段导致探测全失败已废弃）。
# uci set/commit 经 mkdir 原子锁串行化（多进程并发改 /tmp/.uci/passwall staging 会丢更新）。
NODE_TEST_FLAG_BASE=""
NODE_TEST_NODE=""
NODE_TEST_ORIG_ADDR=""
NODE_TEST_DONE=0
NT_LOCKDIR=""
NT_ORIG_FILE=""
NT_ORIG_NODE=""
NT_ORIG_TCP_NODE=""
NT_TCP_SWITCHED=0
NT_SNAP_FILE=""
NT_SNAPSHOT_REAPPLIED=0

# 测前快照 /etc/config/passwall，测后还原以抹掉 passwall 在测速中途新增的异常节点段
# （passwall 自身 restart/订阅刷新会偶发重建自带 socks 节点；脚本无法控制，靠整份快照兜底）。
nt_snapshot() {
    NT_SNAP_FILE="$(mktemp "${RUN_DIR}/passwall_snap.XXXXXX")" || { echolog "创建 passwall 快照失败"; NT_SNAP_FILE=""; return 1; }
    cp /etc/config/passwall "${NT_SNAP_FILE}" 2>/dev/null || { echolog "快照 /etc/config/passwall 失败"; rm -f "${NT_SNAP_FILE}"; NT_SNAP_FILE=""; return 1; }
}

# 整份还原快照（不重放任何 address）：用于失败/中断/结果为空路径，回滚本次测速所有改动。
nt_rollback() {
    [ -n "${NT_SNAP_FILE}" ] && [ -f "${NT_SNAP_FILE}" ] || return 0
    # 直写文件前先丢掉残留的 session delta（worker 被 kill 在 uci set 与 commit 之间会留下），
    # 否则之后任何 uci commit 都会把陈旧 address 刷回文件，破坏这份刚还原的快照
    uci -q revert passwall 2>/dev/null
    cp "${NT_SNAP_FILE}" /etc/config/passwall 2>/dev/null || echolog "警告：还原 passwall 快照失败"
    /etc/init.d/passwall restart >/dev/null 2>&1 || echolog "警告：passwall restart 失败，回滚可能未实时生效"
    echolog "已还原 passwall 配置到测速前快照（回滚本次测速所有改动，清理中途新增的异常节点）"
}

# 把各 worker 最优 IP 一次性写进 /etc/config/passwall：以测前快照为底，只替换/补写各 worker
# 段（config nodes/socks '<id>'）里的 option address，其余行原样输出（文件含凭据，格式绝不改），
# 先写同目录临时文件再 mv 覆盖 —— 同目录 rename 是原子的，所以任何时刻被 kill -9，配置要么是
# 测前快照、要么是完整结果，不会再留下「一部分节点写了新 IP、一部分还是旧 IP」的半成品
# （历史事故：停止时进程被杀在 `cp 快照` 与逐节点 `uci set` 之间，5 个节点只写进 2 个）。
# 直写文件绕过了 uci，故写前必须 uci revert 丢掉可能残留的 session delta：否则之后任何
# uci commit（我们自己的、或 passwall 自身的 uci -q commit passwall）都会把陈旧 delta
# 刷回文件，覆盖掉刚写的 IP。
# 参数: $1 = reapply 文件（每行 node<TAB>最优IP）
# 返回 0 = 已按预期落盘（含读回校验后的补写）；1 = 未写入（无快照兜底也失败 / 快照里已无该节点）
nt_apply_best_addresses() {
    local _rf="$1"
    local _mw _ip _tmp _edits _um _mismatch="" _count=0
    [ -s "$_rf" ] || return 1
    if [ -z "${NT_SNAP_FILE}" ] || [ ! -f "${NT_SNAP_FILE}" ]; then
        # 无快照兜底（正常不可达：两条调用路径都在 nt_snapshot 失败时中止）
        echolog "警告：无测前快照，退化为逐节点 uci set 写回"
        while read -r _mw _ip; do
            [ -n "$_mw" ] && [ -n "$_ip" ] || continue
            uci set passwall.${_mw}.address="${_ip}" 2>/dev/null
        done < "$_rf"
        uci commit passwall 2>/dev/null
        NT_SNAPSHOT_REAPPLIED=1
        return 0
    fi
    _edits="$(mktemp "${RUN_DIR}/node_test_edits.XXXXXX")" || { echolog "创建写回清单失败"; return 1; }
    # 守护：被测 worker 须仍在快照里（防订阅更新重排后把 address 写进空段）。此处按快照文本
    # 判断而非 uci -q get —— 残留 delta 会让 uci 读到与文件不一致的值。
    while read -r _mw _ip; do
        [ -n "$_mw" ] && [ -n "$_ip" ] || continue
        if grep -q "^config [A-Za-z0-9_]* '${_mw}'" "${NT_SNAP_FILE}" 2>/dev/null; then
            printf '%s\t%s\n' "$_mw" "$_ip" >> "$_edits"
            _count=$((_count + 1))
        else
            echolog "worker ${_mw} 在快照中已不存在，跳过写回"
        fi
    done < "$_rf"
    if [ "$_count" -eq 0 ]; then
        rm -f "$_edits"
        return 1
    fi
    uci -q revert passwall 2>/dev/null
    # 清掉上一次运行被强杀时可能留在 /etc/config 的临时文件（本次若也被强杀，留给下一次清）
    rm -f /etc/config/.passwall_speedtest.* 2>/dev/null
    _tmp="$(mktemp /etc/config/.passwall_speedtest.XXXXXX)" || { rm -f "$_edits"; echolog "创建配置临时文件失败"; return 1; }
    _um="$(umask)"; umask 077
    busybox awk 'BEGIN{q=sprintf("%c",39)}
        NR==FNR { ip[$1]=$2; next }
        /^config /{
            if (cur != "" && (cur in ip) && !done[cur]) print "\toption address " q ip[cur] q
            cur=$3; gsub(q,"",cur); done[cur]=0
            print; next
        }
        /^[ \t]*option address /{
            if (cur in ip) {
                match($0,/^[ \t]*/)
                print substr($0,1,RLENGTH) "option address " q ip[cur] q
                done[cur]=1; next
            }
        }
        { print }
        END { if (cur != "" && (cur in ip) && !done[cur]) print "\toption address " q ip[cur] q }' \
        "$_edits" "${NT_SNAP_FILE}" > "$_tmp"
    umask "$_um"
    chmod 600 "$_tmp" 2>/dev/null
    if [ ! -s "$_tmp" ] || ! mv -f "$_tmp" /etc/config/passwall 2>/dev/null; then
        rm -f "$_tmp" "$_edits"
        echolog "警告：写回 /etc/config/passwall 失败，配置保持测前状态"
        return 1
    fi
    NT_SNAPSHOT_REAPPLIED=1
    # 读回校验（在 restart 之前，确保运行时加载的就是校验过的配置）：有不一致的用 uci 补写一次
    while read -r _mw _ip; do
        [ -n "$_mw" ] && [ -n "$_ip" ] || continue
        [ "$(uci -q get passwall.${_mw}.address 2>/dev/null)" = "$_ip" ] || _mismatch="$_mismatch $_mw"
    done < "$_edits"
    if [ -n "$_mismatch" ]; then
        echolog "警告：worker${_mismatch} 的 address 未按预期落盘，改用 uci 逐节点补写"
        while read -r _mw _ip; do
            case " $_mismatch " in *" $_mw "*) uci set passwall.${_mw}.address="${_ip}" ;; esac
        done < "$_edits"
        uci commit passwall 2>/dev/null
    fi
    rm -f "$_edits"
    return 0
}

node_test_cleanup() {
    [ "${NODE_TEST_CLEANED:-0}" = "1" ] && return
    NODE_TEST_CLEANED=1
    # 杀本次拉起的临时 SOCKS 进程（按 flag 前缀通配，匹配单节点 + 各多线程 worker，排除脚本自身）
    if [ -n "${NODE_TEST_FLAG_BASE}" ]; then
        local pid_file
        for pid_file in /tmp/etc/passwall/*"${NODE_TEST_FLAG_BASE}"*_plugin.pid; do
            [ -s "$pid_file" ] && kill -9 "$(head -n1 "$pid_file")" >/dev/null 2>&1
        done
        busybox pgrep -af "${NODE_TEST_FLAG_BASE}" 2>/dev/null | awk '! /passwall-speedtest\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
        rm -rf /tmp/etc/passwall/*"${NODE_TEST_FLAG_BASE}"* 2>/dev/null
    fi
    rmdir "${NT_LOCKDIR}" 2>/dev/null
    # 成功路径已由 success 代码自行「还原快照 + 重放 address + restart」并置
    # NT_SNAPSHOT_REAPPLIED=1，此处跳过；失败/中断/结果为空路径走整份回滚（含 address 与全局节点 node/tcp_node）。
    if [ "${NT_SNAPSHOT_REAPPLIED:-0}" != "1" ]; then
        nt_rollback
    fi
    rm -f "${NT_SNAP_FILE}" "${NT_ORIG_FILE}" 2>/dev/null
    # 清理首完成即停用的完成标记、迭代轮次临时结果、轮次 meta 与停止标志（含中断退出残留）；
    # .nt_committing 是「提交阶段勿强杀」标记，正常路径收尾已删，这里兜底中途退出的残留
    rm -f "${RUN_DIR}"/result.csv.tmp.*.done "${RUN_DIR}"/result.csv.tmp.*.end "${RUN_DIR}"/result.csv.tmp.*.pass "${RUN_DIR}"/result.csv.tmp.*.probed "${RUN_DIR}"/result.csv.tmp.*.carry "${RUN_DIR}"/result.csv.tmp.*.union "${RUN_DIR}"/result.csv.tmp.*.meta "${RUN_DIR}/.nt_stop" "${RUN_DIR}/.nt_committing" "${RUN_DIR}/.auto_stop" "${RUN_DIR}/.user_stop" 2>/dev/null
}

# 锁目录在会话目录内，随会话创建/销毁；原实现是死循环等待，一旦残留就把整个会话卡死。
nt_lock_acquire() {
    local _i=0
    while ! mkdir "${NT_LOCKDIR}" 2>/dev/null; do
        _i=$((_i + 1))
        if [ "$_i" -ge 30 ]; then
            echolog "警告：uci 串行锁等待超 30s，强制接管（疑有 worker 僵死）"
            rm -rf "${NT_LOCKDIR}" 2>/dev/null
            mkdir "${NT_LOCKDIR}" 2>/dev/null
            return 0
        fi
        # 用整数秒：部分 busybox 未启用浮点 sleep（LEDE 24.10 实测 `sleep 0.1` 直接报错
        # 且不睡眠），会让锁超时瞬间触发。30 次 × 1s = 30s，与提示一致。
        sleep 1
    done
}
nt_lock_release() { rmdir "${NT_LOCKDIR}" 2>/dev/null; }

# 下载实测串行锁：同一时刻只允许一个 IP 处于下载测试中，否则多个 worker 并发下载会
# 互抢路由器 WAN 带宽，每个 IP 测出的“速度”都只是被瓜分后的一部分，无法横向比较。
# token 用每个下载唯一的 flag（worker+序号），释放时只删自己的锁，避免超时接管后
# 旧持有者醒来误删新持有者的锁。等待超过 120s 视为持有者僵死（单次下载上限 60s +
# SOCKS 启动），强制接管——正常情况下 worker 不会持锁这么久。
nt_dl_lock_acquire() {
    local _token="$1" _i=0
    [ -n "${DL_LOCK_DIR:-}" ] || return 0
    while ! mkdir "$DL_LOCK_DIR" 2>/dev/null; do
        # 等锁期间只有「其它 worker 已先完成」的自动提前停止才放弃排队；用户中途停止
        # 一轮测速时仍要排队把下载实测做完（见 .user_stop / .auto_stop 的区分）。
        if [ -n "${RUN_DIR:-}" ] && [ -f "${RUN_DIR}/.auto_stop" ]; then
            return 1
        fi
        _i=$((_i + 1))
        if [ "$_i" -ge 120 ]; then
            echolog "下载测速串行锁等待超过 120s，强制接管（疑有 worker 僵死）"
            rm -rf "$DL_LOCK_DIR" 2>/dev/null
            continue
        fi
        # 同上：整数秒以兼容不支持浮点 sleep 的 busybox；120 次 × 1s = 120s
        sleep 1
    done
    echo "$_token" > "$DL_LOCK_DIR/token" 2>/dev/null
    return 0
}
nt_dl_lock_release() {
    [ -n "${DL_LOCK_DIR:-}" ] || return 0
    [ "$(cat "$DL_LOCK_DIR/token" 2>/dev/null)" = "$1" ] && rm -rf "$DL_LOCK_DIR" 2>/dev/null
    return 0
}

# 测速前把 passwall 全局主节点切到稳定节点；还原由 node_test_cleanup 兜底。
# 节点变更需 /etc/init.d/passwall restart 才能实时生效；切换在拉起 worker 之前、
# 还原在所有 worker 结束之后，故 restart 不与 worker 的 app.sh run_socks 并发。
# 调用前须已通过必填与冲突校验（stable_node 非空且不在待测集合内）。
# 返回 1 = 稳定节点不存在（无 type），调用方应中止。
nt_switch_tcp_node() {
    local _s="${stable_node:-}"
    [ -n "$_s" ] || return 0
    # 稳定节点须存在。不再拒绝 socks 型：passwall 的 app.sh get_config() 明确接受
    # nodes 与 socks 两型作全局节点（本地负载均衡入口如 127.0.0.1:1181 正是 socks 型，
    # 也是官方分流节点的 default_node 常指目标）；它不参与测速、address 不会被改写。
    local _st
    _st=$(config_n_get "$_s" type)
    [ -n "$_st" ] || { echolog "稳定节点 ${_s} 不存在或无 type，中止"; return 1; }
    # passwall 26.10.x 起全局主节点键由 tcp_node 迁到 node：app.sh get_config() 读
    # @global[0].node，tcp_node 只剩 footer.htm 显示用（那里的 tcp_node|udp_node 正则
    # 已被注释掉、换成 node.main）。老版本读 tcp_node。故两键同写，谁生效由所装版本
    # 决定；还原统一走测前快照（成功路径 cp 快照 / 失败路径 nt_rollback），不逐键回滚。
    NT_ORIG_NODE="$(uci -q get passwall.@global[0].node 2>/dev/null)"
    NT_ORIG_TCP_NODE="$(uci -q get passwall.@global[0].tcp_node 2>/dev/null)"
    # 生效键已是稳定节点则无需切换（也不置 SWITCHED，cleanup 跳过还原）：node 优先，空则回落 tcp_node
    local _eff="${NT_ORIG_NODE:-$NT_ORIG_TCP_NODE}"
    [ "$_eff" = "$_s" ] && { NT_ORIG_NODE=""; NT_ORIG_TCP_NODE=""; NT_TCP_SWITCHED=0; return 0; }
    local _warn=""
    if [ -n "$NT_ORIG_NODE" ] && [ "$(config_n_get "$NT_ORIG_NODE" protocol)" = "_shunt" ]; then
        _warn="；原主节点 ${NT_ORIG_NODE} 是分流节点，测速期间分流规则暂停、流量全走稳定节点"
    fi
    echolog "切换 passwall 全局节点到稳定节点 ${_s}（原 node=${NT_ORIG_NODE:-无} / tcp_node=${NT_ORIG_TCP_NODE:-无}）${_warn}"
    uci set passwall.@global[0].node="${_s}"
    uci set passwall.@global[0].tcp_node="${_s}"
    uci commit passwall
    /etc/init.d/passwall restart >/dev/null 2>&1 || echolog "警告：passwall restart 失败，节点切换可能未实时生效"
    NT_TCP_SWITCHED=1
}

# 扫描进行中的 worker（全局 NT_RUNNING = 空格分隔的 pid:worker 列表）：
#   .done 存在 → 该 worker 完成且有有效结果，wait 收尸并从 NT_RUNNING 移除，记为停止触发；
#   .end  存在 → 该 worker 完成但无有效结果，wait 收尸并移除（仅释放并发槽，不触发停止）；
#   都没有 → 仍在运行，保留。
# 返回 0 = 检测到 .done（触发首完成即停），1 = 无。
# pid:worker 拆分用 :* 模式（不含 worker id），避免 worker id 含 [] 时 glob 误匹配。
nt_scan_running() {
    local _new="" _t _pid _w _rfile _stop=0
    for _t in $NT_RUNNING; do
        _pid="${_t%%:*}"; _w="${_t#*:}"
        _rfile="${RUN_DIR}/result.csv.tmp.$_w"
        if [ -f "${_rfile}.done" ]; then
            _stop=1
            wait "$_pid" 2>/dev/null
        elif [ -f "${_rfile}.end" ]; then
            wait "$_pid" 2>/dev/null
        else
            _new="${_new:+$_new }$_t"
        fi
    done
    NT_RUNNING="${_new# }"
    [ "$_stop" = "1" ]
}

# 对单个候选 IP 经节点 $_W 探测一次（uci 改 address → run_socks → probes 次 curl → 清理）。
# 供普通 worker 与迭代 worker 共用。uci set+commit 经锁串行化；run_socks+探测在锁外并行。
# stdout 输出一行: "keep sent recv loss avg"（keep=1 保留/0 丢弃）；日志不走 stdout。
# 参数: $1=node $2=ip $3=probe_url $4=timeout $5=probes $6=socks_port $7=flag
nt_probe_one_ip() {
    local _W=$1 _ip=$2 _purl=$3 _tmo=$4 _probes=$5 _port=$6 _flag=$7
    # uci set+commit 加锁（防多 worker 并发改 staging 丢更新）
    nt_lock_acquire
    uci set passwall.${_W}.address="${_ip}"
    uci commit passwall
    nt_lock_release
    # 拉本地 SOCKS（passwall 重启/异常时可能清掉该目录，缺目录会导致 run_socks 写配置失败）
    mkdir -p /tmp/etc/passwall 2>/dev/null
    NO_REC_PROCESS=1 /usr/share/passwall/app.sh run_socks \
        flag="${_flag}" node=${_W} \
        bind=127.0.0.1 socks_port=${_port} \
        config_file=${_flag}.json >>$LOG_FILE 2>&1
    # 就绪轮询 + 多探测（任一次非成功即 fail=1 并跳出，该 IP 整体丢弃）
    local _sent=0 _recv=0 _lat="" _done=0 _notready=0 _fail=0
    while [ $_done -lt $_probes ]; do
        local _res _code _tpre _rc
        _res=$(curl -x socks5h://127.0.0.1:${_port} -I -skL \
            --connect-timeout 3 --max-time ${_tmo} \
            -o /dev/null -w "%{http_code}:%{time_pretransfer}" "${_purl}" 2>/dev/null)
        _rc=$?
        if [ $_rc -eq 7 ]; then
            _notready=$((_notready + 1))
            [ $_notready -ge 10 ] && break
            sleep 1
            continue
        fi
        _notready=0
        _sent=$((_sent + 1))
        _done=$((_done + 1))
        _code="${_res%%:*}"
        _tpre="${_res##*:}"
        case "$_code" in
            200|204|301|302|307|308|40[0-9])
                _recv=$((_recv + 1))
                _lat="${_lat} ${_tpre}"
                ;;
            *)
                _fail=1
                break
                ;;
        esac
    done
    # 清理本次 SOCKS
    local _pf
    for _pf in /tmp/etc/passwall/*"${_flag}"*_plugin.pid; do
        [ -s "$_pf" ] && kill -9 "$(head -n1 "$_pf")" >/dev/null 2>&1
    done
    busybox pgrep -af "${_flag}" 2>/dev/null | awk '! /passwall-speedtest\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
    rm -rf /tmp/etc/passwall/*"${_flag}"* 2>/dev/null
    # 均值/丢包
    local _avg=0 _loss="1.00"
    if [ $_recv -gt 0 ]; then
        _loss=$(awk -v s=$_sent -v r=$_recv 'BEGIN{printf "%.2f", (s-r)/s}')
        _avg=$(echo "$_lat" | tr ' ' '\n' | grep -E '^[0-9.]+$' | awk '{s+=$1; n++} END{ if(n>0) printf "%.2f", s/n*1000 }')
        [ -z "$_avg" ] && _avg=0
    fi
    # 过滤：任一次失败/未完成即丢；否则按 tl/tll/tlr
    local _keep=1
    if [ $_fail -eq 1 ] || [ $_recv -lt $_probes ]; then
        _keep=0
    else
        if [ -n "${tl:-}" ] && [ "${tl}" -gt 0 ] 2>/dev/null; then
            [ "$(awk -v v=$_avg -v c=$tl 'BEGIN{print (v>c)?1:0}')" = "1" ] && _keep=0
        fi
        if [ -n "${tll:-}" ] && [ "${tll}" -gt 0 ] 2>/dev/null; then
            [ "$(awk -v v=$_avg -v c=$tll 'BEGIN{print (v<c)?1:0}')" = "1" ] && _keep=0
        fi
        if [ -n "${tlr:-}" ]; then
            [ "$(awk -v v=$_loss -v c=$tlr 'BEGIN{print (v>c)?1:0}')" = "1" ] && _keep=0
        fi
    fi
    echo "${_keep} ${_sent} ${_recv} ${_loss} ${_avg}"
}

# ── 下载实测（第二阶段）────────────────────────────────────
# 延迟初筛之后，对延迟最优的 N 个 IP 实测真实下载吞吐：与延迟探测走同一条链路——
# 把候选 IP 写进节点 address → run_socks 拉起本地 SOCKS → curl 下载固定大小文件 →
# 取 speed_download（字节/秒）换算 MB/s → 清理 SOCKS。
# 分两阶段的原因：延迟探测便宜，可以覆盖全部候选；真实下载贵，只值得测最有希望的 N 个。
# 结果经全局变量 NT_DL_SPEED 返回（两位小数 MB/s，失败为 0），不用 stdout：
# 本函数内部会 echolog（stdout 也有一份），若用 $(...) 取返回值会把日志混进速度值。
# 参数: $1=node $2=ip $3=download_url $4=max_time $5=socks_port $6=flag
NT_DL_SPEED=0
nt_download_one_ip() {
    local _W=$1 _ip=$2 _durl=$3 _tmo=$4 _port=$5 _flag=$6
    NT_DL_SPEED=0
    nt_lock_acquire
    uci set passwall.${_W}.address="${_ip}"
    uci commit passwall
    nt_lock_release
    mkdir -p /tmp/etc/passwall 2>/dev/null
    # 先删掉同 flag 的旧配置：保证下面校验用的一定是本次 run_socks 刚生成的文件，
    # 而不是历史残留（flag 含 PID+IP 序号，正常情况下不会重名，这里再兜一层）
    rm -f "/tmp/etc/passwall/${_flag}.json" "/tmp/etc/passwall/${_flag}.json_test.log" 2>/dev/null
    NO_REC_PROCESS=1 /usr/share/passwall/app.sh run_socks \
        flag="${_flag}" node=${_W} \
        bind=127.0.0.1 socks_port=${_port} \
        config_file=${_flag}.json >>$LOG_FILE 2>&1
    # ── 链路校验：证明下载确实经过候选 IP ──
    # passwall app.sh run_socks 会把本次生成的客户端配置写到
    # /tmp/etc/passwall/<config_file>（即 /tmp/etc/passwall/<flag>.json）。这份配置就是
    # 本地 SOCKS 进程实际使用的出站配置，其中出站服务器地址必须是我们刚写入节点 address
    # 的候选 IP。文件缺失（run_socks 写配置失败）或不含该 IP（复用了旧配置）时，测出的
    # 速度与候选 IP 无关，直接判本次失败，绝不把脏速度写进结果。
    local _cfg="/tmp/etc/passwall/${_flag}.json" _verify=1
    if [ ! -s "$_cfg" ]; then
        _verify=0
        echolog "下载测速校验失败：SOCKS 配置 ${_cfg} 不存在（run_socks 未生成配置），跳过该 IP"
    elif ! grep -qF -- "$_ip" "$_cfg" 2>/dev/null; then
        _verify=0
        echolog "下载测速校验失败：SOCKS 配置未指向候选 IP ${_ip}，跳过该 IP"
    fi
    # 就绪轮询（curl rc 7 = SOCKS 尚未就绪）+ 一次下载测速。--max-time 截断时 curl 返回 28，
    # 但已下载字节数与平均速度仍然有效，故 0 / 28 都接受（前提是 HTTP 2xx 且确实收到数据）。
    local _try=0 _res='' _rc=0 _code='' _bytes=0 _bps=0 _pf
    while [ "$_verify" = "1" ] && [ $_try -lt 10 ]; do
        _res=$(curl -x socks5h://127.0.0.1:${_port} -sL -o /dev/null \
            --connect-timeout 3 --max-time ${_tmo} \
            --speed-limit ${DL_FAST_FAIL_BPS} --speed-time ${DL_FAST_FAIL_TIME} \
            -w "%{http_code} %{size_download} %{speed_download}" "${_durl}" 2>/dev/null)
        _rc=$?
        if [ $_rc -eq 7 ]; then
            _try=$((_try + 1))
            sleep 1
            continue
        fi
        break
    done
    # 清理本次 SOCKS（与延迟探测一致，按 flag 前缀精确通配）
    for _pf in /tmp/etc/passwall/*"${_flag}"*_plugin.pid; do
        [ -s "$_pf" ] && kill -9 "$(head -n1 "$_pf")" >/dev/null 2>&1
    done
    busybox pgrep -af "${_flag}" 2>/dev/null | awk '! /passwall-speedtest\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
    rm -rf /tmp/etc/passwall/*"${_flag}"* 2>/dev/null
    [ "$_verify" = "1" ] || { NT_DL_SPEED=0; return 0; }
    _code="${_res%% *}"; _res="${_res#* }"
    _bytes="${_res%% *}"; _bps="${_res##* }"
    case "$_code" in 2[0-9][0-9]) ;; *) NT_DL_SPEED=0; return 0 ;; esac
    case "$_rc" in 0|28) ;; *) NT_DL_SPEED=0; return 0 ;; esac
    # 快速死亡：--speed-limit/--speed-time 在前 5s 平均不足 1MB 时主动中止（也是 rc=28，
    # 与 --max-time 截断同码）。此时这段低速不能当有效速度，直接判失败。
    if [ "$_rc" = "28" ] && \
        [ "$(awk -v s="${_bps:-0}" -v lim="$DL_FAST_FAIL_BPS" 'BEGIN{print ((s+0) < (lim+0)) ? 1 : 0}')" = "1" ]; then
        echolog "下载测速快速死亡：${_ip} ${DL_FAST_FAIL_TIME}s 内仅下载 ${_bytes:-0} 字节（不足 ${DL_FAST_FAIL_BYTES}），判失败"
        NT_DL_SPEED=0
        return 0
    fi
    # 16KB 下限：避免把 0 字节/极小的错误响应算成虚高速度
    NT_DL_SPEED=$(awk -v b="${_bytes:-0}" -v s="${_bps:-0}" 'BEGIN{
        if ((b+0) < 16384 || (s+0) <= 0) print "0"
        else printf "%.2f\n", (s+0)/1048576
    }')
    return 0
}

# 下载实测阶段：把 worker 结果文件里延迟最优的前 N 行逐 IP 实测下载速度，写入第 6 列
# （下载速度 MB/s）；成功测速时按速度降序重排（速度相同再按延迟升序），下载失败的行剔除。
# 若一个都没测成功（如测试 URL 经该节点不可达），保留原延迟排序结果，不丢延迟阶段的成果。
# 参数: $1=node $2=result_file $3=node_name $4=count $5=url $6=timeout $7=socks_port $8=flag
nt_download_phase() {
    local _W=$1 _rfile=$2 _Wn=$3 _cnt=$4 _durl=$5 _tmo=$6 _port=$7 _flag=$8
    local _rows="${_rfile}.rows" _out="${_rfile}.dl" _line _ip _spd _hdr
    local _i=0 _n _tested=0 _failed=0 _best_ip='' _best_spd=0 _stopped=0
    [ -f "$_rfile" ] || return 0
    _n=$(awk 'END{print NR+0}' "$_rfile" 2>/dev/null)
    [ "$_n" -gt 1 ] || return 0
    # 先按延迟升序排：保证“前 N 个”就是延迟最优的 N 个。上一会话沿用（.prev）或旧
    # result.csv 的行可能是按下载速度排的，不能直接拿来取前 N。
    sort_result "$_rfile" latency
    # 取数据行：跳过表头/注释/空行。不假设表头一定在第 1 行（.prev 恢复等路径可能没有
    # 表头），否则会把第一条数据行当表头丢掉，该节点最优 IP 恰好就在首行。
    # 同时把第 6 列清零：旧会话/上轮沿用的速度不能参与本次排序（只信本次实测值）
    awk -F, -v OFS=, 'NF>=7 && $1!="" && $1 !~ /^#/ && $1 != "IP 地址" {$6="0.00"; print}' \
        "$_rfile" > "$_rows" 2>/dev/null
    _n=$(awk 'END{print NR+0}' "$_rows" 2>/dev/null)
    if [ "$_n" -eq 0 ]; then rm -f "$_rows"; return 0; fi
    [ "$_cnt" -ge 1 ] 2>/dev/null || _cnt=5
    [ "$_cnt" -gt "$_n" ] && _cnt=$_n

    _hdr=$(sed -n '1p' "$_rfile" 2>/dev/null)
    case "$_hdr" in
        'IP 地址'*) ;;
        *) _hdr='IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码' ;;
    esac
    echo "$_hdr" > "$_out"

    echolog "下载测速 [${_Wn}] 开始：对延迟最优的 ${_cnt} 个 IP 实测下载（${_durl}，单 IP 上限 ${_tmo}s，${DL_FAST_FAIL_TIME}s 内不足 $((DL_FAST_FAIL_BYTES / 1048576))MB 即判失败）"
    # 用户中途停止「第一轮」时仍要完成下载实测：写 .nt_committing 让 rpcd 的停止逻辑
    # 给足收尾时间（最长 1200s），不要按 120s 强杀在下载/写回中间。
    if [ -f "${RUN_DIR}/.user_stop" ]; then
        : > "${RUN_DIR}/.nt_committing" 2>/dev/null
        echolog "下载测速 [${_Wn}] 用户已停止一轮测速，仍继续完成下载实测后再写回退出"
    fi
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        _i=$((_i + 1))
        if [ "$_i" -le "$_cnt" ] && [ "$_stopped" = "0" ]; then
            # 只有「其它 worker 已先完成」的自动提前停止才跳过下载；用户停止一轮时
            # .auto_stop 不存在，下载实测继续（这正是二轮测速的意义）。
            if [ -f "${RUN_DIR}/.auto_stop" ]; then
                _stopped=1
                echolog "下载测速 [${_Wn}] 其它 worker 已先完成，余下 IP 不再下载测速"
            fi
        fi
        if [ "$_i" -le "$_cnt" ] && [ "$_stopped" = "0" ]; then
            _ip="${_line%%,*}"
            # 每个 IP 一个独立 flag/config 文件，杜绝复用上一个 IP 的 SOCKS 配置。
            # 全局串行锁保证同一时刻只有一个 worker 在下载，否则 WAN 带宽被瓜分，
            # 各 IP 的速度没有可比性。结果走全局 NT_DL_SPEED（函数内部会 echolog，
            # 不能用 $(...) 抓 stdout）。
            if nt_dl_lock_acquire "${_flag}_${_i}"; then
                nt_download_one_ip "$_W" "$_ip" "$_durl" "$_tmo" "$_port" "${_flag}_${_i}"
                _spd="$NT_DL_SPEED"
                nt_dl_lock_release "${_flag}_${_i}"
                log_size_guard
                if [ "$(awk -v s="$_spd" 'BEGIN{print ((s+0)>0)?1:0}')" = "1" ]; then
                    _tested=$((_tested + 1))
                    if [ "$(awk -v a="$_spd" -v b="$_best_spd" 'BEGIN{print ((a+0)>(b+0))?1:0}')" = "1" ]; then
                        _best_spd="$_spd"; _best_ip="$_ip"
                    fi
                    echo "$_line" | awk -F, -v OFS=, -v s="$_spd" '{$6=s; print}' >> "$_out"
                    echolog "下载测速 [${_Wn}] ${_i}/${_cnt} - ${_ip} 速度 ${_spd} MB/s [保留]"
                else
                    _failed=$((_failed + 1))
                    echolog "下载测速 [${_Wn}] ${_i}/${_cnt} - ${_ip} 下载失败 [丢弃]"
                fi
            else
                # 等锁时收到停止信号：余下 IP 保留延迟结果，不再下载
                _stopped=1
                echolog "下载测速 [${_Wn}] 收到停止信号，余下 IP 不再下载测速"
                echo "$_line" >> "$_out"
            fi
        else
            echo "$_line" >> "$_out"
        fi
    done < "$_rows"
    rm -f "$_rows"

    if [ "$_tested" -gt 0 ]; then
        # 按下载速度降序（未测到的行速度 0 排在后面，同速度按延迟升序）
        sort_result "$_out"
        mv -f "$_out" "$_rfile"
        echolog "下载测速 [${_Wn}] 完成：成功 ${_tested}/${_cnt}，失败 ${_failed}，最优 ${_best_ip} ${_best_spd} MB/s"
    else
        rm -f "$_out"
        echolog "下载测速 [${_Wn}] 未取得任何有效速度（测试 URL 可能经该节点不可达），保留延迟排序结果"
    fi
    return 0
}

# 普通 worker（非迭代模式）：通过节点 $2 的链路测全部候选 IP（$5），保留行写入结果文件 $4。
# ash 子 shell 里 local 可用（已验证）。
# 参数: $1=idx $2=node $3=origaddr $4=result_file $5=ip_list $6=probe_url $7=timeout $8=probes $9=socks_port $10=flag
node_test_worker() {
    local _idx=$1 _W=$2 _orig=$3 _rfile=$4 _ips=$5 _purl=$6 _tmo=$7 _probes=$8 _port=$9 _flag=${10}
    local _ip _idx2=0 _total
    # 日志用节点备注名（无 remarks 则回退节点 id）；uci -q get 直读配置，子 shell 可用
    local _Wn
    _Wn="$(uci -q get "passwall.${_W}.remarks" 2>/dev/null)"; _Wn="${_Wn:-${_W}}"
    _total=$(printf '%s\n' "$_ips" | grep -c .)
    echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码" > "$_rfile"
    printf '%s\n' "$_ips" | while read -r _ip; do
        [ -n "$_ip" ] || continue
        # 协作式提前停止：主循环首个有效结果完成后写 .nt_stop，本 worker 跑完当前 IP 即停
        log_size_guard
        [ -f "${RUN_DIR}/.nt_stop" ] && { echolog "worker [${_Wn}] 收到停止信号，跑完当前 IP 即停（已完成 ${_idx2}/${_total}）"; break; }
        _idx2=$((_idx2 + 1))
        local _out _keep _sent _recv _loss _avg
        _out=$(nt_probe_one_ip "$_W" "$_ip" "$_purl" "$_tmo" "$_probes" "$_port" "$_flag")
        _keep=${_out%% *}; _out=${_out#* }
        _sent=${_out%% *}; _out=${_out#* }
        _recv=${_out%% *}; _out=${_out#* }
        _loss=${_out%% *}; _avg=${_out#* }
        if [ "$_keep" = "1" ]; then
            echo "${_ip},${_sent},${_recv},${_loss},${_avg},0.00," >> "$_rfile"
        fi
        local _st
        _st=$([ "$_keep" = "1" ] && echo "保留" || echo "丢弃")
        echolog "进度: 走节点测速 [${_Wn}] ${_idx2}/${_total} ($((_idx2*100/_total))%) - ${_ip} 延迟 ${_avg}ms 丢包 ${_loss} [${_st}]"
    done
    # 本 worker 结果按延迟升序排（首行即延迟初筛的最优），再对前 N 个做真实下载实测；
    # 下载阶段成功后结果按实测速度重排（首行即该节点下载最快 IP）
    sort_result "$_rfile" latency
    if [ "${DL_TEST_ENABLED:-1}" = "1" ]; then
        nt_download_phase "$_W" "$_rfile" "$_Wn" "${DL_TEST_COUNT:-5}" \
            "${DL_TEST_URL:-https://speed.cloudflare.com/__down?bytes=10000000}" \
            "${DL_TEST_TIME:-10}" "$_port" "${_flag}_dl"
    fi
    # 完成标记：有有效结果写 .done（触发首个有效结果即停），否则写 .end（仅释放并发槽）
    if [ -n "$(first_result_ip "$_rfile")" ]; then
        : > "${_rfile}.done"
    else
        : > "${_rfile}.end"
    fi
}

# 打印某节点最终轮（最近一次落盘）的测速结果：首行节点名，之后逐行一条测速结果：
#   迭代 [节点名] 最终结果（第 N 轮，共 M 条，完整列表见最佳 IP 表）:
#     IP 延迟 Xms 丢包 Y
#     ...
# 日志只列延迟最低的前 ITER_SUMMARY_MAX 条（中止场景一轮可能通过数百条，全量会刷爆
# 日志）；该节点全部通过行已按节点写入 result.csv（最佳 IP 表，前端可见）。
# 无最终轮（.meta 缺失，该节点本轮从未有通过 IP）时不打印，返回 1。
# 参数: $1=节点备注名 $2=结果文件
iterate_log_final_summary(){
    local _nm="$1" _rf="$2" _lp _n
    _lp=$(cat "${_rf}.meta" 2>/dev/null)
    [ -n "$_lp" ] || return 1
    _n=$(sed '1d' "$_rf" 2>/dev/null | awk -F, 'NF>=7 && $1!="" {c++} END{print c+0}')
    echolog "迭代 [${_nm}] 最终结果（第 ${_lp} 轮，共 ${_n} 条，完整列表见最佳 IP 表）:"
    sed '1d' "$_rf" 2>/dev/null | awk -F, 'NF>=7 && $1!="" {print $1, $5, $4, $6}' | head -n 10 | \
        while read -r _ip _avg _loss _spd; do
            case "$_spd" in
                ''|0|0.0|0.00) echolog "  ${_ip} 延迟 ${_avg}ms 丢包 ${_loss}" ;;
                *) echolog "  ${_ip} 延迟 ${_avg}ms 丢包 ${_loss} 下载 ${_spd} MB/s" ;;
            esac
        done
    [ "${_n:-0}" -gt 10 ] && echolog "  ……其余 $((_n - 10)) 条见最佳 IP 表（已按节点写入 result.csv）"
    return 0
}

# 迭代模式 worker：每个待测节点一个独立收敛循环，直到 deadline 或停止标志。
# 候选列表存 RUN_DIR/iterate_cand_<节点>（该节点自己的临时待测 IP 列表）：
#   第 1 轮 = 初始候选（$4），此后每轮只保留通过 IP（按延迟升序）作为下一轮候选，
#   逐轮收敛出「最稳定基础上延迟最低」的集合。到点后留下的就是最稳的 IP。
# 结果文件 $3 启动时先写表头（截断上次运行残留），每轮完成时原子覆盖（首行=该节点当前最优）；
# 中途不写 result.csv、不动 passwall。
# 终止条件：到点 / 停止标志 / 本轮通过数为 0（保留上一轮结果）/ 候选收敛到 ≤ITERATE_KEEP_MAX。
# 每 IP 之间也检查 deadline/停止标志，到点跑完当前 IP 即停，无全局轮次同步。
# 结束时把最终轮次号写入 $3.meta；最终轮完整测速结果由合并段统一打出（收尾日志逐节点汇总）。
# 参数: $1=idx $2=node $3=result_file $4=ip_list $5=probe_url $6=timeout $7=probes $8=socks_port $9=flag $10=deadline(epoch)
node_iterate_worker() {
    local _idx=$1 _W=$2 _rfile=$3 _ips=$4 _purl=$5 _tmo=$6 _probes=$7 _port=$8 _flag=$9 _deadline=${10}
    local _cand="${RUN_DIR}/iterate_cand_${_W}"
    local _pass=0 _lastpass=0 _kept _ip _list _total _passfile
    # 日志用节点备注名（无 remarks 则回退节点 id）；uci -q get 直读配置，子 shell 可用
    local _Wn
    _Wn="$(uci -q get "passwall.${_W}.remarks" 2>/dev/null)"; _Wn="${_Wn:-${_W}}"
    printf '%s\n' "$_ips" | grep -vE '^[[:space:]]*#|^[[:space:]]*$' > "$_cand"
    # 上一会话（或中断残留）有数据的结果文件先挪到 .prev：本轮若一个 IP 都没通过，
    # 退出时恢复它，避免「第 1 轮全部失败」把上一会话刚写回的最优 IP 清成空表
    if sed -n '2,$p' "$_rfile" 2>/dev/null | grep -v '^#' | grep -q .; then
        mv -f "$_rfile" "${_rfile}.prev"
    fi
    # 无中断残留时，用上一次合并结果（result.csv）中该节点的行初始化 .prev：
    # 每次成功合并都会删除 result.csv.tmp.*，下会话本来无残留可挪；
    # 有了这份 .prev，本会话一个 IP 都没通过时（如节点链路故障）能沿用上一次结果
    if [ ! -f "${_rfile}.prev" ] && [ -f "$IP_FILE" ]; then
        local _pname="${_Wn//,/ }"
        # 从 result.csv 取该节点的旧结果时：① 补上表头（旧实现直接搬数据行，
        # first_result_ip 会把它当表头跳过，丢掉该节点最优 IP）；② 去掉末列节点名，
        # 保持 worker 结果文件 7 列格式（合并段会统一次追加节点名）。
        {
            echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码"
            sed -n '2,$p' "$IP_FILE" 2>/dev/null | grep -av '^#' | \
                awk -F, -v n="$_pname" 'NF>=8 && $1!="" && $8==n {print $1","$2","$3","$4","$5","$6","$7}'
        } > "${_rfile}.prev"
        # 只有表头 = 该节点在 result.csv 里没有旧结果
        [ "$(awk 'END{print NR+0}' "${_rfile}.prev")" -gt 1 ] || rm -f "${_rfile}.prev"
    fi
    # 本轮结果从空表开始，只有通过集落盘时才覆盖；残留文件不再被当作本轮结果合并
    echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码" > "$_rfile"
    rm -f "${_rfile}.meta" 2>/dev/null
    while :; do
        # 到点 / 用户停止（.nt_stop 与 .iter_stop 都查）→ 跑完当前判定即退
        [ -f "${RUN_DIR}/.nt_stop" ] && break
        [ -f "${RUN_DIR}/.iter_stop" ] && break
        [ "$(date +%s)" -ge "$_deadline" ] && break
        _pass=$((_pass + 1))
        _list=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$_cand" 2>/dev/null)
        [ -n "$_list" ] && [ "$(printf '%s\n' "$_list" | grep -c .)" -gt 0 ] || break
        local _idx2=0 _total
        _total=$(printf '%s\n' "$_list" | grep -c .)
        _passfile="${_rfile}.pass"
        # 本轮「已探测过」的 IP 清单（通过与否都记）：轮次被停止/到点截断时，用它区分
        # 「本轮测过了」和「本轮还没轮到」，后者沿用上一轮结果（见轮末合并）
        _probedfile="${_rfile}.probed"
        echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码" > "$_passfile"
        : > "$_probedfile"
        printf '%s\n' "$_list" | while read -r _ip; do
            [ -n "$_ip" ] || continue
            log_size_guard
            [ -f "${RUN_DIR}/.nt_stop" ] && { echolog "迭代 [${_Wn}] 第 ${_pass} 轮收到停止信号，跑完当前 IP 即停"; break; }
            [ -f "${RUN_DIR}/.iter_stop" ] && break
            [ "$(date +%s)" -ge "$_deadline" ] && { echolog "迭代 [${_Wn}] 到达时长上限，跑完当前 IP 即停"; break; }
            _idx2=$((_idx2 + 1))
            echo "$_ip" >> "$_probedfile"
            local _out _keep _sent _recv _loss _avg
            _out=$(nt_probe_one_ip "$_W" "$_ip" "$_purl" "$_tmo" "$_probes" "$_port" "${_flag}_p${_pass}")
            _keep=${_out%% *}; _out=${_out#* }
            _sent=${_out%% *}; _out=${_out#* }
            _recv=${_out%% *}; _out=${_out#* }
            _loss=${_out%% *}; _avg=${_out#* }
            [ "$_keep" = "1" ] && echo "${_ip},${_sent},${_recv},${_loss},${_avg},0.00," >> "$_passfile"
            local _st
            _st=$([ "$_keep" = "1" ] && echo "保留" || echo "丢弃")
            echolog "迭代: [${_Wn}] 第 ${_pass} 轮 ${_idx2}/${_total} ($((_idx2*100/_total))%) - ${_ip} 延迟 ${_avg}ms 丢包 ${_loss} [${_st}]"
        done
        # 本轮通过集原子落盘：有数据才覆盖结果文件并收缩候选；全挂则保留上一轮结果并退出。
        # 本轮若被停止/到点截断（只测了部分候选），未测到的 IP 沿用上一轮结果 —— 否则
        # 「拿只测了一半的 IP 排序」会把上一轮里更优、但本轮还没轮到的 IP 直接丢掉，
        # 节点最优 IP 也就漏了（历史现象：停止后某节点最终结果只剩本轮测过的那一小撮）。
        if [ "$(grep -c . "$_passfile" 2>/dev/null)" -gt 1 ]; then
            local _probed _passed _carried=0 _truncated=0
            _passed=$(( $(grep -c . "$_passfile" 2>/dev/null) - 1 ))
            sort_result "$_passfile" latency
            _probed=$(grep -c . "$_probedfile" 2>/dev/null)
            [ "$_probed" -lt "$_total" ] && _truncated=1
            if [ "$_truncated" = "1" ]; then
                # 上一轮结果里「本轮没探测过」的行原样带入（探测过但没通过的不带）
                awk -F, 'NR==FNR { p[$1]=1; next } FNR>1 && $1!="" && $1 !~ /^#/ && !($1 in p) { print }' \
                    "$_probedfile" "$_rfile" > "${_passfile}.carry" 2>/dev/null
                if [ -s "${_passfile}.carry" ]; then
                    _carried=$(grep -c . "${_passfile}.carry" 2>/dev/null)
                    # 沿用行来自上一轮结果文件，已去掉表头，故直接整体并入（不再 sed 1d）
                    {
                        sed -n '1p' "$_passfile"
                        sed '1d' "$_passfile"
                        cat "${_passfile}.carry"
                    } > "${_passfile}.union" 2>/dev/null
                    sort_result "${_passfile}.union" latency
                    mv -f "${_passfile}.union" "$_passfile"
                    echolog "迭代 [${_Wn}] 第 ${_pass} 轮未测完（${_probed}/${_total}），未测到的 ${_carried} 个 IP 沿用上一轮结果"
                fi
                rm -f "${_passfile}.carry"
            fi
            mv -f "$_passfile" "$_rfile"
            # 下一轮候选 = 本轮结果按延迟升序（含沿用的行）→ 每轮都从最优 IP 开始测
            sed -n '2,$p' "$_rfile" 2>/dev/null | grep -v '^#' | awk -F, 'NF>=7 && $1!="" {print $1}' > "${_cand}.new"
            mv -f "${_cand}.new" "$_cand"
            _lastpass=$_pass
            _kept=$(wc -l < "$_cand" | tr -d ' ')
            echolog "迭代 [${_Wn}] 第 ${_pass} 轮完成，通过 ${_passed}/${_total}，下一轮候选 ${_kept} 个"
            # 收敛终止：剩余 ≤ ITERATE_KEEP_MAX 个时不再复测，保存当前结果提前结束。
            # 仅整轮测完时才判断 —— 被停止/到点截断的轮次候选数偏小，不代表收敛
            if [ "$_truncated" = "0" ] && [ "$_kept" -le "$ITERATE_KEEP_MAX" ]; then
                echolog "迭代 [${_Wn}] 候选收敛至 ${_kept} 个，保存结果，该节点提前结束"
                break
            fi
        else
            rm -f "$_passfile"
            echolog "迭代 [${_Wn}] 第 ${_pass} 轮全部失败，保留第 $((_pass - 1)) 轮结果，该节点提前结束"
            break
        fi
        [ "$(wc -l < "$_cand" | tr -d ' ')" -eq 0 ] && break
    done
    # 本会话拿到过通过集 → 上一会话残留已无意义；一个都没通过 → 恢复上一会话结果，
    # 使合并段沿用其最优 IP 写回（幂等），而不是报「结果为空，保留原 address」
    if [ "${_lastpass:-0}" -ge 1 ]; then
        rm -f "${_rfile}.prev" 2>/dev/null
    elif [ -f "${_rfile}.prev" ]; then
        mv -f "${_rfile}.prev" "$_rfile"
        echolog "迭代 [${_Wn}] 本会话无通过 IP，沿用上一会话结果"
    fi
    # 迭代收敛后的下载实测：只测最终通过集中延迟最优的 N 个，按实测吞吐重排（首行即该节点最快 IP）
    if [ "${DL_TEST_ENABLED:-1}" = "1" ] && [ -n "$(first_result_ip "$_rfile")" ]; then
        nt_download_phase "$_W" "$_rfile" "$_Wn" "${DL_TEST_COUNT:-5}" \
            "${DL_TEST_URL:-https://speed.cloudflare.com/__down?bytes=10000000}" \
            "${DL_TEST_TIME:-10}" "$_port" "${_flag}_dl"
    fi
    # 结束摘要：轮次号落盘（最终轮完整测速结果由合并段统一打出，保证收尾日志逐节点齐全；
    # 不在 worker 退出点打印——提前收敛的节点其结果会被淹没在收尾段之前的进度行里）
    [ "${_lastpass:-0}" -ge 1 ] && echo "${_lastpass}" > "${_rfile}.meta"
    # 完成标记（到点/停止后写，主进程 wait 收尸后合并）
    if [ -n "$(first_result_ip "$_rfile")" ]; then
        : > "${_rfile}.done"
    else
        : > "${_rfile}.end"
    fi
}

node_speed_test() {
    # 校验 passwall 已安装
    [ -f /usr/share/passwall/app.sh ] || { echolog "未安装 passwall，无法使用走节点测速"; return 1; }
    [ -f /usr/share/passwall/utils.sh ] || { echolog "缺少 passwall utils.sh，无法使用走节点测速"; return 1; }
    # 必选项：稳定节点（测速期间把 passwall 全局节点切到它，测后由快照还原）
    [ -n "${stable_node:-}" ] || { echolog "未配置「稳定节点」（必选项），中止走节点测速"; return 1; }
    # passwall 的 utils.sh 会覆盖 LOG_FILE 与 echolog()，先保存再恢复，避免日志写进 passwall 的日志文件
    local _pws_log_file="$LOG_FILE"
    . /usr/share/passwall/utils.sh
    LOG_FILE="$_pws_log_file"
    echolog() {
        local d="$(date "+%Y-%m-%d %H:%M:%S")"
        echo -e "$d: $*"
        echo -e "$d: $*" >>$LOG_FILE
    }

    mkdir -p "$RESULT_DIR"

    # 公共参数
    local probe_url="${node_test_url:-https://www.google.com/generate_204}"
    local timeout="${node_test_timeout:-5}"
    case "$timeout" in ''|*[!0-9]*) timeout=5 ;; esac
    local probes="${node_test_probes:-3}"
    case "$probes" in ''|*[!0-9]*) probes=3 ;; esac
    [ "$probes" -ge 1 ] 2>/dev/null || probes=3
    [ "$probes" -le 5 ] 2>/dev/null || probes=5
    local threads="${node_test_threads:-5}"
    case "$threads" in ''|*[!0-9]*) threads=5 ;; esac
    [ "$threads" -ge 0 ] 2>/dev/null || threads=5

    # ── 下载实测（第二阶段）：延迟初筛后，对每个 worker 延迟最优的 N 个 IP 走同一节点
    # 链路真实下载固定大小文件，按实测吞吐（MB/s）重排并选最优。开关缺省为开（老配置
    # 未写入该项时也启用），显式写 0/off 才关闭。
    DL_TEST_ENABLED=1
    case "${download_test_enabled:-1}" in
        0|no|false|off|OFF|False|No) DL_TEST_ENABLED=0 ;;
    esac
    DL_TEST_COUNT="${download_test_count:-5}"
    case "$DL_TEST_COUNT" in ''|*[!0-9]*) DL_TEST_COUNT=5 ;; esac
    [ "$DL_TEST_COUNT" -ge 1 ] 2>/dev/null || DL_TEST_COUNT=5
    # 每个候选要真实下载一个 10MB 文件，候选越多越费流量/时间；硬上限 10 个
    [ "$DL_TEST_COUNT" -le 10 ] 2>/dev/null || DL_TEST_COUNT=10
    DL_TEST_URL="${download_test_url:-https://speed.cloudflare.com/__down?bytes=10000000}"
    [ -n "$DL_TEST_URL" ] || DL_TEST_URL='https://speed.cloudflare.com/__down?bytes=10000000'
    DL_TEST_TIME="${download_test_time:-10}"
    case "$DL_TEST_TIME" in ''|*[!0-9]*) DL_TEST_TIME=10 ;; esac
    [ "$DL_TEST_TIME" -ge 1 ] 2>/dev/null || DL_TEST_TIME=10
    [ "$DL_TEST_TIME" -le 60 ] 2>/dev/null || DL_TEST_TIME=60
    # 下载实测串行锁目录：多个 worker 同时下载会互抢 WAN 带宽，速度数字不可信
    DL_LOCK_DIR="${RUN_DIR}/.download_test_lock"

    # ── 候选 IP 来源 ──
    local count="${node_test_count:-30}"
    case "$count" in ''|*[!0-9]*) count=30 ;; esac
    [ "$count" -gt 0 ] || count=30

    local ip_source_mode="file"
    local selected_ip_file=""
    if [ "${RETEST_FROM_RESULT:-0}" = "1" ]; then
        # 复测模式：候选来自当前 result.csv + 各节点当前 address，绝不重新拉在线列表。
        read_node_ip_map
        build_retest_ip_lists "$count" || { echolog "复测模式：没有可复测的候选 IP（result.csv 为空且节点 address 不是 IP），中止"; return 1; }
        echolog "复测模式：候选来自现有 result.csv / 各节点当前 address（不重新下载在线列表），每节点最多 ${count} 个"
        ip_source_mode="retest"
    elif [ "${ip_source:-}" = "online" ]; then
        # online CM 源：一次下载原始列表，按各 ip_list 的 regions 分别过滤成 ip_list_<N>.txt
        migrate_ip_online_regions
        fetch_online_raw || return 1
        compute_default_ip_list
        local _n _e
        for _n in 1 2 3 4 5; do
            eval "_e=\${list${_n}_enabled:-0}"
            [ "$_e" = "1" ] && build_ip_list_file "$_n"
        done
        ip_source_mode="online"
    else
        selected_ip_file="$(select_ip_file)"
        [ -f "$selected_ip_file" ] || { echolog "候选 IP 列表文件不存在: $selected_ip_file"; return 1; }
        ip_source_mode="file"
    fi

    # 读取 node_ip 段（统一表：每行=待测节点+其 CM 列表）→ NODE_IP_WORKERS + node→ip_list 映射。
    # 所有模式都要读（worker 来源是 node_ip）；仅在线模式才用 per-node 列表过滤。
    read_node_ip_map

    # 取某 worker 的候选 IP（grep 去注释空行 + head -n count）。无 echolog、可在 $(..) 内用。
    # 迭代模式下这只是该 worker 的「初始候选」——worker 内部的收敛循环自己维护缩小后的列表。
    get_worker_ips(){
        local nodeid="$1" src_file=""
        if [ "$ip_source_mode" = "retest" ]; then
            src_file="${RUN_DIR}/retest_ips_${nodeid}.txt"
        elif [ "$ip_source_mode" = "online" ]; then
            local N
            N=$(resolve_node_list "$nodeid")
            if [ -n "$N" ]; then
                src_file="${RUN_DIR}/ip_list_${N#list}.txt"
            else
                src_file="${ONLINE_RAW:-}"   # 无启用列表 → 全量 :443 原始
            fi
        else
            src_file="$selected_ip_file"
        fi
        [ -n "$src_file" ] && [ -f "$src_file" ] || return 1
        grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$src_file" | head -n "$count"
    }

    NODE_TEST_FLAG_BASE="node_test_$$"
    NODE_TEST_DONE=0
    NODE_TEST_CLEANED=0
    NODE_TESTED_WORKERS=""
    trap node_test_cleanup EXIT INT TERM

    # ── 检测 worker：第三方设置「Passwall worker nodes & per-node IP list」表里选的节点 ──
    # 主源 = node_ip 段的 node 字段；兼容旧配置里的 passwall_services 多选。
    local workers_raw=""
    if [ "x${passwall_enabled:-0}" = "x1" ]; then
        local _w _seen=""
        for _w in ${NODE_IP_WORKERS:-} ${passwall_services:-}; do
            [ -n "$_w" ] || continue
            case " $_seen " in *" $_w "*) ;; *) _seen="$_seen $_w"; workers_raw="$workers_raw $_w"; ;; esac
        done
    fi

    if [ -n "$workers_raw" ]; then
        # ── 多节点并行路径 ──
        # 校验每个 worker，建 idx→node→origaddr 映射文件
        NT_ORIG_FILE="$(mktemp "${RUN_DIR}/node_test_orig.XXXXXX")" || { echolog "创建 worker 映射文件失败"; return 1; }
        NT_LOCKDIR="${RUN_DIR}/.node_test_lock"
        local valid_workers="" widx=0
        for _w in $workers_raw; do
            local wt wa
            wt=$(echo $(config_n_get $_w type) | tr 'A-Z' 'a-z')
            [ -n "$wt" ] || { echolog "worker 节点 $_w 不存在或无 type，跳过"; continue; }
            if [ "$wt" = "socks" ]; then
                echolog "worker 节点 $_w 是 SOCKS 类型，跳过（其 address 即 SOCKS 服务器，替换为 CF IP 会失效）"
                continue
            fi
            wa=$(config_n_get $_w address)
            [ -n "$wa" ] || { echolog "worker 节点 $_w 未配置 address，跳过"; continue; }
            widx=$((widx + 1))
            printf '%s\t%s\t%s\n' "$widx" "$_w" "$wa" >> "$NT_ORIG_FILE"
            valid_workers="$valid_workers $_w"
        done
        if [ -z "$valid_workers" ]; then
            echolog "第三方设置里的 passwall 节点均不可用，回退单节点串行"
            rm -f "$NT_ORIG_FILE"; NT_ORIG_FILE=""
        else
            echolog "开始走节点测速（多节点并行: ${widx} 个 worker, 每IP探测 ${probes} 次, 超时 ${timeout}s, 并发上限 ${threads}）"
            if [ "$DL_TEST_ENABLED" = "1" ]; then
                echolog "下载实测已启用：每个 worker 延迟最优的 ${DL_TEST_COUNT} 个 IP 逐 IP 实测下载（${DL_TEST_URL}，单 IP 上限 ${DL_TEST_TIME}s），按实测吞吐选最优"
            fi
            echolog "提示：测速期间所有 worker 节点的 address 会被反复改写，这些节点会短暂抖动，测完各写各的最优 IP"
            # 记录实测过的 worker 集合，供 ip_replace/passwall_best_ip 跳过（保留各节点自己的最优 IP）
            NODE_TESTED_WORKERS="$valid_workers"
            # 稳定节点不得在待测 worker 集合内（否则用户实流量仍走被改写地址的节点，切换无意义）
            case " $valid_workers " in *" ${stable_node} "*) echolog "稳定节点 ${stable_node} 与待测 worker 重叠，中止（稳定节点不得在待测集合内）"; return 1 ;; esac
            # 测前快照 /etc/config/passwall：测后还原以抹掉 passwall 测速中途新增的异常节点段
            nt_snapshot || { echolog "passwall 快照失败，中止"; return 1; }
            # 拉起 worker 之前切 passwall 全局节点到稳定节点（测后由 node_test_cleanup 还原）
            nt_switch_tcp_node || { echolog "稳定节点校验失败，中止"; node_test_cleanup; trap - EXIT INT TERM; return 1; }
            # 并发上限 + 首个有效结果即停：维持 threads 个并发，轮询各 worker 完成标记；
            # 任一 worker 跑完全部候选 IP 且保留≥1 个有效 IP（写 .done）时，立即终止其余
            # worker，跳到合并阶段按已有（含被杀 worker 的部分）结果排序。无有效结果的
            # worker 完成（写 .end）仅释放并发槽，不触发停止。
            NT_RUNNING=""
            rm -f "${RUN_DIR}/.nt_stop" 2>/dev/null
            local launched=0 _stop=0 _rfile _t _port _wips _wtot
            if [ "${ITERATE_MODE:-0}" = "1" ]; then
                # ── 限时迭代：每个待测节点一个独立收敛循环 ──
                # 无全局轮次、无「首个有效结果即停」；各 worker 内部自维护缩小候选列表，
                # 循环到 NT_ITER_DEADLINE（或停止标志）为止。并发上限不适用，全部同时运行。
                # 结果只在最后合并一次写回（中途不写 result.csv、不动 passwall 结果）。
                echolog "迭代模式：${widx} 个待测节点各跑独立收敛循环至时限，全部同时运行（并发上限不适用）"
                for _w in $valid_workers; do
                    launched=$((launched + 1))
                    _rfile="${RUN_DIR}/result.csv.tmp.$_w"
                    rm -f "${_rfile}.done" "${_rfile}.end" "${_rfile}.pass" "${_rfile}.probed" 2>/dev/null
                    # 端口确定性分配：48900 + idx - 1（每 worker 固定端口，复用于其所有 IP）
                    _port=$((48900 + launched - 1))
                    _wips=$(get_worker_ips "$_w") || { echolog "worker 节点 $_w 候选 IP 不可用，跳过"; continue; }
                    [ "$(echo "$_wips" | grep -c .)" -gt 0 ] || { echolog "worker 节点 $_w 候选 IP 为空，跳过"; continue; }
                    node_iterate_worker "$launched" "$_w" "$_rfile" "$_wips" "$probe_url" "$timeout" "$probes" "$_port" "${NODE_TEST_FLAG_BASE}_$launched" "$NT_ITER_DEADLINE" &
                    NT_RUNNING="${NT_RUNNING:+$NT_RUNNING }$!:${_w}"
                done
                # 各 worker 到点/停止后自行退出，wait 收尸，随后按各自最终通过集合并（仅一次）
                wait
            else
                # ── 普通模式：并发上限 + 首个有效结果即停 ──
                echolog "提示：首个 worker 测出有效结果即终止其余，按已有结果排序"
                [ "$threads" -ge 1 ] 2>/dev/null || threads=$widx
                for _w in $valid_workers; do
                    [ "$_stop" = "1" ] && break
                    # 达到并发上限：轮询回收已完成 worker 释放空位，或首个有效结果触发停止
                    while [ "$(echo $NT_RUNNING | wc -w)" -ge "$threads" ] && [ "$_stop" != "1" ]; do
                        if nt_scan_running; then _stop=1; break; fi
                        [ "$(echo $NT_RUNNING | wc -w)" -ge "$threads" ] && sleep 1
                    done
                    [ "$_stop" = "1" ] && break
                    launched=$((launched + 1))
                    _rfile="${RUN_DIR}/result.csv.tmp.$_w"
                    rm -f "${_rfile}.done" "${_rfile}.end" "${_rfile}.probed" 2>/dev/null
                    # 端口确定性分配：48900 + idx - 1（每 worker 固定端口，复用于其所有 IP）
                    _port=$((48900 + launched - 1))
                    # 按 worker 取其对应 CM IP 列表（在线模式 per-worker；非在线模式共享 selected_ip_file）
                    _wips=$(get_worker_ips "$_w") || { echolog "worker 节点 $_w 候选 IP 不可用，跳过"; continue; }
                    _wtot=$(echo "$_wips" | grep -c .)
                    [ "$_wtot" -gt 0 ] || { echolog "worker 节点 $_w 候选 IP 为空，跳过"; continue; }
                    [ "$_wtot" -lt "$count" ] && echolog "worker 节点 $_w 候选 IP $_wtot < $count（其 CM 列表偏小）"
                    node_test_worker "$launched" "$_w" "" "$_rfile" "$_wips" "$probe_url" "$timeout" "$probes" "$_port" "${NODE_TEST_FLAG_BASE}_$launched" &
                    NT_RUNNING="${NT_RUNNING:+$NT_RUNNING }$!:${_w}"
                done
                # 排空仍运行的 worker（无提前停止时正常完成路径）
                while [ -n "$NT_RUNNING" ] && [ "$_stop" != "1" ]; do
                    if nt_scan_running; then _stop=1; break; fi
                    [ -n "$NT_RUNNING" ] && [ "$_stop" != "1" ] && sleep 1
                done
                # 提前停止：写停止标志，其余 worker 跑完当前 IP 自行 break 退出，wait 收尸（不 kill）
                if [ "$_stop" = "1" ]; then
                    # 用户手动停止时（.user_stop 已存在）不能写 .auto_stop：否则其它 worker
                    # 会跳过二轮下载实测。用户停止的语义是「停第一轮，但把已通过 IP 的下载
                    # 做完再写回」，所以此处只阻止新一轮延迟探测（.nt_stop），不阻止下载。
                    if [ -f "${RUN_DIR}/.user_stop" ]; then
                        echolog "用户已停止一轮测速，其余 worker 继续完成各自下载实测"
                    else
                        echolog "首个有效结果 worker 完成，其余 worker 跑完当前 IP 即停，按已有结果排序"
                        # .auto_stop 只标记「首个 worker 已完成」的自动提前停止：其余 worker
                        # 不再排队做下载实测，避免首个 worker 出结果后还串行下载很久。
                        : > "${RUN_DIR}/.auto_stop"
                    fi
                    : > "${RUN_DIR}/.nt_stop"
                    wait  # 各 worker 自行 break → 写 .done/.end → 正常退出，wait 收尸
                fi
            fi
            NT_RUNNING=""
            # 注意：这里不能删 result.csv.tmp.*.meta——合并段还要读它打逐节点最终结果；
            # .meta 由合并循环逐个删除（随 mwfile），中断残留由 node_test_cleanup 兜底
            rm -f "${RUN_DIR}"/result.csv.tmp.*.done "${RUN_DIR}"/result.csv.tmp.*.end "${RUN_DIR}"/result.csv.tmp.*.pass "${RUN_DIR}"/result.csv.tmp.*.probed "${RUN_DIR}/.nt_stop" 2>/dev/null
            # ── 提交阶段开始：不可中断 ──
            # 从这里到写回完成是本次运行的「提交点」：此刻若被 SIGINT 打断，EXIT/INT trap 会走
            # nt_rollback 把刚算出的最优 IP 整份回滚掉（历史事故：用户点停止 → 20s 后强杀，
            # 正好落在写回段中间）。故屏蔽 INT/TERM，让收尾跑完再退；SIGKILL 屏蔽不掉，但写回
            # 已改成原子替换，被 kill -9 也只会留下测前配置或完整结果。
            # .nt_committing 让 rpcd 的停止逻辑知道「正在提交，别强杀」，与「停止=等到写完」一致。
            trap '' INT TERM
            : > "${RUN_DIR}/.nt_committing"
            # 各 worker 写回各自最优（串行，单进程无锁）
            local merged reapply
            merged="$(mktemp "${RUN_DIR}/result.csv.merged.XXXXXX")"
            reapply="$(mktemp "${RUN_DIR}/node_test_reapply.XXXXXX")"
            echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码,节点" > "$merged"
            local mi mw morig mwfile mwbest
            while read -r mi mw morig; do
                [ -n "$mw" ] || continue
                mwfile="${RUN_DIR}/result.csv.tmp.$mw"
                # 被杀 worker 的部分结果文件未经其自身排序；这里补排，使 first_result_ip
                # 取到该 worker 的最优 IP 写回 passwall address。排序键与 worker 内一致：
                # 有下载实测速度时按速度降序，否则（全 0/未测）按延迟升序。对已完成 worker 幂等。
                sort_result "$mwfile"
                mwbest=$(first_result_ip "$mwfile")
                local mwname
                mwname="$(uci -q get "passwall.${mw}.remarks" 2>/dev/null)"; mwname="${mwname:-$mw}"
                if [ -n "$mwbest" ]; then
                    printf '%s\t%s\n' "$mw" "$mwbest" >> "$reapply"
                    echolog "走节点测速完成 [${mwname}]，最优 IP ${mwbest} 待写回 passwall 节点"
                else
                    echolog "走节点测速 [${mwname}] 结果为空，保留原 address"
                fi
                # 迭代模式：收尾段逐节点打出该节点最终轮（最近一次落盘）的完整测速结果——
                # worker 无论提前收敛还是跑到时限退出，此处统一按「节点名一行 + 逐行结果」汇总
                [ "${ITERATE_MODE:-0}" = "1" ] && iterate_log_final_summary "$mwname" "$mwfile"
                # awk 过滤丢掉被杀 worker kill -9 中途截断的脏行（NF<7），正常 7 列行等价；
                # 末列追加节点备注名（逗号替换为空格防 CSV 断列），供前端按节点查看
                local _nname="${mwname//,/ }"
                sed '1d' "$mwfile" 2>/dev/null | awk -F, -v n="$_nname" 'NF>=7 && $1!="" {print $0 "," n}' >> "$merged"
                rm -f "$mwfile" "${mwfile}.meta" "${mwfile}.prev" 2>/dev/null
            done < "$NT_ORIG_FILE"
            rm -f "${NT_ORIG_FILE}"; NT_ORIG_FILE=""
            # 合并结果排序供 UI/图表展示（首行供 DNS/host 用）：有下载实测速度时按实测吞吐
            # 降序（下载最快的节点排前面），未测/速度 0 的行按延迟升序排在后面
            sort_result "$merged"
            if [ -z "$(first_result_ip "$merged")" ]; then
                echolog "走节点测速所有 worker 结果均为空，保留上一次结果"
                rm -f "$merged" "$reapply"
                trap node_test_cleanup EXIT INT TERM   # 先复原信号，回滚路径照旧
                node_test_cleanup; trap - EXIT INT TERM
                return 1
            fi
            echo "# Speed test time: $(date +'%Y-%m-%d %H:%M:%S')" >> "$merged"
            append_persistent_history "$merged"
            # ── 写回配置 → 重启生效 → 发布结果 ──
            # 顺序固定：先把配置写全（原子替换 + 读回校验），再 restart 让运行时生效，最后才发布
            # result.csv —— 保证「UI 看到新结果」就一定意味着「各节点已拿到自己的最优 IP」。
            # 还原测前快照同时抹掉 passwall 测速中途新增的异常节点段；全局节点键（node/tcp_node）
            # 在快照里就是测前原值，一次 restart 同时让各 worker 最优 IP + 原始全局节点生效。
            echolog "开始写回：各节点最优 IP 写入 passwall 配置（原子替换，此阶段不可中断，请稍候）"
            if nt_apply_best_addresses "$reapply"; then
                /etc/init.d/passwall restart >/dev/null 2>&1 || echolog "警告：passwall restart 失败，最优 IP 可能未实时生效"
            else
                echolog "警告：最优 IP 未写入 passwall 配置，收尾按测前配置回滚"
            fi
            rotate_result_files
            mv -f "$merged" "$IP_FILE"
            bestip=$(first_result_ip "$IP_FILE")
            rm -f "$reapply" "${RUN_DIR}/.nt_committing" 2>/dev/null
            trap node_test_cleanup EXIT INT TERM
            if [ -n "$bestip" ]; then
                if [ "${DL_TEST_ENABLED:-1}" = "1" ]; then
                    echolog "走节点测速全部完成，全局最优 IP ${bestip}（有下载实测时按实测吞吐排序；已写回各 worker 节点；已清理测速期间 passwall 新增的异常节点）"
                else
                    echolog "走节点测速全部完成，全局最低延迟 IP ${bestip}（已写回各 worker 节点；已清理测速期间 passwall 新增的异常节点）"
                fi
            fi
            NODE_TEST_DONE=1; node_test_cleanup; trap - EXIT INT TERM
            return 0
        fi
    fi

    # ── 单节点串行路径（无第三方 passwall worker 时回退）──
    NODE_TEST_NODE="${node_test_node:-}"
    [ -n "${NODE_TEST_NODE}" ] || { echolog "未选择 passwall 节点，无法走节点测速"; return 1; }
    local node_type
    node_type=$(echo $(config_n_get ${NODE_TEST_NODE} type) | tr 'A-Z' 'a-z')
    [ -n "${node_type}" ] || { echolog "passwall 节点 ${NODE_TEST_NODE} 不存在或无 type"; return 1; }
    if [ "${node_type}" = "socks" ]; then
        echolog "走节点测速不支持 SOCKS 类型的 passwall 节点（其 address 即 SOCKS 服务器，替换为 CF IP 会失效），请选择一个 CF-CDN 前置的代理节点"
        return 1
    fi
    NODE_TEST_ORIG_ADDR=$(config_n_get ${NODE_TEST_NODE} address)
    [ -n "${NODE_TEST_ORIG_ADDR}" ] || { echolog "passwall 节点 ${NODE_TEST_NODE} 未配置 address"; return 1; }
    # 稳定节点不得为待测节点本身（否则用户实流量仍走被改写地址的节点，切换无意义）
    [ "${stable_node}" != "${NODE_TEST_NODE}" ] || { echolog "稳定节点与待测节点 ${NODE_TEST_NODE} 相同，中止（稳定节点不得为待测节点）"; return 1; }

    # 测前快照 /etc/config/passwall：测后还原以抹掉 passwall 测速中途新增的异常节点段
    nt_snapshot || { echolog "passwall 快照失败，中止"; return 1; }

    # uci 串行锁目录：多 worker 路径已在分支内设置；单节点路径此前遗漏，导致
    # nt_lock_acquire 对着空路径 mkdir 失败、每次都空等 30s 才强制接管（每 IP 多 30s）。
    NT_LOCKDIR="${RUN_DIR}/.node_test_lock"

    # 单节点候选 IP（按其 node_ip 指派或默认列表；非在线模式共享 selected_ip_file）
    local ip_list total
    ip_list=$(get_worker_ips "${NODE_TEST_NODE}") || { echolog "passwall 节点 ${NODE_TEST_NODE} 候选 IP 不可用"; return 1; }
    total=$(echo "$ip_list" | grep -c .)
    [ "$total" -gt 0 ] || { echolog "passwall 节点 ${NODE_TEST_NODE} 候选 IP 列表为空"; return 1; }
    [ "$total" -lt "$count" ] && echolog "节点 ${NODE_TEST_NODE} 候选 IP $total < $count（其 CM 列表偏小）"
    NODE_TESTED_WORKERS="${NODE_TEST_NODE}"

    echolog "开始走节点测速（单节点串行: ${NODE_TEST_NODE}, 候选: ${total}, 每IP探测 ${probes} 次, 超时 ${timeout}s）"
    echolog "提示：测速期间源节点 ${NODE_TEST_NODE} 的 address 会被反复改写，该节点会短暂抖动，测完写回最优 IP"

    result_tmp="$(mktemp "${RUN_DIR}/result.csv.tmp.XXXXXX")" || { echolog "创建临时测速结果文件失败"; return 1; }
    # inline 调用 worker 之前切 passwall 全局节点到稳定节点（测后由 node_test_cleanup 还原）
    nt_switch_tcp_node || { echolog "稳定节点校验失败，中止"; node_test_cleanup; trap - EXIT INT TERM; return 1; }
    # 单节点：inline 调用 worker（不 background），端口 48900、flag=base
    if [ "${ITERATE_MODE:-0}" = "1" ]; then
        # 限时迭代：该节点跑独立收敛循环到时限，结果文件同路径，末尾统一合并写回（仅一次）
        echolog "迭代模式：节点 ${NODE_TEST_NODE} 独立收敛循环至时限（${NT_ITER_DEADLINE} 截止）"
        node_iterate_worker 1 "${NODE_TEST_NODE}" "$result_tmp" "$ip_list" "$probe_url" "$timeout" "$probes" 48900 "${NODE_TEST_FLAG_BASE}" "$NT_ITER_DEADLINE"
        # 单节点迭代路径无合并段，最终轮完整测速结果在此打出（多 worker 路径在合并段打）
        local _nm
        _nm="$(uci -q get "passwall.${NODE_TEST_NODE}.remarks" 2>/dev/null)"; _nm="${_nm:-${NODE_TEST_NODE}}"
        iterate_log_final_summary "$_nm" "$result_tmp"
    else
        node_test_worker 1 "${NODE_TEST_NODE}" "${NODE_TEST_ORIG_ADDR}" "$result_tmp" "$ip_list" "$probe_url" "$timeout" "$probes" 48900 "${NODE_TEST_FLAG_BASE}"
    fi

    # ── 提交阶段开始：不可中断（同多 worker 路径：此刻被 INT 打断会触发 nt_rollback 抹掉结果）──
    trap '' INT TERM
    : > "${RUN_DIR}/.nt_committing"

    if [ -z "$(first_result_ip "$result_tmp")" ]; then
        echolog "走节点测速结果 IP 数量为 0，整份回滚并保留上一次结果"
        rm -f "$result_tmp"
        trap node_test_cleanup EXIT INT TERM   # 先复原信号，回滚路径照旧
        node_test_cleanup; trap - EXIT INT TERM
        return 1
    fi

    # 数据行末列追加节点备注名（与多 worker 合并段的 result.csv 列结构一致，逗号替换为空格防 CSV 断列）
    local _nm2="${NODE_TEST_NODE}"
    _nm2="$(uci -q get "passwall.${NODE_TEST_NODE}.remarks" 2>/dev/null)"; _nm2="${_nm2//,/ }"; _nm2="${_nm2:-${NODE_TEST_NODE}}"
    awk -F, -v n="$_nm2" 'NR==1 {print $0 ",节点"; next} NF>=7 && $1!="" && $1 !~ /^#/ {print $0 "," n}' \
        "$result_tmp" > "${result_tmp}.nn" 2>/dev/null \
        && [ -s "${result_tmp}.nn" ] && mv -f "${result_tmp}.nn" "$result_tmp"

    echo "# Speed test time: $(date +'%Y-%m-%d %H:%M:%S')" >> "$result_tmp"

    # ── 写回配置 → 重启生效 → 发布结果（同多 worker 路径：先落盘配置，再发布结果）──
    bestip=$(first_result_ip "$result_tmp")
    local _reapply
    _reapply="$(mktemp "${RUN_DIR}/node_test_reapply.XXXXXX")"
    printf '%s\t%s\n' "${NODE_TEST_NODE}" "${bestip}" > "$_reapply"
    echolog "开始写回：节点 ${NODE_TEST_NODE} 最优 IP ${bestip} 写入 passwall 配置（原子替换，此阶段不可中断，请稍候）"
    if nt_apply_best_addresses "$_reapply"; then
        /etc/init.d/passwall restart >/dev/null 2>&1 || echolog "警告：passwall restart 失败，最优 IP 可能未实时生效"
        echolog "走节点测速完成，最优 IP ${bestip} 已写入 passwall 节点 ${NODE_TEST_NODE}（已清理测速期间 passwall 新增的异常节点）"
    else
        echolog "警告：最优 IP 未写入 passwall 配置，收尾按测前配置回滚"
    fi
    rm -f "$_reapply"
    rotate_result_files
    mv -f "$result_tmp" "$IP_FILE"
    rm -f "${RUN_DIR}/.nt_committing" 2>/dev/null
    trap node_test_cleanup EXIT INT TERM

    NODE_TEST_DONE=1; node_test_cleanup; trap - EXIT INT TERM
    return 0
}

function ip_replace(){

    # 获取最快 IP（从 result.csv 结果文件中获取第一个 IP）
    bestip=$(first_result_ip "$IP_FILE")
    if [[ -z "${bestip}" ]]; then
        echolog "走节点测速结果 IP 数量为 0,跳过下面步骤..."
    else
        host_ip
        mosdns_ip
        astra_dns_ip
        alidns_ip
        ssr_best_ip
        vssr_best_ip
        bypass_best_ip
        passwall_best_ip
        passwall2_best_ip
    fi
}

function host_ip() {
    if [ "x${HOST_enabled}" == "x1" ] ;then
        get_servers_config "host_domain"
        HOSTS_LINE=$(echo "$host_domain" | sed 's/,/ /g' | sed "s/^/$bestip /g")
        host_domain_first=$(echo "$host_domain" | awk -F, '{print $1}')

        if [ -n "$(grep $host_domain_first /etc/hosts)" ]
        then
            echo $host_domain_first
            sed -i".bak" "/$host_domain_first/d" /etc/hosts
            echo $HOSTS_LINE >> /etc/hosts;
        else
            echo $HOSTS_LINE >> /etc/hosts;
        fi
        /etc/init.d/dnsmasq reload &>/dev/null
        echolog "HOST 完成"
    fi
}

function mosdns_ip() {
    if [ "x${MosDNS_enabled}" == "x1" ] ;then
        # 默认只取1个，除非配置了 MosDNS_ip_count
        count=1
        if [ -n "$MosDNS_ip_count" ] && [ "$MosDNS_ip_count" -gt 1 ]; then
            count=$MosDNS_ip_count
        fi

        # 获取前 count 个 IP，注意结果文件的第一行通常是标题，所以从第2行开始取
        # sed -n "2,$((count + 1))p" 取第2行到第 count+1 行
        # grep -v '^#' 排除注释行（如末尾的时间戳）
        # awk -F, '{print $1}' 提取第一列 IP
        # tr '\n' ' ' 将多行转为空格分隔的一行
        bestips=$(sed -n "2,$((count + 1))p" $IP_FILE | grep -v '^#' | awk -F, '{print $1}' | tr '\n' ' ')

        if [ -n "$(grep 'option cloudflare' /etc/config/mosdns)" ]
        then
            sed -i".bak" "/option cloudflare/d" /etc/config/mosdns
        fi
        if [ -n "$(grep 'list cloudflare_ip' /etc/config/mosdns)" ]
        then
            sed -i".bak" "/list cloudflare_ip/d" /etc/config/mosdns
        fi

        # 写入 option cloudflare '1'
        sed -i '/^$/d' /etc/config/mosdns && echo -e "\toption cloudflare '1'" >> /etc/config/mosdns

        # 循环写入所有 IP
        for ip in $bestips; do
            if [ -n "$ip" ]; then
                 echo -e "\tlist cloudflare_ip '$ip'" >> /etc/config/mosdns
            fi
        done

        /etc/init.d/mosdns restart &>/dev/null
        if [ "x${openclash_restart}" == "x1" ] ;then
            /etc/init.d/openclash restart &>/dev/null
        fi
        echolog "MosDNS 写入完成，已写入IP: $bestips"
    fi
}

function astra_dns_ip() {
    if [ "x${AstraDNS_enabled}" == "x1" ] ;then
        astra_config="${AstraDNS_config:-/etc/astra-dns/named.yaml}"
        astra_bin="${AstraDNS_bin:-/usr/bin/astra-dns}"

        if [ ! -x ${SCRIPT_DIR}/astra-dns.sh ]; then
            echolog "astra-dns 写入失败: ${SCRIPT_DIR}/astra-dns.sh 不存在"
            return 1
        fi

        if ${SCRIPT_DIR}/astra-dns.sh --result-csv "$IP_FILE" --config "$astra_config" --bin "$astra_bin" >>$LOG_FILE 2>&1; then
            echolog "astra-dns 写入完成，配置文件: $astra_config"
        else
            echolog "astra-dns 写入失败，请检查配置文件路径、二进制路径和 YAML 格式"
            return 1
        fi
    fi
}

function passwall_best_ip(){
    # 走节点测速模式下，每个 passwall worker 在 node_speed_test 里已各自写入其 CM 列表内的最优 IP
    # （见 NODE_TESTED_WORKERS 的逐节点写回）。不再用全局最优 IP 覆写——否则按节点选 CM 列表的意义
    # 被抹掉，且会误把 SOCKS/无 address 等被跳过的无效节点也覆写成 CF IP。故此处保留为 no-op。
    if [ "x${passwall_enabled}" == "x1" ] ;then
        echolog "passwall 各 worker 节点已按各自 CM 列表写入最优 IP，跳过全局覆写"
    fi
}

function passwall2_best_ip(){
    if [ "x${passwall2_enabled}" == "x1" ] ;then
        echolog "设置passwall2 IP"
        for ssrname in $passwall2_services
        do
            echo $ssrname
            uci set passwall2.$ssrname.address="${bestip}"
        done
        uci commit passwall2
    fi
}

function ssr_best_ip(){
    if [ "x${ssr_enabled}" == "x1" ] ;then
        echolog "设置ssr IP"
        for ssrname in $ssr_services
        do
            echo $ssrname
            uci set shadowsocksr.$ssrname.server="${bestip}"
            uci set shadowsocksr.$ssrname.ip="${bestip}"
        done
        uci commit shadowsocksr
    fi
}

function vssr_best_ip(){
    if [ "x${vssr_enabled}" == "x1" ] ;then
        echolog "设置Vssr IP"
        for ssrname in $vssr_services
        do
            echo $ssrname
            uci set vssr.$ssrname.server="${bestip}"
        done
        uci commit vssr
    fi
}

function bypass_best_ip(){
    if [ "x${bypass_enabled}" == "x1" ] ;then
        echolog "设置Bypass IP"
        for ssrname in $bypass_services
        do
            echo $ssrname
            uci set bypass.$ssrname.server="${bestip}"
        done
        uci commit bypass
    fi
}

function alidns_ip(){
    if [ "x${DNS_enabled}" == "x1" ] ;then
        get_servers_config "DNS_type" "app_key" "app_secret" "main_domain" "sub_domain" "line" "AliDNS_ip_count"
        if [ "x${DNS_type}" == "xaliyun" ] ;then
            count=1
            case "$AliDNS_ip_count" in
                ''|*[!0-9]*) count=1 ;;
                *) [ "$AliDNS_ip_count" -gt 1 ] && count=$AliDNS_ip_count ;;
            esac

            bestips=$(sed -n "2,$((count + 1))p" $IP_FILE | grep -v '^#' | awk -F, '{print $1}' | sed '/^$/d' | tr '\n' ' ')
            first_dns_ip=$(echo "$bestips" | awk '{print $1}')
            case "$first_dns_ip" in
                *:*) bestip_is_ipv6=1 ;;
                *) bestip_is_ipv6=0 ;;
            esac

            if [ -z "$bestips" ]; then
                echolog "阿里云DNS写入失败: 未找到可写入IP"
                return
            fi

            for sub in $sub_domain
            do
                if ${SCRIPT_DIR}/aliddns.sh "$app_key" "$app_secret" "$main_domain" "$sub" "$line" "$bestip_is_ipv6" $bestips; then
                    echolog "更新域名${sub}阿里云DNS完成，已写入IP: $bestips"
                else
                    echolog "更新域名${sub}阿里云DNS失败，请检查上方阿里云API错误信息"
                fi
                sleep 1s
            done
        fi
        echo "aliyun done"
    fi
}

read_config

# 启动参数
if [ "$1" ] ;then
    # 整跑入口的单实例锁：start/test/replace 都算一次完整运行。抢不到说明已有整跑在跑
    # （定时任务重叠、UI 连点、SSH 手敲），直接退出——两套 worker 会抢同一批 passwall 节点
    # 并互删中间状态，跑出来的结果是脏的。
    case "$1" in
        start|test|replace|retest)
            run_lock_acquire || { echolog "已有测速在运行（PID $(cat "$RUN_LOCK_DIR/pid" 2>/dev/null)），本次 $1 跳过"; exit 1; }
            ;;
    esac
    [ $1 == "start" ] && speed_test && ip_replace
    [ $1 == "test" ] && speed_test
    [ $1 == "retest" ] && { RETEST_FROM_RESULT=1; speed_test && ip_replace; }
    [ $1 == "replace" ] && ip_replace
    run_lock_release
    exit
fi