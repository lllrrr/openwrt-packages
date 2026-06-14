package main

import (
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"

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
	os.MkdirAll("/etc/devman", 0755)

	var err error
	db, err = gorm.Open(sqlite.Open("/etc/devman/devman.db"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Warn),
	})
	if err != nil {
		log.Fatal(err)
	}
	migrateDB(db)
	detectLAN()

	// Re-detect device types on startup
	retypeUnknown()

	nftInit()
	restoreRateLimits()

	go neightLoop()
	go conntrackLoop()
	go dnsmasqLeaseLoop()
	go dhcpBPFLoop()
	go resolveHostnamesLoop()
	go reconcileLoop()
	go speedLoop()

	httpServe()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	nftCleanup()
}

func retypeUnknown() {
	db.Model(&Device{}).Where("device_type = '' OR device_type IS NULL").
		Update("device_type", "Unknown")
}
