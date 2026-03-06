#!/usr/bin/lua

local nixio = require "nixio"
local uci = require "luci.model.uci".cursor()
-- 引入 string 库防止部分环境未自动加载
local string = require "string"

-- 配置常量
local DEFAULT_DB_PATH = "/etc/httping_data.db"
local CURL_TIMEOUT = 5

-- 状态记录 (减少文件IO)
-- Key: section_name, Value: last_run_timestamp
local last_run_map = {}

-- 辅助函数：获取数据库路径
local function get_db_path()
    local db_path = uci:get("httping", "global", "db_path")
    if not db_path or db_path == "" then
        db_path = DEFAULT_DB_PATH
    end
    return db_path
end

-- 数据库初始化 (保留 Shell 版本逻辑，确保表结构存在)
local function init_db(db_path)
    if not nixio.fs.access(db_path) then
        local cmds = {
            string.format("sqlite3 '%s' \"CREATE TABLE monitor_log (id INTEGER PRIMARY KEY AUTOINCREMENT, server_name TEXT, timestamp INTEGER, duration REAL, type TEXT DEFAULT 'httping');\"", db_path),
            string.format("sqlite3 '%s' \"CREATE INDEX idx_ts ON monitor_log(timestamp);\"", db_path),
            string.format("sqlite3 '%s' \"CREATE INDEX idx_name ON monitor_log(server_name);\"", db_path),
            string.format("sqlite3 '%s' \"PRAGMA journal_mode=WAL;\"", db_path)
        }
        for _, cmd in ipairs(cmds) do
            os.execute(cmd)
        end
    end
end

-- 写入日志
local function log_result(db_path, name, ts, duration, type_str)
    local val_duration = "NULL"
    if duration then
        val_duration = string.format("%.3f", duration)
    end
    
    local sql = string.format("INSERT INTO monitor_log (server_name, timestamp, duration, type) VALUES ('%s', %d, %s, '%s');",
        name, ts, val_duration, type_str)
    
    -- 使用 sqlite3 CLI 执行 (避免依赖 lsqlite3)
    -- 注意：生产环境应考虑 SQL 注入风险，但此处 name 来自配置，相对可控
    local cmd = string.format("sqlite3 '%s' \"%s\"", db_path, sql)
    os.execute(cmd)
end

-- TCPing 实现 (纯 Lua)
local function do_tcping(url)
    local host, port
    
    -- 解析 URL (简单处理 [IPv6]:port 和 host:port)
    if url:match("^%[") then
        host = url:match("^%[(.-)%]")
        port = url:match("]:(%d+)$")
    else
        host = url:match("^(.-):(%d+)$")
        if not host then
            host = url
        end
    end
    
    if not port then port = 80 end
    port = tonumber(port)
    
    if not host then return nil end

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
    
    -- 4. 使用 poll 等待连接完成 (Timeout 2秒)
    -- POLLOUT 通常为 4
    local pstat = nixio.poll({{fd=sock, events=4}}, 2000)
    
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
    local cmd = string.format("curl -L -k -s -o /dev/null -w \"%%{time_namelookup} %%{time_total}\" --max-time %d \"%s\"", CURL_TIMEOUT, url)
    local f = io.popen(cmd)
    if not f then return nil end
    
    local output = f:read("*a")
    f:close()
    
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
local function check_server(section_name, config)
    local enabled = config.enabled or "0"
    if enabled ~= "1" then return end
    
    local url = config.url
    if not url or url == "" then return end
    
    local interval = tonumber(config.interval) or 60
    local check_type = config.type or "httping"
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
        log_result(get_db_path(), name, now, duration, check_type)
    end
end

-- 主循环
local function main_loop()
    local db_path = get_db_path()
    init_db(db_path)
    
    while true do
        -- 重新加载配置
        uci:load("httping")
        
        local global_enabled = uci:get("httping", "global", "enabled")
        
        if global_enabled == "1" then
            -- 遍历所有 server 节点
            uci:foreach("httping", "server", function(s)
                check_server(s[".name"], s)
            end)
        else
            -- 如果全局禁用，稍微 sleep 长一点，或者清空状态
            -- 这里选择不做特殊处理，只是跳过检测
        end
        
        -- 简单的主循环休眠
        -- 实际上为了精度可以使用 nixio.nanosleep，但 1 秒间隔对于监控来说足够
        os.execute("sleep 1")
    end
end

main_loop()
