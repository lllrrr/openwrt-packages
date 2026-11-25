-- AdGuard Home 家长控制服务探测
-- 开启家长控制后，AdGuard Home 会把每条未命中本地规则的查询送到
-- family.adguard-dns.com 做判定。这个域名在国内直连通常超时，
-- 会导致全屋上不了网。所以开启前先试拨一次，已开启但试拨不通时自动关闭。

local M = {}

M.URL = "https://family.adguard-dns.com/dns-query"

local CACHE_SUFFIX = "_parental_probe"

local function cache_path(run)
    return run .. CACHE_SUFFIX
end

-- 读取试拨结果：true/false，缓存不存在或超过 ttl 秒时返回 nil
function M.cached(fs, run, ttl)
    local path = cache_path(run)
    local mtime = fs.stat(path, "mtime")
    if not mtime then
        return nil
    end
    if ttl and ttl > 0 and (os.time() - mtime) > ttl then
        return nil
    end
    local value = (fs.readfile(path) or ""):match("^%s*(%a+)")
    if value == "ok" then
        return true
    elseif value == "fail" then
        return false
    end
    return nil
end

-- 同步试拨一次，结果写入缓存文件，后续刷新状态直接复用，避免每次都等 curl
function M.probe(sys, fs, run, timeout)
    local path = cache_path(run)
    sys.call(string.format(
        "curl -s -o /dev/null -m %d -w '%%{http_code}' %q > %q 2>/dev/null",
        timeout or 5, M.URL, path))
    local code = (fs.readfile(path) or ""):match("(%d%d%d)")
    -- 000 表示 DNS / TCP / TLS 任何一步失败，按不可达处理
    local ok = code ~= nil and code ~= "000"
    fs.writefile(path, ok and "ok\n" or "fail\n")
    return ok
end

-- ttl 为 0 或 nil 时强制重新试拨
function M.reachable(sys, fs, run, ttl, timeout)
    local hit = M.cached(fs, run, ttl)
    if hit ~= nil then
        return hit
    end
    return M.probe(sys, fs, run, timeout)
end

-- 状态变化后清掉旧结果，下次重新试拨
function M.invalidate(sys, run)
    sys.call("rm -f " .. cache_path(run))
end

-- 写入系统日志，和 shell 侧 log_event 使用同一 tag，运行日志里可见
function M.log(sys, level, reason, message)
    local prio, tag = "info", "INFO"
    if level == "error" then
        prio, tag = "err", "ERROR"
    elseif level == "warn" then
        prio, tag = "warning", "WARN"
    end
    sys.call(string.format("logger -t adguardhome_lite -p user.%s %q 2>/dev/null",
        prio, string.format("[%s] %s: %s", tag, reason, message)))
end

return M
