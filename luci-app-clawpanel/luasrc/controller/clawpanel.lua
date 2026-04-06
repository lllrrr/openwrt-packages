-- luci-app-clawpanel controller v1.3.0
-- 重构: PID 文件追踪 + OpenClaw 三态检测 + 统一进程管理
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

--===========================================================
-- 路径管理（集中计算，只算一次）
--===========================================================
local PID_FILE = "/var/run/clawpanel.pid"

local function get_uci_val(key)
	local f = io.popen("uci -q get clawpanel.main." .. key)
	if not f then return "" end
	local v = trim(f:read("*a"))
	f:close()
	return v
end

-- 获取 ClawPanel 所有路径（统一入口，避免路径拼接错误）
local function get_paths()
	local disk = get_uci_val("disk")
	local install_path = get_uci_val("install_path") or ""
	local port = get_uci_val("port") or "19527"
	
	local configs_dir = install_path  -- /Configs
	local clawpanel_bin = configs_dir .. "/clawpanel/clawpanel"
	local clawpanel_data = configs_dir .. "/clawpanel/data"
	local clawpanel_json = clawpanel_data .. "/clawpanel.json"
	local openclaw_dir = get_uci_val("openclaw_dir") or (configs_dir .. "/openclaw")
	local openclaw_work = configs_dir .. "/.openclaw-work"
	
	return {
		disk = disk,
		install_path = install_path,
		configs_dir = configs_dir,
		clawpanel_bin = clawpanel_bin,
		clawpanel_data = clawpanel_data,
		clawpanel_json = clawpanel_json,
		openclaw_dir = openclaw_dir,
		openclaw_work = openclaw_work,
		port = port
	}
end

--===========================================================
-- 进程管理
--===========================================================
local function is_running(pid)
	if not pid or pid == "" then return false end
	return trim(sh("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no")) == "yes"
end

-- 读取 PID 文件
local function read_pid()
	local f = io.open(PID_FILE, "r")
	if not f then return nil end
	local pid = trim(f:read("*a"))
	f:close()
	local n = tonumber(pid)
	return n and n > 0 and pid or nil
end

-- 检查端口是否监听
local function check_port(port)
	local line = trim(sh("netstat -tulnp 2>/dev/null | grep ':" .. port .. " ' | head -1"))
	if line and line ~= "" then
		local pid = line:match("(%d+)%/%S+")
		return { listening = true, pid = pid or "" }
	end
	return { listening = false, pid = "" }
end

-- 等待端口释放（restart 时用）
local function wait_port_free(port, max_wait)
	max_wait = max_wait or 10
	local waited = 0
	while waited < max_wait do
		local info = check_port(port)
		if not info.listening then return true end
		sh("sleep 1")
		waited = waited + 1
	end
	return false
end

-- 杀进程（统一用 killall，不依赖 pkill）
local function kill_clawpanel()
	-- 先读 PID 文件精确杀
	local pid = read_pid()
	if pid then
		sh("kill -9 " .. pid .. " 2>/dev/null")
	end
	-- 再用 killall 兜底（杀所有相关进程）
	sh("killall -9 clawpanel 2>/dev/null")
	sh("rm -f " .. PID_FILE)
end

--===========================================================
-- OpenClaw 检测（三态：not_installed / broken / ready）
--===========================================================
local function detect_node()
	local np
	np = trim(sh("command -v node 2>/dev/null"))
	if np ~= "" and sh("test -x " .. np) == "" then return np end
	if sh("test -x /usr/local/bin/node") == "" then return "/usr/local/bin/node" end
	if sh("test -x /usr/bin/node") == "" then return "/usr/bin/node" end
	return nil
end

local function check_openclaw()
	-- 返回: { status, version, path, reason }
	local paths = get_paths()
	local node_bin = detect_node()
	
	if not node_bin then
		return { status = "broken", version = "", path = "", reason = "Node.js not found" }
	end
	
	-- 候选 openclaw.mjs 路径（按优先级）
	local candidates = {
		"/usr/local/bin/openclaw",
		"/usr/local/lib/node_modules/openclaw/bin/openclaw.mjs",
		paths.openclaw_dir .. "/bin/openclaw.mjs"
	}
	
	for _, p in ipairs(candidates) do
		-- 先检查文件是否存在
		if sh("test -f " .. p) == "" then
			-- 文件存在，验证是否真正可用（执行 --version）
			local v = trim(sh("PATH=/usr/local/bin:$PATH " .. node_bin .. " " .. p .. " --version 2>/dev/null"))
			if v and v ~= "" and not v:find("not found") and not v:find("error") then
				return { status = "ready", version = v, path = p, reason = "" }
			end
		end
	end
	
	-- 检查是否有 package.json 但缺 openclaw.mjs（损坏状态）
	for _, p in ipairs(candidates) do
		local pkg = p:gsub("/bin/openclaw.mjs", "/package.json")
		if sh("test -f " .. pkg) == "" and sh("test -f " .. p) ~= "" then
			return { status = "broken", version = "", path = p, reason = "openclaw.mjs not executable" }
		end
	end
	
	return { status = "not_installed", version = "", path = "", reason = "" }
end

--===========================================================
-- 路由注册
--===========================================================
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
	entry({"admin", "services", "clawpanel", "disks"},
		call("action_disks"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "node_info"},
		call("action_node_info"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "check_system"},
		call("action_check_system"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "check_update"},
		call("action_check_update"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "plugin_versions"},
		call("action_plugin_versions"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "clawpanel_versions"},
		call("action_clawpanel_versions"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "node_latest"},
		call("action_node_latest"), nil).leaf = true
	entry({"admin", "services", "clawpanel", "install_openclaw"}, call("action_install_openclaw"), nil).leaf = true
entry({"admin", "services", "clawpanel", "install_openclaw_status"}, call("action_install_openclaw_status"), nil).leaf = true
entry({"admin", "services", "clawpanel", "upgrade_plugin"},
		call("action_upgrade_plugin"), nil).leaf = true
end

--===========================================================
-- 状态 API
--===========================================================
function action_status()
	local http = require "luci.http"
	local paths = get_paths()
	local port_info = check_port(paths.port)
	
	local result = {
		enabled = get_uci_val("enabled"),
		port = paths.port,
		disk = paths.disk,
		install_path = paths.configs_dir,
		configs_dir = paths.configs_dir,
		lan_addr = trim(sh("uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1'")),
		openclaw_dir = paths.openclaw_dir,
		panel_running = port_info.listening,
		pid = port_info.pid,
		memory_kb = 0,
		uptime = "",
		panel_version = "",
		node_installed = false,
		node_version = "",
		openclaw = { status = "not_installed", version = "", path = "", reason = "" }
	}
	
	-- Node.js 检测
	local node_bin = detect_node()
	if node_bin then
		result.node_installed = true
		result.node_version = trim(sh(node_bin .. " --version 2>/dev/null"))
	end
	
	-- ClawPanel 版本（优先读 .version 文件，避免每次调用二进制）
	local vf = io.open(paths.clawpanel_bin:gsub("/clawpanel$", "/.version"), "r")
	if vf then
		result.panel_version = trim(vf:read("*a"))
		vf:close()
	end
	if result.panel_version == "" then
		-- fallback: 调用 --version（带超时）
		if os.execute("command -v timeout >/dev/null 2>&1") == 0 then
			result.panel_version = trim(sh("timeout 3 " .. paths.clawpanel_bin .. " --version 2>/dev/null"))
		end
	end
	
	-- OpenClaw 三态检测
	local oc = check_openclaw()
	result.openclaw = oc
	
	-- 内存和运行时间
	if result.panel_running and result.pid and result.pid ~= "" then
		local pid_num = tonumber(result.pid)
		if pid_num and pid_num > 0 then
			local rss_raw = trim(sh("awk '/VmRSS/{print $2}' /proc/" .. result.pid .. "/status 2>/dev/null"))
			local ok1, rss_val = pcall(function() return tonumber(rss_raw) end)
			result.memory_kb = (ok1 and rss_val) and rss_val or 0
			
			-- 启动时间（从 /proc/pid/stat 取 starttime）
			local starttime = trim(sh("awk '{print $22}' /proc/" .. result.pid .. "/stat 2>/dev/null"))
			if starttime and starttime ~= "" then
				local st_val = tonumber(starttime)
				if st_val then
					-- uptime_sec = 总 jiffies / Hz
					local f = io.open("/proc/uptime", "r")
					local uptime_total = 0
					if f then
						local up_str = f:read("*a") or ""
						f:close()
						uptime_total = tonumber(up_str:match("^%s*(%S+)")) or 0
					end
					local hz = 100
					local f_hz = io.open("/proc/cpuinfo", "r")
					if f_hz then
						local cpuinfo = f_hz:read("*a") or ""
						f_hz:close()
						local hz_match = cpuinfo:match("cpu MHz%s+:%s+(%S+)")
						if hz_match then
							hz = 100  -- OpenWrt 通常 100 Hz
						end
					end
					local elapsed_sec = uptime_total - (st_val / hz)
					if elapsed_sec > 0 then
						local h = math.floor(elapsed_sec / 3600)
						local m = math.floor((elapsed_sec % 3600) / 60)
						local s = math.floor(elapsed_sec % 60)
						if h > 0 then result.uptime = string.format("%dh %dm %ds", h, m, s)
						elseif m > 0 then result.uptime = string.format("%dm %ds", m, s)
						else result.uptime = s .. "s" end
					end
				end
			end
		end
	end
	
	-- 磁盘剩余空间
	if paths.disk ~= "" then
		local df_out = trim(sh("df -m '" .. paths.disk .. "' 2>/dev/null | tail -1"))
		local avail_mb = 0
		for tok in df_out:gmatch("[^\n]+") do
			local fields = {}
			for w in tok:gmatch("%S+") do table.insert(fields, w) end
			local mounted = fields[#fields] or ""
			if #fields >= 4 and mounted == paths.disk then
				avail_mb = tonumber(fields[4]) or 0
			end
		end
		if avail_mb > 0 then
			result.disk_free = (avail_mb >= 1024) and string.format("%.1f GB", avail_mb / 1024) or (avail_mb .. " MB")
		end
	end
	
	http.prepare_content("application/json")
	http.write_json(result)
end

function action_wait_running()
	local http = require "luci.http"
	local paths = get_paths()
	local max_wait = 90
	local waited = 0
	local interval = 3

	while waited < max_wait do
		local info = check_port(paths.port)
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
	local paths = get_paths()
	local max_wait = 30
	local waited = 0
	local interval = 1

	while waited < max_wait do
		local info = check_port(paths.port)
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

--===========================================================
-- 服务控制（start/stop/restart — 核心修复）
--===========================================================
function action_service_ctl()
	local http = require "luci.http"
	local action = http.formvalue("action") or ""
	local paths = get_paths()

	--========== STOP ==========
	if action == "stop" then
		kill_clawpanel()
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Stopped" })

	--========== START ==========
	elseif action == "start" then
		-- 检查二进制是否存在
		if sh("test -x " .. paths.clawpanel_bin) ~= "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "ClawPanel binary not found at: " .. paths.clawpanel_bin })
			return
		end
		
		-- 确保数据目录存在
		sh("mkdir -p " .. paths.clawpanel_data)
		
		-- 先杀旧进程（如果存在）
		kill_clawpanel()
		
		-- 等待端口释放（最多 5 秒）
		wait_port_free(paths.port, 5)
		
		-- 用 setsid 完全脱离终端启动（关键修复）
		local start_cmd = string.format(
			"setsid env HOME=/root PATH=/usr/local/bin:$PATH NODE_ICU_DATA=/usr/local/share/icu LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH %s >> /tmp/clawpanel.log 2>&1 < /dev/null & echo $!",
			paths.clawpanel_bin
		)
		local out = trim(sh(start_cmd))
		local new_pid = nil
		if out and out ~= "" then
			local n = tonumber(out)
			if n and n > 0 then
				new_pid = out
				-- 写 PID 文件
				local pf = io.open(PID_FILE, "w")
				if pf then pf:write(out .. "\n"); pf:close() end
			end
		end
		
		-- 等待一下再返回，让进程有机会启动
		sh("sleep 2")
		
		-- 验证是否真的启动了
		local info = check_port(paths.port)
		if info.listening then
			http.prepare_content("application/json")
			http.write_json({ status = "ok", message = "Started", pid = info.pid })
		else
			http.prepare_content("application/json")
			http.write_json({ status = "ok", message = "Start initiated (pid=" .. (new_pid or "?") .. "), please check status after a moment", pid = new_pid or "" })
		end

	--========== RESTART ==========
	elseif action == "restart" then
		-- 1. 杀旧进程
		kill_clawpanel()
		
		-- 2. 等待端口真正释放（关键：不能只 sleep 1）
		wait_port_free(paths.port, 10)
		
		-- 3. 检查二进制
		if sh("test -x " .. paths.clawpanel_bin) ~= "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "Binary not found" })
			return
		end
		
		-- 4. 启动
		sh("mkdir -p " .. paths.clawpanel_data)
		local start_cmd = string.format(
			"setsid env HOME=/root PATH=/usr/local/bin:$PATH NODE_ICU_DATA=/usr/local/share/icu LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH %s >> /tmp/clawpanel.log 2>&1 < /dev/null & echo $!",
			paths.clawpanel_bin
		)
		local out = trim(sh(start_cmd))
		local new_pid = nil
		if out and out ~= "" then
			local n = tonumber(out)
			if n and n > 0 then
				new_pid = out
				local pf = io.open(PID_FILE, "w")
				if pf then pf:write(out .. "\n"); pf:close() end
			end
		end
		
		sh("sleep 2")
		local info = check_port(paths.port)
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Restarted", pid = info.pid or new_pid or "" })

	--========== ENABLE/DISABLE ==========
	elseif action == "enable" then
		sh("/etc/init.d/clawpanel enable 2>/dev/null")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Enabled" })

	elseif action == "disable" then
		sh("/etc/init.d/clawpanel disable 2>/dev/null")
		http.prepare_content("application/json")
		http.write_json({ status = "ok", message = "Disabled" })

	--========== SETUP ==========
	elseif action == "setup" then
		sh("rm -f /tmp/clawpanel-setup.log /tmp/clawpanel-setup.pid /tmp/clawpanel-setup.exit")

		local disk = http.formvalue("disk") or ""
		disk = disk:gsub("[^%w%-%./]", ""):gsub("/+$", ""):gsub("%.%.", "")

		if disk == "" then
			http.prepare_content("application/json")
			http.write_json({ status = "error", message = "disk cannot be empty" })
			return
		end

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

		-- 保存 disk 到 UCI
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

--===========================================================
-- 安装日志
--===========================================================
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
		state = "running"
	elseif exit_code == 0 then
		state = "success"
	elseif exit_code > 0 then
		state = "failed"
	end

	http.prepare_content("application/json")
	http.write_json({ state = state, exit_code = exit_code, log = log })
end

--===========================================================
-- 卸载
--===========================================================
function action_uninstall()
	local http = require "luci.http"
	local paths = get_paths()

	local logf = io.open("/tmp/clawpanel-uninstall.log", "w")
	local function log(msg)
		if logf then
			logf:write(msg .. "\n")
			logf:flush()
		end
	end

	log("=== ClawPanel Uninstall Started ===")

	log("Stopping ClawPanel service...")
	kill_clawpanel()
	sh("sleep 2")
	log("Service stopped")

	log("Disabling auto-start...")
	sh("/etc/init.d/clawpanel disable 2>/dev/null")
	sh("uci set clawpanel.main.enabled=0; uci commit clawpanel 2>/dev/null")
	log("Auto-start disabled")

	log("Removing /Configs directory...")
	if paths.configs_dir ~= "" and paths.configs_dir ~= "/" then
		log("Removing: " .. paths.configs_dir)
		sh("rm -rf " .. paths.configs_dir .. " 2>/dev/null")
	end

	log("Cleaning up Node.js/npm (system-wide,谨慎)...")
	-- 只删除我们安装的，不动系统自带
	sh("rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/openclaw 2>/dev/null")
	sh("rm -rf /usr/local/lib/node_modules/openclaw 2>/dev/null")
	sh("rm -rf /usr/local/share/icu 2>/dev/null")

	log("Cleaning up PID and log files...")
	sh("rm -f /var/run/clawpanel.pid /tmp/clawpanel.log /tmp/clawpanel-setup.log /tmp/clawpanel-setup.pid /tmp/clawpanel-setup.exit 2>/dev/null")

	log("UCI config cleaned")
	log("=== Uninstall Finished ===")

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

	local completed = false
	local sf = io.open("/tmp/clawpanel-uninstall.done", "r")
	if sf then
		completed = true
		sf:close()
	end

	http.prepare_content("application/json")
	http.write_json({ log = log, completed = completed })
end

--===========================================================
-- 存储盘列表
--===========================================================
function action_disks()
	local http = require "luci.http"
	local current_disk = get_uci_val("disk")

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
				if not is_system and fs ~= "tmpfs" and fs ~= "devpts" and fs ~= "devtmpfs"
				   and fs ~= "sysfs" and fs ~= "proc" and fs ~= "cgroup2fs"
				   and fs ~= "squashfs" and fs ~= "romfs" then
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

--===========================================================
-- Node.js 信息
--===========================================================
function action_node_info()
	local http = require "luci.http"

	local result = {
		installed = false,
		version = "",
		path = "",
		npm_version = "",
		arch = "",
		suggested_version = "v22.15.1"
	}

	local node_bin = detect_node()
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
	end

	http.prepare_content("application/json")
	http.write_json(result)
end

--===========================================================
-- 安装前系统检查
--===========================================================
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

--===========================================================
-- 插件更新检测
--===========================================================
function action_check_update()
	local http = require "luci.http"

	local local_ver = "1.0.0"
	local f = io.open("/usr/share/clawpanel/VERSION", "r")
	if f then
		local_ver = trim(f:read("*a") or "")
		f:close()
	end
	if local_ver == "" then local_ver = "1.0.0" end

	-- 获取所有 tag 并找最新
	local tags_raw = trim(sh("git ls-remote --tags https://github.com/a10463981/luci-app-clawpanel 2>/dev/null | grep -v '{}' | awk -F'/' '{print $3}' | grep '^v' | sort -V | tail -20"))
	local latest_ver = local_ver
	if tags_raw and tags_raw ~= "" then
		for tag in tags_raw:gmatch("[^\n]+") do
			local v = tag:gsub("^v", ""):gsub("[^%d%.]", "")
			if v and v ~= "" then
				-- semver 比较（简化版）
				local function ver_cmp(a, b)
					local ta, tb = {}, {}
					for w in a:gmatch("%d+") do table.insert(ta, tonumber(w)) end
					for w in b:gmatch("%d+") do table.insert(tb, tonumber(w)) end
					for i=1, math.max(#ta, #tb) do
						local da, db = ta[i] or 0, tb[i] or 0
						if da ~= db then return da > db end
					end
					return false
				end
				if ver_cmp(v, latest_ver) then latest_ver = v end
			end
		end
	end

	http.prepare_content("application/json")
	http.write_json({
		plugin_current = local_ver,
		plugin_latest = latest_ver,
		plugin_has_update = (local_ver ~= latest_ver)
	})
end

--===========================================================
-- 获取所有插件版本（最新优先排序）
--===========================================================
function action_plugin_versions()
	local http = require "luci.http"

	-- 已知版本列表（git ls-remote 在 OpenWrt 不支持 https，用硬编码）
	local known = {
		{raw="v1.3.1", version="1.3.1"},
		{raw="v1.3.0", version="1.3.0"},
		{raw="v1.2.6", version="1.2.6"},
		{raw="v1.2.0", version="1.2.0"},
		{raw="v1.1.0", version="1.1.0"},
		{raw="v1.0.0", version="1.0.0"},
	}
	local versions = {}
	for _, item in ipairs(known) do versions[#versions+1] = item end

	-- 倒序（最新在前）
	table.sort(versions, function(a, b)
		local function parse_ver(s)
			local t = {}
			for w in s:gmatch("%d+") do t[#t+1] = tonumber(w) or 0 end
			return t
		end
		local ta, tb = parse_ver(a.version), parse_ver(b.version)
		for i=1, math.max(#ta, #tb) do
			local da = ta[i] or 0
			local db = tb[i] or 0
			if da ~= db then return da > db end
		end
		return false
	end)

	-- 读取本地版本
	local local_ver = "1.0.0"
	local vf = io.open("/usr/share/clawpanel/VERSION", "r")
	if vf then
		local_ver = trim(vf:read("*a") or "")
		vf:close()
	end

	http.prepare_content("application/json")
	http.write_json({
		versions = versions,
		local_version = local_ver
	})
end
function action_clawpanel_versions()
	local http = require "luci.http"

	-- 从 GitHub API 获取所有 release
	local api_url = "https://api.github.com/repos/zhaoxinyi02/ClawPanel/releases?per_page=50"
	local json_str = trim(sh("curl -sL --connect-timeout 8 '" .. api_url .. "' 2>/dev/null"))

	-- 手动解析 JSON（避免依赖 cjson）
	local releases = {}
	if json_str and json_str ~= "" and json_str:find('"tag_name"') then
		for tag_line in json_str:gmatch('"tag_name"[^,]*') do
			local tag = tag_line:match('"tag_name"%s*:%s*"([^"]+)"')
			if tag then
				-- 提取版本号和类型
				local is_prerelease = false
				local draft = false
				-- 找同一条 release 的 draft/prerelease
				local release_block = json_str:match('"tag_name"%s*:%s*"' .. tag .. '".-}' )
				if release_block then
					if release_block:match('"draft"%s*:%s*true') then draft = true end
					if release_block:match('"prerelease"%s*:%s*true') then is_prerelease = true end
				end
				if not draft then
					table.insert(releases, {
						tag = tag,
						is_prerelease = is_prerelease,
						is_pro = tag:match("^pro%-"),
						is_lite = tag:match("^lite%-")
					})
				end
			end
		end
	end

	-- 如果 API 失败，回退到本地已知版本
	if #releases == 0 then
		releases = {
			{ tag = "pro-v5.3.3", is_prerelease = false, is_pro = true, is_lite = false },
			{ tag = "pro-v5.3.2", is_prerelease = false, is_pro = true, is_lite = false },
			{ tag = "lite-v1.0.0", is_prerelease = false, is_pro = false, is_lite = true }
		}
	end

	http.prepare_content("application/json")
	http.write_json({ releases = releases })
end

--===========================================================
-- 获取 Node.js 最新 LTS 版本（从 nodejs.org）
--===========================================================
function action_node_latest()
	local http = require "luci.http"

	-- 从 nodejs.org/dist/index.json 获取 LTS 版本
	local json_str = trim(sh("curl -sL --max-time 8 https://nodejs.org/dist/index.json 2>/dev/null"))

	local latest_lts = "v22.15.1"
	if json_str and json_str ~= "" then
		-- 找第一个 lts 版本的 version 字段
		-- 格式: {"version":"v23.2.0","lts":true,...}
		for line in json_str:gmatch('{"version":"[^"]+","lts":%s*true[^}]*}') do
			local v = line:match('"version"%s*:%s*"([^"]+)"')
			if v then latest_lts = v; break end
		end
	end

	http.prepare_content("application/json")
	http.write_json({ latest = latest_lts })
end

--===========================================================
-- 一键升级插件（从 GitHub 下载指定版本）
--===========================================================
function action_upgrade_plugin()
	local http = require "luci.http"
	local version = http.formvalue("version") or ""

	if version == "" then
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "version cannot be empty" })
		return
	end

	-- 清理旧日志
	sh("rm -f /tmp/clawpanel-plugin-upgrade.log /tmp/clawpanel-plugin-upgrade.exit")

	-- 构造下载 URL（GitHub 源）
	local url = "https://github.com/a10463981/luci-app-clawpanel/archive/refs/tags/v" .. version .. ".tar.gz"
	local tmp_dir = "/tmp/luci-app-clawpanel-" .. version
	local logf = io.open("/tmp/clawpanel-plugin-upgrade.log", "w")
	local function log(msg)
		if logf then logf:write(msg .. "\n"); logf:flush() end
	end

	log("开始升级 luci-app-clawpanel 到 v" .. version)
	log("下载地址: " .. url)

	-- 下载并解压
	local tarball = "/tmp/luci-app-clawpanel.tar.gz"
	local dl_code = trim(sh("curl -fsSL --connect-timeout 30 -o '" .. tarball .. "' '" .. url .. "' 2>&1; echo $?"))
	if dl_code ~= "0" then
		log("下载失败 (curl exit code: " .. dl_code .. ")")
		if logf then logf:close() end
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "Download failed (HTTP " .. dl_code .. ")", log = "下载失败，请检查网络或版本号是否正确" })
		return
	end

	-- 解压
	sh("rm -rf " .. tmp_dir)
	local ex_code = trim(sh("tar -xzf " .. tarball .. " -C /tmp 2>&1; echo $?"))
	if ex_code ~= "0" then
		log("解压失败 (exit code: " .. ex_code .. ")")
		if logf then logf:close() end
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "Extract failed", log = "解压失败，压缩包可能损坏" })
		return
	end

	-- 检查解压结果
	if sh("test -d " .. tmp_dir) ~= "" then
		log("解压目录不存在: " .. tmp_dir)
		if logf then logf:close() end
		http.prepare_content("application/json")
		http.write_json({ status = "error", message = "Extracted dir not found", log = "解压目录不存在" })
		return
	end

	-- 备份旧文件
	log("备份旧文件...")
	sh("cp /usr/lib/lua/luci/controller/clawpanel.lua /tmp/clawpanel.lua.bak 2>/dev/null")
	sh("cp /usr/lib/lua/luci/view/clawpanel/main.htm /tmp/main.htm.bak 2>/dev/null")
	sh("cp /usr/lib/lua/luci/model/cbi/clawpanel/basic.lua /tmp/basic.lua.bak 2>/dev/null")
	sh("cp /usr/share/clawpanel/VERSION /tmp/VERSION.bak 2>/dev/null")
	log("备份完成")

	-- 安装新文件
	log("安装新文件...")
	sh("cp " .. tmp_dir .. "/luasrc/controller/clawpanel.lua /usr/lib/lua/luci/controller/clawpanel.lua 2>&1")
	sh("cp " .. tmp_dir .. "/luasrc/view/clawpanel/main.htm /usr/lib/lua/luci/view/clawpanel/main.htm 2>&1")
	sh("cp " .. tmp_dir .. "/luasrc/view/clawpanel/basic.htm /usr/lib/lua/luci/view/clawpanel/basic.htm 2>&1")
	sh("cp " .. tmp_dir .. "/luasrc/model/cbi/clawpanel/basic.lua /usr/lib/lua/luci/model/cbi/clawpanel/basic.lua 2>&1")
	sh("cp " .. tmp_dir .. "/root/usr/bin/clawpanel-env /usr/bin/clawpanel-env 2>&1")
	sh("cp " .. tmp_dir .. "/root/etc/init.d/clawpanel /etc/init.d/clawpanel 2>&1")
	sh("chmod +x /usr/bin/clawpanel-env /etc/init.d/clawpanel 2>&1")

	-- 写入版本号
	local vf = io.open("/usr/share/clawpanel/VERSION", "w")
	if vf then vf:write(version .. "\n"); vf:close() end

	-- 清理
	sh("rm -rf " .. tmp_dir .. " " .. tarball)

	-- 重启 uhttpd 使新插件生效
	log("重启 LuCI (uhttpd)...")
	sh("/etc/init.d/uhttpd restart 2>/dev/null")

	log("升级完成！版本: v" .. version)
	if logf then logf:close() end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		message = "Plugin upgraded to v" .. version .. ". LuCI restarting...",
		new_version = version
	})
end


--===========================================================
-- 手动安装 OpenClaw（绕过 ClawPanel 内置安装器的 koffi 编译问题）
-- 使用 npm install --ignore-scripts 跳过 postinstall 编译
--===========================================================
function action_install_openclaw()
	local http = require "luci.http"
	local work_dir = http.formvalue("path") or "/root/.openclaw"
	local LOG_FILE = "/tmp/openclaw_install.log"

	-- 清理旧安装
	sh("rm -rf " .. work_dir .. " 2>/dev/null; mkdir -p " .. work_dir .. " 2>/dev/null")

	-- 写入日志
	local lf = io.open(LOG_FILE, "w")
	local function log(msg)
		if lf then lf:write(msg.."\n"); lf:flush() end
	end
	log("==========================================")
	log("手动安装 OpenClaw")
	log("安装路径: " .. work_dir)
	log("Node: " .. trim(sh("node --version 2>/dev/null")))
	log("NPM: " .. trim(sh("npm --version 2>/dev/null")))
	log("时间: " .. os.date("%Y-%m-%d %H:%M:%S"))

	-- 后台执行 npm install
	local cmd = string.format(
		"setsid sh -c " ..
		"'env HOME=/root npm install -g openclaw " ..
		"--prefix %s " ..
		"--registry https://registry.npmmirror.com " ..
		"--ignore-scripts >> %s 2>&1' &",
		work_dir, LOG_FILE)
	log("执行: " .. cmd)
	sh(cmd)
	log("npm install 已后台启动")
	if lf then lf:close() end

	http.prepare_content("application/json")
	http.write_json({
		status = "ok",
		message = "OpenClaw 安装已启动（后台执行，预计5-10分钟）",
		log_file = LOG_FILE,
		work_dir = work_dir
	})
end

function action_install_openclaw_status()
	local http = require "luci.http"
	local LOG_FILE = "/tmp/openclaw_install.log"

	-- 检查 npm 进程
	local npm_pid = trim(sh("pgrep -f 'npm install' 2>/dev/null || echo ''"))

	-- 检查 package.json（安装完成的标志）
	local pkg_found = trim(sh("test -f /root/.openclaw/package.json && echo yes || echo no"))

	local status, progress, message
	if pkg_found == "yes" then
		status = "done"
		progress = 100
		message = "安装完成！"
	elseif npm_pid ~= "" then
		status = "running"
		progress = 50
		message = "npm install 运行中 (PID: " .. npm_pid .. ")"
	else
		status = "running"
		progress = 10
		message = "等待 npm install 启动..."
	end

	-- 读取日志最后几行
	local last_log = ""
	local lf = io.open(LOG_FILE, "r")
	if lf then
		local lines = {}
		for line in lf:lines() do table.insert(lines, line) end
		lf:close()
		local start = math.max(1, #lines - 8)
		for i = start, #lines do
			last_log = last_log .. lines[i] .. "\n"
		end
	end

	http.prepare_content("application/json")
	http.write_json({
		status = status,
		progress = progress,
		message = message,
		last_log = last_log,
		pkg_found = pkg_found,
		npm_pid = npm_pid
	})
end
