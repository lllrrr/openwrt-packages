# pc-f3-v6-lan-guard · Test Plan（测试计划）

> 角色产出：**conductor**（阶段 3）。执行者：白盒 `wR:p4`，复核 `wR:p2`，真机黑盒 `wR:p3`。
> 映射目标：design §5 的 **A1–A9** 每条 ≥1 白盒（W）+ ≥1 真机黑盒（B）；并列出回归（R）与变异（M）。
> 计数口径（沿用既有约定）：一律 `iptables -t mangle -S <链> | grep -c '^-A'`（`grep -c PARENTCONTROL` 会多算 `-N`）。

---

## 1. 覆盖矩阵（A1–A9 ↔ 用例）

| 验收标准 | 白盒（W，本地桩） | 真机黑盒（B） | 变异（M） |
|---|---|---|---|
| **A1** v6 链出现守卫、覆盖每个前缀、增量恰 3 | W-F3-07, W-F3-09 | B-F3-01（v6 链首 3 条 `-j RETURN`；54→57 / 39→42） | M-F3-02 |
| **A2** v4 逐字节不变 + iPad-v4/v6 指纹不变 + v6 增量仅守卫 | W-F3-08 | B-F3-02（v4 md5/72/53 + iPad 指纹双向比对） | M-F3-02 |
| **A3** 窗口内 LAN v6 可达 / 非 LAN 小红书仍 DROP | W-F3-10（规则语义） | **B-F3-03**（真机可达性 + 封锁双向） | — |
| **A4** 忽略 ` via `/`unreachable`/`default`；无 v6 时降级 | W-F3-02, W-F3-03, W-F3-04, W-F3-05 | B-F3-04（无路由时无守卫且不报错） | **M-F3-01** |
| **A5** 幂等 + 外部 `-F` 后自愈（含守卫） | W-F3-11, W-F3-12 | B-F3-05 | M-F3-02 |
| **A6** 白盒断言可鉴别 | —（由 M 保证） | — | M-F3-01, M-F3-02, M-F3-03 |
| **A7** 零配置变更、不新增链/hook/类别 | W-F3-12（链数不变） | B-F3-06（`uci export` md5 不变；PREROUTING 顺序不变；链声明仍 2 条/族） | — |
| **A8** 全量白盒无回归 | `sh test/run.sh` → ALL SUITES PASS；`mutation_check.sh` → survived 0 / 锚点失效 0 | — | 全量 |
| **A9** 真机装 1.8.2 后验收 | — | B-F3-01..B-F3-08 + 收尾 gate | — |

---

## 2. 白盒用例（W，`wR:p4` 实现）

### 2.1 `test/common_test.sh` —— `pc_lan_nets6` 单元

| ID | 场景（夹具） | 断言 |
|---|---|---|
| **W-F3-01** | `FAKE_IP_ROUTE6` = br-lan 三行直连（GUA `/64`、ULA `/64`、`fe80::/64`）；`network.lan` = `proto static` + `device br-lan` | 输出**恰好 3 行**，顺序稳定（`sort -u` 后），逐行等于预期前缀 |
| **W-F3-02** | 同上 + 追加 `default dev br-lan proto static`、`default from <…> via <…> dev br-lan`、`throw <…>::/64 dev br-lan`、`blackhole <…>::/64 dev br-lan` 四行 | 输出**仍恰好 3 行**（`default`/`throw`/`blackhole`/` via ` 全部被白名单拒掉） |
| **W-F3-03** | 上述「`unreachable <prefix> dev lo`」三行（复刻真机 `ip -6 route show dev lo`）；`network.loopback` = `proto static` + `device lo`（+ 另给一个含直连前缀的 `lan`） | `lo` 节**产出为空**（`unreachable` 被拒）；`lan` 节产出不受影响 |
| **W-F3-04** | `FAKE_IP_ROUTE6` 为空/未设置 | 输出为空、`rc=0`、日志无报错 |
| **W-F3-05** | `network.lan` = `proto static` 但**既无 `device` 也无 `ifname`** | 输出为空、`rc=0`。**⚠ 阶段 5 复审指出此用例恒真**（无 `FAKE_IP_ROUTE6` 时任何实现都输出空）→ **必须改成可鉴别形式**：**同时设置 `FAKE_IP_ROUTE6`（含真实前缀）且只给一个无设备名的静态节**，断言输出为空（若配上设备名则会有输出）；或让桩记录 `ip` 调用并在断言里证明**没有**被调用 |
| **W-F3-06** | 两条不同节产出**同一前缀** | 输出去重后该前缀**只出现一次**（`sort -u`） |
| **W-F3-13**（阶段 5 SF-1 增补） | `FAKE_IP_ROUTE6` 注入行首为 `::/0` 的行（如 `::/0 dev br-lan proto static metric 1024 pref medium`），另给真实直连前缀 | `::/0` **不出现在输出里**（零长前缀被排除）；真实前缀照常产出 |
| **W-F3-14**（阶段 5 SF-2 增补） | 守卫下发用例：`network.lan` 静态节 `ipaddr` 写成含冒号的值（如 `fd00::1`）+ netmask | **v4 链不出现该值**（v4 分支恢复改动前语义：跳过含 `:` 的值）；v6 链不受影响 |

> 夹具写法：沿用 `test/lib.sh` 既有 `cfg_load network <file>`（`init_test.sh:433` 同款）+ `FAKE_IP_ROUTE6="$T_TMP/route6.txt"`。
> **注意**：`pc_lan_nets()` 的既有断言（`common_test.sh:216`，期望 `192.0.2.1/255.255.255.0` 原样）**不得改动**。

### 2.2 `test/init_test.sh` —— 守卫下发

| ID | 场景 | 断言 |
|---|---|---|
| **W-F3-07** | 复刻现有 `init_test.sh:420-447` 的防自锁夹具（`time` 条目 + `network.lan` 静态节），**并补 `device br-lan` + `FAKE_IP_ROUTE6` 三行**，制造「额度耗尽」 | v6 `PARENTCONTROL_QUOTA` 出现 **3 条** `-d <prefix> -j RETURN`；v4 仍出现原 `-d 192.0.2.1/255.255.255.0 -j RETURN` |
| **W-F3-08** | 同 W-F3-07 | v4 侧规则集合**与不加 `FAKE_IP_ROUTE6` 时逐条相同**（证明 v6 改动不影响 v4） |
| **W-F3-09** | 同 W-F3-07 | 每条 RETURN 都排在所有 `-j DROP` **之前**（沿用现有断言法：`grep -m1 -- '-j' | awk '{print $NF}'` = `RETURN`；并对**带设备条件的 DROP** 也成立） |
| **W-F3-10** | 同 W-F3-07，且条目带 `mac` 且目标为解析出的 v6 段 | 链中**同时**存在「`-d <lan-v6-prefix> -j RETURN`」与「`-d <resolved-v6-cidr> -m mac … -j DROP`」→ 规则层面证明「LAN 放行、非 LAN 仍封」 |
| **W-F3-11** | 同 W-F3-07 → 连跑 `build_quota_blocks` **两次** | 第二次**一条 iptables 都不动**：用 `ipt_setcounters v6 mangle PARENTCONTROL_QUOTA '*' 4242` 后计数保留（复用 `acceptance_test.sh:302-308` 的 F1 手法）；链内条数不增 |
| **W-F3-12** | 同 W-F3-07 → 外部 `ip6tables-legacy -t mangle -F PARENTCONTROL_QUOTA` → `build_quota_blocks` | 自愈重建后 **3 条守卫回来**；且**链声明数不变**（`-N` 仍 2 条/族；不新增链 —— A7） |

---

## 3. 真机黑盒用例（B，阶段 6 由 `wR:p3` 执行）

> 前置：**S1–S7 真机安全协议**（备份 → deadman 自动还原 → 单条 bash 闭环 → 只加/删 `remarks=BBTEST-*` 测试节 → 收尾 gate → 时间预算 → 高风险用例需批准）。
> 基线（2026-10-09 实测）：`uci export parentcontrol` md5 `247c232f2a245ecd991999b31f7d55be`；raw md5 `0d7609d2264932ca03a55ecbb5747158`；mangle `-A` v4/v6 = **72/54**；QUOTA `-A` = **53/39**；PREROUTING 顺序 `PARENTCONTROL_QUOTA` → `PARENTCONTROL_ACCT`；iPad-v4 指纹 `4de4df07…` / iPad-v6 指纹 `3f2ab84d…`（按 iPad MAC 过滤）；`ip -6 route show dev br-lan` 3 行直连。

| ID | 用例 | 期望 |
|---|---|---|
| **B-F3-01** | 装 `1.8.2-20261009` → 读 v6 QUOTA 链 | 链首**恰好 3 条** `-d <prefix> -j RETURN`，前缀 = `ip -6 route show dev br-lan` 的 3 个直连前缀；v6 mangle `-A` **54→57**、QUOTA **39→42** |
| **B-F3-02** | A/B 指纹比对（部署前已采基线） | v4 mangle/QUOTA `-A` 仍 **72/53**、iPad-v4 指纹 `4de4df07…` **逐字节不变**；iPad-v6 指纹 `3f2ab84d…` **逐字节不变**；v6 增量**恰为 3 条 RETURN**（diff 证明：剥掉这 3 条后与基线逐条一致）—— **A2 / D10 三条口径** |
| **B-F3-03** | 加一条 `remarks=BBTEST-F3` 测试节（本机 MAC/IP + 小红书域名 + 时段设为**当前时间之外**→ 立刻处于封锁窗口）；`reload` 后：① 本机访问**路由器 v6 管理地址 / 局域网内 v6 目标**；② 本机访问小红书（v6 路径）；③ 对照组访问百度 | ① **可达**（`curl --max-time 5` 成功）；② **被 DROP**（失败/超时）；③ v4/v6 均正常 → **A3**（注意：观测与撤规则**必须在同一条 bash 内闭环**） |
| **B-F3-04** | 环境无 v6 直连前缀时（不可造 → 只做**只读核对**：确认 `pc_lan_nets6` 的数据源与真机路由一致；或临时用一个无 v6 路由的桩设备名，**不改真机配置**） | 无前缀 → 不下发守卫、其余不变、日志无报错 → **A4**（若不可造则 **SKIP 并标注**） |
| **B-F3-05** | 幂等/自愈 | 连续 3 次 `reload` → 条数稳定 57/42 **不堆叠**；外部 `ip6tables -t mangle -F PARENTCONTROL_QUOTA` 后等 1 个 tick（≤ 75 s）→ **3 条守卫回来** → **A5** |
| **B-F3-06** | 零副作用 | `uci export parentcontrol` md5 **仍** `247c232f…`；raw md5 **仍** `0d7609d2…`；PREROUTING 顺序不变；链声明 v4/v6 仍各 2 条；**不新增任何链/表**；未动 `basic.*`/防火墙/passwall/Clash → **A7** |
| **B-F3-07** | 探针与既有功能 | 小红书/百度探针正常（302/200）；SSH 可连；LuCI 四页 200 且中文正常；iPad 当日用量 `base.weburl_0` 未被影响 |
| **B-F3-08** | 收尾 gate | 删测试节 + `commit` + `reload` → 全部回**部署稳态**（**注意：不是 F1/F2 轮的 72/54 模板值**）：`uci export` md5 `247c232f…` / raw md5 `0d7609d2…` / **v4 mangle 72 · QUOTA 53（不变）** / **v6 mangle 57 · QUOTA 42（= 基线 +3 条守卫，1.8.2 自身的稳态）** / iPad 指纹 v4·v6 逐字节不变 / PREROUTING 顺序不变 / 链声明各 2 条、无新链新表 / 无 BBTEST 残留 / cron 2 条 / `/tmp/pc-*` 清空 / deadman 已 kill 且 `fired=no`。**包保留 1.8.2 不卸载**（A9 要求真机装上 1.8.2 后验收；本机无 1.8.1 产物，回滚会让 opkg 库与实际不一致） |

**SKIP 规则**：任何会影响 iPad 的操作（关 `basic.enabled`、停插件测 offload）默认 **SKIP 并标注**（需用户单独批准）。

---

## 4. 回归（R）

| ID | 内容 | 期望 |
|---|---|---|
| **R1** | `sh test/run.sh` | `ALL SUITES PASS`（lint ×3 + UI 静态 + 4 套件） |
| **R2** | `sh test/mutation_check.sh` | survived **0** / 锚点失效 **0**（含新增 3 条） |
| **R3** | 既有 `pc_lan_nets()` 断言（`common_test.sh:216`） | **未改动**，仍 `192.0.2.1/255.255.255.0` |
| **R4** | 既有「防自锁」断言（`init_test.sh:441`） | 仍 PASS（v4 守卫原样；无 `FAKE_IP_ROUTE6` 时 v6 不产出） |
| **R5** | 既有「拿不到局域网网段 → 跳过封锁」断言（`init_test.sh:449-460`） | 仍 PASS（`block_skip_devless` 只看 v4 网段，不被本改动影响） |
| **R6** | F1 自愈断言（`acceptance_test.sh:302-311`） | 仍 PASS（v4 路径未改） |
| **R7** | 真机 iPad 资产 | 按 iPad MAC 过滤的 v4/v6 规则 **逐字节不变**（阶段 6 随 gate 复验） |
| **R8** | 打包可复现 | `build_ipk.sh` 连续两次 md5 相同 |

---

## 5. 变异（M，必须全部 killed）

| ID | 变异（`mutate <file> <old> <new>`） | 期望被哪条用例杀掉 |
|---|---|---|
| **M-F3-01** | **去掉行首格式白名单**：把 `pc_lan_nets6` 的字段校验改成「直接取第 1 字段」 | **W-F3-02**（`default dev br-lan` 会被当成前缀 → 断言 3 行失败） |
| **M-F3-02** | **退回族过滤**：在 `allow_lan_in` 里重新加回 `addr_is_family … || continue` | **W-F3-07 / W-F3-12**（v6 守卫 0 条 → 断言 3 条失败） |
| **M-F3-03** | **不按族选数据源**：把 `allow_lan_in` 改成两个族都用 `pc_lan_nets()` | **W-F3-07**（v6 链无守卫或出现 IPv4 网段） |
| **M-F3-04**（阶段 5 SF-1 增补） | **移除零长前缀排除**：删掉 `pc_lan_nets6` 里拒绝 `/0` 的那一步 | **W-F3-13**（`::/0` 出现在输出 → 断言失败） |

> 约束：变异锚点必须能在当前源码里**唯一命中**（`mutate` 取**首次**出现；未命中即 `锚点失效` 且退出码 1）。新增用例若用不到 W-F3-0x 中的某条，必须在 progress 说明。

---

## 6. 判定

- **阶段 4（code pane）完成条件**：P1–P9 全绿 + P10 已回调。
- **阶段 5（review pane，`/thermos`）通过条件**：无 Blocker；证据与结论可核对。
- **阶段 6（test pane）通过条件**：B-F3-01..08 全 PASS 或明确 SKIP（含理由），收尾 gate 全绿，真机回到基线。

> **终态口径说明（conductor 裁定 2026-10-09，阶段 6 提问）**：`pc-acceptance-test-report.md` §H.8 的 S5 模板写「mangle 回 72/54」是 **F1/F2 轮**的口径——那一轮只换 `/etc/init.d/parentcontrol` 文件、不含新守卫，故复原后与部署前完全相同。F3 的 1.8.2 包**自身**新增 3 条 v6 守卫（A1 的功能要求），部署后 v6 必然为 57/42，删掉测试节后仍是 57/42。因此 F3 的收尾 gate 判据改为「**回部署稳态**」：v4 侧与部署前逐字节相同（72/53 + iPad-v4 指纹），v6 侧 = 基线 +3 条守卫（57/42 + iPad-v6 指纹不变）。**新的 v6 基线 `57/42` 自此成为后续轮次的比对基准。**
