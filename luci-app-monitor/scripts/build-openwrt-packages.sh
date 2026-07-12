#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly PACKAGE_NAME='luci-app-monitor'
readonly PACKAGE_VERSION='1.1.1'
readonly PACKAGE_RELEASE='1'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SOURCE_DIR
readonly DEFAULT_BUILD_IMAGE='golang:1.26-bookworm@sha256:b305420a68d0f229d91eb3b3ed9e519fcf2cf5461da4bef997bf927e8c0bfd2b'

ROOT="${ROOT:-/tmp/luci-app-monitor-openwrt-sdk}"
DIST_DIR="${DIST_DIR:-$SOURCE_DIR/dist}"
BUILD_IMAGE="${BUILD_IMAGE:-$DEFAULT_BUILD_IMAGE}"

SUPPORTED_VERSIONS=(
	'23.05.6'
	'24.10.7'
	'25.12.5'
)

log() {
	printf '[build] %s\n' "$*"
}

die() {
	printf '[build] error: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage: scripts/build-openwrt-packages.sh [VERSION ...]

Build luci-app-monitor with the pinned OpenWrt SDKs. With no VERSION argument,
all supported releases are built and a combined archive is generated.

Supported versions:
  23.05.6  (IPK)
  24.10.7  (IPK)
  25.12.5  (APK)

Options:
  --list     Print the pinned build matrix without building.
  -h, --help Show this help.

Environment:
  ROOT        SDK/download cache and raw-output root
              (default: /tmp/luci-app-monitor-openwrt-sdk)
  DIST_DIR    Final release-asset directory (default: <repository>/dist)
  BUILD_IMAGE Pinned Linux/amd64 container image override
EOF
}

sdk_file_for() {
	case "$1" in
		23.05.6) printf '%s' 'openwrt-sdk-23.05.6-x86-64_gcc-12.3.0_musl.Linux-x86_64.tar.xz' ;;
		24.10.7) printf '%s' 'openwrt-sdk-24.10.7-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst' ;;
		25.12.5) printf '%s' 'openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

sdk_sha256_for() {
	case "$1" in
		23.05.6) printf '%s' 'f22bdac5b702bb823a0ee802e9bbda2a56c0f7a2687e5090113b00910dac995f' ;;
		24.10.7) printf '%s' '996d71f9eab7df2e8acb0bb2c9726426f05c10d419e5f9600d59b14d871f2acb' ;;
		25.12.5) printf '%s' '0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

openwrt_commit_for() {
	case "$1" in
		23.05.6) printf '%s' '761ee326d7e0c9be4569ec1428816c008a202757' ;;
		24.10.7) printf '%s' 'b40dfac0a31695596f7c1f5f1519302ca8237f6e' ;;
		25.12.5) printf '%s' 'f0a60eee2fe051741c643ea6118718aae1ef17fb' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

luci_commit_for() {
	case "$1" in
		23.05.6) printf '%s' '7ce34fe1a53db10bb9dd0223467f5bb71a29a659' ;;
		24.10.7) printf '%s' '3cf713a30bf456af74f9393096c2f7eb770b3ae2' ;;
		25.12.5) printf '%s' '128a7812f4be233c5dd7f7466f534fd888785caf' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

packages_commit_for() {
	case "$1" in
		23.05.6) printf '%s' 'e59d9ef823bcb581e3939789b4eaeaf900b79759' ;;
		24.10.7) printf '%s' '0c8f5f2ed91600b04ba639ef9c4c5ced3286cb3b' ;;
		25.12.5) printf '%s' '5caa62e0bc9f7fb9b0c12a23267bceb7724214dd' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

format_for() {
	case "$1" in
		23.05.6|24.10.7) printf '%s' 'ipk' ;;
		25.12.5) printf '%s' 'apk' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

expected_package_for() {
	case "$1" in
		23.05.6) printf '%s' 'luci-app-monitor_1.1.1_all.ipk' ;;
		24.10.7) printf '%s' 'luci-app-monitor_1.1.1-r1_all.ipk' ;;
		25.12.5) printf '%s' 'luci-app-monitor-1.1.1-r1.apk' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

expected_i18n_package_for() {
	case "$1" in
		23.05.6) printf '%s' 'luci-i18n-monitor-zh-cn_1.1.1_all.ipk' ;;
		24.10.7) printf '%s' 'luci-i18n-monitor-zh-cn_1.1.1-r1_all.ipk' ;;
		25.12.5) printf '%s' 'luci-i18n-monitor-zh-cn-1.1.1-r1.apk' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

metadata_version_for() {
	case "$1" in
		23.05.6) printf '%s' '1.1.1' ;;
		24.10.7|25.12.5) printf '%s' '1.1.1-r1' ;;
		*) die "unsupported OpenWrt version: $1" ;;
	esac
}

sdk_url_for() {
	local version="$1"
	printf 'https://downloads.openwrt.org/releases/%s/targets/x86/64/%s' \
		"$version" "$(sdk_file_for "$version")"
}

archive_name_for() {
	local version="$1"
	printf '%s-openwrt-%s-all-%s.tar.gz' "$PACKAGE_NAME" "$version" "$(format_for "$version")"
}

list_matrix() {
	local version
	printf 'VERSION\tFORMAT\tSDK_SHA256\tOPENWRT_COMMIT\tPACKAGES_COMMIT\tLUCI_COMMIT\n'
	for version in "${SUPPORTED_VERSIONS[@]}"; do
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$version" \
			"$(format_for "$version")" \
			"$(sdk_sha256_for "$version")" \
			"$(openwrt_commit_for "$version")" \
			"$(packages_commit_for "$version")" \
			"$(luci_commit_for "$version")"
	done
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die 'sha256sum or shasum is required'
	fi
}

makefile_value() {
	local key="$1"
	awk -F ':=' -v key="$key" '
		$1 == key {
			value = $2
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			print value
			exit
		}
	' "$SOURCE_DIR/Makefile"
}

validate_source_tree() {
	local path
	local required_paths=(
		'Makefile'
		'htdocs/luci-static/resources/internet-monitor/internet-monitor.css'
		'htdocs/luci-static/resources/view/internet-monitor/overview.js'
		'htdocs/luci-static/resources/view/internet-monitor/settings.js'
		'po/zh_Hans/internet-monitor.po'
		'root/etc/config/internet-monitor'
		'root/etc/init.d/internet-monitor'
		'root/etc/uci-defaults/90_luci-internet-monitor'
		'root/lib/upgrade/keep.d/luci-app-monitor'
		'root/usr/libexec/internet-monitor/daemon'
		'root/usr/libexec/rpcd/luci.internet-monitor'
		'root/usr/share/luci/menu.d/luci-app-monitor.json'
		'root/usr/share/rpcd/acl.d/luci-app-monitor.json'
	)

	[ "$(makefile_value PKG_VERSION)" = "$PACKAGE_VERSION" ] ||
		die "Makefile PKG_VERSION must be $PACKAGE_VERSION"
	[ "$(makefile_value PKG_RELEASE)" = "$PACKAGE_RELEASE" ] ||
		die "Makefile PKG_RELEASE must be $PACKAGE_RELEASE"
	[ "$(makefile_value LUCI_PKGARCH)" = 'all' ] ||
		die 'Makefile LUCI_PKGARCH must be all'
	grep -Fqx "include \$(TOPDIR)/feeds/luci/luci.mk" "$SOURCE_DIR/Makefile" ||
		die "Makefile must include \$(TOPDIR)/feeds/luci/luci.mk"

	for path in "${required_paths[@]}"; do
		[ -f "$SOURCE_DIR/$path" ] || die "required package file is missing: $path"
	done
}

require_host_tools() {
	local tool
	for tool in awk cp curl docker find gzip grep mkdir mv rm sort tar; do
		command -v "$tool" >/dev/null 2>&1 || die "required host tool is missing: $tool"
	done
	command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
		die 'sha256sum or shasum is required'
}

validate_output_paths() {
	case "$ROOT" in
		''|/) die 'ROOT must not be empty or /' ;;
	esac
	case "$DIST_DIR" in
		''|/|"$SOURCE_DIR") die 'DIST_DIR must not be empty, /, or the repository root' ;;
	esac
}

is_supported_version() {
	local candidate="$1"
	local version
	for version in "${SUPPORTED_VERSIONS[@]}"; do
		[ "$candidate" = "$version" ] && return 0
	done
	return 1
}

download_sdk() {
	local version="$1"
	local sdk_file sdk_url expected_sha destination partial actual_sha
	local curl_args

	sdk_file="$(sdk_file_for "$version")"
	sdk_url="$(sdk_url_for "$version")"
	expected_sha="$(sdk_sha256_for "$version")"
	destination="$ROOT/dl/$sdk_file"
	partial="$destination.part"

	if [ -s "$destination" ]; then
		actual_sha="$(sha256_file "$destination")"
		if [ "$actual_sha" = "$expected_sha" ]; then
			log "using verified cached SDK for OpenWrt $version"
			return 0
		fi
		log "discarding SDK with mismatched checksum: $destination"
		rm -f "$destination"
	fi

	rm -f "$partial"
	curl_args=(--fail --location --retry 5 --connect-timeout 20 --output "$partial")
	if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
		curl_args+=(--retry-all-errors)
	fi

	log "downloading OpenWrt $version SDK"
	if ! curl "${curl_args[@]}" "$sdk_url"; then
		rm -f "$partial"
		die "failed to download $sdk_url"
	fi

	actual_sha="$(sha256_file "$partial")"
	if [ "$actual_sha" != "$expected_sha" ]; then
		rm -f "$partial"
		die "SDK checksum mismatch for $sdk_file (expected $expected_sha, got $actual_sha)"
	fi

	mv "$partial" "$destination"
}

build_one() {
	local version="$1"
	local sdk_file openwrt_commit packages_commit luci_commit expected_package expected_i18n_package
	local expected_metadata_version package_format
	local raw_output output_count

	sdk_file="$(sdk_file_for "$version")"
	openwrt_commit="$(openwrt_commit_for "$version")"
	packages_commit="$(packages_commit_for "$version")"
	luci_commit="$(luci_commit_for "$version")"
	expected_package="$(expected_package_for "$version")"
	expected_i18n_package="$(expected_i18n_package_for "$version")"
	expected_metadata_version="$(metadata_version_for "$version")"
	package_format="$(format_for "$version")"
	raw_output="$ROOT/out/$version"

	download_sdk "$version"
	rm -rf "$raw_output"
	mkdir -p "$raw_output"

	log "building $PACKAGE_NAME for OpenWrt $version ($package_format)"
	docker run --rm -i --platform linux/amd64 \
		-v "$SOURCE_DIR:/src:ro" \
		-v "$ROOT/dl:/dl:ro" \
		-v "$ROOT/openwrt-dl:/openwrt-dl" \
		-v "$ROOT/out:/out" \
		"$BUILD_IMAGE" \
		bash -s -- \
			"$version" \
			"$sdk_file" \
			"$openwrt_commit" \
			"$packages_commit" \
			"$luci_commit" \
			"$expected_package" \
			"$expected_i18n_package" \
			"$expected_metadata_version" \
			"$package_format" \
			"$(id -u)" \
			"$(id -g)" \
			"$PACKAGE_VERSION" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

version="$1"
sdk_file="$2"
openwrt_commit="$3"
packages_commit="$4"
luci_commit="$5"
expected_package="$6"
expected_i18n_package="$7"
expected_metadata_version="$8"
package_format="$9"
output_uid="${10}"
output_gid="${11}"
package_version="${12}"
package_name='luci-app-monitor'

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	build-essential \
	ca-certificates \
	file \
	gawk \
	gettext \
	git \
	libncurses-dev \
	libssl-dev \
	python3 \
	python3-distutils \
	rsync \
	unzip \
	wget \
	xz-utils \
	zlib1g-dev \
	zstd >/dev/null

mkdir -p /tmp/sdk
case "$sdk_file" in
	*.tar.xz) tar -xJf "/dl/$sdk_file" -C /tmp/sdk --strip-components=1 ;;
	*.tar.zst) tar --zstd -xf "/dl/$sdk_file" -C /tmp/sdk --strip-components=1 ;;
	*) printf 'unsupported SDK archive: %s\n' "$sdk_file" >&2; exit 1 ;;
esac

rm -rf /tmp/sdk/dl
ln -s /openwrt-dl /tmp/sdk/dl
mkdir -p "/tmp/sdk/package/$package_name"
rsync -a --delete \
	--exclude='.git/' \
	--exclude='.github/' \
	--exclude='dist/' \
	--exclude='scripts/' \
	/src/ "/tmp/sdk/package/$package_name/"

useradd -m builder
chown -R builder:builder /tmp/sdk
if ! chown -R builder:builder /openwrt-dl; then
	chmod -R a+rwX /openwrt-dl
fi
mkdir -p "/out/$version"
if ! chown -R builder:builder "/out/$version"; then
	chmod -R a+rwX "/out/$version"
fi

cat > /tmp/build-as-user.sh <<'BUILDER_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

version="$1"
openwrt_commit="$2"
packages_commit="$3"
luci_commit="$4"
expected_package="$5"
expected_i18n_package="$6"
expected_metadata_version="$7"
package_format="$8"
package_version="$9"
package_name='luci-app-monitor'

cd /tmp/sdk

# Use only the three release-pinned feeds required by this package. Older SDKs
# do not expose the OpenWrt core tree as a named feed, so define it uniformly.
cat > feeds.conf <<EOF
src-git-full base https://git.openwrt.org/openwrt/openwrt.git^$openwrt_commit
src-git packages https://git.openwrt.org/feed/packages.git^$packages_commit
src-git luci https://git.openwrt.org/project/luci.git^$luci_commit
EOF

feed_updated=0
for attempt in 1 2 3; do
	if ./scripts/feeds update base packages luci; then
		feed_updated=1
		break
	fi
	printf 'feed update attempt %s failed\n' "$attempt" >&2
	[ "$attempt" -lt 3 ] || break
	sleep $((attempt * 3))
done
[ "$feed_updated" -eq 1 ] || { printf 'unable to update pinned feeds\n' >&2; exit 1; }

[ "$(git -C feeds/base rev-parse HEAD)" = "$openwrt_commit" ] || {
	printf 'base feed commit mismatch\n' >&2
	exit 1
}
[ "$(git -C feeds/packages rev-parse HEAD)" = "$packages_commit" ] || {
	printf 'packages feed commit mismatch\n' >&2
	exit 1
}
[ "$(git -C feeds/luci rev-parse HEAD)" = "$luci_commit" ] || {
	printf 'LuCI feed commit mismatch\n' >&2
	exit 1
}

./scripts/feeds install -p base \
	jshn rpcd jsonfilter ca-bundle
./scripts/feeds install -p packages curl cgi-io
./scripts/feeds install -p luci luci-base

printf '%s\n' \
	'CONFIG_PACKAGE_luci-app-monitor=m' \
	'CONFIG_PACKAGE_luci-i18n-monitor-zh-cn=m' \
	'CONFIG_LUCI_LANG_zh_Hans=m' > .config
make PKG_PO_VERSION="$expected_metadata_version" defconfig >/dev/null
grep -Fqx 'CONFIG_PACKAGE_luci-app-monitor=m' .config || {
	printf 'luci-app-monitor was not selected; check runtime dependencies\n' >&2
	exit 1
}
grep -Fqx 'CONFIG_PACKAGE_luci-i18n-monitor-zh-cn=m' .config || {
	printf 'Simplified Chinese translation package was not selected\n' >&2
	exit 1
}

make PKG_PO_VERSION="$expected_metadata_version" package/luci-app-monitor/clean V=s
make PKG_PO_VERSION="$expected_metadata_version" package/luci-app-monitor/compile V=s -j1

artifact_count="$(find bin -type f \( \
	-name 'luci-app-monitor_*.ipk' -o \
	-name 'luci-app-monitor-*.apk' -o \
	-name 'luci-i18n-monitor-zh-cn_*.ipk' -o \
	-name 'luci-i18n-monitor-zh-cn-*.apk' \
\) -print | wc -l | tr -d '[:space:]')"
[ "$artifact_count" -eq 2 ] || {
	printf 'expected exactly two monitor packages, found %s\n' "$artifact_count" >&2
	find bin -type f \( \
		-name 'luci-app-monitor_*.ipk' -o \
		-name 'luci-app-monitor-*.apk' -o \
		-name 'luci-i18n-monitor-zh-cn_*.ipk' -o \
		-name 'luci-i18n-monitor-zh-cn-*.apk' \
	\) -print >&2
	exit 1
}

artifact="$(find bin -type f -name "$expected_package" -print -quit)"
[ -n "$artifact" ] && [ -s "$artifact" ] || {
	printf 'expected package was not produced: %s\n' "$expected_package" >&2
	exit 1
}
i18n_artifact="$(find bin -type f -name "$expected_i18n_package" -print -quit)"
[ -n "$i18n_artifact" ] && [ -s "$i18n_artifact" ] || {
	printf 'expected translation package was not produced: %s\n' "$expected_i18n_package" >&2
	exit 1
}

validate_dependencies() {
	local metadata="$1"
	local dependency
	for dependency in luci-base rpcd jshn jsonfilter curl ca-bundle; do
		grep -Fq "$dependency" "$metadata" || {
			printf 'package metadata is missing dependency: %s\n' "$dependency" >&2
			exit 1
		}
	done
}

validate_no_native_payload() {
	local data_dir="$1"
	local path description relative_path
	while IFS= read -r -d '' path; do
		description="$(LC_ALL=C file --brief -- "$path")"
		case "$description" in
			ELF\ *)
				relative_path="${path#"$data_dir"/}"
				printf 'architecture-independent package contains ELF payload: /%s\n' \
					"$relative_path" >&2
				exit 1
			;;
		esac
	done < <(find "$data_dir" -type f -print0)
}

validate_ipk() {
	local package="$1"
	local expected_name="$2"
	local expected_version="$3"
	local package_kind="$4"
	local work outer_list outer_count member normalized_member
	local control_archive data_archive control_dir data_dir metadata path
	package="$(readlink -f "$package")"
	work="$(mktemp -d)"
	outer_list="$work/outer.list"
	control_dir="$work/control"
	data_dir="$work/data"
	mkdir -p "$control_dir" "$data_dir"
	if ! tar -tzf "$package" > "$outer_list"; then
		printf 'invalid OpenWrt IPK gzip/tar container\n' >&2
		exit 1
	fi
	outer_count=0
	while IFS= read -r member; do
		normalized_member="${member#./}"
		case "$normalized_member" in
			debian-binary|control.tar.*|data.tar.*) ;;
			*)
				printf 'invalid OpenWrt IPK outer member: %s\n' "$member" >&2
				exit 1
			;;
		esac
		outer_count=$((outer_count + 1))
	done < "$outer_list"
	[ "$outer_count" -eq 3 ] || {
		printf 'invalid OpenWrt IPK outer member count: %s\n' "$outer_count" >&2
		exit 1
	}
	tar -xzf "$package" -C "$work"
	control_archive="$(find "$work" -maxdepth 1 -type f -name 'control.tar.*' -print -quit)"
	data_archive="$(find "$work" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)"
	if [ ! -f "$work/debian-binary" ] || \
		[ "$(tr -d '\r\n' < "$work/debian-binary" 2>/dev/null)" != '2.0' ] || \
		[ -z "$control_archive" ] || [ -z "$data_archive" ]; then
		printf 'invalid IPK archive structure\n' >&2
		exit 1
	fi
	tar -xf "$control_archive" -C "$control_dir"
	tar -xf "$data_archive" -C "$data_dir"
	metadata="$control_dir/control"
	grep -Fqx "Package: $expected_name" "$metadata"
	grep -Fqx 'Architecture: all' "$metadata"
	grep -Fqx "Version: $expected_version" "$metadata"
	case "$package_kind" in
		main)
			validate_dependencies "$metadata"
			for path in \
				etc/config/internet-monitor \
				etc/init.d/internet-monitor \
				etc/uci-defaults/90_luci-internet-monitor \
				lib/upgrade/keep.d/luci-app-monitor \
				usr/libexec/internet-monitor/daemon \
				usr/libexec/rpcd/luci.internet-monitor \
				usr/share/luci/menu.d/luci-app-monitor.json \
				usr/share/rpcd/acl.d/luci-app-monitor.json \
				www/luci-static/resources/view/internet-monitor/overview.js \
				www/luci-static/resources/view/internet-monitor/settings.js \
				www/luci-static/resources/internet-monitor/internet-monitor.css
			do
				[ -f "$data_dir/$path" ] || {
					printf 'IPK is missing required file: /%s\n' "$path" >&2
					exit 1
				}
			done
		;;
		i18n)
			grep -Fq 'luci-app-monitor' "$metadata" || {
				printf 'translation package does not depend on luci-app-monitor\n' >&2
				exit 1
			}
			for path in \
				etc/uci-defaults/luci-i18n-monitor-zh-cn \
				usr/lib/lua/luci/i18n/internet-monitor.zh-cn.lmo
			do
				[ -f "$data_dir/$path" ] || {
					printf 'translation IPK is missing required file: /%s\n' "$path" >&2
					exit 1
				}
			done
		;;
		*) printf 'unknown IPK package kind: %s\n' "$package_kind" >&2; exit 1 ;;
	esac
	validate_no_native_payload "$data_dir"
	rm -rf "$work"
}

validate_apk() {
	local package="$1"
	local expected_name="$2"
	local expected_version="$3"
	local package_kind="$4"
	local apk_tool work metadata data_dir path
	apk_tool="$(find staging_dir/host -type f -path '*/bin/apk' -print -quit)"
	[ -n "$apk_tool" ] && [ -x "$apk_tool" ] || {
		printf 'SDK apk tool was not found\n' >&2
		exit 1
	}
	work="$(mktemp -d)"
	metadata="$work/metadata"
	data_dir="$work/data"
	mkdir -p "$data_dir"
	"$apk_tool" adbdump "$package" > "$metadata"
	grep -Fq "$expected_name" "$metadata"
	grep -Fq "$expected_version" "$metadata"
	grep -Eq '(^|[^[:alnum:]_])noarch([^[:alnum:]_]|$)' "$metadata"
	"$apk_tool" extract \
		--allow-untrusted \
		--no-chown \
		--destination "$data_dir" \
		"$package" >/dev/null
	case "$package_kind" in
		main)
			validate_dependencies "$metadata"
			for path in \
				etc/config/internet-monitor \
				etc/init.d/internet-monitor \
				etc/uci-defaults/90_luci-internet-monitor \
				lib/upgrade/keep.d/luci-app-monitor \
				usr/libexec/internet-monitor/daemon \
				usr/libexec/rpcd/luci.internet-monitor \
				usr/share/luci/menu.d/luci-app-monitor.json \
				usr/share/rpcd/acl.d/luci-app-monitor.json \
				www/luci-static/resources/view/internet-monitor/overview.js \
				www/luci-static/resources/view/internet-monitor/settings.js \
				www/luci-static/resources/internet-monitor/internet-monitor.css
			do
				[ -f "$data_dir/$path" ] || {
					printf 'APK is missing required file: /%s\n' "$path" >&2
					exit 1
				}
			done
		;;
		i18n)
			grep -Fq 'luci-app-monitor' "$metadata" || {
				printf 'translation APK does not depend on luci-app-monitor\n' >&2
				exit 1
			}
			for path in \
				etc/uci-defaults/luci-i18n-monitor-zh-cn \
				usr/lib/lua/luci/i18n/internet-monitor.zh-cn.lmo
			do
				[ -f "$data_dir/$path" ] || {
					printf 'translation APK is missing required file: /%s\n' "$path" >&2
					exit 1
				}
			done
		;;
		*) printf 'unknown APK package kind: %s\n' "$package_kind" >&2; exit 1 ;;
	esac
	validate_no_native_payload "$data_dir"
	rm -rf "$work"
}

case "$package_format" in
	ipk)
		validate_ipk "$artifact" 'luci-app-monitor' "$expected_metadata_version" main
		validate_ipk "$i18n_artifact" 'luci-i18n-monitor-zh-cn' "$expected_metadata_version" i18n
	;;
	apk)
		validate_apk "$artifact" 'luci-app-monitor' "$expected_metadata_version" main
		validate_apk "$i18n_artifact" 'luci-i18n-monitor-zh-cn' "$expected_metadata_version" i18n
	;;
	*) printf 'unsupported package format: %s\n' "$package_format" >&2; exit 1 ;;
esac

mkdir -p "/out/$version"
install -m 0644 "$artifact" "/out/$version/$expected_package"
install -m 0644 "$i18n_artifact" "/out/$version/$expected_i18n_package"
BUILDER_SCRIPT

chmod 0755 /tmp/build-as-user.sh
runuser -u builder -- /tmp/build-as-user.sh \
	"$version" \
	"$openwrt_commit" \
	"$packages_commit" \
	"$luci_commit" \
	"$expected_package" \
	"$expected_i18n_package" \
	"$expected_metadata_version" \
	"$package_format" \
	"$package_version"

if ! chown -R "$output_uid:$output_gid" "/out/$version" /openwrt-dl; then
	chmod -R a+rwX "/out/$version" /openwrt-dl
fi
CONTAINER_SCRIPT

	output_count="$(find "$raw_output" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
	[ "$output_count" -eq 2 ] || die "expected two raw artifacts for $version, found $output_count"
	[ -s "$raw_output/$expected_package" ] || die "missing expected artifact: $expected_package"
	[ -s "$raw_output/$expected_i18n_package" ] || die "missing expected artifact: $expected_i18n_package"
	cp "$raw_output/$expected_package" "$DIST_DIR/$expected_package"
	cp "$raw_output/$expected_i18n_package" "$DIST_DIR/$expected_i18n_package"

	COPYFILE_DISABLE=1 tar -czf "$DIST_DIR/$(archive_name_for "$version")" \
		-C "$raw_output" "$expected_package" "$expected_i18n_package"
	gzip -t "$DIST_DIR/$(archive_name_for "$version")"
}

contains_all_versions() {
	local wanted version found selected_version
	[ "$#" -eq "${#SUPPORTED_VERSIONS[@]}" ] || return 1
	for wanted in "${SUPPORTED_VERSIONS[@]}"; do
		found=0
		for selected_version in "$@"; do
			[ "$wanted" = "$selected_version" ] && found=1
		done
		[ "$found" -eq 1 ] || return 1
	done
	return 0
}

create_combined_archive() {
	local stage="$ROOT/release-tree"
	local version expected_package expected_i18n_package
	rm -rf "$stage"
	mkdir -p "$stage"
	for version in "$@"; do
		expected_package="$(expected_package_for "$version")"
		expected_i18n_package="$(expected_i18n_package_for "$version")"
		mkdir -p "$stage/$version"
		cp "$ROOT/out/$version/$expected_package" "$stage/$version/$expected_package"
		cp "$ROOT/out/$version/$expected_i18n_package" "$stage/$version/$expected_i18n_package"
	done
	COPYFILE_DISABLE=1 tar -czf "$DIST_DIR/$PACKAGE_NAME-openwrt-all-v$PACKAGE_VERSION.tar.gz" \
		-C "$stage" .
	gzip -t "$DIST_DIR/$PACKAGE_NAME-openwrt-all-v$PACKAGE_VERSION.tar.gz"
}

create_checksums() {
	local list_file="$ROOT/release-files.txt"
	local checksum_file="$DIST_DIR/SHA256SUMS"
	local file name expected actual

	: > "$list_file"
	for file in "$DIST_DIR"/*; do
		[ -f "$file" ] || continue
		name="${file##*/}"
		[ "$name" = 'SHA256SUMS' ] && continue
		printf '%s\n' "$name" >> "$list_file"
	done
	LC_ALL=C sort -o "$list_file" "$list_file"

	: > "$checksum_file.tmp"
	while IFS= read -r name; do
		printf '%s  %s\n' "$(sha256_file "$DIST_DIR/$name")" "$name" >> "$checksum_file.tmp"
	done < "$list_file"
	mv "$checksum_file.tmp" "$checksum_file"

	while IFS=' ' read -r expected name; do
		[ -n "$expected" ] && [ -n "$name" ] || die 'invalid SHA256SUMS entry'
		actual="$(sha256_file "$DIST_DIR/$name")"
		[ "$actual" = "$expected" ] || die "checksum verification failed for $name"
	done < "$checksum_file"
}

main() {
	local arg existing version expected_non_checksum actual_non_checksum actual_total
	local selected_versions=()

	case "${1:-}" in
		-h|--help) usage; exit 0 ;;
		--list) validate_source_tree; list_matrix; exit 0 ;;
	esac

	validate_source_tree
	require_host_tools
	validate_output_paths

	if [ "$#" -eq 0 ]; then
		selected_versions=("${SUPPORTED_VERSIONS[@]}")
	else
		for arg in "$@"; do
			is_supported_version "$arg" || die "unsupported OpenWrt version: $arg"
			for existing in ${selected_versions[@]+"${selected_versions[@]}"}; do
				[ "$existing" != "$arg" ] || die "duplicate OpenWrt version: $arg"
			done
			selected_versions+=("$arg")
		done
	fi

	mkdir -p "$ROOT/dl" "$ROOT/openwrt-dl" "$ROOT/out"
	rm -rf "$DIST_DIR"
	mkdir -p "$DIST_DIR"

	for version in "${selected_versions[@]}"; do
		build_one "$version"
	done

	if contains_all_versions "${selected_versions[@]}"; then
		create_combined_archive "${SUPPORTED_VERSIONS[@]}"
		expected_non_checksum=$((${#selected_versions[@]} * 3 + 1))
	else
		expected_non_checksum=$((${#selected_versions[@]} * 3))
	fi

	create_checksums
	actual_non_checksum="$(find "$DIST_DIR" -maxdepth 1 -type f ! -name SHA256SUMS | wc -l | tr -d '[:space:]')"
	actual_total="$(find "$DIST_DIR" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
	[ "$actual_non_checksum" -eq "$expected_non_checksum" ] ||
		die "release asset count mismatch: expected $expected_non_checksum data files, found $actual_non_checksum"
	[ "$actual_total" -eq $((expected_non_checksum + 1)) ] ||
		die "release asset count mismatch after SHA256SUMS generation"

	log "release assets are ready in $DIST_DIR"
	find "$DIST_DIR" -maxdepth 1 -type f -print | LC_ALL=C sort
}

main "$@"
