'use strict';
'require view';
'require form';
'require uci';
'require rpc';

/* IPv6 Connectivity Check - Configuration page */

var callGetInterfaces = rpc.declare({
	object: 'ipv6check',
	method: 'get_interfaces',
	expect: {}
});

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('ipv6check'),
			callGetInterfaces().catch(function() { return { interfaces: [] }; })
		]);
	},

	render: function(data) {
		var ifaceData = data[1] || {};
		var interfaces = ifaceData.interfaces || ['wan', 'wan6', 'lan'];
		if (!interfaces.length)
			interfaces = ['wan', 'wan6', 'lan'];

		var m, s, o;

		/* ===== Main form ===== */
		m = new form.Map('ipv6check', _('IPv6 Connectivity Check'),
			_('Periodically check IPv6 connectivity and automatically restart a network interface when all targets are unreachable.'));

		/* ===== Global settings ===== */
		s = m.section(form.NamedSection, 'global', 'ipv6check', _('Global Settings'));
		s.anonymous = false;
		s.addremove = false;

		/* enabled toggle */
		o = s.option(form.Flag, 'enabled', _('Enable Monitoring'),
			_('Enable or disable the IPv6 connectivity check service'));
		o.default = '1';
		o.rmempty = false;

		/* check interval */
		o = s.option(form.Value, 'interval', _('Check Interval (seconds)'),
			_('Wait time between checks, minimum 30 seconds'));
		o.datatype = 'uinteger';
		o.default = '300';
		o.placeholder = '300';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 30 || v > 86400) return _('Check interval must be between 30 and 86400 seconds.');
			return true;
		};

		/* retry count */
		o = s.option(form.Value, 'retry_count', _('Retry Count'),
			_('Maximum ping attempts per target'));
		o.datatype = 'uinteger';
		o.default = '3';
		o.placeholder = '3';
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 1 || v > 10) return _('Retry count must be between 1 and 10.');
			return true;
		};

		/* retry interval */
		o = s.option(form.Value, 'retry_interval', _('Retry Interval (seconds)'),
			_('Wait time between retries'));
		o.datatype = 'uinteger';
		o.default = '10';
		o.placeholder = '10';
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 1 || v > 3600) return _('Retry interval must be between 1 and 3600 seconds.');
			return true;
		};

		/* failure threshold */
		o = s.option(form.Value, 'failure_threshold', _('Failure Threshold'),
			_('Consecutive all-fail checks needed to trigger an interface restart'));
		o.datatype = 'uinteger';
		o.default = '3';
		o.placeholder = '3';
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 1 || v > 100) return _('Failure threshold must be between 1 and 100.');
			return true;
		};

		/* auto restart toggle */
		o = s.option(form.Flag, 'auto_restart', _('Auto Restart Interface'),
			_('Automatically restart the specified network interface when consecutive failures reach the threshold'));
		o.default = '1';

		/* restart interface selector */
		o = s.option(form.ListValue, 'restart_interface', _('Restart Interface'),
			_('Network interface to restart on failure'));
		o.default = 'wan6';
		interfaces.forEach(function(iface) {
			o.value(iface, iface);
		});
		/* 确保 wan6 始终在列表中 */
		if (interfaces.indexOf('wan6') === -1) {
			o.value('wan6', 'wan6');
		}

		/* log level */
		o = s.option(form.ListValue, 'log_level', _('Log Level'),
			_('Controls the verbosity of the log'));
		o.value('0', _('Silent - errors only'));
		o.value('1', _('Normal - check results'));
		o.value('2', _('Verbose - all operations'));
		o.default = '1';

		/* max log entries */
		o = s.option(form.Value, 'max_log_entries', _('Max Log Entries'),
			_('Maximum number of entries to keep in the local log file'));
		o.datatype = 'uinteger';
		o.default = '100';
		o.placeholder = '100';
		o.validate = function(section_id, value) {
			var v = parseInt(value);
			if (isNaN(v) || v < 10 || v > 10000) return _('Max log entries must be between 10 and 10000.');
			return true;
		};

		/* ===== Detection targets ===== */
		s = m.section(form.TableSection, 'target', _('Detection Targets'),
			_('Add IPv6 targets to check. Adding multiple DNS servers from different providers improves accuracy.'));
		s.addbtntitle = _('Add Target');
		s.addremove = true;
		s.sortable = true;

		/* target name */
		o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = 'e.g. Google DNS';
		o.rmempty = false;
		o.width = '25%';

		/* target address */
		o = s.option(form.Value, 'host', _('IPv6 Address'));
		o.placeholder = 'e.g. 2001:4860:4860::8888';
		o.rmempty = false;
		o.width = '45%';
		o.validate = function(section_id, value) {
			if (!value || value === '') return _('Please enter an IPv6 address.');

			/* 严格 IPv6 地址格式校验（RFC 4291 全表示形式） */
			var ipv6Regex = /^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:))$/;
			/* 合规域名格式校验（RFC 1123：每段 1-63 字母数字或连字符，不以连字符开头/结尾） */
			var hostnameRegex = /^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$/;

			if (!ipv6Regex.test(value) && !hostnameRegex.test(value)) {
				return _('Please enter a valid IPv6 address or hostname.');
			}
			return true;
		};

		/* enabled flag */
		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';
		o.width = '15%';

		return m.render();
	}
});
