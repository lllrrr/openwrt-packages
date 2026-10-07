#!/bin/sh
# 验证：把 epgUrl 显式设为空串，EPG 到底会不会被关闭？
# 界面文案写的是「留空 EPG 来源即可关闭映射」，这里实测这条说法是否成立。
echo "=== 1) 设 epgUrl 为空串 ==="
uci set migu.main.epgUrl=''
uci commit migu
uci -q get migu.main.epgUrl
echo "(上面应为空行)"
echo ""
echo "=== 2) uci 里该选项的实际存储 ==="
grep -n 'epgUrl' /etc/config/migu || echo "  (uci 文件中没有 epgUrl 这一行)"

echo ""
echo "=== 3) 重启服务 ==="
/etc/init.d/migu restart >/dev/null 2>&1
sleep 14

echo ""
echo "=== 4) 空串时 EPG 是否仍然生效 ==="
curl -s http://127.0.0.1:8788/health | tr -d '\n\t' | sed 's/,"/,\n"/g' | grep -E 'epgEnabled|epgUrl|epgIds|epgOk'

echo ""
echo "=== 5) 再试：显式删除该选项 ==="
uci -q delete migu.main.epgUrl
uci commit migu
grep -c 'epgUrl' /etc/config/migu
/etc/init.d/migu restart >/dev/null 2>&1
sleep 14
curl -s http://127.0.0.1:8788/health | tr -d '\n\t' | sed 's/,"/,\n"/g' | grep -E 'epgEnabled|epgUrl|epgIds|epgOk'

echo ""
echo "=== 6) 对照：靠 epgRefreshHours=0 能否真正关闭 ==="
uci set migu.main.epgRefreshHours='0'
uci commit migu
/etc/init.d/migu restart >/dev/null 2>&1
sleep 14
curl -s http://127.0.0.1:8788/health | tr -d '\n\t' | sed 's/,"/,\n"/g' | grep -E 'epgEnabled|epgIds|epgOk'
echo ""
echo "=== 7) 复原 ==="
uci -q delete migu.main.epgRefreshHours
uci -q delete migu.main.epgUrl
uci commit migu
grep -c 'epgUrl' /etc/config/migu
/etc/init.d/migu restart >/dev/null 2>&1
sleep 14
curl -s http://127.0.0.1:8788/health | tr -d '\n\t' | sed 's/,"/,\n"/g' | grep -E 'epgEnabled|epgIds|epgOk'
