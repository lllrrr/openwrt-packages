module("luci.controller.vnt2", package.seeall)

local nixio = require("nixio")

function index()

   if not nixio.fs.access("/etc/config/vnt2") then
      return
   end

   local e = entry({"admin", "vpn", "vnt2"}, cbi("vnt2"), _("VNT2.0客户端"), 60)
   e.dependent = true

   entry({"admin", "vpn", "vnt2", "save_config"}, call("action_save_config")).leaf = true

end

-- 最大配置文件大小（1MB）
local MAX_CONFIG_SIZE = 1024 * 1024

function action_save_config()
   local http    = require("luci.http")
   local uci     = require("luci.model.uci").cursor()
   local luci_util = require("luci.util")

   local content = http.formvalue("content")

   if not content then
      http.status(400, "Bad Request")
      http.write("missing parameters")
      return
   end

   -- 检查配置文件大小，防止大文件攻击
   if #content > MAX_CONFIG_SIZE then
      http.status(400, "Bad Request")
      http.write("config file too large (max 1MB)")
      return
   end

   -- 仅允许写入 UCI 中配置的 config_path，防止任意文件写入漏洞
   local allowed_path = uci:get("vnt2", "@main[0]", "config_path")
   if not allowed_path or allowed_path == "" then
      http.status(500, "Internal Server Error")
      http.write("cannot determine config path from UCI")
      return
   end

   local f, err = io.open(allowed_path, "w")
   if not f then
      http.status(500, "Internal Server Error")
      http.write("cannot open file: " .. tostring(err))
      return
   end

   f:write(content)
   f:close()

   http.status(200, "OK")
   http.write("ok")
end
