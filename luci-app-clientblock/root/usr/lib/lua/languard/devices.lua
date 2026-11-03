-- languard/devices.lua — 设备的全部状态文件
--
-- 所有权规则:每个文件只有一个所有者函数族在这里,别处只调用不直接读写。
-- 这样"谁改了 pending.json"这类问题永远只有一个答案。
--
--   blocked.json        封禁中的设备
--   names.json          用户改过的设备名
--   known_devices.json  已确认的设备(首次见到的时间)
--   whitelist.json      信任名单
--   groups.json         设备分组
--   ports.json          每设备的端口限制
--   schedule.json       时间表
--   aliases.json        虚拟接口折叠到物理设备
--   panic.json          一键隔离开关

local jsonm = require "languard.json"

local M = {}

local F = {}          -- 文件名,由 setup 注入
local cache = {}      -- 每模块只缓存自己的文件

function M.setup(files)
	F = files
end

-- 缓存失效:只有本模块修改自己的文件时才需要调用
function M.invalidate(name)
	cache[name] = nil
end

-- ---------- blocked.json ----------
function M.load_state()
	return jsonm.load(F.state, function() return {} end)
end

function M.save_state(state)
	return jsonm.save(F.state, state)
end

function M.update_state(fn)
	local ok_ = jsonm.lock(F.state)
	local d = M.load_state()
	fn(d)
	local r = M.save_state(d)
	if ok_ then jsonm.unlock(F.state) end
	return r
end

-- ---------- names.json ----------
function M.load_names()
	return jsonm.load(F.names, function() return {} end)
end

function M.save_names(names)
	return jsonm.save(F.names, names)
end

function M.remember_name(mac, name)
	if not name or name == "" then return end
	local names = M.load_names()
	names[mac] = name
	M.save_names(names)
end

-- ---------- whitelist.json ----------
function M.load_wl()
	local w = jsonm.load(F.whitelist, function() return { macs = {} } end)
	if type(w.macs) ~= "table" then w.macs = {} end
	return w
end

function M.wl_has(mac)
	if not cache.wl then
		cache.wl = {}
		for _, m in ipairs(M.load_wl().macs) do cache.wl[m] = true end
	end
	return cache.wl[mac] == true
end

-- ---------- groups / ports / schedule / aliases / panic ----------
function M.load_groups()
	local g = jsonm.load(F.groups, function() return { seq = 0, groups = {} } end)
	g.seq = tonumber(g.seq) or 0
	if type(g.groups) ~= "table" then g.groups = {} end
	for _, grp in ipairs(g.groups) do
		if type(grp.macs) ~= "table" then grp.macs = {} end
	end
	return g
end

function M.load_ports()
	local p = jsonm.load(F.ports, function() return { seq = 0, rules = {} } end)
	p.seq = tonumber(p.seq) or 0
	if type(p.rules) ~= "table" then p.rules = {} end
	return p
end

function M.load_sched()
	local p = jsonm.load(F.schedule, function() return { seq = 0, rules = {} } end)
	p.seq = tonumber(p.seq) or 0
	if type(p.rules) ~= "table" then p.rules = {} end
	return p
end

function M.load_aliases()
	return jsonm.load(F.aliases, function() return {} end)
end

function M.load_panic()
	return jsonm.load(F.panic, function() return { on = false } end)
end

return M
