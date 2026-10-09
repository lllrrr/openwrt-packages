# F3（IPv6 局域网守卫）阶段 6 测试报告

> **隐私约定**：本文档不含真机标识字面量。路由器/设备/前缀/探针一律占位符：`<router-ip>`、`<test-device-ip>`、`<test-device-mac>`、`<managed-device-mac>`、`<gua-prefix>`、`<router-gua>`、`<test-device-gua>`、`<ula-prefix>`、`<router-ula>`、`<test-device-ula>`、`<probe-v6>`、`<probe-ip>`、`<wan6-linklocal-gw>` 等；同环境可用文中命令复现实测值。**无口令。**

- 角色：**test pane**（阶段 6：白盒独立复核 + 真机黑盒验收）
- 流水线：conductor `wR:p1` / code pane `wR:p4` / review pane `wR:p2`
- 仓库：`/Users/neo/Downloads/MyNextCloud/Work/luci-app-parentcontrol`（分支 `main`，本轮成果未提交）
- 被测产物：`.build/luci-app-parentcontrol_1.8.2-20261009_all.ipk`，md5 `56db2abf28458962299da77b51e89a64`（与任务要求一致 ✓，装包前已校验）
- 真机：ImmortalWrt 23.05.4 x86/64，LuCI + SSH 同址 `<router-ip>`，用户 `root`
- 执行日期：2026-10-09
- 独立性：本 pane 在 `/new` 新会话中执行，与实现者（`wR:p4`）、评审者（`wR:p2`）上下文隔离

---

## 1. 结论速览

| 用例 | 结论 | 一句话证据 |
|---|---|---|
| B-F3-01 | **PASS** | `opkg install` rc=0；v6 `PARENTCONTROL_QUOTA` 首 3 条 = 3 个直连前缀的 `-d <prefix> -j RETURN`（顺序 `fe80::/64`、`<ula-prefix>`、`<gua-prefix>`）；v6 mangle 54→**57**、v6 QUOTA 39→**42** |
| B-F3-02 | **PASS** | ①v4 mangle 72 / v4 QUOTA 53 / iPad-v4 指纹 `4de4df07…` 逐字节不变 ②iPad-v6 指纹 `3f2ab84d…` 逐字节不变 ③剥掉新增 3 条后与基线 v6 快照 **md5 相等**（62==62 行） |
| B-F3-03 | **PASS** | ①路由器 v6 管理地址与局域网 v6 目标均可达（HTTP 200，且用 Host 头做了守卫判别性反证）②本机→小红书 v6 **超时被 DROP**（目标 IP 规则计数器 0→18 pkts）③百度 v4/v6 正常 |
| B-F3-04 | **PASS（只读）**，破坏性降级 **SKIP** | 守卫前缀 == 真机 `ip -6 route show dev br-lan` 的 3 条直连路由，逐条一致（`route_lines=3 guard_lines=3`） |
| B-F3-05 | **PASS** | 连续 3 次 `reload` 稳定 57/42 且**不堆叠**；外部 `-F PARENTCONTROL_QUOTA` 后 1 个 tick（70 s）内 v4/v6 **双双自愈**回 72/53 与 57/42 |
| B-F3-06 | **PASS** | `uci export` 与 raw 配置双 md5 不变；v4 `mangle -S` 与基线 **md5 相等**；v6 剥 3 条后与基线 **md5 相等**；无新增链/表；PREROUTING 顺序不变 |
| B-F3-07 | **PASS** | 4 个 LuCI 页面 HTTP 200 且中文渲染正常；SSH 可连；小红书/百度探针正常；iPad 当日用量未被影响 |
| B-F3-08 | **PASS** | S5 收尾 gate 全项绿（见 §7） |
| **R7** | **PASS** | iPad 按 MAC 过滤的 v4/v6 规则指纹逐字节不变 |
| **R8** | **PASS** | `build_ipk.sh` 连续两次 md5 相同，且与部署产物 md5 一致、解包逐字节一致 |
| 白盒 W-F3-01..14 | **PASS** | `sh test/run.sh` → **ALL SUITES PASS**；14 条全部真跑到，断言非恒真 |
| 变异 M-F3-01..04 | **PASS** | 每条均 **被杀 1 / 存活 0 / 锚点失效 0** |

**总判定：通过。** 0 项 FAIL；1 项按规范 SKIP（B-F3-04 的破坏性降级场景）；1 项独立观察项（见 §5.2）已如实记录、**不计入 F3 回归** —— 成因已查清：**与 flow offload 无关**，插件已按设计关闭 offload（`/tmp/pc_offload_state=disabled` 且 `nft list ruleset | grep -c 'flow add'` = 0），首次 302 属 `reload` 生效的秒级时序窗口。

---

## 2. 终态口径（重要，勿误判）

真机收尾后的终态是 **部署稳态**，即「装了 1.8.2 并保持安装」的状态，**不是** F1/F2 轮模板里的 `72/54`。下一轮请勿据此误判为「没回基线」。

| 指标 | 部署前基线（1.8.1） | 收尾终态（1.8.2） | 判据 |
|---|---|---|---|
| v4 mangle `-A` | 72 | **72** | 必须逐字节不变 |
| v4 QUOTA `-A` | 53 | **53** | 必须逐字节不变 |
| v6 mangle `-A` | 54 | **57** | 必须 = 基线 + 3 |
| v6 QUOTA `-A` | 39 | **42** | 必须 = 基线 + 3 |
| iPad-v4 指纹 | `4de4df07…` | `4de4df07…` | 必须逐字节不变 |
| iPad-v6 指纹 | `3f2ab84d…` | `3f2ab84d…` | 必须逐字节不变 |
| `uci export` md5 | `247c232f…` | `247c232f…` | 必须逐字节不变 |
| raw 配置 md5 | `0d7609d2…` | `0d7609d2…` | 必须逐字节不变 |

**为什么 57/42 才是对的**（conductor 裁定 `m00177`，本文照录）：

1. A9 的验收目标就是「真机装 1.8.2 之后做验收」。装完再卸回 1.8.1 等于验收对象消失。
2. `57/42` 不是「没回基线」，而是 **1.8.2 的基线**：F3 的功能要求（A1）本身就是新增 3 条 v6 守卫，`54→57` / `39→42` 是这一版的正确稳态。
3. 本机没有 1.8.1 的 ipk，人工回退 `init.d`/`common.sh` 会让 opkg 数据库与实际文件不一致（更脏）。

**并须满足**：这 +3 条必须**恰好**是 3 条 `-d <直连前缀> -j RETURN`，而不是别的规则多出来。已用 strip-delta 证明（§4.3 B-F3-02③）。

**另一处模板值差异**：任务书写的「链声明 v4/v6 仍各 2 条」——实测两侧各 **3** 条（`PARENTCONTROL_ACCT`、`PARENTCONTROL_QUOTA`、`PCA_weburl_0`）。`PCA_weburl_0` 是既有的「按 section 计数」链，属**基线组成部分**，与基线**完全一致**（v4 `-S` 整体 md5 与基线相等；v6 剥 3 条守卫后与基线 md5 相等）。故按「链声明与基线不变」判定为 PASS，任务书的「2 条」系模板值笔误。

---

## 3. 第一部分：白盒独立复核（macOS，全部自己跑）

### 3.1 全量套件

```
$ sh test/run.sh
ALL SUITES PASS          （rc=0，real 4m39.7s）
```

各套件计数：`common_test` **PASS (94 checks)**、`init_test` **PASS (140 checks)**、`acceptance_test` **PASS (73 checks)**、`migrate_test` **PASS (94 checks)**，另有 4 个 lint 套件与 UI 静态检查一并运行。`FAIL` 计数 = 0。

预期噪声（既有问题，非 F3 引入）：`common.sh: line 313: echo: write error: Broken pipe`（`sample_counters()` 的 SIGPIPE，见评审 Nit-6 / §5.1）。

> 注意：该套件约 4m40s，短超时（如 300 s）会中断，须后台/长超时运行。

### 3.2 W-F3-01..14 逐条实跑到

14 条全部真实执行且 `ok`（14/14），分属两个文件：

- `test/common_test.sh`：**W-F3-01、02、03、04、05、06、13**（`pc_lan_nets6()` 单元级）
- `test/init_test.sh`：**W-F3-07、08、09、10、11、12、14**（守卫下发级）

复现：

```
$ sh test/common_test.sh      # 含 W-F3-01..06、13
$ sh test/init_test.sh        # 含 W-F3-07..12、14
```

断言非恒真的论证（避免「写了个必然通过的测试」）：

| 用例 | 非恒真证据 |
|---|---|
| W-F3-01 | 由变异 M-F3-01 杀死 |
| W-F3-07 / 12 | 由变异 M-F3-02、M-F3-03 杀死 |
| W-F3-13 | 由 M-F3-04 杀死 + 独立实验 EXP-A 定向复现（§3.4） |
| W-F3-14 | 由独立实验 EXP-B 定向复现（§3.4） |
| W-F3-05 | 含**对照组**（断言一旦补上 `device` 就必须产出前缀），全空实现会失败 |
| W-F3-09 / 11 | 断言链非空状态与计数器保留，非平凡 |

### 3.3 变异测试（逐条隔离，单实例串行）

```
$ MUT_ONLY='M-F3-01' sh test/mutation_check.sh    → 被杀 1 / 存活 0 / 锚点失效 0
$ MUT_ONLY='M-F3-02' sh test/mutation_check.sh    → 被杀 1 / 存活 0 / 锚点失效 0
$ MUT_ONLY='M-F3-03' sh test/mutation_check.sh    → 被杀 1 / 存活 0 / 锚点失效 0
$ MUT_ONLY='M-F3-04' sh test/mutation_check.sh    → 被杀 1 / 存活 0 / 锚点失效 0
```

四条全部 **被杀 1 / 存活 0 / 锚点失效 0** ✓（= 目标：每条变异恰好被 1 条用例杀死，无存活变异，无锚点失配）。

分别对应：M-F3-01 移除行首白名单 → W-F3-02 死；M-F3-02 恢复族过滤 → W-F3-07/12 死；M-F3-03 不按族选数据源 → W-F3-07 死；M-F3-04 移除零长前缀排除 → W-F3-13 死。

**全量变异（安静、单实例，仅作补充）**：

```
$ sh test/mutation_check.sh（后台串行单实例）
  被杀 51 / 存活 0 / 锚点失效 0
```

⚠️ **评审提醒已核实并遵守**：本机上**并发**跑全量 `mutation_check.sh` 会**假失败**——脚本自身的 `trap 'rm -rf "$WORK"' EXIT INT TERM` 在并发 bash 共享信号投递时收到 SIGTERM，提前删除工作目录，导致大量「锚点未命中」。故本轮全程**单实例串行**执行。另注：通过 `| tail` 管道运行时 `$?` 反映的是 `tail` 的返回码，应以打印的「被杀/存活/锚点失效」计数为准。

### 3.4 独立可鉴别性实验（本 pane 的核心价值，自己动手）

两个实验都在 `mktemp -d` 的**一次性副本**里做（`tar --exclude=.git --exclude=.build` 打包复制，**真仓库从未被写入**），做完即丢弃；事后复核两个生产文件的 md5 与做完前完全一致（`common.sh` `20979c453a86d06765a924893077d43b`、`init.d` `75e9836ec543d602d9ba624098e63181`）⇒ **未留痕** ✓。

**EXP-A：W-F3-13 能否抓住「移除零长前缀排除」**

- 操作：在副本里删除 `common.sh` 中 `case "$_pfx" in */0) continue ;; esac` 一行
- 命令：`sh test/common_test.sh`
- 输出（原文）：
  ```
  FAIL W-F3-13: ::/0 与全零前缀被排除，直连前缀照常
  FAILED (1/94 checks failed)
  ```
  泄漏输出中包含 `0:0:0:0:0:0:0:0/0`
- 结论：**恰好 1 条失败，且正是 W-F3-13** ⇒ 该断言可鉴别、方向正确。

**EXP-B：W-F3-14 能否抓住「v4 分支丢掉 `grep -v ':'`」**

- 操作：在副本里把 `init.d` 的 `_nets=$(pc_lan_nets | grep -v ':')` 改回 `_nets=$(pc_lan_nets)`
- 命令：`sh test/init_test.sh`
- 输出（原文）：
  ```
  FAIL W-F3-14: v4 链不出现含冒号的 ipaddr（非法规则不得透传）
    got  =[1]
  FAILED (1/140 checks failed)
  ```
  同组的 `W-F3-14: v6 链不受影响` 仍为 `ok`
- 结论：**恰好 1 条失败**，且显示非法规则 `fd00::1` 确实透传进了 v4 链 ⇒ 该断言可鉴别、方向正确。

### 3.5 R3/R4/R5/R6 四条既有断言未被改动且仍 PASS

| 编号 | 位置 | 断言 | 结果 |
|---|---|---|---|
| R3 | `test/common_test.sh:216` | `t_eq '静态 LAN 网段' '192.0.2.1/255.255.255.0' "$(pc_lan_nets)"` | PASS（run 日志 143 行 `ok 静态 LAN 网段`） |
| R4 | `test/init_test.sh:441` | `t_has '放行到局域网(含路由器)的流量' "$Q" '-d 192.0.2.1/255.255.255.0 -j RETURN'` + `t_has '仍然封锁无设备条件的条目' "$Q" '-j DROP'` + `t_eq 'RETURN 排在 DROP 之前'` | PASS（日志 252–253 行） |
| R5 | `test/init_test.sh:452-460` | `t_eq '无网段 → 不封锁（防自锁）' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA \| flat)"` + `t_has '日志有告警' "$(cat "$LOG_FILE")" '跳过封锁以防自锁'` | PASS（日志 256–257 行） |
| R6 | `test/acceptance_test.sh:302-311` | F1 自愈：规则集没变→一个 iptables 都不动（计数器 4242 保留）；链被外部清空→条数校验触发自愈重建 | PASS（日志 444–447 行） |

文件级证据（证明本轮改动是**纯追加**，未碰这些行）：

```
$ git diff -U0 test/common_test.sh
@@ -278,0 +279,105 @@          # 纯 append after line 278 ⇒ R3(line 216) 未动
$ git diff -U0 test/init_test.sh
@@ -858,0 +859,135 @@          # 纯 append after line 858 ⇒ R4(441)/R5(449-460) 未动
$ md5sum test/acceptance_test.sh → 532199b081313fad21ae07c4935b8c42   （== git show HEAD:… 的 md5）
```

R3/R4/R5 三行/三块 HEAD 与 worktree **逐字节相同**（已逐条比对）。

### 3.6 红线检查：生产/测试代码未被本 pane 改动

比对阶段 1 结束时记录的 md5，全部一致：

| 文件 | md5 |
|---|---|
| `root/usr/lib/parentcontrol/common.sh` | `20979c453a86d06765a924893077d43b` |
| `root/etc/init.d/parentcontrol` | `75e9836ec543d602d9ba624098e63181` |
| `test/common_test.sh` | `82dc7987b56aa12e47d5d1049f012893` |
| `test/init_test.sh` | `1da0837af7df900bb355f546bc7b4671` |
| `test/acceptance_test.sh` | `532199b081313fad21ae07c4935b8c42` |
| `test/mutation_check.sh` | `2f0e6d3f38b42ffb65a45b75122cadca` |
| `test/lib.sh` | `c25f1775c481a20ea454b7e0577f53d4` |
| `test/fakes/ip` | `b30d8aaa56dad80d14dfadf724a5880f` |
| `Makefile` | `5e115440f9c62f25c18974946e7e0fb3` |

`git status --short` 仅含本轮 F3 的既有改动 + 本 pane 新增的 `docs/superpowers/specs/pc-f3-v6-lan-guard-*.md`，无其他写入。

---

## 4. 第二部分：真机黑盒验收（B-F3-01..08 + R7/R8）

### 4.1 环境与部署前基线（逐项实测，全部匹配）

- `iptables v1.8.8 (legacy)` / `ip6tables v1.8.8 (legacy)`（**无 addrtype 模块**，故 ADR-4 的「不新增规则类别」是硬约束）
- 装前版本：`luci-app-parentcontrol - 1.8.1-20261008`
- `/etc/init.d/parentcontrol` md5 `7b49e500f1b15824a0b2508b44386ee1`；`common.sh` md5 `a422ef5ac4bce0edd95b109e67e4a67a`
- `uci export parentcontrol | md5sum` = `247c232f2a245ecd991999b31f7d55be`
- `md5sum /etc/config/parentcontrol` = `0d7609d2264932ca03a55ecbb5747158`
- `iptables -t mangle -S | grep -c '^-A'` = **72**；`ip6tables` = **54**
- QUOTA `-A`：v4 = **53**，v6 = **39**
- `ip -6 route show dev br-lan` = **恰好 3 行**：`<gua-prefix> proto static metric 1024 pref medium`、`<ula-prefix> proto static metric 1024 pref medium`、`fe80::/64 proto kernel metric 256 pref medium`
- weburl 节共 2 个；iPad = `parentcontrol.@weburl[0]`（`parentcontrol.cfg025076`，mac `<managed-device-mac>`，remarks `iPad Pro`，domains `xiaohongshu.com,xhscdn.com,sns-img.xhscdn.com,sns-video.xhscdn.com,xhslink.com,xhs.cn`，sd/hd_quota 60，sd/hd_qstart 09:00:00，sd/hd_qend 21:00:00）

**iPad 指纹复现命令**（文档只写了「按 iPad MAC 过滤 mangle 规则后取 md5」，此处补全为可复现命令，并已实测复现规定值）：

```
$ iptables  -t mangle -S | grep -i '<managed-device-mac>' | md5sum   → 4de4df074b7558b997ff1af05842979f  （68 行）
$ ip6tables -t mangle -S | grep -i '<managed-device-mac>' | md5sum   → 3f2ab84dd8eaf049c917a6d3a78286ec  （52 行）
```

**本机（唯一可加过滤记录的设备）**：en0 `<test-device-ip>`，MAC `<test-device-mac>`；v6 GUA `<test-device-gua>`、ULA `<test-device-ula>`、LL `<test-device-linklocal>`；v6 默认路由 `<wan6-linklocal-gw>%en0`。

**AAAA 事实**（决定探针口径）：`www.xiaohongshu.com` = `<probe-v6>`（iPad 规则已含 `-d <probe-v6-prefix>`）；`xiaohongshu.com`/`xhscdn.com`/`xhslink.com`/`xhs.cn` **无 AAAA**；`www.baidu.com` 有 AAAA。

### 4.2 S1/S2 安全措施（在改任何规则/装包之前完成）

**S1 备份**（均已生成）：

```
/tmp/pc-bb-backup.uci              (0d7609d2…)
/tmp/pc-bb-uci-export.txt
/tmp/pc-bb-mangle-v4-before.txt
/tmp/pc-bb-mangle-v6-before.txt
/tmp/pc-bb-initd                   (7b49e500…)
/tmp/pc-bb-common                  (a422ef5a…)
```

**S2 deadman（不依赖 AI 的自动回滚）**：`/tmp/pc-deadman.sh` = `sleep 900` → 若存在 `/tmp/pc-deadman-frozen` 则退出（我在规范之外自加的一道保险）→ 还原 `init.d`/`common.sh`/config 备份 → `uci -q delete parentcontrol.BBTEST-F3` → `uci commit parentcontrol` → `ubus call uci reload_config` → `restart` → `echo fired > /tmp/pc-deadman-fired`。

```
$ start-stop-daemon -S -b -m -p /tmp/pc-deadman.pid -x /bin/sh -- /tmp/pc-deadman.sh
$ ps w | grep "[p]c-deadman"        # 确认在跑
```

全程 `sleep 900` 内完成；**`/tmp/pc-deadman-fired` 自始至终未生成** ⇒ deadman 从未触发 ⇒ 无回滚发生（并与「`init.d`/`common.sh` md5 仍为 1.8.2 版本」互证）。

> deadman 期间因观察需要多次「kill 精确 pid → 重启」重臂，留下了若干孤立的 `sleep` 子进程（父 sh 已死，无害）。**绝不 `pkill sleep`**（会误杀 passwall 的循环任务）；只按 pidfile 精确 kill，方括号写法 `grep '[p]c-deadman'` 才不会把自身命令行算进去。

**S3 单条 bash 内闭环**：所有「装规则/装包 → 观察 → 撤规则」均在**同一条 bash 命令**内跑完，未跨 LLM 轮次（模型 API 走同一出口，封锁期间再发 LLM 调用会把自己卡死）。观察统一用 `curl --max-time 5/8`、`nc -w 3/4`。

**S4 未碰清单**：`basic.*`、iPad 节、既有 `@weburl[1]`、protocol/time/quota/vacation 节、防火墙/网络/passwall/Clash 配置、路由表——均未触碰；只新增/删除过 **1 条** `remarks=BBTEST-F3` 的测试节。

### 4.3 逐条结果

#### B-F3-01 装包与 v6 守卫下发 —— PASS

```
$ scp -o ControlMaster=no … /tmp/luci-app-parentcontrol_1.8.2-20261009_all.ipk
    两侧 md5 均为 56db2abf28458962299da77b51e89a64
$ opkg install /tmp/luci-app-parentcontrol_1.8.2-20261009_all.ipk     → rc=0
```

postinst 打印 `uci: Invalid argument` 两次 + 正常 conffile 提示 `Existing conffile /etc/config/parentcontrol is different from the conffile in the new package. The new conffile will be placed at /etc/config/parentcontrol-opkg`（既有配置被保留，故 md5 不变——正是我们想要的）。

装后：

```
luci-app-parentcontrol - 1.8.2-20261009
/etc/init.d/parentcontrol   md5 75e9836ec543d602d9ba624098e63181
/usr/lib/parentcontrol/common.sh md5 20979c453a86d06765a924893077d43b
```

v6 `PARENTCONTROL_QUOTA` 链首**恰好 3 条**：

```
-A PARENTCONTROL_QUOTA -d fe80::/64               -j RETURN
-A PARENTCONTROL_QUOTA -d <ula-prefix>     -j RETURN
-A PARENTCONTROL_QUOTA -d <gua-prefix>  -j RETURN
```

条数：v6 mangle **54→57**、v6 QUOTA **39→42**；每个前缀的守卫出现次数 before=0 / after=1 ✓

#### B-F3-02 A2/D10 三条口径 —— PASS（三条全过）

① **v4 侧完全不变**：v4 mangle `-A` 仍 **72**；v4 QUOTA 仍 **53**；iPad-v4 指纹 `4de4df074b7558b997ff1af05842979f` **逐字节不变** ✓

② **iPad-v6 指纹 `3f2ab84dd8eaf049c917a6d3a78286ec` 逐字节不变** ✓

③ **v6 增量恰为 3 条 RETURN**（strip-delta 证明）：把新增的那 3 条守卫行从装后 v6 快照中过滤掉后

```
stripped_md5 = 0e1f271913719b297a94e4f0c28df161
baseline_md5 = md5(/tmp/pc-bb-mangle-v6-before.txt) = 0e1f271913719b297a94e4f0c28df161
lines: 62 == 62
```

⇒ v6 侧的差异**恰好**是 3 条守卫，别无其他改动 ✓

#### B-F3-03 A3 可用性双向 —— PASS（最关键用例）

测试节：`parentcontrol.BBTESTF3=weburl`，enable=1，remarks='BBTEST-F3'，mac=`<test-device-mac>`（本机），domains=`xiaohongshu.com,xhscdn.com,sns-img.xhscdn.com,xhslink.com,xhs.cn`，sd/hd_quota 60，unlimited 0，sd/hd_qstart `00:00:00`，sd/hd_qend `00:01:00` ⇒ 封锁窗口 `00:01:01–23:59:59`（本地时间），加完**立刻处于封锁窗口**。

加节 + `reload` 后：`bb_v6=22 bb_v4=30 guards_v6=3`（守卫仍在链首，`first_drop_line=4`）。

**① 本机 → 路由器 v6 管理地址 / 局域网内 v6 目标 → 可达**

```
①  curl -s -o /dev/null -w '%{http_code} t=%{time_total}' --max-time 5 http://[<router-gua>]/
      → code=200 t=0.015849
①b curl --max-time 5 -H 'Host: xiaohongshu.com' http://[<router-gua>]/
      → code=200 t=0.011589
①c curl --max-time 5 http://[<router-ula>]/
      → code=200 t=0.011525
①d ping6 <router-gua>     → 0% packet loss
```

**①b 是守卫的「判别性反证」**：该请求的 Host 头命中当前生效的 BBTEST 字符串规则（`-m string --string "xiaohongshu.com" … --dports 80,443 -j DROP`），因此**唯有** `-d <gua-prefix> -j RETURN` 先返回才能得到 200 ⇒ ① 是真的正对照，不是「必然为真」的空断言。

**② 本机 → 小红书（走 v6）→ 被 DROP**

```
②  curl -sv --max-time 8 -6 -o /dev/null https://www.xiaohongshu.com/
      * Trying [<probe-v6>]:443...
      * Connection timed out after 8007 milliseconds
②b nc -6 -z -w 4 <probe-v6> 443      → P2b_rc=1
②c curl -sv --max-time 8 -4 https://www.xiaohongshu.com/
      Trying <probe-ip>:443 / <probe-ip> / <probe-ip>
      * Connection timed out after 8005 milliseconds          （v4 侧同样被拦，符合既有语义）
```

**计数器直证**：v6 目标 IP 规则

```
-A PARENTCONTROL_QUOTA -d <probe-v6-prefix> -m mac --mac-source <test-device-mac> \
   -m time --timestart 00:00:00 --timestop 15:59:59 --datestop 2038-01-19T03:14:07 -j DROP
```

探测前 `0 pkts / 0 bytes` → 探测后 **`18 pkts / 1496 bytes`**（而所有字符串型 DROP 仍为 0/0——因为 SYN 在携带 SNI 的 ClientHello 之前就被目标 IP 规则丢掉了）。⇒ 封锁**确实**由该规则在执行。

**③ 对照：百度正常**

```
③  curl --max-time 8 -6 https://www.baidu.com/   → code=200 t=0.070510
③b curl --max-time 8 -4 https://www.baidu.com/   → code=200 t=0.066584
```

**撤节复核（同一条 bash 内完成）**：删节 + `commit` + `reload` 后回到 `v6m=57 v6q=42 v4m=72 v4q=53`、`bb_left=0`、`export_md5=247c232f…`、`raw_md5=0d7609d2…`、`ipad_v4/v6` 指纹不变、`fired=no` ✓

> **①「路由器 v6 管理地址」与「局域网内 v6 目标」均实测到 v6 路径可达，无需降级为规则语义 + 计数器的替代证据。**

#### B-F3-04 无 v6 直连前缀时的降级 —— PASS（只读核对）/ 破坏性场景 SKIP

```
$ ip -6 route show dev br-lan
<gua-prefix> proto static metric 1024 pref medium
<ula-prefix>    proto static metric 1024 pref medium
fe80::/64              proto kernel metric 256 pref medium

route_lines=3   guard_lines=3   （守卫前缀与路由前缀逐一相等）
```

⇒ `pc_lan_nets6()` 的数据源与真机路由一致，守卫恰好覆盖全部直连前缀。

**SKIP 说明**：真正的「无 v6 直连前缀」降级场景需要在真机上拆除 v6 地址/路由（触碰真实网络配置，违反 S4），故**未构造**，按任务书「不可造则只做只读核对」执行。

#### B-F3-05 幂等 + 自愈 —— PASS

起点 `v6m=57 v6q=42 v4m=72 v4q=53 g6=3`；连续三次 `reload`：

```
reload #1 → 57/42/72/53 g6=3
reload #2 → 57/42/72/53 g6=3
reload #3 → 57/42/72/53 g6=3        （条数稳定、不堆叠）
守卫恒为 -d fe80::/64 / -d <ula-prefix> / -d <gua-prefix> 三条
```

**自愈**（外部清空 → 等 1 个 tick ≤ 75 s）：

```
$ ip6tables -t mangle -F PARENTCONTROL_QUOTA
  → v6m=15 v6q=0 g6=0
  等 70 s（1 个 cron tick）后 → v6m=57 v6q=42 g6=3      ✓ 3 条守卫回来了
$ iptables -t mangle -F PARENTCONTROL_QUOTA
  → v4m=19 v4q=0
  等 70 s 后 → v4m=72 v4q=53                            ✓ v4 侧也自愈
```

cron 直证（`logread`）：`cron.err crond[…]: USER root pid … cmd /etc/init.d/parentcontrol tick >/dev/null 2>&1`，18:52–18:57 每分钟一次 ✓

#### B-F3-06 零副作用 —— PASS

- `uci export parentcontrol | md5sum` = `247c232f2a245ecd991999b31f7d55be` **不变** ✓
- `md5sum /etc/config/parentcontrol` = `0d7609d2264932ca03a55ecbb5747158` **不变** ✓
- PREROUTING 顺序不变：v4/v6 均恰为 `-P PREROUTING ACCEPT` → `-A PREROUTING -j PARENTCONTROL_QUOTA` → `-A PREROUTING -j PARENTCONTROL_ACCT` ✓
- 链声明 v4/v6 各 **3** 条（`PARENTCONTROL_ACCT`、`PARENTCONTROL_QUOTA`、`PCA_weburl_0`）＝ 与基线一致（见 §2 模板值说明）✓
- **无新增链、无新增表**：
  - `iptables -t mangle -S` 现 md5 `fff7158127783fc466ee14575d4011db` **== 基线 md5**（均 80 行）⇒ v4 侧语句级逐字节相同
  - `ip6tables -t mangle -S` 共 65 行；剥掉 3 条守卫后 62 行，md5 `0e1f271913719b297a94e4f0c28df161` **== 基线** ⇒ v6 侧除 3 条守卫外逐字节相同
- 未动 `basic.*`：以**整份** `uci export` md5 相等证明（涵盖 `basic.*` 及所有节）；单看 `grep '^parentcontrol\.basic'` 是**空集**（两侧都是空串 md5 `d41d8cd98f00b204e9800998ecf8427e`），该检查**无意义**，已由整体 md5 相等取代
- 其他配置 mtime 均早于本次部署步骤，md5 存档：`firewall=bc92544a917b8b199fc3dc753e027fbf`（Oct 9 18:38）、`network=5e28fd07668fa6fe76a10904eda5a53f`（Oct 1 2024）、`dhcp=314e4e2c53877cd598f0e54034dc67d8`（Oct 9 03:00）、`passwall`（Oct 9 03:00）
- `firewall.parentcontrol=include`（`type='script'`，`path='/etc/parentcontrol.include'`，`reload='1'`）是**包自带、先于 F3** 的 uci-defaults 产物：`root/etc/uci-defaults/luci-app-parentcontrol:13` 与 `:15`。故 `uci show firewall | grep -ci parent` = 4 属既有基线，非本轮新增 ✓

#### B-F3-07 探针与既有功能 —— PASS

LuCI（真实登录后取页面）：`curl -c cookie --data-urlencode luci_username=root --data-urlencode luci_password=$PW http://<router-ip>/cgi-bin/luci/` 然后 `curl -b cookie`；真实路由来自 `/usr/lib/lua/luci/controller/parentcontrol.lua` 第 9/12/13/14 行。

| 页面 | HTTP | 体积 | 中文 |
|---|---|---|---|
| `/cgi-bin/luci/admin/control/parentcontrol` | 200 | 41927 B | 368 CJK |
| `/admin/control/parentcontrol/weburl`（网址过滤） | 200 | 41966 B | 368 CJK |
| `/admin/control/parentcontrol/quota`（使用限额） | 200 | 34224 B | 322 CJK |
| `/admin/control/parentcontrol/stats`（使用统计） | 200 | 39542 B | 673 CJK |

中文渲染正常（抽样：家长控制、一分钟内至少、今日额度、域名刷新、封锁粒度）。注：任务书写的 `/weburl`、`/quota`、`/stats` 是 `/admin/control/parentcontrol` 的**子路径**。

- SSH 可连 ✓
- 小红书/百度探针正常（撤节后 `curl -sv -6 https://www.xiaohongshu.com/` → `* Connected to www.xiaohongshu.com (<probe-v6>) port 443` / `using HTTP/2` ⇒ 封锁完全解除、无残留）✓
- **iPad 当日用量未被影响**：`/etc/parentcontrol/usage/` 只有 `20261002/20261004/20261007/20261008`，**没有 20261009 文件**（今日从未产生用量文件 ⇒ 前后都是 0）；`stats_tsv` → `entry weburl_0 weburl 0 iPad Pro <managed-device-mac> 60 0 <blank> 0 0`；`/etc/parentcontrol/resets.log` 仅两条旧记录（`2026-10-02 … weburl_0 3`、`2026-10-04 … weburl_2 1`），无新条目；运行时 `base.weburl_0` = 2 字节 `0`
- `PARENTCONTROL_ACCT` 双族完好（iPad 的 `-j PCA_weburl_0` 计数规则在位）——因为全程**只 `-F` 过 `PARENTCONTROL_QUOTA`**，从未碰 `PARENTCONTROL_ACCT`，故用量统计未被破坏
- iPad 节逐字节未变：`parentcontrol.@weburl[0]` enable=1，mac `<managed-device-mac>`，remarks `iPad Pro`，sd/hd_quota 60，sd/hd_qstart 09:00:00，sd/hd_qend 21:00:00

#### B-F3-08 收尾 gate（S5）—— PASS

见 §7。

#### R7 iPad 规则逐字节不变 —— PASS

```
ipad_v4 = 4de4df074b7558b997ff1af05842979f   （== 基线，68 行）
ipad_v6 = 3f2ab84dd8eaf049c917a6d3a78286ec   （== 基线，52 行）
```

装包后、每轮测试后、收尾后共测 4 次，全部一致 ✓

#### R8 构建可复现 —— PASS

```
原产物        md5 = 56db2abf28458962299da77b51e89a64
build_ipk.sh 第 1 次 → rc=0，md5 = 56db2abf28458962299da77b51e89a64
build_ipk.sh 第 2 次 → rc=0，md5 = 56db2abf28458962299da77b51e89a64
解包对比：三者 tree_md5 = 4126dbf90bac7d1335329f3875be0ba2（7 个文件），逐字节一致
```

⇒ 两次构建 md5 相同（可复现），且与部署产物解包后**逐字节一致**。`build_ipk.sh` 虽会覆盖 `.build/`，但覆盖后 md5 未变，无需记录新值。

### 4.4 真机数值表 & 指纹表（汇总）

| 项目 | 基线（1.8.1） | 终态（1.8.2） | 期望 | 判定 |
|---|---|---|---|---|
| v4 mangle `-A` | 72 | **72** | 不变 | ✓ |
| v4 QUOTA `-A` | 53 | **53** | 不变 | ✓ |
| v6 mangle `-A` | 54 | **57** | 基线+3 | ✓ |
| v6 QUOTA `-A` | 39 | **42** | 基线+3 | ✓ |
| v4 `mangle -S` md5 | `fff7158127783fc466ee14575d4011db` | 同值 | 不变 | ✓ |
| v6 `mangle -S` 剥 3 条后 md5 | `0e1f271913719b297a94e4f0c28df161` | 同值 | 不变 | ✓ |
| iPad-v4 指纹 | `4de4df074b7558b997ff1af05842979f` | 同值 | 不变 | ✓ |
| iPad-v6 指纹 | `3f2ab84dd8eaf049c917a6d3a78286ec` | 同值 | 不变 | ✓ |
| `uci export` md5 | `247c232f2a245ecd991999b31f7d55be` | 同值 | 不变 | ✓ |
| raw config md5 | `0d7609d2264932ca03a55ecbb5747158` | 同值 | 不变 | ✓ |
| PREROUTING 顺序 | QUOTA → ACCT | 同 | 不变 | ✓ |
| 链声明 v4/v6 | 各 3 | 各 3 | 不变 | ✓ |
| v6 守卫条数 | 0 | **3** | =3 | ✓ |

---

## 5. 独立发现与残差

### 5.1 评审残差清单的核实（非阻塞，均已确认不影响验收）

| 项 | 内容 | 本 pane 复核 |
|---|---|---|
| ① | 零长前缀排除可硬化为 `*/0*`（`::/00`、`::/000` 未覆盖） | 内核从不产出该形态（实测 `ip -6 route show` 中行首 `::/0` 计数 = **0**，3 条默认路由都是 `default from … via …`）⇒ 潜在、不可达 |
| ② | W-F3-13 fixture 可自包含化 | 不影响鉴别力（EXP-A 已证） |
| ③ | 可为 v4 `grep -v ':'` 增加变异 | M-F3-01..04 未覆盖该行，但 EXP-B 已人工证明其可被 W-F3-14 抓住 |
| ④ | W-F3-05 可用 stub 调用日志加强 | 现有对照组已排除「恒空实现」 |
| ⑤ | 【非 F3】`common.sh: line 313: echo: write error: Broken pipe` | 既有 SIGPIPE 噪声，**独立跟进项**，非本轮引入 |

### 5.2 观察项：B-F3-03 首次探针 302 —— 定因为「**与 flow offload 无关**」（结论 (a)）

**现象**：B-F3-03 的**第一次**尝试中，`curl -6 https://www.xiaohongshu.com/` 返回 **`302`（t=0.237 s）**，v4 侧同为 `302`，而当时**所有 BBTEST 的 DROP 规则计数器都是 0 pkts**；第 2、3 次尝试（同形态测试节）均为 **8 s 超时**、且目标 IP 规则计数增长。

**手段**：按 conductor 要求补采真机**只读**证据（不改任何配置、不碰任何规则/节）。

#### ⚠️ 无效证据（明确标注：后人不许再用这两条判断 offload 是否生效）

- `firewall.@defaults[0].flow_offloading='1'` 是 **UCI 配置项**。parentcontrol 从不去改它 —— 它删的是 nft 里的 **flow-add 规则**，不是这个 option。因此这个值恒为 1，**无诊断价值**。
- `flowtable ft { … }` 是 **表定义**。即使 flow-add 规则已被删除，这个表定义依然存在。**有表定义 ≠ 有卸载在生效**。

> 本报告初版 §5.2 正是误用了上述两条，据此误判「offload 处于开启状态」。已按 conductor 裁定更正。

#### ✅ 有效判据：插件自己记录 offload 状态

`root/etc/init.d/parentcontrol:285-312` `apply_offload()`：只要存在受管设备，就 `offload_handle()` 拿到 handle → **删除 `inet fw4 forward` 的 `flow add @ft` 规则** → `elog "offload: disabled"` → `conntrack -D -s <受管主机地址>` → `printf 'disabled\n' > /tmp/pc_offload_state`。反向 `restore_offload()`（`:314-322`）重新 `insert` flow-add 规则并写 `on`。

调用点：`apply_offload` 在构建流程末尾执行（`init.d:647`），`restore_offload` 在删除流程中执行（`init.d:676`）。受管设备判定见 `offload_macs()`（`init.d:272-275`）：`basic.enabled=1` 时返回全部 weburl 节的 mac —— **iPad 节即为受管条目**。

⇒ 因此**只要插件在跑且存在受管条目，offload 就是关闭的**（这也是既有设计：有受管设备就不让任何流被卸载）。

#### 实际执行的命令与原始输出

```
$ SSHPASS=<由操作员在内存中提供，未落盘> sshpass -e ssh -o ControlMaster=no \
    -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@<router-ip> 'sh -s' <<'EOF'
    uci -q get parentcontrol.@basic[0].enabled
    ls -la /tmp/pc_offload_state ; cat /tmp/pc_offload_state
    nft list ruleset | grep -n 'flow'
    nft list ruleset | grep -c 'flow add'
    nft list chain inet fw4 forward | grep -c 'flow add @ft'
    nft list ruleset | grep -n 'flowtable'
    logread | grep -i offload | tail -20
    date ; uptime
  EOF

== 0. basic.enabled ==                          1
== 1. ls -la /tmp/pc_offload_state ==           -rw-r--r-- 1 root root 9 Oct  9 18:53 /tmp/pc_offload_state
== 2. cat /tmp/pc_offload_state ==              disabled
== 3. nft list ruleset | grep -n 'flow' ==      47:  flowtable ft {
                                                57:  ct state established,related accept comment "!fw4: Allow inbound established and related flows"
                                                66:  ct state established,related accept comment "!fw4: Allow forwarded established and related flows"
                                                75:  ct state established,related accept comment "!fw4: Allow outbound established and related flows"
== 4. nft list ruleset | grep -c 'flow add' ==  0
== 5. nft list chain inet fw4 forward | grep -c 'flow add @ft' ==  0
== 6. nft list ruleset | grep -n 'flowtable' == 47:  flowtable ft {
== 7. logread | grep -i offload | tail -20 ==   （空 —— 日志环形缓冲区已滚过该时间窗，无法佐证；不作为判据）
== 8. date ==                                   Fri Oct  9 19:08:55 CST 2026
=== ssh rc=0 ===
```

补充复核（证明插件此刻在运行 ⇒ `apply_offload` 处于生效状态）：

```
/etc/rc.d/S98parentcontrol -> ../init.d/parentcontrol
v4m=72 v4q=53   v6m=57 v6q=42   guards=3
state=disabled   flowadd=0
```

**读法**：第 3/6 项的 `flowtable ft {` 只是**表定义**（无效证据）；真正的判据是第 4/5 项 —— **没有任何 `flow add` 规则**，且插件状态文件为 **`disabled`**。

#### 结论 (a) —— 更正后的表述

**首次 302 与 offload 无关**；插件已按设计关闭 offload 并清 conntrack。首次 302 的可能解释是**探针与 `reload` 生效之间的时序竞争**（或目标地址解析差异），**不构成 offload 绕过**，但仍记录为观察项。

**判定**：非 F3 回归；F3 的验收用例 B-F3-03 在第 2、3 次尝试中均按预期通过。**未发现 offload 绕过路径。** 残留观察价值仅在于「`reload` 后首次探针存在秒级时序窗口」——若需彻底消除，可评估在 `reload` 返回前加入确定性等待（属 F3 范围之外，本次不实施）。

> 口令处理：本次补采所需口令由操作员在**内存中**提供（`SSHPASS` 环境变量，仅用于 `sshpass -e`），**未写入任何文件/报告/仓库/记忆**；S5 已删除的 `/tmp/pc-sshpass.txt` 本次**未重建**。

### 5.3 未测项

| 项 | 状态 | 原因 |
|---|---|---|
| B-F3-04 破坏性降级（真机拆 v6 前缀） | SKIP | 需改真实网络配置，违反 S4；已按任务书执行只读核对 |
| S7 高风险动作（关 `basic.enabled`、停插件测 offload 恢复） | SKIP | 任务书规定默认 SKIP |

---

## 6. 事故与偏差记录

| # | 事件 | 处置 |
|---|---|---|
| 1 | B-F3-03 第 1 次尝试出现 302（详见 §5.2） | 现场即为**单条 bash 闭环**，已立即撤节并复核回基线；随后重做 2、3 次，结果符合预期。**已补采真机只读证据定因：与 flow offload 无关**（`/tmp/pc_offload_state=disabled`、`nft list ruleset | grep -c 'flow add'` = 0） |
| 2 | 任务书模板值 `72/54` 与终态 `57/42` 歧义 | 已向 conductor 报请裁定；conductor 裁定 (A) 保留 1.8.2，终态 = 部署稳态（`m00177`），见 §2 |
| 3 | 任务书「链声明各 2 条」与实测各 3 条 | 实测 `PCA_weburl_0` 为既有链，与基线一致；判为模板值笔误（§2） |
| 4 | 首次 S5 清理遗漏 4 个 `/tmp/pc-*.txt` 临时文件 | 第二次清理补齐，`leftover_pc_count=0` |
| 5 | `/tmp/parentcontrol` 目录残留 | 经查为 parentcontrol 守护进程**自身的运行时状态目录**（`acct.stats.<pid>`、`base.weburl_0`、`daytype`、`quotaspec`），由服务 tick 持续写入，**非 F3 残留** |
| 6 | deadman 重臂留下孤立 `sleep` 进程 | 父 sh 已死，无害；**未** `pkill sleep`（避免误杀 passwall） |

**无严重事故。** deadman 全程**未触发**（`/tmp/pc-deadman-fired` 未生成），无自动回滚发生。

---

## 7. 最终 gate 全绿证据（B-F3-08 / S5）

收尾时刻 `Fri Oct 9 19:00:34 CST 2026`：

```
installed      = luci-app-parentcontrol - 1.8.2-20261009          ✓ 仍为部署版本
v4m=72 v4q=53  v6m=57 v6q=42                                      ✓ 见 §2 口径
export_md5     = 247c232f2a245ecd991999b31f7d55be                 ✓ == 基线
raw_md5        = 0d7609d2264932ca03a55ecbb5747158                 ✓ == 基线
ipad_v4        = 4de4df074b7558b997ff1af05842979f                 ✓ == 基线
ipad_v6        = 3f2ab84dd8eaf049c917a6d3a78286ec                 ✓ == 基线
guards         = 3（fe80::/64, <ula-prefix>, <gua-prefix>）  ✓
bbtest         = 0                                                ✓ 测试节残留 0
deadman_procs  = 0      fired = no                                ✓ deadman 已清理且未触发
service_enabled= 1      cron   = 2                                ✓
init.d  md5    = 75e9836ec543d602d9ba624098e63181                 ✓ 未被 deadman 还原
common.sh md5  = 20979c453a86d06765a924893077d43b                 ✓ 未被 deadman 还原
leftover_pc_count = 0                                             ✓ 真机 /tmp 无 pc-* 残留
```

- 真机 `/tmp` 仅剩 `/tmp/parentcontrol`（服务自身运行时目录，见 §6）
- 本机 `rm -f /tmp/pc-sshpass.txt` 已执行 ⇒ `mac_sshpass_file=removed`；`unset SSHPASS` 已执行
- 口令泄漏扫描（本机全部 `/tmp/pc-*.txt` 证据日志 + 仓库 docs）**全部干净**：无 `luci_password=<值>`、无 `luci_password` 字样、无 `SSHPASS=<字面值>`、无 `sshpass -p`

---

## 8. 红线自查（结束前逐条确认）

| 红线 | 结论 | 证据 |
|---|---|---|
| 未改生产代码 | ✓ | `common.sh`/`init.d` md5 与阶段 1 结束完全一致（§3.6） |
| 未改测试代码 | ✓ | 6 个测试文件 md5 全部与阶段 1 结束一致；改动均为 code pane 的纯追加（§3.5/§3.6） |
| 未碰 iPad 与网络配置 | ✓ | iPad v4/v6 指纹逐字节不变；`uci export` 整份 md5 不变；未改路由/防火墙/passwall（§4.3） |
| 未新增链或规则类别 | ✓ | v4 `-S` md5 == 基线；v6 剥 3 条守卫后 md5 == 基线；无新链/表（§4.3 B-F3-06） |
| deadman 已清理 | ✓ | `deadman_procs=0`，`fired=no`，pid 精确 kill |
| 口令未落盘 | ✓ | `/tmp/pc-sshpass.txt` 已删除；全量日志扫描干净（§7） |
| 真机已回基线 | ✓ | 除 F3 应有的 +3 条 v6 守卫外，全部指标与基线逐字节一致（§2/§7） |
| 未 `git commit` / `git push` | ✓ | 全程未执行任何 git 写操作 |
| 只记录问题、未改代码 | ✓ | 发现项（§5）仅记录，未落任何修改 |

---

## 9. 复现命令索引

```sh
# ---- 第一部分（本机）----
sh test/run.sh
sh test/common_test.sh
sh test/init_test.sh
MUT_ONLY='M-F3-01' sh test/mutation_check.sh     # 02/03/04 同理
sh test/mutation_check.sh                        # 单实例串行!
sh test/build_ipk.sh                             # 连续两次比 md5

# ---- 第二部分（真机）----
export SSHPASS="$(cat /tmp/pc-sshpass.txt)"
sshpass -e ssh -o ControlMaster=no -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  root@<router-ip> 'sh -s' <<'EOF'
  iptables  -t mangle -S | grep -c '^-A'
  ip6tables -t mangle -S | grep -c '^-A'
  ip6tables -t mangle -S PARENTCONTROL_QUOTA | grep -c -- '-j RETURN'
  ip -6 route show dev br-lan
  uci export parentcontrol | md5sum
  iptables  -t mangle -S | grep -i '<managed-device-mac>' | md5sum
  ip6tables -t mangle -S | grep -i '<managed-device-mac>' | md5sum
EOF
unset SSHPASS
```

---

**报告状态**：完成。B-F3-01..08 = **8 PASS / 0 FAIL / 0 SKIP**（B-F3-04 的破坏性降级子场景另计 1 SKIP，该用例本身 PASS）；白盒 W-F3-01..14 全 PASS、变异 4/4 全杀；最终 gate 全绿。
