package main

import (
	"fmt"
	"log"
	"net"
	"os/exec"
	"strings"
)

var lanSubnet *net.IPNet

func detectLAN() {
	iface := lanIface
	var subnet string

	// Try UCI first
	out, err := exec.Command("uci", "get", "network.lan.ipaddr").Output()
	if err == nil {
		lanIP := strings.TrimSpace(string(out))
		maskOut, _ := exec.Command("uci", "get", "network.lan.netmask").Output()
		mask := strings.TrimSpace(string(maskOut))
		if mask == "" {
			mask = "255.255.255.0"
		}
		if lanIP != "" {
			ones, _ := net.IPMask(net.ParseIP(mask).To4()).Size()
			subnet = fmt.Sprintf("%s/%d", lanIP, ones)
		}
	}

	// Fallback: ip addr
	if subnet == "" {
		out, err = exec.Command("ip", "-4", "addr", "show", "dev", iface).Output()
		if err != nil {
			log.Printf("LAN: cannot detect, using 192.168.0.0/16")
			subnet = "192.168.0.0/16"
		} else {
			for _, line := range strings.Split(string(out), "\n") {
				if strings.Contains(line, "inet ") {
					fields := strings.Fields(line)
					if len(fields) >= 2 {
						subnet = fields[1]
						break
					}
				}
			}
		}
	}

	_, lanSubnet, _ = net.ParseCIDR(subnet)
	log.Printf("LAN: %s", lanSubnet)
}

func isLAN(ip string) bool {
	if lanSubnet == nil {
		return strings.HasPrefix(ip, "192.168.")
	}
	parsed := net.ParseIP(ip)
	return parsed != nil && lanSubnet.Contains(parsed)
}
