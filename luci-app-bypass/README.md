# luci-app-bypass

Gateway-level transparent traffic splitting for OpenWrt. This LuCI application combines three specialized components:

| Component | Role |
|---|---|
| **[BypassCore](https://github.com/kinmeic/BypassCore)** | Required transparent routing and traffic-splitting core |
| **naiveproxy** | Naive HTTPS transport adapter and local SOCKS upstream |
| **ChinaDNS-NG** | Auxiliary direct DNS resolver and NFTSet writer |

The data plane uses **nftables/fw4** only. The LuCI frontend uses modern JavaScript views and does not require a Lua runtime.

> **BypassCore is mandatory.** It is the equivalent of Xray or sing-box in Passwall: it owns the transparent listener, rule matching, DNS behavior, observatory, and outbound decisions. NaiveProxy only provides the HTTPS transport and SOCKS upstream. If BypassCore is unavailable or fails to listen, the service fails closed; it never falls back to NaiveProxy.
>
> Source and releases: [kinmeic/BypassCore](https://github.com/kinmeic/BypassCore). The project can be built with `make build`; OpenWrt prebuilt archives are available from its releases.

## How it works

```text
LAN client
   │
nftables TPROXY/REDIRECT
   │
BypassCore (0.0.0.0:<REDIR_PORT>)
   ├── direct / block
   └── proxy → naiveproxy (127.0.0.1:<node_socks_port>)
                    │
                    ▼
              Naive HTTPS server

DNS: dnsmasq :53 → BypassCore DNS :<dns_port>
       domestic/direct DNS → direct outbound
       remote DNS          → selected Naive SOCKS (TCP/DoT/DoH)
       Direct/NFTSet domains → ChinaDNS-NG helper → domestic DNS + NFTSet
```

Each Naive node can use its own OpenWrt logical egress interface. The runtime resolves `wan`, `wan1`, `usbwan`, and similar interfaces through netifd, then installs destination-specific policy routes for the Naive server addresses without overwriting mwan3/PBR packet marks.

## Direct IP List

Other Settings provides a Passwall2-style **Direct IP List**, stored in `/usr/share/bypass/direct_ip`. IPv4/IPv6 addresses, CIDR ranges, `geoip:CODE` entries, and `#` comments are supported. Entries are loaded into nftables sets before REDIRECT/TPROXY, so matching traffic does not enter BypassCore. The default list covers private, loopback, link-local, multicast, and reserved ranges.

## Dependencies

This application supports fw4/nftables only.

- Required: `ca-bundle curl ip-full resolveip libubox nftables kmod-nft-nat kmod-nft-tproxy kmod-nft-socket chinadns-ng`
- `INCLUDE_NaiveProxy` → `naiveproxy`
- `INCLUDE_Geoview` → `geoview`
- `INCLUDE_V2ray_Geo` → `v2ray-geoip` and `v2ray-geosite`
- `INCLUDE_Tcping` → `tcping`

BypassCore is intentionally not an automatic package dependency because it is maintained as an independent project and is not available in the official OpenWrt feeds. Install the matching package from the [BypassCore releases](https://github.com/kinmeic/BypassCore/releases), or place the Linux executable at `/usr/bin/bypasscore`.

Version 1.5.5 and later require BypassCore v1.0.8 or newer. In addition to the native `type: "dns"` UDP/TCP inbound, this version forwards arbitrary DNS record types such as MX, TXT, SRV, PTR and CAA through the selected tagged outbound. Startup rejects older cores so dnsmasq cannot receive silently empty non-address responses.

## Build and install

Place this directory in an OpenWrt source tree, for example under `feeds/luci/applications/luci-app-bypass`, then run:

```sh
make menuconfig
make package/feeds/luci/luci-app-bypass/compile V=s
opkg install luci-app-bypass_*.ipk
```

After installation:

1. Install BypassCore v1.0.8 or newer for the router architecture from its [releases](https://github.com/kinmeic/BypassCore/releases).
2. Install NaiveProxy. ChinaDNS-NG is declared as a runtime dependency.
3. Install `v2ray-geoip`/`v2ray-geosite`, or place `geoip.dat` and `geosite.dat` under `/usr/share/v2ray/`.
4. Open LuCI → Services → Bypass, configure nodes and egress interfaces, then enable the service.

## Configuration highlights

- **Node Config**: supports NaiveProxy HTTPS nodes only; each node can override `default_naive_interface` with its own `egress_interface`.
- **Shunt Rule**: choose Close, Default Node, Direct Connection, Blackhole, or a specific NaiveProxy node. The virtual Default row is always the final catch-all and is stored in `global_rules.default_node` rather than a `shunt_rules` section.
- **Other Settings**: configure TCP redirection, UDP No Redir Ports, IPv6 TProxy, ICMP handling, and Direct IP List.
- **Rule Manage**: maintain the ordered shunt-rule list and optional GeoIP/Geosite update schedule.
- **Runtime upgrades**: the always-on lightweight watcher fingerprints the installed BypassCore, NaiveProxy, and ChinaDNS-NG executables. After an `opkg`/`apk` upgrade settles, Bypass performs one serialized full restart so the new binaries actually take effect. Disabling process-health supervision does not disable upgrade detection.
- **Geo View**: query domain/IP matches against installed GeoIP and Geosite data.

NaiveProxy does not support general SOCKS5 UDP association. By default, forwarded external UDP is blocked to prevent QUIC/STUN traffic from bypassing the TCP proxy. Explicit UDP No Redir Ports are sent directly and may expose the real egress IP.

## Runtime architecture

BypassCore is the required transparent routing core; there is no legacy NaiveProxy core mode or automatic fallback. The service does not install transparent OUTPUT rules for router-local applications, avoiding recursive interception of direct outbound sockets.

Per-node NaiveProxy instances are started only for nodes referenced by shunt rules or the virtual Default row. Direct traffic can use a global default interface or a per-rule override. A node with no explicit egress interface inherits Default Naive Interface, then falls back to the system route. Node server destinations receive dedicated policy routes based on the effective interface, while existing mwan3/PBR marks remain untouched.

## Known limitations

- NaiveProxy-only transport cannot proxy general UDP; UDP is blocked by default unless explicitly listed under UDP No Redir Ports.
- IPv6 transparent proxying is available for TCP when IPv6 TProxy is enabled and the node supports IPv6.
- Remote DNS is handled natively by BypassCore. TCP, DoT, and DoH can use the selected Naive node; UDP is allowed only with Direct outbound, and unsafe/incomplete paths fail closed.
- Router-local applications are not transparently intercepted by nftables OUTPUT rules.
- Subscription parsing, ACL subscriptions, HAProxy load balancing, and automatic SOCKS switching are not implemented.

## License

MIT. See [LICENSE](LICENSE).
