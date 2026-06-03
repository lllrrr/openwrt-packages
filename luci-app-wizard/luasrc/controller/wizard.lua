module("luci.controller.wizard", package.seeall)

function index()
	entry({"admin", "system", "wizard"}, call("restart_wizard"))

	if not nixio.fs.access("/etc/config/wizard") then
		return
	end

	local uci = require "luci.model.uci".cursor()
	local finished = uci:get_bool("wizard", "config", "finished")
	if finished then return end

	entry({"admin", "wizard"}, alias("admin", "wizard", "welcome"), "初始化设置", 1).dependent = false

	local hidden_buttons = { hideapplybtn = true, hidesavebtn = true, hideresetbtn = true }

	entry({"admin", "wizard", "welcome"}, cbi("wizard/welcome", hidden_buttons), _("欢迎"), 10).hidden = true
	entry({"admin", "wizard", "password"}, cbi("wizard/password", hidden_buttons), _("管理密码设定"), 20).hidden = true
	entry({"admin", "wizard", "network"}, cbi("wizard/network", hidden_buttons), _("上网方式设定"), 30).hidden = true
	entry({"admin", "wizard", "wireless"}, cbi("wizard/wireless", hidden_buttons), _("无线设定"), 40).hidden = true
	entry({"admin", "wizard", "final"}, cbi("wizard/final", hidden_buttons), _("完成"), 50).hidden = true

	-- entry({"admin", "status", "overview"}, call("redirect_wizard"), _(""), 0)
	entry({"admin", "system", "admin"}, call("redirect_wizard"), _(""), 0)
end

function redirect_wizard()
	luci.http.redirect(luci.dispatcher.build_url("admin", "wizard", "welcome"))
end

function restart_wizard()
	luci.sys.call("cp -f /rom/etc/config/wizard /etc/config/wizard")
	luci.sys.call("rm -rf /tmp/luci-indexcache /tmp/luci-modulecache")
	luci.http.redirect(luci.dispatcher.build_url("admin", "wizard", "welcome"))
end
