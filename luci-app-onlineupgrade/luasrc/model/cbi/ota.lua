--[[
    LuCI OTA 升级插件 - 设置页面模型
    
    功能特性：
    1. GitHub 联动：支持 API 地址配置及私有库 Token 访问。
    2. 预发布支持：[新增] 支持开启/关闭 Pre-release 版本检测。
    3. 下载加速：支持通过代理镜像节点（如 ghproxy）加速固件下载。
    4. 自动化任务：联动 Crontab 实现每日凌晨 03:00 自动检查新版本。
    5. 容灾策略：支持升级后自动重装第三方插件列表，并强制保留自定义敏感文件。
    6. 磁盘扩容：支持 x86/ARM 架构升级后自动扩展根分区至全盘。
    7. 消息推送：集成 Server酱、Telegram Bot、钉钉机器人通知。
]]--

local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local _ = luci.i18n.translate

-- 变量定义
local m, s, o, t, p, cp, ck, n, type, token, chatid

-- --- 1. 界面地图定义与 UI 响应式样式 ---
m = Map("ota", _("OTA 升级设置"), 
    _("配置 GitHub API 接口、下载代理及推送通知通道。") .. [[
<style type="text/css">
    /* --- 1.1 基础容器：自适应宽度与阴影卡片 --- */
    #maincontent .cbi-map { width: 98% !important; max-width: 950px !important; margin: 15px auto !important; }
    .cbi-section {
        background: #fff !important;
        border: 1px solid #99a9bf !important;
        border-radius: 8px !important;
        padding: 15px 20px !important;
        box-shadow: 0 4px 15px rgba(0,0,0,0.05) !important;
        margin-bottom: 20px !important;
    }

    /* --- 1.2 核心布局优化 --- */
    .cbi-value {
        display: flex !important;
        flex-wrap: wrap !important;
        padding: 14px 0 !important;
        border-bottom: 1px solid #f0f3f7 !important;
        align-items: center !important;
    }
    .cbi-value-title {
        flex: 1 0 180px !important;
        max-width: 220px !important;
        color: #485cc7 !important;
        font-weight: 600 !important;
    }
    .cbi-value-field { 
        flex: 10 1 300px !important;
        display: flex !important; 
        flex-wrap: wrap !important; 
        min-width: 0 !important;
        align-items: center !important; 
    }

    /* --- 1.3 功能注释：极致换行控制 --- */
    .cbi-value-description {
        flex: 1 0 100% !important; 
        margin: 8px 0 0 0 !important;
        color: #808695 !important;
        font-size: 13px !important;
        line-height: 1.6 !important;
        white-space: normal !important;
        word-wrap: break-word !important;
        word-break: break-all !important;
    }

    /* --- 1.4 移动端极致优化 (768px以下) --- */
    @media screen and (max-width: 768px) {
        .cbi-value { flex-direction: column !important; align-items: flex-start !important; }
        .cbi-value-title { width: 100% !important; margin-bottom: 8px !important; }
        .cbi-value-field { width: 100% !important; }
        .cbi-input-text, .cbi-input-password, .cbi-input-select { height: 42px !important; }
    }
</style>
]])

-- --- 2. 基础设置 (Section: settings) ---
s = m:section(NamedSection, "settings", "ota", _("基础设置"))
s.anonymous = true

-- 2.1 GitHub 接口配置
o = s:option(Value, "url", _("GitHub API 地址"), 
    _("填入固件仓库地址。插件会自动处理正式版/预发布版的逻辑。") .. "<br />" .. 
    _("示例：https://api.github.com/repos/qsyqn1/immortalwrt-xgp-auto-build"))
o.placeholder = "https://api.github.com/repos/user/repo"

o = s:option(Value, "github_token", _("GitHub Token (选填)"), _("访问私有仓库或规避 GitHub API 访问频率限制时填写。"))
o.password = true

-- 【核心新增】Pre-release 接收开关
o = s:option(Flag, "allow_prerelease", _("接收预发布版本"), _("开启后可检测并升级至 GitHub 上的 Pre-release (Beta) 版本。"))
o.default = "0"
o.rmempty = false

-- 2.2 下载加速配置
o = s:option(Flag, "download_proxy", _("启用 GitHub 下载加速"), _("开启后通过镜像节点下载，解决国内网络连接 GitHub 慢的问题。"))
o.default = "0"

o = s:option(Value, "custom_proxy_url", _("自定义加速前缀"), _("例如：https://mirror.ghproxy.com/ (留空则尝试使用内置节点)。"))
o:depends("download_proxy", "1")
o.placeholder = "https://mirror.ghproxy.com/"

-- 2.3 升级自动化与增强策略
o = s:option(Flag, "auto_check", _("定时检查更新"), _("每日凌晨 03:00 自动检测云端版本，发现新版将通过下方配置的通道推送。"))

o = s:option(Flag, "backup_plugins", _("升级后恢复插件"), _("升级成功进入系统后，自动根据记录重装之前手动安装过的第三方插件包。"))
o.default = "1"

o = s:option(Flag, "auto_resize", _("自动扩容磁盘"), _("升级后自动将根分区扩展至整个物理磁盘剩余空间（常见于 x86/ARM 扩容）。"))
o.default = "0"

o = s:option(Flag, "config_audit", _("配置冲突审计"), _("挂载下载的固件并分析配置差异，在前端展示潜在风险（内存小于 512M 建议关闭）。"))
o.default = "0"
o.rmempty = false

-- 2.4 文件保留策略
o = s:option(TextValue, "custom_files", _("强制保留文件路径"), _("每行一个绝对路径。这些路径将被强制同步至 /etc/sysupgrade.conf 确保升级不丢失。"))
o.rows = 5

-- --- 3. 推送通知设置 (Section: notification) ---
s = m:section(TypedSection, "ota", _("推送通知设置"))
s.anonymous = true
s.addremove = false
function s.cfgsections(self) return { "notification" } end

o = s:option(Flag, "enabled", _("开启通知服务"))
o.rmempty = false

type = s:option(ListValue, "notify_type", _("通知通道"))
type:value("sct", _("Server酱 (微信通知)"))
type:value("tg", _("Telegram Bot (电报)"))
type:value("dingtalk", _("钉钉群机器人"))
type:depends("enabled", "1")

o = s:option(Value, "notify_token", _("推送身份 Token"), _("对应通知平台提供的 API Key 或 Bot Token。"))
o.password = true
o:depends("enabled", "1")

chatid = s:option(Value, "notify_chatid", _("Telegram Chat ID"))
chatid:depends("notify_type", "tg")
chatid.rmempty = true

-- --- 4. 保存提交后置逻辑 ---
function m.on_after_commit(self)
    -- 4.1 同步 Crontab 定时任务逻辑
    local auto_enabled = uci:get("ota", "settings", "auto_check") == "1"
    local cron_task = "/usr/bin/ota.sh check"
    
    if auto_enabled then
        -- 注入凌晨 3 点任务，并确保不重复
        sys.exec("(crontab -l | grep -v '" .. cron_task .. "'; echo '00 03 * * * " .. cron_task .. "') | crontab -")
    else
        -- 移除定时任务
        sys.exec("crontab -l | grep -v '" .. cron_task .. "' | crontab -")
    end
    sys.exec("/etc/init.d/cron restart")

    -- 4.2 同步“强制保留文件”至 sysupgrade.conf
    local custom_files = uci:get("ota", "settings", "custom_files")
    if custom_files then
        for line in custom_files:gmatch("[^\r\n]+") do
            line = line:gsub("%s+", "") -- 去除空格
            if line ~= "" then
                -- 只有不存在时才追加，避免重复写入
                sys.exec(string.format("grep -q '^%s$' /etc/sysupgrade.conf || echo '%s' >> /etc/sysupgrade.conf", line, line))
            end
        end
    end
end

return m