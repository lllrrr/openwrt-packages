#!/usr/bin/lua

local nixio = require "nixio"
local uci = require "luci.model.uci".cursor()
-- 引入 string 库防止部分环境未自动加载
local string = require "string"

-- 配置常量
local DEFAULT_DB_PATH = "/etc/httping_data.db"
local CURL_TIMEOUT = 5
local TCP_TIMEOUT_MS = 2000
local MIN_INTERVAL = 5
local MAX_INTERVAL = 86400
local DEFAULT_RETENTION_DAYS = 90
local CLEANUP_INTERVAL = 3600

-- 状态记录 (减少文件IO)
-- Key: section_name, Value: last_run_timestamp
local last_run_map = {}
local last_cleanup = 0

local function log_error(message)
    io.stderr:write("[httping] " .. tostring(message) .. "\n")
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function sql_quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function command_succeeded(result)
    return result == true or result == 0
end

local function sqlite_command(db_path, sql, json_output)
    local mode = json_output and " -json" or ""
    return "sqlite3 -batch" .. mode ..
        " -cmd " .. shell_quote(".timeout 5000") ..
        " " .. shell_quote(db_path) .. " " .. shell_quote(sql)
end

local function run_sql(db_path, sql)
    local result = os.execute(sqlite_command(db_path, sql, false) .. " >/dev/null")
    return command_succeeded(result)
end

local function query_sql(db_path, sql)
    local pipe = io.popen(sqlite_command(db_path, sql, false) .. " 2>/dev/null")
    if not pipe then return nil end

    local output = pipe:read("*a")
    local ok = pipe:close()
    if not command_succeeded(ok) then return nil end
    return output
end

-- 辅助函数：获取数据库路径
local function get_db_path()
    local db_path = uci:get("httping", "global", "db_path")
    if not db_path or db_path == "" then
        db_path = DEFAULT_DB_PATH
    end
    return db_path
end

-- 数据库初始化。每次路径变化时都执行幂等检查，以修复空文件或旧数据库。
local function init_db(db_path)
    local schema_sql = [[
        CREATE TABLE IF NOT EXISTS monitor_log (
            id INTEGER PRIMARY KEY,
            server_name TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            duration REAL,
            type TEXT DEFAULT 'httping'
        );
    ]]

    if not run_sql(db_path, schema_sql) then
        log_error("failed to initialize database: " .. db_path)
        return false
    end

    local columns = query_sql(db_path, "PRAGMA table_info(monitor_log);") or ""
    if not columns:match("|type|") then
        if not run_sql(db_path, "ALTER TABLE monitor_log ADD COLUMN type TEXT DEFAULT 'httping';") then
            log_error("failed to migrate database: " .. db_path)
            return false
        end
    end

    local index_sql = [[
        CREATE INDEX IF NOT EXISTS idx_ts ON monitor_log(timestamp);
        CREATE INDEX IF NOT EXISTS idx_name ON monitor_log(server_name);
        PRAGMA journal_mode=WAL;
    ]]
    if not run_sql(db_path, index_sql) then
        log_error("failed to create database indexes: " .. db_path)
        return false
    end

    return true
end

-- 写入日志
local function log_result(db_path, name, ts, duration, type_str)
    local val_duration = "NULL"
    if duration then
        val_duration = string.format("%.3f", duration)
    end

    local sql = string.format("INSERT INTO monitor_log (server_name, timestamp, duration, type) VALUES (%s, %d, %s, %s);",
        sql_quote(name), ts, val_duration, sql_quote(type_str))

    -- 使用 sqlite3 CLI 执行（避免额外的架构相关 Lua SQLite 模块）。
    if not run_sql(db_path, sql) then
        log_error("failed to write result for server: " .. name)
    end
end

-- TCPing 实现 (纯 Lua)
local function do_tcping(url)
    local host, port

    -- 解析 URL (简单处理 [IPv6]:port 和 host:port)
    if url:match("^%[") then
        host = url:match("^%[(.-)%]")
        port = url:match("]:(%d+)$")
    else
        host, port = url:match("^(.-):(%d+)$")
        if not host then
            host = url
        end
    end

    if not port then port = 80 end
    port = tonumber(port)

    if not host or not port or port < 1 or port > 65535 then return nil end

    -- 1. DNS 解析
    local addr_iter = nixio.getaddrinfo(host, "inet") -- 先试 IPv4
    if not addr_iter or #addr_iter == 0 then
        addr_iter = nixio.getaddrinfo(host, "inet6") -- 再试 IPv6
    end

    if not addr_iter or #addr_iter == 0 then
        return nil -- DNS Fail
    end

    local target = addr_iter[1]

    -- 2. 创建 Socket
    local sock = nixio.socket(target.family, "stream")
    if not sock then return nil end

    -- 设置非阻塞以便控制超时
    sock:setblocking(false)

    local t1_sec, t1_usec = nixio.gettimeofday()

    -- 3. 连接
    local stat, code, err = sock:connect(target.address, port)

    -- 处理 connect 结果
    -- 在非阻塞模式下，connect 通常返回 false 和 "inprogress"
    if not stat and code ~= nixio.const.EINPROGRESS then
        sock:close()
        return nil
    end

    -- 4. 使用 poll 等待连接完成（超时 2 秒）。
    local pstat
    if stat then
        pstat = 1
    else
        pstat = nixio.poll({{fd=sock, events=nixio.poll_flags("out")}}, TCP_TIMEOUT_MS)
    end

    local success = false
    if pstat and pstat > 0 then
        -- 检查 socket 错误状态
        local err_code = sock:getopt("socket", "error")
        if err_code == 0 then
            success = true
        end
    end

    local t2_sec, t2_usec = nixio.gettimeofday()
    sock:close()

    if success then
        local ms = (t2_sec - t1_sec) * 1000 + (t2_usec - t1_usec) / 1000
        return ms
    else
        return nil
    end
end

-- HTTPing 实现 (Curl wrapper)
local function do_httping(url)
    -- 使用 curl 的格式化输出功能
    -- %{time_namelookup}: DNS 解析时间
    -- %{time_total}: 总时间
    local cmd = string.format(
        "curl -L -k -s -o /dev/null -w %s --proto '=http,https' --proto-redir '=http,https' --max-time %d -- %s",
        shell_quote("%{time_namelookup} %{time_total}"), CURL_TIMEOUT, shell_quote(url))
    local f = io.popen(cmd)
    if not f then return nil end

    local output = f:read("*a")
    local ok = f:close()

    -- curl 即使失败也可能输出计时字段，必须先检查退出状态。
    if not command_succeeded(ok) then return nil end

    if not output or output == "" then return nil end

    local t_dns, t_total = output:match("([%d%.]+)%s+([%d%.]+)")
    if t_dns and t_total then
        -- 计算 TCP + Transfer 时间 (排除 DNS)
        -- 注意：这里保持和原来 Shell 脚本一样的逻辑 (Total - DNS)
        local duration = (tonumber(t_total) - tonumber(t_dns)) * 1000
        if duration < 0 then duration = 0 end
        return duration
    end

    return nil
end

-- 处理单个 Server 配置
local function check_server(db_path, section_name, config)
    local enabled = config.enabled or "0"
    if enabled ~= "1" then return end

    local url = config.url
    if not url or url == "" then return end

    local interval = tonumber(config.interval) or 60
    interval = math.max(MIN_INTERVAL, math.min(MAX_INTERVAL, interval))
    local check_type = config.type or "httping"
    if check_type ~= "tcping" then check_type = "httping" end
    local name = config.name or section_name

    local now = os.time()
    local last = last_run_map[section_name] or 0

    if (now - last) >= interval then
        -- 更新运行时间
        last_run_map[section_name] = now

        -- 执行检测
        local duration = nil
        if check_type == "tcping" then
            duration = do_tcping(url)
        else
            duration = do_httping(url)
        end

        -- 记录结果
        log_result(db_path, name, now, duration, check_type)
    end
end

local function cleanup_old_data(db_path, now)
    if (now - last_cleanup) < CLEANUP_INTERVAL then return end
    last_cleanup = now

    local retention_days = tonumber(uci:get("httping", "global", "retention_days")) or DEFAULT_RETENTION_DAYS
    retention_days = math.max(1, math.min(3650, retention_days))
    local cutoff = now - (retention_days * 86400)

    if not run_sql(db_path, string.format("DELETE FROM monitor_log WHERE timestamp < %d;", cutoff)) then
        log_error("failed to clean old monitoring data")
    end
end

-- 主循环
local function main_loop()
    local active_db_path = nil
    local attempted_db_path = nil
    local next_db_retry = 0

    while true do
        -- 重新加载配置
        uci:load("httping")

        local db_path = get_db_path()
        local now = os.time()
        if db_path ~= active_db_path and (db_path ~= attempted_db_path or now >= next_db_retry) then
            active_db_path = nil
            attempted_db_path = db_path
            if init_db(db_path) then
                active_db_path = db_path
                last_cleanup = 0
            else
                next_db_retry = now + 30
            end
        end

        local global_enabled = uci:get("httping", "global", "enabled")

        if global_enabled == "1" and active_db_path then
            -- 遍历所有 server 节点
            uci:foreach("httping", "server", function(s)
                check_server(active_db_path, s[".name"], s)
            end)
            cleanup_old_data(active_db_path, os.time())
        else
            -- 如果全局禁用，稍微 sleep 长一点，或者清空状态
            -- 这里选择不做特殊处理，只是跳过检测
        end

        -- 直接使用 nixio 休眠，避免每秒启动一个 shell 进程。
        nixio.nanosleep(1)
    end
end

main_loop()
