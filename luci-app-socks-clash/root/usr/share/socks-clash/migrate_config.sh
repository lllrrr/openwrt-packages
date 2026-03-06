#!/bin/sh
set -e
OPKG_CONF="/etc/config/socks-clash-opkg"
ACTIVE_CONF="/etc/config/socks-clash"

if [ -f "$OPKG_CONF" ]; then
  if [ ! -f "$ACTIVE_CONF" ]; then
    cp "$OPKG_CONF" "$ACTIVE_CONF"
  else
    echo "Migrating: keeping existing config" >/dev/null
  fi
  rm -f "$OPKG_CONF"
fi
exit 0
