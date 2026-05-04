#!/bin/bash
# Build luci-app-parentalcontrol.apk for OpenWrt 25.x (APK format)
# Works for script-only packages (no compilation needed)

set -e

PKG_NAME="luci-app-parentalcontrol"
PKG_VERSION="1.0.0-r1"
PKG_ARCH="noarch"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APK_FILE="$SCRIPT_DIR/${PKG_NAME}-${PKG_VERSION}.apk"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"/{control,data}

# -- Assemble data tree (the actual files) --

# LuCI view
mkdir -p "$BUILD_DIR/data/www/luci-static/resources/view/parentalcontrol"
cp "$SCRIPT_DIR/htdocs/luci-static/resources/view/parentalcontrol/settings.js" \
   "$BUILD_DIR/data/www/luci-static/resources/view/parentalcontrol/"

# Config, init, uci-defaults
mkdir -p "$BUILD_DIR/data/etc/config"
mkdir -p "$BUILD_DIR/data/etc/init.d"
mkdir -p "$BUILD_DIR/data/etc/uci-defaults"
cp "$SCRIPT_DIR/root/etc/config/parentalcontrol" "$BUILD_DIR/data/etc/config/"
cp "$SCRIPT_DIR/root/etc/init.d/parentalcontrol" "$BUILD_DIR/data/etc/init.d/"
chmod +x "$BUILD_DIR/data/etc/init.d/parentalcontrol"
cp "$SCRIPT_DIR/root/etc/uci-defaults/luci-app-parentalcontrol" "$BUILD_DIR/data/etc/uci-defaults/"
chmod +x "$BUILD_DIR/data/etc/uci-defaults/luci-app-parentalcontrol"

# Backend scripts
mkdir -p "$BUILD_DIR/data/usr/libexec/rpcd"
cp "$SCRIPT_DIR/root/usr/libexec/parentalcontrol.sh" "$BUILD_DIR/data/usr/libexec/"
chmod +x "$BUILD_DIR/data/usr/libexec/parentalcontrol.sh"
cp "$SCRIPT_DIR/root/usr/libexec/rpcd/parentalcontrol" "$BUILD_DIR/data/usr/libexec/rpcd/"
chmod +x "$BUILD_DIR/data/usr/libexec/rpcd/parentalcontrol"

# LuCI menu and ACL
mkdir -p "$BUILD_DIR/data/usr/share/luci/menu.d"
mkdir -p "$BUILD_DIR/data/usr/share/rpcd/acl.d"
cp "$SCRIPT_DIR/root/usr/share/luci/menu.d/luci-app-parentalcontrol.json" \
   "$BUILD_DIR/data/usr/share/luci/menu.d/"
cp "$SCRIPT_DIR/root/usr/share/rpcd/acl.d/luci-app-parentalcontrol.json" \
   "$BUILD_DIR/data/usr/share/rpcd/acl.d/"

# -- Calculate installed size --
INSTALLED_SIZE=$(find "$BUILD_DIR/data" -type f -exec cat {} + | wc -c | tr -d ' ')

# -- Create .PKGINFO (APK control metadata) --
cat > "$BUILD_DIR/control/.PKGINFO" <<EOF
pkgname = ${PKG_NAME}
pkgver = ${PKG_VERSION}
pkgdesc = LuCI Parental Control - Time-based access control with per-device scheduling and temporary overrides
url = https://github.com/openwrt
builddate = $(date +%s)
packager = OpenWrt Build System
size = ${INSTALLED_SIZE}
arch = ${PKG_ARCH}
origin = ${PKG_NAME}
license = MIT
depend = luci-base
depend = nftables
EOF

# -- Create post-install script --
cat > "$BUILD_DIR/control/.post-install" <<'SCRIPT'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	( . /etc/uci-defaults/luci-app-parentalcontrol ) && rm -f /etc/uci-defaults/luci-app-parentalcontrol
	rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
	/etc/init.d/parentalcontrol enable 2>/dev/null
	/etc/init.d/rpcd restart 2>/dev/null
}
exit 0
SCRIPT
chmod +x "$BUILD_DIR/control/.post-install"

# -- Create pre-deinstall script --
cat > "$BUILD_DIR/control/.pre-deinstall" <<'SCRIPT'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	/etc/init.d/parentalcontrol stop 2>/dev/null
	/etc/init.d/parentalcontrol disable 2>/dev/null
}
exit 0
SCRIPT
chmod +x "$BUILD_DIR/control/.pre-deinstall"

# -- Build the .apk (two concatenated gzip streams) --

# Stream 1: control (metadata + scripts)
(cd "$BUILD_DIR/control" && tar cf - .PKGINFO .post-install .pre-deinstall) | gzip > "$BUILD_DIR/control.tar.gz"

# Stream 2: data (actual package files)
(cd "$BUILD_DIR/data" && tar cf - .) | gzip > "$BUILD_DIR/data.tar.gz"

# Concatenate into final .apk
cat "$BUILD_DIR/control.tar.gz" "$BUILD_DIR/data.tar.gz" > "$APK_FILE"

# Cleanup
rm -rf "$BUILD_DIR"

echo ""
echo "Built: $APK_FILE"
echo "Size:  $(du -h "$APK_FILE" | awk '{print $1}')"
echo ""
echo "To install on your router:"
echo "  scp $(basename "$APK_FILE") root@<router-ip>:/tmp/"
echo "  ssh root@<router-ip> 'apk add --allow-untrusted /tmp/$(basename "$APK_FILE")'"
