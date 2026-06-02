-- Multi-instance frps: instance list view
-- Licensed to the public under the MIT License.

local dsp = require "luci.dispatcher"

local m, s, o

m = Map("frps", "%s - %s" % { translate("Frps"), translate("FRPS 实例") })
m:append(Template("frps/theme"))
m:append(Template("frps/instances_poll"))

s = m:section(TypedSection, "instance")
s.anonymous = true
s.addremove = true
s.sortable = false
s.template = "cbi/tblsection"
s.extedit = dsp.build_url("admin/services/frps/instances/%s")

function s.create(...)
	-- 用稳定命名创建 instance（ins_<ts>_<rand>），避免 UCI 匿名 cfgXXXXXX 因 section 位置变化漂移。
	-- 与 frpc servers.lua 同款思路：frps instance 虽无 server_id 外键、不会丢数据，但稳定名可避免
	-- 排序/增删后 toml 文件名、防火墙规则 frps_<sid>_*_auto 跟着漂移产生孤儿规则。
	local stable_sid = string.format("ins_%d_%d", os.time(), math.random(1000, 9999))
	for _ = 1, 5 do
		if not m.uci:get("frps", stable_sid) then break end
		stable_sid = string.format("ins_%d_%d", os.time(), math.random(1000, 9999))
	end
	-- 新建实例默认禁用 + 合理默认值
	m.uci:set("frps", stable_sid, "instance")
	m.uci:set("frps", stable_sid, "enabled", "0")
	m.uci:set("frps", stable_sid, "alias", stable_sid)
	m.uci:set("frps", stable_sid, "bindPort", "7000")
	m.uci:save("frps")
	luci.http.redirect(s.extedit % stable_sid)
end

o = s:option(DummyValue, "_status", translate("状态 / 操作"))
o.template = "frps/instance_row"
o.rawhtml = true
o.cfgvalue = function() return "" end

o = s:option(DummyValue, "alias", translate("别名"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or translate("无")
end

o = s:option(DummyValue, "bindAddr", translate("绑定地址"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "0.0.0.0"
end

o = s:option(DummyValue, "bindPort", translate("绑定端口"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "7000"
end

o = s:option(DummyValue, "vhostHTTPPort", translate("HTTP 端口"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "-"
end

o = s:option(DummyValue, "webServer__port", translate("管理面板端口"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "-"
end

o = s:option(Button, "_copy", translate("复制"))
o.inputtitle = translate("复制")
o.inputstyle = "apply"
o.write = function(self, section)
	luci.http.redirect(dsp.build_url("admin/services/frps/instance_copy/" .. section))
end

return m
