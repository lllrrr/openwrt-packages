#!/bin/sh

# 限制 Gately 运行日志在 tmpfs 上的占用。
# /tmp 是内存盘，Gately 的 stdout/stderr 直接重定向到 $LOGFILE，长时间运行会一直长；
# 这里按固定间隔检查，超过上限就只保留最后一段。
#
# 关键：必须「原地截断」而不是 mv 覆盖。
# gately 的 stdout 是以 O_APPEND 打开的，一旦换掉 inode，它会继续往已删除的旧文件写，
# 空间不会释放、界面也再看不到日志。cat > file 才是 truncate 原文件、保留 inode。

LOG="${1:-/tmp/gately-plus-update/gately-start.log}"
MAX=524288          # 上限 512 KB
KEEP=262144         # 超出后保留最后 256 KB
INTERVAL=120        # 检查间隔（秒）

log_size() {
    # busybox 的 wc -c 会真的把整个文件读一遍，优先用 stat
    stat -c %s "$1" 2>/dev/null && return 0
    wc -c < "$1" 2>/dev/null | tr -d ' '
}

while true; do
    sleep "$INTERVAL"
    [ -f "$LOG" ] || continue

    size=$(log_size "$LOG")
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -gt "$MAX" ] || continue

    tmp="$LOG.trim"
    {
        printf '[%s] log trimmed: was %s bytes, kept last %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$size" "$KEEP"
        tail -c "$KEEP" "$LOG"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }

    # 原地写回：保留 inode，gately 的 O_APPEND 句柄继续有效
    cat "$tmp" > "$LOG" 2>/dev/null
    rm -f "$tmp"
done
