#!/bin/sh
# pc-acceptance 验收白盒用例（W3..W32，回溯 docs/superpowers/specs/pc-acceptance-testplan.md §2）。
# 复审 S3 结构整理：从 init_test.sh 拆出（断言逐字保留、未削弱），单条目 weburl 夹具
# 改用 lib.sh 的 put_weburl 构造器去重。运行： sh test/acceptance_test.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
t_setup

FAKE_DATE_YMD=2026-06-08 FAKE_DATE_DOW=1 FAKE_DATE_HM=13:00   # 标准平日

# 本套件各块共用的解析 fixture；需要别的解析时各自 put_resolve 覆盖
put_std_resolve() {
	put_resolve <<'EOF'
4 example.com 1.2.3.4
4 www.example.com 1.2.3.4
6 example.com 2402:4e00:1410::1
6 www.example.com 2402:4e00:1410::1
EOF
}

echo '== W3：组合配置（time+protocol+weburl 各一）走真实 start 全流程 =='
# 旧版缺陷的形态：构建崩在 time 之后 → protocol/weburl 两组规则悄悄没装。
# 钉住「三类规则都在，且 start 跑到生命周期末尾（crontab 已写）」。
fresh
cfg_begin 1
cfg_section <<'EOF'
config time
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:01'
	option sd_quota '10'
config protocol
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:02'
	option proto 'tcp'
	option portd '80'
	option sd_quota '10'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_quota '10'
EOF
cfg_apply
put_std_resolve
: > "$FAKE_CRONTAB"
( start ) >"$T_TMP/w3.out" 2>"$T_TMP/w3.err"
W3_RC=$?
t_eq 'start 跑到底（退出码 0）' 0 "$W3_RC"
t_eq 'stderr 无语法错误/命令找不到' '' "$(grep -E 'syntax error|not found|unexpected' "$T_TMP/w3.err" 2>/dev/null || true)"
A=$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)
t_has 'time 条目计数规则已安装' "$A" '-j PCA_time_0'
t_has 'protocol 条目计数规则已安装' "$A" '-j PCA_protocol_0'
t_has 'weburl 条目计数规则已安装' "$A" '-j PCA_weburl_0'
t_has 'start 跑到了生命周期末尾（crontab 已写）' "$(cat "$FAKE_CRONTAB")" 'tick'
pc_usage_add time_0 10
pc_usage_add protocol_0 10
pc_usage_add weburl_0 10
build_quota_blocks
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)
t_has 'time 耗尽 → 封' "$Q" '-m mac --mac-source aa:bb:cc:dd:ee:01 -j DROP'
t_has 'protocol 耗尽 → 封' "$Q" '-p tcp --dport 80 -j DROP'
t_has 'weburl 耗尽 → 封' "$Q" '-d 1.2.3.0/24 -j DROP'

echo '== W4：del_rule 清掉全部旧规则 + start ×3 不堆叠 =='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 example.com '' 30
cfg_apply
put_std_resolve
# 预置「旧版本」遗留状态：老 filter 链 + 各内置链跳转 + 老 mangle WEBURL/IP 链与跳转
# + 当前两条链 + 残留 PCA 链
iptables-legacy -t filter -N PARENTCONTROL_TIME
iptables-legacy -t filter -A INPUT -j PARENTCONTROL_TIME
iptables-legacy -t filter -N PARENTCONTROL_PROTOCOL
iptables-legacy -t filter -A FORWARD -j PARENTCONTROL_PROTOCOL
iptables-legacy -t filter -N PARENTCONTROL_WEBURL
iptables-legacy -t filter -A OUTPUT -j PARENTCONTROL_WEBURL
iptables-legacy -t mangle -N PARENTCONTROL_WEBURL
iptables-legacy -t mangle -I PREROUTING -j PARENTCONTROL_WEBURL
iptables-legacy -t mangle -N PARENTCONTROL_IP
iptables-legacy -t mangle -I PREROUTING -j PARENTCONTROL_IP
iptables-legacy -t mangle -N PARENTCONTROL_QUOTA
iptables-legacy -t mangle -I PREROUTING -j PARENTCONTROL_QUOTA
iptables-legacy -t mangle -N PARENTCONTROL_ACCT
iptables-legacy -t mangle -I PREROUTING -j PARENTCONTROL_ACCT
iptables-legacy -t mangle -N PCA_weburl_9
ip6tables-legacy -t mangle -N PARENTCONTROL_WEBURL
ip6tables-legacy -t mangle -I PREROUTING -j PARENTCONTROL_WEBURL
ip6tables-legacy -t filter -N PARENTCONTROL_TIME
ip6tables-legacy -t filter -A INPUT -j PARENTCONTROL_TIME
del_rule
t_eq 'filter 表无 PARENTCONTROL 链(v4)' '' "$(ipt_chains v4 filter | grep PARENTCONTROL || true)"
t_eq 'mangle 表无 PARENTCONTROL 链(v4)' '' "$(ipt_chains v4 mangle | grep PARENTCONTROL || true)"
t_eq '老 mangle WEBURL/IP 链清掉(v6 同)' '' "$(ipt_chains v6 mangle | grep PARENTCONTROL || true)"
t_eq '老 filter TIME 链清掉(v6 同)' '' "$(ipt_chains v6 filter | grep PARENTCONTROL || true)"
t_eq 'PREROUTING 无残留跳转(v4)' '' "$(ipt_jump v4 mangle PREROUTING | flat)"
t_eq 'PREROUTING 无残留跳转(v6)' '' "$(ipt_jump v6 mangle PREROUTING | flat)"
t_eq '残留 PCA 链也被清' '' "$(ipt_chains v4 mangle | grep PCA_ || true)"
( start ) >/dev/null 2>&1
N1=$(ipt_all v4 | wc -l | tr -d ' ')
J1=$(ipt_jump v4 mangle PREROUTING | flat)
( start ) >/dev/null 2>&1
( start ) >/dev/null 2>&1
t_eq 'start ×3 规则数不增长' "$N1" "$(ipt_all v4 | wc -l | tr -d ' ')"
t_eq 'PREROUTING 仍恰好 QUOTA→ACCT' 'PARENTCONTROL_QUOTA PARENTCONTROL_ACCT' "$J1"
t_eq 'PREROUTING 无重复跳转' 2 "$(ipt_jump v4 mangle PREROUTING | wc -l | tr -d ' ')"

echo '== W5：陈旧锁自愈（中断留下的锁不再让 start 卡死）=='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 example.com '' 30
cfg_apply
put_std_resolve
touch -t 202001010000 "$LOCK"          # 远超过 1 分钟的陈旧锁
( start ) >"$T_TMP/w5.out" 2>&1 || true
t_eq '陈旧锁不再 exit 1（规则建好了）' ok "$(ipt_exists v4 mangle PARENTCONTROL_QUOTA && echo ok)"
t_eq '锁最终被清（不留在原地）' gone "$([ -e "$LOCK" ] && echo here || echo gone)"
t_has '日志留痕' "$(cat "$LOG_FILE" 2>/dev/null)" 'removing stale lock'
t_has '生命周期走完（crontab 已写）' "$(cat "$FAKE_CRONTAB")" 'tick'

echo '== W6：构建中途崩溃 → trap 清掉锁文件 =='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 example.com '' 30
cfg_apply
: > "$FAKE_CRONTAB"
( refresh_holiday() { exit 3; }; start ) >/dev/null 2>&1 || true   # 模拟构建中途被杀
t_eq '中途崩溃后锁文件被 trap 清掉' gone "$([ -e "$LOCK" ] && echo here || echo gone)"
t_eq '确实没跑到 cron_sync（半途而废）' '' "$(cat "$FAKE_CRONTAB")"

echo '== W7：hotplug iface 的启用判断 + 事件后真的重装 =='
HP_SRC="$REPO/root/etc/hotplug.d/iface/97-parentcontrol"
# 把脚本最后一行（/etc/init.d/parentcontrol start）替换成打桩回显，其余逻辑原样执行
sed 's|^/etc/init.d/parentcontrol start$|echo HP_STARTED|' "$HP_SRC" > "$T_TMP/hotplug.sh"
cfg_begin 1
cfg_apply
OUT=$(ACTION=ifup sh "$T_TMP/hotplug.sh" 2>"$T_TMP/hp.err")
t_eq '启用 + ifup → 调 start' 'HP_STARTED' "$OUT"
t_eq '无 "1: not found"（旧版缺陷：双层替换把输出当命令执行）' '' "$(grep -i 'not found' "$T_TMP/hp.err" || true)"
cfg_begin 0
cfg_apply
OUT=$(ACTION=ifup sh "$T_TMP/hotplug.sh" 2>&1)
t_eq '停用 → 不调 start' '' "$OUT"
cfg_begin 1
cfg_apply
OUT=$(ACTION=ifdown sh "$T_TMP/hotplug.sh" 2>&1)
t_eq '非 ifup/ifupdate 事件 → 不调 start' '' "$OUT"

echo '== W9/W10/W11：flow offloading 联动（状态化 nft 桩）=='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 example.com 192.0.2.160 30
cfg_apply
put_std_resolve
NFT_STATE="$T_TMP/nftstate"
FAKE_NFT_STATE="$NFT_STATE"; export FAKE_NFT_STATE
FAKE_IP_NEIGH="$T_TMP/neigh"; export FAKE_IP_NEIGH
printf '192.0.2.51 dev eth0 lladdr 00:00:5e:00:53:01 REACHABLE\n' > "$FAKE_IP_NEIGH"
FAKE_CONNTRACK_LOG="$T_TMP/ct.log"; export FAKE_CONNTRACK_LOG
rm -f /tmp/pc_offload_state

# S1（复审）：nft 桩语义 —— handle 单调递增、从不重用；delete 不存在的 handle 退非 0
printf '1|meta l4proto { tcp, udp } flow add @ft\n2|meta l4proto tcp flow add @ft\n3|meta l4proto udp flow add @ft\n' > "$NFT_STATE"
rm -f "$NFT_STATE.next"
nft delete rule inet fw4 forward handle 2
t_eq 'S1: 删中间一条后剩 2 条' 2 "$(grep -c '|' "$NFT_STATE")"
nft delete rule inet fw4 forward handle 2 2>/dev/null
t_eq 'S1: delete 不存在的 handle 退非 0' 1 "$?"
nft insert rule inet fw4 forward meta l4proto { tcp, udp } flow add @ft
t_eq 'S1: 新 handle=4（不重用已删的 2、不撞残留的 3）' 4 "$(head -1 "$NFT_STATE" | cut -d'|' -f1)"

printf '1|meta l4proto { tcp, udp } flow add @ft\n' > "$NFT_STATE"
rm -f "$NFT_STATE.next"
run_build
t_hasnt 'W9: fw4 的 flow add 规则被删除' "$(cat "$NFT_STATE")" 'flow add @ft'
t_eq 'W9: offload 状态文件=disabled' 'disabled' "$(cat /tmp/pc_offload_state 2>/dev/null)"
restore_offload
t_has 'W10: 停用恢复路径把 flow add 规则装回' "$(cat "$NFT_STATE")" 'flow add @ft'
t_eq 'W10: offload 状态文件=on' 'on' "$(cat /tmp/pc_offload_state 2>/dev/null)"
: > "$FAKE_CONNTRACK_LOG"
run_build
CT=$(cat "$FAKE_CONNTRACK_LOG")
t_has 'W11: 对 neigh 解析出的受管设备 IP 执行 conntrack -D' "$CT" '-D -s 192.0.2.51'
t_has 'W11: 对条目静态 IP 执行 conntrack -D' "$CT" '-D -s 192.0.2.160'
# conntrack 不可用（桩退非 0，可观测行为与缺失一致）→ 跳过且不报错、不影响构建（复审 N2）
FAKE_NO_CONNTRACK=1; export FAKE_NO_CONNTRACK
LOG_FILE="$T_TMP/w11.log"; export LOG_FILE
run_build
t_eq 'W11: conntrack 不可用 → 构建不受影响（计数规则在）' ok "$(ipt_rules v4 mangle PARENTCONTROL_ACCT | grep -q PCA_weburl_0 && echo ok)"
t_eq 'W11: conntrack 不可用 → 不 purge 也不报 ERROR' '' "$(grep -E 'purged|ERROR' "$LOG_FILE" 2>/dev/null || true)"
FAKE_NO_CONNTRACK=; export FAKE_NO_CONNTRACK
LOG_FILE="$T_TMP/log"; export LOG_FILE
unset FAKE_NFT_STATE FAKE_IP_NEIGH FAKE_CONNTRACK_LOG
rm -f /tmp/pc_offload_state

echo '== W13：CIDR 直通（含 / 的项直接封、不进解析器）=='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 '1.2.3.4/32,example.com' '' 30
cfg_apply
put_resolve <<'EOF'
4 example.com 1.2.3.4
4 www.example.com 1.2.3.4
EOF
FAKE_RESOLVE_LOG="$T_TMP/rlog"; export FAKE_RESOLVE_LOG
: > "$FAKE_RESOLVE_LOG"
refresh_ips
F=$(cat "$IPDIR/weburl_0")
t_has 'CIDR 原样入表（不套 /24 掩码）' "$F" '1.2.3.4/32'
t_eq 'CIDR 不进解析器' 0 "$(grep -c '1\.2\.3\.4/32' "$FAKE_RESOLVE_LOG")"
t_eq '域名才走解析（有查询记录）' 1 "$([ -s "$FAKE_RESOLVE_LOG" ] && echo 1 || echo 0)"
unset FAKE_RESOLVE_LOG
run_build
t_has 'CIDR 目标直接进计数规则' "$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)" '-d 1.2.3.4/32 -j PCA_weburl_0'

echo '== W14：IP 粒度 ip_mask=32 → 精确 /32 =='
fresh
cfg_begin 1 '' 32
put_weburl 00:00:5e:00:53:01 example.com '' 30
cfg_apply
put_std_resolve
run_build
A=$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)
t_has 'ip_mask=32 → 入表为精确 IP（kernel 语义 = /32）' "$(cat "$IPDIR/weburl_0")" '1.2.3.4'
t_has 'ip_mask=32 → 规则用精确主机地址' "$A" '-d 1.2.3.4 -j PCA_weburl_0'
t_eq 'ip_mask=32 → 不再出现 /24' 0 "$(printf '%s' "$A" | grep -c '1\.2\.3\.0/24')"
t_has 'IPv6 不受影响仍 /64' "$(ipt_rules v6 mangle PARENTCONTROL_ACCT | flat)" '-d 2402:4e00:1410:0::/64 -j PCA_weburl_0'

echo '== W16：cron 条目由插件自己维护（不覆盖他人条目）=='
fresh
cfg_begin 1
cfg_apply
printf '*/5 * * * * /usr/bin/somejob # other-job\n' > "$FAKE_CRONTAB"
cron_sync 1
CR=$(cat "$FAKE_CRONTAB")
t_has '他人条目原样保留' "$CR" '/usr/bin/somejob'
t_eq '插件的 tick/refresh 条目恰好两条' 2 "$(grep -c parentcontrol "$FAKE_CRONTAB")"

echo '== W17：名称解析 —— apex+www 变体、关键词猜测 =='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 example.com '' 30
cfg_apply
FAKE_RESOLVE_LOG="$T_TMP/rlog2"; export FAKE_RESOLVE_LOG
: > "$FAKE_RESOLVE_LOG"
put_resolve <<'EOF'
4 example.com 1.2.3.4
4 www.example.com 1.2.3.4
EOF
refresh_ips
t_eq 'apex 与 www. 变体都被查询' 1 "$([ "$(grep -c 'example\.com' "$FAKE_RESOLVE_LOG")" -ge 2 ] && echo 1 || echo 0)"
# 只填关键词（没有点）→ 试 xhs.com / www.xhs.com / xhs.cn
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 xhs '' 30
cfg_apply
: > "$FAKE_RESOLVE_LOG"
put_resolve <<'EOF'
4 xhs.com 5.6.7.8
4 www.xhs.com 5.6.8.9
6 xhs.cn 2402:4e00:1410::99
EOF
refresh_ips
RL=$(cat "$FAKE_RESOLVE_LOG")
# resolve_host 对每个 host 各查一次 v4/v6 → 每个名字恰好两条查询记录
t_eq '尝试 xhs.com（关键词+.com）' 2 "$(printf '%s\n' "$RL" | grep -cx 'xhs\.com')"
t_eq '尝试 www.xhs.com' 2 "$(printf '%s\n' "$RL" | grep -cx 'www\.xhs\.com')"
t_eq '尝试 xhs.cn' 2 "$(printf '%s\n' "$RL" | grep -cx 'xhs\.cn')"
F=$(cat "$IPDIR/weburl_0")
t_has 'xhs.com 的 IPv4 入表' "$F" '5.6.7.0/24'
t_has 'www.xhs.com 的 IPv4 入表（独立 /24）' "$F" '5.6.8.0/24'
t_has 'xhs.cn 的 IPv6 入表' "$F" '2402:4e00:1410:0::/64'
unset FAKE_RESOLVE_LOG

echo '== W32：MAC+静态IP 双身份 —— 封锁各出一条、计数只出一条（ip 优先）=='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 example.com 192.0.2.160 30
cfg_apply
put_std_resolve
run_build
A=$(ipt_rules v4 mangle PARENTCONTROL_ACCT)
t_has '计数：单条用 -s <ip>' "$(printf '%s\n' "$A" | flat)" '-s 192.0.2.160 -d 1.2.3.0/24 -j PCA_weburl_0'
t_eq '计数：不双计（该目标恰一条）' 1 "$(printf '%s\n' "$A" | grep -c -- '-d 1.2.3.0/24 -j PCA_weburl_0')"
t_eq '计数：不出现 mac 条件' 0 "$(printf '%s\n' "$A" | grep -c -- '--mac-source')"
pc_usage_add weburl_0 30
build_quota_blocks
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA)
t_has '封锁：MAC 命中一条' "$(printf '%s\n' "$Q" | flat)" '-m mac --mac-source 00:00:5e:00:53:01 -d 1.2.3.0/24 -j DROP'
t_has '封锁：静态 IP 命中一条' "$(printf '%s\n' "$Q" | flat)" '-s 192.0.2.160 -d 1.2.3.0/24 -j DROP'
t_eq '封锁：该目标恰两条（任一命中即生效）' 2 "$(printf '%s\n' "$Q" | grep -c -- '-d 1.2.3.0/24 -j DROP')"

echo '== F1：封锁链规则集没变时不再「-F 后重建」（消灭每分钟的封锁空窗）=='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 example.com 192.0.2.160 30
cfg_apply
put_std_resolve
run_build
pc_usage_add weburl_0 30
build_quota_blocks
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA)
t_eq 'F1：额度耗尽 → 封锁规则已下发（mac+ip 各一条）' 2 "$(printf '%s\n' "$Q" | grep -c -- '-d 1.2.3.0/24 -j DROP')"
ipt_setcounters v4 mangle PARENTCONTROL_QUOTA '*' 4242
build_quota_blocks
t_has 'F1：规则集没变 → 一个 iptables 都没动（计数器 4242 原样保留）' \
	"$(iptables-legacy -t mangle -L PARENTCONTROL_QUOTA)" '4242'
iptables-legacy -t mangle -F PARENTCONTROL_QUOTA
t_eq 'F1：外部清空后链确实是空的' 0 "$(printf '%s\n' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA)" | grep -c '^-A')"
build_quota_blocks
t_eq 'F1：链被外部清空 → 条数校验触发自愈重建' 2 "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | grep -c -- '-d 1.2.3.0/24 -j DROP')"

echo '== F2：填了静态 IP 的条目，IPv6 计数回退到 MAC（不再整段漏计）=='
fresh
cfg_begin 1
put_weburl 00:00:5e:00:53:01 example.com 192.0.2.160 0
cfg_apply
put_std_resolve
run_build
A4=$(ipt_rules v4 mangle PARENTCONTROL_ACCT)
A6=$(ipt_rules v6 mangle PARENTCONTROL_ACCT)
t_has 'F2：v4 计数用 -s <静态IP>' "$(printf '%s\n' "$A4" | flat)" '-s 192.0.2.160 -d 1.2.3.0/24 -j PCA_weburl_0'
t_eq 'F2：v4 不出现 mac 条件（ip 优先）' 0 "$(printf '%s\n' "$A4" | grep -c -- '--mac-source')"
t_has 'F2：v6 计数回退到 MAC' "$(printf '%s\n' "$A6" | flat)" '-m mac --mac-source 00:00:5e:00:53:01 -d 2402:4e00:1410:0::/64 -j PCA_weburl_0'
t_eq 'F2：v6 不得塞 IPv4 源地址（非法语句，真机会被静默丢弃）' 0 "$(printf '%s\n' "$A6" | grep -c -- '192.0.2.160')"

echo '== F2′：只填 IPv4 的条目 —— v6 链一条都不装（也不得退化成无条件规则）=='
fresh
cfg_begin 1
put_weburl '' example.com 192.0.2.160 0
cfg_apply
put_std_resolve
run_build
A6=$(ipt_rules v6 mangle PARENTCONTROL_ACCT)
Q6=$(ipt_rules v6 mangle PARENTCONTROL_QUOTA)
t_eq 'F2′：v6 计数链该目标 0 条' 0 "$(printf '%s\n' "$A6" | grep -c 'PCA_weburl_0')"
t_eq 'F2′：v6 封锁链该目标 0 条（不得出现无条件的 DROP）' 0 "$(printf '%s\n' "$Q6" | grep -c 'DROP')"

t_summary
