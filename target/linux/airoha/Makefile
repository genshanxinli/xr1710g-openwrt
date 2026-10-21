include $(TOPDIR)/rules.mk

ARCH:=arm
BOARD:=airoha
BOARDNAME:=Airoha ARM
SUBTARGETS:=en7523 an7581 an7583
# dt-overlay is required for the AN7581 evaluation boards, which use a single
# base device tree plus DT overlays instead of one full DTS per board. Without
# the feature CONFIG_HAS_DT_OVERLAY_SUPPORT stays unset, dtc is not called
# with -@, the base blob has no /__symbols__ node, and every overlay fails to
# apply. Upstream enabled it in the commit that introduced the overlays.
FEATURES:=dt dt-overlay squashfs nand ramdisk gpio

KERNEL_PATCHVER:=6.18
KERNEL_TESTING_PATCHVER:=7.3

include $(INCLUDE_DIR)/target.mk
DEFAULT_PACKAGES += \
	kmod-leds-gpio kmod-gpio-button-hotplug

$(eval $(call BuildTarget))
