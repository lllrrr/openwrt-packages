# OxiDNS DNS Configuration and WebUI Guide

Language: [中文](./README.md) | English

This guide is for users who have installed `luci-app-oxidns` and the OxiDNS core. It explains how to configure DNS on the LuCI `DNS Configuration` page, how to enable dnsmasq forwarding with one click on `Basic Information`, and how to do the same work through the OxiDNS WebUI.

Default OpenWrt paths used throughout:

| Item | Default |
| --- | --- |
| Configuration file | `/etc/oxidns/config.yaml` |
| Core binary | `/usr/bin/oxidns` |
| WebUI static directory | `/usr/share/oxidns/webui` |
| Working directory | `/var/lib/oxidns` |
| Log file | `/tmp/oxidns/oxidns.log` |
| DNS listen port | `5335` (UDP/TCP) |
| Management API / WebUI port | `9199` |

---

## 1. How OxiDNS Processes DNS

OxiDNS builds a DNS pipeline from plugins:

1. A **server plugin** receives queries, such as `udp_server`, `tcp_server`, `quic_server`, or `http_server`.
2. The server's `entry` points to a **sequence**.
3. The sequence runs rules in order: matchers test conditions and executors perform actions such as reading the cache, forwarding upstream, or returning a fixed address.
4. The result is returned to the client.

A minimal working configuration normally has:

- one `forward` plugin with at least one upstream;
- one `sequence` that sends queries to `forward`;
- one or more server plugins listening on a port.

The LuCI `DNS Configuration` page and the OxiDNS WebUI edit the **same** `/etc/oxidns/config.yaml`; only the editing method differs:

- `Normal Mode`: forms for everyday changes to logging, runtime settings, included files, the API, listen addresses, upstreams, and common plugin arguments.
- `Advanced Mode`: a full YAML editor for any field, plugin composition, sequence rules, and top-level settings such as `network`.
- `OxiDNS WebUI`: graphical management of plugins, sequences, query records, caches, and upgrades, with a dashboard and runtime logs.

### Before You Start

1. On `Services -> OxiDNS -> Basic Information`, use `Status Overview` to confirm the core is installed.
2. Confirm the service is running; click `Start` if it is not.
3. On `DNS Configuration`, click `Download Config` to back up the current `config.yaml`.
4. Decide on the listen address: `127.0.0.1:5335` for local use or dnsmasq; the router's LAN address or `0.0.0.0:5335` for direct LAN access.
5. Never expose ports 53, 5335, or 9199 to the WAN.

If the core is missing, use `Install Core` under `Core Actions` on the `Installation and Deployment` page, or `Upload Core` for an offline install.

---

## 2. Common Actions on the DNS Configuration Page

Open `Services -> OxiDNS -> DNS Configuration`.

The page has two mode buttons:

- `Advanced Mode`: the default. A full YAML editor.
- `Normal Mode`: forms; available only when the YAML parses cleanly as a top-level mapping.

Both modes share the same action buttons:

| Button | Effect |
| --- | --- |
| `Validate` | Runs `oxidns check` on the current editor content without writing the file. |
| `Download Config` | Downloads the current on-disk `config.yaml` for backup. |
| `Upload Config` | Replaces the current configuration with a local file named `config.yaml`. The file is validated and saved, but the service is not restarted automatically. |
| `Save and Apply` | Validates and writes the file; if the content changed, restarts OxiDNS so the configuration takes effect. |
| `Save` | Validates and writes the file without restarting the service. |
| `Reset` | Discards unsaved edits on the page and restores the on-disk content. |

### Change Preview

The `Change Preview` area is enabled by default through `Show change preview`. It compares the on-disk original with the current editor content:

- green `+` lines are additions;
- red `-` lines are removals;
- `…` marks unchanged regions that are collapsed.

The preview is read-only and never writes the file. Clear the checkbox to hide it.

### Mode Switching

- Switching from `Normal Mode` to `Advanced Mode` merges the current form values into YAML and loads it into the editor.
- Switching back requires the editor content to parse as a YAML object; otherwise an error is shown and you stay in Advanced Mode.
- YAML syntax errors force Advanced Mode and make Normal Mode unavailable.
- If the configuration uses YAML anchors, aliases, or merge keys (`<<`), Normal Mode shows a warning and becomes read-only; edit in Advanced Mode instead.

### Validation and Saving

- Normal Mode runs a front-end check against the built-in schema before submitting: out-of-range numbers, invalid enum values, duplicate plugin tags, sequence steps and `matches`, server `entry`, DoH `exec`, and fallback `primary` / `secondary` that reference missing plugins, and management API security settings are reported directly and nothing is saved. The checks stay aligned with the core `oxidns check`: configurations the core accepts (for example missing `listen` / `entry`, a forward plugin without upstreams, a certificate without its key, or empty plugin fields) are not blocked by the front end. When the configuration pulls in external plugins through `include`, cross-file references cannot be resolved and the reference checks are skipped.
- Both `Save` and `Save and Apply` then run `oxidns check -c <temp file> -d <working directory>` in the backend; invalid content is never written.
- `Save and Apply` always restarts the service, while `Save` only writes the file. Saving first and then clicking `Save and Apply` therefore still triggers a restart even when the file matches the last save, so the running service picks up the new configuration.
- Writes are atomic and the previous file is backed up before replacement.
- The save checks the file mtime. If another program (such as the OxiDNS WebUI) changed the file after the page was opened, the save is rejected; reload the page and edit again.
- Normal Mode writes only fields that were actually edited. Untouched defaults are not added, so the change preview is not polluted by unrelated defaults.
- Normal Mode re-serializes the YAML, preserving comments, field order, and fields the forms do not manage, though whitespace may change slightly. Advanced Mode saves the editor text exactly.

---

## 3. Normal Mode Field Reference

Normal Mode is generated from the backend configuration schema plus fixed front-end sections. **It only shows plugin instances that already exist in the configuration** and never creates plugins; the exceptions are the `Ad filtering` card, which can create, edit, or remove a fixed-tag `adguard_rule` / `black_hole` group and, once subscription URLs are entered, its `download` plugin (see [3.8 Ad Filtering](#38-ad-filtering)), and the `Getting Started` card shown while no server entry references a sequence, which can fill in a minimal sequence plus UDP/TCP server setup.

The `Getting Started` card appears only when no server plugin references a sequence, a configuration that cannot answer queries. Pick or create an entry sequence, set the listen address (default `:5335`), and click `Create entry sequence and servers`. An existing server plugin of the same type only has its empty `entry` / `listen` fields filled in; it is never duplicated, and tag collisions fall back to suffixes such as `main_sequence_2`. When the configuration pulls in plugins through `include`, the card only shows a note and leaves those files alone. Once created, the `Create forward plugin` button in `Upstream DNS` can wire forwarding into the entry sequence.

### 3.1 Log

Configuration path: `log`.

| Field | Config key | Description |
| --- | --- | --- |
| `Log level` | `log.level` | `off`, `trace`, `debug`, `info`, `warn`, or `error`; default `info`. |
| `Log file` | `log.file` | Log file path, default `/tmp/oxidns/oxidns.log`. Leave empty to log only to standard output. |
| `Rotation` | `log.rotation.type` | `never` (default), `minutely`, `hourly`, `daily`, or `weekly`. |
| `Maximum rotation files` | `log.rotation.max_files` | Number of history files to keep. Leave it empty or set `0` to disable automatic deletion; the field is only written when you enter a value. Switching rotation to `never` clears a saved value. |

Notes:

- Log files are plain UTF-8 text without terminal color codes.
- `/tmp` is cleared on reboot. For persistent logs, point `Log file` at a persistent directory such as `/var/log/oxidns/oxidns.log`, or change the log directory under `Installation and Deployment -> Log path` and click `Save and Apply`.
- A new log level affects only subsequent output. After changing the log file or rotation settings, use `Save and Apply` to restart the service.

### 3.2 Runtime

Configuration path: `runtime`.

| Field | Config key | Description |
| --- | --- | --- |
| `Worker threads` | `runtime.worker_threads` | Number of DNS worker threads. Leave empty to use the system's available parallelism (the OxiDNS default); when set it must be at least 1. |

Notes:

- Set this only when you need to limit CPU usage or pin the thread count. Leaving it empty does not write `worker_threads` to the file.
- Clearing an existing value removes the key and restores the default parallelism.

### 3.3 Included Files (Include)

Configuration path: top-level `include`.

| Field | Config key | Description |
| --- | --- | --- |
| `Included configuration files` | `include` | One configuration file path per line. |

Notes:

- Only `plugins` are merged from included files; other settings such as `log`, `runtime`, and `api` in them are ignored.
- Relative paths are resolved from the directory of the configuration file that declares the `include`.
- Recursion is limited to 8 levels.
- Plugin tags must be globally unique after merging all files.
- Plugins from included files are not listed on this page. Edit the corresponding file in Advanced Mode or the WebUI instead.
- Clearing the text area removes the whole `include` key.

Validation rules:

- `include` must be a list of strings, not a single string.
- Entries cannot be empty and cannot be duplicated.

### 3.4 Outbound Network

Configuration path: `network.outbound.default`.

| Field | Config key | Description |
| --- | --- | --- |
| `Default outbound profile` | `network.outbound.default` | Selects the default outbound profile from the `network.outbound.profiles` already defined in the configuration. Selecting "None" deletes the field. |

Notes:

- The drop-down lists only profile names that already exist under `network.outbound.profiles`. When none are defined, only "None" is available; add profiles in Advanced mode or the WebUI first.
- The default is used by HTTP clients and upstreams that do not set their own outbound profile. Individual upstreams and plugins such as `ip_selector` and `download` can still override it with their own `Outbound profile`.
- A `default` that points to an undefined profile stays selected and is marked "not defined"; validation reports it before saving. Define that profile under `network.outbound.profiles` or select a defined one.
- Selecting "None" deletes `network.outbound.default` and restores the core default behavior (system DNS and direct connections); if `network.outbound` is left empty, the empty mapping is removed as well.
- Normal mode does not edit the contents of `network.outbound.profiles`.

### 3.5 API (Management API and WebUI)

Configuration path: `api.http`.

| Field | Config key | Description |
| --- | --- | --- |
| `HTTP listen` | `api.http` or `api.http.listen` | API listen address, such as `192.168.1.1:9199`, `0.0.0.0:9199`, `:9199`, `[::]:9199`, or `127.0.0.1:9199`. |
| `WebUI root` | `api.http.webui.root` | WebUI static directory, default `/usr/share/oxidns/webui`. |
| `WebUI index` | `api.http.webui.index` | Index file name, default `index.html`. |
| `TLS certificate` | `api.http.ssl.cert` | Required together with the private key to serve HTTPS. |
| `TLS private key` | `api.http.ssl.key` | Must be configured together with the certificate. |
| `Client CA certificate` | `api.http.ssl.client_ca` | Used when verifying client certificates. |
| `Require a client certificate` | `api.http.ssl.require_client_cert` | Requires `ssl.client_ca` when enabled. |
| `Basic auth username` | `api.http.auth.username` | Must be set together with the password to enable Basic authentication. |
| `Basic auth password` | `api.http.auth.password` | Never shown again after saving; leave empty to keep the current password. |
| `Remove Basic authentication` | `api.http.auth` | Removes the entire authentication block when checked. |
| `CORS allowed origins` | `api.http.cors.allowed_origins` | One origin per line. Leave empty to derive origins from the listen address; `*` allows any origin. |

`api.http` has two forms:

```yaml
# Shorthand: listen address only; cannot mount the WebUI
api:
  http: "0.0.0.0:9199"
```

```yaml
# Expanded: listen, authentication, TLS, CORS, and WebUI
api:
  http:
    listen: "0.0.0.0:9199"
    ssl:
      cert: "/etc/oxidns/api.crt"
      key: "/etc/oxidns/api.key"
      client_ca: "/etc/oxidns/client-ca.crt"
      require_client_cert: false
    auth:
      type: basic
      username: "admin"
      password: "change-me"
    cors:
      allowed_origins: [ "https://example.com" ]
    webui:
      root: "/usr/share/oxidns/webui"
      index: "index.html"
```

Normal Mode detects the current form:

- With the shorthand, only `HTTP listen` is shown, with a note that the shorthand cannot serve the WebUI, TLS, authentication, or CORS. Click `Convert to expanded form` to convert in place: the current listen address is kept as `listen`, and existing comments and quote style are preserved. The conversion only happens when you click the button; the file is never rewritten automatically.
- With the expanded form, the listen address, WebUI, TLS, Basic authentication, and CORS fields appear.
- Saving authentication fields adds `auth.type: basic` automatically. If only a username or only a password is filled in, validation reports that both are required.
- The password is written only when you type a new one; afterwards the page only says a password is configured and never echoes it. Enter a new value to change it, or check `Remove Basic authentication` to disable authentication.
- These fields can also be configured under `System Settings -> Management API` in the OxiDNS WebUI.

Validation rules:

- The expanded form's `listen` cannot be empty.
- `ssl.cert` and `ssl.key` must be configured together.
- Enabling `require_client_cert` requires `ssl.client_ca`.
- An existing `auth` block must contain both a username and a password.

Listen address formats:

- `ip:port`: listen on a specific IPv4 address.
- `[ipv6]:port`: listen on a specific IPv6 address.
- `:port`: bind dual-stack `[::]:port`.
- For IPv4 only, write `0.0.0.0:port` explicitly.

> The `Open WebUI` button on `Basic Information` builds its URL from this listen address. If it listens on `127.0.0.1` or `::1`, only the router itself can reach it and LuCI shows a hint. For LAN access, use the LAN address or `0.0.0.0:9199`.

### 3.6 Listen Addresses

Configuration path: instances of `udp_server`, `tcp_server`, and `quic_server` under `plugins`.

Normal Mode shows two fields per instance:

| Field | Config key | Description |
| --- | --- | --- |
| `Entry (<tag>)` | `plugins[i].args.entry` | Entry plugin tag, usually a sequence. The dropdown lists the plugin tags defined in the configuration: sequences first, other plugins under `Other plugins`. A current value that is not in the list is kept as `… (not defined)` instead of being rewritten. |
| `Listen (<tag>)` | `plugins[i].args.listen` | Listen address and port, default `:5335`. |

`Entry` is a dropdown so a mistyped tag cannot silently break the lookup chain. When the configuration pulls in external plugins through `include`, the page cannot list those tags, so `Entry` falls back to a text input and the reference checks are skipped.

Example: listen on loopback only so dnsmasq can forward to OxiDNS:

```yaml
- tag: udp_server
  type: udp_server
  args:
    entry: main_sequence
    listen: "127.0.0.1:5335"

- tag: tcp_server
  type: tcp_server
  args:
    entry: main_sequence
    listen: "127.0.0.1:5335"
```

Notes:

- `entry` must reference an existing sequence, or `oxidns check` fails.
- The two servers may share a port because the protocols differ (UDP/TCP).
- A `quic_server` instance also needs its TLS certificate and private key.
- If the page reports that no UDP, TCP, or QUIC server plugins were found, the configuration has none; create them in Advanced Mode or the WebUI.

### 3.7 Upstream DNS

Configuration path: `plugins[i].args.upstreams` of the `forward` plugin.

When the configuration has no `forward` plugin, the section shows a `Create forward plugin` button. Clicking it creates a `forward` plugin tagged `forward` and adds `- exec: $forward` at the end of every entry sequence (before a trailing `accept` when one is present); add at least one upstream below afterwards. The button needs at least one server entry sequence and stays disabled otherwise; if the tag `forward` is already used by a plugin of another type, the section asks you to rename it in Advanced Mode first.

Each `forward` instance gets a section titled with its tag. Each upstream has:

- `Upstream address N`: a preset combobox for common public DNS servers, or a custom address.
- `Options` / `Hide options`: expand or collapse per-upstream connection options.
- `Remove`: remove this upstream.
- `Add upstream DNS`: the add control is the combobox itself. Picking a preset or entering a custom address appends a new upstream carrying that address, and the combobox returns to "Select or input an upstream DNS server" for the next one. An upstream still showing that placeholder has no address and is not saved to the configuration file.

Common presets include Alibaba, Tencent, 114, Baidu, Cloudflare, Google, and Quad9 over UDP, DoT, DoH, and DoQ, for example:

| Address | Description |
| --- | --- |
| `223.5.5.5`, `223.6.6.6` | Alibaba Public DNS (UDP) |
| `119.29.29.29`, `119.28.28.28` | Tencent Public DNS (UDP) |
| `114.114.114.114` | 114 Public DNS (UDP) |
| `180.76.76.76` | Baidu Public DNS (UDP) |
| `https://dns.alidns.com/dns-query` | Alibaba DoH |
| `quic://dns.alidns.com` | Alibaba DoQ |
| `https://doh.pub/dns-query` | Tencent DoH |
| `tls://1.1.1.1`, `tls://1.0.0.1` | Cloudflare DoT |
| `https://cloudflare-dns.com/dns-query` | Cloudflare DoH |
| `tls://8.8.8.8`, `tls://8.8.4.4` | Google DoT |
| `https://dns.google/dns-query` | Google DoH |
| `tls://9.9.9.9`, `tls://149.112.112.112` | Quad9 DoT |
| `https://dns.quad9.net/dns-query` | Quad9 DoH |

Custom addresses accept the upstream schemes OxiDNS supports, such as `udp://`, `tcp://`, `tls://`, `https://`, `quic://`, and `h3://`. Without a scheme, UDP is assumed.

Fields under `Options`:

| Field | Description |
| --- | --- |
| `Tag` | Tag for this upstream, useful in logs and references. |
| `Outbound profile` | References a profile in `network.outbound.profiles`; empty uses `network.outbound.default`. |
| `Dial address` | IP actually connected to, for domain-based DoT/DoH addresses, avoiding self-resolution. Example: `203.0.113.1`. |
| `Port override` | Overrides the upstream port, 1–65535. |
| `Bootstrap server` | Bootstrap DNS for resolving DoT/DoH hostnames, such as `8.8.8.8:53`. |
| `Bootstrap IP version` | IPv4 or IPv6 for bootstrap queries. |
| `SOCKS5 proxy` | SOCKS5 proxy for this upstream, such as `127.0.0.1:1080`. |
| `Query timeout` | Query timeout as a string, such as `5s`. |
| `Idle timeout` | Idle connection timeout in seconds, minimum 0; the protocol default is usually 10. |
| `Max connections` | Maximum connections, 1–4096, default 64. |
| `Min connections` | Minimum maintained connections, 0–4096, default 0. |
| `Skip TLS verification` | Skip certificate verification for this upstream; trusted environments only. |
| `Enable pipeline` | Enable connection pipelining. |
| `Enable HTTP/3` | Enable HTTP/3 for supporting upstreams. |
| `SO_MARK` | Mark connections, 0–4294967295, often used with policy routing. |
| `Bind to device` | Bind to an interface, such as `eth0`. |

The front end checks before saving:

- plugin tags are unique; the core rejects duplicate tags;
- every server `entry`, every sequence step `exec: $tag`, and every DoH entry `exec` references an existing plugin tag; `entry` and DoH `exec` take the bare tag without a `$` prefix;
- a `forward` plugin has at least one upstream;
- every upstream `addr` is non-empty;
- `min_conns` does not exceed `max_conns`.

The backend still runs `oxidns check`, and the core's result is authoritative.

### 3.8 Ad Filtering

The `Ad filtering` card bundles the common ad-blocking setup. It needs at least one server entry sequence in the configuration; when none exists, `Add ad filtering` stays disabled and the card asks you to configure a server entry in Advanced Mode first. After you click `Add ad filtering`, Normal Mode creates the fixed-tag `oxidns_ads_rules` and `oxidns_ads_block` plugins and inserts the blocking rule at the front of every server entry sequence. The `oxidns_ads_download` plugin is added when you enter at least one subscription URL:

| Tag | Type | Purpose |
| --- | --- | --- |
| `oxidns_ads_download` | `download` | Downloads rule files from subscription URLs. |
| `oxidns_ads_rules` | `adguard_rule` | Reads inline rules, local rule files, and downloaded subscription files. |
| `oxidns_ads_block` | `black_hole` | Answers matching queries locally. |

The inserted sequence rule is fixed:

```yaml
- matches: "qname $oxidns_ads_rules"
  exec: $oxidns_ads_block
```

It sits at the front of each entry sequence, so ad domains are blocked before `forward` runs.

Before configuration the card shows the `Add ad filtering` button; it stays disabled when no server entry sequence exists. Once configured it offers:

| Field | Description |
| --- | --- |
| `Subscription URLs` | One `http://` or `https://` URL per line, mapped to `download.downloads`. Subscription files are downloaded only when missing at startup; existing files are not refreshed at startup, so delete the file and restart, or trigger a download through the OxiDNS API/WebUI. A failed startup download fails startup. |
| `Inline rules` | One AdGuard rule per line, mapped to `adguard_rule.rules`. |
| `Local rule files` | One absolute path per line, mapped to `adguard_rule.files`. |
| `Blocking mode` | Maps to `black_hole.mode`; defaults to `nxdomain`. |
| `Blocking addresses` | IPv4 / IPv6 addresses returned in `custom` mode. |
| `Rules directory` | Directory for downloaded subscription files, default `/etc/oxidns/rules`; generated rule files start with `oxidns-ads-`. |

If you keep the subscription download plugin but clear all URLs, validation asks for a URL or tells you to click `Remove subscription downloads` first.

`Remove subscription downloads` deletes only the `download` plugin and the rule-file paths it generated, keeping inline rules, local rule files, and the blocking plugin. `Remove ad filtering` removes the whole group and the sequence rule.

These tags are fixed. If the configuration already uses one of them with a different type, the card reports a collision and does not overwrite it; rename the existing plugin in Advanced Mode first. The generic plugin field sections also stop showing these managed plugins.

### 3.9 Local Hosts

The `Hosts` card manages one `hosts` plugin with a fixed tag, so local name records can be added without Advanced Mode:

- Before configuration it shows the `Enable hosts` button. The button needs at least one server entry sequence; when none exists it stays disabled and asks you to configure a server entry in Advanced Mode first.
- Clicking `Enable hosts` creates the `oxidns_hosts` plugin and inserts this step into every entry sequence:

```yaml
- exec: $oxidns_hosts
```

  The step runs after the ad filtering block step and before the cache step and `forward`. Enabling writes `short_circuit: true` by default so a matching record ends the chain; unmatched queries continue through the remaining steps.
- Once enabled, the card shows every hosts field from the schema:

| Field | Description |
| --- | --- |
| `Hosts entries` (`entries`) | One record per line in `name address` form, for example `router.lan 192.168.10.1`. |
| `Hosts files` (`files`) | Referenced hosts files, one path per line, for example `/etc/hosts`. |
| `Short circuit` (`short_circuit`) | Ends the chain on a match. Enabled by default when the card creates the plugin. |

  Fields you do not edit are not written, so the OxiDNS core defaults apply.
- `Remove hosts` deletes the `oxidns_hosts` plugin and the hosts step from every sequence.

If the configuration already has a `hosts` plugin under another tag, the card only points to Advanced Mode and does not create a second one. If the `oxidns_hosts` tag is already used by another plugin type, the card reports a collision; rename that plugin in Advanced Mode first.

### 3.10 Cache

The `Cache` card manages one `cache` plugin with a fixed tag:

- Before configuration it shows the `Enable cache` button. The button needs at least one server entry sequence; when none exists it stays disabled and asks you to configure a server entry in Advanced Mode first.
- Clicking `Enable cache` creates the `oxidns_cache` plugin and inserts this step into every entry sequence:

```yaml
- exec: $oxidns_cache
```

  The step runs after the ad filtering block step and the hosts step, and before `forward`; when neither exists it sits at the front of the sequence. Enabling writes `short_circuit: true` by default so a cache hit ends the chain; misses continue through the remaining steps.
- Once enabled, the card shows every cache field from the schema: `size`, `lazy_cache_ttl`, `dump_file`, `dump_interval`, `short_circuit`, `cache_negative`, `max_negative_ttl`, `negative_ttl_without_soa`, `max_positive_ttl`, `min_positive_ttl`, and `ecs_in_key`. Fields you do not edit are not written, so the OxiDNS core defaults apply.
- `Remove cache` deletes the `oxidns_cache` plugin and the cache step from every sequence.

If the configuration already has a `cache` plugin under another tag, the card only points to Advanced Mode and does not create a second one. If the `oxidns_cache` tag is already used by another plugin type, the card reports a collision; rename that plugin in Advanced Mode first.

### 3.11 Common Plugin Fields

Normal Mode renders fields from the schema for each plugin type already present. Labels are English; the defaults below come from the current schema.

#### forward

| Field | Description |
| --- | --- |
| `Concurrent upstreams` (`concurrent`) | Number of concurrent upstream queries, 1–32, default 1. |
| `Response selection` (`response_selection`) | Response selection with multiple upstreams: `fastest`, `balanced` (default), `prefer_positive`, or `consensus`. |
| `Short circuit` (`short_circuit`) | Stop processing the rest of the sequence after a hit. |

#### cache

| Field | Description |
| --- | --- |
| `Cache size (entries)` | Cache entries, minimum 0, default 1024. |
| `Override TTL (seconds)` | Window for serving a stale response after the original TTL expires while refreshing asynchronously; minimum 0. |
| `Dump file` | Cache snapshot file path. |
| `Dump interval (seconds)` | Snapshot interval, default 600. |
| `Short circuit` | Stop after a cache hit. |
| `Cache negative responses` | Cache negative responses, enabled by default. |
| `Max negative TTL (seconds)` | Maximum negative TTL, default 300. |
| `Negative TTL without SOA (seconds)` | Negative TTL when no SOA is present, default 60. |
| `Max positive TTL (seconds)` | Maximum positive TTL. |
| `Min positive TTL (seconds)` | Minimum positive TTL. |
| `Include ECS in cache key` | Include ECS in the cache key. |

#### hosts

| Field | Description |
| --- | --- |
| `Hosts entries` | Inline hosts records, one per line, such as `example.com 192.0.2.1`. |
| `Hosts files` | Hosts files, one path per line, such as `/etc/hosts`. |
| `Short circuit` | Stop after a hit. |

#### black_hole

| Field | Description |
| --- | --- |
| `Blocking mode` | `nxdomain`, `nodata`, `null`, `custom`, or `refused`. |
| `Answer addresses` | Addresses returned in `custom` or `null` mode, one per line, such as `0.0.0.0`. |
| `Short circuit` | Stop after a hit. |

#### fallback

| Field | Description |
| --- | --- |
| `Primary executor` | Primary executor tag. |
| `Standby executor` | Standby executor tag. |
| `Slow threshold (ms)` | Threshold for treating the primary as slow, default 0. |
| `Always run standby` | Always run the standby executor in parallel. |
| `Short circuit` | Stop after a hit. |

#### ip_selector

| Field | Description |
| --- | --- |
| `Selection mode` | `first_success` (default), `best_within_budget`, or `background`. |
| `Outbound profile` / `SOCKS5 proxy` | Outbound profile or proxy used for probing. |
| `Probe methods` | Probe methods, one per line; defaults `tcp:443`, `tcp:80`. |
| `Probe stagger (ms)` | Delay between probes, default 200. |
| `Probe timeout (ms)` | Per-probe timeout, default 600. |
| `Max wait (ms)` | Maximum total wait, default 1000. |
| `Top N addresses` | Number of addresses to keep, default 1. |
| `DNSSEC policy` | `reorder_only` (default) or `skip`. |
| `Max parallel probes` | Maximum parallel probes, default 256. |
| `Enable probe cache` | Cache probe results, enabled by default. |
| `Probe cache size` | Probe cache entries, default 4096. |
| `Success TTL (seconds)` | Success cache duration, default 3600. |
| `Failure TTL (seconds)` | Failure cache duration, default 60. |

#### prefer_ipv4 / prefer_ipv6

| Field | Description |
| --- | --- |
| `Probe executor` | Executor tag used for the internal preferred-address probe. |
| `Cache preferred state` | Cache the preferred state, enabled by default. |
| `Preferred state TTL (seconds)` | Preferred state cache duration, default 3600. |

`prefer_ipv4` and `prefer_ipv6` take the same fields; only the preferred address family differs. They are `with_next` executors and must appear in the entry sequence **before** `forward`; any other placement, including after `forward`, does nothing. Advanced Mode example:

```yaml
plugins:
  - tag: prefer_ipv4_main
    type: prefer_ipv4
    args: {}

  - tag: forward_main
    type: forward
    args:
      upstreams:
        - addr: "223.5.5.5"

  - tag: main_sequence
    type: sequence
    args:
      - exec: $prefer_ipv4_main
      - exec: $forward_main
```

`probe_executor` is optional. When omitted, the probe query reuses the downstream continuation; when set, it must point to an executor that can answer queries, such as another `forward`.

#### learn_domain

| Field | Description |
| --- | --- |
| `Target dynamic domain set` | Provider tag of the destination dynamic domain set. |
| `Learning phase` | `before` or `after` (default). |
| `Questions` | `first` (default) or `all`. |
| `Query types` | Query types to learn; defaults `A`, `AAAA`. |
| `Require success (NOERROR)` | Learn only NOERROR, enabled by default. |
| `Require an answer` | Require an answer, enabled by default. |
| `Rule kind` | `full` (default) or `domain`. |
| `Asynchronous` | Learn asynchronously, enabled by default. |
| `Error handling` | `continue` (default), `stop`, or `fail`. |
| `Timeout` | Timeout, default `1s`. |

#### query_recorder

| Field | Description |
| --- | --- |
| `Database path` | SQLite database path, such as `/tmp/oxidns/query.db`. |
| `Queue size` | Queue length, default 8192. |
| `Batch size` | Rows per batch, default 256. |
| `Flush interval (ms)` | Flush interval, default 200. |
| `In-memory tail size` | In-memory tail rows, default 1024. |
| `Retention days` | Retention in days, default 7. |
| `Cleanup interval (hours)` | Cleanup interval, default 1 hour. |
| `Reader concurrency` | Reader concurrency, default 2. |

#### reverse_lookup

| Field | Description |
| --- | --- |
| `Cache size (entries)` | Reverse mapping cache entries, default 65535. |
| `Mapping TTL (seconds)` | Mapping cache duration, default 7200. |
| `Answer PTR from cache` | Answer PTR queries directly from the cache, disabled by default. |

#### ttl

| Field | Description |
| --- | --- |
| `Fixed TTL (seconds)` | Fixed TTL; overrides the TTLs in responses when set. |
| `Minimum TTL (seconds)` | Minimum TTL. |
| `Maximum TTL (seconds)` | Maximum TTL. |

Processing order is `fix` → `min` → `max`; when both bounds are set, the maximum caps the final TTL.

#### download

| Field | Description |
| --- | --- |
| `Downloads` | List of download entries. Each entry has a `URL`, plus `Target directory` and `File name`. Entries can be added and removed individually. |
| `Timeout` | Download timeout, such as `30s`. |
| `Skip TLS verification` | Skip TLS verification for downloads. |
| `Outbound profile` / `SOCKS5 proxy` | Outbound profile or proxy for downloads. |
| `Download at startup when missing` | Download missing files at startup, enabled by default. |

#### query_summary / metrics_collector / debug_print / sleep

| Plugin | Field | Description |
| --- | --- | --- |
| `query_summary` | `Summary label` (`msg`) | Extra label for the periodic query summary. Defaults to `query summary`. |
| `metrics_collector` | `Metrics namespace` (`name`) | Metrics namespace. Defaults to `default`. Metrics are exposed through `GET /api/metrics`. |
| `debug_print` | `Message` (`msg`) | Extra message written to the debug log. Defaults to `debug print`. |
| `sleep` | `Sleep duration (ms)` (`duration`) | Sleep duration as an integer number of milliseconds. Defaults to `0`, which means no delay. |

None of these fields is required. The core accepts empty arguments (`args: {}`), so Normal mode does not refuse to save because a field is empty. The form shows the core defaults, but writes them only when the field is actually changed.

#### ipset

| Field | Description |
| --- | --- |
| `IPv4 set name` (`set_name4`) | IPv4 set name. |
| `IPv6 set name` (`set_name6`) | IPv6 set name. |
| `IPv4 prefix length` (`mask4`) | IPv4 prefix length, 0–32, default 24. |
| `IPv6 prefix length` (`mask6`) | IPv6 prefix length, 0–128, default 32. |

The sets must already exist in the firewall or be created with `ipset`; every field may be empty.

#### nftset

| Field | Description |
| --- | --- |
| `IPv4 table family` (`ipv4.table_family`) | IPv4 table family, for example `ip`. |
| `IPv4 table name` (`ipv4.table_name`) | IPv4 table name, for example `mangle`. |
| `IPv4 set name` (`ipv4.set_name`) | IPv4 set name. |
| `IPv4 prefix length` (`ipv4.mask`) | IPv4 prefix length, 0–32, default 24. |
| `IPv6 table family` (`ipv6.table_family`) | IPv6 table family, for example `ip6`. |
| `IPv6 table name` (`ipv6.table_name`) | IPv6 table name. |
| `IPv6 set name` (`ipv6.set_name`) | IPv6 set name. |
| `IPv6 prefix length` (`ipv6.mask`) | IPv6 prefix length, 0–128, default 48. |

Notes:

- Normal mode edits the structured `ipv4` / `ipv6` target objects. The compatibility-form flat fields (`table_family4`, `table_name4`, `set_name4`, `mask4`, and their IPv6 counterparts) remain editable only in Advanced mode.
- The `ipv4` / `ipv6` targets may be omitted entirely; when a target is configured, its `table_family`, `table_name`, and `set_name` fields are required. The sets must already exist in nftables.

#### Other Plugins

| Plugin | Main fields |
| --- | --- |
| `domain_set` | `Inline domain expressions`, `Referenced domain sets`, `Rule files`; list fields take one item per line. |
| `ip_set` | `Inline IP/CIDR rules`, `Referenced IP sets`, `Rule files`. |
| `geosite` | `GeoSite data file`, `Selectors`. |
| `geoip` | `GeoIP data file`, `Selectors`. |
| `adguard_rule` | `AdGuard rules`, `Rule files`. |
| `dynamic_domain_set` | `Rules file`, `Bootstrap rules`, `Queue size` (1024), `Batch size` (256), `Flush interval (ms)` (200). |
| `tcp_server` | `TLS certificate`, `TLS private key`, `Idle timeout` (default 10). |
| `http_server` | `DoH entries` (each with `Request path`, `Entry executor`, and `Enable JSON DNS API`), `HTTP listen`, `Client IP header`, `TLS certificate`, `TLS private key`, `Idle timeout` (default 30), `Enable HTTP/3`. |
| `quic_server` | `TLS certificate`, `TLS private key`, `Idle timeout`. |

List fields (`entries`, `files`, `selectors`, `rules`, and similar) take **one item per line**. Clearing a list removes the key; a default list is written only when it was actually changed.

Object-list fields (`Downloads`, `DoH entries`) can add and remove entries individually. Numeric ranges and enum values of each entry are validated before saving; fields inside an entry may stay empty, matching the core. A DoH entry's `Entry executor` is a dropdown of the plugin tags defined in the configuration (sequences first, other plugins under `Other plugins`), so it cannot point at a missing plugin by typo; when the configuration pulls in plugins through `include`, it falls back to a text input.

### 3.12 Plugin Overview

The read-only `Plugins` section at the bottom shows:

- `Tag`: instance tag;
- `Type`: plugin type;
- `Arguments`: argument summary (object keys, or step count for arrays);
- `Status`: whether the core supports the type.

`Status` comes from:

- the installed core's plugin type list, when the core is installed;
- a built-in catalog otherwise.

“Not supported by this core” means the core lacks the plugin type; “Unknown plugin type” means even the built-in catalog does not recognize it.

This section never modifies the configuration. Use Advanced Mode or the WebUI plugin center to add, remove, or adjust plugins.

---

## 4. Common Tasks

### 4.1 Change Upstream DNS

1. Open `DNS Configuration -> Normal Mode`.
2. If the `Upstream DNS` section reports that no forward plugin exists, click `Create forward plugin`; the page creates the `forward` plugin and wires it into the entry sequences.
3. Find the target `forward` plugin under `Upstream DNS`.
4. Pick a preset or type a custom address.
5. To add more upstreams, pick or enter another address in the `Add upstream DNS` combobox; each selection appends one upstream. Upstreams left at "Select or input an upstream DNS server" are not saved.
6. Click `Validate`, then `Save and Apply`.

### 4.2 Use DoH / DoT / DoQ Upstreams

1. Choose or enter an encrypted address, such as `https://dns.alidns.com/dns-query`, `tls://1.1.1.1`, or `quic://dns.alidns.com`.
2. For hostname-based addresses, expand `Options` and fill `Dial address` or `Bootstrap server` to avoid self-resolution.
3. Enable `Skip TLS verification` only for private certificates or test environments.
4. Click `Validate`, then `Save and Apply`.

### 4.3 Change the Listen Address or Port

1. Edit `Listen` for the relevant server under `Listen Addresses`.
2. Choose the entry sequence from the `Entry` dropdown (usually `main_sequence`).
3. Click `Save and Apply`.
4. Test with `nslookup -po=<port> example.com 127.0.0.1` or the matching address.

To use port 53, stop whatever else occupies it (usually dnsmasq's DNS function). The recommended setup keeps dnsmasq and forwards to port 5335; see [4.9 Forward Through dnsmasq (Recommended)](#49-forward-through-dnsmasq-recommended).

### 4.4 Enable Caching

1. In Normal Mode, click `Enable cache` in the `Cache` card. If no server entry sequence exists, configure one in Advanced Mode first.
2. The card creates the `oxidns_cache` plugin and inserts `- exec: $oxidns_cache` into the entry sequences; with ad filtering or the hosts step it goes after them, otherwise at the front of the sequence.
3. Adjust cache size, TTLs, and negative caching as needed; fields you do not edit are not written.
4. Click `Save and Apply`.

You can also add a `cache` plugin under any tag in Advanced Mode and reference it from a sequence; such plugins stay under Advanced Mode control and the Normal Mode card does not overwrite them.

### 4.5 Add Local Hosts Entries

#### The Normal Mode Hosts card (recommended)

1. Open `DNS Configuration -> Normal Mode` and find the `Hosts` section.
2. If there is no hosts plugin yet, click `Enable hosts`. LuCI creates the `oxidns_hosts` plugin and inserts the hosts step into every entry sequence, after ad filtering and before the cache step and forwarding.
3. Write one record per line in `Hosts entries`:

```text
router.lan 192.168.1.1
nas.lan 192.168.1.10
```

4. `Hosts files` can reference a system hosts file such as `/etc/hosts`.
5. Click `Validate`, then `Save and Apply`.

Records use the form `name address` or `name hostname`, and a name may have several records (for example an IPv4 and an IPv6 address). Queries that match no record continue through the cache and `forward`.

If the configuration already has a `hosts` plugin under another tag, the card only points you to Advanced Mode and does not create a second one.

#### Manual configuration in Advanced Mode

Normal Mode also renders fields for an existing `hosts` plugin, but only when the plugin is already in the configuration. When creating one by hand, set `short_circuit: true`, otherwise the later `forward` step overrides the hosts answer:

```yaml
- tag: local_hosts
  type: hosts
  args:
    short_circuit: true
    entries:
      - "router.lan 192.168.1.1"

- tag: main_sequence
  type: sequence
  args:
    - exec: $local_hosts
    - exec: $forward
    - exec: accept
```

### 4.6 Block Ads or Specific Domains

#### Use the Normal Mode ad filtering card (recommended)

1. Open `DNS Configuration -> Normal Mode` and find the `Ad filtering` area.
2. Click `Add ad filtering`. The page creates the `oxidns_ads_download`, `oxidns_ads_rules`, and `oxidns_ads_block` plugins and inserts the blocking rule at the front of every server entry sequence.
3. Enter one ad-rule subscription URL per line under `Subscription URLs`, such as `https://example.com/adblock.txt`; alternatively enter `||ads.example.com^` under `Inline rules` or an existing rule file path under `Local rule files`.
4. Choose a `Blocking mode` when needed; `custom` mode also needs `Blocking addresses`.
5. Click `Validate`, then `Save and Apply`.

Subscription files are downloaded only when missing at startup, and a failed download fails startup. Make sure the router can reach the subscription URLs before enabling it. Existing files are not refreshed automatically; trigger a download manually or restart after deleting them.

#### Compose the plugins manually in Advanced Mode

A common pattern combines `domain_set` / `geosite` / `adguard_rule` with `black_hole`. `black_hole` must set `short_circuit: true`; otherwise the following `forward` overwrites the blocked response:

```yaml
- tag: ads
  type: adguard_rule
  args:
    rules:
      - "||ads.example.com^"

- tag: block_ads
  type: black_hole
  args:
    mode: nxdomain
    short_circuit: true

- tag: main_sequence
  type: sequence
  args:
    - matches: "qname $ads"
      exec: $block_ads
    - exec: $forward
    - exec: accept
```

Without the ad filtering card, Normal Mode can still edit fields of existing `black_hole`, `domain_set`, and `adguard_rule` instances, but sequence rules belong in Advanced Mode or the WebUI.

### 4.7 Change Logging

1. Set `Log level` to `debug` temporarily when troubleshooting; keep `info` or `warn` day to day.
2. Point `Log file` at a persistent path to survive reboots.
3. Set `Rotation` and `Maximum rotation files` to prune old logs (leave it empty to keep all files).
4. Click `Save and Apply`.

### 4.8 Backup, Restore, and Roll Back

- Backup: `DNS Configuration -> Download Config`, then keep the downloaded `config.yaml`.
- Restore: `DNS Configuration -> Upload Config` with a file named `config.yaml`. Upload validates and saves but does not restart; then click `Save and Apply` or restart manually.
- Inspect changes: `Change Preview` shows only page edits relative to the on-disk file.
- The backend also backs up the old file under `config-backups/` in the working directory (for example `/var/lib/oxidns/config-backups/`), which you can restore manually.

### 4.9 Forward Through dnsmasq (Recommended)

OxiDNS's `udp_server` / `tcp_server` plugins listen on `:5335` by default, while port 53 on OpenWrt belongs to dnsmasq, which also serves DHCP. The recommended setup keeps dnsmasq and lets it forward queries to OxiDNS, so LAN DHCP, `xxx.lan` hostnames and lease names keep working and clients need no changes.

LuCI provides a `System DNS integration` card on `Services -> OxiDNS -> Basic Information`. Once its checks pass, it performs the dnsmasq changes described under "Manual Configuration" in one click and can be disabled and rolled back the same way. It modifies only `/etc/config/dhcp` (dnsmasq upstreams and `noresolv`) and **never touches** `/etc/oxidns/config.yaml`.

#### Enable In One Click

Prerequisites:

- OxiDNS is installed and running;
- OxiDNS's UDP and TCP listeners use **the same port** and share a reachable IPv4 address, for example both on `127.0.0.1:5335`;
- When OxiDNS listens on `:port`, `0.0.0.0:port`, or `127.0.0.1:port`, the forwarding target is `127.0.0.1`. If UDP and TCP use different ports, share no reachable IPv4 address, or listen on IPv6 only (`[::]:port`, `[::1]:port`), no reliable target can be determined and the `Enable dnsmasq forwarding` button stays unavailable.
- With a `:port` listen entry, OxiDNS may actually bind the IPv6 wildcard (`:::port`) in the kernel. As long as `bindv6only=0` (the OpenWrt default), `127.0.0.1` still works and LuCI detects the listener correctly.

Steps:

1. Open `Services -> OxiDNS -> Basic Information` and find the `System DNS integration` card. It shows the dnsmasq status, integration status, OxiDNS listen target, dnsmasq generic upstreams (the current value before enabling, the saved pre-enable value afterwards), domain-specific upstreams, and the current `noresolv` value. Empty lists show `None`, and a target that is not listening is marked `(not listening)`.
2. Click `Enable dnsmasq forwarding`. The confirmation dialog lists the changes:
   - remove the current generic upstreams, recording their original values;
   - add a forwarding entry pointing at OxiDNS, for example `127.0.0.1#5335`;
   - set `noresolv=1`, recording the original value;
   - keep `/domain/...` domain-specific upstreams.
   These original values are stored in the `dns_integration` section of `/etc/config/oxidns` so they can be restored later. If an identical forwarding entry was already added manually, it is recorded as a previous generic upstream and is restored as it was on disable.
3. After you confirm, the backend saves the pre-enable state, writes `/etc/config/dhcp`, and reloads dnsmasq. The card then shows the integration as enabled, the forwarding target, and the recorded pre-enable upstreams.

Verify:

```sh
nslookup -po=5335 www.baidu.com 127.0.0.1   # OxiDNS directly
nslookup www.baidu.com 192.168.1.1          # through dnsmasq; use the router LAN address
```

You can also query the router address directly from a LAN client; the answer should match a direct query to OxiDNS.

#### Status And Warnings

The card keeps reading the live configuration and compares it with the saved state, and reports these cases:

- the forwarding entry was removed manually;
- the OxiDNS listen address or port changed and no longer matches the recorded target;
- `noresolv` was changed by something else;
- dnsmasq or OxiDNS has stopped.

If any of these drift, follow the hint to re-enable or simply disable the integration to return to a known state.

#### Disable And Restore

After you click `Disable dnsmasq forwarding` and confirm, the backend:

1. removes only the forwarding entry that `dns_integration` recorded for this feature;
2. restores the pre-enable generic upstreams, without adding duplicates;
3. restores `noresolv` to its pre-enable value, or removes the option if it was unset before;
4. commits UCI, reloads dnsmasq, and clears the `dns_integration` record.

After disabling, dnsmasq is back to its pre-enable upstream configuration, and OxiDNS keeps running from `config.yaml` as before.

#### Failure Behavior And Caveats

- **Fail-closed**: while the integration is enabled, stopping OxiDNS makes LAN queries through dnsmasq time out or fail instead of bypassing OxiDNS. Start OxiDNS again, or disable the integration first. LuCI shows a warning confirmation when you click `Stop` while it is enabled.
- **No port 53 takeover**: dnsmasq keeps listening on 53, so DHCP, local names, and lease resolution keep working. To have OxiDNS bind port 53 directly, see the alternative deployment at the end of this section.
- If you edited dnsmasq's generic upstreams manually, disabling restores the snapshot taken when the integration was enabled; later manual edits are not merged.
- Never expose dnsmasq's port 53 or OxiDNS's port 5335 to the WAN.

#### Manual Configuration (Without The One-Click Feature)

1. Open `Services -> OxiDNS -> DNS Configuration`, change both DNS servers under `Listen Addresses` in Normal mode to the loopback address, then click `Save and Apply`:

```yaml
  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:5335"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:5335"
```

Upstream servers are configured in the `forward` plugin's `upstreams`, which defaults to `223.5.5.5`.

2. Point dnsmasq at OxiDNS:

```sh
uci set dhcp.@dnsmasq[0].noresolv='1'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

`noresolv=1` makes dnsmasq ignore `/tmp/resolv.conf.d/resolv.conf.auto`, so a WAN reconnect cannot silently bypass OxiDNS.

3. Verify:

```sh
nslookup -po=5335 www.baidu.com 127.0.0.1   # OxiDNS directly
nslookup www.baidu.com 127.0.0.1            # through dnsmasq
```

Queries through dnsmasq should time out while OxiDNS is stopped and recover when it starts again, which confirms the traffic really goes through OxiDNS.

Roll back with:

```sh
uci set dhcp.@dnsmasq[0].noresolv='0'
uci -q delete dhcp.@dnsmasq[0].server
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Note: `delete dhcp.@dnsmasq[0].server` removes every `server` entry, including `/domain/...` domain-specific upstreams. If you have any, record them with `uci show dhcp.@dnsmasq[0]` first and add them back after rolling back. The one-click `System DNS integration` disable removes only its own entry and restores the pre-enable upstreams automatically, leaving domain-specific upstreams untouched.

If OxiDNS needs to apply per-client policies based on the source address, it can listen on port 53 instead: run `uci set dhcp.@dnsmasq[0].port='0'` to turn off dnsmasq's DNS function (DHCP keeps working), make sure DHCP still advertises the router as DNS, then change both `listen` values above to `":53"`. The trade-offs are that `xxx.lan` hostnames, DHCP lease names and dnsmasq's rebind protection no longer apply, and IPv6 clients require OxiDNS to listen on IPv6 as well, for example `"[::]:53"`.

Either way, never expose port 53 or 5335 to the WAN, or the router becomes an open resolver.

---

## 5. Advanced Mode

`Advanced Mode` is a full YAML editor for the entire `config.yaml`. Use it to:

- add or remove plugins;
- write sequence and matcher rules;
- configure `network.outbound.profiles`, sequence/rules, and other fields not covered by Normal Mode;
- configure API authentication, TLS, and CORS;
- edit plugin arguments Normal Mode does not cover.

### 5.1 Complete Configuration Structure

```yaml
runtime:
  worker_threads: 4

api:
  http:
    listen: "0.0.0.0:9199"
    webui:
      root: "/usr/share/oxidns/webui"
      index: "index.html"

log:
  level: info
  file: "/tmp/oxidns/oxidns.log"
  rotation:
    type: daily
    max_files: 7

network:
  outbound:
    default: direct
    profiles:
      direct:
        resolver: system
        proxy: none

include: []

plugins:
  - tag: cache_main
    type: cache
    args:
      size: 4096
      short_circuit: true
      cache_negative: true

  - tag: forward
    type: forward
    args:
      upstreams:
        - addr: "223.5.5.5"

  - tag: main_sequence
    type: sequence
    args:
      - exec: $cache_main
      - exec: $forward
      - exec: accept

  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: ":5335"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: ":5335"
```

### 5.2 Common Advanced Edits

**Authentication and TLS for the WebUI:**

```yaml
api:
  http:
    listen: "0.0.0.0:9199"
    auth:
      type: basic
      username: "admin"
      password: "${OXIDNS_API_PASSWORD}"
    ssl:
      cert: "/etc/oxidns/api.crt"
      key: "/etc/oxidns/api.key"
    webui:
      root: "/usr/share/oxidns/webui"
      index: "index.html"
```

`auth.username` and `auth.password` must both be non-empty, and `ssl.cert` and `ssl.key` must be provided together.

**Add another listen port:**

```yaml
  - tag: udp_server_lan
    type: udp_server
    args:
      entry: main_sequence
      listen: "0.0.0.0:5353"
```

**Add a sequence rule (block a domain set):**

```yaml
  - tag: ads
    type: domain_set
    args:
      files:
        - "/etc/oxidns/ads.txt"

  - tag: block_ads
    type: black_hole
    args:
      mode: nxdomain
      short_circuit: true

  - tag: main_sequence
    type: sequence
    args:
      - matches: "qname $ads"
        exec: $block_ads
      - exec: $forward
      - exec: accept
```

**Include external configuration files:**

```yaml
include:
  - /etc/oxidns/plugins/common.yaml
```

`include` merges only the `plugins` of the included files. Relative paths are resolved from the directory of the file that declares the `include`, at most 8 levels deep, and merged tags must be globally unique.

**Configure outbound networking:**

```yaml
network:
  outbound:
    default: direct
    profiles:
      direct:
        resolver: system
        proxy: none
      remote:
        resolver:
          nameservers:
            - addr: "1.1.1.1:53"
            - addr: "tls://dns.google:853"
              dial_addr: 8.8.8.8
          ip_version: 4
          timeout: 5s
          proxy: none
        proxy:
          socks5: 127.0.0.1:1080
```

### 5.3 Advanced Mode Cautions

- Always click `Validate` before saving. Valid YAML does not mean a valid OxiDNS configuration; the backend runs the full `oxidns check`.
- Saving writes the editor text exactly and does not reformat or preserve comments you deleted.
- Every `tag` must be unique, 1–64 ASCII characters using letters, digits, `_`, `-`, and `.`; each dot-separated segment must start and end with a letter or digit. The prefixes `qs.exec.`, `qs.match.`, and `qs.cron.` are reserved.
- After renaming a tag, update every `$tag`, `jump`/`goto`, and dependency reference.
- `${VAR}` placeholders are expanded by OxiDNS at startup and during `oxidns check`; undefined variables fail validation and the file is never rewritten.
- Except for `include` paths, relative paths in the configuration are resolved from the working directory (default `/var/lib/oxidns`), not from the configuration file's directory.
- YAML anchors, aliases, or merge keys make Normal Mode read-only.

---

## 6. Configure DNS Through The WebUI

The OxiDNS WebUI is the core's built-in graphical interface. It edits the same `config.yaml` as the LuCI `DNS Configuration` page and is convenient for managing plugins, sequences, query records, caches, and upgrades in a browser.

### 6.1 Open the WebUI From LuCI

1. Confirm the OxiDNS service is running.
2. Open `Services -> OxiDNS -> Basic Information`.
3. Click `Open WebUI` in the `WebUI` row.

The button requires all of the following:

- the core is installed;
- WebUI files are installed (the `full` or `standard` bundle);
- the OxiDNS service is running;
- the configuration has a usable `api.http` listen address.

When unavailable, the page explains why:

| Message | Fix |
| --- | --- |
| Install the OxiDNS core before using WebUI. | Install the core first. |
| The installed minimal core bundle does not include WebUI files... | Click `Install WebUI` on `Installation and Deployment` to download a bundle with WebUI. |
| WebUI files are not installed. | Click `Install WebUI` on `Installation and Deployment`. |
| Start the OxiDNS service before opening WebUI. | Click `Start` on `Basic Information`. |
| WebUI listens on loopback only... | Change `api.http.listen` to the LAN address or `0.0.0.0:9199`, or use an SSH tunnel. |

URL rules:

- For `0.0.0.0` or `[::]`, the host used to reach the router in the browser replaces the wildcard.
- A specific LAN address is used directly.
- For `127.0.0.1` / `::1`, the link remains but only works on the router itself or through an SSH tunnel.

### 6.2 Configuration Required for the WebUI

The WebUI requires the **expanded** `api.http` form:

```yaml
api:
  http:
    listen: "0.0.0.0:9199"
    webui:
      root: "/usr/share/oxidns/webui"
      index: "index.html"
```

If the configuration currently uses the shorthand:

```yaml
api:
  http: "0.0.0.0:9199"
```

click `Convert to expanded form` in `DNS Configuration -> Normal Mode`, switch to the expanded form manually in `Advanced Mode`, or enable the WebUI under `System Settings -> Management API -> WebUI static files` in the WebUI. The shorthand serves only the API.

The WebUI and management API are same-origin:

- the WebUI is mounted at `/`;
- the API is mounted at `/api/*`;
- the front end calls `/api/health`, `/api/config`, `/api/plugins/...`.

Do not configure a separate CORS origin for the WebUI unless you use nginx or an online console.

### 6.3 First Connection and Login

1. If `api.http.auth` (Basic Auth) is enabled, the page asks for credentials.
2. Enter `auth.username` and `auth.password`.
3. Optionally enable `Remember login` to reuse saved credentials.
4. The page shows `Connecting to backend`; on success it opens the dashboard.

If it reports no backend connection:

1. Open `System Settings -> Backend Service`.
2. Keep `Service address` at the default `/api` when served same-origin.
3. Click `Save address` or `Reconnect`.
4. If nginx serves the WebUI, proxy `/api/*` to `api.http.listen` without stripping `/api`.

### 6.4 Layout and Two Modes

The sidebar contains:

- `Dashboard`
- `Plugin Center`
- `Runtime Logs`
- `System Settings`

The header/sidebar also offers:

- `Config Editor`: switch to the full YAML editor;
- `Documentation`: open the OxiDNS docs;
- `Software Upgrade`: check or perform a core upgrade, when the core includes the upgrade plugin;
- theme toggle;
- `Sign out`.

There are two modes:

- **Console mode**: dashboard, plugin center, logs, and system settings with graphical editing;
- **Editor mode**: the full YAML editor for bulk edits or inspecting the raw file.

Both modes edit the same configuration. Switching does not discard edits already in the page, but anything not saved or applied exists only in the browser.

### 6.5 Dashboard

The dashboard shows:

- **Service health**: uptime and running state;
- **CPU usage**: process CPU;
- **DNS QPS**: recent average query rate;
- **Memory**: RSS, working set, commit;
- **Plugin totals**: plugin count and server count;
- **Configuration status**: valid or invalid;
- **Uptime**: days/hours/minutes/seconds.

Below are **pinned plugin** cards. Use the plugin menu in the Plugin Center and choose `Pin to dashboard`; drag to reorder. The order is stored only in the current browser and never written to the configuration.

### 6.6 Plugin Center

The Plugin Center is the core page. It lists instances by server, executor, matcher, and provider.

#### Browse and Filter

- Search by name, type, or configuration;
- filter by plugin type;
- cards show tag, type, runtime state, and key arguments;
- open a card for `Configuration` and `Statistics`/`Metrics` tabs.

#### Create a Plugin

1. Click `Add plugin` or `Create plugin`.
2. Choose the type (server, executor, matcher, provider).
3. Enter an instance name (tag). Rules: 1–64 ASCII characters using letters, digits, `_`, `-`, and `.`; `.` may not start, end, or repeat, and each dot-separated segment must start and end with a letter or digit; the prefixes `qs.exec.`, `qs.match.`, and `qs.cron.` are reserved.
4. Fill the form; types without form fields can be edited as advanced YAML.
5. Saving writes the draft/disk state; click `Apply changes` in the header to activate it.

#### Edit a Plugin

- Form mode: common fields with “reset to default” and “clear explicit value”.
- Advanced settings: edit that plugin's YAML directly with any valid arguments.
- `Negate match`: matcher-only, inverts the matcher result.
- Reference fields: choose an existing plugin, or use `Quick create plugin` and have the new tag filled in.
- Dependencies: initialization order, dependencies, and reverse references, with a topology view.

#### Delete a Plugin

The WebUI checks dependencies first:

- a plugin still referenced by others cannot be deleted directly;
- choose a compatible replacement, remove the references, or fix the configuration in the editor;
- deletion is saved to disk but not applied; click `Apply changes` after verifying.

#### Pin to the Dashboard

Use the plugin card menu to `Pin to dashboard` / `Unpin`. Pinned cards appear on the dashboard; their order stays in browser storage.

#### Runtime Metrics and Controls

The `Statistics` / `Metrics` tab shows runtime data. Some plugins offer runtime controls:

| Plugin | Runtime action |
| --- | --- |
| matcher | Force the base result to `true` or `false` to test a policy; reverts on reload or restart. |
| provider | `Reload data`: reread provider data with the current configuration without rebuilding other plugins; does not apply YAML or topology changes. |
| cache | Browse entries, filter by QNAME, delete one, flush all, export/import a `.dump`. |
| query_recorder | Browse query records, filter, live stream, clear history, inspect matcher hit rates and aggregate statistics. |
| dynamic_domain_set | View, add, delete, and clear rules; rules accept `full:`, `domain:`, `keyword:`, `regexp:`, and bare domains. |
| download | View the download list and trigger downloads, which overwrite the target files. |
| cron | View scheduled jobs and `Run now` an individual job. |

These affect runtime state only and do not modify the configuration unless the page explicitly says otherwise.

#### Sequence Editing

A `sequence` plugin detail provides a canvas/list editor:

- view and reorder rules;
- `IF · match condition` selects a matcher, `THEN · action` selects an executor;
- negate a matcher, move rules up/down, delete rules;
- `jump`/`goto` to other sequences, with loops shown as back-links;
- switch between reference, quick, text, and control-flow editing;
- save writes the plugin configuration; `Apply changes` is still required.

The `Topology` view shows dependencies, matcher conditions, executor targets, and sequence calls, which helps find dangling references and cycles.

### 6.7 Runtime Logs

`Runtime Logs` shows live OxiDNS output:

- `Connected` / `Disconnected` status;
- filter by level (all, trace, debug, info, warn, error);
- search by message or target;
- `Pause` / `Resume` for auto-scroll; new lines are counted while paused;
- `Wrap lines` toggle;
- time format (`YYYY`, `MM`, `DD`, `HH`, `mm`, `ss`, `SSS`);
- elapsed time since process start.

The log file itself is set by `log.file`; this page reads the backend stream and does not replace the LuCI `Runtime Logs` page.

### 6.8 System Settings

`System Settings` has several sections:

#### Backend Service

- `Service address`: defaults to `/api` when same-origin;
- `Save address`, `Reconnect`;
- current connection status.

#### Account and Security

- Set or change the Basic Auth username and password;
- changes require a restart;
- authentication can be disabled, but then anyone who can reach the management API can operate it; the page warns about this.

#### Runtime Status / Configuration Summary

- build version, platform, health, reload state;
- configuration path, version, plugin count, initialization order, validation status.

#### Runtime

- `Worker threads`: Tokio multi-threaded runtime workers; empty uses the system default; cannot be 0.

#### Outbound Network

- `Default outbound profile`: maps to `network.outbound.default`;
- each profile can set:
  - name;
  - SOCKS5 proxy;
  - resolver mode (system or custom nameservers);
  - IP version, resolve timeout, nameserver proxy;
  - nameserver list (UDP/TCP/DoT/DoH/DoH3/DoQ; hostname forms need `dial_addr`);
- shows per-profile resolver cache hits, refresh errors, and address-pool refreshes.

#### Management API

- `Listen address (listen)`: `ip:port`, `[ipv6]:port`, or `:port`;
- `TLS / SSL`: certificate, key, client CA, require client certificate;
- `Authentication (auth)`: points to Account and Security;
- `CORS allowed origins (cors.allowed_origins)`: one Origin per line; `*` allows any;
- `WebUI static files (webui)`: mounts the WebUI at `/` and the API at `/api/*`; set `root` and `index`.

#### Logs

- `Log level`: `off`, `trace`, `debug`, `info`, `warn`, `error`;
- `Log file path`: empty logs only to stdout;
- `Rotation strategy`: never/minutely/hourly/daily/weekly;
- `Maximum history files`: 0 or empty means unlimited.

#### Software Upgrade

- Check for updates, current/latest versions, and release notes;
- `Upgrade now`, `Force upgrade`;
- upgrade settings: GitHub repository, bundle (auto/full/standard/minimal), outbound profile, SOCKS5, GitHub token, allow prereleases, clear cache and back up, automatic check;
- shows the equivalent CLI command; the token is shown as a placeholder only;
- if the core lacks the upgrade plugin, online upgrade is unavailable; use `Update Core` on `Installation and Deployment` or the CLI.

### 6.9 Configuration Editor

After switching to `Config Editor`:

- the plugin index jumps to definitions;
- edit the full YAML with highlighting, indentation, undo/redo, and shortcuts;
- `Save`: writes to disk without applying;
- `Reset`: restores the on-disk content;
- `Download`: download the YAML;
- `Copy`: copy to clipboard;
- `Diff`: compare the original with the current text;
- `Config history`: browser-local snapshots with diff, rollback, delete, and clear;
- `Offline mode`: paste or upload `config.yaml` and edit locally without a backend; the result stays in memory, is lost on refresh, and must be copied or downloaded.

Configuration history is stored only in the current browser, scoped to the service instance. `Roll back this version` writes to disk and triggers a hot reload or restart according to what changed.

### 6.10 Apply, Reload, and Restart

After saving, the header shows configuration sync state:

- `Configuration synced`: disk and runtime agree;
- `Unapplied configuration changes`: click `Apply changes` for a hot reload;
- `Configuration error`: fix validation errors first;
- `Restart required`: top-level settings (`runtime`, `api`, `log`, and so on) changed and a hot reload cannot apply them.

Actions:

| Action | Effect |
| --- | --- |
| `View diff` | Compare the running version with the pending version. |
| `Discard changes · restore running` | Drop unapplied edits and restore the running configuration. |
| `Reload current configuration` | Reload the on-disk configuration. |
| `Restart service` | Replace the running process; DNS is briefly interrupted and in-memory caches are cleared. |

During a restart an overlay shows: saving, requesting restart, waiting for the switch, waiting for readiness, reloading. Let it finish; do not refresh or close the page.

### 6.11 Software Upgrade

`Software Upgrade` handles core self-upgrade:

1. Click `Check for updates` to see the current version, latest version, and release notes.
2. Click `Upgrade now` for a newer release, or `Force upgrade` to reinstall the same version.
3. Upgrade settings cover the GitHub repository, bundle, outbound profile, proxy, token, and prereleases.
4. The page shows stages: request, download and apply, wait for backend, verify version.
5. It reconnects automatically when finished.

Token guidance:

- Safe to persist: a personal device, a trusted LAN, an OS-protected browser profile, and HTTPS;
- Avoid persisting on shared computers or browser accounts, when remoting, or over plain HTTP across networks;
- The token is sent to the backend for checks and upgrades whether or not it is saved; prefer a fine-grained token with read-only access to the target repository.

If the core lacks the upgrade plugin, use `Update Core` / `Upload Core` on the LuCI `Installation and Deployment` page, or the CLI command shown on the page.

### 6.12 LuCI and WebUI Equivalents

| Goal | LuCI | OxiDNS WebUI |
| --- | --- | --- |
| Change log level/file | `DNS Configuration -> Normal Mode -> Log` | `System Settings -> Logs` |
| Change listen address/port | `DNS Configuration -> Normal Mode -> Listen Addresses` | `Plugin Center -> udp_server/tcp_server/quic_server -> Configuration` |
| Change upstream DNS | `DNS Configuration -> Normal Mode -> Upstream DNS` | `Plugin Center -> forward -> Configuration` |
| Add/remove plugins | `DNS Configuration -> Advanced Mode` | `Plugin Center -> Add plugin/Delete` |
| Change sequences | `DNS Configuration -> Advanced Mode` | `Plugin Center -> sequence -> Sequence editing` |
| Enable WebUI/auth/TLS | `DNS Configuration -> Advanced Mode` | `System Settings -> Management API` |
| Edit the full YAML | `DNS Configuration -> Advanced Mode` | `Config Editor` |
| View runtime logs | `Runtime Logs` (LuCI) | `Runtime Logs` (WebUI) |
| View query records/cache | Not available | Details of the matching plugin in the Plugin Center |
| Upgrade the core | `Installation and Deployment -> Update Core` | `Software Upgrade` |

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| “Configuration error” | YAML syntax error, wrong field type, reference to a missing tag | Open Advanced Mode to see the error, or fix it in the WebUI editor, then validate again. |
| Save reports a conflict | The file was changed by the WebUI, a script, or another session | Reload `DNS Configuration`, check the content, and save again. |
| `Save` succeeds but DNS behavior is unchanged | The file was written but the service was not restarted | Click `Save and Apply`, or `Apply changes` / `Restart service` in the WebUI. |
| A plugin is missing from Normal Mode | The instance does not exist or the type has no schema | Add it in Advanced Mode or the WebUI. |
| Normal Mode is read-only | The YAML uses anchors/aliases/merge keys | Edit in Advanced Mode, or remove the anchors. |
| `Open WebUI` is unavailable | Core missing, WebUI files missing, service stopped, or listen address unreachable | Follow the hint; install WebUI for a `minimal` core. |
| Browser cannot open the WebUI | Listening on `127.0.0.1`, firewall block, or port closed | Use the LAN address or `0.0.0.0:9199`; check the firewall and port. |
| WebUI login fails | Wrong credentials, or auth changed without a restart | Check `api.http.auth` and restart OxiDNS after changes. |
| WebUI cannot connect | `Service address` is not `/api`; nginx strips `/api`; backend down | Restore `/api`; check the proxy; confirm OxiDNS is running. |
| Deep links 404 after refresh | Static server lacks an `index.html` fallback | Serve with OxiDNS or add `try_files $uri $uri/ /index.html;` in nginx. |
| Runtime Logs page is empty | No `log.file`, unwritable path, or service stopped | Check `log.file` and directory permissions; fall back to stdout and `logread`. |
| DNS queries time out | Wrong listen address/port, unreachable upstream, firewall | Test directly with `nslookup`; check Listen Addresses and Upstream DNS. |
| Port already in use | dnsmasq or another DNS service owns 53/5335 | Use another port or stop the conflicting service. |

More backend errors appear on the `Runtime Logs` page. LuCI also writes service-control audit records tagged `luci-app-oxidns` to the system log.

---

## 8. Security Recommendations

- Never expose ports 53, 5335, or 9199 to the WAN. An open resolver is abused for DNS amplification.
- Bind the management API to the LAN; use an SSH tunnel or an authenticated reverse proxy for remote access.
- Enable Basic Auth in `api.http.auth` for LAN WebUI access and add HTTPS at the reverse proxy.
- Use `Skip TLS verification` only with trusted self-signed environments, never long-term for public upstreams.
- Use a least-privilege fine-grained GitHub token and avoid persisting it on shared browsers.
- Back up with `Download Config` before changes and keep a rollback copy before large edits.

---

## 9. Related Documentation

- OxiDNS official homepage: <https://oxidns.org/>
- OxiDNS core and WebUI source: <https://github.com/svenshi/oxidns>
- Global configuration reference: <https://oxidns.org/configuration/global>
- Sequence configuration reference: <https://oxidns.org/configuration/sequence>
- Rule configuration reference: <https://oxidns.org/configuration/rules>
- Plugin reference: <https://oxidns.org/plugin-reference/overview>
- WebUI deployment: <https://oxidns.org/webui>
