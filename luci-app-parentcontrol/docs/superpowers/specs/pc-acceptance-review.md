# pc-acceptance — 阶段 5 复审报告（review / thermos）

- 日期：2026-10-03；角色：review pane（reviewer）；conductor：`wR:p1`；task-brief：`pc-acceptance`
- 基线：`HEAD = 7b1376d`，本轮改动**全部未提交**
- 复盘范围：`git diff HEAD`（`root/` 生产代码 2 处 + `test/` 测试体系）+ 未跟踪文件（`test/fakes/ip`、`test/ui_static_check.py`、`test/ui_static_test.sh`、`docs/superpowers/specs/*.md`）
- 复核资料：`pc-acceptance-design.md`（A1..A46）、`pc-acceptance-testplan.md`（W/B/R）、`pc-acceptance-progress.md`（code pane 自述）

## 0. 方法（/thermos）

按 `/thermos` 跑**两路并行**复审（本 pane 无 Task 子代理工具，改用 `pi -p` 起两个并行子代理，各自加载对应 rubric，均只读、不改文件）：

1. `thermo-nuclear-review`（bug / 破坏性 / 安全 / devex / 功能泄漏）
2. `thermo-nuclear-code-quality-review`（可维护性 / 结构 / 复杂度 / 1k 行 / code-judo）

两路结论在本报告去重、交叉验证、按证据加权。**两路在「生产代码 2 处变更干净」上完全一致**；分歧仅在测试基建的严重度定级（见 §5 合成说明）。

本 pane 独立复核（非仅采信子代理）：

- `sh test/run.sh` → **ALL SUITES PASS**（lint locals / ash / luci / TSV + UI 静态 42 项 + common 76 + init 176 + migrate 94）。
- **定点反证**：仓库副本里只回退本轮新增的那一行（filter 表 `-F/-X` 循环去掉 `PARENTCONTROL_WEBURL`）→ `sh test/init_test.sh` **FAILED (1/176)**，唯一失败项正是 `FAIL filter 表无 PARENTCONTROL 链(v4) got=[PARENTCONTROL_WEBURL]`。→ 该断言**确实可鉴别**，不是摆设。
- `MUT_ONLY=W43 sh test/mutation_check.sh` → 2/2 killed（验证 `MUT_ONLY` 分块与锚点可用）。
- 独立 grep 验证凭据/隐私字面量（见 B1）。

---

## 1. 结论

**REVIEW_FAIL** —— 生产代码两处变更经逐行复核**干净且正确**（del_rule 是真修复、common.sh 钩子零行为变化）；但**变更集里有一处 Blocker：新文档 `pc-acceptance-testplan.md:16` 明文写了真机路由器 root 密码**（该仓库 origin 是公开 GitHub）。另有若干测试基建 Should-fix 与 Nit。

| 级别 | 数量 | 摘要 |
|------|------|------|
| Blocker | 1 | 明文 root 密码 + 真机 MAC/IP 进入待提交文档（公开仓库） |
| Should-fix | 3 | fake nft handle 语义失真；`ui_static_check.py` 过度钉字面量；`init_test.sh` 破 1k 行且大段重复 |
| Nit | 5 | 新 filter 行无专用变异；W11 隐藏 conntrack 不封闭；新夹具回退到真实内网段；测试计划「约 1 分钟」失实；设计稿 A1..A34 陈旧 |

---

## 2. 生产代码复审（2 处，逐行）

### 2.1 `root/etc/init.d/parentcontrol` del_rule（+1 字面量）→ 真缺陷修复，非 no-op

**文件:行**：`root/etc/init.d/parentcontrol:572`（把 `PARENTCONTROL_WEBURL` 加进 filter 表 `-F/-X` 循环）。

**证据（全历史追溯，不是推测）**：

- `git show b7fa705:root/etc/init.d/parentcontrol`（1.7.1）：weburl 模式 `chain=OUTPUT`，`$ip -N $TAGW` / `$ip -C OUTPUT -j $TAGW` / `$ip -F $TAGW` / `$ip -X $TAGW` —— **全部无 `-t`，即 filter 表**。→ 老的 `PARENTCONTROL_WEBURL` 链**确实存在过、且在 filter 表**。
- `git show 6393d61`（本仓库把 weburl 改挂 mangle PREROUTING）：`del_rule` 里 filter 循环**仍包含 TAGW**（`for ta in "$TAG" "$TAGW" "$TAGP"; do ... $ip -F $ta; $ip -X $ta; done`，默认 filter），并**另加** mangle 同名链清理。
- `git show c4fe179^:root/etc/init.d/parentcontrol`（统一模型前的 del_rule）：filter 跳转删除循环含 `"$TAG" "$TAGP" "$TAGW"`，但 filter **`-F/-X` 循环只剩 `"$TAG" "$TAGP"`** —— 即 `c4fe179` 那次重构**把 filter 表 WEBURL 的 `-F/-X` 误删了**。本轮修复正是把它补回。

**判定**：**真修复**。对「从1.7.1 / pre-`6393d61` 升级」的用户，filter 表会残留一条 `PARENTCONTROL_WEBURL` 链（跳转已被 `-D` 循环删除，链体及其中 DROP 规则仍在）。

**误清/漏清/副作用**：无。

- 该循环无 `-t` → 只可能作用于 **filter** 表；`TAGQ`/`TAGA`/`PCA_*` 与 mangle 的 `WEBURL`/`IP` 由各自独立循环清（`:576-581`），互不干扰。
- 链不存在时 `-F/-X` 静默失败，无副作用。
- 工作树 del_rule 与 `git show HEAD:...` 逐行对比：**唯一变化就是这个字面量**。

**用户可观测影响（比 code pane 自述更强）**：`luasrc/controller/parentcontrol.lua:25` 的状态判定是
`iptables -t mangle -S ... | grep -q PARENTCONTROL || iptables -S ... | grep -q PARENTCONTROL`。
残留的 **filter** 表 `PARENTCONTROL_*` 链会让 `iptables -S | grep -q` 命中 → **停用后状态仍显示「运行中」**。所以这不是「多清一条空链」的纯清理，而是修掉一个真实的状态误报。progress §3-①「仅升级遗留的旧链清理，多清一条空链」**低估了**其价值（方向对，定级偏低）。

**可鉴别性（本 pane 独立复现）**：仅回退这一行 → `init_test.sh` W4 失败：
```
FAIL filter 表无 PARENTCONTROL 链(v4)
       want=[]
       got =[PARENTCONTROL_WEBURL]
FAILED (1/176 checks failed)
```
→ W4 的 filter WEBURL 断言**真的能鉴别这次修复**，不是摆设。（注意：`mutation_check.sh` 里没有针对这一行的专用变异，见 N1。）

### 2.2 `root/usr/lib/parentcontrol/common.sh` PC_CONF_DIR / BACKUP_DIR 钩子 → 生产零变化

**文件:行**：`common.sh:7`（`PC_CONF_DIR=${PC_CONF_DIR:-/etc/config}`）、`:12`（`BACKUP_DIR=${BACKUP_DIR:-/etc/parentcontrol/backup}`）、`:295-297`（`pc_migrate_config` 改用钩子）。

**证据**：

- `pc_migrate_config` 备份分支改前是 `[ -f "/etc/config/$PC_CONF" ]` + `mkdir -p /etc/parentcontrol/backup` + `cp -a ...`；改后变量默认值**逐字等于**原硬编码路径。未设环境变量时行为**逐字节不变**。
- `grep -rn '/etc/config' root/` 仅剩 `common.sh:7`（新钩子，默认值正确）与 `root/etc/uci-defaults/luci-app-parentcontrol`（**未改动**、且此处读真实 UCI 文件本就是对的，不该被钩子化）。无其他硬编码 `/etc/config`。
- `grep -rn 'parentcontrol/backup' root/` 仅剩 `common.sh:12` 的钩子默认值；`pc_migrate_config` 是**唯一**消费者。
- 命名/形态与既有钩子 `HOLIDAY_CACHE`/`USAGE_DIR`/`IPDIR`/`PC_LIB` 一致。

**判定**：生产行为**零变化**，与既有路径钩子惯例一致，无遗漏的硬编码。

---

## 3. 测试体系复审

### 3.1 断言可鉴别性（无摆设）

- **未删旧断言**：`git diff HEAD -- test/init_test.sh test/migrate_test.sh test/mutation_check.sh` 的删除行**为空**（纯新增）。既有 W1/W8/W12/W15/W18..W31/W33..W36/W40/W41 全部保留（例如 W8 的 `PREROUTING 顺序 QUOTA→ACCT` 在 `init_test.sh:225` 仍在）。→ 「testplan 里『已有』的用例被本轮悄悄破坏」**未发生**。
- 新增断言抽查均有实际判别力：W3（三类规则都在 + rc/stderr/crontab）、W4（链全清 + ×3 不堆叠）、W5/W6（锁自愈/trap）、W7（hotplug 启用判断 + 无 `not found`）、W9–W11（offload 删/恢复 + conntrack）、W13/W14/W17/W32、W37–W43。
- **变异证据**：`mutation_check.sh` 新增 21 个变异（W2/W3/W4/W5/W6/W7/W9/W10/W11/W13/W14/W16/W17/W32/W37/W38a/W38b/W39/W42/W43a/W43b），progress 报告 36/36 全杀；本 pane 复跑 `MUT_ONLY=W43` 2/2 killed，并**独立复现 W4 反证**（§2.1）。

### 3.2 桩是否越界（fake nft 语义）→ 是，失真但当前未致假信心

**文件:行**：`test/fakes/nft:50`（handle 分配）、`:45`（delete 恒 exit 0）。

- handle = `wc -l + 1`：删除中间一行后**会重用**已有 handle（真实 nft 的 handle 单调递增、从不重用）。构造：3 行 handle 1/2/3 → 删 2 → 插一条得 handle 3（与残留的 3 冲突）→ `delete handle 3` 会**一次删两条**。
- `delete` 分支无论 handle 是否存在都 `exit 0`（真实 nft 对不存在的 handle 返回非 0）。

**当前影响**：W9/W10/W11 的 offload 状态永远 ≤1 条规则，且生产代码不检查 delete 退出码 → **这些失真当前不产生假信心**。但 fake 的注释自称模拟 `inet fw4 forward` 的通用子集，是**未来扩展 offload 测试的陷阱**（下一个加第二条 forward 规则的人会踩）。列为 Should-fix。

> `list`/`insert` 两路语义与真实 nft 一致（insert 置顶、`-a` 短选项跳过、`# handle N` 解析均对得上 `offload_handle`）。fake `ip` 仅实现 `ip neigh show`、`date` 新增 `+%Y%m%d%H%M%S` 与调用方一致、`conntrack`/`resolveip` 只在设了 `FAKE_*_LOG` 时记录——默认行为与从前一致，未越界。

### 3.3 `ui_static_check.py` 是否如实标注 → 是

- 模块 docstring、每段 banner（`== W37 ... 静态结构检查（非行为级）==`）、`main()`、`run.sh` 段头、progress §2/§5-2 **五处**都声明「静态、非行为级」，并显式把行为级交给真机 B10/B11/B16。**未被当成行为证据**。
- 但其能力边界有两点应如实备注（Should-fix/Nit，见 §4）：① `w37/w39/w42` 的字符串检查**未剥 Lua 注释**（只有 `w38` 剥了，`:79`），注释里出现目标串也可能满足检查；② 多条检查直接钉整段 Lua 表达式（`'if not rec then return "-" end'` 等），是**源码拼写**而非结构。

### 3.4 覆盖洞

- testplan 声明的 W→A 映射基本落实；A40 的 shell 侧由 W3 覆盖、UI 侧由 W42-静态覆盖。
- **发现的洞**：本轮**唯一的行为性生产变更**（`:572`）**没有专用变异**（`mutation_check.sh:158` 的 W4 变异改的是 **mangle** 循环 `-t mangle`→`-t filter`，命中的是 mangle 断言）。虽然该断言经本 pane 反证确有判别力，但 testplan 自定的「每条新增断言都要由 mutation 证明可鉴别」在这条线上**未闭环**。

---

## 4. 分级发现（Blocker / Should-fix / Nit）

### 🔴 Blocker B1 — 明文真机 root 密码 + 真机 MAC/IP 进入待提交文档（公开仓库）

**文件:行**：`docs/superpowers/specs/pc-acceptance-testplan.md:16`（密码）、`:18-19`（真机资产）

**证据（独立 grep）**：
```
docs/.../pc-acceptance-testplan.md:16:| 真机 | ... `SSHPASS='[REDACTED]' sshpass -e ssh ... root@<router-ip>` |
docs/.../pc-acceptance-testplan.md:18:| 线上既有资产 | iPad `weburl` 节（`mac=<managed-device-mac>`，小红书系列）... |
docs/.../pc-acceptance-testplan.md:19:| 本机 Mac | IP `<test-device-ip>`；路由器看到的 MAC = `<test-device-mac>` ... |
```
`sshpass -e` 从 `$SSHPASS` 取密码 → `[REDACTED]` **就是路由器 root 口令**。`git remote -v` = `https://github.com/neohob/luci-app-parentcontrol.git`（**公开仓库**）。`git grep <旧口令>` 无命中 → 该凭据是**本轮新引入**（docs/ 全新未跟踪）。

**最小复现**：`grep -n SSHPASS docs/superpowers/specs/pc-acceptance-testplan.md`

**为何是 Blocker**：一旦随本轮提交，明文口令永久进入公开 git 历史并暴露设备。且这几行同时把 commit `85d98c2`（"privacy: 测试夹具去掉真实设备 MAC 与内网网段"，把真机 MAC→`00:00:5e:...`、`<lan-cidr>`→`192.0.2.x`）**刻意抹掉的真实 MAC/IP 又写回了文档**（**loop-1 隐私补刀**：此处原有的 2 字节真机 MAC 前缀已占位化），等于撤销了那次隐私修复。

**处置**：提交前**删除口令 + 轮换密码**；真机 MAC/IP 改成占位符（`<router-ip>` / `<test-device-mac>`）。属文档修复（conductor 侧），非 code pane 重写。**建议 conductor 在本轮提交前先做这一项，再决定是否放行。**

### 🟠 Should-fix S1 — fake nft handle 语义失真（未来多规则 offload 测试会得到假信心）

**文件:行**：`test/fakes/nft:50`（`h=$(( $(wc -l < "$ST" ...) + 1 ))`）、`:45`（delete 恒 `exit 0`）

**证据/最小复现**：seed `FAKE_NFT_STATE` 为 3 行（handle 1/2/3）→ `nft delete rule inet fw4 forward handle 2` → `nft insert rule inet fw4 forward ...` → 新行拿到 handle 3（与残余的 3 冲突）→ 再 `delete ... handle 3` 会一次删两条。真实 nft handle 由内核单调分配、从不重用。

**为何要修**：当前用例状态恒 ≤1 条规则，尚未产生假信心；但 fake 自称通用模型，是下一个人的陷阱。一行可修：`h=$(awk -F'|' '{if($1+0>m)m=$1+0} END{print m+1}' "$ST" 2>/dev/null || echo 1)`，或状态文件旁维护单调计数。

### 🟠 Should-fix S2 — `ui_static_check.py` 过度钉 Lua 字面量（易腐、会被人「改断言」绕过）

**文件:行**：`test/ui_static_check.py:54/56/58/68`

**证据**：如 `'if not rec then return "-" end' in s`、`'"%d / %d %s", rec.used, rec.quota' in s`、`'mac .. " （" .. n .. "）"' in s`。把局部变量 `rec`→`r`、或把该分支抽成 helper 这类**纯重构**，会让检查变红——守的是「源码长这样」而非「行为成立」。W37 变异锚点与这些字面量同源，同样问题。

**为何要修**：静态 tripwire 值得留，但应缩到最小语义 token（`sub(1, 5)`、`>=`、`不限` 哨兵），保留真正结构性的检查（`w38` 的「禁止链式 `gsub(...):gsub(...)`」`ui_static_check.py:89`、`w39` 的 shell↔UI 字段名契约、`w42` 的正向对照）。否则下一个重构 Lua 的人会顺手改断言，防线静默失效。

### 🟠 Should-fix S3 — `init_test.sh` 破 1k 行（1151），新增段大比例重复夹具

**文件:行**：`test/init_test.sh:818-1151`（新增段）

**证据**：`wc -l test/init_test.sh` = 1151；新增块 W4/W5/W6/W9-11/W13/W14/W17/W32 反复出现同一形状的 `fresh; cfg_begin 1; cfg_section <<EOF [config weburl ...] EOF; cfg_apply; put_std_resolve; run_build`；`grep -c 'config weburl'` = 39。项目自己的 thermo rubric 有 ~1k 行/重复条件告警。

**为何要修**：新段里真正的断言差异被 11 个近乎相同的夹具块淹没，可读性/可维护性下降。code-judo：加一个 `one_weburl <mac> <domains> [ip] [quota]` 夹具构造器（放 `lib.sh`），或把 W3..W32 验收块挪到独立 `test/acceptance_test.sh`（与 W43 归 `migrate_test.sh`、UI 归 `ui_static_check.py` 同一思路），顺带把 `fresh`/`flat`/`uncond_drop` 提为共享。**纯结构、行为不变**。

### ⚪ Nit N1 — 新增的 filter 表 `PARENTCONTROL_WEBURL` 清理行无专用变异

**文件:行**：`test/mutation_check.sh:158`（W4 变异只改 mangle 循环）vs `root/etc/init.d/parentcontrol:572`

**证据**：把 `:572` 的 `PARENTCONTROL_WEBURL` 去掉后，`init_test.sh` 会因 W4 失败（本 pane 已复现），但 `mutation_check.sh` 仍报 36/36 killed（它的 W4 变异改的是 mangle 循环）。→ testplan「每条新增断言都要 mutation 证明可鉴别」在这条线上未闭环。建议补一个变异：从 filter `-F/-X` 循环移除 `PARENTCONTROL_WEBURL`（期望 `init_test.sh` 失败）。断言本身**已证明可鉴别**，此为「防线留痕」缺口。

### ⚪ Nit N2 — W11「隐藏 conntrack」不封闭（非 macOS 上可能调到真 conntrack）

**文件:行**：`test/init_test.sh:1013`（`mv "$BIN/conntrack" "$T_TMP/conntrack.hidden"`）

**证据**：`apply_offload` 用 `command -v conntrack` 判定；把 fake 的符号链接移走后 `command -v` 会继续搜 PATH。macOS 上无真 conntrack（当前通过）；**Linux CI** 若装了 `conntrack-tools`，真实二进制会被调用、对主机执行 `conntrack -D`。建议改成桩识别的 `FAKE_NO_CONNTRACK=1`（桩退非 0），或构造一个不可能含真 conntrack 的 PATH。

### ⚪ Nit N3 — 新夹具回退到真实内网段（违反项目既有隐私约定）

**文件:行**：`test/init_test.sh:987,997,1010,1011,1133,1141,1148`（`<lan-host>/160`）

**证据**：commit `85d98c2` 明确把夹具里的 `<lan-cidr>` 换成 RFC 5737 的 `192.0.2.x`；本轮新增的 W11/W32 又写回了 `<lan-cidr>`（diff 的 `+` 行）。功能无影响，仅为一致性。建议改 `192.0.2.x`。

### ⚪ Nit N4 — 测试计划文档失实小项

**文件:行**：`docs/superpowers/specs/pc-acceptance-testplan.md:15`（`sh test/run.sh（约 1 分钟）`）

**证据**：实测 `init_test.sh` 单项 ~2m21s，`run.sh` >2.5 分钟（本 pane 计时），与「约 1 分钟」不符；mutation 全量 ~50 分钟（progress 已注）。建议改为「约 3 分钟（mutation 全量约 50 分钟）」。

### ⚪ Nit N5 — 设计稿编号范围陈旧

**文件:行**：`docs/superpowers/specs/pc-acceptance-design.md:3`（`本项目唯一的验收标准清单（A1..A34）`）

**证据**：同文档表格定义到 A46、变更记录（`:115`）也写 A1..A46，testplan 亦按 A1..A46 回溯。作为「唯一回溯基准」的文档，范围写错会削弱可追溯性。改 A1..A46。

---

## 5. 合成说明（两路去重与定级）

- **一致（高权重）**：① 生产代码 2 处**干净**，del_rule 为**真修复**且无副作用；② `PC_CONF_DIR`/`BACKUP_DIR` **零行为变化**；③ fake nft handle 语义失真（两路独立发现）；④ `ui_static_check.py` 如实标注静态、但存在脆性；⑤ 新 filter 行缺专用变异。
- **本 pane 新增**：del_rule 修复的**用户可观测影响**（状态接口误报「运行中」，`controller:25`）；Blocker B1（凭据）；N3/N4/N5。
- **分歧处理**：S2/S3 的严重度，code-quality 路子代理给 Should-fix、安全路子代理给 Nit。考虑项目自有 1k 行 rubric 与「静态检查腐化」的长期成本，本报告取 **Should-fix（测试基建，非生产阻塞）**；不影响生产代码判定。
- **未定级为 Blocker 的项**：S1/S2/S3 均为**测试基建**，不改变运行时正确性，故不进 Blocker。唯一 Blocker 是 B1（凭据）。

## 6. 给 conductor 的最小行动项

1. **（提交前必做）** 删除 `pc-acceptance-testplan.md` 里的明文口令并**轮换路由器密码**；真机 MAC/IP 占位化。（B1）
2. 派回 code pane（可选，非阻塞）：修 fake nft handle 分配与 delete 退出码（S1）；收敛 `ui_static_check.py` 断言粒度（S2）；`init_test.sh` 夹具去重/拆文件（S3）；补 N1 变异；N2/N3/N4/N5 顺手清理。
3. 生产代码 2 处**可放行**，无需回改。

## 7. 信号

REVIEW_FAIL: Blocker B1 = docs/superpowers/specs/pc-acceptance-testplan.md:16 明文真机 root 密码（+ :18-19 真机 MAC/IP）将进入公开仓库；生产代码 2 处变更干净（del_rule 为真修复、common.sh 钩子零行为变化），另 Should-fix S1 fake nft handle 语义失真 / S2 ui_static_check 过度钉字面量 / S3 init_test 破 1k 行，Nit N1–N5。报告：docs/superpowers/specs/pc-acceptance-review.md

---

## 定向复审 · loop 第 1 轮

- 日期：2026-10-04；角色：review pane（reviewer）；conductor `wR:p1`；task-brief `pc-acceptance`
- 基线：`HEAD = 7b1376d`（未变）；增量 = `git diff HEAD -- test/` + 未跟踪 `test/acceptance_test.sh`、`test/ui_static_check.py`、`test/ui_static_test.sh`、`test/fakes/ip`
- 方法：`/thermos` 两路并行（`pi -p` + 两份 rubric，只读）。**诚实声明**：code-quality 路子代理正常返回（结论 PASS）；security 路子代理在收尾前自发起全量变异批次、并在中途执行了一次 `find /` 全盘扫描（0% CPU 挂起），未在预算内产出——其 security/correctness rubric 由本 pane 直接独立完成（§L1–L4 每条均附独立证据/最小复现）。合成见 §L5。
- 结论：**REVIEW_PASS**（S1/S2/S3/N1/N2/N3 全部闭环 + B1 无残留 + `root/` 未新增 + 断言未削弱）。

### L0. 本轮真实改动面（先钉基线）
上一轮 review 用的 `/tmp/pc_diff.txt`（stage-4 完整 diff）仍存活，本 pane 用它把 `HEAD` 重建出 stage-4 工作树（`git archive HEAD | tar -x` → `patch -p1 < pc_diff.txt`，patch exit=0），再与本轮对比，得到**本轮真实改动面**：
- 改：`test/fakes/{nft,conntrack,date,resolveip}`、`test/init_test.sh`、`test/lib.sh`、`test/mutation_check.sh`、`test/run.sh`
- 新：`test/acceptance_test.sh`、`test/ui_static_check.py`、`test/ui_static_test.sh`、`test/fakes/ip`
- **`diff -rq`（排除 `test/`、`docs/`）= 空**：本轮除 `test/` 外零改动。

### L1. B1 闭环（独立 grep，不采信自述）
- 口令：`docs/superpowers/specs/pc-acceptance-testplan.md:16` 现为 `SSHPASS='[REDACTED]'`（`grep -c REDACTED`=2，确为字面占位符）；全树无真实口令字面量、无 `password=…` 真实字面量。（loop-1 原文此处曾引用真实口令字面量，loop-2 复审将其遮盖。）
- 真机 MAC：已知真机 MAC 全树**零命中**；`docs/` 内 6 段 MAC 正则**零命中**。（loop-1 原文此处曾引用真实 MAC 完整字面量，loop-2 复审将其遮盖。）
- 真机 IP：`test/` 内 `<lan-cidr>` **零命中**；`docs/` 内 IPv4 仅 `1.2.3.4`/`192.0.2.x`/`198.18.0.1`（RFC 测试段）。
- `testplan` 顶部新增《凭据与真机标识不落盘》政策段，与本条一致。
- 残留（本 pane 顺手清理）：上一轮 §B1 引用里含 2 字节真机 MAC 前缀 `C6:84:…`（非完整标识、非口令），本轮已在原 §B1 就地占位化。→ **B1 无残留**。

### L2. `root/` 未新增改动（逐字核对）
`git diff HEAD -- root/` 与 stage-4 diff 的 root 段 `diff` **逐字节相同（byte-for-byte）**：仅 `root/etc/init.d/parentcontrol`（del_rule filter `PARENTCONTROL_WEBURL`）与 `root/usr/lib/parentcontrol/common.sh`（`PC_CONF_DIR`/`BACKUP_DIR` 钩子）两处，即上轮已放行内容。`diff -rq` 排除 `test/` 后全树为空。→ **无新增生产改动**。

### L3. S1/S2/S3/N1/N2/N3 逐条闭环

#### L3.1 S1 — nft 桩 handle 单调不重用 + delete 退非 0
- **文件:行**：`test/fakes/nft:55-63`（旁文件 `<state>.next`，首次按现存最大 handle 播种）、`:31-50`（delete：不存在 `exit 1`）。
- **独立复现（直接跑桩，非套件）**：seed `1|a 2|b 3|c` → `delete …handle 2`（exit 0，剩 1,3）→ `delete …handle 2`（exit **1**）→ `delete …handle 99`（exit **1**）→ `insert …`（handle=**4**，不重用 2、不撞残留 3）→ `insert …`（handle=**5**）。list 输出 `\t<rule> # handle N` 与生产 `offload_handle`（`root/etc/init.d/parentcontrol:248-251`）解析一致。
- **S1 子测试**：`test/acceptance_test.sh:164-170`；**专用变异**：`test/mutation_check.sh:284-292`。
- **定点反证**：仓库副本里把分配退回「行数+1」→ `sh test/acceptance_test.sh` **FAILED 1/63**，唯一失败 `S1: 新 handle=4（不重用已删的 2、不撞残留的 3）`；`MUT_ONLY=S1` 亦 killed。→ 真可鉴别。

#### L3.2 S2 — ui_static 收敛到最小语义 token + 去注释 + 结构性保留 + 仍可鉴别
- **文件:行**：`test/ui_static_check.py:39-45`（新增 `strip_lua`/`strip_shell`）、`:65-76`（w37 收敛）、`:98`（w38 禁链式 gsub）、`:124-127`（w39 shell↔UI 字段契约）、`:136-151`（w42 正向对照）。
- **对照上轮 §S2 点名的三处整句字面量**：`'if not rec then return "-" end'` → `'return "-"'`；`'"%d / %d %s", rec.used, rec.quota'` → `'string.format("%d / %d %s"'`；`'mac .. " （" .. n .. "）"'` → 全角括号哨兵 `'" （"'`/`'"）"'`。w37/w38/w39/w42 均已去注释（w38 复用同一 helper）。结构性检查（w38 禁链式 gsub `:98`、w39 字段契约 `:124-127`、w42 正向对照 `:139`）**保留**。
- **收敛后仍可鉴别（本 pane 其实跑）**：`MUT_ONLY=W37`(1) / `W38`(2, W38a+W38b) / `W39`(1) / `W42`(1) → **5/5 killed**（均 `ui_static_test.sh` 失败）。→ 未因收敛而「变绿」。

#### L3.3 S3 — init_test 拆分，断言守恒、未削弱
- **文件:行**：`test/init_test.sh`（**800 行**，原 1151）、`test/acceptance_test.sh`（293 行，含 W3..W32 + S1）、`test/lib.sh:202-238`（共享夹具 `write_basic`/`cfg_begin`/`cfg_section`/`cfg_apply`/`put_weburl`/`fresh`/`flat`）、`test/run.sh:34`（挂上 `acceptance_test.sh`）。
- **断言守恒（对照迁移前后）**：用 stage-4 diff 重建的基线里，`init_test.sh` 追加块 = **恰好 60 条**断言；本轮 `acceptance_test.sh` = 63 条 = 60（迁移）+ 3（S1 新增）。逐描述+整行体比对：**除 2 条 W11 因 N2 改名、4 条 N3 换 IP 字面量外，其余 58 条逐字一致**；`init_test` 116 + acceptance 63 = **179 = stage-4 `init 176` + 3（S1）**。
- **无削弱**：新增无 `|| true`、无比较符放宽、无期望值清空；`run.sh` 全绿（§L4）。
- **鉴别性**：迁移后变异（W3/W4/W5/W6/W7/W9/W10/W11/W13/W14/W17/W32）已改指 `acceptance_test.sh`（mutation_check round-1 delta 可见，无删除）；实跑 W11 killed。

#### L3.4 N1 — filter `PARENTCONTROL_WEBURL` 清理行专用变异
- `test/mutation_check.sh:272-279` 新增 `N1: filter WEBURL 清理行回退`（从 filter `-F/-X` 循环移除该字面量），套件指向 `acceptance_test.sh`。
- **定点反证**：副本里去掉该字面量 → `acceptance_test.sh` **FAILED 1/63**，唯一失败 `filter 表无 PARENTCONTROL 链(v4)`；`MUT_ONLY=N1` 亦 killed。→ 闭环。

#### L3.5 N2 — W11 弃用 `mv` 隐藏法、改桩开关
- `test/fakes/conntrack:7`（`FAKE_NO_CONNTRACK=1` → 一律退非 0）、`test/lib.sh:48`（开关）、`test/acceptance_test.sh:185-191`（W11 改写）。
- stage-4→now 差异：旧为 `mv "$BIN/conntrack" "$T_TMP/conntrack.hidden"`（未封闭，Linux CI 可能调到真 `conntrack`）；新为桩开关。生产 `command -v conntrack`（`init.d:267`）仍命中桩、但每调失败 → 可观测行为与「不可用」等价，且**不可能误调真二进制**；断言语义不变（构建不受影响、不 purge/ERROR）。→ 闭环。

#### L3.6 N3 — 真实内网段清零
- `grep -rn <lan-cidr> test/` → **零命中**；夹具改用 RFC 5737 `192.0.2.51` / `192.0.2.160`。→ 闭环。

### L4. 自证输出（只读）
```
$ sh test/run.sh
  locals / busybox-ash / luci globals / TSV 唯一性 / UI 静态检查 通过
  PASS (76 checks)      # common
  PASS (116 checks)     # init
  PASS (63 checks)      # acceptance（含 S1）
  PASS (94 checks)      # migrate
  ALL SUITES PASS
```
定向变异（本 pane 实跑 `MUT_ONLY`）：`S1 N1 W37 W38 W39 W42 W11 W2` → **9 killed / 0 survived / 0 锚点失效**。
定点反证：
- S1（handle→行数+1）→ acceptance FAILED 1/63（`S1: 新 handle=4…`）。
- N1（去 filter WEBURL）→ acceptance FAILED 1/63（`filter 表无 PARENTCONTROL 链(v4)`）。

### L5. 合成说明（两路去重与定级）
- **code-quality 路**（`/tmp/pc_thermo2.log`）：**PASS**，but 2 Should-fix（测试基建加固）+ 3 Nit（见 §L6）。与本 pane 独立结论一致：S3 拆分干净（1151→800、夹具共享、断言无丢失）、无 Blocker。
- **security 路**（`/tmp/pc_thermo1.log`）：子代理未产出（中途 `find /` 全盘扫描 + 反复自起全量变异批次，0% CPU 挂起，本 pane 终止）。其 security/correctness rubric **由本 pane 直接完成**：§L1（凭据）、§L2（生产未动）、§L3.1–L3.6（S1/S2/S3/N1–N3）均有独立证据与最小复现。
- **两路一致（高权重）**：生产代码干净、本轮测试基建改动全部闭环、无 Blocker。

### L6. 新增建议（非阻塞，测试基建加固；不影响本轮 PASS）
- **SF-a（Should-fix）**：`test/fakes/nft` 的 `.next` 旁文件是**未随 `fresh()` 复位的第二真相源**——`test/lib.sh:233-237`（`fresh`）复位 iptables/usage/state/IPDIR，但**不**复位 `$FAKE_NFT_STATE` / `$FAKE_NFT_STATE.next`。若某用例只重 seed `$ST` 而不删 `.next`，首次 insert 会拿到**已存在**的 handle（本 pane 复现：`.next=2` + seed `1,2,3` → insert 得 handle 2，撞残留）。当前套件在 `test/acceptance_test.sh:164,173` 显式 `rm -f .next` 规避，**未造成假绿**。建议 `fresh()` 一并清 `"$FAKE_NFT_STATE"{,.next}`（或把计数器并入状态文件）。
- **Nit**：`test/fakes/nft:31-33` delete 未校验 `$3.$4.$5=inet.fw4.forward`（list/insert 校验了）——错表的 delete 仍「成功」，削弱判据。
- **Nit**：`/tmp/pc_offload_state` 为固定全局路径（`test/acceptance_test.sh:160,176,179,194`），非 `fresh()` 复位、并发会竞态。
- **Nit**：`test/ui_static_check.py:39-41` `strip_lua` 只处理 `--[^\n]*`，未处理 Lua `--[[ ]]` 块注释/字符串内 `--`（边界）。
- **Nit**：`ui_static_check.py` 残余「拼写耦合」检查（`:71 sd == hd`、`:75 :sub(1, 5)`、`:94-95 gsub("_qstart$")`、`:99-100 is_start and a >= b`）——属**原 S2 范围之外**的进一步加固空间；S2 点名的三处整句字面量已收敛，故不构成 S2 未闭环。

### L7. 本轮信号

REVIEW_PASS: S1/S2/S3/N1/N2/N3 全部闭环——S1 桩 handle 单调不重用 + delete 退非 0（独立复现 + 反证命中唯一断言）；S2 收敛到最小语义 token、补去注释、保留结构性检查，收敛后 5/5 变异仍被杀；S3 拆分后断言守恒（stage-4 60 条 → init 116 + acceptance 63 = 179 = 176+3，逐字保留、仅 2 改名 + 4 IP 字面量）；N1/N2/N3 到位。B1 无残留（无口令、无完整真机 MAC/IP，test/ 内 <lan-cidr> 清零）；root/ 与上轮放行内容逐字节一致、无新增生产改动；断言未削弱。run.sh ALL SUITES PASS（76/116/63/94），定向变异 9/9 killed，定点反证 S1/N1 各自命中唯一断言。新增非阻塞加固项见 §L6。报告：docs/superpowers/specs/pc-acceptance-review.md

---

## 定向复审 · loop 第 2 轮

- 日期：2026-10-04；角色：review pane（reviewer）；conductor `wR:p1`；task-brief `pc-acceptance`
- 基线：`HEAD = 7b1376d`（未变）；**本轮改动面** = `luasrc/model/cbi/parentcontrol/parts.lua`（`submitted()`）+ `test/ui_static_check.py`（w38 新增 2 条断言）+ `test/mutation_check.sh`（新增 `B16` 变异）；其余未提交/未跟踪内容同 loop 1。
- 方法（/thermos，两路并行，均只读）：
  - **安全/正确性路**（`pi -p` 子代理，加载 `thermo-nuclear-review` rubric）：**正常产出**（原文 `/tmp/pc-review2/sec.out`）。
  - **代码质量路**（`pi -p` 子代理，加载 `thermo-nuclear-code-quality-review` rubric）：该子代理两次在收尾前挂起（超预算、无输出）；改用**同 rubric + 内联上下文的独立第二路**（`/tmp/pc-review2/qual.out`）。
  - **本 pane 独立复核**（不采信子代理）：真机**只读** SSH 查证 + `run.sh` + 定向变异 + 独立反证（每条附证据/最小复现）。

### M0. 本轮真实改动面（先钉）
- `git diff HEAD -- luasrc/model/cbi/parentcontrol/parts.lua`：**唯一 hunk `@@ -31,9 +31,17 @@`，只涉及 `submitted()`**（注释 + 函数体）；`validate_window` 不在 hunk 内。
- `test/ui_static_check.py` w38：新增 2 条；既有 w38 断言逐条保留。
- `test/mutation_check.sh`：新增 `B16`（回退到原缺陷行）。变异总数 38 → 39。

### Q1. `self.section.section` 是否是正确写法？→ **是（本环境唯一正确取法）**
真机（ImmortalWrt 23.05.4 x86/64，luci-base `git-24.265.44782`，**Lua 5.1.5**）**只读**查证 `/usr/lib/lua/luci/cbi.lua`：
- `AbstractSection.option`（:853-855）：`local obj = class(self.map, self, option, ...)` —— 建字段时把 **section 对象自身** 当 `section` 实参传入。
- `AbstractValue.__init__`（:1290）：`self.section = section` → 字段的 `self.section` = **AbstractSection 对象**。
- `NamedSection.__init__`（:1075-1081）：`self.section = section`，即 uci 名字字符串。
- `AbstractValue.cbid`（:1363-1364）：`"cbid."..config.."."..section.."."..option`（section = 名字）。
- `Map.formvalue`（:339-341）= `luci.http.formvalue(key)`；`luci.http.formvalue` 转发到 `lucihttp` C 模块（`/usr/lib/lua/luci/http.lua:24-26`）—— 与 `submitted()` 直接调 `http.formvalue` **同源**。
- 唯一调用方 `luasrc/model/cbi/parentcontrol/weburl_edit.lua:22,39-40`：`a:section(NamedSection, arg[1], "weburl")` + `parts.add_profile(t, …)`，`arg[1]` 开头已 guard 非 nil。
- 真机 Lua 复算：`("cbid.%s.%s.%s"):format(config, <NamedSection 对象>, key)` → `bad argument #2 to 'format' (string expected, got table)`（与 B16 真机报错**逐字一致**）；修复表达式对同一对象得 `cbid.parentcontrol.cfg0a1b2c.sd_qstart`。
- ucode 侧**无 CBI 实现**（`/usr/share/ucode/luci/` 只有 controller/dispatcher/http/runtime/template/sys…，无 cbi）→ CBI 走 Lua；代码 pane 的“ucode bridge”框架是红鲱鱼，但结论不受影响。

**判定：正确。** `self.section` = NamedSection 对象，其 `.section` 属性 = uci 名字；`self.section.section` 是**本环境正确且唯一**的取法；`type` 守卫对「对象/字符串」两形态都成立。

> 附带纠正一处自述不精确：progress §10 称「`self:formvalue(other_option)` 会带上 `or self.default` 兜底」。真机 `AbstractValue.formvalue`(:1374-1376) = `self.map:formvalue(self:cbid(section))`，**没有** `or self.default`；`or self.default` 在 `Value.cfgvalue`(:1636)。—— 仅论证用词错，不影响结论：读 raw `http.formvalue` 才能拿到「本次提交值」，而 `cfgvalue` 会回退默认值，原意仍对。

### Q2. fail-open 风险 → **潜在、当前不可达；新引入的“静默降级”，定为 Low**
- `submitted()` 取不到名字（非串/空）→ `return nil`；`validate_window` 的 `if other and other ~= ""` 为假 → **跳过起<止比对**、直接 `return value`（接受）。
- **可达性**：`submitted` 唯一经 `validate_window` 被调；`validate_window` 只挂在 `add_profile` 建的字段上；`grep -rn add_profile luasrc/` = 仅 parts.lua 定义 + weburl_edit.lua 两处调用（**全为 NamedSection**）。NamedSection 的 `.section` 恒为非空串 → **生产路径上 `submitted` 不会返回 nil** → A36 的起<止校验**实际始终生效**。
- 但**相对 HEAD**：HEAD 在此形态**响亮报错（500）**，修复后变成**静默接受起≥止** —— 一条新引入的静默降级路径（即代码质量路点名的 hide-the-invariant）。
- **最小复现思路**：把 `add_profile` 接到 `a:section(TypedSection, "weburl")`（`self.section` = TypedSection 对象、无 `.section` → 守卫取到对象 → nil）→ 编辑页提交 `start=23:00:00,end=00:00:00` 无错落盘。当前无此调用方。
- **影响面**：即便触发，shell 侧 A19 对「起≥止/脏数据」按「不限制时段」兜底 → **不会自锁**，只是「用户以为设了时段、实际不生效」。非安全/锁死问题。
- **判定**：对当前唯一调用路径，是**可接受的降级**（不可达）；但从「共享 helper + 静默 skip」角度，**建议至少落一条日志或显式报错**，避免未来复用 TypedSection 时静默丢 A36。Low（与两路子代理一致）。

### Q3. `validate_window` 语义是否逐字未动？→ **是**
`git diff` 仅 `submitted()` hunk；`validate_window` 逐字未动：`is_start and a >= b`、`not is_start and b >= a`（起=止亦判错）、且仍是 `is_start and self.option:gsub("_qstart$","_qend") or self.option:gsub("_qend$","_qstart")`（**无**链式 `):gsub(`）。w38 对以上均仍通过。

### Q4. 测试侧
**(a) B16 变异真能鉴别？→ 是，且命中唯一断言。**
- `MUT_ONLY=B16 sh test/mutation_check.sh` → `killed 1 / 存活 0 / 锚点失效 0`。
- **本 pane 独立反证**（全仓副本手工回退该行）→ `sh test/ui_static_test.sh` 恰 **1 处不符**，正是 `FAIL submitted 从 self.section.section 取 uci 名字（不直接 format 对象）`。
- 变异新值 = HEAD 原行，与真机报错形态一致 → 「回退成原缺陷必红」成立。

**(b) w38 新断言是否过度钉字面量？→ 偏钉（源码拼写耦合），但无更省的可鉴别写法；Low。**
新断言 = `"self.section.section" in sub and 'format(self.map.config, self.section,' not in sub`。钉的是**源码拼写**而非语义：任何语义等价重构（改用 LuCI 第 3 个 validate 实参、改局部变量名、换 `self:formvalue`）都会**误红**。但负面项精确锁「对象喂 `format`」这一缺陷形态。可接受，但应知其为拼写耦合。

**(c) 既有结构断言是否被削弱？→ 否。** w38 既有 6 条（两字段挂校验 / 起↔止 `gsub` 映射 / 禁链式 `gsub` / 双向 `>=` / `edit.htm a >= b`）**逐条仍在**；本轮纯新增 2 条。

**(d) “静态检查替代行为验证”的假安心？→ 存在，是本轮最大方法学风险。**
`grep -n B16 test/acceptance_test.sh` = **空**：**没有任何行为级用例覆盖编辑页保存路径**；B16 变异**只被 `ui_static_test.sh` 杀**（静态字符串匹配）。而真机 500 的本质是 **Lua 运行时对 table 调 `%s` 的类型错误** —— 恰是静态拼写匹配**无法证明已修**的一类。因此：
- 「B16 变异被杀」**只证明绊线活着**，**不证**真机保存不 500。
- 本 pane 用**只读 SSH 类模型查证 + 真机 Lua 复算表达式**补上「修复为何正确」的证据链（Q1），但那是**审查性推断**，非执行验证。
- **真机 B16 仍必须由 test pane 在设备上跑**（保存 200 / 起=止被拒 / 起<止落盘）。progress §10 已如实标注此点、未被当成行为证据；但管线侧须防「mutation 绿 = B16 绿」的误读。

### Q5. 复核输出（只读）
```
$ sh test/run.sh                                 → ALL SUITES PASS (EXIT=0)
    common 76 / init 116 / acceptance 63 / migrate 94 + 5 段静态/ lint
$ MUT_ONLY=B16  sh test/mutation_check.sh        → killed 1 / survived 0 / 锚点失效 0
$ MUT_ONLY=W38  sh test/mutation_check.sh        → killed 2 / survived 0 / 锚点失效 0
$ MUT_ONLY=W37  sh test/mutation_check.sh        → killed 1 / survived 0 / 锚点失效 0
$ MUT_ONLY=W39  sh test/mutation_check.sh        → killed 1 / survived 0 / 锚点失效 0
$ MUT_ONLY=W42  sh test/mutation_check.sh        → killed 1 / survived 0 / 锚点失效 0
```
（全量 39 个变异**未**在本 pane 重跑——单次 ~50 分钟；本轮 delta 仅 parts.lua + w38 + B16，已定向覆盖。）

### 附. 复审文档自查（前文遗留，已修）
- 本 pane 全树只读扫描真实标识（口令 / 真机 MAC / 真机 IP 具体地址）时发现：**本报告 loop-0/loop-1 的旧文里各有一处把真实口令字面量与真实设备 MAC 完整字面量写进了正文**（均出现在“验证零命中”的断言句里，属自我指涉式泄漏）。二者随本报告（`docs/`，未跟踪、拟随本轮提交）进入 = 公开仓库泄漏面。
- 已在本报告内**就地遮盖**（保留语义：改为“真实口令字面量 / 真实 MAC 完整字面量”描述，附一句遮盖说明）。该口令形态**从未**进过 git 历史（loop-0 已确认），仅需清理工作树；真实 MAC 曾在提交信息 `85d98c2` 出现过（历史层面无法回收），但工作树不再新增引用。
- 其余扫描项（真机 IP 具体地址、测试机 MAC）全树**零命中**；`test/` 内 `<lan-cidr>` 零命中；`docs/` 内 IPv4 仅 RFC 测试段（`1.2.3.4`/`192.0.2.x`/`198.18.0.1`）与通用网段描述。

### 本轮分级
| 级别 | 项 | 文件:行 |
|---|---|---|
| **无 Blocker / 无 High** | 修复正确、`validate_window` 语义未动 | `parts.lua:34-43` |
| Should-fix（测试，非阻塞） | B16 **无行为级防线**，「静态杀」易被误当「行为绿」；真机 B16 必须跑 | `ui_static_check.py:104-110` / `acceptance_test.sh`（缺） |
| Low | fail-open 静默 skip（当前不可达）；建议日志/显式化 | `parts.lua:40-43` |
| Low | w38 新断言钉源码拼写，语义等价重构会误红 | `ui_static_check.py:108-110` |
| Low | 既有第 (c) 类拼写耦合（`is_start and a >= b` 等）在「最小语义 token」目标外 | `ui_static_check.py:94-100` |
| Nit | progress §10「`self:formvalue` 带 `or self.default`」论证不精确（真机无此兜底） | `pc-acceptance-progress.md` §10 |

### 合成说明（两路）
- **两路一致（高权重）**：① `self.section.section` 对唯一调用点**正确**；② `validate_window` 语义**未动**；③ fail-open 是**潜在、当前不可达**的静默降级（Low）；④ w38 钉源码拼写；⑤ **B16 只有静态防线、无行为覆盖 = 假安心**（两路均点名，本 pane 独立确认）。
- **分歧**：代码质量路主张**用 LuCI 第 3 个 validate 实参（`self:validate(fvalue, section)` @ `cbi.lua:1426`）替代 `self.section.section`，删掉 `submitted()`** —— 结构上更贴 LuCI 契约、去掉类型嗅探；安全路认为当前修复**对实际调用点正确、非破坏**。本 pane 取：**当前修复可放行**（正确、最小、无行为回归）；代码质量路写法是**可选结构改进**（Should-fix 级建议、非阻塞），因需连同 w38 断言一起改并重跑真机 B16。

### 结论
本轮修复**正确、最小、非破坏**：`self.section.section` 经真机类模型 + Lua 复算证实为本环境唯一正确取法；`validate_window` 语义逐字未动；白盒全绿、定向变异全杀。**无 Blocker、无 High。** 两条非阻塞项：B16 缺行为级防线（真机 B16 必修）、fail-open 建议显式化；两条 Low 为测试拼写耦合。

### 本轮信号

REVIEW_PASS: A36/B16 编辑页 500 修复经真机只读查证（cbi.lua: AbstractSection.option→AbstractValue.section=对象 / NamedSection.section=名字 / Lua 5.1.5 `%s` 复算报错逐字一致）判定**正确**；validate_window 语义逐字未动；fail-open 潜在但当前唯一调用路径不可达（Low）；run.sh ALL SUITES PASS（76/116/63/94）+ 定向变异 B16/W38/W37/W39/W42 全杀、独立反证 B16 恰命中唯一断言。非阻塞：B16 仅静态防线无行为覆盖（真机 B16 须 test pane 执行）、w38 新断言拼写耦合（Low）、progress §10 论证用词不精确（Nit）。无 Blocker/High。报告：docs/superpowers/specs/pc-acceptance-review.md
