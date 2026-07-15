# luci-app-bypass

OpenWrt 上的网关级透明分流代理。把三个各司其职的组件组合成一个 LuCI 应用：

| 组件 | 角色 | 数据面 |
|---|---|---|
| **BypassCore** | **必需分流核心**：透明入口、规则匹配、路由决策与 outbound | 实时数据面核心 |
| **naiveproxy** | Naive HTTPS 协议适配器，为 BypassCore 提供本机 SOCKS 上游 | 节点连接 |
| **ChinaDNS-NG** | DNS 分流（国内域名 → 国内 DNS；国外域名 → 远程 DNS） | DNS 转发 |
| **dns2socks** | 把 ChinaDNS-NG 的国外 DNS 请求送入 Naive SOCKS 隧道 | 国外 DNS 防泄漏 |

数据面仅依赖 **nftables (fw4)**；前端为现代 LuCI **JavaScript** 视图（**无 Lua 运行时**）。

> **关于 BypassCore 的角色**：BypassCore 对本项目而言等同于 Passwall 的 Xray/sing-box，是不可替代的透明分流核心。它负责透明入口、规则匹配、DNS、Observatory 和 outbound；NaiveProxy 仅把 Naive HTTPS 节点转换成本机 SOCKS 上游。核心不可用时服务明确启动失败，不会回退到 NaiveProxy。
>
> BypassCore 源码：<https://github.com/kinmeic/BypassCore>，`make build` 即可编译，release v1.0.5 提供 OpenWrt 预编译包（`bypasscore-openwrt-aarch64_cortex-a53.tar.gz`、`bypasscore-openwrt-x86_64.tar.gz` 等）。

---

## 工作原理

```
LAN 客户端
   │
nftables TPROXY/REDIRECT
   │
BypassCore (redirect/tproxy://127.0.0.1:<REDIR_PORT>)
   ├── direct / block
   └── proxy → naiveproxy (socks://127.0.0.1:<node_socks_port>)
                    │ proxy = https://<user>:<pass>@<server>:<port>
                    ▼
                 Naive 服务器 (HTTP/2)

DNS:  dnsmasq :53 → ChinaDNS-NG :<dns_port>
       china-dns  = 国内 DNS   (国内域名优先使用国内解析)
       trust-dns  = 远程 DNS   (安装 dns2socks 时经 Naive SOCKS)
       Direct 规则结果 → nftset `bypass_direct_dns`  (不再把所有国内解析结果一概直连)
       group vpslist → nftset `bypass_vps`  (节点服务器 IP → 永远直连)

出口接口 (NaiveProxy→服务器走指定逻辑网络)：
  netifd 解析 wan/wan1/usbwan → 实时 L3 设备、地址、网关
  解析 Naive 服务器 IPv4/IPv6 → ip rule to <SERVER> lookup <TABLE>
  ip/ip -6 route table <TABLE>: default via <runtime-gateway> dev <l3-device>
```

- 每个 NaiveProxy 节点独立配置出口接口；服务器 IP 变更时在启动 / 规则更新 / hotplug 时重新解析。

---

## 依赖关系

本项目只支持 fw4/nftables。透明代理内核模块、ChinaDNS-NG 和 dns2socks 都是安装时硬依赖；NaiveProxy 与 GeoData 工具仍可按需通过 menuconfig 选入：

- 硬依赖：`ca-bundle curl ip-full resolveip libubox nftables kmod-nft-nat kmod-nft-tproxy kmod-nft-socket chinadns-ng dns2socks`
- `INCLUDE_NaiveProxy` → `naiveproxy`（受架构限制，排除 mips/mips64 等）
- `INCLUDE_Geoview` → `geoview`
- `INCLUDE_V2ray_Geo` → `v2ray-geoip` + `v2ray-geosite`
- `INCLUDE_Tcping` → `tcping`

> **本应用不再支持 iptables (fw3)**，仅 nftables。

> **BypassCore 是必需依赖**，但它目前是独立项目且未进入 OpenWrt 官方 feeds，因此不能把 `+bypasscore` 写进本包依赖（官方 SDK 会无法解析）。请先从 [BypassCore Releases](https://github.com/kinmeic/BypassCore/releases) 安装对应架构的 `.ipk` / `.apk`，或放置 Linux ELF 到 `/usr/bin/bypasscore`。应用启动时会严格校验；缺失、架构错误或启动失败时不会接管防火墙和 DNS。

---

## 编译安装

把本目录放到 OpenWrt 源码树里（例如 `feeds/luci/applications/luci-app-bypass` 或直接 `package/luci-app-bypass`），然后：

```sh
# 在 OpenWrt buildroot 里
make menuconfig        # LuCI → Applications → luci-app-bypass，按需勾选 INCLUDE_*
make package/feeds/luci/luci-app-bypass/compile V=s
# 产物：bin/packages/<arch>/luci/luci-app-bypass_*.ipk

opkg install luci-app-bypass_*.ipk
```

安装后：
1. 安装 BypassCore：从 <https://github.com/kinmeic/BypassCore/releases> 下载对应架构的 OpenWrt 包（`bypasscore-openwrt-*.tar.gz`），解出 `bypasscore` 放到 `/usr/bin/bypasscore`（或改 `bypass.global.bypasscore_file`）。
2. 安装 NaiveProxy。`chinadns-ng` 与 `dns2socks` 由本包声明为硬依赖（来自 Passwall packages feed）；缺少依赖时包管理器应拒绝不完整安装。
3. 把 `geoip.dat` / `geosite.dat` 放到 `/usr/share/v2ray/`（或安装 `v2ray-geoip` / `v2ray-geosite`，程序会检测包的实际安装目录）。
4. LuCI → 服务 → Bypass，填节点、选出口接口、启用。

---

## UCI 配置（`/etc/config/bypass`）

```sh
config global
    option enabled '1'
    option node_socks_port '1088'      # 多节点 SOCKS 起始端口
    option dns_redirect '1'
    option bypasscore_file '/usr/bin/bypasscore'
    option naive_file '/usr/bin/naive'
    option chinadns_file '/usr/bin/chinadns-ng'
    option dns2socks_file '/usr/bin/dns2socks'
    option naive_egress_table '20200'         # 节点策略路由表起始编号
    option naive_egress_rule_priority '900'   # 节点策略规则起始优先级

config global_forwarding
    option tcp_proxy_way 'redirect'   # redirect | tproxy
    option tcp_redir_ports '1:65535'
    option ipv6_tproxy '0'
    option accept_icmp '0'

config global_dns
    option domestic_dns 'auto'        # auto = 自动检测运营商 DNS
    option remote_dns '1.1.1.1'
    option remote_dns_protocol 'tcp'  # udp|tcp|doh|tls
    option remote_dns_detour 'remote' # remote = 经 Default 规则节点
    option direct_dns_query_strategy 'UseIP'
    option remote_dns_query_strategy 'UseIPv4'
    option dns_hosts 'cloudflare-dns.com 1.1.1.1
dns.google.com 8.8.8.8'
    option chinadns_listen_port '10553'

config nodes 'naive1'
    option remarks 'Node 1'
    option protocol 'https'
    option address 'naive.example.com'
    option port '443'
    option egress_interface 'wan1'    # 空 = 系统默认路由

config global_rules
    option v2ray_location_asset '/usr/share/v2ray/'
    option domainStrategy 'IpIfNonMatch'
    option domainMatcher 'hybrid'
    option write_ipset_direct '1'
    option enable_geoview_ip '1'
    option direct_egress_interface 'wan1'

config shunt_rules 'China'
    option network 'tcp,udp'
    option domain_list 'geosite:cn'
    option ip_list 'geoip:cn'
    option outbound '_direct'         # 空 | _direct | _blackhole | 节点 section id

config shunt_rules 'Default'
    option remarks 'Default'
    option is_default '1'             # Basic Settings 专用，不在 Rule Manage 显示
    option outbound 'naive1'          # 未匹配流量走 naive1

config nodes 'naive1'
    option address 'naive.example.com'
    option port '443'
    option username 'user'
    option password 'pass'
```

Other Settings 中的 Direct IP List 保存在 `/usr/share/bypass/direct_ip`；其中的 IP、CIDR 与 `geoip:CODE` 会在进入 BypassCore 前由 nftables 直接放行。

---

## 目录结构

```
luci-app-bypass/
├── Makefile                          # luci.mk + INCLUDE_* 可选依赖
├── po/zh-cn/bypass.po                # 中文翻译
├── htdocs/luci-static/resources/view/bypass/
│   ├── basic_settings.js             # 状态面板 + 主设置 / 分流 / DNS / 日志 / 维护
│   ├── node_list.js node_config.js   # 仅 NaiveProxy (https)
│   ├── other_settings.js             # 延时、定时任务与透明转发
│   ├── rule_manage.js rule_edit.js   # GeoData 更新与分流规则
│   ├── geo_view.js log.js
└── root/
    ├── etc/uci-defaults/luci-bypass  # 首次安装：拷默认配置、生成 init、防火墙 include、chmod
    ├── etc/hotplug.d/iface/98-bypass # ifup 重启 / ifupdate 刷新
    └── usr/share/bypass/
        ├── bypass.init service.init  # rc.common 包装器模板、锁与服务生命周期
        ├── direct_ip                # 可编辑的直连 IP/CIDR/GeoIP 列表
        ├── utils.sh                  # 共享库（含双栈出口策略路由、核心身份校验）
        ├── app.sh                    # 编排：多 Naive 节点 / ChinaDNS-NG / BypassCore / start-stop
        ├── monitor.sh                # PID + 监听端口健康检查，异常时完整重启
        ├── nftables.sh               # nft 透明代理、DNS 白名单与 IPv6 TProxy
        ├── rule_update.sh            # 下载校验 geoip/geosite + 重解析出口 IP
        ├── api.sh                    # rpcd file.exec 后端（JSON）
        └── 0_default_config
```

---

## 与 passwall2 的差异

| | passwall2 | luci-app-bypass |
|---|---|---|
| 前端 | Lua CBI / Lua controller | 现代 LuCI JS 视图（无 Lua 运行时） |
| 配置生成 | Lua `util_*.lua gen_config` | 纯 shell + jshn |
| 核心 | Xray / SingBox（自己既分流又转发） | BypassCore 分流决策；naiveproxy 转发 |
| 防火墙 | nftables + iptables | **仅 nftables** |
| 节点协议 | 多种 | 仅 NaiveProxy (https) |
| 功能 | 订阅 / ACL / haproxy / socks 自动切换 … | MVP（尚未实现订阅/ACL/haproxy） |

---

## 运行架构

BypassCore 是必需的透明分流核心，角色等同于 Passwall 的 Xray/sing-box；不存在 NaiveProxy 核心模式或自动回退。BypassCore 缺失、不是 Linux ELF、配置不兼容或监听启动失败时，服务返回失败，并且不会安装透明代理防火墙规则或接管 dnsmasq。

Basic Settings → Shunt Rule 为每条规则选择 Close、Direct、Blackhole 或具体 NaiveProxy 节点；保留的 Default 行始终最后作为兜底且不会出现在 Rule Manage。每个被引用的 NaiveProxy 节点会启动独立本机 SOCKS 实例，BypassCore 为它生成独立 `proxy_<node>` outbound，因此不同规则选择不同节点会真正生效。

### 多 WAN 出口

- 每个 Node Config 都可设置自己的 `egress_interface`，填写 OpenWrt 逻辑网络名，如 `wan`、`wan1`、`usbwan`；留空则该节点使用系统默认路由。
- 程序通过 netifd 运行时状态解析实际 L3 设备与 IPv4/IPv6 网关，兼容 DHCP、PPPoE 与设备名变化。
- 仅为被引用节点的 Naive 服务器 IPv4/IPv6 目标添加独立路由表和 `ip rule to ...`。路由表及优先级从 `naive_egress_table`、`naive_egress_rule_priority` 开始按节点递增；不改写 fwmark，因此不会覆盖 mwan3/PBR 的标记。
- `direct_egress_interface` 控制 Direct 分流的默认出口；每条选择 Direct Connection 的规则还可设置自己的 `egress_interface` 覆盖它。优先级为：规则接口 → Default Direct Interface → 系统默认路由。
- 每条 Proxy 规则可以选择不同 Naive 节点；不同节点会启动独立 Naive 实例并使用各自配置的物理 WAN，多个规则选择同一节点时共享该实例。
- Naive 出口、默认 Direct 出口或规则级 Direct 出口发生 `ifup`、`ifupdate`、`ifdown` 时会重建或撤销对应绑定；节点域名解析结果每小时刷新，刷新不完整时服务会失败关闭，避免悄悄改走系统默认 WAN。
- 守护进程默认开启，每五秒同时检查受管 PID 与真实监听端口；任一 BypassCore、NaiveProxy、dns2socks 或 ChinaDNS-NG 组件异常时执行一次完整、加锁的服务重启，确保进程、DNS、防火墙和策略路由状态一致。

## 已知限制 / 待办

- **UDP 透明代理**：NaiveProxy 的 SOCKS5 服务明确不支持 UDP ASSOCIATE，因此本项目不拦截 UDP，避免造成 UDP 黑洞。TPROXY 仅用于 TCP（包括可选 IPv6 TCP）。
- **IPv6 数据面**：启用“IPv6 TProxy”后安装 IPv6 TCP TProxy 链、策略路由与 BypassCore IPv6 listener；节点服务器出口策略本身始终支持双栈。
- **国外 DNS**：`Remote DNS Outbound = Remote` 仅支持 TCP；ChinaDNS-NG 与 BypassCore 的国外查询经 Default 规则所选节点（没有则使用首个被引用节点）的 DNS2SOCKS 中继。缺少节点/`dns2socks` 或选择其他协议时会失败关闭，避免把协议悄悄降级或直连泄漏。选择 `Direct` 时 BypassCore 可用 UDP/TCP/DoT/DoH；开启 DNS Redirect 时还需 ChinaDNS-NG 支持对应上游，因此 DoT 要求 TLS 构建，DoH 则必须关闭 DNS Redirect。
- **DNS Redirect**：开启后，dnsmasq 的上游指向已通过健康检查的 ChinaDNS-NG，并在 nftables 中把 LAN 客户端的 TCP/UDP 53 查询（包括硬编码公共 DNS 的客户端）重定向回路由器；运行期配置不会写入 `/etc/config/dhcp`。
- **路由器本机透明代理**：当前不安装 nftables OUTPUT 重定向，因为 BypassCore 尚未给 outbound socket 设置可排除的专用 mark，强行开启会让 direct outbound 递归回核心。路由器本机程序可显式使用节点 SOCKS 端口。
- **BypassCore 数据面**：nftables 只负责把符合入口条件的 TCP 送入核心；分流规则由 BypassCore 逐连接执行，Direct/Proxy/Block 不再由防火墙近似判断。
- **未实现**：订阅解析、ACL 规则、haproxy 负载均衡、SOCKS 自动切换、多语言（目前仅 zh-cn）。

---

## 许可证

MIT（见 [LICENSE](LICENSE)）。
