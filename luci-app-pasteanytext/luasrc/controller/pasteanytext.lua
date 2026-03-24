module("luci.controller.pasteanytext", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/pasteanytext") then
        return
    end
    
    -- 确保 UCI 配置中有有效的 section
    local uci = require "luci.model.uci".cursor()
    local section_exists = false
    
    -- 尝试读取配置，如果不存在则创建默认配置
    uci:foreach("pasteanytext", "config", function(section)
        section_exists = true
    end)
    
    if not section_exists then
        -- 创建默认配置
        uci:set("pasteanytext", uci:add("pasteanytext", "config"), "file_path", "/etc/pasteanytext_donotdelete.txt")
        uci:set("pasteanytext", "@config[0]", "max_records", "1000")
        uci:save("pasteanytext")
        uci:commit("pasteanytext")
    end

    entry({"admin", "services", "pasteanytext"}, 
          alias("admin", "services", "pasteanytext", "index"), 
          _("PasteAnyText"), 
          10).dependent = true

    entry({"admin", "services", "pasteanytext", "index"}, 
          template("pasteanytext/index"), 
          _("PasteAnyText"), 
          10)
    
    -- API endpoints for text operations
    entry({"admin", "services", "pasteanytext", "send"}, call("send_text")).post = true
    entry({"admin", "services", "pasteanytext", "receive"}, call("receive_text")).get = true
    -- 原来冲突的 /config 拆分为：
    entry({"admin", "services", "pasteanytext", "config_get"}, call("get_config")).get = true
    entry({"admin", "services", "pasteanytext", "config_save"}, call("save_config")).post = true
end

function send_text()
    local uci = require "luci.model.uci".cursor()
    local file_path = uci:get("pasteanytext", "@config[0]", "file_path")
    if not file_path or file_path == "" then
        file_path = "/etc/pasteanytext_donotdelete.txt"
    end

    local content = luci.http.formvalue("content")
    if not content or content == "" then
        luci.http.status(400, "Bad Request")
        luci.http.prepare_content("application/json")
        luci.http.write('{"success": false, "message": "内容不能为空"}')
        return
    end

    local date_str = os.date("%Y-%m-%d %H:%M:%S")
    local record = string.format("[%s] %s", date_str, content) -- 不改 content，原样

    local file = io.open(file_path, "a+")
    if not file then
        luci.http.status(500, "Internal Server Error")
        luci.http.prepare_content("application/json")
        luci.http.write('{"success": false, "message": "无法写入文件"}')
        return
    end

    -- 移动到末尾，判断是否需要先补一个换行，确保“新记录从下一行开始”
    local size = file:seek("end") or 0
    if size > 0 then
        file:seek("end", -1)
        local last_char = file:read(1)
        file:seek("end")
        if last_char ~= "\n" then
            file:write("\n")
        end
    end

    file:write(record) -- 不额外追加 \n，避免篡改内容尾部形态
    file:close()

    luci.http.status(200, "OK")
    luci.http.prepare_content("application/json")
    luci.http.write('{"success": true, "message": "发送成功", "timestamp": "' .. date_str .. '"}')
end

function receive_text()
    local uci = require "luci.model.uci".cursor()
    local file_path = uci:get("pasteanytext", "@config[0]", "file_path")

    if not file_path or file_path == "" then
        file_path = "/etc/pasteanytext_donotdelete.txt"
    end

    local file = io.open(file_path, "r")
    if not file then
        luci.http.status(200, "OK")
        luci.http.prepare_content("application/json")
        luci.http.write('{"success": true, "count": 0, "records": []}')
        return
    end

    local data = file:read("*a") or ""
    file:close()

    local records = {}
    local current = nil

    -- 按行扫描：遇到时间戳开头就是新记录
    for line in (data .. "\n"):gmatch("(.-)\n") do
        if line:match("^%[%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%] ") then
            if current then
                table.insert(records, current)
            end
            current = line
        else
            if current then
                current = current .. "\n" .. line
            elseif line ~= "" then
                -- 兼容旧脏数据：文件开头不是时间戳也保留
                current = line
            end
        end
    end

    if current then
        table.insert(records, current)
    end

    -- 最新在前
    local reversed = {}
    for i = #records, 1, -1 do
        table.insert(reversed, records[i])
    end

    luci.http.status(200, "OK")
    luci.http.prepare_content("application/json")
    luci.http.write(
        '{"success": true, "count": ' .. tostring(#reversed) ..
        ', "records": ' .. luci.util.serialize_json(reversed) .. '}'
    )
end

function get_config()
    local uci = require "luci.model.uci".cursor()
    
    -- 确保配置 section 存在
    local section_exists = false
    uci:foreach("pasteanytext", "config", function(section)
        section_exists = true
    end)
    
    if not section_exists then
        -- 创建默认配置
        uci:set("pasteanytext", uci:add("pasteanytext", "config"), "file_path", "/etc/pasteanytext_donotdelete.txt")
        uci:set("pasteanytext", "@config[0]", "max_records", "1000")
        uci:save("pasteanytext")
        uci:commit("pasteanytext")
    end
    
    local file_path = uci:get("pasteanytext", "@config[0]", "file_path")
    local max_records = uci:get("pasteanytext", "@config[0]", "max_records")
    
    -- 如果配置不存在或为空，使用默认值
    if not file_path or file_path == "" then
        file_path = "/etc/pasteanytext_donotdelete.txt"
    end
    
    if not max_records or max_records == "" then
        max_records = "1000"
    end
    
    luci.http.status(200, "OK")
    luci.http.prepare_content("application/json")
    luci.http.write(string.format('{"success": true, "file_path": "%s", "max_records": "%s"}', 
                                  file_path, 
                                  max_records))
end

function save_config()
    local uci = require "luci.model.uci".cursor()
    local file_path = luci.http.formvalue("file_path") or "/etc/pasteanytext_donotdelete.txt"
    local max_records = luci.http.formvalue("max_records") or "1000"

    -- 确保 max_records 在合法范围内
    local max_num = tonumber(max_records)
    if not max_num or max_num < 1 or max_num > 10000 then
        max_num = 1000
    end

    -- 保存配置
    uci:set("pasteanytext", "@config[0]", "file_path", file_path)
    uci:set("pasteanytext", "@config[0]", "max_records", tostring(max_num))
    uci:save("pasteanytext")
    uci:commit("pasteanytext")

    luci.http.status(200, "OK")
    luci.http.prepare_content("application/json")
    luci.http.write('{"success": true, "message": "配置已保存"}')
end
