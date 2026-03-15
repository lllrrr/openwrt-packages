-- Copyright 2019-2020 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the MIT License.

local dsp = require "luci.dispatcher"
local nixio = require "nixio"
local util = require "luci.util"

local m, s, o

local sid = arg[1]

m = Map("sxray", "%s - %s" % { translate("SXray"), translate("Edit Inbound") },
	translatef("Details: %s", "<a href=\"https://www.v2ray.com/en/configuration/overview.html#inboundobject\" target=\"_blank\">InboundObject</a>"))
m.redirect = dsp.build_url("admin/services/sxray/inbounds")

if m.uci:get("sxray", sid) ~= "inbound" then
	luci.http.redirect(m.redirect)
	return
end

local local_ips = { "0.0.0.0", "127.0.0.1", "::" }

for _, v in ipairs(nixio.getifaddrs()) do
	if v.addr and
		(v.family == "inet" or v.family == "inet6") and
		v.name ~= "lo" and
		not util.contains(local_ips, v.addr)
	then
		util.append(local_ips, v.addr)
	end
end

s = m:section(NamedSection, sid, "inbound")
s.anonymous = true
s.addremove = false

o = s:option(Value, "alias", translate("Alias"), translate("Any custom string"))
o.rmempty = false

o = s:option(Value, "listen", translate("Listen"))
for _, v in ipairs(local_ips) do
	o:value(v)
end
o.datatype = "ipaddr"

o = s:option(Value, "port", translate("Port"))
o.rmempty = false
o.datatype = "or(port, portrange)"

local core_type = m.uci:get("sxray", "main", "core_type") or "xray"

o = s:option(ListValue, "protocol", translate("Protocol"))

if core_type == "xray" then
	o:value("dokodemo-door", "Dokodemo-door")
	o:value("http", "HTTP")
	o:value("mtproto", "MTProto")
	o:value("shadowsocks", "Shadowsocks")
	o:value("socks", "Socks")
	o:value("vmess", "VMess")
	o:value("vless", "VLESS")
	o:value("trojan", "Trojan")
else
	o:value("tun", "TUN")
	o:value("tproxy", "TProxy")
	o:value("redirect", "Redirect")
	o:value("dokodemo-door", "Dokodemo-door")
	o:value("socks", "SOCKS")
	o:value("http", "HTTP")
	o:value("mixed", "Mixed (SOCKS+HTTP)")
	o:value("vmess", "VMess")
	o:value("vless", "VLESS")
	o:value("trojan", "Trojan")
	o:value("shadowsocks", "Shadowsocks")
	o:value("shadowsocksr", "ShadowsocksR")
	o:value("naive", "Naive")
	o:value("hysteria", "Hysteria")
	o:value("tuic", "TUIC")
end

-- Settings - Dokodemo-door
o = s:option(Value, "s_dokodemo_door_address", "%s - %s" % { "Dokodemo-door", translate("Address") },
	translate("Address of the destination server."))
o:depends("protocol", "dokodemo-door")
o.datatype = "host"

o = s:option(Value, "s_dokodemo_door_port", "%s - %s" % { "Dokodemo-door", translate("Port") },
	translate("Port of the destination server."))
o:depends("protocol", "dokodemo-door")
o.datatype = "port"

o = s:option(MultiValue, "s_dokodemo_door_network", "%s - %s" % { "Dokodemo-door", translate("Network") },
	translate("If transparent proxy enabled on current inbound, this option will be ignored."))
o:depends("protocol", "dokodemo-door")
o:value("tcp")
o:value("udp")
o.default = "tcp"

o = s:option(Value, "s_dokodemo_door_timeout", "%s - %s" % { "Dokodemo-door", translate("Timeout") },
	translate("Time limit for inbound data(seconds)"))
o:depends("protocol", "dokodemo-door")
o.datatype = "uinteger"
o.placeholder = "300"

o = s:option(Flag, "s_dokodemo_door_follow_redirect", "%s - %s" % { "Dokodemo-door", translate("Follow redirect") },
	translate("If transparent proxy enabled on current inbound, this option will be ignored."))
o:depends("protocol", "dokodemo-door")

o = s:option(Value, "s_dokodemo_door_user_level", "%s - %s" % { "Dokodemo-door", translate("User level") },
	translate("All connections share this level"))
o:depends("protocol", "dokodemo-door")
o.datatype = "uinteger"

-- Settings - HTTP
o = s:option(Value, "s_http_account_user", "%s - %s" % { "HTTP", translate("Account user") })
o:depends("protocol", "http")

o = s:option(Value, "s_http_account_pass", "%s - %s" % { "HTTP", translate("Account password") })
o:depends("protocol", "http")
o.password = true

o = s:option(Flag, "s_http_allow_transparent", "%s - %s" % { "HTTP", translate("Allow transparent") })
o:depends("protocol", "http")

o = s:option(Value, "s_http_timeout", "%s - %s" % { "HTTP", translate("Timeout") },
	translate("Time limit for inbound data(seconds)"))
o:depends("protocol", "http")
o.datatype = "uinteger"
o.placeholder = "300"

o = s:option(Value, "s_http_user_level", "%s - %s" % { "HTTP", translate("User level") },
	translate("All connections share this level"))
o:depends("protocol", "http")
o.datatype = "uinteger"

-- Settings - MTProto
o = s:option(Value, "s_mtproto_user_email", "%s - %s" % { "MTProto", translate("User email") })
o:depends("protocol", "mtproto")

o = s:option(Value, "s_mtproto_user_secret", "%s - %s" % { "MTProto", translate("User secret") })
o:depends("protocol", "mtproto")
o.password = true

o = s:option(Value, "s_mtproto_user_level", "%s - %s" % { "MTProto", translate("User level") },
	translate("All connections share this level"))
o:depends("protocol", "mtproto")
o.datatype = "uinteger"

-- Settings - Shadowsocks
o = s:option(Value, "s_shadowsocks_email", "%s - %s" % { "Shadowsocks", translate("Email") })
o:depends("protocol", "shadowsocks")

o = s:option(ListValue, "s_shadowsocks_method", "%s - %s" % { "Shadowsocks", translate("Method") })
o:depends("protocol", "shadowsocks")
o:value("")
o:value("aes-256-cfb")
o:value("aes-128-cfb")
o:value("chacha20")
o:value("chacha20-ietf")
o:value("aes-256-gcm")
o:value("aes-128-gcm")
o:value("chacha20-poly1305")
o:value("chacha20-ietf-poly1305")

o = s:option(Value, "s_shadowsocks_password", "%s - %s" % { "Shadowsocks", translate("Password") })
o:depends("protocol", "shadowsocks")
o.password = true

o = s:option(Value, "s_shadowsocks_level", "%s - %s" % { "Shadowsocks", translate("User level") })
o:depends("protocol", "shadowsocks")
o.datatype = "uinteger"

o = s:option(Flag, "s_shadowsocks_ota", "%s - %s" % { "Shadowsocks", translate("One Time Auth (OTA)") })
o:depends("protocol", "shadowsocks")

o = s:option(MultiValue, "s_shadowsocks_network", "%s - %s" % { "Shadowsocks", translate("Network") })
o:depends("protocol", "shadowsocks")
o:value("tcp")
o:value("udp")
o.default = "tcp"

-- Settings - Socks
o = s:option(ListValue, "s_socks_auth", "%s - %s" % { "Socks", translate("Auth") })
o:depends("protocol", "socks")
o:value("")
o:value("noauth", translate("No Auth"))
o:value("password", translate("Password"))
o.default = "noauth"

o = s:option(Value, "s_socks_account_user", "%s - %s" % { "Socks", translate("Account user") })
o:depends("s_socks_auth", "password")

o = s:option(Value, "s_socks_account_pass", "%s - %s" % { "Socks", translate("Account password") })
o:depends("s_socks_auth", "password")
o.password = true

o = s:option(Flag, "s_socks_udp", "%s - %s" % { "Socks", translate("UDP") })
o:depends("protocol", "socks")

o = s:option(Value, "s_socks_ip", "%s - %s" % { "Socks", translate("IP") },
	translate("When UDP is enabled, V2Ray needs to know the IP address of current host."))
o:depends("s_socks_udp", "1")
for _, v in ipairs(local_ips) do
	o:value(v)
end
o.datatype = "host"
o.placeholder = "127.0.0.1"

o = s:option(Value, "s_socks_user_level", "%s - %s" % { "Socks", translate("User level") },
	translate("All connections share this level"))
o:depends("protocol", "socks")
o.datatype = "uinteger"

-- Settings - VMess
o = s:option(Value, "s_vmess_client_id", "%s - %s" % { "VMess", translate("Client ID") })
o:depends("protocol", "vmess")

o = s:option(Value, "s_vmess_client_alter_id", "%s - %s" % { "VMess", translate("Client alter ID") })
o:depends("protocol", "vmess")
o.datatype = "and(uinteger, max(65535))"

o = s:option(Value, "s_vmess_client_email", "%s - %s" % { "VMess", translate("Client email") })
o:depends("protocol", "vmess")

o = s:option(Value, "s_vmess_client_user_level", "%s - %s" % { "VMess", translate("Client User level") })
o:depends("protocol", "vmess")
o.datatype = "uinteger"

o = s:option(Value, "s_vmess_default_alter_id", "%s - %s" % { "VMess", translate("Default alter ID") })
o:depends("protocol", "vmess")
o.datatype = "and(uinteger, max(65535))"

o = s:option(Value, "s_vmess_default_user_level", "%s - %s" % { "VMess", translate("Default user level") })
o:depends("protocol", "vmess")
o.datatype = "uinteger"

o = s:option(Value, "s_vmess_detour_to", "%s - %s" % { "VMess", translate("Detour to") },
	translate("Optional feature to suggest client to take a detour. If specified, this inbound will instruct the outbound to use another inbound."))
o:depends("protocol", "vmess")

o = s:option(Flag, "s_vmess_disable_insecure_encryption", "%s - %s" % { "VMess", translate("Disable insecure encryption") })
o:depends("protocol", "vmess")

-- Settings - VLESS
o = s:option(Value, "s_vless_user_id", "%s - %s" % { "VLESS", translate("User ID") })
o:depends("protocol", "vless")

o = s:option(ListValue, "s_vless_flow", "%s - %s" % { "VLESS", translate("Flow") })
o:depends("protocol", "vless")
o:value("")
o:value("none", translate("None"))
o:value("xtls-rprx-vision", "XTLS-RPRX-Vision")
o:value("xtls-rprx-vision-udp443", "XTLS-RPRX-Vision-UDP443")

o = s:option(Value, "s_vless_encryption", "%s - %s" % { "VLESS", translate("Encryption") })
o:depends("protocol", "vless")
o.default = "none"

-- Settings - Trojan
o = s:option(Value, "s_trojan_password", "%s - %s" % { "Trojan", translate("Password") })
o:depends("protocol", "trojan")
o.password = true

-- Settings - ShadowsocksR
o = s:option(Value, "s_ssr_password", "%s - %s" % { "ShadowsocksR", translate("Password") })
o:depends("protocol", "shadowsocksr")
o.password = true

o = s:option(ListValue, "s_ssr_method", "%s - %s" % { "ShadowsocksR", translate("Method") })
o:depends("protocol", "shadowsocksr")
o:value("")
o:value("none")
o:value("table")
o:value("rc4")
o:value("rc4-md5")
o:value("aes-128-cfb")
o:value("aes-192-cfb")
o:value("aes-256-cfb")
o:value("aes-128-ctr")
o:value("aes-192-ctr")
o:value("aes-256-ctr")
o:value("camellia-128-cfb")
o:value("camellia-192-cfb")
o:value("camellia-256-cfb")
o:value("bf-cfb")
o:value("cast5-cfb")
o:value("des-cfb")
o:value("idea-cfb")
o:value("rc2-cfb")
o:value("salsa20")
o:value("chacha20")
o:value("chacha20-ietf")

o = s:option(ListValue, "s_ssr_protocol", "%s - %s" % { "ShadowsocksR", translate("Protocol") })
o:depends("protocol", "shadowsocksr")
o:value("")
o:value("origin")
o:value("verify_deflate")
o:value("auth_sha1_v4")
o:value("auth_aes128_md5")
o:value("auth_aes128_sha1")
o:value("auth_chain_a")
o:value("auth_chain_b")
o:value("auth_chain_c")
o:value("auth_chain_d")
o:value("auth_chain_e")
o:value("auth_chain_f")

o = s:option(Value, "s_ssr_protocol_param", "%s - %s" % { "ShadowsocksR", translate("Protocol param") })
o:depends("protocol", "shadowsocksr")

o = s:option(ListValue, "s_ssr_obfs", "%s - %s" % { "ShadowsocksR", translate("Obfs") })
o:depends("protocol", "shadowsocksr")
o:value("")
o:value("plain")
o:value("http_simple")
o:value("http_post")
o:value("random_head")
o:value("tls1.2_ticket_auth")

o = s:option(Value, "s_ssr_obfs_param", "%s - %s" % { "ShadowsocksR", translate("Obfs param") })
o:depends("protocol", "shadowsocksr")

-- Settings - Naive
o = s:option(Value, "s_naive_username", "%s - %s" % { "Naive", translate("Username") })
o:depends("protocol", "naive")

o = s:option(Value, "s_naive_password", "%s - %s" % { "Naive", translate("Password") })
o:depends("protocol", "naive")
o.password = true

-- Settings - Hysteria
o = s:option(Value, "s_hysteria_auth", "%s - %s" % { "Hysteria", translate("Auth") })
o:depends("protocol", "hysteria")

o = s:option(ListValue, "s_hysteria_protocol", "%s - %s" % { "Hysteria", translate("Protocol") })
o:depends("protocol", "hysteria")
o:value("")
o:value("udp")
o:value("faketcp")
o:value("wechat-video")

o = s:option(Value, "s_hysteria_up_mbps", "%s - %s" % { "Hysteria", translate("Up Mbps") })
o:depends("protocol", "hysteria")
o.datatype = "uinteger"

o = s:option(Value, "s_hysteria_down_mbps", "%s - %s" % { "Hysteria", translate("Down Mbps") })
o:depends("protocol", "hysteria")
o.datatype = "uinteger"

o = s:option(Value, "s_hysteria_obfs", "%s - %s" % { "Hysteria", translate("Obfs") })
o:depends("protocol", "hysteria")

o = s:option(Value, "s_hysteria_alpn", "%s - %s" % { "Hysteria", translate("ALPN") })
o:depends("protocol", "hysteria")

-- Settings - TUIC
o = s:option(Value, "s_tuic_uuid", "%s - %s" % { "TUIC", translate("UUID") })
o:depends("protocol", "tuic")

o = s:option(Value, "s_tuic_password", "%s - %s" % { "TUIC", translate("Password") })
o:depends("protocol", "tuic")
o.password = true

o = s:option(ListValue, "s_tuic_congestion_control", "%s - %s" % { "TUIC", translate("Congestion Control") })
o:depends("protocol", "tuic")
o:value("")
o:value("cubic")
o:value("bbr")
o:value("new_reno")

o = s:option(Flag, "s_tuic_zero_rtt_handshake", "%s - %s" % { "TUIC", translate("0-RTT Handshake") })
o:depends("protocol", "tuic")

-- Settings - TUN
o = s:option(Value, "s_tun_name", "%s - %s" % { "TUN", translate("Name") })
o:depends("protocol", "tun")

o = s:option(Value, "s_tun_mtu", "%s - %s" % { "TUN", translate("MTU") })
o:depends("protocol", "tun")
o.datatype = "uinteger"
o.placeholder = "9000"

o = s:option(DynamicList, "s_tun_address", "%s - %s" % { "TUN", translate("Address") })
o:depends("protocol", "tun")

o = s:option(Value, "s_tun_gateway", "%s - %s" % { "TUN", translate("Gateway") })
o:depends("protocol", "tun")

o = s:option(Flag, "s_tun_auto_route", "%s - %s" % { "TUN", translate("Auto Route") })
o:depends("protocol", "tun")

o = s:option(Flag, "s_tun_strict_route", "%s - %s" % { "TUN", translate("Strict Route") })
o:depends("protocol", "tun")

-- Settings - TProxy
o = s:option(Value, "s_tproxy_tcp_port", "%s - %s" % { "TProxy", translate("TCP Port") })
o:depends("protocol", "tproxy")
o.datatype = "port"

o = s:option(Value, "s_tproxy_udp_port", "%s - %s" % { "TProxy", translate("UDP Port") })
o:depends("protocol", "tproxy")
o.datatype = "port"

-- Settings - Redirect
o = s:option(Value, "s_redirect_tcp_port", "%s - %s" % { "Redirect", translate("TCP Port") })
o:depends("protocol", "redirect")
o.datatype = "port"

-- Settings - Mixed
o = s:option(Value, "s_mixed_account_user", "%s - %s" % { "Mixed", translate("User") })
o:depends("protocol", "mixed")

o = s:option(Value, "s_mixed_account_pass", "%s - %s" % { "Mixed", translate("Password") })
o:depends("protocol", "mixed")
o.password = true

o = s:option(Flag, "s_mixed_udp", "%s - %s" % { "Mixed", translate("UDP") })
o:depends("protocol", "mixed")

-- Stream Settings
o = s:option(ListValue, "ss_network", "%s - %s" % { translate("Stream settings"), translate("Network") })
if core_type == "xray" then
	o:value("")
	o:value("tcp", "TCP")
	o:value("kcp", "mKCP")
	o:value("ws", "WebSocket")
	o:value("http", "HTTP/2")
	o:value("domainsocket", "Domain Socket")
	o:value("quic", "QUIC")
else
	o:value("")
	o:value("tcp", "TCP")
	o:value("ws", "WebSocket")
	o:value("http", "HTTP")
	o:value("h2", "HTTP/2")
	o:value("grpc", "gRPC")
	o:value("httpupgrade", "HTTPUpgrade")
end

o = s:option(ListValue, "ss_security", "%s - %s" % { translate("Stream settings"), translate("Security") })
if core_type == "xray" then
	o:value("")
	o:value("none", translate("None"))
	o:value("tls", "TLS")
else
	o:value("")
	o:value("none", translate("None"))
	o:value("tls", "TLS")
	o:value("utls", "uTLS")
	o:value("reality", "REALITY")
end

-- Stream Settings - TLS
o = s:option(Value, "ss_tls_server_name", "%s - %s" % { "TLS", translate("Server name") })
o:depends("ss_security", "tls")
o.datatype = "host"

o = s:option(Value, "ss_tls_alpn", "%s - %s" % { "TLS", "ALPN" })
o:depends("ss_security", "tls")
o.placeholder = "http/1.1"

o = s:option(Flag, "ss_tls_allow_insecure", "%s - %s" % { "TLS", translate("Allow insecure") })
o:depends("ss_security", "tls")

o = s:option(Flag, "ss_tls_allow_insecure_ciphers", "%s - %s" % { "TLS", translate("Allow insecure ciphers") })
o:depends("ss_security", "tls")

o = s:option(Flag, "ss_tls_disable_system_root", "%s - %s" % { "TLS", translate("Disable system root") })
o:depends("ss_security", "tls")

o = s:option(ListValue, "ss_tls_cert_usage", "%s - %s" % { "TLS", translate("Certificate usage") })
o:depends("ss_security", "tls")
o:value("")
o:value("encipherment")
o:value("verify")
o:value("issue")

o = s:option(Value, "ss_tls_cert_file", "%s - %s" % { "TLS", translate("Certificate file") })
o:depends("ss_security", "tls")

o = s:option(Value, "ss_tls_key_file", "%s - %s" % { "TLS", translate("Key file") })
o:depends("ss_security", "tls")

-- Stream Settings - TCP
o = s:option(ListValue, "ss_tcp_header_type", "%s - %s" % { "TCP", translate("Header type") })
o:depends("ss_network", "tcp")
o:value("")
o:value("none", translate("None"))
o:value("http", "HTTP")

o = s:option(Value, "ss_tcp_header_request_version", "%s - %s" % { "TCP", translate("HTTP request version") })
o:depends("ss_tcp_header_type", "http")
o.placeholder = "1.1"

o = s:option(ListValue, "ss_tcp_header_request_method", "%s - %s" % { "TCP", translate("HTTP request method") })
o:depends("ss_tcp_header_type", "http")
o:value("")
o:value("GET")
o:value("HEAD")
o:value("POST")
o:value("DELETE")
o:value("PUT")
o:value("PATCH")
o:value("OPTIONS")
o.default = "GET"

o = s:option(Value, "ss_tcp_header_request_path", "%s - %s" % { "TCP", translate("Request path") })
o:depends("ss_tcp_header_type", "http")

o = s:option(DynamicList, "ss_tcp_header_request_headers", "%s - %s" % { "TCP", translate("Request headers") },
	translatef("A list of HTTP headers, format: <code>header=value</code>. eg: %s", "Host=www.bing.com"))
o:depends("ss_tcp_header_type", "http")

o = s:option(Value, "ss_tcp_header_response_version", "%s - %s" % { "TCP", translate("HTTP response version") })
o:depends("ss_tcp_header_type", "http")
o.placeholder = "1.1"

o = s:option(Value, "ss_tcp_header_response_status", "%s - %s" % { "TCP", translate("HTTP response status") })
o:depends("ss_tcp_header_type", "http")
o.placeholder = "200"

o = s:option(Value, "ss_tcp_header_response_reason", "%s - %s" % { "TCP", translate("HTTP response reason") })
o:depends("ss_tcp_header_type", "http")
o.placeholder = "OK"

o = s:option(DynamicList, "ss_tcp_header_response_headers", "%s - %s" % { "TCP", translate("Response headers") },
	translatef("A list of HTTP headers, format: <code>header=value</code>. eg: %s", "Host=www.bing.com"))
o:depends("ss_tcp_header_type", "http")

-- Stream Settings - KCP
o = s:option(Value, "ss_kcp_mtu", "%s - %s" % { "mKCP", translate("Maximum transmission unit (MTU)") })
o:depends("ss_network", "kcp")
o.datatype = "and(min(576), max(1460))"
o.placeholder = "1350"

o = s:option(Value, "ss_kcp_tti", "%s - %s" % { "mKCP", translate("Transmission time interval (TTI)") })
o:depends("ss_network", "kcp")
o.datatype = "and(min(10), max(100))"
o.placeholder = "50"

o = s:option(Value, "ss_kcp_uplink_capacity", "%s - %s" % { "mKCP", translate("Uplink capacity") })
o:depends("ss_network", "kcp")
o.datatype = "uinteger"
o.placeholder = "5"

o = s:option(Value, "ss_kcp_downlink_capacity", "%s - %s" % { "mKCP", translate("Downlink capacity") })
o:depends("ss_network", "kcp")
o.datatype = "uinteger"
o.placeholder = "20"

o = s:option(Flag, "ss_kcp_congestion", "%s - %s" % { "mKCP", translate("Congestion enabled") })
o:depends("ss_network", "kcp")

o = s:option(Value, "ss_kcp_read_buffer_size", "%s - %s" % { "mKCP", translate("Read buffer size") })
o:depends("ss_network", "kcp")
o.datatype = "uinteger"
o.placeholder = "2"

o = s:option(Value, "ss_kcp_write_buffer_size", "%s - %s" % { "mKCP", translate("Write buffer size") })
o:depends("ss_network", "kcp")
o.datatype = "uinteger"
o.placeholder = "2"

o = s:option(ListValue, "ss_kcp_header_type", "%s - %s" % { "mKCP", translate("Header type") })
o:depends("ss_network", "kcp")
o:value("")
o:value("none", translate("None"))
o:value("srtp", "SRTP")
o:value("utp", "uTP")
o:value("wechat-video", translate("Wechat Video"))
o:value("dtls", "DTLS 1.2")
o:value("wireguard", "WireGuard")

-- Stream Settings - WebSocket
o = s:option(Value, "ss_websocket_path", "%s - %s" % { "WebSocket", translate("Path") })
o:depends("ss_network", "ws")

o = s:option(DynamicList, "ss_websocket_headers", "%s - %s" % { "WebSocket", translate("Headers") },
	translatef("A list of HTTP headers, format: <code>header=value</code>. eg: %s", "Host=www.bing.com"))
o:depends("ss_network", "ws")

-- Stream Settings - HTTP/2
o = s:option(DynamicList, "ss_http_host", "%s - %s" % { "HTTP/2", translate("Host") })
o:depends("ss_network", "http")

o = s:option(Value, "ss_http_path", "%s - %s" % { "HTTP/2", translate("Path") })
o:depends("ss_network", "http")
o.placeholder = "/"

-- Stream Settings - Domain Socket
o = s:option(Value, "ss_domainsocket_path", "%s - %s" % { "Domain Socket", translate("Path") })
o:depends("ss_network", "domainsocket")

-- Stream Settings - QUIC
o = s:option(ListValue, "ss_quic_security", "%s - %s" % { "QUIC", translate("Security") })
o:depends("ss_network", "quic")
o:value("")
o:value("none", translate("None"))
o:value("aes-128-gcm")
o:value("chacha20-poly1305")

o = s:option(Value, "ss_quic_key", "%s - %s" % { "QUIC", translate("Key") })
o:depends("ss_quic_security", "aes-128-gcm")
o:depends("ss_quic_security", "chacha20-poly1305")

o = s:option(ListValue, "ss_quic_header_type", "%s - %s" % { "QUIC", translate("Header type") })
o:depends("ss_network", "quic")
o:value("")
o:value("none", translate("None"))
o:value("srtp", "SRTP")
o:value("utp", "uTP")
o:value("wechat-video", translate("Wechat Video"))
o:value("dtls", "DTLS 1.2")
o:value("wireguard", "WireGuard")

-- Stream Settings - Socket Options
o = s:option(ListValue, "ss_sockopt_tcp_fast_open", "%s - %s" % { translate("Sockopt"), translate("TCP fast open") })
o:value("")
o:value("0", translate("False"))
o:value("1", translate("True"))

o = s:option(ListValue, "ss_sockopt_tproxy", "%s - %s" % { translate("Sockopt"), translate("TProxy") },
	translate("If transparent proxy enabled on current inbound, this option will be ignored."))
o:value("")
o:value("redirect", "Redirect")
o:value("tproxy", "TProxy")
o:value("off", translate("Off"))

-- Other Settings
o = s:option(Value, "tag", translate("Tag"))

o = s:option(Flag, "sniffing_enabled", "%s - %s" %{ translate("Sniffing"), translate("Enabled") })

o = s:option(MultiValue, "sniffing_dest_override", "%s - %s" % { translate("Sniffing"), translate("Dest override") })
o:value("http")
o:value("tls")

o = s:option(ListValue, "allocate_strategy", "%s - %s" % { translate("Allocate"), translate("Strategy") })
o:value("")
o:value("always")
o:value("random")

o = s:option(Value, "allocate_refresh", "%s - %s" % { translate("Allocate"), translate("Refresh") })
o.datatype = "uinteger"

o = s:option(Value, "allocate_concurrency", "%s - %s" % { translate("Allocate"), translate("Concurrency") })
o.datatype = "uinteger"

return m
