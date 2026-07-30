-- Copyright 2020 lwz322 <lwz322@qq.com>
-- Licensed to the public under the MIT License.
-- Multi-instance v2 by mia-clark.

local http = require "luci.http"
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local util = require "luci.util"
local fs = require "nixio.fs"

-- 查看配置文件 / 模板渲染依赖
local nfs = require "nixio.fs"
local tpl = require "luci.template"
local i18n = require "luci.i18n"

module("luci.controller.frps", package.seeall)

-- 程序管理：架构映射，复用 frpc 同款
local ARCH_MAP = {
	x86_64    = "linux_amd64",
	i386      = "linux_386",
	i686      = "linux_386",
	aarch64   = "linux_arm64",
	armv8l    = "linux_arm64",
	armv7l    = "linux_arm",
	armv6l    = "linux_arm",
	armv5l    = "linux_arm",
	mips      = "linux_mips_softfloat",
	mipsel    = "linux_mipsle_softfloat",
	mips64    = "linux_mips64",
	mips64el  = "linux_mips64le",
	riscv64   = "linux_riscv64",
}

local DEFAULT_VERSIONS = {
	"0.68.1", "0.66.0", "0.65.0", "0.64.0", "0.63.0",
	"0.62.1", "0.61.2", "0.60.0", "0.58.1", "0.52.3"
}

local FRP_VERSIONS_DIR = "/usr/share/frp/versions"

-- 程序管理：自建 GitHub Release 代理域名（key=frp-releases，前 2 个为主域名，后 5 个备用）
-- 二进制下载与版本列表都优先走这些域名；全部失败后才回退到 download_mirror + github 直连。
local FRP_DL_PROXIES = {
	"https://gh-raw.966788.xyz",   -- 主域名
	"https://gh-raw.988669.xyz",   -- 主域名
	"https://gh-raw.s03.qzz.io",   -- 备用
	"https://gh-raw.s04.qzz.io",   -- 备用
	"https://gh-raw.s05.qzz.io",   -- 备用
	"https://gh-raw.s06.qzz.io",   -- 备用
	"https://gh-raw.s07.qzz.io",   -- 备用
}

function index()
	if not nixio.fs.access("/etc/config/frps") then
		return
	end

	entry({"admin", "services", "frps"},
		firstchild(), _("Frps · 服务端")).dependent = false

	entry({"admin", "services", "frps", "common"},
		cbi("frps/common"), _("设置"), 1)

	entry({"admin", "services", "frps", "instances"},
		arcombine(cbi("frps/instances"), cbi("frps/instance-detail")),
		_("FRPS 实例"), 2).leaf = true

	entry({"admin", "services", "frps", "status"}, call("action_status"))
	entry({"admin", "services", "frps", "restart"}, call("action_restart"))
	entry({"admin", "services", "frps", "reload"}, call("action_reload"))
	entry({"admin", "services", "frps", "instance_action"}, call("action_instance_action"))
	entry({"admin", "services", "frps", "instance_admin_url"}, call("action_instance_admin_url"))
	entry({"admin", "services", "frps", "instance_copy"}, call("instance_copy")).leaf = true

	-- 程序管理
	entry({"admin", "services", "frps", "program_info"}, call("action_program_info"))
	entry({"admin", "services", "frps", "program_download"}, call("action_program_download")).leaf = true
	entry({"admin", "services", "frps", "program_progress"}, call("action_program_progress"))
	entry({"admin", "services", "frps", "program_switch"}, call("action_program_switch")).leaf = true
	entry({"admin", "services", "frps", "program_delete"}, call("action_program_delete")).leaf = true
	entry({"admin", "services", "frps", "program_refresh"}, call("action_program_refresh"))
	entry({"admin", "services", "frps", "program_save_mirror"}, call("action_program_save_mirror"))

	entry({"admin", "services", "frps", "configuration"}, call("view_conf"), _("查看 TOML 配置"), 5).leaf = true
	entry({"admin", "services", "frps", "download_toml"}, call("download_toml")).leaf = true

	entry({"admin", "services", "frps", "get_log"}, call("get_log")).leaf = true
	entry({"admin", "services", "frps", "clear_log"}, call("clear_log")).leaf = true
	entry({"admin", "services", "frps", "log"}, cbi("frps/log"), _("查看日志"), 8).leaf = true

	-- 应用自更新（与 frpc 共用 release zip：kwrt-frp-mgr-releases）
	-- order=99 让它排到最末，属于不常用功能
	entry({"admin", "services", "frps", "self_update"},
		template("frps/self_update"), _("检查更新"), 99).leaf = true
	entry({"admin", "services", "frps", "self_update_check"},    call("action_self_update_check"))
	entry({"admin", "services", "frps", "self_update_start"},    call("action_self_update_start"))
	entry({"admin", "services", "frps", "self_update_log"},      call("action_self_update_log"))
	entry({"admin", "services", "frps", "self_update_rollback"}, call("action_self_update_rollback"))
end

-- 多实例：枚举所有 instance section 并补齐运行时状态
local function _collect_instances()
	local list = {}
	uci:foreach("frps", "instance", function(s)
		local name = s[".name"]
		local toml = "/var/etc/frps/frps." .. name .. ".toml"
		local running = (sys.call("pgrep -f 'frps\\." .. name .. "\\.toml' >/dev/null") == 0)

		local web_port = tonumber(s.webServer__port or "") or nil
		local web_addr = s.webServer__addr or ""
		local web_user = s.webServer__user or ""
		local web_pass = s.webServer__password or ""
		local web_enabled = (web_port ~= nil and web_user ~= "" and web_pass ~= "")

		-- 运行层统计：仅在 webServer 配置完整时调用 frps /api/serverinfo
		local web_reachable, server_info, last_error = false, nil, ""
		if running and web_enabled then
			-- 优先用 127.0.0.1 + web_port，避免绑定地址是 0.0.0.0 时的不确定
			local probe_host = (web_addr == "" or web_addr == "0.0.0.0" or web_addr == "::") and "127.0.0.1" or web_addr
			local cmd = string.format(
				"curl -s --max-time 1 -u %q:%q http://%s:%d/api/serverinfo 2>/dev/null",
				web_user, web_pass, probe_host, web_port)
			local body = sys.exec(cmd)
			if body and body ~= "" then
				web_reachable = true
				local ok, parsed = pcall(function()
					return require("luci.jsonc").parse(body)
				end)
				if ok and type(parsed) == "table" then
					server_info = parsed
				end
			else
				last_error = "webServer 无响应"
			end
		end

		table.insert(list, {
			name = name,
			alias = s.alias or name,
			enabled = (s.enabled == "1"),
			running = running,
			bindAddr = s.bindAddr or "0.0.0.0",
			bindPort = tonumber(s.bindPort or "") or 7000,
			vhostHTTPPort = tonumber(s.vhostHTTPPort or "") or nil,
			vhostHTTPSPort = tonumber(s.vhostHTTPSPort or "") or nil,
			kcpBindPort = tonumber(s.kcpBindPort or "") or nil,
			quicBindPort = tonumber(s.quicBindPort or "") or nil,
			web_enabled = web_enabled,
			web_addr = web_addr,
			web_port = web_port,
			web_reachable = web_reachable,
			server_info = server_info,
			last_error = last_error,
		})
	end)
	return list
end

function action_status()
	local instances = _collect_instances()
	local any_running = false
	for _, ins in ipairs(instances) do
		if ins.running then any_running = true; break end
	end

	http.prepare_content("application/json")
	http.write_json({
		running = any_running,
		global_enabled = (uci:get("frps", "main", "enabled") == "1"),
		instances = instances,
	})
end

function action_restart()
	local instance = http.formvalue("instance")
	local cmd
	if instance and instance ~= "" and uci:get("frps", instance) == "instance" then
		cmd = "/etc/init.d/frps restart frps." .. instance .. " >/dev/null 2>&1"
	else
		cmd = "/etc/init.d/frps restart >/dev/null 2>&1"
	end
	local code = sys.call(cmd)
	http.prepare_content("application/json")
	http.write_json({ code = code })
end

function action_reload()
	local code = sys.call("/etc/init.d/frps reload >/dev/null 2>&1")
	http.prepare_content("application/json")
	http.write_json({ code = code })
end

function action_instance_action()
	local instance = http.formvalue("instance")
	local op       = http.formvalue("op")
	local code = 1
	local msg = "unknown op"

	if not instance or uci:get("frps", instance) ~= "instance" then
		http.prepare_content("application/json")
		http.write_json({ code = 2, message = "instance not found" })
		return
	end

	if op == "start" then
		uci:set("frps", instance, "enabled", "1")
		uci:commit("frps")
		code = sys.call("/etc/init.d/frps reload >/dev/null 2>&1")
		msg = "ok"
	elseif op == "stop" then
		uci:set("frps", instance, "enabled", "0")
		uci:commit("frps")
		code = sys.call("/etc/init.d/frps reload >/dev/null 2>&1")
		msg = "ok"
	elseif op == "restart" then
		-- 单实例重启：SIGTERM 给 procd 实例，procd 会自动 respawn
		local pname = "frps." .. instance
		code = sys.call(string.format(
			"ubus call service signal '{\"name\":\"frps\",\"instance\":\"%s\",\"signal\":15}' >/dev/null 2>&1",
			pname))
		if code ~= 0 then
			-- 兜底：reload 触发 procd diff（适用于刚改完配置的场景）
			code = sys.call("/etc/init.d/frps reload >/dev/null 2>&1")
		end
		msg = "ok"
	end

	http.prepare_content("application/json")
	http.write_json({ code = code, message = msg })
end

function action_instance_admin_url()
	local instance = http.formvalue("instance")
	if not instance or instance == "" or instance:match("[^%w_%-]") or uci:get("frps", instance) ~= "instance" then
		http.prepare_content("application/json")
		http.write_json({ url = "", port = "", message = "实例不存在" })
		return
	end

	local web_port = uci:get("frps", instance, "webServer__port")
	local web_user = uci:get("frps", instance, "webServer__user")
	local web_pass = uci:get("frps", instance, "webServer__password")
	if not web_port or web_port == "" or not web_user or web_user == "" or not web_pass or web_pass == "" then
		http.prepare_content("application/json")
		http.write_json({ url = "", port = "", message = "该实例未配置 webServer（需 端口 + 用户名 + 密码）" })
		return
	end

	local web_addr = uci:get("frps", instance, "webServer__addr") or ""
	local lan_ip = util.trim(sys.exec("uci -q get network.lan.ipaddr || ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'"))

	-- 如果 web_addr 是 0.0.0.0/空，用 LAN IP；否则用配置的
	local host = lan_ip
	if web_addr ~= "" and web_addr ~= "0.0.0.0" and web_addr ~= "::" then
		host = web_addr
	end

	local scheme = "http"
	if (uci:get("frps", instance, "webServer__tls__certFile") or "") ~= "" then
		scheme = "https"
	end

	local url = ""
	if host ~= "" then
		url = string.format("%s://%s:%s", scheme, host, web_port)
	end

	http.prepare_content("application/json")
	http.write_json({ url = url, port = web_port })
end

-- 生成稳定 instance 名（ins_<ts>_<rand>），极端兜底防同秒碰撞。
-- frps instance 不被任何 UCI 外键引用（不会像 frpc rule.server_id 那样悬空丢数据），
-- 但稳定命名可避免排序/增删后 toml 文件名、防火墙规则 frps_<sid>_*_auto 跟着漂移留孤儿。
local function _stable_ins()
	local id = string.format("ins_%d_%d", os.time(), math.random(1000, 9999))
	for _ = 1, 5 do
		if not uci:get("frps", id) then break end
		id = string.format("ins_%d_%d", os.time(), math.random(1000, 9999))
	end
	return id
end

-- 复制实例
function instance_copy(sid)
	local dsp = require "luci.dispatcher"
	local list_url = dsp.build_url("admin/services/frps/instances")

	if not sid or sid == "" or uci:get("frps", sid) ~= "instance" then
		http.redirect(list_url)
		return
	end

	local src = uci:get_all("frps", sid)
	if not src then
		http.redirect(list_url)
		return
	end

	-- 稳定命名，绝不用 uci:add 产生匿名 cfgXXXXXX
	local new_sid = _stable_ins()
	uci:set("frps", new_sid, "instance")
	if not new_sid then
		http.redirect(list_url)
		return
	end

	for k, v in pairs(src) do
		if k:sub(1, 1) ~= "." then
			if type(v) == "table" then
				uci:set_list("frps", new_sid, k, v)
			else
				uci:set("frps", new_sid, k, v)
			end
		end
	end

	local original = src.alias or ""
	uci:set("frps", new_sid, "alias", original .. "_copy")
	-- 复制后默认禁用，避免端口冲突
	uci:set("frps", new_sid, "enabled", "0")

	uci:save("frps")
	uci:commit("frps")

	http.redirect(dsp.build_url("admin/services/frps/instances/" .. new_sid))
end

-- ────────────────────────────────────────────────────────────────
-- 程序管理 actions（与 frpc 同款，仅 binary 名 frpc → frps）
-- ────────────────────────────────────────────────────────────────

local function _valid_version(v)
	return v and type(v) == "string" and v:match("^[0-9]+%.[0-9]+%.[0-9]+$") ~= nil
end

-- 文件替换模型下，「当前版本」 = /usr/bin/frps -v 的输出。
-- 用版本字符串比对，而不是路径比对（路径恒为 /usr/bin/frps）。
local function _scan_downloaded(current_version)
	local list = {}
	if not fs.stat(FRP_VERSIONS_DIR) then return list end
	for entry in fs.dir(FRP_VERSIONS_DIR) do
		if _valid_version(entry) then
			local path = FRP_VERSIONS_DIR .. "/" .. entry .. "/frps"
			if fs.access(path) then
				table.insert(list, {
					version = entry,
					path = path,
					is_current = (current_version ~= "" and entry == current_version)
				})
			end
		end
	end
	table.sort(list, function(a, b) return a.version > b.version end)
	return list
end

-- 自愈：清理所有指向「不存在文件」或「被删除版本目录」的 client_file 字段。
-- 同时统一清理 frps.main.client_file 这种历史遗留字段（main 不该有 client_file）。
-- 返回修复明细数组，供调用者写日志或回前端。
local function _heal_client_paths(removed_version)
	local healed = {}
	local fallback = "/usr/bin/frps"

	local function is_bad(p)
		if not p or p == "" then return true end
		if removed_version and p:match("/versions/" .. removed_version:gsub("%.", "%%.") .. "/") then
			return true
		end
		return not fs.access(p)
	end

	-- main.default_client_file → 强制有效
	local default = uci:get("frps", "main", "default_client_file") or ""
	if is_bad(default) then
		uci:set("frps", "main", "default_client_file", fallback)
		table.insert(healed, "main.default_client_file: " .. default .. " → " .. fallback)
	end

	-- main.client_file 是历史遗留字段（main 是全局节，不应该有 client_file），直接删
	if uci:get("frps", "main", "client_file") then
		uci:delete("frps", "main", "client_file")
		table.insert(healed, "main.client_file: removed (legacy field)")
	end

	-- 每个 instance.client_file：失效则删除（让 init.d 走 fallback 链）
	uci:foreach("frps", "instance", function(s)
		local cf = s.client_file
		if cf and cf ~= "" and is_bad(cf) then
			uci:delete("frps", s[".name"], "client_file")
			table.insert(healed, s[".name"] .. ".client_file: " .. cf .. " → (inherit default)")
		end
	end)

	if #healed > 0 then uci:commit("frps") end
	return healed
end

function action_program_info()
	local arch_raw = util.trim(sys.exec("uname -m 2>/dev/null"))
	local frp_platform = ARCH_MAP[arch_raw] or ""

	-- 每次打开程序管理页都自愈一次，确保 uci 跟磁盘一致
	local healed = _heal_client_paths()

	local current_file = uci:get("frps", "main", "default_client_file") or ""
	local current_version = ""
	if current_file ~= "" and fs.access(current_file) then
		local out = util.trim(sys.exec(util.shellquote(current_file) .. " -v 2>/dev/null"))
		current_version = out
	end

	local mirror = uci:get("frps", "main", "download_mirror") or ""

	http.prepare_content("application/json")
	http.write_json({
		arch_raw = arch_raw,
		frp_platform = frp_platform,
		arch_supported = (frp_platform ~= ""),
		current_file = current_file,
		current_version = current_version,
		downloaded = _scan_downloaded(current_version),
		mirror = mirror,
		default_versions = DEFAULT_VERSIONS,
		healed = healed,
	})
end

function action_program_download(version)
	http.prepare_content("application/json")

	if not _valid_version(version) then
		http.write_json({ok = false, error = "无效版本号格式"})
		return
	end

	local arch_raw = util.trim(sys.exec("uname -m 2>/dev/null"))
	local platform = ARCH_MAP[arch_raw]
	if not platform then
		http.write_json({ok = false, error = "不支持的架构: " .. arch_raw})
		return
	end

	local target_dir = FRP_VERSIONS_DIR .. "/" .. version
	local status_file = "/tmp/frps_dl_" .. version .. ".json"
	local tmp_archive = "/tmp/frps_dl_" .. version .. ".tar.gz"
	local tmp_unpack = "/tmp/frps_dl_" .. version .. "_unpack"
	local script_file = "/tmp/frps_dl_" .. version .. ".sh"

	if fs.access(target_dir .. "/frps") then
		http.write_json({ok = false, error = "已下载该版本", already = true})
		return
	end
	if fs.access(status_file) then
		http.write_json({ok = true, status = "in_progress"})
		return
	end

	local mirror = uci:get("frps", "main", "download_mirror") or ""
	local asset = "frp_" .. version .. "_" .. platform .. ".tar.gz"

	-- 候选下载源：先 7 个代理域名，全部失败后回退到 download_mirror + github 官方直链
	local urls = {}
	for _, base in ipairs(FRP_DL_PROXIES) do
		urls[#urls + 1] = base .. "/frp-releases/v" .. version .. "/" .. asset
	end
	urls[#urls + 1] = mirror .. "https://github.com/fatedier/frp/releases/download/v" ..
		version .. "/" .. asset
	-- 用空格连接（URL 不含空格），交给 shell 默认 IFS 切分；不能用换行，
	-- 因为 %q 会把换行转义成「反斜杠+换行」，在 sh 双引号内会被当作续行吞掉。
	local url_list = table.concat(urls, " ")

	-- 后台下载脚本：逐个尝试候选源，任一成功即停
	local script = string.format([=[#!/bin/sh
STATUS=%q
TMP=%q
UNPACK=%q
URLS=%q
TARGET=%q

write_status() {
	echo "{\"stage\":\"$1\",\"size\":${2:-0},\"message\":\"${3:-}\"}" > "$STATUS"
}

cleanup_tmp() {
	rm -rf "$TMP" "$UNPACK"
}

write_status downloading 0
mkdir -p "$TARGET"

DL_OK=0
for U in $URLS; do
	[ -z "$U" ] && continue
	HOST=$(echo "$U" | sed -e 's,^https*://,,' -e 's,/.*,,')
	write_status downloading 0 "$HOST"
	wget -q --no-check-certificate -O "$TMP" "$U"
	if [ $? -eq 0 ] && [ -s "$TMP" ]; then
		DL_OK=1
		break
	fi
	rm -f "$TMP"
done

if [ "$DL_OK" -ne 1 ]; then
	write_status error 0 "全部下载源失败"
	cleanup_tmp
	rm -rf "$TARGET"
	(sleep 30; rm -f "$STATUS") &
	exit 1
fi

write_status extracting "$(wc -c < "$TMP" 2>/dev/null)"
mkdir -p "$UNPACK"
tar -xzf "$TMP" -C "$UNPACK" 2>/dev/null

FRPS_SRC=$(find "$UNPACK" -type f -name frps 2>/dev/null | head -1)
if [ -z "$FRPS_SRC" ]; then
	write_status error 0 "解压成功但未找到 frps 二进制"
	cleanup_tmp
	rm -rf "$TARGET"
	(sleep 30; rm -f "$STATUS") &
	exit 1
fi

cp -f "$FRPS_SRC" "$TARGET/frps"
chmod 755 "$TARGET/frps"
cleanup_tmp

DETECTED=$("$TARGET/frps" -v 2>/dev/null)
write_status done "$(wc -c < "$TARGET/frps" 2>/dev/null)" "$DETECTED"

(sleep 30; rm -f "$STATUS") &
]=], status_file, tmp_archive, tmp_unpack, url_list, target_dir)

	fs.writefile(script_file, script)
	sys.call("chmod +x " .. util.shellquote(script_file))
	sys.call("setsid sh -c " .. util.shellquote(
		"(" .. script_file .. " </dev/null >/dev/null 2>&1; rm -f " .. script_file .. ") &"
	) .. " >/dev/null 2>&1")

	http.write_json({ok = true, status = "started", version = version})
end

function action_program_progress()
	http.prepare_content("application/json")
	local version = http.formvalue("version")
	if not version or not _valid_version(version) then
		http.write_json({ok = false, error = "无效版本号"})
		return
	end

	local status_file = "/tmp/frps_dl_" .. version .. ".json"
	local tmp_archive = "/tmp/frps_dl_" .. version .. ".tar.gz"
	local target_dir = FRP_VERSIONS_DIR .. "/" .. version

	if not fs.access(status_file) then
		if fs.access(target_dir .. "/frps") then
			http.write_json({ok = true, stage = "done", size = 0})
		else
			http.write_json({ok = true, stage = "idle", size = 0})
		end
		return
	end

	local content = fs.readfile(status_file) or "{}"
	local ok_json, parsed = pcall(function() return require("luci.jsonc").parse(content) end)
	if not ok_json or type(parsed) ~= "table" then
		http.write_json({ok = true, stage = "unknown"})
		return
	end

	if parsed.stage == "downloading" then
		local stat = nixio.fs.stat(tmp_archive)
		if stat then parsed.size = stat.size end
	end

	http.write_json({
		ok = true,
		stage = parsed.stage,
		size = parsed.size or 0,
		message = parsed.message,
	})
end

-- 文件替换模型：把 /usr/share/frp/versions/<v>/frps 物理覆盖到 /usr/bin/frps。
-- 通过 cp→.new → mv（rename(2)） 完成原子替换，避免 ETXTBSY（运行中的旧 inode 不变）。
-- 不再修改 uci.default_client_file，彻底消除「路径指向被删版本目录」的整类 bug。
function action_program_switch(version)
	http.prepare_content("application/json")

	if not _valid_version(version) then
		http.write_json({ok = false, error = "无效版本号"})
		return
	end

	local src = FRP_VERSIONS_DIR .. "/" .. version .. "/frps"
	if not fs.access(src) then
		http.write_json({ok = false, error = "该版本未下载"})
		return
	end

	local target = "/usr/bin/frps"
	local tmp = target .. ".new"

	local cmd = string.format(
		"cp -f %s %s && chmod 755 %s && mv -f %s %s",
		util.shellquote(src), util.shellquote(tmp),
		util.shellquote(tmp),
		util.shellquote(tmp), util.shellquote(target)
	)
	local rc = sys.call(cmd .. " >/dev/null 2>&1")
	if rc ~= 0 then
		sys.call("rm -f " .. util.shellquote(tmp) .. " >/dev/null 2>&1")
		http.write_json({ok = false, error = "替换 " .. target .. " 失败（rc=" .. tostring(rc) .. "）"})
		return
	end

	-- 防御性：把 default_client_file 锁回 /usr/bin/frps（uci-defaults 也会兜底）
	if uci:get("frps", "main", "default_client_file") ~= target then
		uci:set("frps", "main", "default_client_file", target)
		uci:commit("frps")
	end

	sys.call("/etc/init.d/frps restart >/dev/null 2>&1")

	http.write_json({
		ok = true,
		version = version,
		path = target,
	})
end

function action_program_delete(version)
	http.prepare_content("application/json")

	if not _valid_version(version) then
		http.write_json({ok = false, error = "无效版本号"})
		return
	end

	-- 文件替换模型下，「当前」 = /usr/bin/frps -v 的版本字符串
	local current_bin = uci:get("frps", "main", "default_client_file") or "/usr/bin/frps"
	local current_version = ""
	if fs.access(current_bin) then
		current_version = util.trim(sys.exec(util.shellquote(current_bin) .. " -v 2>/dev/null"))
	end
	if current_version ~= "" and current_version == version then
		http.write_json({ok = false, error = "不能删除当前运行中的版本，请先切换到其他版本"})
		return
	end

	local target_dir = FRP_VERSIONS_DIR .. "/" .. version
	sys.call("rm -rf " .. util.shellquote(target_dir))

	-- 兜底清理：万一历史上有 instance.client_file 指向版本目录
	local healed = _heal_client_paths(version)
	http.write_json({ok = true, healed = healed})
end

function action_program_refresh()
	http.prepare_content("application/json")

	local user_mirror = uci:get("frps", "main", "download_mirror") or ""
	local api_path = "https://api.github.com/repos/fatedier/frp/releases?per_page=20"

	local candidates = {}
	-- 1. 优先：自建代理的版本列表接口（与二进制下载同源，返回 {"releases":[{"tag":"vX"}...]}）
	for _, base in ipairs(FRP_DL_PROXIES) do
		table.insert(candidates, base .. "/frp-releases?per_page=20")
	end
	-- 2. 回退：用户配置的 download_mirror
	if user_mirror ~= "" then
		table.insert(candidates, user_mirror .. api_path)
	end
	-- 3. 回退：内置的已知 API 兼容镜像
	table.insert(candidates, api_path)
	table.insert(candidates, "https://gh-proxy.com/" .. api_path)
	table.insert(candidates, "https://edge-proxy.srv1.qzz.io/" .. api_path)
	table.insert(candidates, "https://edge-proxy.srv0.qzz.io/" .. api_path)
	table.insert(candidates, "https://edge-proxy.988669.xyz/" .. api_path)
	table.insert(candidates, "https://edge-proxy.966788.xyz/" .. api_path)
	table.insert(candidates, "https://gh.api.99988866.xyz/" .. api_path)
	table.insert(candidates, "https://gh-proxy.net/" .. api_path)

	local body, hit_url
	local errors = {}
	for _, url in ipairs(candidates) do
		local cmd = "wget -T 8 -q -O - --no-check-certificate " ..
			util.shellquote(url) .. " 2>/dev/null"
		local resp = sys.exec(cmd)
		-- 代理返回含 "tag"，github API 返回含 "tag_name"，两者都接受
		if resp and #resp > 100 and (resp:find('"tag_name"') or resp:find('"tag"')) then
			body = resp
			hit_url = url
			break
		else
			local short_host = url:gsub("^https?://([^/]+).*", "%1")
			table.insert(errors, short_host .. "(" .. #(resp or "") .. "b)")
		end
	end

	if not body then
		http.write_json({
			ok = false,
			error = "全部 API 镜像不可达。已尝试: " .. table.concat(errors, " · ") ..
			        "。建议在「下载镜像前缀」填入支持 api.github.com 的镜像，如 https://gh.api.99988866.xyz/"
		})
		return
	end

	local versions = {}
	local seen = {}
	-- github API 字段为 tag_name，自建代理字段为 tag；优先解析 tag_name，无果再解析 tag
	for tag in body:gmatch('"tag_name"%s*:%s*"v?([0-9.]+)"') do
		if not seen[tag] and _valid_version(tag) then
			seen[tag] = true
			table.insert(versions, tag)
		end
	end
	if #versions == 0 then
		for tag in body:gmatch('"tag"%s*:%s*"v?([0-9.]+)"') do
			if not seen[tag] and _valid_version(tag) then
				seen[tag] = true
				table.insert(versions, tag)
			end
		end
	end

	if #versions == 0 then
		http.write_json({ok = false, error = "解析 GitHub 响应失败，无版本"})
		return
	end

	http.write_json({
		ok = true,
		versions = versions,
		hit_url = hit_url,
	})
end

function action_program_save_mirror()
	http.prepare_content("application/json")
	local m = http.formvalue("mirror") or ""

	if m ~= "" and not m:match("^https?://") then
		http.write_json({ok = false, error = "镜像前缀必须以 http:// 或 https:// 开头"})
		return
	end

	uci:set("frps", "main", "download_mirror", m)
	uci:commit("frps")
	http.write_json({ok = true, mirror = m})
end

-- ────────────────────────────────────────────────────────────────
-- TOML 配置查看 / 下载
-- ────────────────────────────────────────────────────────────────

function view_conf()
	local sel = http.formvalue("instance")
	if sel and sel:match("[^%w_%-]") then sel = nil end

	local target_name = nil
	if sel and sel ~= "" and uci:get("frps", sel) == "instance" then
		target_name = sel
	end
	if not target_name then
		uci:foreach("frps", "instance", function(s)
			if s.enabled == "1" then
				target_name = s[".name"]
				return false
			end
		end)
	end
	if not target_name then
		uci:foreach("frps", "instance", function(s)
			target_name = s[".name"]
			return false
		end)
	end

	local instances = {}
	uci:foreach("frps", "instance", function(s)
		instances[#instances+1] = { s[".name"], s.alias or s[".name"] }
	end)

	local target_toml = target_name and ("/var/etc/frps/frps." .. target_name .. ".toml") or ""
	local content = nfs.readfile(target_toml) or ""
	tpl.render("frps/file_viewer", {
		title = i18n.translate("Frps - 查看配置文件"),
		content = content,
		toml_path = target_toml,
		current_instance = target_name or "",
		instances = instances,
	})
end

function download_toml()
	local sel = http.formvalue("instance")
	if sel and sel:match("[^%w_%-]") then sel = nil end
	if not sel or sel == "" or uci:get("frps", sel) ~= "instance" then
		http.status(404, "Not Found")
		http.prepare_content("text/plain; charset=utf-8")
		http.write("instance not found")
		return
	end

	local toml_path = "/var/etc/frps/frps." .. sel .. ".toml"
	local content = fs.readfile(toml_path)
	if not content or content == "" then
		http.status(404, "Not Found")
		http.prepare_content("text/plain; charset=utf-8")
		http.write("toml not generated yet, enable the instance and save first")
		return
	end

	local alias = uci:get("frps", sel, "alias") or sel
	local ascii_name = alias:gsub("[^%w%-_%.]", "_"):gsub("_+", "_")
	if ascii_name == "" or ascii_name == "_" then ascii_name = sel end
	local fallback = "frps." .. ascii_name .. ".toml"
	local utf8_raw = "frps." .. alias .. ".toml"
	local utf8_encoded = utf8_raw:gsub("[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)

	http.header("Content-Disposition",
		'attachment; filename="' .. fallback .. '"; filename*=UTF-8\'\'' .. utf8_encoded)
	http.prepare_content("application/toml; charset=utf-8")
	http.write(content)
end

-- ────────────────────────────────────────────────────────────────
-- 日志
-- ────────────────────────────────────────────────────────────────

local function _resolve_log_link(instance)
	if instance and instance ~= "" then
		if instance:match("[^%w_%-]") then
			instance = ""
		end
	end
	if instance and instance ~= "" then
		return "/tmp/frps_log_" .. instance .. ".txt"
	end
	local default_link = "/tmp/frps_log_link.txt"
	uci:foreach("frps", "instance", function(s)
		if s.enabled == "1" then
			default_link = "/tmp/frps_log_" .. s[".name"] .. ".txt"
			return false
		end
	end)
	return default_link
end

function get_log()
	local instance = http.formvalue("instance")
	local link = _resolve_log_link(instance)
	luci.http.write(luci.sys.exec("tail -c 200000 " .. link .. " 2>/dev/null"))
end

function clear_log()
	local instance = http.formvalue("instance")
	local link = _resolve_log_link(instance)
	luci.sys.call("true > " .. link)
end

-- ─────────────────────────────────────────────────────────────────
-- 应用自更新（luci-app-frps 自身升级）
-- 数据源：自建代理的 /kwrt-frp-mgr-releases/{latest|tag} 接口
-- 资产命名：luci-app-frp-<ver>-IPK-22.03.zip / -APK-SNAPSHOT.zip
--   zip 内含 luci-app-frpc_*.ipk 和 luci-app-frps_*.ipk
--   本侧仅升级 luci-app-frps（按"装了哪个升级哪个"原则）
-- ─────────────────────────────────────────────────────────────────

local SELF_UPDATE_PKG  = "luci-app-frps"
local SELF_UPDATE_TAG  = "frps"  -- 区分 frpc/frps 状态文件，避免互相覆盖
local SELF_UPDATE_LOG  = "/tmp/" .. SELF_UPDATE_TAG .. "_self_update.log"
local SELF_UPDATE_STAT = "/tmp/" .. SELF_UPDATE_TAG .. "_self_update.json"

-- 与 program 模块共用代理域名列表（FRP_DL_PROXIES 已在文件顶部定义）
local function _self_update_get_installed_version()
	-- opkg list-installed 输出：  luci-app-frps - 1.2.8
	local out = util.trim(sys.exec("opkg list-installed " .. SELF_UPDATE_PKG .. " 2>/dev/null"))
	local v = out:match("%-%s+([%w%.%-]+)$")
	return v or ""
end

-- 用代理列表逐个尝试 GET 一段 JSON，返回响应文本
local function _self_update_fetch_json(path)
	for _, base in ipairs(FRP_DL_PROXIES) do
		local url = base .. path
		local cmd = "wget -T 8 -q -O - --no-check-certificate " ..
			util.shellquote(url) .. " 2>/dev/null"
		local resp = sys.exec(cmd)
		if resp and #resp > 20 and resp:find('"tag"') then
			return resp, base
		end
	end
	return nil, nil
end

-- semver 比较：a > b 返回正数，相等 0，小于负数；非 semver 直接字符串比
local function _semver_cmp(a, b)
	local function parts(s)
		local t = {}
		for n in s:gmatch("(%d+)") do t[#t+1] = tonumber(n) end
		return t
	end
	local pa, pb = parts(a or ""), parts(b or "")
	local n = math.max(#pa, #pb)
	for i = 1, n do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then return x - y end
	end
	return 0
end

function action_self_update_check()
	http.prepare_content("application/json")
	local resp = _self_update_fetch_json("/kwrt-frp-mgr-releases/latest")
	if not resp then
		http.write_json({ok = false, error = "无法从代理拉取最新版本信息"})
		return
	end
	local tag       = resp:match('"tag"%s*:%s*"([^"]+)"') or ""
	local name      = resp:match('"name"%s*:%s*"([^"]+)"') or tag
	local published = resp:match('"published_at"%s*:%s*"([^"]+)"') or ""
	local body      = ""
	local ok, parsed = pcall(function() return require("luci.jsonc").parse(resp) end)
	if ok and type(parsed) == "table" then
		tag       = parsed.tag or tag
		name      = parsed.name or name
		published = parsed.published_at or published
		body      = parsed.body or ""
	end

	local installed = _self_update_get_installed_version()
	local latest    = (tag or ""):gsub("^v", "")
	local has_update = (installed ~= "" and latest ~= "" and _semver_cmp(latest, installed) > 0)

	-- 找到匹配 ipk 资产（不含 -APK-）
	local asset_url, asset_name, asset_size
	if ok and type(parsed) == "table" and type(parsed.assets) == "table" then
		for _, a in ipairs(parsed.assets) do
			if type(a) == "table" and a.name and not a.name:match("APK") then
				asset_url, asset_name, asset_size = a.download, a.name, a.size
				break
			end
		end
	end

	-- 检测对方 LuCI 应用是否安装（用于「回首页」按钮的可见性控制）
	local peer_pkg = (SELF_UPDATE_PKG == "luci-app-frpc") and "luci-app-frps" or "luci-app-frpc"
	local peer_out = util.trim(sys.exec("opkg list-installed " .. peer_pkg .. " 2>/dev/null"))
	local peer_installed = (peer_out ~= "")

	http.write_json({
		ok = true,
		installed_version = installed,
		latest_version    = latest,
		latest_tag        = tag,
		latest_name       = name,
		published_at      = published,
		has_update        = has_update,
		body              = body or "",
		peer_installed    = peer_installed,
		asset = (asset_url and {
			name = asset_name, size = asset_size, url = asset_url,
		} or nil),
	})
end

function action_self_update_start()
	http.prepare_content("application/json")
	local tag = http.formvalue("tag") or ""
	if not tag:match("^v[0-9][0-9%.]*$") then
		http.write_json({ok = false, error = "无效 tag"})
		return
	end

	if fs.access(SELF_UPDATE_STAT) then
		local content = fs.readfile(SELF_UPDATE_STAT) or "{}"
		local ok2, parsed2 = pcall(function() return require("luci.jsonc").parse(content) end)
		if ok2 and type(parsed2) == "table"
		   and parsed2.stage ~= "done" and parsed2.stage ~= "error" then
			http.write_json({ok = true, status = "in_progress"})
			return
		end
	end

	local installed = _self_update_get_installed_version()

	local ver = tag:gsub("^v", "")
	local asset = "luci-app-frp-" .. ver .. "-IPK-22.03.zip"
	local urls = {}
	for _, base in ipairs(FRP_DL_PROXIES) do
		urls[#urls+1] = base .. "/kwrt-frp-mgr-releases/" .. tag .. "/" .. asset
	end
	local url_list = table.concat(urls, " ")

	local workdir     = "/tmp/" .. SELF_UPDATE_TAG .. "_upd"
	local zip_file    = workdir .. "/" .. asset
	local backup_dir  = "/tmp/" .. SELF_UPDATE_TAG .. "_upd_backup"
	local script_file = "/tmp/" .. SELF_UPDATE_TAG .. "_upd.sh"

	sys.call("rm -f " .. util.shellquote(SELF_UPDATE_LOG) .. " " .. util.shellquote(SELF_UPDATE_STAT))

	local script = string.format([=[#!/bin/sh
LOG=%q
STAT=%q
URLS=%q
WORKDIR=%q
ZIP=%q
BACKUP=%q
PKG=%q
INSTALLED=%q
TAG=%q

log() { echo "[$(date '+%%H:%%M:%%S')] $*" >> "$LOG"; }
state() { printf '{"stage":"%%s","pct":%%s,"message":"%%s"}' "$1" "${2:-0}" "${3:-}" > "$STAT"; }

mkdir -p "$WORKDIR" "$BACKUP"
: > "$LOG"
state preparing 0 "准备升级 $PKG $INSTALLED -> $TAG"
log "===== 自更新开始 ====="
log "当前版本: $INSTALLED"
log "目标版本: $TAG"
log "目标资产: $(basename "$ZIP")"

# ---------- 1) 备份当前版本元数据 ----------
log "[1/5] 备份当前版本元数据..."
echo "$INSTALLED" > "$BACKUP/installed_version"
opkg files "$PKG" > "$BACKUP/files.list" 2>/dev/null
log "  备份位置: $BACKUP"

# ---------- 2) 下载 zip ----------
state downloading 10 "正在下载升级包..."
log "[2/5] 下载升级包..."
DL_OK=0
for U in $URLS; do
	[ -z "$U" ] && continue
	HOST=$(echo "$U" | sed -e 's,^https*://,,' -e 's,/.*,,')
	log "  尝试: $HOST"
	state downloading 15 "$HOST"
	wget -q --no-check-certificate -O "$ZIP" "$U"
	if [ $? -eq 0 ] && [ -s "$ZIP" ]; then
		log "  ✓ 下载成功 ($(wc -c < "$ZIP") 字节)"
		DL_OK=1
		break
	fi
	log "  ✗ 失败"
	rm -f "$ZIP"
done
if [ "$DL_OK" -ne 1 ]; then
	log "❌ 全部下载源失败"
	state error 100 "全部下载源失败"
	exit 1
fi

# ---------- 3) 解压 ----------
state extracting 40 "解压中..."
log "[3/5] 解压 zip..."
if ! command -v unzip >/dev/null 2>&1; then
	log "❌ 系统缺少 unzip，请先安装：opkg install unzip"
	state error 100 "缺少 unzip"
	exit 1
fi
cd "$WORKDIR" || exit 1
unzip -o "$ZIP" >> "$LOG" 2>&1
IPK=$(find "$WORKDIR" -type f -name "${PKG}_*.ipk" | head -1)
if [ -z "$IPK" ]; then
	log "❌ 解压后未找到 $PKG ipk 文件"
	log "  目录内容: $(ls -la "$WORKDIR")"
	state error 100 "未找到 ipk 文件"
	exit 1
fi
log "  找到: $IPK"

# ---------- 4) opkg install ----------
state installing 70 "正在安装新版本..."
log "[4/5] opkg install --force-reinstall ..."
opkg install --force-reinstall "$IPK" >> "$LOG" 2>&1
OPKG_EXIT=$?
if [ $OPKG_EXIT -ne 0 ]; then
	log "❌ opkg install 失败 (exit=$OPKG_EXIT)"
	state error 100 "opkg install 失败 (exit=$OPKG_EXIT)，可用回滚按钮恢复"
	exit 1
fi
log "  ✓ 安装完成"

# ---------- 5) 重启 LuCI 让新 controller 生效 ----------
state restarting 95 "正在重启 LuCI 服务..."
log "[5/5] 重启 rpcd + nginx（页面会暂时打不开，重新刷新即可）..."
rm -rf /tmp/luci-modulecache/* /tmp/luci-indexcache* 2>/dev/null

state done 100 "升级成功，请刷新页面"
log "✅ 升级完成（新版本: $TAG）"
log "===== 自更新结束 ====="

(
	sleep 2
	/etc/init.d/rpcd restart >/dev/null 2>&1
	/etc/init.d/nginx restart >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1
) &

sleep 5
rm -rf "$WORKDIR" "$ZIP" 2>/dev/null
(sleep 60; rm -f "$STAT") &
]=],
		SELF_UPDATE_LOG, SELF_UPDATE_STAT, url_list, workdir, zip_file,
		backup_dir, SELF_UPDATE_PKG, installed, tag)

	fs.writefile(script_file, script)
	sys.call("chmod +x " .. util.shellquote(script_file))
	sys.call("setsid sh -c " .. util.shellquote(
		"(" .. script_file .. " </dev/null >/dev/null 2>&1; rm -f " .. script_file .. ") &"
	) .. " >/dev/null 2>&1")

	http.write_json({ok = true, status = "started", tag = tag, installed = installed})
end

function action_self_update_log()
	http.prepare_content("application/json")

	local stage, pct, message = "idle", 0, ""
	if fs.access(SELF_UPDATE_STAT) then
		local content = fs.readfile(SELF_UPDATE_STAT) or "{}"
		local ok, parsed = pcall(function() return require("luci.jsonc").parse(content) end)
		if ok and type(parsed) == "table" then
			stage   = parsed.stage or "unknown"
			pct     = parsed.pct or 0
			message = parsed.message or ""
		end
	end

	local log = ""
	if fs.access(SELF_UPDATE_LOG) then
		log = util.trim(sys.exec("tail -n 40 " .. util.shellquote(SELF_UPDATE_LOG) .. " 2>/dev/null"))
	end

	http.write_json({
		ok      = true,
		stage   = stage,
		pct     = pct,
		message = message,
		log     = log,
	})
end

function action_self_update_rollback()
	http.prepare_content("application/json")
	local backup_dir = "/tmp/" .. SELF_UPDATE_TAG .. "_upd_backup"
	local ver_file   = backup_dir .. "/installed_version"
	if not fs.access(ver_file) then
		http.write_json({ok = false, error = "未找到备份元数据，无法自动回滚"})
		return
	end
	local old_ver = util.trim(fs.readfile(ver_file) or "")
	if old_ver == "" then
		http.write_json({ok = false, error = "备份内的版本号为空"})
		return
	end
	http.write_json({ok = true, rollback_to = "v" .. old_ver,
		hint = "请用 tag=v" .. old_ver .. " 调 self_update_start"})
end
