package main

import (
	"devman/models"
	"gorm.io/gorm"
)

type Device = models.Device
type DeviceMAC = models.DeviceMAC

func migrateDB(db *gorm.DB) {
	models.MigrateDB(db)
}
