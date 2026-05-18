#!/usr/bin/lua
-- DeviceMaster Snapshot Writer (standalone, no LuCI dependency)
-- Runs via cron every 60s on master node
-- Writes /tmp/dm_snapshot.json for sub-node consumption

local json = require("luci.jsonc")
local uci = require("luci.model.uci").cursor()
local SNAPSHOT = "/tmp/dm_snapshot.json"
local CHILD_REPORTS = "/tmp/dm_child_reports.json"

local function get_ap_ifaces()
    local ifaces = {}
    local handle = io.popen("ls /sys/class/net/ 2>/dev/null | grep '^wl'")
    if handle then
        for line in handle:lines() do
            local iface = line:match("^(%S+)")
            if iface and not iface:match("mesh") then
                table.insert(ifaces, iface)
            end
        end
        handle:close()
    end
    if #ifaces == 0 then
        return {"wl0-ap0", "wl1-ap0", "wl0-ap1", "wl1-ap1"}
    end
    return ifaces
end

local function get_mesh_vmac()
    local handle = io.popen("ip link show dev wl1-mesh0 2>/dev/null | grep 'link/ether' | awk '{print $2}'")
    if handle then
        local mac = handle:read("*l")
        handle:close()
        if mac and mac ~= "" then
            return mac:upper():match("^([0-9A-Fa-f:]+)")
        end
    end
    return nil
end

local snap = {
    _ts = os.time(),
    role = "master",
    dhcp_leases = {},
    arp = {},
    wifi_stations = {},
    fdb_macs = {},
    child_reports = {},
    devices = {},  -- populated below from UCI, then enriched with sub-node data
    master_mac = "",  -- set below for sub-node identification
    master_ip = ""
}

-- Node's own identity (sub-nodes use master_mac to identify the master)
local br_handle = io.popen("ip link show dev br-lan 2>/dev/null | grep 'link/ether' | awk '{print $2}'")
if br_handle then
    local br_mac = br_handle:read("*l")
    br_handle:close()
    if br_mac then
        snap.master_mac = br_mac:upper():match("^([0-9A-Fa-f:]+)") or ""
    end
end
local ip_handle = io.popen("ip -4 addr show dev br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1")
if ip_handle then
    local ip = ip_handle:read("*l")
    ip_handle:close()
    if ip then snap.master_ip = ip end
end

-- DHCP leases
local f = io.open("/tmp/dhcp.leases", "r")
if f then
    for line in f:lines() do
        local ts, mac, ip, hostname = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac and ip then snap.dhcp_leases[mac:upper()] = { ip = ip, hostname = hostname or "" } end
    end
    f:close()
end

-- ARP table
f = io.open("/proc/net/arp", "r")
if f then
    f:read("*l") -- skip header
    for line in f:lines() do
        local ip, hw_type, flags, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac and mac ~= "00:00:00:00:00:00" and flags ~= "0x0" then
            snap.arp[mac:upper()] = ip
        end
    end
    f:close()
end

-- WiFi stations via iwinfo
for _, iface in ipairs(get_ap_ifaces()) do
    local handle = io.popen("iwinfo " .. iface .. " assoclist 2>/dev/null")
    if handle then
        for line in handle:lines() do
            for word in line:gmatch("%S+") do
                if #word == 17 and word:match("^[0-9A-Fa-f:]+$") then
                    snap.wifi_stations[word:upper()] = { iface = iface }
                end
            end
        end
        handle:close()
    end
end

-- Bridge FDB
local mesh_vmac = get_mesh_vmac()
local handle = io.popen("brctl showmacs br-lan 2>/dev/null")
if handle then
    local mesh_port = nil
    -- First pass: find mesh port
    for line in handle:lines() do
        local port, mac, is_local = line:match("^%s*(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)")
        if port and mac and is_local == "yes" and mesh_vmac and mac:upper() == mesh_vmac then
            mesh_port = port
            break
        end
    end
    handle:close()
    -- Second pass: collect non-local MACs on mesh port
    if mesh_port then
        local h2 = io.popen("brctl showmacs br-lan 2>/dev/null")
        if h2 then
            for line in h2:lines() do
                local port, mac, is_local = line:match("^%s*(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)")
                if port and port == mesh_port and mac and is_local == "no" then
                    snap.fdb_macs[mac:upper()] = true
                end
            end
            h2:close()
        end
    end
end

-- Merge pushed reports from sub-nodes (via POST /api/report_sub)
-- Then poll sub-node snapshots (full device data served via cron at /www)
local known_peers = {}

-- Step 1: Load pushed reports from file (real-time push from sub-nodes)
local cf = io.open("/tmp/dm_child_reports.json", "r")
if cf then
    local ok, pushed = pcall(json.parse, cf:read("*a"))
    cf:close()
    if ok and type(pushed) == "table" then
        for node_mac, report in pairs(pushed) do
            known_peers[node_mac] = report
            -- Merge pushed data into master snapshot
            for lease_mac, lease_info in pairs(report.dhcp_leases or {}) do
                if not snap.dhcp_leases[lease_mac] then
                    snap.dhcp_leases[lease_mac] = lease_info
                end
            end
            for arp_mac, arp_ip in pairs(report.arp or {}) do
                if not snap.arp[arp_mac] then
                    snap.arp[arp_mac] = arp_ip
                end
            end
            for dev_mac, dev_info in pairs(report.devices or {}) do
                if not snap.devices[dev_mac] then
                    snap.devices[dev_mac] = dev_info
                end
            end
        end
    end
end

-- Step 2: Poll sub-node snapshots (refreshes stale pushed data)
for mac, _ in pairs(snap.fdb_macs) do
    local peer_ip = snap.arp[mac] or snap.dhcp_leases[mac] and snap.dhcp_leases[mac].ip
    if peer_ip then
        local handle = io.popen("curl -s --connect-timeout 2 --max-time 4 'http://" .. peer_ip .. "/luci-static/resources/dm_snapshot.json' 2>/dev/null")
        if handle then
            local raw = handle:read("*a")
            handle:close()
            if raw and raw ~= "" then
                local ok, pr = pcall(json.parse, raw)
                if ok and type(pr) == "table" and pr.wifi_stations then
                    known_peers[mac] = {
                        ts = os.time(),
                        stations = pr.wifi_stations or {},
                        dhcp_leases = pr.dhcp_leases or {},
                        arp = pr.arp or {},
                        devices = pr.devices or {}
                    }
                    -- Merge sub-node's DHCP leases (fill gaps, don't overwrite)
                    for lease_mac, lease_info in pairs(pr.dhcp_leases or {}) do
                        if not snap.dhcp_leases[lease_mac] then
                            snap.dhcp_leases[lease_mac] = lease_info
                        end
                    end
                    -- Merge sub-node's ARP entries
                    for arp_mac, arp_ip in pairs(pr.arp or {}) do
                        if not snap.arp[arp_mac] then
                            snap.arp[arp_mac] = arp_ip
                        end
                    end
                    -- Merge sub-node's UCI device profiles (for enrichment)
                    for dev_mac, dev_info in pairs(pr.devices or {}) do
                        if not snap.devices[dev_mac] then
                            snap.devices[dev_mac] = dev_info
                        end
                    end
                end
            end
        end
    end
end
snap.child_reports = known_peers

-- UCI device profiles (for sub-node enrichment)
uci:foreach("devicemaster", "device", function(s)
    if s.mac then
        snap.devices[s.mac:upper()] = {
            vendor = s.vendor or "",
            devtype = s.type or "",
            name = s.name or "",
            hostname = s.hostname or ""
        }
    end
end)

-- Computed online MACs (for sub-node: reliable online indicators)
-- Start with WiFi stations (confirmed connected)
local online_macs = {}
for mac, _ in pairs(snap.wifi_stations) do
    online_macs[mac] = snap.arp[mac] or (snap.dhcp_leases[mac] and snap.dhcp_leases[mac].ip) or ""
end
-- Active DHCP leases (confirmed by ARP — kernel-verified reachability)
-- Stale leases without ARP are excluded to prevent ghost entries on sub-node
for mac, _ in pairs(snap.dhcp_leases) do
    if not online_macs[mac] and snap.arp[mac] then
        online_macs[mac] = snap.arp[mac]
    end
end
-- ip neigh: include all states except FAILED/INCOMPLETE (kernel-confirmed neighbors)
local nh = io.popen("ip neigh show 2>/dev/null")
if nh then
    for line in nh:lines() do
        local nip, nmac, nstate = line:match("^(%d+%.%d+%.%d+%.%d+)%s+lladdr%s+([0-9a-fA-F:]+)%s+(%S+)")
        if nmac and nstate then
            nstate = nstate:upper()
            if nstate ~= "FAILED" and nstate ~= "INCOMPLETE" then
                local mac_up = nmac:upper()
                if not online_macs[mac_up] then
                    online_macs[mac_up] = nip
                end
            end
        end
    end
    nh:close()
end
-- Fallback: all complete ARP entries (kernel-resolved = reachable)
for mac, ip in pairs(snap.arp) do
    if not online_macs[mac] then
        online_macs[mac] = ip
    end
end
snap.online_macs = online_macs

-- Write snapshot
local json_str = json.stringify(snap)
local sf = io.open(SNAPSHOT, "w")
if sf then
    sf:write(json_str)
    sf:close()
end
-- Also write to web root for cross-node HTTP access without auth
local wf = io.open("/www/luci-static/resources/dm_snapshot.json", "w")
if wf then
    wf:write(json_str)
    wf:close()
end
