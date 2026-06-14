package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ====== discovery ======

var (
	arpStates = map[string]string{} // IP → ARP state
	arpMu     sync.RWMutex
)

func neightLoop() {
	log.Printf("NEIGH: started")
	exec.Command("sysctl", "-w", "net.ipv4.neigh.default.base_reachable_time_ms=15000").Run()
	exec.Command("sysctl", "-w", "net.ipv4.neigh.default.gc_stale_time=30").Run()
	for {
		out, _ := exec.Command("/sbin/ip", "neigh", "show").Output()
		arpMu.Lock()
		arpStates = map[string]string{}
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) < 4 {
				continue
			}
			ip := fields[0]
			if strings.HasPrefix(ip, "169.254") || strings.HasPrefix(ip, "127.") {
				continue
			}
			// Record FAILED state even if MAC is missing
			if len(fields) == 4 && fields[3] == "FAILED" {
				arpStates[ip] = "FAILED"
				continue
			}
			if len(fields) < 6 {
				continue
			}
			mac, state := fields[4], fields[5]
			if mac == "00:00:00:00:00:00" || mac == "incomplete" {
				continue
			}
			arpStates[ip] = state
			if state != "FAILED" {
				upsertDeviceNoSeen(ip, mac, "", "")
			}
		}
		arpMu.Unlock()
		time.Sleep(15 * time.Second)
	}
}

func conntrackLoop() {
	log.Printf("CONNTRACK: started")
	for {
		out, _ := exec.Command("/usr/sbin/conntrack", "-L", "-o", "id").Output()
		for _, line := range strings.Split(string(out), "\n") {
			srcIdx := strings.Index(line, "src=")
			if srcIdx < 0 {
				continue
			}
			src := strings.SplitN(line[srcIdx+4:], " ", 2)[0]
			dstIdx := strings.Index(line, "dst=")
			if dstIdx < 0 {
				continue
			}
			dst := strings.SplitN(line[dstIdx+4:], " ", 2)[0]
			if !isLAN(src) && isLAN(dst) {
				if dst != "" && !strings.HasPrefix(dst, "127.") {
					upsertDevice(dst, "", "", "")
				}
			}
		}
		time.Sleep(15 * time.Second)
	}
}

func dnsmasqLeaseLoop() {
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
				// Don't skip: IP+MAC still useful. But don't overwrite existing good hostname
				var existing Device
				if db.Where("ipv4 = ? AND hostname != ''", ip).First(&existing).Error == nil {
					continue
				}
				if mac == "" {
					continue
				}
			}
			if now-epoch > 86400 {
				continue
			}	
			upsertDeviceNoSeen(ip, mac, hostname, "")
		}
		time.Sleep(30 * time.Second)
	}
}

func resolveHostnamesLoop() {
	for {
		var ips []string
		db.Model(&Device{}).Where("hostname = '' AND ipv4 != ''").Distinct().Pluck("ipv4", &ips)
		for _, ip := range ips {
			names, err := net.LookupAddr(ip)
			if err != nil || len(names) == 0 {
				continue
			}
			hn := strings.TrimSuffix(names[0], ".")
			if len(hn) > 0 && hn != "localhost" {
				upsertDeviceNoSeen(ip, "", hn, "")
			}
		}
		time.Sleep(60 * time.Second)
	}
}

// ====== DB ops ======

// upsertDevice finds or creates a device by MAC → hostname → IP, then updates it.
// updateLastSeen controls whether last_seen is bumped (ARP/conntrack=true, lease=false).
func upsertDevice(ip, mac, hostname, vendorClass string) { upsertDeviceEx(ip, mac, hostname, vendorClass, true) }
func upsertDeviceNoSeen(ip, mac, hostname, vendorClass string) { upsertDeviceEx(ip, mac, hostname, vendorClass, false) }

func upsertDeviceEx(ip, mac, hostname, vendorClass string, updateLastSeen bool) {
	// Skip IPv6
	if strings.Contains(ip, ":") {
		return
	}
	if ip == "" && hostname == "" && mac == "" {
		return
	}
	ip = strings.TrimSpace(ip)
	mac = strings.ToLower(strings.TrimSpace(mac))
	hostname = strings.TrimSpace(hostname)

	now := time.Now().Unix()
	devType := detectType(hostname, vendorClass)
	if devType == "Unknown" && mac != "" {
		devType = detectTypeByMAC(mac)
	}

	var dev Device

	// Tier 1: MAC
	if mac != "" {
		if err := db.Where("mac = ?", mac).First(&dev).Error; err == nil {
			updateExisting(&dev, ip, mac, hostname, vendorClass, devType, now, updateLastSeen)
			return
		}
	}
	// Tier 2: hostname
	if hostname != "" {
		if err := db.Where("hostname = ?", hostname).First(&dev).Error; err == nil {
			updateExisting(&dev, ip, mac, hostname, vendorClass, devType, now, updateLastSeen)
			return
		}
	}
	// Tier 3: IP
	if ip != "" {
		if err := db.Where("ipv4 = ?", ip).First(&dev).Error; err == nil {
			updateExisting(&dev, ip, mac, hostname, vendorClass, devType, now, updateLastSeen)
			return
		}
	}

	// New device
	dev = Device{
		Hostname:    hostname,
		DeviceType:  devType,
		MAC:         mac,
		IPv4:        ip,
		VendorClass: vendorClass,
		LastSeen:    now,
	}
	db.Create(&dev)
	if mac != "" {
		db.Where(DeviceMAC{DeviceID: dev.ID, MAC: mac}).FirstOrCreate(&DeviceMAC{DeviceID: dev.ID, MAC: mac})
	}
}

func updateExisting(dev *Device, ip, mac, hostname, vendorClass, devType string, now int64, updateLastSeen bool) {
	updates := map[string]interface{}{}
	if updateLastSeen {
		updates["last_seen"] = now
	}
	// Only update IP if it looks valid (LAN IPv4)
	if ip != "" && isLAN(ip) && !strings.Contains(ip, ":") {
		updates["ipv4"] = ip
	}
	if hostname != "" && dev.Hostname == "" {
		updates["hostname"] = hostname
	}
	if devType != "" && devType != "Unknown" && (dev.DeviceType == "" || dev.DeviceType == "Unknown") {
		updates["device_type"] = devType
	}
	// Only update MAC if it looks like a valid MAC (6 hex pairs)
	if mac != "" && len(mac) == 17 && strings.Count(mac, ":") == 5 {
		updates["mac"] = mac
		db.Where(DeviceMAC{DeviceID: dev.ID, MAC: mac}).FirstOrCreate(&DeviceMAC{DeviceID: dev.ID, MAC: mac})
		if dt := detectTypeByMAC(mac); dt != "" && dt != "Unknown" && (dev.DeviceType == "" || dev.DeviceType == "Unknown") {
			updates["device_type"] = dt
		}
	}
	if vendorClass != "" {
		updates["vendor_class"] = vendorClass
	}

	db.Model(dev).Updates(updates)

	// Merge duplicate IP
	if dev.IPv4 != "" && ip != "" && dev.IPv4 != ip {
		var dup Device
		if err := db.Where("ipv4 = ? AND id != ?", ip, dev.ID).First(&dup).Error; err == nil {
			db.Exec("INSERT OR IGNORE INTO device_macs (device_id, mac) SELECT ?, mac FROM device_macs WHERE device_id = ?", dev.ID, dup.ID)
			db.Where("device_id = ?", dup.ID).Delete(&DeviceMAC{})
			if dev.Hostname == "" && dup.Hostname != "" {
				db.Model(dev).Update("hostname", dup.Hostname)
			}
			db.Delete(&dup)
		}
	}
}

func mergeDuplicateHostnames() {
	type row struct {
		Hostname string
		Cnt      int
	}
	var rows []row
	db.Model(&Device{}).Select("hostname, COUNT(*) cnt").
		Where("hostname != ''").Group("hostname").Having("cnt > 1").Find(&rows)
	for _, r := range rows {
		var ids []int64
		db.Model(&Device{}).Where("hostname = ?", r.Hostname).Order("last_seen DESC").Pluck("id", &ids)
		if len(ids) < 2 {
			continue
		}
		keeper := ids[0]
		for _, id := range ids[1:] {
			db.Exec("INSERT OR IGNORE INTO device_macs (device_id, mac) SELECT ?, mac FROM device_macs WHERE device_id = ?", keeper, id)
			db.Where("device_id = ?", id).Delete(&DeviceMAC{})
			db.Delete(&Device{}, id)
		}
	}
}

// ====== reconcile ======

func reconcileLoop() {
	for {
		time.Sleep(5 * time.Second)
		mergeDuplicateHostnames()

		var dbBlocked []string
		db.Model(&Device{}).Where("is_blocked = 1 AND ipv4 != ''").Pluck("ipv4", &dbBlocked)
		blockedSet := toSet(dbBlocked)

		nftBlocked := toSet(nftListBlocked())

		for ip := range blockedSet {
			if !nftBlocked[ip] {
				nftBlock(ip)
			}
		}
		for ip := range nftBlocked {
			if !blockedSet[ip] {
				nftUnblock(ip)
			}
		}
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

func toSet(list []string) map[string]bool {
	m := make(map[string]bool, len(list))
	for _, s := range list {
		m[s] = true
	}
	return m
}

// ====== HTTP handlers ======

func apiDevices(w http.ResponseWriter, r *http.Request) {
	var devs []Device
	db.Where("ipv4 != '' AND ipv4 IS NOT NULL AND ipv4 LIKE '%.%.%.%' AND ipv4 NOT LIKE '%:%'").Order("ipv4 ASC").Find(&devs)

	type DeviceWithSpeed struct {
		Device
		Online  string `json:"online"`
		NumMACs int64  `json:"num_macs"`
		SpeedIn  uint64 `json:"speed_in"`
		SpeedOut uint64 `json:"speed_out"`
	}

	result := make([]DeviceWithSpeed, 0, len(devs))
	for _, d := range devs {
		if d.DeviceType == "" {
			d.DeviceType = "Unknown"
		}

		si, so := getSpeed(d.IPv4)
		online := "gray"
		if si > 0 || so > 0 {
			online = "green"
		} else if d.LastSeen > time.Now().Unix()-60 {
			online = "green"
		} else if d.LastSeen > time.Now().Unix()-120 {
			online = "yellow"
		}

		var nmacs int64
		db.Model(&DeviceMAC{}).Where("device_id = ?", d.ID).Count(&nmacs)
		result = append(result, DeviceWithSpeed{
			Device:   d,
			Online:   online,
			NumMACs:  nmacs,
			SpeedIn:  si,
			SpeedOut: so,
		})
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func apiBlock(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID int64 `json:"device_id"`
		Block    bool  `json:"block"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	db.Model(&Device{}).Where("id = ?", req.DeviceID).Update("is_blocked", req.Block)
	w.Write([]byte(`{"ok":true}`))
}

func apiLimit(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID    int64  `json:"device_id"`
		RateLimit   int    `json:"rate_limit"`
		RateLimitDn int    `json:"rate_limit_down"`
		Alias       string `json:"alias"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	log.Printf("LIMIT: id=%d rate=%d ratedn=%d alias=%s", req.DeviceID, req.RateLimit, req.RateLimitDn, req.Alias)
	if req.Alias != "" {
		db.Model(&Device{}).Where("id = ?", req.DeviceID).Update("alias", req.Alias)
	}
	if req.RateLimit != -1 {
		db.Model(&Device{}).Where("id = ?", req.DeviceID).Update("rate_limit", req.RateLimit)
	}
	if req.RateLimitDn != -1 {
		db.Model(&Device{}).Where("id = ?", req.DeviceID).Update("rate_limit_dn", req.RateLimitDn)
	}
	// Apply to nft/tc
	var d Device
	if db.Where("id = ?", req.DeviceID).First(&d).Error == nil && d.IPv4 != "" {
		go nftSetLimit(d.IPv4, d.RateLimit, d.RateLimitDn)
	}
	w.Write([]byte(`{"ok":true}`))
}
