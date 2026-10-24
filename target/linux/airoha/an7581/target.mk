ARCH:=aarch64
SUBTARGET:=an7581
BOARDNAME:=AN7581 / AN7566 / AN7551
CPU_TYPE:=cortex-a53
KERNELNAME:=Image dtbs
KERNEL_PATCHVER:=7.3
FEATURES+=pwm

DEFAULT_PACKAGES += \
	uboot-envtools kmod-nft-bridge kmod-sched-act-police

# airoha-en7581-npu-firmware (the MT7992 blob) is not a default package.  Only
# the MT7992 reference boards load it - an7581-evb.dtso and
# an7581-evb-emmc-kite.dtso include an7581-npu-mt7992.dtsi - and
# airoha_an7581-evb-multievb already lists it in its DEVICE_PACKAGES.  Every
# other board in this subtarget drives an MT7996 radio and loads
# airoha-en7581-mt7996-npu-firmware instead, so the MT7992 blob was dead
# weight in those images.

# kmod-sched-act-police is here because the airoha driver offloads
# FLOW_ACTION_POLICE to the PPE.  Without the module an ingress shaper fails
# with "No such file or directory" and nothing says why.  No in-tree script
# installs such a filter today; this only makes the capability reachable.

# bridger is in the tree but deliberately unused here.  It is one of the
# routes to getting bridged traffic into the PPE; bridger would need
# kmod-sched-bpf and a BPF pipeline to do it, and its RTM_DELTFILTER control
# path fails silently while a PPE flow is BIND-active, which is exactly the
# stale-filter black hole the current path avoids.
#
# The route this target actually uses is neither bridger nor a bridge-family
# flowtable: bridged traffic is fed through NF_INET_FORWARD by br_netfilter
# (nf_call_iptables on br-lan) and lands in the ordinary "table inet fw4"
# flowtable, where the PPE encodes it as a 5-tuple IPV4_HNAPT/IPV6_ROUTE
# entry, exactly like routed traffic.  Measured: it binds, and a 3.5M-packet
# run spent 0.46 CPU-seconds against 34.3 for the same traffic unbound.
#
# generic/pending-7.3/675-01..675-05 are what a *bridge-family* flowtable
# needed.  Nothing here creates one any more (firewall4 has no
# flow_offloading_bridge option), so those patches are retained rather than
# used; removing them is a separate change that needs its own build test.

# Two facts about /sys/kernel/debug/ppe/usage that read as bugs but are not:
#
#   l2b_bound 0    counts entries of PPE_PKT_TYPE_BRIDGE.  The driver can only
#                  pick that type when the flow dissector reports addr_type 0,
#                  and nf_flow_table_offload.c builds the key from
#                  tuple->l3proto, which is only ever AF_INET or AF_INET6
#                  (anything else returns -EOPNOTSUPP).  So this counter is
#                  structurally unreachable and bridged flows are counted in
#                  "bound" instead.  Do not read it as "bridging is not
#                  offloaded".
#
#   packets=n/a    the NPU refuses per-flow counters (the driver logs "NPU
#                  refused flow stats (-22), continuing without counters"), so
#                  entries have no byte/packet counts.  Use the ib1/ib2 decode
#                  plus the interface counters instead.

# A flow binds once its sustained *rate* clears REG_PPE_BIND_RATE, which this
# driver sets to 0x1e (30) in both the L3 and the L2B half.  Measured on
# hardware: at or above the threshold the UNB record becomes BIND after about
# 1.1-1.8 seconds regardless of how fast you go (30/40/60/80 pps all bind in
# ~1.3 s); well below it the flow either takes tens of seconds or never binds.
# It is not a packet count -- an earlier reading of "31 packets" came from
# tests that all ran about one second, which made count and time collinear.
# Consequence for benchmarking: a short burst never binds, and DNS lookups,
# single HTTP requests and other low-rate flows stay on the CPU, so a
# throughput test built out of short requests will report "offload does not
# work".  Drive one long, sustained flow instead, or raise the rate.
# The threshold is runtime adjustable through /sys/kernel/debug/ppe/bind_rate
# ("l3 [l2b]") when CONFIG_DEBUG_FS is on; see patch 964.

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

