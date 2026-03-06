# luci-app-argo

LuCI 界面管理 Cloudflare Tunnel (Argo) 的插件，适用于 OpenWrt / iStoreOS。

## 功能特点

- 🖥️ **图形化管理界面** - 通过 LuCI Web 界面管理 Cloudflare Tunnel
- 🔧 **一键安装** - 自动检测架构并下载官方二进制文件
- 🚀 **服务管理** - 启动/停止/重启服务，开机自启
- 🔐 **Token 配置** - 安全存储 Cloudflare Tunnel Token
- 📋 **日志查看** - 实时查看运行日志
- 🌐 **中文界面** - 完整的简体中文汉化

## 系统要求

- OpenWrt 18.06+ 或 iStoreOS
- LuCI (luci-base)
- 至少 50MB 可用存储空间
- 支持的架构: amd64 (x86_64), arm64 (aarch64), arm (armv7)

## 安装方法

### 方法一：从源码编译

1. 将本仓库克隆到 OpenWrt SDK 的 package 目录：
```bash
cd /path/to/openwrt/package
git clone https://github.com/hxzlplp7/luci-app-argo.git
```

2. 编译安装包：
```bash
make package/luci-app-argo/compile V=s
```

3. 在 `bin/packages/` 目录下找到生成的 ipk 文件并安装：
```bash
opkg install luci-app-argo_*.ipk
```

### 方法二：直接安装 ipk

1. 下载 Release 中的 ipk 文件
2. 上传到路由器并安装：
```bash
opkg install luci-app-argo_*.ipk
```

## 使用方法

### 第一步：在 Cloudflare 创建隧道获取 Token

1. 打开 [Cloudflare Zero Trust 面板](https://one.dash.cloudflare.com/)
2. 登录您的 Cloudflare 账户
3. 在左侧菜单找到 **Networks** → **Tunnels**
4. 点击 **Create a tunnel** (创建隧道)
5. 选择 **Cloudflared** 作为连接器类型
6. 给隧道起一个名字 (例如: openwrt-tunnel)
7. 在 "Install and run a connector" 页面，找到类似这样的命令：
   ```
   cloudflared tunnel run --token eyJhIjoixxxxx...
   ```
8. 复制 `--token` 后面的那一长串字符（以 eyJ 开头的 Base64 编码字符串）

### 第二步：在 LuCI 中配置

1. 登录 OpenWrt 管理界面
2. 进入 **服务** → **Argo 隧道**
3. 如果 cloudflared 未安装，点击安装按钮
4. 在 **Tunnel Token** 字段粘贴第一步获取的 Token
5. 勾选 **启用**
6. 点击 **保存并应用**

### 第三步：配置 Public Hostname

1. 回到 Cloudflare Zero Trust 面板
2. 在您的隧道配置中添加 **Public Hostname**
3. 配置域名指向您的内网服务

## 目录结构

```
luci-app-argo/
├── Makefile                              # OpenWrt 包 Makefile
├── htdocs/
│   └── luci-static/
│       └── resources/
│           └── view/
│               └── argo/
│                   └── argo.js           # LuCI 前端视图
├── po/
│   ├── templates/
│   │   └── argo.pot                      # 翻译模板
│   ├── zh_Hans/
│   │   └── argo.po                       # 简体中文翻译
│   └── zh-cn/
│       └── argo.po                       # 简体中文翻译（兼容）
└── root/
    ├── etc/
    │   ├── config/
    │   │   └── argo                      # UCI 配置文件
    │   ├── init.d/
    │   │   └── argo                      # init.d 服务脚本
    │   └── uci-defaults/
    │       └── luci-app-argo             # 安装后脚本
    └── usr/
        ├── libexec/
        │   └── rpcd/
        │       └── luci.argo             # RPC 辅助脚本
        └── share/
            ├── luci/
            │   └── menu.d/
            │       └── luci-app-argo.json    # 菜单配置
            └── rpcd/
                └── acl.d/
                    └── luci-app-argo.json    # 权限配置
```

## 文件路径

- **二进制文件**: `/usr/bin/cloudflared`
- **配置目录**: `/etc/argo/`
- **Token 文件**: `/etc/argo/token`
- **服务脚本**: `/etc/init.d/argo`

## 许可证

Apache License 2.0

## 致谢

- [Cloudflare](https://www.cloudflare.com/) - 提供 cloudflared 二进制文件
- [OpenWrt](https://openwrt.org/) - 开源路由器固件
- [hxzlplp7/openwrt-one-click-cloudflared](https://github.com/hxzlplp7/openwrt-one-click-cloudflared) - 原始脚本灵感来源
