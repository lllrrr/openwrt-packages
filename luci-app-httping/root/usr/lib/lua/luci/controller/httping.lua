module("luci.controller.httping", package.seeall)

function index()
    entry({"admin", "services", "httping"}, alias("admin", "services", "httping", "graph"), _("Network Latency Monitor"), 50).dependent = true
    entry({"admin", "services", "httping", "graph"}, template("httping/graph"), _("Monitor Graph"), 1)
    entry({"admin", "services", "httping", "setting"}, cbi("httping/setting"), _("Server Settings"), 2)
    entry({"admin", "services", "httping", "get_data"}, call("action_get_data"))
    entry({"admin", "services", "httping", "clear_data"}, call("action_clear_data"))
end

function action_get_data()
    local luci_http = require "luci.http"
    local start_ts = tonumber(luci_http.formvalue("start")) or (os.time() - 3600)
    local end_ts = tonumber(luci_http.formvalue("end")) or os.time()
    
    local uci = require "luci.model.uci".cursor()
    local db_path = uci:get("httping", "global", "db_path") or "/etc/httping_data.db"
    
    local cmd = string.format("sqlite3 -json %s \"SELECT server_name, timestamp, duration FROM monitor_log WHERE timestamp >= %d AND timestamp <= %d ORDER BY timestamp ASC;\"", db_path, start_ts, end_ts)
    
    local f = io.popen(cmd)
    local output = f:read("*a")
    f:close()
    
    luci_http.prepare_content("application/json")
    luci_http.write(output or "[]")
end

function action_clear_data()
    local uci = require "luci.model.uci".cursor()
    local db_path = uci:get("httping", "global", "db_path") or "/etc/httping_data.db"
    os.execute("sqlite3 " .. db_path .. " \"DELETE FROM monitor_log; VACUUM;\"")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "httping", "setting"))
end