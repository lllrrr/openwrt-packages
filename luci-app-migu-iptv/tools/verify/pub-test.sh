#!/bin/sh
echo '=== 发夹 NAT 从 WAN 地址访问 ==='
WAN=${WAN_IP}
curl -s -o /dev/null -m 8 -w 'WAN 无令牌 /m3u          -> %{http_code}\n' "http://$WAN:8788/m3u"
curl -s -o /dev/null -m 8 -w 'WAN 错令牌 /m3u?token=bad -> %{http_code}\n' "http://$WAN:8788/m3u?token=bad"
curl -s -o /dev/null -m 8 -w 'WAN 对令牌 /TOKEN/m3u    -> %{http_code}\n' "http://$WAN:8788/${PUBLIC_TOKEN}/m3u"

echo
echo '=== 模拟非本机来源：用 LAN 里不存在的地址做源不行，改看历史日志证据 ==='
logread | grep -iE '拒绝|denied' | tail -10

echo
echo '=== health 计数 ==='
curl -s http://127.0.0.1:8788/health | tr ',' '\n' | grep -E 'denied|rejected'

echo
echo '=== isLocalPeer 判定表（对照代码逻辑用 nft/ip 验证本机看到的来源）==='
ip -4 addr show | grep -E 'inet ' | head -5
