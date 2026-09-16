#!/bin/sh
# Boot log / runtime error summary for OpenWrt
# BusyBox compatible

MODE="${1:-summary}"
MAX_LINES="${2:-80}"
case "$MAX_LINES" in ''|*[!0-9]*) MAX_LINES=80 ;; esac
[ "$MAX_LINES" -lt 20 ] && MAX_LINES=20
[ "$MAX_LINES" -gt 300 ] && MAX_LINES=300
TMP_REASON="/tmp/route-tool-bootlog-reasons-$$"
TMP_KEYS="/tmp/route-tool-bootlog-keys-$$"
trap 'rm -f "$TMP_REASON" "$TMP_KEYS"' EXIT HUP INT TERM

now_ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }
collect_log() {
    if command -v logread >/dev/null 2>&1; then logread 2>/dev/null
    elif [ -r /var/log/messages ]; then cat /var/log/messages 2>/dev/null
    fi
}
add_reason() {
    key="$1"; text="$2"
    grep -qx "$key" "$TMP_KEYS" 2>/dev/null && return
    echo "$key" >> "$TMP_KEYS"
    echo "- $text" >> "$TMP_REASON"
}
explain_line() {
    l="$1"
    echo "$l" | grep -Eiq 'I/O error|input/output error|mmc.*error|blk_update_request|Buffer I/O' && add_reason io "存储读写异常：优先检查 eMMC/NAND、供电和文件系统是否稳定。"
    echo "$l" | grep -Eiq 'read-only file system|remount.*read-only' && add_reason ro "文件系统被挂成只读：通常是存储错误或挂载异常后的保护状态。"
    echo "$l" | grep -Eiq 'bad block|ecc error|uncorrectable' && add_reason nand "NAND/eMMC 坏块或 ECC 提示：少量 NAND 坏块可正常，持续增加要备份。"
    echo "$l" | grep -Eiq 'failed to start|start.*failed|procd.*failed|init.*failed' && add_reason service "服务启动失败：看服务名，可能是配置错误、依赖缺失或脚本权限问题。"
    echo "$l" | grep -Eiq 'permission denied|denied' && add_reason perm "权限被拒绝：多见于脚本不可执行、文件权限不对或访问受限。"
    echo "$l" | grep -Eiq 'not found|No such file|command not found' && add_reason missing "文件或命令不存在：可能是依赖没安装、路径写错或旧配置残留。"
    echo "$l" | grep -Eiq 'timeout|timed out' && add_reason timeout "超时：常见于网络、DNS、上游服务慢，先检查连通性。"
    echo "$l" | grep -Eiq 'refused|connection refused' && add_reason refused "连接被拒绝：目标服务没启动、端口没监听或防火墙阻断。"
    echo "$l" | grep -Eiq 'segfault|oops|panic|crash' && add_reason crash "内核/程序崩溃：属于严重异常，需要结合前后日志定位驱动或程序问题。"
    echo "$l" | grep -Eiq 'warn|warning' && add_reason warn "警告日志：不一定影响使用，但如果反复出现需要关注对应模块。"
}

LOG="$(collect_log)"
ERR="$(printf '%s\n' "$LOG" | grep -Ei 'error|fail|failed|warn|warning|panic|oops|segfault|crash|timeout|denied|refused|not found|No such file|I/O error|read-only|corrupt|bad block|ECC' 2>/dev/null | tail -n "$MAX_LINES")"
ERR_COUNT="$(printf '%s\n' "$LOG" | grep -Eci 'error|fail|failed|warn|warning|panic|oops|segfault|crash|timeout|denied|refused|not found|No such file|I/O error|read-only|corrupt|bad block|ECC' 2>/dev/null)"
case "$ERR_COUNT" in ''|*[!0-9]*) ERR_COUNT=0 ;; esac

DMESG_ERR=""
DMESG_STATUS="unavailable"
if command -v dmesg >/dev/null 2>&1; then
    DMESG_ALL="$(dmesg 2>/dev/null)"
    if [ -n "$DMESG_ALL" ]; then
        DMESG_STATUS="ok"
        DMESG_ERR="$(printf '%s\n' "$DMESG_ALL" | grep -Ei 'error|fail|failed|warn|warning|panic|oops|segfault|crash|timeout|I/O error|read-only|corrupt|bad block|ECC' | tail -n 30)"
    else
        # Some OpenWrt builds restrict dmesg for LuCI/rpcd; report the limitation instead of silently hiding it.
        DMESG_STATUS="permission_or_empty"
    fi
fi

: > "$TMP_REASON"; : > "$TMP_KEYS"
printf '%s\n%s\n' "$ERR" "$DMESG_ERR" | while IFS= read -r line; do explain_line "$line"; done
REASON_COUNT="$(wc -l < "$TMP_REASON" 2>/dev/null | tr -d ' ')"
case "$REASON_COUNT" in ''|*[!0-9]*) REASON_COUNT=0 ;; esac
if [ "$ERR_COUNT" -gt 0 ] && [ "$REASON_COUNT" -eq 0 ]; then
    echo "- 有异常关键词，但暂未匹配到具体类型；建议看下面原始日志前后文。" >> "$TMP_REASON"
    REASON_COUNT=1
fi

echo "BOOTLOG_TIME=$(now_ts)"
echo "BOOTLOG_SOURCE=$(command -v logread >/dev/null 2>&1 && echo logread || echo file)"
echo "BOOTLOG_DMESG_STATUS=$DMESG_STATUS"
echo "BOOTLOG_ERROR_COUNT=$ERR_COUNT"
echo "BOOTLOG_EXPLAIN_COUNT=$REASON_COUNT"
if [ "$ERR_COUNT" -eq 0 ]; then
    echo "BOOTLOG_STATUS=OK"
    echo "BOOTLOG_SUMMARY=暂未发现明显 error/fail/warn/panic 关键日志"
    echo "BOOTLOG_EXPLAIN_SUMMARY=未发现明显异常"
else
    echo "BOOTLOG_STATUS=WARN"
    echo "BOOTLOG_SUMMARY=发现 ${ERR_COUNT} 条疑似异常日志，下面列出最近 ${MAX_LINES} 条"
    echo "BOOTLOG_EXPLAIN_SUMMARY=已按关键词归类 ${REASON_COUNT} 类问题，详情见中文解释"
fi

echo "===BOOTLOG_EXPLAIN==="
if [ -s "$TMP_REASON" ]; then cat "$TMP_REASON"; else echo "未发现明显异常"; fi

echo "===BOOTLOG_ERRORS==="
if [ -n "$ERR" ]; then printf '%s\n' "$ERR"; else echo "无明显异常日志"; fi

echo "===DMESG_ERRORS==="
if [ -n "$DMESG_ERR" ]; then
    printf '%s\n' "$DMESG_ERR"
elif [ "$DMESG_STATUS" = "permission_or_empty" ]; then
    echo "dmesg 无输出，可能是权限受限或内核环形缓冲区为空"
else
    echo "无明显内核异常日志"
fi

echo "===BOOTLOG_RECENT==="
printf '%s\n' "$LOG" | tail -n 40
