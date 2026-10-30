# luci-app-cloudflarespeedtest

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/stevenjoezhang/luci-app-cloudflarespeedtest/build.yml?style=for-the-badge&logo=GitHub)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/stevenjoezhang/luci-app-cloudflarespeedtest?style=for-the-badge)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases)

[中文说明](README.CN.md)

**luci-app-cloudflarespeedtest** is a LuCI application for OpenWrt, based on the [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) core tool. It automatically tests the latency and download speed of Cloudflare IPs, selects the best ones for your network, and updates them to proxy and DNS plugins such as SSR+, Passwall, SmartDNS, and AstraDNS.

This project is a fork of [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest) with significant refactoring and improvements.

> If you want to use the best CloudflareSpeedTest IPs directly for DNS resolution and also need ad filtering, you might want to check out the author's [Astra DNS](https://github.com/astra-sec/astra-dns) and its LuCI plugin [luci-app-astra-dns](https://github.com/astra-sec/luci-app-astra-dns).

## Features

*   **Auto Speed Test**: Periodically or manually test Cloudflare IPs to find the best one.
*   **Proxy and DNS Integration**: Automatically update the best IP to SSR+, Passwall, MosDNS, SmartDNS, astra-dns, and other proxy or DNS tools. SmartDNS uses the IPv4 list from the speed test to match source addresses and filter target addresses. Custom lists may include special-purpose or restricted addresses; choose them carefully.
*   **Visual Charts**: View history charts for latency and download speed trends.
*   **Auto Core Download**: The package does not contain the core binary; it downloads automatically on the first run, reducing the package size.
*   **Improved UI & Logs**: Redesigned status display and log format for better readability.
*   **Curated IPv4 List**: The bundled list is based on [Cloudflare's public IPv4 ranges](https://www.cloudflare.com/ips-v4), conservatively excluding known or suspected special-purpose and restricted ranges. Besides `108.162.192.0/18`, `162.158.0.0/16`, `162.159.0.0/18`, `172.68.0.0/14`, and `198.41.192.0/19`, excluded `/24` ranges have third octets `137`, `138`, `192`, `193`, `197`, `200`, `213`, `234`, and `239` under `162.159`; `32`, `33`, `34`, `35`, `38`, `40`, `41`, `42`, `43`, `48`, `49`, `50`, `52`, `53`, `98`, `100`, `101`, `228`, and `234` under `172.64`; plus `173.245.58.0/24` and `173.245.59.0/24`. Whole-range exclusions include conservative inferences, not tests of every address.

## Installation

1.  Download the latest `.ipk` or `.apk` file from [Releases](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases).
2.  Install it on your router:
    ```bash
    opkg install luci-app-cloudflarespeedtest_*.ipk
    ```
3.  Go to LuCI -> Services -> CloudflareSpeedTest to configure.

## Screenshots

![Overview](screenshots/overview.png)
![History Chart](screenshots/chart.png)

## Build

```bash
# Compile package only
make package/luci-app-cloudflarespeedtest/compile V=99

# Compile full image
make menuconfig
#choose LuCI ---> 3. Applications  ---> <*> luci-app-cloudflarespeedtest..... for LuCI ----> save
make V=99
```

## Acknowledgements

*   [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
*   [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest)
