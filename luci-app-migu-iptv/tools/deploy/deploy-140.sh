#!/bin/sh
# 1.4.0 部署：EPG 改为「后台任务 + 轮询」（不阻塞事件循环）+ 完整性校验重试
SRC=/tmp/migu-140.uc
DST=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.3.1-final.bak

echo "=== 0. 语法检查 ==="
ucode -c -o /tmp/chk140.uc "$SRC" || { echo "FAIL: 语法检查未通过"; exit 1; }
echo "OK  $(grep -c '' $SRC) 行"

echo ""
echo "=== 0b. 正向对照：确认 ucode 真会因前向引用崩掉（证明规则成立）==="
if [ -f /tmp/control-fwd.uc ]; then
	echo "--- 运行含前向引用的对照文件，期望报 left-hand side is not a function ---"
	ucode /tmp/control-fwd.uc 2>&1 | head -6
else
	echo "(对照文件未上传，跳过)"
fi

echo ""
echo "=== 1. 备份 ==="
cp "$DST" "$BAK"; md5sum "$BAK"

echo ""
echo "=== 2. 部署 ==="
cp "$SRC" "$DST"; chmod 755 "$DST"
md5sum "$DST"; grep -m1 APP_VERSION "$DST"

echo ""
echo "=== 3. 重启 + 观察进程存活与 EPG（最多 100s）==="
/etc/init.d/migu restart
sleep 3
i=0; epgok=0
while [ $i -lt 20 ]; do
	sleep 5; i=$((i+1))
	p=$(ps w | grep -c "[m]igu.uc")
	v=$(curl -s -m 8 http://127.0.0.1:8788/health 2>/dev/null | tr ',' '\n' | grep -E '"epgIds"|"epgOk"' | tr -d ' \t\n')
	echo "  t=$((i*5))s 进程=$p $v"
	[ "$p" = "0" ] && { echo "❌ 进程崩了"; break; }
	case "$v" in *'"epgOk":true'*) epgok=1; break;; esac
done
[ $epgok = 1 ] && echo "✅ EPG 就绪" || echo "⚠️ 100s 内 EPG 未就绪（可能仍在重试）"

echo ""
echo "=== 4. EPG 日志 ==="
logread 2>/dev/null | grep -i "EPG" | tail -6
echo "--- 是否还有崩溃类报错 ---"
for pat in "not a function" "scheduleEpgRefresh" "epgFetchIds"; do
	echo -n "  '$pat' 出现次数: "; logread 2>/dev/null | grep -c "$pat"
done

echo ""
echo "=== 5. /health ==="
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "version|epg|uptime"

echo ""
echo "=== 6. 关键验证：EPG 拉取期间播放请求【不被阻塞】==="
echo "--- 重启服务，在首拉窗口内连续计时打频道 ---"
/etc/init.d/migu restart
sleep 1
j=0
while [ $j -lt 8 ]; do
	j=$((j+1))
	t=$(curl -s -m 25 -o /dev/null -w '%{time_total}' http://127.0.0.1:8788/m3u)
	echo "  第$j次 /m3u t=${t}s"
	sleep 1
done

echo ""
echo "=== 7. tvg-id 映射核对（正确口径：查是否在 EPG 标准表内）==="
n=0
while [ $n -lt 5 ]; do
	curl -s -L -m 30 -o /tmp/base.xml https://live.fanmingming.cn/e.xml
	[ -s /tmp/base.xml ] && tail -c 200 /tmp/base.xml | grep -q '</tv>' && break
	n=$((n+1)); echo "  基准第$n次不完整，重试…"; sleep 2
done
if [ -s /tmp/base.xml ] && tail -c 200 /tmp/base.xml | grep -q '</tv>'; then
	sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/base.xml | sort -u > /tmp/base.ids
	echo "标准 id 数 $(wc -l < /tmp/base.ids)"
	curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m.txt
	total=$(grep -c '^#EXTINF' /tmp/m.txt)
	grep -o 'tvg-id="[^"]*"' /tmp/m.txt | sed 's/tvg-id="//;s/"//' > /tmp/used.txt
	m=0; u=0
	while read -r id; do
		if grep -qxF "$id" /tmp/base.ids; then m=$((m+1)); else u=$((u+1)); fi
	done < /tmp/used.txt
	echo "✅ 映射到标准 EPG id: $m / $total"
	echo "   未映射（退回频道名）: $u / $total"
	echo -n '   tvg-id="C" 误匹配条数（须为 0）: '; grep -c 'tvg-id="C"' /tmp/m.txt
	echo "--- 央视频道抽查 ---"
	grep '^#EXTINF' /tmp/m.txt | grep -oE 'tvg-id="[^"]*" tvg-name="CCTV[0-9+]+[^"]*"' | head -6
	echo "--- CGTN/CETV 抽查（修复前会被吞成 C）---"
	grep '^#EXTINF' /tmp/m.txt | grep -oE 'tvg-id="[^"]*" tvg-name="(CGTN[^"]*|CETV[0-9])"' | sort -u
else
	echo "❌ 基准下载不完整，跳过核对"
fi

echo ""
echo "=== 8. 内存/统计 ==="
p=$(ps w | grep "[m]igu.uc" | awk '{print $1}')
[ -n "$p" ] && grep -E 'VmRSS|Threads' /proc/$p/status
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "chRequests|chCache|chFallback|streamCache|maxConns|streamTtl"
