--[[
LuCI - Lua Configuration Interface
Copyright 2019 lisaac <https://github.com/lisaac/luci-app-dockerman>
Modified with error handling for Docker service status
]]--

local http = require "luci.http"
local docker = require "luci.model.docker"

local m, s, o
local images, networks, containers, res

-- 创建 Docker 实例
local dk = docker.new()

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

    -- 获取 Docker 数据
    images, err = safe_docker_call(dk.images.list, dk.images)
    if not images then
        return nil, translate("Failed to get images: ") .. err
    end

    networks, err = safe_docker_call(dk.networks.list, dk.networks)
    if not networks then
        return nil, translate("Failed to get networks: ") .. err
    end

    containers, err = safe_docker_call(dk.containers.list, dk.containers, {
        query = {all = true}
    })
    if not containers then
        return nil, translate("Failed to get containers: ") .. err
    end

    -- 创建主表单
    m = SimpleForm("docker",
        translate("Docker - Containers"),
        translate("This page displays all containers that have been created on the connected docker host."))
    m.submit = false
    m.reset = false

    -- 状态显示部分
    s = m:section(SimpleSection)
    s.template = "dockerman/apply_widget"
    s.err = docker:read_status()
    s.err = s.err and s.err:gsub("\n","<br />"):gsub(" ","&#160;")
    if s.err then
        docker:clear_status()
    end

    -- 获取容器列表数据
    local function get_containers()
        local data = {}

        if type(containers) ~= "table" then
            return nil
        end

        for i, v in ipairs(containers) do
            local index = v.Id

            data[index] = {}
            data[index]["_selected"] = 0
            data[index]["_id"] = v.Id:sub(1,12)
            data[index]["_name"] = v.Names[1]:sub(2)
            data[index]["_status"] = v.Status

            if v.Status:find("^Up") then
                data[index]["_status"] = '<font color="green">'.. data[index]["_status"] .. "</font>"
            else
                data[index]["_status"] = '<font color="red">'.. data[index]["_status"] .. "</font>"
            end

            if (type(v.NetworkSettings) == "table" and type(v.NetworkSettings.Networks) == "table") then
                for networkname, netconfig in pairs(v.NetworkSettings.Networks) do
                    data[index]["_network"] = (data[index]["_network"] ~= nil and (data[index]["_network"] .." | ") or "").. networkname .. (netconfig.IPAddress ~= "" and (": " .. netconfig.IPAddress) or "")
                end
            end

            if v.Ports and next(v.Ports) ~= nil then
                data[index]["_ports"] = nil
                for _,v2 in ipairs(v.Ports) do
                    data[index]["_ports"] = (data[index]["_ports"] and (data[index]["_ports"] .. ", ") or "")
                        .. ((v2.PublicPort and v2.Type and v2.Type == "tcp") and ('<a href="javascript:void(0);" onclick="window.open((window.location.origin.match(/^(.+):\\d+$/) && window.location.origin.match(/^(.+):\\d+$/)[1] || window.location.origin) + \':\' + '.. v2.PublicPort ..', \'_blank\');">') or "")
                        .. (v2.PublicPort and (v2.PublicPort .. ":") or "")  .. (v2.PrivatePort and (v2.PrivatePort .."/") or "") .. (v2.Type and v2.Type or "")
                        .. ((v2.PublicPort and v2.Type and v2.Type == "tcp")and "</a>" or "")
                end
            end

            for ii,iv in ipairs(images) do
                if iv.Id == v.ImageID then
                    data[index]["_image"] = iv.RepoTags and iv.RepoTags[1] or (iv.RepoDigests[1]:gsub("(.-)@.+", "%1") .. ":<none>")
                end
            end

            data[index]["_image_id"] = v.ImageID:sub(8,20)
            data[index]["_command"] = v.Command
        end

        return data
    end

    local container_list = get_containers()

    -- 容器列表部分
    s = m:section(Table, container_list, translate("Containers overview"))
    s.addremove = false
    s.sectionhead = translate("Containers")
    s.sortable = false
    s.template = "cbi/tblsection"
    s.extedit = luci.dispatcher.build_url("admin", "docker", "container","%s")

    o = s:option(Flag, "_selected","")
    o.disabled = 0
    o.enabled = 1
    o.default = 0
    o.write = function(self, section, value)
        container_list[section]._selected = value
    end

    o = s:option(DummyValue, "_id", translate("ID"))
    o.width = "10%"

    o = s:option(DummyValue, "_name", translate("Container Name"))
    o.rawhtml = true

    o = s:option(DummyValue, "_status", translate("Status"))
    o.width = "15%"
    o.rawhtml = true

    o = s:option(DummyValue, "_network", translate("Network"))
    o.width = "15%"

    o = s:option(DummyValue, "_ports", translate("Ports"))
    o.width = "10%"
    o.rawhtml = true

    o = s:option(DummyValue, "_image", translate("Image"))
    o.width = "10%"

    o = s:option(DummyValue, "_command", translate("Command"))
    o.width = "20%"

    -- 操作按钮部分
    local start_stop_remove = function(m, cmd)
        local container_selected = {}

        for k in pairs(container_list) do
            if container_list[k]._selected == 1 then
                container_selected[#container_selected + 1] = container_list[k]._name
            end
        end

        if #container_selected > 0 then
            local success = true

            docker:clear_status()
            for _, cont in ipairs(container_selected) do
                docker:append_status("Containers: " .. cmd .. " " .. cont .. "...")
                local res = dk.containers[cmd](dk, {id = cont})
                if res and res.code >= 300 then
                    success = false
                    docker:append_status("code:" .. res.code.." ".. (res.body.message and res.body.message or res.message).. "\n")
                else
                    docker:append_status("done\n")
                end
            end

            if success then
                docker:clear_status()
            end

            luci.http.redirect(luci.dispatcher.build_url("admin/docker/containers"))
        end
    end

    s = m:section(Table,{{}})
    s.notitle = true
    s.rowcolors = false
    s.template = "cbi/nullsection"

    o = s:option(Button, "_new")
    o.inputtitle = translate("Add")
    o.template = "dockerman/cbi/inlinebutton"
    o.inputstyle = "add"
    o.forcewrite = true
    o.write = function(self, section)
        luci.http.redirect(luci.dispatcher.build_url("admin/docker/newcontainer"))
    end

    o = s:option(Button, "_start")
    o.template = "dockerman/cbi/inlinebutton"
    o.inputtitle = translate("Start")
    o.inputstyle = "apply"
    o.forcewrite = true
    o.write = function(self, section)
        start_stop_remove(m, "start")
    end

    o = s:option(Button, "_restart")
    o.template = "dockerman/cbi/inlinebutton"
    o.inputtitle = translate("Restart")
    o.inputstyle = "reload"
    o.forcewrite = true
    o.write = function(self, section)
        start_stop_remove(m, "restart")
    end

    o = s:option(Button, "_stop")
    o.template = "dockerman/cbi/inlinebutton"
    o.inputtitle = translate("Stop")
    o.inputstyle = "reset"
    o.forcewrite = true
    o.write = function(self, section)
        start_stop_remove(m, "stop")
    end

    o = s:option(Button, "_kill")
    o.template = "dockerman/cbi/inlinebutton"
    o.inputtitle = translate("Kill")
    o.inputstyle = "reset"
    o.forcewrite = true
    o.write = function(self, section)
        start_stop_remove(m, "kill")
    end

    o = s:option(Button, "_remove")
    o.template = "dockerman/cbi/inlinebutton"
    o.inputtitle = translate("Remove")
    o.inputstyle = "remove"
    o.forcewrite = true
    o.write = function(self, section)
        start_stop_remove(m, "remove")
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