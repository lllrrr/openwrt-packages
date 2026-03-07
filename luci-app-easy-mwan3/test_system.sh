#!/bin/sh
echo "======================================"
echo "OpenWrt Easy MWAN3 系统检查"
echo "======================================"
echo ""

# 系统信息
echo "[1] OpenWrt 版本:"
cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_DESCRIPTION || echo "  未知"
echo ""

# 防火墙版本
echo "[2] 防火墙版本:"
FW=$(uci get firewall.@defaults[0].name 2>/dev/null || echo "unknown")
echo "  $FW"
if echo "$FW" | grep -q "fw4"; then
    echo "  ⚠️  警告: fw4 不兼容 Easy MWAN3！"
fi
echo ""

# mwan3
echo "[3] mwan3:"
if opkg list-installed | grep -q "mwan3"; then
    opkg list-installed | grep mwan3 | awk '{print "  ✓ 已安装 (版本: " $3 ")"}'
else
    echo "  ✗ 未安装"
fi
echo ""

# LuCI
echo "[4] LuCI:"
if opkg list-installed | grep -q "luci-base"; then
    echo "  ✓ 已安装"
else
    echo "  ✗ 未安装"
fi
echo ""

# 网络接口
echo "[5] 网络接口:"
ip link show | grep -E "^[0-9]+:" | awk '{print "  " $2}' | sed 's/:$//'
echo ""

# 测试连接
echo "[6] 测试连接:"
echo -n "  网关: "; ping -c 1 -W 2 192.168.1.1 >/dev/null 2>&1 && echo "✓" || echo "✗"
echo -n "  外网: "; ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "✓" || echo "✗"
echo ""

# 可用空间
echo "[7] 可用空间:"
df -h /tmp 2>/dev/null | tail -1 | awk '{print "  /tmp: " $4}'
df -h / 2>/dev/null | tail -1 | awk '{print "  /: " $4}'
echo ""

echo "======================================"
echo "检查完成"
echo "======================================"
