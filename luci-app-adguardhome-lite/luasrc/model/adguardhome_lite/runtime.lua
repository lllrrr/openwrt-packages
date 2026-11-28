-- AdGuard Home 管理中心：运行时能力（任务锁、后台动作、HTTP 助手、AGH 客户端）
-- 控制器只保留菜单注册与分发，这里集中放动作层需要注入的一切。

local fs = require "nixio.fs"
local http = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local util = require "luci.model.adguardhome_lite.util"
local codes = require "luci.model.adguardhome_lite.codes"
local agh = require "luci.model.adguardhome_lite.agh"
local selftest = require "luci.model.adguardhome_lite.selftest"
local yaml = require "luci.model.adguardhome_lite.yaml"
local tasks = require "luci.model.adguardhome_lite.tasks"
local env = require "luci.model.adguardhome_lite.env"
local versions = require "luci.model.adguardhome_lite.versions"
local proxy = require "luci.model.adguardhome_lite.proxy"

local M = {}

local TTL = env.TTL

-- 后台动作只接受白名单名称，避免命令拼接成为注入面
local ACTIONS = {
    apply = "sh " .. env.SHARE .. "/apply_settings.sh",
    restart = "/etc/init.d/adguardhome_lite restart",
    set_password = "sh " .. env.SHARE .. "/set_password.sh",
}

local ACTION_NAME = env.RUN .. "_action.name"

function M.update_running()
    return tasks.update_running(fs, env.RUN, sys, TTL.update_grace)
end

function M.action_files(name)
    return tasks.action_files(env.RUN, name)
end

function M.action_running()
    return tasks.action_running(fs, env.RUN, sys, ACTIONS, {
        grace = TTL.action_grace,
        max_age = TTL.action_max_age,
    })
end

-- 所有写操作入口统一用这个判定，避免各处检查顺序不一致
function M.busy_reason()
    return tasks.busy(fs, env.RUN, sys, ACTIONS, {
        update_grace = TTL.update_grace,
        plugin_max_age = TTL.plugin_max_age,
        grace = TTL.action_grace,
        max_age = TTL.action_max_age,
    })
end

function M.start_action(name)
    local cmd = ACTIONS[name]
    if not cmd then
        return false
    end
    -- 同一时间只允许一个动作，避免 apply 与 restart 交叉改写服务与配置
    if M.action_running() then
        return false
    end

    local logfile, codefile, pidfile, running = M.action_files(name)
    local mirror_log = env.RUN .. "_action.log"
    local mirror_code = env.RUN .. "_action.code"

    fs.writefile(ACTION_NAME, name)
    fs.writefile(codefile, "")
    fs.writefile(running, "1")
    fs.remove(pidfile)
    -- 通用日志与返回码只作最近一次动作的镜像，保持原有读取方无需改动
    fs.writefile(mirror_code, "")

    -- $! 是后台子 shell 的 pid；动作结束时写返回码、同步镜像并清理标记
    sys.exec(string.format(
        "( ( %s ); rc=$?; echo $rc > %q; cp -f %q %q 2>/dev/null; cp -f %q %q 2>/dev/null; rm -f %q %q ) >%q 2>&1 & echo $! > %q",
        cmd, codefile, logfile, mirror_log, codefile, mirror_code, running, pidfile, logfile, pidfile))
    return true
end

function M.check_token()
    local token = http.formvalue("token")
    if not token then
        return false
    end

    -- 与 LuCI 分发器使用同一个会话令牌。延迟 require，避免菜单扫描阶段初始化上下文失败。
    local ctx = rawget(_G, "context")
    local expected = ctx and ctx.authtoken
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

function M.require_post()
    if not M.check_token() then
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

function M.default_reason(status)
    if status == 403 then
        return "permission_denied"
    elseif status == 409 then
        return "update_busy"
    elseif status >= 500 then
        return "request_failed"
    end
    return "invalid_param"
end

function M.json_error(msg, code, reason)
    local status = code or 400
    reason = reason or M.default_reason(status)
    http.status(status)
    http.prepare_content("application/json")
    http.write_json({
        ok = false,
        error = msg,
        reason = reason,
        level = codes.level(reason)
    })
end

-- 本机 AdGuard Home 接口：凭据与请求细节在 model/agh.lua 中统一处理
function M.agh_client()
    agh.configure({
        user = env.cfg("adminuser", "admin"),
        -- 兜底与模板内置哈希（admin123）对应，仅在老配置缺字段时命中；
        -- 界面会提示"仍是默认密码"，用户改密后即被 UCI 明文覆盖。
        pass = env.cfg("adminpass", "admin123"),
        port = tonumber(env.cfg("webport", "13800")) or 13800
    })
    return agh
end

function M.agh_request(path, method, body, timeout)
    return M.agh_client().request(path, method, body, timeout)
end

-- 从 AdGuard Home 本地接口读取过滤统计，插件页面无需打开 AGH 面板。
-- 结果缓存 8 秒：页面 10 秒轮询时每次都能拿到新数据，又不会重复请求。
function M.collect_stats()
    local cached = env.read_cache(env.STATS_CACHE, TTL.stats)
    if cached then
        local ok, jsonc = pcall(require, "luci.jsonc")
        if ok then
            local parsed = jsonc.parse(cached)
            if type(parsed) == "table" then
                return parsed
            end
        end
    end

    local _, raw = M.agh_request("/control/stats", "GET")

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
    local yaml_text = fs.readfile(env.cfg("config", "/etc/AdGuardHome.yaml")) or ""

    local data = {
        ok = true,
        queries = stats.num_dns_queries or 0,
        blocked = stats.num_blocked_filtering or 0,
        malware = stats.num_replaced_safebrowsing or 0,
        adult = stats.num_replaced_parental or 0,
        safesearch = stats.num_replaced_safesearch or 0,
        avg = stats.avg_processing_time or 0,
        protection = yaml.scalar_text(yaml_text, "filtering", "protection_enabled") == "true",
        safebrowsing = yaml.scalar_text(yaml_text, "filtering", "safebrowsing_enabled") == "true",
        parental = yaml.scalar_text(yaml_text, "filtering", "parental_enabled") == "true",
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
        fs.writefile(env.STATS_CACHE, encoded)
    end

    return data
end

-- 动作层需要的全部依赖。每轮请求只组装一次，避免各 action 重复 require。
function M.build_ctx()
    return {
        fs = fs,
        http = http,
        sys = sys,
        uci = uci,
        util = util,
        agh = agh,
        selftest = selftest,
        split_words = util.split_words,
        join_words = util.join_words,
        valid_iface_name = util.valid_iface_name,
        valid_client_spec = util.valid_client_spec,
        version_newer = util.version_newer,
        CONF = env.CONF,
        SHARE = env.SHARE,
        RUN = env.RUN,
        STATS_CACHE = env.STATS_CACHE,
        CORE_UPDATE = env.CORE_UPDATE,
        PLUGIN_UPDATE = env.PLUGIN_UPDATE,
        collect_stats = M.collect_stats,
        cfg = env.cfg,
        yaml_list_values = yaml.list,
        yaml_safe_search_enabled = yaml.safe_search_enabled,
        yaml_section_scalar = yaml.scalar,
        yaml_set_section_scalar = yaml.set_section_scalar,
        cache_option = env.cache_option,
        net_devices = env.net_devices,
        is_enabled = env.is_enabled,
        core_version = versions.core_version,
        core_update_info = versions.core_update_info,
        plugin_version = versions.plugin_version,
        plugin_update_info = versions.plugin_update_info,
        service_running = env.service_running,
        openclash_hijack_port = proxy.openclash_hijack_port,
        openclash_running = proxy.openclash_running,
        openclash_upstream_agh = proxy.openclash_upstream_agh,
        passwall_enabled = proxy.passwall_enabled,
        passwall_dns_port = proxy.passwall_dns_port,
        read_number = env.read_number,
        update_running = M.update_running,
        action_running = M.action_running,
        busy_reason = M.busy_reason,
        start_action = M.start_action,
        require_post = M.require_post,
        json_error = M.json_error,
        state_value = env.state_value,
        agh_client = M.agh_client,
        agh_request = M.agh_request,
        agh_api = M.agh_request,
        interval_days = env.interval_days,
    }
end

return M
