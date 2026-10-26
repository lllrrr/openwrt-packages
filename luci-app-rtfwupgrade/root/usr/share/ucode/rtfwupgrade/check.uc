'use strict';

// 一次检测的完整闭环：选源 → 探测 → 判定 → 缓存 → 事件日志 → 检测 webhook。
// CLI 与 rpcd 共用这一份，避免「界面检测有日志、定时检测没日志」这类分叉。

let util = require('rtfwupgrade.util');
let local = require('rtfwupgrade.local');
let config = require('rtfwupgrade.config');
let source = require('rtfwupgrade.source');
let verdict = require('rtfwupgrade.verdict');
let state = require('rtfwupgrade.state');
let eventlog = require('rtfwupgrade.eventlog');
let notify = require('rtfwupgrade.notify');
let version = require('rtfwupgrade.version');

function pick_source(conf, name) {
	let want = trim(name ?? '');
	if (length(want)) {
		let hit = filter(conf.sources, function (s) { return s.name == want; });
		return length(hit) ? hit[0] : null;
	}
	return config.active(conf);
}

// 只在「需要用户行动」的事件上投递 webhook：
//   - 有可用更新 / 同版本不同构建
//   - 检测失败
// 普通「已是最新」「远端更旧」不打扰；download_done 仍由 download.uc 投递。
function notify_check(conf, loc, remote, result, src) {
	if (!length(trim(conf?.webhook ?? '')))
		return;

	let st = result?.verdict?.state ?? '';
	if (result.ok && st != 'update' && st != 'rebuild')
		return;

	let payload = notify.payload(result.ok ? 'check_update' : 'check_failed', loc, remote, {
		state: st,
		error: result.ok ? '' : ((remote?.error ?? result.error) || ''),
		source: src?.name ?? ''
	});

	notify.post(conf.webhook, payload);
}

function run(opts) {
	let o = opts ?? {};
	let conf = o.conf ?? config.load();
	let src = pick_source(conf, o.source);
	let loc = local.identity();
	let result;

	if (src == null) {
		result = {
			ok: false,
			ts: util.now_epoch(),
			version: version.VERSION,
			local: loc,
			remote: null,
			verdict: verdict.compare(loc, null),
			source: null,
			unattended: conf.unattended,
			error: '没有可用的源'
		};

		state.save_last(result);
		eventlog.append('error', 'check', '没有可用的源');
		notify_check(conf, loc, null, result, null);
		return result;
	}

	let remote = source.probe(src, loc, o.channel ?? '');
	result = {
		ok: remote.ok,
		ts: util.now_epoch(),
		version: version.VERSION,
		local: loc,
		remote: remote,
		verdict: verdict.compare(loc, remote),
		source: { name: src.name, label: src.label, url: src.url, layout: src.layout, system: src.system },
		unattended: conf.unattended
	};

	state.save_last(result);
	eventlog.append(remote.ok ? 'info' : 'error', 'check',
		sprintf('%s：%s', result.verdict.label, result.verdict.evidence || remote.error || ''),
		{
			source: src.name,
			remote: remote.version_code ?? '',
			channel: remote.channel ?? '',
			state: result.verdict.state
		});
	notify_check(conf, loc, remote, result, src);

	return result;
}

return {
	run: run
};
