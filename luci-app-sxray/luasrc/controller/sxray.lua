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

	entry({"admin", "services", "sxray", "check-version"}, call("action_check_version"))

	entry({"admin", "services", "sxray", "list-status"},
		call("list_status")).leaf = true

	entry({"admin", "services", "sxray", "list-update"}, call("list_update"))

	entry({"admin", "services", "sxray", "import", "parse"},
		call("action_import_parse")).leaf = true

	entry({"admin", "services", "sxray", "import", "save"},
		call("action_import_save")).leaf = true

	entry({"admin", "services", "sxray", "import", "fetch"},
		call("action_import_fetch")).leaf = true

	entry({"admin", "services", "sxray", "import", "fetch_and_parse"},
		call("action_import_fetch_and_parse")).leaf = true

	entry({"admin", "services", "sxray", "import", "backup"},
		call("action_backup_create")).leaf = true

	entry({"admin", "services", "sxray", "import", "restore"},
		call("action_backup_restore")).leaf = true

	entry({"admin", "services", "sxray", "import", "list_backups"},
		call("action_backup_list")).leaf = true

	entry({"admin", "services", "sxray", "import", "delete_backup"},
		call("action_backup_delete")).leaf = true


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

function action_version()
	local core_type = uci:get("sxray", "main", "core_type") or "xray"
	local xray_file = uci:get("sxray", "main", "xray_file") or ""
	local sing_box_file = uci:get("sxray", "main", "sing_box_file") or ""

	local result = {}

	result.xray = get_core_version_info(xray_file, "xray")
	result.sing_box = get_core_version_info(sing_box_file, "sing-box")

	http.prepare_content("application/json")
	http.write_json(result)
end

function get_core_version_info(file, core_type)
	if file == "" then
		return {
			valid = false,
			message = i18n.translate("Core file path is empty")
		}
	elseif not fs.stat(file) then
		return {
			valid = false,
			message = i18n.translate("Core file not found")
		}
	else
		if not fs.access(file, "rwx", "rx", "rx") then
			fs.chmod(file, 755)
		end

		local version
		local cmd
		if core_type == "xray" then
			cmd = "%s version 2>&1" % file
			version = util.trim(sys.exec(cmd))
			if version ~= "" then
				version = version:match("Xray (%S+)") or version:match("Version:%s*(%S+)") or version
			end
		else
			cmd = "%s version 2>&1" % file
			version = util.trim(sys.exec(cmd))
			if version ~= "" then
				version = version:match("sing%-box version (%S+)") or version:match("version (%S+)") or version
			end
		end

		if version and version ~= "" and not version:find("error", 1, true) and not version:find("fatal", 1, true) then
			return {
				valid = true,
				version = version
			}
		else
			return {
				valid = false,
				message = i18n.translate("Can't get core version")
			}
		end
	end
end

function action_check_version()
	local file = http.formvalue("file") or ""
	local core_type = http.formvalue("core_type") or "xray"

	local info

	if file == "" then
		info = {
			valid = false,
			message = i18n.translate("Core file path is empty")
		}
	elseif not fs.stat(file) then
		info = {
			valid = false,
			message = i18n.translate("Core file not found")
		}
	else
		if not fs.access(file, "rwx", "rx", "rx") then
			fs.chmod(file, 755)
		end

		local version
		local cmd
		if core_type == "xray" then
			cmd = "%s version 2>&1" % file
			version = util.trim(sys.exec(cmd))
			if version ~= "" then
				version = version:match("Xray (%S+)") or version:match("Version:%s*(%S+)") or version
			end
		else
			cmd = "%s version 2>&1" % file
			version = util.trim(sys.exec(cmd))
			if version ~= "" then
				version = version:match("sing%-box version (%S+)") or version:match("version (%S+)") or version
			end
		end

		if version and version ~= "" and not version:find("error", 1, true) and not version:find("fatal", 1, true) then
			info = {
				valid = true,
				version = version
			}
		else
			info = {
				valid = false,
				message = i18n.translate("Can't get core version")
			}
		end
	end

	http.prepare_content("application/json")
	http.write_json(info)
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

	local result = {
		success = false,
		message = "",
		data = nil,
		format_detected = "",
		suggestions = {},
		debug = {}
	}

	if not content or content == "" then
		result.message = i18n.translate("Please provide configuration content")
		result.error_code = "EMPTY_CONTENT"
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- 修复换行符问题：确保所有换行符都是正确的 \n
	-- 处理可能的换行符丢失问题
	local original_content = content
	content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
	
	-- 如果内容看起来是 URI 列表但没有换行符，尝试在合适的位置添加换行符
	if not content:find("\n") and (content:find("vless://") or content:find("vmess://") or content:find("trojan://") or content:find("ss://")) then
		-- 在每个协议前添加换行符
		content = content:gsub("(vless://)", "\n%1"):gsub("(vmess://)", "\n%1"):gsub("(trojan://)", "\n%1"):gsub("(ss://)", "\n%1"):gsub("(ssr://)", "\n%1")
		-- 移除开头可能的换行符
		content = content:gsub("^\n", "")
	end

	-- Debug info
	result.debug.content_length = #content
	result.debug.content_preview = content:sub(1, 200)
	result.debug.original_length = #original_content
	result.debug.has_newline = (content:find("\n") ~= nil)

	local import_util = require "luci.sxray.util_import"

	if format == "auto" then
		format = import_util.detect_format(content)
		result.format_detected = format
		result.debug.detected_format = format
		
		-- 如果检测失败，尝试直接强制作为 uri_list 解析
		if format == "unknown" then
			-- 检查是否有协议标志
			if content:find("vless://") or content:find("vmess://") or content:find("trojan://") or content:find("ss://") then
				format = "uri_list"
				result.debug.fallback_to_uri_list = true
			end
		end
	end

	if format == "unknown" then
		result.message = i18n.translate("Unable to detect configuration format. Supported formats: JSON, YAML, XML, URI list")
		result.error_code = "UNKNOWN_FORMAT"
		table.insert(result.suggestions, i18n.translate("Check if the content is a valid configuration file"))
		table.insert(result.suggestions, i18n.translate("Try manually selecting the correct format"))
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	local parse_result, err_msg = import_util.parse_config(content, format)

	if parse_result then
		result.success = true
		result.data = parse_result
		result.format = format
		-- Calculate item count from outbounds array
		if parse_result.outbounds then
			result.item_count = #parse_result.outbounds
		elseif type(parse_result) == "table" then
			result.item_count = #parse_result
		else
			result.item_count = 0
		end
		-- Include per-item parse errors if any
		if parse_result.errors and #parse_result.errors > 0 then
			result.parse_errors = parse_result.errors
			result.error_count = #parse_result.errors
		end
		-- Check for duplicates
		if parse_result.outbounds and #parse_result.outbounds > 0 then
			local import_util = require "luci.sxray.util_import"
			local dup_info = import_util.check_duplicates(parse_result.outbounds)
			if dup_info and next(dup_info) then
				result.duplicates = dup_info
			end
		end
	else
		result.message = err_msg or i18n.translate("Failed to parse configuration")
		result.error_code = "PARSE_ERROR"
		result.debug.parse_error = err_msg
		
		-- Provide helpful suggestions based on error type
		if result.message:find("invalid") or result.message:find("syntax") then
			table.insert(result.suggestions, i18n.translate("Check for syntax errors in the configuration"))
			table.insert(result.suggestions, i18n.translate("Ensure all brackets and quotes are properly closed"))
		elseif result.message:find("empty") then
			table.insert(result.suggestions, i18n.translate("The configuration appears to be empty"))
		else
			table.insert(result.suggestions, i18n.translate("Verify the configuration content is complete and valid"))
		end
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_import_save()
	local config_data = http.formvalue("config_data")
	local skip_duplicates = http.formvalue("skip_duplicates")

	local result = {
		success = false,
		message = "",
		imported_count = 0,
		skipped_count = 0,
		duplicate_count = 0,
		details = {}
	}

	if not config_data or config_data == "" then
		result.message = i18n.translate("No configuration data provided")
		result.error_code = "NO_DATA"
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	local data = jsonParse(config_data)
	if not data then
		result.message = i18n.translate("Invalid configuration data format")
		result.error_code = "INVALID_FORMAT"
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Normalize data structure: support both {outbounds:[...]} and plain array
	if not data.outbounds and type(data) == "table" then
		if #data > 0 then
			data = { outbounds = data }
		end
	end

	local import_util = require "luci.sxray.util_import"
	local skip_dup = (skip_duplicates == "1" or skip_duplicates == "true")
	local save_result, save_info = import_util.save_config(data, skip_dup)

	if save_result then
		result.success = true
		result.message = i18n.translate("Configuration imported successfully")
		if type(save_info) == "table" then
			result.imported_count = save_info.imported or 0
			result.skipped_count = save_info.skipped or 0
			result.duplicate_count = save_info.duplicated or 0
			result.details = save_info.details or {}
		end
	else
		result.message = save_info or i18n.translate("Failed to save configuration")
		result.error_code = "SAVE_ERROR"
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_import_fetch()
	local url = http.formvalue("url")
	local timeout = tonumber(http.formvalue("timeout")) or 30

	local result = {
		success = false,
		content = "",
		error = "",
		error_code = "",
		content_type = "",
		size = 0
	}

	if not url or url == "" then
		result.error = i18n.translate("Please provide URL")
		result.error_code = "NO_URL"
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Validate URL format
	if not url:match("^https?://") then
		result.error = i18n.translate("Invalid URL format. URL must start with http:// or https://")
		result.error_code = "INVALID_URL"
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Validate timeout value
	if timeout < 5 or timeout > 120 then
		timeout = math.max(5, math.min(120, timeout))
	end

	-- Download content from URL with enhanced error handling
	-- Use a unique separator to reliably extract HTTP code and content type
	local cmd = 'curl -sL --connect-timeout 10 --max-time %d -w "___CURL_META_START___\\n%%{http_code}\\n%%{content_type}\\n___CURL_META_END___" "%s" 2>/dev/null' % {timeout, url}
	local output = util.trim(sys.exec(cmd))
	
	if output and output ~= "" then
		-- Extract metadata using the unique markers
		local meta_start = output:find("___CURL_META_START___", 1, true)
		local meta_end = output:find("___CURL_META_END___", 1, true)
		
		local content, http_code, content_type
		
		if meta_start and meta_end and meta_end > meta_start then
			-- Content is everything before the meta marker
			content = output:sub(1, meta_start - 1)
			-- Metadata is between the markers
			local meta = output:sub(meta_start, meta_end - 1)
			local meta_lines = {}
			for line in meta:gmatch("[^\r\n]+") do
				line = util.trim(line)
				if line ~= "" and line ~= "___CURL_META_START___" then
					table.insert(meta_lines, line)
				end
			end
			if #meta_lines >= 2 then
				http_code = meta_lines[1]
				content_type = meta_lines[2]
			end
		else
			-- Fallback: try to parse last two lines
			local lines = {}
			for line in output:gmatch("[^\r\n]+") do
				table.insert(lines, line)
			end
			if #lines >= 2 then
				content_type = lines[#lines]
				http_code = lines[#lines-1]
				if #lines > 2 then
					content = table.concat(lines, "\n", 1, #lines-2)
				else
					content = ""
				end
			end
		end
		
		result.content_type = content_type or ""
		result.size = content and #content or 0
		
		if http_code == "200" and content and content ~= "" then
			-- Remove BOM if present
			content = content:gsub("^\xEF\xBB\xBF", "")
			-- Detect Base64-encoded subscription content
			local is_subscription = false
			if not content:find("://") and not content:find("^{") then
				local decoded = api.base64Decode(content:gsub("%s+", ""))
				if decoded and decoded ~= "" and decoded:find("://") then
					content = decoded
					is_subscription = true
				end
			end
			result.success = true
			result.content = content
			result.is_subscription = is_subscription
		elseif http_code == "404" then
			result.error = i18n.translate("Resource not found (HTTP 404)")
			result.error_code = "NOT_FOUND"
		elseif http_code == "403" then
			result.error = i18n.translate("Access forbidden (HTTP 403)")
			result.error_code = "FORBIDDEN"
		elseif http_code == "500" then
			result.error = i18n.translate("Server error (HTTP 500)")
			result.error_code = "SERVER_ERROR"
		elseif tonumber(http_code) and tonumber(http_code) >= 400 then
			result.error = i18n.translate("HTTP error: ") .. http_code
			result.error_code = "HTTP_ERROR"
		else
			result.error = i18n.translate("Failed to download content")
			result.error_code = "DOWNLOAD_FAILED"
		end
	else
		result.error = i18n.translate("Failed to connect to server. Check network connection and URL.")
		result.error_code = "CONNECTION_ERROR"
	end
	http.prepare_content("application/json")
	http.write_json(result)
end

function action_import_fetch_and_parse()
	local status, err = pcall(function()
		local url = http.formvalue("url")
		local timeout = tonumber(http.formvalue("timeout")) or 30
		local core_type = http.formvalue("core_type") or "auto"

		local result = {
			success = false,
			message = "",
			data = nil,
			format = "",
			item_count = 0,
			errors = {},
			debug = {}
		}

		if not url or url == "" then
			result.message = i18n.translate("Please provide URL")
			result.error_code = "NO_URL"
			http.prepare_content("application/json")
			http.write_json(result)
			return
		end

		if not url:match("^https?://") then
			result.message = i18n.translate("Invalid URL format. URL must start with http:// or https://")
			result.error_code = "INVALID_URL"
			http.prepare_content("application/json")
			http.write_json(result)
			return
		end

		if timeout < 5 or timeout > 120 then
			timeout = math.max(5, math.min(120, timeout))
		end

		local cmd = 'curl -sL --connect-timeout 10 --max-time %d -w "___CURL_META_START___\\n%%{http_code}\\n%%{content_type}\\n___CURL_META_END___" "%s" 2>/dev/null' % {timeout, url}
		local output = util.trim(sys.exec(cmd))

		if not output or output == "" then
			result.message = i18n.translate("Failed to connect to server. Check network connection and URL.")
			result.error_code = "CONNECTION_ERROR"
			http.prepare_content("application/json")
			http.write_json(result)
			return
		end

		local meta_start = output:find("___CURL_META_START___", 1, true)
		local meta_end = output:find("___CURL_META_END___", 1, true)
		local content = ""
		local http_code = ""
		local content_type = ""

		if meta_start and meta_end and meta_end > meta_start then
			content = output:sub(1, meta_start - 1)
			local meta = output:sub(meta_start, meta_end - 1)
			local meta_lines = {}
			for line in meta:gmatch("[^\r\n]+") do
				line = util.trim(line)
				if line ~= "" and line ~= "___CURL_META_START___" then
					table.insert(meta_lines, line)
				end
			end
			if #meta_lines >= 2 then
				http_code = meta_lines[1]
				content_type = meta_lines[2]
			end
		else
			local lines = {}
			for line in output:gmatch("[^\r\n]+") do
				table.insert(lines, line)
			end
			if #lines >= 2 then
				content_type = lines[#lines]
				http_code = lines[#lines-1]
				if #lines > 2 then
					content = table.concat(lines, "\n", 1, #lines-2)
				else
					content = ""
				end
			end
		end

		result.debug.http_code = http_code
		result.debug.content_type = content_type

		if http_code == "200" and content and content ~= "" then
			content = content:gsub("^\xEF\xBB\xBF", "")

			local is_subscription = false
			if not content:find("://") and not content:find("^{") then
				local cleaned = content:gsub("%s+", "")
				local decoded = api.base64Decode(cleaned)
				if decoded and decoded ~= "" and decoded:find("://") then
					content = decoded
					is_subscription = true
				end
			end

			result.debug.is_subscription = is_subscription
			result.debug.content_length = #content
			result.debug.content_preview = content:sub(1, 100)

			if is_subscription then
				content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
			end

			local import_util = require "luci.sxray.util_import"
			local format = "auto"
			format = import_util.detect_format(content)
			result.format = format
			result.debug.detected_format = format

			if format == "unknown" then
				if content:find("vless://") or content:find("vmess://") or content:find("trojan://") or content:find("ss://") then
					format = "uri_list"
					result.debug.fallback_format = "uri_list"
				end
			end

			if format == "unknown" then
				result.message = i18n.translate("Unable to detect configuration format")
				http.prepare_content("application/json")
				http.write_json(result)
				return
			end

			local parse_result, err_msg = import_util.parse_config(content, format)

			if parse_result then
				result.success = true
				result.data = parse_result
				result.format = format
				if parse_result.outbounds then
					result.item_count = #parse_result.outbounds
				elseif type(parse_result) == "table" then
					result.item_count = #parse_result
				end
				if parse_result.errors and #parse_result.errors > 0 then
					result.errors = parse_result.errors
				end
			else
				result.message = err_msg or i18n.translate("Failed to parse configuration")
				result.debug.parse_error = err_msg
			end
		elseif http_code == "404" then
			result.message = i18n.translate("Resource not found (HTTP 404)")
		elseif http_code == "403" then
			result.message = i18n.translate("Access forbidden (HTTP 403)")
		elseif http_code == "500" then
			result.message = i18n.translate("Server error (HTTP 500)")
		elseif tonumber(http_code) and tonumber(http_code) >= 400 then
			result.message = i18n.translate("HTTP error: ") .. http_code
		else
			result.message = i18n.translate("Failed to download content")
		end

		http.prepare_content("application/json")
		http.write_json(result)
	end)

	if not status then
		local error_result = {
			success = false,
			message = "Internal server error: " .. tostring(err),
			debug = {
				error = tostring(err)
			}
		}
		http.prepare_content("application/json")
		http.write_json(error_result)
	end
end

function action_backup_create()
	local result = {
		success = false,
		message = "",
		filename = ""
	}

	-- Create backup directory if it doesn't exist
	local backup_dir = "/etc/sxray/backup"
	if not fs.stat(backup_dir) then
		fs.mkdirr(backup_dir)
	end

	-- Generate backup filename with timestamp
	local timestamp = os.date("%Y%m%d_%H%M%S")
	local backup_file = backup_dir .. "/backup_" .. timestamp .. ".json"

	-- Read current configuration
	local config_data = {}
	local sections = {"main", "inbound", "outbound", "dns", "routing", "policy", "reverse", "transparent-proxy"}

	for _, section in ipairs(sections) do
		config_data[section] = {}
		uci:foreach("sxray", section, function(s) 
			config_data[section][s[".name"]] = s 
		end)
	end

	-- Write backup file
	local backup_content = jsonStringify(config_data)
	if backup_content then
		local file = io.open(backup_file, "w")
		if file then
			file:write(backup_content)
			file:close()
			result.success = true
			result.message = i18n.translate("Backup created successfully")
			result.filename = backup_file
		else
			result.message = i18n.translate("Failed to create backup file")
		end
	else
		result.message = i18n.translate("Failed to serialize configuration")
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_backup_restore()
	local filename = http.formvalue("filename")
	local result = {
		success = false,
		message = ""
	}

	if not filename or filename == "" then
		result.message = i18n.translate("Please provide backup file path")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Check if backup file exists
	if not fs.stat(filename) then
		result.message = i18n.translate("Backup file not found")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Read backup file
	local backup_content = fs.readfile(filename)
	if not backup_content or backup_content == "" then
		result.message = i18n.translate("Failed to read backup file")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Parse backup content
	local config_data = jsonParse(backup_content)
	if not config_data then
		result.message = i18n.translate("Invalid backup file format")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Restore configuration
	uci:foreach("sxray", "@", function(s) 
		uci:delete("sxray", s[".name"])
	end)

	for section, items in pairs(config_data) do
		for name, values in pairs(items) do
			if name ~= ".name" then
				uci:set("sxray", name, section)
				for k, v in pairs(values) do
					if k ~= ".name" and k ~= ".type" then
						uci:set("sxray", name, k, v)
					end
				end
			end
		end
	end

	uci:commit("sxray")
	result.success = true
	result.message = i18n.translate("Configuration restored successfully")

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_backup_list()
	local backup_dir = "/etc/sxray/backup"
	local result = {
		success = false,
		backups = {}
	}

	if fs.stat(backup_dir) then
		local files = fs.dir(backup_dir)
		if files then
			for file in files do
				if file:match("^backup_%d+_%d+%.json$") then
					local file_path = backup_dir .. "/" .. file
					local stat = fs.stat(file_path)
					if stat then
						local backup = {
							filename = file_path,
							name = file,
							size = string.format("%.1f KB", stat.size / 1024),
							date = os.date("%Y-%m-%d %H:%M", stat.mtime)
						}
						table.insert(result.backups, backup)
					end
				end
			end
		end
	end

	-- Sort backups by timestamp (newest first)
	table.sort(result.backups, function(a, b) 
		return a.filename > b.filename 
	end)

	result.success = true
	http.prepare_content("application/json")
	http.write_json(result)
end

function action_backup_delete()
	local filename = http.formvalue("filename")
	local result = {
		success = false,
		message = ""
	}

	if not filename or filename == "" then
		result.message = i18n.translate("Please provide backup file path")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Check if backup file exists and is in backup directory
	if not fs.stat(filename) or not filename:match("^/etc/sxray/backup/") then
		result.message = i18n.translate("Invalid backup file path")
		http.prepare_content("application/json")
		http.write_json(result)
		return
	end

	-- Delete backup file
	local success = fs.unlink(filename)
	if success then
		result.success = true
		result.message = i18n.translate("Backup deleted successfully")
	else
		result.message = i18n.translate("Failed to delete backup file")
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

