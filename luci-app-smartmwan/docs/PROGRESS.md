# 进度文档

> 本文件反映**当前工作树**。任何「已完成」都必须能用下面的命令复核；
> 不能用命令复核的结论一律写成「待验证」。

最后更新：0.5.0 周期，代码审查与优化（2026-10-28）之后。

## 1. 一句话状态

后端七层（配置 / 系统交互 / 健康 / 调度 / 规则 / 事务 / **RPC**）+ **守护进程入口** +
**前端** + **打包**已完成，**395 lib + 4 bin + 33 集成测试全绿**；RPC 层 29 个方法、守护进程周期循环、
CLI、rpcd ucode 桥（方法级 ACL）+ 7 个 LuCI 视图、OpenWrt 25.12 apk 打包（含四个维护脚本
与同源安装期文件）都已落地，**真实 SDK 产物已通过逐项校验**；只剩目标设备验收（M10）。
规则层的落点：M5 时它的产物只被单测喂进数据面生成器，现在由事务层真正调用
（`Coordinator::build_plan` → `rules::compile()` → `firewall::build()` → `route::Applier`）。
运行期入口也已存在：守护进程主循环读 UCI、按周期决策并调用 `Coordinator::submit()`。
**本轮端到端验证发生在 WSL**（真 netlink + 真 nft 1.1.3）：事务八阶段、幂等复核、
崩溃后启动回收、优雅关停回收、29 个 RPC 方法请求/响应、`--reclaim` 真实残留清场
（1 条规则 + 8 条路由 + `inet smw` 表，二次调用幂等）全部实测通过；
ucode 桥同样在 WSL 经 CLI 对真实守护进程往返验证（含错误信封透传）；
apk 在真实 SDK（mediatek/filogic aarch64 musl）构建成功并解包核对。
浏览器侧已在真机使用中走查一轮（2026-10-27，所有者反馈驱动），修复四处浏览器专属缺陷；
尚缺一次系统性的三视口 / 深色模式回看与手机端确认（清单见 `docs/UI-DESIGN.md` §9.3）。

## 2. 可复核指标

```sh
cargo test --offline --lib                          # 期望：395 passed; 0 failed
cargo test --offline --tests                        # 期望：33 条集成测试全绿
cargo clippy --offline --all-targets -- -D warnings # 期望：0 警告
cargo fmt --all -- --check                          # 期望：无差异
cargo build --offline                               # 期望：0 警告
./scripts/no-lua-check.sh                           # 期望：退出码 0
find src -name '*.rs' -print0 | xargs -0 cat | wc -l # 行数口径，见 §3 注
```

本环境实测结果（2026-10-28 复核，cargo 1.92.0，Linux x86_64）：

| 命令 | 结果 |
|---|---|
| `cargo test --offline --lib` | `395 passed; 0 failed; 0 ignored` 用时 ~0.7s |
| `cargo test --offline --bins` | `4 passed; 0 failed`（reclaim 配置回落两条 + 下发门控两条） |
| `cargo test --offline --tests` | `33 passed; 0 failed`（config 6 / failover 6 / health 4 / rules 5 / scheduler 6 / transaction 6） |
| `./scripts/no-lua-check.sh` | 退出码 0；注入 `src/accidentally_controller.lua` 或 `require("luci.dispatcher")` 后退出码 1（已实测两个方向） |
| `cargo clippy --offline --all-targets -- -D warnings` | **通过，0 警告** |
| `cargo fmt --all -- --check` | **通过，无差异** |
| `cargo build --offline` | 0 警告 |
| `nft -c -f <脚本>` | **WSL 里可用**（root + nft 1.1.3），并以此完成端到端验证；但**目标设备未测**。WSL 的 nft 1.1.3 缺 `dynamic,timeout` 与 jhash 种子参数，能力探测如实报了「不可用」——设备上更新的 nft 会给出不同结论，必须以设备实测为准 |
| SDK 构建 `make package/luci-app-smartmwan/compile V=s` | **BUILD OK**（mediatek/filogic aarch64 musl SDK，产物 `bin/packages/aarch64_cortex-a53/base/luci-app-smartmwan-0.4.0-r1.apk` —— 构建当时版本号为 0.4.0，现 `PKG_VERSION=0.5.0`，重新构建即得对应包名）；全部门禁先绿再构建 |

## 3. 模块完成度

| 模块 | 行数 | 单测 | 状态 | 说明 |
|---|---:|---:|---|---|
| `src/lib.rs` | 340 | 6 | 完成 | fwmark 布局、错误类型、`NS` 前缀、版本常量 |
| `src/config/` | 4028 | 51 | 完成 | UCI 文本解析/序列化、schema v4、迁移、校验、diff、last-good |
| `src/system/` | 8659 | 118 | 代码完成 / 待真机 | netlink、route、interface、conntrack、exec、firewall（`probe_caps`、`HandleOps`、`include_file_text()`；WSL 真 nft/netlink 已验证） |
| `src/health/` | 3310 | 50 | 完成 | 四类探测 + 滑窗指标 + 状态机 + Registry |
| `src/scheduler/` | 3672 | 60 | 完成 | balancing / failover / latency / hysteresis / 装配层 |
| `src/rules/` | 2441 | 55 | 完成 | matchers / presets / dns_sets / compile；**调用者是 `transaction.rs`** |
| `src/logging.rs` | 539 | 5 | 完成 | 分级 + 环形缓冲 + 轮转 + 脱敏（`recent()`/`dropped()`） |
| `src/transaction.rs` | 2322 | 24 | 代码完成 / 待真机 | 单事务锁 + 固定阶段编排 + 逆序回滚 + last-good 快照 + 残留回收 |
| `src/rpc/` | 2638 | 26 | 代码完成 / 待真机 | 29 方法 + 统一信封 + `SO_PEERCRED` ACL + 脱敏审计 |
| `src/main.rs` | 1653 | 4 | 代码完成 / 待真机 | 守护进程装配 + 周期循环 + 热替换 + 下发门控 + 域名刷新环 + 信号 + CLI（含 `--dump-include`/`--reclaim`；reclaim 配置回落与下发门控有 bin 单测） |

合计 `src/**/*.rs` = **29,602** 行。`transaction.rs` 的内部构成：非测试 1,521 行
（`Stage`/`Decision`/`FirewallExec`/`Plan`/`Receipt`/`Coordinator`），
`#[cfg(test)] mod tests` 起于第 1522 行，测试 801 行。

> 行数口径注：本表改用 `find <dir> -name '*.rs' -print0 | xargs -0 cat | wc -l`
> （原始文件行数，含空行与注释）。此前记录的四层数字（3524 / 7181 / 2904 / 3063，合计 17,494）
> 是另一种口径留下的偏低值，**不是**代码被改小了；今后一律用上表那条命令复核。

按子模块的测试分布（用于判断「哪里测得厚、哪里薄」）：

```text
system::firewall   30   rpc::tests         26   transaction         24
system::route      20   config::validate   20   health::tests       19
system::netlink    17   system::interface  17   scheduler::balancing 17
scheduler::tests   16   rules::tests       18   system::tests       15
rules::dns_sets    15   config::tests      14   scheduler::failover 12
rules::matchers    12   health::probe      12   system::exec        11
health::state      11   rules::presets     10   config::uci         10
scheduler::latency  9   system::conntrack   8   health::metrics      8
config::schema      7   scheduler::hysteresis 6  logging              5
core_tests          6
```

合计 395（`config 51 / system 118 / health 50 / scheduler 60 / rules 55 / logging 5 / lib 6 / transaction 24 / rpc 26`）。
复核命令：`cargo test --offline --lib -- --list` 后按模块前缀计数。

## 4. 目录现状（诚实版）

```text
src/            后端核心，见上表
docs/           本文档集（要求/路线图/进度/交接/架构/配置/安全/测试）
research/       两份上游审计（luci.md、buildsystem.md）—— 设计依据
scripts/        no-lua-check.sh
root/           安装期装配文件（M8/M9 已落地）：
                usr/share/rpcd/ucode/smartmwan.uc   ← rpcd ucode 桥（29 方法转发）
                usr/share/rpcd/acl.d/               ← 方法级 ACL（无通配）
                usr/share/luci/menu.d/              ← 7 标签页菜单
                etc/config/smartmwan                ← 评审快照；安装时被 --dump-defaults 产物覆盖
                etc/init.d/smartmwan                ← procd 服务（term_timeout 30）
                etc/nftables.d/smartmwan.nft        ← 评审快照；安装时被 --dump-include 产物覆盖
htdocs/         LuCI 前端资源（M8 已落地）：
                luci-static/resources/smartmwan.js        ← 共享模块（信封/四态/轮询/格式化）
                luci-static/resources/view/smartmwan/*.js ← 7 个视图
                luci-static/resources/smartmwan/smartmwan.css
tests/          6 个跨层集成测试文件（33 条用例，全部通过）
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
| `5fb62af` | feat(packaging) | M9：OpenWrt 包 Makefile（自建交叉编译）+ 四个 apk 维护脚本 + 同源安装期文件 + `--dump-include`/`--reclaim` CLI + GPLv3 许可证升级；真实 SDK 构建成功并解包逐项核对 |
| （本提交） | fix(m10) | M10 真机验收：六处「测试全绿、真机必坏」缺陷修复（fw4 片段机制 / ucode-mod-socket 依赖 / rpcd 整数 typehint / 停用复核误判 / 停用决策脱节 / init.d reload）+ 菜单迁 admin/network；真机数据面/状态机/幂等/回收全项实测通过（+4 测试 → 382） |

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

### 6.20–6.25 M10 真机验收抓出的六处缺陷（2026-10-26，ImmortalWrt SNAPSHOT）

全部有一个共同点：**每一条在 WSL 与单测里都是绿的，只有装到真实固件上才炸**。

6.20 **fw4 片段被插进 `table inet fw4` 表体内部**。该固件的 fw4 有一条内置
`include "/etc/nftables.d/*.nft"` 通配（fw4 print 第 33 行），落在 `table inet fw4 {`
**内部** —— 独立表片段（`table inet smw {}`）放那里必然语法错误，fw4 报
「The rendered ruleset contains errors」整体拒绝加载，且 `nft list tables` 里永远没有
smw 表。此前 M9 用的「UCI include 段」方案还有第二个问题：`uci add` 创建的是匿名段，
`uci -q get firewall.smartmwan` 幂等判断**永远落空**（升级重复加段、卸载残留），
且 `position` 值在真实 fw4 上不可靠。**修复**：片段改装
`/usr/share/nftables.d/ruleset-post/`（fw4 README 载明的 ruleset 顶层自动片段目录，
miniupnpd 同款机制），postinst/postrm 彻底不碰 UCI firewall。真机复核：
`fw4 check` 全绿、`table inet smw` 出现、卸载后无残留。

6.21 **依赖闭包缺 `ucode-mod-socket`**。该模块是**独立 apk 包**，基础 ucode/rpcd 都
不带；缺了它 rpcd 加载 ucode 桥直接抛 `No module named 'socket'`（rpcd 前台日志抓到），
ubus 对象无法注册、LuCI 全部页面显示「无法连接守护进程」。**修复**：DEPENDS 补
`+ucode-mod-socket`，apk 安装时自动从源补拉。

6.22 **rpcd-mod-ucode 的整数 typehint 值是位宽不是默认值**。args 声明 `{limit: 16}`
被解读为「INT16 位宽策略」（上游 ucode.c：8→INT8、16→INT16、64→INT64、其余→INT32），
ubus 传 INT32 的 `{"limit":5}` 被 `Invalid argument` 拒收。字符串/bool 参数不受影响，
因此 23 个方法里只有 getLogs 挂。**修复**：数字参数一律声明 `0`（→INT32），
默认值由守护进程侧解析兜底。

6.23 **停用清场复核误判**。首次安装 + enabled=0 + `inet smw` 表从未存在时，停用事务的
FirewallVerify 阶段对 `list chain` 报 no-such-table 没有豁免（FirewallApply 阶段有
`is_no_such_table` 豁免，复核阶段漏了同款）——把成功的清场误判为失败并回滚，每次启动
都刷 ERROR。**修复**：复核对「期望空状态（expected 为空）+ no-such-table」放行并写明
依据；非停用路径照旧上抛。回归：`disabled_verify_tolerates_missing_table` /
`enabled_verify_still_fails_on_missing_table`（Sim 新增 `fail_list` 开关精确模拟）。

6.24 **停用后决策与数据面脱节**。调度层 `decide` 不看 `cfg.global.enabled`：停用提交
已把内核对象清空，决策却仍按健康状态给桶，UI 显示「承载流量」而内核里没有任何本插件
规则。**修复**：停用配置显式返回全零桶 Outcome；第一轮 `changed=true`（触发一次停用
清场提交），内部桶状态同步归零，后续轮稳定为无变更（否则每 tick 都会跑空事务）。
回归：`disabled_config_yields_zero_buckets_and_no_traffic_claim` /
`disabled_decide_reports_changed_only_on_transition`。

6.25 **procd init.d 的 reload 两坑**。① 函数必须叫 `reload_service()`——名为
`reload()` 的自定义函数在 USE_PROCD=1 的脚本里**不会被执行**（退出码 0，什么都没发生）；
② busybox 的 `start-stop-daemon -K -HUP` 退出码 0 却**根本不发信号**。**修复**：
改名 `reload_service()` + 直接 `kill -HUP $(cat /var/run/smartmwand.pid)`。
真机双向实测：改 log_level → init.d reload → getConfig 立即反映。

另两条**部署事实**记在这里（不是代码缺陷）：① 该固件内核默认
`net.ipv4.ping_group_range=1 0`（禁用 ping socket），健康探测会诚实告警
「不允许创建 ICMP socket」——部署需解锁并持久化（已写入文档，不自动改系统）；
② 5G 模组的网关不回 ICMP，线路必须显式配置公网 `probe_target`，否则网关可达性
探测会误判 failed（配置后状态机 unknown→failed→recovering→healthy 全链路正常）。

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
4. ~~**M10 真机验收**~~（第一轮已完成，2026-10-26）：真机（ImmortalWrt SNAPSHOT /
   mediatek-filogic aarch64 / nft 1.1.7 / apk 3.0.5）完成安装/升级/卸载、enabled=0 零触碰、
   nft 能力探测、ubus 23 方法往返、LuCI 页面、enabled=1 数据面（ip rule/表 101/inet smw）、
   状态机全链路、幂等复核、停用回收、管理面不失联；抓出六处真机必爆缺陷并全部修复
   （§6.20–6.25）。**剩余真机项**：双 WAN 均衡/主备切换（需第二线路接入 eth0）、
   5G 重拨、断电重启幂等、浏览器侧人工确认（需退出重登刷新菜单缓存）。

## 8. 已知阻塞与风险

| 项 | 影响 | 现状 |
|---|---|---|
| 沙箱/开发机无目标设备的 nft 与接口形态 | 无法在开发环境复现目标设备的 nft 版本、5G 模组、双 WAN 拓扑 | **已解除（真机验证补齐）**：真机 nft 1.1.7 上完成了能力探测与数据面验证；WSL 与真机都缺 `dynamic,timeout` 与 jhash 种子参数（能力探测如实报不可用，域名规则走降级路径） |
| ~~无 clippy / rustfmt~~ | ~~无法交付 Lint 与风格结论~~ | **已解除**：工具链 1.99.1 下 clippy 0 警告 + rustfmt 基线已建立（`32b97ad`） |
| 设备仅一条线路在线（eth0 未接上游） | 双 WAN 均衡/主备切换、5G 重拨场景无法验证 | 单线路场景已全项验证（healthy、数据面、出网、回收）；第二线路接入后即可验证，代码路径（主备/均衡/热替换）有单测覆盖 |
| 断电重启幂等 | 未实测 | 设计有双重防护（启动 reclaim 残留回收 + 幂等提交以快照判定）；待用户断电重启后复核 `ip rule` 不重复 |
| ping socket 需解锁 | 未配置时健康探测全部不可用（诚实告警） | ImmortalWrt 内核默认 `ping_group_range=1 0`；部署要求已写入 `README.md` 与 `docs/TESTING.md`（不自动改系统） |
| 游戏预置库需要权威来源 | 违反「不得编造服务器 IP/端口」的风险 | 加载器与校验已就位（`rules::presets`），但**不内置任何数据**；`source` 字段缺失即整条拒绝，单测 `no_preset_is_bundled_in_code` + `missing_source_is_error` 钉住 |
| `getaddrinfo` 不返回 TTL | 域名集合的元素寿命只能取一个下界，偏长会留残值、偏短会加重解析 | 用 `global.dns_ttl_floor_s`（默认 300s，校验 30..86400）作为折中并在 schema 注释、`dns_sets.rs` 模块头、`docs/CONFIGURATION.md` 三处如实写明「这是不完备而非最优」；真 TTL 需换解析器（会引入依赖面），暂未做 |
| DNS 解析结果 ≠ 真实连接目的 | CDN 任播 / GeoDNS / 轮询会让域名规则命中不足 | 属产品固有限制，UI 与文档必须并列展示；DoH/DoT 流量无法从 53 端口识别，不做 SNI/DPI 识别 |

## 9. 与任务书要求的差距审计（2026-10-27，下一阶段工作清单）

> 原始任务书全文见 `docs/SPEC.md`；本节是对照全文逐条审计后的**未实现/部分实现清单**，
> 是接手者的工作起点。核心链路（配置→事务→数据面→探测→RPC→页面）已全部真实可用
> 并经真机验证；下列缺口均不影响已交付部分的安全性。

### 9.1 RPC 接口形态（SPEC §9）——6 个点名方法已补齐（2026-10-27）

方法表 23 → **29**；`src/rpc/mod.rs::METHODS`、`docs/ARCHITECTURE.md` §6、
`root/usr/share/rpcd/ucode/smartmwan.uc`、`acl.d` 四处已同步，6 条新单测（当时 388 全绿）；
此后又补了跨层集成测试与本轮审查修复，当前基线 **395 lib + 4 bin + 33 集成**（2026-10-28）。

| 任务书方法 | 本仓方法名 | 落地形态 |
|---|---|---|
| `switch_mode` | `switchMode` | 改 `global.mode` + 落盘 + 一轮事务；同值不写盘不下发 |
| `set_primary` | `setPrimary` | 改 `global.primary`；拒绝不存在/已停用/已在 `backup_order` 里的线路 |
| `set_backup_order` | `setBackupOrder` | 改 `global.backup_order`；拒绝空表/重复项/未知线路/主线路 |
| `set_algorithm` | `setAlgorithm` | 改 `global.algorithm`；`weighted_ecmp` 带降级 `hint` |
| `failback`（手动回切） | `failback` | **即时动作**：主线路够格才切，不够格如实 `switched=false` 且不留指令 |
| `diagnostics`（聚合只读诊断） | `diagnostics` | 只读聚合视图，零副作用 |

> 方法名用 camelCase 与既有 23 个方法保持一致；上表左列是任务书的 snake_case 记法，
> 二者一一对应，不存在语义差异。

其余 12 个要求的方法均已覆盖（统一信封 ✓）：status→getStatus、interfaces→getLines、
get_config→getConfig、validate_config→validate、apply_config→apply、get_quality→getGameQuality、
get_traffic→getTraffic、get_connections→getConnections、get_game_rules→getGames、
update_game_rules→save、force_failover→forceWan、get_events→getLogs。

### 9.2 LuCI 前端（SPEC §10.1）——配置编辑**大部分已补齐**（2026-10-27）

此前 7 个页面全部是只读展示（全项目 0 个 input/select，`save` 从未被 UI 调用）。
本轮补齐了编辑链路与版式，**剩余缺口**列在最后。

| 页面 | 本轮落地 |
|---|---|
| 负载均衡 | 算法下拉、桶数、会话保持、最小重排间隔、**逐线路权重**；保存/保存并应用 |
| 主备 | 主线路下拉（`setPrimary`）、备用顺序按序号排序（`setBackupOrder`）、回切方式/延迟/连续成功/最小间隔（草稿 `save`）、**立即回切**（`failback`）、强制切换与取消强制 |
| 系统设置 | 服务启停、健康检测参数（周期/超时/失败阈值/预热）、日志等级、**配置导出/导入**（先 `validate` 再 `save`）、诊断信息（`diagnostics`）、立即探测、重新读取、回滚 |
| 总览 | 实时吞吐表、抖动列、桶分布条形图、能力降级、最近一次事务回执、刷新指示 |
| 线路 | 概览卡片（总数/可用/是否已探测）、逐线路键值卡、维护模式开关 |
| 游戏 | 命中数列（读不到显示「—」）、域名集合、线路评分与规则落点 |

编辑链路一律复用既有 `save → diff → apply`，**界面不把配置直接塞给内核**；
改单个字段的（主线路/备用顺序/算法）走 M11 新增的便捷 RPC。

剩余缺口：

* **游戏页**：预设选择、规则增删改、客户端匹配编辑、评分权重——仍无编辑 UI；
* **线路页**：WAN「自动发现 → 一键采用」——仍需手写 UCI 段；
* **总览页**：「最近切换事件列表」后端没有独立的事件流 RPC
  （现以「最近一次事务回执 + 决策说明」呈现）；
* 轻量 SVG（拓扑/趋势）——未做（SPEC 为建议级）；
* ~~键盘导航/焦点可见性/aria~~（**2026-10-27 已补齐**，见 9.2.1）。

### 9.2.1 前端组件系统（2026-10-27）

七类交互统一到一套组件里（`docs/UI-DESIGN.md` 是完整 API 文档）：

| 组件 | 落地内容 |
|---|---|
| Dialog | 四档尺寸（400/560/840/1080）、固定头尾 + 内容区独立滚动、loading/success/error 状态区、异步提交与重复提交保护、失败可重试、`beforeClose` 未保存拦截 |
| Drawer | 右侧滑出、宽度可配、手机端全屏；已接入「配置编辑器」（JSON 导入导出） |
| Sheet | 底部面板、拖动把手与下滑关闭（仅头部手势，不与内容滚动冲突）、安全区与虚拟键盘避让 |
| Confirm | normal/danger/critical 三级、影响与恢复方式逐条列出、`disconnectRisk`、`requireType` 文字确认、初始焦点在「取消」 |
| Toast | 四类语义、去重、上限 4、错误常驻、可选操作按钮、进度态迁移（进行中→完成/失败） |
| Popover / Tooltip | 挂 body 逃逸 overflow、边缘翻转与视口夹取、外部点击与 ESC、触摸设备点击切换 |
| Form | 12 种控件、字段三段式（标签/说明/错误）、aria 关联、IP/IPv6/端口校验、可折叠分组 |

**同时修掉的三个真实缺陷**（都是「单测/肉眼都看不出、真机才炸」的类型）：
`E()` 嵌套数组导致三处 `[object HTML…]`；`content-box` 让 360px 屏幕上的输入框
溢出视口；`Form.field` 收到 `{el,input}` 时抛出难以定位的 `TypeError`。

**验证**：`node scripts/ui-smoke.js` 194 项（视图渲染 + 全部交互契约 + 静态约束）；
`scripts/ui-preview.html` 用真实模块与样式在浏览器里核对，headless Chromium 已过
1280/500/360 三种视口与深色模式。**真机仍未验证**，见 `docs/UI-DESIGN.md` §9.3。

### 9.3 后端功能缺口（SPEC §6/§9）

* ~~**游戏规则命中统计**~~（**已实现，2026-10-27**）：`firewall::build()` 生成的每条游戏
  规则本来就带 `counter`，缺的是「读回来」的路径。本次补齐三段：
  ① `FirewallExec::rule_counters()` —— **只有真实 nft 通道给出数字**，替身与「无 nft」
  一律 `None`（编造的计数会被界面当成命中率，比没有数字更糟）；
  ② `rules::GameHits::from_listing()` —— 只认 `smw:game:` 标签，一条 UCI 规则对应的
  多条 nft 规则**求和**（桶规则/保护/绕行的计数不混入，否则数字会变成全链流量）；
  ③ 主循环每 30 秒采样一次写进 `AppState.hits`（比探测低频：`nft -a list chain`
  要把整条链拉回来），`getGames` 按规则 slug 返回 `hits`。
  **诚实口径**：从未采样或读不到时 `hits` 是 `null` 且 `hits_note` 写明原因，
  绝不用 0 冒充「没命中过」。
* ~~**diagnostics 聚合诊断**~~（已实现，见 9.1）。

### 9.4 测试缺口（SPEC §14）

* ~~`tests/` 目录全空~~ —— **六个集成测试文件已落地（2026-10-27，33 条）**：
  `tests/config.rs`（6）、`tests/health.rs`（4）、`tests/scheduler.rs`（6）、
  `tests/failover.rs`（6）、`tests/rules.rs`（5）、`tests/transaction.rs`（6）。
  它们串的是**跨模块路径**，与单测不重复：手写 UCI → 解析 → 校验 → 保存 → diff；
  健康状态机的完整时间线；七种算法与权重在桶图上的实际效果；主备切换与回切去抖的时序；
  规则条件在最终 nft 文本里的存在性；事务八阶段、幂等复核、失败回滚与残留回收。
  编写过程中确认了两条容易写错的既有行为：① 回切带**去抖二次确认**（条件满足后的
  第一轮只登记意向），② 滑窗容量为 90（失败样本不会立刻被挤出降级判定）。
  **仍缺**：真机矩阵（见下）、长时间运行/并发配置变更/高连接数性能测试。
* 真机矩阵只走了单线路：**七种算法真机分别验证、双 WAN 权重/主备切换/多级备用/
  自动与手动回切、游戏命中与择优、IPv4/IPv6 分别验证、模组重拨/网关变化、
  firewall4 重载后规则保持、断电重启幂等**——全部未做（部分依赖第二线路接入 eth0）；
* 长时间运行资源占用、并发配置变更（单事务锁有单测）、高连接数调度性能——未测。

### 9.5 小项（SPEC §3/§13）

* `rust-toolchain.toml` 不存在（SPEC 目录建议项；`rust-version` 已在 Cargo.toml）；
* 「首次启用前检查当前网络环境并明确提示」——应用流程有 diff + 风险二次确认，
  但无专门的启用前环境检查提示。

### 9.6 已确认合规的等价实现（不缺，避免接手者误判）

* `src/rpc/ubus.rs` 取消：**记录在案的架构决策**（ucode 桥直连守护进程 Unix socket，
  不引入 ubus 客户端依赖），见 `docs/ARCHITECTURE.md` §7；
* `src/rules/games.rs` → `src/rules/presets.rs`：预置加载器功能等价；
* `root/usr/share/luci/view/` → `htdocs/`：25.12 客户端渲染视图的正确路径；
* 全局模式切换/主线路/备用顺序/算法设置的**数据模型与事务**全支持——只差
  便捷 RPC 形态（9.1）与编辑 UI（9.2）。

### 9.7 建议实施顺序（按 SPEC §15「数据面正确 > 功能完整 > UI 精细化」）

1. 补 6 个 RPC（薄封装，事务层已支持）+ 游戏规则 `counter` 与命中数暴露；
2. 前端配置编辑（复用现有 save/validate/diff/apply 链路；先设置页与均衡页，
   再主备页与游戏页）；
3. 系统设置页补齐（服务启停/导入导出/诊断展示）；
4. 总览页补速率/抖动/事件列表；
5. `tests/` 集成测试六件套；
6. 真机剩余矩阵（部分依赖第二线路接入）。
