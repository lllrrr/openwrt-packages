#!/bin/sh
# Build luci-app-frpc-multi .apk with apk mkpkg inside an alpine container.
# Usage: sh build-apk.sh <absolute-srcdir> <absolute-outdir>
set -eu
SRC=${1:?srcdir}
OUT=${2:?outdir}
VER=${VER:-1.0.0-r8}
NAME=luci-app-frpc-multi
PROJECT_URL=${PROJECT_URL:-https://github.com/myc2002/luci-app-frpc-multi}
APK_LICENSE=${APK_LICENSE:-Apache-2.0 AND GPL-2.0-only}
APK_ARCH=${APK_ARCH:-noarch}

W=$(mktemp -d /tmp/frpcm-build.XXXXXX)
trap 'rm -rf "$W"' EXIT
cp -a "$SRC/root" "$W/root"

# permissions
chmod 755 "$W/root/etc/init.d/frpc-multi" "$W/root/usr/sbin/frpc-multi-watchdog"
chmod 644 "$W/root/usr/share/rpcd/ucode/luci.frpc-multi" \
	"$W/root/usr/share/luci/menu.d/luci-app-frpc-multi.json" \
	"$W/root/usr/share/rpcd/acl.d/luci-app-frpc-multi.json" \
	"$W/root/www/luci-static/resources/view/frpc-multi.js"
chmod 600 "$W/root/etc/config/frpc_multi"

# OpenWrt package bookkeeping: file list + conffiles (keeps /etc/config across upgrades)
mkdir -p "$W/root/lib/apk/packages"
python3 - "$W/root" "$NAME" <<'PYFILES'
import pathlib,sys
root=pathlib.Path(sys.argv[1]);name=sys.argv[2]
files=sorted('/'+str(x.relative_to(root)) for x in root.rglob('*') if x.is_file() and not str(x.relative_to(root)).startswith('lib/apk/'))
(root/'lib/apk/packages'/f'{name}.list').write_text('\n'.join(files)+'\n')
PYFILES
echo /etc/config/frpc_multi > "$W/root/lib/apk/packages/$NAME.conffiles"
printf '/etc/config/frpc_multi %s\n' "$(sha256sum "$W/root/etc/config/frpc_multi" | cut -d' ' -f1)" \
	> "$W/root/lib/apk/packages/$NAME.conffiles_static"

cp "$SRC/scripts/post-install" "$W/post-install"
# apk runs post-upgrade (not post-install) on upgrades: same idempotent hook
cp "$SRC/scripts/post-install" "$W/post-upgrade"
cp "$SRC/scripts/pre-deinstall" "$W/pre-deinstall"
chmod 755 "$W/post-install" "$W/post-upgrade" "$W/pre-deinstall"
mkdir -p "$OUT"

docker run --rm -v "$W:/w" -v "$OUT:/out" alpine:edge sh -c "
	apk mkpkg \
		-I name:$NAME \
		-I version:$VER \
		-I 'description:LuCI app for multiple independent frpc connections (one frpc process per server, live status, logs, watchdog)' \
		-I arch:$APK_ARCH \
		-I license:Apache-2.0 \
		-I origin:$NAME \
		-I url:$PROJECT_URL \
		-I 'depends:frpc luci-base rpcd-mod-ucode ucode-mod-uci ucode-mod-ubus ucode-mod-fs ucode-mod-socket' \
		-s post-install:/w/post-install \
		-s post-upgrade:/w/post-upgrade \
		-s pre-deinstall:/w/pre-deinstall \
		-F /w/root \
		-o /out/$NAME-$VER.apk
"
ls -l "$OUT/$NAME-$VER.apk"
