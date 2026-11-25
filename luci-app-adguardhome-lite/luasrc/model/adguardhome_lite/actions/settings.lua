-- AdGuard Home 管理中心 - settings 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}
local tasks = require "luci.model.adguardhome_lite.tasks"

function M.settings_get(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    local binpath = cfg("binpath", "/usr/bin/AdGuardHome/AdGuardHome")
    local configpath = cfg("config", "/etc/AdGuardHome.yaml")
    local mode = cfg("dns_mode", "takeover")
    if mode == "openclash" then
        mode = "takeover"
    end

    local cache_enabled = cache_option(configpath, "cache_enabled", "1")
    local cache_size_mb = tonumber(cache_option(configpath, "cache_size_mb", "16")) or 16
    local cache_ttl_min = tonumber(cache_option(configpath, "cache_ttl_min", "0")) or 0
    local cache_ttl_max = tonumber(cache_option(configpath, "cache_ttl_max", "0")) or 0
    local cache_optimistic = cache_option(configpath, "cache_optimistic", "0")

    local dns_crypto = cfg("dns_crypto", "off")
    local dns_crypto_custom = cfg("dns_crypto_custom", "")

    -- 加密预设只在「Clash 前置」且上游由插件管理时才会写入；
    -- 用户自定义上游时给界面提示，避免以为已经生效。
    local crypto_blocked = false
    if dns_crypto ~= "off" and dns_crypto ~= "" and mode == "clashfirst" then
        if cfg("upstream_source", "auto") == "custom" then
            crypto_blocked = true
        else
            local cur_up = yaml_list_values(configpath, "upstream_dns")
            local auto_up = uci:get(CONF, "main", "auto_upstream") or ""
            local self_ip = uci:get("network", "lan", "ipaddr") or ""
            local clash_port = cfg("clash_dns_port", "7874")
            local managed = false

            if auto_up ~= "" and cur_up == auto_up then
                managed = true
            end

            local known = {
                "",
                "127.0.0.1",
                "127.0.0.1:53",
                "127.0.0.1:1745",
                "127.0.0.1:5335",
                "127.0.0.1:" .. clash_port,
                "223.5.5.5 119.29.29.29"
            }
            for _, v in ipairs(known) do
                if cur_up == v then
                    managed = true
                    break
                end
            end
            if self_ip ~= "" and cur_up == self_ip then
                managed = true
            end
            -- PassWall 的 DNS 端口动态变化，按端口段识别插件写入的上游
            if not managed and cur_up:match("^127%.0%.0%.1:114%d%d$") then
                managed = true
            end

            crypto_blocked = not managed
        end
    end

    local upstream_source = cfg("upstream_source", "auto")
    if upstream_source ~= "custom" then
        upstream_source = "auto"
    end
    local upstream_custom = cfg("upstream_custom", "")
    local upstream_current = yaml_list_values(configpath, "upstream_dns")
    local stats_retention_days = interval_days(yaml_section_scalar(configpath, "statistics", "interval"), 30)
    local querylog_retention_days = interval_days(yaml_section_scalar(configpath, "querylog", "interval"), 30)

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json({
        ok = true,
        enabled = is_enabled(),
        dns_mode = mode,
        webport = tonumber(cfg("webport", "13800")) or 13800,
        binpath = binpath,
        workdir = cfg("workdir", "/etc/AdGuardHome"),
        channel = cfg("channel", "stable"),
        github_proxy = cfg("github_proxy", "gh-proxy.org"),
        cache_enabled = cache_enabled == "1",
        cache_size_mb = cache_size_mb,
        cache_ttl_min = cache_ttl_min,
        cache_ttl_max = cache_ttl_max,
        cache_optimistic = cache_optimistic == "1",
        dns_crypto = dns_crypto,
        dns_crypto_custom = dns_crypto_custom,
        crypto_blocked = crypto_blocked,
        upstream_source = upstream_source,
        upstream_custom = upstream_custom,
        upstream_current = upstream_current,
        stats_retention_days = stats_retention_days,
        querylog_retention_days = querylog_retention_days,
        bypass_ifaces = join_words(uci:get(CONF, "main", "bypass_ifaces")),
        bypass_clients = join_words(uci:get(CONF, "main", "bypass_clients")),
        devices = net_devices(),
        openclash_installed = uci:get("openclash", "config") ~= nil,
        passwall_installed = uci:get("passwall2", "@global[0]", "enabled") ~= nil
            or uci:get("passwall", "@global[0]", "enabled") ~= nil,
        passwall_enabled = passwall_enabled(),
        passwall_dns_port = passwall_dns_port(),
        admin_user = cfg("adminuser", "admin"),
        admin_pass = cfg("adminpass", "admin123"),
        config_path = configpath,
        core = fs.access(binpath, "x") and true or false,
        version = core_version(binpath),
        running = service_running(binpath)
    })
end

function M.settings_save(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    if not require_post() then
        return
    end
    if update_running() then
        json_error("内核正在安装或更新，请等待完成后再保存设置。", 409, "update_busy")
        return
    end
    if tasks.plugin_running(fs, RUN) then
        json_error("插件正在更新，请等待完成后再保存设置。", 409, "plugin_update_busy")
        return
    end

    local enabled = http.formvalue("enabled") or "0"
    local mode = http.formvalue("dns_mode") or "takeover"
    local webport = http.formvalue("webport") or "13800"
    local binpath = http.formvalue("binpath") or "/usr/bin/AdGuardHome/AdGuardHome"
    local workdir = http.formvalue("workdir") or "/etc/AdGuardHome"
    local channel = http.formvalue("channel") or "stable"
    local proxy = http.formvalue("github_proxy") or "gh-proxy.org"
    local cache_enabled = http.formvalue("cache_enabled") or "1"
    local cache_size_raw = http.formvalue("cache_size_mb") or "16"
    local cache_ttl_min_raw = http.formvalue("cache_ttl_min") or "0"
    local cache_ttl_max_raw = http.formvalue("cache_ttl_max") or "0"
    local cache_optimistic = http.formvalue("cache_optimistic") or "0"
    local dns_crypto = http.formvalue("dns_crypto") or "off"
    local dns_crypto_custom = http.formvalue("dns_crypto_custom") or ""
    dns_crypto_custom = dns_crypto_custom:gsub("^%s+", ""):gsub("%s+$", "")
    local bypass_ifaces_raw = http.formvalue("bypass_ifaces") or ""
    local bypass_clients_raw = http.formvalue("bypass_clients") or ""

    if cache_enabled ~= "0" and cache_enabled ~= "1" then
        json_error("DNS 缓存开关参数不正确。", nil, "invalid_cache_toggle")
        return
    end
    if cache_optimistic ~= "0" and cache_optimistic ~= "1" then
        json_error("乐观缓存参数不正确。", nil, "invalid_cache_toggle")
        return
    end

    local cache_size_mb = tonumber(cache_size_raw)
    if not cache_size_mb or cache_size_mb ~= math.floor(cache_size_mb) or cache_size_mb < 1 or cache_size_mb > 256 then
        json_error("缓存大小必须是 1-256MB 之间的整数。", nil, "invalid_cache_size")
        return
    end

    local cache_ttl_min = tonumber(cache_ttl_min_raw)
    local cache_ttl_max = tonumber(cache_ttl_max_raw)
    if not cache_ttl_min or cache_ttl_min ~= math.floor(cache_ttl_min) or cache_ttl_min < 0 or cache_ttl_min > 604800 then
        json_error("最小 TTL 必须是 0-604800 秒之间的整数。", nil, "invalid_cache_ttl")
        return
    end
    if not cache_ttl_max or cache_ttl_max ~= math.floor(cache_ttl_max) or cache_ttl_max < 0 or cache_ttl_max > 604800 then
        json_error("最大 TTL 必须是 0-604800 秒之间的整数。", nil, "invalid_cache_ttl")
        return
    end
    if cache_ttl_max > 0 and cache_ttl_min > cache_ttl_max then
        json_error("最小 TTL 不能大于最大 TTL；最大 TTL 为 0 表示不限制。", nil, "invalid_cache_ttl_range")
        return
    end
    if cache_enabled == "0" then
        cache_optimistic = "0"
    end

    local allowed_crypto = {
        off = true, alidns = true, dnspod = true, cloudflare = true, custom = true
    }
    if not allowed_crypto[dns_crypto] then
        json_error("加密上游参数不正确。", nil, "invalid_crypto")
        return
    end
    if dns_crypto == "custom" then
        if dns_crypto_custom == "" then
            json_error("请填写自定义加密上游地址。", nil, "invalid_crypto_custom")
            return
        end
        local valid_scheme = dns_crypto_custom:match("^https://%S+$")
            or dns_crypto_custom:match("^tls://%S+$")
            or dns_crypto_custom:match("^quic://%S+$")
            or dns_crypto_custom:match("^sdns://%S+$")
        if not valid_scheme then
            json_error("自定义加密上游需以 https://、tls://、quic:// 或 sdns:// 开头，且不能包含空格。", nil, "invalid_crypto_custom")
            return
        end
    end

    if enabled ~= "0" and enabled ~= "1" then
        json_error("启用状态参数不正确。", nil, "invalid_enabled")
        return
    end

    local allowed_modes = {
        takeover = true, upstream = true, none = true, clashfirst = true, passwall = true
    }
    local allowed_bins = {
        ["/usr/bin/AdGuardHome/AdGuardHome"] = true,
        ["/tmp/AdGuardHome/AdGuardHome"] = true
    }
    local allowed_works = {
        ["/etc/AdGuardHome"] = true,
        ["/tmp/AdGuardHome"] = true
    }
    local allowed_channels = { stable = true, beta = true, legacy = true }
    local allowed_proxies = {
        none = true, ["gh-proxy.org"] = true, ["ghproxy.cc"] = true,
        ["ghproxy.com"] = true, ["ghfast.top"] = true
    }

    if not allowed_modes[mode] then
        json_error("DNS 接管方式不正确。", nil, "invalid_dns_mode")
        return
    end
    if not allowed_bins[binpath] then
        json_error("内核安装位置不正确。", nil, "invalid_binpath")
        return
    end
    if not allowed_works[workdir] then
        json_error("工作目录不正确。", nil, "invalid_workdir")
        return
    end
    if not allowed_channels[channel] then
        json_error("更新通道不正确。", nil, "invalid_channel")
        return
    end
    if not allowed_proxies[proxy] then
        json_error("GitHub 反代选项不正确。", nil, "invalid_proxy")
        return
    end

    local upstream_source = http.formvalue("upstream_source") or "auto"
    local upstream_custom = http.formvalue("upstream_custom") or ""
    upstream_custom = upstream_custom:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    if upstream_source ~= "auto" and upstream_source ~= "custom" then
        json_error("上游 DNS 来源参数不正确。", nil, "invalid_upstream_source")
        return
    end
    if upstream_source == "custom" then
        if upstream_custom == "" then
            json_error("请填写自定义上游 DNS，或把来源改回「自动」。", nil, "invalid_upstream_custom")
            return
        end
        if #upstream_custom > 1024 then
            json_error("自定义上游 DNS 过长，请精简后再保存。", nil, "invalid_upstream_too_long")
            return
        end
        for item in upstream_custom:gmatch("%S+") do
            local addr = item:gsub("^%[[^%]]*%]", "")
            local valid = addr:match("^https://%S+$")
                or addr:match("^tls://%S+$")
                or addr:match("^quic://%S+$")
                or addr:match("^sdns://%S+$")
                or addr:match("^[%w%._:%-]+$")
            if not valid then
                json_error("上游 DNS 格式不正确：" .. item, nil, "invalid_upstream_format")
                return
            end
        end
    end

    local ifaces, iface_seen = {}, {}
    for _, name in ipairs(split_words(bypass_ifaces_raw)) do
        if name == "lo" then
            json_error("不能把 lo（回环接口）设为排除接口。", nil, "invalid_bypass_iface")
            return
        end
        if not valid_iface_name(name) then
            json_error("接口名不合法：" .. name .. "（仅支持字母、数字、下划线、点和短横线，最长 15 字符）。", nil, "invalid_bypass_iface")
            return
        end
        if not iface_seen[name] then
            iface_seen[name] = true
            ifaces[#ifaces + 1] = name
        end
    end

    local clients, client_seen = {}, {}
    for _, spec in ipairs(split_words(bypass_clients_raw)) do
        if not valid_client_spec(spec) then
            json_error("客户端地址不合法：" .. spec .. "（支持 IPv4 / IPv6 地址或 CIDR）。", nil, "invalid_bypass_client")
            return
        end
        if not client_seen[spec] then
            client_seen[spec] = true
            clients[#clients + 1] = spec
        end
    end

    if #ifaces > 32 or #clients > 64 then
        json_error("排除项过多，接口最多 32 个、客户端最多 64 个。", nil, "invalid_bypass_limit")
        return
    end

    local port = tonumber(webport)
    if not port or port ~= math.floor(port) or port < 1 or port > 65535 then
        json_error("管理面板端口必须是 1-65535 之间的整数。", nil, "invalid_webport")
        return
    end
    if port == 53 or port == 1745 or port == 5333 or port == 5335 then
        json_error("管理面板端口不能使用 53、1745、5333 或 5335。", nil, "invalid_webport")
        return
    end

    if enabled == "1" and not fs.access(binpath, "x") then
        json_error("所选位置尚未安装内核，请先到概览页安装内核。", nil, "core_not_installed")
        return
    end

    local prev_channel = uci:get(CONF, "main", "channel") or ""
    uci:set(CONF, "main", "enabled", enabled)
    uci:set(CONF, "main", "dns_mode", mode)
    uci:set(CONF, "main", "webport", tostring(port))
    uci:set(CONF, "main", "binpath", binpath)
    uci:set(CONF, "main", "workdir", workdir)
    uci:set(CONF, "main", "channel", channel)
    uci:set(CONF, "main", "github_proxy", proxy)
    uci:set(CONF, "main", "upstream_source", upstream_source)
    uci:set(CONF, "main", "upstream_custom", upstream_custom)
    uci:set(CONF, "main", "cache_enabled", cache_enabled)
    uci:set(CONF, "main", "cache_size_mb", tostring(cache_size_mb))
    uci:set(CONF, "main", "cache_ttl_min", tostring(cache_ttl_min))
    uci:set(CONF, "main", "cache_ttl_max", tostring(cache_ttl_max))
    uci:set(CONF, "main", "cache_optimistic", cache_optimistic)
    uci:set(CONF, "main", "dns_crypto", dns_crypto)
    uci:set(CONF, "main", "dns_crypto_custom", dns_crypto_custom)
    -- 24.10 / 25.12 的 Lua 兼容层没有 add_list，统一用 set_list（空表即删除）
    uci:set_list(CONF, "main", "bypass_ifaces", ifaces)
    uci:set_list(CONF, "main", "bypass_clients", clients)
    uci:commit(CONF)

    -- 切换通道后旧缓存里的版本属于另一条通道，会造成「选了预览版却装正式版」，
    -- 立即失效并后台重查，让概览页尽快显示新通道的目标版本。
    if prev_channel ~= channel then
        fs.remove(CORE_UPDATE)
        sys.exec("sh " .. SHARE .. "/check_core_update.sh >/dev/null 2>&1 &")
    end

    -- 运行中优先通过 AdGuard Home API 在线应用缓存设置；失败则由 apply_settings.sh 回退到文件写入
    uci:delete(CONF, "main", "cache_api_applied")
    if service_running(binpath) then
        agh_client()
        local size_bytes = (cache_enabled == "1") and (cache_size_mb * 1024 * 1024) or 0
        local optimistic = (cache_enabled == "1" and cache_optimistic == "1")
        local ok = agh.patch_dns_config({
            cache_size = size_bytes,
            cache_ttl_min = cache_ttl_min,
            cache_ttl_max = cache_ttl_max,
            cache_optimistic = optimistic
        })
        if ok then
            local dns_conf = agh.get_dns_config()
            ok = dns_conf ~= nil and tonumber(dns_conf.cache_size) == size_bytes
        end
        if ok then
            uci:set(CONF, "main", "cache_api_applied", "1")
            uci:set(CONF, "main", "cache_applied", string.format(
                "%s|%s|%s|%s|%s",
                cache_enabled, cache_size_mb, cache_ttl_min, cache_ttl_max, cache_optimistic))
        end
    end
    uci:commit(CONF)

    start_action("sh " .. SHARE .. "/apply_settings.sh")

    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

function M.yaml_get(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    local configpath = cfg("config", "/etc/AdGuardHome.yaml")
    local yaml = fs.readfile(configpath) or ""

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json({
        ok = true,
        path = configpath,
        enabled = is_enabled(),
        running = service_running(cfg("binpath", "/usr/bin/AdGuardHome/AdGuardHome")),
        yaml = yaml
    })
end

function M.yaml_save(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    if not require_post() then
        return
    end

    if update_running() or action_running() or tasks.plugin_running(fs, RUN) then
        json_error("正在应用设置或执行安装/更新，请等待完成后再保存配置。", 409, "update_busy")
        return
    end

    local yaml = http.formvalue("yaml")
    if not yaml then
        json_error("未收到配置内容。", nil, "yaml_empty")
        return
    end
    if #yaml > 1048576 then
        json_error("配置文件过大，最大支持 1MB。", nil, "yaml_too_large")
        return
    end

    yaml = yaml:gsub("\r\n", "\n")
    local configpath = cfg("config", "/etc/AdGuardHome.yaml")
    local binpath = cfg("binpath", "/usr/bin/AdGuardHome/AdGuardHome")
    if not fs.access(binpath, "x") then
        json_error("尚未安装内核，无法校验配置。", nil, "core_not_installed")
        return
    end

    local tmp = "/tmp/adguardhome_lite_yaml_test.yaml"
    fs.writefile(tmp, yaml)
    local rc = sys.call(string.format("%q --check-config -c %q >/var/run/adguardhome_lite_yaml_check.log 2>&1", binpath, tmp))
    if rc ~= 0 then
        local err = fs.readfile("/var/run/adguardhome_lite_yaml_check.log") or "未知错误"
        if #err > 1000 then
            err = string.sub(err, -1000)
        end
        json_error("配置校验失败：\n" .. err, 422, "yaml_check_failed")
        return
    end

    local old = fs.readfile(configpath) or ""
    fs.writefile(configpath .. ".bak", old)
    if not fs.writefile(configpath, yaml) then
        json_error("写入配置文件失败。", nil, "yaml_write_failed")
        return
    end
    sys.call("chmod 600 " .. configpath .. " >/dev/null 2>&1")

    if is_enabled() then
        start_action("/etc/init.d/adguardhome_lite restart")
    end

    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

return M
