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

-- WiFi stations from all AP interfaces
local ifaces = {"wl0-ap0", "wl1-ap0", "wl0-ap1", "wl1-ap1"}
for _, iface in ipairs(ifaces) do
    local f = io.popen("iwinfo " .. iface .. " assoclist 2>/dev/null")
    if f then
        for line in f:lines() do
            for word in line:gmatch("%S+") do
                if #word == 17 and word:match("^[0-9A-Fa-f:]+$") then
                    report.stations[word:upper()] = { iface = iface }
                end
            end
        end
        f:close()
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
