#!/bin/sh
# 1.4.0 最终端到端验收
P=$(pgrep -f 'migu.uc' | head -1)
echo "=== 进程 pid=$P ==="
echo "--- VmRSS / Threads / fd ---"
grep -E 'VmRSS|Threads' /proc/$P/status
echo "fd 数量: $(ls -l /proc/$P/fd 2>/dev/null | wc -l)"

echo
echo "=== 播放链路（302 -> 索引 -> 分片）==="
LOC=$(curl -s -D - -o /dev/null http://127.0.0.1:8788/ch/608807420 | sed -n 's/^[Ll]ocation: //p' | tr -d '\r')
echo "302 Location 主机: $(echo "$LOC" | sed 's#http://##;s#/.*##')"
echo "$LOC" | grep -q 'client_ip=' && echo "client_ip 参数: 有"

echo "--- 拉取索引内容 ---"
curl -s -L -m 20 "$LOC" -o /tmp/idx.m3u8 -w 'index code=%{http_code} bytes=%{size_download} time=%{time_total}s\n'
head -c 200 /tmp/idx.m3u8; echo
echo "EXTINF 条数: $(grep -c '^#EXTINF' /tmp/idx.m3u8)"

echo "--- 拉取首个分片 ---"
SEG=$(grep -v '^#' /tmp/idx.m3u8 | head -1)
case "$SEG" in
  http*) SURL="$SEG" ;;
  *)     SURL="$(echo "$LOC" | sed 's#/[^/]*$#/#' )$SEG" ;;
esac
echo "分片 URL 前缀: $(echo "$SURL" | cut -c1-60)..."
curl -s -L -m 20 -r 0-400000 "$SURL" -o /tmp/seg.bin -w 'seg code=%{http_code} bytes=%{size_download} time=%{time_total}s\n'
echo "分片首 16 字节:"
hexdump -C -n 16 /tmp/seg.bin 2>/dev/null || busybox hexdump -C -n 16 /tmp/seg.bin 2>/dev/null || echo "(无 hexdump)"

echo
echo "=== 冷/热切换耗时（3 个不同频道）==="
for pid in 608807420 641886683 608807419; do
  C=$(curl -s -o /dev/null -w '%{time_total}' http://127.0.0.1:8788/ch/$pid)
  H=$(curl -s -o /dev/null -w '%{time_total}' http://127.0.0.1:8788/ch/$pid)
  echo "pid=$pid 冷=${C}s 热=${H}s"
done

echo
echo "=== 降级链（CCTV5 无信号时回落 CCTV5+）==="
curl -s -o /dev/null -w 'ch/641886683 code=%{http_code} time=%{time_total}s\n' http://127.0.0.1:8788/ch/641886683
curl -s http://127.0.0.1:8788/health | tr ',' '\n' | grep -E 'chFallback|streamCacheOk|streamCacheFail|avgResolveMs'

echo
echo "=== 内存是否随请求增长（100 次请求前后）==="
B=$(grep VmRSS /proc/$P/status | awk '{print $2}')
for i in $(seq 1 100); do curl -s -o /dev/null http://127.0.0.1:8788/ch/608807420; done
A=$(grep VmRSS /proc/$P/status | awk '{print $2}')
echo "请求前 VmRSS=${B}kB  请求后 VmRSS=${A}kB  差值=$((A-B))kB"
echo "fd 数量: $(ls -l /proc/$P/fd 2>/dev/null | wc -l)"
curl -s http://127.0.0.1:8788/health | tr ',' '\n' | grep -E 'activeConns|requests'
