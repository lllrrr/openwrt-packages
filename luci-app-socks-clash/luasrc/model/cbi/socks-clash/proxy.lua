local m, s, o

m = Map("socks-clash", "代理端口设置",
    "配置 SOCKS5、HTTP 和混合代理端口。")

s = m:section(TypedSection, "socks-clash", "SOCKS5 代理")
s.anonymous = true
s.addremove = false

-- SOCKS5 Enable
o = s:option(Flag, "socks_enabled", "启用 SOCKS5 代理")
o.default = "1"

-- SOCKS5 Port
o = s:option(Value, "socks_port", "SOCKS5 端口")
o.datatype = "port"
o.default = "7891"
o:depends("socks_enabled", "1")

s = m:section(TypedSection, "socks-clash", "HTTP 代理")
s.anonymous = true
s.addremove = false

-- HTTP Enable
o = s:option(Flag, "http_enabled", "启用 HTTP 代理")
o.default = "1"

-- HTTP Port
o = s:option(Value, "http_port", "HTTP 端口")
o.datatype = "port"
o.default = "7890"
o:depends("http_enabled", "1")

s = m:section(TypedSection, "socks-clash", "混合代理 (SOCKS5 + HTTP)")
s.anonymous = true
s.addremove = false

-- Mixed Enable
o = s:option(Flag, "mixed_enabled", "启用混合代理")
o.default = "0"
o.description = "混合端口在同一端口上支持 SOCKS5 和 HTTP 两种协议"

-- Mixed Port
o = s:option(Value, "mixed_port", "混合端口")
o.datatype = "port"
o.default = "7893"
o:depends("mixed_enabled", "1")

s = m:section(TypedSection, "socks-clash", "使用说明")
s.anonymous = true
s.addremove = false
s.template = "socks-clash/proxy_usage"

return m
