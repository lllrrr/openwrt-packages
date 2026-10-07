#!/bin/sh
echo "=== form.js 中 password 的位置（前后各 300 字符）==="
grep -o '.\{0,300\}password.\{0,300\}' /www/luci-static/resources/form.js

echo ""
echo "=== 在 luci 的 JS 资源里全局搜 o.password / .password ==="
grep -rlo 'password' /www/luci-static/resources/*.js 2>/dev/null

echo ""
echo "=== admin 目录里的用法 ==="
grep -rn 'password *=' /www/luci-static/resources/view/ 2>/dev/null | head -20

echo ""
echo "=== cbi.js 里的 password ==="
grep -o '.\{0,200\}password.\{0,200\}' /www/luci-static/resources/cbi.js 2>/dev/null | head -5
ls -l /www/luci-static/resources/cbi.js 2>/dev/null
