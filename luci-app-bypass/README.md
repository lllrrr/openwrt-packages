# luci-app-bypass

OpenWrt 上的网关级透明分流代理。把三个各司其职的组件组合成一个 LuCI 应用：

| 组件 | 角色 | 数据面 |
|---|---|---|
| **BypassCore** | **分流核心**：规则匹配 → 路由决策引擎（domain/IP/GeoIP/port/process 规则 + DNS 子系统 + 负载均衡 + 多 WAN outbound 绑定） | 决策（输出 tag + 绑定语义） |
| **naiveproxy** | 流量承载（https，`redir`/`tproxy` 透明监听） | 实际转发 |
| **ChinaDNS-NG** | DNS 分流（国内域名 → 国内 DNS；国外域名 → 远程 DNS） | DNS 转发 |

数据面仅依赖 **nftables (fw4)**；前端为现代 LuCI **JavaScript** 视图（**无 Lua 运行时**）。

> **关于 BypassCore 的角色**：BypassCore 是一个独立的**分流(routing)子系统**——完整的规则匹配引擎 + 多上游 DNS（UDP/TCP/DoT/DoH + 域名分流）+ Observatory 探测 + 多 WAN outbound 绑定模型。本应用把它定位为**分流决策大脑**：从同一份 UCI 分流规则生成 `config.json`，由 LuCI 的“路由测试 / DNS 解析 / Observatory 探测”页面直接调用 `bypasscore -test` / `-resolve` / `-observe`。流量承载由 naiveproxy 完成（BypassCore 的 outbound 描述符只携带绑定语义，不自行拨号）。
>
> BypassCore 源码：<https://github.com/kinmeic/BypassCore>，`make build` 即可编译，release v1.0.0 提供 OpenWrt 预编译包（`bypasscore-openwrt-aarch64_cortex-a53.tar.gz`、`bypasscore-openwrt-x86_64.tar.gz` 等）。

---

## 工作原理

```
LAN 客户端
   │
nftables TPROXY/REDIRECT
   │            │
  直连         代理目标
   │            │
  wan        naiveproxy (redir/tproxy://127.0.0.1:<REDIR_PORT>)
                 │  proxy = https://<user>:<pass>@<server>:<port>
                 ▼
              naive 服务器 (HTTP/2)

DNS:  dnsmasq :53 → ChinaDNS-NG :<dns_port>
       china-dns  = 国内 DNS   (国内域名 → 国内 IP → 直连)
       trust-dns  = 远程 DNS   (国外域名 → 国外 IP → 代理)
       add-tagchn-ip → nftset `bypass_chn`  (运行时由 chinadns-ng 填充)
       group vpslist → nftset `bypass_vps`  (节点服务器 IP → 永远直连)

出口接口 (naive→server 走指定接口，目的 IP fwmark 策略路由)：
  解析 naive 服务器 IP → nftset `bypass_uplink`
  nft mangle OUTPUT: ip daddr @bypass_uplink → meta mark set <FWMARK>
  ip rule:  fwmark <FWMARK> lookup <TABLE>
  ip route table <TABLE>: default via <iface-gw> dev <iface>  (隧道则 dev-only)
```

- naive **保持 root**，所以 tproxy/tun 不会因丢权限而失败。
- 出口接口有 **全局默认** + **节点级覆盖**；服务器 IP 变更时在启动 / 规则更新 / hotplug 时重新解析。

---

## 依赖关系

Makefile 只硬依赖 shell 运行时必要项；其余全部是 menuconfig 里的**可选勾选**（`INCLUDE_*`）：

- 硬依赖：`curl ip-full resolveip libubox coreutils-nohup coreutils-timeout`
- `Nftables_Transparent_Proxy`（默认 y）：`nftables kmod-nft-tproxy kmod-nft-socket kmod-nft-nat dnsmasq-full + dnsmasq_full_nftset`
- `INCLUDE_NaiveProxy` → `naiveproxy`（受架构限制，排除 mips/mips64 等）
- `INCLUDE_ChinaDNS_NG` → `chinadns-ng`
- `INCLUDE_Geoview` → `geoview`
- `INCLUDE_V2ray_Geo` → `v2ray-geoip` + `v2ray-geosite`
- `INCLUDE_Tcping` → `tcping`

> **本应用不再支持 iptables (fw3)**，仅 nftables。

> **BypassCore** 是独立项目（<https://github.com/kinmeic/BypassCore>），由本应用调用但不打包进 `luci-app-bypass`。从 release 下载对应架构的 OpenWrt 预编译包，或自行 `make build`（源码是可编译的 Go 项目），把 `bypasscore` 二进制放到 `/usr/bin/bypasscore`（或改 UCI 选项 `bypass.global.bypasscore_file`）。应用启动时会校验它是 Linux ELF；若缺失或不是 Linux ELF（例如误放了 macOS/darwin 包），则 LuCI 的“路由测试 / DNS 解析 / Observatory”页面会自动禁用并给出 UI 提示，不影响透明代理本身的转发。

---

## 编译安装

把本目录放到 OpenWrt 源码树里（例如 `feeds/luci/applications/luci-app-bypass` 或直接 `package/luci-app-bypass`），然后：

```sh
# 在 OpenWrt buildroot 里
make menuconfig        # LuCI → Applications → luci-app-bypass，按需勾选 INCLUDE_* / 透明代理后端
make package/feeds/luci/luci-app-bypass/compile V=s
# 产物：bin/packages/<arch>/luci/luci-app-bypass_*.ipk

opkg install luci-app-bypass_*.ipk
```

安装后：
1. 安装 BypassCore：从 <https://github.com/kinmeic/BypassCore/releases> 下载对应架构的 OpenWrt 包（`bypasscore-openwrt-*.tar.gz`），解出 `bypasscore` 放到 `/usr/bin/bypasscore`（或改 `bypass.global.bypasscore_file`）。
2. 把 `geoip.dat` / `geosite.dat` 放到 `/usr/share/v2ray/`（或安装 `v2ray-geoip` / `v2ray-geosite`）。
3. LuCI → 服务 → Bypass，填节点、选出口接口、启用。

---

## UCI 配置（`/etc/config/bypass`）

```sh
config global
    option enabled '1'
    option node 'naive1'
    option node_socks_port '1070'
    option dns_redirect '1'
    option bypass_as_core '0'               # 0=naiveproxy承载(BypassCore仅诊断) | 1=BypassCore当核心(实验性,需BypassCore补SOCKS5拨号器)
    option bypasscore_file '/usr/bin/bypasscore'
    option naive_file '/usr/bin/naive'
    option chinadns_file '/usr/bin/chinadns-ng'
    option default_egress_interface 'wan2'   # 空 = 系统默认路由
    option naive_egress_fwmark '0x2'
    option naive_egress_table '200'

config global_forwarding
    option tcp_proxy_way 'redirect'   # redirect | tproxy
    option tcp_redir_ports '1:65535'
    option udp_redir_ports '1:65535'
    option ipv6_tproxy '0'

config global_dns
    option domestic_dns 'auto'        # auto = 自动检测运营商 DNS
    option remote_dns '1.1.1.1'
    option remote_dns_protocol 'udp'  # udp|tcp|tls|https
    option query_strategy 'UseIPv4'
    option chinadns_listen_port '10553'

config global_rules
    option v2ray_location_asset '/usr/share/v2ray/'
    option domainStrategy 'IpIfNonMatch'

config shunt_rules 'China'
    option network 'tcp,udp'
    option domain_list 'geosite:cn'
    option ip_list 'geoip:cn'
    option outbound '_direct'         # _direct | _proxy | _block

config nodes 'naive1'
    option type 'NaiveProxy'
    option address 'naive.example.com'
    option port '443'
    option username 'user'
    option password 'pass'
    option egress_interface ''        # 空 = 用全局 default_egress_interface
```

---

## 目录结构

```
luci-app-bypass/
├── Makefile                          # luci.mk + INCLUDE_* 可选依赖
├── po/zh-cn/bypass.po                # 中文翻译
├── htdocs/luci-static/resources/view/bypass/
│   ├── overview.js                   # 状态面板 + 路由测试 + observatory + config 预览
│   ├── global.js forwarding.js dns.js
│   ├── node_list.js node_config.js   # 仅 NaiveProxy (https)
│   ├── shunt_rules.js rule_update.js log.js
└── root/
    ├── etc/init.d/bypass             # rc.common + flock + 延迟启动
    ├── etc/uci-defaults/luci-bypass  # 首次安装：拷默认配置、防火墙 include、chmod
    ├── etc/hotplug.d/iface/98-bypass # ifup 重启 / ifupdate 刷新
    └── usr/share/bypass/
        ├── utils.sh                  # 共享库（含出口 fwmark 路由、ELF 校验）
        ├── app.sh                    # 编排：get_config / run_naive / run_chinadns_ng / gen_bypasscore_config / start/stop
        ├── nftables.sh               # nft 透明代理 + 出口 mangle 标记
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

## 运行模式（`bypass_as_core`）

两种模式可切换（UCI `bypass.global.bypass_as_core`）：

- **0（默认，legacy）**：naiveproxy 承载流量（`redir`/`tproxy` 透明监听 + https 出站），BypassCore 仅做诊断（`-test`/`-resolve`/`-observe`）。ChinaDNS-NG 做实时 DNS 分流 + `bypass_chn`/`bypass_vps` nftset 填充。
- **1（BypassCore 当分流核心）**：BypassCore 以 `bypasscore -run -c <cfg>` 常驻当透明代理核心（inbound `tcp_redir` + sniff + route + outbound `freedom`/`blackhole`/`proxy`(SOCKS5→naiveproxy)），naiveproxy 降为 BypassCore 的 SOCKS 上游（只跑 `socks://127.0.0.1:<node_socks_port>` + https 出站）。生成给 BypassCore 的 config 含 `inbounds` 段（按 `tcp_proxy_way` 选 `redirect`(TCP) / `tproxy`(TCP+UDP)）。nftables REDIRECT/TPROXY 指向 BypassCore 的 `REDIR_PORT`。
  - **前置条件已满足**：BypassCore `e60bd1f`+ 已补齐 proxy 模式 SOCKS5 拨号器（`proxy/socks`）+ UDP TPROXY listener（`app/inbound/udp_tproxy_*`）。模式 1 现可完整跑通：直连 / 丢弃 / 经 naiveproxy 代理 三支都通，TCP+UDP（tproxy 模式）都覆盖。

## 已知限制 / 待办

- **UDP 透明代理**：`redirect` 模式只代理 TCP（naive 的 `redir` 监听；BypassCore legacy 模式的 inbound 也只 TCP）。需要 UDP 代理时切换到 `tproxy` 模式——模式 0 需 naive 用支持 tproxy 的构建编译；模式 1（`bypass_as_core=1`）由 BypassCore 的 UDP TPROXY listener 处理（`tcp_proxy_way=tproxy` 时 inbound network=tcp,udp）。
- **BypassCore 数据面**：`-test` 路由预览严格按规则匹配；实际 nftables/ipset 是基于集合的尽力近似，两者共享同一份规则定义但逐连接语义可能略有差异。
- **未实现**：订阅解析、ACL 规则、haproxy 负载均衡、SOCKS 自动切换、monitor/tasks 守护进程、多语言（目前仅 zh-cn）。

---

## 许可证

MIT（见 [LICENSE](LICENSE)）。
