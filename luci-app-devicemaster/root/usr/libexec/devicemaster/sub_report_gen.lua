#!/usr/bin/lua
-- Sub-node Report Generator
-- Generates full device report for push to master node
-- Usage: lua sub_report_gen.lua <node_mac>

local json = require("luci.jsonc")
local node_mac = arg[1] or "unknown"

local report = {
    node_mac = node_mac,
    _ts = os.time(),
    stations = {},
    dhcp_leases = {},
    arp = {},
    devices = {}
}

-- OPTIMIZED: WiFi stations using iw station dump (kernel direct)
-- Instead of iwinfo which spawns ubus calls to hostapd
-- This prevents hostapd memory growth caused by frequent ubus requests
local function get_wifi_stations_iw(iface)
    local stations = {}
    local f = io.popen("iw dev " .. iface .. " station dump 2>/dev/null")
    if f then
        for line in f:lines() do
            local mac = line:match("^Station ([0-9A-Fa-f:]+)")
            if mac then
                stations[mac:upper()] = { iface = iface }
            end
        end
        f:close()
    end
    return stations
end

-- Collect stations from AP interfaces (using iw, not iwinfo)
local ap_ifaces = {"wl0-ap0", "wl1-ap0"}
for _, iface in ipairs(ap_ifaces) do
    local iface_stations = get_wifi_stations_iw(iface)
    for mac, info in pairs(iface_stations) do
        report.stations[mac] = info
    end
end

-- DHCP leases
local f = io.open("/tmp/dhcp.leases", "r")
if f then
    for line in f:lines() do
        local ts, mac, ip, hostname = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac and ip then
            report.dhcp_leases[mac:upper()] = { ip = ip, hostname = hostname or "" }
        end
    end
    f:close()
end

-- ARP table
f = io.open("/proc/net/arp", "r")
if f then
    f:read("*l")  -- skip header
    for line in f:lines() do
        local ip, hw_type, flags, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac and mac ~= "00:00:00:00:00:00" and flags ~= "0x0" then
            report.arp[mac:upper()] = ip
        end
    end
    f:close()
end

-- UCI device profiles
local uci = require("luci.model.uci").cursor()
uci:foreach("devicemaster", "device", function(s)
    if s.mac then
        report.devices[s.mac:upper()] = {
            vendor = s.vendor or "",
            devtype = s.type or "",
            name = s.name or "",
            hostname = s.hostname or ""
        }
    end
end)

io.write(json.stringify(report))
