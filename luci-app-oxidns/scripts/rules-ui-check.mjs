// 规则页 UI 结构断言：标签条必须是原生 cbi-tabmenu、元信息必须压成一行且 4 个 id 都在。
//
// 这些是「UX 约定」而不是功能，但它们坏掉是静默的：标签条退回自绘 inline style 也能跑，
// 元信息 id 丢一个也只是那样信息不再更新（setTextValue 找不到节点直接 return）。
// 只截取 ruleTabs / applyMissingStyle / ruleMetaLine 三个纯函数，注入 E() 桩。
//
//   node scripts/rules-ui-check.mjs            # 用仓库内的 rules.js
//   node scripts/rules-ui-check.mjs <file>     # 指到副本（缺陷注入时用）

import fs from 'fs';
import { fileURLToPath } from 'url';

const DEFAULT_SRC = fileURLToPath(new URL('../htdocs/luci-static/resources/view/oxidns/rules.js', import.meta.url));
const SRC = process.argv[2] || DEFAULT_SRC;
const src = fs.readFileSync(SRC, 'utf8');

function pick(name) {
	const start = src.indexOf(`function ${name}(`);
	if (start < 0) throw new Error(`找不到 ${name}()`);
	return src.slice(start, src.indexOf('\n}\n', start) + 3);
}

const code = [ 'applyMissingStyle', 'ruleTabs', 'ruleMetaLine' ].map(pick).join('\n')
	+ '\nreturn { ruleTabs, ruleMetaLine };\n';

/* 极简 E()：属性原样保留，children 平铺，支持 appendChild / addEventListener */
function E(tag, attrs, children) {
	const node = {
		tag: tag,
		attrs: attrs || {},
		children: [],
		style: {},
		appendChild(c) { this.children.push(c); },
		addEventListener(ev, fn) { (this.handlers = this.handlers || {})[ev] = fn; }
	};
	if (children !== undefined) {
		/* LuCI 的 E() 对数组 children 是逐个 append，不是整块塞进去 */
		if (Array.isArray(children))
			children.forEach((c) => node.children.push(c));
		else
			node.children.push(children);
	}
	return node;
}

const _ = (s) => s;
const handleFileChange = () => {};

const factory = new Function('E', '_', 'handleFileChange', 'formatBytes', 'formatCount', 'formatTime', code);
const api = factory(E, _, handleFileChange, (b) => b + 'B', (n) => n + 'L', (m) => m + 'T');

let failed = 0;
const ok = (m) => console.log('  ok   ' + m);
const bad = (m, d) => { failed++; console.log('  FAIL ' + m + (d ? '  <- ' + d : '')); };
const expect = (m, a, e) => (a === e ? ok(m) : bad(m, `got [${a}] want [${e}]`));

const files = [
	{ name: 'whitelist.txt', label: 'Whitelist', exists: true, path: '/etc/oxidns/rule/whitelist.txt' },
	{ name: 'blocklist.txt', label: 'Blacklist', exists: true, path: '/etc/oxidns/rule/blocklist.txt' },
	{ name: 'hosts.txt', label: 'hosts', exists: false, path: '/etc/oxidns/rule/hosts.txt' }
];

// ① 标签条：原生 cbi-tabmenu，激活项 cbi-tab，其余 cbi-tab-disabled
{
	const bar = api.ruleTabs(files, 'whitelist.txt');
	expect('标签条是 ul', bar.tag, 'ul');
	expect('标签条 class 为 cbi-tabmenu', bar.attrs.class, 'cbi-tabmenu');
	expect('标签条不再写内联 style', bar.attrs.style, undefined);
	expect('标签数量与文件数一致', bar.children.length, 3);
	expect('激活项 class 为 cbi-tab', bar.children[0].attrs.class, 'cbi-tab');
	expect('非激活项 class 为 cbi-tab-disabled', bar.children[1].attrs.class, 'cbi-tab-disabled');
	expect('每项都绑定了 click', typeof bar.children[0].handlers.click, 'function');
	expect('缺文件项标记斜体', bar.children[2].style.fontStyle, 'italic');
	expect('正常项不带斜体', bar.children[0].style.fontStyle, '');
}

// ② 元信息行：一行 div，含 4 个 id
{
	const line = api.ruleMetaLine({ name: 'whitelist.txt', exists: true, size: 12, lines: 3, mtime: 100 }, 'whitelist.txt', false);
	expect('元信息是 div', line.tag, 'div');
	const ids = [];
	line.children.forEach((grp) => grp.children.forEach((c) => { if (c.attrs && c.attrs.id) ids.push(c.attrs.id); }));
	[ 'oxidns-rules-current', 'oxidns-rules-file-size', 'oxidns-rules-file-lines', 'oxidns-rules-file-mtime' ]
		.forEach((id) => expect(`元信息含 ${id}`, ids.indexOf(id) >= 0, true));
	expect('元信息只有一行（4 个 span）', line.children.length, 4);
}

// ③ 加载失败时元信息不炸，全部显示 '-'
{
	const line = api.ruleMetaLine(null, 'whitelist.txt', true);
	const values = line.children.map((grp) => grp.children[1].children[0]);
	expect('加载失败时值全为 -', values.join(','), '-,-,-,-');
}

console.log(failed ? `\n${failed} 条断言失败` : '\n全部通过');
process.exit(failed ? 1 : 0);
