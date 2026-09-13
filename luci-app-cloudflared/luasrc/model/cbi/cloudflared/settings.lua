
local http = require "luci.http"

a=Map("cloudflared",translate("Cloudflared"),translate("Cloudflare的隧道客户端 - 以前称为 Argo Tunnel ，免费的内网穿透，实现内网服务的外网访问"))
a:section(SimpleSection).template  = "cloudflared/cloudflared_status"

t=a:section(NamedSection,"config","cloudflared")
t.anonymous=true
t.addremove=false

e=t:option(Flag,"enabled",translate("Enable"))
e.default=0
e.rmempty=false

btncq = t:option(Button, "btncq", translate("重启"))
btncq.inputtitle = translate("重启")
btncq.description = translate("在没有修改参数的情况下快速重新启动一次")
btncq.inputstyle = "apply"
btncq:depends("enabled", "1")
btncq.write = function()
  os.execute("/etc/init.d/cloudflared restart ")
end

e=t:option(Flag,"cmdenabled",translate("自定义启动参数"),
	translate("使用自定义的启动参数，若不懂请勿开启"))
e.default=0
e.rmempty=false

cfbin = t:option(Value, "cfbin", translate("cloudflared程序路径"),
	translate("自定义cloudflared的存放路径,确保填写完整的路径及cloudflared名称"))
cfbin.placeholder = "/usr/bin/cloudflared"
cfbin.rmempty=false

-- token 仅支持单值(cloudflared --token 为单值参数),用 3 行文本框展示长 token 便于核对
e=t:option(TextValue,"token",translate('隧道 Token'),
	translate("需要先去官网创建隧道，再复制以eyJh开头的一长串token值，注意复制正确否则会启动失败<br>创建隧道提示需要信用卡时，点击返回重新打开即可跳过。"))
e.rows = function() return 3 end
e.placeholder = "eyJhIjoiMzQ3NTNhNDBlZTg4NTYzMDU5YmUzN2U2ZDY4YjEzY2QiLCJ0IjoiNTJkMjkwYTktNmFiNy00NDM5LThlODYtMzhmYTI0NTBhZjNhIiwicyI6IlptRXlOekl4TURZdFpUa3dPUzAwTnprM0xUbGlaR1l0TWpNNVpUUTBNV0k0TTJNMSJ9"
e:depends("cmdenabled", 0)

custom_cmd = t:option(DynamicList, "custom_cmd", translate("自定义启动参数"),
                       translate("这里不需要再加程序路径，只需要正常添加启动参数即可，详细的命令启动参数：<a href='https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/tunnel-run-parameters/' target='_blank'>cloudflared文档</a><br>注意:每个参数必须单独添加,如添加第一个参数tunnel 第二个参数--no-autoupdate 第三个参数--logfile /tmp/cloudflared.info 第四个参数run <br>一个框内不能添加两个参数,多个参数点+多个框即可<br>如需输出日志路径请设置 --logfile /tmp/cloudflared.info"))
custom_cmd.placeholder = "--logfile /tmp/cloudflared.info"
custom_cmd:depends("cmdenabled", 1)

loglevel = t:option(ListValue, "loglevel", translate("日志等级"),
	translate("指定日志记录的详细程度。默认info级别不会产生太多输出，但您可能希望warn在生产中使用该级别。<br>等级由低到高：debug < info < warn < Error < Fatal"))
loglevel:value("info")
loglevel:value("debug")
loglevel:value("warn")
loglevel:value("error")
loglevel:value("fatal")
loglevel:depends("cmdenabled", 0)

update = t:option(Flag, "update", translate("自动更新"),
	translate("默认关闭。开启后 cloudflared 会定期检测并自动下载更新到新版本。<br><b>注意：mips 系列处理器不支持自动更新</b>，开启可能因下载失败导致启动异常，请保持默认关闭。"))
update.rmempty = false
update:depends("cmdenabled", 0)

protocol = t:option(ListValue, "protocol", translate("连接协议"),
	translate("与 Cloudflare 边缘连接使用的传输协议：<br>auto — 自动选择（推荐，优先 QUIC，失败自动回退 HTTP/2）<br>http2 — 基于 TCP 的 HTTP/2，部分网络环境下更稳定<br>quic — 基于 UDP 的 QUIC"))
protocol:value("auto")
protocol:value("http2")
protocol:value("quic")
protocol.default = "auto"
protocol.rmempty = true
protocol:depends("cmdenabled", 0)

region = t:option(ListValue, "region", translate("连接区域"),
	translate("Cloudflare 边缘区域，选择距离最近的区域可降低延迟。官方文档明确提供的区域为 us，其余 enam/weur/apac 等为常用的数据中心区域代码，最终以 Cloudflare 服务端解析为准；也可选“自定义”手动输入区域代码或数据中心编号（如 ssub、002）"))
region:value("", translate("自动（全球区域）"))
region:value("us", translate("美国"))
region:value("enam", translate("北美东部"))
region:value("wnam", translate("北美西部"))
region:value("sam", translate("南美"))
region:value("weur", translate("西欧"))
region:value("eeur", translate("东欧 / 中欧"))
region:value("apac", translate("亚太"))
region:value("oc", translate("大洋洲"))
region:value("me", translate("中东"))
region:value("in", translate("印度"))
region:value("af", translate("非洲"))
region:value("other", translate("自定义…"))
region.rmempty = true
region:depends("cmdenabled", 0)

region_custom = t:option(Value, "region_custom", translate("自定义区域代码"),
	translate("仅在选择“自定义”时生效。手动输入 Cloudflare 边缘区域代码或数据中心编号，例如：ssub、002"))
region_custom.placeholder = "ssub"
region_custom.rmempty = true
region_custom:depends("region", "other")

edge_ip_version = t:option(ListValue, "edge_ip_version", translate("边缘 IP 版本"),
	translate("连接 Cloudflare 边缘时使用的 IP 地址版本：auto — 自动 / 4 — IPv4 / 6 — IPv6。国内网络环境建议选择 4，可避免 IPv6 连接异常"))
edge_ip_version:value("auto")
edge_ip_version:value("4")
edge_ip_version:value("6")
edge_ip_version.default = "auto"
edge_ip_version.rmempty = true
edge_ip_version:depends("cmdenabled", 0)

retries = t:option(Value, "retries", translate("连接重试次数"),
	translate("与边缘连接出错时的最大重试次数，超过后会将连接降级到更低一级的协议。留空使用内置默认值"))
retries.placeholder = "5"
retries.rmempty = true
retries:depends("cmdenabled", 0)

ha_connections = t:option(Value, "ha_connections", translate("并发连接数"),
	translate("与 Cloudflare 边缘建立的高可用连接数量，数量越大可用性越高，但会占用更多资源。留空使用内置默认值"))
ha_connections.placeholder = "4"
ha_connections.rmempty = true
ha_connections:depends("cmdenabled", 0)

metrics = t:option(Value, "metrics", translate("监控指标地址"),
	translate("在本机开启一个 HTTP 指标服务，供监控采集与探活使用，格式 ip:端口，例如 127.0.0.1:41610 留空表示不开启<br>填写有效地址且服务可达后，可点击输入框下方的端点查看：/metrics — 运行指标；/healthcheck — 存活检查；/ready — 就绪检查。"))
metrics.placeholder = "127.0.0.1:41610"
metrics.rmempty = true
metrics:depends("cmdenabled", 0)


e=t:option(DummyValue,"opennewwindow" , 
	translate("<input type=\"button\" class=\"cbi-button cbi-button-apply\" value=\"cloudflare.com\" onclick=\"window.open('https://one.dash.cloudflare.com')\" />"))
e.description = translate("进入官网Zero Trust创建或管理您的 cloudflared 隧道")

-- 覆写 render:在表单下方注入 token 输入实时校验脚本,按错误类型分别提示
local _render = a.render
function a.render(self, ...)
	_render(self, ...)
	http.write([[
<div id="metricsModal" class="mmodal">
  <div class="mmodal-content">
    <div class="mmodal-head"><span id="metricsUrl"></span><button type="button" class="mmodal-close" onclick="closeMetricsModal()">关闭</button></div>
    <div id="metricsRaw"></div>
  </div>
</div>
<script>
// token 输入实时校验:非 eyJh 开头/不完整/格式错误分别提示,通过则为绿色
(function() {
	function init() {
		var inputs = document.querySelectorAll('input.cbi-input-text[name*=".token"], textarea.cbi-input-textarea[name*=".token"]');
		inputs.forEach(function(inp) {
			if (inp.dataset.tkChecked === "1") return;
			inp.dataset.tkChecked = "1";
			var tip = document.createElement("span");
			tip.className = "token-tip";
			inp.parentNode.appendChild(tip);
			// 强制软换行(wrap 是 HTML 属性,需用 JS 设置)
			inp.setAttribute("wrap", "soft");
			function check() {
				var val = (inp.value || "").trim();
				if (val === "") { tip.style.display = "none"; return; }
				tip.style.display = "block";
				if (val.indexOf("eyJh") !== 0) {
					tip.textContent = "Token 必须以 eyJh 开头";
					tip.className = "token-tip err"; return;
				}
				if (val.length < 100) {
					tip.textContent = "Token 不完整，请复制完整字符串";
					tip.className = "token-tip err"; return;
				}
				var ok = false;
				try {
					var s = val.replace(/-/g, "+").replace(/_/g, "/");
					var obj = JSON.parse(atob(s));
					ok = obj && typeof obj === "object";
				} catch (e) { }
				if (!ok) {
					tip.textContent = "Token 格式错误，请重新获取";
					tip.className = "token-tip err"; return;
				}
				tip.textContent = "Token 格式正确";
				tip.className = "token-tip ok";
			}
			inp.addEventListener("input", check);
			inp.addEventListener("blur", check);
			check();
		});
		// 监控指标地址格式校验,并驱动描述区端点链接;数据经 LuCI 后端代理获取,前端解析美化弹窗展示
		var mInput = document.querySelector('input.cbi-input-text[name*=".metrics"]');
		if (mInput) {
			// 动态注入端点链接(不依赖 CBI 描述中的 HTML 渲染)
			var epsWrap = document.createElement("div");
			epsWrap.className = "metrics-links";
			["/metrics", "/healthcheck", "/ready"].forEach(function(ep) {
				var a = document.createElement("a");
				a.className = "mt-link";
				a.setAttribute("data-ep", ep);
				a.textContent = ep;
				epsWrap.appendChild(a);
			});
			mInput.parentNode.insertBefore(epsWrap, mInput.nextSibling);
			function parseMetrics(v) {
				var s = v;
				if (/^https?:\/\//i.test(s)) s = s.replace(/^https?:\/\//i, "");
				var idx = s.lastIndexOf(":");
				if (idx < 1) return { ok: false, msg: "格式应为 ip:端口，例如 127.0.0.1:41610" };
				var host = s.slice(0, idx);
				var port = s.slice(idx + 1);
				if (!/^\d+$/.test(port)) return { ok: false, msg: "端口必须为数字" };
				var p = parseInt(port, 10);
				if (p < 1 || p > 65535) return { ok: false, msg: "端口范围 1-65535" };
				if (host === "" || (host.indexOf(":") !== -1 && !/^\[.*\]$/.test(host)))
					return { ok: false, msg: "IP/主机名格式不正确" };
				return { ok: true, msg: "地址格式正确", port: p };
			}
			var links = Array.prototype.slice.call(document.querySelectorAll('a.mt-link'));
			var mTip = document.createElement("span");
			mTip.className = "metrics-tip";
			mInput.parentNode.appendChild(mTip);
			var running = false;
			function proxyUrl(ep) {
				// 固定锚定到 cloudflared 控制器下,兼容 general/折叠等页面路径
				var v = (mInput.value || "").trim();
				var pm = v === "" ? null : parseMetrics(v);
				var port = pm && pm.ok ? pm.port : "";
				var p = location.pathname;
				var mark = "/vpn/cloudflared";
				var i = p.indexOf(mark);
				var base = i === -1 ? p : p.slice(0, i + mark.length);
				return base + "/metricsproxy?ep=" + encodeURIComponent(ep) + "&port=" + encodeURIComponent(port);
			}
			function setLinks(bool) {
				links.forEach(function(a) { a.classList.toggle("mt-on", bool); });
			}
			// 常见指标名 → 中文(未命中保持原名)
			var METRIC_ZH = {
				"build_info": "构建信息",
				"registered_tunnels": "已注册隧道数",
				"tunnel_requests_total": "隧道请求总数",
				"tunnel_active_conns": "隧道活动连接数",
				"ha_connections": "高可用连接数",
				"conn_latency": "连接延迟",
				"ca_connections": "CA 连接数",
				"process_cpu_seconds_total": "进程 CPU 时间",
				"process_resident_memory_bytes": "进程内存",
				"go_goroutines": "Go 协程数"
			};
			function translateMetricLine(ln) {
				var m = ln.match(/^([A-Za-z0-9_:]+)(\{.*\})?[ \t]+(.+)$/);
				if (!m) return ln;
				var zh = METRIC_ZH[ m[1] ];
				return zh ? (zh + (m[2] || "") + "  " + m[3]) : ln;
			}
			function escapeHtml(s) {
				return String(s == null ? "" : s)
					.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
					.replace(/"/g, "&quot;").replace(/'/g, "&#39;");
			}
			function readyStatusHtml(status) {
				if (status === 200) return '<span class="mm-badge ok">可服务</span>';
				if (status === 503) return '<span class="mm-badge warn">未就绪</span>';
				return '<span class="mm-badge err">健康状态 ' + escapeHtml(String(status)) + '</span>';
			}
			// 地址合法即可点击,点击后由代理直接读取配置返回内容或错误提示
			function update() {
				var v = (mInput.value || "").trim();
				var pm = v === "" ? { ok: false, msg: "" } : parseMetrics(v);
				if (v === "") { mTip.style.display = "none"; setLinks(false); return; }
				mTip.style.display = "block";
				mTip.textContent = pm.msg;
				mTip.className = pm.ok ? "metrics-tip ok" : "metrics-tip err";
				setLinks(pm.ok);
			}
			// 解析后端返回内容,按端点类型美化输出(不直接显示原始 JSON)
			function showResult(ep, j) {
				var title = document.getElementById("metricsUrl");
				var box = document.getElementById("metricsRaw");
				title.textContent = (j && j.url) || ep;
				var html = "";
				if (!j || !j.ok) {
					html = '<div class="mm-err"><span class="mm-badge err">获取失败</span><p>监控服务未运行或无法连接，请确认 cloudflared 已启动且指标地址正确。</p></div>';
				} else if (ep === "/ready") {
					var obj = null;
					try { obj = JSON.parse(j.body); } catch (e) { }
					if (obj) {
						html = '<div class="mm-kv">'
							+ '<div><span class="k">服务状态</span><span class="v">' + readyStatusHtml(obj.status) + '</span></div>'
							+ '<div><span class="k">活动连接数</span><span class="v"><span class="mm-badge info">' + escapeHtml(String(obj.readyConnections)) + '</span></span></div>'
							+ '<div><span class="k">连接器 ID</span><span class="v"><span class="mm-badge id">' + escapeHtml(String(obj.connectorId)) + '</span></span></div>'
							+ '</div>';
					} else {
						html = '<div class="mm-err"><span class="mm-badge err">解析失败</span><pre class="mm-pre">' + escapeHtml(j.body) + '</pre></div>';
					}
				} else if (ep === "/healthcheck") {
					var hc = (j.body || "").trim();
					var hcOK = hc === "OK";
					html = '<div class="mm-kv"><div><span class="k">健康状态</span><span class="v">'
						+ (hcOK ? '<span class="mm-badge ok">OK · 正常</span>' : '<span class="mm-badge err">异常 · ' + escapeHtml(hc) + '</span>')
						+ '</span></div></div>';
				} else { // /metrics:Prometheus 文本,指标名中译,不自动换行横向滚动
					var lines = (j.body || "").split("\n");
					var rows = lines.map(translateMetricLine);
					html = '<pre class="mm-pre">' + escapeHtml(rows.join("\n")) + '</pre>';
				}
				box.innerHTML = html;
				document.getElementById("metricsModal").style.display = "flex";
				document.body.style.overflow = "hidden";
			}
			links.forEach(function(a) {
				a.addEventListener("click", function(ev) {
					ev.preventDefault();
					var ep = a.getAttribute("data-ep") || "";
					if (!parseMetrics((mInput.value || "").trim()).ok) return;
					fetch(proxyUrl(ep), { cache: "no-store" })
						.then(function(r) { return r.json(); })
						.then(function(j) { showResult(ep, j); })
						.catch(function() { showResult(ep, null); });
				});
			});
			mInput.addEventListener("input", update);
			mInput.addEventListener("blur", update);
			update();
		}
		function closeMetricsModal() {
			document.getElementById("metricsModal").style.display = "none";
			document.body.style.overflow = "";
		}
		window.closeMetricsModal = closeMetricsModal;
	}
	if (document.readyState !== "loading") init();
	else document.addEventListener("DOMContentLoaded", init);
})();
</script>
<style>
.token-tip { display: none; font-size: 12px; line-height: 1.4; margin-top: 2px; }
.token-tip.err { color: #dc2626; }
.token-tip.ok { color: #16a34a; }
/* token 输入框:自适应宽度,窄屏随容器、宽屏封顶 720px,长 token 自动折行 */
textarea.cbi-input-textarea[name*=".token"] {
	width: min(100%, 720px);
	box-sizing: border-box;
	min-height: 76px;
	resize: vertical;
}
/* 描述里可点击的监控端点链接:服务未就绪时置灰不可点击 */
.mt-link { color: #6366f1; cursor: pointer; text-decoration: none; opacity: 0.35;
	pointer-events: none; transition: opacity .2s ease; }
.mt-link.mt-on { opacity: 1; pointer-events: auto; font-weight: 600; }
.mt-link.mt-on:hover { text-decoration: underline; }
/* 输入框下方动态注入的端点链接布局 */
.metrics-links { display: flex; gap: 16px; margin-top: 6px; }
/* 监控地址实时格式提示 */
.metrics-tip { display: none; font-size: 12px; line-height: 1.4; margin-top: 2px; }
.metrics-tip.err { color: #dc2626; }
.metrics-tip.ok { color: #16a34a; }
/* 监控结果弹窗(液态玻璃):内容区内部滚动,标题固定 */
.mmodal { display: none; position: fixed; inset: 0; z-index: 999; padding: 16px; box-sizing: border-box;
	background: rgba(0,0,0,0.45); overflow: hidden; }
.mmodal-content { margin: auto; max-width: 760px; max-height: 88vh; display: flex; flex-direction: column;
	border-radius: 14px; background: rgba(255,255,255,0.94); overflow: hidden;
	-webkit-backdrop-filter: blur(20px) saturate(180%); backdrop-filter: blur(20px) saturate(180%);
	box-shadow: 0 12px 36px rgba(0,0,0,0.20); }
.mmodal-head { display: flex; align-items: center; justify-content: space-between; gap: 10px;
	padding: 12px 16px; border-bottom: 1px solid rgba(15,23,42,0.08); flex: 0 0 auto; }
/* 内容区承接滚动,滚动条出现在弹窗内部 */
.mmodal-content #metricsRaw { flex: 1 1 auto; overflow: auto; min-height: 0; padding: 14px 16px; }
.mmodal-head span { font-size: 12px; color: #64748b; word-break: break-all; }
.mmodal-close { padding: 4px 12px; border-radius: 8px; border: none; cursor: pointer; font-weight: 700;
	background: linear-gradient(135deg, #f59e0b, #d97706); color: #fff; transition: filter .2s ease, transform .2s ease; }
.mmodal-close:hover { filter: brightness(1.08); transform: translateY(-1px); }
.mmodal-close:active { transform: scale(0.96); }
.mmodal-content pre { margin: 0; padding: 14px; overflow: auto; flex: 1; min-height: 220px;
	font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12px; line-height: 1.6;
	color: #e2e8f0; background: #14161c; white-space: pre-wrap; word-break: break-word; }
@media (prefers-color-scheme: dark) {
	.mmodal-content { background: rgba(30,34,44,0.95); }
	.mmodal-head { border-bottom-color: rgba(255,255,255,0.10); }
	.mmodal-head span { color: #94a3b8; }
}
/* 弹窗美化:状态徽章 / 键值 / 指标横滚 */
.mm-badge { display: inline-block; padding: 2px 12px; border-radius: 999px; font-size: 12px; font-weight: 700; }
.mm-badge.ok { background: rgba(16,185,129,0.15); color: #059669; }
.mm-badge.warn { background: rgba(245,158,11,0.15); color: #b45309; }
.mm-badge.err { background: rgba(239,68,68,0.16); color: #dc2626; }
.mm-badge.info { background: rgba(59,130,246,0.14); color: #2563eb; }
.mm-badge.id { background: rgba(99,102,241,0.12); color: #4f46e5;
	font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12px; }
/* 键值行:玻璃卡片式,左右分栏 */
.mm-kv { display: grid; gap: 10px; }
.mm-kv > div { display: flex; align-items: center; justify-content: space-between; gap: 14px;
	background: rgba(148,163,184,0.08); border: 1px solid rgba(148,163,184,0.16);
	padding: 10px 14px; border-radius: 10px; transition: background .2s ease; }
.mm-kv > div:hover { background: rgba(148,163,184,0.14); }
.mm-kv .k { font-size: 12px; color: #64748b; white-space: nowrap; }
.mm-kv .v { font-size: 13px; font-weight: 600; color: #334155; word-break: break-all; text-align: right; }
.mm-kv .v.mono { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12px; color: #475569; }
.mm-pre { margin: 0; font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 12px; line-height: 1.6;
	color: #1f2937; white-space: pre; overflow-x: auto; }
.mm-err { color: #dc2626; font-size: 13px; }
.mm-err p { margin: 6px 0 0; }
@media (prefers-color-scheme: dark) {
	.mm-kv .k { color: #94a3b8; }
	.mm-kv .v { color: #e2e8f0; }
	.mm-kv .v.mono { color: #cbd5e1; }
	.mm-kv > div { background: rgba(148,163,184,0.10); border-color: rgba(255,255,255,0.08); }
	.mm-kv > div:hover { background: rgba(148,163,184,0.16); }
	.mm-badge.info { color: #93c5fd; }
	.mm-badge.id { color: #a5b4fc; }
	.mm-pre { color: #e2e8f0; }
}
@media (max-width: 640px) {
	.mm-kv > div { flex-direction: column; align-items: flex-start; gap: 4px; padding: 10px 12px; }
	.mm-kv .v { text-align: left; }
}
</style>
]])
end

return a

