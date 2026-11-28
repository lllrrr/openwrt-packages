-- 容错读取 AdGuard Home 的 YAML 配置。
-- 只实现插件需要的“按路径取标量 / 取列表 / 写区块内标量”，
-- 不依赖固定缩进，避免 AGH 升级重新序列化后静默读不到值。
-- nixio 在路由器上一定存在；CI 里没有，降级后仅纯文本函数可用，便于单元测试。
local ok, fs = pcall(require, "nixio.fs")
if not ok then
    fs = nil
end

local M = {}

local function split_lines(data)
    local lines = {}
    local pos = 1
    while true do
        local start = data:find("\n", pos, true)
        if not start then
            if pos <= #data then
                lines[#lines + 1] = data:sub(pos)
            end
            return lines
        end
        lines[#lines + 1] = data:sub(pos, start - 1)
        pos = start + 1
    end
end

local function indent_of(line)
    local lead = line:match("^([ \t]*)") or ""
    local width = 0
    for i = 1, #lead do
        width = width + (lead:sub(i, i) == "\t" and 4 or 1)
    end
    return width
end

-- 去掉行内注释，但保留引号内的 #
local function strip_comment(value)
    local quote
    for i = 1, #value do
        local c = value:sub(i, i)
        if quote then
            if c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == "#" and (i == 1 or value:sub(i - 1, i - 1):match("%s")) then
            return value:sub(1, i - 1)
        end
    end
    return value
end

local function clean_scalar(value)
    value = strip_comment(value or ""):match("^%s*(.-)%s*$") or ""
    local quoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
    return quoted or value
end

local function split_entry(line)
    local body = line:match("^%s*(.-)%s*$") or ""
    if body == "" or body:sub(1, 1) == "#" or body:sub(1, 1) == "-" then
        return nil
    end
    return body:match("^([%w_%.%-]+):%s*(.*)$")
end

-- 按层级路径定位目标键，返回行号、缩进、原始值与去注释值
local function locate(lines, keys)
    local stack = {}
    for index, line in ipairs(lines) do
        local indent = indent_of(line)
        local key, rest = split_entry(line)
        if key then
            while #stack > 0 and indent <= stack[#stack].indent do
                table.remove(stack)
            end
            stack[#stack + 1] = { indent = indent, key = key }
            if #stack == #keys then
                local matched = true
                for depth = 1, #keys do
                    if stack[depth].key ~= keys[depth] then
                        matched = false
                        break
                    end
                end
                if matched then
                    return index, indent, rest, clean_scalar(rest)
                end
            end
        end
    end
    return nil
end

function M.scalar_text(data, ...)
    local keys = { ... }
    local index, _, _, value = locate(split_lines(data or ""), keys)
    if not index or value == "" then
        return nil
    end
    return value
end

function M.scalar(path, ...)
    if not fs then
        return nil
    end
    local data = fs.readfile(path)
    if not data then
        return nil
    end
    return M.scalar_text(data, ...)
end

-- 读取列表：支持 "[a, b]"、单行标量，以及缩进不固定的 "- item"
function M.list_text(data, ...)
    local lines = split_lines(data or "")
    local index, indent, rest, value = locate(lines, { ... })
    if not index then
        return ""
    end

    local items = {}
    local inline = rest and rest:match("^%[(.*)%]%s*$")
    if inline then
        for item in (inline .. ","):gmatch("([^,]*),") do
            item = clean_scalar(item)
            if item ~= "" then
                items[#items + 1] = item
            end
        end
        return table.concat(items, " ")
    end
    if value ~= "" then
        return value
    end

    for i = index + 1, #lines do
        local line = lines[i]
        local body = line:match("^%s*(.-)%s*$") or ""
        if body ~= "" and body:sub(1, 1) ~= "#" then
            local item_indent = indent_of(line)
            if item_indent <= indent and split_entry(line) then
                break
            end
            local item = body:match("^%-%s*(.*)$")
            if item then
                item = clean_scalar(item)
                if item ~= "" then
                    items[#items + 1] = item
                end
            end
        end
    end
    return table.concat(items, " ")
end

-- 现有列表键（upstream_dns）位于 dns 区块下，先按区块取，取不到再退回顶层
function M.list(path, key)
    if not fs then
        return ""
    end
    local data = fs.readfile(path) or ""
    local text = M.list_text(data, "dns", key)
    if text == "" then
        text = M.list_text(data, key)
    end
    return text
end

function M.safe_search_enabled(path)
    return M.scalar(path, "filtering", "safe_search", "enabled") == "true"
end

-- 只替换区块内已存在的键，保持文件其余内容与缩进风格不变；返回新文本，未命中返回 nil
function M.set_section_text(data, section, key, value)
    local lines = split_lines(data or "")
    local output = {}
    local section_indent
    local replaced = false
    for _, line in ipairs(lines) do
        local indent = indent_of(line)
        local name, rest = split_entry(line)
        if section_indent == nil then
            if name == section and (rest or ""):match("^%s*$") then
                section_indent = indent
            end
            output[#output + 1] = line
        elseif not replaced and indent > section_indent and name == key then
            local lead = line:match("^([ \t]*)") or ""
            output[#output + 1] = lead .. key .. ": " .. value
            replaced = true
        else
            output[#output + 1] = line
        end
    end

    if not replaced then
        return nil
    end

    local text = table.concat(output, "\n")
    if data:sub(-1) == "\n" then
        text = text .. "\n"
    end
    return text
end

function M.set_section_scalar(path, section, key, value)
    if not fs then
        return false
    end
    local data = fs.readfile(path)
    if not data then
        return false
    end
    local text = M.set_section_text(data, section, key, value)
    if not text then
        return false
    end
    return fs.writefile(path, text) and true or false
end

return M
