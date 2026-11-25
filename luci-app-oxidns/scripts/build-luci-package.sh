#!/bin/sh
#
# Quick (non-buildroot) packaging for luci-app-oxidns and its translation.
#
# Usage:
#   scripts/build-luci-package.sh [VERSION [OUT_DIR [CORE_ARCHIVE [RULES_ARCHIVE \
#       [CORE_SHA256 [RULES_SHA256]]]]]]
#
# VERSION defaults to PKG_VERSION from the root Makefile; PKG_RELEASE,
# MAINTAINER and LICENSE are also read from there so the local package agrees
# with the OpenWrt buildroot build. CORE_ARCHIVE / RULES_ARCHIVE are optional
# release tarballs to embed. A matching SHA256 is REQUIRED for each archive:
# pass it as the 5th/6th argument, as <archive>=<sha256> in the 3rd/4th
# argument, or via OXIDNS_CORE_SHA256 / OXIDNS_RULES_SHA256.
#
# SOURCE_DATE_EPOCH (or a fixed default) is used for all tar/gzip/control
# timestamps so identical inputs produce identical package bytes.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

make_value() {
	sed -n "s/^$1:=//p" Makefile | head -n 1
}

MAKE_PKG_VERSION="$(make_value PKG_VERSION)"
PKG_RELEASE="$(make_value PKG_RELEASE)"
PKG_MAINTAINER="$(make_value PKG_MAINTAINER)"
PKG_LICENSE="$(make_value PKG_LICENSE)"
for required in MAKE_PKG_VERSION PKG_RELEASE PKG_MAINTAINER PKG_LICENSE; do
	if [ -z "$(eval "printf '%s' \"\$$required\"")" ]; then
		printf 'cannot read %s from Makefile\n' "$required" >&2
		exit 1
	fi
done

VERSION="${1:-$MAKE_PKG_VERSION}"
OUT_DIR="${2:-dist}"
CORE_ARCHIVE="${3:-}"
RULES_ARCHIVE="${4:-}"
CORE_SHA256="${5:-${OXIDNS_CORE_SHA256:-}}"
RULES_SHA256="${6:-${OXIDNS_RULES_SHA256:-}}"
case "$CORE_ARCHIVE" in
	*=*) CORE_SHA256="${CORE_ARCHIVE#*=}"; CORE_ARCHIVE="${CORE_ARCHIVE%%=*}" ;;
esac
case "$RULES_ARCHIVE" in
	*=*) RULES_SHA256="${RULES_ARCHIVE#*=}"; RULES_ARCHIVE="${RULES_ARCHIVE%%=*}" ;;
esac
PKG_VERSION="$(printf '%s' "$VERSION" | sed 's/^v//')"
PKG_NAME="luci-app-oxidns"
PKG_FILE_BASE="${PKG_NAME}_${PKG_VERSION}-r${PKG_RELEASE}_all"
I18N_PKG_NAME="luci-i18n-oxidns-zh-cn"
I18N_FILE_BASE="${I18N_PKG_NAME}_${PKG_VERSION}-r${PKG_RELEASE}_all"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'required command not found: %s\n' "$1" >&2
		exit 1
	}
}

need_cmd tar
need_cmd gzip
need_cmd node
if command -v sha256sum >/dev/null 2>&1; then
	sha256_of() { sha256sum "$1" | awk '{ print $1 }'; }
	sha256_list() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
	sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }
	sha256_list() { shasum -a 256 "$@"; }
else
	printf 'required command not found: sha256sum (or shasum)\n' >&2
	exit 1
fi

export COPYFILE_DISABLE=1
export LC_ALL=C

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luci-app-oxidns-build.XXXXXX")"
cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

verify_archive_checksum() {
	verify_path="$1"
	verify_expected="$2"
	verify_label="$3"
	if [ -z "$verify_expected" ]; then
		printf 'ERROR: SHA256 is required for the %s archive\n' "$verify_label" >&2
		return 1
	fi
	if ! printf '%s\n' "$verify_expected" | grep -Eq '^[0-9a-fA-F]{64}$'; then
		printf 'ERROR: invalid %s SHA256: %s\n' "$verify_label" "$verify_expected" >&2
		return 1
	fi
	verify_actual="$(sha256_of "$verify_path")"
	if [ "$verify_actual" != "$verify_expected" ]; then
		printf 'ERROR: %s SHA256 mismatch: expected %s, got %s\n' \
			"$verify_label" "$verify_expected" "$verify_actual" >&2
		return 1
	fi
}

# validate_tar_archive <archive> <label>
# Refuse absolute paths, parent traversal, links, devices and FIFOs before any
# extraction happens (the embedded bundle is unpacked as root on the device).
validate_tar_archive() {
	archive="$1"
	label="$2"
	listing="$TMP_DIR/${label}.listing"
	verbose="$TMP_DIR/${label}.verbose"
	if ! tar -tzf "$archive" > "$listing" 2>/dev/null; then
		printf 'ERROR: %s archive is not a readable gzip tar: %s\n' "$label" "$archive" >&2
		return 1
	fi
	if ! tar -tvzf "$archive" > "$verbose" 2>/dev/null; then
		printf 'ERROR: cannot list %s archive members with modes: %s\n' "$label" "$archive" >&2
		return 1
	fi
	if awk '
		{
			path = $0
			sub(/^\.\//, "", path)
			if (path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/ || path ~ /\\/ || path ~ / -> /) {
				bad = 1
			}
		}
		END { exit bad ? 0 : 1 }
	' "$listing"; then
		printf 'ERROR: %s archive contains absolute, traversal or link paths\n' "$label" >&2
		return 1
	fi
	# The first character of tar -tv output is the entry type: '-' file, 'd'
	# directory. Everything else (l/h symlink, b/c device, p FIFO, s socket)
	# is rejected, including inside the embedded core bundle.
	if awk '
		/^[-d]/ { next }
		NF { bad = 1 }
		END { exit bad ? 0 : 1 }
	' "$verbose"; then
		printf 'ERROR: %s archive contains links, devices or special files\n' "$label" >&2
		return 1
	fi
}

if [ -n "$RULES_ARCHIVE" ]; then
	if [ ! -f "$RULES_ARCHIVE" ]; then
		printf 'rules archive not found: %s\n' "$RULES_ARCHIVE" >&2
		exit 1
	fi
	verify_archive_checksum "$RULES_ARCHIVE" "$RULES_SHA256" "rules"
	validate_tar_archive "$RULES_ARCHIVE" "rules"
	if ! tar -tzf "$RULES_ARCHIVE" 2>/dev/null | grep -q '/cn-domains.txt$'; then
		printf 'rules archive does not contain cn-domains.txt, refusing to embed it\n' >&2
		exit 1
	fi
fi

if [ -n "$CORE_ARCHIVE" ]; then
	if [ ! -f "$CORE_ARCHIVE" ]; then
		printf 'core archive not found: %s\n' "$CORE_ARCHIVE" >&2
		exit 1
	fi
	verify_archive_checksum "$CORE_ARCHIVE" "$CORE_SHA256" "core"
	validate_tar_archive "$CORE_ARCHIVE" "core"
	if ! tar -tzf "$CORE_ARCHIVE" 2>/dev/null | grep -qx 'oxidns'; then
		printf 'core archive does not look like an OxiDNS release bundle (missing oxidns entry)\n' >&2
		exit 1
	fi
fi

# Reproducibility: SOURCE_DATE_EPOCH wins if set; otherwise a fixed epoch is
# used so two builds of the same tree are byte-identical.
BUILD_EPOCH="${SOURCE_DATE_EPOCH:-315532800}"
case "$BUILD_EPOCH" in
	''|*[!0-9]*) printf 'ERROR: invalid SOURCE_DATE_EPOCH: %s\n' "$BUILD_EPOCH" >&2; exit 1 ;;
esac
export SOURCE_DATE_EPOCH="$BUILD_EPOCH"
TOUCH_STAMP="$(date -u -r "$BUILD_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || true)"
if [ -z "$TOUCH_STAMP" ]; then
	TOUCH_STAMP="$(date -u -d "@$BUILD_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || true)"
fi
[ -n "$TOUCH_STAMP" ] || { printf 'ERROR: cannot format epoch %s for touch\n' "$BUILD_EPOCH" >&2; exit 1; }
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
	GNU_TAR=1
else
	GNU_TAR=0
fi

normalize_tree() {
	find "$1" -exec touch -t "$TOUCH_STAMP" {} + 2>/dev/null || true
}

write_file_list() {
	file_list_dir="$1"
	file_list_out="$2"
	(
		cd "$file_list_dir"
		find . ! -name . | sed 's#^\./##' | LC_ALL=C sort
	) > "$file_list_out"
}

tar_create_gz_from_dir() {
	tar_gz_out="$1"
	tar_gz_dir="$2"
	tar_gz_list="$TMP_DIR/$(basename "$tar_gz_out").list"
	normalize_tree "$tar_gz_dir"
	write_file_list "$tar_gz_dir" "$tar_gz_list"
	if [ "$GNU_TAR" -eq 1 ]; then
		tar --format=ustar --owner=0 --group=0 --numeric-owner --no-recursion \
			--mtime="@$BUILD_EPOCH" -cf - -C "$tar_gz_dir" -T "$tar_gz_list" \
			| gzip -9n > "$tar_gz_out"
	else
		tar --format=ustar --uid 0 --gid 0 --uname root --gname root --no-recursion \
			-cf - -C "$tar_gz_dir" -T "$tar_gz_list" | gzip -9n > "$tar_gz_out"
	fi
	rm -f "$tar_gz_list"
}

tar_create_segment_gz_from_list() {
	tar_segment_out="$1"
	tar_segment_dir="$2"
	tar_segment_list="$3"
	tar_segment_raw="${tar_segment_out%.gz}"
	tar_segment_cut="$tar_segment_raw.cut"
	normalize_tree "$tar_segment_dir"
	if [ "$GNU_TAR" -eq 1 ]; then
		tar --format=ustar --owner=0 --group=0 --numeric-owner --no-recursion \
			--mtime="@$BUILD_EPOCH" -cf "$tar_segment_raw" -C "$tar_segment_dir" -T "$tar_segment_list"
	else
		tar --format=ustar --uid 0 --gid 0 --uname root --gname root --no-recursion \
			-cf "$tar_segment_raw" -C "$tar_segment_dir" -T "$tar_segment_list"
	fi
	node scripts/strip-tar-eof.mjs "$tar_segment_raw" "$tar_segment_cut"
	gzip -9n < "$tar_segment_cut" > "$tar_segment_out"
}

installed_size() {
	find "$1" -type f -exec wc -c {} + | awk 'END { print $1 + 0 }'
}

create_ipk() {
	ipk_out="$1"
	ipk_control_tar="$2"
	ipk_data_tar="$3"
	ipk_dir="$TMP_DIR/ipk-$(basename "$ipk_out" .ipk)"

	rm -rf "$ipk_dir"
	mkdir -p "$ipk_dir"
	printf '2.0\n' > "$ipk_dir/debian-binary"
	cp "$ipk_data_tar" "$ipk_dir/data.tar.gz"
	cp "$ipk_control_tar" "$ipk_dir/control.tar.gz"
	normalize_tree "$ipk_dir"
	# ipk is an ar archive (debian-binary + control/data tarballs), matching
	# OpenWrt's opkg/ipkg tools. The tar.gz used here used to be rejected by
	# opkg and by apk's indexer.
	node scripts/write-ar-archive.mjs "$ipk_out" \
		"debian-binary=$ipk_dir/debian-binary" \
		"control.tar.gz=$ipk_control_tar" \
		"data.tar.gz=$ipk_data_tar"
}

create_apk() {
	apk_out="$1"
	apk_control_dir="$2"
	apk_data_dir="$3"
	apk_name="$(basename "$apk_out" .apk)"
	apk_control_list="$TMP_DIR/$apk_name.control.list"
	apk_data_raw="$TMP_DIR/$apk_name.data.tar"
	apk_data_tar="$TMP_DIR/$apk_name.data.tar.gz"
	apk_control_tar="$TMP_DIR/$apk_name.control.tar.gz"
	apk_datahash=""

	node scripts/write-apk-data-tar.mjs "$apk_data_dir" "$apk_data_raw"
	gzip -9n < "$apk_data_raw" > "$apk_data_tar"
	apk_datahash="$(sha256_of "$apk_data_tar")"
	printf 'datahash = %s\n' "$apk_datahash" >> "$apk_control_dir/.PKGINFO"

	{
		printf '.PKGINFO\n'
		(
			cd "$apk_control_dir"
			find . ! -name . ! -name .PKGINFO | sed 's#^\./##' | LC_ALL=C sort
		)
	} > "$apk_control_list"

	tar_create_segment_gz_from_list "$apk_control_tar" "$apk_control_dir" "$apk_control_list"
	cat "$apk_control_tar" "$apk_data_tar" > "$apk_out"
}

write_rpcd_restart_script() {
	out="$1"
	cat > "$out" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
# Keep the core binary, webui and configuration across firmware upgrades.
if [ -f /etc/sysupgrade.conf ]; then
	for entry in /etc/oxidns /etc/config/oxidns; do
		grep -qxF "$entry" /etc/sysupgrade.conf 2>/dev/null || \
			echo "$entry" >> /etc/sysupgrade.conf
	done
fi
# Unpack an embedded core bundle on first install, so the package works
# out of the box without downloading anything.
BUNDLE="/usr/share/oxidns/core-bundle.tar.gz"
if [ -f "$BUNDLE" ] && [ ! -x /etc/oxidns/core/oxidns ]; then
	EXTRACT_DIR="$(mktemp -d /tmp/oxidns-core-bundle.XXXXXX)"
	if tar -xzf "$BUNDLE" -C "$EXTRACT_DIR" 2>/dev/null && [ -f "$EXTRACT_DIR/oxidns" ]; then
		mkdir -p /etc/oxidns/core
		cp "$EXTRACT_DIR/oxidns" /etc/oxidns/core/oxidns
		chmod 755 /etc/oxidns/core/oxidns
		if [ -d "$EXTRACT_DIR/webui" ]; then
			rm -rf /etc/oxidns/core/webui
			cp -R "$EXTRACT_DIR/webui" /etc/oxidns/core/webui
			mkdir -p /usr/share/oxidns
			ln -sfn /etc/oxidns/core/webui /usr/share/oxidns/webui
		fi
		mkdir -p /usr/bin
		ln -sf /etc/oxidns/core/oxidns /usr/bin/oxidns
		rm -rf "$EXTRACT_DIR"
		rm -f "$BUNDLE"
	else
		rm -rf "$EXTRACT_DIR"
	fi
fi
if [ -x /etc/oxidns/core/oxidns ] && [ ! -x /usr/bin/oxidns ]; then
	mkdir -p /usr/bin
	ln -sf /etc/oxidns/core/oxidns /usr/bin/oxidns
fi
if [ -d /etc/oxidns/core/webui ] && [ ! -d /usr/share/oxidns/webui ]; then
	mkdir -p /usr/share/oxidns
	ln -sfn /etc/oxidns/core/webui /usr/share/oxidns/webui
fi
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -d /www/luci-static/resources/view/oxidns ]; then
	find /www/luci-static/resources/view/oxidns -type f -name '*.js' -exec touch {} + 2>/dev/null || true
fi
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
exit 0
EOF
	chmod 755 "$out"
}

# Uninstall must not re-add sysupgrade entries, re-unpack the bundle or
# recreate any links; it only clears LuCI caches and restarts rpcd.
write_postrm_script() {
	out="$1"
	cat > "$out" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
exit 0
EOF
	chmod 755 "$out"
}

write_i18n_postinst_script() {
	out="$1"
	cat > "$out" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
if [ -x /etc/uci-defaults/luci-i18n-oxidns-zh-cn ]; then
	/etc/uci-defaults/luci-i18n-oxidns-zh-cn >/dev/null 2>&1 || true
fi
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
exit 0
EOF
	chmod 755 "$out"
}

CONTROL_DIR="$TMP_DIR/control"
DATA_DIR="$TMP_DIR/data"
APK_CONTROL_DIR="$TMP_DIR/apk-control"
I18N_CONTROL_DIR="$TMP_DIR/i18n-control"
I18N_DATA_DIR="$TMP_DIR/i18n-data"
I18N_APK_CONTROL_DIR="$TMP_DIR/i18n-apk-control"
mkdir -p "$CONTROL_DIR" "$DATA_DIR" "$APK_CONTROL_DIR" "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

cat > "$CONTROL_DIR/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION-r$PKG_RELEASE
Architecture: all
Maintainer: $PKG_MAINTAINER
Depends: luci-base, rpcd, jsonfilter, uclient-fetch, ca-bundle
Source: https://github.com/NetForgeCN/luci-app-oxidns
Section: luci
Priority: optional
Description: LuCI support for OxiDNS
License: $PKG_LICENSE
EOF

mkdir -p "$DATA_DIR/www" "$DATA_DIR"
if [ -d htdocs ]; then
	cp -R htdocs/. "$DATA_DIR/www/"
fi
if [ -d root ]; then
	cp -R root/. "$DATA_DIR/"
fi

if [ -n "$CORE_ARCHIVE" ]; then
	mkdir -p "$DATA_DIR/usr/share/oxidns"
	cp "$CORE_ARCHIVE" "$DATA_DIR/usr/share/oxidns/core-bundle.tar.gz"
fi

# Packaged without buildroot there is no oxidns-rules-baseline package, so the
# rule files must travel inside this package: /etc/init.d/oxidns seeds
# /etc/oxidns/rules from them on the first start, exactly like the buildroot
# package does. Get the archive from the pinned release (see
# oxidns-rules-baseline/Makefile) and pass its SHA256 as the sixth argument.
if [ -n "$RULES_ARCHIVE" ]; then
	mkdir -p "$DATA_DIR/usr/share/oxidns/rules-baseline"
	tar -xzf "$RULES_ARCHIVE" -C "$DATA_DIR/usr/share/oxidns/rules-baseline" --strip-components=1
	if [ ! -s "$DATA_DIR/usr/share/oxidns/rules-baseline/cn-domains.txt" ]; then
		printf 'rules archive unpacked without cn-domains.txt\n' >&2
		exit 1
	fi
fi

if [ -f "$DATA_DIR/usr/libexec/rpcd/luci.oxidns" ]; then
	chmod 755 "$DATA_DIR/usr/libexec/rpcd/luci.oxidns"
fi
if [ -f "$DATA_DIR/usr/libexec/oxidns-prewarm" ]; then
	chmod 755 "$DATA_DIR/usr/libexec/oxidns-prewarm"
fi
if [ -f "$DATA_DIR/etc/init.d/oxidns" ]; then
	chmod 755 "$DATA_DIR/etc/init.d/oxidns"
fi
write_rpcd_restart_script "$CONTROL_DIR/postinst"
write_postrm_script "$CONTROL_DIR/postrm"

tar_create_gz_from_dir "$TMP_DIR/control.tar.gz" "$CONTROL_DIR"
tar_create_gz_from_dir "$TMP_DIR/data.tar.gz" "$DATA_DIR"
create_ipk "$OUT_DIR/${PKG_FILE_BASE}.ipk" "$TMP_DIR/control.tar.gz" "$TMP_DIR/data.tar.gz"

cat > "$APK_CONTROL_DIR/.PKGINFO" <<EOF
pkgname = $PKG_NAME
pkgver = $PKG_VERSION-r$PKG_RELEASE
pkgdesc = LuCI support for OxiDNS
url = https://github.com/NetForgeCN/luci-app-oxidns
builddate = $BUILD_EPOCH
packager = $PKG_MAINTAINER
size = $(installed_size "$DATA_DIR")
arch = noarch
origin = $PKG_NAME
license = $PKG_LICENSE
depend = luci-base
depend = rpcd
depend = jsonfilter
depend = uclient-fetch
depend = ca-bundle
EOF
write_rpcd_restart_script "$APK_CONTROL_DIR/.post-install"
cp "$APK_CONTROL_DIR/.post-install" "$APK_CONTROL_DIR/.post-upgrade"
cp "$CONTROL_DIR/postrm" "$APK_CONTROL_DIR/.post-deinstall"

create_apk "$OUT_DIR/${PKG_FILE_BASE}.apk" "$APK_CONTROL_DIR" "$DATA_DIR"

printf 'Wrote %s\n' "$OUT_DIR/${PKG_FILE_BASE}.ipk"
printf 'Wrote %s\n' "$OUT_DIR/${PKG_FILE_BASE}.apk"

if [ -f po/zh_Hans/oxidns.po ]; then
	mkdir -p "$I18N_CONTROL_DIR" "$I18N_APK_CONTROL_DIR" "$I18N_DATA_DIR/usr/lib/lua/luci/i18n" "$I18N_DATA_DIR/etc/uci-defaults"

	cat > "$I18N_CONTROL_DIR/control" <<-EOF
	Package: $I18N_PKG_NAME
	Version: $PKG_VERSION-r$PKG_RELEASE
	Architecture: all
	Maintainer: $PKG_MAINTAINER
Depends: $PKG_NAME
Source: https://github.com/NetForgeCN/luci-app-oxidns
Section: luci
Priority: optional
License: $PKG_LICENSE
	Description: Simplified Chinese translation for luci-app-oxidns
	EOF

	cat > "$I18N_DATA_DIR/etc/uci-defaults/$I18N_PKG_NAME" <<-'EOF'
	uci set luci.languages.zh_cn='简体中文 (Simplified Chinese)'
	uci commit luci
	EOF
	chmod 755 "$I18N_DATA_DIR/etc/uci-defaults/$I18N_PKG_NAME"
	write_i18n_postinst_script "$I18N_CONTROL_DIR/postinst"

	node scripts/po2lmo.mjs po/zh_Hans/oxidns.po "$I18N_DATA_DIR/usr/lib/lua/luci/i18n/oxidns.zh-cn.lmo"

	tar_create_gz_from_dir "$TMP_DIR/control.tar.gz" "$I18N_CONTROL_DIR"
	tar_create_gz_from_dir "$TMP_DIR/data.tar.gz" "$I18N_DATA_DIR"
	create_ipk "$OUT_DIR/${I18N_FILE_BASE}.ipk" "$TMP_DIR/control.tar.gz" "$TMP_DIR/data.tar.gz"

	cat > "$I18N_APK_CONTROL_DIR/.PKGINFO" <<-EOF
	pkgname = $I18N_PKG_NAME
	pkgver = $PKG_VERSION-r$PKG_RELEASE
	pkgdesc = Simplified Chinese translation for luci-app-oxidns
	url = https://github.com/NetForgeCN/luci-app-oxidns
	builddate = $BUILD_EPOCH
	packager = $PKG_MAINTAINER
	size = $(installed_size "$I18N_DATA_DIR")
	arch = noarch
	origin = $I18N_PKG_NAME
	license = $PKG_LICENSE
	depend = $PKG_NAME
	EOF
	write_i18n_postinst_script "$I18N_APK_CONTROL_DIR/.post-install"
	cp "$I18N_APK_CONTROL_DIR/.post-install" "$I18N_APK_CONTROL_DIR/.post-upgrade"

	create_apk "$OUT_DIR/${I18N_FILE_BASE}.apk" "$I18N_APK_CONTROL_DIR" "$I18N_DATA_DIR"

	(
		cd "$OUT_DIR"
		sha256_list \
			"${PKG_FILE_BASE}.ipk" \
			"${PKG_FILE_BASE}.apk" \
			"${I18N_FILE_BASE}.ipk" \
			"${I18N_FILE_BASE}.apk"
	) > "$OUT_DIR/sha256sums.txt"

	printf 'Wrote %s\n' "$OUT_DIR/${I18N_FILE_BASE}.ipk"
	printf 'Wrote %s\n' "$OUT_DIR/${I18N_FILE_BASE}.apk"
else
	(
		cd "$OUT_DIR"
		sha256_list "${PKG_FILE_BASE}.ipk" "${PKG_FILE_BASE}.apk"
	) > "$OUT_DIR/sha256sums.txt"
fi
