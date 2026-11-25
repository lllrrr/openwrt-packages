-- AdGuard Home 管理中心 - logs 动作
-- 依赖由控制器通过 ctx 注入，保持原有行为不变。

local M = {}

function M.logs(ctx)
    local fs, http, sys, uci, util, codes, agh, selftest, split_words, join_words, valid_iface_name, valid_client_spec, version_newer, clean_tag, CONF, SHARE, RUN, STATS_CACHE, VERSION_CACHE, CORE_UPDATE, PLUGIN_UPDATE, INSTALL_VERSION, RELEASE_URL, collect_stats, read_cache, cfg, CACHE_YAML_KEYS, yaml_cache_scalar, yaml_list_values, yaml_safe_search_enabled, yaml_section_scalar, yaml_set_section_scalar, cache_option, IGNORED_IFACE_PATTERNS, iface_ignored, net_devices, is_enabled, core_version, core_update_info, plugin_version, plugin_update_info, service_running, openclash_hijack_port, openclash_running, openclash_upstream_agh, passwall_enabled, passwall_dns_port, read_number, update_running, action_running, start_action, check_token, require_post, default_reason, json_error, state_value, agh_client, agh_request, agh_api, interval_days = ctx.fs, ctx.http, ctx.sys, ctx.uci, ctx.util, ctx.codes, ctx.agh, ctx.selftest, ctx.split_words, ctx.join_words, ctx.valid_iface_name, ctx.valid_client_spec, ctx.version_newer, ctx.clean_tag, ctx.CONF, ctx.SHARE, ctx.RUN, ctx.STATS_CACHE, ctx.VERSION_CACHE, ctx.CORE_UPDATE, ctx.PLUGIN_UPDATE, ctx.INSTALL_VERSION, ctx.RELEASE_URL, ctx.collect_stats, ctx.read_cache, ctx.cfg, ctx.CACHE_YAML_KEYS, ctx.yaml_cache_scalar, ctx.yaml_list_values, ctx.yaml_safe_search_enabled, ctx.yaml_section_scalar, ctx.yaml_set_section_scalar, ctx.cache_option, ctx.IGNORED_IFACE_PATTERNS, ctx.iface_ignored, ctx.net_devices, ctx.is_enabled, ctx.core_version, ctx.core_update_info, ctx.plugin_version, ctx.plugin_update_info, ctx.service_running, ctx.openclash_hijack_port, ctx.openclash_running, ctx.openclash_upstream_agh, ctx.passwall_enabled, ctx.passwall_dns_port, ctx.read_number, ctx.update_running, ctx.action_running, ctx.start_action, ctx.check_token, ctx.require_post, ctx.default_reason, ctx.json_error, ctx.state_value, ctx.agh_client, ctx.agh_request, ctx.agh_api, ctx.interval_days
    local level = (http.formvalue("level") or ""):lower()
    local syslog = sys.exec("logread 2>/dev/null | grep -i 'adguard' | tail -n 300") or ""
    local update = fs.readfile(RUN .. "_update.log") or ""
    local action = fs.readfile(RUN .. "_action.log") or ""
    local filter = fs.readfile(RUN .. "_filter.log") or ""

    if level == "error" or level == "warn" or level == "info" then
        local tag = "[" .. level:upper() .. "]"
        local filtered = {}
        for line in (syslog .. "\n"):gmatch("([^\n]*)\n") do
            if line:find(tag, 1, true) then
                filtered[#filtered + 1] = line
            end
        end
        syslog = table.concat(filtered, "\n")
        if syslog ~= "" then
            syslog = syslog .. "\n"
        end
    end

    http.header("Cache-Control", "no-store")
    http.prepare_content("text/plain; charset=utf-8")
    http.write("===== 持久化状态（重启后保留） =====\n")
    http.write("上次应用：" .. (state_value("last_apply") ~= "" and state_value("last_apply") or "无记录") .. "\n")
    http.write("上次更新：" .. (state_value("last_update") ~= "" and state_value("last_update") or "无记录") .. "\n")
    http.write("上次 DNS 回退：" .. (state_value("last_fallback") ~= "" and state_value("last_fallback") or "无记录") .. "\n")
    http.write("\n===== 系统日志（包含 AdGuard 关键字，最近 300 行"
        .. (level ~= "" and ("，筛选 " .. level:upper()) or "") .. "） =====\n")
    http.write(syslog)
    http.write("\n\n===== 内核安装/更新日志 =====\n")
    http.write(update)
    http.write("\n\n===== 最近一次服务操作日志 =====\n")
    http.write(action)
    http.write("\n\n===== 订阅更新日志（最近 100 次） =====\n")
    http.write(filter)
end

return M
