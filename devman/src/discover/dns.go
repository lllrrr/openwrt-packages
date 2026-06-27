package discover

import (
	"context"
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
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			resolver := net.Resolver{}
			names, err := resolver.LookupAddr(ctx, ip)
			cancel()
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
