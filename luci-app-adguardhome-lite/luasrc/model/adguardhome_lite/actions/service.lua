-- AdGuard Home 管理中心 - service 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}
local tasks = require "luci.model.adguardhome_lite.tasks"

function M.service(ctx)
    local fs, http, uci, CONF = ctx.fs, ctx.http, ctx.uci, ctx.CONF
    local RUN, update_running, action_running, start_action = ctx.RUN, ctx.update_running, ctx.action_running, ctx.start_action
    local require_post, json_error = ctx.require_post, ctx.json_error
    if not require_post() then
        return
    end

    if update_running() then
        json_error("内核正在安装或更新，请稍候再操作服务。", 409, "update_busy")
        return
    end
    if tasks.plugin_running(fs, RUN) then
        json_error("插件正在更新，请稍候再操作服务。", 409, "plugin_update_busy")
        return
    end
    -- 服务操作会改写 UCI 并重启进程，必须与其它动作串行
    if action_running() then
        json_error("正在执行其他操作，请等待完成后再试。", 409, "action_busy")
        return
    end

    local act = http.formvalue("action") or ""
    local allowed = {
        start = true, stop = true, restart = true,
        enable = true, disable = true, bootstrap = true
    }
    if not allowed[act] then
        json_error("不支持的操作。", nil, "rule_action_failed")
        return
    end

    if act == "enable" or act == "bootstrap" or act == "start" then
        uci:set(CONF, "main", "enabled", "1")
        uci:commit(CONF)
        if not start_action("apply") then
            json_error("启动任务失败，请稍后重试。", 409, "action_busy")
            return
        end
    elseif act == "disable" or act == "stop" then
        uci:set(CONF, "main", "enabled", "0")
        uci:commit(CONF)
        if not start_action("apply") then
            json_error("停止任务失败，请稍后重试。", 409, "action_busy")
            return
        end
    elseif act == "restart" then
        if not start_action("restart") then
            json_error("重启任务失败，请稍后重试。", 409, "action_busy")
            return
        end
    end

    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

function M.password(ctx)
    local fs, http, sys, RUN = ctx.fs, ctx.http, ctx.sys, ctx.RUN
    local cfg, update_running, action_running, start_action = ctx.cfg, ctx.update_running, ctx.action_running, ctx.start_action
    local require_post, json_error = ctx.require_post, ctx.json_error
    if not require_post() then
        return
    end

    if update_running() then
        json_error("内核正在安装或更新，请稍候再修改密码。", 409, "update_busy")
        return
    end
    if tasks.plugin_running(fs, RUN) then
        json_error("插件正在更新，请稍候再修改密码。", 409, "plugin_update_busy")
        return
    end
    -- 改密码会重写 YAML 并重启服务，与其它动作必须串行
    if action_running() then
        json_error("正在执行其他操作，请等待完成后再修改密码。", 409, "action_busy")
        return
    end

    local hash = http.formvalue("hash") or ""
    local password = http.formvalue("password") or ""

    if #password < 8 then
        json_error("新密码至少需要 8 个字符。", nil, "invalid_password")
        return
    end
    if password:match("%c") then
        json_error("新密码不能包含换行等控制字符。", nil, "invalid_password")
        return
    end
    if #hash < 50 or not hash:match("^%$2[aby]%$%d%d%$[%w%./]+$") then
        json_error("密码哈希格式不正确，请刷新页面后重试。", nil, "password_hash_invalid")
        return
    end
    if not fs.access(cfg("config", "/etc/AdGuardHome.yaml")) then
        json_error("配置文件尚未生成，请先启用服务。", nil, "service_not_enabled")
        return
    end

    local hashfile = RUN .. "_new_hash"
    local passfile = RUN .. "_new_pass"
    fs.writefile(hashfile, hash)
    fs.writefile(passfile, password)
    sys.call("chmod 600 " .. hashfile .. " " .. passfile .. " >/dev/null 2>&1")

    if not start_action("set_password") then
        fs.remove(hashfile)
        fs.remove(passfile)
        json_error("改密任务启动失败，请稍后重试。", 409, "action_busy")
        return
    end

    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

function M.selftest(ctx)
    local http, selftest, cfg, yaml_section_scalar = ctx.http, ctx.selftest, ctx.cfg, ctx.yaml_section_scalar
    local core_version, service_running = ctx.core_version, ctx.service_running
    local binpath = cfg("binpath", "/usr/bin/AdGuardHome/AdGuardHome")
    local configpath = cfg("config", "/etc/AdGuardHome.yaml")
    local mode = cfg("dns_mode", "takeover")
    local webport = tonumber(cfg("webport", "13800")) or 13800

    -- 优先使用配置文件中实际写入的端口，避免「设置已改但尚未应用」时误报
    local dnsport = 5333
    if mode == "takeover" or mode == "passwall" or mode == "openclash" then
        dnsport = 53
    elseif mode == "clashfirst" then
        dnsport = 5335
    end
    local yaml_port_raw = (yaml_section_scalar(configpath, "dns", "port") or ""):gsub('"', "")
    local yaml_port = tonumber(yaml_port_raw)
    if yaml_port and yaml_port > 0 then
        dnsport = yaml_port
    end

    local result = selftest.run({
        binpath = binpath,
        configpath = configpath,
        webport = webport,
        dnsport = dnsport,
        running = service_running(binpath),
        version = core_version(binpath),
        mode = mode,
        mode_applied = cfg("mode_applied", "none")
    })

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json(result)
end

return M
