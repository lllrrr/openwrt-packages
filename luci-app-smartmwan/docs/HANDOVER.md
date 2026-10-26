# 交接文档

面向**下一个接手的人**（或下一次重启会话的自己）。只写「不知道就会做错」的内容；
能从代码读出来的不重复。读法顺序：本文件 → `docs/SPEC.md`（原始任务书）→
`docs/ARCHITECTURE.md` → `docs/PROGRESS.md`（**§9 差距清单是当前工作起点**）。

## 1. 三十秒版

* 这是 OpenWrt/ImmortalWrt **25.12+** 的多 WAN 智能选路插件，**后端 Rust、前端 LuCI JS + ucode，全项目零 Lua**；
* 已完成：全部代码（后端七层 + 守护进程 + 前端 + 打包）+ **M10 真机验收第一轮**
  （382 lib + 2 bin 单测全绿，clippy/fmt 双零）；
* 真机（ImmortalWrt SNAPSHOT / mediatek-filogic aarch64 / nft 1.1.7）：安装/升级/卸载、
  数据面、健康探测状态机、幂等回收、管理面不失联全部实测通过；抓出**六处真机必爆缺陷**
  全部修复（`docs/PROGRESS.md` §6.20–6.25）—— 每一条在单测/WSL 里都是绿的；
* 遗留：双 WAN 均衡/主备切换与 5G 重拨（设备第二线路 eth0 未接上游）、断电重启幂等、
  浏览器侧渲染人工确认；`tests/` 集成测试仍未写；
* 事务层现在**有运行期调用者**：守护进程主循环（`src/main.rs`）读 UCI、按周期决策、
  调 `Coordinator::submit()`；RPC 的写方法经 `Command` 通道送回同一个循环串行执行
  （`Scheduler` 与事务因此都只有一个所有者，别在 RPC 层另起一套）；
* RPC 的 `apply` **不接收** UI 传来的配置副本，一律以磁盘上已保存的为准；
  `submit()` 返回 `Receipt` 而非 `Result`，RPC 必须原样回传，不得压成 bool；
* 下一步：第二线路接入后验证均衡/主备/5G 重拨；`tests/` 集成测试；浏览器人工确认。

### 前端必读（真机踩坑后新增）

* **LuCI 的 `'require X'` 返回模块类的单例实例，不是类本身**（luci.js 加载器
  `new _class()` 后缓存实例）—— 共享模块 smartmwan.js 在视图里必须直接
  `smartmwan.parse(...)`，**绝不能 `new smartmwan()`**（真机报
  "smartmwan is not a constructor"）。新增视图同理；
* 菜单位置：`admin/network/smartmwan`（仓库所有者指定，放在「网络」菜单下）。

#### 编辑类页面的三条纪律（2026-10-27 新增）

* **不要占用 `handleSave` / `handleSaveApply` / `handleReset`**：它们是 LuCI
  表单视图的保留钩子，写成自己的保存函数会凭空多出一个全局「保存」按钮，
  语义与本页的「保存并应用」完全不同。本项目的编辑页把这三个显式设为 `null`，
  保存函数改叫 `saveConfig()`。
* **编辑一律走 `save → diff → apply`**：界面改的是 `getConfig` 返回的那份配置
  的副本（草稿），保存交给后端校验并写盘，**界面从不把配置直接塞给内核**；
  改单个字段的（主线路/备用顺序/算法）走便捷 RPC，它们内部也是同一条路径。
  未保存的修改必须用 `smartmwan.dirty()` 摆出来 —— 只靠按钮禁用态暗示，
  用户会以为改了其实没下发。
* **命中数 `null` 与 0 是两个意思**：`getGames` 的 `hits` 读不到时是 `null`
  （UI 显示「—」），只有真的读到 counter 才是数字。显示 0 会被读成
  「规则没命中过」，而真相可能是通道不是真 nft、根本没读。

#### 版式与样式

* 版面零件集中在 `smartmwan.js`：`section()`（区块卡片）、`stat()`（统计卡片）、
  `kv()`（键值表）、`field()/select()/number()/checkbox()`（表单）、
  `dirty()`、`tick()`。新增页面直接复用，别再手写一遍卡片结构；
* `smartmwan.css` 的两条硬约束：选择器**全部** `.smw-` 作用域（绝不污染 LuCI
  全局样式），颜色**一律** `var(--x, fallback)`（老主题/暗色主题下变量可能不存在，
  没有 fallback 会变成不可读的透明或纯黑）；暗色走 `prefers-color-scheme`
  而不是主题 class —— 后者在不同 LuCI 主题下名字不统一；
* 数值统一 `font-variant-numeric: tabular-nums`（轮询刷新时不左右跳动），
  动效在 `prefers-reduced-motion` 下关闭。

#### 改前端怎么自检（没有真机时）

```sh
# ① 语法：LuCI 的 'require X'; 是合法表达式语句，node 能直接查
for f in htdocs/luci-static/resources/smartmwan.js htdocs/luci-static/resources/view/smartmwan/*.js; do
  node --check "$f" || echo "语法错误：$f"
done
# ② 渲染冒烟：用 stub 掉 LuCI 运行时（E/L/rpc/ui/view）的脚本跑一遍 render()
#    脚本刻意**不入库**：它带示例数据，混进仓库就有被当成真实状态的风险。
```

## 2. 改了会出事的八条不变式

### 2.1 fwmark 布局是数据平面合同

`src/lib.rs::marks`：bit24..27 = 魔数 `0x5`，bit28..31 **必须为 0**（留给 fw4/netifd/别人），
bit16..23 bucket、bit12..15 gen、bit8..11 class、bit0..7 slot。

* `RULE_MASK == SLOT_MASK`：**任何改变 bucket/gen/class 的决策都不得改变选表**，否则已建立连接会换出口。
  这条有单测 `bucket_and_gen_changes_do_not_affect_table`，别删。
* `table = TABLE_BASE(100) + slot`，`slot` 1..=24 ⇒ 表号 101..124，恒 < 253（避开 main/local/universe）。
* 所有权判定写成**区间** `0x05000000-0x05ffffff`（`own_range_text()`），刻意不用 nft 位运算表达式，
  因为位运算在 `ct mark` 上的语法兼容性更弱。`marks::own_range_text()` 与 `OWN_MIN/OWN_MAX` 的一致性
  由单测锁死 —— 改常量必须同时改文本，否则设备上的所有权判断整体失效。
* 落在别人标记区间的连接，本插件**完全不介入**（宁可走 main 表），这是有意的保守设计，不是 bug。

### 2.2 槽位必须由配置顺序唯一决定

`config::decode()` 把 `wans` 按 `(priority, name)` 排序，`system::assign_slots()` 按该顺序发 1..=N。
⇒ 槽位/表号/规则在两次进程之间可复现，**重启不会产生重复或错位规则**。
不要改成按 UCI 文件顺序或 HashMap 迭代顺序 —— 那会让桶全部重排。
线路数 > `MAX_WANS` 时 `assign_slots` 返回 `Err`，`scheduler::slot_map()` 必须继续向上传播（曾经被吞掉过）。

### 2.3 外部命令只有一条通道

`src/system/exec.rs` 是唯一出口：绝对路径白名单（不做 `$PATH` 查找）、参数数组直接 `execve`（**永不 `sh -c`**）、
硬超时 + `kill_on_drop`、stdout/stderr 字节封顶且超限后继续排空管道（否则子进程卡在写上）、
`stdin=/dev/null`、环境清空只留最小 `PATH`、非零退出码一定是错误。
新增可执行程序**必须**同时进 `ALLOWED_PROGRAMS`；测试专用的 `TEST_PROGRAMS` 只在 `#[cfg(test)]` 存在，
所以 release 里不可能通过测试通道放宽白名单。
优先 netlink / `/sys` / `/proc`，只有 `nft` 这类没有稳定库接口或需要原子事务的才走 exec。

### 2.4 调度状态只有一个所有者

`scheduler::Scheduler` 独占 `failover::Machine` 与 `latency::Picker`；RPC 层只能调用它的公开方法
（`force`/`release_forced`/`on_config_change`/`decide`/`ranking`…），**不得另建一份 Machine**，
否则两套状态机各自切换会互相打架。计划中的 RPC 需要与之互斥（同一把锁）。

两条容易写错的语义（都已修过，别再退回）：

* `hysteresis::interval_elapsed(0, …) == true`：`last==0` 表示「从未变更」，不存在间隔约束；
* `failover` 的最小切换计时：**真实变更才刷新**（含「变为不分流」），`None→None` 不刷新。

### 2.5 「不做高频全量重建」在两处落地

* 应用层：`Outcome.changed` 来自**真实桶图比较**（`buckets != self.buckets`），决策没变就没有任何数据面写入；
* 内核层：低频配置变更才 `delete table inet smw` + 整表重建（单批原子）；
  高频桶重排只 `nft replace rule ... handle N` 替换 `smw:bucket:*` 那几条，规则数量恒定。

⇒ 新增任何「周期性下发」逻辑时，必须先证明自己产生了 diff。

### 2.6 诚实性（产品级要求，不是口号）

* 未探测成功的能力一律 `Error::Unsupported` + 降级 note，**不伪造**（`WeightedEcmp` 是样板案例）；
* 未完成首轮探测时 `decide()` 输出 note「尚未完成首轮探测…周期 Xms、超时 Yms」且**不承载流量**；
* 全线路不可用 ⇒ 桶全 0 + `all_dead=true`，UI 必须显示「无可用出口」，不能显示「正常」；
* 主备模式下备份线路不承载普通流量，除非 `game_policy=exception` 且规则显式命中；
* 游戏预置库**绝不内置编造的服务器 IP/端口**，只放用户可编辑的数据文件（`presets::tests::no_preset_is_bundled_in_code`
  与 `missing_source_is_error` 两条单测把「代码零内置」和「缺来源即拒绝」钉住）。

### 2.7 规则层的六条不变式（M5 新增，最容易在重构时被写坏）

* **规则层不生成 nft 文本**。`config`（用户写了什么）→ `rules`（这些条件在数据面上意味着什么）→
  `system::firewall`（怎么写成 nft 脚本）。把「匹配范围」和「语法兼容性」塞进同一个函数，
  两类错误的表现会互相掩盖。产物只有 `Vec<firewall::GameSpec>`（契约在 `src/system/firewall.rs:146`）。
* **条件必须出现在最终文本里**，测试要按存在性断言（`ether saddr @…`、`ip saddr @…_cli4`、
  `ip daddr @…_dst4`），不能只断言集合被**声明**过 —— 这正是 `051829f`/`e1f31f2` 两个缺陷
  当时躲过全部测试的原因。集合引用一律带字段名，拼接处**不做任何过滤**。
* **能力不足 ⇒ 不下发该条件**，绝不退化成「无目的条件的兜底规则」。后者会命中该主机全部新建连接，
  比条件不生效严重一个量级。同理：元素数量超上限（客户端 512 / 全局集合 2048 / 每规则 32 域名 /
  每域名 32 地址）一律 **Error 不截断**；坏值**报错不跳过**（跳过等于「拦 10 段」变「拦 9 段」）。
* **降级路径的通用判据：匹配面不得变宽**。三类同类缺陷都修在 `firewall::build()`：
  MAC 匹配项被 `@` 前缀过滤丢弃（`051829f`）、域名条件不支持时落到无目的兜底（`e1f31f2`）、
  `caps.ether_sets == false` 时只丢客户端条件继续下发规则 —— 最后一条最阴，因为规则**还有**
  目的条件看起来仍然精确，实际从「一台主机」变成「全 LAN」，而且旧警告文案写着「降级为不匹配」
  （`c2e8067`）。现在规则想限定主机（写了 `client_mac` 或客户端 IP）却一个可用匹配项都不剩时，
  **整条 `continue` 不下发**。新增任何条件降级分支时，照这条判据自查，并按
  「条件还在文本里 / 规则整条不存在」写断言。
* **不猜线路**。`selection=best` 而本轮没有择优结论时进 `Compiled::pending`，UI 显示「等待质量判定」；
  主备模式 + `game_policy=follow` 时游戏规则整体不下发。
* slug 由**规则段名**决定（`matchers::slug_of(&rule.name)`），不是预置项 id；改 id 改不了集合名。
  slug 里**不能用 `clamp_str`**（它会追加 `…[截断 N→M 字节]` 这种人看的标记，而 slug 要进 nft 对象名）。

### 2.8 事务层的六条不变式（M6 新增，动 `Coordinator` 前先读这段）

* **阶段顺序不可调换**：`validate → plan → nft 试算 → 路由下发 → 路由复核 → nft 提交 → nft 复核 → 快照`。
  两个顺序是有原因的，不是习惯：
  nft 试算必须在**任何内核写入之前**（语法不过就不该碰内核）；
  路由必须**先于** nft 提交（反过来会出现「包已打上 `0x05…` 标记、策略路由还没装」的黑洞窗口，
  表现为突然全量走 main 表默认路由，且没有任何报错）。
* **复核不过 ⇒ 不写快照**。`applied.json` / `applied.nft` 是下次启动恢复的依据，
  写进一份没验证过的状态，等于把故障固化成「正常」。
* **记账失败 ⇒ 不回滚已验证的数据面**，但 `ok=false` 且 `error` 写明「数据面已生效但快照写入失败」。
  为了一个文件没写成就把通的上网路径拆掉，是把小故障升级成大故障 —— 这条是**故意**不对称的。
* **回滚逆序 + 逐条报告**：`unwind()` 弹出顺序与下发顺序相反（先 nft 后路由）；
  撤销失败不吞异常，全部写进 `Receipt.rollback` 并 `logging::error_ctx`。
  **`rollback` 非空 = 内核状态需要人工确认**，UI 不得把它显示成「已恢复」。
* **`Receipt` 不是 `Result`**：`submit()` 任何结局都返回回执（阶段记录 / issues / pending / rollback /
  摘要 / nft 通道种类）。`Error` 只能表达一种结局，而「失败但已回滚」与「失败且未提交」
  对运维是两个完全不同的动作。
* **`FirewallExec::Sim` 只证明编排，不证明语法**：回执与文档都必须带上通道种类这句限定；
  `FirewallExec::Absent`（设备上找不到 `nft`）时**拒绝 enabled 提交、允许停用提交**，
  因为半套状态比不更危险，而清场不需要 nft。

另外两条由事务层暴露出来的「同源要求」：

* `firewall::Program::tags` **必须**涵盖程序里每一条带 `comment` 的规则 —— 复核是拿 `tags`
  与内核实际规则做集合比对，漏登记会把一次正确提交判成「多余标签」失败并回滚（M6 就踩了这条）。
  新增带标签的规则时，生成文本与登记 tag 写在同一处。
* `config::diff()` **必须**覆盖 schema 全部字段 —— 它是应用前变更摘要的唯一来源。
  `global.hash_seed` 曾被漏掉（改种子会重排全部新建连接却看不见），现已补上；
  新增字段时按第 4 节「三处同改」再加第四处：`config/mod.rs::diff()`。

### 2.9 RPC 与守护进程的六条不变式（M7 新增，动 `rpc/mod.rs` 或 `main.rs` 前先读这段）

* **RPC 层不保存业务状态**。健康快照、观测、回执都由主循环写进 `AppState` 的槽位，
  RPC 只读；改状态的写方法经 `Command` 通道送回主循环串行执行。想在图省事在 RPC 里
  直接调 `Scheduler::decide()` 或 `Coordinator::submit()`，就会造出第二个状态所有者 ——
  那是数据事故，不是代码风格问题。
* **`apply` 永远不信任 UI 传来的配置**。它没有 config 参数，只触发主循环以磁盘上
  已保存的配置跑一轮事务（`docs/REQUIREMENTS.md` 6.4）。想「让 UI 传一份配置直接下发」
  就等于把 save/apply 分离拆掉。
* **回执原样透传**。`smartmwan.apply` 的 data 就是 `Receipt` 序列化，`ok=false` 的
  回执也要 `ok:true` 的信封送出去（「失败但已回滚」与「失败且未提交」是两种运维动作）。
  压成 bool 就丢了「内核现在是什么状态」。
* **读方法零副作用**。不得为了「刷新」在 getStatus 里触发探测或下发；`probeNow` 是
  唯一的例外（它会真发探测包），因此按写方法记审计。
* **`SO_PEERCRED` 是唯一身份来源**，uid 白名单 = root + 从 `/etc/passwd` 解析的
  `wwwdata`（**不猜常见 uid**）。socket 权限 0660；bind 前探测「已有活实例」并拒绝
  重复启动 —— 两个实例同时写内核比没有实例更糟。
* **关停序列由信号任务持有，不跟在主循环后面**。主循环可能楔死（netlink recv 无超时
  就永久挂住，这是实测过的事故），跟在它后面的关停代码永远走不到。现在 SIGTERM 先发
  停止旗标，30 秒看门狗到点强制走同一序列（限时回收 + 删 socket）后退出。
  另：netlink 的 `SO_RCVTIMEO` 设不上必须判致命错误（`SOL_NETLINK` 层静默失败过一次，
  详见 `docs/PROGRESS.md` §6.16）。

## 3. nftables / fw4 的事实依据（勿凭记忆改写）

* firewall4 是 ucode 实现，表名 `inet fw4`；本插件用**独立的** `inet smw` 表，绝不碰 fw4 的对象；
* `/etc/nftables.d/*.nft` 的挂接机制：UCI `config include` + `type 'nftables'` + `position`（已核对，不是猜的）；
* hook 优先级 `-150`（`HOOK_PRIO`）：在 conntrack(-200) 之后、路由决策之前，因此 `ct state`/`ct mark` 可用且标记能影响选表；
* 安装期静态占位 `/etc/nftables.d/smartmwan.nft` 由 `firewall::include_file_text()` 生成，
  **只声明表 + 一条空 prerouting 链**。`type route hook output` 未经设备实测，不得进占位文件
  （本次刚修过这个错：曾经多写一条名为 output 却挂 prerouting 的链）；
* 待真机实测的语法集中在 `firewall::probe_scripts()`：`jhash ... map`、`th sport/dport`、
  `type route hook output`、`flags dynamic,timeout` 集合、`ether_addr` 集合、规则 `comment`。
  探测不通过 → 该语法**不写进程序**，转为 `Issue::Warning`。

## 4. 配置层要记住的键名

UCI 文件 `/etc/config/smartmwan`，段类型 `smartmwan`(global) / `wan` / `game` / `score`。
完整表在 `docs/CONFIGURATION.md`。几个反直觉的（**UCI 键名 ≠ Rust 字段名**）：

| UCI 键 | 结构体字段 |
|---|---|
| `probe_interval` / `probe_timeout` | `health.interval_ms` / `health.timeout_ms` |
| `recover_warmup_ms` | `health.warmup_ms` |
| `probe_target`（list） | `probe_targets` |
| `lan_zone`（list） | `lan_zones` |
| `target` / `port` / `client_ip` / `client_mac` / `domain`（list） | `targets` / `ports` / `client_ips` / `client_macs` / `domains` |
| `rtt_weight` / `jitter_weight` / `loss_weight` / `instability_penalty` | `score.rtt` / `.jitter` / `.loss` / `.instability` |

* 线路段/游戏段**必须具名**（段名是主键，用于规则定位与冲突提示）；
* 线路的 health 字段留空即继承 global（`decode_health(sec, base)` 的 base 语义）；
* `enabled` 默认 `0`：**首次安装绝不能改变现有路由**（单测 `defaults_are_safe_disabled`）；
* 未识别的用户手写键在 `encode_into()` 回写时原样保留，不静默丢弃；
* `dns_ttl_floor_s`（M5 新增，默认 300，校验 `30..=86400`）：UCI 键名与字段名**一致**，
  它是 `getaddrinfo` 拿不到 TTL 时的**下界折中**，不是「真实 TTL」。改这个值等于同时改
  解析频率与集合里旧 IP 的残留时间，两边都要在 UI 里如实说明；
  新增键必须同时改三处：`schema.rs`（默认值）、`config/mod.rs`（decode/encode/diff）、`validate.rs`（区间）。

## 5. 本环境的限制（结论必须带这些前提）

| 限制 | 后果 |
|---|---|
| 无 `nft` 二进制、无 netfilter 内核支持 | 所有 nft/`ip rule` 行为只到「文本正确 + 单测」，不能声称设备可用 |
| `raw.githubusercontent.com` TLS 中断 | 上游源码引用改用本地已核对文件/镜像站 |
| 沙箱网络改动有风险 | **已变通**：开发/验证迁到 WSL（Debian，独立网络命名空间）。WSL 里真 netlink + 真 nft 可用，本插件的对象只落在自己的表（101–124）与 `inet smw` 表、自己的优先级带（1000–1023），对 WSL 网络零影响；M7 的全部端到端结论都在这里取得。**仍不要**在共享网络/宿主上直接试 |
| `cargo --offline` | 构建/测试一律加 `--offline`（WSL 内依赖已缓存；`cargo fetch` 走 tuna 镜像 + 代理） |

**已解除的限制（2026-10-26）**：clippy 与 rustfmt 之前不可用（1.98.1 的组件包在镜像 404），
把 stable 升到 1.99.1 后即可。⇒ 现在必须保持
`cargo clippy --offline --all-targets -- -D warnings` 与 `cargo fmt --all -- --check` 双零，
新增代码不过这两关就不要提交。

**WSL 实操备忘**（下次少踩坑）：

* 工作副本在 `~/luci-app-smartmwan`；`~/.cargo/bin` 不在 root 的 PATH 里，`sudo` 跑 cargo 要
  `export PATH=/home/A11/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:...` +
  `export CARGO_HOME=/home/A11/.cargo`；
* Windows 侧与 WSL 侧同步用 `cp` 双向拷；**`.gitattributes` 已强制 LF**，
  旧 clone 签出的 CRLF 工作树在 `git add` 时会自动归一化为 LF（`git status` 会显示
  「CRLF will be replaced by LF」的警告，属预期）；
* `/tmp` 在 WSL 重启后会丢（tmpfs）：测试配置、脚本、日志放 `~/smwtest/` 之类持久目录；
* 跑集成测试别 `ip rule flush`（会拆掉 WSL 自己的规则，`ping` 立刻失败），要清场只删
  本插件的对象；真把网络弄坏了就 `wsl --shutdown` 恢复。

## 6. Git 与协作约定

* 远端：`https://github.com/LianXia233/luci-app-smartmwan`，分支 `main`；远端**已有历史**，
  普通 `git push` 即可（`branch.main.remote/merge` 已配好），不要再假设这是个空仓库；
* **远端 URL 里不留 token**，token 只在该次命令里内联使用，绝不写进 `.git/config`、
   remote URL、文档或提交信息；任何一次把 token 明文贴进对话后都应视为已泄露，
  **建议仓库所有者轮换该 token**；
* 提交身份统一为 **`LianXia233 <49828512+LianXia233@users.noreply.github.com>`**（作者与提交者相同），
  用**每条命令的** `-c user.name=... -c user.email=...` 传入，**绝不执行 `git config`**。
  带 `49828512+` 前缀的写法保证 GitHub 一定能把提交归属到该账号（不带前缀的
  `LianXia233@users.noreply.github.com` 不保证）。
  *历史已被重写一次（2026-10-26，按仓库所有者的明确指示）*：`f90e088..2e8b3d1` 的 13 个提交
  原先混用两种身份（早期 `LianXia233` + 后续 `smartmwan-dev <dev@localhost>`），
  已用 `git filter-branch` 统一身份并 `--force-with-lease` 强推。
  **树内容与提交信息逐字节未变**（`git diff` 对比重写前分支为空），但 **hash 全变**：
  任何人手里有旧 clone，必须 `git fetch && git reset --hard origin/main` 或重新 clone，
  不要在旧历史上继续提交。**不要再做第二次历史重写。**
  本地留有重写前的分支 `backup/pre-author-rewrite`（只是防呆备份，远端没有它）；
  确认无误后可以 `git branch -D backup/pre-author-rewrite` 删掉，删之前它同时是
  「内容未被改动」的证据（`git diff backup/pre-author-rewrite main` 应为空）。
  *另一处遗留违规*：本轮为了让 push 省事执行过 `git config branch.main.remote/merge`，
  与本条约定冲突，合规等效做法是首次 `git push -u origin main`；
  若要清理 `git config --unset branch.main.remote` 即可，但**不要新增** `git config` 改动。
* 提交规范：`build:` / `feat:` / `fix(scope):` / `test(scope):` / `docs:` / `chore:`，中文正文，
  一次提交只做一件事（原子提交）；
* **每完成一个阶段同步更新**：`CHANGELOG.md`、`docs/REQUIREMENTS.md`（状态列）、`docs/ROADMAP.md`（勾选）、
  `docs/PROGRESS.md`（数字与落点）、`docs/HANDOVER.md`（新增不变式）；
* 文档里的数字（测试数、行数）必须来自实际命令输出，不能沿用上一版的数字。

## 7. 接手后的正确动作序列

1. 跑 `cargo test --offline --lib`（期望 **378**）+ `cargo test --offline --bins`（期望 **2**）
   + `./scripts/no-lua-check.sh`（期望 0）确认基线；
   再加 `cargo clippy --offline --all-targets -- -D warnings` 与 `cargo fmt --all -- --check`，两个都必须零；
2. **M0–M6 已完成**（配置 / 系统 / 健康 / 调度 / 规则 / 事务），`src/transaction.rs` 2212 行 / 21 单测：
   八阶段固定顺序、单事务锁、逆序回滚、last-good 快照、`reclaim()` 残留回收。
   动它之前先读 §2.8。
3. **M7 已完成**（`src/rpc/mod.rs` 1934 行 / 18 单测 + `src/main.rs` 1520 行 / 2 bin 单测）：
   23 方法 + 统一信封 + `SO_PEERCRED` ACL + 脱敏审计 + tokio 监督循环
   （探测环 / 调度环 / 域名刷新环 / SIGHUP / SIGTERM）+ `--dump-include` / `--reclaim`。
   动它们之前先读 §2.9。**别把 WSL 上的端到端通过当成设备验收** —— 目标设备的 nft 版本、
   接口形态、管理面不失联都要在 M10 用 `FirewallExec::Real` 重跑。
4. **M8/M9 已完成**：ucode 桥 + 方法级 ACL + 7 视图 + CSS；OpenWrt 包 Makefile
   （自建交叉编译，`CONFIG_ARCH` 带引号要剥）+ 四个 apk 维护脚本
   （define 名按 `include/package-pack.mk` 的 `BuildPackVariable` 实测，
   **自造名字会被静默忽略**）+ 同源安装期文件（`--dump-defaults` / `--dump-include`）。
   真实 SDK 构建已通过；`apk adbdump` 可核对脚本是否真的进了包。
5. **M10 剩余项与任务书差距是当前落点**：完整差距清单（RPC 便捷形态 6 个、
   前端配置编辑、游戏命中统计、diagnostics、`tests/` 六件套、真机剩余矩阵）
   见 `docs/PROGRESS.md` §9，建议实施顺序也在那里；原始要求见 `docs/SPEC.md`。
   真机第一轮结论与六处缺陷修复见 `docs/PROGRESS.md` §6.20–6.25 与
   `docs/TESTING.md` §7。

## 8. 绝对不要做的事

* 不要为了「页面能跑起来」而写假数据或 mock 状态；
* 不要在 `root/` 下手写与 `firewall::include_file_text()` 不同的 nft 片段（必须同源生成）；
* 不要 flush 任何非 `inet smw` 的表，不要删非 `smw`/`smw_` 前缀的对象；
* 不要覆盖 `/etc/config/network` 或 `/etc/config/firewall`（本项目对它们只读）；
* 不要引入 `luci-lua-runtime` 或任何 `*.lua`（`no-lua-check.sh` 会拦，但也别靠脚本兜底）；
* **不要内置任何游戏服务器 IP/端口**，也不要加载没有 `source` 的预置项数据文件；
* **不要在规则条件上「放宽」**：能力不支持就不下发该条件，不要退回无目的/无客户端的兜底规则；
  元素超上限不要截断，要报错；
* 不要在匹配项拼接处加任何形式的 `filter`（`051829f` 那个缺陷就是这么来的）；
  集合引用必须带字段名；
* 不要调换事务的阶段顺序，尤其**不要把 nft 提交放到路由之前**（黑洞窗口）或把快照写到复核之前；
* 不要把 `FirewallExec::Sim` 跑绿的测试当成「nft 语法已验证」写进任何结论或 UI 文案；
* 不要在快照写入失败时回滚已验证的数据面 —— 改成 `ok=false` 并说明原因，数据面留着；
* 不要因为「省事」把 `Coordinator::submit()` 的返回值改成 `Result` 或让 RPC 只回 bool；
* 不要在 RPC 层另存一份业务状态或另起一个 `Scheduler`/`Coordinator` 调用点 ——
  状态只有一个所有者（主循环），写方法走 `Command` 通道；
* 不要让 `apply` 接受 UI 传来的配置副本；它只以磁盘上已保存的配置为准；
* 不要把读方法改成「顺手刷一下」：读方法零副作用，探测只有 `probeNow` 会真发；
* 不要把 netlink 的 `SO_RCVTIMEO` 写到 `SOL_NETLINK` 层（静默失败），也不要在
  设不上超时时继续跑 —— 没有超时的 netlink recv 会永久挂住工作线程；
* 不要把 `git reset --hard` / `push --force` 用在已有历史上；文档与代码问题用新提交修正。
