# luci-app-warp

[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-22.03%2B-green.svg)](https://openwrt.org/)

OpenWrt 平台的 Cloudflare WARP LuCI 管理界面，使用官方 `cloudflare-warp` (WireGuard 协议) 接入 Cloudflare 网络，支持基于 nftables 和 ipt2socks 的 TPROXY 透明全局代理。

## ✨ 功能特性

- 🚀 **一键安装** - 自动安装所有依赖并配置
- 🔐 **自动注册** - 无需手动获取配置文件，自动注册WARP账户
- 🌍 **全局代理** - 支持基于 nftables 和 ipt2socks 的 TPROXY 透明全局接管模式
- 🇨🇳 **绕过中国IP** - 可选择性绕过中国大陆IP，优化国内访问
- 📊 **状态监控** - 实时显示连接状态和代理端口情况
- 🔑 **WARP+升级** - 支持应用License Key升级到WARP+
- 🧦 **多代理协议** - 支持本地 SOCKS5 与 HTTP 代理接口
- 🔍 **端点扫描** - 启动时自动扫描延迟最低的优选 Endpoint IP
- 🎨 **现代UI** - 美观的LuCI管理界面

## 📦 依赖

- OpenWrt 22.03 或更高版本 (需要 nftables / firewall4 支持)
- `cloudflare-warp` (Cloudflare 官方 WARP 客户端)
- `ipt2socks` (实现 TPROXY 透明代理必须)
- `jsonfilter`
- `ca-bundle`
- `kmod-nft-tproxy` (开启全局透明代理需要)

## 🚀 快速安装

### 方法一：一键安装脚本

```bash
wget -O- https://raw.githubusercontent.com/hxzlplp7/luci-app-warp/main/install.sh | sh
```

### 方法二：手动安装

1. **安装依赖**

```bash
opkg update
opkg install luci-base jsonfilter ca-bundle kmod-nft-tproxy ipt2socks
```

`cloudflare-warp` 与 `ipt2socks` 通常需要您自行编译或获取预编译二进制文件，并分别放置在 `/usr/bin/warp` 和 `/usr/bin/ipt2socks` 并赋予执行权限 (`chmod +x`)。

2. **下载并安装 LuCI 应用**

```bash
# 克隆仓库
git clone https://github.com/hxzlplp7/luci-app-warp.git /tmp/luci-app-warp

# 复制文件
cp -r /tmp/luci-app-warp/root/* /
cp -r /tmp/luci-app-warp/htdocs/* /www/

# 设置权限
chmod +x /usr/bin/warp-manager
chmod +x /usr/bin/warp-update-china
chmod +x /usr/bin/warp-log
chmod +x /etc/init.d/warp
chmod +x /etc/init.d/warp-cron

# 启用服务
/etc/init.d/warp enable
/etc/init.d/rpcd restart
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
```

### 方法三：从源码编译

```bash
# 进入OpenWrt源码目录
cd openwrt

# 克隆到 package 目录
git clone https://github.com/hxzlplp7/luci-app-warp.git package/luci-app-warp

# 编译
make package/luci-app-warp/compile V=s
```

## 📖 使用说明

### Web界面（LuCI）

1. 打开路由器管理界面
2. 导航到 **服务 → Cloudflare WARP**
3. 在 **状态** 页面点击 **注册账户**
4. 注册成功后点击 **启动** 开始使用

### 命令行

```bash
# 注册账户
warp-manager register

# 启用并启动服务
warp-manager start

# 停止服务并取消启用
warp-manager stop

# 启用并重启服务
warp-manager restart

# 查看状态
warp-manager status

# 测试连接
warp-manager test

# 应用License Key升级到WARP+
warp-manager license aBcD1234-eFgH5678-iJkL9012

# 重置账户
warp-manager reset
```

### 服务管理

```bash
# 启动服务
/etc/init.d/warp start

# 停止服务
/etc/init.d/warp stop

# 重启服务
/etc/init.d/warp restart

# 查看服务状态
/etc/init.d/warp status
```

## ⚙️ 配置选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `enabled` | 启用WARP | `0` |
| `endpoint` | WARP服务器地址 | 空 (自动扫描) |
| `scan_enabled` | 启用IP端点扫描 | `0` |
| `socks_enabled` | 启用 SOCKS5 本地代理 | `1` |
| `socks_port` | SOCKS5 监听端口 | `1080` |
| `http_enabled` | 启用 HTTP 本地代理 | `0` |
| `http_port` | HTTP 监听端口 | `8118` |
| `global_proxy` | 全局代理模式 (TPROXY) | `0` |
| `bypass_china` | 绕过中国大陆IP | `0` |

### 配置文件

配置文件位于 `/etc/config/warp`：

```
config warp 'config'
    option enabled '1'
    option endpoint ''
    option global_proxy '1'
    option bypass_china '1'
    option socks_enabled '1'
    option socks_port '1080'
```

## 🌐 全局流量接管

启用全局代理后，所有来自LAN的流量都将通过WARP隧道：

1. 必须开启 `socks_enabled` SOCKS5 代理。
2. 在设置中开启 **全局代理**
3. `ipt2socks` 将在本地监听 TPROXY 端口，nftables 自动下发透明拦截规则。
4. 所有局域网设备无需额外配置即可使用。

### 绕过中国大陆IP

如果需要国内网站直连：

1. 必须在全局代理模式下生效。
2. 在设置中开启 **绕过中国大陆IP**。
3. 系统会自动下载中国大陆 IP 列表并配置为 nftables 集合 (`luci_warp_china_ip`)。
4. 访问国内网站时将绕过代理直连，国外网站走 WARP。

## ❓ 常见问题

### Q: 注册失败怎么办？

A: 确保路由器能正常访问外网，检查DNS设置。如果仍然失败，可能是Cloudflare API暂时不可用，稍后再试。

### Q: 找不到 `warp` 或 `ipt2socks` 命令？

A: 官方源中不包含 `cloudflare-warp` 和部分系统的 `ipt2socks`，请自行编译放入 `/usr/bin/` 目录。

### Q: 为什么全局代理无效？

A: 检查是否安装了 `kmod-nft-tproxy`，并且系统防火墙支持 `nftables`。如果与其他透明代理插件（如 OpenClash）共存，可能会发生端口冲突或路由劫持，强烈建议不要同时开启两种全局代理插件。

## 📝 更新日志

### v1.4.0
- 🚀 将核心引擎从 `usque` 迁移到官方 `cloudflare-warp` (WireGuard 协议)。
- ✨ 实现全新的基于 `nftables` 的 TPROXY 透明全局代理。
- ✨ 引入 `ipt2socks` 处理 TCP/UDP 透明转发。
- ✨ 全新的中国 IP 绕过机制，采用原生 `nftables` set 实现，不再依赖过时的 `ip route` 产生上万条路由。
- ✨ 新增 IP 扫描优选功能，启动时自动寻找最佳 endpoint。
- ✨ 移除废弃的 TUN 依赖，降低内核空间污染。

## 🙏 致谢

- [Cloudflare WARP](https://1.1.1.1/) - 免费的VPN服务
- [cloudflare-warp](https://github.com/shahradelahi/cloudflare-warp) - 第三方开源 WARP 客户端
- [ipt2socks](https://github.com/zfl9/ipt2socks) - 强大的 TPROXY 转发工具
- [OpenWrt](https://openwrt.org/) - 开源路由器操作系统

## 📄 许可证

本项目采用 [GPL-3.0](LICENSE) 许可证。

---

如有问题或建议，欢迎提交 [Issue](https://github.com/hxzlplp7/luci-app-warp/issues)！
