# NetWiz (luci-app-netwiz) 🚀

![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05_|_25.x+-blue.svg) ![ImmortalWrt](https://img.shields.io/badge/ImmortalWrt-Supported-orange.svg) ![License](https://img.shields.io/badge/License-GPL--3.0-green.svg) ![Build](https://img.shields.io/badge/Build-Passing-brightgreen.svg)

---
### Description
`luci-app-netwiz` (Network Wizard) is a minimalist, safe, and non-destructive network configuration interface for OpenWrt/ImmortalWrt. 

It is designed to be highly user-friendly for novices setting up secondary routers (DHCP/Static IP) or bypass routers.

### Key Features
* **Pure CSR Architecture:** Built with modern Client-Side Rendering.
* **Safe Configuration:** Prevents routing loops and network conflicts (e.g., stops users from putting WAN and LAN in the same subnet).
* **Bypass Router Mode (旁路由):** Auto-configures DHCP and gateway settings safely.
* **Smooth UX:** Replaces traditional dirty hacks with standard `ubus call luci reload` to solve SPA cache issues without interrupting the user session.
* **Multi-language:** Built-in i18n support (English, zh-Hans, zh-Hant).
* **Strict ACL:** Frontend has zero direct write access to UCI. All modifications are safely encapsulated within the backend `rpcd` script.

### Breadcrumb Trail
* 👉 **System -> Network Wizard**。

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

### 💡 Execution Permissions Requirement (For GitHub Actions / Documentation)**

**Required Executable Permissions (chmod +x):**

To ensure the backend daemons and RPC interfaces function correctly, the following files must have executable permissions assigned before building the package:

```bash
chmod +x luci-app-netwiz/root/usr/libexec/rpcd/netwiz
chmod +x luci-app-netwiz/root/usr/libexec/netwiz-autodetect.sh
chmod +x luci-app-netwiz/root/usr/libexec/netwiz-monitor-loop.sh
chmod +x luci-app-netwiz/root/etc/init.d/netwiz-monitor
chmod +x luci-app-netwiz/root/etc/init.d/netwiz-recovery
```
---

```bash
luci-app-netwiz/
├── Makefile                          # standard Makefile (package definition, dependencies)
├── htdocs/
│   └── luci-static/
│       └── resources/
│           └── view/
│               └── netwiz.js         # Frontend UI (Async radar, dynamic stopwatch, JS logic)
├── po/
│   ├── zh_Hans/
│   │   └── netwiz.po                 # Simplified Chinese translation dictionary
│   └── zh_Hant/
│       └── netwiz.po                 # Traditional Chinese translation dictionary
└── root/
    ├── etc/
    │   ├── init.d/
    │   │   ├── netwiz-monitor        # Background daemon service for the monitor loop
    │   │   └── netwiz-recovery       # Power-loss auto-recovery service (START=15)
    │   └── share/
    │       └── rpcd/
    │           └── acl.d/
    │               └── luci-app-netwiz.json # RPC Access Control List (CRITICAL for frontend permissions)
    └── usr/
        ├── libexec/
        │   ├── netwiz-autodetect.sh  # WAN protocol auto-detection engine (DHCP/PPPoE)
        │   ├── netwiz-monitor-loop.sh# Core monitor daemon (Debounce, connection radar, rollback)
        │   └── rpcd/
        │       └── netwiz            # Backend RPC interface (receives UI commands, writes configs)
        └── share/
            └── luci/
                └── menu.d/
                    └── luci-app-netwiz.json # System menu definition (places Netwiz under "System")
```
---

<img width="680" alt="Image" src="https://github.com/user-attachments/assets/40905f7e-fa8b-4bc6-8bc8-846f81b3673c" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/7d056b14-9a88-4d0e-a0ea-2fae7a5f8233" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/2254dffb-bd82-40e0-9d58-0c9f90d60512" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/f2bd9091-2a1d-4b37-9104-3071dbf9d71a" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/01bbdd3a-ab4c-493f-adbd-09a5087f2de4" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/e02aefe9-51f8-4c15-8a93-932b48e4594d" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/52e42b52-11e3-4c61-87e6-17a689451be7" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/d55ff995-4e19-4fca-9059-60779777c4d9" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/a1593cdb-1384-4b78-af35-107fa7ed4f60" />
<img width="680" alt="Image" src="https://github.com/user-attachments/assets/6b3b6aeb-8ed0-4612-a187-c7d8a40b0d67" />

---
