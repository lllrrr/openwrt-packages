#!/usr/bin/env ucode
'use strict';

// luci-app-rtfwupgrade CLI（检测 + 下载 + 刷写）

let util = require('rtfwupgrade.util');
let local = require('rtfwupgrade.local');
let config = require('rtfwupgrade.config');
let check = require('rtfwupgrade.check');
let state = require('rtfwupgrade.state');
let scheduler = require('rtfwupgrade.scheduler');
let download = require('rtfwupgrade.download');
let flash = require('rtfwupgrade.flash');
let eventlog = require('rtfwupgrade.eventlog');

let version = require('rtfwupgrade.version');
const VERSION = version.VERSION;

function usage() {
	print("用法: rtfwupgrade.sh <命令> [选项]\n\n");
	print("命令:\n");
	print("  status           本机标识与最近一次检测结果\n");
	print("  sources          已配置的源（含激活源）\n");
	print("  check            检测更新（默认使用激活源）\n");
	print("  cron             定时任务入口：检测 + 按无人值守档位自动下载/刷写\n");
	print("  schedule         查看/同步 crontab 定时任务（--apply 写入）\n");
	print("  flash            刷写检查：打印护栏与将要执行的命令（加 --yes 才刷）\n");
	print("  flash-status     当前刷写状态（--boot-check 供 init 脚本自检）\n");
	print("  flash-clear      清除刷写状态文件\n");
	print("  version          版本号\n\n");
	print("选项:\n");
	print("  --source <name>  仅本次使用指定源\n");
	print("  --channel <chan> 仅本次使用指定通道（语义值如 stable，或目录如 releases/25.12.2）\n");
	print("  --json           以 JSON 输出\n");
	print("  --apply          仅 schedule：把调度写入 crontab\n");
	print("  --yes            仅 flash：护栏通过时真正刷写\n");
	print("  --force          仅 flash：放行「跨发行版」与「跨源」两条护栏\n");
	print("  --boot-check     仅 flash-status：重启后确认刷写结果\n");
}

function parse_argv(argv) {
	let o = { cmd: '', source: '', channel: '', json: false, apply: false, yes: false, force: false, boot_check: false };
	let i = 0;

	while (i < length(argv)) {
		let a = trim(argv[i] ?? '');
		if (a == '--json')
			o.json = true;
		else if (a == '--apply')
			o.apply = true;
		else if (a == '--yes')
			o.yes = true;
		else if (a == '--force')
			o.force = true;
		else if (a == '--boot-check')
			o.boot_check = true;
		else if (a == '--source') { i++; o.source = trim(argv[i] ?? ''); }
		else if (a == '--channel') { i++; o.channel = trim(argv[i] ?? ''); }
		else if (a == '-h' || a == '--help') { o.cmd = 'help'; }
		else if (!length(o.cmd)) { o.cmd = a; }
		i++;
	}
	return o;
}

function run_check(opts, conf) {
	return check.run({
		conf: conf ?? config.load(),
		source: opts.source,
		channel: opts.channel
	});
}

// 定时任务入口：检测（check.uc 已记录事件/投递 webhook）→ 按档位决定自动下载/刷写。
// 下载是异步的（setsid 后台 curl），同一 tick 里拿不到 verified，所以顺序必须是：
//   ① status() 收尾上一轮下载 → ② 上一轮已 verified 且本次判 update 且档位 2 → 发起刷写
//   → ③ 本 tick 才发起下载时直接返回，等下一 tick 再收尾。
function run_cron(opts) {
	let conf = config.load();

	// ① 先收尾上一轮下载：后台进程已退出时 status() 顺手做校验并投递 webhook。
	// 档位 0 不碰下载器，保持「只检测」的原有行为。
	let dl = (conf.unattended >= 1) ? (download.status() ?? {}) : {};

	let r = run_check(opts, conf);
	let out = {
		ok: r.ok,
		ts: util.now_epoch(),
		verdict: r.verdict?.state ?? '',
		label: r.verdict?.label ?? '',
		unattended: conf.unattended,
		download: dl.state ?? 'idle',
		action: 'none'
	};

	let vs = r.verdict?.state ?? '';

	// 档位 2 的自动刷写只认 update；rebuild 永远只下载不刷。
	// 绝不传 force：自动路径不放行任何一条护栏。
	if (conf.unattended >= 2 && vs == 'update' && dl.state == 'verified') {
		let fr = null;
		try {
			fr = flash.start({ trigger: 'auto' });
		} catch (e) {
			fr = { ok: false, error: sprintf('刷写模块异常：%s', e) };
		}

		if (fr != null && fr.ok == true) {
			out.action = 'flash';
			out.flash = fr.state ?? '';
			eventlog.append('warn', 'cron', sprintf('无人值守档位 2：已发起自动刷写（%s）', fr.state ?? '?'));
		}
		else {
			out.action = 'flash-failed';
			out.error = fr?.error ?? '?';
			eventlog.append('warn', 'cron', '自动刷写失败：' + (fr?.error ?? '?'));
		}

		return out;
	}

	// update 与 rebuild 都意味着远端有一份新构建；downgrade 不自动下载。
	if ((vs == 'update' || vs == 'rebuild') && conf.unattended >= 1) {
		let d = download.start(opts.source ?? '', opts.channel ?? '');

		if (d.state == 'running') {
			out.action = 'download';
		}
		else if (d.state == 'verified') {
			out.action = d.skipped ? 'already-downloaded' : 'verified';
		}
		else {
			out.action = 'download-failed';
			out.error = d.error ?? '?';
			eventlog.append('error', 'download', '自动下载失败：' + (d.error ?? '?'));
		}
	}

	return out;
}

function fmt_size(bytes) {
	let n = int(bytes ?? 0);
	if (!n)
		return '未知';
	if (n >= 1048576)
		return sprintf('%.1f MB', n / 1048576.0);
	return sprintf('%.1f KB', n / 1024.0);
}

function print_check_human(r) {
	let loc = r.local ?? {};
	let rem = r.remote ?? {};
	let vs = r.verdict ?? {};

	print(sprintf('本机   : %s (%s %s)\n', loc.hostname ?? '', loc.distribution ?? '', loc.version ?? ''));
	print(sprintf('板型   : %s [%s]\n', loc.board_name ?? '?', loc.target ?? '?'));
	print(sprintf('构建   : %s @ %s\n', loc.build_id ?? '?', loc.build_date_iso ?? '?'));

	if (rem.ok) {
		print(sprintf('源     : %s <%s> [%s]\n', rem.label ?? '', rem.url ?? '', rem.layout ?? ''));
		print(sprintf('通道   : %s（来自 %s）\n', rem.channel ?? '', rem.channel_origin ?? ''));
		print(sprintf('远端   : %s @ %s\n', rem.version_code ?? '?', rem.source_date_iso || '?'));
	}
	else {
		print(sprintf('源     : %s <%s>\n', rem.label ?? r.source?.label ?? '', rem.url ?? r.source?.url ?? ''));
	}

	print(sprintf('结论   : %s\n', vs.label ?? '未知'));
	print(sprintf('依据   : %s\n', vs.evidence ?? ''));

	if (rem.image != null)
		print(sprintf('镜像   : %s (%s)\n', rem.image.name ?? '', fmt_size(rem.image.size)));

	if (length(rem.warnings ?? []))
		for (let w in rem.warnings)
			print(sprintf('提示   : %s\n', w));

	if (!r.ok)
		print(sprintf('错误   : %s\n', rem.error ?? r.error ?? '探测失败'));
}

function print_status_human(s) {
	let loc = s.local ?? {};
	print(sprintf('主机   : %s\n', loc.hostname ?? ''));
	print(sprintf('系统   : %s %s (%s)\n', loc.distribution ?? '', loc.version ?? '', loc.version_kind ?? ''));
	print(sprintf('板型   : %s [%s] %s\n', loc.board_name ?? '?', loc.board_path ?? loc.target ?? '?', loc.model ?? ''));
	print(sprintf('构建   : %s @ %s\n', loc.build_id ?? '?', loc.build_date_iso ?? '?'));

	let fl = flash.status() ?? {};
	print(sprintf('刷写   : %s\n', fl.state ?? 'idle'));

	let last = s.last;
	if (last == null) {
		print("最近   : 尚未检测\n");
		return;
	}
	print(sprintf('最近   : %s（%s）\n', last.verdict?.label ?? '未知', util.iso_utc(last.ts) || ('epoch ' + (last.ts ?? 0))));
	let rid = trim(last.remote?.version_code ?? '');
	print(sprintf('       源 %s，远端 %s\n', last.source?.label ?? last.remote?.label ?? '?', length(rid) ? rid : '-'));
}

function print_sources_human(conf) {
	for (let s in conf.sources) {
		print(sprintf('%s %-22s %-10s %s%s\n',
			(s.name == conf.active_source) ? '*' : ' ',
			s.name, s.layout, s.url + (length(s.system) ? (' / ' + s.system) : ''),
			length(s.channel ?? '') ? ('  通道=' + s.channel) : ''));
	}
	print(sprintf("激活源  : %s\n", conf.active_source ?? '无'));
	print(sprintf("无人值守: %d 档（%s）\n", conf.unattended, config.unattended_label(conf.unattended)));
	print(sprintf("调度    : %s\n", config.schedule_label(conf)));
	print(sprintf("定时行  : %s\n", scheduler.cron_line(conf) || '（关闭）'));
}

// ── 刷写（sysupgrade -c -k）：默认只检查，--yes 才真正刷 ────────────────────

function flash_opts(opts) {
	return {
		source: opts.source ?? '',
		channel: opts.channel ?? '',
		force: opts.force == true,
		trigger: 'manual'
	};
}

// 待刷镜像取下载器的候选文件；没有下载记录时退回刷写状态里记的那一份
function flash_file() {
	let d = download.status() ?? {};
	let f1 = trim(d.file ?? '');
	if (length(f1))
		return f1;

	let s = flash.status() ?? {};
	return trim(s.file ?? '');
}

// 刷写命令只有这一种形式：保留配置本就是默认（-n 才关），-k 记已装包，-c 保留 /etc 改动
function flash_command(file) {
	return sprintf('sysupgrade -c -k %s', length(file) ? util.shquote(file) : '<镜像绝对路径>');
}

function print_flash_human(g, file) {
	print(sprintf('护栏   : %s\n', g.ok == true ? '通过' : '未通过'));
	for (let e in g.errors ?? [])
		print(sprintf('阻断   : %s\n', e));
	for (let w in g.warnings ?? [])
		print(sprintf('提示   : %s\n', w));
	print(sprintf('镜像   : %s\n', length(file) ? file : '（无）'));
	print(sprintf('命令   : %s\n', flash_command(file)));
}

function print_flash_status_human(s) {
	print(sprintf('刷写   : %s\n', s.state ?? 'idle'));
	if (length(trim(s.trigger ?? '')))
		print(sprintf('触发   : %s\n', s.trigger));
	if (length(trim(s.source ?? '')) || length(trim(s.channel ?? '')))
		print(sprintf('来源   : %s / %s\n', s.source ?? '-', s.channel ?? '-'));
	if (length(trim(s.target_build_id ?? '')) || length(trim(s.target_version ?? '')))
		print(sprintf('目标   : %s @ %s\n', s.target_build_id ?? '?', s.target_version ?? '?'));
	if (length(trim(s.previous_build_id ?? '')))
		print(sprintf('原构建 : %s\n', s.previous_build_id));
	if (length(trim(s.file ?? '')))
		print(sprintf('镜像   : %s（%s）\n', s.file, s.sha256 ? substr(s.sha256, 0, 12) : '-'));
	if (int(s.started ?? 0))
		print(sprintf('发起   : %s\n', util.iso_utc(s.started) || ('epoch ' + s.started)));
	if (int(s.finished ?? 0))
		print(sprintf('结束   : %s\n', util.iso_utc(s.finished) || ('epoch ' + s.finished)));
	if (length(trim(s.error ?? '')))
		print(sprintf('错误   : %s\n', s.error));
}

function print_boot_check_human(b) {
	print(sprintf('重启后 : %s\n', b.state ?? '?'));
	print(sprintf('构建   : %s%s\n',
		b.current_build ?? '?',
		b.changed == true ? '' : sprintf('（未变，期望 %s）', b.previous_build ?? '?')));
}

// flash：不给 --yes 时只检查护栏与将要执行的命令，绝不写状态文件。
// 退出码：未加 --yes 恒为 0（只报告）；加了 --yes 则在护栏阻断或发起失败时为 1。
function run_flash(opts) {
	let o = flash_opts(opts);
	let g = flash.guards(o) ?? { ok: false, errors: [ '护栏检查不可用' ], warnings: [] };
	let file = flash_file();
	let r = null;

	if (opts.yes == true && g.ok == true)
		r = flash.start(o);

	if (opts.json) {
		let out = { ok: g.ok == true, guards: g, file: file, command: flash_command(file), flashed: r?.ok == true };
		if (r != null) {
			out.state = r.state ?? '';
			out.error = r.error ?? '';
			out.errors = r.errors ?? [];
		}
		print(sprintf('%J\n', out));
		return (opts.yes == true && r?.ok != true) ? 1 : 0;
	}

	print_flash_human(g, file);

	if (opts.yes != true) {
		print((g.ok == true ? '提示   : 仅检查，未刷写；确认无误后加 --yes 真正刷写\n'
			: '提示   : 护栏未通过，修好后再试\n'));
		return 0;
	}

	if (g.ok != true) {
		print("结果   : 护栏未通过，已放弃刷写\n");
		return 1;
	}

	if (r?.ok == true) {
		print(sprintf('结果   : 已发起刷写（%s），设备稍后重启\n', r.state ?? 'flash-pending'));
		return 0;
	}

	for (let e in r?.errors ?? [])
		print(sprintf('阻断   : %s\n', e));
	print(sprintf('结果   : 刷写未发起（%s）\n', r?.error ?? '未知错误'));
	return 1;
}

// flash-status：--boot-check 供 init 脚本调用，非「待确认」时静默退出，不打扰启动日志
function run_flash_status(opts) {
	let s = flash.status() ?? { state: 'idle' };

	if (opts.boot_check == true) {
		if ((s.state ?? 'idle') != 'flash-pending')
			return 0;

		let b = flash.boot_check() ?? {};
		if (opts.json)
			print(sprintf('%J\n', b));
		else
			print_boot_check_human(b);

		return b.ok == true ? 0 : 1;
	}

	if (opts.json) {
		print(sprintf('%J\n', s));
		return 0;
	}

	print_flash_status_human(s);
	return 0;
}

function run_flash_clear(opts) {
	let r = flash.clear() ?? {};
	if (opts.json) {
		print(sprintf('%J\n', r));
		return 0;
	}
	print("已清除刷写状态文件\n");
	return 0;
}

let opts = parse_argv(ARGV ?? []);
let conf = config.load();

switch (opts.cmd) {
case 'check': {
	let r = run_check(opts, conf);
	if (opts.json) print(sprintf('%J\n', r));
	else print_check_human(r);
	exit(r.ok ? 0 : 1);
	break;
}
case 'status': {
	let r = {
		version: VERSION,
		ts: util.now_epoch(),
		local: local.identity(),
		config: conf,
		last: state.load_last()
	};
	if (opts.json) print(sprintf('%J\n', r));
	else print_status_human(r);
	break;
}
case 'sources': {
	let r = { config: conf };
	if (opts.json) print(sprintf('%J\n', r));
	else print_sources_human(conf);
	break;
}
case 'cron': {
	let r = run_cron(opts);
	if (opts.json) print(sprintf('%J\n', r));
	else print(sprintf('%s：%s（档位 %d，动作 %s%s）\n',
		r.label || '未检测', r.verdict || '-', r.unattended, r.action,
		r.error ? ('，' + r.error) : ''));
	break;
}
case 'flash': {
	exit(run_flash(opts));
	break;
}
case 'flash-status': {
	exit(run_flash_status(opts));
	break;
}
case 'flash-clear': {
	exit(run_flash_clear(opts));
	break;
}
case 'schedule': {
	let st = scheduler.status();
	if (opts.apply) {
		let r = scheduler.sync();
		if (opts.json) print(sprintf('%J\n', r));
		else print((r.changed ? '已写入：' : '无需变更：') + (r.line || '（定时任务已关闭）') + "\n");
		break;
	}
	if (opts.json) print(sprintf('%J\n', st));
	else {
		print(sprintf('调度    : %s\n', st.schedule || '关闭'));
		print(sprintf('期望行  : %s\n', st.wanted || '（无）'));
		print(sprintf('实际行  : %s\n', st.applied || '（无）'));
		print(sprintf('是否一致: %s\n', st.in_sync ? '是' : '否'));
	}
	break;
}
case 'version':
	print(VERSION + "\n");
	break;
default:
	usage();
	exit(1);
}
