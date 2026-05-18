--[[
LuCI DeviceMaster - Settings CBI Model
]]--

local m, s, o
local sys = require "luci.sys"
local dispatcher = require "luci.dispatcher"
local uci = require "luci.model.uci".cursor()

m = Map("devicemaster")

s = m:section(TypedSection, "settings", "OUI数据库设置")
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_mobile_css", "")
o.rawhtml = true
o.cfgvalue = function(self, section)
    return [[
<style>
/* 移动端响应式布局 */
@media screen and (max-width: 768px) {
    /* 表格横向滚动 */
    .cbi-section-node { overflow-x: auto; -webkit-overflow-scrolling: touch; }
    .cbi-section-node table { min-width: 500px; }
    
    /* 表单元素宽度自适应 */
    .cbi-value-field input[type="text"],
    .cbi-value-field input[type="password"],
    .cbi-value-field select {
        max-width: 100%;
        box-sizing: border-box;
    }
    
    /* 按钮组自适应 */
    .cbi-page-actions { flex-wrap: wrap; gap: 8px; }
    .cbi-page-actions .btn { flex: 1; min-width: 80px; }
    
    /* 分组表格优化 */
    .cbi-tblsection tbody tr {
        display: block;
        margin-bottom: 12px;
        border: 1px solid #ddd;
        border-radius: 6px;
        padding: 8px;
        background: #fafafa;
    }
    .cbi-tblsection tbody tr td {
        display: block;
        padding: 6px 4px;
        border: none !important;
        border-bottom: 1px solid #eee !important;
    }
    .cbi-tblsection tbody tr td:last-child { border-bottom: none !important; }
    .cbi-tblsection tbody tr td.cbi-section-actions { text-align: center; padding-top: 8px; }
    
    /* 设备选择框优化 */
    .device-list-box { max-height: 180px !important; }
    .device-container { max-height: 160px !important; }
    .device-item { font-size: 12px !important; padding: 3px 6px !important; }
    
    /* 日期选择优化 */
    .date-container { gap: 6px !important; }
    
    /* API测试区域优化 */
    .cbi-value-field > div[style*="display:flex"] { flex-wrap: wrap !important; }
    .cbi-value-field input[name="test_mac"] { width: 130px !important; max-width: 100% !important; }
    
    /* 状态显示区域优化 */
    .cbi-value-field > div[style*="background:#f5f5f5"] { padding: 8px !important; font-size: 12px !important; }
}

/* 超小屏幕优化 */
@media screen and (max-width: 480px) {
    .device-item { font-size: 11px !important; }
    .cbi-value-field input[name="test_mac"] { width: 100% !important; }
    .cbi-value { flex-direction: column; }
    .cbi-value-title { width: 100% !important; margin-bottom: 4px; }
    .cbi-value-field { width: 100% !important; }
}
</style>
]]
end

o = s:option(ListValue, "oui_mode", "OUI查询模式")
o:value("remote", "远程查询(默认)")
o:value("local", "本地数据库")
o.default = "remote"
o.description = "远程:按需查询,内存占用低;本地:使用下载的数据库,更快但占用~6MB内存"

o = s:option(ListValue, "remote_api", "远程API接口")
o:value("maclookup", "maclookup.app (JSON格式,推荐)")
o:value("macvendors", "macvendors.com (纯文本)")
o.default = "maclookup"
o.description = "选择远程查询使用的API接口"
o:depends("oui_mode", "remote")

-- OUI Status Display
o = s:option(DummyValue, "_oui_status", "当前状态")
o.rawhtml = true
o.cfgvalue = function(self, section)
    local html = "<div style='background:#f5f5f5;padding:10px;border-radius:4px;'>"
    local has_local = sys.call("test -f /usr/share/devicemaster/oui.txt") == 0
    if has_local then
        local size = sys.exec("du -sh /usr/share/devicemaster/oui.txt 2>/dev/null | cut -f1") or "?"
        local count = sys.exec("wc -l < /usr/share/devicemaster/oui.txt 2>/dev/null") or "0"
        html = html .. "<b>本地数据库:</b> <span style='color:green;'>已安装</span> (" .. size:gsub("\n", "") .. ", " .. count:gsub("\n", "") .. " 条记录)<br>"
    else
        html = html .. "<b>本地数据库:</b> <span style='color:#888;'>未安装</span><br>"
    end
    local cache_count = sys.exec("wc -l < /usr/share/devicemaster/oui_cache.txt 2>/dev/null") or "0"
    local cache_size = sys.exec("du -sh /usr/share/devicemaster/oui_cache.txt 2>/dev/null | cut -f1") or "0"
    html = html .. "<b>远程缓存:</b> " .. cache_count:gsub("\n", "") .. " 条记录 (" .. cache_size:gsub("\n", "") .. ")"
    html = html .. "</div>"
    return html
end

-- API Test
o = s:option(DummyValue, "_api_test_area", "API测试")
o.rawhtml = true
o.cfgvalue = function(self, section)
    local api_url = luci.dispatcher.build_url("admin", "network", "devicemaster", "api", "test_api")
    local html = "<div style='display:flex;align-items:center;gap:8px;flex-wrap:wrap;'>"
    html = html .. "<input type='text' id='test_mac_input' name='test_mac' value='00:11:22:33:44:55' style='width:200px;padding:4px 8px;border:1px solid #ccc;border-radius:4px;' />"
    html = html .. "<button type='button' id='test_api_btn' style='padding:4px 16px;background:#1976d2;color:white;border-radius:4px;border:none;cursor:pointer;' onclick='testOuiApi()'>测试API</button>"
    html = html .. "<span id='test_api_result'></span>"
    html = html .. "</div>"
    html = html .. "<script>"
    html = html .. "function testOuiApi(){"
    html = html .. "  var btn=document.getElementById('test_api_btn');"
    html = html .. "  var res=document.getElementById('test_api_result');"
    html = html .. "  var mac=document.getElementById('test_mac_input').value;"
    html = html .. "  btn.disabled=true;btn.textContent='测试中...';btn.style.background='#90a4ae';"
    html = html .. "  res.innerHTML='<span style=\"color:#888;font-size:0.85em;\">正在查询...</span>';"
    html = html .. "  var xhr=new XMLHttpRequest();"
    html = html .. "  xhr.open('POST','" .. api_url .. "',true);"
    html = html .. "  xhr.setRequestHeader('Content-Type','application/x-www-form-urlencoded');"
    html = html .. "  xhr.onreadystatechange=function(){"
    html = html .. "    if(xhr.readyState===4){"
    html = html .. "      btn.disabled=false;btn.textContent='测试API';btn.style.background='#1976d2';"
    html = html .. "      if(xhr.status===200){"
    html = html .. "        try{"
    html = html .. "          var d=JSON.parse(xhr.responseText);"
    html = html .. "          if(d.success){"
    html = html .. "            res.innerHTML='<span style=\"color:#2e7d32;font-weight:bold;\">✓ '+d.vendor+'</span>'"
    html = html .. "              +'<span style=\"color:#2e7d32;font-size:0.85em;margin-left:6px;\">通过</span>'"
    html = html .. "              +(d.time?'<span style=\"color:#888;font-size:0.8em;margin-left:6px;\">('+d.time+'ms)</span>':'');"
    html = html .. "          }else{"
    html = html .. "            res.innerHTML='<span style=\"color:#c62828;\">✗ '+(d.error||'测试失败')+'</span>';"
    html = html .. "          }"
    html = html .. "        }catch(e){res.innerHTML='<span style=\"color:#c62828;\">✗ 响应解析失败</span>';}"
    html = html .. "      }else{res.innerHTML='<span style=\"color:#c62828;\">✗ 请求失败</span>';}"
    html = html .. "    }"
    html = html .. "  };"
    html = html .. "  xhr.send('mac='+encodeURIComponent(mac));"
    html = html .. "}"
    html = html .. "</script>"
    return html
end

-- Download
o = s:option(DummyValue, "_download_area", "OUI数据库")
o.rawhtml = true
o.cfgvalue = function(self, section)
    local download_result = sys.exec("cat /tmp/oui_download_result.txt 2>/dev/null")
    local result_html = ""
    if download_result and download_result ~= "" then
        sys.exec("rm -f /tmp/oui_download_result.txt")
        local ok = download_result:match("安装成功")
        if ok then
            local size = download_result:match("文件大小:%s*(.+)")
            local count = download_result:match("记录数量:%s*(.+)")
            result_html = "<span style='color:#2e7d32;font-size:0.9em;margin-left:10px;'>✓ 已安装 " .. (size or ""):gsub("\n", "")
            if count then
                result_html = result_html .. " / " .. count:gsub("\n", "") .. "条</span>"
            end
        else
            result_html = "<span style='color:#c62828;font-size:0.9em;margin-left:10px;'>✗ 失败</span>"
        end
    end
    local html = "<div style='display:flex;align-items:center;gap:8px;'>"
    html = html .. "<a href='" .. dispatcher.build_url("admin", "network", "devicemaster", "download_oui") .. "' style='padding:4px 16px;background:#388e3c;color:white;border-radius:4px;text-decoration:none;'>下载并安装</a>"
    html = html .. "<span style='color:#888;font-size:0.85em;'>从IEEE下载完整OUI数据库</span>"
    html = html .. result_html
    html = html .. "</div>"
    return html
end

-- Clear Options
o = s:option(ListValue, "_clear_option", "清除选项")
o:value("cache", "清除远程缓存")
o:value("local", "清除本地数据库")
o:value("all", "清除全部")
o.default = "cache"

o = s:option(Button, "_clear", "执行清除")
o.inputtitle = "清除"
o.inputstyle = "reset"
o.write = function(self, section)
    local clear_opt = luci.http.formvalue("cbid.devicemaster." .. section .. "._clear_option") or "cache"
    if clear_opt == "cache" or clear_opt == "all" then
        sys.exec("rm -f /usr/share/devicemaster/oui_cache.txt")
    end
    if clear_opt == "local" or clear_opt == "all" then
        sys.exec("rm -f /usr/share/devicemaster/oui.txt")
    end
end

-- 底部间距
o = s:option(DummyValue, "_spacer", "")
o.rawhtml = true
o.cfgvalue = function(self, section)
    return '<div style="height:20px"></div>'
end

return m
