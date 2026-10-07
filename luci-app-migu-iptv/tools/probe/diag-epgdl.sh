#!/bin/sh
# 测量 EPG 源下载的可靠性：为什么服务拿到 0 个 id
URL='https://live.fanmingming.cn/e.xml'

echo "=== 1. 连续 6 次下载（每次都落盘，看字节数与 curl 退出码）==="
i=0
while [ $i -lt 6 ]; do
	i=$((i+1))
	rm -f /tmp/e$i.xml
	curl -s -L -m 60 -o /tmp/e$i.xml -w 'code=%{http_code} size=%{size_download} t=%{time_total}\n' "$URL"
	rc=$?
	b=$(wc -c < /tmp/e$i.xml 2>/dev/null || echo 0)
	# 完整性判据：结尾应有 </tv>
	tail -c 200 /tmp/e$i.xml 2>/dev/null | grep -q '</tv>' && comp=COMPLETE || comp=TRUNCATED
	echo "  第$i次 rc=$rc 字节=$b $comp"
	sleep 2
done

echo ""
echo "=== 2. 带 --retry 的版本是否更可靠 ==="
i=0
while [ $i -lt 3 ]; do
	i=$((i+1))
	rm -f /tmp/r$i.xml
	curl -s -L -m 90 --retry 3 --retry-delay 2 --retry-connrefused \
		-o /tmp/r$i.xml -w 'code=%{http_code} size=%{size_download} t=%{time_total} retries_used=%{num_retries}\n' "$URL"
	rc=$?
	b=$(wc -c < /tmp/r$i.xml 2>/dev/null || echo 0)
	tail -c 200 /tmp/r$i.xml 2>/dev/null | grep -q '</tv>' && comp=COMPLETE || comp=TRUNCATED
	echo "  第$i次 rc=$rc 字节=$b $comp"
	sleep 2
done

echo ""
echo "=== 3. 完整性判据验证：完整文件解析出多少 id ==="
for f in /tmp/e1.xml /tmp/e2.xml /tmp/e3.xml /tmp/r1.xml /tmp/r2.xml /tmp/r3.xml; do
	[ -s "$f" ] || continue
	n=$(sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' "$f" | sort -u | wc -l)
	b=$(wc -c < "$f")
	tail -c 200 "$f" | grep -q '</tv>' && comp=COMPLETE || comp=TRUNCATED
	echo "  $f 字节=$b $comp 唯一id=$n"
done

echo ""
echo "=== 4. HTTP 头（看是否支持断点续传 / 有无压缩）==="
curl -s -I -m 30 "$URL" 2>&1 | head -12
