#!/bin/sh

LOG=/tmp/ota.log
FW=/etc/ota/firmware.json

echo "" > $LOG

log(){
  echo "$1" >> $LOG
}

log "OTA START"
sleep 1

log "Checking firmware list..."
sleep 1

log "Downloading firmware..."
for i in 10 30 60 80 100
do
  log "progress=$i%"
  sleep 1
done

log "Flashing system (sysupgrade simulation)..."
sleep 2

log "Verifying checksum..."
sleep 1

log "SUCCESS: rebooting"
