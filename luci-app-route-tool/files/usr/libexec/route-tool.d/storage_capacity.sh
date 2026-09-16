#!/bin/sh
# Storage capacity summary for Route Tool
# BusyBox compatible: reports ROM/overlay/root/eMMC data mount and USB/other /mnt mounts.

fmt_df_line() {
    key="$1"; path="$2"; label="$3"
    [ -e "$path" ] || return
    line="$(df -P -m "$path" 2>/dev/null | awk 'NR==2 {print $1"|"$2"|"$3"|"$4"|"$5"|"$6}')"
    [ -n "$line" ] || return
    IFS='|' read dev total used free pct mp <<EOF
$line
EOF
    echo "${key}_LABEL=$label"
    echo "${key}_DEV=$dev"
    echo "${key}_MOUNT=$mp"
    echo "${key}_TOTAL_MB=$total"
    echo "${key}_USED_MB=$used"
    echo "${key}_FREE_MB=$free"
    echo "${key}_USED_PCT=$pct"
}

is_mmc_dev() { case "$1" in /dev/mmcblk*) return 0 ;; esac; return 1; }
is_usb_dev() { case "$1" in /dev/sd*|/dev/hd*) return 0 ;; esac; return 1; }
hex2dec() { printf '%d\n' "0x$1" 2>/dev/null || echo 0; }

find_mmc_block_base() {
    # Pick by sysfs MMC type instead of hardcoding mmcblk0; SD cards usually report type=SD.
    for d in /sys/block/mmcblk*; do
        [ -r "$d/device/type" ] || continue
        [ "$(cat "$d/device/type" 2>/dev/null)" = "MMC" ] || continue
        echo "${d##*/}"
        return 0
    done
    return 1
}

pick_largest_mmc_mount() {
    df -P -m 2>/dev/null | awk 'NR>1 {print $1"|"$2"|"$3"|"$4"|"$5"|"$6}' | while IFS='|' read dev total used free pct mp; do
        [ -n "$mp" ] || continue
        [ -d "$mp" ] || continue
        [ -w "$mp" ] || continue
        case "$mp" in /tmp|/dev|/proc|/sys|/run|/var/lock|/rom) continue ;; esac
        case "$dev" in /dev/mmcblk*) echo "$free|$dev|$total|$used|$pct|$mp" ;; esac
    done | sort -n | tail -n 1
}

EMMC_BASE="$(find_mmc_block_base 2>/dev/null)"

# Storage type
if [ -n "$EMMC_BASE" ]; then
    STORAGE_TYPE="eMMC"
elif grep -q '^mtd[0-9]' /proc/mtd 2>/dev/null; then
    STORAGE_TYPE="NAND"
else
    STORAGE_TYPE="unknown"
fi
echo "STORAGE_TYPE=$STORAGE_TYPE"

fmt_df_line ROOT / "根分区 /"
fmt_df_line ROM /rom "ROM 只读分区"
fmt_df_line OVERLAY /overlay "Overlay 可写分区"

# eMMC total from block device
if [ -n "$EMMC_BASE" ] && [ -r "/sys/block/$EMMC_BASE/size" ]; then
    sec="$(cat "/sys/block/$EMMC_BASE/size" 2>/dev/null)"
    case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
    echo "EMMC_TOTAL_MB=$((sec * 512 / 1024 / 1024))"
fi

mmc="$(pick_largest_mmc_mount)"
if [ -n "$mmc" ]; then
    IFS='|' read free dev total used pct mp <<EOF
$mmc
EOF
    echo "EMMC_DATA_DEV=$dev"
    echo "EMMC_DATA_MOUNT=$mp"
    echo "EMMC_DATA_TOTAL_MB=$total"
    echo "EMMC_DATA_USED_MB=$used"
    echo "EMMC_DATA_FREE_MB=$free"
    echo "EMMC_DATA_USED_PCT=$pct"
    echo "SPEED_TEST_DEV=$dev"
    echo "SPEED_TEST_MOUNT=$mp"
else
    echo "EMMC_DATA_DEV="
    echo "EMMC_DATA_MOUNT="
    echo "EMMC_DATA_TOTAL_MB=0"
    echo "EMMC_DATA_FREE_MB=0"
fi

# Other mounted storage under /mnt, useful for USB disks or manually mounted data partitions.
i=0
df -P -m 2>/dev/null | awk 'NR>1 {print $1"|"$2"|"$3"|"$4"|"$5"|"$6}' | while IFS='|' read dev total used free pct mp; do
    case "$mp" in /mnt/*) ;;
        *) continue ;;
    esac
    [ "$mp" = "${EMMC_DATA_MOUNT:-}" ] && continue
    echo "MOUNT_${i}_DEV=$dev"
    echo "MOUNT_${i}_MOUNT=$mp"
    echo "MOUNT_${i}_TOTAL_MB=$total"
    echo "MOUNT_${i}_USED_MB=$used"
    echo "MOUNT_${i}_FREE_MB=$free"
    echo "MOUNT_${i}_USED_PCT=$pct"
    i=$((i + 1))
done

# NAND total from MTD sizes.
# Some NAND layouts expose both a full-chip/container MTD (for example "ALL"/"spi-nand0")
# and its child partitions in /proc/mtd. Summing every line then double-counts the same flash
# and makes the UI show almost 2x capacity. Prefer the largest near-full container when it
# overlaps the partition sum; otherwise fall back to summing partitions for normal layouts.
if [ -r /proc/mtd ]; then
    nand_sum_mb=0; nand_max_mb=0; nand_count=0; nand_max_name=""
    while read line; do
        case "$line" in mtd*) ;;
            *) continue ;;
        esac
        hex="$(echo "$line" | awk '{print $2}')"
        # Use printf-based hex conversion for old BusyBox ash compatibility.
        case "$hex" in ''|*[!0-9A-Fa-f]*) size=0 ;; *) size="$(hex2dec "$hex")" ;; esac
        name="$(echo "$line" | sed -n 's/.*"\(.*\)".*/\1/p')"
        size_mb=$((size / 1024 / 1024))
        nand_sum_mb=$((nand_sum_mb + size_mb))
        nand_count=$((nand_count + 1))
        if [ "$size_mb" -gt "$nand_max_mb" ]; then
            nand_max_mb="$size_mb"
            nand_max_name="$name"
        fi
    done < /proc/mtd

    # If the largest MTD is roughly the same size as all the remaining MTDs together,
    # it is a full-chip/container entry and the children are overlapping partitions.
    nand_rest_mb=$((nand_sum_mb - nand_max_mb))
    # Avoid 32-bit shell arithmetic overflow by comparing the ratio in awk.
    if [ "$nand_max_mb" -gt 0 ] && [ "$nand_rest_mb" -gt 0 ] && awk -v a="$nand_max_mb" -v b="$nand_rest_mb" 'BEGIN{exit !((a * 100) >= (b * 90))}'; then
        nand_total="$nand_max_mb"
        nand_method="largest_container:${nand_max_name}"
    else
        nand_total="$nand_sum_mb"
        nand_method="sum_partitions"
    fi
    echo "NAND_TOTAL_MB=$nand_total"
    echo "NAND_MTD_COUNT=$nand_count"
    echo "NAND_TOTAL_METHOD=$nand_method"
fi

echo "CAPACITY_DONE=1"
