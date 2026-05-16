# 架构说明文档

## 整体架构

```
┌───────────────────────────────────────────────────────────────┐
│                        OpenWrt 路由器                          │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │               luci-app-qmodem-failover               │    │
│  │                                                      │    │
│  │  ┌─────────────────┐    ┌──────────────────────┐    │    │
│  │  │  LuCI Web 界面   │    │   守护进程(procd管理) │    │    │
│  │  │                 │    │                      │    │    │
│  │  │ controller.lua  │    │  qmodem-failover.sh  │    │    │
│  │  │ cbi model.lua   │◀───│  (主入口/配置加载)    │    │    │
│  │  │ status.js (轮询) │    └──────────┬───────────┘    │    │
│  │  └─────────────────┘               │                │    │
│  │                                    │ exec           │    │
│  │                         ┌──────────▼───────────┐    │    │
│  │                         │   wan-checker.sh      │    │    │
│  │                         │   (检测主循环)         │    │    │
│  │                         │                      │    │    │
│  │                         │  ① Ping 多目标        │    │    │
│  │                         │  ② HTTP 204检测       │    │    │
│  │                         │  ③ 物理链路检测        │    │    │
│  │                         └──────────┬───────────┘    │    │
│  │                                    │ 触发切换        │    │
│  │                         ┌──────────▼───────────┐    │    │
│  │                         │    switcher.sh        │    │    │
│  │                         │   (路由热切换)         │    │    │
│  │                         │                      │    │    │
│  │                         │  ip route metric修改  │    │    │
│  │                         │  DNS 切换            │    │    │
│  │                         │  防火墙重载           │    │    │
│  │                         └──────────┬───────────┘    │    │
│  │                                    │                │    │
│  │                         ┌──────────▼───────────┐    │    │
│  │                         │    notify.sh          │    │    │
│  │                         │   (可选通知)          │    │    │
│  │                         └──────────────────────┘    │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                               │
│  ┌─────────────────────┐    ┌────────────────────────────┐   │
│  │     有线 WAN (eth0)  │    │   QMODEM LTE (usb0/ppp0)  │   │
│  │   metric=10 (主路由) │    │   metric=100 (备用)        │   │
│  └─────────────────────┘    └────────────────────────────┘   │
└───────────────────────────────────────────────────────────────┘
```

## 状态机

```
              ┌─────────────────┐
    初始化     │                 │
    ──────────▶│   WAN 模式      │◀──────────────────┐
               │                 │                   │
               │  eth0: metric=10│  连续 M 次成功      │
               │  usb0: metric=100│                  │
               └────────┬────────┘                   │
                        │                            │
                   连续 N 次失败                    switcher.sh
                        │                         switch_to_wan
                        ▼                            │
               ┌─────────────────┐                   │
               │   LTE 模式      │───────────────────┘
               │                 │
               │  usb0: metric=5 │
               │  eth0: metric=100│
               └─────────────────┘
```

## 切换时序（故障切换）

```
t=0   WAN Ping 失败 (1/3)
t=3   WAN Ping 失败 (2/3)
t=6   WAN Ping 失败 (3/3) → 触发切换
t=6   ensure_lte_connected() → 检查 usb0 是否有 IP
t=7   ip route del default via WAN_GW dev eth0 metric 10
t=7   ip route add default via WAN_GW dev eth0 metric 100  (保留备用)
t=7   ip route add default via LTE_GW dev usb0 metric 5   (接管)
t=7   ip route flush cache
t=8   /etc/init.d/firewall reload (异步)
t=8   写入 /var/run/qmodem-failover/status: lte:时间戳
t=8   notify.sh "failover" (异步推送)
      ── 切换完成，总耗时约 8~12 秒 ──
```

## 切换时序（恢复回切）

```
t+0   LTE 模式下，开始检测 WAN
t+3   WAN Ping 成功 (1/5)
t+6   WAN Ping 成功 (2/5)
      ...
t+15  WAN Ping 成功 (5/5) → 触发回切
t+15  ip route add default via WAN_GW dev eth0 metric 10
t+15  ip route del default via LTE_GW dev usb0 metric 5
t+15  ip route add default via LTE_GW dev usb0 metric 100 (恢复备用)
t+15  写入 status: wan:时间戳
      ── 回切完成 ──
```

## 文件说明

| 文件 | 类型 | 作用 |
|------|------|------|
| `src/qmodem-failover.sh` | Shell | 主守护进程，加载 UCI 配置，调用检测模块 |
| `src/wan-checker.sh` | Shell | WAN 健康检测主循环，Ping + HTTP + 物理链路 |
| `src/switcher.sh` | Shell | 执行路由热切换，WAN↔LTE |
| `src/notify.sh` | Shell | Webhook 通知（钉钉/企业微信/飞书） |
| `src/qmodem-failover.init` | Shell | procd 服务管理脚本 |
| `src/qmodem-failover.config` | UCI | 默认配置模板 |
| `luasrc/controller/qmodem_failover.lua` | Lua | LuCI 路由 + REST API |
| `luasrc/model/cbi/qmodem_failover.lua` | Lua | LuCI 配置表单 |
| `htdocs/luci-static/qmodem_failover/status.js` | JS | 前端状态轮询 + 手动切换 |
| `po/zh-cn/qmodem_failover.po` | PO | 中文翻译 |
| `Makefile` | Make | OpenWrt 包构建规则 |
| `.github/workflows/build.yml` | YAML | GitHub Actions CI/CD |

## 关键设计决策

### 1. 为什么用路由 metric 而不是 ifdown/ifup？

- `ip route metric` 修改是原子操作，< 1ms 完成
- `ifdown/ifup` 会断开接口，触发防火墙重载，耗时 5~30 秒
- metric 方式保留两个接口同时 UP，WAN 恢复后路由立即可用

### 2. 为什么 success_threshold 默认比 fail_threshold 大？

- 故障切换要快（3次 × 3秒 = 9秒）
- 回切要稳（5次 × 3秒 = 15秒），避免 WAN 不稳定时来回抖动

### 3. 为什么用 procd 而不是 cron？

- procd 原生支持崩溃重启、配置变更自动 reload
- 检测需要秒级频率，cron 最小只支持分钟
- procd 与 OpenWrt 系统集成更好

### 4. 多重检测方式

优先级：物理链路检测 > Ping > HTTP 204 > DNS
- 物理链路检测：网线拔出立即感知（不需要网络包）
- Ping：最快最直接
- HTTP 204：应对某些运营商屏蔽 ICMP 的情况
- DNS：最后手段

