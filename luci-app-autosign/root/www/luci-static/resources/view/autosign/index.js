'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';

// ==================== 智能抓包 / cURL 解析引擎 ====================
function tokenizeArgs(cmdStr) {
	var tokens = [];
	var current = '';
	var inSingle = false;
	var inDouble = false;
	var escaped = false;

	var cleaned = cmdStr.replace(/\\[\r\n]+/g, ' ')
	                    .replace(/\^[\r\n]+/g, ' ')
	                    .replace(/`[\r\n]+/g, ' ');

	for (var i = 0; i < cleaned.length; i++) {
		var ch = cleaned[i];

		if (escaped) {
			current += ch;
			escaped = false;
			continue;
		}

		if (ch === '\\' && !inSingle) {
			escaped = true;
			continue;
		}

		if (ch === "'" && !inDouble) {
			inSingle = !inSingle;
			continue;
		}

		if (ch === '"' && !inSingle) {
			inDouble = !inDouble;
			continue;
		}

		if ((ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n') && !inSingle && !inDouble) {
			if (current.length > 0) {
				tokens.push(current);
				current = '';
			}
			continue;
		}

		current += ch;
	}

	if (current.length > 0) {
		tokens.push(current);
	}

	return tokens;
}

function parseRawHttp(rawText) {
	var trimmed = rawText.trim();
	var firstLineEnd = trimmed.indexOf('\n');
	if (firstLineEnd === -1) return null;

	var firstLine = trimmed.substring(0, firstLineEnd).trim();
	var reqLineMatch = firstLine.match(/^(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)\s+([^\s]+)\s+HTTP\/[0-9.]+/i);
	if (!reqLineMatch) return null;

	var method = reqLineMatch[1].toUpperCase();
	var reqPath = reqLineMatch[2];

	var rest = trimmed.substring(firstLineEnd + 1);
	var parts = rest.split(/\r?\n\r?\n/);
	var headerBlock = parts[0] || '';
	var bodyBlock = parts.length > 1 ? parts.slice(1).join('\n\n').trim() : '';

	var headers = [];
	var cookie = '';
	var host = '';

	var headerLines = headerBlock.split(/\r?\n/);
	for (var i = 0; i < headerLines.length; i++) {
		var line = headerLines[i].trim();
		if (!line) continue;
		var colonIdx = line.indexOf(':');
		if (colonIdx <= 0) continue;

		var hName = line.substring(0, colonIdx).trim();
		var hVal = line.substring(colonIdx + 1).trim();
		var lowerH = hName.toLowerCase();

		if (lowerH === 'host') {
			host = hVal;
		} else if (lowerH === 'cookie') {
			cookie = hVal;
		} else if (lowerH === 'content-length' || lowerH === 'authority' || lowerH === ':authority') {
			continue;
		} else {
			headers.push(hName + ': ' + hVal);
		}
	}

	var fullUrl = reqPath;
	if (!reqPath.startsWith('http://') && !reqPath.startsWith('https://')) {
		fullUrl = 'https://' + (host ? host : 'example.com') + reqPath;
	}

	return {
		method: method,
		url: fullUrl,
		headers: headers,
		cookie: cookie,
		data: bodyBlock
	};
}

function parseCurl(rawText) {
	var raw = rawText.trim();

	// 1. 尝试直接作为原生 HTTP 请求报文解析
	var httpRes = parseRawHttp(raw);
	if (httpRes) {
		return httpRes;
	}

	// 2. 截取从 curl 关键字开始的命令行
	var curlIdx = raw.indexOf('curl');
	if (curlIdx !== -1) {
		raw = raw.substring(curlIdx);
	}

	var tokens = tokenizeArgs(raw);
	var method = '';
	var url = '';
	var headers = [];
	var cookie = '';
	var data = '';

	function handleHeaderToken(hStr) {
		if (!hStr) return;
		var colonIdx = hStr.indexOf(':');
		if (colonIdx <= 0) return;
		var name = hStr.substring(0, colonIdx).trim();
		var val = hStr.substring(colonIdx + 1).trim();
		var lower = name.toLowerCase();

		if (lower.startsWith(':') || lower === 'content-length' || lower === 'authority' || lower === 'host') {
			return;
		}

		if (lower === 'cookie') {
			cookie = val;
		} else {
			headers.push(name + ': ' + val);
		}
	}

	for (var i = 0; i < tokens.length; i++) {
		var tok = tokens[i];
		if (tok === 'curl' || tok === 'curl.exe') continue;

		if (tok === '-X' || tok === '--request') {
			if (i + 1 < tokens.length) {
				method = tokens[++i].toUpperCase();
			}
			continue;
		}
		if (tok.startsWith('-X') && tok.length > 2) {
			method = tok.substring(2).toUpperCase();
			continue;
		}

		if (tok === '-H' || tok === '--header') {
			if (i + 1 < tokens.length) {
				handleHeaderToken(tokens[++i]);
			}
			continue;
		}
		if (tok.startsWith('-H') && tok.length > 2) {
			handleHeaderToken(tok.substring(2));
			continue;
		}

		if (tok === '-b' || tok === '--cookie') {
			if (i + 1 < tokens.length) {
				cookie = tokens[++i];
			}
			continue;
		}
		if (tok.startsWith('-b') && tok.length > 2) {
			cookie = tok.substring(2);
			continue;
		}

		if (tok === '-d' || tok === '--data' || tok === '--data-raw' || tok === '--data-binary' || tok === '--data-ascii' || tok === '--data-urlencode') {
			if (i + 1 < tokens.length) {
				var d = tokens[++i];
				data = data ? (data + '&' + d) : d;
			}
			continue;
		}
		if (tok.startsWith('-d') && tok.length > 2) {
			var d2 = tok.substring(2);
			data = data ? (data + '&' + d2) : d2;
			continue;
		}

		if (tok === '--url') {
			if (i + 1 < tokens.length) {
				url = tokens[++i];
			}
			continue;
		}

		if (tok === '--compressed' || tok === '-k' || tok === '--insecure' || tok === '-s' || tok === '--silent' || tok === '-L' || tok === '--location' || tok === '-i' || tok === '-v') {
			continue;
		}

		if (!tok.startsWith('-')) {
			if (!url && (tok.startsWith('http://') || tok.startsWith('https://') || tok.indexOf('.') !== -1)) {
				url = tok;
			}
		}
	}

	if (!method) {
		method = data ? 'POST' : 'GET';
	}

	if (url && !url.startsWith('http://') && !url.startsWith('https://')) {
		url = 'https://' + url;
	}

	return {
		method: method,
		url: url,
		headers: headers,
		cookie: cookie,
		data: data
	};
}

function suggestTaskName(urlStr) {
	if (!urlStr) return '智能导入任务';
	try {
		var u = new URL(urlStr);
		var host = u.hostname.toLowerCase();
		if (host.indexOf('baidu.com') !== -1 || host.indexOf('tieba') !== -1) return '百度贴吧签到';
		if (host.indexOf('bilibili.com') !== -1) return '哔哩哔哩签到';
		if (host.indexOf('jd.com') !== -1) return '京东每日签到';
		if (host.indexOf('aliyun.com') !== -1) return '阿里云盘签到';
		if (host.indexOf('v2ex.com') !== -1) return 'V2EX每日签到';
		if (host.indexOf('smzdm.com') !== -1) return '什么值得买签到';
		if (host.indexOf('glados') !== -1) return 'GLaDOS签到';
		if (host.indexOf('qq.com') !== -1 || host.indexOf('tencent.com') !== -1) return '腾讯服务签到';
		if (host.indexOf('163.com') !== -1) return '网易云/网易签到';
		if (host.indexOf('weibo.com') !== -1) return '微博签到';
		if (host.indexOf('zhihu.com') !== -1) return '知乎签到';
		if (host.indexOf('github.com') !== -1) return 'GitHub任务';

		var parts = host.split('.');
		if (parts.length >= 2) {
			var domainName = parts[parts.length - 2];
			return domainName + ' 自动签到';
		}
		return host + ' 自动签到';
	} catch (e) {
		return '智能导入任务';
	}
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('autosign'),
			fs.read('/var/log/autosign.log').catch(function() { return ''; })
		]);
	},

	render: function(data) {
		var initial_log = data[1] || '暂无运行日志。可在下方点击【⚡ 立即执行签到测试】运行测试。';

		var m = new form.Map('autosign', _('定时自动签到'),
			_('超轻量级 OpenWrt 定时自动签到插件。支持每日定时调度、随机防风控延迟、多任务 HTTP/脚本混合配置以及微信/Telegram 推送。'));

		// ==================== 1. 基本与定时设置 ====================
		var s_gen = m.section(form.NamedSection, 'global', 'autosign', _('基本与全局设置'));
		s_gen.anonymous = true;
		s_gen.addremove = false;

		var o;

		o = s_gen.option(form.Flag, 'enabled', _('启用定时签到总开关'), _('总开关：开启后，各签到任务将在各自设定的时间独立自动运行。每个任务的具体执行时间请在下方任务列表中直接选择。'));
		o.rmempty = false;

		o = s_gen.option(form.Value, 'random_delay', _('防封随机延迟 (秒)'), _('在指定签到时间到达后，随机休眠 0 ~ N 秒再执行，防止每天固定时间被检测。设为 0 表示立即执行'));
		o.datatype = 'range(0, 3600)';
		o.placeholder = '0';
		o.default = '0';

		o = s_gen.option(form.Value, 'retry_count', _('失败重试次数'), _('当网络波动或接口请求失败时的自动重试次数'));
		o.datatype = 'range(1, 10)';
		o.placeholder = '3';
		o.default = '3';

		o = s_gen.option(form.Value, 'retry_interval', _('重试间隔 (秒)'), _('每次重试之间的等待间隔时间'));
		o.datatype = 'range(1, 600)';
		o.placeholder = '60';
		o.default = '60';

		// ==================== 2. 签到任务管理 ====================
		var s_tasks = m.section(form.GridSection, 'task', _('签到任务管理'), _('支持配置多个不同的签到任务。每个任务均可在此直接点击下拉菜单设置独立的【执行小时】和【执行分钟】（如 08点 30分、12点 00分），彼此完全独立。点击右侧【修改】可编辑接口 URL 或脚本命令。'));
		s_tasks.addremove = true;
		s_tasks.anonymous = true;
		s_tasks.sortable = true;

		// 弹窗智能导入函数
		var showSmartImportModal = function() {
			var textarea = E('textarea', {
				'class': 'cbi-input-textarea',
				'style': 'width: 100%; min-height: 140px; font-family: Consolas, Monaco, monospace; font-size: 12px; line-height: 1.4; padding: 8px; box-sizing: border-box; resize: vertical;',
				'placeholder': "在此粘贴浏览器 F12 复制的 cURL 命令或原始 HTTP 报文，例如：\n\ncurl 'https://tieba.baidu.com/c/s/sign' \\\n  -H 'Cookie: BDUSS=xxxxxx;' \\\n  --data-raw 'kw=xxx&tbs=yyy'"
			});

			var inputName = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'style': 'width: 100%;',
				'placeholder': _('自动识别，也可自定义输入（如：每日贴吧签到）')
			});

			var selectHour = E('select', {
				'class': 'cbi-input-select',
				'style': 'width: 110px; margin-right: 8px;'
			});
			for (var h = 0; h < 24; h++) {
				var hStr = (h < 10 ? '0' : '') + h;
				var opt = E('option', { 'value': hStr }, [ hStr + ' 点' ]);
				if (hStr === '08') opt.selected = true;
				selectHour.appendChild(opt);
			}

			var selectMinute = E('select', {
				'class': 'cbi-input-select',
				'style': 'width: 110px;'
			});
			for (var mIdx = 0; mIdx < 60; mIdx++) {
				var mStr = (mIdx < 10 ? '0' : '') + mIdx;
				var optM = E('option', { 'value': mStr }, [ mStr + ' 分' ]);
				if (mStr === '30') optM.selected = true;
				selectMinute.appendChild(optM);
			}

			var previewCard = E('div', {
				'style': 'margin-top: 14px; padding: 12px; background: rgba(125, 125, 125, 0.08); border: 1px dashed rgba(125, 125, 125, 0.3); border-radius: 6px; font-size: 13px; line-height: 1.6;'
			}, [
				E('div', { 'style': 'color: #888; font-style: italic;' }, [
					_('💡 暂无解析内容。请在上方输入框粘贴 cURL 或 HTTP 报文，系统将自动识别解析。')
				])
			]);

			var btnSubmit = E('button', {
				'class': 'cbi-button cbi-button-action',
				'disabled': true,
				'style': 'margin-right: 10px; font-weight: bold;'
			}, [ '✅ ' + _('解析并添加任务') ]);

			var btnCancel = E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, [ _('取消') ]);

			var doParseAndUpdate = function() {
				var text = textarea.value.trim();
				if (!text) {
					previewCard.innerHTML = '';
					previewCard.appendChild(E('div', { 'style': 'color: #888; font-style: italic;' }, [
						_('💡 暂无解析内容。请在上方输入框粘贴 cURL 或 HTTP 报文，系统将自动识别解析。')
					]));
					btnSubmit.disabled = true;
					return;
				}

				var parsed = parseCurl(text);
				if (!parsed || !parsed.url) {
					previewCard.innerHTML = '';
					previewCard.appendChild(E('div', { 'style': 'color: #ef4444; font-weight: bold;' }, [
						'⚠️ ' + _('未能解析出目标 URL，请检查粘贴的内容是否完整（需包含有效网址）')
					]));
					btnSubmit.disabled = true;
					return;
				}

				btnSubmit.disabled = false;
				if (!inputName.value || inputName.dataset.autoFilled === 'true') {
					inputName.value = suggestTaskName(parsed.url);
					inputName.dataset.autoFilled = 'true';
				}

				previewCard.innerHTML = '';
				var items = [
					E('div', { 'style': 'font-weight: bold; color: #10b981; margin-bottom: 6px;' }, [
						'🎉 ' + _('解析成功！已自动识别关键请求要素：')
					]),
					E('div', {}, [
						E('span', { 'style': 'font-weight: bold;' }, [ _('请求方式: ') ]),
						E('span', { 'class': 'badge', 'style': 'background: #2563eb; color: #fff; padding: 2px 7px; border-radius: 4px; font-weight: bold; font-size: 11px;' }, [ parsed.method ]),
						E('span', { 'style': 'font-weight: bold; margin-left: 12px;' }, [ _('目标 URL: ') ]),
						E('span', { 'style': 'word-break: break-all; color: #0284c7; font-family: monospace;' }, [ parsed.url ])
					])
				];

				if (parsed.cookie) {
					var cShow = parsed.cookie.length > 70 ? (parsed.cookie.substring(0, 70) + '...') : parsed.cookie;
					items.push(E('div', { 'style': 'margin-top: 4px;' }, [
						E('span', { 'style': 'font-weight: bold;' }, [ _('Cookie 凭据: ') ]),
						E('span', { 'style': 'color: #059669; font-family: monospace; word-break: break-all;' }, [ cShow + ' (' + parsed.cookie.length + ' 字符)' ])
					]));
				}

				if (parsed.headers && parsed.headers.length > 0) {
					items.push(E('div', { 'style': 'margin-top: 4px;' }, [
						E('span', { 'style': 'font-weight: bold;' }, [ _('请求头 (Headers): ') ]),
						E('span', { 'style': 'color: #64748b;' }, [ _('已提取 %d 行有效 Headers (已自动排除冗余首部)').format(parsed.headers.length) ])
					]));
				}

				if (parsed.data) {
					var dShow = parsed.data.length > 80 ? (parsed.data.substring(0, 80) + '...') : parsed.data;
					items.push(E('div', { 'style': 'margin-top: 4px;' }, [
						E('span', { 'style': 'font-weight: bold;' }, [ _('请求载荷 (Body): ') ]),
						E('span', { 'style': 'color: #9333ea; font-family: monospace; word-break: break-all;' }, [ dShow ])
					]));
				}

				items.forEach(function(el) { previewCard.appendChild(el); });
			};

			textarea.addEventListener('input', doParseAndUpdate);
			textarea.addEventListener('change', doParseAndUpdate);
			inputName.addEventListener('input', function() {
				inputName.dataset.autoFilled = 'false';
			});

			btnSubmit.addEventListener('click', function(ev) {
				ev.preventDefault();
				var text = textarea.value.trim();
				var parsed = parseCurl(text);
				if (!parsed || !parsed.url) {
					ui.addNotification(null, E('p', _('请先粘贴包含有效 URL 的 cURL 或 HTTP 报文！')), 'warning');
					return;
				}

				var taskName = inputName.value.trim() || suggestTaskName(parsed.url);
				var taskHour = selectHour.value;
				var taskMin = selectMinute.value;

				ui.showModal(_('正在导入任务...'), [
					E('p', { 'class': 'spinning' }, _('正在添加新任务到配置，请稍候...'))
				]);

				var savePromise = m.save ? Promise.resolve(m.save()).catch(function() { return true; }) : Promise.resolve();

				savePromise.then(function() {
					var sid = uci.add('autosign', 'task');
					uci.set('autosign', sid, 'enabled', '1');
					uci.set('autosign', sid, 'name', taskName);
					uci.set('autosign', sid, 'run_hour', taskHour);
					uci.set('autosign', sid, 'run_minute', taskMin);
					uci.set('autosign', sid, 'type', 'http');
					uci.set('autosign', sid, 'method', parsed.method || 'GET');
					uci.set('autosign', sid, 'url', parsed.url || '');
					if (parsed.headers && parsed.headers.length > 0) {
						uci.set('autosign', sid, 'headers', parsed.headers.join('\n'));
					}
					if (parsed.cookie) {
						uci.set('autosign', sid, 'cookie', parsed.cookie);
					}
					if (parsed.data) {
						uci.set('autosign', sid, 'data', parsed.data);
					}
					return uci.save();
				}).then(function() {
					ui.hideModal();
					ui.addNotification(null, E('p', _('任务【%s】已成功导入！请核对并点击页面右下角的【保存并应用】。').format(taskName)), 'info');
					window.location.reload();
				}).catch(function(err) {
					ui.hideModal();
					ui.addNotification(null, E('p', _('导入失败: ') + (err.message || err)), 'error');
				});
			});

			var modalContent = E('div', { 'style': 'font-size: 13px;' }, [
				E('div', {
					'style': 'padding: 10px 14px; margin-bottom: 12px; background: rgba(59, 130, 246, 0.1); border-left: 4px solid #3b82f6; border-radius: 4px; line-height: 1.6;'
				}, [
					E('strong', {}, [ _('使用提示：') ]),
					E('span', {}, [ _('在浏览器 (Edge/Chrome/Firefox) 中按 F12 打开【网络 (Network)】面板，找到签到或打卡的请求，右键选择【复制】->【复制为 cURL (bash / cmd / PowerShell)】或【复制请求报文】，直接粘贴到下方即可智能自动提取所有参数！') ])
				]),

				E('div', { 'style': 'margin-bottom: 10px;' }, [
					E('label', { 'style': 'display: block; font-weight: bold; margin-bottom: 4px;' }, [ _('抓包报文 / cURL 命令 (*):') ]),
					textarea
				]),

				E('div', { 'style': 'display: flex; gap: 16px; margin-bottom: 10px; flex-wrap: wrap;' }, [
					E('div', { 'style': 'flex: 2; min-width: 200px;' }, [
						E('label', { 'style': 'display: block; font-weight: bold; margin-bottom: 4px;' }, [ _('任务名称:') ]),
						inputName
					]),
					E('div', { 'style': 'flex: 1; min-width: 220px;' }, [
						E('label', { 'style': 'display: block; font-weight: bold; margin-bottom: 4px;' }, [ _('独立定时执行时间:') ]),
						E('div', { 'style': 'display: flex; align-items: center;' }, [
							selectHour,
							selectMinute
						])
					])
				]),

				previewCard,

				E('div', { 'style': 'text-align: right; margin-top: 16px;' }, [
					btnCancel,
					btnSubmit
				])
			]);

			ui.showModal(_('📋 智能导入抓包 / cURL 一键填单'), [ modalContent ]);
		};

		// 包装 GridSection 渲染，在表格上方加入【智能导入】按钮
		var orig_render_tasks = s_tasks.render;
		s_tasks.render = function() {
			var res = orig_render_tasks.apply(this, arguments);
			var makeContainer = function(node) {
				var importBtn = E('button', {
					'class': 'cbi-button cbi-button-action',
					'style': 'margin-bottom: 10px; margin-right: 10px; font-weight: bold;',
					'click': function(ev) {
						ev.preventDefault();
						showSmartImportModal();
					}
				}, [ '📋 ' + _('智能导入抓包 / cURL 一键填单') ]);

				if (node && node.querySelector) {
					var targetNode = node.querySelector('.cbi-section-node') || node.querySelector('table') || node.firstChild;
					if (targetNode && targetNode.parentNode) {
						targetNode.parentNode.insertBefore(E('div', { 'style': 'margin: 10px 0;' }, [ importBtn ]), targetNode);
						return node;
					}
				}

				return E('div', {}, [
					E('div', { 'style': 'margin: 10px 0;' }, [ importBtn ]),
					node
				]);
			};

			if (res instanceof Promise) {
				return res.then(makeContainer);
			} else {
				return makeContainer(res);
			}
		};

		o = s_tasks.option(form.Flag, 'enabled', _('启用'));
		o.rmempty = false;
		o.default = '1';
		o.editable = true;

		o = s_tasks.option(form.Value, 'name', _('任务名称'));
		o.rmempty = false;
		o.placeholder = '如：每日打卡';
		o.editable = true;

		// 独立定时时间 - 直接在表格中可选择
		o = s_tasks.option(form.ListValue, 'run_hour', _('执行小时'));
		for (var h = 0; h < 24; h++) {
			var val = (h < 10 ? '0' : '') + h;
			o.value(val, val + ' 点');
		}
		o.default = '08';
		o.rmempty = false;
		o.editable = true;

		o = s_tasks.option(form.ListValue, 'run_minute', _('执行分钟'));
		for (var min = 0; min < 60; min++) {
			var val_min = (min < 10 ? '0' : '') + min;
			o.value(val_min, val_min + ' 分');
		}
		o.default = '30';
		o.rmempty = false;
		o.editable = true;

		o = s_tasks.option(form.ListValue, 'type', _('任务类型'));
		o.value('http', _('HTTP(S) 请求'));
		o.value('script', _('自定义脚本/命令'));
		o.default = 'http';
		o.editable = true;



		// 弹窗编辑详细配置
		o = s_tasks.option(form.ListValue, 'method', _('请求方式'));
		o.value('GET', 'GET');
		o.value('POST', 'POST');
		o.value('PUT', 'PUT');
		o.default = 'POST';
		o.depends('type', 'http');
		o.modalonly = true;

		o = s_tasks.option(form.Value, 'url', _('接口 URL'));
		o.placeholder = 'https://example.com/api/checkin';
		o.depends('type', 'http');
		o.modalonly = true;

		o = s_tasks.option(form.TextValue, 'headers', _('自定义请求头 (Headers)'), _('每行一个 Header，例如：<br><code>User-Agent: Mozilla/5.0</code><br><code>Content-Type: application/json</code>'));
		o.placeholder = 'User-Agent: Mozilla/5.0';
		o.rows = 3;
		o.depends('type', 'http');
		o.modalonly = true;

		o = s_tasks.option(form.TextValue, 'cookie', _('Cookie 数据'), _('若接口需要登录鉴权，在此粘贴完整 Cookie 字符串'));
		o.placeholder = 'session=xxxx; token=yyyy';
		o.rows = 2;
		o.depends('type', 'http');
		o.modalonly = true;

		o = s_tasks.option(form.TextValue, 'data', _('POST/PUT 请求内容 (Body)'), _('JSON 报文或表单数据'));
		o.placeholder = '{"action":"sign"}';
		o.rows = 3;
		o.depends('type', 'http');
		o.modalonly = true;

		o = s_tasks.option(form.Value, 'match_keyword', _('成功判定关键词'), _('若返回内容中包含此文字则视为签到成功。留空则只依据 HTTP 200 状态码判定'));
		o.placeholder = '如: success 或 "code":0';
		o.depends('type', 'http');
		o.modalonly = true;

		o = s_tasks.option(form.Value, 'script_cmd', _('自定义脚本命令或路径'), _('填入可执行命令或脚本路径（如 <code>/etc/autosign/login.sh</code>），退出码为 0 代表执行成功'));
		o.placeholder = '/usr/bin/python3 /root/checkin.py 或 bash /etc/autosign/task.sh';
		o.depends('type', 'script');
		o.modalonly = true;

		// ==================== 3. 消息通知设置 ====================
		var s_notify = m.section(form.NamedSection, 'global', 'autosign', _('消息推送设置'));
		s_notify.anonymous = true;
		s_notify.addremove = false;

		o = s_notify.option(form.ListValue, 'notify_type', _('通知渠道'));
		o.value('none', _('关闭通知'));
		o.value('pushplus', _('PushPlus (微信消息推送)'));
		o.value('serverchan', _('Server酱·Turbo (微信/企业微信)'));
		o.value('telegram', _('Telegram 机器人'));
		o.value('bark', _('Bark (iOS 极速通知)'));
		o.value('webhook', _('自定义 Webhook (POST JSON)'));
		o.default = 'none';

		o = s_notify.option(form.Value, 'notify_token', _('Token / Key / URL'), _('填写所选通知渠道的 Token、SendKey 或 Webhook 完整 URL'));
		o.depends('notify_type', 'pushplus');
		o.depends('notify_type', 'serverchan');
		o.depends('notify_type', 'telegram');
		o.depends('notify_type', 'bark');
		o.depends('notify_type', 'webhook');

		o = s_notify.option(form.Value, 'notify_secret', _('Chat ID (Telegram 专用)'), _('接收消息的 Telegram 用户 ID 或群组 ID'));
		o.depends('notify_type', 'telegram');

		// ==================== 4. 运行日志与即时测试 ====================
		var s_log = m.section(form.NamedSection, 'global', 'autosign', _('运行日志与即时测试'));
		s_log.anonymous = true;
		s_log.addremove = false;

		var log_box = E('pre', {
			'id': 'autosign_log_view',
			'style': 'background:#181818;color:#00ff66;padding:12px 16px;border-radius:6px;font-family:Consolas,Monaco,monospace;font-size:12px;line-height:1.5;max-height:450px;overflow-y:auto;white-space:pre-wrap;word-break:break-all;box-shadow:inset 0 0 10px rgba(0,0,0,0.5);'
		}, [ initial_log ]);

		var update_log_content = function() {
			return fs.read('/var/log/autosign.log').then(function(content) {
				log_box.textContent = content || '暂无运行记录。';
				log_box.scrollTop = log_box.scrollHeight;
			}).catch(function() {
				log_box.textContent = '暂无运行记录。';
			});
		};

		var btn_run_now = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-right:10px;',
			'click': function(ev) {
				ev.preventDefault();
				ui.showModal(_('正在执行签到...'), [
					E('p', { 'class': 'spinning' }, _('正在运行签到任务引擎，请稍候...'))
				]);

				fs.exec('/usr/share/autosign/autosign.sh', ['run', 'force']).then(function(res) {
					ui.hideModal();
					update_log_content();
					ui.addNotification(null, E('p', _('签到任务执行完毕！请在日志窗口查看详细结果。')), 'info');
				}).catch(function(err) {
					ui.hideModal();
					ui.addNotification(null, E('p', _('执行出错: ') + (err.message || err)), 'error');
				});
			}
		}, [ '⚡ ' + _('立即测试全部任务') ]);

		var btn_refresh_log = E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'style': 'margin-right:10px;',
			'click': function(ev) {
				ev.preventDefault();
				update_log_content();
			}
		}, [ '🔄 ' + _('刷新日志') ]);

		var btn_clear_log = E('button', {
			'class': 'cbi-button cbi-button-remove',
			'click': function(ev) {
				ev.preventDefault();
				fs.exec('/usr/share/autosign/autosign.sh', ['clearlog']).then(function() {
					update_log_content();
					ui.addNotification(null, E('p', _('日志已清空')), 'info');
				});
			}
		}, [ '🗑️ ' + _('清空日志') ]);

		var toolbar = E('div', { 'style': 'margin: 12px 0;' }, [
			btn_run_now,
			btn_refresh_log,
			btn_clear_log
		]);

		var custom_log_field = s_log.option(form.DummyValue, '_logview');
		custom_log_field.render = function() {
			return E('div', {}, [
				toolbar,
				log_box
			]);
		};

		// 监听配置保存应用事件，自动同步系统 Crontab
		document.addEventListener('uci-applied', function() {
			fs.exec('/etc/init.d/autosign', ['reload']);
		});

		return m.render();
	}
});
