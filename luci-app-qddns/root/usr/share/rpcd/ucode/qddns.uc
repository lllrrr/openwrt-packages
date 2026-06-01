#!/usr/bin/env ucode

'use strict';

import { open, popen, stat, writefile, unlink } from 'fs';
import { cursor } from 'uci';

const uci = cursor();
const qddns_ctl = '/usr/bin/qddnsctl';
const ip_cmd = '/sbin/ip';
const mktemp_cmd = '/bin/mktemp';
const draft_probe_config_prefix = '/tmp/qddns-luci-source-probe.';
const draft_probe_config_template = `${draft_probe_config_prefix}XXXXXX`;
const draft_probe_source_id = 'wizard_probe';
const draft_probe_rule_id = 'wizard_rule';
const dhcpv4_lease_file = '/tmp/dhcp.leases';
const dhcpv6_lease_file = '/tmp/odhcpd.leases';
const dhcpv6_lease_max_bytes = 262144;
const dhcpv6_lease_max_entries = 64;
const dhcpv6_lease_max_prefixes = 8;

function is_valid_log_scope(scope) {
	if (!scope)
		return false;

	return match(scope, /^[A-Za-z0-9_.-]+$/) != null;
}

function is_valid_id(id) {
	return is_valid_log_scope(id);
}

function get_source_type(source_id) {
	let source_type = null;

	uci.foreach('qddns', 'source', function(s) {
		if (s['.name'] == source_id)
			source_type = s.type || null;
	});

	return source_type;
}

function is_probe_allowed_source_type(source_type) {
	return source_type == 'local_addr' ||
		source_type == 'interface' ||
		source_type == 'dhcpv6_duid' ||
		source_type == 'dhcpv6_mac' ||
		source_type == 'public_probe';
}

function has_rule(rule_id) {
	let found = false;

	uci.foreach('qddns', 'rule', function(s) {
		if (s['.name'] == rule_id)
			found = true;
	});

	return found;
}

function safe_unload() {
	if (!uci?.unload)
		return;

	try {
		uci.unload('qddns');
	}
	catch (err) {
		return;
	}
}

function create_draft_probe_config_path() {
	let p = popen(`${mktemp_cmd} ${draft_probe_config_template} 2>/dev/null`, 'r');
	if (!p)
		return null;

	let path = trim(p.read('all') || '');
	p.close();
	if (!path || substr(path, 0, length(draft_probe_config_prefix)) != draft_probe_config_prefix)
		return null;

	return path;
}

function exec_json_with_config(config_path, command) {
	let p = popen(`${qddns_ctl} --config ${config_path} ${command} 2>&1`, 'r');
	if (!p)
		return null;

	let data = p.read('all');
	p.close();
	let output = trim(data || '');

	if (output) {
		let parsed = null;
		try {
			parsed = json(output);
		}
		catch (err) {
			parsed = null;
		}

		if (parsed)
			return parsed;

		return { ok: false, error: output || 'command failed' };
	}

	return null;
}

function exec_json(command) {
	return exec_json_with_config('/etc/config/qddns', command);
}

function uci_quote(value) {
	value = trim(`${value || ''}`);

	if (!value)
		return null;

	if (match(value, /['\r\n]/) != null)
		return null;

	return `'${value}'`;
}

function draft_source_option(name, value) {
	let quoted = uci_quote(value);

	if (!quoted)
		return null;

	return `\toption ${name} ${quoted}\n`;
}

function push_unique(list, value) {
	if (!value)
		return;

	for (let index = 0; index < length(list); index++)
		if (list[index] == value)
			return;

	push(list, value);
}

function interface_values(value) {
	let values = [];

	if (type(value) == 'array') {
		for (let item in value) {
			for (let part in split(`${item || ''}`, /,+/)) {
				part = trim(part || '');
				if (part)
					push_unique(values, part);
			}
		}
	} else {
		for (let part in split(`${value || ''}`, /,+/)) {
			part = trim(part || '');
			if (part)
				push_unique(values, part);
		}
	}

	return values;
}

function interface_value(value) {
	return join(',', interface_values(value));
}

function single_interface_value(value) {
	let values = interface_values(value);
	return values[0] || '';
}

function draft_lease_file(value) {
	value = trim(`${value || ''}`);
	if (!value)
		return '';

	return value == dhcpv6_lease_file ? value : null;
}

function draft_probe_url(value) {
	value = trim(`${value || ''}`);
	if (!value)
		return '';

	if (match(value, /^https?:\/\//) == null)
		return null;

	return value;
}

function draft_source_config(req) {
	let source_type = req.args.type || '';
	let source_name = req.args.name || 'Wizard source';
	let lease_file = draft_lease_file(req.args.lease_file);
	let probe_url = draft_probe_url(req.args.probe_url);
	let lines = [
		`\nconfig source '${draft_probe_source_id}'\n`
	];

	if (!is_probe_allowed_source_type(source_type))
		return null;
	if (lease_file == null)
		return null;
	if (probe_url == null)
		return null;

	for (let value in [
		source_name,
		source_type,
		req.args.family,
		req.args.address,
		interface_value(req.args.interface),
		req.args.duid,
		req.args.iaid,
		req.args.mac,
		lease_file,
		req.args.hostname_hint,
		req.args.prefix_filter,
		probe_url
	]) {
		if (value && uci_quote(value) == null)
			return null;
	}

	push(lines, draft_source_option('name', source_name));
	push(lines, draft_source_option('type', source_type));
	push(lines, draft_source_option('family', req.args.family));
	push(lines, draft_source_option('address', req.args.address));
	push(lines, draft_source_option('interface', interface_value(req.args.interface)));
	push(lines, draft_source_option('duid', req.args.duid));
	push(lines, draft_source_option('iaid', req.args.iaid));
	push(lines, draft_source_option('mac', req.args.mac));
	push(lines, draft_source_option('lease_file', lease_file));
	push(lines, draft_source_option('hostname_hint', req.args.hostname_hint));
	push(lines, draft_source_option('prefix_filter', req.args.prefix_filter));
	push(lines, draft_source_option('probe_url', probe_url));

	let config = '';
	for (let line in lines)
		if (line)
			config += line;

	return config;
}

function draft_rule_config(source_id, source_type, probe_interface) {
	let lines = [
		`\nconfig provider 'wizard_provider'\n`,
		`\toption type 'custom_http'\n`,
		`\toption url 'http://127.0.0.1/qddns-luci-draft'\n`,
		`\nconfig rule '${draft_probe_rule_id}'\n`,
		`\toption provider 'wizard_provider'\n`,
		`\toption source '${source_id}'\n`,
		`\toption record_type 'A'\n`,
		`\toption zone 'example.test'\n`,
		`\toption record_name 'wizard'\n`
	];

	push(lines, draft_source_option('probe_interface', single_interface_value(probe_interface)));

	let config = '';
	for (let line in lines)
		if (line)
			config += line;

	return config;
}

function source_family(section) {
	let family = section.family || '';

	if (section.type == 'dhcpv6_duid' || section.type == 'dhcpv6_mac')
		return 'ipv6';

	if (family == 'ipv4' || family == 'ipv6')
		return family;

	return null;
}

function section_to_obj(section) {
	let interfaces = interface_value(section.interface);

	return {
		id: section['.name'],
		type: section.type,
		name: section.name || null,
		family: source_family(section),
		hint: section.hostname_hint || section.address || interfaces || section.duid || section.iaid || null,
		interface: interfaces || null
	};
}

function provider_to_obj(section) {
	return {
		id: section['.name'],
		type: section.type,
		name: section.name || null
	};
}

function rule_to_obj(section) {
	return {
		id: section['.name'],
		enabled: section.enabled == '1',
		name: section.name || null,
		provider: section.provider,
		source: section.source,
		probe_interface: single_interface_value(section.probe_interface) || null,
		record_type: section.record_type,
		zone: section.zone,
		record_name: section.record_name
	};
}

function source_type_for_id(source_id) {
	let source_type = null;

	uci.foreach('qddns', 'source', function(s) {
		if (s['.name'] == source_id)
			source_type = s.type || null;
	});

	return source_type;
}

function rule_source_type(rule_id) {
	let source_id = null;

	uci.foreach('qddns', 'rule', function(s) {
		if (s['.name'] == rule_id)
			source_id = s.source || null;
	});

	return source_id ? source_type_for_id(source_id) : null;
}

function rule_status_to_obj(status) {
	if (!status)
		return { ok: false };

	return {
		running: status.running,
		status: status.status,
		current_ip: status.current_ip,
		remote_ip: status.remote_ip,
		last_result: status.last_result,
		last_error: status.last_error,
		last_check: status.last_check,
		next_run: status.next_run
	};
}

function is_public_ipv6(address) {
	let first = substr(address || '', 0, 1);

	return match(address || '', /:/) != null &&
		(first == '2' || first == '3') &&
		substr(address, 0, 9) != '2001:db8:';
}

function is_private_ipv4(address) {
	address = address || '';

	return substr(address, 0, 3) == '10.' ||
		substr(address, 0, 8) == '192.168.' ||
		(substr(address, 0, 4) == '172.' && match(address, /^172[.](1[6-9]|2[0-9]|3[0-1])[.]/) != null);
}

function normalize_dhcpv6_mac(mac) {
	if (!mac)
		return null;

	mac = lc(mac);
	mac = replace(mac, /[:-]/g, '');

	if (length(mac) != 12 || match(mac, /^[0-9a-f]{12}$/) == null)
		return null;

	return join(':', [
		substr(mac, 0, 2),
		substr(mac, 2, 2),
		substr(mac, 4, 2),
		substr(mac, 6, 2),
		substr(mac, 8, 2),
		substr(mac, 10, 2)
	]);
}

function dhcpv6_duid_mac(duid) {
	if (!duid)
		return null;

	duid = lc(duid);
	if (length(duid) < 12 || match(duid, /^[0-9a-f]+$/) == null)
		return null;

	return normalize_dhcpv6_mac(substr(duid, length(duid) - 12, 12));
}

function strip_lan_suffix(hostname) {
	if (!hostname)
		return null;

	return replace(hostname, /\.lan$/, '');
}

function host_entry(entries, mac) {
	if (!mac)
		return null;

	if (!entries[mac]) {
		entries[mac] = {
			mac: mac,
			hostname: null,
			ipv4: [],
			interfaces: [],
			prefixes: []
		};
	}

	return entries[mac];
}

function read_limited_regular_file(path, max_bytes) {
	let info = null;
	let file = null;
	let content = '';

	try {
		info = stat(path);
	}
	catch (err) {
		return '';
	}

	if (!info || info.type != 'file')
		return '';

	try {
		file = open(path, 'r');
		if (!file)
			return '';

		content = file.read(max_bytes + 1) || '';
	}
	catch (err) {
		content = '';
	}

	if (file) {
		try {
			file.close();
		}
		catch (err) {
			return content || '';
		}
	}

	if (length(content) > max_bytes)
		return substr(content, 0, max_bytes);

	return content;
}

function list_interfaces() {
	return exec_json("interfaces") || { ok: true, interfaces: [] };
}

function list_dhcpv6_leases(mode) {
	mode = mode == "mac" ? "mac" : "duid";
	return exec_json(`leases ${mode}`) || { ok: true, leases: [] };
}
const methods = {
	get_overview: {
		call: function() {
			let status = exec_json('status') || { ok: false };
			let res = {
				main: {
					enabled: (uci.get('qddns', 'main', 'enabled') || '1') == '1',
					log_level: uci.get('qddns', 'main', 'log_level') || 'info'
				},
				status: status
			};

			safe_unload();
			return res;
		}
	},

	list_sources: {
		call: function() {
			let sources = [];
			uci.foreach('qddns', 'source', function(s) {
				push(sources, section_to_obj(s));
			});
			safe_unload();
			return {
				result: sources
			};
		}
	},

	list_interfaces: {
		call: function() {
			return list_interfaces();
		}
	},

	probe_source: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args.id || '';

			if (!is_valid_id(id))
				return { ok: false, error: 'invalid source id' };

			let source_type = get_source_type(id);
			if (!source_type) {
				safe_unload();
				return { ok: false, error: 'missing source' };
			}

			if (!is_probe_allowed_source_type(source_type)) {
				safe_unload();
				return { ok: false, error: 'probe not allowed for source type' };
			}

			let data = exec_json(`sources probe ${id}`);
			safe_unload();
			return data || { ok: false, error: 'probe failed' };
		}
	},

	probe_rule_source: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args.id || '';

			if (!is_valid_id(id) || !has_rule(id)) {
				safe_unload();
				return { ok: false, error: 'invalid rule id' };
			}

			let source_type = rule_source_type(id);
			if (!is_probe_allowed_source_type(source_type)) {
				safe_unload();
				return { ok: false, error: 'probe not allowed for source type' };
			}

			let data = exec_json(`rules probe-source ${id}`);
			safe_unload();
			return data || { ok: false, error: 'probe failed' };
		}
	},

	probe_source_draft: {
		args: {
			name: 'name',
			type: 'type',
			family: 'family',
			address: 'address',
			interface: 'interface',
			duid: 'duid',
			iaid: 'iaid',
			mac: 'mac',
			lease_file: 'lease_file',
			hostname_hint: 'hostname_hint',
			prefix_filter: 'prefix_filter',
			probe_url: 'probe_url',
			probe_interface: 'probe_interface'
		},
		call: function(req) {
			let source_config = draft_source_config(req);
			if (!source_config)
				return { ok: false, error: 'invalid draft source' };
			let probe_interface = single_interface_value(req.args.probe_interface);
			if (probe_interface && uci_quote(probe_interface) == null)
				return { ok: false, error: 'invalid probe interface' };
			let source_type = req.args.type || '';
			let use_rule_probe = source_type == 'public_probe' && probe_interface;

			let draft_probe_config = create_draft_probe_config_path();
			if (!draft_probe_config)
				return { ok: false, error: 'unable to create draft source probe' };

			try {
				writefile(draft_probe_config, source_config + (use_rule_probe ? draft_rule_config(draft_probe_source_id, source_type, probe_interface) : ''));
			}
			catch (err) {
				try {
					unlink(draft_probe_config);
				}
				catch (cleanup_err) {
					return { ok: false, error: 'unable to create draft source probe' };
				}
				return { ok: false, error: 'unable to create draft source probe' };
			}

			let data = exec_json_with_config(draft_probe_config, use_rule_probe ? `rules probe-source ${draft_probe_rule_id}` : `sources probe ${draft_probe_source_id}`) || { ok: false, error: 'probe failed' };

			try {
				unlink(draft_probe_config);
			}
			catch (err) {
				return data;
			}

			return data;
		}
	},

	probe_source_for_rule_draft: {
		args: {
			source: 'source',
			probe_interface: 'probe_interface'
		},
		call: function(req) {
			let source_id = req.args.source || '';
			let probe_interface = single_interface_value(req.args.probe_interface);

			if (!is_valid_id(source_id))
				return { ok: false, error: 'invalid source id' };
			if (probe_interface && uci_quote(probe_interface) == null)
				return { ok: false, error: 'invalid probe interface' };

			let source_type = get_source_type(source_id);
			if (!source_type) {
				safe_unload();
				return { ok: false, error: 'missing source' };
			}
			if (!is_probe_allowed_source_type(source_type)) {
				safe_unload();
				return { ok: false, error: 'probe not allowed for source type' };
			}

			if (!(source_type == 'public_probe' && probe_interface)) {
				let data = exec_json(`sources probe ${source_id}`);
				safe_unload();
				return data || { ok: false, error: 'probe failed' };
			}

			let source_config = '';
			uci.foreach('qddns', 'source', function(s) {
				if (s['.name'] != source_id)
					return;

				source_config += `\nconfig source '${draft_probe_source_id}'\n`;
				for (let name in [
					'name',
					'type',
					'family',
					'address',
					'interface',
					'duid',
					'iaid',
					'mac',
					'lease_file',
					'hostname_hint',
					'prefix_filter',
					'probe_url'
				])
					source_config += draft_source_option(name, name == 'interface' ? interface_value(s[name]) : s[name]) || '';
			});
			safe_unload();

			if (!source_config)
				return { ok: false, error: 'missing source' };

			let draft_probe_config = create_draft_probe_config_path();
			if (!draft_probe_config)
				return { ok: false, error: 'unable to create draft source probe' };

			try {
				writefile(draft_probe_config, source_config + draft_rule_config(draft_probe_source_id, source_type, probe_interface));
			}
			catch (err) {
				try {
					unlink(draft_probe_config);
				}
				catch (cleanup_err) {
					return { ok: false, error: 'unable to create draft source probe' };
				}
				return { ok: false, error: 'unable to create draft source probe' };
			}

			let data = exec_json_with_config(draft_probe_config, `rules probe-source ${draft_probe_rule_id}`) || { ok: false, error: 'probe failed' };

			try {
				unlink(draft_probe_config);
			}
			catch (err) {
				return data;
			}

			return data;
		}
	},

	list_dhcpv6_leases: {
		args: { mode: 'mode' },
		call: function(req) {
			return list_dhcpv6_leases(req.args.mode || 'duid');
		}
	},

	list_rules: {
		call: function() {
			let providers = [];
			let rules = [];

			uci.foreach('qddns', 'provider', function(s) { push(providers, provider_to_obj(s)); });
			uci.foreach('qddns', 'rule', function(s) { push(rules, rule_to_obj(s)); });
			safe_unload();

			return {
				providers: providers,
				rules: rules
			};
		}
	},

	run_rule: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args.id || '';

			if (!is_valid_id(id) || !has_rule(id)) {
				safe_unload();
				return { ok: false, error: 'invalid rule id' };
			}

			let data = exec_json(`rules run ${id}`) || { ok: false };
			safe_unload();
			return data;
		}
	},

	test_rule: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args.id || '';

			if (!is_valid_id(id) || !has_rule(id)) {
				safe_unload();
				return { ok: false, error: 'invalid rule id' };
			}

			let data = exec_json(`rules test ${id}`) || { ok: false };
			safe_unload();
			return data;
		}
	},

	get_logs: {
		args: { scope: 'scope' },
		call: function(req) {
			let scope = req.args.scope || 'system';

			if (!is_valid_log_scope(scope))
				return { ok: false, scope: scope, content: '', entries: [], error: 'invalid log scope' };

			if (scope != 'system' && !has_rule(scope)) {
				safe_unload();
				return { ok: false, scope: scope, content: '', entries: [], error: 'missing log scope' };
			}

			let content = exec_json(`logs ${scope}`);
			safe_unload();
			return content || { ok: false, scope: scope, content: '', entries: [] };
		}
	},

	get_rule_status: {
		args: { id: 'id' },
		call: function(req) {
			let id = req.args.id || '';

			if (!is_valid_id(id) || !has_rule(id)) {
				safe_unload();
				return { ok: false, error: 'invalid rule id' };
			}

			let data = exec_json(`rules status ${id}`);
			safe_unload();
			return rule_status_to_obj(data);
		}
	}
};

return { qddns: methods };
