-- Copyright 2024 luci-app-sxray
-- Licensed to the public under the MIT License.

local http = require "luci.http"
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local fs = require "nixio.fs"
local sxray = require "luci.model.sxray"
local i18n = require "luci.i18n"
local util = require "luci.util"
local api = require "luci.sxray.api"
local appname = "sxray"
local jsonStringify = luci.jsonc.stringify
local jsonParse = luci.jsonc.parse

module("luci.controller.sxray", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/sxray") then
		return
	end

	entry({"admin", "services", "sxray"},
		firstchild(), _("SXray")).dependent = false

	entry({"admin", "services", "sxray", "global"},
		cbi("sxray/main"), _("Global Settings"), 1)

	entry({"admin", "services", "sxray", "inbounds"},
		arcombine(cbi("sxray/inbound-list"), cbi("sxray/inbound-detail")),
		_("Inbound"), 2).leaf = true

	entry({"admin", "services", "sxray", "outbounds"},
		arcombine(cbi("sxray/outbound-list"), cbi("sxray/outbound-detail")),
		_("Outbound"), 5).leaf = true

	entry({"admin", "services", "sxray", "dns"},
		cbi("sxray/dns"), _("DNS"), 6)

	entry({"admin", "services", "sxray", "routing"},
		arcombine(cbi("sxray/routing"), cbi("sxray/routing-rule-detail")),
		_("Routing"), 7)

	entry({"admin", "services", "sxray", "policy"},
		arcombine(cbi("sxray/policy"), cbi("sxray/policy-level-detail")),
		_("Policy"), 8)

	entry({"admin", "services", "sxray", "reverse"},
		cbi("sxray/reverse"), _("Reverse"), 9)

	entry({"admin", "services", "sxray", "transparent-proxy"},
		cbi("sxray/transparent-proxy"), _("Transparent Proxy"), 10)

	entry({"admin", "services", "sxray", "about"},
		form("sxray/about"), _("About"), 11)

	entry({"admin", "services", "sxray", "routing", "rules"},
		cbi("sxray/routing-rule-detail")).leaf = true

	entry({"admin", "services", "sxray", "policy", "levels"},
		cbi("sxray/policy-level-detail")).leaf = true

	entry({"admin", "services", "sxray", "status"}, call("action_status"))

	entry({"admin", "services", "sxray", "version"}, call("action_version"))

	entry({"admin", "services", "sxray", "check-version"},
		call("action_check_version")).leaf = true

	entry({"admin", "services", "sxray", "list-status"},
		call("list_status")).leaf = true

	entry({"admin", "services", "sxray", "list-update"}, call("list_update"))

	entry({"admin", "services", "sxray", "import", "parse"},
		call("action_import_parse")).leaf = true

	entry({"admin", "services", "sxray", "import", "save"},
		call("action_import_save")).leaf = true

	entry({"admin", "services", "sxray", "import", "fetch"},
		call("action_import_fetch")).leaf = true

end

function action_status()
	local running = false

	local pid = util.trim(fs.readfile("/var/run/sxray.main.pid") or "")

	if pid ~= "" then
		local core_type = uci:get("sxray", "main", "core_type") or "xray"
		local file
		if core_type == "xray" then
			file = uci:get("sxray", "main", "xray_file") or ""
		else
			file = uci:get("sxray", "main", "sing_box_file") or ""
		end
		if file ~= "" then
			local file_name = fs.basename(file)
			running = sys.call("pidof %s 2>/dev/null | grep -q %s" % { file_name, pid }) == 0
		end
	end

	http.prepare_content("application/json")
	http.write_json({
		running = running
	})
end

local function get_core_version(file, core_type)
	if not file or file == "" then
		return nil, "Core file path is empty"
	end
	if not fs.stat(file) then
		return nil, "Core file not found"
	end
	if not fs.access(file, "rwx", "rx", "rx") then
		fs.chmod(file, 755)
	end

	local version
	local output

	if core_type == "xray" then
		output = util.trim(sys.exec(file .. " version 2>&1"))
		if output and output ~= "" then
			version = output:match("Xray%s+(%S+)") or output:match("Version:%s*(%S+)") or output:match("(%d+%.%d+%.%d+)")
		end
	else
		output = util.trim(sys.exec(file .. " version 2>&1"))
		if output and output ~= "" then
			version = output:match("sing%-box%s+version%s+(%S+)") or output:match("(%d+%.[%d%.]+)")
		end
	end

	if version and version ~= "" and not version:find("error", 1, true) and not version:find("fatal", 1, true) then
		return version, nil
	end
	return nil, "Can't get core version"
end

function action_version()
	local core_type = uci:get("sxray", "main", "core_type") or "xray"
	local xray_file = uci:get("sxray", "main", "xray_file") or ""
	local sing_box_file = uci:get("sxray", "main", "sing_box_file") or ""

	if xray_file == "" then
		xray_file = "/usr/bin/xray"
	end
	if sing_box_file == "" then
		sing_box_file = "/usr/bin/sing-box"
	end

	local xray_version, xray_error = get_core_version(xray_file, "xray")
	local sing_box_version, sing_box_error = get_core_version(sing_box_file, "sing-box")

	http.prepare_content("application/json")
	http.write_json({
		core_type = core_type,
		xray = {
			valid = xray_version ~= nil,
			version = xray_version or "",
			message = xray_error or ""
		},
		sing_box = {
			valid = sing_box_version ~= nil,
			version = sing_box_version or "",
			message = sing_box_error or ""
		}
	})
end

function action_check_version()
	local file = http.formvalue("file") or ""
	local core_type = http.formvalue("core_type") or "xray"

	local version, error_msg = get_core_version(file, core_type)

	http.prepare_content("application/json")
	http.write_json({
		valid = version ~= nil,
		version = version or "",
		message = error_msg or ""
	})
end

function list_status(list_type)
	if list_type == "chnroute" then
		http.prepare_content("application/json")
		http.write_json(sxray.get_routelist_status())
	elseif list_type == "gfwlist" then
		http.prepare_content("application/json")
		http.write_json(sxray.get_gfwlist_status())
	else
		http.status(500, "Bad address")
	end
end

function list_update()
	local type = http.formvalue("type")

	if type == "chnroute" then
		local chnroute_result, chnroute6_result = sxray.generate_routelist()
		http.prepare_content("application/json")
		http.write_json({
			chnroute = chnroute_result,
			chnroute6 = chnroute6_result
		})
	elseif type == "gfwlist" then
		local result = sxray.generate_gfwlist()
		http.prepare_content("application/json")
		http.write_json({
			gfwlist = result
		})
	else
		http.status(500, "Bad address")
	end
end

function action_import_parse()
	local content = http.formvalue("content")
	local format = http.formvalue("format") or "auto"
	local core_type = uci:get("sxray", "main", "core_type") or "xray"

	local result = {
		success = false,
		message = "",
		data = nil
	}

	if not content or content == "" then
		result.message = i18n.translate("Please provide configuration content")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	local import_util = require "luci.sxray.util_import"

	if format == "auto" then
		format = import_util.detect_format(content)
	end

	local parse_result, err_msg = import_util.parse_config(content, format, core_type)

	if parse_result then
		result.success = true
		result.data = parse_result
		result.format = format
	else
		result.message = err_msg or i18n.translate("Failed to parse configuration")
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_import_save()
	local config_data = http.formvalue("config_data")

	local result = {
		success = false,
		message = ""
	}

	if not config_data or config_data == "" then
		result.message = i18n.translate("No configuration data provided")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	local data = jsonParse(config_data)
	if not data then
		result.message = i18n.translate("Invalid configuration data format")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	local import_util = require "luci.sxray.util_import"
	local save_result, err_msg = import_util.save_config(data)

	if save_result then
		result.success = true
		result.message = i18n.translate("Configuration imported successfully")
	else
		result.message = err_msg or i18n.translate("Failed to save configuration")
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_import_fetch()
	local url = http.formvalue("url")

	local result = {
		success = false,
		content = "",
		error = ""
	}

	if not url or url == "" then
		result.error = i18n.translate("Please provide URL")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	if not url:match("^https?://") then
		result.error = i18n.translate("Invalid URL format")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	local content = util.trim(sys.exec('curl -sL --connect-timeout 10 --max-time 30 "%s" 2>/dev/null' % { url }))

	if content and content ~= "" then
		result.success = true
		result.content = content
	else
		result.error = i18n.translate("Failed to download content from URL")
	end

	http.prepare_content("application/json")
	http.write_json(result)
end
