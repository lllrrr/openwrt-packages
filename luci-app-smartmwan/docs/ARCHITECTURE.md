# 架构

设计目标只有一句话：**把「决策」与「下发」彻底分开，让每一层都能单独测试，同时保证
任何一次对内核的写入都是可解释、可回滚、幂等的。**

## 1. 分层

```text
                    ┌────────────────────────────────────────────┐
   LuCI JS 视图 ────│ rpcd ucode 桥 (smartmwan.uc)                │  零 Lua
                    └───────────────┬────────────────────────────┘
                                    │ Unix socket + JSON（统一信封）
                    ┌───────────────▼────────────────────────────┐
                    │ rpc        方法路由 / ACL / 互斥 / 审计      │  已完成（M7）
                    └───────────────┬────────────────────────────┘
                                    │ 只调用公开方法，不复制状态
                    ┌───────────────▼────────────────────────────┐
                    │ scheduler  装配层：唯一持有状态机与择优器    │  完成
                    │  ├─ failover  主备/多级备份/回切/强制        │
                    │  ├─ balancing 桶→槽位分配（静态+动态）      │
                    │  ├─ latency   游戏评分与滞回择优            │
                    │  └─ hysteresis 防抖/最小间隔                │
                    └───────┬───────────────────────┬────────────┘
              读状态 ▲      │ 决策 Outcome          │ 规则
        ┌────────────┴──┐   ▼                       ▼
        │ health        │ ┌──────────────────────────────────────┐
        │ 探测+指标+状态机│ │ transaction 校验→下发→回读→回滚       │  代码完成 / 待真机
        └────────────▲──┘ └───────┬──────────────────┬───────────┘
                     │            │                  │
        ┌────────────┴────────────▼──┐   ┌───────────▼────────────┐
        │ config  UCI 解析/校验/迁移  │   │ system                │
        │       /diff/last-good      │   │  route   策略路由差量   │
        └────────────────────────────┘   │  firewall nft 程序生成  │
                                         │  netlink / interface / │
                                         │  conntrack / exec      │
                                         └────────────────────────┘
```

`rules`（M5，代码完成；**调用者是 `transaction::Coordinator::build_plan()`**）位于 `config` 与 `transaction` 之间，四个子模块：
`matchers`（纯函数归一：CIDR/端口/MAC/域名/slug）、`presets`（数据文件加载器，**代码零内置地址**）、
`dns_sets`（域名→动态集合的注册表 + 解析，纯内存，不碰 nft）、
`mod::compile`（合并预置项与规则、模式与启停感知、产出 `Vec<firewall::GameSpec>`）。
它不碰内核、不做决策、**不生成任何 nft 文本**。

## 2. 每层的职责边界（越界就是设计错误）

| 层 | 允许做 | 禁止做 |
|---|---|---|
| `config` | 读写 `/etc/config/smartmwan`、迁移、校验、diff、last-good | 读内核状态、执行命令 |
| `system` | 观察内核（netlink/`/sys`/`/proc`）、下发内核对象、执行白名单命令 | 做任何「哪条线路更好」的判断 |
| `health` | 探测、算指标、跑状态机 | 决定谁承载流量、写内核 |
| `scheduler` | 决策（唯一状态所有者） | 直接写内核 |
| `rules` | 把规则编译成匹配器与 nft 对象描述（`GameSpec`）、维护域名→地址的内存注册表 | 决策出口、绕过 `GamePolicy`、**生成 nft 文本**、把解析失败当成线路失败 |
| `transaction` | 编排提交与回滚 | 修改决策内容 |
| `rpc` | 鉴权、序列化、调用上面各层 | 自己保存业务状态 |

## 3. 数据流：一次周期决策

```text
1. health::run_round()          并发探测全部线路（额度受 max_concurrent_probes 限制）
2. Registry::record()           结果进滑窗 → 状态机迁移（Unsupported/LocalError 不计数）
3. interface::resolve_all()     重解析设备/地址/网关（5G 重拨后网关会变，必须每轮重算）
4. conntrack::snapshot() +
   interface::sample_traffic()  动态算法的输入
5. scheduler::decide()          → Outcome{buckets, changed, active, standby, notes, …}
6. Outcome.changed == false     → **不调用 submit()**：决策没变就不产生任何数据面写入
7. transaction::submit(cfg, Decision{bucket_map, picks, gen, now_ms})
   ├─ Validate   config::validate::validate()，有 error 直接拒绝，不进 plan
   ├─ Plan       观测内核 → rules::compile() → firewall::build()（含 protect/bypass/游戏/桶）
   ├─ FirewallCheck  nft 试算（`nft -c`），在任何内核改动之前
   ├─ RouteApply     route::Applier::apply()（失败即止，绝不进 nft 提交）
   ├─ RouteVerify    回读 ip rule / 路由表（空 diff 也复核，用证据而非「执行成功」说话）
   ├─ FirewallApply  nft 提交（先压回滚记录再提交）
   ├─ FirewallVerify nft list 回来按链比对 tags
   └─ Persist        最后一步才写 applied.json + applied.nft（last-good）
   任一阶段失败 ⇒ unwind() 逆序回滚（先 nft 后路由），回执 Receipt.rollback 非空

（旁路，不在这条周期链上）rules::dns_sets::refresh_stale() → resolve() → observe()
   → 只对域名规则做，按 `dns_ttl_floor_s` 的下界节流；解析失败**不回灌** health 层的线路状态。
（旁路）桶轮排的热替换：`Nft::replace_rule(handle, body)` 只改那几条桶映射规则，
   不重建整表 —— 见 §4「bucket 在标记里但不在 `ip rule` 掩码里」。
```

`transaction` 层的三条约定（M7 的调用方必须遵守，改动前先想清楚代价）：

1. **阶段顺序不可调换**：nft 试算在任何写入之前；路由先于 nft 提交（反过来会出现
   「包已打标记、策略路由还没装」的黑洞窗口）；快照永远是最后一步。
2. **复核不过不写快照**：`applied.json` / `applied.nft` 只能描述「设备上确实生效」的状态，
   否则下次启动会拿一份假的 last-good 去恢复。
3. **记账失败不回滚已验证的数据面**：persist 失败时保留数据面、置 `ok=false` 并说明原因。
   为了「文件没写成」把已经验证通的上网路径拆掉，是把小故障升级成大故障。

`Coordinator::submit()` 刻意**不返回 `Result`**：任何结局都是一份 `Receipt`
（含阶段记录、issues、pending、rollback、摘要、nft 通道种类）。
RPC 层不得只回一个 bool —— 那等于把「内核现在是什么状态」这个信息丢掉。

## 4. 数据平面合同

标记布局、`RULE_MASK`、表号区间、所有权区间见 `docs/HANDOVER.md` §2.1 与
`src/lib.rs` 的模块注释。这里补充「为什么这样分」：

* **bucket 在标记里但不在 `ip rule` 掩码里**：桶重排只改 `meta mark set jhash … map{…}` 的映射值，
  选表只看 slot ⇒ 重排不会打断已建立连接（它们按 ct mark 继承仍走原出口）。
* **gen（代际）**：纯粹为了可观测性 —— 排查「这条标记是哪一轮打的」时能区分同槽位的不同批次，
  不参与任何决策。
* **class**：区分 normal/game/manual/local-policy，用于计数器与 UI 归因，同样不参与选表。
* **`ip rule` 优先级带**：`RULE_PRIO_BASE(1000) .. +MAX_WANS(24)`，`is_our_priority()` 判定所有权，
  带外规则一律视为用户的，只审计不改动。

## 5. nftables 对象命名与安装路径

* 表：`table inet smw`（`NS` 前缀）；集合/链统一 `smw_*` / `smw:*` 标签。
* 游戏规则的对象命名（规则层给的 slug，`[a-z0-9_]` ≤24，冲突加 `-2`/`-3`）：

  | 对象 | 用途 | 类型 |
  |---|---|---|
  | `smw_g_<slug>_dst4` / `_dst6` | 固定目的网段（v4/v6 分集合，族不能混） | 静态 `ipv4/ipv6_addr` |
  | `smw_g_<slug>_cli4` / `_cli6` | LAN 客户端条件 | 静态 `ipv4/ipv6_addr` |
  | `smw_g_<slug>_mac` | LAN 客户端 MAC 条件 | 静态 `ether_addr` |
  | `smw_g_<slug>_dns` | 域名解析结果 | `flags dynamic,timeout; size 1024`，寿命取 `global.dns_ttl_floor_s`（下限 60s） |
  | 规则 `comment` | `smw:game:<slug>`（所有权标签，清理时只认这个） | — |
  | 域名集合 `comment` | `smw:dns:<slug>` | — |

  集合名来自**规则段名**的 slug，不来自预置项 id。规则文本里每条匹配项都必须带字段名
  （`ether saddr @…` / `ip saddr @…` / `ip daddr @…`）：裸 `@set` 与后续条件混排语义不明，
  而且历史上正是「以 `@` 开头的匹配项被过滤掉」导致 MAC 条件静默失效（`051829f`）。
* 安装期静态占位：`/etc/nftables.d/smartmwan.nft`，内容由 `firewall::include_file_text()` 生成
  （打包时必须用该函数产出，不许手写第二份）。它只声明表与一条空 prerouting 链。
* 预置项数据目录：`/usr/share/smartmwan/presets/*.json`，路径常量在
  `src/rules/presets.rs::PRESET_DIR`（**骨架目录必须与它同名**，本轮已把 `games` 改成 `presets`）。
* fw4 挂接：UCI `config include` + `option type 'nftables'` + `option position`。
* 运行期：守护进程按能力探测结果写完整程序；探测本身走 `firewall::probe_caps(&Nft)`
  （对 `probe_scripts()` 的 8 条脚本逐条 `nft -c`，失败项只记 warning 并关闭对应语法，
  不让整轮探测失败）；桶重排只 `replace rule … handle N`。

## 6. RPC 设计

传输：Unix 域套接字（`global.rpc_socket`），JSON 长度前缀帧，一请求一响应。
鉴权：`SO_PEERCRED` 取对端 uid/gid；rpcd 以 `wwwdata` 身份连入，写方法再按 ACL 表细化。
信封：

```json
{ "ok": true,  "data": { … }, "error": null, "timestamp": 1730000000, "protocol": 1 }
{ "ok": false, "data": null,  "error": { "code": "validate", "message": "…", "details": [ … ] },
  "timestamp": 1730000000, "protocol": 1 }
```

`code` 取 `Error::code()` 的 12 个稳定值之一（`config/validate/netlink/firewall/exec/rollback/
permission/unsupported/timeout/no_route/io/json`），前端据此区分「可重试」与「需用户修正」。

### 方法清单（23 个，M7 已落地；增改必须同步本表与 `src/rpc/mod.rs::METHODS`）

| # | 方法 | 读/写 | 说明 |
|---|---|---|---|
| 1 | `smartmwan.hello` | 读 | 协议版本握手，不符则前端拒绝渲染 |
| 2 | `smartmwan.getStatus` | 读 | 运行总览：模式、活动出口、桶摘要、`notes` |
| 3 | `smartmwan.getLines` | 读 | 线路列表 + 状态 + 指标 + 槽位/表号 |
| 4 | `smartmwan.getLine` | 读 | 单线详情（含探测历史与状态迁移轨迹） |
| 5 | `smartmwan.getBalance` | 读 | 算法、桶图、份额千分比、上次重排时间与搬动数 |
| 6 | `smartmwan.getFailover` | 读 | 主备顺序、当前活动、等待回切的线路及**逐条原因** |
| 7 | `smartmwan.getGames` | 读 | 规则列表 + 命中计数 + 冲突项 |
| 8 | `smartmwan.getGameQuality` | 读 | 每条规则在各候选线路上的评分分解 |
| 9 | `smartmwan.getConnections` | 读 | conntrack 按槽位/类别统计（有上限，超限如实标注截断） |
| 10 | `smartmwan.getTraffic` | 读 | 接口计数器与平滑后的吞吐 |
| 11 | `smartmwan.getLogs` | 读 | `logging::recent(level, limit)`，只读环形缓冲 |
| 12 | `smartmwan.getConfig` | 读 | 当前生效配置 + schema 版本 + 与 last-good 的差异 |
| 13 | `smartmwan.getCapabilities` | 读 | nft 版本与各项语法探测结果（含降级说明） |
| 14 | `smartmwan.validate` | 读 | 对提交的配置跑校验，不写文件、不碰内核 |
| 15 | `smartmwan.save` | 写 | 写 `/etc/config/smartmwan`，返回 diff，**不下发** |
| 16 | `smartmwan.diff` | 读 | 待下发变更摘要（应用前确认用） |
| 17 | `smartmwan.apply` | 写 | 一次事务：`Coordinator::submit()` → 八阶段回执 `Receipt`（阶段记录、issues、pending、rollback、摘要、nft 通道种类）；失败自动逆序回滚。**响应必须回传回执，不得压缩成 bool** |
| 18 | `smartmwan.rollback` | 写 | 恢复 last-good 并重新下发 |
| 19 | `smartmwan.forceWan` | 写 | 强制指定出口（带二次确认标志） |
| 20 | `smartmwan.releaseForced` | 写 | 取消强制，回到自动决策 |
| 21 | `smartmwan.setMaintenance` | 写 | 线路维护模式开关 |
| 22 | `smartmwan.probeNow` | 读（有网络副作用） | 立即跑一轮探测，不改配置、不下发；返回 `RoundInfo` |
| 23 | `smartmwan.reload` | 写 | 重新读取 UCI 并触发 `on_config_change` |

并发：`transaction::Coordinator` 内部一把 `AsyncMutex` 串行化全部 `plan`/`submit`/`reclaim`（M6 已实现，
`is_busy()` 供 RPC 即时回答）；读方法不取写锁，但读 `Scheduler` 状态用短临界区快照，避免「读到半更新的状态」。
审计：所有写方法记录调用者 uid、方法名、参数摘要（脱敏）、transaction id、结果与耗时。

## 7. 为什么自己写 netlink 和 UCI 解析

* **零 Lua 的连带要求**：走 libuci FFI 会把 Lua/uci 工具链依赖引进来，也会让「不覆盖用户配置」
  这件事失去代码级保证（`uci set` 的副作用不可控）。直接读写文本 + 只操作自己的段类型，
  才能让「未识别键原样保留」成为可测试的行为。
* **减少攻击面与包依赖**：`rtnetlink`/`conntrack` 一类 crate 要么依赖 libmnl/netlink 库，
  要么行为不透明。手写 GETRULE/GETROUTE/GETADDR 的编解码只有一处，且能用固定字节序列单测。
* **原子性**：nft 侧必须用 `nft -c -f` → `nft -f` 的两步（校验后原子提交），任何库封装都可能把它
  拆成多条命令。

代价：内核 ABI 常量与结构要自己维护，因此 netlink 模块里有完整的常量表和逐字段解析测试。

## 8. 失败与降级路径（每一条都必须对用户可见）

| 情况 | 行为 |
|---|---|
| 首轮探测未完成 | 不承载流量 + note「尚未完成首轮探测（周期/超时）」 |
| 全部线路 FAILED | 桶全 0、`all_dead=true`，UI 显示「无可用出口」，不回退成「走默认路由」这种隐式行为 |
| 算法在设备上不支持 | `Error::Unsupported` → 降级为 `WeightedHash` 并写 note「算法降级：…」 |
| nft 语法探测失败 | 该语法不写进程序 → `Issue::Warning` 说明降级后果 |
| 事务任一步失败 | `unwind()` 按 `Undo` **逆序**回滚（先 nft 后路由），每条回滚失败都写进 `Receipt.rollback` 并记 `logging::error_ctx`；`rollback` 非空 ⇒ UI 必须提示「内核状态需人工确认」，不能显示成已恢复 |
| nft 试算（`nft -c`）不通过 | 直接拒绝，**一次内核写入都不发生**，`applied.json` / `applied.nft` 也不写（`check_failure_leaves_kernel_and_state_files_untouched`） |
| 路由下发失败 | 停在 RouteApply，绝不进 nft 提交；`Applier` 已自行回滚已成功部分，事务层不再重复撤 |
| 复核（路由或 nft）不通过 | 逆序回滚 + **不写快照**：快照只描述设备上确实生效的状态 |
| 快照写入失败 | **不回滚已验证的数据面**（拆掉一条已经通的上网路径是把小故障升级成大故障），但 `ok=false`、`error` 写明「数据面已生效但快照写入失败」，`rollback` 里记「快照未写入」 |
| 设备上找不到 `nft` | enabled 配置**拒绝提交**（半套状态比不更危险，且绝不只装半套路由）；停用配置**允许**走完（清场不需要 nft），两个 nft 阶段记为「跳过」并写明依据 |
| 决策未变（`Outcome.changed == false`） | 不调用 `submit()`；即使被调用，`Diff` 为空且 `applied.nft` 逐字节相同也判「无变更」，但仍执行试算与两侧复核（`changed=false` 出现在回执里） |
| 命令超时 | `Error::Timeout{operation, elapsed_ms}`，子进程被 kill 且回收 |
| 标记属于别人 | 完全不介入该连接（不抢别人的出口决策） |
| 设备 nft 不支持 `dynamic,timeout` 集合 | **该规则的域名条件不下发**（不退化成无目的兜底规则）+ `Issue::Warning` 指向 `smartmwan.game[<slug>].domains` |
| 设备 nft 不支持 `ether_addr` 集合，且规则只有 MAC 客户端条件 | **整条规则不下发**（丢掉条件继续下发会把「一台主机」放宽成「全 LAN」）+ `Issue::Warning` 指向 `smartmwan.game[<slug>]` |
| 规则只有 IPv6 客户端条件而本机 IPv6 未启用 | 同上：客户端条件全灭 ⇒ 整条不下发 |
| 规则同时写 `target` 与 `domain` | 同族每个目的条件**各出一条规则**（并集），不再是「取第一类非空」 |
| 预置项数据文件缺 `source` / 内部或跨文件重复 id / 单文件坏 JSON | **加载期报错**，整批拒绝；错误带文件名与 id（不做「跳过这个文件」的静默降级） |
| 域名解析失败（`NotFound`/`Timeout`/`LocalError`） | 集合里的旧元素**保留**，只累计失败计数；**不计为线路失败**（DNS 故障不等于出口故障） |
| `selection=best` 但本轮无择优结论 | 规则进 `Compiled::pending`，不下发，UI 显示「等待质量判定」 |

## 9. 尚未决定 / 需要实现时确认

* ~~`rules` 层是否把域名解析委托给 dnsmasq 的 ipset 兼容接口~~ → **已决定：自己做解析 + `nft add element`**
  （`rules::dns_sets::resolve` 用 `spawn_blocking` 包 `to_socket_addrs` + 硬超时）。理由：可控寿命、
  可如实分类解析失败（NXDOMAIN / 超时 / 本地错误），且不引入额外包依赖。
  **代价已写在代码里**：`getaddrinfo` 不返回 TTL，所以元素寿命取 `global.dns_ttl_floor_s` 下界（默认 300s），
  这是明知不完备的折中；v6 结果计入 `v6_skipped`（IPv6 目的集合仍需真机确认）；
* `WeightedEcmp` 的能力探测粒度（内核 `fib_multipath_hash` 与 `ip` 版本要分别测）；
* 多实例（同一设备跑两个 `smartmwan` 配置集）明确**不支持**：标记区间与表号区间是全局唯一资源。
