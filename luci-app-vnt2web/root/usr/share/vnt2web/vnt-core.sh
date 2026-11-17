#!/bin/sh
# vnt 公共函数库（核心层）：核心二进制下载/安装/回滚、UCI -> 命令行参数翻译、
# 进程状态查询、防火墙区域配置。
# 依赖 vnt.sh 中定义的常量与基础函数。

# ---------------------------------------------------------------------------
# 核心安装：下载 -> 校验 -> 备份 -> 原子替换 -> 失败回滚
# 采用「先写 .new 再 mv」的原子替换，避免替换中途掉电留下半个二进制。
# ---------------------------------------------------------------------------
vnt_install_core() {
	# vnt_install_core <版本> [本地zip路径]
	local ver="$1" localzip="${2:-}"
	local asset stem zip work url

	stem="$(vnt_asset_name)" || {
		vnt_ulog "ERROR: 无法识别当前架构 $(vnt_distrib_arch)，vnt 可能没有对应预编译包"
		return 2
	}
	asset="${stem}-v${ver}.zip"
	zip="$VNT_CACHE_DIR/${asset}.download"
	work="$VNT_CACHE_DIR/unpack"

	vnt_ulog "install core ver=${ver} asset=${asset}"
	vnt_ensure_dirs
	rm -rf "$work"
	mkdir -p "$work" "$VNT_CACHE_DIR"

	if [ -n "$localzip" ]; then
		[ -f "$localzip" ] || {
			vnt_ulog "local zip not found: $localzip"
			return 3
		}
		cp -f "$localzip" "$zip" || return 3
		vnt_ulog "using local file $localzip"
	else
		url="$(vnt_url "${VNT_DL}/v${ver}/${asset}")"
		vnt_ulog "download ${url}"
		if ! vnt_fetch "$url" "$zip" 600; then
			vnt_ulog "download failed: $url"
			rm -f "$zip"
			return 3
		fi
	fi

	[ -s "$zip" ] || {
		vnt_ulog "downloaded file is empty"
		rm -f "$zip"
		return 3
	}

	# 解包：优先 python3（可处理 zip），否则 unzip，再退到 busybox unzip
	if vnt_extract_zip "$zip" "$work"; then
		:
	else
		vnt_ulog "unzip failed"
		rm -f "$zip"
		return 4
	fi

	local newbin
	newbin="$(find "$work" -type f -name "$VNT_CORE" 2>/dev/null | head -n 1)"
	if [ -z "$newbin" ]; then
		# 兜底：按前缀找（防止个别版本命名带后缀）
		newbin="$(find "$work" -type f -name 'vnt2_web*' 2>/dev/null | head -n 1)"
	fi
	if [ -z "$newbin" ] || [ ! -s "$newbin" ]; then
		vnt_ulog "archive does not contain $VNT_CORE"
		rm -f "$zip"
		rm -rf "$work"
		return 5
	fi
	chmod 755 "$newbin"

	# 校验：必须能在本机执行（架构不符会在此暴露，而不是留到运行时）。
	# vnt2_web 支持 -V/--version（clap 提供）。
	if ! "$newbin" --version >/dev/null 2>&1 && ! "$newbin" -V >/dev/null 2>&1; then
		vnt_ulog "ERROR: 下载的核心无法在本机运行（架构可能不符）：$(vnt_distrib_arch)"
		rm -f "$zip"
		rm -rf "$work"
		return 6
	fi

	vnt_replace_bin "$newbin" "$(vnt_bin_path)" || {
		vnt_ulog "replace binary failed"
		return 7
	}

	echo "$ver" >"$(vnt_ver_file)"
	{
		echo "version=$ver"
		echo "asset=$asset"
		echo "arch=$(vnt_distrib_arch)"
		echo "path=$(vnt_bin_path)"
		echo "installed_at=$(date '+%Y-%m-%d %H:%M:%S')"
	} >"$(vnt_src_file)"

	rm -f "$zip"
	rm -rf "$work"
	vnt_ulog "core ${ver} installed ok -> $(vnt_bin_path)"
	return 0
}

# 原子替换二进制，并保留备份（含版本号，以便回滚时一并恢复）
vnt_replace_bin() {
	local newbin="$1" dest="$2"
	[ -n "$dest" ] || return 1
	mkdir -p "$(dirname "$dest")" 2>/dev/null
	if [ -f "$dest" ]; then
		mkdir -p "$VNT_CACHE_DIR" 2>/dev/null
		cp -f "$dest" "$VNT_BACKUP" 2>/dev/null
		cp -f "$(vnt_ver_file)" "${VNT_BACKUP}.version" 2>/dev/null
	fi
	cp -f "$newbin" "${dest}.new" 2>/dev/null || return 1
	chmod 755 "${dest}.new"
	mv -f "${dest}.new" "$dest" || return 1
	return 0
}

vnt_rollback_core() {
	[ -f "$VNT_BACKUP" ] || return 1
	local dest
	dest="$(vnt_bin_path)"
	cp -f "$VNT_BACKUP" "$dest" || return 1
	chmod 755 "$dest"
	# 版本号也一并回滚，否则界面会显示「已是最新」但实际是旧版
	if [ -f "${VNT_BACKUP}.version" ]; then
		cp -f "${VNT_BACKUP}.version" "$(vnt_ver_file)" 2>/dev/null
	fi
	vnt_ulog "rolled back to previous core"
	return 0
}

# 解压 zip。vnt 官方发布的是 .zip，而 OpenWrt 默认既没有 unzip 也没有 python3，
# 纯 shell 无法解 deflate 数据流。因此把 unzip 作为包的依赖（见 Makefile DEPENDS），
# 同时保留 python3 优先 —— 部分玩家系统装了 python3，解包更快。
vnt_extract_zip() {
	local zip="$1" dest="$2"
	if vnt_have_cmd unzip; then
		unzip -oq "$zip" -d "$dest" >/dev/null 2>&1 && return 0
	fi
	if vnt_have_cmd python3; then
		python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
			"$zip" "$dest" >/dev/null 2>&1 && return 0
	fi
	if vnt_have_cmd bsdtar; then
		bsdtar -xf "$zip" -C "$dest" >/dev/null 2>&1 && return 0
	fi
	vnt_ulog "ERROR: 系统缺少 unzip，无法解压核心包。请执行: opkg update && opkg install unzip"
	return 1
}

# ---------------------------------------------------------------------------
# 配置是否完整到可以启动
#
# vnt2_web 版不再需要「组网编号 + 服务端地址」——那些在它自带的网页里配置，
# 由核心自己落盘到 work/vnt_config/。这里只需满足：
#   已安装核心 + 令牌合法（或可生成）
# ---------------------------------------------------------------------------
vnt_config_ready() {
	vnt_core_installed || return 1
	local t
	t="$(vnt_get_token)"
	# 没令牌也能启动（start 时会自动生成），但已有令牌就必须合法，
	# 否则 vnt2_web 会因长度不足拒绝启动。
	[ -z "$t" ] && return 0
	vnt_token_valid "$t"
}

# 配置文件目录（vnt2_web 自己在其中管理 vnt_config/）
vnt_config_dir() {
	printf '%s/vnt_config' "$(vnt_config_path)"
}

# 核心日志级别对应的环境变量（vnt2_web 用 RUST_LOG 控制日志）
vnt_log_level_env() {
	local lv
	lv="$(vnt_uci_get log_level 'info')"
	case "$lv" in
	error | warn | info | debug) echo "RUST_LOG=$lv" ;;
	*) echo "RUST_LOG=info" ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# 进程与状态
# ---------------------------------------------------------------------------
vnt_core_installed() {
	[ -x "$(vnt_bin_path)" ]
}

# 核心能否在本机执行（架构是否匹配）。结果按 size+mtime 缓存，避免每次调用都执行二进制。
vnt_core_runs() {
	local bin
	bin="$(vnt_bin_path)"
	[ -x "$bin" ] || return 1
	local sig cache
	sig="$(ls -l "$bin" 2>/dev/null | awk '{print $5"-"$6"-"$7"-"$8}')"
	cache="$VNT_CACHE_DIR/.core_runs"
	if [ -f "$cache" ]; then
		local old
		old="$(cat "$cache" 2>/dev/null)"
		if [ "$old" = "ok:$sig" ]; then
			return 0
		fi
		if [ "$old" = "bad:$sig" ]; then
			return 1
		fi
	fi
	if "$(vnt_bin_path)" --version >/dev/null 2>&1 || "$(vnt_bin_path)" -V >/dev/null 2>&1; then
		mkdir -p "$VNT_CACHE_DIR" 2>/dev/null
		printf 'ok:%s' "$sig" >"$cache" 2>/dev/null
		return 0
	fi
	mkdir -p "$VNT_CACHE_DIR" 2>/dev/null
	printf 'bad:%s' "$sig" >"$cache" 2>/dev/null
	return 1
}

# ---------------------------------------------------------------------------
# 进程存活检测
#
# 由 procd 托管，且 init 脚本已通过 `procd_set_param pidfile` 让 procd
# 在实例启动时写 PID、停止时删除（放 /tmp 下，不占 Flash）。
# 因此 PID 文件是权威来源；另加两路兜底：
#   1) PID 文件 + kill -0  —— 最直接
#   2) procd 的 ubus 实例状态 —— 最权威（能反映「procd 认为它在跑」）
#   3) 按实际二进制路径匹配进程 —— 兜底手工启动等异常场景
#
# 注意：不用「端口在监听」作为存活依据 —— 端口可能被其它程序占用，
# 会造成误报「运行中」。端口状态只作为独立的展示指标（见 vnt_port_listening）。
# ---------------------------------------------------------------------------
# 找出「可执行文件正是目标二进制」的进程 PID。
#
# 用 /proc/<pid>/exe 做判断 —— 它是该进程实际执行的镜像路径，最精确，
# 且完全不依赖 pgrep：既避开 busybox 各版本 pgrep 选项的差异
# （如旧版 `-x` 只比对 argv[0] 不比对 comm），也避开「命令行子串误匹配」。
#
# 为什么不能用 `pgrep -f vnt2web`（裸名字）：-f 是「整条命令行的子串匹配」，
# 而本检测自身就跑在 /usr/libexec/rpcd/vnt2web 里，命令行含 "vnt2web"，
# 会导致恒真 —— 「没启用却显示已启动」正是这么来的。
vnt_core_pids() {
	local bin exe pid
	bin="$(vnt_bin_path)"
	[ -n "$bin" ] || return 1
	for pid in /proc/[0-9]*; do
		pid="${pid#/proc/}"
		exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || continue
		[ "$exe" = "$bin" ] && printf '%s\n' "$pid"
	done
	return 0
}

vnt_core_running() {
	# 1) PID 文件（由 procd 写入，最直接）
	if [ -f "$VNT_PID_FILE" ]; then
		local pid
		pid="$(head -n 1 "$VNT_PID_FILE" 2>/dev/null | tr -d '[:space:]')"
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
	fi

	# 2) procd 实例状态（最权威）
	if vnt_procd_running; then
		return 0
	fi

	# 3) 按可执行文件精确匹配（兜底手工启动等场景）
	local p
	p="$(vnt_core_pids | head -n 1)"
	[ -n "$p" ] && return 0

	return 1
}

# 通过 ubus 查询 procd 的实例状态。不可用时静默返回非零。
vnt_procd_running() {
	vnt_have_cmd ubus || return 1
	# 期望形如 {"vnt2web":{"instances":{"instance1":{"running":true,...}}}}
	local out
	out="$(ubus call service list '{"name":"vnt2web"}' 2>/dev/null)" || return 1
	[ -n "$out" ] || return 1
	# 不用 jshn（可能未加载），直接做文本匹配：
	# 只要出现 "running": true 即视为在跑
	printf '%s' "$out" | grep -q '"running"[[:space:]]*:[[:space:]]*true' && return 0
	return 1
}

vnt_core_pid() {
	if [ -f "$VNT_PID_FILE" ]; then
		local pid
		pid="$(head -n 1 "$VNT_PID_FILE" 2>/dev/null | tr -d '[:space:]')"
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			printf '%s' "$pid"
			return 0
		fi
	fi
	# 从 procd 拿不到 PID 时，按可执行文件精确匹配（见 vnt_core_pids 说明）
	printf '%s' "$(vnt_core_pids | head -n 1)"
	return 0
}

# ---------------------------------------------------------------------------
# 清理残留的核心进程
#
# 为什么必须有这一步：vnt2_web 启动时会 bind 面板端口，若**已有一个残留实例**
# 占着该端口，新进程会因 bind 失败而**立即退出**——表现为「点了启用但起不来」，
# 而且因为残留进程的可执行路径可能与当前配置不同（如升级后 bin 路径变了），
# 状态检测也发现不了它，看起来就像「没进程却起不来」。
#
# 这里在启动前按「可执行文件路径」精确找出所有核心进程并终止，
# 再确认端口已释放，避免新进程撞上绑定的墙。
# ---------------------------------------------------------------------------
vnt_kill_stale_core() {
	local pids p
	pids="$(vnt_core_pids)"
	[ -n "$pids" ] || return 0

	vnt_log "start: 发现残留核心进程，正在清理: $(echo "$pids" | tr '\n' ' ')"
	# 先温和终止
	for p in $pids; do
		kill -TERM "$p" 2>/dev/null
	done
	# 给它一点时间优雅退出。
	# busybox 的 sleep 在部分版本只接受整数，且「cmd || cmd」不可靠
	# （收到非法参数也可能返回 0）。因此先探测一次小数支持情况。
	local nap=1
	if sleep 0.2 2>/dev/null; then
		nap=0.2
	fi
	local i=0
	while [ "$i" -lt 10 ]; do
		pids="$(vnt_core_pids)"
		[ -n "$pids" ] || break
		sleep "$nap"
		i=$((i + 1))
	done
	# 仍在则强杀
	pids="$(vnt_core_pids)"
	if [ -n "$pids" ]; then
		vnt_log "start: 残留进程未响应 TERM，改用 KILL"
		for p in $pids; do
			kill -KILL "$p" 2>/dev/null
		done
		sleep 1
	fi
	# 端口仍未释放（可能是别的程序占用），如实记日志便于排查
	if vnt_port_listening; then
		vnt_log "WARN: 端口 $(vnt_web_port) 仍被占用（可能不是本插件启动的进程）"
	fi
	return 0
}

# 取运行状态文本（vnt2_web 版仅按进程存活判断，组网状态由网页查看）
vnt_status_text() {
	if ! vnt_core_running; then
		echo "stopped"
		return 0
	fi
	echo "running"
	return 0
}

# 内核是否支持 tun（tun 模块或内核内置）
vnt_tun_available() {
	[ -e /dev/net/tun ] && return 0
	if vnt_have_cmd lsmod && lsmod 2>/dev/null | grep -q '^tun '; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# 点对网所需的转发开关与防火墙区域
#
# vnt2_web 自己会创建虚拟网卡（网卡模式在它网页里设置），
# 但网卡默认不在任何防火墙区域内，跨网段流量会被丢。
# 这里在启动后把「实际存在的 vnt 网卡」同步进指定 zone，
# 停止时再把本次添加的移除。
# ---------------------------------------------------------------------------
vnt_net_forwarding() {
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
	return 0
}

# 找出实际的 vnt 虚拟网卡名（vnt2_web 建的网卡通常叫 vnt2-tun 或 vnt-tun）
vnt_real_tun_name() {
	local n
	# 优先用 /sys/class/net 枚举，挑名字匹配 vnt* 的
	if [ -d /sys/class/net ]; then
		n="$(ls /sys/class/net 2>/dev/null | grep -E '^vnt' | head -n 1)"
		[ -n "$n" ] && {
			echo "$n"
			return 0
		}
	fi
	echo ""
	return 0
}

vnt_firewall_zone() {
	local z
	z="$(vnt_uci_get fw_zone 'lan')"
	[ -n "$z" ] || z="lan"
	echo "$z"
	return 0
}

# 把网卡加入 zone。$2 为空时表示清除本插件添加的记录
vnt_firewall_sync() {
	local zone dev recorded
	zone="$(vnt_firewall_zone)"
	vnt_have_uci || return 0
	uci -q get "firewall.$zone" >/dev/null 2>&1 || return 1

	recorded="$(cat "$VNT_FW_RECORD" 2>/dev/null)"
	dev="$1"

	if [ -z "$dev" ]; then
		# 清除：把上次记录的网卡从 zone 移除
		if [ -n "$recorded" ]; then
			uci -q del_list "firewall.$zone.device=$recorded" 2>/dev/null
			uci -q commit firewall
			/etc/init.d/firewall reload >/dev/null 2>&1
			rm -f "$VNT_FW_RECORD" 2>/dev/null
			vnt_log "firewall: 已把 $recorded 移出 zone $zone"
		fi
		return 0
	fi

	# 添加：若 zone 里已有该网卡，仍记录一下以便停止时清理
	local cur
	cur="$(uci -q get "firewall.$zone.device" 2>/dev/null)"
	if echo "$cur" | grep -qw "$dev"; then
		printf '%s' "$dev" >"$VNT_FW_RECORD" 2>/dev/null
		return 0
	fi
	if uci -q add_list "firewall.$zone.device=$dev"; then
		uci -q commit firewall
		/etc/init.d/firewall reload >/dev/null 2>&1
		printf '%s' "$dev" >"$VNT_FW_RECORD" 2>/dev/null
		vnt_log "firewall: 已把 $dev 加入 zone $zone"
	fi
	return 0
}

# 兼容旧调用点
vnt_firewall_add() { vnt_firewall_sync "$2"; }
vnt_firewall_remove() { vnt_firewall_sync ""; }
