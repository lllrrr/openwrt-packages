# luci-app-handoff

OpenWrt / ImmortalWrt 上的「网关分流」：按 **设备组 × 目标**（GeoIP 国家 / 自定义 IP 组）把新连接交给局域网里的另一台网关（旁路由、代理盒子等），可以配多台。

- **流量**：nftables 给新连接打标记，策略路由送到对应网关；已建立的连接不受影响。正向匹配的目标 IP 组支持私有网段（如公司内网 `10.20.0.0/16`），取反/默认规则自动排除私网段。
- **DNS**：被分流设备的 DNS 用 DNAT + masquerade 直接转给网关，不经过本机 dnsmasq；无非链路本地 IPv6 时拒绝 IPv6 DNS，促使设备改走网关的 IPv4 DNS（照常返回 A 与 AAAA 记录）。
- **网关不通**：每台网关并行检测（连续 3 次失败判为不通，1 次成功恢复），按「不通时」设置直连或改走另一台网关（只切换一次）。
- **IPv6**：默认按网关 MAC 自动发现同网段 IPv6 地址（可选优先级：`ULA > fe80:: > GUA` 默认 / `fe80:: > ULA > GUA` / `GUA > ULA > fe80::`，自动过滤不同网段的 ULA）并自动跟踪前缀变化，也支持手动指定或关闭；IPv6 不可用时可按网关选择「拒绝并回退 IPv4」、「直连」或「黑洞丢弃」。
- **设备组**：LuCI 内置局域网设备多选器，支持搜索筛选、一键多选以及离线设备 MAC 批量粘贴。

依赖：`firewall4`、`ip-full`、`jshn`。页面在「服务 → 网关分流」。包与架构无关（`all`）。

## 安装

### 方式一：添加签名软件源（推荐，支持一键升级）

**OpenWrt / ImmortalWrt 24.10（opkg）**：

```sh
wget -qO /etc/opkg/keys/e5d081b67f327ff4 https://r1172464137.github.io/luci-app-handoff/feed/handoff-opkg.pub
grep -q 'luci-app-handoff/feed/24.10' /etc/opkg/customfeeds.conf 2>/dev/null || \
  echo 'src/gz handoff https://r1172464137.github.io/luci-app-handoff/feed/24.10' >> /etc/opkg/customfeeds.conf
opkg update && opkg install luci-app-handoff luci-i18n-handoff-zh-cn
```

**OpenWrt / ImmortalWrt 25.12（apk）**：

```sh
wget -qO /etc/apk/keys/handoff-apk.pem https://r1172464137.github.io/luci-app-handoff/feed/handoff-apk.pem
grep -q 'luci-app-handoff/feed/25.12' /etc/apk/repositories.d/customfeeds.list 2>/dev/null || \
  echo 'https://r1172464137.github.io/luci-app-handoff/feed/25.12/packages.adb' >> /etc/apk/repositories.d/customfeeds.list
apk update && apk add luci-app-handoff luci-i18n-handoff-zh-cn
```

软件源公钥同时存放在本仓库的 [`keys/`](keys/) 目录。

### 方式二：手动下载安装包

从 [Releases](https://github.com/r1172464137/luci-app-handoff/releases) 下载：24.10 用 `.ipk`（`opkg install`），25.12 用 `.apk`（若未导入公钥，需加 `apk add --allow-untrusted`）。

## 命令

```
handoff start|stop|update|watch|status [--json]
```

`update` 更新 GeoIP 数据；`status --json` 是页面用的状态输出。配置在 `/etc/config/handoff`，格式见 [SPEC.md](SPEC.md)。

## 测试

`test/lab.sh` 是在 PVE 实验环境（主路由 + 网关 + 两台客户端）上跑的端到端测试，覆盖分流、目标 IP 组（含私有网段）、IPv6 自动发现与三种不可用策略、DNS、探测路由隔离、故障切换与恢复、页面接口。
