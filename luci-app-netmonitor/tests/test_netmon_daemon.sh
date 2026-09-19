#!/bin/sh
# netmon-daemon.sh 单元测试
#
# 覆盖四块核心逻辑：
#   1. ping 输出解析与错误分类（busybox / iputils 两种格式，6 类结果）
#   2. targets.tsv 字段解析（含 TAB 合并导致字段错位的回归护栏）
#   3. 分段直方图：分桶归属与段固化
#   4. TCP 探测（proto=tcp）：curl 主路径、nc 后备路径、工具缺失降级，
#      以及 tcp_port 的「显式优先 / 缺省继承全局」判定
#   5. 临时目录按实例隔离（reload 竞态）与 config_load 变量缓存清理
#
# 运行环境：Windows / Git Bash 开发机 与 OpenWrt 设备（busybox ash）均可。
# 用法：sh tests/test_netmon_daemon.sh
#
# 说明：本测试不 set -e。被测脚本里的外部命令返回非零（如 Windows 无 logger）
#       在 set -e 下会让测试无声退出，这是此类测试最常见的坑。

PASS=0
FAIL=0
SKIP=0

assert_eq() {
	# assert_eq <描述> <期望> <实际>
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
		printf '  ok    %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s\n' "$1"
		printf '        期望=[%s] 实际=[%s]\n' "$2" "$3"
	fi
}

assert_contains() {
	# assert_contains <描述> <子串> <文本>
	case "$3" in
		*"$2"*)
			PASS=$((PASS + 1))
			printf '  ok    %s\n' "$1"
			;;
		*)
			FAIL=$((FAIL + 1))
			printf '  FAIL  %s (未包含 [%s])\n' "$1" "$2"
			printf '        实际=[%s]\n' "$3"
			;;
	esac
}

assert_not_contains() {
	case "$3" in
		*"$2"*)
			FAIL=$((FAIL + 1))
			printf '  FAIL  %s (不应包含 [%s])\n' "$1" "$2"
			printf '        实际=[%s]\n' "$3"
			;;
		*)
			PASS=$((PASS + 1))
			printf '  ok    %s\n' "$1"
			;;
	esac
}

# ------------------------------------------------------------------ 环境搭建
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
[ -n "$SCRIPT_DIR" ] || SCRIPT_DIR=.
DAEMON="$SCRIPT_DIR/../root/usr/libexec/netmonitor/netmon-daemon.sh"

if [ ! -f "$DAEMON" ]; then
	echo "找不到被测脚本: $DAEMON" >&2
	exit 1
fi

WORK="$SCRIPT_DIR/.tmp"
mkdir -p "$WORK"

# 把脚本当库加载：截掉 main() 及之后的分发段，只保留函数与变量定义。
# 锚点 ^main() { 在脚本中唯一，已用 grep 确认。
LIB="$WORK/lib.sh"
sed '/^main() {/,$d' "$DAEMON" | sed "s|^\. /lib/functions.sh\$|# /lib/functions.sh: 测试中不加载|" > "$LIB"

# 命令替身。
#
# 这里用 shell 函数而不是「stub 目录前置到 PATH」：在本开发环境下 rm 被
# safe-delete shim 包装（实际执行 C:\...\safe-bin\rm），它会走回收站往返，
# 单次可达数秒甚至直接挂起；而该 shim 是 shell 层实现，前置 PATH 无法覆盖它。
# shell 函数的优先级高于外部命令与既有函数，是这里唯一可靠的覆盖方式。
STUB="$WORK/stub"
STUB_DIR="$STUB"
mkdir -p "$STUB"
export STUB_DIR

# ping 替身：输出取 $STUB_DIR/ping.out，返回码取 ping.rc，参数记录到 ping.args
ping() {
	: > "$STUB_DIR/ping.args"
	for _a in "$@"; do
		printf '%s\n' "$_a" >> "$STUB_DIR/ping.args"
	done
	[ -f "$STUB_DIR/ping.out" ] && cat "$STUB_DIR/ping.out"
	return "$(cat "$STUB_DIR/ping.rc" 2>/dev/null || echo 0)"
}

# logger 替身：Windows 开发机没有 logger，缺失会返回 127
logger() { return 0; }

# rm 替身：被测代码中 rm 仅用于清理临时文件，替换为 no-op 不影响被测逻辑，
# 同时避免 safe-delete 往返把测试从秒级拖到分钟级。
rm() { return 0; }

# 被测库
. "$LIB"

# 把运行目录重定向到工作区，避免污染设备上的 /tmp/netmonitor
RUN_DIR="$WORK/run"
RING_DIR="$RUN_DIR/ring"
HIST_DIR="$RUN_DIR/hist"
STATE_DIR="$RUN_DIR/state"
TMP_DIR="$RUN_DIR/tmp"
PERSIST_DIR="$WORK/persist"
mkdir -p "$RING_DIR" "$HIST_DIR" "$STATE_DIR" "$TMP_DIR" "$PERSIST_DIR"

G_MAX_POINTS=1000
G_COUNT=1
G_CONCURRENCY=5
G_FAIL_WARN=3
G_FAIL_CRITICAL=5

echo "== 1. ping 输出解析与错误分类 =="

# ping_case <用例名> <host> <输出文件> <返回码> <期望 lat> <期望 ok> <期望 eno>
ping_case() {
	_name="$1"; _host="$2"; _out="$3"; _rc="$4"
	_exp_lat="$5"; _exp_ok="$6"; _exp_eno="$7"

	cp "$_out" "$STUB_DIR/ping.out"
	printf '%s\n' "$_rc" > "$STUB_DIR/ping.rc"

	_res="$TMP_DIR/tc.res"
	: > "$_res"
	# run_check <id> <host> <proto> <port> <timeout> <family> <iface> <source>
	run_check tc "$_host" icmp 0 3 ipv4 "" ""
	# res 格式: lat \t ok \t eno \t sent \t recv
	_got_lat=$(cut -f1 < "$_res")
	_got_ok=$(cut -f2 < "$_res")
	_got_eno=$(cut -f3 < "$_res")

	assert_eq "$_name: lat" "$_exp_lat" "$_got_lat"
	assert_eq "$_name: ok" "$_exp_ok" "$_got_ok"
	assert_eq "$_name: errno" "$_exp_eno" "$_got_eno"
}

# --- 构造各类 ping 输出样本 ---
S="$WORK/samples"
mkdir -p "$S"

# 1) busybox 成功
cat > "$S/ok_busybox" <<'EOF'
PING www.baidu.com (110.242.68.4): 56 data bytes
64 bytes from 110.242.68.4: seq=0 ttl=52 time=20.529 ms

--- www.baidu.com ping statistics ---
1 packets transmitted, 1 packets received, 0% packet loss
round-trip min/avg/max = 20.529/20.529/20.529 ms
EOF

# 2) busybox 100% 丢包（超时）
cat > "$S/timeout_busybox" <<'EOF'
PING 1.1.1.1 (1.1.1.1): 56 data bytes

--- 1.1.1.1 ping statistics ---
1 packets transmitted, 0 packets received, 100% packet loss
EOF

# 3) DNS 解析失败（busybox: bad address）
cat > "$S/dns_badaddr" <<'EOF'
ping: bad address 'no.such.host.example'
EOF

# 4) DNS 解析失败（unknown host）
cat > "$S/dns_unknown" <<'EOF'
ping: unknown host no.such.host.example
EOF

# 5) 网络不可达
cat > "$S/unreachable" <<'EOF'
PING 192.0.2.1 (192.0.2.1): 56 data bytes
ping: sendto: Network is unreachable
EOF

# 6) iputils 成功格式
cat > "$S/ok_iputils" <<'EOF'
PING www.baidu.com (110.242.68.4) 56(84) bytes of data.
64 bytes from 110.242.68.4: icmp_seq=1 ttl=52 time=11.3 ms

--- www.baidu.com ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 11.300/11.300/11.300/0.000 ms
EOF

ping_case "busybox 成功"      "www.baidu.com" "$S/ok_busybox"     0 "20.529" 1 0
ping_case "busybox 超时"      "1.1.1.1"       "$S/timeout_busybox" 1 "-"     0 1
ping_case "bad address(DNS)"  "x.example"     "$S/dns_badaddr"     1 "-"     0 2
ping_case "unknown host(DNS)" "x.example"     "$S/dns_unknown"     1 "-"     0 2
ping_case "网络不可达"        "192.0.2.1"     "$S/unreachable"     1 "-"     0 3
ping_case "iputils 成功"      "www.baidu.com" "$S/ok_iputils"      0 "11.3"  1 0

# 7) 异常 RTT：远大于探测超时预算（回归护栏）
#
# 实机出现过 time=4159330.860 ms（约 69 分钟）的采样，来源是时钟跳变或输出串味，
# 并非真实延迟。它一旦入库，图表 Y 轴被拉到百万毫秒量级，正常曲线被压成直线，
# 最大值卡片也跟着显示 4159331 ms。这里断言此类采样必须按超时记账，
# 而不是当作一个「很慢但成功」的样本。
cat > "$S/absurd_rtt" <<'EOF'
PING 8.8.8.8 (8.8.8.8): 56 data bytes
64 bytes from 8.8.8.8: seq=0 ttl=117 time=4159330.860 ms

--- 8.8.8.8 ping statistics ---
1 packets transmitted, 1 packets received, 0% packet loss
round-trip min/avg/max = 4159330.860/4159330.860/4159330.860 ms
EOF

ping_case "异常 RTT 超预算"    "8.8.8.8"       "$S/absurd_rtt"      0 "-"     0 1

# 7) 非法目标：host 以 '-' 开头（防止参数注入）
printf '%s\n' "0" > "$STUB_DIR/ping.rc"
cp "$S/ok_busybox" "$STUB_DIR/ping.out"
: > "$TMP_DIR/tc.res"
run_check tc "-evil-host" icmp 0 3 ipv4 "" ""
assert_eq "非法 host: errno" "5" "$(cut -f3 < "$TMP_DIR/tc.res")"
assert_eq "非法 host: ok"    "0" "$(cut -f2 < "$TMP_DIR/tc.res")"

echo
echo "== 2. targets.tsv 字段解析（TAB 合并错位的回归护栏）=="

# 2a. 修复后格式：空字段写成占位符 '-'
printf '%s\n' \
"alidns	AliDNS	223.5.5.5	cn	icmp	3	0	ipv4	-	-	DNS	-" \
> "$RUN_DIR/targets.tsv"

cp "$S/ok_busybox" "$STUB_DIR/ping.out"
printf '%s\n' "0" > "$STUB_DIR/ping.rc"
: > "$STUB_DIR/ping.args"
run_round

_args=$(cat "$STUB_DIR/ping.args" 2>/dev/null)
assert_contains     "修复后: host 正确传给 ping" "223.5.5.5" "$_args"
assert_not_contains "修复后: label 未被当作 -I 参数" "-I" "$_args"

# 2b. 回归护栏：旧写法（空字段留空、产生连续 TAB）必须被判定为错位。
#     这是本测试存在的理由——真实故障表现为 `ping -I DNS 223.5.5.5`，
#     busybox 报 bad address 'DNS'，被错误归类成 DNS 解析失败。
printf '%s\n' \
"alidns	AliDNS	223.5.5.5	cn	icmp	3	0	ipv4			DNS	" \
> "$RUN_DIR/targets.tsv"

# 必须清空 state：否则「未到下次检测时间」会让本轮直接跳过，ping 不会被调用，
# 护栏就检测不到错位（表现为参数为空而非断言失败）。
: > "$STATE_DIR/alidns"
: > "$STUB_DIR/ping.args"
run_round
_args_old=$(cat "$STUB_DIR/ping.args" 2>/dev/null)
if printf '%s' "$_args_old" | grep -q '^-I$' 2>/dev/null; then
	PASS=$((PASS + 1))
	printf '  ok    回归护栏: 旧写法确实产生 -I 参数（字段已错位）\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL  回归护栏: 旧写法未复现错位，护栏失效\n'
	printf '        实际参数=[%s]\n' "$_args_old"
fi

echo
echo "== 3. 分段直方图：分桶与段固化 =="

CHUNK=3   # 段容量改小，便于在测试中触发段固化（生产值为 60）

_id=hist
: > "$HIST_DIR/$_id.cur"
: > "$HIST_DIR/$_id.seg"

# 单次成功样本 lat=25：桶上界为 1 5 10 20 30 ...，25 落在第 5 个桶（索引 4）
update_stats "$_id" 1000 25 1 1 1
_cur=$(cat "$HIST_DIR/$_id.cur")
_hist_field=$(printf '%s' "$_cur" | cut -f9)
assert_eq "分桶: lat=25 落在索引 4 的桶" "0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0" "$_hist_field"
assert_eq "分桶: cnt"  "1" "$(printf '%s' "$_cur" | cut -f3)"
assert_eq "分桶: min"  "25" "$(printf '%s' "$_cur" | cut -f5)"

# 再喂 2 个样本，cnt 达到 CHUNK=3 → 当前段应固化进 .seg 并重置
update_stats "$_id" 1001 120 1 1 1
update_stats "$_id" 1002 300 1 1 1

_seg_lines=$(wc -l < "$HIST_DIR/$_id.seg" | tr -d ' ')
assert_eq "段固化: .seg 行数" "1" "$_seg_lines"
_cur_after=$(cat "$HIST_DIR/$_id.cur")
assert_eq "段固化: 当前段已重置 cnt" "0" "$(printf '%s' "$_cur_after" | cut -f3)"
assert_eq "段固化: 重置后 min 为空占位" "-" "$(printf '%s' "$_cur_after" | cut -f5)"

# 失败样本不应进入直方图，但应计入 sent
update_stats "$_id" 1003 "-" 0 1 0
_cur2=$(cat "$HIST_DIR/$_id.cur")
assert_eq "失败样本: cnt 增加" "1" "$(printf '%s' "$_cur2" | cut -f3)"
assert_eq "失败样本: ok 计数不增加" "0" "$(printf '%s' "$_cur2" | cut -f4)"
assert_eq "失败样本: sent 计入" "1" "$(printf '%s' "$_cur2" | cut -f7)"


echo
echo "== 4. TCP 探测（proto=tcp）=="

# curl 替身：stdout 取 curl.out（模拟 -w '%{time_connect}' 的输出），
# 返回码取 curl.rc，stderr 取 curl.err，参数记录到 curl.args。
# 注意：shell 函数的优先级高于外部命令，"$@" 里的 curl 会被解析到这个替身。
curl() {
	: > "$STUB_DIR/curl.args"
	for _a in "$@"; do
		printf '%s\n' "$_a" >> "$STUB_DIR/curl.args"
	done
	[ -f "$STUB_DIR/curl.out" ] && cat "$STUB_DIR/curl.out"
	[ -f "$STUB_DIR/curl.err" ] && cat "$STUB_DIR/curl.err" >&2
	return "$(cat "$STUB_DIR/curl.rc" 2>/dev/null || echo 0)"
}

# tcp_case <描述> <stdout> <rc> <stderr> <期望 lat> <期望 ok> <期望 eno>
tcp_case() {
	_name="$1"; _out="$2"; _rc="$3"; _err="$4"
	_exp_lat="$5"; _exp_ok="$6"; _exp_eno="$7"

	printf '%s' "$_out" > "$STUB_DIR/curl.out"
	printf '%s\n' "$_rc" > "$STUB_DIR/curl.rc"
	printf '%s' "$_err" > "$STUB_DIR/curl.err"

	TCP_TOOL=curl
	# 结果文件名由 id 决定：run_check_tcp tc2 → $TMP_DIR/tc2.res
	_res="$TMP_DIR/tc2.res"
	: > "$_res"
	run_check_tcp tc2 "1.1.1.1" 443 3 ipv4 "" ""

	assert_eq "$_name: lat"   "$_exp_lat" "$(cut -f1 < "$_res")"
	assert_eq "$_name: ok"    "$_exp_ok"  "$(cut -f2 < "$_res")"
	assert_eq "$_name: errno" "$_exp_eno" "$(cut -f3 < "$_res")"
	assert_eq "$_name: sent"  "1"         "$(cut -f4 < "$_res")"
}

# time_connect 是「秒」，探测结果必须换算成毫秒
tcp_case "TCP 握手成功"        "0.012345" 0 ""  "12.345" 1 0
tcp_case "TCP 握手成功(慢)"    "0.500000" 0 ""  "500.000" 1 0

# 握手耗时超过探测超时预算（timeout=3s）时同样按超时记账，与 ICMP 同一口径
tcp_case "TCP 握手超预算"      "4.000000" 0 ""  "-"      0 1

# 连接被拒绝：curl 输出 0.000000，rc=7
tcp_case "TCP 被拒绝"          "0.000000" 7 "curl: (7) Failed to connect to 1.1.1.1 port 443: Connection refused" "-" 0 3
# 连接超时：rc=7 但 stderr 明说是 timeout
tcp_case "TCP 连接超时(rc=7)"  "0.000000" 7 "curl: (7) Failed to connect to 1.1.1.1 port 443: Connection timed out" "-" 0 1
# 整体超时：rc=28
tcp_case "TCP 操作超时(rc=28)" "0.000000" 28 "" "-" 0 1
# DNS 失败：rc=6
tcp_case "TCP DNS 失败"        "0.000000" 6 "curl: (6) Could not resolve host: x.invalid" "-" 0 2
# 其它错误：rc=52（连接成功后响应异常，但 time_connect 已为 0 说明没连上）
tcp_case "TCP 其它错误"        "0.000000" 52 "" "-" 0 4

# 兜底：TCP 工具缺失（既无 curl 也无可用 nc）
TCP_TOOL=none
: > "$TMP_DIR/tcpnone.res"
run_check_tcp tcpnone "1.1.1.1" 443 3 ipv4 "" ""
assert_eq "TCP 工具缺失: ok"    "0" "$(cut -f2 < "$TMP_DIR/tcpnone.res")"
assert_eq "TCP 工具缺失: errno" "4" "$(cut -f3 < "$TMP_DIR/tcpnone.res")"
assert_eq "TCP 工具缺失: lat"   "-" "$(cut -f1 < "$TMP_DIR/tcpnone.res")"

# nc 后备路径
nc() { return 0; }
TCP_TOOL=nc
: > "$TMP_DIR/tcnc.res"
run_check_tcp tcnc "1.1.1.1" 443 3 ipv4 "" ""
assert_eq "nc 后备: ok"    "1" "$(cut -f2 < "$TMP_DIR/tcnc.res")"
assert_eq "nc 后备: errno" "0" "$(cut -f3 < "$TMP_DIR/tcnc.res")"

nc() {
	printf '%s\n' 'nc: 1.1.1.1 (1.1.1.1:443): Connection refused' >&2
	return 1
}
: > "$TMP_DIR/tcnc2.res"
run_check_tcp tcnc2 "1.1.1.1" 443 3 ipv4 "" ""
assert_eq "nc 后备 被拒绝: ok"    "0" "$(cut -f2 < "$TMP_DIR/tcnc2.res")"
assert_eq "nc 后备 被拒绝: errno" "3" "$(cut -f3 < "$TMP_DIR/tcnc2.res")"

# tcp_errno 归类（直接单测）
: > "$STUB_DIR/err.empty"
printf '%s\n' 'curl: (7) Failed to connect: Connection timed out' > "$STUB_DIR/err.timeout"
printf '%s\n' 'nc: 1.1.1.1 (1.1.1.1:443): Connection refused' > "$STUB_DIR/err.refused"
printf '%s\n' 'nc: bad address no.such.host.example' > "$STUB_DIR/err.badaddr"
assert_eq "tcp_errno: curl 6 -> DNS"       "2" "$(tcp_errno curl 6 "$STUB_DIR/err.empty")"
assert_eq "tcp_errno: curl 28 -> 超时"     "1" "$(tcp_errno curl 28 "$STUB_DIR/err.empty")"
assert_eq "tcp_errno: curl 7 -> 不可达"    "3" "$(tcp_errno curl 7 "$STUB_DIR/err.empty")"
assert_eq "tcp_errno: curl 7 超时文案"     "1" "$(tcp_errno curl 7 "$STUB_DIR/err.timeout")"
assert_eq "tcp_errno: curl 52 -> 其它"     "4" "$(tcp_errno curl 52 "$STUB_DIR/err.empty")"
assert_eq "tcp_errno: nc 被拒绝 -> 不可达" "3" "$(tcp_errno nc 1 "$STUB_DIR/err.refused")"
assert_eq "tcp_errno: nc DNS 失败 -> DNS"  "2" "$(tcp_errno nc 1 "$STUB_DIR/err.badaddr")"

# tcp_tool_probe：本环境必定存在 curl（Git Bash / 设备），应选中 curl
tcp_tool_probe
assert_eq "tcp_tool_probe 选择 curl" "curl" "$TCP_TOOL"

echo
echo "== 5. tcp_port 解析（显式优先 / 缺省继承全局）=="

# config_get 替身：用 CFG_<sid>_<key> 变量模拟 UCI 段内容
config_get() {
	eval "_v=\${CFG_${2}_${3}-\$4}"
	eval "$1=\"\$_v\""
}
config_get_bool() { config_get "$@"; }

RUN_DIR_SAVE="$RUN_DIR"
RUN_DIR="$WORK/run_tcp"
mkdir -p "$RUN_DIR"
G_DEFAULT_PROTO=icmp
G_DEFAULT_TCP_PORT=8443

CFG_cfgTCP_name='TCP Target'
CFG_cfgTCP_host='1.1.1.1'
CFG_cfgTCP_proto='tcp'
CFG_cfgTCP_tcp_port='0'

: > "$RUN_DIR/targets.tsv"
nm_append_target cfgTCP
_line=$(cat "$RUN_DIR/targets.tsv")
assert_eq "TSV 列数"                "13"   "$(printf '%s' "$_line" | awk -F'\t' '{print NF}')"
assert_eq "缺省端口继承全局默认"    "8443" "$(printf '%s' "$_line" | cut -f13)"
assert_eq "proto 列"                "tcp"  "$(printf '%s' "$_line" | cut -f5)"

# 显式端口优先于全局默认
CFG_cfgTCP_tcp_port='2222'
: > "$RUN_DIR/targets.tsv"
nm_append_target cfgTCP
assert_eq "显式端口优先" "2222" "$(cut -f13 < "$RUN_DIR/targets.tsv")"

# 目标未设置 proto 时继承全局默认探测方式
unset CFG_cfgTCP_proto
G_DEFAULT_PROTO=tcp
: > "$RUN_DIR/targets.tsv"
nm_append_target cfgTCP
assert_eq "proto 缺省继承全局" "tcp" "$(cut -f5 < "$RUN_DIR/targets.tsv")"

# 非法的 proto 值必须被纠正回全局默认，不允许写进 TSV
CFG_cfgTCP_proto='udp'
: > "$RUN_DIR/targets.tsv"
nm_append_target cfgTCP
assert_eq "非法 proto 被纠正" "tcp" "$(cut -f5 < "$RUN_DIR/targets.tsv")"

RUN_DIR="$RUN_DIR_SAVE"

echo "== 6. 临时目录按实例隔离（reload 竞态回归护栏）=="

# 背景：procd 的 term_timeout 是 5s，而一次 ping 最长要跑 timeout*count+2 秒，
# 因此 reload→restart 时旧实例往往还在收尾。若新旧实例共用一个 tmp 目录，
# 新实例启动时的清理会删掉旧实例正在写的 .out，旧实例随即解析失败、写出
# 全空结果——实机表现为 `awk: ... No such file or directory`、一条
# `check failed (errno=)` 假告警，以及环缓存里多出一条空采样。
# 这里把 rm 换成「只记录调用参数」的替身（仍是 no-op，保持测试速度），
# 断言清理范围只落在「进程已不存在」的目录上。

rm() { printf '%s\n' "$*" >> "$STUB_DIR/rm.calls"; return 0; }

RUN_DIR="$WORK/run"
mkdir -p "$RUN_DIR"
TMP_DIR="$RUN_DIR/tmp.88888888"
mkdir -p "$TMP_DIR" "$RUN_DIR/tmp.$$" "$RUN_DIR/tmp.99999999"
: > "$RUN_DIR/tmp.99999999/leftover.out"
: > "$RUN_DIR/tmp.$$/inflight.out"
: > "$STUB_DIR/rm.calls"

setup_dirs
_calls=$(cat "$STUB_DIR/rm.calls" 2>/dev/null)

assert_eq "setup_dirs 建立自己的 TMP_DIR" "yes" "$([ -d "$TMP_DIR" ] && echo yes || echo no)"
assert_not_contains "不清理本实例自己的目录" "tmp.88888888" "$_calls"
if [ -d "/proc/$$" ]; then
	assert_not_contains "不清理存活实例的目录" "tmp.$$" "$_calls"
else
	SKIP=$((SKIP + 1))
	printf '  skip  存活实例目录保护（本环境无 /proc/$$）\n'
fi
assert_contains "回收死进程遗留的目录" "tmp.99999999" "$_calls"

# 护栏：源码里必须按 pid 隔离，且启动/退出都不再整体清空公用 tmp 目录
_src=$(cat "$DAEMON")
assert_contains     "源码中 TMP_DIR 按 pid 隔离" 'TMP_DIR=$RUN_DIR/tmp.$$' "$_src"
assert_not_contains "源码中不再清空公用 tmp/*"   'rm -f "$TMP_DIR"/*' "$_src"

RUN_DIR="$RUN_DIR_SAVE"

echo "== 7. reload 不残留已删除选项的旧值（config_load 变量缓存清理）=="

# 背景：config_load 只为「配置里存在的选项」导出 CONFIG_<段>_<选项> 变量，
# 不会清除被删除选项的旧变量；config_get 先看变量、再退默认值，
# 于是长驻守护进程 reload 后会继续读到旧值。
CONFIG_baidu_label='AAA'
CONFIG_SECTIONS='baidu'
CONFIG_global_enabled='1'
NM_UNRELATED='keep'

clear_config_cache

assert_eq "清掉被删除选项的残留变量"   ""     "${CONFIG_baidu_label:-}"
assert_eq "清掉 CONFIG_SECTIONS 段缓存" ""     "${CONFIG_SECTIONS:-}"
assert_eq "清掉全局选项残留变量"       ""     "${CONFIG_global_enabled:-}"
assert_eq "不动非 CONFIG_ 前缀变量"    "keep" "${NM_UNRELATED:-}"

# 顺序护栏：load_config 内必须先清缓存、再 config_load
_lc=$(sed -n '/^load_config() {/,/^}/p' "$DAEMON")
_clr=$(printf '%s\n' "$_lc" | grep -n 'clear_config_cache' | head -1 | cut -d: -f1)
_ld=$(printf '%s\n' "$_lc" | grep -n 'config_load netmonitor' | head -1 | cut -d: -f1)
if [ -n "$_clr" ] && [ -n "$_ld" ] && [ "$_clr" -lt "$_ld" ]; then
	PASS=$((PASS + 1))
	printf '  ok    load_config 中先清缓存再 config_load\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL  load_config 中先清缓存再 config_load (clear=%s load=%s)\n' "$_clr" "$_ld"
fi
assert_contains "源码中存在 clear_config_cache" 'clear_config_cache' "$(cat "$DAEMON")"

# 反例护栏：警告不能用管道 while 写（子 shell 里 unset 无效）。
# 先剥掉注释再断言 —— 守护进程的注释里正是用这个反例来解释坑在哪，
# 若连注释一起匹配，护栏会被自己的文档误伤。
_src_code=$(sed 's/#.*//' "$DAEMON")
assert_not_contains "未使用管道 while 清缓存" 'set | while' "$_src_code"

echo
echo "======================================"
printf '通过 %d, 失败 %d, 跳过 %d\n' "$PASS" "$FAIL" "$SKIP"
echo "工作区: $WORK"

if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
