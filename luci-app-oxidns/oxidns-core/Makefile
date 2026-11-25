#
# Copyright (C) 2026 NetForgeCN
#
# This is free software, licensed under the GNU General Public License v3 or later.
# See /LICENSE for more information.
#
# Bundles the official OxiDNS core release (prebuilt musl binary + webui +
# default config) into the firmware / package. The release archive matching
# the build target architecture is downloaded at compile time, so the
# resulting image ships with a working DNS core out of the box. The core is
# installed to the persistent area (/etc/oxidns/core) so it survives
# sysupgrade when "keep settings" is used.
#
# When a new OxiDNS core is released, bump PKG_VERSION and refresh every
# OXIDNS_PKG_HASH below from the matching release asset's SHA256 (check the
# v$(PKG_VERSION) release page / `sha256sum oxidns-<target>.tar.gz`). A stale
# hash fails the download verification instead of shipping a binary whose
# provenance cannot be checked. The LuCI "Check Update" page is not limited to
# this pinned version.
#
# Bundle choice: this pins the "full" assets (unsuffixed oxidns-<target>.tar.gz).
# OxiDNS 1.7 also publishes oxidns-standard-* and oxidns-minimal-*, but only
# for x86_64/aarch64, and "minimal" drops executors such as arbitrary/response.
# Staying on "full" keeps every architecture on the same feature set.
#
# TARGET MAP (mirrored in root/usr/share/oxidns/targets.json; scripts/check.sh
# cross-checks these rows so runtime detection and buildroot agree):
#   x86_64             -> x86_64-unknown-linux-musl
#   aarch64            -> aarch64-unknown-linux-musl
#   i386               -> i686-unknown-linux-musl
#   arm (cortex, hf)   -> armv7-unknown-linux-musleabihf
#   arm (other, hf)    -> arm-unknown-linux-musleabihf
# Soft-float ARM targets are unsupported: the published assets are hard-float
# (eabihf), so installing one would silently produce an unusable binary.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=oxidns-core
PKG_VERSION:=1.7.1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
# The bundled release archive carries the upstream GPL-3.0 license text.
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=NetForgeCN

# NOTE: PKG_SOURCE_URL is declared conditionally near the end of this file.
# package.mk invokes Download/default whenever PKG_SOURCE_URL is non-empty,
# and that macro requires PKG_SOURCE to be non-empty as well. Feed metadata
# collection runs before the target ARCH is defined, so an unconditional URL
# here would make the whole package fail to parse at index generation time
# with "Download/default is missing the FILE field".

# Map OpenWrt ARCH / CPU_TYPE to OxiDNS release targets. CONFIG_SOFTFLOAT is
# provided by the buildroot target configuration; soft-float ARM must not be
# given a hard-float (eabihf) asset.
ifeq ($(ARCH),x86_64)
  OXIDNS_RUST_TARGET:=x86_64-unknown-linux-musl
  OXIDNS_PKG_HASH:=6c82984e477d70d0c9259a6c7997496e248c78a384b2b7585908bba7f4af854c
else ifeq ($(ARCH),aarch64)
  OXIDNS_RUST_TARGET:=aarch64-unknown-linux-musl
  OXIDNS_PKG_HASH:=2e58721f840c3a4f1b92ed953857f14a65d2e825f8072917c262f7e34e2f21bd
else ifeq ($(ARCH),i386)
  OXIDNS_RUST_TARGET:=i686-unknown-linux-musl
  OXIDNS_PKG_HASH:=453ad3f7a975183ea084a3d72cedf7a6701c881df1ffa6dfd37ddc0f32b24d93
else ifeq ($(ARCH),arm)
  ifeq ($(CONFIG_SOFTFLOAT),y)
    OXIDNS_RUST_TARGET:=unsupported-arch
    OXIDNS_PKG_HASH:=skip
  else ifneq ($(findstring cortex,$(CPU_TYPE)),)
    OXIDNS_RUST_TARGET:=armv7-unknown-linux-musleabihf
    OXIDNS_PKG_HASH:=ea9c078d5eb2bbddf0b545e5959c687bb5b5a4e6e7b8ba326deb4386fd4e54bd
  else
    OXIDNS_RUST_TARGET:=arm-unknown-linux-musleabihf
    OXIDNS_PKG_HASH:=3f43e2eaab61682fcbc8de1ed5a37a2f5fab0611f5e3c0ad032e65b2570c5d83
  endif
else
  OXIDNS_RUST_TARGET:=unsupported-arch
  OXIDNS_PKG_HASH:=skip
endif

# Register the download target only for a recognised target architecture.
# PKG_SOURCE_URL must live inside the same guard as PKG_SOURCE: package.mk
# calls Download/default whenever PKG_SOURCE_URL is non-empty, and that macro
# derives FILE from PKG_SOURCE. At feed index generation time ARCH is not yet
# defined, so a URL without a matching source archive makes the whole package
# fail to parse. On an unsupported target the package is not selectable anyway.
ifneq ($(OXIDNS_PKG_HASH),skip)
  PKG_SOURCE_URL:=https://github.com/svenshi/oxidns/releases/download/v$(PKG_VERSION)/
  PKG_SOURCE:=oxidns-$(OXIDNS_RUST_TARGET).tar.gz
  PKG_HASH:=$(OXIDNS_PKG_HASH)
endif

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/oxidns-core
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=DNS
  TITLE:=OxiDNS core (prebuilt musl binary, bundled at compile time)
  DEPENDS:=@(!SOFTFLOAT&&(x86_64||aarch64||i386||arm))
endef

define Package/oxidns-core/description
  Bundles the official OxiDNS core release for the build target architecture
  ($(OXIDNS_RUST_TARGET)). Installs the binary and webui to the persistent
  area /etc/oxidns/core so they survive firmware upgrades, and links them
  into /usr/bin and /usr/share/oxidns. Upgrades can later be applied from
  the luci-app-oxidns "Check Update" page. Soft-float ARM is not supported.
endef

# The OxiDNS release tarball has multiple top-level entries (oxidns,
# config.yaml, LICENSE, webui/) instead of a single root directory, so the
# default PKG_UNPACK (which strips the first path component) would destroy
# it. Extract without stripping instead.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	tar -C $(PKG_BUILD_DIR) -xzf $(DL_DIR)/$(PKG_SOURCE)
	@if command -v file >/dev/null 2>&1; then \
		file "$(PKG_BUILD_DIR)/oxidns" | grep -q 'ELF' || { \
			echo "ERROR: bundled oxidns is not an ELF binary" >&2; exit 1; \
		}; \
	fi
	@if command -v readelf >/dev/null 2>&1; then \
		case "$(OXIDNS_RUST_TARGET)" in \
			x86_64*) expected='X86-64|Advanced Micro Devices|AMD|amd64' ;; \
			aarch64*) expected='AArch64|aarch64|ARM64|arm64' ;; \
			i686*) expected='Intel 80386|i386|i686|x86' ;; \
			arm*) expected='ARM|arm' ;; \
			*) exit 0 ;; \
		esac; \
		machine_info="$$(readelf -h "$(PKG_BUILD_DIR)/oxidns" 2>/dev/null || true)"; \
		if printf '%s\n' "$$machine_info" | grep -Eqi "$$expected"; then \
			:; \
		elif printf '%s\n' "$$machine_info" | grep -Eqi 'X86-64|Advanced Micro Devices|AMD|aarch64|ARM64|Intel 80386|i386|i686|ARM'; then \
			echo "ERROR: bundled oxidns ABI does not match $(OXIDNS_RUST_TARGET)" >&2; exit 1; \
		else \
			echo "WARNING: readelf did not report a recognizable machine type; skipping ABI check for $(OXIDNS_RUST_TARGET)" >&2; \
		fi; \
	fi
endef

define Build/Compile
endef

define Package/oxidns-core/conffiles
/etc/oxidns/config.yaml
endef

define Package/oxidns-core/install
	$(INSTALL_DIR) \
		$(1)/etc/oxidns/core \
		$(1)/usr/bin \
		$(1)/usr/share/oxidns

	$(INSTALL_BIN) $(PKG_BUILD_DIR)/oxidns $(1)/etc/oxidns/core/oxidns
	$(CP) $(PKG_BUILD_DIR)/webui $(1)/etc/oxidns/core/webui
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/config.yaml $(1)/etc/oxidns/config.yaml

	$(LN) /etc/oxidns/core/oxidns $(1)/usr/bin/oxidns
	$(LN) /etc/oxidns/core/webui $(1)/usr/share/oxidns/webui
endef

define Package/oxidns-core/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
# Keep the core across firmware upgrades.
if [ -f /etc/sysupgrade.conf ]; then
	for entry in /etc/oxidns /etc/config/oxidns; do
		grep -qxF "$$entry" /etc/sysupgrade.conf 2>/dev/null || \
			echo "$$entry" >> /etc/sysupgrade.conf
	done
fi
# Self-heal after a firmware upgrade: relink if the persistent copy survived.
if [ -x /etc/oxidns/core/oxidns ] && [ ! -x /usr/bin/oxidns ]; then
	mkdir -p /usr/bin
	ln -sf /etc/oxidns/core/oxidns /usr/bin/oxidns
fi
if [ -d /etc/oxidns/core/webui ] && [ ! -d /usr/share/oxidns/webui ]; then
	mkdir -p /usr/share/oxidns
	ln -sfn /etc/oxidns/core/webui /usr/share/oxidns/webui
fi
exit 0
endef

$(eval $(call BuildPackage,oxidns-core))
