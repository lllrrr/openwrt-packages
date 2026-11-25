-- AdGuard Home 管理中心 - session 动作
-- 供手机 App 在完成 LuCI 登录后一次性取得会话令牌，避免解析页面 HTML。

local M = {}

-- 令牌由 luci-compat 代理到 _G.L.ctx，控制器里没有同名全局变量。
-- 这里延迟 require，避免菜单扫描阶段初始化上下文失败。
local function current_authtoken()
    local ok, disp = pcall(require, "luci.dispatcher")
    if ok and disp and disp.context then
        return disp.context.authtoken or ""
    end
    return ""
end

function M.session(ctx)
    local http, json_error = ctx.http, ctx.json_error
    local token = current_authtoken()

    if token == "" then
        json_error("登录状态无效，请重新登录路由器。", 401, "auth_required")
        return
    end

    http.prepare_content("application/json")
    http.write_json({
        ok = true,
        token = token
    })
end

return M
