package main

import (
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"

	"devman/models"
	"github.com/google/nftables"
	"github.com/google/nftables/binaryutil"
	"github.com/google/nftables/expr"
)

var (
	nftTable     *nftables.Table
	blockedSet   *nftables.Set
	lanSubnetSet *nftables.Set
	ulMarkSet    *nftables.Set
	dlMarkSet    *nftables.Set
)

func nftInit() {
	c := &nftables.Conn{}

	t := &nftables.Table{Family: nftables.TableFamilyIPv4, Name: "devman"}
	c.AddTable(t)

	blockedSet = &nftables.Set{
		Table:   t,
		Name:    "blocked_ip",
		KeyType: nftables.TypeIPAddr,
	}
	c.AddSet(blockedSet, nil)

	lanSubnetSet = &nftables.Set{
		Table:    t,
		Name:     "lan_subnet",
		KeyType:  nftables.TypeIPAddr,
		Interval: true,
	}
	c.AddSet(lanSubnetSet, nil)

	ulMarkSet = &nftables.Set{
		Table:   t,
		Name:    "ul_mark",
		KeyType: nftables.TypeIPAddr,
	}
	c.AddSet(ulMarkSet, nil)

	dlMarkSet = &nftables.Set{
		Table:   t,
		Name:    "dl_mark",
		KeyType: nftables.TypeIPAddr,
	}
	c.AddSet(dlMarkSet, nil)

	rawBlock := c.AddChain(&nftables.Chain{
		Table:    t,
		Name:     "raw_block",
		Type:     nftables.ChainTypeFilter,
		Hooknum:  nftables.ChainHookPrerouting,
		Priority: nftables.ChainPriorityRaw,
	})

	c.AddRule(&nftables.Rule{
		Table: t,
		Chain: rawBlock,
		Exprs: []expr.Any{
			&expr.Meta{Key: expr.MetaKeyIIFNAME, Register: 1},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte(lanIface + "\x00")},
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 12, Len: 4},
			&expr.Lookup{SourceRegister: 1, SetName: "blocked_ip", SetID: blockedSet.ID},
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 16, Len: 4},
			&expr.Lookup{SourceRegister: 1, SetName: "lan_subnet", SetID: lanSubnetSet.ID, Invert: true},
			&expr.Verdict{Kind: expr.VerdictDrop},
		},
	})

	fwdPrio := nftables.ChainPriority(-1)
	fwd := c.AddChain(&nftables.Chain{
		Table:    t,
		Name:     "forward",
		Type:     nftables.ChainTypeFilter,
		Hooknum:  nftables.ChainHookForward,
		Priority: &fwdPrio,
	})

	c.AddRule(&nftables.Rule{
		Table: t,
		Chain: fwd,
		Exprs: []expr.Any{
			&expr.Meta{Key: expr.MetaKeyIIFNAME, Register: 1},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte(lanIface + "\x00")},
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 12, Len: 4},
			&expr.Lookup{SourceRegister: 1, SetName: "blocked_ip", SetID: blockedSet.ID},
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 16, Len: 4},
			&expr.Lookup{SourceRegister: 1, SetName: "lan_subnet", SetID: lanSubnetSet.ID, Invert: true},
			&expr.Verdict{Kind: expr.VerdictDrop},
		},
	})

	c.AddRule(&nftables.Rule{
		Table: t,
		Chain: fwd,
		Exprs: []expr.Any{
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 12, Len: 4},
			&expr.Lookup{SourceRegister: 1, SetName: "ul_mark", SetID: ulMarkSet.ID},
			&expr.Immediate{Register: 1, Data: binaryutil.BigEndian.PutUint32(0x80000000)},
			&expr.Meta{Key: expr.MetaKeyMARK, SourceRegister: true, Register: 1},
		},
	})

	c.AddRule(&nftables.Rule{
		Table: t,
		Chain: fwd,
		Exprs: []expr.Any{
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 16, Len: 4},
			&expr.Lookup{SourceRegister: 1, SetName: "dl_mark", SetID: dlMarkSet.ID},
			&expr.Immediate{Register: 1, Data: binaryutil.BigEndian.PutUint32(0x40000000)},
			&expr.Meta{Key: expr.MetaKeyMARK, SourceRegister: true, Register: 1},
		},
	})

	postPrio := nftables.ChainPriority(-2)
	post := c.AddChain(&nftables.Chain{
		Table:    t,
		Name:     "post",
		Type:     nftables.ChainTypeFilter,
		Hooknum:  nftables.ChainHookPostrouting,
		Priority: &postPrio,
	})

	c.AddRule(&nftables.Rule{
		Table: t,
		Chain: post,
		Exprs: []expr.Any{
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 12, Len: 4},
			&expr.Lookup{SourceRegister: 1, SetName: "ul_mark", SetID: ulMarkSet.ID},
			&expr.Immediate{Register: 1, Data: binaryutil.BigEndian.PutUint32(0x80000000)},
			&expr.Meta{Key: expr.MetaKeyMARK, SourceRegister: true, Register: 1},
		},
	})

	c.AddRule(&nftables.Rule{
		Table: t,
		Chain: post,
		Exprs: []expr.Any{
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 16, Len: 4},
			&expr.Lookup{SourceRegister: 1, SetName: "dl_mark", SetID: dlMarkSet.ID},
			&expr.Immediate{Register: 1, Data: binaryutil.BigEndian.PutUint32(0x40000000)},
			&expr.Meta{Key: expr.MetaKeyMARK, SourceRegister: true, Register: 1},
		},
	})

	if lanSubnet != nil {
		start := lanSubnet.IP.To4()
		end := make(net.IP, 4)
		for i := range end {
			end[i] = start[i] | ^lanSubnet.Mask[i]
		}
		c.SetAddElements(lanSubnetSet, []nftables.SetElement{{
			Key:    start,
			KeyEnd: end,
		}})
	}

	nftTable = t
	c.Flush()
}

func nftBlock(ip string) {
	ipBytes := net.ParseIP(ip).To4()
	if ipBytes == nil {
		return
	}
	c := &nftables.Conn{}
	c.SetAddElements(blockedSet, []nftables.SetElement{{Key: ipBytes}})
	c.Flush()
}

func nftUnblock(ip string) {
	ipBytes := net.ParseIP(ip).To4()
	if ipBytes == nil {
		return
	}
	c := &nftables.Conn{}
	c.SetDeleteElements(blockedSet, []nftables.SetElement{{Key: ipBytes}})
	c.Flush()
}

func nftListBlocked() []string {
	c := &nftables.Conn{}
	elems, err := c.GetSetElements(blockedSet)
	if err != nil {
		return nil
	}
	var ips []string
	for _, elem := range elems {
		ips = append(ips, net.IP(elem.Key).String())
	}
	return ips
}

func restoreRateLimits() {
	var devs []models.Device
	db.Where("ipv4 != '' AND (rate_limit > 0 OR rate_limit_dn > 0)").Find(&devs)
	for _, d := range devs {
		nftSetLimit(d.IPv4, d.RateLimit, d.RateLimitDn)
	}
	restoreLimitsFromNft()
}

func restoreLimitsFromNft() {
	c := &nftables.Conn{}

	ulElems, err := c.GetSetElements(ulMarkSet)
	if err == nil {
		for _, elem := range ulElems {
			ip := net.IP(elem.Key).String()
			var dev models.Device
			if db.Where("ipv4 = ? AND rate_limit = 0", ip).First(&dev).Error == nil {
				prio := int(hashIp(ip))
				rate := readTcRate("ifb0", prio)
				if rate > 0 {
					db.Model(&dev).Update("rate_limit", rate)
				}
			}
		}
	}

	dlElems, err := c.GetSetElements(dlMarkSet)
	if err == nil {
		for _, elem := range dlElems {
			ip := net.IP(elem.Key).String()
			var dev models.Device
			if db.Where("ipv4 = ? AND rate_limit_dn = 0", ip).First(&dev).Error == nil {
				prio := int(hashIp(ip))
				rate := readTcRate(lanIface, prio)
				if rate > 0 {
					db.Model(&dev).Update("rate_limit_dn", rate)
				}
			}
		}
	}
}

func readTcRate(dev string, prio int) int {
	out, err := exec.Command("tc", "class", "show", "dev", dev, "classid", fmt.Sprintf("1:%d", prio)).Output()
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(out))
	for i, f := range fields {
		if f == "rate" && i+1 < len(fields) {
			val := fields[i+1]
			s := strings.TrimSuffix(strings.TrimSuffix(val, "Mbit"), "Kbit")
			v, _ := strconv.Atoi(s)
			if strings.Contains(val, "Mbit") {
				return v * 1000000
			}
			return v * 1000
		}
	}
	return 0
}

func nftCleanup() {
	if nftTable == nil {
		return
	}
	c := &nftables.Conn{}
	c.DelTable(nftTable)
	c.Flush()
}

func nftSetLimit(ip string, ulBps, dlBps int) {
	limitMu.Lock()
	defer limitMu.Unlock()
	tcLazyInit()

	ipBytes := net.ParseIP(ip).To4()
	if ipBytes == nil {
		return
	}

	c := &nftables.Conn{}
	c.SetDeleteElements(ulMarkSet, []nftables.SetElement{{Key: ipBytes}})
	if ulBps > 0 {
		c.SetAddElements(ulMarkSet, []nftables.SetElement{{Key: ipBytes}})
	}

	prio := int(hashIp(ip))
	ulKbps := ulBps / 1000
	if ulKbps < 1 {
		ulKbps = 1
	}
	if ulBps > 0 {
		exec.Command("tc", "class", "add", "dev", "ifb0", "parent", "1:1", "classid", fmt.Sprintf("1:%d", prio),
			"htb", "rate", fmt.Sprintf("%d", ulKbps)+"kbit", "ceil", fmt.Sprintf("%d", ulKbps)+"kbit", "burst", "15k", "cburst", "15k").Run()
		exec.Command("tc", "class", "change", "dev", "ifb0", "parent", "1:1", "classid", fmt.Sprintf("1:%d", prio),
			"htb", "rate", fmt.Sprintf("%d", ulKbps)+"kbit", "ceil", fmt.Sprintf("%d", ulKbps)+"kbit", "burst", "15k", "cburst", "15k").Run()
		exec.Command("tc", "filter", "add", "dev", "ifb0", "parent", "1:0", "prio", fmt.Sprintf("%d", prio),
			"protocol", "ip", "u32", "match", "ip", "src", ip, "flowid", fmt.Sprintf("1:%d", prio)).Run()
		exec.Command("tc", "filter", "replace", "dev", "ifb0", "parent", "1:0", "prio", fmt.Sprintf("%d", prio),
			"protocol", "ip", "u32", "match", "ip", "src", ip, "flowid", fmt.Sprintf("1:%d", prio)).Run()
	} else {
		exec.Command("tc", "filter", "del", "dev", "ifb0", "parent", "1:0", "prio", fmt.Sprintf("%d", prio),
			"protocol", "ip", "u32", "match", "ip", "src", ip).Run()
		exec.Command("tc", "class", "del", "dev", "ifb0", "parent", "1:1", "classid", fmt.Sprintf("1:%d", prio)).Run()
	}

	c.SetDeleteElements(dlMarkSet, []nftables.SetElement{{Key: ipBytes}})
	if dlBps > 0 {
		c.SetAddElements(dlMarkSet, []nftables.SetElement{{Key: ipBytes}})
	}
	c.Flush()

	dlKbps := dlBps / 1000
	if dlKbps < 1 {
		dlKbps = 1
	}
	if dlBps > 0 {
		exec.Command("tc", "class", "add", "dev", lanIface, "parent", "1:1", "classid", fmt.Sprintf("1:%d", prio),
			"htb", "rate", fmt.Sprintf("%d", dlKbps)+"kbit", "ceil", fmt.Sprintf("%d", dlKbps)+"kbit", "burst", "15k", "cburst", "15k").Run()
		exec.Command("tc", "class", "change", "dev", lanIface, "parent", "1:1", "classid", fmt.Sprintf("1:%d", prio),
			"htb", "rate", fmt.Sprintf("%d", dlKbps)+"kbit", "ceil", fmt.Sprintf("%d", dlKbps)+"kbit", "burst", "15k", "cburst", "15k").Run()
		exec.Command("tc", "filter", "add", "dev", lanIface, "parent", "1:0", "prio", fmt.Sprintf("%d", prio),
			"protocol", "ip", "u32", "match", "ip", "dst", ip, "flowid", fmt.Sprintf("1:%d", prio)).Run()
		exec.Command("tc", "filter", "replace", "dev", lanIface, "parent", "1:0", "prio", fmt.Sprintf("%d", prio),
			"protocol", "ip", "u32", "match", "ip", "dst", ip, "flowid", fmt.Sprintf("1:%d", prio)).Run()
	} else {
		exec.Command("tc", "filter", "del", "dev", lanIface, "parent", "1:0", "prio", fmt.Sprintf("%d", prio),
			"protocol", "ip", "u32", "match", "ip", "dst", ip).Run()
		exec.Command("tc", "class", "del", "dev", lanIface, "parent", "1:1", "classid", fmt.Sprintf("1:%d", prio)).Run()
	}
}

func hashIp(ip string) uint32 {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return 1
	}
	a, _ := atoi(parts[2])
	b, _ := atoi(parts[3])
	return uint32(a)*256 + uint32(b)
}

func atoi(s string) (int, error) {
	var n int
	for _, c := range s {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
	}
	return n, nil
}
