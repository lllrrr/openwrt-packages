-- AdGuard Home 管理中心 - legacy 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}

function M.legacy_scan(ctx)
    local http, sys, SHARE = ctx.http, ctx.sys, ctx.SHARE
    local out = sys.exec("sh " .. SHARE .. "/legacy_cleanup.sh scan 2>/dev/null") or ""
    out = out:match("({.*})") or ""

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    if out == "" then
        http.write('{"ok":false,"error":"扫描失败，请查看系统日志"}')
        return
    end
    http.write(out)
end

function M.legacy_clean(ctx)
    local http, sys, SHARE, require_post = ctx.http, ctx.sys, ctx.SHARE, ctx.require_post
    if not require_post() then
        return
    end

    local out = sys.exec("sh " .. SHARE .. "/legacy_cleanup.sh clean 2>/dev/null") or ""
    out = out:match("({.*})") or ""

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    if out == "" then
        http.write('{"ok":false,"error":"清理失败，请查看系统日志"}')
        return
    end
    http.write(out)
end

return M
