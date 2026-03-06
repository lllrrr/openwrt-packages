# luci-app-openvpn-admin

[![GitHub Release](https://img.shields.io/github/v/release/hzy306016819/luci-app-openvpn-admin)](https://github.com/hzy306016819/luci-app-openvpn-admin/releases)
[![Build Status](https://github.com/hzy306016819/luci-app-openvpn-admin/workflows/Build%20luci-app-openvpn-admin/badge.svg)](https://github.com/hzy306016819/luci-app-openvpn-admin/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

一个功能完整的 OpenVPN 管理界面插件，适用于 OpenWrt/LEDE/ImmortalWrt 系统。
## 重要提示：插件严重依赖MANAGEMENT管理接口。所以openvpn-openssl必须带MANAGEMENT管理接口
- 方法一：在.config文件CONFIG_OPENVPN_openssl_ENABLE_MANAGEMENT=y 
- 方法二：make menuconfig -> Network -> VPN -> openvpn-openssl ->  [*] Enable management server support

## 功能特性

### 🚀 核心功能
- **ipv6环境**：支持公网ipv6环境（测试环境：电信ipv6）
- **实时状态监控**：实时显示 OpenVPN 服务状态和连接客户端
- **客户端管理**：生成客户端配置文件，支持一键下载
- **服务端配置**：可视化配置 OpenVPN 服务器参数
- **日志查看**：实时查看 OpenVPN 日志，支持自动刷新和过滤
- **黑名单管理**：基于客户端 CN 的黑名单系统
- **证书管理**：支持重置所有证书

### 🔧 技术特性
- 基于 OpenVPN Management Interface 实时获取连接状态
- 集成 EasyRSA 进行证书管理
- 支持自动刷新和实时流量监控
- 完整的 LuCI 界面集成
- 支持多种架构（x86_64, ARM, MIPS）

## 系统要求

- OpenWrt 21.02 或更高版本
- LuCI 框架
- OpenVPN（包含 management 接口支持）
- EasyRSA（用于证书管理）

## 安装方法

### 方法一：在线安装（推荐）

1. 登录 OpenWrt/LEDE/ImmortalWrt 的 LuCI 界面
2. 进入 `系统` → `软件包`
3. 更新软件包列表
4. 搜索 `luci-app-openvpn-admin` 并安装

### 方法二：手动安装 IPK

1. 从 [Releases 页面](https://github.com/hzy306016819/luci-app-openvpn-admin/releases) 下载对应架构的 IPK 文件
2. 通过 SSH 登录路由器
3. 上传并安装 IPK 文件：
   ```bash
   opkg install luci-app-openvpn-admin_*.ipk
   安装附带接口管理的openvpn-openssl
   opkg install libopenssl3_*.ipk
   opkg install openvpn-openssl_*.ipk
# 安装效果图（只在安装好的系统测试过，末测试编译）
<img width="1918" height="880" alt="image" src="https://github.com/user-attachments/assets/7dc22795-2a1d-48f3-9847-1f5e22bcddba" />
<img width="1918" height="880" alt="image" src="https://github.com/user-attachments/assets/1dffeeb0-e778-40bd-9832-2aa6d1249f15" />
<img width="1918" height="880" alt="image" src="https://github.com/user-attachments/assets/ef562183-fbf7-4b30-8cd3-613129c83913" />
<img width="1918" height="880" alt="image" src="https://github.com/user-attachments/assets/a0ac2d44-7fb5-44bf-86f1-185fab269906" />
<img width="1918" height="880" alt="image" src="https://github.com/user-attachments/assets/0ca09a8c-4598-41b8-af83-345e5730afc3" />



# 插件目录结构

```plaintext
luci-app-openvpn-admin/
├── luasrc/
│   ├── controller/
│   │   └── openvpn-admin.lua
│   └── view/
│       └── openvpn-admin/
│           ├── client.htm
│           ├── logs.htm
│           ├── server.htm
│           ├── settings.htm
│           └── status.htm
├── root/
│   ├── etc/
│   │   ├── config/
│   │   │   └── openvpn-admin
│   │   │   └── openvpn
│   │   └── openvpn/
│   │       ├── clean-garbage.sh
│   │       ├── client-connect-cn.sh
│   │       ├── generate-client.sh
│   │       ├── openvpn_ipv6 
│   │       ├── openvpn_hotplug.sh                  
│   │       └── renewcert.sh
│   │        
│   │           
└── Makefile
```
## 文件对应目录
文件目录：
"/usr/lib/lua/luci/controller/openvpn-admin.lua"
"/usr/lib/lua/luci/view/openvpn-admin/status.htm"
"/usr/lib/lua/luci/view/openvpn-admin/client.htm"
"/usr/lib/lua/luci/view/openvpn-admin/server.htm"
"/usr/lib/lua/luci/view/openvpn-admin/logs.htm"
"/usr/lib/lua/luci/view/openvpn-admin/settings.htm"
"/etc/config/openvpn-admin"                                                配置文件
"/etc/config/openvpn"                                                      配置文件
下面需要执行权限的：
"/etc/openvpn/generate-client.sh"                              OpenVPN客户端证书生成和配置文件生成脚本
"/etc/openvpn/client-connect-cn.sh"                          用于检查客户端CN是否在黑名单中
"/etc/openvpn/renewcert.sh"                                       证书重置脚本。这个不需要执行权限
"/etc/openvpn/clean-garbage.sh"                               OpenVPN管理界面垃圾文件清理脚本
"/etc/openvpn/openvpn_ipv6"                                 新增ipv6更新脚本，获取pppoe-wan的地址更新openvpn配置文件的ipv6地址。



## 完整修正后的项目关系树

text

```
luci-app-openvpn-admin/
├── 控制器文件 (Lua)
│   └── openvpn-admin.lua                    # 主控制器
├── 视图模板 (HTM)
│   ├── status.htm                          # 状态页面
│   ├── client.htm                          # 客户端页面
│   ├── server.htm                          # 服务端配置页面
│   ├── logs.htm                            # 日志页面
│   └── settings.htm                        # 设置页面
├── 脚本文件 (需要手动创建)
│   ├── /etc/openvpn/client-connect-cn.sh   # 客户端连接黑名单检查脚本 ★
│   └── /etc/openvpn/renewcert.sh           # 重置所有证书脚本 ★
├── 脚本文件 (自动生成)
│   ├── openvpn_ipv6                        # IPv6自动更新主脚本
│   ├── openvpn_hotplug.sh                  # Hotplug系统脚本
│   ├── clean-garbage.sh                    # 垃圾清理脚本
│   └── generate-client.sh                  # 生成客户端配置脚本
├── 配置文件
│   ├── /etc/config/openvpn-admin           # 插件UCI配置
│   ├── /etc/config/openvpn                 # OpenVPN主配置
│   ├── /etc/openvpn/blacklist.json         # 黑名单文件
│   ├── /etc/openvpn/openvpn_connection_history.json # 连接历史
│   └── /etc/openvpn/pki/                   # 证书目录
├── 系统集成文件
│   ├── /etc/hotplug.d/iface/99-openvpn-admin # Hotplug配置文件（自动生成）
│   └── /etc/crontabs/root                  # Cron定时任务（自动更新）
└── 临时文件目录
    ├── /tmp/openvpn-admin/                 # 临时目录（自动创建）
    ├── /tmp/openvpn-admin/openvpn_ipv6.log # IPv6脚本日志
    └── /tmp/openvpn-admin/hotplug_ipv6.log # Hotplug日志
```



## 脚本创建状态检查表

| 脚本文件             | 是否自动生成 | 状态                   | 备注             |
| :------------------- | :----------- | :--------------------- | :--------------- |
| openvpn_ipv6         | 自己创建     | ⚠️ 根据自己环境需要手动创建或替换   | 核心IPv6更新脚本 |
| openvpn_hotplug.sh   | 自动生成     | ✅ 保存设置时生成       | Hotplug系统脚本  |
| clean-garbage.sh     | 自动生成     | ✅ 启用清理功能时生成   | 垃圾清理脚本     |
| generate-client.sh   | 自动生成     | ✅ 首次生成客户端时生成 | 客户端配置生成   |
| client-connect-cn.sh | 手动创建     | ⚠️ 需要手动创建         | 黑名单检查脚本   |
| renewcert.sh         | 手动创建     | ⚠️ 需要手动创建         | 证书重置脚本     |
| 99-openvpn-admin     | 自动生成     | ✅ 启用Hotplug时生成    | Hotplug配置文件  |

## 一、/etc/config/openvpn-admin 解析

这个文件是 **OpenVPN-Admin 管理工具** 的全局配置文件，用于管理 OpenVPN 的运行、日志、黑名单、脚本执行等辅助功能，而非 OpenVPN 服务本身的核心配置。

|                            配置项                            |                           具体作用                           |
| :----------------------------------------------------------: | :----------------------------------------------------------: |
|                  `config settings 'global'`                  | 定义 OpenVPN-Admin 的全局配置块（OpenWRT 配置文件的标准格式） |
|              `option openvpn_instance 'myvpn'`               | 指定要管理的 OpenVPN 实例名称（对应`/etc/config/openvpn`中的`myvpn`实例） |
|      `option openvpn_config_path '/etc/config/openvpn'`      |                指向 OpenVPN 主配置文件的路径                 |
|                  `option history_size '20'`                  |        限制连接历史记录的最大条数（仅保留最近 20 条）        |
|              `option blacklist_duration '300'`               |         黑名单生效时长（单位：秒），300 秒 = 5 分钟          |
|             `option log_file '/tmp/openvpn.log'`             | OpenVPN 日志文件的存储路径（`/tmp`是临时目录，设备重启后日志丢失） |
|             `option easyrsa_dir '/etc/easy-rsa'`             | EasyRSA 工具的安装目录（EasyRSA 用于生成 OpenVPN 所需的证书 / 密钥） |
|           `option easyrsa_pki '/etc/easy-rsa/pki'`           | EasyRSA 的 PKI（公钥基础设施）目录，存放根证书、密钥等基础证书文件 |
|           `option openvpn_pki '/etc/openvpn/pki'`            | OpenVPN 实际使用的 PKI 目录（指向服务端 / 客户端证书的存储位置） |
|             `option logs_refresh_interval '10'`              |          管理界面日志自动刷新的时间间隔（单位：秒）          |
|              `option logs_display_lines '1000'`              |      管理界面最多显示的日志行数（避免日志过多导致卡顿）      |
|              `option logs_refresh_enabled '1'`               |            启用日志自动刷新（1 = 启用，0 = 禁用）            |
|            `option temp_dir '/tmp/openvpn-admin'`            |               OpenVPN-Admin 临时文件的存储目录               |
|              `option clean_garbage_time '4:50'`              |      定时清理垃圾文件的时间（每天凌晨 4 点 50 分执行）       |
|                `option refresh_interval '1'`                 |   管理界面数据（如在线客户端、流量）的刷新间隔（单位：秒）   |
| `option history_file '/etc/openvpn/openvpn_connection_history.json'` |          连接历史记录的持久化文件路径（JSON 格式）           |
|    `option blacklist_file '/etc/openvpn/blacklist.json'`     |           黑名单文件路径（记录被禁止连接的客户端）           |
| `option generate_client_script '/etc/openvpn/generate-client.sh'` |   生成客户端配置文件的脚本路径（一键生成客户端.ovpn 文件）   |
|    `option renew_cert_script '/etc/openvpn/renewcert.sh'`    |         证书续期脚本路径（避免证书过期导致连接失败）         |
| `option clean_garbage_script '/etc/openvpn/clean-garbage.sh'` |        清理垃圾文件（如过期日志、临时文件）的脚本路径        |
|    `option ipv6_script_path '/etc/openvpn/openvpn_ipv6'`     |    处理 IPv6 相关逻辑的脚本路径（如 IPv6 地址配置、路由）    |
|              `option ipv6_script_interval '10'`              |               IPv6 脚本的执行间隔（单位：秒）                |
|                `option blacklist_enabled '0'`                |             禁用黑名单功能（1 = 启用，0 = 禁用）             |
|              `option clean_garbage_enabled '0'`              |                   禁用自动清理垃圾文件功能                   |
|                 `option refresh_enabled '1'`                 |                   启用管理界面数据自动刷新                   |
|               `option ipv6_script_enabled '1'`               |                      启用 IPv6 相关脚本                      |
|                 `option hotplug_enabled '1'`                 |         启用热插拔触发功能（网络接口变化时执行脚本）         |
|             `option hotplug_interface 'br-lan'`              | 监控的热插拔接口（LAN 桥接接口，如路由器 LAN 口变化时触发）  |
| `option hotplug_ipv6_address '240e:3b1:1690:86a0:be24:11ff:feba:9e5a'` |                 热插拔触发时使用的 IPv6 地址                 |
| `option hotplug_script_path '/etc/openvpn/openvpn_hotplug.sh'` |  热插拔事件触发时执行的脚本路径（如接口变化后重启 OpenVPN）  |

------

## 二、/etc/config/openvpn 解析

这个文件是 **OpenVPN 服务端的核心配置**，定义了`myvpn`实例的运行规则（协议、端口、证书、路由、客户端策略等），是 OpenVPN 服务能正常运行的关键。

|                           配置项                            |                           具体作用                           |
| :---------------------------------------------------------: | :----------------------------------------------------------: |
|                  `config openvpn 'myvpn'`                   | 定义一个名为`myvpn`的 OpenVPN 实例（OpenWRT 中可配置多个实例） |
|                    `option proto 'udp6'`                    | 服务端使用的传输协议：`udp6`表示基于 IPv6 的 UDP 协议（UDP 比 TCP 更适合 VPN，延迟更低） |
|                     `option dev 'tun'`                      | 使用`tun`虚拟设备（三层 IP 隧道，用于路由转发）；若用`tap`则是二层以太网隧道 |
|                 `option topology 'subnet'`                  | 子网拓扑模式：给所有客户端分配同一子网（10.8.0.0/24）的 IP，便于路由管理 |
|          `option server '10.8.0.0 255.255.255.0'`           | 定义 OpenVPN 虚拟子网：服务端占用 10.8.0.1，客户端分配 10.8.0.2~10.8.0.254 |
|                 `option compress 'lz4-v2'`                  | 服务端启用`lz4-v2`压缩算法（轻量级高压缩比，提升 VPN 传输效率） |
|            `option ca '/etc/openvpn/pki/ca.crt'`            |  CA 根证书路径（用于验证客户端证书的合法性，核心安全配置）   |
|            `option dh '/etc/openvpn/pki/dh.pem'`            | Diffie-Hellman 参数文件（用于密钥交换，保证加密通信的安全性） |
|         `option cert '/etc/openvpn/pki/server.crt'`         |         服务端证书路径（客户端验证服务端身份的依据）         |
|         `option key '/etc/openvpn/pki/server.key'`          |          服务端私钥路径（服务端加密通信的核心密钥）          |
|                  `option persist_key '1'`                   | 重启 TUN/TAP 设备时不重新读取私钥（提升稳定性，避免密钥重复加载） |
|                  `option persist_tun '1'`                   |  重启时保持 TUN/TAP 设备打开（避免隧道重新建立，减少断连）   |
|                   `option user 'nobody'`                    |  OpenVPN 进程运行的用户（非 root 用户，降低权限提升安全性）  |
|                  `option group 'nogroup'`                   | OpenVPN 进程运行的用户组（配合`nobody`用户，进一步限制权限） |
|                  `option max_clients '10'`                  |   最大允许同时连接的客户端数量（限制并发数，避免资源耗尽）   |
|                 `option keepalive '10 120'`                 | 保活机制：每 10 秒发一次心跳包，120 秒未收到客户端回应则断开连接 |
|                      `option verb '3'`                      | 日志详细程度（0-9，3 为中等，数字越大日志越详细，调试时可调高） |
|        `option status '/var/log/openvpn_status.log'`        |   状态日志路径（记录客户端连接状态、IP 分配、流量等信息）    |
|               `option log '/tmp/openvpn.log'`               | 主日志路径（临时目录，重启后丢失，可配合 openvpn-admin 的日志配置） |
|                    `option enabled '1'`                     | 启用该 OpenVPN 实例（1 = 启用，0 = 禁用，改 0 后服务不启动） |
|                `option script_security '3'`                 | 脚本安全级别（3 为最高级，允许执行任意外部脚本，如 client-connect 脚本） |
|                    `option port '1010'`                     |           服务端监听的端口号（客户端需连接此端口）           |
|                `option ddns '域名或ip'`                |   DDNS 域名（客户端可通过域名访问服务端，无需记住固定 IP）   |
|   `option local '240e:3b1:1697:e780:be24:11ff:feba:9e5a'`   | 服务端绑定的本地 IPv6 地址（仅监听该地址，确保 VPN 走 IPv6） |
| `option client_connect '/etc/openvpn/client-connect-cn.sh'` |  客户端成功连接时执行的脚本（如记录连接日志、分配特定权限）  |
|       `list push 'route 192.168.100.0 255.255.255.0'`       | 推送给客户端的路由规则：让客户端能访问 192.168.100.0/24 局域网 |
|       `list push 'redirect-gateway def1 bypass-dhcp'`       |      强制客户端所有流量走 VPN（默认网关重定向到服务端）      |
|        `list push 'dhcp-option DNS 192.168.100.10'`         |      推送给客户端的 DNS 服务器：客户端用此 DNS 解析域名      |
|                `list push 'compress lz4-v2'`                |         告知客户端启用`lz4-v2`压缩（需和服务端一致）         |
