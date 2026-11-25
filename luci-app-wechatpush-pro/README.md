# luci-app-wechatpush-pro

OpenWrt 路由器通知插件：把设备上下线、公网 IP 变化、运行状态、异常流量与安全事件推送到微信、企业微信、Telegram、邮件或自定义 API。

本仓库是 [tty228/luci-app-wechatpush-pro](https://github.com/tty228/luci-app-wechatpush-pro) 的定制分支，包名、仓库名与 LuCI 菜单均已改为 **luci-app-wechatpush-pro**。默认流量来源为 **ctstat**，同时保留 wrtbwmon 与 OAF 两种来源。

## 功能

- 设备上线 / 离线通知，在线设备列表与每客户端累计下载 / 上传流量
- IPv4 / IPv6 地址变化推送
- CPU 负载、温度、内存、磁盘与 PVE 宿主机状态推送
- 定时推送路由状态、在线设备列表、流量排行
- Web / SSH 登录成功与失败提醒，自动拉黑、端口敲门
- 无人值守任务：定时重启、断网重拨、设备别名与免打扰时段

## 支持的通知渠道

| 渠道 | 接口 |
| --- | --- |
| 微信 | Server酱、推送加、WPUSH、WxPusher |
| 企业微信 | 应用消息（支持 text / markdown / mpnews） |
| Telegram | Bot API |
| 邮件 | msmtp |
| 自定义 | 自定义 API JSON 模板 |

## 安装

Release 同时提供两种包格式：

| 文件 | 适用系统 |
| --- | --- |
| `luci-app-wechatpush-pro_1.2-r2_all.ipk` | OpenWrt 19.07 – 24.10（opkg） |
| `luci-app-wechatpush-pro-1.2-r2.apk` | OpenWrt 25.12+（apk） |
| `luci-i18n-wechatpush-pro-zh-cn_1.2-r2_all.ipk` / `.apk` | 简体中文语言包 |
| `luci-i18n-wechatpush-pro-zh-tw_1.2-r2_all.ipk` / `.apk` | 繁體中文語言包 |

```sh
# opkg
opkg update
opkg install luci-app-wechatpush-pro_1.2-r2_all.ipk
opkg install luci-i18n-wechatpush-pro-zh-cn_1.2-r2_all.ipk   # 简体（按需）
opkg install luci-i18n-wechatpush-pro-zh-tw_1.2-r2_all.ipk   # 繁体（按需）

# apk
apk add --allow-untrusted luci-app-wechatpush-pro-1.2-r2.apk
apk add --allow-untrusted luci-i18n-wechatpush-pro-zh-cn-1.2-r2.apk  # 简体（按需）
apk add --allow-untrusted luci-i18n-wechatpush-pro-zh-tw-1.2-r2.apk  # 繁体（按需）
```

基础依赖：`iputils-arping`、`curl`、`jq`、`bash`、`luci-lua-runtime`。
编译期可选依赖：wrtbwmon（仅使用 wrtbwmon 流量源时需要）、lsblk / smartmontools（磁盘信息）、openssh-client / openssh-keygen（宿主机信息）。

安装后在 LuCI 中进入 **服务 → 微信推送-pro**。

### 从 1.1 及更早版本升级（需先卸载旧包）

自 1.2-r1 起，程序内所有命名统一为 `wechatpush-pro`：启动项 `/etc/init.d/wechatpush-pro`、进程名 `wechatpush-pro`、配置 `/etc/config/wechatpush-pro`、目录 `/usr/share/wechatpush-pro/`、运行目录 `/tmp/wechatpush-pro/`。

**包名已改变（`luci-app-wechatpush` → `luci-app-wechatpush-pro`），包管理器不会自动替换，本包不做旧配置迁移，请按全新安装处理：**

```sh
# opkg 系统（OpenWrt 24.10 及更早）
opkg remove luci-app-wechatpush luci-i18n-wechatpush-zh-cn luci-i18n-wechatpush-zh-tw

# apk 系统（OpenWrt 25.12 及更新）
apk del luci-app-wechatpush luci-i18n-wechatpush-zh-cn luci-i18n-wechatpush-zh-tw
```

若还装过更早的 `luci-app-wechatpush-oaf`，一并卸载：

```sh
opkg remove luci-app-wechatpush-oaf luci-i18n-wechatpush-oaf-zh-cn luci-i18n-wechatpush-oaf-zh-tw
```

> **旧配置不会自动带过来**。卸载旧包时 `/etc/config/wechatpush` 属 conffile 会被保留，仅作备份，新包不会读取它；旧的自定义文件（`diy.json`、`logo.jpg`、`ipv4.list`、`ipv6.list`、`device_aliases.list`、`ip_blacklist`、`usage_accum.db`）也不会自动复制。如需延续，请在新版页面里重新填写，或卸载前手工备份 `/usr/share/wechatpush/api/`。
>
> 卸载后 `/etc/config/wechatpush`、`/usr/share/wechatpush/`、`/etc/init.d/wechatpush` 等残留可直接删除；不删也不影响新包运行（新包只使用 `*-pro` 命名，不会与旧文件冲突）。

## 流量数据来源

在 **基本设置 → 流量数据来源** 中选择，页面会按来源显示专属设置项。

### ctstat（默认，推荐）

通过 ubus 调用 `luci.ctstat.get_stats`，读取 ctstat 守护进程按客户端统计的累计下载 / 上传字节数。

- 需要安装并运行 `luci-app-ctstat`。
- 工作在 conntrack / nftables 上，不创建 iptables 规则，可与 firewall4 共存。
- 在线设备页表格按客户端显示“总下载”“总上传”和“总流量”（下载 + 上传）；定时推送的设备列表中“总流量”同样是两者之和。
- 数据为 ctstat 启动以来的累计值；ctstat 重启或执行 reset 后会重新计数。
- ctstat 将无 MAC 的客户端以 IP 作为键，插件同时按 MAC / IP 匹配，避免设备页丢失流量列。

专属设置：**ctstat RPC 超时（秒）**（默认 5，范围 1–30）。路由器较慢时可增大；调用失败时保留上一份成功快照，不会把流量清零。

### wrtbwmon（原版行为）

使用 wrtbwmon 生成的 `usage.db`。该方式通过 iptables 建链计数，可能与 Routing/NAT、Flow Offloading、代理插件冲突，并在 firewall4 上产生旧版 iptables 规则警告。

专属设置：**wrtbwmon 兼容模式**。

- 自动：按软件包版本选择命令格式
- 新版：`wrtbwmon -f`（1.2.0+）
- 旧版：`wrtbwmon update`（1.0.x）

### OAF / OpenAppFilter

通过 `ubus call fwx common` 读取每客户端流量，不创建 iptables 规则。需要已安装并启用 `open-app-filter` / `luci-app-oaf` 且开启其流量统计。

专属设置：

- **OAF ubus 接口**：自动 / `get_user_stat`（全部设备）/ `get_daily_top_users`（仅流量最高的 8 台）。
- **跨天累计总流量**：OAF 每天零点归零，插件维护本地基线，把上一日流量并入累计值；开启时建议关闭“每天零点重置流量数据”。
- 若开启软件 / 硬件流量卸载，OAF 的 netfilter 钩子可能被绕过，设备流量会明显偏少；此时建议改用 ctstat。

## 使用提示

- 设备主机名获取失败时，可在“设备别名”中按 MAC 或 IP 指定名称，也可安装 Samba 客户端以使用 NetBIOS 查询。
- 默认用 ping / arping 主动探测设备在线状态；Wi-Fi 休眠设备可在高级设置中调整超时或关闭主动探测。
- 自动封禁默认只拦截访问路由器的流量；打开“阻止黑名单 IP 的转发流量”后可拦截经过路由器的流量。fw4 下按最近记录的剩余时长恢复封禁。
- 停止插件服务不会立即撤销已生效的防火墙规则，规则会在防火墙重载或重启后消失；插件运行时会在下一次检测循环恢复。

## 排查问题

提交问题时请附上：

- 设备型号、OpenWrt 版本、插件版本与所选流量来源
- `/usr/share/wechatpush-pro/wechatpush-pro` 的直接输出
- `/tmp/wechatpush-pro/wechatpush-pro.log` 与 `/tmp/wechatpush-pro/usage.db`
- `bash -x /usr/share/wechatpush-pro/wechatpush-pro t1` 的详细日志

常见检查：

```sh
ubus list | grep -E 'luci\.ctstat|fwx'
ubus call luci.ctstat get_stats '{}' | jq '.devices | length'
cat /tmp/wechatpush-pro/usage.db
/etc/init.d/wechatpush-pro restart
```

## 许可

GPL-2.0-or-later。上游项目由 tty228 维护，本分支仅做功能定制与打包维护。
