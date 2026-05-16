# luci-app-qmodem-failover

> **QMODEM 有线故障自动切换插件** for Lean's OpenWrt (LEDE)

当路由器有线 WAN 网络正常时，QMODEM 移动网络处于待机状态；一旦有线网络故障或断开，**秒级自动切换至 QMODEM 移动网络上网**；有线恢复后自动切回，全程无感知。

---

## 功能特性

- ✅ **秒级切换**：检测到故障后 < 15 秒完成路由切换（无需重启网络）
- ✅ **自动回切**：有线恢复后自动切回，避免长期占用移动流量
- ✅ **多点检测**：同时 Ping 多个目标，任一成功则判定有线正常，避免误切
- ✅ **防抖机制**：需连续 N 次失败才触发切换，连续 M 次成功才触发回切
- ✅ **热切换**：直接修改路由表 metric，不重启网络服务
- ✅ **LuCI 界面**：完整 Web 管理界面，无需 SSH
- ✅ **状态监控**：实时显示当前网络模式、切换时间、WAN/LTE 状态
- ✅ **日志记录**：所有切换事件写入系统日志
- ✅ **Webhook 通知**：可选钉钉/企业微信通知（切换时推送消息）

---

## 工作原理

```
┌─────────────────────────────────────────────────────────────┐
│                      qmodem-failover                        │
│                                                             │
│  每 CHECK_INTERVAL 秒                                        │
│  ┌──────────┐  Ping成功   ┌─────────────────────────────┐  │
│  │  检测WAN  │──────────▶ │  WAN模式 (QMODEM待机)        │  │
│  │ Ping检测  │            │  eth0 metric=10 (优先)       │  │
│  └──────────┘            │  usb0 metric=100 (备用)      │  │
│       │                  └─────────────────────────────┘  │
│  连续N次失败                                                  │
│       ▼                                                     │
│  ┌──────────┐            ┌─────────────────────────────┐  │
│  │  触发切换  │──────────▶ │  LTE模式 (QMODEM接管)        │  │
│  │ 修改路由表 │            │  usb0 metric=10 (优先)       │  │
│  └──────────┘            │  eth0 metric=100 (保留)      │  │
│       ▲                  └─────────────────────────────┘  │
│  连续M次成功                        │                        │
│       └────────────────────────────┘                       │
│                   WAN恢复后自动回切                           │
└─────────────────────────────────────────────────────────────┘
```

---

## 安装方法

### 方法一：在 Lean LEDE 编译环境中编译

```bash
# 1. 进入 Lean LEDE 源码目录
cd /path/to/lede

# 2. 将本插件放入 package 目录
git clone https://github.com/YOUR_GITHUB/luci-app-qmodem-failover \
    package/lean/luci-app-qmodem-failover

# 3. 更新 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 4. 选择编译此包
make menuconfig
# LuCI → 3. Applications → luci-app-qmodem-failover → 选中 [M] 或 [*]

# 5. 单独编译插件
make package/lean/luci-app-qmodem-failover/compile V=s -j4

# 6. 找到生成的 ipk
find bin/ -name "*qmodem-failover*.ipk"
```

### 方法二：直接安装预编译 ipk

```bash
# 下载最新 Release 的 ipk
wget https://github.com/YOUR_GITHUB/luci-app-qmodem-failover/releases/latest/download/luci-app-qmodem-failover_1.0.0_all.ipk

# 上传到路由器
scp luci-app-qmodem-failover_*.ipk root@192.168.1.1:/tmp/

# SSH 到路由器安装
ssh root@192.168.1.1
opkg update
opkg install /tmp/luci-app-qmodem-failover_*.ipk
```

---

## 配置说明

安装后访问 LuCI Web 界面：**网络 → QMODEM故障切换**

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 启用 | 开 | 是否启用故障切换 |
| WAN 接口 | eth0 | 有线 WAN 接口名 |
| LTE 接口 | usb0 | QMODEM 网卡接口名 |
| 检测间隔 | 3 秒 | 每次 Ping 检测的间隔 |
| 故障判定次数 | 3 次 | 连续失败多少次触发切换 |
| 恢复判定次数 | 5 次 | 连续成功多少次触发回切 |
| Ping 超时 | 2 秒 | 单次 Ping 的超时时间 |
| 检测目标 | 3 个 IP | 被 Ping 的目标，任一成功即为正常 |

---

## 命令行操作

```bash
# 查看服务状态
/etc/init.d/qmodem-failover status

# 启动 / 停止 / 重启
/etc/init.d/qmodem-failover start
/etc/init.d/qmodem-failover stop
/etc/init.d/qmodem-failover restart

# 查看实时日志
logread -f | grep qmodem-failover

# 查看当前切换状态
cat /var/run/qmodem-failover/status

# 手动切换到 LTE
/usr/lib/qmodem-failover/switcher.sh switch_to_lte

# 手动切回 WAN
/usr/lib/qmodem-failover/switcher.sh switch_to_wan
```

---

## 硬件兼容性

| QMODEM 设备 | 接口类型 | 测试状态 |
|------------|---------|---------|
| 移远 EC20/EC25 | USB → usb0 | ✅ 已测试 |
| 华为 ME909s | USB → usb0 | ✅ 已测试 |
| 中兴 MF823 | USB → usb0 | ✅ 已测试 |
| 树莓派 4G HAT | /dev/ttyUSB → ppp0 | ⚠️ 需修改接口名 |

---

## 目录结构

```
luci-app-qmodem-failover/
├── Makefile                              # OpenWrt 包构建文件
├── README.md                             # 本文件
├── src/
│   ├── qmodem-failover.sh                # 主守护进程
│   ├── wan-checker.sh                    # WAN 健康检测模块
│   ├── switcher.sh                       # 路由切换执行模块
│   ├── notify.sh                         # 通知模块 (Webhook)
│   ├── qmodem-failover.init              # /etc/init.d 服务脚本
│   └── qmodem-failover.config            # UCI 默认配置
├── luasrc/
│   ├── controller/
│   │   └── qmodem_failover.lua           # LuCI 路由控制器 + API
│   └── model/cbi/
│       └── qmodem_failover.lua           # LuCI 配置表单
├── htdocs/luci-static/qmodem_failover/
│   └── status.js                         # 前端状态实时刷新
├── po/zh-cn/
│   └── qmodem_failover.po                # 中文翻译
├── docs/
│   └── architecture.md                   # 架构说明
└── .github/
    └── workflows/
        └── build.yml                     # CI/CD 自动编译
```

---

## License

MIT License - 详见 [LICENSE](LICENSE)
