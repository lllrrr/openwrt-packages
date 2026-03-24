module("luci.controller.vnt2", package.seeall)

function index()
   
   if not nixio.fs.access("/etc/config/vnt2") then
      return
   end

   entry({"admin", "vpn", "vnt2"}, cbi("vnt2"), _("VNT2.0客户端"), 60).dependent = true

end

