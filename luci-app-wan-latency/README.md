# luci-app-wan-latency — OpenWrt WAN 公网延迟监控插件

## v1.3.0

- 新增可选的 HigoOS 原生界面扩展包。
- 在 HigoOS「其他设置」中显示实时公网延迟卡片，每 5 秒自动刷新。
- 通用主包与 HigoOS 集成包完全拆分，不影响其他 OpenWrt 类系统。
- 一键 `.run` 安装器会自动识别 HigoOS；普通系统只安装通用版。
- 完整历史曲线、统计、目标管理和 CSV 导出仍由经过鉴权的 LuCI 页面提供。

### HigoOS 原生面板

![HigoOS 公网延迟原生面板](docs/screenshots/higoos-native-panel.png)

## v1.2.0

- 所有 API 请求通过 LuCI 已认证的 `cgi-io` RPC 桥接，不再暴露匿名 CGI 接口。
- 修复自定义目标名称造成的持久型 XSS 风险，并校验曲线颜色。
- 探测结果标注 ICMP、TCP 443、TCP 80、DNS 或失败，避免混淆不同测量方式。
- 新增抖动、P50、P95、P99 统计和当前区间 CSV 导出。
- `enabled` 与 `retain_days` UCI 配置现在会真正生效。
- 配置写入增加并发锁；探测临时文件改用进程私有目录。
- 新增连续失败、恢复和高延迟的系统日志告警。

默认告警配置：

```uci
option latency_threshold_ms '150'
option loss_alert_consecutive '3'
```

一个适用于 OpenWrt / iStoreOS 的公网延迟监控插件。它持续从 WAN 接口探测多个目标，将数据保存在路由器本地，并在 LuCI「状态 → 公网延迟」中展示实时状态和历史曲线。

## 功能

- 同时监控最多 12 个 IPv4 地址或域名
- ICMP 不可用时依次尝试 HTTPS、HTTP 和 DNS 探测
- 支持 2 秒至 5 分钟的采样间隔
- 支持 15 分钟至 1 年以及自定义时间范围
- 原始数据和 1 分钟汇总数据使用紧凑二进制格式保存
- 默认保留 366 天数据
- 自带阿里云、腾讯云和 Steam 三个预设目标

## 界面预览

### 实时状态与历史总览

![公网延迟监控总览](docs/screenshots/dashboard-overview-v2.png)

### 曲线筛选

![按目标筛选延迟曲线](docs/screenshots/series-filter-v2.png)

## 依赖

- `luci-base`
- `lua`
- `luci-lib-nixio`
- `cgi-io`
- `rpcd-mod-file`
- `curl`
- `ip-full`

## 已测试环境

| 系统 | 版本 | 内核 | 架构 | 状态 |
|---|---|---|---|---|
| iStoreOS | 24.10.8 (2026073111) | 6.6.144 | x86_64 | 通用 LuCI 功能 |
| Hiveton HigoOS H5000M | 1.26.04.29.09 | 6.6.94 | aarch64 | 通用功能及 HigoOS 原生面板 |

其他 OpenWrt / iStoreOS 版本尚未验证，欢迎提交测试结果。

## 编译

将本目录复制到 OpenWrt SDK 或源码树的 `package/luci-app-wan-latency`：

```sh
make menuconfig
# LuCI -> Applications -> luci-app-wan-latency
make package/luci-app-wan-latency/compile V=s
```

生成的 `.ipk` 或 `.apk` 可在对应架构、对应 OpenWrt 版本的设备上安装。

## 安装发行版

请从 [Releases](https://github.com/xiaokeikei/luci-app-wan-latency/releases) 下载文件，并使用同一版本的 `SHA256SUMS` 校验完整性。

### iStoreOS / OpenWrt 24.10（推荐）

将 `.ipk` 上传到路由器后执行：

```sh
opkg install ./luci-app-wan-latency_1.3.0-1_all.ipk
```

HigoOS 可继续安装可选集成扩展：

```sh
opkg install ./luci-app-wan-latency-higoos_1.3.0-1_all.ipk
```

普通 OpenWrt、ImmortalWrt 和 iStoreOS 不需要安装 HigoOS 扩展包。

### 自解压安装器

无法使用软件包管理器安装本地包时，可以使用 `.run`。它不会覆盖已有的 `/etc/config/wan-latency`、目标列表和历史数据：

```sh
chmod +x luci-app-wan-latency-1.3.0-1.run
./luci-app-wan-latency-1.3.0-1.run
```

`.run` 不会自动联网安装依赖；缺少依赖时会列出需要执行的 `opkg install` 命令。它会自动识别 HigoOS，并只在匹配时安装原生界面扩展。

OpenWrt 25.12 及以后使用 `.apk` 的系统尚未完成实机或官方 SDK 验证，因此当前 Release 不提供未经验证的 `.apk`。

## 数据与配置

- UCI 配置：`/etc/config/wan-latency`
- 目标列表：`/etc/wan-latency/targets.conf`
- 当前采样间隔：`/etc/wan-latency/interval`
- 历史数据：`/overlay/wan-latency/data/`
- 临时实时状态：`/tmp/wan-latency-latest.json`

历史数据、实时状态和设备上的自定义目标均未包含在本仓库中。

## 安全设计

浏览器不能直接调用监控后端。LuCI 页面通过带登录会话的 `cgi-io` RPC 桥接执行固定的 `/usr/libexec/wan-latency-api` 程序，rpcd ACL 将权限限定到该程序。直接打开静态页面不会获得数据访问能力。

后端只接受单个、长度不超过 8192 字节的 URL 编码参数，目标地址、目标 ID、采样间隔和查询时间范围均在后端验证。请勿将 LuCI 管理界面直接暴露到公网。

## 来源与许可

本仓库由一台正在运行的 iStoreOS 设备上的自用插件整理而成，以 [GPL-2.0-only](LICENSE) 许可证发布。
