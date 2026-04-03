-- luci-app-clawpanel controller
module("luci.controller.clawpanel", package.seeall)

local function sh(cmd)
	local f = io.popen(cmd .. " 2>/dev/null")
	if not f then return "" end
	local out = f:read("*a")
	f:close()
	return out or ""
end

local function trim(s)
	return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Timeout wrapper: uses `timeout` if available; otherwise plain popen (no block protection)
-- iStoreOS BusyBox has no `timeout` cmd, so the else branch handles it
local function sh_timed(cmd, timeout_sec)
	timeout_sec = timeout_sec or 5
	-- Check if `timeout` command exists
	if os.execute("command -v timeout >/dev/null 2>&1") ~= 0 then
		-- No timeout cmd available; run without time limit (caller should handle this)
		local f = io.popen(cmd .. " 2>/dev/null")
		if not f then return "" end
		local out = ""
		while true do
			local line = f:read("*l")
			if not line then break end
			out = out .. line .. "\n"
		end
		f:close()
		return out
	end
	-- `timeout` available: use it
	local f = io.popen("timeout -t " .. timeout_sec .. " " .. cmd .. " 2>/dev/null")
	if not f then return "" end
	local out = f:read("*a")
	f:close()
	return out or ""
end

function index()
	entry({"admin", "services", "clawpanel"},
		template("clawpanel/main"), _("ClawPanel"), 85).dependent = false
	entry({"admin", "services", "clawpanel", "status_api"},
		call("action_status"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "service_ctl"},
		call("action_service_ctl"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "setup_log"},
		call("action_setup_log"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "wait_running"},
		call("action_wait_running"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "wait_stopped"},
		call("action_wait_stopped"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "uninstall"},
		call("action_uninstall"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "uninstall_log"},
		call("action_uninstall_log"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "mounts"},
		call("action_mounts"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "check_system"},
		call("action_check_system"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "check_update"},
		call("action_check_update"), nil).leaf = true
end

local function is_running(pid)
	if not pid or pid == "" then return false end
	return trim(sh("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no")) == "yes"
end

local function check_port(port)
	local listening = false
	local pid = ""
	local line = trim(sh("netstat -tulnp 2>/dev/null | grep ':" .. port .. " ' | head -1"))
	if line and line ~= "" then
		listening = true
		local p = line:match("(%d+)%/%S+")
		if p and p ~= "" then pid = p end
	end
	return { listening = listening, pid = pid }
end

function action_status()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()

	local port = uci:get("clawpanel", "main", "port") or "19527"
	local enabled = uci:get("clawpanel", "main", "enabled") or "0"
	local install_path = uci:get("clawpanel", "main", "install_path") or ""
	local cp_bin = install_path ~= "" and (install_path .. "/clawpanel/clawpanel") or ""

	local result = {
		enabled = enabled,
		port = port,
		install_path = install_path,
		panel_running = false,
		pid = "",
		memory_kb = 0,
		uptime = "",
		panel_version = "",
		installed_version = "",
		openclaw_dir = uci:get("clawpanel", "main", "openclaw_dir") or "",
		disk_free = ""
	}

	if cp_bin ~= "" and install_path ~= "" then
		-- Read .version file first (fast, written at install time)
		local vf = io.open(install_path .. "/clawpanel/.version", "r")
		if vf then
			local fver = trim(vf:read("*a"))
			vf:close()
			if fver ~= "" then result.panel_version = fver end
		end
		-- Fallback: call --version only if .version is empty
		if result.panel_version == "" then
			local v = trim(sh_timed(cp_bin .. " --version", 5))
			if v and v ~= "" then result.panel_version = v end
		end
	end

	local port_info = check_port(port)
	result.panel_running = port_info.listening
	result.pid = port_info.pid

	if result.panel_running and result.pid and result.pid ~= "" then
		local pid_num = tonumber(result.pid)
		if pid_num and pid_num > 0 then
			local rss_raw = trim(sh("awk '/VmRSS/{print $2}' /proc/" .. result.pid .. "/status 2>/dev/null"))
			local ok1, rss_val = pcall(function() return tonumber(rss_raw) end)
			result.memory_kb = (ok1 and rss_val) and rss_val or 0
			local ts_raw = trim(sh("stat -c %Y /proc/" .. result.pid .. "/status 2>/dev/null"))
			local ok2, ts_val = pcall(function() return tonumber(ts_raw) end)
			if ok2 and ts_val and ts_val > 0 then
				local up = os.time() - ts_val
				local h = math.floor(up / 3600)
				local m = math.floor((up % 3600) / 60)
				local s = up % 60
				if h > 0 then result.uptime = string.format("%dh %dm %ds", h, m, s)
				elseif m > 0 then result.uptime = string.format("%dm %ds", m, s)
				else result.uptime = s .. "s" end
			end
		end
	end

	if install_path ~= "" then
		local disk = trim(sh("df -h '" .. install_path .. "' | tail -1 | awk '{print $4}'"))
		if disk and disk ~= "" then result.disk_free = disk end
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

function action_wait_running()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local port = uci:get("clawpanel", "main", "port") or "19527"
	local max_wait = 90
	local waited = 0
	local interval = 3

	while waited < max_wait do
		local info = check_port(port)
		if info.listening then
			http.prepare_content("application/json")
			http.write_json({ state = "running", pid = info.pid, waited = waited })
			return
		end
		sh("sleep " .. tostring(interval))
		waited = waited + interval
	end

	http.prepare_content("application/json")
	http.write_json({ state = "timeout", pid = "", waited = waited })
end

function action_wait_stopped()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local port = uci:get("clawpanel", "main", "port") or "19527"
	local max_wait = 30
	local waited = 0
	local interval = 1

	while waited < max_wait do
		local info = check_port(port)
		if not info.listening then
			http.prepare_content("application/json")
			http.write_json({ state = "stopped", waited = waited })
			return
		end
		sh("sleep " .. tostring(interval))
		waited = waited + interval
	end

	http.prepare_content("application/json")
	http.write_json({ state = "timeout", waited = waited })
end

function action_service_ctl()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local action = http.formvalue("action") or ""

	if action == "start" then
		local install_path = uci:get("clawpanel", "main", "install_path") or ""
		local cp_bin = install_path ~= "" and (install_path .. "/clawpanel/clawpanel") or ""
		-- 直接用bash后台启动（nohup在iStoreOS上不存在）
		sh("(export HOME=/root; /bin/bash -c '" .. cp_bin .. " >/tmp/clawpanel.log 2>&1&')")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Starting..." })

	elseif action == "stop" then
		sh("killall -9 clawpanel 2>/dev/null")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Stopped" })

	elseif action == "restart" then
		local install_path = uci:get("clawpanel", "main", "install_path") or ""
		local cp_bin = install_path ~= "" and (install_path .. "/clawpanel/clawpanel") or ""
		sh("killall -9 clawpanel 2>/dev/null; sleep 1")
		sh("(export HOME=/root; /bin/bash -c '" .. cp_bin .. " >/tmp/clawpanel.log 2>&1&')")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Restarting..." })

	elseif action == "enable" then
		sh("/etc/init.d/clawpanel enable 2>/dev/null")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Enabled" })

	elseif action == "disable" then
		sh("/etc/init.d/clawpanel disable 2>/dev/null")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Disabled" })

	elseif action == "setup" then
		sh("rm -f /tmp/clawpanel-setup.log /tmp/clawpanel-setup.pid /tmp/clawpanel-setup.exit")

		local version = http.formvalue("version") or ""
		local install_path = http.formvalue("install_path") or ""
		install_path = install_path:gsub("[^%w%-%./]", ""):gsub("/+$", ""):gsub("%.%.", "")

		if install_path == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "install_path cannot be empty" })
			return
		end

		local openclaw_dir = http.formvalue("openclaw_dir") or ""
		openclaw_dir = openclaw_dir:gsub("[^%w%-%./]", ""):gsub("%.%.", "")
		if openclaw_dir == "" then
			openclaw_dir = install_path .. "/clawpanel/data"
		end

		sh("uci set clawpanel.main.install_path='" .. install_path .. "'")
		sh("uci set clawpanel.main.openclaw_dir='" .. openclaw_dir .. "'")
		sh("uci commit clawpanel 2>/dev/null")

		local env_prefix = ""
		if version ~= "" and version ~= "latest" then
			env_prefix = "CP_VERSION=" .. version .. " "
		end

		sh("( " .. env_prefix .. "CP_BASE_PATH='" .. install_path .. "' CP_OPENCLAW_DIR='" .. openclaw_dir .. "' /usr/bin/clawpanel-env setup >> /tmp/clawpanel-setup.log 2>&1; echo $? > /tmp/clawpanel-setup.exit ) & echo $! > /tmp/clawpanel-setup.pid")

		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Installation started in background. Please wait..." })

	else
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "Unknown action: " .. action })
	end
end

function action_setup_log()
	local http = require "luci.http"
	local log = ""

	local f = io.open("/tmp/clawpanel-setup.log", "r")
	if f then
		log = f:read("*a") or ""
		f:close()
	end

	local running = false
	local stored_pid = ""

	local pidf = io.open("/tmp/clawpanel-setup.pid", "r")
	if pidf then
		stored_pid = trim(pidf:read("*a"))
		pidf:close()
		if stored_pid ~= "" then
			running = is_running(stored_pid)
		end
	end

	local exit_code = -1
	if not running then
		local ef = io.open("/tmp/clawpanel-setup.exit", "r")
		if ef then
			local code = trim(ef:read("*a"))
			ef:close()
			local ok, val = pcall(tonumber, code)
			exit_code = (ok and val) and val or -1
		end
	end

	local state = "idle"
	if running then
		if exit_code == 0 then
			state = "success"
		else
			state = "running"
		end
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({ state = state, exit_code = exit_code, log = log })
end

function action_uninstall()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()

	local logf = io.open("/tmp/clawpanel-uninstall.log", "w")
	local function log(msg)
		if logf then
			logf:write(msg .. "\n")
			logf:flush()
		end
	end

	log("=== ClawPanel Uninstall Started ===")

	local install_path = uci:get("clawpanel", "main", "install_path") or ""
	local cp_path = install_path ~= "" and (install_path .. "/clawpanel") or ""

	log("Stopping ClawPanel service...")
	sh("/etc/init.d/clawpanel stop >/dev/null 2>&1")
	sh("sleep 2")
	log("Killing all clawpanel processes...")
	sh("killall -9 clawpanel 2>/dev/null; sleep 1")
	log("Service stopped")

	log("Disabling auto-start...")
	sh("/etc/init.d/clawpanel disable 2>/dev/null")
	sh("uci set clawpanel.main.enabled=0; uci commit clawpanel 2>/dev/null")
	log("Auto-start disabled")

	if cp_path ~= "" and cp_path ~= "/" then
		log("Removing files from " .. cp_path .. "...")
		sh("rm -rf " .. cp_path)
		log("Files removed")
	else
		log("No valid install path to remove")
	end

	log("Cleaning up UCI config...")
	sh("uci revert clawpanel 2>/dev/null; uci commit clawpanel 2>/dev/null")
	log("Cleanup complete")
	log("=== Uninstall Finished ===")

	if logf then logf:close() end

	http.prepare_content("application/json")
	http.write_json({ status = "ok", message = "ClawPanel fully uninstalled" })
end

function action_uninstall_log()
	local http = require "luci.http"
	local log = ""

	local f = io.open("/tmp/clawpanel-uninstall.log", "r")
	if f then
		log = f:read("*a") or ""
		f:close()
	end

	local uci = require "luci.model.uci".cursor()
	local install_path = uci:get("clawpanel", "main", "install_path") or ""
	local completed = (install_path == "")

	http.prepare_content("application/json")
	http.write_json({ log = log, completed = completed })
end

-- 列出系统外置存储挂载点（供 basic.htm 安装向导使用）
function action_mounts()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local current_install_path = uci:get("clawpanel", "main", "install_path") or ""

	-- 读取 /proc/mounts 找外置挂载点
	local mounts = {}
	local f = io.open("/proc/mounts", "r")
	if f then
		for line in f:lines() do
			local dev, mp, fs = line:match("^([^%s]+)%s+([^%s]+)%s+([^%s]+)")
			if mp then
				-- 排除系统分区
				local is_system = false
				local system_paths = {"/", "/overlay", "/rom", "/boot", "/proc", "/sys", "/dev", "/tmp", "/var"}
				for _, sp in ipairs(system_paths) do
					if mp == sp or mp:find("^" .. sp .. "/") then
						is_system = true
						break
					end
				end
				if not is_system and (fs == "ext4" or fs == "vfat" or fs == "ntfs" or fs == "exfat" or fs == "f2fs" or fs == "ubifs") then
					-- 获取可用空间
					local df = io.popen("df -m '" .. mp .. "' 2>/dev/null")
					local df_out = df and df:read("*a") or ""
					if df then df:close() end
					local avail_mb = tonumber(df_out:match("\n(%d+)%s+%d+%s+%d+%s+%d+%s+%d%%%s+" .. mp:gsub("/", "%%%/"))) or 0
					local total_mb = tonumber(df_out:match("(%d+)%s+%d+%s+%d+%s+%d+%s+%d%%%s+" .. mp:gsub("/", "%%%/"))) or 0
					local size_str = ""
					if total_mb > 1024 then
						size_str = string.format("%.1f GB", total_mb / 1024)
					else
						size_str = total_mb .. " MB"
					end
					table.insert(mounts, {
						mount = mp,
						fs = fs,
						size = size_str,
						avail_mb = avail_mb,
						is_current = (mp == current_install_path or current_install_path:find("^" .. mp:gsub("/", "%%%/") .. "/"))
					})
				end
			end
		end
		f:close()
	end

	-- 按可用空间降序排列
	table.sort(mounts, function(a, b) return a.avail_mb > b.avail_mb end)

	http.prepare_content("application/json")
	http.write_json({ mounts = mounts, current_install_path = current_install_path })
end

-- 安装前系统检查（内存、磁盘）
function action_check_system()
	local http = require "luci.http"
	local install_path = http.formvalue("install_path") or ""

	local memory_mb = 0
	local f = io.open("/proc/meminfo", "r")
	if f then
		local content = f:read("*a") or ""
		f:close()
		local total = tonumber(content:match("MemTotal:%s+(%d+)")) or 0
		memory_mb = math.floor(total / 1024)
	end

	local disk_mb = 0
	if install_path ~= "" then
		local df = io.popen("df -m '" .. install_path .. "' 2>/dev/null")
		local df_out = df and df:read("*a") or ""
		if df then df:close() end
		disk_mb = tonumber(df_out:match("\n(%d+)%s+%d+%s+%d+%s+%d+%s+%d%%%s+" .. install_path:gsub("/", "%%%/"))) or 0
	end

	local pass = (memory_mb >= 256) and (disk_mb >= 500)
	http.prepare_content("application/json")
	http.write_json({
		memory_mb = memory_mb,
		memory_ok = (memory_mb >= 256),
		disk_mb = disk_mb,
		disk_ok = (disk_mb >= 500),
		pass = pass
	})
end

-- 检测插件更新（对比本地 VERSION 与 GitHub 最新）
function action_check_update()
	local http = require "luci.http"

	-- 读取本地版本
	local local_ver = "1.0.0"
	local f = io.open("/usr/share/clawpanel/VERSION", "r")
	if f then
		local_ver = trim(f:read("*a") or "")
		f:close()
	end

	-- 读取 GitHub 最新 release（插件本身是 luci-app-clawpanel，非 ClawPanel 二进制）
	local latest_ver = local_ver
	local tag = sh("git ls-remote --tags https://github.com/a10463981/luci-app-clawpanel 2>/dev/null | grep -v '{}' | awk -F'/' '{print $3}' | grep '^v' | sort -V | tail -1"):gsub("^v", ""):gsub("[^%d%.]", "")
	if tag and tag ~= "" then
		latest_ver = tag
	end

	http.prepare_content("application/json")
	http.write_json({
		plugin_current = local_ver,
		plugin_latest = latest_ver,
		plugin_has_update = (local_ver ~= latest_ver)
	})
end
