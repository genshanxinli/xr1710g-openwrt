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

# kmod-sched-act-police is here because the airoha driver offloads
# FLOW_ACTION_POLICE to the PPE.  Without the module an ingress shaper fails
# with "No such file or directory" and nothing says why.  No in-tree script
# installs such a filter today; this only makes the capability reachable.

# bridger is in the tree but deliberately unused here.  It is one of three
# mutually incompatible routes to getting bridged traffic into the PPE; this
# target takes the nft-native one (patches 675-01..675-05, under
# target/linux/generic/pending-7.3/: a "table bridge fw4" flowtable with
# offload flags, plus 675-05 rejecting connections that cross the bridge
# twice).  bridger would need kmod-sched-bpf and a BPF pipeline to
# do the same job, and its RTM_DELTFILTER control path fails silently while a
# PPE flow is BIND-active, which is exactly the stale-filter black hole the
# nft path avoids.  Do not add it back without removing the nft route first.

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

