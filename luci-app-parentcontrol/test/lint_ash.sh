#!/bin/sh
# busybox-ash 兼容性 lint：扫出在路由器上会炸、但在 macOS/Ubuntu 的 bash/dash 上
# 测不出来的写法。用法： sh test/lint_ash.sh <file>...
# 退出码：0 = 干净；1 = 命中禁用写法。
#
# 已踩过的坑：
#   10#18  —— busybox ash 1.36 不支持 base# 前缀（算术语法错误），而本项目要
#             在主机上跑测试，主机的 bash/dash 支持，所以测试抓不到，必须靠 lint。
#   local a,b=0 —— bash 把 `a,b=0` 当两个名字、ash 当成一个非法名字直接报错中止；
#             同样只有主机测试测不出来，靠这条 lint 守（W2）。
#
# 注释行（首个非空白字符是 #）不参与匹配，避免文档里提到这些写法就误报。
set -u

# 只保留稳妥的模式（避免 [[ / ]] 这类和 [[:space:]] 打架的写法）
PATTERNS='10#|<<<|&>|local -a|declar[[:space:]]+-|^function |[[:space:]]function |\$\{[A-Za-z_][A-Za-z0-9_]*:[0-9]|local [A-Za-z_][A-Za-z0-9_]*,'

bad=0
for f in "$@"; do
	[ -f "$f" ] || continue
	hits=$(grep -nE "$PATTERNS" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
	if [ -n "$hits" ]; then
		printf '%s：\n%s\n' "$f" "$hits"
		bad=1
	fi
done

if [ "$bad" -eq 0 ]; then
	echo 'ash 兼容性检查通过'
else
	echo '发现 busybox ash 不兼容写法（见上）'
	exit 1
fi
