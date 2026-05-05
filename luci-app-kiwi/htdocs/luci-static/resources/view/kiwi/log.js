// SPDX-License-Identifier: Apache-2.0
// Kiwi — 日志页（带搜索、倒序、暂停、清空）

'use strict';
'require dom';
'require poll';
'require rpc';
'require ui';
'require view';

/* ── injectCSS ─────────────────────────────────────── */
function injectCSS() {
	if (document.getElementById('kiwi-log-css')) return;
	var el = document.createElement('style');
	el.id = 'kiwi-log-css';
	el.textContent = [
		'.kiwi-log .log-pane{',
		'  font-family:var(--bs-font-monospace,monospace);',
		'  background:rgba(127,127,127,.08);',
		'  color:inherit;',
		'  border:1px solid rgba(127,127,127,.18);',
		'  border-radius:.375rem;',
		'  max-height:68vh;overflow:auto;',
		'}',
		'.kiwi-log .log-pane pre{',
		'  padding:.5rem .75rem;margin:0;',
		'  white-space:pre-wrap;word-wrap:break-word;overflow-wrap:break-word;',
		'  font-size:.8125rem;line-height:1.35;',
		'  color:inherit;',
		'}',
		'.kiwi-log .log-pane .log-line{',
		'  display:flex;gap:.2rem;padding:0;',
		'  align-items:baseline;',
		'}',
		'.kiwi-log .log-pane .log-line .lvl{',
		'  flex-shrink:0;font-size:.65rem;font-weight:700;',
		'  padding:0 .35rem;border-radius:3px;',
		'  text-transform:uppercase;line-height:1.5;',
		'  min-width:2.8rem;text-align:center;',
		'}',
		'.kiwi-log .log-pane .log-line .lvl-info{',
		'  background:rgba(137,180,250,.18);color:#89b4fa;',
		'}',
		'.kiwi-log .log-pane .log-line .lvl-warn{',
		'  background:rgba(250,179,135,.18);color:#fab387;',
		'}',
		'.kiwi-log .log-pane .log-line .lvl-error{',
		'  background:rgba(243,139,168,.18);color:#f38ba8;',
		'}',
		'.kiwi-log .log-pane .log-line .lvl-debug{',
		'  background:rgba(166,173,200,.15);color:#6c7086;',
		'}',
		'.kiwi-log .log-pane .log-line .msg{flex:1;min-width:0;}',
		'.kiwi-log .log-pane .log-line .msg mark{',
		'  background:rgba(255,193,7,.40);color:inherit;',
		'  border-radius:2px;padding:0 2px;',
		'}',
		'.kiwi-log .log-bar{',
		'  display:flex;align-items:center;gap:.5rem;',
		'  padding:.375rem 0;flex-wrap:wrap;',
		'}',
		'.kiwi-log .log-bar .spacer{flex:1}',
		'.kiwi-log .log-bar input[type=search]{',
		'  width:120px;height:25px;flex:none;padding:0 .5rem;',
		'  border:1px solid rgba(127,127,127,.18);',
		'  border-radius:.25rem;',
		'  background:rgba(127,127,127,.08);color:inherit;',
		'  font-size:.75rem;',
		'}',
		'.kiwi-log .log-bar input[type=search]:focus{',
		'  outline:2px solid rgba(137,180,250,.5);',
		'}',
		'.kiwi-log .log-btn{',
		'  display:inline-flex;align-items:center;gap:.25rem;',
		'  padding:.25rem .5rem;border-radius:.25rem;cursor:pointer;',
		'  border:1px solid rgba(127,127,127,.18);',
		'  background:rgba(127,127,127,.08);color:inherit;',
		'  font-size:.75rem;user-select:none;',
		'}',
		'.kiwi-log .log-btn:hover{background:rgba(127,127,127,.15)}',
		'.kiwi-log .log-btn.active{',
		'  background:rgba(64,160,43,.18);border-color:rgba(64,160,43,.35);',
		'}',
		'.kiwi-log .log-btn.danger:hover{',
		'  background:rgba(243,139,168,.25);border-color:rgba(243,139,168,.4);',
		'}',
		'.kiwi-log .log-btn svg{width:14px;height:14px;flex-shrink:0}',
		'.kiwi-log .log-muted{opacity:.55;font-style:italic;font-size:.75rem}',
		'.kiwi-log .log-stat{font-size:.75rem;opacity:.7}',
		'.kiwi-log .log-stat strong{opacity:1;font-weight:700}',
	].join('');
	document.head.appendChild(el);
}

/* ── SVG icons ─────────────────────────────────────── */
var ICONS = {
	reverse: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M5 3v10M2 6l3-3 3 3"/><path d="M11 13V3M8 10l3 3 3-3"/></svg>',
	play:    '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M4 2v12l10-6z"/></svg>',
	pause:   '<svg viewBox="0 0 16 16" fill="currentColor"><rect x="3" y="2" width="4" height="12" rx="1"/><rect x="9" y="2" width="4" height="12" rx="1"/></svg>',
	trash:   '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2 4h12M5.3 4V2.7a.7.7 0 01.7-.7h4a.7.7 0 01.7.7V4M6 7v5M10 7v5M3.5 4l.9 9.3a1 1 0 001 .7h5.2a1 1 0 001-.7l.9-9.3"/></svg>',
};

/* ── Get log RPC ───────────────────────────────────── */
var getLogRpc = rpc.declare({
	object: 'luci.kiwi',
	method: 'getLog',
	expect: { log: '' }
});

/* ── Clear log RPC ─────────────────────────────────── */
var clearLogRpc = rpc.declare({
	object: 'luci.kiwi',
	method: 'clearLog',
	expect: { result: false }
});

/* ── Parse kiwi/syslog line → {level, msg} ────────── */
/* Kiwi 输出 syslog 纯文本: "... user.notice kiwi: message" */
/* 也支持 JSON: {"level":"INFO","message":"..."} */
var LEVEL_RE = /"level"\s*:\s*"(info|warn|error|debug|trace|fatal)"/i;
var MSG_RE  = /"message"\s*:\s*"(.*?)"(\s|$)/;
var SYSLOG_RE = /(?:kernel\.|user\.|daemon\.)?(?:notice|info|warn(?:ing)?|err(?:or)?|debug|emerg|alert|crit)\s+kiwi\s*:\s*(.*)/i;
var SYSLOG_LEVEL_RE = /(notice|info|warn(?:ing)?|err(?:or)?|debug|emerg|alert|crit)\s+kiwi\s*:/i;

function parseLine(raw) {
	raw = raw.trim();
	if (!raw) return { level: 'info', msg: '' };

	/* JSON 格式 */
	var lv = raw.match(LEVEL_RE);
	var mg = raw.match(MSG_RE);
	if (lv && mg) {
		return { level: lv[1].toLowerCase(), msg: mg[1] };
	}

	/* syslog 格式: "... daemon.notice kiwi: message" (含时间戳前缀) */
	var sm = raw.match(SYSLOG_RE);
	if (sm) {
		var lvlm = raw.match(SYSLOG_LEVEL_RE);
		var lvl = lvlm ? lvlm[1].toLowerCase() : 'info';
		if (lvl === 'warning') lvl = 'warn';
		if (lvl === 'err' || lvl === 'error') lvl = 'error';
		if (lvl === 'notice') lvl = 'info';
		return { level: lvl, msg: sm[1].trim() };
	}

	/* fallback: 整行作为消息 */
	return { level: 'info', msg: raw };
}

function esc(s) {
	return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function buildLine(parsed, query) {
	var lvl = parsed.level;
	var msg = esc(parsed.msg);
	if (query && query.length >= 2) {
		var q = esc(query);
		var re = new RegExp('(' + q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
		msg = msg.replace(re, '<mark>$1</mark>');
	}
	return '<div class="log-line">' +
		'<span class="lvl lvl-' + lvl + '">' + lvl + '</span>' +
		'<span class="msg">' + msg + '</span>' +
		'</div>';
}

function filterLines(lines, query) {
	if (!query || query.length < 2) return lines;
	var q = query.toLowerCase();
	return lines.filter(function(raw) {
		return raw.toLowerCase().indexOf(q) !== -1;
	});
}

return view.extend({
	__pollHandle:  null,
	__paused:      false,
	__reverse:     true,
	__logLines:    [],
	__searchQuery: '',
	__maxLines:    500,

	render() {
		injectCSS();
		var self = this;

		var logPre  = E('pre', { id: 'kiwi-log-content' });
		var logPane = E('div', { 'class': 'log-pane' }, [logPre]);
		var statusEl = E('span', { 'class': 'log-stat', id: 'kiwi-log-status' }, '--');

		var searchInput = E('input', {
			type: 'search',
			placeholder: '搜索日志…',
			id: 'kiwi-log-search',
			input: function() {
				self.__searchQuery = this.value;
				self.__renderLog();
			}
		});

		var revBtn = E('button', {
			'class': 'log-btn active',
			title: '倒序（最新在前）',
			id: 'kiwi-log-reverse',
			click: function() {
				self.__reverse = !self.__reverse;
				this.classList.toggle('active', self.__reverse);
				this.title = self.__reverse ? '倒序（最新在前）' : '正序（最早在前）';
				self.__renderLog();
			}
		});
		revBtn.innerHTML = ICONS.reverse;

		var pauseBtn = E('button', {
			'class': 'log-btn',
			title: '暂停刷新',
			id: 'kiwi-log-pause',
			click: function() {
				self.__paused = !self.__paused;
				this.classList.toggle('active', self.__paused);
				this.innerHTML = self.__paused ? ICONS.play : ICONS.pause;
				this.title = self.__paused ? '恢复刷新' : '暂停刷新';
				if (!self.__paused) self.__renderLog();
			}
		});
		pauseBtn.innerHTML = ICONS.pause;

		var clearBtn = E('button', {
			'class': 'log-btn danger',
			title: '清空日志',
			id: 'kiwi-log-clear',
			click: function() {
				return clearLogRpc().then(function(result) {
					self.__logLines = [];
					self.__renderLog();
				}).catch(function(err) {
					ui.addNotification(null,
						E('p', {}, '清空日志失败：' + (err.message || err)), 'danger');
				});
			}
		});
		clearBtn.innerHTML = ICONS.trash;

		var toolbar = E('div', { 'class': 'log-bar' }, [
			searchInput, revBtn, pauseBtn, clearBtn,
			E('span', { 'class': 'spacer' }),
			statusEl,
			E('span', { 'class': 'log-muted' },
				'每 ' + (L.env.pollinterval || '3') + ' 秒刷新 ｜ 上限 500 行')
		]);

		var root = E('div', { 'class': 'cbi-map kiwi-log' }, [
			E('h2', {}, 'Kiwi — 日志'),
			E('div', { 'class': 'cbi-section' }, [toolbar, logPane])
		]);

		self.__pollHandle = poll.add(function() {
			return getLogRpc()
				.then(function(res) {
					var content = res || '';
					var lines = content.split('\x1E');
					if (lines.length > self.__maxLines)
						lines = lines.slice(-self.__maxLines);
					self.__logLines = lines;
					if (!self.__paused) self.__renderLog();
				}).catch(function(e) {
					self.__logLines = [];
					if (e.toString().indexOf('NotFoundError') !== -1)
						self.__logLines = ['日志文件不存在'];
					else
						self.__logLines = ['错误: ' + (e.message || e)];
					self.__renderLog();
				});
		});

		return root;
	},

	__renderLog: function() {
		var el = document.getElementById('kiwi-log-content');
		if (!el) return;

		var query = this.__searchQuery;
		var raw = query ? filterLines(this.__logLines, query) : this.__logLines;
		if (this.__reverse) raw = raw.slice().reverse();

		var html = [];
		for (var i = 0; i < raw.length; i++) {
			if (!raw[i]) continue;
			html.push(buildLine(parseLine(raw[i]), query));
		}

		el.innerHTML = html.length
			? html.join('\n')
			: '<div style="padding:.75rem;opacity:.5;font-style:italic">无匹配日志</div>';

		var pane = el.parentNode;
		if (pane) pane.scrollTop = this.__reverse ? 0 : pane.scrollHeight;

		var st = document.getElementById('kiwi-log-status');
		if (st) {
			var shown = raw.filter(function(l) { return l.trim(); }).length;
			var total = this.__logLines.filter(function(l) { return l.trim(); }).length;
			st.innerHTML = query
				? '筛选 <strong>' + shown + '</strong> / ' + total + ' 行'
				: (this.__paused
					? '共 <strong>' + total + '</strong> 行（已暂停）'
					: '共 <strong>' + total + '</strong> 行');
		}
	},

	handleReset:      null,
	handleSave:      null,
	handleSaveApply: null
});
