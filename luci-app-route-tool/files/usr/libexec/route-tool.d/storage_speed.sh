#!/bin/sh
# eMMC Speed Test - sequential write/read on real eMMC mount
# Usage: storage_speed.sh [size_MB|quick|standard|deep|cleanup] [test_dir|auto]
# BusyBox compatible

ARG="${1:-standard}"
REQ_DIR="${2:-auto}"
MIN_EMMC_KEEP_MB=256
MIN_TMP_KEEP_MB=64
MAX_SIZE_MB=1024

cleanup_one_dir() {
    d="$1"
    case "$d" in ''|/|/proc|/sys|/dev|/run|/rom) return ;; esac
    [ -d "$d" ] && [ -w "$d" ] || return
    rm -f "$d"/emmc*.dat "$d"/emmc_speed_test_*.dat "$d"/emmc_4k_*.dat "$d"/route-tool-speed-read-*.dat 2>/dev/null
    find "$d" -maxdepth 1 -type d -name 'route-tool-speed-*' -exec rm -rf {} \; 2>/dev/null
}

cleanup_leftovers() {
    # Discover writable mount points dynamically instead of naming device-specific /mnt/mmcblk0pXX paths.
    cleanup_one_dir /tmp
    cleanup_one_dir /root
    cleanup_one_dir /overlay
    case "$REQ_DIR" in auto|"") ;; *) cleanup_one_dir "$REQ_DIR" ;; esac
    df -P -m 2>/dev/null | awk 'NR>1 {print $6}' | while IFS= read -r d; do
        cleanup_one_dir "$d"
    done
}

if [ "$ARG" = "cleanup" ] || [ "$REQ_DIR" = "cleanup" ]; then
    cleanup_leftovers
    echo "CLEANUP_DONE=1"
    echo "NOTE=已清理测速临时文件；未执行写入/读取测试。"
    exit 0
fi

case "$ARG" in
    quick) SIZE=128 ;;
    standard) SIZE=512 ;;
    deep) SIZE=1024 ;;
    ''|*[!0-9]*) SIZE=512 ;;
    *) SIZE="$ARG" ;;
esac
[ "$SIZE" -lt 1 ] && SIZE=1
[ "$SIZE" -gt "$MAX_SIZE_MB" ] && SIZE="$MAX_SIZE_MB"

is_mmc_path() { case "$1" in /dev/mmcblk*|/dev/root) return 0 ;; esac; return 1; }

pick_test_parent() {
    if [ "$REQ_DIR" != "auto" ] && [ -n "$REQ_DIR" ]; then
        case "$REQ_DIR" in
            /*) [ -d "$REQ_DIR" ] && [ -w "$REQ_DIR" ] && { echo "$REQ_DIR"; return 0; } ;;
        esac
    fi
    df -P -m 2>/dev/null | awk 'NR>1 {print $1"|"$4"|"$6}' | while IFS='|' read dev free mp; do
        [ -n "$mp" ] || continue
        [ -d "$mp" ] || continue
        [ -w "$mp" ] || continue
        case "$mp" in /tmp|/dev|/proc|/sys|/run|/var/lock|/rom) continue ;; esac
        is_mmc_path "$dev" || continue
        echo "$free $mp"
    done | sort -n | tail -n 1 | awk '{print $2}'
}

free_mb_path() { df -m "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }
mount_dev() { df -P "$TEST_PARENT" 2>/dev/null | awk 'NR==2 {print $1}'; }
now_cs() { if [ -r /proc/uptime ]; then awk '{printf "%d", $1*100}' /proc/uptime; else date +%s | awk '{print $1*100}'; fi; }
mbps() { mb="$1"; cs="$2"; [ "$cs" -le 0 ] && cs=1; awk -v m="$mb" -v c="$cs" 'BEGIN{printf "%.1f", (m*100)/c}'; }
try_drop_cache() { sync; if [ -w /proc/sys/vm/drop_caches ]; then echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && { echo 1; return; }; fi; echo 0; }

TEST_PARENT="$(pick_test_parent)"
if [ -z "$TEST_PARENT" ]; then
    echo "ERROR=no_writable_emmc_mount"
    echo "HINT=没有找到可写且设备名为 /dev/mmcblk* 的挂载点；避免误测 /tmp 内存盘。"
    echo "SPEED_TEST_DONE=0"
    exit 1
fi

cleanup_leftovers
TEST_DIR="${TEST_PARENT%/}/route-tool-speed-$$"
if ! mkdir -p "$TEST_DIR" 2>/dev/null; then
    echo "ERROR=cannot_create_test_dir"
    echo "SPEED_PARENT=$TEST_PARENT"
    echo "SPEED_TEST_DONE=0"
    exit 1
fi
TEST_FILE="$TEST_DIR/seq.dat"
TMP_COPY="/tmp/route-tool-speed-read-$$.dat"
cleanup() { rm -f "$TEST_FILE" "$TMP_COPY" 2>/dev/null; rmdir "$TEST_DIR" 2>/dev/null; }
trap cleanup EXIT HUP INT TERM

EMMC_FREE_MB="$(free_mb_path "$TEST_PARENT")"
TMP_FREE_MB="$(free_mb_path /tmp)"
case "$EMMC_FREE_MB" in ''|*[!0-9]*) EMMC_FREE_MB=0 ;; esac
case "$TMP_FREE_MB" in ''|*[!0-9]*) TMP_FREE_MB=0 ;; esac
EMMC_SAFE=$((EMMC_FREE_MB - MIN_EMMC_KEEP_MB))
TMP_SAFE=$((TMP_FREE_MB - MIN_TMP_KEEP_MB))
[ "$EMMC_SAFE" -lt 0 ] && EMMC_SAFE=0
[ "$TMP_SAFE" -lt 0 ] && TMP_SAFE=0
if [ "$EMMC_SAFE" -lt 1 ]; then
    echo "ERROR=not_enough_free_space"
    echo "SPEED_PARENT=$TEST_PARENT"
    echo "SPEED_DEV=$(mount_dev)"
    echo "EMMC_FREE_MB=$EMMC_FREE_MB"
    echo "MIN_EMMC_KEEP_MB=$MIN_EMMC_KEEP_MB"
    echo "SPEED_TEST_DONE=0"
    exit 1
fi
SIZE_LIMIT_BY="emmc_free-${MIN_EMMC_KEEP_MB}"
if [ "$SIZE" -gt "$EMMC_SAFE" ]; then
    SIZE="$EMMC_SAFE"
    echo "WARN=size_reduced_to_emmc_free"
fi
READ_TARGET="/tmp"
if [ "$TMP_SAFE" -ge 16 ]; then
    if [ "$SIZE" -gt "$TMP_SAFE" ]; then
        SIZE="$TMP_SAFE"
        SIZE_LIMIT_BY="emmc_and_tmp_free"
        echo "WARN=size_reduced_to_tmp_free"
    fi
else
    READ_TARGET="/dev/null"
    SIZE_LIMIT_BY="emmc_free-${MIN_EMMC_KEEP_MB};tmp_fallback_devnull"
    echo "WARN=tmp_space_low_read_to_devnull"
fi
[ "$SIZE" -lt 1 ] && SIZE=1

SPEED_DEV="$(mount_dev)"
echo "SPEED_TEST_START=${SIZE}MB"
echo "SPEED_PARENT=${TEST_PARENT}"
echo "SPEED_DIR=${TEST_DIR}"
echo "SPEED_DEV=${SPEED_DEV}"
echo "SPEED_METHOD=write_emmc_then_copy_to_tmp_or_devnull"
echo "EMMC_FREE_MB_BEFORE=${EMMC_FREE_MB}"
echo "TMP_FREE_MB_BEFORE=${TMP_FREE_MB}"
echo "MIN_EMMC_KEEP_MB=${MIN_EMMC_KEEP_MB}"
echo "MIN_TMP_KEEP_MB=${MIN_TMP_KEEP_MB}"
echo "SIZE_LIMIT_BY=${SIZE_LIMIT_BY}"

# Sequential write: /dev/zero -> eMMC file.
sync
START=$(now_cs)
dd if=/dev/zero of="$TEST_FILE" bs=1M count="$SIZE" conv=fsync 2>/dev/null
WRITE_RC=$?
sync
WRITE_END=$(now_cs)
WRITE_CS=$((WRITE_END - START)); [ "$WRITE_CS" -le 0 ] && WRITE_CS=1
if [ "$WRITE_RC" -eq 0 ]; then WRITE_SPEED="$(mbps "$SIZE" "$WRITE_CS")"; else WRITE_SPEED="0"; fi

echo "SEQ_WRITE_SPEED=${WRITE_SPEED}"
echo "SEQ_WRITE_TIME_CS=${WRITE_CS}"
echo "SEQ_WRITE_SIZE=${SIZE}"
echo "SEQ_WRITE_RC=${WRITE_RC}"
if [ "$WRITE_RC" -ne 0 ] || [ ! -s "$TEST_FILE" ]; then
    echo "ERROR=seq_write_failed"
    echo "SPEED_TEST_DONE=0"
    exit 1
fi

# Sequential read: eMMC file -> /tmp when safe, otherwise /dev/null.
DROP_CACHE="$(try_drop_cache)"
START=$(now_cs)
if [ "$READ_TARGET" = "/tmp" ]; then
    dd if="$TEST_FILE" of="$TMP_COPY" bs=1M count="$SIZE" conv=fsync 2>/dev/null
else
    dd if="$TEST_FILE" of=/dev/null bs=1M count="$SIZE" 2>/dev/null
fi
READ_RC=$?
READ_END=$(now_cs)
READ_CS=$((READ_END - START)); [ "$READ_CS" -le 0 ] && READ_CS=1
if [ "$READ_RC" -eq 0 ]; then READ_SPEED="$(mbps "$SIZE" "$READ_CS")"; else READ_SPEED="0"; fi

echo "SEQ_READ_SPEED=${READ_SPEED}"
echo "SEQ_READ_TIME_CS=${READ_CS}"
echo "SEQ_READ_SIZE=${SIZE}"
echo "SEQ_READ_RC=${READ_RC}"
echo "READ_TARGET=${READ_TARGET}"
echo "DROP_CACHE=${DROP_CACHE}"

cleanup
trap - EXIT HUP INT TERM
EMMC_FREE_AFTER="$(free_mb_path "$TEST_PARENT")"
TMP_FREE_AFTER="$(free_mb_path /tmp)"
echo "EMMC_FREE_MB_AFTER=${EMMC_FREE_AFTER}"
echo "TMP_FREE_MB_AFTER=${TMP_FREE_AFTER}"
echo "CLEANUP_DONE=1"
echo "SPEED_TEST_DONE=1"

# ── eMMC 诊断信息（测速同时采集）──
MMC_SYS=""
for d in /sys/class/mmc_host/mmc*/mmc*:*; do
    [ -d "$d" ] && { MMC_SYS="$d"; break; }
done

if [ -n "$MMC_SYS" ]; then
    # CID
    CID_RAW="$(cat "$MMC_SYS/cid" 2>/dev/null | tr -d '\n ')"
    [ -n "$CID_RAW" ] && echo "EMMC_CID=$CID_RAW"

    # Manufacturer from CID first byte
    MANFID="$(printf '%s' "$CID_RAW" | cut -c1-2)"
    PRDCT_HEX="$(printf '%s' "$CID_RAW" | cut -c7-18)"
    SCRIPT_DIR="${0%/*}"; [ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR="."
    . "$SCRIPT_DIR/storage_common.sh"
    # 与 storage_health.sh 保持一致: 按 MID+PNM 精确识别, 不走 MID 兜底
    echo "EMMC_MANUFACTURER=$(rt_emmc_chip_name "$MANFID" "$PRDCT_HEX")"

    # BOOT1/BOOT2 size from ext_csd bytes 226/227 (unit: 128KB)
    EXT_CSD="$(rt_read_ext_csd 300 2>/dev/null || true)"
    if [ -n "$EXT_CSD" ]; then
        BOOT1_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 226)"
        BOOT2_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 227)"
        BOOT1_KB=$(( $(rt_hex2dec "$BOOT1_HEX") * 128 ))
        BOOT2_KB=$(( $(rt_hex2dec "$BOOT2_HEX") * 128 ))
        echo "EMMC_BOOT1_SIZE_KB=$BOOT1_KB"
        echo "EMMC_BOOT2_SIZE_KB=$BOOT2_KB"

        # RPMB size (byte 222, unit: 128KB)
        RPMB_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 222)"
        RPMB_KB=$(( $(rt_hex2dec "$RPMB_HEX") * 128 ))
        echo "EMMC_RPMB_SIZE_KB=$RPMB_KB"

        # eMMC version (byte 192)
        VER_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 192)"
        VER_DEC="$(rt_hex2dec "$VER_HEX")"
        case "$VER_DEC" in
            0) VER_TXT="4.0" ;; 1) VER_TXT="4.1" ;;
            2) VER_TXT="4.2" ;; 3) VER_TXT="4.3" ;;
            4) VER_TXT="4.4" ;; 5) VER_TXT="4.41" ;;
            6) VER_TXT="4.5" ;; 7) VER_TXT="5.0" ;;
            8) VER_TXT="5.01" ;; 9) VER_TXT="5.1" ;;
            10) VER_TXT="5.1B" ;; *) VER_TXT="未知(0x$VER_HEX)" ;;
        esac
        echo "EMMC_VERSION=$VER_TXT"
        echo "EMMC_VERSION_RAW=0x$VER_HEX"
    fi
fi
