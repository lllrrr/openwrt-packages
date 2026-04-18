module("luci.controller.ota", package.seeall)

function index()
 entry({"admin","services","ota"}, template("ota/index"), _("OTA"), 60)
 entry({"admin","services","ota","start"}, call("start")).leaf=true
 entry({"admin","services","ota","state"}, call("state")).leaf=true
end

function start()
 os.execute("/usr/bin/ota.sh &")
 luci.http.write_json({ok=true})
end

function state()
 local f=io.open("/tmp/ota_state.json","r")
 if f then
  luci.http.write(f:read("*a"))
  f:close()
 else
  luci.http.write_json({state="IDLE"})
 end
end