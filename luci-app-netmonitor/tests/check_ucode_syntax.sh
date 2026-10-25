#!/bin/sh
# ucode 语法检查（近似校验）
#
# 背景：rpcd 的 ucode 插件（root/usr/share/rpcd/ucode/luci.netmonitor）
# 是整个后端的入口。它一旦有语法错误，rpcd 加载插件失败，表现为「所有 RPC
# 调用返回对象不存在」，而不是一条编译错误——排查成本很高。CI 与开发机上
# 通常没有 ucode 解释器，因此这里用 node 做近似解析。
#
# 可行性：ucode 的语法是 ES5 / ES2015 的子集扩展，括号、引号、语句结构
# 层面的错误 node 同样能捕获。本检查定位为「挡住低级语法错误」，
# 不替代实机上的 rpcd 加载验证。
#
# 三处必要的预处理（ucode 与 ES module 的差异）：
#   1. shebang：首行 #!... 在包进函数体后是非法 token，转成行注释。
#   2. import：ucode 的 import 可以出现在文件中部，ES module 要求它在
#      模块顶层；包进函数体后全部注释掉（这几行本身形态固定，
#      漏检的风险远小于让整个检查跑不起来）。
#   3. 顶层 return：ucode 允许顶层 return（即模块导出对象），
#      ES module 与函数体外都不允许，故整体包一层函数。
#
# 用法：sh tests/check_ucode_syntax.sh [文件...]
#       不传参数时检查默认的 ucode 插件文件。

set -u

if [ "$#" -gt 0 ]; then
	FILES="$*"
else
	D=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	FILES="$D/../root/usr/share/rpcd/ucode/luci.netmonitor"
fi

if ! command -v node >/dev/null 2>&1; then
	echo "skip  ucode 语法检查：本环境无 node"
	exit 0
fi

rc=0
for f in $FILES; do
	if [ ! -f "$f" ]; then
		echo "FAIL  $f (文件不存在)"
		rc=1
		continue
	fi

	tmp=$(mktemp "${TMPDIR:-/tmp}/ucode-check.XXXXXX.mjs")
	err=$(mktemp "${TMPDIR:-/tmp}/ucode-check.XXXXXX.err")

	{
		echo 'function __ucode_wrap__() {'
		sed -e '1s|^#!.*|// &|' -e '/^import /s|^|// |' "$f"
		echo
		echo '}'
	} > "$tmp"

	if node --check "$tmp" 2>"$err"; then
		echo "ok    $f"
	else
		echo "FAIL  $f"
		sed 's/^/      /' "$err" | head -20
		rc=1
	fi

	rm -f "$tmp" "$err"
done

exit $rc
