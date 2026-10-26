# 项目要求与验收矩阵

本文件是任务书的**可核查版本**：把 15 节要求拆成条目，每条给出「实现位置」和「如何验收」。
状态图例：

* `完成` —— 代码存在且有单测覆盖；
* `部分` —— 主要逻辑存在，但有明确子项缺失（在备注里写清缺什么）；
* `未开始` —— 占位或空目录，**不得**在任何对外文档/界面里声称已完成；
* `需真机` —— 逻辑完成，但最终结论只能在路由器上取得（沙箱内没有 `nft`、没有 root）。

## 0. 硬性约束（优先级高于任何功能）

| # | 要求 | 实现位置 | 验收方式 | 状态 |
|---|---|---|---|---|
| 0.1 | 全项目零 Lua：不得有 controller/model/view/RPC 垫片 `.lua` | 结构约定 + `scripts/no-lua-check.sh` | `./scripts/no-lua-check.sh`；脚本从三个维度扫描（文件、`require("luci.*")` 内容、Makefile 依赖） | 完成（扫描器已实测：干净树退出 0，注入 `*.lua` 或 `require("luci.dispatcher")` 后退出 1） |
| 0.2 | 扫描器不得误报工具链/SDK 自带的 Lua | `scripts/no-lua-check.sh` 的 `skip` 白名单（`target/ feeds/ openwrt/ sdk* …`）+ 排除自身 | 在含有 `feeds/`、`openwrt/` 的工作树里运行仍为 0 | 完成 |
| 0.3 | 后端必须是 Rust 常驻服务，模块化而非单文件 | `src/{config,system,health,scheduler,rules,transaction,rpc}` | `ls src/*/*.rs`；单文件最大 1827 行，无「上帝文件」 | 完成 |
| 0.4 | 使用稳定工具链 + 成熟依赖，不堆实验 crate | `Cargo.toml`：仅 tokio / libc / serde / serde_json / thiserror，逐条注释「为什么不引入 ubus/rtnetlink/conntrack/libuci FFI」 | `cargo tree -d`；`cargo build --offline` 通过 | 完成 |
| 0.5 | 所有代码注释用中文 | 全 `src/**` | `grep -rL` 抽查；Review 时人工确认 | 完成 |
| 0.6 | 不考虑低端嵌入式优化（现代路由 CPU 足够）→ 使用真实异步运行时 | tokio 多线程 runtime，`src/health/probe.rs`、`src/system/netlink.rs` | `cargo test`；无自旋轮询、无 busy loop | 完成 |

## 1. 前端（LuCI 原生 JavaScript + ucode）

| # | 要求 | 状态 | 备注 |
|---|---|---|---|
| 1.1 | 7 个标签页：运行总览 / 线路管理 / 负载均衡 / 主备切换 / 游戏低延迟 / 连接与流量 / 系统设置 | 未开始 | `htdocs/luci-static/resources/view/smartmwan/` 目前为空 |
| 1.2 | CSS Grid + Flexbox，样式作用域隔离 | 未开始 | 计划 `htdocs/luci-static/resources/smartmwan/smartmwan.css`，根类 `.smw-` 前缀 |
| 1.3 | 诚实的空/加载/无权限/RPC 失败状态 | 未开始 | 后端已为每条状态准备好解释文本（见 4.6、`Outcome::explain()`），前端只需如实渲染 |
| 1.4 | 键盘可达、无装饰性动画 | 未开始 | — |
| 1.5 | RPC 版本握手，版本不符拒绝渲染 | 完成（后端侧） | `RPC_PROTOCOL=1` 已进每个信封的 `protocol` 字段，`smartmwan.hello` 返回协议版本/进程号/运行时长；**前端「版本不符拒绝渲染」的实现在 M8** |

## 2. 数据平面（策略路由 + nftables）

| # | 要求 | 实现位置 | 状态 |
|---|---|---|---|
| 2.1 | 每条线路独立路由表（`TABLE_BASE + slot`，恒 < 253） | `src/lib.rs::marks` | 完成（单测 `mark_fields_roundtrip`） |
| 2.2 | `ip rule` 只用槽位掩码，规则数恒等于启用线路数 | `marks::RULE_MASK`、`src/system/route.rs::plan` | 完成（单测 `bucket_and_gen_changes_do_not_affect_table`） |
| 2.3 | 优先级/掩码冲突审计，不破坏用户既有规则 | `route.rs::audit_conflicts`、`is_our_priority`、`RULE_PRIO_BASE/SPAN` | 完成；真机上需与用户手写规则复核（需真机） |
| 2.4 | ct mark → pktmark 继承，且**不介入他人标记** | `src/system/firewall.rs`（区间匹配 `ct mark 0x05000000-0x05ffffff`） | 完成（文本生成 + 单测）；nft 语法需真机 |
| 2.5 | 已建立连接出口保持（sticky）、NAT/回程一致 | `firewall.rs` 的 inherit 规则 + `global.conn_sticky` | 部分：逻辑与程序生成完成，未做真机连接级验证 |
| 2.6 | IPv4/IPv6 分离处理，可单独关闭 IPv6 接管 | `netlink::Family`、`route.rs::plan`、`enable_ipv6` | 完成 |
| 2.7 | 只清理自己的对象，绝不 flush 整表 | `NS="smw"` 前缀、`delete table inet smw` 单表重建 | 完成（代码层面）；需真机 |
| 2.8 | 真实核对 `/etc/nftables.d/` 机制 | `firewall.rs::include_file_text`，配合 UCI `config include` / `type 'nftables'` / `position` | 完成（依据 firewall4 ucode 源码）；需真机 |
| 2.9 | 不做高频全量重建 | 低频：整表单批原子重建；高频桶重排：仅 `replace rule ... handle N`（`Nft::replace_rule`） | 完成（设计上）；需真机确认 handle 稳定性 |
| 2.10 | 校验后下发 + 下发后回读 + 失败回滚 | `route::Applier::{apply,verify,rollback}`、`Undo`；编排层 `src/transaction.rs::Coordinator`（八阶段固定顺序 + 逆序 `unwind`） | 完成（含单测）；nft 侧在单测里走 `FirewallExec::Sim`，真实 `nft -c/-f/list` 行为需真机 |

## 3. 工作模式与算法

| # | 要求 | 实现位置 | 状态 |
|---|---|---|---|
| 3.1 | 两种全局模式：负载均衡 / 主备（多级备份） | `schema::Mode`、`scheduler::failover` | 完成 |
| 3.2 | 自动/手动回切：延迟 + 连续成功 + 预热 + 防抖 | `failback_delay_ms`、`failback_success_threshold`、`warmup_ms`、`hysteresis::Debounce` | 完成 |
| 3.3 | 强制切换、维护模式 | `failover::force/release_forced`、`WanConfig.maintenance` | 完成 |
| 3.4 | 备份线路默认不承载普通流量，除非显式开启游戏例外 | `GamePolicy::{Follow,Exception}` + `State::carries_normal_traffic` | 完成 |
| 3.5 | 六种哈希/两类动态/加权算法 | `scheduler::balancing`、`schema::Algorithm` | 完成 |
| 3.6 | 每个算法如实标注能力边界，不过度承诺 | `Algorithm::limitations()`（9 条全非空，单测 `every_algorithm_declares_limitations`） | 完成 |
| 3.7 | 不支持的选项绝不伪造 | `Algorithm::WeightedEcmp` → `Error::Unsupported`，调度层降级为 `WeightedHash` 并写入 `notes`（「算法降级」） | 完成 |

## 4. 游戏路由与低延迟

| # | 要求 | 实现位置 | 状态 |
|---|---|---|---|
| 4.1 | 预置库可维护，**绝不编造服务器 IP/端口** | `src/rules/presets.rs`：从 `PRESET_DIR=/usr/share/smartmwan/presets/*.json` 加载，单文件 512KiB 上限、跨文件重名检测、坏文件让整批失败；**代码里零内置数据**，`source` 来源字段缺失即整条拒绝 | 完成（加载器与校验，单测 `no_preset_is_bundled_in_code`/`missing_source_is_error`）；**数据文件本身未提供**，需权威来源 |
| 4.2 | 自定义 CIDR / 协议 / 端口 / 范围 | `schema::GameRule`、`parse_port_range`（逆序/超范围拒绝）、`rules::matchers`（CIDR 网络位归一、裸地址补 /32\|/128、按族分拣；`0`/`0-1024`/取反/逗号写法拒绝） | 完成 |
| 4.3 | 按 LAN 客户端 IP/MAC 匹配 | `client_ips`/`client_macs` + `validate::valid_mac` + `matchers::normalize_mac`（冒号/短横/点分统一小写）；nft 侧生成 `ether saddr @…_mac` / `ip saddr @…_cli4` / `ip6 saddr @…_cli6`；**设备不支持 `ether_addr` 集合或仅有 v6 客户端条件而 IPv6 关闭时，整条规则不下发**（丢条件等于放宽到全 LAN，见 `c2e8067`） | 完成（代码 + 存在性/不放宽断言 `051829f`、`c2e8067`）；`ether_addr` 集合与 bridge/VLAN 口上的实际匹配范围**需真机** |
| 4.4 | 域名规则 → 动态 nft 集合，并写清 DNS/CDN/DoH/IPv6/过期限制 | `src/rules/dns_sets.rs`：注册表按域对账（增/删/保留分别计数、共享 IP 取最大寿命、容量与每域上限 `MAX_DOMAINS_PER_RULE=32`/`MAX_ADDRESSES_PER_DOMAIN=32`/`DYNAMIC_SET_SIZE=1024`/`MAX_SET_ELEMENTS=2048`）、`expire()`/`refresh_stale()`（两寿命窗口）；解析 `spawn_blocking`+超时，分类 `NotFound`/`Timeout`/`LocalError`，**失败不清空旧元素也不计线路失败**。**动态集合当前是 `ipv4_addr`：AAAA 结果被计入 `v6_skipped` 并如实上报，不静默丢弃**，IPv6 域名分流实际不生效（这是能力边界，不是 bug）；六条限制写在模块头、`docs/CONFIGURATION.md` 与本表 | 完成（代码），元素真实老化**需真机** |
| 4.5 | 规则优先级、启停、冲突检查 | `GameRule.priority`（同值按名称字典序）+ `validate::overlaps()`（重叠且同优先级 → Error 并给定序建议）+ `pin_wan` 指向不存在线路 → Error；`rules::compile()` 负责启停/模式感知（主备下 `follow` 不产出、`best` 无择优结论 → `pending` 而非猜线路）、slug 去重、族分拣、超上限报错而非截断 | 完成（校验层 + 规则层，51 条单测） |
| 4.6 | 分线路质量指标 | `health::metrics`（RTT/抖动/丢包/不稳定度/P95，窗口 90 样本，`MIN_SAMPLES=5` 置信门槛） | 完成 |
| 4.7 | 可配置评分公式与归一化/夹取/滑窗/滞回/最小稳定时间 | `scheduler::latency::{ScoreWeights, ratio, clamp01}`，`min_advantage_permille`、`min_stable_ms` | 完成 |
| 4.8 | 模式感知（主备时游戏是否例外） | `scheduler::ranking()` 在 `Follow` 时只允许活动线路 | 完成 |

## 5. 健康检测状态机

| # | 要求 | 状态 |
|---|---|---|
| 5.1 | `UNKNOWN→HEALTHY→DEGRADED→FAILED→RECOVERING→HEALTHY` | 完成（`health/state.rs`） |
| 5.2 | 迁移条件可配 | 完成（`HealthConfig` 8 个阈值，线路级覆盖） |
| 5.3 | 单测覆盖迁移 | 完成（`health` 模块测试 + 时间驱动 `tick()`） |
| 5.4 | 默认 1000/800/3/5/5000ms，并声明「不适合所有 5G 模组」 | 完成（默认值 + 注释 + 本文件 §9） |
| 5.5 | 探测不得计为线路失败的类型 | 完成：`Unsupported`/`LocalError` 不改状态；`Reply/Timeout/Unreachable` 才计分 |
| 5.6 | 探测必须绑定出口设备与源地址 | 完成：`SO_BINDTODEVICE`(25) + 显式 bind + ping socket（无需 `CAP_NET_RAW`） |

## 6. RPC 与配置管理

| # | 要求 | 状态 |
|---|---|---|
| 6.1 | ≥19 个方法，见 `docs/ARCHITECTURE.md` 的方法清单 | **完成（23 个）**：Unix socket + 长度前缀帧 + JSON，`src/rpc/mod.rs`；WSL 真环境端到端验证过全部方法的请求/响应，**目标设备未测** |
| 6.2 | 统一信封 `ok/data/error{code,message}/timestamp` | **完成**：`{ok, data, error{code,message,details}, timestamp, protocol}`，`code` 取 `Error::code()` 的 12 个稳定值；信封形状与错误码映射有单测 |
| 6.3 | 严格 ACL、互斥锁、审计日志、读操作无副作用 | **完成**：`SO_PEERCRED` 取 uid，白名单 root + `/etc/passwd` 解析出的 `wwwdata`（不猜 uid），socket 0660，bind 前拒绝重复启动；写方法（含 `probeNow`）记 uid/pid、脱敏参数摘要、事务 id、结果与耗时；读方法零副作用；互斥由 `Coordinator` 单事务锁 + 主循环串行化共同保证 |
| 6.4 | UCI `save`/`apply` 分离 | **完成**：`save` 写盘并返回 diff 与校验报告（**不下发**）；`apply` 不接收 UI 配置副本，只触发主循环以磁盘上已保存的配置跑一轮完整事务；`diff` 方法返回「已保存未下发」的变更摘要 |
| 6.5 | 下发前变更摘要 | 完成：`config::diff()` + `route::Diff::summary()` + `transaction::Plan::summary`（字段变更 → 本次决策（代际/桶/时间）→ 策略路由增删与冲突 → nft 程序概述），`Plan::text()` 就是将要下发的原文，UI 可先展示再提交 |
| 6.6 | 迁移、默认值、last-good 保存与恢复 | 完成：`config::migrate()`、`Applied::{store_applied, load_applied, restore_last_good}`；事务层在**两侧复核都通过之后**才写快照 —— `state_dir/applied.json`（配置指纹 + 事务 id）与 `state_dir/applied.nft`（实际下发的原文），旧快照另存为 `applied.json.last-good`；快照写失败时 `ok=false` 且不谎报成功 |

## 7. 安全清单（11 项，逐项见 `docs/SECURITY.md`）

注入、损坏 UCI、ACL 过宽、并发事务、重启后规则重复、标记/路由不一致、残留规则、
5G 重拨导致网关变化、IPv6 绕过、探测负载、前端轮询泄漏、管理平面失联 —— 全部有对应机制或已列为待办，状态在 `docs/SECURITY.md` 里逐条给出。

## 8. 构建 / 打包 / 安装

| # | 要求 | 状态 |
|---|---|---|
| 8.1 | Makefile（OpenWrt 包）+ Rust 交叉编译 + 架构探测 | 完成：自建交叉编译（本 SDK 无 `rust-package.mk` 已实证），三元组由 `CONFIG_ARCH`+`LIBC` 推导、未知组合报错，真实 SDK（aarch64 musl）构建通过 |
| 8.2 | 依赖声明、**APK** 产物 | 完成：`+firewall4 +nftables +luci-base +rpcd`（无任何 Lua 包），apk 产物经 `apk adbdump`/`apk extract` 校验（`docs/TESTING.md` §5） |
| 8.3 | procd 服务脚本 | 完成：`root/etc/init.d/smartmwan`（term_timeout 30，respawn 阈值放宽） |
| 8.4 | LuCI menu.d + rpcd acl.d JSON | 完成（M8）：7 标签页菜单 + 方法级 ACL（无通配） |
| 8.5 | UCI 默认配置（**默认关闭**） | 完成：安装期由 `smartmwand --dump-defaults` 生成（与代码同源），`enabled='0'`；`defaults_are_safe_disabled` 单测钉住 |
| 8.6 | nftables 安装片段 | 完成：安装期由 `smartmwand --dump-include` 生成（单一 prerouting hook，占位语法保守） |
| 8.7 | 升级/卸载/回滚脚本，产物校验，可复现性说明 | 完成：四维护脚本（preinst/postinst/prerm/postrm，define 名按 `package-pack.mk` 实测）；卸载走 `--reclaim` 且不删用户配置（conffiles）；产物校验与可复现说明见 `docs/TESTING.md` §5 |
| 8.8 | 绝不覆盖用户网络配置 | 完成（设计上）：本插件只写 `/etc/config/smartmwan` 与 `/etc/nftables.d/smartmwan.nft`，对 `network`/`firewall` 只读（postinst 只幂等添加自己的 include 段） |

## 9. 测试与验收

| # | 要求 | 状态 |
|---|---|---|
| 9.1 | 功能测试 + 工程测试 | 部分：**378** 个 lib 单测 + **2** 个 bin 单测全绿；工程闸门零告警；WSL 真 nft/netlink 端到端已验证（事务八阶段、回收、23 方法、`--reclaim` 清场）；`tests/`（集成）未开始；真机矩阵归 M10 |
| 9.2 | 禁 Lua 自动化检查 | 完成 |
| 9.3 | 10 条交付判据 | 进行中，逐条见 `docs/TESTING.md` §交付判据 |
| 9.4 | 绝不把模拟数据当实时状态展示 | 设计上保证：未测量首轮会产出显式 note「尚未完成首轮探测…」，`Outcome` 无数据时 `carries_traffic()==false` |
| 9.5 | 列出未完成特性 | 完成：本文件与 `CHANGELOG.md` 的「已知缺失」段落 |

## 10. 固件与工具链事实（外部依据）

这些事实决定了本项目的结构约束，因此必须带来源（以下为撰写本文时实际检索到的页面，
链接指向来源页本身；每条描述只写该页摘要能支撑的部分）：

* 从 OpenWrt 25.12 开始包管理器由 opkg 改为 apk（Alpine Package Keeper），默认软件源配置路径
  由 `/etc/opkg/distfeeds.conf` 改为 `/etc/apk/repositories.d/distfeeds.list`；24.10 及更早仍是 opkg。
  这直接决定了 8.2 的产物格式必须是 `.apk`，且打包不能再用 opkg 的 control 流程。
  [Openwrt|镜像站使用帮助|清华大学开源软件镜像站|Tsinghua Open Source Mirror](https://mirrors.tuna.tsinghua.edu.cn/help/openwrt/)
  [OpenWrt](https://mobile.mirrors.ustc.edu.cn/help/openwrt.html)
* ImmortalWrt 与上游一致：从 ImmortalWrt 25.12 开始同样由 opkg 改为 apk，路径变化相同。
  因此本插件的 target 需要同时匹配 `openwrt-25.12` 与 `immortalwrt-25.12`。
  [ImmortalWrt 软件仓库](https://help.mirrors.cernet.edu.cn/immortalwrt/)
* 25.12 的其余底层变化包括内核升级至 6.12、Attended Sysupgrade 集成进 LuCI、
  Wi-Fi 管理脚本用 ucode 替代 shell。
  [OpenWrt 24.10用户注意：包管理器大换血，25.12升级前必看的几个关键变化](https://post.m.smzdm.com/p/a708zvpg/)
* 本插件**不得**依赖 `luci-lua-runtime`：LuCI 框架自身的去 Lua 化已在 25.12 一代完成，
  Lua 运行时是可选的独立包（此条以 `research/luci.md` 里核对过的 `luci-base` 控制文件为准）。

**未能在本环境复核的数值**：具体微版本（如内核 6.12.71/6.12.74、GCC 14.3、glibc 2.41、apk 3.0.2→3.0.5）
只出现在较早的检索摘要里，且不同服务版本对应不同内核补丁号（例如 25.12.6 的内核区间为 6.12.94→6.12.112）。
本项目**不把这些具体数值作为构建前提**；真正的构建前提是「apk 格式 + ucode LuCI + firewall4」这三条，
它们都有可复核来源。交叉编译时按 SDK 实际提供的工具链版本走，不在代码里硬编码。

> 本沙箱对 `raw.githubusercontent.com` 有 TLS 中断，`docs` 里的上游源码引用以本地已核对的 ucode 源码为准。

## 11. 执行顺序（任务书第 15 节）与当前落点

```text
1 审计仓库/固件/LuCI-ucode        完成（research/luci.md, research/buildsystem.md）
2 设计配置/RPC/数据面             完成（docs/ARCHITECTURE.md）
3 Rust 服务 + 健康状态机          完成
4 策略路由 / nftables / 事务      完成（模块 4a system/* + 4b transaction.rs；4b 待真机）
5 算法 + 主备切换                 完成
6 游戏路由                        代码完成（rules/*，51 单测）；已由事务层接线；
                                  预置数据文件仍需权威来源
7 LuCI 页面                       完成（M8：7 视图 + ucode 桥；浏览器渲染待 M10）
8 CSS                             完成（M8：smartmwan.css，.smw- 作用域）
9 打包                            完成（M9：Makefile + apk 四维护脚本 + 同源安装期文件；
                                  真实 SDK 构建并解包校验通过）
10 自动化 + 真机验证              部分（Lua 检查、单测、WSL 端到端完成；真机未做）
11 修复 + 最终报告                持续
```

当前正确落点是 **M10：真机验收**。全部代码路径（守护进程、RPC、前端、打包）都已落地，
WSL 端到端与真实 SDK 构建都已通过；剩下的每一条结论都必须在目标设备上取得
（`docs/TESTING.md` §7 的设备矩阵），前置问题是设备 SSH 口令需要所有者澄清。

安全与数据面正确性优先于界面打磨 —— 因此 §2、§5、§7 的「需真机」条目在没有设备时一律标注为未验证，
不用界面完成度掩盖它们。
