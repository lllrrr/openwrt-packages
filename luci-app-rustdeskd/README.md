# luci-app-rustdeskd

[English](README.md) | [中文](README_zh.md)

**luci-app-rustdeskd** is a web interface for OpenWrt routers to manage your own **RustDesk Remote Desktop Server** (an open-source alternative to TeamViewer). By installing this plugin, you can easily turn your router into a private, self-hosted remote control server.

## Core Features

- **One-Click Core Installer**: No need for complex terminal commands. Download and update the official RustDesk server core (`hbbs` and `hbbr`) directly from the web UI.
- **Data Backup & Restore**: Fully integrates with OpenWrt's backup system. Easily backup and restore your encryption keys and database with a single click.
- **Visual Configuration**: Manage ports, keys, and view real-time service logs directly from the LuCI interface.

## Compilation (OpenWrt SDK)

```bash
# Enter your OpenWrt source directory
cd openwrt

# Clone the repository into the package directory
git clone https://github.com/permails/luci-app-rustdeskd.git package/luci-app-rustdeskd

# Update and install feeds
./scripts/feeds update -a
./scripts/feeds install -a

# Select the package in menuconfig
make menuconfig
# Navigate to: LuCI -> Applications -> luci-app-rustdeskd

# Compile the package
make package/luci-app-rustdeskd/compile V=s
```

## Acknowledgements

This project draws inspiration from [luci-app-rustdesk-server](https://github.com/superzjg/luci-app-rustdesk-server) by superzjg.
