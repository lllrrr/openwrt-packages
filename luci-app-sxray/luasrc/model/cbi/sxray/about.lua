-- Copyright 2024 luci-app-sxray
-- Licensed to the public under the MIT License.

local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local fs = require "nixio.fs"

local config_file = uci:get("sxray", "main", "config_file")
local core_type = uci:get("sxray", "main", "core_type") or "xray"

-- 根据核心类型确定配置文件路径
if not config_file or util.trim(config_file) == "" then
	if core_type == "sing-box" then
		config_file = "/var/etc/sxray_singbox/sxray.main.json"
	else
		config_file = "/var/etc/sxray_xray/sxray.main.json"
	end
end

local config_content = fs.readfile(config_file) or translate("Failed to open file.")

local m

m = SimpleForm("sxray", "%s - %s" % { translate("SXray"), translate("About") },
	"<p>%s</p><p>%s</p><p>%s</p><p>%s</p><p>%s</p><p>%s</p><p>%s</p><p>%s</p>" % {
		translate("LuCI support for SXray."),
		translatef("Based on luci-app-v2ray by %s", "Xingwang Liao"),
		translatef(
			"Source: %s",
			"<a href=\"https://github.com/kuoruan/luci-app-v2ray\" target=\"_blank\">https://github.com/kuoruan/luci-app-v2ray</a>"
		),
		translatef(
			"Xray Core: %s",
			"<a href=\"https://github.com/XTLS/Xray-core\" target=\"_blank\">https://github.com/XTLS/Xray-core</a>"
		),
		translatef(
			"Sing-Box: %s",
			"<a href=\"https://github.com/SagerNet/sing-box\" target=\"_blank\">https://github.com/SagerNet/sing-box</a>"
		),
		translatef("Current Core Type: %s", core_type),
		translatef("Current Config File: %s", config_file),
		"<pre style=\"-moz-tab-size: 4;-o-tab-size: 4;tab-size: 4;word-break: break-all;\">%s</pre>" % config_content,
	})

m.reset = false
m.submit = false

return m
