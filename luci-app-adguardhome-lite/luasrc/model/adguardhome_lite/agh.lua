-- AdGuard Home 本机 API 客户端
-- 凭据通过 0600 的 netrc 临时文件交给 curl，避免密码出现在进程列表。

local fs = require "nixio.fs"
local jsonc = require "luci.jsonc"
local sys = require "luci.sys"

local M = {}

local opts = {
    user = "admin",
    pass = "admin123",
    port = 13800
}

function M.configure(t)
    t = t or {}
    opts.user = t.user or opts.user
    opts.pass = t.pass or opts.pass
    opts.port = tonumber(t.port) or opts.port
end

local function tmp_path(prefix)
    return string.format("/tmp/%s.%d.%d", prefix, os.time(), math.random(100000, 999999))
end

-- 通过 0600 的 netrc 临时文件传凭据
local function with_netrc(fn)
    local pass = (opts.pass or ""):gsub("[\r\n]", "")
    local path = tmp_path("adguardhome_lite_netrc")
    local body = string.format("machine 127.0.0.1\nlogin %s\npassword %s\n", opts.user, pass)

    if not fs.writefile(path, body) then
        return nil
    end
    sys.call(string.format("chmod 600 %q >/dev/null 2>&1", path))

    local ok, result = pcall(fn, path)
    os.remove(path)
    if not ok then
        return nil
    end
    return result
end

-- 调用本机接口；返回 HTTP 状态码与响应体
-- timeout 默认 8 秒；订阅刷新这类会真正下载上游列表的接口需要放宽
function M.request(path, method, body, timeout)
    local url = string.format("http://127.0.0.1:%d%s", opts.port, path)
    local req = tmp_path("agh_api_req.json")
    local res = tmp_path("agh_api_res.json")

    local code = with_netrc(function(netrc)
        local cmd = string.format(
            "curl -s -m %d -o %q -w '%%{http_code}' --netrc-file %q",
            tonumber(timeout) or 8, res, netrc)
        -- PUT 用于 AdGuard Home v1.0 起新增的设置类接口（如 /control/safesearch/settings）
        if method == "POST" or method == "PUT" then
            if body then
                local f = io.open(req, "w")
                if f then
                    f:write(body)
                    f:close()
                end
                cmd = cmd .. " -H 'Content-Type: application/json' -X " .. method
                    .. " --data-binary @" .. string.format("%q", req)
            else
                cmd = cmd .. " -X " .. method
            end
        end
        sys.call(string.format("chmod 600 %q >/dev/null 2>&1", req))
        return sys.exec(cmd .. " " .. string.format("%q", url) .. " 2>/dev/null") or ""
    end)

    local resp = fs.readfile(res) or ""
    os.remove(req)
    os.remove(res)

    return code or "", resp
end

-- 读取当前 DNS 配置；失败返回 nil + reason
-- 注意：AGH 的 /control/dns_config 只接受 POST，读取走 /control/dns_info
function M.get_dns_config()
    local code, resp = M.request("/control/dns_info", "GET")
    if code ~= "200" then
        return nil, "agh_api_unreachable"
    end
    local obj = jsonc.parse(resp or "")
    if type(obj) ~= "table" then
        return nil, "agh_api_bad_response"
    end
    return obj
end

-- 只修改指定字段后整体回写，保留 AGH 自己维护的其它字段
function M.patch_dns_config(patch)
    local obj, reason = M.get_dns_config()
    if not obj then
        return false, reason
    end
    for key, value in pairs(patch or {}) do
        obj[key] = value
    end
    -- AdGuard Home v1.0.0 起不再接受空值的 upstream_mode，空值按等价的 load_balance 回写
    if obj.upstream_mode == nil or obj.upstream_mode == "" then
        obj.upstream_mode = "load_balance"
    end
    local code = M.request("/control/dns_config", "POST", jsonc.stringify(obj))
    if code ~= "200" then
        return false, "agh_api_unreachable"
    end
    return true
end

return M
