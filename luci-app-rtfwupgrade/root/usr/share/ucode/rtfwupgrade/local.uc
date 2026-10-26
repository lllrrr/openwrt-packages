'use strict';

// 读取"我是谁、我在跑什么"：全部来自官方必带字段
//   /usr/lib/os-release -> BUILD_ID / OPENWRT_BUILD_DATE / VERSION / OPENWRT_BOARD
//   /tmp/sysinfo/{board_name,model}

let util = require('rtfwupgrade.util');

function identity() {
	let osr = util.read_kv('/usr/lib/os-release');
	let board = osr.OPENWRT_BOARD ?? '';
	let parts = split(board, '/');
	let version = trim(osr.VERSION ?? '');
	let build_date = util.epoch_or_zero(osr.OPENWRT_BUILD_DATE);

	return {
		hostname: util.hostname(),
		distribution: trim(osr.NAME ?? ''),
		// os-release 的 ID 是发行版的自报身份（immortalwrt / openwrt），
		// 比 NAME 的显示名更适合做判断依据。
		distribution_id: lc(trim(osr.ID ?? '')),
		model: util.file_trim('/tmp/sysinfo/model'),
		board_name: util.file_trim('/tmp/sysinfo/board_name'),
		board_path: board,
		target: parts[0] ?? '',
		subtarget: parts[1] ?? '',
		arch: trim(osr.OPENWRT_ARCH ?? ''),
		version: version,
		version_id: trim(osr.VERSION_ID ?? ''),
		version_kind: (version == 'SNAPSHOT') ? 'snapshot' : 'release',
		build_id: trim(osr.BUILD_ID ?? ''),
		build_date: build_date,
		build_date_iso: util.iso_utc(build_date)
	};
}

return {
	identity: identity
};
