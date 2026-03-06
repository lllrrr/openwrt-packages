--[[
LuCI - Lua Configuration Interface
Copyright 2019 lisaac <https://github.com/lisaac/luci-app-dockerman>
Modified with error handling for Docker service status
]]--

local http = require "luci.http"
local docker = require "luci.model.docker"

local m, s, o
local volumes, containers, dk

-- 创建 Docker 实例
dk = docker.new()

-- 检查 Docker 服务是否可用
local function check_docker_status()
    local ping_res = dk:_ping()
    if ping_res.code ~= 200 then
        return false, translate("Cannot connect to Docker daemon. Is the docker daemon running?")
    end
    return true
end

-- 安全的 Docker API 调用
local function safe_docker_call(func, ...)
    local res = func(...)
    if res.code >= 300 then
        return nil, res.body.message or res.message or translate("Unknown Docker API error")
    end
    return res.body
end

-- 主执行逻辑
local function main()
    -- 检查 Docker 状态
    local ok, err = check_docker_status()
    if not ok then
        local error_form = SimpleForm("docker", translate("Docker Error"), err)
        error_form.reset = false
        error_form.submit = false
        return error_form
    end

    -- 获取卷列表
    local volumes_res, err = safe_docker_call(dk.volumes.list, dk.volumes)
    if not volumes_res then
        return nil, translate("Failed to get volumes: ") .. err
    end
    volumes = volumes_res.Volumes or {}

    -- 获取容器列表
    local containers_res, err = safe_docker_call(dk.containers.list, dk.containers, {
        query = {all = true}
    })
    if not containers_res then
        return nil, translate("Failed to get containers: ") .. err
    end
    containers = containers_res

    -- 获取卷数据
    local function get_volumes()
        local data = {}
        
        if type(volumes) ~= "table" then
            return data
        end

        for i, v in ipairs(volumes) do
            local index = v.Name
            data[index] = {}
            data[index]["_selected"] = 0
            data[index]["_nameraw"] = v.Name
            data[index]["_name"] = v.Name:sub(1,12)

            -- 查找使用该卷的容器
            if containers and type(containers) == "table" then
                for ci, cv in ipairs(containers) do
                    if cv.Mounts and type(cv.Mounts) == "table" then
                        for vi, vv in ipairs(cv.Mounts) do
                            if v.Name == vv.Name then
                                data[index]["_containers"] = (data[index]["_containers"] and (data[index]["_containers"] .. " | ") or "")..
                                '<a href='..luci.dispatcher.build_url("admin/docker/container/"..cv.Id)..' class="dockerman_link" title="'..translate("Container detail")..'">'.. (cv.Names and cv.Names[1] and cv.Names[1]:sub(2) or cv.Id:sub(1,12))..'</a>'
                            end
                        end
                    end
                end
            end

            data[index]["_driver"] = v.Driver or "N/A"
            
            -- 处理挂载点路径
            if v.Mountpoint then
                data[index]["_mountpoint"] = ""
                for v1 in v.Mountpoint:gmatch('[^/]+') do
                    if v1 == index then 
                        data[index]["_mountpoint"] = data[index]["_mountpoint"] .."/" .. v1:sub(1,12) .. "..."
                    else
                        data[index]["_mountpoint"] = data[index]["_mountpoint"] .."/".. v1
                    end
                end
            else
                data[index]["_mountpoint"] = "N/A"
            end

            data[index]["_created"] = v.CreatedAt or "N/A"
        end

        return data
    end

    local volume_list = get_volumes()

    -- 创建主表单
    m = SimpleForm("docker", translate("Docker - Volumes"),
        translate("This page displays all docker volumes that have been created on the connected docker host."))
    m.submit = false
    m.reset = false

    -- 卷列表部分
    s = m:section(Table, volume_list, translate("Volumes overview"))

    o = s:option(Flag, "_selected","")
    o.disabled = 0
    o.enabled = 1
    o.default = 0
    o.write = function(self, section, value)
        volume_list[section]._selected = value
    end

    o = s:option(DummyValue, "_name", translate("Name"))

    o = s:option(DummyValue, "_driver", translate("Driver"))

    o = s:option(DummyValue, "_containers", translate("Containers"))
    o.rawhtml = true

    o = s:option(DummyValue, "_mountpoint", translate("Mount Point"))

    o = s:option(DummyValue, "_created", translate("Created"))

    -- 状态显示部分
    s = m:section(SimpleSection)
    s.template = "dockerman/apply_widget"
    s.err = docker:read_status()
    s.err = s.err and s.err:gsub("\n","<br />"):gsub(" ","&#160;")
    if s.err then
        docker:clear_status()
    end

    -- 操作按钮部分
    s = m:section(Table,{{}})
    s.notitle = true
    s.rowcolors = false
    s.template = "cbi/nullsection"

    o = s:option(Button, "remove")
    o.inputtitle = translate("Remove")
    o.template = "dockerman/cbi/inlinebutton"
    o.inputstyle = "remove"
    o.forcewrite = true
    o.write = function(self, section)
        local volume_selected = {}

        for k in pairs(volume_list) do
            if volume_list[k]._selected == 1 then
                volume_selected[#volume_selected+1] = k
            end
        end

        if next(volume_selected) ~= nil then
            local success = true
            docker:clear_status()
            
            for _, vol in ipairs(volume_selected) do
                docker:append_status("Volumes: " .. "remove" .. " " .. vol .. "...")
                local msg = dk.volumes["remove"](dk, {id = vol})
                
                if msg.code ~= 204 then
                    docker:append_status("code:" .. msg.code.." ".. (msg.body.message and msg.body.message or msg.message).. "\n")
                    success = false
                else
                    docker:append_status("done\n")
                end
            end

            if success then
                docker:clear_status()
            end
            luci.http.redirect(luci.dispatcher.build_url("admin/docker/volumes"))
        end
    end

    return m
end

-- 执行主函数并处理错误
local ok, err_or_form = pcall(main)
if not ok then
    -- 处理运行时错误
    local error_form = SimpleForm("docker", translate("Runtime Error"), 
        translate("An unexpected error occurred: ") .. tostring(err_or_form))
    error_form.reset = false
    error_form.submit = false
    return error_form
elseif type(err_or_form) == "string" then
    -- 处理返回的错误消息
    local error_form = SimpleForm("docker", translate("Docker Error"), err_or_form)
    error_form.reset = false
    error_form.submit = false
    return error_form
else
    -- 返回正常表单
    return err_or_form or m
end