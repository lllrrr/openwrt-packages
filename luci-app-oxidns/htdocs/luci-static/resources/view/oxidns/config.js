'use strict';
'require view';
'require rpc';
'require ui';
'require oxidns.yaml as yaml';
'require view.oxidns.config-guided as guided';
'require view.oxidns.config-yaml as yamlEditor';
'require oxidns.i18n as i18n';

var callConfigRead = rpc.declare({
	object: 'luci.oxidns',
	method: 'config_read',
	expect: {}
});

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
	expect: {}
});

var callConfigSchema = rpc.declare({
	object: 'luci.oxidns',
	method: 'config_schema',
	expect: {}
});

var callConfigPluginTypes = rpc.declare({
	object: 'luci.oxidns',
	method: 'config_plugin_types',
	expect: {}
});

var callConfigValidate = rpc.declare({
	object: 'luci.oxidns',
	method: 'config_validate',
	params: [ 'content' ],
	expect: {}
});

var callConfigSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'config_save',
	params: [ 'content', 'base_mtime', 'restart' ],
	expect: {}
});

var DIFF_MAX_LINES = 800;
var DIFF_CONTEXT = 3;

var state = {
	raw: '',
	doc: null,
	parseError: null,
	serializeError: null,
	mtime: '',
	mode: 'advanced',
	preview: true,
	bindings: [],
	readOnly: false,
	parsedContent: '',
	advancedDraft: '',
	schema: null,
	pluginTypes: null
};

var previewTimer = null;

function loadErrorMessage(err) {
	if (err && (err.message || err.error))
		return err.message || err.error;
	return _('Unable to load configuration.');
}

function coreInstalled(status) {
	return !!(status && status.core && status.core.installed);
}

function guidedApply() {
	if (!state.readOnly)
		guided.apply(state.doc, state.bindings);
}

function setStatus(message, danger) {
	var node = document.getElementById('oxidns-config-status');
	if (!node)
		return;
	node.textContent = message || '';
	node.className = danger ? 'alert-message error' : 'alert-message info';
}

/*
 * Normal mode builds its form from mapping keys. A sequence or scalar at the
 * top level parses as YAML but cannot be edited there, so treat it the same
 * as a syntax error and keep the user in advanced mode.
 */
function topLevelMapping(doc) {
	return !!doc && !!doc.contents && yaml.isMap(doc.contents) === true;
}

function parseContent(content) {
	state.doc = null;
	state.parseError = null;
	state.parsedContent = content || '';

	try {
		var doc = yaml.parseDocument(content || '');

		if (doc.errors && doc.errors.length) {
			state.parseError = doc.errors[0].message || String(doc.errors[0]);
		}
		else if (!doc.contents) {
			state.parseError = _('The configuration file is empty.');
		}
		else if (!topLevelMapping(doc)) {
			state.parseError = _('the top level must be a mapping of keys to values.');
		}
		else {
			state.doc = doc;
		}
	}
	catch (err) {
		state.parseError = err && err.message ? err.message : String(err);
	}

	return !state.parseError;
}

/*
 * Normal mode always works on a parsed document and saves its serialized
 * form, but the serializer rewrites inline comment spacing. Compare the data
 * instead, so an untouched document keeps its saved text and the preview and
 * Reset prompt do not report formatting noise as an edit.
 */
function sameDocumentData(doc, text) {
	try {
		return JSON.stringify(doc.toJSON()) === JSON.stringify(yaml.parse(text || ''));
	}
	catch (err) {
		return false;
	}
}

function guidedContent() {
	state.serializeError = null;

	if (!state.doc)
		return state.raw;

	if (state.readOnly)
		return state.parsedContent;

	guidedApply();

	if (sameDocumentData(state.doc, state.raw))
		return state.raw;

	try {
		return state.doc.toString({ lineWidth: 0 });
	}
	catch (err) {
		state.serializeError = err && err.message ? err.message : String(err);
		return state.raw;
	}
}

function currentContent() {
	if (state.mode === 'advanced')
		return yamlEditor.value(state.advancedDraft);

	return guidedContent();
}

function guidedProblems() {
	if (state.mode !== 'guided' || !state.doc || state.readOnly)
		return [];

	guidedApply();

	var problems = typeof guided.validate === 'function'
		? guided.validate(state.doc, { 'schema': state.schema })
		: [];

	if (problems.length)
		setStatus(problems.join(' '), true);

	return problems;
}

function runConfigCall(label, call, args, onSuccess) {
	ui.showModal(_('OxiDNS'), [
		E('p', {}, label)
	]);

	return L.resolveDefault(call.apply(null, args || []), null).then(function(result) {
		ui.hideModal();
		if (!result || result.ok === false) {
			setStatus(i18n.message(result) || _('Operation failed'), true);
			return result;
		}
		if (onSuccess)
			onSuccess(result);
		setStatus(i18n.message(result) || _('Operation completed.'), false);
		return result;
	}).catch(function(err) {
		ui.hideModal();
		setStatus(err.message || String(err), true);
		return null;
	});
}

function validateYaml() {
	var content = currentContent();

	if (state.serializeError) {
		setStatus(state.serializeError, true);
		return Promise.resolve();
	}

	if (guidedProblems().length)
		return Promise.resolve();

	return runConfigCall(_('Validating configuration...'), callConfigValidate, [
		content
	]);
}

function saveYaml(restart) {
	var content = currentContent();

	if (state.serializeError) {
		setStatus(state.serializeError, true);
		return Promise.resolve();
	}

	if (guidedProblems().length)
		return Promise.resolve();

	/*
	 * Apply must restart even when the content matches the last saved file.
	 * A previous "Save" stores the file without restarting, so the running
	 * service can still hold an older configuration; comparing against the
	 * saved file would silently turn "Save and Apply" into a no-op.
	 */
	var restartService = !!restart;

	return runConfigCall(restartService ? _('Saving and applying configuration...') : _('Saving configuration...'), callConfigSave, [
		content,
		state.mtime,
		restartService
	], function(result) {
		state.mtime = result.mtime !== undefined ? result.mtime : state.mtime;
		applySavedContent(content);
	});
}

function hasUnsavedChanges() {
	try {
		return currentContent() !== state.raw;
	}
	catch (err) {
		return true;
	}
}

function resetYaml() {
	if (hasUnsavedChanges() &&
	    !window.confirm(_('Discard the unsaved changes and reload the last saved configuration?')))
		return;

	return L.resolveDefault(callConfigRead(), null).then(function(result) {
		if (!result || result.ok === false || typeof result.content !== 'string') {
			setStatus((result && (result.message || result.error)) ||
				_('Unable to reload the saved configuration.'), true);
			return;
		}

		state.mtime = result.mtime !== undefined ? result.mtime : state.mtime;
		state.serializeError = null;
		applySavedContent(result.content);
		setStatus(_('Unsaved changes were discarded and the saved configuration was reloaded.'), false);
	}).catch(function(err) {
		setStatus(loadErrorMessage(err), true);
	});
}

function applySavedContent(content) {
	state.raw = content;
	state.advancedDraft = content;

	if (!parseContent(content) && state.mode === 'guided')
		state.mode = 'advanced';

	updateModeButtons();
	renderBody();
}

function downloadYaml() {
	return L.resolveDefault(callConfigRead(), null).then(function(result) {
		if (!result || result.ok === false || typeof result.content !== 'string') {
			setStatus((result && (result.message || result.error)) || _('Unable to load configuration.'), true);
			return;
		}

		var blob = new Blob([ result.content ], { type: 'application/yaml' });
		var url = URL.createObjectURL(blob);
		var link = E('a', { 'href': url, 'download': 'config.yaml' });

		document.body.appendChild(link);
		link.click();
		document.body.removeChild(link);
		window.setTimeout(function() {
			URL.revokeObjectURL(url);
		}, 1000);
		setStatus(_('Configuration downloaded.'), false);
	}).catch(function(err) {
		setStatus(err.message || String(err), true);
	});
}

function readTextFile(file) {
	return new Promise(function(resolve, reject) {
		var reader = new FileReader();
		reader.onload = function() {
			resolve(String(reader.result || ''));
		};
		reader.onerror = function() {
			reject(reader.error || new Error(_('Unable to read the selected file.')));
		};
		reader.readAsText(file);
	});
}

function validIpv4(value) {
	var parts = String(value || '').split('.');

	if (parts.length !== 4)
		return false;

	for (var i = 0; i < parts.length; i++) {
		if (!/^\d{1,3}$/.test(parts[i]) || Number(parts[i]) > 255)
			return false;
	}

	return true;
}

function concreteIpv4(value) {
	if (!validIpv4(value))
		return false;
	if (value === '0.0.0.0' || value === '255.255.255.255')
		return false;
	if (value.indexOf('127.') === 0)
		return false;
	return true;
}

function splitListen(value) {
	var match = String(value || '').trim().match(/^(\[[^\]]+\]|[^:]*):(\d+)$/);

	if (!match)
		return null;

	return { 'host': match[1], 'port': match[2] };
}

function listenNodes(doc) {
	var nodes = [];
	var http = doc.getIn([ 'api', 'http' ], true);
	var apiListen;

	if (http && typeof http.value === 'string' && http.range) {
		nodes.push(http);
	}
	else {
		apiListen = doc.getIn([ 'api', 'http', 'listen' ], true);
		if (apiListen && typeof apiListen.value === 'string' && apiListen.range)
			nodes.push(apiListen);
	}

	var plugins = doc.getIn([ 'plugins' ], true);
	var items = plugins && plugins.items ? plugins.items : [];

	for (var i = 0; i < items.length; i++) {
		var args = items[i] && typeof items[i].get === 'function'
			? items[i].get('args', true)
			: null;
		var listen = args && typeof args.get === 'function'
			? args.get('listen', true)
			: null;

		if (listen && typeof listen.value === 'string' && listen.range)
			nodes.push(listen);
	}

	return nodes;
}

/*
 * A configuration exported from another router can carry that router's LAN
 * address in listen fields. Replace concrete IPv4 hosts with this router's
 * address while keeping wildcard, loopback, hostname, and IPv6 listeners as
 * they are. Splice only the scalar literals so comments and formatting stay
 * untouched.
 */
function localizeListenAddresses(content, localIp) {
	var result = { 'content': content, 'changed': false, 'localIp': localIp };
	var source = String(content || '');
	var doc;

	if (!concreteIpv4(localIp))
		return result;

	try {
		doc = yaml.parseDocument(source);
	}
	catch (err) {
		return result;
	}

	if (!doc || !doc.contents || (doc.errors && doc.errors.length))
		return result;

	var nodes = listenNodes(doc);
	var changes = [];

	for (var i = 0; i < nodes.length; i++) {
		var node = nodes[i];
		var parsed = splitListen(node.value);

		if (!parsed || !concreteIpv4(parsed.host) || parsed.host === localIp)
			continue;

		var literal = source.slice(node.range[0], node.range[1]);
		var hostIndex = literal.indexOf(parsed.host);

		if (hostIndex === -1)
			continue;

		changes.push({
			'start': node.range[0],
			'end': node.range[1],
			'literal': literal.slice(0, hostIndex) +
				localIp +
				literal.slice(hostIndex + parsed.host.length)
		});
	}

	if (!changes.length)
		return result;

	changes.sort(function(a, b) { return b.start - a.start; });

	var output = source;
	for (var j = 0; j < changes.length; j++)
		output = output.slice(0, changes[j].start) + changes[j].literal + output.slice(changes[j].end);

	return { 'content': output, 'changed': true, 'localIp': localIp };
}

function uploadYaml(file) {
	if (!file)
		return Promise.resolve();
	if (file.name !== 'config.yaml') {
		setStatus(_('The file must be named config.yaml.'), true);
		return Promise.resolve();
	}

	if (!window.confirm(_('Uploading config.yaml replaces the saved configuration immediately and discards unsaved changes. Continue?')))
		return Promise.resolve();

	return Promise.all([
		readTextFile(file),
		L.resolveDefault(callStatus(), {})
	]).then(function(results) {
		var content = results[0];
		var status = results[1] || {};
		var localized = localizeListenAddresses(content, status.lan_ipv4 || '');

		return runConfigCall(_('Uploading configuration...'), callConfigSave, [
			localized.content,
			state.mtime,
			false
		], function(result) {
			state.mtime = result.mtime !== undefined ? result.mtime : state.mtime;
			applySavedContent(localized.content);
		}).then(function(result) {
			if (result && result.ok !== false && localized.changed)
				setStatus(_('Configuration uploaded. Listen addresses now use %s.').format(localized.localIp), false);
		});
	}).catch(function(err) {
		setStatus(err.message || String(err), true);
	});
}

function uploadInput() {
	var input = E('input', {
		'type': 'file',
		'accept': '.yaml,text/yaml,application/yaml',
		'style': 'display: none',
		'change': function(ev) {
			var file = ev.target.files && ev.target.files[0];
			ev.target.value = '';
			return uploadYaml(file);
		}
	});

	return E('span', { 'style': 'display: inline-flex' }, [
		input,
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();
				input.click();
			}
		}, _('Upload Config'))
	]);
}

function diffText(value) {
	/* The YAML serializer always ends with a newline; ignore that difference. */
	return String(value || '').replace(/\r\n/g, '\n').replace(/\s+$/, '');
}

function diffLines(oldText, newText) {
	oldText = diffText(oldText);
	newText = diffText(newText);

	if (oldText === newText)
		return [];

	var before = oldText.split('\n');
	var after = newText.split('\n');

	if (before.length > DIFF_MAX_LINES || after.length > DIFF_MAX_LINES)
		return null;

	var n = before.length;
	var m = after.length;
	var table = [];
	var i, j;

	for (i = 0; i <= n; i++)
		table.push(new Uint32Array(m + 1));

	for (i = n - 1; i >= 0; i--) {
		for (j = m - 1; j >= 0; j--) {
			table[i][j] = before[i] === after[j]
				? table[i + 1][j + 1] + 1
				: Math.max(table[i + 1][j], table[i][j + 1]);
		}
	}

	var lines = [];
	i = 0;
	j = 0;

	while (i < n && j < m) {
		if (before[i] === after[j]) {
			lines.push({ 'type': 'ctx', 'text': before[i] });
			i++;
			j++;
		}
		else if (table[i + 1][j] >= table[i][j + 1]) {
			lines.push({ 'type': 'del', 'text': before[i] });
			i++;
		}
		else {
			lines.push({ 'type': 'add', 'text': after[j] });
			j++;
		}
	}

	while (i < n)
		lines.push({ 'type': 'del', 'text': before[i++] });
	while (j < m)
		lines.push({ 'type': 'add', 'text': after[j++] });

	return compactDiff(lines, DIFF_CONTEXT);
}

function compactDiff(lines, context) {
	var keep = [];

	lines.forEach(function(line, index) {
		if (line.type === 'ctx')
			return;

		var from = Math.max(0, index - context);
		var to = Math.min(lines.length - 1, index + context);

		for (var i = from; i <= to; i++)
			keep[i] = true;
	});

	var result = [];

	for (var i = 0; i < lines.length; i++) {
		if (keep[i]) {
			result.push(lines[i]);
		}
		else if (result.length && result[result.length - 1].type !== 'gap') {
			result.push({ 'type': 'gap', 'text': '…' });
		}
	}

	return result;
}

function schedulePreview() {
	if (previewTimer)
		window.clearTimeout(previewTimer);

	previewTimer = window.setTimeout(function() {
		previewTimer = null;
		updatePreview();
	}, 250);
}

function updatePreview() {
	var node = document.getElementById('oxidns-config-preview-body');
	if (!node)
		return;

	while (node.firstChild)
		node.removeChild(node.firstChild);

	if (!state.preview)
		return;

	var lines = diffLines(state.raw, currentContent());

	if (lines === null) {
		node.appendChild(E('div', { 'class': 'cbi-value-description' },
			_('The configuration is too large to preview here. Review the changes in Advanced Mode before saving.')));
		return;
	}

	if (!lines.length) {
		node.appendChild(E('div', { 'class': 'cbi-value-description' }, _('No changes.')));
		return;
	}

	node.appendChild(E('pre', {
		'style': 'margin: 0; padding: .5em; overflow: auto; max-height: 24em; font-size: .9em; font-family: monospace; border: 1px solid var(--border-color-medium, rgba(128,128,128,.35)); border-radius: var(--radius-control, 4px); background: var(--background-color-low, var(--background-color-medium, transparent)); color: var(--text-color-high, var(--text-color, inherit));'
	}, lines.map(function(line) {
		var prefix = line.type === 'add' ? '+ ' : line.type === 'del' ? '- ' : line.type === 'gap' ? '' : '  ';
		var style = line.type === 'add'
			? 'background: rgba(40,160,80,.18);'
			: line.type === 'del'
				? 'background: rgba(200,60,60,.18);'
				: line.type === 'gap'
					? 'opacity: .6;'
					: '';

		return E('div', { 'style': style }, prefix + line.text);
	})));
}

function previewSection() {
	return E('div', { 'class': 'cbi-section', 'style': 'margin-top: 1em;' }, [
		E('h3', {}, _('Change Preview')),
		E('label', { 'style': 'display: inline-flex; gap: .5em; align-items: center; padding-inline: var(--section-inset, 0);' }, [
			E('input', {
				'id': 'oxidns-config-preview-toggle',
				'type': 'checkbox',
				'style': 'position: static; top: auto; right: auto; margin: 0;',
				'checked': state.preview ? 'checked' : null,
				'change': function(ev) {
					state.preview = !!ev.target.checked;
					updatePreview();
				}
			}),
			_('Show change preview')
		]),
		E('div', { 'id': 'oxidns-config-preview-body', 'style': 'margin-top: .75em; padding-inline: var(--section-inset, 0);' })
	]);
}

function lockGuidedForm(node) {
	Array.prototype.forEach.call(node.querySelectorAll('input, select, textarea'), function(control) {
		control.disabled = true;
	});

	Array.prototype.forEach.call(node.querySelectorAll('button'), function(button) {
		var id = button.getAttribute('id') || '';

		if (id.indexOf('oxidns-cfg-upstream-options-toggle-') === 0)
			return;

		button.disabled = true;
	});
}

function modeButton(mode, label) {
	return E('button', {
		'id': 'oxidns-mode-' + mode,
		'class': 'btn cbi-button ' + (state.mode === mode ? 'cbi-button-action' : 'cbi-button-neutral'),
		'click': function(ev) {
			ev.preventDefault();
			switchMode(mode);
		}
	}, label);
}

function updateModeButtons() {
	var guidedButton = document.getElementById('oxidns-mode-guided');
	var advancedButton = document.getElementById('oxidns-mode-advanced');

	if (guidedButton)
		guidedButton.className = 'btn cbi-button ' + (state.mode === 'guided' ? 'cbi-button-action' : 'cbi-button-neutral');
	if (advancedButton)
		advancedButton.className = 'btn cbi-button ' + (state.mode === 'advanced' ? 'cbi-button-action' : 'cbi-button-neutral');
}

function switchMode(mode) {
	if (mode === state.mode)
		return;

	if (mode === 'guided') {
		var content = yamlEditor.value(state.advancedDraft);

		if (!parseContent(content)) {
			ui.addNotification(null, E('p', {},
				_('The YAML is invalid: %s').format(state.parseError)), 'danger');
			return;
		}
	}
	else {
		state.advancedDraft = guidedContent();
	}

	state.mode = mode;
	updateModeButtons();
	renderBody();
}

function fillBody(body) {
	while (body.firstChild)
		body.removeChild(body.firstChild);

	if (state.mode === 'advanced') {
		state.bindings = [];
		state.readOnly = false;
		state.serializeError = null;

		/*
		 * Refresh the parse state from the editor draft so the "Normal mode is
		 * unavailable" notice reflects the current content, not the file that
		 * was loaded when the page opened.
		 */
		parseContent(state.advancedDraft);

		if (state.parseError) {
			body.appendChild(E('div', { 'class': 'alert-message warning', 'style': 'margin: 1em 0;' },
				_('Normal mode is unavailable: %s').format(state.parseError)));
		}

		body.appendChild(yamlEditor.render(state.advancedDraft, {
			'onInput': function(value) {
				state.advancedDraft = value;
				state.serializeError = null;
				schedulePreview();
			}
		}));

		body.appendChild(previewSection());
	}
	else if (!state.doc) {
		body.appendChild(E('div', { 'class': 'alert-message warning', 'style': 'margin: 1em 0;' },
			_('Normal mode needs valid YAML. Fix the YAML in advanced mode first.')));
	}
	else {
		var rendered = guided.render(state.doc, {
			'beforeChange': guidedApply,
			'rerender': renderBody,
			'onInput': schedulePreview,
			'schema': state.schema,
			'pluginTypes': state.pluginTypes
		});

		state.bindings = rendered.bindings;
		state.readOnly = typeof guided.isReadOnly === 'function' && guided.isReadOnly(state.doc);

		if (state.readOnly) {
			lockGuidedForm(rendered.node);
			body.appendChild(E('div', { 'class': 'alert-message warning', 'style': 'margin: 1em 0;' },
				_('This configuration uses YAML anchors, aliases, or merge keys. Normal mode is read-only for this file; edit it in advanced mode.')));
		}

		body.appendChild(rendered.node);
		body.appendChild(previewSection());
	}
}

function renderBody() {
	var body = document.getElementById('oxidns-config-body');
	if (!body)
		return;

	fillBody(body);
	updatePreview();
}

function actionButtons() {
	return E('div', {
		'class': 'cbi-button-row',
		'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: 1em; padding-inline: var(--section-inset, 0);'
	}, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();
				return validateYaml();
			}
		}, _('Validate')),
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();
				return downloadYaml();
			}
		}, _('Download Config')),
		uploadInput(),
		E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'click': function(ev) {
				ev.preventDefault();
				return saveYaml(true);
			}
		}, _('Save and Apply')),
		E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'click': function(ev) {
				ev.preventDefault();
				return saveYaml(false);
			}
		}, _('Save')),
		E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': function(ev) {
				ev.preventDefault();
				return resetYaml();
			}
		}, _('Reset'))
	]);
}

return view.extend({
	load: function() {
		var configPromise = L.resolveDefault(callConfigRead(), null).then(function(config) {
			return config || {
				ok: false,
				message: _('Unable to load configuration.')
			};
		}).catch(function(err) {
			return {
				ok: false,
				message: loadErrorMessage(err)
			};
		});

		var schemaPromise = L.resolveDefault(callConfigSchema(), null).then(function(result) {
			return result && result.ok !== false && result.schema ? result.schema : null;
		}).catch(function() {
			return null;
		});

		var pluginTypesPromise = L.resolveDefault(callConfigPluginTypes(), null).then(function(result) {
			return result && result.ok !== false && result.plugins ? result : null;
		}).catch(function() {
			return null;
		});

		return Promise.all([
			configPromise,
			L.resolveDefault(callStatus(), {}),
			schemaPromise,
			pluginTypesPromise
		]).then(function(results) {
			return {
				config: results[0],
				status: results[1] || {},
				schema: results[2] || null,
				pluginTypes: results[3] || null
			};
		});
	},

	render: function(data) {
		var config = data && data.config ? data.config : {};
		var statusState = data && data.status ? data.status : {};
		var readFailed = config.ok === false;
		var configContent = config.content || '';
		var configMessage = readFailed
			? (i18n.message(config) || _('Unable to load configuration.'))
			: '';

		state.mtime = config.mtime || '';
		state.raw = configContent;
		state.advancedDraft = configContent;
		state.preview = true;
		state.schema = data && data.schema ? data.schema : null;
		state.pluginTypes = data && data.pluginTypes ? data.pluginTypes : null;
		state.mode = 'advanced';
		parseContent(configContent);

		if (readFailed && !coreInstalled(statusState)) {
			return E('div', { 'class': 'cbi-map' }, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'alert-message warning', 'style': 'margin: 1em 0;' },
						_('Install the OxiDNS core before editing the configuration.')),
					E('p', { 'class': 'cbi-section-descr' },
						_('Install it from Services → OxiDNS → Installation and Deployment, then return to this page.'))
				])
			]);
		}

		var body = E('div', { 'id': 'oxidns-config-body', 'style': 'margin-top: 1em;' });
		fillBody(body);

		var node = E('div', { 'class': 'cbi-map' }, [
			E('div', { 'class': 'cbi-section-descr' },
				_('Edit the OxiDNS configuration with form-based editing, or use the full YAML editor.') + ' ' +
				_('Normal mode edits common settings and keeps the remaining YAML, including comments, unchanged.')),
			E('div', { 'class': 'cbi-section' }, [
				readFailed ? E('div', {
					'class': 'alert-message warning',
					'style': 'margin: 1em 0;'
				}, configMessage) : '',
				E('div', {
					'id': 'oxidns-config-modes',
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: 1em; padding-inline: var(--section-inset, 0);'
				}, [
					modeButton('guided', _('Normal Mode')),
					modeButton('advanced', _('Advanced Mode'))
				]),
				body,
				actionButtons(),
				E('div', { 'id': 'oxidns-config-status', 'style': 'margin-top: 1em;' })
			])
		]);

		window.setTimeout(updatePreview, 0);

		return node;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
