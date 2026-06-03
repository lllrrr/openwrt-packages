local ldisp = require "luci.dispatcher"
local lhttp = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local step = uci:get("wizard", "config", "step") or "welcome"
sys.call("/usr/bin/wizard_helper detect_wan &")

local mp, s

mp = Map("wizard", translate("欢迎使用"))
mp.description = translate("开启你的智能路由之旅")

s = mp:section(TypedSection, "_dummy", "")
s.addremove = false
s.anonymous = true

function s.cfgsections()
	return { "_pass" }
end

if step ~= "welcome" then
o = s:option(Button, "_continue", "⁠")
o.inputtitle = translate("点此继续向导")
o.description = translate("从上次中止的地方继续")
o.inputstyle = "apply"
o.write = function()
	lhttp.redirect(ldisp.build_url("admin", "wizard", step))
end
end

o = s:option(Button, "_guide", "⁠")
o.inputtitle = translate("点此进入向导")
o.description = translate("完成路由器基本设定，包括管理密码，上网方式等")
o.inputstyle = "apply"
o.write = function()
	uci:set("wizard", "config", "step", "password")
	uci:commit("wizard")
	lhttp.redirect(ldisp.build_url("admin", "wizard", "password"))
end

o = s:option(Button, "_skip", "⁠")
o.inputtitle = translate("点此跳过向导")
o.description = translate("如您是进阶用户，无需使用向导，请点此")
o.inputstyle = "reset"
o.write = function()
	uci:set("wizard", "config", "finished", "1")
	uci:commit("wizard")
	sys.exec("rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /etc/hotplug.d/iface/90-wan_discovery")
	sys.exec("touch /etc/config/finished")
	lhttp.redirect(ldisp.build_url("admin", "status", "overview"))
end

return mp
