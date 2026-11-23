#!/bin/sh
# 后台回归测试（在 ./sr.sh on 之后运行；8 以后需要先跑一次 ./m3-setup.sh）
# 1-7 故障切换、经网关探测、压回 v4、拦截、域名记录持久化、netifd 重启、经出口下载
# 8-15 AAAA 屏蔽、DoT 拦截、v6 健康探测、接口出口、多工作接口、TCP 长时间空闲、网关换 link-local、v6 前缀变化
S="ssh -F ${SSHCFG:-$HOME/.ssh/lab_config}"
R() { $S lab-router "$@" 2>/dev/null; }
SIDE() { $S lab-side "$@" 2>/dev/null; }
# via <客户端> <url>：SIDE / direct / FAIL(用时)
via() {
	r=$($S lab-hosts "s=\$(date +%s%N); o=\$(doas ip netns exec $1 curl -s -m 5 $2) || o=FAIL; echo \"\$o \$(( (\$(date +%s%N)-s)/1000000 ))ms\"" 2>/dev/null)
	# side 的 v6 地址随委派前缀变化，按地址后半段（接口标识）识别
	case "$r" in 192.168.99.3*|2001:db8:100:*:5a:ff:fe00:400*) echo "SIDE";; 10.77.0.2*|fd77::2*) echo "WG";; FAIL*) echo "FAIL(${r#FAIL })";; *) echo "direct";; esac
}
# wait_for <期望（可用通配符）> <客户端> <url> <最长秒数>：返回用时
wait_for() {
	t0=$(date +%s)
	while [ $(( $(date +%s) - t0 )) -lt "$4" ]; do case "$(via "$2" "$3")" in $1) echo "$(( $(date +%s) - t0 ))s"; return;; esac; sleep 1; done
	echo "超时（${4}s 仍为 $(via "$2" "$3")）"
}
reload() { R "uci commit smartroute; /etc/init.d/smartroute reload"; sleep 3; }
# ev [n] / warns：最近 n 条事件、当前警告（把消息代码按参数展开）
st() { R 'smartroute status' | python3 -c "import json,sys; s=json.load(sys.stdin)['state']; [print('   $1', m['Fmt'].replace('%s','{}').format(*m.get('Args') or [])) for m in (s.get('$2') or [])[-${3:-9}:]]"; }
ev() { st 事件 Events "${1:-2}"; }
warns() { st 警告 Warnings; }
stat() { R 'smartroute status' | python3 -c "import json,sys; print(json.load(sys.stdin)['stats']['$1'])"; }
A4=http://8.8.8.8/cgi-bin/ip; A6=http://[2001:4860::8888]/cgi-bin/ip

echo "== 1. 故障切换：网关 side 丢弃 ICMP（探测失败、转发仍正常）"
echo "   切换前 client-a 国外 v4：$(via client-a $A4)"
SIDE 'nft add table inet srtest; nft add chain inet srtest in "{ type filter hook input priority -10; }"; nft add rule inet srtest in icmp type echo-request drop'
echo "   切到直连用时：$(wait_for direct client-a $A4 30)"
SIDE 'nft delete table inet srtest'
echo "   恢复后切回用时：$(wait_for SIDE client-a $A4 30)"
ev 2

echo "== 2. 经网关探测外部地址（check_ip=8.8.8.8；网关自身可 ping，但不转发 ICMP）"
R "uci set smartroute.side.check_ip=8.8.8.8"; reload
SIDE 'nft add table inet srtest; nft add chain inet srtest fw "{ type filter hook forward priority -10; }"; nft add rule inet srtest fw icmp type echo-request drop'
echo "   切到直连用时：$(wait_for direct client-a $A4 30)"
SIDE 'nft delete table inet srtest'
echo "   恢复后切回用时：$(wait_for SIDE client-a $A4 30)"
R "uci delete smartroute.side.check_ip"; reload

echo "== 3. 压回 v4（出口 IPv6 处理 = v4only）"
R "uci set smartroute.side.ipv6=v4only"; reload
echo "   client-a 国外 v6：$(via client-a $A6)（应快速失败）  国外 v4：$(via client-a $A4)  国内 v6：$(via client-a http://[240e::1]/cgi-bin/ip)"
R "uci delete smartroute.side.ipv6"; reload
echo "   恢复 follow 后国外 v6：$(via client-a $A6)"

echo "== 4. 拦截出口（分流 p1 出口改为 reject）"
$S lab-hosts 'doas ip netns exec client-b nslookup foreign.lab 192.168.99.1 >/dev/null' 2>/dev/null
R "uci set smartroute.p1.exit=reject"; reload
echo "   client-b → foreign.lab(223.5.5.5)：$(via client-b http://223.5.5.5/cgi-bin/ip)（应快速失败）  → 8.8.8.8：$(via client-b $A4)"
R "uci set smartroute.p1.exit=side"; reload

echo "== 5. 域名记录持久化（重启插件后仍有 foreign.lab 的记录）"
R '/etc/init.d/smartroute restart; sleep 4; logread -e smartroute | grep -E "saved [0-9]+ domain records|restored [0-9]+ domain records" | tail -2 | sed "s/^.*smartroute\[[0-9]*\]: /   /"; smartroute dns foreign.lab | grep -E "IP|TTLLeft" | tr -d " \n"; echo'

echo "== 6. netifd 重启（br-lan 重建）后自动重新挂载"
R '(sleep 1; /etc/init.d/network restart) >/dev/null 2>&1 &' ; sleep 25
echo "   client-a 国外 v4：$(wait_for SIDE client-a $A4 40)  国外 v6：$(wait_for SIDE client-a $A6 40)"

echo "== 7. 经出口下载数据文件（download_exit=side，按网关收包量判断）"
R "uci set smartroute.main.download_exit=side; uci set smartroute.main.geoip_url=http://10.255.0.1/geoip.dat; uci set smartroute.main.geosite_url=http://10.255.0.1/geosite.dat; uci commit smartroute; rm -f /usr/share/smartroute/geoip.dat"
a=$(SIDE 'cat /sys/class/net/eth0/statistics/rx_bytes')
R 'smartroute update' | tail -1
b=$(SIDE 'cat /sys/class/net/eth0/statistics/rx_bytes')
echo "   网关收到 $(( (b-a)/1048576 ))MB（geoip.dat 约 16MB）"
R "uci delete smartroute.main.download_exit; uci commit smartroute"

echo "== 8. AAAA 屏蔽（出口 side 设为压回 v4；client-b 查询命中 p1 的 foreign.lab）"
R "uci set smartroute.side.ipv6=v4only"; reload
a=$(stat aaaa_blocked)
q() { $S lab-hosts "doas ip netns exec client-b nslookup -type=$1 foreign.lab 192.168.99.1 2>&1 | grep -c -E '240e::1|223.5.5.5'" 2>/dev/null; }
echo "   AAAA 应答条数：$(q AAAA)（应为 0）  A 应答条数：$(q A)（应为 1）  aaaa_blocked +$(( $(stat aaaa_blocked) - a ))"
R "uci delete smartroute.side.ipv6"; reload
echo "   恢复 follow 后 AAAA 应答条数：$(q AAAA)（应为 1）"

echo "== 9. 拦截 DoT（block_dot=1；isp 的 8.8.8.8:853 上有回显服务）"
D=http://8.8.8.8:853/cgi-bin/ip
echo "   拦截前 client-b → 853：$(via client-b $D)"
R "uci set smartroute.main.block_dot=1"; reload
echo "   拦截后 client-b → 853：$(via client-b $D)（应快速失败）  → 80：$(via client-b $A4)"
R "uci delete smartroute.main.block_dot"; reload
echo "   关闭后 client-b → 853：$(via client-b $D)"

echo "== 10. v6 健康探测（check_ip6=240e::1，与测试目标不同：探测地址本身始终经网关；网关只丢弃转发的 ICMPv6 回显请求）"
R "uci set smartroute.side.check_ip6=240e::1"; reload
SIDE 'nft add table inet srtest; nft add chain inet srtest fw "{ type filter hook forward priority -10; }"; nft add rule inet srtest fw icmpv6 type echo-request drop'
echo "   v6 被拒绝用时：$(wait_for 'FAIL*' client-a $A6 30)"
sleep 3; echo "   client-a 国外 v6：$(via client-a $A6)（应快速失败）  国外 v4：$(via client-a $A4)（应为 SIDE）"
SIDE 'nft delete table inet srtest'
echo "   恢复后 v6 切回用时：$(wait_for SIDE client-a $A6 30)"
ev 2
R "uci delete smartroute.side.check_ip6"; reload

echo "== 11. 接口出口（wg0，所在区域 vpn 开启伪装；p0 出口改为 wg）"
R "uci set smartroute.wg=exit; uci set smartroute.wg.name=wg-isp; uci set smartroute.wg.type=interface; uci set smartroute.wg.network=wg0; uci set smartroute.p0.exit=wg"; reload
echo "   client-a 国外 v4：$(via client-a $A4)  国外 v6：$(via client-a $A6)（都应为 WG）  国内 v4：$(via client-a http://223.5.5.5/cgi-bin/ip)"
R "uci set firewall.vpn.masq=0; uci commit firewall; fw4 -q reload"; reload
echo "   vpn 区域关闭伪装后的警告："; warns | grep -i masquerad
R "uci set firewall.vpn.masq=1; uci commit firewall; fw4 -q reload"
R "uci set smartroute.p0.exit=side; uci delete smartroute.wg"; reload

echo "== 12. 多工作接口（br-lan + eth0.20；client-c 在 guest 网段，加入设备组 A）"
C4() { $S lab-hosts "doas ip netns exec client-c curl -s -m 5 $1 || echo FAIL" 2>/dev/null | cut -d' ' -f1; }
R "uci set smartroute.dc=device; uci set smartroute.dc.name=client-c; uci set smartroute.dc.mac=02:5a:00:00:05:0c; uci add_list smartroute.dc.group=ga"; reload
echo "   只挂 br-lan：client-c 国外 v4 源地址 $(C4 $A4)（应为 192.168.98.10，直连）"
R "uci add_list smartroute.main.interface=br-lan; uci add_list smartroute.main.interface=eth0.20"; reload
echo "   加上 eth0.20：client-c 国外 v4 源地址 $(C4 $A4)（应为 192.168.99.3）  国内 v4 $(C4 http://223.5.5.5/cgi-bin/ip)（应为 192.168.98.10）"
R "uci delete smartroute.main.interface; uci delete smartroute.dc"; reload

echo "== 13. TCP 长时间空闲（UDP 空闲超时改为 10 秒；client-a 的 TCP 连接中途空闲 20 秒）"
R "uci set smartroute.main.idle_timeout=10"; reload
r=$($S lab-hosts "(printf 'GET /cgi-bin/ip HTTP/1.0\r\n'; sleep 20; printf '\r\n'; sleep 2) | doas ip netns exec client-a nc 8.8.8.8 80 | tail -1" 2>/dev/null)
echo "   空闲 20 秒后的应答：${r:-无应答}（源地址应为 192.168.99.3）"
R "uci delete smartroute.main.idle_timeout"; reload


echo "== 14. 网关换了 link-local 地址（插件运行中改成随机地址，再改回 EUI-64；不重启插件）"
ll() { R 'smartroute status' | grep -o '"LL": "[^"]*"' | cut -d'"' -f4; }
SIDE 'ip -6 addr del fe80::5a:ff:fe00:400/64 dev br-lan; ip -6 addr add fe80::9c3e:71ff:a2d4:5b18/64 dev br-lan'
R 'ip -6 neigh flush dev br-lan'   # 模拟邻居缓存过期，否则旧地址仍能按缓存的 MAC 送达
# 网关重启换地址后会发 RS、DNS 等报文，路由器借此学到它的新地址；side 不应答组播 ping，这里用一次 ping 路由器代替
SIDE 'sleep 2; ping -6 -c1 -W1 fe80::5a:ff:fe00:200%br-lan >/dev/null'
echo "   改成随机地址后 v6 恢复经网关用时：$(wait_for SIDE client-a $A6 90)  下一跳 $(ll)"
SIDE 'ip -6 addr del fe80::9c3e:71ff:a2d4:5b18/64 dev br-lan; ip -6 addr add fe80::5a:ff:fe00:400/64 dev br-lan'
R 'ip -6 neigh flush dev br-lan'; SIDE 'sleep 2; ping -6 -c1 -W1 fe80::5a:ff:fe00:200%br-lan >/dev/null'; sleep 3; echo "   改回 EUI-64 后 v6 恢复经网关用时：$(wait_for SIDE client-a $A6 90)  下一跳 $(ll)"

echo "== 15. v6 前缀变化（委派前缀 2001:db8:100:10::/60 → :20::/60；不重启插件）"
I() { $S lab-isp "$@" 2>/dev/null; }
tr6() { R "smartroute trace 02:5a:00:00:05:0a $1" | grep -o '"Note": "[^"]*"\|"Exit": "[^"]*"' | tr '\n' ' '; }
I 'ip -6 route replace 2001:db8:100:20::/60 via fe80::5a:ff:fe00:201 dev br-lan'
R 'uci set network.labpd.ip6prefix=2001:db8:100:20::/60; uci commit network; /etc/init.d/network reload'
t0=$(date +%s); new=""
while [ $(( $(date +%s) - t0 )) -lt 60 ] && [ -z "$new" ]; do sleep 2; new=$($S lab-hosts "doas ip netns exec client-a ip -6 addr show dev mv-a scope global | grep -o '2001:db8:100:20[0-9a-f:]*' | head -1" 2>/dev/null); done
echo "   client-a 新地址 ${new:-未取得}（$(( $(date +%s) - t0 ))s）  经网关：$(wait_for SIDE client-a $A6 30)"
echo "   访问路由器新 LAN 地址 2001:db8:100:20::1：$(tr6 2001:db8:100:20::1)（应为 protected / direct）"
R 'uci set network.labpd.ip6prefix=2001:db8:100:10::/60; uci commit network; /etc/init.d/network reload'
I 'ip -6 route del 2001:db8:100:20::/60'
sleep 10; echo "   恢复原前缀后经网关：$(wait_for SIDE client-a $A6 60)"
