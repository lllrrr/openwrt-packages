'use strict';
'require view';
'require rpc';
'require ui';

// 引入样式表, 与其它视图共用, 通过 id 去重
if (!document.getElementById('chfs-stylesheet')) {
	document.querySelector('head').appendChild(
		E('link', {
			'id': 'chfs-stylesheet',
			'rel': 'stylesheet',
			'href': L.resource('view/chfs/chfs.css')
		})
	);
}

// ---------------------------------------------------------------------------
// 后端接口
//
// 全部方法在 rpcd 的 luci.chfs 对象下, 由 /usr/share/rpcd/ucode/luci.chfs 注册。
// 内核动作一律"先落到待安装区, 再由用户确认安装", 不做下载即替换,
// 使用户在覆盖正在运行的内核之前有机会核对大小、架构与校验值。
// ---------------------------------------------------------------------------

var callKernelInfo = rpc.declare({
	object: 'luci.chfs',
	method: 'kernel_info',
	expect: {}
});

var callKernelSources = rpc.declare({
	object: 'luci.chfs',
	method: 'kernel_sources',
	expect: {}
});

var callKernelPending = rpc.declare({
	object: 'luci.chfs',
	method: 'kernel_pending',
	expect: {}
});

var callKernelBackups = rpc.declare({
	object: 'luci.chfs',
	method: 'kernel_backups',
	expect: {}
});

var callKernelDownload = rpc.declare({
	object: 'luci.chfs',
	method: 'kernel_download',
	params: [ 'url' ],
	expect: {}
});

var callKernelInstall = rpc.declare({
	object: 'luci.chfs',
	method: 'kernel_install',
	params: [ 'src' ],
	expect: {}
});

var callKernelRestore = rpc.declare({
	object: 'luci.chfs',
	method: 'kernel_restore',
	params: [ 'name' ],
	expect: {}
});

var callKernelDiscard = rpc.declare({
	object: 'luci.chfs',
	method: 'kernel_discard',
	params: [ 'name' ],
	expect: {}
});

// 待安装目录, 必须与后端 UPLOAD_DIR 保持一致
var UPLOAD_DIR = '/etc/luci-uploads';

// ELF e_machine 取值到名称的映射, 用于把裸数字翻译成人能读懂的架构名。
// 只列出本插件可能遇到的架构, 其余原样显示数字。
var ELF_MACHINES = {
	3: 'x86 (i386)',
	8: 'MIPS',
	20: 'PowerPC',
	21: 'PowerPC64',
	40: 'ARM (32-bit)',
	62: 'x86-64 (amd64)',
	183: 'AArch64 (arm64)'
};

// ---------------------------------------------------------------------------
// 展示辅助
// ---------------------------------------------------------------------------

// 用给定内容整体替换容器内的子节点
function setBox(box, content) {
	while (box.firstChild)
		box.removeChild(box.firstChild);

	if (content)
		box.appendChild(content);
}

// 生成一行键值展示
function kv(label, value, mono) {
	return E('div', { 'class': 'chfs-kv' }, [
		E('span', { 'class': 'chfs-kv-key' }, label),
		E('span', { 'class': 'chfs-kv-val' + (mono ? ' chfs-mono' : '') }, value)
	]);
}

// 字节数转可读单位
function fmtBytes(n) {
	n = parseInt(n, 10);

	if (isNaN(n) || n < 0)
		return '-';

	if (n >= 1048576)
		return (n / 1048576).toFixed(2) + ' MB (' + n + ' ' + _('bytes') + ')';

	if (n >= 1024)
		return (n / 1024).toFixed(1) + ' KB (' + n + ' ' + _('bytes') + ')';

	return n + ' ' + _('bytes');
}

// e_machine 数值转名称
function elfName(m) {
	if (m == null || m < 0)
		return _('Unknown');

	return ELF_MACHINES[m] ? ELF_MACHINES[m] + ' (e_machine=' + m + ')' : 'e_machine=' + m;
}

// sha256 截断显示, 完整值通过 title 提示
function shaShort(s) {
	if (!s)
		return '-';

	return E('span', { 'class': 'chfs-mono', 'title': s }, s.substring(0, 16) + '...');
}

// 架构匹配标签
function archBadge(match) {
	if (match)
		return E('span', { 'class': 'cbi-label label-success' }, _('Matches'));

	return E('span', { 'class': 'cbi-label label-danger' }, _('Mismatch'));
}

return view.extend({
	// 首屏只拉取本地信息, 不发起任何网络探测:
	// kernel_sources 会对 6 个候选源逐个发起 HEAD 请求, 在路由器上可能耗时
	// 十几秒, 放进 load() 会让页面长时间白屏。改为由用户点击按钮触发。
	load: function() {
		return Promise.all([
			callKernelInfo().catch(function() { return null; }),
			callKernelPending().catch(function() { return null; }),
			callKernelBackups().catch(function() { return null; })
		]);
	},

	render: function(data) {
		var info = data[0] || {};
		var pending = data[1] || {};
		var backups = data[2] || {};
		var self = this;

		var container = E('div', { 'class': 'cbi-map chfs-kernel-page' }, [
			E('h2', {}, _('chfs kernel management')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Replace the chfs binary used by the service. Kernels can be downloaded from this project repository or uploaded manually; either way the file is placed in a pending area first and only written to the program path after you confirm, so a wrong or unreadable binary never silently replaces a working one.'))
		]);

		// ------------------------------------------------------------------
		// 当前内核
		// ------------------------------------------------------------------
		var infoCard = E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('Current kernel'))
		]);

		if (!info.exists) {
			infoCard.appendChild(E('div', { 'class': 'chfs-alert chfs-alert-warn' },
				info.msg || _('The chfs binary was not found. Install the chfs package or use one of the options below.')));

			infoCard.appendChild(kv(_('Device architecture'), info.device_arch || '-', true));
			infoCard.appendChild(kv(_('Kernel branch'), info.kernel_name || '-', true));
		}
		else {
			infoCard.appendChild(kv(_('Device architecture'), info.device_arch || '-', true));
			infoCard.appendChild(kv(_('Kernel branch'), info.kernel_name || '-', true));
			infoCard.appendChild(kv(_('Program path'), info.path || '-', true));
			infoCard.appendChild(kv(_('File size'), fmtBytes(info.size)));
			infoCard.appendChild(E('div', { 'class': 'chfs-kv' }, [
				E('span', { 'class': 'chfs-kv-key' }, _('Architecture')),
				E('span', { 'class': 'chfs-kv-val' }, [
					E('span', { 'class': 'chfs-mono' }, elfName(info.elf_machine)),
					' ',
					archBadge(info.arch_match)
				])
			]));
			infoCard.appendChild(kv(_('SHA256'), info.sha256 || '-', true));
			infoCard.appendChild(kv(_('Expected version'), info.version || '-'));
		}

		container.appendChild(infoCard);

		// ------------------------------------------------------------------
		// 一键下载
		// ------------------------------------------------------------------
		var srcBox = E('div', {}, [
			E('p', { 'class': 'chfs-note' },
				_('Click "Detect sources" to check which download sources are reachable from this device. Detection issues a HEAD request to each candidate and does not download any payload.'))
		]);

		var detectBtn = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();
				return self.handleDetectSources(srcBox, detectBtn);
			}
		}, _('Detect sources'));

		container.appendChild(E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('One-click download')),
			E('p', { 'class': 'chfs-note' },
				_('Download a kernel built for this device from this project repository. The file is saved to the pending area and is not installed automatically.')),
			E('div', { 'class': 'chfs-actions' }, [ detectBtn ]),
			srcBox
		]));

		// ------------------------------------------------------------------
		// 手动上传
		// ------------------------------------------------------------------
		var fileInput = E('input', {
			'type': 'file',
			'class': 'cbi-input-file chfs-file-input',
			'change': function(ev) {
				if (fileInput.files && fileInput.files.length)
					nameLabel.textContent = fileInput.files[0].name + ' (' + fmtBytes(fileInput.files[0].size) + ')';
				else
					nameLabel.textContent = _('No file selected');
			}
		});

		var nameLabel = E('span', { 'class': 'chfs-hint' }, _('No file selected'));

		var upBtn = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();

				if (!fileInput.files || !fileInput.files.length) {
					ui.addNotification(null, E('p', {}, _('Please choose a file first')), 'warning');
					return;
				}

				return self.handleUpload(fileInput.files[0], upBtn);
			}
		}, _('Upload'));

		container.appendChild(E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('Manual upload')),
			E('p', { 'class': 'chfs-note' },
				_('Upload a chfs binary from your computer. This is the fallback when the device cannot reach any download source. The file is saved to the pending area and must be installed afterwards.')),
			E('div', { 'class': 'chfs-actions' }, [ fileInput, upBtn, nameLabel ])
		]));

		// ------------------------------------------------------------------
		// 待安装文件
		// ------------------------------------------------------------------
		var pendCard = E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('Pending files')),
			E('p', { 'class': 'chfs-note' },
				_('Files in the pending area. Installing one will stop the service, replace the program file and start it again.'))
		]);

		var files = pending.files || [];

		if (!files.length) {
			pendCard.appendChild(E('p', { 'class': 'chfs-hint' }, _('No pending files.')));
		}
		else {
			var tb = E('tbody', {});

			files.forEach(function(f) {
				var installBtn = E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) {
						ev.preventDefault();
						return self.confirmDialog(
							_('Install this kernel?'),
							_('The service will be stopped, %s will be replaced and the service will be started again. The current kernel is backed up first.').format('/usr/bin/chfs'),
							_('Install'),
							function() {
								return self.runAction(
									callKernelInstall(f.path),
									_('Installing kernel ...'),
									_('Kernel installed'));
							});
					}
				}, _('Install'));

				// 非 ELF 或架构不符的文件安装必然失败, 直接禁用避免无谓的服务重启
				if (!f.is_elf || !f.arch_match)
					installBtn.disabled = true;

				var delBtn = E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-reset',
					'click': function(ev) {
						ev.preventDefault();
						return self.confirmDialog(
							_('Delete this file?'),
							_('The file will be removed from the pending area. This does not affect the running kernel.'),
							_('Delete'),
							function() {
								return self.runAction(
									callKernelDiscard(f.name),
									_('Deleting file ...'),
									_('File deleted'));
							});
					}
				}, _('Delete'));

				tb.appendChild(E('tr', {}, [
					E('td', { 'class': 'chfs-mono' }, f.name),
					E('td', {}, fmtBytes(f.size)),
					E('td', {}, f.is_elf ? E('span', { 'class': 'chfs-mono' }, elfName(f.elf_machine)) : E('span', { 'class': 'cbi-label label-danger' }, _('Not an ELF file'))),
					E('td', {}, f.is_elf ? archBadge(f.arch_match) : '-'),
					E('td', {}, shaShort(f.sha256)),
					E('td', { 'class': 'chfs-col-action' }, E('div', { 'class': 'chfs-actions' }, [ installBtn, delBtn ]))
				]));
			});

			pendCard.appendChild(E('table', { 'class': 'chfs-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('File name')),
					E('th', {}, _('Size')),
					E('th', {}, _('ELF architecture')),
					E('th', {}, _('Architecture')),
					E('th', {}, _('SHA256')),
					E('th', { 'class': 'chfs-col-action' }, _('Actions'))
				])),
				tb
			]));
		}

		container.appendChild(pendCard);

		// ------------------------------------------------------------------
		// 备份与回滚
		// ------------------------------------------------------------------
		var bakCard = E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('Backups')),
			E('p', { 'class': 'chfs-note' },
				_('A backup of the program file is created automatically before every install. Rolling back replaces the running binary with the selected backup.'))
		]);

		var baks = backups.backups || [];

		if (!baks.length) {
			bakCard.appendChild(E('p', { 'class': 'chfs-hint' }, _('No backups available.')));
		}
		else {
			var btb = E('tbody', {});

			baks.forEach(function(b) {
				var btn = E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-negative',
					'click': function(ev) {
						ev.preventDefault();
						return self.confirmDialog(
							_('Roll back to this backup?'),
							_('The running kernel will be replaced by this backup and the service will be restarted. The backup file itself is kept.'),
							_('Roll back'),
							function() {
								return self.runAction(
									callKernelRestore(b.name),
									_('Rolling back ...'),
									_('Rolled back'));
							});
					}
				}, _('Roll back'));

				btb.appendChild(E('tr', {}, [
					E('td', { 'class': 'chfs-mono' }, b.name),
					E('td', {}, fmtBytes(b.size)),
					E('td', {}, shaShort(b.sha256)),
					E('td', { 'class': 'chfs-col-action' }, E('div', { 'class': 'chfs-actions' }, [ btn ]))
				]));
			});

			bakCard.appendChild(E('table', { 'class': 'chfs-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Backup file')),
					E('th', {}, _('Size')),
					E('th', {}, _('SHA256')),
					E('th', { 'class': 'chfs-col-action' }, _('Actions'))
				])),
				btb
			]));
		}

		container.appendChild(bakCard);

		// ------------------------------------------------------------------
		// 安全提示与刷新
		// ------------------------------------------------------------------
		container.appendChild(E('div', { 'class': 'chfs-card' }, [
			E('h3', {}, _('Safety notes')),
			E('p', { 'class': 'chfs-note chfs-note-warn' },
				_('The kernel runs as root. Only install binaries from sources you trust; a binary that fails to start will leave the service down until it is rolled back.'))
		]));

		container.appendChild(E('div', { 'class': 'chfs-actions' }, [
			E('button', {
				'type': 'button',
				'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) {
					ev.preventDefault();
					location.reload();
				}
			}, _('Refresh'))
		]));

		return container;
	},

	// 探测下载源。单独触发, 避免拖慢首屏。
	handleDetectSources: function(box, btn) {
		var self = this;

		setBox(box, E('p', { 'class': 'chfs-note spinning' },
			_('Detecting download sources, please wait ...')));

		btn.disabled = true;

		return callKernelSources().then(function(res) {
			btn.disabled = false;

			if (!res || !res.ok) {
				setBox(box, E('p', { 'class': 'chfs-note chfs-note-warn' },
					(res && res.msg) || _('Detection failed')));

				return;
			}

			var tb = E('tbody', {});

			(res.sources || []).forEach(function(s) {
				var badge = s.available
					? E('span', { 'class': 'cbi-label label-success' }, _('Available'))
					: E('span', { 'class': 'cbi-label label-secondary' }, _('Unavailable'));

				var dlBtn = E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) {
						ev.preventDefault();
						return self.confirmDialog(
							_('Download this kernel?'),
							_('The file will be downloaded to the pending area. The running kernel is not touched until you click Install.'),
							_('Download'),
							function() {
								return self.runAction(
									callKernelDownload(s.url),
									_('Downloading kernel, this may take a while ...'),
									_('Download finished'));
							});
					}
				}, _('Download'));

				if (!s.available)
					dlBtn.disabled = true;

				tb.appendChild(E('tr', {}, [
					E('td', {}, s.name),
					E('td', { 'class': 'chfs-mono chfs-url-cell' }, s.url),
					E('td', {}, badge),
					E('td', { 'class': 'chfs-mono' }, s.http_code || '-'),
					E('td', { 'class': 'chfs-col-action' }, E('div', { 'class': 'chfs-actions' }, [ dlBtn ]))
				]));
			});

			var frag = E('div', {}, [
				E('p', { 'class': 'chfs-hint' },
					_('Transport used') + ': ' + (res.fetcher || '-')),
				E('table', { 'class': 'chfs-table' }, [
					E('thead', {}, E('tr', {}, [
						E('th', {}, _('Download source')),
						E('th', {}, _('URL')),
						E('th', {}, _('Status')),
						E('th', {}, _('HTTP code')),
						E('th', { 'class': 'chfs-col-action' }, _('Actions'))
					])),
					tb
				])
			]);

			setBox(box, frag);
		}).catch(function(e) {
			btn.disabled = false;
			setBox(box, E('p', { 'class': 'chfs-note chfs-note-warn' },
				_('Request failed') + ': ' + e));
		});
	},

	// 上传内核到待安装区。
	//
	// 走 LuCI 标准的 /cgi-bin/cgi-upload 端点, 参数与 luci-base 的 ui.FileUpload
	// 内部实现一致: sessionid + filename(完整绝对路径) + filedata。
	// cgi-upload 会按当前会话的 ACL 校验目标路径, 因此 acl.d 里必须有
	// /etc/luci-uploads/* 的 write 权限, 否则上传会被拒绝。
	handleUpload: function(file, btn) {
		var self = this;

		// 文件名消毒: 只保留安全字符, 防止路径穿越或非法名称写失败
		var safe = (file.name || 'chfs-upload').replace(/[^0-9A-Za-z._-]/g, '_');
		var target = UPLOAD_DIR + '/' + safe;

		var oldLabel = btn.textContent;

		var restore = function() {
			btn.disabled = false;
			btn.textContent = oldLabel;
		};

		btn.disabled = true;
		btn.textContent = '0%';

		return new Promise(function(resolve, reject) {
			var xhr = new XMLHttpRequest();
			var data = new FormData();

			data.append('sessionid', L.env.sessionid);
			data.append('filename', target);
			data.append('filedata', file);

			xhr.open('POST', (L.env.cgi_base || '/cgi-bin') + '/cgi-upload', true);

			xhr.upload.addEventListener('progress', function(ev) {
				if (ev.lengthComputable)
					btn.textContent = ((ev.loaded / ev.total) * 100).toFixed(1) + '%';
			});

			xhr.addEventListener('load', function() {
				var reply = null;

				try { reply = JSON.parse(xhr.responseText); } catch (e) { reply = null; }

				if (xhr.status !== 200)
					return reject(new Error('HTTP ' + xhr.status));

				if (reply && reply.failure)
					return reject(new Error(reply.failure));

				resolve(reply || {});
			});

			xhr.addEventListener('error', function() {
				reject(new Error(_('Network error')));
			});

			xhr.send(data);
		}).then(function() {
			restore();

			ui.addNotification(null,
				E('p', {}, _('Upload finished') + ': ' + target +
					' — ' + _('Review the pending list below and click Install to apply it.')), 'info');

			window.setTimeout(function() { location.reload(); }, 1500);
		}).catch(function(e) {
			restore();

			ui.addNotification(null,
				E('p', {}, _('Upload failed') + ': ' + (e && e.message ? e.message : e)), 'danger');
		});
	},

	// 统一的动作执行: 等待模态 -> 调用 -> 结果通知。
	// 成功时刷新页面以拉取真实状态; 失败时**不刷新**, 否则错误信息会被立即冲掉。
	runAction: function(promise, waitMsg, successMsg) {
		ui.showModal(_('Please wait'), [
			E('p', { 'class': 'spinning' }, waitMsg)
		]);

		return promise.then(function(res) {
			ui.hideModal();

			if (res && res.ok) {
				ui.addNotification(null,
					E('p', {}, successMsg + (res.msg ? ' — ' + res.msg : '')), 'info');

				window.setTimeout(function() { location.reload(); }, 1500);
			}
			else {
				ui.addNotification(null,
					E('p', {}, _('Operation failed') + ': ' + ((res && res.msg) || _('Unknown error'))),
					'danger');
			}
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Request failed') + ': ' + e), 'danger');
		});
	},

	// 确认对话框
	confirmDialog: function(title, message, confirmLabel, onConfirm) {
		var okBtn = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-negative',
			'click': function(ev) {
				ev.preventDefault();
				ui.hideModal();
				onConfirm();
			}
		}, confirmLabel || _('Confirm'));

		var cancelBtn = E('button', {
			'type': 'button',
			'class': 'btn',
			'click': function(ev) {
				ev.preventDefault();
				ui.hideModal();
			}
		}, _('Cancel'));

		ui.showModal(title, [
			E('p', {}, message),
			E('div', { 'class': 'right' }, [ cancelBtn, ' ', okBtn ])
		]);
	},

	// 本页不使用 UCI 表单, 置空以免渲染出无意义的保存/重置按钮
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
