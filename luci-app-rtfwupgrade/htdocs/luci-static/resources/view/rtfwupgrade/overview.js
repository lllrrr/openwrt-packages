'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require rtfwupgrade.format as fmt';

// 本文件的版本号，必须与 version.uc 的 VERSION 一致（tests/version-check.mjs 会校验）。
// 用途：LuCI 的模块 URL 不带本包版本戳，浏览器会按启发式规则缓存旧 JS；
// 拿它和 ubus 现报的版本比对，就能发现自己正在跑旧代码并提示刷新。
var VIEW_VERSION = '0.2.1_alpha1';

var callStatus = rpc.declare({ object: 'rtfwupgrade', method: 'status' });
var callChannels = rpc.declare({ object: 'rtfwupgrade', method: 'channels', params: ['source'] });
var callCheck = rpc.declare({ object: 'rtfwupgrade', method: 'check', params: ['source', 'channel'] });
var callDownload = rpc.declare({ object: 'rtfwupgrade', method: 'download', params: ['source', 'channel'] });
var callDownloadStatus = rpc.declare({ object: 'rtfwupgrade', method: 'download_status' });
var callCancel = rpc.declare({ object: 'rtfwupgrade', method: 'cancel' });
var callCleanup = rpc.declare({ object: 'rtfwupgrade', method: 'cleanup' });
var callFlash = rpc.declare({ object: 'rtfwupgrade', method: 'flash', params: ['source', 'channel', 'force'] });
var callFlashStatus = rpc.declare({ object: 'rtfwupgrade', method: 'flash_status' });
var callFlashClear = rpc.declare({ object: 'rtfwupgrade', method: 'flash_clear' });

// 缓存破坏：LuCI 把 `resource_version`（来自 <script src="luci.js?v=...">）追加到模块 URL，
// 但这台设备的 LuCI 没有该版本戳，模块 URL 就是裸路径，浏览器于是按 Last-Modified
// 的启发式规则缓存。包升级后用户会一直跑旧 JS，直到手动强制刷新。
//
// 本项目自己的资源改成带包版本号的 URL：版本一变 URL 就变，缓存自然失效。
// 只影响本应用的 CSS（JS 模块由 LuCI 的加载器负责，见 settings.js 里的同类处理）。
function asset(path, version) {
	var href = L.resource(path);

	return href + (version ? (href.indexOf('?') >= 0 ? '&' : '?') + 'v=' + encodeURIComponent(version) : '');
}

function sheet(version) {
	return E('link', { rel: 'stylesheet', href: asset('rtfwupgrade/rtfwupgrade.css', version) });
}

function replace(node, children) {
	while (node.firstChild) node.removeChild(node.firstChild);

	// 视图函数返回的常是一维数组，但一旦有人返回嵌套数组，
	// 裸 appendChild 会抛 "parameter 1 is not of type 'Node'"。
	// 这里统一拍平，并把非节点值转成文本节点。
	(function add(v) {
		if (v === null || v === undefined || v === '' || v === false) return;
		if (Array.isArray(v)) return v.forEach(add);
		if (typeof v === 'object' && (v.nodeType || v.tag)) return node.appendChild(v);
		node.appendChild(document.createTextNode(String(v)));
	})(children);
}

// 通道状态：后端 channels 返回的是「这个源上现有哪些通道」，
// pinned 是用户选中的通道（空串=当前通道）。default 布局只有 current，选择器改为只读展示。
function normalizeChannel(info) {
	var i = info || {};
	var layout = i.layout || '';

	return {
		source: i.source || '',
		layout: layout,
		usable: i.ok === true,
		// default 布局只有一个 current：照常显示，但不可更改
		locked: i.locked === true,
		pinned: i.pinned || '',
		// 语义通道及其解析出的实际目录（available=false 表示源上没有这条线）
		channels: i.channels || [],
		list: i.list || [],
		origin: i.origin || '',
		stable: i.stable || '',
		oldstable: i.oldstable || ''
	};
}

// 语义通道：存的是「跟随哪条线」，探测时按源上公布的版本现算目录。
var CHANNEL_LABELS = {
	'': _('Current channel'),
	snapshot: _('Snapshot builds'),
	stable: _('Stable release'),
	oldstable: _('Old stable release'),
	major: _('Current major version'),
	minor: _('Current minor version')
};

// 通道对用户来说是一句中文标签；具体目录名（旧配置）原样显示。
function channelLabel(chan) {
	if (!chan) return CHANNEL_LABELS[''];
	if (CHANNEL_LABELS[chan]) return CHANNEL_LABELS[chan];

	return chan.indexOf('releases/') === 0 ? chan.substr(9) : chan;
}

// 刷写卡片要显示镜像文件名：后端给的是绝对路径，只留最后一段
function basename(path) {
	var parts = String(path || '').split('/');

	return parts[parts.length - 1] || '';
}

// 本机这一侧的固件来源：只认用户确认过的那个源（current_firmware_source 的段名）。
// 未确认就是「未知」。不根据 /etc/openwrt_release 之类的镜像内文件去猜——
// 那些文件既可能被手动改动，也可能被 keep.d 从旧系统带过来，不足以作为依据。
function confirmedSourceDetail(conf) {
	var name = ((conf && conf.current_firmware_source) || '').trim();

	if (!name) return _('Unknown');

	var src =
		(conf.sources || []).filter(function (s) {
			return s.name === name;
		})[0] || {};

	if (!src.label) return name;

	return src.url ? src.label + ' <' + src.url + '>' : src.label;
}

// 源属于哪个发行版族，与后端 source.uc 的 distro_hint() 同一套线索
function distroOf(src) {
	var s = src || {};
	var probe = String(s.system || '').toLowerCase() + ' ' + String(s.url || '').toLowerCase();

	if (probe.indexOf('immortalwrt') >= 0) return 'immortalwrt';
	if (probe.indexOf('openwrt') >= 0) return 'openwrt';

	return '';
}

// 当前这一整套配置是不是跨源状态：激活源所属发行版 != 本机运行的发行版。
// 与「刷写时的跨发行版护栏」不同，这个判断不需要先检测，打开页面就能看出来。
// 当前是不是「切了源但没确认」的状态：纯粹的源 ID 比较，不涉及发行版判断。
//   current_firmware_source  用户确认过的固件来源（源段名）
//   active_source            此刻正在用的源（会随「切换源」立即改变）
// 两者不同即表示：检测结论可能来自一个用户还没认可的来源。
// current_firmware_source 为空 = 从未初始化，属于首次使用，要提示去确认。
function crossSourceState(conf) {
	var active = (conf.active_source || '').trim();
	var confirmed = (conf.current_firmware_source || '').trim();

	// 从未确认过：首次使用，需要引导，不算「跨源更换」
	if (!confirmed) return { kind: 'uninitialized', active: active, confirmed: '' };

	// 已确认且与当前一致：没有跨源
	if (confirmed === active) return null;

	return { kind: 'switched', active: active, confirmed: confirmed };
}

// 通道后面括号里的来源。所有通道一律标注，保证同一列语义一致：
//   snapshots (.versions.json) / stable (.versions.json) / current (layout)
// 来源本身就是有价值的信息——用户需要知道这个通道名是怎么定下来的，
// 而不是只有部分通道带解释、其余留白。
function channelWithOrigin(rem) {
	var chan = (rem && rem.channel) || '';
	var origin = (rem && rem.channel_origin) || '';

	if (!chan) return '';

	return origin ? chan + ' (' + origin + ')' : chan;
}

// 本机设备名：优先用 /tmp/sysinfo 的 model（人类可读），
// 它缺失时退回 board_name（mediatek/filogic 这类机器标识）。
function localDevice(loc) {
	var l = loc || {};

	return l.model || l.board_name || '-';
}

// 远端设备名：profiles.json 的 titles 给出 vendor + model；
// 取不到时退回 profile 名（bananapi_bpi-r4），再不行用镜像前缀。
function remoteDevice(rem) {
	var r = rem || {};
	var parts = [];

	if (r.device_vendor) parts.push(r.device_vendor);
	if (r.device_model) parts.push(r.device_model);
	if (parts.length) return parts.join(' ');

	return r.profile_name || r.image_prefix || '-';
}

// 远端属于哪个发行版。探测结果本身不带 distribution 字段，
// 因此按与后端 distro_hint() 相同的线索（system 段 + 地址）推断，
// 推不出来时退回源的名称，至少说明「这是哪个站的构建」。
function remoteDistro(res) {
	var rem = (res && res.remote) || {};

	// 首选后端从构建产物名前缀得到的发行版标识（openwrt / immortalwrt）；
	// 取不到时才退回域名线索，最后用源名称兜底。
	var hint =
		(rem.distribution_hint || '').toLowerCase() || distroOf({ url: rem.url || '', system: rem.system || '' });

	if (hint === 'immortalwrt') return 'ImmortalWrt';
	if (hint === 'openwrt') return 'OpenWrt';
	if (rem.label) return rem.label;

	return '-';
}

// 这份结果是哪个源产生的。检测结果里带着 source（源名与地址），
// 用它而不是当前激活源：两者不一致时正是要让用户看见。
function resultSource(res) {
	var s = (res && res.source) || {};
	var rem = (res && res.remote) || {};
	var label = s.label || rem.label || s.name || '';
	var url = s.url || rem.url || '';

	if (!label && !url) return '-';

	return url ? label + ' <' + url + '>' : label;
}

// 结果来源与当前激活源不一致：说明看到的是另一个源留下的结论。
function sourceMismatch(res, activeSource) {
	var name = ((res && res.source) || {}).name || '';

	return !!(name && activeSource && name !== activeSource);
}

// 跨发行版警告来自后端（source.uc 的中文提示，按项目约定不翻译），
// 这里只负责识别它：force 勾选框是否出现由它决定。
function isCrossDistro(w) {
	return /跨发行版|cross-distribut/i.test(String(w || ''));
}

// 续传检查：后端在 start() 里判断能否 -C - 续传，并把原因写进 resume_reason。
// 失败/取消/进行中都要让用户看到“为什么这次没有续传”。
function resumeNote(d) {
	return E('p', { class: 'rtfw-muted' }, _('Resume check: %s').format((d && d.resume_reason) || '-'));
}

return view.extend({
	load: function () {
		return Promise.all([
			callStatus(),
			callFlashStatus().catch(function () {
				return null;
			}),
			callChannels('').catch(function () {
				return null;
			})
		]);
	},

	render: function (loaded) {
		// load() 用 Promise.all 同时取状态与刷写状态；这里兼容只传单个 status 的情况
		// （刷写状态缺失时按 idle 渲染）。
		var status = (Array.isArray(loaded) ? loaded[0] : loaded) || {};
		var flashStatus = Array.isArray(loaded) ? loaded[1] : null;
		var channelInfo = Array.isArray(loaded) ? loaded[2] : null;
		var conf = status.config || {};
		var loc = status.local || {};

		// 存一份配置：对照表要按 current_firmware_source 找对应的源来显示名称
		this.conf = conf;
		this.activeSource = conf.active_source || '';
		// 版本不一致 = 浏览器在跑升级前的旧 JS：必须提示，否则用户看到的是过期界面
		this.stale = !!(status.version && status.version !== VIEW_VERSION);
		this.serverVersion = status.version || '';
		this.channel = normalizeChannel(channelInfo);
		this.crossState = crossSourceState(conf);
		this.download = status.download || { state: 'idle' };
		this.last = status.last || null;
		this.flash = this.normalizeFlash(flashStatus);
		this.flashConfirm = false;
		this.flashForce = false;
		// 跨源放行：激活源与本机发行版不同族时必须显式勾选才能刷写
		this.crossSourceOk = false;
		this.flashErrors = [];
		this.resultNode = E('div', {}, E('p', { class: 'rtfw-muted' }, _('No check has been run yet.')));

		// 未确认固件来源时的引导块：放在「检查更新」之上，
		// 让用户还没点按钮就先看到「先去确认来源」。
		this.confirmNode = E('div', {}, this.buildConfirmNotice());

		var view = E('div', { class: 'rtfw-app' }, [
			sheet(status.version),
			// 浏览器复用了升级前的旧 JS：界面是过期的，必须明说
			this.stale
				? fmt.callout(
						'warning',
						_('The page is running stale code'),
						_(
							'The backend reports version %s but this page was loaded from an older cached copy. Reload the page with Ctrl+Shift+R (Cmd+Shift+R on macOS) to see the current interface.'
						).format(this.serverVersion)
					)
				: '',
			E('h2', {}, _('Router Firmware Update')),
			E(
				'p',
				{ class: 'rtfw-muted' },
				_(
					'Checks build metadata against the active source, downloads the matching sysupgrade image and verifies its sha256. Flashing reboots the device and keeps the current configuration.'
				)
			),

			this.confirmNode,

			E('div', { class: 'rtfw-toolbar' }, [
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'handleCheck')
					},
					_('Check for updates')
				),
				(this.channelNode = E('div', { class: 'rtfw-channel' }, this.buildChannel()))
			]),

			E('h3', {}, _('System info')),
			E('div', { class: 'rtfw-grid' }, [
				fmt.stat(_('Build id'), loc.build_id),
				fmt.stat(_('Build time'), (loc.build_date_iso || '').replace(' UTC', ''), 'OPENWRT_BUILD_DATE'),
				fmt.stat(_('Target hardware'), loc.board_name, loc.board_path),
				fmt.stat(_('System version'), (loc.distribution || '') + ' ' + (loc.version || ''))
			]),

			(this.downloadNode = E('div', {}, this.buildDownload())),

			(this.flashNode = E('div', {}, this.buildFlash())),

			E('h3', {}, _('Result')),
			this.resultNode
		]);

		if (status.last && status.last.verdict) replace(this.resultNode, this.buildResult(status.last, true));

		if (this.download.state === 'running') this.startPolling();

		return view;
	},

	// 概览页只「展示」通道，不提供切换：改通道属于配置，统一到设置页做。
	// 这样也避免了在同一页出现两套切换入口（含两套后果警告）。
	buildChannel: function () {
		var c = this.channel;

		if (!c || !c.usable) return [];

		var cur =
			c.channels.filter(function (x) {
				return x.value === c.pinned;
			})[0] || {};
		var label = channelLabel(c.pinned);

		// 有解析出的目录时一并显示，让用户知道当前实际探测的是哪条路径
		var detail = cur.dir || (c.locked ? 'current' : '');

		return [
			E('div', { class: 'rtfw-channel-row' }, [
				E('span', { class: 'rtfw-muted' }, _('Update channel') + '：'),
				E('span', { class: 'rtfw-channel-value' }, label),
				detail ? E('code', {}, detail) : '',
				E(
					'a',
					{ class: 'rtfw-channel-edit', href: L.url('admin', 'system', 'rtfwupgrade', 'settings') },
					_('Change in settings')
				)
			])
		];
	},

	buildResult: function (res, cached) {
		var vs = res.verdict || {};
		var rem = res.remote || {};
		var loc = res.local || {};
		var nodes = [];

		nodes.push(
			E('div', { class: 'rtfw-toolbar' }, [
				fmt.badge(vs.state, vs.label),
				E(
					'span',
					{ class: 'rtfw-muted' },
					'%s %s'.format(
						cached ? _('cached result from') : _('checked at'),
						new Date((res.ts || 0) * 1000).toISOString().replace('T', ' ').substr(0, 16) + ' UTC'
					)
				)
			])
		);

		// 这份结果不是当前激活源产生的：说明看到的是别的源留下的旧结论。
		// 必须显式说明，否则用户会把它当成激活源的检测结果。
		if (sourceMismatch(res, this.activeSource))
			nodes.push(
				fmt.callout(
					'warning',
					_('Result came from another source'),
					_(
						'This result was produced by %s, but the active source is %s. Run a check to get a verdict for the active source.'
					).format(resultSource(res), this.activeSource)
				)
			);

		nodes.push(
			E('div', { class: 'rtfw-grid' }, [
				fmt.stat(_('Local build id'), loc.build_id),
				fmt.stat(_('Local build time'), (loc.build_date_iso || '').replace(' UTC', '')),
				fmt.stat(_('Remote build id'), rem.version_code || '-'),
				fmt.stat(
					_('Remote build time'),
					(rem.source_date_iso || '').replace(' UTC', ''),
					rem.channel ? _('System update channel') + ': ' + rem.channel : ''
				)
			])
		);

		if (!res.ok)
			nodes.push(fmt.callout('danger', _('Detection failed'), rem.error || res.error || _('Unknown error')));

		nodes.push(
			fmt.kvTable(
				[_('Item'), _('Local'), _('Remote')],
				[
					[_('Distribution'), loc.distribution || '-', remoteDistro(res)],
					[_('Build id'), loc.build_id, rem.version_code],
					[_('Source time'), loc.build_date_iso, rem.source_date_iso],
					[_('Update channel'), loc.version, rem.channel ? channelWithOrigin(rem) : ''],
					[_('Firmware source'), confirmedSourceDetail(this.conf), resultSource(res)],
					[_('Target device'), localDevice(loc), remoteDevice(rem)]
				]
			)
		);

		nodes.push(
			fmt.callout(
				vs.state === 'downgrade' ? 'warning' : vs.state === 'update' ? 'success' : '',
				_('Verdict basis'),
				vs.evidence || '-'
			)
		);

		if (rem.image) {
			nodes.push(E('h3', {}, _('Candidate image')));
			nodes.push(
				fmt.kvTable(
					[_('Item'), _('Value')],
					[
						[_('File'), rem.image.name],
						[
							_('Size'),
							fmt.fmtSize(rem.image.size) +
								(rem.image_limit ? ' / %s'.format(fmt.fmtSize(rem.image_limit)) : '')
						],
						['sha256', rem.image.sha256]
					]
				)
			);
		}

		if ((rem.images || []).length > 1) {
			nodes.push(
				E('details', { class: 'rtfw-images' }, [
					E('summary', {}, _('All images (%d)').format(rem.images.length)),
					fmt.callout(
						'warning',
						_('Images not used by this app'),
						_(
							'Only the squashfs sysupgrade image is offered as a candidate. The other images listed here rewrite the boot chain or the partition table and are not used by this app.'
						)
					),
					fmt.kvTable(
						[_('Type'), _('Filesystem'), _('File'), _('Size')],
						rem.images.map(function (i) {
							return [i.type || '-', i.filesystem || '-', i.name || '-', fmt.fmtSize(i.size)];
						})
					)
				])
			);
		}

		(rem.warnings || []).forEach(function (w) {
			nodes.push(fmt.callout('warning', _('Warning'), w));
		});

		return nodes;
	},

	// 刷写状态也兼容桩环境返回 undefined：一律落到四态里的 idle
	normalizeFlash: function (st) {
		var s = st || {};
		var states = ['idle', 'flash-pending', 'boot-confirmed', 'flash-failed'];
		var state = states.indexOf(s.state) >= 0 ? s.state : 'idle';

		return {
			state: state,
			trigger: s.trigger || '',
			source: s.source || '',
			channel: s.channel || '',
			file: s.file || '',
			sha256: s.sha256 || '',
			size: s.size || 0,
			target_build_id: s.target_build_id || '',
			target_version: s.target_version || '',
			previous_build_id: s.previous_build_id || '',
			started: s.started || 0,
			finished: s.finished || 0,
			error: s.error || ''
		};
	},

	// 待刷写状态优先读状态文件（它才是真正要写入设备的那个文件）；
	// 没有待刷写记录时回落到已下载并校验过的那个文件（绝对路径，命令要用的就是它）。
	// name 只用于展示，path 才是真正写进 sysupgrade 参数里的东西。
	flashTarget: function () {
		var rem = (this.last && this.last.remote) || {};
		var img = rem.image || {};
		var st = this.flash || {};
		var dl = this.download || {};
		var pending = st.state !== 'idle' && st.state !== undefined;
		var path = (pending && st.file) || (dl.state === 'verified' && dl.file) || '';

		return {
			version: (pending && st.target_version) || rem.version_number || rem.version_code || '',
			build_id: (pending && st.target_build_id) || rem.version_code || '',
			name: path ? basename(path) : img.name || '',
			path: path,
			size: (pending && st.size) || dl.size || img.size || 0
		};
	},

	crossDistroWarnings: function () {
		var rem = (this.last && this.last.remote) || {};

		return (rem.warnings || []).filter(isCrossDistro);
	},

	flashLocalErrors: function (st) {
		var errors = [];
		var state = this.normalizeFlash(st).state;

		if (state === 'flash-pending')
			errors.push(_('A flash is already pending. Reboot the router and let the boot check confirm it first.'));

		if (!this.last || !this.last.ok)
			errors.push(_('Run a check first: nothing tells which image this device should be flashed with.'));

		if (!this.download || this.download.state !== 'verified')
			errors.push(_('The image has not been downloaded and verified yet.'));

		// 跨源状态（激活源与本机不同族）与本次结果的跨发行版护栏是两道独立的闸，
		// 各自的勾选只管自己那一条：没勾的逐条列出，不互相遮蔽。
		if (this.crossState && this.crossState.kind === 'switched' && !this.crossSourceOk)
			errors.push(_('The active source has not been confirmed yet. Tick the cross-source override first.'));

		if (this.crossDistroWarnings().length && !this.flashForce)
			errors.push(
				_('This source belongs to a different distribution. Tick the cross-distribution override first.')
			);

		return errors;
	},

	// 未确认固件来源时的引导块。只在 uninitialized 状态出现。
	buildConfirmNotice: function () {
		if (!this.crossState || this.crossState.kind !== 'uninitialized') return '';

		return fmt.callout('warning', _('Confirm the firmware source'), [
			E(
				'p',
				{},
				_(
					'No firmware source has been confirmed on this device yet. Pick the source that matches your build in the settings page; until then this page cannot tell whether the image belongs to the same distribution as this device.'
				)
			),
			E('div', { class: 'rtfw-toolbar' }, [
				E(
					'a',
					{ class: 'rtfw-channel-edit', href: L.url('admin', 'system', 'rtfwupgrade', 'settings') },
					_('Go to sources')
				)
			])
		]);
	},

	// 用户点了「检查更新」「下载镜像」「立即刷写」时，若尚未确认来源就拦下来提醒。
	//
	// 用回调而非返回 Promise：弹窗的「取消 / 仍要继续」由用户点击决定，
	// 返回 Promise 会让调用方一直挂起等待一个可能永远不会发生的点击。
	// 取消时不调用 continueFn，按钮就不会进入加载态，也就不会卡住。
	warnUnconfirmed: function (actionText, continueFn) {
		var self = this;

		if (this.confirmDismissed) return continueFn();
		if (!this.crossState || this.crossState.kind !== 'uninitialized') return continueFn();

		ui.showModal(_('Confirm the firmware source first'), [
			E('p', {}, actionText),
			fmt.callout(
				'warning',
				_('What to do'),
				_(
					'Open the settings page, add the source that matches your build, then select it in the Active column.'
				)
			),
			E('div', { class: 'right rtfw-toolbar' }, [
				E(
					'button',
					{
						class: 'btn',
						// 取消：只关弹窗，不发起请求，也不碰按钮状态
						click: function () {
							ui.hideModal();
						}
					},
					_('Cancel') + ' '
				),
				E(
					'a',
					{
						class: 'btn cbi-button cbi-button-action',
						href: L.url('admin', 'system', 'rtfwupgrade', 'settings')
					},
					_('Go to sources')
				),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-reset',
						click: function () {
							// 仍然继续：放行本次操作，且本次会话不再重复询问
							self.confirmDismissed = true;
							ui.hideModal();
							continueFn();
						}
					},
					_('Continue anyway')
				)
			])
		]);
	},

	// 四项核对 + 不可逆警示 + 确认勾选 + 状态机展示
	buildFlash: function () {
		var self = this;
		var st = this.flash || { state: 'idle' };
		var target = this.flashTarget();
		var cross = this.crossDistroWarnings();
		var nodes = [E('h3', {}, _('Flash firmware'))];

		if (st.state === 'flash-pending')
			nodes.push(
				fmt.callout(
					'warning',
					_('Waiting for reboot confirmation'),
					_(
						'The image was written and sysupgrade was started. The state is confirmed after the router reboots.'
					)
				)
			);

		if (st.state === 'boot-confirmed')
			nodes.push(
				fmt.callout(
					'success',
					_('Flash confirmed after reboot'),
					_('The build id after reboot matches the target: %s').format(st.target_build_id || '-')
				)
			);

		if (st.state === 'flash-failed')
			nodes.push(
				fmt.callout(
					'danger',
					_('Flash not confirmed'),
					_('After reboot the build id is %s while the target was %s.').format(
						st.previous_build_id || '-',
						st.target_build_id || '-'
					) + (st.error ? ' ' + st.error : '')
				)
			);

		nodes.push(
			E('div', { class: 'rtfw-grid' }, [
				fmt.stat(_('Target version'), target.version),
				fmt.stat(_('Target build id'), target.build_id),
				fmt.stat(_('Image file'), target.name || '-', target.path || ''),
				fmt.stat(_('Image size'), fmt.fmtSize(target.size))
			])
		);

		// 依据本次检测结论单独给一块分级提示（可升级 / 重编 / 降级 / 已是最新 / 无法判定），
		// 与下面的「此操作不可逆」并列：前者说的是这次刷写的具体后果，后者说的是刷写本身的固有代价。
		nodes.push(this.buildFlashAdvice());

		if (st.state === 'flash-failed') {
			nodes.push(
				E('div', { class: 'rtfw-toolbar' }, [
					E(
						'button',
						{
							class: 'btn cbi-button cbi-button-reset',
							click: ui.createHandlerFn(this, 'handleFlashClear')
						},
						_('Clear flash state')
					)
				])
			);
		}

		// 已确认过，但当前激活源被换成了别的：需要放行才能刷写。

		if (this.crossState && this.crossState.kind === 'switched') {
			this.crossSourceBox = E('input', {
				type: 'checkbox',
				checked: this.crossSourceOk ? 'checked' : null,
				change: function (ev) {
					self.crossSourceOk = !!ev.target.checked;
					self.syncFlashButton();
				}
			});

			nodes.push(
				fmt.callout('danger', _('Cross-source change'), [
					E(
						'p',
						{},
						_(
							'The active source was switched from %s to %s, but the new one has not been confirmed yet.'
						).format(this.crossState.confirmed, this.crossState.active)
					),
					E(
						'p',
						{},
						_(
							'Flash this source image only if you accept writing another distribution over the running system. Confirming it in the settings page clears this notice without flashing.'
						)
					),
					E('div', { class: 'rtfw-toolbar' }, [
						E('label', { class: 'rtfw-check' }, [this.crossSourceBox, ' ' + _('Allow cross-source change')])
					]),
					E('div', { class: 'rtfw-toolbar' }, [
						E(
							'a',
							{ class: 'rtfw-channel-edit', href: L.url('admin', 'system', 'rtfwupgrade', 'settings') },
							_('Change in settings')
						)
					])
				])
			);
		}

		// 跨源与跨发行版是两道独立的闸：前者看「配置处于跨源状态」，后者看「这次探测的
		// 源与本机不同族」。它们可能同时成立，各自有独立的勾选与放行，不做合并、也不互相抑制。
		if (cross.length) {
			this.flashForceBox = E('input', {
				type: 'checkbox',
				checked: this.flashForce ? 'checked' : null,
				change: function (ev) {
					self.flashForce = !!ev.target.checked;
					self.syncFlashButton();
				}
			});

			nodes.push(
				fmt.callout('warning', _('Cross-distribution flashing'), [
					E(
						'ul',
						{},
						cross.map(function (w) {
							return E('li', {}, w);
						})
					),
					E('div', { class: 'rtfw-toolbar' }, [
						E('label', { class: 'rtfw-check' }, [
							this.flashForceBox,
							' ' + _('Allow cross-distribution flashing')
						])
					]),
					E('div', { class: 'rtfw-toolbar' }, [
						E(
							'a',
							{ class: 'rtfw-channel-edit', href: L.url('admin', 'system', 'rtfwupgrade', 'settings') },
							_('Change in settings')
						)
					])
				])
			);
		}

		// 「此操作不可逆」与确认勾选放在所有跨发行版/跨源警告之后：
		// 先让用户看清这次刷写属于哪种情况，再面对「不可逆」与最终确认。
		nodes.push(
			fmt.callout(
				'danger',
				_('This cannot be undone'),
				_(
					'Flashing reboots the router: the network drops until it is back, and everything written to /tmp is lost. Existing configuration is kept, because sysupgrade runs with -c -k.'
				)
			)
		);

		this.flashConfirmBox = E('input', {
			type: 'checkbox',
			checked: this.flashConfirm ? 'checked' : null,
			change: function (ev) {
				self.flashConfirm = !!ev.target.checked;
				self.syncFlashButton();
			}
		});

		nodes.push(
			E('div', { class: 'rtfw-toolbar' }, [
				E('label', { class: 'rtfw-check' }, [
					this.flashConfirmBox,
					' ' + _('I confirm: flash this image and reboot the router.')
				])
			])
		);

		this.flashErrorNode = E('div', {}, this.buildFlashErrors());

		nodes.push(this.flashErrorNode);

		this.flashButton = E(
			'button',
			{
				class: 'btn cbi-button cbi-button-negative',
				disabled: this.flashBlocked() ? 'disabled' : null,
				click: ui.createHandlerFn(this, 'handleFlashNow')
			},
			_('Flash now')
		);

		nodes.push(E('div', { class: 'rtfw-toolbar' }, [this.flashButton]));

		nodes.push(
			E(
				'p',
				{ class: 'rtfw-muted' },
				_('The command is: %s').format('sysupgrade -c -k ' + (target.path || '/tmp/rtfwupgrade/<image>'))
			)
		);

		return nodes;
	},

	// 依据本次检测结论给出分级提示：语气与内容随判定结果变化（success → warning → danger）。
	// 没有检测结果时不给块：这时刷写按钮本身也是阻断的。
	buildFlashAdvice: function () {
		var res = this.last;

		if (!res || !res.verdict) return '';

		var vs = res.verdict;
		var state = vs.state || '';

		if (state === 'update')
			return fmt.callout(
				'success',
				_('Ready to upgrade'),
				_(
					'The remote build is newer than the one running: this is a normal upgrade. The verdict basis is shown in the result section below.'
				)
			);

		if (state === 'rebuild')
			return fmt.callout(
				'warning',
				_('Same version, different build'),
				_(
					'The version and build time match while the build id differs: the upgrade changes nothing visible, and the automatic path only downloads it.'
				)
			);

		if (state === 'downgrade')
			return fmt.callout(
				'danger',
				_('The remote build is older'),
				_(
					'Flashing writes an older build over the running one: this is a downgrade, and settings the newer build relies on may be lost.'
				)
			);

		if (state === 'same')
			return fmt.callout(
				'',
				_('Already on this build'),
				_('The running build id matches the remote one, so flashing writes the identical image.')
			);

		return fmt.callout(
			'warning',
			_('Verdict unavailable'),
			_('The two sides could not be compared, so the outcome of this flash is unknown.')
		);
	},

	buildFlashErrors: function () {
		var errors = this.flashErrors || [];

		if (!errors.length) return [E('span', { class: 'rtfw-muted' }, _('No blocking problem found so far.'))];

		return [
			fmt.callout(
				'danger',
				_('Flashing is blocked'),
				E(
					'ul',
					{},
					errors.map(function (e) {
						return E('li', {}, e);
					})
				)
			)
		];
	},

	flashBlocked: function () {
		if (!this.flashConfirm) return true;
		// 切了源但未确认：必须先勾选放行，否则按钮保持禁用
		if (this.crossState && this.crossState.kind === 'switched' && !this.crossSourceOk) return true;
		if (this.crossDistroWarnings().length && !this.flashForce) return true;

		return false;
	},

	syncFlashButton: function () {
		if (this.flashButton) this.flashButton.disabled = this.flashBlocked();
	},

	renderFlash: function () {
		if (this.flashNode) replace(this.flashNode, this.buildFlash());
	},

	buildDownload: function () {
		var d = this.download || { state: 'idle' };
		var nodes = [E('h3', {}, _('Image download'))];

		switch (d.state) {
			case 'running':
				nodes.push(E('div', { class: 'rtfw-bar' }, E('span', { style: 'width:' + (d.percent || 0) + '%' })));
				nodes.push(
					E(
						'div',
						{ class: 'rtfw-muted' },
						'%s / %s（%d%%）%s'.format(
							fmt.fmtSize(d.received),
							fmt.fmtSize(d.size),
							d.percent || 0,
							d.resumed_from ? _('resumed') : ''
						)
					)
				);
				if (d.resume_reason) nodes.push(resumeNote(d));
				nodes.push(
					fmt.callout(
						'',
						_('Downloading…'),
						_('The file goes to /tmp (RAM), so it does not survive a reboot.')
					)
				);
				nodes.push(
					E('div', { class: 'rtfw-toolbar' }, [
						E(
							'button',
							{
								class: 'btn cbi-button cbi-button-reset',
								click: ui.createHandlerFn(this, 'handleCancel')
							},
							_('Cancel')
						)
					])
				);
				break;

			case 'verified':
				nodes.push(
					fmt.callout(
						'success',
						_('Downloaded and verified'),
						_('The sha256 matches the one published by the source. The image is ready to flash.')
					)
				);
				nodes.push(
					fmt.kvTable(
						[_('Item'), _('Value')],
						[
							[_('File'), d.file],
							[_('Size'), fmt.fmtSize(d.size)],
							['sha256', d.sha256]
						]
					)
				);
				nodes.push(
					E('div', { class: 'rtfw-toolbar' }, [
						E(
							'button',
							{
								class: 'btn cbi-button cbi-button-reset',
								click: ui.createHandlerFn(this, 'handleCleanup')
							},
							_('Delete file')
						)
					])
				);
				break;

			case 'failed':
				nodes.push(fmt.callout('danger', _('Download failed'), d.error || _('Unknown error')));
				if (d.resume_reason) nodes.push(resumeNote(d));
				nodes.push(
					E('div', { class: 'rtfw-toolbar' }, [
						E(
							'button',
							{
								class: 'btn cbi-button cbi-button-action',
								click: ui.createHandlerFn(this, 'handleDownload')
							},
							_('Retry download')
						),
						E(
							'button',
							{
								class: 'btn cbi-button cbi-button-reset',
								click: ui.createHandlerFn(this, 'handleCleanup')
							},
							_('Delete file')
						)
					])
				);
				break;

			case 'cancelled':
				nodes.push(
					fmt.callout(
						'warning',
						_('Download cancelled'),
						_(
							'The partial file is kept, so a retry resumes with curl -C - after comparing the ETag and Last-Modified.'
						)
					)
				);
				if (d.resume_reason) nodes.push(resumeNote(d));
				nodes.push(
					E('div', { class: 'rtfw-toolbar' }, [
						E(
							'button',
							{
								class: 'btn cbi-button cbi-button-action',
								click: ui.createHandlerFn(this, 'handleDownload')
							},
							_('Resume download')
						),
						E(
							'button',
							{
								class: 'btn cbi-button cbi-button-reset',
								click: ui.createHandlerFn(this, 'handleCleanup')
							},
							_('Delete file')
						)
					])
				);
				break;

			default:
				nodes.push(
					E(
						'div',
						{ class: 'rtfw-muted' },
						_(
							'Downloads the candidate image to /tmp and checks its sha256 against the value published by the source.'
						)
					)
				);
				nodes.push(
					E('div', { class: 'rtfw-toolbar' }, [
						E(
							'button',
							{
								class: 'btn cbi-button cbi-button-action',
								click: ui.createHandlerFn(this, 'handleDownload')
							},
							_('Download image')
						)
					])
				);
		}

		return nodes;
	},

	renderDownload: function () {
		if (this.downloadNode) replace(this.downloadNode, this.buildDownload());
		// 下载状态决定刷写按钮的前提条件（必须 verified），卡片要跟着一起刷新
		this.renderFlash();
	},

	startPolling: function () {
		if (this.pollFn) return;

		this.pollFn = L.bind(this.pollDownload, this);
		poll.add(this.pollFn);
	},

	stopPolling: function () {
		if (!this.pollFn) return;

		poll.remove(this.pollFn);
		this.pollFn = null;
	},

	pollDownload: function () {
		var self = this;

		return callDownloadStatus().then(function (d) {
			self.download = d || { state: 'idle' };
			self.renderDownload();
			if (self.download.state !== 'running') self.stopPolling();
		});
	},

	handleCheck: function (ev) {
		var self = this;
		var btn = ev.currentTarget;

		var run = function () {
			btn.disabled = true;
			btn.classList.add('spinning');

			return callCheck(self.activeSource, '')
				.then(function (res) {
					replace(self.resultNode, self.buildResult(res, false));

					// 刷写卡片的目标镜像、版本与防护提示都取自检测结果，
					// 不跟着刷新就会停留在上一次检测（或初始空态），要手动刷新页面才更新。
					self.last = res || null;
					self.flashErrors = [];
					self.renderFlash();
				})
				.catch(function (err) {
					ui.addNotification(null, E('p', {}, _('Check failed: ') + (err.message || err)), 'error');
				})
				.finally(function () {
					btn.disabled = false;
					btn.classList.remove('spinning');
				});
		};

		// 未确认来源时先弹窗；取消则完全不发请求，按钮也不会进入加载态
		return this.warnUnconfirmed(
			_(
				'This device has no confirmed firmware source yet, so the check would compare against a source you have not chosen.'
			),
			run
		);
	},

	handleDownload: function () {
		var self = this;

		var run = function () {
			return callDownload(self.activeSource, '')
				.then(function (res) {
					if (!res || res.ok === false) throw new Error((res && res.error) || _('Download failed'));

					self.download = res;
					self.renderDownload();
					if (res.state === 'running') self.startPolling();
				})
				.catch(function (err) {
					ui.addNotification(null, E('p', {}, _('Download failed: ') + (err.message || err)), 'error');
				});
		};

		return this.warnUnconfirmed(
			_(
				'This device has no confirmed firmware source yet, so the download would come from a source you have not chosen.'
			),
			run
		);
	},
	handleCancel: function () {
		var self = this;

		return callCancel()
			.then(function (res) {
				if (!res || res.ok === false) throw new Error((res && res.error) || _('Cancel failed'));

				return self.pollDownload();
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Cancel failed: ') + (err.message || err)), 'error');
			});
	},

	handleCleanup: function () {
		var self = this;

		return callCleanup()
			.then(function () {
				self.download = { state: 'idle' };
				self.renderDownload();
				ui.addNotification(null, E('p', {}, _('Downloaded file deleted.')), 'info');
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Delete failed: ') + (err.message || err)), 'error');
			});
	},

	// 点击后先取一次 flash_status 与本地必要条件，任何一条不满足就逐条列出并中止；
	// 全部通过才把 force 传成 '1'（后端只认字符串 '1'）。
	handleFlashNow: function () {
		var self = this;

		var run = function () {
			return callFlashStatus()
				.catch(function () {
					return null;
				})
				.then(function (st) {
					self.flash = self.normalizeFlash(st);
					self.flashErrors = self.flashLocalErrors(st);

					if (self.flashErrors.length) {
						replace(self.flashErrorNode, self.buildFlashErrors());
						ui.addNotification(
							null,
							E('p', {}, _('Flashing is blocked: fix the problems listed above.')),
							'error'
						);
						return false;
					}

					// force 的语义是「我知道这是换来源/换系统，仍要刷」：跨源放行与跨发行版放行
					// 合并成同一个 force 传给后端 —— 后端的 f 条（跨发行版）与 h 条（跨源）
					// 都只认这一个参数，任一勾选即放行。两块各自未勾选仍会进阻断清单，
					// 所以用户看到的还是「没勾哪条就被哪条挡住」。
					var force = self.flashForce || self.crossSourceOk ? '1' : '';

					return callFlash(self.activeSource, '', force).then(function (res) {
						if (!res || res.ok === false) {
							self.flashErrors =
								res && res.errors && res.errors.length
									? res.errors
									: [(res && res.error) || _('Unknown error')];
							replace(self.flashErrorNode, self.buildFlashErrors());
							ui.addNotification(
								null,
								E('p', {}, _('Flashing failed: ') + ((res && res.error) || _('Unknown error'))),
								'error'
							);
							return false;
						}

						// 立刻切到 pending，避免用户重复点第二次刷写
						var tgt = self.flashTarget();

						self.flashErrors = [];
						self.flash = self.normalizeFlash({
							state: 'flash-pending',
							trigger: 'manual',
							source: self.activeSource,
							file: tgt.path,
							size: tgt.size,
							target_build_id: tgt.build_id,
							target_version: tgt.version
						});
						self.flashConfirm = false;
						self.renderFlash();
						return true;
					});
				})
				.catch(function (err) {
					ui.addNotification(null, E('p', {}, _('Flashing failed: ') + (err.message || err)), 'error');
				});
		};

		return this.warnUnconfirmed(
			_(
				'This device has no confirmed firmware source yet, so flashing would write an image from a source you have not chosen.'
			),
			run
		);
	},

	handleFlashClear: function () {
		var self = this;

		return callFlashClear()
			.then(function () {
				self.flash = self.normalizeFlash(null);
				self.flashErrors = [];
				self.renderFlash();
				ui.addNotification(null, E('p', {}, _('Flash state cleared.')), 'info');
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Clear failed: ') + (err.message || err)), 'error');
			});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
