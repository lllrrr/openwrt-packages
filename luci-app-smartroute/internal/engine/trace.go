package engine

import (
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"slices"
	"strings"

	"github.com/vishvananda/netlink"

	"github.com/r1172464137/luci-app-smartroute/internal/bpf"
	"github.com/r1172464137/luci-app-smartroute/internal/rules"
)

// 诊断：流量走向测试与域名记录查询。在命令行进程里运行：重新编译配置，读取运行中的域名记录与出口状态，不产生真实流量。

type DNSRecord struct {
	MAC     string // 解析该域名的设备
	Name    string
	IP      string
	TTLLeft int // 剩余保留秒数
}

// DNSRecords 返回域名或 IP 等于 q 的记录（q 为空返回全部）；mac 不为空时只返回该设备的记录
func DNSRecords(q, mac string, keep uint32) ([]DNSRecord, error) {
	m, err := bpf.Pinned("sr_dns")
	if err != nil {
		return nil, fmt.Errorf("not running")
	}
	defer m.Close()
	q = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(q)), ".")
	now := monoNow()
	var out []DNSRecord
	var k bpf.SrDnsKey
	var v bpf.SrDnsVal
	it := m.Iterate()
	for it.Next(&k, &v) {
		ttl, age := max(uint64(v.Ttl), uint64(keep)), (now-v.SeenNs)/1e9
		if now < v.SeenNs || age >= ttl {
			continue
		}
		r := DNSRecord{MAC: net.HardwareAddr(k.Mac[:]).String(), Name: wireName(v), IP: dnsKeyAddr(k).String(), TTLLeft: int(ttl - age)}
		if (q == "" || r.Name == q || r.IP == q) && (mac == "" || r.MAC == mac) {
			out = append(out, r)
		}
	}
	slices.SortFunc(out, func(a, b DNSRecord) int { return strings.Compare(a.Name+a.IP+a.MAC, b.Name+b.IP+b.MAC) })
	return out, it.Err()
}

func dnsKeyAddr(k bpf.SrDnsKey) netip.Addr {
	if k.Family == 4 {
		return netip.AddrFrom4([4]byte(k.Addr[:4]))
	}
	return netip.AddrFrom16(k.Addr)
}

// wireName 把右对齐的线格式域名转成点分形式
func wireName(v bpf.SrDnsVal) string {
	n := int(v.Len)
	if n < 1 || n > len(v.Name) {
		return ""
	}
	b := v.Name[len(v.Name)-n:]
	var labels []string
	for i := 0; i < len(b) && b[i] != 0; i += int(b[i]) + 1 {
		if i+1+int(b[i]) > len(b) {
			break
		}
		labels = append(labels, strings.ToLower(string(b[i+1:i+1+int(b[i])])))
	}
	return strings.Join(labels, ".")
}

type TraceStep struct {
	Policy string // 分流配置段名
	Match  bool
	Reason string `json:",omitempty"` // 不匹配的原因：device | rules | rules_neg
}

type Trace struct {
	Device     string
	MAC, IP    string   `json:",omitempty"`
	Groups     []string // 设备所属设备组（显示名）
	Target     string
	Addr       string   `json:",omitempty"` // 实际判断的目标地址
	Domain     string   `json:",omitempty"`
	FromRecord bool     `json:",omitempty"` // 域名来自域名记录
	RuleGroups []string // 目标所属规则组（显示名）
	Note       string   `json:",omitempty"` // no_record：设备还没解析过该域名；protected：目标属于内置保护地址
	Steps      []TraceStep
	Policy     string `json:",omitempty"`
	Exit       string // 分流指定的出口（配置段名，direct / reject 为内置出口）
	Actual     string `json:",omitempty"` // 出口故障时实际使用的出口
	// 命中设备查询该域名时 DNS 的实际去向（出口没有配 DNS 时全部为空，即主路由 DNS）
	DNS4, DNS6         string `json:",omitempty"`
	DNS4Exit, DNS6Exit string `json:",omitempty"` // DNS 所在出口（回退后可能不是流量出口）
	DNS6Reject         bool   `json:",omitempty"`
}

// RunTrace 模拟 device（MAC 或 IP）访问 target（域名或 IP）
func RunTrace(p *Plan, device, target string) (*Trace, error) {
	t := &Trace{Device: device, Target: target, Exit: "direct"}
	var mac net.HardwareAddr
	var ip4 netip.Addr
	if hw, err := net.ParseMAC(device); err == nil && len(hw) == 6 {
		mac = hw
		ip4 = ipOfMAC(hw)
	} else if a, err := netip.ParseAddr(device); err == nil && a.Is4() {
		ip4 = a
		mac = neighMAC(0, a)
	} else {
		return nil, fmt.Errorf("device must be a MAC or IPv4 address")
	}
	macStr := ""
	if mac != nil {
		macStr = mac.String()
	}

	// 目标：IP 直接用；域名查域名记录得到 IP
	target = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(target)), ".")
	var addr netip.Addr
	if a, err := netip.ParseAddr(target); err == nil {
		addr = a.Unmap()
		if recs, _ := DNSRecords(addr.String(), macStr, p.S.DNSKeep); macStr != "" && len(recs) > 0 {
			t.Domain, t.FromRecord = recs[0].Name, true
		}
	} else {
		t.Domain = target
		if recs, _ := DNSRecords(target, macStr, p.S.DNSKeep); macStr != "" && len(recs) > 0 {
			addr = netip.MustParseAddr(recs[0].IP)
		} else {
			t.Note = "no_record"
		}
	}
	if addr.IsValid() {
		t.Addr = addr.String()
	}

	// 设备所属设备组
	var dev uint64
	if mac != nil {
		t.MAC = mac.String()
		v := p.MAC[[6]byte(mac)]
		dev |= map[bool]uint64{true: v.G6, false: v.G4}[addr.Is6()]
	}
	if ip4.IsValid() {
		t.IP = ip4.String()
		dev |= lookupPrefix(p.Dev4, ip4)
	}
	if addr.Is6() && mac != nil {
		for _, l := range p.Links {
			if l.IP == ip4 { // IP 规则：IPv6 经该 IP 当前的 MAC 关联
				dev |= l.Bits
			}
		}
	}
	t.Groups = names(p, p.DevBit, dev)

	// 目标所属规则组
	var rg uint64
	if addr.IsValid() {
		if addr.Is4() {
			rg |= lookupPrefix(p.Rules.V4, addr)
		} else {
			rg |= lookupPrefix(p.Rules.V6, addr)
		}
	}
	if t.Domain != "" {
		labels := strings.Split(t.Domain, ".")
		for i := range labels {
			if h, ok := rules.DomainHash(strings.Join(labels[i:], ".")); ok {
				rg |= p.Rules.Domains[h]
			}
		}
	}
	t.RuleGroups = names(p, p.RGBit, rg)

	if addr.IsValid() {
		v4, v6 := skipPrefixes()
		if lookupPrefix(append(v4, v6...), addr) != 0 {
			t.Note = "protected"
			return t, nil
		}
	}

	for i, pol := range p.Policies {
		st := TraceStep{Policy: p.PolicyIDs[i]}
		switch {
		case pol.Flags&pAllDev == 0 && dev&pol.Dev == 0:
			st.Reason = "device"
		default:
			m := pol.Flags&pAllRG != 0 || rg&pol.Rg != 0
			if pol.Flags&pNeg != 0 {
				m = !m
			}
			st.Match = m
			if !m {
				st.Reason = map[bool]string{false: "rules", true: "rules_neg"}[pol.Flags&pNeg != 0]
			}
		}
		t.Steps = append(t.Steps, st)
		if st.Match {
			t.Policy = st.Policy
			t.Exit = p.PolicyExits[i]
			rv := routeView(p, t.Exit)
			if rv.Actual != t.Exit {
				t.Actual = rv.Actual
			}
			if t.Domain != "" && !isLocalDomain(t.Domain) {
				t.DNS4, t.DNS4Exit, t.DNS6, t.DNS6Exit, t.DNS6Reject = rv.DNS4, rv.DNS4Exit, rv.DNS6, rv.DNS6Exit, rv.DNS6Reject
			}
			return t, nil
		}
	}
	return t, nil
}

func isLocalDomain(domain string) bool {
	labels := strings.Split(strings.TrimSuffix(strings.ToLower(domain), "."), ".")
	if len(labels) < 2 {
		return true
	}
	skip := dnsSkipMap()
	for i := range labels {
		if h, ok := rules.DomainHash(strings.Join(labels[i:], ".")); ok && skip[h] != 0 {
			return true
		}
	}
	return false
}

func lookupPrefix(ps []rules.Prefix, a netip.Addr) uint64 {
	best, bits := -1, uint64(0)
	for _, p := range ps {
		if p.P.Contains(a) && p.P.Bits() > best {
			best, bits = p.P.Bits(), p.Bits
		}
	}
	return bits
}

func names(p *Plan, bitOf map[string]uint64, set uint64) []string {
	var out []string
	for sec, b := range bitOf {
		if set&b != 0 {
			out = append(out, p.Names[sec])
		}
	}
	slices.Sort(out)
	return out
}

// routeView：分流指定出口 id 时的实际去向。服务运行时取状态文件（含检测结果），否则按配置推算（视所有出口正常）
func routeView(p *Plan, id string) RouteView {
	var st State
	if b, err := os.ReadFile(StateFile); err == nil && json.Unmarshal(b, &st) == nil {
		if rv, ok := st.Routes[id]; ok {
			return rv
		}
	}
	rv := RouteView{Actual: "direct"}
	if id == "reject" {
		rv.Actual = "reject"
	}
	e := &Engine{health: map[string]*health{}}
	if t := e.effExit(p, id); t != nil {
		rv.Actual = t.ID
		r := e.DNSRouteOf(p, t)
		if r.V4 != nil {
			rv.DNS4, rv.DNS4Exit = r.V4.DNS4.String(), r.V4.ID
		}
		if r.V6 != nil {
			rv.DNS6, rv.DNS6Exit = r.V6.EffDNS6().String(), r.V6.ID
		}
		rv.DNS6Reject = r.V6Reject
	}
	return rv
}

func ipOfMAC(mac net.HardwareAddr) netip.Addr {
	ns, _ := netlink.NeighList(0, netlink.FAMILY_V4)
	for _, n := range ns {
		if strings.EqualFold(n.HardwareAddr.String(), mac.String()) {
			if a, ok := netip.AddrFromSlice(n.IP); ok {
				return a.Unmap()
			}
		}
	}
	return netip.Addr{}
}
