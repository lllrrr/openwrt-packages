# CFPick

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/urbanescavenger/CFPick/build.yml?style=for-the-badge&logo=GitHub)](https://github.com/urbanescavenger/CFPick/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/urbanescavenger/CFPick?style=for-the-badge)](https://github.com/urbanescavenger/CFPick/releases)

[中文说明](README.md)

**CFPick is a Cloudflare CDN IP optimizer: it measures from your own machine through a real proxy core and picks the fastest CDN edge IP for your particular line.**

*   **Candidates can come from the latest online preferred-IP list**: with the online source selected, every run downloads the current list (`IP:PORT#CC`, filterable by country and port). The default address is our merged library `Cloudflare-IP/main/ip_libs.txt` (an Action in that repository normalises and merges CM, IPDB, LancelotRar, HandsomeMJZ, HostMonit, VPS789 and more every hour); if GitHub is unreachable it falls back to the CM source `zip.cm.edu.kg/all.txt`. The field accepts several space/newline separated URLs, downloaded and merged with de-duplication; a failing source is skipped. Built-in IPv4 / IPv6 lists or a custom IP file also work. The list is only a set of candidates, not the answer.
*   **Real kernel, real connections**: each candidate IP is temporarily written into a node config, and your local mihomo / Xray-core kernel or your existing [PassWall](https://github.com/xiaorouji/openwrt-passwall) node brings up a local SOCKS proxy to make real connections to it and measure.
*   **Local optimum, not list ranking**: every candidate is latency-screened first, then the best few are ranked by a real fixed-size download; the winner is whatever actually performs best from your machine, not what someone else's list says.

Test flow: each candidate IP is written into a node (or handed to the local kernel), then probed through a local SOCKS with HTTP HEAD latency (`time_pretransfer`) across every candidate; next, each worker's N lowest-latency IPs download a real fixed-size file over the same chain and are ranked by measured throughput (MB/s). The best IP is written back to the node and other integrations.

CFPick ships in two deployment models:

*   **OpenWrt LuCI package** (`luci-app-cfpick`): runs the test through your existing PassWall nodes or the local kernel, then writes the best IP back to proxy nodes and DNS integrations.
*   **Debian / Ubuntu standalone** ([`debian/`](debian/README.md)): no OpenWrt or PassWall required; bundles two switchable, independently upgradable proxy cores, a Python-stdlib engine and a web console.

> **Renamed**: the project was originally `luci-app-cloudflarespeedtest`, then `luci-app-passwall-speedtest`; starting with **1.0.0** it is **CFPick**. Package `luci-app-cfpick`, UCI config `/etc/config/cfpick`, CLI `cfpick`. Previous settings are not migrated — reconfigure after upgrading.

## Requirements

*   **PassWall** (`openwrt-passwall`) supplies the node links (node source) and receives the best IPs; the test itself always uses the standalone core and never calls `run_socks`.
*   **curl** (hard dependency) for the latency probe.
*   At least one CF-CDN-fronted passwall node (VLESS / VMess / Trojan / SS …). SOCKS-type passwall nodes cannot be used as test nodes (their `address` IS the SOCKS server).

## Features

*   **Node-Based Latency Test**: Probes candidate Cloudflare IPs through your passwall node chain — finds the best CF IP *as seen from your proxy's egress*.
*   **Latency Screening + Real Download Test**: Latency first (cheap, covers every candidate); then, **after every worker has stopped probing**, the main process downloads a real fixed-size file through each worker's N lowest-latency IPs (default 5, max 10) over the same node chain, **one worker and one IP at a time**; `speed_download` from curl is converted to MB/s. The final best IP is picked by measured throughput; IPs whose download fails are dropped; if every download fails (e.g. the URL is unreachable through that node), the latency ranking is kept. Each IP gets its own SOCKS config, and the generated `/tmp/etc/passwall/<flag>.json` is verified to point at the candidate IP before a speed is accepted, so the number cannot come from an unrelated path. Downloads never overlap latency probing — otherwise workers still probing would compete with them for the router's WAN bandwidth and make the per-IP numbers incomparable. Fast-death: a candidate that downloads less than 1 MB in the first 5 seconds is aborted and marked failed (curl `--speed-limit`/`--speed-time`), so dead or crawling IPs no longer burn the full per-IP time limit. In iterative mode the download phase runs after convergence and does not count toward `iterate_minutes`.
*   **Retest Current Best IPs**: A dedicated button on the Plugin Settings page (CLI: `/usr/lib/cfpick/bin/cfpick.sh retest`) — it does **not** re-download the online IP list. Candidates come only from the current `result.csv` rows for each node plus that node's current `address`. Candidate source and scheduling are independent: by default it runs ONE latency round + the download test; if the time-boxed iterative test is also enabled, the same candidates go through each node's convergence loop until `iterate_minutes` elapses, dropping IPs that fail each pass. The best IP is written back as usual. Useful for quickly validating the existing best IPs after a scheduled run without pulling tens of thousands of candidates.
*   **Multi-Threaded Workers**: Passwall nodes selected in the Third-Party tab run as parallel workers — each tests all candidate IPs through its own chain and gets its own best IP written back. Concurrency is capped by `node_test_threads`.
*   **Fail-Fast Multi-Probe**: Each IP is probed `node_test_probes` times; if any probe fails, the IP is discarded immediately. Only IPs that succeed on all probes are kept, so the result is a stable one.
*   **Post-Run Monitoring**: After a worker commits a valid result, a detached monitor re-tests that result every `monitor_interval` seconds (default 60): a plain node probes the address written back (the worker's best IP in result.csv), while a node with a DDNS domain probes the domain (resolved first, preferring the best IP the record still points at). `monitor_failures` consecutive failures (default 1, i.e. a single failure) trigger a two-pass retest: first a quick retest (latency screening stops once `download_count` candidates pass, then the download stage), then a normal retest regardless of the quick result. If neither pass produced a fresh result (the current IP/candidates are dead), a third round re-fetches the normal candidate source. A node whose downloads all fail is not a valid result: it is not written back or published and it triggers the refresh. The monitor exits as soon as a scheduled/manual task takes the worker, and the successful task starts a fresh one. It performs one lightweight HEAD probe only — no IP selection, no write-back, no download lock — and skips a round while a download test is running. Each worker row shows a "monitor X ms" badge; details go to `/tmp/cfpick.log`. Set `monitor_enabled=0` to disable.
*   **Time-Boxed Iterative Test**: With `iterate_enabled`, each tested node runs its **own independent convergence loop** until `iterate_minutes` elapses: after its first pass it only re-tests the IPs that passed its previous pass, so its candidate pool shrinks toward the most stable, lowest-latency IPs. Nothing is written to result.csv or passwall mid-run. A node saves its result and exits early once its pool converges to **≤ the iterative convergence threshold** (`iterate_converge_count`, default 5, max 100), which is independent of the download-test candidate count (`download_test_count`) — no need to wait out the timer; at the end each node's final-pass results are printed to the log before one final merge writes every node's best IP.
*   **Proxy Integration**: Writes the best IP back to ssr / passwall / passwall2 / bypass / vssr nodes, and to HOST / MosDNS / astra-dns / Alibaba Cloud DDNS.
*   **Visual Charts**: History chart for latency trends; hovering/clicking a point shows that node's best IP, latency and measured download speed (latency only when no download test was run).
*   **Improved UI & Logs**: Redesigned status display; per-IP log lines like `进度: 走节点测速 [node] 5/30 (16%) - 1.2.3.4 延迟 87ms 丢包 0.00 [保留]`.
*   **Partial Results Saved on Stop**: Stopping mid-test triggers a trap that cleans up SOCKS, restores node addresses, and keeps the previous result if nothing new was measured. **When the user stops round one manually, the IPs that already passed latency still complete the download test** (up to 5 per worker, run one worker/IP at a time after all probing has stopped) before write-back. The same holds for the automatic early stop (after the first worker finishes): workers stopped early still get their already-passed IPs download-tested.
*   **Broad Integrations**: The best IP can be automatically applied to SSR+ / Passwall / PassWall2 / Bypass / Vssr / HOST / MosDNS / astra-dns / Alibaba Cloud DDNS.

## UI Pages

Only two entries under LuCI → Services → CFPick, similar to Lucky:

*   **Console**: shows the test status, the standalone console URL and an "Open web console" button; the actual operations happen in the standalone console. The "Standalone Engine" tab lives inside that console.
*   **Settings**: the console entry settings (enable, port, listen address, username, session timeout, open console, reset password) plus an **Online update** button: it downloads and installs the matching ipk / apk from the latest GitHub release. It is refused while a speed test is running; refresh the page after the update. All speed-test settings and operations still live in the console tabs.

## Standalone Web Console

The standalone console (`cfpick-web`) runs on its own port with its own login and management UI. LuCI's Settings page only configures the console entry; all speed-test settings and operations live in the console.

### Enable

1. LuCI → Services → CFPick → **Settings → Web Console**;
2. Tick "Enable standalone console", set the port (default **17544**, avoiding Lucky's usual 17543), listen address and username;
3. Save & Apply; the service starts automatically;
4. Open `http://<router-ip>:17544/`; the first visit asks you to create the admin password (at least 6 characters).

Only a salted SHA-256 hash is stored in UCI (`cfpick.global.web_password`); the plaintext password is never stored. The session cookie is `HttpOnly` + `SameSite=Strict`, and write actions also require a custom request header to prevent CSRF.

### Console tabs

*   **Overview**: run state, start/stop/retest, per-node best IPs, recent history, scheduled tasks.
*   **Nodes**: single/stable node and the worker table (one row per PassWall node, with its CM IP list).
*   **IP lists**: enable/name/countries/port and a per-list latency cap for the five CM source lists (0 = follow the global cap; different regions can use different standards).
*   **Settings**: IP source, latency/loss thresholds, probe settings, download test, time-boxed iteration, five-field cron, console account.
*   **Logs**: two sub-windows — the live log (auto-scroll, 2s refresh, reload, download) and the task log (one description per run: success/failure/abnormal counts, each node's updated IP, write-back method, latency and speed, plus special events such as the extra round after all downloads failed).
*   **Third-party**: write-back settings for SSR+ / PassWall / PassWall2 / Bypass / Vssr / HOST / Alibaba Cloud DNS / MosDNS / astra-dns.

The console calls the same `api_*` management API, so it always shows the same data as the LuCI pages.

### Account and security

*   Change the password in **Settings → Console account**; you will be asked to log in again.
*   Forgot the password: run over SSH:
    ```sh
    uci delete cfpick.global.web_password
    uci commit cfpick
    /etc/init.d/cfpick-web restart
    ```
    then open the console again to create a new password.
*   The console is intended for LAN use over plain HTTP. For remote access use a VPN or a TLS reverse proxy; do not expose port 17544 directly to the internet.
*   Service script: `/etc/init.d/cfpick-web`; the port, listen address and username come from the UCI options `web_port`, `web_bind` and `web_user`. Saving the settings reloads the service.

## Standalone Core (fixed)

The test always uses the local mihomo / Xray-core. PassWall is only called to **reference** node links/config and to **write back** the best IPs:

*   **Always on**: the console's Core tab no longer offers an off switch; only the core choice remains. Every worker starts its candidate IP through the local core (`cfpick core start`), never through PassWall's `run_socks`.
*   **Same configuration**: workers are still the PassWall nodes from the **Nodes** tab; IP lists, probe/download settings and schedules are unchanged.
*   **Two cores + self-upgrade**: choose mihomo or Xray-core. Each core gets its own card (version, path, source and current-use badge) and can be installed/upgraded separately, optionally pinned to a release tag; the managed copy lives under `/etc/cfpick/state/core`, independent of PassWall. Existing `/usr/bin/mihomo` and `/usr/bin/xray` are reused when present.
*   **No PassWall changes while testing**: the node `address` is not rewritten, the global node is not switched and `run_socks` is not used. Core outbounds carry `mark 255`, matching PassWall's `meta mark 255 return`, so the path stays single-hop (local SOCKS → node). Incompatible nodes (hysteria2, SS with plugin, …) are reported/skipped instead of silently falling back.
*   **Write-back**: after the test each worker's best IP is written to its PassWall node (non-DDNS only); DDNS workers only update DNS.
*   **Port and core health**: the port is probed first and changed when occupied; after start the core must actually listen; failures are reported, retried on another port, and all probing pauses globally until the core recovers.
*   **CLI**:
    ```sh
    cfpick cores
    cfpick update-core --type xray|mihomo|all
    cfpick core start --node <id> --ip <candidate> --port <socks> --core xray --flag <flag>
    cfpick core stop --flag <flag>
    ```
*   **Dependencies**: `python3-light`, `python3-urllib`, `python3-codecs`, `python3-openssl`, `python3-email`, `curl`, `ca-bundle` (installed automatically by the package).

## Per-node DDNS (Cloudflare)

*   Configure the token (optional Zone ID / Zone name, TTL, IPs per node, proxied flag) in **Settings → DDNS write-back (Cloudflare)** and enable it.
*   Fill the **DDNS domain** column of a worker row in the **Nodes** tab.
*   After a run, that worker's best IP is written to the domain's A/AAAA records and **its PassWall node is not rewritten**; workers without a domain keep the normal PassWall write-back.
*   Domains must belong to the same Cloudflare zone; with no zone configured it is resolved from the domain. DDNS failures are logged and never invalidate the speed-test result.

## Management API

The rpcd object `cfpick` exposes two sets of methods:

*   **Legacy methods** (`status` / `start` / `start_retest` / `stop` / `get_log` / `get_history` / `get_best_result` / `list_nodes`) keep their original shapes so existing pages and scripts keep working.
*   **Stable `api_*` methods** use a uniform envelope, and exceptions become normal error responses:

```json
{ "ok": true,  "data": { }, "ts": 1700000000 }
{ "ok": false, "error": "message", "ts": 1700000000 }
```

| Method | ACL | Args | Description |
| --- | --- | --- | --- |
| `api_ping` | read | — | Health check and API version |
| `api_status` | read | — | Run state, PID, mode, phase, elapsed, cron, worker count and the global best IP |
| `api_results` | read | `limit` (0 = all) | Structured rows from `result.csv` |
| `api_history` | read | — | Persistent history (same data as `get_history`) |
| `api_tasklog` | read | — | Task log: per-run result description (success/failure/abnormal counts), each node's updated IP / method / latency / speed, and special handling (extra round after all downloads failed, candidate refresh) |
| `api_nodes` | read | — | Nodes of each installed proxy tool |
| `api_log` | read | `pos` | Incremental log chunk starting at the previous position |
| `api_tasks` | read | — | Only this plugin's crontab tasks (`/etc/crontabs/root`, `/etc/crontab`), with schedule, command and enabled state |
| `api_task_save` | write | `source` `line` `schedule` `enabled` | Change a related task's schedule or enable/disable it; the `start` task is synced to UCI |
| `api_task_delete` | write | `source` `line` | Delete a related task; the `start` task is removed by disabling the UCI schedule |
| `api_task_add` | write | `source` `schedule` `command` | Add a related task (the command must target this plugin) |
| `api_run_start` | write | — | Start a full test |
| `api_run_retest` | write | — | Retest the current best IPs |
| `api_run_stop` | write | — | Request a cooperative stop (finishes the current write-back) |

Examples:

```sh
ubus call cfpick api_status
ubus call cfpick api_results '{"limit":500}'
ubus call cfpick api_tasks
```

External applications using a LuCI/rpcd session need read/write access to these methods in the rpcd ACL; a root `ubus call` bypasses the ACL. The plugin's own ACL already includes all `api_*` methods.

> After installing or upgrading to this version, if the Management page reports `Request failed` or the `api_*` methods are missing, run `/etc/init.d/rpcd restart` (or reboot) so rpcd reloads the ucode and ACL.

## Test Parameters

*   **IP list source**: Built-in IPv4 / IPv6 lists or a custom IP file, with an optional "scan all IPs in each /24" flag.
*   **Latency cap / lower bound / packet-loss cap** (`tl` / `tll` / `tlr`): Discard candidate IPs outside these thresholds (ms / ms / 0–1).
*   **Passwall node to test through**: Single-node fallback when no passwall workers are selected.
*   **Probe URL**: URL probed via the node's local SOCKS (HTTP HEAD). Defaults to Google `generate_204`.
*   **Max IPs to test**: Cap on candidate IPs tested per worker.
*   **Probe timeout**: Per-IP curl `--max-time` (seconds).
*   **Probes per IP**: Number of curl probes per IP (all must succeed or the IP is discarded).
*   **Max parallel workers**: Concurrency cap for multi-node mode (0 = all).
*   **Real download speed test** (`download_test_enabled`, on by default): after latency screening, measure actual throughput on a few candidates.
*   **Download-test candidates per worker** (`download_test_count`, default 5, max 10): only the N lowest-latency IPs of each worker are download-tested. This consumes real proxy traffic: with the default 10 MB URL, up to about 100 MB per worker, added up across workers (tests are serialized).
*   **Download test URL** (`download_test_url`): fixed-size file fetched through the node's local SOCKS; defaults to Cloudflare `speed.cloudflare.com/__down?bytes=10000000` (10 MB). The response must be HTTP 2xx with at least 16 KB of data.
*   **Download test time limit** (`download_test_time`, default 10s): per-IP curl `--max-time`; a transfer cut off by the limit still yields a valid average speed from the bytes received.
*   **Time-boxed iterative test / duration**: Time-boxed mode where each tested node runs an independent convergence loop (each pass only re-tests IPs that passed the previous pass); at the deadline the best remaining IP per node is written back. After convergence, the final passing set's N lowest-latency IPs also go through the download test.

## How the Best IP Is Applied

After a test completes:

*   Each passwall worker node gets its own best IP written to `passwall.<node>.address`. With the download test enabled, "best" means highest measured throughput (failed downloads are excluded); otherwise, or when every download fails, it falls back to lowest latency.
*   The global best IP (first row of `result.csv`; the highest throughput when download tests succeeded) is written automatically to: HOST (`/etc/hosts`), MosDNS, astra-dns, Alibaba Cloud DDNS, and the `server`/`address` field of ssr / passwall / passwall2 / bypass / vssr nodes.

> Note: The plugin does not modify `ip route`. The best IP takes effect through hosts / DNS / proxy nodes.

## Scheduled Tasks

Built-in cron scheduling supports a 1–24 hour interval or a custom cron expression. The `init.d` script updates the crontab idempotently, only when it changes.

The console's "Overview → Scheduled Tasks" panel lists only crontab lines related to this plugin. From there you can edit the five-field schedule, enable/disable, delete, or add a `start` / `retest` / `test` / `replace` task. The `start` task is still owned by the settings page and UCI, so editing it syncs back to Settings; other related tasks are written straight to `/etc/crontabs/root`. Disabling keeps the line with a `# [cfpick-disabled]` prefix so it can be restored later.

Every full run takes a single-instance lock at its entry point: only one run at a time, and an overlapping trigger (duplicate cron firings, repeated UI clicks, manual SSH runs) is **skipped with one log line** instead of racing the running one over the same passwall nodes. A leftover lock from a killed process or a power loss is taken over automatically on the next run. When writing a custom cron expression, mind the minute field: `* 19 * * 4` means "every minute of hour 19 on Thursday" — use `0 19 * * 4` for a single run.

## Results & History

Results are saved to `/tmp/cfpick/result.csv` with 10 rolling historical versions kept; the Best IP area shows every row grouped per node. Column 6 `下载速度(MB/s)` holds the real download measurement — only the N lowest-latency IPs per worker are filled; rows that were not download-tested (or runs with the download test disabled) keep `0.00`. The latency chart plots the persistent history.

Run logs are kept at `/tmp/cfpick.log`; at the start of each run the previous log is rotated to `.log.1` ~ `.log.5` (last 5 runs; `/tmp` is a RAM disk — cleared on reboot, never written to flash). In addition, when each run finishes its full log is **overwritten** to `/etc/config/cfpick.log` (same directory as the UCI config — persistent across reboots, keeps only the most recent run). The log page shows whole lines including `[node remark]` and `[kept]/[dropped]` tags, so per-node iteration rounds can be read directly.

## Installation

1.  Download the latest `.ipk` or `.apk` file from [Releases](https://github.com/urbanescavenger/CFPick/releases).
2.  Install it on your router:
    ```bash
    opkg install luci-app-cfpick_*.ipk
    ```
3.  Go to LuCI → Services → CFPick to configure.
    > **Upgrading from an older name**: the package is now `luci-app-cfpick`, the UCI config is `cfpick`, and the CLI is `cfpick`. Previous settings are **not** migrated — remove the old package first (`opkg remove luci-app-passwall-speedtest` or `opkg remove luci-app-cloudflarespeedtest`), install the new one, then reconfigure. The old `/etc/config/passwall-speedtest` can be deleted.

## Build

```bash
# Compile package only
make package/luci-app-cfpick/compile V=99

# Compile full image
make menuconfig
#choose LuCI ---> 3. Applications  ---> <*> luci-app-cfpick..... for LuCI ----> save
make V=99
```

## Debian / Ubuntu standalone edition

The same branch ships a standalone implementation under [`debian/`](debian/README.md) that does not
require OpenWrt or PassWall. It bundles two switchable, independently upgradable proxy cores
(mihomo and Xray-core), tests candidate Cloudflare IPs through your share links, ships a
Python3-stdlib web UI, and exports CSV/JSON results.

One-click deploy on Debian/Ubuntu:

```bash
curl -fsSL https://raw.githubusercontent.com/urbanescavenger/CFPick/main/debian/deploy.sh -o /tmp/cfpick-deploy.sh
sudo bash /tmp/cfpick-deploy.sh
rm -f /tmp/cfpick-deploy.sh
```

Or install manually:

```bash
git clone https://github.com/urbanescavenger/CFPick.git
cd CFPick
sudo sh debian/install.sh
```

See [`debian/README.md`](debian/README.md) for deployment, upgrade, uninstall and Web access.

## Acknowledgements

*   [openwrt-passwall](https://github.com/xiaorouji/openwrt-passwall)
*   [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) (the IP list format is reused)
*   [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest)