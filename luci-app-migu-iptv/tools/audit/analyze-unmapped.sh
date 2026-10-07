#!/bin/sh
# 分析「未映射到标准 EPG id」的频道都是些什么，判断还有多少可映射空间
curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m.txt
grep -o 'tvg-id="[^"]*"' /tmp/m.txt | sed 's/tvg-id="//;s/"//' > /tmp/used.txt
grep -o 'tvg-name="[^"]*"' /tmp/m.txt | sed 's/tvg-name="//;s/"//' > /tmp/names.txt

echo "=== 1. 未映射的【唯一】tvg-id 列表（去重）==="
sort -u /tmp/used.txt > /tmp/used.u
n=0
while read -r id; do
	if ! grep -qxF "$id" /tmp/base.ids; then
		n=$((n+1))
		printf '%3d  %s\n' "$n" "$id"
	fi
done < /tmp/used.u
echo "（未映射唯一 id 共 $n 个）"

echo ""
echo "=== 2. 这些未映射名字里，是否含有 EPG 表已知 id 作为前缀/子串 ==="
while read -r id; do
	if grep -qxF "$id" /tmp/base.ids; then continue; fi
	# 找 EPG 表里长度>=4 且是该名字子串的 id
	hit=$(while read -r e; do
		[ ${#e} -ge 4 ] || continue
		case "$id" in *"$e"*) echo "$e";; esac
	done < /tmp/base.ids | head -3 | tr '\n' ',')
	[ -n "$hit" ] && printf '  %-28s ← 含 %s\n' "$id" "$hit"
done < /tmp/used.u

echo ""
echo "=== 3. EPG 表里有、但 M3U 完全没用到的 id（潜在可映射目标）==="
sort -u /tmp/used.txt > /tmp/u.txt
comm -23 /tmp/base.ids /tmp/u.txt > /tmp/unused.ids
wc -l < /tmp/unused.ids
head -40 /tmp/unused.ids
