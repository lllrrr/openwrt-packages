local ldisp = require "luci.dispatcher"
local lhttp = require "luci.http"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local mp, o, pw1, pw2, s

mp = Map("wizard", translate("主机密码"))
mp.description = translate("设定访问设备的管理员密码")

s = mp:section(TypedSection, "_dummy", "")
s.addremove = false
s.anonymous = true

function s.cfgsections()
	return { "_pass" }
end

pw1 = s:option(Value, "pw1", translate("密码"))
pw1.password = true

pw2 = s:option(Value, "pw2", translate("确认密码"))
pw2.password = true

o = s:option(Button, "_password", "⁠")
o.inputtitle = translate("应用")
o.inputstyle = "apply"
o.write = function()
	local v1 = pw1:formvalue("_pass")
	local v2 = pw2:formvalue("_pass")

	if v1 and v2 and #v1 > 0 and #v2 > 0 then
		if v1 == v2 then
			if luci.sys.user.setpasswd(luci.dispatcher.context.authuser, v1) == 0 then
				-- mp.message = translate("密码更改成功！")
				uci:set("wizard", "config", "step", "network")
				uci:commit("wizard")
				lhttp.redirect(ldisp.build_url("admin", "wizard", "network"))
			else
				mp.message = translate("发生未知错误，密码没有更改！")
			end
		else
			mp.message = translate("由于密码验证不匹配，密码没有更改！")
		end
	else
		mp.message = translate("请输入密码！")
	end
end

o = s:option(DummyValue, "__dummy", "⁠")

o = s:option(Button, "_back", "⁠")
o.inputtitle = translate("返回上一步")
o.inputstyle = "reload"
o.write = function()
	uci:set("wizard", "config", "step", "welcome")
	uci:commit("wizard")
	lhttp.redirect(ldisp.build_url("admin", "wizard", "welcome"))
end

return mp
