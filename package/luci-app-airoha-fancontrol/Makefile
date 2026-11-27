# This is free software, licensed under the Apache License, Version 2.0 .

include $(TOPDIR)/rules.mk

PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI Airoha Fan Control
LUCI_DEPENDS:=+luci-base +jsonfilter @TARGET_airoha

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-airoha-fancontrol/conffiles
/etc/config/fan
endef

# call BuildPackage - OpenWrt buildroot signature
