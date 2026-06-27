package main

import (
	"fmt"
	"log"
	"net"
	"os/exec"
	"strings"
)

var blockedSetElems []string

func nftInit() {
	cleanup := exec.Command("nft", "delete", "table", "ip", "devman")
	cleanup.Run()

	cmds := []string{
		"nft add table ip devman",
		"nft add set ip devman blocked_ip { type ipv4_addr; }",
		"nft add set ip devman lan_subnet { type ipv4_addr; flags interval; }",
		"nft add set ip devman ul_mark { type ipv4_addr; }",
		"nft add set ip devman dl_mark { type ipv4_addr; }",
		"nft add chain ip devman raw_block { type filter hook prerouting priority raw; }",
		fmt.Sprintf("nft add rule ip devman raw_block iifname %s ip saddr @blocked_ip ip daddr != @lan_subnet drop", lanIface),
		"nft add chain ip devman forward { type filter hook forward priority -1; }",
		fmt.Sprintf("nft add rule ip devman forward iifname %s ip saddr @blocked_ip ip daddr != @lan_subnet drop", lanIface),
		"nft add rule ip devman forward ip saddr @ul_mark meta mark set 0x80000000",
		"nft add rule ip devman forward ip daddr @dl_mark meta mark set 0x40000000",
		"nft add chain ip devman post { type filter hook postrouting priority -2; }",
		"nft add rule ip devman post ip saddr @ul_mark meta mark set 0x80000000",
		"nft add rule ip devman post ip daddr @dl_mark meta mark set 0x40000000",
	}
	for _, cmd := range cmds {
		parts := strings.Split(cmd, " ")
		if err := exec.Command(parts[0], parts[1:]...).Run(); err != nil {
			log.Printf("NFT: %s failed: %v", cmd, err)
		}
	}
	log.Printf("NFT: table initialized")
}

func nftSetSubnet(subnet *net.IPNet) {
	if subnet == nil {
		return
	}
	ones, _ := subnet.Mask.Size()
	cidr := fmt.Sprintf("%s/%d", subnet.IP.String(), ones)
	exec.Command("nft", "add", "element", "ip", "devman", "lan_subnet", fmt.Sprintf("{ %s }", cidr)).Run()
	log.Printf("NFT: lan_subnet set to %s", cidr)
}

func nftBlock(ip string) {
	if err := exec.Command("nft", "add", "element", "ip", "devman", "blocked_ip", fmt.Sprintf("{ %s }", ip)).Run(); err != nil {
		log.Printf("NFT: block %s failed: %v", ip, err)
	}
}

func nftUnblock(ip string) {
	if err := exec.Command("nft", "delete", "element", "ip", "devman", "blocked_ip", fmt.Sprintf("{ %s }", ip)).Run(); err != nil {
		log.Printf("NFT: unblock %s failed: %v", ip, err)
	}
}

func nftListBlocked() []string {
	out, err := exec.Command("nft", "list", "set", "ip", "devman", "blocked_ip").Output()
	if err != nil {
		return nil
	}
	raw := string(out)
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

func nftSetLimit(ip string, ulBps, dlBps int) {
	limitMu.Lock()
	defer limitMu.Unlock()
	tcLazyInit()

	prio := hashIp(ip)
	if dlBps > 0 {
		nftSetMark("dl_mark", dlBps, ip, prio, lanIface)
	} else {
		nftClearMark("dl_mark", ip, lanIface)
	}
	if ulBps > 0 {
		nftSetMark("ul_mark", ulBps, ip, prio, "ifb0")
	} else {
		nftClearMark("ul_mark", ip, "ifb0")
	}
}

func nftSetMark(set string, rate int, ip string, prio uint32, dev string) {
	bps := rate
	kbps := (bps + 500) / 1000
	if kbps < 1 {
		kbps = 1
	}
	burst := kbps * 2
	if burst > 15000 {
		burst = 15000
	}
	rateStr := fmt.Sprintf("%dkbit", kbps)
	burstStr := fmt.Sprintf("%d", burst)

	exec.Command("nft", "add", "element", "ip", "devman", set, fmt.Sprintf("{ %s }", ip)).Run()

	exec.Command("tc", "class", "add", "dev", dev, "parent", "1:1",
		"classid", fmt.Sprintf("1:%d", prio),
		"htb", "rate", rateStr, "ceil", rateStr, "burst", burstStr, "cburst", burstStr).Run()

	exec.Command("tc", "filter", "add", "dev", dev, "protocol", "all",
		"parent", "1:0", "prio", fmt.Sprintf("%d", prio%0x10000),
		"handle", fmt.Sprintf("%d", prio>>16), fmt.Sprintf("0x%x", prio),
		"fw", "flowid", fmt.Sprintf("1:%d", prio)).Run()
}

func nftClearMark(set string, ip string, dev string) {
	prio := hashIp(ip)
	exec.Command("nft", "delete", "element", "ip", "devman", set, fmt.Sprintf("{ %s }", ip)).Run()
	exec.Command("tc", "class", "del", "dev", dev, "classid", fmt.Sprintf("1:%d", prio)).Run()
	exec.Command("tc", "filter", "del", "dev", dev, "prio", fmt.Sprintf("%d", prio%0x10000)).Run()
}

func restoreRateLimits() {
	var devs []Device
	db.Where("rate_limit > 0 OR rate_limit_dn > 0").Find(&devs)
	for _, d := range devs {
		if d.IPv4 != "" {
			nftSetLimit(d.IPv4, d.RateLimit, d.RateLimitDn)
		}
	}
}

func restoreLimitsFromNft() {
	// Restore limits from nftables/tc into DB
	upIps := parseNftElements("ul_mark")
	dnIps := parseNftElements("dl_mark")
	for _, ip := range upIps {
		prio := hashIp(ip)
		rate := readTcRate("ifb0", int(prio))
		if rate > 0 {
			db.Model(&Device{}).Where("ipv4 = ?", ip).Update("rate_limit", rate)
		}
	}
	for _, ip := range dnIps {
		prio := hashIp(ip)
		rate := readTcRate(lanIface, int(prio))
		if rate > 0 {
			db.Model(&Device{}).Where("ipv4 = ?", ip).Update("rate_limit_dn", rate)
		}
	}
}

func parseNftElements(setName string) []string {
	out, err := exec.Command("nft", "list", "set", "ip", "devman", setName).Output()
	if err != nil {
		return nil
	}
	return parseNftElementsOutput(string(out))
}

func parseNftElementsOutput(raw string) []string {
	start := strings.Index(raw, "elements = {")
	if start < 0 {
		return nil
	}
	end := strings.Index(raw[start:], "}")
	if end < 0 {
		return nil
	}
	var elems []string
	for _, e := range strings.Split(raw[start+13:start+end], ",") {
		e = strings.TrimSpace(e)
		if e != "" {
			elems = append(elems, e)
		}
	}
	return elems
}

func readTcRate(dev string, prio int) int {
	out, err := exec.Command("tc", "class", "show", "dev", dev).Output()
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(line, fmt.Sprintf("1:%d", prio)) {
			continue
		}
		// Parse rate from tc output: ... rate XXXMbit ...
		for _, part := range strings.Fields(line) {
			if strings.HasSuffix(part, "Mbit") {
				if v, _ := atoi(part[:len(part)-4]); v > 0 {
					return v * 1000000
				}
			}
			if strings.HasSuffix(part, "Kbit") {
				if v, _ := atoi(part[:len(part)-4]); v > 0 {
					return v * 1000
				}
			}
		}
	}
	return 0
}

func nftCleanup() {
	exec.Command("nft", "delete", "table", "ip", "devman").Run()
}

func hashIp(ip string) uint32 {
	parts := strings.Split(ip, ".")
	if len(parts) < 4 {
		return 0
	}
	a, _ := atoi(parts[2])
	b, _ := atoi(parts[3])
	return uint32(a&0xff)<<8 | uint32(b&0xff)
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
