# 更新日志

遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格，
版本号遵循语义化版本。**未发布**段落反映当前工作树，而非某个已归档标签。

## [未发布]

### 变更

* **CI 与自动发布**：新增 `.github/workflows/build.yml` —— 只在版本号变化
  （Makefile 的 `PKG_VERSION`/`PKG_RELEASE`）、`v*` tag 或手动 dispatch 时编译，
  日常提交不触发。产物为 `aarch64_cortex-a53` 的 APK：Rust 用工具链交叉编译
  （`rustup target` + `cargo-zigbuild`，不跑 OpenWrt SDK 的 `make package/compile`），
  打包借 SDK 的 `apk mkpkg`，文件树由 `scripts/build-apk.sh` 按 Makefile 的 install 段
  等价组装（含 apk 需要的 `.list`/`.conffiles`/`.conffiles_static`，属主 chown 成 root）。
  打包成功后自动创建 GitHub Release（tag `v<PKG_VERSION>`，同名则覆盖附件）。
* **删除死 feature `unprivileged-tests`**（`Cargo.toml`）：声明后全仓零引用、
  Makefile 也从不打开，留着只会让人以为构建存在两套路径。同时把清单里误引的
  `docs/architecture.md「依赖策略」`改为实际存在的 `docs/ARCHITECTURE.md` §7。

### 修复

* **游戏规则 slug 跨轮漂移**（`src/rules/mod.rs`）：slug 原先只在「本轮通过状态过滤的
  规则」上分配，一条 pending（尚无择优结论）或 follow 规则恢复下发时，排在它后面的规则
  会整体改名 —— nft 标签随之变化，内核 counter 归零、命中数错位。改为新增
  `game_slugs()` 先对**全部**规则按 `(priority, name)` 分配，`compile()` 与 RPC 共用。
* **`getGames` 命中数按原始名归属**（`src/rpc/mod.rs`）：原用 `slug_of(name)` 自行计算，
  未做重名消歧 —— 中文名（slug 为空）永远显示 null，同 slug 冲突时把 A 的计数记到 B 头上。
  改用 `rules::game_slugs()` 的映射查内核计数。
* **择优结果变化不触发下发**（`src/main.rs`）：`cycle()` 原先只看桶图变化与配置指纹，
  `selection = best` 的评分变化但桶图未变时永不提交，内核停留在旧出口。现记录
  `last_picks` 并把 `picks_changed` 纳入 `needs_submit()`。
* **桶热替换的适用条件不足**（`src/main.rs`）：择优变化改的是游戏规则的标记（槽位位），
  而热替换只 `replace` 桶规则，会留下旧落点。新增 `hot_replace_allowed()`，择优变化时
  回退完整事务。
* **决策代际与热替换前提矛盾**（`src/main.rs`）：`gen` 原先在 `decide()` 桶图变化时递增，
  而 `gen` 会写进每条游戏规则的标记 —— 桶图变化时游戏规则也跟着变，「除桶图外逐字节
  相同」的热替换前提不成立、快照与内核分叉。改为只在完整事务提交时递增。
* **失败的提交不再重试**（`src/main.rs`）：桶图单次提交失败后，下一轮变化标志相对上一轮
  **决策**为假，`cycle()` 在退避检查之前提前返回，重试逻辑永远不可达。`needs_submit()`
  现在在 `!last_ok` 时强制提交，再由 `SUBMIT_RETRY_BACKOFF_MS` 节流。
* **日志时间戳在西半球偏几小时**（`src/logging.rs`）：时区偏移缓存量原为无符号，
  负的 `tm_gmtoff` 被吞成 0，整机日志按 UTC 记时；改为有符号 `AtomicI64` 并保留负值。
* **CLI 选项缺值被静默忽略**（`src/main.rs`）：`--log-level` / `--log-file` 后面没跟值
  （或直接跟了另一个选项）时原本悄悄变成 `None`，笔误不报错；现在明确报
  「需要一个参数值」。
* **决策失败可能清空数据面**（`src/main.rs`）：原实现在决策出错时返回空决策，
  下一轮提交会用空桶图覆盖已生效的分流；现在 `decide()` 返回 `Result`，失败时
  只生成 `ok=false` 回执并明说「未向内核写入任何内容」，内核保持上一轮规则。
* **RPC 写方法改配置时未复位调度器**（`src/rpc/mod.rs`）：`save` / `rollback` /
  `setMaintenance` / 改全局字段四条路径原先只替换配置并同步注册表，跳过了
  `on_config_change()` 与已删除规则的清理，与新配置的去抖计时不一致；现统一走
  `adopt_config()`，与 `reload()` 同一条路径。
* **包元数据与包内容架构矛盾**（`Makefile`）：`PKGARCH:=all` 与包内按目标架构编译的
  `smartmwand` 冲突（aarch64 包会被装到 mipsel 上直接无法执行）；已移除，回到
  SDK 目标架构。
* **CI 发布说明与产物名硬编码**（`.github/workflows/build.yml`）：Release 已按
  `${{ env.PKG_ARCH }}` 取产物、写架构行；发布说明的「空段落」检测原先永远判非空
  （安装说明本身就非空），现先摘到独立文件再判。

### 文档

* 全仓数字与状态按本轮实测重测：395 lib + 4 bin + 33 集成测试、RPC 29 方法；
  `docs/PROGRESS.md` §9.1、`docs/TESTING.md` §6、`docs/HANDOVER.md`、
  `docs/ROADMAP.md` M10 的过期表述已更正，`tests/` 集成测试状态由「未写」改为已落地。

## [0.5.0] — 2026-10-27

首个可运行的完整版本：后端七层 + 守护进程 + 前端组件系统 + 打包。
0.4.0 是开发期版本号，从未打 tag 或发布，因此首版直接用 0.5.0。

### 新增

* **仓库与构建基线**：`Cargo.toml`（1 库 + 1 守护进程二进制）、`Cargo.lock`、
  `LICENSE`（GPL-3.0-or-later 全文；初版为 GPLv2，2026-10-26 按所有者指示升级，见「变更」）、`.gitignore`。依赖刻意最小化：
  tokio / libc / serde / serde_json / thiserror，并在清单里逐条写明「不引入
  ubus / rtnetlink / conntrack / libuci FFI」的原因。
* **配置层 `src/config`**：原生 UCI 文本解析与序列化（不依赖 libuci）、
  schema v4 模型、就地迁移（旧键名 `primary_interface`→`primary`、
  `failback` 布尔→枚举）、默认值继承（线路健康参数覆盖全局）、
  结构化校验报告（errors / warnings / schema_version）。
  未识别的用户键在回写时原样保留，不静默丢弃。
* **系统交互层 `src/system`**：手写 rtnetlink 编解码（GETRULE / GETROUTE / GETADDR，
  IPv4 与 IPv6 双族）、策略路由差量下发 + 冲突审计 + 回读校验、
  netifd/`/etc/config/network` 与 firewall zone 拓扑解析、接口计数器采样、
  conntrack 按标记统计、nftables 程序生成与能力探测脚本、
  唯一外部命令通道（程序白名单 + 参数数组 + 超时 + kill_on_drop + 输出封顶）。
* **健康层 `src/health`**：ICMP / TCP / UDP / DNS 四种探测，**全部绑定出口设备
  与源地址**（`SO_BINDTODEVICE` + 显式 bind），避免「所有探测都走默认路由」这个
  多 WAN 经典错误；滑动窗口指标（RTT / 抖动 / 丢包 / 不稳定度 / P95）；
  `UNKNOWN→HEALTHY→DEGRADED→FAILED→RECOVERING→HEALTHY` 状态机含预热与
  时间驱动迁移；`Unsupported` / `LocalError` **不计入线路失败**。
* **调度层 `src/scheduler`**：静态哈希桶分配（SrcIP … FullFiveTuple /
  WeightedHash）、动态算法（LeastNewConnections / LeastTraffic）带单轮搬动预算与
  优势闸门、主备切换与四条件回切（预热 / 稳定时间 / 连续成功 / 最小间隔 + 二次确认）、
  游戏低延迟评分与滞回择优、强制切换与「目标暂不可用时保留指令」语义。
* **规则层 `src/rules`**（任务书执行顺序第 6 步「游戏路由」）：把「用户写的条件」编译成
  数据面能接受的 `firewall::GameSpec`，本身不生成任何 nft 文本 —— 匹配范围与语法兼容性
  放进同一个函数时，两类错误的表现会互相掩盖。四个模块：
  `matchers.rs`（CIDR 归一即网络位清零、裸地址补 /32|/128、按族分拣去重；端口拒绝 `0` 起点、
  `0-1024`、逆序与取反；MAC 接受冒号/短横/点分三种写法并统一小写；域名拒通配符与 URL；
  **遇到坏值一律报错而不是跳过**，跳过会让「拦 10 段」静默变成「拦 9 段」）、
  `presets.rs`（预置项从 `/usr/share/smartmwan/presets/*.json` 加载，**代码里不内置任何
  游戏服务器 IP/端口**，`source` 来源字段缺失即整条拒绝；单文件 512KiB 上限、跨文件重名检测、
  一个坏文件让整批失败而不是静默忽略）、
  `dns_sets.rs`（域名→动态集合的注册表：按域对账增量、过期、两寿命窗口的陈旧刷新，
  解析走 `spawn_blocking` + 超时并分类 `NotFound`/`Timeout`/`LocalError`，
  **解析失败不清空旧元素也不计为线路失败**）、
  `mod.rs`（`compile()` 负责预置项与规则的合并语义、slug 去重、族分拣、启停与模式感知，
  择优结论未出时进 `pending` 而不是猜一条线路）。
  新增配置项 `global.dns_ttl_floor_s`（默认 300 秒，校验 30..=86400）——`getaddrinfo`
  不返回 TTL，集合元素寿命只能取一个下界，这是明知不完备的折中而非最优值，已在 schema 注释里写明。
  端到端单测 `compiled_specs_are_accepted_by_firewall_build` 把「配置→GameSpec→nft 文本」串起来，
  契约漂移在提交前就会被抓到。本层 **51 条单测**（`dns_sets` 15 / `matchers` 12 / `presets` 10 /
  `mod` 14），lib 单测从 276 增至 328；数据面同类缺陷再修一处后为 **329**。
* **事务层 `src/transaction.rs`**（任务书执行顺序第 4 步的 4b「事务编排」，M6）：把此前各自单测的
  模块接成一条真正的提交链路 —— `校验 → 计划（观测内核 + rules::compile + firewall::build）→
  nft 试算 → 路由下发 → 路由复核 → nft 提交 → nft 复核 → 写 last-good 快照`，八阶段顺序固定。
  顺序背后是两条硬道理：nft 试算必须在任何内核写入之前（语法不过就不该碰内核）；
  路由必须**先于** nft 提交（反过来会出现「包已打上 `0x05…` 标记、策略路由还没装」的黑洞窗口，
  表现为突然全量走 main 表且没有任何报错）。失败时 `unwind()` 按逆序回滚（先 nft 后路由），
  每一条撤销失败都写进 `Receipt.rollback` 并记错误日志 —— **该字段非空就意味着内核状态需人工确认**。
  三个刻意的不对称：
  ① 复核不通过**绝不**写快照（快照只能描述设备上确实生效的状态）；
  ② 快照写入失败**不**回滚已验证的数据面，但 `ok=false` 且错误文案写「数据面已生效但快照写入失败」
  （为了一个文件没写成就拆掉通的上网路径，是把小故障升级成大故障）；
  ③ 找不到 `nft` 可执行文件时**拒绝** enabled 提交（半套状态比不更危险，也绝不只装半套路由），
  但**允许**停用提交（清场不需要 nft，两个 nft 阶段记为「跳过」并写明依据）。
  `Coordinator::submit()` 刻意**不返回 `Result`**：任何结局都是一份 `Receipt`
  （阶段记录 / issues / pending / rollback / 变更摘要 / nft 通道种类），
  因为「失败但已回滚」与「失败且未提交」对运维是两个完全不同的动作，RPC 层不得把它压成 bool。
  `reclaim()` 负责回收上次崩溃的残留：按 `NS` 前缀、`RULE_MASK`、`OUR_RTPROT`、表号区间判定所有权，
  **只删自己的对象**，别人的规则与路由保留并原文列进 `foreign`。
  幂等以证据判定（`Diff` 为空 **且** `applied.nft` 逐字节相同 ⇒ `changed=false`），但仍执行试算与两侧复核。
  规则层在这一步**第一次有调用者**：`game_rule_from_config_reaches_the_nft_program` 从 UCI `config game`
  段一路断言到集合名、`ip daddr @set` 与 `smw:game:<slug>` 标签。
  新增 **21 条单测**，lib 单测 329 → **350**。
  **限定**：nft 通道在单测里是 `FirewallExec::Sim` 替身，它**不验证 nft 语法**，只验证编排顺序；
  真机必须换 `FirewallExec::Real`（`nft -c -f` / `nft -f` / `nft -a list`）后重跑同一批结论（M10）。
* **M7 的两块地基（系统交互层）**：
  ① `firewall::probe_caps(&Nft) -> Capabilities` —— 把 `probe_scripts()` 那 8 条一次性表
  `inet smwprobe` 脚本真正接到 `nft -c` 执行路径上。此前这些脚本**只被单测引用过**，
  没有任何代码把探测结果变成能力表，也就是说「按设备实测语法降级」这条设计在运行期是空的；
  现在 `--capabilities` 与守护进程启动探测都有了唯一入口。单条探测失败不是错误，
  而是「该语法不用」，失败清单逐条进 warning（否则「游戏域名规则为什么没生效」无从下手）。
  ② `netlink::HandleOps(NetlinkHandle)` —— 拥有句柄的 `RouteOps` 实现，能 `Arc::new` 后
  塞进 `transaction::Plane::ops`。此前只有借用型的 `BlockingOps<'a>`，**生产装配没有入口**；
  不给 `NetlinkHandle` 直接实现 trait 是因为它上面已有一组同名 async 方法，
  inherent 方法优先，具体类型上会静默调到 async 那个。
  配套新增 **3 条单测**（`probe_caps_enables_everything_when_checks_pass` /
  `probe_caps_keeps_conservative_defaults_when_checks_fail` /
  `version_only_reports_a_real_string`），lib 单测 350 → **353**。
  限定：沙箱没有 `nft`，这三条注入的是 `/bin/true`、`/bin/false`、`/bin/echo`，
  证明的是「探测结果 → 能力表」的判定逻辑，**不证明任何 nft 语法在本机可用**。
* **RPC 层 `src/rpc/mod.rs`**（M7，1934 行）：Unix socket + 4 字节大端长度前缀帧 + JSON，
  统一信封 `{ok, data, error{code,message,details}, timestamp, protocol}`，错误码取
  `Error::code()` 的 12 个稳定值。**23 个方法**（任务书要求 ≥19）：`hello` / `getStatus` /
  `getLines` / `getLine` / `getBalance` / `getFailover` / `getGames` / `getGameQuality` /
  `getConnections` / `getTraffic` / `getLogs` / `getConfig` / `getCapabilities` / `validate` /
  `save` / `diff` / `apply` / `rollback` / `forceWan` / `releaseForced` / `setMaintenance` /
  `probeNow` / `reload`。鉴权用 `SO_PEERCRED` 取对端 uid，白名单只有 root 与从 `/etc/passwd`
  解析出的 `wwwdata`（**不猜常见 uid**），非白名单在进入分发前就回 `permission`。
  所有写方法（以及有网络副作用的 `probeNow`）记审计：调用者 uid/pid、**脱敏后**的参数摘要、
  事务 id、结果与耗时。读方法零副作用——不得为了「刷新」触发探测或下发。
  `apply` 的响应体是 `Receipt` 原样序列化（不得压成 bool），`apply` **不接收** UI 传来的
  配置副本，一律以磁盘上已保存的为准（`docs/REQUIREMENTS.md` 6.4）。
  状态归属是硬约束：RPC 层不保存任何业务状态，健康快照/观测/回执都由主循环写进
  `AppState` 槽位，RPC 只读；改状态的写方法经 `Command` 通道送给主循环串行执行。
  新增 **18 条单测**（方法表与架构文档逐条对齐、信封形状、12 个错误码映射、帧编解码与
  超限/零长/EOF、陌生 uid 拒绝、无主循环时写方法报错、参数缺失即 validate 错误、
  `validate` 不落任何文件、密钥字段递归脱敏、`wwwdata` 从 passwd 解析而非猜测、
  socketpair 上取 `SO_PEERCRED`、未测量时线路状态必须是 unknown、回执原样透传）。
* **守护进程 `src/main.rs`**（M7，1415 行）：单主循环 200ms tick——探测到期就跑探测轮
  （内核观测 + 探测 + 流量/连接采样），然后决策；**只有桶图真的变了、或配置指纹相对上次
  应用变了**才写数据面。桶图单独变化走 `replace rule` 热替换（只改 `smw:bucket:*` 几条，
  不重建整表），其余走完整事务；提交失败退避 5 秒再试（否则一次失败会放大成每 tick 一次的事务风暴）。
  域名集合刷新旁路 30 秒一轮：解析 → 对账 → 增量 `add/del element`，解析失败**绝不**回灌健康层。
  信号：SIGHUP 重载、SIGTERM/SIGINT 优雅关停。关停序列由**信号任务**持有并带 30 秒看门狗——
  曾经它跟在主循环后面，主循环一旦楔死，SIGTERM 就形同虚设（真机集成测试抓到的）。
  CLI：`--config --check --once --dump-nft --dump-defaults --capabilities --print-config
  --restore-last-good`。`--check` 与 `--dump-nft` 全程只读。
* **工程闸门**：`.gitattributes` 强制 LF（`* text=auto eol=lf` + 显式二进制声明），
  消除 Windows 签出 CRLF 造成的整仓假改动；lib 单测 353 → **378**，
  `src/**/*.rs` 合计 **28,283** 行。
* **前端 M8（零 Lua）**：rpcd ucode 桥 `root/usr/share/rpcd/ucode/smartmwan.uc` ——
  声明 ubus 对象 `smartmwan` 的 23 个方法及参数策略，连接守护进程 Unix socket 按
  「4 字节大端长度前缀 + JSON」转发；传输层错误映射成 rpcd 状态码，业务信封
  （ok/data/error）**原样透传**，语义只在 Rust 侧产生。socket 路径三层解析
  （uci 模块 → UCI 文本兜底 → 编译期默认），读超时 15 秒，rpcd 主循环不被无限占住。
  `root/usr/share/rpcd/acl.d/luci-app-smartmwan.json`：**方法级**授权（读 15 个、
  写 8 个、probeNow 单独分组），不用 `ubus: *` 通配。
  `root/usr/share/luci/menu.d/luci-app-smartmwan.json`：7 个标签页。
  `htdocs/luci-static/resources/smartmwan.js` 共享模块：信封解析、四态渲染
  （加载/空/无权限/RPC 失败，全部如实，不写「正常」占位）、轮询生命周期
  （poll.add/remove 成对，切页自停）、展示格式化。
  7 个视图 `htdocs/luci-static/resources/view/smartmwan/*.js`：
  status（总览+轮询）/ lines（线路+维护模式）/ balance（算法+桶图+份额条）/
  failover（主备+强制切换二次确认）/ games（规则+冲突+DNS 集合+评分）/
  traffic（连接+吞吐，3 秒轮询）/ config（待下发变更+apply+rollback+reload，
  save 与 apply 严格分离）。
  `htdocs/luci-static/resources/smartmwan/smartmwan.css`：Grid + Flexbox，
  全部 `.smw-` 作用域。
  **验证边界**：桥接已在 WSL 用 ucode CLI（从源码构建的 1.x）对真实守护进程做过
  端到端测试 —— 23 个方法全部往返正确、错误信封透传正确；**浏览器侧渲染未在真实
  LuCI 环境验证**（无 SDK/设备），归 M10。
* **打包 M9**：OpenWrt/ImmortalWrt 25.12（apk 时代）包 `Makefile` —— 本 SDK 没有
  `rust-package.mk`，按研究笔记的兜底方案自建交叉编译：目标三元组由 SDK 的
  `CONFIG_ARCH`+`LIBC` 推导（包上下文里 kconfig 值带引号，先剥引号），未知组合**直接报错**
  而不静默回落宿主机三元组；链接器用 SDK 的 `TARGET_CC`；`--offline` + 锁定 `Cargo.lock`。
  安装期文件与代码**同源**：`/etc/config/smartmwan` 由 `smartmwand --dump-defaults` 生成、
  `/etc/nftables.d/smartmwan.nft` 由 `smartmwand --dump-include` 生成，
  仓库 `root/` 下的同名文件只是评审快照。`PKGARCH:=all`（静态 musl 二进制无架构绑定依赖，
  架构约束由交叉编译目标保证）；`DEPENDS:=+firewall4 +nftables +luci-base +rpcd`，
  不含任何 Lua 包；`/etc/config/smartmwan` 列入 `conffiles`（卸载不删用户配置）。
  apk 维护脚本 define 名按 `include/package-pack.mk` 的 `BuildPackVariable` 实测：
  `preinst`（安装/升级前停旧实例，让守护进程优雅撤销内核对象）、`postinst`（幂等挂
  firewall include 段；enable/start 由构建系统生成的 `default_postinst` 完成）、
  `prerm`（stop + disable + `--reclaim` 兜底清场）、`postrm`（清 include 段与运行期状态）。
  **自造 define 名（如 `post-install`）会被构建系统静默忽略** —— 首次构建就踩了这个坑，
  用 `apk adbdump` 解包核实后才修正。
  守护进程新增两个 CLI：`--dump-include`（打包同源生成用）、`--reclaim`（一次性回收，
  卸载/排障用；配置损坏或缺失时按默认参数继续清场，所有权判定只用常量：
  优先级带 1000-1023、表号 101-124、`OUR_RTPROT`、`inet smw` 表名）。
  `netlink.rs` 的 `SO_RCVTIMEO/SO_SNDTIMEO` 时间值改经 `i64` 中转，不再点名
  `libc::time_t`/`suseconds_t` 别名（musl 1.2.0 起它们变 64 位并标记弃用，点名会刷警告）。
  新增 **2 条 bin 单测**（reclaim 配置回落），lib 378 + bin 2；
  `src/**/*.rs` 合计 **28,391** 行。
* **真机验收 M10（2026-10-26，ImmortalWrt SNAPSHOT / mediatek-filogic aarch64_cortex-a53，
  内核 6.18.55、nftables 1.1.7、apk-tools 3.0.5 —— 与构建 SDK 完全同源）**。
  真机抓出**六处「测试全绿、真机必坏」缺陷**，全部修复并配回归单测：
  ① **fw4 片段机制**：该固件的 fw4 把 `/etc/nftables.d/*.nft` 用内置 glob include 进
  `table inet fw4` **表体内部**，独立表片段放那里必然语法错误、fw4 整体拒绝加载；
  且 UCI include 段是匿名段，`uci get firewall.smartmwan` 幂等判断永远落空（升级重复加段、
  卸载残留）。改为安装到 `/usr/share/nftables.d/ruleset-post/` 自动片段目录（fw4 README
  载明的顶层位置），postinst/postrm 不再碰 UCI firewall。
  ② **依赖闭包缺 `ucode-mod-socket`**：该模块是独立包，基础 ucode/rpcd 都不带；缺了它
  rpcd 加载 ucode 桥直接抛 `No module named 'socket'`，ubus 对象无法注册。已加入 DEPENDS。
  ③ **rpcd-mod-ucode 的整数 typehint 语义**：args 声明里整数的**值是位宽提示**
  （8→INT8、16→INT16、64→INT64、其余→INT32），不是默认值 —— `limit: 16` 让 INT32
  实参被 `Invalid argument` 拒收。数字参数一律声明 `0`。
  ④ **停用清场复核误判**：首次安装 + enabled=0 + `inet smw` 表从未存在时，停用事务的
  复核对 `list chain` 报 no-such-table 没有豁免（FirewallApply 有、FirewallVerify 没有），
  把成功的清场误判为失败并回滚。复核对「期望空状态 + no-such-table」放行并写明依据。
  ⑤ **停用后决策与数据面脱节**：调度层 `decide` 不看 `enabled`，停用清场后 UI 仍显示
  「承载流量」。停用配置的决策现在显式返回全零桶（第一轮 `changed=true` 触发清场提交，
  内部状态同步归零，后续轮稳定为无变更，不会循环触发空事务）。
  ⑥ **procd init.d 的 reload 两坑**：函数必须叫 `reload_service()`（名为 `reload()` 的
  自定义函数不会被执行）；busybox 的 `start-stop-daemon -K -HUP` 退出码 0 却根本不发
  信号 —— SIGHUP 改为直接对 pidfile 记录的 PID 发。
  真机验收矩阵结果（全部实测）：安装/升级/卸载（conffiles 升级保留、卸载按 apk 语义全删）、
  enabled=0 不碰数据面、nft 能力探测（6/8 项可用；`dynamic,timeout` 集合与 jhash 种子在
  1.1.7 上仍不可用，域名规则诚实降级为告警）、ubus 23 方法全链路往返、LuCI 页面
  （`admin/network/smartmwan`）全部 200、enabled=1 数据面（ip rule 优先级 1000 + 槽位掩码、
  表 101 完整镜像、`inet smw` 保护/绕行集合精确落位）、单线路 healthy 与状态机全链路
  （unknown→failed→recovering→healthy）、实际出网、幂等复核、停用回收清零、管理面不失联。
  **部署要求（文档化，不自动改系统）**：设备需 `net.ipv4.ping_group_range=0 2147483647`
  解锁 ping socket（ImmortalWrt 默认 `1 0` 禁用，否则健康探测全部不可用）。
  菜单按仓库所有者要求移到「网络」页（`admin/network/smartmwan`）。
  新增 **4 条回归单测**（停用复核豁免正反两条 + 停用决策两条），lib **382** + bin 2；
  `src/**/*.rs` 合计 **28,549** 行。
* **工程闸门**：`cargo clippy --offline --all-targets -- -D warnings` 归零
  （20 条 lib 告警逐条修，只保留 1 处带中文说明的 `#[allow]`，在测试夹具里）；
  `cargo fmt --all` 建立基线，此后 `clippy` / `fmt --check` 与单测同为提交前置条件。
* **文档集**：`README.md`、`docs/REQUIREMENTS.md`（任务书 15 节 → 可核查验收矩阵）、
  `docs/ROADMAP.md`（M0–M10 与各自 DoD）、`docs/PROGRESS.md`（模块完成度与实测数字）、
  `docs/HANDOVER.md`（「改了会出事」的不变式清单），以及禁 Lua 自动化检查
  `scripts/no-lua-check.sh`（已实测「干净→退出 0 / 注入→退出 1」两个方向）。
* **技术文档**：`docs/ARCHITECTURE.md`（分层与决策循环、fwmark 布局、nft 对象命名、
  RPC 方法表）、`docs/CONFIGURATION.md`（UCI 键名/默认值全表与校验规则）、
  `docs/SECURITY.md`（任务书安全清单逐条对应到代码位置）、
  `docs/TESTING.md`（测试矩阵与 10 条交付标准的诚实回答）、
  `research/luci.md` 与 `research/buildsystem.md`（去 Lua 前端与 apk/rust 打包研究笔记，
  含「必须在真实 SDK 里复验」的来源声明）。
* **RPC 便捷设置方法（方法表 23 → 29）**：`switchMode` / `setPrimary` / `setBackupOrder` /
  `setAlgorithm` / `failback` / `diagnostics`。前五个只是「改一个 `global` 字段 → 落盘 →
  触发一轮事务」的薄封装（数据模型与事务原本就支持这些设置，缺的是调用形态），
  共用 `mutate_global()` 骨架：**新值与当前相同时不写盘、也不下发**（不变式 2.5：
  没有 diff 就不得有数据面写入）；`failback` 是**即时动作** —— 主线路此刻不够格就如实
  返回 `switched=false`，不留一条将来悄悄生效的指令，这是它与 `forceWan`
  （持久意志，目标暂不可用也保留指令）的分工；`setAlgorithm` 选到可能降级的算法时
  在响应里带 `hint`。  `diagnostics` 是只读聚合诊断（版本 / uptime / 校验结论 /
  能力降级 / 线路健康 / conntrack / DNS / 最近回执 / 近期告警），**零副作用**：
  不触发探测、不下发、不重载。
* **游戏规则命中统计**：`firewall::build()` 生成的游戏规则本来就带 `counter`，
  本次补的是「读回来」——`FirewallExec::rule_counters()`（**只有真实 nft 通道给数字**，
  替身与「无 nft」一律 `None`）、`rules::GameHits`（只认 `smw:game:` 标签，
  同一规则的多条 nft 规则求和）、主循环每 30 秒采样一次；`getGames` 按 slug 返回 `hits`。
  口径：**读不到就是 `null` + 原因说明**，绝不用 0 冒充「规则没命中过」。
* **LuCI 前端配置编辑（此前 7 页全只读、`save` 从未被 UI 调用）**：均衡页
  （算法 / 桶数 / 会话保持 / 最小重排间隔 / 逐线路权重）、主备页（主线路、备用顺序
  按序号排序、回切方式与阈值、**立即回切**）、系统设置页（服务启停、健康检测参数、
  日志等级、**配置导出/导入**、诊断信息、立即探测）。编辑一律走 `save → diff → apply`，
  界面不把配置直接塞给内核；未保存的修改显式摆出提示条。
* **LuCI 前端版式重做**：`smartmwan.css` 重写（语义色变量带 fallback、暗色走
  `prefers-color-scheme`、区块卡片、带状态点的徽标、表格斑马纹与 hover、
  窄屏单列、`tabular-nums` 数值、`prefers-reduced-motion` 关动效）；
  `smartmwan.js` 新增 `section/stat/kv/field/select/number/checkbox/dirty/tick` 零件；
  总览页补实时吞吐与抖动列、桶分布条形图、最近事务回执；线路页补概览卡片。
  编辑页**刻意不占用** LuCI 的 `handleSave` 保留钩子（另起 `saveConfig()`）。
* **前端组件系统（弹层 / 反馈 / 浮层 / 表单 / 加载，2026-10-27）**：新增五个平级模块
  `smwcore.js`（层级栈、滚动锁引用计数、焦点陷阱与恢复、锚定定位、SVG 图标、断点）、
  `smwoverlay.js`（Dialog 四档尺寸 / Drawer 右侧 / Bottom Sheet / Confirm）、
  `smwfeedback.js`（Toast 四类语义 + 去重 + 上限 + 进度态迁移、Loading/Progress/骨架屏）、
  `smwform.js`（字段包装 + 12 种控件 + 校验器）、`smwpopover.js`（Popover / Tooltip）；
  `smartmwan.js` 聚合为 `smw.ui.*` 并保留旧 API 兼容；样式拆为
  `smartmwan.css`（设计令牌与页面级）与 `overlay.css`（弹层），全部限定 `.smw-` 作用域，
  令牌统一 `--smw-*` 且优先继承 LuCI 主题变量。
  **交互契约**：确认框初始焦点落在「取消」、危险等级用图标+动词+可选文字确认三重表达、
  提交期间不可关闭且重复点击丢弃、失败就地显示并可重试、`beforeClose` 支持未保存拦截、
  关闭时归还焦点/滚动锁/层级/监听器、ESC 只作用于最上层。
  **响应式**：移动优先，768/1024 两个断点；Dialog 在手机上转底部面板（DOM 不变），
  Sheet 适配安全区与虚拟键盘，手机端动作按钮竖排全宽 48px。
  **验证**：`scripts/ui-smoke.js`（194 项，含 6 个视图渲染与全部组件交互契约）、
  `scripts/ui-preview.html`（加载真实模块与样式，供浏览器核对）；
  headless Chromium 在 1280/500/360 视口与深色模式下截图核对。
  修复过程中抓到的三个真实缺陷：`E()` 嵌套数组导致的多处 `[object HTML…]`、
  `content-box` 导致 360px 屏幕上输入框溢出、`Form.field` 传入 `{el,input}` 时的晦涩报错。
* **视图迁移**：7 个视图的 51 处 `ui.addNotification` 全部改为 Toast；
  健康检测 / 均衡参数 / 回切策略改用统一 Form 控件（label 关联、失焦校验、错误行）；
  配置导入导出从内联 textarea 改为 Drawer（带未保存拦截与失败重试）；
  「更多操作」收进 Popover 菜单；变更超过 5 项时可开宽屏 Dialog 查看全部；
  游戏页命中列头加 Tooltip 说明口径。
* **集成测试六件套 `tests/`**（此前该目录全空）：`config` / `health` / `scheduler` /
  `failover` / `rules` / `transaction`，共 33 条。串的是**跨模块路径**
  （手写 UCI → 解析 → 校验 → 保存 → diff；健康状态机时间线；七种算法与权重的桶图效果；
  主备切换与回切去抖时序；规则条件在最终 nft 文本里的存在性；事务八阶段/幂等/回滚/回收），
  与既有 392 条单测不重复。编写中确认两条容易写错的既有行为并写进注释：
  回切带**去抖二次确认**（条件满足后第一轮只登记意向）、滑窗容量为 90。

### 变更

* **许可证从 GPL-2.0 升级为 GPL-3.0（2026-10-26，按仓库所有者指示）**：
  `LICENSE` 换为 GPLv3 全文，`Cargo.toml` 与 `Makefile` 的 SPDX 标识符改为
  `GPL-3.0-or-later`，README / ROADMAP / TESTING 的许可证描述同步更新。
  早期提交（`f90e088`）里的 GPLv2 声明是历史事实，按「不改写已提交历史」的约定留痕。
* 骨架目录 `root/usr/share/smartmwan/games/` 改名为 `presets/`，与代码常量
  `rules::presets::PRESET_DIR = "/usr/share/smartmwan/presets"` 对齐。两处不一致的后果是
  「装了包但预置目录不存在」或「用户往 games 里放文件读不到」；今后路径以代码常量为唯一权威。
* 文档的行数口径统一为「原始文件行数（含空行与注释）」，统计命令写进 `docs/PROGRESS.md` §2；
  旧表里偏低的数字（合计 17,494）不是代码变少了，是口径不同。
* `interval_elapsed()` 现在把 `last_change_ms == 0`（从未变更过）判为「间隔已满足」，
  否则进程启动后的第一次决策会被一个不存在的历史切换永久卡住。
* `failover::Machine` 的最小切换计时改为「任何真实变更都刷新（含变为不分流）」，
  未变更（尤其全灭期间的 `None→None`）不刷新。
* `latency::Scored` 的丢包归一化基准为 0 时按「该项不参与扣分」处理，
  不再用 `max(1)` 把「关掉某项权重」变成「该项直接扣满」。

* 提交历史身份统一：13 个提交的 author/committer 全部改为 `LianXia233`（2026-10-26，
  按仓库所有者的明确指示，`git filter-branch` + `--force-with-lease` 强推）。
  **树内容与提交信息逐字节未变**，但所有短哈希都变了，因此全仓文档里的哈希引用
  （`docs/PROGRESS.md` §5 提交表、`docs/HANDOVER.md`、`docs/ROADMAP.md`、本文件的修复条目等）
  已逐条更正为重写后的值。此后不再改写历史；有旧克隆者需 `git fetch && git reset --hard origin/main`。

### 修复

* `Debounce::offer()` 触发后到下一次未命中之间保持沉默（一次性触发语义），
  避免回切/择优动作被反复执行。
* 探测批次取消路径：`JoinSet::abort_all()` 取代 `shutdown()`（后者返回 future，
  未 await 时什么都不做，取消会退化成「等全部探测跑完」）。
* **规则层三处「静默放宽匹配面」的数据面缺陷**（同一类：不报错、甚至带一条看起来合理的警告，
  只是多命中流量）：
  1. MAC 条件整条丢失（`051829f`）。生成器把匹配项拼进规则时带了一个
     `.filter(|m| !m.starts_with('@'))`，而裸集合引用恰好以 `@` 开头，于是**每一条** MAC
     匹配项都被丢掉：一条「只针对这台主机」的游戏规则退化成命中该范围内全部新建连接。
     现在集合引用一律带字段名（`ether saddr @smw_g_<slug>_mac`）且拼接处不再做任何过滤，
     并补了 `ether saddr @…` / `ip saddr @…_cli4` / `ip daddr @…_dst4` 三条存在性断言
     —— 旧测试只检查集合是否**声明**过，所以一直是绿的。
  2. 域名条件被固定网段挤掉，不支持时还退化成兜底规则（`e1f31f2`）。同一规则的 v4 目的条件
     原先只取「第一类非空」，同时写了 `target` 和 `domain` 时域名条件不生效；而域名条件因
     设备 nft 不支持 `dynamic,timeout` 集合被跳过时，规则会落到「无目的条件」分支，
     变成命中该主机全部新建连接的兜底规则 —— 比「不生效」严重得多。现在同一族的
     每个目的条件各出一条规则，只有「本来就没有任何目的条件」时才下无目的规则，
     并去掉了循环外多推的一条重复所有权标签。
  3. 客户端条件全部失效时规则被放宽到全 LAN（`c2e8067`）。规则用 `client_mac` 限定主机，
     而设备 nft 不支持 `ether_addr` 集合时，代码只丢掉该匹配项并写一条警告 ——
     少一个条件不是「不生效」而是「匹配面变大」，降级后命中**全 LAN** 的新连接；
     且警告文案写的是「已降级为不匹配」，与真实行为相反。现在客户端条件全部无法生效时
     **整条规则不下发**（与域名条件同一原则），并把文案改成如实描述。
     共同教训：能力降级路径必须能证明「匹配面没有变宽」—— 断言最终文本里条件还在，或规则整条不存在。
* 安装期 nftables 静态占位（`firewall::include_file_text()`）不再声明第二条挂
  `prerouting` 的 `output` 链：链名与 hook 类型不一致是语义错误（重复注册同一 hook），
  而 `type route hook output` 属于未经设备实测的语法，写进静态占位会让 fw4 在不支持的
  内核上直接启动失败。`output` 链改为运行期按能力探测结果添加，并加了对应断言。
* **`Nft::version()` 把「子进程跑完了」当成「取到版本了」**（本轮修）。旧实现是
  `exec::run(&inv).await.ok().map(...)`：`exec::run` 只在超时或无法启动时返回 `Err`，
  退出码非 0 是 `Ok(Outcome { status: 1 })`，于是 `nft --version` 失败会返回 `Some("")`。
  这会造出第三种状态 —— 既不是「没装 nft」也不是「版本未知」，而是「版本为空」，
  而 `--capabilities` 会把它当有效版本号写进能力表。现在构造失败、执行失败、退出码非 0、
  stdout 与 stderr 全空这四种情况一律 `None`，并各记一条 warning。
* **带 `comment` 的保护/绕行规则没登记进 `Program::tags`**（`9abc322`，M6 暴露）。
  `firewall::build()` 为保护源地址与绕行目的地址生成了 4 条带标签的规则，却只把游戏与桶规则
  登记进 `tags`。M5 之前没人拿 `tags` 与内核实际规则做集合比对，所以漏登记一直没被发现；
  事务层的复核阶段一比就露馅，报「多余标签」——**把一次本来正确的提交判成失败并回滚**。
  现在生成文本与登记 tag 在同一处完成。教训：`tags` 不是元数据，是复核的判据，二者必须同源。
* **`config::diff()` 漏了 `global.hash_seed`**（`9abc322`）。改种子会重排全部新建连接的落线，
  属于用户必须「在应用前看得见」的变更，但变更清单里不出现，`smartmwan.diff` 的摘要就少报一项。
  同类问题只能靠「diff 覆盖 schema 全部字段」的核对来防，新增字段时除 `schema.rs` /
  `decode` / `encode` / `validate` 外还要过 `diff()` 这一关。
* **M7 集成测试（WSL + 真 nft/netlink）抓出的六处「单测全绿、真机必爆」缺陷**。
  它们的共同点：替身（`FakeNetlink` / `FirewallExec::Sim` / `/bin/true`）不验证真实语义，
  所以此前 353 条单测一条都没红。逐条：
  1. **`nft -c` 缺 `-f`**（`system/exec.rs`）。试算调用构造的是 `nft -c <脚本路径>`，
     nft 把路径当命令解析，报 `syntax error, unexpected /` —— 真机上**每一笔**事务都会
     死在试算阶段。正确形式是 `nft -c -f <文件>`。回归测试锁死 check 调用里
     `-c` 与 `-f` 成对出现。
  2. **探测脚本收尾是 `{}` 而不是 `}`**（`system/firewall.rs`）。`probe_scripts()` 的 `mk()`
     用了格式字符串 `{{}}`，产出的是两个字面量 `{}`，整条脚本以 `{}` 结束 ——
     **每一条** mk() 探测都被 `nft -c` 拒绝，能力表大面积假降级（`comments=false`
     会让按标签复核与 handle 定位整体失效）。回归测试断言脚本花括号配平、
     以单独一行 `}` 收尾、无裸 `{}` 行。
  3. **带网关的路由用了 `scope link`**（`system/netlink.rs` / `system/route.rs`）。
     内核对「scope link + gateway」直接 ENETUNREACH 拒绝安装；iproute2 对 `via GW`
     一律用 global scope。回归测试断言 `default_v4` 与 plan 产出的 v4/v6 网关路由
     都是 `RT_SCOPE_UNIVERSE`，无网关的链路级默认路由保持 link。
  4. **netlink socket 的超时从未生效**（`system/netlink.rs`）。`SO_RCVTIMEO`/`SO_SNDTIMEO`
     写在了 `SOL_NETLINK` 层（内核只认 `SOL_SOCKET`），setsockopt 静默 ENOPROTOOPT ——
     没有超时的 netlink recv 会在内核不回复时**永久挂住**整个 spawn_blocking 线程
     （实测：主循环卡死、探测轮全停、SIGTERM 都杀不掉）。另外 `tv_usec` 多乘了 1000。
     现在超时设不上直接判致命错误，拒绝启动。
  5. **成功 ACK 不终结会话**（`system/netlink.rs`）。内核的成功 ACK 也是 `NLMSG_ERROR`
     （error==0），解析器只对 `code != 0` 置 `done`，于是每次**成功**的 netlink 写入都继续
     等下一批消息直到超时 —— 实测表现是「路由装上了，却报 recv 超时并回滚」。
  6. **路由 dump 不按请求的表过滤**（`system/netlink.rs`）。内核的 `RTM_GETROUTE` dump
     **忽略请求里的 rtm_table**（实测请求 101 会连 main/local 的路由一起返回），
     而代码按 24 张表各 dump 一遍：表 101 的路由被收进 24 份，`reconcile` 据此产生
     24 条重复删除 —— 第一次成功、其余全部 ESRCH，启动/关停回收整体失败
     （残留规则会跨重启累积）。现在按响应消息自带的 `rtm_table` 客户端过滤。
* **`drop` 当「不分类」**（`system/firewall.rs`）。没有 LAN 设备时程序下发的是裸 `drop`：
  prerouting 里的 drop 会断掉包括管理面在内的全部流量，把一次配置解析问题放大成全网瘫痪，
  与项目「管理平面不失联」的核心要求直接冲突（代码注释与 issue 文案写的都是「分类规则已全部停用」）。
  改为 `counter comment "smw:no-lan-devices"`：流量原样走 main 表（= 插件安装前行为），
  标签留在链里供 `nft list` 与事务复核看见这个状态。
* **`Registry::record()` 把「没有迁移」当成「未知线路」**（`system/mod.rs` 之外的 `health`）。
  它用一个 bool 同时表达「追踪器没找到」和「没有发生状态迁移」，于是一次普通的无迁移探测
  也会打出「收到未知线路 wan 的探测结果，已丢弃」的假日志 —— 排障时把人带偏。
  现在两者分开，返回值只表达「有没有迁移」。
* **关停序列跟在主循环后面**（`src/main.rs`）。主循环一旦楔死（上面第 4 条那种），
  「先停循环再回收」的代码永远走不到，SIGTERM 形同虚设。现在关停序列由信号任务持有，
  带 30 秒看门狗：到点主循环还没停就强制走同一序列（限时回收 + 删 socket）并退出。
  回收本身也包了 20 秒硬超时——它要抢事务锁，楔死的事务持着锁时不能把退出也搭进去。

### 已知缺失（尚未实现，别当作已完成）

* ~~`src/rpc`（Unix socket JSON RPC + ACL + 审计）——占位。~~ **已实现**（M7，23 方法 +
  18 单测），但只在 WSL 真 netlink/nft 环境做过端到端验证，**未在目标设备上验证**。
* ~~`src/main`（守护进程入口与 tokio 监督循环）——占位。~~ **已实现**（M7）。装配、
  周期循环、桶轮换热替换、域名刷新环、SIGHUP/SIGTERM 都已接线并有真机环境的行为验证；
  `--check` / `--dump-nft` / `--capabilities` / `--once` 等 CLI 可用。
* **真机（目标 OpenWrt/ImmortalWrt 设备）验证：未做**。本轮的端到端验证发生在 WSL
  （Debian + 内核 6.18 + nft 1.1.3 + 真 netlink）：事务八阶段、幂等复核、崩溃后启动回收、
  优雅关停回收、23 个 RPC 方法的请求/响应都实测通过。但 WSL 的 nft 1.1.3 缺
  `dynamic,timeout` 与 jhash 种子参数（能力探测如实报了不可用），设备上的 nft 版本
  （预期更新）会给出不同结论，**必须以设备实测为准**。
* 预置项**数据文件**未提供（`root/usr/share/smartmwan/presets/*.json`）：加载器与校验已就位，
  但因「不得编造服务器 IP/端口」，在拿到可引用来源之前不入库任何具体地址。
* 域名集合的**周期刷新环**未接：`rules::dns_sets` 的对账与解析逻辑完成，
  但没人按 `dns_ttl_floor_s` 定时驱动它（M7 的监督循环）。
* LuCI 前端 7 个页面、CSS、rpcd ucode 桥、ACL JSON、menu.d JSON——未创建。
* OpenWrt 包 Makefile、procd 脚本、UCI 默认配置、`/etc/nftables.d` 片段、
  apk 维护脚本——未创建。
* 真机验证：**未做**。沙箱是 root 容器，但没有 `nft` 二进制、没有 netfilter 支持、
  没有路由器；`ip rule` / `ip route` 只读可用，因此 netlink 解码有单测背书，
  下发路径、fw4 语法、LuCI 页面与 apk 安装全部未经真实设备验证。
  本轮新增两项只能在设备上确认：`flags dynamic,timeout` 集合的实际老化行为，
  以及 `ether saddr @set` 在 bridge 口与 VLAN 子接口上的匹配范围。
  M6 之后还多一项：**事务层的八阶段编排在真实 `nft` 通道上是否仍然成立**
  （单测走的是 `FirewallExec::Sim` 替身，只证明顺序与回滚逻辑，不证明语法）。
* 沙箱可交付的静态结论已齐：`clippy -D warnings` 0 告警、`fmt --check` 无差异、
  `build` 0 告警、353 单测通过、禁 Lua 检查通过 —— 这五项每次提交前重跑。

## [0.3.0] — 2026-10-26（内部里程碑）

* 健康层探测与服务闭合（218 单测）。

## [0.2.0] — 2026-10-26（内部里程碑）

* 系统层策略路由与 netlink 编解码。

## [0.1.0] — 2026-10-26（内部里程碑）

* 配置层与 fwmark 布局定稿。
