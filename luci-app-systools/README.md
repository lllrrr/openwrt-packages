# luci-app-systools - OpenWrt 工具箱插件

一个功能丰富的 OpenWrt LuCI 插件，提供网络向导、智能家居管理等实用工具。

## ✨ 功能特性

### 🌐 网络向导类

| 功能 | 说明 |
|------|------|
| **上网设置向导** | 步骤式引导配置上网（PPPoE/DHCP/静态IP） |
| **IPv6一键设置** | 一键切换 IPv6 模式（Native/6to4/6in4/中继/禁用） |
| **旁路由模式** | 全自动检测配置，一键切换路由/旁路由模式 |
| **设备管理** | 查看已连接设备，修改备注名，绑定静态 IP |

### 🏠 智能家居类

| 功能 | 说明 |
|------|------|
| **Home Assistant** | HA 容器状态监控、启停、日志查看、配置备份 |
| **HA 镜像管理** | 镜像列表、拉取（含国内加速源）、删除、加速配置 |
| **HA 存储设置** | Docker 数据目录迁移到 U 盘，存储管理 |
| **HA 网络设置** | 常用端口快捷管理、mDNS/UPnP 开关 |

## 📦 安装

### 24.12 版本（ipk）
```bash
opkg install luci-app-systools_1.0.0-1_all.ipk
```

### 25.12 版本（apk）
```bash
apk add luci-app-systools_1.0.0-r1.apk --allow-untrusted
```

安装后刷新 LuCI 界面，在「服务」菜单下找到「工具箱」。

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

项目配置了 GitHub Actions 自动构建，支持手动触发：

1. 推送代码到 GitHub
2. 在 Actions 页面手动运行 Build 工作流
3. 选择编译版本（all / 24.12 / 25.12）
4. 编译完成后自动发布到 Releases

## 📝 版本历史

详见 [CHANGES.md](CHANGES.md)

## 📄 许可证

MIT License
