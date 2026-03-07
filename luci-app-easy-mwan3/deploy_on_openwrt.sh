#!/bin/sh
# OpenWrt 自动部署脚本

echo "======================================"
echo "Easy MWAN3 OpenWrt 部署脚本"
echo "======================================"
echo ""

# 系统检查
echo "[1/8] 系统检查..."
OPENWRT_VER=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_DESCRIPTION | cut -d= -f2 | tr -d '"')
FW_VER=$(uci get firewall.@defaults[0].name 2>/dev/null || echo "unknown")
echo "  OpenWrt: $OPENWRT_VER"
echo "  防火墙: $FW_VER"

if echo "$FW_VER" | grep -iq "fw4"; then
    echo ""
    echo "⚠️  警告: 检测到 fw4，Easy MWAN3 不兼容！"
    echo "   Easy MWAN3 只支持 fw3 (iptables)"
    echo ""
    echo "建议："
    echo "  1. 安装 iptables 和 firewall3"
    echo "  2. 或使用 pbr (Policy Based Routing) 替代"
    echo ""
    read -p "是否继续？(y/N): " choice
    case "$choice" in
        y|Y ) echo "继续部署...";;
        * ) echo "部署已取消"; exit 1;;
    esac
fi

# 检查依赖
echo ""
echo "[2/8] 检查依赖..."
if ! opkg list-installed | grep -q "mwan3"; then
    echo "  安装 mwan3..."
    opkg update && opkg install mwan3
else
    echo "  ✓ mwan3 已安装"
fi

if ! opkg list-installed | grep -q "luci-base"; then
    echo "  安装 LuCI..."
    opkg update && opkg install luci
else
    echo "  ✓ LuCI 已安装"
fi

# 创建目录
echo ""
echo "[3/8] 创建目录..."
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/lib/lua/luci/view/easy_mwan3
mkdir -p /etc/config
mkdir -p /etc/init.d
mkdir -p /usr/bin
echo "  ✓ 目录创建完成"

# 部署文件（需要手动创建）
echo ""
echo "[4/8] 创建配置文件..."
cat > /etc/config/easy_mwan3 << 'EOCONF'
config global 'global'
    option enabled '0'
    option mode 'balance'
    list members ''

config rule
    option src_ip ''
    option policy 'default'
    option comment ''
EOCONF
echo "  ✓ 配置文件创建完成"

echo ""
echo "[5/8] 设置权限..."
chmod 600 /etc/config/easy_mwan3
echo "  ✓ 权限设置完成"

# 下载文件
echo ""
echo "[6/8] 从主机下载文件..."
HOST_IP="192.168.1.1"
echo "  尝试连接 $HOST_IP:8888..."

# 测试连接
if wget -q --spider http://$HOST_IP:8888/test_openwrt.sh 2>/dev/null; then
    echo "  ✓ 找到主机 HTTP 服务器"
    
    # 下载文件
    cd /tmp
    echo "  下载控制器..."
    wget -q http://$HOST_IP:8888/luasrc/controller/easy_mwan3.lua -O /usr/lib/lua/luci/controller/easy_mwan3.lua
    
    echo "  下载配置模型..."
    wget -q http://$HOST_IP:8888/luasrc/model/cbi/easy_mwan3.lua -O /usr/lib/lua/luci/model/cbi/easy_mwan3.lua
    
    echo "  下载视图..."
    wget -q http://$HOST_IP:8888/luasrc/view/easy_mwan3/status.htm -O /usr/lib/lua/luci/view/easy_mwan3/status.htm
    wget -q http://$HOST_IP:8888/luasrc/view/easy_mwan3/incompatible.htm -O /usr/lib/lua/luci/view/easy_mwan3/incompatible.htm
    
    echo "  下载启动脚本..."
    wget -q http://$HOST_IP:8888/root/etc/init.d/easy_mwan3 -O /etc/init.d/easy_mwan3
    chmod +x /etc/init.d/easy_mwan3
    
    echo "  下载工具脚本..."
    wget -q http://$HOST_IP:8888/usr/bin/easy_mwan3_apply.sh -O /usr/bin/easy_mwan3_apply.sh
    wget -q http://$HOST_IP:8888/usr/bin/easy_mwan3_status.sh -O /usr/bin/easy_mwan3_status.sh
    wget -q http://$HOST_IP:8888/usr/bin/easy_mwan3_validate.sh -O /usr/bin/easy_mwan3_validate.sh
    wget -q http://$HOST_IP:8888/usr/bin/easy_mwan3_policy.sh -O /usr/bin/easy_mwan3_policy.sh
    wget -q http://$HOST_IP:8888/usr/bin/easy_mwan3_test.sh -O /usr/bin/easy_mwan3_test.sh
    chmod +x /usr/bin/easy_mwan3_*.sh
    
    echo "  ✓ 文件下载完成"
else
    echo "  ✗ 无法连接到主机 HTTP 服务器"
    echo ""
    echo "请确保主机上运行了 HTTP 服务器："
    echo "  cd /tmp/luci-app-easy-mwan3"
    echo "  python3 -m http.server 8888"
    echo ""
    echo "然后重新运行此脚本"
    exit 1
fi

# 启用服务
echo ""
echo "[7/8] 启用服务..."
/etc/init.d/easy_mwan3 enable
/etc/init.d/uhttpd restart
echo "  ✓ 服务已启用"

# 运行测试
echo ""
echo "[8/8] 运行测试..."
echo "======================================"
/usr/bin/easy_mwan3_test.sh
echo "======================================"

echo ""
echo "======================================"
echo "✓ 部署完成！"
echo "======================================"
echo ""
echo "访问地址: http://192.168.1.100/cgi-bin/luci/admin/network/easy_mwan3"
echo ""
echo "常用命令:"
echo "  应用配置: /usr/bin/easy_mwan3_apply.sh"
echo "  查看状态: /usr/bin/easy_mwan3_status.sh json"
echo "  验证配置: /usr/bin/easy_mwan3_validate.sh config"
echo "  运行测试: /usr/bin/easy_mwan3_test.sh"
echo ""
