#!/bin/sh
echo "======================================"
echo "OpenWrt 系统检查"
echo "======================================"
echo ""
cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_DESCRIPTION
uci get firewall.@defaults[0].name 2>/dev/null | xargs echo "防火墙:"
opkg list-installed | grep mwan3 | awk '{print "mwan3: " $3}' || echo "mwan3: 未安装"
opkg list-installed | grep luci-base >/dev/null 2>&1 && echo "LuCI: 已安装" || echo "LuCI: 未安装"
echo ""
echo "网络接口:"
ip link show | grep -E "^[0-9]+:" | awk '{print "  " $2}' | sed 's/:$//'
echo ""
echo "测试连接:"
ping -c 1 -W 1 192.168.1.1 >/dev/null 2>&1 && echo "  网关: ✓" || echo "  网关: ✗"
ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && echo "  外网: ✓" || echo "  外网: ✗"
echo ""
echo "可用空间:"
df -h /tmp 2>/dev/null | tail -1 | awk '{print "  /tmp: " $4}'
df -h / 2>/dev/null | tail -1 | awk '{print "  /: " $4}'
