# luci-app-oxidns

OxiDNS 的 OpenWrt / LuCI 管理插件。安装后 LuCI 出现 `Services -> OxiDNS`：安装 OxiDNS 内核、管理服务、编辑配置与规则文件、查看日志。

> **自用声明**：本仓库是 [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns) 的个人自用分支，内核来自 [svenshi/oxidns](https://github.com/svenshi/oxidns)。只用本仓库 Release 的包，不执行上游的官方安装脚本，不与上游 Release 混用；不保证跟进上游更新。相对上游的改动见文末。

## 安装

从本仓库 [Release](https://github.com/hahaher123/luci-app-oxidns/releases/latest) 下载两个 `noarch` 包：`luci-app-oxidns`（页面与后端）和可选的 `luci-i18n-oxidns-zh-cn`（简体中文语言包），拷到路由器后：

```sh
apk add --allow-untrusted --no-network ./luci-app-oxidns-<版本>.apk
apk add --allow-untrusted --no-network ./luci-i18n-oxidns-zh-cn-<版本>.apk
```

校验和见 Release 里的 `sha256sums.txt`。`opkg` 系统（24.10 及更早）用 `scripts/build-luci-package.sh` 本地产出 `ipk` 再 `opkg install`。装完菜单没出现就重启 `rpcd`（`/etc/init.d/rpcd restart`）。

**装内核**：从旧的 `oxidns` 包迁移时先停服务并卸载旧包（`/etc/init.d/oxidns stop`；`apk del oxidns`），然后到 `Settings` 确认 `Core repository` 为 `svenshi/oxidns`，`Core` 页点 `Install Core`（LuCI 按设备架构下载官方 musl archive 并校验 SHA256；离线环境用 `Upload Core` 上传），最后在 `Overview` 启动服务。内核已装时 `Core` 页提供 `Repair Reinstall` / `Upload Core` 修复，不做升级。

## 页面

| 页面 | 用途 |
| --- | --- |
| `Overview` | 内核 / 服务状态、WebUI 入口；DNS 劫持开关（把局域网发往 53 端口的 DNS 请求重定向到本机 OxiDNS，目标端口从 config.yaml 解析） |
| `Core` | 内核安装、上传安装、修复重装、删除 |
| `Configuration` | 查看、校验、保存配置文件 |
| `Rule Files` | 编辑规则列表文件；定时重置学习文件 |
| `Logs` | 日志文件查看，时间戳按 UTC+8 显示；「清空」截断日志文件 |
| `Settings` | 内核源、代理、token、路径 |

配置在 `/etc/oxidns/config.yaml`，规则目录 `/etc/oxidns/rule`，工作目录 `/var/lib/oxidns`。

## 升级与删除

- **内核**：用 OxiDNS 自带的升级功能（WebUI / API / CLI），LuCI 不提供升级入口。
- **插件**：下载新版本包重装即可。
- **删除内核**：`Core` 页 `Remove Core`，保留配置与工作目录。

## 网络受限环境

路由器需能访问 GitHub Releases。受限网络可在 `Settings` 配 GitHub token 或下载代理（保存后不回显），或在 `Core` 页直接上传 archive / 二进制离线安装。

## 本分支相对上游的改动

包版本高于上游，可直接覆盖升级；文案均已进 `po/`。

1. **新增 `Rule Files` 页** —— 横向标签页编辑规则文件（固定 7 项 + 目录内 `.txt` 自动追加），`Save` 写盘、`Save & Restart` 生效，带 mtime 冲突检测与写前备份。
2. **定时重置学习文件** —— `learned-cn.txt` / `learned-proxy.txt` 可每天 / 每周定时清空（cron 托管块 + 后端脚本），走管理 API 快照与文件同步清理，无需重启。
3. **日志页直读日志文件** —— 显示 config.yaml 中 `log.file` 指定的文件（未配置时退回 `logread`），UTC 时间戳换算成 `+08:00`，「清空」原地截断日志文件，无需重启。
4. **配置页提示优化** —— 校验 / 保存结果按状态着色，区分 `Save` 与 `Save & Restart`，操作期间按钮禁用并保留真实错误文案。
