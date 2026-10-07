#!/bin/sh
# 决定前缀匹配的长度阈值：列出 EPG id 表里所有短 id 与可疑 id
echo "=== 1. EPG id 总数 ==="
wc -l < /tmp/epgids.txt

echo ""
echo "=== 2. 按长度分组统计 ==="
while read -r id; do echo "${#id}"; done < /tmp/epgids.txt | sort -n | uniq -c

echo ""
echo "=== 3. 长度 <= 3 的所有 id（这些最容易误匹配）==="
while read -r id; do
	n=${#id}
	if [ "$n" -le 3 ]; then echo "[$n] $id"; fi
done < /tmp/epgids.txt

echo ""
echo "=== 4. 长度 4~5 的所有 id（评估 3 是否够安全）==="
while read -r id; do
	n=${#id}
	if [ "$n" -ge 4 ] && [ "$n" -le 5 ]; then echo "[$n] $id"; fi
done < /tmp/epgids.txt

echo ""
echo "=== 5. 长度 1~2 的 id 逐个测试会吞掉哪些真实频道名 ==="
for short in C DTV; do
	echo "--- id='$short' ---"
	grep -o 'tvg-name="[^"]*"' /tmp/m3u131.txt | sed 's/tvg-name="//;s/"//' | sort -u | grep "^$short" | head -20
done

echo ""
echo "=== 6. 那 3 条含 CCTV 但 tvg-id 非 CCTV 开头的行 ==="
grep '^#EXTINF' /tmp/m3u131.txt | grep 'CCTV' | grep -v 'tvg-id="CCTV'

echo ""
echo "=== 7. 若阈值为 3，CGTN*/CETV4 会退回到什么 ==="
for n in "CGTN" "CGTN俄语" "CGTN阿拉伯语" "CGTN外语纪录" "CGTN法语" "CGTN西班牙语" "CETV1" "CETV2" "CETV4"; do
	hit=""
	while read -r id; do
		[ "${#id}" -lt 3 ] && continue
		case "$n" in
			"$id"*) if [ "${#id}" -gt "${#hit}" ]; then hit="$id"; fi ;;
		esac
	done < /tmp/epgids.txt
	if [ -n "$hit" ]; then echo "  $n -> $hit"; else echo "  $n -> (无匹配, 退回频道名)"; fi
done
