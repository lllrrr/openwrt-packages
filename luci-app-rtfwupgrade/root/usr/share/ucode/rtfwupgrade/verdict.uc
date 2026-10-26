'use strict';

// 判定"有没有更新"。只用两侧都必然自带的字段：
//   身份：远端 version.buildinfo  ↔ 本机 BUILD_ID
//   方向：远端 source_date_epoch ↔ 本机 OPENWRT_BUILD_DATE（同为 SOURCE_DATE_EPOCH）
//   发行版通道另用 version_number 做语义比较
// 永不使用 HTTP Last-Modified / 文件 mtime / 文件名中的日期。

let util = require('rtfwupgrade.util');

const LABELS = {
	same: '已是最新',
	update: '有可用更新',
	downgrade: '远端更旧（可降级）',
	rebuild: '同版本、不同构建',
	incomparable: '无法比较'
};

function fmt_epoch(epoch) {
	let s = util.iso_utc(epoch);
	return length(s) ? s : ('epoch ' + util.epoch_or_zero(epoch));
}

function compare(local, remote) {
	let out = {
		state: 'incomparable',
		label: LABELS.incomparable,
		evidence: '',
		local: {
			version: trim(local?.version ?? ''),
			build_id: trim(local?.build_id ?? ''),
			build_date: util.epoch_or_zero(local?.build_date),
			build_date_iso: fmt_epoch(local?.build_date)
		},
		remote: {
			version: trim(remote?.version_number ?? ''),
			build_id: trim(remote?.version_code ?? ''),
			build_date: util.epoch_or_zero(remote?.source_date_epoch),
			build_date_iso: fmt_epoch(remote?.source_date_epoch),
			channel: trim(remote?.channel ?? '')
		}
	};

	if (remote == null || !remote.ok) {
		out.evidence = (remote?.error ?? '') || '远端探测失败。';
		return out;
	}

	let lc = out.local.build_id, rc = out.remote.build_id;
	if (length(lc) && lc == rc) {
		out.state = 'same';
		out.evidence = '构建标识一致：' + lc + '。';
		out.label = LABELS.same;
		return out;
	}

	let lv = out.local.version, rv = out.remote.version;
	if (lv != 'SNAPSHOT' && rv != 'SNAPSHOT' && length(lv) && length(rv)) {
		let c = util.version_cmp(rv, lv);
		if (c != null) {
			out.state = (c > 0) ? 'update' : ((c < 0) ? 'downgrade' : 'rebuild');
			out.evidence = sprintf('发行版版本：本机 %s → 远端 %s。', lv, rv);
			out.label = LABELS[out.state];
			return out;
		}
	}

	let ls = out.local.build_date, rs = out.remote.build_date;
	if (ls && rs) {
		out.state = (rs > ls) ? 'update' : ((rs < ls) ? 'downgrade' : 'rebuild');
		out.evidence = sprintf('源码构建时间：本机 %s，远端 %s。', out.local.build_date_iso, out.remote.build_date_iso);
		out.label = LABELS[out.state];
		return out;
	}

	out.evidence = '缺少可比字段（BUILD_ID / OPENWRT_BUILD_DATE）。';
	return out;
}

return {
	LABELS: LABELS,
	compare: compare
};
