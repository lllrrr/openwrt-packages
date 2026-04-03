# luci-app-naived

NaiveProxy LuCI interface for OpenWrt

## Description

luci-app-naived is a LuCI-based configuration interface for NaiveProxy on OpenWrt. It provides a web-based UI to manage NaiveProxy client settings, server configurations, and proxy rules.

## Features

- Web-based configuration interface via LuCI
- Client configuration management
- Server list management
- Transparent proxy support (nftables)
- DNS proxy integration (ChinaDNS-NG, DNSproxy)
- Log viewing and management
- Backup and restore functionality

## Dependencies

- coreutils
- coreutils-base64
- dns2tcp
- dnsmasq-full
- jq
- ip-full
- lua
- libuci-lua
- microsocks
- tcping
- resolveip
- curl
- nping

Optional:
- chinadns-ng (for ChinaDNS-NG support)
- dnsproxy (for DNSproxy support)
- naiveproxy (for NaiveProxy binary)

## Installation

This package is part of the OpenWrt/LEDE ecosystem and can be built from source or installed via opkg:

```bash
opkg update
opkg install luci-app-naived
```

## Build from Source

Add to your OpenWrt feed and build:

```bash
# Add to feeds.conf
src-git naived https://github.com/kinmeic/luci-app-naived.git

# Update feeds and install
./scripts/feeds update naived
./scripts/feeds install luci-app-naived

# Build
make package/luci-app-naived/compile
```

## Configuration

After installation, access the web interface via LuCI at **Services > NaiveProxy** to configure:

- Client mode settings
- Server configurations
- Proxy rules and routing
- DNS settings
- Advanced options

## Files

- `luasrc/controller/naived.lua` - LuCI controller
- `luasrc/model/cbi/naived/` - Configuration models
- `luasrc/view/naived/` - View templates
- `root/etc/init.d/naived` - Init script
- `root/usr/bin/naived-*` - Helper scripts

## License

MIT License
