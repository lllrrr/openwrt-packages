#!/bin/sh
echo "=== form.js 里与 password 相关的处理 ==="
grep -o '.\{240\}password.\{240\}' /www/luci-static/resources/form.js | head -6
echo ""
echo "=== 统计 password 出现次数 ==="
grep -c 'password' /www/luci-static/resources/form.js
