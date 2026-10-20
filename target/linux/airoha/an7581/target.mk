ARCH:=aarch64
SUBTARGET:=an7581
BOARDNAME:=AN7581 / AN7566 / AN7551
CPU_TYPE:=cortex-a53
KERNELNAME:=Image dtbs
KERNEL_PATCHVER:=7.3
FEATURES+=pwm

DEFAULT_PACKAGES += \
	airoha-en7581-npu-firmware uboot-envtools \
	kmod-nft-bridge kmod-sched-act-police

# kmod-crypto-hw-eip93 is deliberately not a default package.  The SoC has
# the EIP93 block and an7581.dtsi describes it, but nothing in this image
# can ask the crypto API for the algorithms it registers: the kernel is
# built without CONFIG_XFRM (no INET_ESP, no INET_AH, no XFRM_USER), without
# kTLS, without dm-crypt and without AF_ALG, and no IPsec daemon is
# installed.  So the module loads, registers authenc(hmac(sha*),cbc(aes))
# and friends, and is never called.  It stays in the feed, so an IPsec user
# only has to "opkg install kmod-crypto-hw-eip93 kmod-ipsec4" (which pulls
# in XFRM and ESP) to get hardware assistance for ESP.

define Target/Description
	Build firmware images for Airoha an7581 ARM based boards.
endef

