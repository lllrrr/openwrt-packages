package main

import (
	"log"
	"time"

	"devman/models"
)

func mergeDuplicateHostnames() {
	type row struct {
		Hostname string
		Cnt      int
	}
	var rows []row
	db.Model(&models.Device{}).Select("hostname, COUNT(*) cnt").
		Where("hostname != ''").Group("hostname").Having("cnt > 1").Find(&rows)
	for _, r := range rows {
		var ids []int64
		db.Model(&models.Device{}).Where("hostname = ?", r.Hostname).Order("last_seen DESC").Pluck("id", &ids)
		if len(ids) < 2 {
			continue
		}
		keeper := ids[0]
		for _, id := range ids[1:] {
			db.Exec("INSERT OR IGNORE INTO device_macs (device_id, mac) SELECT ?, mac FROM device_macs WHERE device_id = ?", keeper, id)
			db.Where("device_id = ?", id).Delete(&models.DeviceMAC{})
			db.Delete(&models.Device{}, id)
		}
	}
}

func mergeByOpt55Hash() {
	var hashes []string
	db.Raw("SELECT opt55_hash FROM devices WHERE opt55_hash != '' GROUP BY opt55_hash HAVING COUNT(*) > 1").Scan(&hashes)
	if len(hashes) > 0 {
		log.Printf("RECONCILE: mergeByOpt55Hash found %d duplicate hashes", len(hashes))
	}
	for _, hash := range hashes {
		var ids []int64
		db.Model(&models.Device{}).Where("opt55_hash = ?", hash).
			Order("CASE WHEN hostname != '' THEN 0 ELSE 1 END, last_seen DESC").
			Pluck("id", &ids)
		if len(ids) < 2 {
			continue
		}
		log.Printf("RECONCILE: merging %d devices by opt55_hash=%s", len(ids), hash)
		keeper := ids[0]
		for _, id := range ids[1:] {
			db.Exec("INSERT OR IGNORE INTO device_macs (device_id, mac) SELECT ?, mac FROM device_macs WHERE device_id = ?", keeper, id)
			db.Where("device_id = ?", id).Delete(&models.DeviceMAC{})
			db.Delete(&models.Device{}, id)
		}
	}
}

func absorbNoFingerprint() {
	var tracked []models.Device
	db.Where("opt55_hash != ''").Find(&tracked)
	if len(tracked) == 0 {
		return
	}
	cutoff := time.Now().Unix() - 120
	for _, t := range tracked {
		var orphans []models.Device
		db.Where("opt55_hash = '' AND hostname = '' AND last_seen < ? AND mac IN (SELECT mac FROM device_macs WHERE device_id = ?)", cutoff, t.ID).Find(&orphans)
		for _, o := range orphans {
			log.Printf("RECONCILE: absorbing device %d (no fingerprint) into %d (opt55=%s)", o.ID, t.ID, t.Opt55Hash)
			db.Exec("INSERT OR IGNORE INTO device_macs (device_id, mac) SELECT ?, mac FROM device_macs WHERE device_id = ?", t.ID, o.ID)
			db.Where("device_id = ?", o.ID).Delete(&models.DeviceMAC{})
			db.Delete(&o)
		}
	}
}

func reconcileLoop() {
	for {
		time.Sleep(5 * time.Second)
		mergeDuplicateHostnames()
		mergeByOpt55Hash()
		absorbNoFingerprint()

		var dbBlocked []string
		db.Model(&models.Device{}).Where("is_blocked = 1 AND ipv4 != ''").Pluck("ipv4", &dbBlocked)
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

func toSet(list []string) map[string]bool {
	m := make(map[string]bool, len(list))
	for _, s := range list {
		m[s] = true
	}
	return m
}
