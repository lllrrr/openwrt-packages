'use strict';
'require ui';
'require uci';
'require view';
'require form';
'require tools.widgets as widgets';
'require view.qddns.shared as qddns';

const PROVIDER_TEMPLATES = {
	cloudflare: {
		label: _('Cloudflare'),
		values: {
			name: _('Cloudflare'),
			type: 'cloudflare'
		}
	},
	dnspod: {
		label: _('DNSPod'),
		values: {
			name: _('DNSPod'),
			type: 'dnspod'
		}
	},
	aliyun: {
		label: _('Aliyun'),
		values: {
			name: _('Aliyun'),
			type: 'aliyun'
		}
	},
	custom_http: {
		label: _('Custom HTTP'),
		values: {
			name: _('Custom HTTP'),
			type: 'custom_http',
			method: 'POST',
			url: 'https://api.example.com/ddns/update',
			headers_json: '{"Content-Type":"application/json"}',
			body_template: '{"zone":"{{zone}}","record":"{{record_name}}","type":"{{record_type}}","ip":"{{ip}}"}',
			success_contains: 'ok'
		}
	}
};

const QDDNS_SETTINGS_STYLE_ID = 'qddns-settings-style';
const SOURCE_OPTION_FIELDS = ['family', 'address', 'interface', 'duid', 'iaid', 'mac', 'lease_file', 'hostname_hint', 'prefix_filter', 'probe_url', 'script'];
const SOURCE_FIELDS_BY_TYPE = {
	local_addr: ['family', 'address'],
	interface: ['family', 'interface'],
	public_probe: ['family', 'probe_url'],
	script: ['family', 'script'],
	dhcpv6_duid: ['interface', 'duid', 'iaid', 'lease_file', 'hostname_hint', 'prefix_filter'],
	dhcpv6_mac: ['interface', 'mac', 'lease_file', 'hostname_hint', 'prefix_filter']
};
const QDDNS_SETTINGS_STYLE = [
	'.qddns-settings-page{margin-bottom:var(--qddns-space-4)}',
	'.qddns-dhcpv6-lease-status{display:grid;gap:var(--qddns-space-2);width:100%;max-width:100%;min-width:0;text-align:left}',
	'.qddns-source-ip-probe{display:flex;flex-wrap:wrap;align-items:center;gap:var(--qddns-space-2);max-width:100%;min-width:0}',
	'.qddns-source-ip-probe .cbi-button{margin:0}',
	'.qddns-source-ip-status{display:block;max-width:100%;min-width:min(100%,8rem);overflow-wrap:anywhere;text-align:left}',
	'.qddns-source-ip-status[data-tone="warning"]{opacity:0.78}',
	'.qddns-source-ip-status[data-tone="negative"]{color:var(--qddns-negative-text,inherit)}',
	''
].join('');

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(qddns.listRules(), { providers: [], rules: [] }),
			L.resolveDefault(qddns.listSources(), { result: [] }),
			uci.load('qddns')
		]).then(function(data) {
			return qddns.normalizeCatalogState(data[0], data[1]);
		});
	},

	ensureSettingsStyle: function() {
		qddns.ensureCommonStyle();

		if (document.getElementById(QDDNS_SETTINGS_STYLE_ID))
			return;

		document.head.appendChild(E('style', { id: QDDNS_SETTINGS_STYLE_ID }, [QDDNS_SETTINGS_STYLE]));
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

	validateVisibleName: function(name, emptyMessage) {
		if (!name)
			return emptyMessage;

		return null;
	},

	getDhcpv6OptionSet: function(section) {
		const options = Object.assign({}, this.sourceDhcpv6Options || {});
		const children = section?.children || [];

		children.forEach(function(option) {
			switch (option.option) {
			case 'name':
				options.name = option;
				break;
			case 'type':
				options.type = option;
				break;
			case 'family':
				options.family = option;
				break;
			case 'address':
				options.address = option;
				break;
			case 'duid':
				options.duid = option;
				break;
			case 'mac':
				options.mac = option;
				break;
			case 'iaid':
				options.iaid = option;
				break;
			case 'lease_file':
				options.leaseFile = option;
				break;
			case 'hostname_hint':
				options.hostnameHint = option;
				break;
			case 'prefix_filter':
				options.prefixFilter = option;
				break;
			case 'interface':
				options.interface = option;
				break;
			case 'probe_url':
				options.probeUrl = option;
				break;
			case 'probe_interface':
				options.probeInterface = option;
				break;
			}
		});

		return options;
	},

	getSourceOptionValue: function(option, sectionId) {
		if (!option || typeof option.getUIElement != 'function' || !option.map?.root)
			return '';

		const widget = option.getUIElement(sectionId);
		if (!widget)
			return '';

		if (typeof widget.getValue == 'function') {
			const value = widget.getValue();
			return Array.isArray(value) ? value.join(',') : String(value || '');
		}

		const input = widget.node?.querySelector('input,select,textarea');
		return input ? String(input.value || '') : '';
	},

	interfaceValues: function(value) {
		return L.toArray(value).flatMap(function(item) {
			return String(item || '').split(/,+/);
		}).map(function(item) {
			return item.trim();
		}).filter(function(item, index, values) {
			return item && values.indexOf(item) === index;
		});
	},

	singleInterfaceValue: function(value) {
		return this.interfaceValues(value)[0] || '';
	},

	sourceFieldsForType: function(sourceType) {
		return SOURCE_FIELDS_BY_TYPE[sourceType] || [];
	},

	isSourceFieldActive: function(field, sourceType) {
		return this.sourceFieldsForType(sourceType).indexOf(field) > -1;
	},

	rulesReferencingSource: function(sourceId) {
		const id = String(sourceId || '');

		return (uci.sections('qddns', 'rule') || []).filter(function(rule) {
			return String(rule.source || '') === id;
		});
	},

	sourceRuleProbeInterface: function(sourceId) {
		const rules = this.rulesReferencingSource(sourceId);

		if (rules.length !== 1)
			return '';

		return this.singleInterfaceValue(rules[0].probe_interface);
	},

	writeRuleProbeInterfaceForSource: function(sourceId, sourceType, value) {
		const rules = this.rulesReferencingSource(sourceId);

		if (rules.length !== 1)
			return;

		const rule = rules[0];
		const normalized = sourceType === 'public_probe' ? this.singleInterfaceValue(value) : '';
		if (normalized)
			uci.set('qddns', rule['.name'], 'probe_interface', normalized);
		else
			uci.unset('qddns', rule['.name'], 'probe_interface');
	},

	clearRuleProbeInterfaceForSource: function(sourceId) {
		this.rulesReferencingSource(sourceId).forEach(function(rule) {
			uci.unset('qddns', rule['.name'], 'probe_interface');
		});
	},

	cleanupSourceTypeOptions: function(sectionId, sourceType) {
		const fields = this.sourceFieldsForType(sourceType);

		SOURCE_OPTION_FIELDS.forEach(function(field) {
			if (fields.indexOf(field) === -1)
				uci.unset('qddns', sectionId, field);
		});
	},

	guardSourceOptionWrite: function(option, field) {
		const viewRef = this;
		const write = option.write;

		option.write = function(sectionId, value) {
			const sourceType = uci.get('qddns', sectionId, 'type') || viewRef.getSourceOptionValue(viewRef.sourceDhcpv6Options?.type, sectionId);

			if (!viewRef.isSourceFieldActive(field, sourceType)) {
				uci.unset('qddns', sectionId, field);
				return;
			}

			return write.apply(this, arguments);
		};
	},

	getSourceType: function(sectionId, optionSet) {
		return this.getSourceOptionValue(optionSet?.type, sectionId) || uci.get('qddns', sectionId, 'type') || '';
	},

	buildSourceDraftData: function(sectionId, optionSet) {
		const sourceType = this.getSourceType(sectionId, optionSet);
		const sourceData = {
			name: this.getSourceOptionValue(optionSet?.name, sectionId) || uci.get('qddns', sectionId, 'name') || '',
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
			probeUrl: '',
			probeInterface: ''
		};

		if (sourceType === 'local_addr') {
			sourceData.family = this.getSourceOptionValue(optionSet?.family, sectionId);
			sourceData.address = this.getSourceOptionValue(optionSet?.address, sectionId);
		} else if (sourceType === 'interface') {
			sourceData.family = this.getSourceOptionValue(optionSet?.family, sectionId);
			sourceData.interfaceName = this.getSourceOptionValue(optionSet?.interface, sectionId);
		} else if (sourceType === 'dhcpv6_duid') {
			sourceData.interfaceName = this.getSourceOptionValue(optionSet?.interface, sectionId);
			sourceData.duid = this.getSourceOptionValue(optionSet?.duid, sectionId);
			sourceData.iaid = this.getSourceOptionValue(optionSet?.iaid, sectionId);
			sourceData.leaseFile = this.getSourceOptionValue(optionSet?.leaseFile, sectionId);
			sourceData.hostnameHint = this.getSourceOptionValue(optionSet?.hostnameHint, sectionId);
			sourceData.prefixFilter = this.getSourceOptionValue(optionSet?.prefixFilter, sectionId);
		} else if (sourceType === 'dhcpv6_mac') {
			sourceData.interfaceName = this.getSourceOptionValue(optionSet?.interface, sectionId);
			sourceData.mac = this.getSourceOptionValue(optionSet?.mac, sectionId);
			sourceData.leaseFile = this.getSourceOptionValue(optionSet?.leaseFile, sectionId);
			sourceData.hostnameHint = this.getSourceOptionValue(optionSet?.hostnameHint, sectionId);
			sourceData.prefixFilter = this.getSourceOptionValue(optionSet?.prefixFilter, sectionId);
		} else if (sourceType === 'public_probe') {
			sourceData.family = this.getSourceOptionValue(optionSet?.family, sectionId);
			sourceData.probeUrl = this.getSourceOptionValue(optionSet?.probeUrl, sectionId);
		}

		sourceData.probeInterface = sourceType === 'public_probe' ? this.getSourceOptionValue(optionSet?.probeInterface, sectionId) : '';
		return sourceData;
	},

	setSourceIpStatus: function(node, message, tone) {
		node.textContent = message || _('N/A');
		node.setAttribute('data-tone', tone || 'neutral');
	},

	bindSourceOptionChange: function(sectionId, optionSet, handler, optionNames) {
		const names = optionNames || ['type', 'family', 'address', 'duid', 'iaid', 'mac', 'leaseFile', 'hostnameHint', 'prefixFilter', 'interface', 'probeUrl', 'probeInterface'];

		window.setTimeout(function() {
			names.forEach(function(name) {
				const option = optionSet?.[name];
				if (!option || typeof option.getUIElement != 'function')
					return;

				const widget = option.getUIElement(sectionId);
				const node = widget?.node;
				const input = node?.querySelector('input,select,textarea') || node;
				if (!input || typeof input.addEventListener != 'function')
					return;

				input.addEventListener('input', handler);
				input.addEventListener('change', handler);
			});
		}, 0);
	},

	renderSourceIpStatus: function(sectionId, optionSet) {
		const node = E('span', { class: 'qddns-source-ip-status', 'data-source-ip-status': sectionId }, [_('N/A')]);
		const probeButton = E('button', { type: 'button', class: 'btn cbi-button cbi-button-action' }, [_('Probe')]);
		const sourceIpProbe = { token: 0 };

		probeButton.disabled = !qddns.isProbeableSourceType(this.getSourceType(sectionId, optionSet));
		if (probeButton.disabled)
			this.setSourceIpStatus(node, _('Not previewable in LuCI'), 'warning');

		this.bindSourceOptionChange(sectionId, optionSet, L.bind(function() {
			sourceIpProbe.token++;
			probeButton.disabled = !qddns.isProbeableSourceType(this.getSourceType(sectionId, optionSet));
			this.setSourceIpStatus(node, probeButton.disabled ? _('Not previewable in LuCI') : _('Probe source IP to preview the current form values.'), 'warning');
		}, this));

		probeButton.addEventListener('click', L.bind(function() {
			return qddns.withBusyButton(probeButton, L.bind(function() {
				return this.updateSourceIpStatus(sectionId, optionSet, node, sourceIpProbe);
			}, this));
		}, this));

		return E('span', { class: 'qddns-source-ip-probe' }, [node, probeButton]);
	},

	updateSourceIpStatus: function(sectionId, optionSet, node, sourceIpProbe) {
		const sourceType = this.getSourceType(sectionId, optionSet);
		sourceIpProbe.token++;
		const token = sourceIpProbe.token;

		if (!qddns.isProbeableSourceType(sourceType)) {
			this.setSourceIpStatus(node, _('Not previewable in LuCI'), 'warning');
			return Promise.resolve();
		}

		this.setSourceIpStatus(node, _('Loading...'), 'neutral');

		return qddns.probeSourceDraft(this.buildSourceDraftData(sectionId, optionSet)).then(L.bind(function(result) {
			if (token !== sourceIpProbe.token)
				return result;

			if (qddns.isFailedResult(result) || !result.address) {
				this.setSourceIpStatus(node, qddns.extractResultMessage(result, _('Unable to read source IP.')), 'negative');
				return result;
			}

			this.setSourceIpStatus(node, result.address, 'neutral');
			return result;
		}, this)).catch(L.bind(function(err) {
			if (token !== sourceIpProbe.token)
				return;

			this.setSourceIpStatus(node, qddns.extractResultMessage(err, _('Unable to read source IP.')), 'negative');
		}, this));
	},

	isDhcpv6DuidSource: function(sectionId, optionSet) {
		return this.getSourceType(sectionId, optionSet) === 'dhcpv6_duid';
	},

	getDhcpv6LeaseMode: function(sectionId, optionSet) {
		return this.isDhcpv6DuidSource(sectionId, optionSet) ? 'duid' : 'mac';
	},

	setSourceOptionValue: function(option, sectionId, value) {
		if (!option)
			return;

		const widget = option.getUIElement(sectionId);
		if (!widget || typeof widget.setValue != 'function')
			return;

		const normalized = option.multiple ? this.interfaceValues(value) : (value == null ? '' : String(value));
		widget.setValue(normalized);

		if (widget.node) {
			widget.node.setAttribute('data-changed', 'true');

			const input = widget.node.querySelector('input,select,textarea') || widget.node;
			input.dispatchEvent(new Event('input', { bubbles: true }));
			input.dispatchEvent(new Event('change', { bubbles: true }));
			widget.node.dispatchEvent(new CustomEvent('widget-update', { bubbles: true }));
			widget.node.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
		}

		if (typeof option.triggerValidation == 'function')
			option.triggerValidation(sectionId);
	},

	fillDhcpv6Lease: function(sectionId, lease, feedback, optionSet) {
		const options = optionSet || this.sourceDhcpv6Options || {};
		const isDuidSource = this.isDhcpv6DuidSource(sectionId, options);

		this.setSourceOptionValue(options.family, sectionId, 'ipv6');
		if (isDuidSource) {
			this.setSourceOptionValue(options.duid, sectionId, lease?.duid || '');
			this.setSourceOptionValue(options.iaid, sectionId, lease?.iaid || '');
		} else {
			this.setSourceOptionValue(options.mac, sectionId, lease?.mac || '');
		}
		this.setSourceOptionValue(options.leaseFile, sectionId, lease?.lease_file || '/tmp/odhcpd.leases');
		this.setSourceOptionValue(options.hostnameHint, sectionId, lease?.hostname || '');
		this.setSourceOptionValue(options.prefixFilter, sectionId, '');

		if (feedback)
			feedback.textContent = isDuidSource ? _('Selected DHCPv6 lease values have been filled. Keep the WAN interface selected separately.') : _('Selected LAN host MAC has been filled. Keep the WAN interface selected separately.');
	},

	filterDhcpv6Choices: function(sectionId, leases, optionSet) {
		const isDuidSource = this.isDhcpv6DuidSource(sectionId, optionSet);

		return qddns.normalizeList(leases).filter(function(lease) {
			const prefixes = qddns.normalizeList(lease?.prefixes);

			if (!prefixes.length)
				return false;

			return isDuidSource ? !!(lease?.duid && lease?.iaid) : !!lease?.mac;
		});
	},

	renderDhcpv6LeaseStatus: function(sectionId, optionSet) {
		this.ensureSettingsStyle();

		const loadButton = E('button', { type: 'button', class: 'btn cbi-button cbi-button-action' });
			const results = E('div', { class: 'qddns-lease-results' });
		const resetResults = L.bind(function() {
			const isDuidSource = this.isDhcpv6DuidSource(sectionId, optionSet);

			loadButton.replaceChildren(isDuidSource ? _('Read current DUID') : _('Read current MAC'));
			results.replaceChildren(E('div', { class: 'cbi-value-description' }, isDuidSource ? _('Read current DHCPv6 lease candidates, then choose one to fill the DUID source fields.') : _('Read current LAN host candidates, then choose one to fill the MAC source fields.')));
		}, this);

		resetResults();
		this.bindSourceOptionChange(sectionId, optionSet, resetResults, ['type']);

		loadButton.addEventListener('click', L.bind(function(ev) {
			return this.handleDhcpv6LeaseLoad(ev, sectionId, results, optionSet);
		}, this));

		return E('div', { class: 'qddns-dhcpv6-lease-status' }, [
			E('div', { class: 'qddns-actions' }, [loadButton]),
			results
		]);
	},

	renderDhcpv6LeaseCard: function(sectionId, lease, feedback, optionSet) {
		const prefixes = qddns.normalizeList(lease?.prefixes);
		const ipv4 = qddns.normalizeList(lease?.ipv4);
		const isDuidSource = this.isDhcpv6DuidSource(sectionId, optionSet);
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
			onSelect: L.bind(function() {
				this.fillDhcpv6Lease(sectionId, lease, feedback, optionSet);
			}, this)
		});
	},

	renderDhcpv6LeaseResults: function(sectionId, leases, optionSet) {
		const list = this.filterDhcpv6Choices(sectionId, leases, optionSet);
		const isDuidSource = this.isDhcpv6DuidSource(sectionId, optionSet);
		const emptyMessage = isDuidSource ? _('No DHCPv6 leases found.') : _('No LAN hosts with public IPv6 found.');
		const feedback = E('div', { class: 'cbi-value-description' }, list.length ? (isDuidSource ? _('Choose a current DUID to fill DUID, IAID, and hostname hint. Keep the WAN interface selected separately.') : _('Choose a current MAC to fill MAC, LAN IP identity, and hostname hint. Keep the WAN interface selected separately.')) : emptyMessage);

		if (!list.length)
			return E('div', { class: 'qddns-lease-results' }, [feedback]);

		return E('div', { class: 'qddns-lease-results' }, [
			feedback,
			E('div', { class: 'qddns-lease-list' }, list.map(L.bind(function(lease) {
				return this.renderDhcpv6LeaseCard(sectionId, lease, feedback, optionSet);
			}, this)))
		]);
	},

	showDhcpv6LeaseResults: function(anchor, node, target) {
		if (target) {
			target.replaceChildren.apply(target, Array.from(node.childNodes));
			return;
		}

		const field = target || anchor?.closest('.cbi-value-field') || anchor?.parentNode;
		if (!field)
			return;

		const existing = field.querySelector('.qddns-lease-results');
		if (existing)
			existing.remove();

		field.appendChild(node);
	},

	handleDhcpv6LeaseLoad: function(ev, sectionId, target, optionSet) {
		const button = ev.currentTarget;
		const title = this.isDhcpv6DuidSource(sectionId, optionSet) ? _('DHCPv6 leases') : _('LAN hosts');

		return qddns.withBusyButton(button, L.bind(function() {
			return qddns.listDhcpv6Leases(this.getDhcpv6LeaseMode(sectionId, optionSet)).then(L.bind(function(result) {
				if (qddns.isFailedResult(result)) {
					qddns.showFailureModal(title, result, _('Unable to load host candidates.'));
					return result;
				}

				this.showDhcpv6LeaseResults(button, this.renderDhcpv6LeaseResults(sectionId, result.leases, optionSet), target);
				return result;
			}, this)).catch(function(err) {
				qddns.showFailureModal(title, { error: qddns.extractResultMessage(err, _('Unable to load host candidates.')) }, _('Unable to load host candidates.'));
			});
		}, this));
	},

	getSourceLabel: function(source) {
		return source?.name || _('Unnamed source');
	},

	getProviderLabel: function(provider) {
		return provider?.name || _('Unnamed provider');
	},

	createProviderFromTemplate: function(providerName, templateId) {
		const template = PROVIDER_TEMPLATES[templateId] || PROVIDER_TEMPLATES.custom_http;
		const sectionId = uci.add('qddns', 'provider', this.nextNumericSectionId());

		Object.keys(template.values).forEach(function(key) {
			uci.set('qddns', sectionId, key, template.values[key]);
		});
		uci.set('qddns', sectionId, 'name', providerName);

		return uci.save().then(function() {
			ui.addNotification(null, E('p', _('Provider template has been staged. Reloading settings page...')), 'info');
			window.location.reload();
		});
	},

	renderProviderTemplatePanel: function() {
		const nameInput = E('input', {
			type: 'text',
			class: 'cbi-input-text',
			placeholder: _('Provider name')
		});
		const templateSelect = E('select', { class: 'cbi-input-select' });
		const feedback = E('div', { class: 'cbi-value-description' }, _('This name is shown in provider tables and rule selectors.'));
		const createButton = E('button', { type: 'button', class: 'btn cbi-button cbi-button-add' }, [_('Create from template')]);

		Object.keys(PROVIDER_TEMPLATES).forEach(function(templateId) {
			templateSelect.appendChild(E('option', { value: templateId }, [PROVIDER_TEMPLATES[templateId].label]));
		});

		nameInput.addEventListener('input', function() {
			nameInput.classList.remove('cbi-input-invalid');
		});

		createButton.addEventListener('click', L.bind(function() {
			const providerName = nameInput.value.trim();
			const validationError = this.validateVisibleName(providerName, _('Provider name must not be empty.'));

			if (validationError) {
				nameInput.classList.add('cbi-input-invalid');
				feedback.textContent = validationError;
				return;
			}

			createButton.disabled = true;
			createButton.classList.add('qddns-busy');

			return this.createProviderFromTemplate(providerName, templateSelect.value).catch(function(err) {
				createButton.disabled = false;
				createButton.classList.remove('qddns-busy');
				qddns.showFailureModal(_('Provider templates'), { error: qddns.extractResultMessage(err, _('Unable to create provider from template.')) }, _('Unable to create provider from template.'));
			});
		}, this));

		return E('div', { class: 'cbi-section qddns-panel' }, [
			E('h3', {}, _('Provider templates')),
			E('p', { class: 'cbi-section-descr' }, _('Create a new named provider from a safe template. The name can be changed later.')),
			E('p', { class: 'cbi-section-descr' }, _('Copy template values into a new provider without exposing credentials in the main table.')),
			E('div', { class: 'cbi-value' }, [
				E('label', { class: 'cbi-value-title' }, _('Provider name')),
				E('div', { class: 'cbi-value-field' }, [nameInput, feedback])
			]),
			E('div', { class: 'cbi-value' }, [
				E('label', { class: 'cbi-value-title' }, _('Template')),
				E('div', { class: 'cbi-value-field' }, [templateSelect])
			]),
			E('div', { class: 'cbi-value' }, [
				E('label', { class: 'cbi-value-title' }, _('Copy template')),
				E('div', { class: 'cbi-value-field' }, [createButton])
			])
		]);
	},

	renderSourceProbePanel: function(sources) {
		return qddns.renderTableSection(_('Source Probe'), [
			_('Name'), _('Type'), _('Family'), _('Hint'), _('Actions')
		], qddns.normalizeList(sources).map(L.bind(function(src) {
			const sourceName = this.getSourceLabel(src);
			let actionNode;

			if (!qddns.isProbeableSourceType(src.type)) {
				actionNode = qddns.renderBadge(_('Not previewable in LuCI'), 'warning');
			} else {
				const probeButton = E('button', { class: 'btn cbi-button cbi-button-action' }, [_('Probe')]);
				const probeSource = L.bind(function() {
					if (src.type === 'public_probe')
						return qddns.probeSourceForRuleDraft(src.id, this.sourceRuleProbeInterface(src.id));

					return qddns.probeSource(src.id);
				}, this);
				probeButton.addEventListener('click', function() {
					return qddns.handleReadAction(probeButton, _('Source Probe'), function() {
						return probeSource();
					}, function(result) {
						qddns.showInfoModal(_('Source Probe'), [
							E('div', { class: 'qddns-modal-meta' }, [
								E('p', {}, '%s: %s'.format(_('Source'), sourceName)),
								E('p', {}, '%s: %s'.format(_('Address'), result.address || _('N/A'))),
								E('p', {}, '%s: %s'.format(_('Family'), result.family || _('N/A'))),
								E('p', {}, '%s: %s'.format(_('Detail'), result.detail || _('N/A')))
							])
						]);
					}, _('Unable to probe the selected source.'));
				});
				actionNode = probeButton;
			}

			return [
				sourceName,
				src.type || '-',
				src.family || '-',
				src.hint || '-',
				actionNode
			];
		}, this)), _('No sources configured'));
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

	useNameCreateFlow: function(section, options) {
		const viewRef = this;
		const handleAdd = section.handleAdd;

		section.sectiontitle = function(sectionId) {
			return uci.get('qddns', sectionId, 'name') || options.unnamed;
		};
		section.modaltitle = section.sectiontitle;

		section.renderSectionAdd = function(extraClass) {
			if (!this.addremove)
				return E([]);

			const createEl = E('div', { class: 'cbi-section-create' });
			const buttonTitle = this.titleFn('addbtntitle') || _('Add');
			const input = E('input', {
				type: 'text',
				class: 'cbi-input-text',
				placeholder: options.placeholder,
				'aria-label': options.placeholder,
				title: options.placeholder,
				disabled: this.map.readonly || null
			});
			const button = E('button', {
				class: 'cbi-button cbi-button-add',
				title: buttonTitle,
				click: ui.createHandlerFn(this, function(ev) {
					return this.handleAdd(ev, input.value);
				}),
				disabled: this.map.readonly || true
			}, [buttonTitle]);

			if (extraClass != null)
				createEl.classList.add(extraClass);

			input.addEventListener('input', L.bind(function() {
				input.classList.remove('cbi-input-invalid');
				button.disabled = this.map.readonly || !String(input.value || '').trim() ? true : null;
			}, this));

			createEl.appendChild(E('div', {}, [
				input,
				E('div', { class: 'cbi-value-description' }, options.description)
			]));
			createEl.appendChild(button);
			return createEl;
		};

		section.handleAdd = function(ev, name) {
			const visibleName = String(name || '').trim();
			const validationError = viewRef.validateVisibleName(visibleName, options.emptyMessage);

			if (validationError) {
				ui.addNotification(null, E('p', validationError), 'warning');
				return Promise.resolve();
			}

			const configName = this.uciconfig || this.map.config;
			const sectionId = viewRef.nextNumericSectionId();
			const addTask = handleAdd.call(this, ev, sectionId);
			uci.set(configName, sectionId, 'name', visibleName);
			return addTask;
		};

		this.useNameColumnHeader(section);
	},

	renderConfigForms: function(data) {
		this.ensureSettingsStyle();

		const viewRef = this;
		const m = new form.Map('qddns', '', '');
		let s;
		let o;

		s = m.section(form.NamedSection, 'main', 'qddns', _('Daemon Settings'), _('These values are saved to UCI. Rules on the dedicated rules page reuse the latest saved sources and providers after you save and reload.'));
		o = s.option(form.Flag, 'enabled', _('Enable daemon'));
		o.rmempty = false;

		o = s.option(form.Value, 'log_dir', _('Log directory'));
		o.placeholder = '/var/log/qddns';

		o = s.option(form.Value, 'state_dir', _('State directory'));
		o.placeholder = '/var/run/qddns';

		o = s.option(form.Value, 'poll_interval', _('Poll interval (seconds)'));
		o.datatype = 'range(1, 86400)';

		o = s.option(form.Value, 'timeout', _('Default timeout (seconds)'));
		o.datatype = 'range(1, 30)';

		o = s.option(form.ListValue, 'log_level', _('Log level'));
		['error', 'warn', 'info', 'debug', 'trace'].forEach(function(level) { o.value(level); });

		o = s.option(widgets.DeviceSelect, 'lan_interface', _('LAN interface'), _('LAN-facing interface for IPv6 neighbor discovery. Used to refresh the neighbor table before reading MAC candidates.'));
		o.multiple = false;
		o.noaliases = true;
		o.nocreate = true;

		s = m.section(form.GridSection, 'source', _('Source Library'), _('Saved sources are available for source probe below and become selectable on the rules page after saving and reloading. Names stay editable.'));
		s.addremove = true;
		s.anonymous = false;
		s.nodescriptions = true;
		this.useNameCreateFlow(s, {
			placeholder: _('New source name'),
			description: _('Enter the source name shown in tables and rule selectors.'),
			emptyMessage: _('Source name must not be empty.'),
			unnamed: _('Unnamed source')
		});

		o = s.option(form.Value, 'name', _('Name'), _('Name shown in tables, probes, and rule selectors.'));
		o.placeholder = _('Unnamed source');
		o.modalonly = true;
		this.sourceDhcpv6Options = {};
		this.sourceDhcpv6Options.name = o;

		o = s.option(form.ListValue, 'type', _('Type'));
		o.value('local_addr', _('Local address'));
		o.value('dhcpv6_duid', _('DHCPv6 DUID'));
		o.value('dhcpv6_mac', _('MAC'));
		o.value('interface', _('Interface'));
		o.value('public_probe', _('Public probe'));
		o.value('script', _('Script'));
		this.sourceDhcpv6Options.type = o;
		const sourceTypeWrite = o.write;
		o.write = function(sectionId, value) {
			const result = sourceTypeWrite.apply(this, arguments);
			viewRef.cleanupSourceTypeOptions(sectionId, value);
			if (value !== 'public_probe')
				viewRef.clearRuleProbeInterfaceForSource(sectionId);
			return result;
		};

		o = s.option(form.ListValue, 'family', _('Family'));
		o.value('', _('Auto'));
		o.value('ipv4', _('IPv4'));
		o.value('ipv6', _('IPv6'));
		o.depends('type', 'local_addr');
		o.depends('type', 'interface');
		o.depends('type', 'public_probe');
		o.depends('type', 'script');
		this.sourceDhcpv6Options.family = o;
		this.guardSourceOptionWrite(o, 'family');
		o = s.option(form.Value, 'address', _('Address')); o.modalonly = true; o.depends('type', 'local_addr'); this.sourceDhcpv6Options.address = o; this.guardSourceOptionWrite(o, 'address');
		o = s.option(form.DummyValue, '_source_ip', _('Source IP'));
		o.rawhtml = true;
		o.modalonly = true;
		o.cfgvalue = function(sectionId) {
			if (arguments.length > 1)
				return null;

			return viewRef.renderSourceIpStatus(sectionId, viewRef.getDhcpv6OptionSet(this.section));
		};
		o = s.option(form.DummyValue, '_dhcpv6_status', _('Status'));
		o.rawhtml = true;
		o.modalonly = true;
		o.depends('type', 'dhcpv6_duid');
		o.depends('type', 'dhcpv6_mac');
		o.cfgvalue = function(sectionId) {
			if (arguments.length > 1)
				return null;

			return viewRef.renderDhcpv6LeaseStatus(sectionId, viewRef.getDhcpv6OptionSet(this.section));
		};
		o = s.option(form.Value, 'duid', _('DUID')); this.sourceDhcpv6Options.duid = o; o.modalonly = true; o.depends('type', 'dhcpv6_duid'); this.guardSourceOptionWrite(o, 'duid');
		o = s.option(form.Value, 'iaid', _('IAID')); this.sourceDhcpv6Options.iaid = o; o.modalonly = true; o.depends('type', 'dhcpv6_duid'); this.guardSourceOptionWrite(o, 'iaid');
		o = s.option(form.Value, 'mac', _('MAC')); this.sourceDhcpv6Options.mac = o; o.modalonly = true; o.depends('type', 'dhcpv6_mac'); this.guardSourceOptionWrite(o, 'mac');
		o = s.option(form.Value, 'lease_file', _('Lease file')); this.sourceDhcpv6Options.leaseFile = o; o.placeholder = '/tmp/odhcpd.leases'; o.modalonly = true; o.depends('type', 'dhcpv6_duid'); o.depends('type', 'dhcpv6_mac'); this.guardSourceOptionWrite(o, 'lease_file');
		o = s.option(form.Value, 'prefix_filter', _('Prefix narrowing'), _('Advanced narrowing after WAN/PD source prefix matching; it cannot replace the interface.')); this.sourceDhcpv6Options.prefixFilter = o; o.placeholder = '240e:'; o.modalonly = true; o.depends('type', 'dhcpv6_duid'); o.depends('type', 'dhcpv6_mac'); this.guardSourceOptionWrite(o, 'prefix_filter');
		o = s.option(form.Value, 'hostname_hint', _('Hostname hint')); this.sourceDhcpv6Options.hostnameHint = o; o.modalonly = true; o.depends('type', 'dhcpv6_duid'); o.depends('type', 'dhcpv6_mac'); this.guardSourceOptionWrite(o, 'hostname_hint');
		o = s.option(widgets.DeviceSelect, 'interface', _('WAN/upstream interface'), _('For DHCPv6 DUID/MAC sources, choose WAN/upstream interface(s); DHCPv6-PD route source prefixes from those interfaces validate LAN host IPv6 addresses.'));
		this.sourceDhcpv6Options.interface = o;
		o.multiple = true;
		o.modalonly = true;
		o.cfgvalue = function(sectionId, value) {
			const stored = arguments.length > 1 ? value : (this.data?.[sectionId] || uci.get('qddns', sectionId, 'interface'));
			const normalized = viewRef.interfaceValues(stored);

			if (arguments.length > 1) {
				this.data = this.data || {};
				this.data[sectionId] = normalized;
			}

			return normalized;
		};
		const interfaceWrite = o.write;
		o.write = function(sectionId, value) {
			return interfaceWrite.call(this, sectionId, viewRef.interfaceValues(value));
		};
		o.noaliases = true;
		o.nocreate = true;
		o.depends('type', 'interface');
		o.depends('type', 'dhcpv6_duid');
		o.depends('type', 'dhcpv6_mac');
		this.guardSourceOptionWrite(o, 'interface');
		o = s.option(form.Value, 'probe_url', _('Probe URL')); this.sourceDhcpv6Options.probeUrl = o; o.modalonly = true; o.depends('type', 'public_probe'); this.guardSourceOptionWrite(o, 'probe_url');
		o = s.option(widgets.DeviceSelect, 'probe_interface', _('Public probe outbound interface'), _('Choose the WAN/upstream interface used by this source IP preview and by the single rule referencing this source; empty uses the system default route.'));
		this.sourceDhcpv6Options.probeInterface = o;
		o.modalonly = true;
		o.multiple = false;
		o.noaliases = true;
		o.nocreate = true;
		o.depends('type', 'public_probe');
		o.cfgvalue = function(sectionId, value) {
			if (arguments.length > 1)
				return viewRef.singleInterfaceValue(value);

			return viewRef.sourceRuleProbeInterface(sectionId);
		};
		o.write = function(sectionId, value) {
			const sourceType = uci.get('qddns', sectionId, 'type') || viewRef.getSourceOptionValue(viewRef.sourceDhcpv6Options?.type, sectionId);
			viewRef.writeRuleProbeInterfaceForSource(sectionId, sourceType, value);
			uci.unset('qddns', sectionId, 'probe_interface');
		};
		o = s.option(form.Value, 'script', _('Script path')); o.modalonly = true; o.depends('type', 'script'); this.guardSourceOptionWrite(o, 'script');

		s = m.section(form.GridSection, 'provider', _('Provider Library'), _('Saved providers become selectable on the rules page after saving and reloading. Names stay editable.'));
		s.addremove = true;
		s.anonymous = false;
		this.useNameCreateFlow(s, {
			placeholder: _('New provider name'),
			description: _('Enter the provider name shown in tables and rule selectors.'),
			emptyMessage: _('Provider name must not be empty.'),
			unnamed: _('Unnamed provider')
		});

		o = s.option(form.Value, 'name', _('Name'), _('Name shown in tables and rule selectors.'));
		o.placeholder = _('Unnamed provider');
		o.modalonly = true;

		o = s.option(form.ListValue, 'type', _('Type'));
		o.value('cloudflare', _('Cloudflare'));
		o.value('dnspod', _('DNSPod'));
		o.value('aliyun', _('Aliyun'));
		o.value('custom_http', _('Custom HTTP'));
		o = s.option(form.Value, 'api_token', _('API token')); o.password = true; o.modalonly = true; o.depends('type', 'cloudflare');
		o = s.option(form.Value, 'secret_id', _('Secret ID')); o.modalonly = true; o.depends('type', 'dnspod');
		o = s.option(form.Value, 'secret_key', _('Secret Key')); o.password = true; o.modalonly = true; o.depends('type', 'dnspod');
		o = s.option(form.Value, 'access_key_id', _('Access Key ID')); o.modalonly = true; o.depends('type', 'aliyun');
		o = s.option(form.Value, 'access_key_secret', _('Access Key Secret')); o.password = true; o.modalonly = true; o.depends('type', 'aliyun');
		o = s.option(form.Value, 'url', _('Custom URL')); o.modalonly = true; o.depends('type', 'custom_http');
		o = s.option(form.Value, 'method', _('HTTP method')); o.placeholder = 'POST'; o.modalonly = true; o.depends('type', 'custom_http');
		o = s.option(form.Value, 'headers_json', _('Headers JSON')); o.modalonly = true; o.depends('type', 'custom_http');
		o = s.option(form.Value, 'body_template', _('Body template')); o.modalonly = true; o.depends('type', 'custom_http');
		o = s.option(form.Value, 'lookup_url', _('Lookup URL')); o.modalonly = true; o.depends('type', 'custom_http');
		o = s.option(form.Value, 'lookup_method', _('Lookup method')); o.modalonly = true; o.depends('type', 'custom_http');
		o = s.option(form.Value, 'lookup_headers_json', _('Lookup headers JSON')); o.modalonly = true; o.depends('type', 'custom_http');
		o = s.option(form.Value, 'lookup_json_pointer', _('Lookup JSON pointer')); o.modalonly = true; o.depends('type', 'custom_http');
		o = s.option(form.Value, 'success_contains', _('Success contains')); o.modalonly = true; o.depends('type', 'custom_http');

		return m.render();
	},

	render: function(data) {
		return this.renderConfigForms(data).then(L.bind(function(formEl) {
			return E('div', { class: 'qddns-settings-page' }, [
				qddns.renderPageHeader({
					title: _('Settings'),
					description: _('Manage daemon defaults, source definitions, and provider credentials here.')
				}),
				formEl,
				this.renderProviderTemplatePanel(),
				this.renderSourceProbePanel(data.sources)
			]);
		}, this));
	}
});
