# FlowLens

[简体中文](README.zh-CN.md)

FlowLens is a LuCI application that turns OpenWrt into a clean, router-style
device traffic dashboard. It shows LAN devices, online/offline state, current
IPv4/IPv6 addresses, realtime per-device throughput, and current accounting
period totals in a React UI embedded inside LuCI.

The project is designed as a self-contained OpenWrt package: the router runs a
small rpcd shell backend and static LuCI assets, while React/Vite are only used
at development time to build the browser bundle.

## Features

- Online/offline device list with MAC address, IPv4, IPv6, and device name.
- Per-device realtime download and upload rates, always displayed in MB/s.
- Summary cards for online devices, offline devices, total download rate, and
  total upload rate.
- Search, status filters, sortable table headers, and responsive card layout.
- LuCI theme-aware UI with live dark/light mode switching.
- Current `nlbwmon` accounting period display, including date range.
- Conservative address selection:
  - IPv4 main display prefers the current DHCP lease.
  - IPv6 main display shows one useful address, preferring global addresses,
    then ULA, while hiding `fe80::` from the default view.
  - STALE neighbor entries and extra addresses are available in the address
    popover as historical/neighbor cache data.
  - FlowLens cache stores only the last main address for offline devices, so
    address lists do not grow forever.
- Stale offline cleanup: devices that are offline, not defined as static DHCP
  hosts, and have no observed traffic for `retain_days` are removed from the
  short-lived FlowLens cache. The default retention is 7 days.

## Data Sources

FlowLens intentionally uses low-risk OpenWrt data sources:

- `/tmp/dhcp.leases` for current DHCP IPv4 leases and host names.
- `/etc/config/dhcp` static host entries to keep configured devices visible
  even when they are offline and quiet.
- `/proc/net/arp` and `ip neigh show` for online presence and neighbor cache.
- `conntrack` for second-level live traffic deltas when available.
- `nlbwmon` for current accounting-period per-MAC counters and totals.
- `/tmp/run/flowlens` for short-lived local state used to calculate deltas and
  remember the last main address for offline devices.

The router runtime does not need Node.js, npm, Vite, or React packages.

## Runtime Configuration

`root/etc/config/flowlens` ships with:

```text
config flowlens 'main'
	option poll_interval '2'
	option retain_days '7'
```

`retain_days` controls stale cleanup for offline, non-static-DHCP devices that
have no observed traffic. Values below 1 or invalid values fall back to 7 days.

## Repository Layout

```text
.
├── Makefile
├── README.md
├── README.zh-CN.md
├── AGENTS.md
├── htdocs/
│   └── luci-static/resources/
│       ├── flowlens/dist/          # built React assets shipped with LuCI
│       └── view/flowlens/          # LuCI view entrypoint
├── root/
│   ├── etc/config/flowlens         # default UCI config
│   └── usr/
│       ├── libexec/rpcd/           # rpcd backend script
│       └── share/
│           ├── luci/menu.d/        # LuCI menu entry
│           └── rpcd/acl.d/         # ubus ACL
├── tests/                          # backend contract tests
└── web/                            # React/Vite source and frontend tests
```

## Requirements

For OpenWrt packaging:

- An OpenWrt/ImmortalWrt buildroot with the LuCI feed available.
- Runtime packages declared by the package Makefile:
  - `nlbwmon`
  - `ip-full`

For frontend development:

- Node.js with npm.
- Shell tools available on macOS/Linux for local tests.

## Build The OpenWrt Package

Place `luci-app-flowlens` in an OpenWrt package feed, then run from the
OpenWrt buildroot:

```sh
./scripts/feeds update luci
./scripts/feeds install luci-app-flowlens
make menuconfig
make package/luci-app-flowlens/compile V=s
```

Enable the package under LuCI applications if needed.

## Frontend Development

The checked-in LuCI package ships the built assets from:

```text
htdocs/luci-static/resources/flowlens/dist/
```

After changing files under `web/src`, rebuild the static bundle:

```sh
cd web
npm install
npm test
npm run build
```

The build writes:

```text
htdocs/luci-static/resources/flowlens/dist/flowlens-app.js
htdocs/luci-static/resources/flowlens/dist/flowlens-app.css
```

When changing the frontend bundle, also bump the matching cache-busting version
in:

- `web/src/main.jsx`
- `htdocs/luci-static/resources/view/flowlens/overview.js`

## Tests

Run frontend unit tests:

```sh
cd web
npm test
```

Run backend contract tests:

```sh
tests/test_rpc_devices.sh
```

Run syntax checks for shell and LuCI JavaScript:

```sh
sh -n root/usr/libexec/rpcd/luci.flowlens
node --check htdocs/luci-static/resources/view/flowlens/overview.js
```

## Development Install On A Router

For quick development on a live router, copy these files to the same absolute
paths on OpenWrt:

```text
/usr/libexec/rpcd/luci.flowlens
/www/luci-static/resources/view/flowlens/overview.js
/www/luci-static/resources/flowlens/dist/flowlens-app.js
/www/luci-static/resources/flowlens/dist/flowlens-app.css
```

Then restart services:

```sh
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

Open LuCI:

```text
Status -> FlowLens
```

If browser caching gets in the way during development, append a version query
parameter to the page URL, for example:

```text
/cgi-bin/luci/admin/status/flowlens?flowlens_v=0.1.23
```

## Notes

- On the first refresh, realtime rates may show `0.00 MB/s` until FlowLens has
  enough samples to calculate a delta.
- `nlbwmon` accounting totals reflect the current `nlbwmon` database period,
  not an all-time total.
- The rpcd backend is POSIX shell and BusyBox awk friendly. Avoid bash-specific
  syntax in router-side scripts.

## License

Apache-2.0
