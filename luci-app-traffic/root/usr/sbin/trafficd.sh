#!/bin/sh
# trafficd.sh - WAN traffic collector for luci-app-traffic
# Data format (CSV):
#   ts,dn_rate,up_rate,dn_bytes,up_bytes[,dn_peak,up_peak]
#   第 6/7 字段 = 该周期内「最高的 1 秒速率」(B/s)，用于"峰值"卡片；
#   老格式（5 字段）没有这两列，读取时退回用第 2/3 字段。
#   L1: 1s     x 180  -> 3 min   (tmpfs)
#   L2: 60s    x 60   -> 1 hour  (tmpfs)
#   L3: 60s    x 4320 -> 3 days  (flash)   <- 每分钟一条（断电最多丢 1 分钟）
#     保留 3 天是为了「1天」视图能左右切到今天/昨天/前天
#   L4: 1d     x 62   -> 62 days (flash)   <- 每跨过一天写入一条
#   L5: monthly, never pruned    (flash)
#
# 关键点：L3/L4 由「真实时刻边界」触发，而不是靠进程自己数秒，
#         因此守护进程重启不会打乱记录节奏、也不必从头攒满 1 小时。

DIR_TMP=/tmp/traffic
DIR_FLASH=/etc/traffic
IFACE=${IFACE:-wan}

L1_KEEP=180
L2_KEEP=60
L3_KEEP=4320          # 3 天 × 1440 分钟
L3_SLACK=1440         # 允许再攒 1 天才裁剪，避免频繁重写整个文件（省 flash）
L4_KEEP=62

mkdir -p "$DIR_TMP" "$DIR_FLASH"
for f in l1 l2; do [ -f "$DIR_TMP/$f.dat" ] || : > "$DIR_TMP/$f.dat"; done
for f in l3 l4 l5; do [ -f "$DIR_FLASH/$f.dat" ] || : > "$DIR_FLASH/$f.dat"; done

# 统计划分的时区：优先读 UCI 配置，未配置则跟随系统。
# 该时区只影响"整点/跨天/月份"的判定，不影响存储的 unix 时间戳。
STAT_TZ=$(uci -q get traffic.main.timezone)
if [ -n "$STAT_TZ" ]; then
  export TZ="$STAT_TZ"
fi

read_counters() {
  awk -v a="$IFACE:" '$1==a {print $2, $10}' /proc/net/dev
}

# agg <src> <dst> <take> <keep> <div>
# 取 src 末尾 take 行聚合为一条写入 dst（分钟级 l1->l2 用）
# 第 6/7 字段记录本周期内「最高的 1 秒速率」：l1 本身是 1s 采样，直接取最大值
agg() {
  tail -n "$3" "$1" | awk -F, -v d="${5:-1}" '
    { sd+=$2; su+=$3; ts=$1; db=$4; ub=$5
      if ($2 > mxd) mxd = $2
      if ($3 > mxu) mxu = $3
      c++ }
    END {
      if (c==0) exit
      printf "%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f\n", ts, sd/c, su/c, db/d, ub/d, mxd, mxu
    }' >> "$2"

  cnt=$(wc -l < "$2")
  if [ "$cnt" -gt $(( $4 + 16 )) ]; then
    tail -n "$4" "$2" > "$2.tmp" && mv "$2.tmp" "$2"
  fi
}

# agg_window <src> <dst> <window_sec> <keep> <div>
# 只取时间戳落在最近 window_sec 内的行聚合为一条写入 dst。
# 用时间窗而非 tail -n N，是为了排除重启前残留的过期行，避免污染平均值。
agg_window() {
  now=$(date +%s)
  from=$((now - $3))
  awk -F, -v s="$from" -v d="${5:-1}" '
    $1 >= s { sd+=$2; su+=$3; ts=$1; db=$4; ub=$5
      # 峰值透传：子行若带第 6/7 字段就用它（该分钟的 1s 峰值），老格式退回均值
      pd = (NF >= 7) ? $6 : $2
      pu = (NF >= 7) ? $7 : $3
      if (pd > mxd) mxd = pd
      if (pu > mxu) mxu = pu
      c++ }
    END {
      if (c==0) exit
      printf "%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f\n", ts-1, sd/c, su/c, db/d, ub/d, mxd, mxu
    }' "$1" >> "$2"

  cnt=$(wc -l < "$2")
  if [ "$cnt" -gt $(( $4 + 16 )) ]; then
    tail -n "$4" "$2" > "$2.tmp" && mv "$2.tmp" "$2"
  fi
}

# agg_window_delta <src> <dst> <window_sec> <keep> <div>
# 与 agg_window 相同取窗口内数据，但字节字段写入「窗口期内的增量」= 末值 - 首值。
# 这样每条记录自带当期流量，前端无需依赖前一条记录做差，单条也能正确显示。
agg_window_delta() {
  now=$(date +%s)
  from=$((now - $3))
  awk -F, -v s="$from" -v d="${5:-1}" '
    $1 >= s {
      if (first == 0) { pdb=$4; pub=$5; first=1 }
      else {
        # 接口计数器可能因重连/重启归零：回绕时按"当前值"算，而不是算成负数
        tdn += ($4 >= pdb) ? ($4 - pdb) : $4
        tup += ($5 >= pub) ? ($5 - pub) : $5
        pdb=$4; pub=$5
      }
      sdn+=$2; sup+=$3
      pd = (NF >= 7) ? $6 : $2
      pu = (NF >= 7) ? $7 : $3
      if (pd > mxd) mxd = pd
      if (pu > mxu) mxu = pu
      lts=$1; c++
    }
    END {
      if (c == 0) exit
      printf "%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f\n", lts-1, sdn/c, sup/c, tdn/d, tup/d, mxd, mxu
    }' "$1" >> "$2"

  cnt=$(wc -l < "$2")
  if [ "$cnt" -gt $(( $4 + 16 )) ]; then
    tail -n "$4" "$2" > "$2.tmp" && mv "$2.tmp" "$2"
  fi
}

# Aggregate previous month into l5 (kept forever)
# l4 每行已是「当天增量」，故按月直接求和即可
agg_month() {
  m=$1
  y=${m%%-*}
  mo=${m##*-}
  start=$(date -d "$y-$mo-01 00:00:00" +%s)
  if [ "$mo" = "12" ]; then
    ny=$((y + 1)); nmo=01
  else
    ny=$y; nmo=$(printf "%02d" $(( $mo + 1 )))
  fi
  end=$(date -d "$ny-$nmo-01 00:00:00" +%s)

  awk -F, -v s="$start" -v e="$end" '
    $1 >= s && $1 < e {
      sdb += $4; sup2 += $5
      if ($1 > lts) lts = $1
      n++
    }
    END {
      if (n == 0) exit
      printf "%.0f,0,0,%.0f,%.0f\n", lts, sdb, sup2
    }' "$DIR_FLASH/l4.dat" >> "$DIR_FLASH/l5.dat"

  logger -t trafficd "month $m aggregated into l5"
}

check_month() {
  now_m=$(date +%Y-%m)
  last_m=$(cat "$DIR_FLASH/.last_month" 2>/dev/null)
  if [ -z "$last_m" ]; then
    echo "$now_m" > "$DIR_FLASH/.last_month"
    return
  fi
  if [ "$now_m" != "$last_m" ]; then
    agg_month "$last_m"
    echo "$now_m" > "$DIR_FLASH/.last_month"
  fi
}

prev=$(read_counters)
prev_ts=$(date +%s)
c1=0

# 边界跟踪：初始化为当前值，避免启动时误写一条
LAST_DAY=$(date +%Y%m%d)

logger -t trafficd "started (iface=$IFACE tz=${STAT_TZ:-system})"

check_month

while true; do
  sleep 1

  cur=$(read_counters)
  now=$(date +%s)
  dt=$((now - prev_ts))
  if [ "$dt" -le 0 ]; then
    continue
  fi

  set -- $prev
  prx=$1; ptx=$2
  set -- $cur
  crx=$1; ctx=$2

  drx=$(( (crx - prx) / dt ))
  dtx=$(( (ctx - ptx) / dt ))
  [ "$drx" -lt 0 ] && drx=0
  [ "$dtx" -lt 0 ] && dtx=0

  echo "$now,$drx,$dtx,$crx,$ctx" >> "$DIR_TMP/l1.dat"
  tail -n "$L1_KEEP" "$DIR_TMP/l1.dat" > "$DIR_TMP/l1.tmp" && mv "$DIR_TMP/l1.tmp" "$DIR_TMP/l1.dat"

  # ---- L1 -> L2：每 60 秒一条分钟记录（易失层，无需边界对齐）----
  c1=$((c1 + 1))
  if [ "$c1" -ge 60 ]; then
    c1=0
    agg "$DIR_TMP/l1.dat" "$DIR_TMP/l2.dat" 60 "$L2_KEEP" 1

    # ---- 同时把这一分钟落盘到 L3（flash）----
    # 这样断电最多丢 1 分钟，而不是整整 1 小时。
    # L3 存「累计字节」，日档靠相邻差值算量，所以直接镜像 l2 的最后一行即可。
    tail -n 1 "$DIR_TMP/l2.dat" >> "$DIR_FLASH/l3.dat"
    cnt3=$(wc -l < "$DIR_FLASH/l3.dat")
    if [ "$cnt3" -gt $((L3_KEEP + L3_SLACK)) ]; then
      tail -n "$L3_KEEP" "$DIR_FLASH/l3.dat" > "$DIR_FLASH/l3.dat.tmp" \
        && mv "$DIR_FLASH/l3.dat.tmp" "$DIR_FLASH/l3.dat"
    fi
  fi

  # ---- L3 -> L4：跨过一天触发 ----
  CUR_DAY=$(date +%Y%m%d)
  if [ "$CUR_DAY" != "$LAST_DAY" ]; then
    # L3 是字节，L4 统一存 MB，所以这里除以 1048576
    agg_window_delta "$DIR_FLASH/l3.dat" "$DIR_FLASH/l4.dat" 86400 "$L4_KEEP" 1048576
    LAST_DAY=$CUR_DAY
    logger -t trafficd "day boundary -> L4 record appended"
    check_month
  fi

  prev=$cur
  prev_ts=$now
done
