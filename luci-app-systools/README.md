# luci-app-systools - OpenWrt 工具箱插件

一个功能丰富的 OpenWrt LuCI 插件，集成网络配置向导和智能家居管理工具，提供直观的 Web 界面操作。

## ✨ 插件简介

luci-app-systools 是专为 OpenWrt 设计的系统工具箱插件，涵盖网络配置和智能家居两大核心领域。通过图形化向导界面，让复杂的网络配置变得简单易用；同时提供完整的 Home Assistant 容器管理能力，支持镜像加速、存储迁移等高级功能。

**主要特点：**
- 🎯 向导式配置，降低使用门槛
- 🏠 深度集成智能家居管理
- 🎨 Argon 主题深度适配，支持暗色模式
- 📦 纯脚本/Lua 实现，架构无关，全平台通用
- 🔧 多版本兼容（24.12 / 25.12）

## 📋 功能列表（8大功能）

### 🌐 网络向导类

| 序号 | 功能 | 说明 |
|------|------|------|
| 1 | **上网设置向导** | 步骤式引导配置上网方式，支持 PPPoE / DHCP / 静态IP |
| 2 | **IPv6 一键设置** | 一键切换 IPv6 模式，支持 Native / 6to4 / 6in4 / 中继 / 禁用 |
| 3 | **旁路由模式** | 全自动检测网络环境，一键切换主路由 / 旁路由模式 |
| 4 | **设备管理** | 查看已连接设备列表，修改设备备注名，绑定静态 IP 地址 |

### 🏠 智能家居类

| 序号 | 功能 | 说明 |
|------|------|------|
| 5 | **Home Assistant 管理** | HA 容器状态监控、启停控制、日志查看、配置备份 |
| 6 | **HA 镜像管理** | Docker 镜像列表、拉取（含国内加速源）、删除、镜像源配置 |
| 7 | **HA 存储设置** | Docker 数据目录迁移到 U 盘，存储挂载管理，空间查看 |
| 8 | **HA 网络设置** | 常用端口快捷管理、mDNS 服务开关、UPnP 服务开关 |

## 📦 安装方法

### OpenWrt 24.12（ipk 格式）

```bash
# 上传 ipk 文件到路由器后执行
opkg update
opkg install luci-app-systools_1.0.0-1_all.ipk
```

### OpenWrt 25.12（apk 格式）

```bash
# 上传 apk 文件到路由器后执行
apk update
apk add luci-app-systools-1.0.0-r0.apk --allow-untrusted
```

## 📍 菜单位置

安装完成后，刷新 LuCI 页面，在菜单中找到：

**顶级菜单 **工具箱****

## ✅ 支持版本

| OpenWrt 版本 | 包格式 | 架构 |
|-------------|--------|------|
| 24.12 | ipk | all（架构无关） |
| 25.12 | apk | all（架构无关） |
| SNAPSHOT | ipk/apk | all（架构无关） |

## 🎨 主题兼容

- ✅ **官方 Bootstrap 主题** - 完全兼容
- ✅ **Argon 主题** - 深度适配，支持亮色/暗色模式
- ✅ 移动端响应式布局

## 🔧 开发

### 目录结构

```
luci-app-systools/
├── Makefile                    # OpenWrt 包定义
├── README.md                   # 项目说明
├── CHANGES.md                  # 变更日志
├── LICENSE                     # 许可证
├── .gitignore
├── .github/
│   └── workflows/
│       └── build.yml           # GitHub Actions 云编译
├── luasrc/
│   ├── controller/
│   │   └── systools.lua        # 菜单注册和路由
│   ├── model/cbi/systools/     # CBI 模型（页面）
│   │   ├── network_wizard.lua
│   │   ├── ipv6.lua
│   │   ├── side_route.lua
│   │   ├── device_manager.lua
│   │   ├── homeassistant.lua
│   │   ├── smarthome_images.lua
│   │   ├── smarthome_storage.lua
│   │   └── smarthome_network.lua
│   ├── systools/               # 公共 Lua 模块
│   └── view/systools/          # 自定义视图
│       └── about.htm
├── root/
│   ├── etc/
│   │   ├── config/systools     # 默认配置
│   │   └── uci-defaults/       # 开机初始化脚本
│   └── usr/
│       └── libexec/systools/   # 后端 Shell 脚本
│           ├── systools-common.sh
│           ├── network_wizard.sh
│           ├── ipv6.sh
│           ├── side_route.sh
│           ├── device_manager.sh
│           ├── homeassistant.sh
│           ├── smarthome_images.sh
│           ├── smarthome_storage.sh
│           └── smarthome_network.sh
├── po/                         # 翻译文件
│   ├── en/systools.po
│   └── zh-cn/systools.po
└── htdocs/
    └── luci-static/resources/systools/
        └── systools.css        # 自定义样式（Argon 适配）
```

### 云编译

项目配置了 GitHub Actions 自动构建：

1. 推送 `v*` 标签自动触发编译并发布到 Release
2. 也可在 Actions 页面手动运行 Build 工作流
3. 支持选择编译版本（all / 24.12 / 25.12）
4. 编译完成后自动发布到 Releases

## 📝 版本历史

详见 [CHANGES.md](CHANGES.md)

## 📄 许可证

MIT License
