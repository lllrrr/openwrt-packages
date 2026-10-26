#!/bin/sh
# Lua 禁用扫描 —— 任务书要求「绝对不使用 Lua」，且必须可自动验证，
# 而不是靠人在 review 里记住。
#
# 设计约束：
#   1. 只判定「项目自有文件」。构建产物（target/、bin/、build/…）、OpenWrt SDK、
#      feeds、工具链自带的 Lua 都不算本项目违规 —— 否则这个检查会在别人的树里
#      疯狂误报，而误报的检查最终都会被人注释掉。
#   2. 除文件名维度外还有内容维度：*.js / *.uc / *.json 里出现 Lua 专有写法
#      （luci.dispatcher、luci.model.uci、require("luci…")）说明有人把旧代码
#      抄进来了，即使扩展名不是 .lua 也要拦下。
#   3. 构建维度：Makefile 不得声明 Lua 依赖、不得安装 luasrc/。
#   4. 任一维度违规即以非零码退出，Makefile 的检查步骤随之失败。
#
# 用法：
#   ./scripts/no-lua-check.sh            # 扫描工作树
#   ./scripts/no-lua-check.sh --verbose  # 打印排除规则与统计
#
# 已知限制：按行处理文件路径，因此不支持文件名里含换行符（本仓库不存在）。

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

verbose=0
if [ "${1:-}" = "--verbose" ]; then
    verbose=1
fi

# 需要整体跳过的目录（构建产物与上游代码）。
skip='^\./(target|bin|build|ipk-split|openwrt|feeds|node_modules|tmp|dl|staging|\.git)/'

all_files=$(find . -type f | grep -Ev "$skip" || true)

# 1) 文件名维度：项目内不得存在任何 .lua。
violations_files=$(printf '%s\n' "$all_files" | grep -E '\.lua$' || true)

# 2) 内容维度。
pattern='require[[:space:]]*\(?"?luci\.|luci\.dispatcher|luci\.model\.uci|luci\.cview'
# 扫描器自身含有这些模式字符串，必须排除，否则永远自报违规。
code_files=$(printf '%s\n' "$all_files" | grep -E '\.(js|uc|json|html|sh|ts)$|(^|/)Makefile$' \
    | grep -v -x './scripts/no-lua-check.sh' || true)
violations_content=
if [ -n "$code_files" ]; then
    violations_content=$(printf '%s\n' "$code_files" | xargs grep -lE "$pattern" -- 2>/dev/null || true)
fi

# 3) 构建维度。
lua_deps=
if [ -f Makefile ]; then
    lua_deps=$(grep -nE 'luci-lua-runtime|liblua|lua5[0-9]|DEPENDS.*[^e]lua|luasrc' Makefile || true)
fi

status=0
report() {
    if [ -n "$1" ]; then
        printf '发现 Lua 违规（%s）：\n%s\n' "$2" "$1"
        status=1
    fi
}

report "$violations_files" ".lua 文件"
report "$violations_content" "Lua 专有 API 引用"
report "$lua_deps" "Makefile 中的 Lua 依赖"

count() {
    if [ -z "$1" ]; then
        printf '0'
    else
        printf '%s\n' "$1" | grep -c .
    fi
}

if [ "$verbose" = 1 ]; then
    echo "排除规则：$skip"
    printf '统计：项目文件=%s  .lua=%s  API 引用=%s  Makefile 依赖=%s\n' \
        "$(printf '%s\n' "$all_files" | grep -c .)" \
        "$(count "$violations_files")" "$(count "$violations_content")" "$(count "$lua_deps")"
fi

if [ "$status" -eq 0 ]; then
    echo "no-lua-check: 通过（0 个 .lua 文件，0 处 Lua API 引用，Makefile 无 Lua 依赖）"
fi
exit "$status"
