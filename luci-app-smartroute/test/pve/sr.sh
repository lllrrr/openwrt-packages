#!/bin/sh
# M1 整体验证：把 Go 后台部署到 lab-router，用 UCI 配置下面两条测试分流（与 ebpf 验证时相同，“国内”改用真实 geoip:cn）
#   p0. 设备组 A（client-a，MAC 规则）× 国内 取反 → 网关 side
#   p1. 设备 client-b（IP 规则 192.168.99.11，IPv6 经关联 MAC）× domain:foreign.lab → 网关 side
#   另有一个未被引用的大规则组（geosite:cn + geolocation-!cn），用来测内存
# 用法: ./sr.sh deploy [dat 目录] | on | off | unselect | dns | status
#   deploy 前在开发机编译: CGO_ENABLED=0 GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o smartroute ./cmd/smartroute
#   on/off/unselect 供 fo-test.sh 使用
set -e
S="ssh -F ${SSHCFG:-$HOME/.ssh/lab_config}"; D=$(cd "$(dirname "$0")/../.." && pwd)
R() { $S lab-router "$@"; }
# 等后台应用完配置：操作前删掉状态文件，应用后会重新生成
CLR='rm -f /var/run/smartroute/state.json'
WAIT='for i in $(seq 30); do [ -e /var/run/smartroute/state.json ] && exit 0; sleep 1; done; echo "等待超时"; logread -e smartroute | tail -5; exit 1'

case "$1" in
deploy)
	[ -f "$D/smartroute" ] && R 'cat > /usr/bin/smartroute.new && chmod +x /usr/bin/smartroute.new && mv /usr/bin/smartroute.new /usr/bin/smartroute' < "$D/smartroute"
	tar c -C "$D/openwrt/smartroute/files" --exclude=./etc/config . | R 'tar x -C / && sh /etc/uci-defaults/90-smartroute'
	tar c -C "$D/luci/htdocs" . | R 'tar x -C /www'
	python3 "$D/scripts/i18n.py" lmo "$D/luci/po/zh_Hans/smartroute.po" /tmp/smartroute.zh-cn.lmo >/dev/null
	R 'cat > /usr/lib/lua/luci/i18n/smartroute.zh-cn.lmo' < /tmp/smartroute.zh-cn.lmo
	tar c -C "$D/luci/root" . | R 'tar x -C / && rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache && /etc/init.d/rpcd reload'
	# dns 测试用：路由器 dnsmasq 把 foreign.lab 解析到 223.5.5.5 / 240e::1
	R 'for a in /foreign.lab/223.5.5.5 /foreign.lab/240e::1; do uci -q del_list dhcp.@dnsmasq[0].address=$a; uci add_list dhcp.@dnsmasq[0].address=$a; done; [ -z "$(uci changes dhcp)" ] || { uci commit dhcp; /etc/init.d/dnsmasq restart; }'
	[ -z "$2" ] || tar c -C "$2" geosite.dat geoip.dat | R 'mkdir -p /usr/share/smartroute && tar x -C /usr/share/smartroute'
	echo deployed ;;
on)
	R "$CLR; cat > /etc/config/smartroute && /etc/init.d/smartroute reload; $WAIT" <<'EOF'
config global 'main'
	option enabled '1'
	option update_hour '-1'

config group 'ga'
	option name '设备组 A'

config group 'gb'
	option name '设备组 B'

config device 'da'
	option name 'client-a'
	option mac '02:5a:00:00:05:0a'
	list group 'ga'

config device 'db'
	option name 'client-b'
	option ip '192.168.99.11'
	list group 'gb'

config rule_group 'cn'
	option name '国内'
	list rule 'geoip:cn'

config rule_group 'fl'
	option name '测试域名'
	list rule 'domain:foreign.lab'

config rule_group 'big'
	option name '大规则组'
	list rule 'geosite:cn'
	list rule 'geosite:geolocation-!cn'

config exit 'side'
	option name 'lab-side'
	option ip '192.168.99.3'

config policy 'p0'
	list source 'ga'
	list rule_group 'cn'
	option invert '1'
	option exit 'side'

config policy 'p1'
	list source 'db'
	list rule_group 'fl'
	option exit 'side'
EOF
	echo "sr on ($(R 'grep DISTRIB_RELEASE /etc/openwrt_release'))" ;;
off) R '/etc/init.d/smartroute stop; for i in $(seq 30); do [ -e /var/run/smartroute.pid ] || exit 0; sleep 1; done; exit 1'; echo "sr off" ;;
unselect) R "$CLR; uci del_list smartroute.da.group=ga && uci commit smartroute && /etc/init.d/smartroute reload; $WAIT"; echo "client-a unselected" ;;
dns) $S lab-hosts 'doas ip netns exec client-b nslookup foreign.lab 192.168.99.1 >/dev/null; for u in http://223.5.5.5/cgi-bin/ip http://[240e::1]/cgi-bin/ip http://8.8.8.8/cgi-bin/ip; do
	echo "client-b $u $(doas ip netns exec client-b curl -s -m 3 $u || echo FAIL)"; done' 2>/dev/null ;;
status) R 'smartroute status' ;;
*) echo "usage: $0 deploy [dat 目录]|on|off|unselect|dns|status"; exit 1 ;;
esac
