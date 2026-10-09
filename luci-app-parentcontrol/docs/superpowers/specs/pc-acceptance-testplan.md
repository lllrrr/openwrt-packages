# pc-acceptance — testplan（白盒 W\* + 上线黑盒 B\* + 回归 R\*）

> **重写版**。用例全部**根据需求**（`pc-acceptance-design.md` 的 A1..A46）推导，逐条回溯。
> 三类：**W = 白盒**（主机跑，走内部逻辑/桩）、**B = 上线黑盒**（真机，只看用户可观测行为）、
> **R = 回归**（修过的缺陷 / 兼容 / 线上既有资产）。
> 由 conductor 写；code pane 落 W 代码，test pane 复核 W + 跑 B + 跑 R。

---

## 0. 环境与前提

| 项 | 值 |
|---|---|
| 仓库 | `/Users/neo/Downloads/MyNextCloud/Work/luci-app-parentcontrol` |
| 白盒运行 | 主机 `sh` + `python3`，`sh test/run.sh`（**约 3 分钟**）；`sh test/mutation_check.sh`（全量**约 50 分钟**，`MUT_ONLY=<子串>` 可分块） |
| 真机 | ImmortalWrt 23.05.4 x86/64，`root@<router-ip>`，`SSHPASS='[REDACTED]' sshpass -e ssh -o StrictHostKeyChecking=no root@<router-ip>` |
| App 现状 | **已部署且启用**；mangle `PARENTCONTROL_QUOTA`(封) + `PARENTCONTROL_ACCT`(计)，PREROUTING 顺序 QUOTA→ACCT；**基线：ipv4 72 / ipv6 54 条 `-A` 规则**（⚠ `grep -c PARENTCONTROL` 会多算 2 条 `-N` 链声明，得到 74/56 —— 计数一律用 `grep -c '^-A'`） |
| 线上既有资产 | iPad `weburl` 节（`mac=<managed-device-mac>`，小红书系列）**生效中 → 绝不可动（R6 专测）** |
| 本机 Mac | IP `<test-device-ip>`；**路由器看到的 MAC = `<test-device-mac>`**（macOS 私密地址） |
| 本机网络 | Clash TUN（utun7=198.18.0.1）→ 只有 Clash 走 DIRECT 的**境内**目标能看到真实 IP；境外/代理流量不可观测（见 §4 限制） |

---

> ⚠ **凭据与真机标识不落盘**：本仓库 origin 是**公开** GitHub 仓库，且仓库目录在 NextCloud 同步盘内。
> 因此本文档中的**路由器口令一律写 `[REDACTED]`**，路由器 IP / 设备 MAC / 设备 IP 一律用占位符
> （`<router-ip>`、`<test-device-mac>`、`<test-device-ip>`、`<managed-device-mac>`）。
> **执行 B/R 时由 conductor 在 handoff 消息里下发真实值**，把占位符替换后使用；**不得**把真实值回写进仓库任何文件。

---

## 1. 真机测试安全协议（B/R 的硬前提，违反即 TEST_FAIL）

- **S1 备份**：`cp /etc/config/parentcontrol /tmp/pc-bb-backup.uci`；`uci export parentcontrol > /tmp/pc-bb-uci-export.txt`；`iptables -t mangle -S > /tmp/pc-bb-mangle-before.txt`（+ ip6tables）；拉一份到本机。
  ✅ **本轮已由 test pane 完成**（路由器 `/tmp/pc-bb-*` 四份 + 本机留档；`uci export` md5=`247c232f…`），可直接复用，不必重复做。
- **S2 deadman**：任何改规则前，先在路由器启动「`sleep 300` 后恢复备份 + commit + restart + 清 BB 测试节」的后台脚本（`setsid`/`nohup`），确认在跑；跑完确认恢复后 kill。
- **S3 单次 bash 内闭环**：任何「装规则→观察→撤规则」必须在**一条 bash 命令里**跑完，不得跨 LLM 轮次（agent 的模型 API 走同一出口，封锁期间再发 LLM 调用会把自己卡死）。观察用 `curl --max-time 5` / `nc -w 3`。
- **S4 不碰**：`basic.*`、iPad 节、protocol/time/quota/vacation 节、防火墙/网络/passwall/Clash。只加/删**一个** `remarks=BBTEST-MAC` 的测试节。
- **S5 收尾校验（gate）**：删测试节 + commit + `reload`；比对用 **`md5sum`**（路由器 busybox **无 `diff`**）——当前 `uci export` 的 md5 必须 == 基线 `247c232f…`；mangle `-A` 计数回 v4=72/v6=54；Mac 探针恢复；iPad 节原样；kill deadman；清 `/tmp/pc-bb-*`。
- **S6 时间预算**：B+R 目标 **< 20 分钟**；不做跨天/60 分钟等待。
- **S7 高风险用例需用户批准**：任何**会影响 iPad** 的操作（关总开关 `basic.enabled`、停用插件测 offload 恢复）默认 **SKIP 并标注**，除非用户明确批准。

---

## 2. 白盒用例 W\*

> `状态`：**已有** = 现套件已实现（列文件）；**新增** = 本轮 code pane 必须补。
> 断言的**可鉴别性**用 `test/mutation_check.sh`（变异注入 → 必须 FAIL）保证。

| ID | 覆盖 | 状态 | 用例（前置 → 步骤 → 期望） |
|----|------|------|------------------------------|
| W1 | A5 | 已有(init_test) | 关闭开关 → `build_all` 后 mangle/filter 均无 PARENTCONTROL 链 |
| W2 | A1 | 已有(run.sh/lint_ash) | 全 shell 文件过 busybox-ash 兼容 lint（禁 `local a,b=0`、`10#` 等） |
| W3 | A1、A40 | **新增** | 组合配置（time+protocol+weburl 各一 enable=1）→ 跑真实 `start` 全流程 → **三类规则都在**（防「bash 语法崩在 time 之后、protocol/weburl 没装」的旧版缺陷复发） |
| W4 | A2 | **新增** | 预置「旧规则已存在」的假 iptables 状态 → `del_rule` → 旧链/PREROUTING 跳转/老 filter 表 TIME·PROTOCOL·WEBURL/老 mangle WEBURL·IP **全部清掉**；连续 `start` ×3 → 规则数不增长、无重复跳转 |
| W5 | A3 | **新增** | 预置陈旧 `$LOCK` → `start()` **不 exit 1**、能完成构建、锁被清 |
| W6 | A3 | **新增** | 让构建中途失败（桩里让某命令返回非 0）→ `trap` 触发 → 锁文件被清、无残留 |
| W7 | A4 | **新增** | 以假 `uci` 分别令 parentcontrol 启用=1 / ≠1 → 跑 hotplug iface 脚本 → 前者调 `start`、后者不调；且**不得出现 `1: not found`** |
| W8 | A6、A9 | 已有(init_test) | 链在 **mangle** PREROUTING；仅挂 QUOTA、ACCT 两条且顺序 QUOTA→ACCT；设备条件为 `-m mac --mac-source` |
| W9 | A7 | **新增** | 有受管设备 → `nft` 桩里预置 fw4 `... flow add @ft` → `apply_offload` → 该规则**被删除**、`/tmp/pc_offload_state=off` |
| W10 | A8 | **新增** | 从「off」状态调用停用/恢复路径 → `flow add @ft` 规则**被装回**、状态文件=on |
| W11 | A7 | **新增** | 有受管设备 + 存在 conntrack 时 → 对受管设备各身份执行 `conntrack -D`；**无 conntrack** → 跳过且不报错、不影响其余构建 |
| W12 | A10 | 已有(init_test) | 封锁与计数共用生成器：同一目标集合在 QUOTA(`-j DROP`) 与 ACCT(`-j PCA_*`) 两侧**完全一致**；计数单条不双计 |
| W13 | A11 | **新增** | `domains='1.2.3.4/32,example.com'` → `1.2.3.4/32` **按 CIDR 直接封、不进解析器**（resolve 桩日志里无它）；`example.com` 才走解析 |
| W14 | A12 | 部分已有 | `ip_mask=24` → `-d x.x.x.0/24`；**新增** `ip_mask=32` → `-d x.x.x.x/32`；IPv6 → `/64` |
| W15 | A13 | 已有(init_test) | 解析结果按条目累积、**只增不减**；删除条目 → 对应 `ips/weburl_<N>` 被清 |
| W16 | A14 | **新增** | `ip_refresh=30` → crontab 写入刷新条目；`ip_refresh=0` → **不写** cron；条目由插件自己维护（不覆盖他人条目） |
| W17 | A15 | 部分已有 | apex+`www.` 变体都解析；**新增** 只填关键词 `xhs` → 试 `xhs.com`/`www.xhs.com`/`xhs.cn` |
| W18 | A16 | 已有(init_test) | 三类条目计时口径：time=该设备全部、protocol=该端口/协议、weburl=目标 IP+明文 DNS/SNI |
| W19 | A17 | 已有(init_test) | 三态：时段外→封（且不计入额度）、时段内未满→放行、耗尽→立即封（无条件 DROP） |
| W20 | A18 | 已有(init_test) | 额度 0 = 全禁；勾「不限额度」→ 只看时段、且不消耗共享池 |
| W21 | A19 | 已有(common_test) | 时段默认全天=不产生规则；脏数据（起≥止/非法）→ 按「不限制」兜底；HH:MM 自动补秒 |
| W22 | A20 | 已有(common_test/init_test) | UTC+8→UTC 换算；跨 UTC 零点切两段；时段外一律**正向区间**（不含 `! -m time`） |
| W23 | A21 | 已有(common_test) | 跨天 → 用量清零、不结转 |
| W24 | A22 | 已有(init_test) | 增量 ≥ `usage_min_kb` 才记 1 分钟；同分钟只记一次；首次采样（无 base）计入；阈值 0 时任何流量都算 |
| W25 | A23 | 已有(init_test) | 池内加总；池满 → 全部成员一起封；「挂池但池无额度」→ 用条目自己额度/用量；池额度=0 仍走池分支 |
| W26 | A24 | 已有(init_test) | 日子类型切 school/holiday → 分别用 `sd_*`/`hd_*`（额度与时段各自独立） |
| W27 | A25 | 已有(init_test) | 额度空 + 未勾不限 → **fail-open 不封**（防静默全禁） |
| W28 | A26 | 已有(common_test/migrate) | 归一器：空/`abc`/`-1`/`+5`/` 5` → 0；纯数字原样；迁移与运行**同一实现** |
| W29 | A27 | 已有(init_test) | QUOTA 链**首条**是 `-d <lan> -j RETURN`，且**先于**任何 DROP |
| W30 | A28 | 已有(init_test) | 拿不到 LAN 网段 → 跳过「无设备条件」的封锁 + 日志告警 |
| W31 | A29 | 已有(common_test) | `pc_lan_nets` 取 `network.*` 的 `proto=static` 段；无配置返回空 |
| W32 | A30 | 部分已有 | **新增**：条目同时填 `mac` + `ip` → 封锁侧**各出一条**规则（任一命中）；计数侧只出一条（`ip` 优先） |
| W33 | A31 | 已有(init_test/common_test) | 有网拉当年+次年；7 天节流；缓存缺失先用 bundle 兜底；bundle 缺才联网；抓取失败不动已有文件；无数据按周末/周中降级 |
| W34 | A32 | 已有(common_test) | `MM-DD` 每年重复 / `YYYY-MM-DD` 绝对 / 跨年区间 / 缺字段坏行跳过 |
| W35 | A33 | 已有(common_test) | 优先级：寒暑假 > 法定/调休 > 周末/工作日 |
| W36 | A34 | 已有(common_test) | 用 `date` 桩改系统时区/时间，判定仍按 UTC+8 |
| W37 | A35 | **新增** | 列表摘要格式化：今日额度 `12 / 30 分钟`、`不限`、条目不存在 `-`；档案摘要「两档案相同只写一次、全天不写、秒不写」；设备列 `MAC（设备名）`。**落到可断言的单测**（把格式化抽成纯函数或断言 `stats_tsv brief`） |
| W38 | A36 | **新增** | 编辑页校验「起必须早于止」：抽出的校验函数对 (起=止)、(起>止) → 报错；(起<止) → 通过（**防「自己和自己比」的回归**） |
| W39 | A37 | **新增(静态)** | 「使用限额」页定义存在且含 quota/vacation 两个 TypedSection；字段名与 shell 侧读取一致 |
| W40 | A38 | 已有(run.sh/lint_luci_globals) | 被 `require` 的 CBI 子模块不得直接用注入全局（防页面 500）；文案为中文字面量 |
| W41 | A39 | 已有(run.sh/init_test) | `stats_tsv` 列**只允许 `tsv.lua` 解析**（结构检查 + TSV 输出断言 meta/entry/hist/histkey 行） |
| W42 | A40 | 部分已有 | shell 侧仍执行 `enable=1` 的 time/protocol 条目（已有）；**新增(静态)**：UI 源码里**没有** time/protocol 的入口/页面 |
| W43 | A41–A46 | 部分已有(migrate_test) | **新增**补：迁移**备份文件生成**（`/etc/parentcontrol/backup/parentcontrol.<ts>.bak`）；**幂等**（连跑两次配置无新变化）；**新模型条目字段一个不动**；老字段（`mode`/`start`/`end`/`week`/`timestart`/`timeend`）清掉 |

**W 的可鉴别要求**：每条**新增**断言都要用 `mutation_check.sh` 的注入法证明「改坏源码后它会 FAIL」——
否则视为摆设，不算通过。

---

## 3. 上线黑盒用例 B\*（真机 · 用本机 Mac 作受管设备）

> 只从**用户可观测的输入输出**判定。判定失败时给最小复现。
> 探针规则：选一个 Clash 走 **DIRECT 的境内**域名（如 `www.sogou.com`），先在本机解析出 IP、
> 并在路由器 conntrack 确认 `src=<test-device-ip> dst=<IP>` 直连；否则换；全都不行 → 按 §4 限制降级并标注。

| ID | 覆盖 | 步骤 | 期望（可观测） | 判定 |
|----|------|------|----------------|------|
| **B1** | A5、A6、A9 | `/etc/init.d/parentcontrol enabled`；`iptables -t mangle -S` 看两条链与 PREROUTING 顺序 | enabled；QUOTA/ACCT 存在；顺序 QUOTA→ACCT | 自动 |
| **B2** | A2 | 规则快照 → `reload` ×3 → 再快照 | 每次 rc=0；规则集合与基线一致、**不堆叠** | 自动 |
| **B3** | A5 | ⚠高风险(影响 iPad)→ **默认 SKIP**：关总开关 → 规则消失 → 再开回来 | （仅用户批准时执行）关=无 PARENTCONTROL 规则、开=回来 | 手动 |
| **B4** | A10、A12、A13、A15 | ①探针基线可达；②加 enabled `weburl` 节（`mac=<test-device-mac>`、`ip=<test-device-ip>`、`domains=<探针>/32` 或域名、sd/hd 全天、`unlimited=0`、`quota=60`）→ commit + reload；③本机重试探针；④本机试对照目标（境外，走代理）；⑤路由器看 TAGQ 的 `-s … -d <探针IP> -j DROP` 与 `ips/weburl_<N>`、以及 ACCT 的 `-j PCA_*`；⑥删节 + reload | ②③探针**仍可达**（quota=60 **未耗尽** → 按 A17② 放行；⚠ 封锁不由本用例承担，见 B5/B6/B7——原稿写“探针失败”是**错的**，已修正）；④对照仍成功；⑤规则与 ips 文件都在、目标作用域只含该探针；⑥恢复到基线 | 自动 |
| **B5** | A17、A19 | 复用 B4 的节，sd/hd `qstart=00:00:01`、`qend=00:00:02`（当前必在时段外）→ reload → 重试探针；再改回 → reload | 时段外探针**失败**；改回**成功** | 自动 |
| **B6** | A18 | 复用 B4 的节，全天窗口 + `quota=0`、`unlimited=0` → reload → 重试探针 | 探针**失败**（0≥0 恒成立）；删节后**成功** | 自动 |
| **B7** | A16、A22 | 复用 B4 的节，设 `quota=1`（1 分钟）、`usage_min_kb=0`；本机对探针造流量；等 1~2 个 tick；查路由器 `usage/` 计数与 TAGQ | 计数增长；超 1 分钟后探针**被封**（尽力而为，允许标注「受 tick 粒度限制」） | 自动 |
| **B8** | A27（安全关键） | **在 B4/B5/B6 封锁生效的那一条 bash 内**：本机 `nc -w 3 <router-ip> 22`、`curl --max-time 5 http://<router-ip>/` | SSH 可连、LuCI 200 → 封锁**没**断掉恢复通道 | 自动 |
| **B9** | A7、A8 | ⚠高风险(停用会影响 iPad)→ **默认 SKIP**：受管条目存在时 `nft list chain inet fw4 forward` 无 `flow add`；停用插件后规则回来 | （仅批准时执行） | 手动 |
| **B10** | A35–A39 | 本机 LuCI 登录后 GET：列表页 / 某条编辑页 / 使用限额页 / 使用统计页 / 状态接口 | 均 200；含中文标记（「网址过滤列表」「使用限额」等）；统计页有数据行 | 自动 |
| **B11** | A40 | 只读：检查菜单/页面里**没有**「时间限制」「协议过滤」入口 | 无入口 | 自动 |
| **B12** | A31 | 路由器：`ls /usr/share/parentcontrol/holiday/`；`tail /tmp/log/parentcontrol.log`；看 `build: day=` 与 holiday 拉取/节流记录 | 有当年+次年 json；日志有 day 判定；7 天节流生效 | 自动 |
| **B13** | A13、A14 | `crontab -l | grep -i parentcontrol`；`uci get basic.ip_refresh`；`ls /etc/parentcontrol/ips/` | cron 有一条刷新条目；间隔=配置值；ips 文件按条目 | 自动 |
| **B14** | A30 | 测试节只填 `ip=<test-device-ip>`（不填 mac）→ reload → 本机重试探针 | 探针**失败**（静态 IP 命中同样生效） | 自动 |
| **B15** | A34 | **只读**核对：`-m time` 区间与 UTC+8 换算一致（不修改系统时区） | 换算正确 | 自动 |
| **B16** | A36 | 编辑页表单提交「起=止」→ 期望被拒（HTTP 回显校验错误） | 被拒绝、不落盘 | 自动 |
| **B17** | A46 | `ls -la /etc/parentcontrol/backup/` | 存在迁移备份 `.bak`（历史产物，只读核对） | 自动 |

---

## 4. 回归用例 R\*

| ID | 覆盖 | 步骤 | 期望 |
|----|------|------|------|
| **R1** | 全部 | `sh test/run.sh` | **ALL SUITES PASS**（3 lint + 3 suite） |
| **R2** | W 可鉴别性 | `sh test/mutation_check.sh` | 每个变异都被测试**检出并 FAIL**（断言非摆设） |
| **R3** | A1–A4（旧版缺陷） | 注入式回归：临时把 4 处旧缺陷改回去（ash 语法 / `del_rule` 变量笔误 / 无锁自愈 / hotplug 恒假），跑 W2/W3/W4/W5/W7 | 对应用例**必须 FAIL**；改回后 PASS（证明这 4 条防线真的在守） |
| **R4** | A7、A8 | 装受管条目 → `flow add` 移除；卸载 → 恢复 | 与 A7/A8 一致，且**反复装/卸不残留** |
| **R5** | A41–A46 | 迁移跑两次；对「已是新模型」的条目再跑 | 第二次**无新变化**；新模型条目字段**不动**；备份文件每次另存属预期 |
| **R6** | 线上既有资产 | 加/删 BB 测试节**前后**，导出 iPad 节对应的 mangle 规则集合，逐条 diff | **逐条一致**（不多不少）——证明新功能没污染在跑的条目 |
| **R7** | A27 | 任意封锁生效时检查 QUOTA 链首 | 仍是 `-d <lan> -j RETURN`，在 DROP 之前 |
| **R8** | A13 | 造两轮解析（模拟 CDN 换段） | 老 IP **保留**、新 IP 追加；删条目 → 文件清空 |
| **R9** | A35–A39 | 界面/统计四页 | 仍渲染 200、中文、TSV 唯一解析 |
| **R10** | A1–A46 | 覆盖矩阵 | 每条 A 至少一个 **PASS** 的 W 或 B；**矩阵无空格** |

---

## 5. 覆盖矩阵（A × {W, B, R}）

| A | W | B | R | | A | W | B | R |
|---|---|---|---|---|---|---|---|---|
| A1 | W2,W3 | — | R3 | | A24 | W26 | — | — |
| A2 | W4 | B2 | R3 | | A25 | W27 | — | — |
| A3 | W5,W6 | — | R3 | | A26 | W28 | — | — |
| A4 | W7 | — | R3 | | A27 | W29 | B8 | R7 |
| A5 | W1 | B1,B3 | — | | A28 | W30 | — | — |
| A6 | W8 | B1 | — | | A29 | W31 | — | — |
| A7 | W9,W11 | B9 | R4 | | A30 | W32 | B14 | — |
| A8 | W10 | B9 | R4 | | A31 | W33 | B12 | — |
| A9 | W8 | B1 | — | | A32 | W34 | — | — |
| A10 | W12 | B4 | — | | A33 | W35 | — | — |
| A11 | W13 | B4 | — | | A34 | W36 | B15 | — |
| A12 | W14 | B4 | — | | A35 | W37 | B10 | R9 |
| A13 | W15 | B4,B13 | R8 | | A36 | W38 | B16 | — |
| A14 | W16 | B13 | — | | A37 | W39 | B10 | R9 |
| A15 | W17 | B4 | — | | A38 | W40 | B10 | R9 |
| A16 | W18 | B7 | — | | A39 | W41 | B10 | R9 |
| A17 | W19 | B5,B7 | — | | A40 | W3,W42 | B11 | — |
| A18 | W20 | B6 | — | | A41 | W43 | — | R5 |
| A19 | W21 | B5 | — | | A42 | W43 | — | R5 |
| A20 | W22 | B15 | — | | A43 | W43 | — | R5 |
| A21 | W23 | — | — | | A44 | W43 | — | R5 |
| A22 | W24 | B7 | — | | A45 | W43 | — | R5 |
| A23 | W25 | — | — | | A46 | W43 | B17 | R5 |

> **白盒执行入口**：`sh test/run.sh`（R1）；**黑盒**：按 §3 在真机执行；**回归**：§4。

---

## 6. 交付物

- 本 testplan：`docs/superpowers/specs/pc-acceptance-testplan.md`
- 需求基准：`docs/superpowers/specs/pc-acceptance-design.md`
- code pane：W 的「新增」用例实现进 `test/`，`sh test/run.sh` 全绿 + `progress.md`（信号行）
- test pane：`docs/superpowers/specs/pc-acceptance-test-report.md`（每条 W/B/R：PASS/FAIL + 证据 + 失败最小复现 + 未测项及原因），末尾 `TEST_PASS:` / `TEST_FAIL:`
