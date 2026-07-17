module("luci.controller.httping", package.seeall)

local DEFAULT_DB_PATH = "/etc/httping_data.db"
local MAX_RANGE_SECONDS = 366 * 86400
local MAX_POINTS_PER_SERVER = 5000

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_succeeded(result)
    return result == true or result == 0
end

local function sqlite_query(db_path, sql)
    local cmd = "sqlite3 -batch -json -cmd " .. shell_quote(".timeout 5000") ..
        " " .. shell_quote(db_path) .. " " .. shell_quote(sql) .. " 2>/dev/null"
    local pipe = io.popen(cmd)
    if not pipe then return nil end

    local output = pipe:read("*a")
    local ok = pipe:close()
    if not command_succeeded(ok) then return nil end
    return output
end

function index()
    entry({"admin", "services", "httping"}, alias("admin", "services", "httping", "graph"), _("Network Latency Monitor"), 50).dependent = true
    entry({"admin", "services", "httping", "graph"}, template("httping/graph"), _("Monitor Graph"), 1)
    entry({"admin", "services", "httping", "setting"}, cbi("httping/setting"), _("Server Settings"), 2)
    entry({"admin", "services", "httping", "get_data"}, call("action_get_data"))
end

function action_get_data()
    local luci_http = require "luci.http"
    local now = os.time()
    local start_value = tonumber(luci_http.formvalue("start"))
    local end_value = tonumber(luci_http.formvalue("end"))

    if start_value ~= nil and (start_value ~= start_value or start_value == math.huge or start_value == -math.huge) then
        start_value = nil
    end
    if end_value ~= nil and (end_value ~= end_value or end_value == math.huge or end_value == -math.huge) then
        end_value = nil
    end

    local latest_allowed = now + 86400
    local start_ts = math.max(0, math.min(latest_allowed, math.floor(start_value or (now - 3600))))
    local end_ts = math.max(0, math.min(latest_allowed, math.floor(end_value or now)))

    if start_ts > end_ts then
        luci_http.status(400, "Invalid time range")
        luci_http.prepare_content("application/json")
        luci_http.write('{"error":"start must not be later than end"}')
        return
    end

    if (end_ts - start_ts) > MAX_RANGE_SECONDS then
        start_ts = end_ts - MAX_RANGE_SECONDS
    end

    local range = math.max(1, end_ts - start_ts)
    local bucket_width = math.max(1, math.ceil(range / MAX_POINTS_PER_SERVER))

    local uci = require "luci.model.uci".cursor()
    local db_path = uci:get("httping", "global", "db_path") or DEFAULT_DB_PATH

    local sql = string.format([[
        SELECT
            server_name,
            MIN(timestamp) AS timestamp,
            AVG(duration) AS duration,
            COUNT(*) AS sample_count,
            SUM(CASE WHEN duration IS NULL THEN 1 ELSE 0 END) AS loss_count
        FROM monitor_log
        WHERE timestamp >= %d AND timestamp <= %d
        GROUP BY server_name, CAST((timestamp - %d) / %d AS INTEGER)
        ORDER BY timestamp ASC;
    ]], start_ts, end_ts, start_ts, bucket_width)

    local output = sqlite_query(db_path, sql)

    if output == nil then
        luci_http.status(500, "Database query failed")
        luci_http.prepare_content("application/json")
        luci_http.write('{"error":"database query failed"}')
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write(output ~= "" and output or "[]")
end
