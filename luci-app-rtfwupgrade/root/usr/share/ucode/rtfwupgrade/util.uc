'use strict';

// 通用工具：进程调用、HTTP 读取、os-release 解析、版本比较、时间格式化。
// 无副作用，可被 CLI 与 rpcd 插件共用。

let fs = require('fs');

// ucode 的 int() 转换失败时返回 NaN（double），且没有 isNaN() 内建函数
function is_nan(n) {
	return n != n;
}

function to_int(v, fallback) {
	let n = int(v ?? 0);
	return is_nan(n) ? (fallback ?? 0) : n;
}

function shquote(s) {
	return "'" + replace(s ?? '', /'/g, "'\\''") + "'";
}

function run(cmd) {
	let fp = fs.popen(cmd, 'r');
	if (fp == null)
		return { code: 127, output: '' };

	let output = fp.read('all');
	let code = fp.close();
	return { code: code ?? 127, output: output ?? '' };
}

// 用设备自带的 curl 取文本；返回 { ok, code, body, error }
function http_get(url, timeout) {
	let t = to_int(timeout, 20);
	let res = run(sprintf('curl -fsS -L --max-time %d --url %s 2>/dev/null', t, shquote(url)));
	if (res.code != 0)
		return { ok: false, code: res.code, error: '请求失败 (' + url + ')' };

	return { ok: true, code: 0, body: res.output };
}

// 解析 KEY="value" / KEY=value 形式的文件（/usr/lib/os-release 等）
function read_kv(path) {
	let text = fs.readfile(path);
	if (text == null)
		return {};

	let out = {};
	for (let line in split(text, '\n')) {
		let m = match(line, /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*)[ \t]*$/);
		if (!m)
			continue;

		let v = trim(m[2]);
		let q = substr(v, 0, 1);
		if (length(v) >= 2 && (q == '"' || q == "'"))
			v = substr(v, 1, length(v) - 2);
		out[m[1]] = v;
	}
	return out;
}

function parse_json(text) {
	try {
		return { ok: true, value: json(text) };
	} catch (e) {
		return { ok: false, error: '' + e };
	}
}

function lc_trim(v) {
	return lc(trim(v ?? ''));
}

function file_trim(path) {
	return trim(fs.readfile(path) ?? '');
}

function hostname() {
	return file_trim('/proc/sys/kernel/hostname');
}

function now_epoch() {
	return time();
}

// 点分版本号比较；不可比时返回 null
function version_cmp(a, b) {
	let pa = split(trim(a ?? ''), '.');
	let pb = split(trim(b ?? ''), '.');
	if (!length(pa) || !length(pb))
		return null;

	let n = (length(pa) > length(pb)) ? length(pa) : length(pb);
	for (let i = 0; i < n; i++) {
		let na = int(pa[i] ?? 0), nb = int(pb[i] ?? 0);
		if (is_nan(na) || is_nan(nb))
			return null;
		if (na != nb)
			return (na < nb) ? -1 : 1;
	}
	return 0;
}

// source_date_epoch -> "YYYY-MM-DD HH:MM UTC"；不可用时返回空串
function iso_utc(epoch) {
	let e = to_int(epoch, 0);
	if (!e)
		return '';

	let t = gmtime(e);
	if (t == null)
		return '';

	// gmtime 的 mon 为 1 基，日期字段是 mday
	return sprintf('%04d-%02d-%02d %02d:%02d UTC', t.year, t.mon, t.mday, t.hour, t.min);
}

function epoch_or_zero(v) {
	return to_int(v, 0);
}

return {
	is_nan: is_nan,
	to_int: to_int,
	shquote: shquote,
	run: run,
	http_get: http_get,
	read_kv: read_kv,
	parse_json: parse_json,
	lc_trim: lc_trim,
	file_trim: file_trim,
	hostname: hostname,
	now_epoch: now_epoch,
	version_cmp: version_cmp,
	iso_utc: iso_utc,
	epoch_or_zero: epoch_or_zero
};
