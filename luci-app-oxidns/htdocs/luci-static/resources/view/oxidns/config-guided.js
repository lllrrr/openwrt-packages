'use strict';
'require baseclass';
'require ui';
'require oxidns.adfilter as adfilter';

var LOG_LEVELS = [ 'off', 'trace', 'debug', 'info', 'warn', 'error' ];
var LOG_ROTATIONS = [ 'never', 'minutely', 'hourly', 'daily', 'weekly' ];
var LISTEN_SERVER_TYPES = { udp_server: true, tcp_server: true, quic_server: true };
var TLS_SERVER_TYPES = { tcp_server: true, quic_server: true, http_server: true };

var UPSTREAM_CHOICES = null;

/*
 * LuCI's closeDropdown() resets the inline width/height of the dropdown node
 * after a selection, which would otherwise shrink the control to its content.
 * Pin the sizing through a stylesheet rule so the width stays stable.
 */
var UPSTREAM_SELECT_CLASS = 'oxidns-upstream-select';
var UPSTREAM_SELECT_STYLE = '.' + UPSTREAM_SELECT_CLASS + ' { width: 100% !important; margin: 0; text-align: left; }';

/*
 * The Bootstrap theme stretches inputs inside .cbi-section-table to the full
 * cell width, while its normal form controls stay at 210px. Keep this page
 * consistent with the theme's native control width.
 */
var BOOTSTRAP_FORM_STYLE =
	'.oxidns-bootstrap-form .table.cbi-section-table .oxidns-control { ' +
	'width: 210px; max-width: 100%; box-sizing: border-box; }';

function isBootstrapTheme() {
	var links = document.querySelectorAll('link[rel="stylesheet"]');

	for (var i = 0; i < links.length; i++) {
		var href = links[i].getAttribute('href') || '';

		if (/(^|\/)bootstrap(?:-[a-z]+)?\/cascade\.css/.test(href))
			return true;
	}

	return false;
}

function upstreamChoices() {
	if (!UPSTREAM_CHOICES) {
		UPSTREAM_CHOICES = {
			'223.5.5.5': _('Aliyun Public DNS (223.5.5.5)'),
			'223.6.6.6': _('Aliyun Public DNS (223.6.6.6)'),
			'119.29.29.29': _('Tencent Public DNS (119.29.29.29)'),
			'119.28.28.28': _('Tencent Public DNS (119.28.28.28)'),
			'114.114.114.114': _('Xinfeng Public DNS (114.114.114.114)'),
			'180.76.76.76': _('Baidu Public DNS (180.76.76.76)'),
			'https://dns.alidns.com/dns-query': _('Aliyun Public DNS (DNS over HTTPS)'),
			'quic://dns.alidns.com': _('Aliyun Public DNS (DNS over QUIC)'),
			'https://doh.pub/dns-query': _('Tencent Public DNS (DNS over HTTPS)'),
			'https://doh.360.cn/dns-query': _('360 Public DNS (DNS over HTTPS)'),
			'tls://1.1.1.1': _('Cloudflare Public DNS (1.1.1.1)'),
			'tls://1.0.0.1': _('Cloudflare Public DNS (1.0.0.1)'),
			'tls://8.8.8.8': _('Google Public DNS (8.8.8.8)'),
			'tls://8.8.4.4': _('Google Public DNS (8.8.4.4)'),
			'tls://9.9.9.9': _('Quad9 Public DNS (9.9.9.9)'),
			'tls://149.112.112.112': _('Quad9 Public DNS (149.112.112.112)'),
			'tls://208.67.222.222': _('Cisco Public DNS (208.67.222.222)'),
			'tls://208.67.220.220': _('Cisco Public DNS (208.67.220.220)'),
			'https://cloudflare-dns.com/dns-query': _('Cloudflare Public DNS (DNS over HTTPS)'),
			'https://dns.google/dns-query': _('Google Public DNS (DNS over HTTPS)'),
			'https://dns.quad9.net/dns-query': _('Quad9 Public DNS (DNS over HTTPS)')
		};
	}

	return UPSTREAM_CHOICES;
}

function text(value) {
	if (value === null || value === undefined)
		return '';
	if (typeof value === 'object')
		return '';
	return String(value);
}

function hasNodePath(doc, path) {
	try {
		return doc.hasIn(path);
	}
	catch (err) {
		return false;
	}
}

function pluginItems(doc) {
	return arrayItems(doc, [ 'plugins' ]);
}

function pluginType(item) {
	if (!item || typeof item.get !== 'function')
		return '';
	return text(item.get('type'));
}

function pluginTag(item, index) {
	if (item && typeof item.get === 'function') {
		var tag = text(item.get('tag'));
		if (tag)
			return tag;
	}
	return '#' + (index + 1);
}

function arrayItems(doc, path) {
	var seq = doc.getIn(path, true);

	if (!seq || !Array.isArray(seq.items))
		return [];

	// A mapping also exposes pairs through "items"; only read sequences.
	return seq.items.length && isPairItem(seq.items[0]) ? [] : seq.items;
}

function isPairItem(item) {
	return !!(item && typeof item === 'object' && 'key' in item && 'value' in item);
}

function isListNode(node) {
	return !!(node && Array.isArray(node.items) &&
		!(node.items.length && isPairItem(node.items[0])));
}

function isEmptyNode(node) {
	if (node === null || node === undefined)
		return true;

	if (typeof node !== 'object')
		return node === '';

	if (Array.isArray(node.items))
		return !node.items.length;

	if ('value' in node)
		return node.value === null || node.value === undefined || node.value === '';

	return false;
}

/*
 * Mappings and sequences both expose "items", so a key like "args:" can look
 * like a list to a plain Array.isArray() check. Inspect the first item and fall
 * back to toJSON() for empty collections; a scalar or alias is neither.
 */
function nodeKind(node) {
	if (!node || !Array.isArray(node.items))
		return '';

	if (node.items.length)
		return isPairItem(node.items[0]) ? 'map' : 'seq';

	try {
		return Array.isArray(node.toJSON()) ? 'seq' : 'map';
	}
	catch (err) {
		return '';
	}
}

/*
 * Document.addIn() and setIn() throw when a hand-written key without a value
 * ("args:", "upstreams:", "entries:") parses as a null scalar. Replace the
 * empty scalar ancestors with mappings and an empty target with a list so the
 * caller can append to it. A node that already holds a value is left alone;
 * the caller reports the problem instead of discarding what the user wrote.
 */
function ensureListNode(doc, path) {
	for (var depth = 1; depth < path.length; depth++) {
		var prefix = path.slice(0, depth);
		var node = doc.getIn(prefix, true);

		if (node === undefined)
			break;

		if (Array.isArray(node.items))
			continue;

		if (!isEmptyNode(node))
			return false;

		doc.setIn(prefix, doc.createNode({}));
	}

	var list = doc.getIn(path, true);

	if (isListNode(list) && list.items.length)
		return true;

	if (list && !isEmptyNode(list))
		return false;

	doc.setIn(path, doc.createNode([]));
	return true;
}

/*
 * Delete a field and then the mapping or sequence that held it when it has
 * nothing left, so clearing network.outbound.default does not leave an
 * "outbound: {}" behind. Stop at the first ancestor that still has content.
 */
function deleteAndPrune(doc, path) {
	doc.deleteIn(path);

	for (var depth = path.length - 1; depth > 0; depth--) {
		var prefix = path.slice(0, depth);
		var node = doc.getIn(prefix, true);

		if (!node || !Array.isArray(node.items) || node.items.length)
			break;

		doc.deleteIn(prefix);
	}
}

function listShapeProblem(field) {
	ui.addNotification(null, E('p', {},
		_('The %s field must be a list. Fix it in Advanced Mode.').format(field)), 'danger');
}

function pluginsShapeProblem(doc) {
	var value = plainValue(doc, [ 'plugins' ]);

	if (value === undefined || value === null || Array.isArray(value))
		return false;

	if (typeof value === 'object')
		return Object.keys(value).length > 0;

	return value !== '';
}

function pathStartsWith(path, prefix) {
	if (!Array.isArray(path) || path.length < prefix.length)
		return false;

	for (var i = 0; i < prefix.length; i++) {
		if (path[i] !== prefix[i])
			return false;
	}

	return true;
}

function row(label, control, description) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', { 'class': 'td left' }, [
			control,
			description ? E('div', { 'class': 'cbi-value-description', 'style': 'margin-top: .35em;' }, description) : ''
		])
	]);
}

function noteRow(message) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'padding: .5em var(--section-inset, 0); color: inherit; opacity: .8;' }, message)
	]);
}

function section(title, description, rows, tableStyle, footer) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, title),
		description ? E('div', { 'class': 'cbi-section-descr' }, description) : '',
		E('div', { 'class': 'table cbi-section-table', 'style': tableStyle || null }, rows),
		footer || ''
	]);
}

function textInput(id, value, placeholder) {
	return E('input', {
		'id': id,
		'class': 'cbi-input-text oxidns-control',
		'type': 'text',
		'value': value || '',
		'placeholder': placeholder || null
	});
}

function upstreamSelect(id, value) {
	var combobox = new ui.Combobox(value || '', upstreamChoices(), {
		'id': id,
		'sort': false,
		'select_placeholder': _('Select an upstream DNS server'),
		'custom_placeholder': _('Enter a custom upstream address')
	});

	var node = combobox.render();
	node.classList.add(UPSTREAM_SELECT_CLASS);
	return node;
}

function levelSelect(id, value) {
	var levels = LOG_LEVELS.slice();
	if (value && levels.indexOf(value) === -1)
		levels.push(value);

	return E('select', { 'id': id, 'class': 'cbi-input-select oxidns-control' },
		levels.map(function(level) {
			return E('option', {
				'value': level,
				'selected': level === value ? 'selected' : null
			}, level);
		}));
}

function rotationSelect(id, value) {
	var rotations = LOG_ROTATIONS.slice();
	if (value && rotations.indexOf(value) === -1)
		rotations.push(value);

	return E('select', { 'id': id, 'class': 'cbi-input-select oxidns-control' },
		rotations.map(function(rotation) {
			return E('option', {
				'value': rotation,
				'selected': rotation === value ? 'selected' : null
			}, rotation);
		}));
}

function addBinding(bindings, id, path, empty, kind, defaultValue, options) {
	var binding = {
		'id': id,
		'path': path,
		'empty': empty || 'set',
		'kind': kind || 'string',
		'default': defaultValue
	};

	if (options) {
		for (var key in options) {
			if (Object.prototype.hasOwnProperty.call(options, key))
				binding[key] = options[key];
		}
	}

	bindings.push(binding);
}

function bindingValue(doc, path) {
	var value = doc.getIn(path, true);

	if (value && typeof value.toJSON === 'function')
		value = value.toJSON();

	return value;
}

function editedLines(input) {
	return String(input.value || '').split('\n').map(function(line) {
		return line.trim();
	}).filter(function(line) {
		return line.length > 0;
	});
}

function sameLines(current, lines) {
	var currentLines = Array.isArray(current) ? current : (typeof current === 'string' ? [ current ] : null);

	if (!currentLines || currentLines.length !== lines.length)
		return false;

	for (var i = 0; i < lines.length; i++) {
		if (text(currentLines[i]) !== lines[i])
			return false;
	}

	return true;
}

function applyBindings(doc, bindings) {
	var authPath = [ 'api', 'http', 'auth' ];
	var authChanged = false;

	for (var i = 0; i < bindings.length; i++) {
		var binding = bindings[i];
		var kind = binding.kind || 'string';

		/*
		 * Custom bindings operate on the whole form (for example the managed
		 * ad filtering group) and do not map to a single input element.
		 */
		if (kind === 'custom') {
			if (typeof binding.apply === 'function') {
				try {
					binding.apply();
				}
				catch (err) {
					/* Leave the node untouched; oxidns check reports the real problem. */
				}
			}

			continue;
		}

		var input = document.getElementById(binding.id);

		if (!input)
			continue;

		try {
			var present = hasNodePath(doc, binding.path);
			var current = present ? bindingValue(doc, binding.path) : undefined;

			if (kind === 'checkbox-delete') {
				if (input.checked)
					doc.deleteIn(binding.path);
				continue;
			}

			if (kind === 'secret') {
				var secret = String(input.value || '');

				if (!secret || (present && String(current) === secret))
					continue;

				doc.setIn(binding.path, secret);

				if (pathStartsWith(binding.path, authPath))
					authChanged = true;
				continue;
			}

			if (kind === 'boolean') {
				var unchanged = present
					? input.checked === (current === true)
					: input.checked === (binding['default'] === true);

				if (unchanged)
					continue;

				doc.setIn(binding.path, !!input.checked);

				if (pathStartsWith(binding.path, authPath))
					authChanged = true;
				continue;
			}

			var value = String(input.value || '').trim();
			var defaultValue = binding['default'] === undefined ? '' : String(binding['default']);

			if (kind === 'string-list') {
				var lines = editedLines(input);

				if (!present) {
					if (!lines.length || (Array.isArray(binding['default']) && sameLines(binding['default'], lines)))
						continue;
				}
				else if (sameLines(current, lines)) {
					continue;
				}

				if (!lines.length) {
					if (present)
						doc.deleteIn(binding.path);
				}
				else {
					doc.setIn(binding.path, doc.createNode(lines));
				}
				continue;
			}

			/*
			 * Do not turn an absent node into an explicit value when the form
			 * still shows the documented default, and do not rewrite a value
			 * that is already stored as the form shows it. Both would make the
			 * change preview report edits the user never made.
			 */
			if (!present ? value === defaultValue : String(current) === value)
				continue;

			if (!value) {
				if (binding.empty === 'delete') {
					if (present) {
						if (binding.prune)
							deleteAndPrune(doc, binding.path);
						else
							doc.deleteIn(binding.path);
					}
				}
				else {
					doc.setIn(binding.path, '');
				}
				continue;
			}

			if (kind === 'number') {
				var number = Number(value);

				if (!isFinite(number))
					continue;

				doc.setIn(binding.path, number);
				continue;
			}

			doc.setIn(binding.path, value);

			if (pathStartsWith(binding.path, authPath))
				authChanged = true;
		}
		catch (err) {
			/* Leave the node untouched; oxidns check reports the real problem. */
		}
	}

	/*
	 * OxiDNS currently supports only Basic authentication. When the form
	 * writes a username or password, materialize auth.type so the saved
	 * block is complete without touching an existing untouched block.
	 */
	if (authChanged && hasNodePath(doc, authPath) &&
	    !hasNodePath(doc, authPath.concat([ 'type' ])))
		doc.setIn(authPath.concat([ 'type' ]), 'basic');
}

function logSection(doc, bindings) {
	var level = text(doc.getIn([ 'log', 'level' ])) || 'info';
	var file = text(doc.getIn([ 'log', 'file' ]));
	var rotation = text(doc.getIn([ 'log', 'rotation', 'type' ])) || 'never';
	var maxFiles = text(doc.getIn([ 'log', 'rotation', 'max_files' ]));

	addBinding(bindings, 'oxidns-cfg-log-level', [ 'log', 'level' ], 'delete', 'string', 'info');
	addBinding(bindings, 'oxidns-cfg-log-file', [ 'log', 'file' ], 'delete');
	addBinding(bindings, 'oxidns-cfg-log-rotation', [ 'log', 'rotation', 'type' ], 'delete', 'string', 'never');
	addBinding(bindings, 'oxidns-cfg-log-rotation-max-files', [ 'log', 'rotation', 'max_files' ], 'delete', 'number');

	/*
	 * The keep count only applies while rotation runs. When the user switches
	 * rotation off, drop a stored count instead of leaving an unused value
	 * behind. A config that already says "never" is saved unchanged.
	 */
	bindings.push({
		'kind': 'custom',
		'apply': function() {
			var input = document.getElementById('oxidns-cfg-log-rotation');

			if (!input || String(input.value) !== 'never' || rotation === 'never')
				return;

			if (hasNodePath(doc, [ 'log', 'rotation', 'max_files' ]))
				doc.deleteIn([ 'log', 'rotation', 'max_files' ]);
		}
	});

	return section(_('Log'), null, [
		row(_('Log level'), levelSelect('oxidns-cfg-log-level', level)),
		row(_('Log file'), textInput('oxidns-cfg-log-file', file, '/tmp/oxidns/oxidns.log'),
			_('Leave empty to stop writing to a log file.')),
		row(_('Rotation'), rotationSelect('oxidns-cfg-log-rotation', rotation)),
		row(_('Maximum rotation files'), E('input', {
			'id': 'oxidns-cfg-log-rotation-max-files',
			'class': 'cbi-input-text oxidns-control',
			'type': 'number',
			'step': '1',
			'min': '0',
			'value': maxFiles,
			'placeholder': '0'
		}), _('Leave empty or set to 0 to keep all historical rotation files.'))
	]);
}

function runtimeSection(doc, bindings) {
	addBinding(bindings, 'oxidns-cfg-runtime-threads',
		[ 'runtime', 'worker_threads' ], 'delete', 'number');

	return section(_('Runtime'),
		_('Leave the worker thread count empty to use the system parallelism.'),
		[
			row(_('Worker threads'), E('input', {
				'id': 'oxidns-cfg-runtime-threads',
				'class': 'cbi-input-text oxidns-control',
				'type': 'number',
				'step': '1',
				'min': '1',
				'value': text(doc.getIn([ 'runtime', 'worker_threads' ])),
				'placeholder': _('Automatic')
			}), _('Must be at least 1.'))
		]);
}

function includeSection(doc, bindings) {
	addBinding(bindings, 'oxidns-cfg-include', [ 'include' ], 'delete', 'string-list');

	return section(_('Included Files'),
		_('Only plugins are loaded from these files; other settings in them are ignored. Relative paths are resolved against the directory of this configuration file.'),
		[
			row(_('Included configuration files'), E('textarea', {
				'id': 'oxidns-cfg-include',
				'class': 'cbi-input-textarea',
				'rows': 3,
				'style': 'width: calc(100% / 3); font-family: monospace;',
				'placeholder': './plugins/common.yaml'
			}, schemaListValue(plainValue(doc, [ 'include' ]))),
				_('One path per line. Plugins from included files are not listed on this page.'))
		]);
}

function outboundProfiles(doc) {
	var profiles = plainValue(doc, [ 'network', 'outbound', 'profiles' ]);

	if (!profiles || typeof profiles !== 'object' || Array.isArray(profiles))
		return [];

	return Object.keys(profiles);
}

function outboundSection(doc, bindings) {
	var current = text(doc.getIn([ 'network', 'outbound', 'default' ]));
	var profiles = outboundProfiles(doc);
	var choices = [ '' ].concat(profiles);

	if (current && choices.indexOf(current) === -1)
		choices.push(current);

	addBinding(bindings, 'oxidns-cfg-outbound-default',
		[ 'network', 'outbound', 'default' ], 'delete', 'string', undefined, { 'prune': true });

	return section(_('Outbound Network'),
		profiles.length
			? _('Profiles are defined under network.outbound.profiles.')
			: _('No outbound profiles are defined. Add them under network.outbound.profiles in Advanced Mode or the WebUI.'),
		[
			row(_('Default outbound profile'),
				E('select', {
					'id': 'oxidns-cfg-outbound-default',
					'class': 'cbi-input-select oxidns-control'
				}, choices.map(function(name) {
					var label = name === ''
						? _('None (system DNS and direct connections)')
						: (profiles.indexOf(name) === -1 ? _('%s (not defined)').format(name) : name);

					return E('option', {
						'value': name,
						'selected': name === current ? 'selected' : null
					}, label);
				})),
				_('Used by HTTP clients and upstreams that do not set an outbound profile.'))
		]);
}

/*
 * Turn api.http: "ip:port" into the expanded form so the WebUI, TLS,
 * authentication, and CORS fields can be configured. Only the listen value is
 * moved; comments attached to the original node are carried over.
 */
function expandApiHttp(doc) {
	var old = doc.getIn([ 'api', 'http' ], true);
	var listen = old && old.value !== undefined ? text(old.value) : '';
	var expanded = doc.createNode({ 'listen': listen });
	var pair = expanded.items && expanded.items[0];

	if (pair) {
		if (old && old.type)
			pair.value.type = old.type;
		if (old && old.comment)
			pair.value.comment = old.comment;
		if (old && old.commentBefore)
			pair.key.commentBefore = old.commentBefore;
		if (old && old.spaceBefore)
			pair.key.spaceBefore = old.spaceBefore;
	}

	doc.setIn([ 'api', 'http' ], expanded);
}

function apiSection(doc, bindings, options) {
	var http = plainValue(doc, [ 'api', 'http' ]);
	var shorthand = typeof http === 'string';
	var listen = shorthand ? http : text(doc.getIn([ 'api', 'http', 'listen' ]));

	/*
	 * In shorthand form the binding path is the whole api.http value, so
	 * "delete" would silently drop the API when the field is cleared. Keep an
	 * empty scalar instead and let validate() report it like the expanded form.
	 */
	addBinding(bindings, 'oxidns-cfg-api-listen',
		shorthand ? [ 'api', 'http' ] : [ 'api', 'http', 'listen' ],
		shorthand ? 'set' : 'delete');

	var rows = [
		row(_('HTTP listen'), textInput('oxidns-cfg-api-listen', listen, '0.0.0.0:9199'))
	];

	if (shorthand) {
		rows.push(row('', E('button', {
			'id': 'oxidns-cfg-api-expand',
			'class': 'btn cbi-button cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();

				if (typeof options.beforeChange === 'function')
					options.beforeChange();

				expandApiHttp(doc);

				if (typeof options.rerender === 'function')
					options.rerender();
			}
		}, _('Convert to expanded form')),
			_('The shorthand form only sets the listen address. Convert it to configure the WebUI, TLS, authentication, and CORS.')));
	}
	else {
		addBinding(bindings, 'oxidns-cfg-api-root', [ 'api', 'http', 'webui', 'root' ], 'delete');
		addBinding(bindings, 'oxidns-cfg-api-index', [ 'api', 'http', 'webui', 'index' ], 'delete', 'string', 'index.html');

		rows.push(row(_('WebUI root'),
			textInput('oxidns-cfg-api-root', text(doc.getIn([ 'api', 'http', 'webui', 'root' ])),
				'/usr/share/oxidns/webui')));
		rows.push(row(_('WebUI index'),
			textInput('oxidns-cfg-api-index',
				text(doc.getIn([ 'api', 'http', 'webui', 'index' ])) || 'index.html')));

		addBinding(bindings, 'oxidns-cfg-api-cert', [ 'api', 'http', 'ssl', 'cert' ], 'delete');
		addBinding(bindings, 'oxidns-cfg-api-key', [ 'api', 'http', 'ssl', 'key' ], 'delete');
		addBinding(bindings, 'oxidns-cfg-api-client-ca', [ 'api', 'http', 'ssl', 'client_ca' ], 'delete');
		addBinding(bindings, 'oxidns-cfg-api-require-client-cert',
			[ 'api', 'http', 'ssl', 'require_client_cert' ], 'delete', 'boolean');

		rows.push(row(_('TLS certificate'),
			textInput('oxidns-cfg-api-cert', text(doc.getIn([ 'api', 'http', 'ssl', 'cert' ])),
				'/etc/oxidns/api.crt')));
		rows.push(row(_('TLS private key'),
			textInput('oxidns-cfg-api-key', text(doc.getIn([ 'api', 'http', 'ssl', 'key' ])),
				'/etc/oxidns/api.key')));
		rows.push(row(_('Client CA certificate'),
			textInput('oxidns-cfg-api-client-ca',
				text(doc.getIn([ 'api', 'http', 'ssl', 'client_ca' ]))),
			_('Required when client certificate verification is enabled.')));
		rows.push(row('', E('label', { 'style': 'display: inline-flex; gap: .5em; align-items: center;' }, [
			E('input', {
				'id': 'oxidns-cfg-api-require-client-cert',
				'type': 'checkbox',
				'style': 'position: static; top: auto; right: auto; margin: 0;',
				'checked': plainValue(doc, [ 'api', 'http', 'ssl', 'require_client_cert' ]) === true ? 'checked' : null
			}),
			_('Require a client certificate')
		])));

		var username = text(doc.getIn([ 'api', 'http', 'auth', 'username' ]));
		var hasPassword = text(doc.getIn([ 'api', 'http', 'auth', 'password' ])) !== '';
		var hasAuth = hasNodePath(doc, [ 'api', 'http', 'auth' ]);

		addBinding(bindings, 'oxidns-cfg-api-auth-user', [ 'api', 'http', 'auth', 'username' ], 'delete');
		addBinding(bindings, 'oxidns-cfg-api-auth-pass', [ 'api', 'http', 'auth', 'password' ], 'delete', 'secret');
		addBinding(bindings, 'oxidns-cfg-api-auth-remove', [ 'api', 'http', 'auth' ], 'delete', 'checkbox-delete');

		rows.push(row(_('Basic auth username'), textInput('oxidns-cfg-api-auth-user', username)));
		rows.push(row(_('Basic auth password'), E('input', {
			'id': 'oxidns-cfg-api-auth-pass',
			'class': 'cbi-input-text oxidns-control',
			'type': 'password',
			'value': '',
			'autocomplete': 'new-password',
			'placeholder': hasPassword
				? _('Configured; leave empty to keep the current password')
				: _('Enter a password')
		}), _('The saved password is never shown again. Fill both username and password to enable Basic authentication.')));

		if (hasAuth) {
			rows.push(row('', E('label', { 'style': 'display: inline-flex; gap: .5em; align-items: center;' }, [
				E('input', {
					'id': 'oxidns-cfg-api-auth-remove',
					'type': 'checkbox',
					'style': 'position: static; top: auto; right: auto; margin: 0;'
				}),
				_('Remove Basic authentication')
			])));
		}

		addBinding(bindings, 'oxidns-cfg-api-cors',
			[ 'api', 'http', 'cors', 'allowed_origins' ], 'delete', 'string-list');

		rows.push(row(_('CORS allowed origins'), E('textarea', {
			'id': 'oxidns-cfg-api-cors',
			'class': 'cbi-input-textarea',
			'rows': 3,
			'style': 'width: calc(100% / 3); font-family: monospace;',
			'placeholder': 'https://admin.example.com'
		}, schemaListValue(plainValue(doc, [ 'api', 'http', 'cors', 'allowed_origins' ]))),
			_('Leave empty to derive the allowed origins from the listen address. Use "*" to allow any origin.')));
	}

	return section(_('API'), null, rows);
}

/*
 * The entry field names another plugin, normally a sequence. Offer the known
 * plugin tags so a typo cannot silently break the lookup chain; an unknown
 * current value stays selectable so opening the page never rewrites it.
 */
function entrySelect(doc, id, value, placeholder) {
	var sequences = [];
	var others = [];

	pluginItems(doc).forEach(function(item, index) {
		var tag = pluginTag(item, index);

		if (tag.charAt(0) === '#')
			return;

		if (pluginType(item) === 'sequence')
			sequences.push(tag);
		else
			others.push(tag);
	});

	var options = [ E('option', { 'value': '' }, placeholder || _('Select an entry plugin')) ];

	function option(tag) {
		return E('option', {
			'value': tag,
			'selected': tag === value ? 'selected' : null
		}, tag);
	}

	sequences.forEach(function(tag) {
		options.push(option(tag));
	});

	if (others.length)
		options.push(E('optgroup', { 'label': _('Other plugins') }, others.map(option)));

	if (value && sequences.indexOf(value) === -1 && others.indexOf(value) === -1)
		options.push(E('option', { 'value': value, 'selected': 'selected' },
			_('%s (not defined)').format(value)));

	return E('select', { 'id': id, 'class': 'cbi-input-select oxidns-control' }, options);
}

function listenSection(doc, bindings) {
	var rows = [];
	var include = plainValue(doc, [ 'include' ]);
	var externalPlugins = Array.isArray(include) && include.length > 0;

	pluginItems(doc).forEach(function(item, index) {
		if (!LISTEN_SERVER_TYPES[pluginType(item)])
			return;

		var tag = pluginTag(item, index);
		var entryId = 'oxidns-cfg-entry-%d'.format(index);
		var listenId = 'oxidns-cfg-listen-%d'.format(index);
		var entryValue = text(doc.getIn([ 'plugins', index, 'args', 'entry' ]));

		addBinding(bindings, entryId, [ 'plugins', index, 'args', 'entry' ], 'delete');
		addBinding(bindings, listenId, [ 'plugins', index, 'args', 'listen' ], 'delete');

		/*
		 * Included files can define plugins this page cannot see, so a tag
		 * list would mislabel a valid entry as undefined there.
		 */
		rows.push(row(_('Entry') + ' (' + tag + ')',
			externalPlugins ? textInput(entryId, entryValue) : entrySelect(doc, entryId, entryValue),
			_('Choose the sequence that handles queries for this server.')));
		rows.push(row(_('Listen') + ' (' + tag + ')',
			textInput(listenId, text(doc.getIn([ 'plugins', index, 'args', 'listen' ])), ':5335')));
	});

	if (!rows.length)
		rows.push(noteRow(_('No UDP, TCP, or QUIC server plugins were found.')));

	return section(_('Listen Addresses'),
		_('Define which address and entry the UDP, TCP, and QUIC server plugins listen on.'), rows);
}

function upstreamButton(label, onClick, options) {
	return E('button', {
		'class': 'btn cbi-button cbi-button-neutral',
		'click': function(ev) {
			ev.preventDefault();
			options.beforeChange();
			onClick();
			options.rerender();
		}
	}, label);
}

var BOOTSTRAP_ENTRY_TAG = 'main_sequence';
var BOOTSTRAP_LISTEN = ':5335';

function uniquePluginTag(doc, base) {
	var tags = {};

	pluginItems(doc).forEach(function(item, index) {
		tags[pluginTag(item, index)] = true;
	});

	if (!tags[base])
		return base;

	for (var suffix = 2; ; suffix++) {
		var candidate = '%s_%d'.format(base, suffix);

		if (!tags[candidate])
			return candidate;
	}
}

/*
 * The getting-started button completes the first UDP and TCP server by writing
 * entry and listen into their args. A hand-written list or scalar there cannot
 * hold those keys, so refuse the click before anything is created.
 */
function bootstrapArgsProblem(doc) {
	var problem = '';

	pluginItems(doc).forEach(function(item, index) {
		var type = pluginType(item);

		if (problem || (type !== 'udp_server' && type !== 'tcp_server'))
			return;

		var args = item.get('args');

		if (args && nodeKind(args) !== 'map' && !isEmptyNode(args))
			problem = pluginTag(item, index);
	});

	return problem;
}

/*
 * Complete the first server plugin of the given type instead of adding a
 * second one; fields that are already set are left alone.
 */
function ensureBootstrapServer(doc, type, entryTag, listen) {
	var found = null;

	pluginItems(doc).forEach(function(item, index) {
		if (!found && pluginType(item) === type)
			found = item;
	});

	if (found) {
		var args = found.get('args');

		/*
		 * A hand-written list (typically "args: []") is not a mapping; only
		 * replace it when it is empty, otherwise the caller has already
		 * refused the click.
		 */
		if (args && nodeKind(args) !== 'map' && !isEmptyNode(args))
			return;

		if (!args || nodeKind(args) !== 'map') {
			found.set('args', doc.createNode({}));
			args = found.get('args');
		}

		if (!text(args.get('entry')))
			args.set('entry', doc.createNode(entryTag));

		if (!text(args.get('listen')))
			args.set('listen', doc.createNode(listen));

		return;
	}

	doc.addIn([ 'plugins' ], doc.createNode({
		'tag': uniquePluginTag(doc, type),
		'type': type,
		'args': {
			'entry': entryTag,
			'listen': listen
		}
	}));
}

function bootstrapEntrySelect(doc, id, value) {
	var options = [ E('option', { 'value': '' }, _('Create a new sequence')) ];

	Object.keys(sequenceTags(doc)).forEach(function(tag) {
		options.push(E('option', {
			'value': tag,
			'selected': tag === value ? 'selected' : null
		}, tag));
	});

	return E('select', { 'id': id, 'class': 'cbi-input-select oxidns-control' }, options);
}

/*
 * A configuration without any server entry that points at a sequence cannot
 * answer queries. Normal Mode only shows existing plugins, so offer the
 * minimal sequence plus UDP and TCP server setup here instead of sending
 * the user to Advanced Mode.
 */
function bootstrapSection(doc, options) {
	var include = plainValue(doc, [ 'include' ]);
	var external = Array.isArray(include) && include.length > 0;

	/*
	 * Included files can define the serving entry themselves, so their
	 * configurations keep the lenient check: any local entry sequence is
	 * enough to hide the card. Without includes, only a sequence that a
	 * server actually references counts.
	 */
	if (external ? entrySequences(doc).length : serverSequenceTags(doc).length)
		return null;

	var rows = [];

	if (external) {
		rows.push(noteRow(_('This configuration loads plugins from included files, so they cannot be created here. Add the entry sequence and server plugins in those files or in Advanced Mode.')));
		return section(_('Getting Started'), null, rows);
	}

	var sequences = Object.keys(sequenceTags(doc));
	var defaultEntry = sequences.indexOf(BOOTSTRAP_ENTRY_TAG) !== -1
		? BOOTSTRAP_ENTRY_TAG
		: (sequences[0] || '');
	var entryId = 'oxidns-cfg-bootstrap-entry';
	var listenId = 'oxidns-cfg-bootstrap-listen';

	rows.push(noteRow(_('No server entry points at an entry sequence yet. Create the minimal sequence and server setup below, then add upstream DNS.')));

	if (sequences.length) {
		rows.push(row(_('Entry sequence'), bootstrapEntrySelect(doc, entryId, defaultEntry),
			_('Choose an existing sequence, or leave this empty to create %s.').format(BOOTSTRAP_ENTRY_TAG)));
	}
	else {
		rows.push(noteRow(_('A new sequence named %s will be created.').format(BOOTSTRAP_ENTRY_TAG)));
	}

	rows.push(row(_('Listen address'), textInput(listenId, BOOTSTRAP_LISTEN, BOOTSTRAP_LISTEN),
		_('Both the UDP and TCP server plugins will listen on this address.')));

	rows.push(E('div', { 'class': 'tr' }, [
		E('div', {
			'class': 'td left',
			'style': 'padding: .5em var(--section-inset, 0);'
		}, [
			E('button', {
				'class': 'btn cbi-button cbi-button-positive',
				'click': function(ev) {
					ev.preventDefault();
					options.beforeChange();

					var problem = bootstrapArgsProblem(doc);

					if (problem) {
						ui.addNotification(null, E('p', {},
							_('The args of the %s plugin must be a mapping. Fix it in Advanced Mode.').format(problem)), 'danger');
						return;
					}

					if (!ensureListNode(doc, [ 'plugins' ])) {
						listShapeProblem('plugins');
						return;
					}

					var entryNode = document.getElementById(entryId);
					var listenNode = document.getElementById(listenId);
					var entryTag = entryNode && entryNode.value ? String(entryNode.value) : '';
					var listen = listenNode && listenNode.value ? String(listenNode.value) : BOOTSTRAP_LISTEN;

					if (!entryTag) {
						entryTag = uniquePluginTag(doc, BOOTSTRAP_ENTRY_TAG);

						doc.addIn([ 'plugins' ], doc.createNode({
							'tag': entryTag,
							'type': 'sequence',
							'args': []
						}));
					}

					ensureBootstrapServer(doc, 'udp_server', entryTag, listen);
					ensureBootstrapServer(doc, 'tcp_server', entryTag, listen);
					options.rerender();
				}
			}, _('Create entry sequence and servers')),
			E('div', { 'class': 'cbi-value-description', 'style': 'margin-top: .35em;' },
				_('Adds the missing plugins without changing existing ones, and wires the servers to the sequence.'))
		])
	]));

	return section(_('Getting Started'),
		_('This configuration has no server plugin that references a sequence, so it cannot answer queries yet.'),
		rows);
}

var UPSTREAM_FIELDS = [
	{ 'key': 'tag', 'type': 'text', 'label': _('Tag') },
	{ 'key': 'outbound', 'type': 'text', 'label': _('Outbound profile') },
	{ 'key': 'dial_addr', 'type': 'text', 'label': _('Dial address'), 'placeholder': '203.0.113.1' },
	{ 'key': 'port', 'type': 'number', 'label': _('Port override'), 'min': 1, 'max': 65535 },
	{ 'key': 'bootstrap', 'type': 'text', 'label': _('Bootstrap server'), 'placeholder': '8.8.8.8:53' },
	{ 'key': 'bootstrap_version', 'type': 'select', 'label': _('Bootstrap IP version'), 'values': [
		{ 'value': '4', 'label': _('IPv4') },
		{ 'value': '6', 'label': _('IPv6') }
	] },
	{ 'key': 'socks5', 'type': 'text', 'label': _('SOCKS5 proxy'), 'placeholder': '127.0.0.1:1080' },
	{ 'key': 'timeout', 'type': 'text', 'label': _('Query timeout'), 'placeholder': '5s' },
	{ 'key': 'idle_timeout', 'type': 'number', 'label': _('Idle timeout'), 'min': 0, 'placeholder': '10' },
	{ 'key': 'max_conns', 'type': 'number', 'label': _('Max connections'), 'min': 1, 'max': 4096, 'placeholder': '64' },
	{ 'key': 'min_conns', 'type': 'number', 'label': _('Min connections'), 'min': 0, 'max': 4096, 'placeholder': '0' },
	{ 'key': 'insecure_skip_verify', 'type': 'boolean', 'label': _('Skip TLS verification'),
		'help': _('Disables certificate verification for this upstream.') },
	{ 'key': 'enable_pipeline', 'type': 'boolean', 'label': _('Enable pipeline') },
	{ 'key': 'enable_http3', 'type': 'boolean', 'label': _('Enable HTTP/3') },
	{ 'key': 'so_mark', 'type': 'number', 'label': _('SO_MARK'), 'min': 0, 'max': 4294967295 },
	{ 'key': 'bind_to_device', 'type': 'text', 'label': _('Bind to device'), 'placeholder': 'eth0' }
];

function upstreamFieldPath(index, position, key) {
	return [ 'plugins', index, 'args', 'upstreams', position, key ];
}

function upstreamFieldId(index, position, key) {
	return 'oxidns-cfg-upstream-%d-%d-%s'.format(index, position, key);
}

function upstreamFieldControl(doc, index, position, field, bindings) {
	var path = upstreamFieldPath(index, position, field.key);
	var id = upstreamFieldId(index, position, field.key);
	var value = plainValue(doc, path);
	var absent = value === undefined || value === null;

	switch (field.type) {
	case 'boolean':
		addBinding(bindings, id, path, 'delete', 'boolean');
		return E('label', { 'style': 'display: inline-flex; gap: .5em; align-items: center;' }, [
			E('input', {
				'id': id,
				'type': 'checkbox',
				'style': 'position: static; top: auto; right: auto; margin: 0;',
				'checked': value === true ? 'checked' : null
			}),
			field.label
		]);

	case 'number':
		addBinding(bindings, id, path, 'delete', 'number');
		return E('input', {
			'id': id,
			'class': 'cbi-input-text oxidns-control',
			'type': 'number',
			'step': '1',
			'style': 'width: 210px; box-sizing: border-box;',
			'min': field.min !== undefined ? field.min : null,
			'max': field.max !== undefined ? field.max : null,
			'value': absent ? '' : String(value),
			'placeholder': field.placeholder || null
		});

	case 'select':
		addBinding(bindings, id, path, 'delete', 'number');
		return E('select', {
			'id': id,
			'class': 'cbi-input-select oxidns-control',
			'style': 'width: 210px; box-sizing: border-box;'
		},
			[
				E('option', { 'value': '', 'selected': absent ? 'selected' : null }, _('Default'))
			].concat(field.values.map(function(option) {
				return E('option', {
					'value': option.value,
					'selected': !absent && String(value) === option.value ? 'selected' : null
				}, option.label);
			})));

	default:
		addBinding(bindings, id, path, 'delete', 'string');
		return E('input', {
			'id': id,
			'class': 'cbi-input-text oxidns-control',
			'type': 'text',
			'style': 'width: 210px; box-sizing: border-box;',
			'value': text(value),
			'placeholder': field.placeholder || null
		});
	}
}

function upstreamAdvancedRows(doc, index, position, bindings) {
	var rows = [
		E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td left', 'style': 'width: 240px' }, ''),
			E('div', { 'class': 'td left' }, E('div', { 'class': 'cbi-value-description' },
				_('Leave fields empty to use the protocol defaults.')))
		])
	];

	UPSTREAM_FIELDS.forEach(function(field) {
		rows.push(row(
			field.type === 'boolean' ? '' : field.label,
			upstreamFieldControl(doc, index, position, field, bindings),
			field.help || null
		));
	});

	return rows;
}

/*
 * Upstreams still showing the "Select or input an upstream DNS server"
 * placeholder are not configured and must not end up in the saved file.
 */
function pruneEmptyUpstreams(doc, index) {
	var path = [ 'plugins', index, 'args', 'upstreams' ];
	var upstreams = arrayItems(doc, path);

	for (var position = upstreams.length - 1; position >= 0; position--) {
		var upstream = upstreams[position];

		if (!upstream || typeof upstream.get !== 'function' || text(upstream.get('addr')))
			continue;

		doc.deleteIn(path.concat([ position ]));
	}

	return arrayItems(doc, path);
}

/*
 * The add control is the placeholder combobox itself: picking a preset or
 * entering a custom address appends an upstream and leaves the combobox back
 * at its placeholder for the next one.
 */
function upstreamAdder(doc, index, options) {
	var node = upstreamSelect('oxidns-cfg-upstream-add-%d'.format(index), '');
	var handled = false;

	node.addEventListener('cbi-dropdown-change', function() {
		if (handled)
			return;

		var value = text(node.value).trim();

		if (!value)
			return;

		handled = true;

		// The dropdown dispatches a second change event while closing; defer
		// the rerender so it runs after the widget has finished with the node.
		window.setTimeout(function() {
			options.beforeChange();

			var path = [ 'plugins', index, 'args', 'upstreams' ];

			if (!ensureListNode(doc, path)) {
				listShapeProblem('upstreams');
				return;
			}

			doc.addIn(path, doc.createNode({ 'addr': value }));
			options.rerender();
		}, 0);
	});

	return node;
}

function upstreamSection(doc, bindings, options) {
	var rows = [];
	var found = false;

	pluginItems(doc).forEach(function(item, index) {
		if (pluginType(item) !== 'forward')
			return;

		found = true;

		var tag = pluginTag(item, index);
		var upstreams = arrayItems(doc, [ 'plugins', index, 'args', 'upstreams' ]);

		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td left', 'style': 'width: 240px' }, E('strong', {}, _('Plugin') + ': ' + tag)),
			E('div', { 'class': 'td left' }, '')
		]));

		upstreams.forEach(function(upstream, position) {
			var id = 'oxidns-cfg-upstream-%d-%d'.format(index, position);
			var address = text(doc.getIn([ 'plugins', index, 'args', 'upstreams', position, 'addr' ]));

			addBinding(bindings, id,
				[ 'plugins', index, 'args', 'upstreams', position, 'addr' ], 'delete');

			var advancedRows = upstreamAdvancedRows(doc, index, position, bindings);

			// Per-upstream options stay collapsed on load even when the
			// upstream already carries them; expand only on user request.
			advancedRows.forEach(function(advancedRow) {
				advancedRow.style.display = 'none';
			});

			var toggle = E('button', {
				'id': 'oxidns-cfg-upstream-options-toggle-%d-%d'.format(index, position),
				'class': 'btn cbi-button cbi-button-neutral',
				'click': function(ev) {
					ev.preventDefault();
					var show = advancedRows[0].style.display === 'none';
					advancedRows.forEach(function(advancedRow) {
						advancedRow.style.display = show ? '' : 'none';
					});
					toggle.textContent = show ? _('Hide options') : _('Options');
					toggle.setAttribute('aria-expanded', show ? 'true' : 'false');
				}
			}, _('Options'));
			toggle.setAttribute('aria-expanded', 'false');

			var selectNode = upstreamSelect(id, address);
			var selectHandled = false;

			// Clearing an existing upstream back to the placeholder removes it
			// rather than saving an entry with no address.
			selectNode.addEventListener('cbi-dropdown-change', function() {
				if (selectHandled || text(selectNode.value).trim())
					return;

				selectHandled = true;

				window.setTimeout(function() {
					options.beforeChange();
					pruneEmptyUpstreams(doc, index);
					options.rerender();
				}, 0);
			});

			rows.push(row(_('Upstream address') + ' ' + (position + 1),
				E('div', { 'style': 'display: flex; gap: .5em; align-items: center; justify-content: flex-start; width: 100%; flex-wrap: wrap;' }, [
					E('div', { 'style': 'flex: 0 0 210px; width: 210px; min-width: 0;' }, [
						selectNode
					]),
					toggle,
					upstreamButton(_('Remove'), function() {
						doc.deleteIn([ 'plugins', index, 'args', 'upstreams', position ]);
					}, options)
				])));

			advancedRows.forEach(function(advancedRow) {
				rows.push(advancedRow);
			});
		});

		if (!upstreams.length)
			rows.push(noteRow(_('No upstream servers configured.')));

		rows.push(row(_('Add upstream DNS'), E('div', {
			'style': 'flex: 0 0 210px; width: 210px; min-width: 0;'
		}, [ upstreamAdder(doc, index, options) ])));
	});

	/*
	 * Without a forward plugin every sequence ends without an upstream, so
	 * offer to create one instead of only reporting the gap.
	 */
	if (!found) {
		var existing = findPluginByTag(doc, FORWARD_TAG);

		if (existing) {
			rows.push(noteRow(_('The tag %s is already used by a %s plugin. Rename it in Advanced Mode to create a forward plugin.')
				.format(FORWARD_TAG, pluginType(existing.item) || _('unknown'))));
		}
		else {
			var canCreate = entrySequences(doc).length > 0;

			rows.push(E('div', { 'class': 'tr' }, [
				E('div', {
					'class': 'td left',
					'style': 'padding: .5em var(--section-inset, 0);'
				}, [
					E('button', {
						'class': 'btn cbi-button cbi-button-positive',
						'disabled': canCreate ? null : 'disabled',
						'click': function(ev) {
							ev.preventDefault();
							options.beforeChange();

							var targets = entrySequences(doc);

							if (!targets.length) {
								ui.addNotification(null, E('p', {},
									_('No entry sequence was found. Configure a server entry in Advanced Mode first.')), 'danger');
								return;
							}

							if (!ensureListNode(doc, [ 'plugins' ])) {
								listShapeProblem('plugins');
								return;
							}

							doc.addIn([ 'plugins' ], doc.createNode({
								'tag': FORWARD_TAG,
								'type': FORWARD_TYPE,
								'args': {}
							}));

							ensureForwardWiring(doc, FORWARD_TAG, targets);
							options.rerender();
						}
					}, _('Create forward plugin')),
					E('div', { 'class': 'cbi-value-description', 'style': 'margin-top: .35em;' },
						canCreate
							? _('Adds a forward plugin and runs it at the end of the entry sequence. Add at least one upstream DNS server below.')
							: _('No entry sequence was found. Configure a server entry in Advanced Mode first.'))
				])
			]));
		}
	}

	return section(_('Upstream DNS'),
		_('Queries are forwarded to these upstream servers.') + ' ' +
		_('Use Options to set per-upstream connection details.'),
		rows, 'table-layout: fixed;');
}

function adFilterTextarea(id, value, placeholder) {
	return E('textarea', {
		'id': id,
		'class': 'cbi-input-textarea',
		'rows': 3,
		'style': 'width: calc(100% / 3); font-family: monospace;',
		'placeholder': placeholder || null,
		'spellcheck': 'false'
	}, value || '');
}

function adFilterModeSelect(id, value) {
	var modes = adfilter.modes.slice();
	if (value && modes.indexOf(value) === -1)
		modes.push(value);

	return E('select', { 'id': id, 'class': 'cbi-input-select oxidns-control' },
		modes.map(function(mode) {
			return E('option', {
				'value': mode,
				'selected': mode === value ? 'selected' : null
			}, mode);
		}));
}

/*
 * Guided ad filtering manages a fixed plugin group (download, adguard_rule,
 * black_hole) and the sequence rule that wires it in. The group is edited
 * through a single custom binding so the plugins are updated together.
 */
function adFilterSection(doc, options) {
	var state = adfilter.inspect(doc);
	var values = state.values;
	var rows = [];
	var binding = null;

	if (state.problems.length) {
		state.problems.forEach(function(problem) {
			rows.push(noteRow(problem));
		});

		return {
			'node': section(_('Ad filtering'), null, rows),
			'binding': null
		};
	}

	if (!state.configured) {
		var canEnable = state.targets.length > 0;

		rows.push(E('div', { 'class': 'tr' }, [
			E('div', {
				'class': 'td left',
				'style': 'padding: .5em var(--section-inset, 0);'
			}, [
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'disabled': canEnable ? null : 'disabled',
					'click': function(ev) {
						ev.preventDefault();
						options.beforeChange();

						var result = adfilter.enable(doc);

						if (!result.ok) {
							ui.addNotification(null, E('p', {}, result.problems.join(' ')), 'danger');
							return;
						}

						options.rerender();
					}
				}, _('Add ad filtering')),
				E('div', { 'class': 'cbi-value-description', 'style': 'margin-top: .35em;' },
					canEnable
						? _('Adds AdGuard rules and blocking plugins, then inserts the blocking rule at the start of the entry sequence. The subscription download plugin is added when you enter subscription URLs.')
						: _('No entry sequence was found. Configure a server entry in Advanced Mode first.'))
			])
		]));

		return {
			'node': section(_('Ad filtering'),
				_('Ad filtering downloads subscription rules at startup, matches them with AdGuard rules, and answers matching queries locally.'),
				rows),
			'binding': null
		};
	}

	rows.push(row(_('Subscription URLs'),
		adFilterTextarea('oxidns-cfg-ad-urls', values.urlsText, 'https://example.com/adblock.txt'),
		_('One http:// or https:// URL per line. Missing files are downloaded when OxiDNS starts; a failed download prevents startup.')));

	rows.push(row(_('Inline rules'),
		adFilterTextarea('oxidns-cfg-ad-rules', values.rulesText, '||ads.example.com^'),
		_('One AdGuard rule per line.')));

	rows.push(row(_('Local rule files'),
		adFilterTextarea('oxidns-cfg-ad-files', values.filesText, '/etc/oxidns/rules/local.txt'),
		_('One absolute path per line. Files are read directly by OxiDNS.')));

	rows.push(row(_('Blocking mode'), adFilterModeSelect('oxidns-cfg-ad-mode', values.mode)));

	rows.push(row(_('Blocking addresses'),
		textInput('oxidns-cfg-ad-ips', values.ipsText, '0.0.0.0 ::'),
		_('Used by custom mode. Separate IPv4 and IPv6 addresses with commas or spaces.')));

	rows.push(row(_('Rules directory'),
		textInput('oxidns-cfg-ad-dir', values.dir, '/etc/oxidns/rules'),
		_('Downloaded subscription files are stored in this directory.')));

	binding = {
		'kind': 'custom',
		'apply': function() {
			var urls = document.getElementById('oxidns-cfg-ad-urls');
			var rules = document.getElementById('oxidns-cfg-ad-rules');
			var files = document.getElementById('oxidns-cfg-ad-files');
			var mode = document.getElementById('oxidns-cfg-ad-mode');
			var ips = document.getElementById('oxidns-cfg-ad-ips');
			var dir = document.getElementById('oxidns-cfg-ad-dir');

			if (!urls || !rules || !files || !mode || !ips || !dir)
				return;

			adfilter.syncIfChanged(doc, {
				'urlsText': urls.value,
				'rulesText': rules.value,
				'filesText': files.value,
				'mode': mode.value,
				'ipsText': ips.value,
				'dir': dir.value
			});
		}
	};

	var footer = E('div', {
		'class': 'cbi-button-row',
		'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: .75em; padding-inline: var(--section-inset, 0);'
	}, [
		E('button', {
			'class': 'btn cbi-button cbi-button-neutral',
			'click': function(ev) {
				ev.preventDefault();

				if (!window.confirm(_('Remove the subscription download plugin? Subscription downloads stop and the plugin with all of its download options is removed. The ad filtering rules and downloaded files on disk stay.')))
					return;

				options.beforeChange();
				adfilter.removeDownload(doc);
				options.rerender();
			}
		}, _('Remove subscription downloads')),
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': function(ev) {
				ev.preventDefault();

				if (!window.confirm(_('Remove the ad filtering configuration?')))
					return;

				options.beforeChange();
				adfilter.disable(doc);
				options.rerender();
			}
		}, _('Remove ad filtering'))
	]);

	return {
		'node': section(_('Ad filtering'),
			_('Ad filtering downloads subscription rules at startup, matches them with AdGuard rules, and answers matching queries locally.'),
			rows, null, footer),
		'binding': binding
	};
}

/*
 * Guided cache and hosts each manage one fixed plugin and its sequence step.
 * The plugin options come from the configuration schema, so enabling either
 * card exposes the same fields as Advanced Mode.
 */
var CACHE_TAG = 'oxidns_cache';
var CACHE_TYPE = 'cache';
var HOSTS_TAG = 'oxidns_hosts';
var HOSTS_TYPE = 'hosts';
var FORWARD_TAG = 'forward';
var FORWARD_TYPE = 'forward';
var ENTRY_SERVER_TYPES = { udp_server: true, tcp_server: true, quic_server: true };

function findPluginByTag(doc, tag) {
	var items = pluginItems(doc);

	for (var i = 0; i < items.length; i++) {
		if (pluginTag(items[i], i) === tag)
			return { 'item': items[i], 'index': i };
	}

	return null;
}

function sequenceTags(doc) {
	var tags = {};

	pluginItems(doc).forEach(function(item, index) {
		if (pluginType(item) !== 'sequence')
			return;

		var tag = pluginTag(item, index);
		if (tag.charAt(0) !== '#')
			tags[tag] = true;
	});

	return tags;
}

function serverEntryTags(doc) {
	var entries = [];

	pluginItems(doc).forEach(function(item) {
		var type = pluginType(item);
		var args = item && typeof item.get === 'function' ? item.get('args') : null;

		if (!args || typeof args.get !== 'function')
			return;

		if (type === 'http_server') {
			var list = args.get('entries');

			if (list && Array.isArray(list.items))
				list.items.forEach(function(entry) {
					if (entry && typeof entry.get === 'function')
						entries.push(text(entry.get('exec')));
				});
		}
		else if (ENTRY_SERVER_TYPES[type]) {
			entries.push(text(args.get('entry')));
		}
	});

	return entries;
}

/*
 * Sequences that a server plugin actually uses as its entry point. A
 * sequence nothing points at cannot answer queries, so it is not an entry
 * sequence even when it is the only one in the file.
 */
function serverSequenceTags(doc) {
	var known = sequenceTags(doc);
	var result = [];

	serverEntryTags(doc).forEach(function(tag) {
		if (tag && known[tag] && result.indexOf(tag) === -1)
			result.push(tag);
	});

	return result;
}

function entrySequences(doc) {
	var known = sequenceTags(doc);
	var result = serverSequenceTags(doc);

	if (result.length)
		return result;

	if (known.main_sequence)
		return [ 'main_sequence' ];

	var all = Object.keys(known);
	return all.length === 1 ? all : [];
}

function sequenceStepExec(step) {
	return step && typeof step.get === 'function' ? text(step.get('exec')) : '';
}

function sequenceArgs(doc, tag) {
	var found = findPluginByTag(doc, tag);

	if (!found || pluginType(found.item) !== 'sequence')
		return null;

	var args = found.item.get('args');
	return args && nodeKind(args) === 'seq' ? args : null;
}

function managedStep(step, tag) {
	return sequenceStepExec(step) === '$' + tag;
}

function ensureStepWiring(doc, tag, targets, predecessors) {
	var anchors = {};

	(predecessors || []).forEach(function(predecessor) {
		anchors['$' + predecessor] = true;
	});

	(targets || []).forEach(function(sequenceTag) {
		var args = sequenceArgs(doc, sequenceTag);

		if (!args)
			return;

		var found = -1;

		for (var i = args.items.length - 1; i >= 0; i--) {
			if (!managedStep(args.items[i], tag))
				continue;

			if (found !== -1)
				args.items.splice(i, 1);
			else
				found = i;
		}

		if (found !== -1)
			return;

		/*
		 * Keep managed steps in a fixed order: ad filtering, hosts, cache,
		 * all ahead of forward. Blocked names are never answered from hosts
		 * or the cache, and cached responses never mask host entries.
		 */
		var position = 0;

		for (var j = 0; j < args.items.length; j++) {
			if (anchors[sequenceStepExec(args.items[j])])
				position = j + 1;
		}

		args.items.splice(position, 0, doc.createNode({ 'exec': '$' + tag }));
	});
}

/*
 * The forward step runs after the managed ad, hosts, and cache steps and
 * before a trailing accept, which ends the sequence with the forwarded reply.
 */
function ensureForwardWiring(doc, tag, targets) {
	(targets || []).forEach(function(sequenceTag) {
		var args = sequenceArgs(doc, sequenceTag);

		if (!args)
			return;

		if (args.items.some(function(step) { return managedStep(step, tag); }))
			return;

		var last = args.items.length - 1;
		var position = last >= 0 && sequenceStepExec(args.items[last]) === 'accept'
			? last
			: args.items.length;

		args.items.splice(position, 0, doc.createNode({ 'exec': '$' + tag }));
	});
}

function removeStepWiring(doc, tag) {
	pluginItems(doc).forEach(function(item) {
		if (pluginType(item) !== 'sequence')
			return;

		var args = item.get('args');

		if (!args || nodeKind(args) !== 'seq')
			return;

		for (var i = args.items.length - 1; i >= 0; i--) {
			if (managedStep(args.items[i], tag))
				args.items.splice(i, 1);
		}
	});
}

function stepWiringMissing(doc, tag, targets) {
	return (targets || []).filter(function(sequenceTag) {
		var args = sequenceArgs(doc, sequenceTag);
		return !args || !args.items.some(function(step) { return managedStep(step, tag); });
	});
}

function cacheSection(doc, bindings, options) {
	var definitions = schemaDefinitions(options);
	var definition = definitions ? definitions[CACHE_TYPE] : null;
	var managed = findPluginByTag(doc, CACHE_TAG);
	var other = null;

	pluginItems(doc).forEach(function(item, index) {
		if (pluginType(item) !== CACHE_TYPE || (managed && index === managed.index))
			return;

		if (!other)
			other = { 'item': item, 'index': index };
	});

	if (managed && pluginType(managed.item) !== CACHE_TYPE) {
		return {
			'node': section(_('Cache'), null, [
				noteRow(_('The tag %s is already used by a %s plugin. Rename it in Advanced Mode before enabling cache.')
					.format(CACHE_TAG, pluginType(managed.item) || _('unknown')))
			])
		};
	}

	if (!managed) {
		if (other) {
			var otherTag = pluginTag(other.item, other.index);
			var otherEditable = !!(definition && Array.isArray(definition.fields) && definition.fields.length);

			return {
				'node': section(_('Cache'), null, [
					noteRow(otherEditable
						? _('Cache is configured by the %s plugin. Edit that plugin\'s settings below.').format(otherTag)
						: _('Cache is configured by the %s plugin. Edit it in Advanced Mode.').format(otherTag))
				])
			};
		}

		var canEnable = entrySequences(doc).length > 0;
		var enableRow = E('div', { 'class': 'tr' }, [
			E('div', {
				'class': 'td left',
				'style': 'padding: .5em var(--section-inset, 0);'
			}, [
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'disabled': canEnable ? null : 'disabled',
					'click': function(ev) {
						ev.preventDefault();
						options.beforeChange();

						var targets = entrySequences(doc);

						if (!targets.length) {
							ui.addNotification(null, E('p', {},
								_('No entry sequence was found. Configure a server entry in Advanced Mode first.')), 'danger');
							return;
						}

						if (!findPluginByTag(doc, CACHE_TAG)) {
							if (!ensureListNode(doc, [ 'plugins' ])) {
								listShapeProblem('plugins');
								return;
							}

							doc.addIn([ 'plugins' ], doc.createNode({
								'tag': CACHE_TAG,
								'type': CACHE_TYPE,
								'args': { 'short_circuit': true }
							}));
						}

						ensureStepWiring(doc, CACHE_TAG, targets,
							[ adfilter.tags.block, HOSTS_TAG ]);
						options.rerender();
					}
				}, _('Enable cache')),
				E('div', { 'class': 'cbi-value-description', 'style': 'margin-top: .35em;' },
					canEnable
						? _('Adds a cache plugin and runs it before forwarding in the entry sequence. Cached responses answer repeated queries without contacting upstream servers.')
						: _('No entry sequence was found. Configure a server entry in Advanced Mode first.'))
			])
		]);

		return {
			'node': section(_('Cache'),
				_('Cache stores DNS responses locally so repeated queries are answered without contacting upstream servers.'),
				[ enableRow ])
		};
	}

	var rows = [];

	(definition && Array.isArray(definition.fields) ? definition.fields : []).forEach(function(field, fieldIndex) {
		if (!field || !Array.isArray(field.path) || !field.path.length)
			return;

		rows.push(row(
			field.type === 'boolean' ? '' : _(text(field.label) || field.path.join('.')),
			schemaControl(doc, managed.index, fieldIndex, field, bindings, null, null, options),
			field.help ? _(field.help) : null
		));
	});

	if (!rows.length)
		rows.push(noteRow(_('No cache options are available in the configuration schema.')));

	var footer = E('div', {
		'class': 'cbi-button-row',
		'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: .75em; padding-inline: var(--section-inset, 0);'
	}, [
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': function(ev) {
				ev.preventDefault();

				if (!window.confirm(_('Remove the cache plugin? Cached responses are discarded and the cache step is removed from the entry sequence.')))
					return;

				options.beforeChange();
				removeStepWiring(doc, CACHE_TAG);
				doc.deleteIn([ 'plugins', managed.index ]);
				options.rerender();
			}
		}, _('Remove cache'))
	]);

	return {
		'node': section(_('Cache'),
			_('Cache stores DNS responses locally so repeated queries are answered without contacting upstream servers.'),
			rows, null, footer)
	};
}

/*
 * Guided hosts manages one fixed hosts plugin and its sequence step, so local
 * name records can be added without opening Advanced Mode.
 */
function hostsSection(doc, bindings, options) {
	var definitions = schemaDefinitions(options);
	var definition = definitions ? definitions[HOSTS_TYPE] : null;
	var managed = findPluginByTag(doc, HOSTS_TAG);
	var other = null;

	pluginItems(doc).forEach(function(item, index) {
		if (pluginType(item) !== HOSTS_TYPE || (managed && index === managed.index))
			return;

		if (!other)
			other = { 'item': item, 'index': index };
	});

	if (managed && pluginType(managed.item) !== HOSTS_TYPE) {
		return {
			'node': section(_('Hosts'), null, [
				noteRow(_('The tag %s is already used by a %s plugin. Rename it in Advanced Mode before enabling hosts.')
					.format(HOSTS_TAG, pluginType(managed.item) || _('unknown')))
			])
		};
	}

	if (!managed) {
		if (other) {
			var otherTag = pluginTag(other.item, other.index);
			var otherEditable = !!(definition && Array.isArray(definition.fields) && definition.fields.length);

			return {
				'node': section(_('Hosts'), null, [
					noteRow(otherEditable
						? _('Hosts is configured by the %s plugin. Edit that plugin\'s settings below.').format(otherTag)
						: _('Hosts is configured by the %s plugin. Edit it in Advanced Mode.').format(otherTag))
				])
			};
		}

		var canEnable = entrySequences(doc).length > 0;
		var enableRow = E('div', { 'class': 'tr' }, [
			E('div', {
				'class': 'td left',
				'style': 'padding: .5em var(--section-inset, 0);'
			}, [
				E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'disabled': canEnable ? null : 'disabled',
					'click': function(ev) {
						ev.preventDefault();
						options.beforeChange();

						var targets = entrySequences(doc);

						if (!targets.length) {
							ui.addNotification(null, E('p', {},
								_('No entry sequence was found. Configure a server entry in Advanced Mode first.')), 'danger');
							return;
						}

						if (!findPluginByTag(doc, HOSTS_TAG)) {
							if (!ensureListNode(doc, [ 'plugins' ])) {
								listShapeProblem('plugins');
								return;
							}

							doc.addIn([ 'plugins' ], doc.createNode({
								'tag': HOSTS_TAG,
								'type': HOSTS_TYPE,
								'args': { 'short_circuit': true }
							}));
						}

						ensureStepWiring(doc, HOSTS_TAG, targets, [ adfilter.tags.block ]);
						options.rerender();
					}
				}, _('Enable hosts')),
				E('div', { 'class': 'cbi-value-description', 'style': 'margin-top: .35em;' },
					canEnable
						? _('Adds a hosts plugin and runs it before forwarding in the entry sequence. Configured names are answered locally and everything else is forwarded.')
						: _('No entry sequence was found. Configure a server entry in Advanced Mode first.'))
			])
		]);

		return {
			'node': section(_('Hosts'),
				_('Hosts answers configured names locally, for example to map a domain to a LAN address.'),
				[ enableRow ])
		};
	}

	var rows = [];

	(definition && Array.isArray(definition.fields) ? definition.fields : []).forEach(function(field, fieldIndex) {
		if (!field || !Array.isArray(field.path) || !field.path.length)
			return;

		rows.push(row(
			field.type === 'boolean' ? '' : _(text(field.label) || field.path.join('.')),
			schemaControl(doc, managed.index, fieldIndex, field, bindings, null, null, options),
			field.help ? _(field.help) : null
		));
	});

	if (!rows.length)
		rows.push(noteRow(_('No hosts options are available in the configuration schema.')));

	var footer = E('div', {
		'class': 'cbi-button-row',
		'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: .75em; padding-inline: var(--section-inset, 0);'
	}, [
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': function(ev) {
				ev.preventDefault();

				if (!window.confirm(_('Remove the hosts plugin? Local name mappings are discarded and the hosts step is removed from the entry sequence.')))
					return;

				options.beforeChange();
				removeStepWiring(doc, HOSTS_TAG);
				doc.deleteIn([ 'plugins', managed.index ]);
				options.rerender();
			}
		}, _('Remove hosts'))
	]);

	return {
		'node': section(_('Hosts'),
			_('Hosts answers configured names locally, for example to map a domain to a LAN address.'),
			rows, null, footer)
	};
}

function schemaDefinitions(options) {
	var schema = options && options.schema;
	var plugins = schema && schema.plugins;

	return plugins && typeof plugins === 'object' ? plugins : null;
}

function plainValue(doc, path) {
	var value = doc.getIn(path, true);

	if (value && typeof value.toJSON === 'function')
		value = value.toJSON();

	return value;
}

function schemaFieldId(pluginIndex, fieldIndex) {
	return 'oxidns-cfg-p%d-f%d'.format(pluginIndex, fieldIndex);
}

function schemaEnumValues(field) {
	return (Array.isArray(field.values) ? field.values : []).map(function(entry) {
		if (entry && typeof entry === 'object') {
			var entryValue = entry.value === undefined ? '' : String(entry.value);
			return {
				'value': entryValue,
				'label': _(text(entry.label) || entryValue)
			};
		}

		return {
			'value': String(entry),
			'label': String(entry)
		};
	});
}

function schemaEnumSelect(field, id, value) {
	var options = [
		E('option', {
			'value': '',
			'selected': value ? null : 'selected'
		}, _(text(field.placeholder) || _('Default')))
	];
	var matched = !value;

	schemaEnumValues(field).forEach(function(entry) {
		if (entry.value === value)
			matched = true;

		options.push(E('option', {
			'value': entry.value,
			'selected': entry.value === value ? 'selected' : null
		}, entry.label));
	});

	if (!matched)
		options.push(E('option', { 'value': value, 'selected': 'selected' }, value));

	return E('select', { 'id': id, 'class': 'cbi-input-select oxidns-control' }, options);
}

function schemaListValue(value) {
	if (Array.isArray(value))
		return value.map(function(entry) {
			return text(entry);
		}).join('\n');

	return typeof value === 'string' ? value : '';
}

function schemaObjectList(doc, field, bindings, path, id, options) {
	var items = arrayItems(doc, path);
	var itemLabel = _(text(field.item_label) || text(field.label) || _('Item'));
	var container = E('div', { 'style': 'display: flex; flex-direction: column; gap: .75em;' });

	items.forEach(function(item, position) {
		var itemPath = path.concat([ position ]);
		var itemRows = [];

		(field.fields || []).forEach(function(subfield, subIndex) {
			if (!subfield || !Array.isArray(subfield.path) || !subfield.path.length)
				return;

			itemRows.push(row(
				subfield.type === 'boolean' ? '' : _(text(subfield.label) || subfield.path.join('.')),
				schemaControl(doc, 0, subIndex, subfield, bindings, itemPath,
					id + '-i' + position, options),
				subfield.help ? _(subfield.help) : null
			));
		});

		container.appendChild(E('div', {
			'class': 'cbi-section',
			'style': 'border: 1px solid rgba(127,127,127,.35); border-radius: 4px; padding: .5em .75em;'
		}, [
			E('div', { 'style': 'display: flex; align-items: center; justify-content: space-between; gap: .5em;' }, [
				E('strong', {}, itemLabel + ' ' + (position + 1)),
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': function(ev) {
						ev.preventDefault();
						options.beforeChange();
						doc.deleteIn(itemPath);
						options.rerender();
					}
				}, _('Remove'))
			]),
			E('div', { 'class': 'table cbi-section-table' }, itemRows)
		]));
	});

	if (!items.length)
		container.appendChild(E('div', { 'class': 'cbi-value-description' },
			_('No entries configured.')));

	container.appendChild(E('button', {
		'class': 'btn cbi-button cbi-button-add',
		'click': function(ev) {
			ev.preventDefault();
			options.beforeChange();

			if (!ensureListNode(doc, path)) {
				listShapeProblem(String(path[path.length - 1]));
				return;
			}

			doc.addIn(path, doc.createNode({}));
			options.rerender();
		}
	}, _('Add entry')));

	return container;
}

function schemaControl(doc, index, fieldIndex, field, bindings, basePath, idPrefix, options) {
	var path = (basePath || [ 'plugins', index, 'args' ]).concat(field.path);
	var id = idPrefix ? idPrefix + '-f' + fieldIndex : schemaFieldId(index, fieldIndex);
	var value = plainValue(doc, path);
	var empty = field.empty === 'set' ? 'set' : 'delete';
	var absent = value === undefined || value === null;
	var defaultValue = field['default'];
	var display = absent && defaultValue !== undefined ? defaultValue : value;
	var displayText = display === undefined || display === null ? '' : String(display);

	switch (field.type) {
	case 'boolean':
		addBinding(bindings, id, path, empty, 'boolean', defaultValue);
		return E('label', { 'style': 'display: inline-flex; gap: .5em; align-items: center;' }, [
			E('input', {
				'id': id,
				'type': 'checkbox',
				'style': 'position: static; top: auto; right: auto; margin: 0;',
				'checked': (absent ? defaultValue === true : value === true) ? 'checked' : null
			}),
			_(text(field.label))
		]);

	case 'integer':
	case 'number':
		addBinding(bindings, id, path, empty, 'number', defaultValue);
		return E('input', {
			'id': id,
			'class': 'cbi-input-text oxidns-control',
			'type': 'number',
			'step': field.type === 'integer' ? '1' : 'any',
			'min': field.min !== undefined ? field.min : null,
			'max': field.max !== undefined ? field.max : null,
			'value': displayText,
			'placeholder': text(field.placeholder) || null
		});

	case 'enum':
		addBinding(bindings, id, path, empty, 'string', defaultValue);
		return schemaEnumSelect(field, id, displayText);

	case 'string-list':
		addBinding(bindings, id, path, empty, 'string-list', defaultValue);
		return E('textarea', {
			'id': id,
			'class': 'cbi-input-textarea',
			'rows': field.rows || 4,
			'style': 'width: ' + (text(field.width) || '100%') + '; font-family: monospace;',
			'placeholder': text(field.placeholder) || null
		}, schemaListValue(display));

	case 'object-list':
		return schemaObjectList(doc, field, bindings, path, id, options);

	case 'plugin-tag': {
		addBinding(bindings, id, path, empty, 'string', defaultValue);

		/*
		 * Included files can define plugins this page cannot see, so a tag
		 * list would mislabel a valid reference as undefined there.
		 */
		var includeFiles = plainValue(doc, [ 'include' ]);

		if (Array.isArray(includeFiles) && includeFiles.length)
			return textInput(id, displayText, text(field.placeholder));

		return entrySelect(doc, id, displayText, text(field.placeholder) || _('Select an entry executor'));
	}

	default:
		addBinding(bindings, id, path, empty, 'string', defaultValue);
		return textInput(id, displayText, text(field.placeholder));
	}
}

function schemaSections(doc, bindings, options) {
	var definitions = schemaDefinitions(options);
	var sections = [];

	if (!definitions)
		return sections;

	pluginItems(doc).forEach(function(item, index) {
		var type = pluginType(item);
		var tag = pluginTag(item, index);

		// The guided ad filtering group has its own section.
		if (adfilter.manages(tag, type))
			return;

		// The guided cache and hosts plugins have their own sections.
		if ((type === CACHE_TYPE && tag === CACHE_TAG) ||
		    (type === HOSTS_TYPE && tag === HOSTS_TAG))
			return;

		var definition = definitions[type];

		if (!definition || !Array.isArray(definition.fields))
			return;

		var rows = [];

		definition.fields.forEach(function(field, fieldIndex) {
			if (!field || !Array.isArray(field.path) || !field.path.length)
				return;

			rows.push(row(
				field.type === 'boolean' ? '' : _(text(field.label) || field.path.join('.')),
				schemaControl(doc, index, fieldIndex, field, bindings, null, null, options),
				field.help ? _(field.help) : null
			));
		});

		if (!rows.length)
			return;

		sections.push(section(
			_(text(definition.title) || type) + ' (' + pluginTag(item, index) + ')',
			definition.description ? _(definition.description) : null,
			rows
		));
	});

	return sections;
}

function argsSummary(item) {
	if (!item || typeof item.get !== 'function')
		return '-';

	var args = item.get('args');

	if (args && typeof args.toJSON === 'function')
		args = args.toJSON();

	if (Array.isArray(args))
		return _('%d step(s)').format(args.length);

	if (args && typeof args === 'object') {
		var keys = Object.keys(args);
		return keys.length ? keys.join(', ') : '-';
	}

	return '-';
}

var PLUGIN_TYPE_CATEGORIES = [ 'servers', 'executors', 'matchers', 'providers' ];

function pluginTypeSupport(pluginTypes) {
	var plugins = pluginTypes && pluginTypes.plugins;

	if (!plugins || typeof plugins !== 'object')
		return null;

	var supported = {};

	PLUGIN_TYPE_CATEGORIES.forEach(function(category) {
		var list = plugins[category];

		if (!Array.isArray(list))
			return;

		list.forEach(function(type) {
			supported[text(type)] = true;
		});
	});

	return {
		'supported': supported,
		'core': text(pluginTypes.source) === 'core'
	};
}

function pluginTypeStatus(type, support) {
	if (!type)
		return '-';

	if (support.supported[type])
		return E('span', { 'style': 'color: var(--success-color-high, #2e7d32);' }, _('Supported'));

	return E('span', { 'style': 'color: var(--danger-color-high, #b71c1c);' },
		support.core ? _('Not supported by this core') : _('Unknown plugin type'));
}

function pluginSection(doc, options) {
	var support = pluginTypeSupport(options && options.pluginTypes);
	var rows = [
		E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td left', 'style': 'width: 240px' }, E('strong', {}, _('Tag'))),
			E('div', { 'class': 'td left', 'style': 'width: 160px' }, E('strong', {}, _('Type'))),
			E('div', { 'class': 'td left' }, E('strong', {}, _('Arguments'))),
			support ? E('div', { 'class': 'td left', 'style': 'width: 200px' }, E('strong', {}, _('Status'))) : ''
		])
	];

	var items = pluginItems(doc);

	items.forEach(function(item, index) {
		var type = pluginType(item);

		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td left' }, pluginTag(item, index)),
			E('div', { 'class': 'td left' }, type || '-'),
			E('div', { 'class': 'td left' }, argsSummary(item)),
			support ? E('div', { 'class': 'td left' }, pluginTypeStatus(type, support)) : ''
		]));
	});

	if (!items.length)
		rows.push(noteRow(pluginsShapeProblem(doc)
			? _('The %s field must be a list. Fix it in Advanced Mode.').format('plugins')
			: _('No plugins are configured.')));

	var description = _('Normal mode covers common settings only. Use Advanced Mode to edit plugins and options not listed here.');

	if (support)
		description += ' ' + (support.core
			? _('Plugin types are read from the installed OxiDNS core.')
			: _('The OxiDNS core is not installed, so plugin types come from the built-in catalog.'));

	return section(_('Plugins'), description, rows);
}

var SERVER_PLUGIN_TYPES = {
	'udp_server': true,
	'tcp_server': true,
	'quic_server': true,
	'http_server': true
};

function isEmptyValue(value) {
	return value === undefined || value === null || value === '' ||
		(Array.isArray(value) && !value.length);
}

function schemaFieldProblems(doc, basePath, fields, pluginTitle, tag, problems) {
	(fields || []).forEach(function(field) {
		if (!field || !Array.isArray(field.path) || !field.path.length)
			return;

		var path = basePath.concat(field.path);
		var value = plainValue(doc, path);
		var label = _(text(field.label) || field.path.join('.'));

		/*
		 * A required nested field only applies when its containing object
		 * exists. Optional objects such as nftset ipv4/ipv6 may be omitted
		 * entirely, but inside an object the core requires the named fields.
		 */
		var parentPresent = field.path.length < 2 || hasNodePath(doc, path.slice(0, -1));

		if (field.required && parentPresent && isEmptyValue(value))
			problems.push(_('The %s plugin %s requires the %s field.')
				.format(pluginTitle, tag, label));

		if (field.type === 'object-list') {
			var items = Array.isArray(value) ? value : [];

			items.forEach(function(item, position) {
				schemaFieldProblems(doc, path.concat([ position ]), field.fields,
					pluginTitle, tag, problems);
			});
			return;
		}

		if (isEmptyValue(value))
			return;

		if (field.type === 'integer' || field.type === 'number') {
			var number = Number(value);

			if (!isFinite(number) ||
			    (field.min !== undefined && number < field.min) ||
			    (field.max !== undefined && number > field.max))
				problems.push(_('The %s plugin %s has an invalid value for %s.')
					.format(pluginTitle, tag, label));
			return;
		}

		if (field.type === 'enum' && Array.isArray(field.values)) {
			var allowed = field.values.map(function(entry) {
				return entry && typeof entry === 'object' ? String(entry.value) : String(entry);
			});

			if (allowed.indexOf(String(value)) === -1)
				problems.push(_('The %s plugin %s has an invalid value for %s.')
					.format(pluginTitle, tag, label));
		}
	});
}

function validateConfig(doc, options) {
	var problems = [];
	var definitions = schemaDefinitions(options) || {};
	var includeValue = plainValue(doc, [ 'include' ]);
	var externalPlugins = Array.isArray(includeValue) && includeValue.length > 0;
	var knownTags = {};
	var seenTags = {};

	pluginItems(doc).forEach(function(item) {
		var tag = text(item && typeof item.get === 'function' ? item.get('tag') : '');

		if (!tag)
			return;

		if (seenTags[tag])
			problems.push(_('The plugin tag %s is used by more than one plugin. Choose a unique tag in Advanced Mode.').format(tag));

		seenTags[tag] = true;
		knownTags[tag] = true;
	});

	pluginItems(doc).forEach(function(item, index) {
		var type = pluginType(item);
		var tag = pluginTag(item, index);
		var argsPath = [ 'plugins', index, 'args' ];

		var definition = definitions[type];

		if (definition && Array.isArray(definition.fields))
			schemaFieldProblems(doc, argsPath, definition.fields,
				_(text(definition.title) || type), tag, problems);

		/*
		 * Sequence steps reference plugins by tag. Included files can define
		 * plugins this page cannot see, so only resolve tags without them.
		 */
		if (type === 'sequence' && !externalPlugins) {
			var steps = plainValue(doc, argsPath);

			(Array.isArray(steps) ? steps : []).forEach(function(step, position) {
				var exec = text(step && step.exec);

				if (exec.charAt(0) === '$' && !knownTags[exec.slice(1)])
					problems.push(_('Step %d of the sequence plugin %s references the missing plugin %s.')
						.format(position + 1, tag, exec.slice(1)));

				var matches = text(step && step.matches);
				var referencePattern = /\$([A-Za-z0-9_.-]+)/g;
				var match;

				while ((match = referencePattern.exec(matches)) !== null) {
					if (!knownTags[match[1]])
						problems.push(_('The matches of step %d of the sequence plugin %s reference the missing plugin %s.')
							.format(position + 1, tag, match[1]));
				}
			});
		}

		if (type === 'fallback' && !externalPlugins) {
			[ 'primary', 'secondary' ].forEach(function(field) {
				var referenced = text(plainValue(doc, argsPath.concat([ field ])));

				if (referenced && !knownTags[referenced])
					problems.push(_('The %s field of the fallback plugin %s references the missing plugin %s.')
						.format(field, tag, referenced));
			});
		}

		if (!SERVER_PLUGIN_TYPES[type])
			return;

		var entry = text(plainValue(doc, argsPath.concat([ 'entry' ])));
		var title = _(text(definition && definition.title) || type);

		// The core refuses to start a server plugin without these fields.
		if (LISTEN_SERVER_TYPES[type] && !entry)
			problems.push(_('The %s plugin %s requires the %s field.').format(title, tag, _('Entry')));

		if (!text(plainValue(doc, argsPath.concat([ 'listen' ]))))
			problems.push(_('The %s plugin %s requires the %s field.').format(title, tag, _('Listen')));

		var cert = text(plainValue(doc, argsPath.concat([ 'cert' ])));
		var key = text(plainValue(doc, argsPath.concat([ 'key' ])));
		var tlsRequired = type === 'quic_server' ||
			(type === 'http_server' && plainValue(doc, argsPath.concat([ 'enable_http3' ])) === true);

		/*
		 * QUIC and HTTP/3 cannot serve plaintext, so the core refuses to start
		 * them without a certificate and key.
		 */
		if (tlsRequired) {
			if (!cert)
				problems.push(_('The %s plugin %s requires the %s field.').format(title, tag, _('TLS certificate')));

			if (!key)
				problems.push(_('The %s plugin %s requires the %s field.').format(title, tag, _('TLS private key')));
		}
		else if (TLS_SERVER_TYPES[type] && !!cert !== !!key) {
			problems.push(_('The TLS certificate and private key of the %s plugin %s must be configured together.').format(title, tag));
		}

		if (entry && !externalPlugins) {
			if (entry.charAt(0) === '$')
				problems.push(_('The entry %s of the %s server plugin %s must use the plugin tag without "$".').format(entry, type, tag));
			else if (!knownTags[entry])
				problems.push(_('The entry %s of the %s server plugin %s does not reference an existing plugin.').format(entry, type, tag));
		}

		if (type === 'http_server') {
			var entries = plainValue(doc, argsPath.concat([ 'entries' ]));

			(Array.isArray(entries) ? entries : []).forEach(function(entryValue, position) {
				var dohPath = text(entryValue && entryValue.path);
				var dohExec = text(entryValue && entryValue.exec);

				if (!dohPath)
					problems.push(_('DoH entry %d of the HTTP server plugin %s requires the %s field.')
						.format(position + 1, tag, _('Request path')));

				if (!dohExec) {
					problems.push(_('DoH entry %d of the HTTP server plugin %s requires the %s field.')
						.format(position + 1, tag, _('Entry executor')));
					return;
				}

				/*
				 * The DoH exec field takes the bare plugin tag; a leading "$"
				 * would be read as part of the tag name. Included files can
				 * define the referenced plugin, so only resolve tags without
				 * them.
				 */
				if (externalPlugins)
					return;

				if (dohExec.charAt(0) === '$')
					problems.push(_('DoH entry %d of the HTTP server plugin %s must reference the plugin tag without "$".').format(position + 1, tag));
				else if (!knownTags[dohExec])
					problems.push(_('DoH entry %d of the HTTP server plugin %s references the missing plugin %s.').format(position + 1, tag, dohExec));
			});
		}
	});

	if (hasNodePath(doc, [ 'runtime', 'worker_threads' ])) {
		var threads = Number(plainValue(doc, [ 'runtime', 'worker_threads' ]));

		if (!isFinite(threads) || threads < 1)
			problems.push(_('The worker thread count must be at least 1.'));
	}

	var include = plainValue(doc, [ 'include' ]);

	if (include !== undefined) {
		if (!Array.isArray(include)) {
			problems.push(_('The include field must be a list of configuration file paths.'));
		}
		else {
			var seenIncludes = {};

			include.forEach(function(entry, position) {
				var includePath = text(entry);

				if (!includePath) {
					problems.push(_('Include entry %d cannot be empty.').format(position + 1));
					return;
				}

				if (seenIncludes[includePath])
					problems.push(_('Include entry %d duplicates another include entry.').format(position + 1));

				seenIncludes[includePath] = true;
			});
		}
	}

	var outboundDefault = text(plainValue(doc, [ 'network', 'outbound', 'default' ]));

	if (outboundDefault && outboundProfiles(doc).indexOf(outboundDefault) === -1)
		problems.push(_('The default outbound profile %s is not defined under network.outbound.profiles.')
			.format(outboundDefault));

	var http = plainValue(doc, [ 'api', 'http' ]);

	if (http !== undefined) {
		var apiListen = typeof http === 'string'
			? http
			: text(plainValue(doc, [ 'api', 'http', 'listen' ]));

		if (!apiListen)
			problems.push(_('The API listen address cannot be empty.'));

		if (typeof http !== 'string') {
			var apiCert = text(plainValue(doc, [ 'api', 'http', 'ssl', 'cert' ]));
			var apiKey = text(plainValue(doc, [ 'api', 'http', 'ssl', 'key' ]));
			var clientCa = text(plainValue(doc, [ 'api', 'http', 'ssl', 'client_ca' ]));
			var requireClientCert = plainValue(doc, [ 'api', 'http', 'ssl', 'require_client_cert' ]);

			if (!!apiCert !== !!apiKey)
				problems.push(_('The API certificate and private key must be configured together.'));

			if (requireClientCert === true && !clientCa)
				problems.push(_('The API requires a client CA when client certificate verification is enabled.'));

			if (hasNodePath(doc, [ 'api', 'http', 'auth' ])) {
				var username = text(plainValue(doc, [ 'api', 'http', 'auth', 'username' ]));
				var password = text(plainValue(doc, [ 'api', 'http', 'auth', 'password' ]));

				if (!username || !password)
					problems.push(_('Basic authentication requires both a username and a password.'));
			}

			if (hasNodePath(doc, [ 'api', 'http', 'webui' ])) {
				if (!text(plainValue(doc, [ 'api', 'http', 'webui', 'root' ])))
					problems.push(_('The API WebUI root cannot be empty.'));

				if (hasNodePath(doc, [ 'api', 'http', 'webui', 'index' ]) &&
				    !text(plainValue(doc, [ 'api', 'http', 'webui', 'index' ])))
					problems.push(_('The API WebUI index cannot be empty.'));
			}
		}
	}

	// Managed ad filtering is validated as a group.
	adfilter.validate(doc).forEach(function(problem) {
		problems.push(problem);
	});

	// The managed cache plugin must stay wired into the entry sequences.
	var cachePlugin = findPluginByTag(doc, CACHE_TAG);

	if (cachePlugin) {
		if (pluginType(cachePlugin.item) !== CACHE_TYPE) {
			problems.push(_('The tag %s is already used by a %s plugin. Rename it in Advanced Mode before enabling cache.')
				.format(CACHE_TAG, pluginType(cachePlugin.item) || _('unknown')));
		}
		else {
			var cacheTargets = entrySequences(doc);

			if (!cacheTargets.length)
				problems.push(_('No entry sequence was found. Configure a server entry in Advanced Mode first.'));
			else if (stepWiringMissing(doc, CACHE_TAG, cacheTargets).length)
				problems.push(_('The cache step could not be inserted into the entry sequence. Check the sequence configuration in Advanced Mode.'));
		}
	}

	// The managed hosts plugin must stay wired into the entry sequences.
	var hostsPlugin = findPluginByTag(doc, HOSTS_TAG);

	if (hostsPlugin) {
		if (pluginType(hostsPlugin.item) !== HOSTS_TYPE) {
			problems.push(_('The tag %s is already used by a %s plugin. Rename it in Advanced Mode before enabling hosts.')
				.format(HOSTS_TAG, pluginType(hostsPlugin.item) || _('unknown')));
		}
		else {
			var hostsTargets = entrySequences(doc);

			if (!hostsTargets.length)
				problems.push(_('No entry sequence was found. Configure a server entry in Advanced Mode first.'));
			else if (stepWiringMissing(doc, HOSTS_TAG, hostsTargets).length)
				problems.push(_('The hosts step could not be inserted into the entry sequence. Check the sequence configuration in Advanced Mode.'));
		}
	}

	return problems;
}

function isAliasNode(node) {
	return !!(node && typeof node === 'object' && typeof node.resolve === 'function' &&
		typeof node.source === 'string');
}

function hasAnchorsOrAliases(node) {
	var found = false;

	function visit(current) {
		if (found || !current || typeof current !== 'object')
			return;

		if (isAliasNode(current) || current.anchor) {
			found = true;
			return;
		}

		if (Array.isArray(current.items))
			current.items.forEach(visit);

		if (current.key) {
			if (current.key.value === '<<')
				found = true;

			visit(current.key);
		}

		visit(current.value);
	}

	visit(node);

	return found;
}

return baseclass.extend({
	render: function(doc, options) {
		var bindings = [];
		var handlers = options || {};
		var bootstrap = isBootstrapTheme();
		var adFilter = adFilterSection(doc, handlers);
		var hosts = hostsSection(doc, bindings, handlers);
		var cache = cacheSection(doc, bindings, handlers);

		var sections = [
			E('style', {}, UPSTREAM_SELECT_STYLE),
			bootstrap ? E('style', {}, BOOTSTRAP_FORM_STYLE) : '',
			logSection(doc, bindings),
			runtimeSection(doc, bindings),
			includeSection(doc, bindings),
			bootstrapSection(doc, handlers),
			outboundSection(doc, bindings),
			apiSection(doc, bindings, handlers),
			listenSection(doc, bindings),
			upstreamSection(doc, bindings, handlers),
			adFilter.node,
			hosts.node,
			cache.node
		].concat(schemaSections(doc, bindings, handlers));

		/*
		 * Run the group binding last so it sees the server entries and
		 * sequence changes applied by the other bindings.
		 */
		if (adFilter.binding)
			bindings.push(adFilter.binding);

		sections.push(pluginSection(doc, handlers));

		var node = E('div', { 'class': bootstrap ? 'oxidns-bootstrap-form' : null }, sections);

		if (typeof handlers.onInput === 'function') {
			node.addEventListener('input', handlers.onInput);
			node.addEventListener('change', handlers.onInput);
			node.addEventListener('cbi-dropdown-change', handlers.onInput);
		}

		return {
			'node': node,
			'bindings': bindings
		};
	},

	apply: applyBindings,
	validate: validateConfig,
	isReadOnly: function(doc) {
		return !!(doc && hasAnchorsOrAliases(doc.contents));
	}
});
