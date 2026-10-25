#!/bin/sh
#
# netmon-daemon.sh - luci-app-netmonitor 后台检测守护进程
#
# 由 /etc/init.d/netmonitor 通过 procd 拉起，全局唯一实例。
# 浏览器页面只读取本进程产出的数据，不会创建第二套探测任务。
#
# 设计要点
#   1. 高频数据全部写入 /tmp（tmpfs），默认不写 Flash；只有显式开启持久化时，
#      才会按 persist_interval 把「聚合桶」批量落盘。
#   2. 统计信息采用「分段（chunk）+ 直方图」增量维护：每轮只做 O(1) 更新，
#      避免每次检测都全量重算历史，CPU 占用与历史长度无关。
#   3. 严格校验用户输入，ping 目标始终以引号包裹且禁止以 '-' 开头，杜绝命令注入。
#   4. 任何异常都被收敛为明确的错误码（超时 / DNS / 不可达 / 其它），不笼统报「网络异常」。
#   5. 每个目标可独立选择探测方式：icmp（默认，ping 回显）或 tcp（TCP 连接握手）。
#      TCP 探测优先使用 curl 的 %{time_connect} 作为握手 RTT；因为固件自带的 nc
#      常为精简版 busybox applet（usage 只有 `nc [IPADDR PORT]`，不支持 -w），
#      既无法限制超时也不能「只建连不传数据」，直接用于探测会挂住整轮检测，
#      所以只有当 nc 确实支持 -w 时才把它作为后备。两者都不可用时 TCP 目标
#      统一报 errno=4，并在日志中给出一次明确提示。
#      TCP 模式下 count 不适用：一次探测只建立一次连接，按 1 个「包」统计。
#
# 运行期文件（全部位于 /tmp/netmonitor）
#   tmp.<pid>/             本实例独占的临时目录（按 pid 隔离，见下方说明）
#   targets.tsv            本轮生效的目标清单（配置重载时重建）
#                          列（TAB 分隔）：
#                            sid name host region proto timeout interval
#                            family iface source label remark port
#   tick                   心跳时间戳，前端据此判断后台是否真的在跑
#   state/<id>             目标运行时状态（上次检测时间、连续失败次数…）
#   ring/<id>.tsv          原始采样点环形缓存（t, latency, ok, errno）
#   hist/<id>.cur          当前统计段
#   hist/<id>.seg          已完成的统计段
#   tmp/<id>.res           单次检测的中间结果
#
# 持久化文件（/etc/netmonitor/history，需显式开启）
#   <id>.agg               聚合桶（t, avg, min, max, ok, cnt, loss）
#   <id>.last              上次落盘时间戳
#

. /lib/functions.sh

RUN_DIR=/tmp/netmonitor
RING_DIR=$RUN_DIR/ring
HIST_DIR=$RUN_DIR/hist
STATE_DIR=$RUN_DIR/state
# 临时目录按实例隔离：一个实例只用自己的 tmp.<pid>。
# reload 触发 restart 时，procd 的 term_timeout 是 5s，而一次 ping 最长要跑
# timeout*count+2 秒，旧实例往往在新实例起来之后还在收尾；若两者共用一个
# tmp 目录，新实例启动时的清理会删掉旧实例正在写的 .out，旧实例随即解析
# 失败并写出全空结果——日志里会出现 `awk: ... No such file or directory`、
# 一条 `check failed (errno=)` 的假告警，环缓存里还会多出一条空采样。
TMP_DIR=$RUN_DIR/tmp.$$
PERSIST_DIR=/etc/netmonitor/history
TAG=netmonitor

# 每个统计段包含的采样点数（段满后固化为一行，便于裁剪与快速聚合）
CHUNK=60
# 直方图桶上界（毫秒），共 17 个桶，用于估算 P50/P95/P99
BUCKETS="1 5 10 20 30 40 50 75 100 150 200 300 400 500 750 1000"
NB=17

TAB=$(printf '\t')

# 错误码：0 成功 / 1 超时 / 2 DNS 解析失败 / 3 网络不可达 / 4 其它错误 / 5 非法目标
# TCP 模式下「连接被拒绝」归入 3：主机可达，但该端口上没有服务在监听。
E_OK=0
E_TIMEOUT=1
E_DNS=2
E_UNREACH=3
E_OTHER=4
E_INVALID=5

RELOAD=1
STOP=0

# TCP 探测工具：curl（首选，微秒级握手耗时） / nc（后备，需支持 -w） / none
TCP_TOOL=none
TCP_WARNED=0

# ---------------------------------------------------------------- 全局配置
G_ENABLED=1
G_INTERVAL=10
G_TIMEOUT=3
G_COUNT=1
G_CONCURRENCY=5
G_FAMILY=auto
G_IFACE=
G_SOURCE=
G_PERSISTENCE=0
G_HISTORY=24h
G_PERSIST_INTERVAL=300
G_MAX_POINTS=4320
# 环形缓冲的软阈值，由 load_config 按 max_points 重算；这里给一个与默认
# max_points 匹配的安全初值，避免未走 load_config 的代码路径（单元测试、
# 异常配置）拿到空值后让 shell 的整数比较报错。
RING_TRIM_AT=4860
G_LOG_LEVEL=info
G_FAIL_WARN=3
G_FAIL_CRITICAL=5
G_DEFAULT_PROTO=icmp
G_DEFAULT_TCP_PORT=80

# ---------------------------------------------------------------- 工具函数
log_msg() {
	# log_msg <level> <message>
	case "$1" in
		debug)
			[ "$G_LOG_LEVEL" = "debug" ] || return 0
			;;
		info)
			case "$G_LOG_LEVEL" in debug|info) ;; *) return 0 ;; esac
			;;
	esac
	logger -t "$TAG" -p "$1" "$2"
}

# 数值合法性：非负整数
is_uint() {
	case "${1:-}" in
		''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

# 目标地址合法性：域名 / IPv4 / IPv6（含 IPv6 文本与 zone id）
# 禁止空值、禁止以 '-' 开头（避免被 ping 当作选项），长度上限 253
valid_host() {
	local h="$1"
	[ -n "$h" ] || return 1
	[ "${#h}" -le 253 ] || return 1
	case "$h" in
		-*) return 1 ;;
		*[!A-Za-z0-9._:\[\]%-]*) return 1 ;;
	esac
	return 0
}

# 接口 / 源地址合法性
valid_iface() {
	local v="$1"
	[ -z "$v" ] && return 0
	[ "${#v}" -le 64 ] || return 1
	case "$v" in
		-*) return 1 ;;
		*[!A-Za-z0-9._:@%-]*) return 1 ;;
	esac
	return 0
}

clamp() {
	# clamp <value> <min> <max>
	local v="$1" mn="$2" mx="$3"
	is_uint "$v" || v="$mn"
	[ "$v" -lt "$mn" ] && v="$mn"
	[ "$v" -gt "$mx" ] && v="$mx"
	printf '%s' "$v"
}

retention_seconds() {
	case "$1" in
		1h)   printf '3600' ;;
		6h)   printf '21600' ;;
		12h)  printf '43200' ;;
		24h)  printf '86400' ;;
		3d)   printf '259200' ;;
		7d)   printf '604800' ;;
		30d)  printf '2592000' ;;
		*)    printf '86400' ;;
	esac
}

setup_dirs() {
	local d p

	mkdir -p "$RUN_DIR" "$RING_DIR" "$HIST_DIR" "$STATE_DIR" "$TMP_DIR"
	if [ "$G_PERSISTENCE" = "1" ]; then
		mkdir -p "$PERSIST_DIR"
	fi

	# 自己的目录刚建出来，本来就是空的；这里只回收「进程已不存在」的遗留
	# tmp.<pid>。正在运行的实例（含刚被 restart 顶掉、仍在 term_timeout 内
	# 收尾的旧实例）一律不碰。
	for d in "$RUN_DIR"/tmp.*; do
		[ -d "$d" ] || continue
		[ "$d" = "$TMP_DIR" ] && continue
		p=${d##*/tmp.}
		case "$p" in
			''|*[!0-9]*) ;;
			*) [ -d "/proc/$p" ] && continue ;;
		esac
		rm -rf "$d" 2>/dev/null
	done
}

zeros_hist() {
	# 输出 NB 个 0，空格分隔
	local i=0 out=
	while [ $i -lt $NB ]; do
		out="$out${out:+ }0"
		i=$((i + 1))
	done
	printf '%s' "$out"
}

# ---------------------------------------------------------------- 配置加载
# config_load 只为「配置里存在的选项」导出 CONFIG_<段>_<选项> 变量，
# 从不清除被删除选项留下的旧变量（CONFIG_SECTIONS 段缓存同理，只会叠加）。
# 守护进程是长驻进程、靠 SIGHUP 原地重载（reload 不重启进程），
# 于是前端把某个字段清空（saveConfig 走 uci unset）后，reload 仍会读到
# 上一次的值，直到进程重启才恢复 —— 表现为「界面上清空了却不生效」。
# 因此每次 config_load 之前先把上一轮的 CONFIG_* 全部清掉。
#
# 注意必须写成 `for v in $(set | ...)`，循环体才会在**当前** shell 执行；
# 若写成 `set | while read v; do unset "$v"; done`，while 落在管道子 shell 里，
# unset 只影响子 shell，对父进程完全无效（代码看着写了，实际不起作用）。
clear_config_cache() {
	local v
	for v in $(set | sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$v" 2>/dev/null
	done
}

load_config() {
	# 目标清单写入依赖 $RUN_DIR 存在，这里兜底创建（对 tmpfs 而言开销可忽略）
	mkdir -p "$RUN_DIR"

	clear_config_cache
	config_load netmonitor

	config_get_bool G_ENABLED global enabled 1
	config_get G_INTERVAL global interval 10
	config_get G_TIMEOUT global timeout 3
	config_get G_COUNT global count 1
	config_get G_CONCURRENCY global concurrency 5
	config_get G_FAMILY global address_family auto
	config_get G_IFACE global interface ''
	config_get G_SOURCE global source ''
	config_get_bool G_PERSISTENCE global persistence 0
	config_get G_HISTORY global history 24h
	config_get G_PERSIST_INTERVAL global persist_interval 300
	config_get G_MAX_POINTS global max_points 4320
	config_get G_LOG_LEVEL global log_level info
	config_get G_FAIL_WARN global fail_warn 3
	config_get G_FAIL_CRITICAL global fail_critical 5
	config_get G_DEFAULT_PROTO global default_proto icmp
	config_get G_DEFAULT_TCP_PORT global default_tcp_port 80

	G_INTERVAL=$(clamp "$G_INTERVAL" 1 3600)
	G_TIMEOUT=$(clamp "$G_TIMEOUT" 1 30)
	G_COUNT=$(clamp "$G_COUNT" 1 20)
	G_CONCURRENCY=$(clamp "$G_CONCURRENCY" 1 50)
	G_PERSIST_INTERVAL=$(clamp "$G_PERSIST_INTERVAL" 60 3600)
	G_MAX_POINTS=$(clamp "$G_MAX_POINTS" 60 200000)
	# 环形缓冲的「软阈值」：实际裁剪到 G_MAX_POINTS，但要超过 RING_TRIM_AT
	# 才动手。多出来的这段余量用来摊薄重写开销，详见 trim_ring() 的说明。
	RING_TRIM_AT=$((G_MAX_POINTS + G_MAX_POINTS / 8))
	[ "$RING_TRIM_AT" -lt 120 ] && RING_TRIM_AT=120
	G_FAIL_WARN=$(clamp "$G_FAIL_WARN" 1 100)
	G_FAIL_CRITICAL=$(clamp "$G_FAIL_CRITICAL" 1 1000)

	valid_iface "$G_IFACE" || G_IFACE=''
	valid_iface "$G_SOURCE" || G_SOURCE=''

	case "$G_DEFAULT_PROTO" in
		icmp|tcp) ;;
		*) G_DEFAULT_PROTO=icmp ;;
	esac
	G_DEFAULT_TCP_PORT=$(clamp "$G_DEFAULT_TCP_PORT" 1 65535)

	# 探测工具只需在配置加载时判定一次
	tcp_tool_probe
	if [ "$TCP_TOOL" = "none" ] && [ "$TCP_WARNED" != "1" ]; then
		TCP_WARNED=1
		log_msg warning "TCP probe unavailable: install curl (or a nc supporting -w); TCP targets will report errno=4"
	fi

	# 目标清单 -> targets.tsv
	: > "$RUN_DIR/targets.tsv"
	config_foreach nm_append_target target
}

nm_append_target() {
	local sid="$1"
	local name host region proto family interval timeout iface source label enabled remark tcp_port

	config_get name "$sid" name "$sid"
	config_get host "$sid" host ''
	config_get region "$sid" region other
	config_get proto "$sid" proto "$G_DEFAULT_PROTO"
	config_get family "$sid" family auto
	config_get interval "$sid" interval 0
	config_get timeout "$sid" timeout 0
	config_get tcp_port "$sid" tcp_port 0
	config_get iface "$sid" interface ''
	config_get source "$sid" source ''
	config_get label "$sid" label ''
	config_get remark "$sid" remark ''
	config_get_bool enabled "$sid" enabled 1

	[ "$enabled" = "1" ] || return 0
	valid_host "$host" || {
		log_msg warning "target '$name' skipped: invalid host '$host'"
		return 0
	}
	valid_iface "$iface" || iface=''
	valid_iface "$source" || source=''

	# 空字段必须写成占位符 '-'：TAB 是 IFS 空白字符，read 会合并连续
	# 分隔符，导致后面的字段整体左移（label 被当成 iface 传进 ping -I）。
	[ -n "$name" ] || name='-'
	[ -n "$iface" ] || iface='-'
	[ -n "$source" ] || source='-'
	[ -n "$label" ] || label='-'
	[ -n "$remark" ] || remark='-'

	case "$region" in
		cn|overseas|other) ;;
		*) region=other ;;
	esac
	case "$family" in
		auto|ipv4|ipv6|both) ;;
		*) family=auto ;;
	esac
	is_uint "$interval" || interval=0
	is_uint "$timeout" || timeout=0

	# proto 只允许 icmp / tcp；tcp 目标未指定端口时继承全局默认端口
	case "$proto" in
		icmp|tcp) ;;
		*) proto="$G_DEFAULT_PROTO" ;;
	esac
	is_uint "$tcp_port" || tcp_port=0
	[ "$tcp_port" -gt 65535 ] && tcp_port=65535
	if [ "$proto" = "tcp" ] && [ "$tcp_port" -lt 1 ]; then
		tcp_port="$G_DEFAULT_TCP_PORT"
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$sid" "$name" "$host" "$region" "$proto" "$timeout" "$interval" \
		"$family" "$iface" "$source" "$label" "$remark" "$tcp_port" >> "$RUN_DIR/targets.tsv"
}

# 目标实际使用的检测间隔（0 表示跟随全局）
target_interval() {
	local iv="$1"
	is_uint "$iv" || iv=0
	[ "$iv" -lt 1 ] && iv=$G_INTERVAL
	[ "$iv" -lt "$G_INTERVAL" ] && iv=$G_INTERVAL
	printf '%s' "$iv"
}

target_timeout() {
	local tv="$1"
	is_uint "$tv" || tv=0
	[ "$tv" -lt 1 ] && tv=$G_TIMEOUT
	printf '%s' "$tv"
}

# 单次探测的 RTT 上界（毫秒）。
#
# ping -W <timeout> 的语义是「等 timeout 秒还没回应，这次就算超时」，所以
# 任何超过 timeout 秒的 RTT，在监控口径里就是超时，而不是「很慢」。
#
# 实测踩过一次：某次采样解析出 4159330.860 ms（约 69 分钟），来源是时钟跳变
# 或输出串味，并非真实延迟。这种值一旦入库，图表 Y 轴被拉到百万毫秒量级，
# 正常的几十毫秒曲线全被压成贴在底部的直线，最大值卡片也跟着显示 4159331 ms。
# 因此在写入前先按探测超时预算卡一道：越界的采样一律按超时记账。
lat_cap() {
	local tv="$1" c
	is_uint "$tv" || tv=$G_TIMEOUT
	[ "$tv" -lt 1 ] && tv=$G_TIMEOUT
	c=$((tv * 1000))
	[ "$c" -lt 1000 ] && c=1000
	printf '%s' "$c"
}

# RTT 是否超出探测超时预算。超出返回 0（真），否则返回 1（假）。
# 延迟是浮点，shell 的整数比较用不了，统一交给 awk。
lat_over_budget() {
	awk -v v="$1" -v c="$2" 'BEGIN { exit !((v + 0) > (c + 0)) }'
}

# ---------------------------------------------------------------- TCP 探测
#
# 为什么不用 nc 作为默认实现：OpenWrt 固件里的 nc 常见为精简版 busybox applet
# （usage 只有 `nc [IPADDR PORT]`），既不支持 -w 超时，也不能「只建连不传数据」。
# 拿它去探测一个被丢弃（DROP）的端口会永久阻塞，进而挂住整轮并发检测。
#
# 因此 TCP 探测的首选实现是 curl：
#   * --connect-timeout 限定握手超时，保证探测有上界；
#   * -w '%{time_connect}' 直接输出 TCP 三次握手耗时（微秒精度），
#     语义上正好等于「TCP ping」的 RTT。
# 而 busybox 的 date 不支持 %N（实测 `date +%s%N` 只返回秒），纯 shell 无法
# 自行测量毫秒级耗时，这也是必须依赖 curl 的原因。
#
# 只有在设备确实没有 curl、且 nc 支持 -w 时，才退化到 nc + /proc/uptime 计时
# （/proc/uptime 只有 10ms 精度，且无法绑定接口/源地址）。

tcp_tool_probe() {
	TCP_TOOL=none

	if command -v curl >/dev/null 2>&1; then
		TCP_TOOL=curl
		return 0
	fi

	if command -v nc >/dev/null 2>&1; then
		# 精简 busybox nc 遇到 -w 会直接打印 Usage；支持 -w 的 nc 不会。
		# 这里探测的是本机回环端口，连接会被立即拒绝，不会长时间阻塞。
		if ! nc -w 1 127.0.0.1 1 </dev/null 2>&1 | grep -q 'Usage'; then
			TCP_TOOL=nc
			return 0
		fi
	fi

	return 0
}

# 单调时钟（毫秒）。只能退到 /proc/uptime，精度 10ms。
mono_ms() {
	local up
	up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
	case "$up" in
		''|*[!0-9.]*)
			printf '0'
			return 0
			;;
	esac
	awk -v v="$up" 'BEGIN { printf "%d", v * 1000 + 0.5 }'
}

# TCP 失败归类：tcp_errno <工具> <退出码> <stderr 文件>
tcp_errno() {
	local tool="$1" rc="$2" errf="$3"
	local msg
	msg=$(cat "$errf" 2>/dev/null)

	case "$tool" in
		curl)
			case "$rc" in
			6)  printf '%s' "$E_DNS" ;;      # CURLE_COULDNT_RESOLVE_HOST
			28) printf '%s' "$E_TIMEOUT" ;;  # CURLE_OPERATION_TIMEDOUT
			7)  # CURLE_COULDNT_CONNECT：区分「无响应」与「被拒绝」
				case "$msg" in
					*imed*out*|*imeout*) printf '%s' "$E_TIMEOUT" ;;
					*) printf '%s' "$E_UNREACH" ;;
				esac
				;;
			*)  printf '%s' "$E_OTHER" ;;
			esac
			;;
		nc)
			case "$msg" in
				*efused*)                printf '%s' "$E_UNREACH" ;;
				*imed*out*|*imeout*)     printf '%s' "$E_TIMEOUT" ;;
				*unknow*|*bad\ address*|*esolv*) printf '%s' "$E_DNS" ;;
				*nreachable*|*route*)    printf '%s' "$E_UNREACH" ;;
				*)                       printf '%s' "$E_OTHER" ;;
			esac
			;;
		*)
			printf '%s' "$E_OTHER"
			;;
	esac
}

# TCP 连接探测。成功时以握手耗时（毫秒）作为延迟；失败时归类到明确 errno。
# 一次连接计为一个「包」（sent=1），因此 TCP 模式下的丢包率等于失败采样占比。
run_check_tcp() {
	# run_check_tcp <id> <host> <port> <timeout> <family> <iface> <source>
	local id="$1" host="$2" port="$3" timeout="$4" family="$5" iface="$6" source="$7"
	local res="$TMP_DIR/$id.res"
	local out="$TMP_DIR/$id.out"
	local errf="$TMP_DIR/$id.err"
	local lat='-' ok=0 eno=$E_OTHER sent=1 recv=0 cap
	local dev= fam_opt= tc= url= rc= tcval= parsed= t0= t1= nc_host=

	if [ "$TCP_TOOL" = "none" ]; then
		printf '%s\t%s\t%s\t%s\t%s\n' '-' '0' "$E_OTHER" "$sent" '0' > "$res"
		return 0
	fi

	: > "$out"
	: > "$errf"

	# 调用方已做全局回退，这里再兜一次，保证单独调用本函数也正确
	[ -n "$iface" ] || iface="$G_IFACE"
	[ -n "$source" ] || source="$G_SOURCE"
	# 源地址比出接口更具体，优先绑定源地址
	dev="$iface"
	[ -n "$source" ] && dev="$source"

	case "$family" in
		ipv4) fam_opt='-4' ;;
		ipv6) fam_opt='-6' ;;
	esac

	if [ "$TCP_TOOL" = "curl" ]; then
		# URL 中的 IPv6 字面量必须加方括号；host 与 port 都经白名单校验后
		# 作为独立参数传入，不做 shell 二次解释，杜绝注入。
		case "$host" in
			*:*) tc="[$host]" ;;
			*)   tc="$host" ;;
		esac
		url="http://$tc:$port/"

		# -q                  忽略 ~/.curlrc
		# -m / --connect-timeout  限定整体与握手超时
		# -w '%{time_connect}'    TCP 握手耗时（秒，微秒精度）
		set -- curl -q -s -o /dev/null \
			-m "$timeout" --connect-timeout "$timeout" \
			-w '%{time_connect}'
		[ -n "$fam_opt" ] && set -- "$@" "$fam_opt"
		[ -n "$dev" ] && set -- "$@" --interface "$dev"
		# --noproxy：避免被环境里的 http_proxy 改写探测目标。
		#
		# 必须写成「选项 + 独立参数」两个元素，不能写 '--noproxy=*'：
		# curl 的等号写法在部分版本上直接报
		#     curl: option --noproxy=*: is unknown
		# 并以退出码 2 退出（curl 8.5.0 实测）。此时 time_connect 恒为 0、
		# rc=2 被归到 errno=4（其它错误），所有 TCP 目标统一显示「检查失败」，
		# 而真正的报错被吞进 stderr 文件里，界面上看不出是参数问题。
		# 手册里该选项的规范形式就是 `--noproxy <list>`，按空格形式传参
		# 在所有版本上都成立。
		set -- "$@" --noproxy '*'
		set -- "$@" "$url"

		rc=0
		"$@" > "$out" 2> "$errf" || rc=$?

		tcval=$(cat "$out" 2>/dev/null)
		case "$tcval" in
			''|*[!0-9.]*) tcval=0 ;;
		esac

		# 连接成功 ⇔ time_connect > 0（握手失败时 curl 输出 0.000000）
		parsed=$(awk -v v="$tcval" 'BEGIN {
			if (v + 0 > 0) printf "%.3f\t1\n", v * 1000;
			else           printf "-\t0\n";
		}')
		lat=$(printf '%s' "$parsed" | cut -f1)
		ok=$(printf '%s' "$parsed" | cut -f2)
	else
		# 后备路径：nc（支持 -w）。精简 nc 无 -s，无法绑定接口/源地址。
		nc_host="$host"
		case "$nc_host" in
			\[*\]*) nc_host=$(printf '%s' "$nc_host" | sed -e 's/^\[//' -e 's/\]$//') ;;
		esac

		t0=$(mono_ms)
		rc=0
		nc -w "$timeout" "$nc_host" "$port" </dev/null > "$out" 2> "$errf" || rc=$?
		t1=$(mono_ms)

		if [ "$rc" = "0" ]; then
			ok=1
			lat=$((t1 - t0))
			[ "$lat" -lt 0 ] && lat=0
		fi
	fi

	if [ "$ok" = "1" ]; then
		eno=$E_OK
		recv=$sent
		# 与 ICMP 同一口径：握手耗时超过探测超时预算，按超时记账
		cap=$(lat_cap "$timeout")
		if lat_over_budget "$lat" "$cap"; then
			log_msg info "target $id: TCP handshake ${lat}ms over timeout budget (${cap}ms), counted as timeout"
			lat='-'
			ok=0
			recv=0
			eno=$E_TIMEOUT
		fi
	else
		lat='-'
		recv=0
		eno=$(tcp_errno "$TCP_TOOL" "$rc" "$errf")
	fi

	printf '%s\t%s\t%s\t%s\t%s\n' "$lat" "$ok" "$eno" "$sent" "$recv" > "$res"
	rm -f "$out" "$errf"
	return 0
}

# ---------------------------------------------------------------- 单次检测
# 按指定地址族执行一次探测。真正的执行体，入口是文件末尾的 run_check()。
run_check_family() {
	# run_check_family <id> <host> <proto> <port> <timeout> <family> <iface> <source>
	local id="$1" host="$2" proto="$3" port="$4" timeout="$5" family="$6"
	local iface="$7" source="$8"
	local out="$TMP_DIR/$id.out"
	local res="$TMP_DIR/$id.res"
	local cmd=ping
	local deadline rc parsed lat ok eno sent recv cap

	# 临时目录已不在时静默跳过。
	#
	# 典型场景：收到 TERM 后主循环退出、cleanup() 删掉了 $TMP_DIR，而本轮
	# 还有探测任务在飞行（wait 被信号中断后不会重新等待）。此时结果文件
	# 写不出来，探测本身也没有任何意义，硬着头皮执行只会在 stderr 上留下
	#     cannot create .../tmp.<pid>/<id>.out: Directory nonexistent
	# 一轮 N 个目标就是 N 条；它还会盖过真正需要关注的探测失败日志。
	[ -d "$TMP_DIR" ] || return 0

	if ! valid_host "$host"; then
		printf '%s\t%s\t%s\t%s\t%s\n' '-' '0' "$E_INVALID" "$G_COUNT" '0' > "$res"
		return 0
	fi

	# TCP 模式走独立的连接探测路径
	if [ "$proto" = "tcp" ]; then
		run_check_tcp "$id" "$host" "$port" "$timeout" "$family" "$iface" "$source"
		return 0
	fi

	: > "$out"

	case "$family" in
		ipv6) command -v ping6 >/dev/null 2>&1 && cmd=ping6 ;;
	esac

	deadline=$((timeout * G_COUNT + 2))

	# 注意：参数通过 "$@" 传递，host 单独加引号，且已校验不以 '-' 开头
	if [ -n "$iface" ]; then
		"$cmd" -c "$G_COUNT" -W "$timeout" -w "$deadline" -I "$iface" "$host" > "$out" 2>&1
	elif [ -n "$source" ]; then
		"$cmd" -c "$G_COUNT" -W "$timeout" -w "$deadline" -I "$source" "$host" > "$out" 2>&1
	else
		"$cmd" -c "$G_COUNT" -W "$timeout" -w "$deadline" "$host" > "$out" 2>&1
	fi
	rc=$?

	parsed=$(awk -v cnt="$G_COUNT" '
		BEGIN { lat = ""; ok = 0; eno = 4; ploss = -1; sent = cnt + 0; }
		/time=/ {
			tmp = $0;
			sub(/^.*time[=<]/, "", tmp);
			sub(/[^0-9.].*$/, "", tmp);
			if (tmp != "" && lat == "") lat = tmp;
		}
		/[0-9]+% packet loss/ {
			tmp = $0;
			if (match(tmp, /[0-9]+(\.[0-9]+)?% packet loss/)) {
				seg = substr(tmp, RSTART, RLENGTH);
				sub(/%.*$/, "", seg);
				ploss = seg + 0;
			}
		}
		/100% packet loss|no answer|timed out|Request timeout|Timeout/ { eno = 1 }
		/Network is unreachable|Network unreachable|No route to host|no route to host|Network is down/ { eno = 3 }
		/bad address|unknown host|not known|Name or service|cannot resolve|failure in name resolution|nodename nor servname|Could not resolve|not found/ { eno = 2 }
		END {
			if (lat != "") ok = 1;
			if (ploss >= 0) recv = int(sent * (100 - ploss) / 100 + 0.5); else recv = (ok ? sent : 0);
			if (ok) { eno = 0; }
			else if (eno == 4 && ploss >= 100) { eno = 1; }
			printf "%s\t%d\t%d\t%d\t%d\n", (ok ? lat : "-"), ok, eno, sent, recv;
		}
	' "$out")

	lat=$(printf '%s' "$parsed" | cut -f1)
	ok=$(printf '%s' "$parsed" | cut -f2)
	eno=$(printf '%s' "$parsed" | cut -f3)
	sent=$(printf '%s' "$parsed" | cut -f4)
	recv=$(printf '%s' "$parsed" | cut -f5)

	# 多包时优先使用 ping 自身给出的平均 RTT
	if [ "$ok" = "1" ] && [ "$G_COUNT" -gt 1 ]; then
		local avg
		avg=$(sed -n 's#.*min/avg/max[^=]*= *[0-9.]*/\([0-9.]*\)/.*#\1#p' "$out" | tail -n 1)
		case "$avg" in
			''|*[!0-9.]*) ;;
			*) lat="$avg" ;;
		esac
	fi

	# 上界检查：RTT 超过探测超时预算的采样按超时记账，不入库为成功样本
	cap=$(lat_cap "$timeout")
	if [ "$ok" = "1" ] && lat_over_budget "$lat" "$cap"; then
		log_msg info "target $id: RTT ${lat}ms over timeout budget (${cap}ms), counted as timeout"
		lat='-'
		ok=0
		eno=$E_TIMEOUT
		recv=0
	fi

	printf '%s\t%s\t%s\t%s\t%s\n' "$lat" "$ok" "$eno" "$sent" "$recv" > "$res"
	rm -f "$out"
	return 0
}

# 单次检测入口：负责地址族分派，具体探测交给 run_check_family()。
#
# 【family=both 双栈】
# UCI、ucode 与前端都提供 both 选项，但此前守护进程只在 run_check 里对
# ipv6 做了特判（换用 ping6），both 与 auto 走完全相同的分支——等于
# 配置项形同虚设，用户选了「IPv4 + IPv6」拿到的仍是系统默认解析顺序。
#
# both 的语义定为「双栈中任一栈可达即认为可达」：先按 IPv4 探测，只有失败
# （超时 / DNS / 不可达 / 工具错误）才再按 IPv6 探测一次，取第一个成功的结果。
# 与 auto 的差别在于 auto 完全交给系统解析顺序（取决于 gai.conf 与解析结果，
# 不会主动重试另一栈），both 则明确覆盖两个栈。
#
# 这样常态下不增加任何开销（v4 成功就不再试 v6），也保持了一次探测一份
# 结果的计数口径：sent/recv 不会因为开了双栈而翻倍。
run_check() {
	# run_check <id> <host> <proto> <port> <timeout> <family> <iface> <source>
	local id="$1" host="$2" proto="$3" port="$4" timeout="$5" family="$6"
	local iface="$7" source="$8"
	local res="$TMP_DIR/$id.res" ok

	# 非法目标直接记账，两个栈都不必试
	if ! valid_host "$host"; then
		printf '%s\t%s\t%s\t%s\t%s\n' '-' '0' "$E_INVALID" "$G_COUNT" '0' > "$res"
		return 0
	fi

	if [ "$family" != "both" ]; then
		run_check_family "$id" "$host" "$proto" "$port" "$timeout" \
			"$family" "$iface" "$source"
		return 0
	fi

	run_check_family "$id" "$host" "$proto" "$port" "$timeout" \
		ipv4 "$iface" "$source"
	# 结果文件是本函数唯一的输出通道：v4 已成功就到此为止
	ok=$(cut -f2 < "$res" 2>/dev/null)
	[ "$ok" = "1" ] && return 0

	run_check_family "$id" "$host" "$proto" "$port" "$timeout" \
		ipv6 "$iface" "$source"
	return 0
}

# 终止本实例派生的探测子进程。
#
# run_check 以后台子 shell 方式并发执行，ping / curl 又由子 shell 再派生，
# 因此真正的探测进程是「孙进程」。procd 发 TERM 后主循环退出、cleanup 删掉
# TMP_DIR，但若不同时终止这些进程：
#   * 它们继续跑完自己的 deadline，白占 CPU 与文件描述符；
#   * 结果文件写进一个已被删除的目录，rm 清理时静默失败，留下脏 inode；
#   * restart 时新旧两批探测短暂并存，探测目标收到的包数翻倍。
#
# 优先按进程组整体终止（只有在本进程确实是该组组长时才这么做，否则负 PID
# 会打到同组的其它进程上）；拿不到进程组信息时退化为按父子关系终止直接子进程。
nm_kill_children() {
	local p c kids

	# run_check 以后台方式执行，所以直接子进程就是那批子 shell。
	kids=$(jobs -p 2>/dev/null)
	[ -n "$kids" ] || return 0

	for p in $kids; do
		# 孙进程：ping / curl 由子 shell 再派生，只杀子 shell 会让它们变孤儿
		# 继续跑完自己的 deadline。这里按父子关系先收掉孙辈、再收子 shell。
		#
		# 刻意不使用「按进程组整体 kill」：`kill -TERM -$$` 的前提是本进程
		# 确为该组组长，而 procd 启动本脚本时进程组如何安排取决于 procd 的
		# 实现与版本；一旦本进程与 procd（或其 helper）同组，负 PID 会把信号
		# 送到它们头上。为了收尾几个探测进程去冒误杀 init 管理进程的风险，
		# 不划算。pgrep 缺失时索性跳过这一层：探测命令自身都带 deadline
		# （ping -w / curl -m），最坏情形是孤儿进程再跑完一次探测预算后自行
		# 退出，且结果文件已随 TMP_DIR 删除、无人消费。
		if command -v pgrep >/dev/null 2>&1; then
			for c in $(pgrep -P "$p" 2>/dev/null); do
				kill -TERM "$c" 2>/dev/null
			done
		fi
		kill -TERM "$p" 2>/dev/null
	done
	return 0
}

# ---------------------------------------------------------------- 统计段维护
update_stats() {
	# update_stats <id> <ts> <lat|-> <ok> <sent> <recv>
	local id="$1" ts="$2" lat="$3" ok="$4" sent="$5" recv="$6"
	local curf="$HIST_DIR/$id.cur"
	local segf="$HIST_DIR/$id.seg"
	local tmpf="$HIST_DIR/$id.tmp"
	local segs_max=$((G_MAX_POINTS / CHUNK + 2))
	local c

	awk -v CUR="$curf" -v SEG="$segf" -v ts="$ts" -v lat="$lat" -v ok="$ok" \
		-v sc="$sent" -v rc="$recv" -v chunk="$CHUNK" -v edges="$BUCKETS" '
		BEGIN {
			nb = split(edges, E, " ");
			for (i = 0; i <= nb; i++) h[i] = 0;
			t0 = ts; sum = 0; cnt = 0; okc = 0; mn = "-"; mx = "-"; sent = 0; recv = 0;
			while ((getline line < CUR) > 0) {
				if (line == "") continue;
				n = split(line, F, "\t");
				if (n < 9) continue;
				t0 = F[1]; sum = F[2] + 0; cnt = F[3] + 0; okc = F[4] + 0;
				mn = F[5]; mx = F[6]; sent = F[7] + 0; recv = F[8] + 0;
				m = split(F[9], HH, " ");
				for (i = 1; i <= m; i++) h[i - 1] = HH[i] + 0;
			}
			close(CUR);
			cnt++;
			sent += sc + 0;
			recv += rc + 0;
			if (ok + 0 == 1) {
				v = lat + 0;
				okc++;
				sum += v;
				if (mn == "-" || mn == "") mn = lat; else if (v < mn + 0) mn = lat;
				if (mx == "-" || mx == "") mx = lat; else if (v > mx + 0) mx = lat;
				b = nb;
				for (i = 0; i < nb; i++) { if (v < E[i + 1] + 0) { b = i; break; } }
				h[b]++;
			}
			out = sprintf("%d\t%.3f\t%d\t%d\t%s\t%s\t%d\t%d\t", t0, sum, cnt, okc, mn, mx, sent, recv);
			for (i = 0; i <= nb; i++) out = out (i > 0 ? " " : "") h[i];
			if (cnt >= chunk) {
				print out >> (SEG);
				close(SEG);
				z = "";
				for (i = 0; i <= nb; i++) z = z (i > 0 ? " " : "") 0;
				print ts "\t0\t0\t0\t-\t-\t0\t0\t" z;
			} else {
				print out;
			}
		}
	' > "$tmpf" && mv "$tmpf" "$curf"

	# 段数量裁剪（丢弃最老的段）
	if [ -f "$segf" ]; then
		c=$(wc -l < "$segf")
		if [ "$c" -gt "$segs_max" ]; then
			tail -n "$segs_max" "$segf" > "$tmpf" && mv "$tmpf" "$segf"
		fi
	fi
}

# 环形缓冲裁剪。
#
# 【为什么要留余量】
# 原实现是「每次追加一行后就检查，超过 max_points 就 tail 重写整个文件」。
# 缓冲区一旦填满，此后**每一次采样**都要做一次 O(n) 读 + O(n) 写：
# 默认 4320 点约 130 KB，10 秒间隔下相当于每 10 秒把 130 KB 整体搬运一遍；
# 把 max_points 配到上限 200000 时，单次搬运约 6 MB，在低端路由器的 tmpfs
# 上这是一笔持续存在、与采样频率成正比的开销。
#
# 现在改成两级阈值：超过 RING_TRIM_AT（max_points 的 1.125 倍）才裁剪，
# 且一次裁回 max_points。重写频率因此降为原来的约 1/540（默认配置下每多
# 累积 540 个样本才搬运一次），代价是缓冲区峰值多占 12.5% 的 tmpfs。
# tmpfs 上的这点内存换取 CPU 与写放大的持续下降是划算的，且裁剪后缓冲区
# 仍严格不超过 max_points，对外可见的上限语义没有变化。
#
# 行数统计（wc）是纯顺序读、不产生写入，开销比重写低一个量级，保留。
trim_ring() {
	local f="$RING_DIR/$1.tsv" c
	[ -f "$f" ] || return 0
	c=$(wc -l < "$f")
	[ "$c" -gt "$RING_TRIM_AT" ] || return 0
	tail -n "$G_MAX_POINTS" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ---------------------------------------------------------------- 一轮检测
run_round() {
	local now id name host region proto timeout tinterval family iface source label remark port
	local st last next plast pok peno sfail sok last_ok total
	local iv tv running=0

	now=$(date +%s)
	running=0

	# 兜底重建本实例的临时目录。
	#
	# 正常情况下它由 setup_dirs() 建好且不会被别人动：目录名带本进程 pid，
	# 且启动时的清理只回收「进程已不存在」的遗留目录。但 /tmp 是共享的，
	# 一旦被外部清掉（有人手工清理、个别固件的 tmp 清理脚本），此后每一轮
	# 采样都会在 stderr 上打一条
	#     cannot create .../tmp.<pid>/<id>.out: Directory nonexistent
	# 一轮 N 个目标就是 N 条，长驻运行会把系统日志刷满，而真正的探测结果
	# 反而在噪声里看不见。这里每轮兜一次，代价是一次 mkdir。
	[ -d "$TMP_DIR" ] || mkdir -p "$TMP_DIR" 2>/dev/null

	while IFS="$TAB" read -r id name host region proto timeout tinterval family iface source label remark port; do
		[ -n "$id" ] || continue
		# 还原写入时的空字段占位符
		[ "$name" = '-' ] && name=''
		[ "$iface" = '-' ] && iface=''
		[ "$source" = '-' ] && source=''
		[ "$label" = '-' ] && label=''
		[ "$remark" = '-' ] && remark=''

		last=0; next=0; plast='-'; pok=0; peno=0; sfail=0; sok=0; last_ok=0; total=0
		st="$STATE_DIR/$id"
		if [ -f "$st" ]; then
			IFS="$TAB" read -r last next plast pok peno sfail sok last_ok total < "$st"
		fi
		is_uint "$last" || last=0

		iv=$(target_interval "$tinterval")
		if [ $((last + iv)) -gt "$now" ]; then
			continue
		fi

		tv=$(target_timeout "$timeout")
		# 目标级接口/源地址未设置时回退到全局
		[ -n "$iface" ] || iface="$G_IFACE"
		[ -n "$source" ] || source="$G_SOURCE"
		case "$family" in
			auto) family="$G_FAMILY" ;;
		esac

		run_check "$id" "$host" "$proto" "$port" "$tv" "$family" "$iface" "$source" &
		running=$((running + 1))
		if [ "$running" -ge "$G_CONCURRENCY" ]; then
			wait
			running=0
		fi
	done < "$RUN_DIR/targets.tsv"

	[ "$running" -gt 0 ] && wait

	collect_results "$now"
}

collect_results() {
	local now="$1"
	local id name host region proto timeout tinterval family iface source label remark port
	local res lat ok eno sent recv
	local st last next plast pok peno sfail sok last_ok total
	local iv

	while IFS="$TAB" read -r id name host region proto timeout tinterval family iface source label remark port; do
		[ -n "$id" ] || continue
		# 还原写入时的空字段占位符
		[ "$name" = '-' ] && name=''
		[ "$iface" = '-' ] && iface=''
		[ "$source" = '-' ] && source=''
		[ "$label" = '-' ] && label=''
		[ "$remark" = '-' ] && remark=''
		res="$TMP_DIR/$id.res"
		[ -f "$res" ] || continue

		IFS="$TAB" read -r lat ok eno sent recv < "$res"
		rm -f "$res"

		last=0; next=0; plast='-'; pok=0; peno=0; sfail=0; sok=0; last_ok=0; total=0
		st="$STATE_DIR/$id"
		if [ -f "$st" ]; then
			IFS="$TAB" read -r last next plast pok peno sfail sok last_ok total < "$st"
		fi
		is_uint "$total" || total=0
		is_uint "$sfail" || sfail=0
		is_uint "$sok" || sok=0
		is_uint "$last_ok" || last_ok=0

		iv=$(target_interval "$tinterval")

		if [ "$ok" = "1" ]; then
			sok=$((sok + 1))
			sfail=0
			last_ok=$now
		else
			sfail=$((sfail + 1))
			sok=0
		fi
		total=$((total + 1))

		# 状态翻转时才写日志，避免刷屏
		if [ "$pok" != "$ok" ]; then
			if [ "$ok" = "1" ]; then
				log_msg info "target '$name' ($host) recovered, latency ${lat}ms"
			else
				log_msg warning "target '$name' ($host) check failed (errno=$eno)"
			fi
		else
			if [ "$sfail" = "$G_FAIL_WARN" ] || [ "$sfail" = "$G_FAIL_CRITICAL" ]; then
				log_msg warning "target '$name' ($host) failed $sfail consecutive times"
			fi
		fi

		# 状态文件用「临时文件 + mv」原子替换。
		#
		# 它是 ucode readState() 读取目标运行时状态的唯一来源。直接 `>` 覆盖
		# 会先把文件截断、再逐字节写入，rpcd 侧的读请求若恰好落在这个窗口
		# 里就会拿到空内容（readState 随即返回全零，界面闪现「从未检测 /
		# 离线」，刷新一次又恢复）—— 一个只在高频轮询下偶发、几乎无法复现
		# 的抖动。mv 在同一 tmpfs 内是原子的，读者要么看到旧值要么看到新值。
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$now" "$((now + iv))" "$lat" "$ok" "$eno" "$sfail" "$sok" "$last_ok" "$total" > "$st.tmp" \
			&& mv -f "$st.tmp" "$st"

		printf '%s\t%s\t%s\t%s\n' "$now" "$lat" "$ok" "$eno" >> "$RING_DIR/$id.tsv"
		trim_ring "$id"

		update_stats "$id" "$now" "$lat" "$ok" "$sent" "$recv"
	done < "$RUN_DIR/targets.tsv"

	# 心跳文件同样原子替换：它是前端判断「后台是否真的在跑」的依据，
	# 截断窗口里被读到会让 tick 变成 0，界面误报「服务未运行」。
	printf '%s\n' "$now" > "$RUN_DIR/tick.tmp" && mv -f "$RUN_DIR/tick.tmp" "$RUN_DIR/tick"
	maybe_persist "$now"
}

# ---------------------------------------------------------------- 持久化
maybe_persist() {
	[ "$G_PERSISTENCE" = "1" ] || return 0
	local now="$1"
	local id name host region proto timeout tinterval family iface source label remark port
	local retention cut last pf lastf agg

	retention=$(retention_seconds "$G_HISTORY")
	cut=$((now - retention))

	while IFS="$TAB" read -r id name host region proto timeout tinterval family iface source label remark port; do
		[ -n "$id" ] || continue
		# 还原写入时的空字段占位符
		[ "$name" = '-' ] && name=''
		[ "$iface" = '-' ] && iface=''
		[ "$source" = '-' ] && source=''
		[ "$label" = '-' ] && label=''
		[ "$remark" = '-' ] && remark=''
		[ -f "$RING_DIR/$id.tsv" ] || continue

		pf="$PERSIST_DIR/$id.agg"
		lastf="$PERSIST_DIR/$id.last"

		last=0
		if [ -f "$lastf" ]; then
			read -r last < "$lastf"
		else
			last=$((now - G_PERSIST_INTERVAL))
		fi
		is_uint "$last" || last=$((now - G_PERSIST_INTERVAL))

		[ $((last + G_PERSIST_INTERVAL)) -gt "$now" ] && continue

		agg=$(awk -F'\t' -v last="$last" -v nowv="$now" '
			$1 > last {
				n++;
				if ($3 == "1") {
					ok++;
					s += $2;
					if (mn == "" || $2 + 0 < mn + 0) mn = $2;
					if (mx == "" || $2 + 0 > mx + 0) mx = $2;
				}
			}
			END {
				if (n > 0) {
					printf "%d\t%.2f\t%s\t%s\t%d\t%d\t%.1f\n", nowv, (ok ? s / ok : 0),
						(mn == "" ? "-" : mn), (mx == "" ? "-" : mx), ok + 0, n, (n - ok) * 100.0 / n;
				}
			}
		' "$RING_DIR/$id.tsv")

		if [ -n "$agg" ]; then
			printf '%s\n' "$agg" >> "$pf"
		fi
		# 落盘到 Flash 的时间戳必须原子替换：这个文件决定下次聚合的起点，
		# 若在写入过程中掉电被截断成半行，恢复后 last 会被 is_uint 判为
		# 非法而回退到 now-interval，导致一个窗口的数据被重复聚合。
		printf '%s\n' "$now" > "$lastf.tmp" && mv -f "$lastf.tmp" "$lastf"

		if [ -f "$pf" ]; then
			awk -F'\t' -v c="$cut" '$1 >= c' "$pf" > "$pf.tmp" && mv "$pf.tmp" "$pf"
		fi
	done < "$RUN_DIR/targets.tsv"
}

# ---------------------------------------------------------------- 主循环
sleep_tick() {
	local i=0
	while [ "$i" -lt "$G_INTERVAL" ]; do
		sleep 1
		i=$((i + 1))
		[ "$RELOAD" = "1" ] && break
		[ "$STOP" = "1" ] && break
	done
}

cleanup() {
	# 终止仍在跑的探测子进程，避免它们变成孤儿白跑到 deadline 为止。
	nm_kill_children

	# 【刻意不再在这里删除 $TMP_DIR】
	#
	# 先前 cleanup 会 rm -rf $TMP_DIR，但收到 TERM 时本轮往往还有探测任务
	# 在飞行：`wait` 被信号打断后不会重新等待，主循环随即退出，于是
	# cleanup 删目录与那些任务写结果文件是并发的。实测 stderr 上会稳定留下
	#     awk: cannot open ".../tmp.<pid>/<id>.out" (No such file or directory)
	#     cannot create ".../tmp.<pid>/<id>.res": Directory nonexistent
	# 一轮 N 个目标就是 N 条，且这类噪声会盖过真正需要关注的探测失败日志。
	#
	# 目录名本来就带本实例 pid，其生命周期由下一次启动时的 setup_dirs()
	# 负责——它只回收「进程已不存在」的 tmp.<pid>，正在运行的实例不受影响。
	# 因此这里留着不删既消除了竞争，也不会造成泄漏（最多残留一个空目录，
	# 下次启动即被回收；init.d 的注释里写的也是这个分工）。
	log_msg info "daemon exited"
}

main() {
	# 先建立目录，load_config 会向 $RUN_DIR 写入目标清单
	setup_dirs
	load_config
	if [ "$G_PERSISTENCE" = "1" ]; then
		mkdir -p "$PERSIST_DIR"
	fi

	trap 'RELOAD=1' HUP
	trap 'STOP=1' TERM INT
	trap 'cleanup' EXIT

	log_msg info "daemon started (interval=${G_INTERVAL}s, timeout=${G_TIMEOUT}s, default-proto=${G_DEFAULT_PROTO}, tcp-tool=${TCP_TOOL}, targets=$(wc -l < "$RUN_DIR/targets.tsv"))"

	while [ "$STOP" != "1" ]; do
		if [ "$RELOAD" = "1" ]; then
			RELOAD=0
			load_config
			setup_dirs
			log_msg info "configuration reloaded"
		fi

		if [ "$G_ENABLED" != "1" ]; then
			sleep 5
			continue
		fi

		run_round
		sleep_tick
	done
}

main "$@"
