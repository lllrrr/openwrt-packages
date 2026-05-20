module("luci.controller.clientstatus", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/clientstatus") then
		return
	end

	entry({"admin", "services", "clientstatus"},
	      call("action_main"),
	      _("Client Management"), 60)

	entry({"admin", "services", "clientstatus", "status"},
	      template("clientstatus"),
	      _("Status"), 1)

	entry({"admin", "services", "clientstatus", "settings"},
	      cbi("clientstatus/settings"),
	      _("Settings"), 2)

	entry({"admin", "services", "clientstatus", "data"},
	      call("action_data"), nil).leaf = true

	entry({"admin", "services", "clientstatus", "mtime"},
	      call("action_mtime"), nil)

	entry({"admin", "services", "clientstatus", "toggle_acl"},
	      call("action_toggle_acl"), nil).leaf = true

	entry({"admin", "services", "clientstatus", "save_hostname"},
	      call("action_save_hostname"), nil).leaf = true

	entry({"admin", "services", "clientstatus", "reset"},
	      call("action_reset"), nil)
end

function action_main()
	local uci = require("luci.model.uci").cursor()
	local enabled = uci:get("clientstatus", "main", "enabled") or "0"

	if enabled == "1" then
		luci.template.render("clientstatus")
	else
		luci.http.redirect(
			luci.dispatcher.build_url("admin/services/clientstatus/settings")
		)
	end
end

-- ─── Helpers ──────────────────────────────────────────

local function valid_mac(mac)
	return mac ~= nil and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function sanitize_hostname(name)
	if not name then return nil end
	name = name:match("^%s*(.-)%s*$") or name
	if #name == 0 then return nil end
	if #name > 64 then name = name:sub(1, 64) end
	name = name:gsub("[\1-\31\127]", "")
	if #name == 0 then return nil end
	return name
end

local function get_blocked_set()
	local uci = require("luci.model.uci").cursor()
	local set = {}
	local raw = uci:get("clientstatus", "main", "blocked_mac")
	if type(raw) == "table" then
		for _, mac in ipairs(raw) do
			set[mac:upper()] = true
		end
	elseif raw then
		set[raw:upper()] = true
	end
	return set
end

local function get_hostname_map()
	local uci = require("luci.model.uci").cursor()
	local map = {}
	uci:foreach("clientstatus", "device", function(s)
		if s.mac and s.hostname and s.hostname ~= "" then
			map[s.mac:upper()] = s.hostname
		end
	end)
	return map
end

-- ─── Mtime endpoint ───────────────────────────────────

function action_mtime()
	-- Send SIGUSR1 to shell daemon — this IS the heartbeat
	local pid_f = io.open("/tmp/clientstatus.pid", "r")
	if pid_f then
		local pid = pid_f:read("*n")
		pid_f:close()
		if pid and pid > 0 then
			pcall(nixio.kill, pid, 10)
		end
	end

	-- Return file mtime for change detection
	local stat = nixio.fs.stat("/tmp/clientstatus")
	local mtime = stat and stat.mtime or 0

	luci.http.header("Cache-Control", "no-store, no-cache, must-revalidate")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ mtime = mtime })
end

-- ─── Data endpoint ────────────────────────────────────

function action_data()
	local output_file = "/tmp/clientstatus"
	local blocked_set = get_blocked_set()
	local hostname_map = get_hostname_map()

	local result = {
		clients  = {},
		updated  = nil
	}

	local f = io.open(output_file, "r")
	if not f then
		luci.http.prepare_content("application/json")
		luci.http.write_json(result)
		return
	end

	for line in f:lines() do
		if line:sub(1, 1) == "#" then
			local ts = line:match("Client Status %-%- (.+)")
			if ts then result.updated = ts end
		else
			local trimmed = line:match("^%s*(.-)%s*$") or line
			if trimmed ~= "" then
				local parts = {}
				for part in trimmed:gmatch("%S+") do
					parts[#parts + 1] = part
				end

				if #parts >= 6 then
					local mac      = parts[1]
					local status   = parts[2]
					local duration = parts[3]
					local ipv4     = parts[4] or ""
					local hostname = parts[5] or ""
					local cnt      = parts[6] or ""

					if valid_mac(mac) then
						if status == "online" or status == "offline" then
							if ipv4 == "-" then ipv4 = "" end
							if hostname == "-" or hostname == "" then hostname = "—" end

							-- Determine NCT (Network Connection Type)
							local nct = "Ethernet"
							if cnt ~= "" and cnt ~= "Ethernet" then
								nct = cnt
							end

							-- ACL: always read from UCI config
							local acl_status = blocked_set[mac:upper()] and "Blocked" or "Allowed"

							local custom_name = hostname_map[mac:upper()]
							local is_custom = false
							local display_name = hostname

							if custom_name then
								display_name = custom_name
								is_custom = true
							end

							result.clients[#result.clients + 1] = {
								mac           = mac,
								status        = status,
								duration      = duration,
								ipv4          = ipv4,
								hostname      = display_name,
								orig_hostname = hostname,
								custom        = is_custom,
								nct           = nct,
								acl           = acl_status
							}
						end
					end
				end
			end
		end
	end
	f:close()

	table.sort(result.clients, function(a, b)
		if a.status ~= b.status then
			return a.status == "online"
		end
		return a.mac < b.mac
	end)

	luci.http.prepare_content("application/json")
	luci.http.write_json(result)
end

-- ─── Toggle ACL ───────────────────────────────────────

function action_toggle_acl()
	local http = require("luci.http")
	local uci  = require("luci.model.uci").cursor()

	local mac = http.formvalue("mac")
	if not mac or mac == "" then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "missing mac" })
		return
	end

	if not valid_mac(mac) then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "invalid mac format" })
		return
	end

	mac = mac:upper()

	local raw = uci:get("clientstatus", "main", "blocked_mac")
	local current = {}
	if type(raw) == "table" then
		current = raw
	elseif raw then
		current = {raw}
	end

	local found = false
	local new_list = {}
	for _, m in ipairs(current) do
		if m:upper() == mac then
			found = true
		else
			new_list[#new_list + 1] = m
		end
	end

	if not found then
		new_list[#new_list + 1] = mac
	end

	uci:delete("clientstatus", "main", "blocked_mac")
	if #new_list > 0 then
		uci:set("clientstatus", "main", "blocked_mac", new_list)
	end

	uci:save("clientstatus")
	uci:commit("clientstatus")

	http.prepare_content("application/json")
	http.write_json({
		ok      = true,
		mac     = mac,
		blocked = not found
	})
end

-- ─── Save hostname ────────────────────────────────────

function action_save_hostname()
	local http = require("luci.http")
	local uci  = require("luci.model.uci").cursor()

	local mac      = http.formvalue("mac")
	local hostname = http.formvalue("hostname")

	if not mac or mac == "" then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "missing mac" })
		return
	end

	if not valid_mac(mac) then
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = "invalid mac format" })
		return
	end

	mac = mac:upper()
	hostname = sanitize_hostname(hostname)

	local section_id = nil
	uci:foreach("clientstatus", "device", function(s)
		if s.mac and s.mac:upper() == mac then
			section_id = s[".name"]
			return false
		end
	end)

	if hostname then
		if section_id then
			uci:set("clientstatus", section_id, "hostname", hostname)
		else
			section_id = uci:add("clientstatus", "device")
			uci:set("clientstatus", section_id, "mac", mac)
			uci:set("clientstatus", section_id, "hostname", hostname)
		end
	else
		if section_id then
			uci:delete("clientstatus", section_id)
		end
	end

	uci:save("clientstatus")
	uci:commit("clientstatus")

	http.prepare_content("application/json")
	http.write_json({
		ok       = true,
		mac      = mac,
		hostname = hostname or ""
	})
end

-- ─── Reset client data ────────────────────────────────

function action_reset()
	nixio.fs.unlink("/tmp/clientstatus")
	nixio.fs.unlink("/tmp/clientstatus.state")

	local pid_f = io.open("/tmp/clientstatus.pid", "r")
	if pid_f then
		local pid = pid_f:read("*n")
		pid_f:close()
		if pid and pid > 0 then
			pcall(nixio.kill, pid, 10)
		end
	end

	luci.http.prepare_content("application/json")
	luci.http.write_json({ ok = true })
end
