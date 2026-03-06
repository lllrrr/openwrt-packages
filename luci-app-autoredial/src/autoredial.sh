#!/bin/sh

# 基础日志函数
log_msg() {
    logger -t "AutoRedial" "$1"
}

# 读取配置
get_config() {
    config_load autoredial
    config_get ENABLED config enabled 0
    config_get METHOD config method "ping"
    config_get TARGET config target "8.8.8.8"
    config_get INTERFACE config interface "wan"
    config_get INTERVAL config interval 30
    config_get COUNT config count 3
}

fail_counter=0

log_msg "Service started."

while true; do
    get_config

    if [ "$ENABLED" -eq 1 ]; then
        CHECK_RESULT=1

        if [ "$METHOD" = "ping" ]; then
            # Ping 检测
            if ping -c 1 -W 3 "$TARGET" > /dev/null 2>&1; then
                CHECK_RESULT=0
            fi
        elif [ "$METHOD" = "url" ]; then
            # URL 检测 (使用 wget 抓取 header，超时5秒)
            if wget --spider --timeout=5 -q "$TARGET" 2>/dev/null; then
                CHECK_RESULT=0
            fi
        fi

        if [ "$CHECK_RESULT" -eq 0 ]; then
            # 网络正常，重置计数器
            if [ "$fail_counter" -gt 0 ]; then
                log_msg "Network recovered."
            fi
            fail_counter=0
        else
            # 网络异常
            fail_counter=$((fail_counter + 1))
            log_msg "Detection failed ($METHOD -> $TARGET). Count: $fail_counter/$COUNT"
            
            if [ "$fail_counter" -ge "$COUNT" ]; then
                log_msg "Threshold reached. Re-dialing interface: $INTERFACE..."
                ifup "$INTERFACE"
                # 重拨后等待一段时间，避免频繁检测
                sleep 15
                fail_counter=0
            fi
        fi
    fi

    sleep "$INTERVAL"
done