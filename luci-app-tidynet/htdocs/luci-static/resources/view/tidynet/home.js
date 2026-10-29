"use strict";
"require view";
"require rpc";
"require ui";

if (!document.getElementById("tidynet-style")) {
	var style = document.createElement("link");
	style.id = "tidynet-style";
	style.rel = "stylesheet";
	style.href = L.resource("view/tidynet/home.css") + "?v=0.4.0-r37";
	document.head.appendChild(style);
}

var callStatus = rpc.declare({ object: "tidynet", method: "status", expect: {} });
var callSettings = rpc.declare({ object: "tidynet", method: "settings", expect: {} });
var callStats = rpc.declare({ object: "tidynet", method: "stats", expect: {} });
var callProxyStatus = rpc.declare({ object: "tidynet", method: "proxy_status", expect: {} });
var callProxyProbe = rpc.declare({ object: "tidynet", method: "proxy_probe", params: [ "target" ], expect: {} });
var callProxyNodeDelay = rpc.declare({ object: "tidynet", method: "proxy_node_delay", params: [ "group", "member" ], expect: {} });
var callProxySelect = rpc.declare({ object: "tidynet", method: "proxy_select", params: [ "group", "member" ], expect: {} });
var callConfigure = rpc.declare({ object: "tidynet", method: "configure", params: [ "payload" ], expect: {} });
var callAction = rpc.declare({ object: "tidynet", method: "action", params: [ "operation", "section" ], expect: {} });
var callResolve = rpc.declare({ object: "tidynet", method: "resolve", params: [ "domain" ], expect: {} });
var pollTimer = null;
var pollView = null;

function isTrue(value) {
	return value === true || value === 1 || value === "1" || value === "true";
}

function boolAttr(value) {
	return !!value;
}

function removeFalseAttr(attrs, key) {
	if (attrs[key] === false || attrs[key] == null) delete attrs[key];
	return attrs;
}

function mkButton(attrs, children) {
	return E("button", removeFalseAttr(attrs, "disabled"), children);
}

function mkOption(attrs, children) {
	return E("option", removeFalseAttr(attrs, "selected"), children);
}

function mkSelect(attrs, children) {
	return E("select", removeFalseAttr(attrs, "disabled"), children);
}

return view.extend({
	load: function() {
		this.connectivityResults = {};
		try {
			var saved = JSON.parse(window.localStorage.getItem("tidynet.connectivity.v1") || "{}");
			[ "google", "openai", "aliyun" ].forEach(function(target) {
				var item = saved[target];
				if (item && typeof item.ok === "boolean" && (!item.ok || (typeof item.delay === "number" && isFinite(item.delay) && item.delay >= 0))) this.connectivityResults[target] = item;
			}, this);
		} catch (e) { /* Storage may be unavailable in private browsing. */ }
		this.nodeDelayResults = {};
		this.nodeDelayBusy = {};
		this.nodeOptimizeBusy = {};
		this.nodeOptimizeProgress = {};
		this.connectivityBusy = false;
		return Promise.all([
			callStatus().catch(function() { return { error: "无法连接 TidyNet 服务" }; }),
			callSettings().catch(function() { return {}; }),
			callStats().catch(function() { return { connected: false }; }),
			callProxyStatus().catch(function() { return { connected: false }; })
		]).then(function(result) { return { status: result[0] || {}, settings: result[1] || {}, stats: result[2] || {}, proxies: result[3] || { connected: false } }; });
	},

	notify: function(message, isError) {
		ui.addNotification(null, E("p", {}, [ message || (isError ? "操作失败" : "已完成") ]), isError ? "error" : "info");
	},

	action: function(operation, section) {
		var self = this;
		return callAction(operation, section || "").then(function(result) {
			if (!result || !result.ok) { self.notify(result && result.error, true); return; }
			self.notify(result.message || "任务已提交");
			self.refresh();
		}).catch(function() { self.notify("路由器没有响应，请检查连接", true); });
	},

	configure: function(payload) {
		var self = this;
		return callConfigure(JSON.stringify(payload)).then(function(result) {
			if (!result || !result.ok) { self.notify(result && result.error, true); return; }
			self.notify(result.message || "设置已保存");
			if (result.accepted) window.setTimeout(function() { self.refresh(); }, 1000);
			else self.refresh();
			return result;
		}).catch(function() { self.notify("保存失败：路由器没有响应", true); });
	},

	refresh: function() {
		var self = this;
		if (this.connectivityBusy) return Promise.resolve();
		if (this.refreshPending) return this.refreshPending;
		this.lastRefreshFailures = 0;
		this.refreshPending = Promise.all([
			callStatus().catch(function() { self.lastRefreshFailures++; return self.data.status; }),
			callSettings().catch(function() { self.lastRefreshFailures++; return self.data.settings; }),
			callStats().catch(function() { self.lastRefreshFailures++; return self.data.stats; }),
			callProxyStatus().catch(function() { self.lastRefreshFailures++; return self.data.proxies || { connected: false }; })
		]).then(function(result) {
			if (pollView !== self || !document.querySelector(".tidynet")) return;
			if (self.connectivityBusy) return;
			var active = document.activeElement;
			if (Array.prototype.some.call(document.querySelectorAll(".modal"), function(el) { return el.getClientRects().length > 0; }) || (active && active.closest && active.closest(".tidynet") && /^(SELECT|INPUT|TEXTAREA)$/.test(active.tagName))) return;
			var signature = JSON.stringify([ result, self.connectivityResults, self.connectivityBusy, self.nodeDelayResults, self.nodeDelayBusy, self.nodeOptimizeBusy, self.nodeOptimizeProgress ]);
			if (signature === self.lastRefreshSignature) return;
			self.lastRefreshSignature = signature;
			self.data = { status: result[0] || {}, settings: result[1] || {}, stats: result[2] || {}, proxies: result[3] || { connected: false } };
			var old = document.querySelector(".tidynet");
			if (old) old.replaceWith(self.render(self.data));
		}).finally(function() { self.refreshPending = null; });
		return this.refreshPending;
	},

	refreshStatus: function() {
		var self = this;
		if (this.connectivityBusy) { this.notify("网站测速中，请稍后刷新状态"); return Promise.resolve(); }
		return this.refresh().then(function() {
			self.notify(self.lastRefreshFailures ? "部分状态读取失败，已保留上次数据" : "状态已刷新", !!self.lastRefreshFailures);
		});
	},

	selectProxy: function(group, member) {
		var self = this;
		return callProxySelect(group, member).then(function(result) {
			if (!result || !result.ok) { self.notify(result && result.error, true); return; }
			self.notify(result.message || "已切换代理"); return self.refresh();
		}).catch(function() { self.notify("切换失败：无法连接 Mihomo 本机控制器", true); });
	},

	updateConnectivity: function() {
		var self = this;
		[ "google", "openai", "aliyun" ].forEach(function(target) {
			var el = document.querySelector(".tn-delay-" + target), result = self.connectivityResults[target];
			if (!el) return;
			el.textContent = result ? (result.ok ? Number(result.delay).toLocaleString() + " ms" : "不可达") : "—";
			el.title = result ? (result.error || "上次测试：" + new Date(result.testedAt || Date.now()).toLocaleString()) : "点击闪电测试";
		});
		var button = document.querySelector(".tn-connectivity-refresh");
		if (button) {
			button.classList.toggle("is-testing", this.connectivityBusy);
			button.setAttribute("aria-busy", String(this.connectivityBusy));
			button.disabled = this.connectivityBusy || isTrue(this.data.status.busy) || !this.data.status.mihomo.running;
		}
		var hint = document.querySelector(".tn-connectivity-hint");
		if (hint) hint.textContent = this.connectivityBusy ? "正在测速…" : "点击闪电测试";
	},

	testConnectivity: function() {
		var self = this;
		if (this.connectivityBusy) return Promise.resolve();
		this.connectivityBusy = true;
		this.updateConnectivity();
		return Promise.all([ "google", "openai", "aliyun" ].map(function(target) {
			return callProxyProbe(target).catch(function() { return { ok: false, error: "路由器测速请求失败" }; }).then(function(result) {
				result = result || { ok: false };
				result.testedAt = Date.now();
				self.connectivityResults[target] = result;
				try { window.localStorage.setItem("tidynet.connectivity.v1", JSON.stringify(self.connectivityResults)); } catch (e) {}
				self.updateConnectivity();
			});
		})).finally(function() {
			self.connectivityBusy = false;
			self.updateConnectivity();
		});
	},

	openNodeTests: function(group, members, selected, groupType) {
		var self = this, canSelect = groupType === "Selector", progress = this.nodeOptimizeProgress[group];
		var sorted = members.slice().sort(function(a, b) {
			var ra = self.nodeDelayResults[JSON.stringify([ group, a ])], rb = self.nodeDelayResults[JSON.stringify([ group, b ])];
			if (ra && ra.ok && rb && rb.ok) return Number(ra.delay) - Number(rb.delay);
			if (ra && ra.ok) return -1;
			if (rb && rb.ok) return 1;
			if (ra && !rb) return -1;
			if (rb && !ra) return 1;
			return 0;
		});
		var rows = sorted.map(function(member) {
			var key = JSON.stringify([ group, member ]), result = self.nodeDelayResults[key];
			var delayText = self.nodeDelayBusy[key] ? "测试中…" : (result ? (result.ok ? Number(result.delay).toLocaleString() + " ms" : "测试失败") : "尚未测试");
			var actions = [ mkButton({ "class": "cbi-button", disabled: boolAttr(!!self.nodeDelayBusy[key] || !!self.nodeOptimizeBusy[group]), click: ui.createHandlerFn(self, function() { return self.testNode(group, member, members, selected, groupType); }) }, [ self.nodeDelayBusy[key] ? "测试中…" : "测速" ]) ];
			if (canSelect) actions.push(mkButton({ "class": "cbi-button cbi-button-action", disabled: boolAttr(!!self.nodeOptimizeBusy[group]), click: ui.createHandlerFn(self, function() { ui.hideModal(); return self.selectProxy(group, member); }) }, [ member === selected ? "当前节点" : "选择" ]));
			return E("div", { "class": "tn-node-test-row" }, [
				E("div", { "class": "tn-node-test-name" }, [ E("strong", {}, [ member ]), E("small", {}, [ member === selected ? (delayText + " · 当前使用") : delayText ]) ]),
				E("div", { "class": "tn-node-test-actions" }, actions)
			]);
		});
		var footer = [];
		if (canSelect && progress) footer.push(E("span", { "class": "tn-optimize-progress" }, [ "正在测速 " + progress.done + "/" + progress.total ]));
		footer.push(mkButton({ "class": "cbi-button", click: function() { ui.hideModal(); } }, [ "关闭" ]));
		if (canSelect) footer.push(mkButton({ "class": "cbi-button cbi-button-action", disabled: boolAttr(!!this.nodeOptimizeBusy[group]), click: ui.createHandlerFn(this, function() { return self.optimizeNode(group, members, selected, groupType); }) }, [ this.nodeOptimizeBusy[group] ? "正在优选…" : "一键优选" ]));
		ui.showModal("节点测速 · " + group, [
			E("p", { "class": "tn-help" }, [ canSelect ? "自动测速同组节点并切换到延时最低的可用节点；DIRECT、REJECT 等直连/拦截项会跳过。" : "延时通过 Mihomo 测试地址 https://www.gstatic.com/generate_204 测量；自动测速组由 Mihomo 自行选择。" ]),
			E("div", { "class": "tn-node-test-list" }, rows),
			E("div", { "class": "tn-modal-actions tn-node-test-footer" }, footer)
		]);
	},

	testNode: function(group, member, members, selected, groupType) {
		var self = this, key = JSON.stringify([ group, member ]);
		if (this.nodeOptimizeBusy[group]) return;
		this.nodeDelayBusy[key] = true;
		this.openNodeTests(group, members, selected, groupType);
		return callProxyNodeDelay(group, member).then(function(result) {
			self.nodeDelayResults[key] = result || { ok: false };
		}).catch(function() {
			self.nodeDelayResults[key] = { ok: false };
		}).finally(function() {
			self.nodeDelayBusy[key] = false;
			self.openNodeTests(group, members, selected, groupType);
		});
	},

	optimizeNode: function(group, members, selected, groupType) {
		var self = this, candidates = members.filter(function(member) { return !/^(DIRECT|REJECT|PASS|GLOBAL|COMPATIBLE)$/i.test(member); });
		if (groupType !== "Selector" || this.nodeOptimizeBusy[group]) return;
		if (!candidates.length) { this.notify("该策略组没有可测速的节点。", true); return; }
		this.nodeOptimizeBusy[group] = true;
		this.nodeOptimizeProgress[group] = { done: 0, total: candidates.length };
		this.openNodeTests(group, members, selected, groupType);
		var index = 0;
		function testNext() {
			if (index >= candidates.length) {
				var best = null;
				candidates.forEach(function(member) {
					var result = self.nodeDelayResults[JSON.stringify([ group, member ])];
					if (result && result.ok && (!best || Number(result.delay) < Number(best.delay))) best = { member: member, delay: result.delay };
				});
				if (!best) {
					self.nodeOptimizeBusy[group] = false; delete self.nodeOptimizeProgress[group];
					self.openNodeTests(group, members, selected, groupType); self.notify("没有测出可用节点，请稍后重试。", true); return;
				}
				if (best.member === selected) {
					self.nodeOptimizeBusy[group] = false; delete self.nodeOptimizeProgress[group];
					self.openNodeTests(group, members, selected, groupType); self.notify("当前节点已是延时最低的可用节点（" + best.delay + " ms）。"); return;
				}
				return callProxySelect(group, best.member).then(function(result) {
					if (!result || !result.ok) { self.notify(result && result.error || "优选节点切换失败。", true); return; }
					ui.hideModal(); self.notify("已优选 " + best.member + "（" + best.delay + " ms）。");
				}).catch(function() { self.notify("优选节点切换失败：无法连接 Mihomo 控制器。", true); }).finally(function() {
					self.nodeOptimizeBusy[group] = false; delete self.nodeOptimizeProgress[group]; return self.refresh();
				});
			}
			var batch = candidates.slice(index, index + 3);
			index += batch.length;
			return Promise.all(batch.map(function(member) {
				var key = JSON.stringify([ group, member ]);
				self.nodeDelayBusy[key] = true;
				return callProxyNodeDelay(group, member).then(function(result) {
					self.nodeDelayResults[key] = result || { ok: false };
				}).catch(function() { self.nodeDelayResults[key] = { ok: false }; }).finally(function() {
					self.nodeDelayBusy[key] = false;
					self.nodeOptimizeProgress[group].done++;
					self.openNodeTests(group, members, selected, groupType);
				});
			})).then(testNext);
		}
		return testNext();
	},

	form: function(title, definitions, submitLabel, submit) {
		var fields = {}, body = [];
		definitions.forEach(function(def) {
			var control;
			if (def.type === "select") {
				control = E("select", { "class": "tn-input", name: def.id }, def.options.map(function(choice) {
					return mkOption({ value: choice[0], selected: boolAttr(choice[0] === String(def.value)) }, [ choice[1] ]);
				}));
			}
			else if (def.type === "textarea") {
				control = E("textarea", { "class": "tn-input tn-textarea", name: def.id, rows: def.rows || 5 }, [ def.value || "" ]);
			}
			else {
				control = E("input", { "class": "tn-input", name: def.id, type: def.type || "text", value: def.value || "", placeholder: def.placeholder || "", autocomplete: "off" });
			}
			fields[def.id] = control;
			body.push(E("label", { "class": "tn-field" }, [ E("span", {}, [ def.label ]), control, def.hint ? E("small", { "class": "tn-help" }, [ def.hint ]) : "" ]));
		});
		ui.showModal(title, [ E("div", { "class": "tn-form" }, body), E("div", { "class": "tn-modal-actions" }, [
			mkButton({ "class": "cbi-button", click: function() { ui.hideModal(); } }, [ "取消" ]),
			mkButton({ "class": "cbi-button cbi-button-action", click: ui.createHandlerFn(this, function() {
				var values = {};
				Object.keys(fields).forEach(function(key) { values[key] = fields[key].value; });
				ui.hideModal(); return submit(values);
			}) }, [ submitLabel || "保存" ])
		]) ]);
	},

	confirm: function(title, detail, yes, operation, section) {
		var self = this;
		ui.showModal(title, [ E("p", { "class": "tn-confirm-copy" }, [ detail ]), E("div", { "class": "tn-modal-actions" }, [
			mkButton({ "class": "cbi-button", click: function() { ui.hideModal(); } }, [ "取消" ]),
			mkButton({ "class": "cbi-button cbi-button-action", click: ui.createHandlerFn(this, function() {
				ui.hideModal(); return self.action(operation, section);
			}) }, [ yes ])
		]) ]);
	},

	removeConfigured: function(title, detail, operation, id) {
		var self = this;
		ui.showModal(title, [ E("p", { "class": "tn-confirm-copy" }, [ detail ]), E("div", { "class": "tn-modal-actions" }, [
			mkButton({ "class": "cbi-button", click: function() { ui.hideModal(); } }, [ "取消" ]),
			mkButton({ "class": "cbi-button tn-danger", click: ui.createHandlerFn(this, function() {
				ui.hideModal(); return self.configure({ operation: operation, id: id });
			}) }, [ "删除" ])
		]) ]);
	},

	editSubscription: function(item) {
		var self = this;
		if (item && item.local_file) {
			this.form("本地配置名称", [ { id: "name", label: "名称", value: item.name } ], "保存名称", function(values) { return self.configure({ operation: "subscription-rename", id: item.id, name: values.name.trim() }); }); return;
		}
		this.form(item ? "编辑订阅" : "添加订阅", [
			{ id: "name", label: "显示名称", value: item ? item.name : "", placeholder: "例如：我的订阅" },
			{ id: "url", label: "订阅地址", type: "url", value: "", placeholder: item && item.url_set ? "已保存；留空保持原地址" : "https:// 或 http://192.168.1.x:端口/", hint: "支持 HTTPS；HTTP 仅允许局域网私有地址。订阅 URL 不会返回浏览器。" },
			{ id: "format", label: "订阅格式", type: "select", value: item ? item.format : "clash-yaml", options: [ [ "clash-yaml", "Clash YAML" ], [ "mihomo-yaml", "Mihomo YAML" ] ] }
		], "保存订阅", function(values) {
			if (!values.name.trim() || (!values.url.trim() && !(item && item.url_set))) { self.notify("请填写名称和订阅地址", true); return; }
			self.configure({ operation: "subscription-save", id: item ? item.id : "", name: values.name.trim(), url: values.url.trim(), format: values.format });
		});
	},

	uploadSubscription: function(ev) {
		var self = this;
		return ui.uploadFile("/tmp/tidynet-upload.yaml", ev.currentTarget).then(function(file) {
			if (file.size > 20971520) { self.notify("配置文件不能超过 20 MB", true); return; }
			return self.configure({ operation: "subscription-import", name: (file.name || "本地配置").replace(/\.(yaml|yml)$/i, "").slice(0, 80) || "本地配置" });
		}).catch(function() { self.notify("上传失败，请检查文件和权限", true); });
	},

	editSource: function(item) {
		var self = this;
		this.form(item ? "编辑广告规则源" : "添加广告规则源", [
			{ id: "name", label: "规则源名称", value: item ? item.name : "" },
			{ id: "url", label: "规则地址", type: "url", value: "", placeholder: item && item.url_set ? "已保存；留空保持原地址" : "https://" },
			{ id: "format", label: "文件格式", type: "select", value: item ? item.format : "hosts", options: [ [ "hosts", "Hosts 列表" ], [ "domains", "纯域名列表" ] ] },
			{ id: "action", label: "规则用途", type: "select", value: item ? item.action : "block", options: [ [ "block", "拦截" ], [ "allow", "允许" ] ] },
			{ id: "enabled", label: "启用", type: "select", value: item && item.enabled === false ? "0" : "1", options: [ [ "1", "启用" ], [ "0", "停用" ] ] }
		], "保存规则源", function(values) {
			if (!values.name.trim() || (!values.url.trim() && !(item && item.url_set))) { self.notify("请填写规则源名称和地址", true); return; }
			self.configure({ operation: "source-save", id: item ? item.id : "", name: values.name.trim(), url: values.url.trim(), format: values.format, action: values.action, enabled: values.enabled });
		});
	},

	manageDomains: function(settings) {
		var self = this;
		this.form("自定义域名", [
			{ id: "allowed", label: "允许域名（每行一个）", type: "textarea", rows: 6, value: settings.allowed_domains || "" },
			{ id: "blocked", label: "拦截域名（每行一个）", type: "textarea", rows: 6, value: settings.blocked_domains || "" }
		], "保存域名", function(values) { return self.configure({ operation: "domains-save", allowed: values.allowed, blocked: values.blocked }); });
	},

	manageSources: function(sources, busy) {
		var self = this;
		var rows = (sources || []).map(function(source) {
			return E("div", { "class": "tn-source-manage-row" }, [
				E("div", {}, [ E("strong", {}, [ source.name || source.id ]), E("small", {}, [ source.action === "allow" ? "允許列表" : "拦截列表" ]) ]),
				E("div", { "class": "tn-row-buttons" }, [
				mkButton({ "class": "tn-link-btn", disabled: boolAttr(busy), click: ui.createHandlerFn(self, function() { self.editSource(source); }) }, [ "编辑" ]),
				mkButton({ "class": "tn-link-btn", disabled: boolAttr(busy), click: ui.createHandlerFn(self, function() { return self.action("adblock-update", source.id); }) }, [ "更新" ]),
				mkButton({ "class": "tn-link-btn tn-delete-link", disabled: boolAttr(busy), click: ui.createHandlerFn(self, function() { self.removeConfigured("删除规则源", "确定删除“%s”？".format(source.name), "source-delete", source.id); }) }, [ "删除" ])
				])
			]);
		});
		ui.showModal("广告规则源", [
			E("div", { "class": "tn-source-manage" }, rows.length ? rows : [ E("p", { "class": "tn-muted" }, [ "暂无规则源" ]) ]),
			E("div", { "class": "tn-modal-actions" }, [
				mkButton({ "class": "cbi-button cbi-button-action", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { self.editSource(null); }) }, [ "添加规则源" ]),
				mkButton({ "class": "cbi-button", click: function() { ui.hideModal(); } }, [ "关闭" ])
			])
		]);
	},

	manageDns: function(settings) {
		var self = this;
		this.form("DNS 设置", [
			{ id: "enabled", label: "系统 DNS 接入", type: "select", value: settings.dns_enabled ? "1" : "0", options: [ [ "0", "关闭" ], [ "1", "启用 TidyNet DNS" ] ], hint: "启用后 dnsmasq 将把 LAN DNS 上游转发到 TidyNet Mihomo DNS；关闭时撤销 TidyNet 自己添加的配置。" },
			{ id: "mode", label: "解析模式", type: "select", value: settings.dns_mode || "redir-host", options: [ [ "redir-host", "真实 IP（redir-host）" ], [ "fake-ip", "Fake IP" ] ] },
			{ id: "ipv6", label: "IPv6 解析", type: "select", value: settings.dns_ipv6 ? "1" : "0", options: [ [ "0", "关闭" ], [ "1", "开启" ] ] },
			{ id: "direct_dns", label: "直连 DNS（每行一个）", type: "textarea", rows: 3, value: settings.dns_direct || "223.5.5.5\nhttps://dns.alidns.com/dns-query", hint: "用于 DIRECT 规则命中的域名解析。" },
			{ id: "proxy_dns", label: "代理 DNS（每行一个）", type: "textarea", rows: 3, value: settings.dns_proxy || "https://1.1.1.1/dns-query\nhttps://8.8.8.8/dns-query", hint: "经代理链路访问；请使用 Mihomo 支持的 DNS 地址格式。" },
			{ id: "direct_domains", label: "直连解析域名（每行一个）", type: "textarea", rows: 3, value: settings.dns_direct_domains || "", hint: "这些域名强制使用上方直连 DNS。支持 example.com，按域名后缀匹配。" },
			{ id: "proxy_domains", label: "代理解析域名（每行一个）", type: "textarea", rows: 3, value: settings.dns_proxy_domains || "", hint: "这些域名强制使用上方代理 DNS。支持 example.com，按域名后缀匹配。" },
			{ id: "cache", label: "DNS 缓存", type: "select", value: settings.dns_cache === "0" ? "0" : "1", options: [ [ "1", "启用" ], [ "0", "关闭" ] ] }
		], "保存设置", function(values) {
			if (values.enabled === "1" && !settings.dns_enabled) {
				ui.showModal("启用 TidyNet DNS", [ E("p", { "class": "tn-confirm-copy" }, [ "这会将 dnsmasq 上游切换到 TidyNet 本机 DNS，并记录原 noresolv 设置以便关闭时恢复。请确认没有其它插件同时管理全局 DNS 上游。" ]), E("div", { "class": "tn-modal-actions" }, [
					mkButton({ "class": "cbi-button", click: function() { ui.hideModal(); } }, [ "取消" ]),
					mkButton({ "class": "cbi-button cbi-button-action", click: ui.createHandlerFn(self, function() {
						ui.hideModal(); return self.configure({ operation: "dns-save", enabled: values.enabled, mode: values.mode, ipv6: values.ipv6, direct_dns: values.direct_dns, proxy_dns: values.proxy_dns, direct_domains: values.direct_domains, proxy_domains: values.proxy_domains, cache: values.cache });
					}) }, [ "启用并保存" ])
				]) ]);
				return;
			}
			return self.configure({ operation: "dns-save", enabled: values.enabled, mode: values.mode, ipv6: values.ipv6, direct_dns: values.direct_dns, proxy_dns: values.proxy_dns, direct_domains: values.direct_domains, proxy_domains: values.proxy_domains, cache: values.cache });
		});
	},

	manageSettings: function(settings) {
		var self = this;
		this.form("面板设置", [
			{ id: "dashboard_url", label: "Mihomo WebUI 地址", type: "url", value: settings.dashboard_url || "", placeholder: "http://192.168.1.8:9090/ui/", hint: "填写浏览器可访问的 Mihomo WebUI；控制接口由该面板按自身设置连接。" }
		], "保存设置", function(values) { return self.configure({ operation: "settings-save", url: values.dashboard_url.trim() }); });
	},

	render: function(data) {
		var self = this;
		this.data = data || this.data || {};
		var s = this.data.status || {}, settings = this.data.settings || {}, stats = this.data.stats || {}, proxyState = this.data.proxies || {};
		var mihomo = s.mihomo || {}, ad = s.adblock || {}, dns = s.dns || {}, subs = settings.subscriptions || [], sources = settings.sources || [];
		var proxyGroups = [];
		if (proxyState.connected && proxyState.data) {
			try {
				var apiProxies = JSON.parse(proxyState.data).proxies || {};
				proxyGroups = Object.keys(apiProxies).map(function(name) { return apiProxies[name]; }).filter(function(group) {
					return Array.isArray(group.all) && group.all.length > 0 && group.type !== "LoadBalance" && (group.type !== "Selector" || group.all.some(function(member) { return !/^(DIRECT|REJECT|PASS|GLOBAL|COMPATIBLE)$/i.test(member); }));
				});
			}
			catch (e) { proxyGroups = []; }
		}
		var root = E("main", { "class": "tidynet" });
		var busy = isTrue(s.busy);
		var webuiUrl = settings.dashboard_url || "http://" + window.location.hostname + ":9090/ui/";
		root.appendChild(E("header", { "class": "tn-header" }, [
			E("div", { "class": "tn-brand" }, [ E("img", { "class": "tn-brand-mascot", src: L.resource("view/tidynet/mascot.svg"), alt: "", width: 48, height: 48 }), E("div", {}, [ E("h2", {}, [ "TidyNet" ]), E("p", {}, [ "代理、DNS 与广告过滤，一处管理" ]) ]) ]),
			E("div", { "class": "tn-header-actions" }, [
				mkButton({ "class": "cbi-button", click: ui.createHandlerFn(this, function() { self.manageSettings(settings); }) }, [ "面板设置" ]),
				E("a", { "class": "cbi-button tn-webui-link", href: webuiUrl, target: "_blank", rel: "noopener noreferrer" }, [ "打开 WebUI ↗" ]),
				mkButton({ "class": "cbi-button", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { return self.refreshStatus(); }) }, [ "刷新状态" ])
			])
		]));

		var stateText = mihomo.running ? "运行中" : (mihomo.installed ? "已停止" : "未安装");
		var coreVersion = (mihomo.core_version || "").replace(/^Mihomo(?:\s+Meta)?\s+/i, "").split(/\s+/)[0] || "未安装";
		var latestVersion = mihomo.latest_version || (mihomo.latest_checked ? "暂不可用" : "检查中");
		function versionParts(value) { var match = String(value || "").match(/(\d+)\.(\d+)\.(\d+)/); return match ? match.slice(1).map(Number) : null; }
		var installedParts = versionParts(coreVersion), latestParts = versionParts(mihomo.latest_version), hasCoreUpdate = false, sameCoreVersion = false;
		if (installedParts && latestParts) {
			sameCoreVersion = installedParts.every(function(part, index) { return part === latestParts[index]; });
			for (var versionIndex = 0; versionIndex < installedParts.length; versionIndex++) {
				if (latestParts[versionIndex] !== installedParts[versionIndex]) { hasCoreUpdate = latestParts[versionIndex] > installedParts[versionIndex]; break; }
			}
		}
		var coreCard = E("section", { "class": "tn-card tn-core-card" }, [
			E("div", { "class": "tn-card-head tn-core-card-head" }, [ E("div", {}, [ E("h3", {}, [ "Mihomo 核心" ]), E("small", { "class": "tn-core-version", title: mihomo.core_version || "核心尚未安装" }, [ "本机版本 · ", coreVersion ]) ]), E("span", { "class": "tn-core-state " + (mihomo.running ? "is-running" : mihomo.installed ? "is-stopped" : "is-missing") }, [ E("i", { "aria-hidden": "true" }), stateText ]) ]),
			E("div", { "class": "tn-core-latest-row" }, [ E("span", {}, [ "官方最新版本 · ", E("b", {}, [ latestVersion ]) ]), mihomo.latest_version ? E("span", { "class": "tn-core-update-state " + (hasCoreUpdate ? "has-update" : "is-latest") }, [ hasCoreUpdate ? "有新版本" : sameCoreVersion ? "已是最新" : "本机版本较新" ]) : "" ]),
			E("div", { "class": "tn-core-actions" }, [
				mkButton({ "class": "cbi-button tn-core-update-btn", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() {
					self.confirm(mihomo.core_installed ? "下载并更新 Mihomo 核心" : "下载 Mihomo 核心", "从 Mihomo 官方发布页获取适配本机架构的核心，校验 SHA-256 后安装。", mihomo.core_installed ? "更新核心" : "下载核心", "mihomo-core-update");
				}) }, [ mihomo.core_installed ? "更新核心" : "下载核心" ]),
				mihomo.installed && !mihomo.running ? mkButton({ "class": "cbi-button tn-core-start", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { return self.action("mihomo-start"); }) }, [ "开始" ]) : "",
				mihomo.running ? mkButton({ "class": "cbi-button tn-core-stop", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { self.confirm("停止 Mihomo", "这会停止 TidyNet 管理的代理核心。", "停止", "mihomo-stop"); }) }, [ "停止" ]) : "",
				mihomo.installed ? mkButton({ "class": "cbi-button", disabled: boolAttr(busy || !mihomo.running), click: ui.createHandlerFn(this, function() { return self.action("mihomo-reload"); }) }, [ "重载配置" ]) : ""
			])
		]);

		var probeResults = this.connectivityResults || {};
		function delayLabel(result) {
			if (!result) return "—";
			return result.ok ? Number(result.delay).toLocaleString() + " ms" : "不可达";
		}
		var connectivityCard = E("section", { "class": "tn-card tn-connectivity-card tn-connectivity-compact" }, [
			E("div", { "class": "tn-connectivity-heading" }, [
				E("div", { "class": "tn-connectivity-title" }, [ E("strong", {}, [ "网络状态" ]) ]), E("small", { "class": "tn-connectivity-hint" }, [ this.connectivityBusy ? "正在测速…" : "点击闪电测试" ])
			]),
			E("div", { "class": "tn-connectivity-items" }, [
				E("div", { "class": "tn-connectivity-item" }, [ E("span", { "class": "tn-service-icon tn-google-icon", "aria-hidden": "true" }, [ "G" ]), E("div", {}, [ E("strong", {}, [ "Google" ]), E("small", { "class": "tn-delay-google", "aria-live": "polite" }, [ delayLabel(probeResults.google) ]) ]) ]),
				E("div", { "class": "tn-connectivity-item" }, [ E("span", { "class": "tn-service-icon tn-openai-icon", "aria-hidden": "true" }, [ "AI" ]), E("div", {}, [ E("strong", {}, [ "OpenAI" ]), E("small", { "class": "tn-delay-openai", "aria-live": "polite" }, [ delayLabel(probeResults.openai) ]) ]) ]),
				E("div", { "class": "tn-connectivity-item" }, [ E("span", { "class": "tn-service-icon tn-aliyun-icon", "aria-hidden": "true" }, [ "阿" ]), E("div", {}, [ E("strong", {}, [ "阿里云" ]), E("small", { "class": "tn-delay-aliyun", "aria-live": "polite" }, [ delayLabel(probeResults.aliyun) ]) ]) ]),
				mkButton({ type: "button", "class": "tn-icon-btn tn-connectivity-refresh" + (this.connectivityBusy ? " is-testing" : ""), title: "测试网站连接延时", "aria-label": "测试 Google、OpenAI 和阿里云延时", "aria-busy": String(this.connectivityBusy), disabled: boolAttr(busy || !mihomo.running || this.connectivityBusy), click: function(ev) { ev.preventDefault(); self.testConnectivity().catch(function() { self.notify("测速更新失败，请重试", true); }); } }, [ E("span", { "class": "tn-bolt", "aria-hidden": "true" }) ])
			]),
			E("div", { "class": "tn-connectivity-item tn-ad-status " + (ad.enabled ? "tn-ad-status-on" : "tn-ad-status-off"), title: "统计来自 dnsmasq 查询日志；使用外部 DoH/DoT 的查询不计入。" }, [
				E("span", { "class": "tn-service-icon tn-ad-icon", "aria-hidden": "true" }, [ "✦" ]),
				E("div", { "class": "tn-filter-overview" }, [
					E("div", { "class": "tn-filter-caption" }, [ E("strong", {}, [ "广告过滤" ]), E("span", { "class": "tn-filter-state" }, [ ad.enabled ? "已启用" : "已暂停" ]) ]),
					E("div", { "class": "tn-filter-counts" }, [
						E("span", {}, [ E("b", {}, [ stats.blocked == null ? "—" : Number(stats.blocked).toLocaleString() ]), " 次拦截" ]),
						E("span", {}, [ E("b", {}, [ stats.queries == null ? "—" : Number(stats.queries).toLocaleString() ]), " 次查询" ])
					])
				])
			])
		]);
		root.appendChild(connectivityCard);
		var subRows = subs.map(function(item) {
			return E("article", { "class": "tn-list-row tn-subscription" + (item.active ? " is-active" : "") }, [
				E("div", { "class": "tn-subscription-heading" }, [ E("strong", {}, [ item.name || "未命名订阅" ]), E("span", { "class": "tn-subscription-badge" }, [ item.active ? "✓ 正在使用" : "待应用" ]) ]),
				E("p", { "class": "tn-subscription-time" }, [ "上次更新 · ", E("span", {}, [ item.updated || "尚未更新" ]) ]),
				!item.local_file ? E("label", { "class": "tn-subscription-schedule" }, [ E("span", {}, [ "自动更新周期" ]), mkSelect({ "class": "tn-input", "aria-label": (item.name || "订阅") + "自动更新周期", disabled: boolAttr(busy), change: function(ev) { self.configure({ operation: "subscription-schedule", id: item.id, interval: ev.target.value }); } }, [ [ "0", "手动更新" ], [ "6", "每 6 小时" ], [ "12", "每 12 小时" ], [ "24", "每天" ], [ "48", "每 2 天" ], [ "168", "每周" ] ].map(function(choice) { return mkOption({ value: choice[0], selected: boolAttr(String(item.update_interval || "0") === choice[0]) }, [ choice[1] ]); })) ]) : "",
				E("div", { "class": "tn-row-buttons" }, [
					mkButton({ "class": "tn-link-btn", disabled: boolAttr(busy), click: ui.createHandlerFn(self, function() { self.editSubscription(item); }) }, [ "编辑" ]),
					item.local_file ? E("span", { "class": "tn-local-file" }, [ "本地文件" ]) : mkButton({ "class": "tn-link-btn", title: "立即手动更新此订阅", disabled: boolAttr(busy || !mihomo.core_installed), click: ui.createHandlerFn(self, function() { return self.action("subscription-update", item.id); }) }, [ "手动更新" ]),
					mkButton({ "class": "cbi-button tn-subscription-apply", title: item.active ? "此配置正在使用" : "更新此订阅并应用到 Mihomo", disabled: boolAttr(busy || !mihomo.core_installed || item.active), click: ui.createHandlerFn(self, function() { return self.action("subscription-use", item.id); }) }, [ item.active ? "已应用" : "应用" ]),
					item.active ? "" : mkButton({ "class": "tn-link-btn tn-delete-link", disabled: boolAttr(busy), click: ui.createHandlerFn(self, function() { self.removeConfigured("删除订阅", "确定删除“%s”？".format(item.name), "subscription-delete", item.id); }) }, [ "删除" ])
				])
			]);
		});
		var subCard = E("section", { "class": "tn-card tn-sub-card" }, [
			E("div", { "class": "tn-card-head" }, [ E("h3", {}, [ "订阅管理" ]), E("div", { "class": "tn-row-buttons" }, [ mkButton({ "class": "cbi-button", disabled: boolAttr(busy || !mihomo.core_installed), click: ui.createHandlerFn(this, function(ev) { return self.uploadSubscription(ev); }) }, [ "上传配置" ]), mkButton({ "class": "cbi-button", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { self.editSubscription(null); }) }, [ "＋ 添加" ]) ]) ]),
			subRows.length ? E("div", { "class": "tn-list" }, subRows) : E("div", { "class": "tn-empty" }, [ "还没有订阅，添加 Mihomo/Clash YAML 地址即可。" ])
		]);

		var adCard = E("section", { "class": "tn-card tn-ad-card" }, [
			E("div", { "class": "tn-card-head" }, [ E("h3", {}, [ "过滤规则" ]),
				mkButton({ "class": "cbi-button cbi-button-action", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() {
					if (ad.enabled) return self.action("adblock-stop");
					self.confirm("启用广告过滤和统计", "TidyNet 会把拦截域名接入 dnsmasq，并启用本机 DNS 查询日志来累计拦截数与查询数。TidyNet 持久保存汇总计数；dnsmasq 系统日志可能短暂包含查询域名和来源地址，保留时长由系统日志设置决定。使用路由器以外的 DoH/DoT 的客户端无法纳入统计。", "启用", "adblock-start");
				}) }, [ ad.enabled ? "暂停过滤" : "启用过滤" ])
			]),
			E("div", { "class": "tn-card-actions tn-rule-actions" }, [
				mkButton({ "class": "cbi-button", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { self.manageSources(sources, busy); }) }, [ "规则源" ]),
				mkButton({ "class": "cbi-button", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { return self.action("adblock-update"); }) }, [ "更新规则" ]),
				mkButton({ "class": "cbi-button", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { self.manageDomains(settings); }) }, [ "自定义域名" ])
			]),
			E("div", { "class": "tn-rules-summary" }, [ E("span", {}, [ "生效规则 ", E("b", {}, [ Number(ad.blocked_domains || 0).toLocaleString() ]), " 条" ]), mkSelect({ "class": "tn-input tn-rule-schedule", "aria-label": "规则自动更新周期", change: function(ev) { self.configure({ operation: "rules-schedule", interval: ev.target.value }); } }, [ [ "0", "手动更新" ], [ "1", "每小时" ], [ "6", "每 6 小时" ], [ "12", "每 12 小时" ], [ "24", "每天 04:00" ] ].map(function(choice) { return mkOption({ value: choice[0], selected: boolAttr(String(settings.rule_update_interval || "0") === choice[0]) }, [ choice[1] ]); })) ]),
			ad.last_update ? E("p", { "class": "tn-footnote" }, [ "最近更新：" + ad.last_update ]) : ""
		]);
		var proxyRows = proxyGroups.map(function(group) {
			var selected = group.now || group.fixed || "";
			var modes = { Selector: [ "manual", "手动选择" ], URLTest: [ "auto", "自动测速" ], Fallback: [ "fallback", "故障切换" ], LoadBalance: [ "balance", "负载均衡" ] };
			var mode = modes[group.type] || [ "manual", "策略组" ];
			var selector = mkSelect({ "class": "tn-input tn-proxy-select", "aria-label": (group.name || "代理策略") + "：当前节点", title: selected, disabled: boolAttr(busy || !proxyState.connected), change: ui.createHandlerFn(self, function(ev) {
				if (ev.target.value && ev.target.value !== selected) return self.selectProxy(group.name, ev.target.value);
			}) }, group.all.map(function(member) {
				return mkOption({ value: member, selected: boolAttr(member === selected) }, [ member ]);
			}));
			return E("article", { "class": "tn-proxy-row tn-proxy-" + mode[0] }, [
				E("div", { "class": "tn-proxy-group-name" }, [ E("strong", {}, [ group.name || "代理策略" ]), E("span", { "class": "tn-proxy-mode" }, [ mode[1] ]) ]),
				E("label", { "class": "tn-proxy-current" }, [ selector ]),
				E("div", { "class": "tn-proxy-controls" }, [
					E("span", { "class": "tn-proxy-meta" }, [ group.all.length + " 个节点" ])
				])
			]);
		});
		var proxyCard = E("section", { "class": "tn-card tn-proxy-card" }, [
			E("div", { "class": "tn-card-head tn-proxy-heading" }, [ E("h3", {}, [ "代理策略" ]), E("span", { "class": "tn-pill " + (proxyState.connected ? "pill-on" : "") }, [ proxyState.connected ? "已连接" : "未连接" ]) ]),
			proxyRows.length ? E("div", { "class": "tn-proxy-list" }, proxyRows) : E("div", { "class": "tn-empty" }, [ proxyState.connected ? "当前配置没有可切换的代理策略组。" : "启动 Mihomo 后，可在这里切换代理策略组；WebUI 控制接口需要令牌保护。" ])
		]);

		var dnsCard = E("section", { "class": "tn-card tn-dns-card" }, [
			E("div", { "class": "tn-card-head" }, [ E("h3", {}, [ "DNS 解析" ]), E("span", { "class": "tn-pill " + (dns.takeover ? "pill-on" : "") }, [ dns.takeover ? "已接管 DNS" : (dns.enabled ? "接管未生效" : "未接管 DNS") ]) ]),
			E("p", { "class": "tn-dns-description" }, [ dns.takeover ? "系统 DNS 查询已转发至 TidyNet" : (dns.enabled ? "请检查 DNS 服务和系统转发配置" : "当前使用系统原有 DNS") ]),
			E("div", { "class": "tn-dns-facts" }, [ E("span", {}, [ "解析模式", E("b", {}, [ dns.mode === "fake-ip" ? "Fake IP" : "真实 IP" ]) ]), E("span", {}, [ "IPv6", E("b", {}, [ dns.ipv6 ? "开启" : "关闭" ]) ]) ]),
			E("div", { "class": "tn-card-actions" }, [
				mkButton({ "class": "cbi-button", click: ui.createHandlerFn(this, function() { self.manageDns(settings); }) }, [ "DNS 设置" ]),
				mkButton({ "class": "cbi-button", click: ui.createHandlerFn(this, function() { self.openDns(); }) }, [ "解析测试" ])
			])
		]);

		var traffic = s.traffic || {}, gateway = traffic.gateway || window.location.hostname;
		var draft = this.trafficDraft || { enabled: settings.traffic_enabled ? "1" : "0", tcp_mode: settings.tcp_mode || "redirect", udp_mode: settings.udp_mode || "tun" };
		function rememberTraffic() { self.trafficDraft = { enabled: trafficEnabled.value, tcp_mode: trafficTcp.value, udp_mode: trafficUdp.value }; }
		var trafficEnabled = mkSelect({ "class": "tn-input", change: rememberTraffic }, [ mkOption({ value: "0", selected: draft.enabled === "0" }, [ "关闭" ]), mkOption({ value: "1", selected: draft.enabled === "1" }, [ "开启" ]) ]);
		var trafficTcp = mkSelect({ "class": "tn-input", change: rememberTraffic }, [ [ "redirect", "自动重定向（推荐）" ], [ "tun", "TUN" ], [ "direct", "不接管" ] ].map(function(choice) { return mkOption({ value: choice[0], selected: draft.tcp_mode === choice[0] }, [ choice[1] ]); }));
		var trafficUdp = mkSelect({ "class": "tn-input", change: rememberTraffic }, [ [ "tun", "TUN（推荐）" ], [ "direct", "不接管" ] ].map(function(choice) { return mkOption({ value: choice[0], selected: draft.udp_mode === choice[0] }, [ choice[1] ]); }));
		var trafficCard = E("section", { "class": "tn-card tn-traffic-card" }, [
			E("div", { "class": "tn-card-head" }, [ E("h3", {}, [ "流量接管" ]), E("span", { "class": "tn-pill " + (traffic.running ? "pill-on" : "") }, [ traffic.running ? "接管运行中" : (traffic.enabled ? "接管异常" : "尚未启用") ]) ]),
			E("p", { "class": "tn-help tn-traffic-copy" }, [ "分别设置 TCP 与 UDP 的接管方式。" ]),
			E("div", { "class": "tn-traffic-settings" }, [ E("label", { "class": "tn-field" }, [ "流量接管", trafficEnabled ]), E("label", { "class": "tn-field" }, [ "TCP 接管方式", trafficTcp ]), E("label", { "class": "tn-field" }, [ "UDP 接管方式", trafficUdp ]) ]),
			E("div", { "class": "tn-traffic-facts" }, [
				E("div", {}, [ E("small", {}, [ "接管范围" ]), E("strong", {}, [ "IPv4" ]) ]),
				E("div", {}, [ E("small", {}, [ "GEO 上次更新" ]), E("strong", {}, [ traffic.geo_updated || "尚未手动更新" ]) ]),
				E("div", {}, [ E("small", {}, [ "依赖状态" ]), E("strong", {}, [ traffic.ready ? "已就绪" : "缺少 yq 或 TUN 模块" ]) ])
			]),
			E("p", { "class": "tn-help tn-traffic-copy" }, [ "仅处理路由到本旁路由的 IPv4 流量；IPv6 暂不接管。" ]),
			E("div", { "class": "tn-card-actions" }, [ mkButton({ "class": "cbi-button cbi-button-action", disabled: boolAttr(busy), click: ui.createHandlerFn(this, function() { return self.configure({ operation: "traffic-save", enabled: trafficEnabled.value, tcp_mode: trafficTcp.value, udp_mode: trafficUdp.value }).then(function(result) { if (result && result.ok) self.trafficDraft = null; }); }) }, [ "保存并应用" ]), mkButton({ "class": "cbi-button", disabled: boolAttr(busy || !mihomo.running), click: ui.createHandlerFn(this, function() { return self.action("geo-update"); }) }, [ "更新 GEO 文件" ]), mkButton({ "class": "cbi-button", click: ui.createHandlerFn(this, function() { return self.refreshStatus(); }) }, [ "检查接管状态" ]) ])
		]);
		root.appendChild(E("div", { "class": "tn-dashboard-grid" }, [ proxyCard, subCard, adCard, dnsCard, trafficCard, coreCard ]));

		var job = s.job || {};
		if (job.state === "running") root.appendChild(E("div", { "class": "tn-job tn-job-running" }, [ "◌  " + (job.message || "后台任务进行中") ]));
		else if (job.state === "error") root.appendChild(E("div", { "class": "tn-job tn-job-error" }, [ "！  " + (job.message || "后台任务失败"), " · ", job.time || "" ]));
		else if (job.state === "success") root.appendChild(E("div", { "class": "tn-job tn-job-success" }, [ "✓  " + (job.message || "后台任务已完成"), " · ", job.time || "" ]));
		if (pollView !== this) {
			if (pollTimer) window.clearInterval(pollTimer);
			pollView = this;
			pollTimer = window.setInterval(function() {
				if (pollView !== self) return;
				if (!document.querySelector(".tidynet")) {
					window.clearInterval(pollTimer);
					pollTimer = null;
					pollView = null;
					return;
				}
				if (!Array.prototype.some.call(document.querySelectorAll(".modal"), function(el) { return el.getClientRects().length > 0; }) && !document.hidden) self.refresh();
			}, 10000);
		}
		return root;
	},

	openDns: function() {
		var input = E("input", { "class": "tn-input", value: "", placeholder: "example.com" });
		var output = E("pre", { "class": "tn-resolve-output" }, [ "查询路由器本机 DNS" ]);
		ui.showModal("DNS 解析测试", [ E("div", { "class": "tn-form" }, [
			E("label", { "class": "tn-field" }, [ E("span", {}, [ "输入域名" ]), input ]),
			mkButton({ "class": "cbi-button cbi-button-action", click: ui.createHandlerFn(this, function() {
				return callResolve(input.value.trim()).then(function(result) { output.textContent = (result.resolver ? "查询路径：" + result.resolver + "\n\n" : "") + (result.output || result.error || "没有结果"); });
			}) }, [ "开始查询" ]), output
		]), E("div", { "class": "tn-modal-actions" }, [ mkButton({ "class": "cbi-button", click: function() { ui.hideModal(); } }, [ "关闭" ]) ]) ]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
