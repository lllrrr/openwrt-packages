#!/bin/sh
# luci-app-clawpanel 一键卸载脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/a10463981/luci-app-clawpanel/main/uninstall.sh | bash
# 或: wget -qO- https://raw.githubusercontent.com/a10463981/luci-app-clawpanel/main/uninstall.sh | bash

set -e

echo "========================================"
echo " luci-app-clawpanel 一键卸载脚本"
echo "========================================"
echo ""

# 确认
echo "[INFO] 这将卸载 ClawPanel 插件"
echo "[INFO] ClawPanel 二进制文件 (/mnt/sda1/clawpanel) 将被保留"
echo "[INFO] 如需同时删除数据，请手动执行: rm -rf /mnt/sda1/clawpanel"
echo ""

printf "确认卸载? (y/N): "
read -r confirm
case "$confirm" in
    y|Y) ;;
    *) echo "已取消"; exit 0 ;;
esac

echo ""
echo "[1/3] 停止服务..."
/etc/init.d/clawpanel stop 2>/dev/null || true
killall -9 clawpanel 2>/dev/null || true

echo ""
echo "[2/3] 卸载 LuCI 插件..."
opkg remove luci-app-clawpanel 2>&1 | tail -5 || true

echo ""
echo "[3/3] 清理配置..."
# 备份并删除 UCI 配置
[ -f /etc/config/clawpanel ] && mv /etc/config/clawpanel /tmp/clawpanel-config-backup 2>/dev/null
uci revert clawpanel 2>/dev/null || true

# 清除 LuCI 缓存
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

echo ""
echo "========================================"
echo " 卸载完成"
echo "========================================"
echo ""
echo "注意: /mnt/sda1/clawpanel 目录未被删除"
echo "如需完全清除，请手动执行:"
echo "  rm -rf /mnt/sda1/clawpanel"
echo "  rm -rf /mnt/sda1/.openclaw"
