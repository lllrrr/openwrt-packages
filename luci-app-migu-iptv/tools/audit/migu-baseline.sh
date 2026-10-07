#!/bin/sh
echo "=== ucode digest module test ==="
ucode -e 'import { md5 } from "digest"; print("md5=" + md5("test") + "\n");' 2>&1 | head -3
echo "=== ucode version ==="
ucode -v 2>&1 | head -1
echo "=== openssl / curl present ==="
which openssl curl
echo "=== spawn cost: 10x date ==="
time sh -c 'i=0; while [ $i -lt 10 ]; do date +%Y%m%d >/dev/null; i=$((i+1)); done'
echo "=== spawn cost: 10x openssl md5 ==="
time sh -c 'i=0; while [ $i -lt 10 ]; do printf "%s" abc | openssl dgst -md5 >/dev/null; i=$((i+1)); done'
echo "=== spawn cost: 10x curl localhost /txt ==="
time sh -c 'i=0; while [ $i -lt 10 ]; do curl -s -o /dev/null -m 5 http://127.0.0.1:8788/txt; i=$((i+1)); done'
echo "=== /ch cold resolution (fresh pids) ==="
for pid in 608807420 608807421 608807422; do
  curl -s -o /dev/null -w "cold pid=$pid code=%{http_code} ttfb=%{time_starttransfer}s total=%{time_total}s\n" --max-time 15 "http://127.0.0.1:8788/ch/$pid"
done
echo "=== /ch warm (cache hit, same pids) ==="
for pid in 608807420 608807421 608807422; do
  curl -s -o /dev/null -w "warm pid=$pid code=%{http_code} ttfb=%{time_starttransfer}s total=%{time_total}s\n" --max-time 15 "http://127.0.0.1:8788/ch/$pid"
done
echo "=== 302 response headers ==="
curl -s -D - -o /dev/null --max-time 10 "http://127.0.0.1:8788/ch/608807420" | grep -iE "^(HTTP|Location|X-Migu)"
echo "=== migu process mem/fds ==="
grep -E "VmRSS|VmSize" /proc/4498/status
echo "fds=$(ls /proc/4498/fd | wc -l)"
echo "=== /m3u + /txt size ==="
curl -s -o /dev/null -w "/m3u code=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer}s\n" --max-time 10 http://127.0.0.1:8788/m3u
curl -s -o /dev/null -w "/txt code=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer}s\n" --max-time 10 http://127.0.0.1:8788/txt
echo "=== firewall rules referencing 8788 ==="
uci show firewall | grep -B3 -A3 8788
echo "=== curl version ==="
curl --version | head -2
