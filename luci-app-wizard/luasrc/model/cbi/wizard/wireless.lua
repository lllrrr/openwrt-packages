local fs = require "nixio.fs"
local ldisp = require "luci.dispatcher"
local lhttp = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local mp, o, s

mp = Map("wizard", translate("无线设定"))
mp.description = translate("设定无线连接信息")

s = mp:section(TypedSection, "_dummy", "")
s.addremove = false
s.anonymous = true

function s.cfgsections()
	return { "_wireless" }
end

if not fs.access("/etc/config/wireless") then
	-- mp.message = translate("无线配置不存在！")
	uci:set("wizard", "config", "step", "final")
	uci:commit("wizard")
	lhttp.redirect(ldisp.build_url("admin", "wizard", "final"))
end

local g24_ssid = s:option(Value, "g24_ssid", "2.4 GHz 无线名称")

local g24_pwd = s:option(Value, "g24_pwd", "2.4 GHz 连接密码")
g24_pwd.password = true

local g5_ssid = s:option(Value, "g5_ssid", "5 GHz 无线名称")
g5_ssid:depends({_same = 0})

local g5_pwd = s:option(Value, "g5_pwd", "5 GHz 连接密码")
g5_pwd.password = true
g5_pwd:depends({_same = 0})

local same = s:option(Flag, "_same", "为 2.4 GHz 和 5 GHz 设置相同的名称和密码")
same.enabled = 1
same.default = 1

o = s:option(Button, "_wireless", "⁠")
o.inputtitle = translate("保存")
o.inputstyle = "edit"
o.write = function()
	local vg24_ssid, vg24_pwd, vg5_ssid, vg5_pwd

	local same_config = same:formvalue("_wireless")
	if same_config == "1" then
		g5_ssid = g24_ssid
		g5_pwd = g24_pwd
	end

	local vg24_ssid, vg24_pwd = g24_ssid:formvalue("_wireless"), g24_pwd:formvalue("_wireless")
	local vg5_ssid, vg5_pwd = g5_ssid:formvalue("_wireless"), g5_pwd:formvalue("_wireless")
	if #vg24_ssid == 0 or #vg24_pwd ==0 or #vg5_ssid == 0 or #vg5_pwd == 0 then
		mp.message = translate("名称或密码不能为空！")
	elseif #vg24_ssid > 256 or #vg5_ssid > 256 then
		mp.message = translate("无线名称不能超过 256 位！")
	elseif #vg24_pwd < 8 or #vg5_pwd < 8 then
		mp.message = translate("连接密码不能小于 8 位！")
	else
		sys.exec("/usr/bin/wizard_helper setup_wireless '" .. vg24_ssid .. "' '" .. vg24_pwd .. "' '"
			.. vg5_ssid .. "' '" .. vg5_pwd .. "'")
		uci:set("wizard", "config", "step", "final")
		uci:commit("wizard")
		lhttp.redirect(ldisp.build_url("admin", "wizard", "final"))
	end
end

o = s:option(DummyValue, "__dummy", "⁠")

o = s:option(Button, "_back", "⁠")
o.inputtitle = translate("返回上一步")
o.inputstyle = "reload"
o.write = function()
	uci:set("wizard", "config", "step", "network")
	uci:commit("wizard")
	lhttp.redirect(ldisp.build_url("admin", "wizard", "network"))
end

return mp
