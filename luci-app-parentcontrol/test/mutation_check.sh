#!/bin/sh
# 变异测试：故意改坏源码，断言测试套件真的会失败（证明用例不是摆设）。
# 全程在仓库副本里做，绝不动工作区。
# 运行： sh test/mutation_check.sh
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/repo"
(cd "$REPO" && tar --exclude=.git -cf - .) | (cd "$WORK/repo" && tar -xf -)

# mutate <file> <old> <new>  —— 锚点找不到就退出 2
mutate() {
	python3 - "$WORK/repo/$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if old not in src:
    sys.exit(2)
open(path, "w").write(src.replace(old, new, 1))
PY
}

KILLED=0
SURVIVED=0
SKIPPED=0

run_mut() { # <名字> <文件> <老> <新> <套件>
	name=$1; file=$2; old=$3; new=$4; suite=$5
	# MUT_ONLY=<子串>：只跑名字含该子串的变异（分块验证用；不设 = 全量，行为不变）
	case "${MUT_ONLY:-}" in
	'') ;;
	*) case "$name" in *"$MUT_ONLY"*) ;; *) return 0 ;; esac ;;
	esac
	if ! mutate "$file" "$old" "$new"; then
		printf '  FAIL  %s（锚点未命中：这条防线已失效，必须修锚点）\n' "$name"
		SKIPPED=$((SKIPPED + 1))
		return
	fi
	if (cd "$WORK/repo" && sh "test/$suite") >"$WORK/out" 2>&1; then
		printf '  SURVIVED  %s —— 改坏后 %s 仍全过，用例没覆盖到\n' "$name" "$suite"
		SURVIVED=$((SURVIVED + 1))
	else
		printf '  killed    %s（%s 失败）\n' "$name" "$suite"
		KILLED=$((KILLED + 1))
	fi
	# 还原
	(cd "$REPO" && tar --exclude=.git -cf - "$file") | (cd "$WORK/repo" && tar -xf -)
}

INIT=root/etc/init.d/parentcontrol
COMMON=root/usr/lib/parentcontrol/common.sh

echo '== 变异测试（期望：每个都被杀死）=='

# 1) 网址 SNI 端口写错
run_mut 'SNI 端口 80,443→80,8443' "$INIT" \
	'--dports 80,443' '--dports 80,8443' init_test.sh

# 2) 网址 TCP/SNI 那条规则整条不装（就是本次修掉的真 bug 的形态）
run_mut 'SNI 规则整条删除' "$INIT" \
	'			emit_dev_rule "$_c" "$1" "$3" weburl "$6" "$4 -p TCP -m multiport --dports 80,443 -m string --algo $_algos --string $_pat" "$5" "$_dev"' ':' init_test.sh

# 3) PREROUTING 挂载顺序被改（TAGQ 不再最先 → 被封的包会先进计数链）
run_mut 'PREROUTING 顺序被改' "$INIT" \
	'		hook_chain "$_ip" mangle PREROUTING "$TAGA"
		hook_chain "$_ip" mangle PREROUTING "$TAGQ"
	done
	build_acct_rules' \
	'		hook_chain "$_ip" mangle PREROUTING "$TAGQ"
		hook_chain "$_ip" mangle PREROUTING "$TAGA"
	done
	build_acct_rules' init_test.sh

# 4) refresh_holiday 永远不联网（novet 短路被提前）
run_mut 'refresh_holiday 永不联网' "$INIT" \
	'	[ "$1" = "novet" ] && return 0' '	return 0' init_test.sh

# 5) 采样阈值失效（任何增量都记 1 分钟）
run_mut '采样阈值失效（任何非零增量都记 1 分钟）' "$INIT" \
	'		[ "$_d" -gt 0 ] && [ "$_d" -ge "$_thr" ] && pc_usage_add "$_key" 1' \
	'		[ "$_d" -gt 0 ] && pc_usage_add "$_key" 1' init_test.sh

# 6) 池额度被忽略（一律按私有额度）
run_mut '共享池口径失效（池额度永远读不到）' "$COMMON" \
	'	_p=$(pc_entry_pool "$1" "$2" "$3")
	[ -n "$_p" ] && pc_pool_quota "$_p" "$3"' \
	'	:' init_test.sh

# 7) 重建时不再 ensure/hook（fw4 reload 后自愈能力丢失）
run_mut '重建自愈能力丢失' "$INIT" \
	'		ensure_chain "$_ip" mangle "$TAGA"
		ensure_chain "$_ip" mangle "$TAGQ"
		hook_chain "$_ip" mangle PREROUTING "$TAGA"
' '' init_test.sh

# 8) 可用时段被忽略（永远当作"不限制时段"）
run_mut '可用时段被忽略' "$COMMON" \
	'	[ "$_ss" -lt "$_ee" ] 2>/dev/null || return 0' '	return 0' common_test.sh

# 9) 节假日解析把 isOffDay 判反
run_mut 'isOffDay 判反' "$COMMON" \
	'		true)  echo 1; return 0 ;;' '		true)  echo 0; return 0 ;;' common_test.sh

# 10) 迁移：不再写可用时段（week=1-5 的老条目本应拿到 09:00-21:00）
run_mut '迁移不写可用时段' "$COMMON" \
	'					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_qstart=$_ws"' \
	'					:' migrate_test.sh

# 11) pc_active_keys 输出的 key 必须是唯一的一份（重复会让封锁链下发两遍）
run_mut '额度遍历输出重复 key' "$COMMON" \
	'			echo "${_m}_${_i}"' \
	'			echo "${_m}_${_i}"; echo "${_m}_${_i}"' init_test.sh

# 12b) 额度计数不再计入字符串（DNS/SNI）命中
run_mut '计数不计 DNS 字符串命中' "$INIT" \
	'			emit_dev_rule "$_c" "$1" "$3" weburl "$6" "$4 -p UDP --dport 53 -m string --algo $_algos --string $_pat" "$5" "$_dev"' ':' init_test.sh

# 12c) 计数/封锁装到错误的表（filter 而非 mangle）
run_mut '计数装错表(filter)' "$INIT" \
	'emit_entry_targets "$_m" "$_i" mangle "$TAGA" "$TAGA" "" "-j PCA_$_key" single' \
	'emit_entry_targets "$_m" "$_i" filter "$TAGA" "$TAGA" "" "-j PCA_$_key" single' init_test.sh

# 12d) 首次采样又变回「只写基线」（丢开机后那段用量）
run_mut '首次采样不计数（丢掉开机后那段用量）' "$INIT" \
	'			_d=$_v
		fi' '			_d=0
		fi' init_test.sh

# 12) 拆除时不清理 mangle 链
run_mut '拆除残留 mangle 链' "$INIT" \
	'		for _ta in "$TAGQ" "$TAGA"; do
			$_ip -t mangle -D PREROUTING -j "$_ta" 2>/dev/null
			$_ip -t mangle -F "$_ta" 2>/dev/null
			$_ip -t mangle -X "$_ta" 2>/dev/null
		done' '' init_test.sh

# ============================================================================
# pc-acceptance 新增白盒用例（W3..W43）的可鉴别性变异 —— 改坏源码后对应用例必须 FAIL
# ============================================================================

# W2（加固）: bash 式 `local a,b=0` 回归（busybox ash 会炸、主机测不出来）→ lint_ash 必须拦
run_mut 'W2: local a,b=0 回归（lint_ash 拦截）' "$COMMON" \
	'pc_uget() { uci -q get "$PC_CONF.$1"; }' \
	'pc_uget() { uci -q get "$PC_CONF.$1"; }
local a,b=0' run.sh

# W3: 组合配置下 start 崩在 time 之后 → protocol/weburl 规则不装（旧版缺陷形态）
run_mut 'W3: start 崩在 time 之后' "$INIT" \
	'	time)
		emit_dev_rule "$ipt"  "$3" "$4" time "$2" "$6" "$7" "$8"' \
	'	time)
		[ "$1" = time ] && exit 9
		emit_dev_rule "$ipt"  "$3" "$4" time "$2" "$6" "$7" "$8"' acceptance_test.sh

# W4: del_rule 的老 mangle WEBURL/IP 清理用错表
run_mut 'W4: 老 WEBURL/IP 链清理用错表' "$INIT" \
	'		for _ta in PARENTCONTROL_WEBURL PARENTCONTROL_IP; do
			$_ip -t mangle -D PREROUTING -j "$_ta" 2>/dev/null
			$_ip -t mangle -F "$_ta" 2>/dev/null
			$_ip -t mangle -X "$_ta" 2>/dev/null
		done' \
	'		for _ta in PARENTCONTROL_WEBURL PARENTCONTROL_IP; do
			$_ip -t filter -D PREROUTING -j "$_ta" 2>/dev/null
			$_ip -t filter -F "$_ta" 2>/dev/null
			$_ip -t filter -X "$_ta" 2>/dev/null
		done' acceptance_test.sh

# W5: 陈旧锁不再自愈（旧版缺陷形态：见锁就退出）
run_mut 'W5: 陈旧锁不自愈' "$INIT" \
	'	[ -f "$LOCK" ] && {
		[ -n "$(find "$LOCK" -mmin +1 2>/dev/null)" ] || exit 1
		elog "removing stale lock $LOCK"
	}' \
	'	[ -f "$LOCK" ] && exit 1' acceptance_test.sh

# W6: 中途失败不清锁（trap 失效）
Q="'"
run_mut 'W6: trap 清锁失效' "$INIT" \
	"	trap ${Q}rm -f \"\$LOCK\"${Q} EXIT INT TERM" \
	'	:' acceptance_test.sh

# W7: hotplug 启用判断回退成旧版缺陷形态（双层替换：输出被当命令执行 → "1: not found"）
run_mut 'W7: hotplug 判断回到旧版 bug' "root/etc/hotplug.d/iface/97-parentcontrol" \
	'[ "$(uci -q get $CONFIG.@basic[0].enabled)" = "1" ] || exit 0' \
	'[ "$(`uci -q get $CONFIG.@basic[0].enabled`)" == 1 ] || exit 0' acceptance_test.sh

# W9: apply_offload 不删 fw4 的 flow add 规则（3 缩进的删除行 = apply_offload 里的那处）
run_mut 'W9: offload 删除被禁' "$INIT" \
	'			[ -n "$h" ] && nft delete rule inet fw4 forward handle $h 2>/dev/null' \
	'			:' acceptance_test.sh

# W10: 停用后 flow add 规则装不回
run_mut 'W10: offload 恢复装不回' "$INIT" \
	'	nft insert rule inet fw4 forward meta l4proto { tcp, udp } flow add @ft 2>/dev/null' \
	'	:' acceptance_test.sh

# W11: 受管设备的 conntrack 清理被跳过
run_mut 'W11: conntrack 清理被禁' "$INIT" \
	'			for a in $(weburl_ips_all); do
				conntrack -D -s "$a" >/dev/null 2>&1 && n=$((n + 1))
			done' \
	'			for a in $(weburl_ips_all); do
				:
			done' acceptance_test.sh

# W13: CIDR 直通被改成走解析器
run_mut 'W13: CIDR 不再直通' "$INIT" \
	'		*/*) echo "$_h" ;;   # 直接写 CIDR：不解析，原样使用' \
	'		*/*) resolve_host "$_h" ;;' acceptance_test.sh

# W14: ip_mask=32 分支失效（永远套 /24）
run_mut 'W14: ip_mask=32 分支失效' "$INIT" \
	'if [ "$PC_IPMASK" = "32" ]; then echo "$_a"; else' \
	'if [ "$PC_IPMASK" = "32x" ]; then echo "$_a"; else' acceptance_test.sh

# W16: cron_sync 不再剔除自己的旧条目（重复堆叠 + 他人条目处理失控）
run_mut 'W16: cron 不剔旧条目' "$INIT" \
	'	new=$(crontab -l 2>/dev/null | grep -v "$CRON_TAG" | grep -v "$CRON_TAG_IP")' \
	'	new=$(crontab -l 2>/dev/null)' init_test.sh

# W17: 关键词猜测被砍
run_mut 'W17: 关键词猜测被砍' "$INIT" \
	'for _hh in "$_h" "$_h.com" "www.$_h.com" "$_h.cn"; do resolve_host "$_hh"; done' \
	'for _hh in "$_h"; do resolve_host "$_hh"; done' acceptance_test.sh

# W32: 计数侧 ip 优先被破坏（改用 mac → 静态 IP 失效/口径漂移）
run_mut 'W32: 计数身份 ip 优先被破坏' "$INIT" \
	'	if [ -n "$_ip" ] && addr_is_family "$_ip" "$_fam6"; then echo "-s $_ip"
	elif [ -n "$_mac" ]; then echo "-m mac --mac-source $_mac"' \
	'	if [ -n "$_mac" ]; then echo "-m mac --mac-source $_mac"
	elif [ -n "$_ip" ] && addr_is_family "$_ip" "$_fam6"; then echo "-s $_ip"' acceptance_test.sh

# F1: 把「规则集没变就不动链」的短路去掉 → 每分钟照旧 -F 后重建（封锁空窗回来了）
run_mut 'F1: 封锁链每次都全量重建（空窗回归）' "$INIT" \
	'	if [ "$_spec" = "$_old" ] && [ "$_ccnt" = "$_lcnt" ]; then
		return 0
	fi' \
	'	if false; then
		return 0
	fi' acceptance_test.sh

# F1: 只比规则文本、不校验链内条数 → 链被外部清空后不会自愈
run_mut 'F1: 不校验链内条数（外部清空后不自愈）' "$INIT" \
	'[ "$_ccnt" = "$_lcnt" ]' '[ -n "$_ccnt" ]' acceptance_test.sh

# F2: 去掉协议族过滤 → 把 IPv4 地址照样塞进 ip6tables（静默失败，v6 额度漏计）
run_mut 'F2: 静态 IP 不按协议族过滤' "$INIT" \
	'	if [ -n "$_ip" ] && addr_is_family "$_ip" "$_fam6"; then echo "-s $_ip"' \
	'	if [ -n "$_ip" ]; then echo "-s $_ip"' acceptance_test.sh

# F2: 无设备条件的退化判定去掉 mac/ip 判空 → 族不匹配时错发无条件规则（全屋误封）
run_mut 'F2: 族不匹配时错发无条件规则' "$INIT" \
	'	if [ "$_n" = 0 ] && [ -z "$_mac" ] && [ -z "$_ip" ]; then' \
	'	if [ "$_n" = 0 ]; then' acceptance_test.sh

# W37: 档案摘要不再去秒
run_mut 'W37: 档案摘要不去秒' "luasrc/model/cbi/parentcontrol/ui.lua" \
	'st = st .. "(" .. ws:sub(1, 5) .. "-" .. we:sub(1, 5) .. ")"' \
	'st = st .. "(" .. ws .. "-" .. we .. ")"' ui_static_test.sh

# W38a: 「起=止」重新放行（>= 退化为 >）
run_mut 'W38a: 起=止重新放行' "luasrc/model/cbi/parentcontrol/parts.lua" \
	'if is_start and a >= b then' 'if is_start and a > b then' ui_static_test.sh

# W38b: 回到「自己和自己比」的链式 gsub（真机踩过的原 bug 形态）
run_mut 'W38b: 自己和自己比回归' "luasrc/model/cbi/parentcontrol/parts.lua" \
	'	local other = submitted(self, is_start
		and self.option:gsub("_qstart$", "_qend")
		or  self.option:gsub("_qend$",  "_qstart"))' \
	'	local other = submitted(self, self.option:gsub("_qstart$", "_qend"):gsub("_qend$", "_qstart"))' ui_static_test.sh

# W39: 寒暑假 TypedSection 改名（区块丢失）
run_mut 'W39: vacation 区块丢失' "luasrc/model/cbi/parentcontrol/quota.lua" \
	't = a:section(TypedSection, "vacation", translate("寒暑假区间"))' \
	't = a:section(TypedSection, "vac", translate("寒暑假区间"))' ui_static_test.sh

# W42: UI 又加回 time 入口
run_mut 'W42: time 入口加回' "luasrc/controller/parentcontrol.lua" \
	'	entry({"admin", "control", "parentcontrol","stats"}, cbi("parentcontrol/stats"), _("使用统计"), 45).leaf = true' \
	'	entry({"admin", "control", "parentcontrol","stats"}, cbi("parentcontrol/stats"), _("使用统计"), 45).leaf = true
	entry({"admin", "control", "parentcontrol","time"}, cbi("parentcontrol/time"), _("时间限制"), 30).leaf = true' ui_static_test.sh

# W43a: 迁移备份不再生成
run_mut 'W43a: 迁移备份丢失' "$COMMON" \
	'		cp -a "$PC_CONF_DIR/$PC_CONF" "$BACKUP_DIR/$PC_CONF.$(date +%Y%m%d%H%M%S).bak" 2>/dev/null' \
	'		:' migrate_test.sh

# W43b: 「已是新模型不动」守卫失效 → 凭空造档案
run_mut 'W43b: 新模型条目被重写' "$COMMON" \
	'					if [ "$_had_dual" = 0 ]; then' \
	'					if :; then' migrate_test.sh

# N1（复审）: del_rule 的 filter -F/-X 循环去掉 PARENTCONTROL_WEBURL
# （= 阶段4 生产修复 init.d del_rule 的回退；acceptance W4 的「filter 表无 PARENTCONTROL 链」必须红）
run_mut 'N1: filter WEBURL 清理行回退' "$INIT" \
	'		for _ta in PARENTCONTROL_TIME PARENTCONTROL_PROTOCOL PARENTCONTROL_WEBURL; do
			$_ip -F "$_ta" 2>/dev/null
			$_ip -X "$_ta" 2>/dev/null
		done' \
	'		for _ta in PARENTCONTROL_TIME PARENTCONTROL_PROTOCOL; do
			$_ip -F "$_ta" 2>/dev/null
			$_ip -X "$_ta" 2>/dev/null
		done' acceptance_test.sh

# S1（复审）: fake nft handle 退回「现存行数+1」分配 → 删中间一条后会重用 handle
#（acceptance 的 S1 断言「新 handle=4 不与残留冲突」必须红）
run_mut 'S1: nft 桩 handle 重用回归' "test/fakes/nft" \
	"	if [ -f \"\$ST.next\" ]; then
		h=\$(cat \"\$ST.next\")
	else
		h=1
		[ -f \"\$ST\" ] && h=\$(awk -F${Q}|${Q} '{if (\$1 + 0 > m) m = \$1 + 0} END {print m + 1}' \"\$ST\")
	fi" \
	'	h=$(( $(wc -l < "$ST" 2>/dev/null || echo 0) + 1 ))' acceptance_test.sh

# B16（真机 500）回归: submitted() 又把 AbstractSection 对象直接喂给 format
#（原缺陷形态：self.section 是对象，Lua 5.1 的 %s 不做 tostring → 编辑页保存 500）
run_mut 'B16: submitted 直接 format section 对象' "luasrc/model/cbi/parentcontrol/parts.lua" \
	'	local name = type(self.section) == "table" and self.section.section or self.section
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return http.formvalue(("cbid.%s.%s.%s"):format(self.map.config, name, key))' \
	'	return http.formvalue(("cbid.%s.%s.%s"):format(self.map.config, self.section, key))' ui_static_test.sh

# F5: 命名节被整条跳过（回到修复前的缺陷形态：家长以为在管控，实际完全放行）
run_mut 'F5: 命名节被跳过' "$COMMON" \
	'					typ = v
					idx = cnt[typ] + 0' \
	'					typ = ""
					idx = 0' common_test.sh

# F5: 命名节下标不递增（混合顺序下与匿名节撞号，链名会指错条目）
run_mut 'F5: 命名节下标不递增' "$COMMON" \
	'					idx = cnt[typ] + 0' \
	'					idx = 0' init_test.sh

# F5: pc_ids_on 不看 enable 值（enable='0' 的条目也会被封锁）
run_mut 'F5: enable=0 也被当成启用' "$COMMON" \
	'$3 == "enable" && $4 == "1"' '$3 == "enable"' common_test.sh

# F5: pc_opts_all 不按字段名过滤（mac 收集会混进 ip）
run_mut 'F5: pc_opts_all 字段不过滤' "$COMMON" \
	'$1 == t && $3 == o && $4 != ""' '$1 == t && $4 != ""' common_test.sh

# M-F3-01（F3/ADR-3）: pc_lan_nets6 去掉行首格式白名单（直接放行第 1 字段）
# → default/throw/blackhole 被当成网段（W-F3-02 必须红）
run_mut 'M-F3-01: v6 行首白名单被去掉' "$COMMON" \
	'		| grep -E '"${Q}"'^([0-9A-Fa-f]*:)+[0-9A-Fa-f:]*/[0-9]+$'"${Q}"' \' \
	'		| grep -E '"${Q}"'.'"${Q}"' \' common_test.sh

# M-F3-02（F3）: 退回族过滤、v6 又改用 v4 网段列表（= 原 F3 缺陷形态，v6 守卫恒 0 条）
run_mut 'M-F3-02: 退回族过滤（v6 守卫恒 0）' "$INIT" \
	'	if [ "$1" = "$ipt6" ]; then
		# v6：家里 on-link 前缀只能问内核路由表（GUA/ULA 都不在 UCI 里，F3 ADR-2）
		_nets=$(pc_lan_nets6)
	else
		# v4：语义冻结（F3 ADR-5），仍走 uci 静态节，一字不改
		# 但保留改动前的族语义：跳过含 ":" 的值（等价于原 addr_is_family "$_n" 0）——
		# 静态节里含冒号的 ipaddr 透传进 iptables 是非法规则，且渲染指纹会与实际
		# 规则永久不一致 → 每分钟无谓全量重建（F3 阶段 5 SF-2）。
		_nets=$(pc_lan_nets | grep -v '\'':'\'')
	fi
	for _n in $_nets; do' \
	'	for _n in $(pc_lan_nets); do
		addr_is_family "$_n" "1" || continue' init_test.sh

# M-F3-03（F3）: 不按族选数据源（两族都用 pc_lan_nets）→ v6 链出现 IPv4 网段守卫
run_mut 'M-F3-03: 不按族选数据源' "$INIT" \
	'	if [ "$1" = "$ipt6" ]; then
		# v6：家里 on-link 前缀只能问内核路由表（GUA/ULA 都不在 UCI 里，F3 ADR-2）
		_nets=$(pc_lan_nets6)
	else
		# v4：语义冻结（F3 ADR-5），仍走 uci 静态节，一字不改
		# 但保留改动前的族语义：跳过含 ":" 的值（等价于原 addr_is_family "$_n" 0）——
		# 静态节里含冒号的 ipaddr 透传进 iptables 是非法规则，且渲染指纹会与实际
		# 规则永久不一致 → 每分钟无谓全量重建（F3 阶段 5 SF-2）。
		_nets=$(pc_lan_nets | grep -v '\'':'\'')
	fi' \
	'	_nets=$(pc_lan_nets)' init_test.sh

# M-F3-04（F3 阶段 5 SF-1）: 去掉零长前缀排除 → ::/0 进链 = "-d ::/0 -j RETURN"
# = 放行一切（W-F3-13 必须红）
run_mut 'M-F3-04: 零长前缀排除被去掉' "$COMMON" \
	'			case "$_pfx" in */0) continue ;; esac' \
	'			:' common_test.sh

printf '\n被杀 %d / 存活 %d / 锚点失效 %d\n' "$KILLED" "$SURVIVED" "$SKIPPED"
[ "$SURVIVED" -eq 0 ] && [ "$SKIPPED" -eq 0 ] || exit 1
