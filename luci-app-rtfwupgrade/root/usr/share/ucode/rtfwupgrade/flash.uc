'use strict';

// 刷写（M3）：护栏 → 落盘 flash-pending → setsid 起 sysupgrade → 重启后自证结果。
//
// 命令只有一种形式：sysupgrade -c -k <镜像绝对路径>
//   保留配置本来就是默认（官方脚本 export SAVE_CONFIG=1，-n 才关闭）；
//   -k 把当前已安装包列表写进备份；-c 保留 /etc/ 下所有改动过的文件。
// sysupgrade 末尾走 ubus call system sysupgrade，命令**不会返回**，设备直接重启，
// 因此只能 setsid 后台起、把输出重定向到 flash.log，绝不能同步等待。
//
// 状态机恰好四个取值（没有第五个）：
//   idle            没有状态文件
//   flash-pending   已落盘、已发起刷写（重启前）
//   boot-confirmed  重启后本机 BUILD_ID == 记录的目标 BUILD_ID
//   flash-failed    重启后本机 BUILD_ID != 记录的目标 BUILD_ID
//
// 状态文件放 /etc（不是 /tmp）：sysupgrade 只搬运 keep.d 里登记的路径，
// root/lib/upgrade/keep.d/rtfwupgrade 登记了它，状态才跨得过重启。

let fs = require('fs');
let util = require('rtfwupgrade.util');
let local = require('rtfwupgrade.local');
let config = require('rtfwupgrade.config');
let source = require('rtfwupgrade.source');
let download = require('rtfwupgrade.download');
let notify = require('rtfwupgrade.notify');
let eventlog = require('rtfwupgrade.eventlog');
let state = require('rtfwupgrade.state');

const STATE = '/etc/rtfwupgrade.flash.json';
const DIR = '/tmp/rtfwupgrade';
const LOG = DIR + '/flash.log';

const STATES = [ 'idle', 'flash-pending', 'boot-confirmed', 'flash-failed' ];

function ensure_dir() {
	try {
		fs.mkdir(DIR, 0o755);
	} catch (e) {
	}
}

// 时间一律走 util.iso_utc（gmtime 的 mon 是 1 基、日期字段是 mday），不可用时退回 epoch
function iso_or_epoch(epoch) {
	let s = util.iso_utc(epoch);
	return length(s) ? s : ('epoch ' + util.to_int(epoch, 0));
}

// 第一个非空文本；ucode 的 || 返回值语义不适合做取值选择，这里显式判断
function first_text(a, b) {
	let t = trim(a ?? '');
	return length(t) ? t : trim(b ?? '');
}

function file_size(path) {
	if (!length(path ?? ''))
		return 0;

	let st = fs.stat(path);
	return (st != null && st.size != null) ? st.size : 0;
}

function load_state() {
	let text = fs.readfile(STATE);
	if (text == null)
		return null;

	let st = null;
	try {
		st = json(text);
	} catch (e) {
		return null;
	}

	if (st == null || type(st) != 'object')
		return null;

	// 只认四个取值：文件被手工改坏时按 idle 处理，别把非法值漏给下游判断
	if (index(STATES, trim(st.state ?? '')) < 0)
		st.state = 'idle';

	return st;
}

// fs.writefile 写失败时**返回 null**（真机实测 /proc 下写入即 null），不一定抛异常，
// 因此必须显式判断返回值：刷写前若写不进状态文件，就没有任何办法在下次开机判断结果。
function save_state(st) {
	let res = null;
	try {
		res = fs.writefile(STATE, sprintf('%J', st));
	} catch (e) {
		return false;
	}

	return res != null;
}

// 跨发行版（f）的放行判据：force、或手工路径的持久默认 flash_allow_cross_distro。
// 自动路径永不使用 force：trigger=auto 时连显式 force 都忽略，
// 否则定时任务可能把设备刷成另一个发行版；手工路径才吃那个持久默认。
// 注意这个持久默认**只**覆盖跨发行版，跨源另见 allow_cross_source()。
function allow_cross(o, conf) {
	if (trim(o?.trigger ?? '') == 'auto')
		return false;
	if (o?.force == true)
		return true;

	return util.to_int(conf?.flash_allow_cross_distro, 0) == 1;
}

// 跨源只认「当场 force」，**不吃** flash_allow_cross_distro 这个持久默认。
// 那个开关的语义是「我接受换发行版」，与「我接受换来源」不是一回事；
// 让它顺手放行跨源，等于一次勾选悄悄替用户确认了一个他从没确认过的固件来源。
function allow_cross_source(o) {
	if (trim(o?.trigger ?? '') == 'auto')
		return false;

	return o?.force == true;
}

// h) 跨源：激活源不是用户确认过的那个源。
//
// 与跨源**发行版**（f）是两件事：f 比的是「源所属族 vs 本机发行版」，h 比的是
// 「这次用哪个源 vs 用户认可的源」。判据是纯粹的段名比较，不需要探测结果。
//
// 为什么必须放到后端：界面上原来只在 doSetActive() / 刷写按钮上拦，直接调 ubus
// 或走 CLI 就能绕过 —— 而 CLI 恰恰是无人值守与脚本最常用的入口。
//
// 首次使用（current_firmware_source 为空）不算跨源：那只是还没初始化，由概览页
// 引导用户去确认，不该让全新安装的 CLI 立刻不可用。
function cross_source_name(o, conf) {
	let confirmed = trim(conf?.current_firmware_source ?? '');
	if (!length(confirmed))
		return '';

	// 本次实际会用到的源：显式 --source / ubus 参数优先，否则是激活源
	let want = trim(o?.source ?? '');
	let name = length(want) ? want : trim(conf?.active_source ?? '');

	if (!length(name) || name == confirmed)
		return '';

	return name;
}

// 一次采集：下载器状态、上一次判定、远端探测、本机身份、配置。
// guards() 与 start() 共用，避免刷写前把同一份 profiles.json 拉两遍。
function inspect(o) {
	let conf = config.load();
	let want = trim(o?.source ?? '');
	let hit = length(want)
		? filter(conf.sources, function (s) { return s.name == want; })
		: [];
	let src = length(want) ? (hit[0] ?? null) : config.active(conf);
	let loc = local.identity();
	let dl = download.status() ?? {};
	let last = state.load_last();
	let probe = null;

	if (src == null) {
		// 源缺失也要给出一份形状完整的探测结果，让护栏逐条报出「为什么不能刷」
		probe = {
			ok: false,
			error: length(want) ? ('未知的源：' + want) : '没有可用的源',
			warnings: [],
			image: null,
			images: [],
			channel: '',
			version_code: '',
			version_number: '',
			source_date_epoch: 0,
			source: '',
			dir: ''
		};
	}
	else {
		probe = source.probe(src, loc, o?.channel ?? '');
	}

	return { conf: conf, src: src, loc: loc, dl: dl, last: last, probe: probe };
}

// 八条阻断项（全部阻断，不是警告）+ 两条不阻断的提示。
// 顺序固定：先看镜像是否已下载校验（a/b/c），再看该不该刷（d），再看这张镜像能不能刷（e/f），
// 再看来源是不是用户认可的（h），最后看有没有前一次没结案（g）。
function check_guards(ctx, o) {
	let errors = [];
	let warnings = [];
	let dl = ctx.dl ?? {};
	let probe = ctx.probe ?? {};
	let vs = trim(ctx.last?.verdict?.state ?? '');
	let file = trim(dl.file ?? '');
	let want = util.to_int(dl.size, 0);

	// a) 下载器没到 verified：镜像要么没下完、要么校验没过
	if (trim(dl.state ?? '') != 'verified')
		push(errors, sprintf('镜像未下载或未通过校验（下载状态：%s）。', first_text(dl.state, '无')));

	// b) verified 标记与 sha256 缺一不可：没有 sha256 就没有可比对的依据
	if (dl.verified != true || !length(trim(dl.sha256 ?? '')))
		push(errors, '缺少 sha256 校验（verified 标记为假或 sha256 为空）。');

	// c) 记录的那份镜像必须还在、体积还得对得上。
	// 镜像名在 download.uc 里已被压成 [A-Za-z0-9._-]，所以这里的 substr 不会切到多字节字符。
	if (!length(file) || substr(file, 0, 1) != '/') {
		push(errors, sprintf('镜像文件缺失或体积不符（记录的路径不是绝对路径：%s）。', length(file) ? file : '空'));
	}
	else if (want <= 0) {
		push(errors, '镜像文件缺失或体积不符（记录的体积未知）。');
	}
	else {
		let got = file_size(file);
		if (got != want)
			push(errors, sprintf('镜像文件缺失或体积不符（记录 %d 字节，实际 %d 字节）。', want, got));
	}

	// d) 只允许 update / rebuild 进刷写；其余状态原样报给用户
	if (vs != 'update' && vs != 'rebuild')
		push(errors, sprintf('判定状态不是 update/rebuild（当前：%s）。', length(vs) ? vs : '无检测结果'));

	// e) 候选镜像必须是 sysupgrade 的 squashfs：别的镜像会重写引导链或分区表
	let img = probe?.image ?? null;
	if (probe?.ok != true)
		push(errors, sprintf('不是可刷写的 sysupgrade squashfs 镜像（远端探测失败：%s）。', first_text(probe?.error, '未知原因')));
	else if (img == null)
		push(errors, '不是可刷写的 sysupgrade squashfs 镜像（该 profile 没有 sysupgrade 镜像）。');
	else if (img.type != 'sysupgrade' || img.filesystem != 'squashfs')
		push(errors, sprintf('不是可刷写的 sysupgrade squashfs 镜像（type=%s，filesystem=%s）。',
			first_text(img.type, '?'), first_text(img.filesystem, '?')));

	// f) 跨发行版是「换系统」而不是升级：除非 force（或手工路径的持久默认），一律阻断
	let cross = filter(probe?.warnings ?? [], function (w) { return match(w ?? '', /跨发行版/) != null; });
	if (length(cross) && !allow_cross(o, ctx.conf))
		push(errors, sprintf('%s只有手工路径能带 force 放行这条护栏。', cross[0]));

	// h) 跨源：这次要用的源不是用户确认过的那个。只有手工路径能带 force 放行，
	// 自动路径一律阻断 —— 定时任务不该从用户还没认可的来源刷写。
	let crossSrc = cross_source_name(o, ctx.conf);
	if (length(crossSrc) && !allow_cross_source(o)) {
		push(errors, sprintf(
			'跨源更换：本次使用的源 %s 不是本机已确认的固件来源 %s。' +
				'请在设置页把该源设为激活源，或带 force 放行这条护栏。',
			crossSrc, trim(ctx.conf?.current_firmware_source ?? '?')));
	}

	// g) 上一次刷写还没结案：先重启让 boot_check 结案，或者 flash-clear 明确放弃
	let cur = load_state();
	if (cur != null && cur.state == 'flash-pending')
		push(errors, sprintf('上一次刷写尚未确认结果（发起于 %s，目标 %s）。',
			iso_or_epoch(cur.started ?? 0), first_text(cur.target_build_id, '?')));

	// ── 以下只提示，不阻断 ────────────────────────────────────────────────
	if (vs == 'rebuild')
		push(warnings, '本次判定是 rebuild（同版本、不同构建），不是 update：自动路径不会刷写它。');

	let rsd = util.to_int(probe?.source_date_epoch, 0);
	let lsd = util.to_int(ctx.loc?.build_date, 0);
	if (rsd > 0 && lsd > 0 && rsd < lsd)
		push(warnings, sprintf('远端 source_date_epoch 较旧（%s，本机 %s）。', iso_or_epoch(rsd), iso_or_epoch(lsd)));

	return { ok: length(errors) == 0, errors: errors, warnings: warnings };
}

function guards(opts) {
	let o = opts ?? {};

	try {
		return check_guards(inspect(o), o);
	} catch (e) {
		return { ok: false, errors: [ '护栏检查异常：' + e ], warnings: [] };
	}
}

function status() {
	let st = load_state();
	if (st == null)
		return { state: 'idle' };

	return st;
}

function start(opts) {
	let o = opts ?? {};
	let ctx = null;
	let g = null;

	try {
		ctx = inspect(o);
		g = check_guards(ctx, o);
	} catch (e) {
		let msg = '刷写护栏检查异常：' + e;
		eventlog.append('error', 'flash', msg);
		return { ok: false, state: 'idle', error: msg, errors: [ msg ] };
	}

	if (g.ok != true) {
		let first = length(g.errors) ? g.errors[0] : '护栏未通过';
		eventlog.append('error', 'flash', '刷写被阻断：' + first, {
			trigger: o.trigger ?? 'manual',
			source: ctx?.src?.name ?? '',
			errors: g.errors
		});
		return { ok: false, state: 'idle', error: first, errors: g.errors };
	}

	let dl = ctx.dl ?? {};
	let probe = ctx.probe ?? {};
	let trigger = (trim(o.trigger ?? '') == 'auto') ? 'auto' : 'manual';
	let file = trim(dl.file ?? '');
	let st = {
		state: 'flash-pending',
		trigger: trigger,
		source: first_text(dl.source, ctx.src?.name),
		channel: first_text(dl.channel, probe.channel),
		file: file,
		sha256: trim(dl.sha256 ?? ''),
		size: util.to_int(dl.size, 0),
		// 目标构建标识以**已下载的那个文件**为准（download.json 的 remote 是下载当时的探测结果）。
		// 不能优先用此刻的 probe：远端在这之后又前进时，probe 会给出一个更新的 build id，
		// 刷下去的还是旧镜像，boot_check 就会把成功的刷写误判成 flash-failed。
		target_build_id: first_text((dl.remote ?? {}).version_code, probe.version_code),
		target_version: first_text((dl.remote ?? {}).version_number, probe.version_number),
		previous_build_id: trim(ctx.loc?.build_id ?? ''),
		started: util.now_epoch(),
		finished: 0,
		error: ''
	};

	// 顺序是铁律：先把 flash-pending 落盘，再起 sysupgrade。
	// 反过来的话，设备恰好在这两条语句之间断电重启，就再也没人知道这次刷写发生过。
	// 落盘失败时绝不能刷：没有记录就没法在下次开机判断结果。
	if (!save_state(st)) {
		let msg = '写入刷写状态文件失败：' + STATE;
		eventlog.append('error', 'flash', msg);
		return { ok: false, state: 'idle', error: msg, errors: [ msg ] };
	}

	ensure_dir();

	let inner = sprintf('sysupgrade -c -k %s', util.shquote(file));
	try {
		fs.writefile(LOG, sprintf('# %s 发起刷写（%s）：%s\n', iso_or_epoch(st.started), trigger, inner));
	} catch (e) {
	}

	let res = util.run(sprintf('setsid sh -c %s >> %s 2>&1 < /dev/null & echo $!',
		util.shquote(inner), util.shquote(LOG)));
	let pid = util.to_int(trim(res.output ?? ''), 0);

	if (pid <= 0) {
		// 命令没起来：把已落盘的 pending 改成失败，别留一个永远等不到重启的 pending
		st.state = 'flash-failed';
		st.finished = util.now_epoch();
		st.error = '无法启动 sysupgrade 进程';
		save_state(st);
		eventlog.append('error', 'flash', st.error);
		return { ok: false, state: 'flash-failed', error: st.error, errors: [ st.error ] };
	}

	eventlog.append('info', 'flash', sprintf('已发起刷写（%s）：%s → %s',
		trigger, first_text(st.previous_build_id, '?'), first_text(st.target_build_id, '?')), {
		file: st.file,
		sha256: st.sha256,
		size: st.size,
		source: st.source,
		channel: st.channel,
		pid: pid
	});

	if (length(trim(ctx.conf?.webhook ?? '')))
		notify.post(ctx.conf.webhook, notify.payload('flash_started', ctx.loc, probe, {
			state: st.state,
			trigger: trigger,
			file: st.file,
			target_version: st.target_version,
			previous_build_id: st.previous_build_id
		}));

	return { ok: true, state: st.state, error: '', errors: [] };
}

// 开机闭环：只有「重启前留下的 flash-pending」才需要判断，其它一律不打扰。
// 两个分支都要写回状态文件（含 finished），保证下次开机不再重复上报。
function boot_check() {
	let st = load_state();
	let loc = local.identity();
	let cur = trim(loc.build_id ?? '');

	if (st == null || st.state != 'flash-pending')
		return {
			ok: true,
			changed: false,
			state: st?.state ?? 'idle',
			previous_build: trim(st?.previous_build_id ?? ''),
			current_build: cur
		};

	let target = trim(st.target_build_id ?? '');
	let same = length(cur) && length(target) && cur == target;

	st.state = same ? 'boot-confirmed' : 'flash-failed';
	st.finished = util.now_epoch();
	if (same)
		st.error = '';
	else
		st.error = sprintf('重启后构建标识未变：本机仍为 %s，目标 %s', first_text(cur, '?'), first_text(target, '?'));

	save_state(st);

	// 开机时不去探测远端：这里只用状态文件里的记录拼最小 remote 负载
	let remote = {
		source: st.source ?? '',
		version_code: target,
		source_date_epoch: 0,
		channel: st.channel ?? '',
		image: { name: fs.basename(st.file ?? ''), size: st.size ?? 0, sha256: st.sha256 ?? '' }
	};
	let conf = config.load();

	if (same) {
		eventlog.append('info', 'flash', sprintf('刷写已确认：本机构建 %s 与目标一致', cur), {
			file: st.file,
			target_version: st.target_version ?? ''
		});
	}
	else {
		eventlog.append('error', 'flash', st.error, {
			file: st.file,
			previous_build_id: st.previous_build_id ?? '',
			target_build_id: target
		});
	}

	if (length(trim(conf.webhook ?? '')))
		notify.post(conf.webhook, notify.payload(same ? 'flash_ok' : 'flash_failed', loc, remote, {
			state: st.state,
			trigger: st.trigger ?? '',
			error: st.error,
			target_version: st.target_version ?? '',
			previous_build_id: st.previous_build_id ?? ''
		}));

	return {
		ok: true,
		changed: true,
		state: st.state,
		previous_build: trim(st.previous_build_id ?? ''),
		current_build: cur
	};
}

function clear() {
	try {
		fs.unlink(STATE);
	} catch (e) {
	}

	eventlog.append('info', 'flash', '已清除刷写状态文件');
	return { ok: true };
}

return {
	STATE: STATE,
	DIR: DIR,
	LOG: LOG,
	status: status,
	guards: guards,
	start: start,
	boot_check: boot_check,
	clear: clear
};
