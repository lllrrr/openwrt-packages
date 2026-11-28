-- AdGuard Home 管理中心 - LuCI 控制器
-- 只负责菜单注册与动作分发；运行环境、版本查新、锁与 HTTP 助手分别在
-- model/adguardhome_lite/{env,versions,proxy,runtime}.lua 中实现。

module("luci.controller.adguardhome_lite", package.seeall)

local runtime = require "luci.model.adguardhome_lite.runtime"

local dashboard_actions = require "luci.model.adguardhome_lite.actions.dashboard"
local core_actions = require "luci.model.adguardhome_lite.actions.core"
local plugin_actions = require "luci.model.adguardhome_lite.actions.plugin"
local service_actions = require "luci.model.adguardhome_lite.actions.service"
local settings_actions = require "luci.model.adguardhome_lite.actions.settings"
local rules_actions = require "luci.model.adguardhome_lite.actions.rules"
local logs_actions = require "luci.model.adguardhome_lite.actions.logs"
local legacy_actions = require "luci.model.adguardhome_lite.actions.legacy"
local session_actions = require "luci.model.adguardhome_lite.actions.session"

function index()
    local root = entry(
        { "admin", "services", "adguardhome_lite" },
        template("adguardhome_lite/wrapper"),
        translate("AdGuard Home Admin Center"),
        60
    )
    root.dependent = true
    root.acl_depends = { "luci-app-adguardhome-lite" }

    -- 右侧独立页面在 iframe 中渲染，彻底隔离 LuCI 主题样式
    entry({ "admin", "services", "adguardhome_lite", "frame" }, template("adguardhome_lite/panel")).leaf = true

    -- 独立管理页面的 JSON 接口（不出现在菜单中）
    entry({ "admin", "services", "adguardhome_lite", "status" }, call("action_status")).leaf = true
    -- 手机 App 登录后取得会话令牌，避免解析页面 HTML
    entry({ "admin", "services", "adguardhome_lite", "session" }, call("action_session")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "stats_clear" }, call("action_stats_clear")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "filters_get" }, call("action_filters_get")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "filters_save" }, call("action_filters_save")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "querylog_get" }, call("action_querylog_get")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "retention_save" }, call("action_retention_save")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "core_install" }, call("action_core_install")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "core_progress" }, call("action_core_progress")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "plugin_update" }, call("action_plugin_update")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "plugin_check" }, call("action_plugin_check")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "plugin_progress" }, call("action_plugin_progress")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "service" }, call("action_service")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "password" }, call("action_password")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "logs_raw" }, call("action_logs")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "settings_get" }, call("action_settings_get")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "settings_save" }, call("action_settings_save")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "yaml_get" }, call("action_yaml_get")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "yaml_save" }, call("action_yaml_save")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "legacy_scan" }, call("action_legacy_scan")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "legacy_clean" }, call("action_legacy_clean")).leaf = true
    entry({ "admin", "services", "adguardhome_lite", "selftest" }, call("action_selftest")).leaf = true
end

-- 每个动作独立组装上下文：动作之间互不共享可变状态
function action_status() return dashboard_actions.status(runtime.build_ctx()) end
function action_session() return session_actions.session(runtime.build_ctx()) end
function action_stats_clear() return dashboard_actions.stats_clear(runtime.build_ctx()) end
function action_core_install() return core_actions.core_install(runtime.build_ctx()) end
function action_core_progress() return core_actions.core_progress(runtime.build_ctx()) end
function action_plugin_update() return plugin_actions.plugin_update(runtime.build_ctx()) end
function action_plugin_check() return plugin_actions.plugin_check(runtime.build_ctx()) end
function action_plugin_progress() return plugin_actions.plugin_progress(runtime.build_ctx()) end
function action_service() return service_actions.service(runtime.build_ctx()) end
function action_password() return service_actions.password(runtime.build_ctx()) end
function action_selftest() return service_actions.selftest(runtime.build_ctx()) end
function action_settings_get() return settings_actions.settings_get(runtime.build_ctx()) end
function action_settings_save() return settings_actions.settings_save(runtime.build_ctx()) end
function action_yaml_get() return settings_actions.yaml_get(runtime.build_ctx()) end
function action_yaml_save() return settings_actions.yaml_save(runtime.build_ctx()) end
function action_filters_get() return rules_actions.filters_get(runtime.build_ctx()) end
function action_filters_save() return rules_actions.filters_save(runtime.build_ctx()) end
function action_querylog_get() return rules_actions.querylog_get(runtime.build_ctx()) end
function action_retention_save() return rules_actions.retention_save(runtime.build_ctx()) end
function action_logs() return logs_actions.logs(runtime.build_ctx()) end
function action_legacy_scan() return legacy_actions.legacy_scan(runtime.build_ctx()) end
function action_legacy_clean() return legacy_actions.legacy_clean(runtime.build_ctx()) end
