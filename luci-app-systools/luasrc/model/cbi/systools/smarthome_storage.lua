-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

local systools_common = require "luci.model.cbi.systools.common"
local m, s, o
local http = require "luci.http"
local sys = require "luci.sys"


-- 路径净化函数，防止路径遍历

-- 路径净化函数，防止路径遍历
-- 循环净化直到没有变化，覆盖 ../、..\、....// 等各种变形
    until path == prev
    -- 确保路径以 / 开头
    if not path:match("^/") then
        path = "/" .. path
    end
m = Map("systools", translate("Docker 存储设置"),
    translate("管理 Docker 数据存储位置，支持迁移到 U 盘"))

-- 检查 Docker 是否安装
local docker_installed = sys.exec("command -v docker >/dev/null 2>&1 && echo yes || echo no")
if docker_installed:match("no") then
    m.pageaction = false
    s = m:section(SimpleSection)
    s.title = translate("Docker 未安装")
    s.description = translate("请先安装 Docker 相关包（dockerd、docker-cli 等）后再使用此功能。")
    return m
end

-- 当前存储状态
s = m:section(NamedSection, "smarthome", "smarthome", translate("当前存储状态"),
    translate("Docker 数据目录的当前使用情况"))
s.addremove = false
s.anonymous = true

-- 获取当前 Docker 数据目录
local data_root = sys.exec("docker info --format '{{.DockerRootDir}}' 2>/dev/null" )
if not data_root or data_root == "" then
    data_root = "/opt/docker"
end
data_root = data_root:gsub("%s+", "")

o = s:option(DummyValue, "_data_root", translate("数据目录"))
o.value = data_root

-- 获取磁盘使用情况
local df_output = sys.exec("df -h '" .. data_root .. "' 2>/dev/null | tail -1")
local total, used, avail, use_pct = df_output:match("%S+%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")

o = s:option(DummyValue, "_total", translate("总容量"))
o.value = total or "N/A"

o = s:option(DummyValue, "_used", translate("已使用"))
o.value = used or "N/A"

o = s:option(DummyValue, "_avail", translate("剩余"))
o.value = avail or "N/A"

o = s:option(DummyValue, "_use_pct", translate("使用率"))
o.value = use_pct or "N/A"

-- 低空间告警
local use_pct_num = tonumber(use_pct and use_pct:gsub("%%", "") or 0)
if use_pct_num and use_pct_num >= 90 then
    o = s:option(DummyValue, "_low_space_warning")
    o.rawhtml = true
    o.value = '<div style="background:#fff3cd;color:#856404;padding:10px;border-radius:4px;margin-top:10px;border:1px solid #ffeeba;">' ..
        '<strong>' .. translate("警告：存储空间不足") .. '</strong><br>' ..
        translate("当前存储空间使用率已超过 90%，建议清理镜像或迁移到更大的存储设备。") ..
        '</div>'
elseif use_pct_num and use_pct_num >= 80 then
    o = s:option(DummyValue, "_space_notice")
    o.rawhtml = true
    o.value = '<div style="background:#d1ecf1;color:#0c5460;padding:10px;border-radius:4px;margin-top:10px;border:1px solid #bee5eb;">' ..
        translate("提示：存储空间使用率已超过 80%，请注意及时清理。") ..
        '</div>'
end

-- 已挂载的存储设备
s2 = m:section(SimpleSection, translate("已挂载的存储设备"),
    translate("系统中当前已挂载的存储设备列表"))

-- 获取挂载列表
local mounts_output = sys.exec("df -hT 2>/dev/null | grep -E 'ext4|ext3|vfat|ntfs' | grep -v '/rom' | grep -v '/overlay'")

if mounts_output and mounts_output ~= "" then
    local mounts = {}
    for line in mounts_output:gmatch("[^\r\n]+") do
        local fs, type, size, used, avail, use_pct, mountpoint = line:match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mountpoint then
            table.insert(mounts, {
                fs = fs,
                type = type,
                size = size,
                used = used,
                avail = avail,
                use_pct = use_pct,
                mountpoint = mountpoint
            })
        end
    end

    if #mounts > 0 then
        local html = '<table class="cbi-table table" style="width:100%">'
        html = html .. '<tr><th>' .. translate("设备") .. '</th>'
        html = html .. '<th>' .. translate("类型") .. '</th>'
        html = html .. '<th>' .. translate("总容量") .. '</th>'
        html = html .. '<th>' .. translate("已用") .. '</th>'
        html = html .. '<th>' .. translate("剩余") .. '</th>'
        html = html .. '<th>' .. translate("挂载点") .. '</th></tr>'

        for _, mnt in ipairs(mounts) do
            html = html .. '<tr>'
            html = html .. '<td><code>' .. mnt.fs .. '</code></td>'
            html = html .. '<td>' .. mnt.type .. '</td>'
            html = html .. '<td>' .. mnt.size .. '</td>'
            html = html .. '<td>' .. mnt.used .. '</td>'
            html = html .. '<td>' .. mnt.avail .. '</td>'
            html = html .. '<td><code>' .. mnt.mountpoint .. '</code></td>'
            html = html .. '</tr>'
        end

        html = html .. '</table>'

        o = s2:option(DummyValue, "_mounts_table")
        o.value = html
        o.rawhtml = true
    end
else
    o = s2:option(DummyValue, "_no_mounts")
    o.value = '<div style="color:gray;text-align:center;padding:20px;">' ..
        translate("未检测到外部存储设备") ..
        '</div>'
    o.rawhtml = true
end

-- 存储迁移
s3 = m:section(NamedSection, "smarthome", "smarthome", translate("存储位置迁移"),
    translate("将 Docker 数据目录迁移到其他存储位置（如 U 盘）"))
s3.addremove = false
s3.anonymous = true

-- 目标路径
o = s3:option(Value, "new_data_root", translate("目标路径"),
    translate("新的 Docker 数据目录路径，例如：/mnt/sda1/docker"))
o.placeholder = "/mnt/sda1/docker"
o.rmempty = true

-- 迁移按钮
o = s3:option(Button, "_migrate", translate("开始迁移"))
o.inputstyle = "apply"
o.inputtitle = translate("开始迁移")
o.description = translate("注意：迁移过程中 Docker 会停止服务，请确保没有重要容器在运行")
function o.write(self, section)
    local new_path = http.formvalue("cbid.systools.smarthome.new_data_root")

    if not new_path or new_path == "" then
        self.description = '<span style="color:red">' .. translate("请输入目标路径") .. '</span>'
        return
    end

    -- 净化路径，防止路径遍历
    new_path = systools_common.sanitize_path(new_path)

    -- 检查目标路径是否存在
    if not sys.exec("test -d " .. systools_common.shell_escape(new_path) .. " && echo yes || echo no"):match("yes") then
        self.description = '<span style="color:red">' .. translate("目标路径不存在，请先挂载 U 盘") .. '</span>'
        return
    end

    -- 执行迁移（后台执行）
    local cmd = string.format("/usr/libexec/systools/smarthome_storage.sh migrate %s >/tmp/systools_migrate.log 2>&1 &",
        systools_common.shell_escape(new_path))
    sys.call(cmd)

    self.description = '<span style="color:green">' .. translate("开始迁移，请稍候...") .. '<br>' ..
        translate("迁移过程中 Docker 会停止服务") .. '<br>' ..
        translate("刷新页面查看进度") .. '</span>'
end

-- 迁移进度
s4 = m:section(SimpleSection, translate("迁移进度"),
    translate("当前迁移操作的进度"))

local migrate_log = sys.exec("cat /tmp/systools_migrate.log 2>/dev/null | tail -20")
if migrate_log and migrate_log ~= "" then
    o = s4:option(DummyValue, "_migrate_log")
    o.rawhtml = true
    o.value = '<pre style="background:#f5f5f5;padding:10px;border-radius:4px;max-height:200px;overflow:auto;font-size:12px;">' ..
        luci.util.pcdata(migrate_log) .. '</pre>'
else
    o = s4:option(DummyValue, "_no_migrate")
    o.value = translate("暂无正在进行的迁移操作")
end

-- 镜像加速配置
s5 = m:section(NamedSection, "smarthome", "smarthome", translate("镜像加速配置"),
    translate("配置 Docker 镜像加速源，提高拉取速度"))
s5.addremove = false
s5.anonymous = true

o = s5:option(ListValue, "mirror_source", translate("镜像源"))
o:value("official", translate("官方源 (Docker Hub)"))
o:value("aliyun", translate("阿里云镜像加速"))
o:value("netease", translate("网易云镜像加速"))
o:value("ustc", translate("中科大镜像加速"))
o:value("custom", translate("自定义加速源"))
o.default = "aliyun"

o = s5:option(Value, "custom_mirror", translate("自定义加速源地址"),
    translate("例如：https://your-mirror.mirror.aliyuncs.com"))
o:depends("mirror_source", "custom")
o.placeholder = "https://"
o.rmempty = true

o = s5:option(Button, "_apply_mirror", translate("应用配置"))
o.inputstyle = "apply"
o.inputtitle = translate("应用并重启 Docker")
function o.write(self, section)
    local mirror_source = http.formvalue("cbid.systools.smarthome.mirror_source")
    local custom_mirror = http.formvalue("cbid.systools.smarthome.custom_mirror")

    -- 执行配置
    local cmd = string.format("/usr/libexec/systools/smarthome_images.sh configure_mirror %s %s >/dev/null 2>&1 &",
        systools_common.shell_escape(mirror_source),
        systools_common.shell_escape(custom_mirror or ""))
    sys.call(cmd)

    self.description = '<span style="color:green">' .. translate("配置已应用，Docker 正在重启") .. '</span>'
end

return m
