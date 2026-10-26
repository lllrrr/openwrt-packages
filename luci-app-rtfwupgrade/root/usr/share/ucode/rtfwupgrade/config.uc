'use strict';

// UCI 配置读取（/etc/config/rtfwupgrade）。
// 源列表可存多条，但同一时刻只有一条 active_source 生效。
//
// 布局类型只有两种：
//   official  OpenWRT/ImmortalWRT 官方发布页结构 root/releases/release/targets
//   default   默认编译输出目录结构 root/targets
// 旧配置里的 bin_targets_root 只是历史别名，读入时归一化为 default。

let uci = require('uci');

const CONFIG = 'rtfwupgrade';
const LAYOUTS = [ 'official', 'default' ];
const LAYOUT_ALIASES = { bin_targets_root: 'default' };
const SCHEDULE_KINDS = [ 'off', 'daily', 'weekly', 'monthly' ];
// 无人值守只有三档：0 只检测、1 自动下载、2 自动下载并刷写。
const UNATTENDED_LEVELS = [ 0, 1, 2 ];
// 注意：ucode 的 substr 按字节切，中文字符 3 字节 —— 取星期必须用数组映射
const WEEKDAY_LABELS = [ '一', '二', '三', '四', '五', '六', '日' ];

function normalize_layout(layout) {
	let value = trim(layout ?? '');
	return LAYOUT_ALIASES[value] ?? value;
}

// 通道按源存放：官方站有 snapshots 与多个 releases，单版本发布站（default 布局）
// 只有一层 targets 目录，所以通道不能做成全局开关。
//   ''                当前通道（snapshot 看 snapshots，release 看同版本线）
//   'snapshots'       显式钉死在快照通道
//   'releases/<ver>'  显式钉死在某个发布版本通道
//
// default 布局没有可选项，通道恒为 'current'：界面上照常显示它（否则用户会以为
// 漏了一个字段），但列表只有这一项、没有别的可选，也就无从更改。
const DEFAULT_CHANNEL = 'current';

// 语义通道：存的是「跟随哪条线」，不是某个补丁版本的具体目录。
// 每次探测按源上的 .versions.json 现算目标目录，所以「稳定版」会随源前进，
// 不会把用户钉死在 25.12.2 这种会过期的具体版本上。
//   ''         当前通道（本机运行的那条线，snapshot 看 snapshots、release 看同版本线）
//   snapshot   快照版
//   stable     稳定版（源公布的 stable_version）
//   oldstable  旧稳定版（源公布的 oldstable_version）
//   major      当前主版本（本机主版本号的最新发布版，如 25.x）
//   minor      当前子版本（本机小版本线的最新发布版，如 25.12.x）
const CHANNELS = [ '', 'snapshot', 'stable', 'oldstable', 'major', 'minor' ];
// 兼容旧配置与 CLI --channel：具体目录仍然可以被直接指定
const LEGACY_CHANNEL_RE = /^(snapshots|releases\/[A-Za-z0-9._-]+)$/;

function default_channel(layout) {
	return (normalize_layout(layout ?? '') == 'default') ? DEFAULT_CHANNEL : '';
}

function normalize_channel(channel, layout) {
	let value = normalize_layout(layout ?? '');
	if (value != 'official')
		return '';

	let c = trim(channel ?? '');
	if (!length(c))
		return '';
	if (index(CHANNELS, c) >= 0)
		return c;
	if (match(c, LEGACY_CHANNEL_RE))
		return c;

	return '';
}

function defaults() {
	return {
		unattended: 0,
		flash_allow_cross_distro: 0,
		schedule_kind: 'daily',
		schedule_time: '04:00',
		schedule_weekday: 1,
		schedule_day: 1,
		webhook: '',
		// 内置只有两个官方源：布局说明的样本，不代表用户实际该用哪个。
		// ID 直接用发行版名，与 os-release 的 ID 对齐，便于判断「源与本机是否同族」。
		active_source: 'openwrt',
		sources: [
			{ name: 'openwrt', label: 'OpenWrt 官方', url: 'https://downloads.openwrt.org', layout: 'official', system: '', channel: '' },
			{ name: 'immortalwrt', label: 'ImmortalWrt 官方', url: 'https://downloads.immortalwrt.org', layout: 'official', system: '', channel: '' }
		]
	};
}

// 档位只认 0/1/2：手改配置写进来的 99 不能被当成「全自动」，一律落回 0。
// ucode 没有 isNaN()，NaN 用 n != n 判断（int() 转换失败返回 NaN）。
function normalize_unattended(v) {
	let n = int(v ?? 0);
	if (n != n)
		return 0;

	return (index(UNATTENDED_LEVELS, n) >= 0) ? n : 0;
}

// 0/1 开关；只把非零整数视为开启，其它一律关闭。
function normalize_switch(v) {
	let n = int(v ?? 0);
	if (n != n)
		return 0;

	return (n == 0) ? 0 : 1;
}

function section_name(s) {
	return s['.name'] ?? s.name ?? '';
}

function load() {
	let g = {};
	let sources = [];

	try {
		let ctx = uci.cursor();

		// rpcd 是长驻进程，而 ucode 的 uci 模块带进程级配置缓存：
		// 不显式 reload 就会读到本进程启动时的旧配置 —— 表现为切换激活源之后
		// 仍然去探测上一个源，结论来源与界面显示不一致。
		ctx.load(CONFIG);

		g = ctx.get_all(CONFIG, 'globals') ?? {};

		ctx.foreach(CONFIG, 'source', function (s) {
			let name = section_name(s);
			if (!length(name))
				return;
			let layout = normalize_layout(s.layout ?? 'official');
			push(sources, {
				name: name,
				label: trim(s.label ?? name),
				url: trim(s.url ?? ''),
				layout: layout,
				system: trim(s.system ?? ''),
				channel: normalize_channel(s.channel ?? '', layout)
			});
		});
	} catch (e) {
		g = {};
		sources = [];
	}

	if (!length(sources))
		sources = defaults().sources;

	// 源只有“存在”与“激活”两种状态：没有 enabled 中间态。
	// 激活源缺失或指向不存在的段时，退回列表里的第一个源。
	let active = trim(g.active_source ?? '');
	let hit = filter(sources, function (s) { return s.name == active; });
	if (!length(hit))
		active = length(sources) ? sources[0].name : '';

	return {
		// 用户亲自确认过的固件来源（源段名 / ID）。
		// 空串 = 从未确认过，界面据此提示「先确认当前源」。
		// 与 active_source 的区别：active_source 随时会随「切换源」按钮改变，
		// 而本字段只在用户确认（或放行跨源后立即刷写）时才更新，
		// 因此可以判断「用户当前看到的检测结论，是否来自他确认过的那台设备的固件来源」。
		current_firmware_source: trim(g.current_firmware_source ?? ''),
		unattended: normalize_unattended(g.unattended),
		// 跨发行版放行只是**手工路径的持久默认**；自动刷写路径永不使用 force。
		flash_allow_cross_distro: normalize_switch(g.flash_allow_cross_distro),
		schedule_kind: trim(g.schedule_kind ?? 'daily'),
		schedule_time: trim(g.schedule_time ?? '04:00'),
		schedule_weekday: int(g.schedule_weekday ?? 1),
		schedule_day: int(g.schedule_day ?? 1),
		webhook: trim(g.webhook ?? ''),
		active_source: active,
		sources: sources
	};
}

function active(conf) {
	let c = conf ?? load();
	let hit = filter(c.sources, function (s) { return s.name == c.active_source; });
	return length(hit) ? hit[0] : null;
}

// 把调度配置翻成 5 段 cron（scheduler.uc 写 crontabs 用；也用于界面与日志里的可读说明）
function schedule_cron(conf) {
	let kind = trim(conf?.schedule_kind ?? 'daily');
	if (kind == 'off')
		return '';

	let t = match(trim(conf?.schedule_time ?? '04:00'), /^([0-9]{1,2}):([0-9]{2})$/);
	let hour = t ? '' + int(t[1]) : '4';
	let min = t ? '' + int(t[2]) : '0';

	if (kind == 'weekly')
		return sprintf('%s %s * * %d', min, hour, int(conf?.schedule_weekday ?? 1));
	if (kind == 'monthly')
		return sprintf('%s %s %d * *', min, hour, int(conf?.schedule_day ?? 1));

	return sprintf('%s %s * * *', min, hour);
}

function schedule_label(conf) {
	let kind = trim(conf?.schedule_kind ?? 'daily');
	if (kind == 'off')
		return '关闭';

	let time = trim(conf?.schedule_time ?? '04:00');
	if (kind == 'weekly')
		return sprintf('每周%s %s', WEEKDAY_LABELS[int(conf?.schedule_weekday ?? 1) - 1] ?? '?', time);

	if (kind == 'monthly')
		return sprintf('每月 %d 号 %s', int(conf?.schedule_day ?? 1), time);

	return '每天 ' + time;
}

function unattended_label(level) {
	let labels = [ '仅检测并通知', '检测后自动下载', '检测后自动下载并刷写' ];
	return labels[int(level ?? 0)] ?? labels[0];
}

return {
	CONFIG: CONFIG,
	LAYOUTS: LAYOUTS,
	SCHEDULE_KINDS: SCHEDULE_KINDS,
	normalize_layout: normalize_layout,
	normalize_channel: normalize_channel,
	DEFAULT_CHANNEL: DEFAULT_CHANNEL,
	CHANNELS: CHANNELS,
	LEGACY_CHANNEL_RE: LEGACY_CHANNEL_RE,
	default_channel: default_channel,
	schedule_cron: schedule_cron,
	schedule_label: schedule_label,
	defaults: defaults,
	load: load,
	active: active,
	unattended_label: unattended_label,
	UNATTENDED_LEVELS: UNATTENDED_LEVELS,
	normalize_unattended: normalize_unattended,
	normalize_switch: normalize_switch
};
