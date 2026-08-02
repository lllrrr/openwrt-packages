local http = luci.http

m = Map("easytier", translate("EasyTier Status"))
m.description = translate("A simple, secure, decentralized VPN solution for intranet penetration, implemented in Rust using the Tokio framework. ")
m.pageaction = false

-- 状态卡片
m:section(SimpleSection).template = "easytier/easytier_status"

-- 连接信息卡片
m:section(SimpleSection).template = "easytier/easytier_cli"

return m
