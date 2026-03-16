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
    local backup_dir = get_backup_dir_from_uci()
    
    if http.formvalue("backup") then
        handle_backup_request(tasks, password, backup_dir)
        return
    end
    
    local data = {
        tasks = tasks,
        password = password,
        backup_dir = backup_dir
    }
    
    http.prepare_content("text/html; charset=utf-8")
    luci.template.render("backup/backup", data)
end

function action_settings()
    -- 如果是磁盘空间检查请求
    if http.formvalue("check_disk") == "1" then
        local dir = http.formvalue("dir")
        if not dir or dir == "" then
            dir = "/tmp/backup"
        end
        
        local free_space = "未知"
        
        -- 创建目录（如果不存在）
        if not fs.access(dir) then
            fs.mkdir(dir)
        end
        
        -- 获取磁盘空间
        local handle = io.popen("df -h " .. dir .. " 2>/dev/null | awk 'NR==2 {print $4}'")
        if handle then
            local result = handle:read("*a")
            handle:close()
            
            if result and result ~= "" then
                free_space = result:gsub("%s+", "")
            else
                -- 备选方案：尝试获取根分区的空间
                handle = io.popen("df -h / 2>/dev/null | awk 'NR==2 {print $4}'")
                if handle then
                    result = handle:read("*a")
                    handle:close()
                    if result and result ~= "" then
                        free_space = result:gsub("%s+", "") .. " (根分区)"
                    end
                end
            end
        end
        
        http.prepare_content("application/json")
        http.write(json.stringify({free_space = free_space}))
        return
    end
    
    if http.formvalue("save") then
        handle_settings_save()
        return
    end
    
    local tasks = get_tasks_from_uci()
    local password = get_password_from_uci()
    local backup_dir = get_backup_dir_from_uci()
    
    -- 获取当前目录的可用空间（页面加载时）
    local free_space = "未知"
    if backup_dir and backup_dir ~= "" then
        local handle = io.popen("df -h " .. backup_dir .. " 2>/dev/null | awk 'NR==2 {print $4}'")
        if handle then
            local result = handle:read("*a")
            handle:close()
            if result and result ~= "" then
                free_space = result:gsub("%s+", "")
            end
        end
    end
    
    local data = {
        tasks = tasks,
        password = password,
        backup_dir = backup_dir,
        free_space = free_space
    }
    
    http.prepare_content("text/html; charset=utf-8")
    luci.template.render("backup/settings", data)
end

function action_restore()
    local password = get_password_from_uci()
    local default_dir = get_backup_dir_from_uci() or "/tmp/backup"
    
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

function get_backup_dir_from_uci()
    local backup_dir = uci:get("backup", "config", "backup_dir")
    return backup_dir or "/tmp/backup"
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
    uci:set("backup", "config", "password", password)
    uci:commit("backup")
    save_password_to_file(password)
end

function save_backup_dir_to_uci(backup_dir)
    if backup_dir and backup_dir ~= "" then
        uci:set("backup", "config", "backup_dir", backup_dir)
    else
        uci:delete("backup", "config", "backup_dir")
    end
    uci:commit("backup")
end

function save_password_to_file(password)
    local password_file = "/usr/bin/backup-password"
    local backup_file = password_file .. ".bak"
    
    if fs.access(password_file) then
        fs.copy(password_file, backup_file)
    end
    
    local fd = io.open(password_file, "w")
    if fd then
        fd:write(password)
        fd:write("\n")
        fd:close()
        os.execute("chmod 755 " .. password_file)
        return true
    else
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
        uci:set("backup", "config", "password", password)
        local uci_ok, uci_err = pcall(function() uci:commit("backup") end)
        
        if not uci_ok then
            success = false
            table.insert(errors, "UCI密码保存失败")
        else
            local file_ok = save_password_to_file(password)
            if not file_ok then
                success = false
                table.insert(errors, "密码文件写入失败")
            end
        end
    end
    
    local backup_dir = http.formvalue("backup_dir")
    if backup_dir then
        local dir_ok, dir_err = pcall(function() save_backup_dir_to_uci(backup_dir) end)
        if not dir_ok then
            success = false
            table.insert(errors, "备份目录保存失败")
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

function handle_backup_request(tasks, password, backup_dir)
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
        password = password,
        backup_dir = backup_dir
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