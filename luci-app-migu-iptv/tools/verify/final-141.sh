#!/bin/sh
# final-141.sh —— 1.4.1 终验：版本一致性、端点回归、EPG、内存
echo "=== 部署文件与仓库版本一致性 ==="
echo "  路由器 md5: $(md5sum /usr/share/ucode/migu.uc | cut -d' ' -f1)"
echo "  路由器 size: $(wc -c < /usr/share/ucode/migu.uc)"
grep -m1 'APP_VERSION' /usr/share/ucode/migu.uc
echo "  uci maxConns: $(uci get migu.main.maxConns)"
echo ""
echo "=== /health 全文 ==="
curl -s -m 10 http://127.0.0.1:8788/health
echo ""
echo "=== 端点回归 ==="
for p in /m3u /txt; do
	echo -n "  $p: "
	curl -s -m 25 -o /tmp/f.out -w 'code=%{http_code} size=%{size_download} time=%{time_total}\n' "http://127.0.0.1:8788$p"
done
echo -n "  /ch/608807420 (热): "
curl -s -m 25 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://127.0.0.1:8788/ch/608807420
echo -n "  /ch/608807421 (冷): "
curl -s -m 25 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://127.0.0.1:8788/ch/608807421
echo -n "  /ch/9001 (外部源): "
curl -s -m 25 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://127.0.0.1:8788/ch/9001
echo ""
echo "=== /m3u 首行与条数 ==="
curl -s -m 25 http://127.0.0.1:8788/m3u > /tmp/f.m3u
head -1 /tmp/f.m3u
echo "  EXTINF 条数: $(grep -c '^#EXTINF' /tmp/f.m3u)"
echo ""
echo "=== 崩溃类日志计数（须全 0）==="
for pat in "not a function" "Reference error" "Syntax error" "attempt to index"; do
	echo -n "  '$pat': "; logread 2>/dev/null | grep -c "$pat"
done
echo ""
echo "=== 内存/线程/fd ==="
P=$(pgrep -f 'ucode.*migu.uc' | head -1)
echo "  pid=$P"
grep -E 'VmRSS|Threads' /proc/$P/status
echo "  fd 数: $(ls /proc/$P/fd 2>/dev/null | wc -l)"
echo ""
echo "=== 长时间运行后 uptime ==="
curl -s -m 5 http://127.0.0.1:8788/health | grep -E '"uptime"|"requests"|rejectedByLimit'
