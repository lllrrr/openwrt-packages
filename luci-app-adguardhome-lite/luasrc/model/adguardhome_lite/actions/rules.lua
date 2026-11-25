-- AdGuard Home 管理中心 - rules 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}

local parental_service = require "luci.model.adguardhome_lite.parental"

-- 预置规则来自自建规则仓库，按设备内存分三档，每档由若干已去重的分类文件组成
-- 三个下载源目录结构一致，可随时切换，默认 jsDelivr
local PRESET_SOURCES = {
    jsdelivr = "https://cdn.jsdelivr.net/gh/Ozero-top/AdguardHome-Rrules@dist/",
    github = "https://raw.githubusercontent.com/Ozero-top/AdguardHome-Rrules/dist/",
    custom = "https://agh.ozero.top/git/AdguardHome-Rrules/agh-dist/"
}
local PRESET_SOURCE_DEFAULT = "jsdelivr"
-- 首选源失败时的尝试顺序（不含首选源本身）
local PRESET_SOURCE_ORDER = { "github", "jsdelivr", "custom" }

local function preset_source(cfg)
    local s = tostring(cfg("preset_source", PRESET_SOURCE_DEFAULT) or "")
    if not PRESET_SOURCES[s] then
        s = PRESET_SOURCE_DEFAULT
    end
    return s
end

local PRESET_TIERS = {
    ["512"] = { "security", "chinese", "ads" },
    ["1024"] = { "security", "chinese", "tracking", "ads" },
    ["2048"] = { "security", "chinese", "tracking", "ads", "annoyances", "intl" }
}
local PRESET_NAMES = {
    security = "AGH 安全防护",
    chinese = "AGH 中文广告",
    ads = "AGH 全站广告",
    tracking = "AGH 跟踪统计",
    annoyances = "AGH 网页干扰",
    intl = "AGH 外语分区"
}

-- 旧版模板内置的第三方整包订阅，切换档位时一并清理，避免重复生效
local LEGACY_PATTERNS = {
    "adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt",
    "adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt",
    "adguardteam.github.io/HostlistsRegistry/assets/filter_3.txt",
    "adguardteam.github.io/HostlistsRegistry/assets/filter_4.txt",
    "anti-ad.net/easylist.txt",
    "Cats-Team/AdRules",
    "AWAvenue-Ads-Rule",
    "8680/GOODBYEADS",
    "big.oisd.nl",
    "hagezi/dns-blocklists"
}
local LEGACY_WHITELIST = "8680/GOODBYEADS"

-- 识别预置规则地址（含反代前缀），返回 allowlist.txt 或 512/ads.txt 这样的相对路径
local function preset_path(url)
    for _, base in pairs(PRESET_SOURCES) do
        local i = url:find(base, 1, true)
        if i then
            return url:sub(i + #base)
        end
    end
    return nil
end

local function matches_any(url, patterns)
    for _, p in ipairs(patterns) do
        if url:find(p, 1, true) then
            return true
        end
    end
    return false
end

function M.filters_get(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")

    local code, resp = agh_api("/control/filtering/status", "GET")
    if code ~= "200" then
        http.write_json({ ok = false, error = "读取过滤规则失败，请确认 AdGuard Home 正在运行。" })
        return
    end

    local okc, jsonc = pcall(require, "luci.jsonc")
    local data = okc and jsonc.parse(resp) or nil
    if not data then
        http.write_json({ ok = false, error = "解析过滤规则失败。" })
        return
    end

    -- AGH 的 /control/status 不返回这三个开关的状态，直接读 YAML 才准确。
    local fconfig = cfg("config", "/etc/AdGuardHome.yaml")
    local safesearch = yaml_safe_search_enabled(fconfig)
    local parental = (yaml_section_scalar(fconfig, "filtering", "parental_enabled") or "") == "true"
    local safebrowsing = (yaml_section_scalar(fconfig, "filtering", "safebrowsing_enabled") or "") == "true"

    -- AdGuard Home 把黑名单和白名单分成两个数组，这里合并返回并标记来源，
    -- 否则白名单订阅在插件里既看不到也删不掉。
    local filters = {}
    for _, f in ipairs(data.filters or {}) do
        if type(f) == "table" then
            f.whitelist = false
            filters[#filters + 1] = f
        end
    end
    for _, f in ipairs(data.whitelist_filters or {}) do
        if type(f) == "table" then
            f.whitelist = true
            filters[#filters + 1] = f
        end
    end

    http.write_json({
        ok = true,
        -- AGH 返回的字段名是 enabled，不是 filtering_enabled
        filtering_enabled = (data.enabled == true) or (data.filtering_enabled == true),
        filters = filters,
        user_rules = data.user_rules or {},
        preset_source = preset_source(cfg),
        safesearch = safesearch,
        parental = parental,
        safebrowsing = safebrowsing
    })
end

function M.filters_save(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    if not require_post() then
        return
    end

    local act = http.formvalue("action") or ""
    local okc, jsonc = pcall(require, "luci.jsonc")
    if not okc then
        json_error("缺少 luci-lib-jsonc，无法操作过滤规则。", nil, "rules_not_supported")
        return
    end

    local path, body
    if act == "add" then
        local url = (http.formvalue("url") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local name = (http.formvalue("name") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local whitelist = http.formvalue("whitelist") == "1"
        if url == "" then
            json_error("请填写订阅地址。", nil, "invalid_rule_source")
            return
        end
        -- AdGuard Home 只接受 http(s) 订阅地址，file:// 会在它那边报错
        if not url:match("^https?://%S+$") then
            json_error("订阅地址需以 http:// 或 https:// 开头。", nil, "invalid_rule_source")
            return
        end
        if name == "" then
            name = url
        end
        path = "/control/filtering/add_url"
        body = jsonc.stringify({ name = name, url = url, whitelist = whitelist })
    elseif act == "toggle" then
        local url = http.formvalue("url") or ""
        local name = http.formvalue("name") or url
        local enabled = http.formvalue("enabled") == "1"
        local whitelist = http.formvalue("whitelist") == "1"
        if url == "" then
            json_error("缺少规则地址。", nil, "invalid_rule_source")
            return
        end
        path = "/control/filtering/set_url"
        body = jsonc.stringify({
            url = url,
            whitelist = whitelist,
            data = { name = name, url = url, enabled = enabled, whitelist = whitelist }
        })
    elseif act == "remove" then
        local url = http.formvalue("url") or ""
        local whitelist = http.formvalue("whitelist") == "1"
        if url == "" then
            json_error("缺少规则地址。", nil, "invalid_rule_source")
            return
        end
        path = "/control/filtering/remove_url"
        body = jsonc.stringify({ url = url, whitelist = whitelist })
    elseif act == "rules" then
        local raw = http.formvalue("rules") or ""
        local rules = {}
        for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" then
                rules[#rules + 1] = line
            end
        end
        path = "/control/filtering/set_rules"
        body = jsonc.stringify({ rules = rules })
    elseif act == "preset_source" then
        -- 切换预置规则下载源：保存选择，并把已有的内置列表改到新源
        local src = http.formvalue("source") or ""
        if not PRESET_SOURCES[src] then
            json_error("不支持的下载源。", nil, "invalid_rule_source")
            return
        end
        uci:set(CONF, "main", "preset_source", src)
        uci:commit(CONF)

        local _, sresp = agh_api("/control/filtering/status", "GET")
        local st = jsonc.parse(sresp)
        if not st or type(st) ~= "table" then
            json_error("读取规则列表失败，请确认 AdGuard Home 正在运行。", nil, "rule_fetch_failed")
            return
        end

        local base = PRESET_SOURCES[src]
        local migrated, failed = 0, {}
        local function repoint(list, whitelist)
            for _, f in ipairs(list or {}) do
                local p = f.url and preset_path(f.url)
                if p and (base .. p) ~= f.url then
                    if agh_api("/control/filtering/set_url", "POST", jsonc.stringify({
                        url = f.url,
                        whitelist = whitelist,
                        data = {
                            name = f.name or p,
                            url = base .. p,
                            enabled = f.enabled ~= false,
                            whitelist = whitelist
                        }
                    })) == "200" then
                        migrated = migrated + 1
                    else
                        failed[#failed + 1] = p
                    end
                end
            end
        end
        repoint(st.filters, false)
        repoint(st.whitelist_filters, true)

        -- 切换源会立即重新下载列表，记入订阅更新日志
        local logfile = RUN .. "_filter.log"
        local hist = fs.readfile(logfile) or ""
        local stamp = os.date("%Y-%m-%d %H:%M:%S")
        local labels = { jsdelivr = "jsDelivr", github = "GitHub 直连", custom = "自建备用" }
        local line = string.format("%s 切换下载源为 %s：迁移 %d 个列表%s\n", stamp, labels[src], migrated,
            #failed > 0 and ("，失败 " .. #failed .. " 个") or "")
        local kept = {}
        for item in (hist .. "\n"):gmatch("([^\n]*)\n") do
            if item ~= "" then
                kept[#kept + 1] = item
            end
        end
        if #kept >= 100 then
            local trimmed = {}
            for i = #kept - 99, #kept do
                trimmed[#trimmed + 1] = kept[i]
            end
            kept = trimmed
        end
        fs.writefile(logfile, table.concat(kept, "\n") .. "\n" .. line)

        http.write_json({ ok = true, source = src, migrated = migrated, failed = failed })
        return
    elseif act == "trim" then
        -- 切换预置规则档位：写入目标档位的内置列表，移除其它档位的
        local tier = http.formvalue("tier") or "512"
        if not PRESET_TIERS[tier] then
            json_error("不支持的档位。", nil, "rule_action_failed")
            return
        end

        local _, sresp = agh_api("/control/filtering/status", "GET")
        local st = jsonc.parse(sresp)
        -- AGH 在没有黑名单订阅时返回 "filters": null，不能当成接口失败
        if not st or type(st) ~= "table" then
            json_error("读取规则列表失败，请确认 AdGuard Home 正在运行。", nil, "rule_fetch_failed")
            return
        end

        local existing, existing_white, preset_existing = {}, {}, {}
        for _, f in ipairs(st.filters or {}) do
            if f.url then
                existing[f.url] = f
                local path = preset_path(f.url)
                if path and not preset_existing[path] then
                    preset_existing[path] = f.url
                end
            end
        end
        for _, f in ipairs(st.whitelist_filters or {}) do
            if f.url then
                existing_white[f.url] = f
            end
        end

        -- 优先用当前选定的下载源，失败后按顺序换其它源；反代只作用于 GitHub 直连地址
        local function add_preset(name, path, whitelist)
            local primary = preset_source(cfg)
            local urls = { PRESET_SOURCES[primary] .. path }
            for _, key in ipairs(PRESET_SOURCE_ORDER) do
                if key ~= primary then
                    urls[#urls + 1] = PRESET_SOURCES[key] .. path
                end
            end
            local proxy = tostring(cfg("github_proxy", "gh-proxy.org") or "")
                :gsub("^%s+", ""):gsub("%s+$", ""):gsub("^https?://", ""):gsub("/+$", "")
            local proxies = {}
            if proxy ~= "" then
                proxies[#proxies + 1] = proxy
            end
            if proxy ~= "ghfast.top" then
                proxies[#proxies + 1] = "ghfast.top"
            end
            for _, m in ipairs(proxies) do
                urls[#urls + 1] = "https://" .. m .. "/" .. PRESET_SOURCES.github .. path
            end

            for _, url in ipairs(urls) do
                if agh_api("/control/filtering/add_url", "POST", jsonc.stringify({
                    name = name,
                    url = url,
                    whitelist = whitelist
                })) == "200" then
                    return true, url
                end
            end
            return false
        end

        local want, changed, failed = {}, 0, {}
        for _, cat in ipairs(PRESET_TIERS[tier]) do
            want[tier .. "/" .. cat .. ".txt"] = PRESET_NAMES[cat]
        end

        -- 先移除其它档位以及已下线分类的内置列表，避免重复或残留；
        -- 不能遍历分类表，否则从分类表里删掉的旧分类（如 social）会残留。
        for url in pairs(existing) do
            local path = preset_path(url)
            -- 同一列表同时存在直连与反代地址时，只保留一个
            local duplicated = path and want[path] and preset_existing[path] ~= url
            if path then
                local tier_of = path:match("^(%d+)/")
                if (tier_of and PRESET_TIERS[tier_of] and not want[path]) or duplicated then
                    if agh_api("/control/filtering/remove_url", "POST", jsonc.stringify({
                        url = url,
                        whitelist = false
                    })) == "200" then
                        changed = changed + 1
                    end
                end
            end
        end

        -- 清理旧版模板内置的第三方整包订阅，用户自行添加的订阅不匹配特征串，保持不动
        for url in pairs(existing) do
            if not preset_path(url) and matches_any(url, LEGACY_PATTERNS) then
                if agh_api("/control/filtering/remove_url", "POST", jsonc.stringify({
                    url = url,
                    whitelist = false
                })) == "200" then
                    changed = changed + 1
                end
            end
        end
        for url in pairs(existing_white) do
            if url:find(LEGACY_WHITELIST, 1, true) then
                if agh_api("/control/filtering/remove_url", "POST", jsonc.stringify({
                    url = url,
                    whitelist = true
                })) == "200" then
                    changed = changed + 1
                end
            end
        end

        local kept = 0
        for path, name in pairs(want) do
            local url = preset_existing[path]
            if not url then
                if add_preset(name, path, false) then
                    changed = changed + 1
                else
                    failed[#failed + 1] = path
                end
            else
                local f = existing[url]
                if f and not f.enabled then
                    if agh_api("/control/filtering/set_url", "POST", jsonc.stringify({
                        url = url,
                        whitelist = false,
                        data = { name = name, url = url, enabled = true, whitelist = false }
                    })) == "200" then
                        changed = changed + 1
                    end
                end
                kept = kept + 1
            end
        end

        -- 白名单与档位无关，缺失时补上；AGH 新增订阅默认启用，这里按旧版惯例保持关闭
        local has_allow = false
        for url in pairs(existing_white) do
            if preset_path(url) == "allowlist.txt" then
                has_allow = true
            end
        end
        if not has_allow then
            local added, added_url = add_preset("AGH 白名单", "allowlist.txt", true)
            if added then
                agh_api("/control/filtering/set_url", "POST", jsonc.stringify({
                    url = added_url,
                    whitelist = true,
                    data = { name = "AGH 白名单", url = added_url, enabled = false, whitelist = true }
                }))
                changed = changed + 1
            end
        end

        if #failed > 0 then
            json_error(string.format(
                "规则列表添加失败：%s。请检查路由器能否访问 GitHub / jsDelivr，或在插件配置中更换 GitHub 反代。",
                failed[1]), nil, "rule_action_failed")
            return
        end

        http.header("Cache-Control", "no-store")
        http.prepare_content("application/json")
        http.write_json({ ok = true, tier = tier, changed = changed, kept = kept })
        return
    elseif act == "feature" then
        local feature = http.formvalue("feature") or ""
        local value = http.formvalue("value") == "1"
        local allowed = { filtering = true, safesearch = true, parental = true, safebrowsing = true }
        if not allowed[feature] then
            json_error("不支持的开关。", nil, "rule_toggle_failed")
            return
        end

        -- 家长控制依赖 AdGuard 服务端在线判定，连不上时开启会直接断网，
        -- 所以开启前强制试拨一次，不通就拒绝（关闭无需探测）。
        if feature == "parental" and value then
            parental_service.invalidate(sys, RUN)
            if not parental_service.reachable(sys, fs, RUN, 0, 5) then
                json_error("无法连接 AdGuard 家长控制服务（family.adguard-dns.com），开启后会导致全屋无法上网。请先启用代理再试。",
                    nil, "parental_service_unreachable")
                return
            end
        end

        if feature == "filtering" then
            -- filtering 没有单独的 enable/disable，走 config 接口
            local _, sresp = agh_api("/control/filtering/status", "GET")
            local st = jsonc.parse(sresp)
            local interval = st and tonumber(st.interval) or 24
            path = "/control/filtering/config"
            body = jsonc.stringify({ enabled = value, interval = interval })
        elseif feature == "safesearch" then
            -- 安全搜索：v1.0.0 移除了 /control/safesearch/enable|disable，
            -- 改用 v0.107.53 起就存在的 /control/safesearch/settings（新旧内核都支持）。
            -- 先读完整配置再只改 enabled，保留各搜索引擎的单独设置。
            local gcode, gresp = agh_api("/control/safesearch/status", "GET")
            local sc
            if gcode == "200" then
                local okp, parsed = pcall(jsonc.parse, gresp or "")
                if okp and type(parsed) == "table" then
                    sc = parsed
                end
            end
            if sc then
                sc.enabled = value
                local pcode = agh_api("/control/safesearch/settings", "PUT", jsonc.stringify(sc))
                if pcode == "200" then
                    http.header("Cache-Control", "no-store")
                    http.prepare_content("application/json")
                    http.write_json({ ok = true })
                    return
                end
            end
            -- 更老的内核没有 settings 接口时退回旧写法
            path = "/control/safesearch/" .. (value and "enable" or "disable")
        else
            path = string.format("/control/%s/%s", feature, value and "enable" or "disable")
        end
    else
        json_error("不支持的操作。", nil, "rule_action_failed")
        return
    end

    local code, resp = agh_api(path, "POST", body)
    if code ~= "200" then
        local detail = tostring(resp or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if #detail > 120 then
            detail = detail:sub(1, 120) .. "..."
        end
        if detail == "" then
            json_error("操作失败，AdGuard Home 可能未运行。", nil, "rule_action_failed")
        else
            json_error("操作失败：" .. detail, nil, "rule_action_failed")
        end
        return
    end

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

local function url_quote(value)
    return (tostring(value or ""):gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- 查询日志：支持筛选、搜索、分页，并补充命中规则和客户端主机名
function M.querylog_get(ctx)
    local fs, http = ctx.fs, ctx.http
    local agh_api = ctx.agh_api

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")

    local limit = tonumber(http.formvalue("limit") or "50") or 50
    if limit < 1 then
        limit = 50
    elseif limit > 500 then
        limit = 500
    end

    local status = (http.formvalue("status") or ""):lower()
    if status ~= "blocked" and status ~= "allowed" then
        status = ""
    end

    local search = (http.formvalue("search") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local older = (http.formvalue("older_than") or ""):gsub("%s+", "")

    local path = "/control/querylog?limit=" .. limit
    if status == "blocked" then
        path = path .. "&response_status=blocked"
    elseif status == "allowed" then
        -- AGH 把未过滤的放行查询标记为 processed
        path = path .. "&response_status=processed"
    end
    if search ~= "" then
        path = path .. "&search=" .. url_quote(search)
    end
    if older ~= "" then
        path = path .. "&older_than=" .. url_quote(older)
    end

    local code, resp = agh_api(path, "GET")
    if code ~= "200" then
        http.write_json({ ok = false, error = "读取查询日志失败，请确认 AdGuard Home 正在运行。" })
        return
    end

    local okc, jsonc = pcall(require, "luci.jsonc")
    local data = okc and jsonc.parse(resp) or nil
    if not data or type(data.data) ~= "table" then
        http.write_json({ ok = false, error = "查询日志返回格式异常。" })
        return
    end

    -- 订阅 id -> 名称，让每条记录能看出被哪份规则拦下
    local filter_names = {}
    local fcode, fresp = agh_api("/control/filtering/status", "GET")
    if fcode == "200" then
        local fdata = okc and jsonc.parse(fresp or "") or nil
        for _, f in ipairs((fdata and fdata.filters) or {}) do
            if f.id and f.name then
                filter_names[tostring(f.id)] = f.name
            end
        end
    end

    -- DHCP 租约：把客户端 IP 补成主机名
    local lease_names = {}
    local leases = fs.readfile("/tmp/dhcp.leases") or ""
    for line in leases:gmatch("[^\n]+") do
        local ip, name = line:match("^%d+%s+%S+%s+(%d+%.%d+%.%d+%.%d+)%s+(%S+)")
        if ip and name and name ~= "*" then
            lease_names[ip] = name
        end
    end

    local items = {}
    for _, e in ipairs(data.data) do
        local q = e.question or {}
        local first = q[1] or q
        local client = e.client or ""
        local client_name = ""
        if e.client_info and e.client_info.name and e.client_info.name ~= "" then
            client_name = e.client_info.name
        elseif lease_names[client] then
            client_name = lease_names[client]
        end

        local rule_text, rule_list = "", ""
        if type(e.rules) == "table" and e.rules[1] then
            rule_text = tostring(e.rules[1].text or "")
            local fid = e.rules[1].filter_list_id
            if fid then
                rule_list = filter_names[tostring(fid)] or ""
            end
        end

        local reason = e.reason or ""
        -- 只有 Filtered* 才是拦截；NotFiltered* 和 Rewritten 都是放行。
        local blocked = (reason:find("^Filtered") ~= nil and reason:find("WhiteList") == nil)
            or reason:find("^Blocked") ~= nil

        items[#items + 1] = {
            time = e.time or "",
            client = client,
            client_name = client_name,
            domain = first.name or "",
            qtype = first.type or "",
            status = e.status or (e.result and e.result.status) or "",
            blocked = blocked,
            reason = reason,
            upstream = e.upstream or "",
            rule = rule_text,
            filter_name = rule_list,
            elapsed_ms = e.elapsedMs or ""
        }
    end

    http.write_json({
        ok = true,
        data = items,
        more = #items >= limit,
        cursor = (items[#items] and items[#items].time) or ""
    })
end

function M.retention_save(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    if not require_post() then
        return
    end

    local days = tonumber(http.formvalue("days") or "30")
    local query_days = tonumber(http.formvalue("query_days") or "30")
    if not days or days ~= math.floor(days) or days < 1 or days > 3650 then
        json_error("统计保留天数必须是 1-3650 之间的整数。", nil, "invalid_retention")
        return
    end
    if not query_days or query_days ~= math.floor(query_days) or query_days < 1 or query_days > 3650 then
        json_error("查询日志保留天数必须是 1-3650 之间的整数。", nil, "invalid_retention")
        return
    end

    local configpath = cfg("config", "/etc/AdGuardHome.yaml")
    if not fs.access(configpath) then
        json_error("尚未生成 AdGuard Home 配置文件。", nil, "config_missing")
        return
    end

    if not yaml_set_section_scalar(configpath, "statistics", "interval", days .. "d")
        or not yaml_set_section_scalar(configpath, "querylog", "interval", query_days .. "d") then
        json_error("写入保留周期失败。", nil, "retention_save_failed")
        return
    end

    start_action("sh " .. SHARE .. "/apply_settings.sh")
    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

return M
