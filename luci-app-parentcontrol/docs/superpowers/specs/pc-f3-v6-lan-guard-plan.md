# pc-f3-v6-lan-guard · Plan（实施计划）

> 角色产出：**conductor**（阶段 3）。执行者：**code pane `wR:p4`**。
> 依据：`pc-f3-v6-lan-guard-design.md`（R1–R6 / D1–D11 / A1–A9 / O1–O5）+ `pc-f3-v6-lan-guard-adr.md`（ADR-1..9）。
> **本文件只写「改什么、改成什么行为、怎么算对」，不写实现代码体** —— 代码由 `wR:p4` 写，红线：conductor 一行实现代码都不写。

---

## 步骤总览

| # | 动作 | 目标文件 | 谁做 |
|---|---|---|---|
| P0 | 读 design+ADR+本文件+testplan；确认工作树干净（`git status`） | — | `wR:p4` |
| P1 | 新增 `pc_lan_nets6()` | `root/usr/lib/parentcontrol/common.sh` | `wR:p4` |
| P2 | 改写 `allow_lan_in()`（族感知） | `root/etc/init.d/parentcontrol` | `wR:p4` |
| P3 | `ip` 桩支持 `-6 route show dev <dev>` | `test/fakes/ip` | `wR:p4` |
| P4 | 夹具导出 `FAKE_IP_ROUTE6` | `test/lib.sh` | `wR:p4` |
| P5 | 新增 W 组用例（`pc_lan_nets6` 单元） | `test/common_test.sh` | `wR:p4` |
| P6 | 新增 W 组用例（v6 守卫下发/顺序/降级/幂等） | `test/init_test.sh` | `wR:p4` |
| P7 | 新增变异（白名单/族感知） | `test/mutation_check.sh` | `wR:p4` |
| P8 | 版本号 1.8.2 / 20261009 | `Makefile` | `wR:p4` |
| P9 | 跑通 `run.sh` + `mutation_check.sh` + `build_ipk.sh` | — | `wR:p4` |
| P10 | 写 progress 段 + 主动回调 `wR:p1` | `docs/…/pc-f3-v6-lan-guard-progress.md` | `wR:p4` |

---

## P1 · `pc_lan_nets6()`（`root/usr/lib/parentcontrol/common.sh`）

**位置**：紧跟 `pc_lan_nets()`（当前 `:320-331`）之后，同风格加注释。

**行为规格（必须逐条满足）**：

1. **遍历范围与 `pc_lan_nets()` 完全一致**：`uci -q show network 2>/dev/null | sed -n "s/^network\.\([A-Za-z0-9_-]*\)\.proto='static'$/\1/p"`（同一套静态接口节：真机上是 `loopback` 和 `lan`）。
2. **取设备名**：`_dev=$(uci -q get "network.$_s.device")`；为空则回退 `uci -q get "network.$_s.ifname"`。**两者都为空 → 跳过该节**（不得对空设备名调 `ip`）。
3. **唯一数据源**：`ip -6 route show dev "$_dev" 2>/dev/null`（ADR-2）。`ip` 不存在/输出为空/命令失败 → 该节产出为空，**不得报错**（`pc_lan_nets6` 必须整体返回 0）。
4. **逐行取第 1 字段**，施加 **ADR-3 格式白名单**（这是安全关键，见 A1/A4/A6）：
   - 字段所有字符必须落在 `0-9 a-f A-F : /`；
   - **至少含一个 `:`**；
   - **恰好一个 `/`**；`/` 前非空且只含 `0-9 a-f A-F :`；`/` 后非空且只含 `0-9`；
   - 任何一条不满足 → **整行丢弃**。
   - ⇒ 由此自动拒掉：`unreachable <prefix> …`（真机 `lo` 三行）、`default …`（默认路由）、`… via …`（转发路由）、`throw`、`blackhole`。
   - **⚠ 阶段 5 SF-1 增补（必做）**：白名单**挡不住**数字形式的全零前缀 `::/0`（会生成 `-d ::/0 -j RETURN` = 放行一切 → 封锁静默失效）→ **必须额外剔除零长前缀**（拒绝以 `/0` 结尾的字段）。配套：`::/0` 注入用例 W-F3-13 + 变异 M-F3-04。
5. **输出**：被接受的字段，一行一个，**`sort -u`** 去重（真机上 `ip -6 route show dev lo` 与 `br-lan` 可能给出同一前缀时只留一份）。
6. **不做任何前缀运算**（ADR-2 末段）：`ip -6 route` 给的就是 CIDR。
7. **变量命名**：函数内所有 `_` 前缀变量必须在 `local` 列表里声明（`test/lint_locals.py` 强制）；不得使用 `local a,b=`、`10#`、`<<<`、`&>`、`local -a`、`function` 等（`test/lint_ash.sh` 强制）。

**真机预期输出（3 行）**：`<lan-v6-gua>/64`、`<lan-v6-ula>/64`、`fe80::/64`。

---

## P2 · `allow_lan_in()` 改为族感知（`root/etc/init.d/parentcontrol`）

**唯一改动点**：`allow_lan_in()` 的函数体（当前 `:334-345`）。**签名保持 3 个位置参数不变**（`$1=ipcmd $2=table $3=chain`）。

**行为规格**：

1. 依据 `$1` 选数据源：`$1` 等于 `$ipt6` → 用 `pc_lan_nets6()`；否则 → 用 `pc_lan_nets()`（ADR-5 冻结的是 `pc_lan_nets()` **本体**一字不变，而非 v4 分支的行数——见下方增补）。**⚠ 阶段 5 SF-2 增补（必做）**：v4 分支必须**跳过含 `:` 的值**（等价于原 `addr_is_family "$_n" 0`），否则 `network` 静态节里含冒号的 `ipaddr` 会透传进 `iptables` —— 非法规则 + 渲染指纹与实际规则永久不一致 → 每分钟无谓重建。配套用例 W-F3-14。
2. 遍历网段，逐个 `ipt_do "$1" -t "$2" -I "$3" -d "$_n" -j RETURN`（保持走 `ipt_do`，`PC_RENDER` 渲染模式才能把守卫记进指纹）。
3. **删除** `addr_is_family "$_n" "$_fam6" || continue` 这一行及其注释。原因：族已由「选哪个数据源」决定，再过滤一次会让 v6 恒为空（这就是 F3 的根因）。**注意不要顺手删掉 `addr_is_family` 函数本身** —— `add_dev_rules()` / `add_dev_rule_single()` 仍在用。
4. `_fam6` 之类不再需要的局部变量要一并清理，`local` 列表保持 lint 通过。

**签名不动的理由（对 ADR/design 的收窄）**：`_quota_emit_rules()` 末尾已经是 `for _ip in "$ipt" "$ipt6"; do allow_lan_in "$_ip" mangle "$TAGQ"; done`（当前 `:508-531`），族由 `$1` 已经能判定；`render_quota_spec()` / `build_quota_blocks()` 因此 **完全不需要改**，`block_skip_devless()` 继续只吃 v4 网段列表。design D5 原写的「`render_quota_spec`/`_quota_emit_rules` 由 2 参改 3 参」**作废**（conductor 于阶段 3 收窄：改动面越小越好，测试仍可用 `FAKE_IP_ROUTE6` 从 `pc_lan_nets6` 端注入，无需新增参数）。

---

## P3 · `test/fakes/ip` 扩桩

- 保留现有 `neigh show` 行为（`FAKE_IP_NEIGH`）。
- **新增**：当 `$1 $2 $3 = "-6 route show"` 且 `$4 = dev` 时，从 `$FAKE_IP_ROUTE6`（**真实 `ip -6 route` 输出格式**，每行形如 `<prefix> dev <device> proto static metric 1024 pref medium`，也允许 `unreachable <prefix> dev <device> …`）里**按 `dev <device>` 过滤**后输出。
- 未设置/文件不存在 → 输出空。
- 其余子命令维持「静默 `exit 0`」（不得改成报错，否则会惊动既有用例）。
- `$5` 以外的 `dev` 写法（如 `ip -6 route show dev lo table main`）不在本轮范围。

## P4 · `test/lib.sh`

在 `t_setup` 的桩能力区（现有 `FAKE_IP_NEIGH=` 那一组）**新增** `FAKE_IP_ROUTE6=`（默认空 = 不惊动既有用例），并加进下方的 `export` 列表。注释风格与既有一致。

---

## P5–P6 · 白盒用例（详表见 `pc-f3-v6-lan-guard-testplan.md`）

- `test/common_test.sh`：**W-F3-01..06** + **W-F3-13**（`::/0` 注入，阶段 5 SF-1）（`pc_lan_nets6` 单元）。
- `test/init_test.sh`：**W-F3-07..12** + **W-F3-14**（v4 含冒号的值被跳过，阶段 5 SF-2）（v6 守卫下发、顺序、降级、幂等、指纹）。
- **⚠ W-F3-05 恒真**（阶段 5 复审指出）：必须改成可鉴别形式，见 testplan §2.1。
- **不得修改既有断言**去迁就新行为；若确实需要改，必须在 progress 里写明「哪条、为什么、改前改后」。

## P7 · 变异（`test/mutation_check.sh`）

新增 **M-F3-01 / M-F3-02 / M-F3-03 / M-F3-04**（见 testplan §5；M-F3-04 = 阶段 5 SF-1 增补）。要求：**全部 killed**，且 **锚点失效 = 0**。

## P8 · 版本（`Makefile`）

`PKG_VERSION` `1.8.1` → `1.8.2`；`PKG_RELEASE` `20261008` → `20261009`。用 **现有** `test/build_ipk.sh` 构建（ADR-8），产物 `luci-app-parentcontrol_1.8.2-20261009_all.ipk`。

## P9 · 自测闸门（全绿才算 P10）

1. `sh test/run.sh` → **`ALL SUITES PASS`**；
2. `sh test/mutation_check.sh` → **survived 0 / 锚点失效 0**，且新增 **4** 条在列；
3. `sh test/build_ipk.sh` → 构建成功；**连续两次构建 md5 相同**（可复现）；
4. 包内 28 个数据文件与仓库逐字节一致（沿用 F5 轮的自检方法）。

## P10 · 交付与回调

- 在 `docs/superpowers/specs/pc-f3-v6-lan-guard-progress.md` 追加执行小节（改了什么、测试数字、包 md5、遗留）。
- **主动回调 `wR:p1`**（conductor），消息内容：状态行 + 测试数字 + 包路径与 md5 + 是否发现新问题。
- 红线：`wR:p4` **不做真机部署、不碰路由器**（阶段 6 由 `wR:p3` 执行）。

---

## 风险与回退

| 风险 | 缓解 |
|---|---|
| 白名单写错 → 默认路由被当网段 → 封锁失效 | M-F3-01 变异必须被杀；A4 断言「`default`/`unreachable`/` via ` 一律不产出」 |
| 忘记删族过滤 → v6 恒空（原样 bug） | M-F3-02 变异必须被杀；W-F3-07 断言 v6 链确实出现守卫 |
| v4 行为被顺手改动 | W-F3-08 断言 v4 守卫仍为 `-d <ipv4>/<mask> -j RETURN` 且不受 v6 逻辑影响；A2 真机逐字节比对 |
| 设备名缺失时空调用 `ip` | P1 规格第 2 条；W-F3-05 断言无 `device` 的静态节被跳过且不报错 |
| 改动面扩大 | P2 只改 `allow_lan_in()` 函数体；`build_quota_blocks()`/`render_quota_spec()`/`_quota_emit_rules()` 保持不动 |
