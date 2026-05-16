--[[
  qmodem_failover.lua - LuCI 路由控制器
  位置: /usr/lib/lua/luci/controller/qmodem_failover.lua
  功能: 注册 Web 路由、提供状态查询 API、手动切换 API
--]]

module("luci.controller.qmodem_failover", package.seeall)

local sys    = require "luci.sys"
local http   = require "luci.http"
local json   = require "luci.jsonc"

-- ─────────────────────────────────────────────
-- 注册菜单和路由
-- ─────────────────────────────────────────────
function index()
    -- 检查配置文件是否存在
    if not nixio.fs.access("/etc/config/qmodem_failover") then
        return
    end

    -- 主配置页面（在"网络"菜单下）
    local page = entry(
        {"admin", "network", "qmodem_failover"},
        cbi("qmodem_failover"),
        _("QMODEM 故障切换"),
        60
    )
    page.dependent = true

    -- 状态页面（实时监控）
    entry(
        {"admin", "network", "qmodem_failover_status"},
        template("qmodem_failover/status"),
        _("切换状态"),
        61
    )

    -- ── REST API ──
    -- GET  /admin/network/qmodem_failover/api/status  → 获取当前状态 JSON
    entry({"admin", "network", "qmodem_failover", "api", "status"},
        call("api_status")).leaf = true

    -- POST /admin/network/qmodem_failover/api/switch  → 手动切换
    entry({"admin", "network", "qmodem_failover", "api", "switch"},
        call("api_switch")).leaf = true

    -- POST /admin/network/qmodem_failover/api/test    → 测试通知
    entry({"admin", "network", "qmodem_failover", "api", "test_notify"},
        call("api_test_notify")).leaf = true

    -- GET  /admin/network/qmodem_failover/api/logs    → 最近切换日志
    entry({"admin", "network", "qmodem_failover", "api", "logs"},
        call("api_logs")).leaf = true
end

-- ─────────────────────────────────────────────
-- 读取状态文件
-- ─────────────────────────────────────────────
local function read_status()
    local status_file = "/var/run/qmodem-failover/status"
    local mode, ts, extra = "unknown", 0, ""
    local f = io.open(status_file, "r")
    if f then
        local line = f:read("*l") or ""
        f:close()
        mode, ts, extra = line:match("^(%a+):(%d+):?(.*)$")
        ts = tonumber(ts) or 0
    end
    return mode or "unknown", ts, extra or ""
end

-- ─────────────────────────────────────────────
-- 检测 WAN 是否存活（简单 Ping）
-- ─────────────────────────────────────────────
local function wan_alive(wan_iface)
    local hosts = {"223.5.5.5", "8.8.8.8", "114.114.114.114"}
    for _, host in ipairs(hosts) do
        local cmd = string.format(
            "ping -c 1 -W 2 -I %s %s >/dev/null 2>&1",
            wan_iface, host
        )
        if sys.call(cmd) == 0 then
            return true
        end
    end
    return false
end

-- ─────────────────────────────────────────────
-- API: 获取状态
-- ─────────────────────────────────────────────
function api_status()
    http.prepare_content("application/json")

    local uci      = require "luci.model.uci".cursor()
    local wan_iface = uci:get("qmodem_failover", "general", "wan_iface") or "eth0"
    local lte_iface = uci:get("qmodem_failover", "general", "lte_iface") or "usb0"

    local mode, ts, _ = read_status()

    -- 接口 IP
    local wan_ip = sys.exec(
        string.format("ip addr show %s 2>/dev/null | awk '/inet / {print $2; exit}'", wan_iface)
    ):gsub("%s+", "")

    local lte_ip = sys.exec(
        string.format("ip addr show %s 2>/dev/null | awk '/inet / {print $2; exit}'", lte_iface)
    ):gsub("%s+", "")

    -- 默认路由
    local default_route = sys.exec("ip route show | grep '^default'"):gsub("%s+$", "")

    -- WAN 物理链路状态
    local wan_carrier = sys.exec(
        string.format("cat /sys/class/net/%s/carrier 2>/dev/null || echo 0", wan_iface)
    ):gsub("%s+", "")

    -- 服务进程状态
    local pid_file = "/var/run/qmodem-failover/checker.pid"
    local pid_f = io.open(pid_file, "r")
    local service_running = false
    if pid_f then
        local pid = pid_f:read("*l")
        pid_f:close()
        if pid and sys.call(string.format("kill -0 %s 2>/dev/null", pid)) == 0 then
            service_running = true
        end
    end

    local result = {
        mode          = mode,
        switch_time   = ts,
        wan_alive     = wan_alive(wan_iface),
        wan_carrier   = (wan_carrier == "1"),
        wan_ip        = wan_ip,
        lte_ip        = lte_ip,
        wan_iface     = wan_iface,
        lte_iface     = lte_iface,
        default_route = default_route,
        service_running = service_running,
        server_time   = os.time()
    }

    http.write(json.stringify(result))
end

-- ─────────────────────────────────────────────
-- API: 手动切换
-- ─────────────────────────────────────────────
function api_switch()
    http.prepare_content("application/json")

    -- 只允许 POST
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        http.status(405, "Method Not Allowed")
        http.write(json.stringify({ success = false, error = "只支持 POST 请求" }))
        return
    end

    local target = http.formvalue("target") or "lte"
    if target ~= "lte" and target ~= "wan" then
        http.write(json.stringify({ success = false, error = "target 参数无效，必须是 lte 或 wan" }))
        return
    end

    local cmd = string.format(
        "/usr/lib/qmodem-failover/switcher.sh switch_to_%s",
        target
    )
    local ret = sys.call(cmd)

    local mode, ts, _ = read_status()
    http.write(json.stringify({
        success = (ret == 0),
        target  = target,
        mode    = mode,
        switch_time = ts,
        error   = (ret ~= 0) and "切换命令执行失败，请查看系统日志" or nil
    }))
end

-- ─────────────────────────────────────────────
-- API: 测试通知
-- ─────────────────────────────────────────────
function api_test_notify()
    http.prepare_content("application/json")
    local ret = sys.call(
        "/usr/lib/qmodem-failover/notify.sh test '这是一条测试通知，QMODEM故障切换插件工作正常'"
    )
    http.write(json.stringify({ success = (ret == 0) }))
end

-- ─────────────────────────────────────────────
-- API: 最近日志（最近 50 条与本插件相关的日志）
-- ─────────────────────────────────────────────
function api_logs()
    http.prepare_content("application/json")
    local logs = sys.exec("logread 2>/dev/null | grep qmodem-failover | tail -50")
    local lines = {}
    for line in logs:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    http.write(json.stringify({ logs = lines }))
end

