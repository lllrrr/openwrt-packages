# luci-app-frpc 多实例改造设计文档

- 日期：2026-05-19
- 作者：geek（与 Claude 协同）
- 状态：草案 v1（待评审）
- 适用范围：`luci-app-frpc`（`luci-app-frps` 不在本次范围内）

---

## 0. 背景与目标

### 0.1 用户诉求

当前 LuCI 中 frpc 只能绑定**一个** frps 服务器、跑**一个** frpc 进程。希望改造为：

- 同时运行**多个 frpc 实例**，每个实例对应一个 frps 服务器；
- 每个实例独立的连接配置、规则、日志、状态；
- LuCI 中能一目了然看到每个实例的运行状态，并能单独启停 / 重启 / 看日志。

### 0.2 当前架构关键事实（已通过源码核实）

| 维度 | 现状 | 证据 |
|---|---|---|
| init.d 多实例迭代 | 已具备：`config_foreach start_instance "frpc"` | [root/etc/init.d/frpc:390-393](../../luci-app-frpc/root/etc/init.d/frpc#L390-L393) |
| 每实例独立 toml | 已具备：`frpc.$section.toml` | [root/etc/init.d/frpc:357](../../luci-app-frpc/root/etc/init.d/frpc#L357) |
| 每实例独立 procd instance | 已具备：`frpc.$section` | [root/etc/init.d/frpc:368](../../luci-app-frpc/root/etc/init.d/frpc#L368) |
| UCI 默认配置 | 仅一个 `config frpc 'main'` | [root/etc/config/frpc:1](../../luci-app-frpc/root/etc/config/frpc#L1) |
| LuCI common UI | `NamedSection, "main"` 锁单实例 | [luasrc/model/cbi/frpc/common.lua:60](../../luci-app-frpc/luasrc/model/cbi/frpc/common.lua#L60) |
| 状态接口 | `pidof frpc` 全局布尔 | [luasrc/controller/frpc.lua:85-100](../../luci-app-frpc/luasrc/controller/frpc.lua#L85-L100) |
| 日志查看 | 全局软链 `/tmp/frpc_log_link.txt` | [root/etc/init.d/frpc:295-328](../../luci-app-frpc/root/etc/init.d/frpc#L295-L328) |
| rule 归属 | 全局 list，无 `server_id` 字段 | [root/etc/init.d/frpc:286](../../luci-app-frpc/root/etc/init.d/frpc#L286) |
| 隐藏 bug | `serverAddr/serverPort/auth.*` 从 frpc section 读，而 `server-detail` 把它们写到 server section ⇒ 大量字段实际未生效 | [root/etc/init.d/frpc:268](../../luci-app-frpc/root/etc/init.d/frpc#L268) |

结论：**底层 procd / toml 框架已经多实例就绪，问题集中在配置模型、控制器、UI 三层**。本次改造同时顺手修复 server section 字段不生效的隐藏 bug。

### 0.3 设计目标（成功标准）

1. 同一台路由器上能同时连接 N 个 frps（N≥2 验证为通），每个实例独立 frpc 进程；
2. LuCI 服务器列表能直观看到每个实例的：进程状态、admin 可达性、proxy 在线数；
3. 规则可按所属服务器筛选、批量改归属；
4. 旧版本配置无需手动迁移，升级即用；
5. 不引入额外二进制依赖；
6. 无需修改 frpc 主程序本身。

### 0.4 非目标（明确不做，YAGNI）

- 不做实时流量曲线图；
- 不做 rule 多服务器共享（一条 rule 只能归属一个 server）；
- 不做 admin port 的外网暴露 / NAT；
- 不做 luci-app-frps 端的同步多实例改造；
- 不做配置导入/导出格式重新设计。

---

## 1. 数据模型（UCI Schema）

### 1.1 总体原则

> **一个 server section = 一个 frpc 实例**。

`main` section 退化为"全局兜底层"，所有 frps 连接相关字段（serverAddr / auth / transport / webServer / log）下沉到 server section。

### 1.2 Schema 定义

```text
config frpc 'main'              # 全局
    option enabled              # 总开关；关闭时所有实例不启动
    option default_client_file  # 兜底主程序路径
    option default_run_user     # 兜底运行用户
    option download_mirror      # 主程序下载镜像源
    option migrated_v2          # 迁移哨兵，已迁移 = "1"

config server '<name>'          # 一个 server = 一个实例
    # —— 实例控制 ——
    option enabled              # 单实例开关
    option alias                # 显示名
    option client_file          # 该实例使用的主程序；留空 → default_client_file
    option run_user             # 该实例运行用户；留空 → default_run_user
    option admin_port           # webServer.port；留空 → 自动分配
    option admin_user
    option admin_password

    # —— frps 连接（原本错放在 main 的字段全部迁到这里）——
    option serverAddr
    option serverPort
    option auth__method
    option auth__token
    option transport__protocol
    option transport__tcpMux
    option transport__heartbeatInterval
    option transport__tls__enable
    option transport__tls__serverName
    # … 其他 transport.* / dnsServer / natHoleStunServer / user / loginFailExit

    # —— 日志 ——
    option enable_logging
    option log__to
    option log__level
    option log__maxDays
    option log__disablePrintColor
    option std_redirect

config rule '<name>'
    option enabled
    option server_id            # 【新增】归属哪个 server section（必填）
    option name
    option type
    option localIP
    option localPort
    option remotePort
    # … 其他 type 相关字段保持原样
```

### 1.3 字段去留对照表

下列字段从 `frpc` 移到 `server`：`user`、`serverAddr`、`serverPort`、`natHoleStunServer`、`dnsServer`、`loginFailExit`、`auth.*`、`transport.*`、`webServer.*`、`log.*`、`enable_logging`、`std_redirect`。

下列字段保留在 `frpc 'main'`：`enabled`（总开关）、`download_mirror`、`default_client_file`、`default_run_user`、`migrated_v2`。

下列字段在 `rule` 新增：`server_id`（必填，下拉选）。

---

## 2. 启动脚本（init.d）改造

> 文件：`luci-app-frpc/root/etc/init.d/frpc`

### 2.1 遍历对象切换

```sh
start_service() {
    config_load "$NAME"

    # 全局总开关
    local global_enabled
    config_get global_enabled main enabled
    [ "$global_enabled" = "1" ] || { _info "Global disabled."; return 0; }

    mkdir -p /var/run/frpc

    config_foreach start_instance "server"   # 改为遍历 server
}
```

### 2.2 start_instance 重写要点

1. 读 `server.enabled`，关则跳过；
2. 解析 client_file：`server.client_file` → `main.default_client_file`，二者皆空报错；
3. 解析 run_user：同理回落；
4. 调 `assign_admin_port "$section"`，结果写 `/var/run/frpc/<section>.admin_port`；
5. 调 `create_config_file "$config_file" "$section"` 生成 `/var/etc/frpc/frpc.<section>.toml`（或当前 `CONFIG_FOLDER`）；
6. `logfile_prepare "$section"`：实例独立日志路径与软链；
7. `procd_open_instance "frpc.<section>"` → 启动；
8. 把 admin_port、log 真实路径、toml 路径写入 `/var/run/frpc/<section>.state`（key=value 行），供控制器读取。

### 2.3 create_config_file 重写

- 第二个参数 `section` 是 server 的 UCI 名；
- `[common]` 段全部 `append_options "$tmp_file" "$section" "server" ...`：从 server section 读，而不是从 frpc section 读 —— 修复隐藏 bug；
- rule 段调用：`config_foreach add_frpc_rule "rule" "$tmp_file" "$section"`；
- `add_frpc_rule` 内部首行：`local rule_section="$1"; local tmp="$2"; local owner="$3"; local sid; config_get sid "$rule_section" server_id; [ "$sid" = "$owner" ] || return 0`。

### 2.4 logfile_prepare 改实例级

- 日志真实文件：仍由用户在 `server.log__to` 配置；未配置时默认 `/var/log/frpc/<section>.log`；
- 软链：`/tmp/frpc_log_<section>.txt -> <real_log_path>`；
- 旧的全局软链 `/tmp/frpc_log_link.txt` 在 service_started 时指向"列表中第一个 enabled 的 server"，仅用于老 UI 缓存兼容，不再是主入口；
- `std_redirect` 路径：`/tmp/frpc_std_redirect_<section>.log`。

### 2.5 admin port 自动分配（`assign_admin_port`）

```text
输入：section 名
输出：端口号（写入 /var/run/frpc/<section>.admin_port 并 echo 到 stdout）

策略：
1. 若 server.admin_port 显式有值且 > 0 → 直接返回。
2. 读取 /var/run/frpc/*.admin_port 收集已分配集合 used。
3. 用 ss -tln 收集本机已监听 TCP 端口集合 listening。
4. 从 7400 起递增，跳过 used ∪ listening，取第一个可用端口（上限 7500）。
5. 找不到 → 返回空字符串，调用方降级（不开 webServer）。
```

注意：admin webServer 默认只监听 `127.0.0.1`，不向外网暴露。

### 2.6 service_stopped / instance 退出清理

- procd 提供 `service_stopped` 钩子，遍历所有 `/var/run/frpc/*.state`，清理实例残留状态文件。
- 不主动 kill 进程，交由 procd。

### 2.7 实例启停与重启的统一原则

**核心约定：UCI 是唯一事实源，procd 状态永远跟 UCI 走。**

- **启动 / 停止**：仅通过修改 `server.<name>.enabled` 实现，禁止直接 procd 启停某个 instance。
  - start 操作 = `uci set frpc.<name>.enabled=1` + `uci commit` + `/etc/init.d/frpc reload`；
  - stop 操作 = `uci set frpc.<name>.enabled=0` + `uci commit` + `/etc/init.d/frpc reload`。
  - reload 是全局的，会触发 procd 比对 `procd_set_param file "$config_file"` 与新生成的 toml；未变化的实例不会被重启，受影响实例由 procd 自行 stop/start。
- **重启**：`/etc/init.d/frpc restart frpc.<name>`，依靠 procd 原生 instance 名参数；不修改 UCI，不影响其他实例。
- **不做**：自定义信号、直接 kill -HUP、procd_send_signal 等绕过 procd 状态机的方案。

> 理由：避免出现"UCI 显示启用但 procd 已 stop"或"UCI 显示禁用但进程仍在跑"的状态漂移，简化排错路径。

---

## 3. 控制器（frpc.lua）改造

> 文件：`luci-app-frpc/luasrc/controller/frpc.lua`

### 3.1 入口新增 / 修改

| 路径 | 方法 | 行为 |
|---|---|---|
| `services/frpc/status` | GET | 返回数组，**同时保留** `running` 字段（聚合 OR）做向后兼容 |
| `services/frpc/restart` | POST | `?server=<name>` 可选；不带则全部 |
| `services/frpc/reload`  | POST | 同上 |
| `services/frpc/instance_action` | POST | `?server=<name>&op=start\|stop\|restart`（新增）。`start/stop` 走 UCI 路径（改 `enabled` + commit + reload 全部）；`restart` 走 procd `restart frpc.<name>` |
| `services/frpc/instance_proxies` | GET | `?server=<name>`，代理 admin API（新增） |
| `services/frpc/instance_admin_url` | GET | `?server=<name>`，返回 admin Dashboard URL（新增） |
| `services/frpc/get_log` | GET | `?server=<name>` 可选；不带则取"默认 server"（兼容旧 UI） |
| `services/frpc/clear_log` | POST | 同上 |

### 3.2 status 响应结构

```json
{
  "running": true,
  "global_enabled": true,
  "instances": [
    {
      "name": "frps_hk",
      "alias": "香港节点",
      "enabled": true,
      "running": true,
      "admin_port": 7401,
      "admin_reachable": true,
      "proxies_total": 5,
      "proxies_online": 5,
      "last_error": ""
    }
  ]
}
```

### 3.3 状态判定细节

- **running**：`pgrep -f "frpc\\.<name>\\.toml" >/dev/null`；
- **admin_port**：读 `/var/run/frpc/<name>.admin_port`；
- **admin_reachable**：`curl -s --max-time 1 -o /tmp/.frpc_api_<name> http://127.0.0.1:<port>/api/status` 返回 2xx；若 curl 不存在则降级为 `false`，不阻塞其他字段；
- **proxies_***：解析 `/api/status` JSON，统计每种 proxy 的 `status` 字段（"online" 计数）；
- 整个 status 接口做 **1.5 秒 LuCI sysauth 级别短缓存**（用 ubus / 临时文件），避免轮询 5 秒打爆 admin。

### 3.4 兼容旧前端

- `status` 返回的顶层 `running` 字段保持原义（任一实例运行即 true），让现有 `status_header.htm` 老缓存在升级后不至于报错；
- `get_log` 不带 `?server` 时，行为退化为读全局软链，与旧 UI 一致；
- **「默认 server」定义**：按 UCI 顺序遍历 server section，取第一个 `enabled=1` 的；全部禁用则取第一个 server section。此定义在 `get_log`、`logfile_prepare` 全局软链、迁移脚本中保持一致。

---

## 4. LuCI UI 改造

### 4.1 common.lua（瘦身）

> `luasrc/model/cbi/frpc/common.lua`

仅保留：
- `general` tab：`enabled` 总开关、`default_client_file`、`default_run_user`、`download_mirror`；
- `program` tab：保留现有程序管理（`program_manager` 模板，多版本管理）。

去除：`advanced`、`manage` tab；这两 tab 的字段全部下沉到 server-detail。

### 4.2 servers.lua（升级为主控台）

> `luasrc/model/cbi/frpc/servers.lua`

列表列：
1. 状态指示灯（绿/黄/红，对应 running+reachable / running+unreachable / stopped）；
2. 名称 / 别名；
3. serverAddr:serverPort；
4. proxies online/total；
5. admin port；
6. 操作下拉（折叠菜单）：启动 / 停止 / 重启 / 看日志 / 打开 admin Dashboard / 编辑。

实现策略：
- 列表行用一个自定义 Template（`view/frpc/server_row.htm`）渲染状态指示灯与操作下拉；
- **操作下拉**：使用单一按钮（如 `▾ 操作`）展开折叠菜单，避免一行 6 个按钮挤占横向空间，移动端友好；
  - 菜单项根据当前状态动态显隐：running 时仅显示「停止 / 重启 / 看日志 / Dashboard / 编辑」；stopped 时显示「启动 / 看日志 / 编辑」（隐藏 Dashboard / 重启）；
  - Dashboard 项需 `admin_reachable=true` 才可点击，否则灰显并 tooltip 提示原因（如"curl 不可用"或"admin 端口未配置"）；
- 按钮通过 XHR 调 `instance_action` / `instance_admin_url`；
- 每 5 秒一次 XHR.poll 拉 `status` 更新状态灯和 proxy 数；
- 列表右上角全局操作按钮：「全部启动」「全部停止」「全部重启」「新增服务器」。

### 4.3 server-detail.lua（接收下沉字段）

> `luasrc/model/cbi/frpc/server-detail.lua`

新增 tab：
- `general`：enabled、alias、client_file（下拉，含"使用全局默认"）、run_user、serverAddr、serverPort、auth.*；
- `advanced`：transport.*、dnsServer、natHoleStunServer、loginFailExit、user；
- `manage`：admin_port（留空 = 自动）、admin_user、admin_password；
- `log`：enable_logging、log__to、log__level、log__maxDays、log__disablePrintColor、std_redirect。

### 4.4 rules.lua（按 server 分组与筛选）

> `luasrc/model/cbi/frpc/rules.lua`

- 列表顶部加 `server` 筛选下拉（"全部" + 各 server）；
- 新增列「所属服务器」，用 chip 着色（同一 server 同色）；
- 多选 + 「批量改归属」按钮（弹出 server 下拉）；
- 「复制规则」扩展：复制时可选目标 server。

### 4.5 rule-detail.lua

- 顶部新增必填 `server_id`（下拉），默认为当前筛选的 server 或第一个 server。

### 4.6 status_header.htm

- 渲染所有实例的状态条（横向 chip 列表，每个 chip 显示别名 + 状态点）；
- 总开关 OFF 时显示灰色"全局已关闭"。

### 4.7 frpc_log.htm

- 顶部加 server 下拉切换；
- `get_log` URL 拼接 `?server=<name>`；
- 切换时清空 textarea 重新拉。

---

## 5. 迁移脚本（uci-defaults）

> 文件：`luci-app-frpc/root/etc/uci-defaults/40_luci-frpc`

### 5.1 触发条件

```sh
[ "$(uci -q get frpc.main.migrated_v2)" = "1" ] && exit 0
```

### 5.2 迁移步骤

1. **遍历所有 `frpc` section**（防御历史上手动建过多个 frpc section 的场景）：
   - 对每个 frpc section S：取 `S.server` 字段 → 目标 server section T；
   - 把 S 中的 `serverAddr / serverPort / user / natHoleStunServer / dnsServer / loginFailExit / auth__* / transport__* / webServer__* / log__* / enable_logging / std_redirect` 字段，**当 T 中对应字段为空时**复制过去；
   - 把 S 的 `enabled / client_file / run_user` 写入 T（同样仅当 T 为空）；
2. **遍历所有 `rule` section**：未设置 `server_id` 的，写入 `S0.server`（S0 = `main` 或第一个 frpc section）；
3. **建立 main**：
   - `enabled` = 任一原 frpc section 的 enabled 为 1 则 1，否则 0；
   - `default_client_file` = 原 `main.client_file`；
   - `default_run_user` = 原 `main.run_user`；
   - `download_mirror` 保留；
4. **清理**：依据 §1.3「字段去留对照表」，从所有 frpc section 中 `uci delete` 已下沉到 server 的字段；保留 frpc 'main' 这一个 section；非 'main' 的额外 frpc section 不删除，仅写日志告知人工确认；
5. **设置哨兵**：`uci set frpc.main.migrated_v2=1`；
6. **重启服务**：`/etc/init.d/frpc enabled && /etc/init.d/frpc restart`。

### 5.3 幂等性

- 哨兵 `migrated_v2=1` 保证脚本只跑一次；
- 即使哨兵丢失重跑，"目标字段为空才写"的策略也避免覆盖用户已编辑的内容。

---

## 6. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| 迁移脚本误覆盖用户已修改的 server 字段 | 数据丢失 | "目标为空才写"策略 + 哨兵 |
| admin port 端口冲突 / 耗尽 | 部分实例 admin 不可达 | 降级：进程级监控仍可用，UI 显示 "admin 不可用" |
| pidof frpc 全局假设遗留 | 状态显示错乱 | 全文换为 `pgrep -f frpc\\.<name>\\.toml` |
| 旧 status_header.htm JS 缓存 | 升级后 UI 报错 | `status` 接口保留顶层 `running` 字段 |
| log 文件量增长 | 占用 /tmp | 沿用用户在 server.log__to 中的配置；未配置默认 `/var/log/frpc/<name>.log`；不主动轮转 |
| curl 不可用 | admin_reachable 永远 false | 降级到仅进程级监控；UI 显示 "admin 不可用（缺少 curl）" |
| 升级即生效，用户在用 | 短暂断连 | uci-defaults 末尾仅 `restart` 一次，时间窗 <2s |
| 多版本主程序 + 多实例组合 | 主程序文件被并发覆盖（下载时） | 下载操作锁文件已由 program manager 处理；本次不改 |

---

## 7. 测试计划

### 7.1 单元 / 脚本级

- `assign_admin_port` 在已用端口集合下能正确跳过；
- `create_config_file` 仅写入归属本实例的 rule（构造两 server + 各 2 rule 验证）；
- 迁移脚本对"旧单 server 配置"、"已迁移配置"、"用户手动多 frpc section 配置"三种输入幂等。

### 7.2 集成（测试设备 192.168.0.187）

- 起 2 个 server 实例，分别连不同 frps（可用公网 + 本地 frps 各一个）；
- 验证两实例各自独立 admin port、独立日志文件；
- LuCI 服务器列表状态实时刷新正确；
- 单实例启停不影响另一实例；
- rule 改归属后，重启对应两个实例后 toml 内容正确变化；
- 主程序版本切换后两实例都使用新版本。

### 7.3 回归

- 单 server 场景下 UI 行为与旧版一致；
- 老 status_header / log 页面不抛 JS 错；
- 升级流程：装旧版 → 配置 → 装新版 → 配置自动迁移、服务自动起来。

---

## 8. 影响的文件清单

```
luci-app-frpc/
├── root/etc/config/frpc                          [改] 默认配置示例
├── root/etc/init.d/frpc                          [大改] 多实例核心
├── root/etc/uci-defaults/40_luci-frpc            [大改] 迁移脚本
├── root/usr/share/rpcd/acl.d/luci-app-frpc.json  [改] 新增接口的 ACL
├── luasrc/controller/frpc.lua                    [大改] 新增接口
├── luasrc/model/cbi/frpc/
│   ├── common.lua                                [大改] 瘦身
│   ├── servers.lua                               [大改] 控制台化
│   ├── server-detail.lua                         [大改] 接收下沉字段
│   ├── rules.lua                                 [改] 分组/筛选/批量
│   └── rule-detail.lua                           [改] 增加 server_id
└── luasrc/view/frpc/
    ├── status_header.htm                         [改] 多实例状态条
    ├── frpc_log.htm                              [改] 实例选择
    ├── program_manager.htm                       [不变]
    ├── file_viewer.htm                           [不变]
    └── server_row.htm                            [新增] 服务器行模板
```

---

## 9. 已确认的设计决策

以下三点曾被列为未决，已在评审中确认，记录如下避免实施阶段重复讨论：

1. **字段命名风格**：保持现有 UCI 双下划线风格（`auth__method`、`transport__tls__enable`），不借此次改造重命名，降低迁移脚本与既有代码的对照成本。
2. **服务器列表行内操作**：折叠为单一「操作」下拉菜单，详见 §4.2。
3. **实例启停的状态机**：以 UCI 为唯一事实源，禁止绕过 procd 直接 kill 进程；详见 §2.7。

### 实施阶段仍待落地决定（不影响整体架构）

- `server_row.htm` 是否禁用 CBI 默认「编辑 / 删除」按钮？倾向于保留 CBI 默认编辑入口（与全站行为一致），仅在末列追加「操作」下拉。删除按钮保留并复用 CBI 原生行为。
- frpc 0.52 之前的版本 admin API 字段差异不兼容（README 已声明 ≥0.52.0）。

---

## 10. 后续步骤

- 本文档评审通过后，进入 `writing-plans` 编写实施计划（按文件粒度拆分为可独立验证的子任务）；
- 实施按下列顺序，每步独立可验证：
  1. 数据模型 + 迁移脚本（不动 init.d，可在测试机验证 uci show 结果）；
  2. init.d 多实例化（命令行启动验证两个实例同时跑起来）；
  3. 控制器接口（curl 接口验证）；
  4. UI（servers / rules / common / status_header）；
  5. 集成联调与文档更新。
