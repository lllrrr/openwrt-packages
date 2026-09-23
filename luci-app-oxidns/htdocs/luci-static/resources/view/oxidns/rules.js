'use strict';
'require view';
'require rpc';
'require ui';

var callRulesList = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_list',
	expect: {}
});

var callRulesRead = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_read',
	params: [ 'name' ],
	expect: {}
});

var callRulesSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_save',
	params: [ 'name', 'content', 'base_mtime', 'restart' ],
	expect: {}
});

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
	expect: {}
});

var callLearnGet = rpc.declare({
	object: 'luci.oxidns',
	method: 'learn_reset_get',
	expect: {}
});

var callLearnSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'learn_reset_save',
	params: [ 'reset_cn', 'reset_proxy', 'freq', 'time', 'weekday', 'api_url', 'api_user', 'api_pass' ],
	expect: {}
});

var callLearnRun = rpc.declare({
	object: 'luci.oxidns',
	method: 'learn_reset_run',
	expect: {}
});

/*
 * 页面状态：
 *   dir     - 规则目录
 *   files   - 目录下可编辑的规则文件
 *   current - 当前正在编辑的文件名
 *   loaded  - 载入 / 保存时的内容快照，用来判断是否有未保存修改
 *   mtime   - 载入时文件在磁盘上的修改时间，保存时用来检测并发改动
 */
var rulesState = {
	dir: '',
	files: [],
	current: null,
	loaded: null,
	mtime: ''
};

/*
 * 固定标签页：题注与文件名一一对应，顺序即页面展示顺序。
 * 目录里多出来的 .txt 以文件名作题注追加在固定标签页之后。
 */
var RULE_TABS = [
	{ name: 'whitelist.txt', label: _('Whitelist') },
	{ name: 'blocklist.txt', label: _('Blacklist') },
	{ name: 'greylist.txt', label: _('Greylist') },
	{ name: 'ddnslist.txt', label: _('Dynamic Domains') },
	{ name: 'hosts.txt', label: 'hosts' },
	{ name: 'redirect.txt', label: _('Redirect') },
	{ name: 'local-ptr.txt', label: _('Local PTR') }
];

var editorState = {
	resultKind: null,
	buttons: []
};

function loadErrorMessage(err) {
	if (err && (err.message || err.error))
		return err.message || err.error;
	return _('Unable to load the rule files.');
}

function readErrorMessage(err) {
	if (err && (err.message || err.error))
		return err.message || err.error;
	return _('Unable to load the rule file.');
}

function textareaValue() {
	var textarea = document.getElementById('oxidns-rules-content');
	return textarea ? textarea.value : '';
}

function selectValue() {
	return rulesState.current || '';
}

function coreInstalled(status) {
	return !!(status && status.core && status.core.installed);
}

function formatBytes(size) {
	var value = parseInt(size, 10);

	if (isNaN(value))
		return '-';
	if (value < 1024)
		return '%d B'.format(value);
	if (value < 1024 * 1024)
		return '%.1f KB'.format(value / 1024);
	return '%.1f MB'.format(value / (1024 * 1024));
}

function formatTime(mtime) {
	var value = parseInt(mtime, 10);

	if (isNaN(value) || value <= 0)
		return '-';

	var date = new Date(value * 1000);

	return '%04d-%02d-%02d %02d:%02d:%02d'.format(
		date.getFullYear(), date.getMonth() + 1, date.getDate(),
		date.getHours(), date.getMinutes(), date.getSeconds());
}

function formatCount(value) {
	var count = parseInt(value, 10);
	return isNaN(count) ? '-' : count;
}

function isDirty() {
	return rulesState.loaded !== null && textareaValue() !== rulesState.loaded;
}

/* 去掉命令输出里的 ANSI 转义，避免终端色彩在页面上变成乱码 */
function plainText(value) {
	return String(value === null || value === undefined ? '' : value)
		.replace(/\u001b\[[0-9;]*[A-Za-z]/g, '')
		.replace(/[ \t]+$/gm, '')
		.replace(/\s+$/, '');
}

function ensureVisible(node) {
	if (!node || !node.getBoundingClientRect)
		return;

	var rect = node.getBoundingClientRect();
	var viewport = window.innerHeight || document.documentElement.clientHeight || 0;

	if (viewport && (rect.bottom > viewport || rect.top < 0))
		node.scrollIntoView({ 'behavior': 'smooth', 'block': 'nearest' });
}

function renderResult(kind, title, detail, containerId) {
	var container = document.getElementById(containerId || 'oxidns-rules-status');
	if (!container)
		return;

	while (container.firstChild)
		container.removeChild(container.firstChild);

	var output = plainText(detail);

	if (output && output.toLowerCase() === String(title).toLowerCase())
		output = '';

	var panel = E('div', {
		'class': 'alert-message ' + kind,
		'style': 'margin: .75em 0 0; overflow-wrap: break-word;'
	}, [
		E('h4', {}, title),
		output ? E('pre', {
			'style': 'margin: .35em 0 0; padding: .5em; max-height: 18em; overflow: auto; white-space: pre-wrap; word-break: break-word; font-size: 12px; line-height: 1.45; background: rgba(0, 0, 0, .06); border: 1px solid rgba(0, 0, 0, .12); border-radius: 3px;'
		}, output) : ''
	]);

	container.appendChild(panel);
	editorState.resultKind = kind;

	window.setTimeout(function() {
		ensureVisible(panel);
	}, 0);
}

function notifyResult(kind, message) {
	if (!message)
		return;

	ui.addTimeLimitedNotification(null, E('p', {}, message), 6000, kind === 'error' ? 'danger' : kind);
}

function setBusy(activeButton, busy) {
	editorState.buttons.forEach(function(button) {
		button.disabled = busy;
		if (busy && button === activeButton)
			button.classList.add('spinning');
		else
			button.classList.remove('spinning');
	});
}

function runRuleCall(button, busyText, call, args, containerId) {
	setBusy(button, true);
	renderResult('notice', busyText, '', containerId);

	return Promise.resolve().then(function() {
		return call.apply(null, args || []);
	}).catch(function(err) {
		return {
			ok: false,
			code: 'rpc_error',
			message: (err && err.message) || String(err)
		};
	}).then(function(result) {
		setBusy(button, false);
		return result;
	});
}

function setTextValue(id, value) {
	var node = document.getElementById(id);

	if (node)
		node.textContent = value === null || value === undefined || value === '' ? '-' : value;
}

/* 把单个文件的元信息写进表格行 */
function showFileInfo(file) {
	var info = file || {};
	var known = info.exists !== false;

	setTextValue('oxidns-rules-current', info.name || rulesState.current);
	setTextValue('oxidns-rules-file-size', known ? formatBytes(info.size) : '-');
	setTextValue('oxidns-rules-file-lines', known ? formatCount(info.lines) : '-');
	setTextValue('oxidns-rules-file-mtime', known ? formatTime(info.mtime) : '-');
}

function applyLoadedFile(result) {
	rulesState.current = result.name || rulesState.current;
	rulesState.loaded = result.content || '';
	rulesState.mtime = result.mtime || '';

	setTabActive(rulesState.current);
	showFileInfo(result);
}

function loadRuleFile(name) {
	if (!name)
		return Promise.resolve(null);

	return runRuleCall(null, _('Loading rule file...'), callRulesRead, [ name ]).then(function(result) {
		if (!result || result.ok === false) {
			renderResult('error', _('Unable to load the rule file'),
				(result && (result.message || result.error)) || readErrorMessage(null));
			notifyResult('error', _('Unable to load the rule file'));
			return null;
		}

		applyLoadedFile(result);

		var textarea = document.getElementById('oxidns-rules-content');
		if (textarea)
			textarea.value = rulesState.loaded;

		if (result.exists === false) {
			renderResult('warning', _('The rule file does not exist yet. Save to create it.'), result.path);
			return result;
		}

		renderResult('notice', _('Loaded rule file'), result.path);
		return result;
	});
}

function saveRuleFile(button, restart) {
	var name = selectValue();

	if (!name)
		return Promise.resolve();

	var content = textareaValue();

	return runRuleCall(button, restart ? _('Saving and restarting service...') : _('Saving rule file...'),
		callRulesSave, [ name, content, String(rulesState.mtime || ''), restart ]).then(function(result) {
		var code = result && result.code;
		var message = result && (result.message || result.error);

		if (result && result.ok === false) {
			/* 文件其实已经写进去了，只是服务没起来：不能只报一个红色错误 */
			if (code === 'service_unavailable' || code === 'service_restart_failed') {
				rulesState.loaded = content;
				renderResult('warning', _('Saved, but the service did not restart'), message);
				notifyResult('warning', _('Saved, but the service did not restart'));
				return;
			}

			if (code === 'rule_conflict') {
				renderResult('error', _('Save failed'),
					_('The rule file was modified on disk since it was loaded. Reload it before saving again.'));
				notifyResult('error', _('Save failed'));
				return;
			}

			renderResult('error', _('Save failed'), message);
			notifyResult('error', _('Save failed'));
			return;
		}

		if (result) {
			rulesState.mtime = result.mtime;
			showFileInfo(result);
		}

		rulesState.loaded = content;

		if (restart) {
			renderResult('success', _('Rule file saved and service restarted'), message);
			notifyResult('success', _('Rule file saved and service restarted'));
			return;
		}

		renderResult('warning', _('Saved, but not applied to the running service'),
			_('OxiDNS reads rule files when a provider is loaded. Use Save & Restart to apply the changes.'));
		notifyResult('warning', _('Saved, but not applied to the running service'));
	});
}

/* 载入之后又改了内容：旧结论不再代表当前内容 */
function handleEditorInput() {
	if (editorState.resultKind !== 'success' && editorState.resultKind !== 'warning')
		return;
	if (!isDirty())
		return;

	renderResult('notice', _('There are unsaved changes'));
}

function discardChanges() {
	if (isDirty() && !window.confirm(_('Discard unsaved changes and reload this file?')))
		return Promise.resolve();

	return loadRuleFile(rulesState.current);
}

function handleFileChange(ev) {
	var name = ev && ev.currentTarget ? ev.currentTarget.getAttribute('data-name') : '';

	if (!name || name === rulesState.current)
		return;

	if (isDirty() && !window.confirm(_('Discard unsaved changes and load another file?')))
		return;

	return loadRuleFile(name);
}

/* 标签页顺序：固定列表在前（按 RULE_TABS 顺序），目录里多出来的 .txt 追加在后。
 * 固定列表里目录还没有的文件也照样出标签页（exists:false，保存时创建），
 * 这样 local-ptr.txt 之类尚未落盘的文件也能从页面直接创建。 */
function orderedFiles(files, dir) {
	var byName = {};

	(files || []).forEach(function(file) {
		byName[file.name] = file;
	});

	var ordered = [];

	RULE_TABS.forEach(function(tab) {
		var file = byName[tab.name];

		if (file) {
			file.label = tab.label;
		} else {
			file = {
				name: tab.name,
				label: tab.label,
				exists: false,
				path: (dir ? dir.replace(/[\/]+$/, '') + '/' : '') + tab.name,
				size: '0',
				lines: '0',
				mtime: ''
			};
		}

		ordered.push(file);
	});

	(files || []).forEach(function(file) {
		var known = RULE_TABS.some(function(tab) {
			return tab.name === file.name;
		});

		if (!known) {
			file.label = file.name;
			ordered.push(file);
		}
	});

	return ordered;
}

function tabStyle(active, missing) {
	var base = 'display: inline-block; padding: 6px 14px; margin-bottom: -1px;'
		+ ' border: 1px solid ' + (active ? 'rgba(0, 0, 0, .2)' : 'transparent') + ';'
		+ ' border-bottom-color: ' + (active ? 'transparent' : 'rgba(0, 0, 0, .2)') + ';'
		+ ' border-radius: 4px 4px 0 0; background: ' + (active ? 'rgba(0, 0, 0, .04)' : 'transparent') + ';'
		+ ' font-weight: ' + (active ? 'bold' : 'normal') + '; cursor: pointer; user-select: none;';

	if (missing)
		base += ' font-style: italic; opacity: .6;';

	return base;
}

/* 横向标签页：切换选中态只改样式，真正加载成功后才更新 data-active */
function ruleTabs(files, current) {
	var bar = E('ul', {
		'id': 'oxidns-rules-tabs',
		'style': 'display: flex; flex-wrap: wrap; gap: 2px; margin: 0; padding: 0 0 0 2px;'
			+ ' list-style: none; border-bottom: 1px solid rgba(0, 0, 0, .2);'
	});

	files.forEach(function(file) {
		var active = file.name === current;
		var missing = file.exists === false;
		var tab = E('li', {
			'data-name': file.name,
			'style': tabStyle(active, missing),
			'title': missing ? _('The rule file does not exist yet. Save to create it.') : file.path
		}, file.label);

		tab.addEventListener('click', handleFileChange);
		bar.appendChild(tab);
	});

	return bar;
}

function setTabActive(name) {
	var bar = document.getElementById('oxidns-rules-tabs');

	if (!bar)
		return;

	Array.prototype.forEach.call(bar.children, function(tab) {
		var tabName = tab.getAttribute('data-name');
		var missing = rulesState.files.some(function(file) {
			return file.name === tabName && file.exists === false;
		});

		tab.setAttribute('style', tabStyle(tabName === name, missing));
	});
}

function ruleTextarea(content) {
	var value = content || '';
	var textarea = E('textarea', {
		'id': 'oxidns-rules-content',
		'class': 'cbi-input-textarea',
		'style': 'width: 100%; min-height: 420px; font-family: monospace;',
		'spellcheck': 'false'
	});

	textarea.defaultValue = value;
	textarea.value = value;
	textarea.addEventListener('input', handleEditorInput);
	return textarea;
}

function infoRow(label, id, value) {
	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', { 'class': 'td left', 'id': id }, value)
	]);
}

/*
 * 定时重置学习文件：learned-cn.txt / learned-proxy.txt 由 OxiDNS 的
 * learn_domain 执行器（dynamic_domain_set）自动写入，重置走管理 API 的
 * rules/clear，内存快照与持久化文件同步清空，无需重启服务。
 */
var LEARN_WEEKDAYS = [
	['0', _('Sunday')],
	['1', _('Monday')],
	['2', _('Tuesday')],
	['3', _('Wednesday')],
	['4', _('Thursday')],
	['5', _('Friday')],
	['6', _('Saturday')]
];

function learnInputValue(id) {
	var node = document.getElementById(id);
	return node ? node.value : '';
}

function handleLearnFreqChange() {
	var select = document.getElementById('oxidns-learn-freq');
	var row = document.getElementById('oxidns-learn-weekday-row');

	if (row)
		row.style.display = (select && select.value === 'weekly') ? '' : 'none';
}

function saveLearnSchedule(button) {
	var resetCn = document.getElementById('oxidns-learn-cn');
	var resetProxy = document.getElementById('oxidns-learn-proxy');
	var cn = !!(resetCn && resetCn.checked);
	var proxy = !!(resetProxy && resetProxy.checked);

	if (!cn && !proxy) {
		renderResult('warning', _('Select at least one learned file to reset.'), '', 'oxidns-learn-status');
		return Promise.resolve();
	}

	var args = [
		cn ? '1' : '0',
		proxy ? '1' : '0',
		learnInputValue('oxidns-learn-freq'),
		learnInputValue('oxidns-learn-time'),
		learnInputValue('oxidns-learn-weekday'),
		learnInputValue('oxidns-learn-api-url'),
		learnInputValue('oxidns-learn-api-user'),
		learnInputValue('oxidns-learn-api-pass')
	];

	return runRuleCall(button, _('Saving schedule...'), callLearnSave, args, 'oxidns-learn-status').then(function(result) {
		if (!result || result.ok === false) {
			renderResult('error', _('Save failed'),
				result && (result.message || result.error), 'oxidns-learn-status');
			notifyResult('error', _('Save failed'));
			return;
		}

		/* 已保存的密码不回显：清空输入框，避免下次保存时重复提交 */
		var passNode = document.getElementById('oxidns-learn-api-pass');
		if (passNode)
			passNode.value = '';

		renderResult('success', _('Schedule saved'),
			result.cron_line ? '%s %s'.format(result.cron_line, 'oxidns-learn-reset.sh') : '', 'oxidns-learn-status');
		notifyResult('success', _('Schedule saved'));
	});
}

function resetLearnedNow(button) {
	return runRuleCall(button, _('Resetting learned files...'), callLearnRun, [], 'oxidns-learn-status').then(function(result) {
		if (!result || result.ok === false) {
			renderResult('error', _('Reset failed'),
				result && (result.message || result.error), 'oxidns-learn-status');
			notifyResult('error', _('Reset failed'));
			return;
		}

		renderResult('success', _('Learned files cleared'), result.detail, 'oxidns-learn-status');
		notifyResult('success', _('Learned files cleared'));
	});
}

function learnRow(label, control, hint) {
	var content = control;

	if (hint)
		content = [control, E('span', {
			'class': 'cbi-value-description',
			'style': 'display: block; margin-top: .35em;'
		}, hint)];

	return E('div', { 'class': 'tr' }, [
		E('div', { 'class': 'td left', 'style': 'width: 240px' }, label),
		E('div', { 'class': 'td left' }, content)
	]);
}

function learnCheckbox(id, label) {
	var input = E('input', {
		'type': 'checkbox',
		'id': id,
		'style': 'margin-right: .35em; vertical-align: middle;'
	});
	var box = E('label', {
		'style': 'margin-right: 1.5em; white-space: nowrap;'
	}, [input, ' ' + label]);

	return { node: box, input: input };
}

function learnResetSection(settings) {
	var s = settings || {};
	var cnBox = learnCheckbox('oxidns-learn-cn', _('Reset learned-cn.txt (learned_cn)'));
	var proxyBox = learnCheckbox('oxidns-learn-proxy', _('Reset learned-proxy.txt (learned_proxy)'));
	var weekdaySelect = E('select', {
		'id': 'oxidns-learn-weekday',
		'class': 'cbi-input-select'
	}, LEARN_WEEKDAYS.map(function(day) {
		return E('option', { 'value': day[0] }, day[1]);
	}));
	var freqSelect = E('select', {
		'id': 'oxidns-learn-freq',
		'class': 'cbi-input-select',
		'style': 'min-width: 160px;'
	}, [
		E('option', { 'value': 'off' }, _('Disabled')),
		E('option', { 'value': 'daily' }, _('Daily')),
		E('option', { 'value': 'weekly' }, _('Weekly'))
	]);
	var timeInput = E('input', {
		'type': 'time',
		'id': 'oxidns-learn-time',
		'style': 'min-width: 120px;'
	});
	var apiUrlInput = E('input', {
		'type': 'text',
		'id': 'oxidns-learn-api-url',
		'class': 'cbi-input-text',
		'style': 'min-width: 280px;'
	});
	var apiUserInput = E('input', {
		'type': 'text',
		'id': 'oxidns-learn-api-user',
		'class': 'cbi-input-text',
		'style': 'min-width: 180px;'
	});
	var apiPassInput = E('input', {
		'type': 'password',
		'id': 'oxidns-learn-api-pass',
		'class': 'cbi-input-text',
		'autocomplete': 'new-password',
		'style': 'min-width: 220px;'
	});

	cnBox.input.checked = s.reset_cn !== false;
	proxyBox.input.checked = s.reset_proxy !== false;
	freqSelect.value = s.freq || 'off';
	weekdaySelect.value = (s.weekday || '1');
	timeInput.value = s.time || '04:00';
	apiUrlInput.value = s.api_url || 'http://127.0.0.1:9199';
	apiUserInput.value = s.api_user || 'admin';
	/* 密码不回显，留空表示保持已存密码 */
	if (s.has_pass)
		apiPassInput.placeholder = '********';

	freqSelect.addEventListener('change', handleLearnFreqChange);

	var weekdayRow = learnRow(_('Day of week'), weekdaySelect);
	weekdayRow.setAttribute('id', 'oxidns-learn-weekday-row');
	weekdayRow.style.display = (freqSelect.value === 'weekly') ? '' : 'none';

	var cronState = s.cron_installed ? _('Installed') : _('Not installed');

	var learnButtons = [
		E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'click': function(ev) {
				ev.preventDefault();
				return saveLearnSchedule(ev.currentTarget);
			}
		}, _('Save schedule')),
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();
				return resetLearnedNow(ev.currentTarget);
			}
		}, _('Reset now'))
	];

	return {
		buttons: learnButtons,
		node: E('div', { 'class': 'cbi-section', 'style': 'margin-top: 1.5em;' }, [
			E('h3', {}, _('Scheduled Reset for Learned Files')),
			E('div', { 'class': 'cbi-map-descr' },
				_('learned-cn.txt and learned-proxy.txt are written automatically by the OxiDNS learn_domain executor (dynamic_domain_set). A scheduled reset clears the selected rule sets through the OxiDNS admin API; no service restart is required.')),
			E('div', { 'class': 'table cbi-section-table', 'style': 'margin-top: .5em;' }, [
				learnRow(_('Learned files'), E('div', {}, [cnBox.node, proxyBox.node])),
				learnRow(_('Schedule'), freqSelect),
				weekdayRow,
				learnRow(_('Reset time'), timeInput),
				learnRow(_('API address'), apiUrlInput),
				learnRow(_('API username'), apiUserInput),
				learnRow(_('API password'), apiPassInput, _('Leave empty to keep the saved password.')),
				learnRow(_('Cron job'), cronState)
			]),
			E('div', {
				'class': 'cbi-button-row',
				'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: 1em;'
			}, learnButtons),
			E('div', { 'id': 'oxidns-learn-status' })
		])
	};
}

return view.extend({
	load: function() {
		return L.resolveDefault(callRulesList(), null).then(function(list) {
			return list || {
				ok: false,
				message: _('Unable to load the rule files.')
			};
		}).catch(function(err) {
			return {
				ok: false,
				message: loadErrorMessage(err)
			};
		}).then(function(list) {
			var files = orderedFiles(list.files || [], list.dir || '');
			var first = null;

			/* 默认打开第一个真实存在的文件（按标签页顺序） */
			files.forEach(function(file) {
				if (first === null && file.exists !== false)
					first = file.name;
			});

			/* 首个文件在 load() 里就读出来，render() 才能同步画出编辑器内容 */
			return L.resolveDefault(first ? callRulesRead(first) : null, null).then(function(file) {
				return Promise.all([
					L.resolveDefault(callStatus(), {}),
					L.resolveDefault(callLearnGet(), null)
				]).then(function(results) {
					return {
						list: list,
						file: file,
						status: results[0] || {},
						learn: results[1]
					};
				});
			});
		});
	},

	render: function(data) {
		var list = data && data.list ? data.list : {};
		var status = data && data.status ? data.status : {};
		var file = data && data.file ? data.file : null;
		var files = orderedFiles(list.files || [], list.dir || '');
		var readFailed = list.ok === false;

		rulesState.dir = list.dir || '';
		rulesState.files = files;
		rulesState.current = file && file.ok !== false ? (file.name || null) : null;
		rulesState.loaded = file && file.ok !== false ? (file.content || '') : null;
		rulesState.mtime = file && file.ok !== false ? (file.mtime || '') : '';

		editorState.resultKind = null;

		var header = [
			E('h2', {}, _('OxiDNS Rule Files')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Edit the rule list files that OxiDNS providers read, then restart the service to apply the changes.'))
		];

		var dirRows = [
			infoRow(_('Rule directory'), 'oxidns-rules-dir', rulesState.dir || '-')
		];

		if (readFailed && !coreInstalled(status)) {
			return E('div', { 'class': 'cbi-map' }, header.concat([
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'alert-message warning', 'style': 'margin: 1em 0;' },
						_('Install the OxiDNS core before editing the rule files.')),
					E('a', {
						'class': 'btn cbi-button cbi-button-action',
						'href': L.url('admin/services/oxidns/core')
					}, _('Install Core'))
				])
			]));
		}

		if (readFailed || !files.length) {
			return E('div', { 'class': 'cbi-map' }, header.concat([
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'alert-message warning', 'style': 'margin: 1em 0;' },
						readFailed
							? (list.message || _('Unable to load the rule files.'))
							: _('No rule files were found in the rule directory.')),
					E('div', { 'class': 'table cbi-section-table' }, dirRows)
				])
			]));
		}

		var loadFailed = !file || file.ok === false;

		var buttons = [
			E('button', {
				'class': 'btn cbi-button cbi-button-positive',
				'click': function(ev) {
					ev.preventDefault();
					return saveRuleFile(ev.currentTarget, false);
				}
			}, _('Save')),
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					ev.preventDefault();
					return saveRuleFile(ev.currentTarget, true);
				}
			}, _('Save & Restart')),
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					ev.preventDefault();
					return discardChanges();
				}
			}, _('Reload'))
		];

		editorState.buttons = buttons;

		var learn = learnResetSection(data && data.learn ? data.learn : {});
		var allButtons = buttons.concat(learn.buttons);

		editorState.buttons = allButtons;

		return E('div', { 'class': 'cbi-map' }, header.concat([
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'table cbi-section-table' }, dirRows.concat([
					E('div', { 'class': 'tr' }, [
						E('div', { 'class': 'td left', 'style': 'width: 240px' }, _('Rule file')),
						E('div', { 'class': 'td left' }, [
							ruleTabs(files, rulesState.current),
							E('span', {
								'class': 'cbi-value-description',
								'style': 'display: block; margin-top: .35em;'
							}, _('One rule per line. Lines starting with # are ignored.'))
						])
					]),
					infoRow(_('Editing'), 'oxidns-rules-current',
						loadFailed ? '-' : (rulesState.current || '-')),
					infoRow(_('Size'), 'oxidns-rules-file-size',
						loadFailed ? '-' : formatBytes(file.size)),
					infoRow(_('Lines'), 'oxidns-rules-file-lines',
						loadFailed ? '-' : formatCount(file.lines)),
					infoRow(_('Modified'), 'oxidns-rules-file-mtime',
						loadFailed ? '-' : formatTime(file.mtime))
				])),
				loadFailed ? E('div', {
					'class': 'alert-message warning',
					'style': 'margin: 1em 0;'
				}, (file && (file.message || file.error)) || readErrorMessage(null)) : '',
				ruleTextarea(loadFailed ? '' : (file.content || '')),
				E('div', {
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: 1em;'
				}, buttons),
				E('div', { 'id': 'oxidns-rules-status' })
			]),
			learn.node
		]));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
