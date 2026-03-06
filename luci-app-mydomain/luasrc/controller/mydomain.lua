module("luci.controller.mydomain", package.seeall)

local i18n = require("luci.i18n")
local translate = i18n.translate or i18n.i18n

function index()
	if not nixio.fs.access("/etc/config/mydomain") then
		return
	end

	-- Main page - use 'firstchild' to allow JavaScript modules to handle sub-pages
	entry({"admin", "services", "mydomain"}, firstchild(), translate("MyDomain Manager"), 60)

	-- Sub-pages with JavaScript view modules
	entry({"admin", "services", "mydomain", "ddns"}, cbi("mydomain/ddns"), translate("Dynamic DNS"), 10)
	entry({"admin", "services", "mydomain", "proxy"}, cbi("mydomain/proxy"), translate("Reverse Proxy"), 20)
	entry({"admin", "services", "mydomain", "cert"}, cbi("mydomain/cert"), translate("Certificate Management"), 30)
	entry({"admin", "services", "mydomain", "status"}, call("action_status"), translate("Status"), 40)
end

function action_status()
	luci.template.render("mydomain/status")
end
