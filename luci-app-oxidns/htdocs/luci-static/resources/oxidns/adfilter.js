'use strict';
'require baseclass';

/*
 * Guided ad filtering is a small managed plugin group:
 *
 *   download -> writes subscription files into a persistent directory
 *   adguard_rule -> matches the downloaded and inline AdGuard rules
 *   black_hole -> answers matching queries locally
 *
 * The group is wired into every entry sequence at the front. The tags are
 * fixed so the operation stays idempotent across saves; collisions with a
 * user plugin are reported instead of overwritten.
 */

var TAGS = {
	download: 'oxidns_ads_download',
	rules: 'oxidns_ads_rules',
	block: 'oxidns_ads_block'
};

var TYPES = {
	download: 'download',
	rules: 'adguard_rule',
	block: 'black_hole'
};

var SERVER_TYPES = {
	'udp_server': true,
	'tcp_server': true,
	'quic_server': true,
	'http_server': true
};

var BLOCK_MODES = [ 'nxdomain', 'nodata', 'null', 'custom', 'refused' ];
var DEFAULT_MODE = 'nxdomain';
var DEFAULT_DIR = '/etc/oxidns/rules';
var FILE_PREFIX = 'oxidns-ads-';

function text(value) {
	if (value === null || value === undefined)
		return '';
	if (typeof value === 'object')
		return '';
	return String(value);
}

function plain(value) {
	if (value && typeof value.toJSON === 'function')
		return value.toJSON();
	return value;
}

function at(doc, path) {
	return plain(doc.getIn(path, true));
}

function pluginItems(doc) {
	var seq = doc.getIn([ 'plugins' ], true);
	return seq && seq.items ? seq.items : [];
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

function findPlugin(doc, tag) {
	var items = pluginItems(doc);

	for (var i = 0; i < items.length; i++) {
		if (pluginTag(items[i], i) === tag)
			return { 'item': items[i], 'index': i };
	}

	return null;
}

function managedPlugins(doc) {
	var result = { 'download': null, 'rules': null, 'block': null, 'collisions': [] };

	pluginItems(doc).forEach(function(item, index) {
		var tag = pluginTag(item, index);
		var type = pluginType(item);

		Object.keys(TAGS).forEach(function(key) {
			if (tag !== TAGS[key])
				return;

			if (type === TYPES[key])
				result[key] = { 'item': item, 'index': index };
			else
				result.collisions.push({ 'tag': tag, 'type': type, 'expected': TYPES[key] });
		});
	});

	return result;
}

function pluginArgs(item) {
	if (!item || typeof item.get !== 'function')
		return null;

	var args = item.get('args');
	return args && typeof args.get === 'function' ? args : null;
}

/*
 * Mappings and sequences both expose "items", so a hand-written "args: {}"
 * can look like a list to a plain Array.isArray() check. Inspect the first
 * item and fall back to toJSON() for empty collections.
 */
function isListNode(node) {
	if (!node || !Array.isArray(node.items))
		return false;

	if (node.items.length)
		return !('key' in node.items[0] && 'value' in node.items[0]);

	try {
		return Array.isArray(node.toJSON());
	}
	catch (err) {
		return false;
	}
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

function serverEntries(doc) {
	var entries = [];

	pluginItems(doc).forEach(function(item) {
		var type = pluginType(item);
		var args = pluginArgs(item);

		if (!args || !SERVER_TYPES[type])
			return;

		if (type === 'http_server') {
			var list = args.get('entries');

			if (list && Array.isArray(list.items))
				list.items.forEach(function(entry) {
					if (entry && typeof entry.get === 'function')
						entries.push(text(entry.get('exec')));
				});
		}
		else {
			entries.push(text(args.get('entry')));
		}
	});

	return entries;
}

/*
 * Ad filtering is inserted into every sequence that a server uses as its
 * entry point. Configurations without a server fall back to main_sequence,
 * then to the only sequence in the file.
 */
function targetSequences(doc) {
	var known = sequenceTags(doc);
	var result = [];

	serverEntries(doc).forEach(function(tag) {
		if (tag && known[tag] && result.indexOf(tag) === -1)
			result.push(tag);
	});

	if (result.length)
		return result;

	if (known.main_sequence)
		return [ 'main_sequence' ];

	var all = Object.keys(known);
	return all.length === 1 ? all : [];
}

function lines(value) {
	return String(value || '').split('\n').map(function(line) {
		return line.trim();
	}).filter(function(line) {
		return line.length > 0;
	});
}

function listValue(value) {
	return Array.isArray(value) ? value.map(text) : [];
}

function addresses(value) {
	return String(value || '').split(/[\s,]+/).map(function(entry) {
		return entry.trim();
	}).filter(function(entry) {
		return entry.length > 0;
	});
}

function isAbsolutePath(value) {
	return value.charAt(0) === '/';
}

function isHttpUrl(value) {
	return /^https?:\/\/[^\/?#\s]+(?:[\/?#]\S*)?$/i.test(value);
}

function isIpAddress(value) {
	if (/^(\d{1,3}\.){3}\d{1,3}$/.test(value)) {
		var parts = value.split('.');
		for (var i = 0; i < parts.length; i++) {
			if (Number(parts[i]) > 255)
				return false;
		}
		return true;
	}

	return value.indexOf(':') !== -1 && /^[0-9a-fA-F:.]+$/.test(value);
}

function filenameFromUrl(url) {
	var clean = String(url || '').split('#')[0].split('?')[0];
	var base = clean.substring(clean.lastIndexOf('/') + 1);

	try {
		base = decodeURIComponent(base);
	}
	catch (err) {
		/* Keep the raw segment when it is not valid percent-encoding. */
	}

	base = base.replace(/[^A-Za-z0-9._-]+/g, '_').replace(/^[._]+/, '');

	if (!base)
		base = 'rules.txt';

	if (base.length > 80)
		base = base.slice(0, 80);

	return base.indexOf(FILE_PREFIX) === 0 ? base : FILE_PREFIX + base;
}

function uniqueFilename(base, used) {
	var name = base;
	var suffix = 2;

	while (used[name]) {
		var dot = base.lastIndexOf('.');
		name = dot > 0
			? base.slice(0, dot) + '-' + suffix + base.slice(dot)
			: base + '-' + suffix;
		suffix++;
	}

	used[name] = true;
	return name;
}

function joinPath(dir, filename) {
	var base = String(dir || '').replace(/\/+$/, '');
	return (base || '') + '/' + filename;
}

function currentDownloads(doc, state) {
	if (!state || !state.download)
		return [];

	var args = pluginArgs(state.download.item);
	var downloads = args ? plain(args.get('downloads')) : null;

	return Array.isArray(downloads) ? downloads : [];
}

function generatedPaths(downloads) {
	return (downloads || []).map(function(entry) {
		var dir = text(entry && entry.dir);
		var filename = text(entry && entry.filename) || filenameFromUrl(text(entry && entry.url));
		return dir && filename ? joinPath(dir, filename) : '';
	}).filter(function(path) {
		return path.length > 0;
	});
}

function basename(path) {
	return String(path || '').substring(String(path || '').lastIndexOf('/') + 1);
}

/*
 * Files written by the managed download plugin are identified by the
 * filename each subscription generates. Matching the basename instead of
 * the reserved prefix keeps a user file such as oxidns-ads-custom.txt
 * editable while still hiding files generated for a previous rules
 * directory.
 */
function generatedFilenames(downloads) {
	var names = {};

	(downloads || []).forEach(function(entry) {
		var filename = text(entry && entry.filename) || filenameFromUrl(text(entry && entry.url));
		if (filename)
			names[filename] = true;
	});

	return names;
}

function readValues(doc, state) {
	var values = {
		'urlsText': '',
		'rulesText': '',
		'filesText': '',
		'ipsText': '',
		'mode': DEFAULT_MODE,
		'dir': DEFAULT_DIR,
		'hasDownload': !!(state && state.download),
		'hasRules': !!(state && state.rules),
		'hasBlock': !!(state && state.block)
	};

	if (state && state.rules) {
		var rulesArgs = pluginArgs(state.rules.item);

		if (rulesArgs) {
			values.rulesText = listValue(plain(rulesArgs.get('rules'))).join('\n');
			values.filesText = listValue(plain(rulesArgs.get('files'))).join('\n');
		}
	}

	if (state && state.block) {
		var blockArgs = pluginArgs(state.block.item);

		if (blockArgs) {
			var mode = text(plain(blockArgs.get('mode')));
			values.mode = mode || DEFAULT_MODE;
			values.ipsText = listValue(plain(blockArgs.get('ips'))).join(' ');
		}
	}

	if (state && state.download) {
		var downloads = currentDownloads(doc, state);
		var generated = generatedPaths(downloads);
		var generatedNames = generatedFilenames(downloads);

		values.urlsText = downloads.map(function(entry) {
			return text(entry && entry.url);
		}).filter(function(url) {
			return url.length > 0;
		}).join('\n');

		if (downloads.length) {
			var dir = text(downloads[0] && downloads[0].dir);
			if (dir)
				values.dir = dir;
		}

		/*
		 * Generated files are derived from the subscription entries. Keep
		 * only the extra local files in the editable list, matching both the
		 * full current paths and the generated filenames so a changed rules
		 * directory does not leave stale generated paths behind.
		 */
		values.filesText = lines(values.filesText).filter(function(path) {
			return generated.indexOf(path) === -1 && !generatedNames[basename(path)];
		}).join('\n');
	}

	return values;
}

function collisionProblems(collisions) {
	return collisions.map(function(collision) {
		return _('The tag %s is already used by a %s plugin. Rename it in Advanced Mode before using ad filtering.')
			.format(collision.tag, collision.type || _('unknown'));
	});
}

function buildDownloads(doc, state, urls, dir) {
	var existing = currentDownloads(doc, state);
	var byUrl = {};
	var used = {};

	existing.forEach(function(entry) {
		var url = text(entry && entry.url);
		var filename = text(entry && entry.filename);

		if (url && filename && filename.indexOf('/') === -1 && !byUrl[url])
			byUrl[url] = filename;
	});

	return urls.map(function(url) {
		var filename = byUrl[url];

		if (!filename)
			filename = filenameFromUrl(url);

		filename = uniqueFilename(filename, used);

		return {
			'url': url,
			'dir': dir || DEFAULT_DIR,
			'filename': filename
		};
	});
}

function setValue(doc, path, value) {
	if (at(doc, path) === value)
		return;

	doc.setIn(path, value);
}

function setList(doc, path, values) {
	var current = at(doc, path);
	var list = values || [];

	if (!list.length) {
		if (current !== undefined && current !== null)
			doc.deleteIn(path);
		return;
	}

	var same = Array.isArray(current) && current.length === list.length;

	if (same) {
		for (var i = 0; i < list.length; i++) {
			if (text(current[i]) !== list[i]) {
				same = false;
				break;
			}
		}
	}

	if (!same)
		doc.setIn(path, doc.createNode(list));
}

function setDownloads(doc, state, entries) {
	if (!state || !state.download)
		return;

	var path = [ 'plugins', state.download.index, 'args', 'downloads' ];
	var current = at(doc, path);
	var same = Array.isArray(current) && current.length === entries.length;

	if (same) {
		for (var i = 0; i < entries.length; i++) {
			var entry = entries[i] || {};
			var previous = current[i] || {};

			if (text(previous.url) !== entry.url ||
			    text(previous.dir) !== entry.dir ||
			    text(previous.filename) !== entry.filename) {
				same = false;
				break;
			}
		}
	}

	if (same)
		return;

	if (!entries.length)
		doc.deleteIn(path);
	else
		doc.setIn(path, doc.createNode(entries));
}

function ensurePlugin(doc, tag, type, args) {
	var found = findPlugin(doc, tag);

	if (found)
		return pluginType(found.item) === type ? found : null;

	var plugins = doc.getIn([ 'plugins' ], true);

	if (!plugins)
		doc.setIn([ 'plugins' ], doc.createNode([]));

	doc.addIn([ 'plugins' ], doc.createNode({
		'tag': tag,
		'type': type,
		'args': args || {}
	}));

	return findPlugin(doc, tag);
}

function ensureBlockDefaults(doc) {
	var state = managedPlugins(doc);
	if (!state.block)
		return;

	var args = pluginArgs(state.block.item);
	if (!args)
		return;

	var path = [ 'plugins', state.block.index, 'args' ];

	if (!text(at(doc, path.concat([ 'mode' ]))))
		doc.setIn(path.concat([ 'mode' ]), DEFAULT_MODE);

	setValue(doc, path.concat([ 'short_circuit' ]), true);
}

function sequenceNode(doc, tag) {
	var known = sequenceTags(doc);

	if (!known[tag])
		return null;

	var found = findPlugin(doc, tag);

	if (!found)
		return null;

	var args = found.item.get('args');
	return isListNode(args) ? args : null;
}

function managedStep(step) {
	return step && typeof step.get === 'function' &&
		text(step.get('exec')) === '$' + TAGS.block;
}

function ensureWiring(doc, targets) {
	var failed = [];

	(targets || []).forEach(function(tag) {
		var args = sequenceNode(doc, tag);

		if (!args) {
			failed.push(tag);
			return;
		}

		var found = -1;

		for (var i = args.items.length - 1; i >= 0; i--) {
			if (!managedStep(args.items[i]))
				continue;

			if (found !== -1)
				args.items.splice(i, 1);
			else
				found = i;
		}

		if (found === -1) {
			args.items.unshift(doc.createNode({
				'matches': 'qname $' + TAGS.rules,
				'exec': '$' + TAGS.block
			}));
		}
	});

	return failed;
}

function removeWiring(doc) {
	pluginItems(doc).forEach(function(item) {
		if (pluginType(item) !== 'sequence')
			return;

		var args = item.get('args');

		if (!isListNode(args))
			return;

		for (var i = args.items.length - 1; i >= 0; i--) {
			if (managedStep(args.items[i]))
				args.items.splice(i, 1);
		}
	});
}

function removeManagedPlugins(doc) {
	var state = managedPlugins(doc);
	var indexes = [];

	Object.keys(TAGS).forEach(function(key) {
		if (state[key])
			indexes.push(state[key].index);
	});

	indexes.sort(function(a, b) {
		return b - a;
	}).forEach(function(index) {
		doc.deleteIn([ 'plugins', index ]);
	});
}

function wiringMissing(doc, targets) {
	return (targets || []).filter(function(tag) {
		var args = sequenceNode(doc, tag);

		if (!args)
			return true;

		return !args.items.some(managedStep);
	});
}

function sameLineList(a, b) {
	if (a.length !== b.length)
		return false;

	for (var i = 0; i < a.length; i++) {
		if (a[i] !== b[i])
			return false;
	}

	return true;
}

function normalizedValues(values) {
	values = values || {};

	return {
		'urls': lines(values.urlsText),
		'rules': lines(values.rulesText),
		'files': lines(values.filesText),
		'mode': text(values.mode),
		'ips': addresses(values.ipsText),
		'dir': text(values.dir).trim() || DEFAULT_DIR
	};
}

function sameValues(a, b) {
	return sameLineList(a.urls, b.urls) &&
		sameLineList(a.rules, b.rules) &&
		sameLineList(a.files, b.files) &&
		sameLineList(a.ips, b.ips) &&
		a.mode === b.mode &&
		a.dir === b.dir;
}

return baseclass.extend({
	tags: TAGS,
	modes: BLOCK_MODES,

	manages: function(tag, type) {
		for (var key in TAGS) {
			if (TAGS[key] === tag && TYPES[key] === type)
				return true;
		}

		return false;
	},

	inspect: function(doc) {
		var state = managedPlugins(doc);

		return {
			'configured': !!(state.download || state.rules || state.block || state.collisions.length),
			'collisions': state.collisions,
			'problems': collisionProblems(state.collisions),
			'targets': targetSequences(doc),
			'values': readValues(doc, state)
		};
	},

	enable: function(doc) {
		var state = managedPlugins(doc);
		var problems = collisionProblems(state.collisions);

		if (problems.length)
			return { 'ok': false, 'problems': problems };

		var targets = targetSequences(doc);

		if (!targets.length)
			return {
				'ok': false,
				'problems': [ _('No entry sequence was found. Configure a server entry in Advanced Mode first.') ]
			};

		ensurePlugin(doc, TAGS.rules, TYPES.rules, {});
		ensurePlugin(doc, TAGS.block, TYPES.block, {});
		ensureBlockDefaults(doc);
		ensureWiring(doc, targets);

		return { 'ok': true, 'problems': [] };
	},

	disable: function(doc) {
		removeWiring(doc);
		removeManagedPlugins(doc);
		return { 'ok': true, 'problems': [] };
	},

	removeDownload: function(doc) {
		var state = managedPlugins(doc);
		var downloads = currentDownloads(doc, state);
		var generated = generatedPaths(downloads);
		var generatedNames = generatedFilenames(downloads);

		if (state.rules) {
			var rulesPath = [ 'plugins', state.rules.index, 'args' ];
			var files = listValue(at(doc, rulesPath.concat([ 'files' ]))).filter(function(path) {
				return generated.indexOf(path) === -1 && !generatedNames[basename(path)];
			});

			setList(doc, rulesPath.concat([ 'files' ]), files);
		}

		if (state.download)
			doc.deleteIn([ 'plugins', state.download.index ]);
	},

	/*
	 * Guided mode renders the ad filtering form from the current document
	 * and applies it on every preview, validation, and save. Only write
	 * back when the form differs from the document so an untouched form
	 * never rewrites defaults or drops comments in managed plugins.
	 */
	syncIfChanged: function(doc, values) {
		var state = managedPlugins(doc);

		if (state.collisions.length)
			return;

		if (!state.download && !state.rules && !state.block)
			return;

		if (sameValues(normalizedValues(readValues(doc, state)),
			normalizedValues(values)))
			return;

		this.sync(doc, values);
	},

	sync: function(doc, values) {
		var state = managedPlugins(doc);

		if (state.collisions.length)
			return;

		var urls = lines(values.urlsText);
		var rules = lines(values.rulesText);
		var files = lines(values.filesText);
		var ips = addresses(values.ipsText);
		var dir = text(values.dir).trim() || DEFAULT_DIR;
		var downloads = buildDownloads(doc, state, urls, dir);
		var generated = generatedPaths(downloads);

		if (!state.rules)
			state.rules = ensurePlugin(doc, TAGS.rules, TYPES.rules, {});

		if (!state.block)
			state.block = ensurePlugin(doc, TAGS.block, TYPES.block, {});

		if (state.rules) {
			var rulesPath = [ 'plugins', state.rules.index, 'args' ];

			setList(doc, rulesPath.concat([ 'rules' ]), rules);
			setList(doc, rulesPath.concat([ 'files' ]), generated.concat(files));
		}

		if (state.block) {
			var blockPath = [ 'plugins', state.block.index, 'args' ];
			var mode = text(values.mode);

			// Keep an unrecognized hand-edited mode so validation can report it.
			if (BLOCK_MODES.indexOf(mode) !== -1)
				setValue(doc, blockPath.concat([ 'mode' ]), mode);
			else if (!text(at(doc, blockPath.concat([ 'mode' ]))))
				setValue(doc, blockPath.concat([ 'mode' ]), DEFAULT_MODE);

			setValue(doc, blockPath.concat([ 'short_circuit' ]), true);

			if ((mode === 'custom' || mode === 'null') && ips.length)
				setList(doc, blockPath.concat([ 'ips' ]), ips);
			else if (at(doc, blockPath.concat([ 'ips' ])) !== undefined)
				doc.deleteIn(blockPath.concat([ 'ips' ]));
		}

		if (urls.length) {
			state.download = ensurePlugin(doc, TAGS.download, TYPES.download, {
				'downloads': downloads,
				'startup_if_missing': true
			});

			if (state.download)
				setValue(doc, [ 'plugins', state.download.index, 'args', 'startup_if_missing' ], true);

			setDownloads(doc, state, downloads);
		}
		else {
			setDownloads(doc, state, []);
		}

		ensureWiring(doc, targetSequences(doc));
	},

	validate: function(doc) {
		var state = managedPlugins(doc);

		if (!(state.download || state.rules || state.block || state.collisions.length))
			return [];

		var problems = collisionProblems(state.collisions);
		var targets = targetSequences(doc);
		var values = readValues(doc, state);
		var urls = lines(values.urlsText);
		var rules = lines(values.rulesText);
		var files = lines(values.filesText);
		var ips = addresses(values.ipsText);
		var seen = {};

		if (!targets.length)
			problems.push(_('No entry sequence was found. Configure a server entry in Advanced Mode first.'));
		else if (wiringMissing(doc, targets).length)
			problems.push(_('The ad filtering rule could not be inserted into the entry sequence. Check the sequence configuration in Advanced Mode.'));

		if (state.download && !urls.length)
			problems.push(_('The ad filtering download plugin needs at least one subscription URL. Add one, or use Remove subscription downloads.'));

		if (!urls.length && !rules.length && !files.length)
			problems.push(_('Ad filtering needs at least one subscription URL, inline rule, or local rule file.'));

		urls.forEach(function(url) {
			if (!isHttpUrl(url))
				problems.push(_('The subscription URL %s is invalid. Use an http:// or https:// URL.').format(url));
			else if (seen[url])
				problems.push(_('The subscription URL %s is duplicated.').format(url));

			seen[url] = true;
		});

		if (urls.length && !isAbsolutePath(values.dir))
			problems.push(_('The rules directory must be an absolute path.'));

		files.forEach(function(path) {
			if (!isAbsolutePath(path))
				problems.push(_('The local rule file %s must be an absolute path.').format(path));
		});

		if (BLOCK_MODES.indexOf(values.mode) === -1)
			problems.push(_('The ad filtering blocking mode is invalid.'));

		if (values.mode === 'custom' && (!ips.length || !ips.every(isIpAddress)))
			problems.push(_('Custom blocking mode requires at least one valid IPv4 or IPv6 address.'));

		return problems;
	}
});
