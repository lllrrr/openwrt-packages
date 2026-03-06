#!/bin/bash
# 快速部署脚本 - 将 luci-app-cymonline 部署到 OpenWrt 设备调试
# 用法: ./deploy.sh <router_ip> [user]
# 示例: ./deploy.sh 192.168.1.1 root

ROUTER_IP="${1:-192.168.1.1}"
ROUTER_USER="${2:-root}"
APP_DIR="$(dirname "$0")/root"

echo "========================================"
echo "部署 luci-app-cymonline 到 $ROUTER_USER@$ROUTER_IP"
echo "========================================"

# 检查目录
if [ ! -d "$APP_DIR" ]; then
    echo "错误: 找不到 root 目录"
    exit 1
fi

# 部署文件
echo "[1/4] 复制配置文件..."
scp "$APP_DIR/etc/config/cymonline" "$ROUTER_USER@$ROUTER_IP:/etc/config/"

echo "[2/4] 复制服务脚本..."
scp "$APP_DIR/etc/init.d/cymonline" "$ROUTER_USER@$ROUTER_IP:/etc/init.d/"
ssh "$ROUTER_USER@$ROUTER_IP" "chmod +x /etc/init.d/cymonline"

echo "[3/4] 复制核心文件..."
ssh "$ROUTER_USER@$ROUTER_IP" "mkdir -p /usr/lib/cymonline /usr/lib/lua/cymonline /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/cymonline"

scp "$APP_DIR/usr/lib/cymonline/network.sh" "$ROUTER_USER@$ROUTER_IP:/usr/lib/cymonline/"
ssh "$ROUTER_USER@$ROUTER_IP" "chmod +x /usr/lib/cymonline/network.sh"

scp "$APP_DIR/usr/lib/lua/cymonline/core.lua" "$ROUTER_USER@$ROUTER_IP:/usr/lib/lua/cymonline/"
scp "$APP_DIR/usr/lib/lua/luci/controller/cymonline.lua" "$ROUTER_USER@$ROUTER_IP:/usr/lib/lua/luci/controller/"
scp "$APP_DIR/usr/lib/lua/luci/view/cymonline/status.htm" "$ROUTER_USER@$ROUTER_IP:/usr/lib/lua/luci/view/cymonline/"

echo "[4/4] 重启 LuCI 服务..."
ssh "$ROUTER_USER@$ROUTER_IP" "/etc/init.d/cymonline enable 2>/dev/null; /etc/init.d/cymonline restart 2>/dev/null; /etc/init.d/uhttpd restart; rm -rf /tmp/luci-*"

echo ""
echo "========================================"
echo "部署完成！"
echo "访问: http://$ROUTER_IP/cgi-bin/luci/admin/status/cymonline"
echo "========================================"
