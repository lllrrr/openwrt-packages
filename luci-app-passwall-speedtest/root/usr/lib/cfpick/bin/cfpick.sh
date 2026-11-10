#!/bin/sh

LOG_FILE='/tmp/cfpick.log'
PERSIST_LOG='/etc/config/cfpick.log'
RESULT_DIR='/tmp/cfpick'
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
# 按 worker 的运行锁：同一 worker 同时只允许一个任务，不同 worker 可并行探测。
# 全量任务（未选节点）和 replace 额外持有 __all__，与所有任务互斥。
WORKER_LOCK_ROOT="$RESULT_DIR/.worker-locks"
COMMIT_LOCK_DIR="$RESULT_DIR/.commit.lock"
RUN_REGISTRY="$RESULT_DIR/.runs"
# 成功后监测：每个成功 worker 一个后台 monitor 进程（独立于任务运行锁）。
MONITOR_LOCK_ROOT="$RESULT_DIR/.monitor-locks"
MONITOR_STATE_DIR="$RESULT_DIR/.monitor-state"
NT_RELOAD_PENDING="$RESULT_DIR/.passwall.reload"
RUN_DIR=""
IPV4_TXT='/usr/share/cfpick/ip.txt'
IPV6_TXT='/usr/share/cfpick/ipv6.txt'

SCRIPT_DIR='/usr/lib/cfpick/bin'

# 定时任务可只跑部分节点：cfpick.sh <mode> --node=<passwall section> [...]
# 为空 = 全部待测节点（保持旧行为）。
NODE_FILTER=""
node_selected() {
    [ -z "$NODE_FILTER" ] && return 0
    case " $NODE_FILTER " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# 迭代模式：单节点候选收敛到 ≤ 此数量即保存结果提前结束（继续复测收益小）。
# 由独立参数 iterate_converge_count（迭代收敛阈值）配置，与下载实测候选数
# download_test_count 无关；node_speed_test 会按配置覆写（缺省 5，上限 100）。
ITERATE_KEEP_MAX=5

# 下载实测快速死亡：起测后 DL_FAST_FAIL_TIME 秒内平均下载不足 DL_FAST_FAIL_BYTES
# 即中止并判失败（curl --speed-limit/--speed-time），别让慢/死 IP 白等满单 IP 时限。
DL_FAST_FAIL_BYTES=1048576
DL_FAST_FAIL_TIME=5
DL_FAST_FAIL_BPS=$((DL_FAST_FAIL_BYTES / DL_FAST_FAIL_TIME))

# 复测模式（retest）：候选只取当前 result.csv + 各节点当前 address，不重新下载在线列表
RETEST_FROM_RESULT=0

function get_global_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get cfpick.global.$1`' 2>/dev/null
        shift
    done
}

function get_servers_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get cfpick.servers.$1`' 2>/dev/null
        shift
    done
}

echolog() {
    local d="$(date "+%Y-%m-%d %H:%M:%S")"
    echo -e "$d: $*"
    echo -e "$d: $*" >>$LOG_FILE
}

# ── 按 worker 的运行锁 ────────────────────────────────────────────────
# 任务勾选哪些 worker，就只锁哪些；没勾选（= 全部）或 replace 额外锁 __all__，
# 与任何任务互斥。同一 worker 冲突时后到者直接跳过（不排队）；不同 worker 的
# 任务可以同时探测，下载/写回阶段再用 commit 锁全局排队。
LOCK_CAP=43200

lock_owner_alive() {
    local _pid
    _pid="$(cat "$1/pid" 2>/dev/null)"
    [ -n "$_pid" ] && [ -d "/proc/$_pid" ] && \
        grep -q 'cfpick\.sh' "/proc/$_pid/cmdline" 2>/dev/null
}

# 原子抢一个 mkdir 锁；活着的持有者未超时则返回 1（调用方跳过），死锁/超时自动接管。
lock_take() {
    local _dir="$1" _cap="${2:-$LOCK_CAP}" _pid _started _now _tries=0
    mkdir -p "$(dirname "$_dir")" 2>/dev/null
    while :; do
        if mkdir "$_dir" 2>/dev/null; then
            echo "$$" > "$_dir/pid"
            date +%s > "$_dir/started"
            return 0
        fi
        _pid="$(cat "$_dir/pid" 2>/dev/null)"
        if lock_owner_alive "$_dir"; then
            _started="$(cat "$_dir/started" 2>/dev/null)"
            case "$_started" in ''|*[!0-9]*) _started=0 ;; esac
            _now="$(date +%s)"
            if [ "$_started" -gt 0 ] && [ $((_now - _started)) -gt "$_cap" ]; then
                echolog "锁 ${_dir##*/} 已持有 $((_now - _started))s 超过上限 ${_cap}s（PID ${_pid} 疑似僵死），接管"
            else
                return 1
            fi
        else
            echolog "锁 ${_dir##*/} 为残留（PID ${_pid:-未知} 已不存在），接管"
        fi
        rm -rf "$_dir"
        _tries=$((_tries + 1))
        [ "$_tries" -lt 3 ] || return 1
    done
}

lock_drop() {
    [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -rf "$1" 2>/dev/null
    return 0
}

WORKER_LOCKS_ACQUIRED=""
ACQUIRED_WORKERS=""
worker_locks_acquire() {
    local _ids="$1" _id
    ACQUIRED_WORKERS=""
    # 固定顺序逐个抢；已被别的任务占用的 worker 只跳过它自己，任务里其余的
    # worker 继续执行。一个都没抢到才整体放弃。
    for _id in $(printf '%s\n' $_ids | sort -u); do
        if lock_take "$WORKER_LOCK_ROOT/$_id.lock" "$LOCK_CAP"; then
            WORKER_LOCKS_ACQUIRED="$WORKER_LOCKS_ACQUIRED $_id"
            ACQUIRED_WORKERS="$ACQUIRED_WORKERS $_id"
        else
            echolog "worker ${_id} 正在被另一个任务使用，本次跳过该 worker（任务里的其余 worker 继续）"
        fi
    done
    WORKER_LOCKS_ACQUIRED="${WORKER_LOCKS_ACQUIRED# }"
    ACQUIRED_WORKERS="${ACQUIRED_WORKERS# }"
    [ -n "$ACQUIRED_WORKERS" ]
}

worker_locks_release() {
    local _id
    for _id in $WORKER_LOCKS_ACQUIRED; do
        lock_drop "$WORKER_LOCK_ROOT/$_id.lock"
    done
    WORKER_LOCKS_ACQUIRED=""
    ACQUIRED_WORKERS=""
}

# 下载实测 + 写回阶段的全局队列：两个不同 worker 的任务可以同时探测，但同一时刻
# 只允许一个做下载/写回，避免互相抢带宽把速度测偏。后到者阻塞等待（A 方案）；
# 停止按钮只停止探测，已经跑完探测的任务仍会排队完成自己的下载和写回。
COMMIT_LOCK_HELD=0
commit_lock_acquire() {
    local _waited=0 _pid _started _now
    [ "$COMMIT_LOCK_HELD" = "1" ] && return 0
    mkdir -p "$RESULT_DIR" 2>/dev/null || return 1
    while :; do
        if mkdir "$COMMIT_LOCK_DIR" 2>/dev/null; then
            echo "$$" > "$COMMIT_LOCK_DIR/pid"
            date +%s > "$COMMIT_LOCK_DIR/started"
            COMMIT_LOCK_HELD=1
            return 0
        fi
        _pid="$(cat "$COMMIT_LOCK_DIR/pid" 2>/dev/null)"
        if lock_owner_alive "$COMMIT_LOCK_DIR"; then
            _started="$(cat "$COMMIT_LOCK_DIR/started" 2>/dev/null)"
            case "$_started" in ''|*[!0-9]*) _started=0 ;; esac
            _now="$(date +%s)"
            if [ "$_started" -gt 0 ] && [ $((_now - _started)) -gt "$LOCK_CAP" ]; then
                echolog "下载锁已持有 $((_now - _started))s 超过上限（PID ${_pid} 疑似僵死），接管"
            else
                _waited=$((_waited + 1))
                if [ $((_waited % 30)) -eq 0 ]; then
                    echolog "等待其他任务完成下载/写回（已等待 ${_waited}s，PID ${_pid}）"
                fi
                [ "$_waited" -ge 14400 ] && {
                    echolog "等待下载锁超过 4 小时，本次放弃"
                    return 1
                }
                sleep 1
                continue
            fi
        else
            echolog "下载锁为残留（PID ${_pid:-未知} 已不存在），接管"
        fi
        rm -rf "$COMMIT_LOCK_DIR"
    done
}

commit_lock_release() {
    [ "$COMMIT_LOCK_HELD" = "1" ] || return 0
    lock_drop "$COMMIT_LOCK_DIR"
    COMMIT_LOCK_HELD=0
    nt_maybe_passwall_reload
}

# 是否还有别的任务在跑（不含自己）。用于 restart 合并与共享日志轮转。
nt_other_runs_active() {
    local _m _pid
    for _m in "$RUN_REGISTRY"/*; do
        [ -e "$_m" ] || continue
        _pid="${_m##*/}"
        [ "$_pid" = "$$" ] && continue
        if [ -d "/proc/$_pid" ] && grep -q 'cfpick\.sh' "/proc/$_pid/cmdline" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# passwall restart 会中断其他任务正在用的 run_socks，所以只要还有别的任务在跑就
# 先记一个 pending，等最后一个任务收尾时统一 restart 一次。
nt_maybe_passwall_reload() {
    [ -f "$NT_RELOAD_PENDING" ] || return 0
    nt_other_runs_active && return 0
    rm -f "$NT_RELOAD_PENDING" 2>/dev/null
    /etc/init.d/passwall restart >/dev/null 2>&1 || echolog "警告：passwall restart 失败，配置可能未实时生效"
}

nt_request_passwall_reload() {
    : > "$NT_RELOAD_PENDING" 2>/dev/null
    nt_maybe_passwall_reload
}

# 下载实测期间暂停其他任务的探测：下载会互相抢带宽，对方在下载时本任务的
# worker 在每次探测前先等一等，对方释放 commit 锁后自动继续。
DOWNLOAD_WAIT_LOGGED=0
wait_while_downloading() {
    local _pid
    [ -d "$COMMIT_LOCK_DIR" ] || { DOWNLOAD_WAIT_LOGGED=0; return 0; }
    _pid="$(cat "$COMMIT_LOCK_DIR/pid" 2>/dev/null)"
    [ -n "$_pid" ] && [ "$_pid" != "$$" ] || { DOWNLOAD_WAIT_LOGGED=0; return 0; }
    lock_owner_alive "$COMMIT_LOCK_DIR" || { DOWNLOAD_WAIT_LOGGED=0; return 0; }
    if [ "$DOWNLOAD_WAIT_LOGGED" = "0" ]; then
        echolog "另一任务正在下载实测，暂停探测，对方完成后自动继续"
        DOWNLOAD_WAIT_LOGGED=1
    fi
    while [ -d "$COMMIT_LOCK_DIR" ] && lock_owner_alive "$COMMIT_LOCK_DIR"; do
        [ -f "${RUN_DIR}/.nt_stop" ] && return 1
        sleep 1
    done
    DOWNLOAD_WAIT_LOGGED=0
    echolog "对方下载完成，继续探测"
    return 0
}

# ── 会话目录与活动任务登记 ────────────────────────────────────────────
# 会话目录名用主进程 PID：worker 都是 fork 出来的子 shell，$$ 仍是主进程 PID。
register_run() {
    mkdir -p "$RUN_REGISTRY" 2>/dev/null || return 0
    {
        printf 'pid=%s\n' "$$"
        printf 'dir=%s\n' "$RUN_DIR"
        printf 'mode=%s\n' "$ACTION"
        printf 'started=%s\n' "$(date +%s)"
        printf 'workers=%s\n' "$(echo $RUN_WORKERS | tr ' ' ',')"
    } > "$RUN_REGISTRY/$$"
}

unregister_run() {
    rm -f "$RUN_REGISTRY/$$" 2>/dev/null
}

run_session_create() {
    mkdir -p "$RESULT_DIR" 2>/dev/null || { echolog "无法创建 $RESULT_DIR，本次跳过"; return 1; }
    RUN_DIR="$RESULT_DIR/run.$$"
    rm -rf "$RUN_DIR" 2>/dev/null
    if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
        echolog "创建会话目录 $RUN_DIR 失败，本次跳过"
        RUN_DIR=""
        return 1
    fi
    echo "$$" > "$RUN_PID_FILE"
    reap_stale_run_dirs
    # 清掉上次被 kill -9 留下的死登记/死 worker 锁，避免面板显示幽灵任务。
    local _m _pid _d
    for _m in "$RUN_REGISTRY"/*; do
        [ -e "$_m" ] || continue
        _pid="${_m##*/}"
        if [ ! -d "/proc/$_pid" ] || ! grep -q 'cfpick\.sh' "/proc/$_pid/cmdline" 2>/dev/null; then
            rm -f "$_m" 2>/dev/null
        fi
    done
    for _d in "$WORKER_LOCK_ROOT"/*.lock; do
        [ -d "$_d" ] || continue
        lock_owner_alive "$_d" || rm -rf "$_d" 2>/dev/null
    done
    register_run
    return 0
}

run_session_destroy() {
    [ -n "$RUN_DIR" ] && rm -rf "$RUN_DIR" 2>/dev/null
    unregister_run
    rm -f "$RUN_PID_FILE" 2>/dev/null
    RUN_DIR=""
}

# 本次任务实际要测的 worker 集合（已应用 --node 过滤）。为空时回退单节点，
# 但回退节点也必须落在所选范围内，绝不偷偷改测用户没选的节点。
run_worker_ids() {
    read_node_ip_map
    local _w _out="" _seen=""
    for _w in ${NODE_IP_WORKERS:-} ${passwall_services:-}; do
        [ -n "$_w" ] || continue
        node_selected "$_w" || continue
        case " $_seen " in *" $_w "*) continue ;; esac
        _seen="$_seen $_w"; _out="$_out $_w"
    done
    if [ -z "$_out" ] && [ -n "${node_test_node:-}" ] && node_selected "$node_test_node"; then
        _out="$node_test_node"
    fi
    echo "${_out# }"
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

# ── 成功后监测 ────────────────────────────────────────────────────────
# worker 取得有效结果后，主流程派生一个后台 monitor 进程：每分钟复测一次
# 这个成功结果的延迟。节点配置了 DDNS 域名时按域名测（先解析，测解析出的
# 地址）；其余节点测 result.csv 里该 worker 的最优 IP。连续失败达到阈值就
# 触发该 worker 的复测，monitor 退出，由复测成功后重新拉起新的 monitor。
# worker 被下一次任务占用（worker 锁出现）时 monitor 立即退出。
# 监测进程本身不改写 passwall 配置：普通节点测已写回的 address，DDNS 节点
# 测仍是域名的 address；独立内核模式把解析出的 IP 传给 cfpick core。
MONITOR_NODE=""
MONITOR_FLAG=""
MONITOR_CLEANED=0

# 与 worker 锁不同：存活的 monitor 永远不因“持有太久”被接管（它本来就长期
# 存在）。只有进程已死（kill -9 / 重启）才清掉残留锁。
monitor_lock_take() {
    local _dir="$1" _pid _mtime _age
    mkdir -p "$(dirname "$_dir")" 2>/dev/null
    if mkdir "$_dir" 2>/dev/null; then
        echo "$$" > "$_dir/pid"
        date +%s > "$_dir/started"
        return 0
    fi
    if lock_owner_alive "$_dir"; then
        return 1
    fi
    _pid="$(cat "$_dir/pid" 2>/dev/null)"
    if [ -z "$_pid" ]; then
        # mkdir 与写 pid 之间的窗口：刚创建的锁不当作残留，避免并发清掉。
        _mtime="$(stat -c %Y "$_dir" 2>/dev/null || date -r "$_dir" +%s 2>/dev/null || echo 0)"
        case "$_mtime" in ''|*[!0-9]*) _mtime=0 ;; esac
        _age=0
        [ "$_mtime" -gt 0 ] && _age=$(( $(date +%s) - _mtime ))
        [ "$_age" -lt 10 ] && return 1
    fi
    rm -rf "$_dir" 2>/dev/null
    mkdir "$_dir" 2>/dev/null || return 1
    echo "$$" > "$_dir/pid"
    date +%s > "$_dir/started"
    return 0
}

# 该 worker 在 result.csv 里的最优 IP（按节点 ID 或备注名匹配，与复测候选一致）。
monitor_result_ip() {
    local _id="$1" _label
    _label="$(node_label "$_id")"
    sed -n '2,$p' "$IP_FILE" 2>/dev/null | grep -av '^#' | \
        awk -F, -v n="$_label" -v id="$_id" \
            'NF>=8 && $1!="" && ((NF>=9 && $9!="" && $9==id) || ((NF<9 || $9=="") && $8==n)) {print $1; exit}'
}

# 节点在 node_ip 段里配置的 DDNS 域名（DDNS 总开关关闭时为空）。
monitor_ddns_domain() {
    local _node="$1" _idx _id _dom=""
    [ "$(uci -q get cfpick.global.ddns_enabled 2>/dev/null)" = "1" ] || return 0
    for _idx in $(uci -q show cfpick 2>/dev/null | \
        sed -n "s/^cfpick\.@node_ip\[\([0-9][0-9]*\)\]=node_ip$/\1/p"); do
        _id="$(uci -q get "cfpick.@node_ip[$_idx].node" 2>/dev/null)"
        [ "$_id" = "$_node" ] || continue
        _dom="$(uci -q get "cfpick.@node_ip[$_idx].ddns_domain" 2>/dev/null)"
        break
    done
    printf '%s' "$_dom"
}

# worker 是否仍在待测节点表里（节点页删除后停止监测）。
monitor_node_configured() {
    local _id="$1" _w
    NODE_IP_MAP_LOADED=0
    read_node_ip_map
    for _w in ${NODE_IP_WORKERS:-} ${passwall_services:-}; do
        [ "$_w" = "$_id" ] && return 0
    done
    [ "${node_test_node:-}" = "$_id" ] && return 0
    return 1
}

monitor_has_target() {
    local _dom
    _dom="$(monitor_ddns_domain "$1")"
    [ -n "$_dom" ] && return 0
    [ -n "$(monitor_result_ip "$1")" ]
}

# 经节点当前配置探测一次（不改 address）：PassWall 模式用 run_socks 读节点
# 已有 address（普通节点=最优 IP，DDNS 节点=域名）；独立内核模式把传入的
# _ip 写进临时内核配置。成功时 NT_MON_LAT = 平均延迟(ms)，返回 0。
# 参数: $1=node $2=ip（独立内核用，可为空）$3=probe_url $4=timeout $5=probes
#       $6=socks_port $7=flag
NT_MON_LAT=0
nt_monitor_probe() {
    local _W=$1 _ip=$2 _purl=$3 _tmo=$4 _probes=$5 _port=$6 _flag=$7
    NT_MON_LAT=0
    mkdir -p /tmp/etc/passwall 2>/dev/null
    local _fail=0 _sent=0 _recv=0 _lat="" _done=0 _notready=0 _res _code _tpre _rc
    if [ "${standalone_enabled:-0}" = "1" ]; then
        [ -n "$_ip" ] || _fail=1
        if [ "$_fail" = "0" ] && ! /usr/bin/cfpick core start --node "$_W" --ip "$_ip" \
             --port "$_port" --core "${standalone_core:-xray}" --flag "$_flag" \
             >>"$LOG_FILE" 2>&1; then
            _fail=1
        fi
    else
        NO_REC_PROCESS=1 /usr/share/passwall/app.sh run_socks \
            flag="${_flag}" node=${_W} bind=127.0.0.1 socks_port=${_port} \
            config_file=${_flag}.json >>$LOG_FILE 2>&1
    fi
    while [ "$_fail" = "0" ] && [ "$_done" -lt "$_probes" ]; do
        _res=$(curl -x socks5h://127.0.0.1:${_port} -I -skL \
            --connect-timeout 3 --max-time ${_tmo} \
            -o /dev/null -w "%{http_code}:%{time_pretransfer}" "${_purl}" 2>/dev/null)
        _rc=$?
        if [ $_rc -eq 7 ]; then
            _notready=$((_notready + 1))
            [ $_notready -ge 10 ] && { _fail=1; break; }
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
            *) _fail=1 ;;
        esac
    done
    # 清理本次拉起的 SOCKS/内核（与 nt_probe_one_ip 相同）
    if [ "${standalone_enabled:-0}" = "1" ]; then
        /usr/bin/cfpick core stop --flag "$_flag" >/dev/null 2>&1
    fi
    local _pf
    for _pf in /tmp/etc/passwall/*"${_flag}"*_plugin.pid; do
        [ -s "$_pf" ] && kill -9 "$(head -n1 "$_pf")" >/dev/null 2>&1
    done
    busybox pgrep -af "${_flag}" 2>/dev/null | awk '! /cfpick\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
    rm -rf /tmp/etc/passwall/*"${_flag}"* 2>/dev/null
    [ "$_fail" = "0" ] || return 1
    [ "$_recv" -ge "$_probes" ] || return 1
    if [ $_recv -gt 0 ]; then
        NT_MON_LAT=$(echo "$_lat" | tr ' ' '\n' | grep -E '^[0-9.]+$' | \
            awk '{s+=$1; n++} END{ if(n>0) printf "%.2f", s/n*1000 }')
        [ -z "$NT_MON_LAT" ] && NT_MON_LAT=0
    fi
    return 0
}

monitor_write_state() {
    local _node=$1 _target=$2 _ip=$3 _lat=$4 _ok=$5 _fails=$6 _tmp
    mkdir -p "$MONITOR_STATE_DIR" 2>/dev/null || return 0
    _tmp="$MONITOR_STATE_DIR/.$_node.$$"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_node" "$_target" "$_ip" "$_lat" "$_ok" "$_fails" "$(date +%s)" \
        > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$MONITOR_STATE_DIR/$_node" 2>/dev/null
    rm -f "$_tmp" 2>/dev/null
}

monitor_cleanup() {
    [ "${MONITOR_CLEANED:-0}" = "1" ] && return 0
    MONITOR_CLEANED=1
    local _pf
    if [ -n "${MONITOR_FLAG:-}" ]; then
        if [ "${standalone_enabled:-0}" = "1" ]; then
            /usr/bin/cfpick core stop --flag "$MONITOR_FLAG" >/dev/null 2>&1
        fi
        for _pf in /tmp/etc/passwall/*"${MONITOR_FLAG}"*_plugin.pid; do
            [ -s "$_pf" ] && kill -9 "$(head -n1 "$_pf")" >/dev/null 2>&1
        done
        busybox pgrep -af "${MONITOR_FLAG}" 2>/dev/null | awk '! /cfpick\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
        rm -rf /tmp/etc/passwall/*"${MONITOR_FLAG}"* 2>/dev/null
    fi
    if [ -n "${MONITOR_NODE:-}" ]; then
        rm -f "$MONITOR_STATE_DIR/$MONITOR_NODE" 2>/dev/null
        lock_drop "$MONITOR_LOCK_ROOT/$MONITOR_NODE.lock"
        echolog "监测 [$(node_label "$MONITOR_NODE" 2>/dev/null)] 结束"
    fi
    return 0
}

# 派生一个后台 monitor；已有存活的 monitor 时不重复启动。
monitor_spawn() {
    local _node="$1" _script="$SCRIPT_DIR/cfpick.sh"
    [ -n "$_node" ] || return 0
    case "${monitor_enabled:-1}" in
        0|no|false|off|OFF|False|No) return 0 ;;
    esac
    [ -x "$_script" ] || return 0
    if [ -d "$WORKER_LOCK_ROOT/$_node.lock" ] && lock_owner_alive "$WORKER_LOCK_ROOT/$_node.lock"; then
        return 0
    fi
    if [ -d "$MONITOR_LOCK_ROOT/$_node.lock" ] && lock_owner_alive "$MONITOR_LOCK_ROOT/$_node.lock"; then
        return 0
    fi
    if command -v start-stop-daemon >/dev/null 2>&1; then
        start-stop-daemon -S -b -x "$_script" -- monitor --node="$_node" \
            </dev/null >>"$LOG_FILE" 2>&1 || return 0
    elif command -v setsid >/dev/null 2>&1; then
        setsid "$_script" monitor --node="$_node" </dev/null >>"$LOG_FILE" 2>&1 &
    else
        ( "$_script" monitor --node="$_node" </dev/null >>"$LOG_FILE" 2>&1 & )
    fi
    echolog "监测 [$(node_label "$_node")] 已启动：每 ${monitor_interval:-60}s 复测一次成功结果，连续 ${monitor_failures:-1} 次失败触发复测"
    return 0
}

# 新任务开始测这些 worker 时，结束它们上一轮的后台 monitor。
monitor_stop_for() {
    local _w _d _pid _age
    for _w in $1; do
        _d="$MONITOR_LOCK_ROOT/$_w.lock"
        [ -d "$_d" ] || continue
        if ! lock_owner_alive "$_d"; then
            # 刚 mkdir 还没写 pid 的锁属于正在启动的 monitor，别误删。
            if [ ! -s "$_d/pid" ]; then
                _age="$(stat -c %Y "$_d" 2>/dev/null || date -r "$_d" +%s 2>/dev/null || echo 0)"
                case "$_age" in ''|*[!0-9]*) _age=0 ;; esac
                [ "$_age" -gt 0 ] && [ $(( $(date +%s) - _age )) -lt 10 ] && continue
            fi
            rm -rf "$_d" 2>/dev/null
            continue
        fi
        _pid="$(cat "$_d/pid" 2>/dev/null)"
        [ -n "$_pid" ] || continue
        if kill "$_pid" 2>/dev/null; then
            echolog "监测 [$(node_label "$_w")] 因新任务开始而停止"
        fi
    done
}

# monitor 入口：cfpick.sh monitor --node=<id>
monitor_worker() {
    local _node="" _x
    for _x in $NODE_FILTER; do _node="$_x"; break; done
    [ -n "$_node" ] || { echolog "monitor 需要 --node"; return 2; }
    MONITOR_NODE="$_node"
    case "${monitor_enabled:-1}" in
        0|no|false|off|OFF|False|No) return 0 ;;
    esac

    local _iv="${monitor_interval:-60}" _max="${monitor_failures:-1}"
    case "$_iv" in ''|*[!0-9]*) _iv=60 ;; esac
    [ "$_iv" -ge 10 ] 2>/dev/null || _iv=10
    [ "$_iv" -le 3600 ] 2>/dev/null || _iv=3600
    case "$_max" in ''|*[!0-9]*) _max=3 ;; esac
    [ "$_max" -ge 1 ] 2>/dev/null || _max=1
    [ "$_max" -le 10 ] 2>/dev/null || _max=10

    if ! monitor_lock_take "$MONITOR_LOCK_ROOT/$_node.lock"; then
        echolog "监测 [$(node_label "$_node")] 已有监测进程，跳过"
        return 0
    fi
    MONITOR_FLAG="mon_$$"
    trap 'monitor_cleanup; exit 0' EXIT INT TERM

    if [ "${standalone_enabled:-0}" != "1" ] && [ ! -f /usr/share/passwall/app.sh ]; then
        echolog "监测 [$(node_label "$_node")] 未安装 passwall 且未启用独立内核，退出"
        monitor_cleanup
        return 0
    fi
    # PassWall 模式的 run_socks 来自 utils.sh；它会覆盖 LOG_FILE/echolog，先保存再恢复。
    if [ "${standalone_enabled:-0}" != "1" ] && [ -f /usr/share/passwall/utils.sh ]; then
        local _pws_log_file="$LOG_FILE"
        . /usr/share/passwall/utils.sh
        LOG_FILE="$_pws_log_file"
        echolog() {
            local d="$(date "+%Y-%m-%d %H:%M:%S")"
            echo -e "$d: $*"
            echo -e "$d: $*" >>$LOG_FILE
        }
    fi

    local _purl="${node_test_url:-https://www.google.com/generate_204}"
    local _tmo="${node_test_timeout:-5}" _probes="${node_test_probes:-3}"
    case "$_tmo" in ''|*[!0-9]*) _tmo=5 ;; esac
    [ "$_tmo" -ge 1 ] 2>/dev/null || _tmo=5
    case "$_probes" in ''|*[!0-9]*) _probes=3 ;; esac
    [ "$_probes" -ge 1 ] 2>/dev/null || _probes=3
    [ "$_probes" -le 5 ] 2>/dev/null || _probes=5
    # 每个 monitor 用自己的 PID 派生端口，互不冲突（每次探测结束即释放）。
    local _port=$((50000 + ($$ % 10000)))

    echolog "监测 [$(node_label "$_node")] 开始：每 ${_iv}s 复测一次成功结果，连续 ${_max} 次失败触发复测"
    local _fails=0 _domain _ip _target _ok _lat _elapsed _stop=0 _last_sig="" _sig
    while :; do
        read_config
        case "${monitor_enabled:-1}" in
            0|no|false|off|OFF|False|No)
                echolog "监测 [$(node_label "$_node")] 已关闭，退出"
                break
                ;;
        esac
        if [ -d "$WORKER_LOCK_ROOT/$_node.lock" ] && \
           lock_owner_alive "$WORKER_LOCK_ROOT/$_node.lock"; then
            echolog "监测 [$(node_label "$_node")] worker 已被新任务触发，退出监测"
            break
        fi
        if ! monitor_node_configured "$_node"; then
            echolog "监测 [$(node_label "$_node")] 已从待测节点表移除，退出"
            break
        fi

        _domain="$(monitor_ddns_domain "$_node")"
        _ip=""
        _target=""
        if [ -n "$_domain" ]; then
            _ip="$(retest_resolve_host "$_domain" | head -n1)"
            _target="$_domain"
        else
            _ip="$(monitor_result_ip "$_node")"
            _target="$_ip"
        fi
        if [ -z "$_target" ]; then
            echolog "监测 [$(node_label "$_node")] 节点已删除或没有可监测的结果，退出"
            break
        fi
        # 休眠期间可能已经跑完一次短任务：成功结果变了就换目标并清零失败计数。
        _sig="${_target}|${_ip}"
        if [ -n "$_last_sig" ] && [ "$_sig" != "$_last_sig" ]; then
            _fails=0
            echolog "监测 [$(node_label "$_node")] 成功结果已更新（${_target}），失败计数清零"
        fi
        _last_sig="$_sig"

        _ok=-1
        _lat=0
        if [ -z "$_ip" ]; then
            _ok=0
            echolog "监测 [$(node_label "$_node")] ${_target} 域名无解析"
        elif [ -d "$COMMIT_LOCK_DIR" ] && lock_owner_alive "$COMMIT_LOCK_DIR"; then
            echolog "监测 [$(node_label "$_node")] 其他任务正在下载实测，本轮跳过"
        elif nt_monitor_probe "$_node" "$_ip" "$_purl" "$_tmo" "$_probes" \
             "$_port" "${MONITOR_FLAG}_$(date +%s)"; then
            _ok=1
            _lat="$NT_MON_LAT"
        else
            _ok=0
        fi

        if [ "$_ok" = "1" ]; then
            _fails=0
            monitor_write_state "$_node" "$_target" "$_ip" "$_lat" 1 0
            echolog "监测 [$(node_label "$_node")] ${_target} 延迟 ${_lat}ms [正常]"
        elif [ "$_ok" = "0" ]; then
            _fails=$((_fails + 1))
            monitor_write_state "$_node" "$_target" "$_ip" 0 0 "$_fails"
            echolog "监测 [$(node_label "$_node")] ${_target} 失败（连续 ${_fails}/${_max} 次）"
            _tasklog_write event monitor_fail info "" "" "" "" "" \
                "监测 $(node_label "$_node") 失败（连续 ${_fails}/${_max} 次）"
            if [ "$_fails" -ge "$_max" ]; then
                _tasklog_write event monitor_retest info "" "" "" "" "" \
                    "监测 $(node_label "$_node") 连续 ${_fails} 次失败，触发该 worker 复测"
                echolog "监测 [$(node_label "$_node")] 连续 ${_max} 次失败，触发该 worker 复测"
                "$SCRIPT_DIR/cfpick.sh" retest --node="$_node" \
                    </dev/null >>"$LOG_FILE" 2>&1 &
                break
            fi
        fi

        # 等待下一分钟；期间 worker 被任务占用则立即退出，把节点让给任务。
        _elapsed=0
        while [ "$_elapsed" -lt "$_iv" ]; do
            if [ -d "$WORKER_LOCK_ROOT/$_node.lock" ] && \
               lock_owner_alive "$WORKER_LOCK_ROOT/$_node.lock"; then
                echolog "监测 [$(node_label "$_node")] worker 已被新任务触发，退出监测"
                _stop=1
                break
            fi
            sleep 1
            _elapsed=$((_elapsed + 1))
        done
        [ "$_stop" = "1" ] && break
    done
    monitor_cleanup
    return 0
}

function read_config(){
    get_global_config "enabled" "custom_cron_enabled" "custom_cron" "tl" "tll" "tlr" "ip_source" "custom_ip_file" "custom_allip" "ip_online_url" "ip_online_regions" "node_test_node" "stable_node" "node_test_url" "node_test_count" "node_test_timeout" "node_test_probes" "node_test_threads" "download_test_enabled" "download_test_count" "download_test_url" "download_test_time" "iterate_enabled" "iterate_minutes" "iterate_converge_count" "standalone_enabled" "standalone_core" "monitor_enabled" "monitor_interval" "monitor_failures"
    get_servers_config "ssr_services" "ssr_enabled" "passwall_enabled" "passwall_services" "passwall2_enabled" "passwall2_services" "bypass_enabled" "bypass_services" "vssr_enabled" "vssr_services" "DNS_enabled" "AliDNS_ip_count" "HOST_enabled" "MosDNS_enabled" "MosDNS_ip_count" "openclash_restart" "AstraDNS_enabled" "AstraDNS_config" "AstraDNS_bin"
    # 五个 CM 备选 IP 列表（ip_list 命名段 list1..list5）
    local _n
    for _n in 1 2 3 4 5; do
        eval "list${_n}_enabled=\$(uci get cfpick.list${_n}.enabled 2>/dev/null)"
        eval "list${_n}_name=\$(uci get cfpick.list${_n}.name 2>/dev/null)"
        eval "list${_n}_regions=\$(uci get cfpick.list${_n}.regions 2>/dev/null)"
        eval "list${_n}_port=\$(uci get cfpick.list${_n}.port 2>/dev/null)"
        # 该列表自己的延迟上限（ms），0/空 = 跟随全局 tl。不同地区标准不同，
        # 例：港日列表 120ms、美欧列表 300ms。
        eval "list${_n}_latency_max=\$(uci get cfpick.list${_n}.latency_max 2>/dev/null)"
    done
}

# 迁移：旧配置只有全局 ip_online_regions、无 ip_list 段时，把它写入 list1 作为默认列表。
# 仅在 ip_source==online 且 list1_regions 为空且 ip_online_regions 非空时执行一次。
function migrate_ip_online_regions(){
    [ "${ip_source:-}" = "online" ] || return 0
    [ -n "${ip_online_regions:-}" ] || return 0
    [ -z "${list1_regions:-}" ] || return 0
    uci set cfpick.list1.enabled='1'
    uci set cfpick.list1.regions="${ip_online_regions}"
    uci commit cfpick
    list1_enabled=1
    list1_regions="${ip_online_regions}"
    echolog "迁移：将旧 ip_online_regions (${ip_online_regions}) 写入 list1 作为默认 CM IP 列表"
}

# 读取 node_ip 段（匿名段）→ 建 nodeid→ip_list 映射，存入 shell 变量 node_ip_list_<nodeid>。
# 用 `uci show` 找 section 索引，再按 `cfpick.@node_ip[N].xxx` 逐项读取。不能依赖
# uci show 的字段顺序：同一个段的 .node / .ip_list 可能任意先后出现，按行顺序解析
# 会漏掉「ip_list 在 node 前面」的段，导致该 worker 静默回退到默认 list1。
# node id 形如 cfg0a1b2c，是合法 shell 变量后缀。
NODE_IP_MAP_LOADED=0
NODE_IP_WORKERS=""
function read_node_ip_map(){
    [ "$NODE_IP_MAP_LOADED" = "1" ] && return 0
    NODE_IP_WORKERS=""
    local idx _node _list
    for idx in $(uci show cfpick 2>/dev/null | \
        sed -n "s/^cfpick\.@node_ip\[\([0-9][0-9]*\)\]=node_ip$/\1/p"); do
        _node="$(uci -q get "cfpick.@node_ip[$idx].node" 2>/dev/null)"
        _list="$(uci -q get "cfpick.@node_ip[$idx].ip_list" 2>/dev/null)"
        [ -n "$_node" ] || continue
        NODE_IP_WORKERS="$NODE_IP_WORKERS $_node"
        eval "node_ip_list_${_node}=\${_list:-}"
    done
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

# 返回某 worker 所属 CM 列表的延迟上限（ms）；0 = 跟随全局 tl。
# 只在 command substitution 内调用；compute_default_ip_list 幂等，可在子 shell 里补算。
function node_latency_max(){
    local nodeid="$1" _n _v
    compute_default_ip_list
    _n=$(resolve_node_list "$nodeid")
    [ -n "$_n" ] || { echo 0; return 0; }
    eval "_v=\${list${_n#list}_latency_max:-0}"
    case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
    echo "$_v"
}

# 任务日志里的节点显示名：只显示备注名，没有备注名时回退 ID。只读，可在 $() 内调用。
function node_label(){
    local _id="$1" _name
    _name="$(uci -q get "passwall.${_id}.remarks" 2>/dev/null)"
    if [ -n "$_name" ] && [ "$_name" != "$_id" ]; then
        printf '%s' "$_name"
    else
        printf '%s' "$_id"
    fi
}

# 滚动归档上一次运行的日志，最多保留 5 份（/tmp 内存盘，重启即清，不写 flash）。
# .log.1 = 上一次运行，.log.5 = 最旧；本次运行写 .log 本体。SSH 查看：cat /tmp/cfpick.log.1
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

# 解析主机名当前指向的 IP（一行一个）。优先 resolveip；没有该命令时退回 nslookup。
retest_resolve_host() {
    local host="$1"
    [ -n "$host" ] || return 0
    if command -v resolveip >/dev/null 2>&1; then
        resolveip "$host" 2>/dev/null
        return 0
    fi
    nslookup "$host" 2>/dev/null | awk '
        /^Name:/ { seen=1; next }
        /^Address( [0-9]+)?:/ && seen { print $NF }'
}

# ── 复测现有最优 IP（retest 入口）─────────────────────────────
# 不重新下载在线列表：候选 = 各节点当前 address + DDNS 域名当前解析的 IP
# + 当前 result.csv 中该节点的行。用于对「已经优选出来的一小撮 IP」做一轮
# 延迟 + 下载实测，快速确认/重排，不必再拉 1~2 万条 CM 源。
# DDNS 节点的 address 是它自己的域名（不是 IP），若只按 address 取候选会是
# 空的、这些节点每轮都被跳过；所以额外解析 DDNS 域名，把当前发布的 IP 也
# 纳入复测（橙云代理时解析到的是 Cloudflare 节点，不能当候选，故跳过）。
build_retest_list_one() {
    # 注意：不能写成 local nodeid="$1" out="...${nodeid}..." —— shell 会先展开整条 local
    # 命令的所有 RHS 再赋值，${nodeid} 此时还未定义（set -u 下直接报 unbound variable）。
    local nodeid="$1" maxn="$2"
    local out="${RUN_DIR}/retest_ips_${nodeid}.txt"
    local remarks addr dom tmp="${out}.tmp"
    remarks=$(uci -q get "passwall.${nodeid}.remarks" 2>/dev/null)
    remarks="${remarks//,/ }"
    addr=$(uci -q get "passwall.${nodeid}.address" 2>/dev/null)
    : > "$tmp" 2>/dev/null || return 1
    # 当前已应用的地址通常就是上次的最优选，放在最前面一起复测；非 IP（域名等）跳过
    case "$addr" in
        ''|*[!0-9a-fA-F:.]*) ;;
        *) echo "$addr" >> "$tmp" ;;
    esac
    # DDNS 节点：address 是域名，用域名当前解析出的 IP 当复测候选（即上次发布的 IP）
    dom=$(nt_node_ddns_domain "$nodeid" 2>/dev/null)
    if [ -n "$dom" ] && [ "$(uci -q get cfpick.global.ddns_proxied 2>/dev/null)" != "1" ]; then
        retest_resolve_host "$dom" >> "$tmp"
    fi
    if [ -f "$IP_FILE" ] && [ -n "$remarks" ]; then
        sed -n '2,$p' "$IP_FILE" 2>/dev/null | grep -av '^#' | \
            awk -F, -v n="$remarks" -v id="$nodeid" \
                'NF>=8 && $1!="" && ((NF>=9 && $9!="" && $9==id) || ((NF<9 || $9=="") && $8==n)) {print $1}' >> "$tmp"
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
        node_selected "$_w" || continue
        case " $_seen " in *" $_w "*) continue ;; esac
        _seen="$_seen $_w"
        build_retest_list_one "$_w" "$maxn" && _any=1
    done
    [ "$_any" = "1" ]
}

# 持久历史：把每次合并的「各节点最优」追加到 /etc/cfpick/history.csv。
# /tmp 下的 result.csv.* 是内存盘（重启即清）且仅 10 份，图表的长期历史依赖此文件。
# 格式与 result.csv 兼容：每块以 "# Speed test time: ..." 开头，其后为该次各节点最优行
# （全局延迟升序中每节点首次出现的行），每次 ≤ 待测节点数行。行数超限尾部修剪。
HISTORY_DIR=/etc/cfpick
HISTORY_MAX_LINES=5000
function append_persistent_history(){
    local mfile="$1"
    [ -f "$mfile" ] || return 0
    if mkdir -p "$HISTORY_DIR" 2>/dev/null; then
        {
            grep -a '^# Speed test time:' "$mfile" | head -n1
            sed -n '2,$p' "$mfile" | grep -av '^#' | \
                awk -F, 'NF>=8 && $1!="" && $8!="" { k=(NF>=9 && $9!="")?$9:$8; if (!seen[k]++) print }'
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

# ── 任务日志（/etc/cfpick/tasklog.tsv）────────────────────────────
# 每次测速开始/结束和运行中的特殊处理各写一行，供操作台「日志 → 任务日志」读取。
# 与 debian/cfpick/tasklog.py 同格式（制表符分隔，11 列）：
#   时间 kind mode status 最优节点 最优IP 延迟 速度 DDNS 说明 各节点明细
# 明细格式 node|ip|latency|speed|status|method，多条用 ; 分隔；
# status = ok/fail/abnormal，method = writeback/ddns/-。
# 写文件失败只影响这条记录，不能影响测速本身。
TASKLOG_FILE="$HISTORY_DIR/tasklog.tsv"
TASKLOG_MAX_LINES=400
TASKLOG_DDNS_STATUS="-"
TASKLOG_DETAILS=""
TASKLOG_DETAIL_IDS=""

_tasklog_clean(){
    printf '%s' "$1" | tr '\t\r\n' '   '
}

_tasklog_write(){
    local _kind="$1" _mode="$2" _status="$3" _node="$4" _ip="$5" \
        _lat="$6" _spd="$7" _ddns="$8" _msg="$9" _details="${10:-}" _lines
    [ -n "$TASKLOG_FILE" ] || return 0
    mkdir -p "$HISTORY_DIR" 2>/dev/null || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date +'%Y-%m-%d %H:%M:%S')" \
        "$(_tasklog_clean "$_kind")" "$(_tasklog_clean "$_mode")" \
        "$(_tasklog_clean "$_status")" "$(_tasklog_clean "$_node")" \
        "$(_tasklog_clean "$_ip")" "$(_tasklog_clean "$_lat")" \
        "$(_tasklog_clean "$_spd")" "$(_tasklog_clean "$_ddns")" \
        "$(_tasklog_clean "$_msg")" "$(_tasklog_clean "$_details")" \
        >> "$TASKLOG_FILE" 2>/dev/null
    _lines=$(wc -l < "$TASKLOG_FILE" 2>/dev/null)
    case "$_lines" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_lines" -gt "$TASKLOG_MAX_LINES" ]; then
        tail -n "$TASKLOG_MAX_LINES" "$TASKLOG_FILE" > "${TASKLOG_FILE}.new" 2>/dev/null && \
            mv -f "${TASKLOG_FILE}.new" "$TASKLOG_FILE" 2>/dev/null
    fi
}

# 追加一个节点的本次结果。$1=worker id $2=显示名 $3=ok/fail/abnormal
# $4=IP $5=延迟 $6=速度 $7=writeback/ddns/-
_tasklog_detail(){
    local _id="$1" _name="$2" _status="$3" _ip="$4" _lat="$5" _spd="$6" _method="$7" _entry
    _name=$(printf '%s' "$_name" | tr '|;\t\r\n' '     ')
    case "$_lat" in ''|*[!0-9.]*) _lat=0 ;; esac
    case "$_spd" in ''|*[!0-9.]*) _spd=0 ;; esac
    _entry="${_name}|${_ip}|${_lat}|${_spd}|${_status}|${_method}"
    if [ -n "$TASKLOG_DETAILS" ]; then
        TASKLOG_DETAILS="${TASKLOG_DETAILS};${_entry}"
    else
        TASKLOG_DETAILS="$_entry"
    fi
    TASKLOG_DETAIL_IDS="${TASKLOG_DETAIL_IDS} ${_id}"
}

# 取结果文件最优数据行的「延迟 速度」（tab 分隔）。$1=结果文件
_tasklog_metrics(){
    sed -n '2,$p' "$1" 2>/dev/null | awk -F, '
        /^#/ || NF < 7 || $1 == "" { next }
        { printf "%s\t%s", $5, $6; exit }'
}

# 本次任务的最优行（节点 \t IP \t 延迟 \t 速度）；只统计本次实际测的 worker。
# $1=结果文件  $2=worker id 列表（空格分隔；为空表示不限）
_tasklog_best(){
    # 跳过首行表头，与 first_result_ip 一致。
    sed -n '2,$p' "$1" 2>/dev/null | awk -F, -v ids=" $2 " '
        /^#/ || NF < 7 || $1 == "" { next }
        {
            id = (NF >= 9) ? $9 : ""
            if (ids != "  " && id != "" && index(ids, " " id " ") == 0) next
            node = (NF >= 8 && $8 != "") ? $8 : id
            printf "%s\t%s\t%s\t%s", node, $1, $5, $6
            exit
        }' 2>/dev/null
}

# 任务结束记录。$1=mode  $2=退出码
_tasklog_finish(){
    local _mode="$1" _rc="$2" _status="failed" _msg="" _best="" _tab \
        _node="" _ip="" _lat="" _spd="" _ddns="$TASKLOG_DDNS_STATUS" \
        _id _dname _ok=0 _fail=0 _abn=0 _total=0
    [ "$_rc" -eq 0 ] && _status="ok"
    [ "$_status" != "ok" ] && [ -f "${RUN_DIR}/.user_stop" ] && _status="stopped"
    # 没有明细的 worker（中止/异常）补齐为 abnormal：沿用上一次结果，本次未更新。
    for _id in $RUN_WORKERS; do
        case " $TASKLOG_DETAIL_IDS " in
            *" $_id "*) ;;
            *)
                _dname="$(node_label "$_id")"
                _tasklog_detail "$_id" "$_dname" abnormal "" 0 0 "-"
                ;;
        esac
    done
    # 统计成功 / 失败 / 异常。用 tr+grep 而不是 for 展开：节点名可能带 [] * ?，
    # 未加引号的展开会被当作通配符。
    _total=$(printf '%s\n' "$TASKLOG_DETAILS" | tr ';' '\n' | grep -c .)
    _ok=$(printf '%s\n' "$TASKLOG_DETAILS" | tr ';' '\n' | grep -c '|ok|')
    _fail=$(printf '%s\n' "$TASKLOG_DETAILS" | tr ';' '\n' | grep -c '|fail|')
    _abn=$((_total - _ok - _fail))
    [ "$_abn" -ge 0 ] 2>/dev/null || _abn=0
    local _label="测速"
    [ "$_mode" = "retest" ] && _label="复测"
    case "$_status" in
        ok) _msg="${_label}任务成功：成功 ${_ok} · 失败 ${_fail} · 异常 ${_abn}" ;;
        stopped) _msg="${_label}任务已停止：成功 ${_ok} · 失败 ${_fail} · 异常 ${_abn}" ;;
        *) _msg="${_label}任务失败：成功 ${_ok} · 失败 ${_fail} · 异常 ${_abn}" ;;
    esac
    if [ "$_ddns" = "-" ]; then
        if [ "$(uci -q get cfpick.global.ddns_enabled 2>/dev/null)" = "1" ]; then
            _ddns="未写入"
        else
            _ddns="未启用"
        fi
    fi
    # 失败/中止时 result.csv 还是上一次的结果，不能当成本次任务的成绩展示。
    if [ "$_status" = "ok" ] && [ -f "$IP_FILE" ]; then
        _best=$(_tasklog_best "$IP_FILE" "$RUN_WORKERS")
    fi
    if [ -n "$_best" ]; then
        _tab="$(printf '\t')"
        _node="${_best%%"$_tab"*}"; _best="${_best#*"$_tab"}"
        _ip="${_best%%"$_tab"*}"; _best="${_best#*"$_tab"}"
        _lat="${_best%%"$_tab"*}"; _spd="${_best#*"$_tab"}"
    fi
    _tasklog_write result "$_mode" "$_status" "$_node" "$_ip" "$_lat" "$_spd" \
        "$_ddns" "$_msg" "$TASKLOG_DETAILS"
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

# 并发任务共享 result.csv：每次提交只替换本次 worker 的行，其他 worker 的行原样保留。
# 调用方必须已持有 commit 锁（避免两次 awk+mv 互相覆盖）。
# 参数: $1=本次运行的 merged 文件（含表头/数据/时间行） $2=本次 worker 列表
function merge_run_result(){
    local _merged="$1" _workers="$2"
    local _tmp="${RESULT_DIR}/result.csv.merge.$$"
    local _old="${RESULT_DIR}/result.csv.old.$$"
    local _map="${RUN_DIR}/merge_map.$$"
    local _w _name
    : > "$_map"
    for _w in $_workers; do
        _name="$(uci -q get "passwall.${_w}.remarks" 2>/dev/null)"; _name="${_name:-$_w}"
        _name="${_name//,/ }"
        printf '%s,%s\n' "$_w" "$_name" >> "$_map"
    done
    rm -f "$_old"
    if [ -s "$IP_FILE" ]; then
        sed '1d' "$IP_FILE" 2>/dev/null | grep -av '^#' > "$_old"
    fi
    {
        if [ -s "$IP_FILE" ]; then
            sed -n '1p' "$IP_FILE"
        else
            echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码,节点,节点ID"
        fi
        [ -s "$_old" ] && awk -F, '
            NR==FNR { ids[$1]=1; names[$2]=1; next }
            { if (($9 != "" && ($9 in ids)) || ($9 == "" && ($8 in names))) next; print }
        ' "$_map" "$_old"
        sed '1d' "$_merged" 2>/dev/null | grep -av '^#'
    } > "$_tmp"
    sort_result "$_tmp"
    echo "# Speed test time: $(date +'%Y-%m-%d %H:%M:%S')" >> "$_tmp"
    if [ -s "$_tmp" ] && mv -f "$_tmp" "$IP_FILE" 2>/dev/null; then
        rm -f "$_old" "$_map"
        return 0
    fi
    rm -f "$_tmp" "$_old" "$_map"
    return 1
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
    # 另一个任务正在下载实测时，先别开始探测/拉候选，避免抢带宽把对方测速测偏。
    wait_while_downloading || { echolog "等待对方下载时收到停止，本次中止"; return 1; }
    # 日志只在整次测速入口处理一次：上次运行日志滚动归档为 .log.1~.log.5。
    # 并发任务共用 /tmp/cfpick.log，还有别的任务在跑时不能轮转，否则会把对方
    # 正在写的日志挪走；单任务时保持原来的滚动行为。
    nt_other_runs_active || rotate_log_files
    # 节点 -> DDNS 域名映射：配置了域名的节点只写 DNS、不回写 passwall。
    nt_build_ddns_map
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
            echolog "════ 复测现有最优 IP（候选来自 result.csv / 节点当前 address / DDNS 域名解析，限时迭代，不重新下载在线列表）════"
        iterate_speed_test
        _rc=$?
    elif [ "${RETEST_FROM_RESULT:-0}" = "1" ]; then
        # 复测现有最优 IP：单轮延迟 + 下载实测
        echolog "════ 复测现有最优 IP（一轮延迟 + 下载实测，候选含 DDNS 域名解析，不重新下载在线列表）════"
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

# 把 node→IP 映射写进 /etc/config/passwall：只改映射里出现的节点，其余行原样输出。
# 并发任务共享 /etc/config/passwall，绝不能整份还原/覆盖别人正在测的节点。
# 调用方须持有 uci 锁。参数: $1 = map 文件（node<TAB>ip）
nt_write_address_map() {
    local _edits="$1" _tmp _um
    [ -s "$_edits" ] || return 1
    # 直写文件前丢掉残留 session delta，否则之后的 uci commit 会把陈旧 address 刷回来。
    uci -q revert passwall 2>/dev/null
    rm -f /etc/config/.cfpick.* 2>/dev/null
    _tmp="$(mktemp /etc/config/.cfpick.XXXXXX)" || { echolog "创建配置临时文件失败"; return 1; }
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
        "$_edits" /etc/config/passwall > "$_tmp"
    umask "$_um"
    chmod 600 "$_tmp" 2>/dev/null
    if [ ! -s "$_tmp" ] || ! mv -f "$_tmp" /etc/config/passwall 2>/dev/null; then
        rm -f "$_tmp"
        echolog "警告：写回 /etc/config/passwall 失败"
        return 1
    fi
    return 0
}

# 只还原本次运行的 worker 到测前 address（从 NT_ORIG_FILE 的第三列取原值）。
nt_restore_orig_addresses() {
    local _map _idx _mw _orig _rc
    _map="$(mktemp "${RUN_DIR}/restore_orig.XXXXXX")" || return 1
    if [ -n "${NT_ORIG_FILE}" ] && [ -s "${NT_ORIG_FILE}" ]; then
        while read -r _idx _mw _orig; do
            [ -n "$_mw" ] || continue
            printf '%s\t%s\n' "$_mw" "$_orig" >> "$_map"
        done < "$NT_ORIG_FILE"
    elif [ -n "${NODE_TEST_NODE}" ] && [ -n "${NODE_TEST_ORIG_ADDR}" ]; then
        printf '%s\t%s\n' "$NODE_TEST_NODE" "$NODE_TEST_ORIG_ADDR" > "$_map"
    else
        rm -f "$_map"
        return 1
    fi
    nt_lock_acquire
    nt_write_address_map "$_map"
    _rc=$?
    nt_lock_release
    rm -f "$_map"
    return $_rc
}

# 失败/中断/结果为空：只回滚本次 worker，别的任务正在测的节点不动。
nt_rollback() {
    if { [ -z "${NT_ORIG_FILE}" ] || [ ! -s "${NT_ORIG_FILE}" ]; } &&
       { [ -z "${NODE_TEST_NODE}" ] || [ -z "${NODE_TEST_ORIG_ADDR}" ]; }; then
        return 0
    fi
    # 只取 uci 锁（写文件本身的互斥），不排 commit 队列：被停止的任务不能为了回滚
    # 去等另一个任务几分钟的下载。
    if nt_restore_orig_addresses; then
        echolog "已回滚本次 worker 的 passwall address（其余 worker 不动）"
        nt_request_passwall_reload
    else
        echolog "警告：回滚本次 worker 的 address 失败"
    fi
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
    local _mw _ip _edits _mismatch="" _count=0
    NT_NO_PASSWALL_RESTART=0
    _edits="$(mktemp "${RUN_DIR}/node_test_edits.XXXXXX")" || { echolog "创建写回清单失败"; return 1; }
    # 守护：被测 worker 须仍在当前 passwall 配置里（防订阅更新重排后把 address 写进空段）。
    # 用当前文件而不是测前快照判断——并发任务可能已经改过其他节点。
    if [ -s "$_rf" ]; then
        while read -r _mw _ip; do
            [ -n "$_mw" ] && [ -n "$_ip" ] || continue
            if grep -q "^config [A-Za-z0-9_]* '${_mw}'" /etc/config/passwall 2>/dev/null; then
                printf '%s\t%s\n' "$_mw" "$_ip" >> "$_edits"
                _count=$((_count + 1))
            else
                echolog "worker ${_mw} 在 passwall 配置中已不存在，跳过写回"
            fi
        done < "$_rf"
    fi
    if [ "$_count" -eq 0 ]; then
        # 没有要写回的节点（全部走 DDNS）：只把本次 worker 的 address 还原到测前值。
        rm -f "$_edits"
        if nt_restore_orig_addresses; then
            NT_SNAPSHOT_REAPPLIED=1
            echolog "本次无需写回 passwall（节点均已配置 DDNS），已还原本次 worker 的测前 address"
            return 0
        fi
        return 1
    fi
    # 混合场景：DDNS 节点不在 _edits 里，但探测期间它们的 address 也被改写成了
    # 候选 IP。这里把未被写回新最优的 worker 还原到测前 address（通常是域名），
    # 否则 DDNS 节点会停在被探测过的某个 IP 上，不再跟随 DNS（后台监测也会因此
    # 测到旧 IP 而不是域名）。
    if [ -n "${NT_ORIG_FILE}" ] && [ -s "${NT_ORIG_FILE}" ]; then
        local _oi _ow _oip
        while read -r _oi _ow _oip; do
            [ -n "$_ow" ] && [ -n "$_oip" ] || continue
            grep -q "^config [A-Za-z0-9_]* '${_ow}'" /etc/config/passwall 2>/dev/null || continue
            awk -F '\t' -v n="$_ow" '$1 == n { found = 1 } END { exit(found ? 0 : 1) }' \
                "$_edits" && continue
            printf '%s\t%s\n' "$_ow" "$_oip" >> "$_edits"
        done < "$NT_ORIG_FILE"
    fi
    nt_lock_acquire
    if ! nt_write_address_map "$_edits"; then
        nt_lock_release
        rm -f "$_edits"
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
    nt_lock_release
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
        busybox pgrep -af "${NODE_TEST_FLAG_BASE}" 2>/dev/null | awk '! /cfpick\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
        rm -rf /tmp/etc/passwall/*"${NODE_TEST_FLAG_BASE}"* 2>/dev/null
    fi
    nt_lock_release
    # 成功路径已由 success 代码自行「还原快照 + 重放 address + restart」并置
    # NT_SNAPSHOT_REAPPLIED=1，此处跳过；失败/中断/结果为空路径走整份回滚（含 address 与全局节点 node/tcp_node）。
    if [ "${NT_SNAPSHOT_REAPPLIED:-0}" != "1" ]; then
        nt_rollback
    fi
    nt_restore_global_node
    commit_lock_release
    rm -f "${NT_SNAP_FILE}" "${NT_ORIG_FILE}" 2>/dev/null
    # 清理首完成即停用的完成标记、迭代轮次临时结果、轮次 meta 与停止标志（含中断退出残留）；
    # .nt_committing 是「提交阶段勿强杀」标记，正常路径收尾已删，这里兜底中途退出的残留
    rm -f "${RUN_DIR}"/result.csv.tmp.*.done "${RUN_DIR}"/result.csv.tmp.*.end "${RUN_DIR}"/result.csv.tmp.*.pass "${RUN_DIR}"/result.csv.tmp.*.probed "${RUN_DIR}"/result.csv.tmp.*.carry "${RUN_DIR}"/result.csv.tmp.*.union "${RUN_DIR}"/result.csv.tmp.*.meta "${RUN_DIR}/.nt_stop" "${RUN_DIR}/.nt_committing" "${RUN_DIR}/.user_stop" 2>/dev/null
}

# uci staging 是跨进程共享的，这里用一把全局锁（不再放在会话目录里）。
nt_lock_acquire() {
    local _i=0 _pid
    while ! mkdir "${NT_LOCKDIR}" 2>/dev/null; do
        _pid="$(cat "${NT_LOCKDIR}/pid" 2>/dev/null)"
        if [ -z "$_pid" ]; then
            # 旧版本留下的无主目录，或进程在 mkdir 与写 pid 之间被杀。
            rm -rf "${NT_LOCKDIR}" 2>/dev/null
            continue
        fi
        _i=$((_i + 1))
        if [ "$_i" -ge 30 ]; then
            echolog "警告：uci 串行锁等待超 30s，强制接管（疑有 worker 僵死）"
            rm -rf "${NT_LOCKDIR}" 2>/dev/null
            mkdir "${NT_LOCKDIR}" 2>/dev/null
            echo "$$" > "${NT_LOCKDIR}/pid" 2>/dev/null
            return 0
        fi
        # 用整数秒：部分 busybox 未启用浮点 sleep（LEDE 24.10 实测 `sleep 0.1` 直接报错
        # 且不睡眠），会让锁超时瞬间触发。30 次 × 1s = 30s，与提示一致。
        sleep 1
    done
    echo "$$" > "${NT_LOCKDIR}/pid" 2>/dev/null
}
nt_lock_release() {
    [ "$(cat "${NT_LOCKDIR}/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -rf "${NT_LOCKDIR}" 2>/dev/null
}

# ── 独立内核 / DDNS 辅助 ────────────────────────────────────────────────
# 独立内核模式（设置页「独立测速」启用）：用本机 mihomo/Xray 拉起候选 IP 的
# 本地 SOCKS（cfpick core start），不再调用 passwall 的 run_socks。cfpick 会把
# passwall 的 UCI 节点转换成内核配置并打 mark 255；失败（节点类型不兼容、
# 内核未安装等）时回退 run_socks，保证统一测速不中断。
nt_start_node_socks() {
    local _W=$1 _ip=$2 _port=$3 _flag=$4
    mkdir -p /tmp/etc/passwall 2>/dev/null
    if [ "${standalone_enabled:-0}" = "1" ]; then
        if /usr/bin/cfpick core start --node "$_W" --ip "$_ip" --port "$_port" \
             --core "${standalone_core:-xray}" --flag "$_flag" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        # 只写日志、不写 stdout：nt_probe_one_ip 的 stdout 是探测结果，混入日志行
        # 会让调用方把日志当结果解析，整轮 IP 被误判为 [丢弃]。
        echolog "独立内核启动失败（节点 ${_W}，内核 ${standalone_core:-xray}），回退 PassWall run_socks" >/dev/null
        # 回退路径需要 run_socks 从节点 address 读候选 IP；独立内核分支平时不改写
        # address，这里补一次（带 uci 串行锁，避免多 worker 并发丢更新）。
        nt_lock_acquire
        uci set passwall.${_W}.address="${_ip}" 2>/dev/null
        uci commit passwall 2>/dev/null
        nt_lock_release
    fi
    NO_REC_PROCESS=1 /usr/share/passwall/app.sh run_socks \
        flag="${_flag}" node=${_W} bind=127.0.0.1 socks_port=${_port} \
        config_file=${_flag}.json >>$LOG_FILE 2>&1
}

# 节点配置了 DDNS 域名时，最优 IP 只写 DNS、不回写 passwall 节点。映射在
# 会话目录里建一次（node<TAB>domain）；结果不依赖 passwall 节点 address。
nt_build_ddns_map() {
    NT_DDNS_MAP="${RUN_DIR}/ddns_domains"
    : > "$NT_DDNS_MAP" 2>/dev/null || { NT_DDNS_MAP=""; return 0; }
    local _sec _node _dom
    for _sec in $(uci -q show cfpick 2>/dev/null | \
            sed -n "s/^\(cfpick\.@node_ip\[[0-9]*\]\)\.node=.*/\1/p"); do
        _node=$(uci -q get "${_sec}.node" 2>/dev/null)
        _dom=$(uci -q get "${_sec}.ddns_domain" 2>/dev/null)
        [ -n "$_node" ] && [ -n "$_dom" ] && printf '%s\t%s\n' "$_node" "$_dom" >> "$NT_DDNS_MAP"
    done
    return 0
}
nt_node_has_ddns() {
    # DDNS 总开关关闭时，即使节点填了域名也照旧写回 passwall。
    [ "$(uci -q get cfpick.global.ddns_enabled 2>/dev/null)" = "1" ] || return 1
    [ -n "${NT_DDNS_MAP:-}" ] && [ -s "$NT_DDNS_MAP" ] || return 1
    awk -F '\t' -v n="$1" '$1 == n { found=1 } END { exit(found ? 0 : 1) }' "$NT_DDNS_MAP"
}
nt_node_ddns_domain() {
    [ "$(uci -q get cfpick.global.ddns_enabled 2>/dev/null)" = "1" ] || return 0
    [ -n "${NT_DDNS_MAP:-}" ] && [ -s "$NT_DDNS_MAP" ] || return 0
    awk -F '\t' -v n="$1" '$1 == n { print $2; exit }' "$NT_DDNS_MAP"
}

# 下载实测的串行性由结构保证：所有 worker 停止后，主进程按 worker 顺序逐个执行
# nt_download_stage；跨任务的下载/写回由 commit_lock 全局排队（后到者等待）。

# 测速前把 passwall 全局主节点切到稳定节点，结束时还原。并发任务共用同一个稳定
# 节点，用引用计数：第一个切换并记下原值，最后一个结束时才还原，避免先结束的
# 任务把仍在运行的任务的全局节点改回去。
STABLE_DIR="$RESULT_DIR/.stable"

nt_stable_cleanup_markers() {
    local _m _pid
    for _m in "$STABLE_DIR"/pid.*; do
        [ -e "$_m" ] || continue
        _pid="${_m##*/pid.}"
        if [ ! -d "/proc/$_pid" ] || ! grep -q 'cfpick\.sh' "/proc/$_pid/cmdline" 2>/dev/null; then
            rm -f "$_m"
        fi
    done
}

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

    nt_lock_acquire
    mkdir -p "$STABLE_DIR" 2>/dev/null
    nt_stable_cleanup_markers
    local _eff
    _eff="$(uci -q get passwall.@global[0].node 2>/dev/null)"
    [ -n "$_eff" ] || _eff="$(uci -q get passwall.@global[0].tcp_node 2>/dev/null)"

    if [ -f "$STABLE_DIR/orig" ]; then
        # 已有任务切换过：只登记引用，让最后一个任务负责还原。
        touch "$STABLE_DIR/pid.$$"
        [ "$_eff" = "$_s" ] || {
            uci set passwall.@global[0].node="${_s}"
            uci set passwall.@global[0].tcp_node="${_s}"
            uci commit passwall
        }
        nt_lock_release
        NT_TCP_SWITCHED=1
        return 0
    fi

    if [ "$_eff" = "$_s" ]; then
        # 用户本来就把全局节点设成了稳定节点：无需切换，也无需还原。
        nt_lock_release
        return 0
    fi

    NT_ORIG_NODE="$(uci -q get passwall.@global[0].node 2>/dev/null)"
    NT_ORIG_TCP_NODE="$(uci -q get passwall.@global[0].tcp_node 2>/dev/null)"
    printf 'node=%s\ntcp_node=%s\n' "$NT_ORIG_NODE" "$NT_ORIG_TCP_NODE" > "$STABLE_DIR/orig"
    touch "$STABLE_DIR/pid.$$"
    local _warn=""
    if [ -n "$NT_ORIG_NODE" ] && [ "$(config_n_get "$NT_ORIG_NODE" protocol)" = "_shunt" ]; then
        _warn="；原主节点 ${NT_ORIG_NODE} 是分流节点，测速期间分流规则暂停、流量全走稳定节点"
    fi
    echolog "切换 passwall 全局节点到稳定节点 ${_s}（原 node=${NT_ORIG_NODE:-无} / tcp_node=${NT_ORIG_TCP_NODE:-无}）${_warn}"
    uci set passwall.@global[0].node="${_s}"
    uci set passwall.@global[0].tcp_node="${_s}"
    uci commit passwall
    nt_lock_release
    /etc/init.d/passwall restart >/dev/null 2>&1 || echolog "警告：passwall restart 失败，节点切换可能未实时生效"
    NT_TCP_SWITCHED=1
}

nt_restore_global_node() {
    [ "${NT_TCP_SWITCHED:-0}" = "1" ] || return 0
    NT_TCP_SWITCHED=0
    nt_lock_acquire
    rm -f "$STABLE_DIR/pid.$$" 2>/dev/null
    nt_stable_cleanup_markers
    local _m _left=0
    for _m in "$STABLE_DIR"/pid.*; do
        [ -e "$_m" ] && { _left=1; break; }
    done
    if [ "$_left" = "1" ] || [ ! -f "$STABLE_DIR/orig" ]; then
        nt_lock_release
        return 0
    fi
    local _on _ot
    _on="$(sed -n 's/^node=//p' "$STABLE_DIR/orig" 2>/dev/null)"
    _ot="$(sed -n 's/^tcp_node=//p' "$STABLE_DIR/orig" 2>/dev/null)"
    uci set passwall.@global[0].node="${_on}"
    uci set passwall.@global[0].tcp_node="${_ot}"
    uci commit passwall
    rm -f "$STABLE_DIR/orig" 2>/dev/null
    nt_lock_release
    echolog "恢复 passwall 全局节点（node=${_on:-无} / tcp_node=${_ot:-无}）"
    nt_request_passwall_reload
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

# 对单个候选 IP 经节点 $_W 探测一次（uci 改 address 或独立内核 → probes 次 curl → 清理）。
# 供普通 worker 与迭代 worker 共用。uci set+commit 经锁串行化；核心启动+探测在锁外并行。
# stdout 输出一行: "keep sent recv loss avg"（keep=1 保留/0 丢弃）；日志不走 stdout。
# 参数: $1=node $2=ip $3=probe_url $4=timeout $5=probes $6=socks_port $7=flag
#       $8=该节点所属列表的延迟上限 ms（0/空 = 跟随全局 tl）
nt_probe_one_ip() {
    local _W=$1 _ip=$2 _purl=$3 _tmo=$4 _probes=$5 _port=$6 _flag=$7 _cap=${8:-0}
    # 独立内核模式不改写节点 address；PassWall 模式仍需写 address 供 run_socks 读取。
    if [ "${standalone_enabled:-0}" != "1" ]; then
        # uci set+commit 加锁（防多 worker 并发改 staging 丢更新）
        nt_lock_acquire
        uci set passwall.${_W}.address="${_ip}"
        uci commit passwall
        nt_lock_release
    fi
    # 拉本地 SOCKS（passwall 重启/异常时可能清掉该目录，缺目录会导致写配置失败）
    mkdir -p /tmp/etc/passwall 2>/dev/null
    nt_start_node_socks "$_W" "$_ip" "$_port" "$_flag"
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
    # 清理本次 SOCKS（独立内核用 cfpick 的 pid 精确停掉，下面的 pgrep 再兜底）
    if [ "${standalone_enabled:-0}" = "1" ]; then
        /usr/bin/cfpick core stop --flag "$_flag" >/dev/null 2>&1
    fi
    local _pf
    for _pf in /tmp/etc/passwall/*"${_flag}"*_plugin.pid; do
        [ -s "$_pf" ] && kill -9 "$(head -n1 "$_pf")" >/dev/null 2>&1
    done
    busybox pgrep -af "${_flag}" 2>/dev/null | awk '! /cfpick\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
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
        # 列表自带的延迟上限优先；未设置（0）时回退到全局 tl。
        local _tcap="$_cap"
        [ "$_tcap" -gt 0 ] 2>/dev/null || _tcap="${tl:-0}"
        if [ -n "${_tcap:-}" ] && [ "$_tcap" -gt 0 ] 2>/dev/null; then
            [ "$(awk -v v=$_avg -v c=$_tcap 'BEGIN{print (v>c)?1:0}')" = "1" ] && _keep=0
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
    # 独立内核模式不改写节点 address；PassWall 模式仍需写 address 供 run_socks 读取。
    if [ "${standalone_enabled:-0}" != "1" ]; then
        nt_lock_acquire
        uci set passwall.${_W}.address="${_ip}"
        uci commit passwall
        nt_lock_release
    fi
    mkdir -p /tmp/etc/passwall 2>/dev/null
    # 先删掉同 flag 的旧配置：保证下面校验用的一定是本次刚生成的文件，而不是历史残留
    # （flag 含 PID+IP 序号，正常情况下不会重名，这里再兜一层）。独立内核用 .yaml。
    rm -f "/tmp/etc/passwall/${_flag}.json" "/tmp/etc/passwall/${_flag}.yaml" \
        "/tmp/etc/passwall/${_flag}.json_test.log" 2>/dev/null
    nt_start_node_socks "$_W" "$_ip" "$_port" "$_flag"
    # ── 链路校验：证明下载确实经过候选 IP ──
    # 本次生成的客户端配置写在 /tmp/etc/passwall/<flag>.json（Xray/run_socks）或
    # <flag>.yaml（mihomo）。这份配置就是本地 SOCKS 进程实际使用的出站配置，其中出站
    # 服务器地址必须是我们刚写入节点 address / 传给 cfpick 的候选 IP。文件缺失或不含该 IP
    # 时，测出的速度与候选 IP 无关，直接判本次失败，绝不把脏速度写进结果。
    local _cfg="/tmp/etc/passwall/${_flag}.json" _verify=1
    [ -s "$_cfg" ] || _cfg="/tmp/etc/passwall/${_flag}.yaml"
    if [ ! -s "$_cfg" ]; then
        _verify=0
        echolog "下载测速校验失败：内核配置 ${_cfg} 不存在（未生成配置），跳过该 IP"
    elif ! grep -qF -- "$_ip" "$_cfg" 2>/dev/null; then
        _verify=0
        echolog "下载测速校验失败：内核配置未指向候选 IP ${_ip}，跳过该 IP"
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
    # 清理本次 SOCKS（独立内核用 cfpick 的 pid 精确停掉，下面的 pgrep 再兜底）
    if [ "${standalone_enabled:-0}" = "1" ]; then
        /usr/bin/cfpick core stop --flag "$_flag" >/dev/null 2>&1
    fi
    for _pf in /tmp/etc/passwall/*"${_flag}"*_plugin.pid; do
        [ -s "$_pf" ] && kill -9 "$(head -n1 "$_pf")" >/dev/null 2>&1
    done
    busybox pgrep -af "${_flag}" 2>/dev/null | awk '! /cfpick\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
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
# 只在所有 worker 停止探测后由 nt_download_stage 调用；主进程顺序执行，天然串行。
# 参数: $1=node $2=result_file $3=node_name $4=count $5=url $6=timeout $7=socks_port $8=flag
nt_download_phase() {
    local _W=$1 _rfile=$2 _Wn=$3 _cnt=$4 _durl=$5 _tmo=$6 _port=$7 _flag=$8
    local _rows="${_rfile}.rows" _out="${_rfile}.dl" _line _ip _spd _hdr
    local _i=0 _n _tested=0 _failed=0 _best_ip='' _best_spd=0
    # 供 nt_download_stage 判断该节点是否需要复测一轮；早退（没有候选行）不算失败。
    NT_DL_FAILED=0
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
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        _i=$((_i + 1))
        if [ "$_i" -le "$_cnt" ]; then
            _ip="${_line%%,*}"
            # 每个 IP 一个独立 flag/config 文件，杜绝复用上一个 IP 的 SOCKS 配置。
            # 本函数只在所有 worker 停止后由主进程顺序调用，不存在并发下载，速度可比。
            # 结果走全局 NT_DL_SPEED（函数内部会 echolog，不能用 $(...) 抓 stdout）。
            nt_download_one_ip "$_W" "$_ip" "$_durl" "$_tmo" "$_port" "${_flag}_${_i}"
            _spd="$NT_DL_SPEED"
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
        NT_DL_FAILED=1
    fi
    return 0
}

# 对单个 worker 的结果文件做下载实测。调用方必须保证此刻所有 worker 都已停止探测/下载，
# 否则其它 worker 的 SOCKS 与探测流量会和本次下载争抢 WAN 带宽，速度数字不可比。
# 参数: $1=node $2=result_file $3=socks_port $4=flag
nt_download_worker() {
    local _W=$1 _rfile=$2 _port=$3 _flag=$4 _Wn
    [ -f "$_rfile" ] || return 0
    [ -n "$(first_result_ip "$_rfile")" ] || return 0
    _Wn="$(uci -q get "passwall.${_W}.remarks" 2>/dev/null)"; _Wn="${_Wn:-${_W}}"
    nt_download_phase "$_W" "$_rfile" "$_Wn" "${DL_TEST_COUNT:-5}" \
        "${DL_TEST_URL:-https://speed.cloudflare.com/__down?bytes=10000000}" \
        "${DL_TEST_TIME:-10}" "$_port" "$_flag"
}

# 下载全部失败的节点：等其他 worker 的下载结束后，按现有 result.csv + 节点 address
# 重新完整复测一轮（延迟探测 + 下载实测）。复测拿到有效下载速度才替换原结果；
# 仍全失败则保留上一轮延迟排序结果。
# 参数: $1=idx $2=node $3=origaddr $4=原结果文件 $5=socks_port
nt_retest_failed_worker() {
    local _idx=$1 _W=$2 _orig=$3 _rfile=$4 _port=$5
    local _rf="${RUN_DIR}/retest_ips_${_W}.txt"
    local _tmp="${RUN_DIR}/result.csv.retest.${_W}"
    local _flag="${NODE_TEST_FLAG_BASE}_${_idx}_rt" _wn
    build_retest_list_one "$_W" "${count:-30}" || return 0
    [ -s "$_rf" ] || return 0
    rm -f "$_tmp" 2>/dev/null
    echolog "复测 [${_W}] 开始：该节点下载全部失败，用现有 result.csv/节点地址再测一轮"
    node_test_worker "$_idx" "$_W" "$_orig" "$_tmp" "$_rf" \
        "${probe_url:-}" "${timeout:-5}" "${probes:-3}" "$_port" "$_flag" \
        "$(node_latency_max "$_W")"
    if [ -z "$(first_result_ip "$_tmp")" ]; then
        rm -f "$_tmp"
        echolog "复测 [${_W}] 没有通过延迟筛选的 IP，保留上一轮结果"
        return 0
    fi
    _wn="$(uci -q get "passwall.${_W}.remarks" 2>/dev/null)"; _wn="${_wn:-${_W}}"
    NT_DL_FAILED=0
    nt_download_phase "$_W" "$_tmp" "$_wn" "${DL_TEST_COUNT:-5}" \
        "${DL_TEST_URL:-https://speed.cloudflare.com/__down?bytes=10000000}" \
        "${DL_TEST_TIME:-10}" "$_port" "${_flag}_dl"
    if [ "$NT_DL_FAILED" != "1" ]; then
        mv -f "$_tmp" "$_rfile"
        echolog "复测 [${_wn}] 下载成功，已用复测结果替换该节点结果"
    else
        rm -f "$_tmp"
        echolog "复测 [${_wn}] 下载仍全部失败，保留上一轮结果"
    fi
    return 0
}

# 下载实测阶段（所有 worker 停止后统一执行）：按映射文件逐 worker 串行实测。
# 与一轮延迟测试分离的原因：worker 还在跑时，其 SOCKS、uci 改写和探测流量都会和下载
# 争抢路由器 WAN 带宽与 CPU，边测边下载会让各 IP 的速度互相污染、无法横向比较。
# 串行由主进程的顺序循环保证，不依赖跨进程锁。
# 参数: $1=worker 映射文件（idx \t node \t origaddr，与 NT_ORIG_FILE 同格式）
nt_download_stage() {
    local _map=$1 _i _W _orig _rfile _failed="" _item _idx _rest
    [ "${DL_TEST_ENABLED:-1}" = "1" ] || return 0
    [ -f "$_map" ] || return 0
    # 下载结果决定各节点写回的最优 IP，与写回同属不可中断的收尾：提前打 .nt_committing，
    # 让 rpcd 的停止逻辑给足宽限（1200s），不要强杀在下载/写回中间。
    : > "${RUN_DIR}/.nt_committing" 2>/dev/null
    if [ -f "${RUN_DIR}/.user_stop" ]; then
        echolog "用户已停止一轮测速，仍继续完成下载实测后再写回退出"
    fi
    echolog "下载实测阶段开始：所有 worker 已停止探测，逐节点串行实测下载速度"
    # 不区分停止来源：自动提前停止时其余 worker 也已被协作式停止，它们已通过的 IP
    # 同样实测下载（无有效结果的 worker 由 nt_download_worker 直接跳过）。
    while read -r _i _W _orig; do
        [ -n "$_W" ] || continue
        _rfile="${RUN_DIR}/result.csv.tmp.$_W"
        NT_DL_FAILED=0
        nt_download_worker "$_W" "$_rfile" "$((48900 + _i - 1))" "${NODE_TEST_FLAG_BASE}_${_i}_dl"
        [ "$NT_DL_FAILED" = "1" ] && _failed="$_failed ${_i}:${_W}:${_orig}"
    done < "$_map"

    # 其他 worker 的下载全部结束后，对下载全部失败的节点各完整复测一轮。
    if [ -n "$_failed" ]; then
        if [ -f "${RUN_DIR}/.user_stop" ]; then
            echolog "用户已停止，跳过下载失败节点的复测"
            return 0
        fi
        echolog "下载全部失败的 worker:${_failed}；其他 worker 下载结束后各复测一轮"
        _failed_labels=""
        for _item in $_failed; do
            _rest=${_item#*:}
            _lid=${_rest%%:*}
            _failed_labels="${_failed_labels}${_failed_labels:+、}$(node_label "$_lid")"
        done
        _tasklog_write event download_retest info "" "" "" "" "" \
            "下载全部失败（${_failed_labels}），加测一轮（延迟探测 + 下载实测）"
        for _item in $_failed; do
            _idx=${_item%%:*}
            _rest=${_item#*:}
            _W=${_rest%%:*}
            _orig=${_rest#*:}
            nt_retest_failed_worker "$_idx" "$_W" "$_orig" \
                "${RUN_DIR}/result.csv.tmp.${_W}" "$((48900 + _idx - 1))"
        done
    fi
    return 0
}

# 普通 worker（非迭代模式）：通过节点 $2 的链路测全部候选 IP（$5），保留行写入结果文件 $4。
# ash 子 shell 里 local 可用（已验证）。下载实测不在这里做，见 nt_download_stage。
# 参数: $1=idx $2=node $3=origaddr $4=result_file $5=ip_list $6=probe_url $7=timeout $8=probes $9=socks_port $10=flag $11=列表延迟上限(0=全局)
node_test_worker() {
    local _idx=$1 _W=$2 _orig=$3 _rfile=$4 _ips=$5 _purl=$6 _tmo=$7 _probes=$8 _port=$9 _flag=${10} _tcap=${11:-0}
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
        wait_while_downloading || { echolog "worker [${_Wn}] 等待下载时收到停止"; break; }
        _idx2=$((_idx2 + 1))
        local _out _keep _sent _recv _loss _avg
        _out=$(nt_probe_one_ip "$_W" "$_ip" "$_purl" "$_tmo" "$_probes" "$_port" "$_flag" "$_tcap")
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
    # 本 worker 结果按延迟升序排（首行即延迟初筛的最优）。下载实测不在这里做：
    # 所有 worker 停止后由主进程统一串行执行（nt_download_stage），避免与仍在
    # 探测的其它 worker 争抢 WAN 带宽。
    sort_result "$_rfile" latency
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
# 终止条件：到点 / 停止标志 / 本轮通过数为 0（保留上一轮结果）/ 候选收敛到 ≤ITERATE_KEEP_MAX
# （该阈值来自独立参数 iterate_converge_count，与 download_test_count 无关）。
# 每 IP 之间也检查 deadline/停止标志，到点跑完当前 IP 即停，无全局轮次同步。
# 结束时把最终轮次号写入 $3.meta；最终轮完整测速结果由合并段统一打出（收尾日志逐节点汇总）。
# 参数: $1=idx $2=node $3=result_file $4=ip_list $5=probe_url $6=timeout $7=probes $8=socks_port $9=flag $10=deadline(epoch) $11=列表延迟上限(0=全局)
node_iterate_worker() {
    local _idx=$1 _W=$2 _rfile=$3 _ips=$4 _purl=$5 _tmo=$6 _probes=$7 _port=$8 _flag=$9 _deadline=${10} _tcap=${11:-0}
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
                awk -F, -v n="$_pname" -v id="$_W" \
                    'NF>=8 && $1!="" && ((NF>=9 && $9!="" && $9==id) || ((NF<9 || $9=="") && $8==n)) {print $1","$2","$3","$4","$5","$6","$7}'
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
            wait_while_downloading || { echolog "迭代 [${_Wn}] 等待下载时收到停止"; break; }
            _idx2=$((_idx2 + 1))
            echo "$_ip" >> "$_probedfile"
            local _out _keep _sent _recv _loss _avg
            _out=$(nt_probe_one_ip "$_W" "$_ip" "$_purl" "$_tmo" "$_probes" "$_port" "${_flag}_p${_pass}" "$_tcap")
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
            # 阈值来自独立的 iterate_converge_count，不随 download_test_count 变化。
            # 仅整轮测完时才判断 —— 被停止/到点截断的轮次候选数偏小，不代表收敛
            if [ "$_truncated" = "0" ] && [ "$_kept" -le "$ITERATE_KEEP_MAX" ]; then
                echolog "迭代 [${_Wn}] 候选收敛至 ${_kept} 个（阈值 ${ITERATE_KEEP_MAX}），保存结果，该节点提前结束"
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
    # 迭代收敛后的下载实测不在这里做：等所有节点都收敛/到点退出后，由主进程
    # 统一串行执行（nt_download_stage），避免与仍在迭代探测的节点争抢 WAN 带宽。
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

    # ── 下载实测（第二阶段）：延迟初筛后，等所有 worker 停止探测，再由主进程按 worker
    # 顺序逐 IP 串行实测：对每个 worker 延迟最优的 N 个 IP 走同一节点链路真实下载固定
    # 大小文件，按实测吞吐（MB/s）重排并选最优。开关缺省为开（老配置
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
    # 下载实测不在各 worker 内执行：等所有 worker 停止探测后，由主进程按 worker 顺序
    # 逐 IP 串行实测（nt_download_stage），避免下载与仍在探测的 worker 争抢 WAN 带宽。

    # 迭代收敛阈值：独立参数（iterate_converge_count），与下载实测候选数无关。
    # 候选收敛到 ≤ N 个即保存结果、该节点提前结束；下载实测仍按 download_test_count
    # 对延迟最优的那批 IP 单独执行，两者互不覆盖。
    ITERATE_KEEP_MAX="${iterate_converge_count:-5}"
    case "$ITERATE_KEEP_MAX" in ''|*[!0-9]*) ITERATE_KEEP_MAX=5 ;; esac
    [ "$ITERATE_KEEP_MAX" -ge 1 ] 2>/dev/null || ITERATE_KEEP_MAX=1
    [ "$ITERATE_KEEP_MAX" -le 100 ] 2>/dev/null || ITERATE_KEEP_MAX=100
    [ "${ITERATE_MODE:-0}" = "1" ] && echolog "迭代收敛阈值：候选 ≤ ${ITERATE_KEEP_MAX} 个即提前结束（与下载实测候选数 ${DL_TEST_COUNT} 相互独立）"

    # ── 候选 IP 来源 ──
    local count="${node_test_count:-30}"
    case "$count" in ''|*[!0-9]*) count=30 ;; esac
    [ "$count" -gt 0 ] || count=30

    local ip_source_mode="file"
    local selected_ip_file=""
    if [ "${RETEST_FROM_RESULT:-0}" = "1" ]; then
        # 复测模式：候选来自当前 result.csv + 各节点当前 address + DDNS 域名解析。
        # 某个 worker 去重后只剩 0/1 个候选时无法择优，一旦这个 IP 失效就会一直
        # 复测失败；这类 worker 退回普通测速来源（在线源会重新下载列表），其余
        # worker 仍按复测的少量候选跑。
        read_node_ip_map
        build_retest_ip_lists "$count"
        local _sparse="" _seen="" _w _rf _rn _before _src _N _n _e _any
        for _w in ${NODE_IP_WORKERS:-} ${passwall_services:-} ${node_test_node:-}; do
            [ -n "$_w" ] || continue
            node_selected "$_w" || continue
            case " $_seen " in *" $_w "*) continue ;; esac
            _seen="$_seen $_w"
            _rf="${RUN_DIR}/retest_ips_${_w}.txt"
            _rn=0
            [ -f "$_rf" ] && _rn=$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$_rf")
            [ "$_rn" -ge 2 ] || _sparse="$_sparse $_w"
        done
        _sparse="${_sparse# }"

        if [ -n "$_sparse" ]; then
            echolog "复测候选不足 2 个的 worker: ${_sparse}；改为普通测速并重新拉取列表 IP"
            _sparse_labels=""
            for _w in $_sparse; do
                _sparse_labels="${_sparse_labels}${_sparse_labels:+、}$(node_label "$_w")"
            done
            _tasklog_write event candidate_refresh info "" "" "" "" "" \
                "复测候选不足 2 个（${_sparse_labels}），清空后改为普通测速重新拉取列表"
            if [ "${ip_source:-}" = "online" ]; then
                migrate_ip_online_regions
                fetch_online_raw || return 1
                compute_default_ip_list
                for _n in 1 2 3 4 5; do
                    eval "_e=\${list${_n}_enabled:-0}"
                    [ "$_e" = "1" ] && build_ip_list_file "$_n"
                done
                for _w in $_sparse; do
                    _N=$(resolve_node_list "$_w")
                    if [ -n "$_N" ]; then
                        _src="${RUN_DIR}/ip_list_${_N#list}.txt"
                    else
                        _src="${ONLINE_RAW:-}"
                    fi
                    [ -n "$_src" ] && [ -f "$_src" ] || continue
                    _rf="${RUN_DIR}/retest_ips_${_w}.txt"
                    _before=$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$_rf" 2>/dev/null)
                    case "$_before" in ''|*[!0-9]*) _before=0 ;; esac
                    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$_src" | head -n "$count" > "$_rf"
                    echolog "worker [$_w] 复测只有 ${_before} 个候选，已改用普通测速候选（$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$_rf") 个）"
                done
            else
                selected_ip_file="$(select_ip_file)"
                [ -f "$selected_ip_file" ] || { echolog "候选 IP 列表文件不存在: $selected_ip_file"; return 1; }
                for _w in $_sparse; do
                    _rf="${RUN_DIR}/retest_ips_${_w}.txt"
                    _before=$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$_rf" 2>/dev/null)
                    case "$_before" in ''|*[!0-9]*) _before=0 ;; esac
                    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$selected_ip_file" | head -n "$count" > "$_rf"
                    echolog "worker [$_w] 复测只有 ${_before} 个候选，已改用普通测速候选（$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$_rf") 个）"
                done
            fi
        fi

        # 兜底：至少一个 worker 有候选，否则中止（与旧行为一致）。
        _any=0
        for _w in ${NODE_IP_WORKERS:-} ${passwall_services:-} ${node_test_node:-}; do
            [ -n "$_w" ] || continue
            node_selected "$_w" || continue
            [ -s "${RUN_DIR}/retest_ips_${_w}.txt" ] && { _any=1; break; }
        done
        [ "$_any" = "1" ] || { echolog "复测模式：没有可复测的候选 IP（result.csv 为空、节点 address 不是 IP 且 DDNS 域名无可解析记录），中止"; return 1; }
        echolog "复测模式：候选来自现有 result.csv / 各节点当前 address / DDNS 域名解析，每节点最多 ${count} 个"
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
            node_selected "$_w" || continue
            case " $_seen " in *" $_w "*) ;; *) _seen="$_seen $_w"; workers_raw="$workers_raw $_w"; ;; esac
        done
    fi

    if [ -n "$workers_raw" ]; then
        # ── 多节点并行路径 ──
        # 校验每个 worker，建 idx→node→origaddr 映射文件
        NT_ORIG_FILE="$(mktemp "${RUN_DIR}/node_test_orig.XXXXXX")" || { echolog "创建 worker 映射文件失败"; return 1; }
        # uci staging（/tmp/.uci/passwall）是跨进程共享的，并发任务必须共用一把锁。
        NT_LOCKDIR="$RESULT_DIR/.uci.lock"
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
                echolog "下载实测已启用：所有 worker 完成一轮延迟测试后，逐节点串行实测每个 worker 延迟最优的 ${DL_TEST_COUNT} 个 IP（${DL_TEST_URL}，单 IP 上限 ${DL_TEST_TIME}s），按实测吞吐选最优"
            fi
            echolog "提示：测速期间所有 worker 节点的 address 会被反复改写，这些节点会短暂抖动，测完各写各的最优 IP"
            # 记录实测过的 worker 集合，供 ip_replace/passwall_best_ip 跳过（保留各节点自己的最优 IP）
            NODE_TESTED_WORKERS="$valid_workers"
            # 稳定节点不得在待测 worker 集合内（否则用户实流量仍走被改写地址的节点，切换无意义）
            case " $valid_workers " in *" ${stable_node} "*) echolog "稳定节点 ${stable_node} 与待测 worker 重叠，中止（稳定节点不得在待测集合内）"; return 1 ;; esac
            # 测前快照 /etc/config/passwall：测后还原以抹掉 passwall 测速中途新增的异常节点段
            nt_snapshot || { echolog "passwall 快照失败，中止"; return 1; }
            # 拉起 worker 之前切 passwall 全局节点到稳定节点（测后由 node_test_cleanup 还原）。
            # 独立内核模式不改写节点 address，也不需要动 passwall 全局节点，直接跳过。
            if [ "${standalone_enabled:-0}" != "1" ]; then
                nt_switch_tcp_node || { echolog "稳定节点校验失败，中止"; node_test_cleanup; trap - EXIT INT TERM; return 1; }
            fi
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
                    node_iterate_worker "$launched" "$_w" "$_rfile" "$_wips" "$probe_url" "$timeout" "$probes" "$_port" "${NODE_TEST_FLAG_BASE}_$launched" "$NT_ITER_DEADLINE" \
                        "$(node_latency_max "$_w")" &
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
                    node_test_worker "$launched" "$_w" "" "$_rfile" "$_wips" "$probe_url" "$timeout" "$probes" "$_port" "${NODE_TEST_FLAG_BASE}_$launched" \
                        "$(node_latency_max "$_w")" &
                    NT_RUNNING="${NT_RUNNING:+$NT_RUNNING }$!:${_w}"
                done
                # 排空仍运行的 worker（无提前停止时正常完成路径）
                while [ -n "$NT_RUNNING" ] && [ "$_stop" != "1" ]; do
                    if nt_scan_running; then _stop=1; break; fi
                    [ -n "$NT_RUNNING" ] && [ "$_stop" != "1" ] && sleep 1
                done
                # 提前停止：写停止标志，其余 worker 跑完当前 IP 自行 break 退出，wait 收尸（不 kill）。
                # 无论用户手动停止还是「首个 worker 完成」的自动提前停止，停止后都不再开启新的
                # 延迟探测；已通过的 IP 由随后的下载阶段逐节点串行完成实测。
                if [ "$_stop" = "1" ]; then
                    if [ -f "${RUN_DIR}/.user_stop" ]; then
                        echolog "用户已停止一轮测速，停止探测后仍会完成各节点已通过 IP 的下载实测"
                    else
                        echolog "首个有效结果 worker 完成，其余 worker 跑完当前 IP 即停，随后串行完成各节点下载实测"
                    fi
                    : > "${RUN_DIR}/.nt_stop"
                    wait  # 各 worker 自行 break → 写 .done/.end → 正常退出，wait 收尸
                fi
            fi
            NT_RUNNING=""
            # 注意：这里不能删 result.csv.tmp.*.meta——合并段还要读它打逐节点最终结果；
            # .meta 由合并循环逐个删除（随 mwfile），中断残留由 node_test_cleanup 兜底
            rm -f "${RUN_DIR}"/result.csv.tmp.*.done "${RUN_DIR}"/result.csv.tmp.*.end "${RUN_DIR}"/result.csv.tmp.*.pass "${RUN_DIR}"/result.csv.tmp.*.probed "${RUN_DIR}/.nt_stop" 2>/dev/null
            # 所有 worker 已停止探测 → 进入下载实测阶段（主进程串行，逐 worker 逐 IP）。
            # 必须放在合并/写回之前：下载结果决定各节点写回哪个最优 IP。
            # 下载会互相抢带宽，跨任务也全局串行：后到者在 commit 锁上排队（A 方案）。
            # 排队期间也算「提交阶段」，停止按钮不会强杀，等它完成自己的下载。
            : > "${RUN_DIR}/.nt_committing" 2>/dev/null
            if ! commit_lock_acquire; then
                echolog "未拿到下载锁，本次放弃（保留上一次结果）"
                rm -f "${RUN_DIR}/.nt_stop" 2>/dev/null
                trap node_test_cleanup EXIT INT TERM
                node_test_cleanup; trap - EXIT INT TERM
                return 1
            fi
            nt_download_stage "$NT_ORIG_FILE"
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
            echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码,节点,节点ID" > "$merged"
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
                    if nt_node_has_ddns "$mw"; then
                        echolog "走节点测速完成 [${mwname}]，最优 IP ${mwbest} 将写入 DDNS 域名（不回写 passwall 节点）"
                    else
                        printf '%s\t%s\n' "$mw" "$mwbest" >> "$reapply"
                        echolog "走节点测速完成 [${mwname}]，最优 IP ${mwbest} 待写回 passwall 节点"
                    fi
                else
                    echolog "走节点测速 [${mwname}] 结果为空，保留原 address"
                fi
                # 迭代模式：收尾段逐节点打出该节点最终轮（最近一次落盘）的完整测速结果——
                # worker 无论提前收敛还是跑到时限退出，此处统一按「节点名一行 + 逐行结果」汇总
                [ "${ITERATE_MODE:-0}" = "1" ] && iterate_log_final_summary "$mwname" "$mwfile"
                # 任务日志明细：本次该节点选中的 IP、写回方式与该 IP 的延迟/速度。
                local _method="writeback" _met _mlat _mspd _mtab _tdname
                nt_node_has_ddns "$mw" && _method="ddns"
                _tdname="$(node_label "$mw")"
                if [ -n "$mwbest" ]; then
                    _met=$(_tasklog_metrics "$mwfile")
                    _mtab="$(printf '\t')"
                    _mlat="${_met%%"$_mtab"*}"; _mspd="${_met#*"$_mtab"}"
                    _tasklog_detail "$mw" "$_tdname" ok "$mwbest" "$_mlat" "$_mspd" "$_method"
                else
                    _tasklog_detail "$mw" "$_tdname" fail "" 0 0 "-"
                fi
                # awk 过滤丢掉被杀 worker kill -9 中途截断的脏行（NF<7），正常 7 列行等价；
                # 末两列追加节点备注名（逗号替换为空格防 CSV 断列）和 passwall section ID。
                # ID 是稳定主键：复测/历史/DDNS 都按它匹配，改 remarks 不会再把节点认丢。
                local _nname="${mwname//,/ }"
                sed '1d' "$mwfile" 2>/dev/null | \
                    awk -F, -v n="$_nname" -v id="$mw" 'NF>=7 && $1!="" {print $0 "," n "," id}' >> "$merged"
                rm -f "$mwfile" "${mwfile}.meta" "${mwfile}.prev" 2>/dev/null
            done < "$NT_ORIG_FILE"
            # 注意：NT_ORIG_FILE 不能在这里删除——nt_apply_best_addresses 还要用它
            # 还原未写回新最优的 worker（DDNS 节点）到测前 address（通常是域名）。
            # 提前 rm 会让 DDNS 节点停在被探测过的候选 IP 上，并误报“未写入 passwall”。
            # 会话结束时 node_test_cleanup 会统一清理。
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
                nt_request_passwall_reload
            else
                echolog "警告：最优 IP 未写入 passwall 配置，收尾按测前配置回滚"
            fi
            # DDNS：配置了 ddns_domain 的节点，最优 IP 写到 Cloudflare DNS；这些节点
            # 已在上面排除出 passwall 写回清单。DDNS 失败不影响测速结果。
            if [ "$(uci -q get cfpick.global.ddns_enabled 2>/dev/null)" = "1" ]; then
                echolog "开始写入 DDNS：按节点最优 IP 更新 Cloudflare DNS"
                if /usr/bin/cfpick ddns uci-apply --result "$merged" >>"$LOG_FILE" 2>&1; then
                    TASKLOG_DDNS_STATUS="已写入"
                else
                    TASKLOG_DDNS_STATUS="有节点失败"
                    echolog "警告：DDNS 有节点未完成（明细见上，不影响测速结果）"
                fi
            fi
            # 全量任务才滚动历史；局部任务只替换自己 worker 的行，避免把别的 worker 的结果滚进 .1。
            # 只有本次真正覆盖了全部 worker 才滚动历史；被占用的 worker 跳过后
            # 结果是局部的，滚动会把上一次的完整结果挪进 .1。
            [ "$RUN_IS_FULL" = "1" ] && rotate_result_files
            if ! merge_run_result "$merged" "$NODE_TESTED_WORKERS"; then
                echolog "警告：合并 result.csv 失败，保留上一次结果"
            fi
            rm -f "$merged"
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
    # 定时任务按节点过滤时，回退的单节点也必须落在所选范围内，否则宁可不跑，
    # 也不能悄悄改测一个用户没选的节点。
    if [ -n "$NODE_FILTER" ] && ! node_selected "$NODE_TEST_NODE"; then
        echolog "所选节点没有可用的 worker（单节点回退 ${NODE_TEST_NODE:-未配置} 不在所选范围），本次跳过"
        return 1
    fi
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
    NT_LOCKDIR="$RESULT_DIR/.uci.lock"

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
    # inline 调用 worker 之前切 passwall 全局节点到稳定节点（测后由 node_test_cleanup 还原）。
    # 独立内核模式不改写节点 address，也不需要动 passwall 全局节点，直接跳过。
    if [ "${standalone_enabled:-0}" != "1" ]; then
        nt_switch_tcp_node || { echolog "稳定节点校验失败，中止"; node_test_cleanup; trap - EXIT INT TERM; return 1; }
    fi
    # 单节点：inline 调用 worker（不 background），端口 48900、flag=base
    if [ "${ITERATE_MODE:-0}" = "1" ]; then
        # 限时迭代：该节点跑独立收敛循环到时限，结果文件同路径，末尾统一合并写回（仅一次）
        echolog "迭代模式：节点 ${NODE_TEST_NODE} 独立收敛循环至时限（${NT_ITER_DEADLINE} 截止）"
        node_iterate_worker 1 "${NODE_TEST_NODE}" "$result_tmp" "$ip_list" "$probe_url" "$timeout" "$probes" 48900 "${NODE_TEST_FLAG_BASE}" "$NT_ITER_DEADLINE" \
            "$(node_latency_max "${NODE_TEST_NODE}")"
    else
        node_test_worker 1 "${NODE_TEST_NODE}" "${NODE_TEST_ORIG_ADDR}" "$result_tmp" "$ip_list" "$probe_url" "$timeout" "$probes" 48900 "${NODE_TEST_FLAG_BASE}" \
            "$(node_latency_max "${NODE_TEST_NODE}")"
    fi

    # 一轮延迟测试已结束（单节点没有并发 worker），进入下载实测阶段：主进程串行逐 IP 实测。
    # 放在写回/摘要之前——下载结果决定写回哪个最优 IP，迭代摘要也要带上实测速度。
    local _dmap="${RUN_DIR}/download_map"
    printf '1\t%s\t\n' "$NODE_TEST_NODE" > "$_dmap" 2>/dev/null
    # 下载/写回阶段全局串行（跨任务排队），避免互抢带宽把速度测偏。
    # 排队期间也算提交阶段，停止不会强杀，仍会完成本次候选的下载。
    : > "${RUN_DIR}/.nt_committing" 2>/dev/null
    if ! commit_lock_acquire; then
        echolog "未拿到下载锁，本次放弃（保留上一次结果）"
        rm -f "$_dmap" "$result_tmp"
        trap node_test_cleanup EXIT INT TERM
        node_test_cleanup; trap - EXIT INT TERM
        return 1
    fi
    [ -s "$_dmap" ] && nt_download_stage "$_dmap"
    rm -f "$_dmap"

    if [ "${ITERATE_MODE:-0}" = "1" ]; then
        # 单节点迭代路径无合并段，最终轮完整测速结果在此打出（多 worker 路径在合并段打）
        local _nm
        _nm="$(uci -q get "passwall.${NODE_TEST_NODE}.remarks" 2>/dev/null)"; _nm="${_nm:-${NODE_TEST_NODE}}"
        iterate_log_final_summary "$_nm" "$result_tmp"
    fi

    # ── 提交阶段开始：不可中断（同多 worker 路径：此刻被 INT 打断会触发 nt_rollback 抹掉结果）──
    trap '' INT TERM
    : > "${RUN_DIR}/.nt_committing"

    if [ -z "$(first_result_ip "$result_tmp")" ]; then
        local _dname
        _dname="$(node_label "$NODE_TEST_NODE")"
        _tasklog_detail "$NODE_TEST_NODE" "$_dname" fail "" 0 0 "-"
        echolog "走节点测速结果 IP 数量为 0，整份回滚并保留上一次结果"
        rm -f "$result_tmp"
        trap node_test_cleanup EXIT INT TERM   # 先复原信号，回滚路径照旧
        node_test_cleanup; trap - EXIT INT TERM
        return 1
    fi

    # 数据行末两列追加节点备注名和 passwall section ID（与多 worker 合并段一致；
    # ID 是稳定主键，改 remarks 不会让复测/DDNS 认丢节点）
    local _nm2="${NODE_TEST_NODE}"
    _nm2="$(uci -q get "passwall.${NODE_TEST_NODE}.remarks" 2>/dev/null)"; _nm2="${_nm2//,/ }"; _nm2="${_nm2:-${NODE_TEST_NODE}}"
    awk -F, -v n="$_nm2" -v id="${NODE_TEST_NODE}" \
        'NR==1 {print $0 ",节点,节点ID"; next} NF>=7 && $1!="" && $1 !~ /^#/ {print $0 "," n "," id}' \
        "$result_tmp" > "${result_tmp}.nn" 2>/dev/null \
        && [ -s "${result_tmp}.nn" ] && mv -f "${result_tmp}.nn" "$result_tmp"

    echo "# Speed test time: $(date +'%Y-%m-%d %H:%M:%S')" >> "$result_tmp"

    # ── 写回配置 → 重启生效 → 发布结果（同多 worker 路径：先落盘配置，再发布结果）──
    bestip=$(first_result_ip "$result_tmp")
    local _reapply _ddns_node=0
    _reapply="$(mktemp "${RUN_DIR}/node_test_reapply.XXXXXX")"
    if nt_node_has_ddns "${NODE_TEST_NODE}"; then
        _ddns_node=1
        echolog "节点 ${NODE_TEST_NODE} 配置了 DDNS，最优 IP ${bestip} 写入 DNS，不回写 passwall 节点"
    else
        printf '%s\t%s\n' "${NODE_TEST_NODE}" "${bestip}" > "$_reapply"
        echolog "开始写回：节点 ${NODE_TEST_NODE} 最优 IP ${bestip} 写入 passwall 配置（原子替换，此阶段不可中断，请稍候）"
    fi
    local _tmet _ttab
    _tmet=$(_tasklog_metrics "$result_tmp")
    _ttab="$(printf '\t')"
    _tasklog_detail "$NODE_TEST_NODE" "$(node_label "$NODE_TEST_NODE")" ok "$bestip" \
        "${_tmet%%"$_ttab"*}" "${_tmet#*"$_ttab"}" \
        "$([ "$_ddns_node" = "1" ] && echo ddns || echo writeback)"
    if nt_apply_best_addresses "$_reapply"; then
        nt_request_passwall_reload
        [ "$_ddns_node" = "1" ] || \
            echolog "走节点测速完成，最优 IP ${bestip} 已写入 passwall 节点 ${NODE_TEST_NODE}（已清理测速期间 passwall 新增的异常节点）"
    else
        echolog "警告：最优 IP 未写入 passwall 配置，收尾按测前配置回滚"
    fi
    rm -f "$_reapply"
    if [ "$(uci -q get cfpick.global.ddns_enabled 2>/dev/null)" = "1" ]; then
        echolog "开始写入 DDNS：按节点最优 IP 更新 Cloudflare DNS"
        if /usr/bin/cfpick ddns uci-apply --result "$result_tmp" >>"$LOG_FILE" 2>&1; then
            TASKLOG_DDNS_STATUS="已写入"
        else
            TASKLOG_DDNS_STATUS="有节点失败"
            echolog "警告：DDNS 有节点未完成（明细见上，不影响测速结果）"
        fi
    fi
    [ "$RUN_IS_FULL" = "1" ] && rotate_result_files
    if ! merge_run_result "$result_tmp" "$NODE_TESTED_WORKERS"; then
        echolog "警告：合并 result.csv 失败，保留上一次结果"
    fi
    rm -f "$result_tmp"
    rm -f "${RUN_DIR}/.nt_committing" 2>/dev/null
    trap node_test_cleanup EXIT INT TERM

    NODE_TEST_DONE=1; node_test_cleanup; trap - EXIT INT TERM
    return 0
}

function ip_replace(){
    # 全局集成（hosts/DNS/其他代理）是共享配置，和下载/写回共用同一把 commit 锁，
    # 避免两个任务同时改 hosts 或 DNS。
    commit_lock_acquire || return 1
    # 获取最快 IP（从合并后的 result.csv 中获取第一个 IP）
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
    commit_lock_release
    return 0
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

# 启动参数: <mode> [--node=<passwall section> ...]
# 兼容 `--node=id` 与 `--node id` 两种写法；没有 --node 时保持旧行为（全部节点）。
ACTION=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        start|test|replace|retest|monitor)
            [ -n "$ACTION" ] || ACTION="$1"
            ;;
        --node=*)
            _node_id="${1#--node=}"
            [ -n "$_node_id" ] && NODE_FILTER="$NODE_FILTER $_node_id"
            ;;
        --node)
            shift
            [ -n "${1:-}" ] && NODE_FILTER="$NODE_FILTER $1"
            ;;
    esac
    shift
done
NODE_FILTER="${NODE_FILTER# }"

# 后台监测模式不参与任务锁/会话/写回：它只复测一个成功结果并在失败时触发复测。
if [ "$ACTION" = "monitor" ]; then
    monitor_worker
    exit $?
fi

if [ -n "$ACTION" ] ;then
    # 按 worker 抢锁：同一 worker 只允许一个任务；不同 worker 可并行。
    LOCK_CAP=43200
    if [ "${iterate_enabled:-0}" = "1" ] && [ "${iterate_minutes:-0}" -ge 1 ] 2>/dev/null; then
        LOCK_CAP=$(( iterate_minutes * 60 + 1800 ))
    fi

    RUN_IS_FULL=0
    if [ "$ACTION" = "replace" ]; then
        # replace 不测节点，只读结果、写全局集成；ip_replace 自己拿 commit 锁。
        _saved_filter="$NODE_FILTER"
        NODE_FILTER=""
        RUN_WORKERS="$(run_worker_ids)"
        NODE_FILTER="$_saved_filter"
    else
        _requested_filter="$NODE_FILTER"
        RUN_WORKERS="$(run_worker_ids)"
        if [ -z "$RUN_WORKERS" ]; then
            echolog "没有可用的待测 worker（检查「节点」页配置和任务选择的节点），本次跳过"
            exit 1
        fi
        # 逐个抢 worker：被别的任务占用的只跳过它自己，任务里其余 worker 继续。
        if ! worker_locks_acquire "$RUN_WORKERS"; then
            echolog "所选 worker 都在被其他任务使用，本次 $ACTION 跳过"
            exit 1
        fi
        # 这些 worker 马上要重新测速：结束它们上一轮成功后的后台监测。
        monitor_stop_for "$ACQUIRED_WORKERS"
        _want=$(printf '%s\n' $RUN_WORKERS | grep -c .)
        _got=$(printf '%s\n' $ACQUIRED_WORKERS | grep -c .)
        if [ -z "$_requested_filter" ] && [ "$_want" = "$_got" ]; then
            RUN_IS_FULL=1
        fi
        RUN_WORKERS="$ACQUIRED_WORKERS"
        NODE_FILTER="$ACQUIRED_WORKERS"
        echolog "本次实际测试 worker: ${ACQUIRED_WORKERS}"
    fi

    if ! run_session_create; then
        worker_locks_release
        exit 1
    fi
    trap 'worker_locks_release; commit_lock_release; run_session_destroy' EXIT INT TERM

    _task_rc=1
    if [ "$ACTION" != "replace" ]; then
        _tw=$(printf '%s\n' $RUN_WORKERS | grep -c .)
        _tasklog_write start "$ACTION" running "" "" "" "" "" \
            "开始测速（${_tw} 个 worker）"
    fi
    if [ "$ACTION" == "start" ]; then
        speed_test && ip_replace
        _task_rc=$?
    elif [ "$ACTION" == "test" ]; then
        speed_test
        _task_rc=$?
    elif [ "$ACTION" == "retest" ]; then
        RETEST_FROM_RESULT=1
        speed_test && ip_replace
        _task_rc=$?
    elif [ "$ACTION" == "replace" ]; then
        ip_replace
        _task_rc=$?
    fi
    if [ "$ACTION" != "replace" ]; then
        _tasklog_finish "$ACTION" "$_task_rc"
    fi
    worker_locks_release
    commit_lock_release
    # 成功后为该 worker 拉起后台监测（失败/停止/局部未成功的节点不监测）。
    if [ "$_task_rc" = "0" ] && [ "$ACTION" != "replace" ]; then
        for _w in $RUN_WORKERS; do
            monitor_has_target "$_w" && monitor_spawn "$_w"
        done
    fi
    run_session_destroy
    trap - EXIT INT TERM
    exit
fi