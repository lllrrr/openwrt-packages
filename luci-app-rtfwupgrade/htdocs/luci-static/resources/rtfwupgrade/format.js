'use strict';
'require baseclass';

// 视图公共格式化：体积、状态色、徽标、统计块、对照表。
// 注意：LuCI 的模块必须返回一个 **Class**（加载器会用 Class.isSubclass 校验并实例化），
// 返回普通对象字面量会直接抛 "factory yields invalid constructor"（已实测踩坑）。

var TONES = {
	same: 'success',
	update: 'warning',
	downgrade: 'danger',
	rebuild: 'notice',
	incomparable: 'muted'
};

function fmtSize(bytes) {
	var n = parseInt(bytes || 0, 10);

	if (!n) return '-';
	if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';

	return (n / 1024).toFixed(1) + ' KB';
}

function fmtSha(sha) {
	return sha ? String(sha).substr(0, 12) : '-';
}

function stateTone(state) {
	return TONES[state] || 'muted';
}

function badge(state, label) {
	return E('span', { class: 'rtfw-badge rtfw-tone-' + stateTone(state) }, label);
}

function stat(label, value, sub) {
	var items = [
		E('div', { class: 'rtfw-label' }, label),
		E('div', { class: 'rtfw-value' }, value === undefined || value === null || value === '' ? '-' : value)
	];

	if (sub) items.push(E('div', { class: 'rtfw-sub' }, sub));

	return E('div', { class: 'rtfw-stat' }, items);
}

function callout(tone, title, content) {
	return E('div', { class: 'rtfw-callout' + (tone ? ' rtfw-tone-' + tone : '') }, [
		title ? E('div', { class: 'rtfw-callout-title' }, title) : '',
		E('div', {}, content)
	]);
}

// columns 可传 [ '标题', { text: '标题', class: 'rtfw-col-action' }, … ]
// rows 的每一项是单元格数组；可选 rowClass(row, index) 返回该行的附加类名，
// 用于让调用方按数据给整行加样式（例如日志按级别着色），而不必自己拼表格。
function kvTable(columns, rows, rowClass) {
	function head(c) {
		return typeof c === 'string' ? { text: c, class: '' } : c;
	}

	return E('table', { class: 'table rtfw-table' }, [
		E(
			'thead',
			{},
			E(
				'tr',
				{},
				columns.map(function (c) {
					var h = head(c);
					return E('th', { class: h.class || '' }, h.text);
				})
			)
		),
		E(
			'tbody',
			{},
			rows.map(function (r, ri) {
				var extra = typeof rowClass === 'function' ? rowClass(r, ri) : '';

				return E(
					'tr',
					extra ? { class: extra } : {},
					r.map(function (c, i) {
						var h = head(columns[i] || '');
						var cls = ((h.class || '') + (i > 0 ? ' rtfw-mono' : '')).trim();
						return E('td', { class: cls }, c === '' || c === null ? '-' : c);
					})
				);
			})
		)
	]);
}

return baseclass.extend({
	TONES: TONES,
	fmtSize: fmtSize,
	fmtSha: fmtSha,
	stateTone: stateTone,
	badge: badge,
	stat: stat,
	callout: callout,
	kvTable: kvTable
});
