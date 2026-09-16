#!/bin/sh
# Storage Smart Diagnosis - all tests combined
MODE="${1:-quick}"

echo "DIAG_MODE=${MODE}"
echo "DIAG_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
echo "DIAG_UPTIME=$(awk '{printf "%d",$1}' /proc/uptime)"

# System
echo "SYS_KERNEL=$(uname -r)"
echo "SYS_ARCH=$(uname -m)"
echo "===PHASE:system==="
/usr/libexec/route-tool.d/storage_system.sh 2>/dev/null

# Storage type
if [ -d /sys/class/mmc_host/mmc0 ]; then
    echo "STORAGE_TYPE=eMMC"
elif grep -q mtd /proc/mtd 2>/dev/null; then
    echo "STORAGE_TYPE=NAND"
else
    echo "STORAGE_TYPE=unknown"
fi

# eMMC health
echo "===PHASE:emmc_health==="
/usr/libexec/route-tool.d/storage_health.sh 2>/dev/null

# Speed test
# UI 只保留一个“eMMC测速”，综合诊断也统一使用默认档位。
echo "===PHASE:emmc_speed==="
/usr/libexec/route-tool.d/storage_speed.sh standard 2>/dev/null

# Memory info + quick test
echo "===PHASE:memory==="
/usr/libexec/route-tool.d/storage_memory.sh info 2>/dev/null
/usr/libexec/route-tool.d/storage_memory.sh quick 128 2>/dev/null

# NAND
echo "===PHASE:nand==="
/usr/libexec/route-tool.d/storage_nand.sh 2>/dev/null

# Detail
echo "===PHASE:detail==="
/usr/libexec/route-tool.d/storage_detail.sh 2>/dev/null

# Partitions
echo "===PHASE:partitions==="
df -h 2>/dev/null | grep -v "tmpfs\|devtmpfs\|overlay" | awk '{print $1,$2,$3,$5,$6}' | tr "\n" "|"

echo ""
echo "DIAG_DONE=1"
