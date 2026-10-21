# This is free software, licensed under the Apache License, Version 2.0 .

include $(TOPDIR)/rules.mk

PKG_VERSION:=1.1.9
PKG_RELEASE:=7
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI Airoha FlowSense — Offload & PPE Monitor
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci \
	+ucode-mod-nl80211 +ethtool-full +tc-full +kmod-sched-core @TARGET_airoha

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-airoha-flowsense/conffiles
/etc/config/npu-monitor
endef

define Package/luci-app-airoha-flowsense/postinst
#!/bin/sh
# Normalise the modes of everything we ship. The build tree is usually a copy
# of a repository that lives on a Windows drive through WSL, where chmod() is
# a no-op and every file reads back as 0777 no matter what git recorded.
#
# Both directions of that bug are fatal here:
#   - scripts that lost +x cannot be executed (init script, rpcd backend,
#     hotplug handler) -> "Permission denied" on the post-upgrade enable
#   - files that gained +o+w are REFUSED by rpcd itself:
#     "Ignoring ucode script ... because it is world writable", so the
#     luci.airoha_flowsense object is never registered and LuCI dies with
#     "RPC call to luci.airoha_flowsense/getStatus failed ... Object not found"
#
# Self-heal both, so the app works regardless of how the package was packed.
# Runs offline (IPKG_INSTROOT set) and online.
chmod 0755 "$${IPKG_INSTROOT}/etc/init.d/npu-jitter" \
           "$${IPKG_INSTROOT}/usr/libexec/npu-jitter-daemon" 2>/dev/null
chmod 0644 "$${IPKG_INSTROOT}/usr/share/rpcd/ucode/luci.airoha_flowsense.uc" \
           "$${IPKG_INSTROOT}/usr/share/rpcd/acl.d/luci-app-airoha-flowsense.json" \
           "$${IPKG_INSTROOT}/usr/share/luci/menu.d/luci-app-airoha-flowsense.json" 2>/dev/null
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/npu-jitter enable 2>/dev/null
	/etc/init.d/npu-jitter restart 2>/dev/null
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd restart 2>/dev/null
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
