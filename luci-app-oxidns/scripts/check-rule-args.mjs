// 顺序参数必须给满：rpc.declare({ params: [...] }) 是按位置映射成字典的，
// 调用时少给一个实参，后面的字段整体前移。
//
// 2026-09-30 的 8314c66 把 rules_save 的 params 从 4 个字段改成 9 个分块字段，
// 却只改了声明、没改调用 —— name 被当成 content_chunk 发走，后端永远只回
// "rule file name is not allowed"，规则页保存从 1.0 起就是坏的。
//
//   node scripts/check-rule-args.mjs

import fs from 'fs';

const RULES = 'htdocs/luci-static/resources/view/oxidns/rules.js';
const DECL = 'var callRulesSave = rpc.declare({';
const CALL = 'return callRulesSave(';

const src = fs.readFileSync(RULES, 'utf8');
const failures = [];

/* 从声明里数 params 数组有几个字符串字面量 */
function declaredCount(text) {
	const start = text.indexOf(DECL);

	if (start < 0)
		return -1;

	const paramsAt = text.indexOf('params:', start);
	const open = text.indexOf('[', paramsAt);
	let depth = 1;
	let i = open + 1;

	for (; i < text.length && depth > 0; i++) {
		if (text[i] === '[')
			depth++;
		else if (text[i] === ']')
			depth--;
	}

	return (text.slice(open + 1, i - 1).match(/'[^']*'/g) || []).length;
}

/* 数一次调用的顶层实参个数（跳过嵌套括号里的逗号） */
function callArgCount(text) {
	const start = text.indexOf(CALL);

	if (start < 0)
		return -1;

	let i = start + CALL.length;
	let depth = 1;
	let args = 1;

	for (; i < text.length && depth > 0; i++) {
		const c = text[i];

		if (c === '(')
			depth++;
		else if (c === ')')
			depth--;
		else if (c === ',' && depth === 1)
			args++;
	}

	return args;
}

const declared = declaredCount(src);
const passed = callArgCount(src);

if (declared < 0)
	failures.push(`${RULES}: 找不到 callRulesSave 的 params 声明`);
else if (passed < 0)
	failures.push(`${RULES}: 找不到 callRulesSave 的调用`);
else if (declared !== passed)
	failures.push(`${RULES}: callRulesSave 调用给了 ${passed} 个实参，params 声明了 ${declared} 个 —— 顺序参数会整体错位`);

if (failures.length) {
	console.error(failures.join('\n'));
	process.exit(1);
}

console.log(`rules_save 参数契约: ${passed} 个实参 / ${declared} 个字段`);
