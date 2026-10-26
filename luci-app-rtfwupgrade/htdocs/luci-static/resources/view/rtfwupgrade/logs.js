'use strict';
'require view';
'require rpc';
'require ui';
'require rtfwupgrade.format as fmt';

var callLogs = rpc.declare({ object: 'rtfwupgrade', method: 'logs' });
var callClear = rpc.declare({ object: 'rtfwupgrade', method: 'logs_clear' });
var callVersion = rpc.declare({ object: 'rtfwupgrade', method: 'version' });

// 后台只发这三种级别（eventlog.append 的调用点全是它们）。
// 级别的颜色与徽标复用 glanceable 的 tone 色板，与其它页面保持一致。
var LEVEL_TONE = { info: 'notice', warn: 'warning', error: 'danger' };
var LEVEL_TEXT = { info: 'info', warn: 'warn', error: 'error' };

// 缓存破坏：LuCI 把 `resource_version`（取自 <script src="luci.js?v=...">）追加到模块 URL，
// 本机这份 LuCI 没有版本戳，模块与样式 URL 都是裸路径，浏览器于是按 Last-Modified
// 的启发式规则缓存；包升级后仍会加载旧文件，直到手动强制刷新。
// 这里给本应用自己的静态资源加上包版本号：版本一变 URL 就变，缓存自然失效。
function asset(path, version) {
	var href = L.resource(path);

	if (!version) return href;

	return href + (href.indexOf('?') >= 0 ? '&' : '?') + 'v=' + encodeURIComponent(version);
}

function sheet(version) {
	return E('link', { rel: 'stylesheet', href: asset('rtfwupgrade/rtfwupgrade.css', version) });
}

function replace(node, children) {
	while (node.firstChild) node.removeChild(node.firstChild);

	// 视图函数返回的常是一维数组，但一旦有人返回嵌套数组，
	// 裸 appendChild 会抛 "parameter 1 is not of type 'Node'"。
	// 这里统一拍平，并把非节点值转成文本节点。
	(function add(v) {
		if (v === null || v === undefined || v === '' || v === false) return;
		if (Array.isArray(v)) return v.forEach(add);
		if (typeof v === 'object' && (v.nodeType || v.tag)) return node.appendChild(v);
		node.appendChild(document.createTextNode(String(v)));
	})(children);
}

function stamp(ts) {
	if (!ts) return '-';

	return new Date(ts * 1000).toISOString().replace('T', ' ').substr(0, 19) + ' UTC';
}

// 「事件 · 级别」这一格：事件用弱化的灰徽标，级别用带色徽标。
// 两段都是纯文本 + class，颜色由 CSS 决定（深色主题下也能自适应）。
function levelCell(e) {
	var ev = e.event || '-';
	var lv = e.level || 'info';

	return E('span', { class: 'rtfw-log-tags' }, [
		E('span', { class: 'rtfw-log-event rtfw-log-event-' + ev }, ev),
		E('span', { class: 'rtfw-log-level rtfw-tone-' + (LEVEL_TONE[lv] || 'muted') }, LEVEL_TEXT[lv] || lv)
	]);
}

return view.extend({
	load: function () {
		// version 只用于给 CSS 打缓存版本戳；取不到也不能让整页挂掉
		return Promise.all([
			callLogs(),
			callVersion().catch(function () {
				return null;
			})
		]);
	},

	render: function (loaded) {
		var data = Array.isArray(loaded) ? loaded[0] : loaded;
		var versionInfo = Array.isArray(loaded) ? loaded[1] : null;
		var status = { version: versionInfo && versionInfo.version ? versionInfo.version : '' };
		var self = this;

		this.data = data || { events: [], download_log: '', cron_log: '' };
		this.filters = { level: '', event: '', q: '' };
		this.logNode = E('div', {}, this.buildLog());

		function pick(label, options, key, onchange) {
			return E('label', { class: 'rtfw-filter' }, [
				E('span', {}, label),
				E(
					'select',
					{ class: 'cbi-input-select', change: onchange },
					options.map(function (o) {
						return E('option', { value: o.value }, o.text);
					})
				)
			]);
		}

		return E('div', { class: 'rtfw-app' }, [
			sheet(status.version),
			E('h2', {}, _('Logs')),
			E(
				'p',
				{ class: 'rtfw-muted' },
				_(
					'Detection, source, download and flash events, newest first, stored under /tmp. A reboot clears them; a pending flash result is kept in /etc until it is confirmed.'
				)
			),

			E('div', { class: 'rtfw-toolbar' }, [
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'handleRefresh')
					},
					_('Refresh')
				),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-reset',
						click: ui.createHandlerFn(this, 'handleClear')
					},
					_('Clear log')
				)
			]),

			E('div', { class: 'rtfw-filters' }, [
				pick(
					_('Level'),
					[
						{ value: '', text: _('All levels') },
						{ value: 'info', text: 'info' },
						{ value: 'warn', text: 'warn' },
						{ value: 'error', text: 'error' }
					],
					'level',
					function (ev) {
						self.filters.level = ev.target.value;
						self.renderLog();
					}
				),

				pick(
					_('Event'),
					[
						{ value: '', text: _('All events') },
						{ value: 'check', text: 'check' },
						{ value: 'source', text: 'source' },
						{ value: 'options', text: 'options' },
						{ value: 'download', text: 'download' },
						{ value: 'cron', text: 'cron' }
					],
					'event',
					function (ev) {
						self.filters.event = ev.target.value;
						self.renderLog();
					}
				),

				E('label', { class: 'rtfw-filter' }, [
					E('span', {}, _('Search')),
					E('input', {
						class: 'cbi-input-text',
						type: 'text',
						placeholder: _('substring of the message'),
						input: function (ev) {
							self.filters.q = ev.target.value;
							self.renderLog();
						}
					})
				])
			]),

			this.logNode
		]);
	},

	renderLog: function () {
		replace(this.logNode, this.buildLog());
	},

	filtered: function () {
		var f = this.filters || {};
		var q = (f.q || '').toLowerCase();

		return ((this.data && this.data.events) || []).filter(function (e) {
			if (f.level && e.level !== f.level) return false;
			if (f.event && e.event !== f.event) return false;
			if (
				q &&
				String(e.message || '')
					.toLowerCase()
					.indexOf(q) < 0
			)
				return false;

			return true;
		});
	},

	buildLog: function () {
		var all = (this.data && this.data.events) || [];
		var events = this.filtered();
		var nodes = [];

		if (all.length)
			nodes.push(E('p', { class: 'rtfw-muted' }, _('Shown %d of %d events').format(events.length, all.length)));

		if (!events.length) {
			nodes.push(
				E('p', { class: 'rtfw-muted' }, all.length ? _('No events match the filter.') : _('No events yet.'))
			);
		} else {
			nodes.push(
				fmt.kvTable(
					[
						{ text: _('Time'), class: 'rtfw-col-time' },
						{ text: _('Event'), class: 'rtfw-col-layout' },
						_('Detail')
					],
					events.map(function (e) {
						return [stamp(e.ts), levelCell(e), e.message || ''];
					}),
					// 整行按级别着色：扫一眼就能看出哪些是问题
					function (row, ri) {
						var e = events[ri] || {};
						return 'rtfw-log-row rtfw-log-' + (e.level || 'info');
					}
				)
			);
		}

		var raw = (this.data && this.data.download_log) || '';
		var cron = (this.data && this.data.cron_log) || '';
		var files = (this.data && this.data.files) || {};

		nodes.push(
			E('details', { class: 'rtfw-images' }, [
				E('summary', {}, _('Raw downloader output (tail)')),
				raw
					? E('pre', { class: 'rtfw-mono', style: 'max-height:22rem;overflow:auto' }, raw)
					: E('p', { class: 'rtfw-muted' }, _('No downloader output yet.'))
			])
		);

		// 定时任务的原始输出（/tmp/rtfwupgrade/cron.log）与下载器输出并列展示。
		// 后端 rpcd logs 新增 cron_log 字段后自动生效；旧后端没有这个字段时显示空态。
		nodes.push(
			E('details', { class: 'rtfw-images' }, [
				E('summary', {}, _('Raw scheduled-task output (tail)')),
				cron
					? E('pre', { class: 'rtfw-mono', style: 'max-height:22rem;overflow:auto' }, cron)
					: E('p', { class: 'rtfw-muted' }, _('No scheduled-task output yet.'))
			])
		);

		if (files.events)
			nodes.push(
				E('p', { class: 'rtfw-muted' }, _('Files: %s , %s').format(files.events, files.download_log || '-'))
			);

		if (files.cron_log)
			nodes.push(E('p', { class: 'rtfw-muted' }, _('Scheduled-task log: %s').format(files.cron_log)));

		return nodes;
	},

	handleRefresh: function () {
		var self = this;

		return callLogs()
			.then(function (data) {
				self.data = data || { events: [], download_log: '', cron_log: '' };
				replace(self.logNode, self.buildLog());
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Refresh failed: ') + (err.message || err)), 'error');
			});
	},

	handleClear: function () {
		var self = this;

		return callClear()
			.then(function () {
				return self.handleRefresh();
			})
			.then(function () {
				ui.addNotification(null, E('p', {}, _('Log cleared.')), 'info');
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Clear failed: ') + (err.message || err)), 'error');
			});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
