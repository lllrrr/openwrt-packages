#!/bin/sh
# 部署 menu.d（路由器上缺 config 路由，导致「设置」页 404）
echo "=== 部署前 ==="
cat /usr/share/luci/menu.d/luci-app-migu-iptv.json | grep -c 'config' || true
echo "  （上面数字为 0 说明 config 路由缺失）"

cp /usr/share/luci/menu.d/luci-app-migu-iptv.json /root/menu.d-migu.bak
cp /tmp/menu.json /usr/share/luci/menu.d/luci-app-migu-iptv.json

echo ""
echo "=== 部署后 ==="
cat /usr/share/luci/menu.d/luci-app-migu-iptv.json

echo ""
echo "=== 清 LuCI 缓存 ==="
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
echo "  done"

echo ""
echo "=== 确认视图文件在位 ==="
ls -l /www/luci-static/resources/view/migu/
