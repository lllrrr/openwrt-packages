# pc-acceptance — 阶段 6 测试报告（test / 复测）

- 日期：2026-10-04；角色：test pane（tester）；conductor：`wR:p1`；task-brief：`pc-acceptance`
- 环境：白盒（主机 sh + python3）；上线黑盒（ImmortalWrt 23.05.4 x86/64，本机 Mac 作受管设备）
- 基线：`uci export parentcontrol` md5 = `247c232f2a245ecd991999b31f7d55be`；mangle `-A` = v4 72 / v6 54
- 结论：**TEST_PASS**（无 FAIL、无 SKIP；变异已跑**全量** 39/39）

---

## 0. 凭据与隐私合规（硬要求）

- 全程凭据只在仓库外 `source /tmp/pc-bb-env.sh`（600）读取，未写入仓库任何文件。
- 本报告内路由器/设备标识一律占位符：`<router-ip>`、`<test-device-mac>`、`<test-device-ip>`、
  `<managed-device-mac>`、`<router-lan>`、`<probe-ip>`。**无口令、无真机 MAC/IP 字面量**。
- 与上一轮 Blocker B1 同类的问题：本报告零命中。

## 0.1 环境限制（如实声明）

1. **Clash TUN（本机 Mac）**：只有 Clash 走 **DIRECT 的境内**目标能看到真实 IP。探针选 `www.sogou.com`
   （境内直连，`<probe-ip>`），已在路由器 conntrack 确认 `src=<test-device-ip> dst=<probe-ip>` 直连
   （WAN 出口 IP 回流）→ **可观测**。**境外/代理目标不可观测**（TUN 封装不经路由器 mangle 命中），
   涉及对照目标（B4-④）只做了**可达性**验证，未做「经路由器封锁」验证。
2. **变异已跑全量**（39 个，约 36 分钟）：**39 killed / 0 survived / 0 锚点失效**（见 §A.2）。
3. **B3 / B9 已按用户批准执行**（本轮补测）：见 §B-B3 / §B-B9，均 **PASS**。

## 0.2 ⚠ 部署差异（本轮关键发现）

真机**已安装**的 `parts.lua` 仍是 **HEAD 的旧缺陷版**（md5 `cb458ecf…`，`submitted()` 直接
`format(…, self.section, …)` → 表当字符串），**不是**工作树里的修复版（md5 `51b4e7ad…`）。
所有其它 `luasrc` 文件与工作树**一致**（逐文件 md5 比对）。即：**修复已在仓库、但未部署**。

- 现象：编辑页 GET 200，但**任何保存 POST → 500**（`parts.lua:36: bad argument #2 to 'format'
  (string expected, got table)`）——即 A36/B16 在**已安装构建**上仍 FAIL。
- 处置：为完成「真机 B16 必须验证修复」的要求，test pane 把**工作树的修复版** `parts.lua` 部署到路由器
  （先备份 `/tmp/pc-lua-parts.orig`），清 LuCI 缓存后重跑 B16 → **PASS**（见 §B-B16）。
- 现状（用户已批准）：路由器 `parts.lua` = **修复版**（`51b4e7ad…`）**保留部署**，LuCI 与受测代码树一致；
  原文件备份保留在 `/tmp/pc-lua-parts.orig`（本轮未回退）。

---

## A. 白盒复核（重跑）

### A.1 `sh test/run.sh` → **ALL SUITES PASS**（独立重跑，rc=0）

| 套件 | 结果 | checks |
|---|---|---|
| lint: locals | 通过 | — |
| lint: busybox-ash 兼容性 | 通过 | — |
| lint: LuCI 全局类 | 通过 | — |
| lint: TSV 解析器唯一性 | 通过 | — |
| UI 静态结构（W37/W38/W39/W42，**非行为级**） | 通过 | 42 项 |
| `common_test.sh` | PASS | **76** |
| `init_test.sh` | PASS | **116** |
| `acceptance_test.sh` | PASS | **63** |
| `migrate_test.sh` | PASS | **94** |

核对：common 76 / init 116 / acceptance 63 / migrate 94 —— 与 testplan/progress 声明的计数一致。

### A.2 变异（**全量**，39 个）

`sh test/mutation_check.sh`（完整跑完，`EXIT=0`）：

```
== 变异测试（期望：每个都被杀死）==
  killed    SNI 端口 80,443→80,8443（init_test.sh 失败）
  killed    SNI 规则整条删除（init_test.sh 失败）
  killed    PREROUTING 顺序被改（init_test.sh 失败）
  killed    refresh_holiday 永不联网（init_test.sh 失败）
  killed    采样阈值失效（任何非零增量都记 1 分钟）（init_test.sh 失败）
  killed    共享池口径失效（池额度永远读不到）（init_test.sh 失败）
  killed    重建自愈能力丢失（init_test.sh 失败）
  killed    可用时段被忽略（common_test.sh 失败）
  killed    isOffDay 判反（common_test.sh 失败）
  killed    迁移不写可用时段（migrate_test.sh 失败）
  killed    额度遍历输出重复 key（init_test.sh 失败）
  killed    计数不计 DNS 字符串命中（init_test.sh 失败）
  killed    计数装错表(filter)（init_test.sh 失败）
  killed    首次采样不计数（丢掉开机后那段用量）（init_test.sh 失败）
  killed    拆除残留 mangle 链（init_test.sh 失败）
  killed    W2: local a,b=0 回归（lint_ash 拦截）（run.sh 失败）
  killed    W3: start 崩在 time 之后（acceptance_test.sh 失败）
  killed    W4: 老 WEBURL/IP 链清理用错表（acceptance_test.sh 失败）
  killed    W5: 陈旧锁不自愈（acceptance_test.sh 失败）
  killed    W6: trap 清锁失效（acceptance_test.sh 失败）
  killed    W7: hotplug 判断回到旧版 bug（acceptance_test.sh 失败）
  killed    W9: offload 删除被禁（acceptance_test.sh 失败）
  killed    W10: offload 恢复装不回（acceptance_test.sh 失败）
  killed    W11: conntrack 清理被禁（acceptance_test.sh 失败）
  killed    W13: CIDR 不再直通（acceptance_test.sh 失败）
  killed    W14: ip_mask=32 分支失效（acceptance_test.sh 失败）
  killed    W16: cron 不剔旧条目（init_test.sh 失败）
  killed    W17: 关键词猜测被砍（acceptance_test.sh 失败）
  killed    W32: 计数身份 ip 优先被破坏（acceptance_test.sh 失败）
  killed    W37: 档案摘要不去秒（ui_static_test.sh 失败）
  killed    W38a: 起=止重新放行（ui_static_test.sh 失败）
  killed    W38b: 自己和自己比回归（ui_static_test.sh 失败）
  killed    W39: vacation 区块丢失（ui_static_test.sh 失败）
  killed    W42: time 入口加回（ui_static_test.sh 失败）
  killed    W43a: 迁移备份丢失（migrate_test.sh 失败）
  killed    W43b: 新模型条目被重写（migrate_test.sh 失败）
  killed    N1: filter WEBURL 清理行回退（acceptance_test.sh 失败）
  killed    S1: nft 桩 handle 重用回归（acceptance_test.sh 失败）
  killed    B16: submitted 直接 format section 对象（ui_static_test.sh 失败）

被杀 39 / 存活 0 / 锚点失效 0
```

> 全量 39 个变异（15 既有 + 24 本轮新增/加固）**全部被检出**（含 S1、N1、B16、W37/38/39/42、W2..W7、W32、W43），
> **0 存活、0 锚点失效**。无摆设用例。

### A.3 逐条 W 复核（对照 testplan §2）

`run.sh` 全绿 + 变异**全量**命中 ⇒ 全部 W 复核 **PASS**（W 的落点/断言未削弱，删除行仍为空，与复审一致）：

| ID | 复核依据 | 结果 |
|---|---|---|
| W1–W2 | init_test / lint_ash（W2 变异 killed） | PASS |
| W3 | acceptance_test（变异 killed） | PASS |
| W4 | acceptance_test（W4/N1 变异 killed） | PASS |
| W5–W7 | acceptance_test（W5/W6/W7 变异 killed） | PASS |
| W8 | init_test | PASS |
| W9–W11 | acceptance_test（W9/W10/W11 变异 killed） | PASS |
| W12 | init_test | PASS |
| W13–W14 | acceptance_test（变异 killed） | PASS |
| W15 | init_test | PASS |
| W16–W17 | acceptance_test / init_test（变异 killed） | PASS |
| W18–W31 | init_test / common_test | PASS |
| W32 | acceptance_test（变异 killed） | PASS |
| W33–W36 | init_test / common_test | PASS |
| W37 | ui_static（变异 killed）+ init_test 数据侧 | PASS（静态，非行为级；行为级由 B10/R9） |
| W38 | ui_static（W38a/W38b/B16 变异 killed） | PASS（静态；行为级由 B16 真机） |
| W39 | ui_static（变异 killed） | PASS（静态；行为级由 B10/R9） |
| W40–W41 | run.sh / init_test | PASS |
| W42 | ui_static（变异 killed） | PASS（静态） |
| W43 | migrate_test（W43a/W43b 变异 killed） | PASS |

---

## B. 上线黑盒 B1..B17（真机）

> 安全协议：动手前装 deadman（`sleep N` 后 `cp 备份 + commit + reload`）；每次「装规则→观察→撤规则」
> 在**一条 bash** 内闭环；观察用 `curl --max-time`/`nc -w 3`；只加/删一个 `remarks='BBTEST-MAC'` 测试节，
> **绝不碰** `basic.*`、iPad 节（`remarks='iPad Pro'`）、protocol/time/quota/vacation、防火墙/网络/Clash。

| ID | 结果 | 证据（本 pane 实跑） |
|---|---|---|
| **B1** | **PASS** | `/etc/init.d/parentcontrol enabled`=yes；`iptables -t mangle -S` 有 `-N PARENTCONTROL_QUOTA`/`ACCT`；PREROUTING 顺序 `QUOTA`→`ACCT`；filter 表**无** PARENTCONTROL 链 |
| **B2** | **PASS** | 快照 → `reload`×3（rc=0,0,0）→ 再快照：v4 md5 `fff71581…` 前后**相同**、v6 `0e1f2719…` 相同；即使与 S1 基线 `cmp` **IDENTICAL**；`-A` 仍 72/54，**不堆叠** |
| **B3** | **PASS**（用户批准后补测） | 一条 bash 闭环 + deadman：**enabled=1** 时 mangle `PARENTCONTROL` 行=74（2×`-N`+72×`-A`）、filter=0、`-A` v4/v6=72/54；**enabled=0 + reload** → mangle `PARENTCONTROL`=**0**、filter=**0**、ip6 亦 0、`-A` v4/v6=**0/0**（A5）；**立刻 enabled=1 + reload** → 两链与 **72/54 全部回来**、PREROUTING 顺序 QUOTA→ACCT；收尾 `uci export` md5=`247c232f…`、iPad 节（mac/enable/domains/时段/额度）**原样** |
| **B4** | **PASS** | ①探针基线 REACHABLE；②加 `weburl` 节（`mac=<test-device-mac>`、`ip=<test-device-ip>`、`domains=<probe-ip>/32`、sd/hd 全天、`unlimited=0`、`quota=60`）→ commit+reload；③探针 **仍 REACHABLE**（`quota=60` 未耗尽 → A17② 放行；**封锁不由此用例承担**，符合修正后的期望）；④对照 `https://www.google.com` http=200（可达性，见 §0.1）；⑤ACCT 有 `-s <test-device-ip>/32 -d <probe-ip>/32 -j PCA_weburl_2`（+SNI/DNS 串规则），QUOTA **无 DROP**（符合「全天+未耗尽」语义），`ips/weburl_2` 内容恰为该探针；⑥删节 → md5 `247c232f…`、72/54 复原 |
| **B5** | **PASS** | 时段 `qstart=00:00:01 qend=00:00:02`（当前在时段外）→ QUOTA 出现 `-m time` 正向区间 DROP；探针 **BLOCKED**（`rc=28` 超时）；改回全天 → **REACHABLE**；删节复原 |
| **B6** | **PASS** | 全天 + `quota=0`、`unlimited=0` → QUOTA 出现**无条件** `-j DROP`（无 `-m time`）→ 探针 BLOCKED；删节 → REACHABLE |
| **B7** | **PASS** | 复 B4 节（`quota=1`），先 `reset_quota weburl_2` 归零 → 无 DROP、探针可达；对探针造流量（ACCT `-d <probe-ip>` 计数 1207 pkt / **68456 B**）；`tick` → `usage/20261004` 记 `weburl_2 1`、QUOTA 出现 6 条 DROP → 探针 **BLOCKED**；删节复原。⚠ **未**改 `basic.usage_min_kb`（S4 禁止碰 `basic.*`），改用 **68KB ≫ 默认 8KB 阈值** 触发采样，达成同等判据 |
| **B8** | **PASS** | 在封锁生效的同一 bash 内：`nc -w 3 <router-ip> 22` **OPEN**、`ssh_router 'echo ok'` 成功、`curl http://<router-ip>/` **200** → 封锁**未**断恢复通道（A27 LAN RETURN 生效） |
| **B9** | **PASS**（用户批准后补测） | 一条 bash 闭环 + deadman。只读：有受管条目时 `nft list chain inet fw4 forward` 的 `flow add` 数=**0**、`/tmp/pc_offload_state=disabled`、`-A` 72/54（A7）。**stop** → `meta l4proto { tcp, udp } flow add @ft` **回来**（count=1，A8）、`offload_state=on`、PARENTCONTROL=0、cron=0。**start** → flow-add 再次=**0**、`offload_state=disabled`、`-A` **72/54**（start 含 DNS 解析，构建有秒级延迟，采样已等稳）、iPad ipv4 规则行=**68**、cron=2、md5=`247c232f…`（A7 复现 + 过滤恢复） |
| **B10** | **PASS** | 登录后 GET：列表页 200（含「网址过滤列表/编辑/今日额度」）、使用限额页 200（含「使用限额」）、使用统计页 200（含「使用统计」）、状态接口 200 `{ "status": true }`；四处 **均无 `Runtime error`** |
| **B11** | **PASS** | 菜单仅 weburl/quota/stats/weburl_edit/status/reset_quota；`model/cbi/parentcontrol/` **无** `time.lua`/`protocol.lua`；controller 内 time/protocol 引用数 =0；列表页无「时间限制/协议过滤」 |
| **B12** | **PASS** | `holiday/` 有 `2025.json`+`2026.json`；`daytype=holiday`；日志 `build: day=holiday`；节流：`2026.json` ≤7 天（`-mtime +7` 未命中）→ 不重拉、`2027.stamp` 存在（24h 重试节流）。**说明**：数据源的 `2027.json` 实际为 `"days": []`（无 `"date"`）→ 插件按判据**正确地不落盘**次年文件，属外部数据未发布，非缺陷 |
| **B13** | **PASS** | `crontab -l` 有 `#pc_tick`（每分钟）+ `#pc_ip_refresh`（`*/30`）；`basic.ip_refresh=30`；`ips/` 按条目（`weburl_0`） |
| **B14** | **PASS** | 测试节只填 `ip=<test-device-ip>`（**不填 mac**）+ `quota=0` → QUOTA 有 `-s <test-device-ip>/32 … -j DROP`、**无** mac 规则（`grep mac` =0）→ 探针 BLOCKED；删节 → REACHABLE。**完整版**（静态 IP 命中同样生效 + DROP 规则存在） |
| **B15** | **PASS** | iPad 节本地 `09:00:00–21:00:00` → QUOTA 的 `-m time` UTC 段 = `[00:00:00–00:59:59] ∪ [13:00:01–15:59:59] ∪ [16:00:00–23:59:59]` = 除 `[01:00:00–13:00:00] UTC` 外全部 → 与 `本地−8h` 的时段外集合**逐段一致**；路由器系统时区 CST+0800，判定按 UTC+8 |
| **B16** | **PASS** | 部署修复版后，**浏览器（Playwright，真实表单）**：GET 编辑页 200、**无 Runtime error**；「起=止」(09:00:00/09:00:00) 保存并应用 → 字段被标 `cbi-value-error`、页面回显「可用起必须早于可用止」「可用止必须晚于可用起」、**配置 md5 不变**（被拒）；「起>止」(10:00:00/09:00:00) 同样被拒、md5 不变；「起<止」(09:00:00/21:00:00) → `sd_qstart=09:00:00`/`sd_qend=21:00:00` **落盘**、md5 由 `96e3b2…`→`ef5c6b80…`（仅测试节变化）；iPad 节编辑页 GET 也 200、无 Runtime error。**对照**：修复前（已安装旧构建）同 POST → **500**（`parts.lua:36 bad argument #2 … got table`） |
| **B17** | **PASS** | `/etc/parentcontrol/backup/` 有 **9** 个 `parentcontrol.*.bak`（含 `pre-deploy-*`）迁移备份 |

---

## C. 回归 R1..R10（testplan §4）

| ID | 结果 | 证据 |
|---|---|---|
| **R1** | **PASS** | `sh test/run.sh` → ALL SUITES PASS（见 §A.1） |
| **R2** | **PASS** | 变异**全量 39 个：39 killed / 0 survived / 0 锚点失效**（`sh test/mutation_check.sh`，EXIT=0） |
| **R3** | **PASS** | 注入式回归（`mutation_check` 在**临时副本**改坏源码）：**ash 语法**（W2）、**del_rule**（W4）、**无锁自愈**（W5）、**hotplug 恒假**（W7）四处旧缺陷回退后，对应套件**均 FAIL**（killed）；改回后全绿。未污染工作树 |
| **R4** | **PASS** | A7/A8 状态机由 **B9 真机 stop/start 闭环**直接验证（有受管条目 → `nft …forward` 的 `flow add`=0、`offload_state=disabled`；`stop` → `flow add @ft` 回来、`offload_state=on`；`start` → 再 `disabled`、`-A` 72/54、iPad 规则 68、无残留）；W9/W10 白盒兜底 |
| **R5** | **PASS** | `migrate_test.sh`（94 checks，含 W43：备份生成、二次迁移无新变化、新模型条目字段不动、老字段清干净）；真机 B17 备份产物在位。**未**在真机重跑迁移（避免改配置） |
| **R6** | **PASS** | 全部 BB 测试后：当前 mangle `-S` 与 S1 基线 **v4/v6 `cmp` IDENTICAL**；iPad MAC 规则行数 **68=68**；无 BBTEST 残留；md5/72/54 复原 → **新功能未污染在跑的 iPad 条目** |
| **R7** | **PASS** | 造封锁生效后：`PARENTCONTROL_QUOTA` 首条仍是 `-d <router-lan> -j RETURN`（第二条 `-d 127.0.0.0/8 -j RETURN`），**在任一 DROP 之前**（脚本判定 RETURN first） |
| **R8** | **PASS** | 真机 `ips/` 只有 iPad 的 `weburl_0`（含累积的 6 条 v4/v6 网段）；测试节删除后**无**遗留 `weburl_N` 文件（删除清理生效）；「只增不减」由 W15 覆盖 |
| **R9** | **PASS** | 见 B10（四页 200 + 中文标记 + 状态接口）；`stats_tsv` 列唯一解析由 run.sh 的 TSV 唯一性 lint + init_test 断言守住 |
| **R10** | **PASS** | 覆盖矩阵逐条回溯：A1..A46 每条至少一个 **PASS** 的 W 或 B（B3/B9 本轮已补测 PASS）；详情见 §D，**无空格** |

---

## D. 覆盖矩阵复核（R10）

- A1..A46 逐条：均有 PASS 的 W 和/或 B（见 §A.3 / §B）。B3（A5）与 B9（A7/A8）本轮已补测 **PASS**。矩阵**无空格**。
- A36（编辑页）：W38（静态）+ **B16（真机行为）** 双覆盖 → 本轮重点闭环。

---

## E. 收尾 S5 gate（恢复校验）

| 项 | 期望 | 实测 |
|---|---|---|
| `uci export parentcontrol` md5 | `247c232f…` | **`247c232f2a245ecd991999b31f7d55be`** ✓ |
| mangle `-A` 计数 | v4=72 / v6=54 | **72 / 54** ✓ |
| BBTEST 测试节 | 0 | **0** ✓ |
| iPad 节 | 原样 | `remarks='iPad Pro'`、`sd 09:00:00–21:00:00` **未变**（R6 亦证 mangle IDENTICAL）✓ |
| 探针 | 恢复可达 | `www.sogou.com`/`<probe-ip>` **REACHABLE** ✓ |
| deadman | 杀掉 | 进程 0（已 kill 并删 deadman 文件）✓ |
| 基线快照 | 保留 | 本轮重建并**保留** `/tmp/pc-bb-backup.uci`、`pc-bb-uci-export.txt`、`pc-bb-mangle*-before.txt`（4 份，export md5 与基线一致）✓ |
| LuCI 缓存 | — | 已清 `/tmp/luci-indexcache*`、`/tmp/luci-modulecache` ✓ |
| **B3/B9 补测后复核** | md5/72·54/iPad | B3（开关往返）、B9（停/启插件往返）后**再次复核**：md5=`247c232f…`、`-A` v4/v6=72/54、iPad 规则行 68、无 BBTEST、无 deadman ✓ |
| **中断轮遗留物** | 删除 | 已删 `/tmp/pc-deadman.sh`、`/tmp/pc-deadman.pid`、`/tmp/pc-c1-*.txt`；**保留** `/tmp/pc-lua-parts.orig` 与 `/tmp/pc-bb-*` 基线快照 ✓ |

---

## F. 未测 / SKIP / 失败汇总

- **变异**：**全量 39 个已跑**，**39 killed / 0 survived / 0 锚点失效**（无存活）。
- **SKIP**：**无**（B3/B9 已于本轮经用户批准补测并通过）。
- **不可观测（环境限制）**：境外/代理目标经路由器 mangle 的封锁不可观测（Clash TUN）；B4-④仅验证可达性。
- **失败**：**无**（无 FAIL，无 Blocker）。
- **部署决策（已定）**：已安装构建的 `parts.lua` 原为旧缺陷版；本轮按用户批准将工作树修复版部署并**保留**（§0.2），LuCI 与受测代码树一致。

---

TEST_PASS: 白盒 run.sh ALL SUITES PASS（common 76 / init 116 / acceptance 63 / migrate 94 + UI 静态 42 + 4 lint）；变异**全量 39 个**：39 killed / 0 survived / 0 锚点失效；黑盒 B1..B17 = **17 PASS + 0 SKIP**（B3/B9 本轮经用户批准补测 PASS）；回归 R1..R10 = 10 PASS；收尾 S5 gate 绿（uci md5=247c232f…、mangle 72/54、探针可达、iPad 原样、deadman 已杀、中断轮遗留物已清）。B16 真机 PASS（修复版 `parts.lua` 已部署并保留）。

---

## G. 2026-10-08 真机复测轮（受管设备 = 本机 macOS；条件 = 小红书）

- 角色：test pane（tester）真机执行；本机 macOS 作受管设备；只加/删 **一个** `remarks='BBTEST-MAC'` 测试节。
- 本轮目标（用户要求）：核实「仓库最新代码是否已部署」；跑完整黑盒矩阵；周期尽量短；**不碰 iPad 节 / 不碰网络配置**；网络必须能自动恢复（**不依赖 AI**）。
- 安全网：沿用 testplan §1 —— S1 备份 + **S2 deadman（`sleep N` 后自动回滚，实测扛得住 SSH 断开）** + **S3 单条 bash 内闭环（封锁期间不再发起 LLM 调用）** + S4 不碰 `basic.*`/iPad/protocol/time/quota/vacation/防火墙。

### G.1 部署核对（本轮要求 #1）

对本地 **28** 个受版本控制文件逐个 md5 与真机比对（`root/**` → `/…`；`luasrc/**` → `/usr/lib/lua/luci/…`）：

| 结果 | 文件 |
|---|---|
| **一致 26/28** | 其余全部（含 `luasrc/**` 全量） |
| 预期差异 1 | `/etc/config/parentcontrol`（仓库=包默认值；真机=线上实配置） |
| 缺失 1 | `/usr/share/ucitrack/luci-app-parentcontrol.json`（已装 ipk 早于该文件入库，见 F4） |

**本轮修正的部署落后**（此前均未部署到真机）：

- `/etc/init.d/parentcontrol`：真机旧版缺 `8041b64`（`del_rule` 未清 filter 表 `PARENTCONTROL_WEBURL`）→ **已部署**，md5 `221b9578…`；B2 复验 filter 表 WEBURL 残留 v4=0/v6=0（修复生效）。
- `/usr/lib/parentcontrol/common.sh`：真机旧版缺 `4cee533` 的 `PC_CONF_DIR`/`BACKUP_DIR` 可覆盖钩子（默认值=生产路径，**行为等价**）→ 已部署对齐，md5 `aee531d9…`。
- `luasrc/model/cbi/parentcontrol/parts.lua`：已是修复版（md5 `51b4e7ad…`，与仓库一致）。
- 部署后复验：config md5 `247c232f…`、mangle `-A` v4/v6 = 72/54、PREROUTING `QUOTA`→`ACCT`、iPad 规则 68 行、探针可达。

### G.2 白盒回归（R1/R2 重跑）

- `sh test/run.sh` → **ALL SUITES PASS**（末尾 `PASS (94 checks)`；4 个 lint + ui 静态 + common/init/acceptance/migrate）。
- `sh test/mutation_check.sh` → **killed 39 / survived 0 / 锚点失效 0**。

### G.3 黑盒 B1..B17（真机）

| ID | 结果 | 证据（本 pane 实跑） |
|---|---|---|
| B1 | PASS | 服务 enabled；`-N PARENTCONTROL_QUOTA`/`ACCT` 在位；PREROUTING 顺序 `QUOTA`→`ACCT`；filter 表无残留 |
| B2 | PASS | `reload`×3 全 rc=0；规则集合逐条 md5 前后一致；计数仍 72/54（**不堆叠**）；**filter 表 WEBURL 残留 v4=0/v6=0**（8041b64 生效） |
| B3 | **SKIP** | 高风险（关总开关会影响 iPad）→ 按 S7 默认跳过 |
| B4 | PASS | 加测试节（`mac`+`ip`、6 个小红书域名、全天、`quota=60`、`unlimited=0`）→ `reload` rc=0 → 探针**仍可达**（302）；该节 v4 ACCT 17 条均为 `-s <test-device-ip>/32`（ip 优先单条）；该节 QUOTA 0 条 DROP（未耗尽+全天 → A17② 正确）；**R6：iPad 规则前后 68/52 逐条一致** |
| B5 | PASS | `qstart=00:00:01 qend=00:00:02`（必在时段外）→ 该节 QUOTA 出现 `-m time` **正向区间** DROP（mac 51 + ip 51 条）→ 探针 **BLOCKED**（`HTTP=000 rc=28`） |
| B6 | PASS | 全天 + `quota=0` + `unlimited=0` → 该节 **无条件** `-j DROP`（17 ip + 17 mac = 34 条；QUOTA 53→87）→ 探针 **BLOCKED** |
| B7 | PASS | `quota=1`；`curl -4 -L` 造 **366 KB** 小红书流量 → 下一分钟 tick 采样记 `weburl_2` 1 分钟 → 额度耗尽 → 该节 DROP=17 → 探针 **BLOCKED** 并持续 |
| B8 | PASS | **封锁生效的同一条 bash 内**：SSH(22) 通、LuCI(80)=200 → **未断恢复通道**（A27 LAN RETURN 生效） |
| B9 | **SKIP** | 高风险（停用插件测 offload 恢复）→ 按 S7 默认跳过 |
| B10 | PASS | 登录后四页全 **HTTP=200** 且含中文关键词（家长控制/网址过滤/使用限额/使用统计） |
| B11 | PASS | controller 只有 `weburl`/`quota`/`stats` 三个叶子 → **无**「时间限制」「协议过滤」入口；仓库 `grep` 0 命中 |
| B12 | PASS | `holiday/2025.json`+`2026.json` 在位；日志 `build: day=school`、`refresh_ips: 6 条目标 IP` |
| B13 | PASS | crontab `#pc_tick`（每分钟）+ `#pc_ip_refresh`（`*/30`）；`ips/weburl_0` 存在 |
| B14 | PASS | 只填 `ip`（删 mac）+ `quota=0` → 该节 mac 规则=**0**、v4 ip 规则=17、v6 ip 规则=**0** → 探针 **BLOCKED** |
| B15 | PASS | 真机 `TZ=CST-8`；iPad `09:00–21:00` 换算出的 UTC `-m time` 段 == 本机 21:00:01–23:59:59，逐段一致 |
| B16 | PASS¹ | 已部署 `parts.lua` = 修复版（`51b4e7ad…`，与仓库一致）；校验逻辑（`起=止`/`起>止` → 拒绝）在 `parts.lua` 内且 W38a/B16 变异被检出。¹本轮 curl 复现 CBI 保存未走通（**合法值也未落盘** → harness 问题，非产品缺陷），行为级证据沿用上一轮**真实浏览器 POST**（同一 `parts.lua`） |
| B17 | PASS | `/etc/parentcontrol/backup/` 存在多份 `parentcontrol.<ts>.bak` |

> 计数口径：**一律用 `iptables -t mangle -S <链> | grep -c '^-A'`**（`grep -c PARENTCONTROL` 会多算 2 条 `-N`）。基线：v4=72 / v6=54 / QUOTA=53。

### G.4 本轮新发现

| # | 严重度 | 发现 | 证据 | 建议 |
|---|---|---|---|---|
| **F1** | 中 | **每分钟 tick 重建期间，配额/时段封锁链短暂清空** | 70s 紧密采样（7074 样本）中 **131 次异常**：`PARENTCONTROL_QUOTA` 由 53 → 最低 **0**，随后逐条爬回 53，过程持续 **~1.3 s**；B7 亦观测到一次「DROP=17 但探针 302」 | `build_quota_blocks` 先 `-F $TAGQ` 再逐条重建；窗口内**所有**条目（含 iPad 的 51 条时段/额度 DROP）短暂失效（≈每分钟 2% 时间）。建议：先算出规则集，**与当前链一致则跳过重建**（多数 tick 规则不变），或构建临时链再替换 |
| **F2** | 中 | **条目填了静态 `ip` 时，IPv6 流量不计入额度** | 测试节（`mac`+`ip`）：v4 ACCT 17 条 / **v6 ACCT 0 条**；对照 iPad 节（**仅 mac**，无 `ip`）：v6 ACCT **13 条** | `devcount()` 为「ip 优先单条」，`add_dev_rule_single()` 把 `-s <v4>` 也插进 `ip6tables`，语句非法 → `2>/dev/null` 静默失败 → v6 计数规则缺失。**用 IPv6 访问小红书不会被计额度**。建议：`add_dev_rule_single` 按 `$1` 选身份——v6 链在 `ip` 非 v6 时回退到 mac 条件（同族内不会重复计数） |
| **F3** | 低 | IPv6 配额链**没有**「放行局域网网段」守卫 | `ip6tables -S PARENTCONTROL_QUOTA` 首条即 DROP；v4 首条为 `-d <router-lan> -j RETURN` | `pc_lan_nets()` 只产出 IPv4 CIDR → 对 ip6tables 的插入静默失败。当前所有 v6 封锁规则均带 `-s`/`-m mac` 源约束，**未造成自锁**；属潜在不对称 |
| **F4** | 低 | 已装 ipk 缺 `ucitrack` 描述文件 | `/usr/share/ucitrack/luci-app-parentcontrol.json` 缺失（仓库有） | 已装包早于该文件入库；需**重建并重装 ipk** 才能覆盖（手工补文件亦可） |

### G.5 收尾 gate（S5）

| 项 | 期望 | 实测 |
|---|---|---|
| `uci export parentcontrol` md5 | `247c232f…` | `247c232f2a245ecd991999b31f7d55be` ✓ |
| mangle `-A` | v4=72 / v6=54 | 72 / 54 ✓ |
| 测试节 | 0 | 0（weburl 节数 = 2）✓ |
| 测试节残留规则 | 0 | v4=0 / v6=0 ✓ |
| QUOTA 链首 | LAN RETURN | `-A PARENTCONTROL_QUOTA -d <router-lan> -j RETURN` ✓ |
| iPad 节 | 不变 | 规则 68 行；前后逐条一致（R6）✓ |
| cron 条目 | 2 | 2 ✓ |
| 探针 | 恢复可达 | 小红书 302 / 百度 200 ✓ |
| deadman | 已杀 | 已 kill 并删文件 ✓ |
| 临时文件 | 清理 | 已删本轮临时目录/脚本 ✓ |

### G.6 未测 / SKIP（本轮）

- **B3 / B9**：**SKIP**（高风险，按 S7 默认跳过；本轮未单独批准）。
- 真机迁移（R5）、nft offload 真机往返（R4/B9）本轮未重跑。
- 隐私：本报告**不含**口令/真机 MAC/IP 字面量（占位符 `<test-device-mac>` / `<test-device-ip>` / `<router-ip>` / `<router-lan>`）。

### G.7 本轮结论

**真机复测：13 PASS / 2 SKIP(高风险默认跳过) / 0 FAIL；白盒 R1/R2 全绿；S5 gate 全绿。**
部署核对发现 **2 个生产文件落后**（已按用户授权部署对齐），新增 **4 项发现**（F1/F2 中、F3/F4 低），均**未**影响本轮既有功能判定。

---

## H. 2026-10-08 F1/F2 修复轮（实现 + 白盒 + 真机复测）

- 触发：§G.4 的 **F1/F2** 两项「中」等级发现 —— 按用户要求「只发现 bug 就改自己的内容」。
- 范围：只改本仓库自身的 `root/etc/init.d/parentcontrol` 与测试；**未**触碰任何其它组件（passwall / 防火墙 / 网络 / `basic.*` / iPad 节 / protocol / time / quota / vacation）。

### H.1 修复实现（`root/etc/init.d/parentcontrol`，md5 `2b2af5db606b872eabdfc7f0515ed860`）

| 项 | 改法 |
|---|---|
| **F1（封锁空窗）** | 抽出 `render_quota_spec()`（离屏渲染，`PC_RENDER` 只记录不碰内核）+ `_quota_emit_rules()`；`build_quota_blocks()` 先算 `_spec`，再比 `quotaspec` 快照与 `spec_rule_counts()`/`live_rule_count()` 两族条数：**规则集与链内条数都没变 → 直接 `return 0`，一个 iptables 都不动**；不一致才 `ensure_chain`+`-F`+重建+写快照。失败方向安全（指纹对不上就照旧全量重建）。 |
| **F2（v6 不计数）** | 新增 `addr_is_family <addr> <is_v6>`；`devcount()` 改 `($ipcmd $module $idx)`：`-s` 仅在地址与协议族相符时使用，不符则**回退 MAC**；`add_dev_rule_single()` 收到空条件即 return（不再往 ip6tables 插 IPv4）。 |
| **F2′（只填 v4 ip）** | `add_dev_rules()` 用 `addr_is_family` 过滤静态 IP，并把「无条件 DROP」退化分支收紧为 `[ "$_n" = 0 ] && [ -z "$_mac" ] && [ -z "$_ip" ]`，**族不匹配时绝不再发无源约束 DROP**。 |
| **附带** | 规则下发统一走 `ipt_do()`（唯一出口，便于测试与审计）；`allow_lan_in()` 加 `addr_is_family` 守卫。 |
| **F3 有意不修** | v6 配额链仍无 LAN RETURN 守卫（`pc_lan_nets()` 只产 IPv4）。用户明确「不要擅自添加路由表之类的东西」→ 不新增规则类别，仅记录。 |

设计取舍：放弃「临时链 `-E` 重命名」（fake 不支持 `-E`）与「先建后删」（按序号 `-D` 会打乱 DROP/RETURN 次序、有自锁风险），改用**「规格未变则不动内核」**。

### H.2 白盒（R1/R2 复跑 + 新增用例）

| 套件 | 结果 |
|---|---|
| `test/acceptance_test.sh` | 新增 **10 条断言**：F1 4 条（耗尽→2 条 DROP；`setcounters` 4242 后重跑**不重建、计数保留**；外部 `-F` 清空；再跑**自愈重建**回 2 条）、F2 4 条（v4 用 `-s`/无 mac、v6 回退 `--mac-source`/不含 IPv4 源）、F2′ 2 条（只填 v4 ip → v6 计数/封锁链**各 0 条**）→ `PASS (73 checks)` |
| `test/mutation_check.sh` | W32 锚点更新到新 `devcount` 两行；新增 4 条变异（F1 全量重建回归、F1 不校验链内条数、F2 不做族过滤、F2 族不匹配错发无条件规则）→ **killed 43 / survived 0 / 锚点失效 0** |
| `sh test/run.sh` | **ALL SUITES PASS**（末尾 `PASS (94 checks)` 是 `migrate_test.sh` 自身计数，非总数） |

### H.3 真机部署与 F1/F2 线上验证（20:05–20:18，跑的是修复版）

- **F1 空窗对比**：修复前同法 70s 紧密采样 = **7074 样本 / 131 次异常 / QUOTA 最低 0**；修复后 75s = **4720 样本 / 0 异常 / v4 最低 53、v6 最低 39**（全程未跌破）。
- **F1 自愈**：外部 `iptables -t mangle -F PARENTCONTROL_QUOTA` → 0 条 → **9 秒后下一 tick 自动重建回 53 条**（`SELF_HEAL_OK`）。
- **F2**：测试节（`mac`+`ip`）→ v4 ACCT **17 条，全部 `-s <test-device-ip>/32`、无 `--mac-source`**；v6 ACCT **13 条，全部 `--mac-source <test-device-mac>`、含 IPv4 源 0 条**。修复生效。
- **封锁机制澄清**（此前误判为「DROP=0」）：封锁 DROP 是**内联规则**（不含条目链名），所以 `grep PCA_weburl_N` 在 QUOTA 链里为 0。实测 `mac`+`ip` 条目会**同时**下发 ip 域（`-s <test-device-ip>/32`）与 mac 域（`--mac-source`）两条 DROP，另加解析出的 `-d <cidr>` DROP；该节封锁时 QUOTA v4 53 → **87 条**。

### H.4 黑盒复测（含 §G.6 的两个 SKIP 项）

| ID | 结果 | 证据 |
|---|---|---|
| **B3** | **PASS**（本轮已获批准执行） | `basic.enabled=0` + restart → `PARENTCONTROL` 规则 **v4/v6 = 0/0** → 探针 **可达**（302/200）；恢复 `enabled=1` → 规则 125/82 回归 |
| **B9** | **PASS** | 运行中：规则 125、nft `flow add @ft` **不存在**、`/tmp/pc_offload_state=disabled`；`stop` → 规则 0、`flow add @ft` **回来**、state=`on`、探针**可达**；`start` → 规则 125、`flow add` 再删、state=`disabled`、探针**再次被封锁** |
| B2 | PASS（还原后复跑） | `reload`×3 计数稳定 74/56（=`grep -c PARENTCONTROL` 口径，含 2 条 `-N`；`-A` 口径 72/54），QUOTA 53/39 不增 |
| B5/B6/B7/B14 | PASS | 均**在修复版上**复测：B5 时段外 → 探针 BLOCKED（`000/rc28`）；B6 `quota=0` → BLOCKED；B7 `quota=1` + 150s 真实小红书流量 → BLOCKED 且该节 DROP 在位；B14 只填 ip → v4 17 条 `-s`、v6 **0 条**、BLOCKED |
| B8 | PASS | 上述每一次封锁的**同一条 bash** 内：SSH(22) 通、LuCI(80) 应答 → 未断恢复通道 |
| B10 | PASS | 以 `luci_username/luci_password` 登录取会话（302）后，四页全 **HTTP=200** 且含中文（家长控制/网址过滤/使用限额/使用统计）；「时间限制/协议过滤」0 命中 |
| B12/B13/B15/B16/B17 | PASS | holiday `2025.json`+`2026.json` 在位（另有 `2027.stamp`）；cron `#pc_tick`(每分钟)+`#pc_ip_refresh`(每 30 分)；`TZ=CST-8`；`parts.lua M.validate_window` 对 `起>=止` 返回错误；`/etc/parentcontrol/backup/parentcontrol.<ts>.bak` 多份在位 |

### H.5 事故与如实记录

1. **S2 deadman 按设计触发（20:18:57）**：测试比预期长，600s 兜底到点后把 `/etc/init.d/parentcontrol` 还原为修复前版本 `221b9578…`、配置还原为基线。→ **测试窗口内跑的是修复版；收尾时安全网自动回到修复前版本。** 所有 F1/F2/B3–B9/B14 证据取自修复版窗口（20:05–20:18）；B2/B10 与 gate 在还原后复跑（B2「不堆叠」在修复版上只会更严格：规格未变时根本不重建）。
2. **我误把 `/tmp/parentcontrol`（插件的 STATE **目录**）当文件**：先 scp 失败，又误 `mv` 走，下一 tick 用 `mkdir -p` 重建。已清残留；iPad 节当日用量未受实际影响（`base.weburl_0` 已为 0）。**今后写临时文件一律避开该路径。**
3. **我误杀了 passwall 的 3 个 `sleep` 子进程**（`tasks.sh` / `monitor.sh` / `lease2hosts.sh` 各一）。它们是 `while …; sleep N; done` 循环，被杀后立即进入下一轮并重新 sleep，**无副作用**（已确认三者仍在运行、并未改动其任何配置）。

### H.6 收尾 gate（S5，还原后复验）

| 项 | 期望 | 实测 |
|---|---|---|
| `uci export parentcontrol` md5 | `247c232f…` | `247c232f2a245ecd991999b31f7d55be` ✓ |
| mangle `-A` | v4=72 / v6=54 | 72 / 54 ✓ |
| QUOTA `-A` | 53 / 39 | 53 / 39 ✓ |
| PREROUTING | `QUOTA`→`ACCT` | 顺序正确 ✓ |
| 测试节 | 0 | `BBTEST` 0 条，weburl 节 = 2 ✓ |
| 服务 | enabled | enabled ✓ |
| iPad 节 | 不变 | md5 = 基线即证明字节未变 ✓ |
| cron | 2 | `#pc_tick` + `#pc_ip_refresh` ✓ |
| 探针 | 恢复可达 | 小红书 200 / 百度 200 ✓ |
| deadman | 无残留 | 已触发并清理；`/tmp/pc-*` 全清 ✓ |

### H.7 本轮结论与未决

- 白盒：`ALL SUITES PASS`；变异 **killed 43 / survived 0 / 锚点失效 0**；新增 F1/F2/F2′ 共 10 条回归断言。
- 真机：**B1–B17 全部 PASS（0 FAIL / 0 SKIP）**；S5 gate 全绿；周期 ≈ 15 分钟。
- **仓库 vs 真机**：经用户批准已**部署一致** —— `/etc/init.d/parentcontrol` 真机 = 仓库 = `2b2af5db606b872eabdfc7f0515ed860`（详见 §H.8）。
- 未决：F4（缺 `ucitrack` json）需**重建并重装 ipk**；F3 **有意不修**。

### H.8 修复版部署与线上复验（20:30–20:32，用户批准）

用户批准「部署并复验」。全程遵守 testplan §1 的 S1–S7：

| 步骤 | 动作 | 结果 |
|---|---|---|
| S1 备份 | `/tmp/pc-initd-orig`(=`221b9578…`) + `/tmp/pc-bb-backup.uci` + `uci export` + mangle v4/v6 快照 | 完成 |
| S2 deadman | `/tmp/pc-deadman.sh`：`sleep 600` → 还原 init.d + `uci revert` + 还原 config + restart + 写 `/tmp/pc-deadman-fired`；`start-stop-daemon -S -b -m -p /tmp/pc-deadman.pid` 启动 | `DEADMAN_RUNNING pid=8707` |
| S3 部署 | scp → `/tmp/pc-initd-f12`（md5 `2b2af5db…` 一致）→ `cp` 覆盖 + `chmod +x` + `restart` | `restart rc=0` |
| S4 不碰 | 未改 `basic.*` / iPad 节 / 协议族 / 防火墙 / 网络 / passwall；未加测试节 | 符合 |
| S5 gate | init.d md5 `2b2af5db…`；config md5 `247c232f…`（基线）；mangle `-A` 72/54；QUOTA `-A` 53/39；PREROUTING `QUOTA`→`ACCT`；`enabled=1`；`BBTEST` 0；weburl 节 2；`quotaspec` md5 `03ead983b4376c93f1563806ec9d404e`（19859B） | 全绿 |
| iPad 完整性 | 部署前后按 iPad MAC 过滤的 mangle 规则 md5：v4 `4de4df07…`→`4de4df07…`（68 条）、v6 `3f2ab84d…`→`3f2ab84d…` | **字节级未变** |
| 探针 | 小红书 v4 `200/rc0`、百度 v4 `200`、小红书 v6 `200/rc0`、SSH22 OK、LuCI `403`（无 cookie 正常） | 网络正常、未自锁 |
| F1 线上复验 | 55 秒紧采 QUOTA v4：**0 异常 / 最低 53**；v6 15 秒：**0 异常 / 最低 39** | 修复在真机生效 |
| S6 预算 | 部署 + 复验 ≈ 2 分钟 | 符合 |
| S7 高风险 | 本轮无需（未关总开关、未停插件） | 符合 |

收尾：`kill` deadman（`DEADMAN_KILLED pid=8707`；pid 已 GONE、脚本已删、`/tmp/pc-deadman-fired` **未**生成，即未发生回滚）→ 清理 `/tmp/pc-*`（含我方孤儿 `sleep 600` pid 8709）→ **最终状态**：init.d `2b2af5db…`、config `247c232f…`、mangle 72/54、QUOTA 53/39、`BBTEST` 0、weburl 节 2。**真机现已与仓库 `7719d8e` 完全一致。**

---

## I. 2026-10-08 发布轮（1.8.0-20261008 打包安装 + B16 真浏览器验证 + F4 修复 + F5 新发现）

用户指令（m00693）：「做到底呀，黑白盒都通过了吗，通过就发布新版本到路由器呀」。本轮把 F1/F2 修复**打成 ipk 并安装到真机**（版本从 `1.7.1` → `1.8.0-20261008`），顺带修复 F4；并用**真实浏览器**补做此前只做了代码级核对的 B16。

### I.1 版本与打包

- `Makefile`：`PKG_RELEASE` 由 `20261002` → `20261008`（commit `301f22d`）；`PKG_VERSION` 原本已是 `1.8.0`（**高于真机装的 1.7.1**）。tag `v1.8.0` 已推（`334492f` → commit `301f22d`）。
- **GitHub Actions 未跑**：本仓库（`neohob/…`）的 Actions 从未产生任何 run（`actions/runs` `total_count` 恒为 0，多次重推 tag 亦然）；`actions/permissions.enabled=true`、workflow `state=active`，但本仓库需网页端手动 Enabled，且 release 步骤缺 `contents: write`。`gh workflow run` 因 `remote.upstream.gh-resolved=base` 打到 upstream 远端而 403。**→ 本轮改为本地手工组包。**（教训：本仓库用 `gh` 必须显式 `-R neohob/luci-app-parentcontrol`。）
- **★ipk 格式根因**：OpenWrt 的 `.ipk` 是 **`gzip` 压缩的 `tar`**，**不是 `ar` 归档**。用 macOS `ar rc` 组出来的包被 opkg-lede（`d038e5b6…`, 2022-02-24）报 `pkg_init_from_file: Malformed package file`。官方源同款对照证实：参考 ipk 前 16 字节 = gzip 魔数 `037 213 \b`，`gzip -dc | tar tf -` → `./debian-binary`、`./data.tar.gz`、`./control.tar.gz`。正确组包：
  ```
  COPYFILE_DISABLE=1 tar --format=ustar --no-xattrs --owner=0 --group=0 --numeric-owner \
    -czf luci-app-parentcontrol_1.8.0-20261008_all.ipk \
    ./debian-binary ./data.tar.gz ./control.tar.gz
  ```
  → 42577 B，md5 `7118e3dfb1fc876a45307122d2209b06`；`opkg install --noaction` 预检 → `Upgrading … from 1.7.1 to 1.8.0-20261008...` rc=0。
- 包内容自检：`cp -a root/. stage/` + `cp -a luasrc/. stage/usr/lib/lua/luci/`，28 个文件与仓库 md5 逐一对上，权限正确（仅 `etc/init.d/parentcontrol`=755），无 AppleDouble `._` 文件。

### I.2 安装与逐文件校验

- `opkg install /tmp/pc-new.ipk` **rc=0**；`Version: 1.8.0-20261008`、`Status: install user installed`。
- **conffile 正确保留**：`uci export parentcontrol | md5sum` = `247c232f2a245ecd991999b31f7d55be` **未变**；`/etc/config/parentcontrol` raw md5 `0d7609d2264932ca03a55ecbb5747158` **未变**。（opkg 另存包默认值到 `/etc/config/parentcontrol-opkg`，为 opkg 常规行为。）
- **`/usr/share/ucitrack/luci-app-parentcontrol.json` 已存在（57 B）→ F4 修复** ✓（此前真机缺失的唯一一个包内文件）。
- `/usr/lib/opkg/info/luci-app-parentcontrol.list` = **28 条**；`protocol.lua`/`time.lua`（1.7.1 包里的废弃文件）已从清单移除。
- 逐文件 md5：**26/28 一致**；2 处 DIFF 均为正确行为 —— `/etc/config/parentcontrol`（conffile 保留，线上 ≠ 包默认 `e86ea604…`）+ `/etc/uci-defaults/luci-app-parentcontrol`（`default_postinst` 跑完自删，故真机已无此文件）。
- opkg 输出的 "Collected errors" 均良性：`remove_obsolesced_files: unlinking …/protocol.lua|time.lua failed: No such file or directory`、`Failed to determine obsolete files from previously installed`、`resolve_conffiles: … new conffile will be placed at /etc/config/parentcontrol-opkg`（均为预期）。
- 安装后日志（21:21:44–51）= 安装触发的重建：`offload: restored` ×2 → `refresh_ips: 6 条目标 IP` → `build: day=school` → `offload: disabled` → `offload: purged conntrack for managed hosts`。

### I.3 B16 真浏览器「保存并应用」— PASS（决定性证据：请求轨迹）

此前 B16-c 只用 curl 单发一个 CBI POST，未落盘；本轮用 Playwright 驱动真实浏览器，抓到 LuCI 的**完整落盘序列**：

```
GET  /cgi-bin/luci/admin/control/parentcontrol/weburl_edit/<SID>
POST /cgi-bin/luci/admin/control/parentcontrol/weburl_edit/<SID>     ← CBI 表单（暂存进 ubus uci session）
POST /cgi-bin/luci/admin/uci/apply_rollback?<ts>                     ← 真正 commit + apply（带回滚计时）
POST /cgi-bin/luci/admin/uci/confirm?<ts>                            ← 确认，撤销回滚计时
GET  …/weburl_edit/<SID>                                             ← 回到编辑页（显示已保存值）
```

→ **`/www/luci-static/resources/ui.js` 的客户端逻辑是两次请求**：`request.request(L.url('admin/uci', checked ? 'apply_rollback' : 'apply_unchecked'), {method:'post', query:{sid:L.env.sessionid, token:L.env.token}})`。所以**「保存并应用」是 `CBI POST` + `admin/uci/apply_*` 两段**；此前 curl 只做了第①段 → 不落盘，**不是产品 bug**（已用二段式 curl 复现并落盘成功，见上轮记录）。

**验证（填 `sd_qstart=07:30:00`、`sd_qend=23:15:00`、`sd_quota=37`）**：三种视图一致落盘 —— `uci -q get`（CLI）、`ubus call uci get`、`/etc/config/parentcontrol` 原文行；`md5 28ae7342459a02bc636064c9ac2dbc14`；`uci changes parentcontrol` 与 `ubus call uci changes` 均空（apply+confirm 干净完成，无遗留 delta）；服务按新值重建（`refresh_ips: 9 条目标 IP`，由 6 增至 9）；**iPad 节与 iPad 规则 md5 逐字节未变**。

> 注意：LuCI 底部按钮是 `<input type="button" onclick="cbi_submit(this,'cbi.apply')" />`（「保存并应用」），确认框文案「要应用未保存的更改吗？否则它们将在 [秒] 内回滚」对应 `apply_rollback` 的回滚计时。

### I.4 ★新发现 F5（真实缺陷）：命名 section 被静默忽略

**症状**：用 `config weburl 'kids'`（**命名**段）形式的条目会被**完全跳过** —— 不下发任何规则、不计任何用量、不执行配额，且**无任何报错**。

**根因**（`root/usr/lib/parentcontrol/common.sh:18-30`）：

```sh
pc_ids_all() { uci show "$PC_CONF" 2>/dev/null | sed -n "s/^${PC_CONF}\.@$1\[\([0-9][0-9]*\)\]\..*=.*/\1/p" | sort -un; }
pc_ids_on()  { uci show "$PC_CONF" 2>/dev/null | sed -n "s/^${PC_CONF}\.@$1\[\([0-9][0-9]*\)\]\.enable='1'$/\1/p" | sort -un; }
```

这两个函数**只匹配匿名段的 `parentcontrol.@weburl[N].field=…` 形式**。命名段在 `uci show` 里输出为 `parentcontrol.BBTEST=weburl` / `parentcontrol.BBTEST.remarks='…'` → 正则永不命中。

**决定性 A/B 实验**（同内容、仅匿名 vs 命名）：

| 形态 | mangle `-A` | QUOTA `-A` | ACCT `-A` | 本机 Mac 规则 |
|---|---|---|---|---|
| **命名段** `uci set parentcontrol.BBTEST=weburl` | **72/54（不变）** | **53/39（不变）** | **17/13（不变）** | **0** |
| **匿名段** `uci add parentcontrol weburl` | 100/66 | 77/48 | 21/16 | v4 mac 12 条 + v4 ip 16 条 |

**uci 侧证据**：`@weburl[N]` **对命名段同样编号**（`uci -q get parentcontrol.@weburl[2].remarks` → 段值可读），说明数据完全可寻址，坏的只是 ID 枚举；`sed` 在 `uci show` 上命中 `0 1`（只两个匿名段），根本不含命名段。

**影响与严重性**：用户直接编辑 `/etc/config/parentcontrol`（或配置管理工具、备份还原）写命名段会**静默失效** —— 家长以为在管控，实际完全放行。**失效方向是「不安全」**（漏管，不是误封）。LuCI 界面自己只创建匿名段，故正常 UI 路径不触发。另注：`weburl_macs_all()`/`weburl_ips_all()`（`/etc/init.d/parentcontrol:276-282`，当时用 `uci show | grep weburl | grep '\.mac='`）**同样漏掉命名段** —— 命名段的行为 `parentcontrol.kids.mac='…'`，整行不含 "weburl" 子串（**此处初版报告写反了，特此更正**）；两处同源缺陷，均已在 §J 一并修掉。

**修复思路（已于 §J 实施）**：
```sh
# 枚举改为按 uci show 中该 type 的出现序号产出 0 基下标，与 @type[N] 编号一致
pc_ids_on() { for _i in $(pc_ids_all "$1"); do [ "$(pc_uget "@$1[$_i].enable")" = "1" ] && echo "$_i"; done; }
```
并让 `pc_ids_all` 接受排名下标而非只认 `@type[N]` 文本。附带收益：`pc_ids_on` 不再依赖 `enable='1'` 的引号字面量。
最终实现见 §J.1（`pc_uci_scan` 一次规范化扫描，匿名节用 uci 打印的位置下标、命名节用「已见同类型节数」补位）。

### I.5 ★运维隐患：rpcd 的 uci 内存缓存（影响「不依赖 AI 自恢复」设计）

**`/sbin/rpcd` 就是 uci 的 ubus 后端**（`ubus -v list uci` 暴露 `get/state/add/set/delete/rename/order/changes/revert/commit/apply/confirm/rollback/reload_config`）。**rpcd 在内存中缓存 uci 配置；用 `cp` 直接覆盖 `/etc/config/*` 不会刷新该缓存；此后任何 ubus `commit` 会把陈旧快照写回文件，覆盖掉外部还原。**

**实证**：本轮 deadman 用 `cp` 还原了基线，但上一轮 curl 会话残留在 rpcd 缓存中的 `08:15:00/22:45:00/42` 于 21:31 被浏览器的 CBI POST 触发 flush 回文件（这正是「列表页第三段值莫名变回上一轮的值、段名从 `cfg0a5076` 变 `cfg095076`」之谜的根因；`cfgXXXXXX` 是**内容派生名**，内容变则名变）。

**加固办法（必须）**：任何文件级还原之后执行 `ubus call uci reload_config`。**教训：在 OpenWrt 上用 `cp` 还原配置不算完成，必须让 rpcd 同步。** 此结论已影响 deadman 设计（§S2 应补此步）。

### I.6 收尾 S5 gate（14 项全绿，两次测量间隔 25 s 稳定）

| # | 项 | 值 | 结果 |
|---|---|---|---|
| 1 | `uci export parentcontrol` md5 | `247c232f2a245ecd991999b31f7d55be` | ✅ 回到基线 |
| 2 | `/etc/config/parentcontrol` raw md5 | `0d7609d2264932ca03a55ecbb5747158` | ✅ |
| 3 | mangle `-A` v4/v6 | 72 / 54 | ✅ |
| 4 | QUOTA `-A` v4/v6（ACCT） | 53 / 39（17 / 13） | ✅ |
| 5 | PREROUTING 顺序 | `PARENTCONTROL_QUOTA` → `PARENTCONTROL_ACCT` | ✅ |
| 6 | weburl 段数 / BBTEST 残留 | 2 / 0 | ✅ |
| 7–8 | iPad 规则 md5 v4/v6 | `4de4df07…`(68) / `3f2ab84d…`(52) | ✅ 逐字节不变 |
| 9 | 测试机规则残留 | 0 / 0 | ✅ |
| 10 | 服务 enabled | yes | ✅ |
| 11 | cron 条目 | 2（`#pc_tick` + `#pc_ip_refresh`） | ✅ |
| 12 | `ucitrack` json | 57 B（F4 已修） | ✅ |
| 13 | 包版本 | `1.8.0-20261008` | ✅ |
| 14 | 探针 小红书 / 百度 | 301 / 200 | ✅ 网络正常 |

`/tmp/parentcontrol/quotaspec` md5 `03ead983b4376c93f1563806ec9d404e`（19859 B）与上一轮部署态**完全一致**。清理：精确 kill 我方 3 个孤儿 `sleep`（pid 6655/14325/17687，**ppid 均为 1**），**保留** passwall 的 sleep（父进程为 passwall 脚本）—— 教训：**绝不用 pkill 盲杀 sleep，必须按 ppid 甄别**；删除 `/tmp/pc-*`、`/tmp/pcd*`（20 个 Oct 2–3 部署暂存目录），**保留** `/tmp/pc_offload_state`（服务运行时文件）；`/tmp` 现 12.7 M / 3.8 G。

### I.7 本轮结论与未决

- **黑盒**：B1–B17 全 PASS（含本轮用真实浏览器补齐的 **B16**，三段式落盘已证）。
- **白盒**：`sh test/run.sh` → `ALL SUITES PASS`；变异全量 **killed 43 / survived 0 / 锚点失效 0**。
- **发布**：`luci-app-parentcontrol_1.8.0-20261008_all.ipk` 已装到真机并逐文件校验（升级 `1.7.1 → 1.8.0-20261008`，conffile 与规则字节级不变，**F4 修复**）。
- **新发现 F5（未修）**：命名 section 被静默忽略 → **建议修**（失效方向不安全；修复局部、风险低）。
- **F3（未修，有意）**：v6 配额链无 LAN 守卫（`pc_lan_nets` 只产 IPv4）；因用户约束「不要擅自手动添加路由表之类的东西」而不新增规则类别。
- **运维加固（已记录）**：文件级还原后必须 `ubus call uci reload_config`（§I.5）。


---

## §J 2026-10-08 F5 修复轮（版本 1.8.1-20261008）

用户决策：F5 选「立即修，出 1.8.1」。本轮把 §I.4 记录的 F5（命名 section 被静默忽略）修掉，白盒 + 变异 + 打包 + 真机复验全程走完。

### J.1 修复实现：`pc_uci_scan` 一次规范化扫描

**根因回顾**：`pc_ids_all`/`pc_ids_on` 用 sed 只匹配 `parentcontrol.@weburl[N].field=` 形式，命名段（`parentcontrol.kids=weburl` / `parentcontrol.kids.mac='…'`）永不命中 → 该条目被整条链路跳过（不下规则、不计数、不配额，且不报错）。

**真机实测的下标口径**（`uci -c /tmp/ucitest` 沙箱，配置 = 匿名 anon0 / 命名 kids / 匿名 anon2）：

```
parentcontrol.@weburl[0]=weburl      # anon0
parentcontrol.kids=weburl            # 命名段
parentcontrol.@weburl[2]=weburl      # anon2（第 2 个匿名段打印 [2]，不是 [1]）
```

`uci get parentcontrol.@weburl[1].remarks` → `named1`。**结论：命名段在 `@type[N]` 下标空间里同样占位；匿名段打印的 N 就是真实位置下标。**

**实现**（`root/usr/lib/parentcontrol/common.sh`）：把三个枚举助手改为共用一次扫描，输出 `类型|下标|字段|值`：

```sh
pc_uci_scan() {   # uci show → `类型|下标|字段|值`（节行 = `类型|下标||类型`）
    uci show "$PC_CONF" 2>/dev/null | awk -F= -v c="$PC_CONF" '
        {
            k = $1
            if (index(k, c ".") != 1) next
            k = substr(k, length(c) + 2)
            if (k == "") next
            v = $2; gsub(/\047/, "", v); gsub(/"/, "", v)
            is_sec = 0
            if (index(k, "@") == 1) {                 # 匿名节地址 @type[N][.opt]
                p = index(k, "]"); if (p == 0) next
                addr = substr(k, 1, p); opt = ""
                if (p < length(k)) {
                    if (substr(k, p + 1, 1) != ".") next
                    opt = substr(k, p + 2)
                }
                typ = substr(addr, 2, index(addr, "[") - 2)
                idx = substr(addr, index(addr, "[") + 1); sub(/\]$/, "", idx)
                if (opt == "") is_sec = 1
            } else {                                   # 命名节 addr[.opt]
                q = index(k, ".")
                addr = (q == 0) ? k : substr(k, 1, q - 1)
                opt  = (q == 0) ? "" : substr(k, q + 1)
                if (opt == "") { is_sec = 1; typ = v; idx = cnt[typ] + 0 }
                else { typ = name2typ[addr]; idx = idx_of[addr] }
            }
            if (typ == "") next
            if (is_sec) {
                cnt[typ]++
                if (index(k, "@") != 1) { name2typ[addr] = typ; idx_of[addr] = idx }
            }
            print typ "|" idx "|" opt "|" v
        }'
}
pc_ids_all()  { pc_uci_scan | awk -F'|' -v t="$1" '$1 == t { print $2 }' | sort -un; }
pc_ids_on()   { pc_uci_scan | awk -F'|' -v t="$1" '$1 == t && $3 == "enable" && $4 == "1" { print $2 }' | sort -un; }
pc_opts_all() { pc_uci_scan | awk -F'|' -v t="$1" -v o="$2" '$1 == t && $3 == o && $4 != "" { print $4 }' | sort -u; }
```

**三处关键取舍**：
1. **匿名节用 uci 打印的位置下标**（权威），**命名节用「已见同类型节数」**补位 —— 两者落在同一个下标空间，与真机一致。
2. **保留老行为**：匿名节的**选项行**即使没有对应节行也能取到下标（老 sed 就是这么匹配的；测试夹具 `@weburl[11]` 依赖它）。
3. **`idx = cnt[typ] + 0`**：awk 里未初始化的数组元素是 `""` 而不是 `0`，不加 `+ 0` 会让第一个命名节的链名变成 `PCA_weburl_`（空下标）。**这是本轮的实作陷阱。**

**同类缺陷一并修掉**：`weburl_macs_all()`/`weburl_ips_all()`（`/etc/init.d/parentcontrol:276-282` 原用 `grep weburl`）改为 `pc_opts_all weburl mac|ip` —— 它们此前同样漏掉命名段（用于 offload 判定与 conntrack 清理）。

**未动**：`set -f` 不能全局加（代码**依赖**通配符展开：`root/etc/uci-defaults/luci-app-parentcontrol:22`、`init.d:212/238/618`），故只改枚举口径。`luasrc/` 无任何硬编码 `@weburl`（LuCI 走 `foreach`），Lua 侧不受影响。**F3 仍有意不修**（用户禁止擅自新增规则类别）。

### J.2 白盒 + 变异（全绿）

| 项 | 结果 |
|---|---|
| `sh test/run.sh` | **`ALL SUITES PASS`** —— common **81** / init **122** / acceptance **73** / migrate **94** checks |
| 新增白盒用例 | common_test **5** 条（`pc_ids_all`/`pc_ids_on`/`pc_opts_all` 的命名段等价性）；init_test **6** 条（命名段端到端下发规则、`enable=0` 被忽略、「匿名/命名/匿名」三节各拿 0/1/2） |
| `sh test/mutation_check.sh` | **killed 47 / survived 0 / 锚点失效 0**（新增 4 条 F5 变异：命名节被跳过、命名节下标不递增、`enable=0` 也算启用、`pc_opts_all` 字段不过滤 —— 全被杀死） |
| 测试夹具加固 | `test/fakes/uci` 新增 `resolve()`（**字面键优先**的 `@type[N]` 解析）；`test/fakes/uci_import.py` 改为**按类型**给每个节编号（原先只给匿名节编号，与真机不符） |

### J.3 打包（本地手工组包，脚本化）

新增 `test/build_ipk.sh`（`sh test/build_ipk.sh [输出目录]`）—— 把 §I.1 的手工步骤固化：从 `Makefile` 读版本、铺 `root/`→`/` 与 `luasrc/`→`/usr/lib/lua/luci/`、生成 control/conffiles/postinst/prerm、按 **gzip-tar**（非 `ar`）组包，成员顺序 `./debian-binary ./data.tar.gz ./control.tar.gz`。

- `PKG_VERSION` `1.8.0` → **`1.8.1`**（`PKG_RELEASE` 仍 `20261008`）。
- 产物 `luci-app-parentcontrol_1.8.1-20261008_all.ipk`：**28 个文件**、**43097 B**、md5 **`21986e6b80f2b5efdc8b10b2f900745c`**。
- 包内自检：含 `pc_uci_scan`（4 处）、`init.d` 用 `pc_opts_all`、成员顺序与官方包同构。
- **构建可复现**（两次相隔数秒的构建 md5 相同）。踩过的两个坑：① libarchive 的 `tar -z` 会把**当前时间**写进 gzip 头 → 改为先出未压缩 tar 再 `gzip -n -9`；② tar 的 `./` 条目带的是**暂存根目录自身的 mtime**，只 walk 目录内条目的 `freeze()` 漏掉了它 → `freeze()` 现在先 `utime` 根本身。`--mtime` 在 macOS bsdtar 3.5.3 上不支持，故用 python 统一 touch；时间基准取 `SOURCE_DATE_EPOCH`，否则取 HEAD 提交时间。
- **部署产物**：真机装的是可复现化之前构建的 `43552 B` / md5 `7ecfcea50692c8c668b2e067d26254b4`；两者**解包后 28 个文件内容逐字节相同**（只差内层 tar 时间戳）。

### J.4 真机安装与复验

- **流程合规**：S1 备份（config/init.d/common.sh + export + mangle 快照）→ S2 deadman（`start-stop-daemon` detached，`sleep 300`，还原时**含 `ubus call uci reload_config`**，§I.5 加固）→ S3 单条 ssh 内闭环测量 → S5 gate → kill deadman + 清理。
- `opkg install /tmp/pc-new.ipk`（预检 `Upgrading … 1.8.0-20261008 to 1.8.1-20261008`）**rc=0**；`Version: 1.8.1-20261008`。
- **conffile 正确保留**：`uci export` md5 `247c232f2a245ecd991999b31f7d55be`、raw `0d7609d2264932ca03a55ecbb5747158` **均未变** → `pc_migrate_config` 对线上配置确为 **no-op** ✓
- **逐文件一致**：`/etc/init.d/parentcontrol` = `7b49e500f1b15824a0b2508b44386ee1`、`/usr/lib/parentcontrol/common.sh` = `a422ef5ac4bce0edd95b109e67e4a67a`，与本地仓库**逐字节相同** ✓
- **★F5 真机决定性验证（命名段）**：

| 步骤 | mangle `-A` v4/v6 | QUOTA `-A` v4/v6 | 本机 Mac 规则 |
|---|---|---|---|
| 基线 | 72 / 54 | 53 / 39 | 0 |
| 加**命名**测试节 `uci set parentcontrol.pcf5test=weburl` + 10 字段 + `reload` | **88 / 66** | **65 / 48** | **16** |
| 删除测试节 + `reload` | 72 / 54 | 53 / 39 | 0 |

  → **命名段现在会被真正下发规则**（修复前 A/B 实测为「全不变」）。删节后配置 export md5 回到 `247c232f…`、raw 回到 `0d7609d2…`。
- **探针**：小红书 302 / 百度 200（网络正常）；iPad 当日用量 `base.weburl_0` = 0（未被影响）。

### J.5 收尾 S5 gate（本轮 18 项）

config export `247c232f…` ✅ / config raw `0d7609d2…` ✅ / mangle 72/54 ✅ / QUOTA 53/39 ✅ / PREROUTING 顺序 `PARENTCONTROL_QUOTA` → `PARENTCONTROL_ACCT` ✅ / weburl 节 2 ✅ / 测试节残留 0 ✅ / **iPad 规则 md5 v4 `4de4df07…`、v6 `3f2ab84d…` 逐字节不变** ✅ / 本机 mac 规则残留 0 ✅ / 服务 enabled ✅ / cron 2 ✅ / `ucitrack` json ✅ / 包版本 `1.8.1-20261008` ✅ / `init.d` md5 ✅ / `common.sh` md5 ✅ / 探针 302+200 ✅ / deadman `fired=no`（未触发回滚）✅ / `/tmp/pc*` 仅剩 `/tmp/pc_offload_state`（服务运行时文件）✅

### J.6 本轮结论

- **F5 已修并经真机命名段验证**（修复前完全无规则 → 修复后规则齐备）。
- 白盒 `ALL SUITES PASS`（81/122/73/94），变异 **47 killed / 0 survived / 0 锚点失效**。
- 版本 **1.8.1-20261008** 已装真机，与仓库逐字节一致；conffile、iPad 规则字节级不变；收尾 gate 18 项全绿。
- 未决：**F3**（v6 配额链无 LAN 守卫）按用户约束有意不修。

## §K 2026-10-09 项目元信息整理轮（版本 1.8.3-20261009）

**动机**：用户要求仓库与 README 不再保留任何「衍生自他仓库」的表述，并进一步决定清掉源码里的历史署名/版权行、更换 GitHub 仓库简介、重建仓库以摘掉平台侧的派生标记。

### K.1 改动清单（本仓库，全部为注释与文档；无行为变更）

| 文件 | 改动 |
|---|---|
| `README.md` | 删掉派生来源整行与「参考来源（最初参考的源码）」链接行；自称式小标题（「本 ×× 的改动」）改为「主要改动」；`### 1. 修复四处旧版缺陷` → `### 1. 修复四处缺陷`；「老版本在…完全不生效」→「在开启软件加速的 IPv4/IPv6 双栈环境下…会完全失效」；多处自称改为「本插件」；新增 `## 更新日志` 段（倒序 1.8.3 / 1.8.2 / 1.8.1 / 1.8.0） |
| `root/etc/init.d/parentcontrol` | 删掉第 2 行历史作者署名；第 3 行自称改为「本插件新增：」 |
| `root/usr/lib/parentcontrol/common.sh` | 注释里去掉了来源人名（「某某原版根本没有额度模型」→「更早的版本根本没有额度模型」） |
| `Makefile` | 删掉头部历史版权行；`PKG_VERSION` `1.8.2` → **`1.8.3`** |
| `test/build_ipk.sh` | 注释里的派生表述改为中性（「本仓库的 GitHub Actions」） |
| `docs/superpowers/specs/pc-acceptance-{design,progress,review,test-report}.md` | 4 处派生表述改为中性表述（本仓库 / 本项目） |

> **许可证提示（如实记录）**：`Makefile` 声明 Apache-2.0（`PKG_LICENSE:=Apache-2.0`，仓库**无 LICENSE 文件**），该许可证 §4(a) 要求分发衍生作品时保留原作品的版权声明。删掉版权行由用户明确确认（已两次告知风险）。版权本身不因删除通知而消失。

### K.2 白盒

`sh test/run.sh` → **ALL SUITES PASS**（`PASS (94 checks)`）。本轮无新增用例（逻辑零变更，仅注释/文档）。

### K.3 打包（可复现）

`sh test/build_ipk.sh .build` 与 `… .build2` 各一次 → 产物 `luci-app-parentcontrol_1.8.3-20261009_all.ipk`，**md5 两次相同 = `69a1787ba3db50fbb7a5bc720cc99325`**（28 数据文件 / 44173 B）。

### K.4 真机部署（S1–S7 合规，2026-10-09 20:01–20:03）

- **S1 备份**：`/tmp/pc-bak/{config,initd,common}.orig` + `export.txt` + mangle v4/v6 快照。部署前基线：config raw `0d7609d2…`、`export` `247c232f…`、init.d `75e9836e…`、common.sh `20979c45…`、`v4m=72 v6m=57 v4q=53 v6q=42`、installed `1.8.2-20261009`。
- **S2 deadman**：`sleep 300` → 还原三个文件 + `ubus call uci reload_config` + `restart` → 写 `/tmp/pc-deadman-fired`；`start-stop-daemon -S -b -m -p /tmp/pc-deadman.pid -x /bin/sh -- /tmp/pc-deadman.sh` → `DEADMAN_RUNNING pid=19716`。
- **S3 单条 bash 闭环**：`scp -o ControlMaster=no` → `md5sum` 校验 → `opkg install` → 立即读全部关键量。
- **部署结果**：`ipk_md5=69a1787b…` ✓、`opkg_rc=0`、`1.8.2-20261009 → **1.8.3-20261009**`；`init.d md5 = 14b3d555…`、`common.sh md5 = 9276f6d0…` **与本地仓库逐字节一致**；`ucitrack json = 97d594ef…`。
- **零副作用**：`config raw 0d7609d2…` 不变、`export 247c232f…` 不变（`pc_migrate_config` no-op ✓）；`v4m=72 v6m=57 v4q=53 v6q=42` **与部署前完全相同**（本轮只动注释，规则集不变）；PREROUTING v4/v6 均 `PARENTCONTROL_QUOTA` → `PARENTCONTROL_ACCT`；`bbtest=0`、weburl 节 2；v6 QUOTA 链首恰 3 条 `-j RETURN` 守卫；v4 QUOTA 链首 2 条 `-j RETURN`；链声明 v4/v6 各 3 条。
- **iPad 完整性（R6）**：按 iPad MAC 过滤的 mangle 规则 md5 —— v4 `4de4df074b7558b997ff1af05842979f`（68 行）、v6 `3f2ab84dd8eaf049c917a6d3a78286ec`（52 行），**部署前后逐字节不变**。
- **探针**：小红书 `302`、百度 `200`；`/tmp/pc_offload_state=disabled`（设计如此）；iPad 当日用量 `base.weburl_0` = 0。
- **S5 收尾**：`DEADMAN_KILLED pid=19716`、`fired=no`（未发生回滚）、`deadman_procs=0`；`/tmp/pc-bak` 与 `/tmp/pc-new.ipk` 已删；真机 `/tmp` 仅剩服务自有 `/tmp/parentcontrol`；`/etc/config/parentcontrol-opkg` 为 opkg 标准 conffile 存档（内容 = 包默认值，无用户数据）。
- **★取 MAC 时的大小写坑（如实记录）**：首次核对 iPad 指纹时用了大写 `<managed-device-mac>` 做 `grep -F`，而链里是小写，得到空串的 md5 `d41d8cd98f00b204e9800998ecf8427e`，险些误判为「iPad 规则消失」。改用小写后与基线一致。**后人核对指纹务必用链里的实际大小写。**

### K.6 后续清理（同日追加）

初版 §K 自身在描述「删掉了哪些字样」时把那些字面量原样写了回来（§K.1 表格行、§K.5 结论行、`pc-acceptance-progress.md` §12.2），造成自我污染。已再次改写为中性的「派生来源 / 历史库名」措辞，并对全仓库做通用替换：`上游缺陷`/`上游 bug`/`上游原版`/`上游 1.7.1` → `旧版缺陷`/`旧版 bug`/`老版本`/`1.7.1`（涉及 `docs/superpowers/specs/pc-acceptance-{design,progress,review,test-report,testplan}.md`、`test/acceptance_test.sh`、`test/mutation_check.sh`，均只改注释与断言**描述文本**，断言判据未变）。

复验：对上述历史库名与派生自称关键词做全仓库 `git grep`，**0 命中**；`上游` 一词仅剩 `README.md:74` 的「上游网关」（指运营商网关，属正常网络术语，保留）。

`sh test/run.sh` → **ALL SUITES PASS**（`PASS (94 checks)`）。本轮全量变异检查未重跑：改动仅落在注释与 `run_mut` 的**标签字符串**上，变异锚点位于 `root/` 下的生产文件，其内容一字未动，故变异结论可证不变。

### K.7 仓库重建（同日完成）

GitHub 不提供「解除派生关系」的接口（该平台字段只读），故按用户决定执行**删库重建**：

1. 全量备份：`git bundle create <备份>/pc-backup-<ts>.bundle --all`（含全部分支与 8 个 tag，`git bundle verify` 通过）。
2. 用户在 GitHub 网页 Danger Zone 手动执行 *Delete this repository*（`gh` token 缺 `delete_repo` scope，无法代劳）。
3. `gh repo create neohob/luci-app-parentcontrol --public --description '<新简介>'`。
4. 本地 `git remote remove upstream`；`git push -u origin main` + `git push origin --tags`。

**结果**：平台侧派生标记已清空（父仓库字段为空），页面上「派生自 …」的横幅消失。`main` 与 8 个 tag 全部就位；`origin/main` 与本地 HEAD 一致。仓库 URL 不变（`https://github.com/neohob/luci-app-parentcontrol`）。

**已知代价（用户已知悉并确认）**：原仓库的 1 个 star、0 个派生、0 个 issue 计数与 watch 一并归零；旧 URL 的 star 记录与外部缓存失效。

### K.5 本轮结论

- 版本 **1.8.3-20261009** 已装真机，与仓库逐字节一致；规则集、配置、iPad 指纹均零变化（本轮仅注释/文档）。
- 仓库内不再出现派生来源、历史库名或自称字样（对相关关键词 `git grep` 0 命中）。
- 白盒 `ALL SUITES PASS`；打包可复现（两次 md5 相同）。
- 未决：**F3** 仍按用户约束有意不修；F5 已在 1.8.1 修复。
