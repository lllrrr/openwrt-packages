#!/bin/sh
echo "=== 保存后 uci ==="
cat /etc/config/migu
echo ""
echo "=== 关键值核对 ==="
for k in userId token publicToken externalSources epgUrl streamTtl failTtl maxConns epgRefreshHours warmRecent; do
	v=$(uci -q get migu.main.$k)
	printf '%-18s = %s\n' "$k" "$v"
done
echo ""
echo "=== md5 对比 ==="
md5sum /etc/config/migu
echo "(保存前 md5 是 d61bda0c30205747a7fabb5e2f87ab6b)"
echo ""
echo "=== 服务是否被自动重启 ==="
/etc/init.d/migu status 2>&1 | head -2
curl -s http://127.0.0.1:8788/health | tr -d '\n\t ' | head -c 400
echo ""
