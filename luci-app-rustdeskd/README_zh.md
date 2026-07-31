# luci-app-rustdeskd

[English](README.md) | [中文](README_zh.md)

**luci-app-rustdeskd** 是一款专为 OpenWrt 路由器打造的 **RustDesk 远程桌面服务器** 可视化管理插件。通过安装这个插件，你可以轻松地把自己的路由器变成一台私有的、完全由你掌控的远程控制中继服务器（开源的 TeamViewer 替代方案）。

## 核心功能

- **一键下载内核**：告别繁琐的命令行操作，支持在网页后台一键下载和更新官方 RustDesk 服务器核心（`hbbs` 和 `hbbr`）。
- **原生备份与恢复**：完美整合 OpenWrt 系统机制，一键无损备份/恢复你的服务器加密公私钥和连接数据，换机重装毫无压力。
- **傻瓜式可视化管理**：提供直观的运行状态、实时日志查看器，让修改端口、管理密钥变得轻而易举。

## 源码编译

```bash
# 进入你的 OpenWrt 源码根目录
cd openwrt

# 将本仓库克隆到 package 目录下
git clone https://github.com/permails/luci-app-rustdeskd.git package/luci-app-rustdeskd

# 更新并安装 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 在菜单中选中此插件
make menuconfig
# 路径: LuCI -> Applications -> luci-app-rustdeskd

# 开始编译
make package/luci-app-rustdeskd/compile V=s
```

## 致谢

本项目部分灵感参考自 superzjg 开发的 [luci-app-rustdesk-server](https://github.com/superzjg/luci-app-rustdesk-server) 项目。
