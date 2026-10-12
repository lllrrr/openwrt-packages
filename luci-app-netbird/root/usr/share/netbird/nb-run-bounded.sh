# SPDX-License-Identifier: Apache-2.0
#
# nb_run_bounded <秒数> <命令> [参数...] —— 带墙钟上限执行命令:超时返回 124,否则透传退出码。
# 供自动重连 watchdog 与 netbird-settings 以 `.` 引入共用,语义与后端 shell.uc 的 with_timeout 一致。
# timeout 能实际执行时直接用;官方 OpenWrt 的 BusyBox 默认不带 timeout applet,此时后台执行命令,
# 由计时子进程到点 kill -9:
#   - `( exec 命令 )` 使记录的 PID 就是命令本身;输出先落临时文件、结束后回放,被强杀命令残留的
#     子进程只握着临时文件,不会让命令替换 $(...) 一直等管道关闭;
#   - 计时子进程 stdio 全部断开,否则命令替换 $(...) 要等它退出;
#   - 命令先结束时收掉计时子进程及其 sleep(trap 用 $!,sleep 一启动就有值),不残留进程;
#   - wait 可被信号打断,调用方的 TERM trap 不会被拖到命令结束。

nb_run_bounded() {
	_nb_secs="$1"
	shift
	if [ -z "${_NB_HAS_TIMEOUT:-}" ]; then
		if timeout 1 true >/dev/null 2>&1; then
			_NB_HAS_TIMEOUT=1
		else
			_NB_HAS_TIMEOUT=0
		fi
	fi
	if [ "$_NB_HAS_TIMEOUT" = 1 ]; then
		timeout "$_nb_secs" "$@"
		return $?
	fi
	_nb_out=$(mktemp /tmp/nb-run.XXXXXX) || return 125
	( exec "$@" ) >"$_nb_out" 2>"$_nb_out.e" &
	_nb_pid=$!
	(
		trap 'kill $! 2>/dev/null; exit 0' TERM
		sleep "$_nb_secs" &
		wait $! && kill -9 "$_nb_pid" 2>/dev/null
	) </dev/null >/dev/null 2>&1 &
	_nb_timer=$!
	wait "$_nb_pid" 2>/dev/null
	_nb_rc=$?
	kill "$_nb_timer" 2>/dev/null
	cat "$_nb_out"
	cat "$_nb_out.e" >&2
	rm -f "$_nb_out" "$_nb_out.e"
	[ "$_nb_rc" -eq 137 ] && _nb_rc=124
	return "$_nb_rc"
}
