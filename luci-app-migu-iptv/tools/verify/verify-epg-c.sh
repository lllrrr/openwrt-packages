#!/bin/sh
# 追查 tvg-id="C" 的误匹配，并验证 chFallback
echo "=== 1. 哪个频道被映射成了 C ==="
grep -n 'tvg-id="C"' /tmp/m3u131.txt

echo ""
echo "=== 2. 该频道在 M3U 里的完整行 ==="
grep 'tvg-id="C"' /tmp/m3u131.txt

echo ""
echo "=== 3. 是否存在别的 C 开头但应属 CCTV 的频道被吞 ==="
echo -n "EXTINF 里有 CCTV 字样但 tvg-id 不是 CCTV 的条数: "
grep '^#EXTINF' /tmp/m3u131.txt | grep 'CCTV' | grep -vc 'tvg-id="CCTV'

echo ""
echo "=== 4. 未映射频道的成因分类（对照 EPG id 表）==="
echo "EPG 源里的 124 个 id 是否含这些名字："
curl -s -m 60 -o /tmp/epgcheck.xml https://live.fanmingming.cn/e.xml
sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/epgcheck.xml | sort -u > /tmp/epgids.txt
echo "EPG id 总数: $(wc -l < /tmp/epgids.txt)"
for n in "东方卫视" "北京卫视" "CHC家庭影院" "三沙卫视" "优漫卡通" "上海新闻综合" "南京十八频道" "备用源1-海外CCTV5HD"; do
	if grep -qx "$n" /tmp/epgids.txt; then echo "  有: $n"; else echo "  无: $n"; fi
done

echo ""
echo "=== 5. chFallback 计数验证（打两个可能走降级的频道）==="
curl -s -m 20 -o /dev/null -w 'ch1 code=%{http_code} t=%{time_total}\n' http://127.0.0.1:8788/ch/641886690
curl -s -m 20 -o /dev/null -w 'ch2 code=%{http_code} t=%{time_total}\n' http://127.0.0.1:8788/ch/608807420
echo "--- /health ---"
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "chRequests|chCache|chFallback|streamCache|avgResolve|version|epgIds"
