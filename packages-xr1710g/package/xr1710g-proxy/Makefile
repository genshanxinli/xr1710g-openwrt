#
# xr1710g-proxy — 名单客户端分流代理（ADR-0003 架构 C）
#
# 数据面：sing-box 核心 + 独立 nft 表 inet xr1710g_proxy（内核层判定，保 PPE/NPU 卸载）
# 不变量：本包任何代码路径永不写 flow_offloading*、永不 reload fw4、永不碰 inet fw4
#
include $(TOPDIR)/rules.mk

PKG_NAME:=xr1710g-proxy
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=XR1710G Maintainer
PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/xr1710g-proxy
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=XR1710G proxy split-routing (kernel-classified, offload-preserving)
  DEPENDS:=+sing-box +nftables-json +kmod-tun +ip-full +curl +python3-light
  PKGARCH:=all
endef

define Package/xr1710g-proxy/description
  Per-client split routing for the Gemma XR1710G (Airoha AN7581GT).

  Classification happens in the kernel (nft + policy routing) so that traffic
  from clients NOT on the proxy list never leaves the hardware-accelerated fast
  path: the `flow add @ft` offload and the flow_offloading* knobs are never
  touched by any code path in this package.

  Only clients in `global.proxy_hosts` get their DNS redirected to sing-box;
  China-destined traffic from those clients is accepted early (keeping PPE/NPU
  offload) and everything else is marked and routed into a TUN device.

  Default off (enabled=0): no nft table, no ip rule, no process.
endef

define Package/xr1710g-proxy/conffiles
/etc/config/xr1710g_proxy
endef

define Build/Compile
endef

define Package/xr1710g-proxy/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/xr1710g_proxy $(1)/etc/config/xr1710g_proxy

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/xr1710g-proxy $(1)/etc/init.d/xr1710g-proxy

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-xr1710g-proxy $(1)/etc/uci-defaults/99-xr1710g-proxy

	$(INSTALL_DIR) $(1)/usr/libexec/xr1710g-proxy
	$(INSTALL_BIN) ./files/usr/libexec/xr1710g-proxy/render.sh $(1)/usr/libexec/xr1710g-proxy/
	$(INSTALL_BIN) ./files/usr/libexec/xr1710g-proxy/cn-list.sh $(1)/usr/libexec/xr1710g-proxy/
	$(INSTALL_BIN) ./files/usr/libexec/xr1710g-proxy/validate-cidr.py $(1)/usr/libexec/xr1710g-proxy/

	# nft 模板 + CN 放行集合/规则集快照：进**只读 squashfs** ⇒ 零 NAND 写、零 overlay 占用（G2）
	$(INSTALL_DIR) $(1)/usr/share/xr1710g-proxy
	$(INSTALL_DATA) ./files/usr/share/xr1710g-proxy/template.nft $(1)/usr/share/xr1710g-proxy/
	$(INSTALL_DATA) ./snapshot/china_ip4.txt $(1)/usr/share/xr1710g-proxy/
	$(INSTALL_DATA) ./snapshot/china_ip6.txt $(1)/usr/share/xr1710g-proxy/
	$(INSTALL_DATA) ./snapshot/geosite-cn.srs $(1)/usr/share/xr1710g-proxy/
endef

define Package/xr1710g-proxy/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# 只做"默认不启用"的兜底：绝不 enable 服务、绝不碰 firewall/network（I4）
uci -q get xr1710g_proxy.global.enabled >/dev/null 2>&1 || uci -q set xr1710g_proxy.global.enabled='0'
uci -q commit xr1710g_proxy 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,xr1710g-proxy))
