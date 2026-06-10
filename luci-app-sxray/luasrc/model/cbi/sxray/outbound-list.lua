-- Copyright 2019-2020 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the MIT License.

local dsp = require "luci.dispatcher"

local m, s, o, imp

m = Map("sxray", "%s - %s" % { translate("SXray"), translate("Outbound") })

imp = m:section(SimpleSection)
imp.template = "sxray/outbound_import"

s = m:section(TypedSection, "outbound")
s.anonymous = true
s.addremove = true
s.sortable = true
s.template = "cbi/tblsection"
s.extedit = dsp.build_url("admin/services/sxray/outbounds/%s")
s.create = function (...)
	local sid = TypedSection.create(...)
	if sid then
		m.uci:save("sxray")
		luci.http.redirect(s.extedit % sid)
		return
	end
end

o = s:option(DummyValue, "alias", translate("Alias"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "?"
end

o = s:option(DummyValue, "send_through", translate("Send Through"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "-"
end

o = s:option(DummyValue, "protocol", translate("Protocol"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "?"
end

o = s:option(DummyValue, "ss_network", translate("Stream Network"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "?"
end

o = s:option(DummyValue, "tag", translate("Tag"))
o.cfgvalue = function (...)
	return Value.cfgvalue(...) or "?"
end


return m
