'use strict';

// 版本号的唯一来源：CLI 与 rpcd 都从这里取，避免两处常量各写各的
// （已踩过：改 rpcd 时漏了 CLI，`rtfwupgrade.sh version` 报 0.1.0 而 ubus 报 0.1.0_alpha1）。
// 与 Makefile 的 PKG_VERSION 必须一致，由 tests/version-check.mjs 保证。
return { VERSION: '0.2.1_alpha1' };
