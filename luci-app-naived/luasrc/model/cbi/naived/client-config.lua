-- Copyright (C) 2017 yushi studio <ywb94@qq.com> github.com/ywb94
-- Licensed to the public under the GNU General Public License v3.

require "nixio.fs"
require "luci.sys"
require "luci.http"
require "luci.jsonc"
require "luci.model.uci"
local uci = require "luci.model.uci".cursor()

local m, s, o

local sid = arg[1]

-- Ensure program existence checks are accurate
local function is_finded(e)
	return luci.sys.exec(string.format('type -t -p "%s" 2>/dev/null', e)) ~= ""
end

-- Default save-and-apply behavior
local function apply_redirect(m)
	local tmp_uci_file = "/etc/config/" .. "naived" .. "_redirect"
	if m.redirect and m.redirect ~= "" then
		if nixio.fs.access(tmp_uci_file) then
			local redirect
			for line in io.lines(tmp_uci_file) do
				redirect = line:match("option%s+url%s+['\"]([^'\"]+)['\"]")
				if redirect and redirect ~= "" then break end
			end
			if redirect and redirect ~= "" then
				luci.sys.call("/bin/rm -f " .. tmp_uci_file)
				luci.http.redirect(redirect)
			end
		else
			nixio.fs.writefile(tmp_uci_file, "config redirect\n")
		end
		m.on_after_save = function(self)
			local redirect = self.redirect
			if redirect and redirect ~= "" then
				uci:set("naived" .. "_redirect", "@redirect[0]", "url", redirect)
			end
		end
	else
		luci.sys.call("/bin/rm -f " .. tmp_uci_file)
	end
end

local server_table = {}

m = Map("naived", translate("Edit NaiveD Server"))
m.redirect = luci.dispatcher.build_url("admin/services/naived/servers")
if m.uci:get("naived", sid) ~= "servers" then
	luci.http.redirect(m.redirect)
	return
end
-- Redirect to the node list after Save & Apply succeeds
apply_redirect(m)

-- [[ Servers Setting ]]--
s = m:section(NamedSection, sid, "servers")
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "naived_url", "NaiveD URL")
o.rawhtml = true
o.template = "naived/naivedurl"
o.value = sid

o = s:option(ListValue, "type", translate("Server Node Type"))
if is_finded("naive") then
	o:value("naiveproxy", translate("NaiveProxy"))
end
if is_finded("ipt2socks") then
	o:value("socks5", translate("Socks5"))
end

o.description = translate("Using incorrect encryption mothod may causes service fail to start")

o = s:option(Value, "alias", translate("Alias(optional)"))

o = s:option(Value, "server", translate("Server Address"))
o.datatype = "host"
o.rmempty = false
o:depends("type", "naiveproxy")
o:depends("type", "socks5")

o = s:option(Value, "server_port", translate("Server Port"))
o.datatype = "port"
o.rmempty = true
o:depends("type", "naiveproxy")
o:depends("type", "socks5")

o = s:option(Flag, "auth_enable", translate("Enable Authentication"))
o.rmempty = false
o.default = "0"
o:depends("type", "socks5")

o = s:option(Value, "username", translate("Username"))
o.rmempty = true
o:depends("type", "naiveproxy")
o:depends({type = "socks5", auth_enable = true})

o = s:option(Value, "password", translate("Password"))
o.password = true
o.rmempty = true
o:depends("type", "naiveproxy")
o:depends({type = "socks5", auth_enable = true})

o = s:option(Flag, "switch_enable", translate("Enable Auto Switch"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "local_port", translate("Local Port"))
o.datatype = "port"
o.default = 1234
o.rmempty = false

return m
