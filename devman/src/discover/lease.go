package discover

import (
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"devman/models"
)

func DnsmasqLeaseLoop() {
	leaseFile := "/etc/dhcp.leases"
	if out, err := exec.Command("uci", "get", "dhcp.@dnsmasq[0].leasefile").Output(); err == nil {
		if p := strings.TrimSpace(string(out)); p != "" {
			leaseFile = p
		}
	}
	log.Printf("LEASE: using lease file %s", leaseFile)
	for {
		data, err := os.ReadFile(leaseFile)
		if err != nil {
			time.Sleep(30 * time.Second)
			continue
		}
		now := time.Now().Unix()
		for _, line := range strings.Split(string(data), "\n") {
			fields := strings.Fields(line)
			if len(fields) < 4 {
				continue
			}
			epoch, _ := strconv.ParseInt(fields[0], 10, 64)
			mac, ip, hostname := fields[1], fields[2], fields[3]
			if hostname == "*" {
				hostname = ""
			}
			if hostname == "" {
				var existing models.Device
				if DB.Where("ipv4 = ? AND hostname != ''", ip).First(&existing).Error == nil {
					continue
				}
				if mac == "" {
					continue
				}
			}
			if now-epoch > 86400 {
				continue
			}
			UpsertDeviceNoSeen(ip, mac, hostname, "")
		}
		time.Sleep(30 * time.Second)
	}
}
