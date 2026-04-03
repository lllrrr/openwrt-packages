#!/usr/bin/lua

require "luci.sys"
local ucursor = require "luci.model.uci".cursor()
local json = require "luci.jsonc"

local server_section = arg[1]
local proto          = arg[2] or "tcp"
local local_port     = arg[3] or "0"
local socks_port     = arg[4] or "0"

local chain          = arg[5] or "0"
local chain_local_port = string.split(chain, "/")[2] or "0"

local server = ucursor:get_all("naived", server_section)
local socks_server = ucursor:get_all("naived", "@socks5_proxy[0]") or {}

local node_id = server_section
local remarks = server.alias or ""

-- Ensure program existence checks are accurate
local function is_finded(e)
	return luci.sys.exec(string.format('type -t -p "%s" 2>/dev/null', e)) ~= ""
end

local naiveproxy = {
	proxy = (server.username and server.password and server.server and server.server_port) and "https://" .. server.username .. ":" .. server.password .. "@" .. server.server .. ":" .. server.server_port,
	listen = (proto == "redir") and "redir" .. "://0.0.0.0:" .. tonumber(local_port) or "socks" .. "://0.0.0.0:" .. tonumber(local_port),
	["insecure-concurrency"] = tonumber(server.concurrency) or 1
}

local config = {}
function config:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self
	return o
end
function config:handleIndex(index)
	local switch = {
		naiveproxy = function()
			print(json.stringify(naiveproxy, 1))
		end
	}
	if switch[index] then
		switch[index]()
	end
end
local f = config:new()
f:handleIndex(server.type)
