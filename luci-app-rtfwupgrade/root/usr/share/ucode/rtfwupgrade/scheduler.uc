'use strict';

// 定时检测：把调度写进 /etc/crontabs/root 的**标记块**里。
//
// 安全约定（这是本项目唯一会写系统全局文件的地方）：
//   - 只增删自己标记块内的行，块外内容一字不动（用户已有的 nginx-util / acme 等必须原样保留）
//   - 写之前先备份到 <crontab>.rtfwupgrade.bak，便于人工回退
//   - 幂等：内容一致就不写文件、不重启 cron
//   - 关闭调度（kind=off）时只移除标记块，不留空痕
//   - 兼容升级前旧包的标记块：同步时一并移除，避免旧命令继续被 cron 调用

let fs = require('fs');
let util = require('rtfwupgrade.util');
let config = require('rtfwupgrade.config');

const CRONTAB = '/etc/crontabs/root';
const BEGIN = '# BEGIN rtfwupgrade (managed block, do not edit)';
const END = '# END rtfwupgrade';
const LEGACY_BEGIN = '# BEGIN lucisysupgrade (managed block, do not edit)';
const LEGACY_END = '# END lucisysupgrade';
const DIR = '/tmp/rtfwupgrade';
const LOG = DIR + '/cron.log';
const CMD = '/usr/bin/rtfwupgrade.sh cron';

function cron_line(conf) {
	let expr = config.schedule_cron(conf ?? config.load());
	if (!length(expr))
		return '';

	// 先建目录再重定向：/tmp 重启即空，cron 的重定向在命令执行前求值，
	// 目录不存在会让 shell 直接放弃执行整条命令。
	return sprintf('%s mkdir -p %s && %s >> %s 2>&1', expr, DIR, CMD, LOG);
}

// 去掉指定标记块（含标记行），返回剩余行。
// 只删标记块本身：块外的空行、缩进、用户命令都按原样保留（否则反复同步会改写别人的 crontab）。
// 末尾那个空元素只是文件结尾的换行，不是一行空行，这里单独丢掉，保证幂等。
function strip_block(text, begin, end) {
	let b = begin ?? BEGIN;
	let e = end ?? END;
	let lines = split(text ?? '', '\n');

	if (length(lines) && lines[length(lines) - 1] === '')
		pop(lines);

	let out = [];
	let inside = false;

	for (let line in lines) {
		let t = trim(line);

		if (inside) {
			if (t == e)
				inside = false;
			continue;
		}
		if (t == b) {
			inside = true;
			continue;
		}
		push(out, line);
	}

	return out;
}

function read_block(text, begin, end) {
	let b = begin ?? BEGIN;
	let e = end ?? END;
	let out = [];
	let inside = false;

	for (let line in split(text ?? '', '\n')) {
		let t = trim(line);

		if (t == b) {
			inside = true;
			continue;
		}
		if (t == e) {
			inside = false;
			continue;
		}
		if (inside && length(t))
			push(out, line);
	}

	return out;
}

function status() {
	let conf = config.load();
	let text = fs.readfile(CRONTAB) ?? '';
	let block = read_block(text);
	let legacy = read_block(text, LEGACY_BEGIN, LEGACY_END);
	let applied = length(block) ? trim(block[0]) : (length(legacy) ? trim(legacy[0]) : '');

	return {
		path: CRONTAB,
		schedule: config.schedule_label(conf),
		wanted: cron_line(conf),
		applied: applied,
		block: block,
		legacy: legacy,
		in_sync: trim(applied) == trim(cron_line(conf)) && !length(legacy)
	};
}

// 依次移除新旧两代受管块。strip_block() 返回行数组，接着处理时必须先拼回文本，
// 否则 split(array) 会得到空结果，把块外所有用户行一起丢掉（已实测踩坑）。
function strip_all_blocks(text) {
	let rest = strip_block(text, LEGACY_BEGIN, LEGACY_END);
	return strip_block(join('\n', rest));
}

// 把 crontab 同步到配置描述的状态
function sync() {
	let conf = config.load();
	let wanted = cron_line(conf);
	let cur = fs.readfile(CRONTAB) ?? '';
	let lines = strip_all_blocks(cur);

	if (length(wanted)) {
		push(lines, BEGIN);
		push(lines, wanted);
		push(lines, END);
	}

	let next = length(lines) ? (join('\n', lines) + '\n') : '';

	if (next == cur)
		return { ok: true, changed: false, line: wanted, schedule: config.schedule_label(conf) };

	try {
		fs.writefile(CRONTAB + '.rtfwupgrade.bak', cur);
	} catch (e) {
	}

	// cron 重定向依赖这个目录；同步时先建出来，避免首次触发失败。
	try {
		fs.mkdir(DIR, 0o755);
	} catch (e) {
	}

	if (!fs.writefile(CRONTAB, next))
		return { ok: false, error: '写入 ' + CRONTAB + ' 失败' };

	// busybox crond 会检测 mtime，但显式重启最稳（这台设备的 init 脚本没有 reload 动作）
	util.run('/etc/init.d/cron restart >/dev/null 2>&1');

	return { ok: true, changed: true, line: wanted, schedule: config.schedule_label(conf) };
}

return {
	CRONTAB: CRONTAB,
	BEGIN: BEGIN,
	END: END,
	LEGACY_BEGIN: LEGACY_BEGIN,
	LEGACY_END: LEGACY_END,
	DIR: DIR,
	LOG: LOG,
	CMD: CMD,
	cron_line: cron_line,
	strip_block: strip_block,
	strip_all_blocks: strip_all_blocks,
	read_block: read_block,
	status: status,
	sync: sync
};
