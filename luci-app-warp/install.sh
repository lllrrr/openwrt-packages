#!/bin/sh
# One-shot installer for luci-app-warp with cloudflare-warp and ipt2socks.
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/hxzlplp7/luci-app-warp/main}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
	printf '%b\n' "${BLUE}==>${NC} $*"
}

ok() {
	printf '%b\n' "${GREEN}OK:${NC} $*"
}

warn() {
	printf '%b\n' "${YELLOW}WARN:${NC} $*"
}

die() {
	printf '%b\n' "${RED}ERROR:${NC} $*" >&2
	exit 1
}

download() {
	url="$1"
	dest="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fL --connect-timeout 15 --retry 2 "$url" -o "$dest"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$dest" "$url"
	else
		die "curl or wget is required"
	fi
}

check_system() {
	[ "$(id -u)" = "0" ] || die "run this installer as root"
	[ -f /etc/openwrt_release ] || die "this installer only supports OpenWrt"

	. /etc/openwrt_release
	ok "detected ${DISTRIB_DESCRIPTION:-OpenWrt}"
}

install_opkg_packages() {
	log "installing OpenWrt packages"
	if ! opkg update; then
		warn "opkg update reported errors; continuing with the package lists that are available"
	fi

	install_opkg_package luci-base
	install_opkg_package ca-bundle
	install_opkg_package jsonfilter
	install_opkg_package unzip
	install_opkg_package curl optional || \
		warn "curl was not installed; WARP connection test commands may be unavailable"

	install_opkg_package kmod-nft-tproxy optional || \
		warn "kmod-nft-tproxy was not installed; global transparent proxy mode may be unavailable"
}

opkg_package_installed() {
	opkg status "$1" 2>/dev/null | grep -q "^Status: .* installed"
}

install_opkg_package() {
	pkg="$1"
	mode="${2:-required}"

	if opkg_package_installed "$pkg"; then
		return 0
	fi

	if opkg install "$pkg" >/dev/null; then
		return 0
	fi

	if [ "$mode" = "optional" ]; then
		return 1
	fi
	die "failed to install required package: $pkg"
}

get_asset_arch() {
	case "$(uname -m)" in
		x86_64)
			printf '%s\n' "amd64"
			;;
		aarch64|arm64)
			printf '%s\n' "arm64"
			;;
		armv7*|armv7l)
			printf '%s\n' "armv7"
			;;
		armv6*|armv6l)
			printf '%s\n' "armv6"
			;;
		armv5*|armv5l)
			printf '%s\n' "armv5"
			;;
		mips|mipsel)
			printf '%s\n' "mipsle"
			;;
		*)
			return 1
			;;
	esac
}

install_warp_binaries() {
	if command -v warp >/dev/null 2>&1 && command -v ipt2socks >/dev/null 2>&1; then
		ok "warp and ipt2socks are already installed"
		return
	fi

	asset_arch="$(get_asset_arch)" || die "unsupported architecture $(uname -m); please build warp and ipt2socks manually and place them in /usr/bin/"
	
	log "Note: Pre-compiled binaries for cloudflare-warp may not be available on GitHub releases yet."
	warn "You may need to cross-compile cloudflare-warp and ipt2socks manually and place them in /usr/bin/"
	
	if [ ! -f "/usr/bin/warp" ]; then
		warn "warp binary not found at /usr/bin/warp."
	else
		ok "warp binary found."
	fi

	if [ ! -f "/usr/bin/ipt2socks" ]; then
		warn "ipt2socks binary not found at /usr/bin/ipt2socks."
	else
		ok "ipt2socks binary found."
	fi
}

install_app() {
	log "installing luci-app-warp files"

	mkdir -p /etc/warp
	mkdir -p /etc/config
	mkdir -p /etc/init.d
	mkdir -p /usr/bin
	mkdir -p /usr/share/luci/menu.d
	mkdir -p /usr/share/rpcd/acl.d
	mkdir -p /www/luci-static/resources/view/warp

	download "$REPO_RAW/root/usr/bin/warp-manager" /usr/bin/warp-manager
	download "$REPO_RAW/root/usr/bin/warp-update-china" /usr/bin/warp-update-china
	download "$REPO_RAW/root/usr/bin/warp-log" /usr/bin/warp-log
	download "$REPO_RAW/root/etc/init.d/warp" /etc/init.d/warp
	download "$REPO_RAW/root/etc/init.d/warp-cron" /etc/init.d/warp-cron

	if [ ! -f /etc/config/warp ]; then
		download "$REPO_RAW/root/etc/config/warp" /etc/config/warp
	else
		warn "kept existing /etc/config/warp"
	fi

	download "$REPO_RAW/root/usr/share/luci/menu.d/luci-app-warp.json" /usr/share/luci/menu.d/luci-app-warp.json
	download "$REPO_RAW/root/usr/share/rpcd/acl.d/luci-app-warp.json" /usr/share/rpcd/acl.d/luci-app-warp.json
	download "$REPO_RAW/htdocs/luci-static/resources/view/warp/status.js" /www/luci-static/resources/view/warp/status.js
	download "$REPO_RAW/htdocs/luci-static/resources/view/warp/settings.js" /www/luci-static/resources/view/warp/settings.js
	download "$REPO_RAW/htdocs/luci-static/resources/view/warp/log.js" /www/luci-static/resources/view/warp/log.js

	chmod 0755 /usr/bin/warp-manager /usr/bin/warp-update-china /usr/bin/warp-log
	chmod 0755 /etc/init.d/warp /etc/init.d/warp-cron

	/etc/init.d/warp enable >/dev/null 2>&1 || true
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

	ok "luci-app-warp files installed"
}

register_account() {
	[ -t 0 ] || {
		warn "skipping interactive registration because stdin is not a terminal"
		return
	}

	printf 'Register a WARP account now? [y/N] '
	read -r choice
	case "$choice" in
		y|Y|yes|YES)
			/usr/bin/warp-manager register
			;;
		*)
			warn "skipped registration; run 'warp-manager register' later"
			;;
	esac
}

main() {
	check_system
	install_opkg_packages
	install_warp_binaries
	install_app
	register_account

	printf '\n%b\n' "${GREEN}Installation complete.${NC}"
	printf '%s\n' "LuCI: Services -> Cloudflare WARP"
	printf '%s\n' "CLI : warp-manager register && /etc/init.d/warp start"
}

main "$@"
