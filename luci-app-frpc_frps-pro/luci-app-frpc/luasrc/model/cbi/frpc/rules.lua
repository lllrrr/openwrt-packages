-- Copyright 2019 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the MIT License.

local dsp = require "luci.dispatcher"
local sys = require "luci.sys"
local util = require "luci.util"
local uci = require "luci.model.uci".cursor()

local m, s, o

local server_table = {}
uci:foreach("frpc", "server", function(s)
	server_table[s[".name"]] = s.alias or s[".name"]
end)

-- visitor 模式下 bindAddr=0.0.0.0 时回退到路由 LAN IP。
-- 每次页面渲染只算一次，避免按行调用 sys.exec 造成性能尖刺。
local _router_ip
local function router_ip()
	if _router_ip == nil then
		local s = sys.exec("ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@[\"ipv4-address\"][0].address' 2>/dev/null")
		s = (s or ""):gsub("%s+", "")
		if s == "" then
			s = sys.exec("uci -q get network.lan.ipaddr 2>/dev/null") or ""
			s = s:gsub("%s+", "")
		end
		_router_ip = s
	end
	return _router_ip
end

-- 返回 visitor 模式下对外展示的 (ip, port)；非 visitor 返回 nil。
-- ip/port 可能是空字符串（用户尚未填）。
local function visitor_endpoint(section)
	if uci:get("frpc", section, "visitor") ~= "1" then return nil end
	local ip = uci:get("frpc", section, "bindAddr") or ""
	if ip == "" or ip == "0.0.0.0" then
		local rip = router_ip()
		if rip ~= "" then ip = rip end
	end
	return ip, uci:get("frpc", section, "bindPort") or ""
end

m = Map("frpc", "%s - %s" % { translate("Frpc"), translate("代理规则") })
m:append(Template("frpc/theme"))
m:append(Template("frpc/rules_filter"))

s = m:section(TypedSection, "rule")
s.anonymous = true
s.addremove = true
s.sortable = true
s.template = "cbi/tblsection"
s.extedit = dsp.build_url("admin/services/frpc/rules/%s")
function s.create(...)
	local sid = TypedSection.create(...)
	if sid then
		m.uci:save("frpc")
		luci.http.redirect(s.extedit % sid)
		return
	end
end

o = s:option(ListValue, "server_id", translate("归属服务器"))
for k, v in pairs(server_table) do
	o:value(k, v)
end
o.write = function(self, section, value)
	return self.map:set(section, self.option, value)
end

o = s:option(Flag, "enabled", translate("启用"))

o = s:option(DummyValue, "name", translate("名称"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "?"
end

o = s:option(DummyValue, "type", translate("类型"))
o.cfgvalue = function (...)
	local v = Value.cfgvalue(...)
	return v and v:upper() or "?"
end

-- 角色列：visitor=1 → 访客（紫徽章），否则 → 代理（灰徽章）
o = s:option(DummyValue, "_role", translate("角色"))
o.rawhtml = true
o.cfgvalue = function(self, section)
	if uci:get("frpc", section, "visitor") == "1" then
		return '<span class="frpc-role-badge visitor">' .. translate("访客") .. '</span>'
	end
	return '<span class="frpc-role-badge proxy">' .. translate("代理") .. '</span>'
end

o = s:option(DummyValue, "localIP", translate("本地 IP"))
o.cfgvalue = function(self, section)
	local ip = visitor_endpoint(section)
	if ip ~= nil then return ip ~= "" and ip or "?" end
	return uci:get("frpc", section, "localIP") or "?"
end

o = s:option(DummyValue, "localPort", translate("本地端口"))
o.cfgvalue = function(self, section)
	local ip, port = visitor_endpoint(section)
	if ip ~= nil then return port ~= "" and port or "?" end
	return uci:get("frpc", section, "localPort") or "?"
end

-- 远程端口列：visitor 模式没有「远程端口」概念，改成「访问」按钮。
-- 按钮指向 http://<bindAddr or LAN IP>:<bindPort>，新窗口打开。
-- 注意：ssh / rdp / ftp 等非 HTTP 协议点击不会正确处理，由用户自行判断。
o = s:option(DummyValue, "remotePort", translate("远程端口"))
o.rawhtml = true
o.cfgvalue = function(self, section)
	local ip, port = visitor_endpoint(section)
	if ip ~= nil then
		if ip ~= "" and port ~= "" then
			return string.format(
				'<a href="http://%s:%s" target="_blank" rel="noopener" class="cbi-button cbi-button-apply">%s</a>',
				util.pcdata(ip), util.pcdata(port), translate("访问")
			)
		end
		return translate("未设置")
	end
	return uci:get("frpc", section, "remotePort") or translate("未设置")
end

o = s:option(Button, "_copy", translate("复制"))
o.inputtitle = translate("复制")
o.inputstyle = "apply"
o.write = function(self, section)
	luci.http.redirect(dsp.build_url("admin/services/frpc/rule_copy/" .. section))
end

return m
