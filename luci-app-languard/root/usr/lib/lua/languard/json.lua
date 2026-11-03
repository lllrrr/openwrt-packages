-- languard/json.lua — 状态文件的唯一读写入口
--
-- 所有 /etc/languard/*.json 都经由这里落盘:
--   * 原子写(临时文件 + rename),读不到半截文档
--   * 目录锁,读改写串行,不会后写覆盖先写
--
-- 模块自己不持有路径:主程序调用 setup(STATE_DIR) 注入。

local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"
local sys = require "luci.sys"

local M = {}
local state_dir = "/etc/languard"

function M.setup(dir)
	state_dir = dir or state_dir
end

-- shell 单引号转义
function M.shq(v)
	return "'" .. tostring(v or ""):gsub("'", "'\\''") .. "'"
end

function M.load(file, shape)
	local f = io.open(file, "r")
	if not f then return shape() end
	local raw = f:read("*a")
	f:close()
	local p = jsonc.parse(raw)
	if type(p) ~= "table" then return shape() end
	return p
end

function M.save(file, v)
	fs.mkdirr(state_dir)
	local o = jsonc.stringify(v)
	if o == "[]" then o = "{}" end
	-- 写在旁边再改名:读取方要么看到旧版本,要么看到新版本,不存在半截
	local tmp = file .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return false end
	f:write(o)
	f:close()
	os.rename(tmp, file)
	return true
end

-- 锁目录:创建成功即持有。持有者崩溃后最多 10 秒自动失效。
function M.lock(file, timeout)
	local lock = file .. ".lock"
	local deadline = os.time() + (timeout or 5)
	while true do
		if fs.mkdir(lock) then return true end
		local st = fs.stat(lock, "mtime")
		if st and (os.time() - st) > 10 then fs.rmdir(lock) end
		if os.time() >= deadline then return false end
		sys.call("sleep 0.05")
	end
end

function M.unlock(file)
	fs.rmdir(file .. ".lock")
end

return M
