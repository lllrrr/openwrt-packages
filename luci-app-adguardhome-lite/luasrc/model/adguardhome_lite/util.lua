-- AdGuard Home 管理中心：纯函数工具
-- 不依赖文件系统、网络或 LuCI 上下文，便于在设备外直接做 Lua 单元测试。

local M = {}

function M.split_words(v)
    local t = {}
    for w in tostring(v or ""):gmatch("%S+") do
        t[#t + 1] = w
    end
    return t
end

function M.join_words(v)
    if type(v) == "table" then
        return table.concat(v, " ")
    end
    return tostring(v or "")
end

function M.valid_iface_name(name)
    return #name <= 15 and name:match("^[%w_%.%-]+$") ~= nil
end

function M.valid_ipv4(addr)
    local a, b, c, d = addr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return false
    end
    return tonumber(a) <= 255 and tonumber(b) <= 255 and tonumber(c) <= 255 and tonumber(d) <= 255
end

local function valid_ipv6(addr)
    if not addr:match("^[%x:]+$") or not addr:find(":", 1, true) then
        return false
    end
    if addr:find(":::", 1, true) then
        return false
    end
    local _, doubles = addr:gsub("::", "")
    if doubles > 1 then
        return false
    end
    local colons = select(2, addr:gsub(":", ""))
    if doubles == 1 then
        return colons >= 2 and colons <= 7
    end
    return colons == 7
end

M.valid_ipv6 = valid_ipv6

function M.valid_client_spec(spec)
    local addr, bits = spec:match("^([^/]+)/(%d+)$")
    if addr then
        if addr:find(":", 1, true) then
            return valid_ipv6(addr) and tonumber(bits) <= 128
        end
        return M.valid_ipv4(addr) and tonumber(bits) <= 32
    end
    if spec:find(":", 1, true) then
        return valid_ipv6(spec)
    end
    return M.valid_ipv4(spec)
end

-- 版本号拆成「基础版本 + 预发布后缀」：1.0.0-b.2 → base {1,0,0}，pre "b"，pre_num 2
-- 纯数字后缀是修订号：1.3.7-2 → {1,3,7,2}，排在 1.3.7 之后
function M.version_info(v)
    local s = tostring(v or ""):lower()
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^v", "")
    local base, rest = s:match("^(%d[%d%.]*)%s*(.*)$")
    if not base then
        return nil
    end
    base = base:gsub("%.$", "")

    local parts = {}
    for n in base:gmatch("%d+") do
        parts[#parts + 1] = tonumber(n)
    end

    local rev = rest:match("^[%.%-_~]+(%d+)$")
    if rev then
        parts[#parts + 1] = tonumber(rev)
        return { parts = parts, pre = "", pre_num = 0 }
    end

    local pre, pre_num = rest:match("^[%.%-_~]*([%a]+)[%.%-_~]*(%d*)")
    return {
        parts = parts,
        pre = pre or "",
        pre_num = tonumber(pre_num or "") or 0
    }
end

function M.version_newer(latest, current)
    local a, b = M.version_info(latest), M.version_info(current)
    if not a or not b then
        return false
    end

    for i = 1, math.max(#a.parts, #b.parts) do
        local x, y = a.parts[i] or 0, b.parts[i] or 0
        if x ~= y then
            return x > y
        end
    end

    -- 基础版本相同时：正式版大于预发布版，预发布之间按通道名与序号比较
    if a.pre == "" and b.pre == "" then
        return false
    end
    if a.pre == "" then
        return true
    end
    if b.pre == "" then
        return false
    end
    if a.pre ~= b.pre then
        return a.pre > b.pre
    end
    return a.pre_num > b.pre_num
end

-- 缓存里的版本可能带 v 前缀或空白，统一后再比较
function M.clean_tag(v)
    return (tostring(v or ""):gsub("%s+", ""):gsub("^[vV]", ""))
end

return M
