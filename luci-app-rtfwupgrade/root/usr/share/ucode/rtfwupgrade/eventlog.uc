'use strict';

// 事件日志（JSONL，落 /tmp，掉电即丢）。
// 只记「用户动作 + 结论」，不记敏感内容；超过阈值时丢弃前半段做轮转。

let fs = require('fs');
let util = require('rtfwupgrade.util');

const DIR = '/tmp/rtfwupgrade';
const FILE = DIR + '/events.jsonl';
const MAX_BYTES = 256 * 1024;

function ensure_dir() {
	try {
		fs.mkdir(DIR, 0o755);
	} catch (e) {
	}
}

function rotate_if_needed() {
	let st = fs.stat(FILE);
	if (st == null || (st.size ?? 0) <= MAX_BYTES)
		return;

	let text = fs.readfile(FILE) ?? '';
	let half = substr(text, int(length(text) / 2));
	let nl = index(half, '\n');
	fs.writefile(FILE, (nl >= 0) ? substr(half, nl + 1) : '');
}

function append(level, event, message, data) {
	ensure_dir();
	rotate_if_needed();

	let rec = { ts: util.now_epoch(), level: level, event: event, message: message ?? '' };
	if (data != null)
		rec.data = data;

	let fp = null;
	try {
		fp = fs.open(FILE, 'a');
	} catch (e) {
		fp = null;
	}

	if (fp == null)
		return false;

	fp.write(sprintf('%J\n', rec));
	fp.close();
	return true;
}

function tail(lines) {
	let n = util.to_int(lines, 100);
	if (n <= 0)
		n = 100;

	let text = fs.readfile(FILE);
	if (text == null)
		return [];

	let rows = [];
	for (let line in split(text, '\n')) {
		let s = trim(line);
		if (!length(s))
			continue;

		try {
			push(rows, json(s));
		} catch (e) {
		}
	}

	let out = [];
	for (let i = length(rows) - 1; i >= 0 && length(out) < n; i--)
		push(out, rows[i]);

	return out;
}

function clear() {
	try {
		fs.unlink(FILE);
	} catch (e) {
	}

	return { ok: true };
}

function clear_file(path) {
	try {
		fs.writefile(path, '');
		return true;
	} catch (e) {
		return false;
	}
}

function tail_file(path, lines, max_bytes) {
	let text = fs.readfile(path);
	if (text == null)
		return '';

	if (length(text) > (max_bytes ?? 16384))
		text = substr(text, length(text) - (max_bytes ?? 16384));

	let rows = split(text, '\n');
	let n = util.to_int(lines, 80);
	return join('\n', (length(rows) > n) ? slice(rows, length(rows) - n) : rows);
}

return {
	DIR: DIR,
	FILE: FILE,
	append: append,
	tail: tail,
	clear: clear,
	clear_file: clear_file,
	tail_file: tail_file
};
