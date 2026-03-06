--[[
LuCI - Lua Configuration Interface
Copyright 2019 lisaac <https://github.com/lisaac/luci-app-dockerman>
Modified with error handling for Docker service status
]]--

local http = require "luci.http"
local docker = require "luci.model.docker"

local m, s, o
local networks, dk, res

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

    -- 获取网络列表
    networks, err = safe_docker_call(dk.networks.list, dk.networks)
    if not networks then
        return nil, translate("Failed to get networks: ") .. err
    end

    -- 获取网络数据
    local function get_networks()
        local data = {}

        if type(networks) ~= "table" then
            return nil
        end

        for i, v in ipairs(networks) do
            local index = v.Created .. v.Id

            data[index] = {}
            data[index]["_selected"] = 0
            data[index]["_id"] = v.Id:sub(1,12)
            data[index]["_name"] = v.Name
            data[index]["_driver"] = v.Driver

            if v.Driver == "bridge" then
                data[index]["_interface"] = v.Options["com.docker.network.bridge.name"] or "docker0"
            elseif v.Driver == "macvlan" then
                data[index]["_interface"] = v.Options.parent or "N/A"
            else
                data[index]["_interface"] = "N/A"
            end

            data[index]["_subnet"] = v.IPAM and v.IPAM.Config and v.IPAM.Config[1] and v.IPAM.Config[1].Subnet or "N/A"
            data[index]["_gateway"] = v.IPAM and v.IPAM.Config and v.IPAM.Config[1] and v.IPAM.Config[1].Gateway or "N/A"
        end

        return data
    end

    local network_list = get_networks()

    -- 创建主表单
    m = SimpleForm("docker",
        translate("Docker - Networks"),
        translate("This page displays all docker networks that have been created on the connected docker host."))
    m.submit = false
    m.reset = false

    -- 网络列表部分
    s = m:section(Table, network_list, translate("Networks overview"))
    s.nodescr = true

    o = s:option(Flag, "_selected","")
    o.template = "dockerman/cbi/xfvalue"
    o.disabled = 0
    o.enabled = 1
    o.default = 0
    o.render = function(self, section, scope)
        self.disable = 0
        if network_list[section]["_name"] == "bridge" or 
           network_list[section]["_name"] == "none" or 
           network_list[section]["_name"] == "host" then
            self.disable = 1
        end
        Flag.render(self, section, scope)
    end
    o.write = function(self, section, value)
        network_list[section]._selected = value
    end

    o = s:option(DummyValue, "_id", translate("ID"))

    o = s:option(DummyValue, "_name", translate("Network Name"))

    o = s:option(DummyValue, "_driver", translate("Driver"))

    o = s:option(DummyValue, "_interface", translate("Parent Interface"))

    o = s:option(DummyValue, "_subnet", translate("Subnet"))

    o = s:option(DummyValue, "_gateway", translate("Gateway"))

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

    o = s:option(Button, "_new")
    o.inputtitle = translate("New")
    o.template = "dockerman/cbi/inlinebutton"
    o.notitle = true
    o.inputstyle = "add"
    o.forcewrite = true
    o.write = function(self, section)
        luci.http.redirect(luci.dispatcher.build_url("admin/docker/newnetwork"))
    end

    o = s:option(Button, "_remove")
    o.inputtitle = translate("Remove")
    o.template = "dockerman/cbi/inlinebutton"
    o.inputstyle = "remove"
    o.forcewrite = true
    o.write = function(self, section)
        local network_selected = {}
        local network_name_selected = {}
        local network_driver_selected = {}

        for k in pairs(network_list) do
            if network_list[k]._selected == 1 then
                network_selected[#network_selected + 1] = network_list[k]._id
                network_name_selected[#network_name_selected + 1] = network_list[k]._name
                network_driver_selected[#network_driver_selected + 1] = network_list[k]._driver
            end
        end

        if next(network_selected) ~= nil then
            local success = true
            docker:clear_status()

            for ii, net in ipairs(network_selected) do
                docker:append_status("Networks: " .. "remove" .. " " .. net .. "...")
                local res = dk.networks["remove"](dk, {id = net})

                if res and res.code >= 300 then
                    docker:append_status("code:" .. res.code.." ".. (res.body.message and res.body.message or res.message).. "\n")
                    success = false
                else
                    docker:append_status("done\n")
                    if network_driver_selected[ii] == "macvlan" then
                        docker.remove_macvlan_interface(network_name_selected[ii])
                    end
                end
            end

            if success then
                docker:clear_status()
            end
            luci.http.redirect(luci.dispatcher.build_url("admin/docker/networks"))
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