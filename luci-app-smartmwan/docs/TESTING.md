# 测试与验收

## 1. 命令一览

```sh
# 单元/回归（无需网络、无需 root、无需路由器）
cargo test --offline --lib          # 期望 378 passed; 0 failed
cargo test --offline --bins         # 期望 2 passed（--reclaim 配置回落）

# Lint 与风格（提交前置条件，必须带 -D warnings）
cargo clippy --offline --all-targets -- -D warnings # 期望 0 warning
cargo fmt --all -- --check                    # 期望 无差异

# 构建
cargo build --offline                # 期望 无 warning
cargo build --offline --release      # 发布前基线

# 工程红线（禁 Lua）
./scripts/no-lua-check.sh            # 期望 退出码 0

# 守护进程一次性命令（--check/--dump-nft/--capabilities 只读；--reclaim 需 root 且会清场）
smartmwand --check                   # 只做校验，不写内核
smartmwand --dump-nft                # 打印将要下发的 nft 程序
smartmwand --dump-defaults           # 打印默认 UCI 配置（打包同源用）
smartmwand --dump-include            # 打印 nftables.d 占位片段（打包同源用）
smartmwand --capabilities            # 在设备上实测 nft 语法能力
smartmwand --once                    # 单轮：探测→决策→下发→回读，不常驻
smartmwand --restore-last-good       # 回到上一次成功状态
smartmwand --reclaim                 # 一次性回收本插件全部内核对象（卸载/排障；幂等）
```

## 2. 测试矩阵（覆盖到的层与不变式）

| 层 | 测试数 | 关键不变式 |
|---|---:|---|
| `lib` 核心 | 6 | 标记字段往返；所有权区间覆盖全部合法标记且不含他人典型值；`RULE_MASK` 只隔离槽位；UTF-8 安全截断；槽位 0 被拒 |
| `config` | 51 | UCI 文本 round-trip；未知键保留；缺字段落默认；迁移旧键；枚举非法值报错而非静默回退；默认关闭；diff/fingerprint 稳定；20 条校验规则（含同优先级规则范围重叠） |
| `system` | 118 | netlink 报文编解码逐字段；`plan()` 只在 usable 时成对产出规则与路由；`Diff::blocking()` 拦住 Error 级冲突；`Applier` 回滚逆序；优先级带所有权判定；`exec` 超时杀进程/白名单/输出封顶；conntrack 行数上限与标记解析；nft 程序文本黄金样本（含 IPv6 关闭不建 v6 集合、占位文件单一 hook、**每个条件必须出现在规则文本里**、同族多目的条件各出一条规则、能力不足时不下发该条件也不留兜底）；**能力探测判定**（8 条脚本全通过 ⇒ 含 `jhash_seed` 在内逐项开启、全失败 ⇒ `nft_exists` 仍为真而高风险语法一律关闭、`jhash_map` 以 `ct_mark_range` 为前提；`Nft::version()` 只在退出 0 且有输出时给版本号）；netlink 会话成功 ACK 后终止；路由 dump 按表号过滤（内核不理会 dump 请求里的 rtm_table）；`nft -c` 必须带 `-f` |
| `health` | 50 | 探测四类均绑定设备与源地址；`Unsupported`/`LocalError` 不改状态；并发额度如实反映配置；取消路径能真正中断批次；滑窗指标与置信门槛；状态机全部迁移边 + 预热 + 时间驱动 `tick()` |
| `scheduler` | 58 | 权重比例 3:1→桶 48:16；DEGRADED 半权重；不可用线路 0 桶；全零映射必带原因；`WeightedEcmp` 返回 `Unsupported`；`buckets=0` 报配置错；相同输入 0 搬动；交织场景搬动数在预算内；动态算法「采样不可信」降级注记；优势闸门 0 搬动；消失槽位强制清出；连接上限触发迁移；`interval_elapsed` 的 0 语义与回绕；回切四条件；强制切换与目标不可用时保留指令；主备顺序不捏造线路 |
| `rules` | 51 | CIDR 网络位归一与按族分拣；坏值**报错不跳过**；端口拒绝 `0`/`0-1024`/逆序/取反；MAC 三种写法统一小写；域名拒通配符与 URL；slug 归一且去重确定性（`-2`/`-3`）；预置项**代码零内置**、缺 `source` 拒绝、空目的拒绝、文件内与跨文件重复 id 拒绝、坏文件整批失败、>512KiB 拒绝；域名注册表按域对账（增/删/保留/v6 跳过/满额拒绝/截断计数）、过期与两寿命陈旧窗口、**解析失败不清空旧元素**；`compile()` 合并语义（目的与域名并集、端口与协议规则赢、客户端条件只来自规则）、四种不产出情形、超上限报错不截断、`pin` 指向不存在/未启用槽位报错、mark 为 0 报错、无条件匹配报错；**端到端**：`compile()` 产物直接喂 `firewall::build()` 并断言集合声明与规则文本同时出现 |
| `logging` | 5 | 等级过滤；环形缓冲上限与 `dropped()` 计数；轮转；敏感字段脱敏 |
| `rpc` | 18 | 方法表与架构文档逐条对齐（23 个、无重名、全部带命名空间、写方法标对）；信封形状（成功不带 error、失败不带 data、protocol/timestamp 必填）；12 个错误码映射逐条锁定；帧编解码 round-trip、零长/超大/EOF 三态；陌生 uid 在分发前被拒且错误信息带 uid；无主循环时写方法明确报错（不假装成功）；缺参数是 validate 错误；`validate` 不落任何文件；密钥字段递归脱敏（密码/token/key 不进日志）；`wwwdata` 从 `/etc/passwd` 解析而非猜测、文件缺失时只允许 root；socketpair 上取 `SO_PEERCRED`；未测量时线路状态必须是 unknown/未测量（不许显示健康）；`apply` 回执原样透传（ok=false 也 ok=true 送出，rollback 字段不丢）|
| `transaction` | 21 | 阶段顺序固定（validate→plan→nft 试算→路由下发→路由复核→nft 下发→nft 复核→快照）且阶段名对日志/RPC 稳定；单事务锁串行化（第二个提交者卡在入口）；试算失败不动内核也不留状态文件；路由失败绝不进 nft 提交；nft apply 失败回滚路由并如实报告回滚结果；nft 复核失败**按逆序**回滚（先 nft 后路由）且不写快照；外来优先级冲突在任何副作用之前拦下；无 nft 通道时拒绝 enabled 提交但允许停用；幂等第二次提交（`[check, apply, check]`，`changed=false`）；快照写失败不得报成功；停用⇒自有对象全清；`reclaim()` 只删自己的规则/路由/表并列出他人对象；游戏规则从 UCI 段一路落到最终 nft 文本；`best` 无结论进 `pending` 不编造线路；事务 id 唯一且写进快照。**限定**：nft 通道是 `FirewallExec::Sim` 替身，只验编排顺序，**不验证 nft 语法** |
| `bin`（main.rs） | 2 | `--reclaim` 的配置回落：配置不可读（目录/坏内容）与不存在都回落默认参数继续清场 |

`tests/`（集成）目前为空 —— 计划见 §4。事务链路的编排结论现在全部落在 lib 单测里
（`transaction` 21 条），集成测试要做的是「黄金样本回归 + 真实 `FirewallExec::Real`」，二者都还没写。

## 3. 工程测试（非功能）

| 检查 | 命令 | 本环境实测 |
|---|---|---|
| 零 Lua（文件 / `require("luci.*")` / Makefile 依赖） | `./scripts/no-lua-check.sh` | 干净树退出 0；注入 `src/accidentally_controller.lua` 或 `require("luci.dispatcher")` 后退出 1（**两个方向都实测过**） |
| 依赖面 | `cargo tree` | 运行依赖仅 tokio / libc / serde / serde_json / thiserror |
| 可复现 | `Cargo.lock` 入库 | 是；apk 构建用 `--offline` |
| 无 shell 拼接 | 代码审查 + `exec.rs` 测试 | 唯一入口，参数数组、绝对路径白名单 |
| 许可证 | `LICENSE` | GPLv3 全文（含「或更高版本」模板），清单声明 `GPL-3.0-or-later` |

## 4. 计划中的测试（尚未编写）

* `tests/golden_nft.rs`：固定配置 → 期望 nft 程序文本快照，防止规则生成回归；
* `tests/config_tx.rs`：save→diff→apply→rollback→last-good 的端到端（用临时目录与假的 `RouteOps`/`Nft` 实现）。
  **M6 之后这条的范围缩小了**：编排语义已在 `transaction` 的 21 条单测里覆盖（含替身通道），
  集成测试要补的是「跨进程重启后从磁盘快照恢复」与「`FirewallExec::Real` 下的真实回滚」；
* `tests/rpc_acl.rs`：信封格式、错误码稳定性、未授权 uid 被拒、读方法无副作用；
* `tests/live_netlink.rs`：`#[ignore]` 的活体冒烟测试，只在有权限的 Linux 上显式运行，
  验证本项目的 netlink 解码与内核真实输出一致（沙箱内核可跑读路径，但不等于 OpenWrt 内核）。

## 5. 打包产物校验（M9，2026-10-26 实测）

构建环境：真实 OpenWrt/ImmortalWrt 25.12 SDK（mediatek/filogic，aarch64_cortex-a53 musl，
gcc 14.4.0），`make package/luci-app-smartmwan/compile V=s` → **BUILD OK**。

产物：`bin/packages/aarch64_cortex-a53/base/luci-app-smartmwan-0.4.0-r1.apk`。
校验方法与结果（全部实测）：

| 校验项 | 方法 | 结果 |
|---|---|---|
| 包元数据 | `apk adbdump <apk>` | name/version/arch=noarch/license=`GPL-3.0-or-later`/depends（firewall4, libc, luci-base, nftables, rpcd——**无任何 Lua 包**）|
| 维护脚本 | `apk adbdump` 的 `scripts:` 段 | `pre-install`（停旧实例）、`post-install`（`default_postinst` + 幂等挂 firewall include）、`pre-deinstall`（`default_prerm` + stop/disable + `--reclaim`）、`post-deinstall`（清 include 段与运行期状态）、`pre/post-upgrade`（构建系统由 preinst/postinst 派生）**全部在包内** |
| 安装树 | `apk extract --allow-untrusted` 解包 | 20 个文件齐全（二进制 / config / init.d / nftables.d / rpcd ucode+ACL / menu.d / 7 视图 + JS 模块 + CSS / conffiles 清单）|
| 二进制架构 | `file` | ELF 64-bit **aarch64**，静态链接，无 section header（musl strip 后）|
| 同源一致性 | 解包产物逐字节 `diff` 仓库快照 | config / nftables.d / init.d / ucode 桥 / ACL / menu / 全部 JS/CSS **逐字节一致**；`smartmwand --dump-defaults` / `--dump-include` 反向生成与包内文件一致 |
| conffiles | 解包 `/lib/apk/packages/*.conffiles_static` | 仅 `/etc/config/smartmwan`，带 sha256 |
| 可复现 | `Cargo.lock` 入库 + `--offline` | 构建机无需网络；SOURCE_DATE_EPOCH 由构建系统固定 |

排障备忘（首次构建踩过的坑）：apk 维护脚本的 define 名必须叫 `preinst`/`postinst`/`prerm`/`postrm`
（`include/package-pack.mk` 的 `BuildPackVariable` 只认这四个；`postinst`/`prerm` 的内容会被构建系统
拼进自动生成的 `post-install`/`pre-deinstall` 里）。自造名字**静默丢弃**，包里只剩默认脚本 ——
必须用 `apk adbdump` 核实，不能只看构建日志。

## 6. 10 条交付判据（逐条如实回答）

| # | 判据 | 现在的回答 |
|---|---|---|
| 1 | 能在 OpenWrt 25.12+ 安装 | **是（真机实证）**：ImmortalWrt SNAPSHOT 真机安装/升级/卸载全部通过，post-install/pre-deinstall 钩子按预期执行 |
| 2 | 能构建 | **两侧都能**：`cargo build --offline`（WSL）+ 真实 SDK `make package/.../compile`（aarch64 musl）都通过 |
| 3 | 能测试 | 能：382 lib + 2 bin 单测 + Lua 红线脚本 + WSL 真 nft/netlink 端到端 + 真机 ubus 23 方法往返；`tests/` 目录的集成测试仍未写 |
| 4 | 零 Lua | 是，且有自动化证明（两个方向实测）；包依赖里也无任何 Lua 包 |
| 5 | 后端为模块化 Rust 常驻服务 | **是（真机实证）**：守护进程常驻、procd 托管、SIGHUP 重载、SIGTERM 优雅关停、崩溃回收、幂等复核都在真机运转 |
| 6 | 前端 7 页可用 | **服务端可用（真机实证）**：`admin/network/smartmwan` 7 页全部 200、菜单树正确下发；浏览器渲染待人工确认（需退出重登刷新菜单缓存） |
| 7 | 数据面真实生效 | **是（真机单线路实证）**：enabled=1 后 ip rule 优先级 1000 + 槽位掩码精确落位、表 101 完整镜像、`inet smw` 保护/绕行集合正确、modem0 healthy、实际出网成功；**双 WAN 均衡/主备切换待第二线路接入** |
| 8 | 安全清单落实 | **是**：注入/配置只读/残留/探测负载/并发事务锁/RPC ACL（SO_PEERCRED + uid 白名单）/审计（脱敏）/前端轮询自停/方法级 ACL（acl.d，无通配）均有实现与验证 |
| 9 | 不把模拟数据当实时状态 | **是（真机实证）**：未测量时线路显示 unknown/未测量；停用后决策与数据面一致（carries_traffic=false）；探测不可用时 WARN 诚实告警 |
| 10 | 列出未完成特性 | 是：`README.md`、`CHANGELOG.md`「已知缺失」、`docs/REQUIREMENTS.md` 状态列、`docs/PROGRESS.md` §4 |

## 7. 本环境的真实限制（2026-10-26 复核）

| 项 | 状态 | 说明 |
|---|---|---|
| `rustc` / `cargo` | 可用 | **1.99.1**（WSL Debian，`~/.cargo`）；此前 Windows 侧 1.98.1 的 clippy/rustfmt 组件包 404，已迁到 WSL 后可用 |
| `cargo clippy` | **可用** | 0 警告（`-D warnings`）；首轮 20 条风格警告已在 `32b97ad` 清零 |
| `cargo fmt` | **可用** | `cargo fmt --all -- --check` 无差异 |
| `nft` 二进制 / netfilter 内核模块 | **WSL 与真机均可用** | WSL nft 1.1.3 完成端到端编排验证；真机 nft 1.1.7 完成能力探测与数据面验证。两版都缺 `dynamic,timeout` 集合与 jhash 种子参数 —— 能力探测如实报「不可用」，域名规则走降级路径并给可见告警 |
| 真实路由/规则下发 | **真机已执行** | 真机（ImmortalWrt SNAPSHOT，mediatek/filogic aarch64，内核 6.18.55）完成：安装/升级/卸载、enabled=0 零触碰、enabled=1 数据面（ip rule 1000 / 表 101 / inet smw）、状态机全链路、幂等复核、停用回收、管理面不失联。**双 WAN 切换场景待第二线路接入** |
| OpenWrt SDK / 交叉工具链 | **可用（WSL）** | 真实 25.12 SDK（mediatek/filogic aarch64 musl）完成 apk 构建，产物校验见 §5 |
| 设备 SSH | **已解决** | dropbear 密码认证正常（Windows 侧 paramiko；此前失败是设备当时的瞬时状态） |
| ping socket（健康探测前提） | **需部署配置** | ImmortalWrt 内核默认 `net.ipv4.ping_group_range=1 0` 禁用 ping socket；部署需 `sysctl -w net.ipv4.ping_group_range='0 2147483647'` 并持久化到 `/etc/sysctl.conf`。未解锁时健康探测全部诚实告警（线路状态 unknown，不伪造） |
| `raw.githubusercontent.com` | TLS 中断 | 上游源码引用改走镜像站与本地已核对文件 |

结论：**「端到端可运行 + 可打包 + 真机数据面生效」已全部证实**。剩余真机项：双 WAN
均衡/主备切换（需第二线路接入）、断电重启幂等、浏览器侧人工确认。
