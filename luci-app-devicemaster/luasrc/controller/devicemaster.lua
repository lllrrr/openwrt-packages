--[[
LuCI DeviceMaster - Real-time Device Controller
Architecture: Event-driven + On-demand
  - Archive Path (UCI): Device profiles stored permanently, triggered by DHCP events
  - Status Path (RAM): Online status read from /proc/net/arp on each API call
  - Interaction Path (Web): Frontend polls only when tab is active
]]--

module("luci.controller.devicemaster", package.seeall)

local json = require("luci.jsonc")
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")

-- Input validation helpers (prevent command injection)
local function is_valid_mac(mac)
    return mac and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$")
end

local function is_valid_ip(ip)
    return ip and ip:match("^%d+%.%d+%.%d+%.%d+$")
end

local function is_valid_rate(rate)
    return rate and rate:match("^%d+[kmgb]?bit$")
end

local function is_valid_uci_id(id)
    return id and id:match("^[A-Za-z0-9_%-]+$")
end

local function is_valid_remote_api(api)
    return api == "maclookup" or api == "macvendors"
end

local function get_remote_api()
    local api = uci:get("devicemaster", "settings", "remote_api") or "maclookup"
    if not is_valid_remote_api(api) then
        api = "maclookup"
    end
    return api
end

function index()
    entry({"admin", "network", "devicemaster"}, firstchild(), "设备管理", 60)
    entry({"admin", "network", "devicemaster", "devices"}, template("devicemaster/devices"), "网络设备", 10)
    entry({"admin", "network", "devicemaster", "groups"}, view("devicemaster/groups"), "分组配置", 15)
    entry({"admin", "network", "devicemaster", "settings"}, cbi("devicemaster/settings"), "OUI管理", 20)

    -- API endpoints
    entry({"admin", "network", "devicemaster", "api", "status"}, call("api_status"))
    entry({"admin", "network", "devicemaster", "api", "set_name"}, call("api_set_name"))
    entry({"admin", "network", "devicemaster", "api", "set_group"}, call("api_set_group"))
    entry({"admin", "network", "devicemaster", "api", "block"}, call("api_block"))
    entry({"admin", "network", "devicemaster", "api", "unblock"}, call("api_unblock"))
    entry({"admin", "network", "devicemaster", "api", "limit"}, call("api_limit"))
    entry({"admin", "network", "devicemaster", "api", "unlimit"}, call("api_unlimit"))
    entry({"admin", "network", "devicemaster", "api", "delete_device"}, call("api_delete_device"))
    entry({"admin", "network", "devicemaster", "api", "get_groups"}, call("api_get_groups"))
    entry({"admin", "network", "devicemaster", "api", "create_group"}, call("api_create_group"))
    entry({"admin", "network", "devicemaster", "api", "delete_group"}, call("api_delete_group"))
    entry({"admin", "network", "devicemaster", "api", "snapshot"}, call("api_snapshot"))
    entry({"admin", "network", "devicemaster", "api", "report"}, call("api_report"))
    local report_sub_node = entry({"admin", "network", "devicemaster", "api", "report_sub"}, call("api_report_sub"))
    report_sub_node.sysauth = false
    report_sub_node.leaf = true
    entry({"admin", "network", "devicemaster", "api", "scan_network"}, call("api_scan_network"))
    entry({"admin", "network", "devicemaster", "api", "discover"}, call("api_discover"))
    entry({"admin", "network", "devicemaster", "api", "set_mode"}, call("api_set_mode"))
    entry({"admin", "network", "devicemaster", "api", "merge_devices"}, call("api_merge_devices"))
    entry({"admin", "network", "devicemaster", "api", "unmerge_device"}, call("api_unmerge_device"))

    -- OUI Database management
    entry({"admin", "network", "devicemaster", "download_oui"}, call("action_download_oui"))
    entry({"admin", "network", "devicemaster", "test_api"}, call("action_test_api"))
    entry({"admin", "network", "devicemaster", "api", "test_api"}, call("api_test_api"))
end

-- Helper: JSON response
local function json_response(data)
    luci.http.prepare_content("application/json")
    luci.http.write(json.stringify(data))
end

local function log_msg(message)
    sys.exec("logger -t devicemaster '" .. tostring(message):gsub("'", "'\\''") .. "'")
end

-- Helper: Execute shell command safely
local function exec_safe(cmd)
    local result = sys.exec(cmd .. " 2>/dev/null")
    return result:gsub("\n$", "")
end

local function shell_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function cleanup_deleted_device_identity(mac)
    if not is_valid_mac(mac) then return end
    local mac_lower = mac:lower()
    local changed_dhcp = false

    while true do
        local deleted = false
        local idx = 0
        while true do
            local host_mac = uci:get("dhcp", "@host[" .. idx .. "]", "mac")
            if not host_mac then break end
            if host_mac:lower() == mac_lower then
                uci:delete("dhcp", "@host[" .. idx .. "]")
                changed_dhcp = true
                deleted = true
                break
            end
            idx = idx + 1
        end
        if not deleted then break end
    end

    if changed_dhcp then
        local ok, err = uci:commit("dhcp")
        if not ok then log_msg("WARN: dhcp cleanup commit failed: " .. tostring(err)) end
    end

    local cmd = "awk -v m=" .. shell_quote(mac_lower) .. " '{if (tolower($2)==m) $4=\"*\"; print}' /tmp/dhcp.leases > /tmp/dhcp.leases.devicemaster && mv /tmp/dhcp.leases.devicemaster /tmp/dhcp.leases"
    sys.call(cmd .. " 2>/dev/null")
end

-- Helper: Get MAC address of wl1-mesh0 virtual interface
local function get_mesh_vmac()
    local mif = sys.exec("ip link show dev wl1-mesh0 2>/dev/null | grep 'link/ether' | awk '{print $2}'")
    if mif and mif ~= "" then
        return mif:upper():match("^([0-9A-Fa-f:]+)")
    end
    return nil
end

-- Helper: Get all local interface MACs + bridge local FDB entries
-- These are the router's own MACs and should not appear in device list
local function get_local_macs()
    local macs = {}
    -- Interface MACs from ip link
    local out = sys.exec("ip link show 2>/dev/null | grep 'link/ether' | awk '{print $2}'")
    if out and out ~= "" then
        for mac in out:gmatch("([0-9A-Fa-f:]+)") do
            macs[mac:upper()] = true
        end
    end
    -- Bridge local FDB entries (catches hardware virtual MACs)
    local fdb = sys.exec("brctl showmacs br-lan 2>/dev/null")
    if fdb and fdb ~= "" then
        for line in fdb:gmatch("[^\r\n]+") do
            local mac = line:match("^%s*%d+%s+([0-9a-fA-F:]+)%s+yes")
            if mac then macs[mac:upper()] = true end
        end
    end
    return macs
end

-- Helper: Dynamically discover wireless AP interfaces
local function get_ap_ifaces()
    local ifaces = {}
    local out = sys.exec("ls /sys/class/net/ 2>/dev/null | grep '^wl'")
    if out and out ~= "" then
        for iface in out:gmatch("%S+") do
            if not iface:match("mesh") then
                table.insert(ifaces, iface)
            end
        end
    end
    if #ifaces == 0 then
        return {"wl0-ap0", "wl1-ap0", "wl0-ap1", "wl1-ap1"}
    end
    return ifaces
end

-- Helper: Generate version string for response cache
local function get_version()
    return "v" .. os.date("%Y%m%d%H%M")
end

-- Helper: Get WiFi station list (devices directly connected to this router)
-- Returns: { ["MAC"] = true }
local function get_wifi_stations()
    local stations = {}
    for _, iface in ipairs(get_ap_ifaces()) do
        local output = sys.exec("iwinfo " .. iface .. " assoclist 2>/dev/null")
        if output then
            for word in output:gmatch("%S+") do
                if #word == 17 and word:match("^[0-9A-Fa-f:]+$") then
                    stations[word:upper()] = true
                end
            end
        end
    end
    return stations
end

-- Helper: Get DHCP leases as { mac = { ip, hostname } }
local function get_dhcp_leases()
    local leases = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if not f then return leases end
    for line in f:lines() do
        local ts, mac, ip, hostname = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac and ip then
            leases[mac:upper()] = { ip = ip, hostname = hostname }
        end
    end
    f:close()
    return leases
end

-- Helper: Get uplink info from Bandix API
-- Returns: { ["MAC"] = "uplink" } where uplink is "wl1-ap0", "wl1-mesh0", etc.
local function get_bandix_uplink()
    local uplinks = {}
    
    -- Check if bandix is running
    local result = sys.exec("pidof bandix 2>/dev/null")
    if not result or result:gsub("\n", "") == "" then
        return uplinks
    end
    
    -- Get port from UCI
    local port = uci:get("bandix", "general", "port") or "8686"
    
    -- Fetch device list from Bandix API
    local response = sys.exec("curl -s --connect-timeout 1 --max-time 3 'http://127.0.0.1:" .. port .. "/api/traffic/devices' 2>/dev/null")
    if not response or response == "" or not response:find('"status":"success"') then
        return uplinks
    end
    
    -- Parse JSON in Lua (avoid spawning per-device shell subprocesses)
    local ok, data = pcall(json.parse, response)
    if not ok or type(data) ~= "table" or type(data.data) ~= "table" then
        return uplinks
    end
    local devices = data.data.d
    if type(devices) ~= "table" then
        return uplinks
    end
    
    for _, dev in ipairs(devices) do
        local mac = dev.mac
        if mac and mac ~= "" then
            uplinks[mac:upper()] = dev.uplink or ""
        end
    end
    
    return uplinks
end

-- Helper: Get mesh station list (mesh nodes connected via wl1-mesh0)
-- Returns: { ["MAC"] = true }
local function get_mesh_stations()
    local stations = {}
    local output = sys.exec("iw dev wl1-mesh0 station dump 2>/dev/null")
    if output then
        for line in output:gmatch("[^\r\n]+") do
            local mac = line:match("^Station ([0-9A-Fa-f:]+)")
            if mac then
                stations[mac:upper()] = true
            end
        end
    end
    return stations
end

-- ============================================================
-- Role detection: determine if this device is master/sub/client
-- ============================================================
-- Returns: { role = "master"|"sub"|"client", master_ip, subnet, iface }
local function detect_role()
    local role = "client"
    local master_ip = ""
    local subnet = ""
    local iface = "br-lan"
    
    -- Check if mesh interface exists
    local mesh = sys.exec("iw dev wl1-mesh0 info 2>/dev/null")
    if not mesh or mesh == "" then
        return { role = role, master_ip = master_ip, subnet = subnet, iface = iface }
    end
    
    -- Has mesh interface: determine master vs sub by DHCP service presence
    -- Note: pidof dnsmasq is unreliable because sub-nodes also run dnsmasq for DNS
    -- Use dhcp.lan.ignore to distinguish: ignore=1 means DHCP disabled → sub
    -- Use gsub to strip trailing newline from sys.exec output
    local dhcp_ignore = sys.exec("uci -q get dhcp.lan.ignore 2>/dev/null"):gsub("%s+$", "")
    if dhcp_ignore ~= "1" then
        role = "master"
    else
        role = "sub"
        -- Infer master IP from default gateway
        -- sys.exec output includes trailing newline, must strip before match
        local gw = sys.exec("ip route show default 2>/dev/null | awk '{print $3}' | head -1"):gsub("%s+$", "")
        if gw and gw:match("^%d+%.%d+%.%d+%.%d+$") then
            master_ip = gw
        end
    end
    
    -- Infer subnet
    local rt = sys.exec("ip route show dev " .. iface .. " 2>/dev/null | awk '{print $1}' | head -1")
    if rt then subnet = rt end
    
    return { role = role, master_ip = master_ip, subnet = subnet, iface = iface }
end

-- ============================================================
-- Create full device snapshot (for sub-node consumption)
-- Written to /tmp/dm_snapshot.json, refreshed every 60s
-- ============================================================
local function create_snapshot()
    local role_info = detect_role()
    
    -- Only master creates snapshot
    local snap = {
        _ts = os.time(),
        role = role_info.role,
        dhcp_leases = {},
        arp = {},
        wifi_stations = {},
        fdb_macs = {},
        child_reports = {}  -- reported by sub-nodes via POST /api/report
    }
    
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
        f:read("*l")
        for line in f:lines() do
            local ip, hw_type, flags, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if mac and mac ~= "00:00:00:00:00:00" and flags ~= "0x0" then
                snap.arp[mac:upper()] = ip
            end
        end
        f:close()
    end
    
    -- WiFi stations
    for _, iface in ipairs(get_ap_ifaces()) do
        local out = sys.exec("iwinfo " .. iface .. " assoclist 2>/dev/null")
        if out then
            for word in out:gmatch("%S+") do
                if #word == 17 and word:match("^[0-9A-Fa-f:]+$") then
                    snap.wifi_stations[word:upper()] = { iface = iface }
                end
            end
        end
    end
    
    -- Bridge FDB non-local MACs
    local mesh_vmac = get_mesh_vmac()
    local fdb = sys.exec("brctl showmacs br-lan 2>/dev/null")
    if fdb and fdb ~= "" then
        local mesh_port = nil
        for line in fdb:gmatch("[^\r\n]+") do
            local port, mac, is_local = line:match("^%s*(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)")
            if port and mac and is_local == "yes" and mesh_vmac and mac:upper() == mesh_vmac then
                mesh_port = port; break
            end
        end
        if mesh_port then
            for line in fdb:gmatch("[^\r\n]+") do
                local port, mac, is_local = line:match("^%s*(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)")
                if port and port == mesh_port and mac and is_local == "no" then
                    snap.fdb_macs[mac:upper()] = true
                end
            end
        end
    end
    
    -- Merge child_reports from file
    local cf = io.open("/tmp/dm_child_reports.json", "r")
    if cf then
        local ok, cr = pcall(json.parse, cf:read("*a"))
        cf:close()
        if ok and type(cr) == "table" then
            snap.child_reports = cr
        end
    end
    
    -- Device profiles from master UCI (for sub-node enrichment)
    snap.devices = {}
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
    
    -- Write snapshot
    local tmp = "/tmp/dm_snapshot.json.tmp"
    local sf = io.open(tmp, "w")
    if sf then
        sf:write(json.stringify(snap))
        sf:close()
        os.rename(tmp, "/tmp/dm_snapshot.json")  -- atomic
    end
end

-- ============================================================
-- Snapshot API: GET - sub nodes pull master data
-- ============================================================
function api_snapshot()
    -- Read the pre-written snapshot file
    local f = io.open("/tmp/dm_snapshot.json", "r")
    if f then
        local data = f:read("*a")
        f:close()
        json_response(json.parse(data) or { error = "parse failed" })
    else
        json_response({ error = "snapshot not available" })
    end
end

-- ============================================================
-- Report API: POST - sub nodes push their local stations
-- ============================================================
function api_report()
    local raw = luci.http.content()
    if not raw or raw == "" then
        json_response({ success = false, error = "no data" })
        return
    end
    local ok, data = pcall(json.parse, raw)
    if not ok or type(data) ~= "table" then
        json_response({ success = false, error = "invalid json" })
        return
    end
    
    -- Validate required fields
    if not data.node_mac or not data.stations then
        json_response({ success = false, error = "missing node_mac or stations" })
        return
    end
    
    -- Read existing child_reports, merge this node's report
    local reports = {}
    local cf = io.open("/tmp/dm_child_reports.json", "r")
    if cf then
        local ok2, existing = pcall(json.parse, cf:read("*a"))
        cf:close()
        if ok2 and type(existing) == "table" then
            reports = existing
        end
    end
    
    reports[data.node_mac:upper()] = {
        ts = os.time(),
        stations = data.stations,
        iface = data.iface or ""
    }
    
    local wf = io.open("/tmp/dm_child_reports.json", "w")
    if wf then
        wf:write(json.stringify(reports))
        wf:close()
    end
    
    json_response({ success = true })
end

-- Unauthenticated report endpoint for sub-node push (mesh internal communication)
function api_report_sub()
    local raw = luci.http.content()
    if not raw or raw == "" then
        json_response({ success = false, error = "no data" })
        return
    end
    local ok, data = pcall(json.parse, raw)
    if not ok or type(data) ~= "table" then
        json_response({ success = false, error = "invalid json" })
        return
    end
    
    if not data.node_mac or not is_valid_mac(data.node_mac) then
        json_response({ success = false, error = "missing node_mac" })
        return
    end
    
    local reports = {}
    -- Atomic read-merge-write (use lock file)
    local lock = "/tmp/dm_child_reports.lock"
    local locked = false
    for i = 1, 10 do
        if sys.call("mkdir '" .. lock .. "' 2>/dev/null") == 0 then
            locked = true
            break
        end
        sys.exec("usleep 100000 2>/dev/null")  -- wait 100ms
    end
    if not locked then
        json_response({success = false, error = "Could not acquire lock"})
        return
    end

    local cf = io.open("/tmp/dm_child_reports.json", "r")
    if cf then
        local ok2, existing = pcall(json.parse, cf:read("*a"))
        cf:close()
        if ok2 and type(existing) == "table" then
            reports = existing
        end
    end

    reports[data.node_mac:upper()] = {
        ts = os.time(),
        stations = data.stations or {},
        dhcp_leases = data.dhcp_leases or {},
        arp = data.arp or {},
        devices = data.devices or {},
        iface = data.iface or ""
    }

    -- Atomic write: temp file + rename
    local tmp = "/tmp/dm_child_reports.json.tmp"
    local wf = io.open(tmp, "w")
    if wf then
        wf:write(json.stringify(reports))
        wf:close()
        os.rename(tmp, "/tmp/dm_child_reports.json")  -- atomic
    end

    sys.call("rmdir '" .. lock .. "' 2>/dev/null")  -- release lock
    
    json_response({ success = true })
end

-- Helper: Identify mesh nodes and children
-- Mesh node sources (priority order):
--   1. iw station dump MAC matches a UCI device
--   2. Bridge FDB: non-local MACs on wl1-mesh0 port
--        Mesh node = type=network device whose OUI matches main router
--        Others on same port = mesh_children
local function identify_topology(bandix_uplink, wifi_stations, mesh_stations, dhcp_leases)
    local mesh_nodes = {}
    local mesh_children = {}
    local mesh_port  -- cached wl1-mesh0 bridge port number
    
    local function find_uci_device(mac)
        local result = nil
        uci:foreach("devicemaster", "device", function(s)
            if s.mac and s.mac:upper() == mac then
                result = s
                return false
            end
        end)
        return result
    end
    
    -- Get main router OUI from br-lan MAC (to identify same-brand mesh node)
    local br_out = sys.exec("ip link show dev br-lan 2>/dev/null | grep 'link/ether' | awk '{print $2}'")
    local router_oui = br_out and br_out:upper():match("^([0-9A-F]+:[0-9A-F]+:[0-9A-F]+)") or nil
    
    -- Parse bridge FDB to find wl1-mesh0 port and collect mesh-connected MACs
    local fdb_macs = {}  -- non-local MACs on the mesh port
    local mesh_vmac = get_mesh_vmac()
    if router_oui and mesh_vmac then
        local fdb = sys.exec("brctl showmacs br-lan 2>/dev/null")
        if fdb and fdb ~= "" then
            for line in fdb:gmatch("[^\r\n]+") do
                local port, mac, is_local = line:match("^%s*(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)")
                if port and mac then
                    local mac_u = mac:upper()
                    if is_local == "yes" and mac_u == mesh_vmac then
                        mesh_port = port
                    end
                end
            end
            if mesh_port then
                for line in fdb:gmatch("[^\r\n]+") do
                    local port, mac, is_local = line:match("^%s*(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)")
                    if port and port == mesh_port and mac and is_local == "no" then
                        table.insert(fdb_macs, mac:upper())
                    end
                end
            end
        end
    end
    
    -- No mesh stations → no mesh topology
    if not next(mesh_stations) then
        return mesh_nodes, mesh_children
    end
    
    local lan_prefix = sys.exec("ip route show dev br-lan 2>/dev/null | awk '{print $1}' | cut -d/ -f1"):match("^(%d+%.%d+%.%d+)")
    if not lan_prefix then
        return mesh_nodes, mesh_children
    end
    
    -- Step 1: mesh nodes from mesh station dump (matches real UCI mesh peers)
    for mac, _ in pairs(mesh_stations) do
        if not mesh_nodes[mac] then
            local uci_dev = find_uci_device(mac)
            if uci_dev then
                mesh_nodes[mac] = {
                    ip = uci_dev.last_ip or "",
                    hostname = uci_dev.hostname or "",
                    child_macs = {},
                    mesh_connected = true
                }
            end
        end
    end
    
    -- Step 2: bridge FDB — identify mesh nodes + children from wl1-mesh0 port
    if not next(mesh_nodes) and next(fdb_macs) and router_oui then
        -- 2a: mesh node = type=network device whose OUI matches the main router
        for _, mac in ipairs(fdb_macs) do
            local mac_oui = mac:match("^([0-9A-F]+:[0-9A-F]+:[0-9A-F]+)")
            if mac_oui and mac_oui == router_oui then
                local uci_dev = find_uci_device(mac)
                if uci_dev then
                    mesh_nodes[mac] = {
                        ip = uci_dev.last_ip or "",
                        hostname = uci_dev.hostname or "",
                        child_macs = {},
                        mesh_connected = true
                    }
                    break
                end
            end
        end
    end
    
    -- 2b: remaining MACs on mesh port → mesh_children (only when mesh nodes exist)
    if next(mesh_nodes) then
        for _, mac in ipairs(fdb_macs) do
            if not mesh_nodes[mac] and not wifi_stations[mac] then
                local uci_dev = find_uci_device(mac)
                if uci_dev then
                    mesh_children[mac] = {
                        ip = uci_dev.last_ip or "",
                        hostname = uci_dev.hostname or "",
                        parent_mac = nil
                    }
                end
            end
        end
        
        -- 2c: DHCP lease MACs on LAN subnet (not already identified) → mesh_children
        for mac, info in pairs(dhcp_leases) do
            if not wifi_stations[mac] and not mesh_nodes[mac] and not mesh_children[mac] then
                local device_prefix = info.ip:match("^(%d+%.%d+%.%d+)")
                if device_prefix and device_prefix == lan_prefix then
                    mesh_children[mac] = {
                        ip = info.ip,
                        hostname = info.hostname or "",
                        parent_mac = nil
                    }
                end
            end
        end
    end
    
    return mesh_nodes, mesh_children
end

-- Helper: Get device online status and IPs (Topology-aware)
-- Returns: online_macs, all_arp, wifi_stations, mesh_info
local function get_arp_online()
    local online = {}
    local all_arp = {}
    local probe_macs = {}

    -- Get basic data
    local wifi_stations = get_wifi_stations()
    local mesh_stations = get_mesh_stations()
    local dhcp_leases = get_dhcp_leases()
    local bandix_uplink = get_bandix_uplink()
    
    -- Identify topology (uses Bandix if available, otherwise falls back)
    local mesh_nodes, mesh_children = identify_topology(bandix_uplink, wifi_stations, mesh_stations, dhcp_leases)

    -- Read /proc/net/arp for all known device IPs
    local f = io.open("/proc/net/arp", "r")
    if f then
        local header = f:read("*l")
        if header then
            for line in f:lines() do
                local ip, hw_type, flags, mac = line:match(
                    "^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)"
                )
                if mac and mac ~= "00:00:00:00:00:00" and flags ~= "0x0" then
                    all_arp[mac:upper()] = ip
                end
            end
        end
        f:close()
    end

    -- Tier 1: WiFi stations are always online
    -- Try to find IP from ARP, DHCP, or ip neigh (any state)
    local neigh_by_mac = {}
    local neigh_raw = sys.exec("ip neigh show dev br-lan 2>/dev/null")
    if neigh_raw and neigh_raw ~= "" then
        for line in neigh_raw:gmatch("[^\r\n]+") do
            local nip, nmac = line:match("^(%d+%.%d+%.%d+%.%d+)%s+lladdr%s+([0-9a-fA-F:]+)")
            if nip and nmac then
                neigh_by_mac[nmac:upper()] = nip
            end
        end
    end
    
    -- Build IP→MAC mapping from DHCP (source of truth for IP assignments)
    -- This handles cases where sub-routers (like JI-weixing) assign IPs to downstream devices
    -- and the main router only sees the sub-router's MAC in ARP
    local dhcp_ip_to_mac = {}
    for mac, info in pairs(dhcp_leases) do
        if info.ip and info.ip ~= "" then
            dhcp_ip_to_mac[info.ip] = mac
        end
    end
    
    for mac, _ in pairs(wifi_stations) do
        online[mac] = all_arp[mac] or (dhcp_leases[mac] and dhcp_leases[mac].ip) or neigh_by_mac[mac] or ""
    end

    -- Tier 2: ip neigh REACHABLE/PERMANENT
    -- Skip ARP entries where IP is already claimed by DHCP for a different MAC
    local output = sys.exec("ip neigh show dev br-lan 2>/dev/null")
    if output and output ~= "" then
        for line in output:gmatch("[^\r\n]+") do
            local ip, mac, state = line:match(
                "^(%d+%.%d+%.%d+%.%d+)%s+lladdr%s+([0-9a-fA-F:]+)%s+(%S+)"
            )
            if mac and state then
                state = state:upper()
                mac = mac:upper()
                if state == "REACHABLE" or state == "PERMANENT" or state == "STALE" or state == "DELAY" then
                    -- Skip if this IP is claimed by DHCP for a different MAC
                    -- (indicates sub-router is NATting or doing DHCP for downstream devices)
                    local dhcp_owner = dhcp_ip_to_mac[ip]
                    if dhcp_owner and dhcp_owner ~= mac then
                        -- Skip this ARP entry, use DHCP's mapping instead
                    else
                        online[mac] = ip
                    end
                end
            end
        end
    end

    -- Tier 3: IoT devices with DHCP leases are always online (no ARP/ping needed)
    local iot_macs = {}
    uci:foreach("devicemaster", "device", function(s)
        if s.mac and s.type == "iot" then
            iot_macs[s.mac:upper()] = true
        end
    end)
    for mac, info in pairs(dhcp_leases) do
        if not online[mac] and iot_macs[mac] then
            online[mac] = info.ip
        end
    end

    -- Tier 4: Ping probe for non-WiFi devices
    -- Skip ARP entries where IP is already claimed by DHCP for a different MAC
    for mac, ip in pairs(all_arp) do
        if not online[mac] and not wifi_stations[mac] and is_valid_ip(ip) then
            local dhcp_owner = dhcp_ip_to_mac[ip]
            if not (dhcp_owner and dhcp_owner ~= mac) then
                probe_macs[mac] = ip
            end
        end
    end

    -- Ping probe
    for mac, ip in pairs(probe_macs) do
        if not online[mac] and is_valid_ip(ip) then
            local ping_result = sys.exec("ping -c 1 -W 1 " .. ip .. " 2>/dev/null && echo OK || echo FAIL")
            if ping_result:match("OK") then
                online[mac] = ip
            end
        end
    end

    -- Special: Mesh node online if any child is online
    -- A mesh_child is considered online if:
    --   1. It's in the online table (ip neigh REACHABLE), OR
    --   2. It has a DHCP lease (recently active on the network)
    -- This prevents the mesh node from flickering offline when
    -- ip neigh entries briefly go STALE between probes.
    local node_count = 0
    local first_node_mac = nil
    for node_mac, node_info in pairs(mesh_nodes) do
        node_count = node_count + 1
        if not first_node_mac then first_node_mac = node_mac end
    end
    
    -- Helper: check if a mesh_child is online
    local function is_child_online(mac)
        if online[mac] then return true end
        if all_arp[mac] then return true end
        if dhcp_leases[mac] then return true end
        return false
    end
    
    -- If only 1 mesh node, all non-direct devices belong to it
    if node_count == 1 and first_node_mac then
        local has_online_child = false
        -- mesh_children are non-direct devices
        for child_mac, child_info in pairs(mesh_children) do
            child_info.parent_mac = first_node_mac
            table.insert(mesh_nodes[first_node_mac].child_macs, child_mac)
            if is_child_online(child_mac) then
                has_online_child = true
            end
        end
        -- If any child is online, node is online
        if has_online_child then
            online[first_node_mac] = mesh_nodes[first_node_mac].ip
        end
    elseif node_count > 1 then
        -- Multiple mesh nodes: link children based on online status
        for node_mac, node_info in pairs(mesh_nodes) do
            local has_online_child = false
            for child_mac, child_info in pairs(mesh_children) do
                if is_child_online(child_mac) and not child_info.parent_mac then
                    has_online_child = true
                    child_info.parent_mac = node_mac
                    table.insert(node_info.child_macs, child_mac)
                end
            end
            if has_online_child then
                online[node_mac] = node_info.ip
            end
        end
    end

    -- Fallback
    if next(online) == nil then
        online = all_arp
    end

    local mesh_info = {
        nodes = mesh_nodes,
        children = mesh_children
    }

    return online, all_arp, wifi_stations, mesh_info
end

-- Helper: Get DHCP leases as { mac = hostname }
local function get_dhcp_hostnames()
    local hostnames = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if not f then return hostnames end

    for line in f:lines() do
        local ts, mac, ip, hostname, clientid = line:match(
            "^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)"
        )
        if mac and hostname and hostname ~= "*" then
            hostnames[mac:upper()] = hostname
        end
    end
    f:close()
    return hostnames
end

-- Helper: Get all MACs in DHCP leases (regardless of hostname)
local function get_dhcp_macs()
    local macs = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if not f then return macs end
    for line in f:lines() do
        local ts, mac = line:match("^(%d+)%s+(%S+)")
        if mac then
            macs[mac:upper()] = true
        end
    end
    f:close()
    return macs
end

-- Session data stored in tmpfs (RAM), avoiding Flash writes
local SESSION_FILE = "/var/run/devicemaster/session.json"
-- Probe cache (file-backed to persist across CGI requests)
local PROBE_CACHE_FILE = "/tmp/dm_probe_cache.json"

local function load_probe_cache()
    local f = io.open(PROBE_CACHE_FILE, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if content and content ~= "" then
        local ok, data = pcall(json.parse, content)
        if ok and type(data) == "table" then return data end
    end
    return {}
end

local function save_probe_cache(cache)
    local tmp = PROBE_CACHE_FILE .. ".tmp"
    local sf = io.open(tmp, "w")
    if sf then
        sf:write(json.stringify(cache))
        sf:close()
        os.rename(tmp, PROBE_CACHE_FILE)  -- atomic
    end
end

local function load_session()
    local f = io.open(SESSION_FILE, "r")
    if not f then return { devices = {} } end
    local content = f:read("*all")
    f:close()
    if content and content ~= "" then
        local ok, data = pcall(json.parse, content)
        if ok and data then return data end
    end
    return { devices = {} }
end

local function save_session(data)
    -- Ensure directory exists
    sys.exec("mkdir -p /var/run/devicemaster 2>/dev/null")
    local tmp = SESSION_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
        f:write(json.stringify(data))
        f:close()
        os.rename(tmp, SESSION_FILE)  -- atomic
    end
end

local function merge_session_aliases(session, primary_mac, alias_macs)
    if not session or type(session.devices) ~= "table" then return end
    local primary = session.devices[primary_mac] or {}

    local function min_number(a, b)
        a, b = tonumber(a), tonumber(b)
        if a and b then return math.min(a, b) end
        return a or b
    end

    local function max_number(a, b)
        a, b = tonumber(a), tonumber(b)
        if a and b then return math.max(a, b) end
        return a or b
    end

    primary.total_online_time = tonumber(primary.total_online_time) or 0

    for _, alias in ipairs(alias_macs or {}) do
        local alias_upper = alias:upper()
        if alias_upper ~= primary_mac then
            local alt = session.devices[alias_upper]
            if alt then
                primary.first_seen = min_number(primary.first_seen, alt.first_seen)
                primary.last_seen = max_number(primary.last_seen, alt.last_seen)
                primary.current_session_start = min_number(primary.current_session_start, alt.current_session_start)
                primary.total_online_time = (tonumber(primary.total_online_time) or 0) + (tonumber(alt.total_online_time) or 0)
                session.devices[alias_upper] = nil
            end
        end
    end

    session.devices[primary_mac] = primary
end

-- Response cache: avoid heavy computation on every frontend poll
local response_cache_str = nil
local response_cache_time = 0
local CACHE_TTL = 15

-- ============================================================
-- API: Set device monitor mode (active/idle)
-- Called by frontend when page opens/closes
-- ============================================================
function api_set_mode()
    local mode = luci.http.formvalue("mode") or "idle"
    local f = io.open("/tmp/dm_mode", "w")
    if f then
        f:write(mode)
        f:close()
    end
    -- Also update legacy page_active file for backward compat
    if mode == "active" then
        f = io.open("/tmp/dm_page_active", "w")
        if f then f:write(tostring(os.time())); f:close() end
    end
    json_response({success = true, mode = mode})
end

-- ============================================================
-- API: Merge multiple devices into one (for rotating MAC addresses)
-- POST: primary_mac=xx&secondary_macs=yy,zz
-- Auto-select online MAC as primary
-- ============================================================
function api_merge_devices()
    local primary_mac = luci.http.formvalue("primary_mac") or ""
    local secondary_macs = luci.http.formvalue("secondary_macs") or ""
    
    primary_mac = primary_mac:upper():gsub("-", ":")
    
    if primary_mac == "" or secondary_macs == "" then
        json_response({success = false, error = "Missing parameters"})
        return
    end
    if not is_valid_mac(primary_mac) then
        json_response({success = false, error = "Invalid primary MAC"})
        return
    end
    
    -- Collect all MACs (primary + secondary)
    local all_macs = {primary_mac}
    for mac in secondary_macs:gmatch("[^,]+") do
        mac = mac:upper():gsub("-", ":")
        if not is_valid_mac(mac) then
            json_response({success = false, error = "Invalid secondary MAC: " .. mac})
            return
        end
        if mac ~= primary_mac then
            table.insert(all_macs, mac)
        end
    end
    
    -- Check which MAC is online (via ARP table) and get IP
    local arp_online = {}
    local arp_ip = {}
    local arp_file = io.open("/proc/net/arp", "r")
    if arp_file then
        -- Skip header line
        arp_file:read("*l")
        for line in arp_file:lines() do
            -- ARP format: IP HW Type Flags MAC HW Mask Device
            local ip, flags, mac = line:match("^(%d+%.%d+%.%d+%.%d+)%s+%S+%s+(%S+)%s+([%x%x:%x%x:%x%x:%x%x:%x%x:%x%x])")
            if mac and ip and mac ~= "00:00:00:00:00:00" and flags ~= "0x0" then
                arp_online[mac:upper()] = true
                arp_ip[mac:upper()] = ip
            end
        end
        arp_file:close()
    end
    
    -- Find the online MAC as primary
    local online_mac = nil
    local online_ip = nil
    for _, mac in ipairs(all_macs) do
        if arp_online[mac] then
            online_mac = mac
            online_ip = arp_ip[mac]
            break
        end
    end
    
    -- Keep the user-selected primary as the canonical device record.
    -- The currently online MAC only contributes last_ip/last_seen and becomes an alias.
    local canonical_mac = primary_mac
    
    -- Helper: Check if device exists in UCI
    local function find_device_idx(target_mac)
        local idx = 0
        while true do
            local mac = uci:get("devicemaster", "@device[" .. idx .. "]", "mac")
            if not mac then break end
            if mac:upper() == target_mac then
                return idx
            end
            idx = idx + 1
        end
        return nil
    end
    
    -- Helper: Create new device entry for ARP-only device
    local function create_device_for_mac(new_mac, ip)
        -- Get hostname from DHCP leases
        local hostname = ""
        local dhcp_file = io.open("/tmp/dhcp.leases", "r")
        if dhcp_file then
            for line in dhcp_file:lines() do
                local ts, mac, lease_ip, name = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
                if mac and mac:upper() == new_mac then
                    hostname = name or ""
                    break
                end
            end
            dhcp_file:close()
        end
        
        -- Detect if randomized MAC (LAA - Locally Administered Address)
        local first_byte = tonumber(new_mac:sub(1,2), 16)
        local randomized = first_byte and (first_byte % 2 == 2)
        
        -- Create new device section
        local section_name = uci:add("devicemaster", "device")
        uci:set("devicemaster", section_name, "mac", new_mac)
        uci:set("devicemaster", section_name, "last_ip", ip or "")
        uci:set("devicemaster", section_name, "vendor", randomized and "Apple" or "未知")
        uci:set("devicemaster", section_name, "type", "phone")
        uci:set("devicemaster", section_name, "discovered", "1")
        uci:set("devicemaster", section_name, "discovered_at", tostring(os.time()))
        uci:set("devicemaster", section_name, "blocked", "0")
        uci:set("devicemaster", section_name, "first_seen", tostring(os.time()))
        uci:set("devicemaster", section_name, "last_seen", tostring(os.time()))
        if hostname ~= "" and hostname ~= "*" then
            uci:set("devicemaster", section_name, "hostname", hostname)
        end
        uci:commit("devicemaster")
        
        -- Return the new index
        return find_device_idx(new_mac)
    end
    
    -- Find primary device (the user-selected canonical record)
    local primary_idx = find_device_idx(canonical_mac)
    
    -- FIX: If primary device not in UCI (ARP-only device), create it first
    if not primary_idx then
        -- This is an ARP-only device, need to create UCI entry first
        primary_idx = create_device_for_mac(canonical_mac, arp_ip[canonical_mac])
        if not primary_idx then
            json_response({success = false, error = "Failed to create device entry for " .. canonical_mac})
            return
        end
    end
    
    -- FIX: Preserve existing device's identity when merging
    -- The device that existed earlier should keep its identity (name, vendor, type, etc.)
    -- Priority: 
    --   1. If primary device has name/vendor/type, keep them
    --   2. If primary is new (ARP-only), inherit from the earliest secondary device
    
    -- Get primary device's current attributes
    local primary_name = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "name") or ""
    local primary_hostname = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "hostname") or ""
    local primary_vendor = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "vendor") or ""
    local primary_type = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "type") or ""
    local primary_first_seen = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "first_seen") or ""
    local primary_manual = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "manual") or ""
    local primary_blocked = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "blocked") or "0"
    
    -- Check if primary device was just created (no first_seen or very recent)
    local primary_is_new = (primary_first_seen == "" or tonumber(primary_first_seen) > os.time() - 60)
    
    -- Find the earliest secondary device with meaningful attributes
    local best_secondary = nil
    local best_first_seen = nil
    
    -- Also check ALL secondary devices for blocked status (any blocked = inherit)
    local any_blocked = false
    
    for _, mac in ipairs(all_macs) do
        if mac ~= canonical_mac then
            local sec_idx = find_device_idx(mac)
            if sec_idx then
                local sec_first_seen = uci:get("devicemaster", "@device[" .. sec_idx .. "]", "first_seen") or ""
                local sec_name = uci:get("devicemaster", "@device[" .. sec_idx .. "]", "name") or ""
                local sec_vendor = uci:get("devicemaster", "@device[" .. sec_idx .. "]", "vendor") or ""
                local sec_type = uci:get("devicemaster", "@device[" .. sec_idx .. "]", "type") or ""
                local sec_manual = uci:get("devicemaster", "@device[" .. sec_idx .. "]", "manual") or ""
                local sec_blocked = uci:get("devicemaster", "@device[" .. sec_idx .. "]", "blocked") or "0"
                
                -- Check if any secondary is blocked
                if sec_blocked == "1" then
                    any_blocked = true
                end
                
                -- Check if this secondary has meaningful attributes
                local has_identity = (sec_name ~= "" or sec_vendor ~= "" or sec_type ~= "" or sec_manual == "1")
                
                if has_identity and sec_first_seen ~= "" then
                    if best_first_seen == nil or tonumber(sec_first_seen) < tonumber(best_first_seen) then
                        best_secondary = sec_idx
                        best_first_seen = sec_first_seen
                    end
                end
            end
        end
    end
    
    -- If primary is new or lacks attributes, inherit from the best secondary
    if best_secondary then
        local sec_name = uci:get("devicemaster", "@device[" .. best_secondary .. "]", "name") or ""
        local sec_hostname = uci:get("devicemaster", "@device[" .. best_secondary .. "]", "hostname") or ""
        local sec_vendor = uci:get("devicemaster", "@device[" .. best_secondary .. "]", "vendor") or ""
        local sec_type = uci:get("devicemaster", "@device[" .. best_secondary .. "]", "type") or ""
        local sec_manual = uci:get("devicemaster", "@device[" .. best_secondary .. "]", "manual") or ""
        local sec_blocked = uci:get("devicemaster", "@device[" .. best_secondary .. "]", "blocked") or "0"
        
        -- Inherit attributes if primary lacks them or is new
        if primary_is_new or primary_name == "" then
            primary_name = sec_name
            primary_hostname = sec_hostname
        end
        if primary_is_new or primary_vendor == "" or primary_vendor == "LAA Device" or primary_vendor == "未知" then
            primary_vendor = sec_vendor
        end
        if primary_is_new or primary_type == "" or primary_type == "unknown" then
            primary_type = sec_type
        end
        if primary_is_new or primary_manual == "" then
            primary_manual = sec_manual
        end
    end
    
    -- Inherit blocked status: primary's own + any blocked secondary
    if primary_blocked == "1" or any_blocked then
        primary_blocked = "1"
    end
    
    -- Update primary device's attributes
    if primary_name ~= "" then
        uci:set("devicemaster", "@device[" .. primary_idx .. "]", "name", primary_name)
        uci:set("devicemaster", "@device[" .. primary_idx .. "]", "hostname", primary_hostname)
    end
    if primary_vendor ~= "" and primary_vendor ~= "LAA Device" then
        uci:set("devicemaster", "@device[" .. primary_idx .. "]", "vendor", primary_vendor)
    end
    if primary_type ~= "" and primary_type ~= "unknown" then
        uci:set("devicemaster", "@device[" .. primary_idx .. "]", "type", primary_type)
    end
    if primary_manual == "1" then
        uci:set("devicemaster", "@device[" .. primary_idx .. "]", "manual", "1")
    end
    if primary_blocked == "1" then
        uci:set("devicemaster", "@device[" .. primary_idx .. "]", "blocked", "1")
    end
    
    -- Get current alt_macs
    local current_alt = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "alt_macs") or ""
    local alt_set = {}
    for mac in current_alt:gmatch("[^,]+") do
        alt_set[mac:upper()] = true
    end
    
    -- Add other MACs as alt_macs
    local new_macs = {}
    for _, mac in ipairs(all_macs) do
        if mac ~= canonical_mac and not alt_set[mac] then
            table.insert(new_macs, mac)
            alt_set[mac] = true
        end
    end
    
    if #new_macs > 0 then
        local new_alt = current_alt
        if new_alt ~= "" then new_alt = new_alt .. "," end
        new_alt = new_alt .. table.concat(new_macs, ",")
        uci:set("devicemaster", "@device[" .. primary_idx .. "]", "alt_macs", new_alt)
    end

    local session = load_session()
    merge_session_aliases(session, canonical_mac, all_macs)
    save_session(session)
    
    -- Track the IP of the currently online alias on the canonical record.
    if online_ip and online_ip ~= "" then
        uci:set("devicemaster", "@device[" .. primary_idx .. "]", "last_ip", online_ip)
    end

    -- Update last_seen for online device
    uci:set("devicemaster", "@device[" .. primary_idx .. "]", "last_seen", tostring(os.time()))
    uci:commit("devicemaster")
    
    -- Remove secondary devices from UCI (they are now merged)
    local remove_set = {}
    for _, mac in ipairs(all_macs) do
        if mac ~= canonical_mac then
            remove_set[mac] = true
        end
    end
    local to_remove = {}
    idx = 0
    while true do
        local mac = uci:get("devicemaster", "@device[" .. idx .. "]", "mac")
        if not mac then break end
        if remove_set[mac:upper()] then
            table.insert(to_remove, idx)
        end
        idx = idx + 1
    end
    
    -- Remove from highest index to lowest to avoid shifting issues
    for i = #to_remove, 1, -1 do
        uci:delete("devicemaster", "@device[" .. to_remove[i] .. "]")
    end
    if #to_remove > 0 then
        uci:commit("devicemaster")
    end

    -- ============================================================
    -- FIX: Sync merged device's hostname to dnsmasq DHCP list
    -- ============================================================
    -- After merging:
    -- 1. The PRIMARY MAC should show the merged record's hostname in
    --    the DHCP static lease list (not whatever old name may have
    --    been stored earlier).
    -- 2. Any secondary MAC that was previously independently
    --    registered with its own dhcp-host entry should have its
    --    entry removed — it is now an alt_mac of the primary record.
    --    Leaving stale entries causes the DHCP list to show
    --    out-of-date / meaningless device names.

    -- Determine the canonical name to sync for the PRIMARY MAC.
    -- (primary_name / primary_hostname were set earlier in this
    -- function; inherit from merged_hostname if empty.)
    local canonical_name = primary_name
    if not canonical_name or canonical_name == "" then
        canonical_name = primary_hostname
    end
    if not canonical_name or canonical_name == "" or canonical_name == "*" or canonical_name == "unknown" then
        -- fall back: derive from the primary record's current fields
        local pn = uci:get("devicemaster", "@device[" .. (find_device_idx(canonical_mac) or 0) .. "]", "name") or ""
        local ph = uci:get("devicemaster", "@device[" .. (find_device_idx(canonical_mac) or 0) .. "]", "hostname") or ""
        if ph ~= "" and ph ~= "*" and ph ~= "unknown" then
            canonical_name = ph
        elseif pn ~= "" and pn ~= "*" and pn ~= "unknown" then
            canonical_name = pn
        end
    end
    if canonical_name and canonical_name:match("^Mobile%-Device%-") then
        canonical_name = ""
    end

    -- Sync primary MAC: delete any existing entry + create new one
    -- Only do this on the main router (where dhcp.lan.ignore is NOT "1")
    local dhcp_ignore_val = sys.exec("uci -q get dhcp.lan.ignore 2>/dev/null"):gsub("%s+$", "")
    if dhcp_ignore_val ~= "1" and canonical_name and canonical_name ~= "" then
        -- Remove any pre-existing dhcp-host for the primary MAC first
        -- (ensures no stale old-name entry lingers)
        local _p_lower = canonical_mac:lower()
        local _di = 0
        while true do
            local hm = uci:get("dhcp", "@host[" .. _di .. "]", "mac")
            if not hm then break end
            if hm:lower() == _p_lower then
                uci:delete("dhcp", "@host[" .. _di .. "]")
                uci:commit("dhcp")
                -- restart scan from 0 since indices shifted
                _di = 0
            else
                _di = _di + 1
            end
        end
        -- Create the new dhcp-host entry for primary MAC
        local section_name = uci:add("dhcp", "host")
        uci:set("dhcp", section_name, "mac", canonical_mac)
        uci:set("dhcp", section_name, "name", canonical_name)
        if online_ip and online_ip ~= "" then
            uci:set("dhcp", section_name, "ip", online_ip)
        end
        uci:commit("dhcp")

        -- Patch /tmp/dhcp.leases so the lease page shows the new name
        local leases_fn = "/tmp/dhcp.leases"
        local f = io.open(leases_fn, "r")
        if f then
            local lines = {}
            for line in f:lines() do
                local ts, lmac, lip, lname, lid = line:match(
                    "^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)")
                if lmac and lmac:upper() == canonical_mac then
                    line = string.format("%s %s %s %s %s",
                        ts, lmac, lip, canonical_name, lid)
                end
                table.insert(lines, line)
            end
            f:close()
            local out = io.open(leases_fn, "w")
            if out then
                for _, line in ipairs(lines) do
                    out:write(line .. "\n")
                end
                out:close()
            end
        end

        -- Restart dnsmasq to apply
        sys.exec("/etc/init.d/dnsmasq restart >/dev/null 2>&1 &")
    end

    -- Clean up any stale dhcp-host entries for the secondary MACs.
    -- These MACs are now alt_macs and should NOT appear as
    -- independent hosts in the DHCP list.
    if dhcp_ignore_val ~= "1" then
        for _, smac in ipairs(all_macs) do
            if smac ~= canonical_mac then
                local s_lower = smac:lower()
                local di = 0
                while true do
                    local hm = uci:get("dhcp", "@host[" .. di .. "]", "mac")
                    if not hm then break end
                    if hm:lower() == s_lower then
                        uci:delete("dhcp", "@host[" .. di .. "]")
                        uci:commit("dhcp")
                        di = 0
                    else
                        di = di + 1
                    end
                end
            end
        end
    end

    json_response({success = true, primary_mac = canonical_mac, online_mac = online_mac, merged_macs = new_macs, note = "Primary MAC kept as selected; online MAC stored as alias"})
end

-- ============================================================
-- API: Unmerge a device (restore secondary MAC as separate device)
-- POST: primary_mac=xx&alt_mac=yy
-- ============================================================
function api_unmerge_device()
    local primary_mac = luci.http.formvalue("primary_mac") or ""
    local alt_mac = luci.http.formvalue("alt_mac") or ""
    
    primary_mac = primary_mac:upper():gsub("-", ":")
    alt_mac = alt_mac:upper():gsub("-", ":")
    
    if primary_mac == "" or alt_mac == "" then
        json_response({success = false, error = "Missing parameters"})
        return
    end
    
    -- Find primary device
    local primary_idx = nil
    local idx = 0
    while true do
        local mac = uci:get("devicemaster", "@device[" .. idx .. "]", "mac")
        if not mac then break end
        if mac:upper() == primary_mac then
            primary_idx = idx
            break
        end
        idx = idx + 1
    end
    
    if not primary_idx then
        json_response({success = false, error = "Primary device not found"})
        return
    end
    
    -- Get and update alt_macs
    local alt_macs = uci:get("devicemaster", "@device[" .. primary_idx .. "]", "alt_macs") or ""
    local new_alts = {}
    local found = false
    for mac in alt_macs:gmatch("[^,]+") do
        if mac:upper() ~= alt_mac then
            table.insert(new_alts, mac)
        else
            found = true
        end
    end
    
    if not found then
        json_response({success = false, error = "Alt MAC not found in primary device"})
        return
    end
    
    uci:set("devicemaster", "@device[" .. primary_idx .. "]", "alt_macs", table.concat(new_alts, ","))
    
    -- Check if the alt_mac already exists as a separate device
    local mac_exists = false
    local check_idx = 0
    while true do
        local mac = uci:get("devicemaster", "@device[" .. check_idx .. "]", "mac")
        if not mac then break end
        if mac:upper() == alt_mac then
            mac_exists = true
            break
        end
        check_idx = check_idx + 1
    end
    
    if mac_exists then
        -- MAC already exists, just remove from alt_macs without creating duplicate
        uci:commit("devicemaster")
        json_response({success = true, primary_mac = primary_mac, unmerged_mac = alt_mac, note = "MAC already exists as separate device"})
    else
        -- Create new device for the unmerged MAC
        local new_device = uci:add("devicemaster", "device")
        uci:set("devicemaster", new_device, "mac", alt_mac)
        uci:set("devicemaster", new_device, "vendor", "LAA")
        uci:set("devicemaster", new_device, "type", "unknown")
        uci:set("devicemaster", new_device, "hostname", "*")
        uci:set("devicemaster", new_device, "first_seen", tostring(os.time()))
        uci:set("devicemaster", new_device, "last_seen", tostring(os.time()))
        uci:commit("devicemaster")
        json_response({success = true, primary_mac = primary_mac, unmerged_mac = alt_mac})
    end
end

-- ============================================================
-- Core API: Real-time device status
-- Reads UCI profiles + ARP online status, joins in memory
-- Uses response cache to reduce load on hostapd/netifd
-- ============================================================
function api_status()
    -- Mark page as active (device_monitor uses this to decide discover frequency)
    local mf = io.open("/tmp/dm_mode", "w")
    if mf then mf:write("active"); mf:close() end
    local f = io.open("/tmp/dm_page_active", "w")
    if f then f:write(tostring(os.time())); f:close() end

    -- Return cached response if still fresh (eliminates ALL subprocess spawning)
    local now = os.time()
    if response_cache_str and now - response_cache_time < CACHE_TTL then
        luci.http.prepare_content("application/json")
        luci.http.write(response_cache_str)
        return
    end
    local online_macs, all_arp, wifi_stations, mesh_info = get_arp_online()
    -- Save local online state before merging master data (for ping probe comparison)
    local local_online = {}
    for mac, ip in pairs(online_macs) do
        local_online[mac] = ip
    end
    local dhcp_names = get_dhcp_hostnames()
    local dhcp_macs = get_dhcp_macs()
    
    -- Build IP→MAC mapping from DHCP (used to detect IP conflicts with sub-routers)
    local dhcp_ip_to_mac = {}
    local dhcp_leases_raw = get_dhcp_leases()
    for mac, info in pairs(dhcp_leases_raw) do
        if info.ip and info.ip ~= "" then
            dhcp_ip_to_mac[info.ip] = mac
        end
    end

    -- Helpers for enrichment: reject incomplete vendor/type values
    local function useful_vendor(v)
        if not v or v == "" then return false end
        local vu = v:upper()
        -- Generic labels that should be overridden by more specific detection
        if vu == "LAA" or vu == "UNKNOWN" or vu == "未知"
            or vu == "MOBILE DEVICE" or vu == "COMPUTER" or vu == "IOT DEVICE"
            or vu == "LAA DEVICE" or vu == "GENERIC DEVICE" then return false end
        return true
    end
    local function useful_type(t)
        if not t or t == "" then return false end
        if t:upper() == "UNKNOWN" then return false end
        return true
    end
    
    -- Sub-node: pull master snapshot to supplement remote device data
    local role_info = detect_role()
    local remote_dhcp = {}
    local remote_arp = {}
    local remote_devices = {}
    local known_offline = {}
    if role_info.role == "sub" and role_info.master_ip ~= "" then
        local snap = nil
        local SNAP_CACHE_FILE = "/tmp/dm_snap_cache.json"
        local cf = io.open(SNAP_CACHE_FILE, "r")
        if cf then
            local ok2, cached = pcall(json.parse, cf:read("*a"))
            cf:close()
            if ok2 and type(cached) == "table" and os.time() - (cached._cached_at or 0) < 30 then
                snap = cached
            end
        end
        if not snap then
            local snap_raw = sys.exec("curl -s --connect-timeout 2 --max-time 3 'http://" .. role_info.master_ip .. "/luci-static/resources/dm_snapshot.json' 2>/dev/null")
            if snap_raw and snap_raw ~= "" then
                local ok2, parsed = pcall(json.parse, snap_raw)
                if ok2 and type(parsed) == "table" and parsed.role == "master" then
                    parsed._cached_at = os.time()
                    snap = parsed
                    local wf = io.open(SNAP_CACHE_FILE, "w")
                    if wf then wf:write(json.stringify(parsed)); wf:close() end
                end
            end
        end
        if snap then
            remote_dhcp = snap.dhcp_leases or {}
            remote_arp = snap.arp or {}
            remote_devices = snap.devices or {}
            for mac, info in pairs(remote_dhcp) do
                dhcp_names[mac] = info.hostname or dhcp_names[mac]
                dhcp_macs[mac] = true
                local cur = online_macs[mac]
                if (not cur or cur == "") and info.ip ~= "" then
                    online_macs[mac] = info.ip
                end
                if not all_arp[mac] then
                    all_arp[mac] = info.ip
                end
            end
            -- Use master's computed online_macs (WiFi + DHCP + ip neigh REACHABLE)
            -- instead of raw ARP, to avoid marking stale entries as online.
            local master_online = snap.online_macs or {}
            for mac, _ in pairs(master_online) do
                local cur = online_macs[mac]
                if not cur or cur == "" then
                    local rip = remote_arp[mac] or (remote_dhcp[mac] and remote_dhcp[mac].ip) or ""
                    if rip ~= "" then
                        online_macs[mac] = rip
                    end
                end
            end
            -- Fill IPs for remaining local devices (WiFi stations with empty IP)
            -- Skip if IP is already claimed by DHCP for a different MAC
            for mac, ip in pairs(remote_arp) do
                local dhcp_owner = dhcp_ip_to_mac[ip]
                if dhcp_owner and dhcp_owner ~= mac then
                    -- Skip: this IP is claimed by DHCP for a different MAC
                else
                    local cur = online_macs[mac]
                    if cur == "" and ip ~= "" then
                        online_macs[mac] = ip
                    end
                    if not all_arp[mac] then
                        all_arp[mac] = ip
                    end
                end
            end
            -- 识别 mesh 主节点 MAC 并标记为在线
            if snap.master_mac and snap.master_mac ~= "" then
                if not online_macs[snap.master_mac] then
                    online_macs[snap.master_mac] = role_info.master_ip
                end
                -- 确保主节点设备有厂商/类型信息，供 ARP-only 设备列表使用
                if not remote_devices[snap.master_mac] then
                    remote_devices[snap.master_mac] = {
                        vendor = "",
                        devtype = "network",
                        name = "Mesh Master",
                        hostname = ""
                    }
                end
            end
        end
    end

    local devices = {}

    -- Load runtime session data from RAM (tmpfs), not Flash
    local session = load_session()

    -- Compute LAN info once (avoids spawning subprocess per device)
    -- ip route show dev br-lan may emit "default" before the subnet route, breaking regex
    -- Use ip addr to get the node's own IP, then extract subnet prefix
    local lan_ip = sys.exec("ip -4 addr show dev br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1")
    local lan_prefix = lan_ip and lan_ip:match("^(%d+%.%d+%.%d+)") or nil

    -- Load probe cache (file-backed for CGI persistence)
    local probe_cache = load_probe_cache()
    local probe_cache_dirty = false

    -- Sub-node: filter out recently-ping-failed MACs (stale entries from master snapshot)
    -- Prevents DHCP/ARP ghosts from re-entering online_macs on every snap re-fetch
    if role_info.role == "sub" then
        for mac, _ in pairs(online_macs) do
            if not local_online[mac] then
                local fail_check = probe_cache["fail|" .. mac] or 0
                if os.time() - fail_check < 180 then
                    online_macs[mac] = nil
                end
            end
        end
    end

    -- Collect known-but-offline devices from master's UCI (remote_devices)
    -- Runs AFTER the fail-marker filter so stale DHCP ghosts are excluded
    known_offline = {}
    if role_info.role == "sub" then
        for mac, _ in pairs(remote_devices) do
            local cur = online_macs[mac]
            if not cur or cur == "" then
                known_offline[mac] = remote_arp[mac] or (remote_dhcp[mac] and remote_dhcp[mac].ip) or ""
            end
        end
    end

    -- Sub-node: ping probe for devices only known from master data
    -- This ensures the sub-node actively verifies mesh_child connectivity
    -- rather than blindly trusting the master's ARP table
    if role_info.role == "sub" then
        for mac, ip in pairs(online_macs) do
            if not local_online[mac] and ip ~= "" and is_valid_ip(ip) then
                local cache_key = "remote|" .. mac .. "|" .. ip
                local last_probe = probe_cache[cache_key] or 0
                if os.time() - last_probe > 120 then
                    probe_cache[cache_key] = os.time()
                    probe_cache_dirty = true
                    local ping_result = sys.exec("ping -c 1 -W 1 " .. ip .. " 2>/dev/null && echo OK || echo FAIL")
                    if not ping_result:match("OK") then
                        online_macs[mac] = nil
                        probe_cache["fail|" .. mac] = os.time()
                    end
                end
            end
        end
    end

    -- Collect local MACs to filter router's own interfaces out of device list
    local local_macs = get_local_macs()

    -- MAC aliases that belong to merged devices. They must not be shown again
    -- as ARP-only/new devices just because the alias is currently online.
    local merged_alias_macs = {}

    -- 1. Read all device profiles from UCI
    uci:foreach("devicemaster", "device", function(s)
        if not s.mac then return end

        local mac_upper = s.mac:upper()
        local ip = s.last_ip or online_macs[mac_upper] or ""
        local is_online = online_macs[mac_upper] ~= nil

        -- For merged devices: check if any alt_mac is online
        local alt_online_ip = nil
        if not is_online and s.alt_macs and s.alt_macs ~= "" then
            for alt_mac in s.alt_macs:gmatch("[^,]+") do
                local alt_ip = online_macs[alt_mac:upper()]
                if alt_ip then
                    is_online = true
                    alt_online_ip = alt_ip
                    break
                end
            end
        end

        -- 非 LAN 子网设备：ARP 或 DHCP 租约中有记录就认为在线
        if not is_online and ip ~= "" and lan_prefix then
            local device_ip_prefix = ip:match("^(%d+%.%d+%.%d+)")
            if device_ip_prefix and device_ip_prefix ~= lan_prefix then
                if all_arp[mac_upper] or dhcp_macs[mac_upper] then
                    is_online = true
                end
            end
        end

        -- WAN 侧设备探测：last_ip 在非 LAN 子网的有效设备，最多每 60 秒 ping 一次
        if not is_online then
            local stored_ip = s.last_ip or ""
            if stored_ip ~= "" and lan_prefix and not stored_ip:match("^" .. lan_prefix:gsub("%.", "%%.")) then
                local cache_key = mac_upper .. "|" .. stored_ip
                local last_probe = probe_cache[cache_key] or 0
                if os.time() - last_probe > 60 then
                    probe_cache[cache_key] = os.time()
                    probe_cache_dirty = true
                    local probe = sys.exec("ping -c 1 -W 1 " .. stored_ip .. " 2>/dev/null && echo OK || echo FAIL")
                    if probe:match("OK") then
                        is_online = true
                        ip = stored_ip
                    end
                end
            end
        end

        -- If online, use the live IP from ARP
        if is_online and online_macs[mac_upper] then
            ip = online_macs[mac_upper]
        elseif is_online and alt_online_ip then
            ip = alt_online_ip
        end

        -- Filter out APIPA (169.254.x.x) addresses - these are self-assigned,
        -- not real network addresses. Fall back to DHCP lease or empty.
        if ip and ip:match("^169%.254%.") then
            local dhcp_ip = nil
            -- Try to find real IP from DHCP leases (validate MAC to prevent injection)
            if is_valid_mac(s.mac) then
                local dhcp_output = sys.exec("grep -i '" .. s.mac .. "' /tmp/dhcp.leases 2>/dev/null")
                if dhcp_output and dhcp_output ~= "" then
                    dhcp_ip = dhcp_output:match("(%d+%.%d+%.%d+%.%d+)")
                end
            end
            ip = dhcp_ip or ""
        end

        -- Prefer real client hostnames. Auto-generated names are only display
        -- fallbacks and must not hide DHCP hostnames such as H-de-S20.
        local hostname = s.hostname
        if not hostname or hostname == "" then
            hostname = dhcp_names[mac_upper]
        end
        -- For merged devices: try alt_macs' DHCP hostnames if current hostname is useless
        if (not hostname or hostname == "" or hostname == "*") and s.alt_macs and s.alt_macs ~= "" then
            for alt_mac in s.alt_macs:gmatch("[^,]+") do
                local alt_name = dhcp_names[alt_mac:upper()]
                if alt_name and alt_name ~= "" and alt_name ~= "*" then
                    hostname = alt_name
                    break
                end
            end
        end
        if not hostname or hostname == "" then
            local rp = remote_devices[mac_upper]
            hostname = (rp and rp.hostname ~= "") and rp.hostname or ""
        end
        if (not hostname or hostname == "") and s.manual == "1" then
            hostname = s.name
        end

        -- Check if MAC is randomized (locally administered bit)
        local randomized = false
        if s.mac then
            local first_byte = tonumber(s.mac:sub(1,2), 16)
            if first_byte and (first_byte % 2 == 2) then
                randomized = true
            end
        end

        -- Check if device is on a controllable network (not upstream)
        local is_controllable = true
        if ip and ip ~= "" then
            local device_prefix = ip:match("^(%d+%.%d+%.%d+)")
            if lan_prefix and device_prefix and device_prefix ~= lan_prefix then
                is_controllable = false
            end
        end

        -- Load runtime data from session.json (RAM), not UCI (Flash)
        local now = os.time()
        local device_session = session.devices[mac_upper] or {}
        local total_online = tonumber(device_session.total_online_time) or 0
        local first_seen = tonumber(device_session.first_seen) or tonumber(s.discovered_at) or now
        local last_seen = tonumber(device_session.last_seen) or first_seen
        local session_start = tonumber(device_session.current_session_start) or tonumber(device_session.last_seen) or first_seen or now
        local was_online = (device_session.online == true or device_session.online == "1" or device_session.online == 1)
        
        -- Auto-migrate discovered_at to first_seen for backward compat
        if not device_session.first_seen and s.discovered_at then
            device_session.first_seen = tonumber(s.discovered_at)
            first_seen = tonumber(s.discovered_at)
        end
        
        -- If device just came online (was offline, now online), start new session.
        -- Online state lives in session.json; UCI does not persist s.online.
        if is_online and not was_online then
            session_start = now
            device_session.current_session_start = now
        end
        
        -- If device just went offline (was online, now offline), add session to total
        if not is_online and was_online then
            local session_duration = last_seen - session_start
            if session_duration > 0 then
                total_online = total_online + session_duration
                device_session.total_online_time = total_online
            end
        end
        
        -- Update last_seen if online
        if is_online then
            device_session.last_seen = now
            last_seen = now
        end
        device_session.online = is_online and "1" or "0"
        
        -- Store back to session data
        session.devices[mac_upper] = device_session
        
        -- Calculate display online_seconds: total + current session (if online)
        local online_seconds = total_online
        if is_online then
            online_seconds = total_online + (now - session_start)
        end
        if is_online and total_online == 0 and first_seen and first_seen < now then
            online_seconds = now - first_seen
        end
        if online_seconds < 0 then online_seconds = 0 end

        -- Grace period: 非 LAN 设备最近在线过则暂时保持在线状态（防闪烁）
        if not is_online and ip ~= "" and lan_prefix then
            local device_ip_prefix = ip:match("^(%d+%.%d+%.%d+)")
            if device_ip_prefix and device_ip_prefix ~= lan_prefix then
                local last_seen = tonumber(device_session.last_seen) or 0
                if last_seen > 0 and now - last_seen < 300 then
                    is_online = true
                end
            end
        end

        -- Determine topology tier
        local topology_tier = "unknown"
        local parent_node = nil
        local mesh_connected = false
        if wifi_stations[mac_upper] then
            topology_tier = "direct"  -- Direct WiFi connection to this router
        elseif mesh_info.nodes[mac_upper] then
            topology_tier = "mesh_node"  -- This device IS a mesh node
            mesh_connected = mesh_info.nodes[mac_upper].mesh_connected or false
        elseif mesh_info.children[mac_upper] then
            topology_tier = "mesh_child"  -- Device connected via mesh node
            parent_node = mesh_info.children[mac_upper].parent_mac
        elseif is_online then
            topology_tier = "remote"  -- Online but not direct (via wire/other)
        end

        local rp = remote_devices[mac_upper]
        -- Parse alt_macs string into array
        local alt_macs = {}
        if s.alt_macs and s.alt_macs ~= "" then
            for alt_mac in s.alt_macs:gmatch("[^,]+") do
                local alt_upper = alt_mac:upper()
                table.insert(alt_macs, alt_upper)
                merged_alias_macs[alt_upper] = true
            end
        end
        merge_session_aliases(session, mac_upper, alt_macs)
        device_session = session.devices[mac_upper] or device_session
        total_online = tonumber(device_session.total_online_time) or 0
        first_seen = tonumber(device_session.first_seen) or first_seen
        last_seen = tonumber(device_session.last_seen) or last_seen
        session_start = tonumber(device_session.current_session_start) or tonumber(device_session.last_seen) or first_seen or session_start
        if is_online then
            device_session.last_seen = now
            last_seen = now
            session.devices[mac_upper] = device_session
        end
        online_seconds = total_online
        if is_online then
            online_seconds = total_online + (now - session_start)
        end
        if is_online and total_online == 0 and first_seen and first_seen < now then
            online_seconds = now - first_seen
        end
        if online_seconds < 0 then online_seconds = 0 end

        devices[#devices + 1] = {
            mac = s.mac,
            ip = ip,
            hostname = hostname,
            vendor = useful_vendor(s.vendor) and s.vendor or (rp and useful_vendor(rp.vendor) and rp.vendor) or "未知",
            type = useful_type(s.type) and s.type or (rp and useful_type(rp.devtype) and rp.devtype) or "unknown",
            online = is_online,
            online_seconds = online_seconds,
            first_seen = tonumber(s.first_seen or s.discovered_at or 0) or 0,
            discovered_at = tonumber(s.discovered_at or 0) or 0,
            last_seen = tonumber(s.last_seen or 0) or 0,
            randomized = randomized,
            is_controllable = is_controllable,
            topology = topology_tier,  -- direct | mesh_node | mesh_child | remote | unknown
            mesh_connected = mesh_connected,  -- For mesh_node: true if connected via mesh interface
            parent_node = parent_node,  -- For mesh_child devices, the parent mesh node MAC
            -- Only expose custom_name when user manually set it (manual=1)
            -- Auto-generated names (vendor-type) should NOT override hostname
            custom_name = (s.manual == "1" and s.name) and s.name or nil,
            blocked = (s.blocked == "1"),
            rate_limit = s.rate_limit or nil,
            group = s.group or s.groups or nil,
            notes = s.notes or nil,
            alt_macs = alt_macs  -- Array of alternative MAC addresses (for rotating MAC devices)
        }
    end)

    -- Save runtime session data to RAM (tmpfs), no Flash write
    save_session(session)
    if probe_cache_dirty then
        save_probe_cache(probe_cache)
    end

    -- 2. Add ARP-only devices (not yet in UCI, e.g. just joined)
    for mac, ip in pairs(online_macs) do
        local found = false
        for _, d in ipairs(devices) do
            if d.mac:upper() == mac then
                found = true
                break
            end
        end

        if not found and not merged_alias_macs[mac] and mac ~= "00:00:00:00:00:00" and not local_macs[mac] then
            local hostname = dhcp_names[mac] or ""
            local randomized = false
            local first_byte = tonumber(mac:sub(1,2), 16)
            if first_byte and (first_byte % 2 == 2) then
                randomized = true
            end

            local is_controllable = true
            local device_prefix = ip:match("^(%d+%.%d+%.%d+)")
            if lan_prefix and device_prefix and device_prefix ~= lan_prefix then
                is_controllable = false
            end

            -- ARP-only devices: no discovered_at yet, so online_seconds = 0
            -- They will get discovered_at when event_handler.sh processes them
            local rp = remote_devices[mac]  -- enriched from master snapshot
            if not hostname or hostname == "" then
                hostname = (rp and rp.hostname ~= "") and rp.hostname or ""
            end
            local custom_name = (rp and rp.name ~= "") and rp.name or nil
            devices[#devices + 1] = {
                mac = mac,
                ip = ip,
                hostname = hostname,
                vendor = (rp and useful_vendor(rp.vendor)) and rp.vendor or "未知",
                type = (rp and useful_type(rp.devtype)) and rp.devtype or "unknown",
                online = true,
                online_seconds = 0,
                randomized = randomized,
                is_controllable = is_controllable,
                custom_name = custom_name,
                blocked = false,
                rate_limit = nil,
                group = nil,
                notes = nil
            }
        end
    end

    -- 3. Known devices from master's UCI that are offline (not in online_macs)
    for mac, ip in pairs(known_offline) do
        local found = false
        for _, d in ipairs(devices) do
            if d.mac:upper() == mac then
                found = true
                break
            end
        end
        if not found and not merged_alias_macs[mac] and mac ~= "00:00:00:00:00:00" and not local_macs[mac] then
            local rp = remote_devices[mac]
            local hostname = (rp and rp.hostname ~= "") and rp.hostname or (rp and rp.name ~= "") and rp.name or ""
            local device_prefix = ip:match("^(%d+%.%d+%.%d+)")
            -- Only show known_offline for LAN-subnet devices with a known IP
            -- Skips: WAN-side devices, devices with no current ARP/DHCP entry
            local is_lan_known_offline = lan_prefix and device_prefix and device_prefix == lan_prefix
            if is_lan_known_offline then
            devices[#devices + 1] = {
                mac = mac,
                ip = ip,
                hostname = hostname,
                vendor = (rp and useful_vendor(rp.vendor)) and rp.vendor or "未知",
                type = (rp and useful_type(rp.devtype)) and rp.devtype or "unknown",
                online = false,
                online_seconds = 0,
                randomized = false,
                is_controllable = true,
                custom_name = (rp and rp.name ~= "") and rp.name or nil,
                blocked = false,
                rate_limit = nil,
                group = nil,
                notes = nil
            }
            end
        end
    end

    -- Sort devices by total online_seconds (descending), regardless of online status
    table.sort(devices, function(a, b)
        return (a.online_seconds or 0) > (b.online_seconds or 0)
    end)

    response_cache_str = json.stringify({devices = devices, _v = get_version()})
    response_cache_time = now
    json_response({devices = devices, _v = get_version()})
end

-- ============================================================
-- Device management APIs
-- ============================================================

-- Helper: Generate auto-name from vendor and type
-- e.g. "Apple" + "phone" -> "Apple-phone"
local function auto_name(vendor, devtype)
    if not vendor or vendor == "" or vendor == "未知" then
        return ""
    end
    -- Shorten long vendor names
    local short = vendor:gsub(" Mobile Communication", ""):gsub(" Corporation", ""):gsub(" Inc%.", ""):gsub(" Co%..*$", ""):gsub(" Technology", ""):gsub(" ", "-")
    if not devtype or devtype == "" or devtype == "unknown" then
        return short
    end
    return short .. "-" .. devtype
end

-- Helper: Extract base name and number suffix from a name
-- e.g., "iphone14promax-2" -> ("iphone14promax", 2)
-- e.g., "iphone14promax" -> ("iphone14promax", nil)
local function parse_name_suffix(name)
    if not name or name == "" then return name, nil end
    -- Match pattern: base name ending with -N where N is a number
    local base, num = name:match("^(.+)-(%d+)$")
    if base and num then
        return base, tonumber(num)
    end
    return name, nil
end

-- Helper: Find a unique name by appending -2, -3, etc.
-- Checks both UCI devicemaster and dhcp host entries
-- FIX: If base already has suffix like "-2", increment the number instead of appending "-2"
local function unique_name(base, current_mac)
    if base == "" then return "" end

    -- Collect all existing names from UCI and dhcp
    -- 修复：排除当前设备，避免自己的旧名称被计入重复
    local existing = {}
    uci:foreach("devicemaster", "device", function(s)
        -- Skip current device to avoid counting its old name as duplicate
        if not current_mac or not s.mac or s.mac:lower() ~= current_mac:lower() then
            if s.name and s.name ~= "" then existing[s.name:lower()] = true end
            if s.hostname and s.hostname ~= "" and s.hostname ~= "*" then existing[s.hostname:lower()] = true end
        end
    end)
    uci:foreach("dhcp", "host", function(s)
        if s.name and s.name ~= "" then existing[s.name:lower()] = true end
    end)

    -- If base name is not taken, use it directly
    if not existing[base:lower()] then
        return base
    end

    -- FIX: Parse base name to extract any existing number suffix
    -- e.g., "iphone14promax-2" should try "iphone14promax-3", not "iphone14promax-2-2"
    local real_base, start_num = parse_name_suffix(base)
    local n = start_num or 1
    
    -- Try -2, -3, ... until we find a free name
    while n < 100 do
        n = n + 1
        local candidate = real_base .. "-" .. tostring(n)
        if not existing[candidate:lower()] then
            return candidate
        end
    end
    return base
end

-- Helper: Sync a hostname to dnsmasq static lease
-- Delegates to sync_hostname.sh to avoid UCI cursor index issues
-- and heredoc problems with sys.exec()
local function sync_to_dnsmasq(mac, name, ip)
    if not name or name == "" then return end
    local script = "/usr/libexec/devicemaster/sync_hostname.sh"
    -- Ensure script exists
    if sys.call("test -x '" .. script .. "'") ~= 0 then
        sys.exec("logger -t devicemaster 'ERROR: sync_hostname.sh not found or not executable'")
        return
    end
    -- Call SYNCHRONOUSLY (no &) - we must wait for dnsmasq restart to complete
    -- Escape single quotes in name for shell safety
    local safe_name = name:gsub("'", "'\\''")
    local safe_ip = ip or ""
    local cmd = script .. " '" .. mac .. "' '" .. safe_name .. "'"
    if safe_ip ~= "" then
        cmd = cmd .. " '" .. safe_ip .. "'"
    end
    local result = sys.exec(cmd .. " 2>&1")
    sys.exec("logger -t devicemaster 'sync_to_dnsmasq result: " .. (result or "nil"):gsub("'", "'\\''") .. "'")
end

-- API: Set device name/vendor/type/group
function api_set_name()
    local mac = luci.http.formvalue("mac")
    local name = luci.http.formvalue("name")
    local vendor = luci.http.formvalue("vendor")
    local devtype = luci.http.formvalue("devtype")
    local group = luci.http.formvalue("group")
    local notes = luci.http.formvalue("notes")

    if not is_valid_mac(mac) then
        json_response({success = false, error = "Invalid MAC address format"})
        return
    end

    -- Find existing section
    local section = nil
    uci:foreach("devicemaster", "device", function(s)
        if s.mac and s.mac:lower() == mac:lower() then
            section = s[".name"]
        end
    end)

    if not section then
        section = uci:add("devicemaster", "device")
        uci:set("devicemaster", section, "mac", mac)
    end

    -- Auto-rename: if name is *, -, unknown, or empty, generate from vendor+type
    if name == "*" or name == "-" or name == "" or name == "unknown" then
        local current_vendor = vendor or uci:get("devicemaster", section, "vendor") or ""
        local current_type = devtype or uci:get("devicemaster", section, "type") or ""
        local generated = auto_name(current_vendor, current_type)
        if generated ~= "" then
            name = generated
        end
    end

    -- FIX: Only call unique_name if name is actually being changed
    -- Get current name to compare
    local current_name = uci:get("devicemaster", section, "name") or ""
    
    -- Ensure name uniqueness (only if name is different from current)
    if name and name ~= "" and name ~= current_name then
        name = unique_name(name, mac)
    end

    if name ~= nil then
        uci:set("devicemaster", section, "name", name)
        uci:set("devicemaster", section, "hostname", name)
        -- Mark as manual to prevent sync_hostname_to_uci from overwriting
        uci:set("devicemaster", section, "manual", "1")
    end
    if vendor and vendor ~= "" then
        uci:set("devicemaster", section, "vendor", vendor)
        uci:set("devicemaster", section, "manual", "1")
    end
    if devtype and devtype ~= "" then
        uci:set("devicemaster", section, "type", devtype)
        uci:set("devicemaster", section, "manual", "1")
    end
    if group ~= nil then uci:set("devicemaster", section, "group", group) end
    if notes ~= nil then uci:set("devicemaster", section, "notes", notes) end
    local ok, err = uci:commit("devicemaster")
    if not ok then log_msg("WARN: uci commit failed: " .. tostring(err)) end

    -- Sync hostname to dnsmasq
    -- 修复：获取设备 IP 并传递，避免 sync_hostname.sh 从 ARP 查找失败
    local dev_ip = uci:get("devicemaster", section, "last_ip") or ""
    if dev_ip == "" then
        -- 从 DHCP leases 查找
        local f = io.open("/tmp/dhcp.leases", "r")
        if f then
            for line in f:lines() do
                local ts, lease_mac, lease_ip, hostname, clientid = line:match(
                    "^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)"
                )
                if lease_mac and lease_mac:lower() == mac:lower() then
                    dev_ip = lease_ip
                    break
                end
            end
            f:close()
        end
    end
    sync_to_dnsmasq(mac, name, dev_ip)

    json_response({success = true})
end

-- API: Set device group
function api_set_group()
    local mac = luci.http.formvalue("mac")
    local group = luci.http.formvalue("group")

    if not is_valid_mac(mac) then
        json_response({success = false, error = "Invalid MAC address format"})
        return
    end

    local section = nil
    uci:foreach("devicemaster", "device", function(s)
        if s.mac and s.mac:lower() == mac:lower() then
            section = s[".name"]
        end
    end)

    if not section then
        section = uci:add("devicemaster", "device")
        uci:set("devicemaster", section, "mac", mac)
    end

    if group and group ~= "" and group ~= "all" and not is_valid_uci_id(group) then
        json_response({success = false, error = "Invalid group ID"})
        return
    end

    uci:set("devicemaster", section, "group", group or "")
    local ok4, err4 = uci:commit("devicemaster")
    if not ok4 then log_msg("WARN: uci commit failed: " .. tostring(err4)) end
    json_response({success = true})
end

-- API: Block device
function api_block()
    local mac = luci.http.formvalue("mac")
    if not is_valid_mac(mac) then
        json_response({success = false, error = "Valid MAC address required"})
        return
    end
    local result = exec_safe("/usr/libexec/devicemaster/traffic_control.sh block " .. mac)
    json_response({success = result == "success"})
end

-- API: Unblock device
function api_unblock()
    local mac = luci.http.formvalue("mac")
    if not is_valid_mac(mac) then
        json_response({success = false, error = "Valid MAC address required"})
        return
    end
    local result = exec_safe("/usr/libexec/devicemaster/traffic_control.sh unblock " .. mac)
    json_response({success = result == "success"})
end

-- API: Limit device bandwidth
function api_limit()
    local mac = luci.http.formvalue("mac")
    local rate = luci.http.formvalue("rate") or "1mbit"
    if not is_valid_mac(mac) then
        json_response({success = false, error = "Valid MAC address required"})
        return
    end
    if not is_valid_rate(rate) then
        json_response({success = false, error = "Invalid rate format (e.g. 1mbit, 500kbit)"})
        return
    end
    local result = exec_safe("/usr/libexec/devicemaster/traffic_control.sh limit " .. mac .. " " .. rate)
    json_response({success = result == "success"})
end

-- API: Remove bandwidth limit
function api_unlimit()
    local mac = luci.http.formvalue("mac")
    if not is_valid_mac(mac) then
        json_response({success = false, error = "Valid MAC address required"})
        return
    end
    local result = exec_safe("/usr/libexec/devicemaster/traffic_control.sh unlimit " .. mac)
    json_response({success = result == "success"})
end

-- API: Get all groups
function api_get_groups()
    local groups = {}
    uci:foreach("devicemaster", "group", function(s)
        table.insert(groups, {
            id = s[".name"],
            name = s.name or s.id or s[".name"],
            color = s.color,
            rate_limit = s.rate_limit
        })
    end)
    json_response({groups = groups})
end

-- API: Create group
function api_create_group()
    local name = luci.http.formvalue("name")
    local color = luci.http.formvalue("color") or "#3498db"
    if not name or name == "" then
        json_response({success = false, error = "Group name required"})
        return
    end
    local section = uci:add("devicemaster", "group")
    uci:set("devicemaster", section, "id", section)
    uci:set("devicemaster", section, "name", name or section)
    uci:set("devicemaster", section, "color", color)
    local ok5, err5 = uci:commit("devicemaster")
    if not ok5 then log_msg("WARN: uci commit failed: " .. tostring(err5)) end
    json_response({success = true, id = section})
end

-- API: Delete group
function api_delete_group()
    local id = luci.http.formvalue("id")
    if not id or id == "" or not is_valid_uci_id(id) then
        json_response({success = false, error = "Group ID required"})
        return
    end
    uci:foreach("devicemaster", "device", function(s)
        if s.group == id then
            uci:delete("devicemaster", s[".name"], "group")
        end
    end)
    uci:delete("devicemaster", id)
    local ok6, err6 = uci:commit("devicemaster")
    if not ok6 then log_msg("WARN: uci commit failed: " .. tostring(err6)) end
    json_response({success = true})
end

-- API: Delete device record and stale dnsmasq identity so rediscovery starts cleanly
function api_delete_device()
    local mac = luci.http.formvalue("mac")
    if not mac or mac == "" then
        json_response({success = false, error = "MAC address required"})
        return
    end
    
    -- Validate MAC format
    if not is_valid_mac(mac) then
        json_response({success = false, error = "Invalid MAC address"})
        return
    end
    
    -- Find and delete the device section by MAC
    local found = false
    uci:foreach("devicemaster", "device", function(s)
        if s.mac and s.mac:upper() == mac:upper() then
            uci:delete("devicemaster", s[".name"])
            found = true
            return false  -- stop iteration
        end
    end)
    
    if found then
        local ok7, err7 = uci:commit("devicemaster")
        if not ok7 then log_msg("WARN: uci commit failed: " .. tostring(err7)) end
        cleanup_deleted_device_identity(mac)
        json_response({success = true})
    else
        json_response({success = false, error = "Device not found"})
    end
end

-- API: Scan network (trigger ARP flood to discover new devices)
function api_scan_network()
    sys.exec("ip neigh flush all >/dev/null 2>&1")
    local lan_net = sys.exec("ip -4 addr show dev br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1"):match("^(%d+%.%d+%.%d+)")
    if lan_net then
        -- Batch ping: 32 concurrent at a time to avoid resource exhaustion
        -- (254 simultaneous pings can overwhelm the kernel ARP table)
        if sys.call("command -v fping >/dev/null 2>&1") == 0 then
            local targets = {}
            for i = 1, 254 do
                targets[#targets + 1] = lan_net .. "." .. tostring(i)
            end
            sys.exec("fping -a -q " .. table.concat(targets, " ") .. " 2>/dev/null")
        else
            sys.exec(string.format(
                "for i in $(seq 1 254); do ping -c 1 -W 1 %s.$i >/dev/null 2>&1 & [ $((i %% 32)) -eq 0 ] && wait; done; wait",
                lan_net
            ))
        end
    end
    json_response({success = true, message = "Network scan complete"})
end

-- API: Discover new devices (run event_handler logic for all ARP devices)
-- This fills UCI with any devices that are in ARP but not yet in UCI
function api_discover()
    local f = io.open("/tmp/dm_mode", "w")
    if f then f:write("active"); f:close() end
    f = io.open("/tmp/dm_page_active", "w")
    if f then f:write(tostring(os.time())); f:close() end
    local result = sys.exec("/usr/libexec/devicemaster/event_handler.sh discover 2>&1")
    json_response({success = true, message = result or "Discovery complete"})
end

-- Action: Download and install OUI database
function action_download_oui()
    local http = require("luci.http")
    local dispatcher = require("luci.dispatcher")

    local free_space = sys.exec("df /usr/share | tail -1 | awk '{print $4}'")
    local result_msg = ""

    if tonumber(free_space) < 10240 then
        result_msg = "错误: 存储空间不足，需要至少10MB可用空间"
    else
        result_msg = "开始下载OUI数据库...\n"
        result_msg = result_msg .. "源: https://standards-oui.ieee.org/oui/oui.csv\n"
        result_msg = result_msg .. "目标: /usr/share/devicemaster/oui.txt\n\n"

        local download_result = sys.exec("/usr/libexec/devicemaster/oui_lookup.sh download /tmp/oui.csv 2>&1")

        if download_result:match("Downloaded") then
            result_msg = result_msg .. "下载完成，正在转换格式...\n"
            local install_result = sys.exec("/usr/libexec/devicemaster/oui_lookup.sh install /tmp/oui.csv 2>&1")
            result_msg = result_msg .. install_result .. "\n"

            local has_local = sys.call("test -f /usr/share/devicemaster/oui.txt") == 0
            if has_local then
                local size = sys.exec("du -sh /usr/share/devicemaster/oui.txt 2>/dev/null | cut -f1")
                local count = sys.exec("wc -l < /usr/share/devicemaster/oui.txt 2>/dev/null")
                result_msg = result_msg .. "\n✓ 安装成功!\n"
                result_msg = result_msg .. "文件大小: " .. (size or "?") .. "\n"
                result_msg = result_msg .. "记录数量: " .. (count or "?") .. "\n"
            else
                result_msg = result_msg .. "\n✗ 安装失败"
            end
            sys.exec("rm -f /tmp/oui.csv")
        else
            result_msg = result_msg .. "✗ 下载失败\n" .. download_result
        end
    end

    sys.exec("echo '" .. result_msg:gsub("'", "'\\''") .. "' > /tmp/oui_download_result.txt")
    luci.http.redirect(dispatcher.build_url("admin", "network", "devicemaster", "settings"))
end

-- Action: Test OUI API
function action_test_api()
    local http = require("luci.http")
    local dispatcher = require("luci.dispatcher")

    local api = get_remote_api()
    local test_mac = luci.http.formvalue("mac") or luci.http.formvalue("test_mac") or "00:11:22:33:44:55"
    if not is_valid_mac(test_mac) then
        json_response({success = false, error = "Valid MAC address required"})
        return
    end
    local result = sys.exec("/usr/libexec/devicemaster/oui_lookup.sh test-api " .. api .. " " .. test_mac .. " 2>&1")

    sys.exec("echo '" .. result:gsub("'", "'\\''") .. "' > /tmp/oui_api_test_result.txt")
    luci.http.redirect(dispatcher.build_url("admin", "network", "devicemaster", "settings"))
end

-- API: Test OUI API (JSON response, no redirect)
function api_test_api()
    local api = get_remote_api()
    local test_mac = luci.http.formvalue("mac") or "00:11:22:33:44:55"

    if not is_valid_mac(test_mac) then
        json_response({success = false, error = "MAC地址格式无效"})
        return
    end

    local result = sys.exec("/usr/libexec/devicemaster/oui_lookup.sh test-api " .. api .. " " .. test_mac .. " 2>&1")

    local vendor = result:match("Extracted vendor:%s*(.+)")
    local rtime = result:match("Response time:%s*([0-9]+)")

    if vendor and vendor ~= "Not Found" and vendor ~= "" then
        json_response({
            success = true,
            vendor = vendor:gsub("\n", ""),
            time = tonumber(rtime) or 0
        })
    else
        json_response({
            success = false,
            error = "未找到厂商信息"
        })
    end
end
