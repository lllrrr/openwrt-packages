# CHANGELOG

## Unreleased — 1.3.17

网络页的状态区以前必须手动点一次“检测”才有内容，点完又只弹一条“点击状态选项卡查看结果”的提示——结果就在按钮上方，却不会自己刷新，用户得切页签或刷新整页才看得到。

### 打开页面即自动检测

- 首屏先把状态项标成“检测中”，随后自动跑一次 `check-network`：缓存命中时先显示上次结果再原地刷新，没有缓存也不会停在“点击检测查看状态”。
- 自动检测排在表单渲染之后（`Promise` 链 + 120ms）再发请求，避免和页面自身的 ubus 调用抢连接；实测手动点“检测”期间页面渲染不再被拖慢。
- 后台检测不回填字段（`autoFill` 只在用户点“检测”时开启），否则一进页面 UCI 就变成“未保存”。

### 检测完成后状态区原位刷新

- 状态项改为按 key 可重算的 `statusRenderers`：每行只渲染一次外层 `span[id]`，检测返回后按 id 重绘 `innerHTML`，不用刷新页面；DOM 尚未落地时最多补刷 20 次（150ms 间隔）。
- 自动检测与“检测”按钮共用同一条链路，同一时刻只发一次请求。
- 新增“上次检测”一行显示 `updated_at`；检测失败时这一行直接显示原因，其余项回到“点击检测查看状态”。

### 顺手修掉的快照比对缺陷

`hasNetCheckData()` 原来拿缓存里的 `bind_ip` / `downstream_lan_subnet` / `upstream_wan_if` 去比“UCI 值或即时推导值”，但后端 `load_config` 会先把这些字段推导出来再写缓存，于是 UCI 留空（默认拓扑）时缓存永远对不上，状态区一直停在“点击检测查看状态”。改为只校验用户真正填过的值，未显式配置的字段不再作为失效条件。

### 自动检测也要节流，不能一打开就探测

- `check-network` 缓存里补 `updated_at_epoch`，`--network-cache` 读取时用路由器自己的时钟算出 `age`（秒）注入输出：浏览器与设备时区/时钟不一致也算得准；旧版本写的缓存没有 epoch，一律按过期处理（宁可重测，不显示陈旧结果）。
- UI 侧 `age < 15` 且快照对得上当前配置 → 直接复用结果，不再发检测请求。反复打开/刷新页面、多标签页同时打开，都不会一直重复探测下游路由；手动点「检测」不受限制，永远强制重测。
- 并发去抖：`do_check_network` 用独立锁串行化，拿不到锁说明另一次检测正在跑，等它写完缓存直接复用结果（BusyBox flock 无 `-w`，沿用 1 秒重试循环）。
- 新增回归测试：`tests/network-cache-age.sh`（缓存 age 契约）、`tests/network-auto-detect-throttle.sh`（纯 Node 桩件跑真实 `network.js`：5s 缓存 0 次检测 / 600s 与无缓存各 1 次 / 快照失配仍检测 / 手动检测强制重测并原位刷新），已接入 `proxy-compatibility.yml`。

验证：本地 LuCI 静态页（aurora/light，1280）实测——无缓存进入页面先显示“检测中”，检测返回后 10 项状态与“上次检测”时间自动出现；点“检测”只弹一条完成提示，状态区无需切页签即可看到最新结果。

### 检测与配置读取去重

- `load_config` 不再逐项调用 `uci -q get`：一次 `uci show` 读出快照后在进程内取值，选项缺失、空值与默认值判定保持原语义。
- `do_check_network` 的接口/路由/时间戳只取一次并复用，防火墙规则改为两遍式 awk（先收集端口与目标，再在 END 处判定），省掉重复的 `ip`/`nft` 读取与每行 fork。本机实测单次 `check-network` 由 0.39 s 降到 0.17 s，输出字段与旧版逐字节一致。
- JSON 组装改为纯 shell 转义，去掉 `jq`/`sed` 进程与结尾多余换行。

### 1.3.17-r3：恢复 POSIX sh 兼容

- `json_escape` 回退为一次 awk 调用，`load_config` 的 `'\''` 反转义改为对整份 `uci show` 输出做一次 `sed`、列表去引号改用 `tr`。
- 原因：r2 的性能改写引入了 `${var//a/b}`、`${var%$'\n'}`、`$'...'` 等 ash/bash 专属展开，而脚本声明 `#!/bin/sh`；在 dash 环境下 `load_config` 直接 `Bad substitution`，OpenClash/LuCI 契约门禁因此全红。OpenWrt 的 busybox ash 不受影响，本版仅为兼容性与门禁恢复。

## 1.3.16-17

修掉两处让概览页“说谎”的运行时问题。其一，OpenClash 状态只在守护进程启动时扫一次，之后永远读那份快照：设备上快照停在 `2026-11-22 14:03:15`（当时 OpenClash 恰好停止），而实际核心已运行 20 多小时，页面就一直显示 `⚠ 已安装（已停止）`。现在 `do_sync` 每轮与 `--status`（页面加载）都会重新探测 OpenClash 三字段并原位修补 `env_cache.json`，`updated_at` 仍只代表完整环境扫描时间。其二，`openclash_mode=auto` 下“入站映射无法用 lan_ac_traffic 绕过”的结论每个同步周期都 `log_warn` 一次，2 分钟一条、约 720 条/天，把 64KB 的 syslog 环形缓冲冲成了满屏相同告警；改为状态变化时才警告，其余降到 debug，OpenClash 重启会重新触发一次。

### 日志梳理：持久状况只报一次

上一处的修法只覆盖了 OpenClash 一条，同类的“每轮重复”还有五处，这次一并收敛。新增 `log_once` / `log_recovered` / `log_prune_cycle_keys`（状态放 `/tmp/upnp_nat_relay/log_state`）：同一状况只在签名变化时出声，恢复时补一条“已恢复”，开机后首次出现必报。

- `upnpc read failed`：上游重启、WAN 抖动时每轮一条 `daemon.err`（720 条/天）。现在一个失败串只报首条，成功后补 `upnpc read recovered after N failed cycle(s)`；`status.json` 的 `failure_count` / `last_error` 照旧每轮更新，UI 不受影响。
- `nft not found` / `upnpc not found`：依赖丢失时每轮一条 err，改为一次性，恢复后提示可用。
- `required config missing` 与随后的“Stale rules cleared”：一次性 err + 一次性 warn，配置补回后报“sync resumed”。
- `nft conflict` / `UCI conflict`：按 `proto_port` 建键，冲突持续时不再逐轮刷，映射不再冲突时键被回收，冲突重现会再报一次。
- `Rejected:`（`log_rejected=1`，默认开）：同样按 `proto_port` 去重，保留“哪些映射被拒”的信息量但不再逐轮重复。
- `failure count reached grace count`：每次清空规则后要再攒够 grace 次失败才会再次触发，改为一次性并对成功同步重新布防。
- `Dry run mode enabled`：一次性，退出 dry-run 时补一条恢复提示。
- 守护进程循环改为 `do_sync >/dev/null 2>&1`：procd 会把守护进程的 stdout/stderr 原样转进 syslog，nft/upnpc 失败时的原始 stderr 会叠加在自己那条消息之外、每轮重复；CLI（`--sync` 等）的 stderr 保持可见，方便手工排查。

## 1.3.15-1

修复 po2lmo 缺失时静默跳过导致的空 lmo，并去掉 msgid 首尾空白，让 `_()` 的 trimws 能命中；按钮组/操作列改用主题 spacing 变量留间距，表格首列统一 `min-width:9rem`，页脚改回 `div` 并移除自身 `border-top`，避免 bootstrap 裸 `footer` 选择器再次画出横线。

## 1.3.14-1

恢复四仓统一的版本条 `.ys-tool-footer`（仅项目名、仓库链接与版本号按仓取值），表格回归原生 `.tr/.th/.td` + `data-title` 契约，并为页面加载失败补上错误兜底。

## 1.3.13-4

第二批经复核（容器实测 + 设备实测）确认的缺陷修复；D-14 复核不成立已撤回，未改默认值。

### D-04 `stop` / `--clear` 不清 per-mapping 的 OpenClash 规则（中）

- 现象：停止或 `--clear` 只清 nft 表和 fw4 `localnetwork` 元素，`/etc/config/openclash` 里 comment 为 `upnp_nat_relay_openclash` 的 `lan_ac_traffic` section 原样保留。设备实测：服务已 inactive，`nft list ruleset` 仍有 `tcp sport 46317 ... return comment "upnp_nat_relay_openclash"`（`openclash_mangle` / `openclash_mangle_output` 两条链），UCI 里 TCP/UDP 两个 section 也都在；OpenClash 每次重载都会从 UCI 重建这些 RETURN，属于“规则仍生效”，不只是配置脏。
- 修复：`do_clear` 在 `openclash_remove_localnetwork` 之后调用 `openclash_remove_per_mapping_rules`，只删除带本插件 comment 的 section（用户自建规则不受影响），有删除时 commit 并记录条数。
- 实测（容器）：`--sync` 生成插件 section；`--clear` 后插件 section 与 nft 规则均为空，用户自建 `existing` section 保留。
- 回退：删除 `do_clear` 中新增的 `openclash_remove_per_mapping_rules` 两行。

### D-08 `procd_set_param log` 非法参数（低）

- 现象：`_procd_set_param` 没有 `log` 分支，参数被静默丢弃（容器实测实例 JSON 只含 `command`，对照 `facility daemon` 会写入 `facility`）。不报错、也不建独立日志；日志实际由 `logger -t upnp-nat-relay` 与 init 的 `stdout`/`stderr` 进入 syslog。
- 设备侧真正限制保留时长的是 `system.log_size=64`（KB）：实测 `system.log` 当前 32KB、覆盖约 16 小时，`system.log.old` 为 65,700 字节（按 64KB 轮转）；该值属系统配置，不在本包修改范围。
- 修复：删除 init 中无效的 `procd_set_param log "upnp_nat_relay"` 一行。
- 回退：恢复该行（不影响功能）。

### D-12 UI/配置中后端不消费的字段（中）

- 复核校正：真正的死字段是 3 个 UI 项（`auto_config_network`、`auto_config_firewall_zone`、`backend`）加 3 个配置项（`upnpc.command`、`custom.command`、`custom.output_format`）；`show_advanced_config` 是纯 UI depends，撤回；`clear_on_stop`、`dry_run`、`openclash_auto_restart` 均有消费点，撤回。
- 取舍：`auto_config_*` 若改为“让 setup 流程尊重开关”，默认关闭时 “Configure Interface / Fix Zone” 按钮会直接失效，属行为回归；`backend=custom` 要实现需新增自定义命令执行与输出解析。两者均按“成本高就删 UI”处理。
- 修复：settings.js 删除 `backend`、`auto_config_network`、`auto_config_firewall_zone` 三个控件及 backend 变更重启逻辑；守护进程固定 `backend=upnpc`，删除 `cfg_backend_command` 死读取；默认配置删除 `main.backend`、两项 `auto_config_*`、`upnpc.command/enabled` 与整个 `backend 'custom'` section；init 校验同步收敛。
- 兼容：已有安装中残留的上述 UCI 键会被忽略，不影响启动；`upnpc.timeout` 保持原样并被消费。
- 回退：分别恢复 settings.js 控件、脚本 `cfg_backend` 读取、默认配置与 init 校验。

### D-13 关键配置缺失时旧规则长期残留（高）

- 现象：`do_sync` 在 `bind_ip` / `downstream_wan_ip` / `upstream_wan_if` 为空时直接 `return 1`，既不清 nft 也不删 OpenClash section，且 `failure_count` 不累加，`failure_grace_count` 永远不会触发清理；daemon 每 interval 重试、无退避。容器实测：有效同步后置空 `downstream_wan_ip`，连续 3 次 `--sync` 加 5 秒 `--daemon`，两条 DNAT 与 OpenClash section 全部原样保留。
- 修复：missing-config 分支在非 `dry_run` 时删除 nft 表、清理 applied 缓存与 OpenClash per-mapping section，并写入 `failed` 状态（`last_error=missing_required_config: ...`）。
- 实测（容器）：同样的破坏配置后，第一次 `--sync` 即清空 nft 规则与 OpenClash section。
- 回退：删除该分支新增的清理与状态写入代码块。

### 版本口径

D-04 / D-12 修正对外可见行为（停止后不再残留绕过规则的配置；UI 去掉无效控件），D-13 增加失败时清理，D-08 仅删除无效行；按补丁版本发布：`1.3.13-4`。

## 1.3.13-3

修复三条经复核（容器 + 设备实测）确认的缺陷，改动彼此独立、可单独回退。

### D-01 postinst 在升级时覆盖 `/etc/config/upnp_nat_relay`（高）

- 现象：只要 `/etc/config/upnp_bridge_relay` 存在，任何安装/升级都会用 `cp -p` 覆盖 nat 配置；`conffiles` 只能让 apk 把新默认文件写成 `.apk-new`，挡不住脚本里的显式拷贝。设备上因此把 `enabled=1` 覆盖成 `enabled=0`，守护进程下一轮同步自停。
- 修复：迁移仅在新装时执行（`PKG_UPGRADE=1` 或 postinst 参数 `upgrade` 时跳过），且仅当 nat 配置仍与包内默认值一致（新增 `/usr/share/upnp_nat_relay/config.default` 供 `cmp` 比对）时才从 bridge 配置迁移一次。
- 实测：`1.3.13-r2 → 1.3.13-r3` 升级后配置 md5 不变；新装且存在 bridge 配置时仍能正确迁移。
- 回退：删除 postinst 中的 `PKG_UPGRADE`/`cmp` 守卫即可（单条改动）。

### D-05 `--clear` 与 `--sync` 竞态，clear 被静默撤销（高）

- 现象：`do_sync` 持有 `/tmp/upnp_nat_relay.lock` 的 flock，`do_clear` 不取锁；同步进行中执行 clear，等同步跑完会把表重新建回来。`stop_service` 的 `--clear` 同样受影响。
- 修复：`do_clear` 使用同一把锁，BusyBox flock 无 `-w`，改为 1 秒重试、最多 30 秒；超时返回 `{"success":false,"error":"another_sync_running"}`。
- 实测：同步进行中执行 clear 会等待锁释放后再删表，最终表与规则均为空；无并发时行为不变。
- 回退：删除 `do_clear` 开头的加锁循环。

### D-06 端口冲突检查逐行 fork（高）

- 现象：`check_port_conflict_single` 对 ruleset 每行执行 `$(echo "$line" | tr ...)`，每个映射重扫整表。
- 修复：改为单次 `awk` 完成“跳过自身表 / 跳过本插件注释 / 匹配 dnat + 协议 + dport（含区间）”的索引。
- 实测（2 个映射、3180 行 ruleset）：一次同步 fork 从约 20,200 降到约 400，耗时从约 28s 降到 1s 内（容器，x86_64 模拟）；设备原生单次扫描 fork 从 9,373 降到 5。
- 回退：恢复旧的 for 循环实现。

### 版本口径

三条均为不改变对外行为语义的缺陷修复（D-01 只影响安装脚本，D-05 只影响并发时序，D-06 只影响性能），按补丁版本发布：`1.3.13-3`。
