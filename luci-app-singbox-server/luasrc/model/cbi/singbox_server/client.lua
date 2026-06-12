local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local dsp = require "luci.dispatcher"

m = Map("singbox_server", translate("服务器端"))
m.description = translate("sing-box 多实例服务端管理。")

-- 全局开关
s = m:section(NamedSection, "global", "global")
s.anonymous = true
s.addremove = false
s:option(Flag, "enabled", translate("启用"))

-- 用户管理表格
s = m:section(TypedSection, "server", translate("用户管理"))
s.anonymous = true
s.addremove = true
s.addbtntitle = translate("添加")
s.template = "cbi/tblsection"
s.extedit = dsp.build_url("admin/vpn/singbox-server/edit/%s")

function s.create(self, section)
	local sid = TypedSection.create(self, section)
	self.map:set(sid, "remarks", translate("备注"))
	self.map:set(sid, "type", "singbox")
	self.map:set(sid, "protocol", "vmess")
	self.map:set(sid, "listen_port", "4566")
	self.map:set(sid, "uuid", "ba9872bc-ebdf-4ce2-8c6f-fce7fa2357aa")
	self.map:set(sid, "transport", "ws")
	self.map:set(sid, "ws_path", "/")
	self.map:set(sid, "enabled", "0")
	self.map:set(sid, "log", "0")
	if self.map.uci then
		self.map.uci:save("singbox_server")
		self.map.uci:commit("singbox_server")
	end
	luci.http.redirect(dsp.build_url("admin/vpn/singbox-server/edit/" .. sid))
end

en = s:option(Flag, "enabled", translate("启用"))
en.rmempty = false

st = s:option(DummyValue, "_status", translate("状态"))
st.rawhtml = true
function st.cfgvalue(self, section)
	local cmd = "ps -w | grep '[s]ing-box run -c /tmp/etc/singbox_server/" .. section .. ".json' >/dev/null 2>&1"
	if sys.call(cmd) == 0 then
		return "<span style='color:green;font-weight:bold'>✓</span>"
	end
	return "<span style='color:red;font-weight:bold'>×</span>"
end

rmk = s:option(DummyValue, "remarks", translate("备注"))
function rmk.cfgvalue(self, section)
	return m:get(section, "remarks") or "-"
end

tp = s:option(DummyValue, "_type", translate("类型"))
function tp.cfgvalue(self, section)
	local custom = m:get(section, "custom_config") or "0"
	if custom == "1" then
		return translate("自定义")
	end

	local p = (m:get(section, "protocol") or "vmess"):upper()
	return p
end

pt = s:option(DummyValue, "_port", translate("端口"))
function pt.cfgvalue(self, section)
	local custom = m:get(section, "custom_config") or "0"
	if custom == "1" then
		return translate("自定义")
	end

	return m:get(section, "listen_port") or "-"
end

lg = s:option(Flag, "log", translate("日志"))
lg.default = "0"
lg.rmempty = false

logbtn = s:option(DummyValue, "_logbtn", " ")
logbtn.rawhtml = true
function logbtn.cfgvalue(self, section)
	return string.format("<input class=\"btn cbi-button cbi-button-apply\" type=\"button\" value=\"%s\" onclick='loadSingBoxLog(%q);location.hash=%q;return false;' />", translate("日志"), section, "log_" .. section)
end

up = s:option(Button, "_up", " ")
up.inputtitle = translate("上移")
function up.write(self, section)
	uci:reorder("singbox_server", section, 0)
	uci:commit("singbox_server")
	luci.http.redirect(dsp.build_url("admin/vpn/singbox-server"))
end

down = s:option(Button, "_down", " ")
down.inputtitle = translate("下移")
function down.write(self, section)
	local idx = 0
	uci:foreach("singbox_server", "server", function(s)
		idx = idx + 1
		if s[".name"] == section then
			uci:reorder("singbox_server", section, idx + 1)
		end
	end)
	uci:commit("singbox_server")
	luci.http.redirect(dsp.build_url("admin/vpn/singbox-server"))
end

-- 日志区，和截图一致放在表格下方
logsec = m:section(SimpleSection, translate("日志"))
logsec.template = "singbox_server/log"

return m
