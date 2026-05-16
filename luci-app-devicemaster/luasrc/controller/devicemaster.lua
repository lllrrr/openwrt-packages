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
    entry({"admin", "network", "devicemaster", "api", "check_update"}, call("api_check_update"))
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

-- ============================================================
-- Online Status Debounce (anti-flicker)
-- Uses temp file to persist state across requests (uhttpd forks per request)
-- A device must fail probe for N consecutive times before being marked offline
-- ============================================================
local DEBOUNCE_FILE = "/tmp/devicemaster_debounce"
local OFFLINE_THRESHOLD = 3       -- Default: local WiFi/wired devices
local OFFLINE_THRESHOLD_MESH = 10 -- Mesh/remote devices: more tolerant

-- Global debounce state for current request (loaded once, saved once)
local _debounce_counters = nil

-- Load debounce counters from file (called once per request)
local function debounce_load()
    if _debounce_counters then return _debounce_counters end
    _debounce_counters = {}
    local f = io.open(DEBOUNCE_FILE, "r")
    if f then
        for line in f:lines() do
            local mac, count = line:match("^([0-9A-F:]+)%s+(%d+)$")
            if mac and count then
                _debounce_counters[mac] = tonumber(count)
            end
        end
        f:close()
    end
    return _debounce_counters
end

-- Save debounce counters to file (called once per request)
local function debounce_save()
    if not _debounce_counters then return end
    local f = io.open(DEBOUNCE_FILE, "w")
    if f then
        for mac, count in pairs(_debounce_counters) do
            if count > 0 then
                f:write(mac .. " " .. count .. "\n")
            end
        end
        f:close()
    end
end

-- Update online status with debounce (in-memory, no file I/O)
-- is_local: true if device is on local WiFi station list or directly reachable
-- Returns: true (online) or false (offline)
local function debounce_status(mac, is_online_now, is_local)
    local counters = debounce_load()
    local threshold = is_local and OFFLINE_THRESHOLD or OFFLINE_THRESHOLD_MESH

    if is_online_now then
        counters[mac] = 0  -- Reset counter on success
        return true
    else
        local fail_count = (counters[mac] or 0) + 1
        counters[mac] = fail_count
        if fail_count >= threshold then
            return false
        else
            return true  -- Still considered online
        end
    end
end

-- WiFi station cache to avoid frequent iwinfo calls (reduces hostapd memory pressure)
local _wifi_stations_cache = nil
local _wifi_stations_cache_time = 0
local WIFI_STATIONS_CACHE_TTL = 5  -- Cache for 5 seconds

-- Get WiFi station list from all wireless interfaces
-- Returns: station_macs { ["MAC"] = true }
local function get_wifi_stations()
    local now = os.time()
    
    -- Return cached result if still valid
    if _wifi_stations_cache and (now - _wifi_stations_cache_time) < WIFI_STATIONS_CACHE_TTL then
        return _wifi_stations_cache
    end
    
    local stations = {}
    -- Try iwinfo first (most reliable)
    local iwinfo_output = sys.exec("iwinfo 2>/dev/null | grep -E 'Access Point|ESSID' | awk '{print $1}'")
    if iwinfo_output then
        for iface in iwinfo_output:gmatch("[^%s]+") do
            local assoclist = sys.exec("iwinfo " .. iface .. " assoclist 2>/dev/null")
            if assoclist then
                for line in assoclist:gmatch("[^\r\n]+") do
                    local mac = line:match("^([0-9a-fA-F:]+)")
                    if mac then
                        stations[mac:upper()] = true
                    end
                end
            end
        end
    end
    -- Fallback: try iw directly
    if next(stations) == nil then
        local iw_output = sys.exec("iw dev 2>/dev/null | grep Interface | awk '{print $2}'")
        if iw_output then
            for iface in iw_output:gmatch("[^%s]+") do
                local dump = sys.exec("iw dev " .. iface .. " station dump 2>/dev/null")
                if dump then
                    for line in dump:gmatch("[^\r\n]+") do
                        local mac = line:match("^Station ([0-9a-fA-F:]+)")
                        if mac then
                            stations[mac:upper()] = true
                        end
                    end
                end
            end
        end
    end
    
    -- Update cache
    _wifi_stations_cache = stations
    _wifi_stations_cache_time = now
    
    return stations
end

-- Online detection strategy (page-open only, prioritize accuracy and speed):
--   1. Collect all known device IPs from ARP + DHCP leases + UCI
--   2. WiFi station list: devices connected to AP are online (even if ping fails)
--   3. ip neigh REACHABLE: kernel confirmed active
--   4. Probe remaining devices with ping/fping
-- Returns: online_macs { ["MAC"] = "IP" }, all_macs { ["MAC"] = "IP" }
local function get_arp_online()
    local all_ips = {}   -- ip -> mac mapping
    local all_macs = {}  -- mac -> ip mapping (uppercase MAC)

    -- 1. Collect IPs from /proc/net/arp
    local f = io.open("/proc/net/arp", "r")
    if f then
        local header = f:read("*l")
        if header then
            for line in f:lines() do
                local ip, hw_type, flags, mac = line:match(
                    "^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)"
                )
                if mac and mac ~= "00:00:00:00:00:00" and flags ~= "0x0" then
                    local mac_upper = mac:upper()
                    all_ips[ip] = mac_upper
                    all_macs[mac_upper] = ip
                end
            end
        end
        f:close()
    end

    -- 2. Also collect IPs from DHCP leases (may have devices not in ARP yet)
    local df = io.open("/tmp/dhcp.leases", "r")
    if df then
        for line in df:lines() do
            local ts, mac, ip, hostname, client_id = line:match(
                "^(%d+)%s+([0-9a-fA-F:]+)%s+(%S+)%s+(%S+)%s+(.*)"
            )
            if mac and ip and mac ~= "00:00:00:00:00:00" then
                local mac_upper = mac:upper()
                if not all_macs[mac_upper] then
                    all_ips[ip] = mac_upper
                    all_macs[mac_upper] = ip
                end
            end
        end
        df:close()
    end

    -- 3. Detect online status with multiple methods
    local online = {}

    -- First: WiFi station list (most reliable for wireless devices)
    -- Devices connected to AP are online even if they don't respond to ICMP
    local wifi_stations = get_wifi_stations()
    for mac, _ in pairs(wifi_stations) do
        if all_macs[mac] and not online[mac] then
            online[mac] = all_macs[mac]
        end
    end

    -- Second: ip neigh REACHABLE (kernel confirmed active)
    local neigh_output = sys.exec("ip neigh show 2>/dev/null")
    if neigh_output then
        for line in neigh_output:gmatch("[^\r\n]+") do
            local ip, mac, state = line:match(
                "^(%d+%.%d+%.%d+%.%d+)%s+%S+%s+%S+%s+([0-9a-fA-F:]+)%s+(%S+)"
            )
            if mac and ip and state then
                local mac_upper = mac:upper()
                state = state:upper()
                if state == "REACHABLE" and all_ips[ip] and not online[mac_upper] then
                    online[mac_upper] = ip
                end
            end
        end
    end

    -- Third: probe remaining devices with fping/ping
    local probe_ips = {}
    for ip, mac in pairs(all_ips) do
        if not online[mac] and is_valid_ip(ip) then
            table.insert(probe_ips, ip)
        end
    end

    if #probe_ips > 0 then
        -- Use fping if available (best: parallel, fast, reliable)
        local has_fping = sys.exec("which fping 2>/dev/null") ~= ""
        if has_fping then
            local ip_list = table.concat(probe_ips, " ")
            local result = sys.exec("fping -a -t 1000 -i 10 " .. ip_list .. " 2>/dev/null")
            if result then
                for line in result:gmatch("[^\r\n]+") do
                    local ok_ip = line:match("^([%d%.]+)$")
                    if ok_ip and all_ips[ok_ip] then
                        online[all_ips[ok_ip]] = ok_ip
                    end
                end
            end
        else
            -- Fallback: serial ping (safer for memory, no background processes)
            for _, ip in ipairs(probe_ips) do
                local ok = sys.exec("ping -c1 -W1 " .. ip .. " >/dev/null 2>&1 && echo 1")
                if ok == "1\n" then
                    if all_ips[ip] then
                        online[all_ips[ip]] = ip
                    end
                end
            end
        end
    end

    -- 4. Also check ip neigh for any devices not in our ARP/DHCP list
    if neigh_output then
        for line in neigh_output:gmatch("[^\r\n]+") do
            local ip, mac, state = line:match(
                "^(%d+%.%d+%.%d+%.%d+)%s+%S+%s+%S+%s+([0-9a-fA-F:]+)%s+(%S+)"
            )
            if mac and ip and state then
                local mac_upper = mac:upper()
                state = state:upper()
                if state == "REACHABLE" and not all_macs[mac_upper] then
                    all_macs[mac_upper] = ip
                    all_ips[ip] = mac_upper
                    online[mac_upper] = ip
                end
            end
        end
    end

    return online, all_macs, wifi_stations
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

-- Global counter for device list changes (incremented when UCI changes)
local _device_list_version = os.time()

function bump_device_version()
    _device_list_version = os.time()
end

-- API: Check if device list has changed (lightweight poll)
function api_check_update()
    local since = tonumber(luci.http.formvalue("since")) or 0
    local current = _device_list_version
    -- Also check if any device status changed (online/offline)
    local online_macs = get_online_macs()
    local online_count = 0
    for _ in pairs(online_macs) do online_count = online_count + 1 end
    
    json_response({
        changed = current > since,
        version = current,
        online_count = online_count
    })
end

-- ============================================================
-- Core API: Real-time device status
-- Reads UCI profiles + ARP online status, joins in memory
-- No cache files, no background daemons needed
-- ============================================================
function api_status()
    local online_macs, all_arp, wifi_stations = get_arp_online()
    local dhcp_names = get_dhcp_hostnames()

    local devices = {}
    -- 修复：添加 dirty 标志，只在有实际 UCI 修改时才 save/commit，避免无谓的磁盘写入
    local uci_dirty = false

    -- 1. Read all device profiles from UCI
    uci:foreach("devicemaster", "device", function(s)
        if not s.mac then return end

        local mac_upper = s.mac:upper()
        local ip = s.last_ip or online_macs[mac_upper] or ""
        local is_online = online_macs[mac_upper] ~= nil

        -- Apply debounce: must fail N consecutive probes before marking offline
        -- Local WiFi devices: 3 failures. Mesh/remote devices: 10 failures.
        local is_local = wifi_stations and wifi_stations[mac_upper] == true
        is_online = debounce_status(mac_upper, is_online, is_local)

        local was_online = (s.online_status == "1")
        
        -- Track online duration: update when status changes
        if is_online and not was_online then
            -- Device just came online: record the time
            uci:set("devicemaster", s[".name"], "last_online_at", tostring(os.time()))
            uci:set("devicemaster", s[".name"], "online_status", "1")
            uci_dirty = true
        elseif not is_online and was_online then
            -- Device just went offline: calculate total online time since discovery
            local last_at = s.last_online_at
            local discovered = s.discovered_at
            if last_at and last_at ~= "" and discovered and discovered ~= "" then
                -- Total online = previous sessions + current session
                local current_session = os.time() - tonumber(last_at)
                local previous_total = tonumber(s.online_duration) or 0
                -- If this is the first offline, previous_total is 0, but we need to count from discovered_at
                if previous_total == 0 then
                    -- First time going offline: count from discovered_at to now
                    local total_online = os.time() - tonumber(discovered)
                    uci:set("devicemaster", s[".name"], "online_duration", tostring(total_online))
                elseif current_session > 0 then
                    -- Subsequent offline: add current session to previous total
                    local total = previous_total + current_session
                    uci:set("devicemaster", s[".name"], "online_duration", tostring(total))
                end
            end
            uci:set("devicemaster", s[".name"], "online_status", "0")
            uci_dirty = true
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
            -- Get LAN subnet from br-lan to determine controllability
            local lan_net = sys.exec("ip route show dev br-lan 2>/dev/null | awk '{print $1}' | cut -d/ -f1")
            local lan_prefix = lan_net and lan_net:match("^(%d+%.%d+%.%d+)") or nil
            local device_prefix = ip:match("^(%d+%.%d+%.%d+)")
            if lan_prefix and device_prefix and device_prefix ~= lan_prefix then
                is_controllable = false
            end
        end

        -- Calculate cumulative online duration (total time spent online since discovery)
        -- online_duration: stored cumulative seconds from past sessions
        -- last_online_at: timestamp when device last came online
        -- discovered_at: when device was first discovered
        local online_seconds = 0
        local stored_duration = tonumber(s.online_duration) or 0
        local last_online_at = s.last_online_at
        local discovered_at = s.discovered_at
        local now = os.time()
        
        if is_online then
            -- Currently online: calculate total time online since discovery
            -- If never went offline, use discovered_at as start
            -- If went offline before, use last_online_at as start of current session
            if discovered_at and discovered_at ~= "" then
                if stored_duration > 0 and last_online_at and last_online_at ~= "" then
                    -- Has offline history: stored + current session
                    local current_session = now - tonumber(last_online_at)
                    if current_session > 0 then
                        online_seconds = stored_duration + current_session
                    else
                        online_seconds = stored_duration
                    end
                else
                    -- Never went offline: calculate from discovered_at
                    online_seconds = now - tonumber(discovered_at)
                end
            else
                online_seconds = stored_duration
            end
        else
            -- Currently offline: just show stored duration
            online_seconds = stored_duration
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
            -- Only expose custom_name when user manually set it (manual=1)
            -- Auto-generated names (vendor-type) should NOT override hostname
            custom_name = (s.manual == "1" and s.name) and s.name or nil,
            blocked = (s.blocked == "1"),
            rate_limit = s.rate_limit or nil,
            group = s.group or s.groups or nil,
            notes = s.notes or nil
        }
    end)
    -- 修复：只在有实际 UCI 修改时才 save/commit，避免每次请求都写磁盘
    if uci_dirty then
        uci:save("devicemaster")
        uci:commit("devicemaster")
    end
    bump_device_version()

    -- 2. Add ARP-only devices (not yet in UCI, e.g. just joined)
    for mac, ip in pairs(online_macs) do
        local found = false
        local mac_upper = mac:upper()
        for _, d in ipairs(devices) do
            if d.mac:upper() == mac_upper then
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
            local lan_net = sys.exec("ip route show dev br-lan 2>/dev/null | awk '{print $1}' | cut -d/ -f1")
            local lan_prefix = lan_net and lan_net:match("^(%d+%.%d+%.%d+)") or nil
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
    -- Use MAC as secondary sort key for stable ordering
    table.sort(devices, function(a, b)
        local a_secs = a.online_seconds or 0
        local b_secs = b.online_seconds or 0
        if a_secs ~= b_secs then
            return a_secs > b_secs
        else
            return (a.mac or "") < (b.mac or "")
        end
    end)

    -- Save debounce state to file (once per request)
    debounce_save()

    json_response({devices = devices})
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
local function unique_name(base)
    if base == "" then return "" end

    -- Collect all existing names from UCI and dhcp
    local existing = {}
    uci:foreach("devicemaster", "device", function(s)
        if s.name and s.name ~= "" then existing[s.name:lower()] = true end
        if s.hostname and s.hostname ~= "" and s.hostname ~= "*" then existing[s.hostname:lower()] = true end
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
local function sync_to_dnsmasq(mac, name)
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
    local result = sys.exec(script .. " '" .. mac .. "' '" .. safe_name .. "' 2>&1")
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
    if name and name ~= "" then
        name = unique_name(name)
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
    sync_to_dnsmasq(mac, name)

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
    -- Only flush br-lan ARP cache (not mesh/other interfaces)
    sys.exec("ip neigh flush dev br-lan >/dev/null 2>&1")

    -- Scan br-lan subnet
    local lan_net = sys.exec("ip route show dev br-lan 2>/dev/null | awk '{print $1}' | cut -d/ -f1"):match("^(%d+%.%d+%.%d+%)")
    if lan_net then
        -- 修复：优先使用 fping 批量扫描（高效、低资源占用）
        -- 如果 fping 不可用，则限制并发 ping 数量为 20 个，避免同时启动 254 个进程耗尽资源
        local has_fping = sys.exec("which fping 2>/dev/null") ~= ""
        if has_fping then
            sys.exec("fping -a -q -t 1000 -i 10 " .. lan_net .. "{1..254} 2>/dev/null")
        else
            -- 分批 ping，每批 20 个，避免进程爆炸
            for batch_start = 1, 254, 20 do
                local batch_end = math.min(batch_start + 19, 254)
                local cmd = ""
                for i = batch_start, batch_end do
                    cmd = cmd .. "ping -c 1 -W 1 " .. lan_net .. i .. " >/dev/null 2>&1 & "
                end
                cmd = cmd .. "wait"
                sys.exec(cmd)
            end
        end
    end

    -- After scan, re-ping all known UCI devices to restore their ARP entries
    -- This prevents mesh/sub-devices from being marked offline
    uci:foreach("devicemaster", "device", function(s)
        local ip = s.last_ip
        if ip and is_valid_ip(ip) then
            sys.exec("ping -c 1 -W 1 " .. ip .. " >/dev/null 2>&1 &")
        end
    end)
    sys.exec("wait >/dev/null 2>&1")

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
