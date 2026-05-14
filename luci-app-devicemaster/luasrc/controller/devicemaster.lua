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
    return mac and mac:match("^%x%x:[%x%x]:[%x%x]:[%x%x]:[%x%x]:[%x%x]$")
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

-- Helper: Get device online status and IPs
-- Uses three data sources:
--   1. /proc/net/arp - all known devices (for IP addresses)
--   2. ip neigh REACHABLE/PERMANENT - truly online devices
--   3. Active ping probe for STALE devices (fast detection when page is open)
-- Returns: online_macs { ["MAC"] = "IP" }, all_macs { ["MAC"] = "IP" }
local function get_arp_online()
    local online = {}
    local all_arp = {}
    local stale_macs = {}  -- STALE devices that need ping probe

    -- Read /proc/net/arp for all known device IPs
    local f = io.open("/proc/net/arp", "r")
    if f then
        local header = f:read("*l")  -- skip header
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

    -- Read ip neigh for accurate online status
    local output = sys.exec("ip neigh show dev br-lan 2>/dev/null")
    if output and output ~= "" then
        for line in output:gmatch("[^\r\n]+") do
            local ip, mac, state = line:match(
                "^(%d+%.%d+%.%d+%.%d+)%s+%S+%s+%S+%s+([0-9a-fA-F:]+)%s+(%S+)"
            )
            if mac and state then
                state = state:upper()
                mac = mac:upper()
                -- REACHABLE = confirmed online (active communication)
                -- PERMANENT = static ARP entry (always considered online)
                if state == "REACHABLE" or state == "PERMANENT" then
                    online[mac] = ip
                elseif state == "STALE" then
                    -- STALE devices: mark for ping probe
                    stale_macs[mac] = ip
                end
            end
        end
    end

    -- Active probe: ping STALE devices to confirm online status
    -- This provides fast detection when user is viewing the device list
    for mac, ip in pairs(stale_macs) do
        -- Quick ping: 1 packet, 1 second timeout (validate IP to prevent injection)
        if is_valid_ip(ip) then
            local ping_result = sys.exec("ping -c 1 -W 1 " .. ip .. " 2>/dev/null && echo OK || echo FAIL")
            if ping_result:match("OK") then
                online[mac] = ip
            end
        end
    end

    -- Fallback: if ip neigh returned nothing, use /proc/net/arp
    if next(online) == nil then
        online = all_arp
    end

    return online, all_arp
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

-- ============================================================
-- Core API: Real-time device status
-- Reads UCI profiles + ARP online status, joins in memory
-- No cache files, no background daemons needed
-- ============================================================
function api_status()
    local online_macs, all_arp = get_arp_online()
    local dhcp_names = get_dhcp_hostnames()
    local devices = {}

    -- 1. Read all device profiles from UCI
    uci:foreach("devicemaster", "device", function(s)
        if not s.mac then return end

        local mac_upper = s.mac:upper()
        local ip = s.last_ip or online_macs[mac_upper] or ""
        local is_online = online_macs[mac_upper] ~= nil

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

        -- Calculate total online duration (seconds since first discovery)
        -- This is cumulative and does not reset when device goes offline
        -- Auto-set discovered_at for devices that lack it (backward compat)
        if not s.discovered_at or s.discovered_at == "" then
            uci:set("devicemaster", s[".name"], "discovered_at", tostring(os.time()))
        end
        local online_seconds = 0
        if s.discovered_at then
            online_seconds = os.time() - tonumber(s.discovered_at)
            if online_seconds < 0 then online_seconds = 0 end
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
    uci:save("devicemaster")
    uci:commit("devicemaster")

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
    table.sort(devices, function(a, b)
        return (a.online_seconds or 0) > (b.online_seconds or 0)
    end)

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
    sys.exec("ip neigh flush all >/dev/null 2>&1")
    local lan_net = sys.exec("ip route show dev br-lan 2>/dev/null | awk '{print $1}' | cut -d/ -f1"):match("^(%d+%.%d+%.%d+%)")
    if lan_net then
        sys.exec(string.format("for i in $(seq 1 254); do ping -c 1 -W 1 %s$i >/dev/null 2>&1 & done; wait", lan_net))
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
