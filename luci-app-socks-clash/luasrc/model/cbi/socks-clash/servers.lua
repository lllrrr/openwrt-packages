local m, s, o
local sys = require "luci.sys"
local nixio = require "nixio"

m = Map("socks-clash", "服务器管理",
    "手动添加和管理代理服务器节点。支持多种协议：Shadowsocks、VMess、VLESS、Trojan、Hysteria、TUIC等。")

-- Server List
s = m:section(TypedSection, "servers", "服务器列表")
s.anonymous = true
s.addremove = true
s.sortable = true
s.template = "cbi/tblsection"

o = s:option(Flag, "enabled", "启用")
o.default = "1"
o.rmempty = false
o.width = "5%"

o = s:option(Value, "alias", "别名")
o.rmempty = false
o.placeholder = "节点名称"
o.width = "20%"

o = s:option(ListValue, "type", "类型")
o:value("ss", "Shadowsocks")
o:value("vmess", "VMess")
o:value("vless", "VLESS")
o:value("trojan", "Trojan")
o:value("hysteria", "Hysteria")
o:value("hysteria2", "Hysteria2")
o:value("tuic", "TUIC")
o.default = "ss"
o.width = "10%"

o = s:option(Value, "server", "服务器地址")
o.rmempty = false
o.placeholder = "example.com"
o.width = "20%"

o = s:option(Value, "port", "端口")
o.rmempty = false
o.datatype = "port"
o.placeholder = "443"
o.width = "8%"

o = s:option(DummyValue, "delay", "延迟")
o.width = "8%"
o.rawhtml = true
o.value = function(self, section)
    local delay_file = "/tmp/socks-clash_delay_" .. section
    if nixio.fs.access(delay_file) then
        local delay = nixio.fs.readfile(delay_file):gsub("%s+", "")
        if delay == "0" or delay == "" then
            return "<span style='color:red;'>超时</span>"
        else
            local delay_num = tonumber(delay)
            if delay_num < 150 then
                return string.format("<span style='color:#22c55e;'>%sms</span>", delay)
            elseif delay_num < 400 then
                return string.format("<span style='color:#f59e0b;'>%sms</span>", delay)
            else
                return string.format("<span style='color:#ef4444;'>%sms</span>", delay)
            end
        end
    else
        return "<span style='color:#64748b;'>未测试</span>"
    end
end

o = s:option(Button, "_test", "测速")
o.inputtitle = "测试"
o.inputstyle = "apply"
o.write = function(self, section)
    sys.call("sh /usr/share/socks-clash/test_proxy.sh " .. section .. " &")
end
o.width = "8%"

-- Edit Server Details
s = m:section(NamedSection, "servers", "servers", "服务器详细配置")
s.addremove = false
s.anonymous = true

-- Common Settings
o = s:option(Value, "alias", "别名")
o.rmempty = false
o.placeholder = "节点名称，如：香港 01"

o = s:option(ListValue, "type", "协议类型")
o:value("ss", "Shadowsocks")
o:value("vmess", "VMess")
o:value("vless", "VLESS")
o:value("trojan", "Trojan")
o:value("hysteria", "Hysteria")
o:value("hysteria2", "Hysteria2")
o:value("tuic", "TUIC")
o.default = "ss"

o = s:option(Value, "server", "服务器地址")
o.rmempty = false
o.placeholder = "example.com 或 IP 地址"

o = s:option(Value, "port", "端口")
o.rmempty = false
o.datatype = "port"
o.placeholder = "443"

-- Shadowsocks Settings
o = s:option(ListValue, "cipher", "加密方式")
o:value("aes-128-gcm", "aes-128-gcm")
o:value("aes-192-gcm", "aes-192-gcm")
o:value("aes-256-gcm", "aes-256-gcm")
o:value("chacha20-ietf-poly1305", "chacha20-ietf-poly1305")
o:value("xchacha20-ietf-poly1305", "xchacha20-ietf-poly1305")
o:value("2022-blake3-aes-128-gcm", "2022-blake3-aes-128-gcm")
o:value("2022-blake3-aes-256-gcm", "2022-blake3-aes-256-gcm")
o.default = "aes-256-gcm"
o:depends("type", "ss")

o = s:option(Value, "password", "密码")
o.password = true
o.rmempty = false
o:depends("type", "ss")
o:depends("type", "trojan")

-- VMess/VLESS Settings
o = s:option(Value, "uuid", "UUID")
o.rmempty = false
o.placeholder = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
o:depends("type", "vmess")
o:depends("type", "vless")

o = s:option(Value, "alterId", "Alter ID")
o.datatype = "uinteger"
o.default = "0"
o:depends("type", "vmess")

o = s:option(ListValue, "cipher_vmess", "加密方式")
o:value("auto", "auto")
o:value("aes-128-gcm", "aes-128-gcm")
o:value("chacha20-poly1305", "chacha20-poly1305")
o:value("none", "none")
o.default = "auto"
o:depends("type", "vmess")

-- Network Settings
o = s:option(ListValue, "network", "传输协议")
o:value("tcp", "TCP")
o:value("ws", "WebSocket")
o:value("h2", "HTTP/2")
o:value("grpc", "gRPC")
o.default = "tcp"
o:depends("type", "vmess")
o:depends("type", "vless")
o:depends("type", "trojan")

o = s:option(Value, "ws_path", "WebSocket Path")
o.placeholder = "/path"
o:depends("network", "ws")

o = s:option(Value, "ws_host", "WebSocket Host")
o.placeholder = "example.com"
o:depends("network", "ws")

-- TLS Settings
o = s:option(Flag, "tls", "启用 TLS")
o.default = "0"
o:depends("type", "vmess")
o:depends("type", "vless")
o:depends("type", "trojan")

o = s:option(Value, "sni", "SNI")
o.placeholder = "example.com"
o:depends("tls", "1")

o = s:option(Flag, "skip_cert_verify", "跳过证书验证")
o.default = "0"
o:depends("tls", "1")

-- UDP Settings
o = s:option(Flag, "udp", "启用 UDP")
o.default = "1"

-- Actions
s = m:section(TypedSection, "socks-clash", "批量操作")
s.anonymous = true
s.addremove = false

o = s:option(Button, "test_all", "测试所有节点")
o.inputtitle = "批量测速"
o.inputstyle = "apply"
o.write = function()
    sys.call("sh /usr/share/socks-clash/test_all_proxies.sh &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "socks-clash", "servers"))
end

o = s:option(Button, "clear_delays", "清除延迟数据")
o.inputtitle = "清除"
o.inputstyle = "reset"
o.write = function()
    sys.call("rm -f /tmp/socks-clash_delay_* 2>/dev/null")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "socks-clash", "servers"))
end

return m
