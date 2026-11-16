#!/usr/bin/env node
'use strict';

/*
 * Renders the System DNS integration card with a stubbed LuCI environment and
 * asserts what the user sees. The card used to read only the `server` options
 * in UCI, so it displayed "None" on routers where the WAN provides the
 * upstreams through /tmp/resolv.conf.d/resolv.conf.auto. This test pins the
 * visible result of every upstream mode reported by the rpcd backend.
 */

import fs from 'node:fs';

const VIEW_PATH = 'htdocs/luci-static/resources/view/oxidns/overview.js';

// LuCI extends String with a printf-style formatter.
String.prototype.format = function () {
	const args = arguments;
	let index = 0;
	return this.replace(/%[sd]/g, () => args[index++]);
};

function element(tag, attrs, children) {
	return {
		tag: tag,
		attrs: attrs || {},
		children: children === undefined ? [] : [].concat(children)
	};
}

function textOf(node) {
	if (node === null || node === undefined)
		return '';
	if (typeof node === 'string')
		return node;
	if (Array.isArray(node))
		return node.map(textOf).join(' ');
	if (node.children)
		return textOf(node.children);
	return '';
}

const stubs = {
	view: { extend: (view) => view },
	rpc: { declare: () => () => Promise.resolve({}) },
	ui: { showModal() {}, hideModal() {}, addNotification() {} },
	poll: { add() {} },
	L: { resolveDefault: (promise, fallback) => Promise.resolve(fallback) },
	_: (text) => text,
	i18n: { translate: (text) => text, message: () => '' },
	document: { getElementById: () => null },
	window: { location: { href: 'http://router/', hostname: 'router' } },
	URL: URL
};

function loadView() {
	const source = fs.readFileSync(VIEW_PATH, 'utf8');
	const factory = new Function(
		'view', 'rpc', 'ui', 'poll', 'L', '_', 'E', 'i18n', 'document', 'window', 'URL',
		source);

	return factory(
		stubs.view, stubs.rpc, stubs.ui, stubs.poll, stubs.L, stubs._,
		element, stubs.i18n, stubs.document, stubs.window, stubs.URL);
}

function renderDnsSection(view, dns) {
	const tree = view.render({ status: {}, dns: dns });

	for (const section of tree.children || []) {
		const text = textOf(section);
		if (text.indexOf('System DNS integration') !== -1)
			return text.replace(/\s+/g, ' ').trim();
	}

	throw new Error('the DNS integration section is missing from the rendered view');
}

const BASE = {
	ok: true,
	supported: true,
	dnsmasq_running: true,
	service_running: true,
	managed: false,
	can_enable: true,
	can_disable: false,
	target: '127.0.0.1#5335',
	port: '5335',
	listener_active: true,
	forward: '127.0.0.1#5335',
	forward_present: false,
	generic_servers: [],
	domain_servers: [],
	previous_servers: [],
	auto_servers: [],
	auto_source: '',
	auto_active: false,
	upstream_mode: 'none',
	noresolv: '',
	noresolv_set: false,
	message: '',
	warning: ''
};

const CASES = [
	{
		name: 'upstreams come from the resolv file only',
		dns: Object.assign({}, BASE, {
			auto_servers: ['223.5.5.5', '119.29.29.29'],
			auto_source: '/tmp/resolv.conf.d/resolv.conf.auto',
			auto_active: true,
			upstream_mode: 'auto'
		}),
		expect: [
			'223.5.5.5, 119.29.29.29',
			'from /tmp/resolv.conf.d/resolv.conf.auto, added by the WAN connection, not stored in UCI'
		]
	},
	{
		name: 'explicit and resolv-file upstreams are merged',
		dns: Object.assign({}, BASE, {
			generic_servers: ['1.1.1.1'],
			auto_servers: ['223.5.5.5'],
			auto_source: '/tmp/resolv.conf.d/resolv.conf.auto',
			auto_active: true,
			upstream_mode: 'mixed'
		}),
		expect: ['1.1.1.1, 223.5.5.5']
	},
	{
		name: 'noresolv suppresses the resolv file',
		dns: Object.assign({}, BASE, {
			noresolv: '1',
			noresolv_set: true
		}),
		expect: [
			'resolv file ignored because noresolv is set',
			'None (all domains use the upstreams above)'
		]
	},
	{
		name: 'an enabled integration reports the managed forward',
		dns: Object.assign({}, BASE, {
			managed: true,
			can_enable: false,
			can_disable: true,
			forward_present: true,
			generic_servers: ['127.0.0.1#5335'],
			domain_servers: ['/example.com/8.8.8.8'],
			previous_servers: ['1.1.1.1', '9.9.9.9'],
			upstream_mode: 'managed',
			noresolv: '1',
			noresolv_set: true
		}),
		expect: [
			'127.0.0.1#5335',
			'all queries are forwarded to OxiDNS; before enabling: 1.1.1.1, 9.9.9.9',
			'/example.com/8.8.8.8'
		]
	},
	{
		name: 'dnsmasq is unavailable',
		dns: { ok: true, supported: false, message: 'dnsmasq is not available' },
		expect: ['Unavailable', 'dnsmasq is not available'],
		// The failing card must not claim an upstream it could not read.
		forbid: ['223.5.5.5']
	}
];

const view = loadView();
const failures = [];

for (const testCase of CASES) {
	let text;
	try {
		text = renderDnsSection(view, testCase.dns);
	}
	catch (error) {
		failures.push(`${testCase.name}: ${error.message}`);
		continue;
	}

	for (const needle of testCase.expect || []) {
		if (text.indexOf(needle) === -1)
			failures.push(`${testCase.name}: missing ${JSON.stringify(needle)} in "${text}"`);
	}
	for (const needle of testCase.forbid || []) {
		if (text.indexOf(needle) !== -1)
			failures.push(`${testCase.name}: unexpected ${JSON.stringify(needle)} in "${text}"`);
	}
}

if (failures.length) {
	console.error(failures.join('\n'));
	process.exit(1);
}

console.log(`DNS card render checks passed (${CASES.length} cases)`);
