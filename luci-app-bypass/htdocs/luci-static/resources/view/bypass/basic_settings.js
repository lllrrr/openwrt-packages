'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

// Basic Settings — merged landing page, passwall2-style tabs:
//   Main / Shunt Rule / DNS / Log / Maintain
// Forwarding lives on its own "Other Settings" page (passwall2 puts it there
// too). The BypassCore route-test/resolve/config-preview panel moves to Geo
// View's companion; this page focuses on service control + config.
//
// Top: 4-card status strip (Core + Baidu/Google/GitHub latency) + bypass badge
// row, mirroring passwall2's global/status.htm.

var COL = { green: '#2dce89', red: '#fb6340', yellow: '#fb9a05' };

function injectStyles() {
	if (document.getElementById('bypass-status-style')) return;
	var style = E('style', { id: 'bypass-status-style' });
	style.textContent = [
		'.bypass-status-grid{display:flex;flex-wrap:wrap;gap:.5rem;margin:.5rem 0}',
		'.bypass-card{flex:1 1 24%;min-width:200px;border:1px solid rgba(0,0,0,.05);border-radius:.375rem;box-shadow:0 0 2rem 0 rgba(136,152,170,.15);display:flex;align-items:center;cursor:default}',
		'.bypass-card.check{cursor:pointer}',
		'.bypass-card .ico{margin:1rem;font-size:28px;line-height:1}',
		'.bypass-card h4{font-size:.8125rem;font-weight:600;margin:1rem 1rem 1rem 0;color:#8898aa;line-height:1.8em;min-height:32px}',
		'.bypass-badge-row{display:flex;flex-wrap:wrap;gap:.5rem;margin:.25rem 0 1rem;padding:0 .5rem}',
		'.bypass-badge{display:inline-flex;align-items:center;gap:4px;padding:4px 10px;border-radius:.375rem;border:1px solid rgba(0,0,0,.05);background:rgba(136,152,170,.06);font-size:.85rem}',
		'.bypass-badge .dot{width:8px;height:8px;border-radius:50%;display:inline-block}',
		'@media(max-width:720px){.bypass-card{flex:1 1 48%}}',
		'@media(max-width:480px){.bypass-card{flex:1 1 100%}}'
	].join('\n');
	document.head.appendChild(style);
}

function api(/* action, ...args */) {
	return fs.exec('/usr/share/bypass/api.sh', Array.prototype.slice.call(arguments)).then(function (res) {
		try { return JSON.parse(res.stdout || '{}'); }
		catch (e) { return { code: -1, error: 'bad JSON: ' + res.stdout }; }
	}).catch(function (e) { return { code: -1, error: String(e) }; });
}

function colorClass(ms, okThreshold, midThreshold) {
	if (ms == null) return 'red';
	if (ms < okThreshold) return 'green';
	if (ms < midThreshold) return 'yellow';
	return 'red';
}

function statusCard(type, icon, title, initLabel) {
	var span = E('span', { class: 'red' }, initLabel);
	var h4 = E('h4', {}, [ title, E('br'), span ]);
	var card = E('div', { class: type ? 'bypass-card check' : 'bypass-card' }, [
		E('div', { class: 'ico' }, icon), h4
	]);
	if (type) {
		card.addEventListener('click', function () {
			span.className = '';
			span.textContent = _('Check…');
			var url = ({
				baidu: 'https://www.baidu.com',
				google: 'https://www.google.com/generate_204',
				github: 'https://github.com'
			})[type];
			api('connect_status', type, url).then(function (r) {
				if (r.ping_type === 'curl' && r.use_time != null) {
					span.className = colorClass(r.use_time, 1000, 2000);
					span.textContent = r.use_time + ' ms';
				} else if (r.status) {
					span.className = 'green';
					span.textContent = _('Working…');
				} else {
					span.className = 'red';
					span.textContent = _('Problem detected!');
				}
			});
		});
	}
	return { card: card, span: span };
}

function badge(label, present, okText, badText) {
	var color = present ? COL.green : COL.red;
	return E('span', { class: 'bypass-badge' }, [
		E('span', { class: 'dot', style: 'background:' + color }),
		E('strong', {}, label + ': '),
		E('span', { style: 'color:' + color }, present ? okText : badText)
	]);
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('bypass'),
			api('status'),
			api('interfaces').then(function (r) { return r.interfaces || []; }).catch(function () { return []; })
		]).then(function (res) {
			return { status: res[1] || {}, interfaces: res[2] || [] };
		});
	},

	render: function (data) {
		injectStyles();
		var status = data.status || {};
		var ifaces = data.interfaces || [];

		/* ---- Status strip (4 cards) ---- */
		var core = statusCard(null, '⚙', _('Core'), status.running ? _('RUNNING') : _('NOT RUNNING'));
		if (status.running) { core.span.className = 'green'; }
		var baidu = statusCard('baidu', '🔍', _('Baidu'), _('Touch Check'));
		var google = statusCard('google', '🔎', _('Google'), _('Touch Check'));
		var github = statusCard('github', '🐙', _('GitHub'), _('Touch Check'));

		var statusStrip = E('div', { class: 'bypass-status-grid' }, [
			core.card, baidu.card, google.card, github.card
		]);

		var pollHandle = setInterval(function () {
			api('status').then(function (s) {
				core.span.className = s.running ? 'green' : 'red';
				core.span.textContent = s.running ? _('RUNNING') : _('NOT RUNNING');
			});
		}, 5000);

		/* ---- bypass badge row ---- */
		var badgeRow = E('div', { class: 'bypass-badge-row' }, [
			badge(_('naive'), status.naive_present === 1, _('present'), _('missing')),
			badge(_('chinadns-ng'), status.chinadns_present === 1, _('present'), _('missing')),
			badge(_('bypasscore'), status.bypasscore_present === 1, _('present'), _('missing')),
			badge(_('bypasscore ELF'), status.bypasscore_linux_elf === 1, _('Linux ELF'), _('not Linux ELF')),
			badge(_('Firewall'), !!status.use_tables, status.use_tables || '—', 'none'),
			badge(_('Egress'), !!status.egress_iface, status.egress_iface || _('default'), _('default'))
		]);

		/* ---- The form.Map (tabbed, multi-section) ---- */
		var m = new form.Map('bypass', _('Bypass'),
			_('naiveproxy + ChinaDNS-ng + BypassCore split proxy.'));

		var o;

		/* ===== Section: global → Main / Log / Maintain tabs ===== */
		var sMain = m.section(form.NamedSection, 'global', 'global');
		sMain.addremove = false;
		sMain.tab('Main', _('Main'));
		sMain.tab('Log', _('Log'));
		sMain.tab('Maintain', _('Maintain'));

		o = sMain.taboption('Main', form.Flag, 'enabled', _('Main switch'));
		o.rmempty = false;
		o.default = '0';

		o = sMain.taboption('Main', form.ListValue, 'node',
			E('span', { style: 'color: red' }, _('Node')));
		o.value('', _('Close'));
		uci.sections('bypass', 'nodes').forEach(function (sec) {
			o.value(sec['.name'], sec.remarks ? sec.remarks + ' (' + sec['.name'] + ')' : sec['.name']);
		});

		o = sMain.taboption('Main', form.Flag, 'localhost_proxy', _('Localhost Proxy'));
		o.default = '1';
		o.rmempty = false;
		o = sMain.taboption('Main', form.Flag, 'client_proxy', _('Client Proxy'));
		o.default = '1';
		o.rmempty = false;

		o = sMain.taboption('Main', form.Value, 'node_socks_port', _('Node Socks Listen Port'));
		o.datatype = 'port';
		o.placeholder = '1088';
		o.default = '1088';

		o = sMain.taboption('Main', form.Flag, 'node_socks_bind_local', _('Node Socks Bind Local'),
			_('When selected, it can only be accessed localhost.'));
		o.default = '1';
		o.rmempty = false;

		o = sMain.taboption('Main', form.Value, 'bypasscore_file', _('BypassCore binary'));
		o.placeholder = '/usr/bin/bypasscore';
		o = sMain.taboption('Main', form.Value, 'naive_file', _('naive binary'));
		o.placeholder = '/usr/bin/naive';
		o = sMain.taboption('Main', form.Value, 'chinadns_file', _('chinadns-ng binary'));
		o.placeholder = '/usr/bin/chinadns-ng';

		o = sMain.taboption('Main', form.ListValue, 'default_egress_interface', _('Default Egress Interface'));
		o.description = _('Steer the naive → server tunnel out of this interface. Empty = system default route.');
		o.value('', _('(system default route)'));
		ifaces.forEach(function (i) { o.value(i, i); });
		o = sMain.taboption('Main', form.Value, 'naive_egress_fwmark', _('Egress fwmark'));
		o.placeholder = '0x2';
		o = sMain.taboption('Main', form.Value, 'naive_egress_table', _('Egress route table'));
		o.datatype = 'uinteger';
		o.placeholder = '200';

		/* ===== Section: global_delay → Main tab (boot delay) ===== */
		var sDelay = m.section(form.NamedSection, 'global_delay', 'global_delay');
		sDelay.addremove = false;
		sDelay.tab('Main', _('Main'));
		o = sDelay.taboption('Main', form.Value, 'start_delay', _('Start Delay (seconds)'),
			_('Delay before Bypass starts on boot (lets WAN/DNS settle). 0 = start immediately.'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.placeholder = '5';

		/* ===== Section: global_rules → Shunt Rule tab ===== */
		var sRules = m.section(form.NamedSection, 'global_rules', 'global_rules');
		sRules.addremove = false;
		sRules.tab('Shunt Rule', _('Shunt Rule'));

		o = sRules.taboption('Shunt Rule', form.ListValue, 'domainStrategy', _('Domain Strategy'),
			_('AsIs = no DNS resolution. IpIfNonMatch = resolve on domain mismatch. IpOnDemand = resolve when a rule needs an IP.'));
		o.value('AsIs', 'AsIs');
		o.value('IpIfNonMatch', 'IpIfNonMatch');
		o.value('IpOnDemand', 'IpOnDemand');
		o.default = 'IpOnDemand';

		o = sRules.taboption('Shunt Rule', form.ListValue, 'domainMatcher', _('Domain matcher'),
			_('Xray-only option; shown for parity. BypassCore ignores this.'));
		o.value('hybrid', 'hybrid');
		o.value('linear', 'linear');

		o = sRules.taboption('Shunt Rule', form.Flag, 'write_ipset_direct', _('Direct DNS result write to IPSet'),
			_('Match direct domain rules into IP and connect directly (not entering the core).'));
		o.default = '1';
		o.rmempty = false;

		o = sRules.taboption('Shunt Rule', form.Flag, 'enable_geoview_ip', _('Enable GeoIP Data Parsing'),
			_('Analyze and preload GeoIP data to enhance shunt performance.'));
		o.default = '1';
		o.rmempty = false;

		// shunt_rules list on the same tab.
		var sShunt = m.section(form.TableSection, 'shunt_rules', _('Shunt Rule List'),
			E('span', { style: 'color: red' },
				_('Note the priority: the higher the order, the higher the priority.')));
		sShunt.addremove = true;
		sShunt.anonymous = false;
		sShunt.sortable = true;
		sShunt.tab('Shunt Rule', _('Shunt Rule'));
		sShunt.extedit = function (sid) {
			return 'rule_edit?rule=' + encodeURIComponent(sid);
		};
		o = sShunt.taboption('Shunt Rule', form.DummyValue, 'remarks', _('Remarks'));
		o = sShunt.taboption('Shunt Rule', form.ListValue, 'outbound', _('Outbound'));
		o.value('_direct', _('Direct'));
		o.value('_proxy', _('Proxy (naive)'));
		o.value('_block', _('Block'));

		/* ===== Section: global_dns → DNS tab ===== */
		var sDns = m.section(form.NamedSection, 'global_dns', 'global_dns');
		sDns.addremove = false;
		sDns.tab('DNS', _('DNS'));

		o = sDns.taboption('DNS', form.Value, 'domestic_dns', _('Domestic DNS (china-dns)'),
			_('"auto" = detect ISP DNS from resolv.conf.'));
		o.placeholder = 'auto';
		o = sDns.taboption('DNS', form.Value, 'remote_dns', _('Remote / Foreign DNS (trust-dns)'));
		o.placeholder = '1.1.1.1';
		o = sDns.taboption('DNS', form.ListValue, 'remote_dns_protocol', _('Remote DNS protocol'));
		o.value('udp', _('UDP'));
		o.value('tcp', _('TCP'));
		o.value('tls', _('TLS (DoT)'));
		o.value('https', _('HTTPS (DoH)'));
		o = sDns.taboption('DNS', form.ListValue, 'query_strategy', _('Query strategy'));
		o.value('UseIPv4', _('IPv4 only'));
		o.value('UseIPv6', _('IPv6 only'));
		o.value('UseIP', _('IPv4 + IPv6'));
		o = sDns.taboption('DNS', form.Value, 'chinadns_listen_port', _('ChinaDNS-NG listen port'));
		o.datatype = 'port';
		o.placeholder = '10553';
		o = sDns.taboption('DNS', form.Value, 'bc_domestic_dns', _('BypassCore domestic DNS'),
			_('Upstream for domestic domains in the BypassCore DNS section.'));
		o.placeholder = 'https://223.5.5.5/dns-query';
		o = sDns.taboption('DNS', form.Value, 'bc_remote_dns', _('BypassCore remote DNS'));
		o.placeholder = 'https://1.1.1.1/dns-query';
		o = sDns.taboption('DNS', form.Value, 'dns_split_domain', _('Domestic split domain'));
		o.placeholder = 'geosite:cn';
		o = sDns.taboption('DNS', form.Flag, 'dns_redirect', _('Redirect dnsmasq to ChinaDNS-NG'),
			_('Force special DNS server to need proxy devices.'));
		o.rmempty = false;

		/* ===== Log tab ===== */
		o = sMain.taboption('Log', form.Flag, 'log_node', _('Enable Node Log'));
		o.default = '1';
		o.rmempty = false;
		o = sMain.taboption('Log', form.ListValue, 'loglevel', _('Log Level'));
		o.value('debug', _('Debug'));
		o.value('info', _('Info'));
		o.value('warning', _('Warning'));
		o.value('error', _('Error'));
		o.default = 'warning';

		/* ===== Maintain tab (backup / restore / reset) ===== */
		var maintNote = E('p', { style: 'color:red' },
			_('Note: Restoring configurations across different versions may cause compatibility issues.'));
		var dlBtn = E('button', {
			class: 'cbi-button cbi-button-save',
			click: function () {
				dlBtn.disabled = true;
				dlBtn.textContent = _('Backing up…');
				api('create_backup').then(function (r) {
					dlBtn.disabled = false;
					dlBtn.textContent = _('DL Backup');
					if (r.code === 0 && r.backup) {
						var blob = b64toBlob(r.backup, 'application/gzip');
						var a = document.createElement('a');
						a.href = URL.createObjectURL(blob);
						a.download = r.filename || 'bypass-backup.tar.gz';
						document.body.appendChild(a);
						a.click();
						document.body.removeChild(a);
						URL.revokeObjectURL(a.href);
					} else {
						ui.addNotification(null, E('p', {}, _('Backup failed: ') + (r.error || _('unknown'))));
					}
				});
			}
		}, _('DL Backup'));

		var ulFile = E('input', { type: 'file', class: 'cbi-input-file', accept: '.tar.gz' });
		var ulBtn = E('button', {
			class: 'cbi-button cbi-button-apply',
			click: function () {
				var f = ulFile.files && ulFile.files[0];
				if (!f) { ui.addNotification(null, E('p', {}, _('Choose a .tar.gz file first.'))); return; }
				ulBtn.disabled = true;
				ulBtn.textContent = _('Restoring…');
				var reader = new FileReader();
				reader.onload = function () {
					var b64 = reader.result.split(',')[1];
					api('restore_backup', b64).then(function (r) {
						ulBtn.disabled = false;
						ulBtn.textContent = _('RST Backup');
						if (r.code === 0) {
							ui.addNotification(null, E('p', {}, _('Restored. Restart Bypass to apply.')));
						} else {
							ui.addNotification(null, E('p', {}, _('Restore failed: ') + (r.error || _('unknown'))));
						}
					});
				};
				reader.readAsDataURL(f);
			}
		}, _('RST Backup'));

		var rstBtn = E('button', {
			class: 'cbi-button cbi-button-reset',
			click: function () {
				if (!confirm(_('Restore to default configuration? This deletes your current config.'))) return;
				if (!confirm(_('Are you sure? This cannot be undone.'))) return;
				rstBtn.disabled = true;
				rstBtn.textContent = _('Resetting…');
				api('reset_config').then(function () {
					window.location.reload();
				});
			}
		}, _('Do Reset'));

		o = sMain.taboption('Maintain', form.DummyValue, '_maintain', '');
		o.rawhtml = true;
		o.cfgvalue = function () {
			return E('div', {}, [
				E('h3', {}, _('Backup and Restore')),
				E('p', {}, _('Backup or Restore Client Configurations.')),
				maintNote,
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, _('Create Backup File')),
					E('div', { class: 'cbi-value-field' }, dlBtn)
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, _('Restore Backup File')),
					E('div', { class: 'cbi-value-field' }, [ulFile, ' ', ulBtn])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, _('Restore to default configuration')),
					E('div', { class: 'cbi-value-field' }, rstBtn)
				])
			]);
		};

		/* ---- Assemble ---- */
		var container = E('div', { class: 'cbi-map' }, [
			E('h2', { name: 'content' }, _('Bypass')),
			statusStrip,
			badgeRow
		]);
		container.appendChild(m.render());
		return container;
	}
});

// base64 → Blob helper for the backup download.
function b64toBlob(b64, contentType) {
	var byteChars = atob(b64);
	var byteArrays = [];
	var sliceSize = 8192;
	for (var offset = 0; offset < byteChars.length; offset += sliceSize) {
		var slice = byteChars.slice(offset, offset + sliceSize);
		var byteNumbers = new Array(slice.length);
		for (var i = 0; i < slice.length; i++) byteNumbers[i] = slice.charCodeAt(i);
		byteArrays.push(new Uint8Array(byteNumbers));
	}
	return new Blob(byteArrays, { type: contentType });
}
