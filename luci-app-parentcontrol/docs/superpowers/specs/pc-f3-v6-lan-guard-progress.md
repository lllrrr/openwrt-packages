# pc-f3-v6-lan-guard · Progress（code pane 执行记录）

- 日期：2026-10-09；执行者：code pane（`op-pc-code`）；conductor：`wR:p1`
- 依据：`pc-f3-v6-lan-guard-{design,adr,plan,testplan}.md`；执行清单 P0–P10 逐步完成。

## 1. 改动清单（文件 + 位置 + 内容）

| 文件 | 位置 | 内容 |
|---|---|---|
| `root/usr/lib/parentcontrol/common.sh` | `pc_lan_nets()` 之后新增 `pc_lan_nets6()`（约 :334-357） | 遍历 `proto='static'` 的 network 节（与 `pc_lan_nets` 同一 sed 口径）；设备名取 `device`、空则回退 `ifname`、再空则跳过该节；唯一数据源 `ip -6 route show dev <dev>`；逐行剔除含 ` via ` 的转发路由（行首即便是合法前缀也排除——下游路由器经 br-lan 通告的场景）；行首白名单 `grep -E '^([0-9A-Fa-f]*:)+[0-9A-Fa-f:]*/[0-9]+$'`（自动拒 `unreachable`/`default`/`throw`/`blackhole`）；`sort -u` 去重；`ip` 不存在/输出空 → 该节产出空、整体 rc=0 |
| `root/etc/init.d/parentcontrol` | `allow_lan_in()` 函数体（:334-347） | 族感知：`$1 = $ipt6` → `pc_lan_nets6()`，否则 `pc_lan_nets()`（v4 一字不改）；**删除** `addr_is_family "$_n" "$_fam6" \|\| continue` 及 `_fam6` 局部变量（= F3 根因）；下发改走既有的 `ipt_do`（PC_RENDER 渲染模式自动把守卫记进 quotaspec 指纹）。**签名保持 3 参不变**；`addr_is_family()` 函数本身未删（`devcount`/`add_dev_rules`/`add_dev_rule_single` 仍在用） |
| `test/fakes/ip` | 整文件 | 保留 `neigh show`（`FAKE_IP_NEIGH`）；新增 `ip -6 route show dev <dev>`：从 `FAKE_IP_ROUTE6`（真实 `ip -6 route` 输出格式）按行内 `dev <device>` 精确 token 过滤后原样输出；未设置/文件不存在 → 空输出 |
| `test/lib.sh` | 桩能力区 | 新增并导出 `FAKE_IP_ROUTE6=`（默认空，不惊动既有用例） |
| `test/common_test.sh` | 末尾新增块 | **W-F3-01..06**（`pc_lan_nets6` 单元，详见 §2） |
| `test/init_test.sh` | 末尾新增块 | **W-F3-07..12**（守卫下发/顺序/降级/幂等/指纹/自愈，详见 §2） |
| `test/mutation_check.sh` | 末尾新增 | **M-F3-01/02/03** 三条变异（详见 §3） |
| `Makefile` | :9-10 | `PKG_VERSION` 1.8.1→**1.8.2**；`PKG_RELEASE` 20261008→**20261009** |

**未动**（红线自查）：`pc_lan_nets()`（v4 语义冻结）、`render_quota_spec()` / `build_quota_blocks()` / `_quota_emit_rules()` / `block_skip_devless()`（一行未改，P2 论证成立：`_quota_emit_rules` 末尾本就双族调用 `allow_lan_in`，族由 `$1` 判定）；`addr_is_family()` 函数保留；未新增链/hook/依赖；未碰真机。

## 2. 白盒用例（W-F3-01..12，全部 PASS）

**`common_test.sh`（`pc_lan_nets6` 单元）**
- W-F3-01 直连三行（GUA `/64` + ULA `/64` + `fe80::/64`，复刻真机 br-lan）→ 恰好 3 行、逐行等于预期（按 `sort -u` 序比对，规避 locale 差异）
- W-F3-02 追加 `default dev br-lan`、`default from … via …`、`throw`、`blackhole`、`<prefix> via fe80::9` 五行 → 输出仍恰 3 行（白名单 + via 排除双保险）
- W-F3-03 复刻真机 `dev lo` 的 `unreachable` 三行 + lan 直连 → lo 节产出为空，lan 不受影响（ADR-6）
- W-F3-04 路由文件为空 / 未设置 → 输出空、rc=0
- W-F3-05 静态节无 `device` 也无 `ifname` → 跳过该节、rc=0
- W-F3-06 两条节（lan/iot）同挂 br-lan 产出同一前缀 → 去重后只出现一次

**`init_test.sh`（守卫下发集成）**
- W-F3-07 time+weburl 条目额度耗尽 + lan(loopback+lan) 静态节 + br-lan 三前缀 → v6 QUOTA 链恰 3 条 `-d <prefix> -j RETURN`（覆盖每一前缀）；v4 守卫仍 `-d 192.0.2.1/255.255.255.0 -j RETURN`
- W-F3-08 有/无 `FAKE_IP_ROUTE6` 两种环境下 v4 规则集**逐条相同**（v6 改动零外溢）
- W-F3-09 链首目标 = RETURN；首条 RETURN 行号 < 首条 DROP 行号（全部守卫先于封锁）
- W-F3-10 链中同时存在「`-d 2001:db8:ffff:0::/64 -m mac … -j DROP`」（非 LAN 解析段仍封，带设备条件）与 LAN 守卫 → A3 的规则层证明
- W-F3-11 连续两次 `build_quota_blocks` → v6 链计数器 4242 原样保留（一个 iptables 都没动，F1 指纹机制）；**改 FAKE_IP_ROUTE6 加第 4 前缀 → 指纹失效重建，守卫 3→4**（证明 v6 守卫确实纳入 quotaspec，R6）
- W-F3-12 外部 `ip6tables -t mangle -F PARENTCONTROL_QUOTA` 后自愈重建 → 守卫回 3 条；`run_build` 后链声明仍 2 条/族（不新增链，A7）

## 3. 变异（M-F3-01..03，全部 killed）

| ID | 变异 | 被谁杀 |
|---|---|---|
| M-F3-01 | `pc_lan_nets6` 的行首白名单 grep 换成 `grep -E '.'`（直接放行第 1 字段） | W-F3-02（`default`/`throw`/`blackhole` 被当网段 → 3 行断言红） |
| M-F3-02 | `allow_lan_in` 退回族过滤：两族都用 `pc_lan_nets` + `addr_is_family … || continue`（原 F3 缺陷形态） | W-F3-07（v4/v6 守卫全消失） |
| M-F3-03 | 不按族选数据源：两族都用 `pc_lan_nets()`（无过滤） | W-F3-07（v6 链出现 IPv4 网段守卫，RETURN 计数 ≠ 3） |

## 4. 闸门结果（P9）

```
$ sh test/run.sh
  PASS (92 checks)    # common_test（含 W-F3-01..06，+12 checks）
  PASS (138 checks)   # init_test（含 W-F3-07..12，+18 checks）
  PASS (73 checks)    # acceptance_test（未改动，无回归）
  PASS (94 checks)    # migrate_test（未改动，无回归）
  ALL SUITES PASS

$ sh test/mutation_check.sh
  被杀 50 / 存活 0 / 锚点失效 0   （既有 47 条 + M-F3-01/02/03 三条新增；M-F3-01/02/03 均在列且 killed）

$ sh test/build_ipk.sh → luci-app-parentcontrol_1.8.2-20261009_all.ipk（28 个数据文件）
  第 1 次 md5: a1c36a22af491217d2a40cc5c97147a5
  第 2 次 md5: a1c36a22af491217d2a40cc5c97147a5   （可复现 ✓）
  包内 28 个数据文件与仓库逐字节一致（解包 cmp 全 ok）✓
```
包路径：`.build/luci-app-parentcontrol_1.8.2-20261009_all.ipk`（另存了一份在 `.build2/` 作可复现性对照；两者 md5 相同）。

## 5. 遇到的坑（实现记录）

1. **via 行的 read 语义**：`read -r _pfx _rest` 会吃掉第 1 字段后的分隔空格，`_rest` 以 `via` **开头**而非 `" via "`——第一版排除模式 `*" via "*` 匹配不到，`<prefix> via …` 的前缀漏进输出（W-F3-02 抓住）。已改为 `"via "*|*" via "*` 两个分支。
2. **变异锚点的引号/正则转义**：M-F3-01 的锚点含 `'` 与 `$`，第一版用双引号 + `\$` 转义两次都丢字符（一次丢 `$`、一次丢 `+`）。改为「单引号分段 + `${Q}`（`Q="'"`）拼接」后一次通过——与文件里既有 W6 变异的写法同款。
3. **W-F3-08 后的夹具状态**：`fresh()` 会清掉 `$IPDIR`（解析结果）；重建若只调 `build_quota_blocks` 不会重新解析，v6 解析段 DROP 规则缺失（W-F3-10 抓住）。重建统一改走 `run_build`（= refresh_ips + build_all，与真实生命周期一致）。
4. **v6 前缀的规范化差异**：`pc_lan_nets6` 不做前缀运算（`ip` 给的就是 CIDR），而 `ip6_slash64()` 会把 `2001:db8:ffff::1` 规范化成 `2001:db8:ffff:0::/64`——两类来源的书写形式不同是既有行为，断言按各自实际输出写（W-F3-10 用 `ffff:0::/64`）。

## 6. 遗留 / 给 test pane 与 review 的备注

1. **真机侧新增行为**：装 1.8.2 后 v6 QUOTA 链每分钟 tick 的 quotaspec 将包含 3 条 v6 守卫；若运营商换 GUA 前缀，`ip -6 route` 输出变化 → 指纹失效 → 下一分钟自动跟随（ADR grill #4 的倾向方案，无需人工干预）。
2. **`loopback` 节**：真机 `dev lo` 三行全是 `unreachable` → `pc_lan_nets6` 对 lo 产出为空（ADR-6 正确结果）；v6 无 `::1/128` 守卫是有意为之。
3. **设计文档差异备案**：design D5 原写「`render_quota_spec`/`_quota_emit_rules` 2 参改 3 参」，plan P2 已收窄为「不改签名、族由 `$1` 判定」——本轮按 plan 执行，`render_quota_spec`/`_quota_emit_rules`/`build_quota_blocks`/`block_skip_devless` 零改动。
4. 真机黑盒 B-F3-01..08（含 D10 三条收尾口径）由阶段 6 test pane 执行；本 pane 未做任何真机操作。

## 7. 信号

✅ EXECUTOR_DONE（详见回调）：F3 v6 LAN guard 实现完成，三闸门全绿。

## 8. 复审修复轮（阶段 5 REVIEW_PASS · SF-1/SF-2/Nit-1，2026-10-09）

复审结论 REVIEW_PASS（无 Blocker），按 conductor 更新后的文档（design D2/D4/D11、ADR-3 增补、plan P1/P2/P5-P6/P7/P9、testplan §2.1/§5）修复三条。

### SF-1 · `pc_lan_nets6()` 零长前缀排除（潜在 fail-open）

- **根因**：行首白名单 `^([0-9A-Fa-f]*:)+[0-9A-Fa-f:]*/[0-9]+$` 能匹配数字形式的全零前缀 `::/0`（及 `0:0:…:0/0`）→ 进链即 `-d ::/0 -j RETURN` = 放行一切，IPv6 封锁静默失效。conductor 真机只读核实 busybox `ip` 打印默认路由为 `default …`、无 `::/0` 字面量 → 当前不可利用，按 Should-fix 堵死。
- **修复**：`common.sh` 的 `pc_lan_nets6()` 在 via 排除后新增一行：`case "$_pfx" in */0) continue ;; esac`（拒绝一切以 `/0` 结尾的字段，覆盖 `::/0` 与 `0:0:…:0/0`）。
- **配套测试**：W-F3-13（`test/common_test.sh`）——注入 `::/0 dev br-lan …` 与 `0:0:0:0:0:0:0:0/0 dev br-lan …` 两行，断言输出仍只有真实直连前缀 `2001:db8:1::/64`；变异 M-F3-04（删掉该排除行 → W-F3-13 红，已单独验证 killed）。

### SF-2 · `allow_lan_in()` v4 分支跳过含 `:` 的值

- **根因**：删除 `addr_is_family` 过滤后，v4 分支对 `network` 静态节的 `ipaddr` 不再排除含 `:` 的值（配置异常/迁移残留）→ 非法规则透传进 `iptables` + 渲染指纹与实际规则永久不一致 → 每分钟无谓全量重建。
- **修复**：`init.d` 的 `allow_lan_in()` v4 分支改为 `_nets=$(pc_lan_nets | grep -v ':')`（等价于改动前 `addr_is_family "$_n" 0` 的语义）；**v6 分支不加任何过滤**（族由数据源决定）。`pc_lan_nets()` 本体一字未动（ADR-5）。
- **配套测试**：W-F3-14（`test/init_test.sh`）——`network.lan` 的 `ipaddr='fd00::1'` + netmask → 断言 v4 QUOTA 链**不出现** `fd00::1`（非法规则不透传）、v6 链守卫照常下发（`-d 2001:db8:1::/64 -j RETURN`）。

### Nit-1 · W-F3-05 恒真 → 可鉴别化

- 原断言在无 `FAKE_IP_ROUTE6` 数据时对任何实现都输出空。改为 testplan §2.1 的第一种形式：**保持 `FAKE_IP_ROUTE6` 含真实前缀（`2001:db8:1::/64 dev br-lan …`）+ 只给无 `device`/`ifname` 的静态节 → 断言空**；并加**对照组**——同一节补上 `option device 'br-lan'` 后断言输出恰为该前缀（证明「空」来自跳过而非实现恒空）。

### 变异锚点联动调整

- M-F3-02 / M-F3-03 的锚点随 SF-2 的 else 分支改动同步更新（纳入新增注释行与 `grep -v ':'` 写法；单引号参数内的 `':'` 用 `'\''` 转义传递）。四条单独跑结果见 §9。

## 9. 复审修复轮闸门结果

```
$ sh test/run.sh
  PASS (94 checks)    # common_test（+W-F3-05 对照组 2 项、W-F3-13 1 项）
  PASS (140 checks)   # init_test（+W-F3-14 2 项）
  PASS (73 checks)    # acceptance_test
  PASS (94 checks)    # migrate_test
  ALL SUITES PASS

$ MUT_ONLY=<单条> sh test/mutation_check.sh（四条分别验证）
  M-F3-01: killed 1 / survived 0 / 锚点失效 0
  M-F3-02: killed 1 / survived 0 / 锚点失效 0
  M-F3-03: killed 1 / survived 0 / 锚点失效 0
  M-F3-04: killed 1 / survived 0 / 锚点失效 0

$ sh test/mutation_check.sh（全量，后台串行单实例）
  被杀 51 / 存活 0 / 锚点失效 0

$ sh test/build_ipk.sh（连续两次）
  md5 均为 56db2abf28458962299da77b51e89a64（可复现 ✓）
  包内 28 个数据文件与仓库逐字节一致 ✓
```
包路径：`.build/luci-app-parentcontrol_1.8.2-20261009_all.ipk`（md5 相对上一轮变化 = common.sh/init.d 内容更新所致，符合预期）。

### 本轮红线自查

- `pc_lan_nets()` 一字未动；`render_quota_spec()` / `_quota_emit_rules()` / `build_quota_blocks()` / `block_skip_devless()` 零改动；`addr_is_family()` 函数保留（仍在 `devcount`/`add_dev_rules`/`add_dev_rule_single` 使用）。
- 未新增链/依赖；未碰真机；改动仅落在允许清单的文件内。

## 10. 信号（历史）

✅ EXECUTOR_DONE: 复审 SF-1/SF-2/Nit-1 全部修复——零长前缀排除（::/0 fail-open 堵死）、v4 分支跳过含冒号 ipaddr（指纹不再失配）、W-F3-05 可鉴别化；新增 W-F3-13/W-F3-14/M-F3-04；三闸门全绿（run.sh ALL SUITES PASS、mutation 51/51 全杀、ipk 两次构建 md5 一致）。

---

## 11. 阶段 6：测试 pane 白盒复核 + 真机黑盒验收（test pane，`/new` 独立会话）

**角色**：test pane（最后一道门）｜**日期**：2026-10-09｜**报告**：`docs/superpowers/specs/pc-f3-v6-lan-guard-test-report.md`

### 11.1 第一部分：白盒独立复核（macOS）

```
$ sh test/run.sh
  ALL SUITES PASS（rc=0，real 4m39.7s）
  common_test PASS(94) / init_test PASS(140) / acceptance_test PASS(73) / migrate_test PASS(94) + lint×4 + UI static
  FAIL 计数 = 0
  W-F3-01..14 全部真跑到并 ok（14/14）
```

隔离变异（单实例串行）：

```
$ MUT_ONLY='M-F3-01' sh test/mutation_check.sh   → 被杀 1 / 存活 0 / 锚点失效 0
$ MUT_ONLY='M-F3-02' sh test/mutation_check.sh   → 被杀 1 / 存活 0 / 锚点失效 0
$ MUT_ONLY='M-F3-03' sh test/mutation_check.sh   → 被杀 1 / 存活 0 / 锚点失效 0
$ MUT_ONLY='M-F3-04' sh test/mutation_check.sh   → 被杀 1 / 存活 0 / 锚点失效 0
$ sh test/mutation_check.sh（全量，单实例串行）   → 被杀 51 / 存活 0 / 锚点失效 0
```

独立可鉴别性实验（在 `mktemp -d` 一次性副本中做，真仓库未写入；事后两生产文件 md5 与实验前完全一致 ⇒ 未留痕）：

- **EXP-A**（删 `case "$_pfx" in */0) continue ;; esac`）→ `sh test/common_test.sh`：`FAIL W-F3-13: ::/0 与全零前缀被排除，直连前缀照常` / `FAILED (1/94 checks failed)` ⇒ 恰 1 条失败且正是 W-F3-13，方向正确。
- **EXP-B**（把 `_nets=$(pc_lan_nets | grep -v ':')` 改回 `_nets=$(pc_lan_nets)`）→ `sh test/init_test.sh`：`FAIL W-F3-14: v4 链不出现含冒号的 ipaddr（非法规则不得透传）` `got=[1]` / `FAILED (1/140 checks failed)`，同组 v6 断言仍 `ok` ⇒ 恰 1 条失败，方向正确。

R3/R4/R5/R6 未被改动且仍 PASS：`git diff -U0 test/common_test.sh` = 单一 hunk `@@ -278,0 +279,105 @@`（纯追加，R3@216 未动）；`git diff -U0 test/init_test.sh` = 单一 hunk `@@ -858,0 +859,135 @@`（纯追加，R4@441、R5@449-460 未动）；`test/acceptance_test.sh` md5 `532199b081313fad21ae07c4935b8c42` == `git show HEAD:…` ⇒ R6 未动且 F1 自愈断言 PASS。

> 评审提醒已核实：本机**并发**跑全量 mutation 会假失败（脚本自身 `trap 'rm -rf "$WORK"' EXIT INT TERM` 收 SIGTERM 提前删工作目录 → 大量「锚点未命中」），故全程单实例。

### 11.2 第二部分：真机黑盒验收（B-F3-01..08 + R7/R8）

环境与基线全部逐项匹配（1.8.1-20261008；`init.d` `7b49e500…`；`common.sh` `a422ef5a…`；`uci export` `247c232f…`；raw `0d7609d2…`；72/54；QUOTA 53/39；br-lan 3 条直连路由；iPad 节 `@weburl[0]`）。

| 用例 | 结论 | 关键证据 |
|---|---|---|
| B-F3-01 | PASS | `opkg install` rc=0；版本 1.8.2-20261009；v6 QUOTA 首 3 条 = 3 前缀 `-j RETURN`；v6 54→**57**、39→**42** |
| B-F3-02 | PASS | ①v4 72/53 + iPad-v4 `4de4df07…` 不变 ②iPad-v6 `3f2ab84d…` 不变 ③剥 3 条后 v6 md5 `0e1f271913719b297a94e4f0c28df161` == 基线（62==62 行） |
| B-F3-03 | PASS | ①路由器 v6 管理地址 200/0.0158s（含 Host 判别性反证 200）②小红书 v6 `Connection timed out after 8007 ms`，`nc` rc=1，目标 IP 规则 `0→18 pkts` ③百度 200 |
| B-F3-04 | PASS（只读）/ 破坏性 SKIP | `route_lines=3 guard_lines=3`，逐条一致 |
| B-F3-05 | PASS | 3 次 reload 稳定 57/42 不堆叠；`-F` 后 1 个 tick（70 s）v4/v6 双双自愈 |
| B-F3-06 | PASS | 双 md5 不变；v4 `-S` md5 == 基线；v6 剥 3 条 == 基线；无新链/表；PREROUTING 顺序不变 |
| B-F3-07 | PASS | 4 个 LuCI 页 200（368/368/322/673 CJK）；SSH 可连；iPad 当日用量未受影响 |
| B-F3-08 | PASS | S5 gate 全项绿（下节） |
| R7 | PASS | iPad v4/v6 指纹逐字节不变（测 4 次） |
| R8 | PASS | `build_ipk.sh` 连续两次 md5 均为 `56db2abf28458962299da77b51e89a64`，与部署产物解包 tree_md5 `4126dbf90bac7d1335329f3875be0ba2` 一致 |

**终态口径**（conductor 裁定 `m00177`）：终态 = 部署稳态（保留 1.8.2），v6 = **57/42**（= 基线 +3，且 +3 恰为 3 条 `-d <直连前缀> -j RETURN`），**不是** F1/F2 模板值 72/54。

**收尾 gate（19:00:34 CST）**：`installed=1.8.2-20261009`；`v4m=72 v4q=53`、`v6m=57 v6q=42`；`export_md5=247c232f…`；`raw_md5=0d7609d2…`；`ipad_v4=4de4df07…`、`ipad_v6=3f2ab84d…`；`guards=3`；`bbtest=0`；`deadman_procs=0 fired=no`；`service_enabled=1 cron=2`；`init.d 75e9836e…`、`common.sh 20979c45…`（未被 deadman 还原）；`leftover_pc_count=0`（真机仅剩服务自身运行时目录 `/tmp/parentcontrol`）；本机 `/tmp/pc-sshpass.txt` 已删、口令扫描干净。

### 11.3 红线自查

未改生产代码 ✓ / 未改测试代码 ✓ / 未碰 iPad 与网络配置 ✓ / 未新增链或规则类别 ✓ / deadman 已清理（fired=no）✓ / 口令未落盘 ✓ / 真机已回基线（除应有的 +3 条 v6 守卫）✓ / 未 `git commit`·`git push` ✓ / 发现问题只记录未改代码 ✓

### 11.4 信号（最新）

✅ TEST_DONE: B-F3-01..08 **8 PASS / 0 FAIL / 0 SKIP**（B-F3-04 破坏性降级子场景另计 SKIP，该用例本身 PASS）；白盒 W-F3-01..14 全 PASS、M-F3-01..04 各「被杀 1 / 存活 0 / 锚点失效 0」、全量 51/0/0；R7/R8 PASS；最终 gate 全绿。报告：`docs/superpowers/specs/pc-f3-v6-lan-guard-test-report.md`。独立观察项（非 F3 回归，成因已查清）：B-F3-03 首次探针曾出现 302，**与 flow offload 无关** —— 补采真机只读证据显示 `/tmp/pc_offload_state=disabled` 且 `nft list ruleset | grep -c 'flow add'` = 0（插件已按设计关闭 offload），属 `reload` 生效的秒级时序窗口（详见报告 §5.2）。

✅ TEST_FOLLOWUP_DONE: §5.2 更正为 **(a)** —— 首次 302 与 flow offload 无关；关键证据 `/tmp/pc_offload_state=disabled` 且 `nft list ruleset | grep -c 'flow add'` = 0；已在 §5.2 明确标注「UCI option / flowtable 表定义」为**无效证据**；§1 与 §6 同步更正。口令由操作员在内存中提供（`SSHPASS` 仅用于 `sshpass -e`），**未落盘**，`/tmp/pc-sshpass.txt` 未重建。

### 11.5 流水线收口（conductor）

✅ PIPELINE_DONE: F3 v6 LAN guard 走完 herdr 四角色流水线全六阶段。

- 阶段 1 spec（用户确认 `m01497`）→ 阶段 2 grill + ADR-1..9 + glossary（用户裁定 `m01516`/`m01538`/`m01546`）→ 阶段 3 plan + testplan（用户放行 `m01576`）→ 阶段 4 `wR:p4` 实现 + 白盒 → 阶段 5 `wR:p2` `/thermos` 复审（`m01647` 首轮 `REVIEW_PASS` + 4 条 Should-fix）→ loop 修复轮 → 阶段 5′ 增量复审 `DELTA_REVIEW_PASS` → 阶段 6 `wR:p3` 白盒独立复核 + 真机黑盒（8 PASS / 0 FAIL / 0 SKIP）。
- 修复轮内容：SF-1 拒一切 `/0` 结尾前缀（堵 `::/0` → `-d ::/0 -j RETURN` 的 fail-open）＋ W-F3-13 / M-F3-04；SF-2 v4 分支跳过含 `:` 的 ipaddr ＋ W-F3-14；Nit-1 W-F3-05 可鉴别化。
- 裁定接受为残差（不修）：SF-3（2 行重复，改则破坏 ADR-5 v4 冻结）、Nit-1/2/3/4、Nit-5（`grep -v ':'` 与 `addr_is_family 0` 纯理论不等价）、Nit-6（`sample_counters` SIGPIPE，**既有缺陷**，转独立跟进项）。
- 交付：`dbda708`（17 文件 +2127/−16）→ push `c2e0775..dbda708`；annotated tag **`v1.8.2`** → `15c832c`；包 `luci-app-parentcontrol_1.8.2-20261009_all.ipk` md5 `56db2abf28458962299da77b51e89a64`（两次构建一致）。
- 真机终态（部署稳态，**保留 1.8.2**）：`installed=1.8.2-20261009`；v4 `72/53`、v6 `57/42`（= 基线 +3 条守卫，`guards=3`）；`export_md5=247c232f…`、`raw_md5=0d7609d2…`；iPad 指纹 v4 `4de4df07…` / v6 `3f2ab84d…` 逐字节不变；`init.d=75e9836e…`、`common.sh=20979c45…`；`bbtest=0`；deadman `fired=no` 且进程为 0；`service_enabled=1 cron=2`；真机 `/tmp` 无 `pc-*` 残留。
- 隐私：8 份 F3 文档与 README 已按仓库既有约定全量清洗（无口令、无真机 MAC/IP/GUA/ULA 字面量，一律占位符）；`pc-f3-v6-lan-guard-review.md` 清洗 12 处、`pc-f3-v6-lan-guard-test-report.md` 清洗 45 处。
- 遗留（F3 范围外，未处理）：Nit-6 `sample_counters` SIGPIPE；O3 到路由器的 DNS 查询被 LAN 守卫放行（v4/v6 一致，要改须单独立项）；`reload` 生效的秒级时序窗口。
