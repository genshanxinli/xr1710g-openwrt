# AN7581 / MT7996 / NPU materials acquisition log

**Status:** research log, last surveyed 2026-11-15 (UTC+08:00)
**Tracking issue:** [#57](https://github.com/genshanxinli/xr1710g-openwrt/issues/57)
**Registry follow-up:** [#87](https://github.com/genshanxinli/xr1710g-openwrt/issues/87)

This file tracks the hardware and firmware documentation this port still needs,
where it was looked for, and the exact result of each attempt. It is a research
log, not a datasheet copy: no vendor document text, register tables or firmware
blobs are reproduced here. File sizes and SHA-256 digests are recorded so that a
later acquisition can be matched to the attempt that produced it.

## How to read this log

- **AVAILABLE** — a public copy was obtained or is already in this tree.
- **PARTIAL** — the public source covers only part of the need.
- **MISSING** — no public copy was located by the listed attempt. This is not
  proof that no copy exists.
- **GATED** — a vendor/account channel is required; no public document browsing.
- **BLOCKED** — the attempt was refused or rate-limited from this host.
- **UNVERIFIED** — reported by another source, not independently checked.

"Not found" always refers to a specific attempt on a specific date. Negative
results are recorded as 404, redirect, empty download section, zero search hits,
or access denial, and are not turned into claims about what a vendor may hold.

Checks were made with direct HTTP fetches (`curl`; HTTP status recorded), the
GitHub API and code search, FCC ID filings, Internet Archive and vendor pages.
The general web-search backend was unavailable during this survey (HTTP 402 from
the search API), and several search endpoints were blocked; see
[Method limits](#method-limits). No vendor NDA or login was bypassed.

Dates: survey attempts are 2026-11-15 (UTC+08:00). Prior evidence is dated by
its GitHub issue or commit. GitHub issue timestamps are UTC.

## Summary

- **Still missing:** AN7581 datasheet/TRM; MT7996 vendor register guide; Realtek
  RTL8261BE and 2.5G NIC datasheets; a fixed EN7581 NPU 7.8 image (above v006).
- **Partial:** public NPU firmware and source (linux-firmware, FDK, ClankerNPU);
  MT7996 upstream headers and firmware; AN7583 HDG v1.2 (reported available,
  custody unverified); 4SS/6E module documentation (hardware not acquired); MLO
  community reports (no controlled measurement data).
- **Public positives found here:** linux-firmware NPU v03 for EN7581+MT7996,
  linux-firmware MT7996 Wi-Fi firmware, public 4SS 5 GHz/6 GHz module datasheets
  from Wallys, and six dated MLO reports/PRs in openwrt/mt76 and
  openwrt/openwrt.

## 1. AN7581 TRM / datasheet

| Date | Material | Why needed | Attempted source / URL / query | Result | Next contact |
|---|---|---|---|---|---|
| 2026-11-15 | AN7581 datasheet / TRM | Register-level reference for PPE, QDMA, NPU and PCS; needed to check DTS-derived assumptions and errata | Airoha AN7581 product page: <https://www.airoha.com/products/p/NpfqGLnZiZuYUZ6N> | **MISSING** — HTTP 200, marketing/specification page only. Its `DOWNLOAD` section is present but contains no document links or files. No datasheet/TRM found. | Airoha sales/FAE via <https://www.airoha.com/contact>; request the AN7581 TRM and errata through the vendor document process |
| 2026-11-15 | AN7581 datasheet / TRM | Same | Internet Archive search `AN7581`: <https://archive.org/advancedsearch.php?q=AN7581&output=json>; GitHub repository search `AN7581` and code search `AN7581 datasheet`, `filename:AN7581*.pdf`, `EN7581 datasheet` | **MISSING** — Internet Archive `numFound: 0`. GitHub: 26 repository hits, none a datasheet/TRM repository; they are firmware, SDK and build-config repos. The SDK mirror `lotusmomo/airoha_sdk` has 2,746 files, no PDF/doc/TRM path and no license. `filename:AN7581*.pdf` returned 0 hits. | Same; review SDK licensing before using any source from that mirror |
| 2026-11-15 | Board schematics / block diagram (partial TRM substitute) | Board wiring, PHY and PCIe topology when the SoC TRM is unavailable | FCC ID `MXF-XR1710G` filing: <https://fccid.io/MXF-XR1710G> (latest application 2024-05-30) | **PARTIAL** — HTTP 200. Exhibits include the user manual, internal/external photos and test reports. `Block Diagram`, `Schematics` and `Operational Description` are listed but marked **Metadata only** (not downloadable). No datasheet/TRM exhibit. | Gemtek/Airoha vendor process; FCC confidential exhibits require applicant release |
| 2026-11-15 | AN7581 datasheet / TRM (search access) | Confirm whether a public copy is indexed | OpenWrt forum search; FCC OET `GenericSearchResult.cfm` POST; fccid.io search page | **BLOCKED** — forum search returned HTTP 429 (rate limited); FCC OET POST returned HTTP 403 (Akamai); fccid.io search returned HTTP 403 (Cloudflare). The direct FCC ID page worked (row above), so these are access limits, not absence evidence. | Retry from a browser; use the known FCC ID rather than site search |
| 2026-11-14 (report) / 2026-11-15 (search) | AN7583 HDG v1.2 (partial AN7581 substitute) | The AN7583 hardware design guide is reported available and is a same-family reference | Issue #57 current evidence; GitHub code search `AN7583 HDG`; Bing exact query `"AN7583" HDG` | **UNVERIFIED** — issue #57 states AN7583 HDG v1.2 is available but records no URL or hash. Public search found no copy (GitHub code search 0 hits; Bing exact query returned no results from this region). Custody and identity not verified here. | Repository owner: confirm custodian and SHA-256, then add the entry to #87; use only as a partial reference, not as an AN7581 TRM |

## 2. NPU firmware and source

| Date | Material | Why needed | Attempted source / URL / query | Result | Next contact |
|---|---|---|---|---|---|
| 2026-11-15 | EN7581+MT7996 NPU firmware (upstream linux-firmware) | Baseline for NPU offload; A/B candidate against the in-tree v08 image (#45) | linux-firmware `airoha/` tree: <https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/airoha>; file history commit `1043c0303910c9f209959dfa39493ab9ea403291` (2026-01-30) | **AVAILABLE (partial)** — `en7581_MT7996_npu_rv32.bin`: 122,336 B, SHA-256 `e743d1b59a9ca6d043e38ff71075e8d28702a104b94abb17a4035514efda4643`; `strings` reports `TLB7.7.0.0_v03` and `*_eagle` symbols. `en7581_MT7996_npu_data.bin`: 3,084 B, SHA-256 `61a75afb052feed2ceb2f3023e16f50317c05c78f9c8e564bf01924ce39c7ec1`. WHENCE: driver `airoha-npu-7581-mt7996`, "used for MT7990 offloading", license `LicenseRef-LICENSE.airoha` (redistributable). | Bench-test per #45; do not replace the in-tree v08 image on version-number grounds alone |
| 2026-11-15 | In-tree NPU firmware v08 | Current device baseline | `package/firmware/linux-firmware/files/airoha/`; commit `29ec6c6d36` (2026-10-23, "linux-firmware: use NPU v0.8 firmware") | **AVAILABLE (in tree)** — `en7581_MT7996_npu_rv32.bin`: 125,832 B, SHA-256 `7068a987bb95e89129a69de10d598f234a4400023eb23aacc8eb377e5f0fe0ea`; `strings` reports `TLB7.7.0.0_v08` and `*_eagle` symbols. `en7581_MT7996_npu_data.bin`: 3,092 B. Recorded as the baseline, not as a missing material. | Keep; use the upstream v03 image as the A/B candidate in #45 |
| 2026-11-15 | NPU firmware "0.1111" candidate | Candidate named in #45 as a linux-firmware image | #45 (`08aa0401`, 122,336 B, "believed 0.1111"); linux-firmware commit lookup; current tree file `strings` | **MISSING / UNVERIFIED** — `08aa0401` is not a linux-firmware commit (`Bad object id`). The current tree file is 122,336 B but its version string is `TLB7.7.0.0_v03`, not `0.1111`. No file carrying a `0.1111` marker was found. | Ask the reporter for the source of the "0.1111" label; verify by SHA-256 and version string before bench work |
| 2026-11-15 | NPU source and FDK | Offload handler work, flow stats (#36) and reproducible builds | <https://github.com/ClankerConstruction/ClankerNPU> (public, no license file, updated 2026-11-13); <https://github.com/hurryman2212/airoha-npu-fdk> (MIT, updated 2026-10-29) | **AVAILABLE (partial)** — the FDK has AN7581 platform headers and a build; ClankerNPU has AN7581/MT7996 support. Caveat: ClankerNPU's README maps MT7996 to `kite`, while both the in-tree v08 and upstream v03 firmware contain `*_eagle` symbols and #34/#65 identify the stock image as eagle. ClankerNPU has no license file; the FDK is MIT. | Resolve the kite/eagle discrepancy against #34 and #65 before building; license review before shipping any binary |
| 2026-11-15 | EN7581 NPU 7.8 fixed firmware (CVE-2026-89142) | #40 states the CVE affects `<= TLB7.8.0.0_v006`; the board needs a fixed EN7581 image | linux-firmware `airoha/an7583_npu_rv32.bin`; #40 extraction procedure; #65 identity table | **PARTIAL** — the public AN7583 image is 85,432 B, md5 `9650a6223338d29312e9c918bf9aacd2`, SHA-256 `0d8bc1d22eee5bb4f36a70d1d450132f55493b88348d46e532894b564a36cca4`, `strings` reports `TLB7.8.0.0_v005` (WHENCE Version 0.5). It matches the AN7583 7.8 artifact noted in #65, but it is **AN7583, not EN7581**, and v005 is still at or below the v006 ceiling in #40. No EN7581 image above the v006 ceiling was found. | Airoha security contact: <https://www.airoha.com/about/governance/intellectual/security-contact>; follow the #40 extraction path from an AN7583 full image, then verify version and hash before use |

## 3. MT7996 registers and firmware

| Date | Material | Why needed | Attempted source / URL / query | Result | Next contact |
|---|---|---|---|---|---|
| 2026-11-15 | MT7996 register map (upstream, partial) | NPU/offload register validation (#51); fill gaps left by vendor documentation | Upstream `regs.h`: <https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/wireless/mediatek/mt76/mt7996/regs.h> | **PARTIAL** — HTTP 200; 838 lines / 29,964 B; 55 `RRO` references; **0** `AIROHA` or `NPU` register definitions. Covers RRO but not the Airoha offload register block. | Use together with #51; request the vendor register guide for the gaps |
| 2026-11-15 | Airoha offload protocol and mt76 NPU plumbing | NPU message/queue contract and host init | <https://raw.githubusercontent.com/torvalds/linux/master/include/linux/soc/airoha/airoha_offload.h>; <https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/wireless/mediatek/mt76/mt7996/npu.c> | **PARTIAL** — header: 317 lines / 8,667 B, queue/message/DMA descriptor constants only, no register map. `npu.c`: 631 lines / 15,649 B, init and message plumbing only. Both public. | No acquisition needed; use as the protocol reference |
| 2026-11-15 | MT7996 vendor register guide / TRM | Full register documentation for RRO, WFDMA and NPU interaction | MediaTek Wi-Fi 7 page: <https://www.mediatek.com/products/networking-and-connectivity/wifi-7>; product URLs tried as `/products/.../mediatek-mt7996`; MediaTek Online: <https://online.mediatek.com/home/> | **MISSING / GATED** — Wi-Fi 7 page HTTP 200 but 0 `MT7996` matches and no MT7996 PDF; the product URL forms tried returned HTTP 404; MediaTek Online returns a login/"Create Account" page only, with no public document browsing. | MediaTek FAE via an authorized distributor; request the MT7996 register guide through a MediaTek Online account/NDA process |
| 2026-11-15 | MT7996 firmware | Wi-Fi firmware baseline | linux-firmware `mediatek/mt7996/` tree: <https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/mediatek/mt7996>; WHENCE | **AVAILABLE** — public files include `mt7996_wm.bin` 2,656,440 B, `mt7996_wa.bin` 510,000 B, `mt7996_rom_patch.bin` 37,216 B, `mt7996_dsp.bin` 192,688 B and 7,680 B EEPROM images; `_233` variants are present. WHENCE versions include `mt7996_wm` `20260310125322` and `mt7996_wa` `20260311120325`; license `LicenseRef-LICENCE.mediatek` (redistributable). | Update through the linux-firmware package; no separate acquisition needed |

## 4. 2.5G / 10G documentation

| Date | Material | Why needed | Attempted source / URL / query | Result | Next contact |
|---|---|---|---|---|---|
| 2026-11-15 | AN7581 PCS/SerDes and 10G/2.5G register documentation | USXGMII and 10G/2.5G link bring-up; the community network reference maps the 10G paths through the SoC PCS blocks | AN7581 TRM attempts (section 1); community AN7581 network reference: <https://github.com/gregordinary/device-ref/blob/main/an7581/network-reference.md> | **MISSING (register level)** — the community reference is HTTP 200 and documents the PON PCS (`0x1fa0_8000`), Ethernet PCS (`0x1fa0_9000`), GDM/QDMA/PPE/NPU blocks, but states its facts rest on one board and OpenWrt's `an7581.dtsi` and grades every claim `[source]`, `[consensus]` or `[reported]`. No register-level document. | Airoha TRM request; treat the community reference as a map, not authoritative register semantics |
| 2026-11-15 | Realtek RTL8261BE 10G PHY datasheet | RTL8261BE is the board's 10G PHY per the README; needed for init, firmware loading and link debugging | Realtek product URL: <https://www.realtek.com/en/products/communications-network-ics/item/rtl8261be>; GitHub code search `RTL8261BE filename:*.pdf`; community SFP note: <https://github.com/woziwrt/bpi-r4-deploy/blob/main/RTL8261BE-10G-SFP.md> | **MISSING** — the Realtek URL returns HTTP 301 to the homepage and serves no product content; GitHub PDF search returned 0 hits; the community note is HTTP 200 and documents SFP-10G-T behaviour and a 2026-10-28 test, but is not a datasheet. The community device reference cites "Realtek's datasheet" without a public link. PHY firmware itself is already packaged in `package/firmware/rtl826x-firmware` (source date 2026-01-24, version `0cd4abe2b0bf197f75c27088f86a74c7ddb103b4`); the missing item is the register/programming document. | Realtek FAE through a distributor; SFP module vendor for module-level documentation |
| 2026-11-15 | 2.5G USB NIC (RTL8156B) datasheet | 2.5G bench profile (#85) and wired-path tests (#70, #44) | GitHub code search `RTL8156B filename:*.pdf`; Realtek public product/search paths (`ProductHits` returned the generic site page, no result list) | **MISSING** — GitHub PDF search returned 0 hits; no public vendor datasheet was located through the attempted Realtek paths. #85 defines the test but does not supply the document. | Realtek/distributor; record the NIC model and revision when the hardware is purchased |

## 5. 4SS / 6E client data

| Date | Material | Why needed | Attempted source / URL / query | Result | Next contact |
|---|---|---|---|---|---|
| 2026-11-15 | 4x4 6 GHz client card (QCN9274/QCN6274) | #52 records that no 4SS client exists; the 6G320 ceiling needs one | Wallys DR9274-6G page: <https://www.wallystech.com/WiFi7_product/DR9274-6G-wifi7-QCN9274-QCN6274-card-moulde-Qualcomm-M.2-Slot-4x4-6G-single-band-Wallys.html>; datasheet: <https://www.wallystech.com/upload/DR92746G.pdf> | **AVAILABLE (documents)** — page HTTP 200; datasheet HTTP 200, 212,044 B, 6 pages, SHA-256 `750a85d34de2160bf1503af18dc8ca6f0cfe1e3e32df5558d5090e7bfaf1d8e9`. Specs: 4x4 6 GHz MU-MIMO, up to 11,530 Mbps PHY, 320 MHz, QCN9274/QCN6274, M.2 E-key PCIe 3.0, 4x MMCX, 8.5 W max. Documents acquired; hardware not purchased or tested. | Wallys sales/sample; the host has no free PCIe slot (#52), so an M.2 adapter/external enclosure or a second board is required; verify ath12k station-mode support |
| 2026-11-15 | 4x4 5 GHz client card | 5G160 4SS test arm | Wallys DR9274-5G page: <https://www.wallystech.com/WiFi7_product/DR9274-5G-wifi7-card-QCN9274-QCN6274-moulde-Qualcomm-M.2-Slot-4x4-5G-single-band-Wallys.html>; datasheet: <https://www.wallystech.com/upload/DR92745G.pdf> | **AVAILABLE (documents)** — page HTTP 200; datasheet HTTP 200, 222,802 B, 6 pages, SHA-256 `9162d7f6d95d16bf18701d2a1a6bb58d6da5db425c125f0483d080368177fe77`. Specs: 4x4 5 GHz MU-MIMO, up to 5,765 Mbps, M.2/PCIe 3.0. Hardware not purchased or tested. | Same as the 6 GHz card |
| 2026-11-15 | QCN9274 2x2 2.4+5 GHz module (candidate check) | Check whether a cheaper existing module covers the need | Compex WLE7002E25 page: <https://www.compex.com.sg/product/wle7002e25/>; [datasheet link](https://compex.com.sg/wp-content/uploads/2025/09/wle7002e25_datasheet_25-sept-2025.pdf) | **PARTIAL / REJECT** — page documents a 2x2 2.4+5 GHz module with no 6 GHz and no 4SS; it cannot cover the 4SS/6E requirement. The datasheet link returned HTTP 404 on the first fetch; later fetches were TLS/WAF-blocked. | Compex sales for a 6 GHz/4x4 variant, if one exists; otherwise Wallys |
| 2026-11-15 | QCN9274 chip-level 4SS/6E data | Chip-level capability and errata for a 4x4 6 GHz client | GitHub repository search `QCN9274 4x4`; module pages above | **MISSING** — no public Qualcomm datasheet or product brief was located; the available data is module-vendor level. The Wallys 4x4 6 GHz datasheet is the only 4x4 6 GHz document acquired. | Qualcomm FAE through a distributor; module datasheets may be sufficient for the lab |
| 2026-11-14 | 4SS lab host/interface data | The 4SS client needs a host PCIe interface and cooling | Issue #52: <https://github.com/genshanxinli/xr1710g-openwrt/issues/52> | **PARTIAL** — the issue records that no 4SS client exists and the host has no free PCIe slot. The Wallys M.2 cards found here cover the radio side but need an adapter or a second board. | Issue #52 owner: choose the adapter/second board and add the model to the lab plan |

## 6. MLO community data

| Date | Material | Why needed | Attempted source / URL / query | Result | Next contact |
|---|---|---|---|---|---|
| 2026-09-26 | MLO field report: MT7996 on XR1710G | Real-world failure modes for the 2-link harness (#49) | openwrt/mt76 issue #1139: <https://github.com/openwrt/mt76/issues/1139> | **AVAILABLE (report)** — open. Environment names AN7581 (Econet XR1710G) and MT7996, two AP-MLDs and an Apple MacBook as MLO client. After a firmware SER event, MLO stations lose management-frame TX and are repeatedly deauthenticated. A field report, not a controlled measurement. | Compare with the local b21 image; ask the reporter for logs/PCAP; add the case to #49 |
| 2026-09-26 | AP-MLD link-width collapse | Test teardown/ordering can invalidate results; need to know this failure mode | openwrt/openwrt issue #25413: <https://github.com/openwrt/openwrt/issues/25413> | **AVAILABLE (report)** — open. Reconfiguring an unrelated radio collapses the MLD 5 GHz links to 20 MHz; neither `wifi reload` nor `wifi reconf` restores them, only a full reboot. | Replicate in #49; ask the reporter for the exact configuration and whether the 6 GHz link also changes |
| 2026-09-26 | MLO bring-up blockers | Both can make a 2-link test fail before traffic starts | openwrt/openwrt issues #25414 and #25415: <https://github.com/openwrt/openwrt/issues/25414>, <https://github.com/openwrt/openwrt/issues/25415> | **AVAILABLE (reports)** — open. #25414: `mld_ap` rejected on HE htmode links ("Cannot enable mld_ap when IEEE 802.11be is disabled"). #25415: MLO stations bounced by `NL80211_ATTR_STA_VLAN` (vlan_id=0) on kernels without ML VLAN support. | Check the local configuration against both before running #49 |
| 2026-09-14 (closed) / 2026-08-24 (open) | MLO control-path fixes | Channel selection and hostapd association fixes affect test setup | openwrt/openwrt issue #25181: <https://github.com/openwrt/openwrt/issues/25181>; PR #24891: <https://github.com/openwrt/openwrt/pull/24891> | **AVAILABLE (reports)** — #25181 (closed): with `channel=auto` on both radios, ACS scans collide and the second link is disabled instead of retried. PR #24891 (open): hostapd 802.11be MLO partner-link association, security-flag and re-association fixes. | Track #24891; use fixed channels and explicit link configuration for the first #49 run |
| 2026-11-15 | 3-link MLO evidence | #49 records 3-link as a known community black-hole risk | GitHub issue searches `3-link`, `3 links`, `three links` in openwrt/mt76 and openwrt/openwrt; issue #49 | **MISSING (primary report)** — no primary public report was located by these searches; only issue #49's statement of the risk. No controlled 3-link aggregation data was found. | Ask the #49 owner/reporters for the original report; do not run 3 links until the 2-link path is stable |

## 7. Method limits

These limits are recorded so that a "not found" result is not read as a
stronger claim than it is.

- **General web search was unavailable.** The search API returned HTTP 402
  during this survey; the log therefore relies on direct URLs, GitHub search,
  FCC IDs, Internet Archive and known vendor pages.
- **Several search endpoints were blocked.** OpenWrt forum search returned
  HTTP 429; the FCC OET result form returned HTTP 403; fccid.io search returned
  HTTP 403; Reddit search returned HTTP 403. The direct FCC ID page worked.
- **Some vendor pages are JavaScript-driven.** The Airoha AN7581 page's
  `DOWNLOAD` section was empty in the fetched HTML; a browser check is still
  worth doing before treating it as permanently empty.
- **Compex fetches were inconsistent.** The product page was seen once with
  HTTP 406 while returning content, later redirected, and later failed at TLS.
  The datasheet URL returned HTTP 404 on one request; later requests failed at
  TLS/WAF with no HTTP response. The 404 is recorded as observed once, not as a
  stable state.
- **"0.1111" is an unverified label.** The value came from issue #45; neither a
  commit nor a version string carrying it was found in linux-firmware.
- **AN7583 HDG v1.2 is unverified.** It is reported available in issue #57, but
  no URL or hash was provided; its custody is unknown to this log.
- **Community reverse-engineering is not a datasheet.** The `device-ref` AN7581
  and MT7996 references are useful maps compiled from DTS, reports and
  measurements. They do not replace a manufacturer TRM and should not be cited
  as register-semantics authority.

## 8. Next actions

1. **Airoha:** request the AN7581 TRM and errata through the sales/FAE form;
   request fixed EN7581 NPU firmware (above the v006 ceiling) through the security contact.
2. **MediaTek:** request the MT7996 register guide through a distributor/FAE and
   a MediaTek Online account.
3. **Realtek:** request RTL8261BE and RTL8156B datasheets through a distributor;
   confirm which RTL8261 variant the XR1710G revision actually carries.
4. **Wallys:** request samples of the 4x4 5 GHz and 4x4 6 GHz QCN9274 cards and
   settle the M.2 host adapter/second-board question with the #52 owner.
5. **MLO:** run the #49 2-link harness against the local image, then compare with
   #1139/#25413; locate the primary 3-link report before attempting three links.
6. **Registry:** add URL, date, size and SHA-256 for every acquired item to the
   #87 materials registry. Do not commit proprietary documents or firmware
   blobs to this repository; record the link, digest and custodian instead.

## 9. Source provenance

- Airoha AN7581 page, contact page and security page were fetched 2026-11-15
  (HTTP 200 each).
- The linux-firmware tree and files were fetched 2026-11-15 from
  `git.kernel.org`; file sizes and hashes above are from those downloads.
- The FCC filing page was read on 2026-11-15; its exhibit list is the source for
  the "Metadata only" entries.
- Wallys pages and datasheets were fetched 2026-11-15; hashes are of the
  downloaded PDFs, not of any file added to this tree.
- Issue and PR facts are cited by number and date; the GitHub issue timestamps
  are UTC.
