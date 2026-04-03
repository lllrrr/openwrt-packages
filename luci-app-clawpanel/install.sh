#!/bin/sh
# luci-app-clawpanel 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/a10463981/luci-app-clawpanel/main/install.sh | bash
# 或: wget -qO- https://raw.githubusercontent.com/a10463981/luci-app-clawpanel/main/install.sh | bash

set -e

RELEASE_URL="https://github.com/a10463981/luci-app-clawpanel/releases/download/v1.0.1"
TMP_DIR="/tmp/luci-app-clawpanel-install"
ARCH=""

# 检测架构
detect_arch() {
    case "$(uname -m)" in
        aarch64)  ARCH="aarch64" ;;
        armv7l)   ARCH="armv7" ;;
        armv6l)   ARCH="armv7" ;;
        i386|i686) ARCH="x86_64" ;;
        x86_64)   ARCH="x86_64" ;;
        mips|mipsle)
            # 尝试更精确的检测
            if grep -q "Features" /proc/cpuinfo 2>/dev/null; then
                ARCH="armv7"
            else
                ARCH="mips" # fallback
            fi
            ;;
        *)
            echo "[ERROR] 不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
    echo "[INFO] 检测到架构: $ARCH"
}

# 检测外置存储挂载点
detect_storage() {
    # 优先使用已挂载的大容量存储
    for mp in /mnt/sda1 /mnt/sdb1 /mnt/data /mnt/storage /overlay; do
        if [ -d "$mp" ] && [ "$(df -m "$mp" 2>/dev/null | tail -1 | awk '{print $2}')" -gt 500 ] 2>/dev/null; then
            echo "$mp"
            return 0
        fi
    done
    echo "/mnt/sda1"  # 默认
}

echo "========================================"
echo " luci-app-clawpanel 一键安装脚本"
echo "========================================"
echo ""

detect_arch

STORAGE=$(detect_storage)
echo "[INFO] 将安装到: $STORAGE"
echo ""

# 创建临时目录
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

# 下载 ipk
IPK_FILE="luci-app-clawpanel_1.0.0_${ARCH}.ipk"
echo "[1/4] 下载安装包 (${ARCH})..."
wget -q --show-progress -O "$IPK_FILE" "${RELEASE_URL}/${IPK_FILE}" 2>&1 || {
    echo "[ERROR] 下载失败，请检查网络或 Release 是否已发布"
    exit 1
}
echo "[OK] 下载完成: $(ls -lh "$IPK_FILE" | awk '{print $5}')"

# 安装
echo ""
echo "[2/4] 安装软件包..."
opkg install "$IPK_FILE" 2>&1 | tail -5

# 初始化 UCI
echo ""
echo "[3/4] 配置软件包..."
if [ -x /etc/uci-defaults/99-clawpanel ]; then
    /etc/uci-defaults/99-clawpanel 2>/dev/null || true
fi

# 清除 LuCI 缓存
echo ""
echo "[4/4] 刷新 LuCI..."
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

# 提示手动步骤
echo ""
echo "========================================"
echo " 安装完成！"
echo "========================================"
echo ""
echo "请在浏览器访问: http://192.168.1.1"
echo "登录后进入: 服务 → ClawPanel"
echo ""
echo "首次使用需要点击【安装】按钮下载 ClawPanel 二进制"
echo "安装路径: ${STORAGE}/clawpanel"
echo ""

# 清理
rm -rf "$TMP_DIR"
