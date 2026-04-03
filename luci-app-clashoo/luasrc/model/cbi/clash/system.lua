local NXFS = require "nixio.fs"
local SYS  = require "luci.sys"
local HTTP = require "luci.http"
local DISP = require "luci.dispatcher"
local UTIL = require "luci.util"
local uci  = require("luci.model.uci").cursor()
local fs   = require "luci.clash"

local font_green = [[<font color="green">]]
local font_off   = [[</font>]]
local bold_on    = [[<strong>]]
local bold_off   = [[</strong>]]

-- ── 第一块：内核下载 ──────────────────────────────────────────────
local cpu_model = SYS.exec(
	"opkg status libc 2>/dev/null | grep 'Architecture' | awk -F ': ' '{print $2}' 2>/dev/null"
)

ku = Map("clash")
ku.pageaction = false
s = ku:section(TypedSection, "clash", "内核下载")
s.anonymous = true
s.addremove  = false
s.description = "从 GitHub 下载 Mihomo 内核二进制文件"

o = s:option(ListValue, "dcore", "版本类型")
o.default = "3"
o:value("2", "mihomo（稳定版）")
o:value("3", "Alpha（预发布版）")
o.description = "稳定版适合日常使用，Alpha 版含最新功能但可能有不稳定风险"

o = s:option(ListValue, "download_core", "CPU 架构")
o.default     = "x86_64"
o.description = "当前设备：" .. font_green .. bold_on .. cpu_model:gsub("%s+$", "") .. bold_off .. font_off
o:value("aarch64_cortex-a53")
o:value("aarch64_generic")
o:value("arm_cortex-a7_neon-vfpv4")
o:value("mipsel_24kc")
o:value("mips_24kc")
o:value("x86_64")
o:value("riscv64")

o = s:option(Value, "core_mirror_prefix", "下载镜像前缀（可选）")
o.rmempty     = true
o.placeholder = "https://gh-proxy.com/"
o.description = "留空直连 GitHub；国内可填镜像前缀提升成功率"

o = s:option(Button, "down_core", "")
o.inputtitle = "保存配置"
o.inputstyle = "apply"
o.write = function()
	ku.uci:commit("clash")
end

o = s:option(Button, "download", "")
o.template = "clash/core_check"

-- ── 第二块：GeoIP 数据库 ──────────────────────────────────────────
local function geoip_update_time()
	local paths = {
		"/etc/clash/Country.mmdb",
		"/usr/share/clash/geoip/Country.mmdb",
		"/usr/share/mihomo/Country.mmdb",
	}
	for _, p in ipairs(paths) do
		if NXFS.access(p) then
			return SYS.exec("ls -l --full-time " .. p .. " | awk '{print $6, $7}'")
		end
	end
	return "-"
end

gm = Map("clash")
gm.pageaction = false
gs = gm:section(TypedSection, "clash", "GeoIP / GeoSite 数据库")
gs.anonymous = true
gs.addremove  = false
gs.description = "Mihomo 使用 GeoIP/GeoSite 数据库进行规则匹配，建议定期更新"

o = gs:option(Flag, "auto_update_geoip", "自动更新")
o.description = "开启后按指定周期自动更新数据库"

o = gs:option(ListValue, "auto_update_geoip_time", "更新时间（每天几点）")
for t = 0, 23 do o:value(t, t .. ":00") end
o.default = 3
o:depends("auto_update_geoip", "1")

o = gs:option(Value, "geoip_update_interval", "更新周期（天）")
o.datatype    = "uinteger"
o.default     = 7
o.rmempty     = false
o.description = "例如 7 表示每隔 7 天更新"
o:depends("auto_update_geoip", "1")

o = gs:option(ListValue, "geoip_source", "数据来源")
o:value("2", "默认简化源（推荐）")
o:value("3", "OpenClash 社区源")
o:value("1", "MaxMind 官方")
o:value("4", "自定义订阅")
o.default = "2"

o = gs:option(ListValue, "geoip_format", "GeoIP 格式")
o:value("mmdb", "MMDB（推荐）")
o:value("dat",  "DAT")
o.default     = "mmdb"
o.description = "一般无需更改"

o = gs:option(ListValue, "geodata_loader", "加载模式")
o:value("standard",       "标准")
o:value("memconservative", "节省内存")
o.default     = "standard"
o.description = [[内存受限设备可选"节省内存"]]

o = gs:option(Value, "license_key", "MaxMind 授权密钥")
o.description = "仅 MaxMind 官方来源需要，申请地址：maxmind.com"
o.rmempty     = true
o:depends("geoip_source", "1")

o = gs:option(Value, "geoip_mmdb_url", "GeoIP（MMDB）订阅链接")
o.rmempty     = true
o.placeholder = "https://raw.githubusercontent.com/alecthw/mmdb_china_ip_list/release/Country.mmdb"
o:depends("geoip_source", "2")
o:depends("geoip_source", "4")

o = gs:option(Value, "geosite_url", "GeoSite 订阅链接")
o.rmempty     = true
o.placeholder = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
o:depends("geoip_source", "2")
o:depends("geoip_source", "3")
o:depends("geoip_source", "4")

o = gs:option(Value, "geoip_dat_url", "GeoIP（DAT）订阅链接")
o.rmempty     = true
o.placeholder = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
o:depends("geoip_source", "2")
o:depends("geoip_source", "3")
o:depends("geoip_source", "4")

o = gs:option(Value, "geoip_asn_url", "GeoIP（ASN）订阅链接")
o.rmempty     = true
o.placeholder = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"
o:depends("geoip_source", "2")
o:depends("geoip_source", "4")

o = gs:option(DummyValue, "_geoip_last_update", "上次更新时间")
o.rawhtml  = true
o.cfgvalue = function()
	local t = geoip_update_time():gsub("%s+$", "")
	return "<strong>" .. (t ~= "" and t or "-") .. "</strong>"
end

o = gs:option(Button, "update_geoip", "")
o.inputtitle = "保存配置"
o.inputstyle = "apply"
o.write = function()
	gm.uci:commit("clash")
end

o = gs:option(Button, "download", "")
o.template = "clash/geoip"


-- ── 第二块半：绕过 ────────────────────────────────────────────────
bm = Map("clash")
bm.pageaction = false
bs = bm:section(TypedSection, "clash", "绕过")
bs.anonymous = true
bs.addremove  = false

-- 绕过目标 IP（不代理这些目的地）
o = bs:option(Flag, "bypass_china", "绕过中国大陆 IP")
o.rmempty     = false
o.default     = "0"
o.description = "目标为中国大陆 IP 时直连，不经过代理（需要 /usr/share/clash/china_ip.txt）"

o = bs:option(Button, "_save_bypass", "")
o.inputtitle = "保存"
o.inputstyle = "apply"
o.write = function()
	bm.uci:commit("clash")
end

-- ── 第二块三：局域网访问控制 ──────────────────────────────────────
am2 = Map("clash")
am2.pageaction = false
as2 = am2:section(TypedSection, "clash", "局域网访问控制")
as2.anonymous = true
as2.addremove  = false
as2.description = "控制哪些局域网设备走代理（按来源 IP 过滤）"

o = as2:option(ListValue, "access_control", "控制模式")
o:value("0", "关闭（所有设备走代理）")
o:value("1", "白名单（仅列表中的设备走代理）")
o:value("2", "黑名单（列表中的设备不走代理）")
o.default     = "0"

o = as2:option(DynamicList, "proxy_lan_ips", "白名单设备 IP")
o.datatype    = "ip4addr"
o.rmempty     = true
o.placeholder = "如：192.168.1.100 或 192.168.2.0/24"
o.description = "手动输入要走代理的设备 IP，支持 CIDR"
o:depends("access_control", "1")

o = as2:option(DynamicList, "reject_lan_ips", "黑名单设备 IP")
o.datatype    = "ip4addr"
o.rmempty     = true
o.placeholder = "如：192.168.1.200 或 192.168.3.0/24"
o.description = "手动输入不走代理的设备 IP，支持 CIDR"
o:depends("access_control", "2")

o = as2:option(Button, "_save_ac", "")
o.inputtitle = "保存"
o.inputstyle = "apply"
o.write = function()
	am2.uci:commit("clash")
end

-- ── 第三块：自动化 ────────────────────────────────────────────────
am = Map("clash")
am.pageaction = false
as = am:section(TypedSection, "clash", "自动化任务")
as.anonymous = true
as.addremove  = false

o = as:option(Flag, "auto_update", "自动更新订阅")
o.description = "定时拉取当前使用的订阅配置"

o = as:option(ListValue, "auto_update_time", "更新频率")
o:value("1",  "每小时")
o:value("6",  "每 6 小时")
o:value("12", "每 12 小时")
o:value("24", "每 24 小时")
o.description = "仅更新当前正在使用的配置"

o = as:option(Flag, "auto_clear_log", "自动清理日志")
o.description = "定时清空运行日志文件"

o = as:option(ListValue, "clear_time", "清理频率")
o:value("1",  "每小时")
o:value("6",  "每 6 小时")
o:value("12", "每 12 小时")
o:value("24", "每 24 小时")
o:depends("auto_clear_log", "1")

o = as:option(Button, "_save_auto", "")
o.inputtitle = "保存"
o.inputstyle = "apply"
o.write = function()
	am.uci:commit("clash")
end

-- ── 第四块：运行日志 ──────────────────────────────────────────────
lm = Map("clash")
lm.pageaction = false
ls = lm:section(TypedSection, "clash", "运行日志")
ls.anonymous = true
ls.addremove  = false

log = ls:option(TextValue, "clog")
log.template = "clash/status_log"

o = ls:option(Button, "Download", "")
o.inputtitle = "下载日志文件"
o.inputstyle = "apply"
o.write = function()
	local sPath = "/usr/share/clash/clash.txt"
	local sFile = NXFS.basename(sPath)
	local fd    = nixio.open(sPath, "r")
	if not fd then return end
	HTTP.header("Content-Disposition", 'attachment; filename="' .. sFile .. '"')
	HTTP.prepare_content("application/octet-stream")
	while true do
		local block = fd:read(nixio.const.buffersize)
		if not block or #block == 0 then break end
		HTTP.write(block)
	end
	fd:close()
	HTTP.close()
end

return ku, gm, bm, am2, am, lm
