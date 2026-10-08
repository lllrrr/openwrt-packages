# luci-app-frpc-multi

用于 OpenWrt / iStoreOS 的 LuCI 多连接 FRP 客户端管理插件。每个连接都是独立的 `frpc` 进程，可分别连接不同的主端（frps）。

## 全新系统一键安装

在全新 OpenWrt / iStoreOS 上以 root 身份复制并运行下面**这一条命令**。脚本会检测 apk/opkg 与 arm64/x86_64，更新系统软件源、选包安装；包依赖由系统包管理器解析，并安装软件源中的匹配架构 `frpc` 内核。

```sh
wget -O /tmp/install-frpc-multi.sh https://raw.githubusercontent.com/myc2002/luci-app-frpc-multi/main/install.sh && sh /tmp/install-frpc-multi.sh
```

支持 apk + arm64/aarch64、apk + x86_64、opkg + arm64/aarch64、opkg + x86_64。其他架构会提示不支持。安装后打开 **LuCI → 服务 → frp 多客户端**。

全新系统须已联网，且配置了当前发行版可用的软件源；若软件源不提供兼容 `frpc` 版本，系统包管理器会报依赖错误，不会从别处静默安装内核。

APK/IPK 是通用 LuCI 脚本，不含 CPU 专用二进制；APK 按 apk 架构标签构建，IPK 内部为 `Architecture: all`，文件名按目标架构区分。FRPC 由 apk/opkg 从系统软件源安装。APK 未签名（安装器使用 `--allow-untrusted`）；请只使用可信 HTTPS Release，并按 `SHA256SUMS` 校验。

## 功能

- 每个连接对应独立 frpc 进程；连接名支持中文，内部 ID 自动生成。
- 支持 tcp、udp、http、https、tcpmux、stcp、xtcp、sudp。
- 集成令牌、TLS、协议、多路复用、连接池、心跳、DNS、出口代理、带宽限制、加密和压缩。
- 支持 HTTP 域名/认证、visitor 与 HTTP/SOCKS5/static_file/unix_domain_socket 插件。
- 状态卡片显示连接状态、PID、代理在线情况和错误；可单独启停、重启、看日志。
- 登录失败默认持续重试；procd 无限重启；每分钟看门狗可关闭。
- 保存配置后只重启发生变化的连接。

**容量说明：**可创建的连接数没有软件内的固定数量限制，但受设备资源和状态 API 端口限制。当前状态 API 自动分配 27400–27999，最多 600 个端口，且占用端口会减少可用数量；不是物理“无限”。

## 兼容要求

- APK：使用 apk 的 OpenWrt/iStoreOS。
- IPK：使用 opkg 的 OpenWrt。
- 需要 LuCI、rpcd ucode 及 ucode uci/ubus/fs/socket 模块。
- `frpc` 0.66.0 已验证；需要支持 TOML 与 loopback `webServer` 状态 API 的版本。
- 已在 iStoreOS 25.12.5 x86_64 上验证。其他设备请备份并确认软件源能提供兼容 `frpc`。

## 使用

1. 点「添加连接…」，填写名称、主端地址/端口、令牌等。
2. 点「添加代理…」，选择所属连接，设置本地目标和远程端口。
3. 保存并应用，在状态卡片确认连接和代理在线。

页面显示的是「名称」；内部 ID（如 `c1`）只用于进程、日志和配置文件名，编辑弹窗内只读显示。已有连接 ID 不变。TLS 默认开启；请与主端设置一致。页面「停用」会持久保存，命令行单独 `stop` 可能被看门狗重新启动。插件不会迁移或停用其他 FRPC 插件；迁移时先停旧实例，避免代理名/端口冲突。插件不会自动修改公网防火墙。

## 一键安装脚本做什么

`install.sh`：检查 root、通过 `uname -m` 识别 arm64/x86_64，再检测 `/etc/apk` 下的 apk 或 opkg；运行包管理器的 `update`，并安装本仓库对应 Release 包。它不通过架构通配/不受信来源绕过系统依赖解析。若依赖下载失败会原样报错退出。源文件：[install.sh](install.sh)。

## 路径与常用命令

- `/etc/config/frpc_multi`：UCI 配置（600，含令牌）。
- `/etc/init.d/frpc-multi`：每连接生成 `/var/etc/frpc-multi/<ID>.toml`（600）。
- `/usr/sbin/frpc-multi-watchdog`：每分钟兜底。

```sh
/etc/init.d/frpc-multi checkconfig [内部ID]
/etc/init.d/frpc-multi restart <内部ID>
/etc/init.d/frpc-multi reload
apk del luci-app-frpc-multi       # 或 opkg remove luci-app-frpc-multi
```

升级保留 UCI 配置。卸载停止连接、删本插件的开机项和 cron，但保留配置文件；删除含令牌配置前自行备份。

## 校验

下载 Release 中适用于本机的 APK/IPK 及 `SHA256SUMS`。Linux 运行 `sha256sum -c SHA256SUMS` 校验发布附件。

## 构建

- `build-release-matrix.sh` 使用 Docker/alpine:edge 的 apk mkpkg 生成 `aarch64` 和 `x86_64` APK、脚本通用 IPK，并写 SHA256 清单。
- `scripts/make-ipk.py` 构造 opkg IPK；FRPC 由 `Depends` 从设备软件源按架构安装。
- 公开仓库没有 GitHub Actions，避免请求额外 workflow 权限；手动构建不自动覆盖 Release。

## 测试范围

已测试配置生成与 frpc verify、单实例启停与无限重试、看门狗、loopback API 认证、临时本机 frps 的端口转发、LuCI 页面以及 APK 安装/升级/卸载/重装。未进行真实断电验收，未保证所有协议/FRP 版本组合。

## 安全与许可证

frpc 状态 API 仅绑定 `127.0.0.1`，管理口令随机生成；rpcd 方法受 LuCI ACL 保护。服务以 root 运行；配置、日志可能含敏感信息，禁止将真实配置/令牌提交到公开仓库。附加 TOML 是管理员输入，不是安全沙箱。

新增代码采用 Apache-2.0；从 OpenWrt FRPC/procd 初始化模式保留的部分按上游 GPL-2.0，见 `NOTICE` 和 `LICENSES/GPL-2.0.txt`。FRP 二进制是独立依赖，不包含在本插件包中。
