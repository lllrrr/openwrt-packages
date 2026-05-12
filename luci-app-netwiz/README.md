# NetWiz (luci-app-netwiz) 🚀

![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05_|_25.x+-blue.svg) ![ImmortalWrt](https://img.shields.io/badge/ImmortalWrt-Supported-orange.svg) ![License](https://img.shields.io/badge/License-GPL--3.0-green.svg) ![Build](https://img.shields.io/badge/Build-Passing-brightgreen.svg)

---
### Description
**NetWiz(luci-app-netwiz)** is a minimalist, safe, and non-destructive network configuration interface for OpenWrt/ImmortalWrt. 

minimalist and ready out of the box. Built with rigorous, well-structured logic, it features an enterprise-grade LAN fail-safe mechanism, intelligent WAN protocol switching, smart validation, and automatic conflict detection for IPs, gateways, WAN, and LAN interfaces. The front-end delivers a smooth, fluid user experience, eliminating the traditional frustrations of “errors after saving” and frequent configuration conflicts.

It is designed to be highly user-friendly for novices setting up secondary routers (DHCP/Static IP) or bypass routers.

### 🌟 Key Features

**🛡️ Enterprise-Grade Fail-Safes**
* **Persistent Power-Loss Recovery:** Backups are written to non-volatile flash (`/etc/config`). An early-boot `init.d` script guarantees an automatic network restoration even if the router loses power mid-test.
* **Smart Concurrency Radar (LAN Auto-Defuse):** The 120-second rollback bomb uses `netstat` to count concurrent connections, accurately distinguishing true browser access from background IoT probes to prevent false-positive defusals.
* **Smart WAN Auto-Detect (Anti-Jitter):** Features a time-based debounce algorithm that requires 3 continuous down-cycles to confirm a physical cable unplug, safely ignoring temporary software interface bounces.
* **Flash-Friendly Safe Logging:** Includes a persistent, auto-trimming logging system (`/etc/netwiz.log`) that survives reboots but strictly caps file size to protect the router's flash memory lifespan.

### 📶 Powerful Smart Wi-Fi Engine
* **Infinite Chip Array Detection:** Breaks the rigid limits of traditional single/dual-chip plugins. Automatically scans and takes over all physical wireless adapters in the system. Perfectly adapts to single-band, dual-band, tri-band, or even multi-band routers, ensuring no hardware is left idle.
* **Ultimate Low-Level Override:** Designed for incomplete, conflicting, or misconfigured underlying settings (e.g., a single chip stuck in 5G mode). Features an exclusive "Will Override Rule" that ignores residual hardware history, forcibly cleansing and rewriting the correct physical protocols and channels to guarantee a 100% successful application.
* **Smart Bandwidth Unleashed:** Say goodbye to crippled networks! When applying configurations, it intelligently identifies hardware limits and silently maximizes channel width (e.g., boosting 2.4G to HT40 and 5G to VHT80). It safely preserves existing Wi-Fi 6 (HE) configurations, ensuring effortless gigabit speeds.
* **Seamless Two-Way Data Sync:** When switching between "Smart Connect" and "Separate Bands", Wi-Fi passwords and SSIDs are intelligently synced back and forth, eliminating repetitive typing. Features historical config memory—retrieve your old password instantly even after disabling and re-enabling Wi-Fi.

**⚙️ Core Architecture & Security**
* **Zero-Zombie `procd` Daemon:** Replaces unreliable `hotplug` tricks with a single, ultra-lightweight native OpenWrt daemon (`netwiz-monitor`) that reads `ubus` states with near 0% CPU footprint.
* **Strict ACL:** The frontend has zero direct write access to UCI. All modifications are safely encapsulated and validated within the backend `rpcd` script.
* **Safe Configuration:** Strictly prevents routing loops and network conflicts (e.g., actively stops users from putting WAN and LAN in the same subnet).

**🚀 Smooth UX & Frontend**
* **Pure CSR Architecture:** Built with modern Client-Side Rendering for a blazing-fast, app-like experience.
* **Asynchronous UI & Hot-Reload:** Eliminates traditional blind wait times. The UI asynchronously "knocks" on the new IP with a real-time stopwatch. The backend applies changes via `reload` instead of a full `restart` to prevent Wi-Fi dropouts.
* **Bypass Router Mode:** One-click deployment that auto-configures complex DHCP, DNS, and gateway settings flawlessly.
* **Multi-language:** Native built-in i18n support, automatically adapting to English, zh-Hans, and zh-Hant.

### Breadcrumb Trail
* 👉 **primary menu entry appearing right before “Logout -> Network Wizard**。
  (Placing the Network Setup Wizard immediately before “Logout” is a deliberate UI decision that benefits both beginners and users seeking quick configuration. It offers a highly visible, easily accessible entry point, eliminating the need to navigate complex OpenWrt menus. Moreover, this layout aligns with the polished, user-centric design conventions adopted by established router brands such as ASUS, TP-Link, and Xiaomi.)

🌐 **Secondary Router Mode (DHCP / Static IP)**
   * Use Case: When the upstream modem (ONT) already handles PPPoE dialing, or an existing primary router is present. This device operates as a secondary router or segmented subnet router.
   * Behavior: Supports both dynamic IP assignment (DHCP) and static IP configuration. Automatically provisions WAN interface settings and performs intelligent subnet validation to prevent routing loops or address conflicts.

🔌 **Broadband Dial-Up (PPPoE)**
   * Use Case: When the modem is configured in full bridge mode and this router is responsible for establishing the PPPoE connection, acting as the primary network gateway.
   * Behavior: Accurately applies PPPoE credentials (username and password), removes residual gateway configurations, and safely restarts the underlying dialer process to ensure a clean connection.

🏠 **LAN Configuration (Primary / Bypass Router Switching)**
   * Use Case: For modifying the device’s LAN management IP, or when a primary router already exists and this device functions as an auxiliary gateway (bypass router).
   * Behavior: One-click activation of “Bypass Router Mode” automatically disables the local DHCP service and enforces manual configuration of the upstream gateway. In primary router mode, safeguards ensure the gateway field remains empty, preventing disruption to the existing LAN topology.

   A bypass router lets you add advanced features without touching the main network. The primary router keeps handling DHCP and NAT, while the bypass router processes selected traffic for tasks like policy routing or proxies. This keeps the network stable while giving you more control.

**A simple, common example:**
   
   * You have a main router providing Wi-Fi and DHCP for your home. You add a bypass router and set only your laptop’s gateway to it. Now, your laptop’s traffic goes through the bypass router (e.g., for proxy or special routing), while all other devices continue using the main router normally. This way, you get advanced control on one device without affecting the rest of the network.

📶 **Wi-Fi Settings（Auto-hide when Wi-Fi is unavailable.）**
* **Use Case**: Initial wireless network setup, or modifying the SSID, password, and encryption protocols for your whole-home network.
* **Behavior**: Intelligently detects the number of underlying physical chips to dynamically render the UI. Supports one-click "Smart Connect (All Bands)" to build a seamless roaming network, or splits into independent 2.4G/5G networks. Perfectly backwards compatible with legacy 802.11b IoT devices.

### 💡 Execution Permissions Requirement (For GitHub Actions / Documentation)**

**Required Executable Permissions (chmod +x):**

To ensure the backend daemons and RPC interfaces function correctly, the following files must have executable permissions assigned before building the package:

```bash
chmod +x luci-app-netwiz/root/usr/libexec/rpcd/netwiz
chmod +x luci-app-netwiz/root/usr/libexec/rpcd/netwiz_dev
chmod +x luci-app-netwiz/root/usr/libexec/netwiz-autodetect.sh
chmod +x luci-app-netwiz/root/usr/libexec/netwiz-monitor-loop.sh
chmod +x luci-app-netwiz/root/etc/init.d/netwiz-monitor
chmod +x luci-app-netwiz/root/etc/init.d/netwiz-recovery
chmod +x luci-app-netwiz/root/etc/hotplug.d/dhcp/99-netwiz-guard
```
---

```bash
luci-app-netwiz/
├── README.md                   # 项目说明书 (功能介绍、安装说明、更新日志)
├── LICENSE                     # 开源许可证
├── Makefile                    # OpenWrt 标准 Makefile (包定义、依赖关系)
│
├── htdocs/                     # 🌐 前端 UI 层 (纯静态资源)
│   └── luci-static/resources/view/
│       ├── netwiz.css          # 全局公共样式表 (弹窗、响应式、UI 美化)
│       ├── netwiz.js           # 前端核心 1：向导引擎 (网络大动脉配置、异步拨号)
│       └── netwiz_dev.js       # 前端核心 2：管家引擎 (设备雷达、智能分段、UI 交互)
│
├── po/                         # 🌍 多语言国际化
│   ├── zh_Hans/netwiz.po       # 简体中文翻译字典
│   └── zh_Hant/netwiz.po       # 繁体中文翻译字典
│
└── root/                       # ⚙️ 后端系统层 (打包时映射到路由器根目录 /)
    ├── etc/
    │   ├── config/
    │   │   └── netwiz          # 底层配置库 (保存向导状态、管家分组与设备活跃时间戳)
    │   │
    │   ├── init.d/             # [向导引擎 守护模块]
    │   │   ├── netwiz-monitor  # 常驻监视守护服务 (启动/停止监控引擎)
    │   │   └── netwiz-recovery # 断电自动恢复服务 (START=15，确保改网失败不失联)
    │   │
    │   └── hotplug.d/dhcp/     # 🛡️ [管家引擎 隐形守卫模块] (NEW!)
    │       └── 99-netwiz-guard # MAC 防伪装触发器 (基于事件驱动的微秒级拦截，零后台损耗)
    │
    └── usr/
        ├── libexec/
        │   ├── netwiz-autodetect.sh   # WAN 协议自动检测引擎
        │   ├── netwiz-monitor-loop.sh # 向导防抖与回退循环逻辑
        │   │
        │   └── rpcd/           # 🔌 RPC 接口层 (前后端数据通信桥梁)
        │       ├── netwiz      # 后端接口 1：向导专用 (处理底层网络协议修改)
        │       └── netwiz_dev  # 后端接口 2：管家专用 (ARP/DHCP存取、包含崩溃自救与静默清理机制) (UPDATED!)
        │
        └── share/
            ├── luci/menu.d/
            │   └── luci-app-netwiz.json # 系统菜单入口注册
            └── rpcd/acl.d/
                └── luci-app-netwiz.json # UBUS 权限控制列表 (授权前端访问后端接口)
```
---

<img width="680" alt="Image" src="https://github.com/user-attachments/assets/b2fca517-cbd2-4aa0-b557-bac5fd557dba" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/cce37944-d90a-4653-923c-d957812d8f37" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/8cae623d-766f-49a8-8c6c-ab78738d6b88" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/f0bd7bf8-16b7-4955-9a83-55673a7bf66e" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/ea664013-9f76-49e3-b10f-8307dbb6fc24" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/5c0370fc-efd9-4e51-be3c-ed35233786d6" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/bd4afb47-0dec-4606-91a3-da47e99ca6e0" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/51c10c7b-85df-4f69-b456-ea7523696ae5" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/8603b708-59c6-4a6d-b953-a83a26b00ef9" />

---
