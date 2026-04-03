-- luci-app-clawpanel — 基本设置 CBI Model
-- 所有 UI 移到了 view/clawpanel/basic.htm，彻底避免 Lua 字符串转义问题
m = Map("clawpanel", "ClawPanel AI 管理面板",
	"ClawPanel 是一个 OpenClaw 智能管理面板，支持进程管理、通道配置等功能。")

m.pageaction = false

-- 直接渲染 HTML 模板，不做任何字符串拼接
s = m:section(SimpleSection)
s.template = "clawpanel/basic"

return m
