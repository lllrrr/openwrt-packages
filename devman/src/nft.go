package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

func nftInit() {
	exec.Command("nft", "add", "table", "ip", "devman").Run()
	exec.Command("nft", "add", "set", "ip", "devman", "blocked_ip", "{", "type", "ipv4_addr", ";", "}").Run()
	// LAN subnet set for allowing local traffic
	exec.Command("nft", "add", "set", "ip", "devman", "lan_subnet", "{", "type", "ipv4_addr", ";", "flags", "interval", ";", "}").Run()
	// Raw PREROUTING drop — fires before passwall TPROXY, only blocks WAN-bound traffic
	exec.Command("nft", "add", "chain", "ip", "devman", "raw_block", "{", "type", "filter", "hook", "prerouting", "priority", "raw", ";", "}").Run()
	exec.Command("nft", "add", "rule", "ip", "devman", "raw_block", "iifname", lanIface, "ip", "saddr", "@blocked_ip", "ip", "daddr", "!=", "@lan_subnet", "drop").Run()
	// Forward chain for non-proxied traffic
	exec.Command("nft", "add", "chain", "ip", "devman", "forward", "{", "type", "filter", "hook", "forward", "priority", "filter", "-", "1", ";", "}").Run()
	exec.Command("nft", "add", "rule", "ip", "devman", "forward", "iifname", lanIface, "ip", "saddr", "@blocked_ip", "ip", "daddr", "!=", "@lan_subnet", "drop").Run()
	// Limit marks
	exec.Command("nft", "add", "set", "ip", "devman", "ul_mark", "{", "type", "ipv4_addr", ";", "}").Run()
	exec.Command("nft", "add", "set", "ip", "devman", "dl_mark", "{", "type", "ipv4_addr", ";", "}").Run()
	exec.Command("nft", "add", "rule", "ip", "devman", "forward", "ip", "saddr", "@ul_mark", "meta", "mark", "set", "0x80000000").Run()
	exec.Command("nft", "add", "rule", "ip", "devman", "forward", "ip", "daddr", "@dl_mark", "meta", "mark", "set", "0x40000000").Run()
	exec.Command("nft", "add", "chain", "ip", "devman", "post", "{", "type", "filter", "hook", "postrouting", "priority", "filter", "-", "2", ";", "}").Run()
	exec.Command("nft", "add", "rule", "ip", "devman", "post", "ip", "saddr", "@ul_mark", "meta", "mark", "set", "0x80000000").Run()
	exec.Command("nft", "add", "rule", "ip", "devman", "post", "ip", "daddr", "@dl_mark", "meta", "mark", "set", "0x40000000").Run()
}

func nftBlock(ip string)   { exec.Command("nft", "add", "element", "ip", "devman", "blocked_ip", "{", ip, "}").Run() }
func nftUnblock(ip string) { exec.Command("nft", "delete", "element", "ip", "devman", "blocked_ip", "{", ip, "}").Run() }

func restoreRateLimits() {
	// Restore from DB → nft/tc
	var devs []Device
	db.Where("ipv4 != '' AND (rate_limit > 0 OR rate_limit_dn > 0)").Find(&devs)
	for _, d := range devs {
		nftSetLimit(d.IPv4, d.RateLimit, d.RateLimitDn)
	}
	// Reverse: restore from nft/tc → DB (survives DB rebuild)
	restoreLimitsFromNft()
}

func restoreLimitsFromNft() {
	// Scan ul_mark and dl_mark sets to find IPs with active limit rules
	out, err := exec.Command("nft", "list", "set", "ip", "devman", "ul_mark").Output()
	if err != nil {
		return
	}
	for _, ip := range parseNftElements(string(out)) {
		var dev Device
		if db.Where("ipv4 = ? AND rate_limit = 0", ip).First(&dev).Error == nil {
			// Read actual rate from tc
			prio := int(hashIp(ip))
			rate := readTcRate("ifb0", prio)
			if rate > 0 {
				db.Model(&dev).Update("rate_limit", rate)
			}
		}
	}
	out, err = exec.Command("nft", "list", "set", "ip", "devman", "dl_mark").Output()
	if err != nil {
		return
	}
	for _, ip := range parseNftElements(string(out)) {
		var dev Device
		if db.Where("ipv4 = ? AND rate_limit_dn = 0", ip).First(&dev).Error == nil {
			prio := int(hashIp(ip))
			rate := readTcRate(lanIface, prio)
			if rate > 0 {
				db.Model(&dev).Update("rate_limit_dn", rate)
			}
		}
	}
}

func parseNftElements(raw string) []string {
	start := strings.Index(raw, "elements = {")
	if start < 0 {
		return nil
	}
	end := strings.Index(raw[start:], "}")
	if end < 0 {
		return nil
	}
	var ips []string
	for _, ip := range strings.Split(raw[start+13:start+end], ",") {
		ip = strings.TrimSpace(ip)
		if ip != "" {
			ips = append(ips, ip)
		}
	}
	return ips
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
	exec.Command("nft", "delete", "table", "ip", "devman").Run()
}

func nftSetLimit(ip string, ulBps, dlBps int) {
	limitMu.Lock()
	defer limitMu.Unlock()
	tcLazyInit()

	exec.Command("nft", "delete", "element", "ip", "devman", "ul_mark", "{", ip, "}").Run()
	if ulBps > 0 {
		exec.Command("nft", "add", "element", "ip", "devman", "ul_mark", "{", ip, "}").Run()
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

	exec.Command("nft", "delete", "element", "ip", "devman", "dl_mark", "{", ip, "}").Run()
	if dlBps > 0 {
		exec.Command("nft", "add", "element", "ip", "devman", "dl_mark", "{", ip, "}").Run()
	}
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
