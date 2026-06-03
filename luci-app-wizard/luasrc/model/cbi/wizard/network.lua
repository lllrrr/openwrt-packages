local ldisp = require "luci.dispatcher"
local lhttp = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local function check_ipv4 (ip4addr)
	if not ip4addr then return nil end
	if not ip4addr:match("%.") then
		return nil
	end

	local b1, b2, b3, b4 = ip4addr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if b1 and b2 and b3 and b4 then
		b1 = tonumber(b1)
		b2 = tonumber(b2)
		b3 = tonumber(b3)
		b4 = tonumber(b4)
	else
		return nil
	end
	if b1 >= 0 and b1 <= 255 and
		b2 >= 0 and b2 <= 255 and
		b3 >= 0 and b3 <= 255 and
		b4 >= 0 and b4 <= 255 then
		return ip4addr
	else
		return nil
	end
	return nil
end

local mp, o, s

mp = Map("wizard", translate("网络设定"))
mp.description = translate("设定接入互联网的方式")

s = mp:section(TypedSection, "_dummy", "")
s.addremove = false
s.anonymous = true

function s.cfgsections()
	return { "_network" }
end

local device = uci:get("network", "wan", "ifname") or uci:get("network", "wan", "device")
if not device then
	mp.message = translate("WAN 网卡不存在！")
end

-- fs.readfile doesn't work, idk why
local default_proto = sys.exec("cat /tmp/wizard_network")
local proto = s:option(ListValue, "_proto", "上网方式")
proto:value("dhcp", translate("自动分配（DHCP）"))
proto:value("pppoe", translate("拨号上网（PPPoE）"))
proto:value("static", translate("静态地址（Static）"))
if default_proto and #default_proto > 0 then
	proto.default = default_proto
else
	proto.default = "pppoe"
end

local ppp_un = s:option(Value, "username", "用户名")
ppp_un:depends({_proto = "pppoe"})

local ppp_pw = s:option(Value, "password", "密码")
ppp_pw.password = true
ppp_pw:depends({_proto = "pppoe"})

local stk_ip = s:option(Value, "ip_addr", "IP 地址")
stk_ip.description = "示例：192.168.1.50"
stk_ip:depends({_proto = "static"})

local stk_subnet = s:option(Value, "subnet", "子网掩码")
stk_subnet.description = "示例：255.255.255.0"
stk_subnet:value("255.255.255.0")
stk_subnet:value("255.255.0.0")
stk_subnet:value("255.0.0.0")
stk_subnet.default = "255.255.255.0"
stk_subnet:depends({_proto = "static"})

local stk_gw = s:option(Value, "gateway", "网关地址")
stk_gw.description = "示例：192.168.1.1"
stk_gw:depends({_proto = "static"})

o = s:option(Button, "_network", "⁠")
o.inputtitle = translate("应用")
o.inputstyle = "apply"
o.write = function()
	local password, gateway, ip_addr, okay, subnet, type, username
	local net_type = proto:formvalue("_network")
	if net_type == "dhcp" then
		uci:set("network", "wan", "proto", "dhcp")
		okay = true
	elseif net_type == "pppoe" then
		username = ppp_un:formvalue("_network")
		password = ppp_pw:formvalue("_network")
		if username and password and #username > 0 and #password > 0 then
			uci:set("network", "wan", "proto", "pppoe")
			uci:set("network", "wan", "username", username)
			uci:set("network", "wan", "password", password)
			okay = true
		else
			mp.message = translate("用户名或密码不能为空！")
		end
	elseif net_type == "static" then
		ip_addr = stk_ip:formvalue("_network")
		subnet = stk_subnet:formvalue("_network")
		gateway = stk_gw:formvalue("_network")
		if not (check_ipv4(ip_addr) and check_ipv4(subnet) and check_ipv4(gateway)) then
			mp.message = translate("网络地址填写有误！")
		else
			uci:set("network", "wan", "proto", "static")
			uci:set("network", "wan", "ipaddr", ip_addr)
			uci:set("network", "wan", "subnet", subnet)
			uci:set("network", "wan", "gateway", gateway)
			okay = true
		end
	end

	if okay then
		uci:commit("network")
		uci:set("wizard", "config", "step", "wireless")
		uci:commit("wizard")
		lhttp.redirect(ldisp.build_url("admin", "wizard", "wireless"))
	end
end

o = s:option(DummyValue, "__dummy", "⁠")

o = s:option(Button, "_back", "⁠")
o.inputtitle = translate("返回上一步")
o.inputstyle = "reload"
o.write = function()
	uci:set("wizard", "config", "step", "password")
	uci:commit("wizard")
	lhttp.redirect(ldisp.build_url("admin", "wizard", "password"))
end

return mp
