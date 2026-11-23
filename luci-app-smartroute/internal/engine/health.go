package engine

import (
	"log"
	"math/rand/v2"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"time"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"

	"github.com/r1172464137/luci-app-smartroute/internal/bpf"
)

// 健康检查：按出口的检测间隔探测 IPv4（默认 ping 网关本身，可改为经该出口 ping 外部地址）与 IPv6（默认网关的 IPv6 下一跳）。
// 连续 downAfter 次失败判为故障，连续 upAfter 次成功判为恢复。
//   - IPv4 故障：改写 eBPF 分流表里的 mark，新连接改用备用出口；路由表不动，探测包（带出口 mark）始终测的是该出口本身
//   - 仅 IPv6 故障：该出口的 IPv6 按“拒绝 IPv6”处理（v6 路由改为 prohibit、屏蔽 AAAA），设备回退到 IPv4 继续走该出口
const (
	downAfter = 2
	upAfter   = 2
)

type health struct {
	key          string // 出口 ID + 探测地址：变了就重新开始计数
	v4           netip.Addr
	up, up6      bool
	fails, oks   int
	fails6, oks6 int
	rtt, rtt6    time.Duration
	probe6       bool         // 本出口有 IPv6 探测
	dns          [2]dnsHealth // 出口 DNS（IPv4 / IPv6）的检测结果
	next         time.Time
	busy         int // 进行中的探测数
}

// dnsHealth：经出口实际查询一次域名的结果；on = false 表示没有检测（视为可用）
type dnsHealth struct {
	on         bool
	target     netip.AddrPort
	up         bool
	fails, oks int
	rtt        time.Duration
}

// 探测种类
const (
	pkV4 = iota
	pkV6
	pkDNS4
	pkDNS6
)

type ProbeResult struct {
	ID   string
	Kind int
	OK   bool
	RTT  time.Duration
}

type Event struct {
	Time time.Time
	Msg
	Bad bool `json:",omitempty"`
}

func (e *Engine) event(bad bool, f string, a ...any) {
	ev := Event{time.Now(), msg(f, a...), bad}
	log.Print(ev.Msg)
	e.events = append(e.events, ev)
	if len(e.events) > 50 {
		e.events = e.events[len(e.events)-50:]
	}
}

// Probes 返回探测结果的通道，由主循环读取后交给 HealthResult
func (e *Engine) Probes() <-chan ProbeResult { return e.probes }

// probeTargets：IPv4 探测地址；IPv6 探测地址与所在接口（link-local 地址需要接口）
func probeTargets(p *Plan, x *Exit) (v4, v6 netip.Addr, zone string) {
	v4 = x.CheckIP
	if !p.S.IPv6 || x.V6Mode != "follow" {
		return
	}
	switch {
	case x.CheckIP6.IsValid():
		v6 = x.CheckIP6
	case x.Type == "gateway" && x.LL.IsValid():
		v6, zone = x.LL, x.Dev
	}
	return
}

// dnsTargets：要检测的出口 DNS。只检测经该出口有路由的地址，否则探测包会走主路由，测得的不是这个出口
func (e *Engine) dnsTargets(p *Plan, x *Exit) (d [2]netip.AddrPort) {
	if x.Type == "reject" {
		return
	}
	if x.DNS4.IsValid() && route(p, x, netlink.FAMILY_V4, "follow") != nil {
		d[0] = x.DNS4
	}
	if e.v6RouteOK(p, x) {
		d[1] = x.EffDNS6()
	}
	return
}

// HealthTick 发起到期的探测（并发、不阻塞主循环）
func (e *Engine) HealthTick(p *Plan) {
	now := time.Now()
	for _, x := range p.Exits {
		v4, v6, zone := probeTargets(p, x)
		dt := e.dnsTargets(p, x)
		if x.Interval <= 0 || (!v4.IsValid() && !v6.IsValid() && !dt[0].IsValid() && !dt[1].IsValid()) {
			continue
		}
		h := e.healthOf(x, v4, v6)
		for i, t := range dt {
			if d := &h.dns[i]; d.target != t {
				*d = dnsHealth{on: t.IsValid(), target: t, up: true}
			}
		}
		if h.busy > 0 || now.Before(h.next) {
			continue
		}
		h.next = now.Add(time.Duration(x.Interval) * time.Second)
		run := func(kind int, f func() (bool, time.Duration)) {
			h.busy++
			go func(id string) {
				ok, rtt := f()
				e.probes <- ProbeResult{id, kind, ok, rtt}
			}(x.ID)
		}
		mark := x.Mark
		if v4.IsValid() {
			run(pkV4, func() (bool, time.Duration) { return probe(v4, "", mark, time.Second) })
		}
		if v6.IsValid() {
			run(pkV6, func() (bool, time.Duration) { return probe(v6, zone, mark, time.Second) })
		}
		for i, t := range dt {
			if t.IsValid() {
				name := x.DNSCheck
				run(pkDNS4+i, func() (bool, time.Duration) { return probeDNS(t, name, mark, 2*time.Second) })
			}
		}
	}
}

func (e *Engine) healthOf(x *Exit, v4, v6 netip.Addr) *health {
	key := x.ID + "|" + v4.String() + "|" + v6.String()
	h := e.health[x.ID]
	if h != nil && h.key == key {
		return h
	}
	n := &health{key: key, v4: v4, up: true, up6: true, probe6: v6.IsValid()}
	if h != nil {
		n.next, n.busy = h.next, h.busy // 进行中的探测结果仍会回来
		if h.v4 == v4 {                 // 只换了 IPv6 探测目标（如网关换了 link-local）：IPv4 状态保留
			n.up, n.fails, n.oks, n.rtt = h.up, h.fails, h.oks, h.rtt
		}
		n.dns = h.dns // DNS 检测按各自的目标地址单独重置
	}
	e.health[x.ID] = n
	return n
}

// HealthResult 记录一次探测结果；状态变化时重写分流表、路由与防火墙（DNS 去向随出口状态变化），IPv4 故障时清掉经该出口的连接记录
func (e *Engine) HealthResult(p *Plan, r ProbeResult) error {
	x, h := p.exitByID(r.ID), e.health[r.ID]
	if x == nil || h == nil {
		return nil
	}
	h.busy--
	var up *bool
	var fails, oks *int
	var rtt *time.Duration
	switch r.Kind {
	case pkV4:
		up, fails, oks, rtt = &h.up, &h.fails, &h.oks, &h.rtt
	case pkV6:
		up, fails, oks, rtt = &h.up6, &h.fails6, &h.oks6, &h.rtt6
	default:
		d := &h.dns[r.Kind-pkDNS4]
		if !d.on { // 检测期间目标已取消
			return writeState(p, e)
		}
		up, fails, oks, rtt = &d.up, &d.fails, &d.oks, &d.rtt
	}
	if r.OK {
		*oks, *fails, *rtt = *oks+1, 0, r.RTT
	} else {
		*fails, *oks = *fails+1, 0
	}
	changed := true
	switch {
	case *up && *fails >= downAfter:
		*up = false
		switch {
		case r.Kind == pkV6:
			e.event(true, "Exit %s: IPv6 check failed %s times in a row, IPv6 is now rejected so devices fall back to IPv4", x.Name, downAfter)
		case r.Kind == pkDNS4:
			e.event(true, "Exit %s: DNS server %s did not answer %s times in a row", x.Name, x.DNS4.String(), downAfter)
		case r.Kind == pkDNS6:
			e.event(true, "Exit %s: IPv6 DNS server %s did not answer %s times in a row", x.Name, x.EffDNS6().String(), downAfter)
		case e.effMark(p, x.Fallback) == 0:
			e.event(true, "Exit %s failed %s checks in a row, switched to direct connection", x.Name, downAfter)
		default:
			e.event(true, "Exit %s failed %s checks in a row, switched to %s", x.Name, downAfter, e.fallbackName(p, x))
		}
	case !*up && *oks >= upAfter:
		*up = true
		switch r.Kind {
		case pkV6:
			e.event(false, "Exit %s: IPv6 check recovered", x.Name)
		case pkDNS4, pkDNS6:
			e.event(false, "Exit %s: DNS server recovered", x.Name)
		default:
			e.event(false, "Exit %s recovered, switched back", x.Name)
		}
	default:
		changed = false
	}
	if changed {
		if err := e.syncPolicies(p); err != nil {
			return err
		}
		if r.Kind == pkV6 {
			if err := e.syncRoutes(p); err != nil {
				return err
			}
		}
		if err := setFirewall(p, e, true); err != nil {
			return err
		}
		if r.Kind == pkV4 && !*up {
			e.purgeConns(x.Mark)
		}
	}
	return writeState(p, e) // 每次都写：状态页显示最新时延
}

// effExit：出口正常用自己，故障时沿备用出口链找第一个正常的；都不可用返回 nil（直连）
func (e *Engine) effExit(p *Plan, id string) *Exit {
	seen := map[string]bool{}
	for id != "" && id != "direct" && !seen[id] {
		seen[id] = true
		x := p.exitByID(id)
		if x == nil {
			return nil
		}
		if e.trafficUp(x) {
			return x
		}
		id = x.Fallback
	}
	return nil
}

func (e *Engine) effMark(p *Plan, id string) uint32 {
	if x := e.effExit(p, id); x != nil {
		return x.Mark
	}
	return 0
}

func (e *Engine) fallbackName(p *Plan, x *Exit) string {
	if f := e.effExit(p, x.Fallback); f != nil {
		return f.Name
	}
	return "direct"
}

// trafficUp：出口能否承载新连接。IPv4 检测失败，或设了“DNS 不可用时流量也切换”且出口 DNS 不可用，都算不可用
func (e *Engine) trafficUp(x *Exit) bool {
	h := e.health[x.ID]
	if h == nil {
		return true
	}
	return h.up && !(x.DNSMoveTraffic && h.dns[0].on && !h.dns[0].up)
}

// v6Mode：出口当前实际的 IPv6 处理方式；设为转发但 IPv6 探测失败时按“拒绝 IPv6”处理
func (e *Engine) v6Mode(x *Exit) string {
	if h := e.health[x.ID]; x.V6Mode == "follow" && h != nil && h.probe6 && !h.up6 {
		return "v4only"
	}
	return x.V6Mode
}

// syncPolicies 写分流表（mark 按出口状态换成实际出口，出口拒绝 IPv6 时带上 AAAA 屏蔽标志），最后写配置使之生效
func (e *Engine) syncPolicies(p *Plan) error {
	var flags uint32
	for i := 0; i < maxPolicy; i++ {
		var pol bpf.SrPolicy
		if i < len(p.Policies) {
			pol = p.Policies[i]
			pol.Mark = 0
			if x := e.effExit(p, p.PolicyExits[i]); x != nil {
				pol.Mark = x.Mark
				if p.S.IPv6 && x.Type != "reject" && e.v6Mode(x) == "v4only" {
					pol.Flags |= pNoAAAA
					flags |= cfAAAA
				}
				if r := e.DNSRouteOf(p, x); r.V4 != nil || r.V6 != nil || r.V6Reject {
					pol.Flags |= pDNS
					flags |= cfDNS
				}
			}
		}
		if err := e.objs.SrPolicy.Put(uint32(i), pol); err != nil {
			return err
		}
	}
	e.dlMark.Store(e.effMark(p, p.S.DownloadExit))
	cfg := bpf.SrCfg{Npol: uint32(len(p.Policies)), MarkMask: p.S.MarkMask, IdleS: p.S.Idle, DnsMinS: p.S.DNSKeep, TcpIdleS: tcpIdle, Flags: flags}
	return e.objs.SrCfg.Put(uint32(0), cfg)
}

// purgeConns 删掉经故障出口的连接记录：经网关的 TCP 连接已经断了，UDP 流重新判断后走备用出口
func (e *Engine) purgeConns(mark uint32) {
	var k bpf.SrConnKey
	var v bpf.SrConnVal
	var del []bpf.SrConnKey
	it := e.objs.SrConn.Iterate()
	for it.Next(&k, &v) {
		if v.Mark == mark {
			del = append(del, k)
		}
	}
	for _, k := range del {
		e.objs.SrConn.Delete(k)
	}
}

// probe 发一个 ICMP / ICMPv6 echo，带上 mark 后按该出口的路由表发出。zone：link-local 地址所在接口
func probe(dst netip.Addr, zone string, mark uint32, timeout time.Duration) (bool, time.Duration) {
	network, laddr, req, rep := "ip4:icmp", "0.0.0.0", byte(8), byte(0)
	if dst.Is6() {
		network, laddr, req, rep = "ip6:ipv6-icmp", "::", 128, 129
	}
	c, err := net.ListenPacket(network, laddr)
	if err != nil {
		return false, 0
	}
	defer c.Close()
	if mark != 0 {
		if rc, err := c.(*net.IPConn).SyscallConn(); err == nil {
			rc.Control(func(fd uintptr) { unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, int(mark)) })
		}
	}
	id := uint16(rand.Uint32())
	msg := []byte{req, 0, 0, 0, byte(id >> 8), byte(id), 0, 1, 's', 'r'}
	if !dst.Is6() { // ICMPv6 的校验和由内核计算
		cs := checksum(msg)
		msg[2], msg[3] = byte(cs>>8), byte(cs)
	}
	if zone != "" {
		// 传接口编号而不是名字：Go 按名字查编号有最长 60 秒的缓存，br-lan 重建后会一直发往旧编号
		zone = strconv.Itoa(ifIndex(zone))
	}
	start := time.Now()
	if _, err := c.WriteTo(msg, &net.IPAddr{IP: dst.AsSlice(), Zone: zone}); err != nil {
		return false, 0
	}
	c.SetReadDeadline(start.Add(timeout))
	buf := make([]byte, 1500)
	for {
		n, from, err := c.ReadFrom(buf)
		if err != nil {
			return false, 0
		}
		a, _ := netip.AddrFromSlice(from.(*net.IPAddr).IP)
		// 读到的是去掉 IP 头的 ICMP 报文；原始套接字会收到所有 ICMP，按来源、类型与 ID 过滤
		if a.Unmap() == dst && n >= 8 && buf[0] == rep && uint16(buf[4])<<8|uint16(buf[5]) == id {
			return true, time.Since(start)
		}
	}
}

// echoAll 向接口 idx 上的 ff02::1 发 ICMPv6 echo，返回 timeout 内应答的 link-local 地址
func echoAll(idx int, timeout time.Duration) []netip.Addr {
	c, err := net.ListenPacket("ip6:ipv6-icmp", "::")
	if err != nil || idx <= 0 {
		return nil
	}
	defer c.Close()
	id := uint16(rand.Uint32())
	msg := []byte{128, 0, 0, 0, byte(id >> 8), byte(id), 0, 1, 's', 'r'}
	if _, err := c.WriteTo(msg, &net.IPAddr{IP: net.ParseIP("ff02::1"), Zone: strconv.Itoa(idx)}); err != nil {
		return nil
	}
	c.SetReadDeadline(time.Now().Add(timeout))
	var out []netip.Addr
	buf := make([]byte, 1500)
	for {
		n, from, err := c.ReadFrom(buf)
		if err != nil {
			return out
		}
		a, _ := netip.AddrFromSlice(from.(*net.IPAddr).IP)
		if n >= 8 && buf[0] == 129 && uint16(buf[4])<<8|uint16(buf[5]) == id && a.IsLinkLocalUnicast() && !slices.Contains(out, a) {
			out = append(out, a)
		}
	}
}

func checksum(b []byte) uint16 {
	var s uint32
	for i := 0; i+1 < len(b); i += 2 {
		s += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		s += uint32(b[len(b)-1]) << 8
	}
	for s>>16 != 0 {
		s = s&0xffff + s>>16
	}
	return ^uint16(s)
}
