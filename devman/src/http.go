package main

import "net/http"

func httpServe() {
	http.HandleFunc("/api/devices", apiDevices)
	http.HandleFunc("/api/block", apiBlock)
	http.HandleFunc("/api/limit", apiLimit)
	go http.ListenAndServe(":9999", nil)
}
