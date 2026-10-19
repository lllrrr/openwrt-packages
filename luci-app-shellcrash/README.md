# luci-app-shellcrash

适用于 OpenWrt / ImmortalWrt 系统的 **ShellCrash** 原生 LuCI Web 控制管理插件。

让基于命令行交互的 ShellCrash 拥有现代化、响应式的图形操作界面，支持服务生命周期管控、Clash API 运行时模式切换、国内外分流真延迟测试、订阅管理与配置在线维护、Web 控制面板（Zashboard / Metacubexd）一键直连与本地部署。

---

## ✨ 核心特性

- **运行状态与监控**：
  - 实时显示 ShellCrash 及核心运行状态（运行中 / 已停止）、核心 PID、内存占用（VmRSS）、运行时长、核心类型及版本。
  - 清晰展示当前监听端口：HTTP/Socks 混合代理端口（默认 7890）、透明代理端口（7892/7893）、DNS 端口（1053）及 RESTful API 端口（9999）。
  - 开机自启动状态检测与一键切换。
- **服务生命周期控制**：
  - 一键启动服务、停止服务、重启服务。
  - 支持 **热重载配置**（通过 Clash API PUT 请求无缝重载，无需重启整个核心中断网络）。
  - 内置离线安装包（174 KB）：系统若未初始化 ShellCrash，界面提供 **一键初始化 ShellCrash 环境**，无需连外网即可完成部署。
- **真实分流延迟测试**：
  - 并发测试国内与国际代表性站点（百度、Google、GitHub、YouTube）。
  - 请求强制通过本地混合代理端口发出，精准测出经节点与分流规则后的端到端真实往返延迟（毫秒级别）。
- **Web 控制面板生态集成**：
  - 支持 **Zashboard**（现代化响应式）、**Metacubexd**（Clash.Meta 官方）、**Yacd** 等多款流行面板。
  - **一键直连**：跳转时自动注入路由器的 Hostname、API 端口与 Secret 鉴权信息，免除手动登录。
  - **本地一键部署**：支持将 Web 面板一键下载并解压部署到路由器内核目录（`/ui/`）或 LuCI 站点（`/www/`），无外网也可离线访问。
- **内核与分流模式即时调控**：
  - 规则分流（Rule）、全局代理（Global）、全局直连（Direct）一键无缝切换（Clash API 即时生效）。
  - 日志级别切换（Silent / Error / Warning / Info / Debug）。
  - 局域网连接共享（Allow LAN）、IPv6 透明分流支持、TCP 并发连接开关。
- **订阅与节点管理**：
  - 查看已配置的订阅源、链接与更新周期。
  - 提供 **一键更新全部订阅并重载**，自动触发更新脚本并拉取最新节点与规则。
- **ShellCrash.cfg 在线配置编辑器**：
  - 在 Web 界面中直接查看并编辑 `ShellCrash.cfg`。
  - 保存时 **自动备份** 为 `ShellCrash.cfg.bak`，并提供 **一键从备份还原** 功能，防止改错导致无法启动。
- **实时运行日志**：
  - 自动捕获 ShellCrash 调试日志与核心连接日志。
  - 支持设置显示行数（默认 200 行），支持每 3 秒自动轮询刷新及手动刷新。
- **多平台安装包与 CI 编译**：
  - 架构无关（`all` / `noarch`），完美适配 ARM64（MT7981 / MT7982 / MT7986）、x86_64、MIPS 等全系列架构。
  - 同时提供 `.apk`（OpenWrt 25.12+）、`.ipk`（OpenWrt 21~24）、`.tar.gz`（手动通用解压包）。
  - GitHub Actions 自动化 CI，支持 `workflow_dispatch` 手动触发与发布 Release。

---

## 📦 安装方法

### 方式一：下载预编译包安装（推荐）

在 GitHub [Releases](https://github.com/hhCodingCat/luci-app-shellcrash/releases) 页面下载对应格式安装包上传至路由器：

#### 1. ImmortalWrt / OpenWrt 25.12 及以上版本（apk-tools 3）：
```sh
apk add --allow-untrusted ./luci-app-shellcrash-1.0.0-r1.apk
```

#### 2. OpenWrt 24.10 及更早版本（opkg）：
```sh
opkg install ./luci-app-shellcrash_1.0.0-1_all.ipk
```

#### 3. 任何版本通用手动安装：
```sh
tar -xzf luci-app-shellcrash-1.0.0-rootfs.tar.gz -C /
sh /etc/uci-defaults/99-luci-app-shellcrash
```

---

### 方式二：编译进固件（源码编译）

在 OpenWrt / ImmortalWrt 源码根目录下：

```sh
# 克隆仓库到 package 目录
git clone https://github.com/hhCodingCat/luci-app-shellcrash.git package/luci-app-shellcrash

# 更新并安装 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 进入配置菜单勾选插件
make menuconfig
# 路径：LuCI -> 3. Applications -> <*> luci-app-shellcrash
```

---

## 🛠️ 本地打包命令

本项目自带纯 Python 构建脚本（无需安装 OpenWrt SDK），直接执行：

```sh
# 构建所有三种格式（.ipk, .apk, .tar.gz）
python3 scripts/build.py

# 构建产物保存在 dist/ 目录下
ls -la dist/
```

---

## 📄 开源许可证

本项目遵循 [GPL-3.0](LICENSE) 开源协议。
