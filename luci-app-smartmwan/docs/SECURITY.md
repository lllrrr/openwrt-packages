# 安全与稳定性清单

任务书第 11 节列出 11 类风险，这里逐条给出：**威胁模型 → 现有机制 → 代码位置 → 状态**。
状态为「需真机」的条目，表示机制已在代码里，但结论只能由设备验证得出；在没有设备前不得写成「已验证」。

图例：`已实现（单测）` / `已实现（需真机）` / `部分` / `未开始`

## 1. 命令注入

* **威胁**：多 WAN 插件必然要执行 `nft`/`ip`，用户输入（段名、设备名、探测目标、路径）进入命令行即 RCE。
* **机制**：
  1. 唯一执行入口 `system::exec`，程序名必须在**绝对路径白名单** `ALLOWED_PROGRAMS` 内，不做 `$PATH` 查找；
  2. 参数以数组传给 `execve`，**不经过 `sh -c`**，因此引号/分号/反引号/换行没有解释空间；
  3. 环境清空后只保留最小 `PATH`，`stdin=/dev/null`；
  4. 硬超时 + `kill_on_drop`，输出字节封顶（超限继续排空管道但丢弃内容，置 `truncated`）；
  5. 非零退出码一律 `Error::Exec`，不静默忽略；
  6. 上游还有一层：`config::validate` 对段名/接口名/域名/MAC/CIDR/路径做字符集与长度校验
     （段名会成为 nft 集合名与注释的一部分）。
* **位置**：`src/system/exec.rs`、`src/config/validate.rs`。
* **状态**：已实现（单测：超时杀进程、白名单外程序被拒、输出截断、spawn 失败走 `Error::Exec` 而非 panic）。

## 2. 损坏用户配置（UCI damage）

* **威胁**：写坏 `/etc/config/network`/`firewall` 会让设备失联。
* **机制**：
  1. 只写 `/etc/config/smartmwan` 与 `/etc/nftables.d/smartmwan.nft`；对 `network`/`firewall` **只读**；
  2. 原生文本解析 + 只操作自己的段类型（`smartmwan`/`wan`/`game`/`score`），未识别的用户键原样保留；
  3. 写入前先 `render()` 到内存并跑校验；校验不通过不落盘；
  4. 不使用 `uci set/commit`（避免其副作用与依赖），因此也不依赖任何 Lua。
* **位置**：`src/config/mod.rs`（`Store::save`/`render`/`encode_into`）、`src/config/uci.rs`。
* **状态**：已实现（单测覆盖 round-trip 与未知键保留）；真机上还需验证与 `uci show` 的互操作。

## 3. ACL 过宽

* **威胁**：LuCI 页面通常以 `wwwdata` 身份调 rpcd，权限给宽了等于把 root 能力暴露给未鉴权会话。
* **机制（已落地，M7/M8）**：
  1. `root/usr/share/rpcd/acl.d/luci-app-smartmwan.json` 按**方法粒度**授权，禁止 `ubus: *` 或整组通配；
  2. 读方法与写方法分成两组 ACL，只读用户（`luci.app.nonroot`）只拿到读组；
  3. ucode 桥再对守护进程 socket 做一次 `SO_PEERCRED` 校验：对端 uid 必须是 root 或 wwwdata，
     写方法额外要求事务锁持有者身份；
  4. 任何需要二次确认的操作（`apply`、`forceWan`）要求 `confirm` 字段，缺失即 `Error::Permission`。
* **状态**：**已实现** —— 方法级 ACL 与 `SO_PEERCRED` 白名单均已落地（详见 `src/rpc/mod.rs`）；
  真机侧随 M10 验收复核。

## 4. 并发事务

* **威胁**：两个 `apply` 交错会留下半套规则；用户在 LuCI 连点两次比想象的更常见。
* **机制**：
  1. `scheduler` 是唯一状态所有者（RPC 只能调它的方法，不得复制状态）；
  2. `transaction::Coordinator` 内部一把 `AsyncMutex` 串行化所有 `submit`/`reclaim`；
     计划的读法（`plan()`）与写入（`submit()`）共用同一把锁，因此「先看摘要再提交」之间
     不会插进别人的内核改动。`is_busy()` 给 RPC 侧做即时回答；
  3. `route::Applier::apply()` 返回 `Vec<Undo>`，回滚按逆序执行，且把无法撤销的项写进 `leftovers`
     明确报告，而不是假装成功；事务层的 `unwind()` 同样逆序（先 nft 后路由），
     并把每一条回滚失败写进 `Receipt.rollback` —— **该字段非空就意味着内核状态需要人工确认**；
  4. 提交前的闸门：`Plan::blocked()` 非空 ⇒ 直接返回拒绝回执，一次内核写入都不发生。
* **状态**：机制已实现并有单测（`second_committer_waits_for_the_first_to_finish`、
  `foreign_priority_conflict_blocks_before_any_side_effect`）；RPC 层的并发调用面在 M7 接入后才算闭合。

## 5. 重启后规则重复

* **威胁**：崩溃/断电后重启若「先加自己的规则再看已有什么」，就会出现成对重复规则，表现为流量随机偏斜。
* **机制**：
  1. 启动时**先读现状**：`netlink` dump `ip rule`/路由表，用 `is_our_priority()` + `OUR_RTPROT` +
     表号区间 + `NS` 前缀判定所有权；
  2. 与 `plan()` 的目标做差量（`Diff`），只补不重复；`Diff::is_empty()` ⇒ 不产生任何写入；
  3. nft 侧同理：整表以 `delete table inet smw` + 重新声明的方式**幂等重建**（单批原子），
     不依赖「先清空再添加」的多条命令。
* **位置**：`src/system/route.rs::{plan, reconcile, audit_conflicts}`、`src/system/firewall.rs`。
* **状态**：已实现（单测）；需真机验证断电重启场景。

## 6. 标记与路由不一致

* **威胁**：`ip rule` 说「fwmark X 走表 N」，但表 N 里没有对应默认路由，表现为间歇性黑洞。
* **机制**：
  1. 表号由 `marks::table_of(slot)` 唯一决定，不允许任意配置表号；
  2. `route::plan()` 只有在 `WanTarget::usable_v4()/usable_v6()` 为真时才同时产出规则**和**路由，
     二者成对出现（不存在「装了规则没路由」）；
  3. `build_mirror()` 复制 main 表相关路由进专属表，保证策略表与原表可达性等价；
  4. `Applier::verify()` 下发后回读并与 `Desired` 比对，不一致返回 `Issue` 列表交回滚判断；
  5. 关闭 IPv6 时刻意「不装 v6 标记规则」，而不是「装规则但表里没有 v6 路由」—— 让 v6 自然走 main 表。
* **状态**：已实现（单测）；需真机。

## 7. 残留规则（leftovers）

* **威胁**：卸载或停用后仍留有规则，用户以为插件没生效却实际在改路由。
* **机制**：
  1. 一切对象带 `NS="smw"` 前缀，`teardown_program()` 只生成 `delete table inet smw`（**绝不 flush 别人的表**）；
  2. `/etc/nftables.d/smartmwan.nft` 是可删除的静态占位，删除该文件 + 移除 `firewall` 的 include 段
     即可完全回到插件安装前的状态；
  3. `route` 侧按优先级带 + `OUR_RTPROT` 精确删除自己安装的规则；
  4. 回滚时无法撤销的项写入 `leftovers` 并记 error 级日志，供 UI 显示「需要人工处理」。
* **状态**：已实现（单测 `teardown_only_deletes_own_table`、`include_file_is_inert`）；需真机验证卸载。

## 8. 5G/4G 模组重拨导致网关/地址变化

* **威胁**：模组重拨后网关 IP 变了，但策略表里还留着旧网关 → 线路「健康」却不通。
* **机制**：
  1. 每轮决策前 `interface::resolve_all()` 重新解析（不缓存拓扑结论），
     `diff_resolved()` 显式产出 `DeviceChange`；
  2. 网关优先取 netifd/路由现状（`default_gateway()`），配置里的 `gateway` 只是覆盖项；
  3. 源地址按当前地址集合选取（`pick_source()`），地址消失即标记线路不可用并触发重新下发；
  4. 探测失败分类里 `Unreachable` 与 `Timeout` 区分开：网关变了通常是前者，能更快进入 FAILED。
* **位置**：`src/system/interface.rs`、`src/health/probe.rs`。
* **状态**：已实现（单测）；需真机（模组重拨是无法在沙箱复现的场景）。

## 9. IPv6 绕过

* **威胁**：只做 v4 策略路由时，内网客户端的 v6 流量走 main 表默认路由，导致「看起来分流了但实际没分」
  以及 v6 泄漏到未预期的出口。
* **机制**：
  1. `enable_ipv6` 为真时，规则/路由/nft 对象按族**成对**生成（`netlink::Family` 双族）；
  2. 为假时，明确不接管：v6 走 main 表，并且校验层会对「配了 v6 目标却关了 IPv6」给出警告；
  3. nft 侧 `smw_protected_v6`/`bypass_v6` 集合与 v4 同构，保护段（如 `fe80::/10`）永不分流；
  4. 探测侧 `probe_ipv6` 独立判定：v4 通不代表 v6 通。
* **状态**：已实现（单测，含「IPv6 关闭时不建 v6 集合」）；需真机验证 RA/DPD 下发的 v6 默认路由时序。

## 10. 探测自身造成负载

* **威胁**：多线路 × 多目标 × 短周期会把设备 CPU、蜂窝模组信令、运营商侧限速都打爆，
  还会因探测超时而误判线路故障（自 feedback 循环）。
* **机制**：
  1. `max_concurrent_probes` 全局信号量，批次超出额度时**排队**并在日志里如实写明；
  2. 每请求硬超时，取消路径用 `JoinSet::abort_all()`（不会「等全部跑完」）；
  3. 用 ping socket（`SOCK_DGRAM/IPPROTO_ICMP`）而非 raw socket，无需 `CAP_NET_RAW`；
  4. 探测目标建议多运营商（校验层对 >5 个目标给警告，对 0 个目标提示退化风险）；
  5. `Unsupported`/`LocalError` 不计入线路失败，避免本地资源耗尽被误判成链路故障。
* **状态**：已实现（单测含并发额度、取消、错误分类）；真机上需要实测 CPU/信令开销。

## 11. 前端轮询泄漏

* **威胁**：LuCI 视图离开后 `poll` 未移除 → 后台持续打 RPC，最终 rpcd 连接堆积、页面变慢。
* **机制（已落地，M8）**：`poll.add()` 与 `poll.remove()` 必须在同一视图对象的生命周期里成对调用；
  只读接口设计为可被前端安全轮询（**无副作用**），并约定前端在 `error`/`timeout` 时退避而不是重试风暴。
* **状态**：已实现 —— 共享轮询在视图 `onUnload` 里清理；`node scripts/ui-smoke.js`（194 项）覆盖该生命周期。

## 12. 管理平面失联

* **威胁**：插件把路由器自身的管理流量（Web/SSH/DNS）一起分流到某条坏线路，用户被锁在外面。
* **机制**：
  1. `protected_src` 默认含 `169.254.0.0/16`、`fe80::/10`，为空时校验给**警告**并提示加入管理网段；
  2. nft 侧只匹配 LAN zone 转发的流量（`TAG_NOT_LAN`），本机流量走独立的 `route hook output` 决策；
  3. 本机流量若无法确认出口一致性，宁可不接管（能力探测失败时降级为警告，见 `include_file_text()`
     不声明 output 链的原因）；
  4. `require_confirm`（默认开）强制「可能失联」的变更在前端二次确认；
  5. 首次安装默认 `enabled=0`；`--restore-last-good` 提供回到上次可用状态的路径；
  6. 卸载路径明确：删 include 文件 + 删 nft 表 + 删自己的 `ip rule`，不残留任何影响管理的对象。
* **状态**：已实现（逻辑与校验）；需真机验证失联场景。

## 13. 日志与隐私

* `logging::redact()` 按字段名脱敏（password/key/token/secret/psk 等），未知字段做长度封顶；
  外部命令回显一律 `clamp_str()` 截断且保留 UTF-8 边界（单测 `clamp_keeps_utf8_boundary`）。
* 单测 `secret_fields_are_redacted` 锁住该行为。
* **状态**：已实现（单测）。

## 14. 供应链与依赖面

* 运行时依赖只有 tokio / libc / serde / serde_json / thiserror；`Cargo.lock` 入库以固定版本；
* 不引入 libuci/netfilter/conntrack 的 FFI，减少设备侧 soname 冲突面；
* 打包时依赖必须显式声明（apk），且**不声明** `luci-lua-runtime`。
* **状态**：依赖已固定；打包依赖声明已完成（M9：`DEPENDS` 与 apk `--info depends` 同源，且不含任何 Lua 包）。

### 14.1 规则数据文件（游戏预置项）的供应链

这一面比 crate 依赖更危险，因为它的内容**直接决定数据面放行范围**：一份被污染的
`/usr/share/smartmwan/presets/*.json` 等于把用户游戏流量指向攻击者网段。现有防护：

| 威胁 | 机制 | 位置 |
|---|---|---|
| 编造的服务器地址被当成权威数据 | 本项目**不内置任何**预置数据；`source` 缺失即整条拒绝加载 | `presets::validate`，单测 `no_preset_is_bundled_in_code` / `missing_source_is_error` |
| 超大文件耗尽内存 | 先 `metadata()` 判大小再读，>512KiB 直接拒绝（不是截断读取） | `presets::load_dir` + `MAX_FILE_BYTES` |
| 同 id 不同地址互相覆盖 | 文件内重复 → 报错并带文件名；跨文件重复 → 排序后报错 | `presets::parse_text` / `load_dir`，单测 `duplicate_id_within_one_file_is_error`、`loads_directory_sorted_and_rejects_cross_file_dupes` |
| 半个文件生效（静默降级） | 一个文件解析失败 → **整批失败**，不跳过；错误信息带文件名 | `load_dir`，单测同上一条的最后一段 |
| id / 集合名注入 nft 语法 | id 只允许字母数字与 `_ . -`（≤40）；规则名经 `matchers::slug_of` 归一为 `[a-z0-9_]`（≤24）后进对象名；CIDR/端口/MAC/域名在加载时就校验 | `presets::validate`、`matchers::*` |
| 数据文件写「全网段」变相全放行 | `targets` 与 `domains` 全空 → 拒绝；`0.0.0.0/0`、`::/0` 在 `matchers::normalize_prefix` 里拒绝 | `presets::validate`、`matchers::split_normalize` |
| 设备 nft 不支持 `ether_addr` 集合 | 丢掉 MAC 条件继续下发 = 把「一台主机」放宽成「全 LAN」 | 客户端条件全部失效时**整条不下发**；单测 `mac_only_rule_is_not_emitted_when_ether_sets_unsupported`（`c2e8067`） |
| 元素数量把集合撑爆 | 超 `MAX_SET_ELEMENTS` / 每规则 32 域名 / 每域名 32 地址 → **报错不截断** | `presets::validate`、`rules::compile` |

**仍然敞口的部分（不声称已解决）**：

* 数据文件本身的**真实性**无法由代码验证 —— `source` 只能是人工可追溯的声明；
  设备侧不校验签名（引入签名校验要么增加依赖面，要么把信任交给 apk，都不等于验证了地址清单本身）。
  M9 打包时应在包内提供**空目录 + README**，并在 UI 里显示 `source` 与 `updated`，把「这是谁的清单、多旧」摊开；
* 预置项文件在运行期**不需要** root 写权限，但 `ruleset` 变更目前不触发审计（M7 RPC 层才有审计日志）；
* 域名解析结果来自设备默认解析路径（`getaddrinfo`），如果 LAN 客户端用 DoH/DoT 绕过本机 DNS，
  集合与实际连接目的会不一致 —— 属产品固有限制，必须在 UI 说明。

## 15. 当前敞口的诚实总结

| 条目 | 是否可以声称安全 |
|---|---|
| 命令注入、配置只读、标记/路由一致性、残留清理、探测负载、日志脱敏 | 可以，依据是代码 + 单测（不含真机结论） |
| 规则层「不放宽匹配面」（条件必须落进文本、超上限报错不截断、缺来源拒绝加载、不猜线路） | 可以，依据是代码 + 51 条单测（含端到端 `compiled_specs_are_accepted_by_firewall_build`）；M6 起 `rules::compile()` 已被事务层真正调用（`game_rule_from_config_reaches_the_nft_program` 从 UCI 段一路断言到最终 nft 文本），但**运行期入口（谁来触发提交）仍待 M7** |
| 预置项数据文件的**内容真实性** | **不可以** —— 代码只能验证来源声明存在、格式合法、数量有界，不能验证那份网段清单是否真的是游戏服务器 |
| 断电重启幂等、5G 重拨、IPv6 实际转发路径、卸载彻底性 | **不可以**，只能说「机制存在」，需真机 |
| `flags dynamic,timeout` 集合的真实老化、`ether saddr @set` 在 bridge/VLAN 上的匹配范围 | **不可以**，沙箱无 nft；规则文本已按能力探测降级，但设备行为未观测 |
| 事务「失败不留半套状态」 | 可以声称**机制正确**：24 条事务单测覆盖「试算不过不动内核 / 路由失败不进 nft / 复核不过不写快照 / 回滚逆序且逐条报告 / 快照写失败不报成功」。但 nft 通道在单测里是 `FirewallExec::Sim`，**不验证 nft 语法**，真机结论待 M10 |
| 并发事务锁 | 可以，依据是 `Coordinator` 的单把 `AsyncMutex` + `second_committer_waits_for_the_first_to_finish`；对外的并发调用面（RPC）在 M7 接入后才算闭合 |
| ACL、前端轮询 | **不可以**，尚未实现（M7 / M8） |

任何 UI 文案、README 或交付说明在 M7/M8/M9 完成前，都不得出现「权限受控」「事务安全」「无轮询泄漏」这类表述。
