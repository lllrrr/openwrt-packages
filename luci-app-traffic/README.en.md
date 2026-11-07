# luci-app-traffic

*A lightweight WAN traffic monitor for OpenWrt / LuCI*

[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-00B5E2)](https://openwrt.org)
[![LuCI](https://img.shields.io/badge/LuCI-JS%20API-1E90FF)](https://github.com/openwrt/luci)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[中文](README.md) | **English**

---

## Overview

A lightweight traffic monitor for a single WAN interface on OpenWrt. It reads the kernel interface counters from `/proc/net/dev` directly.

**It does not rely on conntrack**, so it keeps working with `flow offloading` enabled — something conntrack-based tools such as nlbwmon or vnstat2 cannot do (once a connection hits the flowtable, its conntrack byte counters stop updating).

## Features

- **6 time ranges**
  - `3 min` — 1-second sampling, optional live refresh
  - `1 hour` — per-minute curve
  - `1 day` — **hourly bars across a natural day 00:00–24:00**, switch between today / yesterday / the day before; the peak card is kept
  - `Last 30 days`
  - `Month` — full-month bars, step back through months
  - `Year` — fixed 12 columns (Jan–Dec), with year switching
- **Five-layer downsampling** across tmpfs and flash, aggregated at **real clock boundaries**
- **Minute-level durability** — the 1-day data is flushed to flash every minute, so a power cut loses at most 1 minute
- **Peak = the highest 1-second rate** within the window (down and up separately), not "total ÷ duration"
- **Tiered freshness** — `This month` / `Last 30 days` include today's live data and grow **hourly**; `Year` grows **daily**
- **Pure SVG frontend** — no CDN, no external dependencies, follows the system dark / light theme
- **Safe upgrades** — code-only overwrite, pre-upgrade data snapshot, format version guard, automatic rollback on data loss
- **Low overhead** — ~1.3 % CPU, ~1.1 MB RAM, roughly 150 MB flash writes per year (the price of minute-level durability)

## Data layers

| Layer | Interval | Rows | Coverage | Storage | Used by |
|---|---|---|---|---|---|
| L1 | 1 s | 180 | 3 min | tmpfs (RAM) | 3-minute view |
| L2 | 60 s | 60 | 1 hour | tmpfs (RAM) | 1-hour view |
| L3 | **60 s** | **4320** | **3 days** | flash | 1-day view; source for daily rollup |
| L4 | 1 day | 93 | about 3 months | flash | Last 30 days / month view |
| L5 | 1 month | forever | unlimited | flash | Year view |

> **Retention**: minute layer 3 days, daily layer about 3 months (the month view goes back at most 3 months); the monthly rollup is kept long-term for the year view.

Record format (CSV):

```text
ts,dn_rate,up_rate,dn_bytes,up_bytes[,dn_peak,up_peak]
```

- **Fields 6/7** hold the highest 1-second rate within that period; older 5-field rows fall back to the average
- **L1 / L2 / L3** store **cumulative bytes**; traffic is derived from the difference between consecutive rows
- **L4 / L5** store **per-period deltas**, so every row is self-contained and a single row still renders correctly
- When a cumulative counter **wraps** (interface reconnect or reboot resets it), the delta is taken as the current value instead, so totals never go negative

## Aggregation timing

No internal tick counter — aggregation is driven by **real clock boundaries**:

- **Every minute** → the newest L2 row is mirrored to L3 on flash (so a power cut costs at most 1 minute)
- **Every day boundary** → the last 24 hours of L3 is rolled up into one L4 row, and the previous month is settled into L5 at month change

As a result, **restarting the daemon never breaks the recording rhythm**.

In the 1-day view, each hourly point's rate is **that hour's accumulated traffic ÷ 3600 s**. It starts small right after the hour begins and rises as minutes accumulate, reaching the true hourly average once the hour completes — which avoids the artificial spike caused by dividing by a handful of elapsed minutes.

> Aggregation uses a **time-window filter** (rows selected by timestamp) instead of a fixed "last N rows", so stale rows left over from before a restart are excluded automatically and cannot skew the averages.

#### Timezone

Hour / day / month boundaries depend on a timezone, configured via the UCI option `traffic.main.timezone` (a POSIX timezone string, default `CST-8`).

This setting **only affects boundary detection, not the stored Unix timestamps**, and it does not change the system-wide timezone. It works without the `zoneinfo` package.

## Installation

#### Option 1 — manual deployment

```sh
scp -r root/.   root@192.168.1.1:/
scp -r htdocs/. root@192.168.1.1:/www/

ssh root@192.168.1.1 '
  chmod 755 /usr/sbin/trafficd.sh /etc/init.d/trafficd /www/cgi-bin/traffic
  /etc/init.d/trafficd enable
  /etc/init.d/trafficd start
  rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
  /etc/init.d/rpcd restart
  /etc/init.d/uhttpd restart
'
```

#### Option 2 — OpenWrt SDK / buildroot

Drop this repository under `package/` in your buildroot and run:

```sh
make package/luci-app-traffic/compile V=s
# output: bin/packages/*/base/luci-app-traffic_*.ipk
```

## Access

- **LuCI**: Status → Traffic Monitor
- **Direct**: `http://192.168.1.1/traffic/`

## Safe upgrades

`tools/traffic-upgrade.sh` enforces five hard guarantees:

1. Never deletes or truncates any `.dat` data file
2. Snapshots persistent data to `/etc/traffic/.backup/<timestamp>` before upgrading (keeps the latest 3)
3. Aborts when the data format version does not match, requiring an explicit migration — **never silently wipes data**
4. Compares row counts before and after; restores from the snapshot on any loss
5. **Restarts the collector only when its own code changed**, avoiding pointless resets of the aggregation counters

```sh
# preview what would happen
sh tools/traffic-upgrade.sh /path/to/new/package --dry-run

# apply
sh tools/traffic-upgrade.sh /path/to/new/package
```

## Layout

```text
root/                                   -> router root /
├── usr/sbin/trafficd.sh                collector daemon
├── etc/init.d/trafficd                 procd service
├── etc/uci-defaults/99-traffic         default config on first install
└── usr/share/luci|rpcd/...             menu and ACL

htdocs/                                 -> /www
├── cgi-bin/traffic                     JSON API
├── traffic/index.html                  pure-SVG frontend
└── luci-static/resources/view/traffic/main.js   LuCI embedded view

tools/traffic-upgrade.sh                safe upgrade script
```

## Limitations

- **Single interface only.** With flow offloading enabled, per-device / per-app accounting is not reliable, because conntrack stops updating once a connection enters the flowtable
- **History starts at install time**; traffic before installation cannot be recovered
- Day / month boundaries depend on the timezone setting
- `L3` keeps only 3 days, so the 1-day view can look back at most two days

## Compatibility

| Item | Version |
|---|---|
| Device | Xiaomi AX3000T V1 (MT7981B + MT7531) |
| System | OpenWrt 25.12.6 (apk) |
| Frontend | LuCI JS API |

Should work on any OpenWrt 21.02+ system using the **LuCI JS API**.

## License

[MIT](LICENSE)
