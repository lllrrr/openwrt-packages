-- Copyright 2024 luci-app-systools
-- Licensed to the public under the MIT License.

local systools_common = require "luci.model.cbi.systools.common"
local m, s, o
local http = require "luci.http"
local sys = require "luci.sys"


m = Map("systools", translate("Docker 镜像管理"),
    translate("管理 Docker 镜像，支持拉取、删除等操作"))

-- 检查 Docker 是否安装
local docker_installed = sys.exec("command -v docker >/dev/null 2>&1 && echo yes || echo no")
if docker_installed:match("no") then
    m.pageaction = false
    s = m:section(SimpleSection)
    s.title = translate("Docker 未安装")
    s.description = translate("请先安装 Docker 相关包（dockerd、docker-cli 等）后再使用此功能。")
    return m
end

-- 镜像拉取部分
s = m:section(NamedSection, "smarthome", "smarthome", translate("拉取镜像"),
    translate("从 Docker Hub 或国内镜像源拉取镜像"))
s.addremove = false
s.anonymous = true

-- 常用镜像快捷选择
o = s:option(ListValue, "quick_image", translate("常用镜像"))
o:value("", translate("--- 选择常用镜像 ---"))
o:value("homeassistant/home-assistant:latest", "Home Assistant (latest)")
o:value("homeassistant/home-assistant:stable", "Home Assistant (stable)")
o:value("eclipse-mosquitto:latest", "Mosquitto MQTT")
o:value("koenkk/zigbee2mqtt:latest", "Zigbee2MQTT")
o:value("nodered/node-red:latest", "Node-RED")
o:value("esphome/esphome:latest", "ESPHome")
o.default = ""

-- 自定义镜像名
o = s:option(Value, "custom_image", translate("自定义镜像名"),
    translate("例如：homeassistant/home-assistant:latest"))
o.placeholder = "homeassistant/home-assistant:latest"
o.rmempty = true

-- 镜像源选择
o = s:option(ListValue, "mirror_source", translate("镜像源"))
o:value("official", translate("官方源 (Docker Hub)"))
o:value("aliyun", translate("阿里云镜像加速"))
o:value("netease", translate("网易云镜像加速"))
o:value("ustc", translate("中科大镜像加速"))
o:value("custom", translate("自定义加速源"))
o.default = "aliyun"

-- 自定义加速源地址
o = s:option(Value, "custom_mirror", translate("自定义加速源地址"),
    translate("例如：https://your-mirror.mirror.aliyuncs.com"))
o:depends("mirror_source", "custom")
o.placeholder = "https://"
o.rmempty = true

-- 拉取按钮
o = s:option(Button, "_pull", translate("拉取镜像"))
o.inputstyle = "apply"
o.inputtitle = translate("开始拉取")
function o.write(self, section)
    local image_name = http.formvalue("cbid.systools.smarthome.custom_image")
    local quick_image = http.formvalue("cbid.systools.smarthome.quick_image")
    local mirror_source = http.formvalue("cbid.systools.smarthome.mirror_source")
    local custom_mirror = http.formvalue("cbid.systools.smarthome.custom_mirror")

    -- 优先使用自定义镜像名，没有的话用快捷选择
    if not image_name or image_name == "" then
        image_name = quick_image
    end

    if not image_name or image_name == "" then
        self.description = '<span style="color:red">' .. translate("请输入或选择要拉取的镜像名") .. '</span>'
        return
    end

    -- 执行拉取（后台执行）
    local cmd = string.format("/usr/libexec/systools/smarthome_images.sh pull %s %s %s >/tmp/systools_pull.log 2>&1 &",
        systools_common.shell_escape(image_name),
        systools_common.shell_escape(mirror_source),
        systools_common.shell_escape(custom_mirror or ""))
    sys.call(cmd)

    self.description = '<span style="color:green">' .. translate("开始拉取镜像：") .. image_name .. '<br>' ..
        translate("请稍候，刷新页面查看进度") .. '</span>'
end

-- 拉取进度
s2 = m:section(SimpleSection, translate("拉取进度"),
    translate("当前正在拉取的镜像进度"))

local pull_log = sys.exec("cat /tmp/systools_pull.log 2>/dev/null | tail -20")
if pull_log and pull_log ~= "" then
    o = s2:option(DummyValue, "_pull_log")
    o.rawhtml = true
    o.value = '<pre style="background:#f5f5f5;padding:10px;border-radius:4px;max-height:200px;overflow:auto;font-size:12px;">' ..
        luci.util.pcdata(pull_log) .. '</pre>'
else
    o = s2:option(DummyValue, "_no_pull")
    o.value = translate("暂无正在拉取的镜像")
end

-- 镜像统计
s3 = m:section(NamedSection, "smarthome", "smarthome", translate("镜像统计"))
s3.anonymous = true

local stats_output = sys.exec("/usr/libexec/systools/smarthome_images.sh stats 2>/dev/null")
local stats = {}
for line in stats_output:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key and value then
        stats[key] = value
    end
end

o = s3:option(DummyValue, "_count", translate("镜像总数"))
o.value = stats.total_count or "0"

o = s3:option(DummyValue, "_size", translate("总大小"))
o.value = stats.total_size or "N/A"

-- 清理按钮
btn_prune = s3:option(Button, "_prune", translate("清理悬空镜像"))
btn_prune.inputtitle = translate("清理")
btn_prune.inputstyle = "reset"
btn_prune.description = translate("删除未被使用的悬空镜像")
function btn_prune.write(self, section)
    sys.call("/usr/libexec/systools/smarthome_images.sh prune >/dev/null 2>&1 &")
    http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "images"))
end

-- 镜像列表
s4 = m:section(SimpleSection, translate("已下载镜像"),
    translate("当前系统中已下载的 Docker 镜像列表"))

-- 获取镜像列表
local images_output = sys.exec("/usr/libexec/systools/smarthome_images.sh list 2>/dev/null")
local images = {}
for line in images_output:gmatch("[^\r\n]+") do
    local repo, tag, id, size, created = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if id then
        table.insert(images, {
            repo = repo,
            tag = tag,
            id = id,
            size = size,
            created = created
        })
    end
end

if #images == 0 then
    o = s4:option(DummyValue, "_empty")
    o.value = '<div style="color:gray;text-align:center;padding:20px;">' ..
        translate("暂无已下载的镜像") ..
        '</div>'
    o.rawhtml = true
else
    -- 显示镜像表格（标准CBI风格，单form多按钮）
    local html = '<form method="post" class="cbi-section-table-form">'
    html = html .. '<input type="hidden" name="cbi.submit" value="1">'
    html = html .. '<table class="cbi-table table cbi-section-table" style="width:100%">'
    html = html .. '<tr class="cbi-section-table-titles">'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("仓库") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("标签") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("镜像 ID") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("大小") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell">' .. translate("创建时间") .. '</th>'
    html = html .. '<th class="cbi-section-table-cell cbi-section-actions">' .. translate("操作") .. '</th>'
    html = html .. '</tr>'

    for _, img in ipairs(images) do
        html = html .. '<tr class="cbi-section-table-row">'
        html = html .. '<td class="cbi-section-table-cell"><strong>' .. img.repo .. '</strong></td>'
        html = html .. '<td class="cbi-section-table-cell">' .. img.tag .. '</td>'
        html = html .. '<td class="cbi-section-table-cell"><small>' .. img.id:sub(1,12) .. '</small></td>'
        html = html .. '<td class="cbi-section-table-cell">' .. img.size .. '</td>'
        html = html .. '<td class="cbi-section-table-cell"><small>' .. img.created .. '</small></td>'
        html = html .. '<td class="cbi-section-table-cell cbi-section-actions">'
        html = html .. '<button type="submit" name="cbid.systools.smarthome._remove_' .. img.id .. '" '
        html = html .. 'class="cbi-button cbi-button-negative cbi-button-reset" '
        html = html .. 'onclick="return confirm(\'' .. translate("确定要删除此镜像吗？") .. '\')">'
        html = html .. translate("删除") .. '</button>'
        html = html .. '</td>'
        html = html .. '</tr>'
    end

    html = html .. '</table>'
    html = html .. '</form>'

    o = s4:option(DummyValue, "_table")
    o.value = html
    o.rawhtml = true
end
        sys.call("/usr/libexec/systools/smarthome_images.sh remove " .. systools_common.shell_escape(img.id) .. " >/dev/null 2>&1 &")
        http.redirect(luci.dispatcher.build_url("admin", "systools", "smarthome", "images"))
    end
end

return m


