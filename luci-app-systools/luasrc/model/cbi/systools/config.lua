-- Copyright 2024 System Tools Project
local systools_common = require "luci.model.cbi.systools.common"
-- Licensed under the MIT License

local m, s, o
local sys = require "luci.sys"
local http = require "luci.http"
local fs = require "nixio.fs"

m = Map("systools", translate("配置管理"), translate("导入导出插件配置，方便备份和迁移。"))

-- 导出配置区域
s = m:section(SimpleSection, translate("导出配置"), translate("导出当前所有 systools 插件配置"))
s.anonymous = true

-- 获取当前配置内容
local current_config = sys.exec("uci export systools 2>/dev/null")
if not current_config or #current_config == 0 then
    current_config = translate("暂无配置")
end

o = s:option(TextValue, "_export_content", translate("当前配置"))
o.rows = 15
o.readonly = true
o.value = current_config
o.description = translate("复制下方内容保存为备份文件，或使用导出按钮下载")

-- 导出按钮
btn_export = s:option(Button, "_export_btn", translate("导出配置文件"))
btn_export.inputtitle = translate("导出配置")
btn_export.inputstyle = "apply"
btn_export.write = function(self, section)
    -- 生成导出文件并触发下载
    local export_file = "/tmp/systools_config_backup.txt"
    sys.exec("uci export systools > " .. systools_common.shell_escape(export_file) .. " 2>/dev/null")
    http.redirect(luci.dispatcher.build_url("admin", "systools", "config"))
end

-- 导入配置区域
s2 = m:section(SimpleSection, translate("导入配置"), translate("从备份文件恢复配置，导入前将自动备份当前配置"))
s2.anonymous = true

o = s2:option(TextValue, "_import_content", translate("粘贴配置内容"))
o.rows = 10
o.description = translate("将导出的配置内容粘贴到此处，然后点击导入按钮恢复")
o.placeholder = translate("粘贴 UCI 配置内容...")

-- 导入按钮
btn_import = s2:option(Button, "_import_btn", translate("导入配置"))
btn_import.inputtitle = translate("导入配置")
btn_import.inputstyle = "positive"
btn_import.write = function(self, section)
    local import_content = http.formvalue("cbid.systools._import_content")
    
    if not import_content or #import_content == 0 then
        return
    end
    
    -- ===== 白名单校验 =====
    -- 1. 必须包含 package systools 声明
    if not import_content:match("package%s+systools") then
        m.message = translate("导入失败：配置格式不正确，必须包含 systools 包声明")
        return
    end
    
    -- 2. 禁止包含其他 package 的配置（安全白名单）
    local other_packages = {}
    for pkg in import_content:gmatch("package%s+([a-z0-9_]+)") do
        if pkg ~= "systools" then
            table.insert(other_packages, pkg)
        end
    end
    if #other_packages > 0 then
        m.message = translate("导入失败：不允许包含其他包的配置")
        return
    end
    
    -- 3. 基本格式校验：检查是否有明显异常字符
    if import_content:match("[<>;|`$]") and not import_content:match("option%s+") then
        m.message = translate("导入失败：配置内容包含可疑字符")
        return
    end
    
    -- 先备份当前配置
    local backup_dir = "/etc/systools/backup/config"
    sys.exec("mkdir -p " .. systools_common.shell_escape(backup_dir))
    local backup_file = backup_dir .. "/systools_backup_" .. os.date("%Y%m%d_%H%M%S") .. ".uci"
    sys.exec("uci export systools > " .. systools_common.shell_escape(backup_file) .. " 2>/dev/null")
    
    -- 写入临时文件并导入
    local tmp_file = "/tmp/systools_import.tmp"
    fs.writefile(tmp_file, import_content)
    
    -- 执行导入
    local result = sys.exec("uci import systools < " .. systools_common.shell_escape(tmp_file) .. " && uci commit systools 2>&1")
    
    -- 清理临时文件
    sys.exec("rm -f " .. systools_common.shell_escape(tmp_file))
    
    http.redirect(luci.dispatcher.build_url("admin", "systools", "config"))
end

-- 备份文件列表
s3 = m:section(SimpleSection, translate("备份记录"), translate("最近的配置备份文件"))
s3.anonymous = true

-- 列出备份文件
local backup_list = sys.exec("ls -lt /etc/systools/backup/config/ 2>/dev/null | head -10")
if not backup_list or #backup_list == 0 then
    o = s3:option(DummyValue, "_no_backup")
    o.value = translate("暂无备份记录")
else
    o = s3:option(DummyValue, "_backup_list")
    o.rawhtml = true
    o.value = '<pre style="background:#f5f5f5;padding:10px;border-radius:4px;font-size:12px;">' .. luci.util.pcdata(backup_list) .. '</pre>'
end

return m
