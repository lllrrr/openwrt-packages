package main

import (
	"net/http"

	"devman/handler"
)

func httpServe() {
	handler.DB = db
	handler.GetSpeed = getSpeed
	handler.NftSetLimit = nftSetLimit

	r := handler.SetupRouter()
	go http.ListenAndServe(":9999", r)
}
