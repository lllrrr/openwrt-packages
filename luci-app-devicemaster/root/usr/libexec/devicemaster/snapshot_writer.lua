#!/usr/bin/lua
-- DeviceMaster Snapshot Writer (standalone, no LuCI dependency)
-- Runs via cron every 60s on master node
-- Writes /tmp/dm_snapshot.json for sub-node consumption

local json = require("luci.jsonc")
local uci = require("luci.model.uci").cursor()
local SNAPSHOT = "/tmp/dm_snapshot.json"
local CHILD_REPORTS = "/tmp/dm_child_reports.json"

-- A node report older than this is considered dead. device_monitor.sh pushes
-- every 300s on the sub node, so this tolerates two lost reports. Mirrors
-- REPORT_TTL in luasrc/controller/devicemaster.lua.
local REPORT_TTL = 900

local function get_ap_ifaces()
    local ifaces = {}
    local handle = io.popen("ls /sys/class/net/ 2>/dev/null")
    if handle then
        for line in handle:lines() do
            -- <radio>-ap<N> is a hostapd BSS: wl0-ap0 on GL.iNet, phy0-ap0 on
            -- plain OpenWrt. The previous "^wl" prefix test also matched
            -- wlan0, and the "mesh" exclusion was the only thing keeping
            -- wl1-mesh0 out. Same rule as sub_report_gen.lua and
            -- devicemaster.lua.
            if line:match("%-ap%d+$") then
                table.insert(ifaces, line)
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

-- Strict dotted-quad IPv4 check.
--
-- The value is spliced into an io.popen() command line below, and it does NOT
-- originate from the kernel on every path: snap.arp / snap.dhcp_leases are
-- merged from reports pushed by sub nodes over the unauthenticated
-- /api/report_sub endpoint. Without this guard a sub node (or anyone able to
-- reach that endpoint) could return `1.2.3.4'; <command>; echo '` and have it
-- executed here on every cron tick.
local function is_valid_ipv4(ip)
    if type(ip) ~= "string" then
        return false
    end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return false
    end
    for _, octet in ipairs({ a, b, c, d }) do
        if tonumber(octet) > 255 then
            return false
        end
    end
    return true
end

local snap = {
    _ts = os.time(),
    -- Every node runs this writer, so this marks the payload as "a snapshot
    -- produced by the plugin", not "this host is the master". Sub nodes check
    -- exactly this field before trusting a fetched snapshot (api_status in
    -- devicemaster.lua requires parsed.role == "master"), which is why it stays
    -- a constant even when the writer runs on a sub node or a mesh repeater -
    -- the repeater's snapshot is the only copy of its downstream nodes that the
    -- master can reach.
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

-- WiFi stations.
--
-- Uses `iw ... station dump` (kernel direct), NOT `iwinfo ... assoclist`.
-- iwinfo goes through ubus to hostapd, and this script runs from cron every
-- minute - the same per-minute ubus traffic that device_monitor.sh and
-- sub_report_gen.lua were already changed away from because it makes
-- hostapd's memory footprint grow without bound on long uptimes.
for _, iface in ipairs(get_ap_ifaces()) do
    local handle = io.popen("iw dev " .. iface .. " station dump 2>/dev/null")
    if handle then
        for line in handle:lines() do
            local mac = line:match("^Station%s+([0-9A-Fa-f:]+)")
            if mac and #mac == 17 then
                snap.wifi_stations[mac:upper()] = { iface = iface }
            end
        end
        handle:close()
    end
end

-- Bridge FDB.
--
-- Read once into memory and reuse. This used to spawn `brctl showmacs br-lan`
-- twice per tick: once to locate the mesh port, once to collect the MACs behind
-- it.
local mesh_vmac = get_mesh_vmac()
local fdb_rows = {}
local handle = io.popen("brctl showmacs br-lan 2>/dev/null")
if handle then
    for line in handle:lines() do
        local port, mac, is_local = line:match("^%s*(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)")
        if port and mac then
            fdb_rows[#fdb_rows + 1] = { port = port, mac = mac:upper(), is_local = is_local }
        end
    end
    handle:close()
end

local mesh_port = nil
if mesh_vmac then
    for _, row in ipairs(fdb_rows) do
        if row.is_local == "yes" and row.mac == mesh_vmac then
            mesh_port = row.port
            break
        end
    end
end
if mesh_port then
    for _, row in ipairs(fdb_rows) do
        if row.port == mesh_port and row.is_local == "no" then
            snap.fdb_macs[row.mac] = true
        end
    end
end

-- Merge pushed reports from sub-nodes (via POST /api/report_sub)
-- Then refresh from the nodes themselves.
local known_peers = {}

local function merge_peer_data(rep)
    for lease_mac, lease_info in pairs(rep.dhcp_leases or {}) do
        if not snap.dhcp_leases[lease_mac] then
            snap.dhcp_leases[lease_mac] = lease_info
        end
    end
    for arp_mac, arp_ip in pairs(rep.arp or {}) do
        if not snap.arp[arp_mac] then
            snap.arp[arp_mac] = arp_ip
        end
    end
    for dev_mac, dev_info in pairs(rep.devices or {}) do
        if not snap.devices[dev_mac] then
            snap.devices[dev_mac] = dev_info
        end
    end
end

-- Step 1: reports the nodes pushed here themselves.
local now_ts = os.time()
local cf = io.open("/tmp/dm_child_reports.json", "r")
if cf then
    local ok, pushed = pcall(json.parse, cf:read("*a"))
    cf:close()
    if ok and type(pushed) == "table" then
        for node_mac, report in pairs(pushed) do
            -- Skip reports from nodes that stopped pushing. The file is only
            -- ever cleared by a reboot, so without this a node that was
            -- unplugged, reset or re-flashed kept its whole device list alive
            -- on the master forever. Mirrors the expiry api_report_sub applies.
            local ts = type(report) == "table" and tonumber(report.ts) or nil
            if ts and (now_ts - ts) <= REPORT_TTL then
                known_peers[node_mac] = report
                merge_peer_data(report)
            end
        end
    end
end

-- Step 2: poll the nodes themselves.
--
-- Candidates are the hosts that actually pushed a report - their node_ip
-- arrives with it - and NOT every MAC seen on the mesh bridge port.
--
-- This used to loop over snap.fdb_macs: every non-local MAC reachable over the
-- mesh, which in a bridged mesh is every client behind every sub node. The
-- master then curled each phone, laptop and printer once a minute, serially,
-- with --connect-timeout 2 --max-time 4, hoping one of them would answer with
-- dm_snapshot.json. Almost none can: they do not run this plugin. With a few
-- dozen clients the loop outlived its own 60s cron slot and the next tick
-- started on top of it.
--
-- The FDB list survives as a cold-start fallback only: a master that has not
-- received any push yet would otherwise never learn its nodes exist. It is
-- capped, requests run in parallel so the step costs one timeout in total, and
-- a node that keeps failing is backed off instead of being retried every tick.
local MAX_FDB_FALLBACK = 4
local POLL_FAIL_FILE = "/tmp/dm_peer_poll.json"
local POLL_BACKOFF_AFTER = 3      -- consecutive failures before backing off
local POLL_BACKOFF_SEC = 1800     -- how long to leave a dead peer alone

local targets = {}
for node_mac, rep in pairs(known_peers) do
    if type(rep) == "table" and is_valid_ipv4(rep.node_ip) then
        targets[rep.node_ip] = node_mac
    end
end

if not next(targets) then
    local n = 0
    for mac in pairs(snap.fdb_macs) do
        if n >= MAX_FDB_FALLBACK then break end
        local ip = snap.arp[mac] or (snap.dhcp_leases[mac] and snap.dhcp_leases[mac].ip)
        if is_valid_ipv4(ip) and not targets[ip] then
            targets[ip] = mac
            n = n + 1
        end
    end
end

local poll_state = {}
local pf = io.open(POLL_FAIL_FILE, "r")
if pf then
    local ok, st = pcall(json.parse, pf:read("*a"))
    pf:close()
    if ok and type(st) == "table" then poll_state = st end
end

local queue = {}
for ip, mac in pairs(targets) do
    local st = poll_state[ip]
    local until_ts = type(st) == "table" and tonumber(st.until_ts) or nil
    if not (until_ts and now_ts < until_ts) then
        queue[#queue + 1] = { ip = ip, mac = mac }
    end
end

if #queue > 0 then
    -- Unique per run: a manual invocation must not rm -rf the results a
    -- still-running cron instance is about to read.
    local dir = string.format("/tmp/dm_poll_%d_%d", now_ts, math.floor((os.clock() * 1000) % 100000))
    local cmds = {}
    for i, t in ipairs(queue) do
        cmds[#cmds + 1] = string.format(
            "curl -s --connect-timeout 2 --max-time 5 'http://%s/luci-static/resources/dm_snapshot.json' > '%s/%d.json' 2>/dev/null",
            t.ip, dir, i)
    end
    os.execute("mkdir -p '" .. dir .. "'")
    -- All requests at once, then wait for the batch: with N peers this costs
    -- one --max-time, not N.
    os.execute("( " .. table.concat(cmds, " & ") .. " & wait ) 2>/dev/null")

    for i, t in ipairs(queue) do
        local raw = nil
        local rf = io.open(dir .. "/" .. i .. ".json", "r")
        if rf then
            raw = rf:read("*a")
            rf:close()
        end
        local ok, pr = false, nil
        if raw and raw ~= "" then
            ok, pr = pcall(json.parse, raw)
        end

        if ok and type(pr) == "table" and pr.wifi_stations then
            known_peers[t.mac] = {
                ts = now_ts,
                stations = pr.wifi_stations or {},
                dhcp_leases = pr.dhcp_leases or {},
                arp = pr.arp or {},
                devices = pr.devices or {},
                node_ip = t.ip
            }
            merge_peer_data(pr)
            poll_state[t.ip] = nil
        else
            local st = type(poll_state[t.ip]) == "table" and poll_state[t.ip] or { fails = 0 }
            st.fails = (tonumber(st.fails) or 0) + 1
            if st.fails >= POLL_BACKOFF_AFTER then
                st.until_ts = now_ts + POLL_BACKOFF_SEC
                st.fails = 0
            end
            poll_state[t.ip] = st
        end
    end
    os.execute("rm -rf '" .. dir .. "'")
end

local wf = io.open(POLL_FAIL_FILE .. ".tmp", "w")
if wf then
    wf:write(json.stringify(poll_state))
    wf:close()
    os.rename(POLL_FAIL_FILE .. ".tmp", POLL_FAIL_FILE)
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
-- ip neigh: kernel-confirmed neighbours (every state except the "no answer"
-- ones).
--
-- NOTE: this loop was dead code on OpenWrt. It uses a bare `ip neigh show`, and
-- BusyBox then prints the "dev <ifname>" field between the address and lladdr -
-- see print_neigh() in networking/libiproute/ipneigh.c:
--     if (!G_filter.index && r->ndm_ifindex)
--         printf("dev %s ", ll_index_to_name(r->ndm_ifindex));
-- The pattern required the address and lladdr to be adjacent, so it never
-- matched a single line. (It would have worked under iproute2 only if the dev
-- field were absent, which it is not.) A bare dump can additionally carry
-- "router"/"proxy" flags and "used <a>/<b>/<c>" cache info before the state, so
-- take the MAC from the lladdr field and scan for a known state token instead
-- of assuming a column.
local NUD_STATES = {
	INCOMPLETE = true, REACHABLE = true, STALE = true, DELAY = true,
	PROBE = true, FAILED = true, NOARP = true, PERMANENT = true,
}
local nh = io.popen("ip neigh show 2>/dev/null")
if nh then
    for line in nh:lines() do
        local nip, rest = line:match("^(%d+%.%d+%.%d+%.%d+)%s+(.*)$")
        local nmac = rest and rest:match("lladdr%s+([0-9a-fA-F:]+)")
        if nip and nmac then
            local nstate = nil
            for word in rest:gmatch("%u+") do
                if NUD_STATES[word] then
                    nstate = word
                    break
                end
            end
            if nstate ~= nil and nstate ~= "FAILED" and nstate ~= "INCOMPLETE" then
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

-- Write snapshot.
--
-- Both copies are written to a temp file and renamed into place: a sub node
-- polls /luci-static/resources/dm_snapshot.json with curl every minute, and a
-- plain truncate-then-write let it read a half-written file (json.parse then
-- fails and the sub node sees a snapshot error for a whole cycle).
local function write_atomic(path, data)
    local tmp = path .. ".tmp"
    local fh = io.open(tmp, "w")
    if not fh then return false end
    fh:write(data)
    fh:close()
    return os.rename(tmp, path)
end

local json_str = json.stringify(snap)
write_atomic(SNAPSHOT, json_str)
-- The web-visible copy is a SYMLINK to /tmp/dm_snapshot.json, created by
-- /etc/init.d/devicemaster (dm_setup_web_links) - it is deliberately NOT
-- written here any more. /www lives on the overlay filesystem, so writing it
-- once a minute was 1440 flash writes per node per day, forever: twenty times
-- more often than the 12h session flush that this very cron file documents as
-- the flash-wear-avoidance policy. /tmp is tmpfs (RAM), and uhttpd serves the
-- symlink transparently.
