#!/bin/sh
echo "=== form.js 里所有导出的类名（Class.extend 赋值）==="
grep -nE '^[A-Za-z]+ *: *Class\.extend' /www/luci-static/resources/form.js | sed 's/^/  /'

echo ""
echo "=== 直接搜 Textarea / TextArea ==="
grep -n 'extarea' /www/luci-static/resources/form.js | head -10

echo ""
echo "=== 搜 TextValue ==="
grep -n 'TextValue' /www/luci-static/resources/form.js | head -10
