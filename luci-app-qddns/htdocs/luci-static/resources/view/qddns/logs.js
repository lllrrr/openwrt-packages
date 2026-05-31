'use strict';
'require view';
'require ui';
'require view.qddns.shared as qddns';

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return L.resolveDefault(qddns.listRules(), { providers: [], rules: [] }).then(function(data) {
			const normalized = qddns.normalizeRulesData(data);
			return Promise.all([
				normalized,
				L.resolveDefault(qddns.getLogs('system'), { ok: false, scope: 'system', content: '', entries: [] })
			]).then(function(results) {
				return {
					rules: results[0],
					logs: results[1]
				};
			});
		});
	},

	currentScope: 'system',

	getRuleLabel: function(rule) {
		return rule?.name || _('Unnamed rule');
	},

	getScopeLabel: function(scope) {
		if (scope === 'system')
			return _('System Logs');

		const rules = qddns.normalizeList(this.rulesData?.rules || []);
		for (let index = 0; index < rules.length; index++) {
			if (rules[index]?.id === scope)
				return this.getRuleLabel(rules[index]);
		}

		return _('Unnamed rule');
	},

	getScopeChoices: function() {
		const choices = [{ value: 'system', label: _('System Logs') }];
		qddns.sortNamedItems(this.rulesData?.rules || []).forEach(L.bind(function(rule) {
			choices.push({ value: rule.id, label: _('Rule') + ': ' + this.getRuleLabel(rule) });
		}, this));
		return choices;
	},

	loadLogs: function(scope) {
		return L.resolveDefault(qddns.getLogs(scope), { ok: false, scope: scope, content: '', entries: [] });
	},

	replaceLogsPanel: function() {
		const root = document.getElementById('qddns-logs-page');
		if (root)
			root.replaceWith(this.renderLogsPage());
	},

	refreshScope: function(scope, button) {
		return qddns.withBusyButton(button, L.bind(function() {
			return this.loadLogs(scope).then(L.bind(function(result) {
				if (qddns.isFailedResult(result)) {
					qddns.showFailureModal(_('Logs'), result, _('Unable to load logs for the selected scope.'));
					return result;
				}

				this.currentScope = result.scope || scope;
				this.logsData = result;
				this.replaceLogsPanel();
				return result;
			}, this)).catch(L.bind(function(err) {
				qddns.showFailureModal(_('Logs'), { error: qddns.extractResultMessage(err, _('Unable to load logs for the selected scope.')) }, _('Unable to load logs for the selected scope.'));
			}, this));
		}, this));
	},

	renderScopeControls: function() {
		const wrap = E('div', { class: 'qddns-actions' });
		const select = E('select', { class: 'cbi-input-select' });
		const reloadButton = E('button', { class: 'btn cbi-button cbi-button-action' }, [_('Load Logs')]);

		this.getScopeChoices().forEach(L.bind(function(choice) {
			const option = E('option', { value: choice.value }, [choice.label]);
			if (choice.value === this.currentScope)
				option.selected = true;
			select.appendChild(option);
		}, this));

		reloadButton.addEventListener('click', L.bind(function() {
			return this.refreshScope(select.value, reloadButton);
		}, this));

		wrap.appendChild(select);
		wrap.appendChild(reloadButton);
		return wrap;
	},

	renderLogEntries: function() {
		const entries = qddns.normalizeList(this.logsData?.entries);
		return qddns.renderTableSection(_('Log Entries'), [
			_('Timestamp'), _('Level'), _('Scope'), _('Detail')
		], entries.map(L.bind(function(entry) {
			return [
				entry.timestamp ? qddns.formatEpoch(entry.timestamp) : '-',
				entry.level || '-',
				this.getScopeLabel(entry.scope || 'system'),
				entry.message || '-'
			];
		}, this)), _('No logs available'));
	},

	formatLogLine: function(entry) {
		return '%s\t%s\t%s\t%s'.format(
			entry?.timestamp ? qddns.formatEpoch(entry.timestamp) : '-',
			entry?.level || '-',
			this.getScopeLabel(entry?.scope || 'system'),
			entry?.message || '-'
		);
	},

	renderLogContent: function() {
		const entries = qddns.normalizeList(this.logsData?.entries);
		const content = entries.length ? entries.map(L.bind(this.formatLogLine, this)).join('\n') : _('No logs available');

		return E('div', { class: 'cbi-section qddns-panel' }, [
			E('h3', {}, _('Log Output')),
			E('pre', { class: 'qddns-log-output' }, [content])
		]);
	},

	renderLogsPage: function() {
		qddns.ensureCommonStyle();

		const currentChoice = this.getScopeChoices().filter(L.bind(function(choice) {
			return choice.value === this.currentScope;
		}, this))[0];
		const currentLabel = currentChoice ? currentChoice.label : _('System Logs');

		return E('div', { id: 'qddns-logs-page' }, [
			qddns.renderPageHeader({
				title: _('Logs'),
				description: _('Review system logs or switch to a saved rule scope below. This page is read-only and does not expose rule execution or status actions.')
			}),
			E('div', { class: 'cbi-section qddns-panel' }, [
				E('h3', {}, _('Log Scope')),
				E('p', { class: 'cbi-section-descr' }, '%s: %s'.format(_('Current selection'), currentLabel)),
				this.renderScopeControls()
			]),
			this.renderLogEntries(),
			this.renderLogContent()
		]);
	},

	render: function(data) {
		this.rulesData = data.rules;
		this.logsData = data.logs;
		this.currentScope = data.logs?.scope || 'system';
		return this.renderLogsPage();
	}
});
