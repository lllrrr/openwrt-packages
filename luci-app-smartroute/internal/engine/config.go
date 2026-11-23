// Package engine 把 UCI 配置编译成数据面的表、路由和防火墙规则，并应用到系统。
package engine

import (
	"fmt"
	"math/bits"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"

	"github.com/r1172464137/luci-app-smartroute/internal/bpf"
	"github.com/r1172464137/luci-app-smartroute/internal/rules"
	"github.com/r1172464137/luci-app-smartroute/internal/uci"
)

const (
	pAllDev = 1
	pAllRG  = 2
	pNeg    = 4

	pNoAAAA = 8  // 出口拒绝 IPv6：屏蔽命中域名的 AAAA 记录
	pDNS    = 16 // 出口配置了 DNS：命中的设备查询命中域名时按出口转发 DNS

	cfAAAA = 1
	cfDNS  = 2

	maxPolicy = 32 // 与 smartroute.bpf.c 的 MAX_POLICY 一致
	DataDir   = "/usr/share/smartroute"
	tcpIdle   = 7200 // TCP 连接空闲超时（秒）；设备发出 FIN / RST 时提前结束
)

// Msg 是给界面显示的消息：英文格式串（只用 %s，界面按它查翻译）+ 参数
type Msg struct {
	Fmt  string
	Args []string `json:",omitempty"`
}

func msg(f string, a ...any) Msg {
	args := make([]string, len(a))
	for i, v := range a {
		args[i] = fmt.Sprint(v)
	}
	return Msg{f, args}
}

func (m Msg) String() string {
	a := make([]any, len(m.Args))
	for i, v := range m.Args {
		a[i] = v
	}
	return fmt.Sprintf(m.Fmt, a...)
}

type Settings struct {
	Enabled              bool
	Ifaces               []string // 工作接口（网桥），如 br-lan、br-guest
	IPv6                 bool
	MarkMask             uint32
	TableBase            int
	Idle, DNSKeep        uint32
	GeositeURL, GeoipURL string
	UpdateHour           int    // 每天几点更新数据文件，-1 不更新
	DownloadExit         string // 下载数据文件经哪个出口（主路由直连访问不了 GitHub 时）
	DNSPersist           bool   // 停止时保存域名记录，启动时恢复
	FixInvalid           bool   // fw4 放行经网关、被判为无效的连接
	BlockDoT             bool   // 拒绝工作接口上的设备访问 853 端口（DoT / DoQ），使其回退到明文 DNS
}

type Exit struct {
	ID, Name, Type string // Type: gateway | interface | direct | reject
	V6Mode         string // follow | v4only | none
	Network        string `json:",omitempty"` // 接口出口：netifd 逻辑接口名，如 wg、wan2
	Index          int
	Mark           uint32
	Table          int
	IP4, IP6       netip.Addr     // IP6：手动填写的 link-local 下一跳
	DNS4, DNS6     netip.AddrPort // 可选：出口 DNS（IPv4 / IPv6，默认端口 53）
	DNSFail        string         // 出口 DNS 不可用时：fallback 沿故障切换链换用其他出口的 DNS | router 改用主路由 DNS | keep 不换
	DNSMoveTraffic bool           // 出口 DNS 不可用时，流量也按故障切换处理
	DNS6None       string         // IPv6 查询找不到可用出口时：reject 拒绝（设备改查 IPv4）| router 交给主路由 DNS
	DNSCheck       string         // 检测 DNS 用的域名
	NoHijack       bool           // 网关：放行网关自身发出的 DNS 查询，不被主路由的 DNS 劫持
	Fallback       string         // 故障时改用的出口 ID，空 = 直连
	CheckIP        netip.Addr     // 健康检查探测地址，默认网关本身；经该出口发出
	CheckIP6       netip.Addr     // IPv6 探测地址，默认网关的 IPv6 下一跳
	Interval       int            // 检测间隔（秒），0 不检测
	// 运行时解析
	MAC      HW             `json:",omitempty"`
	LL       netip.Addr     // 网关的 IPv6 下一跳：通常是 link-local，网关不应答组播 ping 时可能是它的全局地址
	Dev      string         `json:",omitempty"` // 网关所在接口 / 接口出口的设备名
	Gw4, Gw6 netip.Addr     // 接口出口的下一跳（点对点接口没有）
	AutoDNS6 netip.AddrPort // 按 DNS4 自动推算/发现的 IPv6 DNS（未手动设 DNS6 时生效）
}

// EffDNS6 返回出口实际使用的 IPv6 DNS：手动配置的 dns6 优先，否则用按 dns 自动解析出的地址
func (x *Exit) EffDNS6() netip.AddrPort {
	if x.DNS6.IsValid() {
		return x.DNS6
	}
	return x.AutoDNS6
}

// HW 是 MAC 地址，JSON 里输出为 aa:bb:cc:dd:ee:ff
type HW net.HardwareAddr

func (h HW) MarshalText() ([]byte, error) { return []byte(net.HardwareAddr(h).String()), nil }

func (h *HW) UnmarshalText(b []byte) error {
	m, err := net.ParseMAC(string(b))
	*h = HW(m)
	return err
}

// Link：IP 规则的设备，按该 IPv4 当前对应的 MAC 管 IPv6
type Link struct {
	IP   netip.Addr
	Bits uint64
	MAC  HW `json:",omitempty"`
}

type Plan struct {
	S           Settings
	Exits       []*Exit // 只含 mark ≠ 0 的出口
	Policies    []bpf.SrPolicy
	PolicyIDs   []string
	PolicyExits []string // 每条分流的出口 ID，故障切换时据此换 mark
	MAC         map[[6]byte]bpf.SrMacVal
	Dev4, Dev6  []rules.Prefix
	Links       []*Link
	Rules       *rules.Result
	Warnings    []Msg
	// 诊断用：配置段 → 位 / 显示名
	DevBit, RGBit map[string]uint64
	Names         map[string]string
}

func (p *Plan) warn(f string, a ...any) { p.Warnings = append(p.Warnings, msg(f, a...)) }

// ExitMark 出口的 mark（不考虑健康状态；不存在或直连为 0）
func (p *Plan) ExitMark(id string) uint32 {
	if x := p.exitByID(id); x != nil {
		return x.Mark
	}
	return 0
}

func (p *Plan) exitByID(id string) *Exit {
	for _, x := range p.Exits {
		if x.ID == id {
			return x
		}
	}
	return nil
}

func settings(s *uci.Section) Settings {
	num := func(k string, def int) int {
		if n, err := strconv.ParseInt(s.Get(k), 0, 64); err == nil {
			return int(n)
		}
		return def
	}
	ifaces := s.Opts["interface"]
	if len(ifaces) == 0 {
		ifaces = []string{"br-lan"}
	}
	return Settings{
		Enabled:      s.Bool("enabled", false),
		Ifaces:       ifaces,
		IPv6:         s.Bool("ipv6", true),
		MarkMask:     uint32(num("mark_mask", 0x1f000000)),
		TableBase:    num("table_base", 3100),
		Idle:         uint32(num("idle_timeout", 600)),
		DNSKeep:      uint32(num("dns_keep", 300)),
		GeositeURL:   s.GetDef("geosite_url", "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"),
		GeoipURL:     s.GetDef("geoip_url", "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"),
		UpdateHour:   num("update_hour", 4),
		DownloadExit: s.Get("download_exit"),
		DNSPersist:   s.Bool("dns_persist", true),
		FixInvalid:   s.Bool("fix_invalid", true),
		BlockDoT:     s.Bool("block_dot", false),
	}
}

// Compile 编译配置。配置里的个别错误（引用不存在、地址格式错）记为警告并跳过该项，不影响其余部分。
// fw 为防火墙配置，用于检查接口出口的地址伪装（nil 时不检查）
func Compile(secs []*uci.Section, dataDir string, fw []*uci.Section) (*Plan, error) {
	p := &Plan{MAC: map[[6]byte]bpf.SrMacVal{}}
	byName := map[string]*uci.Section{}
	main := &uci.Section{Opts: map[string][]string{}}
	for _, s := range secs {
		byName[s.Name] = s
		if s.Type == "global" {
			main = s
		}
	}
	p.S = settings(main)
	if p.S.MarkMask == 0 {
		return nil, fmt.Errorf("mark_mask must not be 0")
	}
	of := func(typ string) []*uci.Section {
		var out []*uci.Section
		for _, s := range secs {
			if s.Type == typ {
				out = append(out, s)
			}
		}
		return out
	}
	policies := of("policy")

	// 设备组各占一位；被分流直接选中的设备再各占一位
	devBit, rgBit := map[string]uint64{}, map[string]uint64{}
	alloc := func(m map[string]uint64, name, what string) error {
		if len(m) == 64 {
			return fmt.Errorf("more than 64 %s", what)
		}
		m[name] = 1 << len(m)
		return nil
	}
	for _, s := range of("group") {
		if err := alloc(devBit, s.Name, "device groups and devices selected in policies"); err != nil {
			return nil, err
		}
	}
	for _, s := range policies {
		for _, src := range s.Opts["source"] {
			if d := byName[src]; d != nil && d.Type == "device" && devBit[src] == 0 {
				if err := alloc(devBit, src, "device groups and devices selected in policies"); err != nil {
					return nil, err
				}
			}
		}
	}
	var groups []rules.Group
	for _, s := range of("rule_group") {
		if err := alloc(rgBit, s.Name, "rule groups"); err != nil {
			return nil, err
		}
		groups = append(groups, rules.Group{Bit: rgBit[s.Name], Rules: s.Opts["rule"]})
	}

	// 出口：mark = 序号 << 掩码最低位
	shift := bits.TrailingZeros32(p.S.MarkMask)
	maxExit := int(p.S.MarkMask >> shift)
	exits := map[string]*Exit{"direct": {ID: "direct", Name: "direct", Type: "direct"}}
	addExit := func(e *Exit) error {
		if e.Type != "direct" {
			if len(p.Exits) == maxExit || len(p.Exits) == maxPolicy {
				return fmt.Errorf("more exits than mark_mask can hold (%d)", min(maxExit, maxPolicy))
			}
			e.Index = len(p.Exits) + 1
			e.Mark = uint32(e.Index) << shift
			e.Table = p.S.TableBase + e.Index
			p.Exits = append(p.Exits, e)
		}
		exits[e.ID] = e
		return nil
	}
	for _, s := range of("exit") {
		e := &Exit{ID: s.Name, Name: s.GetDef("name", s.Name), Type: s.GetDef("type", "gateway"), V6Mode: s.GetDef("ipv6", "follow"),
			Fallback: s.Get("fallback"), Interval: 5}
		if n, err := strconv.Atoi(s.Get("check_interval")); err == nil && n >= 0 {
			e.Interval = n
		}
		switch e.Type {
		case "gateway":
			a, err := netip.ParseAddr(s.Get("ip"))
			if err != nil || !a.Is4() {
				p.warn("Exit %s: invalid gateway address %s, skipped", e.Name, s.Get("ip"))
				continue
			}
			e.IP4, e.CheckIP = a, a
			if v := s.Get("ip6"); v != "" {
				if a, err := netip.ParseAddr(v); err == nil && a.IsLinkLocalUnicast() {
					e.IP6 = a
				} else {
					p.warn("Exit %s: IPv6 next hop %s must be a link-local address, ignored", e.Name, v)
				}
			}
		case "interface":
			e.Network = s.Get("network")
			if e.Network == "" {
				p.warn("Exit %s: no interface selected, skipped", e.Name)
				continue
			}
			if fw != nil && !masqueraded(fw, e.Network) {
				p.warn("Exit %s: interface %s is not in a firewall zone with masquerading; add it to such a zone (for example wan), otherwise traffic through it gets no replies", e.Name, e.Network)
			}
		case "direct", "reject":
		default:
			p.warn("Exit %s: unsupported type %s, skipped", e.Name, e.Type)
			continue
		}
		if v := s.Get("check_ip"); v != "" {
			if c, err := netip.ParseAddr(v); err == nil && c.Is4() {
				e.CheckIP = c
			} else {
				p.warn("Exit %s: check address %s must be an IPv4 address, ignored", e.Name, v)
			}
		}
		if v := s.Get("check_ip6"); v != "" {
			if c, err := netip.ParseAddr(v); err == nil && c.Is6() && !c.Is4In6() {
				e.CheckIP6 = c
			} else {
				p.warn("Exit %s: IPv6 check address %s must be an IPv6 address, ignored", e.Name, v)
			}
		}
		if v := s.Get("dns"); v != "" {
			if ap, ok := parseDNS(v, false); ok {
				e.DNS4 = ap
				if v6, ok := knownDNS6[ap.Addr().String()]; ok {
					e.AutoDNS6 = netip.AddrPortFrom(netip.MustParseAddr(v6), ap.Port())
				}
			} else {
				p.warn("Exit %s: DNS address %s must be an IPv4 address (optional :port), ignored", e.Name, v)
			}
		}
		if v := s.Get("dns6"); v != "" {
			if ap, ok := parseDNS(v, true); ok && !ap.Addr().IsLinkLocalUnicast() {
				e.DNS6 = ap
			} else if ok && ap.Addr().IsLinkLocalUnicast() {
				p.warn("Exit %s: IPv6 DNS address %s must not be a link-local address, ignored", e.Name, v)
			} else {
				p.warn("Exit %s: IPv6 DNS address %s must be an IPv6 address (optional [addr]:port), ignored", e.Name, v)
			}
		}
		e.DNSFail = s.GetDef("dns_fail", "fallback")
		if !slices.Contains([]string{"fallback", "router", "keep"}, e.DNSFail) {
			p.warn("Exit %s: unsupported DNS failure handling %s, using fallback", e.Name, e.DNSFail)
			e.DNSFail = "fallback"
		}
		e.DNSMoveTraffic = s.Get("dns_fail_traffic") == "1"
		e.DNS6None = s.GetDef("dns6_none", "reject")
		if e.DNS6None != "reject" && e.DNS6None != "router" {
			p.warn("Exit %s: unsupported IPv6 DNS handling %s, using reject", e.Name, e.DNS6None)
			e.DNS6None = "reject"
		}
		e.DNSCheck = strings.Trim(strings.ToLower(strings.TrimSpace(s.GetDef("dns_check", defaultDNSCheck))), ".")
		if _, ok := rules.DomainHash(e.DNSCheck); !ok || !strings.Contains(e.DNSCheck, ".") {
			p.warn("Exit %s: DNS check domain %s is invalid, using %s", e.Name, e.DNSCheck, defaultDNSCheck)
			e.DNSCheck = defaultDNSCheck
		}
		e.NoHijack = e.Type == "gateway" && s.GetDef("dns_nohijack", "1") == "1"
		if err := addExit(e); err != nil {
			return nil, err
		}
	}

	// 内置的拦截出口：被分流或故障切换引用时才占用一个序号
	needReject := func(id string) error {
		if id == "reject" && exits[id] == nil {
			return addExit(&Exit{ID: "reject", Name: "reject", Type: "reject"})
		}
		return nil
	}
	for _, x := range p.Exits {
		if x.Fallback != "" && exits[x.Fallback] == nil && x.Fallback != "reject" {
			p.warn("Exit %s: fallback exit %s does not exist, direct connection is used on failure", x.Name, x.Fallback)
			x.Fallback = ""
		}
		if err := needReject(x.Fallback); err != nil {
			return nil, err
		}
	}
	for _, s := range policies {
		if !s.Bool("enabled", true) {
			continue
		}
		if len(p.Policies) == maxPolicy {
			p.warn("More than %s policies, the rest are not applied", maxPolicy)
			break
		}
		var pol bpf.SrPolicy
		for _, src := range s.Opts["source"] {
			switch {
			case src == "all":
				pol.Flags |= pAllDev
			case devBit[src] != 0:
				pol.Dev |= devBit[src]
			default:
				p.warn("Policy %s: device source %s does not exist", s.Name, src)
			}
		}
		if pol.Dev == 0 && pol.Flags&pAllDev == 0 {
			p.warn("Policy %s: no valid device source, not applied", s.Name)
			continue
		}
		if rgs := s.Opts["rule_group"]; len(rgs) == 0 {
			pol.Flags |= pAllRG
		} else {
			for _, g := range rgs {
				if rgBit[g] == 0 {
					p.warn("Policy %s: rule group %s does not exist", s.Name, g)
				}
				pol.Rg |= rgBit[g]
			}
			if pol.Rg == 0 {
				p.warn("Policy %s: no valid rule group, not applied", s.Name)
				continue
			}
		}
		if s.Bool("invert", false) {
			if pol.Flags&pAllRG != 0 {
				p.warn("Policy %s: \"all destinations\" cannot be inverted, not applied", s.Name)
				continue
			}
			pol.Flags |= pNeg
		}
		id := s.GetDef("exit", "direct")
		if err := needReject(id); err != nil {
			return nil, err
		}
		e := exits[id]
		if e == nil {
			p.warn("Policy %s: exit %s does not exist, not applied", s.Name, id)
			continue
		}
		pol.Mark = e.Mark
		p.Policies = append(p.Policies, pol)
		p.PolicyIDs = append(p.PolicyIDs, s.Name)
		p.PolicyExits = append(p.PolicyExits, id)
	}

	var dev4, dev6 []rules.Prefix
	for _, s := range of("device") {
		b := devBit[s.Name]
		for _, g := range s.Opts["group"] {
			if devBit[g] == 0 || byName[g].Type != "group" {
				p.warn("Device %s: device group %s does not exist", s.Name, g)
				continue
			}
			b |= devBit[g]
		}
		if b == 0 {
			continue
		}
		mac, ip, typ := s.Get("mac"), s.Get("ip"), s.Get("type")
		if typ == "" { // 手动添加时按地址格式确定：有 MAC 用 MAC 规则
			typ = map[bool]string{true: "mac", false: "ip"}[mac != ""]
		}
		switch typ {
		case "mac":
			hw, err := net.ParseMAC(mac)
			if err != nil || len(hw) != 6 {
				p.warn("Device %s: invalid MAC %s", s.Name, mac)
				continue
			}
			k := [6]byte(hw)
			v := p.MAC[k]
			v.G4 |= b
			v.G6 |= b
			p.MAC[k] = v
		case "ip":
			pf, ok := rules.ParsePrefix(ip)
			if !ok {
				p.warn("Device %s: invalid IP %s", s.Name, ip)
				continue
			}
			if pf.Addr().Is4() {
				dev4 = append(dev4, rules.Prefix{P: pf, Bits: b})
				if pf.IsSingleIP() {
					p.Links = append(p.Links, &Link{IP: pf.Addr(), Bits: b})
				}
			} else {
				dev6 = append(dev6, rules.Prefix{P: pf, Bits: b})
			}
		default:
			p.warn("Device %s: invalid rule type %s", s.Name, typ)
		}
	}
	p.Dev4, p.Dev6 = rules.Merge(dev4), rules.Merge(dev6)
	p.DevBit, p.RGBit, p.Names = devBit, rgBit, map[string]string{}
	for _, s := range secs {
		p.Names[s.Name] = s.GetDef("name", s.Name)
	}
	p.Rules = rules.Compile(groups, dataDir)
	return p, nil
}

const defaultDNSCheck = "www.google.com"

// 常见公共 DNS 的 IPv4 → IPv6 映射：用户只需填 IPv4 DNS，IPv6 自动对应
var knownDNS6 = map[string]string{
	"8.8.8.8":         "2001:4860:4860::8888",
	"8.8.4.4":         "2001:4860:4860::8844",
	"1.1.1.1":         "2606:4700:4700::1111",
	"1.0.0.1":         "2606:4700:4700::1001",
	"9.9.9.9":         "2620:fe::fe",
	"149.112.112.112": "2620:fe::9",
	"208.67.222.222":  "2620:119:35::35",
	"208.67.220.220":  "2620:119:53::53",
	"223.5.5.5":       "2400:3200::1",
	"223.6.6.6":       "2400:3200:baba::1",
	"119.29.29.29":    "2402:4e00::",
	"180.184.1.1":     "2400:da00::6666",
	"94.140.14.14":    "2a10:50c0::ad1:ff",
	"94.140.15.15":    "2a10:50c0::ad2:ff",
}

// parseDNS 解析出口 DNS 地址：支持纯 IP（默认端口 53）或 IP:端口（IPv6 为 [IP]:端口）
func parseDNS(raw string, v6 bool) (netip.AddrPort, bool) {
	s := strings.TrimSpace(raw)
	var ap netip.AddrPort
	if a, err := netip.ParseAddr(s); err == nil {
		ap = netip.AddrPortFrom(a, 53)
	} else if p, err := netip.ParseAddrPort(s); err == nil && p.Port() > 0 {
		ap = p
	} else {
		return netip.AddrPort{}, false
	}
	a := ap.Addr()
	if v6 {
		if !a.Is6() || a.Is4In6() {
			return netip.AddrPort{}, false
		}
	} else if !a.Is4() {
		return netip.AddrPort{}, false
	}
	return ap, true
}

// masqueraded：逻辑接口所在的防火墙区域开启了地址伪装
func masqueraded(fw []*uci.Section, network string) bool {
	for _, z := range fw {
		if z.Type != "zone" || !z.Bool("masq", false) {
			continue
		}
		var nets []string
		for _, v := range z.Opts["network"] { // 可能是列表，也可能是空格分隔的字符串
			nets = append(nets, strings.Fields(v)...)
		}
		if slices.Contains(nets, network) {
			return true
		}
	}
	return false
}
