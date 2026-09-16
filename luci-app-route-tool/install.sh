#!/bin/sh
set -u
BASE="$(cd "$(dirname "$0")" && pwd)"
cp -a "$BASE/files/"* /
chmod 755 /usr/libexec/route-tool
# New shared helpers are sourced by executable scripts; keep all shipped helpers readable/executable after manual install.
chmod 755 /usr/libexec/route-tool.d/*.sh 2>/dev/null || true
rm -rf /tmp/luci-* 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
echo "route-tool 已安装。菜单：系统 / Route Tool"
