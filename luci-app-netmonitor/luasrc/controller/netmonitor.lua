module("luci.controller.netmonitor", package.seeall)
function index()
entry({"admin","status","netmonitor"}, template("netmonitor"), _("Network Monitor"), 7).leaf=true
end