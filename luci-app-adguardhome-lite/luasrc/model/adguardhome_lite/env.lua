-- AdGuard Home 管理中心：常量与运行环境探测
-- 只放与具体业务无关的底层能力，控制器、动作层与测试共用。

local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local util = require "luci.model.adguardhome_lite.util"
local yaml = require "luci.model.adguardhome_lite.yaml"

local M = {}

M.CONF = "adguardhome_lite"
M.SHARE = "/usr/share/adguardhome-lite"
M.RUN = "/var/run/adguardhome_lite"
M.STATS_CACHE = M.RUN .. "_stats.json"
M.VERSION_CACHE = M.RUN .. "_core_version"
M.CORE_UPDATE = M.RUN .. "_core_update"
M.PLUGIN_UPDATE = M.RUN .. "_plugin_update"
M.INSTALL_VERSION = M.SHARE .. "/install_version"
M.RELEASE_URL = "https://github.com/Ozero-top/luci-app-adguardhome-lite/releases/latest"

-- 所有缓存与超时集中在此，避免散落的魔法数字难以核对
M.TTL = {
    stats = 8,               -- 统计缓存：页面 10 秒轮询，8 秒可拿到新数据
    plugin_version = 3600,   -- 插件版本缓存
    update_ok = 86400,       -- 内核/插件查新成功缓存一天
    update_fail = 600,       -- 查新失败 10 分钟后再试
    update_pending = 3600,   -- 占位缓存（尚无结果）
    notes_grace = 60,        -- 更新说明首次缺失时的等待时间
    update_grace = 60,       -- 内核更新锁已建、pid 未写入时的宽限
    plugin_max_age = 1800,   -- 插件更新标记最长存活时间
    action_grace = 20,       -- 动作刚启动、pid 尚未写入时的宽限
    action_max_age = 1800,   -- 动作标记最长存活时间，防止僵尸锁
}

-- 读取带 TTL 的临时缓存，避免每次请求都重新执行外部命令
function M.read_cache(path, ttl)
    local mtime = fs.stat(path, "mtime")
    if not mtime then
        return nil
    end
    if ttl and (os.time() - mtime) > ttl then
        return nil
    end
    local data = fs.readfile(path)
    if not data or data == "" then
        return nil
    end
    return data
end

function M.cfg(opt, default)
    local v = uci:get(M.CONF, "main", opt)
    if v == nil then
        v = uci:get(M.CONF, "@adguardhome_lite[0]", opt)
    end
    if v == nil or v == "" then
        return default
    end
    return v
end

-- 老版本升级时 UCI 还没有缓存选项，读取 YAML 现有值作为界面初值，
-- 避免第一次打开页面就把用户原来的缓存状态显示错。
M.CACHE_YAML_KEYS = {
    cache_enabled = "cache_enabled",
    cache_size_mb = "cache_size",
    cache_ttl_min = "cache_ttl_min",
    cache_ttl_max = "cache_ttl_max",
    cache_optimistic = "cache_optimistic"
}

-- 缓存配置以 AdGuard Home 的 YAML 为准（AGH 面板与插件 UI 共用同一份），
-- YAML 不存在或缺少字段时才回退到 UCI / 默认值。
function M.cache_option(configpath, key, default)
    -- 新版 AGH 把缓存选项放在顶层 dns 区块下，而不是独立的 cache 区块
    local raw = yaml.scalar(configpath, "dns", M.CACHE_YAML_KEYS[key])
    if raw ~= nil and raw ~= "" then
        raw = raw:gsub('"', "")

        if key == "cache_enabled" or key == "cache_optimistic" then
            if raw == "true" then
                return "1"
            elseif raw == "false" then
                return "0"
            end
            return default
        elseif key == "cache_size_mb" then
            local bytes = tonumber(raw)
            if bytes and bytes > 0 then
                return tostring(math.floor(bytes / 1048576 + 0.5))
            end
            return default
        end

        local n = tonumber(raw)
        if n then
            return tostring(math.floor(n))
        end
        return default
    end

    local v = uci:get(M.CONF, "main", key)
    if v ~= nil and v ~= "" then
        return v
    end
    return default
end

-- 排除列表（接口 / 客户端 IP）的解析与校验。
-- 这些值最终会写进 nft 规则文件，必须先做严格的白名单校验。
-- 接口候选只取 /sys/class/net 下的目录；内核自带的空隧道/占位设备一并跳过。
M.IGNORED_IFACE_PATTERNS = {
    "^lo$", "^dummy%d+$", "^sit%d+$", "^ip6tnl%d+$", "^tunl%d+$",
    "^gre%d+$", "^gretap%d+$", "^erspan%d+$", "^ip6gre%d+$",
    "^ip6_vti%d+$", "^teql%d+$", "^siit%d+$", "^utun%d*$",
}

function M.iface_ignored(name)
    for _, pat in ipairs(M.IGNORED_IFACE_PATTERNS) do
        if name:match(pat) then
            return true
        end
    end
    return false
end

function M.net_devices()
    local out = sys.exec("for d in /sys/class/net/*; do [ -d \"$d\" ] && echo \"${d##*/}\"; done") or ""
    local list = {}
    for name in out:gmatch("[^\n]+") do
        if not M.iface_ignored(name) and util.valid_iface_name(name) then
            list[#list + 1] = name
        end
    end
    table.sort(list)
    return list
end

function M.is_enabled()
    local v = M.cfg("enabled", "0")
    return v == "1" or v == 1 or v == true
end

function M.service_running(binpath)
    -- 优先用 procd init.d 的 status：procd 跟踪子进程，返回 rc=0 即为 running。
    -- 这绕开了 pgrep -f 的 cmdline 自匹配问题（shell 命令行里含 binpath 时 pgrep 会匹配到自己）。
    if sys.call("/etc/init.d/adguardhome_lite status >/dev/null 2>&1") == 0 then
        return true
    end
    -- 兜底：init.d 文件不存在时才走到这里，用 /proc/*/maps 查 binpath 是否被任何进程 mmap，
    -- 同样不依赖 cmdline，避开 pgrep -f 的自匹配。
    local initd = fs.access("/etc/init.d/adguardhome_lite")
    if not initd then
        if not binpath or binpath == "" then
            return false
        end
        local out = sys.exec(string.format(
            "grep -l %q /proc/*/maps 2>/dev/null | head -n 1", binpath))
        return out and out ~= ""
    end
    return false
end

function M.read_number(path)
    local v = fs.readfile(path)
    if not v then
        return nil
    end
    v = v:match("[-]?%d+")
    return v and tonumber(v) or nil
end

-- 读取持久化状态（上次应用/更新/回退结果），仅用于展示与排障
function M.state_value(key)
    local raw = fs.readfile("/etc/adguardhome_lite/state/" .. key) or ""
    return (raw:gsub("%s+$", ""))
end

function M.interval_days(value, default)
    local n, unit = tostring(value or ""):match("^(%d+)%s*([dhms])$")
    n = tonumber(n)
    if not n or n < 1 then
        return default
    end
    if unit == "h" then
        return math.max(1, math.floor(n / 24 + 0.5))
    elseif unit == "s" then
        return math.max(1, math.floor(n / 86400 + 0.5))
    end
    return n
end

return M
