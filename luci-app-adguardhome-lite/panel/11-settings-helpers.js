	function setSelectValue(id, value) {
		var el = $(id);
		if (!el) return;
		var found = false;
		for (var i = 0; i < el.options.length; i++) {
			if (el.options[i].value === value) {
				el.value = value;
				found = true;
				break;
			}
		}
		if (!found && value) {
			var opt = document.createElement('option');
			opt.value = value;
			opt.textContent = value;
			el.appendChild(opt);
			el.value = value;
		}
	}

	function pickedBypassIfaces() {
		var menu = $('agh-bypass-iface-menu');
		if (!menu) return '';
		return Array.prototype.slice.call(menu.querySelectorAll('input:checked'))
			.map(function (el) { return el.value; })
			.join(' ');
	}

	function updateBypassIfaceLabel() {
		var label = $('agh-bypass-iface-label');
		if (!label) return;
		var picked = pickedBypassIfaces().split(/\s+/).filter(Boolean);
		label.textContent = picked.length ? ('已排除：' + picked.join('、')) : '全部接管';
		label.title = picked.join(' ');
	}

	function renderBypassIfaces(devices, configured) {
		var menu = $('agh-bypass-iface-menu');
		if (!menu) return;
		var picked = (configured || '').split(/\s+/);
		var list = toList(devices).slice();
		picked.forEach(function (name) {
			if (name && list.indexOf(name) < 0) list.push(name);
		});
		menu.innerHTML = '';
		if (!list.length) {
			menu.textContent = '未检测到可用接口';
			updateBypassIfaceLabel();
			return;
		}
		list.sort();
		list.forEach(function (name) {
			var item = document.createElement('label');
			item.className = 'agh-option';
			var input = document.createElement('input');
			input.type = 'checkbox';
			input.value = name;
			input.checked = picked.indexOf(name) >= 0;
			input.addEventListener('change', updateBypassIfaceLabel);
			var text = document.createElement('span');
			text.textContent = name;
			item.appendChild(input);
			item.appendChild(text);
			menu.appendChild(item);
		});
		updateBypassIfaceLabel();
	}

	function applyUpstreamLocks() {
		var src = $('agh-set-upstream-source');
		var custom = $('agh-set-upstream-custom');
		var on = !!(src && src.value === 'custom');
		if (custom) {
			custom.disabled = !on;
		}
		var field = $('agh-upstream-custom-field');
		if (field) {
			// 自动模式下这一栏没有作用，直接隐藏，避免空白大输入框占位
			field.hidden = !on;
		}

		// 接管 53 模式下 AGH 的上游就是本机 DNSMasq(1745)，
		// 换成公网上游会丢掉路由器/DHCP 主机名的本地解析，必须提示。
		var note = $('agh-upstream-lan-note');
		if (note) {
			var modeEl = $('agh-set-dns-mode');
			var modeVal = modeEl ? modeEl.value : '';
			var show = on && (modeVal === 'takeover' || modeVal === 'passwall');
			note.hidden = !show;
			if (!show) {
				note.textContent = '';
			} else if (modeVal === 'passwall') {
				note.textContent = '当前是「PassWall 前置」：自定义上游会绕过 PassWall 的 DNS，国内外分流将失效；需要分流时请把来源保持为「自动」。';
			} else {
				note.textContent = '当前是「接管 53 端口」：自定义上游会绕过本机 DNSMasq(1745)，路由器与 DHCP 主机名（如 xxx.lan）将无法解析。需要保留本地解析时，请在列表末尾加上 127.0.0.1:1745。';
			}
		}
	}

	function applyCacheLocks() {
		var enabled = $('agh-set-cache-enabled');
		var on = !!(enabled && enabled.checked);
		var fields = $('agh-cache-fields');
		if (fields) {
			fields.classList.toggle('is-locked', !on);
			Array.prototype.slice.call(fields.querySelectorAll('input, select')).forEach(function (el) {
				el.disabled = !on;
			});
		}
		var optimistic = $('agh-set-cache-optimistic');
		if (optimistic) optimistic.disabled = !on;
	}

	function applyCryptoLocks() {
		var sel = $('agh-set-dns-crypto');
		var value = sel ? sel.value : 'off';
		var customWrap = $('agh-crypto-custom-wrap');
		if (customWrap) customWrap.hidden = value !== 'custom';

		var modeEl = $('agh-set-dns-mode');
		var mode = modeEl ? modeEl.value : '';
		var on = mode === 'clashfirst';
		var fields = $('agh-crypto-fields');
		if (fields) {
			fields.classList.toggle('is-locked', !on);
			Array.prototype.slice.call(fields.querySelectorAll('input, select, button')).forEach(function (el) {
				el.disabled = !on;
			});
		}

		var note = $('agh-crypto-mode-note');
		if (!note) return;
		// 自定义上游时右列已经有输入框，再叠加提示会显得拥挤，直接不显示
		var text = '';
		if (value !== 'custom') {
			if (!on) {
				text = '需切换到「Clash 前置」后才能使用。';
			} else if (value !== 'off' && state.cryptoBlocked) {
				text = '检测到自定义上游 DNS，加密预设不会生效；请在「DNS 解析 → 上游 DNS」把来源改回「自动」。';
			}
		}
		note.textContent = text;
		note.style.display = text ? '' : 'none';

		// 锁定时保存按钮一并禁用，避免点了没有反应
		var saveBtn = $('agh-save-crypto-btn');
		if (saveBtn) {
			saveBtn.disabled = !on;
			saveBtn.title = on ? '' : '当前接管方式不是「Clash 前置」，无法保存加密上游';
		}
	}

