#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() {
	printf '[check] %s\n' "$*"
}

die() {
	printf '[check] error: %s\n' "$*" >&2
	exit 1
}

require_tool() {
	command -v "$1" >/dev/null 2>&1 || die "required tool is missing: $1"
}

cd "$SOURCE_DIR"

for tool in bash git node python3 ruby sh shellcheck; do
	require_tool "$tool"
done

required_files=(
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
	'scripts/build-openwrt-packages.sh'
	'.github/workflows/ci.yml'
	'.github/workflows/release.yml'
)

for path in "${required_files[@]}"; do
	[ -s "$path" ] || die "required file is missing or empty: $path"
done

for path in \
	root/etc/init.d/internet-monitor \
	root/etc/uci-defaults/90_luci-internet-monitor \
	root/usr/libexec/internet-monitor/daemon \
	root/usr/libexec/rpcd/luci.internet-monitor \
	scripts/build-openwrt-packages.sh \
	scripts/check-static.sh
do
	[ -x "$path" ] || die "required executable bit is missing: $path"
done

log 'checking package metadata'
grep -Fqx 'PKG_VERSION:=1.1.1' Makefile || die 'PKG_VERSION must be 1.1.1'
grep -Fqx 'PKG_RELEASE:=1' Makefile || die 'PKG_RELEASE must be 1'
grep -Fqx 'LUCI_PKGARCH:=all' Makefile || die 'LUCI_PKGARCH must be all'
grep -Fqx 'include $(TOPDIR)/feeds/luci/luci.mk' Makefile || die 'luci.mk include is missing'
for dependency in luci-base rpcd jshn jsonfilter curl ca-bundle; do
	grep -Eq "^LUCI_DEPENDS:=.*\\+$dependency([[:space:]]|$)" Makefile ||
		die "LUCI_DEPENDS is missing +$dependency"
done

log 'checking shell syntax'
while IFS= read -r -d '' path; do
	case "$(head -n 1 "$path")" in
		'#!/bin/sh'*) sh -n "$path" ;;
		'#!/usr/bin/env bash'*|'#!/bin/bash'*) bash -n "$path" ;;
	esac
done < <(find root scripts -type f -print0)

shellcheck -x -s sh \
	root/etc/init.d/internet-monitor \
	root/etc/uci-defaults/90_luci-internet-monitor \
	root/usr/libexec/internet-monitor/daemon \
	root/usr/libexec/rpcd/luci.internet-monitor

log 'running unit tests'
python3 -W error::ResourceWarning -m unittest discover -s tests -v

log 'checking JSON documents'
python3 - \
	root/usr/share/luci/menu.d/luci-app-monitor.json \
	root/usr/share/rpcd/acl.d/luci-app-monitor.json <<'PYTHON'
import json
import pathlib
import sys

for value in sys.argv[1:]:
    path = pathlib.Path(value)
    with path.open("r", encoding="utf-8") as handle:
        document = json.load(handle)
    if not isinstance(document, dict) or not document:
        raise SystemExit(f"{path}: expected a non-empty JSON object")
PYTHON

log 'checking LuCI JavaScript syntax'
while IFS= read -r -d '' path; do
	node --check "$path"
done < <(find htdocs -type f -name '*.js' -print0)

log 'checking workflow YAML syntax'
ruby -e '
  require "psych"
  ARGV.each { |path| Psych.parse_file(path) || abort("#{path}: empty YAML") }
' .github/workflows/ci.yml .github/workflows/release.yml

if grep -ERn 'uses:[[:space:]]+[^[:space:]]+@(main|master|v[0-9]+)([[:space:]]|$)' .github/workflows; then
	die 'GitHub Actions must be pinned to immutable commit SHAs'
fi

log 'checking pinned OpenWrt build matrix'
matrix="$(scripts/build-openwrt-packages.sh --list)"
[ "$(printf '%s\n' "$matrix" | wc -l | tr -d '[:space:]')" -eq 4 ] ||
	die 'build matrix must contain exactly three releases'
for expected in \
	$'23.05.6\tipk\tf22bdac5b702bb823a0ee802e9bbda2a56c0f7a2687e5090113b00910dac995f' \
	$'24.10.7\tipk\t996d71f9eab7df2e8acb0bb2c9726426f05c10d419e5f9600d59b14d871f2acb' \
	$'25.12.5\tapk\t0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c'
do
	printf '%s\n' "$matrix" | grep -Fq "$expected" || die "build matrix entry is missing: $expected"
done

grep -Fq "tags:" .github/workflows/release.yml || die 'release workflow has no tag trigger'
grep -Fq "gh release" .github/workflows/release.yml || die 'release workflow does not publish a GitHub Release'
grep -Fq "scripts/build-openwrt-packages.sh" .github/workflows/release.yml ||
	die 'release workflow does not invoke the SDK build'

git diff --check
log 'all static checks passed'
