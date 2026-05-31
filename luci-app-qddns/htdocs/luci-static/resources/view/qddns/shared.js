'use strict';
'require baseclass';
'require rpc';
'require ui';

const callOverview = rpc.declare({ object: 'qddns', method: 'get_overview', expect: {} });
const callRules = rpc.declare({ object: 'qddns', method: 'list_rules', expect: {} });
const callSources = rpc.declare({ object: 'qddns', method: 'list_sources', expect: { result: [] } });
const callInterfaces = rpc.declare({ object: 'qddns', method: 'list_interfaces', expect: {} });
const callDhcpv6Leases = rpc.declare({ object: 'qddns', method: 'list_dhcpv6_leases', params: ['mode'], expect: {} });
const callProbeSource = rpc.declare({ object: 'qddns', method: 'probe_source', params: ['id'], expect: {} });
const callProbeSourceDraft = rpc.declare({ object: 'qddns', method: 'probe_source_draft', params: ['name', 'type', 'family', 'address', 'interface', 'duid', 'iaid', 'mac', 'lease_file', 'hostname_hint', 'prefix_filter', 'probe_url'], expect: {} });
const callRunRule = rpc.declare({ object: 'qddns', method: 'run_rule', params: ['id'], expect: {} });
const callGetLogs = rpc.declare({ object: 'qddns', method: 'get_logs', params: ['scope'], expect: {} });
const callGetRuleStatus = rpc.declare({ object: 'qddns', method: 'get_rule_status', params: ['id'], expect: {} });
const QDDNS_COMMON_STYLE_ID = 'qddns-common-style';
const QDDNS_COMMON_STYLE = [
	':root{',
		'--qddns-space-1:0.25rem;',
		'--qddns-space-2:0.5rem;',
		'--qddns-space-3:0.75rem;',
		'--qddns-space-4:1rem;',
		'--qddns-space-5:1.5rem;',
		'--qddns-radius-sm:0.375rem;',
		'--qddns-radius-md:0.5rem;',
		'--qddns-border:rgba(127,127,127,0.24);',
		'--qddns-surface:rgba(127,127,127,0.08);',
		'--qddns-surface-strong:rgba(127,127,127,0.14);',
		'--qddns-positive:rgba(46,159,98,0.18);',
		'--qddns-positive-text:rgb(35,115,72);',
		'--qddns-negative:rgba(200,73,73,0.16);',
		'--qddns-negative-text:rgb(146,47,47);',
		'--qddns-warning:rgba(220,150,35,0.18);',
		'--qddns-warning-text:rgb(145,97,14);',
		'--qddns-neutral:rgba(127,127,127,0.12);',
		'--qddns-neutral-text:inherit;',
		'--qddns-table-min:56rem;',
		'--qddns-form-table-min:72rem;',
		'--qddns-cell-min:8rem;',
		'--qddns-cell-wide:14rem;',
		'--qddns-lease-meta-label:5.5rem;',
	'}',
	'.qddns-panel{margin-bottom:var(--qddns-space-4);padding:var(--qddns-space-4);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-md);background:var(--qddns-surface)}',
	'.qddns-page-header{display:grid;gap:var(--qddns-space-3)}',
	'.qddns-page-title{margin:0;font-size:1.35rem;font-weight:700;line-height:1.3}',
	'.qddns-page-desc{margin:0;line-height:1.5;opacity:0.78}',
	'.qddns-page-cta{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:var(--qddns-space-3)}',
	'.qddns-page-cta-text{display:grid;gap:var(--qddns-space-1);flex:1 1 22rem;min-width:min(100%,16rem)}',
	'.qddns-page-cta-text h3{margin:0}',
	'.qddns-page-cta-text p{margin:0}',
	'.qddns-wide-form .cbi-map>h2:empty{display:none}',
	'.qddns-actions{display:flex;flex-wrap:wrap;gap:var(--qddns-space-2);max-width:100%}',
	'.qddns-actions .cbi-button{margin:0;max-width:100%;white-space:normal}',
	'.qddns-actions .cbi-button.qddns-busy{opacity:0.7;cursor:progress}',
	'.qddns-badge{display:inline-flex;align-items:center;justify-content:center;min-height:2rem;padding:0 var(--qddns-space-3);border-radius:999px;font-size:0.8125rem;font-weight:600;line-height:1.4;border:1px solid transparent}',
	'.qddns-badge-positive{background:var(--qddns-positive);border-color:var(--qddns-positive);color:var(--qddns-positive-text)}',
	'.qddns-badge-negative{background:var(--qddns-negative);border-color:var(--qddns-negative);color:var(--qddns-negative-text)}',
	'.qddns-badge-warning{background:var(--qddns-warning);border-color:var(--qddns-warning);color:var(--qddns-warning-text)}',
	'.qddns-badge-neutral{background:var(--qddns-neutral);border-color:var(--qddns-border);color:var(--qddns-neutral-text)}',
	'.qddns-feedback{display:flex;flex-direction:column;gap:var(--qddns-space-2);padding:var(--qddns-space-4);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-sm);background:var(--qddns-surface)}',
	'.qddns-feedback-negative{border-color:var(--qddns-negative);background:var(--qddns-negative);color:var(--qddns-negative-text)}',
	'.qddns-empty-cell{text-align:center;opacity:0.72;padding:var(--qddns-space-4)}',
	'.qddns-log-output{margin:0;max-height:20rem;overflow:auto;padding:var(--qddns-space-4);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-sm);background:var(--qddns-surface-strong);white-space:pre-wrap;word-break:break-word}',
	'.qddns-table-wrap{width:100%;max-width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch}',
	'.qddns-table-wrap .qddns-table{width:100%;min-width:var(--qddns-table-min);margin-bottom:0;table-layout:auto}',
	'.qddns-table-wrap .qddns-table th,.qddns-table-wrap .qddns-table td{min-width:var(--qddns-cell-min);vertical-align:top;white-space:normal;word-break:normal;overflow-wrap:break-word}',
	'.qddns-table-wrap .qddns-table th{white-space:nowrap}',
	'.qddns-table-wrap .qddns-table th:first-child,.qddns-table-wrap .qddns-table td:first-child{white-space:nowrap}',
	'.qddns-table-wrap .qddns-table th:last-child,.qddns-table-wrap .qddns-table td:last-child{min-width:var(--qddns-cell-wide)}',
	'.qddns-wide-form{width:100%;max-width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch}',
	'.qddns-wide-form .cbi-section-table{min-width:var(--qddns-form-table-min);table-layout:auto}',
	'.qddns-wide-form .cbi-section-table th,.qddns-wide-form .cbi-section-table td{min-width:var(--qddns-cell-min);vertical-align:top;white-space:normal;word-break:normal;overflow-wrap:break-word}',
	'.qddns-wide-form .cbi-section-table th{white-space:nowrap}',
	'.qddns-wide-form .cbi-section-table td:first-child,.qddns-wide-form .cbi-section-table td:last-child{white-space:nowrap}',
		'.qddns-wide-form .cbi-section-table .cbi-input-text,.qddns-wide-form .cbi-section-table .cbi-input-password,.qddns-wide-form .cbi-section-table .cbi-input-select{min-width:var(--qddns-cell-min);max-width:var(--qddns-cell-wide)}',
		'.qddns-wide-form .cbi-section-table input[type="checkbox"]{min-width:auto}',
		'.qddns-lease-results{display:grid;justify-items:stretch;gap:var(--qddns-space-2);width:100%;max-width:100%;min-width:0;text-align:left}',
		'.qddns-lease-list{display:grid;justify-items:stretch;gap:var(--qddns-space-2);width:100%;max-width:100%;min-width:0}',
		'.qddns-lease-card{appearance:none;box-sizing:border-box;display:grid;align-items:start;justify-items:stretch;justify-content:stretch;gap:var(--qddns-space-2);width:100%!important;min-width:0;margin:0;padding:var(--qddns-space-3);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-sm);background:var(--qddns-surface);color:inherit;font:inherit;line-height:1.35;text-align:left!important;text-transform:none;cursor:pointer}',
		'.qddns-lease-card:hover,.qddns-lease-card:focus,.qddns-lease-card.is-selected{border-color:currentColor;background:var(--qddns-surface-strong)}',
		'.qddns-lease-head{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:start;gap:var(--qddns-space-2);width:100%;justify-self:stretch;min-width:0;text-align:left}',
		'.qddns-lease-title{justify-self:start;min-width:0;font-weight:600;text-align:left;overflow-wrap:anywhere}',
		'.qddns-lease-action{justify-self:end;max-width:100%;padding:0.1rem 0.4rem;border-radius:999px;background:var(--qddns-surface-strong);font-size:0.9em;line-height:1.35;opacity:0.85;text-align:center;white-space:nowrap}',
		'.qddns-lease-meta{display:grid;grid-template-columns:1fr;gap:var(--qddns-space-1);width:100%;justify-self:stretch;min-width:0;text-align:left}',
		'.qddns-lease-meta-item{display:grid;grid-template-columns:minmax(var(--qddns-lease-meta-label),max-content) minmax(0,1fr);gap:var(--qddns-space-1);width:100%;justify-self:stretch;min-width:0;text-align:left;overflow-wrap:break-word;word-break:normal}',
		'.qddns-lease-meta-label{min-width:var(--qddns-lease-meta-label);opacity:0.72}',
		'.qddns-lease-meta-value{min-width:0;overflow-wrap:anywhere;word-break:normal;white-space:pre-wrap;text-align:left}',
		'@media (max-width: 768px){',
			':root{--qddns-table-min:48rem;--qddns-form-table-min:64rem}',
			'.qddns-panel{padding:var(--qddns-space-3)}',
	'}'
].join('');

function normalizeList(items) {
	return Array.isArray(items) ? items : [];
}

function isElement(node, tagName) {
	return node && node.nodeType === 1 && node.tagName && node.tagName.toLowerCase() === tagName;
}

function statusLabel(status) {
	const value = String(status || '').toLowerCase();

	switch (value) {
	case 'running':
		return _('Running');
	case 'stopped':
		return _('Stopped');
	case 'enabled':
		return _('Enabled');
	case 'disabled':
		return _('Disabled');
	case 'unknown':
		return _('Unknown');
	case 'ok':
		return _('OK');
	case 'success':
		return _('Success');
	case 'synced':
		return _('Synced');
	case 'updated':
		return _('Updated');
	case 'unchanged':
		return _('Unchanged');
	case 'error':
		return _('Error');
	case 'failed':
		return _('Failed');
	case 'invalid':
		return _('Invalid');
	case 'pending':
		return _('Pending');
	case 'testing':
		return _('Testing');
	case 'queued':
		return _('Queued');
	case 'warning':
		return _('Warning');
	default:
		return status || '';
	}
}

return baseclass.extend({
	overview: callOverview,
	listRules: callRules,
	listSources: callSources,
	listInterfaces: callInterfaces,
	listDhcpv6Leases: callDhcpv6Leases,
	probeSource: callProbeSource,
	probeSourceDraft: function(source) {
		source = source || {};
		return callProbeSourceDraft(
			source.name || '',
			source.type || '',
			source.family || '',
			source.address || '',
			L.toArray(source.interfaceName || source.interface).join(','),
			source.duid || '',
			source.iaid || '',
			source.mac || '',
			source.leaseFile || source.lease_file || '',
			source.hostnameHint || source.hostname_hint || '',
			source.prefixFilter || source.prefix_filter || '',
			source.probeUrl || source.probe_url || ''
		);
	},
	runRule: callRunRule,
	getLogs: callGetLogs,
	getRuleStatus: callGetRuleStatus,

	normalizeList: normalizeList,

	normalizeInterfaces: function(data) {
		const values = Array.isArray(data) ? data : data?.interfaces;

		return normalizeList(values).map(function(item) {
			return (typeof item == 'string') ? { name: item } : item;
		}).filter(function(item) {
			return item?.name;
		}).sort(function(left, right) {
			return left.name.localeCompare(right.name);
		});
	},

	ensureCommonStyle: function() {
		if (document.getElementById(QDDNS_COMMON_STYLE_ID))
			return;

		document.head.appendChild(E('style', { id: QDDNS_COMMON_STYLE_ID }, [QDDNS_COMMON_STYLE]));
	},

	normalizeRulesData: function(data) {
		return {
			providers: normalizeList(data?.providers),
			rules: normalizeList(data?.rules)
		};
	},

	normalizeCatalogState: function(rules, sources) {
		const sourceList = Array.isArray(sources) ? sources : sources?.result;

		return {
			rules: this.normalizeRulesData(rules),
			sources: normalizeList(sourceList)
		};
	},

	formatEpoch: function(epoch) {
		if (!epoch)
			return _('N/A');

		const date = new Date(epoch * 1000);
		return isNaN(date.getTime()) ? String(epoch) : date.toLocaleString();
	},

	sortNamedItems: function(items) {
		return normalizeList(items).slice().sort(function(left, right) {
			const leftLabel = left?.name || '';
			const rightLabel = right?.name || '';
			return leftLabel.localeCompare(rightLabel);
		});
	},

	statusTone: function(status) {
		const value = String(status || '').toLowerCase();

		if (['running', 'enabled', 'ok', 'success', 'synced', 'updated'].indexOf(value) > -1)
			return 'positive';

		if (['stopped', 'disabled', 'error', 'failed', 'invalid'].indexOf(value) > -1)
			return 'negative';

		if (['unknown', 'pending', 'testing', 'queued', 'warning'].indexOf(value) > -1)
			return 'warning';

		return 'neutral';
	},

	renderBadge: function(label, tone) {
		return E('span', { class: 'qddns-badge qddns-badge-' + (tone || 'neutral') }, label || '-');
	},

	renderStatusBadge: function(status, fallback, toneStatus) {
		const label = statusLabel(status || fallback) || '-';
		return this.renderBadge(label, this.statusTone(toneStatus || status || fallback));
	},

	statusLabel: statusLabel,

	resultLabel: function(result) {
		return result ? statusLabel(result) : '';
	},

	renderLeaseMeta: function(label, value) {
		return E('span', { class: 'qddns-lease-meta-item' }, [
			E('span', { class: 'qddns-lease-meta-label' }, label + ': '),
			E('span', { class: 'qddns-lease-meta-value' }, value || '-')
		]);
	},

	renderLeaseCard: function(options) {
		options = options || {};

		const card = E('button', {
			type: 'button',
			class: 'qddns-lease-card',
			'aria-pressed': 'false',
			title: options.actionLabel || _('Fill from this lease')
		}, [
			E('span', { class: 'qddns-lease-head' }, [
				E('span', { class: 'qddns-lease-title' }, options.title || _('Unnamed host')),
				E('span', { class: 'qddns-lease-action' }, options.actionLabel || _('Fill from this lease'))
			]),
			E('span', { class: 'qddns-lease-meta' }, normalizeList(options.meta))
		]);

		if (typeof options.onSelect == 'function') {
			card.addEventListener('click', function() {
				const selected = card.parentNode?.querySelector('.qddns-lease-card.is-selected');

				if (selected) {
					selected.classList.remove('is-selected');
					selected.setAttribute('aria-pressed', 'false');
				}

				card.classList.add('is-selected');
				card.setAttribute('aria-pressed', 'true');
				options.onSelect(card);
			});
		}

		return card;
	},

	extractResultMessage: function(result, fallback) {
		if (typeof result == 'string' && result)
			return result;

		return result?.error || result?.detail || result?.message || fallback || _('Request failed');
	},

	isFailedResult: function(result) {
		return !result || result.ok === false;
	},

	isProbeableSourceType: function(sourceType) {
		return ['local_addr', 'interface', 'dhcpv6_duid', 'dhcpv6_mac', 'public_probe'].indexOf(sourceType) > -1;
	},

	withBusyButton: function(button, handler) {
		button.disabled = true;
		button.classList.add('qddns-busy');

		return Promise.resolve(handler()).finally(function() {
			button.disabled = false;
			button.classList.remove('qddns-busy');
		});
	},

	renderModalClose: function() {
		return E('div', { class: 'right' }, [
			E('button', { class: 'btn cbi-button', click: ui.hideModal }, [_('Close')])
		]);
	},

	showFailureModal: function(title, result, fallback) {
		ui.showModal(title, [
			E('div', { class: 'qddns-feedback qddns-feedback-negative' }, [
				E('strong', {}, _('Request failed')),
				E('p', {}, this.extractResultMessage(result, fallback))
			]),
			this.renderModalClose()
		]);
	},

	showInfoModal: function(title, nodes) {
		ui.showModal(title, nodes.concat([this.renderModalClose()]));
	},

	handleReadAction: function(button, title, handler, onSuccess, fallback) {
		return this.withBusyButton(button, L.bind(function() {
			return Promise.resolve(handler()).then(L.bind(function(result) {
				if (this.isFailedResult(result)) {
					this.showFailureModal(title, result, fallback);
					return result;
				}

				onSuccess(result);
				return result;
			}, this)).catch(L.bind(function(err) {
				this.showFailureModal(title, { error: this.extractResultMessage(err, fallback) }, fallback);
			}, this));
		}, this));
	},

	handleMutationAction: function(button, title, handler, onSuccess, fallback, refresh) {
		const refreshHandler = (typeof refresh == 'function') ? refresh : function() { return Promise.resolve(); };

		return this.withBusyButton(button, L.bind(function() {
			return Promise.resolve(handler()).then(L.bind(function(result) {
				return Promise.resolve(refreshHandler()).then(L.bind(function() {
					if (this.isFailedResult(result)) {
						this.showFailureModal(title, result, fallback);
						return result;
					}

					onSuccess(result);
					return result;
				}, this));
			}, this)).catch(L.bind(function(err) {
				return Promise.resolve(refreshHandler()).then(L.bind(function() {
					this.showFailureModal(title, { error: this.extractResultMessage(err, fallback) }, fallback);
				}, this));
			}, this));
		}, this));
	},

	// options: { title: string, description?: string }
	renderPageHeader: function(options) {
		this.ensureCommonStyle();

		options = options || {};

		const header = [
			E('h2', { class: 'qddns-page-title' }, options.title || _('QDDNS'))
		];

		if (options.description)
			header.push(E('p', { class: 'qddns-page-desc' }, options.description));

		return E('div', { class: 'cbi-section qddns-panel qddns-page-header' }, header);
	},

	renderTableSection: function(title, headers, rows, emptyText) {
		return E('div', { class: 'cbi-section qddns-panel' }, [
			E('h3', {}, title),
			this.renderTable(headers, rows, emptyText)
		]);
	},

	renderTable: function(headers, rows, emptyText) {
		this.ensureCommonStyle();

		const tableRows = normalizeList(rows);
		const tableChildren = [
			E('tr', { class: 'tr cbi-section-table-titles' }, headers.map(function(header) {
				return E('th', {}, header);
			}))
		];

		if (tableRows.length) {
			tableRows.forEach(function(row) {
				if (isElement(row, 'tr')) {
					tableChildren.push(row);
					return;
				}

				const cells = Array.isArray(row) ? row : [row];
				tableChildren.push(E('tr', {}, cells.map(function(cell) {
					return isElement(cell, 'td') ? cell : E('td', {}, Array.isArray(cell) ? cell : [cell]);
				})));
			});
		} else {
			tableChildren.push(E('tr', {}, [
				E('td', { colspan: headers.length, class: 'qddns-empty-cell' }, emptyText)
			]));
		}

		return E('div', { class: 'qddns-table-wrap' }, [
			E('table', { class: 'table cbi-section-table qddns-table' }, tableChildren)
		]);
	}
});
