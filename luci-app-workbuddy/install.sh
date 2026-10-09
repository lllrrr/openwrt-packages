#!/bin/sh
# luci-app-workbuddy 直接安装脚本（适用于无法本地打 apk 的 ImmortalWrt/OpenWrt 设备）
#
# 用法：
#   把整个包目录上传到路由器，或在包根目录执行：
#     sh install.sh            # 安装/升级
#     sh install.sh remove     # 卸载
#
# 本脚本按 files/ 目录结构部署文件，注册 procd 服务与 LuCI 菜单，
# 并在完成后重启 rpcd / uhttpd 使菜单与 ACL 生效。

set -e

PKG=luci-app-workbuddy
SRC=$(cd "$(dirname "$0")" && pwd)
FILES="$SRC/files"

die() { echo "错误: $*" >&2; exit 1; }
info() { echo "[$PKG] $*"; }

SYSCTL_CONF=/etc/sysctl.d/99-workbuddy-forward.conf

# 应用转发效率内核参数。
# 优先走内核自带的 sysctl 初始化脚本（ImmortalWrt 会读取 /etc/sysctl.d/*.conf）；
# 没有该脚本时退化为逐条 sysctl -w，保证在精简固件上也能生效。
apply_sysctl() {
	if [ -x /etc/init.d/sysctl ]; then
		/etc/init.d/sysctl restart >/dev/null 2>&1 || true
		return 0
	fi
	# shellcheck disable=SC2013
	for kv in $(grep '=' "$SYSCTL_CONF" 2>/dev/null | grep -v '^#'); do
		sysctl -w "$kv" >/dev/null 2>&1 || true
	done
}

# 还原本插件改过的四项（默认值来自出厂实测，见 conf 文件注释）
restore_sysctl() {
	sysctl -w net.ipv4.tcp_slow_start_after_idle=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_fastopen=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_mtu_probing=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_max_syn_backlog=128 >/dev/null 2>&1 || true
}


[ -d "$FILES" ] || die "找不到 files/ 目录，请在包根目录执行本脚本"

# ---------- 依赖检查 ----------
check_deps() {
	local missing=""
	for mod in fs uloop socket uci ubus; do
		[ -f "/usr/lib/ucode/$mod.so" ] || missing="$missing ucode-mod-$mod"
	done
	command -v ucode >/dev/null 2>&1 || missing="$missing ucode"
	command -v curl  >/dev/null 2>&1 || missing="$missing curl"

	if [ -n "$missing" ]; then
		info "缺少依赖:$missing"
		info "尝试自动安装..."
		if command -v apk >/dev/null 2>&1; then
			apk update >/dev/null 2>&1 || true
			# shellcheck disable=SC2086
			apk add $missing || die "依赖安装失败，请手动安装:$missing"
		elif command -v opkg >/dev/null 2>&1; then
			opkg update >/dev/null 2>&1 || true
			# shellcheck disable=SC2086
			opkg install $missing || die "依赖安装失败，请手动安装:$missing"
		else
			die "未找到 apk/opkg，无法自动安装依赖:$missing"
		fi
	fi
}

# ---------- 卸载 ----------
do_remove() {
	info "停止服务..."
	/etc/init.d/workbuddy stop 2>/dev/null || true
	/etc/init.d/workbuddy disable 2>/dev/null || true

	info "删除文件..."
	rm -f /etc/init.d/workbuddy
	rm -f /etc/uci-defaults/50-workbuddy
	rm -f /usr/share/rpcd/ucode/workbuddy
	rm -f /usr/libexec/rpcd/workbuddy
	rm -f /usr/share/luci/menu.d/luci-app-workbuddy.json
	rm -f /usr/share/rpcd/acl.d/luci-app-workbuddy.json
	rm -rf /www/luci-static/resources/view/workbuddy
	rm -f /usr/share/ucode/workbuddy.uc
	rm -f /usr/bin/workbuddy-pool

	info "还原转发效率内核参数..."
	rm -f "$SYSCTL_CONF"
	restore_sysctl

	info "保留 /etc/config/workbuddy 与 /etc/workbuddy/token.json（如需彻底清除请手动删除）"
	info "重启 rpcd 与 uhttpd..."
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/uhttpd restart 2>/dev/null || true
	info "卸载完成"
}

# ---------- 安装 ----------
do_install() {
	check_deps

	info "创建目录..."
	mkdir -p /usr/share/ucode
	mkdir -p /usr/share/rpcd/ucode
	mkdir -p /usr/share/luci/menu.d
	mkdir -p /usr/share/rpcd/acl.d
	mkdir -p /www/luci-static/resources/view/workbuddy
	mkdir -p /etc/workbuddy
	chmod 700 /etc/workbuddy

	info "部署核心服务..."
	cp -f "$FILES/usr/share/ucode/workbuddy.uc" /usr/share/ucode/workbuddy.uc || die "复制 workbuddy.uc 失败"
	chmod 644 /usr/share/ucode/workbuddy.uc

	# 上游连接池（可选组件）。
	# 缺失或架构不符都只告警、不中断安装：ucode 侧对池是静默降级的，
	# 没有池服务照样能用，只是每个请求多付一次 TCP+TLS 握手。
	if [ -f "$FILES/usr/bin/workbuddy-pool" ]; then
		info "部署上游连接池..."
		cp -f "$FILES/usr/bin/workbuddy-pool" /usr/bin/workbuddy-pool
		chmod 755 /usr/bin/workbuddy-pool
		# 架构不符时内核只会给出 "not found"（退出码 127），在这里先拦下来，
		# 免得等启动后才发现池一直起不来。
		POOL_RC=0
		/usr/bin/workbuddy-pool -version >/dev/null 2>&1 || POOL_RC=$?
		if [ "$POOL_RC" -eq 127 ]; then
			info "  警告：workbuddy-pool 无法在本机执行（架构不符？），将回退直连 curl"
		fi
	else
		info "  未找到 workbuddy-pool，跳过（将使用直连 curl）"
	fi

	info "部署 rpcd 后端..."
	cp -f "$FILES/usr/share/rpcd/ucode/workbuddy" /usr/share/rpcd/ucode/workbuddy || die "复制 rpcd 脚本失败"
	chmod 644 /usr/share/rpcd/ucode/workbuddy

	info "部署 LuCI 菜单与界面..."
	cp -f "$FILES/usr/share/luci/menu.d/luci-app-workbuddy.json" /usr/share/luci/menu.d/
	cp -f "$FILES/usr/share/rpcd/acl.d/luci-app-workbuddy.json" /usr/share/rpcd/acl.d/
	cp -f "$FILES/www/luci-static/resources/view/workbuddy/"*.js /www/luci-static/resources/view/workbuddy/

	info "部署配置与服务脚本..."
	if [ -f /etc/config/workbuddy ]; then
		info "  已存在 /etc/config/workbuddy，保留用户配置"
	else
		cp -f "$FILES/etc/config/workbuddy" /etc/config/workbuddy
	fi
	cp -f "$FILES/etc/init.d/workbuddy" /etc/init.d/workbuddy
	chmod 755 /etc/init.d/workbuddy
	cp -f "$FILES/etc/uci-defaults/50-workbuddy" /etc/uci-defaults/50-workbuddy
	chmod 755 /etc/uci-defaults/50-workbuddy

	info "部署转发效率内核参数..."
	mkdir -p /etc/sysctl.d
	cp -f "$FILES/etc/sysctl.d/99-workbuddy-forward.conf" "$SYSCTL_CONF" || die "复制 sysctl 配置失败"
	apply_sysctl

	info "执行 uci-defaults..."
	sh /etc/uci-defaults/50-workbuddy || true

	info "启用并启动服务..."
	/etc/init.d/workbuddy enable
	/etc/init.d/workbuddy restart

	sleep 2
	info "重启 rpcd 与 uhttpd 使菜单生效..."
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/uhttpd restart 2>/dev/null || true

	# 校验
	PORT=$(uci -q get workbuddy.main.port || echo 8789)
	sleep 1
	if netstat -ltn 2>/dev/null | grep -q ":$PORT "; then
		info "服务已监听 :$PORT"
		curl -sS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null | head -c 200
		echo ""

		# 连接池是可选件：没起来只提示，不影响判定安装成功
		USE_POOL=$(uci -q get workbuddy.main.use_pool || echo 1)
		POOL_PORT=$(uci -q get workbuddy.main.pool_port || echo 8790)
		if [ "$USE_POOL" = "1" ]; then
			if netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$POOL_PORT "; then
				info "连接池已监听 127.0.0.1:$POOL_PORT"
			else
				info "提示：连接池未监听 :$POOL_PORT（将以直连方式工作），可查 logread | grep workbuddy"
			fi
		fi

		info "安装成功"
	else
		info "警告：:$PORT 未监听，请查看日志：logread | grep workbuddy"
		exit 1
	fi
}

case "$1" in
	remove|uninstall)
		do_remove
		;;
	""|install)
		do_install
		;;
	*)
		echo "用法: sh install.sh [install|remove]"
		exit 1
		;;
esac
