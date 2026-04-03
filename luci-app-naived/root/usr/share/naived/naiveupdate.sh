#!/bin/sh
/usr/bin/lua /usr/share/naived/update.lua
sleep 2s
sh /usr/share/naived/chinaipset.sh /var/etc/naived/china_ip.txt
