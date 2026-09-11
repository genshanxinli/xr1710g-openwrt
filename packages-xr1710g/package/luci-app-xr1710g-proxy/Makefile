#
# luci-app-xr1710g-proxy — 极简 LuCI 前端（总开关 / 名单 / CN 更新 / 只读状态）
#
# 自写而非引 homeproxy（ADR-0003 Considered Options）：
#   homeproxy 硬依赖 +kmod-nft-tproxy，且 routing_mode=bypass_mainland_china 把 CN 判定
#   放在用户态（generate_client.uc）——先天不保 CN 流量的硬件卸载。
# 本前端只做四件事，**绝不**触发 fw4、**绝不**写 flow_offloading*（I1/I2/I4）。
#
include $(TOPDIR)/rules.mk

LUCI_NAME:=luci-app-xr1710g-proxy
LUCI_PKG_VERSION:=1.0.0
PKG_VERSION:=$(LUCI_PKG_VERSION)
PKG_RELEASE:=1

PKG_MAINTAINER:=XR1710G Maintainer
PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=LuCI app for XR1710G split-routing proxy
LUCI_DESCRIPTION:=Minimal frontend for xr1710g-proxy: master switch, client list, \
	CN allow-list snapshot status and on-demand update, plus read-only runtime state. \
	Every change goes through uci + /etc/init.d/xr1710g-proxy reload; the firewall \
	(fw4) is never reloaded and flow_offloading* is never written.
LUCI_DEPENDS:=+luci-base +xr1710g-proxy +jq

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
