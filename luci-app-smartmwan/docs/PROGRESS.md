# 进度文档

> 本文件反映**当前工作树**。任何「已完成」都必须能用下面的命令复核；
> 不能用命令复核的结论一律写成「待验证」。

最后更新：0.4.0-dev 周期，M9 打包（Makefile + apk 维护脚本 + 同源安装期文件 + GPLv3）落地之后。

## 1. 一句话状态

后端七层（配置 / 系统交互 / 健康 / 调度 / 规则 / 事务 / **RPC**）+ **守护进程入口** +
**前端** + **打包**已完成，**378 lib + 2 bin 单测全绿**；RPC 层 23 个方法、守护进程周期循环、
CLI、rpcd ucode 桥（方法级 ACL）+ 7 个 LuCI 视图、OpenWrt 25.12 apk 打包（含四个维护脚本
与同源安装期文件）都已落地，**真实 SDK 产物已通过逐项校验**；只剩目标设备验收（M10）。
规则层的落点：M5 时它的产物只被单测喂进数据面生成器，现在由事务层真正调用
（`Coordinator::build_plan` → `rules::compile()` → `firewall::build()` → `route::Applier`）。
运行期入口也已存在：守护进程主循环读 UCI、按周期决策并调用 `Coordinator::submit()`。
**本轮端到端验证发生在 WSL**（真 netlink + 真 nft 1.1.3）：事务八阶段、幂等复核、
崩溃后启动回收、优雅关停回收、23 个 RPC 方法请求/响应、`--reclaim` 真实残留清场
（1 条规则 + 8 条路由 + `inet smw` 表，二次调用幂等）全部实测通过；
ucode 桥同样在 WSL 经 CLI 对真实守护进程往返验证（含错误信封透传）；
apk 在真实 SDK（mediatek/filogic aarch64 musl）构建成功并解包核对。
浏览器侧渲染未在真实 LuCI 环境验证。

## 2. 可复核指标

```sh
cargo test --offline --lib                          # 期望：378 passed; 0 failed
cargo clippy --offline --all-targets -- -D warnings # 期望：0 警告
cargo fmt --all -- --check                          # 期望：无差异
cargo build --offline                               # 期望：0 警告
./scripts/no-lua-check.sh                           # 期望：退出码 0
find src -name '*.rs' -print0 | xargs -0 cat | wc -l # 行数口径，见 §3 注
```

本环境实测结果（2026-10-26 复核，工具链 1.99.1，WSL Debian）：

| 命令 | 结果 |
|---|---|
| `cargo test --offline --lib` | `378 passed; 0 failed; 0 ignored` 用时 ~0.22s |
| `cargo test --offline --bins` | `2 passed; 0 failed`（reclaim 配置回落两条） |
| `./scripts/no-lua-check.sh` | 退出码 0；注入 `src/accidentally_controller.lua` 或 `require("luci.dispatcher")` 后退出码 1（已实测两个方向） |
| `cargo clippy --offline --all-targets -- -D warnings` | **通过，0 警告** |
| `cargo fmt --all -- --check` | **通过，无差异** |
| `cargo build --offline` | 0 警告 |
| `nft -c -f <脚本>` | **WSL 里可用**（root + nft 1.1.3），并以此完成端到端验证；但**目标设备未测**。WSL 的 nft 1.1.3 缺 `dynamic,timeout` 与 jhash 种子参数，能力探测如实报了「不可用」——设备上更新的 nft 会给出不同结论，必须以设备实测为准 |
| SDK 构建 `make package/luci-app-smartmwan/compile V=s` | **BUILD OK**（mediatek/filogic aarch64 musl SDK，产物 `bin/packages/aarch64_cortex-a53/base/luci-app-smartmwan-0.4.0-r1.apk`）；全部门禁先绿再构建 |

## 3. 模块完成度

| 模块 | 行数 | 单测 | 状态 | 说明 |
|---|---:|---:|---|---|
| `src/lib.rs` | 340 | 6 | 完成 | fwmark 布局、错误类型、`NS` 前缀、版本常量 |
| `src/config/` | 4028 | 51 | 完成 | UCI 文本解析/序列化、schema v4、迁移、校验、diff、last-good |
| `src/system/` | 8652 | 118 | 代码完成 / 待真机 | netlink、route、interface、conntrack、exec、firewall（`probe_caps`、`HandleOps`、`include_file_text()`；WSL 真 nft/netlink 已验证） |
| `src/health/` | 3310 | 50 | 完成 | 四类探测 + 滑窗指标 + 状态机 + Registry |
| `src/scheduler/` | 3586 | 58 | 完成 | balancing / failover / latency / hysteresis / 装配层 |
| `src/rules/` | 2270 | 51 | 完成 | matchers / presets / dns_sets / compile；**调用者是 `transaction.rs`** |
| `src/logging.rs` | 539 | 5 | 完成 | 分级 + 环形缓冲 + 轮转 + 脱敏（`recent()`/`dropped()`） |
| `src/transaction.rs` | 2212 | 21 | 代码完成 / 待真机 | 单事务锁 + 固定阶段编排 + 逆序回滚 + last-good 快照 + 残留回收 |
| `src/rpc/` | 1934 | 18 | 代码完成 / 待真机 | 23 方法 + 统一信封 + `SO_PEERCRED` ACL + 脱敏审计 |
| `src/main.rs` | 1520 | 2 | 代码完成 / 待真机 | 守护进程装配 + 周期循环 + 热替换 + 域名刷新环 + 信号 + CLI（含 `--dump-include`/`--reclaim`；reclaim 配置回落有 bin 单测） |

合计 `src/**/*.rs` = **28,391** 行。`transaction.rs` 的内部构成：非测试 1,449 行
（`Stage`/`Decision`/`FirewallExec`/`Plan`/`Receipt`/`Coordinator`），
`#[cfg(test)] mod tests` 起于第 1450 行，测试 744 行。

> 行数口径注：本表改用 `find <dir> -name '*.rs' -print0 | xargs -0 cat | wc -l`
> （原始文件行数，含空行与注释）。此前记录的四层数字（3524 / 7181 / 2904 / 3063，合计 17,494）
> 是另一种口径留下的偏低值，**不是**代码被改小了；今后一律用上表那条命令复核。

按子模块的测试分布（用于判断「哪里测得厚、哪里薄」）：

```text
system::firewall   30   transaction          21   system::route      20
config::validate   20   health::tests        19   rpc::tests         18
system::netlink    17   system::interface    17   scheduler::balancing 17
system::tests      15   rules::dns_sets      15   scheduler::tests   14
rules::tests       14   config::tests        14   scheduler::failover 12
rules::matchers    12   health::probe        12   system::exec       11
health::state      11   rules::presets       10   config::uci        10
scheduler::latency  9   system::conntrack     8   health::metrics     8
config::schema      7   scheduler::hysteresis 6  logging             5
core_tests          6
```

合计 378（`config 51 / system 118 / health 50 / scheduler 58 / rules 51 / logging 5 / lib 6 / transaction 21 / rpc 18`）。
复核命令：`cargo test --offline --lib -- --list` 后按模块前缀计数。

## 4. 目录现状（诚实版）

```text
src/            后端核心，见上表
docs/           本文档集（要求/路线图/进度/交接/架构/配置/安全/测试）
research/       两份上游审计（luci.md、buildsystem.md）—— 设计依据
scripts/        no-lua-check.sh
root/           安装期装配文件（M8/M9 已落地）：
                usr/share/rpcd/ucode/smartmwan.uc   ← rpcd ucode 桥（23 方法转发）
                usr/share/rpcd/acl.d/               ← 方法级 ACL（无通配）
                usr/share/luci/menu.d/              ← 7 标签页菜单
                etc/config/smartmwan                ← 评审快照；安装时被 --dump-defaults 产物覆盖
                etc/init.d/smartmwan                ← procd 服务（term_timeout 30）
                etc/nftables.d/smartmwan.nft        ← 评审快照；安装时被 --dump-include 产物覆盖
htdocs/         LuCI 前端资源（M8 已落地）：
                luci-static/resources/smartmwan.js        ← 共享模块（信封/四态/轮询/格式化）
                luci-static/resources/view/smartmwan/*.js ← 7 个视图
                luci-static/resources/smartmwan/smartmwan.css
tests/          空（集成测试未开始）
Makefile        OpenWrt 包（M9 已落地）：自建交叉编译 + 同源安装期文件 + 四个 apk 维护脚本
LICENSE         GPLv3 全文（2026-10-26 起）
```

> 骨架目录本轮做了一次**对齐**：原来是 `root/usr/share/smartmwan/games`，
> 而代码里的常量是 `PRESET_DIR = "/usr/share/smartmwan/presets"`（`src/rules/presets.rs:50`）。
> 两处不一致的后果是「装了包但预置目录不存在 / 用户往 games 里放文件读不到」，
> 因此以代码常量为准。路径的唯一权威来源是 `src/rules/presets.rs::PRESET_DIR`。

## 5. 提交历史与阶段

| 提交 | 阶段 | 内容 |
|---|---|---|
| `f90e088` | build | crate 清单、`Cargo.lock`、`LICENSE`（GPLv2 全文）、`.gitignore` |
| `4bef8ae` | feat | 后端核心四层（配置 / 系统 / 健康 / 调度），259 测试 |
| `fa1c5a0` | test | 桶分配算法 17 条不变式单测，276 测试 |
| `c71ac12` | docs | 验收矩阵、路线图、进度、交接 |
| `32b97ad` | chore | clippy 归零 + rustfmt 基线 |
| `f803ad8` | docs | 架构/配置/安全/测试文档 + 两份上游研究笔记 |
| `051829f` | fix(firewall) | MAC 条件必须真的出现在规则文本里（此前被 `@` 前缀过滤整条丢弃） |
| `e1f31f2` | fix(firewall) | 域名条件不再被固定网段挤掉，也不再把匹配面放宽成兜底规则（+1 测试） |
| `c78d247` | feat(rules) | 规则层四模块：matchers / presets / dns_sets / compile（+50 测试 → 327） |
| `e766b4f` | test(rules) | 补同文件重复 id 的单测 + 更正预置项 id 注释（+1 测试 → 328） |
| `c2e8067` | fix(firewall) | 客户端条件全部失效时整条规则不下发，不再放宽到全 LAN（+1 测试 → 329） |
| `2e8b3d1` | docs | M5 落地后的文档同步（数字全部重测） |
| `73a5298` | docs | 作者身份统一后的历史重写留痕 + 全部哈希引用更正 |
| `9abc322` | feat(transaction) | M6 事务层：固定阶段编排 + 逆序回滚 + last-good 快照 + 残留回收（+21 测试 → 350）；顺带修 `firewall::build()` 漏登记 tags、`config::diff()` 漏 `hash_seed` |
| `e46c0c5` | docs | M6 落地后的文档同步（数字全部重测） |
| `6cfaac1` | feat(firewall,netlink) | M7 前置：`probe_caps()` 把能力探测接上 `nft -c` 执行路径、`HandleOps` 提供生产用 `Arc<dyn RouteOps>`、修 `Nft::version()` 把「跑完了」当「取到了」（+3 测试 → 353） |
| `54f85d1` | docs | M7 前置落地后的文档同步（数字全部重测） |
| `79d22e5` | chore | 强制 LF 行尾（新增 `.gitattributes`：`* text=auto eol=lf` + 显式二进制声明），消除 Windows 签出 CRLF 造成的整仓假改动 |
| `2c34252` | feat(rpc,main) | M7：RPC 层 23 方法 + 守护进程入口与监督循环（+25 测试 → 378）；WSL 真 nft/netlink 端到端验证，并修掉集成测试抓出的六处「单测全绿、真机必爆」缺陷 |
| `76bda77` | docs | M7 落地后的文档同步（数字全部重测） |
| `7424b3b` | test(netlink,route) | 测试示例地址改用文档段（192.168.100.0/24），避免与真实设备网段重合 |
| `42fbb84` | feat(frontend) | M8：rpcd ucode 桥 + 方法级 ACL + menu.d + 7 个 JS 视图 + CSS；桥接经 WSL ucode CLI 对真实守护进程端到端验证（23 方法往返） |
| （本提交） | feat(packaging) | M9：OpenWrt 包 Makefile（自建交叉编译）+ 四个 apk 维护脚本 + 同源安装期文件 + `--dump-include`/`--reclaim` CLI + GPLv3 许可证升级；真实 SDK 构建成功并解包逐项核对 |

> **关于本表的哈希**：2026-10-26 按仓库所有者的明确指示，用 `git filter-branch` 把全部提交的
> author/committer 统一为 `LianXia233`（见 `docs/HANDOVER.md` §6），并 `--force-with-lease` 强推。
> **提交内容逐字节未变**（`git diff` 空），但**所有哈希都变了**，本表与全仓文档里的哈希引用已随之更正。
> 这是唯一一次重写，此后不得再改写；旧克隆需 `git fetch && git reset --hard origin/main`。

> **更正 `c78d247` 的提交说明**：其中「新增 51 条（rules 30 + dns_sets 21）」分布写错了。
> 实测为：`c78d247` 新增 **50** 条，全部在 `rules`（`dns_sets` 15 / `matchers` 12 /
> `presets` 9 / `mod` 14）；第 **51** 条来自 `e1f31f2`（`system::firewall`，24 条里新增的那条）。
> 也就是说「51」这个总数跨了两个提交，分布也不是它写的那样。当前 `rules` 已有 51 条
> （`e766b4f` 又补了 1 条同文件重复 id 的分支），总数 329。
> 按「不改写已提交历史」的约定，此处留痕而不 amend。后来的身份统一重写**只换了作者字段**，
> 没有动这条提交说明，所以本更正依然有效。

## 6. 本轮修过的真实缺陷（不是「顺手优化」）

这些是测试暴露出来的、会影响行为的错误，记录在此避免回归：

1. `interval_elapsed(last=0, …)` 把「从未切换过」当成「刚切换过」，导致进程启动后第一次决策被永久卡住
   —— 现在 `last_change_ms == 0` 直接判为间隔已满足。
2. `failover` 的最小切换计时语义：任何**真实**变更（含「变为不分流」）都刷新；未变更
   （尤其全灭期间的 `None→None`）绝不刷新，否则恢复后还要多等一个间隔。
3. 探测批次取消路径写成 `JoinSet::shutdown()`，它返回 future，未 await 等于什么都没做，
   取消会退化成「等全部探测跑完」—— 改为 `abort_all()`。
4. `latency` 丢包归一化基准为 0 时被 `.max(1)` 变成「该项扣满」，与「关掉该项」的用户意图相反
   —— 现在基准为 0 表示该项不参与扣分。
5. `Prober` 的并发额度原先是 `SystemProber` 私有方法（死代码），提升为 trait 的
   `free_permits()`，批次超额度时在日志里如实写「超出的部分排队执行」。
6. `scheduler::slot_map()` 曾经吞掉 `assign_slots()` 的错误并回退为空表 —— 那会把「配置有错」
   伪装成「没有线路」。改为返回 `Result` 并向上传播，配了 24 条以上线路时明确报错。
7. **MAC 条件整条丢失**（`051829f`，数据面缺陷）。`firewall.rs` 拼接规则匹配项时有一句
   `.filter(|m| !m.starts_with('@'))`，而裸集合引用正好以 `@` 开头 —— 每条 MAC 匹配项都被丢掉，
   「只针对这台主机」的规则静默放大成命中该范围内全部新建连接。现在集合引用必须带字段名
   （`ether saddr @set`）且拼接处不再过滤，并补了 `ether saddr` / `ip saddr` / `ip daddr`
   三条**存在性**断言。旧测试只断言集合被**声明**过，所以一直没红 —— 这是「测试看着厚、
   其实没测到关键路径」的典型，写规则层时按「条件必须出现在最终文本里」补测。
8. **目的条件互相挤掉 + 不支持时退化成兜底规则**（`e1f31f2`，数据面缺陷）。同一 v4 规则里
   `target` 与 `domain` 只取第一类非空，域名条件不生效；更糟的是域名集合因能力不足被跳过时，
   规则落到「无目的条件」分支，变成命中该主机全部新建连接的兜底规则。现在同族每个目的条件各一条规则，
   只有本来就没有任何目的条件时才下无目的规则；顺带删掉循环外多推的一条重复所有权标签。
9. **客户端条件全部失效时规则被放宽到全 LAN**（`c2e8067`，同类第三处）。规则用 `client_mac`
   限定主机，但设备 nft 不支持 `ether_addr` 集合（`caps.ether_sets == false`）时，代码只丢匹配项
   并写一条警告 —— 少一个条件不是「不生效」而是「匹配面变大」：降级后命中**全 LAN** 的新连接并打上
   游戏标记。更要命的是警告文案当时写「已降级为不匹配」，与真实行为相反，看日志会被误导。
   现在与域名条件同一处理原则：客户端条件全部无法生效时**整条不下发** + 如实说明；
   新增 `mac_only_rule_is_not_emitted_when_ether_sets_unsupported`（旧代码会让它失败）。

三条同类缺陷的共同教训：**能力降级路径必须证明「匹配面没有变宽」**。
只断言集合被声明、或者只断言「有警告产出」都不够，要断言最终规则文本里条件还在，
或者规则整条不存在。

10. **带 comment 的规则没登记进 `Program::tags`**（`9abc322`，M6 暴露）。`firewall::build()`
    为保护源地址 / 绕行目的地址生成了 4 条带 `comment "smw:protected-src:v4"` 之类标签的规则，
    却只把游戏与桶规则登记进 `tags`。M5 之前没人拿 `tags` 和内核实际规则做集合比对，所以漏登记
    一直没被发现；事务层的复核阶段一比就露馅，报的是「多余标签」——**把一次本来正确的提交判成失败并回滚**。
    现在生成规则与登记标签在同一处完成。教训：`tags` 不是元数据，是复核的判据，二者必须同源。
11. **`config::diff()` 漏了 `global.hash_seed`**（`9abc322`）。改种子会重排全部新建连接的落线，
    属于用户必须「在应用前看得见」的变更，但变更清单里不出现，UI 的「变更摘要」就会少报一项。
    同类问题只能靠「diff 覆盖 schema 全部字段」的核对来防，M7 做 RPC 的 changeSummary 时按
    `schema.rs` 的字段清单再核一遍。
12. **`Nft::version()` 把「子进程跑完了」当成「取到版本了」**（本轮修）。旧实现写的是
    `exec::run(&inv).await.ok().map(...)`：`exec::run` 只在超时/无法启动时返回 `Err`，
    退出码非 0 是 `Ok(Outcome{status: 1})`，于是 `nft --version` 失败会返回 `Some("")`。
    UI 上就出现「版本：空」这种既不是「没装」也不是「版本未知」的第三态，`--capabilities`
    还会把它当成有效版本号写进能力表。现在退出码非 0、构造失败、执行失败、stdout 与 stderr
    都为空这四种情况一律 `None` 并各记一条 warning；新增
    `version_only_reports_a_real_string`（注入 `/bin/false` 与 `/bin/echo`）。

**12–18. M7 集成测试（WSL 真 nft/netlink）抓出的七处缺陷**。全部有一个共同点：
替身（`FakeNetlink` / `FirewallExec::Sim` / `/bin/true`）不验证真实语义，
所以此前 353 条单测一条都没红。逐条记录在此，因为每一条都对应一类「测试看着厚、
其实没测到关键路径」的盲区：

13. **`nft -c` 缺 `-f`**（`system/exec.rs`）。试算构造的是 `nft -c <脚本路径>`，
    nft 把路径当命令解析报 `syntax error, unexpected /` —— 真机上每一笔事务都会死在
    试算阶段。修正为 `nft -c -f <文件>`，回归测试锁死 `-c` 与 `-f` 成对。
14. **探测脚本收尾是 `{}` 而不是 `}`**（`system/firewall.rs`）。`probe_scripts()` 的 `mk()`
    在格式字符串里写了 `{{}}`，产出两个字面量 `{}`，整条脚本以 `{}` 结束 ——
    **每一条** mk() 探测都被 `nft -c` 拒绝，能力表大面积假降级（`comments=false`
    会让按标签复核与 handle 定位整体失效，`jhash_map=false` 会让桶映射退化）。
    回归测试断言花括号配平、以单独一行 `}` 收尾、无裸 `{}` 行。
15. **带网关的路由用了 `scope link`**（`system/netlink.rs`、`system/route.rs`）。
    内核对「scope link + gateway」直接 ENETUNREACH；iproute2 对 `via GW` 一律用
    global scope。回归测试断言 `default_v4` 与 plan 产出的 v4/v6 网关路由都是
    `RT_SCOPE_UNIVERSE`，无网关的链路级默认路由保持 link。
16. **netlink socket 的超时从未生效**（`system/netlink.rs`）。`SO_RCVTIMEO`/`SO_SNDTIMEO`
    写在了 `SOL_NETLINK` 层（内核只认 `SOL_SOCKET`），setsockopt 静默 ENOPROTOOPT ——
    没有超时的 netlink recv 会在内核不回复时**永久挂住**整个 spawn_blocking 线程。
    实测表现：主循环卡死、探测轮全停、SIGTERM 杀不掉进程（关停代码跟在主循环后面）。
    另外 `tv_usec` 多乘了 1000。现在超时设不上直接判致命错误。
17. **成功 ACK 不终结会话**（`system/netlink.rs`）。内核的成功 ACK 也是 `NLMSG_ERROR`
    （error==0），解析器只对 `code != 0` 置 `done`，于是每次**成功**的 netlink 写入都继续
    等下一批消息直到超时 —— 实测表现是「路由装上了，却报 recv 超时并回滚」。
18. **路由 dump 不按请求的表过滤**（`system/netlink.rs`）。内核的 `RTM_GETROUTE` dump
    **忽略请求里的 rtm_table**（实测请求 101 会连 main/local 的路由一起返回），而代码按
    24 张表各 dump 一遍：表 101 的路由被收进 24 份，`reconcile` 据此产生 24 条重复删除 ——
    第一次成功、其余全部 ESRCH，启动/关停回收整体失败（残留会跨重启累积）。
    现在按响应消息自带的 `rtm_table` 客户端过滤。
19. **`drop` 当「不分类」**（`system/firewall.rs`）。没有 LAN 设备时程序下发裸 `drop`：
    prerouting 里的 drop 会断掉包括管理面在内的全部流量，把一次配置解析问题放大成
    全网瘫痪，与「管理平面不失联」的核心要求直接冲突（注释与 issue 文案写的都是
    「分类规则已全部停用」——文案才是意图）。改为 `counter comment "smw:no-lan-devices"`。
20. **关停序列跟在主循环后面**（`src/main.rs`）。主循环一旦楔死（第 16 条那种），
    「先停循环再回收」永远走不到，SIGTERM 形同虚设。现在关停序列由信号任务持有，
    带 30 秒看门狗；回收本身也包了 20 秒硬超时（它要抢事务锁）。
21. **`Registry::record()` 把「没有迁移」当成「未知线路」**（`src/health/mod.rs`）。
    一个 bool 同时表达「追踪器没找到」和「没有发生状态迁移」，于是一次普通的无迁移探测
    也会打出「已丢弃」的假日志 —— 排障时把人带偏。现在两者分开。

另有一条**测试设计的坑**记在这里（不是产品缺陷）：夹具里的「别人装的路由」原本用默认路由
（`dst = None/0`）放进表 101，结果被本插件自己的表内默认路由按 (表号, 前缀) 覆盖掉
（`ip route replace` 语义，真实内核也是如此），于是「保留别人的对象」这条断言永远测不到。
改成独立前缀 `172.16.0.0/24` 后才真正跑通。写残留类测试时，**前缀必须和我们的不相撞**。

## 7. 下一步（严格顺序）

1. ~~**M7 RPC + main**~~（已完成）：`src/rpc/mod.rs`（23 方法 + 统一信封 +
   peer-cred ACL + 脱敏审计）+ `src/main.rs`（装配、探测环、调度环 `Scheduler::decide` →
   `Coordinator::submit`、桶轮排 `replace rule` 热替换、域名集合刷新环、SIGHUP/SIGTERM、
   CLI）。`submit()` 返回 `Receipt` 而非 `Result`，RPC 层把回执原样交给 UI。
   端到端验证在 WSL 完成（事务八阶段 / 幂等 / 崩溃回收 / 关停回收 / 23 方法请求响应）。
2. ~~**M8 前端**~~（已完成）：ucode 桥与 ACL + 7 个 JS 视图与 CSS；
   桥接经 WSL ucode CLI 对真实守护进程端到端验证。
3. ~~**M9 打包**~~（已完成）：Makefile + apk + procd + `/etc/nftables.d` 片段
   （由 `--dump-include` 生成，保证同源）+ 四个维护脚本（define 名按
   `package-pack.mk` 实测）+ 真实 SDK 构建与解包核对；
   `--reclaim` 在 WSL 对真实残留（1 规则 + 8 路由 + `inet smw` 表）清场并幂等复核。
4. **M10 自动化 + 真机**：把 M2/M6/M7 的「待真机」条目逐条改成「完成」——
   nft 通道用 `FirewallExec::Real` 重跑同一批结论，5G 重拨、IPv6 绕过、断电重启幂等
   按 `docs/TESTING.md` 的设备矩阵验证；浏览器侧 LuCI 渲染验收也在这里；
   另：设备 SSH 口令与 Web 口令不一致的问题需要仓库所有者澄清后才能上真机。

## 8. 已知阻塞与风险

| 项 | 影响 | 现状 |
|---|---|---|
| 沙箱/开发机无目标设备的 nft 与接口形态 | 无法在开发环境复现目标设备的 nft 版本、5G 模组、双 WAN 拓扑 | **部分解除**：WSL（Debian + 内核 6.18 + nft 1.1.3 + 真 netlink）上完成了端到端验证 —— 事务八阶段、幂等复核、崩溃后启动回收、优雅关停回收、23 个 RPC 方法请求/响应；并借此抓出七处真机必爆缺陷（§6.13–6.19）。WSL 的 nft 1.1.3 缺 `dynamic,timeout` 与 jhash 种子参数（能力探测如实报不可用），设备上更新的 nft 会给出不同结论，**必须以设备实测为准**；M2/M6/M7 的「待真机」条目归 M10 |
| ~~无 clippy / rustfmt~~ | ~~无法交付 Lint 与风格结论~~ | **已解除**：工具链 1.99.1 下 clippy 0 警告 + rustfmt 基线已建立（`32b97ad`） |
| 无目标真机 | 5G 重拨、IPv6 绕过、断电重启幂等、管理面不失联 等只能在 M10 验证 | 相关逻辑已有代码级防护，且 WSL 上验证了「崩溃→重启回收→重装」与「关停回收」两条生命周期；设备特有的重拨/掉电场景结论必须留白 |
| 设备 SSH 口令被拒 | 无法上真机执行 M10 矩阵 | Web（LuCI）登录同一口令成功（HTTP 302 对 403 判别），但 dropbear/ubus 全部拒绝；已按所有者指示停止探测。**需要所有者澄清口令或改发公钥** |
| 游戏预置库需要权威来源 | 违反「不得编造服务器 IP/端口」的风险 | 加载器与校验已就位（`rules::presets`），但**不内置任何数据**；`source` 字段缺失即整条拒绝，单测 `no_preset_is_bundled_in_code` + `missing_source_is_error` 钉住 |
| `getaddrinfo` 不返回 TTL | 域名集合的元素寿命只能取一个下界，偏长会留残值、偏短会加重解析 | 用 `global.dns_ttl_floor_s`（默认 300s，校验 30..86400）作为折中并在 schema 注释、`dns_sets.rs` 模块头、`docs/CONFIGURATION.md` 三处如实写明「这是不完备而非最优」；真 TTL 需换解析器（会引入依赖面），暂未做 |
| DNS 解析结果 ≠ 真实连接目的 | CDN 任播 / GeoDNS / 轮询会让域名规则命中不足 | 属产品固有限制，UI 与文档必须并列展示；DoH/DoT 流量无法从 53 端口识别，不做 SNI/DPI 识别 |
