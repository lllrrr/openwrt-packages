-- Copyright 2024 System Tools Project
-- Licensed under the MIT License

module("luci.controller.systools", package.seeall)

function index()
    -- 主菜单
    entry({"admin", "systools"}, firstchild(), _("工具箱"), 60).dependent = false
    
    -- 网络向导分类
    entry({"admin", "systools", "wizard"}, firstchild(), _("网络向导"), 10)
    
    -- 上网设置向导
    entry({"admin", "systools", "wizard", "network_wizard"}, cbi("systools/network_wizard"), _("上网设置向导"), 1)
    
    -- IPv6 一键设置
    entry({"admin", "systools", "wizard", "ipv6"}, cbi("systools/ipv6"), _("IPv6 一键设置"), 2)
    
    -- 旁路由模式
    entry({"admin", "systools", "wizard", "side_route"}, cbi("systools/side_route"), _("旁路由模式"), 3)
    
    -- 设备管理
    entry({"admin", "systools", "wizard", "device_manager"}, cbi("systools/device_manager"), _("设备管理"), 4)
    
    -- 智能家居分类
    entry({"admin", "systools", "smarthome"}, firstchild(), _("🏠 智能家居"), 20)
    
    -- Home Assistant 管理（默认页）
    entry({"admin", "systools", "smarthome", "homeassistant"}, cbi("systools/homeassistant"), _("Home Assistant"), 1)
    
    -- HA 镜像管理
    entry({"admin", "systools", "smarthome", "images"}, cbi("systools/smarthome_images"), _("HA 镜像管理"), 2)
    
    -- HA 存储设置
    entry({"admin", "systools", "smarthome", "storage"}, cbi("systools/smarthome_storage"), _("HA 存储设置"), 3)
    
    -- HA 网络设置
    entry({"admin", "systools", "smarthome", "network"}, cbi("systools/smarthome_network"), _("HA 网络设置"), 4)
    
    -- 配置管理
    entry({"admin", "systools", "config"}, cbi("systools/config"), _("配置管理"), 80)

    -- 关于
    entry({"admin", "systools", "about"}, template("systools/about"), _("关于"), 90)
end
