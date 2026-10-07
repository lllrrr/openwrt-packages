#!/bin/sh
# 部署 LuCI 侧改动：设置页、状态页、rpcd 插件、ACL
set -e
echo "=== 1. 语法检查（LuCI JS 用 node 只能粗查，这里只查 rpcd ucode）==="
ucode -c -o /tmp/chk-rpcd /tmp/migu-rpcd || { echo "rpcd 插件语法错误"; exit 1; }
echo "  rpcd 插件语法 OK"

echo ""
echo "=== 2. 备份现有文件 ==="
BK=/root/migu-luci-$(date +%Y%m%d-%H%M%S).bak
mkdir -p $BK
cp /usr/share/rpcd/ucode/migu                      $BK/rpcd-migu
cp /usr/share/rpcd/acl.d/luci-app-migu-iptv.json   $BK/acl.json
cp /www/luci-static/resources/view/migu/config.js  $BK/config.js
cp /www/luci-static/resources/view/migu/status.js  $BK/status.js
echo "  备份到 $BK"

echo ""
echo "=== 3. 部署 ==="
cp /tmp/migu-rpcd /usr/share/rpcd/ucode/migu && chmod 755 /usr/share/rpcd/ucode/migu
echo "  rpcd 插件 $(md5sum /usr/share/rpcd/ucode/migu | cut -d' ' -f1)"
cp /tmp/acl.json /usr/share/rpcd/acl.d/luci-app-migu-iptv.json
echo "  ACL      $(md5sum /usr/share/rpcd/acl.d/luci-app-migu-iptv.json | cut -d' ' -f1)"
cp /tmp/config.js /www/luci-static/resources/view/migu/config.js
echo "  config.js $(md5sum /www/luci-static/resources/view/migu/config.js | cut -d' ' -f1)"
cp /tmp/status.js /www/luci-static/resources/view/migu/status.js
echo "  status.js $(md5sum /www/luci-static/resources/view/migu/status.js | cut -d' ' -f1)"

echo ""
echo "=== 4. 重启 rpcd + 清 LuCI 缓存 ==="
/etc/init.d/rpcd restart
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-*cache*
echo "  done"

echo ""
echo "=== 5. 等 rpcd 就绪并验证方法可见 ==="
sleep 4
ubus -v list migu 2>/dev/null | head -12

echo ""
echo "=== 6. 关键回归：logs 传字符串（前端新写法）==="
ubus call migu logs '{"lines":"40"}' 2>&1 | head -3

echo ""
echo "=== 7. testchannel 现在在 ACL 里了吗 ==="
grep -o 'testchannel' /usr/share/rpcd/acl.d/luci-app-migu-iptv.json && echo "  ✅ 已声明"

echo ""
echo "=== 8. status 新字段是否返回 ==="
ubus call migu status 2>/dev/null | tr ',' '\n' | grep -E 'uptime|chRequests|epgIds|epgOk|maxConns|streamTtl|failTtl|activeConns|chFallback|recentPids' | sed 's/^/  /'
