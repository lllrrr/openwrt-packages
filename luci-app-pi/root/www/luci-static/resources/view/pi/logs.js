'use strict';'require dom';'require fs';'require poll';'require rpc';'require ui';'require view';

function injectCSS(){
	if(document.getElementById('pi-log-css'))return;
	var el=document.createElement('style');
	el.id='pi-log-css';
	el.textContent=[
		'.pi-log .log-pane{',
		'  font-family:var(--bs-font-monospace,monospace);',
		'  background:rgba(127,127,127,.08);',
		'  color:inherit;',
		'  border:1px solid rgba(127,127,127,.18);',
		'  border-radius:.375rem;',
		'  max-height:68vh;overflow:auto;',
		'}',
		'.pi-log .log-pane pre{',
		'  padding:.5rem .75rem;margin:0;',
		'  white-space:pre-wrap;word-wrap:break-word;overflow-wrap:break-word;',
		'  font-size:.8125rem;line-height:1.35;',
		'  color:inherit;',
		'}',
		'.pi-log .log-pane .log-line{',
		'  display:flex;gap:.2rem;padding:0;',
		'  align-items:baseline;',
		'}',
		'.pi-log .log-pane .log-line .lvl{',
		'  flex-shrink:0;font-size:.65rem;font-weight:700;',
		'  padding:0 .35rem;border-radius:3px;',
		'  text-transform:uppercase;line-height:1.5;',
		'  min-width:2.8rem;text-align:center;',
		'}',
		'.pi-log .log-pane .log-line .lvl-info{',
		'  background:rgba(137,180,250,.18);color:#89b4fa;',
		'}',
		'.pi-log .log-pane .log-line .lvl-warn{',
		'  background:rgba(250,179,135,.18);color:#fab387;',
		'}',
		'.pi-log .log-pane .log-line .lvl-error{',
		'  background:rgba(243,139,168,.18);color:#f38ba8;',
		'}',
		'.pi-log .log-pane .log-line .lvl-debug{',
		'  background:rgba(166,173,200,.15);color:#6c7086;',
		'}',
		'.pi-log .log-pane .log-line .msg{flex:1;min-width:0;}',
		'.pi-log .log-pane .log-line .msg mark{',
		'  background:rgba(255,193,7,.40);color:inherit;',
		'  border-radius:2px;padding:0 2px;',
		'}',
		'.pi-log .log-bar{',
		'  display:flex;align-items:center;gap:.5rem;',
		'  padding:.375rem 0;flex-wrap:wrap;',
		'}',
		'.pi-log .log-bar .spacer{flex:1}',
		'.pi-log .log-bar input[type=search]{',
		'  width: 120px; height: 25px; flex: none; padding: 0 .5rem;',
		'  border:1px solid rgba(127,127,127,.18);',
		'  border-radius:.25rem;',
		'  background:rgba(127,127,127,.08);color:inherit;',
		'  font-size:.75rem;',
		'}',
		'.pi-log .log-bar input[type=search]:focus{',
		'  outline:2px solid rgba(137,180,250,.5);',
		'}',
		'.pi-log .log-btn{',
		'  display:inline-flex;align-items:center;gap:.25rem;',
		'  padding:.25rem .5rem;border-radius:.25rem;cursor:pointer;',
		'  border:1px solid rgba(127,127,127,.18);',
		'  background:rgba(127,127,127,.08);color:inherit;',
		'  font-size:.75rem;user-select:none;',
		'}',
		'.pi-log .log-btn:hover{background:rgba(127,127,127,.15)}',
		'.pi-log .log-btn.active{',
		'  background:rgba(64,160,43,.18);border-color:rgba(64,160,43,.35);',
		'}',
		'.pi-log .log-btn.danger:hover{',
		'  background:rgba(243,139,168,.25);border-color:rgba(243,139,168,.4);',
		'}',
		'.pi-log .log-btn svg{width:14px;height:14px;flex-shrink:0}',
		'.pi-log .log-muted{opacity:.55;font-style:italic;font-size:.75rem}',
		'.pi-log .log-stat{font-size:.75rem;opacity:.7}',
		'.pi-log .log-stat strong{opacity:1;font-weight:700}',
	].join('');
	document.head.appendChild(el);
}

var ICONS={
	reverse:'<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M5 3v10M2 6l3-3 3 3"/><path d="M11 13V3M8 10l3 3 3-3"/></svg>',
	play:'<svg viewBox="0 0 16 16" fill="currentColor"><path d="M4 2v12l10-6z"/></svg>',
	pause:'<svg viewBox="0 0 16 16" fill="currentColor"><rect x="3" y="2" width="4" height="12" rx="1"/><rect x="9" y="2" width="4" height="12" rx="1"/></svg>',
	trash:'<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2 4h12M5.3 4V2.7a.7.7 0 01.7-.7h4a.7.7 0 01.7.7V4M6 7v5M10 7v5M3.5 4l.9 9.3a1 1 0 001 .7h5.2a1 1 0 001-.7l.9-9.3"/></svg>',
};

function esc(s){
	return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

var LOG_FILE = '/var/log/pi/pi.log';
var LEVEL_RE = /(?:^|\s)level\s*=\s*(info|warn|error|debug|trace|fatal)\b\s*/i;
var MSG_RE   = /msg\s*=\s*"(.*?)"(\s|$)/;

function parseLine(raw){
	raw = raw.replace(/^\s+/,'');
	var lv = raw.match(LEVEL_RE);
	var mg = raw.match(MSG_RE);
	var level = (lv ? lv[1].toLowerCase() : 'info');
	var msg   = mg ? mg[1] : raw;
	return { level: level, msg: msg };
}

function buildLine(parsed, query){
	var lvl = parsed.level;
	var msg = esc(parsed.msg);
	if(query && query.length >= 2){
		var q = esc(query);
		var re = new RegExp('(' + q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
		msg = msg.replace(re, '<mark>$1</mark>');
	}
	return '<div class="log-line">'
		+ '<span class="lvl lvl-' + lvl + '">' + (lvl === 'warn' ? 'warn' : lvl) + '</span>'
		+ '<span class="msg">' + msg + '</span>'
		+ '</div>';
}

function filterLines(lines, query){
	if(!query || query.length < 2) return lines;
	var q = query.toLowerCase();
	return lines.filter(function(raw){
		return raw.toLowerCase().indexOf(q) !== -1;
	});
}

return view.extend({
	__pollHandle: null,
	__paused: false,
	__reverse: true,
	__logLines: [],
	__searchQuery: '',
	__maxLines: 500,

	render(){
		injectCSS();
		var self = this;
		var logPre = E('pre', { id: 'pi-log-content' });
		var logPane = E('div', { 'class': 'log-pane' }, [ logPre ]);
		var statusEl = E('span', { 'class': 'log-stat', id: 'pi-log-status' }, '--');

		var searchInput = E('input', {
			type: 'search',
			placeholder: '搜索日志\u2026',
			id: 'pi-log-search',
			input: function(){
				self.__searchQuery = this.value;
				self.__renderLog();
			}
		});

		var revBtn = E('button', {
			'class': 'log-btn active',
			title: '倒序（最新在前）',
			id: 'pi-log-reverse',
			click: function(){
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
			id: 'pi-log-pause',
			click: function(){
				self.__paused = !self.__paused;
				var paused = self.__paused;
				this.classList.toggle('active', paused);
				this.innerHTML = paused ? ICONS.play : ICONS.pause;
				this.title = paused ? '恢复刷新' : '暂停刷新';
				if(!paused) self.__renderLog();
			}
		});
		pauseBtn.innerHTML = ICONS.pause;

		var clearBtn = E('button', {
			'class': 'log-btn danger',
			title: '清空日志',
			id: 'pi-log-clear',
			click: function(){
				return fs.write(LOG_FILE, '').then(function(){
					self.__logLines = [];
					self.__renderLog();
				}).catch(function(err){
					ui.addNotification(null, E('p', {}, '清空日志失败：' + (err.message || err)), 'danger');
				});
			}
		});
		clearBtn.innerHTML = ICONS.trash;

		var toolbar = E('div', { 'class': 'log-bar' }, [
			searchInput,
			revBtn,
			pauseBtn,
			clearBtn,
			E('span', { 'class': 'spacer' }),
			statusEl,
			E('span', { 'class': 'log-muted' }, '每 ' + (L.env.pollinterval || '3') + ' 秒刷新 ｜ 上限 500 行')
		]);

		var root = E('div', { 'class': 'cbi-map pi-log' }, [
			E('h2', {}, '日志'),
			E('div', { 'class': 'cbi-section' }, [ toolbar, logPane ])
		]);

		self.__pollHandle = poll.add(function(){
			return fs.read_direct(LOG_FILE, 'text').then(function(content){
				var lines = (content || '').split('\n');
				if(lines.length > self.__maxLines){
					lines = lines.slice(-self.__maxLines);
				}
				self.__logLines = lines;
				if(!self.__paused) self.__renderLog();
			}).catch(function(e){
				self.__logLines = [];
				if(e.toString().indexOf('NotFoundError') !== -1){
					self.__logLines = ['日志文件不存在'];
				} else {
					self.__logLines = ['错误: ' + (e.message || e)];
				}
				self.__renderLog();
			});
		});

		return root;
	},

	__renderLog: function(){
		var el = document.getElementById('pi-log-content');
		if(!el) return;
		var query = this.__searchQuery;
		var raw = query ? filterLines(this.__logLines, query) : this.__logLines;
		if(this.__reverse) raw = raw.slice().reverse();
		var html = [];
		for(var i = 0; i < raw.length; i++){
			if(!raw[i]) continue;
			var parsed = parseLine(raw[i]);
			html.push(buildLine(parsed, query));
		}
		el.innerHTML = html.length
			? html.join('\n')
			: '<div style="padding:.75rem;opacity:.5;font-style:italic">无匹配日志</div>';
		var pane = el.parentNode;
		if(pane && this.__reverse) pane.scrollTop = 0;
		var st = document.getElementById('pi-log-status');
		if(st){
			var shown = raw.filter(function(l){ return l.trim(); }).length;
			var total = this.__logLines.filter(function(l){ return l.trim(); }).length;
			st.innerHTML = query
				? '筛选 <strong>' + shown + '</strong> / ' + total + ' 行'
				: (this.__paused ? '共 <strong>' + total + '</strong> 行（已暂停）' : '共 <strong>' + total + '</strong> 行');
		}
	},

	handleReset: null,
	handleSave: null,
	handleSaveApply: null
});
