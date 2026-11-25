-- AdGuard Home 管理中心 - LuCI 控制器
-- 负责菜单注册、状态查询、内核安装、服务控制和密码修改。
module("luci.controller.adguardhome_lite", package.seeall)

local fs = require "nixio.fs"
local http = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local util = require "luci.model.adguardhome_lite.util"
local codes = require "luci.model.adguardhome_lite.codes"
local agh = require "luci.model.adguardhome_lite.agh"
local selftest = require "luci.model.adguardhome_lite.selftest"

-- 纯函数集中在 model 模块中，便于单元测试；此处仅做本地别名
local split_words = util.split_words
local join_words = util.join_words
local valid_iface_name = util.valid_iface_name
local valid_client_spec = util.valid_client_spec
local version_newer = util.version_newer
local clean_tag = util.clean_tag

local CONF = "adguardhome_lite"
local SHARE = "/usr/share/adguardhome-lite"
local RUN = "/var/run/adguardhome_lite"
local STATS_CACHE = RUN .. "_stats.json"
local VERSION_CACHE = RUN .. "_core_version"
local CORE_UPDATE = RUN .. "_core_update"
local PLUGIN_UPDATE = RUN .. "_plugin_update"
local INSTALL_VERSION = SHARE .. "/install_version"
local RELEASE_URL = "https://github.com/Ozero-top/luci-app-adguardhome-lite/releases/latest"

-- 前置声明：action_status 会内联统计结果，定义在下方
local collect_stats

-- 读取带 TTL 的临时缓存，避免每次请求都重新执行外部命令
local function read_cache(path, ttl)
    local mtime = fs.stat(path, "mtime")
    if not mtime then
        return nil
    end
    if ttl and (os.time() - mtime) > ttl then
        return nil
    end
    local data = fs.readfile(path)
    if not data or data == "" then
        return nil
    end
    return data
end

local function cfg(opt, default)
    local v = uci:get(CONF, "main", opt)
    if v == nil then
        v = uci:get(CONF, "@adguardhome_lite[0]", opt)
    end
    if v == nil or v == "" then
        return default
    end
    return v
end

-- 老版本升级时 UCI 还没有缓存选项，读取 YAML 现有值作为界面初值，
-- 避免第一次打开页面就把用户原来的缓存状态显示错。
local CACHE_YAML_KEYS = {
    cache_enabled = "cache_enabled",
    cache_size_mb = "cache_size",
    cache_ttl_min = "cache_ttl_min",
    cache_ttl_max = "cache_ttl_max",
    cache_optimistic = "cache_optimistic"
}

local function yaml_cache_scalar(path, key)
    local data = fs.readfile(path)
    if not data then
        return nil
    end
    local v = data:match("\n  " .. key .. ":[ \t]*([^\r\n#]+)")
    if not v then
        return nil
    end
    return v:match("^%s*(.-)%s*$")
end

-- 读取 YAML 中某个两空格键的列表值（支持多行、行内 [a, b] 和单值写法），
-- 用于判断当前上游 DNS 是否仍由插件管理。
local function yaml_list_values(path, key)
    local data = fs.readfile(path)
    if not data then
        return ""
    end

    local values = {}
    local inlist = false
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if not inlist then
            local inline = line:match("^  " .. key .. ":%s*(.-)%s*$")
            if inline then
                if inline:sub(1, 1) == "[" then
                    inline = inline:sub(2):gsub("%]%s*$", "")
                    for v in inline:gmatch("[^,]+") do
                        v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub('"', "")
                        if v ~= "" then
                            values[#values + 1] = v
                        end
                    end
                    return table.concat(values, " ")
                end
                if inline ~= "" then
                    return (inline:gsub('"', ""))
                end
                inlist = true
            end
        else
            local v = line:match("^    %- (.+)$")
            if v then
                v = v:gsub("^%s+", ""):gsub("%s+$", "")
                if v ~= "" then
                    values[#values + 1] = v
                end
            else
                break
            end
        end
    end

    return table.concat(values, " ")
end

-- 读取 filtering.safe_search.enabled（多一层嵌套）
local function yaml_safe_search_enabled(path)
    local data = fs.readfile(path)
    if not data then
        return false
    end
    local in_block = false
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^  safe_search:%s*$") then
            in_block = true
        elseif in_block then
            local v = line:match("^    enabled:%s*(%S+)")
            if v then
                return v == "true"
            end
            if line:match("^  [^ ]") then
                break
            end
        end
    end
    return false
end

-- 读取某个顶级段的二级标量，例如 statistics.interval、querylog.interval
local function yaml_section_scalar(path, section, key)
    local data = fs.readfile(path)
    if not data then
        return nil
    end
    local insec = false
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if not insec then
            if line:match("^" .. section .. ":%s*$") then
                insec = true
            end
        else
            local v = line:match("^  " .. key .. ":%s*(.-)%s*$")
            if v then
                return v
            end
            if line:match("^[^%s]") then
                return nil
            end
        end
    end
    return nil
end

-- 写入某个顶级段的二级标量，保留文件其他内容
local function yaml_set_section_scalar(path, section, key, value)
    local data = fs.readfile(path)
    if not data then
        return false
    end

    local out = {}
    local insec = false
    local replaced = false
    for line in data:gmatch("([^\n]*)\n") do
        if not insec then
            if line:match("^" .. section .. ":%s*$") then
                insec = true
            end
            out[#out + 1] = line
        elseif line:match("^  " .. key .. ":") then
            out[#out + 1] = "  " .. key .. ": " .. value
            insec = false
            replaced = true
        elseif line:match("^[^%s]") then
            out[#out + 1] = line
            insec = false
        else
            out[#out + 1] = line
        end
    end

    if not replaced then
        return false
    end

    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write(table.concat(out, "\n") .. "\n")
    f:close()
    return true
end

-- 缓存配置以 AdGuard Home 的 YAML 为准（AGH 面板与插件 UI 共用同一份），
-- YAML 不存在或缺少字段时才回退到 UCI / 默认值。
local function cache_option(configpath, key, default)
    local raw = yaml_cache_scalar(configpath, CACHE_YAML_KEYS[key])
    if raw ~= nil and raw ~= "" then
        raw = raw:gsub('"', "")

        if key == "cache_enabled" or key == "cache_optimistic" then
            if raw == "true" then
                return "1"
            elseif raw == "false" then
                return "0"
            end
            return default
        elseif key == "cache_size_mb" then
            local bytes = tonumber(raw)
            if bytes and bytes > 0 then
                return tostring(math.floor(bytes / 1048576 + 0.5))
            end
            return default
        end

        local n = tonumber(raw)
        if n then
            return tostring(math.floor(n))
        end
        return default
    end

    local v = uci:get(CONF, "main", key)
    if v ~= nil and v ~= "" then
        return v
    end
    return default
end

-- 排除列表（接口 / 客户端 IP）的解析与校验。
-- 这些值最终会写进 nft 规则文件，必须先做严格的白名单校验。
-- 接口候选只取 /sys/class/net 下的目录；内核自带的空隧道/占位设备一并跳过。
local IGNORED_IFACE_PATTERNS = {
    "^lo$", "^dummy%d+$", "^sit%d+$", "^ip6tnl%d+$", "^tunl%d+$",
    "^gre%d+$", "^gretap%d+$", "^erspan%d+$", "^ip6gre%d+$",
    "^ip6_vti%d+$", "^teql%d+$", "^siit%d+$", "^utun%d*$",
}

local function iface_ignored(name)
    for _, pat in ipairs(IGNORED_IFACE_PATTERNS) do
        if name:match(pat) then
            return true
        end
    end
    return false
end

local function net_devices()
    local out = sys.exec("for d in /sys/class/net/*; do [ -d \"$d\" ] && echo \"${d##*/}\"; done") or ""
    local list = {}
    for name in out:gmatch("[^\n]+") do
        if not iface_ignored(name) and valid_iface_name(name) then
            list[#list + 1] = name
        end
    end
    table.sort(list)
    return list
end

local function is_enabled()
    local v = cfg("enabled", "0")
    return v == "1" or v == 1 or v == true
end

local function core_version(binpath)
    if not fs.access(binpath, "x") then
        return ""
    end

    -- 优先使用缓存：只要内核文件没变，就直接复用上次结果，
    -- 避免每次刷新页面都启动一次 30MB 的内核查版本。
    local bin_mtime = fs.stat(binpath, "mtime")
    local cache_mtime = fs.stat(VERSION_CACHE, "mtime")
    if bin_mtime and cache_mtime and cache_mtime >= bin_mtime then
        local cached = fs.readfile(VERSION_CACHE)
        if cached and cached ~= "" then
            return (cached:gsub("%s+$", ""))
        end
    end

    local out = sys.exec(string.format("%q --version 2>/dev/null | head -n 1", binpath))
    if not out or out == "" then
        return ""
    end

    -- 版本号可能带预发布后缀（v1.0.0-b.2），不能只取数字和小数点
    local ver = out:match("[vV]%d[%w%.%-]*") or ""
    ver = ver:gsub("[^%w%.%-]+$", "")
    if ver ~= "" then
        fs.writefile(VERSION_CACHE, ver)
    end
    return ver
end

-- 从标签列表里取语义版本最大的一个；旧缓存没有列表时退回单值
local function latest_tag(list, fallback)
    local best = fallback or ""
    for tag in tostring(list or ""):gmatch("%S+") do
        local v = clean_tag(tag)
        if v ~= "" and (best == "" or version_newer(v, best)) then
            best = v
        end
    end
    return best
end

-- 旧版本通道：取最新正式版之外的上一条正式版本线（如 1.0.0 之前是 0.107.x）
local function legacy_tag(list, latest_stable)
    local current_series = tostring(latest_stable or ""):match("^(%d+%.%d+)")
    if not current_series then
        return ""
    end
    local best = ""
    for tag in tostring(list or ""):gmatch("%S+") do
        local v = clean_tag(tag)
        if v ~= "" and v:match("^(%d+%.%d+)") ~= current_series
            and (best == "" or version_newer(v, best)) then
            best = v
        end
    end
    return best
end

-- 内核更新检查：按「内核更新通道」取对应最新版本，结果缓存 24 小时
local function core_update_info(binpath, channel)
    local cache = fs.readfile(CORE_UPDATE) or ""
    local stable_tags = cache:match("stable_tags=([^\n]*)") or ""
    local beta_tags = cache:match("beta_tags=([^\n]*)") or ""
    local stable = latest_tag(stable_tags, clean_tag(cache:match("stable=([^\n]*)")))
    local beta_tag = latest_tag(beta_tags, clean_tag(cache:match("beta=([^\n]*)")))
    local legacy = legacy_tag(stable_tags, stable)
    local checked = tonumber(cache:match("time=(%d+)"))

    -- 拿到结果才缓存一天；检查失败时只缓存一小时，尽快重试
    local ttl = (stable ~= "" and beta_tag ~= "") and 86400 or 3600
    if not checked or (os.time() - checked) > ttl then
        -- 先写占位时间，避免每次轮询都重复启动检查任务；已有标签列表保留
        fs.writefile(CORE_UPDATE, string.format(
            "stable=%s\nbeta=%s\nstable_tags=%s\nbeta_tags=%s\ntime=%d\n",
            stable, beta_tag, stable_tags, beta_tags, os.time()))
        sys.exec("sh " .. SHARE .. "/check_core_update.sh >/dev/null 2>&1 &")
    elseif channel == "legacy" and legacy == "" and stable_tags == "" then
        -- 旧版缓存没有标签列表，算不出上一条版本线，主动补查一次
        sys.exec("sh " .. SHARE .. "/check_core_update.sh >/dev/null 2>&1 &")
    end

    -- 三个通道各自独立：正式版只取正式标签，预发布版只取预发布标签，
    -- 旧版本只取上一条正式版本线。不能把 beta 和 stable 混在一起比大小，
    -- 否则 1.0.0 会盖掉 1.0.0-b.2，导致选了预发布版却安装正式版。
    local latest = ""
    if channel == "beta" then
        latest = beta_tag ~= "" and beta_tag or stable
    elseif channel == "legacy" then
        latest = legacy
    else
        latest = stable
    end

    local current = core_version(binpath)
    return {
        current = current,
        latest = latest,
        -- 通道由 Releases API 的 prerelease 标记决定，不能只看版本号里的 -b
        beta = (channel == "beta" and beta_tag ~= "" and latest == beta_tag),
        update = (latest ~= "" and current ~= "" and version_newer(latest, current)) or false
    }
end

-- 插件版本：取包管理器与 install.sh 记录中较新的一个，兼容 ipk 与脚本安装混用
local function plugin_version()
    -- 通用模式安装（含强制降级）以 install_version 为准，避免包管理器里的旧高版本覆盖显示
    if fs.access(SHARE .. "/install_source") then
        local v = (fs.readfile(INSTALL_VERSION) or ""):gsub("%s+", "")
        if v:match("^%d+%.%d+") then
            fs.writefile(RUN .. "_plugin_version", v)
            return v
        end
    end

    local cached = read_cache(RUN .. "_plugin_version", 3600)
    if cached and cached ~= "" then
        return cached
    end

    local candidates = {}

    local out = sys.exec("opkg list-installed 2>/dev/null | awk '$1 == \"luci-app-adguardhome-lite\" { print $3; exit }'") or ""
    out = out:gsub("%s+", "")
    if out ~= "" then
        candidates[#candidates + 1] = out
    end

    out = sys.exec("apk info -v luci-app-adguardhome-lite 2>/dev/null | head -n 1") or ""
    local ver = out:match("%d+%.%d+%.%d+[%w%.%-]*")
    if ver then
        candidates[#candidates + 1] = ver
    end

    local v = (fs.readfile(INSTALL_VERSION) or ""):gsub("%s+", "")
    if v:match("^%d+%.%d+") then
        candidates[#candidates + 1] = v
    end

    local best = ""
    for i = 1, #candidates do
        if best == "" or version_newer(candidates[i], best) then
            best = candidates[i]
        end
    end

    if best ~= "" then
        fs.writefile(RUN .. "_plugin_version", best)
    end
    return best
end

-- 插件更新检查：结果缓存 24 小时，过期后在后台重新检查，不阻塞状态接口
local function plugin_update_info()
    local cache = fs.readfile(PLUGIN_UPDATE) or ""
    local latest = clean_tag(cache:match("latest=([^\n]*)"))
    local checked = tonumber(cache:match("time=(%d+)"))
    local notes = cache:match("notes<<EOF\n(.-)\nEOF") or ""
    local failed = cache:match("failed=1") ~= nil
    -- 插件 Release 都是正式版，不比内核的正式版 / 预发布版通道，直接比版本号
    local current = plugin_version()

    -- 拿到结果才缓存一天；失败后等 10 分钟再重试，避免离线时随每次状态轮询重复请求
    local ttl = failed and 600 or ((latest ~= "") and 86400 or 3600)
    local age = checked and (os.time() - checked) or math.huge
    -- 旧缓存没有更新说明时补一次；留 60 秒给后台任务，仍取不到则记 nonotes=1 避免反复请求
    local need_notes = latest ~= "" and notes == "" and not failed
        and not cache:match("nonotes=1") and age > 60
    if need_notes or age > ttl then
        -- 先写占位时间，保留已有说明与失败标记，避免每次轮询都重复启动检查任务
        local placeholder = "latest=" .. latest .. "\ntime=" .. os.time() .. "\n"
        if notes ~= "" then
            placeholder = placeholder .. "notes<<EOF\n" .. notes .. "\nEOF\n"
        end
        if failed then
            placeholder = placeholder .. "failed=1\n"
        end
        fs.writefile(PLUGIN_UPDATE, placeholder)
        -- 传入当前版本，让检查脚本合并所有中间版本的更新说明
        sys.exec("sh " .. SHARE .. "/check_plugin_update.sh "
            .. string.format("%q", current) .. " >/dev/null 2>&1 &")
    end

    local newer = version_newer(latest, current)

    local url = RELEASE_URL
    if latest ~= "" then
        url = "https://github.com/Ozero-top/luci-app-adguardhome-lite/releases/tag/v" .. latest
    end

    return {
        current = current,
        latest = latest,
        update = newer,
        url = url,
        -- 仅在确实有新版本时返回；内容已由检查脚本限制在 12KB 内，可包含多个版本的说明
        notes = newer and notes or ""
    }
end

local function service_running(binpath)
    if not binpath or binpath == "" then
        return false
    end

    if sys.call(string.format("pgrep -f %q >/dev/null 2>&1", binpath)) == 0 then
        return true
    end

    return sys.call(string.format("ps w 2>/dev/null | grep -v grep | grep -F %q >/dev/null 2>&1", binpath)) == 0
end

-- 检测 Clash 的 53 劫持目标端口（兼容 redirect to :PORT 与 dnat ... :PORT）
local function openclash_hijack_port()
    local out = sys.exec("nft list chain inet fw4 dstnat 2>/dev/null | grep 'Clash DNS Hijack' | head -n 1")
    if not out or out == "" then
        return ""
    end

    local p = out:match("redirect to :(%d+)") or out:match("dnat.*:(%d+)")
    return p or ""
end

local function openclash_running()
    return sys.call("pidof clash >/dev/null 2>&1") == 0
end

-- Clash 是否启用了自定义上游 DNS，且其中包含指向 AdGuard Home 的条目
local function openclash_upstream_agh(port)
    local found = false
    pcall(function()
        uci:foreach("openclash", "dns_servers", function(s)
            local enabled = tostring(s.enabled or "1")
            local sport = tostring(s.port or "")
            if enabled ~= "0" and s.group == "nameserver"
                and s.ip == "127.0.0.1" and sport == tostring(port) then
                found = true
            end
        end)
    end)
    return found
end

local function passwall_enabled()
    if (uci:get("passwall2", "@global[0]", "enabled") or "") == "1" then
        return true
    end
    return (uci:get("passwall", "@global[0]", "enabled") or "") == "1"
end

-- 端口由 get_new_port 动态分配：PassWall 1.x 从 11400 起，变量名 ACL_default_dns_port；
-- PassWall 2.x 从 2001 起，默认 ACL 的变量名为 ACL_acl_default_dns_port。
-- 两者都装时以 PassWall2 为准，避免读到 1.x 的残留运行时文件。
local function passwall_dns_port()
    local files, keys, fallback
    if (uci:get("passwall2", "@global[0]", "enabled") or "") == "1" then
        files = { "/tmp/etc/passwall2/var", "/tmp/etc/passwall2_tmp/var" }
        keys = { "ACL_acl_default_dns_port", "ACL_default_dns_port" }
        fallback = "2001"
    else
        files = { "/tmp/etc/passwall/var", "/tmp/etc/passwall_tmp/var" }
        keys = { "ACL_default_dns_port" }
        fallback = "11400"
    end
    for _, f in ipairs(files) do
        local content = fs.readfile(f)
        if content then
            for _, key in ipairs(keys) do
                local port = content:match(key .. "=[\"']?(%d+)")
                if port then
                    return port
                end
            end
        end
    end
    return fallback
end

local function read_number(path)
    local v = fs.readfile(path)
    if not v then
        return nil
    end
    v = v:match("[-]?%d+")
    return v and tonumber(v) or nil
end

local function update_running()
    if not fs.access(RUN .. "_update.lock") then
        return false
    end

    local pid = read_number(RUN .. "_update.pid")
    if pid and pid > 0 and sys.call("kill -0 " .. tostring(pid) .. " >/dev/null 2>&1") == 0 then
        return true
    end

    -- 刚创建锁但 PID 尚未写入时，给任务一个短暂的启动时间
    local mtime = fs.stat(RUN .. "_update.lock", "mtime")
    if mtime and (os.time() - mtime) < 60 then
        return true
    end

    -- 锁文件已过期，清理后允许重新执行
    fs.remove(RUN .. "_update.lock")
    fs.remove(RUN .. "_update.pid")
    return false
end

local function action_running()
    if not fs.access(RUN .. "_action.running") then
        return false
    end

    local mtime = fs.stat(RUN .. "_action.running", "mtime")
    if mtime and (os.time() - mtime) > 300 then
        fs.remove(RUN .. "_action.running")
        return false
    end

    return true
end

local function start_action(cmd)
    fs.writefile(RUN .. "_action.code", "")
    fs.writefile(RUN .. "_action.running", "1")
    sys.exec("( " .. cmd .. "; rc=$?; echo $rc > " .. RUN .. "_action.code; rm -f " .. RUN .. "_action.running ) >" .. RUN .. "_action.log 2>&1 &")
end

local function check_token()
    local token = http.formvalue("token")
    if not token then
        return false
    end

    -- 与 LuCI 分发器使用同一个会话令牌。延迟 require，避免菜单扫描阶段初始化上下文失败。
    local expected = context and context.authtoken
    if not expected then
        local ok, disp = pcall(require, "luci.dispatcher")
        if ok and disp and disp.context then
            expected = disp.context.authtoken
        end
    end
    if expected then
        return token == expected
    end

    local ok, csrf = pcall(require, "luci.csrf")
    if ok and csrf and type(csrf.check) == "function" then
        return csrf.check(token)
    end

    return false
end

local function require_post()
    if not check_token() then
        -- 用 JSON 返回，前端才能识别为令牌失效并取新令牌重试一次
        http.status(403)
        http.prepare_content("application/json")
        http.write_json({
            ok = false,
            error = "登录状态已失效，请刷新页面后重试。",
            reason = "auth_required",
            level = codes.level("auth_required")
        })
        return false
    end

    return true
end

local function default_reason(status)
    if status == 403 then
        return "permission_denied"
    elseif status == 409 then
        return "update_busy"
    elseif status >= 500 then
        return "request_failed"
    end
    return "invalid_param"
end

local function json_error(msg, code, reason)
    local status = code or 400
    reason = reason or default_reason(status)
    http.status(status)
    http.prepare_content("application/json")
    http.write_json({
        ok = false,
        error = msg,
        reason = reason,
        level = codes.level(reason)
    })
end

-- 读取持久化状态（上次应用/更新/回退结果），仅用于展示与排障
local function state_value(key)
    local raw = fs.readfile("/etc/adguardhome_lite/state/" .. key) or ""
    return (raw:gsub("%s+$", ""))
end

-- 本机 AdGuard Home 接口：凭据与请求细节在 model/agh.lua 中统一处理
local function agh_client()
    agh.configure({
        user = cfg("adminuser", "admin"),
        pass = cfg("adminpass", "admin123"),
        port = tonumber(cfg("webport", "13800")) or 13800
    })
    return agh
end

local function agh_request(path, method, body, timeout)
    return agh_client().request(path, method, body, timeout)
end

function index()
    local root = entry(
        { "admin", "services", "adguardhome_lite" },
        template("adguardhome_lite/wrapper"),
        "AdGuard Home 管理中心",
        60
    )
    root.dependent = true
    root.acl_depends = { "luci-app-adguardhome-lite" }

    -- 右侧独立页面在 iframe 中渲染，彻底隔离 LuCI 主题样式
    entry({ "admin", "services", "adguardhome_lite", "frame" }, template("adguardhome_lite/panel")).leaf = true

    -- 独立管理页面的 JSON 接口（不出现在菜单中）
    entry({ "admin", "services", "adguardhome_lite", "status" }, call("action_status")).leaf = true
    -- 手机 App 登录后取得会话令牌，避免解析页面 HTML
    entry({ "admin", "services", "adguardhome_lite", "session" }, call("action_session")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "stats_clear" }, call("action_stats_clear")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "filters_get" }, call("action_filters_get")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "filters_save" }, call("action_filters_save")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "querylog_get" }, call("action_querylog_get")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "retention_save" }, call("action_retention_save")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "core_install" }, call("action_core_install")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "core_progress" }, call("action_core_progress")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "plugin_update" }, call("action_plugin_update")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "plugin_check" }, call("action_plugin_check")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "plugin_progress" }, call("action_plugin_progress")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "service" }, call("action_service")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "password" }, call("action_password")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "logs_raw" }, call("action_logs")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "settings_get" }, call("action_settings_get")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "settings_save" }, call("action_settings_save")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "yaml_get" }, call("action_yaml_get")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "yaml_save" }, call("action_yaml_save")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "legacy_scan" }, call("action_legacy_scan")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "legacy_clean" }, call("action_legacy_clean")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "selftest" }, call("action_selftest")).leaf = true
end

-- 从 AdGuard Home 本地接口读取过滤统计，插件页面无需打开 AGH 面板。
-- 结果缓存 8 秒：页面 10 秒轮询时每次都能拿到新数据，又不会重复请求。
collect_stats = function()
    local cached = read_cache(STATS_CACHE, 8)
    if cached then
        local ok, jsonc = pcall(require, "luci.jsonc")
        if ok then
            local parsed = jsonc.parse(cached)
            if type(parsed) == "table" then
                return parsed
            end
        end
    end

    local _, raw = agh_request("/control/stats", "GET")

    if not raw or raw == "" then
        return { ok = false, error = "AdGuard Home 未运行或统计接口不可用。" }
    end

    local ok_req, jsonc = pcall(require, "luci.jsonc")
    if not ok_req then
        return { ok = false, error = "缺少 luci-lib-jsonc，无法解析统计结果。" }
    end

    local stats = jsonc.parse(raw)
    if type(stats) ~= "table" then
        return { ok = false, error = "统计接口返回格式异常。" }
    end

    -- 防护/安全浏览/家长控制等开关直接读 YAML，省掉一次 HTTP 请求
    local yaml_text = fs.readfile(cfg("config", "/etc/AdGuardHome.yaml")) or ""

    local data = {
        ok = true,
        queries = stats.num_dns_queries or 0,
        blocked = stats.num_blocked_filtering or 0,
        malware = stats.num_replaced_safebrowsing or 0,
        adult = stats.num_replaced_parental or 0,
        safesearch = stats.num_replaced_safesearch or 0,
        avg = stats.avg_processing_time or 0,
        protection = yaml_text:match("\n  protection_enabled:%s*true") ~= nil,
        safebrowsing = yaml_text:match("\n  safebrowsing_enabled:%s*true") ~= nil,
        parental = yaml_text:match("\n  parental_enabled:%s*true") ~= nil,
        adult_filter = yaml_text:find("nsfw.txt", 1, true) ~= nil,
        top_blocked = {}
    }

    local top = stats.top_blocked_domains
    if type(top) == "table" then
        for i = 1, math.min(#top, 5) do
            local item = top[i]
            if type(item) == "table" then
                for domain, count in pairs(item) do
                    data.top_blocked[#data.top_blocked + 1] = { domain = domain, count = count }
                end
            end
        end
    end

    local encoded = jsonc.stringify(data)
    if encoded and encoded ~= "" then
        fs.writefile(STATS_CACHE, encoded)
    end

    return data
end

-- 清空 AdGuard Home 统计：调用官方 /control/stats_reset，并删除插件侧缓存

-- 历史调用名保持不变，内部统一走 netrc 凭据方式
local agh_api = agh_request

local function interval_days(value, default)
    local n, unit = tostring(value or ""):match("^(%d+)%s*([dhms])$")
    n = tonumber(n)
    if not n or n < 1 then
        return default
    end
    if unit == "h" then
        return math.max(1, math.floor(n / 24 + 0.5))
    elseif unit == "s" then
        return math.max(1, math.floor(n / 86400 + 0.5))
    end
    return n
end

-- DNS 自检：只读检查内核、进程、面板端口与 DNS 查询链路，不修改任何配置

-- 旧版残留扫描：只读，返回 JSON 清单

-- 旧版残留清理：先备份，再删除旧插件文件、移动旧内核

-- ===== 动作层：具体实现已拆分到 model/adguardhome_lite/actions/ =====
local dashboard_actions = require "luci.model.adguardhome_lite.actions.dashboard"
local core_actions = require "luci.model.adguardhome_lite.actions.core"
local plugin_actions = require "luci.model.adguardhome_lite.actions.plugin"
local service_actions = require "luci.model.adguardhome_lite.actions.service"
local settings_actions = require "luci.model.adguardhome_lite.actions.settings"
local rules_actions = require "luci.model.adguardhome_lite.actions.rules"
local logs_actions = require "luci.model.adguardhome_lite.actions.logs"
local legacy_actions = require "luci.model.adguardhome_lite.actions.legacy"
local session_actions = require "luci.model.adguardhome_lite.actions.session"

local function action_ctx()
    return {
        fs = fs,
        http = http,
        sys = sys,
        uci = uci,
        util = util,
        codes = codes,
        agh = agh,
        selftest = selftest,
        split_words = split_words,
        join_words = join_words,
        valid_iface_name = valid_iface_name,
        valid_client_spec = valid_client_spec,
        version_newer = version_newer,
        clean_tag = clean_tag,
        CONF = CONF,
        SHARE = SHARE,
        RUN = RUN,
        STATS_CACHE = STATS_CACHE,
        VERSION_CACHE = VERSION_CACHE,
        CORE_UPDATE = CORE_UPDATE,
        PLUGIN_UPDATE = PLUGIN_UPDATE,
        INSTALL_VERSION = INSTALL_VERSION,
        RELEASE_URL = RELEASE_URL,
        collect_stats = collect_stats,
        read_cache = read_cache,
        cfg = cfg,
        CACHE_YAML_KEYS = CACHE_YAML_KEYS,
        yaml_cache_scalar = yaml_cache_scalar,
        yaml_list_values = yaml_list_values,
        yaml_safe_search_enabled = yaml_safe_search_enabled,
        yaml_section_scalar = yaml_section_scalar,
        yaml_set_section_scalar = yaml_set_section_scalar,
        cache_option = cache_option,
        IGNORED_IFACE_PATTERNS = IGNORED_IFACE_PATTERNS,
        iface_ignored = iface_ignored,
        net_devices = net_devices,
        is_enabled = is_enabled,
        core_version = core_version,
        core_update_info = core_update_info,
        plugin_version = plugin_version,
        plugin_update_info = plugin_update_info,
        service_running = service_running,
        openclash_hijack_port = openclash_hijack_port,
        openclash_running = openclash_running,
        openclash_upstream_agh = openclash_upstream_agh,
        passwall_enabled = passwall_enabled,
        passwall_dns_port = passwall_dns_port,
        read_number = read_number,
        update_running = update_running,
        action_running = action_running,
        start_action = start_action,
        check_token = check_token,
        require_post = require_post,
        default_reason = default_reason,
        json_error = json_error,
        state_value = state_value,
        agh_client = agh_client,
        agh_request = agh_request,
        agh_api = agh_api,
        interval_days = interval_days
    }
end

function action_status() return dashboard_actions.status(action_ctx()) end
function action_session() return session_actions.session(action_ctx()) end
function action_stats_clear() return dashboard_actions.stats_clear(action_ctx()) end
function action_core_install() return core_actions.core_install(action_ctx()) end
function action_core_progress() return core_actions.core_progress(action_ctx()) end
function action_plugin_update() return plugin_actions.plugin_update(action_ctx()) end
function action_plugin_check() return plugin_actions.plugin_check(action_ctx()) end
function action_plugin_progress() return plugin_actions.plugin_progress(action_ctx()) end
function action_service() return service_actions.service(action_ctx()) end
function action_password() return service_actions.password(action_ctx()) end
function action_selftest() return service_actions.selftest(action_ctx()) end
function action_settings_get() return settings_actions.settings_get(action_ctx()) end
function action_settings_save() return settings_actions.settings_save(action_ctx()) end
function action_yaml_get() return settings_actions.yaml_get(action_ctx()) end
function action_yaml_save() return settings_actions.yaml_save(action_ctx()) end
function action_filters_get() return rules_actions.filters_get(action_ctx()) end
function action_filters_save() return rules_actions.filters_save(action_ctx()) end
function action_querylog_get() return rules_actions.querylog_get(action_ctx()) end
function action_retention_save() return rules_actions.retention_save(action_ctx()) end
function action_logs() return logs_actions.logs(action_ctx()) end
function action_legacy_scan() return legacy_actions.legacy_scan(action_ctx()) end
function action_legacy_clean() return legacy_actions.legacy_clean(action_ctx()) end
