-- CBI 模型用于配置页面
local m = Map("usbmodem", translate("USB Modem Settings"), translate("Configure USB modem mode and SMS forwarding."))

local s = m:section(TypedSection, "settings", "")
s.anonymous = true

-- 模式选择
mode = s:option(ListValue, "mode", translate("Default Mode"))
mode:value("ncm", "NCM")
mode:value("ecm", "ECM")
mode:value("qmi", "QMI")
mode:value("rndis", "RNDIS")
mode.rmempty = false

-- Bark 配置
bark_token = s:option(Value, "bark_token", translate("Bark Device Token"))
bark_token.placeholder = "Your Bark token"

bark_server = s:option(Value, "bark_server", translate("Bark Server URL"))
bark_server.placeholder = "https://api.day.app"
bark_server.default = "https://api.day.app"

bark_enabled = s:option(Flag, "bark_enabled", translate("Enable Bark Push"))
bark_enabled.default = "1"

return m
