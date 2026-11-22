# UPnP NAT Relay

[English](README.en.md) | **中文**

OpenWrt LuCI 插件，用于在双路由器（多级 NAT）网络环境中，将下游路由器的 UPnP 端口映射接力穿透上游 NAT。映射由插件直接写入自有 nftables DNAT 链；OpenClash 规则不参与 DNAT。

## 它做了什么

在双路由器（多级 NAT）组网中，下游路由器可以为 LAN 设备创建 UPnP 端口映射，但上游 OpenWrt 路由器并不知道这些映射的存在。本插件：

1. 从下游路由器 LAN 侧读取真实的 UPnP 映射
2. 对映射进行安全过滤
3. 在上游 OpenWrt 上创建对应的 DNAT 规则
4. 不修改 OpenClash 配置，也不为同步映射重启代理。代理侧是否放行取决于 OpenClash 运行时规则
5. 当下游 UPnP 映射消失时自动移除 DNAT 规则

这比在上游路由器上开大范围 DMZ 或手动逐条配置端口转发更安全、更省心。

## 快速开始

### 编译

**方式一：OpenWrt SDK（推荐）**

```sh
cd /path/to/openwrt-sdk

echo "src-git luci_app_upnp_nat_relay https://github.com/hello-yunshu/luci-app-upnp-nat-relay.git" >> feeds.conf.default
./scripts/feeds update luci_app_upnp_nat_relay
./scripts/feeds install luci-app-upnp-nat-relay

make menuconfig
make package/luci-app-upnp-nat-relay/compile V=s
```

**方式二：从 [Releases](https://github.com/hello-yunshu/luci-app-upnp-nat-relay/releases) 下载预编译包**

每次推送到 main 分支，CI 会自动构建 `.ipk`（opkg）和 `.apk`（apk）两种格式的包。

### 安装

```sh
# OpenWrt 24.10 / 23.05 (opkg)
opkg install luci-app-upnp-nat-relay_*.ipk

# OpenWrt 25.12+ (apk)
apk add --allow-untrusted ./luci-app-upnp-nat-relay*.apk
```

从旧包名迁移时，先卸载 `luci-app-upnp-bridge-relay`，再安装 `luci-app-upnp-nat-relay`。新包安装时会把 `/etc/config/upnp_bridge_relay` 迁移为 `/etc/config/upnp_nat_relay`。

### 使用

1. **LuCI 网页界面**：服务 → UPnP NAT Relay → 设置向导，按步骤引导完成配置
2. **命令行**：

```sh
# 环境检查
upnp-nat-relay --check-env

# 干跑模式（只读取，不写入规则）
upnp-nat-relay --dry-run

# 完整同步（创建 DNAT 规则）
upnp-nat-relay --sync

# 查看状态
upnp-nat-relay --status
```

## 适用场景

- 你有一个上游 OpenWrt 路由器和一个下游路由器（任意品牌）
- 下游路由器已为 LAN 设备启用了 UPnP
- 你希望外部网络能访问下游路由器后面的设备
- 你只想暴露实际有 UPnP 映射的端口，而不是开一大段端口范围

## 不适用场景

- 你只有一个路由器（没有多级 NAT）
- 上游路由器不是 OpenWrt
- 上游 OpenWrt 使用 fw3/iptables（需要 fw4/nftables）
- 上游 WAN 没有公网 IP（CGNAT 无法穿透）
- 你想暴露低位特权端口（22、80、443 等）

## 兼容性矩阵

| 等级 | OpenWrt 版本 | 防火墙 | 包管理器 | 状态 |
|------|-------------|--------|---------|------|
| Tier 1 | 25.12.x | fw4 / nftables | apk | 推荐 |
| Tier 2 | 24.10.x | fw4 / nftables | opkg | 支持 |
| 实验性 | 23.05.x | fw4 / nftables | opkg | 尽力支持 |
| 不支持 | 任意 | fw3 / iptables | 任意 | 不支持 |

## 网络拓扑

```
互联网
  |
  +-- 上游 OpenWrt 路由器
  |     - WAN：公网出口
  |     - LAN：连接下游路由器 WAN
  |     - 额外接口：连接下游路由器 LAN（用于读取 UPnP）
  |     - 运行防火墙 / NAT / OpenClash
  |
  +-- 下游路由器
  |     - WAN：连接上游 OpenWrt LAN
  |     - LAN：已启用 UPnP
  |     - 例如：小米、华硕、OpenWrt、爱快等
  |
  +-- 下游 LAN 客户端
        - NAS
        - 游戏主机
        - PC
        - 下载设备
```

示例地址：

```
上游 OpenWrt LAN：       192.168.2.1/24
下游路由器 WAN：         192.168.2.2

下游路由器 LAN：         192.168.3.1/24
上游额外接口：           192.168.3.50/24  （仅用于读取 UPnP）
```

核心转发原理：DNAT 的目标是**下游路由器 WAN IP**（192.168.2.2），而不是下游 LAN 客户端 IP。下游路由器自身的 NAT/UPnP 规则负责第二跳转发。

## 如何连接下游路由器

上游 OpenWrt 需要一个**额外接口**连接到下游路由器的 LAN 侧。这个接口**仅用于读取 UPnP**，不用于上网。

**重要规则：**

- 不要在此接口上设置默认网关
- 不要将此接口桥接到主 LAN
- 不要将此接口配置为 WAN 出口

示例配置：

```
接口名称：  upnp_nat_lan
设备：      eth2
协议：      静态地址
IP 地址：   192.168.3.50
子网掩码：  255.255.255.0
网关：      （留空）
DNS：       （留空）
```

插件可通过设置向导自动创建此接口，也可以手动配置。

## 依赖

| 包 | 用途 |
|---|------|
| miniupnpc | 提供 `upnpc` 命令，读取下游 UPnP IGD 映射 |
| nftables | 创建和管理插件专属的 nftables DNAT 表 |
| coreutils-timeout | 为耗时探测命令提供 `timeout` 限制 |
| flock | 为同步任务提供文件锁，避免并发执行 |
| uci | 读写 OpenWrt UCI 配置 |
| ubus | LuCI 状态和操作 RPC 接口 |
| rpcd | LuCI 后端 RPC 守护进程 |
| luci-base | LuCI 网页界面框架 |

如需手动安装依赖：

OpenWrt 25.12+：

```sh
apk update
apk add miniupnpc nftables coreutils-timeout flock luci-base rpcd uci
```

OpenWrt 24.10 / 23.05：

```sh
opkg update
opkg install miniupnpc nftables coreutils-timeout flock luci-base rpcd uci
```

## LuCI 使用

安装后，在 LuCI 中导航到 **服务 → UPnP NAT Relay**。界面提供 8 个子页面：

### 1. 概览

服务状态、上次同步结果、映射计数和操作按钮（启动、停止、立即同步、清除规则）。

### 2. 设置向导

逐步引导配置插件：
- 选择连接到下游 LAN 的接口
- 填写或自动检测接口 IP
- 测试 ping 和 UPnP 连通性
- 配置下游路由器 WAN IP
- 设置允许的端口范围
- 检查 OpenClash 运行时 `localnetwork` 是否包含原始目标地址（条件性代理旁路）
- 启用服务

### 3. 基本设置

服务开关、同步间隔、日志级别、停止时清理规则等基础配置。

### 4. 网络与防火墙

查看和配置读取接口与防火墙区域。检测错误配置，如读取接口上的默认路由或区域设置不当。

### 5. 安全过滤

配置允许的端口范围、拒绝端口列表、允许的协议和内部子网。默认：允许 40000-65535 端口，拒绝知名敏感端口。

### 6. 映射表

三个表格分别显示：
- 从下游路由器读取的原始 UPnP 映射
- 上游路由器上当前同步的 DNAT 规则
- 被拒绝的映射及拒绝原因

### 7. OpenClash 兼容性

relay 直接在上游防火墙自有表中安装 DNAT，不需要 OpenClash UCI 规则或重启。`lan_ac_traffic` 按来源地址和来源端口匹配，不能表达入站映射所需的目的端口，因此插件拒绝生成或写入这类规则。OpenClash 是否继续拦截取决于原始目标地址是否属于其运行时 `localnetwork` 集合；v0.47.156 源码对本机 WAN IPv4 有提前 RETURN，但公网别名和其他版本/模式仍需检查运行时集合与计数器。

### 8. 诊断与回滚

环境检查、网络连通性测试、近期日志、依赖状态和建议的修复命令。

## 接口与区域推荐配置

读取接口应位于独立的防火墙区域，推荐设置如下：

| 设置 | 值 | 原因 |
|------|---|------|
| input | ACCEPT | 允许 OpenWrt 访问下游 LAN |
| output | ACCEPT | 允许下游 LAN 的响应返回 |
| forward | REJECT | 防止此接口参与正常转发 |
| masquerade | 关闭 | 此接口不需要 NAT |
| mtu_fix | 关闭 | 不是 WAN 出口 |

如果区域 output 为 REJECT，从上游路由器执行 `ping` 或 `upnpc` 时会报 "Operation not permitted"。插件可通过 **修复区域** 按钮自动修复。

## OpenClash 兼容性

OpenClash `lan_ac_traffic` 在透明代理的 prerouting 链中按源地址和源端口匹配。UPnP relay 的入站 DNAT 流量来自远端客户端，映射端口是目的端口；回包则从下游接口进入。relay 生成的 `src_ip=下游 WAN IP`、`src_port=映射端口` 和上游 WAN interface 不能匹配这两个方向，因此不能用于绕过入站端口转发。

插件现在会拒绝生成或写入这类规则，并在页面显示“不支持”的原因。旧的 `openclash_mode` 和 `openclash_return_strategy` 值为兼容已有配置而保留；`auto` 不会再写入 OpenClash 配置。页面上的 **移除插件规则** 和显式 **重启 OpenClash** 操作仍可用。更新前写入的插件规则可能仍保存在 OpenClash UCI 配置中；移除后需通过 OpenClash 自身操作应用配置变更。

UPnP relay 的 nftables DNAT 与 OpenClash UCI 无关：relay 会在自有 `inet upnp_nat_relay` 表中原子替换映射规则。v0.47.156 的源码显示，OpenClash 在 prerouting 处理链中会对属于 `localnetwork` 的目标执行 RETURN；因此实际 WAN IPv4 可以沿 relay DNAT 路径继续，但公网别名若不在该运行时集合中仍可能进入代理处理。relay 不会自行把地址加入或移出 OpenClash 共享集合。该版本组合目前只有规则来源和隔离内核规则行为证据，尚无匹配版本 OpenClash daemon 的真实 WAN 入站流量验收，不能据此标为完整支持。

OpenClash v0.48.002 的隔离 IPv4 TCP 入站测试确认，生成的 RETURN 规则计数为 0，而同一流量进入了后续 OpenClash 处理链。UDP 和 IPv6 组合尚无真实流量验收；IPv4 地址配 `family=both` 时，该版本还会拒绝对应 IPv6 规则。由于规则写入已被禁用，这些组合不会被报告为支持。旧 `openclash_auto_restart` 升级迁移仍会移除该选项。

## 安全注意事项

**本插件将下游 UPnP 映射暴露到公网。** 请务必注意以下事项：

- **限制端口范围**：不要使用 `1-65535` 作为允许范围，推荐默认的 `40000-65535`
- **不要允许低位特权端口**：0-1023 端口和知名端口（22、80、443、3389 等）默认被拒绝，不要从拒绝列表中移除
- **不要将读取接口设为默认路由**：否则所有流量都会经过下游路由器
- **不要将读取接口桥接到主 LAN**：会造成网络环路或路由混乱
- **定期查看被拒绝的映射**：在映射表页面检查被拒绝的条目及原因
- **确认你的 WAN IP 类型**：如果上游 WAN 是私网/CGNAT IP，即使 DNAT 规则正确，外部也无法访问

## 故障排除

### 1. 找不到 UPnP IGD 设备

**症状**：`upnpc -m <bind_ip> -l` 未返回任何设备。

**解决方案**：确认以下事项：
- 绑定 IP 在下游路由器的 LAN 子网内
- 下游路由器已启用 UPnP
- 读取接口已连接到下游 LAN

```sh
upnpc -m <bind_ip> -l
```

### 2. 绑定 IP 不存在

**症状**：配置的 bind_ip 在本地接口上未找到。

**解决方案**：检查读取接口是否已启动且 IP 正确：

```sh
ip addr
```

### 3. ping 下游网关报 "Operation not permitted"

**症状**：`ping 192.168.3.1` 返回 "Operation not permitted"。

**解决方案**：读取接口的防火墙区域 output 可能设为 REJECT，改为 ACCEPT：

```sh
uci set firewall.@zone[N].output=ACCEPT
uci commit firewall
fw4 reload
```

或在 LuCI 网络与防火墙页面使用 **修复区域** 按钮。

### 4. 下游路由器 WAN IP 不可达

**症状**：无法 ping 通下游路由器 WAN IP（如 192.168.2.2）。

**解决方案**：检查上游 LAN 与下游 WAN 之间的物理连接，确认下游路由器 WAN 接口已启动。

### 5. 端口已同步但外网无法访问

**逐项检查**：

1. 上游 WAN 是否有公网 IP？（检查 CGNAT：100.64.0.0/10）
2. nftables DNAT 规则是否存在？（`nft list table inet upnp_nat_relay`）
3. OpenClash 是否拦截了转发流量？
4. 入站目标 IP 是否位于 OpenClash 运行时 `localnetwork` 集合？
5. 下游 UPnP 映射是否仍然存在？
6. 下游路由器防火墙是否允许该映射？

## 项目边界

本插件**不会**：

- 让没有公网 IP 的网络从互联网可达
- 绕过运营商 CGNAT
- 让 UPnP 本身变得安全
- 保证兼容所有路由器品牌
- 推荐开放低位特权端口
- 建议或执行读取接口与主 LAN 桥接
- 保证自动识别所有 OpenClash 版本的配置结构

## 项目结构

```
package/luci-app-upnp-nat-relay/
├── Makefile                                    # 包定义与构建规则
├── htdocs/luci-static/resources/
│   ├── upnp-nat-relay/
│   │   ├── upnp-nat-relay.css                  # 全局样式
│   │   └── utils.js                            # 共享工具函数
│   └── view/upnp-nat-relay/
│       ├── overview.js                         # 概览仪表盘
│       ├── wizard.js                           # 设置向导
│       ├── settings.js                         # 基本设置
│       ├── network.js                          # 网络与防火墙
│       ├── security.js                         # 安全过滤
│       ├── mappings.js                         # 映射表
│       ├── openclash.js                        # OpenClash 兼容
│       └── diagnostics.js                      # 诊断与回滚
├── po/                                         # 翻译文件
├── root/
│   ├── etc/
│   │   ├── config/upnp_nat_relay               # UCI 配置文件
│   │   └── init.d/upnp_nat_relay               # procd 服务脚本
│   └── usr/
│       ├── bin/upnp-nat-relay                  # 核心业务脚本
│       ├── libexec/rpcd/upnp_nat_relay         # RPC 后端（23 个 API 方法）
│       └── share/
│           ├── luci/menu.d/                    # LuCI 菜单注册
│           └── rpcd/acl.d/                     # RPC 权限控制
```

## 架构设计

```
┌──────────────┐     ubus/rpcd     ┌──────────────────┐     UCI      ┌──────────────┐
│  LuCI 前端    │ ──────────────→  │  rpcd 后端        │ ──────────→ │  UCI 配置     │
│  (8 个 JS 视图)│ ←──────────────  │  (23 个 API 方法)  │ ←──────────  │  upnp_nat_relay│
└──────────────┘     JSON 响应      └──────────────────┘              └──────┬───────┘
                                                                            │
                                                              upnp-nat-relay
                                                                            │
                                                                   ┌────────▼────────┐
                                                                   │  nftables DNAT   │
                                                                   │  + OpenClash 规则 │
                                                                   └────────┬────────┘
                                                                            │
                                                              读取 UPnP → 过滤 → 创建规则
```

**数据流**：

1. 前端通过 `ubus call upnp_nat_relay <method>` 调用 rpcd 后端
2. 后端调用 `upnp-nat-relay` 执行具体操作
3. 守护进程按配置间隔自动同步 UPnP 映射
4. 同步结果写入状态文件 `/tmp/upnp_nat_relay/`
5. 日志写入 `/tmp/upnp_nat_relay/upnp-nat-relay.log`

## UCI 配置参考

### service section (main)

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `enabled` | boolean | 0 | 是否启用自动同步 |
| `interval` | integer | 60 | 同步间隔（秒） |
| `backend` | string | `upnpc` | UPnP 后端 |
| `bind_ifname` | string | `eth2` | 绑定接口名 |
| `bind_ip` | string | `192.168.3.50` | 绑定 IP |
| `downstream_lan_gateway` | string | `192.168.3.1` | 下游 LAN 网关 |
| `downstream_lan_subnet` | string | `192.168.3.0/24` | 下游 LAN 子网 |
| `downstream_wan_ip` | string | `192.168.2.2` | 下游 WAN IP |
| `upstream_wan_if` | string | `pppoe-wan` | 上游 WAN 接口 |
| `show_advanced_config` | boolean | 0 | 显示高级配置 |
| `auto_config_network` | boolean | 0 | 自动配置网络 |
| `auto_config_firewall_zone` | boolean | 0 | 自动配置防火墙区域 |
| `firewall_zone_name` | string | `upnp_nat` | 防火墙区域名 |
| `allowed_external_ports` | string | `40000-65535` | 允许的外部端口范围 |
| `protocols` | string | `tcp udp` | 允许的协议 |
| `failure_grace_count` | integer | 3 | 失败宽限次数 |
| `clear_on_stop` | boolean | 1 | 停止时清理规则 |
| `dry_run` | boolean | 0 | 试运行模式 |
| `log_level` | string | `info` | 日志级别 |
| `deny_low_ports` | boolean | 1 | 拒绝特权端口 |
| `restrict_to_subnet` | boolean | 1 | 限制到子网 |
| `deny_empty_description` | boolean | 0 | 拒绝空描述映射 |
| `log_rejected` | boolean | 1 | 记录被拒绝的映射 |
| `openclash_mode` | enum | `prompt` | 旧配置兼容项；入站转发旁路不支持，不写入规则 |
| `openclash_return_strategy` | enum | `per_mapping` | 旧配置兼容项；当前不生成 RETURN 规则 |
| `openclash_backup` | boolean | 1 | 旧配置兼容项；不写入 OpenClash 规则 |
| `openclash_rule_remark` | string | `UPnP NAT Relay Auto RETURN` | 旧配置兼容项；不写入 OpenClash 规则 |
| `openclash_auto_restart` | 旧配置项 | — | 已废弃；升级时删除。写入规则不会自动重启 OpenClash |
| `openclash_sync_interval` | integer | 0 | OpenClash 同步间隔（0=跟随主同步） |

### deny_ports section (default)

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `port` | list | 22,23,25,53,80,110,143,443,445,465,587,993,995,1433,3306,3389,5432,6379,8080,8443 | 拒绝的端口列表 |

### backend section (upnpc)

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `enabled` | boolean | 1 | 是否启用 |
| `command` | string | `upnpc` | 后端命令 |
| `timeout` | integer | 10 | 超时时间（秒） |

### backend section (custom)

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `enabled` | boolean | 0 | 是否启用 |
| `command` | string | — | 自定义后端命令 |
| `output_format` | string | `json` | 输出格式 |

## 命令行参考

```sh
# 环境和依赖检查
upnp-nat-relay --check-env

# 网络连通性检查
upnp-nat-relay --check-network

# 读取网络缓存
upnp-nat-relay --network-cache

# 干跑模式：读取并过滤映射，不写入 nftables
upnp-nat-relay --dry-run

# 完整同步：读取、过滤并创建 DNAT 规则
upnp-nat-relay --sync

# 生成 OpenClash RETURN 规则
upnp-nat-relay --generate-openclash-rule

# 读取 OpenClash 规则缓存
upnp-nat-relay --openclash-rule-cache

# 清除插件所有 nftables 规则
upnp-nat-relay --clear

# 显示当前状态
upnp-nat-relay --status

# 刷新环境信息
upnp-nat-relay --refresh-env

# 导出下游路由器当前 UPnP 映射
upnp-nat-relay --dump-mappings

# 自动创建读取网络接口
upnp-nat-relay --setup-interface

# 修复或创建防火墙区域
upnp-nat-relay --fix-zone

# 应用 OpenClash RETURN 规则
upnp-nat-relay --setup-openclash

# 重启 OpenClash 服务
upnp-nat-relay --restart-openclash

# 移除插件的 OpenClash RETURN 规则
upnp-nat-relay --remove-openclash-rule

# 同步 OpenClash 规则
upnp-nat-relay --sync-openclash

# 回滚所有插件创建的配置
upnp-nat-relay --rollback

# 读取日志
upnp-nat-relay --read-log

# 清除日志
upnp-nat-relay --clear-log

# 以守护进程模式运行
upnp-nat-relay --daemon
```

## 许可证

GPLv3 License，详见 [LICENSE](LICENSE)。
