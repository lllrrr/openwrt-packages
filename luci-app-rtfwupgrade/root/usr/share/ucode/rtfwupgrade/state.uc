'use strict';

// 运行态缓存：最近一次检测结果（放 /tmp，掉电即丢，符合幂等要求）。

let fs = require('fs');

const CACHE = '/tmp/rtfwupgrade.last.json';

function save_last(obj) {
	try {
		fs.writefile(CACHE, sprintf('%J', obj));
		return true;
	} catch (e) {
		return false;
	}
}

function load_last() {
	let text = fs.readfile(CACHE);
	if (text == null)
		return null;

	try {
		return json(text);
	} catch (e) {
		return null;
	}
}

function clear_last() {
	try {
		fs.unlink(CACHE);
	} catch (e) {
	}
	return true;
}

return {
	CACHE: CACHE,
	save_last: save_last,
	load_last: load_last,
	clear_last: clear_last
};
