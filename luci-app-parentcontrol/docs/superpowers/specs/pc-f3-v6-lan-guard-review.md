# pc-f3-v6-lan-guard — 阶段 5 复审报告（review / thermos）

> **隐私约定**：本文档不含真机标识字面量。路由器/设备/前缀一律占位符：`<router-ip>`、`<test-device-mac>`、`<managed-device-mac>`、`<test-device-ip>`、`<gua-prefix>`、`<ula-prefix>`、`<wan-gua-prefix>`、`<wan6-linklocal-gw>` 等；同环境可用文中命令复现实测值。

- 日期：2026-10-09；角色：review pane（reviewer）；conductor：`wR:p1`；task-brief：`pc-f3-v6-lan-guard`
- 基线：`HEAD = c2e0775`（本轮改动**全部未提交**）
- 复审范围：`git diff`（8 文件，**+288 / −15**）+ 未跟踪 `docs/superpowers/specs/pc-f3-v6-lan-guard-{glossary,design,adr,plan,testplan,progress}.md`；**`.build/` 不在范围**（构建产物）
- 复核资料：`pc-f3-v6-lan-guard-glossary.md` / `-design.md`（R1–R6 / D1–D11 / A1–A9）/ `-adr.md`（9 条）/ `-plan.md`（P0–P10）/ `-testplan.md`（W/M/B/R）
- **`-progress.md` 是 code pane 的自述，本报告不采信其结论**（仅用于定位改动意图）

## 0. 方法（/thermos）

按 `/thermos` 跑**两路并行**只读子代理，各自独立复核、互不可见：

1. `thermo-nuclear-review-subagent`（bug / 破坏性 / 安全 / 功能泄漏）
2. `thermo-nuclear-code-quality-review-subagent`（可维护性 / 结构 / 复杂度 / 1k 行 / code-judo）

两路都**自行重跑了 `sh test/run.sh`** 并各自写了正则/管道探针；结论在 §4 去重、交叉验证、按证据加权。
**本 pane 的独立复核（不只采信子代理）**：

| 复核项 | 命令 | 结果 |
|---|---|---|
| 全量白盒 | `sh test/run.sh` | **ALL SUITES PASS**（lint locals / ash / luci / TSV + UI 静态 42 + common 92 + init 138 + acceptance 73 + migrate 94）；W-F3-01..12 全 `ok` |
| ash 兼容 | `sh test/lint_ash.sh` | 通过（rc=0） |
| locals | `python3 test/lint_locals.py` | 通过（rc=0） |
| **白名单探针** | 复刻 `read -r pfx rest` + `case "via "` + `grep -E` | **接受 `::/0`**（见 SF-1）；拒 `default`/`unreachable`/`throw`/`blackhole`/`prohibit`/`local`/`broadcast`；` via ` 分支剔掉 `default via`、`2001:db8:2::/64 via fe80::9 …`、`2001:db8:3::/64 dev br-lan via fe80::9` |
| **定点反证（变异）** | `MUT_ONLY='M-F3-01' / 'M-F3-02' / 'M-F3-03' sh test/mutation_check.sh` | 各 **被杀 1 / 存活 0 / 锚点失效 0** → 三条新变异锚点**唯一命中且真被杀** |
| v4 冻结核对 | `git diff` 逐 hunk | `common.sh` 纯追加（`pc_lan_nets()` 一字未动）；`init.d` **单个 hunk（332-347）**，只动 `allow_lan_in` |
| 缺 `ip` 的 stderr | `sh -c 'nosuchcmd 2>/dev/null; echo rc=$?'` | `rc=127` 且**无输出** → 设计要求的「`ip` 不存在不得报错」成立（子代理的 F7 为误报，已剔除） |

### 0.1 环境/工具限制（如实声明）

1. **全量 `sh test/mutation_check.sh` 在本机不可靠**：它自己的 `trap 'rm -rf "$WORK"' EXIT INT TERM` 在收到 SIGTERM（同一 session 内并发 bash 共享信号投递）时提前删掉工作副本，导致后续 44–46 条出现 `锚点未命中` + `FileNotFoundError: …/repo/…` + `tar: Write error` + `Terminated: 15`。**这是夹具/环境假象，不是本改动的缺陷**（`docs/superpowers/specs/pc-acceptance-test-report.md` 记录该仓库安静环境下全量 39 条约 36 分钟、39 killed / 0 survived / 0 锚点失效）。故本轮以**单条隔离**跑三条新变异为准。
2. 本机（macOS）**无 busybox / iproute2 源码或二进制**，且网络被禁 → 「`ip -6 route` 到底打印 `default` 还是 `::/0`」无法在本机证伪，只能靠仓库内**真机实测记录** + 目标环境复核（见 SF-1 的证据门）。
3. 参考真机环境：**ImmortalWrt 23.05.4 x86/64，iptables-legacy 1.8.8（无 `addrtype` 模块）**（前述验收报告）。

## 1. 结论

**REVIEW_PASS** —— 按 testplan §6「阶段 5 通过条件：**无 Blocker**；证据与结论可核对」。

生产代码两处变更（新增 `pc_lan_nets6()` + `allow_lan_in()` 族感知）经逐行复核**干净且正确**：v4 在正常配置下语义冻结，v6 守卫真的下发并进入指纹，无新链/新 hook/新规则类别、无新依赖。但存在 **1 条需在本轮或下一阶段闭环的安全边界缺口（SF-1，latent）** 与 3 条工程/文档 should-fix。

| 级别 | 数量 | 摘要 |
|------|------|------|
| Blocker | **0** | — |
| Should-fix | 4 | SF-1 白名单接受 `::/0` 且 ADR-3/D11 过度声明「已堵死」；SF-2 v4 边界不再严格冻结；SF-3 静态节选择器重复；SF-4 D5 文档漂移 |
| Nit | 6 | W-F3-05 断言恒真；无 `::/0` 测试；每分钟 tick 多查路由表；render/emit 两次查表→指纹竞态；变异锚点耦合脆弱；文档把真机资产当永久事实 + README §7 未提 v6 |

---

## 2. 生产代码复审（两处，逐行）

### 2.1 `root/usr/lib/parentcontrol/common.sh:337-357` — 新增 `pc_lan_nets6()`

**判定：正确。** 逐条核对（`plan.md:36-44` 的 7 条行为规格）：

- **数据源**：只对 `proto='static'` 的 network 节取 `device`（空则 `ifname`），再 `ip -6 route show dev <dev>` —— 与「GUA 动态委派不在 UCI、ULA 在 UCI 是 /48 聚合（比实际 /64 宽）」的 ADR-2 理由一致。
- **设备缺失**：`common.sh:344` `[ -n "$_dev" ] || continue` 先于 `common.sh:345` 的 `ip` 调用 → 不会对空设备名执行 `ip`（**行为正确**；但见 N1，测试证不到这一点）。
- **` via ` 行级剔除**：`common.sh:352` `case "$_rest" in "via "*|*" via "*) continue ;; esac`。**必要且正确**——`read -r _pfx _rest` 按首个 IFS 空白切分，故 `_rest` 从 `via ` 起（命中 `"via "*`），行中段也命中 `*" via "*`。探针证实它剔掉 `2001:db8:2::/64 via fe80::9 dev br-lan`、`2001:db8:3::/64 dev br-lan via fe80::9` —— 这两条**行首是合法前缀**，白名单拦不住，必须靠这条（子代理的 (b) 问独立确认此点成立）。
- **行首白名单**：`common.sh:355` `grep -E '^([0-9A-Fa-f]*:)+[0-9A-Fa-f:]*/[0-9]+$'` → 拒 `unreachable`（真机 `dev lo` 三行）、`default`、`throw`、`blackhole`、`prohibit`、`local`、`broadcast`。**但接受 `::/0`，见 SF-1。**
- **无前缀运算**：全程字符串，无掩码/进位计算。
- **`sort -u`**：`common.sh:356` 到位（W-F3-06 断言去重后仅一次）。
- **ash/POSIX**：`local _s _dev _pfx _rest` 多名字（本文件既有用法）；`case` 带引号字面量 + glob 合法；`read -r`；无 `bash` 专有语法；两处 `while` 的变量各在自己的管道段内使用，**无子 shell 作用域 bug**；`lint_locals.py` / `lint_ash.sh` 均通过。

### 2.2 `root/etc/init.d/parentcontrol:334-346` — `allow_lan_in()` 族感知

**判定：v6 侧正确修复；v4 侧等价（一处边角例外，见 SF-2）。**

```sh
allow_lan_in() { # $1=ipcmd $2=table $3=chain
	local _nets _n
	if [ "$1" = "$ipt6" ]; then
		_nets=$(pc_lan_nets6)
	else
		_nets=$(pc_lan_nets)
	fi
	for _n in $_nets; do
		ipt_do "$1" -t "$2" -I "$3" -d "$_n" -j RETURN
	done
	return 0
}
```

- **v6 不再被过滤空**：旧路径对 v6 调 `pc_lan_nets()`（只产 IPv4）再 `addr_is_family "$_n" 1`（无 `:` → false）→ **恒 0 条守卫**（这正是本轮要修的缺陷）。新路径 v6 走 `pc_lan_nets6` → W-F3-07 断言恰好 3 条 RETURN。
- **`addr_is_family()` 必须保留**：仍被 `devcount()`（`init.d:101`）与 `add_dev_rules()`（`init.d:118`）使用，且 M-F3-02 的锚点正落在旧调用形态上。**未变成死代码**。
- **未引用变量**：`_nets`/`_n` 均 `local`；空 `_nets` 时 `for` 不执行 → 无规则、`rc=0`（R5 降级）。
- **未动**：`render_quota_spec()`（`init.d:535-546`）、`_quota_emit_rules()`（`:510-531`）、`build_quota_blocks()`（`:566-588`）、`block_skip_devless()`（`:500-506`）**零 diff**（`init.d` diff 仅一个 hunk）。
- **插入点正确**：`_quota_emit_rules()` 末尾 `for _ip in "$ipt" "$ipt6"; do allow_lan_in …; done`（`init.d:528-529`），在**所有封锁规则之后**用 `-I` 插到链首 → 守卫先于 DROP（W-F3-09 断言）。
- **指纹**：守卫经 `ipt_do` 进 `quotaspec` → v6 前缀变化会触发重建（W-F3-11），无前缀变化不动内核（计数器 4242 保留）。
- **无新链/hook/规则类别**：只是既有 `PARENTCONTROL_QUOTA`（mangle）链里多插 `-d <prefix> -j RETURN`；W-F3-12 钉住每族链数 = 2。`Makefile:11-12` 仅版本号 1.8.1/20261008 → 1.8.2/20261009，`Makefile:16` 依赖未变（无显式 `ip`/`ip-full`，但 `ip` 是 busybox 核心 applet）。

---

## 3. 重点核查逐条结论（对应用户 Q1–Q6）

**Q1｜v4 是否真的零变化？**
`pc_lan_nets()`（`common.sh:320-331`）**一字未动**；`render_quota_spec` / `_quota_emit_rules` / `build_quota_blocks` / `block_skip_devless` **零 diff**。`allow_lan_in` 的 v4 分支：旧代码 `addr_is_family "$_n" 0 || continue` 对 `pc_lan_nets()` 产出的 `ip/netmask`（无 `:`）**恒真**，故在正常配置下等价；`for _n in $_nets` 与旧 `for _n in $(pc_lan_nets)` 同为无引号按 IFS 切分，等价。**唯一例外**：旧代码对 v4 也做族过滤，若某 `proto='static'` 节的 `ipaddr` 里含 `:`（IPv6 误填），旧代码丢弃、新代码透传给 iptables（静默失败 → 实际条数少于渲染条数 → 每分钟重建）。**见 SF-2。**

**Q2｜`pc_lan_nets6()` 的正确性与安全性**
- 行首白名单**确实**拒掉 `unreachable` / `default` / `throw` / `blackhole` / `prohibit` / `local` / `broadcast`（探针逐条验证）。
- **最关键的失效模式：会。** 「不带 ` via ` 的默认路由、行首形如合法前缀」若写成 **`::/0`**，白名单**照收**，` via ` 检查也拦不住（无 ` via `）→ 生成 `-d ::/0 -j RETURN` → 整个 IPv6 地址空间在链首放行 → **v6 封锁静默失效（fail-open）**。**唯一挡住它的是 `ip` 恰好把零长前缀渲染成关键字 `default`（缺 `:` → 被拒），而非白名单本身。** 真机证据（`adr.md:44-53`、`design.md:73`）显示该 `ip` 打印 `default`（且真默认路由带 ` via `），故判定**latent**，见 **SF-1**（含一行加固补丁与真机证据门）。
- ` via ` 行级剔除：**必要且正确**（理由见 §2.1）。executor 的说法**成立**。
- 设备缺失/回退 `ifname`/空设备名：**真的跳过**，不报错、不产生 `ip … dev ""`（`common.sh:342-344`）。
- 不做任何前缀运算；`sort -u` 到位。

**Q3｜`allow_lan_in()` 族感知改法**
v6 不再被过滤空（修复生效，见 §2.2）。`addr_is_family()` **必须保留**（`init.d:101` devcount、`init.d:118` add_dev_rules 仍在用；删掉会破坏既有「v6 ↔ MAC 回退」语义与 M-F3-02 锚点）。

**Q4｜OpenWrt 目标环境兼容性**
ash/POSIX 干净（无 bashism；`local` 多名字是本文件既有用法；`case` 引号+glob 合法；`sort -u`/`grep -E`/`sed -n` 均为 busybox 支持；无 `set -e`/`set -u`/`pipefail`，函数尾为 `sort -u` 故 rc 恒 0，无 set-e 陷阱）。`ip -6 route show dev <dev>` 的输出格式假设成立（真机记录 `adr.md:44-50`；注意该输出在按 `dev` 过滤时**可能省略 `dev` 字段**，这不影响本逻辑）。两条 lint 通过。**未发现兼容性问题。**

**Q5｜测试是否真的可鉴别**
W-F3-01..12 中 **11 条可鉴别**（各自断言会在实现退化时变化）。**W-F3-05 是恒真断言**（N1）；**无任何用例注入 `::/0`**（N2，正是 SF-1 漏网的原因）。M-F3-01/02/03 **都是真杀手**：去掉白名单 → `default/throw/blackhole` 泄漏 → W-F3-02 红；退回族过滤 → v6 守卫 0 条 → W-F3-07 红；两族都用 `pc_lan_nets` → v6 链出现 IPv4 段 → W-F3-07/08 红。**单条隔离实跑：三条各 被杀 1 / 存活 0 / 锚点失效 0。** 两条既有回归锚点也保持有效：R3 `common_test.sh:216` 的 `pc_lan_nets()` 断言未改动；R4/R5 既有防自锁断言仍 PASS。

**Q6｜有没有引入新风险**
新链/hook/规则类别：**无**。新依赖：**无**。对 iPad 既有规则的影响：v4 守卫逐字节不变（`-d 192.0.2.1/255.255.255.0 -j RETURN`）；v6 侧新增的正是本轮的修复目标本身。性能：`build_quota_blocks` 每分钟 tick 一次（`init.d:784`），其中 `render_quota_spec` 会跑一遍 `pc_lan_nets6` → 稳态约 **2 次 `ip -6 route`/分钟**（loopback+lan 两节；重建时约 4 次）——量级可忽略，且与既有 v4 `pc_lan_nets` 每 tick 跑一次同构（N3）。**另发现一处极窄的潜在重建竞态**（N4）。

---

## 4. 合成说明（两路一致 / 分歧）

**两路完全一致**：无 Blocker；`::/0` 被白名单接受且 ADR-3/D11 的「堵死」声明过度（各自独立写出探针，结论相同）；W-F3-05 恒真；v4 有一处边角不再严格冻结；新链/新依赖均无。

**仅一路提出（本 pane 复核后采纳）**：
- 质量路：SF-3（静态节选择器重复）、SF-4（D5 漂移）、N5（变异锚点耦合）、N6（文档把真机资产当永久事实）。→ 采纳（§2.1 已核实两条 `uci|sed` 逐字节相同；`design.md:76/95-96` 与 `plan.md:61` 确实冲突）。
- bug 路：N4（render/emit 各自查表 → 指纹竞态）。→ 采纳为 Nit（`init.d:570` 与 `:582` 各调一次 `_quota_emit_rules` → 各查一次路由表；路由表在两次调用之间变化时，持久化指纹与实际下发不一致，下一 tick 必然重建，直到路由表稳定）。**不升级**：v6 前缀本就会变，重建是正确副作用，只是多一次重建。
- bug 路：F7（`ip` 缺失时 shell 的 "not found" 不被 `2>/dev/null` 抑制）。→ **本 pane 实测证伪**（`rc=127` 且无输出），**剔除**。

---

## 5. 发现清单（按级别）

### Blocker
（无）

### Should-fix

**SF-1｜白名单接受 `::/0`，且 ADR-3 / D11 / 代码注释把它说成「已堵死」——安全边界缺口（latent，fail-open 方向）**
- 位置：`common.sh:355`（白名单）；`common.sh:340-341`（注释）；`adr.md:61`（ADR-3 理由）；`design.md:73`（D11）；`plan.md:112`（风险表）
- 证据：
  ```
  $ printf '%s\n' '::/0 dev br-lan proto static metric 1024 pref medium' \
    | { read -r p rest; case "$rest" in "via "*|*" via "*) exit 9;; esac; printf '%s\n' "$p"; } \
    | grep -E '^([0-9A-Fa-f]*:)+[0-9A-Fa-f:]*/[0-9]+$'
  ::/0                      ← 通过；落成 -d ::/0 -j RETURN（init.d:343）
  ```
  ADR-3 的中文是「**用一条正则同时拒掉 `unreachable` / `default` / `throw` / `blackhole` / 任何非前缀行首，不需要逐个枚举——枚举法总会有遗漏，白名单不会**」。这个保证**不成立**：`::/0` 是合法前缀语法。
- 为什么仍判 Should-fix 而非 Blocker：仓库内**真机实测**（`adr.md:44-50`）显示该 `ip` 对零长前缀打印关键字 `default`（被拒），真默认路由带 ` via `（被拒）；且「LAN 网桥上出现不带 ` via ` 的默认路由」本身近乎不可能（下游路由器通告必带 ` via `）。即：**在当前目标 `ip` 上不可利用**。
- 建议（一行，建议本轮闭环）——在 `common.sh:352` 之后加零长前缀排除，并补测试+变异：
  ```sh
  case "$_rest" in "via "*|*" via "*) continue ;; esac
  # 零长前缀（::/0）= 默认路由 = 整个互联网，不是「家里」；白名单与 via 检查都拦不住它
  case "$_pfx" in */0) continue ;; esac
  ```
  并把 `test/common_test.sh:307` 的注入表加一行 `::/0 dev br-lan proto static metric 1024`，再加一条变异（去掉上面这行）由 W-F3-02 杀掉。
- **证据门（升级条件）**：真机执行 `ip -6 route show | grep -nE '^\s*(::/0|default)'` 与 `ip -6 route show dev <lan-dev>`；**若任何一条零长前缀打印为 `::/0`，本条立即升级为 Blocker，本轮不得上线。** 建议并入 testplan 的 B-F3 真机项。

**SF-2｜v4 边界不再严格冻结：`addr_is_family` 过滤从 v4 路径一并移除**
- 位置：`init.d:334-346`（旧：`addr_is_family "$_n" "$_fam6" || continue` 对两族都生效）
- 证据：旧代码对 v4 传 `_fam6=0`，`addr_is_family "<含 : 的串>" 0` → false → 丢弃；新代码 v4 分支无任何过滤。若某 `proto='static'` 节的 `ipaddr` 误填 IPv6，`pc_lan_nets()` 会产出它 → `iptables -d <v6cidr> -j RETURN` 静默失败 → 实际条数 < 渲染条数 → `live_rule_count` 校验不过 → **每分钟无条件重建**（`init.d:566-574`）。这与 ADR-5「v4 语义冻结 / 零 diff」的措辞相冲突。
- 现实性：低（OpenWrt 约定 `ipaddr` = v4、`ip6addr` = v6）。建议二选一：① 恢复 v4 侧过滤（`addr_is_family "$_n" 0 || continue`，等价于只收无 `:` 的段）；② 或在 ADR-5 明确「v4 冻结 = 正常配置下等价，唯一例外是非法的含 `:` ipaddr」。

**SF-3｜静态节选择器逐字节重复，族对称不变量只靠复制粘贴维持**
- 位置：`common.sh:322-323`（v4）与 `common.sh:339-340`（v6）：
  ```sh
  uci -q show network 2>/dev/null \
      | sed -n "s/^network\.\([A-Za-z0-9_-]*\)\.proto='static'$/\1/p" \
  ```
- 证据：`diff <(sed -n '322,323p' common.sh) <(sed -n '339,340p' common.sh)` 无差异。`design.md` P1 要求「遍历范围与 `pc_lan_nets()` 完全一致」——该不变量目前只存在于两段重复文本里，任一侧改了 sed 口径就会出现两族面对不同节集合的漂移（历史上本仓库正因「两处解析器不同步」出过 TSV 静默错值事故，见 README 测试节）。
- 建议：抽一个 `pc_static_ifaces()`（返回节名列表），`pc_lan_nets()` / `pc_lan_nets6()` 各自做薄映射。

**SF-4｜D5 文档漂移未闭环（design 里留着与代码相反的指令）**
- 位置：`design.md:76`（`| **D5** | render_quota_spec() 与 _quota_emit_rules() 签名改为 **3 参** … |`）与 `design.md:95-96`（接口段 `← 由 2 参改 3 参`）；对照 `plan.md:61`（P2：`design D5 原写的…**作废**`）与代码 `init.d:334/535/510`（**签名未动**）。
- 证据：`progress.md` 只把这记为「差异备案」，**从未回改 design**。只读 `design.md` 的实现者会去做一次不存在的签名改造。
- 建议：在 `design.md:76` 与 `:95-96` 就地标注「（作废 → 见 plan P2）」而不是留给读者自行发现。（注：design/adr/plan 由 conductor 维护，review pane 不代改。）

### Nit

| ID | 位置 | 说明 |
|----|------|------|
| **N1** | `test/common_test.sh:338-352` + `test/fakes/ip:16-19` | **W-F3-05 恒真**：桩按 `$i=="dev" && $(i+1)==d` 过滤，`d=""` 时任何 token 都不等于空串 → 输出同样为空。所以「跳过空设备节」与「对空设备名调 `ip`」在本用例下**不可区分**（真 `ip` 报错也被 `2>/dev/null` 吞掉）。该用例标题声称「不对空设备名调 ip」，实际只断言了空输出+rc=0。**建议**：给 `ip` 桩加调用日志/标记文件，断言该节下 `ip` **从未被调用**；并补一条变异（删 `common.sh:344` 的 `|| continue`）由它杀掉。 |
| **N2** | `test/common_test.sh:306-314` | 无任何用例注入 `::/0`（只注 `default` / `default from … via …` / `throw` / `blackhole` / ` via `）→ SF-1 对测试不可见。建议随 SF-1 一并补。 |
| **N3** | `init.d:784` → `:570` → `common.sh:337-345` | 每分钟 tick 的「有没有变」快路径也会实时查路由表：稳态约 2 次 `ip -6 route`（+`uci show network`、每静态节 1–2 次 `uci get`）；重建时约翻倍。量级可忽略（与 v4 `pc_lan_nets` 每 tick 同构），仅记录。 |
| **N4** | `init.d:570` 与 `:582` | `build_quota_blocks` 先 `render_quota_spec`（内部 `_quota_emit_rules` → `pc_lan_nets6`）算指纹，再单独 `_quota_emit_rules` 真下发（再查一次路由表）。两次之间路由表变化 → 指纹与实际下发不一致 → 下一 tick 必然重建，直到稳定。极窄，且重建方向安全。 |
| **N5** | `test/mutation_check.sh:352-376` | M-F3-02 与 M-F3-03 内嵌**同一段 ~7 行 `allow_lan_in` 正文（含中文注释）**，将来任何注释/缩进改动会**同时**打断两条锚点（`SKIPPED` → `exit 1`）。建议每条变异用各自最小的独立锚点。 |
| **N6** | `design.md` A2/D10、`adr.md` ADR-7、`README.md:142-153` | ① 文档把真机资产（`iPad-v4 指纹 4de4df07…`、`iPad-v6 指纹 3f2ab84d…`）当**永久事实**断言，实为「某日实测快照」，建议标注日期/可复现命令。② `README` §7「防自锁」仍只描述 v4「到局域网网段 → RETURN」，本轮把 v6 也补上了，README 未同步（建议补一句「v6 走内核 on-link 路由表」）。 |

---

## 6. 判定

- 无 Blocker，证据与结论可逐条核对 → **本阶段通过**。
- **必须闭环（建议本轮，最迟与阶段 6 并行）**：SF-1 的一行加固 + 真机证据门；SF-2 二选一收敛；SF-3/SF-4 属工程与文档卫生，可随下一轮清理。
- 阶段 6（test pane）请注意：全量 `test/mutation_check.sh` 在本机（并发/信号共享）会假失败，请在安静环境跑或以 `MUT_ONLY=` 单条跑；`::/0` 的真机复核属于 SF-1 的证据门，务必执行。

REVIEW_PASS: 无 Blocker。生产代码两处变更（新增 `pc_lan_nets6()` + `allow_lan_in()` 族感知）逐行复核干净、正确，v4 在正常配置下语义冻结、v6 守卫真下发且进入指纹，无新链/新依赖。遗留 4 条 Should-fix——①（latent，最高优先）白名单接受 `::/0`，ADR-3/D11 声称的「已堵死默认路由」不成立，需一行加固 + 真机 `ip -6 route` 证据门（若真机打印 `::/0` 则升级为 Blocker）；② v4 边界不再严格冻结（含 `:` ipaddr 的边角）；③ 静态节选择器逐字节重复；④ design D5 与 plan P2 冲突未回改——另有 6 条 Nit（W-F3-05 恒真、无 `::/0` 用例、每 tick 查路由表、render/emit 指纹竞态、变异锚点耦合、文档把真机快照当永久事实且 README §7 未同步 v6）。

---

## 附：Conductor 裁定（阶段 5 收口，2026-10-09）

> 本节由 **conductor（`wR:p1`）** 追加，**不属于 reviewer 的原始报告**。裁定基于复审findings + conductor 的独立只读核实。

### 证据门核实结果（SF-1 的「真机 ip 是否出现 `::/0`」）

**已核实，2026-10-09，真机只读（不改任何配置）**：

```
$ ip -6 route show
default from <wan-gua> via <wan6-linklocal-gw> dev eth1 proto static metric 512 pref medium
default from <wan-gua-prefix> via <wan6-linklocal-gw> dev eth1 proto static metric 512 pref medium
default from <gua-prefix> via <wan6-linklocal-gw> dev eth1 proto static metric 512 pref medium
<wan-gua-prefix> dev eth1 proto static metric 256 pref medium
unreachable <wan-gua-prefix> dev lo proto static metric 2147483647 pref medium
<gua-prefix> dev br-lan proto static metric 1024 pref medium
unreachable <gua-prefix> dev lo proto static metric 2147483647 pref medium
<ula-prefix> dev br-lan proto static metric 1024 pref medium
unreachable <ula-prefix> dev lo proto static metric 2147483647 pref medium
fe80::/64 dev eth1 proto kernel metric 256 pref medium
fe80::/64 dev br-lan proto kernel metric 256 pref medium
```

- 首字段为 `::/0` 的行数 = **0**；三行默认路由均由 busybox `ip` 打印为 **`default from … via …`**。
- ⇒ **SF-1 维持 Should-fix（潜在 fail-open），不升级 Blocker。**
- 但**白名单确实接受 `::/0`**（conductor 已用正则逐字符验证），故文档中「白名单已堵死默认路由」的表述**属于过度声明**，必须修正（已完成）。

### 各 finding 的处置

| 编号 | 处置 | 说明 |
|---|---|---|
| **SF-1**（`::/0` fail-open + 文档过度声明） | ✅ **修**（回 `wR:p4`） | 代码：`pc_lan_nets6()` 增加**零长前缀排除**；测试：新增 `::/0` 注入用例 **W-F3-13** + 变异 **M-F3-04**；文档：ADR-3 与 design D11 的过度声明**已由 conductor 修正**。 |
| **SF-2**（v4 边界不再严格冻结） | ✅ **修**（回 `wR:p4`） | 代码：`allow_lan_in()` **v4 分支跳过含 `:` 的值**（恢复改动前语义）；测试：新增用例 **W-F3-14**；文档：design D4 已补注。 |
| **SF-3**（静态节选择器两处重复） | 🟡 **接受，暂不修** | 唯一的去重办法是把选择器抽成公共函数，而这**必须改动 `pc_lan_nets()`**——违反 ADR-5「v4 一字不改」的冻结约束，且会让阶段 6 的真机逐字节比对证据作废。**2 行重复 < 破坏 v4 冻结的代价**。记为技术债，候补：下一个不改 v4 语义的版本里再抽。 |
| **SF-4**（design D5 与 plan P2 冲突） | ✅ **已修**（conductor 直接改） | design.md D5 已改写为「**作废**」并注明理由；§3 接口定义里的 3 参签名已改回 2 参。**文档冲突是 conductor 的产出缺陷，由 conductor 自己修**。 |
| **Nit-1**（W-F3-05 恒真） | ✅ **修**（回 `wR:p4`） | 恒真断言 = 虚假保证，必须变成可鉴别形式（testplan §2.1 已给出两种改法）。 |
| **Nit-2**（无用例注入 `::/0`） | ✅ **已并** | 由 W-F3-13 覆盖。 |
| **Nit-3**（每 tick 约 2 次 `ip -6 route`） | 🟡 **接受** | 真机是 x86/64，每次 tick（60 s）多 2 次 `ip` 调用开销可忽略；且这是「只读内核表」的唯一可靠来源（ADR-2）。**不为此引入缓存**——缓存会带来失效/陈旧风险，得不偿失。 |
| **Nit-4**（render/emit 两次查表 → 指纹竞态） | 🟡 **接受** | 后果分析：若两次查表之间路由表变化，则「写入 `quotaspec` 的指纹」与「实际下发的规则」不一致 → **下一 tick 检测到不一致 → 全量重建 → 自愈**。属**自纠正**的良性竞态，且改掉它需要改签名（正是 D5 作废要避免的）。 |
| **Nit-5**（M-F3-02/03 锚点同段耦合） | 🟡 **接受** | 变异工具每次 `run_mut` 结束都会从仓库还原文件，且两条变异各自锚点唯一命中；耦合只影响「新增第三条变异时的可读性」，不影响结果。 |
| **Nit-6**（文档把真机指纹当永久事实 + README §7 未同步 v6） | ✅ **已修**（conductor 直接改） | README §7 已补「两个族都有这条守卫 / IPv6 取自内核路由表 / 1.8.2 起补齐」。指纹数值本身在 testplan 里已标注为「2026-10-09 实测基线」（快照，非永久事实）。 |

### 结论

- 原始复审结论 **REVIEW_PASS（无 Blocker）** 成立，conductor 采纳。
- 但因存在 **2 条下令修（SF-1 / SF-2）+ 1 条测试加固（Nit-1）**，按 skill 的 gate 口径（`REVIEW_PASS` 须无 Should-fix）**本轮不算全绿** → **触发 loop**：文档已由 conductor 修好，代码/测试修复回 `wR:p4`，完成后**重跑阶段 5**（针对增量复评）。


---

## 附：阶段 5′ 增量复审（reviewer，2026-10-09）

**范围**：**仅本轮 delta**（相对阶段 5 复审后的工作区；`HEAD` 仍为 `c2e0775`）。生产文件只有 `root/usr/lib/parentcontrol/common.sh`、`root/etc/init.d/parentcontrol`；另 `README.md`（§7）、`test/common_test.sh`、`test/init_test.sh`、`test/mutation_check.sh`。`.build/` 排除。
**方法**：只审「修复是否正确 + 是否新引入问题」，不重审全量。全部结论由本 pane 独立复核（读码 + 探针 + 隔离实跑变异 + 与 `HEAD` 对照），**不采信 code pane 自述**。

### 判定

**`DELTA_REVIEW_PASS`** —— **Blocker 0 / Should-fix 0 / Nit 7**。
三条下令修的 finding（SF-1 / SF-2 / Nit-1）**全部核实到位**，且**未引入新的 Blocker/Should-fix**。

### 本轮 delta 实际改了什么（逐行核对，与自述一致）

| 文件 | 改动 |
|---|---|
| `common.sh:354-358` | `pc_lan_nets6()` 第 2 个 `while` 内、` via ` 排除**之后**、白名单 `grep` **之前**新增 `case "$_pfx" in */0) continue ;; esac`（`common.sh:357`） |
| `init.d:340-348` | v4 分支改 `_nets=$(pc_lan_nets \| grep -v ':')`，v6 分支 `_nets=$(pc_lan_nets6)`；删掉 `addr_is_family "$_n" "$_fam6" \|\| continue`；`return 0` 保留 |
| `README.md:147-152` | §7 补「两个族都有这条守卫 / IPv6 取自内核路由表 / 1.8.2 起补齐」 |
| `common_test.sh:335-341` | W-F3-05 加「对照组」；新增 W-F3-13 / W-F3-14 |
| `init_test.sh:938-990` | 新增 W-F3-14 |
| `mutation_check.sh:370-383` | 新增 M-F3-04；M-F3-02/M-F3-03 锚点随新代码正文更新 |

### A. SF-1 是否真被堵死？—— 现实路径已堵死；非规范零长写法仍漏（不可达）

`case "$_pfx" in */0)` 是「字段以 `/0` 两字符结尾」的判定。实测（探针，逐条喂进完整管道）：

| 行首字段 | `*/0` | 白名单 `grep -E` | 最终 |
|---|---|---|---|
| `::/0` | REJECTED | passes | **丢弃** ✅ |
| `0:0:0:0:0:0:0:0/0` | REJECTED | passes | **丢弃** ✅ |
| `::0/0` / `0::/0` / `0:0::/0` / `0000::/0` | REJECTED | passes | **丢弃** ✅ |
| `::/00` | passes-case | passes | **泄漏** ❌ |
| `::/000` / `::/0000000000` | passes-case | passes | **泄漏** ❌ |
| `2001:db8:1::/64` / `fe80::/64` | passes | passes | 产出 ✅ |

- **`*/0` 并不「恰好覆盖」零长前缀**：它只覆盖「字面以 `/0` 结尾」的写法，不覆盖**数值为 0 但长度字段带前导零**的 `::/00` 一类。
- **但不可达**：唯一数据源是 `ip -6 route show dev <dev>`，输出由内核 netlink 渲染，长度字段是十进制规范形（且 /0 打印成关键字 `default`，已被白名单拒）。非规范 `/00` 不可能出现。conductor 的真机只读证据（review.md 裁定节：`ip -6 route show` 全表中首字段为 `::/0` 的行数 = 0）与此一致。
- 因此：**SF-1 的 fail-open 现实风险已消除**；残差列为 Nit（见 §E-N1）。放宽到等价写法 `*/0*`（一个字符）或把白名单收紧为 `/[1-9][0-9]*$` 可彻底闭合，**且两者都不触碰 O1（v4 冻结）与 O2（不新增规则类别）**——改动只在 `pc_lan_nets6()` 这个 v6 新函数内部。注意：改白名单正则会使 M-F3-01 的锚点失效，需同步改锚点。

### B. SF-2 的 v4 语义是否与改动前逐值等价？—— 等价（现实取值全集）

原语义：`addr_is_family "$_n" 0` ⇒ `case "$_n" in *:*) [ 0 = 1 ](false) ;; *) [ 0 = 0 ](true) ;; esac` ⇒ **当且仅当 `$_n` 不含 `:` 时保留**。新语义：`grep -v ':'` ⇒ **当且仅当该行不含 `:` 时保留**。

实测等价表（旧函数 vs 新过滤器，逐值比对）：

```
192.0.2.1/255.255.255.0   old:KEEP  new:KEEP  SAME
fd00::1/255.255.255.0     old:DROP  new:DROP  SAME
(空)                      old:KEEP  new:KEEP  SAME
10.0.0.1/255.0.0.0        old:KEEP  new:KEEP  SAME
a:b                       old:DROP  new:DROP  SAME
/                         old:KEEP  new:KEEP  SAME
```

唯一不等价情形：**同一输出行内既有空格又有冒号**（旧代码按词过滤、新代码按行过滤）。这要求 `network` 静态节的 `ipaddr` 同时含空格与冒号（如 `ipaddr='a b:c'`），现实中不存在，且旧行为产出的 `-d a` 本身也是非法规则。⇒ 记 Nit（§E-N5），不影响 A2/R3。

`pc_lan_nets()` 一字未动、`render_quota_spec` / `_quota_emit_rules` / `build_quota_blocks` / `block_skip_devless` 仍零 diff；v4 分支新增的只是一个过滤器，`return 0` 保留 ⇒ **R3/A2（v4 逐字节）成立**，并由 W-F3-08（v4 规则集不随 v6 数据变化）+ W-F3-07（v4 守卫仍是 `-d 192.0.2.1/255.255.255.0 -j RETURN`）+ 全量套件（含 acceptance/migrate 的 v4 精确断言）佐证。

### C. 新引入问题核查 —— 无 Blocker/Should-fix

- **`grep -v ':'` 无匹配行返回 1**：实测 `rc=1`。两个生产文件**均无 `set -e`/`set -u`/`pipefail`**（`grep -n 'set -'` 只命中 `set --` 位置参数用法；`init.d` shebang 为 `#!/bin/sh /etc/rc.common`），命令替换的退出码不被检查；`allow_lan_in()` 末尾 `return 0` 有兜底 ⇒ **无害**（独立确认，与你的判断一致）。
- **`for _n in $_nets` 空值/词分割**：`_nets` 为空 → 循环不执行 → 零规则、`rc=0`（R5 降级）；词分割是有意为之（改动前 `for _n in $(pc_lan_nets)` 同样依赖 IFS 切分）。
- **`_nets` 未加引号是否被放大**：未放大。旧代码的 `for _n in $(pc_lan_nets)` 同样未加引号，word-splitting 与 pathname expansion 语义完全一致（`_nets` 只是把命令替换的结果先落进变量，最终仍在同一个 `for` 里切分）。取值集合与改动前相同 ⇒ 无回归。
- **`local _nets _n` 多名字**：本文件既有用法（原 `local _n _fam6`），ash 通过；`lint_locals.py` / `lint_ash.sh` 均通过。
- **无新链/hook/规则类别、无新依赖**：未变；W-F3-12 仍钉住每族链数 = 2（A7）。
- **预先存在的 stderr 噪声（非本 delta 引入，但值得顺手处理）**：见 §E-N6。

### D. 新用例/变异可鉴别性

| 项 | 实跑证据 | 结论 |
|---|---|---|
| **W-F3-14** | 在**临时副本**（`/tmp/pcdelta`，非仓库）只做一个最小变异：`_nets=$(pc_lan_nets \| grep -v ':')` → `_nets=$(pc_lan_nets)`；跑 `sh test/init_test.sh` → `FAIL W-F3-14: v4 链不出现含冒号的 ipaddr` + `FAILED (1/140 checks failed)` | **可鉴别**，且**唯一定向**抓住「删掉 `grep -v ':'`」（其余 139 项仍 ok） |
| **W-F3-13** | `MUT_ONLY='M-F3-04'`（去掉零长前缀排除）→ `被杀 1 / 存活 0 / 锚点失效 0` | **可鉴别** |
| **M-F3-01 / M-F3-02 / M-F3-03**（锚点因本轮代码正文变化而重写） | 三条单条隔离实跑 → 各 `被杀 1 / 存活 0 / 锚点失效 0` | **锚点仍唯一命中**，未因正文改动而失效 |
| 全量 | `sh test/run.sh` → `ALL SUITES PASS`；W-F3-01..14 **全 ok**；lint 三项通过 | 修复未破坏既有断言 |

**W-F3-13 的夹具串扰（你问的那点）**：是的，它 `cat >>` 到 `W-F3-05`/`W-F3-06` 遗留的 `$FAKE_IP_ROUTE6`（`W-F3-06` 自己**不写**该文件），并沿用 `W-F3-06` 的 `net6c.uci`（两节同 `dev br-lan`）。**当前断言值正确**（遗留内容恰好是唯一一行 `2001:db8:1::/64 dev br-lan …`，两节 × 该行 + 新增 2 行零长前缀 → `sort -u` 后正是 `2001:db8:1::/64`），但属**隐式顺序耦合**：改动 W-F3-05/06 的路由文件内容会静默改变 W-F3-13 的语义 ⇒ 记 Nit（§E-N2）。

### E. Nit 清单（7 条，均不阻塞）

| ID | 位置 | 说明 |
|---|---|---|
| **N1** | `common.sh:357` | `*/0` 不覆盖非规范零长写法（`::/00`、`::/000`）。**内核 `ip -6 route` 不可能产出**，故不可达；若要彻底闭合：`*/0*`（一字符）或白名单收紧为 `/[1-9][0-9]*$`（后者需同步改 M-F3-01 锚点）。另 W-F3-13 只注入了 `::/0` 与 `0:0:…:0/0`，未注入 `/00` 形态。 |
| **N2** | `common_test.sh:333-341` | W-F3-13 依赖 W-F3-05/06 遗留的 `$FAKE_IP_ROUTE6` 与 cfg（隐式顺序耦合），当前正确但脆；建议自带 `cat > "$FAKE_IP_ROUTE6"`。 |
| **N3** | `mutation_check.sh:370-383` | 没有**专门**针对「v4 丢 `grep -v ':'`」的变异（M-F3-03 会顺带杀掉，但它同时破坏族分派）。W-F3-14 的可鉴别性目前只由本次定向实验证明；建议补一条只改 v4 分支的变异。 |
| **N4** | `common_test.sh:335-341` | 「对照组」消除了「实现恒空」这类恒真，但**仍未证明**「跳过该节」与「用空设备名调 `ip`」可区分（桩无调用日志，`$5=""` 时 awk 恒不匹配）——原 Nit-1 的原始命题仍有缺口；补一个桩调用标记文件即可。 |
| **N5** | `init.d:348` | `grep -v ':'` 与 `addr_is_family "$_n" 0` 仅在「同一行既有空格又有冒号」时不等价（需 `ipaddr` 同时含空格与冒号）。纯理论，不影响 A2/R3。 |
| **N6** | `init.d:622` + `common.sh:313` | **预先存在**：`sample_counters()` 里的 `active_acct_keys \| grep -qx "$_k"`，`grep -q` 命中即退出 → SIGPIPE → `pc_active_keys` 的 `echo "${_m}_${_i}"` 报 `common.sh: line 313: echo: write error: Broken pipe`。对照实测：`HEAD` 上**同样存在**（2 次，位置相同），本 delta 因新增用例触发次数 2 → 7；`common.sh:313` 与 `HEAD` 逐字符相同 ⇒ **非本 delta 引入**。真机 syslog 也会刷，建议顺手 `2>/dev/null` 或改用 `grep -qx "$_k" <<EOF`。 |
| **N7** | `init.d:341`、`plan.md:57` | 措辞：「v4：语义冻结（F3 ADR-5），仍走 uci 静态节，**一字不改**」/ plan「（v4 路径**一字不变**，ADR-5）」在 v4 分支实际已改的当下**字面不准**；紧邻的 SF-2 增补文字已澄清，建议把首行改为「v4 选择口径不变，仅新增『跳过含 `:` 的值』」。 |

### 复核用命令（可复现）

```
sh test/run.sh                                                  # ALL SUITES PASS, W-F3-01..14 全 ok
MUT_ONLY='M-F3-01' sh test/mutation_check.sh                    # 被杀 1 / 存活 0 / 锚点失效 0
MUT_ONLY='M-F3-02' sh test/mutation_check.sh                    # 同上
MUT_ONLY='M-F3-03' sh test/mutation_check.sh                    # 同上
MUT_ONLY='M-F3-04' sh test/mutation_check.sh                    # 同上
git show HEAD:root/usr/lib/parentcontrol/common.sh | sed -n 313p  # 与工作区同 → 噪声非本 delta 引入
```

---

## 附：Conductor 对阶段 5′ Nit 1–7 的裁定（2026-10-09）

阶段 5′ 结论 **DELTA_REVIEW_PASS**：Blocker 0 / Should-fix 0 / Nit 7 ⇒ **gate 通过**。逐条裁定：

| Nit | 裁定 | 理由 |
|---|---|---|
| **N1** `*/0` 不覆盖 `::/00`、`::/000` | 🟡 接受为残差 | 唯一数据源是内核 FIB（`ip -6 route`），内核打印规范形、长度无前导零 → **不可达**。加固写法已列入残差清单 |
| **N2** W-F3-13 依赖 W-F3-05/06 遗留夹具 | 🟡 接受为残差 | 断言值经复核正确、当前可鉴别（M-F3-04 实测杀掉）；脆但不假 |
| **N3** 无常驻变异保护 SF-2 | 🟡 接受为残差 | 增量评审批次已做**定向实验**（v4 分支还原 → W-F3-14 变红且仅此 1/140）⇒ 可鉴别性已有证据，缺的只是常驻条目 |
| **N4** W-F3-05 对照组仍不能区分「跳过」与「空设备名」 | 🟡 接受为残差 | 两者判据等价（均不产出前缀）；区分需给桩加调用日志能力，超出本任务范围 |
| **N5** `grep -v ':'` 与 `addr_is_family 0` 的理论差异 | 🟡 接受 | 需 `ipaddr` 同时含空格与冒号（UCI 中不可能），纯理论，不影响 A2/A3/R3 |
| **N6** `init.d:622`+`common.sh:313` SIGPIPE `write error: Broken pipe` | 🟡 接受，**转独立跟进项** | 对照 `HEAD` 逐字符相同 ⇒ **非本 delta 引入**，本 delta 仅使触发 2→7 次。属既有噪声缺陷，不在 F3 范围 |
| **N7** 「v4 一字不改」字面不准 | ✅ 文档侧已修；**代码注释有意不动** | `plan.md:57` 已改写为「ADR-5 冻结的是 `pc_lan_nets()` **本体**一字不变，而非 v4 分支的行数」。`init.d:341` 注释**不改**：改它会作废已通过复审并打包的产物（`56db2abf…`），且紧邻 342–345 行已写清 `grep -v ':'` 的来由，不构成误导 |

### 残差清单（转后续轮次，均不阻塞本次发布）

1. `pc_lan_nets6()` 零长前缀排除加固：`*/0` → `*/0*`（或白名单收紧 `/[1-9][0-9]*`，需同步 M-F3-01 锚点）。
2. W-F3-13 夹具自包含化（不再依赖前序用例遗留的 `FAKE_IP_ROUTE6`/`cfg`）。
3. 新增常驻变异条目以保护 SF-2（只改 v4 分支）。
4. W-F3-05 对照组强化（需给 `test/fakes/ip` 加调用日志桩能力）。
5. 【独立缺陷，非 F3】`init.d:622` + `common.sh:313` 的 SIGPIPE `write error: Broken pipe` 噪声（建议 `2>/dev/null` 或 here-string）。
