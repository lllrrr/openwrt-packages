-- languard/nft.lua — 内核侧的唯一写入口
--
-- 规则文件、集合元素、fw4 重载都在这里。其他模块只描述"要拦什么",
-- 不直接拼 nft 命令。

local sys = require "luci.sys"

local M = {}

local rule_file
local load_ips     -- function(): 返回 blocked_ips 表

function M.setup(opts)
	rule_file = opts.rule_file
	load_ips = opts.load_ips
end

function M.chunk(setname, verb, list)
	if #list == 0 then return end
	local i = 1
	while i <= #list do
		local j = math.min(i + 1999, #list)
		local part = {}
		for k = i, j do part[#part + 1] = list[k] end
		local rc = sys.call(string.format("nft %s element inet fw4 %s { %s } 2>/dev/null",
			verb, setname, table.concat(part, ", ")))
		if rc ~= 0 then
			for _, one in ipairs(part) do
				sys.call(string.format("nft %s element inet fw4 %s { %s } 2>/dev/null",
					verb, setname, one))
			end
		end
		i = j + 1
	end
end

function M.set_exists(name)
	return sys.call("nft list set inet fw4 " .. name .. " >/dev/null 2>&1") == 0
end

-- 只重写集合内容,不动规则集:集合对象、链和别的防火墙规则都保持原样
function M.rebuild_sets()
	local ips = load_ips()
	local v4, v6 = {}, {}
	for ip in pairs(ips) do
		if ip:find(":") then v6[#v6 + 1] = ip else v4[#v4 + 1] = ip end
	end
	sys.call("nft flush set inet fw4 blocked_ip4 2>/dev/null")
	sys.call("nft flush set inet fw4 blocked_ip6 2>/dev/null")
	M.chunk("blocked_ip4", "add", v4)
	M.chunk("blocked_ip6", "add", v6)
	return #v4 + #v6
end

function M.unload()
	-- 顺序有讲究:nft 不允许删除仍被规则引用的集合("Resource busy"),
	-- 而活下来的集合会保留所有历史元素。先删链才能让解封真正生效。
	sys.call("nft delete chain inet fw4 user_ip_input >/dev/null 2>&1; " ..
	         "nft delete chain inet fw4 user_ip_forward >/dev/null 2>&1; " ..
	         "nft delete chain inet fw4 user_pre_input >/dev/null 2>&1; " ..
	         "nft delete chain inet fw4 user_pre_forward >/dev/null 2>&1; " ..
	         "nft delete set inet fw4 blocked_ip4 >/dev/null 2>&1; " ..
	         "nft delete set inet fw4 blocked_ip6 >/dev/null 2>&1")
end

-- 运行时增删单个元素,避开约 6 秒的 fw4 全量重载
function M.set_element_live(ip, add)
	local setname = ip:find(":") and "blocked_ip6" or "blocked_ip4"
	local verb = add and "add" or "delete"
	return sys.call(string.format("nft %s element inet fw4 %s { %s } 2>/dev/null",
		verb, setname, ip)) == 0
end

function M.reload_firewall()
	M.unload()
	local ok_ = sys.call("fw4 reload >/dev/null 2>&1") == 0
	if not ok_ then
		-- 再试一次:先清掉自己的对象,避免上一次的残留卡住重载
		M.unload()
		sys.call("fw4 reload >/dev/null 2>&1")
	end
	return ok_
end

return M
