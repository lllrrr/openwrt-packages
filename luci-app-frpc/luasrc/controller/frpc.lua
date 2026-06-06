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

	-- 应用自更新（与 frps 共用 release zip：kwrt-frp-mgr-releases）
	-- order=99 让它排到最末（备份/还原 之后），属于不常用功能
	entry({"admin", "services", "frpc", "self_update"},
		template("frpc/self_update"), _("检查更新"), 99).leaf = true
	entry({"admin", "services", "frpc", "self_update_check"},  call("action_self_update_check"))
	entry({"admin", "services", "frpc", "self_update_start"},  call("action_self_update_start"))
	entry({"admin", "services", "frpc", "self_update_log"},    call("action_self_update_log"))
	entry({"admin", "services", "frpc", "self_update_rollback"}, call("action_self_update_rollback"))

	entry({"admin", "services", "frpc", "configuration"}, call("view_conf"), _("查看 TOML 配置"), 5).leaf = true
	entry({"admin", "services", "frpc", "download_toml"}, call("download_toml")).leaf = true
	
	entry({"admin", "services", "frpc", "get_log"}, call("get_log")).leaf = true
	entry({"admin", "services", "frpc", "clear_log"}, call("clear_log")).leaf = true
	entry({"admin", "services", "frpc", "log"}, cbi("frpc/log"), _("查看日志"), 8).leaf = true

	-- 备份/还原（注意：不能 .leaf=true，否则其下的 sub-routes 会被当成 view_backup 的参数）
	entry({"admin", "services", "frpc", "backup"},
		call("view_backup"), _("备份/还原"), 9)

	-- destination CRUD
	entry({"admin", "services", "frpc", "backup", "dest_list"},   call("action_backup_dest_list"))
	entry({"admin", "services", "frpc", "backup", "dest_save"},   call("action_backup_dest_save"))
	entry({"admin", "services", "frpc", "backup", "dest_delete"}, call("action_backup_dest_delete"))
	entry({"admin", "services", "frpc", "backup", "dest_test"},   call("action_backup_dest_test"))

	-- 备份操作
	entry({"admin", "services", "frpc", "backup", "list"},            call("action_backup_list"))
	entry({"admin", "services", "frpc", "backup", "create"},          call("action_backup_create"))
	entry({"admin", "services", "frpc", "backup", "create_progress"}, call("action_backup_create_progress"))
	entry({"admin", "services", "frpc", "backup", "download"},        call("action_backup_download")).leaf = true
	entry({"admin", "services", "frpc", "backup", "upload"},          call("action_backup_upload"))
	entry({"admin", "services", "frpc", "backup", "delete"},          call("action_backup_delete"))

	-- 还原操作
	entry({"admin", "services", "frpc", "backup", "restore"},          call("action_backup_restore"))
	entry({"admin", "services", "frpc", "backup", "restore_progress"}, call("action_backup_restore_progress"))
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

-- 生成稳定 section 名（srv_<ts>_<rand>），极端兜底防同秒碰撞。
-- 关键：server 绝不能用 uci:add 产生匿名 cfgXXXXXX——它的名字依赖 section 在文件中的
-- 位置，任何排序/增删都会让 cfg-id 漂移，导致 rule.server_id 悬空（见 servers.lua s.create
-- 与 uci-defaults migrate_v3 注释）。复制服务器同样必须走稳定命名。
local function _stable_sid(prefix)
	local id = string.format("%s_%d_%d", prefix, os.time(), math.random(1000, 9999))
	for _ = 1, 5 do
		if not uci:get("frpc", id) then break end
		id = string.format("%s_%d_%d", prefix, os.time(), math.random(1000, 9999))
	end
	return id
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

	-- server 用稳定命名（srv_xxx），rule 可保持匿名（无任何外键引用 rule 名，漂移无害）
	local new_sid
	if stype == "server" then
		new_sid = _stable_sid("srv")
		uci:set("frpc", new_sid, stype)
	else
		new_sid = uci:add("frpc", stype)
	end
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
]=], status_file, tmp_archive, tmp_unpack, url_list, target_dir)

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
	-- 1. 优先：自建代理的版本列表接口（与二进制下载同源，返回 {"releases":[{"tag":"vX"}...]}）
	for _, base in ipairs(FRP_DL_PROXIES) do
		table.insert(candidates, base .. "/frp-releases?per_page=20")
	end
	-- 2. 回退：用户配置的 download_mirror（如果用户配的就是 API 镜像就直接命中）
	if user_mirror ~= "" then
		table.insert(candidates, user_mirror .. api_path)
	end
	-- 3. 回退：内置的已知 API 兼容镜像（按设备实测可用性排序）
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

-- ────────────────────────────────────────────────────────────────
-- 备份/还原 actions
-- ────────────────────────────────────────────────────────────────

local function _backup_core()
	return require("luci.frpc.backup_core")
end

function view_backup()
	a.render("frpc/backup_manager", {
		title = t.translate("Frpc - 备份与还原"),
	})
end

function action_backup_dest_list()
	http.prepare_content("application/json")
	local core = _backup_core()
	http.write_json({ ok = true, destinations = core.list_all_destinations() })
end

function action_backup_dest_save()
	http.prepare_content("application/json")
	local core = _backup_core()
	local id   = http.formvalue("id") or ""
	local typ  = http.formvalue("type") or ""
	local name = http.formvalue("name") or ""

	if id ~= "" and not core.valid_id(id) then
		http.write_json({ ok = false, error = "id 包含非法字符" })
		return
	end
	if typ ~= "local" and typ ~= "webdav" and typ ~= "s3" then
		http.write_json({ ok = false, error = "未知 driver 类型: " .. typ })
		return
	end
	if name == "" then
		http.write_json({ ok = false, error = "name 必填" })
		return
	end

	-- 新建：id 为空则自动生成（os.time + 4位随机数防秒级碰撞）
	local section_id = id
	if section_id == "" then
		section_id = typ .. "_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
	end

	-- section type 必须正确（更新场景下校验现有 section 是 destination 类型）
	local existing = uci:get("frpc", section_id)
	if existing and existing ~= "destination" then
		http.write_json({ ok = false, error = "id 已被其他类型占用" })
		return
	end

	uci:set("frpc", section_id, "destination")
	uci:set("frpc", section_id, "type", typ)
	uci:set("frpc", section_id, "name", name)
	uci:set("frpc", section_id, "enabled", http.formvalue("enabled") == "1" and "1" or "0")

	-- type 相关字段
	if typ == "local" then
		local path = http.formvalue("path") or "/etc/frpc-backup"
		uci:set("frpc", section_id, "path", path)
	elseif typ == "webdav" then
		uci:set("frpc", section_id, "url",        http.formvalue("url") or "")
		uci:set("frpc", section_id, "username",   http.formvalue("username") or "")
		uci:set("frpc", section_id, "password",   http.formvalue("password") or "")
		uci:set("frpc", section_id, "verify_tls", http.formvalue("verify_tls") == "1" and "1" or "0")
	elseif typ == "s3" then
		uci:set("frpc", section_id, "endpoint",   http.formvalue("endpoint") or "")
		uci:set("frpc", section_id, "region",     http.formvalue("region") or "")
		uci:set("frpc", section_id, "bucket",     http.formvalue("bucket") or "")
		uci:set("frpc", section_id, "access_key", http.formvalue("access_key") or "")
		uci:set("frpc", section_id, "secret_key", http.formvalue("secret_key") or "")
		uci:set("frpc", section_id, "path_style", http.formvalue("path_style") == "1" and "1" or "0")
	end

	uci:commit("frpc")
	http.write_json({ ok = true, id = section_id })
end

function action_backup_dest_delete()
	http.prepare_content("application/json")
	local core = _backup_core()
	local id = http.formvalue("id") or ""
	if not core.valid_id(id) then
		http.write_json({ ok = false, error = "无效 id" })
		return
	end
	if uci:get("frpc", id) ~= "destination" then
		http.write_json({ ok = false, error = "destination 不存在" })
		return
	end
	uci:delete("frpc", id)
	uci:commit("frpc")
	http.write_json({ ok = true })
end

function action_backup_dest_test()
	http.prepare_content("application/json")
	local core = _backup_core()
	local id = http.formvalue("id") or ""
	if not core.valid_id(id) then
		http.write_json({ ok = false, error = "无效 id" })
		return
	end
	local cfg, err = core.load_destination(id)
	if not cfg then http.write_json({ ok = false, error = err }); return end
	local drv, derr = core.load_driver(cfg)
	if not drv then http.write_json({ ok = false, error = derr }); return end
	local ok, terr = drv:test()
	http.write_json({ ok = ok and true or false, error = terr })
end

function action_backup_list()
	http.prepare_content("application/json")
	local core = _backup_core()
	local all_dests = core.list_all_destinations()

	local backups = {}
	local dest_errors = {}
	for _, cfg in ipairs(all_dests) do
		if cfg.enabled == "1" then
			local drv, derr = core.load_driver(cfg)
			if drv then
				local entries, lerr = drv:list()
				if entries then
					for _, e in ipairs(entries) do
						table.insert(backups, {
							dest_id    = cfg.id,
							dest_name  = cfg.name,
							dest_type  = cfg.type,
							id         = e.id,
							name       = e.name,
							size       = e.size,
							mtime      = e.mtime,
						})
					end
				else
					table.insert(dest_errors, { dest_id = cfg.id, error = lerr })
				end
			else
				table.insert(dest_errors, { dest_id = cfg.id, error = derr })
			end
		end
	end

	-- 按 mtime DESC（mtime=0 时退化按 name DESC，让较新的时间戳排前面）
	table.sort(backups, function(a, b)
		if a.mtime ~= b.mtime then return a.mtime > b.mtime end
		return a.name > b.name
	end)

	http.write_json({ ok = true, backups = backups, dest_errors = dest_errors })
end

-- 异步创建备份：写后台脚本 setsid 执行；前端轮询 create_progress
function action_backup_create()
	http.prepare_content("application/json")
	local core = _backup_core()

	local note = http.formvalue("note") or ""
	local dest_ids_csv = http.formvalue("dest_ids") or ""
	local inc_uci = http.formvalue("inc_uci") == "1"
	local inc_bin = http.formvalue("inc_bin") == "1"
	local inc_ver = http.formvalue("inc_ver") == "1"

	local dest_ids = {}
	for s in dest_ids_csv:gmatch("([^,]+)") do
		if core.valid_id(s) and uci:get("frpc", s) == "destination" then
			table.insert(dest_ids, s)
		end
	end
	if #dest_ids == 0 then
		http.write_json({ ok = false, error = "请选择至少一个备份目的地" })
		return
	end

	-- 任务 ID：用时间戳 + 随机数（不同于 backup_id，避免歧义）
	local task_id = "task_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 999999))
	local status_file = "/tmp/frpc_backup_create_" .. task_id .. ".json"

	-- 把任务参数写到 work_file，后台脚本读取
	local work_file = "/tmp/frpc_backup_create_" .. task_id .. ".work"
	local jsonc = require("luci.jsonc")
	fs.writefile(work_file, jsonc.stringify({
		note = note,
		dest_ids = dest_ids,
		includes = { uci = inc_uci, current_binary = inc_bin, version_metadata = inc_ver },
	}))

	-- 写后台 lua 脚本
	local script_file = "/tmp/frpc_backup_create_" .. task_id .. ".lua"
	local script = string.format([=[
local fs   = require "nixio.fs"
local json = require "luci.jsonc"
local core = require "luci.frpc.backup_core"

local status_file = %q
local work_file   = %q

local function write_status(stage, msg, extra)
    local t = { stage = stage, message = msg or "", extra = extra }
    fs.writefile(status_file, json.stringify(t))
end

local work = json.parse(fs.readfile(work_file) or "{}") or {}

write_status("packing", "正在打包...")
local ok, res = core.pack_backup({
    note = work.note,
    includes = work.includes,
    download_mirror = require("luci.model.uci").cursor():get("frpc","main","download_mirror") or "",
})
if not ok then
    write_status("error", "打包失败：" .. tostring(res))
    return
end

local failed = {}
local succeeded = {}
for i, dest_id in ipairs(work.dest_ids) do
    write_status("uploading", "上传到 " .. dest_id .. " (" .. i .. "/" .. #work.dest_ids .. ")")
    local cfg, ce = core.load_destination(dest_id)
    if not cfg then
        table.insert(failed, { dest_id = dest_id, error = ce })
    else
        local drv, de = core.load_driver(cfg)
        if not drv then
            table.insert(failed, { dest_id = dest_id, error = de })
        else
            local ok2, err = drv:put(res.tar_path, res.filename)
            if ok2 then
                table.insert(succeeded, dest_id)
            else
                table.insert(failed, { dest_id = dest_id, error = err })
            end
        end
    end
end

-- 清理本地 tmp tar
os.execute("rm -f " .. res.tar_path)
os.execute("rm -f " .. work_file)

if #failed == 0 then
    write_status("done", "全部成功", { backup_id = res.backup_id, filename = res.filename, succeeded = succeeded })
else
    write_status("done", "部分失败：" .. #failed .. " / " .. #work.dest_ids,
        { backup_id = res.backup_id, filename = res.filename, succeeded = succeeded, failed = failed })
end
]=], status_file, work_file)

	fs.writefile(script_file, script)
	sys.call("chmod +x " .. util.shellquote(script_file))
	sys.call("setsid sh -c " .. util.shellquote(
		"(lua " .. script_file .. " </dev/null >/dev/null 2>&1; " ..
		"rm -f " .. script_file .. "; " ..
		"sleep 30; rm -f " .. status_file .. ") &"
	) .. " >/dev/null 2>&1")

	http.write_json({ ok = true, task_id = task_id })
end

function action_backup_create_progress()
	http.prepare_content("application/json")
	local task_id = http.formvalue("task_id") or ""
	if not task_id:match("^task_[0-9_]+$") then
		http.write_json({ ok = false, error = "无效 task_id" })
		return
	end
	local status_file = "/tmp/frpc_backup_create_" .. task_id .. ".json"
	local content = fs.readfile(status_file)
	if not content or content == "" then
		http.write_json({ ok = true, stage = "idle" })
		return
	end
	local parsed = require("luci.jsonc").parse(content)
	if not parsed then
		http.write_json({ ok = true, stage = "unknown" })
		return
	end
	parsed.ok = true
	http.write_json(parsed)
end

function action_backup_delete()
	http.prepare_content("application/json")
	local core = _backup_core()
	local dest_id = http.formvalue("dest_id") or ""
	local name    = http.formvalue("name") or ""

	if not core.valid_id(dest_id) then
		http.write_json({ ok = false, error = "无效 dest_id" })
		return
	end
	if not name:match("^frpc%-backup%-.+%.tar%.gz$") then
		http.write_json({ ok = false, error = "无效备份名" })
		return
	end

	local cfg, ce = core.load_destination(dest_id)
	if not cfg then http.write_json({ ok = false, error = ce }); return end
	local drv, de = core.load_driver(cfg)
	if not drv then http.write_json({ ok = false, error = de }); return end
	local ok, err = drv:remove(name)
	http.write_json({ ok = ok and true or false, error = err })
end

function action_backup_restore()
	http.prepare_content("application/json")
	local core = _backup_core()
	local dest_id = http.formvalue("dest_id") or ""
	local name    = http.formvalue("name") or ""

	if not core.valid_id(dest_id) then
		http.write_json({ ok = false, error = "无效 dest_id" })
		return
	end
	if not name:match("^frpc%-backup%-.+%.tar%.gz$") then
		http.write_json({ ok = false, error = "无效备份名" })
		return
	end

	local task_id = "task_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 999999))
	local status_file = "/tmp/frpc_backup_restore_" .. task_id .. ".json"
	local script_file = "/tmp/frpc_backup_restore_" .. task_id .. ".lua"

	local script = string.format([=[
local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local util = require "luci.util"
local json = require "luci.jsonc"
local core = require "luci.frpc.backup_core"

local status_file = %q
local DEST_ID = %q
local NAME    = %q

local function write_status(stage, msg, extra)
    fs.writefile(status_file, json.stringify({ stage = stage, message = msg or "", extra = extra }))
end

local snapshot_path

local function rollback()
    if not snapshot_path or not fs.access(snapshot_path) then
        write_status("error", "回滚失败：快照文件丢失")
        return
    end
    write_status("rolling_back", "正在从快照回滚...")
    local ok, res = core.unpack_and_verify(snapshot_path)
    if not ok then
        write_status("error", "回滚解包失败：" .. tostring(res))
        return
    end
    local ok2, err = core.apply_unpacked(res.pkgroot, res.manifest)
    core.cleanup_unpack(res.unpack_dir)
    if ok2 then
        write_status("error", "已从快照回滚（原还原失败）")
    else
        write_status("error", "回滚也失败：" .. tostring(err))
    end
end

-- 1) 自动快照
write_status("snapshotting", "正在创建还原前快照...")
local ok, snap = core.create_auto_snapshot()
if not ok then
    write_status("error", "创建快照失败：" .. tostring(snap))
    return
end
snapshot_path = snap

-- 2) 下载
write_status("downloading", "正在从备份点拉取...")
local cfg, ce = core.load_destination(DEST_ID)
if not cfg then write_status("error", "destination 不存在：" .. tostring(ce)); return end
local drv, de = core.load_driver(cfg)
if not drv then write_status("error", "driver 加载失败：" .. tostring(de)); return end

local tmp_tar = "/tmp/frpc_restore_dl_" .. tostring(os.time()) .. ".tar.gz"
local ok2, err = drv:get(NAME, tmp_tar)
if not ok2 then
    sys.call("rm -f " .. util.shellquote(tmp_tar))
    rollback()
    return
end

-- 3) 解包校验
write_status("unpacking", "正在校验备份包...")
local ok3, res = core.unpack_and_verify(tmp_tar)
sys.call("rm -f " .. util.shellquote(tmp_tar))
if not ok3 then
    write_status("error", "校验失败：" .. tostring(res), { snapshot = snapshot_path })
    return
end

-- 4) 应用
write_status("applying", "正在覆盖配置与二进制...")
local ok4, aerr = core.apply_unpacked(res.pkgroot, res.manifest)
core.cleanup_unpack(res.unpack_dir)

if not ok4 then
    rollback()
    return
end

-- ok4=true 时 aerr 可能带回提示（如跨架构跳过二进制），一并展示给用户
write_status("done", aerr and ("还原成功（注意：" .. aerr .. "）") or "还原成功",
    { snapshot = snapshot_path, note = aerr })
]=], status_file, dest_id, name)

	fs.writefile(script_file, script)
	sys.call("setsid sh -c " .. util.shellquote(
		"(lua " .. script_file .. " </dev/null >/dev/null 2>&1; " ..
		"rm -f " .. script_file .. "; " ..
		"sleep 30; rm -f " .. status_file .. ") &"
	) .. " >/dev/null 2>&1")

	http.write_json({ ok = true, task_id = task_id })
end

function action_backup_restore_progress()
	http.prepare_content("application/json")
	local task_id = http.formvalue("task_id") or ""
	if not task_id:match("^task_[0-9_]+$") then
		http.write_json({ ok = false, error = "无效 task_id" })
		return
	end
	local status_file = "/tmp/frpc_backup_restore_" .. task_id .. ".json"
	local content = fs.readfile(status_file)
	if not content or content == "" then
		http.write_json({ ok = true, stage = "idle" })
		return
	end
	local parsed = require("luci.jsonc").parse(content)
	if not parsed then http.write_json({ ok = true, stage = "unknown" }); return end
	parsed.ok = true
	http.write_json(parsed)
end

-- 下载：仅本地 destination
function action_backup_download()
	local core = _backup_core()
	local dest_id = http.formvalue("dest_id") or ""
	local name    = http.formvalue("name") or ""

	if not core.valid_id(dest_id) or not name:match("^frpc%-backup%-.+%.tar%.gz$") then
		http.status(400, "Bad Request")
		http.prepare_content("text/plain")
		http.write("invalid params")
		return
	end
	local cfg, ce = core.load_destination(dest_id)
	if not cfg or cfg.type ~= "local" then
		http.status(400, "Bad Request")
		http.prepare_content("text/plain")
		http.write("only local destination can be downloaded directly")
		return
	end
	local path = (cfg.path or "/etc/frpc-backup") .. "/" .. name
	if not fs.access(path) then
		http.status(404, "Not Found")
		http.prepare_content("text/plain")
		http.write("not found")
		return
	end
	http.header("Content-Disposition", 'attachment; filename="' .. name .. '"')
	http.prepare_content("application/gzip")
	local content = fs.readfile(path)
	http.write(content or "")
end

-- 上传导入：multipart，把上传的 .tar.gz 移入 local_default
function action_backup_upload()
	http.prepare_content("application/json")
	local core = _backup_core()

	local tmp_path = "/tmp/frpc_upload_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 999999)) .. ".tar.gz"
	local written = 0
	local oversized = false

	http.setfilehandler(function(meta, chunk, eof)
		if oversized then return end
		if chunk and #chunk > 0 then
			if written + #chunk > core.MAX_UPLOAD_BYTES then
				oversized = true
				return
			end
			local f = io.open(tmp_path, written == 0 and "wb" or "ab")
			if f then
				f:write(chunk)
				f:close()
				written = written + #chunk
			end
		end
	end)

	-- 触发解析（必须读一遍 formvalue 才会调 filehandler）
	http.formvalue("file")

	if oversized then
		sys.call("rm -f " .. util.shellquote(tmp_path))
		http.write_json({ ok = false, error = "文件超过 " .. core.MAX_UPLOAD_BYTES .. " 字节上限" })
		return
	end
	if written == 0 or not fs.access(tmp_path) then
		http.write_json({ ok = false, error = "未收到文件" })
		return
	end

	-- 校验是合法 frpc 备份包
	local ok, res = core.unpack_and_verify(tmp_path)
	if not ok then
		sys.call("rm -f " .. util.shellquote(tmp_path))
		http.write_json({ ok = false, error = "校验失败：" .. tostring(res) })
		return
	end
	core.cleanup_unpack(res.unpack_dir)

	-- 移入 local_default
	local local_cfg = core.load_destination("local_default")
	local target_dir
	if local_cfg and local_cfg.path then
		target_dir = local_cfg.path
	else
		target_dir = core.LOCAL_BACKUP_DIR
	end
	sys.call("mkdir -p " .. util.shellquote(target_dir))

	-- 备份文件名一律重写为规范化形式
	local utc_compact = (res.manifest.created_at or ""):gsub("[%-:]", ""):gsub("%..*$", "")
	local norm_name = "frpc-backup-" .. utc_compact .. "-" .. core.note_to_slug(res.manifest.note or "") .. ".tar.gz"
	local dst = target_dir .. "/" .. norm_name

	if sys.call("mv -f " .. util.shellquote(tmp_path) .. " " .. util.shellquote(dst) .. " >/dev/null 2>&1") ~= 0 then
		sys.call("rm -f " .. util.shellquote(tmp_path))
		http.write_json({ ok = false, error = "移动文件到目标目录失败" })
		return
	end

	http.write_json({ ok = true, filename = norm_name, dest_id = "local_default" })
end

-- ─────────────────────────────────────────────────────────────────
-- 应用自更新（luci-app-frpc 自身升级）
-- 数据源：自建代理的 /kwrt-frp-mgr-releases/{latest|tag} 接口
-- 资产命名：luci-app-frp-<ver>-IPK-22.03.zip / -APK-SNAPSHOT.zip
--   zip 内含 luci-app-frpc_*.ipk 和 luci-app-frps_*.ipk
--   本侧仅升级 luci-app-frpc（按"装了哪个升级哪个"原则）
-- ─────────────────────────────────────────────────────────────────

local SELF_UPDATE_PKG  = "luci-app-frpc"
local SELF_UPDATE_TAG  = "frpc"  -- 区分 frpc/frps 状态文件，避免互相覆盖
local SELF_UPDATE_LOG  = "/tmp/" .. SELF_UPDATE_TAG .. "_self_update.log"
local SELF_UPDATE_STAT = "/tmp/" .. SELF_UPDATE_TAG .. "_self_update.json"

-- 与 program 模块共用代理域名列表（FRP_DL_PROXIES 已在文件顶部定义）
local function _self_update_get_installed_version()
	-- opkg list-installed 输出：  luci-app-frpc - 1.2.8
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
	-- 简易解析（避免依赖 jsonc 库异常）
	local tag        = resp:match('"tag"%s*:%s*"([^"]+)"') or ""
	local name       = resp:match('"name"%s*:%s*"([^"]+)"') or tag
	local published  = resp:match('"published_at"%s*:%s*"([^"]+)"') or ""
	local body       = resp:match('"body"%s*:%s*"((\\.[^"]*|[^"\\])*)"')
	-- Lua 正则不能完美抓 escaped json string，退化用 luci.jsonc
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

	http.write_json({
		ok = true,
		installed_version = installed,
		latest_version    = latest,
		latest_tag        = tag,
		latest_name       = name,
		published_at      = published,
		has_update        = has_update,
		body              = body or "",
		asset = (asset_url and {
			name = asset_name, size = asset_size, url = asset_url,
		} or nil),
	})
end

-- 启动自更新后台脚本
function action_self_update_start()
	http.prepare_content("application/json")
	local tag = http.formvalue("tag") or ""
	if not tag:match("^v[0-9][0-9%.]*$") then
		http.write_json({ok = false, error = "无效 tag"})
		return
	end

	-- 已在进行中？
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

	-- 候选下载源：7 个代理 + 原始 github（github 通常拉不到 zip release，但保底）
	local ver = tag:gsub("^v", "")
	local asset = "luci-app-frp-" .. ver .. "-IPK-22.03.zip"
	local urls = {}
	for _, base in ipairs(FRP_DL_PROXIES) do
		urls[#urls+1] = base .. "/kwrt-frp-mgr-releases/" .. tag .. "/" .. asset
	end
	local url_list = table.concat(urls, " ")

	local workdir   = "/tmp/" .. SELF_UPDATE_TAG .. "_upd"
	local zip_file  = workdir .. "/" .. asset
	local backup_dir = "/tmp/" .. SELF_UPDATE_TAG .. "_upd_backup"
	local script_file = "/tmp/" .. SELF_UPDATE_TAG .. "_upd.sh"

	-- 清旧状态/日志
	sys.call("rm -f " .. util.shellquote(SELF_UPDATE_LOG) .. " " .. util.shellquote(SELF_UPDATE_STAT))

	-- 备份策略：保存当前版本号 + opkg files 清单，回滚时通过重新下载该 tag 装回
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
# 清 LuCI 模块缓存
rm -rf /tmp/luci-modulecache/* /tmp/luci-indexcache* 2>/dev/null

# 关键：fork 重启，让本脚本先写完 done 状态再让 nginx 重启
state done 100 "升级成功，请刷新页面"
log "✅ 升级完成（新版本: $TAG）"
log "===== 自更新结束 ====="

(
	sleep 2
	/etc/init.d/rpcd restart >/dev/null 2>&1
	/etc/init.d/nginx restart >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1
) &

# 清理临时下载
sleep 5
rm -rf "$WORKDIR" "$ZIP" 2>/dev/null
# 状态文件保留 60s 让前端看到 done
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

-- 查询升级进度 + 日志 tail
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

	-- 取日志最后 40 行
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

-- 回滚到升级前的版本（从备份读取旧版本号，重新下载该 tag 装回）
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
	-- 触发对旧 tag 的升级（复用 start 逻辑）
	http.write_json({ok = true, rollback_to = "v" .. old_ver,
		hint = "请用 tag=v" .. old_ver .. " 调 self_update_start"})
end
