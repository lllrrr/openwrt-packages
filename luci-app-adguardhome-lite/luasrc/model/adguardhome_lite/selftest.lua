-- DNS 自检：只读检查内核、进程、管理端口与本机 DNS 查询链路
-- 通过 ctx 注入依赖，便于在设备外做单元测试。

local fs = require "nixio.fs"
local sys = require "luci.sys"

local M = {}

function M.run(ctx)
    ctx = ctx or {}
    local checks = {}

    local function add(id, label, ok, detail)
        checks[#checks + 1] = {
            id = id,
            label = label,
            ok = ok and true or false,
            detail = detail or ""
        }
    end

    local installed = fs.access(ctx.binpath, "x") and true or false
    add("core", "内核文件", installed,
        installed and ((ctx.version and ctx.version ~= "") and ctx.version or ctx.binpath) or "未安装内核")
    add("config", "配置文件", fs.access(ctx.configpath) and true or false, ctx.configpath)

    local running = ctx.running and true or false
    add("running", "服务进程", running, running and "运行中" or "未运行")

    local webcode = ""
    if running then
        webcode = sys.exec(string.format(
            "curl -s -m 3 -o /dev/null -w '%%{http_code}' %q 2>/dev/null",
            string.format("http://127.0.0.1:%d/", ctx.webport))) or ""
    end
    add("web", "管理面板端口", webcode ~= "" and webcode ~= "000",
        string.format("端口 %d：HTTP %s", ctx.webport, webcode ~= "" and webcode or "无响应"))

    local dns_ok, dns_detail = false, "未执行（服务未运行）"
    if running then
        local out = sys.exec(string.format(
            "nslookup -timeout=2 -retry=1 -port=%d example.com 127.0.0.1 2>&1", ctx.dnsport)) or ""
        dns_ok = out ~= "" and not out:find("can't resolve") and not out:find("timed out")
        local snippet = out:gsub("%s+", " ")
        if #snippet > 160 then
            snippet = snippet:sub(1, 160) .. "..."
        end
        dns_detail = string.format("端口 %d：%s", ctx.dnsport, snippet ~= "" and snippet or "无输出")
    end
    add("dns", "DNS 查询", dns_ok, dns_detail)

    -- 接管方式一致性只作提示，不影响整体结论
    add("mode", "DNS 接管状态", ctx.mode == ctx.mode_applied,
        string.format("配置：%s，已应用：%s", ctx.mode, ctx.mode_applied))

    local all_ok = true
    for _, check in ipairs(checks) do
        if check.id ~= "mode" and not check.ok then
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
