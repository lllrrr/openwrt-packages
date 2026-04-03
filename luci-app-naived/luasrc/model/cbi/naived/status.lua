-- Copyright (C) 2017 yushi studio <ywb94@qq.com>
-- Licensed to the public under the GNU General Public License v3.
require "nixio.fs"
require "luci.sys"
require "luci.model.uci"
local m, s, o
local redir_run = 0
local reudp_run = 0
local sock5_run = 0
local gfw_count = 0
local ad_count = 0
local ip_count = 0
local nfip_count = 0
local Process_list = luci.sys.exec("busybox ps -w")
local uci = require "luci.model.uci".cursor()
-- html constants
font_blue = [[<b style=color:green>]]
style_blue = [[<b style=color:red>]]
font_off = [[</b>]]
bold_on = [[<strong>]]
bold_off = [[</strong>]]

if nixio.fs.access("/etc/naived/gfw_list.conf") then
	gfw_count = tonumber(luci.sys.exec("cat /etc/naived/gfw_list.conf | wc -l")) / 2
end

if nixio.fs.access("/etc/naived/ad.conf") then
	ad_count = tonumber(luci.sys.exec("cat /etc/naived/ad.conf | wc -l"))
end

if nixio.fs.access("/etc/naived/china_ip.txt") then
	ip_count = tonumber(luci.sys.exec("cat /etc/naived/china_ip.txt | wc -l"))
end

if nixio.fs.access("/etc/naived/applechina.conf") then
	apple_count = tonumber(luci.sys.exec("cat /etc/naived/applechina.conf | wc -l"))
end

if nixio.fs.access("/etc/naived/netflixip.list") then
	nfip_count = tonumber(luci.sys.exec("cat /etc/naived/netflixip.list | wc -l"))
end

if Process_list:find("udp-only-naived-reudp", 1, true) then
	reudp_run = 1
end

--[[
if Process_list:find("tcp.udp.dual.naived.retcp", 1, true) then
	redir_run = 1
end
]]--

if Process_list:find("tcp-only-naived-retcp", 1, true) then
	redir_run = 1
end

if Process_list:find("tcp-udp-naived-local", 1, true) then
	sock5_run = 1
end

if Process_list:find("tcp-udp-naived-retcp", 1, true) then
	redir_run = 1
	reudp_run = 1
end

--[[
if Process_list:find("nft.naived.retcp", 1, true) then
	redir_run = 1
end
]]--

if Process_list:find("local-naived-retcp", 1, true) then
	redir_run = 1
	sock5_run = 1
end

--[[
if Process_list:find("local.nft.naived.retcp", 1, true) then
	redir_run = 1
	sock5_run = 1
end
]]--

if Process_list:find("local-udp-naived-retcp", 1, true) then
	reudp_run = 1
	redir_run = 1
	sock5_run = 1
end


if  Process_list:find("naived/bin/dns2tcp") or
    Process_list:find("dnsproxy.*127.0.0.1.*5335") or
    Process_list:find("chinadns.*127.0.0.1.*5335") then
	pdnsd_run = 1
end

m = SimpleForm("Version")
m.reset = false
m.submit = false

s = m:field(DummyValue, "redir_run", translate("Global Client"))
s.rawhtml = true
if redir_run == 1 then
	s.value = font_blue .. bold_on .. translate("Running") .. bold_off .. font_off
else
	s.value = style_blue .. bold_on .. translate("Not Running") .. bold_off .. font_off
end

s = m:field(DummyValue, "reudp_run", translate("Game Mode UDP Relay"))
s.rawhtml = true
if reudp_run == 1 then
	s.value = font_blue .. bold_on .. translate("Running") .. bold_off .. font_off
else
	s.value = style_blue .. bold_on .. translate("Not Running") .. bold_off .. font_off
end

if uci:get_first("naived", 'global', 'pdnsd_enable', '0') ~= '0' then
	s = m:field(DummyValue, "pdnsd_run", translate("DNS Anti-pollution"))
	s.rawhtml = true
	if pdnsd_run == 1 then
		s.value = font_blue .. bold_on .. translate("Running") .. bold_off .. font_off
	else
		s.value = style_blue .. bold_on .. translate("Not Running") .. bold_off .. font_off
	end
end

s = m:field(DummyValue, "sock5_run", translate("Global SOCKS5 Proxy Server"))
s.rawhtml = true
if sock5_run == 1 then
	s.value = font_blue .. bold_on .. translate("Running") .. bold_off .. font_off
else
	s.value = style_blue .. bold_on .. translate("Not Running") .. bold_off .. font_off
end

s = m:field(Button, "Restart", translate("Restart Naived"))
s.inputtitle = translate("Restart Service")
s.inputstyle = "reload"
s.write = function()
	luci.sys.call("/etc/init.d/naived restart >/dev/null 2>&1 &")
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "naived", "client"))
end

s = m:field(DummyValue, "google", translate("Google Connectivity"))
s.value = translate("No Check")
s.template = "naived/check"

s = m:field(DummyValue, "baidu", translate("Baidu Connectivity"))
s.value = translate("No Check")
s.template = "naived/check"

s = m:field(DummyValue, "gfw_data", translate("GFW List Data"))
s.rawhtml = true
s.template = "naived/refresh"
s.value = gfw_count .. " " .. translate("Records")

s = m:field(DummyValue, "ip_data", translate("China IP Data"))
s.rawhtml = true
s.template = "naived/refresh"
s.value = ip_count .. " " .. translate("Records")

if uci:get_first("naived", 'global', 'apple_optimization', '0') ~= '0' then
	s = m:field(DummyValue, "apple_data", translate("Apple Domains Data"))
	s.rawhtml = true
	s.template = "naived/refresh"
	s.value = apple_count .. " " .. translate("Records")
end

if uci:get_first("naived", 'global', 'netflix_enable', '0') ~= '0' then
	s = m:field(DummyValue, "nfip_data", translate("Netflix IP Data"))
	s.rawhtml = true
	s.template = "naived/refresh"
	s.value = nfip_count .. " " .. translate("Records")
end

if uci:get_first("naived", 'global', 'adblock', '0') == '1' then
	s = m:field(DummyValue, "ad_data", translate("Advertising Data"))
	s.rawhtml = true
	s.template = "naived/refresh"
	s.value = ad_count .. " " .. translate("Records")
end

s = m:field(DummyValue, "check_port", translate("Check Server Port"))
s.template = "naived/checkport"
s.value = translate("No Check")

return m
