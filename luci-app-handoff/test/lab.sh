#!/bin/sh
# handoff（多网关版）在 smartroute 的 PVE 实验环境上的测试（在管理机上运行）。
# 拓扑见 luci-app-smartroute/test/pve/README.md：router 192.168.99.1，网关 side 192.168.99.3，
# 客户端 client-a(.10) / client-b(.11)；isp 上 223.5.5.5、240e::1 扮演国内，8.8.8.8、2001:4860::8888 扮演国外。
# 多网关：side 是唯一真网关；b=192.168.99.4 不存在，专门用来测「备用网关」。
# 测试前先停掉 router 上的 smartroute。用法：SSHCFG=.../ssh_config sh test/lab.sh
cd "$(dirname "$0")/.." || exit 1
S="ssh -F ${SSHCFG:-$HOME/.ssh/lab_config}"
GW=192.168.99.3 GW6=2001:db8:100:10:5a:ff:fe00:400 MAC_B=02:5a:00:00:05:0b
B=192.168.99.4
fail=0

r() { $S lab-router "$@"; }
side() { $S lab-side "$@"; }
# 访问回显服务：SIDE = 经网关，direct = 不经网关，FAIL = 不通
via() {
	local src
	src=$($S lab-hosts "doas ip netns exec $1 curl -s -m 4 $2" 2>/dev/null | awk '{ print $1 }')
	case $src in '') echo FAIL ;; $GW | $GW6) echo SIDE ;; *) echo direct ;; esac
}
# side.test 只有网关的 DNS 认识：查到 = DNS 被转给了网关
dns() {
	$S lab-hosts "doas ip netns exec $1 nslookup -type=a side.test $2" 2>/dev/null | grep -q 10.9.9.9 && echo GW || echo LOCAL
}
expect() { # 名称 实际 期望
	if [ "$2" = "$3" ]; then echo "ok   $1：$2"; else echo "FAIL $1：$2（期望 $3）"; fail=1; fi
}
matrix() { # 客户端 国内v4 国外v4 国内v6 国外v6 DNS@v4 DNS@v6 DNS@写死的8.8.8.8
	expect "$1 223.5.5.5" "$(via $1 http://223.5.5.5/cgi-bin/ip)" "$2"
	expect "$1 8.8.8.8" "$(via $1 http://8.8.8.8/cgi-bin/ip)" "$3"
	expect "$1 [240e::1]" "$(via $1 'http://[240e::1]/cgi-bin/ip')" "$4"
	expect "$1 [2001:4860::8888]" "$(via $1 'http://[2001:4860::8888]/cgi-bin/ip')" "$5"
	expect "$1 DNS 192.168.99.1" "$(dns $1 192.168.99.1)" "$6"
	expect "$1 DNS 2001:db8:100:10::1" "$(dns $1 2001:db8:100:10::1)" "$7"
	expect "$1 DNS 8.8.8.8" "$(dns $1 8.8.8.8)" "$8"
}
# 连续 3 次失败才切换。多网关版每轮把各网关的 v4、v6 一起并行检测：最坏 ping 2 秒 + 间隔 2 秒 ≈ 4 秒，
# 3 轮 ≈ 12 秒，20 秒留足余量（比以前串行检测时短）
settle() { sleep 20; }
# 网关段：段名 显示名 ip ip6 fallback
gw() {
	r "uci set handoff.$1=gateway
		uci set handoff.$1.name='$2'; uci set handoff.$1.ip='$3'; uci set handoff.$1.ip6='$4'
		uci set handoff.$1.dns_port='53'; uci set handoff.$1.probe=''; uci set handoff.$1.fallback='$5'
		uci commit handoff"
}
# 规则段：段名 去向（全部设备、GeoIP cn 取反）
rule() {
	r "uci set handoff.$1=rule; uci set handoff.$1.name='$1'
		uci -q del_list handoff.$1.geoip=cn; uci add_list handoff.$1.geoip=cn
		uci set handoff.$1.invert='1'; uci set handoff.$1.target='$2'; uci commit handoff"
}
reload() { r "/etc/init.d/handoff reload"; }
J() { r "handoff status --json | jsonfilter -e '$1'" 2>/dev/null; }

echo "== 部署"
for f in usr/sbin/handoff etc/init.d/handoff; do r "cat > /$f && chmod +x /$f" <root/$f; done
r "[ -f /etc/config/handoff ] || cat > /etc/config/handoff" <root/etc/config/handoff
side "nft delete table inet labdown 2>/dev/null; uci -q get dhcp.@dnsmasq[0].address | grep -q side.test || {
	uci add_list dhcp.@dnsmasq[0].address=/side.test/10.9.9.9; uci commit dhcp; /etc/init.d/dnsmasq restart; }"
r "while uci -q delete handoff.@rule[0]; do :; done
	while uci -q delete handoff.@gateway[0]; do :; done
	while uci -q delete handoff.@group[0]; do :; done
	while uci -q delete handoff.@ipgroup[0]; do :; done
	uci set handoff.main.enabled=1; uci set handoff.main.lan=lan; uci set handoff.main.interval=2
	uci commit handoff"
gw side side $GW $GW6 direct
rule rside side
r "/etc/init.d/handoff enable; /etc/init.d/handoff restart
	for i in \$(seq 30); do handoff status | grep -q '^GeoIP cn' && nft list chain inet handoff decide | grep -q g_cn && break; sleep 2; done
	handoff status"

echo "== 正常：国外交给网关，DNS 都给网关"
for c in client-a client-b; do matrix $c direct SIDE direct SIDE GW GW GW; done

echo "== 改规则不影响已有连接（流量卸载开启，限速下载 40MB 中途加规则）"
$S lab-hosts "doas ip netns exec client-a curl -s -m 30 --limit-rate 8M -o /dev/null -w '%{size_download}' http://8.8.8.8/big >/dev/shm/gwr-big" 2>/dev/null &
sleep 2
r "uci set handoff.kids=group; uci add_list handoff.kids.mac=$MAC_B
	uci set handoff.rkids=rule; uci set handoff.rkids.name=kids; uci set handoff.rkids.group=kids; uci set handoff.rkids.target=direct
	uci reorder handoff.rkids=1; uci commit handoff; /etc/init.d/handoff reload"
wait
expect "下载完整" "$($S lab-hosts 'cat /dev/shm/gwr-big; rm -f /dev/shm/gwr-big' 2>/dev/null)" 41943040

echo "== 设备组：client-b 先命中「直连、任何目标」，DNS 也留在本机"
matrix client-a direct SIDE direct SIDE GW GW GW
matrix client-b direct direct direct direct LOCAL LOCAL LOCAL
r "uci delete handoff.kids; uci delete handoff.rkids; uci commit handoff"
reload

echo "== 目标 IP 组：8.8.8.8 直连，v4 的组不影响 v6（2001:4860::8888 仍 SIDE），DNS 仍全给网关"
# uci reorder 的位置按整个文件里所有段的先后数（从 0），1 = 紧跟 main，也就是排在 rside 之前
r "uci set handoff.gdns=ipgroup; uci set handoff.gdns.name='gdns'
	uci -q del_list handoff.gdns.ip=8.8.8.8; uci add_list handoff.gdns.ip=8.8.8.8
	uci set handoff.rgdns=rule; uci set handoff.rgdns.name='rgdns'
	uci -q del_list handoff.rgdns.ipgroup=gdns; uci add_list handoff.rgdns.ipgroup=gdns
	uci set handoff.rgdns.target='direct'
	uci reorder handoff.rgdns=1; uci commit handoff"
reload
matrix client-a direct direct direct SIDE GW GW GW

echo "== 目标 IP 组：给 gdns 加上 2001:4860::8888，v6 国外也直连"
r "uci add_list handoff.gdns.ip='2001:4860::8888'; uci commit handoff"
reload
matrix client-a direct direct direct direct GW GW GW

echo "== 删掉 IP 组和规则：回到只按 GeoIP"
r "uci delete handoff.rgdns; uci delete handoff.gdns; uci commit handoff"
reload
matrix client-a direct SIDE direct SIDE GW GW GW

echo "== IP 组不存在：整条规则跳过（warn），矩阵与正常场景相同"
r "uci set handoff.rbad=rule; uci set handoff.rbad.name='bad-ipgroup'
	uci -q del_list handoff.rbad.ipgroup=nosuch; uci add_list handoff.rbad.ipgroup=nosuch
	uci set handoff.rbad.invert='1'; uci set handoff.rbad.target='side'
	uci reorder handoff.rbad=1; uci commit handoff"
reload
expect "warn：引用不存在的 IP 组" "$(r "for i in \$(seq 5); do logread | grep -q 'IP 组 nosuch 不存在' && echo found && break; sleep 1; done")" found
expect "坏规则没进 nft" "$(r "nft list chain inet handoff decide | grep -c i_nosuch")" 0
matrix client-a direct SIDE direct SIDE GW GW GW
r "uci delete handoff.rbad; uci commit handoff"
reload

echo "== 备用网关：规则交给不通的 b（b 的 fallback=side）→ 国外改走 side，DNS 也到 side"
gw b b $B '' side
rule rside b
reload
settle
matrix client-a direct SIDE direct SIDE GW GW GW
r "handoff status"

echo "== status --json：一行 JSON，b 的 up=false、via=side（b 没设 ip6，up6 应为 null，肉眼看输出）"
r "handoff status --json"
expect "JSON 是一行" "$(r "handoff status --json" | wc -l)" 1
expect "JSON running" "$(J @.running)" true
expect "JSON 网关顺序" "$(J '@.gateways[*].id' | tr '\n' ' ')" "side b "
expect "JSON up" "$(J '@.gateways[*].up' | tr '\n' ' ')" "true false "
expect "JSON via" "$(J '@.gateways[*].via' | tr '\n' ' ')" "side side "

echo "== 备用网关也不通、fallback=direct → 国外直连，DNS 留本机"
r "uci set handoff.b.fallback=direct; uci commit handoff"
reload
settle
matrix client-a direct direct direct direct LOCAL LOCAL LOCAL

echo "== 回到只给 side"
r "uci set handoff.rside.target=side; uci delete handoff.b; uci commit handoff"
reload
settle
matrix client-a direct SIDE direct SIDE GW GW GW

echo "== 网关 IPv6 不通：交给网关的 v6 拒绝（设备回退 v4），v6 DNS 拒绝"
side "nft -f - <<-'EOF'
	table inet labdown {
		chain i { type filter hook input priority -10; policy accept; icmpv6 type echo-request drop; }
		chain f { type filter hook forward priority -10; policy accept; meta nfproto ipv6 drop; }
	}
	EOF"
settle
matrix client-a direct SIDE direct FAIL GW LOCAL GW
r "handoff status"

echo "== 网关整体不通：全部直连，DNS 回到本机"
side "nft delete table inet labdown; nft -f - <<-'EOF'
	table inet labdown {
		chain i { type filter hook input priority -10; policy accept; icmp type echo-request drop; icmpv6 type echo-request drop; }
		chain f { type filter hook forward priority -10; policy drop; }
	}
	EOF"
settle
matrix client-a direct direct direct direct LOCAL LOCAL LOCAL
r "handoff status"

echo "== 网关恢复"
side "nft delete table inet labdown"
settle
matrix client-a direct SIDE direct SIDE GW GW GW

echo "== 没设置网关 IPv6：同 IPv6 不通"
r "uci delete handoff.side.ip6; uci commit handoff"
reload
settle
matrix client-a direct SIDE direct FAIL GW LOCAL GW
r "uci set handoff.side.ip6=$GW6; uci commit handoff"
reload

[ $fail = 0 ] && echo "全部通过" || echo "有失败项"
exit $fail
