-- Copyright 2019-2020 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the MIT License.

local dsp = require "luci.dispatcher"
local nixio = require "nixio"
local util = require "luci.util"

local m, s, o

local sid = arg[1]

m = Map("sxray", "%s - %s" % { translate("SXray"), translate("Edit Outbound") },
	translatef("Details: %s", "<a href=\"https://www.v2ray.com/en/configuration/overview.html#outboundobject\" target=\"_blank\">OutboundObject</a>"))
m.redirect = dsp.build_url("admin/services/sxray/outbounds")

if m.uci:get("sxray", sid) ~= "outbound" then
	luci.http.redirect(m.redirect)
	return
end

local local_ips = { "0.0.0.0", "::" }

for _, v in ipairs(nixio.getifaddrs()) do
	if v.addr and
		(v.family == "inet" or v.family == "inet6") and
		v.name ~= "lo" and
		not util.contains(local_ips, v.addr)
	then
		util.append(local_ips, v.addr)
	end
end

s = m:section(NamedSection, sid, "outbound")
s.anonymous = true
s.addremove = false

o = s:option(Value, "alias", translate("Alias"), translate("Any custom string"))
o.rmempty = false

o = s:option(Value, "send_through", translate("Send through"), translate("An IP address for sending traffic out."))
o.datatype = "ipaddr"
for _, v in ipairs(local_ips) do
	o:value(v)
end

local core_type = m.uci:get("sxray", "main", "core_type") or "xray"

o = s:option(ListValue, "protocol", translate("Protocol"))

if core_type == "xray" then
	o:value("blackhole", "Blackhole")
	o:value("dns", "DNS")
	o:value("freedom", "Freedom")
	o:value("http", "HTTP/2")
	o:value("mtproto", "MTProto")
	o:value("shadowsocks", "Shadowsocks")
	o:value("socks", "Socks")
	o:value("vmess", "VMess")
	o:value("vless", "VLESS")
	o:value("trojan", "Trojan")
else
	o:value("direct", "Direct")
	o:value("block", "Block")
	o:value("dns", "DNS")
	o:value("socks", "SOCKS")
	o:value("http", "HTTP")
	o:value("vmess", "VMess")
	o:value("vless", "VLESS")
	o:value("trojan", "Trojan")
	o:value("shadowsocks", "Shadowsocks")
	o:value("shadowsocksr", "ShadowsocksR")
	o:value("naive", "Naive")
	o:value("hysteria", "Hysteria")
	o:value("hysteria2", "Hysteria2")
	o:value("tuic", "TUIC")
	o:value("juicity", "Juicity")
	o:value("wireguard", "WireGuard")
end

-- Settings Blackhole
o = s:option(ListValue, "s_blackhole_reponse_type", "%s - %s" % { "Blackhole", translate("Response type") } )
o:depends("protocol", "blackhole")
o:value("")
o:value("none", translate("None"))
o:value("http", "HTTP")

-- Settings DNS
o = s:option(ListValue, "s_dns_network", "%s - %s" % { "DNS", translate("Network") } )
o:depends("protocol", "dns")
o:value("")
o:value("tcp", "TCP")
o:value("udp", "UDP")

o = s:option(Value, "s_dns_address", "%s - %s" % { "DNS", translate("Address") } )
o:depends("protocol", "dns")

o = s:option(Value, "s_dns_port", "%s - %s" % { "DNS", translate("Port") } )
o:depends("protocol", "dns")
o.datatype = "port"

-- Settings Freedom
o = s:option(ListValue, "s_freedom_domain_strategy", "%s - %s" % { "Freedom", translate("Domain strategy") } )
o:depends("protocol", "freedom")
o:value("")
o:value("AsIs")
o:value("UseIP")
o:value("UseIPv4")
o:value("UseIPv6")

o = s:option(Value, "s_freedom_redirect", "%s - %s" % { "Freedom", translate("Redirect") } )
o:depends("protocol", "freedom")

o = s:option(Value, "s_freedom_user_level", "%s - %s" % { "Freedom", translate("User level") } )
o:depends("protocol", "freedom")
o.datatype = "uinteger"

-- Settings - HTTP
o = s:option(Value, "s_http_server_address", "%s - %s" % { "HTTP", translate("Server address") } )
o:depends("protocol", "http")
o.datatype = "host"

o = s:option(Value, "s_http_server_port", "%s - %s" % { "HTTP", translate("Server port") } )
o:depends("protocol", "http")
o.datatype = "port"

o = s:option(Value, "s_http_account_user", "%s - %s" % { "HTTP", translate("User") } )
o:depends("protocol", "http")

o = s:option(Value, "s_http_account_pass", "%s - %s" % { "HTTP", translate("Password") } )
o:depends("protocol", "http")
o.password = true

-- Settings - Shadowsocks
o = s:option(Value, "s_shadowsocks_email", "%s - %s" % { "Shadowsocks", translate("Email") } )
o:depends("protocol", "shadowsocks")

o = s:option(Value, "s_shadowsocks_address", "%s - %s" % { "Shadowsocks", translate("Address") } )
o:depends("protocol", "shadowsocks")
o.datatype = "host"

o = s:option(Value, "s_shadowsocks_port", "%s - %s" % { "Shadowsocks", translate("Port") } )
o:depends("protocol", "shadowsocks")
o.datatype = "port"

o = s:option(ListValue, "s_shadowsocks_method", "%s - %s" % { "Shadowsocks", translate("Method") } )
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

o = s:option(Flag, "s_shadowsocks_ota", "%s - %s" % { "Shadowsocks", translate("OTA") })
o:depends("protocol", "shadowsocks")

-- Settings - Socks
o = s:option(Value, "s_socks_server_address", "%s - %s" % { "Socks", translate("Server address") })
o:depends("protocol", "socks")
o.datatype = "host"

o = s:option(Value, "s_socks_server_port", "%s - %s" % { "Socks", translate("Server port") })
o:depends("protocol", "socks")
o.datatype = "port"

o = s:option(Value, "s_socks_account_user", "%s - %s" % { "Socks", translate("User") })
o:depends("protocol", "socks")

o = s:option(Value, "s_socks_account_pass", "%s - %s" % { "Socks", translate("Password") })
o:depends("protocol", "socks")
o.password = true

o = s:option(Value, "s_socks_user_level", "%s - %s" % { "Socks", translate("User level") })
o:depends("protocol", "socks")
o.datatype = "uinteger"

-- Settings - VMess
o = s:option(Value, "s_vmess_address", "%s - %s" % { "VMess", translate("Address") })
o:depends("protocol", "vmess")
o.datatype = "host"

o = s:option(Value, "s_vmess_port", "%s - %s" % { "VMess", translate("Port") })
o:depends("protocol", "vmess")
o.datatype = "port"

o = s:option(Value, "s_vmess_user_id", "%s - %s" % { "VMess", translate("User ID") })
o:depends("protocol", "vmess")

o = s:option(Value, "s_vmess_user_alter_id", "%s - %s" % { "VMess", translate("Alter ID") })
o:depends("protocol", "vmess")
o.datatype = "and(uinteger, max(65535))"

o = s:option(ListValue, "s_vmess_user_security", "%s - %s" % { "VMess", translate("Security") })
o:depends("protocol", "vmess")
o:value("")
o:value("auto", translate("Auto"))
o:value("aes-128-gcm")
o:value("chacha20-poly1305")
o:value("none", translate("None"))

o = s:option(Value, "s_vmess_user_level", "%s - %s" % { "VMess", translate("User level") })
o:depends("protocol", "vmess")
o.datatype = "uinteger"

-- Settings - VLESS
o = s:option(Value, "s_vless_address", "%s - %s" % { "VLESS", translate("Address") })
o:depends("protocol", "vless")
o.datatype = "host"

o = s:option(Value, "s_vless_port", "%s - %s" % { "VLESS", translate("Port") })
o:depends("protocol", "vless")
o.datatype = "port"

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
o = s:option(Value, "s_trojan_address", "%s - %s" % { "Trojan", translate("Address") })
o:depends("protocol", "trojan")
o.datatype = "host"

o = s:option(Value, "s_trojan_port", "%s - %s" % { "Trojan", translate("Port") })
o:depends("protocol", "trojan")
o.datatype = "port"

o = s:option(Value, "s_trojan_password", "%s - %s" % { "Trojan", translate("Password") })
o:depends("protocol", "trojan")
o.password = true

-- Settings - ShadowsocksR
o = s:option(Value, "s_ssr_address", "%s - %s" % { "ShadowsocksR", translate("Address") })
o:depends("protocol", "shadowsocksr")
o.datatype = "host"

o = s:option(Value, "s_ssr_port", "%s - %s" % { "ShadowsocksR", translate("Port") })
o:depends("protocol", "shadowsocksr")
o.datatype = "port"

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
o = s:option(Value, "s_naive_address", "%s - %s" % { "Naive", translate("Address") })
o:depends("protocol", "naive")
o.datatype = "host"

o = s:option(Value, "s_naive_port", "%s - %s" % { "Naive", translate("Port") })
o:depends("protocol", "naive")
o.datatype = "port"

o = s:option(Value, "s_naive_username", "%s - %s" % { "Naive", translate("Username") })
o:depends("protocol", "naive")

o = s:option(Value, "s_naive_password", "%s - %s" % { "Naive", translate("Password") })
o:depends("protocol", "naive")
o.password = true

-- Settings - Hysteria
o = s:option(Value, "s_hysteria_address", "%s - %s" % { "Hysteria", translate("Address") })
o:depends("protocol", "hysteria")
o.datatype = "host"

o = s:option(Value, "s_hysteria_port", "%s - %s" % { "Hysteria", translate("Port") })
o:depends("protocol", "hysteria")
o.datatype = "port"

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

-- Settings - Hysteria2
o = s:option(Value, "s_hysteria2_address", "%s - %s" % { "Hysteria2", translate("Address") })
o:depends("protocol", "hysteria2")
o.datatype = "host"

o = s:option(Value, "s_hysteria2_port", "%s - %s" % { "Hysteria2", translate("Port") })
o:depends("protocol", "hysteria2")
o.datatype = "port"

o = s:option(Value, "s_hysteria2_password", "%s - %s" % { "Hysteria2", translate("Password") })
o:depends("protocol", "hysteria2")
o.password = true

o = s:option(Value, "s_hysteria2_obfs_password", "%s - %s" % { "Hysteria2", translate("Obfs Password") })
o:depends("protocol", "hysteria2")
o.password = true

o = s:option(Value, "s_hysteria2_up_mbps", "%s - %s" % { "Hysteria2", translate("Up Mbps") })
o:depends("protocol", "hysteria2")
o.datatype = "uinteger"

o = s:option(Value, "s_hysteria2_down_mbps", "%s - %s" % { "Hysteria2", translate("Down Mbps") })
o:depends("protocol", "hysteria2")
o.datatype = "uinteger"

-- Settings - TUIC
o = s:option(Value, "s_tuic_address", "%s - %s" % { "TUIC", translate("Address") })
o:depends("protocol", "tuic")
o.datatype = "host"

o = s:option(Value, "s_tuic_port", "%s - %s" % { "TUIC", translate("Port") })
o:depends("protocol", "tuic")
o.datatype = "port"

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

o = s:option(Value, "s_tuic_udp_relay_mode", "%s - %s" % { "TUIC", translate("UDP Relay Mode") })
o:depends("protocol", "tuic")

o = s:option(Flag, "s_tuic_zero_rtt_handshake", "%s - %s" % { "TUIC", translate("0-RTT Handshake") })
o:depends("protocol", "tuic")

-- Settings - Juicity
o = s:option(Value, "s_juicity_address", "%s - %s" % { "Juicity", translate("Address") })
o:depends("protocol", "juicity")
o.datatype = "host"

o = s:option(Value, "s_juicity_port", "%s - %s" % { "Juicity", translate("Port") })
o:depends("protocol", "juicity")
o.datatype = "port"

o = s:option(Value, "s_juicity_uuid", "%s - %s" % { "Juicity", translate("UUID") })
o:depends("protocol", "juicity")

o = s:option(Value, "s_juicity_password", "%s - %s" % { "Juicity", translate("Password") })
o:depends("protocol", "juicity")
o.password = true

o = s:option(ListValue, "s_juicity_congestion_control", "%s - %s" % { "Juicity", translate("Congestion Control") })
o:depends("protocol", "juicity")
o:value("")
o:value("bbr")
o:value("cubic")
o:value("new_reno")

-- Settings - WireGuard
o = s:option(Value, "s_wireguard_secret_key", "%s - %s" % { "WireGuard", translate("Secret Key") })
o:depends("protocol", "wireguard")
o.password = true

o = s:option(Value, "s_wireguard_peer_public_key", "%s - %s" % { "WireGuard", translate("Peer Public Key") })
o:depends("protocol", "wireguard")

o = s:option(Value, "s_wireguard_endpoint", "%s - %s" % { "WireGuard", translate("Endpoint") })
o:depends("protocol", "wireguard")

o = s:option(DynamicList, "s_wireguard_address", "%s - %s" % { "WireGuard", translate("Address") })
o:depends("protocol", "wireguard")

o = s:option(Value, "s_wireguard_mtu", "%s - %s" % { "WireGuard", translate("MTU") })
o:depends("protocol", "wireguard")
o.datatype = "uinteger"
o.placeholder = "1420"

o = s:option(Flag, "s_wireguard_preshared_key", "%s - %s" % { "WireGuard", translate("Preshared Key") })
o:depends("protocol", "wireguard")
o.password = true

o = s:option(Value, "s_wireguard_keepalive", "%s - %s" % { "WireGuard", translate("Keepalive") })
o:depends("protocol", "wireguard")
o.datatype = "uinteger"

o = s:option(DynamicList, "s_wireguard_reserved", "%s - %s" % { "WireGuard", translate("Reserved") })
o:depends("protocol", "wireguard")

-- Settings - Direct (Sing-Box)
o = s:option(ListValue, "s_direct_domain_strategy", "%s - %s" % { "Direct", translate("Domain strategy") })
o:depends("protocol", "direct")
o:value("")
o:value("AsIs")
o:value("UseIP")
o:value("UseIPv4")
o:value("UseIPv6")

-- Settings - Block (Sing-Box)
o = s:option(ListValue, "s_block_type", "%s - %s" % { "Block", translate("Type") })
o:depends("protocol", "block")
o:value("")
o:value("default", translate("Default"))
o:value("dns", "DNS")

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
	o:value("udp", "UDP")
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

o = s:option(Value, "ss_tcp_header_request_path", "%s - %s" % { "TCP", translate("Request path") })
o:depends("ss_tcp_header_type", "http")

o = s:option(DynamicList, "ss_tcp_header_request_headers", "%s - %s" % { "TCP", translate("Request headers") },
	translatef("A list of HTTP headers, format: <code>header=value</code>. eg: %s", "Host=www.bing.com"))
o:depends("ss_tcp_header_type", "http")

o = s:option(Value, "ss_tcp_header_response_version", "%s - %s" % { "TCP", translate("HTTP response version") })
o:depends("ss_tcp_header_type", "http")

o = s:option(Value, "ss_tcp_header_response_status", "%s - %s" % { "TCP", translate("HTTP response status") })
o:depends("ss_tcp_header_type", "http")

o = s:option(Value, "ss_tcp_header_response_reason", "%s - %s" % { "TCP", translate("HTTP response reason") })
o:depends("ss_tcp_header_type", "http")

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
o = s:option(Value, "ss_sockopt_mark", "%s - %s" % { translate("Sockopt"), translate("Mark") },
	translate("If transparent proxy is enabled, this option is ignored and will be set to 255."))
o.placeholder = "255"

o = s:option(ListValue, "ss_sockopt_tcp_fast_open", "%s - %s" % { translate("Sockopt"), translate("TCP fast open") })
o:value("")
o:value("0", translate("False"))
o:value("1", translate("True"))

-- Other Settings
o = s:option(Value, "tag", translate("Tag"))

o = s:option(Value, "proxy_settings_tag", "%s - %s" % { translate("Proxy settings"), translate("Tag") })

o = s:option(Flag, "mux_enabled", "%s - %s" % { translate("Mux"), translate("Enabled") })

o = s:option(Value, "mux_concurrency", "%s - %s" % { translate("Mux"), translate("Concurrency") })
o.datatype = "uinteger"
o.placeholder = "8"

return m
