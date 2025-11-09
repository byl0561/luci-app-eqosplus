#
# Copyright (C) 2006-2017 OpenWrt.org
# Copyright (C) 2022-2023 sirpdboy <herboy2008@gmail.com>
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-eqosplus
PKG_VERSION:=2.1.0
PKG_RELEASE:=2

LUCI_TITLE:=LuCI support for eqosplus.
LUCI_DEPENDS:=+bash +tc +kmod-sched-core +kmod-ifb +kmod-sched +iptables-mod-filter +iptables-mod-nat-extra +luci +luci-base +luci-compat
LUCI_PKGARCH:=all

PKG_MAINTAINER:=lava <byl0561@gmail.com>

define Build/Compile
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
rm -rf /tmp/luci-*
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/eqosplus
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

