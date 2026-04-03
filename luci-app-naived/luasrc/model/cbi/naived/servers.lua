-- Licensed to the public under the GNU General Public License v3.
require "luci.http"
require "luci.sys"
require "nixio.fs"
require "luci.dispatcher"
require "luci.model.uci"
local cbi = require "luci.cbi"
local uci = require "luci.model.uci".cursor()

local m, s, o, node
local server_count = 0

-- Ensure program existence checks are accurate
local function is_finded(e)
	return luci.sys.exec(string.format('type -t -p "%s" 2>/dev/null', e)) ~= ""
end

uci:foreach("naived", "servers", function(s)
	server_count = server_count + 1
end)

m = Map("naived", translate("Servers manage"))

-- [[ Servers Manage ]]--
s = m:section(TypedSection, "servers")
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"
s.sortable = true
s.extedit = luci.dispatcher.build_url("admin", "services", "naived", "servers", "%s")
function s.create(...)
	local sid = TypedSection.create(...)
	if sid then
		luci.http.redirect(s.extedit % sid)
		return
	end
end

o = s:option(DummyValue, "type", translate("Type"))
function o.cfgvalue(self, section)
	return Value.cfgvalue(self, section) or translate("None")
end

o = s:option(DummyValue, "alias", translate("Alias"))
function o.cfgvalue(...)
	return Value.cfgvalue(...) or translate("None")
end

o = s:option(DummyValue, "server_port", translate("Server Port"))
function o.cfgvalue(...)
	return Value.cfgvalue(...) or "N/A"
end

o = s:option(DummyValue, "server_port", translate("Socket Connected"))
o.template = "naived/socket"
o.width = "10%"
o.render = function(self, section, scope)
	self.transport = s:cfgvalue(section).transport
	if self.transport == 'ws' then
		self.ws_path = s:cfgvalue(section).ws_path
		self.tls = s:cfgvalue(section).tls
	end
	DummyValue.render(self, section, scope)
end

o = s:option(DummyValue, "server", translate("Ping Latency"))
o.template = "naived/ping"
o.width = "10%"

local global_server = uci:get_first('naived', 'global', 'global_server') 

node = s:option(Button, "apply_node", translate("Apply"))
node.inputstyle = "apply"
node.render = function(self, section, scope)
	if section == global_server then
		self.title = translate("Reapply")
	else
		self.title = translate("Apply")
	end
	Button.render(self, section, scope)
end
node.write = function(self, section)
	uci:set("naived", '@global[0]', 'global_server', section)
	uci:save("naived")
	uci:commit("naived")
	luci.http.redirect(luci.dispatcher.build_url("admin", "services", "naived", "restart"))
end

o = s:option(Flag, "switch_enable", translate("Auto Switch"))
o.rmempty = false
function o.cfgvalue(...)
	return Value.cfgvalue(...) or 1
end

m:append(Template("naived/server_list"))

return m
