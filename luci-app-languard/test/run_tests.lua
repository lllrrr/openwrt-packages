#!/usr/bin/env lua
-- languard 回归测试。在路由器上运行:
--   lua /usr/lib/lua/languard/test.lua        (若随包安装)
--   lua test/run_tests.lua                    (仓库根,需 LUAI_PATH 含 /usr/lib/lua)
-- 覆盖审计发现的两个具体回归:
--   1. qosadd 的 ip 必须经 normalize_ip 校验(否则注入 nft 语法)
--   2. save_json_map 必须原子写(临时文件 + rename,不留半截)
--   3. normalize_ip 拒绝非法/注入输入

local jsonc = require "luci.jsonc"
local netm = require "languard.net"
local jsonm = require "languard.json"
local appsm = require "languard.apps"

local pass, fail = 0, 0
local function check(name, cond)
	if cond then
		pass = pass + 1
		print("PASS " .. name)
	else
		fail = fail + 1
		print("FAIL " .. name)
	end
end

-- ---------- normalize_ip ----------
check("normalize_ip 合法 IPv4", netm.normalize_ip("1.2.3.4") == "1.2.3.4")
check("normalize_ip 合法 CIDR", netm.normalize_ip("1.2.3.0/24") == "1.2.3.0/24")
check("normalize_ip 拒绝空格注入", netm.normalize_ip("1.2.3.4 foo") == nil)
check("normalize_ip 拒绝分号注入", netm.normalize_ip("1.2.3.4; drop") == nil)
check("normalize_ip 拒绝非地址", netm.normalize_ip("not an ip") == nil)
check("normalize_ip 拒绝越界八位组", netm.normalize_ip("1.2.3.999") == nil)

-- ---------- save_json_map 原子写 ----------
local tmpdir = "/tmp/languard-test"
local os = require "os"
os.execute("rm -rf " .. tmpdir .. " 2>/dev/null")
os.execute("mkdir -p " .. tmpdir .. " 2>/dev/null")
jsonm.setup(tmpdir)
local f = tmpdir .. "/state.json"
local ok_save = jsonm.save(f, { a = 1, b = { 2, 3 } })
check("save_json_map 写入成功", ok_save == true)
local raw = jsonm.load(f, function() return {} end)
check("save_json_map 内容可读回", type(raw) == "table" and raw.a == 1)
-- 原子写:不应残留 .tmp 文件
local leftover = os.execute("ls " .. f .. ".tmp >/dev/null 2>&1") == 0
check("save_json_map 不留 .tmp", leftover == false)

-- ---------- qosadd 校验 ip ----------
-- 用 mock 依赖驱动 apps.lua;normalize_ip 用真实的 netm.normalize_ip
local deps = {
	APPSTAT_FILE = "/tmp/languard-test/appstats.json",
	CT_SEEN_FILE = "/tmp/languard-test/ct.json",
	QOS_FILE = "/tmp/languard-test/qos.json",
	QOS_LEVELS = { cs1 = "1:15", ef = "1:11" },
	SAMPLE_PCAP = "/tmp/languard-test/sample.pcap",
	SAMPLE_STATE = "/tmp/languard-test/sample.json",
	load_apps = function() return { seq = 0, apps = {} } end,
	save_apps = function() return true end,
	load_appips = function() return {} end,
	load_qos = function() return { seq = 0, rules = {} } end,
	save_qos = function() return true end,
	render_qos_rules = function() return true end,
	apply_qos = function() return true end,
	collect_devices = function() return {} end,
	load_json_map = function(a, b) return jsonm.load(a, b) end,
	save_json_map = function(a, b) return jsonm.save(a, b) end,
	load_state = function() return {} end,
	save_state = function() return true end,
	normalize_ip = function(v) return netm.normalize_ip(v) end,
	notify_event = function() return 0 end,
	read_all = function(p)
		local fh = io.open(p, "r")
		if not fh then return nil end
		local d = fh:read("*a") fh:close() return d
	end,
	trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
	sig_usable = function() return true end,
	ok = function(t) t = t or {}; t.success = true; t.running = true; return t end,
	err = function(m) return { success = false, running = true, error = m } end,
	sample_running = function() return false end,
	parse_pcap = function() return {} end,
}
appsm.setup(deps)

local r_bad = appsm.qosadd("1.2.3.4 foo", "someapp", "cs1")
check("qosadd 拒绝坏 ip(注入)", r_bad and r_bad.success == false)
local r_bad2 = appsm.qosadd("1.2.3.4; drop", "someapp", "cs1")
check("qosadd 拒绝坏 ip(分号)", r_bad2 and r_bad2.success == false)
local r_ok = appsm.qosadd("1.2.3.4", "someapp", "cs1")
check("qosadd 接受合法 ip", r_ok and r_ok.success == true)
local r_noip = appsm.qosadd("", "someapp", "cs1")
check("qosadd 空 ip + 有 app 可用", r_noip and r_noip.success == true)

os.execute("rm -rf " .. tmpdir .. " 2>/dev/null")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
os.exit(0)
