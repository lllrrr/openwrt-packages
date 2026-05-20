-- Copyright 2019 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the MIT License.

local http = require "luci.http"
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local util = require "luci.util"
local fs = require "nixio.fs"

-- 查看配置文件所需
local e=require"nixio.fs"
local t=require"luci.sys"
local a=require"luci.template"
local t=require"luci.i18n"

module("luci.controller.frpc", package.seeall)

-- 程序管理：OpenWrt/Linux arch → frp release 后缀映射
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

-- 程序管理：硬编码的可下载版本（按新到旧，最低 0.52.0 因 TOML 配置）
local DEFAULT_VERSIONS = {
	"0.68.1", "0.66.0", "0.65.0", "0.64.0", "0.63.0",
	"0.62.1", "0.61.2", "0.60.0", "0.58.1", "0.52.3"
}

local FRP_VERSIONS_DIR = "/usr/share/frp/versions"

function index()
	if not nixio.fs.access("/etc/config/frpc") then
		return
	end

	entry({"admin", "services", "frpc"},
		firstchild(), _("Frpc")).dependent = false

	entry({"admin", "services", "frpc", "common"},
		cbi("frpc/common"), _("设置"), 1)

	entry({"admin", "services", "frpc", "rules"},
		arcombine(cbi("frpc/rules"), cbi("frpc/rule-detail")),
		_("代理规则"), 2).leaf = true

	entry({"admin", "services", "frpc", "servers"},
		arcombine(cbi("frpc/servers"), cbi("frpc/server-detail")),
		_("FRPS 服务器"), 3).leaf = true

	entry({"admin", "services", "frpc", "status"}, call("action_status"))
	entry({"admin", "services", "frpc", "restart"}, call("action_restart"))
	entry({"admin", "services", "frpc", "reload"}, call("action_reload"))
	entry({"admin", "services", "frpc", "instance_action"}, call("action_instance_action"))
	entry({"admin", "services", "frpc", "instance_admin_url"}, call("action_instance_admin_url"))

	entry({"admin", "services", "frpc", "rule_copy"}, call("rule_copy")).leaf = true
	entry({"admin", "services", "frpc", "server_copy"}, call("server_copy")).leaf = true

	-- 程序管理
	entry({"admin", "services", "frpc", "program_info"}, call("action_program_info"))
	entry({"admin", "services", "frpc", "program_download"}, call("action_program_download")).leaf = true
	entry({"admin", "services", "frpc", "program_progress"}, call("action_program_progress"))
	entry({"admin", "services", "frpc", "program_switch"}, call("action_program_switch")).leaf = true
	entry({"admin", "services", "frpc", "program_delete"}, call("action_program_delete")).leaf = true
	entry({"admin", "services", "frpc", "program_refresh"}, call("action_program_refresh"))
	entry({"admin", "services", "frpc", "program_save_mirror"}, call("action_program_save_mirror"))

	entry({"admin", "services", "frpc", "rule_batch_set_server"}, call("action_rule_batch_set_server"))

	entry({"admin", "services", "frpc", "configuration"}, call("view_conf"), _("查看 TOML 配置"), 5).leaf = true
	entry({"admin", "services", "frpc", "download_toml"}, call("download_toml")).leaf = true
	
	entry({"admin", "services", "frpc", "get_log"}, call("get_log")).leaf = true
	entry({"admin", "services", "frpc", "clear_log"}, call("clear_log")).leaf = true
	entry({"admin", "services", "frpc", "log"}, cbi("frpc/log"), _("查看日志"), 8).leaf = true
end

-- 多实例：枚举所有 server section 并补齐运行时状态
local function _collect_instances()
	local list = {}
	uci:foreach("frpc", "server", function(s)
		local name = s[".name"]
		local toml = "/var/etc/frpc/frpc." .. name .. ".toml"
		-- pgrep 用 ERE 正则，\. 表示字面 . （Lua 中 \\ 转义为 \）
		local running = (sys.call("pgrep -f 'frpc\\." .. name .. "\\.toml' >/dev/null") == 0)
		local admin_port_raw = util.trim(sys.exec("cat /var/run/frpc/" .. name .. ".admin_port 2>/dev/null"))
		local admin_port = tonumber(admin_port_raw) or nil

		-- 配置层统计：从 UCI 按 server_id 过滤 rule，区分 proxy / visitor
		local proxies_total, visitors_total = 0, 0
		uci:foreach("frpc", "rule", function(r)
			if r.server_id == name and r.enabled == "1" then
				if r.visitor == "1" then
					visitors_total = visitors_total + 1
				else
					proxies_total = proxies_total + 1
				end
			end
		end)

		-- 运行层统计：proxies_online 来自 frpc admin /api/status；visitors_active 简化为 = visitors_total when running
		local admin_enabled_flag = (s.admin_enabled == "1")
		local proxies_online, admin_reachable, last_error = 0, false, ""
		-- 仅当真的有 proxy 需要监控时才发起 admin API 调用，避免 frpc 日志被 /api/status 刷屏
		if running and admin_port and admin_enabled_flag and proxies_total > 0 then
			local auth = ""
			local au = s.admin_user or s.webServer__user
			local ap = s.admin_password or s.webServer__password
			if au and au ~= "" then
				auth = string.format("-u %q:%q ", au, ap or "")
			end
			local cmd = string.format(
				"curl -s --max-time 1 %shttp://127.0.0.1:%d/api/status 2>/dev/null",
				auth, admin_port)
			local body = sys.exec(cmd)
			if body and body ~= "" then
				admin_reachable = true
				local ok, parsed = pcall(function()
					return require("luci.jsonc").parse(body)
				end)
				if ok and type(parsed) == "table" then
					for _, group in pairs(parsed) do
						if type(group) == "table" then
							for _, p in ipairs(group) do
								if p.status == "online" or p.status == "running" then
									proxies_online = proxies_online + 1
								elseif p.err and p.err ~= "" then
									last_error = p.err
								end
							end
						end
					end
				end
			end
		end

		-- visitor 没有"在线"概念，frpc 进程跑着就算 active（不依赖 admin API）
		local visitors_active = running and visitors_total or 0

		table.insert(list, {
			name = name,
			alias = s.alias or name,
			enabled = (s.enabled == "1"),
			admin_enabled = admin_enabled_flag,
			running = running,
			admin_port = admin_port,
			admin_reachable = admin_reachable,
			proxies_total = proxies_total,
			proxies_online = proxies_online,
			visitors_total = visitors_total,
			visitors_active = visitors_active,
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
		running = any_running,                                  -- 兼容旧 UI
		global_enabled = (uci:get("frpc", "main", "enabled") == "1"),
		instances = instances,
	})
end

function action_restart()
	local server = http.formvalue("server")
	local cmd
	if server and server ~= "" and uci:get("frpc", server) == "server" then
		cmd = "/etc/init.d/frpc restart frpc." .. server .. " >/dev/null 2>&1"
	else
		cmd = "/etc/init.d/frpc restart >/dev/null 2>&1"
	end
	local code = sys.call(cmd)
	http.prepare_content("application/json")
	http.write_json({ code = code })
end

function action_reload()
	-- reload 始终是全局的，单实例 reload 没有意义（rule 归属可能在多实例间漂移）
	local code = sys.call("/etc/init.d/frpc reload >/dev/null 2>&1")
	http.prepare_content("application/json")
	http.write_json({ code = code })
end

function action_instance_action()
	local server = http.formvalue("server")
	local op     = http.formvalue("op")
	local code = 1
	local msg = "unknown op"

	-- 验证 server 存在
	if not server or uci:get("frpc", server) ~= "server" then
		http.prepare_content("application/json")
		http.write_json({ code = 2, message = "server not found" })
		return
	end

	if op == "start" then
		uci:set("frpc", server, "enabled", "1")
		uci:commit("frpc")
		code = sys.call("/etc/init.d/frpc reload >/dev/null 2>&1")
		msg = "ok"
	elseif op == "stop" then
		uci:set("frpc", server, "enabled", "0")
		uci:commit("frpc")
		code = sys.call("/etc/init.d/frpc reload >/dev/null 2>&1")
		msg = "ok"
	elseif op == "restart" then
		code = sys.call("/etc/init.d/frpc restart frpc." .. server .. " >/dev/null 2>&1")
		msg = "ok"
	end

	http.prepare_content("application/json")
	http.write_json({ code = code, message = msg })
end

function action_instance_admin_url()
	local server = http.formvalue("server")
	if not server or server == "" or server:match("[^%w_%-]") or uci:get("frpc", server) ~= "server" then
		http.prepare_content("application/json")
		http.write_json({ url = "", port = "", message = "服务器不存在" })
		return
	end
	if uci:get("frpc", server, "admin_enabled") ~= "1" then
		http.prepare_content("application/json")
		http.write_json({ url = "", port = "", message = "该实例未启用 Admin Dashboard" })
		return
	end
	local port = util.trim(sys.exec("cat /var/run/frpc/" .. server .. ".admin_port 2>/dev/null"))
	local lan_ip = util.trim(sys.exec("uci -q get network.lan.ipaddr || ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'"))

	local url = ""
	if port ~= "" and lan_ip ~= "" then
		url = string.format("http://%s:%s", lan_ip, port)
	end

	http.prepare_content("application/json")
	http.write_json({ url = url, port = port })
end

local function _copy_section(stype, name_key, list_page, sid)
	local dsp = require "luci.dispatcher"
	local list_url = dsp.build_url("admin/services/frpc/" .. list_page)

	if not sid or sid == "" or uci:get("frpc", sid) ~= stype then
		http.redirect(list_url)
		return
	end

	local src = uci:get_all("frpc", sid)
	if not src then
		http.redirect(list_url)
		return
	end

	local new_sid = uci:add("frpc", stype)
	if not new_sid then
		http.redirect(list_url)
		return
	end

	for k, v in pairs(src) do
		if k:sub(1, 1) ~= "." then
			-- DynamicList 字段（如 extra_options）在 get_all 中是 table，必须用 set_list
			if type(v) == "table" then
				uci:set_list("frpc", new_sid, k, v)
			else
				uci:set("frpc", new_sid, k, v)
			end
		end
	end

	local original = src[name_key] or ""
	uci:set("frpc", new_sid, name_key, original .. "_copy")

	-- 立即持久化到 /etc/config/frpc，避免用户在编辑页不保存就离开导致 staging 残留
	uci:save("frpc")
	uci:commit("frpc")

	http.redirect(dsp.build_url("admin/services/frpc/" .. list_page .. "/" .. new_sid))
end

function rule_copy(sid)
	_copy_section("rule", "name", "rules", sid)
end

function server_copy(sid)
	_copy_section("server", "alias", "servers", sid)
end

-- ────────────────────────────────────────────────────────────────
-- 程序管理 actions
-- ────────────────────────────────────────────────────────────────

local function _valid_version(v)
	return v and type(v) == "string" and v:match("^[0-9]+%.[0-9]+%.[0-9]+$") ~= nil
end

-- 文件替换模型下，「当前版本」 = /usr/bin/frpc -v 的输出。
-- 用版本字符串比对，而不是路径比对（路径恒为 /usr/bin/frpc）。
local function _scan_downloaded(current_version)
	local list = {}
	if not fs.stat(FRP_VERSIONS_DIR) then return list end
	for entry in fs.dir(FRP_VERSIONS_DIR) do
		if _valid_version(entry) then
			local path = FRP_VERSIONS_DIR .. "/" .. entry .. "/frpc"
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
-- 同时清掉 main.client_file 这种历史遗留字段（main 是全局节，不该有 client_file）。
local function _heal_client_paths(removed_version)
	local healed = {}
	local fallback = "/usr/bin/frpc"

	local function is_bad(p)
		if not p or p == "" then return true end
		if removed_version and p:match("/versions/" .. removed_version:gsub("%.", "%%.") .. "/") then
			return true
		end
		return not fs.access(p)
	end

	local default = uci:get("frpc", "main", "default_client_file") or ""
	if is_bad(default) then
		uci:set("frpc", "main", "default_client_file", fallback)
		table.insert(healed, "main.default_client_file: " .. default .. " → " .. fallback)
	end

	if uci:get("frpc", "main", "client_file") then
		uci:delete("frpc", "main", "client_file")
		table.insert(healed, "main.client_file: removed (legacy field)")
	end

	uci:foreach("frpc", "server", function(s)
		local cf = s.client_file
		if cf and cf ~= "" and is_bad(cf) then
			uci:delete("frpc", s[".name"], "client_file")
			table.insert(healed, s[".name"] .. ".client_file: " .. cf .. " → (inherit default)")
		end
	end)

	if #healed > 0 then uci:commit("frpc") end
	return healed
end

function action_program_info()
	local arch_raw = util.trim(sys.exec("uname -m 2>/dev/null"))
	local frp_platform = ARCH_MAP[arch_raw] or ""

	local healed = _heal_client_paths()

	local current_file = uci:get("frpc", "main", "default_client_file") or ""
	local current_version = ""
	if current_file ~= "" and fs.access(current_file) then
		local out = util.trim(sys.exec(util.shellquote(current_file) .. " -v 2>/dev/null"))
		current_version = out
	end

	local mirror = uci:get("frpc", "main", "download_mirror") or ""

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

-- 异步下载：fork 后台脚本，立即返回；前端通过 program_progress 查询进度
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
	local status_file = "/tmp/frpc_dl_" .. version .. ".json"
	local tmp_archive = "/tmp/frpc_dl_" .. version .. ".tar.gz"
	local tmp_unpack = "/tmp/frpc_dl_" .. version .. "_unpack"
	local script_file = "/tmp/frpc_dl_" .. version .. ".sh"

	-- 已存在
	if fs.access(target_dir .. "/frpc") then
		http.write_json({ok = false, error = "已下载该版本", already = true})
		return
	end
	-- 在下载中
	if fs.access(status_file) then
		http.write_json({ok = true, status = "in_progress"})
		return
	end

	local mirror = uci:get("frpc", "main", "download_mirror") or ""
	local url = mirror .. "https://github.com/fatedier/frp/releases/download/v" ..
		version .. "/frp_" .. version .. "_" .. platform .. ".tar.gz"

	-- 后台下载脚本
	local script = string.format([=[#!/bin/sh
STATUS=%q
TMP=%q
UNPACK=%q
URL=%q
TARGET=%q

write_status() {
	echo "{\"stage\":\"$1\",\"size\":${2:-0},\"message\":\"${3:-}\"}" > "$STATUS"
}

cleanup_tmp() {
	rm -rf "$TMP" "$UNPACK"
}

write_status downloading 0
mkdir -p "$TARGET"
wget -q --no-check-certificate -O "$TMP" "$URL"
WGET_EXIT=$?

if [ $WGET_EXIT -ne 0 ] || [ ! -s "$TMP" ]; then
	write_status error 0 "下载失败 (wget exit=$WGET_EXIT)"
	cleanup_tmp
	rm -rf "$TARGET"
	(sleep 30; rm -f "$STATUS") &
	exit 1
fi

write_status extracting "$(wc -c < "$TMP" 2>/dev/null)"
mkdir -p "$UNPACK"
tar -xzf "$TMP" -C "$UNPACK" 2>/dev/null

FRPC_SRC=$(find "$UNPACK" -type f -name frpc 2>/dev/null | head -1)
if [ -z "$FRPC_SRC" ]; then
	write_status error 0 "解压成功但未找到 frpc 二进制"
	cleanup_tmp
	rm -rf "$TARGET"
	(sleep 30; rm -f "$STATUS") &
	exit 1
fi

cp -f "$FRPC_SRC" "$TARGET/frpc"
chmod 755 "$TARGET/frpc"
cleanup_tmp

# 验证可执行
DETECTED=$("$TARGET/frpc" -v 2>/dev/null)
write_status done "$(wc -c < "$TARGET/frpc" 2>/dev/null)" "$DETECTED"

# 保留 status 30s 让前端拿到 done 状态后再清理
(sleep 30; rm -f "$STATUS") &
]=], status_file, tmp_archive, tmp_unpack, url, target_dir)

	-- 写脚本并 setsid 后台启动
	fs.writefile(script_file, script)
	sys.call("chmod +x " .. util.shellquote(script_file))
	sys.call("setsid sh -c " .. util.shellquote(
		"(" .. script_file .. " </dev/null >/dev/null 2>&1; rm -f " .. script_file .. ") &"
	) .. " >/dev/null 2>&1")

	http.write_json({ok = true, status = "started", version = version})
end

-- 查询下载进度（前端轮询）
function action_program_progress()
	http.prepare_content("application/json")
	local version = http.formvalue("version")
	if not version or not _valid_version(version) then
		http.write_json({ok = false, error = "无效版本号"})
		return
	end

	local status_file = "/tmp/frpc_dl_" .. version .. ".json"
	local tmp_archive = "/tmp/frpc_dl_" .. version .. ".tar.gz"
	local target_dir = FRP_VERSIONS_DIR .. "/" .. version

	-- status 不存在但 frpc 存在 = 已完成（status 文件已被 30s 后清理）
	if not fs.access(status_file) then
		if fs.access(target_dir .. "/frpc") then
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

	-- 下载中：实时取临时归档文件大小
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

-- 文件替换模型：把 /usr/share/frp/versions/<v>/frpc 物理覆盖到 /usr/bin/frpc。
-- 通过 cp→.new → mv（rename(2)） 完成原子替换，避免 ETXTBSY（运行中的旧 inode 不变）。
-- 不再修改 uci.default_client_file，彻底消除「路径指向被删版本目录」的整类 bug。
function action_program_switch(version)
	http.prepare_content("application/json")

	if not _valid_version(version) then
		http.write_json({ok = false, error = "无效版本号"})
		return
	end

	local src = FRP_VERSIONS_DIR .. "/" .. version .. "/frpc"
	if not fs.access(src) then
		http.write_json({ok = false, error = "该版本未下载"})
		return
	end

	local target = "/usr/bin/frpc"
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

	-- 防御性：把 default_client_file 锁回 /usr/bin/frpc（uci-defaults 也会兜底）
	if uci:get("frpc", "main", "default_client_file") ~= target then
		uci:set("frpc", "main", "default_client_file", target)
		uci:commit("frpc")
	end

	sys.call("/etc/init.d/frpc restart >/dev/null 2>&1")

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

	-- 文件替换模型下，「当前」 = /usr/bin/frpc -v 的版本字符串
	local current_bin = uci:get("frpc", "main", "default_client_file") or "/usr/bin/frpc"
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

	-- 兜底清理：万一历史上有 server.client_file 指向版本目录
	local healed = _heal_client_paths(version)
	http.write_json({ok = true, healed = healed})
end

function action_program_refresh()
	http.prepare_content("application/json")

	local user_mirror = uci:get("frpc", "main", "download_mirror") or ""
	local api_path = "https://api.github.com/repos/fatedier/frp/releases?per_page=20"

	-- 按顺序尝试的候选列表
	-- 注意：ghfast.top / ghproxy.com / ghproxy.net 这类是文件代理，对 api.github.com 通常 404
	-- 所以这里独立维护 API 兼容镜像列表
	local candidates = {}
	-- 1. 用户配置的 download_mirror 作为最优先尝试（如果用户配的就是 API 镜像就直接命中）
	if user_mirror ~= "" then
		table.insert(candidates, user_mirror .. api_path)
	end
	-- 2. 内置的已知 API 兼容镜像（按设备实测可用性排序）
	table.insert(candidates, api_path)                                       -- 直连 api.github.com（多数环境可用）
	table.insert(candidates, "https://gh-proxy.com/" .. api_path)            -- 实测可用
	table.insert(candidates, "https://edge-proxy.srv1.qzz.io/" .. api_path)  -- 实测可用
	table.insert(candidates, "https://edge-proxy.srv0.qzz.io/" .. api_path)  -- 备选
	table.insert(candidates, "https://edge-proxy.988669.xyz/" .. api_path)   -- 备选
	table.insert(candidates, "https://edge-proxy.966788.xyz/" .. api_path)   -- 备选
	table.insert(candidates, "https://gh.api.99988866.xyz/" .. api_path)     -- 备选
	table.insert(candidates, "https://gh-proxy.net/" .. api_path)            -- 备选

	local body, hit_url
	local errors = {}
	for _, url in ipairs(candidates) do
		-- wget -T 8 (busybox 支持) 8 秒超时；--no-check-certificate 容错自签证书
		local cmd = "wget -T 8 -q -O - --no-check-certificate " ..
			util.shellquote(url) .. " 2>/dev/null"
		local resp = sys.exec(cmd)
		if resp and #resp > 100 and resp:find('"tag_name"') then
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
	for tag in body:gmatch('"tag_name"%s*:%s*"v([0-9.]+)"') do
		if not seen[tag] and _valid_version(tag) then
			seen[tag] = true
			table.insert(versions, tag)
		end
	end

	if #versions == 0 then
		http.write_json({ok = false, error = "解析 GitHub 响应失败，无版本"})
		return
	end

	http.write_json({
		ok = true,
		versions = versions,
		hit_url = hit_url,  -- 让前端可显示哪个镜像命中了
	})
end

function action_program_save_mirror()
	http.prepare_content("application/json")
	local m = http.formvalue("mirror") or ""

	-- 允许空字符串（=直连）或必须以 http(s):// 开头
	if m ~= "" and not m:match("^https?://") then
		http.write_json({ok = false, error = "镜像前缀必须以 http:// 或 https:// 开头"})
		return
	end

	uci:set("frpc", "main", "download_mirror", m)
	uci:commit("frpc")
	http.write_json({ok = true, mirror = m})
end

function action_rule_batch_set_server()
	local rules_csv = http.formvalue("rules") or ""
	local target = http.formvalue("server") or ""
	if uci:get("frpc", target) ~= "server" then
		http.prepare_content("application/json")
		http.write_json({ code = 1, message = "target server not found" })
		return
	end
	local count = 0
	for r in rules_csv:gmatch("([^,]+)") do
		if uci:get("frpc", r) == "rule" then
			uci:set("frpc", r, "server_id", target)
			count = count + 1
		end
	end
	uci:commit("frpc")
	http.prepare_content("application/json")
	http.write_json({ code = 0, count = count })
end

function view_conf()
	-- 多实例：支持 ?server=xxx 切换查看对应实例的 toml
	local sel_server = http.formvalue("server")
	-- 安全：仅允许字母/数字/下划线/连字符
	if sel_server and sel_server:match("[^%w_%-]") then sel_server = nil end

	local target_name = nil
	if sel_server and sel_server ~= "" and uci:get("frpc", sel_server) == "server" then
		target_name = sel_server
	end
	if not target_name then
		uci:foreach("frpc", "server", function(s)
			if s.enabled == "1" then
				target_name = s[".name"]
				return false
			end
		end)
	end
	if not target_name then
		uci:foreach("frpc", "server", function(s)
			target_name = s[".name"]
			return false
		end)
	end

	-- 收集所有 server 用于下拉
	local servers = {}
	uci:foreach("frpc", "server", function(s)
		servers[#servers+1] = { s[".name"], s.alias or s[".name"] }
	end)

	local target_toml = target_name and ("/var/etc/frpc/frpc." .. target_name .. ".toml") or ""
	local content = e.readfile(target_toml) or ""
	a.render("frpc/file_viewer", {
		title = t.translate("Frpc - 查看配置文件"),
		content = content,
		toml_path = target_toml,
		current_server = target_name or "",
		servers = servers,
	})
end

function download_toml()
	local sel_server = http.formvalue("server")
	if sel_server and sel_server:match("[^%w_%-]") then sel_server = nil end
	if not sel_server or sel_server == "" or uci:get("frpc", sel_server) ~= "server" then
		http.status(404, "Not Found")
		http.prepare_content("text/plain; charset=utf-8")
		http.write("server not found")
		return
	end

	local toml_path = "/var/etc/frpc/frpc." .. sel_server .. ".toml"
	local content = fs.readfile(toml_path)
	if not content or content == "" then
		http.status(404, "Not Found")
		http.prepare_content("text/plain; charset=utf-8")
		http.write("toml not generated yet, enable the instance and save first")
		return
	end

	-- 文件名：alias 可能含中文，按 RFC 5987 同时下发 ASCII 兜底名与 UTF-8 编码原名
	local alias = uci:get("frpc", sel_server, "alias") or sel_server
	-- ASCII 兜底：把所有非安全字符替换为 _
	local ascii_name = alias:gsub("[^%w%-_%.]", "_"):gsub("_+", "_")
	if ascii_name == "" or ascii_name == "_" then ascii_name = sel_server end
	local fallback = "frpc." .. ascii_name .. ".toml"
	-- UTF-8 原名（含中文），按 RFC 3986 百分号编码
	local utf8_raw = "frpc." .. alias .. ".toml"
	local utf8_encoded = utf8_raw:gsub("[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)

	http.header("Content-Disposition",
		'attachment; filename="' .. fallback .. '"; filename*=UTF-8\'\'' .. utf8_encoded)
	http.prepare_content("application/toml; charset=utf-8")
	http.write(content)
end

local function _resolve_log_link(server)
	-- 显式指定优先
	if server and server ~= "" then
		-- 安全：仅允许字母/数字/下划线/连字符
		if server:match("[^%w_%-]") then
			server = ""
		end
	end
	if server and server ~= "" then
		return "/tmp/frpc_log_" .. server .. ".txt"
	end
	-- 默认 server：第一个 enabled 的 server
	local default_link = "/tmp/frpc_log_link.txt"
	uci:foreach("frpc", "server", function(s)
		if s.enabled == "1" then
			default_link = "/tmp/frpc_log_" .. s[".name"] .. ".txt"
			return false
		end
	end)
	return default_link
end

function get_log()
	local server = http.formvalue("server")
	local link = _resolve_log_link(server)
	luci.http.write(luci.sys.exec("tail -c 200000 " .. link .. " 2>/dev/null"))
end

function clear_log()
	local server = http.formvalue("server")
	local link = _resolve_log_link(server)
	luci.sys.call("true > " .. link)
end
