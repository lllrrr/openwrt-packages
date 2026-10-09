#!/bin/sh
# UI 静态结构检查（W37/W38/W39/W42-静态）。主机没有 lua，无法行为级跑 LuCI ——
# 由 ui_static_check.py 扫源码兜底（能力边界声明见该文件头部）。
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
exec python3 "$HERE/ui_static_check.py" "$REPO"
