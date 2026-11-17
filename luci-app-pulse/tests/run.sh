#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

printf '\n%s\n' '检查 shell 脚本语法...'
for script in install.sh generate-version.sh root/etc/init.d/pulse-traffic \
 root/etc/uci-defaults/90-pulse-migrate root/usr/libexec/pulse-docker \
 root/usr/libexec/pulse-temperature; do
 sh -n "$script"
done

printf '\n%s\n' '运行前端回归测试...'
node --test --test-reporter=./tests/reporter.cjs tests/*.test.cjs
printf '\n%s\n' '运行翻译, 安装及版本回归测试...'
PYTHONDONTWRITEBYTECODE=1 python3 tests/run-python.py
printf '\n✔ %12s  %s\n' '-' '全部轻量回归测试已通过, 本次测试结束.'
