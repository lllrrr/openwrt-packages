# handoff 计划（smartroute 简化版）

状态：2026-11-24 多网关版 + 目标 IP 组完成：后端（root/usr/sbin/handoff）与 LuCI 页面都已在 PVE 实验环境实测通过（`test/lab.sh` 113 项全过；页面用 Playwright 实测渲染、弹窗、保存写 UCI、自动 reload、ACL）。前后端约定见 SPEC.md（本文件下面的单网关描述已过时，以 SPEC.md 和代码为准）。未提交，未建 GitHub 仓库，未打包发布。

## 思路

主路由只按「设备组 × GeoIP」判断，不看域名、不嗅探、不改设备设置、不用 fake-ip。需要代理的流量整条交给局域网里的另一台网关，网关收到什么就代理什么；国内 / 国外靠网关 DNS 的分流区分（DNS 层，不是嗅探）。

```
设备查 DNS ──(走网关的设备：nft DNAT)──> 网关 DNS（真实 IP 模式，按域名分国内 / 远程解析）
设备新连接 ──> 主路由按 设备组 × GeoIP 判断 ──> 国内：直连（硬件卸载）
                                              └> 其余：fwmark → 专用路由表 → 网关 → 网关直接代理
网关不通 ──> 新连接直连，DNS 转发撤掉回到主路由 dnsmasq；恢复后都切回
```

## 规则模型

- 设备组：名称、MAC 列表、IP / 网段列表（v4 / v6）。按 MAC 识别，IPv6 隐私地址也认得。
- 规则：从上到下，第一条命中的生效；条件 = 设备组（空 = 全部设备）× GeoIP 类别（空 = 任何目标，可取反）；去向 = 网关 / 直连。都不命中 → 直连。内网、本机、组播始终直连。
- 只影响新连接：判断结果记在 ct mark（M_DONE / M_GW），改规则、切网关状态都不改已有连接。
- GeoIP 数据：MetaCubeX/meta-rules-dat 的 `geo/geoip/<类别>.list`（v4 / v6 混在一起的 CIDR 文本），默认经 jsDelivr 镜像下载，地址可配置。缺数据的规则整条跳过（防止“空集合 + 取反”把全部流量交给网关）。缺数据每 5 分钟重试，有数据每天更新。

## 转发

- nft `table inet handoff`：prerouting mangle 在新连接首包上跳 `decide` 链判断；交给网关的走 `goto gw4 / gw6`（状态链，网关正常 = 打网关 mark，不通 = 记为直连）。
- ip rule：`fwmark → lookup main suppress_prefixlength 0`（局域网、隧道等具体路由优先）→ `fwmark → table 3100`（默认路由指向网关）。
- 网关自身流量按 IP 和 MAC 排除，防止绕圈。关 IPv4 send_redirects、丢 IPv6 nd-redirect。
- 交给网关的连接在主路由上是单向的（网关直接回给设备），不会进入卸载，正好避开 openwrt#18471（打 mark + 卸载回程 MAC 错误）。握手后的包被 conntrack 判为 invalid、没有 ct mark：pre 链对 invalid 包逐包重新判断，gw 链直接打 fwmark（meta mark 写在 ct mark 前）。fw4 的 drop_invalid 必须关（默认关）。

## IPv6

| 状态 | 国内 v6 | 该交给网关的 v6 |
|---|---|---|
| 网关有 v6 且正常 | 直连 | 交给网关（table 3100 `default via 网关v6`） |
| 网关没有 v6 / v6 不通 | 直连 | `prohibit`，设备立刻回退 IPv4 → 交给网关 |
| 网关整体不通 | 直连 | 直连 |

AAAA 不过滤（保住国内 v6），靠 prohibit 让设备回退。

## DNS（待写）

- 走网关的设备 = 出现在任一「去向网关」启用规则里的设备组（规则不选设备组 = 全部设备）。
- 这些设备的 UDP/TCP 53（不论原目标，含写死的 8.8.8.8:53）DNAT 到 `网关:DNS 端口`，并对这些被 DNAT 的查询做 masquerade（网关把应答回给主路由）。
- IPv6 DNS：网关有 v6 → DNAT 到网关 v6；没有 → 拒绝（端口不可达），设备改用 v4 DNS 服务器。
- 网关不通：清空 DNS 转发链，查询回到主路由 dnsmasq；不改 /etc/config/dhcp、不重启 dnsmasq。
- 网关侧要求：真实 IP 模式（不开 fake-ip），DNS 按域名分国内 / 远程。设备自带 DoH 拿到的也是干净 IP，不用管。

## 故障检测

procd 托管的 `handoff watch` 循环：每 interval 秒 ping 网关（可选：经网关访问一个 IPv4 字面量网址，代理进程挂了也能发现），连续 3 次失败切直连，一次成功切回；IPv6 网关单独检测。

## 待做

1. 脚本加 DNS 转发链（含故障时清空）。
2. `/etc/config/handoff` 默认配置（默认一条：全部设备，GeoIP `cn` 取反 → 网关；未启用）。
3. `/etc/init.d/handoff`（procd：start 成功才起 watch；配置改动和 lan 接口 up 时 reload）。
4. LuCI：一个页面 = 基本设置（启用、网关 v4 / v6、DNS 端口、检测地址、局域网接口、状态、立即更新 GeoIP）+ 设备组表 + 可排序规则表；menu.d、acl.d。
5. OpenWrt Makefile（PKGARCH all，依赖 firewall4、ip-full）。
6. PVE 实验环境测试（先停 lab-router 上的 smartroute）：分流矩阵（check.sh 同款）、DNS 转发、故障切换与恢复、v6 三种状态、流量卸载开启时的长连接。
7. README；GitHub 建公开仓库 r1172464137/luci-app-handoff 并推送；之后再加打包发布工作流（参考 smartroute 的 build-packages.sh 与签名软件源）。
