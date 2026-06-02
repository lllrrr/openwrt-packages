'use strict';
'require view';
'require uci';
'require ui';
'require form';
'require network';
'require tools.widgets as widgets';
'require view.qddns.shared as qddns';

const QDDNS_STYLE_ID = 'qddns-rules-style';
const QDDNS_STYLE = [
	':root{',
		'--qddns-rule-console-min:46rem;',
		'--qddns-rule-toggle-width:6.5rem;',
		'--qddns-rule-type-width:8rem;',
		'--qddns-rule-action-min:10rem;',
		'--qddns-rule-wizard-width:min(64rem,94vw);',
		'--qddns-rule-wizard-field-min:14rem;',
		'--qddns-rule-wizard-meta-label:5.5rem;',
	'}',
	'.qddns-rules-page{margin-bottom:var(--qddns-space-4)}',
	'.qddns-table-wrap{overflow-x:auto}',
	'.qddns-table-wrap .table{margin-bottom:0}',
	'.qddns-rules-console-table .qddns-table{min-width:var(--qddns-rule-console-min);table-layout:fixed}',
	'.qddns-rules-console-table .qddns-table th,.qddns-rules-console-table .qddns-table td{min-width:0;overflow-wrap:anywhere}',
	'.qddns-rules-console-table .qddns-table th:first-child,.qddns-rules-console-table .qddns-table td:first-child{white-space:normal}',
	'.qddns-rules-console-table .qddns-table th:last-child,.qddns-rules-console-table .qddns-table td:last-child{width:var(--qddns-rule-action-min);min-width:var(--qddns-rule-action-min)}',
	'.qddns-rules-console-table .qddns-actions{flex-wrap:nowrap}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table th,.qddns-rules-form.qddns-wide-form .cbi-section-table td{vertical-align:middle;white-space:normal;overflow-wrap:anywhere;word-break:break-word}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table th{white-space:nowrap}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table th:first-child,.qddns-rules-form.qddns-wide-form .cbi-section-table td:first-child{width:auto;white-space:normal;font-weight:600}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table th:nth-child(2),.qddns-rules-form.qddns-wide-form .cbi-section-table td:nth-child(2){width:var(--qddns-rule-toggle-width);white-space:nowrap;text-align:center}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table th:nth-child(3),.qddns-rules-form.qddns-wide-form .cbi-section-table td:nth-child(3){width:var(--qddns-rule-type-width);white-space:nowrap}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table td:last-child{width:var(--qddns-rule-action-min);min-width:var(--qddns-rule-action-min);white-space:nowrap;text-align:left}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table .cbi-button{margin:0 var(--qddns-space-1) var(--qddns-space-1) 0}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table .cbi-input-text,.qddns-rules-form.qddns-wide-form .cbi-section-table .cbi-input-select{width:100%;min-width:0;max-width:100%}',
	'.qddns-rules-form.qddns-wide-form .cbi-section-table input[type="checkbox"]{min-width:auto}',
	'.qddns-rule-wizard-primary{font-size:1rem;font-weight:700;padding:var(--qddns-space-3) var(--qddns-space-4)}',
	'.modal.qddns-rule-wizard-dialog{align-items:stretch;width:var(--qddns-rule-wizard-width);max-width:94vw;max-height:calc(100vh - var(--qddns-space-4));overflow:auto}',
	'.modal.qddns-rule-wizard-dialog>h4{box-sizing:border-box;width:100%;margin:0 0 var(--qddns-space-3);padding:0;text-align:left;font-size:1.2rem;font-weight:700;line-height:1.3!important}',
	'.qddns-rule-wizard-modal{box-sizing:border-box;display:grid;align-items:stretch;justify-items:stretch;gap:var(--qddns-space-4);width:100%;max-width:100%;min-width:0;text-align:left;line-height:1.45}',
	'.qddns-rule-wizard-steps{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:var(--qddns-space-2)}',
	'.qddns-rule-wizard-step{display:grid;align-content:start;gap:var(--qddns-space-1);min-width:0;padding:var(--qddns-space-2) var(--qddns-space-3);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-sm);background:var(--qddns-neutral);text-align:left}',
	'.qddns-rule-wizard-step.is-active{font-weight:700;background:var(--qddns-surface-strong);border-color:currentColor}',
	'.qddns-rule-wizard-step.is-complete{border-color:var(--qddns-positive);background:var(--qddns-positive);color:var(--qddns-positive-text)}',
	'.qddns-rule-wizard-step small{font-weight:400;opacity:0.72;line-height:1.35}',
	'.qddns-rule-wizard-panel{display:grid;justify-items:stretch;gap:var(--qddns-space-3);width:100%;max-width:100%;min-width:0;justify-self:stretch;text-align:left}',
	'.qddns-rule-wizard-panel h4{justify-self:start;margin:0;padding:0;text-align:left;font-size:1.05rem;font-weight:700;line-height:1.35!important}',
	'.qddns-rule-wizard-lead{margin:0;max-width:52rem;color:inherit;opacity:0.82;text-align:left}',
	'.qddns-rule-wizard-path-bar{display:grid;align-items:end;grid-template-columns:minmax(0,1fr) minmax(14rem,18rem);gap:var(--qddns-space-3);width:100%;min-width:0;text-align:left}',
	'.qddns-rule-wizard-path-copy{display:grid;gap:var(--qddns-space-1);min-width:0;text-align:left}',
	'.qddns-rule-wizard-section{display:grid;gap:var(--qddns-space-3);box-sizing:border-box;width:100%;min-width:0;padding:var(--qddns-space-3);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-sm);background:rgba(127,127,127,0.045);text-align:left}',
	'.qddns-rule-wizard-section-head{display:grid;grid-template-columns:1fr;align-items:start;gap:var(--qddns-space-1);min-width:0;text-align:left}',
	'.qddns-rule-wizard-section-title{font-weight:700;line-height:1.35;text-align:left}',
	'.qddns-rule-wizard-section-desc{min-width:0;opacity:0.72;overflow-wrap:anywhere;text-align:left}',
	'.qddns-rule-wizard-grid{display:grid;align-items:start;justify-items:stretch;grid-template-columns:repeat(auto-fit,minmax(min(100%,var(--qddns-rule-wizard-field-min)),1fr));gap:var(--qddns-space-3);width:100%;min-width:0}',
	'.qddns-rule-wizard-grid-narrow{grid-template-columns:minmax(0,18rem);max-width:18rem}',
	'.qddns-rule-wizard-field{display:flex;flex-direction:column;gap:var(--qddns-space-1);min-width:0;text-align:left}',
	'.qddns-rule-wizard-field label{font-weight:600;line-height:1.35;text-align:left}',
	'.qddns-rule-wizard-field .cbi-value-description{margin:0;text-align:left}',
	'.qddns-rule-wizard-field .cbi-input-text,.qddns-rule-wizard-field .cbi-input-select{box-sizing:border-box;width:100%;min-width:0;max-width:100%}',
	'.qddns-rule-wizard-field .cbi-dropdown{box-sizing:border-box;width:100%;min-width:0;max-width:100%}',
	'.qddns-rule-wizard-field .cbi-input-select[data-auto-record-type="1"]{opacity:0.82}',
	'.qddns-rule-wizard-source-panel{display:grid;justify-items:stretch;gap:var(--qddns-space-3);width:100%;min-width:0;text-align:left}',
	'.qddns-rule-wizard-source-actions{align-items:center;justify-content:flex-start}',
	'.qddns-rule-wizard-detection-grid{display:grid;align-items:end;justify-items:stretch;grid-template-columns:minmax(0,1fr) minmax(10rem,14rem) max-content;gap:var(--qddns-space-3);width:100%;min-width:0}',
	'.qddns-rule-wizard-probe-action-field{align-self:end;align-items:center;justify-content:flex-start;min-height:2.4rem}',
	'.qddns-rule-wizard-switch{display:flex;align-items:center;gap:var(--qddns-space-2);min-height:2.4rem}',
	'.qddns-rule-wizard-summary{display:grid;gap:var(--qddns-space-2);padding:var(--qddns-space-3);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-sm);background:var(--qddns-surface-strong)}',
	'.qddns-rule-wizard-summary-row{display:grid;grid-template-columns:minmax(var(--qddns-rule-wizard-meta-label),max-content) minmax(0,1fr);gap:var(--qddns-space-2);min-width:0;text-align:left}',
	'.qddns-rule-wizard-summary-label{opacity:0.72}',
	'.qddns-rule-wizard-summary-value{min-width:0;overflow-wrap:anywhere}',
	'.qddns-rule-wizard-source-status{display:grid;align-content:center;justify-items:start;box-sizing:border-box;width:100%;min-height:2.4rem;min-width:0;padding:0 var(--qddns-space-3);border:1px solid var(--qddns-border);border-radius:var(--qddns-radius-sm);background:var(--qddns-surface);text-align:left}',
	'.qddns-rule-wizard-source-ip{display:block;max-width:100%;font-weight:700;line-height:1.35;overflow-wrap:anywhere;text-align:left}',
	'.qddns-rule-wizard-source-ip[data-tone="warning"]{opacity:0.78}',
	'.qddns-rule-wizard-source-ip[data-tone="negative"]{color:var(--qddns-negative-text)}',
	'.qddns-rule-wizard-feedback{box-sizing:border-box;width:100%;max-width:100%;justify-self:stretch;margin:0;min-height:2.25rem;padding:var(--qddns-space-2) var(--qddns-space-3);border:1px solid transparent;border-radius:var(--qddns-radius-sm);text-align:left}',
	'.qddns-rule-wizard-feedback[data-source-ip-guide="idle"],.qddns-rule-wizard-feedback[data-source-ip-guide="ready"]{min-height:0;padding:0;border-color:transparent;background:transparent;opacity:0.72}',
	'.qddns-rule-wizard-feedback.alert-message.warning{border-color:var(--qddns-warning);background:var(--qddns-warning);color:var(--qddns-warning-text)}',
	'.qddns-rule-wizard-modal .qddns-actions{justify-content:flex-end}',
	'.qddns-rule-wizard-modal .qddns-rule-wizard-source-actions{justify-content:flex-start}',
	'.qddns-rule-wizard-modal .qddns-rule-wizard-probe-action-field{justify-content:flex-start}',
	'.qddns-rule-wizard-footer-actions{width:100%;max-width:100%;justify-self:stretch;justify-content:flex-end}',
	'.qddns-modal-meta{display:grid;gap:var(--qddns-space-2);margin-bottom:var(--qddns-space-4)}',
	'.qddns-modal-meta p{margin:0}',
	'@media (max-width: 768px){',
		':root{--qddns-rule-console-min:40rem;--qddns-rule-action-min:8.5rem}',
		'.qddns-rule-wizard-grid-narrow{max-width:100%}',
		'.qddns-rule-wizard-path-bar{grid-template-columns:1fr}',
		'.qddns-rule-wizard-steps{grid-template-columns:1fr}',
		'.qddns-rule-wizard-detection-grid{grid-template-columns:1fr}',
		'.qddns-rule-wizard-probe-action-field{justify-content:flex-start}',
	'}'
].join('');

return view.extend({
	loadRuntimeState: function() {
		return L.resolveDefault(qddns.overview(), {});
	},

	loadCatalogState: function() {
		return Promise.all([
			L.resolveDefault(qddns.listRules(), { providers: [], rules: [] }),
			L.resolveDefault(qddns.listSources(), { result: [] }),
			uci.load('qddns'),
			L.resolveDefault(qddns.listInterfaces(), { interfaces: [] }),
			L.resolveDefault(network.getDevices(), [])
		]).then(function(data) {
			const catalog = qddns.normalizeCatalogState(data[0], data[1]);
			catalog.interfaces = qddns.normalizeInterfaces(data[3]);
			catalog.interfaceDevices = qddns.normalizeList(data[4]);
			return catalog;
		});
	},

	buildPageData: function(runtime, catalog) {
		return {
			runtime: runtime || {},
			catalog: {
				rules: qddns.normalizeRulesData(catalog?.rules),
				sources: qddns.normalizeList(catalog?.sources),
				interfaces: qddns.normalizeInterfaces(catalog?.interfaces),
				interfaceDevices: qddns.normalizeList(catalog?.interfaceDevices)
			}
		};
	},

	load: function() {
		return Promise.all([
			this.loadRuntimeState(),
			this.loadCatalogState()
		]).then(L.bind(function(data) {
			return this.buildPageData(data[0], data[1]);
		}, this));
	},

	ensurePageStyle: function() {
		qddns.ensureCommonStyle();

		if (document.getElementById(QDDNS_STYLE_ID))
			return;

		document.head.appendChild(E('style', { id: QDDNS_STYLE_ID }, [QDDNS_STYLE]));
	},

	getRuleStates: function() {
		return this.pageData?.runtime?.status?.rule_states || {};
	},


	nextNumericSectionId: function() {
		const used = {};
		const sections = uci.sections('qddns') || [];

		sections.forEach(function(section) {
			used[section['.name']] = true;
		});

		for (let index = 1; true; index++) {
			const candidate = String(index);
			if (!used[candidate])
				return candidate;
		}
	},

	getRuleLabel: function(rule) {
		return rule?.name || _('Unnamed rule');
	},

	findById: function(items, id) {
		const list = qddns.normalizeList(items);
		for (let index = 0; index < list.length; index++) {
			if (list[index]?.id === id)
				return list[index];
		}
		return null;
	},

	getSourceLabel: function(sourceId) {
		const source = this.findById(this.pageData?.catalog?.sources, sourceId);
		return source?.name || _('Unnamed source');
	},

	getProviderLabel: function(providerId) {
		const provider = this.findById(this.pageData?.catalog?.rules?.providers, providerId);
		return provider?.name || _('Unnamed provider');
	},

	renderWizardField: function(label, control, description) {
		const nodes = [
			E('label', {}, label),
			control
		];

		if (description)
			nodes.push(E('div', { class: 'cbi-value-description' }, description));

		return E('div', { class: 'qddns-rule-wizard-field' }, nodes);
	},

	renderWizardSelect: function(choices, emptyText, itemFallback) {
		const select = E('select', { class: 'cbi-input-select' });
		const list = qddns.normalizeList(choices);

		if (!list.length) {
			select.appendChild(E('option', { value: '' }, [emptyText]));
			select.disabled = true;
			return select;
		}

		list.forEach(function(choice) {
			select.appendChild(E('option', { value: choice.id }, [choice.name || itemFallback || _('Unnamed item')]));
		});

		return select;
	},

	renderWizardInterfaceSelect: function(catalog, multiple) {
		const choices = {};
		const order = [];

		function addChoice(name, node) {
			if (!name || name === 'lo' || choices[name])
				return;

			choices[name] = node || E('span', {
				title: _('Select this interface only when it is the WAN/upstream interface for this source.')
			}, [name]);
			order.push(name);
		}

		qddns.normalizeList(catalog?.interfaceDevices).forEach(function(device) {
			const name = device?.getName?.();
			const type = device?.getType?.() || 'ethernet';
			const networks = qddns.normalizeList(device?.getNetworks?.()).map(function(net) {
				return net?.getName?.();
			}).filter(function(netName) {
				return netName;
			});
			const label = E([
				E('img', {
					title: device?.getI18n?.() || name,
					src: L.resource('icons/%s%s.svg'.format(type, device?.isUp?.() ? '' : '_disabled'))
				}),
				E('span', { class: 'hide-open' }, [name]),
				E('span', { class: 'hide-close', title: _('Select this interface only when it is the WAN/upstream interface for this source.') }, [
					device?.getI18n?.() || name,
					networks.length ? ' (%s)'.format(networks.join(', ')) : ''
				])
			]);

			addChoice(name, label);
		});

		qddns.normalizeInterfaces(catalog?.interfaces).forEach(function(item) {
			addChoice(item.name);
		});

		const dropdown = new ui.Dropdown([], choices, {
			sort: order,
			multiple: multiple !== false,
			optional: true,
			select_placeholder: E('em', _('unspecified')),
			display_items: 3,
			dropdown_items: 7,
			create: false
		}).render();

		dropdown.classList.add('qddns-rule-wizard-interface-select');
		return dropdown;
	},

	setWizardInterfaceValue: function(control, value) {
		const selected = String(value || '').split(/,+/).map(function(item) {
			return item.trim();
		}).filter(function(item, index, values) {
			return item && values.indexOf(item) === index;
		});

		if (control?.classList?.contains('cbi-dropdown')) {
			const dropdown = L.dom.findClassInstance(control);
			const values = {};

			selected.forEach(function(name) {
				values[name] = true;
			});

			if (dropdown?.setValues)
				dropdown.setValues(control, values);

			return;
		}

		if (!control?.options)
			return;

		for (let index = 0; index < control.options.length; index++)
			control.options[index].selected = selected.indexOf(control.options[index].value) > -1;
	},

	renderWizardSourceIp: function(statusNode) {
		return E('div', { class: 'qddns-rule-wizard-source-status' }, [
			statusNode
		]);
	},

	wizardValue: function(control) {
		if (control?.classList?.contains('cbi-dropdown')) {
			const values = Array.from(control.querySelectorAll('input[type="hidden"]')).map(function(input) {
				return String(input.value || '').trim();
			}).filter(function(value) {
				return value;
			});

			if (values.length)
				return values.join(',');

			return String(control.value || '').trim().split(/\s+/).filter(function(value) {
				return value;
			}).join(',');
		}

		if (control?.multiple)
			return Array.from(control.selectedOptions || []).map(function(option) {
				return String(option.value || '').trim();
			}).filter(function(value) {
				return value;
			}).join(',');

		return String(control?.value || '').trim();
	},

	wizardSelectedText: function(control, fallback) {
		const option = control?.options?.[control.selectedIndex];
		return String(option?.textContent || fallback || '').trim();
	},

	wizardSourceId: function(fields) {
		return String(fields.source?.getAttribute('data-wizard-source-id') || this.wizardValue(fields.source)).trim();
	},

	wizardSourceLabel: function(fields) {
		return String(fields.source?.getAttribute('data-wizard-source-label') || this.wizardSelectedText(fields.source, _('Unnamed source'))).trim();
	},

	setWizardStep: function(modal, stepIndex) {
		const panels = modal.querySelectorAll('[data-wizard-panel]');
		const steps = modal.querySelectorAll('[data-wizard-step]');

		panels.forEach(function(panel, index) {
			panel.style.display = index === stepIndex ? '' : 'none';
		});

		steps.forEach(function(step, index) {
			step.classList.toggle('is-active', index === stepIndex);
			step.classList.toggle('is-complete', index < stepIndex);
			if (index === stepIndex)
				step.setAttribute('aria-current', 'step');
			else
				step.removeAttribute('aria-current');
		});
	},

	sourceFamily: function(sourceId) {
		const source = this.findById(this.pageData?.catalog?.sources, sourceId);
		return String(source?.family || '').toLowerCase();
	},

	sourceType: function(sourceId) {
		const source = this.findById(this.pageData?.catalog?.sources, sourceId);
		return String(source?.type || '').toLowerCase();
	},

	isPublicProbeSource: function(sourceId) {
		return this.sourceType(sourceId) === 'public_probe';
	},

	validateRecordTypeForSource: function(recordType, sourceId) {
		const family = this.sourceFamily(sourceId);
		const type = String(recordType || '').toUpperCase();

		if ((type === 'A' && family === 'ipv6') || (type === 'AAAA' && family === 'ipv4'))
			return _('Record type must match the selected source address family.');

		return true;
	},

	isProbeInterfaceVisible: function(fields) {
		if ((fields.sourceMode?.value || 'new') === 'new')
			return fields.sourceType?.value === 'public_probe';

		return this.isPublicProbeSource(this.wizardSourceId(fields));
	},

	wizardSourceFamily: function(fields, sourceId) {
		return String(fields.source?.getAttribute('data-probed-family') || this.sourceFamily(sourceId)).toLowerCase();
	},

	syncWizardRecordType: function(control, family) {
		const normalized = String(family || '').toLowerCase();
		const recordType = normalized === 'ipv6' ? 'AAAA' : normalized === 'ipv4' ? 'A' : '';

		if (!control)
			return;

		if (recordType) {
			control.value = recordType;
			control.disabled = true;
			control.setAttribute('data-auto-record-type', '1');
			control.title = _('Automatically set from the source IP family.');
		} else {
			control.disabled = false;
			control.removeAttribute('data-auto-record-type');
			control.removeAttribute('title');
		}
	},

	inferSourceFamily: function(address, fallback) {
		const value = String(address || '').trim();

		if (value.indexOf(':') > -1)
			return 'ipv6';
		if (value.indexOf('.') > -1)
			return 'ipv4';

		return String(fallback || '').toLowerCase();
	},

	setWizardFeedback: function(feedback, message) {
		feedback.textContent = message;
		feedback.classList.add('alert-message', 'warning');
		feedback.setAttribute('data-source-ip-guide', 'warning');
	},

	wizardFeedbackForStep: function(stepIndex) {
		if (stepIndex === 1)
			return _('Enter provider, zone, and record name.');
		if (stepIndex === 2)
			return _('Review the source IP and DNS record before creating the rule.');

		return _('Create or choose an IP source and probe it, then choose the DNS location.');
	},

	resetWizardFeedback: function(feedback, stepIndex) {
		feedback.textContent = this.wizardFeedbackForStep(stepIndex);
		feedback.classList.remove('alert-message', 'warning');
		feedback.setAttribute('data-source-ip-guide', 'idle');
	},

	validateWizardStep: function(fields, feedback, stepIndex) {
		this.resetWizardFeedback(feedback, stepIndex);

		if (stepIndex === 0) {
			const source = this.wizardSourceId(fields);
			const recordType = this.wizardValue(fields.recordType) || 'A';

			if (!source) {
				this.setWizardFeedback(feedback, _('Create or choose a source before continuing.'));
				return false;
			}

			if (fields.source?.getAttribute('data-source-create-dirty') === '1') {
				this.setWizardFeedback(feedback, _('Probe source IP before continuing. The source will be saved with the rule.'));
				return false;
			}

			if (fields.source?.getAttribute('data-source-ip-loading') === '1') {
				this.setWizardFeedback(feedback, _('Source IP is still loading.'));
				return false;
			}

			if (fields.source?.getAttribute('data-source-ip-error') === '1') {
				this.setWizardFeedback(feedback, _('Unable to read source IP. Choose another source or fix the source configuration.'));
				return false;
			}

			const family = this.wizardSourceFamily(fields, source);
			if ((recordType === 'A' && family === 'ipv6') || (recordType === 'AAAA' && family === 'ipv4')) {
				this.setWizardFeedback(feedback, _('Record type must match the selected source address family.'));
				return false;
			}
		}

		if (stepIndex === 1 && (!this.wizardValue(fields.provider) || !this.wizardValue(fields.zone))) {
			this.setWizardFeedback(feedback, _('Provider and domain are required.'));
			return false;
		}

		return true;
	},

	wizardSourceOptionValue: function(sourceData, option) {
		return ({
			family: sourceData.family,
			address: sourceData.address,
			interface: sourceData.interfaceName,
			duid: sourceData.duid,
			iaid: sourceData.iaid,
			mac: sourceData.mac,
			lease_file: sourceData.leaseFile,
			hostname_hint: sourceData.hostnameHint,
			prefix_filter: sourceData.prefixFilter,
			probe_url: sourceData.probeUrl
		})[option] || '';
	},

	stageWizardSource: function(sectionId, sourceData) {
		const sourceOptions = ['family', 'address', 'interface', 'duid', 'iaid', 'mac', 'lease_file', 'hostname_hint', 'prefix_filter', 'probe_url'];
		const exists = (uci.sections('qddns') || []).some(function(section) {
			return section['.name'] === sectionId;
		});

		if (!exists)
			uci.add('qddns', 'source', sectionId);
		uci.set('qddns', sectionId, 'name', sourceData.name);
		uci.set('qddns', sectionId, 'type', sourceData.type);

		sourceOptions.forEach(L.bind(function(option) {
			const normalized = String(this.wizardSourceOptionValue(sourceData, option) || '').trim();

			if (normalized)
				uci.set('qddns', sectionId, option, normalized);
			else if (typeof uci.unset == 'function')
				uci.unset('qddns', sectionId, option);
		}, this));
	},

	createRuleFromWizard: function(fields, feedback, button, sourceDraft) {
		const provider = this.wizardValue(fields.provider);
		const draftSource = sourceDraft?.id && sourceDraft?.data ? sourceDraft : null;
		let source = this.wizardSourceId(fields) || draftSource?.id || '';
		const domain = this.wizardValue(fields.zone);
		const dot = domain.indexOf('.');
		const zone = dot > 0 ? domain.substring(dot + 1) : '';
		const recordName = dot > 0 ? domain.substring(0, dot) : domain;
		const recordType = this.wizardValue(fields.recordType) || 'A';
		const ruleName = '%s %s'.format(domain, recordType);

		if (!provider || !source || !domain) {
			feedback.textContent = _('Provider, source, and domain are required.');
			feedback.classList.add('alert-message', 'warning');
			return Promise.resolve();
		}

		const family = this.wizardSourceFamily(fields, source);
		if ((recordType === 'A' && family === 'ipv6') || (recordType === 'AAAA' && family === 'ipv4')) {
			feedback.textContent = _('Record type must match the selected source address family.');
			feedback.classList.add('alert-message', 'warning');
			return Promise.resolve();
		}

		button.disabled = true;
		button.classList.add('qddns-busy');
		feedback.textContent = _('Saving and applying rule...');
		feedback.classList.remove('alert-message', 'warning');

		if (draftSource) {
			source = draftSource.id;
			this.stageWizardSource(source, draftSource.data);
		}

		const sectionId = uci.add('qddns', 'rule', this.nextNumericSectionId());
		uci.set('qddns', sectionId, 'name', ruleName);
		uci.set('qddns', sectionId, 'enabled', fields.enabled.checked ? '1' : '0');
		uci.set('qddns', sectionId, 'record_type', recordType);
		uci.set('qddns', sectionId, 'provider', provider);
		uci.set('qddns', sectionId, 'source', source);
		uci.set('qddns', sectionId, 'zone', zone);
		uci.set('qddns', sectionId, 'record_name', recordName);
		uci.set('qddns', sectionId, 'proxied', '0');
		uci.set('qddns', sectionId, 'check_interval', '60');
		uci.set('qddns', sectionId, 'force_interval', '3600');
		uci.set('qddns', sectionId, 'retry_count', '3');
		uci.set('qddns', sectionId, 'retry_backoff', '30');
		if (this.isProbeInterfaceVisible(fields) && this.wizardValue(fields.probeInterface))
			uci.set('qddns', sectionId, 'probe_interface', this.wizardValue(fields.probeInterface));

		return uci.save().then(function() {
			feedback.textContent = _('Rule has been saved. Applying changes...');
			ui.changes.apply(true);
		}).catch(L.bind(function(err) {
			if (typeof uci.remove == 'function') {
				uci.remove('qddns', sectionId);
				if (draftSource)
					uci.remove('qddns', source);
			}
			button.disabled = false;
			button.classList.remove('qddns-busy');
			qddns.showFailureModal(_('Add DDNS rule'), { error: qddns.extractResultMessage(err, _('Unable to add the DDNS rule.')) }, _('Unable to add the DDNS rule.'));
		}, this));
	},

	showRuleWizardModal: function(data, launcher) {
		const providers = qddns.sortNamedItems(data?.catalog?.rules?.providers || []);
		const sources = qddns.sortNamedItems(data?.catalog?.sources || []);
		const viewRef = this;
		const fields = {
			sourceMode: E('select', { class: 'cbi-input-select' }, [
				E('option', { value: 'new' }, [_('Create new source')]),
				E('option', { value: 'saved' }, [_('Use saved source')])
			]),
			sourceName: E('input', { type: 'text', class: 'cbi-input-text', placeholder: _('Source name') }),
			sourceType: E('select', { class: 'cbi-input-select' }, [
				E('option', { value: 'interface' }, [_('Interface')]),
				E('option', { value: 'public_probe' }, [_('Public probe')]),
				E('option', { value: 'dhcpv6_duid' }, [_('DHCPv6 DUID')]),
				E('option', { value: 'dhcpv6_mac' }, [_('MAC')]),
				E('option', { value: 'local_addr' }, [_('Local address')])
			]),
			sourceFamily: E('select', { class: 'cbi-input-select' }, [
				E('option', { value: '' }, [_('Auto')]),
				E('option', { value: 'ipv4' }, [_('IPv4')]),
				E('option', { value: 'ipv6' }, [_('IPv6')])
			]),
			sourceAddress: E('input', { type: 'text', class: 'cbi-input-text', placeholder: '198.51.100.10 / 2001:db8::10' }),
			sourceProbeUrl: E('select', { class: 'cbi-input-select' }, [
				E('option', { value: 'https://ddns.oray.com/checkip' }, ['ddns.oray.com/checkip']),
				E('option', { value: 'http://myip.ipip.net' }, ['myip.ipip.net']),
				E('option', { value: 'http://members.3322.org/dyndns/getip' }, ['members.3322.org/dyndns/getip']),
				E('option', { value: 'http://ip.3322.net' }, ['ip.3322.net']),
				E('option', { value: 'http://whatismyip.akamai.com' }, ['whatismyip.akamai.com']),
				E('option', { value: 'http://ifconfig.me/ip' }, ['ifconfig.me/ip'])
			]),
			sourceInterface: this.renderWizardInterfaceSelect(data?.catalog, true),
			sourceInterfaceSingle: this.renderWizardInterfaceSelect(data?.catalog, false),
			probeInterface: this.renderWizardInterfaceSelect(data?.catalog, false),
			sourceDuid: E('input', { type: 'text', class: 'cbi-input-text' }),
			sourceIaid: E('input', { type: 'text', class: 'cbi-input-text' }),
			sourceMac: E('input', { type: 'text', class: 'cbi-input-text', placeholder: 'aa:bb:cc:dd:ee:ff' }),
			sourceLeaseFile: E('input', { type: 'text', class: 'cbi-input-text', value: '/tmp/odhcpd.leases' }),
			sourceHostnameHint: E('input', { type: 'text', class: 'cbi-input-text' }),
			sourcePrefixFilter: E('input', { type: 'text', class: 'cbi-input-text', placeholder: '240e:' }),
			recordType: E('select', { class: 'cbi-input-select' }, [
				E('option', { value: 'A' }, ['A']),
				E('option', { value: 'AAAA' }, ['AAAA'])
			]),
			provider: this.renderWizardSelect(providers, _('No providers available'), _('Unnamed provider')),
			source: this.renderWizardSelect(sources, _('No sources available'), _('Unnamed source')),
			zone: E('input', { type: 'text', class: 'cbi-input-text', placeholder: 'home.example.com' }),
			enabled: E('input', { type: 'checkbox', checked: 'checked' })
		};
		const sourceIpStatus = E('span', { class: 'qddns-rule-wizard-source-ip', 'data-source-ip-status': 'wizard' }, [_('Loading...')]);
		const sourceProbe = { token: 0, address: '', family: '', loading: false };
		const sourceCreate = { id: '', clean: false, version: 0, address: '', family: '', data: null };
		const wizardDefaultFeedback = _('Create or choose an IP source and probe it, then choose the DNS location.');
		const feedback = E('div', { class: 'cbi-value-description qddns-rule-wizard-feedback' }, wizardDefaultFeedback);
		const sourceLeaseButton = E('button', { type: 'button', class: 'btn cbi-button cbi-button-action' }, [_('Read current DUID')]);
		const sourceLeaseResults = E('div', { class: 'qddns-lease-results' });
		const saveSourceButton = E('button', { type: 'button', class: 'btn cbi-button cbi-button-action' }, [_('Probe source IP')]);
		const saveButton = E('button', { type: 'button', class: 'btn cbi-button cbi-button-add' }, [_('Save and apply')]);
		const previousButton = E('button', { type: 'button', class: 'btn cbi-button' }, [_('Back')]);
		const nextButton = E('button', { type: 'button', class: 'btn cbi-button cbi-button-action' }, [_('Next')]);
		const summary = E('div', { class: 'qddns-rule-wizard-summary' });
		let stepIndex = 0;
		fields.source.value = '';

		const sourceModeGroup = E('div', { class: 'qddns-rule-wizard-path-bar' }, [
			E('div', { class: 'qddns-rule-wizard-path-copy' }, [
				E('span', { class: 'qddns-rule-wizard-section-title' }, _('Source path')),
				E('span', { class: 'qddns-rule-wizard-section-desc' }, _('Choose whether to create a source now or use one already saved.'))
			]),
			this.renderWizardField(_('Mode'), fields.sourceMode)
		]);
		const savedSourcePanel = E('div', { class: 'qddns-rule-wizard-source-panel', 'data-source-panel': 'saved' }, [
			E('div', { class: 'qddns-rule-wizard-section' }, [
				E('div', { class: 'qddns-rule-wizard-section-head' }, [
					E('span', { class: 'qddns-rule-wizard-section-title' }, _('Saved source')),
					E('span', { class: 'qddns-rule-wizard-section-desc' }, _('Select a saved source. Previewable sources are probed automatically; otherwise A/AAAA follows the saved family or stays manual.'))
				]),
				E('div', { class: 'qddns-rule-wizard-grid' }, [
					this.renderWizardField(_('Source'), fields.source)
				])
			])
		]);
		const sourceFamilyField = this.renderWizardField(_('Family'), fields.sourceFamily);
		const sourceAddressField = this.renderWizardField(_('Address'), fields.sourceAddress);
		const sourceProbeUrlField = this.renderWizardField(_('Probe URL'), fields.sourceProbeUrl, _('Select a public IP detection service.'));
		const probeInterfaceField = this.renderWizardField(_('Public probe outbound interface'), fields.probeInterface, _('Optional for public probe rules. Choose the WAN/upstream interface used for public IP detection; empty uses the system default route.'));
		const sourceTypeHint = E('div', { class: 'cbi-value-description' });
		const sourceTypeField = E('div', { class: 'qddns-rule-wizard-field' }, [
			E('label', {}, _('Source type')),
			fields.sourceType,
			sourceTypeHint
		]);
		const sourceInterfaceField = E('div', { class: 'qddns-rule-wizard-field' }, [
			E('label', {}, _('WAN/upstream interface')),
			fields.sourceInterfaceSingle,
			fields.sourceInterface,
			E('div', { class: 'cbi-value-description' }, _('Select WAN/upstream interface(s). Verify the real upstream path before probing.'))
		]);
		const sourceDuidField = this.renderWizardField(_('DUID'), fields.sourceDuid);
		const sourceIaidField = this.renderWizardField(_('IAID'), fields.sourceIaid);
		const sourceMacField = this.renderWizardField(_('MAC'), fields.sourceMac);
		const sourceLeaseFileField = this.renderWizardField(_('Lease file'), fields.sourceLeaseFile);
		const sourceHostnameHintField = this.renderWizardField(_('Hostname hint'), fields.sourceHostnameHint);
		const sourcePrefixFilterField = this.renderWizardField(_('Prefix narrowing'), fields.sourcePrefixFilter, _('Advanced narrowing after WAN/PD source prefix matching; it cannot replace the interface.'));
		const sourceLeasePanel = E('div', { class: 'qddns-rule-wizard-source-panel', 'data-source-panel': 'lease' }, [
			E('div', { class: 'qddns-actions qddns-rule-wizard-source-actions' }, [sourceLeaseButton]),
			sourceLeaseResults
		]);
		const sourcePrefixTitle = E('span', { class: 'qddns-rule-wizard-section-title' }, _('WAN prefix source'));
		const sourcePrefixDescription = E('span', { class: 'qddns-rule-wizard-section-desc' }, _('Choose the WAN/upstream interface that owns the delegated IPv6 prefix. Do not select LAN here.'));
		const sourcePrefixGroup = E('div', { class: 'qddns-rule-wizard-section', 'data-source-group': 'prefix' }, [
			E('div', { class: 'qddns-rule-wizard-section-head' }, [
				sourcePrefixTitle,
				sourcePrefixDescription
			]),
			E('div', { class: 'qddns-rule-wizard-grid' }, [
				sourceInterfaceField,
				sourcePrefixFilterField
			])
		]);
		const sourceIdentityGroup = E('div', { class: 'qddns-rule-wizard-section', 'data-source-group': 'identity' }, [
			E('div', { class: 'qddns-rule-wizard-section-head' }, [
				E('span', { class: 'qddns-rule-wizard-section-title' }, _('LAN host identity')),
				E('span', { class: 'qddns-rule-wizard-section-desc' }, _('Lease cards fill the LAN host identity only; the WAN interface remains the prefix source.'))
			]),
			E('div', { class: 'qddns-rule-wizard-grid' }, [
				sourceDuidField,
				sourceIaidField,
				sourceMacField,
				sourceLeaseFileField,
				sourceHostnameHintField
			]),
			sourceLeasePanel
		]);
		const sourceDetectionGroup = E('div', { class: 'qddns-rule-wizard-section' }, [
			E('div', { class: 'qddns-rule-wizard-section-head' }, [
				E('span', { class: 'qddns-rule-wizard-section-title' }, _('Source IP check')),
				E('span', { class: 'qddns-rule-wizard-section-desc' }, _('Probe the source before continuing. A/AAAA is locked to the detected IP family.'))
			]),
			E('div', { class: 'qddns-rule-wizard-detection-grid' }, [
				this.renderWizardField(_('Source IP'), this.renderWizardSourceIp(sourceIpStatus)),
				this.renderWizardField(_('Record type'), fields.recordType),
				E('div', { class: 'qddns-actions qddns-rule-wizard-probe-action-field' }, [saveSourceButton])
			]),
			E('div', { class: 'qddns-rule-wizard-grid' }, [
				probeInterfaceField
			])
		]);
		const newSourcePanel = E('div', { class: 'qddns-rule-wizard-source-panel', 'data-source-panel': 'new' }, [
			E('div', { class: 'qddns-rule-wizard-section' }, [
				E('div', { class: 'qddns-rule-wizard-section-head' }, [
					E('span', { class: 'qddns-rule-wizard-section-title' }, _('Source definition')),
					E('span', { class: 'qddns-rule-wizard-section-desc' }, _('Name the source and choose how QDDNS should read the current IP.'))
				]),
				E('div', { class: 'qddns-rule-wizard-grid' }, [
					this.renderWizardField(_('Source name'), fields.sourceName),
					sourceTypeField,
					sourceFamilyField,
					sourceAddressField,
					sourceProbeUrlField
				])
			]),
			sourcePrefixGroup,
			sourceIdentityGroup
		]);
		function renderWizardStep(index, label, hint) {
			return E('span', { 'data-wizard-step': String(index), class: index ? 'qddns-rule-wizard-step' : 'qddns-rule-wizard-step is-active' }, [
				label,
				E('small', {}, hint)
			]);
		}

		const modal = E('div', { class: 'qddns-rule-wizard-modal' }, [
			E('div', { class: 'qddns-rule-wizard-steps' }, [
				renderWizardStep(0, _('1. Source IP'), _('select and probe')),
				renderWizardStep(1, _('2. DNS record'), _('provider and name')),
				renderWizardStep(2, _('3. Create'), _('save and apply'))
			]),
			E('div', { 'data-wizard-panel': '0', class: 'qddns-rule-wizard-panel' }, [
				E('h4', {}, _('Choose source IP')),
				E('p', { class: 'qddns-rule-wizard-lead' }, _('Start with an IP source. For DHCPv6 DUID/MAC, WAN/upstream interfaces use WAN/PD route source prefixes to filter valid LAN host IPv6 addresses; lease candidates only identify the LAN host.')),
				sourceModeGroup,
				savedSourcePanel,
				newSourcePanel,
				sourceDetectionGroup
			]),
			E('div', { 'data-wizard-panel': '1', class: 'qddns-rule-wizard-panel', style: 'display:none' }, [
				E('h4', {}, _('Choose where to update DNS')),
				E('p', { class: 'qddns-rule-wizard-lead' }, _('Use a saved provider, then enter the DNS zone and host record to update.')),
				E('div', { class: 'qddns-rule-wizard-section' }, [
					E('div', { class: 'qddns-rule-wizard-section-head' }, [
						E('span', { class: 'qddns-rule-wizard-section-title' }, _('DNS record')),
						E('span', { class: 'qddns-rule-wizard-section-desc' }, _('The record type is already matched to the detected source IP family.'))
					]),
					E('div', { class: 'qddns-rule-wizard-grid' }, [
						this.renderWizardField(_('Provider'), fields.provider),
						this.renderWizardField(_('Domain'), fields.zone)
					])
				])
			]),
			E('div', { 'data-wizard-panel': '2', class: 'qddns-rule-wizard-panel', style: 'display:none' }, [
				E('h4', {}, _('Review and create')),
				summary,
				E('div', { class: 'qddns-rule-wizard-section' }, [
					E('div', { class: 'qddns-rule-wizard-section-head' }, [
						E('span', { class: 'qddns-rule-wizard-section-title' }, _('Activation')),
						E('span', { class: 'qddns-rule-wizard-section-desc' }, _('Rule name is generated automatically from the record.'))
					]),
					E('div', { class: 'qddns-rule-wizard-grid qddns-rule-wizard-grid-narrow' }, [
						this.renderWizardField(_('Enable after creation'), E('label', { class: 'qddns-rule-wizard-switch' }, [fields.enabled, _('Enabled')]))
					])
				])
			]),
			feedback,
			E('div', { class: 'qddns-actions qddns-rule-wizard-footer-actions' }, [previousButton, nextButton, saveButton, E('button', { type: 'button', class: 'btn cbi-button', click: ui.hideModal }, [_('Close')])])
		]);

		function setWizardSourceIp(message, tone) {
			sourceIpStatus.textContent = message || _('N/A');
			sourceIpStatus.setAttribute('data-tone', tone || 'neutral');
		}

		function setWizardProbeFeedback(message, tone) {
			feedback.textContent = message || wizardDefaultFeedback;
			feedback.classList.toggle('alert-message', tone === 'loading' || tone === 'error' || tone === 'warning');
			feedback.classList.toggle('warning', tone === 'loading' || tone === 'error' || tone === 'warning');
			feedback.setAttribute('data-source-ip-guide', tone || 'idle');
		}

		function resetStepFeedback() {
			viewRef.resetWizardFeedback(feedback, stepIndex);
		}

		function currentSourceMode() {
			return fields.sourceMode.value || 'new';
		}

		function newSourceProbePrompt() {
			return _('Probe source IP before continuing. The source will be saved with the rule.');
		}

		function sourceDetectedMessage(address) {
			const type = viewRef.wizardValue(fields.recordType) || 'A';

			if (currentSourceMode() === 'saved')
				return _('Source IP detected: %s. Record type was set to %s. The saved source will be used for this rule.').format(address, type);

			return _('Source IP detected: %s. Record type was set to %s. The source will be saved with the rule.').format(address, type);
		}

		function isDhcpv6SourceType(sourceType) {
			return sourceType === 'dhcpv6_duid' || sourceType === 'dhcpv6_mac';
		}

		function effectiveSourceId() {
			return String(fields.source.getAttribute('data-wizard-source-id') || viewRef.wizardValue(fields.source) || '').trim();
		}

		function setEffectiveSource(sourceId, label) {
			fields.source.setAttribute('data-wizard-source-id', sourceId || '');
			fields.source.setAttribute('data-wizard-source-label', label || '');
			if (fields.source.value !== (sourceId || ''))
				fields.source.value = sourceId || '';
		}

		function ensureSavedSourceSelected() {
			if (viewRef.wizardValue(fields.source))
				return;

			for (let index = 0; index < fields.source.options.length; index++) {
				const option = fields.source.options[index];

				if (!option.disabled && String(option.value || '').trim()) {
					fields.source.value = option.value;
					return;
				}
			}
		}

		function resetSourceProbe(message, tone) {
			sourceProbe.token++;
			sourceProbe.address = '';
			sourceProbe.family = '';
			sourceProbe.loading = false;
			fields.source.removeAttribute('data-probed-family');
			fields.source.removeAttribute('data-source-ip-loading');
			fields.source.removeAttribute('data-source-ip-error');
			setWizardSourceIp(_('N/A'), 'neutral');
			setWizardProbeFeedback(message || wizardDefaultFeedback, tone || 'idle');
			updateButtons();
			if (stepIndex === 2)
				updateWizardSummary();
		}

		function markProbeInterfaceStale() {
			const message = _('Probe source IP before continuing. The public probe interface changed.');
			if (currentSourceMode() === 'new') {
				markNewSourceDirty(message);
			} else {
				resetSourceProbe(message, 'warning');
				fields.source.setAttribute('data-source-ip-error', '1');
				updateButtons();
			}
		}

		function updateProbeInterfaceField() {
			const visible = viewRef.isProbeInterfaceVisible(fields);
			probeInterfaceField.style.display = visible ? '' : 'none';
			if (!visible)
				viewRef.setWizardInterfaceValue(fields.probeInterface, '');
		}

		function markNewSourceDirty(message) {
			sourceCreate.clean = false;
			sourceCreate.version++;
			sourceCreate.address = '';
			sourceCreate.family = '';
			sourceCreate.data = null;
			fields.source.setAttribute('data-source-create-dirty', '1');
			setEffectiveSource('', viewRef.wizardValue(fields.sourceName) || _('Unnamed source'));
			resetSourceProbe(message || newSourceProbePrompt(), 'warning');
		}

		function resetLeaseResults() {
			const isDuidSource = fields.sourceType.value === 'dhcpv6_duid';

			sourceLeaseButton.replaceChildren(isDuidSource ? _('Read current DUID') : _('Read current MAC'));
			sourceLeaseResults.replaceChildren(E('div', { class: 'cbi-value-description' }, isDuidSource ? _('Read current DHCPv6 lease candidates, then choose one to fill the DUID source fields.') : _('Read current LAN host candidates, then choose one to fill the MAC source fields.')));
		}

		function updateSourcePrefixText() {
			if (fields.sourceType.value === 'interface') {
				sourcePrefixTitle.textContent = _('WAN/upstream interface');
				sourcePrefixDescription.textContent = _('Choose the WAN/upstream interface whose current address should be published.');
				sourceTypeHint.textContent = _('Publish the current address from a WAN/upstream interface.');
				return;
			}

			if (fields.sourceType.value === 'public_probe') {
				sourceTypeHint.textContent = _('Query a public service to detect the external IP address.');
				return;
			}

			sourcePrefixTitle.textContent = _('WAN prefix source');
			sourcePrefixDescription.textContent = _('Choose the WAN/upstream interface that owns the delegated IPv6 prefix. Do not select LAN here.');
			if (fields.sourceType.value === 'dhcpv6_duid')
				sourceTypeHint.textContent = _('Find a LAN host by DHCPv6 DUID/IAID, then validate its IPv6 against selected WAN/PD prefixes.');
			else if (fields.sourceType.value === 'dhcpv6_mac')
				sourceTypeHint.textContent = _('Find a LAN host by MAC, then validate its IPv6 against selected WAN/PD prefixes.');
			else
				sourceTypeHint.textContent = _('Use an address you type manually.');
		}

		function syncNewSourceRecordType() {
			const sourceType = fields.sourceType.value;
			const family = isDhcpv6SourceType(sourceType) ? 'ipv6' : (viewRef.wizardValue(fields.sourceFamily) || (sourceType === 'local_addr' ? viewRef.inferSourceFamily(viewRef.wizardValue(fields.sourceAddress)) : ''));

			viewRef.syncWizardRecordType(fields.recordType, family);
		}

		function updateNewSourceFields(skipDirty) {
			const sourceType = fields.sourceType.value;
			const isDuidSource = sourceType === 'dhcpv6_duid';
			const isMacSource = sourceType === 'dhcpv6_mac';
			const isDhcpv6Source = isDuidSource || isMacSource;
			const isPublicProbe = sourceType === 'public_probe';

			sourceFamilyField.style.display = isDhcpv6Source ? 'none' : '';
			sourceAddressField.style.display = sourceType === 'local_addr' ? '' : 'none';
			sourceProbeUrlField.style.display = isPublicProbe ? '' : 'none';
			sourceInterfaceField.style.display = sourceType === 'interface' || isDhcpv6Source ? '' : 'none';
			fields.sourceInterfaceSingle.style.display = sourceType === 'interface' ? '' : 'none';
			fields.sourceInterface.style.display = isDhcpv6Source ? '' : 'none';
			sourcePrefixGroup.style.display = sourceType === 'interface' || isDhcpv6Source ? '' : 'none';
			sourceIdentityGroup.style.display = isDhcpv6Source ? '' : 'none';
			sourceDuidField.style.display = isDuidSource ? '' : 'none';
			sourceIaidField.style.display = isDuidSource ? '' : 'none';
			sourceMacField.style.display = isMacSource ? '' : 'none';
			sourceLeaseFileField.style.display = 'none';
			sourceHostnameHintField.style.display = isDhcpv6Source ? '' : 'none';
			sourcePrefixFilterField.style.display = isDhcpv6Source ? '' : 'none';
			sourceLeasePanel.style.display = isDhcpv6Source ? '' : 'none';
			updateSourcePrefixText();
			updateProbeInterfaceField();
			if (!skipDirty)
				resetSourceTypeFields(sourceType);
			else if (isDhcpv6Source)
				fields.sourceFamily.value = 'ipv6';
			syncNewSourceRecordType();
			resetLeaseResults();
			if (!skipDirty)
				markNewSourceDirty();
		}

		function resetSourceTypeFields(sourceType) {
			const isDhcpv6Source = isDhcpv6SourceType(sourceType);

			fields.sourceFamily.value = isDhcpv6Source ? 'ipv6' : '';
			fields.sourceAddress.value = '';
			setSourceInterfaceValue('');
			fields.sourceDuid.value = '';
			fields.sourceIaid.value = '';
			fields.sourceMac.value = '';
			fields.sourceLeaseFile.value = isDhcpv6Source ? '/tmp/odhcpd.leases' : '';
			fields.sourceHostnameHint.value = '';
			fields.sourcePrefixFilter.value = '';
		}

		function restoreNewSourceProbe() {
			sourceProbe.token++;
			sourceProbe.address = sourceCreate.address || '';
			sourceProbe.family = sourceCreate.family || '';
			sourceProbe.loading = false;
			fields.source.removeAttribute('data-source-create-dirty');
			fields.source.removeAttribute('data-source-ip-loading');
			fields.source.removeAttribute('data-source-ip-error');
			if (sourceProbe.family)
				fields.source.setAttribute('data-probed-family', sourceProbe.family);
			else
				fields.source.removeAttribute('data-probed-family');
			viewRef.syncWizardRecordType(fields.recordType, sourceProbe.family);
			if (sourceProbe.address) {
				setWizardSourceIp(sourceProbe.address, 'neutral');
				setWizardProbeFeedback(sourceDetectedMessage(sourceProbe.address), 'ready');
			} else {
				setWizardSourceIp(_('N/A'), 'neutral');
				setWizardProbeFeedback(newSourceProbePrompt(), 'warning');
			}
			if (stepIndex === 2)
				updateWizardSummary();
		}

		function updateSourceMode() {
			const useNewSource = currentSourceMode() === 'new';

			savedSourcePanel.style.display = useNewSource ? 'none' : '';
			newSourcePanel.style.display = useNewSource ? '' : 'none';
			saveSourceButton.style.display = stepIndex === 0 ? '' : 'none';
			if (useNewSource) {
				if (sourceCreate.clean && sourceCreate.id) {
					setEffectiveSource(sourceCreate.id, viewRef.wizardValue(fields.sourceName) || _('Unnamed source'));
					restoreNewSourceProbe();
				} else {
					markNewSourceDirty();
				}
			} else {
				sourceCreate.version++;
				fields.source.removeAttribute('data-source-create-dirty');
				ensureSavedSourceSelected();
				setEffectiveSource(viewRef.wizardValue(fields.source), viewRef.wizardSelectedText(fields.source, _('Unnamed source')));
				updateWizardSourceProbe();
			}
			updateProbeInterfaceField();
			updateButtons();
		}

		function renderSummaryRow(label, value) {
			return E('div', { class: 'qddns-rule-wizard-summary-row' }, [
				E('span', { class: 'qddns-rule-wizard-summary-label' }, label + ':'),
				E('span', { class: 'qddns-rule-wizard-summary-value' }, value || '-')
			]);
		}

		function updateWizardSummary() {
			const sourceType = fields.sourceType.value;
			const isDhcpv6Source = isDhcpv6SourceType(sourceType);
			const recordType = viewRef.wizardValue(fields.recordType) || 'A';
			const family = sourceProbe.family || viewRef.wizardSourceFamily(fields, effectiveSourceId());
			const recordFamily = family === 'ipv6' ? _('IPv6 source') : family === 'ipv4' ? _('IPv4 source') : _('source family unknown');
			const rows = [
				renderSummaryRow(_('Record'), '%s (%s, %s)'.format(viewRef.wizardValue(fields.zone) || '-', recordType, recordFamily)),
				renderSummaryRow(_('Source'), viewRef.wizardSourceLabel(fields)),
				renderSummaryRow(_('Source IP'), sourceProbe.address || sourceIpStatus.textContent || _('N/A')),
				renderSummaryRow(_('Provider'), viewRef.wizardSelectedText(fields.provider, _('Unnamed provider')))
			];

			if (currentSourceMode() === 'new') {
				if (sourceType === 'interface' || isDhcpv6Source)
					rows.push(renderSummaryRow(_('WAN/upstream interface'), viewRef.wizardValue(fields.sourceInterface)));
				if (viewRef.isProbeInterfaceVisible(fields))
					rows.push(renderSummaryRow(_('Public probe outbound interface'), viewRef.wizardValue(fields.probeInterface) || _('System default route')));
				if (isDhcpv6Source)
					rows.push(renderSummaryRow(_('LAN host identity'), sourceType === 'dhcpv6_duid' ? '%s / %s'.format(viewRef.wizardValue(fields.sourceDuid) || '-', viewRef.wizardValue(fields.sourceIaid) || '-') : viewRef.wizardValue(fields.sourceMac)));
				if (isDhcpv6Source && viewRef.wizardValue(fields.sourcePrefixFilter))
					rows.push(renderSummaryRow(_('Prefix narrowing'), viewRef.wizardValue(fields.sourcePrefixFilter)));
			} else if (viewRef.isProbeInterfaceVisible(fields)) {
				rows.push(renderSummaryRow(_('Public probe outbound interface'), viewRef.wizardValue(fields.probeInterface) || _('System default route')));
			}

			summary.replaceChildren.apply(summary, rows);
		}

		function updateWizardSourceProbe() {
			const sourceId = effectiveSourceId();
			sourceProbe.token++;
			const token = sourceProbe.token;
			sourceProbe.address = '';
			sourceProbe.family = '';
			sourceProbe.loading = false;
			fields.source.removeAttribute('data-probed-family');
			fields.source.removeAttribute('data-source-ip-loading');
			fields.source.removeAttribute('data-source-ip-error');

			if (!sourceId) {
				setWizardSourceIp(_('N/A'), 'neutral');
				setWizardProbeFeedback(currentSourceMode() === 'new' ? newSourceProbePrompt() : wizardDefaultFeedback, currentSourceMode() === 'new' ? 'warning' : 'idle');
				updateButtons();
				if (stepIndex === 2)
					updateWizardSummary();
				return Promise.resolve();
			}

			const source = viewRef.findById(sources, sourceId);
			viewRef.syncWizardRecordType(fields.recordType, source?.family);
			if (!qddns.isProbeableSourceType(source?.type)) {
				sourceProbe.family = viewRef.inferSourceFamily('', source?.family);
				if (sourceProbe.family)
					fields.source.setAttribute('data-probed-family', sourceProbe.family);
				else
					fields.source.removeAttribute('data-probed-family');
				setWizardSourceIp(_('Not previewable in LuCI'), 'warning');
				setWizardProbeFeedback(sourceProbe.family ? _('This source type cannot be previewed in LuCI. Record type was set from the saved source family; the backend will validate it when the rule runs.') : _('This source type cannot be previewed in LuCI. Confirm the record type manually; the backend will validate it when the rule runs.'), 'warning');
				updateButtons();
				if (stepIndex === 2)
					updateWizardSummary();
				return Promise.resolve();
			}

			sourceProbe.loading = true;
			fields.source.setAttribute('data-source-ip-loading', '1');
			setWizardSourceIp(_('Loading...'), 'neutral');
			setWizardProbeFeedback(_('Probing source IP...'), 'loading');
			updateButtons();
			if (stepIndex === 2)
				updateWizardSummary();

			return qddns.probeSourceForRuleDraft(sourceId, viewRef.isProbeInterfaceVisible(fields) ? viewRef.wizardValue(fields.probeInterface) : '').then(function(result) {
				if (token !== sourceProbe.token)
					return result;

				sourceProbe.loading = false;
				fields.source.removeAttribute('data-source-ip-loading');
				if (qddns.isFailedResult(result) || !result.address) {
					const message = qddns.extractResultMessage(result, _('Unable to read source IP.'));
					fields.source.setAttribute('data-source-ip-error', '1');
					setWizardSourceIp(message, 'negative');
					setWizardProbeFeedback(message, 'error');
					updateButtons();
					if (stepIndex === 2)
						updateWizardSummary();
					return result;
				}

				sourceProbe.address = result.address;
				sourceProbe.family = result.family || viewRef.inferSourceFamily(result.address);
				if (sourceProbe.family)
					fields.source.setAttribute('data-probed-family', sourceProbe.family);
				else
					fields.source.removeAttribute('data-probed-family');
				fields.source.removeAttribute('data-source-create-dirty');
				viewRef.syncWizardRecordType(fields.recordType, sourceProbe.family);
				updateProbeInterfaceField();
				setWizardSourceIp(result.address, 'neutral');
				setWizardProbeFeedback(sourceDetectedMessage(result.address), 'ready');
				updateButtons();
				if (stepIndex === 2)
					updateWizardSummary();
				return result;
			}).catch(function(err) {
				if (token !== sourceProbe.token)
					return;

				sourceProbe.address = '';
				sourceProbe.family = '';
				const message = qddns.extractResultMessage(err, _('Unable to read source IP.'));
				sourceProbe.loading = false;
				fields.source.removeAttribute('data-probed-family');
				fields.source.removeAttribute('data-source-ip-loading');
				fields.source.setAttribute('data-source-ip-error', '1');
				setWizardSourceIp(message, 'negative');
				setWizardProbeFeedback(message, 'error');
				updateButtons();
				if (stepIndex === 2)
					updateWizardSummary();
			});
		}

		function interfaceValues(value) {
			return String(value || '').split(/,+/).map(function(item) {
				return item.trim();
			}).filter(function(item, index, values) {
				return item && values.indexOf(item) === index;
			});
		}

		function ensureSourceInterfaceOption(value) {
			if (!fields.sourceInterface?.options)
				return;

			interfaceValues(value).forEach(function(name) {
				for (let index = 0; index < fields.sourceInterface.options.length; index++)
					if (fields.sourceInterface.options[index].value === name)
						return;

				fields.sourceInterface.appendChild(E('option', { value: name }, [name]));
			});
		}

		function setSourceInterfaceValue(value) {
			const selected = interfaceValues(value);

			if (fields.sourceInterface?.classList?.contains('cbi-dropdown')) {
				const dropdown = L.dom.findClassInstance(fields.sourceInterface);
				const values = {};

				selected.forEach(function(name) {
					values[name] = true;
				});

				if (dropdown?.setValues)
					dropdown.setValues(fields.sourceInterface, values);

				return;
			}

			ensureSourceInterfaceOption(selected.join(','));

			for (let index = 0; index < fields.sourceInterface.options.length; index++)
				fields.sourceInterface.options[index].selected = selected.indexOf(fields.sourceInterface.options[index].value) > -1;
		}

		function fillWizardLease(lease, feedbackNode) {
			const isDuidSource = fields.sourceType.value === 'dhcpv6_duid';
			const ipv4 = qddns.normalizeList(lease?.ipv4);

			fields.sourceFamily.value = 'ipv6';
			if (!viewRef.wizardValue(fields.sourceName))
				fields.sourceName.value = lease?.hostname || (isDuidSource ? _('DHCPv6 DUID') : (lease?.mac || _('MAC')));
			if (isDuidSource) {
				fields.sourceDuid.value = lease?.duid || '';
				fields.sourceIaid.value = lease?.iaid || '';
			} else {
				fields.sourceMac.value = lease?.mac || '';
				if (!viewRef.wizardValue(fields.sourceName) && ipv4.length)
					fields.sourceName.value = ipv4[0];
			}
			fields.sourceLeaseFile.value = lease?.lease_file || '/tmp/odhcpd.leases';
			fields.sourceHostnameHint.value = lease?.hostname || '';
			if (feedbackNode)
				feedbackNode.textContent = isDuidSource ? _('Selected DHCPv6 lease values have been filled. Keep the WAN interface selected separately.') : _('Selected LAN host MAC has been filled. Keep the WAN interface selected separately.');
			markNewSourceDirty();
		}

		function renderLeaseCard(lease, feedbackNode) {
			const prefixes = qddns.normalizeList(lease?.prefixes);
			const ipv4 = qddns.normalizeList(lease?.ipv4);
			const isDuidSource = fields.sourceType.value === 'dhcpv6_duid';
			const identityMeta = isDuidSource ? [
				qddns.renderLeaseMeta(_('DUID'), lease?.duid || '-'),
				qddns.renderLeaseMeta(_('IAID'), lease?.iaid || '-')
			] : [
				qddns.renderLeaseMeta(_('MAC'), lease?.mac || '-'),
				qddns.renderLeaseMeta(_('LAN IP'), ipv4.length ? ipv4.join(', ') : '-')
			];

			return qddns.renderLeaseCard({
				title: lease?.hostname || _('Unnamed host'),
				actionLabel: _('Fill from this lease'),
				meta: identityMeta.concat([
					qddns.renderLeaseMeta(_('Prefix'), prefixes.length ? prefixes.join('\n') : '-'),
					qddns.renderLeaseMeta(_('Host interface'), lease?.host_interface || '-')
				]),
				onSelect: function() {
					fillWizardLease(lease, feedbackNode);
				}
			});
		}

		function renderLeaseResults(leases) {
			const isDuidSource = fields.sourceType.value === 'dhcpv6_duid';
			const list = qddns.normalizeList(leases).filter(function(lease) {
				const prefixes = qddns.normalizeList(lease?.prefixes);

				if (!prefixes.length)
					return false;

				return isDuidSource ? !!(lease?.duid && lease?.iaid) : !!lease?.mac;
			});
			const emptyMessage = isDuidSource ? _('No DHCPv6 leases found.') : _('No LAN hosts with public IPv6 found.');
			const feedbackNode = E('div', { class: 'cbi-value-description' }, list.length ? (isDuidSource ? _('Choose a current DUID to fill DUID, IAID, and hostname hint. Keep the WAN interface selected separately.') : _('Choose a current MAC to fill MAC, LAN IP identity, and hostname hint. Keep the WAN interface selected separately.')) : emptyMessage);

			if (!list.length)
				return E('div', { class: 'qddns-lease-results' }, [feedbackNode]);

			return E('div', { class: 'qddns-lease-results' }, [
				feedbackNode,
				E('div', { class: 'qddns-lease-list' }, list.map(function(lease) {
					return renderLeaseCard(lease, feedbackNode);
				}))
			]);
		}

		function loadWizardLeases() {
			const mode = fields.sourceType.value === 'dhcpv6_duid' ? 'duid' : 'mac';

			return qddns.withBusyButton(sourceLeaseButton, function() {
				sourceLeaseResults.replaceChildren(E('div', { class: 'cbi-value-description' }, _('Loading...')));
				return qddns.listDhcpv6Leases(mode).then(function(result) {
					if (qddns.isFailedResult(result)) {
						sourceLeaseResults.replaceChildren(E('div', { class: 'cbi-value-description alert-message warning' }, qddns.extractResultMessage(result, _('Unable to load host candidates.'))));
						return result;
					}

					const rendered = renderLeaseResults(result.leases);
					sourceLeaseResults.replaceChildren.apply(sourceLeaseResults, Array.from(rendered.childNodes));
					return result;
				}).catch(function(err) {
					sourceLeaseResults.replaceChildren(E('div', { class: 'cbi-value-description alert-message warning' }, qddns.extractResultMessage(err, _('Unable to load host candidates.'))));
				});
			});
		}

		function buildSourceData() {
			const sourceType = fields.sourceType.value;
			const sourceData = {
				name: viewRef.wizardValue(fields.sourceName),
				type: sourceType,
				family: '',
				address: '',
				interfaceName: '',
				duid: '',
				iaid: '',
				mac: '',
				leaseFile: '',
				hostnameHint: '',
				prefixFilter: '',
				probeUrl: ''
			};

			if (sourceType === 'local_addr') {
				sourceData.family = viewRef.wizardValue(fields.sourceFamily);
				sourceData.address = viewRef.wizardValue(fields.sourceAddress);
			} else if (sourceType === 'public_probe') {
				sourceData.family = viewRef.wizardValue(fields.sourceFamily);
				sourceData.probeUrl = viewRef.wizardValue(fields.sourceProbeUrl);
				sourceData.probeInterface = viewRef.isProbeInterfaceVisible(fields) ? viewRef.wizardValue(fields.probeInterface) : '';
			} else if (sourceType === 'interface') {
				sourceData.family = viewRef.wizardValue(fields.sourceFamily);
				sourceData.interfaceName = viewRef.wizardValue(fields.sourceInterfaceSingle);
			} else if (sourceType === 'dhcpv6_duid') {
				sourceData.family = 'ipv6';
				sourceData.interfaceName = viewRef.wizardValue(fields.sourceInterface);
				sourceData.duid = viewRef.wizardValue(fields.sourceDuid);
				sourceData.iaid = viewRef.wizardValue(fields.sourceIaid);
				sourceData.leaseFile = viewRef.wizardValue(fields.sourceLeaseFile) || '/tmp/odhcpd.leases';
				sourceData.hostnameHint = viewRef.wizardValue(fields.sourceHostnameHint);
				sourceData.prefixFilter = viewRef.wizardValue(fields.sourcePrefixFilter);
			} else if (sourceType === 'dhcpv6_mac') {
				sourceData.family = 'ipv6';
				sourceData.interfaceName = viewRef.wizardValue(fields.sourceInterface);
				sourceData.mac = viewRef.wizardValue(fields.sourceMac);
				sourceData.leaseFile = viewRef.wizardValue(fields.sourceLeaseFile) || '/tmp/odhcpd.leases';
				sourceData.hostnameHint = viewRef.wizardValue(fields.sourceHostnameHint);
				sourceData.prefixFilter = viewRef.wizardValue(fields.sourcePrefixFilter);
			}

			return sourceData;
		}

		function validateNewSource() {
			const sourceData = buildSourceData();
			const sourceType = sourceData.type;
			const isDhcpv6Source = isDhcpv6SourceType(sourceType);

			if (!sourceData.name)
				return _('Source name is required.');
			if (sourceType === 'public_probe' && !sourceData.probeUrl)
				return _('Probe URL is required.');
			if (sourceType === 'local_addr' && !sourceData.address)
				return _('Address is required.');
			if ((sourceType === 'interface' || isDhcpv6Source) && !sourceData.interfaceName)
				return _('WAN/upstream interface is required.');
			if (sourceType === 'dhcpv6_duid' && (!sourceData.duid || !sourceData.iaid))
				return _('Choose a lease candidate or enter the source values manually.');
			if (sourceType === 'dhcpv6_mac' && !sourceData.mac)
				return _('Choose a lease candidate or enter the source values manually.');

			return sourceData;
		}

		function saveNewSource() {
			const sourceData = validateNewSource();

			if (typeof sourceData === 'string') {
				setWizardProbeFeedback(sourceData, 'error');
				return Promise.resolve();
			}

			const sourceVersion = sourceCreate.version;

			return qddns.withBusyButton(saveSourceButton, function() {
				const sectionId = sourceCreate.id || viewRef.nextNumericSectionId();

				setWizardProbeFeedback(_('Probing source IP...'), 'loading');
				sourceProbe.loading = true;
				fields.source.setAttribute('data-source-ip-loading', '1');
				fields.source.removeAttribute('data-source-ip-error');
				setWizardSourceIp(_('Loading...'), 'neutral');
				updateButtons();
				return qddns.probeSourceDraft(sourceData).then(function(result) {
					if (sourceVersion !== sourceCreate.version)
						return result;

					sourceProbe.loading = false;
					fields.source.removeAttribute('data-source-ip-loading');
					if (qddns.isFailedResult(result) || !result.address) {
						const message = qddns.extractResultMessage(result, _('Unable to read source IP.'));
						sourceCreate.clean = false;
						sourceCreate.address = '';
						sourceCreate.family = '';
						sourceCreate.data = null;
						sourceProbe.address = '';
						sourceProbe.family = '';
						setEffectiveSource('', sourceData.name || _('Unnamed source'));
						fields.source.setAttribute('data-source-create-dirty', '1');
						fields.source.setAttribute('data-source-ip-error', '1');
						fields.source.removeAttribute('data-probed-family');
						setWizardSourceIp(message, 'negative');
						setWizardProbeFeedback(message, 'error');
						updateButtons();
						return result;
					}

					const probedFamily = result.family || viewRef.inferSourceFamily(result.address, sourceData.family);
					if (probedFamily)
						sourceData.family = probedFamily;

					sourceCreate.id = sectionId;
					sourceCreate.clean = true;
					sourceCreate.address = result.address;
					sourceCreate.family = probedFamily || '';
					sourceCreate.data = Object.assign({}, sourceData);
					sourceProbe.address = result.address;
					sourceProbe.family = probedFamily || '';
					fields.source.removeAttribute('data-source-create-dirty');
					fields.source.removeAttribute('data-source-ip-error');
					if (sourceProbe.family)
						fields.source.setAttribute('data-probed-family', sourceProbe.family);
					else
						fields.source.removeAttribute('data-probed-family');
					setEffectiveSource(sectionId, sourceData.name || _('Unnamed source'));
					viewRef.syncWizardRecordType(fields.recordType, sourceProbe.family);
					setWizardSourceIp(result.address, 'neutral');
					setWizardProbeFeedback(sourceDetectedMessage(result.address), 'ready');
					updateButtons();
					if (stepIndex === 2)
						updateWizardSummary();
					return result;
				}).catch(function(err) {
					if (sourceVersion !== sourceCreate.version)
						return;

					sourceCreate.clean = false;
					sourceCreate.address = '';
					sourceCreate.family = '';
					sourceCreate.data = null;
					sourceProbe.address = '';
					sourceProbe.family = '';
					setEffectiveSource('', sourceData.name || _('Unnamed source'));
					sourceProbe.loading = false;
					fields.source.removeAttribute('data-source-ip-loading');
					fields.source.setAttribute('data-source-create-dirty', '1');
					fields.source.setAttribute('data-source-ip-error', '1');
					fields.source.removeAttribute('data-probed-family');
					const message = qddns.extractResultMessage(err, _('Unable to read source IP.'));
					setWizardSourceIp(message, 'negative');
					setWizardProbeFeedback(message, 'error');
					updateButtons();
				});
			});
		}

		function probeCurrentSource() {
			return currentSourceMode() === 'new' ? saveNewSource() : updateWizardSourceProbe();
		}

		function updateButtons() {
			previousButton.style.display = stepIndex ? '' : 'none';
			nextButton.style.display = stepIndex < 2 ? '' : 'none';
			saveButton.style.display = stepIndex === 2 ? '' : 'none';
			saveSourceButton.style.display = stepIndex === 0 ? '' : 'none';
			nextButton.disabled = stepIndex === 0 && sourceProbe.loading;
			if (stepIndex === 0 && !effectiveSourceId())
				nextButton.disabled = true;
			if (stepIndex === 0 && fields.source?.getAttribute('data-source-create-dirty') === '1')
				nextButton.disabled = true;
			if (stepIndex === 0 && fields.source?.getAttribute('data-source-ip-error') === '1')
				nextButton.disabled = true;
			if (stepIndex === 2)
				updateWizardSummary();
			viewRef.setWizardStep(modal, stepIndex);
		}

		previousButton.addEventListener('click', L.bind(function() {
			stepIndex = Math.max(0, stepIndex - 1);
			if (stepIndex === 0 && sourceProbe.address)
				setWizardProbeFeedback(sourceDetectedMessage(sourceProbe.address), 'ready');
			else
				resetStepFeedback();
			updateButtons();
		}, this));

		fields.sourceMode.addEventListener('change', updateSourceMode);

		fields.sourceFamily.addEventListener('input', syncNewSourceRecordType);
		fields.sourceFamily.addEventListener('change', syncNewSourceRecordType);
		fields.sourceAddress.addEventListener('input', syncNewSourceRecordType);
		fields.sourceAddress.addEventListener('change', syncNewSourceRecordType);

		fields.source.addEventListener('change', L.bind(function() {
			this.resetWizardFeedback(feedback, stepIndex);
			setEffectiveSource(viewRef.wizardValue(fields.source), viewRef.wizardSelectedText(fields.source, _('Unnamed source')));
			updateWizardSourceProbe();
		}, this));

		fields.recordType.addEventListener('change', L.bind(function() {
			this.resetWizardFeedback(feedback, stepIndex);
			updateProbeInterfaceField();
			if (stepIndex === 2)
				updateWizardSummary();
		}, this));

		fields.sourceType.addEventListener('change', function() {
			updateNewSourceFields();
		});

		fields.probeInterface.addEventListener('change', markProbeInterfaceStale);
		fields.probeInterface.addEventListener('input', markProbeInterfaceStale);

		[
			fields.sourceName,
			fields.sourceFamily,
			fields.sourceAddress,
			fields.sourceProbeUrl,
			fields.sourceInterface,
			fields.sourceInterfaceSingle,
			fields.sourceDuid,
			fields.sourceIaid,
			fields.sourceMac,
			fields.sourceLeaseFile,
			fields.sourceHostnameHint,
			fields.sourcePrefixFilter
		].forEach(function(field) {
			field.addEventListener('input', function() { markNewSourceDirty(); });
			field.addEventListener('change', function() { markNewSourceDirty(); });
			field.addEventListener('cbi-dropdown-change', function() { markNewSourceDirty(); });
		});

		sourceLeaseButton.addEventListener('click', loadWizardLeases);
		saveSourceButton.addEventListener('click', probeCurrentSource);

		nextButton.addEventListener('click', L.bind(function() {
			if (!this.validateWizardStep(fields, feedback, stepIndex))
				return;

			stepIndex = Math.min(2, stepIndex + 1);
			resetStepFeedback();
			updateButtons();
		}, this));

		saveButton.addEventListener('click', L.bind(function() {
			if (!this.validateWizardStep(fields, feedback, stepIndex))
				return Promise.resolve();

			const sourceDraft = currentSourceMode() === 'new' && sourceCreate.clean && sourceCreate.id && sourceCreate.data ? {
				id: sourceCreate.id,
				data: sourceCreate.data
			} : null;

			return this.createRuleFromWizard(fields, feedback, saveButton, sourceDraft);
		}, this));

		updateNewSourceFields(true);
		updateSourceMode();
		updateButtons();
		ui.showModal(_('Guided DDNS rule setup'), [modal], 'qddns-rule-wizard-dialog');

		if (launcher)
			launcher.blur();
		window.setTimeout(function() {
			if (currentSourceMode() === 'new' && typeof fields.sourceName.focus == 'function')
				fields.sourceName.focus();
			else if (fields.source && typeof fields.source.focus == 'function')
				fields.source.focus();
		}, 0);
	},

	renderRuleWizard: function(data) {
		const providers = qddns.normalizeList(data?.catalog?.rules?.providers);
		const sources = qddns.normalizeList(data?.catalog?.sources);
		const settingsUrl = '%s/settings'.format(L.url('admin/services/qddns'));
		const button = E('button', { type: 'button', class: 'btn cbi-button cbi-button-add qddns-rule-wizard-primary' }, [_('Start guided setup')]);

		button.addEventListener('click', L.bind(function() {
			this.showRuleWizardModal(data, button);
		}, this));

		const text = [
			E('h3', {}, _('Guided DDNS rule setup')),
			E('p', { class: 'cbi-section-descr' }, _('Start a short wizard that creates a complete rule with safe defaults. Use the advanced table below for later edits.'))
		];

		if (!providers.length) {
			button.disabled = true;
			button.title = _('Add a provider in Settings before creating a rule.');
			text.push(E('p', { class: 'cbi-section-descr alert-message warning' }, [
				E('a', { href: settingsUrl }, _('Add a provider in Settings before creating a rule.'))
			]));
		} else if (!sources.length) {
			text.push(E('p', { class: 'cbi-section-descr' }, _('Tip: you can create a source inside the wizard, or manage saved sources in Settings.')));
		}

		return E('div', { id: 'qddns-rule-wizard', class: 'cbi-section qddns-panel' }, [
			E('div', { class: 'qddns-page-cta' }, [
				E('div', { class: 'qddns-page-cta-text' }, text),
				button
			]),
		]);
	},

	useNameColumnHeader: function(section) {
		const renderHeaderRows = section.renderHeaderRows;

		section.renderHeaderRows = function() {
			const rows = renderHeaderRows.apply(this, arguments);
			const nameHeader = rows.querySelector('tr.cbi-section-table-titles th');

			if (nameHeader)
				nameHeader.textContent = _('Name');

			return rows;
		};
	},

	useRuleEditorLabels: function(section) {
		section.sectiontitle = function(sectionId) {
			return uci.get('qddns', sectionId, 'name') || _('Unnamed rule');
		};
		section.modaltitle = section.sectiontitle;
		section.renderSectionAdd = function() {
			return E([]);
		};
		this.useNameColumnHeader(section);
	},


	replaceRulesConsole: function() {
		const root = document.getElementById('qddns-rules-console');
		if (root)
			root.replaceWith(this.renderRulesConsole(this.pageData));
	},

	refreshRuntime: function() {
		return this.loadRuntimeState().then(L.bind(function(runtime) {
			this.pageData = this.buildPageData(runtime, this.pageData?.catalog);
			this.replaceRulesConsole();
			return this.pageData;
		}, this));
	},

	showActionResult: function(title, rule, result) {
		qddns.showInfoModal(title, [
				E('div', { class: 'qddns-modal-meta' }, [
					E('p', {}, '%s: %s'.format(_('Rule'), this.getRuleLabel(rule))),
					E('p', {}, '%s: %s'.format(_('Status'), qddns.statusLabel(result.status) || _('Unknown'))),
					E('p', {}, '%s: %s'.format(_('Current IP'), result.current_ip || _('N/A'))),
					E('p', {}, '%s: %s'.format(_('Remote IP'), result.remote_ip || _('N/A'))),
					E('p', {}, '%s: %s'.format(_('Changed'), result.changed ? _('Yes') : _('No'))),
				E('p', {}, '%s: %s'.format(_('Detail'), result.detail || _('N/A')))
			])
		]);
	},

	renderRulesConsole: function(data) {
		const ruleStates = this.getRuleStates();
		const rules = qddns.sortNamedItems(data?.catalog?.rules?.rules || []);
		const table = qddns.renderTable([
			_('Rule'), _('Runtime'), _('Actions')
		], rules.map(L.bind(function(rule) {
			const state = ruleStates[rule.id] || {};
			const runtime = state.status || (rule.enabled ? _('Enabled') : _('Disabled'));
			const runtimeTone = state.status || (rule.enabled ? 'enabled' : 'disabled');

			return [
				this.getRuleLabel(rule),
				qddns.renderStatusBadge(runtime, _('Unknown'), runtimeTone),
				this.renderRuleActions(rule)
			];
		}, this)), _('No rules configured'));

		table.classList.add('qddns-rules-console-table');

		return E('div', { id: 'qddns-rules-console', class: 'cbi-section qddns-panel' }, [
			E('h3', {}, _('Rule Console')),
			table
		]);
	},

	renderRuleActions: function(rule) {
		const wrap = E('div', { class: 'qddns-actions' });
		const ruleLabel = this.getRuleLabel(rule);
		const actions = [
			{ label: _('Run once'), handler: qddns.runRule, title: _('Run Rule'), fallback: _('Unable to run the selected rule.') }
		];

		actions.forEach(L.bind(function(action) {
			const button = E('button', { class: 'btn cbi-button cbi-button-action' }, [action.label]);
			button.addEventListener('click', L.bind(function() {
				return qddns.handleMutationAction(button, action.title, function() {
					return action.handler(rule.id);
				}, L.bind(function(result) {
					this.showActionResult(action.title, rule, result);
				}, this), action.fallback, L.bind(this.refreshRuntime, this));
			}, this));
			wrap.appendChild(button);
		}, this));

		const statusButton = E('button', { class: 'btn cbi-button' }, [_('Status')]);
		statusButton.addEventListener('click', L.bind(function() {
			return qddns.handleReadAction(statusButton, _('Rule Status'), function() {
				return qddns.getRuleStatus(rule.id);
			}, function(result) {
				qddns.showInfoModal(_('Rule Status'), [
						E('h4', {}, ruleLabel),
						E('div', { class: 'qddns-modal-meta' }, [
							E('p', {}, '%s: %s'.format(_('Daemon'), result.running ? _('Running') : _('Stopped'))),
							E('p', {}, '%s: %s'.format(_('Status'), qddns.statusLabel(result.status) || _('Unknown'))),
							E('p', {}, '%s: %s'.format(_('Current IP'), result.current_ip || _('N/A'))),
							E('p', {}, '%s: %s'.format(_('Remote IP'), result.remote_ip || _('N/A'))),
							E('p', {}, '%s: %s'.format(_('Last Result'), qddns.resultLabel(result.last_result) || _('N/A'))),
							E('p', {}, '%s: %s'.format(_('Last Error'), result.last_error || _('N/A'))),
						E('p', {}, '%s: %s'.format(_('Last Check'), result.last_check ? qddns.formatEpoch(result.last_check) : _('N/A'))),
						E('p', {}, '%s: %s'.format(_('Next Run'), result.next_run ? qddns.formatEpoch(result.next_run) : _('N/A')))
					])
				]);
			}, _('Unable to load rule status.'));
		}, this));
		wrap.appendChild(statusButton);

		return wrap;
	},

	renderRuleForm: function(data) {
		const providers = qddns.sortNamedItems(data?.catalog?.rules?.providers || []);
		const sources = qddns.sortNamedItems(data?.catalog?.sources || []);
		const viewRef = this;
		const m = new form.Map('qddns', '', '');
		let s;
		let o;

		s = m.section(form.GridSection, 'rule', _('Rule List'));
		s.addremove = true;
		s.anonymous = false;
		this.useRuleEditorLabels(s);

		o = s.option(form.Value, 'name', _('Name'), _('Name shown in the rule table, console, and log selector.'));
		o.placeholder = _('Unnamed rule');
		o.modalonly = true;
		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;
		o.editable = true;
		o = s.option(form.ListValue, 'record_type', _('Record type'));
		o.value('A');
		o.value('AAAA');
		o.modalonly = true;
		o.validate = L.bind(function(sectionId, value) {
			return this.validateRecordTypeForSource(value, uci.get('qddns', sectionId, 'source'));
		}, this);
		o = s.option(form.ListValue, 'provider', _('Provider'));
		providers.forEach(function(provider) { o.value(provider.id, provider.name || _('Unnamed provider')); });
		o.modalonly = true;
		o = s.option(form.ListValue, 'source', _('Source'));
		sources.forEach(function(source) { o.value(source.id, source.name || _('Unnamed source')); });
		o.modalonly = true;
		o.validate = L.bind(function(sectionId, value) {
			return this.validateRecordTypeForSource(uci.get('qddns', sectionId, 'record_type'), value);
		}, this);
		const sourceWrite = o.write;
		o.write = function(sectionId, value) {
			const result = sourceWrite.apply(this, arguments);
			if (!viewRef.isPublicProbeSource(value))
				uci.unset('qddns', sectionId, 'probe_interface');
			return result;
		};
		o = s.option(widgets.DeviceSelect, 'probe_interface', _('Public probe outbound interface'), _('Optional for public probe rules. Choose the WAN/upstream interface used for public IP detection; empty uses the system default route.'));
		o.modalonly = true;
		o.multiple = false;
		o.noaliases = true;
		o.nocreate = true;
		sources.forEach(L.bind(function(source) {
			if (source?.type === 'public_probe')
				o.depends({ source: source.id });
		}, this));
		o.validate = L.bind(function(sectionId, value) {
			if (!String(value || '').trim())
				return true;
			if (!this.isPublicProbeSource(uci.get('qddns', sectionId, 'source')))
				return _('Public probe outbound interface only applies to public probe rules.');
			return true;
		}, this);
		const probeInterfaceWrite = o.write;
		o.write = function(sectionId, value) {
			if (!viewRef.isPublicProbeSource(uci.get('qddns', sectionId, 'source'))) {
				uci.unset('qddns', sectionId, 'probe_interface');
				return;
			}
			return probeInterfaceWrite.apply(this, arguments);
		};

		o = s.option(form.DummyValue, '_provider_name', _('Provider'));
		o.modalonly = false;
		o.cfgvalue = function(sectionId) {
			var provider = uci.get('qddns', sectionId, 'provider') || '';
			return provider ? viewRef.getProviderLabel(provider) : '-';
		};

		o = s.option(form.DummyValue, '_source_name', _('Source'));
		o.modalonly = false;
		o.cfgvalue = function(sectionId) {
			var source = uci.get('qddns', sectionId, 'source') || '';
			return source ? viewRef.getSourceLabel(source) : '-';
		};

		o = s.option(form.DummyValue, '_runtime', _('Runtime'));
		o.modalonly = false;
		o.cfgvalue = function(sectionId) {
			const ruleStates = viewRef.getRuleStates();
			const state = ruleStates[sectionId] || {};
			const enabled = uci.get('qddns', sectionId, 'enabled') === '1';
			const runtime = state.status || (enabled ? 'enabled' : 'disabled');
			return qddns.statusLabel(runtime);
		};

		o = s.option(form.Value, '_domain', _('Domain'));
		o.placeholder = 'home.example.com';
		o.modalonly = true;
		o.cfgvalue = function(sectionId) {
			var zone = uci.get('qddns', sectionId, 'zone') || '';
			var record = uci.get('qddns', sectionId, 'record_name') || '';
			if (record && zone)
				return record + '.' + zone;
			return zone || record || '';
		};
		o.write = function(sectionId, value) {
			var domain = String(value || '').trim();
			var dot = domain.indexOf('.');
			if (dot > 0) {
				uci.set('qddns', sectionId, 'record_name', domain.substring(0, dot));
				uci.set('qddns', sectionId, 'zone', domain.substring(dot + 1));
			} else {
				uci.set('qddns', sectionId, 'record_name', domain);
				uci.set('qddns', sectionId, 'zone', '');
			}
		};

		o = s.option(form.DummyValue, '_run_actions', _('Quick Actions'));
		o.modalonly = true;
		o.rawhtml = true;
		o.cfgvalue = function(sectionId) {
			var wrap = E('div', { class: 'qddns-actions' });
			var runBtn = E('button', { type: 'button', class: 'btn cbi-button cbi-button-action' }, [_('Run once')]);
			var statusBtn = E('button', { type: 'button', class: 'btn cbi-button' }, [_('Status')]);

			runBtn.addEventListener('click', function() {
				return qddns.handleMutationAction(runBtn, _('Run Rule'), function() {
					return qddns.runRule(sectionId);
				}, function(result) {
					var ruleName = uci.get('qddns', sectionId, 'name') || _('Unnamed rule');
					qddns.showInfoModal(_('Run Rule'), [
						E('div', { class: 'qddns-modal-meta' }, [
							E('p', {}, '%s: %s'.format(_('Rule'), ruleName)),
							E('p', {}, '%s: %s'.format(_('Status'), qddns.statusLabel(result.status) || _('Unknown'))),
							E('p', {}, '%s: %s'.format(_('Current IP'), result.current_ip || _('N/A'))),
							E('p', {}, '%s: %s'.format(_('Changed'), result.changed ? _('Yes') : _('No')))
						])
					]);
				}, _('Unable to run the selected rule.'), function() {
					return viewRef.refreshRuntime();
				});
			});

			statusBtn.addEventListener('click', function() {
				return qddns.handleReadAction(statusBtn, _('Rule Status'), function() {
					return qddns.getRuleStatus(sectionId);
				}, function(result) {
					var ruleName = uci.get('qddns', sectionId, 'name') || _('Unnamed rule');
					qddns.showInfoModal(_('Rule Status'), [
						E('h4', {}, ruleName),
						E('div', { class: 'qddns-modal-meta' }, [
							E('p', {}, '%s: %s'.format(_('Status'), qddns.statusLabel(result.status) || _('Unknown'))),
							E('p', {}, '%s: %s'.format(_('Current IP'), result.current_ip || _('N/A'))),
							E('p', {}, '%s: %s'.format(_('Remote IP'), result.remote_ip || _('N/A'))),
							E('p', {}, '%s: %s'.format(_('Last Check'), result.last_check ? qddns.formatEpoch(result.last_check) : _('N/A')))
						])
					]);
				}, _('Unable to load rule status.'));
			});

			wrap.appendChild(runBtn);
			wrap.appendChild(statusBtn);
			return wrap;
		};
		o = s.option(form.Value, 'ttl', _('TTL'));
		o.datatype = 'uinteger';
		o.modalonly = true;
		o = s.option(form.Flag, 'proxied', _('Proxied'));
		o.modalonly = true;
		o = s.option(form.Value, 'check_interval', _('Check interval'));
		o.datatype = 'uinteger';
		o.modalonly = true;
		o = s.option(form.Value, 'force_interval', _('Force interval'));
		o.datatype = 'uinteger';
		o.modalonly = true;
		o = s.option(form.Value, 'retry_count', _('Retry count'));
		o.datatype = 'uinteger';
		o.modalonly = true;
		o = s.option(form.Value, 'retry_backoff', _('Retry backoff'));
		o.datatype = 'uinteger';
		o.modalonly = true;

		return m.render();
	},

	render: function(data) {
		this.pageData = data || this.buildPageData({}, {});
		this.ensurePageStyle();

		return this.renderRuleForm(this.pageData).then(L.bind(function(formEl) {
			return E('div', { class: 'qddns-rules-page' }, [
				qddns.renderPageHeader({
					title: _('Rules'),
					description: _('Start with the guided setup to create a complete rule, then run and monitor saved rules in the console. Use the advanced table for detailed edits.')
				}),
				this.renderRuleWizard(this.pageData),
				E('div', { class: 'qddns-wide-form qddns-rules-form' }, [formEl])
			]);
		}, this));
	}
});
