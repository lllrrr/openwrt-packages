package main

import (
	"log"
	"strings"
	"time"

	"devman/models"
)

// ====== DB ops ======

// upsertDevice finds or creates a device by MAC → hostname → IP, then updates it.
// opt55Hash is the DHCP Option 55 fingerprint hash for deduplication.
// updateLastSeen controls whether last_seen is bumped (ARP/conntrack=true, lease=false).
func upsertDevice(ip, mac, hostname, vendorClass, opt55Hash string) {
	upsertDeviceEx(ip, mac, hostname, vendorClass, opt55Hash, true)
}
func upsertDeviceNoSeen(ip, mac, hostname, vendorClass string) {
	upsertDeviceEx(ip, mac, hostname, vendorClass, "", false)
}

func upsertDeviceEx(ip, mac, hostname, vendorClass, opt55Hash string, updateLastSeen bool) {
	// Global lock to prevent race conditions
	mu.Lock()
	defer mu.Unlock()

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

	var dev models.Device
	var matchBy string

	// Tier 0: Opt55Hash
	if opt55Hash != "" {
		if err := db.Where("opt55_hash = ?", opt55Hash).First(&dev).Error; err == nil {
			matchBy = "opt55"
			updateExisting(&dev, ip, mac, hostname, vendorClass, opt55Hash, devType, now, updateLastSeen, matchBy)
			return
		}
	}
	// Tier 1: MAC
	if mac != "" {
		if err := db.Where("mac = ?", mac).First(&dev).Error; err == nil {
			matchBy = "mac"
			updateExisting(&dev, ip, mac, hostname, vendorClass, opt55Hash, devType, now, updateLastSeen, matchBy)
			return
		}
		// Tier 1b: MAC in device_macs
		var dm models.DeviceMAC
		if err := db.Where("mac = ?", mac).First(&dm).Error; err == nil {
			if err := db.Where("id = ?", dm.DeviceID).First(&dev).Error; err == nil {
				matchBy = "mac"
				updateExisting(&dev, ip, mac, hostname, vendorClass, opt55Hash, devType, now, updateLastSeen, matchBy)
				return
			}
		}
	}
	// Tier 2: hostname
	if hostname != "" {
		if err := db.Where("hostname = ?", hostname).First(&dev).Error; err == nil {
			matchBy = "hostname"
			updateExisting(&dev, ip, mac, hostname, vendorClass, opt55Hash, devType, now, updateLastSeen, matchBy)
			return
		}
	}
	// Tier 3: IP (weak match, do NOT update MAC)
	if ip != "" {
		if err := db.Where("ipv4 = ?", ip).First(&dev).Error; err == nil {
			matchBy = "ip"
			updateExisting(&dev, ip, "", hostname, vendorClass, opt55Hash, devType, now, updateLastSeen, matchBy)
			return
		}
	}

	// New device
	dev = models.Device{
		Hostname:    hostname,
		DeviceType:  devType,
		MAC:         mac,
		IPv4:        ip,
		VendorClass: vendorClass,
		Opt55Hash:   opt55Hash,
		LastSeen:    now,
	}
	db.Create(&dev)
	if mac != "" {
		db.Where(models.DeviceMAC{DeviceID: dev.ID, MAC: mac}).FirstOrCreate(&models.DeviceMAC{DeviceID: dev.ID, MAC: mac})
	}
}

func updateExisting(dev *models.Device, ip, mac, hostname, vendorClass, opt55Hash, devType string, now int64, updateLastSeen bool, matchBy string) {
	updates := map[string]interface{}{}
	if updateLastSeen {
		updates["last_seen"] = now
	}
	// Only update IP when matched by a strong identifier (prevents conntrack from reverting IP changes)
	if matchBy != "ip" && matchBy != "hostname" {
		if ip != "" && isLAN(ip) && !strings.Contains(ip, ":") {
			updates["ipv4"] = ip
		}
	}
	if hostname != "" && dev.Hostname == "" {
		updates["hostname"] = hostname
	}
	if devType != "" && devType != "Unknown" && (dev.DeviceType == "" || dev.DeviceType == "Unknown") {
		updates["device_type"] = devType
		if dev.DeviceType != devType {
			log.Printf("CORE: updating device %d type from %q to %q (hostname=%q)", dev.ID, dev.DeviceType, devType, hostname)
		}
	}
	// Only update MAC when matched by a strong identifier (not IP or hostname alone)
	if matchBy == "opt55" || matchBy == "mac" {
		if mac != "" && len(mac) == 17 && strings.Count(mac, ":") == 5 {
			updates["mac"] = mac
			db.Where(models.DeviceMAC{DeviceID: dev.ID, MAC: mac}).FirstOrCreate(&models.DeviceMAC{DeviceID: dev.ID, MAC: mac})
			if dev.Opt55Hash != "" {
				var dup models.Device
				if db.Where("mac = ? AND id != ? AND opt55_hash = ''", mac, dev.ID).First(&dup).Error == nil {
					db.Exec("INSERT OR IGNORE INTO device_macs (device_id, mac) SELECT ?, mac FROM device_macs WHERE device_id = ?", dev.ID, dup.ID)
					db.Where("device_id = ?", dup.ID).Delete(&models.DeviceMAC{})
					db.Delete(&dup)
				}
			}
			if dt := detectTypeByMAC(mac); dt != "" && dt != "Unknown" && (dev.DeviceType == "" || dev.DeviceType == "Unknown") {
				updates["device_type"] = dt
			}
		}
	}
	if vendorClass != "" {
		updates["vendor_class"] = vendorClass
	}
	if opt55Hash != "" && dev.Opt55Hash == "" {
		updates["opt55_hash"] = opt55Hash
	}

	db.Model(dev).Updates(updates)

	// IP collision check (only for strong matches)
	if matchBy == "opt55" || matchBy == "mac" {
		if dev.IPv4 != "" && ip != "" && dev.IPv4 != ip {
			var dup models.Device
			if err := db.Where("ipv4 = ? AND id != ?", ip, dev.ID).First(&dup).Error; err == nil {
				db.Exec("INSERT OR IGNORE INTO device_macs (device_id, mac) SELECT ?, mac FROM device_macs WHERE device_id = ?", dev.ID, dup.ID)
				db.Where("device_id = ?", dup.ID).Delete(&models.DeviceMAC{})
				if dev.Hostname == "" && dup.Hostname != "" {
					db.Model(dev).Update("hostname", dup.Hostname)
				}
				db.Delete(&dup)
			}
		}
	}
}
