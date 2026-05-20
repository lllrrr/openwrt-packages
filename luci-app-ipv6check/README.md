# luci-app-ipv6check

OpenWrt IPv6 连通性检测 LuCI 插件

## 功能特性

- **多源检测** — 同时 ping6 多个 IPv6 目标地址（默认内置 Google / Cloudflare / 阿里云 DNS）
- **定时监测** — 可配置检测间隔（默认 5 分钟），由 procd 服务管理
- **自动恢复** — 所有目标连续失败达到阈值后自动 `ifdown/ifup` 重启指定接口（默认 wan6）
- **Web 管理界面** — 通过 LuCI 查看实时状态、检测日志和接口重启历史
- **手动操作** — 支持一键手动检测和手动重启接口
- **灵活配置** — 所有参数通过 UCI 配置，支持 LuCI 在线修改

## 安装

### 方式一：OpenWrt SDK 编译安装

```bash
# 1. 将插件目录复制到 SDK 的 feeds 中
cp -r luci-app-ipv6check /path/to/openwrt/feeds/luci/applications/

# 2. 更新 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 3. 选择插件
make menuconfig
# -> LuCI -> 3. Applications -> luci-app-ipv6check

# 4. 编译
make package/luci-app-ipv6check/compile V=s
```

### 方式二：手动安装（直接部署到路由器）

```bash
# 将文件复制到路由器对应目录
scp -r root/* root@router:/
scp -r htdocs/luci-static/resources/view/ipv6check/* root@router:/www/luci-static/resources/view/ipv6check/

# 设置执行权限
ssh root@router "chmod +x /usr/bin/ipv6check /usr/libexec/rpcd/ipv6check /etc/init.d/ipv6check"

# 重启 rpcd 并启动服务
ssh root@router "/etc/init.d/rpcd restart && /etc/init.d/ipv6check enable && /etc/init.d/ipv6check start"
```

## 使用说明

安装后在 LuCI 菜单中访问：**网络 → IPv6 连通检测**

### 运行状态页

- 查看所有检测目标的实时连通状态
- 一键手动触发检测
- 手动重启网络接口
- 查看检测日志和接口重启历史

### 参数配置页

- 启用/禁用监测服务
- 设置检测间隔、重试参数
- 配置失败阈值和自动重启行为
- 添加/删除/修改检测目标地址

## UCI 配置说明

配置文件位于 `/etc/config/ipv6check`

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `enabled` | `1` | 是否启用监测 |
| `interval` | `300` | 检测间隔（秒） |
| `retry_count` | `3` | 每个目标的重试次数 |
| `retry_interval` | `10` | 重试间隔（秒） |
| `failure_threshold` | `3` | 连续全部失败次数阈值 |
| `auto_restart` | `1` | 是否自动重启接口 |
| `restart_interface` | `wan6` | 重启的网络接口 |
| `log_level` | `1` | 日志级别: 0=静默 1=普通 2=详细 |

## 文件结构

```
luci-app-ipv6check/
├── Makefile                                          # OpenWrt 构建文件
├── README.md                                         # 本文档
├── htdocs/luci-static/resources/view/ipv6check/
│   ├── config.js                                     # 配置页面 JS
│   └── status.js                                     # 状态页面 JS
└── root/
    ├── etc/config/ipv6check                          # UCI 配置
    ├── etc/init.d/ipv6check                          # procd 服务
    ├── etc/uci-defaults/luci-app-ipv6check           # 初始化脚本
    ├── usr/bin/ipv6check                             # 核心监测脚本
    ├── usr/libexec/rpcd/ipv6check                    # RPC 后端
    ├── usr/share/luci/menu.d/luci-app-ipv6check.json # 菜单定义
    └── usr/share/rpcd/acl.d/luci-app-ipv6check.json  # 权限定义
```

## 兼容性

- OpenWrt 21.02+ (LuCI JS 客户端渲染架构)
- 需要 `iputils-ping6` 或内置 `ping6` 命令

## 许可证

GPL-2.0-only
