# luci-app-oxidns（NetForgeCN）

[English](./README.en.md)

一个面向 OpenWrt 的 OxiDNS 管理插件。安装后，LuCI 的 `Services -> OxiDNS` 提供内核、配置、服务、日志、规则和预热的完整管理界面。

它在 [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) 的框架之上，补齐了“**装好即用、升级不丢、常用域名提前解析**”的能力。基于 GPL-3.0-or-later 发布。

## 相比上游增加了什么

| 能力 | 这个版本 | 带来的好处 |
|---|---|---|
| 内核随包分发 | `oxidns-core` 子包在编译期内置官方核心、WebUI 和默认配置 | 刷完固件就有 DNS 能力，首次使用无需联网安装内核 |
| 规则随包分发 | `oxidns-rules-baseline` 子包内置 5 份规则基线 | 首次启动完全离线完成，规则文件缺失时自动补齐 |
| 规则订阅管理 | `Data & Updates -> 规则基线` 检查 / 更新，带 SHA256 校验、暂存校验和回滚 | 一键完成规则升级，替换前先完成校验与暂存 |
| 域名预热 | `Configuration -> 预热` 按 A / AAAA 提前查询并写入缓存 | 常用域名首次访问直接使用缓存，减少等待 |
| 内核在线升级 | `Data & Updates -> 内核` 的 `Check Update` | 不用重新编译固件即可升级内核 |
| 日志筛选 | 关键词 + `plugin` / `qtype` / `rcode` 过滤，实时行数 | 快速定位某类查询，日志再多也能看 |
| DNS 劫持 | `Overview -> DNS Hijack` 一键把 LAN 53 端口重定向到本机 OxiDNS，IPv4/IPv6 全覆盖 | 局域网设备无需改 DNS 即可走 OxiDNS，能看到真实客户端 IP |
| CodeMirror 编辑器 | 配置页用 YAML 语法高亮编辑器，带行号、内部滚动 | 编辑长配置不跳屏，改配置更直观 |
| Geo 数据管理 | `Data & Updates -> Geo 数据` 在线下载/更新 geoip.dat 与 geosite.dat，地址可改可还原 | 数据更新不用重新编译固件，默认走自建规则源 |
| API 凭据托管 | 用户名与密码存 `0600` 凭据文件，脚本注入 `${OXIDNS_API_USER}` / `${OXIDNS_API_PASS}` | UCI 与 YAML 都不放明文，旧密码一键迁移 |
| 升级自愈 | 内核、WebUI、配置和规则在 sysupgrade 后自动恢复 | 保留配置升级固件后，重装一次插件即可恢复服务 |

## 页面一览

顶部只有 4 个一级入口，原来的 9 个页面收进页内子标签。RPC、UCI 配置和 ACL 都没有变化；旧地址以隐藏菜单节点保留，仍可直达对应面板，但不再显示在侧栏。

| 一级入口 | 子标签 | 用途 |
|---|---|---|
| `Overview` | 概览 | 内核 / 服务状态、WebUI 入口、配置路径、诊断快捷入口 |
| `Overview` | DNS Hijack | LAN 53 端口重定向开关、目标端口来源、防火墙段状态 |
| `Configuration` | YAML 配置 | CodeMirror 高亮编辑、校验、保存 `config.yaml` |
| `Configuration` | Settings | 仓库、bundle、代理、路径、日志与 API 凭据管理 |
| `Configuration` | 预热 | 预热开关、域名清单、目标地址与周期、手动执行 |
| `Data & Updates` | 内核 | 安装、上传、升级、修复或移除内核 |
| `Data & Updates` | 规则基线 | 规则基线状态、检查更新、一键更新 |
| `Data & Updates` | Geo 数据 | geoip.dat / geosite.dat 状态、下载地址、目录、在线更新 |
| `Logs` | — | 过滤和刷新日志，探测全部上游的应答 / TTL / 耗时 |

子标签采用懒渲染：只有首次切到该标签时才构建界面，避免编辑器在隐藏面板里量到零宽度；切走的标签会停止轮询，再次进入时恢复。

> 安全提示：上传内核默认关闭。需要在 `Configuration -> Settings` 勾选“允许手动上传内核”，并且登录用户具备 `luci-app-oxidns-core-upload` ACL 组权限（默认 root 账号具备）；上传的二进制不会在校验阶段执行，仅作为服务内核运行。`Data & Updates -> Geo 数据` 可填写可选 SHA-256 校验值，下载内容校验失败会保留现有数据。

## 快速开始

1. 按下面的“构建与安装”把插件装进固件或路由器。
2. 打开 `Services -> OxiDNS -> Configuration -> Settings` 子标签的 `API credentials`，点 `Generate credentials`，立即复制并保存。凭据写入 `/etc/oxidns/api-auth.env`（权限 `0600`），不会写入 UCI。旧版 UCI 密码可用 `Migrate UCI password` 一键迁移并清除。
3. 在 `Configuration -> YAML 配置` 子标签按需编辑 `config.yaml`，点 `Save & Restart`。配置里使用 `${OXIDNS_API_USER}` / `${OXIDNS_API_PASS}` 引用凭据。
4. 打开 `Overview`，启动服务并启用开机自启；页面上的 `Diagnostics` 可直达上游探测和凭据管理。
5. 打开 `Configuration -> 预热` 子标签，确认目标地址与 `config.yaml` 中的监听一致，点 `Run now` 立即预热。
6. 打开 `Logs -> Upstream probe`，从 `config.yaml` 读取全部上游并直接查询，查看应答、TTL、耗时与不可探测原因。

> Basic Auth 用 Base64 传输凭据，不是加密。管理 API 应只监听回环地址；如需远程访问，请启用 TLS 或通过 VPN 暴露。

## 域名预热（Prewarm）

预热会遍历清单里的每个域名，向指定的 OxiDNS 监听地址发起 A 和 AAAA 查询。查询经过该监听入口的规则链并进入缓存后，客户端首次访问这些域名时就能直接命中。

| 项目 | 默认值 |
|---|---|
| 启用 | 开 |
| 目标 | `udp://127.0.0.1:5333` |
| 周期 | 3000 秒（约 50 分钟） |
| 清单 | 包内默认 75 个域名，可在页面增删 |
| 并发 | 4 |
| 单次查询超时 / 重试 | 2 秒 / 1 次 |

让预热生效只需要三件事：

- `config.yaml` 里有 `cache` 插件，并且它在预热目标入口实际执行的链路上；
- 预热页里的 IP、端口、协议与 `udp_server` / `tcp_server` 的 `listen` 一致；
- 路由器上有 `dig`（由 `bind-dig` 提供，已作为本插件依赖自动安装）。

预热固定使用 `dig` 指定 `@IP -p 端口` 查询，不再使用 BusyBox `nslookup`：不同固件的 `nslookup` 自定义端口写法不一致（`-port` / `-p` / 不支持），可能导致查询落到 53 端口而预热无效。

页面上的 `Server IP` 可选 `127.0.0.1` 或 `192.168.1.1`；端口和协议可自由填写。`Run now` 不受总开关影响，可随时手动执行一轮。周期填 `0` 表示服务启动时执行一次。

验证预热：

```sh
logread -t oxidns-prewarm              # 查看每轮结果
/usr/libexec/oxidns-prewarm --once     # 手动执行一轮
dig @127.0.0.1 -p 5333 youtube.com A   # 验证监听口在应答
```

## 规则基线

基线只包含 OxiDNS 实际加载的 5 份列表，构建时从上游拉取并校验，设备中不需要再做格式转换：

| 文件 | 用途 |
|---|---|
| `cn-domains.txt` | 国内域名长尾，配合 geosite 判定国内组 |
| `anti-ad-domains.txt` | anti-AD 域名表 |
| `adrules-domains.txt` | AdRules 域名表 |
| `neodevhost-domains.txt` | neoDevHost 域名表 |
| `adguard-hostlist.txt` | AdGuard HostlistsRegistry 规则 |

`cn-domains.txt` 由 dnsmasq-china-list 在构建机上转换生成，原始 conf 不随包分发。规则更新由 `Rules` 页统一处理，先校验再替换；校验不通过时自动保留上一版。

## DNS 劫持（DNS Hijack）

开启后会把局域网发往 53 端口的 DNS 请求（TCP + UDP、IPv4 + IPv6）用 fw4 redirect 重定向到本机 OxiDNS 监听地址，局域网设备无需单独改 DNS。目标端口默认从 `config.yaml` 的 `udp_server` / `tcp_server` 自动读取，也可在页面手动指定。

- 状态以 `/etc/config/firewall` 里的 `oxidns_hijack*` 段为准；只改这些带 `oxidns-dns-hijack` 标记的段，不动其它防火墙规则。
- 显式写入 `family=any`——fw4 对未指定 family 的 redirect 按 IPv4 兜底，不写会漏掉 IPv6 的 53 查询。安装时也会幂等修复旧版留下的段。
- 关闭时只删除受管段并重载防火墙，不影响其它规则。
- 劫持后来自局域网设备的查询会带真实客户端 IP，日志与统计不再全是 `127.0.0.1`。

注意：劫持的端口必须和 OxiDNS 的实际监听一致；若 `config.yaml` 用了非标准端口或经过端口映射，请切到手动模式填写真实端口。

## Geo 数据（Geo Data）

`Geo Data` 页管理 OxiDNS 的 `geosite.dat` 与 `geoip.dat`（供配置里的 `geosite_cn` / `geoip_cn` 等 provider 使用，落点 `/usr/share/v2ray`）。

默认下载地址指向自建的 **`NetForgeCN/v2ray-rules-dat`** release 资产：以 Loyalsoldier 全集为基础，额外合并 `netforge-antiad` / `netforge-adrules` / `netforge-neodev` / `netforge-ads` 广告标签（都并入 `category-ads-all`），每 2 小时跟随上游构建。使用稳定的 `releases/latest/download` 路径，始终取最新版本，无需手工改版本号。

| 项目 | 默认值 |
|---|---|
| GeoIP 地址 | `https://github.com/NetForgeCN/v2ray-rules-dat/releases/latest/download/geoip.dat` |
| GeoSite 地址 | `https://github.com/NetForgeCN/v2ray-rules-dat/releases/latest/download/geosite.dat` |
| 存储目录 | `/usr/share/v2ray` |

下载地址与存储目录都可在页面修改并一键恢复默认；下载先写临时文件再原子替换，失败时保留现有文件，勾选「下载后重启」可在成功后让新数据立即生效。

## 构建与安装

### 方式一：OpenWrt buildroot（推荐，可编进固件）

```sh
git clone https://github.com/openwrt/openwrt.git
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

git clone https://github.com/NetForgeCN/luci-app-oxidns.git package/luci-app-oxidns
make menuconfig
# LuCI -> Applications -> luci-app-oxidns
make package/luci-app-oxidns/compile V=s
```

硬依赖（选中插件会一起选中）：`oxidns-core`、`oxidns-rules-baseline`、`bind-dig`（预热用 `dig`），以及 LuCI/rpcd 基础组件 `luci-base`、`rpcd`、`jsonfilter`、`uclient-fetch`、`ca-bundle`。产物在 `bin/packages/<架构>/`。

OpenWrt 25.12 及更新版本的 LuCI 要求每个 JS 模块都返回 `baseclass.extend()` / `view.extend()` 生成的类构造器；本插件的 `tabs.js` 已按此修正。插件**不依赖** `openssl`、`base64` 等命令：生成随机凭据时依次尝试 `openssl rand -base64` → `base64` → BusyBox 自带的 `od`/`tr`/`cut`，最少只有 busybox 的固件也能生成合法的 32 位密码。

支持 x86_64、aarch64、i386、ARM hard-float（cortex 映射 armv7，其余映射 armv6）；soft-float ARM 不能直接使用官方 hard-float（eabihf）内核。MIPS 等未发布 musl 内核的架构**无法用 buildroot 打包内置内核**（`oxidns-core` 是硬依赖）；可以走下面的“快速打包”不嵌入内核，再从 `Core` 页上传适配的内核。

### 方式二：快速打包

需要 `node` 22、`tar`、`gzip` 以及 `sha256sum`（macOS 用 `shasum -a 256`）：

```sh
git clone https://github.com/NetForgeCN/luci-app-oxidns.git
cd luci-app-oxidns

# 只打插件，内核到页面安装；版本号默认读取根目录 Makefile
./scripts/build-luci-package.sh 0.2.0 dist

# 内置内核 + 规则基线（按路由器架构选 release 资产），先下载再校验
curl -fL -O https://github.com/svenshi/oxidns/releases/download/v1.7.1/oxidns-x86_64-unknown-linux-musl.tar.gz
curl -fL -O https://github.com/NetForgeCN/luci-app-oxidns/releases/download/rules-v2026.11.24.0419/oxidns-rules-baseline-2026.11.24.0419.tar.gz
cat > sha256sums.txt <<'EOF'
6c82984e477d70d0c9259a6c7997496e248c78a384b2b7585908bba7f4af854c  oxidns-x86_64-unknown-linux-musl.tar.gz
1084a9aa8a7986c6159fbeba78433ff64c26567bfe0f782822fc3898023b2a6a  oxidns-rules-baseline-2026.11.24.0419.tar.gz
EOF
sha256sum -c sha256sums.txt
./scripts/build-luci-package.sh 0.2.0 dist-embedded \
	oxidns-x86_64-unknown-linux-musl.tar.gz \
	oxidns-rules-baseline-2026.11.24.0419.tar.gz \
	6c82984e477d70d0c9259a6c7997496e248c78a384b2b7585908bba7f4af854c \
	1084a9aa8a7986c6159fbeba78433ff64c26567bfe0f782822fc3898023b2a6a
```

脚本强制要求这两个归档的 SHA256，校验失败或归档里含绝对路径、`..`、链接、设备文件时立即退出。升级内核或基线版本时，请同步更新 `oxidns-core/Makefile` / `oxidns-rules-baseline/Makefile` 中的哈希和上面的校验值。

安装（本地包未签名，先校验构建脚本生成的 `sha256sums.txt` 再安装）：

```sh
sha256sum -c sha256sums.txt
opkg install luci-app-oxidns_*.ipk
opkg install luci-i18n-oxidns-zh-cn_*.ipk
# apk 系统：校验通过后安装
apk add ./luci-app-oxidns_*.apk ./luci-i18n-oxidns-zh-cn_*.apk
```

若 apk 因本地包未签名而拒绝安装，请仅在对 `sha256sums.txt` 校验通过之后使用 `--allow-untrusted`。

## 持久化与升级

- 内核和 WebUI 放在持久区 `/etc/oxidns/core/`，`/usr/bin/oxidns`、`/usr/share/oxidns/webui` 只是指向它的符号链接；
- LuCI 页面、rpcd 后端和 `/etc/init.d/oxidns` 由软件包安装在 `/usr`，刷固件时会被新固件中的版本覆盖；配置、规则和内核留在 `/etc`；
- `/etc/oxidns`、`/etc/config/oxidns` 加入 `/etc/sysupgrade.conf`，配置跨固件升级保留；
- 开机时自动补齐缺失的符号链接和规则文件；
- 升级固件时勾选“保留配置”，刷完需要重新安装一次插件，才能恢复 `/usr` 下的页面、rpcd 与 init 脚本（持久的内核/配置无需再次下载）；
- 内核升级用 `Core -> Check Update`，规则升级用 `Rules` 页，二者互不影响。

## 默认路径

| 用途 | 路径 |
|---|---|
| 内核（运行 / 持久） | `/usr/bin/oxidns` → `/etc/oxidns/core/oxidns` |
| WebUI（运行 / 持久） | `/usr/share/oxidns/webui` → `/etc/oxidns/core/webui` |
| 核心配置 | `/etc/oxidns/config.yaml` |
| 工作目录 | `/var/lib/oxidns` |
| UCI 配置 | `/etc/config/oxidns` |
| 规则基线（只读） | `/usr/share/oxidns/rules-baseline` |
| 规则工作副本 | `/etc/oxidns/rules` |
| 预热清单 | `/etc/oxidns/prewarm.txt` |
| 服务脚本 | `/etc/init.d/oxidns` |

## 许可与致谢

GPL-3.0-or-later，详见 [LICENSE](LICENSE)。基于 [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) 和 [svenshi/oxidns](https://github.com/svenshi/oxidns) 构建，感谢上游作者的贡献。
