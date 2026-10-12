// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Tailscale Inc & AUTHORS  (attribution retained; see NOTICE)
// Modified from luci-app-tailscale-community@eabe1288afe024566b930b26681a722ccf07b19b
// 函数体整段复制自上游 commit 301f02e
//
// Canonical runtime path:    /usr/share/rpcd/ucode/lib/shell.uc
// Repo canonical source:     root/usr/share/rpcd/ucode/lib/shell.uc
//
// shell_quote(s) — POSIX sh safe single-quote wrapping
// 不变量：printf '%s\n' shell_quote(x) 的输出等于 x
// 内部 ' 通过 '\'' 序列转义（关闭当前单引号段 → 字面 ' → 开启新单引号段）
//
// module-compat：本文件作为 ucode 模块经 loadfile()() 加载，返回 { shell_quote, with_timeout }。
// ucode 2025.07.18 不支持 export 关键字，只接受顶层 return 模式；
// 同时去掉 shebang 与 'use strict'（loadfile 模式不需要）。

function shell_quote(s) {
    if (s == null || s == '') return "''";
    return "'" + replace(s, "'", "'\\''") + "'";
}

// 可执行链接可能指向未编译该 applet 的 BusyBox，必须实际运行才能确认能力。
// 使用纯数字秒，兼容不接受时间后缀的 timeout 实现；加载时探测一次。
const _HAS_TIMEOUT = system('timeout 1 true >/dev/null 2>&1') == 0;

// with_timeout(cmd, secs?) → 带墙钟上限（缺省 5 秒）的命令串；超时退出码为 124。
// cmd 必须是单条简单命令（可带重定向），且返回值整体交给 popen/system 执行、不再拼接。
// 官方 OpenWrt 的 BusyBox 默认不带 timeout applet，此时改为后台执行 + 计时子进程强杀：
//   - `( exec cmd )` 使记录的 PID 就是命令本身；输出先落临时文件、结束后再回放，被强杀命令
//     残留的子进程（如 init 脚本派生的进程）只握着临时文件，不会让 popen 读端一直等管道关闭；
//   - 计时子进程 stdio 全部断开；命令先结束时连同计时子进程里的 sleep 一起收掉（trap 用 $!，
//     sleep 一启动就有值，避免信号落在启动与赋值之间时漏杀），热路径不残留进程、不增加等待；
//   - kill -9 的 137 归为 124，与 timeout 语义一致。
function with_timeout(cmd, secs) {
    secs = (type(secs) == 'int' && secs > 0) ? secs : 5;
    if (_HAS_TIMEOUT)
        return 'timeout ' + secs + ' ' + cmd;
    return '__nbf=$(mktemp /tmp/nb-run.XXXXXX) || exit 125; ' +
        '( exec ' + cmd + ' ) >"$__nbf" 2>"$__nbf.e" & __nbp=$!; ' +
        '( trap \'kill $! 2>/dev/null; exit 0\' TERM; sleep ' + secs + ' & ' +
        'wait $! && kill -9 $__nbp 2>/dev/null ) </dev/null >/dev/null 2>&1 & __nbw=$!; ' +
        'wait $__nbp 2>/dev/null; __nbrc=$?; kill $__nbw 2>/dev/null; ' +
        'cat "$__nbf"; cat "$__nbf.e" >&2; rm -f "$__nbf" "$__nbf.e"; ' +
        '[ $__nbrc -eq 137 ] && __nbrc=124; exit $__nbrc';
}

return { shell_quote, with_timeout };
