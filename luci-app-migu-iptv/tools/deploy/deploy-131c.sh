#!/bin/sh
# 1.3.1 终版部署 + 正确口径验证
SRC=/tmp/migu-131c.uc
DST=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.3.1-epgprefix.bak

echo "=== 0. 语法检查 ==="
ucode -c -o /tmp/chk131c.uc "$SRC" || { echo "FAIL: 语法检查未通过"; exit 1; }
echo "OK"

echo ""
echo "=== 1. 备份 ==="
cp "$DST" "$BAK"; md5sum "$BAK"

echo ""
echo "=== 2. 部署 ==="
cp "$SRC" "$DST"; chmod 755 "$DST"
md5sum "$DST"; echo "行数 $(wc -l < $DST)"

echo ""
echo "=== 3. 重启并等待 EPG 就绪（最多 90s）==="
/etc/init.d/migu restart
ok=0
i=0
while [ $i -lt 18 ]; do
	sleep 5; i=$((i+1))
	line=$(curl -s -m 8 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E '"epgIds"|"epgOk"' | tr -d ' \t\n')
	echo "  t=$((i*5))s $line"
	case "$line" in *'"epgOk": true'*) ok=1; break;; esac
done
[ $ok = 1 ] || echo "警告：EPG 未在 90s 内就绪"

echo ""
echo "=== 4. EPG 状态 ==="
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "version|epg"
echo "--- 日志 ---"
logread 2>/dev/null | grep -i "EPG" | tail -4

echo ""
echo "=== 5. 基准：EPG 标准 id 表 ==="
curl -s -m 60 -o /tmp/epgv2.xml https://live.fanmingming.cn/e.xml || true
if [ ! -s /tmp/epgv2.xml ]; then echo "下载失败(偶发TLS)，重试一次"; sleep 2; curl -s -m 60 -o /tmp/epgv2.xml https://live.fanmingming.cn/e.xml; fi
[ -s /tmp/epgv2.xml ] || { echo "FAIL: 基准下载失败，改用服务内已知的 124 个 id"; }
sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/epgv2.xml | sort -u > /tmp/epgids2.txt
echo "标准 id 数 $(wc -l < /tmp/epgids2.txt)"

echo ""
echo "=== 6. /m3u ==="
curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m3u131c.txt
total=$(grep -c '^#EXTINF' /tmp/m3u131c.txt)
echo "bytes=$(wc -c < /tmp/m3u131c.txt)  EXTINF=$total"

echo ""
echo "=== 7. 【核心指标】每个用到的 tvg-id 是否命中 EPG 标准表 ==="
grep -o 'tvg-id="[^"]*"' /tmp/m3u131c.txt | sed 's/tvg-id="//;s/"//' > /tmp/used2.txt
hit=0; miss=0
sort -u /tmp/used2.txt > /tmp/used2u.txt
while read -r id; do
	if grep -qxF "$id" /tmp/epgids2.txt; then hit=$((hit+1)); else miss=$((miss+1)); fi
done < /tmp/used2u.txt
echo "不同 tvg-id 共 $(wc -l < /tmp/used2u.txt) 个：命中标准表 $hit 个，未命中 $miss 个"
echo "→ 按频道条数计（更直观）:"
m=0; u=0
while read -r id; do
	if grep -qxF "$id" /tmp/epgids2.txt; then m=$((m+1)); else u=$((u+1)); fi
done < /tmp/used2.txt
echo "   已映射到标准 EPG id 的频道条数: $m / $total"
echo "   仍用频道名做 tvg-id 的条数:     $u / $total"

echo ""
echo "=== 8. 误匹配回归检查 ==="
echo -n 'tvg-id="C" 条数（1.3.1前为 8，应为 0）: '; grep -c 'tvg-id="C"' /tmp/m3u131c.txt
echo -n 'tvg-id="DTV" 条数（应为 0）: '; grep -c 'tvg-id="DTV"' /tmp/m3u131c.txt

echo ""
echo "--- CCTV/CGTN/CETV 映射抽查 ---"
grep '^#EXTINF' /tmp/m3u131c.txt | grep -oE 'tvg-id="[^"]*" tvg-name="(CCTV[0-9+]+|CGTN[^"]*|CETV[0-9])[^"]*"' | head -20

echo ""
echo "=== 9. 仍用频道名的前 25 条（这些是 EPG 源里确实没有的台，属正常）==="
sort -u /tmp/used2.txt | grep -vFxf /tmp/epgids2.txt | head -25
