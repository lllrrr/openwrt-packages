#!/bin/sh
# 验证并发上限真的会返回 503（这是唯一还没实测过的分支）
echo '=== 把 maxConns 临时降到下限 4 ==='
uci set migu.main.maxConns='4'
uci commit migu
/etc/init.d/migu restart >/dev/null 2>&1
sleep 6
curl -s http://127.0.0.1:8788/health | tr ',' '\n' | grep -E 'maxConns|activeConns'

echo
echo '=== 同时打开 6 条慢连接（占用事件循环），再从第 7 条发起请求 ==='
# 用 shell 后台起 6 个 curl：每个请求一个会走冷解析的频道，解析要 ~0.5-1s，
# 期间连接保持在 connections 数组里
i=0
while [ $i -lt 6 ]; do
  # 用不同 pid 且清掉缓存不易，改用 sleep 型慢客户端：连上后不读，占住 fd
  (printf 'GET /m3u HTTP/1.1\r\nHost: x\r\n\r\n'; sleep 4) | nc 127.0.0.1 8788 >/dev/null 2>&1 &
  i=$((i+1))
done
sleep 1
echo "占位期间 activeConns: $(curl -s http://127.0.0.1:8788/health | tr ',' '\n' | grep activeConns)"

echo
echo '=== 超限请求应得到 503 ==='
curl -s -o /tmp/busy.txt -m 10 -w 'code=%{http_code}\n' http://127.0.0.1:8788/m3u
echo "响应体: $(cat /tmp/busy.txt)"

echo
echo '=== rejectedByLimit 计数 ==='
curl -s http://127.0.0.1:8788/health | tr ',' '\n' | grep -E 'rejectedByLimit|activeConns'

wait 2>/dev/null
sleep 3
echo
echo '=== 连接释放后应恢复 ==='
curl -s -o /dev/null -w 'code=%{http_code} time=%{time_total}s\n' http://127.0.0.1:8788/m3u
echo "释放后 activeConns: $(curl -s http://127.0.0.1:8788/health | tr ',' '\n' | grep activeConns)"

echo
echo '=== 复原 maxConns=64 ==='
uci set migu.main.maxConns='64'
uci commit migu
/etc/init.d/migu restart >/dev/null 2>&1
sleep 6
curl -s http://127.0.0.1:8788/health | tr ',' '\n' | grep -E 'maxConns|activeConns|version'
