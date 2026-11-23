#!/bin/sh
# network.js 自动检测节流行为测试（纯 Node，无 LuCI 依赖）。
# node 不可用时跳过，不影响 shell-only 环境。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
	echo "SKIP: node not available, skipping network-auto-detect-throttle"
	exit 0
fi

exec node "$ROOT/tests/network-auto-detect-throttle.cjs"
