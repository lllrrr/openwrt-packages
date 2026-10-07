#!/bin/sh
# 1.4.0 终版部署 + 长时间观察 EPG 可靠性
SRC=/tmp/migu-141.uc
DST=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.4.0-pre.bak

echo "=== 0. 语法检查 ==="
ucode -c -o /tmp/chk141.uc "$SRC" || { echo "FAIL: 语法检查未通过"; exit 1; }
echo "OK  $(grep -c '' $SRC) 行"

echo ""
echo "=== 1. 备份 + 部署 ==="
cp "$DST" "$BAK"; echo "备份 md5: $(md5sum $BAK | cut -d' ' -f1)"
cp "$SRC" "$DST"; chmod 755 "$DST"
echo "新版本 md5: $(md5sum $DST | cut -d' ' -f1)"
grep -m1 APP_VERSION "$DST"

echo ""
echo "=== 2. 重启 ==="
/etc/init.d/migu restart
sleep 3
ps w | grep "[m]igu.uc" | head -2

echo ""
echo "=== 3. 观察 120s：进程稳定 + EPG 是否就绪 ==="
i=0; epgok=''
while [ $i -lt 24 ]; do
	sleep 5; i=$((i+1))
	p=$(ps w | grep -c "[m]igu.uc")
	v=$(curl -s -m 8 http://127.0.0.1:8788/health 2>/dev/null | tr ',' '\n' | grep -E '"epgIds"|"epgOk"' | tr -d ' \t\n')
	[ $((i % 2)) -eq 0 ] && echo "  t=$((i*5))s 进程=$p $v"
	if [ "$p" = "0" ]; then echo "❌ 进程崩了"; break; fi
	case "$v" in *'"epgOk":true'*) epgok=1; echo "  ✅ EPG 就绪于 t=$((i*5))s"; break;; esac
done
[ -n "$epgok" ] || echo "⚠️ 120s 内未就绪"

echo ""
echo "=== 4. 日志（EPG 与崩溃类）==="
logread 2>/dev/null | grep -iE "EPG|not a function|migu.*error" | tail -8
echo "--- 崩溃类计数（须全 0）---"
for pat in "not a function" "scheduleEpgRefresh" "epgFetchIds" "Reference error"; do
	echo -n "  '$pat': "; logread 2>/dev/null | grep -c "$pat"
done

echo ""
echo "=== 5. /health ==="
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "version|epg|uptime|streamTtl|maxConns"

echo ""
echo "=== 6. 反复重启 5 次，统计 EPG 首次成功率（验证 --retry-all-errors 的效果）==="
succ=0; fail=0
r=0
while [ $r -lt 5 ]; do
	r=$((r+1))
	/etc/init.d/migu restart
	s=0; got=''
	while [ $s -lt 24 ]; do
		sleep 5; s=$((s+1))
		v=$(curl -s -m 8 http://127.0.0.1:8788/health 2>/dev/null | tr ',' '\n' | grep -E '"epgOk"' | tr -d ' \t\n')
		case "$v" in *'true'*) got=yes; break;; esac
	done
	if [ "$got" = yes ]; then succ=$((succ+1)); echo "  第$r次: ✅ 成功（${s}×5s）"; else fail=$((fail+1)); echo "  第$r次: ❌ 失败"; fi
done
echo "  首拉成功 $succ / 5，失败 $fail / 5"

echo ""
echo "=== 7. 阻塞验证：EPG 拉取窗口内 /m3u 与 /ch 延迟 ==="
/etc/init.d/migu restart
sleep 2
j=0
while [ $j -lt 6 ]; do
	j=$((j+1))
	t1=$(curl -s -m 25 -o /dev/null -w '%{time_total}' http://127.0.0.1:8788/m3u)
	t2=$(curl -s -m 25 -o /dev/null -w '%{time_total}' http://127.0.0.1:8788/ch/608807420)
	echo "  第$j次 /m3u=${t1}s /ch=${t2}s"
	sleep 3
done

echo ""
echo "=== 8. tvg-id 映射（正确口径）==="
n=0
while [ $n -lt 6 ]; do
	rm -f /tmp/base.xml
	curl -s -L --compressed -m 30 --retry 4 --retry-delay 2 --retry-all-errors -o /tmp/base.xml https://live.fanmingming.cn/e.xml
	[ -s /tmp/base.xml ] && tail -c 200 /tmp/base.xml | grep -q '</tv>' && break
	n=$((n+1)); sleep 2
done
if [ -s /tmp/base.xml ] && tail -c 200 /tmp/base.xml | grep -q '</tv>'; then
	sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/base.xml | sort -u > /tmp/base.ids
	echo "标准 id 数 $(wc -l < /tmp/base.ids)"
	# 等服务 EPG 就绪
	w=0
	while [ $w -lt 18 ]; do
		v=$(curl -s -m 8 http://127.0.0.1:8788/health | grep -o '"epgOk": *[a-z]*')
		case "$v" in *true*) break;; esac
		sleep 5; w=$((w+1))
	done
	curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m.txt
	total=$(grep -c '^#EXTINF' /tmp/m.txt)
	grep -o 'tvg-id="[^"]*"' /tmp/m.txt | sed 's/tvg-id="//;s/"//' > /tmp/used.txt
	m=0; u=0
	while read -r id; do
		if grep -qxF "$id" /tmp/base.ids; then m=$((m+1)); else u=$((u+1)); fi
	done < /tmp/used.txt
	echo "✅ 映射到标准 EPG id: $m / $total"
	echo "   未映射: $u / $total"
	echo -n '   tvg-id="C" 误匹配（须 0）: '; grep -c 'tvg-id="C"' /tmp/m.txt
	echo "--- CGTN/CETV 抽查 ---"
	grep '^#EXTINF' /tmp/m.txt | grep -oE 'tvg-id="[^"]*" tvg-name="(CGTN[^"]*|CETV[0-9])"' | sort -u
else
	echo "❌ 基准下载失败"
fi

echo ""
echo "=== 9. 内存 ==="
p=$(ps w | grep "[m]igu.uc" | awk '{print $1}')
[ -n "$p" ] && grep -E 'VmRSS|Threads' /proc/$p/status
