#!/bin/bash

# 自动编译 luci-app-block-host 为 ipk 包的脚本
# 需要预先安装 OpenWrt SDK

set -e

SDK_PATH="${SDK_PATH:-$HOME/openwrt-sdk}"
PLUGIN_NAME="luci-app-hostblocker"

echo "=== 编译 $PLUGIN_NAME ==="

# 检查 SDK 是否存在
if [ ! -d "$SDK_PATH" ]; then
    echo "错误：未找到 OpenWrt SDK 在 $SDK_PATH"
    echo "请设置 SDK_PATH 环境变量或下载 SDK"
    echo "下载地址：https://downloads.openwrt.org/releases/"
    exit 1
fi

cd "$SDK_PATH"

# 创建 feeds.conf.default（如果不存在）
if [ ! -f feeds.conf.default ]; then
    echo "创建 feeds.conf.default..."
    echo "src-git feeds https://github.com/openwrtfeeds/openwrtfeeds.git" > feeds.conf.default
fi

# 更新 feeds
echo "更新 feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# 复制插件（从 src 复制到 package）
echo "从 src 复制插件到 package 目录..."
mkdir -p package/$PLUGIN_NAME
cp -r "$(dirname "$0")/src/"* package/$PLUGIN_NAME/

# 配置
echo "配置编译选项..."
echo "CONFIG_PACKAGE_$PLUGIN_NAME=y" >> .config
make defconfig

# 编译
echo "开始编译..."
make package/$PLUGIN_NAME/compile V=s

# 显示结果
echo ""
echo "=== 编译完成 ==="
echo "IPK 文件位置："
find bin/packages -name "$PLUGIN_NAME*.ipk" 2>/dev/null || echo "未找到生成的 ipk 文件"
