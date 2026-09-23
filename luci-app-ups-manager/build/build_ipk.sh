#!/bin/bash
# ==============================================================================
# Build standard OpenWrt / iStoreOS IPK package for luci-app-ups-manager
# ==============================================================================
set -e

PKG_NAME="luci-app-ups-manager"
PKG_VERSION="1.0.0"
PKG_RELEASE="2"
PKG_ARCH="all"

OUTPUT_DIR="$(pwd)/dist"
BUILD_DIR="$(pwd)/build/tmp_ipk"
IPK_NAME="${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}.ipk"

echo "=== Building ${IPK_NAME} ==="
rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR/data" "$BUILD_DIR/control" "$OUTPUT_DIR"

# 1. Prepare data directory
mkdir -p "$BUILD_DIR/data/etc" "$BUILD_DIR/data/usr" "$BUILD_DIR/data/www"
cp -r root/* "$BUILD_DIR/data/"
cp -r htdocs/* "$BUILD_DIR/data/www/"

# Explicitly ensure POSIX executable permissions
chmod 755 "$BUILD_DIR/data/etc/init.d/ups-manager"
chmod 755 "$BUILD_DIR/data/usr/bin/ups-manager-"*
chmod 755 "$BUILD_DIR/data/usr/libexec/rpcd/luci.ups-manager"
chmod 755 "$BUILD_DIR/data/etc/uci-defaults/80_ups_manager"

(cd "$BUILD_DIR/data" && tar -czf "$BUILD_DIR/data.tar.gz" .)

# 2. Prepare control directory
cat <<EOF > "$BUILD_DIR/control/control"
Package: $PKG_NAME
Version: $PKG_VERSION-$PKG_RELEASE
Depends: luci-base, rpcd, nut, nut-common, nut-server, nut-upsmon, nut-upsc, nut-driver-usbhid-ups, curl
Section: luci
Architecture: $PKG_ARCH
Maintainer: Gilbert Liu & Contributors
Title: LuCI support for UPS Manager
Description: Enterprise UPS Power Management System for OpenWrt / iStoreOS with auto-discovery, telemetry, outage alerts and shutdown protection.
Source: https://github.com/liuyuhao1023/luci-app-ups-manager
License: GPL-2.0-or-later
EOF

cat <<'EOF' > "$BUILD_DIR/control/postinst"
#!/bin/sh
if [ -z "$IPKG_INSTROOT" ]; then
	chmod 755 /etc/init.d/ups-manager 2>/dev/null || true
	chmod 755 /etc/uci-defaults/80_ups_manager 2>/dev/null || true
	chmod 755 /usr/bin/ups-manager-* 2>/dev/null || true
	chmod 755 /usr/libexec/rpcd/luci.ups-manager 2>/dev/null || true
	/etc/uci-defaults/80_ups_manager 2>/dev/null || true
	/etc/init.d/ups-manager enable
	/etc/init.d/ups-manager restart 2>/dev/null || true
	/etc/init.d/rpcd reload 2>/dev/null || true
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/
fi
exit 0
EOF
chmod 755 "$BUILD_DIR/control/postinst"

cat <<'EOF' > "$BUILD_DIR/control/prerm"
#!/bin/sh
if [ -z "$IPKG_INSTROOT" ]; then
	/etc/init.d/ups-manager stop 2>/dev/null || true
	/etc/init.d/ups-manager disable 2>/dev/null || true
fi
exit 0
EOF
chmod 755 "$BUILD_DIR/control/prerm"

cat <<'EOF' > "$BUILD_DIR/control/postrm"
#!/bin/sh
if [ -z "$IPKG_INSTROOT" ]; then
	rm -rf /tmp/run/ups-manager* /tmp/log/ups-manager*
	/etc/init.d/rpcd reload 2>/dev/null || true
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/
fi
exit 0
EOF
chmod 755 "$BUILD_DIR/control/postrm"

(cd "$BUILD_DIR/control" && tar -czf "$BUILD_DIR/control.tar.gz" .)

# 3. Assemble .ipk archive
echo "2.0" > "$BUILD_DIR/debian-binary"
(cd "$BUILD_DIR" && tar -czf "$OUTPUT_DIR/$IPK_NAME" ./debian-binary ./control.tar.gz ./data.tar.gz)

rm -rf "$BUILD_DIR"

echo "=========================================================="
echo "🎉 Successfully built: dist/$IPK_NAME"
ls -lh "$OUTPUT_DIR/$IPK_NAME"
echo "=========================================================="
