#!/usr/bin/lua

------------------------------------------------
-- This file is part of the luci-app-naived update.lua
-- By Mattraks
------------------------------------------------
require "luci.sys"
require "luci.model.uci"
local icount = 0
local args = arg[1]
local uci = require "luci.model.uci".cursor()

-- Configure the DNSMASQ path used for database updates
-- Get the DNSMASQ config ID
local DNSMASQ_UCI_CONFIG = uci:get_first("dhcp", "dnsmasq", ".name")

-- Get the default DNSMASQ config file
local DNSMASQ_CONF_PATH = "/tmp/etc/dnsmasq.conf." .. DNSMASQ_UCI_CONFIG

-- If the DNSMASQ config file exists, extract conf-dir
for line in io.lines(DNSMASQ_CONF_PATH) do
    local conf_dir = line:match("^conf%-dir=(.+)")
    if conf_dir then
        DNSMASQ_CONF_DIR = conf_dir:gsub("%s+", "") -- Remove whitespace
        break
    end
end

-- Set the dnsmasq-naived.d directory path and trim the trailing slash
local TMP_DNSMASQ_PATH = DNSMASQ_CONF_DIR:match("^(.-)/?$") .. "/dnsmasq-naived.d"

local TMP_PATH = "/var/etc/naived"
-- match comments/title/whitelist/ip address/excluded_domain
local comment_pattern = "^[!\\[@]+"
local ip_pattern = "^%d+%.%d+%.%d+%.%d+"
local domain_pattern = "([%w%-%_]+%.[%w%.%-%_]+)[%/%*]*"
local excluded_domain = {
    "apple.com", "sina.cn", "sina.com.cn", "baidu.com", "byr.cn", "jlike.com", 
    "weibo.com", "zhongsou.com", "youdao.com", "sogou.com", "so.com", "soso.com", 
    "aliyun.com", "taobao.com", "jd.com", "qq.com"
}
-- gfwlist parameter
local mydnsip = '127.0.0.1'
local mydnsport = '5335'
local ipsetname = 'gfwlist'
local new_appledns = uci:get_first("naived", "global", "apple_dns")
local bc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
-- base64decoding
local function base64_dec(data)
	data = string.gsub(data, '[^' .. bc .. '=]', '')
	return (data:gsub('.', function(x)
		if (x == '=') then
			return ''
		end
		local r, f = '', (bc:find(x) - 1)
		for i = 6, 1, -1 do
			r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0')
		end
		return r;
	end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
		if (#x ~= 8) then
			return ''
		end
		local c = 0
		for i = 1, 8 do
			c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0)
		end
		return string.char(c)
	end))
end
-- check if domain is excluded
local function check_excluded_domain(value)
	for _, domain in ipairs(excluded_domain) do
		if value:find(domain) then
			return true
		end
	end
end
-- Convert gfwlist data to dnsmasq format
local function generate_gfwlist(type)
    local domains, domains_map = {}, {}
    local out = io.open("/tmp/naived-update." .. type, "w")
    for line in io.lines("/tmp/naived-update.tmp") do
        if not (string.find(line, comment_pattern) or string.find(line, ip_pattern) or check_excluded_domain(line)) then
            local start, finish, match = string.find(line, domain_pattern)
            if start and not domains_map[match] then
                domains_map[match] = true
                table.insert(domains, match)
            end
        end
    end
    for _, domain in ipairs(domains) do
        out:write(string.format("server=/%s/%s#%s\n", domain, mydnsip, mydnsport))
        out:write(string.format("ipset=/%s/%s\n", domain, ipsetname))
    end
    out:close()
    os.remove("/tmp/naived-update.tmp")
end

-- Rewrite Apple DNS rules
local function generate_apple(type)
	local domains, domains_map = {}, {}
	local out = io.open("/tmp/naived-update." .. type, "w")
	for line in io.lines("/tmp/naived-update.tmp") do
		if not (string.find(line, comment_pattern)) then
			local start, finish, match = string.find(line, domain_pattern)
			if start and not domains_map[match] then
				domains_map[match] = true
				match = string.gsub(match, "%s", "") -- Remove all whitespace from the domain
				table.insert(domains, match)
			end
		end
	end
	for _, domain in ipairs(domains) do
        if new_appledns and new_appledns ~= "" then
            out:write(string.format("server=/%s/%s\n", domain, new_appledns))
        end
	end
	out:close()
	os.remove("/tmp/naived-update.tmp")
end

-- Convert ad-block data to dnsmasq format
local function generate_adblock(type)
	local domains, domains_map = {}, {}
	local out = io.open("/tmp/naived-update." .. type, "w")
	for line in io.lines("/tmp/naived-update.tmp") do
		if not (string.find(line, comment_pattern)) then
			local start, finish, match = string.find(line, domain_pattern)
			if start and not domains_map[match] then
				domains_map[match] = true
				table.insert(domains, match)
			end
		end
	end
	for _, domain in ipairs(domains) do
		out:write(string.format("address=/%s/\n", domain))
	end
	out:close()
	os.remove("/tmp/naived-update.tmp")
end

local log = function(...)
	if args then
		print("{ret=" .. table.concat({...}, ",retcount=") .. "}")
	else
		print(os.date("%Y-%m-%d %H:%M:%S ") .. table.concat({...}, " "))
	end
end

local function update(url, file, type, file2)
	local Num = 1
	local refresh_cmd = "curl -sSL --insecure -o /tmp/naived-update." .. type .. " " .. url
	local sret = luci.sys.call(refresh_cmd)
	if sret == 0 then
		if type == "gfw_data" then
			local gfwlist = io.open("/tmp/naived-update." .. type, "r")
			local decode = gfwlist:read("*a")
			if not decode:find("google") then
				decode = base64_dec(decode)
			end
			gfwlist:close()
			-- Write back the decoded gfwlist
				gfwlist = io.open("/tmp/naived-update.tmp", "w")
			gfwlist:write(decode)
			gfwlist:close()
			generate_gfwlist(type)
			Num = 2
		end
		if type == "apple_data" then
				local apple = io.open("/tmp/naived-update." .. type, "r")
			local decode = apple:read("*a")
			if not decode:find("apple") then
				decode = base64_dec(decode)
			end
			apple:close()
			-- Write back Apple China data
				apple = io.open("/tmp/naived-update.tmp", "w")
			apple:write(decode)
			apple:close()
			if new_appledns and new_appledns ~= "" then
				generate_apple(type)
			end
		end
		if type == "ad_data" then
				local adblock = io.open("/tmp/naived-update." .. type, "r")
			local decode = adblock:read("*a")
			if decode:find("address=") then
				adblock:close()
			else
				adblock:close()
				-- Write back ad-block data
					adblock = io.open("/tmp/naived-update.tmp", "w")
				adblock:write(decode)
				adblock:close()
				generate_adblock(type)
			end
		end
		local new_md5 = luci.sys.exec("echo -n $([ -f '/tmp/naived-update." .. type .. "' ] && md5sum /tmp/naived-update." .. type .. " | awk '{print $1}')")
		local old_md5 = luci.sys.exec("echo -n $([ -f '" .. file .. "' ] && md5sum " .. file .. " | awk '{print $1}')")
		if new_md5 == old_md5 then
			if args then
				log(1)
			else
				log("Data already up to date, no update needed!")
			end
		else
			icount = luci.sys.exec("cat /tmp/naived-update." .. type .. " | wc -l")
			luci.sys.exec("cp -f /tmp/naived-update." .. type .. " " .. file)
			if file2 then
				luci.sys.exec("cp -f /tmp/naived-update." .. type .. " " .. file2)
			end
			if type == "gfw_data" or type == "ad_data" then
				luci.sys.call("sh /usr/share/naived/gfw2ipset.sh")
			else
				if luci.sys.call("command -v ipset >/dev/null 2>&1") == 0 then
						luci.sys.call("sh /usr/share/naived/chinaipset.sh " .. TMP_PATH .. "/china_ip.txt")
				end
			end
			if args then
				log(0, tonumber(icount) / Num)
			else
				log("Update succeeded! New total record count: " .. tostring(tonumber(icount) / Num))
			end
		end
	else
		if args then
			log(-1)
		else
			log("Update failed!")
		end
	end
	os.remove("/tmp/naived-update." .. type)
end

if args then
	if args == "gfw_data" then
		update(uci:get_first("naived", "global", "gfwlist_url"), "/etc/naived/gfw_list.conf", args, TMP_DNSMASQ_PATH .. "/gfw_list.conf")
		os.exit(0)
	end
	if args == "ip_data" then
			update(uci:get_first("naived", "global", "chnroute_url"), "/etc/naived/china_ip.txt", args, TMP_PATH .. "/china_ip.txt")
		os.exit(0)
	end
	if args == "apple_data" then
		update(uci:get_first("naived", "global", "apple_url"), "/etc/naived/applechina.conf", args, TMP_DNSMASQ_PATH .. "/applechina.conf")
		os.exit(0)
	end
	if args == "ad_data" then
		update(uci:get_first("naived", "global", "adblock_url"), "/etc/naived/ad.conf", args, TMP_DNSMASQ_PATH .. "/ad.conf")
		os.exit(0)
	end
	if args == "nfip_data" then
		update(uci:get_first("naived", "global", "nfip_url"), "/etc/naived/netflixip.list", args, TMP_DNSMASQ_PATH .. "/netflixip.list")
		os.exit(0)
	end
else
	log("Updating the GFW list database")
	update(uci:get_first("naived", "global", "gfwlist_url"), "/etc/naived/gfw_list.conf", "gfw_data", TMP_DNSMASQ_PATH .. "/gfw_list.conf")
	log("Updating the China IP database")
	update(uci:get_first("naived", "global", "chnroute_url"), "/etc/naived/china_ip.txt", "ip_data", TMP_PATH .. "/china_ip.txt")
	if uci:get_first("naived", "global", "apple_optimization", "0") == "1" then
		log("Updating the Apple domain database")
		update(uci:get_first("naived", "global", "apple_url"), "/etc/naived/applechina.conf", "apple_data", TMP_DNSMASQ_PATH .. "/applechina.conf")
	end
	if uci:get_first("naived", "global", "adblock", "0") == "1" then
		log("Updating the ad-block database")
		update(uci:get_first("naived", "global", "adblock_url"), "/etc/naived/ad.conf", "ad_data", TMP_DNSMASQ_PATH .. "/ad.conf")
	end
	if uci:get_first("naived", "global", "netflix_enable", "0") == "1" then
		log("Updating the Netflix IP database")
		update(uci:get_first("naived", "global", "nfip_url"), "/etc/naived/netflixip.list", "nfip_data", TMP_DNSMASQ_PATH .. "/netflixip.list")
	end
	-- log("Updating the Netflix IP database")
	-- update(uci:get_first("naived", "global", "nfip_url"), "/etc/naived/netflixip.list", "nfip_data")
end
