# pc-acceptance — 阶段 4 code pane 进度（progress）

- 日期：2026-10-03；角色：code pane（executor）；conductor：`wR:p1`；task-brief：`pc-acceptance`
- 任务：把 `pc-acceptance-testplan.md` §2 里标「新增」的白盒用例实现进 `test/`，自证跑绿，逐条可鉴别。

## 0. 结论

- `sh test/run.sh` → **ALL SUITES PASS**（lint locals / ash 兼容 / luci globals / TSV 唯一性 / **UI 静态结构（新，42 项）** + common 76 checks + init **176** checks + migrate **94** checks，全绿）。
- `sh test/mutation_check.sh` → 36 个变异**全部被杀死**（15 个既有 + 21 个本轮新增；锚点全部命中且唯一），见 §4。
- 新增 UI 类用例（W37/W38/W39/W42-静态）是**静态结构检查、非行为级**（主机无 lua），已在检查输出与代码注释里如实标注；行为级由真机 B10/B11/B16 承担。

## 1. 逐条 W 状态（testplan §2）

| ID | 状态 | 落点 | 说明 |
|----|------|------|------|
| W1 | 已有 | init_test | 关闭开关 → mangle/filter 均无 PARENTCONTROL 链 |
| W2 | 已有 + **加固** | lint_ash.sh | 原模式**拦不住** `local a,b=0`（A1 的典型 bash-only 语法）→ 补 `local [A-Za-z_][A-Za-z0-9_]*,` 模式，并以变异（suite=run.sh）证明可鉴别 |
| W3 | **新增** | init_test「W3」 | time+protocol+weburl 各一 → 真实 `start` 全流程：rc=0、stderr 无语法错误、三类 ACCT 规则都在、三类耗尽都能封、crontab 已写（防「崩在 time 之后」的旧版缺陷复发） |
| W4 | **新增** | init_test「W4」 | 预置老 filter TIME/PROTOCOL/WEBURL 链+跳转、老 mangle WEBURL/IP 链+跳转、当前两条链、PCA 残链 → `del_rule` 全部清掉；`start`×3 规则数不增长、PREROUTING 恰好 QUOTA→ACCT。**暴露生产缺陷并修复，见 §3-①** |
| W5 | **新增** | init_test「W5」 | 预置陈旧 `$LOCK`（mtime 2020）→ `start` 不 exit 1、规则建成、锁被清、日志留痕、生命周期走完 |
| W6 | **新增** | init_test「W6」 | 子壳内让 `refresh_holiday` 中途 `exit 3` 模拟构建崩溃 → EXIT trap 清锁；crontab 未写（证明确实半途而废） |
| W7 | **新增** | init_test「W7」 | hotplug 脚本末行打桩后原样执行：enabled=1+ifup → 调 start；enabled=0 / ifdown → 不调；stderr 无 `not found`（旧版「双层替换」缺陷形态） |
| W8 | 已有 | init_test | mangle PREROUTING、QUOTA→ACCT、`-m mac --mac-source` |
| W9 | **新增** | init_test「W9/W10/W11」 | 状态化 nft 桩预置 fw4 `flow add @ft` → `run_build` 后规则被删、`/tmp/pc_offload_state=disabled` |
| W10 | **新增** | 同上 | 从 off 状态调 `restore_offload` → 规则装回、状态文件=on |
| W11 | **新增** | 同上 | conntrack 桩记录调用：对 neigh 解析出的 IP 与条目静态 IP 都执行 `-D`；隐藏 conntrack 后跳过且不报错、构建不受影响 |
| W12 | 已有 | init_test | 封锁/计数共用生成器、计数单条不双计 |
| W13 | **新增** | init_test「W13」 | `domains='1.2.3.4/32,example.com'`：CIDR 原样入表/进规则（不套 /24）、resolveip 查询日志无 CIDR、域名才走解析 |
| W14 | 部分已有 → **补** | init_test「W14」 | `ip_mask=32`：入表为精确 IP、规则用精确主机地址、无 /24；IPv6 仍 /64。**表示法取舍见 §5-1** |
| W15 | 已有 | init_test | 解析只增不减、删条目清文件 |
| W16 | 已有基础上 **补** | init_test「W16」 | 预置他人 crontab 条目 → `cron_sync 1` 后原样保留、插件条目恰好 2 条（原有用例已盖 0=不写/去重） |
| W17 | 部分已有 → **补** | init_test「W17」 | resolveip 查询日志证明：apex 与 www. 变体都被查询；关键词 `xhs` → 试 `xhs.com`/`www.xhs.com`/`xhs.cn`，且各变体 IP（含独立 /24 与 v6）入表 |
| W18–W31 | 已有 | init_test / common_test | 对照 testplan「已有」标注，未改动 |
| W32 | 部分已有 → **补** | init_test「W32」 | mac+ip 双身份：封锁侧各出一条（任一命中）、计数侧恰一条且用 `-s <ip>`、计数无 mac 条件 |
| W33–W36 | 已有 | init_test / common_test | 节假日拉取/寒暑假/优先级/UTC+8 |
| W37 | **新增（静态）** | ui_static_check.py `w37` | 今日额度 `已用/额度 分钟`、`不限`、不存在 `-`；档案摘要「两档案相同只写一次 / 全天不写 / 秒不写（sub(1,5)）」；设备列 `MAC（设备名）`。数据侧 `stats_tsv brief` 断言 init_test 已有 |
| W38 | **新增（静态）** | `w38` | validate_window 双向 `>=` 判错、起↔止 gsub 映射、**禁止链式 gsub（自己和自己比）**、两个 qstart/qend 字段都挂校验、edit.htm 前端同样 `a >= b` |
| W39 | **新增（静态）** | `w39` | 使用限额页存在；quota（共享额度池）+ vacation（寒暑假区间）两个 TypedSection；字段 name/sd_quota/hd_quota/start/end 与 shell 侧读取逐字一致；菜单入口在 |
| W40 | 已有 | run.sh / lint_luci_globals.py | 未改动 |
| W41 | 已有 | run.sh TSV 唯一性 + init_test stats_tsv | 未改动 |
| W42 | 部分已有 → **补（静态）** | `w42` | 正向对照（weburl/quota/stats 入口仍在，证明检查真的在扫）+ 无 time/protocol 入口/页面/模型文件/任何引用 + 无「时间限制」「协议过滤」文案；shell 侧仍执行已由 init_test 既有用例覆盖 |
| W43 | 部分已有 → **补** | migrate_test「W43」 | 备份文件生成+内容=原文件+重复迁移每次另存（时间戳推进）；新模型条目逐字段不动；整体幂等；老字段 week/timestart/timeend/sd(hd)_mode/start/end 全部清掉 |

## 2. 文件清单

**测试体系（本轮主体）**
- `test/init_test.sh`：新增 W3/W4/W5/W6/W7/W9-11/W13/W14/W16/W17/W32 共 11 个用例块（+96 checks）
- `test/migrate_test.sh`：新增 W43 两个用例块（+14 checks）
- `test/ui_static_check.py`（新）：W37/W38/W39/W42-静态，42 项结构断言，头部有「静态、非行为级」声明
- `test/ui_static_test.sh`（新）：上述的 shell 入口
- `test/run.sh`：挂上 UI 静态结构段
- `test/lint_ash.sh`：补 `local x,y` 禁用模式（W2 加固）
- `test/mutation_check.sh`：新增 21 个变异 + `MUT_ONLY` 分块过滤器（默认不设 = 全量，行为不变）
- `test/lib.sh`：fakes 链接表加 `ip`；新增 4 个默认关闭的桩开关（`FAKE_NFT_STATE`/`FAKE_CONNTRACK_LOG`/`FAKE_RESOLVE_LOG`/`FAKE_IP_NEIGH`，留空 = 桩行为与从前一致）
- `test/fakes/nft`：重写 —— 默认退出 1（不变）；设 `FAKE_NFT_STATE` 后变状态化（list/delete/insert，handle 语义对齐 offload_handle 的解析）
- `test/fakes/conntrack`：默认退出 0（不变）；设 `FAKE_CONNTRACK_LOG` 后记录参数
- `test/fakes/resolveip`：行为不变；设 `FAKE_RESOLVE_LOG` 后记录被查询 host
- `test/fakes/ip`（新）：只实现 `ip neigh show`（读 `FAKE_IP_NEIGH`），其余静默成功
- `test/fakes/date`：新增 `+%Y%m%d%H%M%S`（迁移备份时间戳用）

**生产代码（两处，详见 §3）**
- `root/etc/init.d/parentcontrol`（del_rule）
- `root/usr/lib/parentcontrol/common.sh`（PC_CONF_DIR/BACKUP_DIR 钩子）

## 3. ⚠ 改了生产代码（供 review gate）

1. **`root/etc/init.d/parentcontrol` — `del_rule`**：老 filter 表 `PARENTCONTROL_WEBURL` 链原来只删跳转、**不删链本身**（TIME/PROTOCOL 有删，WEBURL 漏了）。W4 用例按 testplan「老 filter 表 TIME·PROTOCOL·WEBURL 全部清掉」断言时暴露。修复 = 把 `PARENTCONTROL_WEBURL` 加进 filter 表的 `-F/-X` 循环。影响面：仅升级遗留的旧链清理，多清一条空链；对统一模型链（TAGQ/TAGA/PCA_）与新配置无任何影响。
2. **`root/usr/lib/parentcontrol/common.sh`**：新增 `PC_CONF_DIR`/`BACKUP_DIR` 两个可覆盖钩子（默认值 = 原硬编码的 `/etc/config`、`/etc/parentcontrol/backup`），让 A46 备份分支在主机可测（主机 `/etc/config` 不可写也不该碰）。影响面：路由器上默认值即原路径，**行为零变化**；符合该文件既有路径钩子（HOLIDAY_CACHE/USAGE_DIR/…）的先例。

除此之外未动任何生产代码；没有为让测试变绿而削弱/删除任何断言（修正的是我自己用例里的写法 bug，见 §5-4）。

## 4. 自证输出

```
$ sh test/run.sh
  ……（4 段 lint + UI 静态结构 42 项 ok）……
  PASS (76 checks)     # common_test
  PASS (176 checks)    # init_test（含本轮新增）
  PASS (94 checks)     # migrate_test（含本轮新增）
  ALL SUITES PASS
```

```
$ sh test/mutation_check.sh        # 全量约 50 分钟（init_test ~2 分钟/次 × 24）
  killed    SNI 端口 80,443→80,8443（init_test.sh 失败）
  ……（15 个既有变异全部 killed）……
  killed    W2: local a,b=0 回归（lint_ash 拦截）（run.sh 失败）
  killed    W3: start 崩在 time 之后（init_test.sh 失败）
  killed    W4: 老 WEBURL/IP 链清理用错表（init_test.sh 失败）
  killed    W5: 陈旧锁不自愈（init_test.sh 失败）
  killed    W6: trap 清锁失效（init_test.sh 失败）
  killed    W7: hotplug 判断回到旧版 bug（init_test.sh 失败）
  killed    W9: offload 删除被禁（init_test.sh 失败）
  killed    W10: offload 恢复装不回（init_test.sh 失败）
  killed    W11: conntrack 清理被禁（init_test.sh 失败）
  killed    W13: CIDR 不再直通（init_test.sh 失败）
  killed    W14: ip_mask=32 分支失效（init_test.sh 失败）
  killed    W16: cron 不剔旧条目（init_test.sh 失败）
  killed    W17: 关键词猜测被砍（init_test.sh 失败）
  killed    W32: 计数身份 ip 优先被破坏（init_test.sh 失败）
  killed    W37: 档案摘要不去秒（ui_static_test.sh 失败）
  killed    W38a: 起=止重新放行（ui_static_test.sh 失败）
  killed    W38b: 自己和自己比回归（ui_static_test.sh 失败）
  killed    W39: vacation 区块丢失（ui_static_test.sh 失败）
  killed    W42: time 入口加回（ui_static_test.sh 失败）
  killed    W43a: 迁移备份丢失（migrate_test.sh 失败）
  killed    W43b: 新模型条目被重写（migrate_test.sh 失败）

被杀 36 / 存活 0 / 锚点失效 0
```
（`MUT_ONLY=<子串>` 可分块复跑单个变异。）

## 5. 发现、取舍与如实声明

1. **W14 表示法**：`ip_mask=32` 时 shell 侧入表/下发的是**裸 IP**（`-d 1.2.3.4`），不是字面 `-d 1.2.3.4/32`；内核语义完全等价（单主机 = /32）。断言按语义（精确主机 + 无 /24 + IPv6 仍显式 /64）落，**不改生产代码去追字面表示法**。testplan W14 的字面写法建议按此理解（是否修订由 conductor 定）。
2. **UI 静态检查的能力边界**（W37/W38/W39/W42-静态）：证明「实现该行为的构造存在、且没退化成已知坏形态（如链式 gsub）」，不能证明运行时行为；已在 `ui_static_check.py` 头部与每段输出里标注。W37 的数据侧由 init_test 既有 `stats_tsv brief` 断言覆盖。
3. **W17 查询计数**：`resolve_host` 对每个名字各查一次 v4/v6，故查询日志里每个 host 恰好 2 条 —— 断言按 2 写。
4. 首轮跑出的 6 处 FAIL 全部是我方用例写法问题（grep 把变量当文件名、种子行自带 parentcontrol 字样、误删一行取值语句），逐一修正后全绿；非生产代码问题。
5. `/tmp/pc_offload_state` 是生产固定路径，测试直接读写并清理（主机 /tmp）；W11「无 conntrack」用 `mv` 暂时隐藏 `$BIN/conntrack` 后立即还原。

## 6. 遗留 / 待决

1. **生产修复 §3-①（del_rule）需要 review gate 确认**——这是本轮唯一一处行为性生产变更。
2. W2 既有覆盖声明里「`local a,b=0`」实际未被原 lint 模式覆盖；本轮已补模式+变异。如果 conductor 认为 W2 不该动，回退该模式即可（其余不受影响）。
3. 全量 `mutation_check.sh` 约 50 分钟；已加 `MUT_ONLY` 支持分块。CI 若嫌慢可按套件分片。
4. 黑盒 B1..B17 与回归 R（真机）不在本 pane 范围，待 test pane。
5. 本轮调试用的 `.pcdbg/` 临时目录已删除，工作区只留上述改动。
6. **回调通道的环境记录**：本 pane 里 `herdr` CLI 直连失败（沙箱 TMPDIR 过长 → `local socket name length exceeds capacity of sun_path`），且 herdr-mesh MCP 的 `agent_send`/`relay`/`handoff` 都会内部调用当前版本不存在的 `herdr agent send` 子命令而报错。**可用通道**：`herdr_pane_send_text`（写文本）+ `herdr_pane_send_keys ["Enter"]`（提交）到 `wR:p1` —— 本轮 PIPELINE_DONE 回调就是这样送达的。

## 7. 信号

（第 1 轮的信号行已由 §8 末尾的最新信号取代。）

## 8. loop 第 1 轮（复审返工，2026-10-04）

复审报告：`pc-acceptance-review.md`。生产代码 2 处已放行；本轮只修测试基建 S1/S2/S3 + N1/N2/N3，**未再动 `root/`**（已核对 `git status`：`root/` 无新改动）。

### 处置明细

| 项 | 处置 |
|----|------|
| **S1** fake nft 语义 | `test/fakes/nft`：① handle 改为**单调递增、从不重用**——计数器存旁文件 `<state>.next`，首次使用按现存最大 handle 播种（兼容测试手工 seed）；② `delete` 对不存在的 handle **退非 0**（对齐真实 nft）；③ acceptance_test 新增 **S1 子测试**钉住「删中间一条（handle 2）后新 insert 拿 handle=4，不重用 2、不撞残留 3」+「delete 不存在的 handle 退非 0」；④ 新增变异 `S1: nft 桩 handle 重用回归`（把分配退回「现存行数+1」→ S1 断言必须红） |
| **S2** ui_static 过度钉字面量 | `ui_static_check.py`：w37 的整句钉死（`'if not rec then return "-" end'`、`'"%d / %d %s", rec.used, rec.quota'`、`'mac .. " （" .. n .. "）"'` 等）收敛到最小语义 token（`return "-"` 哨兵、`translate("不限")`、`string.format("%d / %d %s"`、`":sub(1, 5)"` ×2、`\w+ == "00:00:00" and \w+ == "23:59:59"`、全角括号哨兵 `" （"`/`"）"`）；w37/w39/w42 **补去注释**（新增 `strip_lua`，shell 侧 `strip_shell` 去整行 `#`；w38 复用同一 helper）。保留结构性检查：w38 禁止链式 gsub、w39 shell↔UI 字段名契约、w42 正向对照。W37 变异锚点（`sub(1, 5)`）复查后无需改，仍可鉴别 |
| **S3** init_test 破 1k 行 | **拆分**：W3..W32 验收块整体迁入新文件 `test/acceptance_test.sh`（292 行，挂进 `run.sh`）；`write_basic/cfg_begin/cfg_section/cfg_apply/fresh/flat` 提为 lib.sh 共享；新增 `put_weburl <mac> <domains> [ip] [quota]` 夹具构造器消除 8 处重复夹具。`init_test.sh` 1151 → **800 行**；**断言逐字保留、未削弱**（acceptance 63 checks 全部由原块迁移 + S1 子测试） |
| **N1** filter 行无变异 | 新增 `N1: filter WEBURL 清理行回退` 变异（del_rule 的 filter `-F/-X` 循环去掉 `PARENTCONTROL_WEBURL`，即 :572 那次生产修复的回退）→ 期望 acceptance_test（W4 的「filter 表无 PARENTCONTROL 链」）失败 |
| **N2** 隐藏 conntrack 不封闭 | 弃用 `mv` 隐藏法；conntrack 桩加 `FAKE_NO_CONNTRACK=1` 开关（一律退非 0）。生产侧 `command -v` 仍能找到桩但每次调用失败——可观测行为与「没有 conntrack」一致（不 purge、不报错、构建不受影响），且不会在装了 conntrack-tools 的 CI 上误调真二进制。W11 断言改写为「conntrack 不可用 → …」（语义不变） |
| **N3** 真实内网段 | W9-11/W32 夹具与断言里的 `<lan-cidr>` 全部改为 RFC 5737 `192.0.2.x`（192.0.2.51 / 192.0.2.160）；`grep -rn <lan-cidr> test/` 已清零 |

### 关键输出

```
$ sh test/run.sh
  locals / ash / luci globals / TSV 唯一性 / UI 静态检查 通过
  PASS (76 checks)     # common_test
  PASS (116 checks)    # init_test（拆分后回到 <1k 行）
  PASS (63 checks)     # acceptance_test（新；含 S1 子测试）
  PASS (94 checks)     # migrate_test
  ALL SUITES PASS

$ sh test/mutation_check.sh   # 38 个变异（36 + N1 + S1）
  被杀 38 / 存活 0 / 锚点失效 0
```

### 变异套件归属调整（随 S3 拆分）

W3/W4/W5/W6/W7/W9/W10/W11/W13/W14/W17/W32 的变异套件从 `init_test.sh` 改指 `acceptance_test.sh`（被改坏的源码路径对应的断言现在住在新套件里）；W16 留在 `init_test.sh`（其鉴别断言「重复写入不产生重复项」仍在原地）；W2（run.sh）/W37-W42（ui_static）/W43a/b（migrate）不变。

### 本轮确认

- **未动 `root/`**（`git status` 中 `root/` 仅保留阶段 4 已放行的 2 个文件，本轮零新增改动）。
- 复审 B1（testplan 明文凭据）属 conductor 侧文档修复，不在本轮范围。
- 返工过程中发现并修正一处自伤：acceptance_test 初版漏抄了 W9-11 的 `FAKE_IP_NEIGH` fixture 写入行（neigh 断言红），补回后全绿——非断言削弱。

## 9. 信号（第 1 轮）

✅ PIPELINE_DONE: 复审 S1/S2/S3/N1/N2/N3 全部处置完成——run.sh ALL SUITES PASS（common 76 / init 116 / acceptance 63 / migrate 94）、mutation_check 38/38 全杀（含新增 N1/S1），本轮未动 root/。

## 10. loop 第 2 轮（修 A36/B16 编辑页 500，2026-10-04）

### 根因（真机证据 + 代码模型互相印证）

- 真机保存「网址过滤」编辑页 500：`parts.lua:36: bad argument #2 to 'format' (string expected, got table)`。
- `#2` 就是第二个 format 实参 = **`self.section`**。在 LuCI 的 CBI 类模型里，字段（`AbstractValue`）的 `.section` 存的是 **AbstractSection 对象**（`weburl_edit.lua` 里是 `NamedSection` 实例），不是 uci 名字字符串；名字存在**对象的 `.section` 属性**里。把对象传给 Lua 5.1 的 `string.format("%s")`（`%s` 不做 tostring）即抛此错。
- ucodebridge 只桥接 `luci.http`/uci/dispatcher，**不改变 CBI 类的上述结构**——与真机报错完全一致。
- 该缺陷是 HEAD 既有：只要编辑页四个时间字段（默认值 `00:00:00`/`23:59:59` 非空）触发 validate 就必炸 → 编辑页核心入口实际不可用（A36/B16 FAIL）。不受影响的路径：列表页增删（`weburl.lua`）、其它页面（`parts` 仅被 `weburl_edit.lua` require，已 grep 证实）。

### 改了什么

| 文件:行 | 改动 |
|---|---|
| `luasrc/model/cbi/parentcontrol/parts.lua`（`submitted()`，:34-43） | 从 `self.section` 的 **`.section` 属性**取 uci 名字（`type` 守卫：对象取 `.section`，字符串原样——兼容不同 LuCI 形态）；名字取不到（非串/空）时返回 nil = 跳过兄弟比对（fail-open，不阻断保存）。`format` 只喂字符串 |

**语义保持不变**：`validate_window` 的「起必须早于止」、双向 `>=` 判错（起=止也错）、禁止链式 gsub 自己和自己比——逐字未动；只修了「怎么拿到兄弟字段的提交值」。

**为什么不用别的写法**：`self:formvalue(other_option)` 会带上 `or self.default` 兜底（qend 默认 `23:59:59`），兄弟字段未提交时会产生假比较值；直接用 `http.formvalue(cbid(...))` 与 LuCI 自身 `AbstractValue.cbid` 的命名规则一致（表单字段名即 `cbid.<config>.<section>.<option>`），行为最贴原意。

### 测试同步（白盒）

- `ui_static_check.py` w38 新增两条结构断言：`submitted` 从 `self.section.section` 取名（哨兵 `self.section.section` 在、且不得出现 `format(self.map.config, self.section,`）。既有结构断言（禁链式 gsub、双向 `>=`、两字段都挂校验）全部保留。
- `mutation_check.sh` 新增 `B16: submitted 直接 format section 对象` 变异（回退到原缺陷形态 → w38 必红）。总数 38 → 39。

### 自证输出

```
$ sh test/run.sh                → ALL SUITES PASS（rc=0；common 76 / init 116 / acceptance 63 / migrate 94 + 5 段检查）
$ MUT_ONLY=B16 sh test/mutation_check.sh → killed 1 / survived 0 / 锚点失效 0
$ MUT_ONLY=W38 sh test/mutation_check.sh → killed 2 / survived 0 / 锚点失效 0（既有变异不受写法变化影响）
$ sh test/mutation_check.sh（全量，后台） → 被杀 39 / 存活 0 / 锚点失效 0
```

### 查证说明（如实）

- 本 pane 的执行沙箱挡住了对 `/tmp/pc-bb-env.sh` 的访问（workspace 之外），**只读 SSH 未能在本 pane 执行**。
- 根因改由三重证据锚定：① 真机报错的 `argument #2` 正是 `self.section` 实参 → 设备上它是 table；② LuCI CBI 类模型（`AbstractValue.__init__` 存 section 对象、`NamedSection.__init__` 把名字存进 `.section`）在 23.05 的 Lua cbi.lua 中即如此，ucodebridge 不改类结构；③ 修复对两种形态（对象/字符串）都做了 `type` 守卫，即使某版本行为不同也不会再炸。

### 给 test pane 的确认步骤（真机 B16 重跑）

1. `source /tmp/pc-bb-env.sh`（deadman 按安全协议 §1 先起好）。
2. LuCI 登录 → 打开任一 weburl 条目的「编辑」页 → 直接点保存：**应 200、无 `Runtime error`**；「起=止」提交应被服务端校验拒绝并回显「可用起必须早于可用止」；「起<止」正常落盘。
3. 核对 `uci show parentcontrol.@weburl[N]` 的 `sd/hd_qstart/qend` 与提交一致（md5 变化仅来自该节）；iPad 节不受影响（R6 口径）。
4. 顺带回归：编辑页把「起」改成晚于「止」→ 应被拒；删空两字段 → 应按「不限制时段」兜底保存成功（shell 侧 `pc_qwin_sec` 既有语义）。

## 11. 信号（最新）

✅ PIPELINE_DONE: A36/B16 编辑页 500 已修（submitted() 改从 .section 取 uci 名字，validate 语义不变），白盒全绿（run.sh ALL SUITES PASS；mutation 39/39 全杀含新 B16 变异），给 test pane 的真机确认步骤已写入 progress §10。

✅ PIPELINE_DONE: F1/F2 修复轮（2026-10-08 20:05–20:32）—— 修复「配额封锁链每分钟空窗」（`build_quota_blocks` 规格未变则 return 0，不再 `-F` 后重建；新增 `render_quota_spec`/`spec_rule_counts`/`live_rule_count`/`ipt_do`）与「带静态 IP 的条目 IPv6 静默失败、永不计数」（新增 `addr_is_family`，`devcount($ipcmd $module $idx)` 族不符回退 MAC；连带 `allow_lan_in` 族守卫）。白盒全绿：`run.sh` ALL SUITES PASS；acceptance **PASS (73 checks)**（新增 10 条 F1/F2/F2′ 回归断言）；mutation **killed 43 / survived 0 / 锚点失效 0**。真机黑盒 **B1–B17 全 PASS（0 FAIL / 0 SKIP，周期 ≈15 分钟）**，含首次通过 B3（关总开关→规则 0/0）与 B9（stop→nft `flow add @ft` 恢复/state=on）。修复版已按用户批准**部署真机**并按 S1–S7 复验：config md5 `247c232f…` 不变、mangle 72/54、QUOTA 53/39、iPad 规则字节级未变、F1 线上 55 样本 0 异常/v4 最低 53；deadman 未触发即解除，`/tmp/pc-*` 已清。详见报告 `pc-acceptance-test-report.md` §H（含 §H.8 部署）。代码/报告 = commit `7719d8e` + `5fa503f`，已 push `origin/main`。**真机现与仓库一致。**

✅ PIPELINE_DONE: 1.8.0 发布轮（2026-10-08 21:00–21:35，用户批准「发布新版本到路由器」）—— ① `PKG_RELEASE` `20261002`→`20261008`（commit `301f22d`），tag `v1.8.0` 已推（`334492f`）；本仓库的 GitHub Actions 从未跑（需网页端 Enabled + `contents: write`），**改为本地手工组 ipk**。② **关键教训：OpenWrt `.ipk` 是 gzip 压缩的 tar，不是 `ar` 归档** —— `ar rc` 组包必被 opkg-lede 报 `Malformed package file`；正确做法 `COPYFILE_DISABLE=1 tar --format=ustar --no-xattrs --owner=0 --group=0 --numeric-owner -czf … ./debian-binary ./data.tar.gz ./control.tar.gz`（42577 B，md5 `7118e3df…`，成员顺序与官方包一致）。③ `opkg install` rc=0，`1.7.1 → 1.8.0-20261008`；**conffile 保留**（config export md5 `247c232f…`、raw `0d7609d2…` 均未变）；逐文件 **26/28 一致**（2 处 DIFF 为 conffile 保留 + uci-defaults 自删，均正确）；`/usr/share/ucitrack/luci-app-parentcontrol.json` 已存在 → **F4 修复**；`protocol.lua`/`time.lua` 已从包清单移除。④ **B16 真浏览器 PASS** —— 抓到 LuCI 落盘是**三段式**：`POST weburl_edit/<SID>`（CBI 暂存）→ `POST /admin/uci/apply_rollback?<ts>`（commit+apply，带回滚计时）→ `POST /admin/uci/confirm?<ts>`（确认）；此前 curl 只做第①段故不落盘，**不是产品 bug**。填 `07:30:00/23:15:00/37` 后 CLI/ubus/原文三视图一致，`uci changes` 空，iPad 规则 md5 逐字节不变。⑤ **★新发现 F5（真实缺陷，未修）**：`pc_ids_all`/`pc_ids_on`（`root/usr/lib/parentcontrol/common.sh:18-30`）只匹配匿名段的 `@weburl[N]` 正则，**命名段（`config weburl 'kids'`）被静默忽略**（A/B 实测：命名段 72/54+53/39+17/13 全不变、本机 Mac 规则 0；改匿名段后 100/66+77/48+21/16+规则 28 条）→ 失效方向**不安全**（漏管非误封），建议修。⑥ **★运维隐患**：`/sbin/rpcd` 缓存 uci 配置，`cp` 覆盖 `/etc/config/*` 不刷新缓存，之后任何 ubus `commit` 会把陈旧快照写回（实证：deadman 还原后被浏览器 CBI POST flush 回上一轮值）→ **文件级还原后必须 `ubus call uci reload_config`**，deadman 设计需补此步。⑦ 收尾 gate **14 项全绿**（间隔 25 s 两次测量稳定）：config `247c232f…`、mangle 72/54、QUOTA 53/39、PREROUTING 顺序、weburl 节 2 / BBTEST 0、iPad v4 `4de4df07…`/v6 `3f2ab84d…` 字节级不变、测试机残留 0、cron 2、探针 301/200；`quotaspec` md5 `03ead983…` 与旧部署态一致。清理：精确 kill 我方孤儿 `sleep`（pid 6655/14325/17687，ppid=1），**保留 passwall 的 sleep**（教训：绝不 pkill 盲杀 sleep，按 ppid 甄别）；清 `/tmp/pc-*`、`/tmp/pcd*`，保留 `/tmp/pc_offload_state`。详见报告 `pc-acceptance-test-report.md` §I。**未决：F5 待用户决定是否修复并出 1.8.1；F3 有意不修。**

## 12.1 信号（F5 修复轮，最新）

✅ PIPELINE_DONE: F5 修复轮 → **1.8.1-20261008**（2026-10-08，用户决策「立即修，出 1.8.1」）—— ① **修复**：`root/usr/lib/parentcontrol/common.sh` 的 `pc_ids_all`/`pc_ids_on` 由「只匹配 `@weburl[N]` 的 sed」改为共用 **`pc_uci_scan`** 一次规范化扫描（输出 `类型|下标|字段|值`）。口径来自真机沙箱实测：**命名段在 `@type[N]` 下标空间里同样占位**（匿名/命名/匿名 → `[0]/[1](命名)/[2]`），故匿名节用 uci 打印的位置下标、命名节用「已见同类型节数」补位；**保留**「匿名节只有选项行也能取到下标」的老行为（测试夹具 `@weburl[11]` 依赖）。**实作陷阱：awk 未初始化数组元素是 `""` 而非 `0`，必须 `idx = cnt[typ] + 0`**，否则第一个命名节链名成 `PCA_weburl_`。新增 `pc_opts_all`，并把 `weburl_macs_all()`/`weburl_ips_all()`（`init.d:276-282`，原用 `grep weburl` —— **同样漏命名段，§I.4 初版写反了，已更正**）改为 `pc_opts_all weburl mac|ip`。② **白盒**：`run.sh` → `ALL SUITES PASS`（common **81** / init **122** / acceptance **73** / migrate **94**）；新增 5 条 common + 6 条 init F5 用例；`mutation_check.sh` → **killed 47 / survived 0 / 锚点失效 0**（新 4 条 F5 变异全杀）。③ **夹具修正**：`test/fakes/uci_import.py` 改为**按类型**编号（原先只给匿名节编号，与真机不符）；`test/fakes/uci` 加 `resolve()`（字面键优先的 `@type[N]` 解析）。④ **打包脚本化**：新增 `test/build_ipk.sh`（从 Makefile 读版本、gzip-tar 组包、成员顺序 `./debian-binary ./data.tar.gz ./control.tar.gz`）；`PKG_VERSION` `1.8.0`→**`1.8.1`**；新增 `test/build_ipk.sh`（可复现：gzip `-n` + 冻结 mtime，两次构建 md5 相同）；产物 28 文件 / 43097 B / md5 **`21986e6b80f2b5efdc8b10b2f900745c`**（真机部署用的是可复现化之前的构建 `7ecfcea5…`/43552 B，**解包后 28 文件内容逐字节相同**）。⑤ **真机（S1–S7 合规）**：`opkg install` rc=0，`1.8.0 → 1.8.1-20261008`；conffile 保留（export `247c232f…` / raw `0d7609d2…` 未变 → migrate no-op）；`init.d` `7b49e500…`、`common.sh` `a422ef5a…` 与仓库**逐字节一致**。**★F5 真机决定性验证（命名节 `pcf5test`）**：mangle 72/54→**88/66**、QUOTA 53/39→**65/48**、本机 Mac 规则 0→**16**，删除后全部回到基线且 export md5 回 `247c232f…`。⑥ **收尾 gate 18 项全绿**：iPad v4 `4de4df07…` / v6 `3f2ab84d…` **逐字节不变**；探针 小红书 302 / 百度 200；deadman `fired=no` 已解除；`/tmp/pc*` 仅剩 `/tmp/pc_offload_state`。详见报告 `pc-acceptance-test-report.md` §J（含 §J.1 实现、§J.2 白盒/变异、§J.4 真机 A/B 表、§J.5 gate）。**未决：F3 按用户约束有意不修。**

## 12.2 信号（项目元信息整理轮，1.8.3-20261009）

✅ PIPELINE_DONE: 项目元信息整理轮（2026-10-09，用户要求移除派生来源表述、README 不再出现相关字样，并决策清掉源码署名与版权行、换仓库简介、重建仓库）—— ① **仓库字样清零**：README 删掉来源声明行与参考链接行，标题改中性，新增 `## 更新日志`（1.8.3/1.8.2/1.8.1/1.8.0）；`root/etc/init.d/parentcontrol` 删历史署名行、第 3 行自称改为「本插件新增」；`common.sh`/`build_ipk.sh` 与 4 份工程文档的派生表述改中性；`Makefile` 删历史版权行。对相关关键词 `git grep` 全仓库 0 命中。**许可证提示已如实告知用户**（Apache-2.0 §4(a) 要求保留版权声明，删除由用户确认）。② **版本**：`PKG_VERSION` `1.8.2` → **`1.8.3`**（`PKG_RELEASE` 仍 `20261009`）。③ **白盒**：`sh test/run.sh` → `ALL SUITES PASS`。④ **打包可复现**：`sh test/build_ipk.sh` 两次 → `luci-app-parentcontrol_1.8.3-20261009_all.ipk` md5 **`69a1787ba3db50fbb7a5bc720cc99325`**（28 文件 / 44173 B）。⑤ **真机（S1–S7 合规）**：`opkg install` rc=0，`1.8.2 → 1.8.3-20261009`；`init.d 14b3d555…`、`common.sh 9276f6d0…` 与仓库逐字节一致；**零副作用** —— config `0d7609d2…` / export `247c232f…` 不变，`v4m=72 v6m=57 v4q=53 v6q=42` 与部署前相同（仅注释变更），iPad 指纹 v4 `4de4df07…` / v6 `3f2ab84d…` 逐字节不变；探针 302/200；deadman `fired=no` 已解除，`/tmp/pc-*` 已清。⑥ **踩坑**：核对 iPad 指纹时 `grep -F` 用大写 MAC 而链里是小写 → 得到空串 md5，已纠正。详见报告 `pc-acceptance-test-report.md` §K。
