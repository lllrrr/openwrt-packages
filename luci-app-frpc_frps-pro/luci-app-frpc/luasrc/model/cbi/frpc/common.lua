-- Copyright 2019 Xingwang Liao <kuoruan@gmail.com> #modify by superzjg@gmail.com 20240810
-- Licensed to the public under the MIT License.

local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local fs = require "nixio.fs"
local sys = require "luci.sys"

local m, s, o

local function frpc_version()
	local file = uci:get("frpc", "main", "default_client_file")
	if not file or file == "" or not fs.stat(file) then
		return "<em style=\"color: red;\">%s</em>" % translate("可执行文件无效")
	end
	if not fs.access(file, "rwx", "rx", "rx") then
		fs.chmod(file, 755)
	end
	local version = util.trim(sys.exec("%s -v 2>/dev/null" % file))
	if version == "" then
		return "<em style=\"color: red;\">%s</em>" % translate("未能获取到版本信息")
	end
	if version < "0.52.0" then
		return "<em style=\"color: red;\">%s</em>" % translatef("升级至 0.52.0 或以上才支持 toml 配置文件，当前版本：%s", version)
	end
	return translatef("版本: %s", version)
end

m = Map("frpc", "%s - %s" % { translate("Frpc"), translate("通用设置") },
"<p>%s</p><p>%s</p><p>%s</p>" % {
	translate("Frp 是一个可用于内网穿透的高性能的反向代理应用。多实例模式下，每个服务器（server）就是一个独立的 frpc 进程。"),
	translatef("获取更多信息，请访问： %s",
		"<a href=\"https://github.com/fatedier/frp\" target=\"_blank\">https://github.com/fatedier/frp</a>；官方文档：<a href=\"https://gofrp.org/zh-cn/\" target=\"_blank\">gofrp.org</a>"),
	translatef("本插件仓库： %s",
		"<a href=\"https://github.com/mia-clark/luci-app-frpc_frps-pro\" target=\"_blank\">https://github.com/mia-clark/luci-app-frpc_frps-pro</a>")
})

m:append(Template("frpc/theme"))
m:append(Template("frpc/status_header"))

s = m:section(NamedSection, "main", "frpc")
s.addremove = false
s.anonymous = true

s:tab("general", translate("常规选项"))
s:tab("program", translate("程序管理"))

o = s:taboption("program", DummyValue, "_program_ui", "")
o.template = "frpc/program_manager"
o.rawhtml = true
o.cfgvalue = function() return "" end

o = s:taboption("general", Flag, "enabled", translate("全局启用"))
o.description = translate("总开关；关闭则所有实例都不启动")

o = s:taboption("general", Value, "default_client_file", translate("默认可执行文件路径"), frpc_version())
o.rmempty = false
o.default = "/usr/bin/frpc"
o.description = translate("server 若未指定 client_file，则使用此默认值。可在「程序管理」中下载/切换版本。")

o = s:taboption("general", ListValue, "default_run_user", translate("默认运行用户"))
o:value("", translate("-- 默认 --"))
for user in util.execi("cat /etc/passwd | cut -d':' -f1") do
	if user then o:value(user) end
end

return m
