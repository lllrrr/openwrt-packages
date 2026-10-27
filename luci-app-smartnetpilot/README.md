# 智能网络向导（luci-app-smartnetpilot）

简体中文 | [English](README.en.md)

一个面向 OpenWrt / LuCI 的「傻瓜式」网络设置向导。选一种上网方式，按页面提示填写必要信息，点一下「保存并应用」即可完成 WAN、LAN、IPv6、DNS、无线和 HTTPS 的配置——全程不需要输入 Linux 命令。

插件位于 **网络 → 智能网络向导**（`admin/network/smartnetpilot`）。首页是三张模式卡片：

| 模式 | 适用场景 |
| --- | --- |
| 宽带拨号（PPPoE） | 运营商提供了宽带账号和密码，线路需要 PPPoE 认证 |
| 现有路由器（DHCP） | 新路由器接在光猫或已有网关后面，WAN 自动获取地址（也可以固定 IP） |
| 旁路由（Side Router） | 保留现有主路由器，把本设备当作旁路由或附加服务 |

![智能网络向导首页（Argon 主题）](screenshot.png)

## 安装

### 从 Releases 安装

1. 打开 [Releases](https://github.com/Arthur97172/luci-app-smartnetpilot/releases) 页面，下载安装包。
2. 把安装包上传到设备（例如 `/tmp`），然后安装：

   **OpenWrt 24.10 及更早（opkg）**

   ```sh
   opkg install /tmp/luci-app-smartnetpilot_*.ipk

   #可选，安装简体中文语言包：

   opkg install /tmp/luci-i18n-smartnetpilot-zh-cn_*.ipk
   ```

   **OpenWrt 25.12+（apk）**

   ```sh
   apk add --allow-untrusted /tmp/luci-app-smartnetpilot-*.apk

   #可选，安装简体中文语言包：

   apk add --allow-untrusted /tmp/luci-i18n-smartnetpilot-zh-cn-*.apk
   ```

3. 刷新 LuCI，入口出现在「网络 → 智能网络向导」。

> 未安装语言包时界面显示英文。安装包架构为 `all`，ARM / x86 / MIPS 等平台通用。

### 从源码编译

```sh
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a
git clone https://github.com/Arthur97172/luci-app-smartnetpilot.git package/luci-app-smartnetpilot
make menuconfig     # LuCI → Applications → luci-app-smartnetpilot
make package/luci-app-smartnetpilot/compile V=s
```

编译产物位于 `bin/packages/<架构>/base/` 目录下。

## 使用方法

1. 打开「网络 → 智能网络向导」，在首页三张卡片里选择接入方式。当前正在使用的模式会标注「当前」。
2. 在「WAN 设置」里按所选模式填写内容：
   - **宽带拨号**：宽带账号、密码；可指定 WAN 物理端口，也可以自定义 DNS。
   - **现有路由器**：WAN 用 DHCP 自动获取，或选择「静态 IPv4 地址」后填写地址、掩码、网关和 DNS。
   - **旁路由**：设置本机 LAN 地址（静态或由上级分配），并填写主路由器地址作为网关；「局域网 DNS 服务器」会下发给局域网客户端。
3. 需要改 Wi-Fi 时填写「无线设置」里的名称（SSID）和密码（WPA2-PSK，至少 8 位）。留空则不改动现有无线配置。
4. 点开右上角的「高级设置」，可以开启 IPv6、关闭 LAN 的 DHCP 服务器、向客户端通告指定 DNS、把管理页面重定向到 HTTPS；「其他设置」分区里还有 SYN Flood 防护。
5. 点击页面底部的「保存并应用」。只想暂存修改时，可以先点「保存」。点右上角的「更改模式」会直接清除页面上尚未保存的修改并回到首页，不会保存这些内容。
6. 如果改动会影响你访问设备的方式（管理地址变化、LAN 变成 DHCP 客户端、HTTPS 开关切换、无线名称或密码变化），页面会先弹出确认框，逐条列出将会发生什么。确认后配置开始应用；管理地址变化时当前页面会断开，并自动打开新地址。
7. 应用后设备进入 120 秒确认期：页面显示倒计时和新的管理地址。用新地址重新打开向导页，点「保留配置」即可；如果连不上新地址，倒计时结束（或点「立即回滚」）后会自动恢复应用前的配置。需要直接生效时，可以在确认框里选择「不确认，直接应用」，此时不再自动回滚。

> 旁路由模式下，如果主路由器已经在提供 DHCP，记得展开「高级设置」并打开「关闭 LAN DHCP 服务器」，同一网络中只应有一个 DHCP 服务器。

## 工作原理

前端只把易读的 UCI 选项写入 `/etc/config/smartnetpilot`，例如
`smartnetpilot.default.wan_proto=pppoe`、`smartnetpilot.default.lan_ipaddr=192.168.2.1`，浏览器本身不执行任何命令。

`/etc/init.d/smartnetpilot` 读取这些选项，翻译成系统真正使用的配置。它**只**在你点击「保存并应用」时执行一次：

- 前端在提交前调用 RPC `arm_apply` 创建一次性请求标记 `/tmp/smartnetpilot.apply`，随后才提交配置并触发应用。
- 启用回滚时，`arm_apply` 先调用 `prepare_apply`，把当前配置快照到 `/tmp/smartnetpilot-rollback/backup`，并把随机 token 同时写入状态目录和标记。
- ucitrack 的 `reload` 只有发现这个标记时才会真正写入配置；标记被读取后立即删除，并且超过 300 秒的残留标记会被忽略。
- 因此安装、升级（包管理器会调用 `start`）、开机（`boot`）以及任何其他原因导致的配置提交都不会改动网络。

应用后的确认期（两阶段提交）：

- `reload` 写入配置并重启网络后，把状态标记为 `pending`，记录截止时间，并启动一个脱离页面的定时器（`wait_rollback`）。
- 向导页通过 RPC `apply_status` 轮询剩余时间；点「保留配置」会调用 `confirm_apply`，取消定时器并保留新配置。
- 倒计时结束仍未确认，或用户点「立即回滚」时，定时器调用 `rollback_if_pending`，用快照覆盖当前配置、提交 UCI 并重新加载服务，然后把结果记为 `rolledback`。
- 快照保存在 `/tmp`，重启、重新安装或升级后自动失效；`boot()` 和 uci-defaults 会清空这些状态。
- 已有待确认的应用时拒绝新的应用请求；带 token 的应用如果找不到匹配的快照也会被拒绝，避免留下无法自动恢复的配置。

真正写入前的校验：

- **模式**：`wan_proto` 为空或不是 `pppoe` / `dhcp` / `siderouter` 时直接拒绝应用（全新安装的默认配置就是这种状态）。
- **必填项**：PPPoE 缺账号或密码、静态 WAN / 静态 LAN 的地址或掩码非法时拒绝应用。
- **WAN 口**：优先使用你指定的端口，其次沿用现有 `network.wan` 的 `device`/`ifname`，再次尝试 DSA 的 `wan` 端口；都不可用时拒绝应用，绝不猜测端口，也不会改写 `br-lan` 的桥接端口列表。候选端口会对照 `/etc/board.json` 的 `network` 段校验，交换机 CPU 通道（例如 DSA 设备的 `eth0`）会被跳过并回退到 `wan`；`eth0.1` 这类 VLAN 子接口以及 `usb*`、`wwan*` 不受影响，读不到 `board.json` 时不做这项判断。

写入内容：

- **network**：按模式重建 `wan` / `wan6`（PPPoE、DHCP 或静态地址）；旁路由模式只改写 LAN。
- **firewall**：重建 WAN 区域和 lan→wan 转发，写入 SYN Flood 开关；检测到 `dockerd` 时补上 Docker 区域与相关转发。
- **dhcp**：按需关闭 LAN 的 DHCP 服务器，或通过 `dhcp_option 6` 向客户端下发指定 DNS。
- **wireless**：把 SSID / 密码写入所有 AP 接口和默认 radio，加密方式为 WPA2-PSK。
- **uhttpd 或 nginx**：HTTPS 开关与 HTTP→HTTPS 重定向；没有 nginx 时用 uhttpd，并生成 10 年有效期的本地自签证书。
- 提交前把 `network`、`firewall`、`dhcp`、`wireless`、`system`、`uhttpd`、`nginx` 备份到 `/tmp/smartnetpilot_backup_<时间戳>`，提交失败会自动恢复。
- 提交成功后，在后台重启 network，并按需 reload WiFi、system、rpcd、uhttpd、dnsmasq 和 firewall。

写入 IPv4 之前会校验格式（4 段、每段 0–255），非法值只记录日志并跳过。

开机时 `boot()` 钩子直接返回，不会重新套用向导设置，避免重启后覆盖你后来手动做的调整。安装或升级软件包时，包管理器同样会调用 `start()`，该钩子也是空操作，所以安装本插件本身不会改变任何网络配置。

前端通过 RPC `luci.smartnetpilot get_ip` 读取当前 LAN 地址，只用于在页面上显示和管理地址变化提示。

## 主题与兼容性

- 支持 LuCI 亮色 / 暗色主题，无需手动切换。
- 已适配 `luci-theme-bootstrap`（OpenWrt 24.10 / 25.12 默认主题）与 `luci-theme-argon` 2.x / 3.x。
- 明暗判断依次尝试：主题显式标记（`data-theme`、`dark` 类名）→ 页面背景亮度 → `prefers-color-scheme`，并监听主题切换与系统设置变化。
- 样式表放在插件自己的作用域内，只改变本页外观，不影响其他 LuCI 页面。

## 安全说明

- 安装、升级、开机都不会应用配置；只有向导页面的「保存并应用」会，且需要一次性请求标记。
- 未选择接入方式或必填项不完整时拒绝应用，不会把默认配置翻译成错误的网络设置。
- 无法确定可用 WAN 口时拒绝应用，不会猜测端口或覆盖 LAN 桥接。
- 用 `/etc/board.json` 区分物理端口和交换机 CPU 通道：把 `eth0` 这类 CPU 口选作 WAN 时，前端在保存前提示，服务端也会跳过它并回退到 `wan`；设备上没有 `board.json` 时保持原有行为。
- 每次应用前自动备份相关配置，提交失败立即恢复。
- 应用成功后有 120 秒确认期；未确认就自动恢复应用前的快照（`network`、`firewall`、`dhcp`、`wireless`、`system`、`uhttpd`、`nginx`、`smartnetpilot`），避免新地址不可达后设备失联。
- 「不确认，直接应用」会跳过倒计时和自动回滚，配置立即生效；如果新地址有误，设备可能无法再访问，需要通过串口、SSH、TTL 或恢复模式处理。
- IPv4 地址先校验再写入，非法值不会被写进 UCI。
- 会影响访问方式的修改（管理地址、LAN DHCP 角色、HTTPS、无线密码）先确认再应用。
- 管理地址变化或 LAN 变成 DHCP 客户端时直接提交到 `admin/uci/apply_unchecked`，绕开 LuCI 自带的应用后刷新；确认和回滚由本插件自己的 120 秒定时器负责，浏览器断开不会误触发回滚。
- HTTPS 使用本机生成的自签证书，浏览器首次访问会提示不受信任，属正常现象；设备已安装 nginx 时优先通过 nginx 完成跳转。
- 应用过程有锁文件保护（`/var/lock/smartnetpilot-boot.lock`），300 秒后视为残留并自动清理，避免两个应用流程同时改网络配置。
- 除管理系统本身外，向导不额外开放任何端口或服务。

## 文件结构

```
.
├── Makefile
├── htdocs/luci-static/resources/view/smartnetpilot/
│   ├── smartnetpilot.js
│   └── smartnetpilot.css
├── po/templates/smartnetpilot.pot
├── po/zh_Hans/smartnetpilot.po
└── root/
    ├── etc/config/smartnetpilot
    ├── etc/init.d/smartnetpilot
    ├── etc/uci-defaults/40-luci-smartnetpilot
    ├── usr/libexec/rpcd/luci.smartnetpilot
    └── usr/share/
        ├── luci/menu.d/luci-app-smartnetpilot.json
        ├── rpcd/acl.d/luci-app-smartnetpilot.json
        └── ucitrack/luci-app-smartnetpilot.json
```

## 依赖

- OpenWrt 24.10 或更新版本，带 LuCI（JavaScript 视图，`luci-base`）
- `uhttpd`（默认）或 `nginx`：HTTPS 管理在两者之一上生效
- `openssl`：开启 HTTPS 时生成本地证书
- `dnsmasq` 与系统防火墙（`firewall4` / `firewall3`）：随 OpenWrt 自带
- 无线设置需要设备存在 `/etc/config/wireless` 与 `wifi` 命令；无无线的设备会自动隐藏「无线设置」分区按钮

## 许可证

GPL-3.0-only
