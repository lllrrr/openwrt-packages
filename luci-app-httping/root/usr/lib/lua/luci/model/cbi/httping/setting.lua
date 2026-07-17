m = Map("httping", translate("Network Latency Monitor Settings"))

s = m:section(NamedSection, "global", "global", translate("Global Settings"))
s:option(Flag, "enabled", translate("Enable Monitor"))
s:option(Value, "db_path", translate("Database Path"), translate("Default: /etc/httping_data.db"))

btn = s:option(Button, "_clear", translate("Data Management"))
btn.inputtitle = translate("Clear All History Data")
btn.inputstyle = "remove" 
btn.write = function(self, section)
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "httping", "clear_data"))
end

ts = m:section(TypedSection, "server", translate("Server Node List"))
ts.template = "cbi/tblsection"
ts.addremove = true
ts.anonymous = true

-- 【修改重点】重写删除逻辑，实现立即清空数据库数据
function ts.remove(self, section)
    -- 1. 获取要删除的服务器名称
    local name = self.map:get(section, "name")
    
    if name and name ~= "" then
        -- 2. 获取数据库路径
        local uci = require "luci.model.uci".cursor()
        local db_path = uci:get("httping", "global", "db_path") or "/etc/httping_data.db"
        
        -- 3. 执行 SQLite 删除命令 (转义单引号防止SQL注入)
        local safe_name = name:gsub("'", "''")
        local cmd = string.format("sqlite3 %s \"DELETE FROM monitor_log WHERE server_name = '%s';\"", db_path, safe_name)
        os.execute(cmd)
    end

    -- 4. 调用父类的删除方法完成 UCI 配置的删除
    return TypedSection.remove(self, section)
end

ts:option(Flag, "enabled", translate("Enable"))
ts:option(Value, "name", translate("Display Name"))

local type = ts:option(ListValue, "type", translate("Detection Type"))
type:value("httping", "HTTPing")
type:value("tcping", "TCPing")
type.default = "httping"

local url = ts:option(Value, "url", translate("Address/URL"))
url.description = translate("HTTPing: http://example.com | TCPing: example.com:80")

ts:option(Value, "interval", translate("Detection Interval (seconds)"))

return m