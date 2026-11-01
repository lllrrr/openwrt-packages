#!/bin/sh
# ============================================================
# traffic-upgrade - luci-app-traffic 安全升级脚本
#
# 五条硬保证（严禁违反，改本脚本亦不得削弱）：
#   1. 绝不删除/截断任何 .dat 数据文件（脚本内不存在针对数据的 rm）
#   2. 升级前把持久层数据快照到 /etc/traffic/.backup/<时间戳>，自动保留最近 3 份
#      （易失层 l1/l2 是 tmpfs 滚动缓冲，丢失后数分钟自愈，不备份以免白白消耗 flash 写入；
#        且数据未变化时直接复用旧快照，不重复落盘）
#   3. 数据格式版本不符时直接中止并要求迁移，禁止静默清空
#   4. 升级前后比对持久层行数，任何减少立即从快照还原数据
#   5. 仅当采集守护进程自身代码变更时才重启它，避免无谓重置聚合计数器
#
# 用法: traffic-upgrade <解压目录> [--dry-run]
# ============================================================

FMT_VERSION=1
SNAP_ROOT=/etc/traffic/.backup
KEEP_SNAP=3

# 持久层：行数只增不减，重点校验对象
PERSIST="/etc/traffic/l3.dat /etc/traffic/l4.dat /etc/traffic/l5.dat /etc/traffic/.last_month"
# 易失层：tmpfs 滚动缓冲，重启即失效，只做存在性检查
VOLATILE="/tmp/traffic/l1.dat /tmp/traffic/l2.dat"

CODE="/usr/sbin/trafficd.sh
/etc/init.d/trafficd
/www/cgi-bin/traffic
/www/traffic/index.html
/usr/share/luci/menu.d/luci-app-traffic.json
/usr/share/rpcd/acl.d/luci-app-traffic.json
/www/luci-static/resources/view/traffic/main.js"

SRC=""
DRY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        -*) echo "unknown option: $a"; exit 1 ;;
        *) [ -z "$SRC" ] && SRC="$a" ;;
    esac
done

if [ -z "$SRC" ]; then
    echo "usage: traffic-upgrade <extracted-dir> [--dry-run]"
    exit 1
fi
if [ ! -d "$SRC" ]; then
    echo "ERROR: source dir not found: $SRC"
    exit 1
fi

HAVE_MD5=0
command -v md5sum >/dev/null 2>&1 && HAVE_MD5=1

# 输出: "<行数>"  用于持久层行数统计
lines_of() {
    if [ -f "$1" ]; then wc -l < "$1" 2>/dev/null; else echo 0; fi
}

# 快照文件名去斜杠
base_of() {
    echo "$1" | sed 's#.*/##'
}

echo "=== 1/6 升级前数据指纹 ==="
BEFORE=0
for f in $PERSIST; do
    n=$(lines_of "$f")
    BEFORE=$((BEFORE + n))
    printf '  %-32s %s lines\n' "$f" "$n"
done
echo "  --------------------------------"
echo "  持久层总行数: $BEFORE"

echo "=== 2/6 数据格式版本校验 ==="
CUR_FMT=$(cat /etc/traffic/.fmtver 2>/dev/null)
if [ -z "$CUR_FMT" ]; then
    echo "  未发现格式版本标记，按当前版本 $FMT_VERSION 记录（不清数据）"
    [ "$DRY" = "1" ] || echo "$FMT_VERSION" > /etc/traffic/.fmtver
elif [ "$CUR_FMT" != "$FMT_VERSION" ]; then
    echo "  !! 数据格式版本不匹配: 现有=$CUR_FMT 本程序期望=$FMT_VERSION"
    echo "  !! 已中止，未做任何改动。请编写迁移脚本后再升级，禁止清空数据。"
    exit 1
else
    echo "  格式版本一致: $CUR_FMT"
fi

echo "=== 3/6 数据快照备份（仅持久层，易失层不备份）==="
STAMP=$(date +%Y%m%d-%H%M%S)
SNAP="$SNAP_ROOT/$STAMP"
if [ "$DRY" = "1" ]; then
    echo "  [dry-run] 将在 $SNAP 建立快照"
else
    # 若持久层数据与最新快照完全一致，则复用该快照，不重复写 flash
    NEWEST=$(ls -1d "$SNAP_ROOT"/*/ 2>/dev/null | sort | tail -1)
    NEWEST=${NEWEST%/}
    SNAP_NEEDED=1
    if [ -n "$NEWEST" ] && [ -d "$NEWEST" ]; then
        SAME=1
        for f in $PERSIST; do
            b=$(base_of "$f")
            if [ -f "$f" ] && [ -f "$NEWEST/$b" ]; then
                if [ "$HAVE_MD5" = "1" ]; then
                    ma=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
                    mb=$(md5sum "$NEWEST/$b" 2>/dev/null | awk '{print $1}')
                else
                    ma=$(wc -c < "$f" 2>/dev/null)
                    mb=$(wc -c < "$NEWEST/$b" 2>/dev/null)
                fi
                [ "$ma" != "$mb" ] && SAME=0
            else
                SAME=0
            fi
        done
        if [ "$SAME" = "1" ]; then
            SNAP_NEEDED=0
            SNAP="$NEWEST"
            echo "  数据与最新快照一致，复用: $SNAP（避免重复写入 flash）"
        fi
    fi

    if [ "$SNAP_NEEDED" = "1" ]; then
        mkdir -p "$SNAP"
        # 只快照持久层；易失层 l1/l2 是 tmpfs 滚动缓冲，丢失后数分钟内自愈，备份无意义且白白写 flash
        for f in $PERSIST; do
            [ -f "$f" ] && cp "$f" "$SNAP/$(base_of "$f")" 2>/dev/null
        done
        echo "  快照已保存: $SNAP"
        # 仅保留最近 KEEP_SNAP 份
        ls -1 "$SNAP_ROOT" 2>/dev/null | sort -r | tail -n +$((KEEP_SNAP + 1)) | while read -r d; do
            rm -rf "$SNAP_ROOT/$d"
        done
    fi
fi

echo "=== 4/6 备份并覆盖代码（绝不触碰 .dat）==="
BACKUP=/tmp/traffic-codebak-$$
mkdir -p "$BACKUP"
CHANGED_DAEMON=0
CHANGED_ANY=0

for f in $CODE; do
    if [ ! -f "$SRC$f" ]; then
        continue
    fi
    if [ -f "$f" ]; then
        mkdir -p "$BACKUP$(dirname "$f")"
        cp "$f" "$BACKUP$f"
        if [ "$HAVE_MD5" = "1" ]; then
            om=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
            nm=$(md5sum "$SRC$f" 2>/dev/null | awk '{print $1}')
        else
            om=$(wc -c < "$f" 2>/dev/null)
            nm=$(wc -c < "$SRC$f" 2>/dev/null)
        fi
        if [ "$om" = "$nm" ]; then
            echo "  无变化   $f"
            continue
        fi
    fi
    CHANGED_ANY=1
    case "$f" in
        /usr/sbin/trafficd.sh|/etc/init.d/trafficd) CHANGED_DAEMON=1 ;;
    esac
    if [ "$DRY" = "1" ]; then
        echo "  [dry-run] 将更新 $f"
    else
        cp "$SRC$f" "$f" || { echo "  !! 写入失败: $f"; }
        echo "  已更新   $f"
    fi
done
[ "$CHANGED_ANY" = "0" ] && echo "  （所有代码均与现网一致，无需覆盖）"

[ -f /usr/sbin/trafficd.sh ] && chmod 755 /usr/sbin/trafficd.sh
[ -f /etc/init.d/trafficd ] && chmod 755 /etc/init.d/trafficd
[ -f /www/cgi-bin/traffic ] && chmod 755 /www/cgi-bin/traffic
[ -f /www/traffic/index.html ] && chmod 644 /www/traffic/index.html

echo "=== 5/6 服务处理 ==="
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
rm -f /tmp/luci-indexcache.*.json
if [ "$CHANGED_DAEMON" = "1" ]; then
    echo "  采集守护进程代码已变更 -> 重启 trafficd"
    [ "$DRY" = "1" ] || /etc/init.d/trafficd restart >/dev/null 2>&1
else
    echo "  采集守护进程代码未变 -> 不重启，保留聚合计数器（不影响 L3/L4 累积）"
fi
if [ "$DRY" = "1" ]; then
    echo "  [dry-run] 将重启 rpcd/uhttpd 并清 LuCI 缓存"
else
    /etc/init.d/rpcd restart >/dev/null 2>&1
    /etc/init.d/uhttpd restart >/dev/null 2>&1
    sleep 2
fi

if [ "$DRY" = "1" ]; then
    echo "=== dry-run 结束，未做任何实际修改 ==="
    rm -rf "$BACKUP"
    exit 0
fi

echo "=== 6/6 数据完整性校验 ==="
AFTER=0
for f in $PERSIST; do
    n=$(lines_of "$f")
    AFTER=$((AFTER + n))
    printf '  %-32s %s lines\n' "$f" "$n"
done
echo "  --------------------------------"
echo "  持久层总行数: $BEFORE -> $AFTER"

restore_data() {
    echo "  !! 正在从快照还原数据: $SNAP"
    for f in $PERSIST; do
        b=$(base_of "$f")
        [ -f "$SNAP/$b" ] && cp "$SNAP/$b" "$f" 2>/dev/null
    done
}

if [ "$AFTER" -lt "$BEFORE" ]; then
    echo "  !! 检测到数据行数减少，判定为数据丢失 -> 回滚数据与代码"
    restore_data
    for f in $CODE; do
        [ -f "$BACKUP$f" ] && cp "$BACKUP$f" "$f"
    done
    /etc/init.d/trafficd restart >/dev/null 2>&1
    echo "  已回滚。请检查上述步骤。"
    rm -rf "$BACKUP"
    exit 1
fi

echo "$FMT_VERSION" > /etc/traffic/.fmtver
rm -rf "$BACKUP"
echo "升级完成，数据完好未动（$BEFORE -> $AFTER 行）"
