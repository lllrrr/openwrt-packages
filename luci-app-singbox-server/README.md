# luci-app-singbox-server

独立的 sing-box 服务端 LuCI 插件，从 [homeproxy](https://github.com/immortalwrt/homeproxy) 
中提取的纯服务端功能，无需客户端路由/DNS 劫持等依赖。

## 功能特点

- **多协议支持**：Mixed, HTTP, SOCKS5, Shadowsocks, Trojan, VLESS, VMess, 
  Hysteria v1/v2, TUIC v5, NaïveProxy, AnyTLS
- **传输层**：WebSocket, gRPC, HTTP/2, HTTP Upgrade
- **TLS 模式**：
  - 手动证书（PEM 文件上传）
  - ACME 自动签发（HTTP-01 / TLS-ALPN-01 / DNS-01 挑战，支持 Let's Encrypt、ZeroSSL、Google 等）
  - VLESS REALITY（自动生成密钥对）
  - ECH（Encrypted Client Hello）
- **高级选项**：多路复用（含 TCP Brutal）、协议探测 Sniff、TCP Fast Open / UDP Fragment
- **一键生成**：UUID、REALITY 密钥对、ECH 密钥对
- **状态监控**：实时显示进程运行状态与 sing-box 版本，支持界面内启动/停止/重启

## 依赖

| 包 | 用途 |
|---|---|
| `sing-box` | 核心代理引擎 |
| `ucode-mod-fs` | Ucode 文件系统模块（配置生成脚本） |
| `ucode-mod-uci` | Ucode UCI 模块（读取配置） |

## 目录结构

```
luci-app-singbox-server/
├── Makefile
├── htdocs/luci-static/resources/view/singbox-server/
│   └── main.js                     ← LuCI 前端视图
└── root/
    ├── etc/
    │   ├── capabilities/singbox-server.json   ← ujail 权限
    │   ├── config/singbox-server              ← UCI 默认配置
    │   ├── init.d/singbox-server              ← procd 服务脚本
    │   └── singbox-server/
    │       ├── certs/                         ← TLS 证书存放目录
    │       └── scripts/generate_server.uc     ← JSON 配置生成脚本
    └── usr/share/
        ├── luci/menu.d/luci-app-singbox-server.json
        └── rpcd/ucode/luci.singbox-server     ← RPC 后端（证书上传 / 密钥生成）
```

## 安装

### 方式一：OpenWrt 构建系统

将本目录放入 `feeds/luci/applications/` 后执行：

```bash
make package/luci-app-singbox-server/compile V=s
```

### 方式二：手动部署（开发调试）

```bash
# 1. 复制文件
cp -r root/* /
cp -r htdocs/* /www/

# 2. 赋予 init 脚本可执行权限
chmod +x /etc/init.d/singbox-server
chmod +x /etc/singbox-server/scripts/generate_server.uc

# 3. 创建证书目录
mkdir -p /etc/singbox-server/certs

# 4. 刷新 LuCI 缓存
rm -rf /tmp/luci-*

# 5. 启用服务
/etc/init.d/singbox-server enable
```

## UCI 配置示例

```uci
# /etc/config/singbox-server

config singbox-server 'config'
    option enabled '1'
    option log_level 'warn'

# VLESS + REALITY 示例
config server
    option enabled '1'
    option label 'vless-reality'
    option type 'vless'
    option address '::'
    option port '443'
    option uuid 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    option vless_flow 'xtls-rprx-vision'
    option tls '1'
    option tls_reality '1'
    option tls_reality_handshake_server 'google.com'
    option tls_reality_handshake_port '443'
    option tls_reality_private_key '<your-private-key>'
    option tls_reality_short_id 'abcdef01'

# Trojan + TLS + WebSocket 示例
config server
    option enabled '1'
    option label 'trojan-ws'
    option type 'trojan'
    option address '::'
    option port '8443'
    option password 'your-password'
    option transport 'ws'
    option ws_path '/trojan'
    option tls '1'
    option tls_acme '1'
    option tls_acme_domain 'yourdomain.example.com'
    option tls_acme_email 'admin@example.com'
    option tls_acme_provider 'letsencrypt'

# Shadowsocks 2022 示例
config server
    option enabled '1'
    option label 'ss2022'
    option type 'shadowsocks'
    option address '::'
    option port '8388'
    option shadowsocks_encrypt_method '2022-blake3-aes-128-gcm'
    option password '<base64-16-bytes>'
```

## 工作原理

```
UCI 配置 (/etc/config/singbox-server)
        │
        ▼ ucode scripts/generate_server.uc
/var/run/singbox-server/sing-box-s.json
        │
        ▼ sing-box run --config
sing-box 进程监听各 inbound 端口
```

`init.d/singbox-server` 调用 `ucode generate_server.uc` 生成 JSON，
随后通过 `procd` 启动 `sing-box run --config sing-box-s.json`，
支持 ujail 沙箱隔离（需要 `/sbin/ujail` 存在）。

## 与 homeproxy 的区别

| 功能 | homeproxy | luci-app-singbox-server |
|---|:---:|:---:|
| 代理服务端 | ✅ | ✅ |
| 代理客户端 | ✅ | ❌ |
| 透明代理/路由 | ✅ | ❌ |
| DNS 劫持 | ✅ | ❌ |
| 订阅管理 | ✅ | ❌ |
| 独立部署 | ❌ | ✅ |

## License

GPL-2.0-only
