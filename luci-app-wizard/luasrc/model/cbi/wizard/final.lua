local fs = require "nixio.fs"
local ldisp = require "luci.dispatcher"
local lhttp = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local mp, s

mp = Map("wizard", translate("结束"))
mp.description = translate("您的路由器已经设置完毕")

s = mp:section(TypedSection, "_dummy", "")
s.addremove = false
s.anonymous = true

function s.cfgsections()
	return { "_final" }
end

o = s:option(Button, "_end", "⁠")
o.inputtitle = translate("点此结束向导")
o.description = translate("应用您的所有设定，然后重启网络")
o.inputstyle = "apply"
o.write = function()
	lhttp.redirect(ldisp.build_url("admin", "status", "overview"))

	uci:set("wizard", "config", "finished", "1")
	uci:commit("wizard")

	sys.exec("rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /etc/hotplug.d/iface/90-wan_discovery")
	sys.exec("touch /etc/config/finished")

	sys.exec("/etc/init.d/network restart &")
end

o = s:option(DummyValue, "__dummy", "⁠")

o = s:option(Button, "_back", "⁠")
o.inputtitle = translate("返回上一步")
o.inputstyle = "reload"
o.write = function()
	local target
	if fs.access("/etc/config/wireless") then
		target = "wireless"
	else
		target = "network"
	end
	uci:set("wizard", "config", "step", target)
	uci:commit("wizard")
	lhttp.redirect(ldisp.build_url("admin", "wizard", target))
end

return mp
