# 路线图

里程碑编号与任务书（原始要求见 `docs/SPEC.md`）第 15 节「执行顺序」一一对应。
**完成定义（DoD）里有真机项的里程碑，在没有设备的情况下不得标记为「完成」**，
最多 `待真机验收`。与任务书的全量差距清单见 `docs/PROGRESS.md` §9。

## M0 —— 基线与红线（已完成）

DoD：

* [x] Rust crate 骨架、GPLv3 许可证、`.gitignore`；
* [x] 依赖最小化并在清单里逐条写明取舍理由；
* [x] 禁 Lua 自动化检查 `scripts/no-lua-check.sh`，并**实测两个方向**（干净 → 0，注入 → 1）；
* [x] fwmark 布局定稿并写成不变式单测（魔数、槽位、`RULE_MASK` 只隔离槽位）。

产出：`Cargo.toml`、`src/lib.rs`、`LICENSE`、`scripts/no-lua-check.sh`。

## M1 —— 配置层（已完成）

DoD：

* [x] 原生 UCI 文本解析/序列化（不依赖 libuci，因此不需要 Lua、不需要 FFI）；
* [x] schema v4 + 默认值集中于 `schema.rs`（UI 与 `--dump-defaults` 同源）；
* [x] 就地迁移：旧键 `primary_interface`→`primary`、`failback` 布尔→枚举；
* [x] 结构化校验报告（errors/warnings/schema_version），未识别的用户键回写时原样保留；
* [x] `save`/`apply` 分离所需的三件套：`diff()`、`fingerprint()`、`Applied::{store,load}_applied`。

## M2 —— 系统交互层（代码完成，待真机）

DoD：

* [x] 手写 rtnetlink 编解码（GETRULE/GETROUTE/GETADDR，v4+v6 双族）；
* [x] 策略路由差量下发：`plan()` → `Diff` → `Applier::{apply,verify,rollback}` + `Undo`；
* [x] 优先级/掩码冲突审计 `audit_conflicts()`，只在自己的 `RULE_PRIO_BASE..+SPAN` 带内动作；
* [x] netifd 拓扑与 firewall zone 解析、`/sys` 接口计数、conntrack 按标记统计；
* [x] 唯一执行通道：绝对路径白名单 + 参数数组（不经 `sh -c`）+ 硬超时 + kill_on_drop + 输出封顶；
* [x] nftables 程序生成与能力探测脚本；
* [ ] **待真机**：`nft -c -f` / `nft -f` / `nft -a list` / `replace rule handle` 在目标设备上的实际行为；
* [ ] **待真机**：`jhash ... map`、`th sport/dport`、`type route hook output`、`flags dynamic,timeout`、
      `ether_addr` 集合、规则 `comment` —— 全部由 `probe_scripts()` 在设备上实测，探测不通过的语法
      降级为 `Issue::Warning` 而不是写进程序。

## M3 —— 健康层（已完成）

DoD：

* [x] ICMP/TCP/UDP/DNS 四类探测，均 `SO_BINDTODEVICE` + 显式源地址 bind；
* [x] ping socket（`SOCK_DGRAM/IPPROTO_ICMP`），不需要 `CAP_NET_RAW`；
* [x] 滑窗指标（RTT、抖动、丢包、不稳定度、P95；窗口 90，置信门槛 5 样本）；
* [x] `UNKNOWN→HEALTHY→DEGRADED→FAILED→RECOVERING→HEALTHY` + 预热 + 时间驱动 `tick()`；
* [x] 探测结果五分法 `Reply/Timeout/Unreachable/Unsupported/LocalError`，后两类不计入线路失败；
* [x] 状态机单测。

## M4 —— 调度层（已完成）

DoD：

* [x] 9 种算法的桶分配与动态重排，各带能力边界说明；
* [x] 动态算法的单轮搬动预算 + 优势闸门（防抖动式全量迁移）；
* [x] 主备：多级备份顺序、四条件回切、强制切换、维护模式、全灭保护；
* [x] 游戏评分与滞回择优，模式感知（`Follow` 时只允许活动线路）；
* [x] 装配层 `scheduler::decide()`：单一所有者持有 `Machine`/`Picker`，未测量首轮显式说明；
* [x] `Outcome.changed` 由真实桶图比较得出 —— 决策未变即不产生任何数据面写入（这是「不做高频全量重建」
      在应用层的落点）；
* [x] 276 个 lib 单测（其中 balancing 不变式 17 条）—— 这是 **M4 收口时**的数字，M5 之后 329，M6 之后 350，M7 地基之后 353。

## M5 —— 规则层（游戏路由）（已完成）

范围：`src/rules/{mod,matchers,presets,dns_sets}.rs`（现 2441 行，55 条单测）

DoD：

* [x] `GameSpec`：从 UCI `config game` 段编译出匹配器集合，按 (priority, name) 确定性排序
      （`rules::compile`；slug 冲突按排序顺序加 `-2`/`-3`，同一输入两次编译产物逐字节相同）；
* [x] 冲突检查：重叠目的段与同优先级歧义在 `config::validate::overlaps()`（20 条单测），
      `pin_wan` 指向已禁用/不存在的线路在 `rules::compile` 里直接报错；
* [x] 预置库：**只提供用户可自行编辑的数据文件**（`/usr/share/smartmwan/presets/*.json`），
      本项目不内置任何服务器 IP/端口，缺 `source` 的来源声明直接拒绝加载（Error）；
      `presets::tests::no_preset_is_bundled_in_code` 把这条钉住；
* [x] 域名规则 → 动态 nft 集合：`dns_sets::Registry` 按域名对账（增/删/保留分别计数），
      `flags dynamic,timeout; size 1024` 由 `firewall` 声明，寿命来自
      `global.dns_ttl_floor_s`（默认 300 秒，校验 30..86400）；
      `MAX_SET_ELEMENTS=2048` 超限在 `rules` 层报错而不是截断；
* [x] 文档化的限制：`dns_sets` 模块头六条（getaddrinfo 拿不到 TTL、CDN/anycast、
      DoH/DoT 绕过、IPv6 不进集合但计入 `v6_skipped`、不看 SNI、解析失败不算线路故障）；
* [x] 与 `GamePolicy` 的联动：主备模式 + `game_policy=follow` 时游戏规则整体不下发
      （`rules::tests::failover_follow_blocks_game_rules`），
      `selection=best` 无择优结论时进 `pending` 而不是随便指一条线路；
* [x] 端到端单测：`rules::tests::compiled_specs_are_accepted_by_firewall_build` 把规则层产物直接
      喂进 `firewall::build()`，断言集合声明与规则文本同时出现（分层契约漂移只能在这里被抓到）；
* [x] 规则层落地过程中抓出并修复**三处数据面静默放宽**缺陷：`051829f`（MAC 匹配项被 `@` 前缀过滤
      整条丢弃）、`e1f31f2`（域名条件被固定网段挤掉，且设备不支持动态集合时退化成命中全部新建连接的
      兜底规则）、`c2e8067`（`caps.ether_sets == false` 时只丢客户端条件继续下发，把「一台主机」
      放宽成「全 LAN」，而警告文案还写着「降级为不匹配」）。三者都补了「条件必须出现在最终 nft 文本里
      或规则整条不存在」的断言 —— 旧测试只验证集合被**声明**过，所以一直是绿的
      （详见 `docs/PROGRESS.md` §6.7/6.8/6.9）。

真机才能收口的项目（不属于本层 DoD，但 M10 之前不能宣称完成）：

* [ ] `nft -c` 校验生成的脚本（沙箱无 `nft` 二进制）；
* [ ] 动态集合的真实老化行为与 `dns_ttl_floor_s` 的观感一致性；
* [ ] `ether saddr` 在目标设备 nft 版本上的实测（`probe_scripts` 的 `ether_sets`）。

## M6 —— 事务层（代码完成，待真机）

范围：`src/transaction.rs`（现 2322 行，24 条单测），把 M2 的 `route::Applier` 与 `firewall::Nft`
编排成一次可回滚提交，并把 M5 的规则层真正接上（`rules::compile()` → `firewall::Input::games`）。

DoD：

* [x] **装配**：一次提交内把 `config 校验 → 内核观测 → rules::compile → firewall::build → nft 试算
      → route 下发/复核 → nft 下发/复核 → 快照` 串起来，中间任一步失败都不留下半套状态
      （`Coordinator::run` 的八阶段固定顺序 + `submit_follows_the_fixed_stage_order_and_persists`）；
* [x] 单事务锁：`AsyncMutex` 串行化所有提交，`is_busy()` 供 RPC 侧报告；
      `second_committer_waits_for_the_first_to_finish` 用「先持锁再提交」证明第二个提交者卡在入口，
      而不是插进内核操作中间；
* [x] validate → plan → dry-run → apply → verify → commit last-good；任一步失败按 `Undo` **逆序**回滚
      （`nft_verify_failure_rolls_back_nft_then_routes_in_reverse_order` 断言的回滚顺序是 nft 先、路由后，
      与下发顺序相反）；
* [x] 试算不过 / 被优先级冲突拦下 ⇒ **一次内核写入都不发生**
      （`check_failure_leaves_kernel_and_state_files_untouched`、
      `foreign_priority_conflict_blocks_before_any_side_effect`）；
* [x] 路由失败绝不进 nft 提交（否则会出现「已打标记但无策略路由」的黑洞窗口）——
      `route_apply_failure_never_reaches_nft_apply`；
* [x] 复核不通过 ⇒ 不写快照；快照写失败 ⇒ **不回滚已验证的数据面**，但 `ok=false` 并写明
      「数据面已生效但快照写入失败」（`snapshot_write_failure_is_not_reported_as_success`）；
* [x] 残留检测：`Coordinator::reclaim()` 按 `NS` 前缀 / `RULE_MASK` / `OUR_RTPROT` / 表号区间判定所有权，
      只删自己的对象，别人的规则与别人的路由保留并写进 `foreign`
      （`reclaim_deletes_ours_and_keeps_everything_foreign`、`reclaim_tolerates_a_fresh_box_with_nothing_to_clean`）；
* [x] 重启幂等：重复 apply 以 `Diff` 为空 **且** `applied.nft` 逐字节相同为证据判「无变更」，
      但仍然执行 nft 试算与两侧复核（`second_submit_of_same_config_is_a_no_op_but_still_verified`，
      调用序列 `[check, apply, check]`）；
* [x] 事务日志：每笔变更记 transaction id（`T<毫秒>-<pid>-<序号>`），与 `Applied.transaction` 对应，
      并写进 `state_dir/applied.nft` 所在快照；
* [x] 规则层接线：`game_rule_from_config_reaches_the_nft_program` 从 UCI `config game` 段出发，
      断言集合名、`ip daddr @set` 与 `smw:game:<slug>` 标签同时出现在最终程序里；
* [x] 诚实性约束：`selection=best` 无择优结论进 `pending` 而不是编造线路
      （`best_without_a_verdict_is_pending_not_fabricated`）；停用配置走「回收全部自有对象」而不是留着；
* [x] 无 nft 通道时**拒绝** enabled 提交（半套状态比不更危险），但**允许** disable 提交（清场不需要 nft）
      （`missing_nft_blocks_enabled_submit_but_allows_disable`）；
* [ ] **待真机**：以上全部用 `FirewallExec::Sim` 走编排，它**不验证 nft 语法**；真机必须换
      `FirewallExec::Real`（`nft -c -f` / `nft -f` / `nft -a list`）后重跑同一批结论（归 M10）。

落地过程中修掉两处会被事务层暴露的真实缺陷（详见 `docs/PROGRESS.md` §6.10/6.11）：
`firewall::build()` 生成了带 `comment` 的保护/绕行规则却没登记进 `Program::tags`（复核误报「多余标签」，
把正确提交判成失败）；`config::diff()` 漏了 `global.hash_seed`（应用前变更清单少报一项）。

## M7 —— RPC 与守护进程（代码完成，待真机验收）

范围：`src/rpc/mod.rs`、`src/main.rs`（原计划里的 `src/rpc/ubus.rs` **取消**：
桥接走 rpcd 的 ucode 插件直连 Unix socket，不引入 ubus 客户端，理由见 `docs/ARCHITECTURE.md` §7）

前置（本轮已完成，均有单测）：

* [x] `firewall::probe_caps(&Nft) -> Capabilities`：把 `probe_scripts()` 的 8 条脚本接到
      `nft -c`，产出能力表 —— 没有它，「按设备实测语法降级」在运行期是空的；
* [x] `netlink::HandleOps`：拥有型 `RouteOps`，`Arc::new(HandleOps(h))` 即可填进
      `transaction::Plane::ops` —— 没有它，生产环境根本构造不出 `Plane`。

DoD：

* [x] Unix socket + JSON，**29** 个方法（≥19，清单见 `docs/ARCHITECTURE.md`）；
* [x] 统一信封 `{ok, data, error{code,message,details}, timestamp, protocol}`，错误码取 `Error::code()`；
* [x] `SO_PEERCRED` 校验对端 uid，白名单为 root + 从 `/etc/passwd` 解析的 `wwwdata`（不猜 uid），
      非白名单在进入分发前一律 `permission`；
* [x] 读写互斥：读操作无副作用（不得为了「刷新」而触发下发）；
* [x] 审计日志：所有写方法（含 `probeNow`）记调用者 uid/pid、**脱敏后**的参数摘要、事务 id、结果与耗时；
* [x] CLI：`--config --check --once --dump-nft --dump-defaults --capabilities --print-config --restore-last-good`；
* [x] tokio 监督循环：探测环 + 调度环（`Scheduler::decide` → `Coordinator::submit`，桶图单独变化走
      `replace rule` 热替换）+ 域名集合刷新环 + SIGHUP 重载 + SIGTERM/SIGINT 优雅关停；
* [ ] **待真机验收**：以上全部在 WSL（真 netlink + nft 1.1.3）端到端实测通过 ——
      事务八阶段、幂等复核、崩溃后启动回收、优雅关停回收、29 个 RPC 方法请求/响应均验证；
      但目标设备的 nft 版本、接口形态（5G 重拨、双 WAN）必须以设备实测为准。
      另需验证：管理平面不失联、IPv6 不绕过、断电重启后规则不重复（M10 矩阵）。

## M8 —— 前端（代码完成，待 SDK/设备验收）

DoD：

* [x] 7 个标签页 JS 视图 + `smartmwan.css`（Grid + Flexbox，`.smw-` 作用域）；
* [x] rpcd ucode 桥 `root/usr/share/rpcd/ucode/smartmwan.uc`（零 Lua）；
* [x] `menu.d` / `acl.d` JSON，ACL 按方法粒度授权（16 读 / 12 写 / `probeNow` 单独分组），不用 `ubus: *`；
* [x] 空/加载/无权限/RPC 失败四态如实渲染；后端 note 直接透传，不写「正常」占位；
* [x] `poll.add/remove` 生命周期成对（模块级句柄自持有，根容器离开 DOM 即自停轮询）。

浏览器渲染与真机 LuCI 集成验收归 M10。

## M9 —— 打包与安装（已完成，2026-10-26）

DoD：

* [x] OpenWrt 包 Makefile（本 SDK 无 `rust-package.mk`，按研究笔记兜底自建交叉编译：
      目标三元组由 `CONFIG_ARCH`+`LIBC` 推导（注意包上下文里 kconfig 值带引号，需剥引号），
      未知组合直接报错不静默回落；链接器用 SDK 的 `TARGET_CC`；`--offline` + 锁定 `Cargo.lock`）；
* [x] **apk** 产物与维护脚本（define 名按 `include/package-pack.mk` 的 `BuildPackVariable`
      实测为 `preinst`/`postinst`/`prerm`/`postrm`，自造名字会被静默忽略），
      依赖声明不含任何 Lua 包（`firewall4 +nftables +luci-base +rpcd`）；
* [x] `root/etc/config/smartmwan`（默认 `enabled=0`）、`root/etc/init.d/smartmwan`（procd）、
      `root/etc/nftables.d/smartmwan.nft`（由 `smartmwand --dump-include` 生成，与代码同源；
      apk 内容与仓库快照逐字节一致已验证）；
* [x] 升级/卸载：`preinst` 停旧实例让守护进程优雅回收；`prerm` 停服务 + disable +
      `--reclaim` 兜底清场；`postrm` 清 firewall include 段与运行期状态文件；
      **不删用户配置**（配置归 `conffiles`，apk 内 `conffiles_static` 带校验和）；
* [x] 产物校验：aarch64 静态 ELF（musl，无 NEEDED）、安装树 20 文件齐全、
      同源文件反解比对一致、PKGINFO 许可证 `GPL-3.0-or-later`；
      可复现性说明见 `docs/TESTING.md` §5。

## M10 —— 自动化与真机验收（第一轮已完成，2026-10-26；浏览器侧 2026-10-27 补齐一轮）

DoD：

* [x] CI/脚本：`cargo test`、`no-lua-check.sh`、`--check`、`--dump-nft` 快照比对、apk 构建
      （apk 构建与全部门禁已真实执行；GitHub Actions 等在线 CI 未做，本地脚本齐备）；
* [x] `tests/*.rs` 集成测试（跨层回归）：6 个文件 / 33 条用例
      （config 6 / failover 6 / health 4 / rules 5 / scheduler 6 / transaction 6），
      2026-10-28 实测全绿；
* [x] 真机验收（ImmortalWrt SNAPSHOT / mediatek-filogic aarch64 / 内核 6.18.55 / nft 1.1.7 /
      apk 3.0.5，与构建 SDK 同源）：安装/升级/卸载、enabled=0 零触碰、nft 能力探测
      （6/8 项可用，域名规则诚实降级）、ubus 23 方法往返（当时值；M11 已扩到 29）、LuCI `admin/network/smartmwan`
      7 页 200、enabled=1 数据面（ip rule 1000 / 表 101 / `inet smw` 集合）、状态机全链路
      （unknown→failed→recovering→healthy）、幂等复核、停用回收清零、管理面不失联；
      抓出六处「测试全绿、真机必坏」缺陷并全部修复（`docs/PROGRESS.md` §6.20–6.25）；
* [x] 浏览器侧验收（2026-10-27，所有者实机使用反馈驱动）：修复四处浏览器专属缺陷
      ——LuCI `require` 返回单例实例被当构造函数、`E()` 不递归嵌套数组、
      `createHandlerFn` 回调 `this` 丢失、写 handler 自刷新丢弃 DOM——
      并完成界面全面汉化（菜单/标签/算法名/ACL 描述）；页内 TAB 确认为
      **LuCI 原生机制**（自绘方案已撤销，浏览器会话缓存导致的一度英文显示
      以退出重登解决）；
* [ ] 剩余真机项：双 WAN 均衡/主备切换与 5G 重拨（需第二线路接入 eth0）、
      断电重启幂等（需所有者断电重启后复核 ip rule 不重复）；
* [x] 最终报告：状态/改动文件/测试命令/结果/遗留问题，全部如实
      （`docs/TESTING.md` §6/§7、`CHANGELOG.md` M10 条目）。

## M11 —— 任务书差距收口（未开始）

对照 `docs/SPEC.md` 全量审计后的收口阶段，逐条清单见 `docs/PROGRESS.md` §9。
按 SPEC §15 的优先级（数据面正确 > 功能完整 > UI 精细化）排序：

DoD：

* [x] RPC 便捷形态 6 个：`switchMode` / `setPrimary` / `setBackupOrder` /
      `setAlgorithm` / `failback`（均为事务层已有能力的薄封装）+
      `diagnostics`（聚合只读诊断）—— 方法表 23 → 29（2026-10-27）；
* [x] 游戏规则命中统计：`counter` 已随规则下发，本次补齐「读回来」的链路
      （`FirewallExec::rule_counters()` → `rules::GameHits` → 主循环 30s 采样 →
      `getGames.hits`）；读不到时为 `null` 而不是 0（2026-10-27）；
* [~] 前端配置编辑（原为最大缺口，7 页全只读、`save` 从未被 UI 调用）：
      设置页与均衡页表单 ✅、主备页（主线路/备用排序/回切阈值）✅、
      系统设置页（启停/导入导出/诊断）✅；**游戏页的规则增删改与评分权重仍未做**；
* [x] 系统设置页补齐：服务启停按钮、配置导入/导出、诊断信息展示（2026-10-27）；
* [x] 总览页补齐：实时吞吐表、抖动列、主备信息、刷新指示；
      **「最近切换事件列表」改为以「最近一次事务回执 + 决策说明」呈现**
      （后端未单独提供切换事件流；如需逐条事件需新增 RPC）；
* [x] `tests/` 集成测试六件套（config/health/scheduler/failover/rules/transaction，33 条）；
* [ ] 真机剩余矩阵：双 WAN 权重/主备切换/多级备用/自动与手动回切（需第二线路）、
      七种算法真机分别验证、IPv4/IPv6 分别验证、模组重拨、firewall4 重载后规则保持、
      断电重启幂等；
* [ ] 小项：`rust-toolchain.toml`、启用前环境检查提示。

## 明确不做的事

* 不做 opkg 时代遗留的 `.ipk` 产物（25.12 起上游已换 apk）；
* 不内置任何无来源的游戏服务器 IP/端口；
* 不为了「看起来能用」而伪造未探测成功的能力；
* 不做低端嵌入式专项优化（按任务书要求，假设现代路由 CPU 足够，直接用 tokio 多线程）。
