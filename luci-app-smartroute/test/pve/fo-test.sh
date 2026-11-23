#!/bin/sh
# 流量卸载 + 规则变更测试（client-a 以 3MB/s 下载 isp 上的 40MB 文件，用 side 的 eth0 收包量判断走向）
# 用法: ./fo-test.sh            卸载开/关两种状态各跑一遍
S="ssh -F ${SSHCFG:-$HOME/.ssh/lab_config}"; P=${P:-$(dirname "$0")/sr.sh}; T=$(mktemp)
rx()  { $S lab-side 'cat /sys/class/net/eth0/statistics/rx_bytes' 2>/dev/null; }
off() { $S lab-router "uci set firewall.@defaults[0].flow_offloading=$1; uci commit firewall; fw4 -q reload" 2>/dev/null; }
dl()  { $S lab-hosts "doas ip netns exec client-a curl -s -o /dev/null -w 'exit=%{exitcode} %{size_download}B' -m 60 --limit-rate 3M $1" 2>/dev/null; }
# case <名称> <url> <开始前动作> <下载中动作>
case_() {
	$P $3 >/dev/null 2>&1; a=$(rx); dl "$2" >$T & sleep 4; [ -n "$4" ] && $P $4 >/dev/null 2>&1; wait; b=$(rx)
	printf '  %-34s %-26s side 收到 %sMB\n' "$1" "$(cat $T)" $(( (b-a)/1048576 ))
}
echo "router: $($S lab-router 'grep DISTRIB_RELEASE /etc/openwrt_release' 2>/dev/null)"
for fo in 1 0; do
	off $fo; echo "== flow_offloading=$fo"
	case_ "v4 国外，规则开"              http://8.8.8.8/big            on ""
	case_ "v6 国外，规则开"              "http://[2001:4860::8888]/big" on ""
	case_ "中途开启规则（旧直连应不断）"  http://8.8.8.8/big            off on
	case_ "中途移出名单（经网关的旧连接应不断）" http://8.8.8.8/big            on unselect
done
off 1; $P on >/dev/null 2>&1; rm -f $T
