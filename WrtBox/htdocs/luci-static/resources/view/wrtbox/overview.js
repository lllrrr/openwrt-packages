'use strict';
'require view';
'require rpc';
'require poll';

var callGetStatus = rpc.declare({
	object: 'luci.wrtbox',
	method: 'get_status'
});

var callServiceAction = rpc.declare({
	object: 'luci.wrtbox',
	method: 'service_action',
	params: ['action']
});

function formatBytesKB(kb) {
	if (kb == null || isNaN(kb)) return '-';
	if (kb >= 1024 * 1024) return (kb / (1024 * 1024)).toFixed(2) + ' GB';
	if (kb >= 1024) return (kb / 1024).toFixed(1) + ' MB';
	return kb + ' KB';
}

function buildPanelUrl(st) {
	var sum = (st && st.active_summary) || {};
	if (sum.api_port) {
		var rawApiHost = (sum.api_host || '').trim();
		var apiHost = (!rawApiHost || rawApiHost === '0.0.0.0' || rawApiHost === '::' || rawApiHost === '[::]' || rawApiHost === '127.0.0.1')
			? window.location.hostname
			: rawApiHost.replace(/^\[|\]$/g, '');
		var apiPort = sum.api_port;
		var apiSecret = sum.api_secret || '';
		return 'http://' + apiHost + ':' + apiPort + '/dashboard/'
			+ (apiSecret ? ('?secret=' + encodeURIComponent(apiSecret)) : '')
			+ '#/groups';
	}

	if (sum.clash_port) {
		var rawHost = (sum.clash_host || '').trim();
		var host = (!rawHost || rawHost === '0.0.0.0' || rawHost === '::' || rawHost === '[::]' || rawHost === '127.0.0.1')
			? window.location.hostname
			: rawHost.replace(/^\[|\]$/g, '');
		var port = sum.clash_port;
		var secret = sum.clash_secret || '';
		var url = 'http://' + host + ':' + port + '/ui/';
		if (secret) {
			url += '?hostname=' + encodeURIComponent(host)
				+ '&port=' + encodeURIComponent(String(port))
				+ '&secret=' + encodeURIComponent(secret);
		}
		return url;
	}

	return 'http://' + window.location.hostname + ':9191/dashboard/#/groups';
}

return view.extend({
	overviewContainerEl: null,
	panelBtnEl: null,
	currentPanelUrl: '',
	serviceBusy: false,
	serviceBtns: null,

	load: function() {
		return callGetStatus();
	},

	setButtonsLoading: function(activeAction) {
		var self = this;
		if (!this.serviceBtns) return;
		var labels = {
			start: { idle: _('Start'), busy: _('Starting...') },
			stop: { idle: _('Stop'), busy: _('Stopping...') },
			restart: { idle: _('Restart'), busy: _('Restarting...') }
		};
		['start', 'stop', 'restart'].forEach(function(act) {
			var btn = self.serviceBtns[act];
			if (!btn) return;
			btn.innerHTML = '';
			if (activeAction) {
				btn.disabled = true;
				if (act === activeAction) {
					btn.classList.add('is-loading');
					btn.appendChild(E('span', { 'class': 'wrtbox-spinner' }));
					btn.appendChild(document.createTextNode(labels[act].busy));
				} else {
					btn.classList.remove('is-loading');
					btn.style.opacity = '0.55';
					btn.textContent = labels[act].idle;
				}
			} else {
				btn.disabled = false;
				btn.style.opacity = '';
				btn.classList.remove('is-loading');
				btn.textContent = labels[act].idle;
			}
		});
	},

	handleServiceAction: function(action) {
		var self = this;
		if (this.serviceBusy) return;
		this.serviceBusy = true;
		this.setButtonsLoading(action);

		// Instantly update UI status to busy state
		var heroBar = document.getElementById('ov-hero-bar');
		var statusLine = document.getElementById('ov-service-status-line');
		if (heroBar && statusLine) {
			var busyLabels = { start: _('Starting...'), stop: _('Stopping...'), restart: _('Restarting...') };
			heroBar.classList.remove('is-stopped');
			heroBar.classList.add('is-busy');
			statusLine.innerHTML = '';
			statusLine.appendChild(E('span', { 'class': 'ov-dot' }));
			statusLine.appendChild(E('span', { 'class': 'ov-status-text', 'style': 'color:#f39c12;' }, busyLabels[action] || _('Processing...')));
		}

		return callServiceAction(action).then(function(res) {
			return self.refreshStatus();
		}).catch(function(err) {
			// ignore or refresh
		}).then(function() {
			self.serviceBusy = false;
			self.setButtonsLoading(null);
		});
	},

	renderOverviewContent: function(st) {
		var self = this;
		if (!this.overviewContainerEl) return;

		var panelUrl = buildPanelUrl(st);
		this.currentPanelUrl = panelUrl;
		if (this.panelBtnEl) {
			this.panelBtnEl.href = panelUrl || '#';
		}

		var isRunning = !!st.running;
		var pid = st.pid;
		var mem = formatBytesKB(st.memory_kb);

		var statusDot = E('span', { 'class': 'ov-dot' });
		var statusText = isRunning ? _('Running') : _('Stopped');
		var statusTextColor = isRunning ? '#2ecc71' : '#e74c3c';
		var statusChildren = [statusDot, E('span', { 'class': 'ov-status-text', 'style': 'color:' + statusTextColor + ';' }, statusText)];
		if (isRunning && pid) {
			statusChildren.push(E('span', { 'class': 'ov-meta-pill' }, 'PID ' + pid));
			statusChildren.push(E('span', { 'class': 'ov-meta-pill' }, _('RAM: %s').format(mem)));
		}

		var heroBar = E('div', {
			'id': 'ov-hero-bar',
			'class': 'ov-hero' + (isRunning ? '' : ' is-stopped')
		}, [
			E('div', { 'class': 'ov-hero-left' }, [
				E('div', { 'id': 'ov-service-status-line', 'class': 'ov-status-line' }, statusChildren)
			]),
			E('div', { 'class': 'ov-actions' }, [
				this.serviceBtns.start,
				this.serviceBtns.stop,
				this.serviceBtns.restart,
				this.panelBtnEl
			])
		]);

		var coreVersionHtml = st.core_exists
			? E('div', { 'style': 'display:flex;align-items:center;gap:8px;flex-wrap:wrap;' }, [
				E('span', { 'style': 'color:#2ecc71;' }, st.core_version || st.core_tag || _('Installed')),
				st.core_channel === 'prerelease'
					? E('span', { 'class': 'badge badge-orange', 'style': 'margin:0;' }, _('Testing'))
					: E('span', { 'class': 'badge badge-green', 'style': 'margin:0;' }, _('Stable'))
			])
			: E('span', { 'style': 'color:#e67e22;' }, _('Not Installed'));

		var modesEl = E('span', {}, '-');
		if (st.active_summary && st.active_summary.modes && st.active_summary.modes.length > 0) {
			modesEl = E('div', { 'class': 'ov-chip-row' }, st.active_summary.modes.map(function(m) {
				return E('span', { 'class': 'ov-chip' }, m);
			}));
		}

		var gridEl = E('div', { 'class': 'ov-grid' }, [
			E('div', { 'class': 'ov-cell' }, [
				E('div', { 'class': 'ov-cell-label' }, _('Core Version')),
				coreVersionHtml
			]),
			E('div', { 'class': 'ov-cell' }, [
				E('div', { 'class': 'ov-cell-label' }, _('System Architecture')),
				E('div', { 'class': 'ov-cell-value' }, st.arch || '-'),
				E('div', { 'class': 'ov-cell-sub' }, _('Free: %s').format(formatBytesKB(st.free_kb)))
			]),
			E('div', { 'class': 'ov-cell' }, [
				E('div', { 'class': 'ov-cell-label' }, _('Profile')),
				E('div', { 'class': 'ov-cell-value' }, st.active_profile_name ? st.active_profile_name : E('em', {}, _('None')))
			]),
			E('div', { 'class': 'ov-cell' }, [
				E('div', { 'class': 'ov-cell-label' }, _('Inbounds')),
				modesEl
			])
		]);

		this.overviewContainerEl.innerHTML = '';
		this.overviewContainerEl.appendChild(heroBar);
		this.overviewContainerEl.appendChild(gridEl);
	},

	refreshStatus: function() {
		var self = this;
		return callGetStatus().then(function(st) {
			self.renderOverviewContent(st || {});
		});
	},

	render: function(st) {
		var self = this;
		st = st || {};

		var styleEl = E('style', {}, [
			'@keyframes wrtbox-spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }',
			'.wrtbox-btn { display:inline-flex; align-items:center; justify-content:center; gap:6px; transition: transform 0.12s ease, opacity 0.15s ease; }',
			'.wrtbox-btn:active:not(:disabled) { transform: scale(0.95); }',
			'.wrtbox-btn.is-loading { opacity:0.88; cursor:wait; }',
			'.wrtbox-spinner { width:12px; height:12px; border:2px solid currentColor; border-top-color:transparent; border-radius:50%; display:inline-block; animation:wrtbox-spin 0.7s linear infinite; }',
			'.ov-hero { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 16px; padding: 18px 20px; border-bottom: 1px solid var(--border, #33363f); background: linear-gradient(135deg, rgba(39, 174, 96, 0.08), rgba(94, 114, 228, 0.04)); }',
			'.ov-hero.is-stopped { background: linear-gradient(135deg, rgba(217, 83, 79, 0.08), transparent); }',
			'.ov-hero.is-busy { background: linear-gradient(135deg, rgba(230, 126, 34, 0.10), transparent); }',
			'.ov-hero-left { display: flex; flex-direction: column; gap: 6px; }',
			'.ov-status-line { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; }',
			'.ov-dot { width: 10px; height: 10px; border-radius: 50%; background: #27ae60; box-shadow: 0 0 0 4px rgba(39, 174, 96, 0.2); flex-shrink: 0; }',
			'.ov-hero.is-stopped .ov-dot { background: #d9534f; box-shadow: 0 0 0 4px rgba(217, 83, 79, 0.2); }',
			'.ov-hero.is-busy .ov-dot { background: #e67e22; box-shadow: 0 0 0 4px rgba(230, 126, 34, 0.22); }',
			'.ov-status-text { font-size: 18px; font-weight: 700; color: #2ecc71; }',
			'.ov-hero.is-stopped .ov-status-text { color: #e74c3c; }',
			'.ov-hero.is-busy .ov-status-text { color: #f39c12; }',
			'.ov-meta-pill { display: inline-flex; align-items: center; padding: 2px 9px; border-radius: 999px; font-size: 12px; background: rgba(255, 255, 255, 0.06); border: 1px solid var(--border, #33363f); color: #9aa0aa; }',
			'.ov-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }',
			'.ov-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); }',
			'.ov-cell { padding: 16px 20px; border-bottom: 1px solid var(--border, #33363f); border-right: 1px solid var(--border, #33363f); display: flex; flex-direction: column; gap: 8px; }',
			'.ov-cell:nth-child(2n) { border-right: none; }',
			'.ov-cell:nth-last-child(-n+2) { border-bottom: none; }',
			'.ov-cell-label { font-size: 12px; font-weight: 600; color: #9aa0aa; }',
			'.ov-cell-value { font-size: 15px; font-weight: 600; color: #e4e6eb; word-break: break-word; }',
			'.ov-cell-sub { font-size: 12px; color: #9aa0aa; line-height: 1.45; }',
			'.ov-chip-row { display: flex; flex-wrap: wrap; gap: 6px; }',
			'.ov-chip { display: inline-flex; align-items: center; padding: 3px 10px; border-radius: 5px; font-size: 12px; font-weight: 500; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; background: rgba(94, 114, 228, 0.14); border: 1px solid rgba(94, 114, 228, 0.28); color: #c9d2ff; }',
			'.badge { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 11px; font-weight: 500; color: #fff; }',
			'.badge-green { background: #27ae60; }',
			'.badge-orange { background: #e67e22; }',
			'@media (max-width: 720px) { .ov-grid { grid-template-columns: 1fr; } .ov-cell { border-right: none; border-bottom: 1px solid var(--border, #33363f) !important; } .ov-cell:last-child { border-bottom: none !important; } }'
		].join('\n'));

		this.serviceBtns = {
			start: E('button', {
				'type': 'button',
				'class': 'cbi-button cbi-button-positive wrtbox-btn',
				'click': function() { self.handleServiceAction('start'); }
			}, _('Start')),
			stop: E('button', {
				'type': 'button',
				'class': 'cbi-button cbi-button-negative wrtbox-btn',
				'click': function() { self.handleServiceAction('stop'); }
			}, _('Stop')),
			restart: E('button', {
				'type': 'button',
				'class': 'cbi-button cbi-button-apply wrtbox-btn',
				'click': function() { self.handleServiceAction('restart'); }
			}, _('Restart'))
		};

		this.panelBtnEl = E('a', {
			'id': 'wrtbox-panel-btn',
			'class': 'cbi-button cbi-button-action wrtbox-btn',
			'href': '#',
			'target': '_blank',
			'rel': 'noopener noreferrer',
			'style': 'text-decoration:none;white-space:nowrap;',
			'mousedown': function() {
				if (self.currentPanelUrl) self.panelBtnEl.href = self.currentPanelUrl;
			},
			'click': function(ev) {
				if (!self.currentPanelUrl || !/^https?:\/\//i.test(self.currentPanelUrl)) {
					ev.preventDefault();
					return;
				}
				self.panelBtnEl.href = self.currentPanelUrl;
			}
		}, _('Open Panel'));

		this.overviewContainerEl = E('div', { 'class': 'cbi-section' }, []);

		this.renderOverviewContent(st);

		poll.add(function() {
			return self.refreshStatus();
		}, 5);

		return E('div', { 'class': 'cbi-map' }, [
			styleEl,
			E('h2', { 'class': 'page-title-bar' }, _('Status')),
			this.overviewContainerEl
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
