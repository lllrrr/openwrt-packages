
module("luci.controller.onlineupgrade", package.seeall)
local sys = require "luci.sys"
local json = require "luci.jsonc"

function index()
    entry({"admin","services","ota"}, template("ota/index"), _("OTA Upgrade"), 60)
    entry({"admin","services","ota","start"}, call("start")).leaf = true
    entry({"admin","services","ota","status"}, call("status")).leaf = true
    entry({"admin","services","ota","firmware"}, call("firmware")).leaf = true
end

function firmware()
    local f = io.open("/etc/ota/firmware.json","r")
    if not f then
        luci.http.write_json({list={}})
        return
    end
    local data = f:read("*a")
    f:close()
    luci.http.prepare_content("application/json")
    luci.http.write(data)
end

function start()
    os.execute("/usr/bin/ota.sh start &")
    luci.http.write_json({ok=true})
end

function status()
    local f = io.open("/tmp/ota.log","r")
    local log = ""
    if f then
        log = f:read("*a")
        f:close()
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({log=log})
end
