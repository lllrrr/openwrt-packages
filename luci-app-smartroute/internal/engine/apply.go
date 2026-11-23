package engine

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"maps"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"

	"github.com/r1172464137/luci-app-smartroute/internal/bpf"
	"github.com/r1172464137/luci-app-smartroute/internal/rules"
	"github.com/r1172464137/luci-app-smartroute/internal/uci"
)

const (
	fwFile    = "/var/etc/smartroute.fw4.nft" // fw4 include（uci-defaults 里登记），放在 forward 链最前
	StateFile = "/var/run/smartroute/state.json"
	// 修改前的 send_redirects（每行“路径 值”），停止时恢复。存文件而不是内存：进程崩溃重启后不会把已改成的 0 当成原值
	redirFile = "/var/run/smartroute.redirects"
)

// 内置保护：私有、保留、组播地址永不分流；本机 LAN 侧各接口的网段在 Apply 时追加
var skipStatic = []string{
	"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
	"192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/3",
	"::/127", "fc00::/7", "fe80::/10", "ff00::/8",
}

type Engine struct {
	objs      *bpf.SrObjects
	links     map[string][]link.Link // 工作接口 → 挂载的程序
	ifidx     map[string]int         // 挂载时的接口序号：接口删除重建后会变
	started   bool
	tableBase int
	s         Settings // 最近一次应用的设置
	health    map[string]*health
	probes    chan ProbeResult
	events    []Event
	hitsDay   string
	linkMAC   map[netip.Addr]HW // IP 规则设备最近一次查到的 MAC
	dlMark    atomic.Uint32     // 下载数据文件用的 mark（跟随故障切换），供下载协程读取
}

func New() (*Engine, error) {
	objs, err := bpf.Open()
	if err != nil {
		return nil, err
	}
	return &Engine{objs: objs, links: map[string][]link.Link{}, ifidx: map[string]int{}, health: map[string]*health{},
		probes: make(chan ProbeResult, 64), linkMAC: map[netip.Addr]HW{}}, nil
}

// DownloadMark 下载数据文件时用的 mark：所选出口故障时为其备用出口
func (e *Engine) DownloadMark() uint32 { return e.dlMark.Load() }

func (e *Engine) Apply(p *Plan) error {
	if err := e.attach(p); err != nil {
		return err
	}
	if !e.started && p.S.DNSPersist {
		if n := e.loadDNS(); n > 0 {
			log.Printf("restored %d domain records", n)
		}
	}
	e.started = true
	if e.tableBase != 0 && e.tableBase != p.S.TableBase {
		cleanRoutes(e.tableBase)
	}
	e.tableBase, e.s = p.S.TableBase, p.S

	for _, x := range p.Exits {
		e.resolveExit(p, x)
	}
	e.resolveLinks(p)
	if err := e.syncMaps(p); err != nil {
		return err
	}
	if err := e.syncRoutes(p); err != nil {
		return err
	}
	if err := setFirewall(p, e, true); err != nil {
		return err
	}
	if hasDNS(p) && bridgeNFEnabled() {
		p.warn("net.bridge.bridge-nf-call-iptables is enabled, so exit DNS redirection will not take effect; set it to 0")
	}
	for _, w := range p.Warnings {
		log.Print(w)
	}
	e.event(false, "Configuration applied (%s policies, %s exits, %s rules)", len(p.Policies), len(p.Exits), p.Rules.Count)
	err := writeState(p, e)
	// 规则已写进内核表，释放用户态副本（十几万条）并把内存还给系统
	p.Rules.Domains, p.Rules.V4, p.Rules.V6 = nil, nil, nil
	debug.FreeOSMemory()
	return err
}

// attach 挂到各工作接口；接口被删除重建（netifd 重启）后序号会变，要重新挂。不存在的接口跳过
func (e *Engine) attach(p *Plan) error {
	want := map[string]int{}
	for _, n := range p.S.Ifaces {
		if ifc, err := net.InterfaceByName(n); err == nil {
			want[n] = ifc.Index
		} else {
			log.Printf("working interface %s does not exist, skipped", n)
		}
	}
	if len(want) == 0 {
		return fmt.Errorf("none of the working interfaces exist: %s", strings.Join(p.S.Ifaces, ", "))
	}
	for n, ls := range e.links {
		if want[n] != e.ifidx[n] {
			for _, l := range ls {
				l.Close()
			}
			delete(e.links, n)
		}
	}
	for n, idx := range want {
		if e.links[n] != nil {
			continue
		}
		ls, err := bpf.Attach(e.objs, n)
		if err != nil {
			return err
		}
		e.links[n], e.ifidx[n] = ls, idx
	}
	return nil
}

// Rewire 接口或地址变化后（netifd 重载、WAN 重拨、前缀变化）重新挂载、更新保护网段与路由，不重新编译规则
func (e *Engine) Rewire(p *Plan) error {
	if err := e.attach(p); err != nil {
		return err
	}
	for _, x := range p.Exits {
		if x.Type == "interface" {
			e.resolveExit(p, x)
		} else {
			resolveDNS6(x)
		}
	}
	skip4, skip6 := skipPrefixes()
	for _, err := range []error{
		syncMap(e.objs.SrSkip4, lpm4(skip4)), syncMap(e.objs.SrSkip6, lpm6(skip6)),
		e.syncRoutes(p),
		setFirewall(p, e, true),
	} {
		if err != nil {
			return err
		}
	}
	return nil
}

// Refresh 定时执行：刷新 IP 规则设备与网关的当前 MAC；网关换了网卡或还没取到 IPv6 下一跳时重新解析
func (e *Engine) Refresh(p *Plan) error {
	reroute, newLL, newDNS := false, false, false
	for _, x := range p.Exits {
		old := *x
		switch x.Type {
		case "gateway":
			m := HW(neighMAC(ifIndex(x.Dev), x.IP4))
			// 自动找到的 IPv6 下一跳探测不通：网关可能换了 link-local 地址（如重启后随机生成），重新找
			h := e.health[x.ID]
			lost := !x.IP6.IsValid() && h != nil && h.probe6 && !h.up6
			needLL := p.S.IPv6 && x.V6Mode == "follow" && (!x.LL.IsValid() || lost)
			if (m != nil && !bytes.Equal(m, x.MAC)) || needLL || x.Dev == "" {
				e.resolveExit(p, x)
			} else {
				resolveDNS6(x)
			}
		case "interface":
			e.resolveExit(p, x)
		}
		if x.LL != old.LL && x.LL.IsValid() {
			e.event(false, "Gateway %s: IPv6 next hop changed to %s", x.Name, x.LL)
		}
		if x.LL != old.LL { // 新下一跳重新开始 IPv6 健康计数，不沿用旧下一跳的故障状态
			v4, v6, _ := probeTargets(p, x)
			e.healthOf(x, v4, v6)
			newLL = true
		}
		newDNS = newDNS || x.AutoDNS6 != old.AutoDNS6
		reroute = reroute || x.LL != old.LL || x.Dev != old.Dev || x.Gw4 != old.Gw4 || x.Gw6 != old.Gw6
	}
	if newLL || newDNS {
		if err := e.syncPolicies(p); err != nil { // AAAA 屏蔽 / DNS 标志随 IPv6 状态变化
			return err
		}
	}
	if newDNS {
		if err := setFirewall(p, e, true); err != nil {
			return err
		}
	}
	if reroute {
		if err := e.syncRoutes(p); err != nil {
			return err
		}
	}
	e.resolveLinks(p)
	if err := e.syncMAC(p); err != nil {
		return err
	}
	e.resetHitsDaily()
	return writeState(p, e)
}

// resetHitsDaily：命中次数按天统计，跨天清零
func (e *Engine) resetHitsDaily() {
	day := time.Now().Format("2006-01-02")
	if e.hitsDay == day {
		return
	}
	if e.hitsDay != "" {
		zero := make([]uint64, ebpf.MustPossibleCPU())
		for i := uint32(0); i < maxPolicy; i++ {
			e.objs.SrHits.Put(i, zero)
		}
	}
	e.hitsDay = day
}

// Close 卸载并清理全部痕迹：程序、固定的表、ip rule 与路由表、nft、sysctl
func (e *Engine) Close() {
	for _, ls := range e.links {
		for _, l := range ls {
			l.Close()
		}
	}
	if e.s.DNSPersist {
		e.saveDNS()
	}
	e.objs.Close()
	bpf.Remove()
	if e.tableBase != 0 {
		cleanRoutes(e.tableBase)
	}
	setFirewall(nil, nil, false)
	os.RemoveAll(filepath.Dir(StateFile))
}

// ---------------- eBPF 表 ----------------

func (e *Engine) syncMAC(p *Plan) error {
	mac := map[bpf.SrMacKey]bpf.SrMacVal{}
	for k, v := range p.MAC {
		mac[bpf.SrMacKey{Mac: k}] = v
	}
	for _, l := range p.Links {
		if l.MAC != nil {
			k := bpf.SrMacKey{Mac: [6]byte(l.MAC)}
			v := mac[k]
			v.G6 |= l.Bits
			mac[k] = v
		}
	}
	for _, x := range p.Exits { // 出口自身的流量永不分流
		if x.MAC != nil {
			k := bpf.SrMacKey{Mac: [6]byte(x.MAC)}
			v := mac[k]
			v.Skip = 1
			mac[k] = v
		}
	}
	return syncMap(e.objs.SrMac, mac)
}

func (e *Engine) syncMaps(p *Plan) error {
	m := e.objs
	skip4, skip6 := skipPrefixes()
	for _, err := range []error{
		e.syncMAC(p),
		syncMap(m.SrDev4, lpm4(p.Dev4)), syncMap(m.SrDev6, lpm6(p.Dev6)),
		syncMap(m.SrSkip4, lpm4(skip4)), syncMap(m.SrSkip6, lpm6(skip6)),
		syncMap(m.SrRg4, lpm4(p.Rules.V4)), syncMap(m.SrRg6, lpm6(p.Rules.V6)),
		syncMap(m.SrDom, p.Rules.Domains),
		syncMap(m.SrDnsSkip, dnsSkipMap()),
		e.syncPolicies(p), // 最后写：分流条数生效的同时，前面的表都已就绪
	} {
		if err != nil {
			return fmt.Errorf("write eBPF maps: %w", err)
		}
	}
	return nil
}

// syncMap 让表的内容等于 want：覆盖写入、删掉多余项，不清空重写（清空期间会漏判）。
// 优先批量写（十几万条只需几次系统调用）；表类型不支持批量（前缀树）时逐条写
func syncMap[K comparable, V any](m *ebpf.Map, want map[K]V) error {
	var k K
	var v V
	var stale []K
	it := m.Iterate()
	for it.Next(&k, &v) {
		if _, ok := want[k]; !ok {
			stale = append(stale, k)
		}
	}
	if err := it.Err(); err != nil {
		return err
	}
	if len(stale) > 0 {
		if _, err := m.BatchDelete(stale, nil); err != nil {
			for _, k := range stale {
				m.Delete(k)
			}
		}
	}
	if len(want) == 0 {
		return nil
	}
	keys, vals := make([]K, 0, len(want)), make([]V, 0, len(want))
	for k, v := range want {
		keys, vals = append(keys, k), append(vals, v)
	}
	if _, err := m.BatchUpdate(keys, vals, nil); err == nil {
		return nil
	}
	for i := range keys {
		if err := m.Put(keys[i], vals[i]); err != nil {
			return err
		}
	}
	return nil
}

func lpm4(ps []rules.Prefix) map[bpf.SrLpm4]uint64 {
	out := map[bpf.SrLpm4]uint64{}
	for _, p := range ps {
		out[bpf.SrLpm4{Plen: uint32(p.P.Bits()), Addr: p.P.Addr().As4()}] = p.Bits
	}
	return out
}

func lpm6(ps []rules.Prefix) map[bpf.SrLpm6]uint64 {
	out := map[bpf.SrLpm6]uint64{}
	for _, p := range ps {
		out[bpf.SrLpm6{Plen: uint32(p.P.Bits()), Addr: p.P.Addr().As16()}] = p.Bits
	}
	return out
}

// wanLinks：主路由表里带默认路由的接口（WAN、第二条 WAN、PPPoE）
func wanLinks() map[int]bool {
	out := map[int]bool{}
	for _, fam := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		rs, _ := netlink.RouteListFiltered(fam, &netlink.Route{Table: unix.RT_TABLE_MAIN}, netlink.RT_FILTER_TABLE)
		for _, r := range rs {
			if r.Dst == nil || r.Dst.IP.IsUnspecified() {
				out[r.LinkIndex] = true
			}
		}
	}
	return out
}

// skipPrefixes：内置保护网段 + 本机 LAN 侧各接口的网段（LAN 网段、委派的 v6 前缀）。
// WAN 侧接口的网段不加：那是运营商的网段，里面的地址照常分流
func skipPrefixes() (v4, v6 []rules.Prefix) {
	var all []netip.Prefix
	for _, s := range skipStatic {
		all = append(all, netip.MustParsePrefix(s))
	}
	wan := wanLinks()
	if addrs, err := netlink.AddrList(nil, netlink.FAMILY_ALL); err == nil {
		for _, a := range addrs {
			if wan[a.LinkIndex] {
				continue
			}
			if ip, ok := netip.AddrFromSlice(a.IP); ok {
				ones, _ := a.Mask.Size()
				if pf, err := ip.Unmap().Prefix(ones); err == nil {
					all = append(all, pf)
				}
			}
		}
	}
	for _, pf := range all {
		if pf.Addr().Is4() {
			v4 = append(v4, rules.Prefix{P: pf, Bits: 1})
		} else {
			v6 = append(v6, rules.Prefix{P: pf, Bits: 1})
		}
	}
	return rules.Merge(v4), rules.Merge(v6)
}

// ---------------- 出口解析 ----------------

func ifIndex(name string) int {
	if ifc, err := net.InterfaceByName(name); err == nil {
		return ifc.Index
	}
	return -1
}

// neighMAC 在邻居表里查 IP 对应的 MAC；ifindex 为 0 时查全部接口
func neighMAC(ifindex int, ip netip.Addr) net.HardwareAddr {
	if ifindex < 0 {
		return nil
	}
	fam := netlink.FAMILY_V4
	if ip.Is6() {
		fam = netlink.FAMILY_V6
	}
	ns, _ := netlink.NeighList(ifindex, fam)
	for _, n := range ns {
		if a, ok := netip.AddrFromSlice(n.IP); ok && a.Unmap() == ip && len(n.HardwareAddr) == 6 &&
			n.State&(netlink.NUD_FAILED|netlink.NUD_INCOMPLETE) == 0 {
			return n.HardwareAddr
		}
	}
	return nil
}

func ping(addr string, v6 bool) bool {
	args := []string{"-c1", "-W1", addr}
	if v6 {
		args = append([]string{"-6"}, args...)
	}
	return exec.Command("ping", args...).Run() == nil
}

func eui64(mac net.HardwareAddr) netip.Addr {
	b := [16]byte{0: 0xfe, 1: 0x80, 8: mac[0] ^ 2, 9: mac[1], 10: mac[2], 11: 0xff, 12: 0xfe, 13: mac[3], 14: mac[4], 15: mac[5]}
	return netip.AddrFrom16(b)
}

func (e *Engine) resolveExit(p *Plan, x *Exit) {
	switch x.Type {
	case "gateway":
		resolveGateway(p, x)
	case "interface":
		resolveInterface(p, x)
	}
	resolveDNS6(x)
}

// resolveDNS6 按配置的 IPv4 DNS 自动解析 IPv6 DNS：常见公共 DNS 直接查映射表；
// 局域网地址（如网关自身）按其 MAC 在 IPv6 邻居表找全局/ULA 地址（不能用 link-local）
func resolveDNS6(x *Exit) {
	if !x.DNS4.IsValid() || x.DNS6.IsValid() {
		x.AutoDNS6 = netip.AddrPort{}
		return
	}
	if v6, ok := knownDNS6[x.DNS4.Addr().String()]; ok {
		x.AutoDNS6 = netip.AddrPortFrom(netip.MustParseAddr(v6), x.DNS4.Port())
		return
	}
	var mac net.HardwareAddr
	if x.Type == "gateway" && x.DNS4.Addr() == x.IP4 && x.MAC != nil {
		mac = net.HardwareAddr(x.MAC)
	} else {
		mac = neighMAC(0, x.DNS4.Addr())
	}
	if mac != nil {
		if a := globalV6ByMAC(ifIndex(x.Dev), mac); a.IsValid() {
			x.AutoDNS6 = netip.AddrPortFrom(a, x.DNS4.Port())
			return
		}
	}
	x.AutoDNS6 = netip.AddrPort{}
}

// globalV6ByMAC 在邻居表里找该 MAC 的全局/ULA IPv6 地址（非 link-local），供 DNAT ip6 使用
func globalV6ByMAC(idx int, mac net.HardwareAddr) netip.Addr {
	best, bestScore := netip.Addr{}, 0
	ns, _ := netlink.NeighList(idx, netlink.FAMILY_V6)
	for _, n := range ns {
		a, ok := netip.AddrFromSlice(n.IP)
		if !ok || !bytes.Equal(n.HardwareAddr, mac) || n.State&(netlink.NUD_FAILED|netlink.NUD_INCOMPLETE) != 0 ||
			!a.IsGlobalUnicast() || a.IsLinkLocalUnicast() {
			continue
		}
		score := 1
		if n.State&(netlink.NUD_REACHABLE|netlink.NUD_DELAY|netlink.NUD_PROBE|netlink.NUD_PERMANENT) != 0 {
			score += 2
		}
		if a.IsPrivate() { // ULA（fc00::/7）前缀稳定，优先于会变化的运营商前缀
			score++
		}
		if score > bestScore {
			best, bestScore = a, score
		}
	}
	return best
}

// resolveGateway 得到网关所在接口、MAC 与 IPv6 下一跳：手动填写 → EUI-64 推算并 ping 验证 → 组播 ping 后按 MAC 查邻居表
func resolveGateway(p *Plan, x *Exit) {
	x.Dev = ""
	if rs, err := netlink.RouteGet(x.IP4.AsSlice()); err == nil && len(rs) > 0 {
		if l, err := netlink.LinkByIndex(rs[0].LinkIndex); err == nil {
			x.Dev = l.Attrs().Name
		}
	}
	if x.Dev == "" {
		p.warn("Exit %s: no route to gateway %s", x.Name, x.IP4)
		return
	}
	idx := ifIndex(x.Dev)
	if x.MAC = HW(neighMAC(idx, x.IP4)); x.MAC == nil {
		ping(x.IP4.String(), false)
		x.MAC = HW(neighMAC(idx, x.IP4))
	}
	if x.MAC == nil {
		p.warn("Exit %s: gateway %s does not respond, its MAC is unknown", x.Name, x.IP4)
	}
	if !p.S.IPv6 || x.V6Mode != "follow" {
		return
	}
	zone := "%" + x.Dev
	x.LL = netip.Addr{}
	switch {
	case x.IP6.IsValid():
		x.LL = x.IP6
	case x.MAC == nil:
	case ping(eui64(net.HardwareAddr(x.MAC)).String()+zone, true):
		x.LL = eui64(net.HardwareAddr(x.MAC))
	default:
		// 组播 ping 的应答者逐个单播 ping 一次，让邻居表记下其 MAC（网关已缓存本机 MAC 时不会主动发邻居请求）；
		// 再在邻居表里按网关 MAC 找它的地址。有的网关不应答组播 ping，所以也接受它的全局地址作下一跳
		for _, a := range echoAll(idx, time.Second) {
			if neighMAC(idx, a) == nil {
				ping(a.String()+zone, true)
			}
		}
		x.LL = nextHopByMAC(idx, net.HardwareAddr(x.MAC))
	}
	if !x.LL.IsValid() {
		p.warn("Exit %s: IPv6 next hop not found, IPv6 traffic goes direct", x.Name)
	}
}

// nextHopByMAC 在邻居表里找该 MAC 的 IPv6 地址：可达的优先于过期的（过期条目可能是网关已不用的旧地址），
// 同等状态下 link-local 优先于全局地址
func nextHopByMAC(idx int, mac net.HardwareAddr) netip.Addr {
	best, bestScore := netip.Addr{}, 0
	ns, _ := netlink.NeighList(idx, netlink.FAMILY_V6)
	for _, n := range ns {
		a, ok := netip.AddrFromSlice(n.IP)
		if !ok || !bytes.Equal(n.HardwareAddr, mac) || n.State&(netlink.NUD_FAILED|netlink.NUD_INCOMPLETE) != 0 ||
			!(a.IsLinkLocalUnicast() || a.IsGlobalUnicast()) {
			continue
		}
		score := 1
		if n.State&(netlink.NUD_REACHABLE|netlink.NUD_DELAY|netlink.NUD_PROBE|netlink.NUD_PERMANENT) != 0 {
			score += 2
		}
		if a.IsLinkLocalUnicast() {
			score++
		}
		if score > bestScore {
			best, bestScore = a, score
		}
	}
	return best
}

// resolveInterface 从 netifd 取接口出口的设备名与下一跳（点对点接口如 WireGuard、PPPoE 没有下一跳）
func resolveInterface(p *Plan, x *Exit) {
	type route struct {
		Target  string
		Mask    int
		Nexthop string
	}
	var st struct {
		Up       bool
		L3Device string `json:"l3_device"`
		Route    []route
		Inactive struct{ Route []route }
	}
	x.Dev, x.Gw4, x.Gw6 = "", netip.Addr{}, netip.Addr{}
	out, err := exec.Command("ubus", "call", "network.interface."+x.Network, "status").Output()
	if err != nil || json.Unmarshal(out, &st) != nil || !st.Up || st.L3Device == "" {
		p.warn("Exit %s: interface %s is down or does not exist, its traffic goes direct", x.Name, x.Network)
		return
	}
	x.Dev = st.L3Device
	for _, r := range append(st.Route, st.Inactive.Route...) {
		nh, err := netip.ParseAddr(r.Nexthop)
		if r.Mask != 0 || err != nil || nh.IsUnspecified() {
			continue
		}
		if r.Target == "0.0.0.0" && !x.Gw4.IsValid() {
			x.Gw4 = nh
		} else if r.Target == "::" && !x.Gw6.IsValid() {
			x.Gw6 = nh
		}
	}
}

// resolveLinks：IP 规则的设备，按 邻居表 → DHCP 租约 找到当前 MAC
// 查不到时沿用上次查到的 MAC（邻居表条目会过期，而设备的 IP 与 MAC 很少变化）
func (e *Engine) resolveLinks(p *Plan) {
	leases := map[netip.Addr]net.HardwareAddr{}
	if f, err := os.Open("/tmp/dhcp.leases"); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			fs := strings.Fields(sc.Text()) // 到期时间 MAC IP 主机名 客户端ID
			if len(fs) >= 3 {
				hw, err1 := net.ParseMAC(fs[1])
				ip, err2 := netip.ParseAddr(fs[2])
				if err1 == nil && err2 == nil && len(hw) == 6 {
					leases[ip] = hw
				}
			}
		}
		f.Close()
	}
	for _, l := range p.Links {
		m := HW(neighMAC(0, l.IP))
		if m == nil {
			m = HW(leases[l.IP])
		}
		if m != nil {
			e.linkMAC[l.IP] = m
		}
		l.MAC = e.linkMAC[l.IP]
	}
}

// ---------------- 路由 ----------------

func defaultDst(fam int) *net.IPNet {
	if fam == netlink.FAMILY_V6 {
		return &net.IPNet{IP: net.IPv6zero, Mask: net.CIDRMask(0, 128)}
	}
	return &net.IPNet{IP: net.IPv4zero.To4(), Mask: net.CIDRMask(0, 32)}
}

// 本插件的 ip rule 优先级与路由表号都在 (base, base+maxPolicy]
func ours(base, v int) bool { return v > base && v <= base+maxPolicy }

// exitRoute 出口在某地址族下的默认路由；nil 表示表里不放这个地址族的路由（查不到就回落主表，即直连）
func (e *Engine) exitRoute(p *Plan, x *Exit, fam int) *netlink.Route {
	return route(p, x, fam, e.v6Mode(x))
}

// probeRoute：IPv6 探测地址的主机路由，按“转发”计算、不看健康状态。
// IPv6 因探测失败改成 prohibit 后，探测包靠它仍经出口发出，才能发现恢复（设备访问探测地址本身也走这条，影响可忽略）
func probeRoute(p *Plan, x *Exit) *netlink.Route {
	_, v6, _ := probeTargets(p, x)
	r := route(p, x, netlink.FAMILY_V6, "follow")
	if !v6.IsValid() || r == nil || r.Type == unix.RTN_PROHIBIT {
		return nil
	}
	r.Dst = &net.IPNet{IP: v6.AsSlice(), Mask: net.CIDRMask(128, 128)}
	if v6 == x.LL {
		r.Gw = nil // 探测的就是下一跳本身：同链路直达
	}
	return r
}

func route(p *Plan, x *Exit, fam int, v6mode string) *netlink.Route {
	r := &netlink.Route{Table: x.Table, Dst: defaultDst(fam)}
	v6 := fam == netlink.FAMILY_V6
	switch {
	case v6 && !p.S.IPv6:
		return nil
	case x.Type == "reject", v6 && v6mode == "v4only":
		r.Type = unix.RTN_PROHIBIT
		return r
	case v6 && v6mode != "follow", x.Dev == "":
		return nil
	}
	r.LinkIndex = ifIndex(x.Dev)
	switch {
	case x.Type == "gateway" && !v6:
		r.Gw = x.IP4.AsSlice()
	case x.Type == "gateway":
		if !x.LL.IsValid() {
			return nil
		}
		r.Gw = x.LL.AsSlice()
	case !v6 && x.Gw4.IsValid():
		r.Gw = x.Gw4.AsSlice()
	case v6 && x.Gw6.IsValid():
		r.Gw = x.Gw6.AsSlice()
	}
	return r
}

func (e *Engine) syncRoutes(p *Plan) error {
	base, mask := p.S.TableBase, p.S.MarkMask
	used := map[int]bool{}
	for _, fam := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		want := map[int]*netlink.Rule{}
		if fam == netlink.FAMILY_V4 || p.S.IPv6 {
			for _, x := range p.Exits {
				r := netlink.NewRule()
				r.Family, r.Priority, r.Mark, r.Mask, r.Table = fam, base+x.Index, x.Mark, &mask, x.Table
				want[r.Priority] = r
			}
		}
		have, err := netlink.RuleList(fam)
		if err != nil {
			return err
		}
		for _, r := range have {
			if !ours(base, r.Priority) {
				continue
			}
			if w := want[r.Priority]; w != nil && r.Mark == w.Mark && r.Mask != nil && *r.Mask == mask && r.Table == w.Table {
				delete(want, r.Priority)
				continue
			}
			netlink.RuleDel(&r)
		}
		for _, r := range want {
			if err := netlink.RuleAdd(r); err != nil {
				return fmt.Errorf("add ip rule: %w", err)
			}
		}
	}
	for _, x := range p.Exits {
		used[x.Table] = true
		for _, fam := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
			var want []*netlink.Route
			if r := e.exitRoute(p, x, fam); r != nil {
				want = append(want, r)
				if r := probeRoute(p, x); r != nil && fam == netlink.FAMILY_V6 {
					want = append(want, r)
				}
			}
			if err := syncTable(x.Table, fam, want); err != nil {
				return fmt.Errorf("exit %s route: %w", x.Name, err)
			}
		}
	}
	for t := base + 1; t <= base+maxPolicy; t++ {
		if !used[t] {
			flushTable(t, netlink.FAMILY_V4)
			flushTable(t, netlink.FAMILY_V6)
		}
	}
	return nil
}

// syncTable 让路由表里只剩 want 这些路由（按目标网段对应）
func syncTable(table, fam int, want []*netlink.Route) error {
	keep := map[string]bool{}
	for _, r := range want {
		keep[r.Dst.String()] = true
	}
	rs, _ := netlink.RouteListFiltered(fam, &netlink.Route{Table: table}, netlink.RT_FILTER_TABLE)
	for _, r := range rs {
		if r.Dst == nil || !keep[r.Dst.String()] { // 内核把默认路由的 Dst 报成 nil 或 ::/0，两种都按默认路由处理
			if r.Dst != nil || !keep[defaultDst(fam).String()] {
				netlink.RouteDel(&r)
			}
		}
	}
	for _, r := range want {
		if err := netlink.RouteReplace(r); err != nil {
			return err
		}
	}
	return nil
}

func flushTable(table, fam int) {
	rs, _ := netlink.RouteListFiltered(fam, &netlink.Route{Table: table}, netlink.RT_FILTER_TABLE)
	for _, r := range rs {
		netlink.RouteDel(&r)
	}
}

func cleanRoutes(base int) {
	for _, fam := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		rs, _ := netlink.RuleList(fam)
		for _, r := range rs {
			if ours(base, r.Priority) {
				netlink.RuleDel(&r)
			}
		}
		for t := base + 1; t <= base+maxPolicy; t++ {
			flushTable(t, fam)
		}
	}
}

// ---------------- 防火墙 ----------------

// 本地域名后缀（不转发 DNS，始终交由本机 dnsmasq）：内置常见本地后缀 + /etc/config/dhcp 里的本地域名
var dnsSkipStatic = []string{"lan", "local", "arpa", "localhost", "localdomain"}

func dnsSkipMap() map[uint64]uint8 {
	out := map[uint64]uint8{}
	add := func(s string) {
		s = strings.Trim(strings.ToLower(strings.TrimSpace(s)), ".")
		if s == "" {
			return
		}
		if h, ok := rules.DomainHash(s); ok {
			out[h] = 1
		}
	}
	for _, s := range dnsSkipStatic {
		add(s)
	}
	if secs, err := uci.Load("dhcp"); err == nil {
		for _, s := range secs {
			if s.Type == "dnsmasq" {
				add(s.Get("domain"))
			}
		}
	}
	return out
}

func hasDNS(p *Plan) bool {
	for _, x := range p.Exits {
		if x.DNS4.IsValid() || x.EffDNS6().IsValid() {
			return true
		}
	}
	return false
}

func bridgeNFEnabled() bool {
	for _, f := range []string{"/proc/sys/net/bridge/bridge-nf-call-iptables", "/proc/sys/net/bridge/bridge-nf-call-ip6tables"} {
		if b, err := os.ReadFile(f); err == nil && strings.TrimSpace(string(b)) == "1" {
			return true
		}
	}
	return false
}

// buildNFT 生成本插件专属的 nft 表（fw4 重载不影响）：
//   - 丢弃发出的 ICMPv6 重定向；可选拒绝 853 端口（DoT / DoQ）
//   - 出口 DNS（eBPF 给命中的 DNS 查询打上实际流量出口的 mark，TCP / UDP 53）：
//     dns_mark 按 DNSRouteOf 把 mark 改成 DNS 实际所在出口（每个包都改，路由随之走那个出口）；
//     dns_pre 按改后的 mark DNAT 到该出口的 DNS，早于 ImmortalWrt 的 DNS 劫持（dstnat+5）；
//     dns_post 对经网关出口的查询做伪装，保证回包经主路由；dns_v6_in / dns_fwd 拒绝没有可用出口的 IPv6 查询，dns_fwd 还清掉已转发查询的 mark
//   - 网关出口开启“不被劫持”时：网关自身发出的 UDP 53 查询抢先 DNAT 到原目标（地址不变，不影响 wan 区的伪装），劫持规则不再生效
func buildNFT(p *Plan, e *Engine) string {
	var b strings.Builder
	b.WriteString("table inet smartroute\ndelete table inet smartroute\n")
	if p == nil {
		return b.String()
	}
	ifs := `"` + strings.Join(p.S.Ifaces, `", "`) + `"`
	b.WriteString("table inet smartroute {\n\tchain out {\n\t\ttype filter hook output priority 0; policy accept;\n\t\ticmpv6 type nd-redirect drop\n\t}\n")
	if p.S.BlockDoT {
		b.WriteString("\tchain dot {\n\t\ttype filter hook forward priority -1; policy accept;\n" +
			"\t\tiifname { " + ifs + " } tcp dport 853 reject with tcp reset\n" +
			"\t\tiifname { " + ifs + " } udp dport 853 reject\n\t}\n")
	}

	mask := p.S.MarkMask
	mm := func(m uint32) string { return fmt.Sprintf("meta mark & 0x%08x == 0x%08x", mask, m) }
	const q53 = "meta l4proto { tcp, udp } th dport 53"
	var remap, dnat, masq, v6rej, gwSkip []string
	for _, t := range p.Exits {
		if t.Type == "gateway" && t.NoHijack && t.MAC != nil {
			mac := net.HardwareAddr(t.MAC).String()
			gwSkip = append(gwSkip, fmt.Sprintf("\t\tether saddr %s meta nfproto ipv4 udp dport 53 dnat ip to ip daddr\n", mac))
			if p.S.IPv6 {
				gwSkip = append(gwSkip, fmt.Sprintf("\t\tether saddr %s meta nfproto ipv6 udp dport 53 dnat ip6 to ip6 daddr\n", mac))
			}
		}
		if t.Type == "reject" || t.Mark == 0 || e == nil {
			continue
		}
		r := e.DNSRouteOf(p, t)
		for i, d := range []*Exit{r.V4, r.V6} {
			if d == nil {
				continue
			}
			fam, kw, to := "ipv4", "ip", t.DNS4
			if i == 1 {
				fam, kw, to = "ipv6", "ip6", t.EffDNS6()
			}
			if d != t {
				remap = append(remap, fmt.Sprintf("\t\tmeta nfproto %s %s %s meta mark set meta mark & 0x%08x | 0x%08x\n", fam, q53, mm(t.Mark), ^mask, d.Mark))
				continue
			}
			dnat = append(dnat, fmt.Sprintf("\t\tmeta nfproto %s %s %s dnat %s to %s\n", fam, q53, mm(t.Mark), kw, to))
			if t.Type == "gateway" { // 按 DNS 地址匹配：转发链里已清掉 mark
				oif := ifs
				if t.Dev != "" {
					oif = `"` + t.Dev + `"`
				}
				masq = append(masq, fmt.Sprintf("\t\tiifname { %s } oifname { %s } meta nfproto %s %s daddr %s meta l4proto { tcp, udp } th dport %d ct status dnat ct original proto-dst 53 masquerade\n",
					ifs, oif, fam, kw, to.Addr(), to.Port()))
			}
		}
		if r.V6Reject {
			v6rej = append(v6rej, fmt.Sprintf("\t\tiifname { %s } meta nfproto ipv6 %s %s reject\n", ifs, q53, mm(t.Mark)))
		}
	}
	// 转发的 DNS 查询选好路由后清掉出口 mark：开启流量卸载时，内核按这个包的 mark 给回程查路由，
	// 网关出口的路由表会把发回设备的应答送到网关（TCP 查询因此被重置）
	var unmark []string
	if len(dnat) > 0 {
		unmark = []string{fmt.Sprintf("\t\tiifname { %s } meta l4proto { tcp, udp } ct status dnat ct original proto-dst 53 meta mark set meta mark & 0x%08x\n", ifs, ^mask)}
	}
	chain := func(name, hook string, head []string, rules ...[]string) {
		n := 0
		for _, r := range rules {
			n += len(r)
		}
		if n == 0 {
			return
		}
		b.WriteString("\tchain " + name + " {\n\t\t" + hook + "; policy accept;\n")
		for _, h := range head {
			b.WriteString("\t\t" + h + "\n")
		}
		for _, r := range rules {
			for _, l := range r {
				b.WriteString(l)
			}
		}
		b.WriteString("\t}\n")
	}
	lanOnly := []string{"iifname != { " + ifs + " } return"}
	chain("dns_mark", "type filter hook prerouting priority mangle + 10", lanOnly, remap)
	chain("dns_pre", "type nat hook prerouting priority dstnat - 1", lanOnly, gwSkip, dnat)
	chain("dns_post", "type nat hook postrouting priority srcnat - 1", nil, masq)
	chain("dns_v6_in", "type filter hook input priority 0", nil, v6rej)
	chain("dns_fwd", "type filter hook forward priority -1", nil, v6rej, unmark)
	b.WriteString("}\n")
	return b.String()
}

// setFirewall：
//   - fw4 include：放行已打标、被 conntrack 判为无效的转发（经网关的连接回包不经过本机）；
//     放在 fw4 自己的 forward 链里才有用——另建链 accept 挡不住 fw4 的 drop。
//     停止或关闭时写空文件，不删除：fw4 重载时不报 include 文件不存在
//   - 本插件自己的 nft 表（fw4 重载不影响）：丢弃发出的 ICMPv6 重定向；可选拒绝 853 端口；出口 DNS DNAT 与伪装
//   - 关闭 IPv4 send_redirects
func setFirewall(p *Plan, e *Engine, on bool) error {
	content := ""
	if on && p.S.FixInvalid {
		content = fmt.Sprintf("meta mark & 0x%08x != 0 ct state invalid accept comment \"!smartroute\"\n", p.S.MarkMask)
	}
	if old, err := os.ReadFile(fwFile); err != nil || string(old) != content {
		os.MkdirAll("/var/etc", 0o755)
		if err := os.WriteFile(fwFile, []byte(content), 0o644); err != nil && on {
			return err
		}
		reloadFW4()
	}

	var nft string
	if on {
		nft = buildNFT(p, e)
	} else {
		nft = buildNFT(nil, nil)
	}
	cmd := exec.Command("nft", "-f", "-")
	cmd.Stdin = strings.NewReader(nft)
	if out, err := cmd.CombinedOutput(); err != nil && on {
		return fmt.Errorf("nft: %v %s", err, out)
	}

	saved, _ := os.ReadFile(redirFile)
	if !on {
		for _, line := range strings.Split(string(saved), "\n") {
			if f, v, ok := strings.Cut(line, " "); ok {
				os.WriteFile(f, []byte(v), 0o644)
			}
		}
		os.Remove(redirFile)
		return nil
	}
	for _, ifc := range append([]string{"all"}, p.S.Ifaces...) {
		f := "/proc/sys/net/ipv4/conf/" + ifc + "/send_redirects"
		if _, err := os.Stat(f); err != nil {
			continue
		}
		if !strings.Contains(string(saved), f+" ") {
			b, _ := os.ReadFile(f)
			saved = fmt.Appendf(saved, "%s %s\n", f, strings.TrimSpace(string(b)))
		}
		os.WriteFile(f, []byte("0"), 0o644)
	}
	return os.WriteFile(redirFile, saved, 0o644)
}

func reloadFW4() {
	if out, err := exec.Command("fw4", "-q", "reload").CombinedOutput(); err != nil {
		log.Printf("fw4 reload: %v %s", err, out)
	}
}

// ---------------- 状态 ----------------

type ExitHealth struct {
	Up     bool
	RTTms  float64 `json:",omitempty"`
	Up6    *bool   `json:",omitempty"` // 没有 IPv6 探测时为空
	RTT6ms float64 `json:",omitempty"`
	DNSUp  *bool   `json:",omitempty"` // 没有检测出口 DNS 时为空
	DNS6Up *bool   `json:",omitempty"`
}

// RouteView：分流指定某出口时实际的去向（出口故障、DNS 回退后），供诊断页使用
type RouteView struct {
	Actual     string // 实际流量出口 ID，direct = 直连
	DNS4, DNS6 string `json:",omitempty"` // 实际使用的 DNS 地址，空 = 主路由 DNS
	DNS4Exit   string `json:",omitempty"` // 该 DNS 所在出口 ID
	DNS6Exit   string `json:",omitempty"`
	DNS6Reject bool   `json:",omitempty"`
}

type State struct {
	Updated    time.Time
	Interfaces []string
	Policies   []string
	Exits      []*Exit
	Health     map[string]ExitHealth // 只有开启了健康检查的出口
	Routes     map[string]RouteView  // 按出口 ID
	Links      []*Link
	Rules      map[string]any
	Warnings   []Msg
	Events     []Event
	MaxRSSKiB  int64 // 进程至今的峰值内存
}

func groupCounts(p *Plan) map[string]int {
	out := map[string]int{}
	for sec, bit := range p.RGBit {
		out[sec] = p.Rules.PerBit[bit]
	}
	return out
}

func writeState(p *Plan, e *Engine) error {
	var ru syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	st := State{
		Updated: time.Now(), Interfaces: slices.Sorted(maps.Keys(e.links)), Policies: p.PolicyIDs, Exits: p.Exits, Links: p.Links, Warnings: p.Warnings,
		Rules: map[string]any{"count": p.Rules.Count, "domains": p.Rules.NDomains, "v4": p.Rules.NV4,
			"v6": p.Rules.NV6, "skipped": p.Rules.Skipped, "groups": groupCounts(p)},
		Health: map[string]ExitHealth{}, Events: e.events, MaxRSSKiB: int64(ru.Maxrss),
	}
	for _, x := range p.Exits {
		if h := e.health[x.ID]; h != nil && x.Interval > 0 {
			eh := ExitHealth{Up: h.up, RTTms: float64(h.rtt.Microseconds()) / 1000}
			if h.probe6 {
				up6 := h.up6
				eh.Up6, eh.RTT6ms = &up6, float64(h.rtt6.Microseconds())/1000
			}
			if h.dns[0].on {
				up := h.dns[0].up
				eh.DNSUp = &up
			}
			if h.dns[1].on {
				up := h.dns[1].up
				eh.DNS6Up = &up
			}
			st.Health[x.ID] = eh
		}
	}
	st.Routes = map[string]RouteView{}
	for _, x := range p.Exits {
		rv := RouteView{Actual: "direct"}
		if t := e.effExit(p, x.ID); t != nil {
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
		st.Routes[x.ID] = rv
	}
	b, _ := json.MarshalIndent(st, "", "  ")
	os.MkdirAll("/var/run/smartroute", 0o755)
	return os.WriteFile(StateFile, b, 0o644)
}
