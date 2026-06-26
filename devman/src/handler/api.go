package handler

import (
	"encoding/json"
	"net/http"
	"strconv"
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
	var devID int64
	var block bool
	if err := json.NewDecoder(r.Body).Decode(&struct {
		DeviceID *int64 `json:"device_id"`
		Block    *bool  `json:"block"`
	}{DeviceID: &devID, Block: &block}); err != nil {
		devID, _ = parseInt64(r.URL.Query().Get("device_id"))
		block = r.URL.Query().Get("block") == "1" || r.URL.Query().Get("block") == "true"
	}
	DB.Model(&models.Device{}).Where("id = ?", devID).Update("is_blocked", block)
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		req.DeviceID, _ = parseInt64(r.URL.Query().Get("device_id"))
		req.RateLimit, _ = parseInt(r.URL.Query().Get("rate_limit"))
		req.RateLimitDn, _ = parseInt(r.URL.Query().Get("rate_limit_down"))
		req.Alias = r.URL.Query().Get("alias")
		req.Opt55Hash = r.URL.Query().Get("opt55_hash")
	}
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

func parseInt64(s string) (int64, error) {
	return strconv.ParseInt(s, 10, 64)
}

func parseInt(s string) (int, error) {
	return strconv.Atoi(s)
}

func SetupRouter() *chi.Mux {
	r := chi.NewRouter()
	r.Get("/api/devices", apiDevices)
	r.Get("/api/block", apiBlock)
	r.Post("/api/block", apiBlock)
	r.Get("/api/limit", apiLimit)
	r.Post("/api/limit", apiLimit)
	return r
}
