#!/usr/bin/ucode
// SPDX-License-Identifier: GPL-2.0-only
//
// Copyright (C) 2024 OpenWrt.org
//
// Reads UCI config 'singbox-server' and writes a sing-box inbound
// JSON configuration to /var/run/singbox-server/sing-box-s.json.

'use strict';

import { writefile, mkdirp } from 'fs';

const CONF     = 'singbox-server';
const HP_DIR   = '/etc/singbox-server';
const RUN_DIR  = '/var/run/singbox-server';
const OUT_FILE = RUN_DIR + '/sing-box-s.json';

// ─── UCI helpers ────────────────────────────────────────────────────────────
const uci = require('uci').cursor();
uci.load(CONF);

function get(section, key, def) {
	const v = uci.get(CONF, section, key);
	return (v != null) ? v : (def !== undefined ? def : null);
}

function bool(section, key, def) {
	return get(section, key, def ? '1' : '0') === '1';
}

function num(section, key, def) {
	const v = get(section, key, null);
	return (v != null) ? +v : (def !== undefined ? +def : null);
}

// ─── Transport builder ───────────────────────────────────────────────────────
function build_transport(s) {
	const type = get(s, 'transport', 'none');
	if (!type || type === 'none') return null;

	const t = { type };

	switch (type) {
	case 'ws': {
		const path = get(s, 'ws_path', '/');
		const host = get(s, 'ws_host');
		if (path)                  t.path = path;
		if (host)                  t.headers = { Host: host };
		const early = bool(s, 'ws_early_data');
		if (early) {
			t.max_early_data       = num(s, 'ws_early_data_header_name') ? 2048 : 2048;
			t.early_data_header_name = get(s, 'ws_early_data_header_name', 'Sec-WebSocket-Protocol');
		}
		break;
	}
	case 'grpc':
		t.service_name = get(s, 'grpc_service_name', 'GunService');
		break;
	case 'http': {
		const path = get(s, 'http_path', '/');
		const host = get(s, 'http_host');
		if (path) t.path = path;
		if (host) t.host = [ host ];
		break;
	}
	case 'httpupgrade': {
		const path = get(s, 'httpupgrade_path', '/');
		const host = get(s, 'httpupgrade_host');
		if (path) t.path = path;
		if (host) t.host = host;
		break;
	}
	}
	return t;
}

// ─── Multiplex builder ───────────────────────────────────────────────────────
function build_multiplex(s) {
	if (!bool(s, 'multiplex')) return null;

	const mux = { enabled: true };
	const padding = bool(s, 'multiplex_padding');
	if (padding) mux.padding = true;

	if (bool(s, 'multiplex_brutal')) {
		mux.brutal = {
			enabled   : true,
			up_mbps   : num(s, 'multiplex_brutal_up', 100),
			down_mbps : num(s, 'multiplex_brutal_down', 100)
		};
	}
	return mux;
}

// ─── TLS builder ─────────────────────────────────────────────────────────────
function build_tls(s) {
	if (!bool(s, 'tls')) return null;

	const tls = { enabled: true };

	const reality  = bool(s, 'tls_reality');
	const acme     = bool(s, 'tls_acme');
	const ech      = bool(s, 'tls_ech');

	const sni = get(s, 'tls_sni');
	if (sni) tls.server_name = sni;

	// ALPN
	const alpn_raw = get(s, 'tls_alpn');
	if (alpn_raw) tls.alpn = split(alpn_raw, ',');

	if (reality) {
		// ── VLESS Reality ──────────────────────────────────────────────────
		tls.reality = {
			enabled  : true,
			handshake: {
				server      : get(s, 'tls_reality_handshake_server', 'google.com'),
				server_port : num(s, 'tls_reality_handshake_port', 443)
			},
			private_key : get(s, 'tls_reality_private_key'),
			short_id    : filter(
				map(split(get(s, 'tls_reality_short_id', '') || '', ','), trim),
				v => length(v) > 0
			)
		};
		if (bool(s, 'tls_reality_max_time_difference')) {
			tls.reality.max_time_difference = get(s, 'tls_reality_max_time_difference_value', '60s');
		}

	} else if (acme) {
		// ── ACME auto certificate ──────────────────────────────────────────
		const domains_raw = get(s, 'tls_acme_domain');
		const acme_obj = {
			domain            : filter(map(split(domains_raw || '', ','), trim), v => length(v) > 0),
			data_directory    : HP_DIR + '/certs/acme',
			default_server_name: split(domains_raw || '', ',')[0]
		};

		const email = get(s, 'tls_acme_email');
		if (email) acme_obj.email = email;

		const provider = get(s, 'tls_acme_provider', 'letsencrypt');
		if (provider && provider !== 'letsencrypt')
			acme_obj.provider = provider;

		if (bool(s, 'tls_acme_disable_http_challenge'))
			acme_obj.disable_http_challenge = true;

		const http_port = num(s, 'tls_acme_http01_port');
		if (http_port) acme_obj.alternative_http_port = http_port;

		const alpn_port = num(s, 'tls_acme_tlsalpn01_port');
		if (alpn_port) acme_obj.alternative_tls_port = alpn_port;

		// DNS-01 challenge
		const dns_provider = get(s, 'tls_acme_dns_provider');
		if (dns_provider) {
			acme_obj.dns01_challenge = {
				provider       : dns_provider,
				access_key_id  : get(s, 'tls_acme_dns_access_key_id'),
				access_key_secret: get(s, 'tls_acme_dns_access_key_secret')
			};
		}

		// EAB
		const eab_kid = get(s, 'tls_acme_eab_kid');
		const eab_key = get(s, 'tls_acme_eab_hmac_key');
		if (eab_kid && eab_key) {
			acme_obj.external_account = { key_id: eab_kid, mac_key: eab_key };
		}

		tls.acme = acme_obj;

	} else {
		// ── Manual certificate ─────────────────────────────────────────────
		const cert = get(s, 'tls_cert_path');
		const key  = get(s, 'tls_key_path');
		if (cert) tls.certificate_path = cert;
		if (key)  tls.key_path          = key;
	}

	// ECH
	if (ech) {
		tls.ech = {
			enabled     : true,
			pq_signature_schemes_enabled: bool(s, 'tls_ech_pq_signature_schemes'),
			dynamic_record_sizing_disabled: false
		};
		const ech_key = get(s, 'tls_ech_key');
		const ech_cfg  = get(s, 'tls_ech_config');
		if (ech_key) tls.ech.key = [ ech_key ];
		if (ech_cfg) tls.ech.config = [ ech_cfg ];
	}

	return tls;
}

// ─── Per-protocol inbound builder ────────────────────────────────────────────
function build_inbound(s) {
	const type    = get(s, 'type');
	const label   = get(s, 'label', s);
	const listen  = get(s, 'address', '::');
	const port    = num(s, 'port', 0);

	if (!type || !port) return null;

	const inbound = {
		type        : type,
		tag         : 'inbound-' + label,
		listen      : listen,
		listen_port : port
	};

	// Optional: tcp_fast_open / udp_fragment
	if (bool(s, 'tcp_fast_open'))    inbound.tcp_fast_open    = true;
	if (bool(s, 'tcp_multi_path'))   inbound.tcp_multi_path   = true;
	if (bool(s, 'udp_fragment'))     inbound.udp_fragment     = true;

	const sniff = bool(s, 'sniff');
	if (sniff) {
		inbound.sniff = true;
		if (bool(s, 'sniff_override_destination'))
			inbound.sniff_override_destination = true;
	}

	switch (type) {

	// ── simple auth protocols ──────────────────────────────────────────
	case 'mixed':
	case 'http':
	case 'socks': {
		const user = get(s, 'username');
		const pass = get(s, 'password');
		if (user && pass) inbound.users = [{ username: user, password: pass }];
		if (type === 'http' && bool(s, 'http_set_system_proxy'))
			inbound.set_system_proxy = true;
		break;
	}

	// ── Shadowsocks ───────────────────────────────────────────────────
	case 'shadowsocks': {
		const method = get(s, 'shadowsocks_encrypt_method', 'aes-128-gcm');
		const pass   = get(s, 'password');
		inbound.method   = method;
		inbound.password = pass;

		const net = get(s, 'network');
		if (net && net !== 'tcp_and_udp') inbound.network = net;
		break;
	}

	// ── Trojan ────────────────────────────────────────────────────────
	case 'trojan': {
		const pass = get(s, 'password');
		if (pass) inbound.users = [{ password: pass }];
		break;
	}

	// ── VLESS ────────────────────────────────────────────────────────
	case 'vless': {
		const uuid = get(s, 'uuid');
		const flow = get(s, 'vless_flow');
		const user = { uuid };
		if (flow) user.flow = flow;
		inbound.users = [ user ];
		break;
	}

	// ── VMess ────────────────────────────────────────────────────────
	case 'vmess': {
		const uuid = get(s, 'uuid');
		if (uuid) inbound.users = [{ uuid }];
		break;
	}

	// ── Hysteria v1 ───────────────────────────────────────────────────
	case 'hysteria': {
		const pass = get(s, 'password');
		const up   = num(s, 'hysteria_up_mbps', 100);
		const down = num(s, 'hysteria_down_mbps', 100);
		if (up)   inbound.up_mbps   = up;
		if (down) inbound.down_mbps = down;
		if (pass) inbound.users = [{ auth_str: pass }];

		const recv_window_conn = num(s, 'hysteria_recv_window_conn');
		const recv_window_client = num(s, 'hysteria_recv_window_client');
		if (recv_window_conn)   inbound.recv_window_conn   = recv_window_conn;
		if (recv_window_client) inbound.recv_window_client = recv_window_client;

		if (bool(s, 'hysteria_disable_mtu_discovery'))
			inbound.disable_mtu_discovery = true;
		break;
	}

	// ── Hysteria2 ────────────────────────────────────────────────────
	case 'hysteria2': {
		const pass     = get(s, 'password');
		const up_raw   = get(s, 'hysteria2_up_mbps');
		const down_raw = get(s, 'hysteria2_down_mbps');

		if (pass) inbound.users = [{ password: pass }];

		if (up_raw || down_raw) {
			inbound.up_mbps   = up_raw   ? +up_raw   : null;
			inbound.down_mbps = down_raw ? +down_raw : null;
		}

		if (bool(s, 'hysteria2_ignore_client_bandwidth'))
			inbound.ignore_client_bandwidth = true;

		if (bool(s, 'hysteria2_brutal_debug'))
			inbound.brutal_debug = true;
		break;
	}

	// ── TUIC v5 ──────────────────────────────────────────────────────
	case 'tuic': {
		const uuid = get(s, 'uuid');
		const pass = get(s, 'password');
		const cc   = get(s, 'tuic_congestion_control', 'cubic');
		if (uuid && pass) inbound.users = [{ uuid, password: pass }];
		inbound.congestion_control = cc;

		if (bool(s, 'tuic_zero_rtt_handshake'))
			inbound.zero_rtt_handshake = true;
		const heartbeat = get(s, 'tuic_heartbeat');
		if (heartbeat) inbound.heartbeat = heartbeat;
		break;
	}

	// ── NaïveProxy ───────────────────────────────────────────────────
	case 'naive': {
		const user = get(s, 'username');
		const pass = get(s, 'password');
		if (user && pass) inbound.users = [{ username: user, password: pass }];

		const net = get(s, 'network');
		if (net && net !== 'tcp_and_udp') inbound.network = net;
		break;
	}

	// ── AnyTLS ──────────────────────────────────────────────────────
	case 'anytls': {
		const pass = get(s, 'password');
		if (pass) inbound.users = [{ password: pass }];

		const idle_session_check = get(s, 'anytls_idle_session_check_interval', '30s');
		if (idle_session_check) inbound.idle_session_check_interval = idle_session_check;

		const idle_session_timeout = get(s, 'anytls_idle_session_timeout', '30s');
		if (idle_session_timeout) inbound.idle_session_timeout = idle_session_timeout;

		const min_idle = num(s, 'anytls_min_idle_session', 0);
		if (min_idle) inbound.min_idle_session = min_idle;
		break;
	}
	}

	// Transport
	const transport = build_transport(s);
	if (transport) inbound.transport = transport;

	// Multiplex
	const multiplex = build_multiplex(s);
	if (multiplex) inbound.multiplex = multiplex;

	// TLS
	const tls = build_tls(s);
	if (tls) inbound.tls = tls;

	return inbound;
}

// ─── Main ────────────────────────────────────────────────────────────────────
const log_level = get('config', 'log_level', 'warn');

const config = {
	log: {
		disabled  : log_level === 'disable',
		level     : log_level !== 'disable' ? log_level : null,
		output    : RUN_DIR + '/sing-box-s.log',
		timestamp : true
	},
	inbounds  : [],
	outbounds : [
		{ type: 'direct', tag: 'direct' },
		{ type: 'block',  tag: 'block'  }
	]
};

uci.foreach(CONF, 'server', (server) => {
	const name = server['.name'];
	if (!name) return;

	if (!bool(name, 'enabled')) return;

	const inbound = build_inbound(name);
	if (inbound) push(config.inbounds, inbound);
	else warn('singbox-server: skipping invalid server section: ' + name + '\n');
});

if (length(config.inbounds) === 0) {
	warn('singbox-server: no enabled server inbounds found – aborting.\n');
	exit(1);
}

mkdirp(RUN_DIR);

const json = sprintf('%J', config);   // sing-box requires valid JSON
if (!writefile(OUT_FILE, json)) {
	warn('singbox-server: failed to write ' + OUT_FILE + '\n');
	exit(1);
}

print('singbox-server: config written to ' + OUT_FILE + '\n');
exit(0);
