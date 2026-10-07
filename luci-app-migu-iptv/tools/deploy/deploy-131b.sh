#!/bin/sh
# 1.3.1 第二轮：部署 EPG_MIN_PREFIX 修复 + 用正确口径验证
SRC=/tmp/migu-131b.uc
DST=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.3.1-epg.bak

echo "=== 0. 语法检查 ==="
ucode -c -o /tmp/chk131b.uc "$SRC" || { echo "FAIL: 语法检查未通过"; exit 1; }
echo "OK"

echo ""
echo "=== 1. 备份当前（1.3.1 第一轮）==="
cp "$DST" "$BAK"; md5sum "$BAK"

echo ""
echo "=== 2. 部署 ==="
cp "$SRC" "$DST"; chmod 755 "$DST"
md5sum "$DST"; echo "行数 $(wc -l < $DST)"
grep -m1 APP_VERSION "$DST"

echo ""
echo "=== 3. 重启 ==="
/etc/init.d/migu restart
sleep 3
ps w | grep "[m]igu.uc" | head -2 || { echo "FAIL: 未起，回滚"; cp "$BAK" "$DST"; /etc/init.d/migu restart; exit 1; }

echo ""
echo "=== 4. 等 EPG 首次抓取 ==="
sleep 14
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "version|epgIds|epgOk"

echo ""
echo "=== 5. 取 EPG 标准 id 表（作为正确性基准）==="
curl -s -m 60 -o /tmp/epgv.xml https://live.fanmingming.cn/e.xml
[ -s /tmp/epgv.xml ] || { echo "FAIL: EPG 下载为空"; exit 1; }
echo "EPG 字节 $(wc -c < /tmp/epgv.xml)"
sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/epgv.xml | sort -u > /tmp/epgids.txt
echo "标准 id 数 $(wc -l < /tmp/epgids.txt)"

echo ""
echo "=== 6. 取 /m3u ==="
curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m3u131b.txt
echo "bytes=$(wc -c < /tmp/m3u131b.txt)  EXTINF=$(grep -c '^#EXTINF' /tmp/m3u131b.txt)"

echo ""
echo "=== 7. 决定性验证 A：tvg-id 是否都存在于标准 id 表里 ==="
grep -o 'tvg-id="[^"]*"' /tmp/m3u131b.txt | sed 's/tvg-id="//;s/"//' | sort > /tmp/used_ids.txt
echo "用到的不同 tvg-id 数: $(sort -u /tmp/used_ids.txt | wc -l)"
echo "其中【存在于 EPG 标准表】的条数: $(sort -u /tmp/used_ids.txt | grep -Fxf /tmp/epgids.txt | wc -l)"
echo "其中【不在 EPG 标准表】的条数（应只剩真正无 EPG 的频道）: $(sort -u /tmp/used_ids.txt | grep -vFxf /tmp/epgids.txt | wc -l)"

echo ""
echo "--- 不在标准表里的 tvg-id（这些就是确实没有 EPG 的频道）---"
sort -u /tmp/used_ids.txt | grep -vFxf /tmp/epgids.txt | head -40

echo ""
echo "=== 8. 决定性验证 B：tvg-id=\"C\" 误匹配是否已消除 ==="
echo -n 'tvg-id="C" 的条数（修复前 8）: '
grep -c 'tvg-id="C"' /tmp/m3u131b.txt

echo ""
echo "--- CGTN*/CETV4 现在的 tvg-id ---"
grep '^#EXTINF' /tmp/m3u131b.txt | grep -oE 'tvg-id="[^"]*" tvg-name="(CGTN[^"]*|CETV4)"' | sort -u

echo ""
echo "=== 9. 抽查几条央视频道映射 ==="
grep '^#EXTINF' /tmp/m3u131b.txt | grep -oE 'tvg-id="[^"]*" tvg-name="CCTV[0-9+]+[^"]*"' | head -8

echo ""
echo "=== 10. 统计口径修正：真正未映射的条数 ==="
total=$(grep -c '^#EXTINF' /tmp/m3u131b.txt)
echo "总频道 $total"
mapped=0
unmapped=0
grep '^#EXTINF' /tmp/m3u131b.txt | while read -r line; do :; done
grep -o 'tvg-id="[^"]*"' /tmp/m3u131b.txt | sed 's/tvg-id="//;s/"//' | while read -r id; do
	if grep -qxF "$id" /tmp/epgids.txt; then echo "M"; else echo "U"; fi
done | sort | uniq -c
