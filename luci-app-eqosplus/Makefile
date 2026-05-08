#
# Copyright (C) 2006-2017 OpenWrt.org
# Copyright (C) 2022-2025 lava <byl0561@gmail.com>
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-eqosplus
PKG_VERSION:=legacy-2.3.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for eqosplus.
#
# Dependency strategy
# -------------------
# tc/sched/ifb stack: always required (rate limiting, both backends).
#
# Connection-limit feature has two backends, picked at runtime via UCI:
#   nft  (fw4, OpenWrt 22.03+) : `ct count over N` is in kmod-nft-core,
#                                 which firewall4 already pulls in. ZERO
#                                 extra package needed on fw4 systems.
#   iptables (fw3, 19.07~21.02): `xt_connlimit` + ipset are NOT in base,
#                                 must be installed alongside.
#
# Build-time conditional `+PACKAGE_firewall:<dep>` reads as: "pull <dep> only
# when the legacy `firewall` package (i.e. fw3) is selected in this image's
# config." On fw4-only builds, `firewall` is replaced by `firewall4` so the
# guard is false → iptables-side packages are NOT pulled in. Saves ~300-400KB
# on a typical fw4 image (avoids dragging in iptables-zz-legacy/iptables-nft
# binaries + ipset userspace + kmods that would otherwise sit dormant).
LUCI_DEPENDS:=+tc +kmod-sched-core +kmod-ifb +kmod-sched +kmod-sched-flower \
	+luci +luci-base +luci-compat \
	+PACKAGE_firewall:iptables-mod-conntrack-extra \
	+PACKAGE_firewall:kmod-ipt-conntrack-extra \
	+PACKAGE_firewall:ipset \
	+PACKAGE_firewall:kmod-ipt-ipset
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

