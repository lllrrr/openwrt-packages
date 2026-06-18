# UPnP NAT Relay

**English** | [中文](README.md)

OpenWrt LuCI plugin for relaying downstream router UPnP mappings through upstream NAT, with nftables DNAT and OpenClash RETURN support.

## What It Does

In a dual-router (multi-NAT) setup, the downstream router can create UPnP port mappings for its LAN devices, but the upstream OpenWrt router does not know about these mappings. This plugin:

1. Reads real UPnP mappings from the downstream router's LAN side
2. Applies security filtering
3. Creates corresponding DNAT rules on the upstream OpenWrt
4. Optionally configures OpenClash RETURN rules to bypass transparent proxy
5. Automatically removes DNAT when downstream UPnP mappings disappear

This replaces the need for wide-range DMZ or manual port forwarding on the upstream router.

## Quick Start

### Compile

**Method 1: OpenWrt SDK (recommended)**

```sh
cd /path/to/openwrt-sdk

echo "src-git luci_app_upnp_nat_relay https://github.com/hello-yunshu/luci-app-upnp-nat-relay.git" >> feeds.conf.default
./scripts/feeds update luci_app_upnp_nat_relay
./scripts/feeds install luci-app-upnp-nat-relay

make menuconfig
make package/luci-app-upnp-nat-relay/compile V=s
```

**Method 2: Download pre-built from [Releases](https://github.com/hello-yunshu/luci-app-upnp-nat-relay/releases)**

CI automatically builds both `.ipk` (opkg) and `.apk` (apk) format packages on every push to main.

### Install

```sh
# OpenWrt 24.10 / 23.05 (opkg)
opkg install luci-app-upnp-nat-relay_*.ipk

# OpenWrt 25.12+ (apk)
apk add --allow-untrusted ./luci-app-upnp-nat-relay*.apk
```

When migrating from the old package name, remove `luci-app-upnp-bridge-relay` first, then install `luci-app-upnp-nat-relay`. The new package migrates `/etc/config/upnp_bridge_relay` to `/etc/config/upnp_nat_relay` during installation.

### Use

1. **LuCI Web UI**: Services → UPnP NAT Relay → Setup Wizard, follow the step-by-step guide
2. **CLI**:

```sh
# Check environment
upnp-nat-relay --check-env

# Dry run (read only, no rules written)
upnp-nat-relay --dry-run

# Full sync (create DNAT rules)
upnp-nat-relay --sync

# View status
upnp-nat-relay --status
```

## When to Use

- You have an upstream OpenWrt router and a downstream router (any brand)
- The downstream router has UPnP enabled for its LAN devices
- You want external access to reach devices behind the downstream router
- You want to expose only the ports that actually have UPnP mappings, not a wide port range

## When NOT to Use

- You only have a single router (no dual-NAT scenario)
- Your upstream router is not OpenWrt
- Your upstream OpenWrt uses fw3/iptables (fw4/nftables is required)
- You do not have a public IP on the upstream WAN (CGNAT cannot be bypassed)
- You want to expose low-privileged ports (22, 80, 443, etc.)

## Compatibility Matrix

| Tier | OpenWrt Version | Firewall | Package Manager | Status |
|------|----------------|----------|-----------------|--------|
| Tier 1 | 25.12.x | fw4 / nftables | apk | Recommended |
| Tier 2 | 24.10.x | fw4 / nftables | opkg | Supported |
| Experimental | 23.05.x | fw4 / nftables | opkg | Best-effort |
| Unsupported | Any | fw3 / iptables | Any | Not supported |

## Network Topology

```
Internet
  |
  +-- Upstream OpenWrt Router
  |     - WAN: public internet exit
  |     - LAN: connected to downstream router WAN
  |     - Extra interface: connected to downstream router LAN (for UPnP reading)
  |     - Runs firewall / NAT / OpenClash
  |
  +-- Downstream Router
  |     - WAN: connected to upstream OpenWrt LAN
  |     - LAN: UPnP enabled
  |     - e.g. Xiaomi, ASUS, OpenWrt, iKuai, etc.
  |
  +-- Downstream LAN Clients
        - NAS
        - Game consoles
        - PCs
        - Download devices
```

Example addresses:

```
Upstream OpenWrt LAN:       192.168.2.1/24
Downstream router WAN:      192.168.2.2

Downstream router LAN:      192.168.3.1/24
Upstream extra interface:   192.168.3.50/24  (for UPnP reading only)
```

Key forwarding principle: DNAT targets the **downstream router WAN IP** (192.168.2.2), not the downstream LAN client IP. The downstream router's own NAT/UPnP rules handle the second hop.

## How to Connect the Downstream Router

The upstream OpenWrt needs an **extra interface** connected to the downstream router's LAN side. This interface is **only for reading UPnP**, not for internet access.

**Important rules:**

- Do NOT set a default gateway on this interface
- Do NOT bridge this interface with the main LAN
- Do NOT configure this interface as a WAN exit

Example setup:

```
Interface name:  upnp_nat_lan
Device:          eth2
Protocol:        static
IP address:      192.168.3.50
Netmask:         255.255.255.0
Gateway:         (leave empty)
DNS:             (leave empty)
```

The plugin can auto-create this interface via the Setup Wizard, or you can configure it manually.

## Dependencies

| Package | Purpose |
|---------|---------|
| miniupnpc | Provides `upnpc` command to read downstream UPnP IGD mappings |
| nftables | Creates and manages the plugin's own nftables DNAT table |
| coreutils-timeout | Provides `timeout` limits for slow probe commands |
| flock | Provides file locking for sync tasks to avoid concurrent runs |
| uci | Reads/writes OpenWrt UCI configuration |
| ubus | LuCI status and action RPC interface |
| rpcd | LuCI backend RPC daemon |
| luci-base | LuCI web interface framework |

Install dependencies manually if needed:

OpenWrt 25.12+:

```sh
apk update
apk add miniupnpc nftables coreutils-timeout flock luci-base rpcd uci
```

OpenWrt 24.10 / 23.05:

```sh
opkg update
opkg install miniupnpc nftables coreutils-timeout flock luci-base rpcd uci
```

## LuCI Usage

After installation, navigate to **Services → UPnP NAT Relay** in LuCI. The interface provides 8 sub-pages:

### 1. Overview

Service status, last sync result, mapping counts, and action buttons (start, stop, sync now, clear rules).

### 2. Setup Wizard

Step-by-step guide to configure the plugin:
- Select the interface connected to the downstream LAN
- Fill in or auto-detect the interface IP
- Test ping and UPnP connectivity
- Configure the downstream router WAN IP
- Set allowed port ranges
- Configure OpenClash RETURN
- Enable the service

### 3. Settings

Service toggle, sync interval, log level, clear-on-stop, and other basic configuration.

### 4. Network

View and configure the reading interface and firewall zone. Detects misconfigurations such as default routes on the reading interface or incorrect zone settings.

### 5. Security

Configure allowed port ranges, denied port list, allowed protocols, and allowed internal subnets. Default: allow ports 40000-65535, deny well-known sensitive ports.

### 6. Mappings

Three tables showing:
- Raw UPnP mappings read from the downstream router
- Currently synced DNAT rules on the upstream router
- Rejected mappings with rejection reasons

### 7. OpenClash

OpenClash compatibility management:
- Detect if OpenClash is installed and running
- Show suggested RETURN rules
- Apply or remove RETURN rules
- Backup and restore OpenClash configuration

### 8. Diagnostics

Environment check, network connectivity test, recent logs, dependency status, and suggested fix commands.

## Interface & Zone Recommended Configuration

The reading interface should be in its own firewall zone with the following settings:

| Setting | Value | Reason |
|---------|-------|--------|
| input | ACCEPT | Allow OpenWrt to reach downstream LAN |
| output | ACCEPT | Allow responses from downstream LAN |
| forward | REJECT | Prevent this interface from participating in normal forwarding |
| masquerade | OFF | No NAT needed on this interface |
| mtu_fix | OFF | Not a WAN exit |

If the zone output is REJECT, you will get "Operation not permitted" when running `ping` or `upnpc` from the upstream router. The plugin can fix this automatically via the **Fix Zone** button.

## OpenClash Compatibility

When OpenClash is running on the upstream router, its transparent proxy rules may intercept DNAT-forwarded traffic. The plugin can add RETURN rules to OpenClash's access control to bypass this.

Three modes are available:

| Mode | Behavior |
|------|----------|
| **off** | Do not handle OpenClash at all |
| **prompt** (default) | Show the suggested RETURN rule but do not write it automatically |
| **auto** | Automatically write the RETURN rule to OpenClash configuration |

The default RETURN strategy is **per-mapping** (per_mapping): an independent RETURN rule is generated for each synced UPnP mapping, precisely matching the external port. Alternatively, the **port pool** (port_pool) strategy uses a single rule covering the downstream router WAN IP + allowed port range (e.g. `192.168.2.2 / 40000-65535 / TCP+UDP / RETURN`), which is stable and does not need frequent updates.

If automatic writing fails (unrecognized OpenClash config structure), the plugin will display manual configuration instructions with copyable text.

## Security Considerations

**This plugin exposes downstream UPnP mappings to the public internet.** Please take the following precautions:

- **Limit the port range**: Do not use `1-65535` as the allowed range. The default `40000-65535` is recommended.
- **Do not allow low-privileged ports**: Ports 0-1023 and well-known ports (22, 80, 443, 3389, etc.) are denied by default. Do not remove them from the deny list.
- **Do not set the reading interface as the default route**: This would route all traffic through the downstream router.
- **Do not bridge the reading interface into the main LAN**: This would create network loops or routing confusion.
- **Review rejected mappings**: Check the Mappings page for rejected entries and their reasons.
- **Verify your WAN IP type**: If your upstream WAN has a private/CGNAT IP, external access will not work even if DNAT rules are correct.

## Troubleshooting

### 1. No UPnP IGD Device Found

**Symptom**: `upnpc -m <bind_ip> -l` returns no devices.

**Solution**: Confirm that:
- The bind IP is on the downstream router's LAN subnet
- The downstream router has UPnP enabled
- The reading interface is connected to the downstream LAN

```sh
upnpc -m <bind_ip> -l
```

### 2. Bind IP Does Not Exist

**Symptom**: The configured bind_ip is not found on any local interface.

**Solution**: Check that the reading interface is up and has the correct IP:

```sh
ip addr
```

### 3. "Operation not permitted" When Pinging Downstream Gateway

**Symptom**: `ping 192.168.3.1` returns "Operation not permitted".

**Solution**: The reading interface's firewall zone likely has `output` set to REJECT. Change it to ACCEPT:

```sh
uci set firewall.@zone[N].output=ACCEPT
uci commit firewall
fw4 reload
```

Or use the **Fix Zone** button in the LuCI Network page.

### 4. Downstream Router WAN IP Unreachable

**Symptom**: Cannot ping the downstream router's WAN IP (e.g. 192.168.2.2).

**Solution**: Check the physical connection between the upstream LAN and the downstream WAN. Verify that the downstream router's WAN interface is up.

### 5. Port Synced but Not Accessible from the Internet

**Check the following**:

1. Does the upstream WAN have a public IP? (Check for CGNAT: 100.64.0.0/10)
2. Do the nftables DNAT rules exist? (`nft list table inet upnp_nat_relay`)
3. Is OpenClash intercepting the forwarded traffic?
4. Has an OpenClash RETURN rule been configured?
5. Does the downstream UPnP mapping still exist?
6. Does the downstream router's firewall allow the mapping?

## Project Boundaries

This plugin does **NOT**:

- Make a network without a public IP reachable from the internet
- Bypass ISP CGNAT
- Make UPnP itself secure
- Guarantee compatibility with all router brands
- Recommend opening low-privileged ports
- Recommend or perform bridging the reading interface into the main LAN
- Guarantee automatic recognition of all OpenClash version config structures

## Project Structure

```
package/luci-app-upnp-nat-relay/
├── Makefile                                    # Package definition and build rules
├── htdocs/luci-static/resources/
│   ├── upnp-nat-relay/
│   │   ├── upnp-nat-relay.css                  # Global styles
│   │   └── utils.js                            # Shared utility functions
│   └── view/upnp-nat-relay/
│       ├── overview.js                         # Dashboard overview
│       ├── wizard.js                           # Setup wizard
│       ├── settings.js                         # Basic settings
│       ├── network.js                          # Network & firewall
│       ├── security.js                         # Security filtering
│       ├── mappings.js                         # Mapping tables
│       ├── openclash.js                        # OpenClash compatibility
│       └── diagnostics.js                      # Diagnostics & rollback
├── po/                                         # Translation files
├── root/
│   ├── etc/
│   │   ├── config/upnp_nat_relay               # UCI configuration
│   │   └── init.d/upnp_nat_relay               # procd service script
│   └── usr/
│       ├── bin/upnp-nat-relay                  # Core business script
│       ├── libexec/rpcd/upnp_nat_relay         # RPC backend (23 API methods)
│       └── share/
│           ├── luci/menu.d/                    # LuCI menu registration
│           └── rpcd/acl.d/                     # RPC access control
```

## Architecture

```
┌──────────────┐     ubus/rpcd     ┌──────────────────┐     UCI      ┌──────────────┐
│  LuCI Frontend│ ──────────────→  │  rpcd Backend     │ ──────────→ │  UCI Config   │
│  (8 JS views) │ ←──────────────  │  (23 API methods) │ ←──────────  │  upnp_nat_relay│
└──────────────┘     JSON response └──────────────────┘              └──────┬───────┘
                                                                            │
                                                              upnp-nat-relay
                                                                            │
                                                                   ┌────────▼────────┐
                                                                   │  nftables DNAT   │
                                                                   │  + OpenClash rules│
                                                                   └────────┬────────┘
                                                                            │
                                                              Read UPnP → Filter → Create rules
```

**Data Flow**:

1. Frontend calls rpcd backend via `ubus call upnp_nat_relay <method>`
2. Backend invokes `upnp-nat-relay` to execute operations
3. Daemon auto-syncs UPnP mappings at configured intervals
4. Sync results are written to status files in `/tmp/upnp_nat_relay/`
5. Logs are written to `/tmp/upnp_nat_relay/upnp-nat-relay.log`

## UCI Configuration Reference

### service section (main)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | 0 | Enable auto-sync |
| `interval` | integer | 60 | Sync interval (seconds) |
| `backend` | string | `upnpc` | UPnP backend |
| `bind_ifname` | string | `eth2` | Bind interface name |
| `bind_ip` | string | `192.168.3.50` | Bind IP |
| `downstream_lan_gateway` | string | `192.168.3.1` | Downstream LAN gateway |
| `downstream_lan_subnet` | string | `192.168.3.0/24` | Downstream LAN subnet |
| `downstream_wan_ip` | string | `192.168.2.2` | Downstream WAN IP |
| `upstream_wan_if` | string | `pppoe-wan` | Upstream WAN interface |
| `show_advanced_config` | boolean | 0 | Show advanced configuration |
| `auto_config_network` | boolean | 0 | Auto-configure network |
| `auto_config_firewall_zone` | boolean | 0 | Auto-configure firewall zone |
| `firewall_zone_name` | string | `upnp_nat` | Firewall zone name |
| `allowed_external_ports` | string | `40000-65535` | Allowed external port range |
| `protocols` | string | `tcp udp` | Allowed protocols |
| `failure_grace_count` | integer | 3 | Failure grace count |
| `clear_on_stop` | boolean | 1 | Clear rules on stop |
| `dry_run` | boolean | 0 | Dry-run mode |
| `log_level` | string | `info` | Log level |
| `deny_low_ports` | boolean | 1 | Deny privileged ports |
| `restrict_to_subnet` | boolean | 1 | Restrict to subnet |
| `deny_empty_description` | boolean | 0 | Deny mappings with empty description |
| `log_rejected` | boolean | 1 | Log rejected mappings |
| `openclash_mode` | enum | `prompt` | OpenClash mode: `off` / `prompt` / `auto` |
| `openclash_return_strategy` | enum | `per_mapping` | RETURN strategy: `per_mapping` / `port_pool` |
| `openclash_backup` | boolean | 1 | OpenClash config backup |
| `openclash_rule_remark` | string | `UPnP NAT Relay Auto RETURN` | OpenClash rule remark |
| `openclash_auto_restart` | boolean | 0 | OpenClash auto-restart |
| `openclash_sync_interval` | integer | 0 | OpenClash sync interval (0=follow main sync) |

### deny_ports section (default)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | list | 22,23,25,53,80,110,143,443,445,465,587,993,995,1433,3306,3389,5432,6379,8080,8443 | Denied port list |

### backend section (upnpc)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | 1 | Enable |
| `command` | string | `upnpc` | Backend command |
| `timeout` | integer | 10 | Timeout (seconds) |

### backend section (custom)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | 0 | Enable |
| `command` | string | — | Custom backend command |
| `output_format` | string | `json` | Output format |

## Command Line Reference

```sh
# Environment and dependency check
upnp-nat-relay --check-env

# Network connectivity check
upnp-nat-relay --check-network

# Read network cache
upnp-nat-relay --network-cache

# Dry run: read and filter mappings without writing nftables
upnp-nat-relay --dry-run

# Full sync: read, filter, and create DNAT rules
upnp-nat-relay --sync

# Generate OpenClash RETURN rule
upnp-nat-relay --generate-openclash-rule

# Read OpenClash rule cache
upnp-nat-relay --openclash-rule-cache

# Clear all plugin nftables rules
upnp-nat-relay --clear

# Show current status
upnp-nat-relay --status

# Refresh environment info
upnp-nat-relay --refresh-env

# Dump current UPnP mappings from downstream router
upnp-nat-relay --dump-mappings

# Auto-create the reading network interface
upnp-nat-relay --setup-interface

# Fix or create the firewall zone
upnp-nat-relay --fix-zone

# Apply OpenClash RETURN rule
upnp-nat-relay --setup-openclash

# Restart OpenClash service
upnp-nat-relay --restart-openclash

# Remove plugin's OpenClash RETURN rule
upnp-nat-relay --remove-openclash-rule

# Sync OpenClash rules
upnp-nat-relay --sync-openclash

# Rollback all plugin-created configurations
upnp-nat-relay --rollback

# Read log
upnp-nat-relay --read-log

# Clear log
upnp-nat-relay --clear-log

# Run as daemon
upnp-nat-relay --daemon
```

## License

GPLv3 License. See [LICENSE](LICENSE) for details.
