# 配置参考

文件：`/etc/config/smartmwan`（UCI 文本）。段类型四种：

| 段类型 | 用途 | 是否具名 |
|---|---|---|
| `smartmwan` | 全局设置，约定段名 `global` | 否（读 `global`） |
| `wan` | 一条 WAN 线路 | **是**（段名即线路主键） |
| `game` | 一条游戏/分流规则 | **是**（用于定位与冲突提示） |
| `score` | 游戏评分权重，约定段名 `default` | 否 |

规则：

* 未写的键取本文档「默认值」列的值（默认值唯一来源是 `src/config/schema.rs`，UI 与
  `smartmwand --dump-defaults` 同源）；
* 布尔写 `1`/`0`；枚举一律小写；
* `list` 型键可写多次，或 `list 'a' 'b'` 形式；
* **未识别的用户手写键在保存回写时原样保留**，不会被静默删除；
* 线路段/游戏段的段名字符集受限（会成为 nft 集合名与注释标识的一部分），非法段名是**校验错误**，
  不是警告。

当前 schema 版本：`CONFIG_SCHEMA_VERSION = 4`。低于 4 的配置在首次读取时就地迁移
（`primary_interface`→`primary`、`failback` 布尔→枚举）；高于 4 直接报错并提示升级守护进程，
**绝不按猜测降级解释**。

## 1. `config smartmwan 'global'`

### 1.1 模式与算法

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `config_version` | int | `4` | 由守护进程写入，不要手改 |
| `enabled` | bool | `0` | **默认关闭**。安装即改路由是不可接受的 |
| `mode` | enum | `balance` | `balance` 负载均衡 / `failover` 主备 |
| `algorithm` | enum | `src_ip_dst_ip` | 见 §1.2 |
| `game_policy` | enum | `follow` | 主备模式下游戏流量：`follow` 严格跟随主备 / `exception` 允许跨线路择优 |
| `failback` | enum | `auto` | `auto` 自动回切 / `manual` 仅手动 |
| `primary` | string | 空 | 主线路段名，全配置最多一条显式 primary |
| `backup_order` | list | 空 | 备用顺序（按优先级排列的段名） |
| `failback_delay_ms` | ms | `60000` | 主线路恢复后至少等待该时间才回切 |
| `failback_success_threshold` | int | `5` | 回切所需连续成功次数 |
| `min_switch_interval_ms` | ms | `15000` | 任意两次出口变更的最小间隔（防抖兜底闸门） |
| `conn_sticky` | bool | `1` | 已建立连接保持原出口（ct mark → pkt mark 继承） |
| `hash_seed` | int | `1397577521`（`0x534d5731`，即 "SMW1"） | 多设备部署时建议改，避免分桶模式雷同 |
| `buckets` | int | `64` | 允许 `2..=64`；桶数是分流粒度上限，建议 16/32/64 |

主备顺序的确定规则（不会猜）：**显式 `primary` → `backup_order` → 其余线路按
(`priority`, 段名)**。`primary` 指向不存在的段是校验错误；该值不会被替换成「看起来像主线路」的段。

### 1.2 `algorithm` 取值与真实能力

| 值 | nft 哈希输入 | 能力边界（UI 必须原样展示） |
|---|---|---|
| `src_ip` | `ip saddr` | 同一内网 IP 始终同出口；单客户端大流量不会被均分 |
| `src_ip_src_port` | `ip saddr . sport` | 同连接端口稳定，长连接不会自动迁移；NAT 后源端口会变，跨 NAT 不可复现 |
| `src_ip_dst_ip` | `ip saddr . ip daddr` | 同客户端访问同一目标始终同出口；目标数少时均度差 |
| `src_ip_dst_ip_dst_port` | `ip saddr . ip daddr . dport` | **不含协议**，同 IP 同端口的 TCP/UDP 走同一出口 |
| `full_five_tuple` | `saddr . daddr . sport . dport . l4proto` | 均度最好，但同客户端会话可能分散，对会话保持敏感的应用不友好 |
| `least_new_connections` | `numgen random` + 守护进程重排 | 基于 conntrack 快照与计数器差值，存在采样误差；高连接速率下估算偏晚 |
| `least_traffic` | `numgen random` + 守护进程重排 | 依据接口字节计数平滑，不感知单条连接；单连接峰值不会立即触发迁移 |
| `weighted_hash` | `ip saddr . ip daddr` + 按权重分桶 | 权重是桶比例不是带宽占比；单连接仍受限于一条线路，不叠加带宽 |
| `weighted_ecmp` | 不适用（内核多路径） | 需内核多路径与 ip-full；能力探测失败时**拒绝启用**，不会伪造生效 |

### 1.3 健康探测（全局默认，可被线路覆盖）

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `probe_interval` | ms | `1000` | 探测周期；必须 > `probe_timeout` |
| `probe_timeout` | ms | `800` | 单次探测超时 |
| `failure_threshold` | int | `3` | 连续失败 N 次判 FAILED |
| `recovery_threshold` | int | `5` | 连续成功 N 次进入 RECOVERING；小于故障阈值会告警 |
| `recover_warmup_ms` | ms | `5000` | RECOVERING 预热期，期间不参与分流 |
| `degraded_rtt_ms` | ms | `150` | RTT 超阈判 DEGRADED |
| `degraded_loss_pmm` | ‰ | `20` | 丢包率（千分比）超阈判 DEGRADED |
| `degraded_jitter_ms` | ms | `40` | 抖动超阈判 DEGRADED |
| `max_concurrent_probes` | int | `16` | 全局并发上限，防止探测压垮设备；`0` 是错误 |

> **这些默认值不是普适最优。** 5G/4G 模组的蜂窝链路 RTT 基线本身可能在 30–150ms 之间波动，
> 运营商侧对 ICMP 限速或丢弃也很常见。默认参数偏保守，只保证「不会误判到立刻切换」，
> 不保证对具体模组最灵敏。调参建议先只看 `probe_interval` / `probe_timeout` / `failure_threshold`
> 三个值，并配合 `smartmwand --capabilities`、`getLines` 的历史轨迹观察实际抖动分布后再收紧。

### 1.4 调度与流量

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `sample_window_ms` | ms | `10000` | 动态算法统计窗口，必须 ≥ `rebalance_interval_ms` |
| `rebalance_interval_ms` | ms | `2000` | 最小重排间隔；`<200` 判为错误（会退化成高频规则重建） |
| `smoothing_permille` | ‰ | `700` | 负载平滑系数（EWMA），必须 `1..999` |
| `max_connections_per_wan` | int | `0` | 单线并发上限，`0`=不限；超限会触发桶迁移 |
| `protected_src` | list | `169.254.0.0/16`, `fe80::/10` | **永不参与分流**的内网源段（管理口/VPN 回段），防失联；清空会告警 |
| `bypass_dst` | list | RFC 保留段 + 组播 + `::1/128` + `fc00::/7` 等 | 不分流的目的段；写 `0.0.0.0/0` 是错误（等于全局绕过） |
| `lan_zone` | list | `lan` | 只有来自这些 zone 的流量参与分流 |
| `enable_ipv6` | bool | `1` | 关闭时 IPv6 一律走 main 表（不接管） |
| `dns_ttl_floor_s` | s | `300` | 域名规则解析出的集合元素寿命，校验 `30..=86400`。**这是折中不是最优**：实现用 `getaddrinfo`，它不返回真实 TTL，只能取一个下界。调小→解析次数与瞬时「集合里还没有」的窗口都变大；调大→CDN 换节点后旧 IP 仍在集合里命中。见 §3 的域名限制 |

### 1.5 运行与日志

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `log_level` | enum | `info` | 取值 `error` / `warning` / `info` / `debug` / `trace` |
| `log_file` | path | `/tmp/log/smartmwan.log` | 留空=只写 stderr |
| `log_max_bytes` | int | `524288` | <16384 告警：一次故障切换的日志会被截没 |
| `log_keep_backups` | int | `3` | 轮转保留的旧文件数 |
| `rpc_socket` | path | `/var/run/smartmwan/rpc.sock` | 必须绝对路径且不含 `..` |
| `state_dir` | path | `/tmp/run/smartmwan` | last-good 与运行态；tmpfs，断电即清 |
| `require_confirm` | bool | `1` | 「可能失联」的变更必须前端二次确认 |

## 2. `config wan '<段名>'`

段名建议与 netifd 接口名一致，但**不强制**（`device` 可覆盖）。

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `enabled` | bool | `1` | 关闭的线路不占槽位 |
| `role` | enum | `auto` | `auto` / `primary` / `backup` / `monitor`（只观察，永不参与分流） |
| `device` | string | 空 | 覆盖自动发现的网络设备名；留空=跟随 netifd。≤15 字符（IFNAMSIZ） |
| `weight` | int | `1` | 加权算法用；`0` 是错误 |
| `priority` | int | `100` | 越小越优先；同时决定槽位与排序 |
| `down_kbps` / `up_kbps` | int | `0` | 带宽上限（0=不限），`least_traffic` 的归一化依据；上限 `100000000` |
| `probe_target` | list | 空 | 探测目标（IP 字面量或域名，**不能是网段**）。建议 2 个以上不同运营商 |
| `probe_proto` | enum | `icmp` | `icmp` / `tcp` / `udp` / `dns` |
| `probe_port` | int | `0` | `tcp` 默认 443、`udp`/`dns` 默认 53；`icmp` 下被忽略（会告警） |
| `probe_ipv6` | bool | `1` | 对该线路做 IPv6 探测 |
| `gateway` | ip | 空 | 覆盖自动发现的网关（模组环境常见需要） |
| `src_ip` | ip | 空 | 覆盖源地址（用于 `ip rule from` 与 SNAT 一致性） |
| `maintenance` | bool | `0` | 维护模式：保留配置但不参与分流 |
| `label` | string | 空 | UI 显示名，不参与匹配 |
| 健康覆盖 | — | — | §1.3 的全部键可写在线路段，未写的继承全局 |

## 3. `config game '<段名>'`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `enabled` | bool | `1` | — |
| `priority` | int | `50` | 越小越先匹配；同值按段名字典序（保证确定性）。**同优先级且匹配范围重叠 → 校验错误** |
| `preset` | string | 空 | 预置标识，指向 `/usr/share/smartmwan/presets/*.json` 里的 `id`（格式见 §3.1）；空表示纯自定义规则。标识不存在 → 校验错误 |
| `target` | list | 空 | 目的 IP/CIDR（v4/v6 混写，按族分拣）；`0.0.0.0/0`、`::/0` 被拒绝。写法由 `rules::matchers` 归一：`10.0.0.5/24` → `10.0.0.0/24`，裸地址补 `/32`\|`/128` |
| `port` | list | 空 | `443` 或 `8000-8010`；空=不限端口；逆序范围、`0` 起点、`0-1024`、逗号与取反写法一律拒绝（**不会**替你静默改成 `1-1024`） |
| `proto` | enum | `both` | `tcp` / `udp` / `both` |
| `client_ip` | list | 空 | 内网客户端 IP/CIDR；单条规则上限 512 个元素，超了报错不截断 |
| `client_mac` | list | 空 | MAC，`aa:bb:cc:dd:ee:ff`，也接受 `aa-bb-…` 与 `aabb.ccdd.eeff`，统一小写冒号形式 |
| `domain` | list | 空 | **不支持通配符**，须逐条具体域名；每条规则最多 32 个域名、每域名最多 32 个地址。依赖 DNS 解析（限制见下，寿命取 `global.dns_ttl_floor_s`） |
| `selection` | enum | `best` | `best` 择优 / `pin` 固定线路 / `follow` 跟随普通策略 |
| `pin_wan` | string | 空 | `selection=pin` 时必填且必须存在，否则错误 |
| `comment` | string | 空 | 仅 UI 展示 |

约束与如实提示：

* 启用但**没有任何匹配条件**的规则是错误（会匹配全部流量）；
* `game_policy=follow`（默认）时，`selection=best`/`pin` 会被主备顺序覆盖并产生警告 ——
  这是设计行为：主备模式下备份线路不承载普通流量，游戏例外必须显式改 `game_policy=exception`；
* 域名规则的实现限制（必须在 UI 与文档同时出现）：DNS 解析结果 ≠ 真实连接目的（CDN 任播、GeoDNS、
  轮询）、DoH/DoT 流量无法从 53 端口识别、IPv6 需单独解析 AAAA、集合条目按 TTL 过期而连接寿命更长、
  动态集合容量上限（`DYNAMIC_SET_SIZE=1024`，全局元素上限 `MAX_SET_ELEMENTS=2048`）。
  本实现额外受限于：`getaddrinfo` **不返回 TTL**，元素寿命只能取 `dns_ttl_floor_s` 这个下界；
  解析失败（`NotFound`/`Timeout`/`LocalError`）**不清空集合里的旧元素，也不计为线路失败**。
* 设备 nft 不支持 `flags dynamic,timeout` 集合时，该规则的域名条件**不下发**，并给出警告
  （`smartmwan.game[<slug>].domains`）。此时**不会**退化成「无目的条件的兜底规则」——
  那会命中该主机全部新建连接，比条件不生效严重得多。
* 设备 nft 不支持 `ether_addr` 集合时，MAC 条件无法生效；如果这条规则**只**靠 MAC（或只靠
  IPv6 客户端条件而本机 IPv6 已关闭）限定主机，那么**整条规则不下发**（`smartmwan.game[<slug>]`
  的警告）。同理，少一个客户端条件不等于「更严格」，而是「范围放大到全 LAN」。

### 3.1 预置项数据文件（`/usr/share/smartmwan/presets/*.json`）

路径的唯一权威来源是 `src/rules/presets.rs::PRESET_DIR`（同名常量，不要凭记忆改写）。
**本仓库不内置任何游戏服务器 IP/端口**：代码里没有预置数据，单测
`rules::presets::tests::no_preset_is_bundled_in_code` 把这条钉住。用户/下游自行维护数据文件，
且**必须**写 `source` 说明来源，缺失即整条拒绝。

文件形态三种都接受（`parse_text` 依次尝试）：顶层数组、`{"presets": [...]}`、单个对象。

```json
{
  "presets": [
    {
      "id": "pubg-eu",
      "label": "PUBG 欧服（示例，地址请自行核实）",
      "source": "https://example.com/official-server-list（须在 2026-10-26 之前核实）",
      "updated": "2026-10-01",
      "targets": ["203.0.113.0/24", "2001:db8::/48"],
      "ports": ["30000-30010"],
      "proto": "udp",
      "domains": ["pubg.example.net"]
    }
  ]
}
```

加载规则（都是刻意选择的，不是随手实现）：

| 行为 | 说明 |
|---|---|
| 目录不存在 | 视为「无预置项」，不报错（未打包数据文件时属正常） |
| 非 `.json` / 子目录 | 忽略 |
| 单文件 > 512KiB | 报错（`MAX_FILE_BYTES`），不是截断读取 |
| 一个文件解析失败 | **整批失败**，不静默跳过 —— 否则用户会以为预置项还在 |
| 跨文件重复 `id` | 报错，避免两条同 id 不同地址的预置项 |
| `id` 字符集 / 长度 | 只允许字母数字与 `_ . -`（含大写），≤40 字节。**刻意按最严的来**：它会出现在 UI 与审计文本里，也可能被下游拿去做对象名。注意 nft 对象名实际取自**规则段名**的 slug（`rules::compile` 用 `slug_of(&rule.name)`），不是预置项 id |
| `targets` 与 `domains` 全空 | 报错（等于无目的条件，太危险） |
| 元素数量 | 超 `MAX_SET_ELEMENTS` 报错不截断 |

### 3.2 `preset` 与规则自身字段的合并语义

`rules::compile()` 的合并表（写清哪个赢，避免 UI 与用户预期不一致）：

| 字段 | 合并方式 | 理由 |
|---|---|---|
| 目的网段 `target` | **并集**（预置项 + 规则自身） | 预置项给服务器段，用户加自己的段，两者都要生效 |
| 域名 `domain` | **并集** | 同上 |
| 端口 `port` | 规则写了就用规则的，没写才用预置项的 | 把预置项的整段端口范围并进来会**静默扩大匹配面** |
| 协议 `proto` | 规则不是 `both` 就用规则的，否则用预置项的 | 同上 |
| `client_ip` / `client_mac` | 只用规则的 | 预置项描述服务器，不该规定「哪些主机」 |
| `priority` / `enabled` / `selection` / `pin_wan` | 只用规则的 | 预置项是数据，不是策略 |

不产出数据面规则、但会留一条可显示说明的四种情形：规则停用；`selection=follow`
（本来就不该有独立标记）；全局为「主备」且 `game_policy=follow`（待命线路不允许被游戏流量使用）；
`selection=best` 但本轮还没有择优结果 —— 最后一种进 `Compiled::pending` 并在 UI 显示「等待质量判定」，
**绝不「先随便指一条」**，否则界面显示的择优结论就成了编造。

## 4. `config score 'default'`

评分公式：`score = 100 - w_rtt·norm_rtt - w_jitter·norm_jitter - w_loss·norm_loss - w_instab·instability`
（各项先归一化到 0..=1 再加权，最终夹取到 0..=100）。

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `rtt_weight` | int | `50` | RTT 权重 |
| `jitter_weight` | int | `20` | 抖动权重 |
| `loss_weight` | int | `60` | 丢包权重 |
| `instability_penalty` | int | `10` | 近期切换/抖动的线路扣分 |
| `rtt_norm_ms` | ms | `200` | RTT 归一化基准（达到该值视为最差）；`0` 是错误（除零） |
| `jitter_norm_ms` | ms | `60` | 抖动基准 |
| `loss_norm_pmm` | ‰ | `50` | 丢包基准 |
| `min_advantage_permille` | ‰ | `150` | 滞回：候选必须优出 15% 才切换，防止来回择优 |
| `min_stable_ms` | ms | `20000` | 择优后最小稳定时间 |

四项权重全为 0 是错误（择优会退化成「永不切换」）。

## 5. save 与 apply 是两个动作

```text
uci set smartmwan.global.mode=failover     →  只改文件（RPC: save）
smartmwand 计算 diff 并展示                 →  只读（RPC: diff）
用户确认 → 事务下发                          →  才改内核（RPC: apply）
```

`apply` 的语义：校验 → 生成程序 → `nft -c -f`（dry-run）→ `nft -f`（原子提交）→
`nft -a list` 回读校验 → 写 last-good。任一步失败按 `Undo` 逆序回滚并返回 `Error::Rollback`。

last-good 位于 `state_dir`（默认 `/tmp/run/smartmwan`）。`smartmwand --restore-last-good`
可在改坏之后回到上一次成功状态。注意 tmpfs 语义：**断电后 last-good 随之消失**，重启时以
`/etc/config/smartmwan` 为准（这是刻意的：避免把上次运行态当成当前意图）。

## 6. 最小可用示例

```text
config smartmwan 'global'
    option enabled '1'
    option mode 'balance'
    option algorithm 'src_ip_dst_ip'
    option buckets '64'
    list protected_src '192.168.100.0/24'

config wan 'wan1'
    option role 'primary'
    option priority '10'
    list probe_target '119.29.29.29'
    list probe_target '223.5.5.5'
    option probe_proto 'icmp'

config wan 'wan2'
    option role 'backup'
    option priority '20'
    list probe_target '119.29.29.29'

config game 'demo'
    option enabled '1'
    option priority '10'
    list target '203.0.113.0/24'         # RFC 5737 文档段，仅演示语法
    option proto 'both'
    option selection 'best'
```

> 上面的 `target` 用的是 RFC 5737 保留的文档地址段，**只是格式示例，不是任何服务的真实地址**。
> 本项目不内置、也不推荐任何未经核实的服务器 IP/端口；请填写你自己实际观测到的目的地址
> （例如从本插件的「连接与流量」页里取，而不是从网络教程抄）。

## 7. 校验规则清单（`smartmwand --check` 会全部跑）

* 路径类：绝对路径、不含 `..`；
* 名称类：段名字符集、重复段名、IFNAMSIZ 15 字符；
* 数值类：桶数区间、平滑系数 `1..999`、超时 < 周期、恢复阈值 ≥ 故障阈值（否则警告）、
  权重非 0、归一化基准非 0、`dns_ttl_floor_s` 必须 `30..=86400`；
* 语义类：多条 primary、primary 不存在、backup_order 含主线路或重复项、
  启用但无可用线路、`bypass_dst` 含默认路由、规则无条件匹配、`pin_wan` 缺失/不存在、
  同优先级规则范围重叠；
* 一致性类：IPv6 关闭时仍写 v6 目标/探测目标 → 警告；`protected_src` 为空 → 警告（失联风险）；
* 规则层（`rules::compile`，M5）：`preset` 标识在数据目录里不存在 → Error；
  条件元素数量超上限（客户端 512、全局集合 2048、每规则 32 域名、每域名 32 地址）→ **Error 而非截断**；
  mark 为 0、`pin` 指向未启用的槽位（0 或 >24）→ Error；
  写法归一在 `rules::matchers` 完成，坏值**报错不跳过**（跳过会让「拦 10 段」静默变成「拦 9 段」）；
* 预置项数据文件（`rules::presets`）：缺 `source` → 整条拒绝；`targets` 与 `domains` 全空 → 拒绝；
  单个文件解析失败 → **整批失败**（不静默忽略该文件）；跨文件重复 `id` → 拒绝；
  文件 > 512KiB → 拒绝；文件内的 CIDR/端口/域名在加载时就校验，错误信息带文件名与 `id`。

## 8. 部署要求与安装语义（真机实证，ImmortalWrt 25.12+/apk 时代）

### 8.1 健康探测前提：ping socket

设备内核默认 `net.ipv4.ping_group_range = 1 0`（禁用 ping socket）。未解锁时所有线路的
ICMP 探测不可用，健康层会**诚实告警**（线路状态 unknown，不伪造健康）：

```sh
sysctl -w net.ipv4.ping_group_range='0 2147483647'
echo 'net.ipv4.ping_group_range=0 2147483647' >> /etc/sysctl.conf   # 持久化
```

插件**不会自动修改**这个系统级设置。也可以给线路显式配 `probe_proto`（tcp/udp/dns）
绕开 ICMP。

### 8.2 nftables 占位片段的位置与移除

占位片段安装在 `/usr/share/nftables.d/ruleset-post/smartmwan.nft`（fw4 自动片段目录，
被 include 到 ruleset 顶层——**不是** `/etc/nftables.d/`，该目录会被此固件的 fw4 内置
glob include 进 `table inet fw4` 表体内部，独立表片段放那里会导致 fw4 整体拒绝加载）。
删除该文件并重启防火墙即可移除占位表；守护进程的运行期对象由 `--reclaim` 或停用事务回收。

### 8.3 apk 的安装/升级/卸载语义

* **升级/重装**：`/etc/config/smartmwan` 列入 conffiles，用户改动**保留**
  （真机实测：改 `enabled` 后 `apk add --force` 重装，改动仍在）；
* **卸载**（`apk del`）：按 apk 语义**连 conffiles 一起删除**（与 opkg 不同）——
  卸载前如需保留配置请自行备份 `/etc/config/smartmwan`；
* 卸载时 `prerm` 会停服务并跑 `--reclaim` 清掉插件在内核里的全部自有对象。

### 8.4 LuCI 菜单位置

「网络」菜单下：`网络 → 智能多线路`（URL 前缀 `/cgi-bin/luci/admin/network/smartmwan`），
7 个标签页：运行总览 / 线路管理 / 负载均衡 / 主备切换 / 游戏路由 / 连接与流量 / 配置。
浏览器若显示旧菜单标题，是会话缓存的菜单树——退出重新登录即可刷新。
