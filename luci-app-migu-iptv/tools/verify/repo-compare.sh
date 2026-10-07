#!/bin/sh
# 汇总路由器上 migu 插件的所有文件 md5，用于与本地仓库比对
echo "== ROUTER MIGU FILES =="
for f in \
  /usr/share/ucode/migu.uc \
  /www/luci-static/resources/view/migu/config.js \
  /www/luci-static/resources/view/migu/status.js \
  /usr/share/rpcd/ucode/migu \
  /usr/share/rpcd/acl.d/luci-app-migu-iptv.json \
  /usr/share/luci/menu.d/luci-app-migu-iptv.json \
  /etc/init.d/migu \
  /etc/config/migu
do
  if [ -f "$f" ]; then
    printf "%-60s " "$f"
    md5sum "$f" | awk '{print $1}'
  else
    printf "%-60s MISSING\n" "$f"
  fi
done
echo "== APP_VERSION =="
grep -m1 "APP_VERSION" /usr/share/ucode/migu.uc
echo "== HEALTH =="
curl -s -m 5 http://127.0.0.1:8788/health
echo ""
echo "== DONE =="
