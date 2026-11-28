-- DNS 自检：只读检查内核、进程、管理端口与本机 DNS 查询链路
-- 通过 ctx 注入依赖，便于在设备外做单元测试。

local fs = require "nixio.fs"
local sys = require "luci.sys"

local M = {}

function M.run(ctx)
    ctx = ctx or {}
    local checks = {}

    -- level: ok 正常 / warn 提示（不影响整体结论）/ fail 异常
    local function add(id, label, level, detail)
        checks[#checks + 1] = {
            id = id,
            label = label,
            ok = level == "ok",
            level = level,
            detail = detail or ""
        }
    end

    local installed = fs.access(ctx.binpath, "x") and true or false
    add("core", "内核文件", installed and "ok" or "fail",
        installed and ((ctx.version and ctx.version ~= "") and ctx.version or ctx.binpath) or "未安装内核")
    add("config", "配置文件", fs.access(ctx.configpath) and "ok" or "fail", ctx.configpath)

    local running = ctx.running and true or false
    add("running", "服务进程", running and "ok" or "fail", running and "运行中" or "未运行")

    local webcode = ""
    if running then
        webcode = sys.exec(string.format(
            "curl -s -m 3 -o /dev/null -w '%%{http_code}' %q 2>/dev/null",
            string.format("http://127.0.0.1:%d/", ctx.webport))) or ""
    end
    add("web", "管理面板端口", (webcode ~= "" and webcode ~= "000") and "ok" or "fail",
        string.format("端口 %d：HTTP %s", ctx.webport, webcode ~= "" and webcode or "无响应"))

    -- level 与 detail 一起返回：端口有服务应答只是「查询被改道」的提示，
    -- 端口无人监听才是真故障（本机查询会直接失败），两者不能同等对待。
    local dns_level, dns_detail = "warn", "未执行（服务未运行）"
    if running then
        -- PassWall/Clash 的 nat_output 规则会把本机发往 127.0.0.1:53 的查询
        -- 重定向到自己的端口。此时探测的不是 AGH，不能据此判定 DNS 故障。
        local hijack = sys.exec(string.format(
            "nft list ruleset 2>/dev/null | grep -E 'oif \"lo\".*dport %d .*redirect to :[0-9]+' | head -n 1 | sed -n 's/.*redirect to :\\([0-9][0-9]*\\).*/\\1/p'",
            ctx.dnsport)) or ""
        hijack = hijack:gsub("%s+", "")
        if hijack ~= "" then
            local hport_ok = (sys.exec(string.format(
                "netstat -lntu 2>/dev/null | grep -qE '[:.]%s[[:space:]]' && echo 1", hijack)) or ""):find("1") ~= nil
            -- 端口有服务：查询被交给代理分流，属预期行为，仅提示；
            -- 端口无人监听：查询会直接失败，判定异常。
            dns_level = hport_ok and "warn" or "fail"
            dns_detail = string.format(
                "本机查询被 PassWall/Clash 劫持到 :%s（%s），未经过 AdGuard Home 端口 %d",
                hijack, hport_ok and "该端口有服务应答，查询已交由代理处理" or "该端口无人监听，本机查询会失败", ctx.dnsport)
        else
            local out = sys.exec(string.format(
                "nslookup -timeout=2 -retry=1 -port=%d example.com 127.0.0.1 2>&1", ctx.dnsport)) or ""
            local dns_ok = out ~= "" and not out:find("can't resolve") and not out:find("timed out")
            dns_level = dns_ok and "ok" or "fail"
            local snippet = out:gsub("%s+", " ")
            if #snippet > 160 then
                snippet = snippet:sub(1, 160) .. "..."
            end
            dns_detail = string.format("端口 %d：%s", ctx.dnsport, snippet ~= "" and snippet or "无输出")
        end
    end
    add("dns", "DNS 查询", dns_level, dns_detail)

    -- 接管方式一致性只作提示，不影响整体结论
    add("mode", "DNS 接管状态", ctx.mode == ctx.mode_applied and "ok" or "warn",
        string.format("配置：%s，已应用：%s", ctx.mode, ctx.mode_applied))

    local all_ok = true
    for _, check in ipairs(checks) do
        if check.level == "fail" then
            all_ok = false
        end
    end

    return {
        ok = all_ok,
        dns_port = ctx.dnsport,
        checks = checks
    }
end

return M
