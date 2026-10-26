'use strict';
/*
 * smartmwan 前端共享模块（零 Lua）
 *
 * 放置于 htdocs/luci-static/resources/smartmwan.js，视图用 'require smartmwan' 引入。
 * 只放「每个视图都要用、且必须一致」的东西：
 *   * 信封解析：桥原样透传 {ok, data, error{code,message,details}}，四态判定只此一份；
 *   * 四态渲染：加载中 / 空 / 无权限 / RPC 失败，全部如实，不写「正常」占位；
 *   * 轮询生命周期：poll.add/remove 成对，切页自停（下一 tick 发现容器已不在文档即自行摘除）；
 *   * 展示格式化：毫秒、千分比、字节、时间。
 *
 * 诚实性约束（任务书）：任何「状态」必须来自 RPC 字段或后端 notes，
 * 本文件不提供任何「猜测良好」的辅助函数。
 */

/* 样式表注入：<link> + L.resource，不用内联 <style>；幂等（按 id 判重）。 */
if (document.getElementById('smw-css-link') == null) {
	var link = E('link', {
		'id': 'smw-css-link',
		'rel': 'stylesheet',
		'type': 'text/css',
		'href': L.resource('smartmwan/smartmwan.css')
	});
	document.head.appendChild(link);
}

var smw = L.Class.extend({
	__name__: 'smartmwan',

	/* ---------- 信封 ---------- */

	/**
	 * 解析桥透传的信封。
	 * 返回 { state: 'loading'|'empty'|'error'|'ready', data, error }。
	 * state 的判据只有信封本身，不猜。
	 */
	parse: function(envelope) {
		if (envelope == null)
			return { state: 'error', error: { code: 'io', message: 'RPC 无响应' } };

		if (envelope.ok !== true)
			return {
				state: 'error',
				error: envelope.error || { code: 'unknown', message: '未知错误' }
			};

		var data = envelope.data;

		if (data == null || (Array.isArray(data) && data.length == 0))
			return { state: 'empty', data: data };

		return { state: 'ready', data: data };
	},

	/* ---------- 四态渲染 ---------- */

	/**
	 * 把四态渲染成一个节点。调用方给 ready 状态的渲染器。
	 * loadingText / emptyText 由调用方给具体文案；错误态展示 code + message + details。
	 */
	states: function(parsed, opts) {
		opts = opts || {};

		if (parsed.state == 'loading')
			return E('div', { 'class': 'smw-state smw-state-loading' },
				E('em', { 'class': 'spinning' }, [ opts.loadingText || '加载中…' ]));

		if (parsed.state == 'empty')
			return E('div', { 'class': 'smw-state smw-state-empty' },
				E('em', {}, [ opts.emptyText || '暂无数据' ]));

		if (parsed.state == 'error')
			return E('div', { 'class': 'smw-state smw-state-error alert-message warning' }, [
				E('strong', {}, [ 'RPC 失败：' ]),
				E('span', {}, [ parsed.error.message || String(parsed.error) ]),
				parsed.error.code ? E('div', { 'class': 'smw-error-code' },
					[ '错误码：', E('code', {}, parsed.error.code) ]) : '',
				(parsed.error.details && parsed.error.details.length)
					? E('ul', { 'class': 'smw-error-details' },
						parsed.error.details.map(function(d) { return E('li', {}, [ d ]) }))
					: ''
			]);

		return opts.render(parsed.data);
	},

	/* ---------- 轮询生命周期 ---------- */

	/**
	 * 注册轮询，保证：
	 *   1. 同一模块同时只有一条活跃轮询（进入先摘旧的）；
	 *   2. 离开页面后自行停止（下一 tick 发现根容器已不在文档即 poll.remove）。
	 * 返回登记用的函数引用（调用方无需关心）。
	 */
	poll: function(rootId, fn, interval) {
		if (this._pollFn != null) {
			poll.remove(this._pollFn);
			this._pollFn = null;
		}

		var self = this;
		var f = function() {
			var root = document.getElementById(rootId);
			if (root == null) {
				// 已被切页替换：成对退出的另一半。
				poll.remove(f);
				if (self._pollFn === f)
					self._pollFn = null;
				return;
			}
			fn();
		};

		this._pollFn = f;
		poll.add(f, interval);
		return f;
	},

	/* ---------- 展示格式化（不造数） ---------- */

	ms: function(v) {
		if (v == null)
			return '—';
		return v >= 1000 ? (v / 1000).toFixed(1) + ' s' : v + ' ms';
	},

	pmm: function(v) {
		if (v == null)
			return '—';
		return (v / 10).toFixed(1) + ' %';
	},

	bytes: function(v) {
		if (v == null)
			return '—';
		var units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
		var i = 0;
		while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
		return (i == 0 ? v : v.toFixed(1)) + ' ' + units[i];
	},

	kbps: function(v) {
		if (v == null)
			return '—';
		return v >= 1024 ? (v / 1024).toFixed(1) + ' Mbps' : v + ' kbps';
	},

	time: function(ms) {
		if (ms == null)
			return '—';
		var d = new Date(ms);
		function p(n) { return (n < 10 ? '0' : '') + n; }
		return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
	},

	ago: function(ms, now) {
		if (ms == null)
			return '—';
		var d = (now || Date.now()) - ms;
		if (d < 0)
			d = 0;
		if (d < 60000)
			return Math.floor(d / 1000) + ' 秒前';
		if (d < 3600000)
			return Math.floor(d / 60000) + ' 分钟前';
		return Math.floor(d / 3600000) + ' 小时前';
	},

	/* ---------- 通用零件 ---------- */

	/** 线路状态徽标：颜色只由 state 决定，不猜。 */
	stateBadge: function(state, label) {
		var cls = {
			healthy: 'smw-badge smw-badge-ok',
			degraded: 'smw-badge smw-badge-warn',
			failed: 'smw-badge smw-badge-bad',
			recovering: 'smw-badge smw-badge-info',
			unknown: 'smw-badge smw-badge-muted'
		}[state] || 'smw-badge smw-badge-muted';
		return E('span', { 'class': cls }, [ label || state ]);
	},

	/** 后端 notes 原样列表：UI 不得只挑好消息。 */
	notes: function(notes) {
		if (!notes || !notes.length)
			return E('span', { 'class': 'smw-muted' }, [ '（无）' ]);
		return E('ul', { 'class': 'smw-notes' },
			notes.map(function(n) { return E('li', {}, [ n ]) }));
	},

	/** 简单表格：head 为字符串数组，rows 为字符串数组的数组。 */
	table: function(head, rows) {
		return E('div', { 'class': 'smw-table' },
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' },
					head.map(function(h) { return E('th', { 'class': 'th' }, [ h ]) })),
				rows.map(function(r) {
					return E('tr', { 'class': 'tr' },
						r.map(function(c) { return E('td', { 'class': 'td' }, [ c ]) }));
				})
			]));
	}
});

return smw;
