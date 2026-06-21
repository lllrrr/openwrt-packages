#!/bin/sh
# fix_mac_hostname.sh
# 清理 devicemaster UCI 中 hostname 字段被设成 MAC 地址的设备记录。
# 匹配模式：XX:XX:XX:XX:XX:XX / XX-XX-XX-XX-XX-XX / XXXXXXXXXXXX
# 条件：hostname 匹配 MAC 格式 且 manual != "1"
# 结果：将该设备的 hostname 清空，下次 DHCP 事件 / discover 会自动重新写入真实 hostname。

echo "=== 扫描被污染成 MAC 地址的 hostname ==="
found=0
for section in $(uci show devicemaster | grep "=device$" | cut -d. -f2 | cut -d= -f1); do
    hn=$(uci -q get devicemaster.$section.hostname)
    mac=$(uci -q get devicemaster.$section.mac)
    man=$(uci -q get devicemaster.$section.manual)

    # 空值直接跳过
    [ -z "$hn" ] && continue

    # 检查 hostname 是否匹配任意 MAC 格式
    is_mac=0
    case "$hn" in
        ??:??:??:??:??:??) is_mac=1 ;;
        ??-??-??-??-??-??) is_mac=1 ;;
        ????????????)
            # 12位纯十六进制（小写转大写后验证）
            echo "$hn" | grep -qiE '^[0-9A-F]{12}$' && is_mac=1
            ;;
    esac

    if [ "$is_mac" = "1" ]; then
        echo "  [FOUND] section=$section  mac=$mac  hostname=$hn  manual=$man"
        if [ "$man" = "1" ]; then
            echo "         manual=1，跳过（用户手动设置的 hostname）"
        else
            echo "         清空 hostname，等待重新同步..."
            uci -q delete devicemaster.$section.hostname
            uci -q commit devicemaster
            found=$((found + 1))
        fi
        echo ""
    fi
done

if [ "$found" -gt 0 ]; then
    echo "=== 已清空 $found 个设备的 hostname ==="
    echo "建议在 LuCI 页面按 F5 刷新，或等待下次 discover 周期（1 分钟内）重新同步。"
else
    echo "=== 未发现 hostname 为 MAC 格式且 manual!=1 的设备 ==="
fi
