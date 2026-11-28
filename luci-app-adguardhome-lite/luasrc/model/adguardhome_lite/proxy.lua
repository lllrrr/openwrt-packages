-- AdGuard Home 管理中心：旁路代理（OpenClash / PassWall）探测
-- 只做只读查询，用于在界面上提示端口占用与上游联动。

local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local M = {}

-- 检测 Clash 的 53 劫持目标端口（兼容 redirect to :PORT 与 dnat ... :PORT）
function M.openclash_hijack_port()
    local out = sys.exec("nft list chain inet fw4 dstnat 2>/dev/null | grep 'Clash DNS Hijack' | head -n 1")
    if not out or out == "" then
        return ""
    end

    local p = out:match("redirect to :(%d+)") or out:match("dnat.*:(%d+)")
    return p or ""
end

function M.openclash_running()
    return sys.call("pidof clash >/dev/null 2>&1") == 0
end

-- Clash 是否启用了自定义上游 DNS，且其中包含指向 AdGuard Home 的条目
function M.openclash_upstream_agh(port)
    local found = false
    pcall(function()
        uci:foreach("openclash", "dns_servers", function(s)
            local enabled = tostring(s.enabled or "1")
            local sport = tostring(s.port or "")
            if enabled ~= "0" and s.group == "nameserver"
                and s.ip == "127.0.0.1" and sport == tostring(port) then
                found = true
            end
        end)
    end)
    return found
end

function M.passwall_enabled()
    if (uci:get("passwall2", "@global[0]", "enabled") or "") == "1" then
        return true
    end
    return (uci:get("passwall", "@global[0]", "enabled") or "") == "1"
end

-- 端口由 get_new_port 动态分配：PassWall 1.x 从 11400 起，变量名 ACL_default_dns_port；
-- PassWall 2.x 从 2001 起，默认 ACL 的变量名为 ACL_acl_default_dns_port。
-- 两者都装时以 PassWall2 为准，避免读到 1.x 的残留运行时文件。
function M.passwall_dns_port()
    local files, keys, fallback
    if (uci:get("passwall2", "@global[0]", "enabled") or "") == "1" then
        files = { "/tmp/etc/passwall2/var", "/tmp/etc/passwall2_tmp/var" }
        keys = { "ACL_acl_default_dns_port", "ACL_default_dns_port" }
        fallback = "2001"
    else
        files = { "/tmp/etc/passwall/var", "/tmp/etc/passwall_tmp/var" }
        keys = { "ACL_default_dns_port" }
        fallback = "11400"
    end
    for _, f in ipairs(files) do
        local content = fs.readfile(f)
        if content then
            for _, key in ipairs(keys) do
                local port = content:match(key .. "=[\"']?(%d+)")
                if port then
                    return port
                end
            end
        end
    end
    return fallback
end

return M
