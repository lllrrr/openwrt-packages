local _ = luci.i18n.translate

local m, s

m = Map("ota", _("OTA 升级设置"), _("配置 GitHub API 地址及下载优化选项。"))

s = m:section(NamedSection, "settings", "ota", _("基础设置"))
s.anonymous = true

-- GitHub API 地址
s:option(Value, "url", _("GitHub API 地址"))

-- GitHub Token
t = s:option(Value, "github_token", _("GitHub Token (选填)"))
t.password = true

-- 备份插件开关
s:option(Flag, "backup_plugins", _("升级后自动重装插件"))

-- 下载加速开关
p = s:option(Flag, "download_proxy", _("使用 GitHub 下载加速"))
p.default = "0"

-- 自定义加速地址 (依赖于 p 的勾选)
cp = s:option(Value, "custom_proxy_url", _("自定义加速地址"), _("例如: https://mirror.ghproxy.com/ (必须以 / 结尾)"))
cp:depends("download_proxy", "1")
cp.placeholder = "https://mirror.ghproxy.com/"

return m