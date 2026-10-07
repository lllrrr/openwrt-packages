#!/bin/sh
# 1.3.1 终版部署 + 正确口径验证（EPG 基准带重试，避免偶发 TLS 失败污染结论）
SRC=/tmp/migu-final.uc
DST=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.3.1-crashbak.bak

echo "=== 0. 语法检查 ==="
ucode -c -o /tmp/chkf.uc "$SRC" || { echo "FAIL: 语法检查未通过"; exit 1; }
echo "OK"

echo ""
echo "=== 1. 备份当前（坏版本）==="
cp "$DST" "$BAK"; md5sum "$BAK"

echo ""
echo "=== 2. 部署 ==="
cp "$SRC" "$DST"; chmod 755 "$DST"
md5sum "$DST"; echo "行数 $(wc -l < $DST)"; grep -m1 APP_VERSION "$DST"

echo ""
echo "=== 3. 重启 ==="
/etc/init.d/migu restart
sleep 3
ps w | grep "[m]igu.uc" | head -2

echo ""
echo "=== 4. 确认进程稳定存活（关键：验证不再被异常带走）==="
alive=1
i=0
while [ $i -lt 12 ]; do
	sleep 5; i=$((i+1))
	p=$(ps w | grep -c "[m]igu.uc")
	ids=$(curl -s -m 8 http://127.0.0.1:8788/health 2>/dev/null | tr ',' '\n' | grep -E '"epgIds"|"epgOk"' | tr -d ' \t\n')
	echo "  t=$((i*5))s 进程数=$p $ids"
	if [ "$p" = "0" ]; then alive=0; break; fi
done
if [ $alive = 1 ]; then echo "✅ 进程 60 秒内未再崩溃"; else echo "❌ 进程又崩了"; fi

echo ""
echo "=== 5. EPG 与错误日志 ==="
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "version|epg"
echo "--- 最近 EPG 日志 ---"; logread 2>/dev/null | grep -i "EPG" | tail -4
echo "--- 是否还有 scheduleEpgRefresh 报错 ---"
logread 2>/dev/null | grep -c "scheduleEpgRefresh" || true

echo ""
echo "=== 6. EPG 基准（落盘 + 重试，直到成功）==="
n=0
while [ $n -lt 5 ]; do
	curl -s -L -m 60 -o /tmp/epgbase.xml https://live.fanmingming.cn/e.xml
	if [ -s /tmp/epgbase.xml ]; then break; fi
	n=$((n+1)); echo "  第 $n 次失败，重试…"; sleep 3
done
if [ -s /tmp/epgbase.xml ]; then
	echo "基准字节 $(wc -c < /tmp/epgbase.xml)"
	sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/epgbase.xml | sort -u > /tmp/epgbase.ids
	echo "标准 id 数 $(wc -l < /tmp/epgbase.ids)"
else
	echo "❌ 基准下载全失败，跳过映射核对"
fi

echo ""
echo "=== 7. /m3u 与映射核对 ==="
curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m3uf.txt
total=$(grep -c '^#EXTINF' /tmp/m3uf.txt)
echo "bytes=$(wc -c < /tmp/m3uf.txt)  EXTINF=$total"
grep -o 'tvg-id="[^"]*"' /tmp/m3uf.txt | sed 's/tvg-id="//;s/"//' > /tmp/usedf.txt

if [ -s /tmp/epgbase.ids ]; then
	m=0; u=0
	while read -r id; do
		if grep -qxF "$id" /tmp/epgbase.ids; then m=$((m+1)); else u=$((u+1)); fi
	done < /tmp/usedf.txt
	echo "✅ 已映射到标准 EPG id 的频道条数: $m / $total"
	echo "   仍用频道名的条数:              $u / $total"
fi

echo ""
echo "=== 8. 误匹配/崩溃回归检查 ==="
echo -n 'tvg-id="C" 条数（必须 0）: '; grep -c 'tvg-id="C"' /tmp/m3uf.txt
echo -n 'tvg-id="DTV" 条数（必须 0）: '; grep -c 'tvg-id="DTV"' /tmp/m3uf.txt

echo ""
echo "--- 央视频道映射抽查 ---"
grep '^#EXTINF' /tmp/m3uf.txt | grep -oE 'tvg-id="[^"]*" tvg-name="CCTV[0-9+]+[^"]*"' | head -10
echo "--- CGTN/CETV 抽查（修复前被吞成 C）---"
grep '^#EXTINF' /tmp/m3uf.txt | grep -oE 'tvg-id="[^"]*" tvg-name="(CGTN[^"]*|CETV[0-9])"' | sort -u

echo ""
echo "=== 9. 取流与降级计数 ==="
curl -s -m 20 -o /dev/null -w 'ch1 code=%{http_code} t=%{time_total}\n' http://127.0.0.1:8788/ch/608807420
curl -s -m 20 -o /dev/null -w 'ch2 code=%{http_code} t=%{time_total}\n' http://127.0.0.1:8788/ch/641886690
curl -s -m 20 -o /dev/null -w 'ch3(热) code=%{http_code} t=%{time_total}\n' http://127.0.0.1:8788/ch/608807420
echo "--- /health 统计 ---"
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "chRequests|chCache|chFallback|streamCache|avgResolve|activeConns|uptime"
