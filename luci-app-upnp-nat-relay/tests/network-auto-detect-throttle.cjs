'use strict';
/* network.js 自动检测节流的行为测试（纯 Node，无需 LuCI/浏览器）：
 *   1. 缓存够新（age < 15s）→ 不自动检测，状态区直接显示结果
 *   2. 缓存过期 / 缺失 / 快照对不上当前配置 → 自动检测一次，返回后原位刷新
 *   3. 手动「检测」按钮不受节流限制，永远强制重测
 */
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'package', 'luci-app-upnp-nat-relay', 'htdocs',
	'luci-static', 'resources', 'view', 'upnp-nat-relay', 'network.js');

const code = fs.readFileSync(SRC, 'utf8').replace(/^'require .*';$/gm, '');

/* ---------- LuCI 桩件 ---------- */
const calls = { checkNetwork: 0 };
let checkNetworkResult = null;

const uciStore = {
	upnp_nat_relay: {
		main: {
			bind_ifname: 'br-lan',
			bind_ip: '192.168.2.1',
			downstream_lan_gateway: '192.168.3.1',
			downstream_lan_subnet: '192.168.3.0/24',
			downstream_wan_ip: '192.168.3.1',
			upstream_wan_if: 'pppoe-wan',
			firewall_zone_name: 'upnp_nat'
		}
	}
};

const uci = {
	load: () => Promise.resolve(),
	get: (cfg, sec, opt) => (uciStore[cfg] && uciStore[cfg][sec] && uciStore[cfg][sec][opt]) || null,
	set: (cfg, sec, opt, val) => {
		uciStore[cfg] = uciStore[cfg] || {};
		uciStore[cfg][sec] = uciStore[cfg][sec] || {};
		uciStore[cfg][sec][opt] = val;
	},
	unset: () => {}
};

const rpc = {
	declare: (spec) => {
		if (spec.method === 'check-network')
			return () => new Promise((resolve) => {
				calls.checkNetwork++;
				setTimeout(() => resolve(checkNetworkResult), 30);
			});
		return () => Promise.resolve(null);
	}
};

const network = {
	getDevices: () => Promise.resolve([]),
	getNetworks: () => Promise.resolve([]),
	getInterfaces: () => Promise.resolve([])
};

const utils = {
	loadSharedCSS: () => {},
	renderWithFooter: (node) => Promise.resolve(node),
	rpcWithRetry: (fn) => fn(),
	getErrorMessage: (e) => (e && e.message) || String(e),
	FOOTER_OPTIONS: {}
};

const ui = {
	addNotification: () => {},
	showModal: () => {},
	hideModal: () => {}
};

const E = (tag, attrs, children) => ({ tag, attrs: attrs || {}, children });
const _ = (s) => s;

const nodes = {};
const captured = [];
const document = {
	getElementById: (id) => nodes[id] || null,
	head: { appendChild: () => {} },
	createElementNS: () => ({ setAttribute: () => {}, appendChild: () => {} }),
	createElement: () => ({ setAttribute: () => {}, appendChild: () => {} })
};
const window = {
	setTimeout: (fn, ms) => setTimeout(fn, ms),
	location: { reload: () => {} }
};

function makeOption(name) {
	const o = {
		name, values: [], rmempty: true,
		depends: () => {},
		cfgvalue: null,
		onchange: null
	};
	o.value = (v, label) => o.values.push({ v, label });
	return o;
}

const form = {
	Map: function () {
		this.sections = [];
		this.section = (cls, type, label) => {
			const s = new form.TypedSection(type, label);
			this.sections.push(s);
			return s;
		};
		this.render = () => {
			/* 模拟 LuCI：把每个 option 的 cfgvalue 结果写进 fake DOM（按 span id 归位） */
			for (const s of this.sections) {
				for (const o of s.allOptions) {
					if (typeof o.cfgvalue !== 'function')
						continue;
					const html = o.cfgvalue('main');
					if (typeof html !== 'string')
						continue;
					const m = html.match(/id="([^"]+)"/);
					if (!m)
						continue;
					nodes[m[1]] = nodes[m[1]] || { innerHTML: '' };
					nodes[m[1]].innerHTML = html;
				}
			}
			return { fake: true };
		};
	},
	TypedSection: function () {
		this.allOptions = [];
		this.tab = () => {};
		this.taboption = (tab, cls, name, title, desc) => {
			const o = makeOption(name);
			this.allOptions.push(o);
			captured.push(o);
			return o;
		};
		this.option = (cls, name, title, desc) => {
			const o = makeOption(name);
			this.allOptions.push(o);
			captured.push(o);
			return o;
		};
	},
	Value: function () {},
	ListValue: function () {},
	Flag: function () {},
	Button: function () {},
	DummyValue: function () {}
};

const view = { extend: (o) => o };
const factory = new Function(
	'view', 'ui', 'rpc', 'uci', 'form', 'network', 'utils', 'E', '_', 'document', 'window', code
);

function payload(age) {
	return {
		cached: 1, age: age,
		updated_at: '2026-11-23 14:20:00', updated_at_epoch: 1795415180,
		bind_ifname: 'br-lan', bind_ip: '192.168.2.1',
		downstream_lan_gateway: '192.168.3.1', downstream_lan_subnet: '192.168.3.0/24',
		downstream_wan_ip: '192.168.3.1', upstream_wan_if: 'pppoe-wan',
		detected_bind_ip: '192.168.2.1', detected_downstream_lan_subnet: '192.168.3.0/24',
		detected_downstream_lan_gateway: '192.168.3.1', detected_downstream_wan_ip: '203.0.113.10',
		detected_upstream_wan_if: 'pppoe-wan',
		iface_exists: 1, bind_ip_configured: 1, gateway_reachable: 1, upnpc_readable: 1,
		upnpc_mapping_count: 15, wan_ip_reachable: 1, upstream_wan_exists: 1,
		default_route_on_bind: 0, bad_forwarding: 0, gateway_set: 0, gateway_value: '',
		dns_set: 0, dns_value: '', zone_name: 'upnp_nat', zone_exists: 1,
		zone_input: 'ACCEPT', zone_output: 'ACCEPT', zone_forward: 'REJECT', zone_masq: '0'
	};
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function statusText(key) {
	const node = nodes['ubr-net-status-' + key];
	return node ? String(node.innerHTML).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() : '(none)';
}

async function scenario(name, cache, expectCalls, expectShown) {
	calls.checkNetwork = 0;
	for (const k of Object.keys(nodes))
		delete nodes[k];
	captured.length = 0;
	checkNetworkResult = payload(0);

	const viewObj = factory(view, ui, rpc, uci, form, network, utils, E, _, document, window);
	const loaded = await viewObj.load.call(viewObj);
	loaded.network = cache;
	await viewObj.render.call(viewObj, loaded);
	await wait(400);

	const callsOk = calls.checkNetwork === expectCalls;
	const shown = statusText('if_status').indexOf('Interface exists') >= 0;
	const valueOk = shown === expectShown;
	const pass = callsOk && valueOk;
	console.log((pass ? 'PASS' : 'FAIL') + ': ' + name +
		'  [检测次数=' + calls.checkNetwork + '/' + expectCalls +
		' 状态=' + JSON.stringify(statusText('if_status')) + ']');
	return pass;
}

/* 手动点「检测」：即使缓存刚测过也要强制重测，且状态区刷新 */
async function manualDetectScenario() {
	calls.checkNetwork = 0;
	for (const k of Object.keys(nodes))
		delete nodes[k];
	captured.length = 0;
	checkNetworkResult = payload(0);
	checkNetworkResult.iface_exists = 0; /* 手动检测后要能看到变化 */

	const viewObj = factory(view, ui, rpc, uci, form, network, utils, E, _, document, window);
	const loaded = await viewObj.load.call(viewObj);
	loaded.network = payload(2); /* 2 秒前刚测过，自动检测会被跳过 */
	await viewObj.render.call(viewObj, loaded);
	await wait(400);

	const before = calls.checkNetwork;
	const btn = captured.filter((o) => o.name === '_check_network')[0];
	if (!btn || typeof btn.onclick !== 'function') {
		console.log('FAIL: 手动检测 — 找不到「检测」按钮');
		return false;
	}
	await btn.onclick.call({ node: { disabled: false, textContent: 'Detect' } });
	await wait(100);

	const pass = before === 0 && calls.checkNetwork === 1 &&
		statusText('if_status').indexOf('Interface not found') >= 0;
	console.log((pass ? 'PASS' : 'FAIL') + ': 手动「检测」不受节流限制，强制重测并刷新' +
		'  [检测次数=' + calls.checkNetwork + '/1 状态=' + JSON.stringify(statusText('if_status')) + ']');
	return pass;
}

(async () => {
	let all = true;

	all = await scenario('缓存 5s：跳过自动检测，直接显示结果', payload(5), 0, true) && all;
	all = await scenario('缓存 600s：自动检测一次并原位刷新', payload(600), 1, true) && all;
	all = await scenario('无缓存：自动检测一次', { cached: 0, updated_at: '' }, 1, true) && all;

	const mismatch = payload(5);
	mismatch.bind_ip = '10.9.9.9';
	all = await scenario('缓存 5s 但快照对不上配置：仍要检测', mismatch, 1, true) && all;
	all = await manualDetectScenario() && all;

	console.log(all ? 'OK: network auto-detect throttle' : 'FAIL: network auto-detect throttle');
	process.exit(all ? 0 : 1);
})();
