# luci-app-frpc-multi

用于 OpenWrt / iStoreOS 的 LuCI 多连接 FRP 客户端管理插件。每个连接都是独立的 `frpc` 进程，可分别连接不同的主端（frps）。

> **r10 架构修复：** 旧版 APK 的 `aarch64` 标签不等于 OpenWrt 的 `aarch64_generic` / `aarch64_cortex-a53`。插件只有脚本，现改为 APK `noarch` 和 IPK `all` 通用包。重新运行以下一键命令，不要强制改架构或跳过依赖。r8 的 IPK 格式问题已在 r9 修复。

## 全新系统一键安装

在全新 OpenWrt / iStoreOS 上以 root 身份复制并运行下面**这一条命令**。脚本会检测 apk/opkg 与 arm64/x86_64，更新系统软件源、选包安装；包依赖由系统包管理器解析，并安装软件源中的匹配架构 `frpc` 内核。

```sh
wget -O /tmp/install-frpc-multi.sh https://raw.githubusercontent.com/myc2002/luci-app-frpc-multi/main/install.sh && sh /tmp/install-frpc-multi.sh
```

支持 apk + arm64/aarch64、apk + x86_64、opkg + arm64/aarch64、opkg + x86_64。其他架构会提示不支持。安装后打开 **LuCI → 服务 → frp 多客户端**。

全新系统须已联网，且配置了当前发行版可用的软件源，以安装 LuCI/ucode 等依赖。安装器随后用 `frpc verify` 检查 TOML 等必需能力。若系统 frpc（例如 0.51.3）过旧，将明确提示并从 fatedier/frp 官方 GitHub Release 下载对应架构的 **0.66.0**，按固定 SHA256 验证，安装到 `/usr/lib/frpc-multi/frpc`。这份内核仅本插件优先使用，不覆盖 `/usr/bin/frpc`，不改变其他 FRPC 插件。

APK/IPK 仅含通用 LuCI 脚本，不含 CPU 专用二进制。APK 包内架构为 **`noarch`**，IPK 为 **`Architecture: all`**；每个格式只需一个文件，可用于上述 ARM64/x86_64 系统，包括 `aarch64_generic`、`aarch64_cortex-a53`。`uname -m` 仅用来选择需要下载的 FRPC 官方内核，不作为插件包的架构标签。FRPC 由 apk/opkg 从本设备软件源安装。APK 未签名（安装器使用 `--allow-untrusted`）；请只使用可信 HTTPS Release，并按 `SHA256SUMS` 校验。

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

`install.sh`：检查 root、识别 arm64/x86_64 和 apk/opkg；下载并校验插件 SHA256，运行包管理器 update/install；验证 frpc 能力，必要时下载校验官方 0.66.0 独立内核，最后重载本插件。**手工只安装 APK/IPK 不会执行独立内核下载步骤，旧内核系统请使用上方一键命令。** 源文件：[install.sh](install.sh)。

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

- `build-release-matrix.sh` 生成 `noarch` APK 和 `all` IPK，并写 SHA256 清单。APK 默认使用 Docker/alpine:edge；也可设置 `APK_MKPKG=/path/to/apk-v3` 使用本地 apk v3 工具。
- `scripts/make-ipk.py` 构造 opkg IPK；FRPC 由 `Depends` 从设备软件源按架构安装。
- 公开仓库没有 GitHub Actions，避免请求额外 workflow 权限；手动构建不自动覆盖 Release。

## 测试范围

r10 使用真实 apk-tools v3 在隔离根目录验证 `aarch64_generic` / `aarch64_cortex-a53` / `x86_64` 均可安装 `noarch` APK，同时确认错误的 `aarch64` 包被拒绝；真实 OpenWrt opkg 验证这三种架构可安装 `all` IPK、权限正确、升级保留配置。此架构验收使用测试依赖占位，未运行服务安装钩子，不等于完整设备运行验收。可复用测试见 `tests/test-apk-architectures.sh`、`tests/test-opkg-architectures.py`；安装器七种组合测试见 `tests/test-installer.py`。

已测试配置生成与 frpc verify、单实例启停与无限重试、看门狗、loopback API 认证、临时本机 frps 的端口转发、LuCI 页面以及 APK 安装/升级/卸载/重装。未进行真实断电验收，未保证所有协议/FRP 版本组合。

## 安全与许可证

frpc 状态 API 仅绑定 `127.0.0.1`，管理口令随机生成；rpcd 方法受 LuCI ACL 保护。服务以 root 运行；配置、日志可能含敏感信息，禁止将真实配置/令牌提交到公开仓库。附加 TOML 是管理员输入，不是安全沙箱。

新增代码采用 Apache-2.0；从 OpenWrt FRPC/procd 初始化模式保留的部分按上游 GPL-2.0，见 `NOTICE` 和 `LICENSES/GPL-2.0.txt`。FRP 二进制是独立依赖，不包含在本插件包中。
