-- Copyright 2026 luci-app-frpc-pro
-- Licensed to the public under the MIT License.

local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local util = require "luci.util"

local M = {}

local Driver = {}
Driver.__index = Driver

function M.new(cfg)
    local self = setmetatable({}, Driver)
    self.cfg = cfg or {}
    self.path = self.cfg.path or "/etc/frpc-backup"
    -- 去尾斜杠
    self.path = self.path:gsub("/+$", "")
    if self.path == "" then self.path = "/etc/frpc-backup" end
    return self
end

local function shc(cmd)
    return sys.call(cmd .. " >/dev/null 2>&1")
end

function Driver:test()
    -- 确保目录存在
    if not fs.stat(self.path) then
        if shc("mkdir -p " .. util.shellquote(self.path)) ~= 0 then
            return false, "目录不存在且无法创建：" .. self.path
        end
    end
    -- 写探针文件
    local probe = self.path .. "/.frpc_backup_probe"
    local f = io.open(probe, "w")
    if not f then return false, "目录不可写：" .. self.path end
    f:write("ok"); f:close()
    os.remove(probe)
    return true, nil
end

function Driver:list()
    if not fs.stat(self.path) then return {}, nil end
    local entries = {}
    for entry in fs.dir(self.path) do
        if entry:match("^frpc%-backup%-.+%.tar%.gz$") then
            local p = self.path .. "/" .. entry
            local st = fs.stat(p)
            if st then
                table.insert(entries, {
                    id        = entry:gsub("^frpc%-backup%-", ""):gsub("%.tar%.gz$", ""),
                    name      = entry,
                    size      = st.size,
                    mtime     = st.mtime,
                    raw_path  = p,
                })
            end
        end
    end
    table.sort(entries, function(a, b) return a.mtime > b.mtime end)
    return entries, nil
end

function Driver:put(local_path, remote_name, progress_cb)
    if not fs.access(local_path) then return false, "本地文件不存在" end
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    if not fs.stat(self.path) then
        if shc("mkdir -p " .. util.shellquote(self.path)) ~= 0 then
            return false, "目录创建失败"
        end
    end
    local dst = self.path .. "/" .. remote_name
    if shc("cp -f " .. util.shellquote(local_path) .. " " .. util.shellquote(dst)) ~= 0 then
        return false, "本地复制失败"
    end
    if progress_cb then
        local st = fs.stat(dst)
        progress_cb(st and st.size or 0, st and st.size or 0)
    end
    return true, nil
end

function Driver:get(remote_name, local_path, progress_cb)
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local src = self.path .. "/" .. remote_name
    if not fs.access(src) then return false, "远端文件不存在：" .. remote_name end
    if shc("cp -f " .. util.shellquote(src) .. " " .. util.shellquote(local_path)) ~= 0 then
        return false, "本地复制失败"
    end
    if progress_cb then
        local st = fs.stat(local_path)
        progress_cb(st and st.size or 0, st and st.size or 0)
    end
    return true, nil
end

function Driver:remove(remote_name)
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local p = self.path .. "/" .. remote_name
    if not fs.access(p) then return true, nil end -- 已不存在视为成功
    if shc("rm -f " .. util.shellquote(p)) ~= 0 then
        return false, "删除失败"
    end
    return true, nil
end

return M
