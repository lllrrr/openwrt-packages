#!/bin/sh
# DeviceMaster Snapshot Writer - runs via cron
# Lightweight shell: reads local data, calls Lua for JSON generation

SNAPSHOT_FILE="/tmp/dm_snapshot.json"
CHILD_REPORTS_FILE="/tmp/dm_child_reports.json"
NOW=$(date +%s)

# Use uclient-fetch or wget to call the API on localhost
# This uses the existing LuCI module which has the snapshot logic
if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O- "http://127.0.0.1/cgi-bin/luci/admin/network/devicemaster/api/snapshot" 2>/dev/null > "$SNAPSHOT_FILE"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O- "http://127.0.0.1/cgi-bin/luci/admin/network/devicemaster/api/snapshot" 2>/dev/null > "$SNAPSHOT_FILE"
elif command -v curl >/dev/null 2>&1; then
    curl -s "http://127.0.0.1/cgi-bin/luci/admin/network/devicemaster/api/snapshot" > "$SNAPSHOT_FILE"
fi

# If snapshot file is empty or error, write minimal fallback
if [ ! -s "$SNAPSHOT_FILE" ] || grep -q '"error"' "$SNAPSHOT_FILE" 2>/dev/null; then
    printf '{"_ts":%d,"role":"master","dhcp_leases":{}}\n' "$NOW" > "$SNAPSHOT_FILE"
fi
