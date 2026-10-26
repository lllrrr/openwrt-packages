'use strict';
'require view';
'require rpc';
'require ui';
'require rtfwupgrade.format as fmt';

var callStatus = rpc.declare({ object: 'rtfwupgrade', method: 'status' });
var callSetOptions = rpc.declare({
	object: 'rtfwupgrade',
	method: 'set_options',
	params: ['unattended', 'schedule_kind', 'schedule_time', 'schedule_weekday', 'schedule_day', 'webhook']
});
var callSetActive = rpc.declare({ object: 'rtfwupgrade', method: 'set_active', params: ['source'] });
var callChannels = rpc.declare({ object: 'rtfwupgrade', method: 'channels', params: ['source'] });
var callSetChannel = rpc.declare({ object: 'rtfwupgrade', method: 'set_channel', params: ['source', 'channel'] });
var callSourceAdd = rpc.declare({
	object: 'rtfwupgrade',
	method: 'source_add',
	params: ['name', 'label', 'url', 'layout', 'system']
});
var callSourceDel = rpc.declare({ object: 'rtfwupgrade', method: 'source_del', params: ['name'] });
var callSourceSet = rpc.declare({
	object: 'rtfwupgrade',
	method: 'source_set',
	params: ['name', 'label', 'url', 'layout', 'system', 'channel']
});
var callScheduleStatus = rpc.declare({ object: 'rtfwupgrade', method: 'schedule_status' });

// 语义通道：存的是「跟随哪条线」，探测时按源上公布的版本现算目录，
// 所以用户选「稳定版」不会被钉死在某个会过期的补丁版本上。
var CHANNEL_LABELS = {
	'': _('Current channel'),
	snapshot: _('Snapshot builds'),
	stable: _('Stable release'),
	oldstable: _('Old stable release'),
	major: _('Current major version'),
	minor: _('Current minor version')
};

var CHANNEL_ORDER = ['', 'snapshot', 'stable', 'oldstable', 'major', 'minor'];

var SCHEDULE_KINDS = [
	{ value: 'off', text: _('Disabled') },
	{ value: 'daily', text: _('Daily') },
	{ value: 'weekly', text: _('Weekly') },
	{ value: 'monthly', text: _('Monthly') }
];

var WEEKDAYS = [_('Monday'), _('Tuesday'), _('Wednesday'), _('Thursday'), _('Friday'), _('Saturday'), _('Sunday')];

// 预设只是「一键填表」的模板，不会自动创建源。
// 命名按**布局**区分，而不是按「镜像 / 自建」这类归属：
//   official —— 官方发布页结构（含 releases/<版本>/ 或 snapshots/）
//   聚合站   —— 同样是 official，但一个地址下托管多个发行版（靠 system 段区分）
//   default  —— 只有 root/targets 一层，没有版本通道，故为「单版本发布站」
var PRESETS = [
	{
		text: _('OpenWrt official'),
		short: 'OpenWrt',
		label: _('OpenWrt official'),
		url: 'https://downloads.openwrt.org',
		layout: 'official',
		system: ''
	},
	{
		text: _('ImmortalWrt official'),
		short: 'ImmortalWrt',
		label: _('ImmortalWrt official'),
		url: 'https://downloads.immortalwrt.org',
		layout: 'official',
		system: ''
	},
	{
		text: _('Multi-distribution mirror'),
		short: _('Mirror'),
		label: _('Multi-distribution mirror'),
		url: 'https://rtfw.shuery.lssa.fun',
		layout: 'official',
		system: 'immortalwrt'
	},
	{
		text: _('Single-version release site'),
		short: _('Single-version'),
		label: _('Single-version release site'),
		url: 'https://immortalwrt.shuery.lssa.fun',
		layout: 'default',
		system: ''
	}
];

// 布局说明：只支持两种目录结构，官方发布页与单版本 bin/targets 输出各对应一种。
// 路径部分在界面上要显示成行内代码块，所以这里拆成「说明文字」与「路径」两段，
// 由 layoutHelp() 拼成 说明：`路径` 的形式。
// <option title="..."> 只接受纯文本，因此另留一份 layoutHint() 供它使用。
const LAYOUT_PATHS = {
	official: 'root/releases/release/targets',
	default: 'root/targets'
};

function layoutText(kind) {
	if (kind === 'official') return _('OpenWRT/ImmortalWRT official release page directory structure');
	if (kind === 'default') return _('Default build output directory structure');

	return kind;
}

function layoutHint(kind) {
	return layoutText(kind) + ': ' + (LAYOUT_PATHS[kind] || '');
}

function layoutItem(kind) {
	return E('li', {}, [
		E('span', { class: 'rtfw-layout-key' }, kind),
		' —— ',
		layoutText(kind),
		'：',
		E('code', {}, LAYOUT_PATHS[kind] || ''),
		'。'
	]);
}

// 布局说明：只讲两种目录结构。表格下方与两个对话框都用它。
function layoutHelp() {
	return E('div', { class: 'rtfw-layout-help' }, [
		E('div', { class: 'rtfw-layout-help-title' }, _('Layouts')),
		E('ul', { class: 'rtfw-layout-list' }, [layoutItem('official'), layoutItem('default')])
	]);
}

// 操作说明：讲「添加」与「高级」两个按钮怎么用。
// 只出现在源表格下方——对话框里已经在做那件事，再解释按钮只会让人困惑。
function actionsHelp() {
	return E('div', { class: 'rtfw-layout-help' }, [
		E('div', { class: 'rtfw-layout-help-title' }, _('Actions')),
		E('ul', { class: 'rtfw-layout-list' }, [
			E('li', {}, [
				E('span', { class: 'rtfw-layout-key' }, _('Add')),
				' —— ',
				_('The last table row is quick add: fill the required fields and press Add.')
			]),
			E('li', {}, [
				E('span', { class: 'rtfw-layout-key' }, _('Advanced')),
				' —— ',
				_('Press Advanced when you need to set the identifier and other parameters yourself.')
			])
		])
	]);
}

function layoutTitle() {
	return layoutHint('official') + '\n' + layoutHint('default');
}

// 缓存破坏：LuCI 把 `resource_version`（取自 <script src="luci.js?v=...">）追加到模块 URL，
// 本机这份 LuCI 没有版本戳，模块与样式 URL 都是裸路径，浏览器于是按 Last-Modified
// 的启发式规则缓存；包升级后仍会加载旧文件，直到手动强制刷新。
// 这里给本应用自己的静态资源加上包版本号：版本一变 URL 就变，缓存自然失效。
function asset(path, version) {
	var href = L.resource(path);

	if (!version) return href;

	return href + (href.indexOf('?') >= 0 ? '&' : '?') + 'v=' + encodeURIComponent(version);
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

function field(title, control, hint) {
	return E('div', { class: 'cbi-value' }, [
		E('label', { class: 'cbi-value-title' }, title),
		E('div', { class: 'cbi-value-field' }, [
			control,
			// hint 可能是纯文本，也可能是节点树（布局说明）。
			// 一律包进数组：数组中的节点按节点处理、字符串按文本处理，
			// 避免节点被当成字符串渲染成一串 [object Object]。
			hint ? E('div', { class: 'rtfw-muted' }, Array.isArray(hint) ? hint : [hint]) : ''
		])
	]);
}

return view.extend({
	load: function () {
		return Promise.all([
			callStatus(),
			callScheduleStatus().catch(function () {
				return null;
			}),
			callChannels('').catch(function () {
				return null;
			})
		]);
	},

	render: function (loaded) {
		// load() 用 Promise.all 同时取状态与定时任务状态；这里同时兼容旧测试
		// 只传单个 status 对象的情况（schedule 缺失时状态块显示“暂无”）。
		var status = Array.isArray(loaded) ? loaded[0] || {} : loaded || {};
		var schedule = Array.isArray(loaded) ? loaded[1] : (loaded && loaded.schedule) || null;
		var channelInfo = Array.isArray(loaded) ? loaded[2] : null;
		var conf = status.config || {};
		var self = this;

		this.data = {
			unattended: '' + (conf.unattended || 0),
			kind: conf.schedule_kind || 'daily',
			time: conf.schedule_time || '04:00',
			weekday: '' + (conf.schedule_weekday || 1),
			day: '' + (conf.schedule_day || 1),
			webhook: conf.webhook || ''
		};
		this.sources = conf.sources || [];
		this.active = conf.active_source || '';
		// 记住已生效的激活源：切换对话框要拿它做「从哪 → 到哪」的对比
		this.activeSource = this.active;
		this.layouts = status.layouts || ['official', 'default'];
		this.form = { name: '', label: '', url: '', layout: 'official', system: '' };

		// 用户确认过的固件来源（源段名）。空 = 首次使用，要提示先选源。
		this.currentFirmwareSource = conf.current_firmware_source || '';

		// 更新通道跟着激活源走：换源之后要重新取一次列表
		this.channel = this.normalizeChannel(channelInfo);
		this.channelNode = E('div', {}, this.buildChannel());

		this.sourcesNode = E('div', {}, this.buildSources());
		this.scheduleNode = E('div', {}, this.buildScheduleExtra());
		this.schedule = schedule || null;
		this.scheduleStatusNode = E('div', {}, this.buildScheduleStatus(this.schedule));
		this.adv = { preset: '', name: '', label: '', url: '', layout: 'official', system: '' };
		this.edit = null;
		this.editNode = null;

		return E('div', { class: 'rtfw-app' }, [
			sheet(status.version),
			E('h2', {}, _('Settings')),

			E('h3', {}, _('Check sources')),

			// 首次安装：预置源只是「能用」的样例，未必符合这台设备的实际发行版。
			// 用户必须自己添加并选中正确的源，之后以它的 ID 作为「源是否已配置」的依据。
			!this.currentFirmwareSource
				? fmt.callout('warning', _('Confirm the firmware source'), [
						E(
							'p',
							{},
							_(
								'No firmware source has been confirmed on this device yet. Add the source that matches your build, then select it in the Active column.'
							)
						),
						E(
							'p',
							{},
							_(
								'Selecting it records the source as this device firmware origin. Until that is done, the overview page asks you to confirm the source before flashing.'
							)
						)
					])
				: '',
			E(
				'p',
				{ class: 'rtfw-muted' },
				_(
					'One source is active at a time. It supplies the build metadata and the image the device is compared against.'
				)
			),
			this.sourcesNode,

			E('h3', {}, _('Update channel')),
			E(
				'p',
				{ class: 'rtfw-muted' },
				_('The channel belongs to the active source and decides which release line is probed.')
			),
			this.channelNode,

			E('h3', {}, _('Detection and notification')),

			field(
				_('Unattended level'),
				E(
					'select',
					{
						class: 'cbi-input-select',
						change: function (ev) {
							self.data.unattended = ev.target.value;
						}
					},
					['0', '1', '2'].map(function (v) {
						return E(
							'option',
							{ value: v, selected: v === self.data.unattended ? 'selected' : null },
							v +
								' — ' +
								[_('detect and notify'), _('download automatically'), _('flash automatically')][
									parseInt(v, 10)
								]
						);
					})
				),
				E('div', { class: 'rtfw-levels' }, [
					E('ul', { class: 'rtfw-levels-list' }, [
						E('li', {}, [E('b', {}, '0'), ' —— ', _('Checks and notifies only.')]),
						E('li', {}, [E('b', {}, '1'), ' —— ', _('Also downloads the image and verifies its sha256.')]),
						E('li', {}, [
							E('b', {}, '2'),
							' —— ',
							_('Also flashes the image, but only when the verdict is an update (see below).')
						])
					]),
					E('p', { class: 'rtfw-muted rtfw-levels-head' }, _('How "update" is decided')),
					E('ol', { class: 'rtfw-levels-list' }, [
						E(
							'li',
							{},
							_('Identical build id means "already up to date"; nothing is downloaded or flashed.')
						),
						E('li', {}, _('When both sides report a release version, the higher version number wins.')),
						E(
							'li',
							{},
							_('Otherwise the build timestamp is compared: a newer remote counts as an update.')
						),
						E(
							'li',
							{},
							_(
								'Same version or timestamp but a different build id is a rebuild: it is downloaded, never flashed automatically.'
							)
						)
					]),
					E('p', { class: 'rtfw-muted rtfw-levels-head' }, _('For level 2 to flash, all of these must hold')),
					E('ul', { class: 'rtfw-levels-list' }, [
						E('li', {}, _('The verdict is an update, not a rebuild or a downgrade.')),
						E('li', {}, _('The image was downloaded and its sha256 verified on an earlier run.')),
						E(
							'li',
							{},
							_('The image is a sysupgrade squashfs one and the source is the same distribution.')
						),
						E('li', {}, _('No earlier flash is still waiting for a reboot check.'))
					])
				])
			),

			field(
				_('Scheduled task'),
				E(
					'select',
					{
						class: 'cbi-input-select',
						change: function (ev) {
							self.data.kind = ev.target.value;
							replace(self.scheduleNode, self.buildScheduleExtra());
						}
					},
					SCHEDULE_KINDS.map(function (o) {
						return E(
							'option',
							{ value: o.value, selected: o.value === self.data.kind ? 'selected' : null },
							o.text
						);
					})
				),
				_(
					'Runs unattended on this schedule. The entry is written into /etc/crontabs/root inside its own marked block.'
				)
			),

			this.scheduleNode,

			this.scheduleStatusNode,

			field(
				_('Webhook URL'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					placeholder: 'https://example.invalid/hook',
					value: self.data.webhook,
					input: function (ev) {
						self.data.webhook = ev.target.value;
					}
				}),
				_('POST JSON when update events happen. Leave empty to disable.')
			),

			E('div', { class: 'rtfw-toolbar' }, [
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'handleSaveOptions')
					},
					_('Save settings')
				)
			]),

			fmt.callout(
				'',
				_('Where settings live'),
				_(
					'All settings live in /etc/config/rtfwupgrade. Flashing runs sysupgrade with -c -k, so the configuration, the installed-package list and changed files under /etc/ are carried over.'
				)
			)
		]);
	},

	normalizeChannel: function (info) {
		var i = info || {};
		var layout = i.layout || '';

		return {
			source: i.source || '',
			layout: layout,
			usable: i.ok === true,
			locked: i.locked === true,
			pinned: i.pinned || '',
			// 语义通道及其解析出的实际目录（available=false 表示源上没有这条线）
			channels: i.channels || [],
			list: i.list || [],
			origin: i.origin || '',
			stable: i.stable || '',
			oldstable: i.oldstable || '',
			localVersion: i.local_version || ''
		};
	},

	channelLabel: function (chan) {
		if (!chan) return _('Current channel');

		return chan.indexOf('releases/') === 0 ? chan.substr(9) : chan;
	},

	// default 布局（root/targets）只有一个 current：显示但不可改
	buildChannel: function () {
		var self = this;
		var c = this.channel;

		if (!c || !c.usable)
			return [E('p', { class: 'rtfw-muted' }, _('No channel information available for this source.'))];

		if (c.locked)
			return [
				E('div', { class: 'rtfw-channel-row' }, [
					E('span', { class: 'rtfw-mono' }, c.pinned || 'current'),
					E('span', { class: 'rtfw-badge rtfw-tone-muted' }, _('Fixed by layout'))
				]),
				E(
					'p',
					{ class: 'rtfw-muted' },
					_(
						'A default-layout source has a single directory (root/targets), so there is no channel to choose.'
					)
				)
			];

		// 旧配置里可能存着具体目录：不在语义列表里也要列出来，否则会显示成「当前通道」
		var known = c.channels.map(function (x) {
			return x.value;
		});
		var extra = c.pinned && known.indexOf(c.pinned) < 0 ? c.pinned : '';

		var options = CHANNEL_ORDER.map(function (v) {
			var info =
				c.channels.filter(function (x) {
					return x.value === v;
				})[0] || {};
			var text = (CHANNEL_LABELS[v] || v) + (info.dir ? ' · ' + info.dir : '');

			return E(
				'option',
				{
					value: v,
					selected: v === c.pinned ? 'selected' : null,
					// 源上没有这条线：置灰，避免选中后检测才报错
					disabled: info.available === false ? 'disabled' : null
				},
				text
			);
		});

		if (extra)
			options.push(
				E(
					'option',
					{ value: extra, selected: extra === c.pinned ? 'selected' : null },
					self.channelLabel(extra)
				)
			);

		var select = E(
			'select',
			{
				class: 'cbi-input-select',
				change: ui.createHandlerFn(this, 'handleChannelChange')
			},
			options
		);

		var cur =
			c.channels.filter(function (x) {
				return x.value === c.pinned;
			})[0] || {};

		return [
			E('div', { class: 'rtfw-channel-row' }, [
				select,
				cur.available === false && !extra
					? E('span', { class: 'rtfw-badge rtfw-tone-warning' }, _('Not on this source'))
					: c.pinned
						? E('span', { class: 'rtfw-badge rtfw-tone-notice' }, _('Follow a version line'))
						: ''
			])
		].concat(this.buildChannelHelp());
	},

	// 每个通道的定义与取数策略：用户要能看懂「选它之后会去哪个目录、什么时候变」。
	// 目录示例按当前源的实际解析结果给，而不是写死的版本号。
	buildChannelHelp: function () {
		var c = this.channel;
		var dirOf = function (v) {
			var hit =
				(c.channels || []).filter(function (x) {
					return x.value === v;
				})[0] || {};
			return hit.dir || '';
		};
		var ver = c.localVersion || '';

		var rows = [
			[
				'',
				_(
					'Uses the release line this device already runs: a snapshot build probes the snapshots directory, a release build probes its own version line.'
				),
				dirOf('')
			],
			['snapshot', _('Always probes the snapshots directory, whatever this device runs.'), dirOf('snapshot')],
			[
				'stable',
				_(
					'Probes the version the source currently publishes as its stable release. Moves on when the source moves.'
				),
				dirOf('stable')
			],
			[
				'oldstable',
				_('Probes the version the source publishes as its old stable release. Moves on when the source moves.'),
				dirOf('oldstable')
			],
			['major', _('Probes the newest release within the same major version as this device.'), dirOf('major')],
			['minor', _('Probes the newest release within the same version line as this device.'), dirOf('minor')]
		];

		return [
			E('p', { class: 'rtfw-muted rtfw-levels-head' }, _('What each channel means')),
			E(
				'ul',
				{ class: 'rtfw-levels-list' },
				rows.map(function (r) {
					return E('li', {}, [
						E('b', {}, CHANNEL_LABELS[r[0]] || r[0]),
						' —— ',
						r[1],
						r[2] ? ' ' : '',
						r[2] ? E('code', {}, r[2]) : ''
					]);
				})
			),
			E('p', { class: 'rtfw-muted' }, [
				_(
					'Semantic channels are resolved against the source on every check, so a pick is not tied to one patch release. The image, the sha256 check and the update verdict work the same way for every channel.'
				),
				ver ? ' ' + _('This device runs %s.').format(ver) : ''
			])
		];
	},

	handleChannelChange: function (ev) {
		var self = this;
		var next = ev.target.value;
		var prev = this.channel.pinned;

		if (next === prev) return Promise.resolve(false);

		ev.target.value = prev;

		return ui.showModal(_('Switch update channel'), [
			E(
				'p',
				{},
				_('You are switching this source from %s to %s.').format(
					this.channelLabel(prev),
					this.channelLabel(next)
				)
			),
			fmt.callout(
				'warning',
				_('What this changes'),
				E('ul', {}, [
					E('li', {}, _('The last check result is discarded, because it was produced by another channel.')),
					E(
						'li',
						{},
						_(
							'Builds from different channels are not comparable: pinning an older release makes the remote look older, and the verdict turns into a downgrade.'
						)
					),
					E(
						'li',
						{},
						_(
							'The scheduled task follows this setting too, so unattended level 2 will flash from the channel you pick here.'
						)
					)
				])
			),
			E('div', { class: 'right rtfw-toolbar' }, [
				E('button', { class: 'btn', click: ui.hideModal }, _('Cancel') + '\u00a0'),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'doSetChannel', next)
					},
					_('Switch channel')
				)
			])
		]);
	},

	doSetChannel: function (next) {
		var self = this;

		return callSetChannel(this.channel.source || this.activeSource, next)
			.then(function (res) {
				if (!res || res.ok === false) throw new Error((res && res.error) || _('Switch failed'));

				ui.hideModal();
				self.channel.pinned = res.channel || '';
				replace(self.channelNode, self.buildChannel());
				ui.addNotification(
					null,
					E(
						'p',
						{},
						_('Update channel switched to %s. Run a check again.').format(
							self.channelLabel(res.channel || '')
						)
					),
					'info'
				);
				return true;
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Switch failed: ') + (err.message || err)), 'error');
				return false;
			});
	},

	buildSources: function () {
		var self = this;

		var rows = this.sources.map(function (s) {
			return E('tr', {}, [
				E(
					'td',
					{ class: 'rtfw-col-check' },
					E('input', {
						type: 'radio',
						name: 'rtfw-active-source',
						value: s.name,
						checked: s.name === self.active ? 'checked' : null,
						change: function (ev) {
							self.active = ev.target.value;
						}
					})
				),
				E('td', { class: 'rtfw-col-name', title: _('identifier') + ': ' + s.name }, s.label || s.name),
				E('td', { class: 'rtfw-mono rtfw-col-layout' }, s.layout || '-'),
				E('td', { class: 'rtfw-mono' }, s.url || '-'),
				E('td', { class: 'rtfw-mono rtfw-col-system' }, s.system ? s.system : '-'),
				E(
					'td',
					{ class: 'rtfw-col-action' },
					E('div', { class: 'rtfw-rowactions' }, [
						E(
							'button',
							{
								class: 'rtfw-rowbtn rtfw-rowbtn-edit',
								click: ui.createHandlerFn(self, 'handleEdit', s.name)
							},
							_('Edit')
						),
						E(
							'button',
							{
								class: 'rtfw-rowbtn',
								click: ui.createHandlerFn(self, 'handleDelete', s.name)
							},
							_('Delete')
						)
					])
				)
			]);
		});

		return [
			E('table', { class: 'table rtfw-table rtfw-sources' }, [
				E(
					'thead',
					{},
					E('tr', {}, [
						E('th', { class: 'rtfw-col-check' }, _('Active source')),
						E('th', { class: 'rtfw-col-name' }, _('Name')),
						E('th', { class: 'rtfw-col-layout' }, _('Layout')),
						E('th', {}, _('Address')),
						E('th', { class: 'rtfw-col-system' }, _('System')),
						E('th', { class: 'rtfw-col-action' }, _('Actions'))
					])
				),
				E('tbody', {}, rows.concat([this.buildAddRow()])),
				// 表格下方两段说明：布局讲目录结构，操作讲这两个按钮怎么用。
				// 拆成独立容器，是为了让对话框只取用其中的布局那一段。
				E(
					'tfoot',
					{},
					E('tr', {}, E('td', { class: 'rtfw-layout-cell', colspan: '6' }, [layoutHelp(), actionsHelp()]))
				)
			]),
			E('div', { class: 'rtfw-toolbar' }, [
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'handleSaveActive')
					},
					_('Save and apply')
				)
			])
		];
	},

	// 表格最后一行的快速添加：顺序与列一致，只有必填项
	buildAddRow: function () {
		var self = this;
		var els = (this.rowEls = {});

		function text(key, ph) {
			var el = E('input', { class: 'cbi-input-text', type: 'text', placeholder: ph });
			els[key] = el;
			return el;
		}

		els.preset = E(
			'select',
			{
				class: 'cbi-input-select',
				change: function (ev) {
					var preset = PRESETS[parseInt(ev.target.value, 10)];

					if (!preset) return;

					els.label.value = preset.label;
					els.url.value = preset.url;
					els.layout.value = preset.layout;
					els.system.value = preset.system;
				}
			},
			[E('option', { value: '' }, _('Preset'))].concat(
				PRESETS.map(function (preset, i) {
					return E('option', { value: '' + i }, preset.short);
				})
			)
		);

		// 布局下拉只显示 official / default；具体目录结构放在标题与表格下方的说明里
		els.layout = E(
			'select',
			{ class: 'cbi-input-select', title: layoutTitle() },
			this.layouts.map(function (l) {
				return E(
					'option',
					{ value: l, selected: l === 'official' ? 'selected' : null, title: layoutHint(l) },
					l
				);
			})
		);

		return E('tr', { class: 'rtfw-addrow' }, [
			E('td', { class: 'rtfw-col-check' }, els.preset),
			E('td', { class: 'rtfw-col-name' }, text('label', _('Source label'))),
			E('td', { class: 'rtfw-col-layout' }, els.layout),
			E('td', {}, text('url', 'https://example.invalid/immortalwrt')),
			E('td', { class: 'rtfw-col-system' }, text('system', _('optional placeholder'))),
			E('td', { class: 'rtfw-col-action rtfw-addcell' }, [
				E(
					'button',
					{ class: 'rtfw-rowbtn rtfw-rowbtn-ok', click: ui.createHandlerFn(this, 'handleQuickAdd') },
					_('Add')
				),
				E(
					'button',
					{ class: 'rtfw-rowbtn rtfw-rowbtn-plain', click: ui.createHandlerFn(this, 'handleAdvanced') },
					_('Advanced')
				)
			])
		]);
	},

	// 「高级」对话框：完整参数（含标识）
	buildAdvancedForm: function () {
		var self = this;
		var adv = this.adv;

		function bind(key) {
			return function (ev) {
				adv[key] = ev.target.value;
			};
		}

		return E('div', { class: 'rtfw-modal-form' }, [
			field(
				_('Preset'),
				E(
					'select',
					{
						class: 'cbi-input-select',
						change: function (ev) {
							var preset = PRESETS[parseInt(ev.target.value, 10)];

							self.adv = {
								preset: ev.target.value,
								name: '',
								label: preset ? preset.label : '',
								url: preset ? preset.url : '',
								layout: preset ? preset.layout : 'official',
								system: preset ? preset.system : ''
							};
							replace(self.advNode, self.buildAdvancedForm());
						}
					},
					[E('option', { value: '' }, _('— pick a preset —'))].concat(
						PRESETS.map(function (preset, i) {
							return E(
								'option',
								{ value: '' + i, selected: adv.preset === '' + i ? 'selected' : null },
								preset.text
							);
						})
					)
				),
				_('fills the fields below; you can edit everything afterwards')
			),

			field(
				_('Source label'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					value: adv.label,
					placeholder: _('My mirror'),
					input: bind('label')
				}),
				_('shown in the table; free text, duplicates allowed')
			),

			field(
				_('Layout'),
				E(
					'select',
					{
						class: 'cbi-input-select',
						title: layoutTitle(),
						change: bind('layout')
					},
					this.layouts.map(function (l) {
						return E(
							'option',
							{ value: l, selected: l === adv.layout ? 'selected' : null, title: layoutHint(l) },
							l
						);
					})
				),
				layoutHelp()
			),

			field(
				_('Address'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					value: adv.url,
					placeholder: 'https://example.invalid/immortalwrt',
					input: bind('url')
				})
			),

			field(
				_('System'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					value: adv.system,
					placeholder: _('optional, e.g. immortalwrt'),
					input: bind('system')
				}),
				_('path segment for mirrors that host several systems, e.g. rtfw/immortalwrt')
			),

			field(
				_('Identifier'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					value: adv.name,
					placeholder: _('auto-generated when empty'),
					input: bind('name')
				}),
				_(
					'internal UCI section name (lower-case letters, digits, underscore); normally you do not need to set it'
				)
			),

			E('div', { class: 'right rtfw-toolbar' }, [
				E('button', { class: 'btn', click: ui.hideModal }, _('Cancel') + '\u00a0'),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'handleAdvancedAdd')
					},
					_('Add')
				)
			])
		]);
	},

	// 「编辑」对话框：标识（UCI 段名）只读，label/layout/url/system 可改。
	// 编辑状态单独放在 this.edit，绝不复用「添加」的 this.adv。
	buildEditForm: function () {
		var self = this;
		var ed = this.edit || {};

		function bind(key) {
			return function (ev) {
				ed[key] = ev.target.value;
			};
		}

		return E('div', { class: 'rtfw-modal-form' }, [
			field(
				_('Identifier'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					value: ed.name || '',
					readonly: 'readonly',
					disabled: 'disabled'
				}),
				_('It is the UCI section name and cannot be changed.')
			),

			field(
				_('Source label'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					value: ed.label || '',
					placeholder: _('My mirror'),
					input: bind('label')
				}),
				_('shown in the table; free text, duplicates allowed')
			),

			field(
				_('Layout'),
				E(
					'select',
					{
						class: 'cbi-input-select',
						title: layoutTitle(),
						change: bind('layout')
					},
					this.layouts.map(function (l) {
						return E(
							'option',
							{ value: l, selected: l === ed.layout ? 'selected' : null, title: layoutHint(l) },
							l
						);
					})
				),
				layoutHelp()
			),

			field(
				_('Address'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					value: ed.url || '',
					placeholder: 'https://example.invalid/immortalwrt',
					input: bind('url')
				})
			),

			field(
				_('System'),
				E('input', {
					class: 'cbi-input-text',
					type: 'text',
					value: ed.system || '',
					placeholder: _('optional, e.g. immortalwrt'),
					input: bind('system')
				}),
				_('path segment for mirrors that host several systems, e.g. rtfw/immortalwrt')
			),

			E('div', { class: 'right rtfw-toolbar' }, [
				E('button', { class: 'btn', click: ui.hideModal }, _('Cancel') + '\u00a0'),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'handleEditSave')
					},
					_('Save')
				)
			])
		]);
	},

	// 定时任务状态：crontab 里的受管块是否与当前配置一致
	buildScheduleStatus: function (sch) {
		if (!sch)
			return [
				fmt.callout(
					'',
					_('Scheduled task status'),
					_('The schedule status is not available yet. Save the settings once to sync the crontab.')
				)
			];

		var wanted = sch.wanted || '';
		var applied = sch.applied || '';
		var state = '';
		var tone = '';
		var detail = '';

		if (!wanted && !applied) {
			state = _('Not written');
			detail = _('The scheduled task is off, so no crontab entry is expected.');
		} else if (!wanted) {
			state = _('Out of sync');
			tone = 'warning';
			detail = _('A managed crontab block is still present; save the settings to remove it.');
		} else if (!applied) {
			state = _('Not written');
			detail = _('The managed block has not been written yet; save the settings to write it.');
		} else if (sch.in_sync) {
			state = _('Written to crontab');
			tone = 'success';
			detail = _('The managed block matches the current schedule.');
		} else {
			state = _('Out of sync');
			tone = 'warning';
			detail = _('The managed block differs from the current schedule; save the settings to rewrite it.');
		}

		// 用户只需要知道「成了没有」。两行 cron 与路径属于排查用的细节：
		// 只在没同步时给出一行可复制的命令，其余折叠进 details，避免默认界面充斥长命令。
		var nodes = [
			E('div', { class: 'rtfw-schedule-state' }, [
				E('span', { class: 'rtfw-badge rtfw-tone-' + (tone || 'muted') }, state),
				E('span', { class: 'rtfw-muted' }, ' ' + detail)
			])
		];

		// 只有「该写却没写」时才把期望的命令直接摆出来——那时用户需要它来核对或手动补。
		if (wanted && !sch.in_sync) nodes.push(E('div', { class: 'rtfw-schedule-value' }, wanted));

		var diag = [E('div', { class: 'rtfw-schedule-path' }, _('Crontab path: %s').format(sch.path || '-'))];
		if (wanted) diag.push(E('div', { class: 'rtfw-schedule-path' }, _('Wanted: %s').format(wanted)));
		if (applied && applied !== wanted)
			diag.push(E('div', { class: 'rtfw-schedule-path' }, _('Applied: %s').format(applied)));

		nodes.push(
			E('details', { class: 'rtfw-details' }, [E('summary', {}, _('Task diagnostics')), E('div', {}, diag)])
		);

		return [fmt.callout(tone, _('Scheduled task status'), nodes)];
	},

	buildScheduleExtra: function () {
		var self = this;
		var d = this.data;
		var out = [];

		if (d.kind === 'off') return [E('p', { class: 'rtfw-muted' }, _('The scheduled check is disabled.'))];

		if (d.kind === 'weekly')
			out.push(
				field(
					_('Weekday'),
					E(
						'select',
						{
							class: 'cbi-input-select',
							change: function (ev) {
								self.data.weekday = ev.target.value;
							}
						},
						WEEKDAYS.map(function (t, i) {
							return E(
								'option',
								{ value: '' + (i + 1), selected: '' + (i + 1) === d.weekday ? 'selected' : null },
								t
							);
						})
					)
				)
			);

		if (d.kind === 'monthly')
			out.push(
				field(
					_('Day of month'),
					E(
						'select',
						{
							class: 'cbi-input-select',
							change: function (ev) {
								self.data.day = ev.target.value;
							}
						},
						Array.from({ length: 28 }, function (_, i) {
							return E(
								'option',
								{ value: '' + (i + 1), selected: '' + (i + 1) === d.day ? 'selected' : null },
								'' + (i + 1)
							);
						})
					),
					_('1-28 only, so that every month triggers')
				)
			);

		out.push(
			field(
				_('Time (24h)'),
				E('input', {
					class: 'cbi-input-text',
					type: 'time',
					value: d.time,
					input: function (ev) {
						self.data.time = ev.target.value;
					}
				})
			)
		);

		return out;
	},

	handleQuickAdd: function () {
		var self = this;
		var els = this.rowEls || {};
		var v = {
			name: '',
			label: ((els.label && els.label.value) || '').trim(),
			url: ((els.url && els.url.value) || '').trim(),
			layout: (els.layout && els.layout.value) || 'official',
			system: ((els.system && els.system.value) || '').trim()
		};

		if (!v.label || !v.url) {
			ui.addNotification(
				null,
				E('p', {}, _('Quick add needs a label and an address at least — use Advanced for the rest.')),
				'warning'
			);
			return Promise.resolve(false);
		}

		return this.addSource(v).then(function (ok) {
			if (ok) {
				['label', 'url', 'system'].forEach(function (k) {
					if (self.rowEls[k]) self.rowEls[k].value = '';
				});
				if (self.rowEls.preset) self.rowEls.preset.value = '';
			}
			return ok;
		});
	},

	handleAdvanced: function () {
		this.adv = { preset: '', name: '', label: '', url: '', layout: 'official', system: '' };
		this.advNode = E('div', {}, this.buildAdvancedForm());

		return ui.showModal(_('Add source'), [this.advNode]);
	},

	handleAdvancedAdd: function () {
		var self = this;

		return this.addSource(this.adv).then(function (ok) {
			if (ok) ui.hideModal();
			return ok;
		});
	},

	// 快速添加与高级对话框共用的落地逻辑
	addSource: function (v) {
		var self = this;

		return callSourceAdd(v.name, v.label, v.url, v.layout, v.system)
			.then(function (res) {
				if (!res || res.ok === false) throw new Error((res && res.error) || _('Add failed'));

				self.refreshSources(res);
				ui.addNotification(null, E('p', {}, _('Source added.')), 'info');
				return true;
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Add failed: ') + (err.message || err)), 'error');
				return false;
			});
	},

	// 编辑入口：从表格行取当前值，放进独立的 this.edit 状态
	handleEdit: function (name) {
		var src = (this.sources || []).filter(function (x) {
			return x.name === name;
		})[0];

		if (!src) {
			ui.addNotification(null, E('p', {}, _('Update failed')), 'error');
			return Promise.resolve(false);
		}

		// 通道不在这个表单里编辑（它在概览页切换），但必须原样带回去：
		// source_set 收到空 channel 会把它从配置里删掉，编辑一下名称就把钉住的通道弄丢了。
		this.edit = {
			name: src.name,
			label: src.label || '',
			url: src.url || '',
			layout: src.layout || 'official',
			system: src.system || '',
			channel: src.channel || ''
		};
		this.editNode = E('div', {}, this.buildEditForm());

		return ui.showModal(_('Edit source'), [this.editNode]);
	},

	handleEditSave: function () {
		var self = this;
		var ed = this.edit;

		if (!ed) return Promise.resolve(false);

		return callSourceSet(ed.name, ed.label, ed.url, ed.layout, ed.system, ed.channel)
			.then(function (res) {
				if (!res || res.ok === false) throw new Error((res && res.error) || _('Update failed'));

				self.refreshSources(res);
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('Source updated.')), 'info');
				return true;
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Update failed: ') + (err.message || err)), 'error');
				return false;
			});
	},

	refreshSources: function (res) {
		if (res && res.sources) {
			this.sources = res.sources;
			this.active = res.active_source || this.active;
			replace(this.sourcesNode, this.buildSources());
		}
	},

	handleDelete: function (name) {
		var src =
			(this.sources || []).filter(function (x) {
				return x.name === name;
			})[0] || {};

		return ui.showModal(_('Delete source'), [
			E(
				'p',
				{},
				_(
					'Delete source %s? Its section is removed from the configuration and the last check result is discarded.'
				).format(src.label || name)
			),
			E('div', { class: 'right' }, [
				E('button', { class: 'btn', click: ui.hideModal }, _('Cancel') + '\u00a0'),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-negative',
						click: ui.createHandlerFn(this, 'doDelete', name)
					},
					_('Delete')
				)
			])
		]);
	},

	doDelete: function (name) {
		var self = this;

		ui.hideModal();

		return callSourceDel(name)
			.then(function (res) {
				if (!res || res.ok === false) throw new Error((res && res.error) || _('Delete failed'));

				self.refreshSources(res);
				ui.addNotification(null, E('p', {}, _('Source deleted.')), 'info');
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Delete failed: ') + (err.message || err)), 'error');
			});
	},

	// 切换激活源要先讲清代价：后端 set_active 会作废上一次检测结果，
	// 而刷写目标、定时任务与自动刷写全都跟着这个源走。
	// 弹窗要显示源的名字，而不是段名（id）。段名是稳定标识，但它不是给人读的：
	// 'openwrt' 应显示成「OpenWrt 官方」，'shuery' 应显示成「Shuery 单版站」。
	sourceLabel: function (name) {
		if (!name) return _('none');

		var hit = (this.sources || []).filter(function (s) {
			return s.name === name;
		})[0];

		return (hit && hit.label) || name;
	},

	handleSaveActive: function () {
		if (this.active === this.activeSource) {
			ui.addNotification(
				null,
				E('p', {}, _('The active source is already %s.').format(this.sourceLabel(this.activeSource))),
				'info'
			);
			return Promise.resolve(false);
		}

		// current_firmware_source 为空 = 首次设置。这不是「切换」，而是给这台设备选定
		// 固件来源，选错会导致后续镜像与本机对不上，所以要专门提醒一次。
		if (!this.currentFirmwareSource) return this.confirmFirstSource();

		// 已经确认过来源，现在改成另一个源：这才叫「切换」，A 必须取已确认源。
		var from = this.sourceLabel(this.currentFirmwareSource);
		var to = this.sourceLabel(this.active);

		return ui.showModal(_('Switch active source'), [
			E('p', {}, _('Move the active source from %s to %s?').format(from, to)),
			fmt.callout(
				'warning',
				_('What this changes'),
				E('ul', {}, [
					E('li', {}, _('The last check result is discarded, because it came from the other source.')),
					E(
						'li',
						{},
						_(
							'The next check probes the new source: a different build series may look newer or older than the one running now.'
						)
					),
					E(
						'li',
						{},
						_(
							'The scheduled task and unattended level 2 follow this source too, so automatic flashing will target it.'
						)
					)
				])
			),
			E('div', { class: 'right rtfw-toolbar' }, [
				E('button', { class: 'btn', click: ui.hideModal }, _('Cancel') + ' '),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'doSetActive', this.active)
					},
					_('Switch source')
				)
			])
		]);
	},

	// 首次设置固件来源：说明这一步在做什么、选错会怎样，确认后才写入。
	confirmFirstSource: function () {
		var to = this.sourceLabel(this.active);

		return ui.showModal(_('Confirm the firmware source'), [
			E('p', {}, _('Set the firmware source for this device to %s?').format(to)),
			fmt.callout(
				'warning',
				_('Why this matters'),
				E('ul', {}, [
					E(
						'li',
						{},
						_(
							'This becomes the reference for every later comparison: the page judges whether an image is newer, older or the same by comparing against the source you pick here.'
						)
					),
					E(
						'li',
						{},
						_(
							'If you pick a source that builds for a different system, the image it offers is not the one this device is running.'
						)
					),
					E(
						'li',
						{},
						_(
							'The scheduled task and unattended level 2 follow this source too, so automatic flashing will target it.'
						)
					)
				])
			),
			E('div', { class: 'right rtfw-toolbar' }, [
				E('button', { class: 'btn', click: ui.hideModal }, _('Cancel') + ' '),
				E(
					'button',
					{
						class: 'btn cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, 'doSetActive', this.active)
					},
					_('Set as firmware source')
				)
			])
		]);
	},

	doSetActive: function (name) {
		var self = this;

		return callSetActive(name)
			.then(function (res) {
				if (!res || res.ok === false) throw new Error((res && res.error) || _('Save failed'));

				ui.hideModal();
				self.active = name;
				self.activeSource = name;

				// 首次确认时后端会顺带写入 current_firmware_source，
				// 这里同步到前端，否则下次切换仍会被当成「首次」而跳过警告。
				if (res.config) self.currentFirmwareSource = res.config.current_firmware_source || '';

				ui.addNotification(null, E('p', {}, _('Active source updated.')), 'info');

				// 通道跟着源走：换了源就得换一份通道列表，否则界面还在显示上一个源的
				return callChannels(name)
					.then(function (info) {
						self.channel = self.normalizeChannel(info);
						replace(self.channelNode, self.buildChannel());
					})
					.catch(function () {
						// 取不到就退回「无通道信息」提示，不要留着旧源的通道
						self.channel = self.normalizeChannel(null);
						replace(self.channelNode, self.buildChannel());
					});
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Save failed: ') + (err.message || err)), 'error');
			});
	},

	// 保存后刷新定时任务状态：优先重新查询，查询失败时用 set_options 返回的 sync 结果兜底
	refreshScheduleStatus: function (fallback) {
		var self = this;

		return callScheduleStatus()
			.then(function (sch) {
				self.schedule = sch || null;
			})
			.catch(function () {
				self.schedule = fallback
					? {
							path: '',
							schedule: fallback.schedule || '',
							wanted: fallback.line || '',
							applied: fallback.ok ? fallback.line || '' : '',
							in_sync: fallback.ok === true
						}
					: null;
			})
			.then(function () {
				replace(self.scheduleStatusNode, self.buildScheduleStatus(self.schedule));
			});
	},

	handleSaveOptions: function () {
		var self = this;
		var d = this.data;

		return callSetOptions(d.unattended, d.kind, d.time, d.weekday, d.day, d.webhook)
			.then(function (res) {
				if (!res || res.ok === false) throw new Error((res && res.error) || _('Save failed'));

				ui.addNotification(null, E('p', {}, _('Settings saved.')), 'info');
				return self.refreshScheduleStatus(res.schedule);
			})
			.catch(function (err) {
				ui.addNotification(null, E('p', {}, _('Save failed: ') + (err.message || err)), 'error');
			});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
