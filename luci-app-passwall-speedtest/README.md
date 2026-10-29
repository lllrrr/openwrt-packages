# luci-app-passwall-speedtest

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/urbanescavenger/luci-app-passwall-speedtest/build.yml?style=for-the-badge&logo=GitHub)](https://github.com/urbanescavenger/luci-app-passwall-speedtest/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/urbanescavenger/luci-app-passwall-speedtest?style=for-the-badge)](https://github.com/urbanescavenger/luci-app-passwall-speedtest/releases)

[中文说明](README.CN.md)

**luci-app-passwall-speedtest** is a LuCI application for OpenWrt that selects the best Cloudflare IP **through your existing [PassWall](https://github.com/xiaorouji/openwrt-passwall) nodes**. It writes each candidate IP into a passwall node's `address` and spins up a local SOCKS via passwall: first it screens every candidate with HTTP HEAD latency (`time_pretransfer`); then, for each worker's N lowest-latency IPs, it downloads a real fixed-size file over the same node chain and measures actual throughput (MB/s). The final best IP is written back to the passwall node(s) and other integrations.

> This is a refactor of the original `luci-app-cloudflarespeedtest`: the standalone `CloudflareSpeedTest` binary download path has been removed. The test now runs entirely through passwall — no external test binary is downloaded or bundled. It is two-stage: cheap latency screening across all candidates, then a real download test on the few most promising ones.

## Requirements

*   **PassWall** (`openwrt-passwall`) must be installed — the test drives `/usr/share/passwall/app.sh run_socks`. If passwall is missing, the test reports an error and aborts.
*   **curl** (hard dependency) for the latency probe.
*   At least one CF-CDN-fronted passwall node (VLESS / VMess / Trojan / SS …). SOCKS-type passwall nodes cannot be used as test nodes (their `address` IS the SOCKS server).

## Features

*   **Node-Based Latency Test**: Probes candidate Cloudflare IPs through your passwall node chain — finds the best CF IP *as seen from your proxy's egress*.
*   **Latency Screening + Real Download Test**: Latency first (cheap, covers every candidate), then a real fixed-size download through each worker's N lowest-latency IPs (default 5, max 10) over the same node chain; `speed_download` from curl is converted to MB/s. The final best IP is picked by measured throughput; IPs whose download fails are dropped; if every download fails (e.g. the URL is unreachable through that node), the latency ranking is kept. Each IP gets its own SOCKS config, and the generated `/tmp/etc/passwall/<flag>.json` is verified to point at the candidate IP before a speed is accepted, so the number cannot come from an unrelated path. Download tests across workers run **one at a time** — concurrent downloads would split the router's WAN bandwidth and make the per-IP numbers incomparable. Fast-death: a candidate that downloads less than 1 MB in the first 5 seconds is aborted and marked failed (curl `--speed-limit`/`--speed-time`), so dead or crawling IPs no longer burn the full per-IP time limit. In iterative mode the download phase runs after convergence and does not count toward `iterate_minutes`.
*   **Retest Current Best IPs**: A dedicated button on the Plugin Settings page (CLI: `passwall-speedtest.sh retest`) — it does **not** re-download the online IP list. Candidates come only from the current `result.csv` rows for each node plus that node's current `address`. Candidate source and scheduling are independent: by default it runs ONE latency round + the download test; if the time-boxed iterative test is also enabled, the same candidates go through each node's convergence loop until `iterate_minutes` elapses, dropping IPs that fail each pass. The best IP is written back as usual. Useful for quickly validating the existing best IPs after a scheduled run without pulling tens of thousands of candidates.
*   **Multi-Threaded Workers**: Passwall nodes selected in the Third-Party tab run as parallel workers — each tests all candidate IPs through its own chain and gets its own best IP written back. Concurrency is capped by `node_test_threads`.
*   **Fail-Fast Multi-Probe**: Each IP is probed `node_test_probes` times; if any probe fails, the IP is discarded immediately. Only IPs that succeed on all probes are kept, so the result is a stable one.
*   **Time-Boxed Iterative Test**: With `iterate_enabled`, each tested node runs its **own independent convergence loop** until `iterate_minutes` elapses: after its first pass it only re-tests the IPs that passed its previous pass, so its candidate pool shrinks toward the most stable, lowest-latency IPs. Nothing is written to result.csv or passwall mid-run. A node saves its result and exits early once its pool converges to **≤ N IPs**, where N reuses `download_test_count` (so the surviving set is exactly what the download test will measure; 3 when the download test is off) — no need to wait out the timer; at the end each node's final-pass results are printed to the log before one final merge writes every node's best IP.
*   **Proxy Integration**: Writes the best IP back to ssr / passwall / passwall2 / bypass / vssr nodes, and to HOST / MosDNS / astra-dns / Alibaba Cloud DDNS.
*   **Visual Charts**: History chart for latency trends; hovering/clicking a point shows that node's best IP, latency and measured download speed (latency only when no download test was run).
*   **Improved UI & Logs**: Redesigned status display; per-IP log lines like `进度: 走节点测速 [node] 5/30 (16%) - 1.2.3.4 延迟 87ms 丢包 0.00 [保留]`.
*   **Partial Results Saved on Stop**: Stopping mid-test triggers a trap that cleans up SOCKS, restores node addresses, and keeps the previous result if nothing new was measured. **When the user stops round one manually, the IPs that already passed latency still complete the download test** (up to 5 per worker, serialized across workers) before write-back. Only the automatic early stop (after the first worker finishes) skips other workers' downloads.
*   **Broad Integrations**: The best IP can be automatically applied to SSR+ / Passwall / PassWall2 / Bypass / Vssr / HOST / MosDNS / astra-dns / Alibaba Cloud DDNS.

## UI Pages

Three pages under LuCI → Services → PassWall Speed Test:

*   **Plugin Settings**: Basic (test params) + Crontab tabs, with a Start/Stop button, a 3-second polled status bar, a read-only Best IP area, and a latency history chart.
*   **Third Party Settings**: Tabs appear on demand for each proxy tool installed on the router. The passwall nodes selected here double as the parallel workers.
*   **Logs**: Incrementally fetches the test log, with an optional 5-second auto-refresh.

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

Every full run takes a single-instance lock at its entry point: only one run at a time, and an overlapping trigger (duplicate cron firings, repeated UI clicks, manual SSH runs) is **skipped with one log line** instead of racing the running one over the same passwall nodes. A leftover lock from a killed process or a power loss is taken over automatically on the next run. When writing a custom cron expression, mind the minute field: `* 19 * * 4` means "every minute of hour 19 on Thursday" — use `0 19 * * 4` for a single run.

## Results & History

Results are saved to `/tmp/passwall-speedtest/result.csv` with 10 rolling historical versions kept; the Best IP area shows every row grouped per node. Column 6 `下载速度(MB/s)` holds the real download measurement — only the N lowest-latency IPs per worker are filled; rows that were not download-tested (or runs with the download test disabled) keep `0.00`. The latency chart plots the persistent history.

Run logs are kept at `/tmp/passwall-speedtest.log`; at the start of each run the previous log is rotated to `.log.1` ~ `.log.5` (last 5 runs; `/tmp` is a RAM disk — cleared on reboot, never written to flash). In addition, when each run finishes its full log is **overwritten** to `/etc/config/passwall-speedtest.log` (same directory as the UCI config — persistent across reboots, keeps only the most recent run). The log page shows whole lines including `[node remark]` and `[kept]/[dropped]` tags, so per-node iteration rounds can be read directly.

## Installation

1.  Download the latest `.ipk` or `.apk` file from [Releases](https://github.com/urbanescavenger/luci-app-passwall-speedtest/releases).
2.  Install it on your router:
    ```bash
    opkg install luci-app-passwall-speedtest_*.ipk
    ```
3.  Go to LuCI → Services → PassWall Speed Test to configure.
    > Upgrading from the old `luci-app-cloudflarespeedtest`: the UCI config was renamed to `passwall-speedtest`, so previous settings are **not** migrated — reconfigure in the LuCI page. You may delete the old `/etc/config/cloudflarespeedtest`.

## Build

```bash
# Compile package only
make package/luci-app-passwall-speedtest/compile V=99

# Compile full image
make menuconfig
#choose LuCI ---> 3. Applications  ---> <*> luci-app-passwall-speedtest..... for LuCI ----> save
make V=99
```

## Acknowledgements

*   [openwrt-passwall](https://github.com/xiaorouji/openwrt-passwall)
*   [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) (the IP list format is reused)
*   [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest)