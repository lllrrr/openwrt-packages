#!/bin/sh
# 1.4.0 最终部署与完整验收
SRC=/tmp/migu-140f.uc
DST=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.3.1-epgfix.bak

echo "=== 0. 语法检查 ==="
ucode -c -o /tmp/chk.uc "$SRC" || { echo "FAIL"; exit 1; }
echo "OK  $(grep -c '' $SRC) 行  $(wc -c < $SRC) 字节"

echo ""
echo "=== 1. 备份 + 部署 ==="
cp "$DST" "$BAK"; echo "备份 $(md5sum $BAK | cut -d' ' -f1)"
cp "$SRC" "$DST"; chmod 755 "$DST"
echo "部署 $(md5sum $DST | cut -d' ' -f1)"
grep -m1 APP_VERSION "$DST"

echo ""
echo "=== 2. 重启 + 等 EPG 就绪 ==="
/etc/init.d/migu restart
i=0; got=''
while [ $i -lt 24 ]; do
	sleep 5; i=$((i+1))
	p=$(ps w | grep -c "[m]igu.uc")
	[ "$p" = "0" ] && { echo "❌ 进程崩了"; break; }
	v=$(curl -s -m 8 http://127.0.0.1:8788/health 2>/dev/null | tr ',' '\n' | grep -E '"epgIds"|"epgOk"' | tr -d ' \t\n')
	case "$v" in *'"epgOk":true'*) got="$v"; echo "  ✅ t=$((i*5))s $v"; break;; esac
done
[ -n "$got" ] || echo "⚠️ 未就绪"

echo ""
echo "=== 3. 崩溃类错误计数（须全 0）==="
for pat in "not a function" "Reference error" "scheduleEpgRefresh" "epgFetchIds" "Syntax error"; do
	echo -n "  '$pat': "; logread 2>/dev/null | grep -c "$pat"
done
echo "--- 最近 EPG 日志 ---"
logread 2>/dev/null | grep -i "EPG" | tail -3

echo ""
echo "=== 4. /health 全字段 ==="
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | sed 's/^ *//'

echo ""
echo "=== 5. 映射核对（正确口径）==="
curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m.txt
total=$(grep -c '^#EXTINF' /tmp/m.txt)
grep -o 'tvg-id="[^"]*"' /tmp/m.txt | sed 's/tvg-id="//;s/"//' > /tmp/used.txt
m=0; u=0
while read -r id; do
	if grep -qxF "$id" /tmp/base.ids; then m=$((m+1)); else u=$((u+1)); fi
done < /tmp/used.txt
echo "  /m3u $(wc -c < /tmp/m.txt) 字节，$total 条频道"
echo "  ✅ 命中标准 EPG id: $m / $total"
echo "     未命中（源里无此台）: $u / $total"
echo -n '  tvg-id="C" 误匹配（须 0）: '; grep -c 'tvg-id="C"' /tmp/m.txt
echo -n '  首行 x-tvg-url: '; head -1 /tmp/m.txt

echo ""
echo "=== 6. 性能回归对比（改造前基线 冷0.48~0.78s / 热0.0018s）==="
curl -s -m 25 -o /dev/null -w '  冷 /ch/608807420  code=%{http_code} t=%{time_total}s\n' http://127.0.0.1:8788/ch/608807420
curl -s -m 25 -o /dev/null -w '  热 /ch/608807420  code=%{http_code} t=%{time_total}s\n' http://127.0.0.1:8788/ch/608807420
curl -s -m 25 -o /dev/null -w '  再热             code=%{http_code} t=%{time_total}s\n' http://127.0.0.1:8788/ch/608807420
curl -s -m 25 -o /dev/null -w '  /m3u             code=%{http_code} t=%{time_total}s\n' http://127.0.0.1:8788/m3u
echo -n '  /txt 大小: '; curl -s -m 15 http://127.0.0.1:8788/txt | wc -c
echo -n '  /health(免令牌) 免鉴权: '; curl -s -m 10 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8788/health
echo -n '  无效 pid 失败缓存: '; curl -s -m 25 -o /dev/null -w '%{time_total}s ' http://127.0.0.1:8788/ch/99999999; curl -s -m 25 -o /dev/null -w '→ %{time_total}s\n' http://127.0.0.1:8788/ch/99999999

echo ""
echo "=== 7. 内存 ==="
p=$(ps w | grep "[m]igu.uc" | awk '{print $1}')
[ -n "$p" ] && grep -E 'VmRSS|Threads' /proc/$p/status && echo "  fd: $(ls /proc/$p/fd 2>/dev/null | wc -l)"
