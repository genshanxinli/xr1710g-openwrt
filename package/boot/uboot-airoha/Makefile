include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_VERSION:=2026.07
PKG_HASH:=78e8bfc382fe388f9b55aa1daf8c563522a037779b5d4c349d1415e381f1243e
PKG_BUILD_DEPENDS:=arm-trusted-firmware-tools/host

UBOOT_USE_INTREE_DTC:=1

include $(INCLUDE_DIR)/u-boot.mk
include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/host-build.mk

define U-Boot/Default
  BUILD_TARGET:=airoha
  LZMA_COMPRESS:=1
  HIDDEN:=1
endef

define U-Boot/an7581_gemtek_w1700k
  NAME:=Gemtek W1700K (UBI)
  UBOOT_CONFIG:=an7581_w1700k
  BUILD_DEVICES:=gemtek_w1700k-ubi
  BUILD_SUBTARGET:=an7581
endef

define U-Boot/an7581_gemtek_xr1710g
  NAME:=Gemtek XR1710G (UBI)
  UBOOT_CONFIG:=an7581_xr1710g
  BUILD_DEVICES:=gemtek_xr1710g-ubi
  BUILD_SUBTARGET:=an7581
endef

define U-Boot/an7581_nokia_valyrian
  NAME:=Nokia Valyrian
  UBOOT_CONFIG:=an7581_nokia_valyrian
  BUILD_DEVICES:=nokia_valyrian
  BUILD_SUBTARGET:=an7581
  BL2_IMAGE:=an7581-bl2.bin
  BL31_IMAGE:=an7581-bl31.bin
endef

define U-Boot/an7581_nokia_xg-040g-md
  NAME:=Nokia XG-040G-MD
  UBOOT_CONFIG:=an7581_nokia_xg-040g-md
  BUILD_DEVICES:=nokia_xg-040g-md-ubi
  BUILD_SUBTARGET:=an7581
  BL2_IMAGE:=an7581-bl2.bin
  BL31_IMAGE:=an7581-bl31.bin
endef

define U-Boot/an7581_rfb
  NAME:=AN7581 Reference Board
  UBOOT_CONFIG:=an7581_evb
  BUILD_DEVICES:=airoha_an7581-evb-multievb
  BUILD_SUBTARGET:=an7581
  BL2_IMAGE:=an7581-bl2.bin
  BL31_IMAGE:=an7581-bl31.bin
  DEPENDS:=+trusted-firmware-a-an7581-bl31
endef

define U-Boot/an7583_nokia_xg-040g-mf
  NAME:=Nokia XG-040G-MF
  UBOOT_CONFIG:=an7583_nokia_xg-040g-mf
  BUILD_DEVICES:=nokia_xg-040g-mf-ubi
  BUILD_SUBTARGET:=an7583
  BL2_IMAGE:=an7583-bl2.bin
  BL31_IMAGE:=an7583-bl31.bin
  DEPENDS:=+trusted-firmware-a-an7583-bl31
endef

define U-Boot/an7583_rfb
  NAME:=AN7583 Reference Board
  UBOOT_CONFIG:=an7583_evb
  BUILD_DEVICES:=airoha_an7583-evb-multievb
  BUILD_SUBTARGET:=an7583
  BL2_IMAGE:=an7583-bl2.bin
  BL31_IMAGE:=an7583-bl31.bin
  DEPENDS:=+trusted-firmware-a-an7583-bl31
endef

define U-Boot/en7523_rfb
  NAME:=EN7523 Reference Board
  UBOOT_CONFIG:=en7523_evb
  BUILD_DEVICES:=airoha_en7523-evb
  BUILD_SUBTARGET:=en7523
  BL2_IMAGE:=en7523-bl2.bin
  BL31_IMAGE:=en7523-bl31.bin
endef

UBOOT_TARGETS := \
	an7581_gemtek_w1700k \
	an7581_gemtek_xr1710g \
	an7581_nokia_valyrian \
	an7581_nokia_xg-040g-md \
	an7581_rfb \
	an7583_nokia_xg-040g-mf \
	an7583_rfb \
	en7523_rfb

UBOOT_CUSTOMIZE_CONFIG := \
	--disable TOOLS_KWBIMAGE \
	--disable TOOLS_LIBCRYPTO \
	--disable TOOLS_MKEFICAPSULE \
	--enable DM_RNG \
	--enable RNG_AIROHA \
	--enable SERIAL_RX_BUFFER \
	--set-val SERIAL_RX_BUFFER_SIZE 256

# The Airoha TRNG driver (patches/112-rng-*) is what turns the DT's
# rng@1faa1000 node into /chosen/kaslr-seed (boot/fdt_support.c fdt_kaslrseed).
# RNG_AIROHA is hidden behind "if DM_RNG" and depends on ARCH_AIROHA, so a
# dropped --enable would silently leave the node dead again: assert the pair.
# The call site also skips fdt_kaslrseed() when MEASURED_BOOT or
# ARMV8_SEC_FIRMWARE_SUPPORT is enabled, so those must stay off.
define Build/Configure
	$(call Build/Configure/U-Boot)
	sed -i 's/CONFIG_TOOLS_LIBCRYPTO=y/# CONFIG_TOOLS_LIBCRYPTO is not set/' $(PKG_BUILD_DIR)/.config
	grep -q "^CONFIG_DM_RNG=y" $(PKG_BUILD_DIR)/.config || { echo "uboot-airoha: CONFIG_DM_RNG is not set -- fdt_kaslrseed() would be a no-op" >&2; exit 1; }
	grep -q "^CONFIG_RNG_AIROHA=y" $(PKG_BUILD_DIR)/.config || { echo "uboot-airoha: CONFIG_RNG_AIROHA is not set -- fdt_kaslrseed() would be a no-op" >&2; exit 1; }
	if grep -q "^CONFIG_MEASURED_BOOT=y" $(PKG_BUILD_DIR)/.config; then echo "uboot-airoha: CONFIG_MEASURED_BOOT=y suppresses fdt_kaslrseed()" >&2; exit 1; fi
	if grep -q "^CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT=y" $(PKG_BUILD_DIR)/.config; then echo "uboot-airoha: CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT=y suppresses fdt_kaslrseed()" >&2; exit 1; fi
endef

define Build/Compile
	$(call Build/Compile/U-Boot)
	$(if $(LZMA_COMPRESS), $(STAGING_DIR_HOST)/bin/lzma e \
		$(PKG_BUILD_DIR)/u-boot.bin \
		$(PKG_BUILD_DIR)/u-boot.lzma)
endef

# don't stage files to bindir, let target/linux/airoha/image/*.mk do that
define Package/u-boot/install
endef

define Build/InstallDev
	$(INSTALL_DIR) $(STAGING_DIR_IMAGE)
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/u-boot.$(if $(LZMA_COMPRESS),lzma,bin) \
		$(STAGING_DIR_IMAGE)/$(BUILD_VARIANT)-u-boot.$(if $(LZMA_COMPRESS),lzma,bin)
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/u-boot.dtb \
		$(STAGING_DIR_IMAGE)/$(BUILD_VARIANT)-u-boot.dtb
endef

$(eval $(call BuildPackage/U-Boot))
