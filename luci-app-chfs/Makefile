#
# Copyright (C) 2026 LianXia233
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for chfs (CuteHttpFileServer)
LUCI_DEPENDS:=+chfs +rpcd +rpcd-mod-ucode +ucode +ucode-mod-fs +ucode-mod-uci
LUCI_PKGARCH:=all
LUCI_DESCRIPTION:=chfs (CuteHttpFileServer) 的 LuCI 管理界面, 支持端口与共享目录配置、\
	账户权限与访问规则、IP 黑白名单、日志与开机自启管理.

PKG_NAME:=luci-app-chfs
PKG_VERSION:=1.0.0
PKG_RELEASE:=6

PKG_MAINTAINER:=LianXia233
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/luci/luci.mk

# 显式修正包内可执行位.
#
# 背景: luci.mk 的 Package/$(PKG_NAME)/install 用 `cp -pR $(PKG_BUILD_DIR)/root/*`
# 保留源文件权限. 但本仓库在 Windows 上开发 (git core.filemode=false), 可执行位
# 无法写进 git 索引, 检出后这些脚本是 0644, 装到设备后:
#   /etc/init.d/chfs: Permission denied            (postinst 无法调用 init 脚本)
#   rpcd 不加载 /usr/share/rpcd/ucode/luci.chfs    (无执行位不被视为可加载模块)
#
# 不能重定义 Package/$(PKG_NAME)/install —— luci.mk 已无条件定义它, 覆盖会连带
# 丢掉 htdocs/root 的拷贝逻辑. 正确做法是使用 install_lib 钩子:
# include/package-pack.mk 第 156-157 行的规则是
#   $(call Package/$(1)/install,$(PKG_BUILD_DIR)/.pkgdir/$(1))
#   $(call Package/$(1)/install_lib,$(PKG_BUILD_DIR)/.pkgdir/$(1))
# 即在 install 之后、打包之前向 .pkgdir 追加内容, 恰是打 chmod 的位置.
define Package/luci-app-chfs/install_lib
	chmod 0755 $(1)/etc/init.d/chfs
	chmod 0755 $(1)/etc/uci-defaults/99-luci-app-chfs
	chmod 0755 $(1)/usr/share/rpcd/ucode/luci.chfs
endef

# 兼容 luci.mk 的两代调用签名:
#   - openwrt-21.02 及更早: $(eval $(call BuildPackage,$(PKG_NAME)))
#   - openwrt-22.03 及更新: $(eval $(call BuildPackage,luci-app-chfs))
# luci.mk 内部对两种写法均做了兼容处理, 此处沿用主流写法.
$(eval $(call BuildPackage,luci-app-chfs))
