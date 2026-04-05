-- luci-app-clawpanel — CBI basic model
-- 实际 UI 全部移到了 view/clawpanel/main.htm，此文件仅保留最小 CBI 框架
m = Map("clawpanel", "ClawPanel",
	"ClawPanel 智能管理面板 — 统一目录 /Configs，Node.js 系统级安装")

m.pageaction = false

s = m:section(SimpleSection)
s.template = "clawpanel/basic"

return m
