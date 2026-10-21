# OpenWrt for Gemtek XR1710G

OpenWrt support for the **Gemtek XR1710G** (sold as the *Brightspeed XR1710G*
Wi-Fi 7 gateway). This is a fork of
[`OpenWRT-fanboy/OpenW1700k`](https://github.com/OpenWRT-fanboy/OpenW1700k);
all device work lives on branch **`xr1710g`**.

### Where `xr1710g` comes from

`xr1710g` is **based on the `kernel73` branch** of the upstream repository,
which is where the AN7581 target, the kernel 7.3 port and the MediaTek MT7996
work come from:

```
openwrt/openwrt                  (upstream source, default: main)
  └─ OpenWRT-fanboy/OpenW1700k   (fork parent, branch: kernel73)
       └─ xr1710g-openwrt        (this repository, branch: xr1710g)
```

The branch was carried over by replaying it, not by a direct merge, so the
SHAs do not match even where the subject lines do. As a result
`git merge-base upstream/kernel73 xr1710g` reports the point where `kernel73`
split off `main` (`89381af998`, 2026-10-16), **not** the tip of `kernel73`:

- 70 of the 247 commits upstream has on `kernel73` and not on `main` are
  present in `xr1710g` by subject, with different SHAs; the remaining 177
  (later kernel, netfilter and driver work) are not carried here;
- on top of those, `xr1710g` carries the XR1710G device support and its own
  fixes.

To see the real divergence at any time:

```sh
comm -23 <(git log --format=%s upstream/kernel73 ^main | sort -u) \
         <(git log --format=%s main..HEAD | sort -u)   # upstream-only
```

Because `kernel73` does not exist in the fork by default, GitHub's *Sync fork*
button never offers it. The branch is mirrored here so the relationship is
visible and so a sync has somewhere to land; keep it byte-identical to
`upstream/kernel73` and do not commit to it:

```sh
git fetch upstream
git push origin refs/remotes/upstream/kernel73:refs/heads/kernel73
```

To pick up upstream work, merge or cherry-pick from `upstream/kernel73` into
`xr1710g` — do not sync-fork, which would replace `xr1710g` with the fork
parent's default branch.

The XR1710G shares the AN7581 platform with the W1700K but is **not** a clone:
it uses an RTL8261BE 10G PHY instead of the RTL8261N, drives the 1G port LEDs
through the MT7530 LED controller instead of GPIOs, has no Zigbee/GPS radio,
and ships a different factory bootloader. W1700K images must not be flashed.

## Hardware

| | |
|---|---|
| SoC | Airoha AN7581 (4× Cortex-A53, 1.2 GHz max OPP) |
| RAM / flash | 2 GiB DDR4 / 512 MiB SPI-NAND |
| Wired | 4 ports: 2× 10G (RTL8261BE — `wan` + `lan2`), 2× 1G LAN (`lan3` + `lan4`, AN7581 internal switch) |
| Wireless | MediaTek MT7996, Wi-Fi 7, 2.4/5/6 GHz |
| Other | Nuvoton NCT7802 hwmon, Airoha NPU offload engine |

## Flashing

Three images are produced:

- `...-ubi-initramfs-recovery.itb` — boot from the U-Boot recovery console
  (needs the third-party U-Boot; stock AXON 1.6 cannot load it). This is the
  unbrick image; it runs entirely from RAM.
- `...-ubi-squashfs-sysupgrade.itb` — written by `sysupgrade` from a running
  system.
- `...-ubi-chainload-uboot.itb` — a FIT that chain-loads OpenWrt's U-Boot.

The flash layout is `vendor` + `chainloader` + `ubi` + `reserved_bmt`. The
device reports `compat_version 2.0`; images built from this tree upgrade in
place. Upgrading from a `1.x` layout soft-bricks the device and needs
serial/TTL recovery. Cross-flashing a W1700K image is rejected by
`sysupgrade`: besides the signing check, the FIT device tree name is compared
against the running board, because the bootloader would otherwise happily
boot the other board's device tree.

## What is included

- Full Cone NAT (`nft-fullcone`) with hardware and software flow offloading
  enabled by default. Note that the shipped `nft-fullcone` module only
  implements true full-cone behaviour for UDP; for other protocols the rule is
  equivalent to MASQUERADE. `fw4` probes the module once at startup and falls
  back to plain NAT with a warning in `logread` if it cannot be loaded.
- NPU offload for wired and wireless traffic, plus MT7996 NPU firmware.
- CPU frequency scaling up to 1200 MHz, the top OPP in the base `an7581.dtsi`
  table (`performance` governor default), with a tickless idle kernel
  (`CONFIG_NO_HZ_IDLE`), so the periodic tick stops while the CPU is idle
  instead of firing at a fixed CONFIG_HZ=250.
- Status LEDs, including the 10G port LEDs, which are driven by the RTL8261BE
  LED engine rather than by GPIOs.
- A single fan owner: `/etc/init.d/airoha_fan` applies the stock curve only
  when `luci-app-airoha-fancontrol` is not installed, and stays out of the way
  once it is.
- The hardware LuCI pages are part of the image: Airoha NPU, flow sense, fan
  control, Wi-Fi 7 and MLO.

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
