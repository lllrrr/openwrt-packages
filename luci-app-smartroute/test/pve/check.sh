#!/bin/sh
# 测试矩阵（在管理机上运行，经 ssh 跳到 lab-hosts）：客户端访问 isp 上的“国内/国外”回显服务
# 回显的源地址 = side 的地址 → 经过网关（SIDE）；= 客户端自己 → 直连
S="ssh -F ${SSHCFG:-$HOME/.ssh/lab_config}"
side=$($S lab-side 'ip -o addr show br-lan | awk "{print \$4}" | cut -d/ -f1 | grep -v ^fe80' 2>/dev/null | tr '\n' ' ')
$S lab-hosts "for c in client-a client-b; do for u in http://223.5.5.5/cgi-bin/ip http://8.8.8.8/cgi-bin/ip http://[240e::1]/cgi-bin/ip http://[2001:4860::8888]/cgi-bin/ip; do
	r=\$(doas ip netns exec \$c curl -s -m 3 \$u || echo FAIL); echo \"\$c \$u \$r\"; done; done" 2>/dev/null |
while read c u src arrow dst; do
	via=direct; [ "$src" = FAIL ] && via=FAIL
	for a in $side; do [ "$src" = "$a" ] && via=SIDE; done
	printf '%-9s %-38s %-7s %s\n' "$c" "$u" "$via" "$src"
done
