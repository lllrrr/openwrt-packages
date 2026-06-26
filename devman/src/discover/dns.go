package discover

import (
	"net"
	"strings"
	"time"

	"devman/models"
)

func ResolveHostnamesLoop() {
	for {
		var ips []string
		DB.Model(&models.Device{}).Where("hostname = '' AND ipv4 != ''").Distinct().Pluck("ipv4", &ips)
		for _, ip := range ips {
			names, err := net.LookupAddr(ip)
			if err != nil || len(names) == 0 {
				continue
			}
			hn := strings.TrimSuffix(names[0], ".")
			if len(hn) > 0 && hn != "localhost" {
				UpsertDeviceNoSeen(ip, "", hn, "")
			}
		}
		time.Sleep(60 * time.Second)
	}
}
