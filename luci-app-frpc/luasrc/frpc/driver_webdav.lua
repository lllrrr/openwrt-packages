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
    self.url = (self.cfg.url or ""):gsub("/+$", "") .. "/"
    self.username = self.cfg.username or ""
    self.password = self.cfg.password or ""
    self.verify_tls = (self.cfg.verify_tls == "1" or self.cfg.verify_tls == true)
    return self
end

-- 构造 curl 通用参数（鉴权 + TLS）
function Driver:_curl_args()
    -- 5 分钟：备份包含 frpc 二进制（约 10MB），慢速链路要给余量
    local args = " --silent --show-error --max-time 300"
    if not self.verify_tls then args = args .. " -k" end
    if self.username ~= "" then
        args = args .. " -u " .. util.shellquote(self.username .. ":" .. self.password)
    end
    return args
end

-- 对 URL 路径段进行 percent-encoding（保留 / : - _ . ~）
local function url_encode_segment(s)
    return (s:gsub("[^%w%-_%.~/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function Driver:_remote_url(name)
    return self.url .. url_encode_segment(name)
end

-- test：PROPFIND Depth: 0 到根 URL；2xx 即 OK
function Driver:test()
    if not self.url:match("^https?://") then
        return false, "URL 必须以 http:// 或 https:// 开头"
    end
    local cmd = string.format(
        "curl%s -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%%{http_code}' %s 2>&1",
        self:_curl_args(), util.shellquote(self.url))
    local code = util.trim(sys.exec(cmd))
    local n = tonumber(code)
    if n and n >= 200 and n < 300 then
        return true, nil
    end
    if n == 401 then return false, "鉴权失败（401），请检查用户名密码" end
    if n == 404 then return false, "URL 不存在（404）" end
    return false, "WebDAV 测试失败（HTTP " .. (code or "?") .. "）"
end

-- list：PROPFIND Depth: 1，解析 <d:href> 抓文件名
function Driver:list()
    -- 把 http_code 追加到 body 末尾，便于区分鉴权失败与"列表确实空"
    local cmd = string.format(
        "curl%s -X PROPFIND -H 'Depth: 1' -w '\\n__HTTP_CODE__%%{http_code}' %s 2>/dev/null",
        self:_curl_args(), util.shellquote(self.url))
    local out = sys.exec(cmd) or ""
    local body, code_str = out:match("^(.*)\n__HTTP_CODE__(%d%d%d)%s*$")
    if not code_str then return {}, "PROPFIND 无响应或返回格式异常" end
    local n = tonumber(code_str)
    if not (n and n >= 200 and n < 300) then
        if n == 401 then return {}, "鉴权失败（401），请检查用户名密码" end
        if n == 404 then return {}, "URL 不存在（404）" end
        return {}, "PROPFIND 失败（HTTP " .. code_str .. "）"
    end

    local entries = {}
    local seen = {}
    -- 兼容 d:href / D:href / href 命名空间
    for href in body:gmatch("<[%w]*:?href[^>]*>([^<]+)</[%w]*:?href>") do
        -- 提取文件名（href 可能是绝对 URL 或绝对路径）
        local fname = href:match("([^/]+)$")
        if fname then
            -- 解码 percent-encoding
            fname = fname:gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end)
            if fname:match("^frpc%-backup%-.+%.tar%.gz$") and not seen[fname] then
                seen[fname] = true
                -- WebDAV 返回的 getcontentlength 解析比较复杂，简化为不带 size/mtime
                -- 仅在用户点开详情或下载时再获取
                table.insert(entries, {
                    id        = fname:gsub("^frpc%-backup%-", ""):gsub("%.tar%.gz$", ""),
                    name      = fname,
                    size      = 0,
                    mtime     = 0,
                    raw_path  = href,
                })
            end
        end
    end
    return entries, nil
end

function Driver:put(local_path, remote_name, progress_cb)
    if not fs.access(local_path) then return false, "本地文件不存在" end
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local cmd = string.format(
        "curl%s -X PUT --data-binary @%s -o /dev/null -w '%%{http_code}' %s 2>&1",
        self:_curl_args(),
        util.shellquote(local_path),
        util.shellquote(self:_remote_url(remote_name)))
    local code = util.trim(sys.exec(cmd))
    local n = tonumber(code)
    if n and n >= 200 and n < 300 then
        if progress_cb then
            local st = fs.stat(local_path)
            progress_cb(st and st.size or 0, st and st.size or 0)
        end
        return true, nil
    end
    return false, "WebDAV PUT 失败（HTTP " .. (code or "?") .. "）"
end

function Driver:get(remote_name, local_path, progress_cb)
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local cmd = string.format(
        "curl%s -o %s -w '%%{http_code}' %s 2>/dev/null",
        self:_curl_args(),
        util.shellquote(local_path),
        util.shellquote(self:_remote_url(remote_name)))
    local code = util.trim(sys.exec(cmd))
    local n = tonumber(code)
    if n and n >= 200 and n < 300 then
        if progress_cb then
            local st = fs.stat(local_path)
            progress_cb(st and st.size or 0, st and st.size or 0)
        end
        return true, nil
    end
    sys.call("rm -f " .. util.shellquote(local_path))
    return false, "WebDAV GET 失败（HTTP " .. (code or "?") .. "）"
end

function Driver:remove(remote_name)
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local cmd = string.format(
        "curl%s -X DELETE -o /dev/null -w '%%{http_code}' %s 2>&1",
        self:_curl_args(),
        util.shellquote(self:_remote_url(remote_name)))
    local code = util.trim(sys.exec(cmd))
    local n = tonumber(code)
    if n and (n == 204 or n == 200 or n == 404) then
        return true, nil  -- 404 视为已删除
    end
    return false, "WebDAV DELETE 失败（HTTP " .. (code or "?") .. "）"
end

return M
