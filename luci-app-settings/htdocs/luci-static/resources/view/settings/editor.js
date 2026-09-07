'use strict';
'require view';
'require fs';
'require ui';

var LIST_FILE = '/etc/luci-app-settings.json';
var CHECK_DIR = '/tmp/luci-app-settings';

var PRESET_FILES = [
	{ path: '/etc/config/network',  title: _('Network') },
	{ path: '/etc/config/dhcp',     title: _('DHCP / DNS') },
	{ path: '/etc/config/firewall', title: _('Firewall') },
	{ path: '/etc/config/system',   title: _('System') }
];

function parseCustomList(raw) {
	var list = [];

	try { list = JSON.parse(raw); }
	catch (e) { list = []; }

	if (!Array.isArray(list))
		list = [];

	return list.filter(function(item) {
		return item != null &&
		       typeof(item.path) == 'string' &&
		       item.path.charAt(0) == '/';
	});
}

function detectInitScript(path) {
	var base = path.replace(/^.*\//, '');
	var candidates = [ base ];
	var stripped = base.replace(/\.[^.]+$/, '');

	if (stripped != '' && stripped != base)
		candidates.push(stripped);

	/* e.g. /etc/sing-box/config.json -> "sing-box" */
	var parent = path.replace(/\/[^\/]+$/, '').replace(/^.*\//, '');

	if (parent != '' && parent != 'etc' && candidates.indexOf(parent) == -1)
		candidates.push(parent);

	return candidates.reduce(function(promise, cand) {
		return promise.then(function(found) {
			if (found != null)
				return found;

			return L.resolveDefault(fs.stat('/etc/init.d/' + cand), null).then(function(st) {
				return (st != null && st.type == 'file') ? cand : null;
			});
		});
	}, Promise.resolve(null));
}

/* --- JSONC (JSON with comments) validation --- */

var JSONC_MESSAGES = null;

function jsoncMessage(code) {
	if (JSONC_MESSAGES == null)
		JSONC_MESSAGES = {
			InvalidSymbol:          _('Invalid symbol'),
			InvalidNumberFormat:    _('Invalid number format'),
			PropertyNameExpected:   _('Property name expected'),
			ValueExpected:          _('Value expected'),
			ColonExpected:          _('Colon (":") expected'),
			CommaExpected:          _('Comma (",") expected'),
			CloseBraceExpected:     _('Closing brace ("}") expected'),
			CloseBracketExpected:   _('Closing bracket ("]") expected'),
			EndOfFileExpected:      _('End of file expected'),
			InvalidCommentToken:    _('Invalid comment token'),
			UnexpectedEndOfComment: _('Unterminated comment'),
			UnexpectedEndOfString:  _('Unterminated string'),
			UnexpectedEndOfNumber:  _('Unterminated number'),
			InvalidUnicode:         _('Invalid unicode escape'),
			InvalidEscapeCharacter: _('Invalid escape character'),
			InvalidCharacter:       _('Invalid character')
		};

	return JSONC_MESSAGES[code] || code;
}

function offsetToLineCol(text, offset) {
	var head = text.slice(0, offset).split('\n');

	return { line: head.length, col: head[head.length - 1].length + 1 };
}

/* Degraded check used when the CodeMirror bundle failed to load. */
function strictJsonCheck(text) {
	var res = { errors: [], relaxed: false };

	try {
		JSON.parse(text);
	}
	catch (e) {
		var m = e.message.match(/at position (\d+)/);
		var offset = m ? Math.min(+m[1], text.length) : 0;
		var pos = offsetToLineCol(text, offset);

		res.errors.push({
			from: offset,
			to: offset,
			line: pos.line,
			col: pos.col,
			message: e.message
		});
	}

	return res;
}

/* Validate as JSONC: comments and trailing commas are accepted. Returns
 * { errors: [ { from, to, line, col, message } ], relaxed: bool }, where
 * "relaxed" flags a document that only parses because of that tolerance. */
function jsoncCheck(text) {
	var C = window.__CM6;
	var res = { errors: [], relaxed: false };

	if (text.trim() == '')
		return res;

	if (C == null || C.jsoncParse == null)
		return strictJsonCheck(text);

	var raw = [];

	C.jsoncParse(text, raw, { allowTrailingComma: true, disallowComments: false });

	res.errors = raw.map(function(e) {
		var pos = offsetToLineCol(text, e.offset);

		return {
			from: e.offset,
			to: e.offset + e.length,
			line: pos.line,
			col: pos.col,
			message: jsoncMessage(C.printParseErrorCode(e.error))
		};
	});

	/* Only worth reporting when the document is otherwise clean, and only as a
	 * single hint - one marker per comment would drown a commented config. */
	if (res.errors.length == 0) {
		var strict = [];

		C.jsoncParse(text, strict, { allowTrailingComma: false, disallowComments: true });
		res.relaxed = (strict.length > 0);
	}

	return res;
}

/* Legacy selection based copy - the only option on plain HTTP, where the async
 * clipboard API is not exposed. */
function copyTextLegacy(text) {
	var ta = E('textarea', { 'style': 'position:fixed; top:-1000px; opacity:0' });
	var ok = false;

	ta.value = text;
	document.body.appendChild(ta);
	ta.focus();
	ta.select();

	try { ok = document.execCommand('copy'); }
	catch (e) { ok = false; }

	document.body.removeChild(ta);

	return ok;
}

function copyText(text) {
	var fallback = function() {
		return copyTextLegacy(text) ? Promise.resolve()
			: Promise.reject(new Error(_('Copying failed. The messages above can be selected and copied by hand.')));
	};

	if (navigator.clipboard == null || !window.isSecureContext)
		return fallback();

	/* writeText() can stay pending forever when the document lost focus, so
	 * never let the caller wait on it without an answer. */
	return Promise.race([
		navigator.clipboard.writeText(text),
		new Promise(function(resolveFn, rejectFn) {
			window.setTimeout(function() { rejectFn(new Error('timeout')); }, 2000);
		})
	]).catch(fallback);
}

/* --- CodeMirror 6 integration (bundled as settings/cm6.js, textarea fallback) --- */

function loadCM6() {
	if (window.__CM6 != null)
		return Promise.resolve(true);

	return new Promise(function(resolveFn) {
		var s = document.createElement('script');

		s.src = L.resource('settings/cm6.js') + '?v=2';
		s.onload = function() { resolveFn(window.__CM6 != null); };
		s.onerror = function() { resolveFn(false); };
		document.head.appendChild(s);
	});
}

/* Move the cursor to a document offset and reveal it. */
function jumpToOffset(entry, offset) {
	if (!entry.cmView)
		return;

	var view = entry.cmView;
	var at = Math.max(0, Math.min(offset, view.state.doc.length));

	view.dispatch({ selection: { anchor: at }, scrollIntoView: true });
	view.focus();
}

/* Render the always visible diagnostics list below an editor. The CodeMirror
 * lint tooltip only survives while the pointer rests on the gutter marker,
 * which makes the message impossible to select or copy - this panel keeps the
 * same messages as plain, selectable text. */
function renderDiagnostics(entry, check) {
	var node = entry.diagnode;

	if (node == null)
		return;

	while (node.firstChild)
		node.removeChild(node.firstChild);

	var errors = (check != null) ? check.errors : [];

	if (errors.length == 0) {
		if (check == null || !check.relaxed) {
			node.style.display = 'none';
			return;
		}

		node.style.display = '';
		node.appendChild(E('div', { 'class': 'cbi-section-descr' },
			_('This file uses relaxed JSON syntax (comments and/or trailing commas), which is accepted here. Make sure the target program understands it as well.')));

		return;
	}

	var lines = errors.map(function(e) {
		return _('line %d, column %d: %s').format(e.line, e.col, e.message);
	});

	node.style.display = '';
	node.appendChild(E('div', { 'style': 'margin-bottom:.25em' }, [
		E('strong', {}, [ _('JSON syntax errors (%d)').format(errors.length) ]),
		' ',
		E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'style': 'padding:0 .5em',
			'click': function(ev) {
				var btn = ev.currentTarget;

				copyText(lines.join('\n') + '\n').then(function() {
					ui.addNotification(null, E('p', _('Error messages copied to the clipboard.')), 'info');
				}).catch(function(err) {
					ui.addNotification(null, E('p', err.message));
				});

				btn.blur();
			}
		}, [ _('Copy') ])
	]));

	node.appendChild(E('ul', {
		'style': 'margin:0; padding-left:1.5em; user-select:text; -webkit-user-select:text'
	}, errors.map(function(e, i) {
		var row = [ document.createTextNode(lines[i]) ];

		if (entry.cmView) {
			row.push(' ');
			row.push(E('a', {
				'href': '#',
				'click': function(ev) {
					ev.preventDefault();
					jumpToOffset(entry, e.from);
				}
			}, [ _('jump to') ]));
		}

		return E('li', { 'style': 'margin:.15em 0' }, row);
	})));
}

/* Lint source for .json files: tolerates comments and trailing commas, and
 * mirrors every diagnostic into the panel rendered by renderDiagnostics(). */
function jsoncLintSource(entry) {
	return function(view) {
		var text = view.state.doc.toString();
		var max = view.state.doc.length;
		var check = jsoncCheck(text);

		renderDiagnostics(entry, check);

		return check.errors.map(function(e) {
			var from = Math.min(e.from, max);

			return {
				from: from,
				to: Math.min(Math.max(e.to, from + 1), max),
				severity: 'error',
				message: e.message
			};
		});
	};
}

var uciLang = null, jsonLang = null, shellLang = null;

function languageExtensions(entry) {
	var C = window.__CM6;
	var path = entry.path;

	if (/\.json$/.test(path)) {
		if (jsonLang == null)
			jsonLang = C.StreamLanguage.define(C.jsonMode);

		return [
			jsonLang,
			C.lintGutter(),
			C.linter(jsoncLintSource(entry), { delay: 400 })
		];
	}

	if (/^\/etc\/config\//.test(path)) {
		if (uciLang == null)
			uciLang = C.StreamLanguage.define({
				startState: function() { return { n: 0 }; },
				token: function(stream, st) {
					if (stream.sol())
						st.n = 0;

					if (stream.eatSpace())
						return null;

					if (stream.match(/^#.*/))
						return 'comment';

					var idx = st.n++;

					if (stream.match(/^'([^'\\]|\\.)*'/) || stream.match(/^"([^"\\]|\\.)*"/))
						return 'string';

					if (stream.match(/^['"].*/))
						return 'invalid';

					if (stream.match(/^[^\s#'"]+/)) {
						if (idx == 0)
							return /^(config|option|list|package)$/.test(stream.current())
								? 'keyword' : 'invalid';

						return (idx == 1) ? 'variableName' : 'atom';
					}

					stream.next();
					return null;
				}
			});

		return [ uciLang, C.lintGutter() ];
	}

	if (/\.sh$/.test(path) || /^\/etc\/init\.d\//.test(path) || /^\/etc\/rc\./.test(path)) {
		if (shellLang == null)
			shellLang = C.StreamLanguage.define(C.shell);

		return [ shellLang ];
	}

	return [];
}

function createEditor(entry) {
	var C = window.__CM6;
	var dark = (window.matchMedia != null) &&
	           window.matchMedia('(prefers-color-scheme: dark)').matches;

	var exts = [
		C.lineNumbers(),
		C.highlightActiveLineGutter(),
		C.highlightSpecialChars(),
		C.history(),
		C.drawSelection(),
		C.indentOnInput(),
		C.syntaxHighlighting(C.defaultHighlightStyle, { fallback: true }),
		C.bracketMatching(),
		C.highlightActiveLine(),
		C.highlightSelectionMatches(),
		C.keymap.of([].concat(C.defaultKeymap, C.historyKeymap, C.searchKeymap,
			C.lintKeymap, [ C.indentWithTab ])),
		C.EditorView.theme({
			'&': { 'height': '34em', 'border': '1px solid #999', 'font-size': '13px' },
			'.cm-scroller': { 'font-family': 'SFMono-Regular, Consolas, Menlo, monospace', 'overflow': 'auto' }
		})
	].concat(languageExtensions(entry));

	if (dark)
		exts.push(C.oneDark);

	entry.cmView = new C.EditorView({
		state: C.EditorState.create({ doc: entry.content, extensions: exts })
	});

	return entry.cmView.dom;
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		var self = this;

		return loadCM6().then(function() {
			return L.resolveDefault(fs.read(LIST_FILE), '');
		}).then(function(raw) {
			self.customList = parseCustomList(raw);

			var entries = PRESET_FILES.map(function(p) {
				return {
					path: p.path,
					title: p.title,
					custom: false
				};
			}).concat(self.customList.map(function(c) {
				return {
					path: c.path,
					title: c.path.replace(/^.*\//, ''),
					service: (typeof(c.service) == 'string') ? c.service : '',
					custom: true
				};
			}));

			return Promise.all(entries.map(function(entry) {
				return Promise.all([
					L.resolveDefault(fs.stat(entry.path), null),
					L.resolveDefault(fs.read(entry.path), null),
					(entry.custom && entry.service == '')
						? detectInitScript(entry.path) : Promise.resolve(null)
				]).then(function(res) {
					entry.stat = res[0];
					entry.exists = (res[0] != null);
					entry.content = (res[1] != null) ? res[1] : '';
					entry.detected = res[2];
					return entry;
				});
			}));
		});
	},

	statLine: function(entry) {
		if (!entry.exists)
			return _('%s — file does not exist yet, it will be created when saving.').format(entry.path);

		return _('%s — %d bytes, last modified: %s').format(
			entry.path,
			entry.stat.size,
			new Date(entry.stat.mtime * 1000).toLocaleString());
	},

	getValue: function(entry) {
		return entry.cmView ? entry.cmView.state.doc.toString() : entry.textarea.value;
	},

	setValue: function(entry, value) {
		if (entry.cmView) {
			if (entry.cmView.state.doc.toString() != value)
				entry.cmView.dispatch({
					changes: { from: 0, to: entry.cmView.state.doc.length, insert: value }
				});
		}
		else {
			entry.textarea.value = value;
		}
	},

	clearDiagnostics: function(entry) {
		renderDiagnostics(entry, null);

		if (entry.cmView)
			entry.cmView.dispatch(window.__CM6.setDiagnostics(entry.cmView.state, []));
	},

	markErrorLine: function(entry, line, message) {
		if (!entry.cmView)
			return;

		var C = window.__CM6;
		var view = entry.cmView;
		var lnum = Math.max(1, Math.min(line || 1, view.state.doc.lines));
		var info = view.state.doc.line(lnum);

		view.dispatch(C.setDiagnostics(view.state, [
			{ from: info.from, to: info.to, severity: 'error', message: message }
		]));
		view.dispatch({ selection: { anchor: info.from }, scrollIntoView: true });
		view.focus();
	},

	validateJsonSyntax: function(entry, value) {
		if (!/\.json$/.test(entry.path) || value.trim() == '')
			return Promise.resolve(null);

		var check = jsoncCheck(value);

		renderDiagnostics(entry, check);

		if (check.errors.length == 0)
			return Promise.resolve(null);

		var first = check.errors[0];
		var err = new Error(_('JSON syntax check failed at line %d, column %d: %s')
			.format(first.line, first.col, first.message));

		err.line = first.line;
		err.offset = first.from;

		return Promise.reject(err);
	},

	validateUciSyntax: function(path, value) {
		var m = path.match(/^\/etc\/config\/([^\/]+)$/);

		if (m == null)
			return Promise.resolve(null);

		var name = m[1];

		return fs.exec('/bin/mkdir', [ '-p', CHECK_DIR ]).then(function() {
			return fs.write(CHECK_DIR + '/' + name, value, 384 /* 0600 */);
		}).then(function() {
			return fs.exec('/sbin/uci', [ '-c', CHECK_DIR, 'show', name ]);
		}).then(function(res) {
			if (res.code !== 0) {
				var msg = (res.stderr || res.stdout || '').trim();
				var err = new Error(_('UCI syntax check failed: %s').format(msg));
				var lm = msg.match(/at line (\d+)/);

				err.line = lm ? +lm[1] : null;
				throw err;
			}

			return null;
		});
	},

	confirmSaveAnyway: function(err) {
		return new Promise(function(resolveFn) {
			var done = function(ok) {
				ui.hideModal();
				resolveFn(ok);
			};

			ui.showModal(_('JSON syntax error'), [
				E('p', {}, err.message),
				E('p', {}, _('Comments and trailing commas are already accepted, so this is a genuine syntax error. You can still save the file as-is if the target program tolerates it.')),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': function() { done(false); }
					}, [ _('Cancel') ]),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-negative important',
						'click': function() { done(true); }
					}, [ _('Save anyway') ])
				])
			]);
		});
	},

	applyEntry: function(entry) {
		var cmd, args, what;

		if (entry.custom && entry.service != '') {
			cmd  = '/etc/init.d/' + entry.service;
			args = [ 'restart' ];
			what = _('Service "%s" has been restarted.').format(entry.service);
		}
		else {
			cmd  = '/sbin/reload_config';
			args = [];
			what = _('Changed configuration files were applied via reload_config.');
		}

		return fs.exec(cmd, args).then(function(res) {
			if (res.code !== 0)
				throw new Error(_('Command failed with exit code %d: %s').format(
					res.code, (res.stderr || res.stdout || '').trim()));

			ui.addNotification(null, E('p', [
				_('Contents of %s have been saved and applied.').format(entry.path),
				' ',
				what
			]), 'info');
		}).catch(function(err) {
			ui.addNotification(null, E('p',
				_('File was saved, but applying the changes failed: %s').format(err.message)));
		});
	},

	doSave: function(entry, apply) {
		var self = this;
		var value = self.getValue(entry).replace(/\r\n/g, '\n');

		if (value.length > 0 && value.charAt(value.length - 1) != '\n')
			value += '\n';

		return self.validateJsonSyntax(entry, value).catch(function(err) {
			if (err.offset != null)
				jumpToOffset(entry, err.offset);
			else if (err.line != null)
				self.markErrorLine(entry, err.line, err.message);

			return self.confirmSaveAnyway(err).then(function(confirmed) {
				if (!confirmed) {
					var abort = new Error(err.message);
					abort.cancelled = true;
					throw abort;
				}
			});
		}).then(function() {
			return self.validateUciSyntax(entry.path, value);
		}).then(function() {
			return fs.write(entry.path, value, 420 /* 0644 */);
		}).then(function() {
			self.clearDiagnostics(entry);
			self.setValue(entry, value);

			return L.resolveDefault(fs.stat(entry.path), null).then(function(st) {
				entry.stat = st;
				entry.exists = (st != null);
				entry.statnode.textContent = self.statLine(entry);
			});
		}).then(function() {
			if (!apply) {
				ui.addNotification(null, E('p',
					_('Contents of %s have been saved.').format(entry.path)), 'info');
				return null;
			}

			return self.applyEntry(entry);
		}).catch(function(err) {
			if (err.cancelled) {
				ui.addNotification(null, E('p',
					_('Save cancelled: %s was not modified and no apply action was performed.').format(entry.path)), 'info');
				return;
			}

			if (err.line != null)
				self.markErrorLine(entry, err.line, err.message);

			ui.addNotification(null, E('p', [
				_('Unable to save %s: %s').format(entry.path, err.message),
				' ',
				_('The file on disk was not modified and no apply action was performed.')
			]));
		});
	},

	writeCustomList: function(list) {
		return fs.write(LIST_FILE, JSON.stringify(list, null, '\t') + '\n', 420 /* 0644 */);
	},

	handleAddSave: function(pathinput, svcinput, ev) {
		var self = this;
		var path = pathinput.value.trim();
		var svc = svcinput.value.trim();

		if (path == '' || path.charAt(0) != '/') {
			ui.addNotification(null, E('p', _('Please enter an absolute file path below /etc/.')));
			return null;
		}

		if (!/^\/etc\/[A-Za-z0-9._/-]+$/.test(path) ||
		    path.indexOf('..') != -1 ||
		    path.charAt(path.length - 1) == '/') {
			ui.addNotification(null, E('p', _('Invalid file path.')));
			return null;
		}

		var dup = PRESET_FILES.some(function(p) { return p.path == path; }) ||
		          self.customList.some(function(c) { return c.path == path; });

		if (dup) {
			ui.addNotification(null, E('p', _('This file is already in the list.')));
			return null;
		}

		if (svc != '' && !/^[A-Za-z0-9._-]+$/.test(svc)) {
			ui.addNotification(null, E('p', _('Invalid service name.')));
			return null;
		}

		var newList = self.customList.concat([ { path: path, service: svc } ]);

		return self.writeCustomList(newList).then(function() {
			ui.hideModal();
			window.location.reload();
		}).catch(function(err) {
			ui.addNotification(null, E('p',
				_('Failed to update the custom file list: %s').format(err.message)));
		});
	},

	handleAddFile: function(ev) {
		var self = this;

		var pathinput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%',
			'placeholder': '/etc/sysctl.conf'
		});

		var svcinput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%',
			'placeholder': 'dnsmasq'
		});

		var matchbadge = E('span', {
			'style': 'display:none; margin-left:.5em; color:#00a000; white-space:nowrap'
		}, [ _('Matched') ]);

		var detectTimer = null;

		var runDetect = function() {
			var path = pathinput.value.trim();

			if (!/^\/etc\/[A-Za-z0-9._/-]+$/.test(path) ||
			    path.indexOf('..') != -1 ||
			    path.charAt(path.length - 1) == '/') {
				matchbadge.style.display = 'none';
				return;
			}

			detectInitScript(path).then(function(cand) {
				if (cand != null) {
					if (svcinput.value == '' || svcinput.getAttribute('data-auto') == '1') {
						svcinput.value = cand;
						svcinput.setAttribute('data-auto', '1');
					}

					matchbadge.style.display = (svcinput.value == cand) ? '' : 'none';
				}
				else {
					matchbadge.style.display = 'none';

					if (svcinput.getAttribute('data-auto') == '1') {
						svcinput.value = '';
						svcinput.removeAttribute('data-auto');
					}
				}
			});
		};

		pathinput.addEventListener('input', function() {
			if (detectTimer != null)
				window.clearTimeout(detectTimer);

			detectTimer = window.setTimeout(runDetect, 400);
		});

		svcinput.addEventListener('input', function() {
			svcinput.removeAttribute('data-auto');
			matchbadge.style.display = 'none';
		});

		ui.showModal(_('Add custom file'), [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('File path') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					pathinput,
					E('div', { 'class': 'cbi-value-description' },
						_('Absolute path under /etc/, e.g. /etc/sysctl.conf.'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Init script to restart on apply (optional)') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', { 'style': 'display:flex; align-items:center' }, [
						svcinput,
						matchbadge
					]),
					E('div', { 'class': 'cbi-value-description' },
						_('init.d service name; leave empty to run reload_config.'))
				])
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-positive important',
					'click': ui.createHandlerFn(self, 'handleAddSave', pathinput, svcinput)
				}, [ _('Add') ])
			])
		]);

		pathinput.focus();
	},

	handleResetEntry: function(entry, ev) {
		var self = this;

		return Promise.all([
			L.resolveDefault(fs.stat(entry.path), null),
			L.resolveDefault(fs.read(entry.path), null)
		]).then(function(res) {
			entry.stat = res[0];
			entry.exists = (res[0] != null);
			entry.content = (res[1] != null) ? res[1] : '';
			self.clearDiagnostics(entry);
			self.setValue(entry, entry.content);
			entry.statnode.textContent = self.statLine(entry);

			ui.addNotification(null, E('p',
				_('Contents of %s have been reloaded from disk.').format(entry.path)), 'info');
		});
	},

	handleRemoveEntry: function(entry, ev) {
		var self = this;
		var newList = self.customList.filter(function(c) { return c.path != entry.path; });

		return self.writeCustomList(newList).then(function() {
			window.location.reload();
		}).catch(function(err) {
			ui.addNotification(null, E('p',
				_('Failed to update the custom file list: %s').format(err.message)));
		});
	},

	renderPane: function(entry, idx) {
		var self = this;

		entry.statnode = E('div', { 'class': 'cbi-section-descr' });
		entry.statnode.textContent = self.statLine(entry);

		entry.diagnode = E('div', { 'style': 'display:none; margin:.5em 0' });

		var children = [ entry.statnode ];

		if (window.__CM6 != null) {
			children.push(createEditor(entry));
		}
		else {
			entry.textarea = E('textarea', {
				'style': 'width:100%; font-family:monospace; white-space:pre;',
				'rows': 25,
				'wrap': 'off',
				'spellcheck': 'false'
			});

			entry.textarea.value = entry.content;
			children.push(entry.textarea);
		}

		children.push(entry.diagnode);

		if (entry.custom) {
			var applyText;

			if (entry.service != '') {
				applyText = _('Apply action: restart service "%s".').format(entry.service);
			}
			else {
				applyText = _('Apply action: run reload_config (this only reloads services for files under /etc/config).');

				if (entry.detected)
					applyText += ' ' + _('Detected init.d script with the same name: "%s".').format(entry.detected);
			}

			children.push(E('div', { 'class': 'cbi-section-descr' }, applyText));
		}

		var btns = [
			E('button', {
				'class': 'cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, 'doSave', entry, true)
			}, [ _('Save & Apply') ]),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-save',
				'click': ui.createHandlerFn(self, 'doSave', entry, false)
			}, [ _('Save') ]),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(self, 'handleResetEntry', entry)
			}, [ _('Reset') ])
		];

		if (entry.custom)
			btns.push(' ', E('button', {
				'class': 'cbi-button cbi-button-remove',
				'click': ui.createHandlerFn(self, 'handleRemoveEntry', entry)
			}, [ _('Remove from list') ]));

		children.push(E('div', { 'class': 'cbi-page-actions' }, btns));

		var pane = E('div', {
			'data-tab': 'file' + idx,
			'data-tab-title': entry.title
		}, children);

		pane.addEventListener('cbi-tab-active', function() {
			if (entry.cmView)
				entry.cmView.requestMeasure();
		});

		return pane;
	},

	render: function(entries) {
		var self = this;

		self.entries = entries;

		var paneContainer = E('div', {}, entries.map(function(entry, idx) {
			return self.renderPane(entry, idx);
		}));

		var node = E('div', {}, [
			E('h2', {}, [ _('Configuration Files') ]),
			E('div', { 'class': 'cbi-map-descr' },
				_('Directly edit the raw contents of common UCI configuration files under /etc/config and apply the changes. Custom files can be added to the list with the button below.')),
			E('div', { 'style': 'margin-bottom:1em' }, [
				E('button', {
					'class': 'cbi-button cbi-button-add',
					'click': ui.createHandlerFn(self, 'handleAddFile')
				}, [ _('Add custom file…') ])
			]),
			paneContainer
		]);

		ui.tabs.initTabGroup(paneContainer.childNodes);

		return node;
	}
});
