#!/bin/sh
# 便捷打包入口。真正干活的是 build-ipk.py（纯 Python，不依赖 SDK 与 ar/tar）。
#
# 用法：
#   sh scripts/build-ipk.sh            # 打包，版本号取 Makefile
#   sh scripts/build-ipk.sh 1.0.1      # 指定版本号
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

# 优先 python3，退到 python（Windows 常见）
if command -v python3 >/dev/null 2>&1; then
	PY=python3
elif command -v python >/dev/null 2>&1; then
	PY=python
else
	echo "需要 python3 或 python 才能打包" >&2
	exit 1
fi

exec "$PY" "$HERE/build-ipk.py" "$@"
