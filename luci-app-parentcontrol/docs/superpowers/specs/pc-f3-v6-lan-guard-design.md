# pc-f3-v6-lan-guard · Design / Spec

> 流水线任务：修复 **F3 —— IPv6 配额链缺少「放行局域网」守卫**
> 角色产出：本文件由 **conductor**（阶段 1）编写。code/review/test 只读不改。
> 隐私：本仓库为公开仓库，全文使用占位符（`<lan-v4-cidr>` / `<lan-v6-gua>` / `<lan-v6-ula>` / `<test-device-mac>` / `<router-lan-ip>`），不写真实设备 MAC/IP、口令。

---

## 0. 背景与问题（F3）

`PARENTCONTROL_QUOTA`（mangle 表）是「可用时段之外 / 额度耗尽」的封锁链。**IPv4 侧链首有两条守卫**（先放行到局域网与路由器自身，避免管理员把自己锁在门外）：

```
-A PARENTCONTROL_QUOTA -d <lan-v4-cidr> -j RETURN
-A PARENTCONTROL_QUOTA -d 127.0.0.0/8 -j RETURN
```

**IPv6 侧一条都没有**（真机实测 39 条规则，全部 DROP）。

### 根因（已读码确认）

| 位置 | 代码 | 后果 |
|---|---|---|
| `root/usr/lib/parentcontrol/common.sh:320-331` | `pc_lan_nets()`：`uci show network` 里取 `proto='static'` 的节，输出 `ipaddr/netmask` | **只产出 IPv4 网段** |
| `root/etc/init.d/parentcontrol:334-345` | `allow_lan_in()`：`_fam6=1` 时 `addr_is_family "$_n" "$_fam6" \|\| continue` | v6 路径把每个 IPv4 网段都 `continue` 掉 → **v6 零守卫** |
| `root/etc/init.d/parentcontrol:508-531` | `_quota_emit_rules()` 末尾 `for _ip in "$ipt" "$ipt6"; do allow_lan_in …` | 两个族都调用，但 v6 分支不产出任何规则 |

原注释已自认此点：`# pc_lan_nets 只产出 IPv4 网段；往 ip6tables 里插 IPv4 网段只会静默失败`。

### 真机证据（2026-10-08/09，只读采集）

- br-lan 同时持有 GUA `<lan-v6-gua>/64`（ISP 动态委派）、ULA `<lan-v6-ula>/64`（`network.globals.ula_prefix` 来源）、`fe80::/64`。
- 受管设备**真实在用 IPv6**：`ip -6 neigh show dev br-lan` 里 `<test-device-mac>` 等 MAC 有 REACHABLE 的 GUA 邻居地址。
- `network.lan.proto='static'`、`network.lan.device='br-lan'`、`network.lan.ip6assign='60'`。
- `ip -6 route show dev br-lan` 输出（直连路由 = on-link 前缀）：
  ```
  <lan-v6-gua>/64 proto static metric 1024 pref medium
  <lan-v6-ula>/64 proto static metric 1024 pref medium
  fe80::/64 proto kernel metric 256 pref medium
  ```

### 危害

v6 封锁窗口内，受管设备访问**局域网内 IPv6 目标**（含路由器自身管理地址）会被本功能 DROP。其中最危险的一类是 `block_entry()`（`init.d:464`）经 `emit_entry_targets` 下发的**解析目标 IP 段规则**：

```
-A PARENTCONTROL_QUOTA -d <resolved-ipv6-cidr> -m mac --mac-source <test-device-mac> -m time … -j DROP
```

它**没有端口约束、没有 `-m string` 约束**，是无条件 DROP；一旦该段与局域网 on-link 段重合，管理员/局域网互访会被封死。v4 靠链首守卫挡住这类误伤，v6 目前没有任何保护。

---

## 1. 功能需求（用户可观测行为）

| # | 需求 |
|---|---|
| R1 | 封锁窗口内，受管设备访问**局域网内 IPv6 目标**（含路由器自身 v6 管理地址）**不被本功能 DROP**——即行为与 IPv4 侧一致。 |
| R2 | 封锁窗口内，受管设备访问**非局域网**目标的小红书相关流量**仍被 DROP**——守卫不得成为绕过口。 |
| R3 | IPv4 侧行为**完全不变**（规则集逐字节一致）。 |
| R4 | 守卫只在**既有** `PARENTCONTROL_QUOTA` 链内以 `-j RETURN` 形式新增；不新建链、不新增 hook 点、不新增规则类别。 |
| R5 | LAN 无 IPv6 时（无 on-link v6 前缀）优雅降级：不下发任何 v6 守卫，其余行为不变。 |
| R6 | 与既有「规则集未变则不重建」（F1/F2 修复）协同：v6 守卫纳入 `quotaspec` 指纹；连续 tick 不抖动、不堆叠。 |

---

## 2. 技术决策（全部写死，不许"待定"）

| # | 决策 |
|---|---|
| **D1** | 新增 `pc_lan_nets6()`，位置紧跟 `pc_lan_nets()` 之后（`root/usr/lib/parentcontrol/common.sh`，约 331 行后）。 |
| **D2** | `pc_lan_nets6()` 的**唯一数据源**是 `ip -6 route show dev <dev>`：遍历 `uci show network` 中 `proto='static'` 的节，取 `device`（缺省回退 `ifname`）；**只接受第 1 字段匹配 `^[0-9a-fA-F:]+/[0-9]+$` 的行**（白名单，见 D11），其余整行丢弃；**并额外剔除零长前缀（以 `/0` 结尾，见 D11 与阶段 5 SF-1）**；再 `sort -u` 去重。 |
| **D11** | **行首格式白名单（安全关键）**：`pc_lan_nets6()` 只接受形如 `<hex>:<hex>/<len>` 的行首字段。真机证据：`ip -6 route show dev lo` 的三行行首是 **`unreachable`**（不是网段）；全表里还有 `default from … via …`（默认路由）。没有这条白名单，`unreachable` 会被当成网段生成垃圾规则，而**一旦出现不带 ` via ` 的默认路由（`default dev <dev>`），就会把整个互联网当成「家里」放行 → 封锁彻底失效**。同类风险一并堵死：` via ` 转发路由、`default`、`unreachable`、`throw`、`blackhole` 全部被格式拒掉，无需再逐个枚举。**⚠ 修正（2026-10-09 阶段 5 SF-1）**：白名单**并不能**拒掉「以数字形式出现的全零前缀」`::/0`（它匹配 `^([0-9A-Fa-f]*:)+[0-9A-Fa-f:]*/[0-9]+$`），而 `::/0` 一旦进链会生成 `-d ::/0 -j RETURN` = 放行一切 → 封锁静默失效。真机上不成立（busybox `ip` 把默认路由打印成 `default …`，2026-10-09 只读核实），但属**潜在 fail-open**，故补零长前缀排除并配 `::/0` 注入用例与变异。**另**：` via ` 排除是**行级**检查（行首可以是合法前缀却被 ` via ` 修饰，如 `<prefix> via fe80::1 dev br-lan`），白名单只看行首字段格式、拦不住，必须单独做 —— 已实现。 |
| **D3** | 输出格式与 `pc_lan_nets()` 对齐：`<prefix>/<len>`（`ip` 输出已是网络地址，**不做前缀运算**）。 |
| **D4** | `allow_lan_in()` 改为族感知：`$1 = $ipt6` 时遍历 `pc_lan_nets6()`，否则遍历 `pc_lan_nets()`；**删除** `addr_is_family … \|\| continue` 过滤（族已由调用点决定）。**但 v4 分支必须保持改动前语义**：仍跳过含 `:` 的值（等价于原 `addr_is_family "$_n" 0`），否则 `network` 静态节里若出现含冒号的 `ipaddr` 会透传进 `iptables`（非法规则 + 渲染指纹与实际规则永久不一致 → 每分钟无谓重建）—— 阶段 5 SF-2。 |
| **D5** | ~~`render_quota_spec()` 与 `_quota_emit_rules()` 签名改为 **3 参**~~ —— **作废（2026-10-09 阶段 3 收窄）**：查码后确认 `_quota_emit_rules()` 已对两族循环调用 `allow_lan_in "$_ip" mangle "$TAGQ"`、族由 `$1` 可判定，故**签名一律不动**，`render_quota_spec()` / `_quota_emit_rules()` / `build_quota_blocks()` / `block_skip_devless()` **零改动**；改动只落在 `allow_lan_in()` 函数体内（见 `pc-f3-v6-lan-guard-plan.md` P2）。 |
| **D6** | 守卫插入位置不变：`_quota_emit_rules()` 最后调用 `allow_lan_in`（`-I` 插到链首），必须在所有封锁规则之后调用。 |
| **D7** | 测试桩 `test/fakes/ip` 扩展：除 `neigh show` 外，支持 `-6 route show dev <dev>`，从新环境变量 `FAKE_IP_ROUTE6`（指向一个「`<dev> <prefix>`」两列的文本文件）读数据；未设置时输出空。`test/lib.sh` 的 `t_setup` 增加并导出该变量（默认空）。 |
| **D8** | 版本：`Makefile` 的 `PKG_VERSION` `1.8.1` → **`1.8.2`**，`PKG_RELEASE` `20261008` → **`20261009`**；tag **`v1.8.2`**；ipk 用既有 `test/build_ipk.sh` 构建（保持可复现）。 |
| **D9** | 白盒用例必须**可鉴别**：新增用例中的关键断言，需用变异（删掉 v6 守卫下发/删掉 `pc_lan_nets6` 的 ` via ` 过滤）证明会 FAIL。 |
| **D10** | 真机收尾 gate 的口径（**已修正，2026-10-09 阶段 2 grill**）：原稿误称「iPad 完整性检查不再适用」。经查证，既有检查是**按 iPad MAC 过滤** mangle 规则后取 md5（报告 §H.6 / §J.5 命令），而新增守卫 `-d <prefix> -j RETURN` **不含 `-m mac`**，不会进入该名单 → **原检查依然成立，无需放宽**。故 gate 用**三条更精确的口径**：① v4 侧 mangle/QUOTA 与 iPad-v4 指纹**逐字节不变**（72 / 53 / `4de4df07…`）；② v6 侧 **iPad-v6 指纹逐字节不变**（`3f2ab84d…`）；③ v6 侧总数恰好增加 3（mangle 54→**57**、QUOTA 39→**42**），且**多出来的只是那 3 条 `-j RETURN` 守卫**（多一条/少一条/夹带其它均 FAIL）。 |

---

## 3. 接口定义

```sh
# common.sh（新增，紧跟 pc_lan_nets 之后）
# 局域网 on-link IPv6 前缀，一行一个 "<prefix>/<len>"。
# 数据源：ip -6 route show dev <device>（只取直连路由，剔除 " via " 行）。
pc_lan_nets6() { … }

# init.d（改签名）
allow_lan_in()      { # $1=ipcmd $2=table $3=chain   ← 签名不变，内部按 $1 选族
render_quota_spec() { # $1=daytype $2=lan4           ← 签名不变（D5 已作废）
_quota_emit_rules() { # $1=daytype $2=lan4           ← 签名不变（D5 已作废）
```

新增**只读**外部依赖：`ip`（busybox 自带，真机已存在）。不新增 uci 配置项。

---

## 4. Out of scope（明确不做）

| # | 不做 | 理由 |
|---|---|---|
| O1 | **不改** `pc_lan_nets()` 的 v4 语义、不动 v4 守卫集合 | R3；v4 是现状基线 |
| O2 | 不新增链 / 不新增 hook 点 / 不新增规则类别（如 addrtype、ipset、nft） | R4；用户明确约束「不要擅自添加路由表之类的东西」。真机亦无 `addrtype` 模块 |
| O3 | **不修** v4 侧「到路由器的 DNS 查询被 `-d <lan-v4-cidr> -j RETURN` 放行 → `-m udp --dport 53 -m string` 拦不到本机 DNS」这一既有行为 | 既有设计、与 F3 无关；改它属行为变更，需单独提需求 |
| O4 | 不动 `basic.*` / 不动防火墙 / 不动 passwall / Clash / 网络配置 | 用户硬约束 |
| O5 | 不做跨天时段、不做 IPv6 邻居发现（NDP）层面的策略 | 与本缺陷无关 |

---

## 5. 验收标准（A1..A9，阶段 3 testplan 必须逐条映射）

| # | 验收标准（可观测） |
|---|---|
| **A1** | 生成后的 v6 `PARENTCONTROL_QUOTA` 链包含 `-j RETURN` 守卫，覆盖 `pc_lan_nets6()` 产出的**每一个**前缀；**真机预期恰好 3 条**（`<lan-v6-gua>/64`、`<lan-v6-ula>/64`、`fe80::/64`），v6 mangle 54→**57**、QUOTA 39→**42**。 |
| **A2** | v4 `PARENTCONTROL_QUOTA` 链与基线**逐字节一致**（条数 53、iPad-v4 指纹 `4de4df07…` 不变）；v6 侧 **iPad-v6 指纹 `3f2ab84d…` 不变**；v6 增量**恰好只有 3 条守卫**（D10 三条口径）。 |
| **A3** | 封锁窗口内，受管设备 → 局域网内 IPv6 目标（含路由器 v6 管理地址）不被本功能 DROP；封锁窗口内 → 非局域网 IPv6 目标的小红书流量仍被 DROP。 |
| **A4** | `pc_lan_nets6()` **忽略**含 ` via ` 的非直连路由；无 LAN IPv6 时输出为空且不下发守卫（无 v6 守卫规则、`quotaspec` 仍自洽）。 |
| **A5** | 幂等：连续两次 tick 不新增/不重复守卫；外部 `-F` 清空链后能自愈重建（含守卫）。 |
| **A6** | 新增白盒断言**可鉴别**：删掉 v6 守卫下发 → 用例 FAIL；删掉 ` via ` 过滤 → 用例 FAIL（变异检出）。 |
| **A7** | 不新增链、不改 hook 点、不改网络/防火墙/passwall 配置；`uci export parentcontrol` 的 md5 与基线一致（配置零变更）。 |
| **A8** | 既有全量白盒无回归：`sh test/run.sh` → `ALL SUITES PASS`；`sh test/mutation_check.sh` → survived 0 / 锚点失效 0。 |
| **A9** | 真机验收：装 `1.8.2-20261009` 后 v6 链出现**恰好 3 条**守卫；段内受管设备到 LAN v6 目标可达、到非 LAN 小红书目标仍被 DROP；探针（小红书/百度）正常；收尾 gate 全绿（按 **D10 三条口径**：v4 不变 / iPad-v4+v6 指纹不变 / v6 增量恰为 3 条守卫）；iPad 当日用量未被影响。 |

---

## 6. 交付物清单

| # | 文件 |
|---|---|
| 1 | `root/usr/lib/parentcontrol/common.sh`（`pc_lan_nets6`） |
| 2 | `root/etc/init.d/parentcontrol`（`allow_lan_in` / `render_quota_spec` / `_quota_emit_rules` / `build_quota_blocks`） |
| 3 | `test/fakes/ip`、`test/lib.sh`（v6 路由桩） |
| 4 | `test/common_test.sh`、`test/init_test.sh`、`test/mutation_check.sh`（W* 用例 + 变异） |
| 5 | `Makefile`（1.8.2 / 20261009） |
| 6 | `docs/superpowers/specs/pc-f3-v6-lan-guard-{adr,glossary,plan,testplan,progress,review,test-report}.md` |
