#!/bin/sh

# DNS 劫持的契约测试。
#
# 背景：fw4 对「没有 family」的 redirect 按 **IPv4** 兜底，所以只写 `=redirect` 的
# 段只劫持 IPv4 —— 0.1.5-r5 及更早就是这个 bug：开关开着、IPv4 的 :53 被重定向了，
# IPv6 的 :53 原样放行。详见后端里 hijack_family_covers_ipv6 上方的注释。
#
# 这里驱动的是**真实的 rpcd 后端**（root/usr/libexec/rpcd/luci.oxidns）与**真实
# Makefile 里抽出来的 postinst**，uci / jsonfilter / firewall init 全部打桩，
# 所以离线可跑、不碰真实系统。
#
#   sh scripts/hijack-check.sh              # 断言
#   sh scripts/hijack-check.sh --inject     # 附缺陷注入，确认断言真的能红
#
# 不并进 integration-check.sh：那个脚本在 Windows/MSYS 下会被沙箱的删除守卫整条
# 打死（本地跑不了），而这条要能本地跑。

set -eu

INJECT=0
if [ "${1:-}" = "--inject" ]; then
	INJECT=1
fi
# 只跑某一条注入（配额紧时用）: sh scripts/hijack-check.sh --inject <key>
INJECT_ONLY="${2:-}"
inject_want() { [ -z "$INJECT_ONLY" ] || [ "$INJECT_ONLY" = "$1" ]; }

BACKEND_DEFAULT="root/usr/libexec/rpcd/luci.oxidns"
MAKEFILE="Makefile"
BACKEND="$BACKEND_DEFAULT"
POSTINST_CMD=""

# 临时树。刻意**不用**继承来的 TMPDIR：Windows/MSYS 下它常常是 `C:\...` 形式，
# 那种路径拼进 PATH 后桩找不着，退出时 rm 还会被安全删除守卫拦下（embedded drive
# prefix）。这里固定用 POSIX 的 /tmp，并 cd+pwd 规范化一遍。
: "${OXIDNS_HIJACK_TMPDIR:=/tmp}"
WORK="$(mktemp -d "$OXIDNS_HIJACK_TMPDIR/oxidns-hijack-check.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
# 沙箱里批量删除有配额（摸到阈值会把整条进程链打死），调试时可用
# OXIDNS_HIJACK_KEEP=1 留住临时树，自己清。
if [ -n "${OXIDNS_HIJACK_KEEP:-}" ]; then
	trap 'printf "\n临时树保留在 %s\n" "$WORK"' EXIT HUP INT TERM
else
	trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fi

FAILED=0
ok() { printf '  ok   %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  FAIL %s%s\n' "$1" "${2:+  <- $2}"; }
expect() { # expect <label> <actual> <expected>
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi
}
has() { # has <label> <haystack> <needle>
	case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "缺少 [$3]（实际 [$2]）" ;; esac
}

# 分段开关：sandbox 有累计资源配额，一次跑不完全部时用
# OXIDNS_HIJACK_ONLY=sections|legacy|migration|source 单独跑一段。
ONLY="${OXIDNS_HIJACK_ONLY:-all}"
want() { [ "$ONLY" = "all" ] || [ "$ONLY" = "$1" ]; }

# --------------------------------------------------------------------------- #
# 桩
# --------------------------------------------------------------------------- #

BIN="$WORK/bin"
mkdir -p "$BIN"

# 极简 uci：平铺 "key=value"。get 的匹配一律走 awk 的 index()（字面量），
# 因为 key 里全是点、用 grep 会当正则。
cat > "$BIN/uci" <<'UCI'
#!/bin/sh
STORE="${UCI_STUB_STORE:?}"
if [ "${1:-}" = "-q" ]; then shift; fi
CMD="$1"
shift
	case "$CMD" in
	get)
		# 命中就打印值、rc=0；没命中 rc=1 —— 后端的 hijack_managed_sections 靠
		# 这个 rc 判断段存在与否。⚠️ 不能让下面的 exit 0 把它盖掉。
		awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); f = 1; exit }
		                 END { if (!f) exit 1 }' "$STORE" || exit 1
		;;
	set)
		KEY="${1%%=*}"
		VAL="${1#*=}"
		awk -v k="$KEY=" 'index($0, k) != 1' "$STORE" > "$STORE.tmp"
		mv "$STORE.tmp" "$STORE"
		printf '%s=%s\n' "$KEY" "$VAL" >> "$STORE"
		;;
	delete)
		awk -v k="$1=" 'index($0, k) != 1' "$STORE" > "$STORE.tmp"
		mv "$STORE.tmp" "$STORE"
		;;
	commit)
		;;
esac
exit 0
UCI
chmod 755 "$BIN/uci"

# 极简 jsonfilter：只实现 -e '@.<key>' 取扁平对象的一个键。
# 必须打这个桩 —— 否则后端会退到它自己的 sed 回退分支（只认字符串值），
# 而真机走的是 jsonfilter 分支，测的东西就不是一回事了。
cat > "$BIN/jsonfilter" <<'JF'
#!/bin/sh
if [ "${1:-}" = "-e" ]; then shift; fi
KEY="$(printf '%s' "${1#@.}")"
awk -v k="\"$KEY\"" '
	{
		if (match($0, k "[ \t]*:[ \t]*")) {
			rest = substr($0, RSTART + RLENGTH)
			if (rest ~ /^"/) { sub(/^"/, "", rest); sub(/".*$/, "", rest) }
			else { sub(/[,}].*$/, "", rest); sub(/[ \t\r\n]+$/, "", rest) }
			print rest
			exit
		}
	}
'
JF
chmod 755 "$BIN/jsonfilter"

cat > "$BIN/firewall-init" <<'INIT'
#!/bin/sh
printf '%s\n' "$*" >> "${OXIDNS_FAKE_FIREWALL_LOG:?}"
exit 0
INIT
chmod 755 "$BIN/firewall-init"

PATH="$BIN:$PATH"
export PATH

new_store() { # new_store <tag>
	STORE="$WORK/store-$1"
	: > "$STORE"
	UCI_STUB_STORE="$STORE"
	export UCI_STUB_STORE
	OXIDNS_FAKE_FIREWALL_LOG="$WORK/fw-$1.log"
	export OXIDNS_FAKE_FIREWALL_LOG
	: > "$OXIDNS_FAKE_FIREWALL_LOG"
}

uci_get() { uci -q get "$1" 2>/dev/null || true; }
# 写失败不在这里炸 —— 断言会从 uci_get 读回来，读不到自然报错，比中途退出好定位。
uci_set() { uci -q set "$1" || true; }

snapshot() { cp "$STORE" "$WORK/snapshot"; }
unchanged() { # unchanged <label>
	if cmp -s "$WORK/snapshot" "$STORE"; then
		ok "$1"
	else
		bad "$1" "$(diff "$WORK/snapshot" "$STORE" | tr '\n' ' ')"
	fi
}
added_lines() { diff "$WORK/snapshot" "$STORE" | sed -n 's/^> //p'; }

config_yaml() { # config_yaml <udp-port> <tcp-port> → 打印路径
	# 形状照抄随包发行的 files/oxidns.yaml：`- tag:` 与 `type:` 分两行，
	# listen 写 ":端口"。后端 config_dns_listen 的 awk 就认这个形状。
	path="$WORK/config-$1-$2.yaml"
	{
		printf 'plugins:\n'
		printf '  - tag: udp_server\n    type: udp_server\n    args:\n'
		printf '      entry: main_sequence\n      listen: ":%s"\n' "$1"
		printf '  - tag: tcp_server\n    type: tcp_server\n    args:\n'
		printf '      entry: main_sequence\n      listen: ":%s"\n' "$2"
	} > "$path"
	printf '%s' "$path"
}

call() { # call <method> [json]
	if [ $# -ge 2 ]; then
		printf '%s' "$2" | "$BACKEND" call "$1"
	else
		"$BACKEND" call "$1" < /dev/null
	fi
}

# 造一个 0.1.5-r5 时代留下的段：有我们打的 name 标记，但（默认）没有 family。
legacy_store() { # legacy_store <tag> [<family-value>]
	new_store "$1"
	cfg="$(config_yaml 5335 5335)"
	{
		printf 'firewall.oxidns_hijack=redirect\n'
		printf 'firewall.oxidns_hijack.name=oxidns-dns-hijack\n'
		printf 'firewall.oxidns_hijack.src=lan\n'
		printf 'firewall.oxidns_hijack.proto=tcp udp\n'
		printf 'firewall.oxidns_hijack.src_dport=53\n'
		printf 'firewall.oxidns_hijack.dest_port=5335\n'
		printf 'firewall.oxidns_hijack.target=DNAT\n'
		if [ $# -ge 2 ]; then
			printf 'firewall.oxidns_hijack.family=%s\n' "$2"
		fi
		printf 'oxidns.main.config_path=%s\n' "$cfg"
	} >> "$STORE"
}

extract_postinst() { # 与 scripts/build-luci-package.sh 抽 define 块的办法一致
	awk '$0 == "define Package/luci-app-oxidns/postinst" { inside = 1; next }
	     inside && $0 == "endef" { exit }
	     inside { print }' "$MAKEFILE" | sed 's/\$\$/$/g' > "$WORK/postinst.sh"
	chmod 755 "$WORK/postinst.sh"
}

run_postinst() { # run_postinst [IPKG_INSTROOT]
	if [ -n "$POSTINST_CMD" ]; then
		script="$POSTINST_CMD"
	else
		extract_postinst
		script="$WORK/postinst.sh"
	fi
	if [ $# -ge 1 ]; then
		IPKG_INSTROOT="$1" sh "$script" >/dev/null 2>&1 || true
	else
		( unset IPKG_INSTROOT || true; sh "$script" >/dev/null 2>&1 ) || true
	fi
}

# --------------------------------------------------------------------------- #
# 断言
# --------------------------------------------------------------------------- #

suite() {
	if want sections; then
	printf '\n== 开启劫持时，段必须显式带 family=any ==\n'

	# --- 两个监听端口相同 → 单个 both 段 -------------------------------- #
	new_store c1
	uci_set "oxidns.main.config_path=$(config_yaml 5335 5335)"
	OUT="$(call hijack_save '{"enabled":true}')"
	has "同端口：返回 ok" "$OUT" '"ok":true'
	expect "同端口：建了 both 段" "$(uci_get firewall.oxidns_hijack)" "redirect"
	expect "同端口：段带 name 标记" "$(uci_get firewall.oxidns_hijack.name)" "oxidns-dns-hijack"
	expect "同端口：src=lan" "$(uci_get firewall.oxidns_hijack.src)" "lan"
	expect "同端口：proto" "$(uci_get firewall.oxidns_hijack.proto)" "tcp udp"
	expect "同端口：src_dport=53" "$(uci_get firewall.oxidns_hijack.src_dport)" "53"
	expect "同端口：dest_port" "$(uci_get firewall.oxidns_hijack.dest_port)" "5335"
	expect "同端口：target=DNAT" "$(uci_get firewall.oxidns_hijack.target)" "DNAT"
	expect "★ 同端口：family=any（否则 fw4 只渲染 IPv4）" \
		"$(uci_get firewall.oxidns_hijack.family)" "any"
	has "同端口：状态 ipv6=true" "$OUT" '"ipv6":1'
	expect "同端口：没多建 udp 段" "$(uci_get firewall.oxidns_hijack_udp)" ""
	expect "同端口：没多建 tcp 段" "$(uci_get firewall.oxidns_hijack_tcp)" ""

	# --- 两个端口不同 → udp / tcp 两段，都要带 family ------------------- #
	new_store c2
	uci_set "oxidns.main.config_path=$(config_yaml 5335 5336)"
	OUT="$(call hijack_save '{"enabled":true}')"
	has "异端口：两段" "$OUT" '"sections":["oxidns_hijack_udp","oxidns_hijack_tcp"]'
	expect "异端口：udp 段 family=any" "$(uci_get firewall.oxidns_hijack_udp.family)" "any"
	expect "异端口：tcp 段 family=any" "$(uci_get firewall.oxidns_hijack_tcp.family)" "any"
	expect "异端口：udp 段端口" "$(uci_get firewall.oxidns_hijack_udp.dest_port)" "5335"
	expect "异端口：tcp 段端口" "$(uci_get firewall.oxidns_hijack_tcp.dest_port)" "5336"
	has "异端口：状态 ipv6=true" "$OUT" '"ipv6":1'

	# --- 关掉 → 段被删、ipv6=false -------------------------------------- #
	OUT="$(call hijack_save '{"enabled":false}')"
	has "关闭：返回 ok" "$OUT" '"ok":true'
	expect "关闭：udp 段已删" "$(uci_get firewall.oxidns_hijack_udp)" ""
	expect "关闭：tcp 段已删" "$(uci_get firewall.oxidns_hijack_tcp)" ""
	has "关闭：enabled=0" "$OUT" '"enabled":0'
	has "关闭：ipv6=false" "$OUT" '"ipv6":0'

	fi

	if want legacy; then
	printf '\n== 旧版留下的段要能被看出来（只劫持了 IPv4）==\n'

	legacy_store c4
	OUT="$(call hijack_get)"
	has "遗留段：enabled=1" "$OUT" '"enabled":1'
	has "遗留段：★ ipv6=false ⇒ 暴露「只劫持 IPv4」" "$OUT" '"ipv6":0'

	legacy_store c4b any
	OUT="$(call hijack_get)"
	has "遗留段（已带 any）：ipv6=true" "$OUT" '"ipv6":1'

	fi

	if want migration; then
	printf '\n== postinst 迁移 ==\n'

	# --- 补 family=any，且只改这一处 ------------------------------------ #
	legacy_store c5
	snapshot
	run_postinst
	expect "迁移：补上 family=any" "$(uci_get firewall.oxidns_hijack.family)" "any"
	expect "迁移：只新增 family 这一行" "$(added_lines)" "firewall.oxidns_hijack.family=any"
	OUT="$(call hijack_get)"
	has "迁移后：ipv6=true" "$OUT" '"ipv6":1'

	# --- 幂等：再跑一次一个字节都不动 ----------------------------------- #
	snapshot
	run_postinst
	unchanged "迁移幂等：第二次运行不改任何东西"

	# --- 用户显式指定 ipv4 → 不动 --------------------------------------- #
	legacy_store c7 ipv4
	snapshot
	run_postinst
	expect "迁移：不动用户显式写的 ipv4" "$(uci_get firewall.oxidns_hijack.family)" "ipv4"
	unchanged "迁移：显式 ipv4 时整份配置不变"
	OUT="$(call hijack_get)"
	has "显式 ipv4：状态 ipv6=false" "$OUT" '"ipv6":0'

	# --- 不是我们的段 → 一个字节都不碰 ---------------------------------- #
	new_store c8
	{
		printf 'firewall.other_vpn=redirect\n'
		printf 'firewall.other_vpn.name=other-vpn\n'
		printf 'firewall.other_vpn.src=lan\n'
	} >> "$STORE"
	snapshot
	run_postinst
	expect "迁移：不碰别人的段" "$(uci_get firewall.other_vpn.family)" ""
	unchanged "迁移：别人的段整份不变"

	# --- 离线安装 / 镜像构建（IPKG_INSTROOT 非空）→ 整体跳过 ------------ #
	legacy_store c9
	snapshot
	run_postinst /some/buildroot
	expect "迁移：IPKG_INSTROOT 非空时跳过" "$(uci_get firewall.oxidns_hijack.family)" ""
	unchanged "迁移：跳过时整份配置不变"

	fi

	if want source; then
	printf '\n== 源码依据 ==\n'
	has "后端注释写明 fw4 的 IPv4 兜底机制" "$(cat "$BACKEND")" "backwards compatibility"
	fi
}

# 指了 INJECT_ONLY 就只跑那一条注入：基线套件由段开关决定，不重复跑一遍。
if [ -z "$INJECT_ONLY" ]; then
	suite
fi

# --------------------------------------------------------------------------- #
# 缺陷注入：确认上面的断言真的能红
# --------------------------------------------------------------------------- #

inject() { # inject <label> <后端副本|-> <postinst 副本|-> <段名> [<key>]
	if ! inject_want "$5"; then
		return 0
	fi
	_before="$FAILED"
	BACKEND="$2"
	if [ "$3" = "-" ]; then
		POSTINST_CMD=""
	else
		POSTINST_CMD="$3"
	fi
	ONLY="$4"
	printf '\n-- 注入：%s\n' "$1"
	suite >/dev/null 2>&1 || true
	BACKEND="$BACKEND_DEFAULT"
	POSTINST_CMD=""
	ONLY="${OXIDNS_HIJACK_ONLY:-all}"
	if [ "$FAILED" -gt "$_before" ]; then
		ok "注入「$1」-> 变红（$((FAILED - _before)) 条断言失败）"
	else
		bad "注入「$1」-> 依然全绿" "harness 测不出这个缺陷"
	fi
	FAILED="$_before"
}

# mutate <源文件> <目标文件> <sed 表达式>：改不出差异就直接判失败，
# 免得「注入没生效」被当成「harness 测不出来」。
mutate() {
	sed "$3" "$1" > "$2"
	chmod 755 "$2"
	if cmp -s "$1" "$2"; then
		bad "注入锚点失配" "$3 在 $1 上没改出任何差异"
		return 1
	fi
	return 0
}

if [ "$INJECT" = "1" ]; then
	printf '\n== 缺陷注入 ==\n'

	# 1) 后端不再写 family ⇒ 段退回 IPv4-only（这就是本轮修的 bug 本身）
	if mutate "$BACKEND_DEFAULT" "$WORK/backend-nofamily" \
		's/^\([[:space:]]*\)uci -q set "firewall\.\$SECT\.family=any" || return 1$/\1:/'; then
		inject "后端不写 family=any" "$WORK/backend-nofamily" "-" sections nofamily
	fi

	# 2) family 写成 inet（fw4 的 parse_family 里 'inet' 也解析成 4）⇒ 等价回归
	if mutate "$BACKEND_DEFAULT" "$WORK/backend-inet" 's/family=any/family=inet/'; then
		inject "family 写成 inet（fw4 解析成 IPv4）" "$WORK/backend-inet" "-" sections inet
	fi

	# 3) 状态里的 ipv6 恒为 true ⇒ 遗留段那个可见信号失效
	if mutate "$BACKEND_DEFAULT" "$WORK/backend-alwaysv6" \
		's/if ! hijack_family_covers_ipv6 "\$SECT"; then/if false; then/'; then
		inject "状态 ipv6 恒为 true" "$WORK/backend-alwaysv6" "-" legacy alwaysv6
	fi

	extract_postinst

	# 4) postinst 丢掉整段迁移 ⇒ 旧机器升上来还是只劫持 IPv4
	awk 'index($0, "0.1.5-r6") > 0 { skip = 1 }
	     skip && $0 == "exit 0" { skip = 0 }
	     !skip { print }' "$WORK/postinst.sh" > "$WORK/postinst-nomigrate.sh"
	chmod 755 "$WORK/postinst-nomigrate.sh"
	if cmp -s "$WORK/postinst.sh" "$WORK/postinst-nomigrate.sh"; then
		bad "注入锚点失配" "postinst 里没找到 0.1.5-r6 迁移段"
	else
		inject "postinst 没有迁移块" "$BACKEND_DEFAULT" "$WORK/postinst-nomigrate.sh" migration nomigrate
	fi

	# 5) 迁移去掉「只在 family 为空时补」的守卫 ⇒ 会覆盖用户显式写的 ipv4
	awk 'index($0, "uci -q get \"firewall.$hijack_sect.family\"") > 0 { next }
	     { print }' "$WORK/postinst.sh" > "$WORK/postinst-forced.sh"
	chmod 755 "$WORK/postinst-forced.sh"
	if cmp -s "$WORK/postinst.sh" "$WORK/postinst-forced.sh"; then
		bad "注入锚点失配" "postinst 里没找到 family 空值守卫"
	else
		inject "迁移无条件覆盖用户设置" "$BACKEND_DEFAULT" "$WORK/postinst-forced.sh" migration forced
	fi
fi

printf '\n%d failed\n' "$FAILED"
[ "$FAILED" = "0" ]
