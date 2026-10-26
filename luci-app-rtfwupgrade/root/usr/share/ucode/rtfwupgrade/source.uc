'use strict';

// 源探测。只读取官方/构建系统一定自带的文件：
//   <dir>/version.buildinfo   构建标识（r<rev>-<sha>），与镜像内 BUILD_ID 同源
//   <dir>/profiles.json       目标元数据（version_number / source_date_epoch / profiles[]）
//   <base>/.versions.json     官方通道发现（可选，缺失则回退单通道）
//
// 两种 layout：
//   official  OpenWRT/ImmortalWRT 官方发布页结构
//             <base>[/<system>]/{snapshots|releases/<ver>}/targets/<target>/<subtarget>/
//   default   默认编译输出目录结构
//             <base>[/<system>]/targets/<target>/<subtarget>/

let util = require('rtfwupgrade.util');

function url_join(segments) {
	let url = '';

	for (let seg in segments) {
		let s = trim(seg ?? '');
		while (length(s) && substr(s, 0, 1) == '/')
			s = substr(s, 1);
		while (length(s) && substr(s, length(s) - 1) == '/')
			s = substr(s, 0, length(s) - 1);
		if (length(s))
			url += (length(url) ? '/' : '') + s;
	}
	return url;
}

// 远端属于哪个发行版：看**构建产物**的命名，不看站点域名。
// 官方源与单版本发布站的镜像名都以发行版开头（openwrt-… / immortalwrt-…），
// 这是构建系统自己写死的，比从 URL 里猜可靠得多。
// 回退顺序：镜像名前缀 → 源的 system 段 → 地址。
//   image_names  该源在当前目标下产出的镜像文件名数组（可为空）
function distro_from_image(names) {
	for (let n in names ?? []) {
		let m = match(lc(n ?? ''), /^([a-z0-9]+?)-/);
		if (m && (m[1] == 'openwrt' || m[1] == 'immortalwrt'))
			return m[1];
	}

	return '';
}

function distro_hint(url, system, names) {
	// 首选构建产物前缀
	let byImage = distro_from_image(names);
	if (length(byImage))
		return byImage;

	// 退路：源的 system 段与地址（仅在拿不到镜像名时使用）
	for (let probe in [ lc(system ?? ''), lc(url ?? '') ]) {
		if (match(probe, /immortalwrt/))
			return 'immortalwrt';
		if (match(probe, /openwrt/))
			return 'openwrt';
	}

	return '';
}

function distro_label(hint) {
	if (hint == 'immortalwrt') return 'ImmortalWrt';
	if (hint == 'openwrt') return 'OpenWrt';

	return hint;
}

function target_path(local) {
	let path = trim(local?.board_path ?? '');
	if (length(path))
		return path;

	return trim((local?.target ?? '') + '/' + (local?.subtarget ?? ''), '/');
}

function dir_of(src, channel, local) {
	let target = target_path(local);

	if (src.layout == 'default')
		return url_join([ src.url, src.system, 'targets', target ]);

	return url_join([ src.url, src.system, channel, 'targets', target ]);
}

function discover(src, timeout) {
	if (src.layout != 'official')
		return { list: [ 'current' ], origin: 'layout' };

	let res = util.http_get(url_join([ src.url, src.system, '.versions.json' ]), timeout ?? 15);
	if (!res.ok)
		return { list: [ 'snapshots' ], origin: 'default' };

	let parsed = util.parse_json(res.body);
	if (!parsed.ok)
		return { list: [ 'snapshots' ], origin: 'default' };

	let v = parsed.value ?? {};
	let list = [ 'snapshots' ];
	for (let ver in (v.versions_list ?? []))
		push(list, 'releases/' + ver);

	return {
		list: list,
		origin: '.versions.json',
		stable: trim(v.stable_version ?? ''),
		oldstable: trim(v.oldstable_version ?? '')
	};
}

function series_of(version) {
	let m = match(trim(version ?? ''), /^([0-9]+)\.([0-9]+)/);
	return m ? (m[1] + '.' + m[2]) : '';
}

// 发布通道列表里，同一版本线的最新一个（列表本身按版本降序，取第一个命中的即可）
function newest_in(list, pred) {
	for (let c in list) {
		if (match(c, /^releases\//) && pred(substr(c, 9)))
			return c;
	}

	return '';
}

function major_of(version) {
	let m = match(trim(version ?? ''), /^([0-9]+)\./);
	return m ? m[1] : '';
}

// 本机正在跑的那条线：release 用同版本线的最新发布版，snapshot 用快照通道。
function current_channel(disc, local) {
	let list = disc.list ?? [];

	if (local.version_kind != 'release')
		return list[0] ?? 'snapshots';

	let exact = 'releases/' + local.version;
	if (index(list, exact) >= 0)
		return exact;

	let series = series_of(local.version);
	let same = newest_in(list, function (v) {
		return series_of(v) == series;
	});

	return length(same) ? same : (list[0] ?? 'snapshots');
}

// 语义通道 → 实际目录。
// 关键点：这里只决定「去哪个目录取数据」，取回来之后仍然走同一套 probe + verdict，
// 判定策略不因通道而改变（版本号高的算更新、快照按源码时间、rebuild 只下载不刷写…）。
// 解析不出来时返回空串，由调用方明确报错，绝不悄悄换成别的通道。
function resolve_channel(disc, local, want) {
	let c = trim(want ?? '');
	let list = disc.list ?? [];

	// 空串 = 当前通道。'current' 是 default 布局的固定通道名（config.DEFAULT_CHANNEL），
	// CLI --channel current 也会传它，因此两者等价，都按「当前通道」解析。
	if (!length(c) || c == 'current')
		return current_channel(disc, local);
	if (c == 'snapshot')
		return 'snapshots';
	if (match(c, /^releases\//) || c == 'snapshots')
		return c;

	let stable = trim(disc.stable ?? '');
	let oldstable = trim(disc.oldstable ?? '');

	if (c == 'stable')
		return length(stable) ? ('releases/' + stable) : '';
	if (c == 'oldstable')
		return length(oldstable) ? ('releases/' + oldstable) : '';

	// 主/子版本都以本机的版本号为锚点。SNAPSHOT 构建没有版本号，
	// 退回当前通道会让用户「选了主版本却在探测 snapshots」，所以这里明确判为不可用。
	if (c == 'major') {
		let major = major_of(local.version);
		if (local.version_kind != 'release' || !length(major))
			return '';

		let hit = newest_in(list, function (v) { return major_of(v) == major; });
		return length(hit) ? hit : '';
	}

	if (c == 'minor') {
		let series = series_of(local.version);
		if (local.version_kind != 'release' || !length(series))
			return '';

		let hit = newest_in(list, function (v) { return series_of(v) == series; });
		return length(hit) ? hit : '';
	}

	return '';
}

// 兼容旧签名：指定了通道就优先，否则用当前通道。
// 注意「钉住」现在也可以是一个语义值，由 resolve_channel() 换算成目录。
function pick_channel(disc, local, pinned) {
	let pin = trim(pinned ?? '');

	if (length(pin))
		return resolve_channel(disc, local, pin) || pin;

	return current_channel(disc, local);
}

// 通道来源标签：界面用它区分「当前通道」与「用户选定」。
function channel_origin(disc, pinned, override) {
	if (length(trim(override ?? '')))
		return 'override';
	if (length(trim(pinned ?? '')))
		return 'config';

	return disc.origin;
}

// 探测时用的通道：显式 override > 配置里的语义通道 > 当前通道。
// 语义通道解析失败（源上已没有该版本线）时返回 error，由 probe() 如实报出来。
function resolve_for_probe(disc, local, pinned, override) {
	let want = trim(override ?? '');
	if (!length(want))
		want = trim(pinned ?? '');

	let channel = resolve_channel(disc, local, want);

	if (!length(channel)) {
		let names = { stable: '稳定版', oldstable: '旧稳定版', major: '当前主版本', minor: '当前子版本' };
		let label = names[want] ?? '';

		// 主/子版本对本机没有意义时（SNAPSHOT），单独说清楚原因
		if ((want == 'major' || want == 'minor') && local.version_kind != 'release')
			return {
				channel: '',
				error: sprintf('本机是 %s 构建，没有版本号可用于解析「%s」；请改用快照版或稳定版',
					local.version || 'snapshot', label)
			};

		return {
			channel: '',
			error: length(label)
				? sprintf('该源没有可用的「%s」通道（源公布的版本：stable=%s、oldstable=%s）',
					label, (disc.stable || '无'), (disc.oldstable || '无'))
				: sprintf('该源上没有通道 %s', want)
		};
	}

	return { channel: channel, error: '' };
}

function match_profile(meta, local) {
	let profiles = meta?.profiles ?? {};
	let board = trim(local?.board_name ?? '');

	if (length(board)) {
		for (let name in keys(profiles)) {
			let p = profiles[name] ?? {};
			if (index(p.supported_devices ?? [], board) >= 0)
				return { name: name, profile: p };
		}
	}

	let guess = replace(board, /,/g, '_');
	if (length(guess) && profiles[guess] != null)
		return { name: guess, profile: profiles[guess] };

	return null;
}

// 只把 squashfs 的 sysupgrade 镜像作为升级候选；其余镜像仅在高级列表中出现
function pick_image(images) {
	let sysup = filter(images ?? [], function (i) { return i.type == 'sysupgrade'; });
	let squash = filter(sysup, function (i) { return i.filesystem == 'squashfs'; });

	if (length(squash)) return squash[0];
	if (length(sysup)) return sysup[0];
	return null;
}

function probe(src, local, channel_override) {
	let disc = discover(src);
	let pin = trim(src?.channel ?? '');
	let override = trim(channel_override ?? '');
	let pick = resolve_for_probe(disc, local, pin, override);
	let channel = pick.channel;
	let dir = dir_of(src, channel, local);

	let out = {
		ok: false,
		source: src.name,
		label: src.label,
		url: src.url,
		layout: src.layout,
		system: src.system,
		channel: channel,
		channel_origin: channel_origin(disc, pin, override),
		channels: disc.list,
		stable: disc.stable ?? '',
		oldstable: disc.oldstable ?? '',
		dir: dir,
		version_code: '',
		version_number: '',
		source_date_epoch: 0,
		source_date_iso: '',
		profile_name: '',
		image: null,
		images: [],
		image_limit: 0,
		warnings: [],
		error: ''
	};

	if (!length(src.url)) {
		out.error = '源未配置 url。';
		return out;
	}

	// 语义通道解析不出来（源上没有这条版本线）：明确报错。
	// 绝不回落到别的通道 —— 那会给出一个「来自你没选的通道」的结论。
	if (length(pick.error)) {
		out.error = pick.error;
		return out;
	}

	// 钉住的通道已经不在源上了：照旧去探（404 会如实报错），但先把原因说清楚，
	// 否则用户只会看到一句「profiles.json 不可读：<一长串地址>」。
	if (length(pin) && src.layout == 'official' && index(disc.list ?? [], channel) < 0)
		push(out.warnings, sprintf('该源上已没有通道 %s（可选：%s）', channel, join('、', disc.list ?? [])));

	let bi = util.http_get(url_join([ dir, 'version.buildinfo' ]), 15);
	if (bi.ok)
		out.version_code = trim(bi.body);
	else
		push(out.warnings, 'version.buildinfo 不可读。');

	let pj = util.http_get(url_join([ dir, 'profiles.json' ]), 25);
	if (!pj.ok) {
		out.error = 'profiles.json 不可读：' + dir;
		return out;
	}

	let parsed = util.parse_json(pj.body);
	if (!parsed.ok) {
		out.error = 'profiles.json 解析失败：' + parsed.error;
		return out;
	}

	let meta = parsed.value ?? {};
	out.version_number = trim(meta.version_number ?? '');
	out.source_date_epoch = util.epoch_or_zero(meta.source_date_epoch);
	out.source_date_iso = util.iso_utc(out.source_date_epoch);

	if (!length(out.version_code))
		out.version_code = trim(meta.version_code ?? '');

	let hit = match_profile(meta, local);
	if (hit == null) {
		out.error = '该源未收录此设备（board_name=' + (local.board_name ?? '?') + '）。';
		return out;
	}

	out.profile_name = hit.name;
	out.images = hit.profile.images ?? [];
	out.image = pick_image(out.images);
	out.image_limit = util.epoch_or_zero((hit.profile.file_size_limits ?? {}).image);

	// profiles.json 直接给出该设备的产物前缀与厂商/型号，
	// 比从镜像文件名或 /tmp/sysinfo 反推更可靠。
	out.image_prefix = trim(hit.profile.image_prefix ?? '');
	let titles = hit.profile.titles ?? [];
	if (length(titles)) {
		out.device_vendor = trim(titles[0].vendor ?? '');
		out.device_model = trim(titles[0].model ?? '');
	}

	if (out.image == null)
		push(out.warnings, '该 profile 没有 sysupgrade 镜像。');

	// 远端发行版：profiles.json 的 image_prefix 是最直接的依据（它就是产物前缀），
	// 其次退回镜像文件名，最后才用源的 system 段与地址。
	let names = map(out.images ?? [], function (i) { return i.name ?? ''; });
	if (length(out.image_prefix))
		push(names, 0, out.image_prefix);
	let hint = distro_hint(src.url, src.system, names);

	// 本机发行版：os-release 的 ID（immortalwrt / openwrt），而不是显示名。
	let hostId = lc(trim(local?.distribution_id ?? ''));

	out.distribution_hint = hint;
	out.distribution_id = hostId;

	if (length(hint) && length(hostId) && hint != hostId)
		push(out.warnings, sprintf('该源属于 %s，而本机运行 %s：跨发行版刷写属于「换系统」，配置文件可能不兼容。',
			distro_label(hint), local.distribution));

	out.ok = true;
	return out;
}

return {
	url_join: url_join,
	dir_of: dir_of,
	discover: discover,
	distro_hint: distro_hint,
	series_of: series_of,
	pick_channel: pick_channel,
	current_channel: current_channel,
	resolve_channel: resolve_channel,
	resolve_for_probe: resolve_for_probe,
	channel_origin: channel_origin,
	match_profile: match_profile,
	pick_image: pick_image,
	probe: probe
};
