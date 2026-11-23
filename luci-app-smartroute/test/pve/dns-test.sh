#!/bin/sh
# 出口 DNS 测试（先 sr.sh deploy；会改写 lab 的出口配置，结束时还原为 sr.sh 的默认）
#   网关 side 的 dnsmasq 把 foreign.lab 解析为 9.9.9.1，isp（扮演 8.8.8.8，经 wg0 出口 vpn）解析为 9.9.9.2，
#   主路由自己解析为 223.5.5.5。client-b 命中分流 p1（domain:foreign.lab → side），client-c 不命中任何分流
set -e
S="ssh -F ${SSHCFG:-$HOME/.ssh/lab_config}"
R() { $S lab-router "$@"; }
pass=0 fail=0
q() { # netns server extra
	$S lab-hosts "doas ip netns exec $1 dig +short +time=2 +tries=1 $2 foreign.lab A $3" 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true
}
expect() { # 说明 期望 实际
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1：$3"
	else fail=$((fail + 1)); echo "FAIL $1：期望 ${2:-无应答}，得到 ${3:-无应答}"; fi
}
both() { # 说明 期望：UDP、TCP、IPv4 / IPv6 传输各查一次（TCP 紧跟 UDP）
	expect "$1 UDP/v4" "$2" "$(q client-b @192.168.99.1)"
	expect "$1 TCP/v4" "$2" "$(q client-b @192.168.99.1 +tcp)"
	expect "$1 UDP/v6" "${3:-$2}" "$(q client-b @2001:db8:100:10::1)"
	expect "$1 TCP/v6" "${3:-$2}" "$(q client-b @2001:db8:100:10::1 +tcp)"
}
apply() { R "$1; uci commit smartroute; /etc/init.d/smartroute reload"; sleep "${2:-3}"; }

$S lab-side "uci -q del_list dhcp.@dnsmasq[0].address=/foreign.lab/9.9.9.1; uci add_list dhcp.@dnsmasq[0].address=/foreign.lab/9.9.9.1; uci commit dhcp; /etc/init.d/dnsmasq restart"
# isp 的 dnsmasq 默认只回答直连网段；实验环境的 wan 不做伪装，网关自身发往 8.8.8.8 的查询源地址是 192.168.99.3，需要放开
$S lab-isp "uci -q del_list dhcp.@dnsmasq[0].address=/foreign.lab/9.9.9.2; uci add_list dhcp.@dnsmasq[0].address=/foreign.lab/9.9.9.2; uci set dhcp.@dnsmasq[0].localservice='0'; uci commit dhcp; /etc/init.d/dnsmasq restart"
apply "uci set smartroute.side.dns='192.168.99.3'; uci set smartroute.side.fallback='vpn'; uci -q delete smartroute.side.dns_fail; uci -q delete smartroute.side.dns_fail_traffic; uci -q delete smartroute.side.dns6_none; uci -q delete smartroute.side.ipv6
	uci set smartroute.vpn=exit; uci set smartroute.vpn.type='interface'; uci set smartroute.vpn.network='wg0'; uci set smartroute.vpn.name='lab-wg'
	uci set smartroute.vpn.dns='8.8.8.8'; uci set smartroute.vpn.dns6='[2001:4860::8888]:53'; uci set smartroute.vpn.check_ip='8.8.8.8'" 10

echo "== 正常：命中的设备用网关 DNS，未命中的用主路由"
# 等规则加载完、client-b（IP 规则）的 IPv6 地址经 MAC 关联进设备组
for i in $(seq 45); do [ "$(q client-b @192.168.99.1)" = 9.9.9.1 ] && [ "$(q client-b @2001:db8:100:10::1)" = 9.9.9.1 ] && break; sleep 2; done
both "命中" 9.9.9.1
expect "未命中 client-c" 223.5.5.5 "$(q client-c @192.168.99.1)"

echo "== 网关 DNS 停止：沿故障切换链改用 vpn 的 DNS"
$S lab-side "/etc/init.d/dnsmasq stop"
sleep 16
both "回退" 9.9.9.2
expect "流量不切换" '"side"' "$(R "smartroute status" | grep -A2 '"side": {' | grep -o '"Actual": "[a-z]*"' | grep -o '"[a-z]*"$')"

echo "== dns_fail=router：交给主路由"
apply "uci set smartroute.side.dns_fail='router'"
both "router" 223.5.5.5

echo "== dns_fail=keep：仍发往网关（无应答）"
apply "uci set smartroute.side.dns_fail='keep'"
expect "keep UDP/v4" "" "$(q client-b @192.168.99.1)"

echo "== dns_fail_traffic=1：流量也切到 vpn，DNS 用 vpn 的"
apply "uci set smartroute.side.dns_fail='fallback'; uci set smartroute.side.dns_fail_traffic='1'" 16
expect "流量切换" '"vpn"' "$(R "smartroute status" | grep -A2 '"side": {' | grep -o '"Actual": "[a-z]*"' | grep -o '"[a-z]*"$')"
expect "DNS UDP/v4" 9.9.9.2 "$(q client-b @192.168.99.1)"

echo "== 网关 DNS 恢复：切回"
$S lab-side "/etc/init.d/dnsmasq start"
apply "uci -q delete smartroute.side.dns_fail_traffic" 16
both "恢复" 9.9.9.1

echo "== side 不处理 IPv6：IPv6 查询改用 vpn，IPv4 仍用网关"
apply "uci set smartroute.side.ipv6='none'" 8
both "不处理 IPv6" 9.9.9.1 9.9.9.2

echo "== 再让 vpn 也不可用：IPv6 查询被拒绝（设备应改查 IPv4）"
apply "uci set smartroute.vpn.check_ip='192.0.2.1'" 16
expect "IPv6 查询被拒绝" "" "$(q client-b @2001:db8:100:10::1)"
expect "IPv4 仍可用" 9.9.9.1 "$(q client-b @192.168.99.1)"
apply "uci set smartroute.side.dns6_none='router'"
expect "dns6_none=router：IPv6 交给主路由" 223.5.5.5 "$(q client-b @2001:db8:100:10::1)"

echo "== 网关自身的 DNS 查询与主路由的 DNS 劫持"
apply "uci -q delete smartroute.side.ipv6; uci -q delete smartroute.side.dns6_none; uci set smartroute.vpn.check_ip='8.8.8.8'" 3
gw() { $S lab-side "nslookup -type=a foreign.lab 8.8.8.8 2>/dev/null" | awk '/^Address/ && !/:53$/ {print $2}' | head -1; }
expect "开启“不被劫持”：网关查到 8.8.8.8 的结果" 9.9.9.2 "$(gw)"
apply "uci set smartroute.side.dns_nohijack='0'"
expect "关闭：被劫持到主路由" 223.5.5.5 "$(gw)"

apply "uci -q delete smartroute.side.dns_nohijack; uci -q delete smartroute.side.dns; uci -q delete smartroute.side.fallback; uci -q delete smartroute.side.dns_fail; uci -q delete smartroute.vpn"
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
