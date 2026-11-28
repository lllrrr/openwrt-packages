-- AdGuard Home 管理中心 - core 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}
local tasks = require "luci.model.adguardhome_lite.tasks"

function M.core_install(ctx)
    local fs, http, sys, SHARE = ctx.fs, ctx.http, ctx.sys, ctx.SHARE
    local RUN, cfg, core_update_info, update_running = ctx.RUN, ctx.cfg, ctx.core_update_info, ctx.update_running
    local action_running, require_post, json_error = ctx.action_running, ctx.require_post, ctx.json_error
    if not require_post() then
        return
    end

    if update_running() then
        json_error("内核正在安装或更新，请等待当前任务完成。", 409, "update_busy")
        return
    end
    if tasks.plugin_running(fs, RUN) then
        json_error("插件正在更新，请等待当前任务完成。", 409, "plugin_update_busy")
        return
    end
    -- 安装内核会替换正在运行的内核文件，必须等配置动作结束后再开始
    if action_running() then
        json_error("正在执行其他操作，请等待完成后再安装内核。", 409, "action_busy")
        return
    end

    -- 把页面已确认的通道与版本传给安装脚本，保证提示的版本就是实际安装的版本
    local channel = cfg("channel", "stable")
    if channel ~= "beta" and channel ~= "legacy" then
        channel = "stable"
    end
    local info = core_update_info(cfg("binpath", "/usr/bin/AdGuardHome/AdGuardHome"), channel)
    if channel == "legacy" and info.latest == "" then
        json_error("旧版本通道暂无可用目标版本，请等待版本检查完成后重试。", 409, "invalid_param")
        return
    end
    local cmd = "sh " .. SHARE .. "/update_core.sh"
    if info.latest ~= "" then
        cmd = cmd .. " " .. string.format("%q", channel) .. " " .. string.format("%q", info.latest)
    end

    fs.writefile(RUN .. "_update.log", "正在启动内核安装任务...\n")
    fs.remove(RUN .. "_update.code")
    sys.exec(cmd .. " >" .. RUN .. "_update.log 2>&1 &")

    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

function M.core_progress(ctx)
    local fs, http, RUN, read_number = ctx.fs, ctx.http, ctx.RUN, ctx.read_number
    local update_running = ctx.update_running
    local log = fs.readfile(RUN .. "_update.log") or ""
    if #log > 24000 then
        log = string.sub(log, -24000)
    end

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json({
        running = update_running(),
        log = log,
        code = read_number(RUN .. "_update.code")
    })
end

return M
