local DEFAULT_DB_PATH = "/etc/httping_data.db"

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function sql_quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function run_sql(db_path, sql)
    local cmd = "sqlite3 -batch -cmd " .. shell_quote(".timeout 5000") ..
        " " .. shell_quote(db_path) .. " " .. shell_quote(sql) .. " >/dev/null"
    local result = os.execute(cmd)
    return result == true or result == 0
end

m = Map("httping", translate("Network Latency Monitor Settings"))

s = m:section(NamedSection, "global", "global", translate("Global Settings"))
s:option(Flag, "enabled", translate("Enable Monitor"))

local db_path = s:option(Value, "db_path", translate("Database Path"), translate("Default: /etc/httping_data.db"))
db_path.default = DEFAULT_DB_PATH
db_path.rmempty = false
db_path.validate = function(self, value)
    if not value or value:sub(1, 1) ~= "/" or value:find("%c") then
        return nil, translate("Please enter an absolute path without control characters")
    end
    return value
end

local retention = s:option(Value, "retention_days", translate("Data Retention Days"), translate("Automatically delete historical data older than this period"))
retention.default = 90
retention.datatype = "range(1,3650)"
retention.rmempty = false

btn = s:option(Button, "_clear", translate("Data Management"))
btn.inputtitle = translate("Clear All History Data")
btn.inputstyle = "remove"
btn.write = function(self, section)
    local path = self.map:get("global", "db_path") or DEFAULT_DB_PATH
    if run_sql(path, "DELETE FROM monitor_log; VACUUM;") then
        self.map.message = translate("History data cleared")
    else
        self.map.message = translate("Failed to clear data; check the database path and system log")
    end
end

ts = m:section(TypedSection, "server", translate("Server Node List"))
ts.template = "cbi/tblsection"
ts.addremove = true
ts.anonymous = true

-- 删除节点时同步删除其历史数据。
function ts.remove(self, section)
    local name = self.map:get(section, "name")

    if name and name ~= "" then
        -- shell 参数和 SQL 字符串分别转义。
        local path = self.map:get("global", "db_path") or DEFAULT_DB_PATH
        run_sql(path, "DELETE FROM monitor_log WHERE server_name = " .. sql_quote(name) .. ";")
    end

    return TypedSection.remove(self, section)
end

local enabled = ts:option(Flag, "enabled", translate("Enable"))
enabled.default = 1

local name = ts:option(Value, "name", translate("Display Name"))
name.rmempty = false
name.validate = function(self, value, section)
    if not value or value == "" or #value > 128 or value:find("%c") then
        return nil, translate("Name is required, must not contain control characters, and must be at most 128 characters")
    end

    local duplicate = false
    self.map.uci:foreach("httping", "server", function(server)
        if server[".name"] ~= section and server.name == value then
            duplicate = true
        end
    end)
    if duplicate then
        return nil, translate("Display names must be unique")
    end
    return value
end

local type = ts:option(ListValue, "type", translate("Detection Type"))
type:value("httping", "HTTPing")
type:value("tcping", "TCPing")
type.default = "httping"

local url = ts:option(Value, "url", translate("Address/URL"))
url.description = translate("HTTPing: http://example.com | TCPing: example.com:80")
url.rmempty = false
url.validate = function(self, value, section)
    if not value or value == "" or #value > 2048 or value:find("%c") then
        return nil, translate("Address is required, must not contain control characters, and must be at most 2048 characters")
    end

    local check_type = self.map:get(section, "type") or "httping"
    if check_type == "httping" and not value:match("^https?://") then
        return nil, translate("HTTPing address must start with http:// or https://")
    end
    if check_type == "tcping" then
        local _, colon_count = value:gsub(":", "")
        local port = value:match("^%[.-%]:(%d+)$") or value:match("^[^:]+:(%d+)$")
        local bracketed_host = value:match("^%[.-%]$")

        if colon_count > 1 and not port and not bracketed_host then
            return nil, translate("IPv6 addresses must use the [IPv6]:port format")
        end
        if colon_count == 1 and not port then
            return nil, translate("TCPing port must be numeric")
        end
        if port and (tonumber(port) < 1 or tonumber(port) > 65535) then
            return nil, translate("TCPing port must be between 1 and 65535")
        end
    end
    return value
end

local interval = ts:option(Value, "interval", translate("Detection Interval (seconds)"))
interval.default = 60
interval.datatype = "range(5,86400)"
interval.rmempty = false

return m
