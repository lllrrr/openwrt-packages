# luci-app-sxray

LuCI support for Xray/Sing-Box, integrating features from both luci-app-v2ray and openwrt-passwall.

## Features

### Network Configuration
- **Inbound/Outbound Traffic**: Uses openwrt-passwall's node list configuration
- **Node Subscription**: Uses openwrt-passwall's subscription system
- **Complete Node Configuration**: Full passwall node configuration integration

### UI/UX Modules
- **Global Settings**: luci-app-v2ray implementation
- **DNS Configuration**: luci-app-v2ray implementation
- **Routing Configuration**: luci-app-v2ray implementation
- **Policy Configuration**: luci-app-v2ray implementation
- **Reverse Proxy**: luci-app-v2ray implementation
- **Transparent Proxy**: luci-app-v2ray implementation with iptables/nftables support
- **About**: luci-app-v2ray implementation

### Core Features
- **Dual Core Support**: Choose between Xray and Sing-Box
- **OpenWrt 24.10 Compatibility**: Full support for latest OpenWrt version
- **Firewall Backend Selection**: Manual choice between iptables and nftables
- **Full Protocol Support**: All network protocols from both Xray and Sing-Box

## Installation

### Building from Source

1. Clone this repository into your OpenWrt buildroot's package directory
2. Run `make menuconfig` and select `luci-app-sxray`
3. Build with `make package/luci-app-sxray/compile`

### Using Pre-built Packages

Download the ipk files and install using opkg:

```bash
opkg install luci-app-sxray_*.ipk
```

## Configuration

1. Navigate to `Services > SXray` in LuCI
2. Configure your preferred core type (Xray or Sing-Box)
3. Set up nodes using the node list or subscription
4. Configure global settings, DNS, routing, etc.
5. For transparent proxy, choose between iptables and nftables

## Project Structure

```
luci-app-sxray/
├── Makefile                 # OpenWrt package Makefile
├── luasrc/
│   ├── controller/
│   │   └── sxray.lua       # Main controller
│   ├── model/
│   │   ├── sxray.lua        # Core model
│   │   └── cbi/
│   │       └── sxray/       # CBI configuration modules
│   └── view/
│       └── sxray/           # View templates
├── root/
│   ├── etc/
│   │   ├── config/sxray     # Default configuration
│   │   ├── init.d/sxray     # Init script
│   │   └── uci-defaults/    # UCI defaults
│   └── usr/
└── po/                       # Translation files
```

## Credits

- [luci-app-v2ray](https://github.com/kuoruan/luci-app-v2ray) - UI/UX foundation
- [openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) - Node configuration system

## License

MIT License
