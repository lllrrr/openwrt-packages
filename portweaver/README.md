# OpenWrt PortWeaver Package

This package provides PortWeaver for OpenWrt, built with the Zig toolchain.

## Prerequisites

- OpenWrt SDK
- Zig compiler (will be downloaded automatically as build dependency)

## Building

1. Copy this package to your OpenWrt SDK feeds:
   ```bash
   cp -r openwrt-portweaver <SDK_PATH>/package/network/portweaver
   ```

2. Update and install feeds:
   ```bash
   ./scripts/feeds update -a
   ./scripts/feeds install -a
   ```

3. Configure and build:
   ```bash
   make menuconfig  # Select Network -> portweaver
   make package/portweaver/compile V=s
   ```

## Configuration

Configuration file is located at `/etc/config/portweaver`.

Example configuration:
```
config project 'rdp'
    option remark 'Windows RDP'
    option family 'any'
    option protocol 'tcp'
    option listen_port '3389'
    option reuseaddr '1'
    option target_address '192.168.1.100'
    option target_port '3389'
    option open_firewall_port '1'
    option add_firewall_forward '1'
```

Supported options:
- `remark` - Description of the forwarding rule
- `family` - Address family: `any` / `ipv4` / `ipv6`
- `protocol` - Protocol: `both` / `tcp` / `udp`
- `listen_port` - Port to listen on (source port)
- `reuseaddr` - Enable SO_REUSEADDR (0/1)
- `target_address` - Destination IP address
- `target_port` - Destination port
- `open_firewall_port` - Open port in firewall (0/1)
- `add_firewall_forward` - Add firewall forwarding rule (0/1)

## Service Management

```bash
/etc/init.d/portweaver start
/etc/init.d/portweaver stop
/etc/init.d/portweaver restart
/etc/init.d/portweaver enable  # Start on boot
```

## License

MIT
