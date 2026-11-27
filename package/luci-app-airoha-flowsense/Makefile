# This is free software, licensed under the Apache License, Version 2.0 .

include $(TOPDIR)/rules.mk

PKG_VERSION:=1.1.9
PKG_RELEASE:=12
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI Airoha FlowSense — Offload & PPE Monitor
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci \
	+ucode-mod-nl80211 +ip-bridge +tc-tiny \
	+kmod-sched-core @TARGET_airoha

define Package/luci-app-airoha-flowsense/conffiles
/etc/config/npu-monitor
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-airoha-flowsense/postinst
#!/bin/sh
if ! command -v group_exists >/dev/null 2>&1 && [ -r "$${IPKG_INSTROOT}/lib/functions.sh" ]; then
	. "$${IPKG_INSTROOT}/lib/functions.sh"
fi
if command -v group_exists >/dev/null 2>&1; then
	group_exists npu-jitter || group_add npu-jitter 455
	user_exists npu-jitter || user_add npu-jitter 455 455 npu-jitter /var/run/flowsense-jitter /bin/false
	group_add_user npu-jitter npu-jitter
fi
# Enforce executable and non-world-writable permissions required by procd and rpcd.
chmod 0755 "$${IPKG_INSTROOT}/etc/init.d/npu-jitter" \
           "$${IPKG_INSTROOT}/usr/libexec/npu-jitter-daemon" 2>/dev/null
chmod 0644 "$${IPKG_INSTROOT}/usr/share/rpcd/ucode/luci.airoha_flowsense.uc" \
           "$${IPKG_INSTROOT}/usr/share/rpcd/acl.d/luci-app-airoha-flowsense.json" \
           "$${IPKG_INSTROOT}/usr/share/luci/menu.d/luci-app-airoha-flowsense.json" 2>/dev/null
[ -f "$${IPKG_INSTROOT}/etc/capabilities/npu-jitter.json" ] && \
	chmod 0644 "$${IPKG_INSTROOT}/etc/capabilities/npu-jitter.json" 2>/dev/null
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd restart 2>/dev/null
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
