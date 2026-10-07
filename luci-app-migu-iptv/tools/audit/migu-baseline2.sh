#!/bin/sh
# migu-baseline2.sh — 严谨基线：真实 pid、清缓存重启、冷/热/连点
echo "=== restart service to clear in-memory caches ==="
/etc/init.d/migu restart >/dev/null 2>&1
sleep 3
curl -s -o /dev/null http://127.0.0.1:8788/m3u
PIDS=$(curl -s http://127.0.0.1:8788/m3u | grep -o 'ch/[0-9]*' | head -6 | cut -d/ -f2)
echo "PIDS: $PIDS"
echo ""
echo "=== COLD rounds (restart between rounds) ==="
for r in 1 2 3; do
  for p in $PIDS; do
    curl -s -o /dev/null -w "r$r pid=$p code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total}\n" --max-time 15 "http://127.0.0.1:8788/ch/$p"
  done
  /etc/init.d/migu restart >/dev/null 2>&1
  sleep 3
  curl -s -o /dev/null http://127.0.0.1:8788/m3u
done
echo ""
echo "=== WARM (same pids again, cache hit) ==="
for p in $PIDS; do
  curl -s -o /dev/null -w "warm pid=$p code=%{http_code} ttfb=%{time_starttransfer}\n" --max-time 15 "http://127.0.0.1:8788/ch/$p"
done
echo ""
echo "=== RAPID ZAP x5 first pid ==="
FIRST=$(echo $PIDS | cut -d' ' -f1)
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "zap$i pid=$FIRST ttfb=%{time_starttransfer}\n" --max-time 10 "http://127.0.0.1:8788/ch/$FIRST"
done
echo ""
echo "=== INVALID pid (negative path cost) ==="
for i in 1 2; do
  curl -s -o /dev/null -w "invalid$i code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total}\n" --max-time 20 "http://127.0.0.1:8788/ch/99999999"
done
echo ""
echo "=== /m3u + /txt + /health ==="
curl -s -o /dev/null -w "/m3u code=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer}\n" --max-time 10 http://127.0.0.1:8788/m3u
curl -s -o /dev/null -w "/health code=%{http_code} ttfb=%{time_starttransfer}\n" --max-time 10 http://127.0.0.1:8788/health
curl -s http://127.0.0.1:8788/health
echo ""
echo "=== process state ==="
PID=$(pgrep -f 'ucode /usr/share/ucode/migu.uc' | head -1)
echo "pid=$PID fds=$(ls /proc/$PID/fd 2>/dev/null | wc -l)"
grep -E "VmRSS|VmSize" /proc/$PID/status
echo ""
echo "=== migu log tail ==="
logread | grep migu | tail -5
