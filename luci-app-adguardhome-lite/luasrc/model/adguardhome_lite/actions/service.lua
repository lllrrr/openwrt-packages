-- AdGuard Home 管理中心 - service 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}
local tasks = require "luci.model.adguardhome_lite.tasks"

function M.service(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    if not require_post() then
        return
    end

    if update_running() then
        json_error("内核正在安装或更新，请稍候再操作服务。", 409, "update_busy")
        return
    end
    if tasks.plugin_running(fs, RUN) then
        json_error("插件正在更新，请稍候再操作服务。", 409, "plugin_update_busy")
        return
    end

    local act = http.formvalue("action") or ""
    local allowed = {
        start = true, stop = true, restart = true,
        enable = true, disable = true, bootstrap = true
    }
    if not allowed[act] then
        json_error("不支持的操作。", nil, "rule_action_failed")
        return
    end

    if act == "enable" or act == "bootstrap" or act == "start" then
        uci:set(CONF, "main", "enabled", "1")
        uci:commit(CONF)
        start_action("sh " .. SHARE .. "/apply_settings.sh")
    elseif act == "disable" or act == "stop" then
        uci:set(CONF, "main", "enabled", "0")
        uci:commit(CONF)
        start_action("sh " .. SHARE .. "/apply_settings.sh")
    elseif act == "restart" then
        start_action("/etc/init.d/adguardhome_lite restart")
    end

    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

function M.password(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    if not require_post() then
        return
    end

    if tasks.plugin_running(fs, RUN) then
        json_error("插件正在更新，请稍候再修改密码。", 409, "plugin_update_busy")
        return
    end

    local hash = http.formvalue("hash") or ""
    local password = http.formvalue("password") or ""

    if #password < 8 then
        json_error("新密码至少需要 8 个字符。", nil, "invalid_password")
        return
    end
    if password:match("%c") then
        json_error("新密码不能包含换行等控制字符。", nil, "invalid_password")
        return
    end
    if #hash < 50 or not hash:match("^%$2[aby]%$%d%d%$[%w%./]+$") then
        json_error("密码哈希格式不正确，请刷新页面后重试。", nil, "password_hash_invalid")
        return
    end
    if not fs.access(cfg("config", "/etc/AdGuardHome.yaml")) then
        json_error("配置文件尚未生成，请先启用服务。", nil, "service_not_enabled")
        return
    end

    local hashfile = RUN .. "_new_hash"
    local passfile = RUN .. "_new_pass"
    fs.writefile(hashfile, hash)
    fs.writefile(passfile, password)
    sys.call("chmod 600 " .. hashfile .. " " .. passfile .. " >/dev/null 2>&1")

    start_action("sh " .. SHARE .. "/set_password.sh")

    http.prepare_content("application/json")
    http.write_json({ ok = true })
end

function M.selftest(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    local binpath = cfg("binpath", "/usr/bin/AdGuardHome/AdGuardHome")
    local configpath = cfg("config", "/etc/AdGuardHome.yaml")
    local mode = cfg("dns_mode", "takeover")
    local webport = tonumber(cfg("webport", "13800")) or 13800

    -- 优先使用配置文件中实际写入的端口，避免「设置已改但尚未应用」时误报
    local dnsport = 5333
    if mode == "takeover" or mode == "passwall" or mode == "openclash" then
        dnsport = 53
    elseif mode == "clashfirst" then
        dnsport = 5335
    end
    local yaml_port_raw = (yaml_section_scalar(configpath, "dns", "port") or ""):gsub('"', "")
    local yaml_port = tonumber(yaml_port_raw)
    if yaml_port and yaml_port > 0 then
        dnsport = yaml_port
    end

    local result = selftest.run({
        binpath = binpath,
        configpath = configpath,
        webport = webport,
        dnsport = dnsport,
        running = service_running(binpath),
        version = core_version(binpath),
        mode = mode,
        mode_applied = cfg("mode_applied", "none")
    })

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json(result)
end

return M
