-- languard/apps.lua — 应用识别、流量统计、QoS、抓包采样的对外接口
--
-- 这里只有方法本身;识别索引、conntrack 采集、指纹这些热路径留在主文件,
-- 通过 setup 注入。模块不持有任何状态文件。

local sys = require "luci.sys"

local M = {}
local D = {}

function M.setup(deps)
	D = deps
end

function M.applist()
	local d = D.load_apps()
	local st = D.load_json_map(D.APPSTAT_FILE, function() return { day = "", apps = {} } end)
	local out = {}
	for _, a in ipairs(d.apps) do
		out[#out + 1] = { id = a.id, name = a.name, class = a.class,
		                  generic = a.generic or false,
		                  sigs = #(a.sigs or {}),
		                  bytes = (st.apps or {})[a.name] or 0 }
	end
	table.sort(out, function(x, y) return (x.bytes or 0) > (y.bytes or 0) end)
	return { success = true, running = true, apps = out, day = st.day or "" }
end

function M.appstats(range)
	local st = D.load_json_map(D.APPSTAT_FILE, function() return { day = "", apps = {}, dev = {} } end)
	local buckets = {}
	if range == "week" then
		buckets[#buckets + 1] = st
		for _, h in pairs(st.hist or {}) do buckets[#buckets + 1] = h end
	elseif range == "yesterday" then
		local h = (st.hist or {})[os.date("%Y-%m-%d", os.time() - 86400)]
		if h then buckets[#buckets + 1] = h end
	else
		buckets[#buckets + 1] = st
	end
	local apps, dev, low, prox, nodes, ph = {}, {}, {}, {}, {}, {}
	for _, b in ipairs(buckets) do
		for k, v in pairs(b.proxy or {}) do prox[k] = (prox[k] or 0) + v end
		for k, v in pairs(b.node or {}) do nodes[k] = (nodes[k] or 0) + v end
		for k, v in pairs(b.ph or {}) do
			local e = ph[k]
			if not e then e = { b = 0, n = {}, g = {} }; ph[k] = e end
			e.b = e.b + (v.b or 0)
			if type(v.n) == "table" then
				for n, x in pairs(v.n) do e.n[n] = (e.n[n] or 0) + x end
				for n, x in pairs(v.g or {}) do e.g[n] = (e.g[n] or 0) + x end
			else
				-- entries written before the split existed carry one name
				if v.n then e.n[v.n] = (e.n[v.n] or 0) + (v.b or 0) end
				if v.g then e.g[v.g] = (e.g[v.g] or 0) + (v.b or 0) end
			end
		end
		for k, v in pairs(b.apps or {}) do apps[k] = (apps[k] or 0) + v end
		for k, v in pairs(b.low or {}) do low[k] = (low[k] or 0) + v end
		for ip, m in pairs(b.dev or {}) do
			dev[ip] = dev[ip] or {}
			for k, v in pairs(m) do dev[ip][k] = (dev[ip][k] or 0) + v end
		end
	end
	local names = {}
	for name, bytes in pairs(apps) do
		names[#names + 1] = { name = name, bytes = bytes, low = low[name] or 0 }
	end
	table.sort(names, function(a, b) return a.bytes > b.bytes end)
	-- an address is only useful once it has a device behind it
	local by_ip = {}
	for _, d in ipairs(D.collect_devices()) do
		if d.ip then by_ip[d.ip] = d end
	end

	local devs, per_app = {}, {}
	for ip, m in pairs(dev) do
		local d = by_ip[ip]
		local row = { ip = ip, bytes = 0, apps = {},
		              mac = d and d.mac or nil,
		              name = d and (d.host or d.mac) or nil,
		              vendor = d and d.vendor or nil }
		for name, bytes in pairs(m) do
			row.bytes = row.bytes + bytes
			row.apps[#row.apps + 1] = { name = name, bytes = bytes }
			per_app[name] = per_app[name] or {}
			per_app[name][#per_app[name] + 1] = {
				ip = ip, bytes = bytes,
				name = d and (d.host or d.mac) or nil,
				mac = d and d.mac or nil,
			}
		end
		table.sort(row.apps, function(a, b) return a.bytes > b.bytes end)
		devs[#devs + 1] = row
	end
	table.sort(devs, function(a, b) return a.bytes > b.bytes end)
	for _, list in pairs(per_app) do
		table.sort(list, function(a, b) return a.bytes > b.bytes end)
	end

	local plist, ptotal = {}, 0
	for g, bytes in pairs(prox) do
		plist[#plist + 1] = { group = g, bytes = bytes }
		ptotal = ptotal + bytes
	end
	table.sort(plist, function(a, b) return a.bytes > b.bytes end)

	local nlist = {}
	for k, bytes in pairs(nodes) do nlist[#nlist + 1] = { node = k, bytes = bytes } end
	table.sort(nlist, function(a, b) return a.bytes > b.bytes end)

	local function ranked(m, key)
		local out = {}
		for k, v in pairs(m or {}) do out[#out + 1] = { [key] = k, bytes = v } end
		table.sort(out, function(a, b) return a.bytes > b.bytes end)
		return out
	end
	local hlist = {}
	for host, e in pairs(ph) do
		local nl = ranked(e.n, "node")
		local gl = ranked(e.g, "group")
		hlist[#hlist + 1] = { host = host, bytes = e.b or 0,
		                      nodes = nl, groups = gl,
		                      node = nl[1] and nl[1].node, group = gl[1] and gl[1].group }
	end
	table.sort(hlist, function(a, b) return a.bytes > b.bytes end)
	while #hlist > 1000 do table.remove(hlist) end

	return { success = true, running = true, day = st.day or "", range = range or "today",
	         apps = names, dev = devs, per_app = per_app,
	         proxy = plist, proxy_total = ptotal, nodes = nlist, hosts = hlist }
end

-- 破坏性:清空当日流量统计与流量账本,不可恢复
function M.appreset(confirm)
	if not (confirm == "yes" or confirm == true or confirm == 1 or confirm == "1" or confirm == "true") then
		return D.err("refusing to reset counters without confirmation; pass {\"confirm\":\"yes\"}")
	end
	D.save_json_map(D.APPSTAT_FILE, { day = os.date("%Y-%m-%d"), apps = {}, dev = {} })
	D.save_json_map(D.CT_SEEN_FILE, {})
	return D.ok({})
end

function M.appimport(text)
	if type(text) ~= "string" or #text < 8 then return D.err("empty input") end
	local d = D.load_apps()
	local by_name = {}
	for _, a in ipairs(d.apps) do by_name[a.name] = a end

	local cls, added, merged = nil, 0, 0
	for line in text:gmatch("[^\r\n]+") do
		local c = line:match("^#class%s+(%a+)")
		if c then
			cls = c
		else
			local id, name, body = line:match("^(%d+)%s+([^:]+):%[(.*)%]")
			if id then
				local sigs = {}
				for part in body:gmatch("[^,]+") do
					-- gmatch("[^;]*") yields an extra empty match on every
					-- consecutive separator, which shifts every later field;
					-- anchoring on the separator keeps the columns aligned
					local f = {}
					for v in (part .. ";"):gmatch("([^;]*);") do f[#f + 1] = D.trim(v) end
					while #f < 6 do f[#f + 1] = "" end
					local sig = { proto = f[1], dport = f[3], host = f[4], dict = f[6] }
					if D.sig_usable(sig, cls) then sigs[#sigs + 1] = sig end
				end
				if #sigs > 0 then
					local ex = by_name[name]
					if ex then
						ex.sigs = sigs
						ex.class = cls or ex.class
						merged = merged + 1
					else
						d.seq = d.seq + 1
						local app = { id = d.seq, name = name, class = cls or "other", sigs = sigs }
						d.apps[#d.apps + 1] = app
						by_name[name] = app
						added = added + 1
					end
				end
			end
		end
	end
	if added + merged == 0 then return D.err("nothing recognised") end
	D.save_apps(d)
	return D.ok({ added = added, merged = merged, total = #d.apps })
end

function M.siglist(name)
	local d = D.load_apps()
	for _, a in ipairs(d.apps) do
		if a.name == name then
			local out = {}
			for i, sig in ipairs(a.sigs or {}) do
				out[#out + 1] = { idx = i, proto = sig.proto, dport = sig.dport,
				                  host = sig.host, dict = sig.dict }
			end
			return D.ok({ name = a.name, class = a.class, sigs = out })
		end
	end
	return D.err("no such app")
end

function M.sigadd(name, proto, dport, host)
	local d = D.load_apps()
	for _, a in ipairs(d.apps) do
		if a.name == name then
			local sig = { proto = proto or "", dport = dport or "", host = host or "", dict = "" }
			if not D.sig_usable(sig, a.class) then
				return D.err("that would match everything: give a hostname, or a game port")
			end
			a.sigs[#a.sigs + 1] = sig
			D.save_apps(d)
			return D.ok({ count = #a.sigs })
		end
	end
	return D.err("no such app")
end

function M.sigdel(name, idx)
	local d = D.load_apps()
	for _, a in ipairs(d.apps) do
		if a.name == name then
			idx = tonumber(idx)
			if not idx or not a.sigs[idx] then return D.err("no such signature") end
			table.remove(a.sigs, idx)
			D.save_apps(d)
			return D.ok({ count = #a.sigs })
		end
	end
	return D.err("no such app")
end

function M.appdel(id)
	local d = D.load_apps()
	local keep, found = {}, false
	for _, a in ipairs(d.apps) do
		if tostring(a.id) == tostring(id) then found = true else keep[#keep + 1] = a end
	end
	if not found then return D.err("no such app") end
	d.apps = keep
	D.save_apps(d)
	return D.ok({})
end

function M.qoslist()
	local d = D.load_qos()
	local ips = D.load_appips()
	local out = {}
	for _, r in ipairs(d.rules) do
		out[#out + 1] = { id = r.id, ip = r.ip, app = r.app, dscp = r.dscp,
		                  action = r.action or "dscp",
		                  ips = #(ips[r.app] or {}) }
	end
	return { success = true, running = true, rules = out, levels = D.QOS_LEVELS }
end

function M.qosadd(ip, app, dscp)
	if (not ip or ip == "") and (not app or app == "") then
		return D.err("pick a device, an app, or both")
	end
	if dscp and dscp ~= "block" and D.QOS_LEVELS[dscp] == nil then
		return D.err("unknown class")
	end
	local d = D.load_qos()
	for _, r in ipairs(d.rules) do
		if (r.ip or "") == (ip or "") and (r.app or "") == (app or "") then
			return D.err("that rule already exists")
		end
	end
	d.seq = d.seq + 1
	d.rules[#d.rules + 1] = { id = d.seq, ip = ip or "", app = app or "",
	                          dscp = (dscp ~= "block") and (dscp or "cs1") or nil,
	                          action = (dscp == "block") and "block" or "dscp" }
	D.save_json_map(D.QOS_FILE, d)
	local okk = D.apply_qos()
	return D.ok({ id = d.seq, applied = okk })
end

function M.qosdel(id)
	local d = D.load_qos()
	local keep, found = {}, false
	for _, r in ipairs(d.rules) do
		if tostring(r.id) == tostring(id) then found = true else keep[#keep + 1] = r end
	end
	if not found then return D.err("no such rule") end
	d.rules = keep
	D.save_json_map(D.QOS_FILE, d)
	D.apply_qos()
	return D.ok({})
end

function M.sample_start(duration)
	duration = tonumber(duration) or 60
	if duration < 10 then duration = 10 end
	if duration > 300 then duration = 300 end
	sys.call("pkill -f 'tcpdump.*lg_sample' 2>/dev/null")
	os.remove(D.SAMPLE_PCAP)
	sys.call(string.format(
		"sh -c 'timeout %d tcpdump -i br-lan -U -s 96 -c 4000 -w %s " ..
		"\"udp or tcp[tcpflags] & tcp-push != 0\" >/dev/null 2>&1 &'",
		duration, D.SAMPLE_PCAP))
	D.save_json_map(D.SAMPLE_STATE, { started = os.time(), duration = duration })
	return D.ok({ started = os.time(), duration = duration })
end

function M.sample_stop()
	sys.call("pkill -f 'tcpdump.*lg_sample' 2>/dev/null")
	return D.ok({})
end

function M.sample_result()
	local st = D.load_json_map(D.SAMPLE_STATE, function() return {} end)
	local running = D.sample_running()
	local f = io.open(D.SAMPLE_PCAP, "rb")
	if not f then
		return { success = true, running = running, groups = {},
		         started = st.started, duration = st.duration, packets = 0 }
	end
	local data = f:read("*a")
	f:close()
	if not data or #data < 24 then
		return { success = true, running = running, groups = {},
		         started = st.started, duration = st.duration, packets = 0 }
	end

	local pkts = D.parse_pcap(data)
	local groups = {}
	local total = 0
	for _, p in ipairs(pkts) do
		if #p.payload >= 4 then
			total = total + 1
			-- the first four bytes are what a signature records
			local hex = {}
			for i = 1, 4 do hex[i] = string.format("%02x", p.payload:byte(i)) end
			local prefix = table.concat(hex, ":")
			local key = p.proto .. "|" .. p.dport .. "|" .. prefix
			local g = groups[key]
			if not g then
				g = { proto = p.proto, dport = p.dport, prefix = prefix,
				      count = 0, dsts = {}, srcs = {} }
				groups[key] = g
			end
			g.count = g.count + 1
			g.dsts[p.dst] = true
			g.srcs[p.src] = true
		end
	end

	local out = {}
	for _, g in pairs(groups) do
		local dsts, srcs = {}, {}
		for ip in pairs(g.dsts) do dsts[#dsts + 1] = ip end
		for ip in pairs(g.srcs) do srcs[#srcs + 1] = ip end
		out[#out + 1] = { proto = g.proto, dport = g.dport, prefix = g.prefix,
		                  count = g.count, dsts = dsts, srcs = srcs }
	end
	table.sort(out, function(a, b) return a.count > b.count end)
	local top = {}
	for i = 1, math.min(#out, 25) do top[i] = out[i] end

	return { success = true, running = running, groups = top, packets = total,
	         started = st.started, duration = st.duration }
end

function M.sample_save(name, proto, dport, prefix, cls)
	if not name or D.trim(name) == "" then return D.err("name required") end
	if not prefix or prefix == "" then return D.err("no fingerprint") end
	local parts = {}
	local i = 0
	for byte in prefix:gmatch("%x%x") do
		parts[#parts + 1] = i .. ":" .. byte
		i = i + 1
	end
	local dict = table.concat(parts, "|")

	local d = D.load_apps()
	for _, a in ipairs(d.apps) do
		if a.name == D.trim(name) then
			a.sigs[#a.sigs + 1] = { proto = proto or "", dport = dport or "", host = "", dict = dict }
			D.save_apps(d)
			return D.ok({ name = a.name, dict = dict, appended = true })
		end
	end
	d.seq = d.seq + 1
	d.apps[#d.apps + 1] = { id = d.seq, name = D.trim(name), class = cls or "game",
	                        sigs = { { proto = proto or "", dport = dport or "", host = "", dict = dict } } }
	D.save_apps(d)
	return D.ok({ name = D.trim(name), dict = dict, appended = false })
end
return M
