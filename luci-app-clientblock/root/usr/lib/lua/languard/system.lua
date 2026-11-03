-- languard/system.lua — 备份与恢复
--
-- 这是唯一知道"哪些文件值得带走"的地方。清单由调用方注入,
-- 模块自己不认识任何具体状态文件。

local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"
local sys = require "luci.sys"

local M = {}

local cfg = {}          -- { files = {...}, state_dir, notify_file, deps = {...} }

function M.setup(opts)
	cfg = opts
end

local function err(msg) return { success = false, error = msg } end
local function ok(t)
	t = t or {}
	t.success = true
	t.running = true
	return t
end

function M.exportconfig()
	local d = cfg.deps
	local out = { success = true, running = true, version = 1, data = {} }
	for key, path in pairs(cfg.files) do
		local raw = d.read_all(path)
		if raw then
			local p = jsonc.parse(raw)
			if type(p) == "table" then out.data[key] = p end
		end
	end
	return out
end

-- ubus 消息装不下 2MB 的应用库,所以写到 /www 让浏览器下载。
-- /www 是 uhttpd 的静态根,不经过 LuCI 认证,所以:
--   * 文件名随机,猜不到
--   * 令牌一律打码,导入时 *** 表示保留原值
--   * 每次导出先删掉上一份
function M.exportfile()
	local payload = M.exportconfig()
	local ntf = payload.data.notify
	if type(ntf) == "table" and type(ntf.channels) == "table" then
		for _, c in ipairs(ntf.channels) do
			if type(c) == "table" and c.token and c.token ~= "" then c.token = "***" end
		end
	end
	local body = jsonc.stringify(payload)

	local okd, dir = pcall(fs.dir, "/www")
	if okd then
		local f = dir()
		while f do
			if f:match("^languard%-backup.*%.json$") then fs.unlink("/www/" .. f) end
			f = dir()
		end
	end

	math.randomseed(os.time())
	local name = string.format("languard-backup-%06x%04x.json",
		math.random(0, 0xffffff), math.random(0, 0xffff))
	local f = io.open("/www/" .. name, "w")
	if not f then return err("cannot write /www") end
	f:write(body) f:close()
	-- uhttpd 以受限身份读静态文件,0600 会 403;nixio 的 mode 按八进制解释,
	-- 传十进制 420 会得到 0420,所以交给 chmod 命令
	pcall(function() sys.call("chmod 644 /www/" .. name) end)

	local n = 0
	for _ in pairs(payload.data) do n = n + 1 end
	return ok({ url = "/" .. name, size = #body, sections = n })
end

function M.importconfig(payload)
	local d = cfg.deps
	local p = payload
	if type(p) == "string" then
		local ok_, parsed = pcall(jsonc.parse, p)
		if not ok_ or type(parsed) ~= "table" then return err("invalid JSON") end
		p = parsed
	end
	if type(p) ~= "table" or type(p.data) ~= "table" then return err("missing data") end

	-- 导出的令牌是打码的,恢复时用现有的顶替
	local cur = p.data.notify
	if type(cur) == "table" and type(cur.channels) == "table" then
		local live = d.load_json_map(cfg.notify_file, function() return { channels = {} } end)
		local byid = {}
		for _, c in ipairs(live.channels or {}) do byid[tostring(c.id)] = c end
		for _, c in ipairs(cur.channels) do
			if type(c) == "table" and c.token == "***" then
				local o = byid[tostring(c.id)]
				c.token = (o and o.token) or nil
			end
		end
	end

	local n = 0
	for key, path in pairs(cfg.files) do
		local v = p.data[key]
		if type(v) == "table" then
			local o = jsonc.stringify(v)
			if o == "[]" then o = "{}" end
			local f = io.open(path, "w")
			if f then f:write(o) f:close() n = n + 1 end
		end
	end
	d.render_rules(d.load_state())
	d.reload_firewall()
	return ok({ imported = n })
end

-- 恢复走上传路径:/cgi-bin/lg-upload 落在 uploads 下,这里读取并导入
function M.importfile(name)
	name = tostring(name or "languard-backup.json")
	if not name:match("^[%w%._-]+%.json$") then return err("bad file name") end
	local path = cfg.state_dir .. "/uploads/" .. name
	local raw = cfg.deps.read_all(path)
	if not raw or raw == "" then return err("upload not found") end
	local r = M.importconfig(raw)
	fs.unlink(path)
	return r
end

return M
