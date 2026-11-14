# OpenWrt PR #26296 convergence checklist

Status snapshot: **2026-11-15**. Local tree: `xr1710g` at `30406ad57d` (this
docs branch adds only this file).
Upstream references: `openwrt/openwrt` `main` at `7b46f9593eb9` (2026-11-13), PR
#26296 head `16bbb337f4c5` (open, three commits), PR #26297 (open), PR #26508
(open), PR #23990 (open RFC).

This file tracks what this tree already has, what an open upstream PR carries,
and what exists only here. It is **documentation only**: it changes no code,
build configuration or firmware.

**No open PR is upstream.** "PR #26296 open" below means the change is proposed
upstream but has **not** been merged. "merged in main" means it is present in
`openwrt/openwrt` `main` at the snapshot above and is therefore not something
this tree needs to carry as a local patch.

## Base relationship

This tree is `genshanxinli/xr1710g-openwrt` branch `xr1710g`, based on
`OpenWRT-fanboy/OpenW1700k` `kernel73`, which is OpenWrt `main` plus the
kernel 7.3 testing port. PR #26296 targets `openwrt/openwrt` `main` (kernel
6.18) and is an independent XR1710G implementation. The local device support
therefore cannot be rebased by copying PR files over the tree; the deltas below
are what remain.

## Status keys

| Key | Meaning |
| --- | --- |
| `merged in main` | Present in `openwrt/openwrt` main at the snapshot; no local patch needed for upstreaming. |
| `PR #26296 open` | In the open XR1710G PR; not merged, so not upstream. |
| `PR #26297 open` | In the separate open LED-mode PR; not merged. |
| `local only` | Carried only in this tree; no upstream PR or commit found. |
| `not for upstream` | Deliberately local (lab tooling, vendor packaging, product defaults). |

## Convergence table

| Item | Local path | Upstream status | Blocker | Action |
| --- | --- | --- | --- | --- |
| DTS / board tree | `target/linux/airoha/dts/an7581-xr1710g-ubi.dts`; shared `an7581-npu-mt7996.dtsi`, `an7581-npu-wlan.dtsi` | `PR #26296 open` — adds `an7581-gemtek_xr1710g-ubi.dts` plus the shared `an7581-gemtek-common.dtsi` (W1700K refactor). | The local DTS is standalone and predates the PR (imported with tag `pre-sync-2026-10-24`). The PR does not have `realtek,sds-mode`, `realtek,patch-rtk-serdes`, the RTL8261BE `leds` children, or `openwrt,netdev-name = "cpu"`; those are local-only. Keeping both board-tree implementations would duplicate the device and is not a convergence path. | After #26296 merges, rebase this tree on it and keep only the extra PHY/LED deltas in the common dtsi; send those as a follow-up. Do not call the current local DTS upstream. |
| PCIe (AN7581 PCIe PHY, 2-lane) | `target/linux/airoha/patches-7.3/220-06-...`, `220-10-...`, `602-04-...`, `609-04-...`; `&pcie0` in the board DTS | `merged in main` — the same patch names are in main's `target/linux/airoha/patches-6.18/`. | No upstream blocker. The 6.18 copies are the upstream ones; the only local addition is the testing-kernel 7.3 forward-port, which has to stay in sync. | No upstream PR; drop these from any series and refresh them when the kernel baseline moves. |
| PCIe/hif2 (MT7996 NPU host interface) | `package/kernel/mt76/Makefile` (source `OpenWRT-fanboy/mt76-firmware`, 2026-10-08) and `package/kernel/mt76/patches/`; HIF2/NPU work is referenced by issues #96 and #98, not by a tracked file | `local only` — main uses `openwrt/mt76` 2026-10-28 with only the `100-` and `101-` patches; no HIF2/NPU patch is upstream. | Different mt76 base and fork-only NPU code; no public HIF2/NPU register documentation found; the patches are not split per change. | Keep this out of #26296. Rebase on `openwrt/mt76`, split and submit per patch; keep HIF2-only changes in this fork. |
| 10G/2.5G (USXGMII PCS, RTL8261BE) | `target/linux/airoha/patches-7.3/745-...`, `747-...`, `748-...`, `749-...`; `target/linux/generic/pending-7.3/744-net-phy-realtek-reapply-the-RTK-SerDes-tuning-after-aneg.patch`; DTS `phy5`/`phy8` quirks `realtek,sds-mode = <0x88c6>` and `realtek,patch-rtk-serdes`; `rtl826x-firmware`, `rtl8261c-firmware` packages | `local only` for 744/745/747/748/749 — #26296 lists the 10G link failure under Known issues and deliberately excludes the fixes. `rtl826x-firmware` and `rtl8261c-firmware` are `merged in main`. | The AN7581 PCS RX calibration failure (`No FBCK Lock`) is platform-wide, not XR-specific; no open upstream PR (the earlier USXGMII attempt #22536 was closed unmerged); the fixes need reports from other AN7581 boards. 744/747/748/749 are 7.3-only; 745 is also carried in `patches-6.18`. | Merge #26296 first; then submit 744/745/747/748/749 as a separate net/pcs + realtek series with per-board `Tested-by`. Keep the board DTS quirks local until that series is accepted. |
| LED (status, lan3/lan4, 10G ports) | `target/linux/airoha/an7581/base-files/etc/board.d/01_leds`; DTS `leds`, `gsw_phy1/2`, `phy5`/`phy8` LED children; `patches-7.3/203-09-...`; `patches-7.3/998-silence-PHY-LED-pinctrl-error.patch` | `PR #26296 open` (lan3/lan4 `01_leds` entries only); `PR #26297 open` (netdev LED mode reset in base-files); `203-09` `merged in main`; `998` and the 10G LED bits `local only`; `PR #26508 open` may swap the `phy1_led0`/`phy1_led1` pins. | #26297 is unmerged; `998` hides a pinctrl error and is not upstreamable as-is; local `01_leds` has extra wan/lan2 entries and RTL8261BE LED children that #26296 does not; the merge order with #26508 changes the pin mapping. | Land #26297; remove `998` once the pinctrl/DTS mapping is correct; send 10G LED support as a follow-up after #26296 and #26508. |
| Fan (NCT7802) | `target/linux/airoha/an7581/base-files/etc/init.d/airoha_fan` (single-owner rewrite); `package/luci-app-airoha-fancontrol/`; `package/luci-app-w1700k-fancontrol/` | `PR #26296 open` only adds `gemtek,xr1710g-ubi` to the existing W1700K case; the equivalent legacy script is already in main. The rewrite and the LuCI apps are `local only`. | The rewrite changes W1700K behaviour and needs W1700K testing and maintainer buy-in; the LuCI apps belong in `openwrt/luci`, not in the target PR. | Keep the rewrite and apps local for now. If upstreaming, make the init change board-neutral and submit it separately from #26296. |
| netwatchdog | `scripts/lib/netwatchdog-guard.sh` (planned by #102, not present at `30406ad57d`); the netwatchdog service itself has no tracked config in this tree | `not for upstream` — lab safety tooling, not part of OpenWrt or #26296. | External service, not in this tree; #102 is open and the guard has not been implemented. | Keep out of `openwrt/openwrt`; land the guard in this fork if destructive scripts need it; record the service location outside the repo. |
| NPU firmware (EN7581 + MT7996) | `package/firmware/linux-firmware/files/airoha/en7581_MT7996_npu_rv32.bin` (125832 bytes, sha256 `7068a987bb95e89129a69de10d598f234a4400023eb23aacc8eb377e5f0fe0ea`) and `..._data.bin` (3092 bytes, sha256 `6fd9506e399ebb309801ac2ecc74d3e10fa66731afc828c76fde8a67b2153f49`); `package/firmware/linux-firmware/airoha.mk` (local MT7996 package copies from `./files/airoha/`) | The package `airoha-en7581-mt7996-npu-firmware` is `merged in main`, but main takes the blobs from `$(PKG_BUILD_DIR)/airoha/` (the linux-firmware tarball). The local v0.8 blobs are `local only`. | Local v0.8 (source `zhengping-zhang/airoha-npu`, commit `e47ab18e23`) differs from the linux-firmware master blobs fetched on 2026-11-14 (122336 and 3084 bytes); provenance/licence review is tracked by #87; binaries must not be sent to `openwrt/openwrt`. | Submit v0.8 to linux-firmware with provenance/licence evidence, or keep it as a local override. Never add the blobs to the device PR. |
| NPU/PPE driver patches (airoha) | `target/linux/airoha/patches-7.3/`: `199-...`, `201-...`, `204-...` to `216-...`, `926-...`, `963-...` to `965-...`, `992-...`, `998-...`; a subset (`200-02`, `202-*`, `203-*`, `924-`) is already in main | Mixed: that subset is `merged in main`; most are `local only`. | Mostly 7.3 testing-kernel only (`199`, `992`, `998` also have 6.18 copies); many are experimental changes without a split series. | Keep in the fork; upstream only fixes that also apply to main 6.18 and have hardware evidence. |
| mt76 patches | `package/kernel/mt76/patches/` (0001, 0003, 0005, 0008 to 0015); `package/kernel/mt76/Makefile` (source `OpenWRT-fanboy/mt76-firmware`, 2026-10-08) | `local only` — main uses `openwrt/mt76` 2026-10-28 with only `100-` and `101-`. | Different base tree; the NPU patches depend on fork-only code; no upstream review. | Rebase on `openwrt/mt76`, split per patch, and submit to `openwrt/mt76` or the OpenWrt mailing list; keep NPU-only patches in the fork. |
| wifi-scripts (51/58) | `package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/hostapd.uc`, `files-ucode/lib/netifd/wireless/mac80211.sh`, `files/lib/netifd/wireless/mac80211.sh`, `files/lib/netifd/hostapd.sh`; `patches/010-wifi-scripts-enable-EHT-beamforming-by-default.patch` | `local only` for the band inference, country guard and 320 MHz changes. The txpower backport comes from open RFC #23990 (unmerged). No files numbered 51 or 58 exist in this repo. | The `51/58` identifier is not present in this tree, its history, the fanboy branches, or the issue titles; the local changes are not split into reviewable patches; #23990 is unmerged. | Identify and link the `51/58` source. Split the local changes into country/band guard, 320 MHz, EHT beamforming and txpower; submit the first three as separate wifi-scripts PRs and keep txpower behind #23990. |
| U-Boot / chainloader | `package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch`; `package/boot/uboot-airoha/Makefile`; `package/boot/uboot-tools/uboot-envtools/files/airoha_an7581` | `PR #26296 open` — adds `403-add-gemtek-xr1710g.patch`, a different implementation that drops the installer entries. | Two chainloader implementations; the PR version is the one tested by its author; installation still needs a serial console. | After merge, adopt the PR's U-Boot patch and drop `999`; re-test the recovery/TFTP menu. |
| Image/device entry and product packages | `target/linux/airoha/image/an7581.mk` (`Device/gemtek-ubi-common`, `gemtek_xr1710g-ubi`); `base-files/etc/board.d/02_network` (adds the `US` country); `05_compat-version`; `package/luci-app-*` | `PR #26296 open` — hardware-only board entry. The local extra packages (`kmod-nft-fullcone`, `usteer`, `ethtool-full`, `luci-app-*`) and the US country default are `local only`. The PR's XR block does not set `DEVICE_COMPAT_VERSION` or a `05_compat-version` entry; local does. The LuCI apps are not in `openwrt/luci`. | The product package set and country default are not upstream material; the missing compat gate in the PR must be confirmed before the local gate is dropped; the LuCI apps need separate review. | Rebase the board entry on #26296; keep product packages in the build config/overlay; confirm or fix the compat gate with the PR author; submit LuCI apps to `openwrt/luci` individually. |
| platform.sh upgrade path | `target/linux/airoha/an7581/base-files/lib/upgrade/platform.sh` (FDT cross-flash guard, requires `dumpimage`) | `PR #26296 open` — rebuilds the `factory` volume from the vendor partition. The local FDT guard is `local only`. | Two independent upgrade implementations; `dumpimage` is not in the PR's package set; both need hardware test coverage. | Keep the PR's factory rebuild; port the FDT cross-flash guard as a separate patch with its own test evidence if it is still wanted. |
| Local-only lab scripts and local feed | `scripts/wireless/*.sh` (PRs #127, #129-135), `scripts/check-npu-firmware.sh` (#126), `scripts/wifi7-supply-bench.sh` (#128); `scripts/pcie-single-cut.sh` (planned by #97, not present); `scripts/lib/netwatchdog-guard.sh` (planned by #102, not present); `local-feed/net/netifyd/` | `not for upstream` — lab topology/hardware tooling and a third-party package with local patches. | The scripts live only on unmerged branches; `pcie-single-cut` and the netwatchdog guard are not implemented yet; the rest are tied to this bench. | Keep in this fork or a separate lab repo; never send to `openwrt/openwrt` or bundle with #26296. |

## Next 3 actions

1. **Merge #26296, then rebase.** Track #26296 until it lands, then rebase
   `xr1710g` on the merged tree and delete the duplicate DTS, U-Boot, board,
   `01_leds`, and `platform.sh` pieces, keeping only the real deltas. Track
   #26297 (LED mode) and #26508 (GPIO mux) for ordering, because #26508 can swap
   the `phy1_led0`/`phy1_led1` pins.
2. **Reconcile the firmware and package baselines.** Bump the local
   `linux-firmware` to at least 20261019, decide whether the v0.8 NPU blobs go
   to linux-firmware (#87) or stay a local override, and align the mt76 source
   with `openwrt/mt76` and wifi-scripts with main.
3. **Submit the local-only series in order.** After #26296: (a) 10G
   PCS/PHY fixes (744/745/747/748/749) plus the DTS quirks, (b) 10G LED support,
   (c) mt76/NPU patches. Each as its own series with hardware evidence; keep
   lab scripts, netwatchdog, netifyd and LuCI apps local.

## Do not upstream

- `scripts/wireless/*.sh`, `scripts/pcie-single-cut.sh`, netwatchdog, and the
  `local-feed/net/netifyd` package: lab or vendor tooling, `not for upstream`.
- `target/linux/airoha/patches-7.3/998-silence-PHY-LED-pinctrl-error.patch`:
  hides a real pinctrl error; fix the mapping instead.
- The local LuCI apps: they need individual `openwrt/luci` PRs, not a bundle
  with the device support.
- The v0.8 NPU binaries: submit them to linux-firmware with provenance, or keep
  them local; never to `openwrt/openwrt`.
- The local fan single-owner rewrite: W1700K behaviour changes need their own
  review.

## Notes on the ambiguous items

- **wifi-scripts 51/58.** No file, branch, commit subject or issue title in this
  repo or the fanboy fork contains a `51`/`58` wifi-scripts series. The row
  above maps the item to the wifi-scripts files that are actually tracked here.
  If `51/58` names patches kept outside this repository, add their URL or path
  next to the row so the next worker can reconcile them.
- **netwatchdog.** Not a tracked file. Issues #102 and #108 use it as a
  precondition for destructive experiments; the guard helper is planned but not
  present at this commit.
- **hif2.** Not a tracked file either. It is the MT7996 NPU host-interface area
  referenced by issues #96 and #98; the code is in the mt76 source fetched at
  build time, not in this tree.

## Verification performed

- `gh pr view 26296 --repo openwrt/openwrt`: open, 3 commits, 12 files, head
  `16bbb337f4c5`; #26297 and #26508 open; #23990 open.
- `gh api repos/openwrt/openwrt/contents/...?ref=main`: checked the DTS,
  `patches-6.18`, `an7581.mk`, `mt76`, `wifi-scripts` and firmware package
  layouts against main.
- `target/linux/airoha/Makefile`: `KERNEL_PATCHVER:=6.18`,
  `KERNEL_TESTING_PATCHVER:=7.3`; main has only `patches-6.18`.
- NPU blobs: sha256 and sizes from the local files; the linux-firmware master
  blobs were fetched from kernel.org on 2026-11-14 for comparison.
- No build, flash or device test was run for this change; this is a
  documentation-only file.
