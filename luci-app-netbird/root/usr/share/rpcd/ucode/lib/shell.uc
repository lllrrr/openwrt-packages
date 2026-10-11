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

function with_timeout(cmd) {
    return _HAS_TIMEOUT ? ('timeout 5 ' + cmd) : cmd;
}

return { shell_quote, with_timeout };
