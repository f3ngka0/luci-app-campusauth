#
# LuCI app: Dr.COM campus portal auto-login
#
# This Makefile follows the layout used by the official LuCI feed
# (openwrt/luci). To build it, drop this directory into a checkout of that
# feed, i.e.
#
#     feeds/luci/applications/luci-app-campusauth/
#
# and then select it in `make menuconfig` under LuCI -> Applications.
# The `include ../../luci.mk` line below resolves to feeds/luci/luci.mk.
#
include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI app for Dr.COM campus portal auto-login
LUCI_DESCRIPTION:=\
 Automatically detects a dropped Dr.COM portal session and logs back in. \
 Ships a LuCI page for the credentials/service type and a companion uplink \
 watchdog that keeps a durable record of WAN health and recovers a lost DHCP \
 lease (a lost lease means there is no route to the portal at all, so the \
 auto-login cannot work until it is back).

# Lua CBI models need the compatibility layer.
# wget (uclient-fetch or busybox) is used for the portal requests.
LUCI_DEPENDS:=+luci-compat +uclient-fetch

LUCI_PKGARCH:=all
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Your Name <you@example.com>

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
