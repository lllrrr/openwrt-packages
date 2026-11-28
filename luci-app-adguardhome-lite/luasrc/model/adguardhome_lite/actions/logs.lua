-- AdGuard Home 管理中心 - logs 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}

function M.logs(ctx)
    local fs, http, sys, RUN = ctx.fs, ctx.http, ctx.sys, ctx.RUN
    local state_value = ctx.state_value
    local level = (http.formvalue("level") or ""):lower()
    local syslog = sys.exec("logread 2>/dev/null | grep -i 'adguard' | tail -n 300") or ""
    local update = fs.readfile(RUN .. "_update.log") or ""
    local action = fs.readfile(RUN .. "_action.log") or ""
    local filter = fs.readfile(RUN .. "_filter.log") or ""

    -- 每个动作单独落盘，通用 _action.log 只保留最近一次，这里把各自的历史也读出来
    local action_name = (fs.readfile(RUN .. "_action.name") or ""):gsub("%s+", "")
    local per_action = {}
    for _, name in ipairs({ "apply", "restart", "set_password" }) do
        local base = RUN .. "_action_" .. name
        local body = fs.readfile(base .. ".log")
        if body then
            local code = (fs.readfile(base .. ".code") or ""):gsub("%s+", "")
            local mtime = fs.stat(base .. ".log", "mtime")
            per_action[#per_action + 1] = {
                name = name,
                body = body,
                code = code ~= "" and code or "-",
                time = mtime and os.date("%Y-%m-%d %H:%M:%S", mtime) or "-"
            }
        end
    end
    table.sort(per_action, function(a, b) return a.time > b.time end)

    if level == "error" or level == "warn" or level == "info" then
        local tag = "[" .. level:upper() .. "]"
        local filtered = {}
        for line in (syslog .. "\n"):gmatch("([^\n]*)\n") do
            if line:find(tag, 1, true) then
                filtered[#filtered + 1] = line
            end
        end
        syslog = table.concat(filtered, "\n")
        if syslog ~= "" then
            syslog = syslog .. "\n"
        end
    end

    http.header("Cache-Control", "no-store")
    http.prepare_content("text/plain; charset=utf-8")
    http.write("===== 持久化状态（重启后保留） =====\n")
    http.write("上次应用：" .. (state_value("last_apply") ~= "" and state_value("last_apply") or "无记录") .. "\n")
    http.write("上次更新：" .. (state_value("last_update") ~= "" and state_value("last_update") or "无记录") .. "\n")
    http.write("上次 DNS 回退：" .. (state_value("last_fallback") ~= "" and state_value("last_fallback") or "无记录") .. "\n")
    http.write("\n===== 系统日志（包含 AdGuard 关键字，最近 300 行"
        .. (level ~= "" and ("，筛选 " .. level:upper()) or "") .. "） =====\n")
    http.write(syslog)
    http.write("\n\n===== 内核安装/更新日志 =====\n")
    http.write(update)
    http.write("\n\n===== 最近一次服务操作日志 =====\n")
    http.write(action)
    http.write("\n\n===== 各动作最近一次日志（当前动作：" .. (action_name ~= "" and action_name or "无") .. "） =====\n")
    if #per_action == 0 then
        http.write("暂无记录\n")
    end
    for _, item in ipairs(per_action) do
        http.write(string.format("--- %s | 返回码 %s | %s ---\n", item.name, item.code, item.time))
        http.write(item.body)
        if item.body ~= "" and item.body:sub(-1) ~= "\n" then
            http.write("\n")
        end
    end
    http.write("\n\n===== 订阅更新日志（最近 100 次） =====\n")
    http.write(filter)
end

return M
