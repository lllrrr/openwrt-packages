#!/bin/sh
echo "=== A. EPG 标准表完整 id 列表（124 个）==="
cat /tmp/base.ids

echo ""
echo "=== B. 未映射名字是否真的不在表里（逐个精确查）==="
for x in CETV1 CETV2 CETV4 CGTN CGTN俄语 CGTN法语 熊猫频道1 南京十八频道 陕西秦腔频道 海南广播电视总台新闻频道 上海新闻综合 江苏城市频道; do
	printf '  %-32s 在表中=' "$x"
	grep -qxF "$x" /tmp/base.ids && echo YES || echo no
done

echo ""
echo "=== C. 未映射项里，去掉「备用源」(外部源频道，本就无 EPG) 后还剩多少 ==="
grep -v '^备用源' /tmp/used.u > /tmp/u2.txt
tot=$(wc -l < /tmp/used.u)
rest=$(wc -l < /tmp/u2.txt)
echo "  未映射唯一 id: $tot，其中备用源 4 个，其余 $rest"

echo ""
echo "=== D. 其余未映射项逐个核验是否在表中（全部核，不只取样）==="
inb=0; notin=0
while read -r id; do
	if grep -qxF "$id" /tmp/base.ids; then inb=$((inb+1)); echo "  [在表但未映射!] $id"; else notin=$((notin+1)); fi
done < /tmp/u2.txt
echo "  结论：在表却未映射 = $inb（应为 0）；确实不在表 = $notin"

echo ""
echo "=== E. 已映射的 77 条长什么样（抽查 20）==="
grep -o 'tvg-id="[^"]*" tvg-name="[^"]*"' /tmp/m.txt | while read -r line; do
	id=$(echo "$line" | sed 's/tvg-id="//;s/" tvg-name.*//')
	if grep -qxF "$id" /tmp/base.ids; then echo "  $line"; fi
done | head -20
