# LuCI app for PortWeaver

This package provides a LuCI web interface for PortWeaver port forwarding configuration.

## Features

- Enable/disable PortWeaver service
- Configure global settings (log level)
- Manage port forwarding rules
- Support for TCP, UDP, and both protocols
- Simple and intuitive web interface

## Installation

Copy this package to OpenWrt SDK feeds/luci/applications/ directory and build with:

```bash
make package/luci-app-portweaver/compile
```

## Usage

After installation, access the web interface at:
**Services → PortWeaver**
