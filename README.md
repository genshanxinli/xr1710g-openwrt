# OpenWrt for Gemtek XR1710G

Minimal, rebase-friendly OpenWrt (Linux 7.4) firmware tree for the **Gemtek / Brightspeed XR1710G** Wi-Fi 7 gateway (`gemtek,xr1710g-ubi`).
Shares the Airoha AN7581 platform with the W1700K, but has distinct 10G PHYs, switch-driven 1G LEDs, and factory bootloader — **never flash W1700K images**.

## Hardware Specs

| Component | Specification |
| --- | --- |
| SoC | Airoha AN7581 (4x Cortex-A53, 1.2 GHz max OPP) |
| Memory / Flash | 2 GiB DDR4 / 512 MiB SPI-NAND (`mtd0` `vendor`, `mtd1` `chainloader`, `mtd2` `ubi`, `mtd3` `reserved_bmt`) |
| Wired Ethernet | 2x 10G (`wan` + `lan2`, Realtek RTL8261BE), 2x 1G (`lan3` + `lan4`, internal switch, MT7530 PHY LEDs) |
| Wireless | MediaTek MT7996 tri-band Wi-Fi 7 (2.4 / 5 / 6 GHz, mt76) + Airoha NPU hardware offload |
| Thermal / Boot | Nuvoton NCT7802 hwmon; U-Boot `CONFIG_ENV_SIZE=0x4000`, `loadaddr=0x85000000`, `compat_version 2.0` |

## Build & Verification

Build from a **pure-ASCII path** (e.g. `/xr/xr1710g`; non-ASCII paths break host `meson`).

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
./scripts/build-preflight.sh
./scripts/build-preflight.sh --patch-queue [dl/linux-7.4*.tar.*]
python3 scripts/check-uboot-ubi.py
make menuconfig   # Target: Airoha -> AN7581 -> Gemtek XR1710G (UBI)
make -j$(nproc)
python3 scripts/check-image-artifacts.py bin/targets/airoha/an7581
```

Safety gates: `build-preflight.sh` (ASCII path, BusyBox ash lint, LuCI RPCD ACL, repo hygiene, `fuzz=0` patch queue), `check-uboot-ubi.py` (U-Boot/UBI/env `0x4000`/KASLR), `check-image-artifacts.py` (FIT/FWx0/`sha256sums`/manifest), and `flash-gate.sh` (live pre-flash guard).

Build outputs in `bin/targets/airoha/an7581/`:
- `openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb` — sysupgrade image
- `openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb` — RAM-resident TFTP recovery image
- `openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb` — OpenWrt chainloader FIT

## Safe Flashing & Recovery

**Non-negotiable flash rules:**
- **Never use `sysupgrade -F`** (`scripts/flash-gate.sh` unconditionally refuses `-F`/`--force`).
- **Never write to `mtd0` (`vendor`), `mtd1` (`chainloader`), or `mtd3` (`reserved_bmt`)** — keep them strictly read-only.
- **Require `compat_version 2.0`** on both device and image (never flash a `2.0` image onto a `1.x` partition layout or cross-flash W1700K).

### Live Upgrade (`flash-gate.sh`)

Copy `scripts/flash-gate.sh`, the sysupgrade `.itb`, and `sha256sums` to `/tmp/` on the router:

```sh
# 1. Read-only layout, UBI, and mtd0/mtd1 readability probe (writes nothing)
sh /tmp/flash-gate.sh --probe

# 2. Verify image FIT magic, sha256sums, FWx0 trailer, board, compat 2.0, and sysupgrade -T
sh /tmp/flash-gate.sh --check-only -i /tmp/openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb

# 3. Run full gate + verified mtd0/mtd1 header backup, then execute plain sysupgrade
sh /tmp/flash-gate.sh --run -i /tmp/openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb
```

### TFTP / Initramfs Recovery

The XR1710G UBI layout has no flash `recovery` volume; recovery boots `initramfs-recovery.itb` into RAM over TFTP.

1. Configure your host Ethernet interface to `192.168.1.254/24` (U-Boot `serverip`) and serve `openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb` over TFTP.
2. Power on the router and hold the **reset** button once the chainloader starts (~15 s after power-on; do not hold at power-on or the boot ROM enters UART download mode), or pick **Boot system via TFTP** from the U-Boot serial menu (`115200 8N1`).
3. Once initramfs boots on `192.168.1.1`, copy `sysupgrade.itb` + `sha256sums` + `flash-gate.sh` to `/tmp/` and upgrade with `sh /tmp/flash-gate.sh --run -i /tmp/...-squashfs-sysupgrade.itb` (plain `sysupgrade`, never `-F`).
