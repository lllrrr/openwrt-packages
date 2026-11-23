#!/bin/sh
# 在 lab-hosts（Alpine）上用 netns + macvlan 造出两个客户端，各有独立 MAC：
#   client-a 02:5a:00:00:05:0a 192.168.99.10  启用 v6 临时隐私地址（模拟手机/电脑）
#   client-b 02:5a:00:00:05:0b 192.168.99.11  对照组
# v6 地址由 router 的 RA 经 SLAAC 生成。用法: doas sh hosts-setup.sh
set -e
apk add -q curl iproute2 >/dev/null
for c in a b; do
	ns=client-$c; ip=192.168.99.1$([ $c = a ] && echo 0 || echo 1)
	ip netns del $ns 2>/dev/null && sleep 2 || true   # netns 销毁是异步的，旧 macvlan 还在时同 MAC 的新接口起不来
	ip link del mv-$c 2>/dev/null || true
	ip netns add $ns
	ip link add link eth0 name mv-$c address 02:5a:00:00:05:0$c type macvlan mode bridge
	ip link set mv-$c netns $ns
	ip netns exec $ns sh -ec "
		sysctl -qw net.ipv6.conf.all.use_tempaddr=$([ $c = a ] && echo 2 || echo 0)
		sysctl -qw net.ipv6.conf.default.use_tempaddr=$([ $c = a ] && echo 2 || echo 0)
		sysctl -qw net.ipv6.conf.mv-$c.use_tempaddr=$([ $c = a ] && echo 2 || echo 0)
		ip link set lo up
		ip link set mv-$c up
		ip addr add $ip/24 dev mv-$c
		ip route add default via 192.168.99.1"
done
sleep 4
for c in a b; do echo "client-$c: $(ip netns exec client-$c ip -br a show mv-$c)"; done
