package main

import (
	"encoding/json"
	"log"
	"os"
)

var ouiVendorMap map[string]string

func loadOUI(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, &ouiVendorMap)
}

func init() {
	path := "/etc/devman/oui.json"
	if err := loadOUI(path); err != nil {
		log.Printf("OUI: failed to load %s: %v, OUI detection disabled", path, err)
		ouiVendorMap = make(map[string]string)
	}
}
