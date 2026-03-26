local m, s, o

m = Map("vnt2", _("VNT2.0 客户端"))

-- ========== 服务运行状态展示 ==========
s = m:section(TypedSection, "main", _("客户端运行状态"))
s.addremove = false
s.anonymous = true
s.template = "cbi/nullsection"

o = s:option(DummyValue, "service_status", "")
o.rawhtml = true

function o.cfgvalue(self, section)
    local status_output = luci.sys.exec("/etc/init.d/vnt2 status 2>/dev/null") or ""
    local lower_out = status_output:lower()

    -- 正确判断服务运行状态：优先检查 "not running"，其次检查 "running"
    local is_running = false
    if lower_out:find("not running") then
        is_running = false
    elseif lower_out:find("running") then
        is_running = true
    end

    if is_running then
        return [[
            <div style="padding: 10px; background-color: #f0fff4; border: 1px solid #28a745; border-radius: 4px; margin-bottom: 15px;">
                <span style="color: #28a745; font-weight: bold;">
                    &#10004; ]] .. _("VNT2.0客户端 运行中") .. [[
                </span>
            </div>
        ]]
    else
        return [[
            <div style="padding: 10px; background-color: #fff5f5; border: 1px solid #dc3545; border-radius: 4px; margin-bottom: 15px;">
                <span style="color: #dc3545; font-weight: bold;">
                    &#10008; ]] .. _("VNT2.0客户端 已停止") .. [[
                </span>
            </div>
        ]]
    end
end

-- ========== 基础配置 ==========
s = m:section(TypedSection, "main", _("基本配置"))
s.addremove = false
s.anonymous = true

s:tab("basic", _("基本配置"))

-- 1. 运行状态
o = s:taboption("basic", Flag, "enabled", _("运行"))
o.default = o.disabled
o.rmempty = false

-- 2. 可执行文件路径
o = s:taboption("basic", Value, "vnt_path", _("可执行文件路径"))
o.datatype = "string"
o.rmempty = false
o.default = "/usr/bin/vnt2-cli"

-- 3. 配置文件路径
o = s:taboption("basic", Value, "config_path", _("配置文件路径"))
o.datatype = "string"
o.rmempty = false
o.default = "/etc/vnt2/config.toml"

-- 4. 日志保存路径
o = s:taboption("basic", Value, "log_path", _("日志保存路径"))
o.datatype = "string"
o.rmempty = false
o.default = "/tmp"

-- ========== 配置文件编辑（子标签） ==========
s:tab("editor", _("配置文件编辑"))

o = s:taboption("editor", DummyValue, "config_editor_html", "")
o.rawhtml = true
o.cfgvalue = function(self, section)
    local uci = require("luci.model.uci").cursor()
    local config_path = uci:get("vnt2", "@main[0]", "config_path")

    local content = ""
    local f = io.open(config_path, "r")
    if f then
        content = f:read("*a")
        f:close()
    else
        content = "# 错误：无法读取配置文件 → " .. (config_path or "") .. "\n"
    end

    content = content:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")

    return [[
<style>
#editor_container {
    width: 100% !important;
    overflow-x: auto !important;
    overflow-y: hidden !important;
    margin: 0 0 10px 0 !important;
    padding: 0 !important;
}
#custom_config_editor {
    width: max-content !important;
    min-width: 100% !important;
    height: 600px !important;
    font-size: 14px !important;
    font-family: monospace !important;
    padding: 12px !important;
    border: 1px solid #ccc !important;
    border-radius: 4px !important;
    resize: vertical !important;
    box-sizing: border-box !important;
    white-space: pre !important;
}
#save_config_btn {
    padding: 8px 25px !important;
    background: #007bff !important;
    color: #fff !important;
    border: none !important;
    border-radius: 4px !important;
    font-weight: bold !important;
    cursor: pointer !important;
    font-size: 14px !important;
}
#save_config_btn:hover {
    background: #0056b3 !important;
}
#save_tip {
    margin-left: 15px !important;
    font-weight: bold !important;
    color: #28a745 !important;
    display: none !important;
}
</style>

<button id="save_config_btn">]] .. _("保存配置文件") .. [[</button>
<span id="save_tip">]] .. _("保存成功！") .. [[</span>

<div id="editor_container">
    <textarea id="custom_config_editor">]] .. content .. [[</textarea>
</div>

<script>
document.getElementById('save_config_btn').addEventListener('click', function() {
    var content = document.getElementById('custom_config_editor').value;

    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/luci/admin/vpn/vnt2/save_config', true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() {
        if (xhr.status === 200) {
            var tip = document.getElementById('save_tip');
            tip.style.display = 'inline';
            setTimeout(function() { tip.style.display = 'none'; }, 2000);
        } else {
            alert('保存失败：' + xhr.responseText);
        }
    };
    xhr.onerror = function() {
        alert('保存请求失败，请检查网络连接。');
    };
    xhr.send('content=' + encodeURIComponent(content));
});
</script>
]]
end

-- ========== 节点信息 ==========
s = m:section(TypedSection, "main", _("节点信息"))
s.anonymous = true
s.addremove = false
s.template = "cbi/nullsection"

o = s:option(DummyValue, "info_table", "")
o.rawhtml = true

local function get_vnt2_info()
    local handle = io.popen("vnt-ctrl info 2>/dev/null", "r")

    if not handle then
        return '<span style="color:red; font-weight:bold;">执行命令失败</span>'
    end

    local content = handle:read("*a")
    handle:close()

    if not content or content == "" then
        return '<span style="color:#666; font-weight:bold;">暂无信息</span>'
    end

    -- 清理 ANSI 转义
    content = content:gsub("\27%[%d+m", "")
    content = content:gsub("\27%[%d+;%d+m", "")
    content = content:gsub("\r", "")

    -- 去除空行
    local lines = {}
    for line in content:gmatch("[^\n]+") do
        local tl = line:gsub("^%s+", ""):gsub("%s+$", "")
        if tl ~= "" then
            table.insert(lines, tl)
        end
    end
    content = table.concat(lines, "\n")

    -- HTML 转义
    content = content:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    -- 高亮关键词
    content = content:gsub("Online (%d+ms)", '<span style="color:#0c0">Online %1</span>')
    content = content:gsub("Unknown", '<span style="color:#f33">Unknown</span>')

    return content
end

function o.cfgvalue(self, section)
    local txt = get_vnt2_info()
    return [[
<div style="
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    background: #f8f8f8;
    border: 1px solid #ddd;
    border-radius: 4px;
    padding: 10px;
    margin: 5px 0;
">
<pre style="
    margin:0;
    font-family: monospace;
    font-size: 14px;
    font-weight: bold;
    white-space: pre;
    line-height: 1.3;
">]] .. txt .. [[</pre>
</div>
]]
end

-- ========== 节点列表 ==========
s = m:section(TypedSection, "main", _("节点列表"))
s.anonymous = true
s.addremove = false
s.template = "cbi/nullsection"

o = s:option(DummyValue, "client_list", "")
o.rawhtml = true

local function get_vnt2_clients()
    local handle = io.popen("vnt-ctrl clients 2>/dev/null", "r")

    if not handle then
        return '<span style="color:red; font-weight:bold;">执行命令失败</span>'
    end

    local content = handle:read("*a")
    handle:close()

    if not content or content == "" then
        return '<span style="color:#666; font-weight:bold;">暂无客户端</span>'
    end

    -- 清理 ANSI 转义
    content = content:gsub("\27%[%d+m", "")
    content = content:gsub("\27%[%d+;%d+m", "")
    content = content:gsub("\r", "")

    -- 去除空行
    local lines = {}
    for line in content:gmatch("[^\n]+") do
        local tl = line:gsub("^%s+", ""):gsub("%s+$", "")
        if tl ~= "" then
            table.insert(lines, tl)
        end
    end
    content = table.concat(lines, "\n")

    -- HTML 转义
    content = content:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    -- 高亮关键词
    content = content:gsub("true", '<span style="color:#0c0">true</span>')
    content = content:gsub("false", '<span style="color:#f33">false</span>')

    return content
end

function o.cfgvalue(self, section)
    local txt = get_vnt2_clients()
    return [[
<div style="
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    background: #f8f8f8;
    border: 1px solid #ddd;
    border-radius: 4px;
    padding: 10px;
    margin: 5px 0;
">
<pre style="
    margin:0;
    font-family: monospace;
    font-size: 14px;
    font-weight: bold;
    white-space: pre;
    line-height: 1.5;
">]] .. txt .. [[</pre>
</div>
]]
end

return m
