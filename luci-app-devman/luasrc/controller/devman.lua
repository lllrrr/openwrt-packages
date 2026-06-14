module("luci.controller.devman", package.seeall)

function index()
	page = entry({"admin", "network", "devman"}, template("devman/overview"), _("设备管理"), 5)
	page.i18n = "devman"
	entry({"admin", "network", "devman", "api_devices"}, call("api_devices")).sysauth = false
	entry({"admin", "network", "devman", "api_block"}, call("api_block")).sysauth = false
	entry({"admin", "network", "devman", "api_limit"}, call("api_limit")).sysauth = false
end

-- Helper: POST JSON to Go backend via temp file (avoids shell injection)
local function curl_post(path, body)
	local f = io.open("/tmp/devman_req.json", "w")
	if f then f:write(body); f:close() end
	os.execute("curl -s -X POST http://127.0.0.1:9999" .. path .. " -d @/tmp/devman_req.json &")
end

-- Helper: escape string for JSON (handle \, ", newlines)
local function json_escape(s)
	return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"))
end

function api_devices()
	local http = require "luci.http"
	local f = io.popen("curl -s http://127.0.0.1:9999/api/devices")
	local data = f:read("*a") or "[]"
	f:close()
	http.prepare_content("application/json")
	http.write(data)
end

function api_block()
	local http = require "luci.http"
	local dev = tonumber(http.formvalue("device_id"))
	local block = http.formvalue("block")
	if dev then
		local body = string.format('{"device_id":%d,"block":%s}', dev, (block == "1" and "true" or "false"))
		curl_post("/api/block", body)
	end
	http.prepare_content("application/json")
	http.write('{"ok":true}')
end

function api_limit()
	local http = require "luci.http"
	local dev = tonumber(http.formvalue("device_id"))
	local limit = tonumber(http.formvalue("rate_limit")) or 0
	local limit_dn = tonumber(http.formvalue("rate_limit_down")) or -1
	local alias = http.formvalue("alias")
	if dev then
		local body_parts = { string.format('"device_id":%d,"rate_limit":%d,"rate_limit_down":%d', dev, limit, limit_dn) }
		if alias and alias ~= "" then
			body_parts[#body_parts + 1] = string.format('"alias":"%s"', json_escape(alias))
		end
		curl_post("/api/limit", "{" .. table.concat(body_parts, ",") .. "}")
	end
	http.prepare_content("application/json")
	http.write('{"ok":true}')
end
