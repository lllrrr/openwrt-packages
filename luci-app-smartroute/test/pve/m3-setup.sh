#!/bin/sh
# M3 测试用的附加环境（可重复执行；路由器和 isp 的配置写进 UCI，客户端 netns 重启 lab-hosts 后需重跑）：
#   接口出口：router wg0(10.77.0.2/30, fd77::2/64) ⇄ isp wg0(10.77.0.1, fd77::1)，router 上 wg0 放进单独的 vpn 区域（开启伪装）
#              实验环境的 wan 区域不做伪装（isp 有回内网的路由），所以不能直接放进 wan
#              isp 回显看到的源地址为 10.77.0.2 / fd77::2 即经过隧道
#   多工作接口：router eth0.20 = guest 网段 192.168.98.1/24（isp 加回程路由）；lab-hosts 上 netns client-c(02:5a:00:00:05:0c, .98.10)
#   DoT：isp 在 8.8.8.8:853 上再开一个回显服务，能连上即未被拦截
S="ssh -F ${SSHCFG:-$HOME/.ssh/lab_config}"
R() { $S lab-router "$@" 2>/dev/null; }
I() { $S lab-isp "$@" 2>/dev/null; }

inst='if command -v apk >/dev/null; then apk add -q kmod-wireguard wireguard-tools; else opkg list-installed | grep -q ^wireguard-tools || { opkg update >/dev/null; opkg install kmod-wireguard wireguard-tools >/dev/null; }; fi'
I "$inst"; R "$inst"
R 'command -v apk >/dev/null && apk add -q luci-proto-wireguard || opkg install luci-proto-wireguard >/dev/null'   # 否则 LuCI 的接口选择框加载 wireguard.js 时 404
# 密钥只在第一次生成，之后沿用
ik=$(I 'uci -q get network.wg0.private_key || wg genkey'); rk=$(R 'uci -q get network.wg0.private_key || wg genkey')
ip=$(echo "$ik" | I 'wg pubkey'); rp=$(echo "$rk" | R 'wg pubkey')

I "uci -q delete network.wg0; uci -q delete network.wgpeer
uci set network.wg0=interface; uci set network.wg0.proto=wireguard; uci set network.wg0.private_key='$ik'; uci set network.wg0.listen_port=51820
uci add_list network.wg0.addresses=10.77.0.1/30; uci add_list network.wg0.addresses=fd77::1/64
uci set network.wgpeer=wireguard_wg0; uci set network.wgpeer.public_key='$rp'
uci add_list network.wgpeer.allowed_ips=10.77.0.2/32; uci add_list network.wgpeer.allowed_ips=fd77::2/128
z=\$(uci show firewall | sed -n \"s/^firewall\.\(@zone\[[0-9]*\]\)\.network=.*'labwan'.*/\1/p;s/^firewall\.\(@zone\[[0-9]*\]\)\.network=.*'lan'.*/\1/p\" | head -1)
uci -q del_list firewall.\$z.network=wg0; uci add_list firewall.\$z.network=wg0
uci -q delete network.guestback; uci set network.guestback=route; uci set network.guestback.interface=lan; uci set network.guestback.target=192.168.98.0/24; uci set network.guestback.gateway=10.255.0.2
uci -q delete uhttpd.dot; uci set uhttpd.dot=uhttpd; uci set uhttpd.dot.home=/www-echo; uci set uhttpd.dot.cgi_prefix=/cgi-bin; uci add_list uhttpd.dot.listen_http=8.8.8.8:853
uci commit; /etc/init.d/uhttpd restart; fw4 -q reload
/etc/init.d/network restart"   # 刚装好 wireguard 时 netifd 需要重启才认识这种协议

R "uci -q delete network.wg0; uci -q delete network.wgpeer; uci -q delete network.guest; uci -q delete dhcp.guest
uci set network.wg0=interface; uci set network.wg0.proto=wireguard; uci set network.wg0.private_key='$rk'
uci add_list network.wg0.addresses=10.77.0.2/30; uci add_list network.wg0.addresses=fd77::2/64
uci set network.wgpeer=wireguard_wg0; uci set network.wgpeer.public_key='$ip'; uci set network.wgpeer.endpoint_host=10.255.0.1; uci set network.wgpeer.endpoint_port=51820
uci add_list network.wgpeer.allowed_ips=0.0.0.0/0; uci add_list network.wgpeer.allowed_ips=::/0; uci set network.wgpeer.route_allowed_ips=0
uci set network.guest=interface; uci set network.guest.proto=static; uci set network.guest.device=eth0.20; uci add_list network.guest.ipaddr=192.168.98.1/24
uci set dhcp.guest=dhcp; uci set dhcp.guest.interface=guest; uci set dhcp.guest.ignore=1
w=\$(uci show firewall | sed -n \"s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'/\1/p\"); l=\$(uci show firewall | sed -n \"s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'/\1/p\")
uci -q del_list firewall.\$w.network=wg0
uci -q delete firewall.vpn; uci set firewall.vpn=zone; uci set firewall.vpn.name=vpn; uci add_list firewall.vpn.network=wg0
uci set firewall.vpn.input=REJECT; uci set firewall.vpn.output=ACCEPT; uci set firewall.vpn.forward=REJECT; uci set firewall.vpn.masq=1; uci set firewall.vpn.masq6=1
uci -q delete firewall.lanvpn; uci set firewall.lanvpn=forwarding; uci set firewall.lanvpn.src=lan; uci set firewall.lanvpn.dest=vpn
uci -q del_list firewall.\$l.network=guest; uci add_list firewall.\$l.network=guest
uci commit; fw4 -q reload; /etc/init.d/network restart"

$S lab-hosts 'doas sh -ec "
ip link show eth0.20 >/dev/null 2>&1 || { ip link add link eth0 name eth0.20 type vlan id 20; ip link set eth0.20 up; }
ip netns del client-c 2>/dev/null && sleep 2 || true; ip link del mv-c 2>/dev/null || true
ip netns add client-c; ip link add link eth0.20 name mv-c address 02:5a:00:00:05:0c type macvlan mode bridge; ip link set mv-c netns client-c
ip netns exec client-c sh -ec \"ip link set lo up; ip link set mv-c up; ip addr add 192.168.98.10/24 dev mv-c; ip route add default via 192.168.98.1\""' 2>/dev/null
sleep 5
echo "wg: $(R 'ping -c1 -W2 10.77.0.1 >/dev/null && echo ok || echo FAIL')  guest: $($S lab-hosts 'doas ip netns exec client-c ping -c1 -W2 192.168.98.1 >/dev/null && echo ok || echo FAIL' 2>/dev/null)  dot-echo: $(R 'wget -qO- -T3 http://8.8.8.8:853/cgi-bin/ip || echo FAIL')"
