
#!/bin/sh

STATE=/tmp/ota_state.json
FW=/tmp/fw.bin
URL="https://example.com/fw.bin"

update(){
 echo "{\"state\":\"$1\",\"progress\":$2,\"msg\":\"$3\"}" > $STATE
 ubus send ota.event "{\"state\":\"$1\",\"progress\":$2}"
}

update CHECK 0 "Checking"

sleep 1

update DOWNLOADING 10 "Downloading"
wget -O $FW $URL || {
 update FAIL 0 "Download failed"
 exit 1
}

update VERIFY 60 "Verifying"
sha256sum $FW || {
 update FAIL 0 "Checksum fail"
 exit 1
}

update FLASHING 80 "Flashing"

# ⚠️ 真升级（测试先注释）
# sysupgrade -n $FW

update REBOOT 95 "Rebooting"
reboot