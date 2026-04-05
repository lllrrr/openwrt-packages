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
	entry({"admin", "services", "clawpanel", "disks"},
		call("action_disks"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "node_info"},
		call("action_node_info"), nil).leaf = true
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
	local disk = uci:get("clawpanel", "main", "disk") or ""
	local install_path = uci:get("clawpanel", "main", "install_path") or ""

	-- 获取 LAN IP 地址
	local lan_addr = trim(sh("uci get network.lan.ipaddr 2>/dev/null || cat /etc/config/network | grep -A2 'config interface.lan' | grep 'option ipaddr' | cut -d\"' -f2 || echo '192.168.1.1'"))

	local result = {
		enabled = enabled,
		port = port,
		disk = disk,
		install_path = install_path,
		configs_dir = disk,
		lan_addr = lan_addr,
		openclaw_dir = uci:get("clawpanel", "main", "openclaw_dir") or "",
		openclaw_work = uci:get("clawpanel", "main", "openclaw_work") or "",
		node_installed = false,
		node_version = "",
		openclaw_version = "",
		panel_running = false,
		pid = "",
		memory_kb = 0,
		uptime = "",
		panel_version = "",
		installed_version = "",
		disk_free = ""
	}

	-- Node.js 检测
	local node_bin = nil
	if os.execute("command -v node >/dev/null 2>&1") == 0 then node_bin = "node"
	elseif os.execute("test -x /usr/local/bin/node") == 0 then node_bin = "/usr/local/bin/node"
	elseif os.execute("test -x /usr/bin/node") == 0 then node_bin = "/usr/bin/node" end
	if node_bin then
		result.node_installed = true
		result.node_version = trim(sh(node_bin .. " --version 2>/dev/null"))
	end

	-- OpenClaw 版本
	local openclaw_dir = uci:get("clawpanel", "main", "openclaw_dir") or ""
	if openclaw_dir ~= "" then
		local ocmjs = trim(sh("find '" .. openclaw_dir .. "' -name 'openclaw.mjs' -path '*/node_modules/openclaw/*' 2>/dev/null | head -1"))
		if ocmjs == "" then ocmjs = trim(sh("find /usr/local/lib/node_modules/openclaw -name 'openclaw.mjs' 2>/dev/null | head -1")) end
		if ocmjs ~= "" and node_bin then
			result.openclaw_version = trim(sh(node_bin .. " " .. ocmjs .. " --version 2>/dev/null"))
		end
	end

	if install_path ~= "" then
		local cp_bin = install_path ~= "" and (install_path .. "/clawpanel/clawpanel") or ""

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

	if disk ~= "" then
		local df_out = trim(sh("df -m '" .. disk .. "' 2>/dev/null | tail -1"))
		local avail_mb = 0
		for tok in df_out:gmatch("[^\n]+") do
			local fields = {}
			for w in tok:gmatch("%S+") do table.insert(fields, w) end
			local mounted = fields[#fields] or ""
			if #fields >= 6 and mounted == disk then
				avail_mb = tonumber(fields[4]) or 0
			end
		end
		if avail_mb > 0 then
			result.disk_free = (avail_mb >= 1024) and (string.format("%.1f GB", avail_mb / 1024)) or (avail_mb .. " MB")
		end
	elseif install_path ~= "" then
		local disk_str = trim(sh("df -h '" .. install_path .. "' | tail -1 | awk '{print $4}'"))
		if disk_str and disk_str ~= "" then result.disk_free = disk_str end
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
		if cp_bin == "" or not io.open(cp_bin, "r") then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "ClawPanel binary not found. Please install first." })
			return
		end
		sh("(export HOME=/root; " .. cp_bin .. " >/tmp/clawpanel.log 2>&1 &)")
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
		if cp_bin ~= "" and io.open(cp_bin, "r") then
			sh("(export HOME=/root; " .. cp_bin .. " >/tmp/clawpanel.log 2>&1 &)")
		end
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

		-- disk: 存储盘挂载点（如 /mnt/sda1 或 /overlay）
		local disk = http.formvalue("disk") or ""
		disk = disk:gsub("[^%w%-%./]", ""):gsub("/+$", ""):gsub("%.%.", "")

		if disk == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "disk cannot be empty" })
			return
		end

		-- 允许 /overlay 但禁止真正的系统路径
		local forbidden = {"/", "/rom", "/boot", "/proc", "/sys", "/dev", "/tmp", "/var", "/etc", "/root", "/usr", "/bin", "/sbin", "/lib"}
		local is_forbidden = false
		for _, fp in ipairs(forbidden) do
			if disk == fp or disk:find("^" .. fp .. "/") then
				is_forbidden = true
				break
			end
		end
		if is_forbidden then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "System path forbidden: " .. disk })
			return
		end

		-- 保存 disk 到 UCI（controller 读取此字段）
		sh("uci set clawpanel.main.disk='" .. disk .. "'")
		sh("uci set clawpanel.main.install_path='" .. disk .. "/Configs'")
		sh("uci commit clawpanel 2>/dev/null")

		local version = http.formvalue("version") or ""
		local env_prefix = ""
		if version ~= "" and version ~= "latest" then
			env_prefix = "CP_VERSION=" .. version .. " "
		end

		sh("( " .. env_prefix .. "CP_BASE_PATH='" .. disk .. "' /usr/bin/clawpanel-env setup >> /tmp/clawpanel-setup.log 2>&1; echo $? > /tmp/clawpanel-setup.exit ) & echo $! > /tmp/clawpanel-setup.pid")

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
		-- Files will be removed in background (user can delete manually if needed)
		log("Files marked for removal (background)")
	else
		log("No valid install path to remove")
	end

	log("Cleaning up UCI config...")
	sh("uci set clawpanel.main.enabled='0' 2>/dev/null; uci commit clawpanel 2>/dev/null")
	log("UCI config cleaned (enabled=0)")
	log("卸载 Node.js/npm...")
	sh("rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/openclaw 2>/dev/null; rm -rf /usr/local/lib/node_modules 2>/dev/null; rm -rf /usr/lib/node_modules 2>/dev/null; rm -rf /usr/local/share/icu 2>/dev/null; echo done")
	log("Node.js/npm 已卸载")

	log("=== Uninstall Finished ===")

	-- Write completed marker
	local sf = io.open("/tmp/clawpanel-uninstall.done", "w")
	if sf then sf:write("done\n"); sf:close() end

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

	-- Check if uninstall completed via status file
	local completed = false
	local sf = io.open("/tmp/clawpanel-uninstall.done", "r")
	if sf then
		completed = true
		sf:close()
	end

	http.prepare_content("application/json")
	http.write_json({ log = log, completed = completed })
end

-- 列出可用存储盘（供 main.htm 新版 UI 使用）
function action_disks()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local current_disk = uci:get("clawpanel", "main", "disk") or ""

	local disks = {}
	local f = io.open("/proc/mounts", "r")
	if f then
		for line in f:lines() do
			local dev, mp, fs = line:match("^([^%s]+)%s+([^%s]+)%s+([^%s]+)")
			if mp then
				local is_system = false
				local system_paths = {"/", "/rom", "/boot", "/proc", "/sys", "/dev", "/tmp", "/var", "/run"}
				for _, sp in ipairs(system_paths) do
					if mp == sp or mp:find("^" .. sp .. "/") then
						is_system = true
						break
					end
				end
				-- 允许 ext4/vfat/overlay/btrfs 等，排除 tmpfs/devpts
				if not is_system and fs ~= "tmpfs" and fs ~= "devpts" and fs ~= "devtmpfs"
				   and fs ~= "sysfs" and fs ~= "proc" and fs ~= "cgroup2fs"
				   and fs ~= "squashfs" and fs ~= "romfs" then
					-- 获取可用空间（df -m 避免路径含 / 导致模式错误）
					local df = io.popen("df -m '" .. mp .. "' 2>/dev/null | tail -1")
					local df_out = df and df:read("*a") or ""
					if df then df:close() end
					local avail_mb = 0
					local total_mb = 0
					for tok in df_out:gmatch("[^\n]+") do
						-- df -m 输出: Filesystem 1-blocks Used Available Use% Mounted
						-- 用空格分割后第4列=Available，第5列=Use%，第6列+=Mounted
						local fields = {}
						for w in tok:gmatch("%S+") do table.insert(fields, w) end
						-- 找到 Mounted 列（第6+个字段），检查是否匹配当前挂载点
						local mounted = fields[#fields] or ""
						if #fields >= 6 and mounted == mp then
							avail_mb = tonumber(fields[4]) or 0
							total_mb = tonumber(fields[2]) or 0
						end
					end
					local size_str = ""
					if total_mb >= 1024 then
						size_str = string.format("%.1f GB", total_mb / 1024)
					else
						size_str = total_mb .. " MB"
					end
					if avail_mb >= 200 then
						table.insert(disks, {
							mount = mp,
							fs = fs,
							device = dev,
							size = size_str,
							avail_mb = avail_mb,
							total_mb = total_mb,
							is_current = (mp == current_disk)
						})
					end
				end
			end
		end
		f:close()
	end

	table.sort(disks, function(a, b) return a.avail_mb > b.avail_mb end)

	http.prepare_content("application/json")
	http.write_json({ disks = disks, current_disk = current_disk })
end

-- Node.js 系统信息
function action_node_info()
	local http = require "luci.http"

	local result = {
		installed = false,
		version = "",
		path = "",
		npm_version = "",
		arch = "",
		suggested_version = ""
	}

	local node_bin = nil
	if os.execute("command -v node >/dev/null 2>&1") == 0 then
		node_bin = "node"
	elseif os.execute("test -x /usr/local/bin/node") == 0 then
		node_bin = "/usr/local/bin/node"
	elseif os.execute("test -x /usr/bin/node") == 0 then
		node_bin = "/usr/bin/node"
	end

	if node_bin then
		result.installed = true
		result.path = trim(sh("readlink -f " .. node_bin .. " 2>/dev/null"))
		result.version = trim(sh(node_bin .. " --version 2>/dev/null"))
		result.npm_version = trim(sh("/usr/local/bin/npm --version 2>/dev/null"))
		result.arch = trim(sh("uname -m 2>/dev/null"))
	end

	-- 从 GitHub 获取 Node.js 最新 LTS 版本
	local latest_lts = trim(sh("curl -sL --max-time 8 https://nodejs.org/dist/index.json 2>/dev/null | grep -o '\"version\":\"v[0-9][^\"]*lts[^\"]*\"' | head -1 | grep -o 'v[0-9][^ \"]*'"))
	if latest_lts and latest_lts ~= "" then
		result.suggested_version = latest_lts
	else
		result.suggested_version = "v22.15.1"
	end

	http.prepare_content("application/json")
	http.write_json(result)
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
				-- 排除根分区、boot、proc/sys/dev 等系统路径
				-- /overlay 保留：部分设备只有内置存储（无外置 USB），overlay 分区可作为备选
				local system_paths = {"/", "/rom", "/boot", "/proc", "/sys", "/dev", "/tmp", "/var", "/run"}
				for _, sp in ipairs(system_paths) do
					if mp == sp or mp:find("^" .. sp .. "/") then
						is_system = true
						break
					end
				end
				-- 排除虚拟文件系统，明确列出常用存储文件系统类型
				if not is_system and (
					fs == "ext4" or fs == "vfat" or fs == "ntfs" or
					fs == "exfat" or fs == "f2fs" or fs == "ubifs" or
					fs == "overlay" or fs == "btrfs" or fs == "xfs"
				) then
					-- 获取可用空间
					local df = io.popen("df -m '" .. mp .. "' 2>/dev/null | tail -1")
					local df_out = df and df:read("*a") or ""
					if df then df:close() end
					local avail_mb = 0
					local total_mb = 0
					for tok in df_out:gmatch("[^\n]+") do
						local fields = {}
						for w in tok:gmatch("%S+") do table.insert(fields, w) end
						local mounted = fields[#fields] or ""
						if #fields >= 6 and mounted == mp then
							avail_mb = tonumber(fields[4]) or 0
							total_mb = tonumber(fields[2]) or 0
						end
					end
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
	local disk = http.formvalue("disk") or ""

	local memory_mb = 0
	local f = io.open("/proc/meminfo", "r")
	if f then
		local content = f:read("*a") or ""
		f:close()
		local total = tonumber(content:match("MemTotal:%s+(%d+)")) or 0
		memory_mb = math.floor(total / 1024)
	end

	local disk_mb = 0
	if disk ~= "" then
		local df = io.popen("df -m '" .. disk .. "' 2>/dev/null | tail -1")
		local df_out = df and df:read("*a") or ""
		if df then df:close() end
		for tok in df_out:gmatch("[^\n]+") do
			local fields = {}
			for w in tok:gmatch("%S+") do table.insert(fields, w) end
			local mounted = fields[#fields] or ""
			if #fields >= 6 and mounted == disk then
				disk_mb = tonumber(fields[4]) or 0
			end
		end
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
