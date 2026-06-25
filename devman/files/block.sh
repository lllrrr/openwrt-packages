#!/bin/sh
# nftables set-based blocking for devman
case "$1" in
  init)
    nft add table ip devman 2>/dev/null
    nft add set ip devman blocked_ip { type ipv4_addr\; } 2>/dev/null
    nft add chain ip devman forward { type filter hook forward priority filter - 1\; } 2>/dev/null
    nft add rule ip devman forward ip saddr @blocked_ip drop 2>/dev/null
    ;;
  add) nft add element ip devman blocked_ip { $2 } 2>/dev/null ;;
  del) nft delete element ip devman blocked_ip { $2 } 2>/dev/null ;;
esac
