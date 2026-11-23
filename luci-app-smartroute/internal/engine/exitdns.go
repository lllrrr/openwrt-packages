package engine

import (
	"math/rand/v2"
	"net"
	"net/netip"
	"strings"
	"syscall"
	"time"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

// 出口 DNS 的去向：以出口 t 为实际流量出口时，命中设备的明文 DNS 查询发到哪里。
//   - t 的 DNS 可用就用 t 的；不可用时按 t 的设置：fallback 沿故障切换链找第一个可用的、router 交给主路由、keep 仍用 t 的
//   - IPv6 查询只考虑有 IPv6 路由的出口；找不到时按 t 的设置拒绝（IPv4 查询走出口时才拒绝，设备改查 IPv4）或交给主路由
type DNSRoute struct {
	V4, V6   *Exit // 转发到该出口的 DNS；nil = 主路由 DNS
	V6Reject bool  // 拒绝 IPv6 查询
}

// alive：出口本身的 IPv4 检测正常
func (e *Engine) alive(x *Exit) bool {
	h := e.health[x.ID]
	return h == nil || h.up
}

// dnsOK：出口 DNS 检测正常，或没有检测
func (e *Engine) dnsOK(x *Exit, i int) bool {
	h := e.health[x.ID]
	return h == nil || !h.dns[i].on || h.dns[i].up
}

// v6RouteOK：出口的 IPv6 路由表里确有可用路由（不是拒绝、也不是空表——空表会落到主路由从 WAN 直接出去）
func (e *Engine) v6RouteOK(p *Plan, x *Exit) bool {
	return p.S.IPv6 && x.Type != "reject" && e.v6Mode(x) == "follow" && route(p, x, netlink.FAMILY_V6, "follow") != nil
}

func (e *Engine) dnsUsable(p *Plan, x *Exit, v6 bool) bool {
	if x.Type == "reject" || !e.alive(x) {
		return false
	}
	if v6 {
		return x.EffDNS6().IsValid() && e.v6RouteOK(p, x) && e.dnsOK(x, 1)
	}
	return x.DNS4.IsValid() && route(p, x, netlink.FAMILY_V4, "follow") != nil && e.dnsOK(x, 0)
}

func (e *Engine) DNSRouteOf(p *Plan, t *Exit) (r DNSRoute) {
	if t == nil || t.Type == "reject" || (!t.DNS4.IsValid() && !t.EffDNS6().IsValid()) {
		return
	}
	pick := func(v6 bool) *Exit {
		if e.dnsUsable(p, t, v6) {
			return t
		}
		switch t.DNSFail {
		case "router":
			return nil
		case "keep":
			if v6 && t.EffDNS6().IsValid() && e.v6RouteOK(p, t) || !v6 && t.DNS4.IsValid() {
				return t
			}
			return nil
		}
		seen := map[string]bool{t.ID: true}
		for id := t.Fallback; id != "" && id != "direct" && !seen[id]; {
			seen[id] = true
			x := p.exitByID(id)
			if x == nil {
				break
			}
			if e.dnsUsable(p, x, v6) {
				return x
			}
			id = x.Fallback
		}
		return nil
	}
	r.V4 = pick(false)
	if p.S.IPv6 {
		r.V6 = pick(true)
		r.V6Reject = r.V6 == nil && r.V4 != nil && t.DNS6None == "reject"
	}
	return
}

// probeDNS 经出口（带出口 mark）向 srv 查询 name 的 A 记录；收到应答（NOERROR / NXDOMAIN）即视为可用
func probeDNS(srv netip.AddrPort, name string, mark uint32, timeout time.Duration) (bool, time.Duration) {
	d := net.Dialer{Timeout: timeout, Control: func(_, _ string, rc syscall.RawConn) error {
		var serr error
		if mark != 0 {
			rc.Control(func(fd uintptr) { serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, int(mark)) })
		}
		return serr
	}}
	c, err := d.Dial("udp", srv.String())
	if err != nil {
		return false, 0
	}
	defer c.Close()
	id := uint16(rand.Uint32())
	q := []byte{byte(id >> 8), byte(id), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0} // RD=1，一个问题
	for _, l := range strings.Split(name, ".") {
		q = append(append(q, byte(len(l))), l...)
	}
	q = append(q, 0, 0, 1, 0, 1) // A / IN
	start := time.Now()
	c.SetDeadline(start.Add(timeout))
	if _, err := c.Write(q); err != nil {
		return false, 0
	}
	buf := make([]byte, 1500)
	for {
		n, err := c.Read(buf)
		if err != nil {
			return false, 0
		}
		if n >= 12 && uint16(buf[0])<<8|uint16(buf[1]) == id && buf[2]&0x80 != 0 {
			rc := buf[3] & 0x0F
			return rc == 0 || rc == 3, time.Since(start)
		}
	}
}
