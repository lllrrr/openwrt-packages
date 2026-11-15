# luci-app-oxidns

语言：中文 | [English](./README.en.md)

`luci-app-oxidns` 是 OxiDNS 的 OpenWrt / LuCI 管理插件。安装后，LuCI 会增加 `服务 -> OxiDNS` 页面，用于安装 OxiDNS 内核、管理 OpenWrt 服务、编辑配置、查看日志，以及按需将局域网 DNS 通过 dnsmasq 转发到 OxiDNS。

本仓库只包含 LuCI 管理界面和 rpcd 后端；OxiDNS 内核、WebUI 与通用 release 由 [svenshi/oxidns](https://github.com/svenshi/oxidns) 提供。

**完整操作说明**：从零配置 DNS、普通模式/高级模式逐项参考、插件参数、常见任务、故障排查以及 OxiDNS WebUI 的使用方法，见 [info/README.md](info/README.md)。其中在 `基本信息` 一键启用 dnsmasq 转发、手动配置以及回滚，见 [4.9 用 dnsmasq 转发（推荐）](info/README.md#49-用-dnsmasq-转发推荐)；普通模式的广告过滤卡片见 [3.8 广告过滤](info/README.md#38-广告过滤ad-filtering)。

![OxiDNS LuCI 管理界面](screenshot.png)

## 安装 LuCI 插件

从本仓库 Release 下载安装包并上传到设备（例如 `/tmp`），然后安装。

OpenWrt 24.10（`opkg`）：

```sh
opkg install /tmp/luci-app-oxidns_*.ipk

# 可选：安装简体中文语言包
opkg install /tmp/luci-i18n-oxidns-zh-cn_*.ipk
```

OpenWrt 25.12（`apk`）：

```sh
apk add --allow-untrusted /tmp/luci-app-oxidns-*.apk

# 可选：安装简体中文语言包
apk add --allow-untrusted /tmp/luci-i18n-oxidns-zh-cn-*.apk
```

如果安装后菜单没有出现，重启 `rpcd`，然后打开 `服务 -> OxiDNS`：

```sh
/etc/init.d/rpcd restart
```

### 从源码编译

要把本包裁剪进固件或自行调整时，把它放进 OpenWrt 构建树编译：

```sh
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a
git clone https://github.com/Arthur97172/luci-app-oxidns.git package/luci-app-oxidns
make menuconfig   # LuCI -> Applications -> luci-app-oxidns
make package/luci-app-oxidns/compile V=s
```

产物在 `bin/packages/<架构>/` 下：24.10 构建树生成 `.ipk`，25.12 构建树生成 `.apk`。

## 功能

- `基本信息`：`状态概览` 展示后端、内核、构建信息、服务状态、开机自启和 WebUI 入口；下方可启动、停止或重启服务。
- `系统 DNS 接入`：位于 `基本信息` 页面，可一键启用或停用 dnsmasq 转发。启用后 dnsmasq 将通用 DNS 查询转发到 OxiDNS 的监听地址，保留特定域名上游；默认关闭，停用时会恢复原来的通用上游和 `noresolv` 设置。
- `安装部署`：安装、更新、上传、修复或删除内核与 WebUI；配置内核仓库、bundle、路径、系统日志输出和下载凭据。
- `DNS配置`：默认进入高级模式（完整 YAML 编辑器），普通模式提供常用设置表单；两种模式都支持校验、下载/上传配置、保存、保存并应用和改动预览。`forward` 的上游可从下拉框选择常用 DNS 服务器或输入自定义地址，没有 `forward` 插件时可一键创建并接入入口 sequence；server 的 `Entry` 改为下拉选择已有插件。普通模式的 `广告过滤` 卡片可一键创建并管理固定的 `adguard_rule` / `black_hole` 插件组（填写订阅地址后创建 `download` 插件），支持订阅下载、内联规则、本地规则文件和拦截模式，并把拦截规则插入每个入口 sequence 的最前面。普通模式的 `Hosts` 卡片可一键创建固定的 `hosts` 插件（`oxidns_hosts`），把 hosts 步骤插入入口 sequence，并维护本地域名记录。普通模式的 `缓存` 卡片可一键创建固定的 `cache` 插件（`oxidns_cache`），把缓存步骤插入入口 sequence，并在启用后提供全部缓存字段。
- `运行日志`：查看 OxiDNS 运行日志。

## 默认路径

| 项目 | 路径 |
| --- | --- |
| 内核二进制 | `/usr/bin/oxidns` |
| WebUI | `/usr/share/oxidns/webui` |
| 配置文件 | `/etc/oxidns/config.yaml` |
| 工作目录 | `/var/lib/oxidns` |
| 日志文件 | `/tmp/oxidns/oxidns.log` |
| 服务脚本 | `/etc/init.d/oxidns` |

## 已知限制

- 只支持 OxiDNS 已发布的 Linux musl release target。
- `更新内核` 只安装严格更新的正式版本，不会降级已安装的较新或自定义构建。
- 替换内核或 WebUI 前会暂存并校验新文件；复制失败时恢复旧文件，避免留下内核与 WebUI 不匹配的状态。
- 普通模式只编辑已存在的插件实例，新增/删除插件和 sequence 规则需在高级模式或 OxiDNS WebUI 中完成；`广告过滤`、`Hosts` 和 `缓存` 卡片是例外，它们可以创建或删除固定的 `adguard_rule` / `black_hole` 插件组（填写订阅地址后创建 `download` 插件）、`oxidns_hosts` 插件和 `oxidns_cache` 插件，并维护入口 sequence 中对应的拦截、hosts 和缓存步骤。上游区域的 `创建 forward 插件` 按钮也可以创建固定的 `forward` 插件并接入入口 sequence。配置使用 YAML anchor、alias 或 merge key 时，普通模式会变为只读。
- 普通模式保存会重新序列化 YAML：保留注释、字段顺序和表单未管理的字段，只写入实际改动的字段。普通模式、高级模式和 OxiDNS WebUI 编辑同一份文件，建议同时只使用一个入口。
- `基本信息` 的 WebUI 入口要求 WebUI 文件已安装、服务正在运行且 HTTP 监听地址可访问；只监听 `127.0.0.1` / `::1` 时需要本机访问或 SSH 隧道。
- `系统 DNS 接入` 要求 OxiDNS 已启动，UDP 与 TCP 监听使用同一个端口并共享可达的 IPv4 地址；只监听 IPv6、端口不一致或没有共同可达的 IPv4 地址时，“启用 dnsmasq 转发”按钮不可用。
- 启用 `系统 DNS 接入` 后，停止 OxiDNS 会导致局域网 DNS 解析失败（fail-closed），不会自动绕过 OxiDNS；需重新启动 OxiDNS 或停用转发。
- `系统 DNS 接入` 不接管 53 端口；dnsmasq 继续监听 53 并提供 DHCP、本地域名和租约解析。需要 OxiDNS 直接监听 53 时属于另一种部署方式，代价和步骤见详细文档。

## 私有仓库与下载

路由器需要能访问 GitHub Releases 和 release archive。私有仓库或受限网络可以在 `安装部署` 中配置 GitHub token 或下载代理；Token 和代理值保存后不会在 LuCI 中回显。配置下载代理需要安装 `curl`，也可以使用 `上传内核` 离线安装。

## 许可证

本项目以 GNU General Public License v3.0 或更高版本（`GPL-3.0-or-later`）发布。完整许可证文本见 [LICENSE](LICENSE)。

## 致谢

- [https://oxidns.org/](https://oxidns.org/)：OxiDNS 官方主页，提供文档、配置参考和最新动态。
- [https://github.com/svenshi/oxidns](https://github.com/svenshi/oxidns)：OxiDNS 内核及其 WebUI 的源代码仓库；本插件安装的内核和 WebUI 均来自该项目的 release。
- 本仓库克隆自 [svenshi/luci-app-oxidns](https://github.com/svenshi/luci-app-oxidns)，并在此基础上进行了优化。
