module("luci.controller.backup", package.seeall)

local uci = require("luci.model.uci").cursor()
local fs = require("nixio.fs")
local json = require("luci.jsonc")
local http = require("luci.http")
local dispatcher = require("luci.dispatcher")

function index()
    entry({"admin", "system", "backup"}, 
          firstchild(),  
          _("智能备份恢复"), 
          60).dependent = false
    
    entry({"admin", "system", "backup", "execute"}, 
          call("action_backup"), 
          _("执行备份"), 
          10).dependent = false
    
    entry({"admin", "system", "backup", "settings"}, 
          call("action_settings"), 
          _("设置"), 
          20).dependent = false

    entry({"admin", "system", "backup", "restore"}, 
          call("action_restore"), 
          _("执行恢复"), 
          15).dependent = false
end

function action_backup()
    local tasks = get_tasks_from_uci()
    local password = get_password_from_uci()
    
    if http.formvalue("backup") then
        handle_backup_request(tasks, password)
        return
    end
    
    local data = {
        tasks = tasks,
        password = password
    }
    
    http.prepare_content("text/html; charset=utf-8")
    luci.template.render("backup/backup", data)
end

function action_settings()
    if http.formvalue("save") then
        handle_settings_save()
        return
    end
    
    local tasks = get_tasks_from_uci()
    local password = get_password_from_uci()
    
    local data = {
        tasks = tasks,
        password = password
    }
    
    http.prepare_content("text/html; charset=utf-8")
    luci.template.render("backup/settings", data)
end

function action_restore()
    local password = get_password_from_uci()
    local default_dir = "/tmp/backup"
    
    if http.formvalue("restore") then
        handle_restore_request(password)
        return
    end
    
    local scan_dir = http.formvalue("scan_dir") or default_dir
    local files = list_backup_files(scan_dir)
    
    local data = {
        password = password,
        current_dir = scan_dir,
        files = files
    }
    
    http.prepare_content("text/html; charset=utf-8")
    luci.template.render("backup/restore", data)
end

function get_tasks_from_uci()
    local tasks = {}
    uci:foreach("backup", "task", function(section)
        local files = {}
        if section.files then
            for file in string.gmatch(section.files, "[^%s]+") do
                table.insert(files, file)
            end
        end
        table.insert(tasks, {
            name = section.name,
            files = files
        })
    end)
    return tasks
end

function get_password_from_uci()
    local password = uci:get("backup", "config", "password")
    return password or ""
end

function save_tasks_to_uci(tasks)
    uci:delete_all("backup", "task")
    for i, task in ipairs(tasks) do
        local section = uci:add("backup", "task")
        uci:set("backup", section, "name", task.name)
        if task.files and #task.files > 0 then
            uci:set("backup", section, "files", table.concat(task.files, " "))
        end
    end
    uci:commit("backup")
end

function save_password_to_uci(password)
    -- 保存密码到 UCI 配置文件
    uci:set("backup", "config", "password", password)
    uci:commit("backup")
    
    -- 同时保存密码到 /usr/bin/backup-password 文件
    save_password_to_file(password)
end

-- 新增函数：保存密码到文件
function save_password_to_file(password)
    local password_file = "/usr/bin/backup-password"
    local backup_file = password_file .. ".bak"
    
    -- 如果原文件存在，先备份
    if fs.access(password_file) then
        fs.copy(password_file, backup_file)
    end
    
    -- 写入新密码到文件
    local fd = io.open(password_file, "w")
    if fd then
        fd:write(password)
        fd:write("\n")  -- 添加换行符，使文件格式更规范
        fd:close()
        
        -- 设置正确的权限 (755 或根据实际需求)
        os.execute("chmod 755 " .. password_file)
        
        return true
    else
        -- 写入失败，尝试恢复备份
        if fs.access(backup_file) then
            fs.copy(backup_file, password_file)
        end
        return false
    end
end

function handle_settings_save()
    local success = true
    local message = "设置保存成功"
    local errors = {}
    
    local password = http.formvalue("password")
    if password then
        -- 先保存到 UCI
        uci:set("backup", "config", "password", password)
        local uci_ok, uci_err = pcall(function() uci:commit("backup") end)
        
        if not uci_ok then
            success = false
            table.insert(errors, "UCI密码保存失败")
        else
            -- UCI保存成功后，再保存到文件
            local file_ok = save_password_to_file(password)
            if not file_ok then
                success = false
                table.insert(errors, "密码文件写入失败")
            end
        end
    end
    
    local tasks_json = http.formvalue("tasks")
    if tasks_json and tasks_json ~= "" then
        local ok, tasks = pcall(json.parse, tasks_json)
        if ok and tasks then
            local save_ok, save_err = pcall(function() save_tasks_to_uci(tasks) end)
            if not save_ok then
                success = false
                table.insert(errors, "任务保存失败")
            end
        else
            success = false
            table.insert(errors, "任务数据格式错误")
        end
    end
    
    if #errors > 0 then
        message = table.concat(errors, "；")
    end
    
    http.prepare_content("application/json")
    http.write(json.stringify({success = success, message = message}))
end

function handle_backup_request(tasks, password)
    local selected_tasks = {}
    local encrypt = http.formvalue("encrypt") == "1"
    
    local selected_files = http.formvalue("selected_files")
    if selected_files then
        if type(selected_files) ~= "table" then
            selected_files = {selected_files}
        end
        
        for _, file in ipairs(selected_files) do
            local task_name, file_path = file:match("^([^:]+):(.+)$")
            if task_name then
                local found = false
                for _, task in ipairs(selected_tasks) do
                    if task.name == task_name then
                        table.insert(task.files, file_path)
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(selected_tasks, {
                        name = task_name,
                        files = {file_path}
                    })
                end
            end
        end
    end
    
    local backup_script = "/etc/backup/backup.sh"
    local post_data = {
        tasks = selected_tasks,
        encrypt = encrypt,
        password = password
    }
    
    local json_str = json.stringify(post_data)
    local tmp_file = "/tmp/backup_data_" .. os.time() .. ".json"
    
    local tmp_fd = io.open(tmp_file, "w")
    if tmp_fd then
        tmp_fd:write(json_str)
        tmp_fd:close()
    end
    
    local command = string.format("cat %s | %s", tmp_file, backup_script)
    local handle = io.popen(command)
    local response = handle:read("*a")
    handle:close()
    
    os.remove(tmp_file)
    
    if not response or response == "" then
        response = json.stringify({success = false, message = "备份脚本执行失败"})
    end
    
    http.prepare_content("application/json")
    http.write(response)
end

function list_backup_files(dir)
    local files = {}
    if not fs.access(dir) then
        return files
    end
    
    for entry in fs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = dir .. "/" .. entry
            local stat = fs.stat(full_path)
            if stat and stat.type == "reg" then
                if entry:match("%.tar%.gz$") or entry:match("%.tar%.gz%.gpg$") then
                    table.insert(files, {
                        name = entry,
                        path = full_path,
                        size = stat.size,
                        mtime = stat.mtime
                    })
                end
            end
        end
    end
    return files
end

function handle_restore_request(password)
    local selected_files = http.formvalue("restore_files")
    local decrypt = http.formvalue("decrypt") == "1"
    
    if not selected_files then
        http.prepare_content("application/json")
        http.write(json.stringify({success = false, message = "未选择任何文件"}))
        return
    end
    
    if type(selected_files) ~= "table" then
        selected_files = {selected_files}
    end
    
    local restore_script = "/etc/backup/restore.sh"
    local post_data = {
        files = selected_files,
        decrypt = decrypt,
        password = password
    }
    
    local json_str = json.stringify(post_data)
    local tmp_file = "/tmp/restore_data_" .. os.time() .. ".json"
    
    local tmp_fd = io.open(tmp_file, "w")
    if tmp_fd then
        tmp_fd:write(json_str)
        tmp_fd:close()
    end
    
    local command = string.format("cat %s | %s", tmp_file, restore_script)
    local handle = io.popen(command)
    local response = handle:read("*a")
    handle:close()
    
    os.remove(tmp_file)
    
    if not response or response == "" then
        response = json.stringify({success = false, message = "恢复脚本执行失败或无输出"})
    end
    
    http.prepare_content("application/json")
    http.write(response)
end