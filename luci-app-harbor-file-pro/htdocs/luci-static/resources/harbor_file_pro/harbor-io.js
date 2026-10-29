
(function (global) {
	'use strict';

	var ENDPOINT = '/cgi-bin/harbor-io-pro';

	function validSessionID(value) {
		return typeof value === 'string' && /^[a-fA-F0-9]{32}$/.test(value) && !/^0{32}$/.test(value);
	}

	function sessionID() {
		var value = '';
		if (global.rpc && typeof global.rpc.getSessionID === 'function') {
			try { value = global.rpc.getSessionID(); } catch (error) {}
		}
		if (validSessionID(value))
			return value;
		value = global.L && global.L.env && global.L.env.sessionid;
		if (validSessionID(value))
			return value;
		value = global.HarborFile && global.HarborFile.sessionid;
		return validSessionID(value) ? value : '';
	}

	function queryString(params) {
		var out = [];
		for (var k in params)
			if (params[k] !== undefined && params[k] !== null)
				out.push(encodeURIComponent(k) + '=' + encodeURIComponent(params[k]));
		return out.join('&');
	}

	function byteInteger(value) { return Number.isSafeInteger(value) && value >= 0; }

	function createIO(context) {
	function qs(params) { return queryString(Object.assign({}, params, context)); }
	var HarborIO = {

		getSessionID: sessionID,
		requestURL: function(mode, path, extra) { return ENDPOINT + '?' + qs(Object.assign({ mode: mode, path: path, sessionid: sessionID() }, extra || {})); },

		download: function (path, filename) {
			var target = 'harbor_dl_' + Date.now() + '_' + Math.floor(Math.random() * 1e6);

			var iframe = document.createElement('iframe');
			iframe.name = target;
			iframe.style.display = 'none';

			var form = document.createElement('form');
			form.method = 'POST';
			form.action = ENDPOINT;
			form.target = target;
			form.style.display = 'none';

			var fields = {
				mode: 'download',
				sessionid: sessionID(),
				path: path,
				filename: filename || path.split('/').pop()
			};

			Object.assign(fields, context);
			for (var k in fields) {
				var input = document.createElement('input');
				input.type = 'hidden';
				input.name = k;
				input.value = fields[k];
				form.appendChild(input);
			}

			document.body.appendChild(iframe);
			document.body.appendChild(form);
			form.submit();

			setTimeout(function () {
				form.remove();
				iframe.remove();
			}, 60000);

			return true;
		},

		inlineURL: function (path, mimetype) {
			return ENDPOINT + '?' + qs({
				mode: 'inline',
				sessionid: sessionID(),
				path: path,
				mimetype: mimetype
			});
		},

		thumbnailURL: function (path, cachePath) {
			return ENDPOINT + '?' + qs({
				mode: 'thumbnail',
				sessionid: sessionID(),
				path: path,
				cache: cachePath
			});
		},

		slice: function (path, offset, length) {
			if (!byteInteger(offset) || !byteInteger(length) || !byteInteger(offset + length)) return Promise.reject(new Error('Invalid byte range'));
			var url = ENDPOINT + '?' + qs({
				mode: 'slice',
				sessionid: sessionID(),
				path: path,
				offset: offset,
				length: length
			});

			return fetch(url, { credentials: 'same-origin' }).then(function (res) {
				if (!res.ok)
					return res.text().then(function (t) {
						throw new Error('slice failed: HTTP ' + res.status + (t ? ': ' + t.trim() : ''));
					});

				var total = parseInt(res.headers.get('X-Harbor-Total') || '0', 10);
				var off = parseInt(res.headers.get('X-Harbor-Offset') || '0', 10);

				if (!byteInteger(total) || !byteInteger(off) || off !== Math.min(offset, total)) throw new Error('Invalid slice response offset');
				return res.arrayBuffer().then(function (buf) {
					if (buf.byteLength !== Math.min(length, 1048576, total - off)) throw new Error('Incomplete slice response');
					return { buffer: buf, offset: off, total: total };
				});
			});
		},

		patch: function (path, offset, bytes, expectedSize) {
			if (!byteInteger(offset) || expectedSize != null && !byteInteger(expectedSize)) return Promise.reject(new Error('Invalid byte offset or file size'));
			var url = ENDPOINT + '?' + qs({
				mode: 'patch',
				sessionid: sessionID(),
				path: path,
				offset: offset,
				expected_size: expectedSize
			});

			return fetch(url, {
				method: 'POST',
				credentials: 'same-origin',
				headers: { 'Content-Type': 'application/octet-stream' },
				body: bytes
			}).then(function (res) {
				return res.json().then(function (j) {
					if (!res.ok || j.code !== 0)
						throw new Error(j.message || ('patch failed: HTTP ' + res.status));
					return j.data;
				});
			});
		},

		splice: function (path, start, end, bytes, expectedSize) {
			if (!byteInteger(start) || !byteInteger(end) || end < start || expectedSize != null && !byteInteger(expectedSize)) return Promise.reject(new Error('Invalid byte range or file size'));
			var url = ENDPOINT + '?' + qs({
				mode: 'splice',
				sessionid: sessionID(),
				path: path,
				start: start,
				end: end,
				expected_size: expectedSize
			});

			return fetch(url, {
				method: 'POST',
				credentials: 'same-origin',
				headers: { 'Content-Type': 'application/octet-stream' },
				body: bytes
			}).then(function (res) {
				return res.json().then(function (j) {
					if (!res.ok || j.code !== 0)
						throw new Error(j.message || ('splice failed: HTTP ' + res.status));
					return j.data;
				});
			});
		},

		search: function (path, needle, opts) {
			opts = opts || {};

			var url = ENDPOINT + '?' + qs({
				mode: 'search',
				sessionid: sessionID(),
				path: path,
				q: needle,
				encoding: opts.encoding || 'text',
				regex: opts.regex ? 1 : 0,
				start: opts.start || 0,
				last: opts.last ? 1 : 0,
				before: opts.before,
				limit: opts.limit || 100,
				ignorecase: opts.ignoreCase ? 1 : 0
			});

			return fetch(url, { credentials: 'same-origin' }).then(function (res) {
				return res.json().then(function (j) {
					if (!res.ok || j.code !== 0)
						throw new Error(j.message || ('search failed: HTTP ' + res.status));
					return j.data;
				});
			});
		},

		replaceAll: function (path, needle, replacement, opts) {
			opts = opts || {};
			var q = {
				mode: 'replace_all',
				sessionid: sessionID(),
				path: path,
				q: needle,
				r: replacement,
				encoding: opts.encoding || 'text',
				rencoding: opts.rencoding || opts.encoding || 'text',
				regex: opts.regex ? 1 : 0,
				ignorecase: opts.ignoreCase ? 1 : 0,
				range: opts.range || null
			};
			if (opts.stageSrc) {
				q.stage = 1;
				q.src = opts.stageSrc;
			}
			var url = ENDPOINT + '?' + qs(q);

			return fetch(url, {
				method: 'POST',
				credentials: 'same-origin',
				headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
				body: ''
			}).then(function (res) {
				return res.json().then(function (j) {
					if (!res.ok || j.code !== 0)
					throw new Error(j.message || ('replace_all failed: HTTP ' + res.status));
				return j.data;
				});
			});
		},

		stageCommit: function (path) {
			var url = ENDPOINT + '?' + qs({
				mode: 'stage_commit',
				sessionid: sessionID(),
				path: path
			});
			return fetch(url, { method: 'POST', credentials: 'same-origin',
				headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: '' })
				.then(function (res) { return res.json(); })
				.then(function (j) {
					if (!j || j.code !== 0)
						throw new Error((j && j.message) || 'commit failed');
					return j;
				});
		},

		stageDiscard: function (path) {
			var url = ENDPOINT + '?' + qs({
				mode: 'stage_discard',
				sessionid: sessionID(),
				path: path
			});
			return fetch(url, { method: 'POST', credentials: 'same-origin',
				headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: '' })
				.then(function (res) { return res.json(); })
				.then(function (j) { return j; });
		},

		replaceProgress: function (path) {
			var url = ENDPOINT + '?' + qs({
				mode: 'replace_progress',
				sessionid: sessionID(),
				path: path
			});
			return fetch(url, { credentials: 'same-origin' })
				.then(function (res) { return res.json(); })
				.then(function (j) {
					return (j && j.code === 0) ? j.data : { done: 0, total: 0 };
				});
		},

		readAll: function (path) {
			var url = ENDPOINT + '?' + qs({
				mode: 'inline',
				sessionid: sessionID(),
				path: path,
				mimetype: 'application/octet-stream'
			});

			return fetch(url, { credentials: 'same-origin' }).then(function (res) {
				if (!res.ok)
					return res.text().then(function (t) {
						throw new Error('read failed: HTTP ' + res.status + (t ? ': ' + t.trim() : ''));
					});
				return res.arrayBuffer();
			});
		}
	};

	return HarborIO;
	}
	global.HarborIO = createIO({});
	global.HarborIO.forDevice = function(item) { return createIO({ device_id: item.device_id, device_revision: item.device_revision || '' }); };
})(window);
