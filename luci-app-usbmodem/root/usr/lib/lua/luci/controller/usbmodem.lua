module("luci.controller.usbmodem", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/usbmodem") then
		return
	end

	local page
	page = entry({"admin", "network", "usbmodem"}, alias("admin", "network", "usbmodem", "status"), _("USB Modem"), 60)
	page.dependent = true

	entry({"admin", "network", "usbmodem", "status"}, template("usbmodem/status"), _("Status"), 10)
	entry({"admin", "network", "usbmodem", "at"}, template("usbmodem/at"), _("AT Commands"), 20)
	entry({"admin", "network", "usbmodem", "config"}, cbi("usbmodem"), _("Settings"), 30)

	-- API 接口，供前端 AJAX 调用
	entry({"admin", "network", "usbmodem", "api", "detect"}, call("api_detect"), nil)
	entry({"admin", "network", "usbmodem", "api", "switch"}, call("api_switch"), nil)
	entry({"admin", "network", "usbmodem", "api", "at"}, call("api_at"), nil)
	entry({"admin", "network", "usbmodem", "api", "sms"}, call("api_sms"), nil)
end

function api_detect()
	luci.http.prepare_content("application/json")
	local handle = io.popen("/usr/bin/usbmodem_detect 2>/dev/null")
	local result = handle:read("*all")
	handle:close()
	luci.http.write(result or '{"iface":"","protocol":"","at_port":""}')
end

function api_switch()
	local mode = luci.http.formvalue("mode")
	if mode then
		os.execute("/usr/bin/usbmodem_switch " .. mode .. " >/dev/null 2>&1")
	end
	luci.http.prepare_content("application/json")
	luci.http.write('{"status":"ok"}')
end

function api_at()
	local cmd = luci.http.formvalue("cmd")
	if cmd then
		local handle = io.popen("/usr/bin/usbmodem_at '" .. cmd:gsub("'", "'\\''") .. "' 2>&1")
		local result = handle:read("*all")
		handle:close()
		luci.http.prepare_content("text/plain")
		luci.http.write(result)
	else
		luci.http.status(400, "Bad Request")
	end
end

function api_sms()
	-- 简单返回最后几条短信（需配合后台保存短信记录文件）
	-- 这里为了演示，返回模拟数据
	luci.http.prepare_content("application/json")
	local f = io.open("/tmp/usbmodem_sms.json", "r")
	if f then
		luci.http.write(f:read("*all"))
		f:close()
	else
		luci.http.write('{"messages":[]}')
	end
end
