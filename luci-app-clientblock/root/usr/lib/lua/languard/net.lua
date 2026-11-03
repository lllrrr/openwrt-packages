-- languard/net.lua — 地址、邻居表、租约的纯解析
--
-- 这里不做任何写入,也不持有状态文件;调用方传入它需要的东西。
-- 之所以独立:这些函数被设备列表、流量统计、封禁链路共同使用,
-- 而它们之间没有共享的可变状态。

local sys = require "luci.sys"

local M = {}

local lease_file = "/tmp/dhcp.leases"
local neigh_cmd = "ip -4 neigh show dev br-lan 2>/dev/null"
local lan_prefix_fn

function M.setup(opts)
	lease_file = opts.lease_file or lease_file
	neigh_cmd = opts.neigh_cmd or neigh_cmd
	lan_prefix_fn = opts.lan_prefix
end

function M.normalize_mac(mac)
	if not mac then return nil end
	mac = mac:lower():gsub("[^0-9a-f]", "")
	if #mac ~= 12 then return nil end
	return mac:sub(1, 2) .. ":" .. mac:sub(3, 4) .. ":" .. mac:sub(5, 6) .. ":" ..
	       mac:sub(7, 8) .. ":" .. mac:sub(9, 10) .. ":" .. mac:sub(11, 12)
end

-- 只接受结构合法的 IPv6:至多一个 "::",每段 1-4 位十六进制,组数合法。
-- 必须在这里判死:一条 nft 拒收的地址会让整个 fw4 reload 失败,
-- 而失败前已经卸载了我们自己的链,封禁会静默消失。
local function valid_v6(x)
	if not x:find(":", 1, true) then return false end
	local dc, pos = 0, 1
	while true do
		local i = x:find("::", pos, true)
		if not i then break end
		dc = dc + 1
		if dc > 1 then return false end
		pos = i + 2
	end
	local groups = 0
	for g in (x .. ":"):gmatch("([^:]*):") do
		if g ~= "" then
			if #g > 4 or g:find("[^0-9a-fA-F]") then return false end
			groups = groups + 1
		end
	end
	if dc > 0 then return groups <= 7 end
	return groups == 8
end

-- "1.2.3.4" / "1.2.3.0/24" / IPv6 -> 规范化形式,非法返回 nil
function M.normalize_ip(v)
	if not v then return nil end
	v = v:gsub("^%s+", ""):gsub("%s+$", "")
	if v == "" or #v > 43 then return nil end
	local a, b, c, d, plen = v:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)/(%d+)$")
	if a then
		a, b, c, d, plen = tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(plen)
		if not (a and b and c and d and plen) then return nil end
		if a > 255 or b > 255 or c > 255 or d > 255 or plen > 32 then return nil end
		return string.format("%d.%d.%d.%d/%d", a, b, c, d, plen)
	end
	a, b, c, d = v:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if a then
		a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
		if not (a and b and c and d) then return nil end
		if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
		return string.format("%d.%d.%d.%d", a, b, c, d)
	end
	local v6, plen6 = v:match("^([0-9a-fA-F:]+)/(%d+)$")
	if v6 then
		plen6 = tonumber(plen6)
		if plen6 and plen6 <= 128 and valid_v6(v6) then
			return v6:lower() .. "/" .. plen6
		end
		return nil
	end
	if valid_v6(v) then return v:lower() end
	return nil
end

-- 本地管理地址(容器、虚拟机和手机的随机 MAC)没有厂商条目
function M.is_local_mac(mac)
	local b = tonumber(mac:sub(1, 2), 16)
	return b ~= nil and (b % 4) >= 2
end

function M.ipv4_to_int(ip)
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
end

-- 用除法代替位运算:Lua 5.1 没有位运算符,bit 库在部分固件上缺失
function M.cidr_match(ip, cidr)
	local net, bits = cidr:match("^([%d%.]+)/(%d+)$")
	if not net then net, bits = cidr, 32 end
	bits = tonumber(bits)
	local a, b = M.ipv4_to_int(ip), M.ipv4_to_int(net)
	if not a or not b then return false end
	if bits <= 0 then return true end
	if bits > 32 then return false end
	local size = 2 ^ (32 - bits)
	return math.floor(a / size) == math.floor(b / size)
end

function M.is_private_ip(ip)
	return M.cidr_match(ip, "10.0.0.0/8") or M.cidr_match(ip, "172.16.0.0/12")
		or M.cidr_match(ip, "192.168.0.0/16") or M.cidr_match(ip, "127.0.0.0/8")
		or M.cidr_match(ip, "169.254.0.0/16")
end

function M.lan_prefix()
	local out = sys.exec("ip -4 addr show dev br-lan 2>/dev/null") or ""
	return out:match("inet%s+(%d+%.%d+%.%d+)%.")
end

function M.parse_leases()
	local map = {}
	local f = io.open(lease_file, "r")
	if not f then return map end
	for line in f:lines() do
		local exp, mac, ip, host = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
		if mac then
			map[mac:lower()] = { ip = ip, host = (host ~= "*" and host or nil), expires = tonumber(exp) }
		end
	end
	f:close()
	return map
end

function M.parse_neigh()
	local map = {}
	local fh = io.popen(neigh_cmd, "r")
	if not fh then return map end
	for line in fh:lines() do
		local ip, mac = line:match("^(%d+%.%d+%.%d+%.%d+)%s+lladdr%s+(%S+)")
		if ip and mac then
			map[mac:lower()] = ip
		end
	end
	fh:close()
	return map
end

function M.parse_static_hosts()
	local map = {}
	local out = sys.exec("uci -q show dhcp 2>/dev/null") or ""
	local cur = {}
	for line in out:gmatch("[^\n]+") do
		local idx, key, val = line:match("^dhcp%.@host%[(%d+)%]%.(%w+)='(.*)'$")
		if idx then
			cur[idx] = cur[idx] or {}
			cur[idx][key] = val
		end
	end
	for _, h in pairs(cur) do
		if h.mac and h.ip then
			for mac in h.mac:gmatch("%S+") do
				map[mac:lower()] = { ip = h.ip, host = h.name }
			end
		end
	end
	return map
end

-- 并行 ping 后重读邻居表:唤醒那些一直静默、从不显示 REACHABLE 的 IoT 设备
function M.probe_online()
	local base = (lan_prefix_fn and lan_prefix_fn()) or M.lan_prefix() or "192.168.1"
	sys.call(string.format(
		"for i in $(seq 2 254); do (ping -c1 -W1 %s.$i >/dev/null 2>&1) & done; wait", base), 25)
	return M.parse_neigh()
end

return M
