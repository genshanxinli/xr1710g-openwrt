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

The branch was originally carried over by replaying it, so the SHAs differ
from upstream's even where the subject lines match. It has since drifted away
from a clean ancestry: measured on 2026-11-21, the fork parent's `kernel73`
tip is **not** an ancestor of `xr1710g` — the merge-base is still
`5192094fd6`, and the last real absorption of upstream work is `bc0b2ed82a`
(2026-10-24): `xr1710g` carried 511 commits upstream did not have and missed
880 of theirs; both move with every commit — read them below, not here:

```sh
scripts/track-upstream.sh                 # the table; exits 1 while it drifts
git merge-base --is-ancestor upstream/kernel73 HEAD; echo "exit=$?"   # 1
```

The pre-sync state is preserved as the tag `pre-sync-2026-10-24`, which is the
rollback point (`git reset --hard pre-sync-2026-10-24`).

Because `kernel73` does not exist in the fork by default, GitHub's *Sync fork*
button never offers it, and syncing `main` would replace `xr1710g` with the
fork parent's default branch — do not use it. The branch is mirrored here so
the relationship is visible and so a sync has somewhere to land. The mirror is
tracked, not trusted: on 2026-11-21 it was 35 commits ahead of and 273 behind
`upstream/kernel73`, with 628 differing files — a recorded deviation, not a
byte-identical copy. Refresh it only after a sync has landed:

```sh
git fetch upstream
git switch xr1710g
git merge upstream/kernel73        # resolve, then make target/linux/prepare
git push --force origin upstream/kernel73:refs/heads/kernel73   # re-mirror
```

What is machine-checked — and where the moving counters live — is in
[Upstream drift record](#upstream-drift-record).

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

The flash layout is `vendor` + `chainloader` + `ubi` + `reserved_bmt`. It stays
four partitions because the two-partition reference layout needs BL2/BL31
written by the build (`target/linux/airoha/image/an7581.mk:1-5`) while this
board's `vendor` partition is a vendor-signed AXON blob; this tree only
produces `chainload-uboot.itb`. Device and this tree both report
`compat_version 2.0`; images built from this tree upgrade in place.

Cross-flashing a W1700K image is rejected by
`sysupgrade`: besides the signing check, the FIT device tree name is compared
against the running board, because the bootloader would otherwise happily
boot the other board's device tree.

### Soft-brick gate: a 1.x unit must not be flashed with a 2.0 image

`compat_version 2.0` is baked in at build time
(`target/linux/airoha/image/an7581.mk:83`) and written onto the device by
`.../base-files/etc/board.d/05_compat-version:11-14`. `sysupgrade` reads it
back and compares it with the image before it writes anything
(`package/base-files/files/lib/upgrade/fwtool.sh:49-50,52-54,75-80`).

- **1.x unit + 2.0 image, plain `sysupgrade`** → the compat check fails, `sysupgrade`
  aborts, **nothing is written to flash**. That is the gate working.
- **1.x unit + 2.0 image, `sysupgrade -F`** → **the gate is gone**. A compat
  mismatch is reported as "invalid but forceable" (`validate_firmware_image:10`
  `FORCEABLE=1`, `:14-16`), so `-F` writes the 2.0 partition table over the 1.x
  one and the unit no longer boots; recovery then needs serial/TTL (see below).
  **Never use `-F` to get past a compat mismatch.**
- Stock (vendor AXON) units do not run OpenWrt's `sysupgrade` at all — conversion
  happens through the vendor web UI or U-Boot TFTP, which write `ubi` directly.
  This warning text is therefore the only gate those units get.

Read-only layout check before flashing (all of these are safe, none writes):

```sh
ssh root@192.168.1.1 'cat /proc/mtd'        # 4 parts: vendor, chainloader, ubi, reserved_bmt
ssh root@192.168.1.1 'ubinfo -a | grep -E "Name|bad physical|reserved physical"'
ssh root@192.168.1.1 'uci -q get system.@system[0].compat_version'   # must print 2.0
```

A 2.0 unit shows `chainloader` at `0x00600000` (1 MiB), `reserved_bmt` at
`0x1be00000` (66 MiB) and **both** `ubootenv` and `ubootenv2` volumes in UBI.
Any of those missing, or the compat value unreadable (treat unreadable as `1.0`),
means the unit is not on the 2.0 layout — do not flash this tree's images onto it.

Before you flash anything on hardware you would rather not lose: capture the
running `/proc/mtd` and `ubinfo -a` output over ssh, keep the vendor image and
`ubootenv`/`ubootenv2` volumes, and verify the compat gate listed above before
writing. Nothing here has been booted from the recovery image yet, so treat the
recovery path as untested on hardware.

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

## Upstream drift record

`scripts/track-upstream.sh` measures the fork parent; the line below is the
part `--check` can assert, and the `Claim ledger` job re-checks its shape on
every pull request. The moving counters — branch tips, ahead/behind, how many
files the mirror differs by — are deliberately not here: they change with
every upstream push. They live in issue #189 and in the script's own output.

<!-- upstream-record: checked=2026-11-21 merge_base=5192094fd6 ancestor=no mirror_tree=different branches=kernel73,kernel74,main mirror=origin/kernel73 local=HEAD -->

After a real sync, replace that line with `scripts/track-upstream.sh
--record`. Nothing refreshes it automatically: `.github/workflows/
upstream-drift.yml` runs `scripts/track-upstream.sh` on a Monday cron, but
this repository has no runner, so the job never executes — run `--check`
locally (or in the `Claim ledger` job's static form) instead.

## Documentation

This tree ships no prose documents; the evidence for every hardware claim lives
in the issue that settles it and in the machine-checked ledger `scripts/claims.yaml`
(`python3 scripts/check-claims.py --strict --max-unverified N`). Start from the
issue index, then follow the `file:line` pointers in the ledger.

## Building

Use the CI in [`genshanxinli/xr1710g-builds`](https://github.com/genshanxinli/xr1710g-builds),
which also publishes images to releases. To build by hand:

The build embeds the worktree path in the host staging pkg-config files; a
non-ASCII path makes meson fail in an unrelated host package before the
requested target is built. Use a pure-ASCII path such as `/xr/xr1710g`, and
run `scripts/build-preflight.sh` before `make`:

```sh
git clone -b xr1710g https://github.com/genshanxinli/xr1710g-openwrt.git openwrt
cd openwrt
./scripts/feeds update -a && ./scripts/feeds install -a
./scripts/build-preflight.sh
make menuconfig   # Target: Airoha -> AN7581 -> Gemtek XR1710G
make -j$(nproc)
```

`SKIP_PATH_CHECK=1 ./scripts/build-preflight.sh` reports the problem as a
warning and exits 0; the build will still fail.

Output is under `bin/targets/airoha/an7581/`.
