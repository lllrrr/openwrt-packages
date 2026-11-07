#!/usr/bin/env node
/*
 * 合并页面的渲染契约：真跑 settings.js + coresection.js，检查输出的 DOM 树。
 *
 * 结构检查只能证明"文件里写了什么"，这里证明"渲染出来是什么"：
 *   - 内核区块必须排在设置区块之前；
 *   - 内核六行状态、动作按钮、设置表单的每个输入框都在；
 *   - 内核模块必须返回构造函数（LuCI 的 compileClass 要求），普通对象会抛
 *     "factory yields invalid constructor"。
 *
 *   node scripts/page-merge-render.mjs
 */

import fs from 'fs';
import path from 'path';
import vm from 'vm';
import { fileURLToPath } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const VIEW = path.resolve(HERE, '../htdocs/luci-static/resources/view/oxidns');

const failures = [];

/* ------------------------------------------------------------ DOM 桩 */

function E(tag, attrs, children) {
	const node = {
		tag,
		attrs: attrs || {},
		children: [],
		addEventListener() {},
		appendChild(c) { this.children.push(c); },
		removeChild(c) {
			const i = this.children.indexOf(c);
			if (i >= 0) this.children.splice(i, 1);
		},
		get firstChild() { return this.children[0] || null; },
		get textContent() {
			return this.children.map((c) => (typeof c === 'string' ? c : c.textContent || '')).join('');
		},
		set textContent(v) { this.children = [ String(v) ]; },
		get nodeType() { return 1; },
		classList: { add() {}, remove() {}, toggle() {} }
	};

	if (typeof children === 'string')
		node.children.push(children);
	else if (Array.isArray(children))
		children.forEach((c) => c != null && node.children.push(c));
	else if (children)
		node.children.push(children);

	return node;
}

/* --------------------------------------------------------- 视图加载器 */

function loadView(file, extra) {
	const sandbox = {
		E,
		_: (s) => s,
		L: {
			resolveDefault: (p) => Promise.resolve(p),
			env: {},
			url: (p) => '/' + p
		},
		ui: { addNotification() {}, addTimeLimitedNotification() {}, showModal() {}, hideModal() {} },
		rpc: { declare: () => () => Promise.resolve({}) },
		view: { extend: (o) => o },
		/* LuCI 的 baseclass.extend 返回构造函数，成员同时挂在函数上 */
		baseclass: { extend: (proto) => Object.assign(function() {}, proto) },
		Promise,
		window: { setTimeout: () => 0, setInterval: () => 0, clearInterval() {}, location: { reload() {} }, innerHeight: 900 },
		document: { getElementById: () => null, createElement: () => E('div'), body: {} },
		console,
		...extra
	};

	sandbox.globalThis = sandbox;

	const src = fs.readFileSync(path.join(VIEW, file), 'utf8');

	/* String.prototype.format 是 LuCI 扩展的，真实浏览器里有，这里补上 */
	const polyfill = 'String.prototype.format = function() { var a = arguments, i = 0; '
		+ 'return this.replace(/%[sd]/g, function() { return String(a[i++]); }); };\n';

	/* LuCI 用 new Function 包一层，模块顶层才允许 return；这里照做 */
	return vm.runInNewContext('(function(){\n' + polyfill + src + '\n})()', sandbox, { filename: file });
}

const coresection = loadView('coresection.js', {});

if (typeof coresection !== 'function')
	failures.push('coresection.js 没有返回构造函数（LuCI 会抛 factory yields invalid constructor）');

const view = loadView('settings.js', { coresection: coresection });

/* ------------------------------------------------------------- 工具 */

function walk(node, fn) {
	if (typeof node === 'string') { fn(node); return; }
	if (!node || typeof node !== 'object') return;
	fn(node);
	(node.children || []).forEach((c) => walk(c, fn));
}

function find(node, pred) {
	let hit = null;
	walk(node, (n) => { if (!hit && pred(n)) hit = n; });
	return hit;
}

function ids(node) {
	const out = [];
	walk(node, (n) => { if (n.attrs && n.attrs.id) out.push(n.attrs.id); });
	return out;
}

function texts(node) {
	const out = [];
	walk(node, (n) => { if (typeof n === 'string') out.push(n); });
	return out.join(' ');
}

/* --------------------------------------------------------------- 渲染 */

const data = {
	settings: {
		core_repository: 'openwrt-oxidns',
		core_bundle: 'full',
		config_path: '/etc/oxidns/config.yaml',
		working_dir: '/var/lib/oxidns',
		download_proxy: '',
		download_proxy_set: false,
		github_token_set: false
	},
	status: {
		core: { installed: true, version: '1.6.1-r5', bundle: 'full', target: 'x86_64', binary_path: '/usr/bin/oxidns' },
		service_status: { running: true },
		config_path: '/etc/oxidns/config.yaml',
		working_dir: '/var/lib/oxidns'
	}
};

const tree = view.render(data);
const allIds = ids(tree);
const bodyText = texts(tree);

/* 1) 关键 id 必须齐全 */
const required = [
	'oxidns-core-section', 'oxidns-core-installed', 'oxidns-core-version',
	'oxidns-core-bundle', 'oxidns-core-target', 'oxidns-core-binary',
	'oxidns-core-service', 'oxidns-core-actions',
	'oxidns-settings-section', 'oxidns-settings-status',
	'oxidns-setting-core-repository', 'oxidns-setting-core-bundle',
	'oxidns-setting-config-path', 'oxidns-setting-working-dir',
	'oxidns-setting-download-proxy', 'oxidns-setting-github-token'
];

for (const id of required) {
	if (!allIds.includes(id))
		failures.push(`渲染结果缺少 id: ${id}`);
}

/* 2) 内核区块必须排在设置区块之前 */
const iCore = allIds.indexOf('oxidns-core-section');
const iSet = allIds.indexOf('oxidns-settings-section');

if (iCore >= 0 && iSet >= 0 && iCore > iSet)
	failures.push('内核区块排在设置区块之后（期望先内核、后设置）');

/* 3) 两侧的按钮都在 */
for (const label of [ 'Update Core', 'Repair Reinstall', 'Upload Core', 'Remove Core', 'Save Settings' ]) {
	if (!bodyText.includes(label))
		failures.push(`缺少按钮: ${label}`);
}

/* 4) 设置表单确实带上了读回来的值 */
const repoInput = find(tree, (n) => n.attrs && n.attrs.id === 'oxidns-setting-core-repository');

if (!repoInput || repoInput.attrs.value !== 'openwrt-oxidns')
	failures.push('设置表单没有带上 core_repository 的当前值');

/* 5) 未装内核时只给安装入口 */
const missing = view.render({
	settings: {},
	status: { core: { installed: false }, service_status: { running: false } }
});
const missingText = texts(missing);

if (!missingText.includes('Install Core'))
	failures.push('未装内核时缺少 Install Core 按钮');

if (missingText.includes('Update Core'))
	failures.push('未装内核时不该出现 Update Core');

/* ------------------------------------------------------------- 输出 */

console.log('内核/设置页面渲染检查');

if (failures.length) {
	for (const f of failures)
		console.log('  FAIL ' + f);
	console.log(`\n${failures.length} 条失败`);
	process.exit(1);
}

console.log(`  ok   两个区块顺序正确，${required.length} 个关键 id 齐全`);
console.log('  ok   已装/未装两种状态下的按钮与表单取值都正确');
console.log('\n全部通过');
