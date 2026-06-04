module("luci.controller.singbox_server", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/singbox_server") then
		return
	end

	entry({"admin", "vpn"}, firstchild(), _("VPN"), 45).dependent = false

	entry({"admin", "vpn", "singbox-server"}, cbi("singbox_server/client"), _("SingBox服务端"), 60).dependent = true
	entry({"admin", "vpn", "singbox-server", "edit"}, cbi("singbox_server/server"), nil).leaf = true
	entry({"admin", "vpn", "singbox-server", "status"}, call("action_status")).leaf = true
	entry({"admin", "vpn", "singbox-server", "log"}, call("action_log")).leaf = true
	entry({"admin", "vpn", "singbox-server", "clear_log"}, call("action_clear_log")).leaf = true
	entry({"admin", "vpn", "singbox-server", "start"}, call("action_start")).leaf = true
	entry({"admin", "vpn", "singbox-server", "stop"}, call("action_stop")).leaf = true
end

local function shellquote(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

function action_status()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local status = {}
	uci:foreach("singbox_server", "server", function(s)
		local sid = s[".name"]
		local cmd = "ps -w | grep " .. shellquote("[s]ing-box run -c /tmp/etc/singbox_server/" .. sid .. ".json") .. " >/dev/null 2>&1"
		status[sid] = (luci.sys.call(cmd) == 0)
	end)
	http.prepare_content("application/json")
	http.write_json(status)
end

function action_log()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	local sid = http.formvalue("sid") or "main"
	local path = sid == "main" and "/tmp/log/singbox_server.log" or ("/tmp/log/singbox_server_" .. sid .. ".log")
	local content = fs.readfile(path) or ""
	http.prepare_content("text/plain; charset=utf-8")
	http.write(content)
end

function action_clear_log()
	local http = require "luci.http"
	local sid = http.formvalue("sid") or "main"
	local path = sid == "main" and "/tmp/log/singbox_server.log" or ("/tmp/log/singbox_server_" .. sid .. ".log")
	luci.sys.call("cat /dev/null > " .. shellquote(path))
	http.prepare_content("application/json")
	http.write_json({code = 0})
end

function action_start()
	local http = require "luci.http"
	luci.sys.call("/etc/init.d/singbox_server restart >/dev/null 2>&1 &")
	http.redirect(luci.dispatcher.build_url("admin/vpn/singbox-server"))
end

function action_stop()
	local http = require "luci.http"
	luci.sys.call("/etc/init.d/singbox_server stop >/dev/null 2>&1 &")
	http.redirect(luci.dispatcher.build_url("admin/vpn/singbox-server"))
end
