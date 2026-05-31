'use strict';
'require view';
'require poll';
'require view.qddns.shared as qddns';

const QDDNS_STYLE_ID = 'qddns-overview-style';
const QDDNS_STYLE = [
	'.qddns-dashboard{margin-bottom:var(--qddns-space-5)}',
	'.qddns-dashboard .qddns-panel,.qddns-dashboard .qddns-card{margin-bottom:var(--qddns-space-4)}',
	'.qddns-cards{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:var(--qddns-space-3)}',
	'.qddns-card{padding:var(--qddns-space-4);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-md);background:var(--qddns-surface);display:flex;flex-direction:column;gap:var(--qddns-space-2);min-height:6rem;justify-content:center}',
	'.qddns-card-label{font-size:0.75rem;opacity:0.72}',
	'.qddns-card-value{font-size:1.5rem;font-weight:600;line-height:1.3;word-break:break-word}',
	'.qddns-ip-synced{display:inline-flex;align-items:center;gap:var(--qddns-space-2);white-space:nowrap}',
	'.qddns-ip-synced .qddns-badge{font-size:0.7rem;padding:0 var(--qddns-space-2)}',
	'.qddns-ip-diff{display:grid;gap:0.15rem}',
	'.qddns-ip-diff-old{opacity:0.6;font-size:0.85em;text-decoration:line-through}',
	'@media (max-width: 1100px){',
		'.qddns-cards{grid-template-columns:repeat(3,minmax(0,1fr))}',
	'}',
	'@media (max-width: 768px){',
		'.qddns-card{padding:var(--qddns-space-3)}',
		'.qddns-card-value{font-size:1.25rem}',
		'.qddns-cards{grid-template-columns:repeat(2,minmax(0,1fr))}',
	'}'
].join('');

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	loadRuntimeState: function() {
		return L.resolveDefault(qddns.overview(), {});
	},

	load: function() {
		return Promise.all([
			this.loadRuntimeState(),
			L.resolveDefault(qddns.listRules(), { rules: [], providers: [] })
		]).then(function(data) {
			var rulesData = qddns.normalizeRulesData(data[1]);
			return {
				overview: data[0] || {},
				rules: rulesData.rules,
				providers: rulesData.providers
			};
		});
	},

	buildRuleLabels: function(rules) {
		const labels = {};

		qddns.normalizeList(rules).forEach(function(rule) {
			if (rule?.id)
				labels[rule.id] = String(rule.name || '').trim() || _('Unnamed rule');
		});

		return labels;
	},

	ruleLabel: function(ruleId) {
		return this.ruleLabels?.[ruleId] || _('Unnamed rule');
	},

	ruleProvider: function(ruleId) {
		var rules = qddns.normalizeList(this.rulesData);
		for (var i = 0; i < rules.length; i++) {
			if (rules[i]?.id === ruleId)
				return this.providerLabel(rules[i].provider);
		}
		return '-';
	},

	providerLabel: function(providerId) {
		var providers = qddns.normalizeList(this.providersData);
		for (var i = 0; i < providers.length; i++) {
			if (providers[i]?.id === providerId)
				return providers[i].name || _('Unnamed provider');
		}
		return _('Unnamed provider');
	},

	ensureDashboardStyle: function() {
		qddns.ensureCommonStyle();

		if (document.getElementById(QDDNS_STYLE_ID))
			return;

		document.head.appendChild(E('style', { id: QDDNS_STYLE_ID }, [QDDNS_STYLE]));
	},

	replaceDashboard: function() {
		const root = document.getElementById('qddns-dashboard');
		if (root)
			root.replaceWith(this.renderDashboard(this.runtimeData));
	},

	refreshRuntime: function() {
		return this.loadRuntimeState().then(L.bind(function(overview) {
			this.runtimeData = overview || {};
			this.replaceDashboard();
			return this.runtimeData;
		}, this));
	},

	renderDashboardIntro: function() {
		return qddns.renderPageHeader({
			title: _('Overview'),
			description: _('Runtime widgets refresh automatically. Use the dedicated rules, settings, and logs pages for actions, configuration, and diagnostics.')
		});
	},

	renderOverviewCards: function(overview) {
		const status = overview.status || {};
		const enabled = overview.main?.enabled;
		const rulesText = '%s / %s'.format(String(status.enabled_rules || 0), String(status.rules || 0));
		const cards = [
			{ label: _('Daemon'), value: qddns.renderStatusBadge(status.running ? _('Running') : _('Stopped'), null, status.running ? 'running' : 'stopped') },
			{ label: _('Version'), value: status.version || '-' },
			{ label: _('Rules (enabled / total)'), value: rulesText },
			{ label: _('Sources'), value: String(status.sources || 0) },
			{ label: _('Providers'), value: String(status.providers || 0) }
		];

		return E('div', { class: 'qddns-cards' }, cards.map(function(card) {
			return E('div', { class: 'cbi-section qddns-card' }, [
				E('div', { class: 'qddns-card-label' }, card.label),
				E('div', { class: 'qddns-card-value' }, Array.isArray(card.value) ? card.value : [card.value])
			]);
		}));
	},

	renderIpCell: function(currentIp, remoteIp) {
		const current = currentIp || '-';
		const remote = remoteIp || '-';

		if (!currentIp && !remoteIp)
			return E('span', {}, '-');

		if (current === remote || !remoteIp)
			return E('span', { class: 'qddns-ip-synced' }, [
				current,
				qddns.renderBadge(_('Synced'), 'positive')
			]);

		return E('span', { class: 'qddns-ip-diff' }, [
			E('span', {}, current),
			E('span', { class: 'qddns-ip-diff-old' }, remote)
		]);
	},

	renderRecentResults: function(overview) {
		const results = overview.status?.recent_results || [];

		return qddns.renderTableSection(_('Recent Results'), [
			_('Rule'), _('Provider'), _('Status'), _('IP'), _('Result'), _('Last Check')
		], results.map(L.bind(function(item) {
				return [
					this.ruleLabel(item.id),
					this.ruleProvider(item.id),
					qddns.renderStatusBadge(item.status, _('Unknown')),
					this.renderIpCell(item.current_ip, item.remote_ip),
					qddns.resultLabel(item.last_result) || item.last_error || '-',
					item.last_check ? qddns.formatEpoch(item.last_check) : '-'
				];
			}, this)), _('No runtime results yet'));
	},

	renderDashboard: function(data) {
		this.ensureDashboardStyle();

		return E('div', { id: 'qddns-dashboard', class: 'qddns-dashboard' }, [
			this.renderDashboardIntro(),
			this.renderOverviewCards(data || {}),
			this.renderRecentResults(data || {})
		]);
	},

	render: function(data) {
		this.runtimeData = data?.overview || {};
		this.ruleLabels = this.buildRuleLabels(data?.rules);
		this.rulesData = data?.rules || [];
		this.providersData = data?.providers || [];
		this.ensureDashboardStyle();

		poll.add(L.bind(function() {
			return this.refreshRuntime();
		}, this));

		return this.renderDashboard(this.runtimeData);
	}
});
