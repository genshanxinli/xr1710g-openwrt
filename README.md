# OpenWrt for Gemtek XR1710G

OpenWrt support for the **Gemtek XR1710G** (sold as the *Brightspeed XR1710G*
Wi-Fi 7 gateway). This is a fork of
[`OpenWRT-fanboy/OpenW1700k`](https://github.com/OpenWRT-fanboy/OpenW1700k)
(branch `kernel73`); all device work lives on branch **`xr1710g`**.

The XR1710G shares the AN7581 platform with the W1700K but is **not** a clone:
it uses an RTL8261BE 10G PHY instead of the RTL8261N, drives the 1G port LEDs
through the MT7530 LED controller instead of GPIOs, has no Zigbee/GPS radio,
and ships a different factory bootloader. W1700K images must not be flashed.

## Hardware

| | |
|---|---|
| SoC | Airoha AN7581 (4× Cortex-A53, 1.3 GHz) |
| RAM / flash | 2 GiB DDR4 / 512 MiB SPI-NAND |
| Wired | 4 ports: 2× 10G (RTL8261BE — `wan` + `lan2`), 2× 1G LAN (`lan3` + `lan4`, AN7581 internal switch) |
| Wireless | MediaTek MT7996, Wi-Fi 7, 2.4/5/6 GHz |
| Other | Nuvoton NCT7802 hwmon, Airoha NPU offload engine |

## Flashing

Two images are produced:

- `...-ubi-initramfs-recovery.itb` — boot from the U-Boot recovery console
  (needs the third-party U-Boot; stock AXON 1.6 cannot load it).
- `...-ubi-sysupgrade.itb` — written by `sysupgrade` from a running system.

The flash layout is `vendor` + `chainloader` + `ubi` + `reserved_bmt`. The
device reports `compat_version 2.0`; images built from this tree upgrade in
place. Upgrading from a `1.x` layout, or cross-flashing a W1700K image,
soft-bricks the device and needs serial/TTL recovery.

## What is included

- Full Cone NAT (`nft-fullcone`) with hardware and software flow offloading
  enabled by default.
- NPU offload for wired and wireless traffic, plus MT7996 NPU firmware.
- CPU frequency scaling up to 1350 MHz (`performance` governor default).
- Status LEDs, fan control, and the hardware LuCI pages: Airoha NPU, flow
  sense, fan control, Wi-Fi 7/MLO.

## Building

Use the CI in [`genshanxinli/xr1710g-builds`](https://github.com/genshanxinli/xr1710g-builds),
which also publishes images to releases. To build by hand:

```sh
git clone -b xr1710g https://github.com/genshanxinli/xr1710g-openwrt.git openwrt
cd openwrt
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # Target: Airoha -> AN7581 -> Gemtek XR1710G
make -j$(nproc)
```

Output is under `bin/targets/airoha/an7581/`.
