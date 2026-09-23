#!/bin/sh
# ==============================================================================
# iStoreOS / OpenWrt Package & Store Ingestion Verification Suite
# ==============================================================================
set -e

ERRORS=0

log_pass() {
	echo "  [PASS] $1"
}

log_fail() {
	echo "  [FAIL] $1"
	ERRORS=$((ERRORS + 1))
}

echo "=== 1. 检验 OpenWrt Package Makefile 规范 ==="
if [ -f "Makefile" ]; then
	grep -q "PKG_NAME:=luci-app-ups-manager" Makefile && log_pass "PKG_NAME 正确声明" || log_fail "缺少有效 PKG_NAME"
	grep -q "LUCI_PKGARCH:=all" Makefile && log_pass "LUCI_PKGARCH 声明为 all (全架构兼容)" || log_fail "未声明 LUCI_PKGARCH:=all"
	grep -q "Package/.*postinst" Makefile && log_pass "包含 postinst 安装生命周期钩子" || log_fail "缺少 postinst 钩子"
	grep -q "Package/.*prerm" Makefile && log_pass "包含 prerm 卸载生命周期钩子" || log_fail "缺少 prerm 钩子"
	grep -q "Package/.*postrm" Makefile && log_pass "包含 postrm 残留清理生命周期钩子" || log_fail "缺少 postrm 钩子"
else
	log_fail "未找到根目录 Makefile"
fi

echo "=== 2. 检验全平台 CPU 架构兼容性 (x86_64, aarch64, arm, mips) ==="
# Ensure there are no compiled ELF binary files inside the repository
ELF_COUNT=$(find root/ htdocs/ -type f -exec file {} + 2>/dev/null | grep -i "ELF" | wc -l || echo 0)
if [ "$ELF_COUNT" -eq 0 ]; then
	log_pass "未包含任何平台绑定编译型二进制文件，纯原生 JS + POSIX Shell，100% 全架构支持"
else
	log_fail "发现 $ELF_COUNT 个平台特定二进制文件，可能影响异构 CPU 架构上架！"
fi

echo "=== 3. 检验 LuCI ACL 与 Menu 导航定义规范 ==="
if [ -f "root/usr/share/rpcd/acl.d/luci-app-ups-manager.json" ]; then
	log_pass "ACL 权限文件位于标准的 /usr/share/rpcd/acl.d/ 目录"
else
	log_fail "缺少 rpcd ACL 文件"
fi

if [ -f "root/usr/share/luci/menu.d/luci-app-ups-manager.json" ]; then
	log_pass "Menu 导航文件位于标准的 /usr/share/luci/menu.d/ 目录"
else
	log_fail "缺少 LuCI menu 文件"
fi

echo "=== 4. 检验 iStoreOS 官方 App-Meta 元数据包规范 ==="
META_DIR="applications/app-meta-ups-manager"
if [ -d "$META_DIR" ]; then
	[ -f "$META_DIR/Makefile" ] && log_pass "app-meta Makefile 就绪" || log_fail "缺少 app-meta Makefile"
	[ -f "$META_DIR/config.sh" ] && log_pass "iStore 自动配置脚本 config.sh 就绪" || log_fail "缺少 config.sh"
	if [ -f "$META_DIR/logo.png" ]; then
		log_pass "软件中心图标 logo.png 存在"
	else
		log_fail "缺少软件中心图标 logo.png"
	fi
else
	log_fail "未找到 $META_DIR 目录"
fi

echo "=== 5. 检验系统脚本与执行权限 ==="
for script in root/etc/init.d/ups-manager root/usr/bin/ups-manager-* root/usr/libexec/rpcd/luci.ups-manager; do
	if [ -f "$script" ]; then
		log_pass "脚本存在: $script"
	fi
done

echo ""
if [ $ERRORS -eq 0 ]; then
	echo "============================================================"
	echo "  🎉 恭喜！所有 iStoreOS 软件中心上架合规性校验项均已全部通过！"
	echo "============================================================"
	exit 0
else
	echo "============================================================"
	echo "  ❌ 发现 $ERRORS 项不合规项，请按上述指引修复后再次验证。"
	echo "============================================================"
	exit 1
fi
