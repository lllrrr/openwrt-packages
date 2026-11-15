# luci-app-oxidns

Language: [中文](./README.md) | English

`luci-app-oxidns` is the LuCI management app for OxiDNS on OpenWrt. After installation, LuCI adds `Services -> OxiDNS` pages for installing the OxiDNS core, managing the OpenWrt service, editing configuration, viewing logs, and optionally forwarding LAN DNS through dnsmasq to OxiDNS.

This repository contains only the LuCI management UI and the rpcd backend; the OxiDNS core, WebUI, and general releases come from [svenshi/oxidns](https://github.com/svenshi/oxidns).

**Full guide**: configuring DNS from scratch, the Normal/Advanced mode field reference, plugin fields, common tasks, troubleshooting, and OxiDNS WebUI instructions are in [info/README.en.md](info/README.en.md). For enabling dnsmasq forwarding with one click on `Basic Information`, manual configuration, and rollback, see [4.9 Forward Through dnsmasq (Recommended)](info/README.en.md#49-forward-through-dnsmasq-recommended); for the Normal mode ad filtering card, see [3.8 Ad Filtering](info/README.en.md#38-ad-filtering).

![OxiDNS LuCI interface](screenshot.png)

## Install The LuCI App

Download the package from this repository's Releases, upload it to the device (for example `/tmp`), then install it.

OpenWrt 24.10 (`opkg`):

```sh
opkg install /tmp/luci-app-oxidns_*.ipk

# Optional: install the Simplified Chinese language pack
opkg install /tmp/luci-i18n-oxidns-zh-cn_*.ipk
```

OpenWrt 25.12 (`apk`):

```sh
apk add --allow-untrusted /tmp/luci-app-oxidns-*.apk

# Optional: install the Simplified Chinese language pack
apk add --allow-untrusted /tmp/luci-i18n-oxidns-zh-cn-*.apk
```

If the menu does not appear after installation, restart `rpcd`, then open `Services -> OxiDNS`:

```sh
/etc/init.d/rpcd restart
```

### Build From Source

To include the package in firmware or customize it, place it in an OpenWrt build tree and compile it together with the other packages:

```sh
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a
git clone https://github.com/Arthur97172/luci-app-oxidns.git package/luci-app-oxidns
make menuconfig   # LuCI -> Applications -> luci-app-oxidns
make package/luci-app-oxidns/compile V=s
```

The artifacts appear under `bin/packages/<arch>/`: a 24.10 build tree produces `.ipk`, and a 25.12 build tree produces `.apk`.

## Features

- `Basic Information`: `Status Overview` shows the backend, core, build, service status, boot autostart, and WebUI entry, with start, stop, and restart controls below.
- `System DNS integration`: on the `Basic Information` page, enable or disable dnsmasq forwarding in one click. When enabled, dnsmasq forwards generic DNS queries to OxiDNS's listen address while keeping domain-specific upstreams; it is disabled by default, and disabling restores the previous generic upstreams and `noresolv` setting.
- `Installation and Deployment`: install, update, upload, repair, or remove the core and WebUI; configure the core repository, bundle, paths, system log output, and download credentials.
- `DNS Configuration`: Advanced mode (a full YAML editor) is the default; Normal mode provides forms for common settings. Both support validation, config download/upload, save, save and apply, and a change preview. `forward` upstreams can be picked from a preset combobox or entered as a custom address, and when no `forward` plugin exists Normal mode creates one and wires it into the entry sequences; a server's `Entry` is chosen from a dropdown of known plugins. The Normal mode `Ad filtering` card creates and manages a fixed `adguard_rule` / `black_hole` plugin group (plus a `download` plugin once subscription URLs are entered) with inline rules, local rule files, and a blocking mode, and inserts the blocking rule at the front of every entry sequence. The Normal mode `Hosts` card creates the fixed `hosts` plugin (`oxidns_hosts`), inserts the hosts step into the entry sequences, and maintains the local name records. The Normal mode `Cache` card creates the fixed `cache` plugin (`oxidns_cache`), inserts the cache step into the entry sequences, and exposes every cache field once enabled.
- `Runtime Logs`: view OxiDNS runtime logs.

## Default Paths

| Item | Path |
| --- | --- |
| Core binary | `/usr/bin/oxidns` |
| WebUI | `/usr/share/oxidns/webui` |
| Configuration | `/etc/oxidns/config.yaml` |
| Working directory | `/var/lib/oxidns` |
| Log file | `/tmp/oxidns/oxidns.log` |
| Init script | `/etc/init.d/oxidns` |

## Known Limitations

- Only published OxiDNS Linux musl release targets are supported.
- `Update Core` installs only strictly newer stable releases and never downgrades a newer or custom build.
- Before replacing the core or WebUI, LuCI stages and verifies the new files; if a copy fails, the old files are restored so the core and WebUI cannot be left mismatched.
- Normal mode only edits plugin instances that already exist. Adding or removing plugins and changing sequence rules require Advanced mode or the OxiDNS WebUI; the `Ad filtering`, `Hosts`, and `Cache` cards are the exceptions: they create or remove a fixed `adguard_rule` / `black_hole` group (plus a `download` plugin once subscription URLs are entered), the fixed `oxidns_hosts` plugin, and the fixed `oxidns_cache` plugin, and maintain the matching blocking, hosts, and cache steps in the entry sequences. The `Create forward plugin` button in the upstream section can also create the fixed `forward` plugin and wire it into the entry sequences. With YAML anchors, aliases, or merge keys, Normal mode becomes read-only.
- Saving from Normal mode re-serializes the YAML: comments, field order, and fields the form does not manage are preserved, and only edited fields are written. Normal mode, Advanced mode, and the OxiDNS WebUI edit the same file, so use only one entry point at a time.
- The WebUI entry on `Basic Information` requires installed WebUI files, a running service, and a reachable HTTP listen address; with `127.0.0.1` / `::1`, use local access or an SSH tunnel.
- `System DNS integration` requires OxiDNS to be running, with UDP and TCP listeners on the same port that share a reachable IPv4 address; the `Enable dnsmasq forwarding` button stays unavailable with IPv6-only listeners, mismatched ports, or no shared reachable IPv4 address.
- Once `System DNS integration` is enabled, stopping OxiDNS makes LAN DNS resolution fail (fail-closed) instead of bypassing OxiDNS automatically; start OxiDNS again or disable the integration.
- `System DNS integration` does not take over port 53; dnsmasq keeps listening on 53 and continues to provide DHCP, local names, and lease resolution. Having OxiDNS bind port 53 directly is a different deployment, and the detailed guide covers its trade-offs and steps.

## Private Repositories And Downloads

The router must be able to reach GitHub Releases and release archives. For private repositories or restricted networks, configure a GitHub token or download proxy in `Installation and Deployment`; saved values are never shown again in LuCI. A download proxy requires `curl`; alternatively use `Upload Core` for offline installs.

## License

This project is licensed under the GNU General Public License v3.0 or later (`GPL-3.0-or-later`). See [LICENSE](LICENSE) for the full license text.

## Acknowledgements

- [https://oxidns.org/](https://oxidns.org/): the official OxiDNS homepage, with documentation, configuration references, and project news.
- [https://github.com/svenshi/oxidns](https://github.com/svenshi/oxidns): the source repository for the OxiDNS core and its WebUI; the core and WebUI files installed by this plugin come from that project's releases.
- This repository is cloned from [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) and optimized on top of it.
