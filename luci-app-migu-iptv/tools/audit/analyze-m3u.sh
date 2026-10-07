#!/bin/sh
# analyze-m3u.sh —— 分析当前 /m3u 输出结构
curl -s -m 10 http://127.0.0.1:8788/m3u > /tmp/cur.m3u
echo "总行数: $(wc -l < /tmp/cur.m3u)"
echo "EXTINF 条数: $(grep -c '^#EXTINF' /tmp/cur.m3u)"
echo ""
echo "=== 前 25 行 ==="
head -25 /tmp/cur.m3u
echo ""
echo "=== group-title 统计 ==="
grep -o 'group-title="[^"]*"' /tmp/cur.m3u | sort | uniq -c | sort -rn
echo ""
echo "=== tvg-id 使用情况（非空统计） ==="
echo "  带 tvg-id= 的行: $(grep -c 'tvg-id="' /tmp/cur.m3u)"
echo "  tvg-id=\"\" 空: $(grep -c 'tvg-id=""' /tmp/cur.m3u)"
echo "  带 tvg-logo 的行: $(grep -c 'tvg-logo="' /tmp/cur.m3u)"
echo ""
echo "=== 样本 5 条（含 tvg-id/logo/group） ==="
grep '^#EXTINF' /tmp/cur.m3u | sed -n '1,5p'