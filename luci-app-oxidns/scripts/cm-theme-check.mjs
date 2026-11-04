#!/usr/bin/env node
/*
 * CodeMirror 主题契约检查。
 *
 * 主题是"看起来如何"的东西，坏掉不会报错 —— 少一条规则只是那个 token 退回
 * 继承色，深色主题下可能正好等于背景色，字就消失了。所以把它钉成可断言的东西：
 *
 *   1. cmeditor.js 确实加载了 cmtheme.css、且排在 codemirror.min.css 之后
 *   2. theme 选项与 CSS 里的 .cm-s-<name> 对得上
 *   3. 语法模式用到的每个 token 都有配色（yaml / shell）
 *   4. 每个 token 的对比度达标：浅色 ≥ 4.5，深色 ≥ 4.5（WCAG AA 正文）
 *   5. preferDark() 对典型背景色判断正确
 *
 *   node scripts/cm-theme-check.mjs              # 检查本包
 *   node scripts/cm-theme-check.mjs <pkg-root>   # 检查另一个包（如 mihomo）
 */

import fs from 'fs';
import path from 'path';
import vm from 'vm';
import { fileURLToPath } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = process.argv[2] ? path.resolve(process.argv[2]) : path.resolve(HERE, '..');

const failures = [];
const notes = [];
const ok = (msg) => notes.push('  ok   ' + msg);
const bad = (msg) => failures.push(msg);

/* ---------------------------------------------------------------- 工具 */

function read(p) {
	return fs.readFileSync(p, 'utf8');
}

/* sRGB 相对亮度（WCAG 2.1） */
function luminance(hex) {
	const h = hex.replace('#', '');
	const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
	const [r, g, b] = [0, 2, 4].map((i) => parseInt(full.slice(i, i + 2), 16) / 255)
		.map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));

	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a, b) {
	const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m);
	return (x + 0.05) / (y + 0.05);
}

/* 拆 CSS 块，返回 [{ selectors, body }] */
function blocks(css) {
	return css.replace(/\/\*[\s\S]*?\*\//g, '')
		.split('}')
		.map((chunk) => {
			const i = chunk.indexOf('{');
			return i < 0 ? null : { selectors: chunk.slice(0, i), body: chunk.slice(i + 1) };
		})
		.filter(Boolean);
}

/* 从一组选择器里抽出 .cm-xxx 并在 body 里找 color */
function tokenColors(css, dark) {
	const out = {};

	for (const b of blocks(css)) {
		const sel = b.selectors;
		if (!sel.includes('.cm-s-lucicode'))
			continue;
		/* 深色块靠 .cm-dark 区分 */
		if (Boolean(sel.includes('.cm-dark')) !== dark)
			continue;

		const color = /(?:^|[;\s])color:\s*(#[0-9a-fA-F]{3,8})/.exec(b.body);
		if (!color)
			continue;

		for (const m of sel.matchAll(/\.cm-(?!s-)([a-z0-9-]+)/g))
			out[m[1]] = color[1];
	}

	return out;
}

/* ------------------------------------------------------- 1. 资源与主题接线 */

const viewDir = path.join(ROOT, 'htdocs/luci-static/resources/view');
const resDir = fs.existsSync(path.join(ROOT, 'htdocs/luci-static/resources/oxidns-codemirror'))
	? path.join(ROOT, 'htdocs/luci-static/resources/oxidns-codemirror')
	: path.join(ROOT, 'htdocs/luci-static/resources/mihomo-codemirror');

const cmJs = fs.existsSync(path.join(viewDir, 'oxidns/cmeditor.js'))
	? path.join(viewDir, 'oxidns/cmeditor.js')
	: path.join(viewDir, 'mihomo/cmeditor.js');

const cssPath = path.join(resDir, 'cmtheme.css');

if (!fs.existsSync(cssPath))
	bad(`缺少 ${path.relative(ROOT, cssPath)}`);
if (!fs.existsSync(cmJs))
	bad(`缺少 ${path.relative(ROOT, cmJs)}`);

const cmSrc = fs.existsSync(cmJs) ? read(cmJs) : '';
const css = fs.existsSync(cssPath) ? read(cssPath) : '';

/* STYLES 数组里 cmtheme.css 必须存在且排在 codemirror.min.css 之后 */
const stylesMatch = /var STYLES = \[([^\]]*)\]/.exec(cmSrc);
if (!stylesMatch) {
	bad('cmeditor.js: 找不到 STYLES');
}
else {
	const list = [...stylesMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
	const iBase = list.indexOf('codemirror.min.css');
	const iTheme = list.indexOf('cmtheme.css');

	if (iBase < 0) bad('cmeditor.js: STYLES 里没有 codemirror.min.css');
	if (iTheme < 0) bad('cmeditor.js: STYLES 里没有 cmtheme.css —— 主题不会被加载');
	else if (iBase >= 0 && iTheme < iBase)
		bad('cmeditor.js: cmtheme.css 排在 codemirror.min.css 之前，会被默认主题盖掉');
	else ok(`STYLES 顺序正确 [${list.join(', ')}]`);
}

/* theme 选项与 CSS 类名一致 */
const themeConst = /var THEME = '([^']+)'/.exec(cmSrc);
if (!themeConst)
	bad("cmeditor.js: 缺少 THEME 常量");
else {
	if (!cmSrc.includes('theme: THEME'))
		bad('cmeditor.js: fromTextArea 没传 theme: THEME');

	if (!css.includes(`.cm-s-${themeConst[1]}`))
		bad(`cmtheme.css: 没有 .cm-s-${themeConst[1]} 规则，与 THEME='${themeConst[1]}' 不匹配`);
	else
		ok(`主题名对齐：cm-s-${themeConst[1]}`);
}

if (!/classList\.(add|toggle)\('cm-dark'/.test(cmSrc))
	bad('cmeditor.js: 没有深色分支（preferDark → cm-dark）');

/*
 * 静态资源必须带版本参数。
 * LuCI 的模块 URL 只带 luci-base 的 ?v=，应用更新不会改变它，浏览器
 * （尤其 Firefox）会继续用缓存里的旧 cmtheme.css —— 面板上就是"改了没反应"。
 */
if (!/var ASSET_VERSION = '[^']+'/.test(cmSrc))
	bad('cmeditor.js: 缺少 ASSET_VERSION，静态资源无法破缓存');

else {
	for (const [ what, re ] of [
		[ 'link.href', /link\.href = BASE \+ name \+ '\?v=' \+ ASSET_VERSION/ ],
		[ 'script.src', /script\.src = BASE \+ name \+ '\?v=' \+ ASSET_VERSION/ ]
	]) {
		if (!re.test(cmSrc))
			bad(`cmeditor.js: ${what} 没带 ASSET_VERSION`);
	}

	if (!failures.length)
		ok('静态资源已带版本参数（ASSET_VERSION）');
}

/*
 * 行的 <pre> 必须被显式接管。
 *
 * 包里打包的 codemirror.min.css 不是原版 —— 它把
 *   .CodeMirror pre.CodeMirror-line { font-family: Arial,monospace; font-size: 15px; line-height: 1.25 }
 * 写死了：正文 15px 比例字体、行号 12.5px、行距退回 18.75px（2.15 失效）。
 * 覆盖时必须用「同元素复合」选择器（.cm-s-x.CodeMirror），写成后代
 * （.cm-s-x .CodeMirror）永远匹配不到 —— 这个坑已经踩过一次。
 */
if (!css.includes('.cm-s-lucicode.CodeMirror pre.CodeMirror-line'))
	bad('cmtheme.css: 缺少 .cm-s-lucicode.CodeMirror pre.CodeMirror-line（同元素复合）覆盖规则');

if (css.includes('.cm-s-lucicode .CodeMirror pre.CodeMirror-line'))
	bad('cmtheme.css: 用了后代选择器 .cm-s-lucicode .CodeMirror pre…，永远匹配不到，需同元素复合');

{
	const rule = /\.cm-s-lucicode\.CodeMirror pre\.CodeMirror-line[\s\S]*?\{([\s\S]*?)\}/.exec(css);

	if (!rule) {
		bad('cmtheme.css: 找不到 pre.CodeMirror-line 的接管规则体');
	}
	else {
		let missingProp = false;

		for (const prop of [ 'font-family', 'font-size', 'line-height' ]) {
			if (!new RegExp(prop + ':\\s*inherit').test(rule[1])) {
				bad(`cmtheme.css: pre 接管规则缺少 ${prop}: inherit（打包 CSS 的 15px / Arial 会漏进来）`);
				missingProp = true;
			}
		}

		if (!missingProp)
			ok('pre 行规则已接管（字体/字号/行高 inherit）');
	}
}

/* --------------------------------------------------- 2. token 覆盖率 + 对比度 */

const modes = fs.readdirSync(resDir).filter((f) => /^(yaml|shell)\.(min\.)?js$/.test(f));

if (!modes.length)
	bad('资源目录里找不到 yaml.js / shell.js，无法核对 token 覆盖');

const usedTokens = new Set();

for (const f of modes) {
	const src = read(path.join(resDir, f));

	for (const m of src.matchAll(/["'](atom|number|string|string-2|comment|meta|keyword|def|variable|variable-2|variable-3|builtin|operator|bracket|tag|attribute|qualifier|hr|link|error|property|type)["']/g))
		usedTokens.add(m[1]);
}

const LIGHT_BG = '#fcfcfd';
const DARK_BG = '#161b22';
const light = tokenColors(css, false);
const dark = tokenColors(css, true);

const missing = [...usedTokens].filter((t) => !light[t]);
if (missing.length)
	bad(`浅色主题缺少 token 配色：${missing.join(', ')}`);
else
	ok(`token 覆盖 ${usedTokens.size} 个（${[...usedTokens].sort().join(', ')}）`);

const darkMissing = [...usedTokens].filter((t) => !dark[t]);
if (darkMissing.length)
	bad(`深色主题缺少 token 配色：${darkMissing.join(', ')}`);

/* 正文与背景的对比度 */
const bodyColor = /\.cm-s-lucicode\.CodeMirror\s*\{[^}]*?color:\s*(#[0-9a-fA-F]{3,8})/.exec(css);

if (!bodyColor)
	bad('cmtheme.css: 找不到正文色（.cm-s-lucicode.CodeMirror 的 color）');
else if (contrast(bodyColor[1], LIGHT_BG) < 12)
	bad(`正文对比度不足：${bodyColor[1]} on ${LIGHT_BG} = ${contrast(bodyColor[1], LIGHT_BG).toFixed(2)}`);
else
	ok(`正文对比度 ${contrast(bodyColor[1], LIGHT_BG).toFixed(2)}:1`);

const rows = [];

for (const [token, color] of Object.entries(light)) {
	const ratio = contrast(color, LIGHT_BG);

	rows.push({ token, light: color, ratio });

	if (ratio < 4.5)
		bad(`浅色 ${token} 对比度 ${ratio.toFixed(2)} < 4.5（${color} on ${LIGHT_BG}）`);
}

for (const [token, color] of Object.entries(dark)) {
	const ratio = contrast(color, DARK_BG);

	if (ratio < 4.5)
		bad(`深色 ${token} 对比度 ${ratio.toFixed(2)} < 4.5（${color} on ${DARK_BG}）`);
}

/* ---------------------------------------------- 3. 深色判定与运行时跟随 */

const fnSrc = /(function preferDark\((?:[^)]*)\)[\s\S]*?\n\})/.exec(cmSrc);
const watchSrc = /(function watchTheme\([\s\S]*?\n\})/.exec(cmSrc);

/*
 * 极简 DOM 桩：只要能表达「节点 + 背景色 + data-darkmode + 父链」。
 * 两个函数必须放进同一个 vm 上下文，否则 watchTheme 里看不到 preferDark。
 */
function makeNode(bg, attrs, parent) {
	return {
		nodeType: 1,
		parentElement: parent || null,
		_bg: bg || 'rgba(0, 0, 0, 0)',
		getAttribute: (k) => (attrs && k in attrs ? attrs[k] : null)
	};
}

function makeApi(root, body, hooks) {
	const sandbox = {
		window: {
			getComputedStyle: (n) => ({ backgroundColor: n ? n._bg : 'rgba(0, 0, 0, 0)' }),
			matchMedia: () => ({ addEventListener: () => {} })
		},
		document: { documentElement: root, body: body }
	};

	if (hooks)
		Object.assign(sandbox, hooks);

	const src = `(function() { ${fnSrc[1]}\n${watchSrc[1]}\nreturn { preferDark: preferDark, watchTheme: watchTheme }; })()`;

	return vm.runInNewContext(src, sandbox);
}

if (!fnSrc) {
	bad('cmeditor.js: 找不到 preferDark 函数');
}
else if (!watchSrc) {
	bad('cmeditor.js: 找不到 watchTheme（主题切换不会跟随）');
}
else {
	const cases = [
		{
			name: 'html 声明 data-darkmode 且底色仍为浅（属性优先）',
			root: makeNode('rgba(0, 0, 0, 0)', { 'data-darkmode': 'true' }),
			body: makeNode('rgb(255, 255, 255)'),
			el: undefined,
			expect: true
		},
		{
			name: '无属性、body 深灰',
			root: makeNode('rgba(0, 0, 0, 0)'),
			body: makeNode('rgb(34, 34, 34)'),
			el: undefined,
			expect: true
		},
		{
			name: '无属性、body 近白',
			root: makeNode('rgba(0, 0, 0, 0)'),
			body: makeNode('rgb(252, 252, 253)'),
			el: undefined,
			expect: false
		},
		{
			name: 'body 全透明、容器深色（向上找）',
			root: makeNode('rgba(0, 0, 0, 0)'),
			body: makeNode('rgba(0, 0, 0, 0)'),
			el: makeNode('rgb(18, 18, 18)'),
			expect: true
		},
		{
			name: '全透明且无属性（兜底浅色）',
			root: makeNode('rgba(0, 0, 0, 0)'),
			body: makeNode('rgba(0, 0, 0, 0)'),
			el: undefined,
			expect: false
		}
	];

	let preferenceFailures = 0;

	for (const c of cases) {
		const got = makeApi(c.root, c.body).preferDark(c.el);

		if (got !== c.expect) {
			bad(`preferDark 在「${c.name}」下返回 ${got}，期望 ${c.expect}`);
			preferenceFailures++;
		}
	}

	if (!preferenceFailures)
		ok(`preferDark 判定正确（${cases.length} 个样本）`);

	/* 运行时切换主题必须跟上：bootstrap 的深色按钮只改属性、不刷新页面 */
	let dark = false;
	let observerCb = null;
	let matchCb = null;

	const wrapper = { classList: { toggle: (_cls, on) => { dark = Boolean(on); } } };
	const cm = { getWrapperElement: () => wrapper };

	const root = makeNode('rgba(0, 0, 0, 0)');
	const body = makeNode('rgb(255, 255, 255)');
	const el = makeNode('rgba(0, 0, 0, 0)', null, body);

	const api = makeApi(root, body, {
		MutationObserver: class { constructor(cb) { observerCb = cb; } observe() {} }
	});

	/* matchMedia 的监听由上面默认桩吞掉，这里只验证观察器路径 */
	api.watchTheme(cm, el);

	if (dark !== false) {
		bad('watchTheme: 浅色页面初始就判成深色');
	}
	else if (typeof observerCb !== 'function') {
		bad('watchTheme: 没有注册 MutationObserver，切换主题不会跟随');
	}
	else {
		root.getAttribute = (k) => (k === 'data-darkmode' ? 'true' : null);
		observerCb();

		if (dark !== true)
			bad('watchTheme: 切到深色后没有加上 cm-dark');
		else
			ok('watchTheme 能跟随运行时切换');
	}
}

/* ------------------------------------------------------------ 输出 */

console.log('CodeMirror 主题检查 · ' + path.relative(process.cwd(), ROOT));
console.log('');
console.log('  浅色 token（背景 ' + LIGHT_BG + '）');
for (const r of rows.sort((a, b) => b.ratio - a.ratio))
	console.log(`    ${r.token.padEnd(12)} ${r.light}  ${r.ratio.toFixed(2)}:1`);
console.log('');

const lightWorst = rows.reduce((m, r) => (r.ratio < m.ratio ? r : m), rows[0]);
if (lightWorst)
	console.log(`  最低对比度：${lightWorst.token} ${lightWorst.ratio.toFixed(2)}:1`);
console.log('');

for (const n of notes)
	console.log(n);

if (failures.length) {
	console.log('');
	for (const f of failures)
		console.log('  FAIL ' + f);
	console.log(`\n${failures.length} 条失败`);
	process.exit(1);
}

console.log('\n全部通过');
