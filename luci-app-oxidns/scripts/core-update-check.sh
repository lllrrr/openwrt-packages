#!/bin/sh

# 内核取源逻辑的契约测试：openwrt-oxidns 的 apk 优先，架构不支持时回落官方。
#
# 被测的是**真实源码**里的函数：从 root/usr/libexec/rpcd/luci.oxidns 抽出函数体
# 再 eval，避免测试里另抄一份实现（抄的那份永远是对的，测不出回归）。
#
# resolve_openwrt_pkg 需要 jsonfilter，开发机没有 —— 那部分放到设备上验，
# 这里只覆盖纯逻辑：版本比较、架构判定、已装包版本解析。
#
#   sh scripts/core-update-check.sh
#   sh scripts/core-update-check.sh --inject

set -eu

INJECT=0
if [ "${1:-}" = "--inject" ]; then
	INJECT=1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/root/usr/libexec/rpcd/luci.oxidns"

mkdir -p "$ROOT/tmp"
WORK=$(mktemp -d "$ROOT/tmp/core-update-check.XXXXXX")
if [ -n "${OXIDNS_CORE_CHECK_KEEP:-}" ]; then
	trap 'printf "\n临时树保留在 %s\n" "$WORK"' EXIT HUP INT TERM
else
	trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fi

FAILED=0
ok() { printf '  ok   %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  FAIL %s%s\n' "$1" "${2:+  <- $2}"; }
expect() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi
}

suite() {
	_src="$1"

	# 只抽需要的函数。version_gt / openwrt_pkg_arch / installed_pkg_version 都是
	# 纯 shell（不碰 ubus / uci / jsonfilter），可以直接跑。
	for fn in version_gt openwrt_pkg_arch installed_pkg_version; do
		_body=$(sed -n "/^$fn() {/,/^}/p" "$_src")
		[ -n "$_body" ] || { bad "源码里找不到 $fn()" "$_src"; return 1; }
		eval "$_body"
	done

	# ① version_gt：a > b 必须严格
	gt() { version_gt "$1" "$2" && printf yes || printf no; }
	expect "1.6.1-r5 > 1.6.1（缺 -rN 视为 r0）" "$(gt 1.6.1-r5 1.6.1)" "yes"
	expect "1.6.1 > 1.6.1-r5 为假" "$(gt 1.6.1 1.6.1-r5)" "no"
	expect "1.6.2 > 1.6.1-r5" "$(gt 1.6.2 1.6.1-r5)" "yes"
	expect "同版本不算更高" "$(gt 1.6.1-r5 1.6.1-r5)" "no"
	expect "1.10.0 > 1.9.9（按段比数值，不按字符串）" "$(gt 1.10.0 1.9.9)" "yes"
	expect "1.6.1-r10 > 1.6.1-r9" "$(gt 1.6.1-r10 1.6.1-r9)" "yes"
	expect "2.0 > 1.99.99" "$(gt 2.0 1.99.99)" "yes"
	expect "1.6 与 1.6.0 相等" "$(gt 1.6 1.6.0)" "no"

	# ② openwrt_pkg_arch：本机没有 /etc/apk/arch 时按 uname 兜底
	#    （CI 是 x86_64；/etc/apk/arch 分支由设备端到端覆盖）
	if [ -r /etc/apk/arch ]; then
		expect "有 /etc/apk/arch 时取它" "$(openwrt_pkg_arch)" "$(head -n1 /etc/apk/arch | tr -d ' \r')"
	else
		case "$(uname -m)" in
			x86_64 | amd64) expect "uname x86_64 映射到 x86_64 资产" "$(openwrt_pkg_arch)" "x86_64" ;;
			aarch64 | arm64) expect "uname aarch64 映射到 aarch64_generic 资产" "$(openwrt_pkg_arch)" "aarch64_generic" ;;
			*) ok "本机架构不在映射表内，跳过" ;;
		esac
	fi

	# ③ installed_pkg_version：apk-tools 3 的 `apk list -I` 是主路径
	BIN="$WORK/bin"
	rm -rf "$BIN"
	mkdir -p "$BIN"

	cat > "$BIN/apk" <<-'EOS'
		#!/bin/sh
		case "$1 $2" in
			"list -I")
				[ -n "${FAKE_APK_LIST:-}" ] && printf '%s\n' "$FAKE_APK_LIST"
				exit 0
				;;
			"info -v")
				[ -n "${FAKE_APK_INFO:-}" ] && printf '%s\n' "$FAKE_APK_INFO"
				exit 0
				;;
		esac
		exit 0
	EOS
	chmod 755 "$BIN/apk"

	_saved_path="$PATH"
	PATH="$BIN:$PATH"
	export PATH

	FAKE_APK_LIST="oxidns-1.6.1-r5 x86_64 {/home/runner/work/openwrt-oxidns/openwrt-oxidns} (GPL-3.0-or-later) [installed]"
	FAKE_APK_INFO=""
	export FAKE_APK_LIST FAKE_APK_INFO
	expect "apk list -I 解析出 1.6.1-r5" "$(installed_pkg_version)" "1.6.1-r5"

	FAKE_APK_LIST=""
	FAKE_APK_INFO="oxidns-1.6.0-r2"
	export FAKE_APK_LIST FAKE_APK_INFO
	expect "apk-tools 2 的 apk info -v 回退" "$(installed_pkg_version)" "1.6.0-r2"

	FAKE_APK_LIST=""
	FAKE_APK_INFO=""
	export FAKE_APK_LIST FAKE_APK_INFO
	expect "包未安装时返回空" "$(installed_pkg_version)" ""

	# apk 的 verbose 说明文字不该被当版本号（设备上 apk info -v 会打描述）
	FAKE_APK_LIST="oxidns: OxiDNS is a high-performance, programmable DNS engine"
	FAKE_APK_INFO=""
	export FAKE_APK_LIST FAKE_APK_INFO
	expect "描述文字不会被误认成版本" "$(installed_pkg_version)" ""

	PATH="$_saved_path"
	export PATH

	return "$FAILED"
}

printf '== oxidns 内核取源契约 ==\n\n'
suite "$SRC" && SUITE_RC=0 || SUITE_RC=1

if [ "$INJECT" = "1" ]; then
	printf '\n== 缺陷注入（每条都必须让断言变红）==\n'

	inject() { # <名称> <sed 表达式>
		_key=$1
		_expr=$2
		_copy="$WORK/inject-$_key"
		cp "$SRC" "$_copy"
		sed -i "$_expr" "$_copy"
		if cmp -s "$SRC" "$_copy"; then
			bad "注入 $_key 未生效（sed 没匹配到）"
			return 0
		fi
		if (
			FAILED=0
			suite "$_copy"
		) >"$WORK/inject-$_key.out" 2>&1; then
			bad "注入 $_key 没有被断言抓到" "见 $WORK/inject-$_key.out"
		else
			ok "注入 $_key 已变红"
		fi
	}

	# 把「缺 -rN 视为 r0」改坏：直接返回上游段比较结果，忽略修订号
	# python 注入：sed 应付不了带引号/斜杠的表达式时用这个。
	# 生成的脚本 = 读文件到 s + 调用方给的改写片段 + 写回。
	inject_py() { # <名称> <python 代码（作用在变量 s 上）>
		_key=$1
		_code=$2
		_copy="$WORK/inject-$_key"
		_py="$WORK/inject-$_key.py"
		cp "$SRC" "$_copy"
		# 原生 Windows python 不认 MSYS 的 /d/... 路径；路径走 argv 传，
		# 避免把反斜杠写进 python 字符串（\t 会变成制表符）。
		_copy_arg="$(cygpath -w "$_copy" 2>/dev/null || printf '%s' "$_copy")"
		{
			printf 'import io, sys\n'
			printf 'path = sys.argv[1]\n'
			printf 's = io.open(path, encoding="utf-8").read()\n'
			printf '%s\n' "$_code"
			printf 'io.open(path, "w", encoding="utf-8", newline="\\n").write(s)\n'
		} > "$_py"
		python "$_py" "$_copy_arg" || bad "注入 $_key 的 python 片段执行失败" "见 $_py"
		if cmp -s "$SRC" "$_copy"; then
			bad "注入 $_key 未生效（片段没改到任何内容）"
			return 0
		fi
		if (
			FAILED=0
			suite "$_copy"
		) >"$WORK/inject-$_key.out" 2>&1; then
			bad "注入 $_key 没有被断言抓到" "见 $WORK/inject-$_key.out"
		else
			ok "注入 $_key 已变红"
		fi
	}

	inject ignore_rev 's/^\t\[ "\$GT_AREV" -gt "\$GT_BREV" \]$/\treturn 1/'
	# 把逐段数值比较改回字符串比较
	inject string_cmp 's/^\tGT_CMP="\$(awk -v a="\$GT_A" -v b="\$GT_B".*$/\tGT_CMP="$(printf "\\n" | awk -v a="$GT_A" -v b="$GT_B" '"'"'BEGIN { print (a > b) ? 1 : ((a < b) ? -1 : 0) }'"'"')"/'
	# 让 apk list 解析把描述行也当版本（sed 表达式里带引号，改用 python 注入）
	inject_py loose_apk '
lines = s.split("\n")
for i, line in enumerate(lines):
    if "apk list -I oxidns" in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = indent + "PKG_VER_VALUE=\"$(apk list -I oxidns 2>/dev/null | head -n1 || true)\""
        break
s = "\n".join(lines)
'
fi

printf '\n'
if [ "$SUITE_RC" = "0" ] && [ "$FAILED" = "0" ]; then
	printf '结果: 全部通过\n'
	exit 0
fi
if [ "$SUITE_RC" != "0" ]; then
	printf '结果: %d 条断言失败\n' "$FAILED"
else
	printf '结果: 断言全过，但有 %d 条缺陷注入没有被抓到\n' "$FAILED"
fi
exit 1
