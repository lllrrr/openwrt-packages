-- AdGuard Home 管理中心 - legacy 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}

function M.legacy_scan(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    local out = sys.exec("sh " .. SHARE .. "/legacy_cleanup.sh scan 2>/dev/null") or ""
    out = out:match("({.*})") or ""

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    if out == "" then
        http.write('{"ok":false,"error":"扫描失败，请查看系统日志"}')
        return
    end
    http.write(out)
end

function M.legacy_clean(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    if not require_post() then
        return
    end

    local out = sys.exec("sh " .. SHARE .. "/legacy_cleanup.sh clean 2>/dev/null") or ""
    out = out:match("({.*})") or ""

    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    if out == "" then
        http.write('{"ok":false,"error":"清理失败，请查看系统日志"}')
        return
    end
    http.write(out)
end

return M
