#!/bin/sh
# 诊断：为什么服务内的 EPG 拉取失败，而同一时刻手工 curl 成功
echo "=== 1. 当前 /health EPG 字段 ==="
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "version|epg"

echo ""
echo "=== 2. logread 里的 EPG 记录 ==="
logread 2>/dev/null | grep -i "EPG" | tail -10
echo "--- 若为空，看 migu 全部日志尾部 ---"
logread 2>/dev/null | grep -i "migu" | tail -15

echo ""
echo "=== 3. 复现服务里的那条命令（逐段拆开）==="
TMP=/tmp/.migu-epg-diag.xml
URL='https://live.fanmingming.cn/e.xml'

echo "--- 3a. 只跑 curl -o 落盘 ---"
rm -f "$TMP"
t0=$(date +%s)
curl -s -L -m 60 -o "$TMP" "$URL"
rc=$?
t1=$(date +%s)
echo "curl exit=$rc 耗时=$((t1-t0))s 文件字节=$(wc -c < $TMP 2>/dev/null || echo NONE)"

echo ""
echo "--- 3b. 整条命令（和代码里完全一致，仅换临时路径）---"
CMD="curl -s -L -m 60 -o $TMP $URL && sed -n 's/.*<channel[^>]*id=\"\([^\"]*\)\".*/\1/p' $TMP | sort -u"
t0=$(date +%s)
OUT=$(sh -c "$CMD")
t1=$(date +%s)
echo "耗时=$((t1-t0))s"
echo "输出行数=$(printf '%s\n' "$OUT" | grep -c . )"
echo "前 5 行:"
printf '%s\n' "$OUT" | head -5

echo ""
echo "=== 4. 内存与 /tmp 状态 ==="
free | head -2
df -h /tmp | tail -1
ls -la /tmp/.migu-epg.xml 2>/dev/null || echo "服务临时文件不存在（已被 rm）"

echo ""
echo "=== 5. 服务进程状态 ==="
ps w | grep "[m]igu.uc"

echo ""
echo "=== 6. 直接触发一次服务的 EPG 刷新（通过重启，观察首拉是否稳定）==="
/etc/init.d/migu restart
for i in 5 10 15 20 25 30; do
	sleep 5
	v=$(curl -s -m 8 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E '"epgIds"|"epgOk"' | tr '\n' ' ')
	echo "  t=${i}s $v"
done

echo ""
echo "=== 7. 最终 EPG 状态 ==="
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "version|epg"
echo "--- 本轮日志 ---"
logread 2>/dev/null | grep -i "EPG" | tail -5
