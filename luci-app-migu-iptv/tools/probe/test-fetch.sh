#!/bin/sh
# 对比几种抓取策略的可靠性（每种 4 次），并测试 gzip 压缩是否可用
URL='https://live.fanmingming.cn/e.xml'

probe() {  # $1=文件 $2=策略名 $3=命令
	f=$1; name=$2; shift 2
	rm -f "$f"
	t0=$(date +%s)
	sh -c "$*"
	t1=$(date +%s)
	b=$(wc -c < "$f" 2>/dev/null || echo 0)
	if [ -s "$f" ] && tail -c 200 "$f" | grep -q '</tv>'; then st=COMPLETE; else st=TRUNCATED; fi
	printf '  %-34s %8s字节 %-9s %2ss\n' "$name" "$b" "$st" "$((t1-t0))"
}

echo "=== S1 当前策略：shell 循环 3 次 × curl -m 25 --retry 1 ==="
i=0; while [ $i -lt 4 ]; do
	i=$((i+1))
	probe /tmp/s1.xml "S1#$i" "i=0; while [ \$i -lt 3 ]; do curl -s -L -m 25 --retry 1 -o /tmp/s1.xml $URL; if [ -s /tmp/s1.xml ] && tail -c 200 /tmp/s1.xml | grep -q '</tv>'; then break; fi; rm -f /tmp/s1.xml; i=\$((i+1)); sleep 2; done"
done

echo ""
echo "=== S2 交给 curl 自己重试：--retry-all-errors --retry 5 ==="
i=0; while [ $i -lt 4 ]; do
	i=$((i+1))
	probe /tmp/s2.xml "S2#$i" "curl -s -L --connect-timeout 8 -m 25 --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/s2.xml $URL"
done

echo ""
echo "=== S3 压缩传输（--compressed，看能否显著缩小体积）==="
i=0; while [ $i -lt 3 ]; do
	i=$((i+1))
	probe /tmp/s3.xml "S3#$i" "curl -s -L --compressed --connect-timeout 8 -m 25 --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/s3.xml $URL"
done

echo ""
echo "=== S4 S3 基础上再加 shell 循环兜底（3 轮）==="
i=0; while [ $i -lt 4 ]; do
	i=$((i+1))
	probe /tmp/s4.xml "S4#$i" "i=0; while [ \$i -lt 3 ]; do curl -s -L --compressed --connect-timeout 8 -m 25 --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/s4.xml $URL; if [ -s /tmp/s4.xml ] && tail -c 200 /tmp/s4.xml | grep -q '</tv>'; then break; fi; rm -f /tmp/s4.xml; i=\$((i+1)); sleep 2; done"
done

echo ""
echo "=== 各策略解析出的 id 数（应均为 124）==="
for s in 1 2 3 4; do
	[ -s /tmp/s$s.xml ] || { echo "  s$s: 无文件"; continue; }
	n=$(sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/s$s.xml | sort -u | wc -l)
	echo "  /tmp/s$s.xml 字节=$(wc -c < /tmp/s$s.xml) id=$n"
done

echo ""
echo "=== 服务器是否支持压缩（看响应头）==="
curl -s -I -m 20 -H 'Accept-Encoding: gzip, deflate, br' "$URL" 2>&1 | grep -iE 'content-encoding|content-length|vary|cf-' | head -6
