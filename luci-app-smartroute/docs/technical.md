# 技术说明

面向开发者与需要直接改配置的用户。设计背景与取舍见 [PRD](PRD.md)。

## 工作原理

- 数据面在 LAN 口的 eBPF（TCX）里完成：出方向读取发往设备的明文 DNS 应答，记录“IP → 域名”；入方向在每个新连接的第一个包上按“设备 → 分流顺序 → 规则组 → 出口”判断并打标记，记入连接表，后续包沿用同一出口。
- 转发走内核策略路由：`ip rule fwmark` + 每个出口一张路由表。v4 下一跳是网关 IP，v6 下一跳是网关的 link-local 地址；线路 / 隧道出口直接走接口。
- 主路由始终是设备的 v4 / v6 网关，插件只在转发时改下一跳，所以不用改 DHCP、RA 或设备设置，也不使用 fake-ip。
- 后台是一个 Go 静态程序（cilium/ebpf，无 cgo）：读 UCI 配置、编译规则组、写 eBPF 表与路由表、健康检查、定时更新 geosite / geoip。

运行要求：内核 ≥ 6.6（TCX）。程序没有 CO-RE 重定位，不需要内核 BTF（`/sys/kernel/btf/vmlinux`），也不需要 kmod-sched-bpf、tc、bpftool。

## 目录结构

| 目录 | 内容 |
| --- | --- |
| [`ebpf/`](../ebpf) | 数据面 eBPF 程序与校验器注意事项 |
| [`cmd/smartroute`](../cmd/smartroute)、[`internal/`](../internal) | 后台（Go） |
| [`luci/`](../luci) | LuCI 界面（网络 → 智能分流）、rpcd 插件、翻译（`po/`） |
| [`openwrt/`](../openwrt) | 三个安装包的 Makefile；`smartroute/files/` 是默认配置、procd 启动脚本、fw4 include 登记；`keys/` 是软件源公钥 |
| [`scripts/`](../scripts) | `build-packages.sh` 交叉编译并用 OpenWrt SDK 打包；`i18n.py` 翻译检查与 lmo 生成；`oui.sh` 厂商前缀表 |
| [`test/`](../test) | `pve/` PVE 测试环境与回归测试；`ui-check/` 界面检查（无头浏览器） |

## 编译与打包

```sh
go generate ./internal/bpf    # 改了 ebpf/*.c 后重新生成（需 clang + libbpf-dev）
go test ./...
CGO_ENABLED=0 GOARCH=arm64 go build -trimpath -ldflags '-s -w' -o smartroute ./cmd/smartroute   # MIPS 加 GOMIPS=softfloat

# 打包：<SDK 所在目录的下载地址> <输出目录> <版本>；设 KEY_DIR 时同时生成签名的软件源
./scripts/build-packages.sh https://downloads.immortalwrt.org/releases/24.10.6/targets/x86/64 out 0.3.0
```

推送 `v*` 标签时，GitHub Actions 为 24.10（ipk）/ 25.12（apk）× 7 种架构打包并签名，发布到 Releases，并把软件源与原型页面部署到 GitHub Pages。签名私钥保存在仓库 Secrets（`SMARTROUTE_KEY_BUILD`、`SMARTROUTE_APK_KEY`）。

界面原文为英文，中文在 `luci/po/zh_Hans/smartroute.po`。改了界面文字后运行 `python3 scripts/i18n.py pot` 并补翻译，`python3 scripts/i18n.py check` 检查是否齐全。注意 LuCI 自带语言包里已有的原文会优先使用 LuCI 的译法。

## 配置（UCI）

界面中的设置都保存在 `/etc/config/smartroute`，也可以直接用 UCI 配置：

```
config global 'main'
	option enabled '1'                # 其余项见 openwrt/smartroute/files/etc/config/smartroute
	list interface 'br-lan'           # 工作接口，可多个（如再加 br-guest）
	option block_dot '0'              # 1 = 拒绝设备访问 853 端口（DoT / DoQ），使其回退到明文 DNS

config group 'proxy'                # 设备组
	option name '需要代理'

config device 'phone'               # 设备：MAC 规则（管 v4 + v6）或 IP 规则（v4 按 IP，v6 按该 IP 当前的 MAC）
	option name '手机'
	option mac 'aa:bb:cc:dd:ee:ff'    # 或 option ip '192.168.1.10' / 网段
	list group 'proxy'

config rule_group 'cn'              # 规则组：xray 格式（geosite:、geoip:、domain:、full:、IP 段）
	option name '国内'
	list rule 'geosite:cn'
	list rule 'geoip:cn'

config exit 'side'                  # 出口：gateway（局域网里另一台设备）| interface（线路 / 隧道）
	option name '代理网关'
	option ip '192.168.1.2'           # interface 类型改用 option network 'wg0'
	option ipv6 'follow'              # follow：v6 也交给网关 | v4only：拒绝 v6，设备回退 v4 | none：不处理
	option dns ''                     # 可选：出口 DNS（IPv4，如 192.168.1.2 或 8.8.8.8，可带 :端口），留空用主路由 DNS
	option dns6 ''                    # 可选：出口 IPv6 DNS（非 link-local，可带 [地址]:端口）；留空时按 dns 自动获取
	option dns_fail 'fallback'        # 出口 DNS 不可用时：fallback 沿故障切换链换用其他出口的 DNS，最后用主路由 | router 用主路由 | keep 不换
	option dns_fail_traffic '0'       # 1：出口 DNS 不可用时流量也切到备用出口
	option dns6_none 'reject'         # IPv6 查询没有可用出口时：reject 拒绝（设备改查 IPv4）| router 交给主路由
	option dns_check 'www.google.com' # 检测出口 DNS 用的域名
	option dns_nohijack '1'           # 网关出口：网关自身的 DNS 查询不被主路由的 DNS 劫持
	option fallback ''                # 故障时改用的出口，空 = 直连
	option check_interval '5'         # 健康检查间隔（秒），0 不检查；连续 2 次失败切换
	option check_ip ''                # v4 探测地址，默认网关本身；填外部地址则经该网关探测
	option check_ip6 ''               # v6 探测地址，默认网关的 v6 下一跳；v6 探测失败时只拒绝 v6

config policy                       # 分流：按顺序匹配，命中第一条即生效
	list source 'proxy'               # all | 设备组 | 设备
	list rule_group 'cn'              # 省略 = 全部目标
	option invert '1'                 # 规则组取反：非国内
	option exit 'side'                # 出口，或内置的 direct / reject
```

`/etc/init.d/smartroute reload` 后生效，已建立的连接保持原出口。

## 出口 DNS

出口配置了 `dns` 时，命中分流的设备查询命中的域名，查询改发到该出口的 DNS：

- eBPF 解析设备发出的明文 UDP 53 查询，按“设备 × 域名”命中分流后打上实际流量出口的 mark；`.lan`、`.local`、`.arpa`、dhcp 的本地域名与单标签主机名始终交给主路由。
- 同一设备 10 秒内又发起 TCP 53 连接（应答被截断后的重查），这条连接跟随刚才的出口。TCP 首包没有域名，超过 10 秒的 TCP 查询交给主路由。
- nft 表 `inet smartroute`：`dns_mark`（prerouting mangle+10）按 DNS 的实际去向改 mark，`dns_pre`（dstnat-1，早于 ImmortalWrt 的 DNS 劫持）DNAT 到该出口的 DNS，`dns_post` 对经网关的查询做伪装让应答回到主路由，`dns_fwd` 在路由选定后清掉 mark（开启流量卸载时，内核会按这个 mark 给回程查路由，应答会被送到网关），`dns_v6_in` / `dns_fwd` 拒绝没有可用出口的 IPv6 查询。
- 去向：流量出口的 DNS 可用就用它的；不可用时按 `dns_fail` 处理。“可用”指出口检测正常、有对应地址族的路由（IPv6 还要求出口转发 IPv6 且已找到下一跳）、DNS 检测正常。IPv6 查询沿同一链只找有 IPv6 路由的出口，找不到时按 `dns6_none` 处理（IPv4 查询走出口时才拒绝）。
- 检测：按 `check_interval` 经出口（带出口 mark）查询 `dns_check` 的 A 记录，NOERROR / NXDOMAIN 算正常；连续 2 次失败判为不可用，连续 2 次成功判为恢复。`check_interval` 为 0 时不检测，视为可用。
- 网关自身的查询：ImmortalWrt 默认开启 `dhcp.@dnsmasq[0].dns_redirect`，把所有 UDP 53 查询重定向到本机。`dns_nohijack` 开启时，网关 MAC 发出的 UDP 53 查询在 `dns_pre` 里抢先 DNAT 到原目标（地址不变，wan 区伪装照常），重定向不再生效。
- 诊断页的“模拟访问”显示实际生效的去向（含回退），来自运行状态里的 `Routes`。

## 命令行

| 命令 | 作用 |
| --- | --- |
| `smartroute status` | 运行状态、出口检测结果、事件、每条分流的命中次数（JSON） |
| `smartroute trace <设备 MAC 或 IP> <域名或 IP>` | 流量走向测试：这台设备访问这个目标会走哪个出口、为什么 |
| `smartroute dns [域名或 IP]` | 查看域名记录 |
| `smartroute update` | 立即更新 geosite / geoip 数据文件 |

## 测试

在 Proxmox VE 上的隔离实验环境里进行，被测路由为 ImmortalWrt 24.10 / 25.12 虚拟机，说明见 [`test/pve/`](../test/pve)。`test/pve/backend-test.sh` 是后台回归测试（故障切换、v6 探测、AAAA 屏蔽、DoT 拦截、接口出口、多工作接口、前缀变化等 15 项），`test/pve/dns-test.sh` 是出口 DNS 测试（UDP / TCP、IPv4 / IPv6 传输、各种回退、网关自身查询与劫持，30 项），`test/ui-check/` 是界面检查。
