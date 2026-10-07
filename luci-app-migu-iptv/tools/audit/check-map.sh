#!/bin/sh
# check-map.sh —— 精确统计 /m3u 的 tvg-id 与 EPG 标准 id 表的交集
curl -s -m 25 http://127.0.0.1:8788/m3u > /tmp/x.m3u
echo "local m3u bytes: $(wc -c < /tmp/x.m3u)"

# EPG 标准 id 表：优先用服务自己落的盘，否则现拉一份
EPG=/tmp/.migu-epg.xml
if [ ! -s "$EPG" ]; then
	echo "服务临时文件不在，现拉一份 EPG"
	EPG=/tmp/e141.xml
	curl -s -L -m 60 -o "$EPG" https://live.fanmingming.cn/e.xml
fi
echo "EPG 文件: $EPG  bytes=$(wc -c < "$EPG")"

sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' "$EPG" | sort -u > /tmp/epg.ids
grep -o 'tvg-id="[^"]*"' /tmp/x.m3u | sed 's/^tvg-id="//; s/"$//' | sort -u > /tmp/tvg.ids

echo ""
echo "EPG 标准 id 数:        $(wc -l < /tmp/epg.ids)"
echo "M3U 唯一 tvg-id 数:    $(wc -l < /tmp/tvg.ids)"
echo "其中命中 EPG 标准 id:  $(grep -Fxf /tmp/epg.ids /tmp/tvg.ids | wc -l)"
echo "未命中（仍是中文名）:  $(grep -Fxvf /tmp/epg.ids /tmp/tvg.ids | wc -l)"

echo ""
echo "=== 命中样例（前 15）==="
grep -Fxf /tmp/epg.ids /tmp/tvg.ids | head -15

echo ""
echo "=== 未命中样例（前 20）==="
grep -Fxvf /tmp/epg.ids /tmp/tvg.ids | head -20

echo ""
echo "=== 检查杂项短 id 是否被误当标准 id ==="
for bad in C DTV; do
	echo -n "  M3U 中出现 tvg-id=\"$bad\": "
	grep -c "tvg-id=\"$bad\"" /tmp/x.m3u
done
