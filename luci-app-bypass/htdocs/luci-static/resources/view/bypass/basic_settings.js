'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

// Basic Settings — the merged landing page, laid out like passwall2's
// client/global.lua:
//   • 4-card status strip (Core running + Baidu/Google/GitHub latency) at top
//   • bypass badge row (naive/chinadns-ng/bypasscore present + ELF)
//   • form.Map with tabs: Main / Forwarding / DNS / Log / BypassCore
//
// The status strip mirrors passwall2's global/status.htm. Because this is a JS
// view (not a .htm template), the card DOM is built with E() and styles are
// injected via a <style> node.
//
// Multi-section + tabs: each NamedSection owns its own set of tabs (LuCI JS
// binds taboption to the section it is called on), so the global, global_
// forwarding and global_dns sections each re-declare the tabs they use and the
// options are attached to the section that actually holds that UCI option.

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

// rpcd helper: call api.sh <action> [args], parse the single JSON line.
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

		// Poll Core status every 5s (mirrors status.htm XHR.poll(5, ...)).
		var pollHandle = setInterval(function () {
			api('status').then(function (s) {
				core.span.className = s.running ? 'green' : 'red';
				core.span.textContent = s.running ? _('RUNNING') : _('NOT RUNNING');
			});
		}, 5000);
		window.addEventListener('popsstate', function () { clearInterval(pollHandle); });

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

		/* ===== Section: global → Main / Log / BypassCore tabs ===== */
		var sMain = m.section(form.NamedSection, 'global', 'global');
		sMain.addremove = false;
		sMain.tab('Main', _('Main'));
		sMain.tab('Log', _('Log'));
		sMain.tab('BypassCore', _('BypassCore'));

		o = sMain.taboption('Main', form.Flag, 'enabled', _('Main switch'));
		o.rmempty = false;

		o = sMain.taboption('Main', form.ListValue, 'node',
			E('span', { style: 'color: red' }, _('Node')));
		o.value('', _('Close'));
		uci.sections('bypass', 'nodes').forEach(function (sec) {
			o.value(sec['.name'], sec.remarks ? sec.remarks + ' (' + sec['.name'] + ')' : sec['.name']);
		});

		o = sMain.taboption('Main', form.Value, 'node_socks_port', _('SOCKS Port'));
		o.datatype = 'port';
		o.placeholder = '1070';

		o = sMain.taboption('Main', form.Flag, 'localhost_proxy', _('Proxy localhost'));
		o = sMain.taboption('Main', form.Flag, 'client_proxy', _('Proxy router clients'));

		o = sMain.taboption('Main', form.ListValue, 'loglevel', _('Log Level'));
		o.value('debug', _('Debug'));
		o.value('info', _('Info'));
		o.value('warning', _('Warning'));
		o.value('error', _('Error'));

		o = sMain.taboption('Main', form.Flag, 'dns_redirect', _('Redirect dnsmasq to ChinaDNS-NG'));
		o.rmempty = false;

		o = sMain.taboption('Main', form.Flag, 'bypass_as_core', _('BypassCore as transparent core'));
		o.description = _('0 (default): naiveproxy carries traffic, BypassCore is diagnostic-only. 1: BypassCore runs -run as the transparent proxy core; naiveproxy becomes its SOCKS upstream.');
		o.rmempty = false;

		o = sMain.taboption('Main', form.Value, 'bypasscore_file', _('BypassCore binary'));
		o.description = _('Install the Linux ELF from BypassCore releases. Route-test / resolve / observatory auto-disable if missing or not a Linux ELF.');
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

		o = sDelay.taboption('Main', form.Value, 'start_delay', _('Start Delay (seconds)'));
		o.description = _('Delay before Bypass starts on boot (lets WAN/DNS settle). Mirrors passwall2. 0 = start immediately. The default main switch above must be enabled for the service to actually run.');
		o.datatype = 'uinteger';
		o.default = '5';
		o.placeholder = '5';

		/* ===== Section: global_forwarding → Forwarding tab ===== */
		var sFwd = m.section(form.NamedSection, 'global_forwarding', 'global_forwarding');
		sFwd.addremove = false;
		sFwd.tab('Forwarding', _('Forwarding'));

		o = sFwd.taboption('Forwarding', form.Value, 'tcp_redir_ports', _('TCP redirect ports'));
		o.description = _('"1:65535" redirects all TCP. "disable" to disable.');
		o.placeholder = '1:65535';

		o = sFwd.taboption('Forwarding', form.Value, 'udp_redir_ports', _('UDP redirect ports'));
		o.placeholder = '1:65535';

		o = sFwd.taboption('Forwarding', form.Value, 'tcp_no_redir_ports', _('TCP no-redirect ports'));
		o.placeholder = 'disable';

		o = sFwd.taboption('Forwarding', form.Value, 'udp_no_redir_ports', _('UDP no-redirect ports'));
		o.placeholder = 'disable';

		o = sFwd.taboption('Forwarding', form.ListValue, 'tcp_proxy_way', _('Transparent mode'));
		o.value('redirect', _('Redirect (recommended, TCP)'));
		o.value('tproxy', _('TPROXY (TCP + UDP, experimental)'));
		o.description = _('naive listen mode. "redirect" = TCP. "tproxy" = TCP+UDP and requires a naive build with tproxy support plus kmod-nft-tproxy.');

		o = sFwd.taboption('Forwarding', form.Flag, 'ipv6_tproxy', _('Enable IPv6 TProxy'));
		o.rmempty = false;

		/* ===== Section: global_dns → DNS tab ===== */
		var sDns = m.section(form.NamedSection, 'global_dns', 'global_dns');
		sDns.addremove = false;
		sDns.tab('DNS', _('DNS'));

		o = sDns.taboption('DNS', form.Value, 'domestic_dns', _('Domestic DNS (china-dns)'));
		o.description = _('"auto" = detect ISP DNS from resolv.conf.');
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

		o = sDns.taboption('DNS', form.Value, 'bc_domestic_dns', _('BypassCore domestic DNS'));
		o.description = _('Upstream for domestic domains in the BypassCore DNS section. Empty disables the split.');
		o.placeholder = 'https://223.5.5.5/dns-query';

		o = sDns.taboption('DNS', form.Value, 'bc_remote_dns', _('BypassCore remote DNS'));
		o.placeholder = 'https://1.1.1.1/dns-query';

		o = sDns.taboption('DNS', form.Value, 'dns_split_domain', _('Domestic split domain'));
		o.placeholder = 'geosite:cn';

		/* ===== Log tab content (inline log viewer) ===== */
		var logPre = E('pre', { class: 'cbi-section', style: 'white-space:pre-wrap;max-height:420px;overflow:auto;font-size:11px' }, _('Loading…'));
		var refreshLog = function () {
			api('log_tail', '300').then(function (r) {
				while (logPre.firstChild) logPre.removeChild(logPre.firstChild);
				logPre.appendChild(document.createTextNode(r.log || _('(no log yet)')));
			});
		};
		o = sMain.taboption('Log', form.DummyValue, '_log_viewer', '');
		o.rawhtml = true;
		o.cfgvalue = function () {
			return E('div', {}, [
				E('div', { class: 'cbi-section', style: 'margin-bottom:8px' }, [
					E('button', { class: 'cbi-button cbi-button-neutral', click: refreshLog }, _('Refresh')),
					' ',
					E('button', {
						class: 'cbi-button cbi-button-reset',
						click: function () {
							api('clear_log').then(function () {
								while (logPre.firstChild) logPre.removeChild(logPre.firstChild);
								logPre.appendChild(document.createTextNode(_('(cleared)')));
							});
						}
					}, _('Clear'))
				]),
				logPre
			]);
		};
		refreshLog();

		/* ===== BypassCore tab content (route test + resolve + config preview) ===== */
		var rtInput = E('input', { type: 'text', class: 'cbi-input-text', placeholder: 'tcp:www.google.com:443', style: 'width:340px' });
		var rtResult = E('pre', { style: 'white-space:pre-wrap;min-height:40px;font-size:11px' }, _('Results appear here.'));
		var dnsInput = E('input', { type: 'text', class: 'cbi-input-text', placeholder: 'example.com', style: 'width:340px' });
		var dnsResult = E('pre', { style: 'white-space:pre-wrap;min-height:40px;font-size:11px' }, _('Resolved IPs appear here.'));
		var cfgPre = E('pre', { style: 'white-space:pre-wrap;max-height:420px;overflow:auto;font-size:11px' }, _('Click to generate/preview.'));

		o = sMain.taboption('BypassCore', form.DummyValue, '_bc_panel', '');
		o.rawhtml = true;
		o.cfgvalue = function () {
			return E('div', {}, [
				E('div', { class: 'cbi-section' }, [
					E('h3', {}, _('BypassCore route test')),
					E('p', {}, _('Preview which shunt rule / outbound a destination matches.')),
					E('div', { style: 'margin-bottom:8px' }, [
						rtInput, ' ',
						E('button', {
							class: 'cbi-button cbi-button-apply',
							click: function () {
								var dest = (rtInput.value || '').trim();
								if (!dest) { ui.addNotification(null, E('p', {}, _('Enter a destination like tcp:www.google.com:443'))); return; }
								api('route_test', dest).then(function (r) {
									while (rtResult.firstChild) rtResult.removeChild(rtResult.firstChild);
									if (r.code === 0 || r.code === undefined) {
										rtResult.appendChild(document.createTextNode(
											(r.matched ? _('Matched: ') + r.matched + '\n\n' : '') + (r.raw || _('(no output)'))));
									} else {
										rtResult.appendChild(document.createTextNode(_('Error: ') + (r.error || r.raw || _('unknown'))));
									}
								});
							}
						}, _('Test')),
						' ',
						E('button', {
							class: 'cbi-button cbi-button-neutral',
							click: function () {
								api('observe').then(function (r) {
									while (rtResult.firstChild) rtResult.removeChild(rtResult.firstChild);
									rtResult.appendChild(document.createTextNode(r.raw || r.error || _('(no output)')));
								});
							}
						}, _('Observatory'))
					]),
					rtResult
				]),
				E('div', { class: 'cbi-section' }, [
					E('h3', {}, _('DNS resolve (BypassCore)')),
					E('div', { style: 'margin-bottom:8px' }, [
						dnsInput, ' ',
						E('button', {
							class: 'cbi-button cbi-button-apply',
							click: function () {
								var dom = (dnsInput.value || '').trim();
								if (!dom) { ui.addNotification(null, E('p', {}, _('Enter a domain to resolve.'))); return; }
								api('resolve', dom).then(function (r) {
									while (dnsResult.firstChild) dnsResult.removeChild(dnsResult.firstChild);
									if (r.code === 0) {
										dnsResult.appendChild(document.createTextNode(r.raw || _('(no output)')));
									} else {
										dnsResult.appendChild(document.createTextNode(_('Error: ') + (r.error || r.raw || _('unknown'))));
									}
								});
							}
						}, _('Resolve'))
					]),
					dnsResult
				]),
				E('div', { class: 'cbi-section' }, [
					E('h3', {}, _('BypassCore config.json preview')),
					E('button', {
						class: 'cbi-button cbi-button-action',
						click: function () {
							api('config_preview').then(function (r) {
								while (cfgPre.firstChild) cfgPre.removeChild(cfgPre.firstChild);
								cfgPre.appendChild(document.createTextNode(r.config || r.error || _('(none)')));
							});
						}
					}, _('Generate & preview')),
					cfgPre
				])
			]);
		};

		/* ---- Assemble: status strip + badges above the map ---- */
		var container = E('div', { class: 'cbi-map' }, [
			E('h2', { name: 'content' }, _('Bypass')),
			statusStrip,
			badgeRow
		]);
		container.appendChild(m.render());
		return container;
	}
});
