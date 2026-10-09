[简体中文](README.md) | **English**

# luci-app-frpc-multi

A LuCI app for OpenWrt / iStoreOS that runs multiple frp client connections. Each connection is a separate `frpc` process, so you can connect to several frp servers at once and manage status, logs and start/stop from one page.

> The web interface is currently in Chinese.

## Install

Run as root:

```sh
wget -O /tmp/install-frpc-multi.sh https://raw.githubusercontent.com/myc2002/luci-app-frpc-multi/main/install.sh && sh /tmp/install-frpc-multi.sh
```

Supports apk and opkg on ARM64 or x86_64. When it finishes, open **LuCI → Services → frp 多客户端**.

The script verifies the package checksum and installs dependencies from your configured package feeds. If the `frpc` in your feeds is too old to support TOML configs, it downloads the official 0.66.0 release into `/usr/lib/frpc-multi/frpc` for this app only. `/usr/bin/frpc` is never overwritten.

You can also download a package from [Releases](https://github.com/myc2002/luci-app-frpc-multi/releases): `noarch.apk` for apk systems, `all.ipk` for opkg systems. Verify it against `SHA256SUMS`. A manual install does not handle an outdated `frpc`.

## Features

- Independent connections: one failing connection does not affect the others; crashed processes restart automatically, plus a per-minute watchdog
- Proxy types: tcp, udp, http, https, tcpmux, stcp, xtcp, sudp
- Token, TLS, transport protocol, multiplexing, connection pool, heartbeat, DNS, outbound proxy, bandwidth limit, encryption, compression
- HTTP domains and auth, visitors, and the http_proxy, socks5, static_file and unix_domain_socket plugins
- Status cards show connection state, proxy health and errors; restart, disable or view logs per connection
- Saving only restarts the connections that actually changed

There is no fixed limit on the number of connections; the practical limit is your device's resources. The status API uses local ports in the 27400–27999 range.

## Usage

1. Click **添加连接…** (Add connection), then enter a name, server address, port and token.
2. Click **添加代理…** (Add proxy), pick the connection it belongs to, then set the local address and remote port.
3. Save and apply, then check the status cards to confirm the connection and proxies are online.

Notes:

- TLS is on by default and must match the server setting.
- **停用** (Disable) in the page is persistent. A connection stopped with `stop` on the command line may be restarted by the watchdog.
- The app does not touch other frp packages and does not change your firewall; open the required ports yourself.
- `/etc/config/frpc_multi` contains tokens and is mode 600. Upgrades keep it; uninstalling does not delete it.

## Commands

```sh
/etc/init.d/frpc-multi checkconfig [ID]   # check config
/etc/init.d/frpc-multi restart [ID]       # restart
/etc/init.d/frpc-multi reload             # reload
apk del luci-app-frpc-multi               # uninstall; use `opkg remove` on opkg
```

## Build

```sh
sh build-release-matrix.sh
```

Produces a `noarch` APK, an `all` IPK and `SHA256SUMS`. Building the APK needs Docker, or set `APK_MKPKG` to a local apk v3 tool. Test scripts for the installer and packaging are in `tests/`.

## License

New code is Apache-2.0. The init script reuses parts of the OpenWrt FRPC package and follows its GPL-2.0 license; see `NOTICE` and `LICENSES/`. frp itself is a separate dependency and is not included in this package.
