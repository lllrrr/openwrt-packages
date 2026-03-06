#!/bin/bash
# SocksClash v1.2.0 单个节点测速脚本

SECTION="$1"
UCI_CONFIG="socks-clash"
DELAY_FILE="/tmp/socks-clash_delay_${SECTION}"
TEST_URL="http://www.gstatic.com/generate_204"
TIMEOUT=5

if [ -z "$SECTION" ]; then
    echo "Usage: $0 <section_name>"
    exit 1
fi

# 获取节点信息
ENABLED=$(uci -q get "$UCI_CONFIG.$SECTION.enabled")
TYPE=$(uci -q get "$UCI_CONFIG.$SECTION.type")
SERVER=$(uci -q get "$UCI_CONFIG.$SECTION.server")
PORT=$(uci -q get "$UCI_CONFIG.$SECTION.port")

if [ "$ENABLED" != "1" ]; then
    echo "0" > "$DELAY_FILE"
    exit 1
fi

if [ -z "$SERVER" ] || [ -z "$PORT" ]; then
    echo "0" > "$DELAY_FILE"
    exit 1
fi

# 简单的延迟测试（TCP 连接时间）
start_time=$(date +%s%3N)

if timeout $TIMEOUT bash -c "echo -n '' > /dev/tcp/$SERVER/$PORT" 2>/dev/null; then
    end_time=$(date +%s%3N)
    delay=$((end_time - start_time))
    echo "$delay" > "$DELAY_FILE"
    exit 0
else
    echo "0" > "$DELAY_FILE"
    exit 1
fi
