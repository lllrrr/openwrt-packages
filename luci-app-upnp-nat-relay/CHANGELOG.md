# CHANGELOG

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
