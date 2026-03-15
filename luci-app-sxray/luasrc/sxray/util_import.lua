module("luci.sxray.util_import", package.seeall)
local api = require "luci.sxray.api"
local uci = api.uci
local sys = api.sys
local jsonc = api.jsonc
local fs = api.fs
local appname = "sxray"
local i18n = require "luci.i18n"
local datatypes = require "luci.cbi.datatypes"

local tinsert = table.insert
local ssub, slen, schar, sbyte, sformat, sgsub = string.sub, string.len, string.char, string.byte, string.format, string.gsub
local split = api.split
local jsonParse, jsonStringify = luci.jsonc.parse, luci.jsonc.stringify
local base64Decode = api.base64Decode
local UrlEncode = api.UrlEncode
local UrlDecode = api.UrlDecode
local trim = api.trim

local has_singbox = api.finded_com("sing-box")
local has_xray = api.finded_com("xray")

local function is_ip(val)
	local str = val:match("%[(.-)%]") or val
	return datatypes.ipaddr(str) or false
end

local function is_ipv6(val)
	local str = val:match("%[(.-)%]") or val
	return datatypes.ip6addr(str) or false
end

local function is_ipv6addrport(val)
	local address, port = val:match("%[(.-)%]:([0-9]+)$")
	if address and datatypes.ip6addr(address) and datatypes.port(port) then
		return true
	end
	return false
end

local function get_ipv6_only(val)
	local result = ""
	local inner = val:match("%[(.-)%]") or val
	if datatypes.ip6addr(inner) then
		result = inner
	end
	return result
end

function detect_format(content)
	content = trim(content)
	if not content or content == "" then
		return nil
	end

	if content:find("^{") and content:find("}$") then
		local ok, parsed = pcall(jsonc.parse, content)
		if ok and parsed then
			if parsed.inbounds or parsed.outbounds then
				return "xray_json"
			end
			if parsed.inbounds or parsed.outbounds then
				return "singbox_json"
			end
		end
	end

	if content:find("vmess://") or content:find("vless://") or
	   content:find("trojan://") or content:find("ss://") or
	   content:find("ssr://") or content:find("naive://") or
	   content:find("hysteria://") or content:find("hysteria2://") or
	   content:find("tuic://") or content:find("juicity://") or
	   content:find("wireguard://") then
		return "uri_list"
	end

	if content:find("vmess://") then
		return "vmess_qr"
	end

	return "unknown"
end

local function processData(szType, content, core_type)
	local result = {
		type = "outbound",
		core_type = core_type
	}

	if szType == 'ssr' then
		result.protocol = 'shadowsocksr'
		result.alias = "ShadowsocksR"

		local dat = split(content, "/%?")
		local hostInfo = split(dat[1], ':')
		if dat[1]:match('%[(.*)%]') then
			result.address = dat[1]:match('%[(.*)%]')
		else
			result.address = hostInfo[#hostInfo-5]
		end
		result.port = hostInfo[#hostInfo-4]
		result.ssr_protocol = hostInfo[#hostInfo-3]
		result.method = hostInfo[#hostInfo-2]
		result.obfs = hostInfo[#hostInfo-1]
		result.password = base64Decode(hostInfo[#hostInfo])
		local params = {}
		for _, v in pairs(split(dat[2], '&')) do
			local t = split(v, '=')
			params[t[1]] = t[2]
		end
		result.obfsParam = base64Decode(params.obfsparam)
		result.protocolParam = base64Decode(params.protoparam)
		result.alias = base64Decode(params.remarks) or "ShadowsocksR"

	elseif szType == 'vmess' then
		local info = jsonParse(content)
		if core_type == "sing-box" and has_singbox then
			result.core_type = 'sing-box'
		elseif core_type == "xray" and has_xray then
			result.core_type = "xray"
		else
			return nil, "No suitable core available for VMess"
		end
		result.protocol = 'vmess'
		result.alterId = info.aid
		result.address = info.add
		result.port = info.port
		result.id = info.id
		result.alias = info.ps or "VMess"

		info.path = (info.path and info.path ~= "") and UrlDecode(info.path) or nil

		if not info.net then info.net = "tcp" end
		info.net = string.lower(info.net)
		if result.core_type == "sing-box" and info.net == "raw" then
			info.net = "tcp"
		elseif result.core_type == "xray" and info.net == "tcp" then
			info.net = "raw"
		end
		if info.net == 'h2' or info.net == 'http' then
			info.net = "http"
			result.network = (result.core_type == "xray") and "xhttp" or "http"
		else
			result.network = info.net
		end
		if info.net == 'ws' then
			result.host = info.host
			result.path = info.path
			if result.core_type == "sing-box" and info.path then
				local ws_path_dat = split(info.path, "?")
				local ws_path = ws_path_dat[1]
				local ws_path_params = {}
				for _, v in pairs(split(ws_path_dat[2], '&')) do
					local t = split(v, '=')
					ws_path_params[t[1]] = t[2]
				end
				if ws_path_params.ed and tonumber(ws_path_params.ed) then
					result.path = ws_path
				end
			end
		end
		if info.net == "http" then
			if result.core_type == "xray" then
				result.headerType = "stream-one"
				result.host = info.host
				result.path = info.path
			else
				result.http_host = (info.host and info.host ~= "") and { info.host } or nil
				result.http_path = info.path
			end
		end
		if info.net == 'raw' or info.net == 'tcp' then
			if info.type and info.type ~= "http" then
				info.type = "none"
			end
			result.headerType = info.type
			result.tcp_guise_http_host = (info.host and info.host ~= "") and { info.host } or nil
			result.tcp_guise_http_path = (info.path and info.path ~= "") and { info.path } or nil
		end
		if info.net == 'kcp' or info.net == 'mkcp' then
			info.net = "mkcp"
			result.network = "mkcp"
			result.mkcp_guise = info.type
			result.mkcp_mtu = 1350
			result.mkcp_tti = 50
			result.mkcp_uplinkCapacity = 5
			result.mkcp_downlinkCapacity = 20
			result.mkcp_readBufferSize = 2
			result.mkcp_writeBufferSize = 2
			result.mkcp_seed = info.seed
		end
		if info.net == 'quic' then
			result.quic_guise = info.type
			result.quic_key = info.key
			result.quic_security = info.securty
		end
		if info.net == 'grpc' then
			result.grpc_serviceName = info.path
		end
		if info.net == 'xhttp' then
			result.xhttp_host = info.host
			result.xhttp_path = info.path
		end
		if info.net == 'httpupgrade' then
			result.httpupgrade_host = info.host
			result.httpupgrade_path = info.path
		end
		if not info.security then result.security = "auto" end
		result.security = info.security
		if info.tls == "tls" or info.tls == "1" then
			result.tls = "1"
			result.serverName = (info.sni and info.sni ~= "") and info.sni or info.host
			info.allowinsecure = info.allowinsecure or info.insecure
			if info.allowinsecure and (info.allowinsecure == "1" or info.allowinsecure == "0") then
				result.tls_allowInsecure = info.allowinsecure
			end
			result.tls_CertSha = info.pcs
			result.tls_CertByName = info.vcn
		else
			result.tls = "0"
		end

		result.tcp_fast_open = info.tfo

	elseif szType == "ss" then
		result.protocol = 'shadowsocks'
		result.alias = "Shadowsocks"

		local idx_sp = content:find("#") or 0
		local alias = ""
		if idx_sp > 0 then
			alias = content:sub(idx_sp + 1, -1)
		end
		result.alias = UrlDecode(alias)
		local info = content:sub(1, idx_sp - 1):gsub("/%?", "?")
		local params = {}
		if info:find("%?") then
			local find_index = info:find("%?")
			local query = split(info, "%?")
			for _, v in pairs(split(query[2], '&')) do
				local t = split(v, '=')
				if #t >= 2 then params[t[1]] = UrlDecode(t[2]) end
			end
			info = info:sub(1, find_index - 1)
		end

		local hostInfo = split(base64Decode(UrlDecode(info)), "@")
		if hostInfo and #hostInfo > 0 then
			local host_port = hostInfo[#hostInfo]
			if host_port:find(":") then
				local sp = split(host_port, ":")
				result.port = sp[#sp]
				if is_ipv6addrport(host_port) then
					result.address = get_ipv6_only(host_port)
				else
					result.address = sp[1]
				end
			else
				result.address = host_port
			end

			local userinfo = nil
			if #hostInfo > 2 then
				userinfo = {}
				for i = 1, #hostInfo - 1 do
					tinsert(userinfo, hostInfo[i])
				end
				userinfo = table.concat(userinfo, '@')
			else
				userinfo = base64Decode(hostInfo[1])
			end
			local method, password
			if userinfo:find(":") then
				method = userinfo:sub(1, userinfo:find(":") - 1)
				password = userinfo:sub(userinfo:find(":") + 1, #userinfo)
			else
				password = hostInfo[1]
			end

			local _method = (method or "none"):lower()
			method = (_method == "chacha20-poly1305" and "chacha20-ietf-poly1305") or
				(_method == "xchacha20-poly1305" and "xchacha20-ietf-poly1305") or _method

			result.method = method
			result.password = password
			result.tcp_fast_open = params.tfo

			if params.type then
				params.type = string.lower(params.type)
				if result.core_type == "sing-box" and params.type == "raw" then
					params.type = "tcp"
				elseif result.core_type == "xray" and params.type == "tcp" then
					params.type = "raw"
				end
				if params.type == "h2" or params.type == "http" then
					params.type = "http"
					result.network = (result.core_type == "xray") and "xhttp" or "http"
				else
					result.network = params.type
				end
				if result.core_type ~= "SS-Rust" and result.core_type ~= "SS" then
					if params.type == 'ws' then
						result.host = params.host
						result.path = params.path
					end
					if params.type == "http" then
						if result.core_type == "sing-box" then
							result.network = "http"
							result.http_host = (params.host and params.host ~= "") and { params.host } or nil
							result.http_path = params.path
						elseif result.core_type == "xray" then
							result.network = "xhttp"
							result.headerType = "stream-one"
							result.host = params.host
							result.path = params.path
						end
					end
					if params.type == 'raw' or params.type == 'tcp' then
						result.headerType = params.headerType or "none"
						result.tcp_guise_http_host = (params.host and params.host ~= "") and { params.host } or nil
						result.tcp_guise_http_path = (params.path and params.path ~= "") and { params.path } or nil
					end
					result.tls = "0"
					if params.security == "tls" or params.security == "reality" then
						result.tls = "1"
						result.serverName = (params.sni and params.sni ~= "") and params.sni or params.host
						result.alpn = params.alpn
						if params.fp and params.fp ~= "" then
							result.utls = "1"
							result.fingerprint = params.fp
						end
						if params.security == "reality" then
							result.reality = "1"
							result.realityPublicKey = params.pbk or nil
							result.realityShortId = params.sid or nil
							result.realitySpiderX = params.spx or nil
						end
					end
					params.allowinsecure = params.allowinsecure or params.insecure
					if params.allowinsecure and (params.allowinsecure == "1" or params.allowinsecure == "0") then
						result.tls_allowInsecure = params.allowinsecure
					end
				end
			end
		end

	elseif szType == "trojan" then
		result.protocol = 'trojan'
		result.alias = "Trojan"

		local alias = ""
		if content:find("#") then
			local idx_sp = content:find("#")
			alias = content:sub(idx_sp + 1, -1)
			content = content:sub(0, idx_sp - 1)
		end
		result.alias = UrlDecode(alias)
		if content:find("@") then
			local Info = split(content, "@")
			result.password = UrlDecode(Info[1])
			local port = "443"
			Info[2] = (Info[2] or ""):gsub("/%?", "?")
			local query = split(Info[2], "%?")
			local host_port = query[1]
			local params = {}
			for _, v in pairs(split(query[2], '&')) do
				local t = split(v, '=')
				if #t > 1 then
					params[string.lower(t[1])] = UrlDecode(t[2])
				end
			end
			if host_port:find(":") then
				local sp = split(host_port, ":")
				port = sp[#sp]
				if is_ipv6addrport(host_port) then
					result.address = get_ipv6_only(host_port)
				else
					result.address = sp[1]
				end
			else
				result.address = host_port
			end

			local peer, sni = nil, ""
			if params.peer then peer = params.peer end
			sni = params.sni and params.sni or ""
			result.port = port

			result.tls = '1'
			result.serverName = peer and peer or sni
			result.tls_CertSha = params.pcs
			result.tls_CertByName = params.vcn

			params.allowinsecure = params.allowinsecure or params.insecure
			if params.allowinsecure then
				if params.allowinsecure == "1" or params.allowinsecure == "0" then
					result.tls_allowInsecure = params.allowinsecure
				else
					result.tls_allowInsecure = string.lower(params.allowinsecure) == "true" and "1" or "0"
				end
			end

			if not params.type then params.type = "tcp" end
			params.type = string.lower(params.type)
			if result.core_type == "sing-box" and params.type == "raw" then
				params.type = "tcp"
			elseif result.core_type == "xray" and params.type == "tcp" then
				params.type = "raw"
			end
			if params.type == "h2" or params.type == "http" then
				params.type = "http"
				result.network = (result.core_type == "xray") and "xhttp" or "http"
			else
				result.network = params.type
			end
			if params.type == 'ws' then
				result.host = params.host
				result.path = params.path
			end
			if params.type == "http" then
				if result.core_type == "sing-box" then
					result.network = "http"
					result.http_host = (params.host and params.host ~= "") and { params.host } or nil
					result.http_path = params.path
				elseif result.core_type == "xray" then
					result.network = "xhttp"
					result.headerType = "stream-one"
					result.host = params.host
					result.path = params.path
				end
			end
			if params.type == 'raw' or params.type == 'tcp' then
				result.headerType = params.headerType or "none"
				result.tcp_guise_http_host = (params.host and params.host ~= "") and { params.host } or nil
				result.tcp_guise_http_path = (params.path and params.path ~= "") and { params.path } or nil
			end
			result.alpn = params.alpn
			result.tcp_fast_open = params.tfo
		end

	elseif szType == "vless" then
		if core_type == "sing-box" and has_singbox then
			result.core_type = 'sing-box'
		elseif core_type == "xray" and has_xray then
			result.core_type = "xray"
		else
			return nil, "No suitable core available for VLESS"
		end
		result.protocol = "vless"
		result.alias = "VLESS"

		local alias = ""
		if content:find("#") then
			local idx_sp = content:find("#")
			alias = content:sub(idx_sp + 1, -1)
			content = content:sub(0, idx_sp - 1)
		end
		result.alias = UrlDecode(alias)
		if content:find("@") then
			local Info = split(content, "@")
			result.id = UrlDecode(Info[1])
			local port = "443"
			Info[2] = (Info[2] or ""):gsub("/%?", "?")
			local query = split(Info[2], "%?")
			local host_port = query[1]
			local params = {}
			for _, v in pairs(split(query[2], '&')) do
				local t = split(v, '=')
				params[t[1]] = UrlDecode(t[2])
			end
			if host_port:find(":") then
				local sp = split(host_port, ":")
				port = sp[#sp]
				if is_ipv6addrport(host_port) then
					result.address = get_ipv6_only(host_port)
				else
					result.address = sp[1]
				end
			else
				result.address = host_port
			end

			if not params.type then params.type = "tcp" end
			params.type = string.lower(params.type)
			if result.core_type == "sing-box" and params.type == "raw" then
				params.type = "tcp"
			elseif result.core_type == "xray" and params.type == "tcp" then
				params.type = "raw"
			end
			if params.type == "h2" or params.type == "http" then
				params.type = "http"
				result.network = (result.core_type == "xray") and "xhttp" or "http"
			else
				result.network = params.type
			end
			if params.type == 'ws' then
				result.host = params.host
				result.path = params.path
			end
			if params.type == "http" then
				if result.core_type == "sing-box" then
					result.network = "http"
					result.http_host = (params.host and params.host ~= "") and { params.host } or nil
					result.http_path = params.path
				elseif result.core_type == "xray" then
					result.network = "xhttp"
					result.headerType = "stream-one"
					result.host = params.host
					result.path = params.path
				end
			end
			if params.type == 'raw' or params.type == 'tcp' then
				result.headerType = params.headerType or "none"
				result.tcp_guise_http_host = (params.host and params.host ~= "") and { params.host } or nil
				result.tcp_guise_http_path = (params.path and params.path ~= "") and { params.path } or nil
			end
			if params.type == 'grpc' then
				if params.path then result.grpc_serviceName = params.path end
				if params.serviceName then result.grpc_serviceName = params.serviceName end
			end
			if params.type == 'xhttp' then
				result.xhttp_host = params.host
				result.xhttp_path = params.path
			end

			result.encryption = params.encryption or "none"
			result.flow = params.flow and params.flow:gsub("-udp443", "") or nil

			result.tls = "0"
			if params.security == "tls" or params.security == "reality" then
				result.tls = "1"
				result.serverName = (params.sni and params.sni ~= "") and params.sni or params.host
				result.alpn = params.alpn
				if params.fp and params.fp ~= "" then
					result.utls = "1"
					result.fingerprint = params.fp
				end
				if params.ech and params.ech ~= "" then
					result.ech = "1"
					result.ech_config = params.ech
				end
				result.tls_CertSha = params.pcs
				result.tls_CertByName = params.vcn
				if params.security == "reality" then
					result.reality = "1"
					result.realityPublicKey = params.pbk or nil
					result.realityShortId = params.sid or nil
					result.realitySpiderX = params.spx or nil
				end
			end

			result.port = port

			params.allowinsecure = params.allowinsecure or params.insecure
			if params.allowinsecure and (params.allowinsecure == "1" or params.allowinsecure == "0") then
				result.tls_allowInsecure = params.allowinsecure
			end

			result.tcp_fast_open = params.tfo
		end

	elseif szType == 'hysteria' then
		if not has_singbox then
			return nil, "Sing-box not available for Hysteria"
		end
		result.core_type = 'sing-box'
		result.protocol = "hysteria"
		result.alias = "Hysteria"

		local alias = ""
		if content:find("#") then
			local idx_sp = content:find("#")
			alias = content:sub(idx_sp + 1, -1)
			content = content:sub(0, idx_sp - 1)
		end
		result.alias = UrlDecode(alias)

		local dat = split(content:gsub("/%?", "?"), '%?')
		local host_port = dat[1]
		local params = {}
		for _, v in pairs(split(dat[2], '&')) do
			local t = split(v, '=')
			if #t > 0 then
				params[t[1]] = t[2]
			end
		end
		if host_port:find(":") then
			local sp = split(host_port, ":")
			result.port = sp[#sp]
			if is_ipv6addrport(host_port) then
				result.address = get_ipv6_only(host_port)
			else
				result.address = sp[1]
			end
		else
			result.address = host_port
		end
		result.hysteria_obfs = params.obfsParam
		result.hysteria_auth_type = "string"
		result.hysteria_auth_password = params.auth
		result.serverName = params.peer
		params.allowinsecure = params.allowinsecure or params.insecure
		if params.allowinsecure and (params.allowinsecure == "1" or params.allowinsecure == "0") then
			result.tls_allowInsecure = params.allowinsecure
		end
		result.hysteria_alpn = params.alpn
		result.hysteria_up_mbps = params.upmbps
		result.hysteria_down_mbps = params.downmbps
		result.hysteria_hop = params.mport

	elseif szType == 'hysteria2' or szType == 'hy2' then
		result.protocol = "hysteria2"
		result.alias = "Hysteria2"

		local alias = ""
		if content:find("#") then
			local idx_sp = content:find("#")
			alias = content:sub(idx_sp + 1, -1)
			content = content:sub(0, idx_sp - 1)
		end
		result.alias = UrlDecode(alias)
		local Info = content
		if content:find("@") then
			local contents = split(content, "@")
			result.hysteria2_auth_password = UrlDecode(contents[1])
			Info = (contents[2] or ""):gsub("/%?", "?")
		end
		local query = split(Info, "%?")
		local host_port = query[1]
		local params = {}
		for _, v in pairs(split(query[2], '&')) do
			local t = split(v, '=')
			if #t > 1 then
				params[string.lower(t[1])] = UrlDecode(t[2])
			end
		end
		if host_port:find(":") then
			local sp = split(host_port, ":")
			result.port = sp[#sp]
			if is_ipv6addrport(host_port) then
				result.address = get_ipv6_only(host_port)
			else
				result.address = sp[1]
			end
		else
			result.address = host_port
		end
		result.serverName = params.sni
		result.tls_CertSha = params.pcs
		result.tls_CertByName = params.vcn
		params.allowinsecure = params.allowinsecure or params.insecure
		if params.allowinsecure and (params.allowinsecure == "1" or params.allowinsecure == "0") then
			result.tls_allowInsecure = params.allowinsecure
		end
		result.hysteria2_tls_pinSHA256 = params.pinSHA256
		result.hysteria2_hop = params.mport

		if (core_type == "sing-box" and has_singbox) or (core_type == "xray" and has_xray) then
			local is_singbox = core_type == "sing-box" and has_singbox
			result.core_type = is_singbox and 'sing-box' or 'xray'
			result.protocol = "hysteria2"
			if params["obfs-password"] or params["obfs_password"] then
				result.hysteria2_obfs_type = "salamander"
				result.hysteria2_obfs_password = params["obfs-password"] or params["obfs_password"]
			end
		else
			return nil, "No suitable core available for Hysteria2"
		end

	elseif szType == 'tuic' then
		if not has_singbox then
			return nil, "Sing-box not available for Tuic"
		end
		result.core_type = 'sing-box'
		result.protocol = "tuic"
		result.alias = "Tuic"

		local alias = ""
		if content:find("#") then
			local idx_sp = content:find("#")
			alias = content:sub(idx_sp + 1, -1)
			content = content:sub(0, idx_sp - 1)
		end
		result.alias = UrlDecode(alias)
		local Info = content
		if content:find("@", 1, true) then
			local contents = split(content, "@")
			local auth = contents[1] or ""
			local idx = auth:find(":", 1, true)
			if not idx then
				auth = UrlDecode(auth)
				idx = auth:find(":", 1, true)
			end
			if idx then
				result.id = UrlDecode(auth:sub(1, idx - 1))
				result.password = UrlDecode(auth:sub(idx + 1))
			end
			Info = (contents[2] or ""):gsub("/%?", "?")
		end
		local query = split(Info, "%?")
		local host_port = query[1]
		local params = {}
		for _, v in pairs(split(query[2], '&')) do
			local t = split(v, '=')
			if #t > 1 then
				params[string.lower(t[1])] = UrlDecode(t[2])
			end
		end
		if host_port:find(":") then
			local sp = split(host_port, ":")
			result.port = sp[#sp]
			if is_ipv6addrport(host_port) then
				result.address = get_ipv6_only(host_port)
			else
				result.address = sp[1]
			end
		else
			result.address = host_port
		end
		result.serverName = params.sni
		result.tls_disable_sni = params.disable_sni
		result.tuic_alpn = params.alpn or "default"
		result.tuic_congestion_control = params.congestion_control or "cubic"
		result.tuic_udp_relay_mode = params.udp_relay_mode or "native"
		params.allowinsecure = params.allowinsecure or params.insecure
		if params.allowinsecure then
			if params.allowinsecure == "1" or params.allowinsecure == "0" then
				result.tls_allowInsecure = params.allowinsecure
			else
				result.tls_allowInsecure = string.lower(params.allowinsecure) == "true" and "1" or "0"
			end
		end
	else
		return nil, "Unsupported protocol: " .. szType
	end

	if not result.alias or result.alias == "" then
		if result.address and result.port then
			result.alias = result.address .. ':' .. result.port
		else
			result.alias = "Unnamed"
		end
	end

	return result
end

local function parse_vmess_uri(uri, core_type)
	local content = uri:match("^vmess://(.+)$")
	if not content then
		return nil, "Invalid VMess URI"
	end

	local decoded = base64Decode(content)
	if not decoded then
		return nil, "Failed to decode Base64"
	end

	local ok, data = pcall(jsonc.parse, decoded)
	if not ok or not data then
		return nil, "Invalid VMess JSON"
	end

	return processData('vmess', decoded, core_type)
end

local function parse_vless_uri(uri, core_type)
	local content = uri:match("^vless://(.+)$")
	if not content then
		return nil, "Invalid VLESS URI"
	end
	return processData('vless', content, core_type)
end

local function parse_ss_uri(uri, core_type)
	local content = uri:match("^ss://(.+)$")
	if not content then
		return nil, "Invalid Shadowsocks URI"
	end
	return processData('ss', content, core_type)
end

local function parse_trojan_uri(uri, core_type)
	local content = uri:match("^trojan://(.+)$")
	if not content then
		return nil, "Invalid Trojan URI"
	end
	return processData('trojan', content, core_type)
end

local function parse_hysteria_uri(uri, core_type)
	local content = uri:match("^hysteria://(.+)$")
	if not content then
		return nil, "Invalid Hysteria URI"
	end
	return processData('hysteria', content, core_type)
end

local function parse_hysteria2_uri(uri, core_type)
	local content = uri:match("^hy2://(.+)$") or uri:match("^hysteria2://(.+)$")
	if not content then
		return nil, "Invalid Hysteria2 URI"
	end
	return processData('hysteria2', content, core_type)
end

local function parse_tuic_uri(uri, core_type)
	local content = uri:match("^tuic://(.+)$")
	if not content then
		return nil, "Invalid TUIC URI"
	end
	return processData('tuic', content, core_type)
end

local function parse_ssr_uri(uri, core_type)
	local content = uri:match("^ssr://(.+)$")
	if not content then
		return nil, "Invalid ShadowsocksR URI"
	end
	return processData('ssr', content, core_type)
end

local function parse_uri_list(content, core_type)
	local outbounds = {}
	local errors = {}

	for line in content:gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" and not line:find("^#") then
			local result, err

			if line:find("^vmess://") then
				result, err = parse_vmess_uri(line, core_type)
			elseif line:find("^vless://") then
				result, err = parse_vless_uri(line, core_type)
			elseif line:find("^trojan://") then
				result, err = parse_trojan_uri(line, core_type)
			elseif line:find("^ss://") then
				result, err = parse_ss_uri(line, core_type)
			elseif line:find("^ssr://") then
				result, err = parse_ssr_uri(line, core_type)
			elseif line:find("^hysteria://") then
				result, err = parse_hysteria_uri(line, core_type)
			elseif line:find("^hysteria2://") or line:find("^hy2://") then
				result, err = parse_hysteria2_uri(line, core_type)
			elseif line:find("^tuic://") then
				result, err = parse_tuic_uri(line, core_type)
			end

			if result then
				table.insert(outbounds, result)
			elseif err then
				table.insert(errors, err)
			end
		end
	end

	return {
		outbounds = outbounds,
		errors = errors
	}
end

local function parse_xray_json(content, core_type)
	local ok, data = pcall(jsonc.parse, content)
	if not ok or not data then
		return nil, "Invalid JSON format"
	end

	local result = {
		inbounds = {},
		outbounds = {},
		routing = data.routing,
		dns = data.dns
	}

	if data.inbounds then
		for _, inbound in ipairs(data.inbounds) do
			table.insert(result.inbounds, {
				type = "inbound",
				protocol = inbound.protocol,
				alias = inbound.tag or ("Inbound " .. #result.inbounds + 1),
				listen = inbound.listen or "0.0.0.0",
				port = inbound.port,
				tag = inbound.tag,
				settings = inbound.settings
			})
		end
	end

	if data.outbounds then
		for _, outbound in ipairs(data.outbounds) do
			table.insert(result.outbounds, {
				type = "outbound",
				protocol = outbound.protocol,
				alias = outbound.tag or ("Outbound " .. #result.outbounds + 1),
				tag = outbound.tag,
				settings = outbound.settings,
				streamSettings = outbound.streamSettings
			})
		end
	end

	return result
end

local function parse_singbox_json(content, core_type)
	local ok, data = pcall(jsonc.parse, content)
	if not ok or not data then
		return nil, "Invalid JSON format"
	end

	local result = {
		inbounds = {},
		outbounds = {},
		routing = data.route,
		dns = data.dns
	}

	if data.inbounds then
		for _, inbound in ipairs(data.inbounds) do
			table.insert(result.inbounds, {
				type = "inbound",
				protocol = inbound.type,
				alias = inbound.tag or ("Inbound " .. #result.inbounds + 1),
				listen = inbound.listen,
				port = inbound.listen_port,
				tag = inbound.tag
			})
		end
	end

	if data.outbounds then
		for _, outbound in ipairs(data.outbounds) do
			table.insert(result.outbounds, {
				type = "outbound",
				protocol = outbound.type,
				alias = outbound.tag or ("Outbound " .. #result.outbounds + 1),
				tag = outbound.tag
			})
		end
	end

	return result
end

function parse_config(content, format, core_type)
	content = trim(content)
	if not content or content == "" then
		return nil, "Empty content"
	end

	if format == "auto" then
		format = detect_format(content)
	end

	if not format or format == "unknown" then
		return nil, "Could not detect configuration format"
	end

	if format == "uri_list" then
		return parse_uri_list(content, core_type)
	elseif format == "xray_json" then
		return parse_xray_json(content, core_type)
	elseif format == "singbox_json" then
		return parse_singbox_json(content, core_type)
	elseif format == "vmess_qr" then
		return parse_uri_list(content, core_type)
	end

	return nil, "Unsupported format: " .. format
end

function save_config(data)
	if not data then
		return false, "No data to save"
	end

	local changes = {}

	if data.outbounds then
		for _, outbound in ipairs(data.outbounds) do
			local section = uci:add(appname, "outbound")
			uci:set(appname, section, "type", outbound.type or "outbound")
			uci:set(appname, section, "protocol", outbound.protocol or "")
			uci:set(appname, section, "alias", outbound.alias or "Unnamed")

			if outbound.core_type then
				uci:set(appname, "main", "core_type", outbound.core_type)
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
			end

			if outbound.network then uci:set(appname, section, "ss_network", outbound.network) end
			if outbound.headerType then uci:set(appname, section, "ss_tcp_header_type", outbound.headerType) end

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
			if outbound.tls_allowInsecure then uci:set(appname, section, "ss_tls_allow_insecure", outbound.tls_allowInsecure) end

			if outbound.fingerprint then uci:set(appname, section, "ss_tls_fingerprint", outbound.fingerprint) end

			if outbound.realityPublicKey then uci:set(appname, section, "ss_reality_public_key", outbound.realityPublicKey) end
			if outbound.realityShortId then uci:set(appname, section, "ss_reality_short_id", outbound.realityShortId) end
			if outbound.realitySpiderX then uci:set(appname, section, "ss_reality_spider_x", outbound.realitySpiderX) end

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

			table.insert(changes, {
				type = "outbound",
				section = section,
				alias = outbound.alias
			})
		end
	end

	if data.inbounds then
		for _, inbound in ipairs(data.inbounds) do
			local section = uci:add(appname, "inbound")
			uci:set(appname, section, "protocol", inbound.protocol or "")
			uci:set(appname, section, "alias", inbound.alias or "Unnamed")

			if inbound.listen then
				uci:set(appname, section, "listen", inbound.listen)
			end
			if inbound.port then
				uci:set(appname, section, "port", inbound.port)
			end

			table.insert(changes, {
				type = "inbound",
				section = section,
				alias = inbound.alias
			})
		end
	end

	uci:commit(appname)

	return true, changes
end
