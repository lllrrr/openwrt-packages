local m = {}

function m.index()
    local page = entry({"admin", "services", "ota"}, alias("admin", "services", "ota", "client"), _("OTA 升级"), 60)
    page.dependent = true
    entry({"admin", "services", "ota", "client"}, template("ota/index"), _("固件升级"), 10).leaf = true
    entry({"admin", "services", "ota", "config"}, cbi("ota"), _("设置"), 20).leaf = true
    entry({"admin", "services", "ota", "info"}, call("get_info")).leaf = true
    entry({"admin", "services", "ota", "check_update"}, call("get_remote_info")).leaf = true
    entry({"admin", "services", "ota", "start"}, call("start_upgrade")).leaf = true
    entry({"admin", "services", "ota", "state"}, call("get_state")).leaf = true
end

function m.get_state()
    local fs = require "nixio.fs"
    local data = fs.readfile("/tmp/ota_state.json")
    luci.http.prepare_content("application/json")
    if data and #data > 5 then 
        luci.http.write(data)
    else
        luci.http.write_json({state = "IDLE", msg = "准备就绪", progress = 0})
    end
end

function m.start_upgrade()
    local selected_file = luci.http.formvalue("filename")
    os.execute("rm -f /tmp/ota_state.json")
    local is_running = os.execute("pgrep -f /usr/bin/ota.sh > /dev/null")
    if is_running == 0 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({ok = false, msg = "升级程序已在后台运行"})
        return
    end
    local cmd = "/usr/bin/ota.sh"
    if selected_file and selected_file ~= "" then
        -- 增加简单的转义处理，防止注入
        cmd = cmd .. " '" .. selected_file:gsub("'", "") .. "'"
    end
    os.execute(cmd .. " > /tmp/ota_build.log 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ok = true})
end

function m.get_info()
    local sys = require "luci.sys"
    local platform = sys.exec("uname -m") or "Unknown"
    local version = sys.exec(". /etc/openwrt_release && echo $DISTRIB_DESCRIPTION")
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        platform = platform:gsub("%s+", ""),
        version = (version or "Unknown"):gsub("\n", "")
    })
end

function m.get_remote_info()
    local uci = require "luci.model.uci".cursor()
    local url = uci:get("ota", "settings", "url")
    local remote_ver = "N/A"
    local file_list = ""
    local changelog = ""
    
    if url and url ~= "" then
        local tmp_json = "/tmp/ota_remote.json"
        local code = os.execute(string.format("wget -qO %s --header='User-Agent: x' --timeout=5 '%s'", tmp_json, url))
        
        if code == 0 then
            local sys = require "luci.sys"
            remote_ver = sys.exec(string.format("jsonfilter -i %s -e '@.tag_name'", tmp_json)) or "N/A"
            changelog = sys.exec(string.format("jsonfilter -i %s -e '@.body'", tmp_json)) or ""
            file_list = sys.exec(string.format("jsonfilter -i %s -e '@.assets[*].name' | grep -E '\\.(img\\.gz|img|bin)$'", tmp_json)) or ""
            os.remove(tmp_json)
        else
            remote_ver = "连接失败"
        end
    end

    -- 统一在此处输出 JSON，不要在 if 分支里重复输出
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        remote_version = remote_ver:gsub("\n", ""),
        files = file_list,
        log = changelog
    })
end

return m