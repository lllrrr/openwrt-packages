#!/usr/bin/lua

-- Copyright 2026 luci-app-sxray
-- Subscribe management script for sxray

require 'luci.util'
require 'luci.jsonc'
require 'luci.sys'
local appname = 'sxray'
local api = require("luci.sxray.api")
local datatypes = require "luci.cbi.datatypes"

local tinsert = table.insert
local ssub, slen, schar, sbyte, sformat, sgsub = string.sub, string.len, string.char, string.byte, string.format, string.gsub
local split = api.split
local jsonParse, jsonStringify = luci.jsonc.parse, luci.jsonc.stringify
local base64Decode = api.base64Decode
local UrlEncode = api.UrlEncode
local UrlDecode = api.UrlDecode
local uci = api.uci
local fs = api.fs
uci:revert(appname)

local has_singbox = api.finded_com("sing-box")
local has_xray = api.finded_com("xray")
local allowInsecure_default = nil

-- Get default core types from global_subscribe config
local ss_type_default = api.get_core("ss_type", {{has_singbox,"sing-box"},{has_xray,"xray"}})
local trojan_type_default = api.get_core("trojan_type", {{has_singbox,"sing-box"},{has_xray,"xray"}})
local vmess_type_default = api.get_core("vmess_type", {{has_xray,"xray"},{has_singbox,"sing-box"}})
local vless_type_default = api.get_core("vless_type", {{has_xray,"xray"},{has_singbox,"sing-box"}})
local hysteria2_type_default = api.get_core("hysteria2_type", {{has_singbox,"sing-box"},{has_xray,"xray"}})
local core_has = {
	["xray"] = has_xray, ["sing-box"] = has_singbox
}

local domain_strategy_default = uci:get(appname, "@global_subscribe[0]", "domain_strategy") or ""
local domain_strategy_node = ""

-- Filter keyword config
local filter_keyword_mode_default = uci:get(appname, "@global_subscribe[0]", "filter_keyword_mode") or "0"
local filter_keyword_discard_list_default = uci:get(appname, "@global_subscribe[0]", "filter_discard_list") or {}
local filter_keyword_keep_list_default = uci:get(appname, "@global_subscribe[0]", "filter_keep_list") or {}

local function is_filter_keyword(value)
	if filter_keyword_mode_default == "1" then
		for k,v in ipairs(filter_keyword_discard_list_default) do
			if value:find(v, 1, true) then return true end
		end
	elseif filter_keyword_mode_default == "2" then
		local result = true
		for k,v in ipairs(filter_keyword_keep_list_default) do
			if value:find(v, 1, true) then result = false end
		end
		return result
	elseif filter_keyword_mode_default == "3" then
		local result = false
		for k,v in ipairs(filter_keyword_discard_list_default) do
			if value:find(v, 1, true) then result = true end
		end
		for k,v in ipairs(filter_keyword_keep_list_default) do
			if value:find(v, 1, true) then result = false end
		end
		return result
	elseif filter_keyword_mode_default == "4" then
		local result = true
		for k,v in ipairs(filter_keyword_keep_list_default) do
			if value:find(v, 1, true) then result = false end
		end
		for k,v in ipairs(filter_keyword_discard_list_default) do
			if value:find(v, 1, true) then result = true end
		end
		return result
	end
	return false
end

local nodeResult = {}
local isDebug = false

local log = function(...)
	if isDebug == true then
		local result = os.date("%Y-%m-%d %H:%M:%S: ") .. table.concat({...}, " ")
		print(result)
	else
		api.log(...)
	end
end

-- Subscribe info (remaining traffic, expiry date)
local subscribe_info = {}
local function get_subscribe_info(cfgid, value)
	if type(cfgid) ~= "string" or cfgid == "" or type(value) ~= "string" then return end
	value = value:gsub("%s+", "")
	local date_patterns = {"套餐到期：(.+)", "过期时间：(.+)", "有效期至：(.+)", "到期时间：(.+)", "截止日期：(.+)"}
	local expired_date
	for _, p in ipairs(date_patterns) do expired_date = value:match(p) or expired_date end
	local rem_patterns = {"剩余流量：(.+)", "流量剩余：(.+)", "可用流量：(.+)", "套餐剩余：(.+)"}
	local rem_traffic
	for _, p in ipairs(rem_patterns) do rem_traffic = value:match(p) or rem_traffic end
	subscribe_info[cfgid] = subscribe_info[cfgid] or {expired_date = "", rem_traffic = ""}
	if expired_date then
		local function formatDate(str)
			local y, m, d = str:match("(%d%d%d%d)[-/]?(%d%d?)[-/]?(%d%d?)")
			if y and m and d then return y .. "." .. m .. "." .. d end
			return str
		end
		subscribe_info[cfgid]["expired_date"] = formatDate(expired_date)
	end
	if rem_traffic then
		subscribe_info[cfgid]["rem_traffic"] = rem_traffic
	end
end

-- Save a parsed outbound node to UCI
local function save_outbound_to_uci(outbound, add_mode, group)
	local section = uci:add(appname, "outbound")
	if not section then return nil end

	uci:set(appname, section, "type", outbound.type or "outbound")
	uci:set(appname, section, "protocol", outbound.protocol or "")
	uci:set(appname, section, "alias", outbound.alias or "Unnamed")
	uci:set(appname, section, "add_mode", tostring(add_mode))
	if group and group ~= "" and group ~= "default" then
		uci:set(appname, section, "group", group)
	end
	if outbound.core_type then
		uci:set(appname, section, "core_type", outbound.core_type)
	end

	-- Set domain_strategy for sing-box nodes
	if outbound.core_type == "sing-box" and domain_strategy_node and domain_strategy_node ~= "" then
		uci:set(appname, section, "domain_strategy", domain_strategy_node)
	end

	local protocol = outbound.protocol

	if protocol == "vmess" then
		if outbound.address then uci:set(appname, section, "s_vmess_address", outbound.address) end
		if outbound.port then uci:set(appname, section, "s_vmess_port", outbound.port) end
		if outbound.id then uci:set(appname, section, "s_vmess_user_id", outbound.id) end
		if outbound.alterId then uci:set(appname, section, "s_vmess_user_alter_id", outbound.alterId) end
		if outbound.security then uci:set(appname, section, "s_vmess_user_security", outbound.security) end
	elseif protocol == "vless" then
		if outbound.address then uci:set(appname, section, "s_vless_address", outbound.address) end
		if outbound.port then uci:set(appname, section, "s_vless_port", outbound.port) end
		if outbound.id then uci:set(appname, section, "s_vless_user_id", outbound.id) end
		if outbound.flow then uci:set(appname, section, "s_vless_flow", outbound.flow) end
		if outbound.encryption then uci:set(appname, section, "s_vless_encryption", outbound.encryption) end
	elseif protocol == "trojan" then
		if outbound.address then uci:set(appname, section, "s_trojan_address", outbound.address) end
		if outbound.port then uci:set(appname, section, "s_trojan_port", outbound.port) end
		if outbound.password then uci:set(appname, section, "s_trojan_password", outbound.password) end
	elseif protocol == "shadowsocks" then
		if outbound.address then uci:set(appname, section, "s_shadowsocks_address", outbound.address) end
		if outbound.port then uci:set(appname, section, "s_shadowsocks_port", outbound.port) end
		if outbound.method then uci:set(appname, section, "s_shadowsocks_method", outbound.method) end
		if outbound.password then uci:set(appname, section, "s_shadowsocks_password", outbound.password) end
	elseif protocol == "shadowsocksr" then
		if outbound.address then uci:set(appname, section, "s_ssr_address", outbound.address) end
		if outbound.port then uci:set(appname, section, "s_ssr_port", outbound.port) end
		if outbound.ssr_protocol then uci:set(appname, section, "s_ssr_protocol", outbound.ssr_protocol) end
		if outbound.method then uci:set(appname, section, "s_ssr_method", outbound.method) end
		if outbound.obfs then uci:set(appname, section, "s_ssr_obfs", outbound.obfs) end
		if outbound.password then uci:set(appname, section, "s_ssr_password", outbound.password) end
		if outbound.obfsParam then uci:set(appname, section, "s_ssr_obfs_param", outbound.obfsParam) end
		if outbound.protocolParam then uci:set(appname, section, "s_ssr_protocol_param", outbound.protocolParam) end
	elseif protocol == "hysteria" then
		if outbound.address then uci:set(appname, section, "s_hysteria_address", outbound.address) end
		if outbound.port then uci:set(appname, section, "s_hysteria_port", outbound.port) end
		if outbound.hysteria_auth_password then uci:set(appname, section, "s_hysteria_auth", outbound.hysteria_auth_password) end
		if outbound.hysteria_up_mbps then uci:set(appname, section, "s_hysteria_up_mbps", outbound.hysteria_up_mbps) end
		if outbound.hysteria_down_mbps then uci:set(appname, section, "s_hysteria_down_mbps", outbound.hysteria_down_mbps) end
		if outbound.hysteria_obfs then uci:set(appname, section, "s_hysteria_obfs", outbound.hysteria_obfs) end
		if outbound.hysteria_alpn then uci:set(appname, section, "s_hysteria_alpn", outbound.hysteria_alpn) end
	elseif protocol == "hysteria2" then
		if outbound.address then uci:set(appname, section, "s_hysteria2_address", outbound.address) end
		if outbound.port then uci:set(appname, section, "s_hysteria2_port", outbound.port) end
		if outbound.hysteria2_auth_password then uci:set(appname, section, "s_hysteria2_password", outbound.hysteria2_auth_password) end
		if outbound.hysteria2_obfs_password then uci:set(appname, section, "s_hysteria2_obfs_password", outbound.hysteria2_obfs_password) end
	elseif protocol == "tuic" then
		if outbound.address then uci:set(appname, section, "s_tuic_address", outbound.address) end
		if outbound.port then uci:set(appname, section, "s_tuic_port", outbound.port) end
		if outbound.id then uci:set(appname, section, "s_tuic_uuid", outbound.id) end
		if outbound.password then uci:set(appname, section, "s_tuic_password", outbound.password) end
		if outbound.tuic_congestion_control then uci:set(appname, section, "s_tuic_congestion_control", outbound.tuic_congestion_control) end
		if outbound.tuic_udp_relay_mode then uci:set(appname, section, "s_tuic_udp_relay_mode", outbound.tuic_udp_relay_mode) end
	elseif protocol == "wireguard" then
		if outbound.wireguard_secret_key then uci:set(appname, section, "s_wireguard_secret_key", outbound.wireguard_secret_key) end
		if outbound.address then uci:set(appname, section, "s_wireguard_endpoint", outbound.address .. ":" .. (outbound.port or "")) end
		if outbound.wireguard_peer_public_key then uci:set(appname, section, "s_wireguard_peer_public_key", outbound.wireguard_peer_public_key) end
		if outbound.wireguard_local_address then uci:set(appname, section, "s_wireguard_address", outbound.wireguard_local_address) end
		if outbound.wireguard_mtu then uci:set(appname, section, "s_wireguard_mtu", outbound.wireguard_mtu) end
		if outbound.wireguard_preshared_key then uci:set(appname, section, "s_wireguard_preshared_key", outbound.wireguard_preshared_key) end
	end

	-- Stream settings
	if outbound.network then uci:set(appname, section, "ss_network", outbound.network) end
	if outbound.headerType then uci:set(appname, section, "ss_tcp_header_type", outbound.headerType) end

	-- TLS
	if outbound.tls == "1" then
		if outbound.reality == "1" then
			uci:set(appname, section, "ss_security", "reality")
		elseif outbound.utls == "1" then
			uci:set(appname, section, "ss_security", "utls")
		else
			uci:set(appname, section, "ss_security", "tls")
		end
	else
		uci:set(appname, section, "ss_security", "none")
	end

	if outbound.serverName then uci:set(appname, section, "ss_tls_server_name", outbound.serverName) end
	if outbound.alpn then uci:set(appname, section, "ss_tls_alpn", outbound.alpn) end

	-- Handle allowInsecure: use per-node setting, or fallback to subscribe-level default
	local tls_insecure = outbound.tls_allowInsecure
	if (tls_insecure == nil or tls_insecure == "") and allowInsecure_default then
		tls_insecure = "1"
	end
	if tls_insecure then uci:set(appname, section, "ss_tls_allow_insecure", tls_insecure) end

	if outbound.fingerprint then uci:set(appname, section, "ss_tls_fingerprint", outbound.fingerprint) end

	-- Reality
	if outbound.realityPublicKey then uci:set(appname, section, "ss_reality_public_key", outbound.realityPublicKey) end
	if outbound.realityShortId then uci:set(appname, section, "ss_reality_short_id", outbound.realityShortId) end
	if outbound.realitySpiderX then uci:set(appname, section, "ss_reality_spider_x", outbound.realitySpiderX) end

	-- Transport-specific settings
	if outbound.network == "ws" then
		if outbound.host then
			uci:set(appname, section, "ss_websocket_headers", { "Host=" .. outbound.host })
		end
		if outbound.path then uci:set(appname, section, "ss_websocket_path", outbound.path) end
	elseif outbound.network == "http" or outbound.network == "h2" then
		if outbound.http_host then uci:set(appname, section, "ss_http_host", outbound.http_host) end
		if outbound.http_path then uci:set(appname, section, "ss_http_path", outbound.http_path) end
	elseif outbound.network == "grpc" then
		if outbound.grpc_serviceName then uci:set(appname, section, "ss_grpc_service_name", outbound.grpc_serviceName) end
	elseif outbound.network == "mkcp" or outbound.network == "kcp" then
		if outbound.mkcp_guise then uci:set(appname, section, "ss_kcp_header_type", outbound.mkcp_guise) end
		if outbound.mkcp_mtu then uci:set(appname, section, "ss_kcp_mtu", outbound.mkcp_mtu) end
		if outbound.mkcp_tti then uci:set(appname, section, "ss_kcp_tti", outbound.mkcp_tti) end
		if outbound.mkcp_uplinkCapacity then uci:set(appname, section, "ss_kcp_uplink_capacity", outbound.mkcp_uplinkCapacity) end
		if outbound.mkcp_downlinkCapacity then uci:set(appname, section, "ss_kcp_downlink_capacity", outbound.mkcp_downlinkCapacity) end
		if outbound.mkcp_readBufferSize then uci:set(appname, section, "ss_kcp_read_buffer_size", outbound.mkcp_readBufferSize) end
		if outbound.mkcp_writeBufferSize then uci:set(appname, section, "ss_kcp_write_buffer_size", outbound.mkcp_writeBufferSize) end
		if outbound.mkcp_seed then uci:set(appname, section, "ss_kcp_seed", outbound.mkcp_seed) end
	elseif outbound.network == "quic" then
		if outbound.quic_guise then uci:set(appname, section, "ss_quic_header_type", outbound.quic_guise) end
		if outbound.quic_security then uci:set(appname, section, "ss_quic_security", outbound.quic_security) end
		if outbound.quic_key then uci:set(appname, section, "ss_quic_key", outbound.quic_key) end
	elseif outbound.network == "xhttp" then
		if outbound.xhttp_host then uci:set(appname, section, "ss_xhttp_host", outbound.xhttp_host) end
		if outbound.xhttp_path then uci:set(appname, section, "ss_xhttp_path", outbound.xhttp_path) end
	elseif outbound.network == "httpupgrade" then
		if outbound.httpupgrade_host then uci:set(appname, section, "ss_httpupgrade_host", outbound.httpupgrade_host) end
		if outbound.httpupgrade_path then uci:set(appname, section, "ss_httpupgrade_path", outbound.httpupgrade_path) end
	end

	if outbound.tcp_fast_open then uci:set(appname, section, "ss_sockopt_tcp_fast_open", outbound.tcp_fast_open) end
	if outbound.tag then uci:set(appname, section, "tag", outbound.tag) end

	return section
end

-- Truncate (delete) subscription nodes by group
local function truncate_nodes(group)
	uci:foreach(appname, "outbound", function(node)
		if node.add_mode == "2" then
			if (not group) or (group:lower() == (node.group or ""):lower()) then
				uci:delete(appname, node['.name'])
			end
		end
	end)
	uci:foreach(appname, "subscribe_list", function(o)
		if (not group) or (group:lower() == (o.remark or ""):lower()) then
			uci:delete(appname, o['.name'], "md5")
		end
	end)
	api.uci_save(uci, appname, true)
end

-- Update nodes: clear old subscribed nodes and write new ones
local function update_node(manual)
	if next(nodeResult) == nil then
		log("没有可用的节点信息更新。")
		return
	end

	local group = {}
	for _, v in ipairs(nodeResult) do
		group[v["remark"]:lower()] = true
	end

	-- Delete old subscription nodes (add_mode=2) for these groups
	if manual == 0 and next(group) then
		uci:foreach(appname, "outbound", function(node)
			if node.add_mode == "2" and (node.group and group[node.group:lower()] == true) then
				uci:delete(appname, node['.name'])
			end
		end)
	end

	-- Write new nodes
	for _, v in ipairs(nodeResult) do
		local remark = v["remark"]
		local list = v["list"]
		for _, outbound in ipairs(list) do
			save_outbound_to_uci(outbound, 2, remark)
		end
	end

	-- Update subscribe info (traffic, expiry)
	for cfgid, info in pairs(subscribe_info) do
		for key, value in pairs(info) do
			if value ~= "" then
				uci:set(appname, cfgid, key, value)
			else
				uci:delete(appname, cfgid, key)
			end
		end
	end

	api.uci_save(uci, appname, true)

	if arg[3] == "cron" then
		if not fs.access("/var/lock/" .. appname .. ".lock") then
			luci.sys.call("touch /tmp/lock/" .. appname .. "_cron.lock")
		end
	end

	if manual ~= 1 then
		luci.sys.call("/etc/init.d/" .. appname .. " restart > /dev/null 2>&1 &")
	end
end

-- Parse subscription links using util_import
local function parse_link(raw, add_mode, group, cfgid)
	if not raw or #raw == 0 then
		if add_mode == "2" then
			log('获取到的【' .. group .. '】订阅内容为空，可能是订阅地址无效，或是网络问题，请诊断！')
		end
		return
	end

	local import_util = require "luci.sxray.util_import"

	-- Try base64 decode if needed
	local content = raw
	if not content:find("://") and not content:find("^{") then
		local cleaned = content:gsub("%s+", "")
		local decoded = base64Decode(cleaned)
		if decoded and decoded ~= "" and decoded:find("://") then
			content = decoded
		end
	end

	-- Normalize line endings
	content = content:gsub("\r\n", "\n"):gsub("\r", "\n")

	-- Detect format
	local format = import_util.detect_format(content)
	if not format or format == "unknown" then
		-- Try to force as URI list if we see protocol markers
		if content:find("vless://") or content:find("vmess://") or content:find("trojan://") or content:find("ss://") then
			format = "uri_list"
		end
	end

	if not format or format == "unknown" then
		log('无法检测【' .. group .. '】订阅内容格式，跳过。')
		return
	end

	local parse_result, err_msg = import_util.parse_config(content, format)
	if not parse_result then
		log('解析【' .. group .. '】订阅内容失败: ' .. (err_msg or "未知错误"))
		return
	end

	local outbounds = parse_result.outbounds or {}
	local node_list = {}

	for _, outbound in ipairs(outbounds) do
		local alias = outbound.alias or "Unnamed"

		-- Skip nodes that fail validation
		if outbound.error_msg then
			log('丢弃节点: ' .. alias .. ", 原因:" .. outbound.error_msg)
		elseif not outbound.protocol then
			log('丢弃节点: ' .. alias .. ", 无协议信息。")
		elseif (add_mode == "2" and is_filter_keyword(alias)) then
			log('丢弃过滤节点: ' .. (outbound.protocol or "") .. ' 节点, ' .. alias)
		elseif not outbound.address or alias == "NULL" or outbound.address == "127.0.0.1" or
			(not datatypes.hostname(outbound.address) and not (api.is_ip(outbound.address))) then
			log('丢弃无效节点: ' .. (outbound.protocol or "") .. ' 节点, ' .. alias)
		else
			tinsert(node_list, outbound)
		end

		-- Extract subscribe info from node remarks
		if add_mode == "2" then
			get_subscribe_info(cfgid, alias)
		end
	end

	if #node_list > 0 then
		nodeResult[#nodeResult + 1] = {
			remark = group,
			list = node_list
		}
	end
	log('成功解析【' .. group .. '】节点数量: ' .. #node_list)
end

-- Download subscription content via curl
local function curl_subscribe(url, file, ua, mode)
	if not url or url == "" then return 404 end
	local curl_args = {
		"-skL", "-w %{http_code}", "--retry 3", "--connect-timeout 10", "--max-time 60", "-H 'Accept-Encoding: identity'"
	}
	if ua and ua ~= "" and ua ~= "curl" then
		ua = (ua == "sxray") and ("sxray/" .. (api.get_version() or "1.0")) or ua
		curl_args[#curl_args + 1] = '--user-agent "' .. ua .. '"'
	end
	local return_code, result
	if mode == "direct" then
		return_code, result = api.curl_base(url, file, curl_args)
	elseif mode == "proxy" then
		return_code, result = api.curl_proxy(url, file, curl_args)
		-- Fallback to direct if proxy fails
		if not return_code or return_code ~= 0 then
			log('  代理访问失败，回退到直连访问...')
			return_code, result = api.curl_base(url, file, curl_args)
		end
	else
		-- Auto mode: try proxy first, then direct
		return_code, result = api.curl_proxy(url, file, curl_args)
		if not return_code or return_code ~= 0 then
			return_code, result = api.curl_base(url, file, curl_args)
		end
	end
	return tonumber(result)
end

-- Main execution
local execute = function()
	local subscribe_list = {}
	local fail_list = {}

	if arg[2] ~= "all" then
		string.gsub(arg[2], '[^' .. "," .. ']+', function(w)
			subscribe_list[#subscribe_list + 1] = uci:get_all(appname, w) or {}
		end)
	else
		uci:foreach(appname, "subscribe_list", function(o)
			subscribe_list[#subscribe_list + 1] = o
		end)
	end

	local manual_sub = arg[3] == "manual"

	for index, value in ipairs(subscribe_list) do
		local cfgid = value[".name"]
		local remark = value.remark or ""
		local url = value.url or ""

		-- Set allowInsecure for this subscription
		if value.allowInsecure and value.allowInsecure == "1" then
			allowInsecure_default = true
		end

		-- Override filter keyword mode per subscription
		local filter_keyword_mode = value.filter_keyword_mode or "5"
		if filter_keyword_mode == "0" then
			filter_keyword_mode_default = "0"
		elseif filter_keyword_mode == "1" then
			filter_keyword_mode_default = "1"
			filter_keyword_discard_list_default = value.filter_discard_list or {}
		elseif filter_keyword_mode == "2" then
			filter_keyword_mode_default = "2"
			filter_keyword_keep_list_default = value.filter_keep_list or {}
		elseif filter_keyword_mode == "3" then
			filter_keyword_mode_default = "3"
			filter_keyword_keep_list_default = value.filter_keep_list or {}
			filter_keyword_discard_list_default = value.filter_discard_list or {}
		elseif filter_keyword_mode == "4" then
			filter_keyword_mode_default = "4"
			filter_keyword_keep_list_default = value.filter_keep_list or {}
			filter_keyword_discard_list_default = value.filter_discard_list or {}
		end

		-- Override core types per subscription
		local ss_type = value.ss_type or "global"
		if ss_type ~= "global" and core_has[ss_type] then
			ss_type_default = ss_type
		end
		local trojan_type = value.trojan_type or "global"
		if trojan_type ~= "global" and core_has[trojan_type] then
			trojan_type_default = trojan_type
		end
		local vmess_type = value.vmess_type or "global"
		if vmess_type ~= "global" and core_has[vmess_type] then
			vmess_type_default = vmess_type
		end
		local vless_type = value.vless_type or "global"
		if vless_type ~= "global" and core_has[vless_type] then
			vless_type_default = vless_type
		end
		local hysteria2_type = value.hysteria2_type or "global"
		if hysteria2_type ~= "global" and core_has[hysteria2_type] then
			hysteria2_type_default = hysteria2_type
		end

		-- Domain strategy
		local domain_strategy = value.domain_strategy or "global"
		if domain_strategy ~= "global" then
			domain_strategy_node = domain_strategy
		else
			domain_strategy_node = domain_strategy_default
		end

		local ua = value.user_agent
		local access_mode = value.access_mode
		local result_str = (not access_mode) and "自动" or (access_mode == "direct" and "直连访问" or (access_mode == "proxy" and "通过代理" or "自动"))
		log('正在订阅:【' .. remark .. '】' .. url .. ' [' .. result_str .. ']')

		local tmp_file = "/tmp/" .. cfgid
		value.http_code = curl_subscribe(url, tmp_file, ua, access_mode)

		if value.http_code ~= 200 then
			fail_list[#fail_list + 1] = value
		else
			if luci.sys.call("[ -f " .. tmp_file .. " ] && sed -i -e '/^[ \t]*$/d' -e '/^[ \t]*\r$/d' " .. tmp_file) == 0 then
				local f = io.open(tmp_file, "r")
				local stdout = f:read("*all")
				f:close()
				local raw_data = api.trim(stdout)
				local old_md5 = value.md5 or ""
				local new_md5 = luci.sys.exec("md5sum " .. tmp_file .. " 2>/dev/null | awk '{print $1}'"):gsub("\n", "")
				if not manual_sub and old_md5 == new_md5 then
					log('订阅:【' .. remark .. '】没有变化，无需更新。')
				else
					parse_link(raw_data, "2", remark, cfgid)
					uci:set(appname, cfgid, "md5", new_md5)
				end
			else
				fail_list[#fail_list + 1] = value
			end
		end

		luci.sys.call("rm -f " .. tmp_file)

		-- Reset per-subscription overrides back to global defaults
		allowInsecure_default = nil
		filter_keyword_mode_default = uci:get(appname, "@global_subscribe[0]", "filter_keyword_mode") or "0"
		filter_keyword_discard_list_default = uci:get(appname, "@global_subscribe[0]", "filter_discard_list") or {}
		filter_keyword_keep_list_default = uci:get(appname, "@global_subscribe[0]", "filter_keep_list") or {}

		ss_type = uci:get(appname, "@global_subscribe[0]", "ss_type") or ""
		ss_type_default = core_has[ss_type] and ss_type or ss_type_default
		trojan_type = uci:get(appname, "@global_subscribe[0]", "trojan_type") or ""
		trojan_type_default = core_has[trojan_type] and trojan_type or trojan_type_default
		vmess_type = uci:get(appname, "@global_subscribe[0]", "vmess_type") or ""
		vmess_type_default = core_has[vmess_type] and vmess_type or vmess_type_default
		vless_type = uci:get(appname, "@global_subscribe[0]", "vless_type") or ""
		vless_type_default = core_has[vless_type] and vless_type or vless_type_default
		hysteria2_type = uci:get(appname, "@global_subscribe[0]", "hysteria2_type") or ""
		hysteria2_type_default = core_has[hysteria2_type] and hysteria2_type or hysteria2_type_default
	end

	if #fail_list > 0 then
		for index, value in ipairs(fail_list) do
			local code = value.http_code
			local reason = "连接失败"
			if code == nil then
				reason = "无法连接服务器（网络不通或代理未运行）"
			elseif code == 403 then
				reason = "访问被拒绝(403)"
			elseif code == 404 then
				reason = "订阅地址不存在(404)"
			elseif code == 0 then
				reason = "连接超时或DNS解析失败"
			elseif code and code > 0 then
				reason = "HTTP错误(" .. tostring(code) .. ")"
			end
			log(string.format('【%s】订阅失败: %s [%s]', value.remark, reason, tostring(code)))
		end
	end

	update_node(0)
end

-- Entry point
if arg[1] then
	if arg[1] == "start" then
		log('开始订阅...')
		xpcall(execute, function(e)
			log(e)
			if type(debug) == "table" and type(debug.traceback) == "function" then
				log(debug.traceback())
			end
			log('发生错误, 正在恢复服务')
		end)
		log('订阅完毕...\n')
	elseif arg[1] == "add" then
		-- Add from file (links import)
		local f = assert(io.open("/tmp/links.conf", 'r'))
		local raw = f:read('*all')
		f:close()
		parse_link(raw, "1", arg[2] or "default", "")
		update_node(1)
		luci.sys.call("rm -f /tmp/links.conf")
	elseif arg[1] == "truncate" then
		truncate_nodes(arg[2])
	end
end
