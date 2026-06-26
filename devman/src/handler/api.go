package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"devman/models"
	"github.com/go-chi/chi/v5"
	"gorm.io/gorm"
)

type DeviceWithSpeed struct {
	models.Device
	Online   string `json:"online"`
	NumMACs  int64  `json:"num_macs"`
	SpeedIn  uint64 `json:"speed_in"`
	SpeedOut uint64 `json:"speed_out"`
}

var DB *gorm.DB
var GetSpeed func(ip string) (uint64, uint64)

func apiDevices(w http.ResponseWriter, r *http.Request) {
	var devs []models.Device
	DB.Where("ipv4 != '' AND ipv4 IS NOT NULL AND ipv4 LIKE '%.%.%.%' AND ipv4 NOT LIKE '%:%'").Order("ipv4 ASC").Find(&devs)

	result := make([]DeviceWithSpeed, 0, len(devs))
	for _, d := range devs {
		if d.DeviceType == "" {
			d.DeviceType = "Unknown"
		}

		si, so := GetSpeed(d.IPv4)
		online := "gray"
		if si > 0 || so > 0 {
			online = "green"
		} else if d.LastSeen > time.Now().Unix()-60 {
			online = "green"
		} else if d.LastSeen > time.Now().Unix()-120 {
			online = "yellow"
		}

		var nmacs int64
		DB.Model(&models.DeviceMAC{}).Where("device_id = ?", d.ID).Count(&nmacs)
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
	DB.Model(&models.Device{}).Where("id = ?", req.DeviceID).Update("is_blocked", req.Block)
	w.Write([]byte(`{"ok":true}`))
}

func apiLimit(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID    int64  `json:"device_id"`
		RateLimit   int    `json:"rate_limit"`
		RateLimitDn int    `json:"rate_limit_down"`
		Alias       string `json:"alias"`
		Opt55Hash   string `json:"opt55_hash"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	if req.Alias != "" {
		DB.Model(&models.Device{}).Where("id = ?", req.DeviceID).Update("alias", req.Alias)
	}
	if req.Opt55Hash != "" {
		DB.Model(&models.Device{}).Where("id = ?", req.DeviceID).Update("opt55_hash", req.Opt55Hash)
	}
	if req.RateLimit != -1 {
		DB.Model(&models.Device{}).Where("id = ?", req.DeviceID).Update("rate_limit", req.RateLimit)
	}
	if req.RateLimitDn != -1 {
		DB.Model(&models.Device{}).Where("id = ?", req.DeviceID).Update("rate_limit_dn", req.RateLimitDn)
	}
	var d models.Device
	if DB.Where("id = ?", req.DeviceID).First(&d).Error == nil && d.IPv4 != "" {
		go NftSetLimit(d.IPv4, d.RateLimit, d.RateLimitDn)
	}
	w.Write([]byte(`{"ok":true}`))
}

var NftSetLimit func(ip string, ulBps, dlBps int)

func SetupRouter() *chi.Mux {
	r := chi.NewRouter()
	r.Get("/api/devices", apiDevices)
	r.Post("/api/block", apiBlock)
	r.Post("/api/limit", apiLimit)
	return r
}
