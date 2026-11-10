'use strict';
'require view';
'require rpc';
'require ui';
'require view.oxidns.upload as chunkedUpload';
'require view.oxidns.cmeditor as cmeditor';

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

/*
 * 规则文件可能很大（黑名单动辄几 MB），整份内容同样不能一次发过去：
 * nginx 下请求体超过 client_body_buffer_size 会把 ubus 模块打崩，详见 upload.js。
 */
var callRulesSave = rpc.declare({
	object: 'luci.oxidns',
	method: 'rules_save',
	params: [ 'content_chunk', 'upload_id', 'chunk_offset', 'chunk_newlines', 'chunk_bytes', 'done',
		'name', 'base_mtime', 'restart' ],
	expect: {}
});

var callStatus = rpc.declare({
	object: 'luci.oxidns',
	method: 'status',
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

/*
 * 分块上传要跑好几轮 RPC，给个百分比让用户知道还在动（与配置页同款）。
 * 只有三块以上才值得显示 —— 小块内容一闪而过反而像卡顿。
 */
function uploadProgress(busyText, containerId) {
	var shown = '';

	return function(done, total) {
		var suffix = chunkedUpload.progressSuffix(done, total);

		if (!suffix || suffix === shown)
			return;

		shown = suffix;
		renderResult('notice', busyText + suffix, '', containerId);
	};
}

function runRuleUpload(button, busyText, run, containerId) {
	setBusy(button, true);
	renderResult('notice', busyText, '', containerId);

	return Promise.resolve().then(function() {
		return run(uploadProgress(busyText, containerId));
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

/* 编辑器下方的一行元信息。原来是四行表格，按 mosdns 那个规则栏的密度压成一行淡字，
   四个 id 全部保留 —— showFileInfo() 靠它们更新。 */
function ruleMetaLine(file, name, loadFailed) {
	var info = file || {};
	var known = !loadFailed && info.exists !== false;

	var item = function(label, id, value) {
		return E('span', { 'style': 'white-space: nowrap;' }, [
			label + ' ',
			E('span', { 'id': id }, value)
		]);
	};

	return E('div', {
		'class': 'cbi-value-description',
		'style': 'margin-top: .35em; display: flex; flex-wrap: wrap; gap: 1.25em;'
	}, [
		item(_('Editing'), 'oxidns-rules-current', loadFailed ? '-' : (name || '-')),
		item(_('Size'), 'oxidns-rules-file-size', known ? formatBytes(info.size) : '-'),
		item(_('Lines'), 'oxidns-rules-file-lines', known ? formatCount(info.lines) : '-'),
		item(_('Modified'), 'oxidns-rules-file-mtime', known ? formatTime(info.mtime) : '-')
	]);
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
			cmeditor.setValue(textarea, rulesState.loaded);

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
	var busyText = restart ? _('Saving and restarting service...') : _('Saving rule file...');

	/* 走与配置页相同的分块路径。单次请求体必须远低于 8 KB：uhttpd 的 ubus
	   通道是 64 KB 硬上限，nginx 的 ubus 模块在请求体超过 client_body_buffer_size
	   时 memcpy 一个 NULL 源指针，直接把 worker 打崩。
	   旧代码把 4 个位置参数塞进 9 个字段的 params 声明里，参数整体错位
	   （name 被当成 content_chunk 发走），后端只回 "rule file name is not allowed"。 */
	return runRuleUpload(button, busyText, function(progress) {
		return chunkedUpload.uploadText(content, function(chunk, last, uploadId) {
			return callRulesSave(chunk.text, uploadId, chunk.offset, chunk.newlines, chunk.bytes, last,
				name, String(rulesState.mtime || ''), restart);
		}, progress);
	}).then(function(result) {
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

function applyMissingStyle(tab, missing) {
	tab.style.fontStyle = missing ? 'italic' : '';
	tab.style.opacity = missing ? '.6' : '';
}

/* 横向标签页：切换选中态只改样式，真正加载成功后才更新 data-active */
/* 标签条用 LuCI 原生的 cbi-tabmenu 结构，样式跟着主题走（与 mosdns 的规则栏一致）。
   「文件还不存在」这种状态用斜体 + 半透明表达，不额外造 class。 */
function ruleTabs(files, current) {
	var bar = E('ul', {
		'id': 'oxidns-rules-tabs',
		'class': 'cbi-tabmenu'
	});

	files.forEach(function(file) {
		var active = file.name === current;
		var missing = file.exists === false;
		var tab = E('li', {
			'class': active ? 'cbi-tab' : 'cbi-tab-disabled',
			'data-name': file.name,
			'title': missing ? _('The rule file does not exist yet. Save to create it.') : file.path
		}, file.label);

		applyMissingStyle(tab, missing);
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
		var active = tabName === name;
		var missing = rulesState.files.some(function(file) {
			return file.name === tabName && file.exists === false;
		});

		tab.className = active ? 'cbi-tab' : 'cbi-tab-disabled';
		applyMissingStyle(tab, missing);
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
				return L.resolveDefault(callStatus(), {}).then(function(status) {
					return {
						list: list,
						file: file,
						status: status || {}
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
						'href': L.url('admin/services/oxidns/settings')
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

		var editor = ruleTextarea(loadFailed ? '' : (file.content || ''));

		// 规则文件是纯文本列表: 不指定 mode, 但要 CodeMirror 的固定视口,
		// 否则编辑长列表时页面会跟着光标上下滚动。
		cmeditor.load().then(function() {
			cmeditor.defer(editor);
		});

		return E('div', { 'class': 'cbi-map' }, header.concat([
			E('div', { 'class': 'cbi-section' }, [
				ruleTabs(files, rulesState.current),
				E('div', {
					'class': 'cbi-value-description',
					'style': 'margin: .35em 0 .75em;'
				}, [
					E('span', { 'id': 'oxidns-rules-dir' }, rulesState.dir || '-'),
					' — ',
					_('One rule per line. Lines starting with # are ignored.')
				]),
				loadFailed ? E('div', {
					'class': 'alert-message warning',
					'style': 'margin: 1em 0;'
				}, (file && (file.message || file.error)) || readErrorMessage(null)) : '',
				editor,
				ruleMetaLine(file, rulesState.current, loadFailed),
				E('div', {
					'class': 'cbi-button-row',
					'style': 'display: flex; flex-wrap: wrap; gap: .5em; margin-top: 1em;'
				}, buttons),
				E('div', { 'id': 'oxidns-rules-status' })
			])
		]));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
