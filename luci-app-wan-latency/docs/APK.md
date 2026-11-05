# OpenWrt APK 安装包

面向 OpenWrt 25.12.5 / APK v3；MU300 / U30 Air 目标架构为 `aarch64_generic`。这不是安卓应用。保留原有 IPK 供 opkg 系统使用。

```sh
apk update
apk add --allow-untrusted ./luci-app-wan-latency-*.apk
```

本包未签名，仅在核对本发布页 SHA256SUMS 后安装。保留 `/etc/config` 中已有配置。

构建：Linux 上设置 `APK` 为 OpenWrt 25.12.5 SDK 中的 `staging_dir/host/bin/apk`，运行 `sudo --preserve-env=APK python3 tools/build_apk.py`。也可手动运行 GitHub Actions 的 Build OpenWrt APK。源文件只从 Git 跟踪清单读取，排除截图、缓存和历史安装包；源码包不含 Git 历史或本机路径。

验证覆盖原生 APK v3 打包与解包、逐文件内容校验及已有自动测试；未声称已在实体 U30 Air 上完成安装或联网验证。
