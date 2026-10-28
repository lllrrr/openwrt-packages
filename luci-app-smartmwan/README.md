# luci-app-smartmwan

面向 **OpenWrt 25.12 / ImmortalWrt（openwrt-25.12 基线）** 的多 WAN 智能选路插件：
策略路由 + firewall4/nftables 数据面 + Rust 异步守护进程 + LuCI 原生 JavaScript 界面。

**本项目不使用 Lua。** 后端为 Rust，前端为 LuCI ucode-era 原生 JS（`L.view`），
RPC 桥接为 rpcd 的 ucode 插件。仓库里出现任何 `*.lua` 都视为回归，
`scripts/no-lua-check.sh` 会把它当构建失败处理。

## 为什么只做 25.12+

OpenWrt 25.12 把包管理从 opkg 换成 **apk**，LuCI 也从 Lua 迁移到 ucode
（`luci-base` 不再带 `luasrc/`）。这两件事决定了本插件的形态：交付物是 `.apk`，
界面是 JS + rpcd ucode，而不是一份还能在 21.02 上跑的兼容代码。
兼容性细节与来源见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md#固件与工具链事实)。

## 目录结构

```text
src/                    Rust 后端（1 个库 + 1 个守护进程二进制）
  lib.rs                分层文档、错误类型、fwmark 布局（全项目最重要的约定）
  config/               UCI 文本解析 / 迁移 / 类型化模型 / 结构化校验
  system/               netlink、策略路由、接口拓扑、nftables 生成、conntrack、exec
  health/               探测（ICMP/TCP/UDP/DNS）、滑动窗口指标、线路状态机
  scheduler/            负载均衡桶分配、主备切换、滞回去抖、低延迟择优
  rules/                流量分类（游戏白名单 / 客户端匹配 / 域名动态集合）
  transaction.rs        校验→下发→回读→回滚 的单事务层
  rpc/                  Unix socket JSON RPC + ACL + 审计日志
  main.rs               守护进程入口与 tokio 监督循环
Makefile                OpenWrt 包（apk 时代；自建交叉编译 + 同源安装期文件 + 维护脚本）
root/                   打包进 apk 的运行时文件（UCI 快照、procd、fw4 自动片段、rpcd ucode/acl、menu.d）
htdocs/                 LuCI 前端资源（view JS + css）
scripts/                构建与检查脚本（含 Lua 禁用扫描）
docs/                   任务书(SPEC) / 要求对照 / 架构 / 配置 / 安全 / 测试 / 路线图 / 进度 / 交接
tests/                  跨层集成测试（6 个文件 / 33 条用例）
```

## 当前状态（2026-10-28）

后端七层（config / system / health / scheduler / rules / transaction / rpc）+
**守护进程入口** + **前端** + **打包**已实现，
`cargo test --offline` = **395 lib + 4 bin + 33 集成测试，全部通过**。
RPC 层提供 29 个方法（Unix socket + JSON 统一信封 + `SO_PEERCRED` ACL + 脱敏审计）；
守护进程 `smartmwand` 常驻运行：探测环、调度环（`Scheduler::decide` → `Coordinator::submit`，
桶图单独变化走 `replace rule` 热替换）、域名集合刷新环、SIGHUP 重载、SIGTERM 优雅关停
（关停会撤销自己的全部内核对象）。CLI 支持 `--check / --once / --dump-nft /
--dump-defaults / --dump-include / --capabilities / --print-config / --restore-last-good / --reclaim`。

端到端验证在 **WSL**（真 netlink + 真 nft 1.1.3）完成：事务八阶段、幂等复核、
崩溃（kill -9）后启动回收、优雅关停回收、29 个 RPC 方法请求/响应、`--reclaim`
对真实残留的清场与幂等复核全部实测通过，并借此修掉七处「单测全绿、真机必爆」的
缺陷（`docs/PROGRESS.md` §6.13–6.19）。
rpcd ucode 桥同样在 WSL 经 ucode CLI 对真实守护进程往返验证（含错误信封透传）；


打包（M9）已完成：真实 OpenWrt/ImmortalWrt 25.12 SDK（aarch64 musl）构建出
`.apk` 并逐项校验（四个维护脚本、同源安装期文件、conffiles、aarch64 静态二进制），
校验方法见 [docs/TESTING.md](docs/TESTING.md) §5。
**真机验收（M10）第一轮已完成**：ImmortalWrt SNAPSHOT 真机（mediatek/filogic aarch64，
nft 1.1.7）安装/升级/卸载、数据面下发、健康探测状态机、幂等回收、管理面不失联全部
实测通过；抓出六处「测试全绿、真机必坏」缺陷并全部修复（`docs/PROGRESS.md` §6.20–6.25）。
浏览器侧验收已完成一轮（2026-10-27）：修复四处浏览器专属缺陷（LuCI require
单例实例误当构造函数、E() 嵌套数组、回调 this 丢失、handler 自刷新丢弃 DOM），
界面全面汉化（菜单在「网络 → 智能多线路」），部署要求与 apk 安装/卸载语义见
[docs/CONFIGURATION.md](docs/CONFIGURATION.md) §8。
剩余：双 WAN 均衡/主备切换（需第二线路接入）、断电重启幂等。
**与任务书的全量差距清单（RPC 便捷形态、前端配置编辑、游戏命中统计、集成测试等）
见 [docs/PROGRESS.md](docs/PROGRESS.md) §9**，原始要求见 [docs/SPEC.md](docs/SPEC.md)。

**部署要求**：设备内核需放通 ping socket，否则健康探测不可用（会诚实告警而不是伪造状态）：

```sh
sysctl -w net.ipv4.ping_group_range='0 2147483647'
echo 'net.ipv4.ping_group_range=0 2147483647' >> /etc/sysctl.conf
```

原始任务书见 [docs/SPEC.md](docs/SPEC.md)；逐条完成度见 [docs/PROGRESS.md](docs/PROGRESS.md)，交付判据见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)，接手须知见 [docs/HANDOVER.md](docs/HANDOVER.md)。

## 安装（预编译包）

提升 `PKG_VERSION`、打 `v*` tag 或手动触发后，CI 会自动构建并发布：

* 下载页：<https://github.com/LianXia233/luci-app-smartmwan/releases>
* 架构：`aarch64_cortex-a53`（mediatek/filogic、ipq807x 等 ARM64 路由）
* 未签名包，安装时必须带 `--allow-untrusted`：

```sh
apk add --allow-untrusted luci-app-smartmwan-0.5.0-r1.apk
```

首次安装 `enabled=0`，不会改动现有路由；到「网络 → 智能多线路」里手动启用。
依赖 `firewall4`、`nftables`、`luci-base`、`rpcd`、`ucode-mod-socket`。

### CI

`.github/workflows/build.yml`：**只有版本号变化**（Makefile 的 `PKG_VERSION`/`PKG_RELEASE`）、
`v*` tag 或手动 dispatch 才编译 —— 日常提交不触发构建。

Rust 侧用工具链交叉编译（`rustup target` + `cargo-zigbuild`，Zig 自带 musl 运行时），
**不用** OpenWrt SDK 的 `make package/.../compile`（那会拉起整套构建系统）；
打包只借 SDK 里的 `apk mkpkg`，文件树由 `scripts/build-apk.sh` 按 Makefile 的
install 段等价组装，成功后自动创建 Release（tag `v<PKG_VERSION>`）。

## 开发环境命令

```sh
cargo test --offline --lib                           # 单元测试（395 条，无需网络/root/路由器）
cargo test --offline --bins                          # bin 测试（4 条：--reclaim 配置回落 + 下发门控）
cargo test --offline --tests                         # 集成测试（33 条：config/failover/health/rules/scheduler/transaction）
cargo clippy --offline --all-targets -- -D warnings  # Lint：必须 0 警告
cargo fmt --all -- --check                           # 风格：必须无差异
cargo build --offline --release                      # 构建 smartmwand
./scripts/no-lua-check.sh                            # Lua 禁用扫描（三个维度）
```

开发/验证环境迁到了 **WSL Debian**（root 下 `/usr/sbin/nft` 1.1.3 + 真 netlink 可用）；
`clippy` / `rustfmt` / 端到端验证都在那里跑。详见 [docs/TESTING.md](docs/TESTING.md)。

## 设计要点（读代码前先读这段）

* **fwmark 是合同**。`src/lib.rs::marks` 定义了 `0x5` 魔数 + 槽位/类别/代际/桶的位布局，
  `ip rule` 只用低 8 位掩码，因此桶图怎么变都不会让已建立连接换出口。
* **不做高频全量重建**。规则总数恒等于启用线路数；桶图变化用
  `replace rule handle`，重排受单轮预算与最小间隔约束（`scheduler::balancing`）。
* **不拼接 shell**。所有外部命令走 `system::exec` 的白名单 + 参数数组 + 超时 + 输出封顶。
* **不谎报**。`Unsupported`/`LocalError` 不计入线路失败；没有采样就说没有采样；
  没有可用线路就不分流；加权 ECMP 直接返回不支持而不是伪实现。
* **一次提交要么完整要么撤销**。事务层固定 `试算 → 路由 → 复核 → nft → 复核 → 快照` 的顺序，
  路由先于 nft（否则会出现「包已标记但无策略路由」的黑洞），复核不过绝不写快照，
  回滚按逆序执行且每一条失败都写进回执（`rollback` 非空 = 内核状态需人工确认）。
  唯一的故意例外：快照写失败时**不**回滚已经验证通的数据面，只报 `ok=false` 并说明原因。
* **默认不改变现状**。`global.enabled = 0`，首次安装不动任何用户网络配置。
* **规则层不放宽、不编造**。条件写错就报错而不是跳过（跳过等于「拦 10 段」变「拦 9 段」）；
  元素数量超上限报错而不是截断；设备不支持动态集合时**不下发该条件**，客户端条件全部失效时
  **整条规则不下发** —— 绝不退化成命中全部新建连接的宽规则；择优结论还没出来时规则进 `pending`，
  不「先随便指一条」。
* **不内置任何游戏服务器地址**。`rules/presets.rs` 只是加载器；数据文件必须写 `source`，
  否则整条拒绝（单测 `no_preset_is_bundled_in_code` 钉住代码里零内置数据）。

## 许可

GPL-3.0-or-later（见 [LICENSE](LICENSE)，SPDX 标识符与 Cargo.toml/Makefile 一致）。
