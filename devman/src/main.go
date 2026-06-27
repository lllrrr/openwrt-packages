package main

import (
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"devman/discover"
	"devman/models"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

var (
	db       *gorm.DB
	mu       sync.RWMutex
	limitMu  sync.Mutex
	lanIface = "br-lan"
)

func main() {
	log.SetFlags(log.LstdFlags)

	// Read config from environment variables (set by init script) or use defaults
	dbPath := os.Getenv("DB_PATH")
	if dbPath == "" {
		dbPath = "/etc/devman/devman.db"
	}
	lanIf := os.Getenv("LAN_IF")
	if lanIf == "" {
		lanIf = "br-lan"
	}
	lanIface = lanIf

	os.MkdirAll("/etc/devman", 0755)

	var err error
	db, err = gorm.Open(sqlite.Open(dbPath), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Warn),
	})
	if err != nil {
		log.Fatal(err)
	}
	models.MigrateDB(db)
	detectLAN()

	retypeUnknown()

	nftInit()
	nftSetSubnet(lanSubnet)
	restoreRateLimits()

	// Wire discover package dependencies
	discover.DB = db
	discover.UpsertDevice = upsertDevice
	discover.UpsertDeviceNoSeen = upsertDeviceNoSeen
	discover.IsLAN = isLAN

	go discover.NeightLoop()
	go discover.ConntrackLoop()
	go discover.DnsmasqLeaseLoop()
	go dhcpBPFLoop()
	go discover.ResolveHostnamesLoop()
	go reconcileLoop()
	go speedLoop()

	httpServe()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	nftCleanup()
}

func retypeUnknown() {
	db.Model(&models.Device{}).Where("device_type = '' OR device_type IS NULL").
		Update("device_type", "Unknown")
}
