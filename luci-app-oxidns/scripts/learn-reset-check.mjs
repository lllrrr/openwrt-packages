// 「立即重置」必须先落盘再触发 —— 契约测试。
//
// 背景：重置脚本（/usr/libexec/oxidns/learn-reset.sh）读的是 UCI，不是页面输入框。
// 改了用户名 / 密码 / API 地址却没点「保存定时设置」就点「立即重置」，用的是旧值。
// 所以 resetLearnedNow 要先调 saveLearnSchedule(button, true) 再触发重置。
//
// 这里直接跑**真实 view 源码**里的三个函数（learnInputValue / saveLearnSchedule /
// resetLearnedNow），只把 LuCI 运行时（document、_、renderResult、notifyResult、
// runRuleCall、callLearnSave、callLearnRun）作为参数注入，不抄一份实现。
//
//   node scripts/learn-reset-check.mjs             # 用仓库内的 rules.js
//   node scripts/learn-reset-check.mjs <file>      # 指到别的副本（做缺陷注入时用）

import fs from 'fs';
import { fileURLToPath } from 'url';

// LuCI 自己扩展了 String.prototype.format —— 见技能 openwrt-luci-verify-offline
// 「必须模拟的 LuCI 语义」表。
String.prototype.format = function (...args) {
	let i = 0;
	return this.replace(/%[sd]/g, () => String(args[i++]));
};

const DEFAULT_SRC = fileURLToPath(new URL('../htdocs/luci-static/resources/view/oxidns/rules.js', import.meta.url));
const SRC = process.argv[2] || DEFAULT_SRC;
const src = fs.readFileSync(SRC, 'utf8');

function pick(name) {
	const start = src.indexOf(`function ${name}(`);
	if (start < 0)
		throw new Error(`找不到函数 ${name}() —— 改名了就要同步改这个测试`);
	const end = src.indexOf('\n}\n', start) + 3;
	return src.slice(start, end);
}

const code = [ 'learnInputValue', 'saveLearnSchedule', 'resetLearnedNow' ].map(pick).join('\n')
	+ '\nreturn { saveLearnSchedule, resetLearnedNow };\n';

function makeEnv(opts) {
	const calls = { save: [], run: [], results: [], notes: [] };

	const fields = {
		'oxidns-learn-cn': { checked: true },
		'oxidns-learn-proxy': { checked: true },
		'oxidns-learn-freq': { value: 'daily' },
		'oxidns-learn-time': { value: '04:17' },
		'oxidns-learn-weekday': { value: '1' },
		'oxidns-learn-api-url': { value: 'http://127.0.0.1:9199' },
		'oxidns-learn-api-user': { value: opts.user },
		'oxidns-learn-api-pass': { value: opts.pass }
	};

	const document = { getElementById: (id) => fields[id] || null };
	const _ = (s) => s;
	const renderResult = (kind, title, detail, container) => calls.results.push({ kind, title, detail, container });
	const notifyResult = (kind, title) => calls.notes.push({ kind, title });

	const callLearnSave = (...args) => {
		calls.save.push(args);
		return Promise.resolve(opts.saveResult || { ok: true, cron_line: '17 4 * * *' });
	};
	const callLearnRun = (...args) => {
		calls.run.push(args);
		return Promise.resolve({ ok: true, detail: 'learned_cn: cleared' });
	};
	const runRuleCall = (button, busy, call, args) => Promise.resolve(call.apply(null, args || []));

	const factory = new Function('document', '_', 'renderResult', 'notifyResult', 'runRuleCall',
		'callLearnSave', 'callLearnRun', code);

	return {
		api: factory(document, _, renderResult, notifyResult, runRuleCall, callLearnSave, callLearnRun),
		calls,
		fields
	};
}

let failed = 0;
const ok = (m) => console.log('  ok   ' + m);
const bad = (m, d) => { failed++; console.log('  FAIL ' + m + (d ? '  <- ' + d : '')); };
const expect = (m, a, e) => (a === e ? ok(m) : bad(m, `got [${a}] want [${e}]`));

// ① 普通保存：参数顺序、返回值
{
	const env = makeEnv({ user: 'admin', pass: '' });
	const r = await env.api.saveLearnSchedule(null, false);
	expect('保存成功返回 true', r, true);
	expect('callLearnSave 收到 8 个参数', env.calls.save[0].length, 8);
	expect('第 7 个参数是用户名', env.calls.save[0][6], 'admin');
	expect('成功时渲染 Schedule saved', env.calls.results.some(x => x.title === 'Schedule saved'), true);
	expect('保存不该触发重置', env.calls.run.length, 0);
}

// ② silent 保存：不渲染保存成功，但仍清空密码框
{
	const env = makeEnv({ user: 'admin', pass: 'secret' });
	const r = await env.api.saveLearnSchedule(null, true);
	expect('silent 保存返回 true', r, true);
	expect('silent 不渲染保存成功', env.calls.results.some(x => x.title === 'Schedule saved'), false);
	expect('silent 仍清空密码框', env.fields['oxidns-learn-api-pass'].value, '');
}

// ③ 立即重置：先保存、后重置
{
	const env = makeEnv({ user: 'admin', pass: '' });
	await env.api.resetLearnedNow(null);
	expect('先调用保存', env.calls.save.length, 1);
	expect('再调用重置', env.calls.run.length, 1);
	expect('重置不带参数', env.calls.run[0].length, 0);
	expect('成功渲染 Learned files cleared', env.calls.results.some(x => x.title === 'Learned files cleared'), true);
}

// ④ 用户名为空：不保存、不重置，直接报错
{
	const env = makeEnv({ user: '', pass: 'x' });
	await env.api.resetLearnedNow(null);
	expect('空用户名不调用保存', env.calls.save.length, 0);
	expect('空用户名不触发重置', env.calls.run.length, 0);
	expect('空用户名报错', env.calls.results.some(x => x.kind === 'error' && x.detail === 'API username cannot be empty.'), true);
}

// ⑤ 保存失败：不重置
{
	const env = makeEnv({ user: 'admin', pass: '', saveResult: { ok: false, message: 'invalid_freq' } });
	await env.api.resetLearnedNow(null);
	expect('保存失败不触发重置', env.calls.run.length, 0);
	expect('保存失败报错', env.calls.results.some(x => x.kind === 'error'), true);
}

// ⑥ 两个学习集都没勾：不保存不重置
{
	const env = makeEnv({ user: 'admin', pass: '' });
	env.fields['oxidns-learn-cn'].checked = false;
	env.fields['oxidns-learn-proxy'].checked = false;
	await env.api.resetLearnedNow(null);
	expect('未选学习集不保存', env.calls.save.length, 0);
	expect('未选学习集不重置', env.calls.run.length, 0);
}

console.log(failed ? `\n${failed} 条断言失败` : '\n全部通过');
process.exit(failed ? 1 : 0);
