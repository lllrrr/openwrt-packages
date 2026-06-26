package discover

import "gorm.io/gorm"

var (
	DB                 *gorm.DB
	UpsertDevice       func(ip, mac, hostname, vendorClass, opt55Hash string)
	UpsertDeviceNoSeen func(ip, mac, hostname, vendorClass string)
	IsLAN              func(ip string) bool
)
