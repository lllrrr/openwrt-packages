-- AdGuard Home 管理中心 - plugin 动作
-- 负责插件在线更新：后台执行 plugin_update.sh，前端轮询进度。

local M = {}
local tasks = require "luci.model.adguardhome_lite.tasks"

function M.plugin_update(ctx)
    local fs, http, sys = ctx.fs, ctx.http, ctx.sys
    local RUN, SHARE = ctx.RUN, ctx.SHARE
    local require_post, json_error = ctx.require_post, ctx.json_error

    if not require_post() then
        return
    end

    if ctx.update_running() or tasks.plugin_running(fs, RUN) or ctx.action_running() then
        json_error("已有安装或更新任务在运行，请稍后再试。", 409, "plugin_update_busy")
        return
    end

    local version = (http.formvalue("version") or ""):gsub("%s+", "")
    if not version:match("^%d+%.%d+%.%d+[%w%.%-]*$") then
        json_error("目标版本无效。", nil, "plugin_update_invalid")
        return
    end

    local current = ctx.plugin_version()
    local force = http.formvalue("force") == "1"

    if not force then
        if current ~= "" and not ctx.version_newer(version, current) then
            json_error("目标版本不高于当前版本。", nil, "plugin_update_invalid")
            return
        end

        -- 只允许更新到检查结果中的最新版，避免任意版本或降级
        local info = ctx.plugin_update_info()
        if not info or info.latest ~= version then
            json_error("目标版本已变化，请刷新页面后重试。", nil, "plugin_update_invalid")
            return
        end
    end

    local channel = http.formvalue("channel") or "cn"
    if channel ~= "cn" and channel ~= "github" then
        channel = "cn"
    end
    local method = http.formvalue("method") or "source"
    if method ~= "source" and method ~= "package" then
        method = "source"
    end

    local log = RUN .. "_plugin_update.log"
    fs.writefile(log, string.format(
        "目标版本：v%s\n更新渠道：%s\n更新方式：%s\n强制更新：%s\n",
        version,
        channel == "cn" and "国内加速" or "GitHub 直连",
        method == "source" and "通用模式" or "安装包模式",
        force and "是" or "否"))

    fs.remove(RUN .. "_plugin_update.code")

    -- 脚本会把自己复制到 /tmp 再执行，避免更新过程中覆盖自身
    sys.exec(string.format("sh %q %q %q %q %q >>%q 2>&1 &",
        SHARE .. "/plugin_update.sh", version, channel, method,
        force and "1" or "0", log))

    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

function M.plugin_progress(ctx)
    local fs, http = ctx.fs, ctx.http
    local RUN = ctx.RUN

    local log = fs.readfile(RUN .. "_plugin_update.log") or ""
    if #log > 24000 then
        log = string.sub(log, -24000)
    end

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json({
        running = tasks.plugin_running(fs, RUN),
        log = log,
        code = ctx.read_number(RUN .. "_plugin_update.code")
    })
end

-- 手动检测插件更新：清除 24 小时缓存并立即触发一次后台检查
function M.plugin_check(ctx)
    local fs, http = ctx.fs, ctx.http
    local require_post = ctx.require_post

    if not require_post() then
        return
    end

    fs.remove(ctx.PLUGIN_UPDATE)
    local info = ctx.plugin_update_info()

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json({
        ok = true,
        checking = true,
        current = info.current or "",
        latest = info.latest or "",
        update = info.update and true or false
    })
end

return M
