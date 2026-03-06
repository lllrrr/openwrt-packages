# SocksClash

[![Version](https://img.shields.io/badge/version-1.2.0-blue.svg)](https://github.com/hxzlplp7/luci-app-socks-clash/releases/tag/v1.2.0)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05+-orange.svg)](https://openwrt.org/)

一个**专注于代理功能**的简化版 LuCI 应用，基于 Clash Meta 内核。与 OpenClash 不同，**不做透明代理、不劫持 DNS**，只提供纯粹的 SOCKS5/HTTP 代理服务。

## ✨ 特点

- 🎯 **专注代理** - 只提供代理端口，不修改路由表和防火墙规则
- 🚀 **简单易用** - 极简配置界面，5分钟上手
- 📡 **订阅管理** - 支持订阅更新、过滤器、自动更新
- 🔧 **节点管理** - 手动添加节点、延迟测试、批量测速
- ⏰ **定时任务** - 订阅/内核/规则库自动更新
- 🎨 **现代界面** - 深色主题、流畅动画、响应式设计
- 📊 **控制面板** - 实时流量监控、节点切换、连接管理

## 📦 安装

### 方法一：直接安装 IPK（推荐）

1. 从 [Releases](https://github.com/hxzlplp7/luci-app-socks-clash/releases) 下载对应架构的 IPK 包
2. 上传到 OpenWrt 路由器
3. 安装：

```bash
opkg update
opkg install luci-app-socks-clash_*.ipk
```

### 方法二：从源码编译

```bash
# 1. 进入 OpenWrt SDK 的 package 目录
cd ~/openwrt-sdk/package

# 2. 克隆本项目
git clone https://github.com/hxzlplp7/luci-app-socks-clash.git

# 3. 编译
cd ~/openwrt-sdk
make package/luci-app-socks-clash/compile V=s
```

## 🚀 快速开始

### 1. 下载内核

首次使用需要下载 Clash Meta 内核：

- 进入 **SocksClash** → **设置** → **内核管理**
- 点击 **下载内核** 按钮
- 等待下载完成

### 2. 添加订阅

- 进入 **订阅** 页面
- 点击 **添加** 按钮
- 填写订阅名称和订阅地址
- 点击 **保存并应用**
- 点击 **更新所有订阅**

### 3. 启动服务

- 回到 **概览** 页面
- 点击 **启动服务** 按钮
- 等待服务启动成功

### 4. 配置客户端

代理地址：
- **HTTP 代理**: `http://192.168.1.1:7890`
- **SOCKS5 代理**: `socks5://192.168.1.1:7891`
- **混合代理**: `192.168.1.1:7893`（同时支持HTTP和SOCKS5）

详细配置教程请查看 **使用指南** 页面。

## 📋 功能列表

### v1.2.0 新增功能

#### 订阅管理增强
- ✅ 节点过滤器（关键词包含/排除）
- ✅ 节点类型过滤
- ✅ 订阅信息解析（流量统计）
- ✅ 自动更新时间设置

#### 配置生成器
- ✅ 从订阅自动合并节点
- ✅ 自动生成代理组
  - 🚀 PROXY（手动选择）
  - ♻️ AUTO（自动测速选择）
  - 🔄 FALLBACK（故障转移）
- ✅ 配置文件验证

#### 内核管理
- ✅ 版本自动检测
- ✅ 在线更新
- ✅ 重试机制
- ✅ 备份恢复

#### 节点管理 🆕
- ✅ 手动添加节点
- ✅ 支持多种协议（SS/VMess/VLESS/Trojan/Hysteria/TUIC）
- ✅ 单个/批量测速
- ✅ 延迟彩色显示

#### 定时任务 🆕
- ✅ 订阅自动更新
- ✅ 内核自动更新
- ✅ GeoIP/GeoSite 自动更新
- ✅ 服务定时重启

#### GeoIP/GeoSite 更新 🆕
- ✅ 从 MetaCubeX/meta-rules-dat 更新
- ✅ 重试机制

### 核心功能

- ✅ SOCKS5 代理（默认端口 7891）
- ✅ HTTP 代理（默认端口 7890）
- ✅ 混合代理（默认端口 7893）
- ✅ 订阅管理（多订阅源支持）
- ✅ 规则管理（GeoIP/GeoSite）
- ✅ 日志查看（实时/历史）
- ✅ 配置编辑器（YAML）
- ✅ 控制面板（流量监控、节点切换）

## 🎨 界面预览

### 概览页
- 服务状态、代理地址、流量统计
- 快捷操作按钮

### 控制面板
- 实时流量监控
- 代理组管理
- 节点切换（支持拖拽排序）
- 模式切换（规则/全局/直连）

### 订阅管理
- 订阅列表
- 过滤器配置
- 自动更新设置

### 服务器管理 🆕
- 节点列表（表格视图）
- 延迟显示（彩色）
- 测速按钮

## 🔧 配置说明

### 端口配置

| 服务 | 默认端口 | 说明 |
|------|---------|------|
| HTTP 代理 | 7890 | 标准 HTTP 代理端口 |
| SOCKS5 代理 | 7891 | SOCKS5 代理端口 |
| 混合代理 | 7893 | HTTP + SOCKS5 混合端口 |
| Dashboard | 9090 | Web 控制面板端口 |

### 目录结构

```
/etc/socks-clash/
├── config/                  # 配置文件目录
│   ├── config.yaml         # 当前使用的配置
│   ├── subscription1.yaml  # 订阅配置
│   └── backup/             # 配置备份
├── core/                   # 内核目录
│   └── clash              # Clash Meta 内核
└── rule/                   # 规则文件
    ├── geoip.dat
    └── geosite.dat

/tmp/
├── socks-clash.log         # 历史日志
├── socks-clash_start.log   # 实时日志
└── lock/                   # 锁文件目录
```

## 🆚 与 OpenClash 的区别

| 特性 | SocksClash | OpenClash |
|------|-----------|-----------|
| 定位 | 专注代理 | 全功能透明代理 |
| 透明代理 | ❌ 不支持 | ✅ 支持 TUN/REDIRECT |
| DNS 劫持 | ❌ 不支持 | ✅ 支持 FakeIP |
| 路由表修改 | ❌ 不支持 | ✅ 支持策略路由 |
| 防火墙集成 | ❌ 不支持 | ✅ 自动添加规则 |
| 订阅管理 | ✅ 支持（带过滤器） | ✅ 支持 |
| 节点管理 | ✅ 支持手动添加 | ✅ 支持 |
| 规则管理 | ✅ 基础支持 | ✅ 完整支持 |
| 配置复杂度 | 🟢 简单 | 🟡 复杂 |
| 适用场景 | 客户端代理 | 全局透明代理 |

## 📖 使用场景

### ✅ 适合的场景

- 只想为特定应用配置代理（浏览器、终端工具等）
- 不想修改路由器的网络配置
- 需要灵活控制哪些设备/应用使用代理
- 学习 Clash 配置文件语法
- 作为旁路由使用

### ❌ 不适合的场景

- 需要全局透明代理（所有设备自动走代理）
- 需要 DNS 分流和 FakeIP
- 需要策略路由和多网口
- 需要 TUN 模式

**如果你需要上述功能，请使用 [OpenClash](https://github.com/vernesong/OpenClash)**

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📜 开源协议

MIT License

## 🙏 致谢

- [OpenClash](https://github.com/vernesong/OpenClash) - 参考了订阅管理和日志系统的实现
- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) - Clash Meta 内核
- [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) - GeoIP/GeoSite 数据库

## 📞 联系方式

- GitHub Issues: [提交问题](https://github.com/hxzlplp7/luci-app-socks-clash/issues)
- Telegram: [@your-channel]（如果有的话）

## ⭐ Star History

如果这个项目对你有帮助，请给一个 Star ⭐

---

**Made with ❤️ for OpenWrt community**
