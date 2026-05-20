# luci-app-frpc 多实例改造 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 luci-app-frpc 改造为「一个 server section = 一个 frpc 实例」的多实例架构，支持同时连接多个 frps、独立日志与状态监控。

**Architecture:** 复用底层 procd 已有的多 instance 框架，把数据模型从 `frpc(main) + server + rule(全局)` 改为 `frpc(main 仅全局) + server(实例载体) + rule(server_id 归属)`；控制器从单进程 `pidof` 升级为按实例 procd + frpc admin API 双源监控；UI 把 servers 列表升级为"实例控制台"。

**Tech Stack:** OpenWrt procd / UCI / `/etc/rc.common` shell；LuCI Lua (luci.controller / luci.cbi)；HTML+XHR.poll；frpc admin webServer (HTTP /api/status)。

**前置依赖：** 设计文档 [docs/superpowers/specs/2026-05-19-frpc-multi-instance-design.md](../specs/2026-05-19-frpc-multi-instance-design.md)。所有架构问题以 spec 为准。

**测试设备：** 192.168.0.187（OpenWrt，已部署 frpc，项目 skill `frpc-dev-deploy` 可一键推送 luasrc/htm/init.d）。

---

## 阶段总览

| Phase | 主题 | 任务数 | 独立可验证产物 |
|---|---|---|---|
| 1 | 数据模型 + 迁移 | 3 | `uci show frpc` 输出符合新 schema |
| 2 | init.d 多实例化 | 8 | ssh 上去能看到 2 个 frpc 进程同时跑 |
| 3 | 控制器接口 | 7 | `curl /cgi-bin/luci/.../status` 返回多实例数组 |
| 4 | UI 改造 | 10 | 浏览器中按 spec §4 操作可工作 |
| 5 | 收尾与回归 | 3 | 单 server 场景行为与旧版一致 |

**约定：**
- 每个 task 形成一个独立 commit（前缀 `feat:` / `refactor:` / `fix:` / `docs:`）；
- 每个 task 的最后一步都是「在测试设备上验证」；OpenWrt shell/Lua 无现成单测框架，TDD 退化为「先定义验证命令并预期失败 → 实施 → 验证通过」；
- 文件路径全部使用项目根的相对路径（项目根 = `luci-app-frpc_frps-pro/`）；
- 测试设备命令统一格式：`ssh root@192.168.0.187 '<cmd>'`；
- 推送代码用项目 skill `frpc-dev-deploy`（脚本会增量 rsync 改动文件到测试设备并 restart 服务）。

**与 spec 的实施差异（YAGNI 删减）：**

| spec 中的项 | 实施差异 | 理由 |
|---|---|---|
| `services/frpc/instance_proxies` 独立接口 | 不单独实现，proxy 明细聚合进 `status` 的 `proxies_total/online` 计数 | UI §4.2 仅需计数，明细暂无使用方；如未来"实例详情页"需要再补 |
| `acl.d/luci-app-frpc.json` 新增接口 ACL | 不修改 | 现有 ACL 已全开 uci frpc 读写；新接口走 LuCI 控制器 `entry()` + sysauth，不依赖 rpcd acl |

如未来确需 instance_proxies 接口或 rpcd 级 ACL，再以补丁形式追加，不在本计划范围内。

---

## Phase 1 — 数据模型与迁移

### Task 1.1：更新默认 UCI 配置示例

**Files:**
- Modify: `luci-app-frpc/root/etc/config/frpc`

- [ ] **Step 1：定义验证标准**

预期：升级安装后 `uci show frpc` 至少包含一个 `frpc.main` + 一个 `server` + 至少一条 `rule` 且 `rule.server_id` 指向该 server。

- [ ] **Step 2：写入新的默认配置内容**

把文件完全替换为：

```text
config frpc 'main'
	option enabled '0'
	option default_client_file '/usr/bin/frpc'
	option default_run_user ''
	option download_mirror ''

config server 'frps'
	option enabled '1'
	option alias '默认服务器'
	option serverAddr '0.0.0.0'
	option serverPort '7000'

config rule 'ssh_proxy'
	option server_id 'frps'
	option enabled '1'
	option name 'ssh'
	option type 'tcp'
	option localIP '127.0.0.1'
	option localPort '22'
	option remotePort '6000'
```

- [ ] **Step 3：本地校验语法**

Run: `cat luci-app-frpc/root/etc/config/frpc | head -20`
Expected: 输出与上一步一致，无乱码、无 BOM。

- [ ] **Step 4：Commit**

```bash
git add luci-app-frpc/root/etc/config/frpc
git commit -m "refactor(config): 默认 UCI 配置升级为多实例 schema (main+server+rule.server_id)"
```

---

### Task 1.2：编写迁移脚本

**Files:**
- Modify: `luci-app-frpc/root/etc/uci-defaults/40_luci-frpc`

- [ ] **Step 1：定义验证标准**

构造一份"旧版配置"（main 含 serverAddr/auth__token/transport__* / webServer__* / log__*；一个 server section；多条 rule 无 server_id），跑脚本后：
- 所有这些字段都搬到对应 server section；
- 所有 rule 都有了 `server_id`；
- `main.migrated_v2=1`；
- 再跑一次脚本，没有任何字段变化（幂等）。

- [ ] **Step 2：写完整脚本**

把文件替换为以下内容（保留原 ucitrack 逻辑，追加迁移逻辑）：

```sh
#!/bin/sh

uci -q batch <<-EOF >/dev/null
	delete ucitrack.@frpc[-1]
	add ucitrack frpc
	set ucitrack.@frpc[-1].init=frpc
	commit ucitrack
EOF

# === 多实例迁移 v2 ===
migrate_v2() {
	local migrated
	migrated=$(uci -q get frpc.main.migrated_v2)
	[ "$migrated" = "1" ] && return 0

	# 字段集：从 frpc section 下沉到 server section
	local SERVER_FIELDS="user serverAddr serverPort natHoleStunServer dnsServer loginFailExit \
		auth__method auth__token \
		transport__poolCount transport__protocol \
		transport__tcpMux transport__tcpMuxKeepaliveInterval \
		transport__quic__keepalivePeriod transport__quic__maxIdleTimeout transport__quic__maxIncomingStreams \
		transport__proxyURL \
		transport__tls__enable transport__tls__disableCustomTLSFirstByte \
		transport__tls__certFile transport__tls__keyFile transport__tls__trustedCaFile transport__tls__serverName \
		transport__heartbeatInterval transport__heartbeatTimeout \
		webServer__addr webServer__port webServer__user webServer__password \
		enable_logging std_redirect \
		log__to log__level log__maxDays log__disablePrintColor"

	# 遍历所有 frpc section（防御历史上手动建过多个）
	local frpc_sections
	frpc_sections=$(uci -q show frpc | awk -F. '/^frpc\.[^=]+=frpc$/ {print $2}' | awk -F= '{print $1}')

	local frpc_sec
	for frpc_sec in $frpc_sections; do
		local target_server
		target_server=$(uci -q get "frpc.${frpc_sec}.server")
		[ -z "$target_server" ] && continue
		[ -z "$(uci -q get frpc.${target_server})" ] && continue

		# 下沉 server 字段：仅当目标为空时复制
		local f
		for f in $SERVER_FIELDS; do
			local v dst
			dst=$(uci -q get "frpc.${target_server}.${f}")
			[ -n "$dst" ] && continue
			v=$(uci -q get "frpc.${frpc_sec}.${f}")
			[ -z "$v" ] && continue
			uci set "frpc.${target_server}.${f}=${v}"
		done

		# 复制实例级字段：enabled / client_file / run_user
		local ef
		for ef in enabled client_file run_user; do
			local dst v
			dst=$(uci -q get "frpc.${target_server}.${ef}")
			[ -n "$dst" ] && continue
			v=$(uci -q get "frpc.${frpc_sec}.${ef}")
			[ -z "$v" ] && continue
			uci set "frpc.${target_server}.${ef}=${v}"
		done

		# 清理已下沉字段（仅清字段，不删 section）
		for f in $SERVER_FIELDS; do
			uci -q delete "frpc.${frpc_sec}.${f}" 2>/dev/null
		done
	done

	# 默认 server：第一个 enabled=1 的 frpc.server，否则第一个 server
	local default_server
	default_server=$(uci -q show frpc | awk -F. '/^frpc\.[^=]+=server$/ {print $2}' | awk -F= '{print $1}' | while read s; do
		[ "$(uci -q get frpc.${s}.enabled)" = "1" ] && { echo "$s"; break; }
	done)
	[ -z "$default_server" ] && default_server=$(uci -q show frpc | awk -F. '/^frpc\.[^=]+=server$/ {print $2; exit}' | awk -F= '{print $1}')

	# 给所有未带 server_id 的 rule 写入归属
	if [ -n "$default_server" ]; then
		local rules
		rules=$(uci -q show frpc | awk -F. '/^frpc\.[^=]+=rule$/ {print $2}' | awk -F= '{print $1}')
		local r
		for r in $rules; do
			[ -n "$(uci -q get frpc.${r}.server_id)" ] && continue
			uci set "frpc.${r}.server_id=${default_server}"
		done
	fi

	# 建立 main 段
	local main_enabled
	main_enabled=0
	for frpc_sec in $frpc_sections; do
		[ "$(uci -q get frpc.${frpc_sec}.enabled)" = "1" ] && main_enabled=1
	done
	uci -q get frpc.main >/dev/null 2>&1 || uci set frpc.main=frpc
	uci set frpc.main.enabled="${main_enabled}"

	# default_client_file 取首个 frpc section 的 client_file
	local default_cf
	default_cf=$(uci -q get frpc.main.default_client_file)
	if [ -z "$default_cf" ]; then
		for frpc_sec in $frpc_sections; do
			local cf
			cf=$(uci -q get "frpc.${frpc_sec}.client_file")
			[ -n "$cf" ] && { uci set "frpc.main.default_client_file=${cf}"; break; }
		done
		[ -z "$(uci -q get frpc.main.default_client_file)" ] && uci set "frpc.main.default_client_file=/usr/bin/frpc"
	fi

	# default_run_user
	local default_ru
	default_ru=$(uci -q get frpc.main.default_run_user)
	if [ -z "$default_ru" ]; then
		for frpc_sec in $frpc_sections; do
			local ru
			ru=$(uci -q get "frpc.${frpc_sec}.run_user")
			[ -n "$ru" ] && { uci set "frpc.main.default_run_user=${ru}"; break; }
		done
	fi

	# 哨兵
	uci set frpc.main.migrated_v2=1
	uci commit frpc

	logger -t luci-app-frpc "Migration v2 done: ${frpc_sections}"
}

migrate_v2

rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
exit 0
```

- [ ] **Step 3：构造测试 UCI 输入**

```bash
ssh root@192.168.0.187 'cat > /tmp/frpc.old <<EOF
config frpc "main"
	option enabled "1"
	option server "frps"
	option client_file "/usr/bin/frpc"
	option serverAddr "1.2.3.4"
	option serverPort "7000"
	option auth__token "secret123"
	option transport__tcpMux "true"

config server "frps"
	option alias "测试"

config rule "ssh"
	option enabled "1"
	option name "ssh"
	option type "tcp"
	option localPort "22"
	option remotePort "6000"
EOF
cp /tmp/frpc.old /etc/config/frpc.bak.test
cp /tmp/frpc.old /etc/config/frpc'
```

- [ ] **Step 4：推送脚本到设备并触发**

```bash
scp luci-app-frpc/root/etc/uci-defaults/40_luci-frpc root@192.168.0.187:/etc/uci-defaults/
ssh root@192.168.0.187 'sh /etc/uci-defaults/40_luci-frpc; uci show frpc'
```

Expected:
- `frpc.frps.serverAddr='1.2.3.4'`
- `frpc.frps.auth__token='secret123'`
- `frpc.frps.transport__tcpMux='true'`
- `frpc.frps.enabled='1'`
- `frpc.frps.client_file='/usr/bin/frpc'`
- `frpc.ssh.server_id='frps'`
- `frpc.main.enabled='1'`
- `frpc.main.default_client_file='/usr/bin/frpc'`
- `frpc.main.migrated_v2='1'`

- [ ] **Step 5：验证幂等**

```bash
ssh root@192.168.0.187 'uci show frpc > /tmp/uci.1; sh /etc/uci-defaults/40_luci-frpc; uci show frpc > /tmp/uci.2; diff /tmp/uci.1 /tmp/uci.2'
```

Expected: 无输出（diff 为空）。

- [ ] **Step 6：恢复设备状态**

```bash
ssh root@192.168.0.187 'rm -f /etc/config/frpc.bak.test /tmp/frpc.old /tmp/uci.1 /tmp/uci.2'
```

- [ ] **Step 7：Commit**

```bash
git add luci-app-frpc/root/etc/uci-defaults/40_luci-frpc
git commit -m "feat(migration): uci-defaults 加入 v2 数据模型迁移（main 字段下沉到 server, rule 写入 server_id, 幂等）"
```

---

### Task 1.3：阶段验证

- [ ] **Step 1：清单核对**

- [ ] `etc/config/frpc` 默认配置已符合新 schema
- [ ] `40_luci-frpc` 迁移脚本幂等通过验证
- [ ] 没有触碰任何 init.d / Lua 代码（这阶段必须只动配置和迁移）

- [ ] **Step 2：阶段提示**

Phase 1 完成。`uci show frpc` 现在符合新 schema，但 init.d 还在读老字段路径，所以 **此时 frpc 暂时无法启动**。这是预期状态，Phase 2 会修复。

---

## Phase 2 — init.d 多实例化

> 本阶段所有变更集中在 `luci-app-frpc/root/etc/init.d/frpc`。
> 推送命令统一为：`scp luci-app-frpc/root/etc/init.d/frpc root@192.168.0.187:/etc/init.d/frpc && ssh root@192.168.0.187 'chmod +x /etc/init.d/frpc'`。

### Task 2.1：新增 `assign_admin_port` 函数

**Files:**
- Modify: `luci-app-frpc/root/etc/init.d/frpc`（在 `client_file_validate` 函数之后插入）

- [ ] **Step 1：定义验证**

预期：在 `7400` 起未占用时返回 `7400`；如 `/var/run/frpc/foo.admin_port=7400` 已存在，对另一个实例返回 `7401`；上限 `7500` 全占用时返回空。

- [ ] **Step 2：插入函数**

```sh
# 自动分配 admin port；显式配置优先
# $1 = section name
# stdout: 端口号或空字符串
assign_admin_port() {
	local section="$1"
	local explicit
	explicit=$(uci -q get "frpc.${section}.admin_port")
	if [ -n "$explicit" ] && [ "$explicit" -gt 0 ] 2>/dev/null; then
		echo "$explicit"
		return 0
	fi

	mkdir -p /var/run/frpc
	# 已分配端口集合（其他实例）
	local used=""
	local f
	for f in /var/run/frpc/*.admin_port; do
		[ -f "$f" ] || continue
		# 跳过自己
		[ "$f" = "/var/run/frpc/${section}.admin_port" ] && continue
		used="$used $(cat "$f" 2>/dev/null)"
	done

	# 本机已监听 TCP 端口集合
	local listening
	listening=$(ss -tln 2>/dev/null | awk 'NR>1 {split($4,a,":"); print a[length(a)]}' | sort -u)

	local p=7400
	while [ "$p" -le 7500 ]; do
		case " $used " in *" $p "*) p=$((p+1)); continue;; esac
		echo "$listening" | grep -q "^${p}$" && { p=$((p+1)); continue; }
		echo "$p"
		return 0
	done
	echo ""
	return 1
}
```

- [ ] **Step 3：推送并冒烟**

```bash
scp luci-app-frpc/root/etc/init.d/frpc root@192.168.0.187:/etc/init.d/frpc
ssh root@192.168.0.187 'chmod +x /etc/init.d/frpc; mkdir -p /var/run/frpc; rm -f /var/run/frpc/*.admin_port; \
	. /lib/functions.sh; . /etc/init.d/frpc; \
	echo "first:$(assign_admin_port hk)"; \
	echo "7400" > /var/run/frpc/hk.admin_port; \
	echo "second:$(assign_admin_port jp)"; \
	rm -f /var/run/frpc/hk.admin_port /var/run/frpc/jp.admin_port'
```

Expected: `first:7400` 和 `second:7401`。

- [ ] **Step 4：Commit**

```bash
git add luci-app-frpc/root/etc/init.d/frpc
git commit -m "feat(init.d): 新增 assign_admin_port 自动分配 7400-7500 端口"
```

---

### Task 2.2：扩展 `server_section_validate`

**Files:**
- Modify: `luci-app-frpc/root/etc/init.d/frpc:129-138`

- [ ] **Step 1：把所有下沉字段加入校验**

替换 `server_section_validate` 函数为：

```sh
server_section_validate() {
	uci_validate_section "$NAME" "server" "$1" \
		'enabled:bool:0' \
		'alias:string' \
		'client_file:string' \
		'run_user:string' \
		'admin_port:port' \
		'admin_user:string' \
		'admin_password:string' \
		'serverAddr:string' \
		'serverPort:port' \
		'user:string' \
		'natHoleStunServer:string' \
		'dnsServer:host' \
		'loginFailExit:or("true", "false")' \
		'auth__method:or("token", "oidc")' \
		'auth__token:string' \
		'transport__poolCount:uinteger' \
		'transport__protocol:string' \
		'transport__tcpMux:or("true", "false")' \
		'transport__tcpMuxKeepaliveInterval:uinteger' \
		'transport__quic__keepalivePeriod:integer' \
		'transport__quic__maxIdleTimeout:integer' \
		'transport__quic__maxIncomingStreams:uinteger' \
		'transport__proxyURL:string' \
		'transport__tls__enable:or("true", "false")' \
		'transport__tls__disableCustomTLSFirstByte:or("true", "false")' \
		'transport__tls__certFile:file' \
		'transport__tls__keyFile:file' \
		'transport__tls__trustedCaFile:file' \
		'transport__tls__serverName:string' \
		'transport__heartbeatInterval:integer' \
		'transport__heartbeatTimeout:integer' \
		'com_extra_options:list(string)' \
		'webServer__addr:host' \
		'webServer__port:port' \
		'webServer__user:string' \
		'webServer__password:string' \
		'enable_logging:bool:0' \
		'std_redirect:bool:0' \
		'log__to:string' \
		'log__level:or("trace", "debug", "info", "warn", "error")' \
		'log__maxDays:uinteger' \
		'log__disablePrintColor:or("true", "false")'
}
```

- [ ] **Step 2：rule_section_validate 增加 server_id**

把 `rule_section_validate` 的第一行从 `'enabled:bool:0' \` 改为前面加一行：

```sh
		'server_id:string' \
		'enabled:bool:0' \
```

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/root/etc/init.d/frpc
git commit -m "refactor(init.d): server_section_validate 接管所有下沉字段；rule 增加 server_id 校验"
```

---

### Task 2.3：重写 `add_frpc_rule` 增加 server_id 过滤

**Files:**
- Modify: `luci-app-frpc/root/etc/init.d/frpc:207-259`

- [ ] **Step 1：在函数头增加 owner 参数和归属判断**

把 `add_frpc_rule` 前 10 行从：

```sh
add_frpc_rule() {
	local section="$1"
	local file="$2"

	if ! rule_section_validate "$section" ; then
		_err "Rule section validate failed: \"$section\""
		return 1
	fi

	if [ "x$enabled" != "x1" ] ; then
		return 0
	fi
```

改为：

```sh
add_frpc_rule() {
	local section="$1"
	local file="$2"
	local owner="$3"

	if ! rule_section_validate "$section" ; then
		_err "Rule section validate failed: \"$section\""
		return 1
	fi

	# 仅写入归属本实例的 rule
	if [ -n "$owner" ] && [ "$server_id" != "$owner" ]; then
		return 0
	fi

	if [ "x$enabled" != "x1" ] ; then
		return 0
	fi
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/root/etc/init.d/frpc
git commit -m "feat(init.d): add_frpc_rule 增加 owner 过滤参数，按 rule.server_id 归属写入 toml"
```

---

### Task 2.4：重写 `create_config_file` 接收 owner 并从 server 段读取

**Files:**
- Modify: `luci-app-frpc/root/etc/init.d/frpc:261-294`

- [ ] **Step 1：函数签名和调用点改造**

把整个 `create_config_file` 函数替换为：

```sh
create_config_file() {
	local config_file="$1"
	local section="$2"
	local tmp_file
	tmp_file="$(mktemp /tmp/frpc-XXXXXX)"

	echo "# 文件生成时间：$(date +%Y-%m-%d_%H:%M:%S)" > "$tmp_file"
	echo "# 实例：$section" >> "$tmp_file"

	# 注意：此时 shell 上下文里的变量是 server section validate 后注入的
	# server section 字段直接 append，使用统一 . 分隔（append_options 内部把 . 还原为 .）
	append_options "$tmp_file" \
		"user" "serverAddr" "serverPort..INT" "natHoleStunServer" "dnsServer" \
		"loginFailExit..INT" "auth.method" "auth.token"

	if [ "x$enable_logging" = "x1" ] ; then
		append_options "$tmp_file" \
			"log.to" "log.level" "log.maxDays..INT" "log.disablePrintColor..INT"
	fi

	append_options "$tmp_file" \
		"transport.poolCount..INT" "transport.tcpMux..INT" "transport.tcpMuxKeepaliveInterval..INT" "transport.protocol" \
		"transport.quic.keepalivePeriod..INT" "transport.quic.maxIdleTimeout..INT" "transport.quic.maxIncomingStreams..INT" \
		"transport.proxyURL" "transport.tls.enable..INT" "transport.tls.disableCustomTLSFirstByte..INT" \
		"transport.tls.certFile" "transport.tls.keyFile" "transport.tls.trustedCaFile" "transport.tls.serverName" \
		"transport.heartbeatInterval..INT" "transport.heartbeatTimeout..INT" \
		"webServer.addr" "webServer.port..INT" "webServer.user" "webServer.password"

	config_list_foreach "$section" "com_extra_options" add_rule_extra_option "$tmp_file"

	# 仅写入归属本实例的 rule
	config_foreach add_frpc_rule "rule" "$tmp_file" "$section"

	cp -f "$tmp_file" "$config_file"
	[ "$?" = "0" ] && rm -f "$tmp_file"
}
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/root/etc/init.d/frpc
git commit -m "refactor(init.d): create_config_file 接收 owner section，从 server 段读取配置字段（修复字段不生效隐藏 bug）"
```

---

### Task 2.5：重写 `logfile_prepare` 实例级

**Files:**
- Modify: `luci-app-frpc/root/etc/init.d/frpc:295-328`

- [ ] **Step 1：函数签名改造**

把整个 `logfile_prepare` 函数替换为：

```sh
logfile_prepare() {
	local section="$1"
	local link="/tmp/frpc_log_${section}.txt"
	local std_log="/tmp/frpc_std_redirect_${section}.log"

	if [ "x$enable_logging" != "x1" ];then
		rm -f "$link" "$std_log"
		echo "未配置日志输出保存" > "$link"
		return 1
	fi

	if [ "${std_redirect}" == "1" ];then
		if [ -z "${log__to}" -o "${log__to}" == "console" ];then
			log__to="$std_log"
			true >"${log__to}"
		else
			mkdir -p "$(dirname "${log__to}")"
			touch "${log__to}" 2>/dev/null
			if [ "$?" != "0" ];then
				log__to="$std_log"
				echo "【$(date +%Y-%m-%d_%H:%M:%S)】--->警告：配置的日志文件路径似乎无效/只读！" > "${log__to}"
			fi
		fi
	fi

	if [ -n "${log__to}" -a "${log__to}" != "console" ];then
		mkdir -p "$(dirname "${log__to}")"
		touch "${log__to}"
	fi

	if [ -n "$run_user" ]; then
		chmod 644 "$log__to"
		chown "$run_user" "$log__to" 2>/dev/null
	fi

	# 实例级软链
	ln -sf "${log__to}" "$link"
	# 兼容旧 UI：把全局软链指向默认（第一个 enabled）实例的日志
	# 由 start_service 末尾统一设置；本函数仅维护实例级链
}
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/root/etc/init.d/frpc
git commit -m "refactor(init.d): logfile_prepare 改为实例级（/tmp/frpc_log_<section>.txt）"
```

---

### Task 2.6：重写 `start_instance` 遍历 server section

**Files:**
- Modify: `luci-app-frpc/root/etc/init.d/frpc:329-384`

- [ ] **Step 1：整个函数替换**

```sh
start_instance() {
	local section="$1"

	if ! server_section_validate "$section" ; then
		_err "Server section validate failed: \"$section\""
		return 1
	fi

	if [ "x$enabled" != "x1" ] ; then
		_info "Instance \"$section\" disabled."
		return 0
	fi

	# 解析 client_file: server.client_file → main.default_client_file
	local effective_client="$client_file"
	if [ -z "$effective_client" ]; then
		effective_client=$(uci -q get frpc.main.default_client_file)
	fi
	if [ -z "$effective_client" ] || ( ! client_file_validate "$effective_client" ) ; then
		_err "Instance \"$section\": client_file invalid (\"$effective_client\")."
		return 1
	fi

	# 解析 run_user: server.run_user → main.default_run_user
	local effective_user="$run_user"
	if [ -z "$effective_user" ]; then
		effective_user=$(uci -q get frpc.main.default_run_user)
	fi

	# 自动分配 admin port（若未显式配置）
	local effective_admin_port
	effective_admin_port=$(assign_admin_port "$section")
	if [ -n "$effective_admin_port" ]; then
		mkdir -p /var/run/frpc
		echo "$effective_admin_port" > "/var/run/frpc/${section}.admin_port"
		# 若 webServer__port 为空，注入到本次 shell 上下文，让 append_options 写到 toml
		[ -z "$webServer__port" ] && webServer__port="$effective_admin_port"
		# 默认 admin 监听 127.0.0.1，避免外网暴露
		[ -z "$webServer__addr" ] && webServer__addr="127.0.0.1"
	fi

	test -d "$CONFIG_FOLDER" || mkdir -p "$CONFIG_FOLDER"
	local config_file="$CONFIG_FOLDER/frpc.${section}.toml"

	create_config_file "$config_file" "$section"

	if [ ! -f "$config_file" ] ; then
		_err "Could not create config file: \"$config_file\""
		return 1
	fi

	logfile_prepare "$section"

	# 记录实例 state（供 controller 读取）
	mkdir -p /var/run/frpc
	{
		echo "section=${section}"
		echo "toml=${config_file}"
		echo "log=${log__to}"
		echo "admin_port=${effective_admin_port}"
		echo "client_file=${effective_client}"
	} > "/var/run/frpc/${section}.state"

	procd_open_instance "frpc.${section}"
	if [ "${std_redirect}" == "1" ];then
		procd_set_param command "/bin/sh"
		procd_append_param command -c "exec ${effective_client} -c ${config_file} >>\"${log__to}\" 2>&1"
	else
		procd_set_param command "$effective_client"
		procd_append_param command -c "$config_file"
	fi
	procd_set_param respawn
	procd_set_param file "$config_file"
	[ -n "$effective_user" ] && procd_set_param user "$effective_user"
	procd_close_instance
}
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/root/etc/init.d/frpc
git commit -m "refactor(init.d): start_instance 重写为按 server section 启动，含 client_file/run_user 回落与 admin port 自动分配"
```

---

### Task 2.7：重写 `start_service` + 兼容性全局软链

**Files:**
- Modify: `luci-app-frpc/root/etc/init.d/frpc:390-393`

- [ ] **Step 1：替换 start_service**

```sh
start_service() {
	config_load "$NAME"

	# 全局总开关
	local global_enabled
	global_enabled=$(uci -q get frpc.main.enabled)
	if [ "$global_enabled" != "1" ]; then
		_info "Global disabled (frpc.main.enabled != 1)."
		return 0
	fi

	mkdir -p /var/run/frpc
	# 遍历 server section
	config_foreach start_instance "server"

	# 兼容旧 UI：全局软链指向"默认 server"（第一个 enabled）
	local default_link=""
	for f in /var/run/frpc/*.state; do
		[ -f "$f" ] || continue
		local sec
		sec=$(basename "$f" .state)
		[ "$(uci -q get frpc.${sec}.enabled)" = "1" ] || continue
		default_link="/tmp/frpc_log_${sec}.txt"
		break
	done
	if [ -n "$default_link" ] && [ -e "$default_link" ]; then
		ln -sf "$default_link" /tmp/frpc_log_link.txt
	fi
}

service_stopped() {
	# 清理实例 state，但保留 admin_port 缓存（下次启动复用避免漂移）
	rm -f /var/run/frpc/*.state 2>/dev/null
}
```

- [ ] **Step 2：推送 + 启动两实例验证**

```bash
ssh root@192.168.0.187 'uci batch <<EOF
set frpc.main=frpc
set frpc.main.enabled=1
set frpc.main.default_client_file=/usr/bin/frpc
set frpc.main.migrated_v2=1

set frpc.frps=server
set frpc.frps.enabled=1
set frpc.frps.alias=A
set frpc.frps.serverAddr=127.0.0.1
set frpc.frps.serverPort=7000

set frpc.jp=server
set frpc.jp.enabled=1
set frpc.jp.alias=B
set frpc.jp.serverAddr=127.0.0.1
set frpc.jp.serverPort=7100

commit frpc
EOF
/etc/init.d/frpc restart
sleep 2
ls /var/etc/frpc/
ls /var/run/frpc/
ps | grep frpc | grep -v grep'
```

Expected:
- `/var/etc/frpc/frpc.frps.toml` 和 `/var/etc/frpc/frpc.jp.toml` 都存在；
- `/var/run/frpc/frps.state` 和 `/var/run/frpc/jp.state` 都存在；
- `ps | grep frpc` 显示两个独立进程（命令行分别带 `frpc.frps.toml` 和 `frpc.jp.toml`）。

- [ ] **Step 3：验证 toml 内容只含归属本实例的 rule**

```bash
ssh root@192.168.0.187 'cat /var/etc/frpc/frpc.frps.toml; echo "---"; cat /var/etc/frpc/frpc.jp.toml'
```

Expected: 两个 toml 的 `[[proxies]]` 段互不重叠，各自只包含 `server_id` 指向自己的 rule。

- [ ] **Step 4：Commit**

```bash
git add luci-app-frpc/root/etc/init.d/frpc
git commit -m "feat(init.d): start_service 改为遍历 server section + 全局总开关 + 旧 UI 软链兼容"
```

---

### Task 2.8：移除 `frpc_scetion_validate` 老校验函数

**Files:**
- Modify: `luci-app-frpc/root/etc/init.d/frpc:91-127`

- [ ] **Step 1：审查依赖**

```bash
grep -n "frpc_scetion_validate\|frpc_section_validate" luci-app-frpc/root/etc/init.d/frpc
```

Expected: 重写 start_instance 后应仅剩函数定义本身，无调用方。

- [ ] **Step 2：删除函数定义（第 91–127 行）**

把 `frpc_scetion_validate() { ... }` 整段删除。

- [ ] **Step 3：再次推送 + 重启验证**

```bash
scp luci-app-frpc/root/etc/init.d/frpc root@192.168.0.187:/etc/init.d/frpc
ssh root@192.168.0.187 '/etc/init.d/frpc restart; sleep 2; ps | grep frpc | grep -v grep'
```

Expected: 两实例仍然运行。

- [ ] **Step 4：Commit**

```bash
git add luci-app-frpc/root/etc/init.d/frpc
git commit -m "refactor(init.d): 删除已废弃的 frpc_scetion_validate（多实例化后不再使用）"
```

---

## Phase 3 — 控制器接口

> 所有改动集中在 `luci-app-frpc/luasrc/controller/frpc.lua`。
> 推送命令：`scp luci-app-frpc/luasrc/controller/frpc.lua root@192.168.0.187:/usr/lib/lua/luci/controller/frpc.lua && ssh root@192.168.0.187 'rm -rf /tmp/luci-indexcache /tmp/luci-modulecache'`。

### Task 3.1：新增辅助函数 `_collect_instances`

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua`（在 `action_status` 之前插入）

- [ ] **Step 1：插入函数**

```lua
-- 多实例：枚举所有 server section 并补齐运行时状态
local function _collect_instances()
	local list = {}
	uci:foreach("frpc", "server", function(s)
		local name = s[".name"]
		local toml = "/var/etc/frpc/frpc." .. name .. ".toml"
		local running = (sys.call("pgrep -f 'frpc%." .. name .. "%.toml' >/dev/null") == 0)
		local admin_port_raw = util.trim(sys.exec("cat /var/run/frpc/" .. name .. ".admin_port 2>/dev/null"))
		local admin_port = tonumber(admin_port_raw) or nil

		local proxies_total, proxies_online, admin_reachable, last_error = 0, 0, false, ""
		if running and admin_port then
			-- frpc admin /api/status 返回各 proxy 类型分组
			local auth = ""
			local au = s.admin_user or s.webServer__user
			local ap = s.admin_password or s.webServer__password
			if au and au ~= "" then
				auth = string.format("-u %q:%q ", au, ap or "")
			end
			local cmd = string.format(
				"curl -s --max-time 1 %shttp://127.0.0.1:%d/api/status 2>/dev/null",
				auth, admin_port)
			local body = sys.exec(cmd)
			if body and body ~= "" then
				admin_reachable = true
				-- 用 jsonc 而非自己 parse；OpenWrt 标配 luci.jsonc
				local ok, parsed = pcall(function()
					return require("luci.jsonc").parse(body)
				end)
				if ok and type(parsed) == "table" then
					for _, group in pairs(parsed) do
						if type(group) == "table" then
							for _, p in ipairs(group) do
								proxies_total = proxies_total + 1
								if p.status == "online" or p.status == "running" then
									proxies_online = proxies_online + 1
								elseif p.err and p.err ~= "" then
									last_error = p.err
								end
							end
						end
					end
				end
			end
		end

		table.insert(list, {
			name = name,
			alias = s.alias or name,
			enabled = (s.enabled == "1"),
			running = running,
			admin_port = admin_port,
			admin_reachable = admin_reachable,
			proxies_total = proxies_total,
			proxies_online = proxies_online,
			last_error = last_error,
		})
	end)
	return list
end
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/luasrc/controller/frpc.lua
git commit -m "feat(controller): 新增 _collect_instances 聚合多实例运行时状态（pgrep + admin API）"
```

---

### Task 3.2：重写 `action_status` 返回数组并保留向后兼容

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua:85-100`

- [ ] **Step 1：替换函数**

```lua
function action_status()
	local instances = _collect_instances()
	local any_running = false
	for _, ins in ipairs(instances) do
		if ins.running then any_running = true; break end
	end

	http.prepare_content("application/json")
	http.write_json({
		running = any_running,                                  -- 兼容旧 UI
		global_enabled = (uci:get("frpc", "main", "enabled") == "1"),
		instances = instances,
	})
end
```

- [ ] **Step 2：验证**

```bash
curl -sk "https://192.168.0.187/cgi-bin/luci/admin/services/frpc/status" \
	-H "Cookie: sysauth=<手动登录后从浏览器拷贝>" | jsonfilter -e '@.instances[*].name'
```

Expected: 输出 `frps` 和 `jp`（顺序按 UCI section 顺序）。

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/luasrc/controller/frpc.lua
git commit -m "feat(controller): action_status 改为返回多实例数组，保留 running 顶层字段做兼容"
```

---

### Task 3.3：新增 `action_instance_action`

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua`（在 `action_reload` 后插入）

- [ ] **Step 1：插入函数**

```lua
function action_instance_action()
	local server = http.formvalue("server")
	local op     = http.formvalue("op")
	local code = 1
	local msg = "unknown op"

	-- 验证 server 存在
	if not server or uci:get("frpc", server) ~= "server" then
		http.prepare_content("application/json")
		http.write_json({ code = 2, message = "server not found" })
		return
	end

	if op == "start" then
		uci:set("frpc", server, "enabled", "1")
		uci:commit("frpc")
		code = sys.call("/etc/init.d/frpc reload >/dev/null 2>&1")
		msg = "ok"
	elseif op == "stop" then
		uci:set("frpc", server, "enabled", "0")
		uci:commit("frpc")
		code = sys.call("/etc/init.d/frpc reload >/dev/null 2>&1")
		msg = "ok"
	elseif op == "restart" then
		code = sys.call("/etc/init.d/frpc restart frpc." .. server .. " >/dev/null 2>&1")
		msg = "ok"
	end

	http.prepare_content("application/json")
	http.write_json({ code = code, message = msg })
end
```

- [ ] **Step 2：在 `index()` 中注册路由**

把 `entry({"admin", "services", "frpc", "reload"}, call("action_reload"))` 后追加：

```lua
	entry({"admin", "services", "frpc", "instance_action"}, call("action_instance_action"))
```

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/luasrc/controller/frpc.lua
git commit -m "feat(controller): 新增 instance_action 接口（start/stop 走 UCI, restart 走 procd 单实例）"
```

---

### Task 3.4：新增 `action_instance_admin_url`

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua`

- [ ] **Step 1：插入函数**

```lua
function action_instance_admin_url()
	local server = http.formvalue("server")
	local port = util.trim(sys.exec("cat /var/run/frpc/" .. server .. ".admin_port 2>/dev/null"))
	local lan_ip = util.trim(sys.exec("uci -q get network.lan.ipaddr || ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'"))

	local url = ""
	if port ~= "" and lan_ip ~= "" then
		url = string.format("http://%s:%s", lan_ip, port)
	end

	http.prepare_content("application/json")
	http.write_json({ url = url, port = port })
end
```

> 注意：admin port 默认绑定 127.0.0.1，从 LAN 访问需要用户在 server-detail 中把 `webServer__addr` 显式改为 `0.0.0.0`。

- [ ] **Step 2：注册路由**

在 `index()` 中追加：

```lua
	entry({"admin", "services", "frpc", "instance_admin_url"}, call("action_instance_admin_url"))
```

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/luasrc/controller/frpc.lua
git commit -m "feat(controller): 新增 instance_admin_url 接口供 UI 跳转 Dashboard"
```

---

### Task 3.5：改造 `get_log` / `clear_log` 接受 `?server=`

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua`（找到 `get_log` 与 `clear_log`）

- [ ] **Step 1：辅助函数 + 改造**

在 `get_log` 之前插入：

```lua
local function _resolve_log_link(server)
	-- 显式指定优先
	if server and server ~= "" then
		return "/tmp/frpc_log_" .. server .. ".txt"
	end
	-- 默认 server：第一个 enabled 的 server
	local default_link = "/tmp/frpc_log_link.txt"
	uci:foreach("frpc", "server", function(s)
		if s.enabled == "1" then
			default_link = "/tmp/frpc_log_" .. s[".name"] .. ".txt"
			return false
		end
	end)
	return default_link
end
```

替换 `get_log` 和 `clear_log` 函数体为：

```lua
function get_log()
	local server = http.formvalue("server")
	local link = _resolve_log_link(server)
	luci.http.write(luci.sys.exec("tail -c 200000 " .. link .. " 2>/dev/null"))
end

function clear_log()
	local server = http.formvalue("server")
	local link = _resolve_log_link(server)
	luci.sys.call("true > " .. link)
end
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/luasrc/controller/frpc.lua
git commit -m "feat(controller): get_log/clear_log 支持 ?server= 参数，未指定时退化到默认 server"
```

---

### Task 3.6：改造 `action_restart` / `action_reload` 接受 `?server=`

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua:102-112`

- [ ] **Step 1：替换两个函数**

```lua
function action_restart()
	local server = http.formvalue("server")
	local cmd
	if server and server ~= "" and uci:get("frpc", server) == "server" then
		cmd = "/etc/init.d/frpc restart frpc." .. server .. " >/dev/null 2>&1"
	else
		cmd = "/etc/init.d/frpc restart >/dev/null 2>&1"
	end
	local code = sys.call(cmd)
	http.prepare_content("application/json")
	http.write_json({ code = code })
end

function action_reload()
	-- reload 始终是全局的，单实例 reload 没有意义（rule 归属可能在多实例间漂移）
	local code = sys.call("/etc/init.d/frpc reload >/dev/null 2>&1")
	http.prepare_content("application/json")
	http.write_json({ code = code })
end
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/luasrc/controller/frpc.lua
git commit -m "feat(controller): restart 支持 ?server= 单实例；reload 保持全局"
```

---

### Task 3.7：阶段 curl 端到端验证

- [ ] **Step 1：拿到 sysauth cookie**

浏览器登录 `http://192.168.0.187/cgi-bin/luci/`，F12 复制 `sysauth_http` 或 `sysauth` cookie 值，写入本地变量 `SYSAUTH`。

- [ ] **Step 2：跑全套接口**

```bash
BASE="http://192.168.0.187/cgi-bin/luci/admin/services/frpc"
COOKIE="sysauth=$SYSAUTH"

echo "--- status ---"
curl -s -H "Cookie: $COOKIE" "$BASE/status" | head -c 500
echo

echo "--- instance_action stop frps ---"
curl -s -H "Cookie: $COOKIE" -X POST "$BASE/instance_action?server=frps&op=stop"
sleep 2
ssh root@192.168.0.187 'ps | grep frpc.frps.toml | grep -v grep || echo "stopped"'

echo "--- instance_action start frps ---"
curl -s -H "Cookie: $COOKIE" -X POST "$BASE/instance_action?server=frps&op=start"
sleep 2
ssh root@192.168.0.187 'ps | grep frpc.frps.toml | grep -v grep'

echo "--- get_log frps ---"
curl -s -H "Cookie: $COOKIE" "$BASE/get_log?server=frps" | tail -c 500
```

Expected:
- status 返回包含 `"instances":[...]` 数组；
- stop 后 frps 进程消失，jp 仍在；
- start 后 frps 进程回归；
- get_log 返回 frps 的日志内容。

- [ ] **Step 3：Phase 3 提示**

控制器接口完整工作。UI 还在用旧的单实例视图，下一阶段会全面改造。

---

## Phase 4 — UI 改造

> 推送命令统一：`bash` 脚本里调 `frpc-dev-deploy` 项目 skill；或手工 `scp luci-app-frpc/luasrc/... root@192.168.0.187:/usr/lib/lua/luci/...`，最后清缓存 `rm -rf /tmp/luci-indexcache /tmp/luci-modulecache`。

### Task 4.1：common.lua 瘦身

**Files:**
- Modify: `luci-app-frpc/luasrc/model/cbi/frpc/common.lua`

- [ ] **Step 1：替换文件内容**

把整文件替换为：

```lua
-- Copyright 2019 Xingwang Liao <kuoruan@gmail.com> #modify by superzjg@gmail.com 20240810
-- Licensed to the public under the MIT License.

local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local fs = require "nixio.fs"
local sys = require "luci.sys"

local m, s, o

local function frpc_version()
	local file = uci:get("frpc", "main", "default_client_file")
	if not file or file == "" or not fs.stat(file) then
		return "<em style=\"color: red;\">%s</em>" % translate("可执行文件无效")
	end
	if not fs.access(file, "rwx", "rx", "rx") then
		fs.chmod(file, 755)
	end
	local version = util.trim(sys.exec("%s -v 2>/dev/null" % file))
	if version == "" then
		return "<em style=\"color: red;\">%s</em>" % translate("未能获取到版本信息")
	end
	if version < "0.52.0" then
		return "<em style=\"color: red;\">%s</em>" % translatef("升级至 0.52.0 或以上才支持 toml 配置文件，当前版本：%s", version)
	end
	return translatef("版本: %s", version)
end

m = Map("frpc", "%s - %s" % { translate("Frpc"), translate("通用设置") },
"<p>%s</p><p>%s</p>" % {
	translate("Frp 是一个可用于内网穿透的高性能的反向代理应用。多实例模式下，每个服务器（server）就是一个独立的 frpc 进程。"),
	translatef("获取更多信息，请访问： %s",
		"<a href=\"https://github.com/fatedier/frp\" target=\"_blank\">https://github.com/fatedier/frp</a>；官方文档：<a href=\"https://gofrp.org/zh-cn/\" target=\"_blank\">gofrp.org</a>")
})

m:append(Template("frpc/status_header"))

s = m:section(NamedSection, "main", "frpc")
s.addremove = false
s.anonymous = true

s:tab("general", translate("常规选项"))
s:tab("program", translate("程序管理"))

o = s:taboption("program", DummyValue, "_program_ui", "")
o.template = "frpc/program_manager"
o.rawhtml = true
o.cfgvalue = function() return "" end

o = s:taboption("general", Flag, "enabled", translate("全局启用"))
o.description = translate("总开关；关闭则所有实例都不启动")

o = s:taboption("general", Value, "default_client_file", translate("默认可执行文件路径"), frpc_version())
o.datatype = "file"
o.rmempty = false
o.default = "/usr/bin/frpc"
o.description = translate("server 若未指定 client_file，则使用此默认值")

o = s:taboption("general", ListValue, "default_run_user", translate("默认运行用户"))
o:value("", translate("-- 默认 --"))
for user in util.execi("cat /etc/passwd | cut -d':' -f1") do
	if user then o:value(user) end
end

o = s:taboption("general", Value, "download_mirror", translate("下载镜像源"))
o.description = translate("程序管理：下载 frp 时使用的镜像 URL 前缀")

return m
```

- [ ] **Step 2：推送 + 浏览器验证**

打开 `http://192.168.0.187/cgi-bin/luci/admin/services/frpc/common`，确认页面只剩"常规选项""程序管理"两个 tab，所有 advanced/manage 字段不再出现。

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/luasrc/model/cbi/frpc/common.lua
git commit -m "refactor(ui): common.lua 瘦身为全局设置（仅 enabled + default_client_file + default_run_user + download_mirror）"
```

---

### Task 4.2：server-detail.lua 接收下沉字段

**Files:**
- Modify: `luci-app-frpc/luasrc/model/cbi/frpc/server-detail.lua`

- [ ] **Step 1：完整重写**

```lua
-- 多实例：server section 编辑页（接收从 main 下沉的所有 frps 连接字段）
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"

local m, s, o

local sid = arg[1]
if not sid or uci:get("frpc", sid) ~= "server" then
	luci.http.redirect(luci.dispatcher.build_url("admin/services/frpc/servers"))
	return
end

m = Map("frpc", "%s - %s" % { translate("Frpc"), translate("服务器配置") })

s = m:section(NamedSection, sid, "server")
s.addremove = false
s.anonymous = true

s:tab("general", translate("常规"))
s:tab("advanced", translate("高级"))
s:tab("manage", translate("管理"))
s:tab("log", translate("日志"))

-- === general ===
o = s:taboption("general", Flag, "enabled", translate("启用此实例"))
o.default = "0"

o = s:taboption("general", Value, "alias", translate("别名"))
o.placeholder = sid

o = s:taboption("general", Value, "client_file", translate("可执行文件（留空 = 全局默认）"))
o.datatype = "file"

o = s:taboption("general", ListValue, "run_user", translate("运行用户（留空 = 全局默认）"))
o:value("", translate("-- 全局默认 --"))
for user in util.execi("cat /etc/passwd | cut -d':' -f1") do
	if user then o:value(user) end
end

o = s:taboption("general", Value, "serverAddr", translate("frps 地址"))
o.rmempty = false

o = s:taboption("general", Value, "serverPort", translate("frps 端口"))
o.datatype = "port"
o.default = "7000"

o = s:taboption("general", Value, "user", translate("用户名"))

o = s:taboption("general", ListValue, "auth__method", translate("认证方式"))
o:value("", translate("无"))
o:value("token", "token")
o:value("oidc", "oidc")

o = s:taboption("general", Value, "auth__token", translate("Token"))
o.password = true
o:depends("auth__method", "token")

-- === advanced ===
o = s:taboption("advanced", ListValue, "transport__protocol", translate("传输协议"))
o:value("", translate("默认 tcp"))
o:value("tcp"); o:value("kcp"); o:value("quic"); o:value("websocket"); o:value("wss")

o = s:taboption("advanced", Flag, "transport__tcpMux", translate("启用 tcpMux"))
o.enabled = "true"
o.disabled = "false"

o = s:taboption("advanced", Value, "transport__heartbeatInterval", translate("心跳间隔（秒）"))
o.datatype = "integer"

o = s:taboption("advanced", Value, "transport__heartbeatTimeout", translate("心跳超时（秒）"))
o.datatype = "integer"

o = s:taboption("advanced", Flag, "transport__tls__enable", translate("启用 TLS"))
o.enabled = "true"
o.disabled = "false"

o = s:taboption("advanced", Value, "transport__tls__serverName", translate("TLS serverName"))
o:depends("transport__tls__enable", "true")

o = s:taboption("advanced", Value, "dnsServer", translate("DNS 服务器"))
o.datatype = "host"

o = s:taboption("advanced", Value, "natHoleStunServer", translate("NAT 打洞 STUN 服务器"))

o = s:taboption("advanced", Flag, "loginFailExit", translate("登录失败退出"))
o.enabled = "true"
o.disabled = "false"

-- === manage（每实例独立 admin webServer）===
o = s:taboption("manage", Value, "admin_port", translate("Admin 端口（留空 = 自动分配 7400 起）"))
o.datatype = "port"

o = s:taboption("manage", Value, "webServer__addr", translate("Admin 监听地址"))
o.default = "127.0.0.1"
o.description = translate("默认 127.0.0.1 仅本机；改为 0.0.0.0 可从 LAN 访问 Dashboard")

o = s:taboption("manage", Value, "admin_user", translate("Admin 用户"))

o = s:taboption("manage", Value, "admin_password", translate("Admin 密码"))
o.password = true

-- === log ===
o = s:taboption("log", Flag, "enable_logging", translate("启用日志"))

o = s:taboption("log", Value, "log__to", translate("日志路径"))
o:depends("enable_logging", "1")
o.description = translate("留空默认 /var/log/frpc/<server>.log")

o = s:taboption("log", ListValue, "log__level", translate("日志级别"))
o:depends("enable_logging", "1")
o:value("trace"); o:value("debug"); o:value("info"); o:value("warn"); o:value("error")

o = s:taboption("log", Value, "log__maxDays", translate("最大保留天数"))
o:depends("enable_logging", "1")
o.datatype = "uinteger"

o = s:taboption("log", Flag, "std_redirect", translate("捕获 stdout/stderr 到日志"))
o:depends("enable_logging", "1")

return m
```

- [ ] **Step 2：浏览器验证**

服务器列表点 frps 编辑，确认四个 tab 都展示且字段都能读写。

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/luasrc/model/cbi/frpc/server-detail.lua
git commit -m "refactor(ui): server-detail 接收下沉字段，新增 admin port / log 配置 tab"
```

---

### Task 4.3：rule-detail.lua 增加 server_id 下拉

**Files:**
- Modify: `luci-app-frpc/luasrc/model/cbi/frpc/rule-detail.lua`（在文件顶部 Map 创建后插入）

- [ ] **Step 1：在所有现有 option 之前插入 server_id**

定位到第一个 `o = s:option(...)` 或 `o = s:taboption(...)` 之前，插入：

```lua
-- 多实例：rule 必须归属一个 server
local server_choices = {}
uci:foreach("frpc", "server", function(srv)
	server_choices[#server_choices + 1] = { srv[".name"], srv.alias or srv[".name"] }
end)

o = s:taboption("general", ListValue, "server_id", translate("归属服务器"))
o.rmempty = false
for _, c in ipairs(server_choices) do
	o:value(c[1], c[2])
end
o.description = translate("此规则仅会写入该服务器对应的 frpc 实例")
```

> 如果 rule-detail.lua 还未引入 `uci`，在文件顶部加 `local uci = require "luci.model.uci".cursor()`。如果当前文件没有 tab 结构（直接 `s:option`），把 `taboption("general", ...)` 换成 `option(...)`。

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/luasrc/model/cbi/frpc/rule-detail.lua
git commit -m "feat(ui): rule-detail 新增必填 server_id 下拉（归属服务器）"
```

---

### Task 4.4：rules.lua 增加「所属服务器」列与筛选

**Files:**
- Modify: `luci-app-frpc/luasrc/model/cbi/frpc/rules.lua`

- [ ] **Step 1：在文件顶部加载 server 名称映射**

在 `m = Map(...)` 之前插入：

```lua
local server_table = {}
uci:foreach("frpc", "server", function(s)
	server_table[s[".name"]] = s.alias or s[".name"]
end)
```

- [ ] **Step 2：在第一个列字段（一般是 enabled）之前插入「所属服务器」列**

找到 `o = s:option(Flag, "enabled", ...)`，在之前插入：

```lua
o = s:option(ListValue, "server_id", translate("归属服务器"))
for k, v in pairs(server_table) do
	o:value(k, v)
end
o.write = function(self, section, value)
	return self.map:set(section, self.option, value)
end
```

> ListValue 在列表页直接给出下拉编辑能力，省一次跳转。

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/luasrc/model/cbi/frpc/rules.lua
git commit -m "feat(ui): rules 列表新增「所属服务器」列（下拉直接修改）"
```

---

### Task 4.5：rules.lua 顶部 server 筛选下拉（前端过滤）

**Files:**
- Modify: `luci-app-frpc/luasrc/model/cbi/frpc/rules.lua`

- [ ] **Step 1：通过 Template 注入筛选条**

在 `m = Map(...)` 后插入：

```lua
m:append(Template("frpc/rules_filter"))
```

- [ ] **Step 2：创建 `luasrc/view/frpc/rules_filter.htm`**

**Files:**
- Create: `luci-app-frpc/luasrc/view/frpc/rules_filter.htm`

```html
<%
local uci = require "luci.model.uci".cursor()
local servers = {}
uci:foreach("frpc", "server", function(s)
	servers[#servers+1] = { s[".name"], s.alias or s[".name"] }
end)
%>
<style>
.frpc-rules-filter { margin: 8px 0; }
.frpc-rules-filter select { min-width: 200px; }
tr.cbi-section-table-row.frpc-hidden { display: none; }
</style>
<div class="frpc-rules-filter">
	<label>筛选服务器：</label>
	<select id="frpc_rule_filter">
		<option value="">全部</option>
		<% for _, s in ipairs(servers) do %>
		<option value="<%=s[1]%>"><%=s[2]%></option>
		<% end %>
	</select>
</div>
<script>
(function() {
	function applyFilter() {
		var sel = document.getElementById('frpc_rule_filter');
		var v = sel.value;
		var rows = document.querySelectorAll('tr.cbi-section-table-row');
		rows.forEach(function(tr) {
			if (!v) { tr.classList.remove('frpc-hidden'); return; }
			var s = tr.querySelector('select[id$=".server_id"]');
			var rowServer = s ? s.value : '';
			if (rowServer === v) tr.classList.remove('frpc-hidden');
			else tr.classList.add('frpc-hidden');
		});
	}
	document.addEventListener('DOMContentLoaded', function() {
		var sel = document.getElementById('frpc_rule_filter');
		if (sel) {
			sel.addEventListener('change', applyFilter);
			applyFilter();
		}
	});
})();
</script>
```

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/luasrc/model/cbi/frpc/rules.lua luci-app-frpc/luasrc/view/frpc/rules_filter.htm
git commit -m "feat(ui): rules 顶部新增服务器筛选下拉（前端过滤）"
```

---

### Task 4.6：rules.lua 多选 + 批量改归属

**Files:**
- Modify: `luci-app-frpc/luasrc/model/cbi/frpc/rules.lua`
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua`（新增 `rule_batch_set_server`）

- [ ] **Step 1：控制器新增接口**

在 `controller/frpc.lua` 中插入：

```lua
function action_rule_batch_set_server()
	local rules_csv = http.formvalue("rules") or ""
	local target = http.formvalue("server") or ""
	if uci:get("frpc", target) ~= "server" then
		http.prepare_content("application/json")
		http.write_json({ code = 1, message = "target server not found" })
		return
	end
	local count = 0
	for r in rules_csv:gmatch("([^,]+)") do
		if uci:get("frpc", r) == "rule" then
			uci:set("frpc", r, "server_id", target)
			count = count + 1
		end
	end
	uci:commit("frpc")
	http.prepare_content("application/json")
	http.write_json({ code = 0, count = count })
end
```

注册路由：

```lua
	entry({"admin", "services", "frpc", "rule_batch_set_server"}, call("action_rule_batch_set_server"))
```

- [ ] **Step 2：在 rules_filter.htm 中追加批量操作 UI**

在 `<div class="frpc-rules-filter">` 内末尾追加：

```html
	<span style="margin-left: 20px;">
		批量改归属到：
		<select id="frpc_rule_batch_target">
			<option value="">-- 选择目标 --</option>
			<% for _, s in ipairs(servers) do %>
			<option value="<%=s[1]%>"><%=s[2]%></option>
			<% end %>
		</select>
		<button type="button" id="frpc_rule_batch_apply">应用到勾选行</button>
	</span>
```

在脚本 `applyFilter` 之后追加：

```javascript
function rowCheckboxes() {
	// 给每行加 checkbox（一次性）
	var rows = document.querySelectorAll('tr.cbi-section-table-row');
	rows.forEach(function(tr) {
		if (tr.querySelector('.frpc-row-check')) return;
		var sid = tr.id.replace('cbi-frpc-', '');
		var td = document.createElement('td');
		var cb = document.createElement('input');
		cb.type = 'checkbox';
		cb.className = 'frpc-row-check';
		cb.dataset.sid = sid;
		td.appendChild(cb);
		tr.insertBefore(td, tr.firstChild);
	});
}
function applyBatch() {
	var target = document.getElementById('frpc_rule_batch_target').value;
	if (!target) { alert('请选择目标服务器'); return; }
	var checked = Array.from(document.querySelectorAll('.frpc-row-check:checked'));
	if (checked.length === 0) { alert('请勾选至少一条规则'); return; }
	var rules = checked.map(function(cb){return cb.dataset.sid;}).join(',');
	var fd = new FormData();
	fd.append('rules', rules);
	fd.append('server', target);
	fetch('<%=luci.dispatcher.build_url("admin/services/frpc/rule_batch_set_server")%>', {
		method: 'POST', body: fd, credentials: 'same-origin'
	}).then(function(r){return r.json();}).then(function(j){
		alert('已更新 ' + j.count + ' 条规则，刷新页面查看');
		location.reload();
	});
}
document.addEventListener('DOMContentLoaded', function() {
	rowCheckboxes();
	var btn = document.getElementById('frpc_rule_batch_apply');
	if (btn) btn.addEventListener('click', applyBatch);
});
```

- [ ] **Step 3：Commit**

```bash
git add luci-app-frpc/luasrc/model/cbi/frpc/rules.lua \
	luci-app-frpc/luasrc/view/frpc/rules_filter.htm \
	luci-app-frpc/luasrc/controller/frpc.lua
git commit -m "feat(ui): rules 支持多选 + 批量改归属服务器"
```

---

### Task 4.7：新建 `view/frpc/server_row.htm` 渲染状态灯与操作下拉

**Files:**
- Create: `luci-app-frpc/luasrc/view/frpc/server_row.htm`

- [ ] **Step 1：创建文件**

```html
<%
local sid = self.section
%>
<div class="frpc-server-cell" data-server="<%=sid%>">
	<span class="frpc-status-dot frpc-status-unknown" id="frpc_dot_<%=sid%>" title="加载中">●</span>
	<span class="frpc-proxies" id="frpc_proxies_<%=sid%>">-/-</span>
	<div class="frpc-actions">
		<button type="button" class="frpc-action-toggle" onclick="frpcToggleMenu('<%=sid%>')">▾ 操作</button>
		<div class="frpc-action-menu" id="frpc_menu_<%=sid%>" style="display:none;">
			<a href="#" onclick="frpcAction('<%=sid%>','start');return false;" data-show-when="stopped">启动</a>
			<a href="#" onclick="frpcAction('<%=sid%>','stop');return false;" data-show-when="running">停止</a>
			<a href="#" onclick="frpcAction('<%=sid%>','restart');return false;" data-show-when="running">重启</a>
			<a href="<%=luci.dispatcher.build_url('admin/services/frpc/log')%>?server=<%=sid%>" target="_blank">看日志</a>
			<a href="#" onclick="frpcOpenAdmin('<%=sid%>');return false;" data-show-when="reachable">Dashboard</a>
		</div>
	</div>
</div>
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/luasrc/view/frpc/server_row.htm
git commit -m "feat(ui): 新增 server_row.htm 模板（状态灯 + 操作下拉）"
```

---

### Task 4.8：servers.lua 接入 server_row.htm 与状态轮询

**Files:**
- Modify: `luci-app-frpc/luasrc/model/cbi/frpc/servers.lua`

- [ ] **Step 1：在列表中追加 DummyValue 列引用模板**

找到 `s = m:section(TypedSection, "server")` 后第一个 `o = s:option(...)` 之前，插入：

```lua
o = s:option(DummyValue, "_status", translate("状态 / 操作"))
o.template = "frpc/server_row"
o.rawhtml = true
o.cfgvalue = function() return "" end
```

并在 `m = Map(...)` 之后追加全局轮询脚本（用一个独立 Template 注入）：

```lua
m:append(Template("frpc/servers_poll"))
```

- [ ] **Step 2：创建 `view/frpc/servers_poll.htm`**

**Files:**
- Create: `luci-app-frpc/luasrc/view/frpc/servers_poll.htm`

```html
<style>
.frpc-status-dot { font-size: 18px; vertical-align: middle; margin-right: 4px; }
.frpc-status-running   { color: #4caf50; }
.frpc-status-warning   { color: #ff9800; }
.frpc-status-stopped   { color: #f44336; }
.frpc-status-unknown   { color: #9e9e9e; }
.frpc-proxies { font-size: 12px; color: #666; margin-right: 8px; }
.frpc-actions { display: inline-block; position: relative; }
.frpc-action-menu { position: absolute; top: 100%; right: 0; background: #fff; border: 1px solid #ccc; min-width: 120px; z-index: 100; box-shadow: 0 2px 6px rgba(0,0,0,0.15); }
.frpc-action-menu a { display: block; padding: 6px 12px; text-decoration: none; color: #333; }
.frpc-action-menu a:hover { background: #f0f0f0; }
.frpc-action-menu a.frpc-disabled { color: #aaa; pointer-events: none; }
</style>
<script>
function frpcToggleMenu(sid) {
	var m = document.getElementById('frpc_menu_' + sid);
	if (!m) return;
	// 关其他菜单
	document.querySelectorAll('.frpc-action-menu').forEach(function(el){
		if (el !== m) el.style.display = 'none';
	});
	m.style.display = (m.style.display === 'none') ? 'block' : 'none';
}
function frpcAction(sid, op) {
	var fd = new FormData();
	fd.append('server', sid);
	fd.append('op', op);
	fetch('<%=luci.dispatcher.build_url("admin/services/frpc/instance_action")%>', {
		method: 'POST', body: fd, credentials: 'same-origin'
	}).then(function(){ setTimeout(frpcRefreshStatus, 1000); });
}
function frpcOpenAdmin(sid) {
	fetch('<%=luci.dispatcher.build_url("admin/services/frpc/instance_admin_url")%>?server=' + sid, {
		credentials: 'same-origin'
	}).then(function(r){return r.json();}).then(function(j){
		if (j.url) window.open(j.url, '_blank');
		else alert('Admin URL 不可用，请检查 admin_port 与 webServer__addr 配置');
	});
}
function frpcRefreshStatus() {
	fetch('<%=luci.dispatcher.build_url("admin/services/frpc/status")%>', {credentials:'same-origin'})
		.then(function(r){return r.json();})
		.then(function(j){
			(j.instances || []).forEach(function(ins) {
				var dot = document.getElementById('frpc_dot_' + ins.name);
				var px  = document.getElementById('frpc_proxies_' + ins.name);
				if (dot) {
					dot.className = 'frpc-status-dot ' +
						(!ins.running ? 'frpc-status-stopped' :
						 ins.admin_reachable ? 'frpc-status-running' : 'frpc-status-warning');
					dot.title = ins.running ? (ins.admin_reachable ? '运行中' : '运行中(admin 不可达)') : '已停止';
				}
				if (px) px.textContent = ins.proxies_online + '/' + ins.proxies_total;
				// 菜单项按状态显隐
				var menu = document.getElementById('frpc_menu_' + ins.name);
				if (menu) {
					menu.querySelectorAll('a[data-show-when]').forEach(function(a) {
						var when = a.dataset.showWhen;
						var show = (when === 'running' && ins.running)
							|| (when === 'stopped' && !ins.running)
							|| (when === 'reachable' && ins.admin_reachable);
						a.style.display = show ? '' : 'none';
					});
				}
			});
		});
}
document.addEventListener('DOMContentLoaded', function() {
	frpcRefreshStatus();
	setInterval(frpcRefreshStatus, 5000);
	// 点击页面其他位置关菜单
	document.addEventListener('click', function(e) {
		if (!e.target.closest('.frpc-actions')) {
			document.querySelectorAll('.frpc-action-menu').forEach(function(el){el.style.display='none';});
		}
	});
});
</script>
```

- [ ] **Step 3：浏览器验证**

打开服务器列表，状态指示灯每 5 秒刷新，停止/启动菜单可用，Dashboard 在 admin 可达时可点击。

- [ ] **Step 4：Commit**

```bash
git add luci-app-frpc/luasrc/model/cbi/frpc/servers.lua luci-app-frpc/luasrc/view/frpc/servers_poll.htm
git commit -m "feat(ui): servers 列表升级为实例控制台（状态灯 / 折叠操作菜单 / 5s 轮询）"
```

---

### Task 4.9：status_header.htm 多实例 chip

**Files:**
- Modify: `luci-app-frpc/luasrc/view/frpc/status_header.htm`

- [ ] **Step 1：替换内容**

```html
<style>
.frpc-status-bar { padding: 8px; background: #f5f5f5; border-radius: 4px; margin-bottom: 12px; }
.frpc-status-bar .frpc-chip { display: inline-block; padding: 4px 10px; margin: 2px; border-radius: 12px; background: #e0e0e0; font-size: 12px; }
.frpc-chip-on  { background: #c8e6c9; }
.frpc-chip-off { background: #ffcdd2; }
.frpc-chip-warn { background: #ffe0b2; }
</style>
<fieldset class="cbi-section">
	<legend><%:Frpc 状态%></legend>
	<div id="frpc_status_bar" class="frpc-status-bar">加载中…</div>
</fieldset>
<script>
(function() {
	function render(data) {
		var bar = document.getElementById('frpc_status_bar');
		if (!data.global_enabled) {
			bar.innerHTML = '<b style="color:#999">全局已关闭</b>';
			return;
		}
		if (!data.instances || data.instances.length === 0) {
			bar.innerHTML = '<i>尚未配置服务器</i>';
			return;
		}
		var html = '';
		data.instances.forEach(function(ins) {
			var cls = !ins.enabled ? 'frpc-chip-off'
				: ins.running ? (ins.admin_reachable ? 'frpc-chip-on' : 'frpc-chip-warn')
				: 'frpc-chip-off';
			html += '<span class="frpc-chip ' + cls + '" title="' +
				(ins.last_error || '') + '">' +
				ins.alias + ' ' + ins.proxies_online + '/' + ins.proxies_total + '</span>';
		});
		bar.innerHTML = html;
	}
	function poll() {
		fetch('<%=luci.dispatcher.build_url("admin/services/frpc/status")%>', {credentials:'same-origin'})
			.then(function(r){return r.json();}).then(render);
	}
	document.addEventListener('DOMContentLoaded', function() {
		poll();
		setInterval(poll, 5000);
	});
})();
</script>
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/luasrc/view/frpc/status_header.htm
git commit -m "feat(ui): status_header 改为多实例 chip 列表（含 online/total + 全局禁用提示）"
```

---

### Task 4.10：frpc_log.htm 实例选择下拉

**Files:**
- Modify: `luci-app-frpc/luasrc/view/frpc/frpc_log.htm`

- [ ] **Step 1：在顶部加 server 下拉**

把整文件替换为：

```html
<%
local uci = require "luci.model.uci".cursor()
local servers = {}
uci:foreach("frpc", "server", function(s)
	servers[#servers+1] = { s[".name"], s.alias or s[".name"] }
end)
%>
<fieldset class="cbi-section">
	<legend><%:frpc 日志%></legend>
	<div style="margin-bottom:8px;">
		查看：
		<select id="frpc_log_server">
			<option value="">默认（首个启用服务器）</option>
			<% for _, s in ipairs(servers) do %>
			<option value="<%=s[1]%>"><%=s[2]%></option>
			<% end %>
		</select>
		<button type="button" onclick="frpcClearLog()">清空日志</button>
	</div>
	<textarea id="log_textarea" rows="25" wrap="off" readonly="readonly"
		style="width:100%;background:#000;color:#0f0;font-family:monospace"></textarea>
</fieldset>
<script>
(function() {
	function currentServer() {
		return document.getElementById('frpc_log_server').value;
	}
	function refresh() {
		var url = '<%=luci.dispatcher.build_url("admin/services/frpc/get_log")%>';
		var s = currentServer();
		if (s) url += '?server=' + s;
		fetch(url, {credentials:'same-origin'}).then(function(r){return r.text();}).then(function(t){
			var ta = document.getElementById('log_textarea');
			var atBottom = (ta.scrollTop + ta.clientHeight + 20 >= ta.scrollHeight);
			ta.value = t;
			if (atBottom) ta.scrollTop = ta.scrollHeight;
		});
	}
	window.frpcClearLog = function() {
		var url = '<%=luci.dispatcher.build_url("admin/services/frpc/clear_log")%>';
		var s = currentServer();
		if (s) url += '?server=' + s;
		fetch(url, {method:'POST', credentials:'same-origin'}).then(refresh);
	};
	document.addEventListener('DOMContentLoaded', function() {
		refresh();
		setInterval(refresh, 2000);
		document.getElementById('frpc_log_server').addEventListener('change', refresh);
	});
})();
</script>
```

- [ ] **Step 2：Commit**

```bash
git add luci-app-frpc/luasrc/view/frpc/frpc_log.htm
git commit -m "feat(ui): 日志页加 server 切换下拉（默认看首个启用实例）"
```

---

## Phase 5 — 收尾与回归

### Task 5.1：README 更新

**Files:**
- Modify: `README.md`

- [ ] **Step 1：追加多实例说明段**

在 README 末尾追加：

```markdown
## 多实例

本版本支持同时连接多个 frps 服务器。在 LuCI 中：

1. 进入「服务 → frpc → 服务器」，每个服务器条目就是一个独立 frpc 实例；
2. 「启用此实例」开关 + 服务器列表行内「操作」下拉控制单实例启停 / 重启；
3. 「规则」页可按服务器筛选与批量改归属（`server_id` 字段）；
4. 状态栏与列表实时显示每实例的运行 / proxy 在线数；
5. 每实例独立 admin Dashboard（默认 7400 起自动分配端口）。

升级说明：从单实例版本升级时，迁移脚本会自动把 `main` 中的连接字段下沉到 `server` section，并给所有 rule 写入 `server_id`，无需手动配置。
```

- [ ] **Step 2：Commit**

```bash
git add README.md
git commit -m "docs(readme): 追加多实例使用说明"
```

---

### Task 5.2：单 server 场景回归

- [ ] **Step 1：在测试设备清空 + 仅留一个 server**

```bash
ssh root@192.168.0.187 'uci batch <<EOF
delete frpc.jp
commit frpc
EOF
/etc/init.d/frpc restart
sleep 2
ps | grep frpc | grep -v grep
curl -s http://127.0.0.1:7400/api/status -o /dev/null && echo "admin OK"'
```

Expected: 只有一个 frpc 进程；状态栏只有一个 chip；规则页操作一切如常。

- [ ] **Step 2：恢复双实例（如需继续测试）**

```bash
ssh root@192.168.0.187 'uci batch <<EOF
set frpc.jp=server
set frpc.jp.enabled=1
set frpc.jp.alias=B
set frpc.jp.serverAddr=127.0.0.1
set frpc.jp.serverPort=7100
commit frpc
EOF
/etc/init.d/frpc restart'
```

- [ ] **Step 3：无 commit（回归测试无代码变更）**

---

### Task 5.3：升级路径手工演练

- [ ] **Step 1：构造旧版数据**

```bash
ssh root@192.168.0.187 'cat > /etc/config/frpc <<EOF
config frpc "main"
	option enabled "1"
	option server "frps"
	option client_file "/usr/bin/frpc"
	option serverAddr "1.2.3.4"
	option serverPort "7000"
	option auth__token "old_token"

config server "frps"
	option alias "旧服务器"

config rule "ssh"
	option enabled "1"
	option name "ssh"
	option type "tcp"
	option localPort "22"
	option remotePort "6000"
EOF
# 删除 migrated_v2 哨兵
uci -q delete frpc.main.migrated_v2 2>/dev/null
uci commit frpc'
```

- [ ] **Step 2：触发迁移脚本 + 重启**

```bash
ssh root@192.168.0.187 'sh /etc/uci-defaults/40_luci-frpc; /etc/init.d/frpc restart; sleep 2; uci show frpc; ps | grep frpc.frps.toml | grep -v grep'
```

Expected:
- 迁移后 `frpc.frps.serverAddr=1.2.3.4`、`frpc.frps.auth__token=old_token`；
- `frpc.ssh.server_id=frps`；
- `frpc.main.migrated_v2=1`；
- frpc 进程已起。

- [ ] **Step 3：无 commit（演练无代码变更）**

---

## 自检清单

- [ ] Phase 1：默认配置 + 迁移脚本 — `uci show frpc` 符合新 schema，幂等验证通过
- [ ] Phase 2：init.d 八步重写 — 测试设备能跑两个独立 frpc 进程，toml 内 rule 按 server_id 分流
- [ ] Phase 3：控制器七个接口 — curl 跑通 status / instance_action / get_log
- [ ] Phase 4：UI 十步改造 — common 瘦身 / server-detail 接收下沉字段 / rule-detail 加 server_id / rules 分组筛选批量 / server_row 操作菜单 / servers 轮询 / status_header 多 chip / log 实例切换
- [ ] Phase 5：README + 单 server 回归 + 升级演练
