# SPDX-License-Identifier: GPL-2.0-only
#
# Opt-in package group: EIP93 classic ESP.  This package installs nothing
# itself; selecting it pulls in strongSwan (the minimal IKEv1/IKEv2 PSK
# set), the IPv4 IPsec kernel modules and the EIP93 crypto engine.
#
# It is deliberately not part of DEFAULT_PACKAGES.  The EIP93 block only
# accelerates classic ESP transforms - authenc(hmac(sha1|sha256|md5),
# cbc(aes|des|des3_ede)) - and has no GCM or ChaCha20-Poly1305 offload, so
# an image that does not run IPsec gains nothing from the extra packages.

include $(TOPDIR)/rules.mk

PKG_NAME:=eip93-ipsec
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/eip93-ipsec
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=EIP93 classic IPsec package set (opt-in)
  DEPENDS:=@TARGET_airoha \
	+kmod-ipsec \
	+kmod-ipsec4 \
	+kmod-crypto-hw-eip93 \
	+strongswan \
	+strongswan-charon \
	+strongswan-ipsec \
	+strongswan-mod-aes \
	+strongswan-mod-des \
	+strongswan-mod-gmpdh \
	+strongswan-mod-hmac \
	+strongswan-mod-kdf \
	+strongswan-mod-kernel-netlink \
	+strongswan-mod-md5 \
	+strongswan-mod-mgf1 \
	+strongswan-mod-pubkey \
	+strongswan-mod-random \
	+strongswan-mod-sha1 \
	+strongswan-mod-sha2 \
	+strongswan-mod-socket-default \
	+strongswan-mod-stroke \
	+strongswan-mod-updown
  PKGARCH:=all
endef

define Package/eip93-ipsec/description
 Pulls in everything needed to run an IPsec endpoint on the EIP93
 (MT7621/Airoha SafeXcel) crypto engine: strongSwan, the IPv4 IPsec
 modules (kmod-ipsec, kmod-ipsec4) and kmod-crypto-hw-eip93.
 .
 The strongSwan side is the minimal tested IKEv1/IKEv2 PSK set: charon,
 the ipsec utility, and the AES/DES, HMAC, MD5/SHA1/SHA2, GMP-DH, KDF,
 kernel-netlink, socket-default, stroke and updown plugins.  This is the
 same set as the strongswan-isakmp meta-package plus strongswan-mod-kdf,
 listed explicitly because the meta-package lacks a KDF backend by
 default.
 .
 The EIP93 hardware only accelerates classic ESP, i.e.
 authenc(hmac(sha1|sha256|md5),cbc(aes|des|des3_ede)).  It has no GCM
 and no ChaCha20-Poly1305 offload.  Configure ESP proposals with those
 classic transforms only.
 .
 This package group is not part of DEFAULT_PACKAGES: nothing is added to
 an image unless it is selected explicitly.  The manual "ip xfrm" smoke
 test in scripts/eip93-ipsec-smoke.sh additionally needs ip-full and
 iperf3, which are not pulled in by this package.
endef

define Build/Compile
endef

define Package/eip93-ipsec/install
	true
endef

$(eval $(call BuildPackage,eip93-ipsec))
