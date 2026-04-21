--[[
    LuCI OTA 升级插件 - 设置页面模型
    
    功能特性：
    1. GitHub 联动：支持 API 地址配置及私有库 Token 访问。
    2. 下载加速：支持通过代理镜像节点（如 ghproxy）加速固件下载。
    3. 自动化任务：联动 Crontab 实现每日凌晨 03:00 自动检查新版本。
    4. 容灾策略：支持升级后自动重装第三方插件列表，并强制保留自定义敏感文件。
    5. 磁盘扩容：新增支持 x86/ARM 架构升级后自动扩展根分区至全盘。
    6. 消息推送：集成 Server酱、Telegram Bot、钉钉机器人三大通知通道。
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

    /* --- 1.2 PC端 核心布局 --- */
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

    /* --- 1.3 功能注释：强制换行与自动伸缩 --- */
    .cbi-value-description {
        flex: 1 0 100% !important;   /* 强制占据 100% 宽度实现物理换行 */
        margin: 8px 0 0 0 !important;
        padding: 0 !important;
        color: #808695 !important;
        font-size: 13px !important;
        line-height: 1.6 !important;
        font-weight: normal !important;
        /* 极致换行控制：防止长链接或长英文溢出屏幕 */
        white-space: normal !important;
        word-wrap: break-word !important;
        word-break: break-all !important;
        overflow-wrap: break-word !important;
    }

    /* --- 1.4 表单组件：样式缝合 --- */
    .cbi-input-text, .cbi-input-password, .cbi-input-select {
        flex: 1 !important; height: 38px !important; 
        border: 1px solid #808695 !important; border-radius: 4px 0 0 4px !important;
        padding: 0 12px !important; background: #fff !important;
        box-sizing: border-box !important; margin: 0 !important;
    }

    #maincontent .cbi-value-field .cbi-button {
        display: inline-flex !important; align-items: center !important; justify-content: center !important;
        height: 38px !important; min-width: 50px !important;
        margin: 0 0 0 -1px !important; padding: 0 10px !important;
        background-color: #485cc7 !important;
        border: 1px solid #485cc7 !important; border-radius: 0 4px 4px 0 !important;
        color: #fff !important; text-shadow: none !important;
    }

    /* --- 1.5 移动端 极致优化 (响应式阈值 768px) --- */
    @media screen and (max-width: 768px) {
        .cbi-section { padding: 12px !important; }
        
        .cbi-value { 
            display: flex !important; 
            flex-direction: column !important; /* 强制垂直排列：标题在上，内容在下 */
            align-items: flex-start !important; 
            padding: 16px 0 !important;
        }

        .cbi-value-title { 
            flex: none !important;
            width: 100% !important; 
            max-width: 100% !important;
            margin-bottom: 8px !important;
            font-size: 15px !important;
            line-height: 1.2 !important;
        }

        .cbi-value-field { 
            width: 100% !important;
            flex: none !important;
        }

        /* 增加移动端触控高度 */
        .cbi-input-text, .cbi-input-password, .cbi-input-select, #maincontent .cbi-value-field .cbi-button {
            height: 42px !important;
        }

        /* 移动端文本域自适应 */
        textarea {
            width: 100% !important;
            font-size: 14px !important;
        }

        /* Checkbox 触控区域放大 */
        .cbi-value-field > input[type="checkbox"] {
            margin: 5px 0 !important;
            transform: scale(1.2);
        }
    }
</style>
]])

-- --- 2. 基础设置 (Section: settings) ---
s = m:section(NamedSection, "settings", "ota", _("基础设置"))
s.anonymous = true

-- 2.1 GitHub 接口配置
o = s:option(Value, "url", _("GitHub API 地址"), _("填入固件所在的 GitHub Release 接口地址。") .. "<br />" .. _("示例：https://api.github.com/repos/user/repo/releases/latest"))
o.placeholder = "https://api.github.com/repos/..."

o = s:option(Value, "github_token", _("GitHub Token (选填)"), _("访问私有仓库或规避 GitHub API 访问频率限制时必填。"))
o.password = true

-- 2.2 下载加速配置
o = s:option(Flag, "download_proxy", _("启用 GitHub 下载加速"), _("开启后将通过镜像节点下载，解决国内连接 GitHub 慢的问题。"))
o.default = "0"

o = s:option(Value, "custom_proxy_url", _("自定义加速前缀"), _("例如：https://mirror.ghproxy.com/ (留空则尝试内置节点)。"))
o:depends("download_proxy", "1")
o.placeholder = "https://mirror.ghproxy.com/"

-- 2.3 升级自动化与增强策略 (Safe-Flash)
o = s:option(Flag, "auto_check", _("定时检查更新"), _("在每日凌晨 03:00 检测云端版本并推送通知。"))

o = s:option(Flag, "backup_plugins", _("升级后恢复插件"), _("升级成功后自动重装之前已安装的第三方插件包。"))
o.default = "1"

-- 【新增功能】自动磁盘扩容开关
o = s:option(Flag, "auto_resize", _("自动扩容磁盘"), _("升级后自动将根分区扩展至整个物理磁盘（适用于 x86/ARM 刷机）。"))
o.default = "0"

-- 增加配置冲突审计开关
o = s:option(Flag, "config_audit", translate("配置冲突审计"), translate("挂载固件以检查配置冲突（内存不足时禁用）"))
o.default = "0" -- 默认为关闭，防止 x86 用户直接卡死
o.rmempty = false

-- 自定义文件保留策略
o = s:option(TextValue, "custom_files", _("强制保留文件路径"), _("每行一个绝对路径。这些路径将被强制加入 /etc/sysupgrade.conf 以确保升级不丢失。"))
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

o = s:option(Value, "notify_token", _("推送身份 Token"), _("对应通知平台提供的 API Key。"))
o.password = true
o:depends("enabled", "1")

chatid = s:option(Value, "notify_chatid", _("Telegram Chat ID"))
chatid:depends("notify_type", "tg")
chatid.rmempty = true

-- --- 4. 保存提交后置逻辑 ---
function m.on_after_commit(self)
    -- 4.1 同步 Crontab 定时任务
    local auto_enabled = uci:get("ota", "settings", "auto_check") == "1"
    local cron_task = "/usr/bin/ota.sh check"
    
    if auto_enabled then
        sys.exec("(crontab -l | grep -v '" .. cron_task .. "'; echo '00 03 * * * " .. cron_task .. "') | crontab -")
    else
        sys.exec("crontab -l | grep -v '" .. cron_task .. "' | crontab -")
    end
    sys.exec("/etc/init.d/cron restart")

    -- 4.2 处理“强制保留文件”逻辑：同步到 sysupgrade.conf
    local custom_files = uci:get("ota", "settings", "custom_files")
    if custom_files then
        -- 清理旧的标记，重新写入
        for line in custom_files:gmatch("[^\r\n]+") do
            if line ~= "" then
                sys.exec(string.format("grep -q '%s' /etc/sysupgrade.conf || echo '%s' >> /etc/sysupgrade.conf", line, line))
            end
        end
    end
end

return m