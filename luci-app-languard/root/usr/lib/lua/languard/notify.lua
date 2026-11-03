-- languard/notify.lua — 通知通道与事件分发
--
-- 一个坏掉的通道绝不能影响封禁本身,所以发送失败只记发送数,不抛错。

local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"
local sys = require "luci.sys"

local M = {}

local D = {}          -- { notify_file, notify_tmp, state_dir, events, shq }

function M.setup(deps)
	D = deps
end

local function default()
	return { seq = 0, channels = {},
	         events = { auto_block = true, new_device = true, expire = false } }
end

function M.load()
	local f = io.open(D.notify_file, "r")
	if not f then return default() end
	local raw = f:read("*a")
	f:close()
	local p = jsonc.parse(raw)
	if type(p) ~= "table" then return default() end
	p.seq = tonumber(p.seq) or 0
	if type(p.channels) ~= "table" then p.channels = {} end
	if type(p.events) ~= "table" then p.events = {} end
	return p
end

function M.save(n)
	fs.mkdirr(D.state_dir)
	local f = io.open(D.notify_file, "w")
	if not f then return false end
	local o = jsonc.stringify(n)
	if o == "[]" then o = "{}" end
	f:write(o)
	f:close()
	return true
end

local function http_post(url, body)
	local f = io.open(D.notify_tmp, "w")
	if not f then return false end
	f:write(body)
	f:close()
	local rc = sys.call(string.format(
		"curl -s -m 10 -o /dev/null -X POST -H 'Content-Type: application/json' --data-binary @%s %s",
		D.notify_tmp, D.shq(url)))
	fs.unlink(D.notify_tmp)
	return rc == 0
end

function M.send(ch, event, title, body)
	if ch.enabled == false then return false end
	if ch.type == "telegram" then
		local url = "https://api.telegram.org/bot" .. tostring(ch.token or "") .. "/sendMessage"
		return http_post(url, jsonc.stringify({
			chat_id = ch.chat or "", text = title .. "\n" .. body,
			disable_web_page_preview = true }))
	elseif ch.type == "bark" then
		return http_post(tostring(ch.url or ""), jsonc.stringify({
			title = title, body = body, group = "OpenWrt" }))
	elseif ch.type == "webhook" then
		return http_post(tostring(ch.url or ""), jsonc.stringify({
			event = event, title = title, body = body, ts = os.time() }))
	end
	return false
end

-- 发给每个启用的通道;永不抛错
function M.event(event, title, body)
	local n = M.load()
	if n.events[event] == false then return 0 end
	local sent = 0
	for _, ch in ipairs(n.channels) do
		if M.send(ch, event, title, body) then sent = sent + 1 end
	end
	return sent
end

function M.get()
	local n = M.load()
	local out = {}
	for _, c in ipairs(n.channels) do
		out[#out + 1] = {
			id = c.id, type = c.type, name = c.name, enabled = c.enabled ~= false,
			url = c.url, token = c.token and "***" or "", chat = c.chat,
			has_token = (c.token ~= nil and c.token ~= ""),
		}
	end
	return { success = true, running = true, channels = out,
	         events = n.events, event_names = D.events }
end

local function ok(t)
	t = t or {}
	t.success = true
	t.running = true
	return t
end

local function err(m) return { success = false, error = m } end

function M.add(type_, name, url, token, chat)
	type_ = tostring(type_ or "")
	if type_ ~= "telegram" and type_ ~= "bark" and type_ ~= "webhook" then
		return err("type must be telegram, bark or webhook")
	end
	if type_ == "telegram" and (tostring(token or "") == "" or tostring(chat or "") == "") then
		return err("telegram needs a bot token and chat id")
	end
	if type_ ~= "telegram" and tostring(url or "") == "" then
		return err("a URL is required")
	end
	local n = M.load()
	n.seq = (tonumber(n.seq) or 0) + 1
	n.channels[#n.channels + 1] = {
		id = n.seq, type = type_, name = (name ~= "" and name) or type_,
		url = (url ~= "" and url) or nil, token = (token ~= "" and token) or nil,
		chat = (chat ~= "" and chat) or nil, enabled = true,
	}
	if not M.save(n) then return err("cannot write settings") end
	return ok({ id = n.seq })
end

function M.del(id)
	local n = M.load()
	for i, c in ipairs(n.channels) do
		if tostring(c.id) == tostring(id) then
			table.remove(n.channels, i)
			M.save(n)
			return ok({})
		end
	end
	return err("no such channel")
end

function M.toggle(id, enabled)
	local n = M.load()
	for _, c in ipairs(n.channels) do
		if tostring(c.id) == tostring(id) then
			c.enabled = (enabled == true or enabled == "1" or enabled == 1 or enabled == "true")
			M.save(n)
			return ok({})
		end
	end
	return err("no such channel")
end

function M.setevents(events)
	local n = M.load()
	if type(events) == "string" then
		local t = {}
		for v in events:gmatch("[%w_]+") do t[#t + 1] = v end
		events = t
	end
	if type(events) == "table" then
		local set = {}
		for _, e in ipairs(events) do set[e] = true end
		for _, e in ipairs(D.events) do n.events[e] = set[e] or false end
		M.save(n)
	end
	return ok({ events = n.events })
end

function M.test(id)
	local n = M.load()
	for _, c in ipairs(n.channels) do
		if tostring(c.id) == tostring(id) then
			local sent = M.send(c, "test", "OpenWrt test",
				"This is a test message from luci-app-languard.")
			local res = { success = sent, running = true }
			if not sent then res.error = "send failed (check URL/token)" end
			return res
		end
	end
	return err("no such channel")
end

return M
