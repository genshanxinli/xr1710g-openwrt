#
# Copyright (C) 2026 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=regio
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define KernelPackage/regio
  SUBMENU:=Debugging
  TITLE:=XR1710G AN7581 MMIO debug window
  FILES:=$(PKG_BUILD_DIR)/regio.ko
  KCONFIG:=
endef

define KernelPackage/regio/description
  A minimal debugfs file that exposes 32-bit MMIO reads, dumps and (when
  explicitly enabled) writes for the Airoha AN7581 boards.  It exists
  because the stock image has no /dev/mem and busybox has no devmem applet.
  The module is not part of any default image; install kmod-regio and
  insmod regio on demand.  Reads are limited to read_ranges and writes need
  allow_write=1; regio_never[] refuses the SPI-NAND controller, DRAM and the
  NPU window for both read and write, and regio_ro[] refuses writes to the
  clock/PLL, UART1+watchdog and scuclk blocks.
endef

define Build/Compile
	$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,regio))
