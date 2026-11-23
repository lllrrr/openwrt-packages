package engine

import (
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"

	"github.com/r1172464137/luci-app-smartroute/internal/uci"
)

func TestCompile(t *testing.T) {
	secs, err := uci.Parse(`smartroute.main=global
smartroute.main.enabled='1'
smartroute.ga=group
smartroute.gb=group
smartroute.cn=rule_group
smartroute.cn.rule='223.5.5.0/24' '240e::/20'
smartroute.fl=rule_group
smartroute.fl.rule='domain:foreign.lab' 'keyword:x'
smartroute.side=exit
smartroute.side.ip='192.168.99.3'
smartroute.bad=exit
smartroute.bad.ip='nope'
smartroute.da=device
smartroute.da.mac='02:5a:00:00:05:0a'
smartroute.da.group='ga'
smartroute.db=device
smartroute.db.ip='192.168.99.11'
smartroute.db.group='gb' 'missing'
smartroute.p0=policy
smartroute.p0.source='ga'
smartroute.p0.rule_group='cn'
smartroute.p0.invert='1'
smartroute.p0.exit='side'
smartroute.p1=policy
smartroute.p1.source='db'
smartroute.p1.rule_group='fl'
smartroute.p1.exit='reject'
smartroute.p2=policy
smartroute.p2.source='all'
smartroute.p2.exit='direct'
smartroute.p3=policy
smartroute.p3.enabled='0'
smartroute.p3.source='all'
smartroute.p4=policy
smartroute.p4.source='nobody'
`)
	if err != nil {
		t.Fatal(err)
	}
	p, err := Compile(secs, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	// 位：ga=1 gb=2 db=4（被分流直接选中）；cn=1 fl=2
	if len(p.Policies) != 3 || strings.Join(p.PolicyIDs, ",") != "p0,p1,p2" {
		t.Fatalf("policies %v %+v", p.PolicyIDs, p.Policies)
	}
	if q := p.Policies[0]; q.Dev != 1 || q.Rg != 1 || q.Flags != pNeg || q.Mark != 0x01000000 {
		t.Errorf("p0 %+v", q)
	}
	if q := p.Policies[1]; q.Dev != 4 || q.Rg != 2 || q.Mark != 0x02000000 {
		t.Errorf("p1 %+v", q)
	}
	if q := p.Policies[2]; q.Flags != pAllDev|pAllRG || q.Mark != 0 {
		t.Errorf("p2 %+v", q)
	}
	if len(p.Exits) != 2 || p.Exits[0].Table != 3101 || p.Exits[1].Type != "reject" || p.Exits[1].Table != 3102 {
		t.Errorf("exits %+v %+v", p.Exits[0], p.Exits)
	}
	if v := p.MAC[[6]byte{2, 0x5a, 0, 0, 5, 0xa}]; v.G4 != 1 || v.G6 != 1 {
		t.Errorf("mac %+v", v)
	}
	if len(p.Dev4) != 1 || p.Dev4[0].Bits != 6 || len(p.Links) != 1 || p.Links[0].Bits != 6 {
		t.Errorf("dev4 %+v links %+v", p.Dev4, p.Links)
	}
	if len(p.Rules.V4) != 1 || len(p.Rules.V6) != 1 || len(p.Rules.Domains) != 1 {
		t.Errorf("rules %+v", p.Rules)
	}
	var ws []string
	for _, m := range p.Warnings {
		ws = append(ws, m.String())
	}
	w := strings.Join(ws, "\n")
	for _, s := range []string{"bad", "missing", "nobody"} {
		if !strings.Contains(w, s) {
			t.Errorf("警告缺少 %s：\n%s", s, w)
		}
	}
}

func TestChecksum(t *testing.T) {
	// ICMP echo：带上校验和后整体再算一次应为 0
	msg := []byte{8, 0, 0, 0, 0x12, 0x34, 0, 1, 's', 'r', 'x'}
	cs := checksum(msg)
	msg[2], msg[3] = byte(cs>>8), byte(cs)
	if checksum(msg) != 0 {
		t.Fatalf("checksum %x", checksum(msg))
	}
}

func TestEffMark(t *testing.T) {
	secs, _ := uci.Parse(`smartroute.a=exit
smartroute.a.ip='10.0.0.1'
smartroute.a.fallback='b'
smartroute.b=exit
smartroute.b.ip='10.0.0.2'
smartroute.b.fallback='a'
smartroute.c=exit
smartroute.c.ip='10.0.0.3'
smartroute.c.fallback='reject'
`)
	p, err := Compile(secs, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	e := &Engine{health: map[string]*health{}}
	down := func(x *Exit) { e.health[x.ID] = &health{up: false} }
	a, b, c, rej := p.exitByID("a"), p.exitByID("b"), p.exitByID("c"), p.exitByID("reject")
	if rej == nil {
		t.Fatal("备用出口引用 reject 时应创建内置拦截出口")
	}
	if e.effMark(p, "a") != a.Mark {
		t.Error("正常时用自己的 mark")
	}
	down(a)
	if e.effMark(p, "a") != b.Mark {
		t.Error("a 故障应切到 b")
	}
	down(b)
	if e.effMark(p, "a") != 0 {
		t.Error("备用链成环且都故障时应直连")
	}
	down(c)
	if e.effMark(p, "c") != rej.Mark {
		t.Error("c 故障应切到拦截")
	}
}

func TestInterfaceExitNAT(t *testing.T) {
	secs, _ := uci.Parse(`smartroute.wg=exit
smartroute.wg.type='interface'
smartroute.wg.network='wg0'
smartroute.w2=exit
smartroute.w2.type='interface'
smartroute.w2.network='wan2'
`)
	fw, _ := uci.Parse(`firewall.z1=zone
firewall.z1.name='wan'
firewall.z1.network='wan' 'wan2'
firewall.z1.masq='1'
firewall.z2=zone
firewall.z2.name='vpn'
firewall.z2.network='wg0'
`)
	p, err := Compile(secs, t.TempDir(), fw)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Exits) != 2 || p.Exits[0].Network != "wg0" {
		t.Fatalf("exits %+v", p.Exits)
	}
	if len(p.Warnings) != 1 || !strings.Contains(p.Warnings[0].String(), "wg0") {
		t.Errorf("只有不在伪装区域里的 wg0 应告警：%v", p.Warnings)
	}
}

func TestMsgFormat(t *testing.T) {
	if got := msg("Exit %s failed %s checks", "side", 2).String(); got != "Exit side failed 2 checks" {
		t.Error(got)
	}
}

func TestProbeRouteSurvivesV6Down(t *testing.T) {
	secs, _ := uci.Parse(`smartroute.main=global
smartroute.main.ipv6='1'
smartroute.a=exit
smartroute.a.ip='10.0.0.1'
smartroute.a.check_ip6='2001:db8::1'
`)
	p, err := Compile(secs, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	x := p.exitByID("a")
	x.Dev, x.LL = "br-lan", netip.MustParseAddr("fe80::1")
	e := &Engine{health: map[string]*health{"a": {up: true, up6: false, probe6: true}}}
	if r := e.exitRoute(p, x, netlink.FAMILY_V6); r == nil || r.Type != unix.RTN_PROHIBIT {
		t.Fatal("v6 探测失败时默认路由应为 prohibit")
	}
	r := probeRoute(p, x)
	if r == nil || r.Dst.String() != "2001:db8::1/128" || !r.Gw.Equal(x.LL.AsSlice()) {
		t.Fatalf("v6 故障时探测地址仍应经网关：%+v", r)
	}
	x.CheckIP6 = netip.Addr{}
	if r := probeRoute(p, x); r == nil || r.Dst.String() != "fe80::1/128" || r.Gw != nil {
		t.Fatalf("未设探测地址时探测网关 link-local，应同链路直达：%+v", r)
	}
}

func TestHealthKeepsV4WhenV6TargetChanges(t *testing.T) {
	e := &Engine{health: map[string]*health{}}
	x := &Exit{ID: "a"}
	v4 := netip.MustParseAddr("10.0.0.1")
	h := e.healthOf(x, v4, netip.MustParseAddr("fe80::1"))
	h.up, h.up6 = false, false
	n := e.healthOf(x, v4, netip.MustParseAddr("fe80::2"))
	if n.up || !n.up6 {
		t.Fatalf("换了 IPv6 下一跳：IPv4 故障状态应保留、IPv6 重新计数，得到 up=%v up6=%v", n.up, n.up6)
	}
	if n := e.healthOf(x, netip.MustParseAddr("10.0.0.2"), netip.MustParseAddr("fe80::2")); !n.up {
		t.Fatal("换了 IPv4 探测地址应重新计数")
	}
}

func TestExitDNSConfig(t *testing.T) {
	secs, _ := uci.Parse(`smartroute.main=global
smartroute.main.enabled='1'
smartroute.main.ipv6='1'
smartroute.side=exit
smartroute.side.ip='192.168.99.3'
smartroute.side.dns='192.168.99.3:5353'
smartroute.side.dns6='2001:4860:4860::8888'
smartroute.wg=exit
smartroute.wg.type='interface'
smartroute.wg.network='wg0'
smartroute.wg.dns='8.8.8.8'
smartroute.wg.dns_fail='bogus'
smartroute.wg.dns_check='not a domain'
smartroute.corp=exit
smartroute.corp.type='interface'
smartroute.corp.network='wg1'
smartroute.corp.dns='10.0.0.53'
smartroute.bad=exit
smartroute.bad.ip='192.168.99.4'
smartroute.bad.dns='not-an-ip'
smartroute.bad.dns6='fe80::1'
smartroute.bad.dns_nohijack='0'
`)
	p, err := Compile(secs, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	side, wg, corp, bad := p.exitByID("side"), p.exitByID("wg"), p.exitByID("corp"), p.exitByID("bad")
	if side.DNS4.String() != "192.168.99.3:5353" || side.EffDNS6().String() != "[2001:4860:4860::8888]:53" {
		t.Fatalf("side DNS %v / %v", side.DNS4, side.EffDNS6())
	}
	if wg.DNS4.String() != "8.8.8.8:53" || wg.EffDNS6().String() != "[2001:4860:4860::8888]:53" { // 公共 DNS 自动对应 IPv6
		t.Fatalf("wg DNS %v / %v", wg.DNS4, wg.EffDNS6())
	}
	if corp.EffDNS6().IsValid() {
		t.Fatalf("corp 不应有 IPv6 DNS：%v", corp.EffDNS6())
	}
	if side.DNSFail != "fallback" || side.DNS6None != "reject" || side.DNSCheck != "www.google.com" || !side.NoHijack || side.DNSMoveTraffic {
		t.Fatalf("side 默认值不对：%+v", side)
	}
	if wg.DNSFail != "fallback" || wg.DNSCheck != "www.google.com" || wg.NoHijack {
		t.Fatalf("wg 非法值应回到默认值，接口出口无劫持开关：%+v", wg)
	}
	if bad.NoHijack {
		t.Fatal("dns_nohijack=0 应关闭")
	}
	if len(p.Warnings) != 4 {
		t.Fatalf("期望 4 条告警，得到 %v", p.Warnings)
	}
}

// dnsLab：side（网关，故障切换到 wg）、wg（接口）、corp（接口，不处理 IPv6），运行时信息已解析
func dnsLab(t *testing.T, extra string) (*Plan, *Exit, *Exit, *Exit) {
	t.Helper()
	secs, _ := uci.Parse(`smartroute.main=global
smartroute.main.enabled='1'
smartroute.main.ipv6='1'
smartroute.side=exit
smartroute.side.ip='192.168.99.3'
smartroute.side.dns='192.168.99.3'
smartroute.side.dns6='2001:db8::3'
smartroute.side.fallback='wg'
smartroute.wg=exit
smartroute.wg.type='interface'
smartroute.wg.network='wg0'
smartroute.wg.dns='8.8.8.8'
smartroute.corp=exit
smartroute.corp.type='interface'
smartroute.corp.network='wg1'
smartroute.corp.ipv6='none'
smartroute.corp.dns='10.0.0.53'
` + extra)
	p, err := Compile(secs, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	side, wg, corp := p.exitByID("side"), p.exitByID("wg"), p.exitByID("corp")
	side.Dev, side.MAC, side.LL = "br-lan", HW{2, 0, 0, 0, 0, 3}, netip.MustParseAddr("fe80::3")
	wg.Dev, corp.Dev = "wg0", "wg1"
	return p, side, wg, corp
}

func TestDNSRoute(t *testing.T) {
	p, side, wg, corp := dnsLab(t, "")
	mk := func(h map[string]*health) *Engine { return &Engine{health: h} }
	dnsDown := func(i int) *health {
		h := &health{up: true, up6: true}
		h.dns[i] = dnsHealth{on: true, up: false}
		return h
	}
	name := func(x *Exit) string {
		if x == nil {
			return "router"
		}
		return x.ID
	}
	check := func(what string, e *Engine, x *Exit, v4, v6 string, rej bool) {
		t.Helper()
		r := e.DNSRouteOf(p, x)
		if name(r.V4) != v4 || name(r.V6) != v6 || r.V6Reject != rej {
			t.Errorf("%s：得到 v4=%s v6=%s reject=%v，期望 v4=%s v6=%s reject=%v", what, name(r.V4), name(r.V6), r.V6Reject, v4, v6, rej)
		}
	}
	healthy := mk(map[string]*health{})
	check("全部正常", healthy, side, "side", "side", false)
	check("接口出口", healthy, wg, "wg", "wg", false)
	check("不处理 IPv6 的出口：拒绝 IPv6 查询", healthy, corp, "corp", "router", true)

	check("side DNS 不可用：沿故障切换链用 wg", mk(map[string]*health{"side": dnsDown(0)}), side, "wg", "side", false)
	side.DNSFail = "router"
	check("router：交给主路由", mk(map[string]*health{"side": dnsDown(0)}), side, "router", "side", false)
	side.DNSFail = "keep"
	check("keep：仍用 side", mk(map[string]*health{"side": dnsDown(0)}), side, "side", "side", false)
	side.DNSFail = "fallback"

	v6down := &health{up: true, up6: false, probe6: true}
	check("side IPv6 不通：IPv6 查询改用 wg", mk(map[string]*health{"side": v6down}), side, "side", "wg", false)
	check("side IPv6 不通、wg 故障：拒绝 IPv6 查询", mk(map[string]*health{"side": v6down, "wg": {up: false}}), side, "side", "router", true)
	side.DNS6None = "router"
	check("dns6_none=router：交给主路由", mk(map[string]*health{"side": v6down, "wg": {up: false}}), side, "side", "router", false)
	side.DNS6None = "reject"

	side.LL = netip.Addr{}
	check("还没找到 IPv6 下一跳：不能把 IPv6 查询交给 side", healthy, side, "side", "wg", false)
	side.LL = netip.MustParseAddr("fe80::3")

	both := dnsDown(0)
	both.dns[1] = dnsHealth{on: true, up: false}
	check("整条链都不可用：IPv4 回主路由，IPv6 也回主路由", mk(map[string]*health{"side": both, "wg": {up: false}}), side, "router", "router", false)

	// DNS 不可用时流量也切换
	e := mk(map[string]*health{"side": dnsDown(0)})
	if x := e.effExit(p, "side"); x != side {
		t.Fatal("默认 DNS 不可用不影响流量")
	}
	side.DNSMoveTraffic = true
	if x := e.effExit(p, "side"); x != wg {
		t.Fatalf("dns_fail_traffic=1 时流量应切到 wg，得到 %v", x)
	}
}

func TestDNSNFT(t *testing.T) {
	p, side, wg, corp := dnsLab(t, "")
	mm := func(x *Exit) string { return fmt.Sprintf("meta mark & 0x%08x == 0x%08x", p.S.MarkMask, x.Mark) }
	has := func(nft string, want ...string) {
		t.Helper()
		for _, w := range want {
			if !strings.Contains(nft, w) {
				t.Errorf("生成的 nft 缺少 %q：\n%s", w, nft)
			}
		}
	}
	nft := buildNFT(p, &Engine{health: map[string]*health{}})
	has(nft,
		"meta nfproto ipv4 meta l4proto { tcp, udp } th dport 53 "+mm(side)+" dnat ip to 192.168.99.3:53",
		"meta nfproto ipv6 meta l4proto { tcp, udp } th dport 53 "+mm(side)+" dnat ip6 to [2001:db8::3]:53",
		mm(wg)+" dnat ip to 8.8.8.8:53",
		mm(wg)+" dnat ip6 to [2001:4860:4860::8888]:53",
		mm(corp)+" dnat ip to 10.0.0.53:53",
		`iifname { "br-lan" } oifname { "br-lan" } meta nfproto ipv4 ip daddr 192.168.99.3 meta l4proto { tcp, udp } th dport 53 ct status dnat ct original proto-dst 53 masquerade`,
		`meta nfproto ipv6 ip6 daddr 2001:db8::3 meta l4proto { tcp, udp } th dport 53 ct status dnat ct original proto-dst 53 masquerade`,
		"chain dns_fwd", fmt.Sprintf("ct status dnat ct original proto-dst 53 meta mark set meta mark & 0x%08x", ^p.S.MarkMask),
		"chain dns_v6_in", "meta nfproto ipv6 meta l4proto { tcp, udp } th dport 53 "+mm(corp)+" reject",
		"ether saddr 02:00:00:00:00:03 meta nfproto ipv4 udp dport 53 dnat ip to ip daddr",
		"priority dstnat - 1",
	)
	if strings.Contains(nft, "chain dns_mark") || strings.Contains(nft, "daddr 8.8.8.8 meta l4proto { tcp, udp } th dport 53 ct status dnat") {
		t.Errorf("全部正常时不应改 mark，接口出口不加伪装：\n%s", nft)
	}

	h := &health{up: true, up6: true}
	h.dns[0] = dnsHealth{on: true, up: false}
	nft = buildNFT(p, &Engine{health: map[string]*health{"side": h}})
	has(nft, "chain dns_mark", "priority mangle + 10",
		fmt.Sprintf("meta nfproto ipv4 meta l4proto { tcp, udp } th dport 53 %s meta mark set meta mark & 0x%08x | 0x%08x", mm(side), ^p.S.MarkMask, wg.Mark))
	if strings.Contains(nft, mm(side)+" dnat ip to") {
		t.Errorf("side 的 IPv4 DNS 不可用时不应再 DNAT 到它：\n%s", nft)
	}

	side.NoHijack = false
	if nft = buildNFT(p, &Engine{health: map[string]*health{}}); strings.Contains(nft, "ether saddr") {
		t.Errorf("关闭“不被劫持”后不应放行网关：\n%s", nft)
	}
	// 没有任何出口 DNS 时，只要网关开了不被劫持，dns_pre 仍然存在
	p2, s2, _, _ := dnsLab(t, "")
	for _, x := range p2.Exits {
		x.DNS4, x.DNS6, x.AutoDNS6 = netip.AddrPort{}, netip.AddrPort{}, netip.AddrPort{}
	}
	nft = buildNFT(p2, &Engine{health: map[string]*health{}})
	has(nft, "chain dns_pre", "ether saddr "+net.HardwareAddr(s2.MAC).String())
	if strings.Contains(nft, "dnat ip to 192") || strings.Contains(nft, "dns_post") || strings.Contains(nft, "dns_fwd") {
		t.Errorf("没有出口 DNS 时不应有转发规则：\n%s", nft)
	}
}

func TestProbeDNS(t *testing.T) {
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer c.Close()
	var rcode atomic.Int32 // 测试与应答协程共用
	go func() {
		buf := make([]byte, 512)
		for {
			n, a, err := c.ReadFrom(buf)
			if err != nil {
				return
			}
			if n < 12 || buf[12] != 3 || string(buf[13:16]) != "www" {
				continue // 不是期望的查询：不回答
			}
			buf[2] |= 0x80
			buf[3] = buf[3]&0xF0 | byte(rcode.Load())
			c.WriteTo(buf[:n], a)
		}
	}()
	srv := netip.MustParseAddrPort(c.LocalAddr().String())
	if ok, _ := probeDNS(srv, "www.example.com", 0, time.Second); !ok {
		t.Fatal("NOERROR 应判为可用")
	}
	rcode.Store(2)
	if ok, _ := probeDNS(srv, "www.example.com", 0, time.Second); ok {
		t.Fatal("SERVFAIL 应判为不可用")
	}
	if ok, _ := probeDNS(srv, "foo.example.com", 0, 300*time.Millisecond); ok {
		t.Fatal("没有应答应判为不可用")
	}
}
