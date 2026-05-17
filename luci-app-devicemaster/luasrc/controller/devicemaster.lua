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
    entry({"admin", "network", "devicemaster", "api", "scan_network"}, call("api_scan_network"))
    entry({"admin", "network", "devicemaster", "api", "discover"}, call("api_discover"))

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

-- Helper: Execute shell command safely
local function exec_safe(cmd)
    local result = sys.exec(cmd .. " 2>/dev/null")
    return result:gsub("\n$", "")
end

-- Helper: Get WiFi station list (devices directly connected to this router)
-- Returns: { ["MAC"] = true }
local function get_wifi_stations()
    local stations = {}
    for _, iface in ipairs({"wl0-ap0", "wl1-ap0"}) do
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
    if router_oui then
        local fdb = sys.exec("brctl showmacs br-lan 2>/dev/null")
        if fdb and fdb ~= "" then
            for line in fdb:gmatch("[^\r\n]+") do
                local port, mac, is_local = line:match("^%s*(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)")
                if port and mac then
                    local mac_u = mac:upper()
                    if is_local == "yes" and mac_u == "02:0C:43:26:46:58" then
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
                    if mac == "D4:EE:07:24:9B:8E" then os.execute("echo step3c >> /tmp/topo_dbg") end
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
    for mac, _ in pairs(wifi_stations) do
        online[mac] = all_arp[mac] or dhcp_leases[mac] and dhcp_leases[mac].ip or ""
    end

    -- Tier 2: ip neigh REACHABLE/PERMANENT
    local output = sys.exec("ip neigh show dev br-lan 2>/dev/null")
    if output and output ~= "" then
        for line in output:gmatch("[^\r\n]+") do
            local ip, mac, state = line:match(
                "^(%d+%.%d+%.%d+%.%d+)%s+lladdr%s+([0-9a-fA-F:]+)%s+(%S+)"
            )
            if mac and state then
                state = state:upper()
                mac = mac:upper()
                if state == "REACHABLE" or state == "PERMANENT" then
                    online[mac] = ip
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
    for mac, ip in pairs(all_arp) do
        if not online[mac] and not wifi_stations[mac] and is_valid_ip(ip) then
            probe_macs[mac] = ip
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
-- Probe cache to avoid pinging offline devices too often (module-level, persists across calls)
local probe_cache = {}

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
    local f = io.open(SESSION_FILE, "w")
    if f then
        f:write(json.stringify(data))
        f:close()
    end
end

-- Response cache: avoid heavy computation on every frontend poll
local response_cache_str = nil
local response_cache_time = 0
local CACHE_TTL = 5

-- ============================================================
-- Core API: Real-time device status
-- Reads UCI profiles + ARP online status, joins in memory
-- Uses response cache to reduce load on hostapd/netifd
-- ============================================================
function api_status()
    -- Return cached response if still fresh (eliminates ALL subprocess spawning)
    local now = os.time()
    if response_cache_str and now - response_cache_time < CACHE_TTL then
        luci.http.prepare_content("application/json")
        luci.http.write(response_cache_str)
        return
    end
    local online_macs, all_arp, wifi_stations, mesh_info = get_arp_online()
    local dhcp_names = get_dhcp_hostnames()
    local dhcp_macs = get_dhcp_macs()
    local devices = {}

    -- Load runtime session data from RAM (tmpfs), not Flash
    local session = load_session()

    -- Compute LAN info once (avoids spawning subprocess per device)
    local lan_net = sys.exec("ip route show dev br-lan 2>/dev/null | awk '{print $1}' | cut -d/ -f1")
    local lan_prefix = lan_net and lan_net:match("^(%d+%.%d+%.%d+)") or nil

    -- 1. Read all device profiles from UCI
    uci:foreach("devicemaster", "device", function(s)
        if not s.mac then return end

        local mac_upper = s.mac:upper()
        local ip = s.last_ip or online_macs[mac_upper] or ""
        local is_online = online_macs[mac_upper] ~= nil

        -- type=network/router 设备: ARP 或 DHCP 租约中有记录就认为在线（跨子网/NAT/Mesh）
        if not is_online and (s.type == "network" or s.type == "router") then
            if all_arp[mac_upper] or dhcp_macs[mac_upper] then
                is_online = true
                if ip == "" then ip = all_arp[mac_upper] or "" end
            end
        end

        -- WAN 侧设备探测：type=network 且 last_ip 在非 LAN 子网，最多每 60 秒 ping 一次
        if not is_online and (s.type == "network" or s.type == "router") then
            local stored_ip = s.last_ip or ""
            if stored_ip ~= "" and not stored_ip:match("^192%.168%.31%.") then
                local cache_key = mac_upper .. "|" .. stored_ip
                local last_probe = probe_cache[cache_key] or 0
                if os.time() - last_probe > 60 then
                    probe_cache[cache_key] = os.time()
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

        -- Use DHCP hostname if UCI hostname is empty
        -- Note: empty string "" is truthy in Lua, need explicit check
        local hostname = s.hostname
        if not hostname or hostname == "" then
            hostname = s.name
        end
        if not hostname or hostname == "" then
            hostname = dhcp_names[mac_upper]
        end
        if not hostname or hostname == "" then
            hostname = ""
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
        local session_start = tonumber(device_session.current_session_start) or now
        
        -- Auto-migrate discovered_at to first_seen for backward compat
        if not device_session.first_seen and s.discovered_at then
            device_session.first_seen = tonumber(s.discovered_at)
            first_seen = tonumber(s.discovered_at)
        end
        
        -- If device just came online (was offline, now online), start new session
        if is_online and (not s.online or s.online == "0") then
            session_start = now
            device_session.current_session_start = now
        end
        
        -- If device just went offline (was online, now offline), add session to total
        if not is_online and s.online == "1" then
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
        
        -- Store back to session data
        session.devices[mac_upper] = device_session
        
        -- Calculate display online_seconds: total + current session (if online)
        local online_seconds = total_online
        if is_online then
            online_seconds = total_online + (now - session_start)
        end
        if online_seconds < 0 then online_seconds = 0 end

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

        devices[#devices + 1] = {
            mac = s.mac,
            ip = ip,
            hostname = hostname,
            vendor = s.vendor or "未知",
            type = s.type or "unknown",
            online = is_online,
            online_seconds = online_seconds,
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
            notes = s.notes or nil
        }
    end)

    -- Save runtime session data to RAM (tmpfs), no Flash write
    save_session(session)

    -- 2. Add ARP-only devices (not yet in UCI, e.g. just joined)
    for mac, ip in pairs(online_macs) do
        local found = false
        for _, d in ipairs(devices) do
            if d.mac:upper() == mac then
                found = true
                break
            end
        end

        if not found and mac ~= "00:00:00:00:00:00" then
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
            devices[#devices + 1] = {
                mac = mac,
                ip = ip,
                hostname = hostname,
                vendor = "未知",
                type = "unknown",
                online = true,
                online_seconds = 0,
                randomized = randomized,
                is_controllable = is_controllable,
                custom_name = nil,
                blocked = false,
                rate_limit = nil,
                group = nil,
                notes = nil
            }
        end
    end

    -- Sort devices by total online_seconds (descending), regardless of online status
    table.sort(devices, function(a, b)
        return (a.online_seconds or 0) > (b.online_seconds or 0)
    end)

    response_cache_str = json.stringify({devices = devices, _v = "fdb3"})
    response_cache_time = now
    json_response({devices = devices, _v = "fdb3"})
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
    local short = vendor:gsub(" Mobile Communication", ""):gsub(" Corporation", ""):gsub(" Inc%.", ""):gsub(" Co%..*$", ""):gsub(" Technology", "")
    if not devtype or devtype == "" or devtype == "unknown" then
        return short
    end
    return short .. "-" .. devtype
end

-- Helper: Find a unique name by appending -2, -3, etc.
-- Checks both UCI devicemaster and dhcp host entries
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

    -- Try -2, -3, ... until we find a free name
    local n = 2
    while n < 100 do
        local candidate = base .. "-" .. tostring(n)
        if not existing[candidate:lower()] then
            return candidate
        end
        n = n + 1
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

    if not mac or mac == "" then
        json_response({success = false, error = "MAC address required"})
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

    -- Ensure name uniqueness
    -- 修复：传入 MAC 以排除当前设备，避免自己的旧名称被计入重复
    if name and name ~= "" then
        name = unique_name(name, mac)
    end

    if name ~= nil then
        uci:set("devicemaster", section, "name", name)
        uci:set("devicemaster", section, "hostname", name)
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
    uci:commit("devicemaster")

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

    if not mac or mac == "" then
        json_response({success = false, error = "MAC address required"})
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

    uci:set("devicemaster", section, "group", group or "")
    uci:commit("devicemaster")
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
            name = s.name or s.id,
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
    local section = uci:add("devicemaster", "group")
    uci:set("devicemaster", section, "id", section)
    uci:set("devicemaster", section, "name", name or section)
    uci:set("devicemaster", section, "color", color)
    uci:commit("devicemaster")
    json_response({success = true, id = section})
end

-- API: Delete group
function api_delete_group()
    local id = luci.http.formvalue("id")
    if not id or id == "" then
        json_response({success = false, error = "Group ID required"})
        return
    end
    uci:delete("devicemaster", id)
    uci:commit("devicemaster")
    json_response({success = true})
end

-- API: Delete device record (only removes UCI entry, device can be rediscovered)
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
        uci:commit("devicemaster")
        json_response({success = true})
    else
        json_response({success = false, error = "Device not found"})
    end
end

-- API: Scan network (trigger ARP flood to discover new devices)
function api_scan_network()
    sys.exec("ip neigh flush all >/dev/null 2>&1")
    local lan_net = sys.exec("ip route show dev br-lan 2>/dev/null | awk '{print $1}' | cut -d/ -f1"):match("^(%d+%.%d+%.%d+%)")
    if lan_net then
        -- Batch ping: 32 concurrent at a time to avoid resource exhaustion
        -- (254 simultaneous pings can overwhelm the kernel ARP table)
        if sys.call("command -v fping >/dev/null 2>&1") == 0 then
            sys.exec("fping -a -q " .. lan_net .. "{1..254} 2>/dev/null")
        else
            sys.exec(string.format(
                "for i in $(seq 1 254); do ping -c 1 -W 1 %s$i >/dev/null 2>&1 & [ $((i %% 32)) -eq 0 ] && wait; done; wait",
                lan_net
            ))
        end
    end
    json_response({success = true, message = "Network scan complete"})
end

-- API: Discover new devices (run event_handler logic for all ARP devices)
-- This fills UCI with any devices that are in ARP but not yet in UCI
function api_discover()
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

    local api = uci:get("devicemaster", "settings", "remote_api") or "maclookup"
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
    local api = uci:get("devicemaster", "settings", "remote_api") or "maclookup"
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
