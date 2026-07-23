# luci-app-bypass

OpenWrt 上的网关级透明分流代理。把两个各司其职的组件组合成一个 LuCI 应用：

| 组件 | 角色 | 数据面 |
|---|---|---|
| **BypassCore** | **必需分流核心**：透明入口、规则匹配、路由决策及原生 WireGuard outbound | 实时数据面核心 |
| **naiveproxy** | Naive HTTPS 协议适配器，为 BypassCore 提供本机 SOCKS 上游 | 节点连接 |

数据面仅依赖 **nftables (fw4)**；前端为现代 LuCI **JavaScript** 视图（**无 Lua 运行时**）。

> **关于 BypassCore 的角色**：BypassCore 对本项目而言等同于 Passwall 的 Xray/sing-box，是不可替代的透明分流核心。它负责透明入口、规则匹配、DNS、Observatory 和 outbound；NaiveProxy 仅把 Naive HTTPS 节点转换成本机 SOCKS 上游。核心不可用时服务明确启动失败，不会回退到 NaiveProxy。
>
> BypassCore 源码：<https://github.com/kinmeic/BypassCore>，`make build` 即可编译。luci-app-bypass 1.8.0 要求 BypassCore v1.4.0（配置 schema 5）或更新版本，并按机器可读的 capability 清单校验所需能力，而不是只比较版本号。

---

## 工作原理

```
LAN 客户端
   │
nftables TPROXY/REDIRECT
   │
BypassCore (redirect/tproxy://0.0.0.0:<REDIR_PORT>)
   ├── direct / block
   ├── NaiveProxy 节点 → naiveproxy 本机 SOCKS → Naive 服务器
   └── WireGuard 节点 → 进程内用户态 WireGuard 隧道 → WireGuard peer

DNS:  dnsmasq :53 → BypassCore DNS :<dns_port>
       国内/直连 DNS → DNS server.outboundTag=direct
       国外 DNS → DNS server.outboundTag → 所选 Naive SOCKS（TCP/DoT/DoH）
       Direct/节点域名 → 带 tag 的国内 DNS 策略
                      └→ BypassCore 原生 netlink writer
                         ├→ TTL 元素 `bypass_direct_dns`
                         └→ TTL 元素 `bypass_vps`（节点服务器 IP 永远直连）

出口接口 (NaiveProxy→服务器走指定逻辑网络)：
  netifd 解析 wan/wan1/usbwan → 实时 L3 设备、地址、网关
  解析 Naive 服务器 IPv4/IPv6 → ip rule to <SERVER> lookup <TABLE>
  ip/ip -6 route table <TABLE>: default via <runtime-gateway> dev <l3-device>
```

- 每个 NaiveProxy 节点可独立配置出口接口；留空时继承 Default Naive Interface。服务器 IP 变更时在启动 / 规则更新 / hotplug 时重新解析。
- BypassCore 路由、DNS 策略和 DNS→NFTSet 映射可通过控制面事务式热重载；候选集合会在切换快照前完成内核探测。独立的 fw4 reload 和“清空 NFTSet”操作也会重新探测当前集合，同时刷新内核元数据与 writer 去重状态。改变节点进程、dnsmasq、nftables 或 listener identity 的配置自动降级为完整重启。GeoData 内容更新仍需完整重启，因为相同配置 hash 不会强制重建快照。
- 路由解释、Observatory 和 DNS 诊断只查询正在运行的控制面，不再启动临时 BypassCore 进程。

---

## 依赖关系

本项目只支持 fw4/nftables。透明代理内核模块是安装时硬依赖；NaiveProxy 与 GeoData 工具仍可按需通过 menuconfig 选入：

- 硬依赖：`ca-bundle curl ip-full resolveip libubox nftables kmod-nft-nat kmod-nft-tproxy kmod-nft-socket`
- `INCLUDE_NaiveProxy` → `naiveproxy`（受架构限制，排除 mips/mips64 等）
- `INCLUDE_Geoview` → `geoview`
- `INCLUDE_V2ray_Geo` → `v2ray-geoip` + `v2ray-geosite`

> **本应用不再支持 iptables (fw3)**，仅 nftables。

> **BypassCore 是必需依赖**，但它目前是独立项目且未进入 OpenWrt 官方 feeds，因此不能把 `+bypasscore` 写进本包依赖（官方 SDK 会无法解析）。请先从 [BypassCore Releases](https://github.com/kinmeic/BypassCore/releases) 安装 v1.4.0 或更新版本的对应架构 `.ipk` / `.apk`，或放置相应 Linux ELF 到 `/usr/bin/bypasscore`。应用启动时会校验 schema 5、Unix 控制面、显式 DNS outbound、原生 final outbound、DNS 结果 NFTSet writer/probe、原生 TCP connect 探测、WireGuard client outbound 和结构化健康状态；不满足要求时不会接管防火墙和 DNS。节点延迟测试直接复用运行中的控制面，不再依赖 `tcping` 包或临时探测进程。

> **ChinaDNS-NG 已完全移出本项目运行链。** BypassCore 直接保留 `full:`、`domain:`、裸 substring、`regexp:`、`keyword:` 和 `geosite:` 语义，最终命中带 tag 的上游后，把成功的 A/AAAA 结果通过 netlink 批量写入 NFTSet。目标 set 会检查 family、地址类型与 `timeout` flag，新元素按 DNS TTL 自动过期；不再需要辅助进程、10553 端口、dnsmasq 分域复制或 geosite 文本展开。

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
1. 安装 BypassCore v1.4.0 或更新版本：从 <https://github.com/kinmeic/BypassCore/releases> 下载对应架构的 OpenWrt 包，解出 `bypasscore` 放到 `/usr/bin/bypasscore`（或改 `bypass.global.bypasscore_file`）。
2. 使用 NaiveProxy 节点时安装 NaiveProxy；WireGuard 节点不需要外部协议进程。
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
    option bypasscore_dns_listen_port '10554'

config nodes 'naive1'
    option remarks 'Node 1'
    option node_type 'naiveproxy'
    option protocol 'https'
    option address 'naive.example.com'
    option port '443'
    option egress_interface 'wan1'    # 空 = 继承 Default Naive Interface
    option username 'user'
    option password 'pass'

config nodes 'wg1'
    option remarks 'WireGuard Node'
    option node_type 'wireguard'
    option secret_key 'BASE64_PRIVATE_KEY'
    option public_key 'BASE64_LOCAL_PUBLIC_KEY'
    list wireguard_address '10.0.0.2/32'
    option mtu '1420'

config wireguard_peer
    option node 'wg1'
    option public_key 'BASE64_PEER_PUBLIC_KEY'
    option endpoint 'wg.example.com:51820'
    list allowed_ips '0.0.0.0/0'
    list allowed_ips '::/0'
    option pre_shared_key 'BASE64_PRESHARED_KEY' # 可选
    option keep_alive '25'

config global_rules
    option v2ray_location_asset '/usr/share/v2ray/'
    option domainStrategy 'IpIfNonMatch'
    option write_ipset_direct '1'
    option enable_geoview_ip '1'
    option direct_egress_interface 'wan1'
    option default_naive_interface 'wan2'
    option default_node 'naive1'       # 虚拟 Default 行；未匹配流量走 naive1

config shunt_rules 'China'
    option network 'tcp,udp'
    option domain_list 'geosite:cn'
    option ip_list 'geoip:cn'
    option outbound '_direct'         # 空 | _default | _direct | _blackhole | 节点 section id
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
│   ├── node_list.js node_config.js   # NaiveProxy / WireGuard 节点
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
        ├── app.sh                    # 编排：多 Naive 节点 / BypassCore DNS+NFTSet / start-stop
        ├── monitor.sh                # 运行文件变更 + PID/端口健康检查，必要时完整重启
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
| 核心 | Xray / SingBox（自己既分流又转发） | BypassCore 分流及 WireGuard；naiveproxy 适配 Naive HTTPS |
| 防火墙 | nftables + iptables | **仅 nftables** |
| 节点协议 | 多种 | NaiveProxy (https)、WireGuard client |
| 功能 | 订阅 / ACL / haproxy / socks 自动切换 … | MVP（尚未实现订阅/ACL/haproxy） |

---

## 运行架构

BypassCore 是必需的透明分流核心，角色等同于 Passwall 的 Xray/sing-box；不存在 NaiveProxy 核心模式或自动回退。BypassCore 缺失、不是 Linux ELF、配置不兼容或监听启动失败时，服务返回失败，并且不会安装透明代理防火墙规则或接管 dnsmasq。

Basic Settings → Shunt Rule 为每条规则选择 Close、Default Node、Direct、Blackhole 或具体 NaiveProxy/WireGuard 节点；Rule Manage 的拖动顺序会显式持久化。虚拟 Default 行始终最后作为兜底，其值保存在 `global_rules.default_node`，不会创建或占用 `shunt_rules` section。每个被引用的 NaiveProxy 节点会启动独立本机 SOCKS 实例；WireGuard 节点则作为 BypassCore 进程内 outbound，均可被规则独立选择。

### 多 WAN 出口

- 每个 Node Config 都可设置自己的 `egress_interface`，填写 OpenWrt 逻辑网络名，如 `wan`、`wan1`、`usbwan`；留空则继承 `default_naive_interface`，两者都为空才使用系统默认路由。优先级为：节点接口 → Default Naive Interface → 系统默认路由。
- 程序通过 netifd 运行时状态解析实际 L3 设备与 IPv4/IPv6 网关，兼容 DHCP、PPPoE 与设备名变化。
- 仅为被引用节点的 Naive 服务器 IPv4/IPv6 目标添加独立路由表和 `ip rule to ...`。路由表及优先级从 `naive_egress_table`、`naive_egress_rule_priority` 开始按节点递增；不改写 fwmark，因此不会覆盖 mwan3/PBR 的标记。
- `direct_egress_interface` 控制 Direct 分流的默认出口；每条选择 Direct Connection 的规则还可设置自己的 `egress_interface` 覆盖它。优先级为：规则接口 → Default Direct Interface → 系统默认路由。
- 每条 Proxy 规则可以选择不同 Naive 节点；不同节点会启动独立 Naive 实例并使用各自配置的物理 WAN，多个规则选择同一节点时共享该实例。
- Naive 出口、默认 Direct 出口或规则级 Direct 出口发生 `ifup`、`ifupdate`、`ifdown` 时会重建或撤销对应绑定；节点域名解析结果每小时刷新，刷新不完整时服务会失败关闭，避免悄悄改走系统默认 WAN。
- 运行期 watcher 会记录 BypassCore、NaiveProxy 可执行文件的指纹；通过 `opkg`/`apk` 更新并稳定后会执行一次串行完整重启，确保新版本实际生效。关闭进程健康监控不会关闭二进制更新检测。
- 守护进程默认开启，每十五秒检查受管 PID、真实监听端口和 BypassCore 聚合 readiness（含原生 NFTSet writer）；任一必需组件持续异常时执行一次完整、加锁的服务重启，确保进程、DNS、防火墙和策略路由状态一致。

## 已知限制 / 待办

- **UDP 透明代理**：无 WireGuard 节点启用时仍默认阻断外部转发 UDP。WireGuard 节点启用后，UDP 由独立 TProxy inbound 送入 BypassCore；规则若把 UDP 交给 NaiveProxy 则失败关闭。UDP No Redir Ports 始终直连，并可能暴露真实出口 IP。
- **IPv6 数据面**：启用“IPv6 TProxy”后安装 IPv6 TCP/按需 UDP TProxy 链、策略路由与 BypassCore IPv6 listener；所选 outbound 必须支持 IPv6。
- **国外 DNS**：`Remote DNS Outbound = Remote` 时，TCP、DoT、DoH 可经 NaiveProxy 或 WireGuard；UDP 可经 WireGuard，NaiveProxy UDP 会被拒绝。选择 `Direct` 时可使用 UDP/TCP/DoT/DoH。路径缺失时失败关闭，不会悄悄改走真实 WAN。
- **DNS Redirect**：开启后，dnsmasq 只有一个上游，即已通过 TCP/UDP 健康检查的 BypassCore DNS inbound。需要直连解析的分流域名与节点域名在核心内匹配带 tag 的国内 DNS policy，其 A/AAAA 结果由同进程的有界异步 writer 合并后写入带 timeout 的 NFTSet。nftables 同时把 LAN 客户端的 TCP/UDP 53 查询（包括硬编码公共 DNS 的客户端）重定向回路由器；运行期配置不会写入 `/etc/config/dhcp`。
- **路由器本机透明代理**：当前不安装 nftables OUTPUT 重定向，因为 BypassCore 尚未给 outbound socket 设置可排除的专用 mark，强行开启会让 direct outbound 递归回核心。路由器本机程序可显式使用节点 SOCKS 端口。
- **BypassCore 数据面**：nftables 把符合入口条件的 TCP，以及启用 WireGuard 时的 UDP，送入核心；分流规则由 BypassCore 逐连接执行，Direct/Proxy/Block 不再由防火墙近似判断。
- **未实现**：订阅解析、ACL 规则、haproxy 负载均衡、SOCKS 自动切换、多语言（目前仅 zh-cn）。

---

## 许可证

MIT（见 [LICENSE](LICENSE)）。
