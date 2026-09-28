#!/usr/bin/lua
-- Sub-node Report Generator
-- Generates full device report for push to master node
-- Usage: lua sub_report_gen.lua <node_mac>
--
-- The report is POSTed by device_monitor.sh to the master's /api/report_sub.
-- Besides this node's own clients it carries three things the master needs:
--
--   node_ip   - the node's LAN address, so the master can poll the right hosts
--               instead of curling every MAC it sees on the mesh bridge port
--               (see the poller in snapshot_writer.lua).
--   role      - "sub", so the master can tell a node report from a stray POST.
--   relayed   - reports this node received from OTHER sub nodes. A node behind
--               a mesh repeater posts to its default gateway, which is that
--               repeater and not the master; the repeater used to file those
--               reports in its own /tmp and never forward them, so anything two
--               hops out was invisible on the master.

local json = require("luci.jsonc")
local node_mac = (arg[1] or ""):upper()

-- Reports older than this are not worth relaying. Mirrors REPORT_TTL in
-- luasrc/controller/devicemaster.lua.
local REPORT_TTL = 900
local MAX_RELAY = 8

local report = {
    node_mac = node_mac,
    node_ip = "",
    role = "sub",
    _ts = os.time(),
    stations = {},
    dhcp_leases = {},
    arp = {},
    devices = {}
}

-- AP interfaces to inspect, enumerated from the kernel.
--
-- This used to be a hard-coded {"wl0-ap0", "wl1-ap0"}: a node carrying an extra
-- SSID (wl0-ap1) or using a different radio naming silently reported only a
-- subset of its clients, and the master then treated the rest as "not on this
-- node". snapshot_writer.lua enumerates the same way - keep the two in sync.
local function get_ap_ifaces()
    local ifaces = {}
    local h = io.popen("ls /sys/class/net/ 2>/dev/null")
    if h then
        for line in h:lines() do
            -- <radio>-ap<N> is a hostapd BSS: wl0-ap0 on GL.iNet, phy0-ap0 on
            -- plain OpenWrt. Matching that shape keeps wl1-mesh0 out without a
            -- separate exclusion, and a bare "^wl" prefix test would have
            -- caught wlan0 as well. Same rule in snapshot_writer.lua and
            -- devicemaster.lua.
            if line:match("%-ap%d+$") then
                table.insert(ifaces, line)
            end
        end
        h:close()
    end
    if #ifaces == 0 then
        return { "wl0-ap0", "wl1-ap0" }
    end
    return ifaces
end

-- WiFi stations via `iw ... station dump` (kernel direct).
-- NOT iwinfo: that goes through ubus to hostapd, and frequent calls make
-- hostapd's memory footprint grow over long uptimes.
local function collect_stations()
    local stations = {}
    for _, iface in ipairs(get_ap_ifaces()) do
        local f = io.popen("iw dev " .. iface .. " station dump 2>/dev/null")
        if f then
            for line in f:lines() do
                local mac = line:match("^Station%s+([0-9A-Fa-f:]+)")
                if mac and #mac == 17 then
                    stations[mac:upper()] = { iface = iface }
                end
            end
            f:close()
        end
    end
    return stations
end

report.stations = collect_stations()

-- This node's LAN address (what the master should poll / push back to).
local function get_lan_ip()
    local f = io.popen("ip -4 addr show dev br-lan 2>/dev/null | awk '/inet /{print $2; exit}'")
    if f then
        local addr = f:read("*l")
        f:close()
        if addr then
            return addr:match("^(%d+%.%d+%.%d+%.%d+)") or ""
        end
    end
    return ""
end

report.node_ip = get_lan_ip()

-- One level of relaying for multi-hop meshes (see the header comment).
local function collect_relayed()
    local out = {}
    local f = io.open("/tmp/dm_child_reports.json", "r")
    if not f then return out end
    local ok, all = pcall(json.parse, f:read("*a"))
    f:close()
    if not ok or type(all) ~= "table" then return out end

    local now = os.time()
    local n = 0
    for mac, rep in pairs(all) do
        if n >= MAX_RELAY then break end
        -- Skip ourselves, anything that is not a MAC, and stale reports.
        if type(mac) == "string" and mac ~= node_mac
            and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$")
            and type(rep) == "table"
            and tonumber(rep.ts) and (now - tonumber(rep.ts)) <= REPORT_TTL
        then
            out[mac:upper()] = {
                stations = rep.stations or {},
                dhcp_leases = rep.dhcp_leases or {},
                arp = rep.arp or {},
                devices = rep.devices or {},
                node_ip = rep.node_ip or "",
                ts = tonumber(rep.ts)
            }
            n = n + 1
        end
    end
    return out
end

local relayed = collect_relayed()
if next(relayed) then
    report.relayed = relayed
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
