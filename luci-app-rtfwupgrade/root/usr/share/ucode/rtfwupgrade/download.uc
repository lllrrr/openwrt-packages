'use strict';

// 镜像下载与校验（M2：只下载、只校验，不刷写）。
//
// 设计要点：
//   - 落 /tmp/rtfwupgrade/（tmpfs，掉电即丢，天然幂等）
//   - 后台 curl -C - 续传；续传前比对 ETag/Last-Modified，服务端文件换了就重下
//   - 完成判定不依赖守护进程：后台命令把 curl 退出码写进 download.rc，
//     status() 发现进程已退出就顺手做校验/收尾，并投递 webhook
//   - 候选镜像、sha256、体积上限一律由后端重新探测得到，不信任前端传参

let fs = require('fs');
let digest = require('digest');
let util = require('rtfwupgrade.util');
let local = require('rtfwupgrade.local');
let config = require('rtfwupgrade.config');
let source = require('rtfwupgrade.source');
let notify = require('rtfwupgrade.notify');
let eventlog = require('rtfwupgrade.eventlog');

const DIR = '/tmp/rtfwupgrade';
const STATE = DIR + '/download.json';
const RC = DIR + '/download.rc';
const LOG = DIR + '/download.log';

function ensure_dir() {
	try {
		fs.mkdir(DIR, 0o755);
	} catch (e) {
	}
}

function load_state() {
	let text = fs.readfile(STATE);
	if (text == null)
		return null;

	try {
		return json(text);
	} catch (e) {
		return null;
	}
}

function save_state(st) {
	ensure_dir();
	fs.writefile(STATE, sprintf('%J', st));
	return st;
}

function clear_state() {
	try {
		fs.unlink(STATE);
		fs.unlink(RC);
	} catch (e) {
	}
}

function file_size(path) {
	if (!length(path ?? ''))
		return 0;

	let st = fs.stat(path);
	return (st != null && st.size != null) ? st.size : 0;
}

// fs.statvfs 只存在于较新的 ucode；24.10/25.12 的 ucode 里没有它（实测 type=null，
// 无条件调用会抛 TypeError 把整个下载入口打断）。因此按可用性回退到 busybox df。
function free_bytes(path) {
	if (type(fs.statvfs) == 'function') {
		let s = fs.statvfs(path);
		if (s != null)
			return util.to_int((s.bavail ?? 0) * (s.bsize ?? 0), 0);
	}

	let res = util.run(sprintf("df -k %s 2>/dev/null | tail -n 1 | awk '{print $4}'", util.shquote(path)));
	let kb = util.to_int(trim(res.output ?? ''), 0);
	return kb > 0 ? kb * 1024 : 0;
}

// 我们总是用 setsid 起下载，因此 PID 同时是进程组 ID：
// 只杀组长会留下孤儿 curl 继续写文件（实测踩过），必须按组杀。
function group_alive(pid) {
	if (!pid)
		return false;

	return trim(util.run(sprintf('kill -0 -%d 2>/dev/null && echo yes', pid)).output ?? '') == 'yes';
}

function kill_group(pid) {
	if (!pid)
		return false;

	util.run(sprintf('kill -TERM -%d 2>/dev/null', pid));
	if (group_alive(pid)) {
		util.run('sleep 2');
		util.run(sprintf('kill -KILL -%d 2>/dev/null', pid));
	}

	return !group_alive(pid);
}

// 设备上没有 pkill，用 ps 扫残留下载进程（命令行里带我们的目录）
function sweep_strays() {
	let res = util.run(sprintf("for p in $(ps w | grep '[c]url' | grep %s | awk '{print $1}'); do kill -KILL $p 2>/dev/null; done; echo swept",
		util.shquote(DIR)));
	return trim(res.output ?? '');
}

// 取远端文件的 ETag / Last-Modified / Content-Length，用于续传前的同一性判断
function head_meta(url) {
	let res = util.run(sprintf('curl -fsSI -L --max-time 20 --url %s 2>/dev/null', util.shquote(url)));
	if (res.code != 0)
		return null;

	let out = { etag: '', last_modified: '', length: 0 };
	for (let line in split(res.output ?? '', '\n')) {
		let m = match(line, /^([A-Za-z-]+):[ \t]*(.+)$/);
		if (!m)
			continue;

		let k = lc(trim(m[1]));
		if (k == 'etag')
			out.etag = trim(m[2]);
		else if (k == 'last-modified')
			out.last_modified = trim(m[2]);
		else if (k == 'content-length')
			out.length = util.to_int(trim(m[2]), 0);
	}
	return out;
}

function verify(path, sha256) {
	if (!length(trim(sha256 ?? '')))
		return { ok: false, error: 'profiles.json 未提供 sha256，拒绝放行。' };

	let got = digest.sha256_file(path);
	if (got == null)
		return { ok: false, error: '无法计算下载文件的 sha256。' };

	if (util.lc_trim(got) != util.lc_trim(sha256))
		return { ok: false, error: 'sha256 不匹配。', got: trim(got) };

	return { ok: true, got: trim(got) };
}

function read_rc() {
	let v = trim(fs.readfile(RC) ?? '');
	if (!length(v))
		return null;

	let n = util.to_int(v, -1);
	return (n < 0) ? null : n;
}

// 收尾：后台进程已退出时做校验与 webhook（幂等，可被 status() 反复调用）
function finalize(st) {
	let rc = read_rc();
	let conf = config.load();
	let loc = local.identity();
	let remote = st.remote ?? {};

	if (rc != null && rc != 0) {
		st.state = 'failed';
		st.error = 'curl 退出码 ' + rc;
	}
	else if (file_size(st.file) < util.to_int(st.size, 0)) {
		st.state = 'failed';
		st.error = '文件不完整（' + file_size(st.file) + ' / ' + st.size + ' 字节）';
	}
	else {
		let v = verify(st.file, st.sha256);
		st.verified = v.ok == true;
		st.state = v.ok ? 'verified' : 'failed';
		st.error = v.ok ? '' : (v.error + (v.got ? ('（实际 ' + substr(v.got, 0, 12) + '…）') : ''));
	}

	st.finished = util.now_epoch();

	eventlog.append(st.state == 'verified' ? 'info' : 'error', 'download',
		sprintf('%s：%s', st.state == 'verified' ? '下载完成并通过校验' : '下载失败',
			st.state == 'verified' ? (st.sha256 ? substr(st.sha256, 0, 12) : 'sha256 已校验') : (st.error || '未知错误')),
		{ file: st.file, size: st.size, received: file_size(st.file) });

	if (length(conf.webhook))
		notify.post(conf.webhook, notify.payload('download_done', loc, remote, { state: st.state, error: st.error }));

	return save_state(st);
}

function status() {
	let st = load_state();
	if (st == null)
		return { state: 'idle', percent: 0 };

	if (st.state == 'running') {
		let received = file_size(st.file);
		if (!group_alive(st.pid))
			st = finalize(st);
		else {
			st.received = received;
			st.percent = (util.to_int(st.size, 0) > 0) ? (received * 100 / st.size) : 0;
			if (st.percent > 100)
				st.percent = 100;
			return st;
		}
	}

	st.received = file_size(st.file);
	st.percent = util.to_int(st.size, 0) > 0 ? (st.received * 100 / st.size) : 0;
	if (st.percent > 100)
		st.percent = 100;

	return st;
}

function start(req_source, req_channel) {
	ensure_dir();

	let conf = config.load();
	let src = length(trim(req_source ?? ''))
		? (filter(conf.sources, function (s) { return s.name == trim(req_source); })[0] ?? null)
		: config.active(conf);

	if (src == null)
		return { ok: false, error: '没有可用的源。' };

	let cur = status();
	if (cur.state == 'running')
		return { ok: false, error: '已有下载在进行中。' };

	let loc = local.identity();
	let remote = source.probe(src, loc, req_channel);
	if (!remote.ok)
		return { ok: false, error: remote.error || '探测失败' };

	let img = remote.image;
	if (img == null)
		return { ok: false, error: '该源没有可用于升级的镜像。' };

	let size = util.to_int(img.size, 0);
	let limit = util.to_int(remote.image_limit, 0);
	if (limit > 0 && size > limit)
		return { ok: false, error: sprintf('镜像 %d 字节超过该 profile 的上限 %d 字节。', size, limit) };

	let file = DIR + '/' + replace(img.name ?? 'image.bin', /[^A-Za-z0-9._-]/g, '_');
	let url = source.url_join([ remote.dir, img.name ]);

	// 同一镜像已经下载并通过校验：直接复用，别让定时任务每天重下几十 MB。
	if (cur.state == 'verified' && (cur.file ?? '') == file && size > 0 && file_size(file) == size) {
		let v = verify(file, trim(img.sha256 ?? ''));
		if (v.ok) {
			cur.ok = true;
			cur.skipped = true;
			cur.received = file_size(file);
			cur.percent = 100;
			eventlog.append('info', 'download', sprintf('%s 已下载并通过校验，跳过重复下载', img.name ?? ''));
			return cur;
		}
	}

	let free = free_bytes(DIR);
	if (size > 0 && free > 0 && free < size * 1.1)
		return { ok: false, error: sprintf('/tmp 可用空间不足（需约 %d，实有 %d）。', size, free) };

	// 上一轮的残留下载进程必须先清掉，否则两个 curl 会同时写同一个文件
	sweep_strays();

	// 续传保护：只有服务端文件没变（ETag/Last-Modified 一致）才允许 -C -
	let meta = head_meta(url);
	let resume = false;
	let why = '';
	let partial = file_size(file);
	let old = load_state();

	if (partial <= 0)
		why = '没有已下载的部分';
	else if (partial >= size)
		why = '已有文件不小于目标体积';
	else if (old == null)
		why = '没有上一次的状态记录';
	else if ((old.url ?? '') != url)
		why = '下载地址与上次不同';
	else if (meta == null)
		why = 'HEAD 失败，无法确认服务端文件未变';
	else if ((old.etag ?? '') != (meta.etag ?? ''))
		why = 'ETag 变化：' + (old.etag ?? '(空)') + ' → ' + (meta.etag ?? '(空)');
	else if ((old.last_modified ?? '') != (meta.last_modified ?? ''))
		why = 'Last-Modified 变化';
	else {
		resume = true;
		why = 'ETag/Last-Modified 一致';
	}

	if (!resume && partial > 0) {
		try { fs.unlink(file); } catch (e) {}
		partial = 0;
	}

	let inner = sprintf('curl -fL%s --max-time 3600 --url %s -o %s; echo $? > %s',
		resume ? ' -C -' : '', util.shquote(url), util.shquote(file), util.shquote(RC));

	let res = util.run(sprintf('setsid sh -c %s > %s 2>&1 & echo $!', util.shquote(inner), util.shquote(LOG)));
	let pid = util.to_int(trim(res.output ?? ''), 0);
	if (pid <= 0)
		return { ok: false, error: '无法启动下载进程。' };

	try { fs.unlink(RC); } catch (e) {}

	let st = {
		state: 'running',
		pid: pid,
		url: url,
		file: file,
		size: size,
		resumed_from: resume ? partial : 0,
		resume_reason: why,
		sha256: trim(img.sha256 ?? ''),
		etag: meta?.etag ?? '',
		last_modified: meta?.last_modified ?? '',
		source: src.name,
		channel: remote.channel ?? '',
		version_code: remote.version_code ?? '',
		remote: {
			source: src.name,
			file: file,
			version_code: remote.version_code ?? '',
			channel: remote.channel ?? '',
			source_date_epoch: remote.source_date_epoch ?? 0,
			image: { name: img.name ?? '', size: size, sha256: trim(img.sha256 ?? '') }
		},
		started: util.now_epoch(),
		finished: 0,
		verified: false,
		error: ''
	};

	save_state(st);
	eventlog.append('info', 'download',
		sprintf('开始下载 %s（%d 字节%s）', img.name ?? '', size, resume ? sprintf('，续传自 %d', partial) : ''));

	st.percent = 0;
	st.received = resume ? partial : 0;
	return st;
}

function cancel() {
	let st = load_state();
	if (st == null || st.state != 'running')
		return { ok: false, error: '当前没有进行中的下载。', state: status().state };

	kill_group(st.pid);
	st.state = 'cancelled';
	st.finished = util.now_epoch();
	st.error = '';
	save_state(st);
	eventlog.append('warn', 'download', sprintf('下载已取消（已收 %d / %d 字节）', file_size(st.file), util.to_int(st.size, 0)));

	// 保留已下载部分，便于之后续传
	return { ok: true, state: 'cancelled', received: file_size(st.file), size: util.to_int(st.size, 0) };
}

function cleanup() {
	// 正在下载时必须先按进程组杀掉，否则孤儿 curl 会继续写回被删掉的文件
	let st = load_state();
	if (st != null && st.state == 'running' && group_alive(st.pid))
		kill_group(st.pid);

	clear_state();
	let ok = true;
	try {
		for (let f in fs.lsdir(DIR) ?? []) {
			// 保留事件日志与定时任务原始输出：删除下载文件不该顺带清空「日志」页
			// （只有 logs_clear 才清）。
			if (f == 'events.jsonl' || f == 'cron.log')
				continue;
			try { fs.unlink(DIR + '/' + f); } catch (e) { ok = false; }
		}
	} catch (e) {
		ok = false;
	}
	return { ok: ok };
}

return {
	DIR: DIR,
	STATE: STATE,
	LOG: LOG,
	status: status,
	start: start,
	cancel: cancel,
	cleanup: cleanup,
	verify: verify,
	head_meta: head_meta,
	free_bytes: free_bytes
};
