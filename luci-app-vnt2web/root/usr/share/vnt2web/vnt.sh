#!/bin/sh
# vnt 公共函数库（基础层）：路径、日志、架构映射、HTTP 客户端、版本查询、镜像与代理。
# 被 /etc/init.d/vnt2web、LuCI rpcd 后端与更新脚本 source。
#
# 目标是 POSIX sh（OpenWrt 的 /bin/sh 是 busybox ash），故不使用数组与 bash 专有语法。

VNT_REPO="vnt-dev/vnt"
VNT_API="https://api.github.com/repos/${VNT_REPO}/releases/latest"
VNT_DL="https://github.com/${VNT_REPO}/releases/download"

# ---------------------------------------------------------------------------
# 路径
#
# 三类数据的落点策略：
#   bin     核心二进制  —— 可配置，默认 /usr/bin/vnt2web
#   config  组网配置    —— 可配置，默认 /etc/vnt2web/config
#   log     运行日志    —— 固定 /tmp/vnt2web，不持久化
#
# 设计说明：默认值刻意把 bin 放在 /usr 下（跟随系统），config 放在 /etc 下
# （OpenWrt 升级固件时 sysupgrade 只保留 /etc，配置得以延续）。
# 若把 bin 也指定到 /etc 下，则升级固件后核心仍在，可省去重新下载。
# 两个路径都可在 LuCI 的「存储路径」里改。
# ---------------------------------------------------------------------------

# 根目录：仅用于存放令牌等少量状态
VNT_ETC="${VNT_ETC:-/etc/vnt2web}"

# 日志固定放 /tmp —— 内存盘，重启即清，不占用 Flash。
# 这是 OpenWrt 上日志的常规做法：日志写多了会磨损 Flash。
VNT_LOG_DIR="${VNT_LOG_DIR:-/tmp/vnt2web}"

# 运行期缓存（下载中间文件、回滚备份、探测缓存）
VNT_CACHE_DIR="${VNT_CACHE_DIR:-/tmp/vnt2web/run}"

# 核心程序名（vnt2_web 自带网页界面，同时含组网客户端与网页服务）
VNT_CORE="vnt2_web"

# --- 可配置路径：默认值（UCI 中可覆盖）---
VNT_BIN_DEFAULT="/usr/bin/vnt2web"
VNT_CFG_DEFAULT="/etc/vnt2web/config"

# 核心二进制路径。UCI 未指定时用默认值。
vnt_bin_path() {
	local p
	p="$(vnt_uci_get bin_path '')"
	[ -n "$p" ] || p="$VNT_BIN_DEFAULT"
	printf '%s' "$p"
	return 0
}

# 配置目录。UCI 未指定时用默认值。
vnt_config_path() {
	local p
	p="$(vnt_uci_get config_dir '')"
	[ -n "$p" ] || p="$VNT_CFG_DEFAULT"
	printf '%s' "$p"
	return 0
}

# 版本与来源标记：放在 /etc 下（与令牌同处），不跟随 bin —— 避免往
# /usr/bin 这种系统目录里塞非二进制文件，也保证换 bin 路径时状态不丢失。
vnt_ver_file() { printf '%s/.core_version' "$VNT_ETC"; }
vnt_src_file() { printf '%s/.core_source' "$VNT_ETC"; }

# 令牌文件：放 /etc 下，保证升级固件后访问令牌不变
vnt_token_file() { printf '%s/token' "$VNT_ETC"; }

# 备份（回滚用）：放 tmpfs，重启即清，避免占 Flash
VNT_BACKUP="$VNT_CACHE_DIR/${VNT_CORE}.bak"
VNT_PID_FILE="${VNT_PID_FILE:-/tmp/vnt2web/vnt2web.pid}"
# 记录本插件加入防火墙区域的网卡名，便于停止时精确移除
VNT_FW_RECORD="$VNT_ETC/.fw_device"

VNT_MAIN_LOG="$VNT_LOG_DIR/main.log"
VNT_UPDATE_LOG="$VNT_LOG_DIR/update.log"
VNT_CORE_LOG="$VNT_LOG_DIR/core.log"

# 日志上限：超过则原地截断，保留尾部。
# 用原地截断而非改名轮转：core.log 由 vnt 进程以追加方式持有 fd，
# 改名会让它继续写旧 inode，轮转等于失效；O_APPEND 下原地截断是安全的。
VNT_LOG_MAX_BYTES="${VNT_LOG_MAX_BYTES:-262144}"   # 256 KB
VNT_LOG_KEEP_BYTES="${VNT_LOG_KEEP_BYTES:-131072}" # 128 KB
# OpenWrt 普遍用 tmpfs 存 /var/log，空间紧张，上限取小一些。

vnt_ensure_dirs() {
	# 二进制所在目录（可能被指定到任意位置）
	local bd
	bd="$(dirname "$(vnt_bin_path)")"
	# 配置目录（vnt2_web 会在其中建 vnt_config/）
	local cd
	cd="$(vnt_config_path)"
	mkdir -p "$bd" "$cd" "$VNT_LOG_DIR" "$VNT_CACHE_DIR" "$VNT_ETC" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
vnt_trim_log() {
	local f="$1" size tmp
	[ -f "$f" ] || return 0
	size="$(wc -c <"$f" 2>/dev/null | tr -d ' ')" || return 0
	[ -n "$size" ] || return 0
	[ "$size" -gt "$VNT_LOG_MAX_BYTES" ] 2>/dev/null || return 0
	tmp="${f}.trim"
	{
		printf '[log trimmed: 仅保留最近 %d KB]\n' "$((VNT_LOG_KEEP_BYTES / 1024))"
		tail -c "$VNT_LOG_KEEP_BYTES" "$f" 2>/dev/null | tail -n +2
	} >"$tmp" 2>/dev/null || {
		rm -f "$tmp"
		return 0
	}
	cat "$tmp" >"$f" 2>/dev/null
	rm -f "$tmp"
	return 0
}

_vnt_log() {
	local f="$1"
	shift
	mkdir -p "$(dirname "$f")" 2>/dev/null
	vnt_trim_log "$f"
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$f"
	return 0
}

vnt_log() { _vnt_log "$VNT_MAIN_LOG" "$@"; }
vnt_ulog() { _vnt_log "$VNT_UPDATE_LOG" "$@"; }
vnt_clog() { _vnt_log "$VNT_CORE_LOG" "$@"; }

# ---------------------------------------------------------------------------
# UCI 读取：优先用 uci，退化到解析 /etc/config/vnt2web
# 用 command -v 探测而非硬编码 /sbin/uci —— 后者在测试环境与
# 部分精简固件里不成立。
# ---------------------------------------------------------------------------
vnt_have_uci() {
	command -v uci >/dev/null 2>&1
}

vnt_uci_get() {
	# vnt_uci_get <option> [default]
	local opt="$1" def="${2:-}"
	if vnt_have_uci; then
		local v
		v="$(uci -q get "vnt2web.main.$opt" 2>/dev/null)"
		if [ -n "$v" ]; then
			echo "$v"
			return 0
		fi
	fi
	echo "$def"
	return 0
}

# 读取列表型选项（UCI list），每行一项
vnt_uci_list() {
	local opt="$1"
	if vnt_have_uci; then
		uci -q get "vnt2web.main.$opt" 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
	fi
	return 0
}

# ---------------------------------------------------------------------------
# 架构映射：OpenWrt DISTRIB_ARCH -> vnt release 目标三元组
# vnt 官方发布的三元组见 README；映射错误的后果是「下载到架构不符的二进制」，
# 故这里做得尽量细，无法确定时明确返回失败而不是猜。
# ---------------------------------------------------------------------------
vnt_distrib_arch() {
	local a="${1:-}"
	if [ -z "$a" ] && [ -r /etc/openwrt_release ]; then
		a="$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_ARCH")"
	fi
	echo "$a"
}

vnt_asset_triple() {
	local arch="${1:-$(vnt_distrib_arch)}"
	case "$arch" in
	# ---- 64 位 x86 / ARM ----
	x86_64 | amd64) echo "x86_64-unknown-linux-musl" ;;
	aarch64_generic | aarch64_cortex-a53 | aarch64_cortex-a72 | aarch64_cortex-a76 | aarch64_*)
		echo "aarch64-unknown-linux-musl" ;;
	# ---- 32 位 ARM ----
	# 有硬件浮点（neon / vfpv3 / vfpv4）走 hard-float
	arm_cortex-a7_neon-vfpv4 | arm_cortex-a9_vfpv3-d16 | arm_cortex-a15_neon-vfpv4 | arm_cortex-a9)
		echo "armv7-unknown-linux-musleabihf" ;;
	# 纯 cortex-a7 不保证 vfp，走 soft-float
	arm_cortex-a7 | arm_cortex-a5)
		echo "armv7-unknown-linux-musleabi" ;;
	# ARMv6（树莓派 1 / Zero）带 VFP
	arm_arm1176jzf-s_vfp) echo "arm-unknown-linux-musleabihf" ;;
	# ARMv5 等无浮点
	arm_arm926ej-s | arm_xscale) echo "arm-unknown-linux-musleabi" ;;
	# ---- MIPS ----
	mips_24kc | mips_mips32 | mips_74k | mips_*) echo "mips-unknown-linux-musl" ;;
	mipsel_24kc | mipsel_24kc_24kf | mipsel_mips32 | mipsel_74kc | mipsel_*) echo "mipsel-unknown-linux-musl" ;;
	# ---- 明确不支持 ----
	i386_* | i486) return 1 ;;
	*) return 1 ;;
	esac
	return 0
}

vnt_asset_name() {
	local triple
	triple="$(vnt_asset_triple "${1:-}")" || return 1
	echo "vnt2-${triple}"
	return 0
}

# ---------------------------------------------------------------------------
# HTTP 客户端：按能力选，不硬编码。
#   curl           —— 唯一支持 --proxy 的，配了代理就必须用它
#   uclient-fetch  —— OpenWrt 内置，最省事，但不支持代理
#   wget           —— wget-ssl（busybox wget 不支持 https，需排除）
# ---------------------------------------------------------------------------
vnt_have_cmd() { command -v "$1" >/dev/null 2>&1; }

vnt_have_curl() { vnt_have_cmd curl; }

# 可用的 HTTP 客户端名；都没有则返回空
vnt_http_client() {
	if vnt_have_curl; then
		echo curl
		return 0
	fi
	if vnt_have_cmd uclient-fetch; then
		echo uclient-fetch
		return 0
	fi
	if vnt_have_cmd wget; then
		# busybox wget 不支持 https，仅在非 busybox 时采用
		if [ "$(readlink -f "$(command -v wget)" 2>/dev/null)" != "/bin/busybox" ]; then
			echo wget
			return 0
		fi
	fi
	return 1
}

# 代理配置（网络层）。与镜像前缀（URL 层）相互独立。
vnt_get_proxy() {
	local p
	p="$(vnt_uci_get proxy '')"
	printf '%s' "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
	return 0
}

# 镜像前缀：把 GitHub 地址改写到镜像站
vnt_get_mirror() {
	local m
	m="$(vnt_uci_get mirror '')"
	printf '%s' "$m" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s:/*$::'
	return 0
}

vnt_url() {
	local prefix
	prefix="$(vnt_get_mirror)"
	if [ -n "$prefix" ]; then
		echo "${prefix}/$1"
	else
		echo "$1"
	fi
	return 0
}

# 统一下载入口，自动附加代理与 TLS 跳过。
# 用法：vnt_fetch <url> <输出文件> [超时秒]
vnt_fetch() {
	local url="$1" out="$2" tmo="${3:-600}"
	local cli proxy
	cli="$(vnt_http_client)" || {
		vnt_log "ERROR: 系统没有可用的 HTTP 客户端（curl / uclient-fetch / wget），无法下载"
		return 127
	}
	proxy="$(vnt_get_proxy)"

	if [ -n "$proxy" ] && [ "$cli" != "curl" ]; then
		vnt_log "ERROR: 已配置网络代理但系统没有 curl，无法走代理下载。请先安装 curl。"
		return 127
	fi

	case "$cli" in
	curl)
		if [ -n "$proxy" ]; then
			curl -fsSL --max-time "$tmo" --retry 3 --retry-delay 2 \
				--proxy "$proxy" --insecure -o "$out" "$url"
		else
			curl -fsSL --max-time "$tmo" --retry 3 --retry-delay 2 \
				--insecure -o "$out" "$url"
		fi
		return $?
		;;
	uclient-fetch)
		uclient-fetch -q -T "$tmo" --no-check-certificate -O "$out" "$url"
		return $?
		;;
	wget)
		wget -q -T "$tmo" --no-check-certificate -O "$out" "$url"
		return $?
		;;
	esac
	return 1
}

# 仅取文本响应体到 stdout（用于版本查询）
vnt_get_text() {
	local url="$1" tmo="${2:-20}" tmp
	tmp="$(mktemp 2>/dev/null || echo "/tmp/.vnt.$$")"
	if vnt_fetch "$url" "$tmp" "$tmo" >/dev/null 2>&1 && [ -s "$tmp" ]; then
		cat "$tmp"
	fi
	rm -f "$tmp"
	return 0
}

# ---------------------------------------------------------------------------
# 版本号解析：严格只接受 数字.数字[.数字[.数字]]（2-4 段）
# 早期实现按 / 取末段，遇到镜像把整段 URL 编码时会得到 https%3A%2F%2F...，
# 拼出错误下载地址导致 404。
#
# 现改用「提取」而非「切分」：从任意串里抓出第一个形如 2.0.11 的片段。
# 两步走，优先带 v 前缀的（更可能是版本号本身）：
#   1) v2.0.11 / -v2.0.11 / tag/v2.0.11
#   2) 兜底 2.0.11
# 不走 URL 解码：%2F %3A 解码与否都不影响数字点号串的提取，
# 只有被编码的点（%2E）需要单独还原。
# ---------------------------------------------------------------------------
vnt_normalize_version() {
	local raw="$1" v
	[ -n "$raw" ] || return 1
	# 还原被编码的点号，去掉引号/反引号/空白
	raw="$(printf '%s' "$raw" | sed 's/%2[Ee]/./g' | tr -d '`"'"'"' \r\n')"
	[ -n "$raw" ] || return 1

	# 优先：带 v 前缀的版本号
	v="$(printf '%s' "$raw" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+){0,2}' 2>/dev/null | head -n 1 | sed 's/^v//')"
	[ -n "$v" ] && {
		echo "$v"
		return 0
	}

	# 兜底：任意位置的 数字.数字[.数字[.数字]]
	v="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+){0,2}' 2>/dev/null | head -n 1)"
	[ -n "$v" ] || return 1
	echo "$v"
	return 0
}

# 查询最新版本号。三重来源，可靠性递减：
#   1) latest.json —— vnt 官方随 release 发布，最可靠且镜像可代理
#   2) releases/latest 的 302 重定向
#   3) GitHub API
vnt_latest_version() {
	local body v

	body="$(vnt_get_text "$(vnt_url "https://github.com/${VNT_REPO}/releases/latest/download/latest.json")" 20)"
	if [ -n "$body" ]; then
		v="$(printf '%s' "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
		v="$(vnt_normalize_version "$v")" && [ -n "$v" ] && {
			echo "$v"
			return 0
		}
	fi

	# 回退 1：解析 releases/latest 的 302 重定向地址（需要 curl 的 -w 能力）
	if vnt_have_curl; then
		local eff proxy
		eff=""
		proxy="$(vnt_get_proxy)"
		if [ -n "$proxy" ]; then
			eff="$(curl -sSI --max-time 20 -o /dev/null -w '%{url_effective}' \
				--proxy "$proxy" --insecure \
				"$(vnt_url "https://github.com/${VNT_REPO}/releases/latest")" 2>/dev/null)"
		else
			eff="$(curl -sSI --max-time 20 -o /dev/null -w '%{url_effective}' \
				--insecure \
				"$(vnt_url "https://github.com/${VNT_REPO}/releases/latest")" 2>/dev/null)"
		fi
		if [ -n "$eff" ]; then
			v="$(vnt_normalize_version "${eff##*/}")" && [ -n "$v" ] && {
				echo "$v"
				return 0
			}
		fi
	fi

	# 回退 2：GitHub API
	body="$(vnt_get_text "$(vnt_url "$VNT_API")" 20)"
	if [ -n "$body" ]; then
		v="$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
		v="$(vnt_normalize_version "$v")" && [ -n "$v" ] && {
			echo "$v"
			return 0
		}
	fi

	return 1
}

vnt_installed_version() {
	local vf
	vf="$(vnt_ver_file)"
	if [ -f "$vf" ]; then
		head -n 1 "$vf" | tr -d '\r\n'
	fi
	return 0
}

# ---------------------------------------------------------------------------
# 版本比较：vnt_ver_cmp A B -> 输出 -1 / 0 / 1
# ---------------------------------------------------------------------------
vnt_ver_cmp() {
	local a="$1" b="$2"
	[ "$a" = "$b" ] && {
		echo 0
		return 0
	}
	local i=1 x y
	while [ "$i" -le 4 ]; do
		x="$(echo "$a" | cut -d. -f$i)"
		y="$(echo "$b" | cut -d. -f$i)"
		[ -n "$x" ] || x=0
		[ -n "$y" ] || y=0
		if [ "$x" -gt "$y" ] 2>/dev/null; then
			echo 1
			return 0
		fi
		if [ "$x" -lt "$y" ] 2>/dev/null; then
			echo -1
			return 0
		fi
		i=$((i + 1))
	done
	echo 0
	return 0
}

# ---------------------------------------------------------------------------
# 访问令牌
# vnt2_web 要求令牌至少 16 位（源码校验：len() < 16 直接拒绝启动）。
# 默认生成的令牌是 24 字节 -> 48 位十六进制。
# ---------------------------------------------------------------------------
VNT_TOKEN_MIN=16

# 读取当前令牌。
# UCI 优先：界面上设置的令牌要立即生效。此前是「文件优先」，导致在界面里
# 改了令牌却不生效（安装时生成的文件一直盖着），这是个静默的坑。
vnt_get_token() {
	local t
	t="$(vnt_uci_get token '')"
	if [ -z "$t" ] && [ -f "$(vnt_token_file)" ]; then
		t="$(head -n 1 "$(vnt_token_file)" 2>/dev/null | tr -d '\r\n')"
	fi
	printf '%s' "$t"
	return 0
}

# 令牌是否合法（>= VNT_TOKEN_MIN 位，且不含空白）
vnt_token_valid() {
	local t="$1"
	[ -n "$t" ] || return 1
	[ "${#t}" -ge "$VNT_TOKEN_MIN" ] || return 1
	case "$t" in
	*" "*) return 1 ;;
	esac
	return 0
}

# 保存令牌：写文件（0600）并同步到 UCI，保证界面显示与实际一致
vnt_save_token() {
	local t="$1"
	# 目录可能尚未创建（例如首次安装、或 /etc 被清后），先确保存在
	mkdir -p "$VNT_ETC" 2>/dev/null
	printf '%s' "$t" >"$(vnt_token_file)"
	chmod 600 "$(vnt_token_file)" 2>/dev/null
	if vnt_have_uci; then
		uci -q set "vnt2web.main.token=$t" && uci -q commit vnt2web
	fi
	return 0
}

# 生成随机令牌并保存，输出令牌
vnt_gen_token() {
	local t=""
	# 优先 openssl（若固件带了），否则 /dev/urandom，再退到时间戳
	if vnt_have_cmd openssl; then
		t="$(openssl rand -hex 24 2>/dev/null)"
	fi
	if [ -z "$t" ] && [ -r /dev/urandom ]; then
		t="$(head -c 24 /dev/urandom | od -An -tx1 2>/dev/null | tr -d ' \n')"
	fi
	if [ -z "$t" ]; then
		t="$(date +%s 2>/dev/null)${RANDOM}${RANDOM}${RANDOM}${RANDOM}"
	fi
	# 保证长度足够
	while [ "${#t}" -lt "$VNT_TOKEN_MIN" ]; do
		t="${t}${RANDOM}"
	done
	vnt_save_token "$t"
	printf '%s' "$t"
	return 0
}

# 用于日志/界面的脱敏提示
vnt_token_hint() {
	local t
	t="$(vnt_get_token)"
	if [ -z "$t" ]; then
		echo "未设置"
	elif vnt_token_valid "$t"; then
		echo "已设置(${#t}位)"
	else
		echo "过短(需≥${VNT_TOKEN_MIN}位)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# 监听地址 / 面板地址
# ---------------------------------------------------------------------------
vnt_web_bind() {
	# 监听地址固定为全部网卡：局域网内其它设备也能直接打开组网面板。
	# 不再提供配置项——对绝大多数家庭/办公场景这是想要的行为，
	# 而限制为 127.0.0.1 的场景可由防火墙规则实现，比改应用配置更合适。
	printf '0.0.0.0'
	return 0
}

vnt_web_port() {
	local p
	p="$(vnt_uci_get port '19099')"
	case "$p" in
	'' | *[!0-9]*) p=19099 ;;
	esac
	[ "$p" -ge 1 ] && [ "$p" -le 65535 ] || p=19099
	printf '%s' "$p"
	return 0
}

# procd 传参用的 bind:port
vnt_web_addr() { printf '%s:%s' "$(vnt_web_bind)" "$(vnt_web_port)"; }

# 本机可用的访问主机名：
#   监听 0.0.0.0 时用第一个非回环 IPv4，否则用监听地址本身
vnt_web_host() {
	local b
	b="$(vnt_web_bind)"
	case "$b" in
	0.0.0.0 | ::)
		ip -4 addr show 2>/dev/null \
			| sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' \
			| grep -v '^127\.' | head -n 1
		;;
	*) printf '%s' "$b" ;;
	esac
	return 0
}

# 面板地址（不带令牌，用于界面展示）
vnt_panel_url_bare() {
	local host
	host="$(vnt_web_host)"
	[ -n "$host" ] || host="127.0.0.1"
	printf 'http://%s:%s/' "$host" "$(vnt_web_port)"
	return 0
}

# 面板地址（带令牌，可直接免登录打开）
# vnt2_web 前端会读取 ?token= 存入 localStorage 并自动清理地址栏，
# 因此这是官方支持的免登录入口。
vnt_panel_url() {
	local t host
	t="$(vnt_get_token)"
	host="$(vnt_web_host)"
	[ -n "$host" ] || host="127.0.0.1"
	if [ -n "$t" ]; then
		printf 'http://%s:%s/?token=%s' "$host" "$(vnt_web_port)" "$t"
	else
		printf 'http://%s:%s/' "$host" "$(vnt_web_port)"
	fi
	return 0
}

# 端口是否在监听
vnt_port_listening() {
	local port hex
	port="$(vnt_web_port)"
	[ -n "$port" ] || return 1
	if vnt_have_cmd ss; then
		ss -tln 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 0
	fi
	if vnt_have_cmd netstat; then
		netstat -tln 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 0
	fi
	# 兜底：直接读 /proc/net/tcp（无需任何工具，OpenWrt 上一定存在）。
	# 该文件的本地地址是「十六进制 IP:端口」，端口为 4 位大写十六进制。
	hex="$(printf '%04X' "$port" 2>/dev/null)"
	if [ -n "$hex" ] && [ -r /proc/net/tcp ]; then
		# 状态 0A = LISTEN
		awk -v p=":$hex" 'NR>1 && $4=="0A" && index($2, p) {found=1; exit} END{exit !found}' \
			/proc/net/tcp 2>/dev/null && return 0
	fi
	return 1
}

