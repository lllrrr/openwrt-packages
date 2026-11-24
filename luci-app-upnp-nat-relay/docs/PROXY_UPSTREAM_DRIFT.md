# 代理上游漂移：怎么读、怎么处理

`proxy-upstream-baseline.json` 记录**实际资格化过**的上游代理版本，不是"允许存在的版本"。
`scripts/check-proxy-upstreams.py` 每周（`.github/workflows/proxy-compatibility.yml`，周一 03:23）
以及改到相关文件时，把这些记录和上游最新 release / 分支 HEAD 比一次。

## 漂移只报告，不挡出包

`Proxy compatibility canary` 的 `upstream-drift` job 会打印一张表，漂移的行标 `**DRIFT**`，
run summary 里还有一节 `### Upstream drift reported — does not block the release`。脚本此时 **exit 0**。

理由写在基线的 `policy` 里：上游发新版不是"功能坏了"的证据。本插件只与这些包**共用防火墙**——
自己插链、不写它们的文件、不驱动它们的服务——所以它们的版本号变了，等于"该复测了"，不等于"我们坏了"。

真正会挡住发布的是能描述失败的信号：relay / adapter 契约失败、资格化清单无效、不可变 tag 冲突；
以及基线自身的缺陷（缺字段、未知 `kind`）——那是本仓库的错，脚本对它 **exit 1**，
并由 `tests/proxy-upstream-policy.py` 钉死：把阻断权加回漂移必须是显式评审过的改动，不能顺手滑进去。

## DRIFT 出现后该做什么

1. **先看改了什么，不是看版本号。** 比 baseline 的 ref 和当前 ref：
   `gh api repos/<repo>/compare/<baseline>...<current>`，重点看 `nftables.sh` / `iptables.sh` /
   链名 / `hook prerouting` 优先级 / `sysctl` 一类会改变共存行为的行。
2. **判断是否落在共存面上。** 只改 LuCI 界面、翻译、订阅解析 → 与防火墙共存无关；
   改链序、链优先级、TPROXY、`rp_filter`、`src_valid_mark` → 落在共存面上，默认必须实跑。
3. **要跑就跑一次共存流程**（隔离 OpenWrt，不碰主路由）：
   - 装上游包的目标版本，确认服务起来；
   - 装/启用 UPnP relay，确认重载后 `nft list ruleset` 里两套链共存、顺序符合预期；
   - 记录开上游前后 `net.ipv4.conf.*.rp_filter`、`src_valid_mark` 的实际值；
   - 从 LAN 侧做一次入向转发（映射）验证，再回滚到测试前状态。
4. **前进 baseline**：改 `observedRef`，并把 `qualification` 重写成"在哪个版本上、验到了什么、
   哪些模式仍未验证"——不要写成"已验证"这类笼统结论。
5. **没有实跑就不要前进 ref**，除非同时满足下面两条（release-owner 决定，理由必须写进
   `qualification`）：
   - 本仓代码**根本不引用这个包**：全仓 grep 零命中（链名、init 调用、UCI 读全都算引用）；
   - 上游改动方向是**放宽**而不是收紧（例如把反向路径校验关掉），且没有改链优先级。

   这两条只覆盖"本仓自己的行为"，不覆盖"上游之间怎么互相干扰"；所以一旦某个模式
   （IPv6、UDP、分片）从来没被声称资格化过，前进 ref 也不等于给它背书，`qualification`
   里要写明该模式的问题从哪个版本开始算。

## 当前状态（2026-11-24）

| 上游 | baseline | 上游最新 | 状态 |
|---|---|---|---|
| OpenClash | `v0.48.002` | `v0.48.002` | 无漂移；共存只在 `v0.47.156` 上实跑过 |
| PassWall1 | `26.11.23-1` | `26.11.23-1` | 无漂移；2026-11-24 按 owner 决定前进，未实跑 |
| PassWall2 | `26.11.23-1` | `26.11.23-1` | 无漂移；同上 |
| HomeProxy | `fadaa676104f` | 同左 | 无漂移 |
| sing-box | `v1.14.4` | `v1.14.4` | 无漂移 |

### 2026-11-24 的这次前进，依据是什么

PassWall1/2 从 `26.11.11-1` 前进到 `26.11.23-1`，走的是第 5 步的例外，依据两条：

- **本仓不引用这两个包。** 全仓 grep `passwall` / `PassWall` 只命中本 baseline 文件本身；
  relay 的链是自己的 `inet upnp_nat_relay` 表，`priority dstnat - 5`，只写 DNAT 规则。
  两个上游包自己的优先级（`nat prerouting dstnat - 1`、`mangle prerouting mangle - 1`）在这次
  改动里没有变，所以顺序仍是：对方 mangle(-151) → 本仓 dstnat(-105) → 对方 dstnat(-101)。
- **改动方向是放宽。** 两包都把自己的 IPv6 TCP/UDP 重定向从 `TPROXY` 换成 `TPROXY6`（IPv6 修正，
  只影响它们自己的 mangle 链），并把已有的 `rp_filter=0` 扩到 `src_valid_mark=0`；后者是关掉基于
  mark 的源校验，方向是更松，不会把本仓已转发的入向流量掐掉。本仓既不读也不写这两个 sysctl。

**没有因此获得的新资格**：IPv6 和 UDP 仍然没有被声称过。IPv6 流量现在会真的落进对方的 TPROXY，
如果哪天要做 IPv6 入向映射，第一件事就是回到第 3 步实跑，版本号从 `26.11.23-1` 算起。
