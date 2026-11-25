# luci-app-wechatpush-pro

An OpenWrt notification package that pushes client online/offline events, WAN IP changes, router status, abnormal traffic and security events to WeChat, WeCom, Telegram, email or a custom API.

This repository is a customized fork of [tty228/luci-app-wechatpush-pro](https://github.com/tty228/luci-app-wechatpush-pro). The package name, repository name and LuCI menu entry are now **luci-app-wechatpush-pro**. The default traffic source is **ctstat**, with wrtbwmon and OAF still available.

## Features

- Client online/offline notifications with per-client cumulative download and upload traffic
- IPv4 / IPv6 address change pushes
- CPU load, temperature, memory, disk and PVE host monitoring
- Scheduled router status and online client list pushes
- Web / SSH login alerts, automatic IP blocking and port knocking
- Unattended tasks: scheduled reboot, PPPoE reconnection, device aliases and quiet hours

## Notification channels

| Channel | Backend |
| --- | --- |
| WeChat | ServerChan, PushPlus, WPUSH, WxPusher |
| WeCom | Work WeChat app messages (text / markdown / mpnews) |
| Telegram | Bot API |
| Email | msmtp |
| Custom | User-defined API JSON templates |

## Installation

Releases ship both package formats:

| File | Target |
| --- | --- |
| `luci-app-wechatpush-pro_1.2-r2_all.ipk` | OpenWrt 19.07 – 24.10 (opkg) |
| `luci-app-wechatpush-pro-1.2-r2.apk` | OpenWrt 25.12+ (apk) |
| `luci-i18n-wechatpush-pro-zh-cn_1.2-r2_all.ipk` / `.apk` | Simplified Chinese translations |
| `luci-i18n-wechatpush-pro-zh-tw_1.2-r2_all.ipk` / `.apk` | Traditional Chinese translations |

```sh
# opkg
opkg update
opkg install luci-app-wechatpush-pro_1.2-r2_all.ipk
opkg install luci-i18n-wechatpush-pro-zh-cn_1.2-r2_all.ipk   # simplified, if needed
opkg install luci-i18n-wechatpush-pro-zh-tw_1.2-r2_all.ipk   # traditional, if needed

# apk
apk add --allow-untrusted luci-app-wechatpush-pro-1.2-r2.apk
apk add --allow-untrusted luci-i18n-wechatpush-pro-zh-cn-1.2-r2.apk  # simplified, if needed
apk add --allow-untrusted luci-i18n-wechatpush-pro-zh-tw-1.2-r2.apk  # traditional, if needed
```

Base dependencies: `iputils-arping`, `curl`, `jq`, `bash`, `luci-lua-runtime`.
Optional build-time dependencies: wrtbwmon (only for the wrtbwmon traffic source), lsblk / smartmontools (disk information), openssh-client / openssh-keygen (host information).

After installation, open **Services → WeChat Push-pro** in LuCI.

### Upgrading from 1.1 or earlier (remove the old package first)

Starting with 1.2-r1 every internal name is `wechatpush-pro`: init script `/etc/init.d/wechatpush-pro`, process name `wechatpush-pro`, config `/etc/config/wechatpush-pro`, data dir `/usr/share/wechatpush-pro/`, runtime dir `/tmp/wechatpush-pro/`.

**The package name changed (`luci-app-wechatpush` → `luci-app-wechatpush-pro`), so the package manager will not replace it, and this package does not migrate old settings. Treat it as a clean install:**

```sh
# opkg systems (OpenWrt 24.10 and older)
opkg remove luci-app-wechatpush luci-i18n-wechatpush-zh-cn luci-i18n-wechatpush-zh-tw

# apk systems (OpenWrt 25.12 and newer)
apk del luci-app-wechatpush luci-i18n-wechatpush-zh-cn luci-i18n-wechatpush-zh-tw
```

If you also had the older `luci-app-wechatpush-oaf`, remove it as well:

```sh
opkg remove luci-app-wechatpush-oaf luci-i18n-wechatpush-oaf-zh-cn luci-i18n-wechatpush-oaf-zh-tw
```

> **Old settings are not carried over.** `/etc/config/wechatpush` is a conffile and survives removal, but the new package never reads it; the old custom files (`diy.json`, `logo.jpg`, `ipv4.list`, `ipv6.list`, `device_aliases.list`, `ip_blacklist`, `usage_accum.db`) are not copied either. Re-enter what you need in the new UI, or back up `/usr/share/wechatpush/api/` before removing.
>
> After removal you may delete the leftovers (`/etc/config/wechatpush`, `/usr/share/wechatpush/`, `/etc/init.d/wechatpush`). Leaving them is harmless — the new package only uses the `*-pro` names and never collides with them.

## Traffic data sources

Select under **Basic Settings → Traffic Data Source**. Source-specific options appear below the selector.

### ctstat (default, recommended)

Calls `luci.ctstat.get_stats` over ubus and reads cumulative per-client download/upload byte counters from the ctstat daemon.

- Requires `luci-app-ctstat` to be installed and running.
- Works on conntrack / nftables, creates no iptables rules and coexists with firewall4.
- The online clients table shows **total download**, **total upload** and **total traffic** (download + upload) per client. In the scheduled client list, **Total Traffic** is likewise the sum of the two.
- Counters are cumulative since the ctstat daemon started; they restart when ctstat is restarted or reset.
- Clients without a known MAC are keyed by IP in ctstat. The plugin matches by both MAC and IP so the traffic columns are not lost.

Source-specific setting: **ctstat RPC timeout (seconds)** (default 5, range 1–30). Increase it on slow routers. A failed call keeps the last successful snapshot instead of zeroing traffic.

### wrtbwmon (original behavior)

Reads the `usage.db` produced by wrtbwmon. This source counts traffic via iptables and may conflict with Routing/NAT, Flow Offloading and proxy plugins; it also creates legacy iptables rule warnings on firewall4.

Source-specific setting: **wrtbwmon compatibility mode**.

- Auto: detect the command syntax from the package version
- Modern: `wrtbwmon -f` (1.2.0+)
- Legacy: `wrtbwmon update` (1.0.x)

### OAF / OpenAppFilter

Reads per-client traffic via `ubus call fwx common`. It creates no iptables rules. Requires `open-app-filter` / `luci-app-oaf` with traffic statistics enabled.

Source-specific settings:

- **OAF ubus API**: Auto / `get_user_stat` (all clients) / `get_daily_top_users` (top 8 only).
- **Accumulate Total Traffic Across Days**: OAF resets daily. The plugin keeps a baseline and adds the completed day to the cumulative total. Disable "Reset Traffic Data Every Day at Midnight" when using this option.
- If software/hardware flow offloading is enabled, OAF's netfilter hook may be bypassed and per-client traffic will be undercounted. Use ctstat in that case.

## Tips

- If a client hostname cannot be resolved, set an alias by MAC or IP, or install a Samba client for NetBIOS lookup.
- Active probing with ping/arping is used by default to detect sleeping Wi-Fi clients. Adjust timeouts or disable probing in Advanced Settings if needed.
- Automatic blocking only filters traffic to the router by default. Enable "block forwarded traffic for blacklisted IPs" to filter traffic passing through the router. On fw4, remaining ban time is restored from the last recorded value.
- Stopping the service does not immediately remove active firewall rules; they disappear on firewall reload/reboot and are restored by the next detection cycle while the service runs.

## Troubleshooting

Please include the following when reporting an issue:

- Device model, OpenWrt version, package version and selected traffic source
- Direct output of `/usr/share/wechatpush-pro/wechatpush-pro`
- `/tmp/wechatpush-pro/wechatpush-pro.log` and `/tmp/wechatpush-pro/usage.db`
- Verbose logs from `bash -x /usr/share/wechatpush-pro/wechatpush-pro t1`

Useful checks:

```sh
ubus list | grep -E 'luci\.ctstat|fwx'
ubus call luci.ctstat get_stats '{}' | jq '.devices | length'
cat /tmp/wechatpush-pro/usage.db
/etc/init.d/wechatpush-pro restart
```

## License

GPL-2.0-or-later. Upstream project maintained by tty228; this fork provides customization and package maintenance.
