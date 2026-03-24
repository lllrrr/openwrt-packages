require("luci.i18n")
local _ = luci.i18n.translate

local m, s, o

m = Map("vnt2", _("VNT2.0 客户端"))

-- ========== 新增：服务运行状态展示（基础配置标签页最上方） ==========
s = m:section(TypedSection, "main", _("客户端运行状态"))
s.addremove = false
s.anonymous = true
s.template = "cbi/nullsection"  -- 无额外样式，仅展示内容

-- 展示状态（带颜色和图标，醒目）
o = s:option(DummyValue, "service_status", "")
o.rawhtml = true

function o.cfgvalue(self, section)
    -- 执行 status 命令，捕获输出（重定向错误输出到空，避免干扰）
    local status_output = luci.sys.exec("/etc/init.d/vnt2 status 2>/dev/null") or ""
    
    -- 判断是否包含 "running"（不区分大小写更稳妥）
    local is_running = (status_output:lower():find("running", 1, true) ~= nil) and (status_output:lower():find("not", 1, true) == nil)
    
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

-- ========== 标签页1：基础配置（完全保留你的原有逻辑） ==========
s = m:section(TypedSection, "main", _("基本配置"))
s.addremove = false  -- 不允许添加/删除配置节
s.anonymous = true   -- 匿名配置节（无需命名）


-- ---------------------- 子标签1：基本配置 ----------------------
s:tab("basic", _("基本配置"))

-- 1. 运行状态勾选框
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

-- ---------------------- 子标签2：配置文件编辑（纯HTML+横向滚动+独立保存按钮） ----------------------
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
        content = "# 错误：无法读取配置文件 → " .. config_path .. "\n"
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

<input type="hidden" id="config_path" value="]] .. config_path .. [[">
<button id="save_config_btn">]] .. _("保存配置文件") .. [[</button>
<span id="save_tip">]] .. _("保存成功！") .. [[</span>

<div id="editor_container">
    <textarea id="custom_config_editor">]] .. content .. [[</textarea>
</div>

<script>
document.getElementById('save_config_btn').addEventListener('click', function() {
    var content = document.getElementById('custom_config_editor').value;
    var path = document.getElementById('config_path').value;

    var xhr = new XMLHttpRequest();
    xhr.open('POST', window.location.href, true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() {
        if (xhr.status === 200) {
            var tip = document.getElementById('save_tip');
            tip.style.display = 'inline';
            setTimeout(function() { tip.style.display = 'none'; }, 2000);
        }
    };
    xhr.send('save_config=1&content=' + encodeURIComponent(content) + '&path=' + encodeURIComponent(path));
});
</script>
]]
end

-- ========== 新增：VNT2 服务信息展示 ==========
s = m:section(TypedSection, "main", _("节点信息"))
s.anonymous = true
s.addremove = false
s.template = "cbi/nullsection"

o = s:option(DummyValue, "info_table", _(""))
o.rawhtml = true

-- 获取并格式化info命令输出的函数
local function get_vnt2_info()
    local cmd = "vnt-ctrl info 2>/dev/null"
    local handle = io.popen(cmd, 'r')
    
    if not handle then
        return '<span style="color:red; font-weight:bold;">执行命令失败</span>'
    end
    
    local content = handle:read('*a')
    handle:close()
    
    if content == "" then
        return '<span style="color:#666; font-weight:bold;">暂无信息</span>'
    end

    -- 清理 ANSI 与特殊字符
    content = content:gsub("\27%[%d+m", "")
    content = content:gsub("\27%[%d+;%d+m", "")
    content = content:gsub("\r", "")

    -- 清理空行
    local lines = {}
    for line in content:gmatch("[^\n]+") do
        local tl = line:gsub("^%s+",""):gsub("%s+$","")
        if tl ~= "" then
            table.insert(lines, tl)
        end
    end
    content = table.concat(lines, "\n")

    -- HTML转义（安全）
    content = content:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    -- 高亮 Online、数字
    content = content:gsub("Online (%d+ms)", '<span style="color:#0c0">Online %1</span>')
    content = content:gsub("Unknown", '<span style="color:#f33">Unknown</span>')

    return content
end
-- 配置显示内容
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




-- ========== 标签页2：集群节点状态 ==========
s = m:section(TypedSection, "main", _("节点列表"))
s.anonymous = true
s.addremove = false
s.template = "cbi/nullsection"  -- 修正：移除tblsection，改用无样式模板
s.extedit = nil

o = s:option(DummyValue, "client_list", _(""))  -- 修正：添加翻译函数
o.rawhtml = true

local function get_vnt2_clients()
    local cmd = "vnt-ctrl clients 2>/dev/null"
    local handle = io.popen(cmd, 'r')
    
    if not handle then
        return '<span style="color:red; font-weight:bold;">执行命令失败</span>'
    end
    
    local content = handle:read('*a')
    handle:close()
    
    if content == "" then
        return '<span style="color:#666; font-weight:bold;">暂无客户端</span>'
    end

    -- 过滤ANSI
    content = content:gsub("\27%[%d+m", "")
    content = content:gsub("\27%[%d+;%d+m", "")
    content = content:gsub("\r", "")

    -- 跳过第一行空行，只留有效行
    local lines = {}
    local idx = 1
    for line in content:gmatch("[^\n]+") do
        if idx > 0 then
            local tl = line:gsub("^%s+",""):gsub("%s+$","")
            if tl ~= "" then
                table.insert(lines, tl)
            end
        end
        idx = idx + 1
    end
    content = table.concat(lines, "\n")

    -- 不转HTML，原样输出（交给外层pre处理）
    content = content:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    -- 颜色高亮（不破坏格式）
    content = content:gsub("true", '<span style="color:#0c0">true</span>')
    content = content:gsub("false", '<span style="color:#f33">false</span>')

    return content
end

-- 修正：改用cfgvalue函数，每次页面刷新都会重新获取数据
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

-- ====================== 仅独立保存按钮逻辑（安全、不报错） ======================
if luci.http.formvalue("save_config") then
    local content = tostring(luci.http.formvalue("content") or "")
    local path    = tostring(luci.http.formvalue("path") or "")

    if #content > 512 * 1024 then
        luci.http.status(400, "Config too large")
        return
    end

    local uci = require("luci.model.uci").cursor()
    local cfg_path = uci:get("vnt2", "@main[0]", "config_path") or "/etc/vnt2/config.toml"

    if path == cfg_path then
        local f = io.open(path, "w")
        if f then
            f:write(content)
            f:close()
            luci.sys.call("/etc/init.d/vnt2 restart >/dev/null 2>&1")
        end
    end

    luci.http.status(200, "OK")
    return
end

return m

