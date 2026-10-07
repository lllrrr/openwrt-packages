#!/bin/sh
# check-141.sh —— 1.4.1 上线后 EPG/映射/性能复检
echo "=== EPG 状态 ==="
curl -s -m 10 http://127.0.0.1:8788/health | grep -E '"version"|epg'
echo ""
echo "=== /m3u 首行 ==="
curl -s -m 25 http://127.0.0.1:8788/m3u > /tmp/c141.m3u
head -1 /tmp/c141.m3u
echo ""
echo "=== tvg-id 统计 ==="
echo -n "  EXTINF 总条数:        "; grep -c '^#EXTINF' /tmp/c141.m3u
echo -n "  tvg-id 唯一值:        "; grep -o 'tvg-id="[^"]*"' /tmp/c141.m3u | sort -u | wc -l
echo -n "  以 CCTV 开头:         "; grep -o 'tvg-id="[^"]*"' /tmp/c141.m3u | sort -u | grep -c 'tvg-id="CCTV'
echo -n "  含中文（疑似未映射）: "; grep -o 'tvg-id="[^"]*"' /tmp/c141.m3u | sort -u | grep -c '[一-龥]'
echo ""
echo "=== 未映射的 tvg-id 样例（前 12 个）==="
grep -o 'tvg-id="[^"]*"' /tmp/c141.m3u | sort -u | grep '[一-龥]' | head -12
echo ""
echo "=== EPG 日志 ==="
logread 2>/dev/null | grep -i 'EPG' | tail -3
echo ""
echo "=== 性能复测 ==="
echo -n "  /m3u:    "; curl -s -m 25 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://127.0.0.1:8788/m3u
echo -n "  /ch 冷:  "; curl -s -m 25 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://127.0.0.1:8788/ch/608807420
echo -n "  /ch 热:  "; curl -s -m 25 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://127.0.0.1:8788/ch/608807420
echo -n "  /txt:    "; curl -s -m 25 -o /dev/null -w 'code=%{http_code} size=%{size_download}\n' http://127.0.0.1:8788/txt
