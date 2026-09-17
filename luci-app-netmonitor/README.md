# luci-app-netmonitor（网络质量监控）

[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.2.0-informational.svg)](CHANGELOG.md)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%2025.x-00A0D0.svg)](https://openwrt.org)
[![LuCI](https://img.shields.io/badge/LuCI-JS%20view%20%2B%20ucode%20RPC-FF6B35.svg)](https://github.com/openwrt/luci)
[![Package arch](https://img.shields.io/badge/arch-all%20%28PKGARCH%3Dall%29-lightgrey.svg)](#52-安装到设备)
[![Build](https://github.com/LianXia233/luci-app-netmonitor/actions/workflows/build.yml/badge.svg)](https://github.com/LianXia233/luci-app-netmonitor/actions/workflows/build.yml)
[![Tests](https://img.shields.io/badge/tests-536%20assertions%20passing-2e9e5b.svg)](#十一测试清单)
[![i18n](https://img.shields.io/badge/i18n-zh__Hans%20%2B%20en%2C%200%20untranslated-2e9e5b.svg)](#十一测试清单)
[![Last commit](https://img.shields.io/github/last-commit/LianXia233/luci-app-netmonitor/main.svg)](https://github.com/LianXia233/luci-app-netmonitor/commits/main)
[![Code size](https://img.shields.io/github/languages/code-size/LianXia233/luci-app-netmonitor.svg)](https://github.com/LianXia233/luci-app-netmonitor)

面向 **OpenWrt 主线（upstream / mainline）** 的网络延迟与网络联通性监控插件。
后台由 `procd` 托管一个常驻探测守护进程，LuCI 页面只负责读取状态与曲线，
**关闭浏览器页面后监控依然持续运行**。

菜单位置：**状态 → 网络质量监控（Network Monitor）**

---

## 目录

- [一、设计原则](#一设计原则)
- [二、主要特性](#二主要特性)
- [三、架构](#三架构)
- [四、目录结构](#四目录结构)
- [五、编译与安装](#五编译与安装)
- [六、UCI 配置说明](#六uci-配置说明etcconfignetmonitor)
- [七、RPC 接口](#七rpc-接口ubus-对象-lucinetmonitor)
- [八、数据存储与 Flash 保护](#八数据存储与-flash-保护)
- [九、卸载](#九卸载)
- [十、调试方法](#十调试方法)
- [十一、测试清单](#十一测试清单)
- [十二、开发约定与踩坑记录](#十二开发约定与踩坑记录)
- [十三、兼容性](#十三兼容性)
- [十四、动态 SVG 图标与动画系统](#十四动态-svg-图标与动画系统)
- [十五、已知限制](#十五已知限制)
- [十六、版本与更新日志](#十六版本与更新日志)
- [十七、许可证](#十七许可证)

> 版本变更记录不在本文件维护，统一见 [`CHANGELOG.md`](CHANGELOG.md)。

---

## 一、设计原则

| 原则 | 落地方式 |
| --- | --- |
| 主线兼容优先 | 只使用 LuCI / UCI / ubus / ucode / procd / rpcd / shell / HTML5 / CSS3 / 原生 JS / SVG，不依赖厂商固件 API、不绑定主题、不引入前端框架 |
| 后台独立运行 | 探测由 procd 单实例守护进程完成，浏览器只读取；开多个标签页不会创建多套 Ping 任务 |
| 低资源占用 | 高频数据全部落在 `/tmp`（tmpfs），默认不写 Flash；统计采用「分段 + 直方图」增量维护，CPU 与历史长度无关 |
| 数据可靠 | 失败与成功严格区分，区分超时 / DNS 失败 / 网络不可达 / 其它错误；失败时延迟为 `null`，绝不用 `0 ms` 冒充 |
| 响应式 | PC 多列卡片、平板自动减列、手机单列；表格横向滚动，不出现页面溢出 |

---

## 二、主要特性

- 默认 10 秒一轮探测，支持 1/5/10/15/30/60/120/300 秒及任意 1–3600 秒自定义值
- 多目标并发探测，并发上限可配（默认 5）
- 每目标可单独设置：名称、地址、区域、自定义标签、探测方式、TCP 端口、地址族、检测间隔、超时、出口接口、源地址、启用状态、备注
- 两种探测方式，**逐个目标可选**：ICMP echo（默认）与 TCP 连接握手；TCP 端口可逐目标指定，也可只设一个全局默认端口。被 ICMP 屏蔽或限速的网络里，TCP 方式依然能测出真实握手耗时
- 区域分类：国内 / 国外 / 其他，外加自由自定义标签（香港、日本、DNS、游戏……），**不内置任何 IP 归属库**
- 实时统计：当前 / 最低 / 最高 / 平均 / P50 / P95 / P99 延迟、丢包率、成功率、连续成功与连续失败次数、最后检测时间、最近成功时间
- 质量等级：优秀 / 良好 / 一般 / 较差 / 严重 / 离线，**阈值全部可在页面配置**，不硬编码在前端
- 历史数据：内存环形缓存（默认 4320 点/目标）+ 可选 Flash 持久化（1h / 6h / 12h / 24h / 3d / 7d / 30d）
- 7 个页面：总览、实时监控、延迟曲线、国内/国外、历史数据、目标管理、设置
- 自研 SVG 折线图 / 面积图 / 丢包标记 / Tooltip（鼠标悬停与手机触摸均可查看）
- 24 个内联动态 SVG 图标，全部与真实数据绑定（延迟表盘、成功率 / 丢包率环形进度、
  延迟等级仪表、时钟指针、实时柱状、按失败类型切换的诊断图标），详见第十四章
- 中文（zh_Hans）/ 英文双语，通过 LuCI 标准 i18n 机制
- 通知接口预留（Webhook / Telegram / 企业微信 / 钉钉 / 邮件）

---

## 三、架构

```
LuCI Web UI (HTML5 + CSS3 + 原生 JS + SVG)
        │  ubus / rpcd 权限受控
        ▼
/usr/share/rpcd/ucode/luci.netmonitor        ← 读状态、改配置、控服务
        │  读取 /tmp 与 /etc 下的数据文件
        ▼
/etc/init.d/netmonitor (procd)               ← 启停、respawn、配置变更自动 reload
        │
        ▼
/usr/libexec/netmonitor/netmon-daemon.sh     ← 单实例探测守护进程
        │  ICMP: ping / ping6    TCP: curl 连接握手（并发受控）
        ▼
/tmp/netmonitor/{ring,hist,state}            ← tmpfs 高频数据（分段 + 直方图）
/etc/netmonitor/history/*.agg                ← 可选 Flash 持久化（按间隔批量落盘）
```

**关键点：检测频率与 UI 刷新频率完全解耦。** 后台默认 10 秒探测一次，
前端默认 2 秒拉取一次最新状态，页面刷新不会触发任何 Ping。

---

## 四、目录结构

```
luci-app-netmonitor/
├── Makefile                                   # 包定义（依赖全为主线组件）
├── LICENSE
├── CHANGELOG.md                               # 版本变更记录
├── README.md
├── po/
│   ├── gen_po.py                              # 翻译提取/生成脚本（开发用，不打包）
│   ├── core_msgids.txt                        # 与核心语言包同名的 msgid 及核心译文（见 12.21）
│   ├── templates/luci-app-netmonitor.pot
│   └── zh_Hans/luci-app-netmonitor.po
├── .github/workflows/build.yml                # CI：静态检查 + 单元测试 + SDK 构建
├── root/
│   ├── etc/
│   │   ├── init.d/netmonitor                  # procd 服务脚本
│   │   └── uci-defaults/luci-app-netmonitor   # 首次安装写入默认配置
│   └── usr/
│       ├── libexec/netmonitor/
│       │   └── netmon-daemon.sh               # 后台检测守护进程
│       └── share/
│           ├── luci/menu.d/luci-app-netmonitor.json      # 菜单（状态 → 网络质量监控）
│           └── rpcd/
│               ├── acl.d/luci-app-netmonitor.json        # RPC 权限
│               └── ucode/luci.netmonitor                 # RPC 后端
├── tests/
│   ├── test_netmon_daemon.sh                  # 守护进程单元测试（94 条断言）
│   └── test_icons.js                          # 动态 SVG 图标自检（442 条断言）
└── htdocs/luci-static/resources/
    ├── netmonitor/
    │   ├── style.css                          # 全部样式限定在 .nm- 命名空间
    │   ├── common.js                          # RPC 封装、格式化、等级、卡片
    │   ├── icons.js                           # 24 个内联动态 SVG 图标
    │   └── chart.js                           # 自研 SVG 图表
    └── view/netmonitor/
        ├── overview.js  realtime.js  charts.js
        ├── regions.js   history.js   targets.js  settings.js
```

> 不含任何 LuCI 旧版 `luasrc/` 目录：现代主线 LuCI 使用 JS 视图 + ucode RPC，
> 本项目按当前主线结构组织。

---

## 五、编译与安装

### 5.1 放入源码树编译

```bash
cd openwrt
cp -r luci-app-netmonitor package/luci-app-netmonitor
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig            # LuCI → Applications → luci-app-netmonitor
make package/luci-app-netmonitor/compile V=s
```

产物：`bin/packages/*/luci/luci-app-netmonitor_1.2.0-r1_all.ipk`
（版本号取自 `Makefile` 的 `PKG_VERSION` / `PKG_RELEASE`；源码树放在 feeds 里构建时，
产物名中的版本可能带 LuCI 的日期后缀，以实际输出为准）

### 5.2 安装到设备

本包 `PKGARCH=all`，架构无关，同一份产物可安装到任意架构设备。

**opkg（OpenWrt 23.05 / 24.10）**

```bash
opkg update
opkg install luci-app-netmonitor luci-i18n-netmonitor-zh-cn
```

**apk（OpenWrt 25.x 及更新版本）**

```bash
apk update
apk add luci-app-netmonitor luci-i18n-netmonitor-zh-cn
```

**离线安装**（从构建机拷贝产物）

```bash
scp luci-app-netmonitor_*.ipk luci-i18n-netmonitor-zh-cn_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install /tmp/luci-app-netmonitor_*.ipk /tmp/luci-i18n-netmonitor-zh-cn_*.ipk"
```

**签名校验失败**（自编译包未签名，opkg 报 `Signature check failed`）：

```bash
opkg install --force-downgrade --force-depends luci-app-netmonitor_*.ipk
# 必要时加 --force-overwrite 覆盖同名文件
```

apk 侧对应参数：

```bash
apk add --allow-untrusted luci-app-netmonitor_*.apk
```

> `--force-downgrade` 用于版本号低于设备已装版本时（重复安装调试版本很常见）。

**安装后必须重载 rpcd 与 uhttpd**，否则 RPC 后端不生效、菜单不出现：

```bash
rm -f /tmp/luci-indexcache*          # 清 LuCI 菜单索引缓存
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

/etc/init.d/netmonitor enable        # 开机自启
/etc/init.d/netmonitor start
/etc/init.d/netmonitor status
```

浏览器进入 **状态 → 网络质量监控**（本插件挂载在一级菜单「状态」下，不是「网络」）。

### 5.3 实机验证步骤（逐条确认）

```bash
# 1) 后台守护进程存活
/etc/init.d/netmonitor status
pgrep -f netmon-daemon

# 2) ubus 对象已注册（未注册说明 rpcd 没重载或 ucode 文件有语法错误）
ubus list | grep netmonitor          # 期望: luci.netmonitor

# 3) 探测链路正常（tick 应随时间递增）
ubus call luci.netmonitor service_status
sleep 12; ubus call luci.netmonitor service_status

# 4) 目标状态：失败时 latency 必须为 null，不能是 0
ubus call luci.netmonitor get_status

# 5) 统计与曲线
ubus call luci.netmonitor get_statistics '{"range":"1h"}'
ubus call luci.netmonitor get_history  '{"range":"1h"}'

# 6) 运行期文件（均在 /tmp，不写 Flash）
ls -la /tmp/netmonitor/{state,ring,hist}/
```

**依赖缺失排查**（ubus 对象不出现、页面报错时）：

```bash
# 逐个确认依赖已安装
for p in luci-base luci-mod-status rpcd rpcd-mod-ucode ucode \
         ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-uloop; do
    opkg status "$p" >/dev/null 2>&1 && echo "ok   $p" || echo "MISS $p"
done

# 确认 ucode 插件被 rpcd 加载（语法错误会在此暴露）
ucode -c /usr/share/rpcd/ucode/luci.netmonitor && echo "ucode syntax OK"
/etc/init.d/rpcd restart; sleep 2; ubus list | grep netmonitor
```

**日志查看**

```bash
logread | grep netmonitor            # 服务启停、配置重载、目标状态翻转
logread | grep -i rpcd               # RPC 后端加载失败原因
/etc/init.d/netmonitor stop
/usr/libexec/netmonitor/netmon-daemon.sh   # 前台运行，直接看探测输出（排障首选）
```

> 正常探测不写日志，只有状态翻转（恢复 / 失败）与异常才记录，避免刷屏。

**卸载后复核**

```bash
opkg remove luci-app-netmonitor luci-i18n-netmonitor-zh-cn
/etc/init.d/rpcd restart
ubus list | grep netmonitor          # 应无输出
```

### 5.4 依赖

本包直接声明的依赖（`Makefile` 中的 `LUCI_DEPENDS`）：

```
luci-base  luci-mod-status
ucode-mod-fs  ucode-mod-uci  ucode-mod-ubus  ucode-mod-uloop
```

运行时实际需要、但由 `luci-base` 传递提供的组件：

```
rpcd  rpcd-mod-file  rpcd-mod-luci  rpcd-mod-ucode  cgi-io  ucode
```

全部为 OpenWrt 主线自带组件，无需额外软件源。

`rpcd` / `rpcd-mod-ucode` / `ucode` 三项**不在本包显式声明**，这是刻意的：`luci-base` 的 `LUCI_DEPENDS` 已完整包含它们，重复声明会在 SDK 构建环境下触发 Kconfig 递归依赖，详见 12.9。

---

## 六、UCI 配置说明（`/etc/config/netmonitor`）

### 6.1 global 段

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `1` | 监控总开关 |
| `interval` | `10` | 全局检测间隔（秒），范围 1–3600，推荐 1/5/10/15/30/60/120/300 |
| `timeout` | `3` | Ping 超时（秒），1–30 |
| `count` | `1` | 每次检测的发包数，1–20 |
| `concurrency` | `5` | 并发检测目标数上限，1–50 |
| `address_family` | `auto` | 全局默认地址族：`auto` / `ipv4` / `ipv6`。目标级 `family` 可覆盖，**且目标级多一个 `both`**（IPv4 + IPv6 双栈，见 6.2） |
| `default_proto` | `icmp` | 默认探测方式：`icmp`（ICMP echo）/ `tcp`（TCP 连接握手） |
| `default_tcp_port` | `80` | TCP 探测的默认端口（1–65535），供未单独指定 `tcp_port` 的目标使用 |
| `interface` | 空 | 出口接口（如 `wan`、`wwan`），空则走系统默认路由 |
| `source` | 空 | 源地址 |
| `persistence` | `0` | 是否开启 Flash 持久化历史 |
| `history` | `24h` | 持久化保留时间：1h/6h/12h/24h/3d/7d/30d |
| `persist_interval` | `300` | 落盘间隔（秒），60–3600 |
| `max_points` | `4320` | 每目标内存环形缓存点数（10s × 4320 ≈ 12 小时） |
| `ui_refresh` | `2` | 前端刷新间隔（秒），1–60 |
| `log_level` | `info` | `debug` / `info` / `warning` / `error` |
| `fail_warn` / `fail_critical` | `3` / `5` | 连续失败告警 / 严重阈值 |
| `loss_warn` / `loss_critical` | `5` / `20` | 丢包率告警 / 严重阈值（%） |
| `latency_excellent` | `50` | 优秀阈值（ms） |
| `latency_good` | `100` | 良好阈值（ms） |
| `latency_fair` | `200` | 一般阈值（ms） |
| `latency_poor` | `500` | 较差阈值（ms） |
| `notify_enabled` / `notify_url` | `0` / 空 | 通知接口预留 |

### 6.2 target 段（可多个）

```
config target 'baidu'
	option name     'Baidu'
	option host     'www.baidu.com'
	option region   'cn'          # cn | overseas | other
	option label    ''            # 自定义标签，如 香港 / 日本 / DNS / 游戏
	option proto    'icmp'        # icmp | tcp
	option tcp_port '0'           # TCP 端口；0 = 跟随全局 default_tcp_port
	option family   'auto'        # auto | ipv4 | ipv6 | both（both 仅目标级可用）
	option interval '0'           # 0 = 跟随全局
	option timeout  '3'           # 0 = 跟随全局
	option interface ''
	option source   ''
	option enabled  '1'
	option remark   ''
```

默认配置提供 4 个示例目标（百度、阿里 DNS、Cloudflare、Google DNS），
其中百度默认启用、另外 3 个默认禁用，**可任意修改或删除**。

> 表格、弹窗与设置页的可选项集合都以源码为准：全局 `address_family` 三选一
> （`auto`/`ipv4`/`ipv6`），目标级 `family` 四选一（多一个 `both`）。
> 后端 `FAMILIES` 常量虽然同时接受四个值，但全局设置页不下发 `both`。

#### 6.2.1 ICMP 与 TCP 两种探测方式

`proto` 逐个目标可选；目标未写 `proto` 时继承全局 `default_proto`；
`tcp_port` 为 `0`（或未写）时继承全局 `default_tcp_port`。

| `proto` | 实际动作 | 延迟口径 | 适用场景 |
| --- | --- | --- | --- |
| `icmp`（默认） | `ping` / `ping6` 发 ICMP echo | ICMP 往返时间（RTT） | 通用，最贴近传统 ping |
| `tcp` | 向 `tcp_port` 发起 TCP 三次握手 | 握手耗时（curl `%{time_connect}`） | 被 ICMP 屏蔽 / 限速的网络，只需确认端口可达 |

注意：

- TCP 模式下一次连接计为一个「包」（`sent=1`），因此**丢包率等于失败采样占比**；
  `count` 不适用（握手只做一次）。
- `interval` / `timeout` / 并发上限 / 地址族照常生效；`interface` 与 `source`
  在 curl 路径下通过 `--interface` 绑定。
- 延迟口径不同，**跨方式的历史曲线不要直接对比**：ICMP 常被中间设备优先处理，
  TCP 还包含建连排队时间。
- 失败分类同样明确：curl 退出码 6 → DNS 失败，28 → 超时，7 → 按出错信息区分
  超时 / 不可达，其余归入「其它错误」；失败时延迟仍为 `null`，绝不写成 `0 ms`。

命令行示例：

```bash
uci set netmonitor.myhost=target
uci set netmonitor.myhost.name='MyHost'
uci set netmonitor.myhost.host='example.com'
uci set netmonitor.myhost.region='overseas'
uci set netmonitor.myhost.proto='tcp'        # 可选：改用 TCP 握手探测
uci set netmonitor.myhost.tcp_port='443'     # 可选：0 = 跟随全局 default_tcp_port
uci set netmonitor.myhost.enabled='1'
uci commit netmonitor
/etc/init.d/netmonitor reload
```

---

## 七、RPC 接口（ubus 对象 `luci.netmonitor`）

权限由 `/usr/share/rpcd/acl.d/luci-app-netmonitor.json` 控制，
未授权用户无法调用写操作。

| 方法 | 权限 | 说明 |
| --- | --- | --- |
| `get_status` | read | 全局与每目标实时状态、区域聚合、阈值、迷你曲线 |
| `get_targets` | read | 目标配置列表 |
| `get_history` | read | 指定范围/目标/区域的历史点（自动降采样） |
| `get_statistics` | read | 指定范围的聚合统计（平均/最大/最小/P50/P95/丢包/成功率） |
| `get_config` | read | 全局配置 |
| `set_config` | write | 修改全局配置（白名单 + 范围校验，含 `default_proto` / `default_tcp_port`） |
| `add_target` / `update_target` / `delete_target` | write | 目标增删改（含 `proto` / `tcp_port`） |
| `move_target` / `copy_target` / `batch_targets` | write | 排序 / 复制 / 批量启停 |
| `clear_history` | write | 清空内存与持久化历史 |
| `service_status` | read | 服务运行状态与心跳 |
| `start_service` / `stop_service` / `restart_service` | write | 服务控制 |

调试调用：

```bash
ubus call luci.netmonitor get_status '{}'
ubus call luci.netmonitor get_history '{"range":"1h","max_points":300}'
ubus list luci.netmonitor
```

返回结构中的延迟字段：成功为数值（ms），失败为 `null`。

---

## 八、数据存储与 Flash 保护

| 数据 | 位置 | 写入频率 |
| --- | --- | --- |
| 原始采样点 | `/tmp/netmonitor/ring/<id>.tsv` | 每次探测追加 1 行（tmpfs，不损耗 Flash） |
| 统计段 + 直方图 | `/tmp/netmonitor/hist/<id>.{cur,seg}` | 每次探测更新 1 行 |
| 目标运行状态 | `/tmp/netmonitor/state/<id>` | 每次探测重写（极小） |
| 持久化聚合桶 | `/etc/netmonitor/history/<id>.agg` | 仅在开启持久化时，每 `persist_interval` 秒写 1 行 |

要点：

1. **默认不写 Flash**（`persistence=0`）。
2. 持久化写入的是**聚合桶**（一段窗口的 avg/min/max/loss），不是原始点，
   30 天 @5 分钟粒度也只有约 8640 行/目标。
3. 落盘时按保留时间裁剪，文件不会无限增长。
4. 统计采用 60 点一段 + 17 桶直方图：每轮只做 O(1) 增量更新，
   P50/P95/P99 由直方图插值估算，**不会每轮全量重算历史**。
5. 内存采样点数由 `max_points` 限制，超出自动裁掉最老数据。

---

## 九、卸载

```bash
/etc/init.d/netmonitor stop
/etc/init.d/netmonitor disable
opkg remove luci-app-netmonitor
rm -rf /tmp/netmonitor          # 运行期数据（可省略，重启即失）
rm -rf /etc/netmonitor          # 持久化历史（确认不再需要时执行）
```

配置文件 `/etc/config/netmonitor` 由 opkg 保留（如需彻底清除请手动删除）。
由于默认配置通过 `uci-defaults` 注入，卸载后重装不会覆盖已有配置。

---

## 十、调试方法

### 10.1 查看日志

```bash
logread | grep netmonitor
# 打开 debug
uci set netmonitor.global.log_level='debug'; uci commit netmonitor
/etc/init.d/netmonitor reload
```

正常探测**不写日志**；只在状态翻转、连续失败达到阈值、配置重载、服务启停时记录。

### 10.2 前台运行守护进程（排障首选）

```bash
/etc/init.d/netmonitor stop
sh -x /usr/libexec/netmonitor/netmon-daemon.sh
```

### 10.3 检查数据文件

```bash
ls -l /tmp/netmonitor/state/          # 每个目标一行运行状态
tail -n 5 /tmp/netmonitor/ring/baidu.tsv     # 原始采样：t latency ok errno
cat /tmp/netmonitor/hist/baidu.cur    # 当前统计段
cat /tmp/netmonitor/tick              # 最近一次心跳时间戳
```

错误码：`0` 成功、`1` 超时、`2` DNS 解析失败、`3` 网络不可达、`4` 其它错误、`5` 目标非法。

### 10.4 手工验证 RPC

```bash
ubus call luci.netmonitor service_status '{}'
ubus call luci.netmonitor get_status '{"spark":true}' | head -c 800
```

### 10.5 常见问题

| 现象 | 排查 |
| --- | --- |
| 页面一直显示"暂无监控数据" | ① 服务是否运行 `/etc/init.d/netmonitor status`；② 是否有启用目标 `uci show netmonitor \| grep enabled`；③ 心跳文件 `/tmp/netmonitor/tick` 是否更新 |
| 目标一直 DNS 解析失败 | 检查路由器 DNS 配置；域名是否被劫持；可先换成 IP 测试 |
| 改动配置不生效 | procd 会监听 `/etc/config/netmonitor`，若未触发可手动 `/etc/init.d/netmonitor reload` |
| 页面样式异常 | 确认 CSS 已加载（浏览器开发工具搜索 `.nm-root`）；本页面样式全部在 `.nm-` 命名空间内，不会与其它主题冲突 |
| 中文未生效 | 确认已安装 `luci-i18n-netmonitor-zh-cn`（注意包名是别名 `zh-cn`，源码目录才是 `po/zh_Hans`，见 12.11），或编译时在 LuCI → Translations 中选中 Chinese；必要时在 LuCI 中重新切换语言 |
| 服务反复重启 | 查看 `logread`，通常为配置非法（如 host 含空格）导致；修正后 `restart` |

---

## 十一、测试清单

### 编译测试

```bash
make package/luci-app-netmonitor/compile V=s
```

### 服务测试

```bash
/etc/init.d/netmonitor start
/etc/init.d/netmonitor status
/etc/init.d/netmonitor restart
/etc/init.d/netmonitor reload
/etc/init.d/netmonitor enable
/etc/init.d/netmonitor disable
```

### 配置测试

```bash
uci show netmonitor
```

### 网络测试矩阵

| 场景 | 期望 |
| --- | --- |
| IPv4 地址可达 | 正常延迟，状态在线 |
| IPv4 域名可达 | 正常延迟；DNS 正常 |
| IPv6 地址可达 | 走 `ping6`，正常延迟 |
| 不可达地址 | 状态失败，错误类型为超时 |
| 不存在域名 | 明确显示 **DNS 解析失败**，而非"Ping 失败" |
| 断网 | 显示网络不可达或超时，连续失败达到阈值后等级下沉 |
| 丢包网络 | 丢包率上升，图上出现丢包标记 |

### UI 测试

桌面 / 手机 / 浅色 / 深色 / 默认 LuCI 主题 均需检查：
无横向溢出、按钮可点、文字不截断、表格可横向滚动。

以下四项是**端到端硬断言**（v1.1.0 已在实机全量跑通），不只是肉眼检查：

- 设置页每个设置项都带 `data-nm-key`，其键名集合与后端 `GLOBAL_OPTS`
  **完全一致（不多不少）**，且控件当前值等于 `uci get` 的真实值
- 不做任何改动直接点「保存并应用」→ 提示 `No changes to save`，
  **不出现** `ubus code 5` 之类的原始 RPC 报错
- 目标管理页可新增 / 编辑 / 删除目标，保存后 `uci show netmonitor` 与页面显示一致
- 目标改用 TCP 探测方式后能真实产出握手延迟：
  `/tmp/netmonitor/ring/<id>.tsv` 出现 `ok=1` 且延迟为数值的采样

### 异常测试

- 目标不可达、网络断开、DNS 异常
- 杀掉守护进程：`kill -9 $(cat /var/run/netmonitor.pid)` → procd 应在数秒内 respawn
- 写入非法配置 → 服务应拒绝或回退到默认值而不是崩溃

### 单元测试

守护进程的五块核心逻辑（ping 解析 / 错误分类、targets.tsv 解析、分段直方图、
TCP 探测、临时目录按实例隔离与 config_load 变量缓存清理）
有可重复运行的单元测试，覆盖 94 条断言：

```sh
# 开发机（Git Bash / Linux）与设备上均可运行
sh tests/test_netmon_daemon.sh
```

测试要点：

- 用 `sed` 截掉 `main() {` 及之后的分发段，把脚本当库加载，避免执行主循环。
- 用 **shell 函数**做命令替身（`ping` / `logger` / `rm`），而不是 stub 目录前置 PATH。
  原因见下文 12.4，PATH 前置无法覆盖本环境下的 `rm` shim。
- 第 2 组用例是**回归护栏**：它断言「不带占位符的旧 tsv 写法确实会字段错位」，
  而不只是「新写法能用」。这样一旦有人改回旧写法，测试会立刻失败。

前端动态图标另有一套 442 条断言的自检，不需要设备即可运行：

```sh
# 需要 Node.js（不依赖浏览器）
node tests/test_icons.js
```

测试要点：

- 导出完整性：24 个图标函数全部存在且可调用。
- 结构合法性：每个图标在多种输入下都返回**恰好一个** `<svg>` 根节点，
  且不含 `undefined` / `NaN` 泄漏到属性里。
- 数据变化性：13 组「不同输入必须产生不同输出」的断言，防止图标退化成装饰。
- 数据语义：有数据时不得输出 `--` 占位，无数据时不得伪造 `0ms`；
  尺寸阈值以下必须真的不绘制文字。
- 调用一致性：扫描 7 个页面源码，凡出现 `icons.xxx()` 的名字必须在 `icons.js` 中导出。

---

## 十二、开发约定与踩坑记录

以下每一条都在 ImmortalWrt SNAPSHOT（aarch64，LuCI Master 26.246）实机上验证过，
是本项目的硬约束，改动相关代码时请一并遵守。

### 12.1 rpcd ucode 插件：参数一律以字符串传递

`rpcd-mod-ucode` 调用 ucode 方法时，**第一个参数是 request 资源对象，实参在
`request.args` 里**，不是「第一个参数即参数对象」：

```ucode
// 正确
call: function(req) {
    const a = (type(req?.args) == 'object') ? req?.args : {};
    // 用 a.id、a.name …
}

// 错误：a 是 resource，a.id 恒为 null
call: function(a) { /* a.id */ }
```

实测约束（同一台设备）：

| 传入值 | 结果 |
|---|---|
| `{"x":"1"}`（字符串） | 正常 |
| `{"x":1}`（数字字面量） | `Invalid argument` |
| `{"x":true}`（布尔字面量） | `Invalid argument` |
| `{"x":["a"]}`（数组字面量） | `Invalid argument` |
| 未在 `args` 中声明的键 | `Invalid argument` |

因此：

1. 方法必须在 `args` 里声明**每一个**可能的键，缺一个键该调用就会被拒绝。
2. 前端统一把标量序列化为字符串，数组转成逗号分隔列表（见 `common.js` 的 `strParams`）。
   例如批量操作传 `ids: "baidu,cloudflare"`，后端用 `split(a.ids, ',')` 解析。
3. `args` 里写的类型值（`'string'` / `'array'` / 任意占位串）只作占位，实际只接受字符串。

### 12.2 rpcd ucode 插件：返回结构必须是 `{ '<ubus对象名>': methods }`

```ucode
return { 'luci.netmonitor': methods };   // 正确
return methods;                          // 对象不会注册，ubus list 看不到
```

### 12.3 LuCI 前端：工具模块必须 `return Class.extend({...})`

LuCI 的模块加载器要求 factory 返回**类**，加载器随后 `new` 出实例并注入给依赖方：

```js
// luci.js 加载器逻辑
_class = _factory(...);
if (!Class.isSubclass(_class))
    error('"%s" factory yields invalid constructor', name);
const instance = new _class();   // 注入给依赖方的就是这个实例
```

- 工具模块（`common.js` / `icons.js` / `chart.js`）：用 `return Class.extend({...});`
- 页面模块（`view/netmonitor/*.js`）：用 `return view.extend({...});`
- **不要用 `Class.singleton({...})`**：它等价于 `Class.extend().instantiate()`，
  返回的是**实例**，必然触发 `factory yields invalid constructor`。
- 依赖注入进来的已经是实例，可以直接 `common.api.xxx()`。
- 引用带点号的模块要显式别名：`'require netmonitor.common as common';`
  （加载器会把点号替换成下划线，不写别名拿不到变量）。

### 12.4 targets.tsv：空字段必须写占位符，否则字段整体错位

TAB 属于 IFS **空白字符**，POSIX shell 的 `read` 会合并连续分隔符。
当 `iface` / `source` / `label` / `remark` 为空时会产生连续 TAB，导致后面的字段
整体左移：

```
# 错误写法（空字段留空）
alidns \t AliDNS \t 223.5.5.5 \t ... \t ipv4 \t \t \t DNS \t
                                              ↑ 连续 TAB 被合并
实际解析：iface = "DNS"   ← label 左移到了 iface
后果：执行 ping -I DNS 223.5.5.5 → busybox 报 bad address 'DNS'
      → 被错误归类成「DNS 解析失败」
```

修复：写入时把空字段写成 `-`，读取后还原为空（见 `netmon-daemon.sh` 的
`nm_append_target` 与三处 `read` 之后）。保证每行字段数恒为 12。

### 12.5 行尾必须 LF

OpenWrt 的 shell 是 BusyBox ash，CRLF 会让 `\r` 成为脚本内容的一部分，
表现为 procd 启动失败或命令解析异常。`.sh` / `.py` / 配置脚本与 RPC 文件一律 LF。
仓库根目录已放 `.gitattributes`（`* text=auto eol=lf`）作结构性保障。

### 12.6 uci-defaults 不会隐式创建配置文件

部分设备的 `uci set` 不会自动创建 `/etc/config/<name>`（报 `Entry not found`）。
`uci-defaults` 脚本里要先兜底：

```sh
[ -f "/etc/config/$NM_CFG" ] || : > "/etc/config/$NM_CFG"
```

另外 SSH 通道下 heredoc 容易被吞，建议用 `printf` 管道喂 `uci -q batch`。

### 12.7 i18n 模块并非所有固件都存在

`L.require('i18n')` 在精简固件上会产生 404（该文件不存在），
且这是**网络层错误，JS 的 catch 无法消除**，会一直出现在控制台。
因此只在 LuCI 已注册 i18n 能力时才调用，否则交给服务端注入的翻译表。

### 12.8 排查：部署后菜单不出现

删掉 LuCI 的索引缓存并重启 rpcd：

```sh
rm -f /tmp/luci-indexcache*; rm -rf /tmp/luci-modulecache
/etc/init.d/rpcd restart
```

### 12.9 SDK 构建：CI 环境变量 `PKG_NAME` 污染包元数据扫描，使 `package/<name>/compile` 目标消失

**现象**：GitHub Actions 中 `make defconfig` 步骤退出码为 0（`.config` 正常写出、
`CONFIG_TARGET_*` 符号齐全），下一步却报

```
make[1]: *** No rule to make target 'package/luci-app-netmonitor/compile'.  Stop.
make: *** [include/toplevel.mk:226: package/luci-app-netmonitor/compile] Error 2
```

同时诊断输出显示 `tmp/.packageinfo` 里 `^Package: luci-app-netmonitor$` 有 **146 条**
（不同 SDK 版本为 146/148 条），且这些同名条目的 `Submenu` / `Depends` 各不相同：

```
33544:Package: luci-app-netmonitor
33545-Submenu: 1. Collections
33547-Depends: +libc +luci-light +luci-app-package-manager   # 字段实为 luci 元包的
33567:Package: luci-app-netmonitor
33568-Submenu: 3. Applications
33570-Depends: +libc +luci-base +acme                        # 字段实为 luci-app-acme 的
```

**根因**：CI 工作流曾定义了 workflow 级环境变量 `PKG_NAME: luci-app-netmonitor`。
OpenWrt 的包元数据扫描链路（`include/toplevel.mk` -> `include/scan.mk`）会对每个包目录
发起一次 DUMP 子 make（`--no-print-dir -r DUMP=1 -C package/<dir>`），子 make 继承环境变量；
而 `luci.mk` 用

```makefile
PKG_NAME?=$(LUCI_NAME)
LUCI_NAME?=$(notdir ${CURDIR})
```

推导包名——make 把环境变量视为"已定义"，`?=` 不会覆盖，于是**整个 luci feed 的每个包
都把自己的包名钉成了 `luci-app-netmonitor`**（只有包名行被污染，Depends/Submenu 等字段
仍是各包自己的，这就是上面"同名却字段各异"的由来）。

后果链：

1. 上百个包共用同一个 Kconfig symbol `PACKAGE_luci-app-netmonitor`，`tmp/.config-package.in`
   里出现大量 `recursive dependency detected!`（自依赖，或经 `select` 派生的跨包假环）；
2. `tmp/.packagedeps`（`package/Makefile` 的 `builddirs` 数据源）里所有行都变成
   `package-$(CONFIG_PACKAGE_luci-app-netmonitor) += <别人的目录>`，符号语义彻底错乱；
3. 最终 `package/luci-app-netmonitor/compile` 目标不再生成——错误信息指向"目标缺失"，
   与真正的 Kconfig 失败相距甚远，极具迷惑性。

**两个重要的排除项**（都有日志实锤，排查时不要再绕进去）：

- `recursive dependency detected` 是**伴生噪音而非失败原因**：SDK/feeds 本来就有一批
  （nginx-mod-* 十余条自依赖、`LIBCURL_LDAP`、`GENSIO_SSHD` 等），`make defconfig`
  报了这些 error 后仍然退出 0 并写出 `.config`。
- `scan.mk` 对每个包是**独立子 make 进程**（日志 2041 条 `Collecting package info`
  对应 2041 次静默子 make；`--no-print-dir` 让它们不打印 Entering directory），
  makefile 内的变量**不可能**跨包残留——所以"上一个包的 `PKG_NAME:=` 污染下一个包"
  的经典解释在这里不成立，唯一能跨进程渗入的就是**环境变量**。

**修法**：

1. 工作流变量改名 `NM_PKG`（`.github/workflows/build.yml`），全部引用同步替换；
   并在进入 SDK 的步骤加防御线 `unset PKG_NAME || true`。
2. `Makefile` 不设置 `PKG_NAME`、不设置 `LUCI_PKGARCH`（默认即 `all`），与上游 luci feed
   惯例一致；内部变量加 `NETMONITOR_` 前缀避免同名干扰。
3. 依赖不重复声明 `+rpcd` / `+rpcd-mod-ucode` / `+ucode`：`luci-base` 的 `LUCI_DEPENDS`
   已包含（实机 `apk info -R luci-base` 可验证，且实测不含 `ucode-mod-uloop`，需自留）。
4. Configure 步骤自愈逻辑保留：检出 `recursive dependency detected` 时只清理 `tmp/` 下
   可再生索引并重跑一次；打印 `.packageinfo` / 生成的 Kconfig 片段便于定位。

**关键约束：绝不能删除 `Config-build.in`**。它属于 Kconfig 输入（不是 `tmp/` 下的
可再生生成物），删掉后构建会立刻变成另一个错误：

```
Config.in:153: glob failed: No files found "Config-build.in"
```

**判据与速查**：

- `.packageinfo` 中 `grep -c '^Package: luci-app-netmonitor$'` 必须为 **1**（>1 即环境
  变量泄漏，先 `env | grep PKG_NAME` 排查 CI 定义）；
- `grep -B1 '^Package: luci-app-netmonitor$' tmp/.packageinfo` 可列出每条同名条目的
  `Source-Makefile:` 路径，直接看清污染来自哪些目录；
- `target symbols:` 必须非 0（`.config` 含目标符号，说明 Kconfig 写出成功）。

### 12.10 扫描阶段被文件清单排除：缺少“构建系统签名”注释，使包彻底不进 `.packageinfo`

**现象**：`PKG_NAME` 环境变量污染（12.9）修复后，诊断输出从“同名条目过多（146 条）”
转变为“完全为 0”：

```
Package 行数: 0
config PACKAGE_luci-app-netmonitor 出现次数: 0
==> packageinfo entries for luci-app-netmonitor: 0
make[1]: *** No rule to make target 'package/luci-app-netmonitor/compile'.  Stop.
```

注意与 12.9 的区别：12.9 是同名条目“过多”，这里是“完全为 0”。同时 `tmp/.packageinfo`
里**其它** luci 包（luci-base、luci-app-firewall、luci-theme-bootstrap 等）都在，唯独本包
缺席——说明扫描机制本身工作正常，是本包没有被扫描到。

**根因**：`include/scan.mk` 第 77 行用

```sh
find -L $(SCAN_DIR) -mindepth 1 -name Makefile | xargs grep -aHE 'call (Build/DefaultTargets|BuildPackage|KernelPackage)'
```

生成待扫描文件清单（FILELIST）。只有 Makefile **文本里字面量**出现 `call BuildPackage`
（或其变体）的包才会被纳入扫描。本包在 12.9 修复后只保留了两行 `include`，文本里没有
`call BuildPackage`，于是扫描阶段根本不会加载本包，DUMP 子 make 不被触发，本包自然不出现在
`.packageinfo`、Kconfig 里也没有 `PACKAGE_luci-app-netmonitor` 符号，`package/<name>/compile`
目标随之消失。

这与“luci.mk 找不到”是**不同**的失败——后者会在 `logs/package/luci-app-netmonitor/dump.txt`
里留下 `Cannot locate luci.mk` 报错；而本问题发生时**根本没有 dump.txt**，因为扫描没轮到本包。

**修法**：在 `Makefile` 末尾保留上游 luci feed 的标准签名注释（`luci.mk` 内部的
`$(eval $(call BuildPackage,...))` 不计入扫描 grep，必须靠这行注释补上）：

```makefile
# call BuildPackage - OpenWrt buildroot signature
```

**判据**：修复后再跑 CI，`Package 行数` 应为 **1**，`package/luci-app-netmonitor/compile`
目标出现，编译进入 `Build package/luci-app-netmonitor` 阶段；本包 i18n 包
`luci-i18n-netmonitor-zh-cn`（注意是别名 `zh-cn`，不是 `zh_Hans`）也随之生成。

### 12.11 CI 的 i18n 包名必须从 `.packageinfo` 推导，不能手算

**现象**：`6c074ab` 构建首次通过后，日志里出现一条误导性警告：

```
make[1]: *** No rule to make target 'package/luci-i18n-luci-app-netmonitor-zh_Hans/compile'.  Stop.
##[warning]skip luci-i18n-luci-app-netmonitor-zh_Hans
```

构建本身成功（主包编译时会顺带产出 i18n 包），但这条警告掩盖了一个真实缺陷：
CI 的 i18n 循环用 `luci-i18n-$NM_PKG-$lang` 拼名字，拼出来是
`luci-i18n-luci-app-netmonitor-zh_Hans`，而 `luci.mk` 实际生成的包名是
`luci-i18n-<basename>-<lang>`——`<basename>` 是包名去掉 `luci-<type>-` 前缀（本包即
`netmonitor`），`<lang>` 用的是 `LUCI_LC_ALIAS` 别名（`zh_Hans` -> `zh-cn`）。两者永远对不上，
循环里的 `|| echo warning skip` 把错误吃掉，翻译包能否进产物完全依赖“主包编译恰好也构建了 i18n”
这一未文档化的副作用——一旦 OpenWrt 行为变化，翻译包会悄悄丢失。

**修法**：i18n 循环不再手算名字，改为直接从本次扫描生成的 `tmp/.packageinfo` 取出本包衍生的
i18n 包名再逐个 `make package/<name>/compile`：

```sh
for i18n in $(grep -oE '^Package: luci-i18n-netmonitor-[A-Za-z0-9._-]+$' tmp/.packageinfo | sed 's/^Package: //'); do
  make package/$i18n/compile V=s || echo "::warning::skip $i18n"
done
```

### 12.12 luci.mk 不注册 i18n 子包的独立 `compile` 目标：不要单独编译，改校验产物

**现象**：`b7638de` 应用 12.11 后，循环已能正确取出真实 i18n 包名 `luci-i18n-netmonitor-zh-cn`，
但日志里依旧冒出误导性警告：
```
make[1]: *** No rule to make target 'package/luci-i18n-netmonitor-zh-cn/compile'.  Stop.
##[warning]skip luci-i18n-netmonitor-zh-cn
```
构建结论仍是 success、i18n 的 `.ipk`/`.apk` 也确实进了产物——但循环本身的 `make package/.../compile`
从未成功过，警告是“被吞掉的真实失败”。

**两个被证伪的假设**（记下来避免重走）：
1. “i18n 循环只是手算错名” → 12.11 已修正名字，警告仍在，说明不是名字问题。
2. “i18n 包没被 `.config` 选中，所以 `package/<name>/compile` 目标不存在” → 错。
   在 8982168 里我们已在 Configure 步骤把 `CONFIG_PACKAGE_luci-i18n-netmonitor-zh-cn=y`
   写进 `.config`，CI run 34933542682 的日志实锤：`No change to .config` 之后仍报
   `No rule to make target 'package/luci-i18n-netmonitor-zh-cn/compile'`。即**无论选中与否，该目标都不存在**。

**真实根因**：luci.mk 的 `LuciTranslation` 在编译**主包**时，会遍历 `po/` 下每个语言目录、把 i18n
子包（`luci-i18n-<basename>-<lang>`，本包即 `luci-i18n-netmonitor-zh-cn`）作为主包构建过程的一部分
**顺带编译并打包**；但它**不会**为这些 i18n 子包注册独立的 `package/luci-i18n-*/compile` 目标。
因此 `make package/luci-i18n-netmonitor-zh-cn/compile` 在任何情况下都“无此目标”，与 `.config` 无关。
i18n 包之所以进产物，是主包编译的**确定性产物**（非脆弱副作用）——CI 实证：ipk 日志
`Packaged contents of .../luci-i18n-netmonitor-zh-cn into .../luci-i18n-netmonitor-zh-cn_26.258.19988~8982168_all.ipk`；
apk 日志末行 `luci-i18n-netmonitor-zh-cn-26.258.19988~8982168.apk`。

**修法**：删除 i18n 编译循环（`make package/<i18n>/compile`），改为**存在性校验**——确认
`tmp/.packageinfo` 中扫描到的每个 i18n 包，都在 `bin/` 下产出了对应 `.ipk`/`.apk`
（apk 文件名用短横、ipk 用下划线分隔版本号，故两种命名一并匹配）。一旦 luci.mk 不再顺带构建 i18n，
此步立即以 `::error` 暴露，而非静默丢包：

```sh
for i18n in $(grep -oE '^Package: luci-i18n-netmonitor-[A-Za-z0-9._-]+$' tmp/.packageinfo | sed 's/^Package: //'); do
  [ -z "$i18n" ] && continue
  found=$(find bin -type f \( -name "${i18n}*.ipk" -o -name "${i18n}*.apk" \) 2>/dev/null | head -1)
  if [ -z "$found" ]; then
    echo "::error::translation package $i18n was scanned but no built artifact found under bin/"
    exit 1
  fi
  echo "==> i18n artifact present: $found"
done
```

（Configure 步骤也不再写 i18n 的 `CONFIG_PACKAGE_*`——写了也没用，反而暗示“选中才编译”的错误心智模型。）

**判据**：CI 中 Build 步骤应打印
`==> i18n artifact present: .../luci-i18n-netmonitor-zh-cn[_-]*.{ipk,apk}`，
且全程不再出现 `No rule to make target 'package/luci-i18n` 与 `##[warning]skip`。

---

### 12.13 reload 期间临时目录被新实例清空：临时目录必须按实例隔离

**现象**：设备长时间运行后，日志里零散出现
```
awk: can't open file /tmp/netmonitor/tmp/cloudflare.out: No such file or directory
```
并伴随环缓里插进空行、单次采样 `latency=null` 但 `errno=0`（既不是成功，也不是任何已知失败）。

**根因**：守护进程把单次探测的中间文件写在**共享**目录 `/tmp/netmonitor/tmp/`，
而 procd 的 `term_timeout` 是 5 秒，单次探测最长可达 `timeout*count+2` 秒。
配置变更触发 reload 时会 `restart`，新旧两个实例在一段时间内**重叠**：
新实例的 `setup_dirs()` 一上来就 `rm -f /tmp/netmonitor/tmp/*`，
把旧实例正在读写的 `.out` / `.err` 直接删掉。旧实例随即 awk 读不到文件、
把解析出的空值写进环缓。

**修法**：临时目录按实例独占，回收只针对死进程。

```sh
TMP_DIR=$RUN_DIR/tmp.$$            # 每实例一个，互不干扰

# setup_dirs() 里只回收「pid 已不存在」的遗留目录
for d in "$RUN_DIR"/tmp.*; do
    [ -d "$d" ] || continue
    [ "$d" = "$TMP_DIR" ] && continue
    p=${d##*/tmp.}
    case "$p" in ''|*[!0-9]*) ;; *) [ -d "/proc/$p" ] && continue ;; esac
    rm -rf "$d" 2>/dev/null
done
```

`cleanup()` 也只删自己的 `$TMP_DIR`；`/etc/init.d/netmonitor` 的 start/stop 不再
`rm -f .../tmp/*`——临时目录的生命周期完全由守护进程按 pid 负责。

**判据**：连续 3 次 `reload`，日志无 `awk: can't open file`、环缓无空行、
每次采样的 `latency` 与 `errno` 自洽。回归护栏见 `tests/test_netmon_daemon.sh` 第 6 节。

---

### 12.14 保存走 OpenWrt 原生 uci：`uci.apply()` 在没有改动时会报错

**现象**：前端点「保存并应用」，什么都没改也弹原始 RPC 报错
`uci/apply failed with ubus code 5: No data received`。

**根因**：`uci.apply()` 底层是 rpcd 的 `uci.apply`，它在**没有待提交改动**时
直接返回 ubus code 5（No data received）。早期前端实现是无条件
`uci.save().then(() => uci.apply())`，于是「无改动」这个最正常的操作反而**必然**报错。

**修法**：保存前逐项 `uci.get` 比对现值，只提交真正的差异；全部相同则直接返回 0，
连 `save()` / `apply()` 都不调。

```js
var cur  = uci.get(conf, sid, opt);
var want = (o.val == null) ? '' : String(o.val);
var have = (cur   == null) ? '' : String(cur);
if (have === want) continue;                 // 无差异，跳过
if (want === '') uci.unset(conf, sid, opt);
else             uci.set(conf, sid, opt, want);
changed++;
...
if (changed === 0) return 0;                 // 不调 save / apply
return uci.save().then(function () { return uci.apply(); });
```

**两个坑**：

1. **`null` 与 `''` 必须归一**。表单清空字段得到 `''`，而设备上「该选项不存在」是 `null`。
   若用 `o.val == null` 判断，二者被当作不同值，「清空一个本来就不存在的字段」
   会被算成改动，照样撞上 code 5。
2. **返回值语义要和 UI 对齐**：`0` 表示无改动，前端据此提示 `No changes to save`
   而不是 `Saved`——否则用户会以为配置被重写了。

**刻意保留的设计**：保存链路完全走 OpenWrt 原生 `uci` / `ubus`，不引入插件私有 RPC。
实测保存过程中用到的 rpcd 方法集合为 `['apply', 'changes', 'confirm', 'get', 'set']`，
`uci apply` 自带的超时回滚（`rollback`）也随之生效。

---

### 12.15 `data-nm-key` 只能挂在控件上，不能同时挂容器

**现象**：端到端测试给目标编辑器的「名称」输入框赋值 `TCPUITEST`，
脚本报告赋值成功，但保存后设备上 `uci get netmonitor.<sid>.name` 还是旧值。

**根因**：`field()` 为了给设置项打标记，把 `data-nm-key="name"` **同时**挂在了
`.nm-field` 容器 `div` 和真正的 `<input>` 上。测试用
`document.querySelector('[data-nm-key="name"]')` 命中的是**先出现的容器 div**，
赋值只是往一个 `div` 上挂了个临时属性，输入框根本没动——保存自然没变化，
而测试还以为自己改成功了。这是「测试通过但功能没生效」的典型假阳性。

**修法**：`data-nm-key` 只挂控件（`input` / `select`），容器一律不挂；
测试选择器相应收紧为 `input[data-nm-key="..."]` / `select[data-nm-key="..."]`。

**判据**：设置页 26 个控件的 `data-nm-key` 集合与后端 `GLOBAL_OPTS` 的 26 个键
**完全相等（不多不少）**，且每个控件的当前值等于 `uci get` 的真实值。

---

### 12.16 长驻守护进程 reload 会读到「已删除选项」的旧值：必须清掉 config_load 的变量缓存

**现象**：在界面上把某个字段清空（例如目标的「自定义标签」或「TCP 端口」）并保存，
`uci get` 已确认该选项不存在，但守护进程仍按旧值工作 ——
`/tmp/netmonitor/targets.tsv` 里对应列还是旧值。**重启服务后立刻恢复正常。**

**定位过程**（把变量范围压到最小）：

| 操作 | `targets.tsv` 的 label 列 |
| --- | --- |
| 设 `label=AAA` 并 `reload` | `AAA` |
| `uci delete label` + `commit` + `reload` | **仍是 `AAA`** |
| 再 `reload` 一次（不重启进程） | **仍是 `AAA`** |
| `restart` 守护进程 | `-`（正常） |

「只有重启才恢复」这一条把问题锁定在 **reload 不重启进程** 这条路径上。

**根因**：`config_load` 的实现是「把配置里**存在**的选项导出成
`CONFIG_<段>_<选项>` 变量」，它**不会**清除上一轮留下的、现在已被删除的选项变量
（`CONFIG_SECTIONS` 段缓存同理，只会不断叠加）。而 `config_get` 的取值顺序是
「变量存在就用变量，不存在才退默认值」，于是被删除的选项仍能读到旧值。

这一坑在传统 OpenWrt 服务脚本里不会出现 —— 它们每次都是新进程、重新 `config_load`。
只有**长驻进程 + 原地重载**才会踩到，而本插件为了避开 restart 竞态，
reload 正是走 SIGHUP 原地重载（见 12.13）。

**修法**：每次 `config_load` 之前先清掉全部 `CONFIG_*` 变量。

```sh
clear_config_cache() {
	local v
	for v in $(set | sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$v" 2>/dev/null
	done
}

load_config() {
	mkdir -p "$RUN_DIR"
	clear_config_cache          # 必须在 config_load 之前
	config_load netmonitor
	...
}
```

**一个容易写错的细节**：清缓存必须写成 `for v in $(set | ...)`，
让循环体在**当前** shell 执行。若写成
`set | while read v; do unset "$v"; done`，`while` 会落在管道子 shell 中，
`unset` 只作用于那个子 shell，对父进程**完全无效** —— 代码看起来「写了」，实际毫无作用。
测试里专门留了一条 `assert_not_contains 'set | while'` 防止后人改回这种写法。

**判据**：删除某选项并 `reload`（不重启）后，`targets.tsv` 对应列应立即变为占位符 `-`。
回归护栏见 `tests/test_netmon_daemon.sh` 第 7 节。

---

### 12.17 不要抢 procd 的 pidfile，reload 时也不要盲信 pid

**现象**：每次 `stop` / `restart` 都留下一条错误级日志：
```
daemon.err procd: Failed to remove pidfile: /var/run/netmonitor.pid: No such file or directory
```
看起来像停止失败，实际服务状态完全正常。这类**假报错**最耽误排障 —— 真出问题时
会被淹没，或者反过来让人去查一个根本不存在的故障。

**根因**：pidfile 由 `procd_set_param pidfile` 交给 procd 创建，**也由 procd 负责清理**。
`stop_service()` 里那句 `rm -f "$PIDFILE"` 抢在 procd 前面把它删了，
procd 随后再来删就撞上 ENOENT，于是记成错误。

**修法**：`stop_service()` 不再碰 pidfile。这一点要写在注释里，
否则后人会觉得"少了清理步骤"而把它加回去。

**顺带加固 `reload_service()`**：原实现只判断「`/proc/$pid` 是否存在」。
但 pidfile 若因异常掉电残留，那个 pid 可能早已被内核回收给**别的进程** ——
而 **SIGHUP 对多数进程是致命信号**，误发等于随手杀掉别人的进程。
现在先核对 `/proc/$pid/cmdline` 确实是本守护进程，才投递 HUP：

```sh
	cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
	case "$cmd" in
		*netmon-daemon.sh*) kill -HUP "$pid" 2>/dev/null ;;   # 确认是本守护进程
		*)                   restart ;;
	esac
```

**判据**：

- `restart` 后 `logread` 不再出现 `Failed to remove pidfile`；
- 正常 `reload` 仍打印 `configuration reload requested` + `configuration reloaded`
  （证明 cmdline 校验没有误伤正常路径）；
- 把 pidfile 故意改写成 `1` 再 `reload`，应看到 pid **发生变化**（走了 restart），
  而不是向 pid 1 发信号。三条都在实机上实测通过。

---

### 12.18 ucode 的 `int / int` 是整除：小数位被无声吃掉

**现象**：总览页丢包率卡片显示 `0%`，同一页却写着「丢包数: 1」、
样本量 124 —— 真值 0.8% 被显示成 0；延迟全部只剩整数位。

**根因**：ucode 有**独立的 `int` 类型**，且 **`int / int` 走整除**。
设备上验算：

```sh
ucode -e 'print(8/10, " ", 2530/100, " ", 8.0/10)'
# 0 25 0.8        <- 前两个是整除，第三个才是除法
```

格式化函数里写的是 `((v * m + 0.5) | 0) / m`。按位或 `|` 的结果是 `int`，
加上 `m` 本身也是 `int`，两侧皆 int → 商被截断。于是 `fx(v, 1)` 退化为整数、
`fx(v, 2)` 也只到整数位，25 处调用一起失效。同类问题还在百分位计算里：
`total * p / 100` 的 `100` 是 int 字面量，P95 被截到桶边界。

**修法**：把除数写成 double，让除法走浮点。

```js
function fx(v, d) {
	if (v == null) return null;
	let m = (d == 1) ? 10 : 100;
	return ((v * m + 0.5) | 0) / (m * 1.0);      // 除数必须是 double
}
let target = total * p / 100.0;                   // 整数百分比也要除以 100.0
```

**判据**：`ubus call luci.netmonitor get_status` 返回 `loss: 0.7`、
`current: 23.56`、`p95: 46.5`；页面上出现带小数位的百分比
（实机验证脚本断言卡片主值里至少有一个含 `.`）。

---

### 12.19 Windows 开发机上 `core.filemode=false`：脚本可执行位不入库

**现象**：设备上 `/etc/init.d/netmonitor status` 报权限错误、服务不自启；
把 SDK 打出的包解开看，init 脚本是 `644`。

**根因**：本仓库在 Windows 上开发，git 默认 `core.filemode=false`，
**文件模式根本不被追踪**，`git add` 一律记成 `100644`。而 OpenWrt 打包用
`cp -fpR` 保留源文件模式 —— 入库是 644，装到设备上就是不可执行的 init 脚本。

**修法**：`git update-index --chmod=+x <file>` **只改索引**、不动工作区。
刻意不用「改工作区权限再 `git add`」那一套：工作区权限在不同机器/复制方式下
容易丢，且 `git add` 在 `core.filemode=false` 时照样不会记录。
CI 里直接用 `git ls-files -s` 读索引模式并核对必须为 `100755`。

必须可执行的 6 个文件（带 shebang、会被直接 exec）：

```
root/etc/init.d/netmonitor
root/etc/uci-defaults/luci-app-netmonitor
root/usr/libexec/netmonitor/netmon-daemon.sh
tests/test_netmon_daemon.sh
tests/test_icons.js
po/gen_po.py
```

---

### 12.20 设备上没有 `po2lmo`：自行编译 `.lmo`

**现象**：改完 `po/zh_Hans/*.po` 直接部署，界面还是旧译文。

**根因**：运行时读的是 `/usr/lib/lua/luci/i18n/<域>.zh-cn.lmo`（编译后的 gettext 域），
`.po` 只参与构建期。而 `po2lmo` 属于 `luci-base` 的**宿主工具**，
测试设备上并没有（`which po2lmo` 为空）。

**做法**：按上游 `modules/luci-base/src/po2lmo.c`（写入端）与
`src/lib/lmo.c`（读取端）自行实现一个纯 Python 编译器，放在开发工作区、不进包。
格式要点（全部**大端**）：

- **数据区**：每条 msgstr 的 UTF-8 字节，然后补 0 到 4 字节对齐，
  `pad = (4 - len % 4) % 4`；offset 累加的是「长度 + 填充」。
- **索引区**：N 条 × 16 字节 `key_id, val_id, offset, length`，
  按 `key_id` 升序，`val_id = plural_num + 1`（非复数即 1），
  `offset` 是**文件绝对偏移**。
- **末尾 4 字节**：索引区的起始偏移。
- 键与值都用 Paul Hsieh 的 `sfh_hash`；`msgstr` 为空、
  或 `sfh_hash(key) == sfh_hash(val)` 的条目跳过。

**可信度怎么来的**：拿入库的 po 重编译，与设备现存的 `.lmo`
**逐字节比对一致**（v1.0.1 的 7 个提交全部一致），说明实现与官方一致；
再用它编译新版 po 覆盖上去。

**判据**：编译工具自检「回读全部一致」；部署后本地文件与设备文件 md5 相同。

---

### 12.21 中文映射表的两种静默失效：重复键与核心语言包同名覆盖

这两种都不会报错、不会出现在 `untranslated` 里，只能靠专门的审计发现。

**（一）映射表重复键**

- **现象**：目标管理页的页签显示「目标数」，应为「目标管理」。
- **根因**：`po/gen_po.py` 的中文映射表在总览段又写了一条
  `'Targets': '目标数'`，与菜单段的 `'Targets': '目标管理'` 同名。
  Python 字典字面量里**后者覆盖前者且不给任何提示**，被覆盖的那条翻译
  静默失效 —— 而 `collect()` 只会把「没有译文」的条目报成 untranslated，
  重复键属于「有译文但取的不是你以为的那条」，查不出来。
- **修法**：删掉重复键；并让 `gen_po.py` 用 `ast` **回读自己的源码**
  （字典构造时重复键已合并，单看 ZH 变量查不出来），把重复键及其行号打印出来，
  CI 命中 `DUPLICATE ZH key` 即失败。

**（二）核心语言包同名覆盖**

- **现象**：目标管理页表头显示「**卷标**」（本插件写的是「标签」）；
  在线率的百分比被标成「运行时间」（`Uptime`）；
  从无数据的时间显示成「**禁用**」（`Never`，本意「从未检测」）。
- **根因**：LuCI 把核心 `base.zh-cn.lmo` 与插件语言包一起加载，
  **同名 msgid 上核心覆盖插件**，插件自己写的那条被静默丢弃。
  核心的 `Label` 指分区卷标、`Uptime` 指运行时间、`Never` 是「禁用」。
- **排查手法**：`.lmo` 只存哈希、无法反查 msgid，于是**反向算** ——
  对本插件每个 msgid 求 `sfh_hash`，去核心语言包的索引里查，命中即同名，
  再比两条译文是否一致。
- **修法**分两类：
  - 核心译文在本插件语境下不合适 → 换成插件语境明确的新 msgid：
    `'Label'` → `'Custom label'`、`'Uptime'` → `'Availability'`、
    `'Never'` → `'Never checked'`；
  - 核心译文同样可用 → 本插件取值**直接对齐核心**：
    `Interval` / `Overview` / `Enabled`。
- **护栏**：把「核心语言包也有、且本插件在用」的 26 个 msgid 及其核心译文
  冻结进 `po/core_msgids.txt`，`gen_po.py` 校验「同名必须同译」，
  CI 命中 `CORE COLLISION MISMATCH` 即失败。清单外的通用词检测不到 ——
  新增 `_('...')` 文案后需用工作区的冲突审计脚本复查并重新生成清单。
- **判据**：实机断言「在线率」出现且「运行时间」不出现；
  目标管理页「自定义标签」出现且「卷标」不出现。

---

### 12.22 后端 `err()` 文案必须登记进前端映射表

**现象**：后端校验失败时，界面上弹出的是英文原文（如 `invalid host`）。

**根因**：rpcd 的 ucode 插件**没有 LuCI i18n 运行时**，只能返回英文串。
前端把它交给 `_()` 时用的是**变量形式**（`_(BACKEND_MSG[s])`），
`po/gen_po.py` 的正则抓不到字面量 → 不进 po → 运行时查表落空 → 回落英文。

**修法**：

- `po/gen_po.py` 直接解析 `common.js` 里的映射表作为文案来源
  （映射表即唯一事实来源，后端登记一条，翻译侧自动跟上）；
- 前端在 RPC 的**唯一出口** `common.localizeError()` 统一查表，
  并支持 `invalid value for <键名>` 这类前缀拼接报错；
- `gen_po.py` 把 ucode 后端全部 `err('...')` 字面量与映射表键比对，
  未登记即打印 `UNREGISTERED backend error`，CI 失败。

**约束**：后端新增任何 `err('...')`，必须同时登记进
`common.js` 的 `BACKEND_MSG` / `BACKEND_MSG_ARG` 并补中文，
否则 CI 直接拦下。

---

### 12.23 CI 的 `checks` 作业

`checks` 作业在 `build` 之前跑（`build` 声明 `needs: checks`），含四项：

| 检查 | 拦下的真实事故 |
| --- | --- |
| 可执行位（读 git 索引） | init 脚本入库成 644，装到设备上服务起不来 |
| 翻译完整性 | 后端 `err()` 漏登记、映射表重复键、与核心语言包同名不同译 |
| 守护进程单元测试 | 探测输出解析、字段对齐、TCP 判定等逻辑回归 |
| 图标与视图断言 | 图标导出缺失、SVG 结构与尺寸阈值被破坏 |

之所以**前置**而不是放在 build 之后：这几项失败时，产物照样能编出来、
CI 也是绿的，只是装上不能用 —— 等到设备实测才发现，代价最大。

**注意：代码生成必须与文件系统无关。** `po/gen_po.py` 遍历源码目录产出 po/pot，
而 `os.walk` 的**目录枚举顺序由文件系统决定**（NTFS 与 ext4 就不一样），
只对文件名排序并不够 —— 子目录的先后会改变条目顺序，于是 CI 上的
`git diff --exit-code -- po/` 在换机器后**必然**报「po/ 与源码不一致」。
已对 `dirnames` 就地排序，使产出与文件系统无关。

---

## 十三、兼容性

- 目标平台：OpenWrt 主线（23.05 / 24.x 及更新版本），兼容其衍生发行版
- LuCI：现代 JS 视图 + ucode RPC 架构（传统 Lua CBI 版本不适用）
- 探测命令：ICMP 模式用 busybox `ping` / `ping6`，同时兼容 iputils 输出格式；
  TCP 模式优先用 `curl`（握手耗时取自 `%{time_connect}`），无 curl 时退化到支持 `-w` 的 `nc`
  并用单调时钟计时；两者都不可用时 TCP 目标会明确报「其它错误」而不是静默成功
- 主题：仅使用主题提供的 CSS 变量与 `.nm-` 私有命名空间，不影响其它页面

---

## 十四、动态 SVG 图标与动画系统

全部图标在 `htdocs/luci-static/resources/netmonitor/icons.js` 中用内联 SVG 绘制，
不引用任何图标 CDN、图标字体或位图。共 24 个图标，统一使用 `0 0 120 120` 视口
（`dot()` 为 10×10 的微型状态点，用于表格行首）。

设计原则只有一条：**图标是数据可视化，不是装饰**。同一个函数在不同真实数据下
输出不同的结构、颜色与动画速度；任何图标都不会在缺少数据时伪造一个数值。

### 14.1 图标含义与绑定字段

| # | 函数 | 含义 | 绑定的真实数据 |
|---|------|------|----------------|
| 01/02 | `health(state, size)` | 总体健康 / 异常 | `get_status.health`（good / warning / critical / unknown） |
| 03 | `ping(size, opts)` | Ping 探测 | 探测等级；DNS 失败时整体转为橙色 |
| 04 | `latencyDial(ms, grade, size)` | 实时延迟表盘 | 中心数字 = `overall.current`，配色 = 阈值判定等级 |
| 05 | `online(size, ok)` | 在线状态 | `targets[].status`（在线时虚线环流动，离线时静止变灰） |
| 06 | `packetLoss(pct, size)` | 丢包检测 | `loss`：0% 画绿色对勾，>0% 画红色叉号 |
| 07 | `highLatency(ms, grade, size)` | 高延迟波形 | 目标延迟与等级（poor / severe 时波形转橙红） |
| 08 | `dnsFail(size)` | DNS 解析失败 | `targets[].last_error == 'dns'` |
| 09 | `regionCN(size, region, ms)` | 国内网络 | `regions.cn`：abnormal > 0 时节点转红并叠加告警环 |
| 10 | `regionGlobal(size, region, ms)` | 国外网络 | `regions.overseas` |
| 11 | `gradeGauge(ms, grade, size)` | 延迟等级仪表 | 指针角度与彩色弧长均由阈值等级换算 |
| 12 | `trend(size)` | 统计趋势 | 曲线卡片标识 |
| 13 | `iface(up, size)` | 网络接口 | 接口链路状态（down 时指示灯闪烁） |
| 14 | `service(state, size)` | 服务状态 | `get_status.running`（停止时外环反转、指示灯闪烁） |
| 15 | `multiTarget(list, size)` | 多目标监控 | 最多 3 个目标的圆点颜色（等级 → 状态 → 启用 → 中立色） |
| 16 | `successRing(pct, size)` | 成功率圆环 | 弧长 = 按样本加权的 `success_rate` |
| 17 | `lossRing(pct, size)` | 丢包率圆环 | 弧长 = `loss`；0% 时弧长为 0，不会伪造一个绿色满环 |
| 18 | `clock(ts, size)` | 检测时间 | 时针 / 分针角度由 `tick`、`last_check` 的真实时间换算 |
| 19 | `gear(size)` | 设置 | 设置页当前生效参数 |
| 20 | `database(size)` | 历史数据 | 数据来源（内存 / 持久化）与保留期 |
| 21 | `bell(count, size)` | 异常提醒 | `overall.offline`：为 0 时显示绿色对勾而非红色徽标 |
| 22 | `dualStack(family, v4, v6, size)` | IPv4 / IPv6 | `address_family` 与目标地址族，未启用的一侧变灰 |
| 23 | `liveBars(values, size)` | 实时统计柱状 | 各目标当前延迟，柱高按最大值归一化 |
| 24 | `responsive(size)` | 响应式布局 | 小屏表格可横向滚动的说明 |

### 14.2 环形进度的算法

圆环半径固定 `r = 38`，周长 `C = 2πr ≈ 238.76`。进度弧通过内联
`stroke-dasharray: <C × ratio> <C>` 表达，并 `rotate(-90 60 60)` 让起点回到 12 点方向。

因此弧长是数值的线性映射，可以直接反算校对：

| 显示值 | stroke-dasharray | 校验 |
|--------|------------------|------|
| 成功率 100% | `238.8 238.8` | 满环 |
| 成功率 75% | `179.1 238.8` | 179.1 / 238.8 = 0.75 |
| 丢包率 25% | `59.7 238.8` | 59.7 / 238.8 = 0.25 |
| 丢包率 0% | `0.0 238.8` | 不绘制弧，只保留底色环 |

`online()` 的在线弧使用 `r = 40`（周长 251.3），`gradeGauge()` 使用半圆弧
（`r = 42`，弧长 ≈ 131.9）。

### 14.3 动画实现与性能约束

动画全部由 CSS 完成（不使用 SMIL `<animate>`），只驱动三个属性：

| 关键帧 | 作用属性 | 使用场景 |
|--------|----------|----------|
| `nm-dash-v3` / `nm-dash-v3-rev` | `stroke-dashoffset` | 虚线环流动（在线、接口、趋势、DNS 失败的对勾路径） |
| `nm-pulse-soft` | `opacity` | 节点 / 数据点呼吸 |
| `nm-ring-scale` | `transform: scale()` + `opacity` | 告警环扩散 |
| `nm-bars` | `transform: scaleY()` | 柱状图错峰起伏 |
| `nm-blink-soft` | `opacity` | 失效状态闪烁 |
| `nm-rotate` | `transform: rotate()` | 齿轮旋转、在线环旋转 |

三条约束：

1. **位移量取虚线周期的整数倍**。`stroke-dasharray: 5 9` 的周期是 14，
   位移量取 70（= 5 个周期），首尾状态严格重合，循环处不会跳帧。
2. **`transform` 必须配 `transform-box: fill-box`**，让旋转 / 缩放围绕元素自身
   包围盒进行，规避各浏览器对 SVG `transform-origin` 的解析差异。
3. **不使用 `filter`、`blur`、大面积 `box-shadow`**，避免在低端路由设备上产生
   离屏合成开销。整套动画只作用于合成层属性，不触发重排。

`@media (prefers-reduced-motion: reduce)` 下 `.nm-root * { animation: none !important }`，
用户系统的减少动效偏好会被严格尊重。

### 14.4 文字可读性阈值

图标统一按 120×120 绘制，字号随渲染尺寸等比缩小：`font-size: 23` 在 44px 的图标里
只剩 8.4px，`font-size: 11` 更是只剩 4px —— 渲染出来是一团噪点，不是信息。
因此约定：

| 阈值 | 内容 | 说明 |
|------|------|------|
| ≥ 60px | 主数值（延迟数字、圆环百分比） | 实际高度约 11.5px，可读 |
| ≥ 84px | 辅助文字（ms、IPv4 / IPv6、目标名、告警计数） | 实际高度约 9px，可读 |

低于阈值时只保留图形本身，数值由旁边的真实文字承担。例如目标卡片中 44px 的
丢包 / 成功率圆环不绘制中心百分比，而是在右侧以 `<b>0%</b>` 呈现。

### 14.5 图标在页面上的分布

| 页面 | 动态图标 |
|------|----------|
| 总览 | 健康环（76px 主视觉）、6 张 KPI 卡的右上角图标、6 张图标指标卡、每张目标卡的在线状态 + 丢包 / 成功率圆环、页脚服务状态 + 实时采样柱状 |
| 实时监控 | 指标条 4 张图标卡；表格状态列的图标按真实失败类型切换（正常 → 在线环，DNS → 地球叉号，超时 → 丢包叉号，高延迟 → 波形） |
| 延迟曲线 | 摘要卡图标（当前 / 最大 / 最小 / 范围）+ 实时采样柱状 |
| 国内 / 国外 | 区域大图标（节点颜色由 abnormal 决定）+ 区域丢包 / 在线率圆环 |
| 历史数据 | 概览条 4 张图标卡（目标数 / 平均延迟 / 丢包 / 成功率，均由区间统计重算）+ 卡片标题图标 |
| 目标管理 | 工具条多目标 + 齿轮、地址族列双栈图标、启停列在线图标、小屏提示图标 |
| 设置 | 当前生效配置 6 张图标卡（数值直接读 UCI）+ 服务状态图标 |

### 14.6 自检与实机验证

```sh
# 1) 本地自检：442 条断言，覆盖导出完整性、SVG 结构、尺寸阈值与数据语义
node tests/test_icons.js

# 2) 实机验证：逐页检查图标数量、运行中的动画数量、环形弧长与控制台错误
python3 nm_svg_verify.py
```

实机验证会打印每页的 `icons(svg.nm-svg)` / `animating` 计数与
`stroke-dasharray` 实测值，可直接与上表核对。

---

## 十五、已知限制

1. 探测协议已实现 ICMP 与 TCP 两种（选择方式见 6.2.1）；HTTP 层面（状态码 / 内容校验）
   的探测尚未提供，`proto` 已是开放枚举，后续版本可扩展。
2. TCP 模式依赖设备有 `curl`（或支持 `-w` 的 `nc`）；两者都没有时 TCP 目标会稳定报
   「其它错误」，不会静默算成成功。
3. `both`（IPv4 + IPv6 同时探测）当前按主地址族执行双栈解析，独立结果展示待后续版本完善。
4. 通知功能仅提供配置位与接口预留，尚未接入具体后端。
5. 目标级检测间隔受全局轮询周期约束，实际间隔为「不小于全局检测间隔」的最接近值。
6. 动态图标中的目标名 / 计数等辅助文字仅在图标渲染尺寸 ≥ 84px 时出现，
   小尺寸下由旁边的文字承担（见 14.4）。

---

## 十六、版本与更新日志

**本文件不再维护任何形式的版本变更记录。** 所有版本变更的唯一归口是
[`CHANGELOG.md`](CHANGELOG.md)，格式遵循
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

| 位置 | 职责 |
| --- | --- |
| `CHANGELOG.md` | **唯一的**版本变更记录：新增 / 变更 / 修复三类条目，按版本倒序排列 |
| `README.md`（本文件） | 只描述**当前版本**的稳定行为：设计原则、架构、配置、RPC、调试与开发约束 |
| 第十二章 | 踩坑记录按**技术主题**组织，不按版本组织；条目本身就是当前仍生效的硬约束 |

这样切分的理由：

1. 第十二章的每一条都是**至今仍生效的约束**，不是「某版本改过什么」；
   把它放在 README 里，读者才能和对应的代码放在一起看。
2. 版本历史留在 README 里会随版本线性膨胀，最终挤掉使用文档本身 ——
   本项目 README 已逾 1400 行，这个风险是真实存在的。
3. `CHANGELOG.md` 末尾的链接引用块直接指向各版本的 `compare` 链接，
   需要逐行 diff 时可从那里跳转。

```bash
git log --oneline                    # 提交历史
git tag -l                           # 已发布版本：v1.0.0 / v1.0.1 / v1.1.0 / v1.2.0
git diff v1.1.0..v1.2.0              # 两个版本之间的完整改动
```

版本号与 `Makefile` 的一致性由发布流程保证：`PKG_VERSION` 必须与 `CHANGELOG.md`
最新条目的版本号、以及 git tag `v<版本>` 三者相同。

---

## 十七、许可证

GPL-3.0-or-later，`LICENSE` 为 GPLv3 完整官方文本。

Copyright (C) 2026 netmonitor contributors

本包沿用 LuCI 生态惯例，以 SPDX 标识 `GPL-3.0-or-later` 声明在 `Makefile` 的
`PKG_LICENSE` 中；原 1.1.0 及更早版本发布于 GPL-2.0-or-later，该许可证本身即允许
按 GPLv3 使用。各版本变更见 [`CHANGELOG.md`](CHANGELOG.md)。


