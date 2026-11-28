-- AdGuard Home 管理中心：内核与插件版本、查新缓存
-- 版本比较是纯函数，放在 util.lua 里便于单测；这里只负责取数与缓存。

local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.model.adguardhome_lite.util"
local env = require "luci.model.adguardhome_lite.env"

local M = {}

local version_newer = util.version_newer
local clean_tag = util.clean_tag

function M.core_version(binpath)
    if not fs.access(binpath, "x") then
        return ""
    end

    -- 优先使用缓存：只要内核文件没变，就直接复用上次结果，
    -- 避免每次刷新页面都启动一次 30MB 的内核查版本。
    local bin_mtime = fs.stat(binpath, "mtime")
    local cache_mtime = fs.stat(env.VERSION_CACHE, "mtime")
    if bin_mtime and cache_mtime and cache_mtime >= bin_mtime then
        local cached = fs.readfile(env.VERSION_CACHE)
        if cached and cached ~= "" then
            return (cached:gsub("%s+$", ""))
        end
    end

    local out = sys.exec(string.format("%q --version 2>/dev/null | head -n 1", binpath))
    if not out or out == "" then
        return ""
    end

    -- 版本号可能带预发布后缀（v1.0.0-b.2），不能只取数字和小数点
    local ver = out:match("[vV]%d[%w%.%-]*") or ""
    ver = ver:gsub("[^%w%.%-]+$", "")
    if ver ~= "" then
        fs.writefile(env.VERSION_CACHE, ver)
    end
    return ver
end

-- 从标签列表里取语义版本最大的一个；旧缓存没有列表时退回单值
function M.latest_tag(list, fallback)
    local best = fallback or ""
    for tag in tostring(list or ""):gmatch("%S+") do
        local v = clean_tag(tag)
        if v ~= "" and (best == "" or version_newer(v, best)) then
            best = v
        end
    end
    return best
end

-- 旧版本通道：取最新正式版之外的上一条正式版本线（如 1.0.0 之前是 0.107.x）
function M.legacy_tag(list, latest_stable)
    local current_series = tostring(latest_stable or ""):match("^(%d+%.%d+)")
    if not current_series then
        return ""
    end
    local best = ""
    for tag in tostring(list or ""):gmatch("%S+") do
        local v = clean_tag(tag)
        if v ~= "" and v:match("^(%d+%.%d+)") ~= current_series
            and (best == "" or version_newer(v, best)) then
            best = v
        end
    end
    return best
end

-- 内核更新检查：按「内核更新通道」取对应最新版本，结果缓存 24 小时
function M.core_update_info(binpath, channel)
    local cache = fs.readfile(env.CORE_UPDATE) or ""
    local stable_tags = cache:match("stable_tags=([^\n]*)") or ""
    local beta_tags = cache:match("beta_tags=([^\n]*)") or ""
    local stable = M.latest_tag(stable_tags, clean_tag(cache:match("stable=([^\n]*)")))
    local beta_tag = M.latest_tag(beta_tags, clean_tag(cache:match("beta=([^\n]*)")))
    local legacy = M.legacy_tag(stable_tags, stable)
    local checked = tonumber(cache:match("time=(%d+)"))

    -- 拿到结果才缓存一天；检查失败时只缓存一小时，尽快重试
    local ttl = (stable ~= "" and beta_tag ~= "") and env.TTL.update_ok or env.TTL.update_pending
    if not checked or (os.time() - checked) > ttl then
        -- 先写占位时间，避免每次轮询都重复启动检查任务；已有标签列表保留
        fs.writefile(env.CORE_UPDATE, string.format(
            "stable=%s\nbeta=%s\nstable_tags=%s\nbeta_tags=%s\ntime=%d\n",
            stable, beta_tag, stable_tags, beta_tags, os.time()))
        sys.exec("sh " .. env.SHARE .. "/check_core_update.sh >/dev/null 2>&1 &")
    elseif channel == "legacy" and legacy == "" and stable_tags == "" then
        -- 旧版缓存没有标签列表，算不出上一条版本线，主动补查一次
        sys.exec("sh " .. env.SHARE .. "/check_core_update.sh >/dev/null 2>&1 &")
    end

    -- 三个通道各自独立：正式版只取正式标签，预发布版只取预发布标签，
    -- 旧版本只取上一条正式版本线。不能把 beta 和 stable 混在一起比大小，
    -- 否则 1.0.0 会盖掉 1.0.0-b.2，导致选了预发布版却安装正式版。
    local latest
    if channel == "beta" then
        latest = beta_tag ~= "" and beta_tag or stable
    elseif channel == "legacy" then
        latest = legacy
    else
        latest = stable
    end

    local current = M.core_version(binpath)
    return {
        current = current,
        latest = latest,
        -- 通道由 Releases API 的 prerelease 标记决定，不能只看版本号里的 -b
        beta = (channel == "beta" and beta_tag ~= "" and latest == beta_tag),
        update = (latest ~= "" and current ~= "" and version_newer(latest, current)) or false
    }
end

-- 插件版本：取包管理器与 install.sh 记录中较新的一个，兼容 ipk 与脚本安装混用
function M.plugin_version()
    -- 通用模式安装（含强制降级）以 install_version 为准，避免包管理器里的旧高版本覆盖显示
    if fs.access(env.SHARE .. "/install_source") then
        local v = (fs.readfile(env.INSTALL_VERSION) or ""):gsub("%s+", "")
        if v:match("^%d+%.%d+") then
            fs.writefile(env.RUN .. "_plugin_version", v)
            return v
        end
    end

    local cached = env.read_cache(env.RUN .. "_plugin_version", env.TTL.plugin_version)
    if cached and cached ~= "" then
        return cached
    end

    local candidates = {}

    local out = sys.exec("opkg list-installed 2>/dev/null | awk '$1 == \"luci-app-adguardhome-lite\" { print $3; exit }'") or ""
    out = out:gsub("%s+", "")
    if out ~= "" then
        candidates[#candidates + 1] = out
    end

    out = sys.exec("apk info -v luci-app-adguardhome-lite 2>/dev/null | head -n 1") or ""
    local ver = out:match("%d+%.%d+%.%d+[%w%.%-]*")
    if ver then
        candidates[#candidates + 1] = ver
    end

    local v = (fs.readfile(env.INSTALL_VERSION) or ""):gsub("%s+", "")
    if v:match("^%d+%.%d+") then
        candidates[#candidates + 1] = v
    end

    local best = ""
    for i = 1, #candidates do
        if best == "" or version_newer(candidates[i], best) then
            best = candidates[i]
        end
    end

    if best ~= "" then
        fs.writefile(env.RUN .. "_plugin_version", best)
    end
    return best
end

-- 插件更新检查：结果缓存 24 小时，过期后在后台重新检查，不阻塞状态接口
function M.plugin_update_info()
    local cache = fs.readfile(env.PLUGIN_UPDATE) or ""
    local latest = clean_tag(cache:match("latest=([^\n]*)"))
    local checked = tonumber(cache:match("time=(%d+)"))
    local notes = cache:match("notes<<EOF\n(.-)\nEOF") or ""
    local failed = cache:match("failed=1") ~= nil
    -- 插件 Release 都是正式版，不比内核的正式版 / 预发布版通道，直接比版本号
    local current = M.plugin_version()

    -- 拿到结果才缓存一天；失败后等 10 分钟再重试，避免离线时随每次状态轮询重复请求
    local ttl = failed and env.TTL.update_fail or ((latest ~= "") and env.TTL.update_ok or env.TTL.update_pending)
    local age = checked and (os.time() - checked) or math.huge
    -- 旧缓存没有更新说明时补一次；留一段时间给后台任务，仍取不到则记 nonotes=1 避免反复请求
    local need_notes = latest ~= "" and notes == "" and not failed
        and not cache:match("nonotes=1") and age > env.TTL.notes_grace
    if need_notes or age > ttl then
        -- 先写占位时间，保留已有说明与失败标记，避免每次轮询都重复启动检查任务
        local placeholder = "latest=" .. latest .. "\ntime=" .. os.time() .. "\n"
        if notes ~= "" then
            placeholder = placeholder .. "notes<<EOF\n" .. notes .. "\nEOF\n"
        end
        if failed then
            placeholder = placeholder .. "failed=1\n"
        end
        fs.writefile(env.PLUGIN_UPDATE, placeholder)
        -- 传入当前版本，让检查脚本合并所有中间版本的更新说明
        sys.exec("sh " .. env.SHARE .. "/check_plugin_update.sh "
            .. string.format("%q", current) .. " >/dev/null 2>&1 &")
    end

    local newer = version_newer(latest, current)

    local url = env.RELEASE_URL
    if latest ~= "" then
        url = "https://github.com/Ozero-top/luci-app-adguardhome-lite/releases/tag/v" .. latest
    end

    return {
        current = current,
        latest = latest,
        update = newer,
        url = url,
        -- 仅在确实有新版本时返回；内容已由检查脚本限制在 12KB 内，可包含多个版本的说明
        notes = newer and notes or ""
    }
end

return M
