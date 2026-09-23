#!/bin/sh
# Clean uninstaller for legacy istore-ups / ups-manager
set -e

echo "=== [1/4] 正在停止并注销现有服务 ==="
/etc/init.d/istore-ups stop 2>/dev/null || true
/etc/init.d/istore-ups disable 2>/dev/null || true
/etc/init.d/ups-manager stop 2>/dev/null || true
/etc/init.d/ups-manager disable 2>/dev/null || true

# Kill any running daemon
pkill -f istore-ups 2>/dev/null || true
pkill -f ups-manager 2>/dev/null || true

echo "=== [2/4] 正在清理旧版文件与视图 ==="
rm -f /etc/init.d/istore-ups /etc/init.d/ups-manager
rm -f /usr/bin/istore-ups-* /usr/bin/ups-manager-*
rm -f /usr/libexec/rpcd/luci.istore-ups /usr/libexec/rpcd/luci.ups-manager
rm -f /etc/uci-defaults/80_istore_ups /etc/uci-defaults/80_ups_manager
rm -f /usr/share/luci/menu.d/luci-app-istore-ups.json /usr/share/luci/menu.d/luci-app-ups-manager.json
rm -f /usr/share/rpcd/acl.d/luci-app-istore-ups.json /usr/share/rpcd/acl.d/luci-app-ups-manager.json
rm -rf /www/luci-static/resources/view/istore-ups /www/luci-static/resources/view/ups-manager
rm -rf /tmp/run/istore-ups* /tmp/log/istore-ups* /tmp/run/ups-manager* /tmp/log/ups-manager*
rm -rf /tmp/istore-ups-install /tmp/ups-manager-install

echo "=== [3/4] 正在重启 RPC 守护进程 ==="
/etc/init.d/rpcd restart 2>/dev/null || true

echo "=== [4/4] 正在彻底刷新 LuCI 缓存 ==="
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/

echo ""
echo "============================================================"
echo "  旧版 istore-ups 已彻底卸载并清理干净！"
echo "============================================================"
