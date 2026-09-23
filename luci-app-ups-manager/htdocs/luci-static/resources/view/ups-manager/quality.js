'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require uci';

var callGetStatus = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_status',
	expect: { '': {} }
});

var callGetRawData = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_raw_data',
	expect: { '': {} }
});

var callGetQualityEvents = rpc.declare({
	object: 'luci.ups-manager',
	method: 'get_quality_events',
	expect: { '': {} }
});

var callClearQualityEvents = rpc.declare({
	object: 'luci.ups-manager',
	method: 'clear_quality_events',
	expect: { '': {} }
});

var DEFAULT_RULES = {
	hide_unsupported: '0',
	status_overload_sev: 'critical',
	status_bypass_sev: 'warning',
	status_replace_batt_sev: 'warning',
	status_selftest_fail_sev: 'warning',
	in_volt_low_trig: '190',
	in_volt_low_rec: '200',
	in_volt_low_sev: 'warning',
	in_volt_high_trig: '250',
	in_volt_high_rec: '245',
	in_volt_high_sev: 'warning',
	out_volt_low_trig: '190',
	out_volt_low_rec: '200',
	out_volt_low_sev: 'warning',
	out_volt_high_trig: '250',
	out_volt_high_rec: '245',
	out_volt_high_sev: 'warning',
	in_freq_low_trig: '47',
	in_freq_low_rec: '48',
	in_freq_low_sev: 'warning',
	in_freq_high_trig: '53',
	in_freq_high_rec: '52',
	in_freq_high_sev: 'warning',
	temp_high_trig: '50',
	temp_high_rec: '45',
	temp_high_sev: 'warning',
	load_high_trig: '80',
	load_high_rec: '75',
	load_high_sev: 'warning',
	load_crit_trig: '95',
	load_crit_rec: '90',
	load_crit_sev: 'critical'
};

return view.extend({
	activeFilter: 'all',
	rulesData: {},
	statusData: {},
	eventsList: [],

	load: function() {
		return Promise.all([
			callGetStatus().catch(function() { return {}; }),
			callGetQualityEvents().catch(function() { return { events: [] }; }),
			uci.load('ups_manager').catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var self = this;
		this.statusData = data[0] || {};
		var eventData = data[1] || {};
		this.eventsList = eventData.events || [];

		// Read UCI config
		this.rulesData = {};
		for (var k in DEFAULT_RULES) {
			var val = uci.get('ups_manager', 'quality', k);
			this.rulesData[k] = (val !== null && val !== undefined && val !== '') ? String(val) : DEFAULT_RULES[k];
		}

		var container = E('div', { 'class': 'cbi-map ups-quality-container' });

		var styleNode = E('style', {}, [
			'.ups-quality-container { max-width: 1280px; margin: 0 auto; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", "Helvetica Neue", Arial, sans-serif; color: #1e293b; }',
			'.dark-mode .ups-quality-container { color: #f8fafc; }',
			'.pq-card { background: var(--cbi-section-background, #ffffff); border: 1px solid var(--cbi-section-border, #e2e8f0); border-radius: 12px; padding: 1.25rem 1.5rem; margin-bottom: 1.25rem; box-shadow: 0 1px 3px rgba(0,0,0,0.02); }',
			'.dark-mode .pq-card { background: #1e293b; border-color: #334155; }',
			'.pq-header-top { display: flex; justify-content: space-between; align-items: flex-start; flex-wrap: wrap; gap: 1rem; }',
			'.pq-subtag-row { display: flex; align-items: center; gap: 0.6rem; margin-bottom: 0.4rem; }',
			'.pq-subtag-title { font-size: 0.75rem; font-weight: 700; color: #3b82f6; letter-spacing: 0.05em; text-transform: uppercase; }',
			'.pq-main-title { font-size: 1.6rem; font-weight: 800; margin: 0; line-height: 1.2; color: #0f172a; }',
			'.dark-mode .pq-main-title { color: #f8fafc; }',
			'.pq-main-desc { font-size: 0.85rem; color: #64748b; margin: 0.45rem 0 0 0; }',
			'.dark-mode .pq-main-desc { color: #94a3b8; }',
			'.pq-summary-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; margin-top: 1.25rem; }',
			'@media (max-width: 900px) { .pq-summary-grid { grid-template-columns: repeat(2, 1fr); } }',
			'@media (max-width: 500px) { .pq-summary-grid { grid-template-columns: 1fr; } }',
			'.pq-summary-tile { background: #f8fafc; border: 1px solid #edf2f7; border-radius: 10px; padding: 1rem 1.25rem; }',
			'.dark-mode .pq-summary-tile { background: #0f172a; border-color: #334155; }',
			'.pq-summary-k { font-size: 0.8rem; font-weight: 600; color: #64748b; margin-bottom: 0.4rem; }',
			'.dark-mode .pq-summary-k { color: #94a3b8; }',
			'.pq-summary-v { font-size: 1.55rem; font-weight: 800; line-height: 1.1; font-variant-numeric: tabular-nums; }',
			'.pq-section-heading { font-size: 1.05rem; font-weight: 700; display: flex; align-items: center; gap: 0.45rem; margin: 0; }',
			'.pq-section-desc { font-size: 0.82rem; color: #64748b; margin: 0.35rem 0 1.1rem 0; }',
			'.dark-mode .pq-section-desc { color: #94a3b8; }',
			'.pq-metrics-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; }',
			'@media (max-width: 900px) { .pq-metrics-grid { grid-template-columns: repeat(2, 1fr); } }',
			'@media (max-width: 600px) { .pq-metrics-grid { grid-template-columns: 1fr; } }',
			'.pq-metric-item { background: var(--cbi-section-background, #ffffff); border: 1px solid #e2e8f0; border-radius: 10px; padding: 1rem 1.25rem; display: flex; flex-direction: column; justify-content: space-between; min-height: 125px; }',
			'.dark-mode .pq-metric-item { background: #1e293b; border-color: #334155; }',
			'.pq-metric-header { display: flex; justify-content: space-between; align-items: center; }',
			'.pq-metric-label { font-size: 0.92rem; font-weight: 700; color: #1e293b; }',
			'.dark-mode .pq-metric-label { color: #f8fafc; }',
			'.pq-metric-val { font-size: 1.85rem; font-weight: 800; margin: 0.6rem 0; font-variant-numeric: tabular-nums; }',
			'.pq-metric-footer { display: flex; justify-content: space-between; align-items: center; font-size: 0.75rem; color: #94a3b8; }',
			'.pq-metric-mono { font-family: monospace; color: #94a3b8; font-size: 0.72rem; }',
			'.badge-pill { display: inline-flex; align-items: center; gap: 0.3rem; padding: 2px 8px; border-radius: 9999px; font-size: 0.75rem; font-weight: 600; }',
			'.badge-pill-green { background: #d1fae5; color: #059669; }',
			'.badge-pill-red { background: #fee2e2; color: #dc2626; }',
			'.badge-pill-gray { background: #f1f5f9; color: #64748b; }',
			'.text-unsupported { font-size: 0.78rem; color: #94a3b8; font-weight: 500; }',
			'.pq-rules-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; }',
			'@media (max-width: 1100px) { .pq-rules-grid { grid-template-columns: repeat(2, 1fr); } }',
			'@media (max-width: 600px) { .pq-rules-grid { grid-template-columns: 1fr; } }',
			'.pq-rule-card { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 10px; padding: 1rem 1.15rem; display: flex; flex-direction: column; justify-content: space-between; }',
			'.dark-mode .pq-rule-card { background: #1e293b; border-color: #334155; }',
			'.pq-rule-card.unsupported-hidden { display: none !important; }',
			'.pq-rule-title-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem; }',
			'.pq-rule-title { font-size: 0.92rem; font-weight: 700; color: #1e293b; }',
			'.dark-mode .pq-rule-title { color: #f8fafc; }',
			'.pq-rule-fields { display: flex; flex-direction: column; gap: 0.6rem; }',
			'.pq-rule-inputs-row { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }',
			'.pq-input-group label { display: block; font-size: 0.72rem; color: #64748b; margin-bottom: 0.25rem; }',
			'.dark-mode .pq-input-group label { color: #94a3b8; }',
			'.pq-input-group input, .pq-input-group select { width: 100%; border: 1px solid #cbd5e1; border-radius: 6px; padding: 0.35rem 0.5rem; font-size: 0.85rem; background: #ffffff; color: inherit; box-sizing: border-box; }',
			'.dark-mode .pq-input-group input, .dark-mode .pq-input-group select { background: #0f172a; border-color: #475569; }',
			'.pq-rule-unsupported-note { font-size: 0.72rem; color: #94a3b8; margin-top: 0.6rem; display: flex; align-items: center; gap: 0.35rem; }',
			'.pq-event-item { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 10px; padding: 0.9rem 1.25rem; margin-bottom: 0.75rem; display: flex; align-items: center; justify-content: space-between; gap: 1rem; }',
			'.dark-mode .pq-event-item { background: #1e293b; border-color: #334155; }',
			'.pq-event-left { display: flex; align-items: center; gap: 1rem; }',
			'.pq-circle-icon { width: 34px; height: 34px; border-radius: 50%; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }',
			'.pq-circle-icon.recovered { background: #d1fae5; }',
			'.pq-circle-icon.recovered .pq-dot { width: 14px; height: 14px; border-radius: 50%; background: #10b981; }',
			'.pq-circle-icon.ongoing { background: #fee2e2; }',
			'.pq-circle-icon.ongoing .pq-dot { width: 14px; height: 14px; border-radius: 50%; background: #ef4444; }',
			'.pq-event-main-line { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; margin-bottom: 0.25rem; }',
			'.pq-event-name { font-size: 0.95rem; font-weight: 700; color: #0f172a; }',
			'.dark-mode .pq-event-name { color: #f8fafc; }',
			'.pq-event-val { font-size: 0.92rem; font-weight: 700; font-family: monospace; color: #1e293b; }',
			'.dark-mode .pq-event-val { color: #f8fafc; }',
			'.pq-event-subline { font-size: 0.78rem; color: #94a3b8; }',
			'.pq-tab-btn { border: none; background: transparent; padding: 5px 14px; font-size: 0.82rem; font-weight: 500; color: #64748b; border-radius: 6px; cursor: pointer; transition: all 0.2s; }',
			'.pq-tab-btn.active { background: #ffffff; color: #0f172a; font-weight: 700; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }',
			'.dark-mode .pq-tab-btn.active { background: #334155; color: #ffffff; }'
		]);

		container.appendChild(styleNode);

		// Render Top Header Card
		container.appendChild(this.renderHeaderCard());

		// Render Current Metrics Card
		container.appendChild(this.renderCurrentMetricsCard());

		// Render Alarm Rules Card
		container.appendChild(this.renderRulesCard());

		// Render Events Card
		container.appendChild(this.renderEventsCard());

		return container;
	},

	renderHeaderCard: function() {
		var self = this;
		var status = this.statusData;
		var isConnected = status && status.connected;

		// Calculate ongoing anomaly count
		var ongoingCount = 0;
		if (!isConnected || !status.is_online) ongoingCount++;
		if (status.load_percent && status.load_percent > 80) ongoingCount++;
		if (status.input_voltage && (status.input_voltage < 190 || status.input_voltage > 250)) ongoingCount++;

		var isAllNormal = ongoingCount === 0;
		var topBadge = isAllNormal ?
			E('span', { 'class': 'badge-pill badge-pill-green' }, ['🟢 ', _('整体正常')]) :
			E('span', { 'class': 'badge-pill badge-pill-red' }, ['🔴 ', _('存在异常')]);

		var refreshBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'style': 'display:inline-flex;align-items:center;gap:0.4rem;padding:0.4rem 0.9rem;border-radius:8px;',
			'click': function(ev) {
				var btn = ev.target;
				btn.disabled = true;
				self.refreshAll().then(function() {
					btn.disabled = false;
				});
			}
		}, ['🔄 ', _('刷新数据')]);

		var card = E('div', { 'class': 'pq-card', 'id': 'pq-top-header-card' }, [
			E('div', { 'class': 'pq-header-top' }, [
				E('div', {}, [
					E('div', { 'class': 'pq-subtag-row' }, [
						E('span', { 'class': 'pq-subtag-title' }, 'POWER QUALITY MONITORING'),
						topBadge
					]),
					E('h2', { 'class': 'pq-main-title' }, _('电能质量')),
					E('p', { 'class': 'pq-main-desc' }, _('监控电压、频率、温度、负载与 UPS 告警状态。'))
				]),
				E('div', {}, [refreshBtn])
			]),
			E('div', { 'class': 'pq-summary-grid', 'id': 'pq-summary-grid' }, [
				E('div', { 'class': 'pq-summary-tile' }, [
					E('div', { 'class': 'pq-summary-k' }, _('整体状态')),
					E('div', { 'class': 'pq-summary-v', 'style': 'color:' + (isAllNormal ? '#059669' : '#dc2626') }, isAllNormal ? _('整体正常') : _('存在异常'))
				]),
				E('div', { 'class': 'pq-summary-tile' }, [
					E('div', { 'class': 'pq-summary-k' }, _('进行中异常')),
					E('div', { 'class': 'pq-summary-v', 'style': 'color:#dc2626;' }, String(ongoingCount))
				]),
				E('div', { 'class': 'pq-summary-tile' }, [
					E('div', { 'class': 'pq-summary-k' }, _('今日异常')),
					E('div', { 'class': 'pq-summary-v', 'style': 'color:#2563eb;' }, '0')
				]),
				E('div', { 'class': 'pq-summary-tile' }, [
					E('div', { 'class': 'pq-summary-k' }, _('最近异常')),
					E('div', { 'class': 'pq-summary-v', 'style': 'font-size:1.25rem;color:#1e293b;' }, _('输入频率波动'))
				])
			])
		]);

		return card;
	},

	renderCurrentMetricsCard: function() {
		var status = this.statusData;
		var isConnected = status && status.connected;

		// 1. Input Voltage
		var inV = (isConnected && status.input_voltage !== null && status.input_voltage !== undefined) ? Number(status.input_voltage).toFixed(1) : '0.0';
		var inVAbnormal = !isConnected || inV < 190 || inV > 250;
		var inVBadge = inVAbnormal ? E('span', { 'class': 'badge-pill badge-pill-red' }, _('异常')) : E('span', { 'class': 'badge-pill badge-pill-green' }, _('正常'));

		// 2. Output Voltage
		var outV = (isConnected && status.output_voltage !== null && status.output_voltage !== undefined) ? Number(status.output_voltage).toFixed(1) : '0.0';
		var outVAbnormal = !isConnected || outV < 190 || outV > 250;
		var outVBadge = outVAbnormal ? E('span', { 'class': 'badge-pill badge-pill-red' }, _('异常')) : E('span', { 'class': 'badge-pill badge-pill-green' }, _('正常'));

		// 3. Input Frequency
		var inF = (isConnected && status.input_freq !== null && status.input_freq !== undefined) ? Number(status.input_freq).toFixed(1) : '0.0';
		var inFAbnormal = !isConnected || inF < 47 || inF > 53;
		var inFBadge = inFAbnormal ? E('span', { 'class': 'badge-pill badge-pill-red' }, _('异常')) : E('span', { 'class': 'badge-pill badge-pill-green' }, _('正常'));

		// 4. UPS Load
		var load = (isConnected && status.load_percent !== null && status.load_percent !== undefined) ? Math.round(status.load_percent) : 0;
		var loadAbnormal = load >= 80;
		var loadBadge = loadAbnormal ? E('span', { 'class': 'badge-pill badge-pill-red' }, _('异常')) : E('span', { 'class': 'badge-pill badge-pill-green' }, _('正常'));

		// 5. Temperature (Check if hardware supports it)
		var hasTemp = isConnected && status.temperature !== null && status.temperature !== undefined && status.temperature !== '' && !isNaN(status.temperature);
		var tempVal = hasTemp ? (Number(status.temperature).toFixed(1) + ' °C') : _('未知');
		var tempBadge = hasTemp ?
			(status.temperature > 50 ? E('span', { 'class': 'badge-pill badge-pill-red' }, _('异常')) : E('span', { 'class': 'badge-pill badge-pill-green' }, _('正常'))) :
			E('span', { 'class': 'text-unsupported' }, _('不支持'));

		// 6. UPS Status
		var statusText = isConnected ? (status.status || 'OL') : 'OFFLINE';
		var statusIsOnline = isConnected && status.is_online;
		var statusBadge = statusIsOnline ? E('span', { 'class': 'badge-pill badge-pill-green' }, _('正常')) : E('span', { 'class': 'badge-pill badge-pill-red' }, _('异常'));

		return E('div', { 'class': 'pq-card' }, [
			E('h3', { 'class': 'pq-section-heading' }, ['📊 ', _('当前指标')]),
			E('p', { 'class': 'pq-section-desc' }, _('来自 UPS 当前可读取的电能质量数据。')),
			E('div', { 'class': 'pq-metrics-grid', 'id': 'pq-metrics-grid' }, [
				// Card 1
				E('div', { 'class': 'pq-metric-item' }, [
					E('div', { 'class': 'pq-metric-header' }, [
						E('span', { 'class': 'pq-metric-label' }, _('输入电压')),
						inVBadge
					]),
					E('div', { 'class': 'pq-metric-val', 'style': 'color:' + (inVAbnormal ? '#dc2626' : '#059669') }, inV + ' V'),
					E('div', { 'class': 'pq-metric-footer' }, [
						E('span', {}, _('正常范围: 190 ~ 250 V')),
						E('span', { 'class': 'pq-metric-mono' }, 'input.voltage')
					])
				]),

				// Card 2
				E('div', { 'class': 'pq-metric-item' }, [
					E('div', { 'class': 'pq-metric-header' }, [
						E('span', { 'class': 'pq-metric-label' }, _('输出电压')),
						outVBadge
					]),
					E('div', { 'class': 'pq-metric-val', 'style': 'color:' + (outVAbnormal ? '#dc2626' : '#059669') }, outV + ' V'),
					E('div', { 'class': 'pq-metric-footer' }, [
						E('span', {}, _('正常范围: 190 ~ 250 V')),
						E('span', { 'class': 'pq-metric-mono' }, 'output.voltage')
					])
				]),

				// Card 3
				E('div', { 'class': 'pq-metric-item' }, [
					E('div', { 'class': 'pq-metric-header' }, [
						E('span', { 'class': 'pq-metric-label' }, _('输入频率')),
						inFBadge
					]),
					E('div', { 'class': 'pq-metric-val', 'style': 'color:' + (inFAbnormal ? '#dc2626' : '#059669') }, inF + ' Hz'),
					E('div', { 'class': 'pq-metric-footer' }, [
						E('span', {}, _('正常范围: 47 ~ 53 Hz')),
						E('span', { 'class': 'pq-metric-mono' }, 'input.frequency')
					])
				]),

				// Card 4
				E('div', { 'class': 'pq-metric-item' }, [
					E('div', { 'class': 'pq-metric-header' }, [
						E('span', { 'class': 'pq-metric-label' }, _('UPS 负载率')),
						loadBadge
					]),
					E('div', { 'class': 'pq-metric-val', 'style': 'color:#2563eb;' }, load + ' %'),
					E('div', { 'class': 'pq-metric-footer' }, [
						E('span', {}, _('正常范围: < 80 %')),
						E('span', { 'class': 'pq-metric-mono' }, 'ups.load')
					])
				]),

				// Card 5
				E('div', { 'class': 'pq-metric-item' }, [
					E('div', { 'class': 'pq-metric-header' }, [
						E('span', { 'class': 'pq-metric-label' }, _('UPS 温度')),
						tempBadge
					]),
					E('div', { 'class': 'pq-metric-val', 'style': 'color:' + (hasTemp ? '#1e293b' : '#64748b') }, tempVal),
					E('div', { 'class': 'pq-metric-footer' }, [
						E('span', {}, _('正常范围: < 50 °C')),
						E('span', { 'class': 'pq-metric-mono' }, 'battery.temperature')
					])
				]),

				// Card 6
				E('div', { 'class': 'pq-metric-item' }, [
					E('div', { 'class': 'pq-metric-header' }, [
						E('span', { 'class': 'pq-metric-label' }, _('UPS 告警状态')),
						statusBadge
					]),
					E('div', { 'class': 'pq-metric-val', 'style': 'color:' + (statusIsOnline ? '#059669' : '#2563eb') }, statusText),
					E('div', { 'class': 'pq-metric-footer' }, [
						E('span', {}, _('正常范围: OL (市电在线)')),
						E('span', { 'class': 'pq-metric-mono' }, 'ups.status')
					])
				])
			])
		]);
	},

	renderRulesCard: function() {
		var self = this;
		var r = this.rulesData;
		var isHideUnsupported = r.hide_unsupported === '1';

		var hideCheckbox = E('input', {
			'type': 'checkbox',
			'id': 'pq-hide-unsupported-check',
			'style': 'cursor:pointer;',
			'change': function(ev) {
				var checked = ev.target.checked;
				self.rulesData.hide_unsupported = checked ? '1' : '0';
				var items = document.querySelectorAll('.pq-rule-card.is-unsupported');
				for (var i = 0; i < items.length; i++) {
					if (checked) {
						items[i].classList.add('unsupported-hidden');
					} else {
						items[i].classList.remove('unsupported-hidden');
					}
				}
			}
		});
		if (isHideUnsupported) hideCheckbox.checked = true;

		var restoreBtn = E('button', {
			'class': 'btn cbi-button cbi-button-neutral',
			'style': 'border-radius:6px;padding:0.35rem 0.75rem;font-size:0.82rem;',
			'click': function() {
				if (!confirm(_('确定恢复所有电能质量规则为出厂默认值吗？'))) return;
				for (var k in DEFAULT_RULES) {
					var el = document.getElementById('rule-input-' + k);
					if (el) el.value = DEFAULT_RULES[k];
					self.rulesData[k] = DEFAULT_RULES[k];
				}
				hideCheckbox.checked = false;
				var items = document.querySelectorAll('.pq-rule-card.is-unsupported');
				for (var i = 0; i < items.length; i++) items[i].classList.remove('unsupported-hidden');
				ui.addNotification(null, E('p', {}, _('已恢复默认数值，请点击“保存规则”使其持久生效。')), 'info');
			}
		}, ['🔄 ', _('恢复默认')]);

		var saveBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'style': 'border-radius:6px;padding:0.35rem 0.85rem;font-size:0.82rem;',
			'click': function(ev) {
				var btn = ev.target;
				btn.disabled = true;

				// Harvest form values
				for (var k in DEFAULT_RULES) {
					var el = document.getElementById('rule-input-' + k);
					if (el) {
						self.rulesData[k] = el.value;
						uci.set('ups_manager', 'quality', k, el.value);
					}
				}
				uci.set('ups_manager', 'quality', 'hide_unsupported', hideCheckbox.checked ? '1' : '0');

				return uci.save().then(function() {
					return uci.apply();
				}).then(function() {
					btn.disabled = false;
					ui.addNotification(null, E('p', {}, _('电能质量告警与防护规则已成功保存并生效。')), 'info');
				}).catch(function(err) {
					btn.disabled = false;
					ui.addNotification(null, E('p', {}, _('保存失败: ') + (err.message || err)), 'error');
				});
			}
		}, ['💾 ', _('保存规则')]);

		return E('div', { 'class': 'pq-card' }, [
			E('div', { 'style': 'display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:1rem;margin-bottom:1rem;' }, [
				E('div', {}, [
					E('h3', { 'class': 'pq-section-heading' }, ['🔔 ', _('告警规则')]),
					E('p', { 'class': 'pq-section-desc', 'style': 'margin-bottom:0;' }, _('配置电能质量异常告警与通知策略'))
				]),
				E('div', { 'style': 'display:flex;align-items:center;gap:0.75rem;' }, [
					E('label', { 'style': 'display:flex;align-items:center;gap:0.35rem;font-size:0.82rem;color:#64748b;cursor:pointer;' }, [
						hideCheckbox,
						_('隐藏不支持项')
					]),
					restoreBtn,
					saveBtn
				])
			]),

			// Subsection 1: Status Rules
			E('div', { 'style': 'font-size:0.88rem;font-weight:700;color:#334155;margin:1.25rem 0 0.75rem 0;' }, _('状态类告警 (基于状态变化的告警规则)')),
			E('div', { 'class': 'pq-rules-grid' }, [
				// Rule 1: UPS 过载
				this.renderStatusRuleCard('status_overload_sev', _('UPS 过载'), true, r.status_overload_sev),
				// Rule 2: UPS 进入旁路模式
				this.renderStatusRuleCard('status_bypass_sev', _('UPS 进入旁路模式'), true, r.status_bypass_sev),
				// Rule 3: 电池需要更换 (不支持)
				this.renderStatusRuleCard('status_replace_batt_sev', _('电池需要更换'), false, r.status_replace_batt_sev),
				// Rule 4: UPS 自检失败 (不支持)
				this.renderStatusRuleCard('status_selftest_fail_sev', _('UPS 自检失败'), false, r.status_selftest_fail_sev)
			]),

			// Subsection 2: Numeric Rules
			E('div', { 'style': 'font-size:0.88rem;font-weight:700;color:#334155;margin:1.5rem 0 0.75rem 0;' }, _('数值类告警 (基于数值阈值的告警规则)')),
			E('div', { 'class': 'pq-rules-grid' }, [
				// 1. 输入电压过低
				this.renderNumericRuleCard('in_volt_low', _('输入电压过低'), 'V', true, r.in_volt_low_trig, r.in_volt_low_rec, r.in_volt_low_sev),
				// 2. 输入电压过高
				this.renderNumericRuleCard('in_volt_high', _('输入电压过高'), 'V', true, r.in_volt_high_trig, r.in_volt_high_rec, r.in_volt_high_sev),
				// 3. 输出电压过低
				this.renderNumericRuleCard('out_volt_low', _('输出电压过低'), 'V', true, r.out_volt_low_trig, r.out_volt_low_rec, r.out_volt_low_sev),
				// 4. 输出电压过高
				this.renderNumericRuleCard('out_volt_high', _('输出电压过高'), 'V', true, r.out_volt_high_trig, r.out_volt_high_rec, r.out_volt_high_sev),
				// 5. 输入频率过低
				this.renderNumericRuleCard('in_freq_low', _('输入频率过低'), 'Hz', true, r.in_freq_low_trig, r.in_freq_low_rec, r.in_freq_low_sev),
				// 6. 输入频率过高
				this.renderNumericRuleCard('in_freq_high', _('输入频率过高'), 'Hz', true, r.in_freq_high_trig, r.in_freq_high_rec, r.in_freq_high_sev),
				// 7. UPS 温度过高 (不支持)
				this.renderNumericRuleCard('temp_high', _('UPS 温度过高'), '°C', false, r.temp_high_trig, r.temp_high_rec, r.temp_high_sev),
				// 8. UPS 负载较高
				this.renderNumericRuleCard('load_high', _('UPS 负载较高'), '%', true, r.load_high_trig, r.load_high_rec, r.load_high_sev),
				// 9. UPS 严重过载
				this.renderNumericRuleCard('load_crit', _('UPS 严重过载'), '%', true, r.load_crit_trig, r.load_crit_rec, r.load_crit_sev)
			])
		]);
	},

	renderStatusRuleCard: function(key, title, supported, curSev) {
		var isHidden = !supported && this.rulesData.hide_unsupported === '1';
		var cardClass = 'pq-rule-card' + (!supported ? ' is-unsupported' : '') + (isHidden ? ' unsupported-hidden' : '');

		var badge = supported ?
			E('span', { 'class': 'badge-pill badge-pill-green' }, _('支持')) :
			E('span', { 'class': 'text-unsupported' }, _('不支持'));

		var sevSelect = E('select', {
			'id': 'rule-input-' + key,
			'class': 'cbi-input-select'
		}, [
			E('option', { 'value': 'warning', 'selected': curSev === 'warning' }, _('警告')),
			E('option', { 'value': 'critical', 'selected': curSev === 'critical' }, _('严重'))
		]);

		var noteNode = !supported ?
			E('div', { 'class': 'pq-rule-unsupported-note' }, [
				E('span', { 'style': 'color:#3b82f6;font-size:0.85rem;' }, 'ℹ️'),
				_('当前 UPS 未提供对应数据字段')
			]) : null;

		return E('div', { 'class': cardClass }, [
			E('div', { 'class': 'pq-rule-title-row' }, [
				E('span', { 'class': 'pq-rule-title' }, title),
				badge
			]),
			E('div', { 'class': 'pq-rule-fields' }, [
				E('div', { 'class': 'pq-input-group' }, [
					E('label', {}, _('严重程度')),
					sevSelect
				])
			]),
			noteNode
		]);
	},

	renderNumericRuleCard: function(prefix, title, unit, supported, trigVal, recVal, sevVal) {
		var isHidden = !supported && this.rulesData.hide_unsupported === '1';
		var cardClass = 'pq-rule-card' + (!supported ? ' is-unsupported' : '') + (isHidden ? ' unsupported-hidden' : '');

		var badge = supported ?
			E('span', { 'class': 'badge-pill badge-pill-green' }, _('支持')) :
			E('span', { 'class': 'text-unsupported' }, _('不支持'));

		var trigInput = E('input', {
			'type': 'number',
			'id': 'rule-input-' + prefix + '_trig',
			'value': trigVal
		});

		var recInput = E('input', {
			'type': 'number',
			'id': 'rule-input-' + prefix + '_rec',
			'value': recVal
		});

		var sevSelect = E('select', {
			'id': 'rule-input-' + prefix + '_sev',
			'class': 'cbi-input-select'
		}, [
			E('option', { 'value': 'warning', 'selected': sevVal === 'warning' }, _('警告')),
			E('option', { 'value': 'critical', 'selected': sevVal === 'critical' }, _('严重'))
		]);

		var noteNode = !supported ?
			E('div', { 'class': 'pq-rule-unsupported-note' }, [
				E('span', { 'style': 'color:#3b82f6;font-size:0.85rem;' }, 'ℹ️'),
				_('当前 UPS 未提供对应数据字段')
			]) : null;

		return E('div', { 'class': cardClass }, [
			E('div', { 'class': 'pq-rule-title-row' }, [
				E('span', { 'class': 'pq-rule-title' }, title),
				badge
			]),
			E('div', { 'class': 'pq-rule-fields' }, [
				E('div', { 'class': 'pq-rule-inputs-row' }, [
					E('div', { 'class': 'pq-input-group' }, [
						E('label', {}, _('触发阈值 (') + unit + ')'),
						trigInput
					]),
					E('div', { 'class': 'pq-input-group' }, [
						E('label', {}, _('恢复阈值 (') + unit + ')'),
						recInput
					])
				]),
				E('div', { 'class': 'pq-input-group' }, [
					E('label', {}, _('严重程度')),
					sevSelect
				])
			]),
			noteNode
		]);
	},

	renderEventsCard: function() {
		var self = this;

		var tabAll = E('button', {
			'class': 'pq-tab-btn' + (this.activeFilter === 'all' ? ' active' : ''),
			'click': function() { self.switchTab('all'); }
		}, _('全部'));

		var tabOngoing = E('button', {
			'class': 'pq-tab-btn' + (this.activeFilter === 'ongoing' ? ' active' : ''),
			'click': function() { self.switchTab('ongoing'); }
		}, _('进行中'));

		var tabRecovered = E('button', {
			'class': 'pq-tab-btn' + (this.activeFilter === 'recovered' ? ' active' : ''),
			'click': function() { self.switchTab('recovered'); }
		}, _('已恢复'));

		var refreshEventsBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'style': 'border-radius:6px;padding:0.35rem 0.75rem;font-size:0.82rem;',
			'click': function() { self.refreshEvents(); }
		}, ['🔄 ', _('刷新')]);

		var clearBtn = E('button', {
			'class': 'btn cbi-button cbi-button-neutral',
			'style': 'border-radius:6px;padding:0.35rem 0.75rem;font-size:0.82rem;',
			'click': function() {
				if (!confirm(_('确定清理所有已恢复的历史事件吗？'))) return;
				callClearQualityEvents().then(function() {
					self.eventsList = [];
					self.updateEventsList();
					ui.addNotification(null, E('p', {}, _('已成功清理已恢复事件。')), 'info');
				});
			}
		}, ['🗑️ ', _('清理已恢复')]);

		var card = E('div', { 'class': 'pq-card', 'id': 'pq-events-card' }, [
			E('div', { 'style': 'display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:1rem;margin-bottom:1rem;' }, [
				E('div', {}, [
					E('h3', { 'class': 'pq-section-heading' }, ['⚠️ ', _('异常事件')]),
					E('p', { 'class': 'pq-section-desc', 'style': 'margin-bottom:0;' }, _('查看正在发生和已经恢复的电能质量异常。'))
				]),
				E('div', { 'style': 'display:flex;align-items:center;gap:0.6rem;flex-wrap:wrap;' }, [
					E('div', { 'style': 'display:flex;background:#f1f5f9;border-radius:8px;padding:3px;gap:2px;' }, [
						tabAll, tabOngoing, tabRecovered
					]),
					refreshEventsBtn,
					clearBtn
				])
			]),
			E('div', { 'id': 'pq-events-list-container' }, this.renderEventRows()),
			E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;font-size:0.82rem;color:#64748b;margin-top:1.25rem;border-top:1px solid #f1f5f9;padding-top:0.75rem;' }, [
				E('span', { 'id': 'pq-events-count-label' }, _('共 ') + this.eventsList.length + _(' 条 · 第 1/1 页')),
				E('div', { 'style': 'display:flex;align-items:center;gap:0.5rem;' }, [
					E('span', {}, _('每页 20 条')),
					E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'disabled': true, 'style': 'padding:2px 8px;font-size:0.8rem;' }, _('上一页')),
					E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'disabled': true, 'style': 'padding:2px 8px;font-size:0.8rem;' }, _('下一页'))
				])
			])
		]);

		return card;
	},

	renderEventRows: function() {
		var self = this;
		var filtered = this.eventsList.filter(function(item) {
			if (self.activeFilter === 'ongoing') return item.status === 'ongoing';
			if (self.activeFilter === 'recovered') return item.status === 'recovered';
			return true;
		});

		if (filtered.length === 0) {
			return [
				E('div', { 'style': 'text-align:center;padding:2.5rem 0;color:#94a3b8;font-size:0.9rem;' }, _('暂无相关电能质量异常记录'))
			];
		}

		var rows = [];
		filtered.forEach(function(item) {
			var isRecovered = item.status === 'recovered';
			var circleNode = E('div', { 'class': 'pq-circle-icon ' + (isRecovered ? 'recovered' : 'ongoing') }, [
				E('div', { 'class': 'pq-dot' })
			]);

			var sevBadge = item.severity === 'critical' ?
				E('span', { 'class': 'badge-pill badge-pill-red' }, _('严重')) :
				E('span', { 'class': 'badge-pill badge-pill-gray' }, _('警告'));

			var statusPill = isRecovered ?
				E('span', { 'class': 'badge-pill badge-pill-green' }, _('已恢复')) :
				E('span', { 'class': 'badge-pill badge-pill-red' }, _('进行中'));

			var detailBtn = E('button', {
				'class': 'btn cbi-button cbi-button-neutral',
				'style': 'padding:0.3rem 0.85rem;font-size:0.82rem;border-radius:6px;',
				'click': function() { self.showEventModal(item); }
			}, _('详情'));

			var row = E('div', { 'class': 'pq-event-item' }, [
				E('div', { 'class': 'pq-event-left' }, [
					circleNode,
					E('div', {}, [
						E('div', { 'class': 'pq-event-main-line' }, [
							E('span', { 'class': 'pq-event-name' }, item.title || _('电能指标波动')),
							sevBadge,
							E('span', { 'class': 'pq-event-val' }, item.value || '--'),
							statusPill
						]),
						E('div', { 'class': 'pq-event-subline' }, (item.time || '') + ' · ' + (item.id || ''))
					])
				]),
				E('div', {}, [detailBtn])
			]);

			rows.push(row);
		});

		return rows;
	},

	switchTab: function(tabName) {
		this.activeFilter = tabName;
		var card = document.getElementById('pq-events-card');
		if (card) {
			var btns = card.querySelectorAll('.pq-tab-btn');
			btns.forEach(function(b) { b.classList.remove('active'); });
			if (tabName === 'all' && btns[0]) btns[0].classList.add('active');
			if (tabName === 'ongoing' && btns[1]) btns[1].classList.add('active');
			if (tabName === 'recovered' && btns[2]) btns[2].classList.add('active');
		}
		this.updateEventsList();
	},

	updateEventsList: function() {
		var container = document.getElementById('pq-events-list-container');
		if (container) {
			dom.content(container, this.renderEventRows());
		}
		var countLabel = document.getElementById('pq-events-count-label');
		if (countLabel) {
			countLabel.innerText = _('共 ') + this.eventsList.length + _(' 条 · 第 1/1 页');
		}
	},

	showEventModal: function(item) {
		ui.showModal(_('电能质量异常事件详情'), [
			E('table', { 'class': 'table', 'style': 'margin-top:0.5rem;' }, [
				E('tr', {}, [
					E('td', { 'style': 'font-weight:600;width:35%;' }, _('事件名称 / ID')),
					E('td', {}, (item.title || '') + ' (' + (item.id || '') + ')')
				]),
				E('tr', {}, [
					E('td', { 'style': 'font-weight:600;' }, _('告警等级')),
					E('td', {}, item.severity === 'critical' ? _('严重告警') : _('预警提示'))
				]),
				E('tr', {}, [
					E('td', { 'style': 'font-weight:600;' }, _('当前状态')),
					E('td', {}, item.status === 'recovered' ? _('🟢 已恢复正常') : _('🔴 异常进行中'))
				]),
				E('tr', {}, [
					E('td', { 'style': 'font-weight:600;' }, _('触发时数值')),
					E('td', { 'style': 'font-family:monospace;font-weight:bold;' }, item.value || '--')
				]),
				E('tr', {}, [
					E('td', { 'style': 'font-weight:600;' }, _('触发发生时刻')),
					E('td', {}, item.time || '--')
				]),
				E('tr', {}, [
					E('td', { 'style': 'font-weight:600;' }, _('异常持续时长')),
					E('td', {}, item.duration || _('瞬态已消除'))
				]),
				E('tr', {}, [
					E('td', { 'style': 'font-weight:600;' }, _('详情判定说明')),
					E('td', {}, item.detail || _('监测到电网供电指标偏离安全门限，已自动录入电能质量分析日志。'))
				])
			]),
			E('div', { 'class': 'right', 'style': 'margin-top:1.5rem;' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.hideModal
				}, _('关闭'))
			])
		]);
	},

	refreshEvents: function() {
		var self = this;
		return callGetQualityEvents().then(function(res) {
			if (res && res.events) {
				self.eventsList = res.events;
				self.updateEventsList();
			}
		});
	},

	refreshAll: function() {
		var self = this;
		return Promise.all([
			callGetStatus().catch(function() { return {}; }),
			callGetQualityEvents().catch(function() { return { events: [] }; })
		]).then(function(res) {
			self.statusData = res[0] || {};
			if (res[1] && res[1].events) {
				self.eventsList = res[1].events;
			}
			// Refresh UI elements
			var grid = document.getElementById('pq-metrics-grid');
			if (grid && grid.parentNode) {
				var newCard = self.renderCurrentMetricsCard();
				grid.parentNode.replaceWith(newCard);
			}
			self.updateEventsList();
			ui.addNotification(null, E('p', {}, _('电能质量数据已刷新')), 'info');
		});
	}
});
