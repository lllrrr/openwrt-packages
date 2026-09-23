#!/bin/sh
# One-click installer for UPS Manager
# Compatible with OpenWrt 23.x, 24.x, 25.x and iStoreOS (apk / opkg)

set -e

echo "=== [1/6] 正在检测系统包管理器与安装依赖 ==="
if command -v apk >/dev/null 2>&1; then
    echo "检测到 apk 包管理器 (OpenWrt 25.x / iStoreOS 25.12+)"
    apk update
    apk add nut-server nut-upsmon nut-upsc nut-driver-usbhid-ups curl
elif command -v opkg >/dev/null 2>&1; then
    echo "检测到 opkg 包管理器"
    opkg update
    opkg install nut nut-common nut-server nut-upsmon nut-upsc nut-driver-usbhid-ups curl
else
    echo "警告: 未能检测到 apk 或 opkg，请手动确认依赖安装。"
fi

echo "=== [2/6] 正在下载最新版本的 UPS Manager ==="
mkdir -p /tmp/ups-manager-install
cd /tmp/ups-manager-install
curl -kL https://github.com/liuyuhao1023/luci-app-ups-manager/archive/refs/heads/main.tar.gz -o ups-manager.tar.gz
tar -zxvf ups-manager.tar.gz

echo "=== [3/6] 正在部署文件到系统目录 ==="
cp -r luci-app-ups-manager-main/root/* /
cp -r luci-app-ups-manager-main/htdocs/* /www/

echo "=== [4/6] 正在配置系统执行权限与换行符 ==="
chmod +x /etc/init.d/ups-manager
chmod +x /usr/bin/ups-manager-*
chmod +x /usr/libexec/rpcd/luci.ups-manager
chmod +x /etc/uci-defaults/80_ups_manager

# Strip any carriage returns if present
sed -i 's/\r$//' /etc/init.d/ups-manager /usr/bin/ups-manager-* /usr/libexec/rpcd/luci.ups-manager /etc/uci-defaults/80_ups_manager 2>/dev/null || true

echo "=== [5/6] 正在初始化配置并启动服务 ==="
/etc/uci-defaults/80_ups_manager 2>/dev/null || true
/etc/init.d/ups-manager enable
/etc/init.d/ups-manager restart

echo "=== [6/6] 正在重新载入 RPC 并清理 LuCI 缓存 ==="
/etc/init.d/rpcd restart
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/

echo ""
echo "============================================================"
echo "  恭喜！UPS Manager v1.0.0 已成功安装并启动！"
echo "  请刷新浏览器访问路由器后台，进入「服务」->「UPS 管理」使用。"
echo "============================================================"
