package models

import "gorm.io/gorm"

type Device struct {
	ID          int64  `gorm:"primaryKey;autoIncrement" json:"id"`
	Alias       string `json:"alias"`
	Hostname    string `gorm:"index" json:"hostname"`
	DeviceType  string `json:"device_type"`
	MAC         string `gorm:"index" json:"current_mac"`
	IPv4        string `gorm:"index" json:"current_ip"`
	IsBlocked   bool   `json:"is_blocked"`
	RateLimit   int    `json:"rate_limit"`
	RateLimitDn int    `gorm:"column:rate_limit_dn" json:"rate_limit_down"`
	LastSeen    int64  `json:"last_seen"`
	VendorClass string `gorm:"column:vendor_class" json:"vendor_class"`
	Opt55Hash   string `gorm:"column:opt55_hash" json:"opt55_hash"`
}

func (Device) TableName() string { return "devices" }

type DeviceMAC struct {
	DeviceID int64  `gorm:"uniqueIndex:idx_dev_mac"`
	MAC      string `gorm:"uniqueIndex:idx_dev_mac"`
}

func (DeviceMAC) TableName() string { return "device_macs" }

func MigrateDB(db *gorm.DB) {
	db.AutoMigrate(&Device{}, &DeviceMAC{})
}
