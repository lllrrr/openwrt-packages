package main

import (
	"strings"
)

func detectType(hostname, vendorClass string) string {
	h := strings.ToLower(hostname)
	v := strings.ToLower(vendorClass)
	if h == "" {
		return "Unknown"
	}
	for _, kw := range []string{"iphone", "ipad", "apple", "macbook", "imac"} {
		if strings.Contains(h, kw) || strings.Contains(v, kw) {
			return "Apple"
		}
	}
	for _, kw := range []string{"xiaomi", "redmi"} {
		if strings.Contains(h, kw) || strings.Contains(v, kw) {
			return "Xiaomi"
		}
	}
	for _, kw := range []string{"samsung", "sgt-"} {
		if strings.Contains(h, kw) || strings.Contains(v, kw) {
			return "Samsung"
		}
	}
	for _, kw := range []string{"oneplus"} {
		if strings.Contains(h, kw) || strings.Contains(v, kw) {
			return "OnePlus"
		}
	}
	for _, kw := range []string{"huawei", "honor"} {
		if strings.Contains(h, kw) || strings.Contains(v, kw) {
			return "Huawei"
		}
	}
	for _, kw := range []string{"pixel"} {
		if strings.Contains(h, kw) || strings.Contains(v, kw) {
			return "Google"
		}
	}
	for _, kw := range []string{"android"} {
		if strings.Contains(h, kw) || strings.Contains(v, kw) {
			return "Android"
		}
	}
	if strings.Contains(h, "desktop") || strings.Contains(h, "windows") || strings.Contains(h, "pc-") {
		return "Windows"
	}
	if strings.Contains(h, "ubuntu") || strings.Contains(h, "debian") || strings.Contains(h, "raspberry") || strings.Contains(h, "openwrt") || strings.Contains(v, "dhcpcd-") {
		return "Linux"
	}
	for _, kw := range []string{"lumi", "gateway", "midea", "esp", "sonoff", "tasmota", "ipcamera", "camera", "wlan", "bouffalolab", "plug"} {
		if strings.Contains(h, kw) || strings.Contains(v, kw) {
			return "IoT"
		}
	}
	if strings.Contains(h, "tmall") || strings.Contains(h, "天猫") {
		return "IoT"
	}
	return "Unknown"
}

func detectTypeByMAC(mac string) string {
	mac = strings.ToLower(strings.ReplaceAll(mac, ":", ""))
	if len(mac) < 6 {
		return ""
	}
	oui := mac[:6]
	if len(mac) >= 2 {
		firstByte, _ := hexToByte(mac[:2])
		if firstByte&0x2 != 0 {
			return ""
		}
	}
	if v, ok := ouiVendorMap[oui]; ok {
		return v
	}
	return "Unknown"
}
