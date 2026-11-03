-- languard/feeds.lua — 订阅源
--
-- 一个源可能给三种东西:IP 列表、域名列表、geosite 分类。三者的更新都是
-- "整源替换"而不是增量追加,否则源里删掉的条目会永远留在名单里。

local fs = require "nixio.fs"
local sys = require "luci.sys"

local M = {}
local D = {}

function M.setup(deps)
	D = deps
end

local function ok(t)
	t = t or {}
	t.success = true
	t.running = true
	return t
end

local function err(m) return { success = false, error = m } end

local function feed_skip(ip)
	local a, b = ip:match("^(%d+)%.(%d+)%.")
	if a then
		a, b = tonumber(a), tonumber(b)
		if a == 0 or a == 10 or a == 127 then return true end
		if a == 172 and b >= 16 and b <= 31 then return true end
		if a == 192 and b == 168 then return true end
		if a == 169 and b == 254 then return true end
		if a == 100 and b >= 64 and b <= 127 then return true end
		if a >= 224 then return true end          -- multicast / reserved
		return false
	end
	if ip == "::1" or ip:match("^fe80") or ip:match("^f[cd]") or ip:match("^ff") then
		return true
	end
	return false
end

local function parse_domain_list(raw)
	local out, seen = {}, {}
	for line in raw:gmatch("[^\r\n]+") do
		line = line:gsub("#.*$", ""):gsub("%s+$", "")
		if line ~= "" and not line:find("^include:") and not line:find("^regexp:") then
			line = line:gsub("^full:", ""):gsub("%s*@!?[%w-]+$", "")
			if D.is_domain_token(line) and not seen[line] then
				seen[line] = true
				out[#out + 1] = line
			end
		end
	end
	return out
end

local function merge_app_feed(fd, domains)
	if #domains == 0 then return nil, "no domains in list" end
	local d = D.load_apps()
	local sigs = {}
	for _, dom in ipairs(domains) do
		sigs[#sigs + 1] = { proto = "tcp", dport = "", host = dom, dict = "" }
	end
	for _, a in ipairs(d.apps) do
		if a.name == fd.name then
			a.sigs = sigs
			a.class = fd.cls or a.class
			D.save_apps(d)
			return #sigs
		end
	end
	d.seq = d.seq + 1
	d.apps[#d.apps + 1] = { id = d.seq, name = fd.name, class = fd.cls or "other",
	                        sigs = sigs, feed = tostring(fd.id) }
	D.save_apps(d)
	return #sigs
end

local function geosite_categories(data)
	local out = {}
	local i = 1
	while i <= #data do
		local tag, wire, val, nxt = D.pb_field(data, i)
		if not tag then break end
		i = nxt
		if tag == 1 and wire == 2 then
			local code, domains = nil, {}
			local j = 1
			while j <= #val do
				local t2, w2, v2, n2 = D.pb_field(val, j)
				if not t2 then break end
				j = n2
				if t2 == 1 and w2 == 2 then
					code = v2
				elseif t2 == 2 and w2 == 2 then
					local dtype, dval = 0, nil
					local k = 1
					while k <= #v2 do
						local t3, w3, v3, n3 = D.pb_field(v2, k)
						if not t3 then break end
						k = n3
						if t3 == 1 and w3 == 0 then dtype = v3
						elseif t3 == 2 and w3 == 2 then dval = v3 end
					end
					-- regex entries cannot be expressed as a hostname match
					if dval and dtype ~= 1 then domains[#domains + 1] = dval end
				end
			end
			if code and #domains > 0 then out[code] = domains end
		end
	end
	return out
end

local function merge_geosite(fd, cats)
	local d = D.load_apps()
	local by_name = {}
	for _, a in ipairs(d.apps) do by_name[a.name] = a end
	local made, updated, skipped = 0, 0, 0
	for code, domains in pairs(cats) do
		-- the file spells these in upper case, so match on the lower form and
		-- skip whole families rather than a fixed list
		local lc = code:lower()
		local routing = lc:match("^geolocation") ~= nil
			or lc:match("^category") ~= nil
			or lc:match("^tld") ~= nil
			or lc == "cn" or lc == "direct" or lc == "proxy" or lc == "private"
			or lc == "gfw" or lc == "greatfire"
		if routing then
			skipped = skipped + 1
		else
			local sigs = {}
			for _, dom in ipairs(domains) do
				sigs[#sigs + 1] = { proto = "tcp", dport = "", host = dom, dict = "" }
			end
			-- an all-uppercase name or a very large set is a vendor umbrella,
			-- not an app: it still matches, but is labelled as coarse
			local generic = (code == code:upper() and #domains > 50) or #domains > 300
			local ex = by_name[code]
			if ex then
				ex.sigs = sigs
				ex.feed = tostring(fd.id)
				ex.generic = generic
				updated = updated + 1
			else
				d.seq = d.seq + 1
				d.apps[#d.apps + 1] = { id = d.seq, name = code, class = fd.cls or "other",
				                        sigs = sigs, feed = tostring(fd.id), generic = generic }
				made = made + 1
			end
		end
	end
	D.save_apps(d)
	return made, updated, skipped
end

local function load_feeds()
	local f = load_json_map(D.FEEDS_FILE, function() return { seq = 0, feeds = {} } end)
	f.seq = tonumber(f.seq) or 0
	if type(f.feeds) ~= "table" then f.feeds = {} end
	-- subscriptions created before scheduling existed default to daily, the
	-- whole point of keeping a list is that it stays current
	for _, fd in ipairs(f.feeds) do
		if fd.interval == nil then fd.interval = 86400 end
	end
	return f
end

local function fetch_feed(fd, ips, now)
	local tmp = "/tmp/languard-feed.txt"
	-- the exit code matters: a timeout still leaves a partial file behind,
	-- and treating that as the whole list would delete everything after it
	local rc = sys.call(string.format("curl -fsSL -m 60 -o %s %s", tmp, D.shq(fd.url)))
	local raw = D.read_all(tmp)
	fs.unlink(tmp)
	if rc ~= 0 then return nil, "download failed (curl " .. tostring(rc) .. ")" end
	if not raw or raw == "" then return nil, "download failed" end

	-- Feeds in the wild are not uniform: netsets put one CIDR per line,
	-- Spamhaus appends "; SBL123", some providers emit CSV, others ship a
	-- hosts file. Take every token that parses as an address and ignore the
	-- rest, so one list does not need a bespoke parser.
	-- Most public lists are ordered worst-first, so a cap keeps the top of the
	-- list. It also bounds the state file: every ubus call parses it, and
	-- 150k entries made a single tick cost five seconds.
	local wanted, dn, n, truncated = {}, {}, 0, false
	for line in raw:gmatch("[^\n]+") do
		line = line:gsub("#.*$", ""):gsub("//.*$", "")
		for tok in line:gmatch("[^%s,;\t]+") do
			local norm = D.normalize_ip(tok)
			if norm and not feed_skip(norm) and not D.is_trusted_proxy(norm)
			   and not wanted[norm] then
				if n >= D.MAX_FEED_IPS then
					truncated = true
					break
				end
				wanted[norm] = true
				n = n + 1
			elseif not norm and D.is_domain_token(tok) then
				dn[tok:lower()] = true
			end
		end
		if truncated then break end
	end
	if n == 0 and next(dn) == nil then return nil, "nothing usable in feed" end

	local prev = 0
	for _, meta in pairs(ips) do
		if tostring(meta.feed or "") == tostring(fd.id) then prev = prev + 1 end
	end
	if prev > 100 and n < prev / 2 then
		return nil, string.format("feed shrank from %d to %d, keeping the old list", prev, n)
	end

	local added, removed = {}, {}
	for ip, meta in pairs(ips) do
		if tostring(meta.feed or "") == tostring(fd.id) and not wanted[ip] then
			ips[ip] = nil
			removed[#removed + 1] = ip
		end
	end
	for ip in pairs(wanted) do
		if ips[ip] == nil then
			ips[ip] = { since = now, note = "feed: " .. fd.name,
			            source = "feed", feed = tostring(fd.id) }
			added[#added + 1] = ip
		end
	end

	fd.last = now
	fd.last_count = #added
	fd.last_total = n
	fd.last_truncated = truncated
	fd.last_error = nil
	return { added = added, removed = removed, total = n, truncated = truncated,
	         domains = dn }
end

local function merge_feed_domains(fd, wanted, now)
	local d = D.load_domains()
	local id = tostring(fd.id)
	local changed = 0
	for name, meta in pairs(d.names) do
		if tostring(meta.feed or "") == id and not wanted[name] then
			d.names[name] = nil
			changed = changed + 1
		end
	end
	for name in pairs(wanted or {}) do
		if d.names[name] == nil and #d.names < D.MAX_DOMAINS then
			d.names[name] = { since = now, source = "feed", feed = id,
			                  note = "feed: " .. fd.name }
			changed = changed + 1
		end
	end
	if changed > 0 then D.save_domains(d) end
	return changed
end

local function refresh_due_feeds(now)
	local f = load_feeds()
	local due
	for _, fd in ipairs(f.feeds) do
		local iv = tonumber(fd.interval) or 0
		if fd.enabled ~= false and iv > 0 and
		   (now - (tonumber(fd.last) or 0)) >= iv then
			due = fd
			break
		end
	end
	if not due then return nil end

	-- an app feed replaces a signature set, so reuse the manual path
	if (due.kind or "ip") == "app" or (due.kind or "ip") == "geosite" then
		local r = D.methods.feedrefresh(due.id)
		return { id = due.id, name = due.name, app = true, ok = r and r.success or false }
	end

	local lk = D.lock_acquire(D.IPSTATE_FILE, 10)
	local ips = D.load_ipstate()
	local delta, why = fetch_feed(due, ips, now)
	if not delta then
		due.last_error = why
		-- do not hammer a broken source on every tick
		due.last = now
		save_json_map(D.FEEDS_FILE, f)
		if lk then D.lock_release(D.IPSTATE_FILE) end
		D.notify_event("feed_fail", "Feed failed: " .. due.name, tostring(why))
		return { id = due.id, name = due.name, error = why }
	end

	local dch = merge_feed_domains(due, delta.domains, now)
	save_json_map(D.FEEDS_FILE, f)
	D.save_ipstate(ips)
	if lk then D.lock_release(D.IPSTATE_FILE) end
	D.render_rules(D.load_state())
	D.apply_ip_delta(delta)
	if dch > 0 then D.apply_domains() end
	return { id = due.id, name = due.name, added = #delta.added,
	         removed = #delta.removed, domains = dch, truncated = delta.truncated }
end

function M.feedlist()
	local f = load_feeds()
	local ips = D.load_ipstate()
	local counts = {}
	for _, meta in pairs(ips) do
		local id = tostring(meta.feed or "")
		if id ~= "" then counts[id] = (counts[id] or 0) + 1 end
	end
	local out = {}
	for _, fd in ipairs(f.feeds) do
		out[#out + 1] = { id = fd.id, name = fd.name, url = fd.url,
		                  enabled = fd.enabled ~= false, imported = counts[tostring(fd.id)] or 0,
		                  last = fd.last, last_count = fd.last_count,
		                  interval = tonumber(fd.interval) or 0,
		                  kind = fd.kind or "ip", cls = fd.cls,
		                  last_error = fd.last_error,
		                  total = fd.last_total, truncated = fd.last_truncated }
	end
	return { success = true, running = true, feeds = out }
end

function M.feedadd(name, url, interval, kind, cls)
	if tostring(url or "") == "" then return err("url required") end
	local f = load_feeds()
	f.seq = (tonumber(f.seq) or 0) + 1
	local iv = tonumber(interval)
	if iv == nil then iv = 86400 end
	kind = tostring(kind or "ip")
	if kind ~= "ip" and kind ~= "domain" and kind ~= "app" and kind ~= "geosite" then kind = "ip" end
	f.feeds[#f.feeds + 1] = { id = f.seq, name = (name ~= "" and name) or tostring(url),
	                          url = url, enabled = true, interval = iv,
	                          kind = kind, cls = (cls ~= "" and cls) or nil }
	save_json_map(D.FEEDS_FILE, f)
	return ok({ id = f.seq })
end

function M.feeddel(id)
	local f = load_feeds()
	local keep, removed = {}, false
	local gone
	for _, fd in ipairs(f.feeds) do
		if tostring(fd.id) == tostring(id) then removed = true; gone = fd
		else keep[#keep + 1] = fd end
	end
	if not removed then return err("no such feed") end
	f.feeds = keep
	-- an uploaded feed owns its file; removing the feed must not leave it behind
	if gone and gone.url then
		local path = gone.url:match("^file://(.+)$")
		if path and path:find("/uploads/", 1, true) and not path:find("..", 1, true) then
			fs.unlink(path)
		end
	end
	save_json_map(D.FEEDS_FILE, f)
	-- drop everything this feed contributed, addresses and domains alike
	local ips = D.load_ipstate()
	for ip, meta in pairs(ips) do
		if tostring(meta.feed or "") == tostring(id) then ips[ip] = nil end
	end
	D.save_ipstate(ips)

	local doms = D.load_domains()
	local dchanged = 0
	for name, meta in pairs(doms.names) do
		if tostring(meta.feed or "") == tostring(id) then
			doms.names[name] = nil
			dchanged = dchanged + 1
		end
	end
	if dchanged > 0 then
		D.save_domains(doms)
		D.apply_domains()
	end
	D.render_rules(D.load_state())
	D.reload_firewall()
	return ok({})
end

function M.feedrefresh(id)
	local f = load_feeds()
	local fd
	for _, x in ipairs(f.feeds) do
		if tostring(x.id) == tostring(id) then fd = x end
	end
	if not fd then return err("no such feed") end

	if (fd.kind or "ip") == "geosite" then
		local tmp = "/tmp/languard-feed.dat"
		local rc = sys.call(string.format("curl -fsSL -m 120 -o %s %s", tmp, D.shq(fd.url)))
		local raw = D.read_all(tmp)
		fs.unlink(tmp)
		if rc ~= 0 or not raw or #raw < 32 then return err("download failed") end
		local cats = geosite_categories(raw)
		local n = 0
		for _ in pairs(cats) do n = n + 1 end
		if n == 0 then return err("no categories in file") end
		local made, updated, skipped = merge_geosite(fd, cats)
		fd.last, fd.last_count, fd.last_error = os.time(), made + updated, nil
		save_json_map(D.FEEDS_FILE, f)
		return ok({ added = made, merged = updated, skipped = skipped, total = made + updated })
	end

	if (fd.kind or "ip") == "app" then
		local tmp = "/tmp/languard-feed.txt"
		local rc = sys.call(string.format("curl -fsSL -m 60 -o %s %s", tmp, D.shq(fd.url)))
		local raw = D.read_all(tmp)
		fs.unlink(tmp)
		if rc ~= 0 or not raw then return err("download failed") end
		local n, why = merge_app_feed(fd, parse_domain_list(raw))
		if not n then return err(why) end
		fd.last, fd.last_count, fd.last_error = os.time(), n, nil
		save_json_map(D.FEEDS_FILE, f)
		return ok({ added = n, merged = n, total = n })
	end

	local lk = D.lock_acquire(D.IPSTATE_FILE, 10)
	local ips = D.load_ipstate()
	local delta, why = fetch_feed(fd, ips, os.time())
	if not delta then
		fd.last_error = why
		save_json_map(D.FEEDS_FILE, f)
		if lk then D.lock_release(D.IPSTATE_FILE) end
		return err(why)
	end

	local dch = merge_feed_domains(fd, delta.domains, os.time())
	save_json_map(D.FEEDS_FILE, f)
	D.save_ipstate(ips)
	if lk then D.lock_release(D.IPSTATE_FILE) end
	D.render_rules(D.load_state())
	D.apply_ip_delta(delta)
	if dch > 0 then D.apply_domains() end
	return { success = true, running = true, added = #delta.added,
	         removed = #delta.removed, total = delta.total, domains = dch,
	         truncated = delta.truncated, cap = D.MAX_FEED_IPS }
end

function M.feedset(id, interval)
	local f = load_feeds()
	local fd
	for _, x in ipairs(f.feeds) do
		if tostring(x.id) == tostring(id) then fd = x end
	end
	if not fd then return err("no such feed") end
	local iv = tonumber(interval)
	if not iv or iv < 0 then return err("invalid interval") end
	fd.interval = iv
	save_json_map(D.FEEDS_FILE, f)
	return ok({ id = fd.id, interval = iv })
end

M.feed_skip = feed_skip
M.parse_domain_list = parse_domain_list
M.merge_app_feed = merge_app_feed
M.geosite_categories = geosite_categories
M.merge_geosite = merge_geosite
M.load_feeds = load_feeds
M.fetch_feed = fetch_feed
M.merge_feed_domains = merge_feed_domains
M.refresh_due_feeds = refresh_due_feeds

return M
