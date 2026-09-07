<div align="center">

# WAN IP Selector

**Keep redialing until your public IP lands in a pool you actually want**

[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-00B5E2)](https://openwrt.org/)
[![LuCI](https://img.shields.io/badge/LuCI-JS%20view-ff8c00)](https://github.com/openwrt/luci)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Language](https://img.shields.io/badge/UI-%E4%B8%AD%20%2F%20EN-lightgrey)](#interface-language)

[简体中文](README.md) · English

</div>

---

## Introduction

Some ISPs hand out public addresses from several different pools, and those pools are **not equivalent** — which pool you land in directly affects international routing, peering, latency, and sometimes even NAT behaviour and MTU. Reconnecting gets you a different pool, but redialing by hand and checking the address every single time gets old fast.

WAN IP Selector automates it: after every dial it reads the interface address, compares it against the pools you configured, and redials until it lands on one you want.

It is **not tied to any particular ISP or country** — you supply the pools.

## Features

**Matching**

- Works with any logical interface (`wan`, `wan2`, PPPoE, DHCP), not just the default `wan`
- **Include mode** — only accept addresses inside the pools you list
- **Exclude mode** — accept anything else, to **dodge** a few bad pools
- Pools accept CIDR (`203.0.113.0/24`) or a bare prefix (`203.0.113.` / `203.0`), expanded to `/24` and `/16`
- Multiple entries; an empty list accepts any address

**Control**

- Attempt limit, retry delay, settle time and cooldown are all configurable
- Supports **unlimited retries** (`max_attempts = 0`) — keep dialing until it hits
- Two triggers: the **interface up event** (evaluated as soon as a dial completes) and a **background monitor** that polls on an interval
- The monitor exists because ISPs **rotate the address on their own**, usually every few days, and that does not always produce an interface event
- Manual buttons in LuCI as well

**Interface**

- LuCI page with a **live status panel**, refreshed every 5 seconds: current address, whether it matches, attempts so far
- Three buttons: redial now / check now / stop and clear the lock
- Chinese and English UI

**Implementation**

- Pure shell backend — no Python, no extra runtime, only `jsonfilter` which ships with OpenWrt
- About 20 KB installed
- Ships with 70 unit tests (28 for address matching, 42 for the translation compiler)

## Installation

Two packages are published, following the convention of the official LuCI feed:

| Package | Purpose |
|---|---|
| `luci-app-wanip-selector` | The application, English interface |
| `luci-i18n-wanip-selector-zh-cn` | Simplified Chinese interface |

### Option 1: download an ipk (recommended)

Grab them from [Releases](https://github.com/System32X-code/luci-app-wanip-selector/releases), then:

```sh
scp -P <port> luci-*-wanip-selector*_all.ipk root@<router>:/tmp/
ssh -p <port> root@<router> "opkg install /tmp/luci-app-wanip-selector_*.ipk /tmp/luci-i18n-wanip-selector-zh-cn_*.ipk"
```

The application package alone is enough if you want the English interface. You can also upload through **System → Software** in LuCI.

Reload the page (Ctrl+F5); the entry appears under **Network → WAN IP Selector**.

### Option 2: build the packages yourself

No OpenWrt SDK needed, just Python 3:

```sh
python3 tools/build-ipk.py
# dist/luci-app-wanip-selector_1.0.0-1_all.ipk
# dist/luci-i18n-wanip-selector-zh-cn_1.0.0-1_all.ipk
```

Translations are compiled by `tools/po2lmo.py`, a pure Python equivalent of the SDK's `po2lmo`. Its output is **byte for byte identical** to the official tool, verified against catalogues shipped in the firmware.

### Option 3: build inside an OpenWrt tree

```sh
git clone https://github.com/System32X-code/luci-app-wanip-selector.git package/luci-app-wanip-selector

make menuconfig               # LuCI -> Applications -> luci-app-wanip-selector
make package/luci-app-wanip-selector/compile V=s
```

## Usage

Open **Network → WAN IP Selector**.

### Status panel

The top of the page shows the current address, whether it matches, the attempt count and the run state, refreshed every 5 seconds. You can watch a redial round progress right there.

The three buttons ignore the master switch and always work:

| Button | Effect |
|---|---|
| Redial now | Start the redial loop immediately |
| Check now | Only evaluate the current address, no redial |
| Stop / clear lock | Interrupt the loop and release the lock (use it to reset after an abnormal exit) |

### General settings

| Setting | Description |
|---|---|
| Enable | Master switch. Nothing is redialed automatically while off, but the buttons still work |
| Interface | Logical interface to watch and redial; the dropdown lists interfaces from `/etc/config/network` |
| Match mode | Include (only pools listed) / Exclude (anything but the pools listed) |
| Address pools | Repeatable. CIDR or bare prefix. **An empty list accepts any address** |
| Max attempts | Give up after this many redials. **0 means never give up** |

### Monitoring

| Setting | Default | Description |
|---|---|---|
| Enable monitoring | off | Keep checking the address, not only when the link comes up |
| Check interval | 300 s | A few minutes is plenty; the address changes at most once every few days |

ISPs usually rotate the public address every few days on their own, and that
**does not always produce an interface up event**, so the hotplug trigger alone
would miss it. With monitoring on, the address is pulled back into your pools
as soon as it drifts out.

### Advanced settings

| Setting | Default | Description |
|---|---|---|
| Delay between attempts | 15 s | How long to wait between redials |
| Settle time | 8 s | How long to wait for an address after a redial; slow PPPoE links get an extra 30 s grace period |
| Cooldown | 600 s | Pause after hitting the attempt limit, so the ISP is not hammered |
| Verbose logging | on | Log every attempt to the system log |

### Prefix expansion

| You write | Interpreted as |
|---|---|
| `203.0.113.0/24` | `203.0.113.0/24` |
| `203.0.113.` | `203.0.113.0/24` |
| `203.0` | `203.0.0.0/16` |
| `203.` | `203.0.0.0/8` |

## Command line

```sh
wanip-selector check     # evaluate the current address, exit 0 when acceptable
wanip-selector status    # machine readable JSON state
wanip-selector run       # honour the master switch, redial until acceptable
wanip-selector force     # same, ignoring the master switch (manual trigger)
wanip-selector trigger   # start a round in the background and return at once
wanip-selector monitor   # run the periodic checker in the foreground (procd uses this)
wanip-selector stop      # abort a running loop, clear the lock, mark idle

/etc/init.d/wanip_selector {start|stop|reload|status|check|force}

logread -e wanip-selector    # what it has been doing
```

## How it works

```
interface comes up ─────┐          background monitor ───┐
   │ hotplug hook        │          every check_interval  │
   │ watched iface only  │          supervised by procd   │
   ▼                     ▼                               ▼
        /usr/sbin/wanip-selector   (setsid, the caller never blocks)
                          │
                          │  atomic mkdir lock, owner pid kept inside
                          │  held -> exit; owner gone -> reclaim stale lock
                          ▼
             read the address via ubus + jsonfilter
                          │
        ┌─────────────────┴─────────────────┐
     matches                            no match
        │                                   │
  write state, done         ifdown / ifup → wait → re-evaluate → repeat
                            until it matches, or the limit is hit, then cooldown
```

## Caveats

- **Redialing drops every connection.** If you administer the router remotely over this same WAN link, every attempt kicks you off.
- **`max attempts = 0` means no internet until a matching address shows up.** If your ISP never hands out that pool, the line stays down indefinitely. Prefer a finite limit unless you know the pool is common.
- **Frequent reconnects may trigger ISP rate limiting or a temporary block.** Keep the retry delay at a sensible value; the defaults are deliberately conservative.
- **IPv4 only.** IPv6 prefixes are not evaluated.
- Whether you can reach the pool you want depends entirely on the ISP's allocation policy. This package only makes trying cheaper — **it cannot create a possibility that was not there.**

## Compatibility

- OpenWrt **21.02** and newer, and derivatives (iStoreOS, ImmortalWrt, …)
- The LuCI JS (client side) view, default since 21.02
- Requires `jsonfilter` (part of a standard image)

## Interface language

LuCI follows the language you select under **System → Language and Style**. Chinese and English are provided.

## Contributing

Issues and pull requests are welcome.

If you run into an ISP that needs special handling — a different way to determine the address, or extra actions around the redial — please open an issue. That kind of requirement may deserve a configurable hook.

## Author

**System32X-code**

## License

[MIT](LICENSE)
