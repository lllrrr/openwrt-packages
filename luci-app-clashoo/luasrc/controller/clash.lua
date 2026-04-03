module("luci.controller.clash", package.seeall)
local fs=require"nixio.fs"
local http=require"luci.http"
local uci=require"luci.model.uci".cursor()



function index()

	if not nixio.fs.access("/etc/config/clash") then
		return
	end

	-- luci 24.10+ 通过 menu.d JSON 注册菜单
	local has_menu_d = nixio.fs.access("/usr/share/luci/menu.d/luci-app-clashoo.json")
	if not has_menu_d then
		local page = entry({"admin", "services", "clash"}, alias("admin", "services", "clash", "overview"), "Clash", 1)
		page.dependent = true
		page.acl_depends = {"luci-app-clashoo"}

		entry({"admin", "services", "clash", "overview"},    cbi("clash/overview"),          "概览",     10).leaf = true
		entry({"admin", "services", "clash", "system"},      cbi("clash/system"),            "系统设置", 20).leaf = true
		entry({"admin", "services", "clash", "config_manager"}, cbi("clash/config_manager"), "配置管理", 30).leaf = true
		entry({"admin", "services", "clash", "dns_settings"},cbi("clash/dns_settings"),      "DNS 设置", 40).leaf = true

		-- 隐藏子页（被 config_manager 内部跳转使用）
		entry({"admin", "services", "clash", "proxyprovider"}, cbi("clash/config/proxy_provider"),      nil).leaf = true
		entry({"admin", "services", "clash", "servers"},       cbi("clash/config/servers-config"),       nil).leaf = true
		entry({"admin", "services", "clash", "ruleprovider"},  cbi("clash/config/rule_provider"),        nil).leaf = true
		entry({"admin", "services", "clash", "rules"},         cbi("clash/config/rules"),                nil).leaf = true
		entry({"admin", "services", "clash", "pgroups"},       cbi("clash/config/groups"),               nil).leaf = true
		entry({"admin", "services", "clash", "rulemanager"},   cbi("clash/config/ruleprovider_manager"), nil).leaf = true
		entry({"admin", "services", "clash", "ip-rules"},      cbi("clash/config/ip-rules"),             nil).leaf = true
	end

	-- API 路由
	entry({"admin", "services", "clash", "check_status"}, call("check_status")).leaf = true
	entry({"admin", "services", "clash", "readlog"},       call("action_read")).leaf = true
	entry({"admin", "services", "clash", "status"},        call("action_status")).leaf = true
	entry({"admin", "services", "clash", "set_mode"},      call("do_set_mode")).leaf = true
	entry({"admin", "services", "clash", "set_proxy_mode"},call("do_set_proxy_mode")).leaf = true
	entry({"admin", "services", "clash", "start"},         call("do_start")).leaf = true
	entry({"admin", "services", "clash", "stop"},          call("do_stop")).leaf = true
	entry({"admin", "services", "clash", "reload"},        call("do_reload")).leaf = true
	entry({"admin", "services", "clash", "list_configs"},  call("action_list_configs")).leaf = true
	entry({"admin", "services", "clash", "set_config"},    call("do_set_config")).leaf = true
	entry({"admin", "services", "clash", "doupdate"},      call("do_update")).leaf = true
	entry({"admin", "services", "clash", "check"},         call("check_update_log")).leaf = true
	entry({"admin", "services", "clash", "corelog"},       call("down_check")).leaf = true
	entry({"admin", "services", "clash", "logstatus"},     call("logstatus_check")).leaf = true
	entry({"admin", "services", "clash", "geo"},           call("geoip_check")).leaf = true
	entry({"admin", "services", "clash", "geoipupdate"},   call("geoip_update")).leaf = true
	entry({"admin", "services", "clash", "check_geoip"},   call("check_geoip_log")).leaf = true

end

local fss = require "luci.clash"

local function download_rule_provider()
	local filename = luci.http.formvalue("filename")
  	local status = luci.sys.call(string.format('/usr/share/clash/create/clash_rule_provider.sh "%s" >/dev/null 2>&1',filename))
  	return status
end


function action_update_rule_providers()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
	rulep = download_rule_provider();
})
end


local function uhttp_port()
	local uhttp_port = luci.sys.exec("uci get uhttpd.main.listen_http |awk -F ':' '{print $NF}'")
	if uhttp_port ~= "80" then
		return ":" .. uhttp_port
	end
end

function action_update()
	luci.sys.exec("kill $(pgrep /usr/share/clash/update.sh) ; (bash /usr/share/clash/update.sh >/usr/share/clash/clash.txt 2>&1) &")
end


local function in_use()
	return luci.sys.exec("uci get clash.config.config_type")
end


local function conf_path()
	if nixio.fs.access(string.sub(luci.sys.exec("uci get clash.config.use_config"), 1, -2)) then
	return fss.basename(string.sub(luci.sys.exec("uci get clash.config.use_config"), 1, -2))
	else
	return ""
	end
end



local function typeconf()
	return luci.sys.exec("uci get clash.config.config_type")
end

local function proxy_mode()
	local v = luci.sys.exec("uci -q get clash.config.p_mode 2>/dev/null")
	v = (v or ""):gsub("%s+", "")
	if v == "global" or v == "direct" then
		return v
	end
	return "rule"
end

local function sanitize_config_type(raw)
	raw = (raw or ""):gsub("%s+", "")
	if raw == "1" or raw == "2" or raw == "3" then
		return raw
	end
	return ""
end

local function append_config_list(configs, pattern)
	for path in nixio.fs.glob(pattern) do
		configs[#configs + 1] = fss.basename(path)
	end
end

local function list_configs(conf_type)
	local configs = {}
	conf_type = sanitize_config_type(conf_type)

	if conf_type == "1" then
		append_config_list(configs, '/usr/share/clash/config/sub/*.yaml')
	elseif conf_type == "2" then
		append_config_list(configs, '/usr/share/clash/config/upload/*.yaml')
	elseif conf_type == "3" then
		append_config_list(configs, '/usr/share/clash/config/custom/*.yaml')
	else
		append_config_list(configs, '/usr/share/clash/config/sub/*.yaml')
		append_config_list(configs, '/usr/share/clash/config/upload/*.yaml')
		append_config_list(configs, '/usr/share/clash/config/custom/*.yaml')
	end

	table.sort(configs)
	return configs
end


function action_conf()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
	conf_path = conf_path(),
	typeconf = typeconf(),
	configs = list_configs()

	})
end

function action_list_configs()
	local req_type = sanitize_config_type(luci.http.formvalue("type"))
	if req_type == "" then
		req_type = sanitize_config_type(typeconf())
	end
	luci.http.prepare_content("application/json")
	luci.http.write_json({ configs = list_configs(req_type), current = conf_path(), type = req_type })
end


local function dash_port()
	return luci.sys.exec("uci get clash.config.dash_port 2>/dev/null")
end
local function dash_pass()
	return luci.sys.exec("uci get clash.config.dash_pass 2>/dev/null")
end

local function selected_core_bin()
	local core = luci.sys.exec("uci get clash.config.core 2>/dev/null")
	core = core and core:gsub("\n", "") or ""
	if core == "1" then
		if nixio.fs.access("/etc/clash/clash") then return "/etc/clash/clash" end
		if nixio.fs.access("/usr/bin/clash") then return "/usr/bin/clash" end
	elseif core == "2" then
		if nixio.fs.access("/usr/bin/clash-meta") then return "/usr/bin/clash-meta" end
		if nixio.fs.access("/etc/clash/clash-meta") then return "/etc/clash/clash-meta" end
		if nixio.fs.access("/usr/bin/mihomo") then return "/usr/bin/mihomo" end
	else
		if nixio.fs.access("/usr/bin/mihomo") then return "/usr/bin/mihomo" end
		if nixio.fs.access("/etc/clash/clash") then return "/etc/clash/clash" end
	end
	return ""
end

local function dashboard_panel()
	return luci.sys.exec("uci get clash.config.dashboard_panel 2>/dev/null")
end

local function panel_download_state()
	local f = io.open("/tmp/clash_panel_download_state", "r")
	if not f then
		if nixio.fs.access("/var/run/panel_downloading") then
			return "downloading"
		end
		return ""
	end
	local s = f:read("*l") or ""
	f:close()
	return s
end

local function binary_version(path)
	if nixio.fs.access(path) then
		return luci.sys.exec(path .. " -v 2>/dev/null | awk 'NR==1 { if ($1 == \"Mihomo\") print $3; else print $2 }'")
	end
	return "0"
end

local function clash_binary_core()
	return binary_version("/etc/clash/clash")
end

local function clash_meta_core()
	if nixio.fs.access("/usr/bin/clash-meta") then
		return binary_version("/usr/bin/clash-meta")
	end
	return binary_version("/etc/clash/clash-meta")
end

local function mihomo_core()
	return binary_version("/usr/bin/mihomo")
end

local function new_mihomo_version()
	return luci.sys.exec("sed -n 1p /usr/share/clash/new_mihomo_core_version 2>/dev/null")
end

local function new_clash_meta_version()
	return luci.sys.exec("sed -n 1p /usr/share/clash/new_clash_meta_core_version 2>/dev/null")
end

local function is_running()
	return luci.sys.call("pidof clash >/dev/null || pidof mihomo >/dev/null || pidof clash-meta >/dev/null") == 0
end

local function is_web()
	return luci.sys.call("pidof clash >/dev/null || pidof mihomo >/dev/null || pidof clash-meta >/dev/null") == 0
end

local function localip()
	local ip = luci.sys.exec("uci -q get network.lan.ipaddr 2>/dev/null") or ""
	ip = ip:gsub("%s+", ""):gsub("/%d+$", "")
	if ip == "" then
		ip = luci.sys.exec("ip -4 -o addr show dev br-lan 2>/dev/null | awk '{print $4}' | sed -n '1p'") or ""
		ip = ip:gsub("%s+", ""):gsub("/%d+$", "")
	end
	return ip
end

local function check_version()
	return luci.sys.exec("sh /usr/share/clash/check_luci_version.sh")
end

local function check_core()
	return luci.sys.exec("sh /usr/share/clash/check_core_version.sh")
end


local function current_version()
	return luci.sys.exec("sed -n 1p /usr/share/clash/luci_version")
end

local function new_version()
	return luci.sys.exec("sed -n 1p /usr/share/clash/new_luci_version")
end

local function new_core_version()
	return luci.sys.exec("sed -n 1p /usr/share/clash/new_core_version")
end


local function e_mode()
	return luci.sys.exec("egrep '^ {0,}enhanced-mode' /etc/clash/config.yaml |grep enhanced-mode: |awk -F ': ' '{print $2}'")
end

local function mode_value()
	local tun = luci.sys.exec("uci get clash.config.tun_mode 2>/dev/null")
	tun = tun and tun:gsub("\n", "") or "0"
	if tun == "1" then
		local stack = luci.sys.exec("uci -q get clash.config.stack 2>/dev/null")
		stack = stack and stack:gsub("%s+", "") or "system"
		if stack == "mixed" then
			return "mixed"
		end
		return "tun"
	end
	return "fake-ip"
end

local function ping_enable()
	local v = luci.sys.exec("uci -q get clash.config.ping_enable 2>/dev/null") or ""
	v = v:gsub("%s+", "")
	if v == "" then
		return "0"
	end
	return v
end


local function clash_core()
	local version = luci.sys.exec([[
		for bin in /usr/bin/mihomo /usr/bin/clash-meta /etc/clash/clash; do
			[ -x "$bin" ] || continue
			ver=$($bin -v 2>/dev/null | awk 'NR==1 { if ($1 == "Mihomo") print $3; else print $2 }')
			[ -n "$ver" ] && { echo "$ver"; exit 0; }
		done
	]])

	if version ~= "" then
		return version
	end

	version = luci.sys.exec("sed -n 1p /usr/share/clash/core_version")
	return version ~= "" and version or "0"
end




local function readlog()
	return luci.sys.exec("sed -n '$p' /usr/share/clash/clash_real.txt 2>/dev/null")
end

local function geo_data()
	return os.date("%Y-%m-%d %H:%M:%S",fss.mtime("/etc/clash/Country.mmdb"))
end

local function downcheck()
	if nixio.fs.access("/var/run/core_update_error") then
		return "0"
	elseif nixio.fs.access("/var/run/core_update") then
		return "1"
	elseif nixio.fs.access("/usr/share/clash/core_down_complete") then
		return "2"
	end
end

function action_read()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
	readlog = readlog();
	})
end

function down_check()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
	 downcheck = downcheck();
	})
end

local function geoipcheck()
	if nixio.fs.access("/var/run/geoip_update_error") then
		return "0"
	elseif nixio.fs.access("/var/run/geoip_update") then
		return "1"
	elseif nixio.fs.access("/var/run/geoip_down_complete") then
		return "2"
	end
end

function geoip_check()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
	 geoipcheck = geoipcheck();
	})
end




function check_status()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		check_version = check_version(),
		check_core = check_core(),
		check_mihomo = luci.sys.exec("sh /usr/share/clash/check_mihomo_core_version.sh"),
		check_clash_meta = luci.sys.exec("sh /usr/share/clash/check_clash_meta_version.sh"),
		current_version = current_version(),
		new_version = new_version(),
		clash_core = clash_core(),
		new_core_version = new_core_version(),
		new_mihomo_version = new_mihomo_version(),
		new_clash_meta_version = new_clash_meta_version(),
		conf_path = conf_path(),
		typeconf = typeconf()	
	})
end
function action_status()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		web = is_web(),
		clash = is_running(),
		localip = localip(),
		dash_port = dash_port(),
		dashboard_panel = dashboard_panel(),
		current_version = current_version(),
		new_core_version = new_core_version(),
		new_version = new_version(),
		clash_core = clash_binary_core(),
		clash_meta_core = clash_meta_core(),
		mihomo_core = mihomo_core(),
		dash_pass = dash_pass(),
		new_clash_meta_version = new_clash_meta_version(),
		new_mihomo_version = new_mihomo_version(),
		e_mode = e_mode(),
		mode_value = mode_value(),
		in_use = in_use(),
		conf_path = conf_path(),
		uhttp_port = uhttp_port(),
		typeconf = typeconf(),
		proxy_mode = proxy_mode(),
		panel_download_state = panel_download_state(),
		dashboard_installed = nixio.fs.access("/etc/clash/dashboard/index.html"),
		yacd_installed = nixio.fs.access("/usr/share/clash/yacd/index.html"),
		razord_installed = nixio.fs.access("/etc/clash/dashboard/index.html"),
		zashboard_installed = nixio.fs.access("/etc/clash/dashboard/index.html")
	})
end

function do_set_proxy_mode()
	local mode = (luci.http.formvalue("mode") or ""):gsub("%s+", "")
	if mode ~= "rule" and mode ~= "global" and mode ~= "direct" then
		luci.http.status(400, "Bad Request")
		return
	end

	local rc = luci.sys.call(string.format([[uci set clash.config.p_mode=%q && uci commit clash]], mode))
	if rc ~= 0 then
		luci.http.status(500, "Set Proxy Mode Failed")
		return
	end

	if is_running() then
		luci.sys.call([[/etc/init.d/clash restart >/dev/null 2>&1]])
		luci.sys.call([[sleep 2]])
		if not is_running() then
			luci.http.status(500, "Restart Failed")
			return
		end
	end

	luci.http.status(200, "OK")
end

function action_ping_status()
	luci.http.prepare_content("application/json")
	luci.http.write_json({
		ping_enable = ping_enable()
	})
end

function act_ping()
	local e={}
	e.index=luci.http.formvalue("index")
	e.ping=luci.sys.exec("ping -c 1 -W 1 -w 5 %q 2>&1 | grep -o 'time=[0-9]*.[0-9]' | awk -F '=' '{print$2}'"%luci.http.formvalue("domain"))
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end


function geoip_update()
	fs.writefile("/var/run/geoiplog","0")
	luci.sys.exec("(rm /var/run/geoip_update_error ;  touch /var/run/geoip_update ; sh /usr/share/clash/geoip.sh >/tmp/geoip_update.txt 2>&1  || touch /var/run/geoip_update_error ;rm /var/run/geoip_update) &")
end


function do_update()
	fs.writefile("/var/run/clashlog","0")
	luci.sys.exec("(rm /var/run/core_update_error ;  touch /var/run/core_update ; sh /usr/share/clash/core_download.sh >/tmp/clash_update.txt 2>&1  || touch /var/run/core_update_error ;rm /var/run/core_update) &")
end

function do_start()
	if selected_core_bin() == "" then
		luci.http.status(500, "Core Not Found")
		return
	end
	local rc = luci.sys.call([[uci set clash.config.enable='1' && uci commit clash && /etc/init.d/clash start >/dev/null 2>&1]])
	if rc == 0 or is_running() then
		luci.http.status(200, "OK")
	else
		luci.http.status(500, "Start Failed")
	end
end

function do_stop()
	local rc = luci.sys.call([[uci set clash.config.enable='0' && uci commit clash && /etc/init.d/clash stop >/dev/null 2>&1]])
	if rc == 0 or not is_running() then
		luci.http.status(200, "OK")
	else
		luci.http.status(500, "Stop Failed")
	end
end

function do_reload()
	local rc = luci.sys.call([[/etc/init.d/clash restart >/dev/null 2>&1]])
	if rc == 0 then
		luci.http.status(200, "OK")
	else
		luci.http.status(500, "Reload Failed")
	end
end

function do_set_mode()
	local mode = luci.http.formvalue("mode") or "fake-ip"
	if mode ~= "tun" and mode ~= "fake-ip" and mode ~= "mixed" then
		luci.http.status(400, "Bad Request")
		return
	end

	local rc
	if mode == "tun" or mode == "mixed" then
		local core = luci.sys.exec("uci -q get clash.config.core 2>/dev/null"):gsub("%s+", "")
		local preferred = core
		if core == "1" then
			if nixio.fs.access("/usr/bin/mihomo") then
				preferred = "3"
			elseif nixio.fs.access("/usr/bin/clash-meta") or nixio.fs.access("/etc/clash/clash-meta") then
				preferred = "2"
			end
		end
		local stack = (mode == "mixed") and "mixed" or "system"
		rc = luci.sys.call(string.format(
			[[uci set clash.config.tun_mode='1' && uci set clash.config.core=%q && uci set clash.config.stack=%q && uci set clash.config.enable_udp='1' && uci set clash.config.enhanced_mode='fake-ip' && uci commit clash]],
			preferred ~= "" and preferred or "3", stack))
	else
		rc = luci.sys.call([[uci set clash.config.tun_mode='0' && uci set clash.config.enhanced_mode='fake-ip' && uci commit clash]])
	end

	if rc ~= 0 then
		luci.http.status(500, "Set Mode Failed")
		return
	end

	if is_running() then
		luci.sys.call([[/etc/init.d/clash restart >/dev/null 2>&1]])
		luci.sys.call([[sleep 2]])
		if not is_running() then
			luci.http.status(500, "Restart Failed")
			return
		end
	end

	luci.http.status(200, "OK")
end

function do_set_config()
	local name = luci.http.formvalue("name") or ""
	if name == "" then
		luci.http.status(400, "Bad Request")
		return
	end
	local candidate = "/usr/share/clash/config/sub/" .. name
	local ctype = "1"
	if not nixio.fs.access(candidate) then
		candidate = "/usr/share/clash/config/upload/" .. name
		ctype = "2"
	end
	if not nixio.fs.access(candidate) then
		candidate = "/usr/share/clash/config/custom/" .. name
		ctype = "3"
	end
	if nixio.fs.access(candidate) then
		local rc = luci.sys.call(string.format([[uci set clash.config.use_config=%q && uci set clash.config.config_type=%q && uci commit clash]], candidate, ctype))
		if rc == 0 then
			if is_running() then
				luci.sys.call([[/etc/init.d/clash restart >/dev/null 2>&1]])
				luci.sys.call([[sleep 2]])
				if not is_running() then
					luci.http.status(500, "Restart Failed")
					return
				end
			end
			luci.http.status(200, "OK")
		else
			luci.http.status(500, "Set Config Failed")
		end
	else
		luci.http.status(404, "Not Found")
	end
end

function do_set_config_type()
	local ctype = sanitize_config_type(luci.http.formvalue("type"))
	if ctype == "" then
		luci.http.status(400, "Bad Request")
		return
	end

	local base_map = {
		["1"] = "/usr/share/clash/config/sub/",
		["2"] = "/usr/share/clash/config/upload/",
		["3"] = "/usr/share/clash/config/custom/"
	}

	local basedir = base_map[ctype]
	local current = uci:get("clash", "config", "use_config") or ""
	local current_ok = current ~= "" and current:sub(1, #basedir) == basedir and nixio.fs.access(current)

	uci:set("clash", "config", "config_type", ctype)
	if not current_ok then
		local configs = list_configs(ctype)
		if #configs > 0 then
			uci:set("clash", "config", "use_config", basedir .. configs[1])
		else
			uci:delete("clash", "config", "use_config")
		end
	end
	uci:commit("clash")
	luci.http.status(200, "OK")
end

function do_set_panel()
	local name = luci.http.formvalue("name") or "metacubexd"
	if name ~= "metacubexd" and name ~= "yacd" and name ~= "zashboard" and name ~= "razord" then
		name = "metacubexd"
	end
	local rc = luci.sys.call(string.format([[uci set clash.config.dashboard_panel=%q && uci commit clash]], name))
	if rc == 0 then
		luci.http.status(200, "OK")
	else
		luci.http.status(500, "Set Panel Failed")
	end
end

function do_download_panel()
	local name = luci.http.formvalue("name") or luci.sys.exec("uci -q get clash.config.dashboard_panel 2>/dev/null")
	name = (name or ""):gsub("%s+", "")
	if name ~= "metacubexd" and name ~= "yacd" and name ~= "zashboard" and name ~= "razord" then
		name = "metacubexd"
	end
	local rc = luci.sys.call(string.format([[sh /usr/share/clash/panel_download.sh %q >/dev/null 2>&1 &]], name))
	if rc == 0 then
		luci.http.status(200, "OK")
	else
		luci.http.status(500, "Download Failed")
	end
end

function check_update_log()
	luci.http.prepare_content("text/plain; charset=utf-8")
	local clashlog_pos = fs.readfile("/var/run/clashlog") or "0"
	local fdp=tonumber(clashlog_pos) or 0
	local f=io.open("/tmp/clash_update.txt", "r+")
	if not f then
		luci.http.write("\0")
		return
	end
	f:seek("set",fdp)
	local a=f:read(2048000) or ""
	fdp=f:seek()
	fs.writefile("/var/run/clashlog",tostring(fdp))
	f:close()
if fs.access("/var/run/core_update") then
	luci.http.write(a)
else
	luci.http.write(a.."\0")
end
end

function check_geoip_log()
	luci.http.prepare_content("text/plain; charset=utf-8")
	local geoiplog_pos = fs.readfile("/var/run/geoiplog") or "0"
	local fdp=tonumber(geoiplog_pos) or 0
	local f=io.open("/tmp/geoip_update.txt", "r+")
	if not f then
		luci.http.write("\0")
		return
	end
	f:seek("set",fdp)
	local a=f:read(2048000) or ""
	fdp=f:seek()
	fs.writefile("/var/run/geoiplog",tostring(fdp))
	f:close()
if fs.access("/var/run/geoip_update") then
	luci.http.write(a)
else
	luci.http.write(a.."\0")
end
end


function logstatus_check()
	luci.http.prepare_content("text/plain; charset=utf-8")
	local logstatus_pos = fs.readfile("/usr/share/clash/logstatus_check") or "0"
	local fdp=tonumber(logstatus_pos) or 0
	local f=io.open("/usr/share/clash/clash.txt", "r+")
	f:seek("set",fdp)
	local a=f:read(2048000) or ""
	fdp=f:seek()
	fs.writefile("/usr/share/clash/logstatus_check",tostring(fdp))
	f:close()
if fs.access("/var/run/logstatus") then
	luci.http.write(a)
else
	luci.http.write(a.."\0")
end
end
