#!/bin/sh
# deploy-141rst.sh —— 部署 migu.uc 1.4.1（拒绝路径 RST 修正）并做回归校验
set -u
NEW=/tmp/migu-141rst.uc
TGT=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.4.0-rstfix.bak

echo "=== [1] 语法检查 ==="
if /usr/bin/ucode -c -o /tmp/chk141rst.uc "$NEW"; then
	echo "  syntax OK  ($(grep -c '' $NEW) 行)"
else
	echo "  SYNTAX FAIL"; exit 1
fi

echo ""
echo "=== [2] 备份当前版本 ==="
cp "$TGT" "$BAK"
echo "  bak md5: $(md5sum "$BAK" | cut -d' ' -f1)  size=$(wc -c < "$BAK")"

echo ""
echo "=== [3] 部署 ==="
cp "$NEW" "$TGT"; chmod 755 "$TGT"
echo "  new md5: $(md5sum "$TGT" | cut -d' ' -f1)  size=$(wc -c < "$TGT")"
grep -m1 'APP_VERSION' "$TGT"

echo ""
echo "=== [4] 重启 ==="
/etc/init.d/migu restart
sleep 8
P=$(pgrep -f 'ucode.*migu.uc' | tr '\n' ' ')
if [ -n "$P" ]; then echo "  进程存活: pid=$P"; else echo "  ❌ 进程死了"; exit 1; fi

echo ""
echo "=== [5] /health ==="
curl -s -m 10 http://127.0.0.1:8788/health
echo ""

echo ""
echo "=== [6] 崩溃类日志（须全 0）==="
for pat in "not a function" "Reference error" "Syntax error" "drainQueued"; do
	echo -n "  '$pat': "; logread 2>/dev/null | grep -c "$pat"
done

echo ""
echo "=== [7] 回归：/m3u 与 /ch ==="
echo -n "  /m3u:           "; curl -s -m 25 -o /tmp/r141rst.m3u -w 'code=%{http_code} size=%{size_download} time=%{time_total}\n' http://127.0.0.1:8788/m3u
echo "  EXTINF 行数:    $(grep -c '^#EXTINF' /tmp/r141rst.m3u)"
echo -n "  /ch 冷:         "; curl -s -m 25 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://127.0.0.1:8788/ch/608807420
echo -n "  /ch 热:         "; curl -s -m 25 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://127.0.0.1:8788/ch/608807420

echo ""
echo "=== [8] 当前 maxConns（应为 64）==="
uci get migu.main.maxConns

echo ""
echo "=== [9] 内存 ==="
PP=$(pgrep -f 'ucode.*migu.uc' | head -1)
[ -n "$PP" ] && grep -E 'VmRSS|Threads' /proc/$PP/status

echo ""
echo "=== done ==="
