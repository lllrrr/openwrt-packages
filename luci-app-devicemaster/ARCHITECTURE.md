# DeviceMaster 功能架构图谱

## 一、整体架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DeviceMaster 插件架构                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐          │
│  │   前端界面层     │    │   API 控制层     │    │   后端服务层     │          │
│  │                 │    │                 │    │                 │          │
│  │  devices.htm    │───▶│ devicemaster.lua│───▶│ device_monitor  │          │
│  │  groups.js      │    │                 │    │ event_handler   │          │
│  │  settings.lua   │    │  20+ API端点    │    │ traffic_control │          │
│  │                 │    │                 │    │ oui_lookup      │          │
│  └─────────────────┘    └─────────────────┘    │ sync_hostname   │          │
│                                                │ schedule_exec   │          │
│                                                │ snapshot_writer │          │
│                                                └─────────────────┘          │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                          数据存储层                                    │  │
│  │                                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │ UCI配置     │  │ session.json│  │ OUI数据库   │  │ 缓存文件    │  │  │
│  │  │ (Flash)     │  │ (RAM/tmpfs) │  │ (本地/远程) │  │ (tmp)       │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                          系统资源层                                    │  │
│  │                                                                       │  │
│  │  /tmp/dhcp.leases  /proc/net/arp  nftables  tc  dnsmasq  ubus        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 二、核心功能模块

### 1. 设备发现与识别（7级识别链）

```
┌─────────────────────────────────────────────────────────────────┐
│                    设备识别流程（优先级从高到低）                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Level 0: 用户手动标注 (manual=1) ───────────── 最高优先级       │
│      │                                                           │
│  Level 1: 本地 OUI 数据库查询 ─────────────────── IEEE数据库     │
│      │                                                           │
│  Level 2: 远程 OUI API 查询 ───────────────────── maclookup.app  │
│      │                                                           │
│  Level 3: mDNS/Bonjour 探测 ───────────────────── Apple设备识别  │
│      │                                                           │
│  Level 4: DHCP hostname 模式匹配 ─────────────── 品牌推断        │
│      │                                                           │
│  Level 5: DHCP Option55 指纹分析 ─────────────── OS识别         │
│      │                                                           │
│  Level 6: nlbwmon 协议分析 ───────────────────── 流量特征       │
│      │                                                           │
│  Level 7: 端口流量模式分析 ───────────────────── conntrack      │
│      │                                                           │
│  输出: 厂商 + 设备类型 + 自动命名                                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2. 设备在线状态判断（多层验证）

```
┌─────────────────────────────────────────────────────────────────┐
│                    在线状态判断流程                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Tier 1: WiFi Station (iw station dump) ──────── 直接WiFi连接   │
│      │                                                           │
│  Tier 2: ip neigh REACHABLE/PERMANENT ────────── ARP可达状态    │
│      │                                                           │
│  Tier 3: IoT设备 DHCP租约存在 ────────────────── 长连接设备     │
│      │                                                           │
│  Tier 4: Ping探测 ────────────────────────────── 主动验证       │
│      │                                                           │
│  特殊规则:                                                       │
│  ├─ Mesh子节点: 任一子设备在线 → 节点在线                       │
│  ├─ NAT设备: 下游设备在线 → NAT设备在线                         │
│  ├─ 非LAN设备: 最近在线过 → 5分钟内保持在线（防闪烁）           │
│  └─ 合并设备: 任一alt_mac在线 → 设备在线                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 3. Mesh网络拓扑识别

```
┌─────────────────────────────────────────────────────────────────┐
│                    Mesh拓扑判断逻辑                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  主节点判断:                                                     │
│  ├─ dhcp.lan.ignore ≠ 1 (DHCP服务启用)                         │
│  ├─ 有 dhcp range 配置                                          │
│  └─ 能读取 /tmp/dhcp.leases                                     │
│                                                                  │
│  子节点判断:                                                     │
│  ├─ dhcp.lan.ignore = 1 (DHCP服务禁用)                         │
│  ├─ 有 mesh接口 (wl1-mesh0)                                     │
│  └─ 默认网关指向主节点IP                                         │
│                                                                  │
│  拓扑层级:                                                       │
│  ├─ direct ─────── 直接WiFi连接到本路由器                       │
│  ├─ mesh_node ──── Mesh节点本身                                 │
│  ├─ mesh_child ─── 通过Mesh节点连接的设备                       │
│  ├─ remote ─────── 在线但非直连（有线/其他路径）                │
│  └─ unknown ─────── 状态未知                                    │
│                                                                  │
│  数据同步:                                                       │
│  ├─ 主节点: 创建快照 → /tmp/dm_snapshot.json                    │
│  ├─ 子节点: 上报数据 → POST /api/report_sub                     │
│  └─ 子节点: 拉取快照 → 补充远程设备信息                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4. 设备命名与同步

```
┌─────────────────────────────────────────────────────────────────┐
│                    设备命名流程                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  命名优先级:                                                     │
│  1. 用户自定义名称 (manual=1) ──────────────── 最高优先级       │
│  2. DHCP hostname ──────────────────────────── 客户端报告       │
│  3. mDNS探测名称 ───────────────────────────── Apple设备        │
│  4. 自动生成: 厂商-类型 ──────────────────────── 如 "Apple-phone"│
│                                                                  │
│  重名处理:                                                       │
│  ├─ 检测 devicemaster + dhcp 中的重复                           │
│  ├─ 自动追加序号: name-2, name-3...                             │
│  └─ 智能解析: iphone-2 → iphone-3 (不变成 iphone-2-2)          │
│                                                                  │
│  同步流程:                                                       │
│  ├─ 修改 UCI devicemaster.name                                  │
│  ├─ 调用 sync_hostname.sh                                       │
│  │   ├─ 删除旧 dhcp host 条目                                   │
│  │   ├─ 检查重名并追加序号                                       │
│  │   ├─ 创建新 dhcp host 条目                                   │
│  │   ├─ 修改 /tmp/dhcp.leases                                   │
│  │   └─ 重启 dnsmasq                                            │
│  └─ 结果: OpenWrt终端列表显示自定义名称                         │
│                                                                  │
│  注意: dnsmasq不支持中文hostname，会自动过滤                     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 5. 流量控制

```
┌─────────────────────────────────────────────────────────────────┐
│                    流量控制功能                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  封禁功能:                                                       │
│  ├─ nftables set: blocked_macs                                  │
│  ├─ 链: dm_block (forward) + dm_block_input (input)            │
│  ├─ 规则: ether saddr/daddr @blocked_macs drop                  │
│  └─ 持久化: UCI blocked=1                                       │
│                                                                  │
│  限速功能:                                                       │
│  ├─ 主模式: tc (Traffic Control)                                │
│  │   ├─ HTB qdisc on br-lan                                     │
│  │   ├─ class_id = MAC哈希 (1-254)                              │
│  │   └─ filter: match ip src/dst                                │
│  ├─ 降级模式: nftables limit rate (pps)                         │
│  └─ 持久化: UCI rate_limit="1mbit"                              │
│                                                                  │
│  定时规则:                                                       │
│  ├─ 按分组生效                                                   │
│  ├─ 时间范围: start_time - end_time                             │
│  ├─ 生效日期: 周日-周六                                         │
│  └─ 操作: block 或 limit                                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 6. 设备合并（旋转MAC处理）

```
┌─────────────────────────────────────────────────────────────────┐
│                    设备合并功能                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  背景: Apple iOS 使用隐私MAC（随机MAC/LAA）                      │
│  每次连接可能使用不同MAC，导致出现多个"设备"                     │
│                                                                  │
│  合并流程:                                                       │
│  1. 用户选择多个设备卡片                                         │
│  2. 自动选择在线MAC作为主MAC                                     │
│  3. 其他MAC作为 alt_macs 存储                                    │
│  4. 继承最早设备的身份信息（名称、厂商、类型）                   │
│  5. 删除被合并的设备记录                                         │
│                                                                  │
│  在线判断:                                                       │
│  ├─ 主MAC在线 → 设备在线                                        │
│  └─ 任一alt_mac在线 → 设备在线                                  │
│                                                                  │
│  反向操作:                                                       │
│  └─ unmerge: 从alt_macs中移除，恢复为独立设备                   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 7. 双模式监控（资源优化）

```
┌─────────────────────────────────────────────────────────────────┐
│                    双模式监控                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  空闲模式 (idle):                                                │
│  ├─ 触发: 页面关闭/浏览器离开                                   │
│  ├─ 间隔: 5分钟                                                 │
│  ├─ 行为: 仅检测新设备，不启动流量监控                           │
│  └─ 目的: 节省资源，减少hostapd内存压力                          │
│                                                                  │
│  活跃模式 (active):                                              │
│  ├─ 触发: 页面打开/用户访问                                     │
│  ├─ 间隔: 30秒                                                  │
│  ├─ 行为: 完整检测 + 流量监控                                   │
│  └─ 超时: 15秒无活动自动切换idle                                │
│                                                                  │
│  模式文件: /tmp/dm_mode                                         │
│  活动标记: /tmp/dm_page_active                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## 三、数据流向图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              数据流向                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  DHCP事件 ──────▶ event_handler.sh ──────▶ UCI设备记录                      │
│      │                │                      │                              │
│      │                ├─ 7级识别             ├─ mac, vendor, type           │
│      │                ├─ 自动命名             ├─ name, hostname             │
│      │                └─ 同步dnsmasq          └─ discovered_at             │
│      │                                       │                              │
│  ARP表 ─────────▶ device_monitor.sh ─────▶ 缓存文件                        │
│      │                │                      │                              │
│      │                ├─ 新设备检测           ├─ /tmp/devicemaster_device_  │
│      │                ├─ 在线状态更新         │   cache                     │
│      │                └─ 子节点上报           ├─ /tmp/dm_snapshot.json      │
│      │                                       │                              │
│  前端请求 ──────▶ devicemaster.lua ──────▶ JSON响应                         │
│      │                │                      │                              │
│      │                ├─ api_status          ├─ 设备列表 + 在线状态         │
│      │                ├─ api_set_name        ├─ success/error               │
│      │                ├─ api_block           │                              │
│      │                ├─ api_limit           │                              │
│      │                └─ api_merge_devices   │                              │
│      │                                       │                              │
│  定时任务 ──────▶ schedule_executor.sh ───▶ 流量控制                        │
│      │                                       │                              │
│      │                                       │                              │
│  session.json ───▶ 在线时长统计 ──────────▶ 累计时间                        │
│      │                                       │                              │
│      └─ RAM存储，避免Flash频繁写入           └─ total_online_time          │
│                                                                              │
│  跨节点互传（第四轮重构，细节见 6.5）：                                      │
│    子节点 ──push 300s（含 node_ip / relayed）──▶ /api/report_sub             │
│           ──▶ /tmp/dm_child_reports.json ──▶ snapshot_writer 合并            │
│           ──▶ api_status 消费（设备归属）                                    │
│    子节点 ◀──pull 静态快照 /luci-static/resources/dm_snapshot.json（无认证） │
│    主节点 ──pull 仅对已上报节点（兜底），不再遍历子网内每台终端               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 四、外部联动

| 联动组件 | 用途 | 数据获取方式 |
|----------|------|--------------|
| dnsmasq | DHCP事件触发 | dhcpscript 配置 |
| nftables | 流量封禁 | 直接操作 |
| tc | 带宽限速 | 直接操作 |
| Bandix | 设备上行链路信息 | HTTP API |
| nlbwmon | 流量协议分析 | JSON输出 |
| avahi | mDNS探测 | avahi-resolve |
| ubus | 系统状态 | libubus-lua |

## 五、文件清单

| 文件 | 功能 |
|------|------|
| `devicemaster.lua` | API控制器（20+端点） |
| `devices.htm` | 设备列表页面 |
| `groups.js` | 分组配置页面 |
| `settings.lua` | OUI管理页面 |
| `device_monitor.sh` | 监控守护进程（idle/active 双模式） |
| `event_handler.sh` | DHCP事件处理 |
| `traffic_control.sh` | 封禁 / 限速（nftables + tc） |
| `oui_lookup.sh` | OUI查询模块 |
| `sync_hostname.sh` | 名称同步 |
| `schedule_executor.sh` | 定时规则执行 |
| `snapshot_writer.lua` | 主节点快照写入（cron 每分钟） |
| `sub_report_gen.lua` | 子节点报告生成（被 device_monitor 调用） |
| `init.d/devicemaster` | 服务启动脚本 |
| `uci_init.sh` | UCI 引导库（uci-defaults 与 init.d 共用） |
| `uninstall.sh` | 手动卸载清理脚本 |
| `etc/config/devicemaster` | 出厂配置（**只含注释，见 6.3**） |
| `etc/cron.d/devicemaster` | 三个 cron 任务 |
| `rpcd/acl.d/luci-app-devicemaster.json` | rpcd 权限 |

> 已删除（死代码，2026-09-28）：`device_collector.sh`(1677行)、`devicemasterd`(190行)、
> `traffic_monitor.sh`(137行)、`device_monitor.sh` 的 `write_sub_stations()`、`devicemaster.lua`
> 的 `create_snapshot()` 与 `api_report()`（后三项见 6.4）。依据见第七节。

## 六、已知问题与修复状态

### 6.1 原有记录

| 问题 | 严重程度 | 状态 | 说明 |
|------|----------|------|------|
| 命令注入风险 | 高 | ✅ 已处理 | MAC格式验证后才执行shell命令 |
| ARP正则匹配错误 | 高 | ✅ 已修复 | 跳过header行，过滤无效MAC |
| 变量作用域问题 | 高 | ✅ 已修复 | dhcp_ip_to_mac在api_status内定义 |
| hostname长度未限制 | 中 | ✅ 已修复 | 添加63字符限制(RFC 1035) |
| 限速单位解析不完整 | 中 | ✅ 已修复 | 添加G(gbit)单位支持 |
| 合并设备blocked继承 | 中 | ✅ 已修复 | 检查所有secondary的blocked状态 |
| 重复代码 | 低 | ⚠️ 待优化 | infer_vendor_from_hostname重复，建议后续统一 |

### 6.2 第二轮审查发现并修复

| # | 问题 | 严重程度 | 现象 / 影响 | 验证方式 | 修复 |
|---|------|----------|-------------|----------|------|
| 1 | `identify_type()` 引用未定义的 `$is_laa` | 高 | `[ "" -eq 1 ]` 报 `integer expected`；light 模式下 LAA 设备的 mDNS service 兜底分支**永不执行** | 直接复现报错 | 函数内计算 `is_laa`，并抽成统一实现 |
| 2 | tc classid 与 `htb default 10` 撞车 | 高 | `mac_to_class_id()` 输出 1..254 含 10；命中 10 的设备限速类成为**全 LAN 兜底类** | B/A 对比 + 1024 组合穷举：旧公式 4/1024（0.4%）命中 | 输出改为 11..254，常量 `HTB_DEFAULT_CLASS` 提取 |
| 3 | `write_sub_stations()` 的 `sep` 变量丢失 | 高 | ash 中 `... \| while read` 是子 shell，逗号计数器被丢弃，双 AP 网卡输出 `[{…}{…}]` **非法 JSON** | 用真实 JSON 解析器做 B/A：旧输出 `Expected ',' or ']'` | 改为先收集再让 awk 单遍输出逗号 |
| 4 | 出厂 `config device` 空模板节 | 高 | (a) 设备列表出现空白卡片；(b) 每次 api_status 触发 `sync_to_dnsmasq("")` → `grep -i "" /proc/net/arp` 匹配所有行 → 可能改写 `/tmp/dhcp.leases` 无关行并重启 dnsmasq；(c) init.d 的 `[ -z "$mac" ] && break` 让**封禁恢复 / session 读写全部提前退出** | 代码路径复现 | 清空出厂配置 + `dm_prune_template_sections()` 清理存量 + 三处循环改为按“节是否存在”判断 + `sync_to_dnsmasq` 拒绝非法 MAC |
| 5 | `uci-defaults` 永不执行 | 高 | 第 6 行 `[ ! -f /etc/config/devicemaster ]` 恒假（该文件随包安装），内置分组**从未创建** | — | 抽出 `uci_init.sh`，uci-defaults 与 init.d 共用同一幂等引导 |
| 6 | 设备编辑框分组下拉是硬编码中文标签 | 高 | 存的是“个人/IoT/访客/安全”，而控制器按分组 id 校验/筛选 → 分组功能端到端失效 | 代码路径复现 | 下拉改为从 `api/get_groups` 动态填充，并保留“未知分组”占位 |
| 7 | `api_get_groups` 返回 `.name` 而非 `id` | 高 | 内置分组的 id（phones）与匿名节名（cfg0a1b2c）不一致，前端匹配不到 | — | 返回 `s.id or s[".name"]`；内置分组改为**具名节** |
| 8 | `api_delete_group` 用 id 当节名删除 | 中 | id ≠ 节名时静默删不掉 | — | 先解析出真实节名再删除 |
| 9 | `response_cache` 实为无效缓存 | 中 | 变量是**逐请求重建**的 Lua local，CGI 下每次 3s 轮询都全量重算（注释宣称“eliminates ALL subprocess spawning”不成立） | 依据 LuCI 请求模型 | 改为 `/tmp` 文件缓存 + TTL + 变更接口失效 + `force=1` |
| 10 | `randomized` 判定 `% 2 == 2` | 中 | 恒为假，UI 从不标记随机 MAC，`api_report_sub` 同样误判 | 表达式求值 | 统一为 `is_random_mac()`（`% 2 == 1`） |
| 11 | OUI 缓存路径不一致 | 中 | 前端读 `/usr/share/.../oui_cache.txt`，shell 写 `/tmp/devicemaster_oui_cache.txt` → 计数恒为 0、清理按钮无效 | 代码路径复现 | shell 侧提供 `cache-file` 子命令，前端不再硬编码 |
| 12 | `oui_lookup.sh test_api` 用 `date +%s%N` | 低 | BusyBox date 不支持 `%N`，耗时数值错误 | — | 改用 `/proc/uptime` 单调毫秒时钟 |
| 13 | `device_monitor.sh` 只判断 PID 文件存在 | 中 | traffic_monitor 崩溃后 PID 文件残留，**永久不再重启** | — | 新增 `traffic_monitor_alive()`（`/proc/<pid>/cmdline` 校验，防 PID 复用） |
| 14 | settings 去重块会删掉具名 `settings` 节 | 中 | `@type[i]` 统计的是该类型**全部**节（含具名），`while uci get @settings[0]` 把用户配置一并删除，每次升级**重置 OUI 设置** | 用 mock uci 做“旧逻辑 vs 新逻辑”对照 | 只按 `uci show` 报告的匿名索引删除 |
| 15 | `dm_ensure_*` 每次启动都 `uci commit` | 中 | init.d 每次开机都写 Flash | mock 统计 commit 次数：稳态 0 次 | 引入 `dm_changed`/`dm_commit()`，仅在真改动时提交 |
| 16 | `postrm` 在**升级**时也执行破坏性清理 | 高 | `opkg upgrade` 会删掉 `/etc/config/devicemaster`、DHCP 主机项并重启 dnsmasq → 用户设备数据全丢 | 对照 OpenWrt postrm 约定（`$1` = remove/upgrade） | 仅 `$$1 = remove` 时清理；并修正 `$${IPKG_INSTROOT}` 转义（原来被 make 吃掉，守卫失效） |
| 17 | 未声明 `conffiles` | 高 | `luci.mk` 只复制 `root/`，不声明 conffiles → `opkg upgrade` 直接覆盖用户配置 | 核对 `luci.mk` 源码 | 新增 `Package/.../conffiles` = `/etc/config/devicemaster` |
| 18 | `bandix.general.port` 未校验 | 低 | 单引号拼接进 shell，UCI 值含引号可越界 | — | 增加 `^%d+$` 校验 |

> 注：第 13 项新增的 `traffic_monitor_alive()` 已随 `traffic_monitor.sh` 在第三轮一并删除 ——
> 该脚本不在调用链上，这项防护没有了对象。

### 6.3 第二轮记录但未处理（第三轮已全部结清）

| 问题 | 说明 | 第三轮结果 |
|------|------|-----------|
| `device_collector.sh`（1677 行）与 `devicemasterd` 不在调用链上 | `event_handler.sh` 只定义了 `COLLECTOR` 变量但从未调用；init.d 中 devicemasterd 的 procd 段被注释。二者合计约 2000 行死代码 | ✅ 已删除 |
| `api_status` 每次轮询都写 `/tmp/dm_mode=active` | 属既有设计（页面打开即 active） | 保留（设计如此） |
| `api_status` 仍用 `iwinfo assoclist` | `device_monitor.sh` 已改用 `iw station dump`；此处未同步 | ✅ 已改用 `iw`；`snapshot_writer.lua` 同类问题一并修（它每分钟执行，影响最大） |
| `api_report` / `api_report_sub` 对 `/tmp/dm_child_reports.json` 读改写无锁 | 并发上报可能丢失一次子节点数据 | ✅ 已加锁并加陈旧锁自愈；无锁的 `api_report` 已删除 |
| `groups.js` 使用已废弃的 `L.view.extend` | `view: View` 仍作为 `@deprecated` 别名存在 | ✅ 已改用 `view.extend` 并显式 `require view` |
| `groups.js` 读取 `/tmp/devicemaster_device_cache` | 该文件已不再生成 | ✅ 已移除该读取 |

### 6.4 第三轮审查（全面复审）发现并修复

判定方式：先做静态扫描（未定义变量、未注册接口、未使用函数、前后端字段契约、shell 拼接点），再逐段读完全部 14 个源文件（含此前未审计的 `event_handler.sh` 2758 行），最后对关键逻辑做**可复现的行为验证**（见"验证"列）。

| # | 问题 | 严重度 | 证据 / 复现 | 修复 |
|---|------|--------|------------|------|
| 1 | `snapshot_writer.lua` 把**远端可控**的 IP 拼进 `io.popen` 命令行 | 高 | `peer_ip` 取自 `snap.arp` / `snap.dhcp_leases`，而这两个表会合并子节点 POST 到**无认证**端点 `/api/report_sub` 的内容；随后进入 `curl ... 'http://<peer_ip>/...'`。子节点返回 `1.2.3.4'; <命令>; echo '` 即在本机每分钟执行 | 新增 `is_valid_ipv4()`（27 例注入/边界用例全过）；`api_report_sub` 侧同步过滤 `arp`/`dhcp_leases`，双层拦截 |
| 2 | `schedule_executor.sh` 在 **08:00 / 09:00** 直接报错中止 | 高 | POSIX 算术把前导零当八进制：`$((08 * 60))` → `value too great for base`，ash 中不可捕获，整个 cron 脚本中止；实测 `sh -c 'echo $((08 * 60))'` 复现 | 新增 `norm_num()`（去前导零）+ `is_valid_time()` 白名单；25 例用例全过（`08:00`→480、`09:00`→540） |
| 3 | 每分钟向 `/www` 写文件 = 每分钟一次 Flash 写 | 高 | `/www` 在 overlay 上；`snapshot_writer.lua` 每分钟写 `dm_snapshot.json`，即 1440 次/天/节点，与同一 cron 文件里"避开 Flash 磨损"的注释直接矛盾 | 真实文件移到 `/tmp`（tmpfs），`/www` 下改为符号链接（`init.d` 的 `dm_setup_web_links`，含目标播种与可读性校验） |
| 4 | `device_monitor.sh` 的 `write_sub_stations()` 产物**无任何消费者** | 中 | 全仓（含上级目录）grep `dm_sub_stations` 只有写入方；主节点拉取的是各节点的 `dm_snapshot.json`，真正上报走 `sub_report_gen.lua` + POST | 删除函数与调用；顺带消除子节点每 5 分钟的一次 Flash 写 |
| 5 | `register_device()` 用 `sleep 0.1` 做锁等待 | 中 | BusyBox `sleep` 不支持小数（OpenWrt 未开 FANCY_SLEEP），失败立即返回 → 50 次重试在毫秒内耗尽，锁等待实际失效 | 改 `usleep 100000 2>/dev/null \|\| sleep 1` |
| 6 | 三处 mkdir 锁在被 kill 后**不会自愈** | 中 | 进程被强杀时 `trap` 不执行，锁目录残留 → 后续注册/扫描/同步全失败（`sync_hostname.sh` 原逻辑是直接 `exit 1`，DHCP 名称同步会坏到重启为止） | `register_device`(30s)、`discover_all`(600s)、`sync_hostname`(30s，含等待) 均加 mtime 陈旧锁回收 |
| 7 | `sync_hostname.sh` 每次调用都无条件 `uci commit dhcp` | 中 | 该脚本被 `discover_all` / `reidentify_all` **逐设备**调用，绝大多数调用 `deleted=0`（什么都没删）却照样提交 | 改为 `deleted>0` 才提交 |
| 8 | DHCP 事件里无条件 `set last_ip` + `commit` | 中 | `main()` 每个 DHCP add 触发两次 Flash 写（`updated` 一次 + `last_ip` 一次），字段未变也写 | 仅当 IP 真的变化时写入并提交 |
| 9 | `event_handler.sh` 遗留两处 DEBUG 日志 | 低 | `arp_loop ...`、`sync check ...`，每个设备每次扫描各一条，长期污染 syslog | 删除 |
| 10 | `grep ... \| awk '{print $4}'` 缺提前退出（4 处） | 低 | dhcp.leases 出现多行匹配时 `hostname` 含换行 → 写入 UCI 会破坏配置文件 | 4 处改 `awk '{print $4; exit}'` |
| 11 | `register_device()` 用旧的前缀正则判断"无意义主机名" | 低 | 与 `is_meaningless_hostname()` 已修好的完整 MAC 匹配相矛盾，会把 `ab:cd:ef-server` 这类合法名误判 | 改为直接调用 `is_meaningless_hostname()` |
| 12 | `devicemaster.lua` ping 前未校验 `last_ip` | 低 | `sys.exec("ping -c 1 -W 1 " .. stored_ip ...)` 无引号拼接，缺纵深防御 | 加 `is_valid_ip()` |

**本轮验证**：10 个 shell `bash -n`/`sh -n` 全 OK；4 个 Lua `luaparse(5.1)` 全 OK；IPv4 校验 27/27、时间解析 25/25 用例通过；`iwinfo` 已无任何活调用（仅剩注释）。

**本轮记录但未改动（低危，留档）**

| 问题 | 说明 |
|------|------|
| `schedule_executor.sh` 的 `check_device_group()` 使用 `elif` 链 | 设备同时存在 `group` 与旧 `groups` 属性、且 `group` 指向的组名不匹配时，`groups` 分支被短路。现实中两属性并存的情况极少 |
| `score_add()` 用 `\|` 分隔字段 | DHCP hostname 若含 `\|` 会污染评分文件（影响打分，不影响安全） |
| `sync_hostname.sh` 的 `while [ $_alt_idx -lt 200 ]` | 硬编码 200 个设备上限，超过后 alt_mac 查不到 |

**需要在真机确认的一点**：`/www/luci-static/resources/dm_snapshot.json` 现在是符号链接，指向 `/tmp/dm_snapshot.json`。uhttpd 以 `open()` 直接服务该路径，正常应透明跟随；若某构建拒绝服务符号链接，子节点会取不到主节点快照（届时把 `dm_setup_web_links()` 改回直接写文件即可，一处改动）。


### 6.5 第四轮：跨节点互传链路重构

起点是把主/子节点的数据互传端到端对一遍。结论出乎意料：链路上有三条路径
（子→主 push、主→子 pull、子→拉主快照），其中**主→子 pull 的取数方式本身就是性能陷阱**，
而**子→主 push 上来的数据在主节点页面上没有任何消费者**。

#### 发现并修复

| # | 问题 | 严重度 | 证据 | 修复 |
|---|------|--------|------|------|
| 1 | 子节点上报的设备数据**在主节点上无人消费** | 高 | 全仓 grep `dm_child_reports`：写入方 `api_report_sub`、读取方只有 `snapshot_writer.lua`——而它把数据并进**快照**（供子节点拉走）。主节点页面唯一的取数函数 `api_status` 从不读该文件。数据绕了一圈回到子节点，母路由自己什么都看不到 | `api_status` 增加 master 分支消费该文件：`stations` → 归属、`devices`/`leases`/`arp` → 补全；输出新增 `node_mac`，设备卡片显示"接入: ⟨节点⟩" |
| 2 | 主→子 **对子网内每一台终端**轮询 | 高 | `snapshot_writer.lua` Step 2 遍历 `snap.fdb_macs`——mesh 端口上所有非本地 MAC，在桥接式 mesh 里等于**每个子节点下的每个终端**。对手机/打印机逐个发起串行 `curl`（connect-timeout 2 / max-time 4），而它们不运行本插件、不会返回 `dm_snapshot.json`。几十个 MAC 即超过 60s 的 cron 槽位 → 任务堆叠 | 候选改为"真正 push 过的节点"（`node_ip` 随报告上来）；FDB 仅作冷启动兜底且上限 4 个；请求**并行**（实测 3 路串行 4.46s → 并行 1.94s）；连续失败 3 次的 peer 退避 30 分钟 |
| 3 | 幽灵节点：上报记录**只写不删** | 高 | `known_peers` 与 `/tmp/dm_child_reports.json` 中的 `ts` 从不校验，文件只由重启清空。子节点一旦拔线/重置/重刷，其整份设备列表永久留在主节点 | 两侧统一按 `REPORT_TTL = 900s` 过期（子节点 push 间隔 300s，容忍连丢两次） |
| 4 | 多跳 mesh：下游节点的数据**丢失** | 中 | `push_to_master()` 推给 default gateway。若该网关是中间节点而非主节点，中间节点收到后只存进自己的 `/tmp`，**从不转发** → 2 跳外的设备在主节点不可见 | `sub_report_gen.lua` 携带 `relayed`（仅一层，上限 8 个，带 TTL 过滤）；主节点把它们当一级节点合并，深度上限由"只接受 `relayed`、不接受 `relayed[..].relayed`"保证 |
| 5 | 上报的 `stations` / `devices` **未做结构校验** | 中 | 原代码 `stations = data.stations or {}` 原样透传；`stations` 决定"设备归属哪个节点"并进入设备列表，`devices` 的字段在浏览器渲染 | 新增 `sanitize_stations()` / `sanitize_devices()`（MAC 白名单 + 字段长度/字符白名单） |
| 6 | 合并 N 个节点要取 N 次锁、做 N 次整文件读改写 | 中 | `merge_child_report()` 单节点一锁；中继一次要写多个节点，期间文件处于半合并状态供 `snapshot_writer` 读取 | 改为 `merge_child_reports(entries)`：单锁、单次读改写、原子替换 |
| 7 | 三份 `get_ap_ifaces()` 规则不一致 | 中 | `sub_report_gen.lua` 硬编码 `{"wl0-ap0","wl1-ap0"}` → 多 SSID（`wl0-ap1`）的客户端被漏报，主节点认为它们"不在这台节点上"；另两份用 `^wl` 前缀 + 排除 `mesh`，会匹配到 `wlan0` | 三处统一为 `-ap%d+$`（覆盖 `wl0-ap0` 与 OpenWrt 原生的 `phy0-ap0`），保留硬编码兜底；17/17 用例通过 |
| 8 | `brctl showmacs br-lan` 每个 tick 跑两次 | 低 | 一次用于定位 mesh 端口、一次用于收集其上的 MAC | 一次读入内存复用 |
| 9 | push 失败**完全静默** | 低 | `curl ... >/dev/null 2>&1` 且不检查返回值；互传断链时母路由上只会"看不到那台设备"，没有任何线索 | 记录一行有界的原因（截断 120 字符），`logread -t devicemaster-monitor` 可见 |

#### 互传定稿：push 上行 + 单点拉取

```
                    ┌──────────────── 主节点 (master) ────────────────┐
                    │ cron 1min: snapshot_writer.lua                   │
                    │   ├─ 读 /tmp/dm_child_reports.json  ◀── push ───┼──┐
                    │   ├─ 合并 stations/arp/leases/devices            │  │
                    │   └─ 写 /tmp/dm_snapshot.json (www 符号链接)     │  │
                    │ api_status: 消费 child_reports → 设备归属        │  │
                    └────────────────────────┬────────────────────────┘  │
                                             │ 拉快照 (静态 URL, 无认证)  │
                                             ▼                          │
                    ┌──────────────── 子节点 (sub / repeater) ────────┐  │
                    │ api_status: 拉主快照 → 全局视图                  │  │
                    │ device_monitor.sh 每 300s:                       │  │
                    │   sub_report_gen.lua ──▶ POST /api/report_sub ───┼──┘
                    │     └── relayed: 它收到的下游报告（多跳中继）     │
                    └────────────────────────┬────────────────────────┘
                                             │ 下游 node push 到它的 default gw
                                             ▼
                                      ┌── 更深一层节点 ──┐
```

要点：
- **上行（子 → 主）用 push**，携带 `node_mac` / `node_ip` / `role` / `relayed`；主节点由此既拿到数据，也**知道子节点的真实地址**（不再从 FDB 猜）。
- **主 → 子不再逐设备拉取**，只对"push 过的节点"补拉（push 失败的兜底），且在**逐节点**而非逐终端。
- **子 → 主快照仍用 pull**（`/luci-static/resources/dm_snapshot.json`，静态路径、零认证），这条不变。
- 归属信息（哪台设备挂在哪台节点）只有子节点知道，因此由 `stations` 上行，主节点不再自行猜测。

#### 验证

| 项 | 方式 | 结果 |
|----|------|------|
| 并行请求真的并行 | 与 `snapshot_writer` 相同的 `( cmd & cmd & wait )` 串，3 路各 sleep 1s | 串行 4.46s → **并行 1.94s**（本机 Windows 进程启动开销约 0.5s/次） |
| 空命令串的保护不是摆设 | 直接执行 `( & wait )` | 确认是 shell 语法错误 → `if #queue > 0` 守卫必要 |
| 候选选择 / 过期 / 退避 / 字段过滤 | node 复刻同一套纯逻辑，29 条用例 | **29/29 通过**（含"2 个 push 胜过 50 个 FDB 终端"、"冷启动上限 4"、"注入的 node_ip 被拒"、"3 次失败后退避 1800s"、"成功清零退避"） |
| 接口枚举规则 | `-ap\d+$` 对 17 个真实命名 | **17/17 通过**（`wl0-ap0`/`phy0-ap0` 命中，`wl1-mesh0`/`wlan0`/`br-lan`/`eth0` 不命中） |
| 语法 | 10 个 shell `sh -n`、4 个 Lua `luaparse(5.1)`、`devices.htm` 内联脚本 | 全 OK |

#### 记录但未改动（需真机确认）

| 项 | 说明 |
|----|------|
| `snapshot_writer.lua` 的 `role` 恒为 `"master"` | 子节点与中继节点也这样标。子节点侧正是用它判断"这是一份快照"（`parsed.role == "master"`），改成真实角色会**中断这条检查**（下游节点将不再接受中继节点的快照）。已保持常量并在源码注释中说明 |
| 子节点仍以 default gateway 作为主节点地址 | 中继机制使"推给上游"成为正确设计（链式上行），无需更改。代价是多跳场景下主节点看到最外层设备会晚 1 个 push 周期（≤600s），`REPORT_TTL = 900s` 留有余量 |
| 主节点改不动子节点上的设备名 | 归属信息已上行，但 `api_set_name` 写的是**本机 UCI**。对"only known via sub node"的设备改名，只改到主节点记录、不影响子节点。要真正下发需增加一条下行命令通道（本轮未做） |


### 6.6 第五轮：设备状态检测与厂商识别

审查对象是"设备状态怎么判、厂商怎么认"。两处结论修正了此前的猜测：**状态判定的
一个层级在 OpenWrt 上从未生效**，而**识别链最贵的两个探针在每个设备上重复执行**。

#### 发现并修复

| # | 问题 | 严重度 | 证据 | 修复 |
|---|------|--------|------|------|
| 1 | `ip neigh` 解析对字段顺序脆弱，`snapshot_writer.lua` 的该层**在 OpenWrt 上完全没生效** | 高 | BusyBox 源码 `networking/libiproute/ipneigh.c` 的 `print_neigh()`：<br>`if (!G_filter.index && r->ndm_ifindex)`<br>`    printf("dev %s ", ll_index_to_name(r->ndm_ifindex));`<br>`G_filter.index` 仅在传了 `dev <name>` 过滤时非零 → **裸 dump 会打印 `dev br-lan`，带 dev 过滤时不打印**。`snapshot_writer.lua` 用的是裸 `ip neigh show`（有 dev 字段），而 pattern 要求 IP 与 `lladdr` 相邻 → 一行都匹配不上；`controller` 用 `ip neigh show dev br-lan`（无 dev 字段）反而恰好匹配 | 两处统一为：锚定 IP → 从行余下部分取 `lladdr` 的 MAC → 扫描已知 NUD 状态词 |
| 2 | 同一 pattern 还会把缓存信息 `used a/b/c` 当成状态 | 高 | `print_neigh()` 在状态前输出 `used <a>/<b>/<c>` 与 `router`/`proxy` 标志。原 pattern 取 MAC 之后第一个 token → `nud = "USED"`，不在任何白名单里 → 该设备**永不被判为在线** | 同上：状态按已知词表匹配（MAC 是 hex，不可能与之冲突——`STALE` 含 `S/T/L`，不是合法 hex 字符） |
| 3 | `api_status` 的 ping 探测**串行**，且队列里全是最可能离线的设备 | 高 | `for mac, ip in pairs(probe_macs) do sys.exec("ping -c 1 -W 1 " .. ip ...)`。`probe_macs` 收的是"ARP 还记着、但 `ip neigh` 无有效状态"的设备——即最可能已离线的那些，几乎每个都跑满 1s 超时。30 个陈旧 ARP 条目 = 该请求卡 30s，而设备页每隔几秒轮询一次 | 改为单次后台批次 + 逐文件读回（只有真回复才含 `ttl=`）。实测 8 探针：**串行 16s → 并行 5s**（本机约 1s/进程的 fork 开销已计入，BusyBox 上即 ≈1s） |
| 4 | mDNS 全量枚举**每设备重跑一次** | 中 | `mdns_service_hints()` 每次调用都执行 `avahi-browse -a -t -r -p`（全网服务枚举，约 20 个进程），而 `identify_vendor()` 与 `identify_type()` **各调一次** → 10 台设备 = 20 次完全相同的全网枚举 | 新增 `mdns_dump()`：枚举一次落 `/tmp`（TTL 300s），所有调用方复用 |
| 5 | `http_hints()` 的 7 个端口串行探测 | 中 | `for port in 80 443 8080 8443 8008 5000 5001; do wget -T 1 ...` —— 无监听时每个跑满 1s，最坏 7s/设备，且发生在 dnsmasq **同步等待**的识别链里 | 改为每端口一个后台任务。同时补回并行改写时丢掉的 `head -c 4096` 限流与换行分隔——**这一条是实测抓到的**：7 个无换行 banner 粘成一行，断言"7 个 body 全部收集"得 1 而非 7 |
| 6 | `lookup_oui_local()`（`event_handler.sh` 里的副本）只查 6 位 OUI | 中 | 与 `oui_lookup.sh` 已修的 9/7/6 不一致。这是权重 80 的**主路径**，MA-M/MA-S 记录永不可达 | 抽出 `oui_lookup_prefix()`，两处行为一致；补 `|` 终止符（否则 6 位前缀会吃掉 7/9 位记录） |
| 7 | `OUI_APPEND` 是**死分支** | 中 | `/usr/share/devicemaster/oui_append.txt` 全仓从不创建（只在卸载时 `rm`）；查询用 `cut -c1-8`（含冒号的 `AA:BB:CC`）去 grep tab 分隔的表，格式也对不上 | 做成真正可用的覆盖表，路径改到 `/etc/devicemaster/oui_append.txt`（`sysupgrade` 会保留；`/usr/share` 是只读 rootfs，写在那里的东西升级即丢）。格式 `PREFIX\|BRAND`，接受 6/7/9 位与任意分隔符；`oui_lookup.sh` 同步支持 |
| 8 | `*canon*` / `*hp*` 的宽匹配 | 低 | 字符串层面 `canonical` 确实含子串 `canon`，Ubuntu 主机可能被标成 Canon 打印机 | 锚定到硬件实际广播的形式（`ty=canon`、`canon `、`canon-`、`usb_mfg=hp`、`laserjet`…），并用测试固定住 |
| 9 | `ip neigh show dev br-lan` 每请求执行两次 | 低 | 一次用于填 IP（962 行）、一次用于读状态（993 行），命令完全相同 | 单次读取，产出 `neigh_by_mac` / `neigh_state` 两个视图 |

#### 新增的识别方案

| 信号 | 内容 | 为什么值得 |
|------|------|------------|
| `_device-info._tcp` 的 `model=` | Apple 在 TXT 里广播**具体机型**：`model=MacBookPro18,3`、`model=iPhone14,2` | 机型级识别。OUI 只能到注册公司，主机名只能靠猜 |
| `_companion-link._tcp` / `_airdrop._tcp` | Apple Continuity 专有服务 | 基本只有 iOS/macOS 会广播 |
| `_esphomelib._tcp`、`_shelly._tcp`、`_tasmota._tcp`、`_nanoleaf._tcp`、`_matter._tcp` | 服务名**就是固件名** | 确定性信号，而非端口推断 |
| `_rfb._tcp`、`_smb._tcp`、`_afpovertcp._tcp`、`_nfs._tcp` | 远程桌面与文件共享 | 只有完整计算机会广播这些 |
| `_rtsp._tcp`、`_onvif`、`_axis-video._tcp` | 摄像头/录像机协议 | 摄像头此前只能靠 hostname 猜 |
| HTTP 响应头 `Server:` | `GoAhead`→摄像头、`lighttpd`/`Boa`/`mini_httpd`→嵌入式、`IIS`→Windows | 设备首页常常是空 HTML 或一句跳转，响应头才有信息。用 `nc` 发 `HEAD`，零新依赖 |
| IEEE 注册名 → 消费品牌 | `Shenzhen Chuangwei-RGB Electronics`→Skyworth、`Beijing Xiaomi Mobile Software`→Xiaomi、`Hewlett Packard`→HP 等约 30 条 | OUI 库里存的是**法人名**。直接展示既难读，又会让同一品牌散成好几个"厂商"，破坏分组与厂商列 |
| 扩展 mDNS 厂商表 | Hikvision / Dahua / EZVIZ / Aqara / Yeelight / Tuya / TP-Link / MikroTik / Synology / QNAP | 这些在国内家庭网络里最常出现，此前全部落到 `Unknown` |

#### 验证

| 项 | 方式 | 结果 |
|----|------|------|
| 厂商归一化 | 从**源文件抽取**函数（非复制，避免与实现漂移）跑 25 条断言 | 25/25；含 3 条误伤守卫：`Canonical Ltd.` ≠ Canon、`INTELLIGENT TECHNOLOGY` ≠ Intel、未映射名原样透传 |
| OUI 前缀查找（event_handler） | 同上，17 条 | 全过；含"6 位前缀不得吃掉 7 位记录"与"overlay 优先于 IEEE 表" |
| OUI 前缀查找（oui_lookup） | 同上，8 条 | 8/8 |
| 新 mDNS 信号 | stub `mdns_dump`，13 条 | 全过；含 `_http._tcp` 不判 HP、`canonical=ubuntu` 不判 Canon |
| `http_hints` | stub `wget`/`nc`，11 条 | 全过；含 7 个 body + 3 个响应头**全部**进入缓存（证明批次不是"只剩最后一个写者"），两种注入载荷（`;` 与单引号逃逸）均未执行 |
| `ip neigh` 解析 | node 复刻，12 条，覆盖 6 种真实输出格式 | 全过；并对照旧 pattern 复现了两类失败（裸 dump 一行都匹配不上、`used` 被当成状态） |
| 并行 ping | 真实 shell + 8 个探针 stub | 串行 16s → 并行 5s；存活判定只命中真回复的 2 个；8 个结果文件齐全 |
| 语法 | 10 个 shell `sh -n` + 4 个 Lua `luaparse(5.1)` | 全 OK |

#### 记录但未改动

| 项 | 说明 |
|----|------|
| `wifi_type_hint()` 见到 `HE-MCS`/`VHT-MCS` 即判手机 | 新笔记本、新电视同样支持这些速率；权重仅 30，通常被 hostname/厂商压过 |
| `ttl_type_hint()` 按 TTL 区间推断类型 | macOS 同样用 64，与手机无法区分；权重 20，仅作兜底 |
| `score_add()` 用 `\|` 分隔字段 | 同 6.4 节。hostname 含 `\|` 会污染评分文件 |
| `is_laa_mac()` / `mac_to_class_id` 在多个脚本各有一份 | 行为一致但重复，合并需跨文件引用，收益有限 |


## 七、实际调用链与死代码（实测）

判定依据：全仓引用点 grep + 启动脚本实际内容（非文档描述）。

**在调用链上**

| 触发源 | 调用 |
|--------|------|
| dnsmasq `dhcpscript`（DHCP 租约事件） | `event_handler.sh` |
| `init.d/devicemaster` → procd | `device_monitor.sh`（idle 300s / active 30s） |
| cron 每分钟 | `schedule_executor.sh`、`snapshot_writer.lua` |
| cron 每 12 小时 | `init.d/devicemaster flush_session` |
| LuCI `api/get status` | 控制器内直接聚合（ARP + leases + iw/nlbwmon + UCI） |
| 子节点 → 主节点 | `api/report_sub`（`sub_report_gen.lua` 生成）、`api/snapshot` |

**不在调用链上（死代码，本轮已删除）**

| 文件 / 符号 | 规模 | 证据 |
|------|------|------|
| `device_collector.sh` | 1677 行 | 全仓仅 `event_handler.sh` 定义了 `COLLECTOR` 变量，**没有任何调用点**；文件末尾的 `[ "${0##*/}" = "device_collector.sh" ]` 主入口因此永不触发 |
| `devicemasterd` | 190 行 | `init.d/devicemaster` 中其 procd 段被注释掉，无其它启动点；只有 `uninstall.sh` 会 `killall` |
| `traffic_monitor.sh` | 137 行 | 唯一的启动方 `device_monitor.sh` 里相关调用已移除；其产物（`traffic.json`、`stats/*.json`、`rx_rate`/`tx_rate`）全仓无消费者 |
| `device_collector.sh` 同级：`create_snapshot()`（`devicemaster.lua`） | ~105 行 | 无调用者；快照实际由 `snapshot_writer.lua` 生成 |
| `api_report()`（`devicemaster.lua`） | ~30 行 | 无锁的重复端点，前端不调用、脚本只 POST `api/report_sub` |
| `write_sub_stations()`（`device_monitor.sh`） | ~48 行 | 产物 `/www/.../dm_sub_stations.json` 全仓无读取方 |

合计约 2200 行代码不在任何链路上，均已于本轮（第三轮）删除，同时清理了全部引用点（`init.d`、`uci-defaults`、`uninstall.sh`、`ARCHITECTURE.md`/`README.md`）。
开发前备份：`.workbuddy/backup/2026-09-28-pre-cleanup.tar.gz`（仓库无 git 历史可用）。
