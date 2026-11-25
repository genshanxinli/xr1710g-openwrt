#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# build-eagle-v4.sh - build and statically validate the AN7581 + MT7996
#                     eagle v4 DDR-descriptor NPU firmware.
#
# Target image: SOC=AN7581 WIFI=MT7996.  The XR1710G board is an eagle/RRO
# part, so this build must use WIFI_EAGLE and must not fall back to kite.
#
# Source: ClankerConstruction/ClankerNPU at a pinned commit, plus the
# source patch embedded below.  The patch is what moves the firmware from
# the upstream SRAM descriptor layout to the stock v08 DDR layout:
#
#   * the ring descriptor arena leaves the 64 KB SRAM and becomes the
#     stock v08 DDR type1 region at NPU 0x3E8A2000 (host npu_pkt
#     0x8A0A2000), size 0x4A040;
#   * qid10/11/12 answer with the stock ring7/8/9 offsets
#     0x18020/0x19020/0x1B020, and the host-visible value stays
#     base & 0x1FFFFFFF (0x1E8... on the wire), never an unmasked 0x3E8...;
#   * SRAM types 1/29/44 are deleted, type26 grows to 0x4000 so the three
#     MSDU page id pools and the TDMA rx ids share it, and type129/type133
#     use the stock sizes 0xE5FF/0x11000.
#
# This script never writes a device, never flashes, and never needs a
# board.  It only builds two binaries and statically inspects the ELF and
# the raw images.  Binaries are build products and must not be committed.
#
# Usage:
#   tools/npu-firmware/build-eagle-v4.sh [--dry-run] [--src-dir DIR]
#                                        [--out-dir DIR] [--jobs N]
#
#   --dry-run   print the exact steps and the expected static checks, then
#               exit 0; no network access, no compiler, no files written.
#
# Environment: CROSS (default riscv64-elf-), BUILD_ROOT, CLANKER_SRC,
#              OUT_DIR, CLANKER_URL, CLANKER_COMMIT.
#
set -euo pipefail

readonly CLANKER_URL="${CLANKER_URL:-https://github.com/ClankerConstruction/ClankerNPU.git}"
readonly CLANKER_COMMIT="${CLANKER_COMMIT:-735529c10d5120e10f7e4a6ddf97fb384fce9903}"
readonly CLANKER_GITREV="${CLANKER_GITREV:-eagle-v4-ddr}"
readonly CROSS="${CROSS:-riscv64-elf-}"
JOBS="${JOBS:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT

BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build_dir/npu-firmware}"
SRC_DIR="${CLANKER_SRC:-$BUILD_ROOT/ClankerNPU}"
OUT_DIR="${OUT_DIR:-$BUILD_ROOT/eagle-v4}"
PATCH_FILE="$BUILD_ROOT/eagle-v4-source.patch"

usage() {
	cat <<'EOF'
build and statically validate the AN7581 + MT7996 eagle v4 NPU firmware

usage: tools/npu-firmware/build-eagle-v4.sh [options]

  --dry-run        print the steps and expected checks only; no network,
                   no compiler, no files written
  --src-dir DIR    use DIR for the ClankerNPU checkout (default: <build>/ClankerNPU)
  --out-dir DIR    copy artifacts and logs to DIR (default: <build>/eagle-v4)
  --jobs N         make -j N
  -h, --help       show this help

No device is contacted and no firmware is written or flashed by this script.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

say() {
	printf '%s\n' "$*"
}

write_patch() {
	mkdir -p "$BUILD_ROOT"
	cat > "$PATCH_FILE" <<'EAGLE_V4_PATCH'
diff --git a/npu_config.h b/npu_config.h
index 041cbb6..cc1b9d5 100644
--- a/npu_config.h
+++ b/npu_config.h
@@ -16,7 +16,9 @@
  *   AN7583 → 6 cores
  *
  * WiFi chip → driver path:
- *   MT7916, MT7996              → kite (TDMA RX path, WiFi chip name table)
+ *   MT7916                      → kite (TDMA RX path, WiFi chip name table)
+ *   MT7996 on AN7581            → eagle (XR1710G board: RRO/MSDU page/ind cmd)
+ *   MT7996 on AN7552/AN7583     → kite
  *   MT7991, MT7992, MT7993      → eagle (RRO, MSDU page ring, ind cmd ring)
  *   NOWIFI                      → no WiFi offload
  */
@@ -39,7 +41,17 @@
 #error "Define one SoC: AN7552, AN7581, or AN7583"
 #endif
 
-#if defined(MT7916) || defined(MT7996)
+/*
+ * XR1710G board exception: AN7581 + MT7996 is an eagle/RRO part.
+ * The stock v08 firmware on this board has 19 eagle strings and no
+ * kite strings, and the host forces MT76_HWRRO_V3 for MT7996.  Keep
+ * MT7996 on kite for the other SoCs (AN7552/AN7583) and keep MT7992
+ * eagle unchanged.
+ */
+#if defined(WIFI_EAGLE) || (defined(AN7581) && defined(MT7996))
+#define WIFI_EAGLE
+#define HAS_WIFI
+#elif defined(MT7916) || defined(MT7996)
 #define WIFI_KITE
 #define HAS_WIFI
 #elif defined(MT7991) || defined(MT7992) || defined(MT7993)
diff --git a/npu_globals.c b/npu_globals.c
index 5a0cd54..c333a24 100644
--- a/npu_globals.c
+++ b/npu_globals.c
@@ -466,10 +466,10 @@ u8 wifi_port_band_5g[16];
 
 /* host tx packet buffer, published over the mailbox */
 volatile u32 npu_tx_pkt_buf_addr;
-u32 tdma_rx_dscp_base[2];
+u32 tdma_rx_dscp_base[3];
 u32 tdma_rx_desc_count;
 u32 tdma_rx_alloc_fail;
-u32 tdma_rx_ridx[2];
+u32 tdma_rx_ridx[3];
 
 #ifdef WIFI_KITE
 u32 ratelimit_table[32];
@@ -493,20 +493,20 @@ volatile u32 eagle_rro_cfg[26];
 volatile u32 eagle_rro_active;
 
 /* Host ring bases, keyed by the ring index the host puts in interfaceID. */
-u32 eagle_rx_ring_pcie_base[2];
-u32 eagle_msdu_pg_pcie_base;
+u32 eagle_rx_ring_pcie_base[3];
+u32 eagle_msdu_pg_pcie_base[3];
 u32 eagle_ind_cmd_pcie_base;
 u32 eagle_txdone_pcie_base;
 u16 eagle_txdone_ring_cnt;
 
-u32 eagle_tx_ring_pcie_base[2];
+u32 eagle_tx_ring_pcie_base[3];
 u32 eagle_tx_ring_pcie_base_r3;
 
-u32 eagle_txd_space[2];
-u32 eagle_tx_buf_space_pg[2];
+u32 eagle_txd_space[3];
+u32 eagle_tx_buf_space_pg[3];
 
 u32 eagle_rx_txdone_desc_base;
-u32 eagle_msdu_pg_desc_base;
+u32 eagle_msdu_pg_desc_base[3];
 
 u32 eagle_pkt_buf_addr;
 
@@ -521,18 +521,17 @@ u32 eagle_txdone_id_base;
 u32 eagle_chip_info[6];
 u32 eagle_phy_tx_gpio;
 
-u32 eagle_stage_buf0;
-u32 eagle_stage_buf1;
-u32 eagle_stage_base[2];
-u16 eagle_stage_widx[2];
-u16 eagle_stage_ridx[2];
+u32 eagle_stage_buf[3];
+u32 eagle_stage_base[3];
+u16 eagle_stage_widx[3];
+u16 eagle_stage_ridx[3];
 
-u32 eagle_rx_ring_desc_base[2];
+u32 eagle_rx_ring_desc_base[3];
 u32 eagle_ind_cmd_desc_base;
-u16 eagle_rx_ring_size[2];
-u16 eagle_rx_ring_cpu_idx[2];
-volatile u8 eagle_rx_ring_init_done[2];
-u16 eagle_rx_ring_bufid[2][1536];
+u16 eagle_rx_ring_size[3];
+u16 eagle_rx_ring_cpu_idx[3];
+volatile u8 eagle_rx_ring_init_done[3];
+u16 eagle_rx_ring_bufid[3][1536];
 
 /* datapath state the host drives over the mailbox */
 volatile u32 eagle_rx_en;
@@ -551,13 +550,13 @@ u32 eagle_emi_cidx;
 u8 eagle_emi_cidx_valid;
 
 /* packet queues between the rxdmad ring and the host adaptor */
-u32 eagle_txq_base[2];
-u16 eagle_txq_widx[2];
-u16 eagle_txq_ridx[2];
-u32 eagle_mseg_base[2];
-u16 eagle_mseg_widx[2];
-u16 eagle_mseg_ridx[2];
-u32 eagle_txq_mutex[2];
+u32 eagle_txq_base[3];
+u16 eagle_txq_widx[3];
+u16 eagle_txq_ridx[3];
+u32 eagle_mseg_base[3];
+u16 eagle_mseg_widx[3];
+u16 eagle_mseg_ridx[3];
+u32 eagle_txq_mutex[3];
 u16 eagle_mseg_retry;
 
 /* rxdmad ring */
@@ -571,17 +570,17 @@ u32 eagle_seg_bufid[7];
 u16 eagle_seg_len[7];
 
 /* rx rings */
-u32 eagle_rx_ring_ridx[2];
-s8 eagle_rx_ring_kick[2];
+u32 eagle_rx_ring_ridx[3];
+s8 eagle_rx_ring_kick[3];
 
 /* wifi tx rings */
-u32 eagle_tx_ring_desc[2];
-u16 eagle_tx_ring_cpu_idx[2];
+u32 eagle_tx_ring_desc[3];
+u16 eagle_tx_ring_cpu_idx[3];
 
 /* wifi tx done ring */
 u32 eagle_txdone_ridx;
-u8 eagle_tx_first_push[2];
-u8 eagle_in_first[2];
+u8 eagle_tx_first_push[3];
+u8 eagle_in_first[3];
 u8 eagle_txdone_kick;
 #ifdef HAS_EAGLE_SYNC
 /* sync_method (type 31): set once the id left its rx descriptor */
diff --git a/npu_hostadpt.c b/npu_hostadpt.c
index 32824a1..14e809a 100644
--- a/npu_hostadpt.c
+++ b/npu_hostadpt.c
@@ -24,9 +24,9 @@ static u32 hostadpt_rx_ring_base;
 #ifdef HAS_NPU_WIFI_TX
 /* host -> NPU tx rings: 208-byte entries, bit0 of word0 is the own bit */
 #define HOSTADPT_IN_ENTRY     208
-u32 hostadpt_in_base[2];
-u32 hostadpt_in_size[2];
-u32 hostadpt_in_ridx[2];
+u32 hostadpt_in_base[3];
+u32 hostadpt_in_size[3];
+u32 hostadpt_in_ridx[3];
 #endif
 
 int hostadpt_init(void)
@@ -40,6 +40,13 @@ int hostadpt_init(void)
 			      NPU_ADDR_MASK;
 	hostadpt_in_size[0] = REG32(HOSTADPT_IN_MAX_CNT(0));
 	hostadpt_in_size[1] = REG32(HOSTADPT_IN_MAX_CNT(1));
+	/* band2 is only valid when the host programmed its ring */
+	if (REG32(HOSTADPT_IN_BASE_PTR(2)) != 0) {
+		hostadpt_in_base[2] =
+			(REG32(HOSTADPT_IN_BASE_PTR(2)) & 0x3FFFFFFF) |
+			NPU_ADDR_MASK;
+		hostadpt_in_size[2] = REG32(HOSTADPT_IN_MAX_CNT(2));
+	}
 #endif
 	/* wait for host to configure RX DMA pointer */
 	while (REG32(HOSTADPT_RX_DMA_PTR) == 0)
diff --git a/npu_internal.h b/npu_internal.h
index 67a1f9d..0f32de4 100644
--- a/npu_internal.h
+++ b/npu_internal.h
@@ -628,10 +628,10 @@ extern u8 wifi_port_band_2g[16];
 extern u8 wifi_port_band_5g[16];
 
 extern volatile u32 npu_tx_pkt_buf_addr;
-extern u32 tdma_rx_dscp_base[2];
+extern u32 tdma_rx_dscp_base[3];
 extern u32 tdma_rx_desc_count;
 extern u32 tdma_rx_alloc_fail;
-extern u32 tdma_rx_ridx[2];
+extern u32 tdma_rx_ridx[3];
 void tdma_rx_init(void);
 void np_skb_tx_force_reset(void);
 
@@ -649,17 +649,17 @@ extern u32 apcli_byte_count_5g[2];
 #endif
 
 #ifdef WIFI_EAGLE
-extern u32 eagle_rx_ring_pcie_base[2];
-extern u32 eagle_msdu_pg_pcie_base;
+extern u32 eagle_rx_ring_pcie_base[3];
+extern u32 eagle_msdu_pg_pcie_base[3];
 extern u32 eagle_ind_cmd_pcie_base;
 extern u32 eagle_txdone_pcie_base;
 extern u16 eagle_txdone_ring_cnt;
-extern u32 eagle_tx_ring_pcie_base[2];
+extern u32 eagle_tx_ring_pcie_base[3];
 extern u32 eagle_tx_ring_pcie_base_r3;
-extern u32 eagle_txd_space[2];
-extern u32 eagle_tx_buf_space_pg[2];
+extern u32 eagle_txd_space[3];
+extern u32 eagle_tx_buf_space_pg[3];
 extern u32 eagle_rx_txdone_desc_base;
-extern u32 eagle_msdu_pg_desc_base;
+extern u32 eagle_msdu_pg_desc_base[3];
 extern u32 eagle_pkt_buf_addr;
 
 extern u32 eagle_dram_ba_node_addr;
@@ -672,17 +672,16 @@ extern u8 eagle_test_noba;
 extern u32 eagle_txdone_id_base;
 extern u32 eagle_chip_info[6];
 extern u32 eagle_phy_tx_gpio;
-extern u32 eagle_stage_buf0;
-extern u32 eagle_stage_buf1;
-extern u32 eagle_stage_base[2];
-extern u16 eagle_stage_widx[2];
-extern u16 eagle_stage_ridx[2];
-extern u32 eagle_rx_ring_desc_base[2];
+extern u32 eagle_stage_buf[3];
+extern u32 eagle_stage_base[3];
+extern u16 eagle_stage_widx[3];
+extern u16 eagle_stage_ridx[3];
+extern u32 eagle_rx_ring_desc_base[3];
 extern u32 eagle_ind_cmd_desc_base;
-extern u16 eagle_rx_ring_size[2];
-extern u16 eagle_rx_ring_cpu_idx[2];
-extern volatile u8 eagle_rx_ring_init_done[2];
-extern u16 eagle_rx_ring_bufid[2][1536];
+extern u16 eagle_rx_ring_size[3];
+extern u16 eagle_rx_ring_cpu_idx[3];
+extern volatile u8 eagle_rx_ring_init_done[3];
+extern u16 eagle_rx_ring_bufid[3][1536];
 extern volatile u32 eagle_rx_en;
 extern volatile u32 eagle_tx_en;
 extern volatile u32 eagle_init_done;
@@ -697,13 +696,13 @@ extern u32 eagle_rro_addr_elem[128];
 extern u32 eagle_session_tbl;
 extern u32 eagle_emi_cidx;
 extern u8 eagle_emi_cidx_valid;
-extern u32 eagle_txq_base[2];
-extern u16 eagle_txq_widx[2];
-extern u16 eagle_txq_ridx[2];
-extern u32 eagle_mseg_base[2];
-extern u16 eagle_mseg_widx[2];
-extern u16 eagle_mseg_ridx[2];
-extern u32 eagle_txq_mutex[2];
+extern u32 eagle_txq_base[3];
+extern u16 eagle_txq_widx[3];
+extern u16 eagle_txq_ridx[3];
+extern u32 eagle_mseg_base[3];
+extern u16 eagle_mseg_widx[3];
+extern u16 eagle_mseg_ridx[3];
+extern u32 eagle_txq_mutex[3];
 extern u16 eagle_mseg_retry;
 extern u32 eagle_rxdmad_ridx;
 extern u8 eagle_rxdmad_gen;
@@ -713,13 +712,13 @@ extern u8 eagle_rxdmad_segs;
 extern u32 eagle_rxdmad_seglen;
 extern u32 eagle_seg_bufid[7];
 extern u16 eagle_seg_len[7];
-extern u32 eagle_rx_ring_ridx[2];
-extern s8 eagle_rx_ring_kick[2];
-extern u32 eagle_tx_ring_desc[2];
-extern u16 eagle_tx_ring_cpu_idx[2];
+extern u32 eagle_rx_ring_ridx[3];
+extern s8 eagle_rx_ring_kick[3];
+extern u32 eagle_tx_ring_desc[3];
+extern u16 eagle_tx_ring_cpu_idx[3];
 extern u32 eagle_txdone_ridx;
-extern u8 eagle_tx_first_push[2];
-extern u8 eagle_in_first[2];
+extern u8 eagle_tx_first_push[3];
+extern u8 eagle_in_first[3];
 extern u8 eagle_txdone_kick;
 extern volatile u32 eagle_rro_cfg[26];
 extern volatile u32 eagle_rro_active;
diff --git a/npu_sram.c b/npu_sram.c
index a41b044..c10eafb 100644
--- a/npu_sram.c
+++ b/npu_sram.c
@@ -113,6 +113,30 @@ struct sram_size_ent {
 	u32 size;
 };
 
+/* Only the AN7581 + MT7996 board needs three host-sized MSDU page rings
+ * and three TDMA rx rings.  MT7992 keeps the old 8-id / 0x100-byte
+ * layout so its SRAM ledger does not move.
+ *
+ * eagle v4 (the same AN7581 + MT7996 build) goes one step further and
+ * moves the whole ring descriptor arena to DDR: SRAM type1 is gone, the
+ * MSDU page descriptors are not a SRAM block any more, and the TDMA rx
+ * ids share the type26 pool with the MSDU page ids.  That leaves only
+ * one 0x4000-byte type26 block for both id spaces and keeps the SRAM
+ * ledger far below SRAM_END. */
+#if defined(AN7581) && defined(MT7996)
+#define EAGLE_MSDU_POOL_SIZE	0x4000
+#define EAGLE_MSDU_PAGE_SIZE	0x7000	/* not allocated in SRAM on v4 */
+#define EAGLE_TDMA_ID_SIZE	0x1800	/* not allocated in SRAM on v4 */
+#elif defined(MT7996)
+#define EAGLE_MSDU_POOL_SIZE	0x1800
+#define EAGLE_MSDU_PAGE_SIZE	0x7000
+#define EAGLE_TDMA_ID_SIZE	0x1800
+#else
+#define EAGLE_MSDU_POOL_SIZE	0x00030
+#define EAGLE_MSDU_PAGE_SIZE	0x00100
+#define EAGLE_TDMA_ID_SIZE	0x01000
+#endif
+
 #ifdef WIFI_KITE
 /* the kite tables, one per SoC */
 #if defined(AN7552)
@@ -153,8 +177,8 @@ static const struct sram_size_ent sram_size_hi[] = {
 static const struct sram_size_ent sram_size_lo[] = {
 	{   1, 0x12080 }, {   2, 0x01800 }, {   3, 0x01800 }, {   9, 0x002A8 },
 	{  10, 0x002A8 }, {  11, 0x00078 }, {  14, 0x00600 }, {  15, 0x00600 },
-	{  22, 0x01008 }, {  25, 0x00090 }, {  26, 0x00010 }, {  30, 0x00100 },
-	{  31, 0x02BC0 },
+	{  22, 0x01008 }, {  25, 0x00090 }, {  26, EAGLE_MSDU_POOL_SIZE }, {  30, 0x00100 },
+	{  31, 0x02BC0 }, {  42, 0x01800 }, {  43, 0x00600 }, {  44, EAGLE_MSDU_PAGE_SIZE },
 };
 
 static const struct sram_size_ent sram_size_hi[] = {
@@ -165,28 +189,61 @@ static const struct sram_size_ent sram_size_hi[] = {
 /* AN7581 eagle, as the stock image: the rx sync bitmap (31), 64 KB TDMA
  * tx and rx rings (132, 133), no BME or DBA ring */
 static const struct sram_size_ent sram_size_lo[] = {
+#if defined(MT7996)
+	/* v4: type1 (ring descriptors) lives in DDR 0x3E8A2000, and the
+	 * type29/type44 blocks are folded into the 0x4000 type26 pool. */
+	{   2, 0x01818 }, {   3, 0x01818 }, {   9, 0x003E8 },
+	{  10, 0x003E8 }, {  11, 0x00078 }, {  14, 0x00600 }, {  15, 0x00600 },
+	{  22, 0x01008 }, {  25, 0x00040 }, {  26, EAGLE_MSDU_POOL_SIZE }, {  30, 0x00100 },
+	{  31, 0x00601 }, {  18, 0x06800 }, {  16, 0x02020 }, {  17, 0x02020 },
+	{  28, 0x06800 }, {  23, 0x00800 },
+	{  42, 0x01800 }, {  43, 0x00600 },
+#else
 	{   1, 0x220C0 }, {   2, 0x01818 }, {   3, 0x01818 }, {   9, 0x003E8 },
 	{  10, 0x003E8 }, {  11, 0x00078 }, {  14, 0x00600 }, {  15, 0x00600 },
-	{  22, 0x01008 }, {  25, 0x00040 }, {  26, 0x00010 }, {  30, 0x00100 },
+	{  22, 0x01008 }, {  25, 0x00040 }, {  26, EAGLE_MSDU_POOL_SIZE }, {  30, 0x00100 },
 	{  31, 0x00601 }, {  18, 0x06800 }, {  16, 0x02020 }, {  17, 0x02020 },
-	{  28, 0x06800 }, {  29, 0x01000 }, {  23, 0x00800 },
+	{  28, 0x06800 }, {  29, EAGLE_TDMA_ID_SIZE }, {  23, 0x00800 },
+	{  42, 0x01800 }, {  43, 0x00600 }, {  44, EAGLE_MSDU_PAGE_SIZE },
+#endif
 };
 
 static const struct sram_size_ent sram_size_hi[] = {
-	{ 138, 0x06000 }, { 129, 0x13FFF }, { 132, 0x11000 }, { 133, 0x11000 },
+	{ 138, 0x06000 },
+#if defined(MT7996)
+	{ 129, 0x0E5FF },
+#else
+	{ 129, 0x13FFF },
+#endif
+	{ 132, 0x11000 },
+#if defined(MT7996)
+	/* stock v08 type table: 129=0xE5FF, 133=0x11000.  The 0xCA00
+	 * saved here is what lets the three host-sized MSDU rings fit. */
+	{ 133, 0x11000 },
+#else
+	{ 133, 0x11000 },
+#endif
+
 	{ 130, 0x00004 }, { 137, 0x00004 },
 };
 #else
 static const struct sram_size_ent sram_size_lo[] = {
 	{   1, 0x220C0 }, {   2, 0x01818 }, {   3, 0x01818 }, {   9, 0x003E8 },
 	{  10, 0x003E8 }, {  11, 0x00078 }, {  14, 0x00600 }, {  15, 0x00600 },
-	{  22, 0x01008 }, {  25, 0x00040 }, {  26, 0x00010 }, {  30, 0x00100 },
+	{  22, 0x01008 }, {  25, 0x00040 }, {  26, EAGLE_MSDU_POOL_SIZE }, {  30, 0x00100 },
 	{  18, 0x06800 }, {  16, 0x02020 }, {  17, 0x02020 }, {  28, 0x06800 },
-	{  29, 0x01000 }, {  23, 0x00800 },
+	{  29, EAGLE_TDMA_ID_SIZE }, {  23, 0x00800 }, {  42, 0x01800 }, {  43, 0x00600 },
+	{  44, EAGLE_MSDU_PAGE_SIZE },
 };
 
 static const struct sram_size_ent sram_size_hi[] = {
-	{ 138, 0x06000 }, { 129, 0x13FFF }, { 132, 0x04000 }, { 133, 0x10000 },
+	{ 138, 0x06000 }, { 129, 0x13FFF }, { 132, 0x04000 },
+#if defined(MT7996)
+	{ 133, 0x18000 },
+#else
+	{ 133, 0x10000 },
+#endif
+
 	{ 134, 0x01000 }, { 136, 0x08010 }, { 130, 0x00004 }, { 137, 0x00004 },
 };
 #endif
diff --git a/npu_wifi.c b/npu_wifi.c
index 96047d9..9d4d89e 100644
--- a/npu_wifi.c
+++ b/npu_wifi.c
@@ -139,12 +139,22 @@ void core0_wifi_init_wrapper(void)
 #ifdef HAS_NPU_WIFI_TX
 	eagle_tx_ring_desc[0] = eagle_ring_desc_base(3);
 	eagle_tx_ring_desc[1] = eagle_ring_desc_base(4);
+#if defined(MT7996)
+	/* MT7996 has bands 0 and 2, not band 1: ring4 is idle and
+	 * becomes the band2 tx ring */
+	eagle_tx_ring_desc[2] = eagle_ring_desc_base(4);
+#endif
 	if (eagle_tx_ring_desc[0] == 0)
 		npu_printf("%s:[ERROR]!!!! can't get tx ring0 desc base:%x\n",
 			   "npu_offload_wifi_tx_ring_init", 0);
 	if (eagle_tx_ring_desc[1] == 0)
 		npu_printf("%s:[ERROR]!!!! can't get tx ring1 desc base:%x\n",
 			   "npu_offload_wifi_tx_ring_init", 0);
+#if defined(MT7996)
+	if (eagle_tx_ring_desc[2] == 0)
+		npu_printf("%s:[ERROR]!!!! can't get tx ring2 desc base:%x\n",
+			   "npu_offload_wifi_tx_ring_init", 0);
+#endif
 #endif
 #endif
 
diff --git a/npu_wifi.h b/npu_wifi.h
index 26e3354..5bab29f 100644
--- a/npu_wifi.h
+++ b/npu_wifi.h
@@ -51,7 +51,11 @@
 #endif
 
 /* TDMA rx ring geometry */
+#if defined(MT7996)
+#define TDMA_RX_RINGS         3
+#else
 #define TDMA_RX_RINGS         2
+#endif
 #define TDMA_RX_RING_DESCS    1024
 #define TDMA_RX_DESC_SIZE     32
 #define TDMA_RX_RING_STRIDE   0x8000
@@ -116,9 +120,9 @@ int __attribute__((noinline)) tdma_tx_submit(u32 token, u32 pkt_len,
 
 extern volatile u8 hostadpt_tx_ring_ready;
 #ifdef HAS_NPU_WIFI_TX
-extern u32 hostadpt_in_base[2];
-extern u32 hostadpt_in_size[2];
-extern u32 hostadpt_in_ridx[2];
+extern u32 hostadpt_in_base[3];
+extern u32 hostadpt_in_size[3];
+extern u32 hostadpt_in_ridx[3];
 #endif
 
 #ifdef HAS_WIFI
@@ -287,6 +291,26 @@ void __attribute__((noinline)) npu_set_rxd_init(u32 ring_size, u32 band);
 #define EAGLE_RING_TXDONE1      11
 #define EAGLE_RING_ALL          15
 
+#if defined(AN7581) && defined(MT7996)
+/*
+ * eagle v4 / XR1710G: the stock v08 ring descriptor arena is in the DDR
+ * npu_pkt region, not in the 64 KB SRAM at 0x3E800000.  Host npu_pkt
+ * starts at 0x8A000000; the NPU's DDR window maps it at 0x3E800000, so
+ * the stock type1 arena at offset 0xA2000 is 0x3E8A2000 on the NPU side
+ * (host 0x8A0A2000) and covers 0x4A040 bytes, exactly as stock v08's
+ * type1 size table says.  qid10/11/12 then point into it at the stock
+ * ring7/8/9 offsets 0x18020/0x19020/0x1B020.
+ */
+#define EAGLE_DESC_DDR_BASE	0x3E8A2000
+#define EAGLE_DESC_DDR_SIZE	0x4A040
+#define EAGLE_DESC_HOST_BASE	0x8A0A2000
+#define EAGLE_DESC_HOST_END	(EAGLE_DESC_HOST_BASE + EAGLE_DESC_DDR_SIZE)
+#define EAGLE_NPU_PKT_HOST_END	0x8CC00000	/* 0x8A000000 + 0x2C00000 */
+#define EAGLE_MSDU_PG0_OFF	0x18020		/* ring7, 256 x 16 B */
+#define EAGLE_MSDU_PG1_OFF	0x19020		/* ring8, 512 x 16 B */
+#define EAGLE_MSDU_PG2_OFF	0x1B020		/* ring9, 1024 x 16 B */
+#endif
+
 #define EAGLE_RX_RING_MAX_IDX   1535
 #define EAGLE_TX_BUF_SLOT       256
 #define EAGLE_TX_BUF_SPACE_SIZE 0x80000
@@ -315,10 +339,10 @@ void __attribute__((noinline)) npu_set_rxd_init(u32 ring_size, u32 band);
 /* Where frames are supposed to appear. One line every two seconds from
  * core 3 says which stage they stop at. */
 struct eagle_dbg {
-	u32 in[2];	/* host tx entries taken off the in ring */
-	u32 stage[2];	/* frames staged for the WiFi tx ring */
-	u32 nostage[2];	/* staging refused: ring full or no token */
-	u32 push[2];	/* descriptors handed to the WiFi tx ring */
+	u32 in[3];	/* host tx entries taken off the in ring */
+	u32 stage[3];	/* frames staged for the WiFi tx ring */
+	u32 nostage[3];	/* staging refused: ring full or no token */
+	u32 push[3];	/* descriptors handed to the WiFi tx ring */
 	u32 rxd;	/* rxdmad descriptors parsed */
 	u32 rxq;	/* packets queued for the host */
 	u32 rxfast;	/* packets sent straight to the wired side */
@@ -328,8 +352,8 @@ struct eagle_dbg {
 	u32 rxbig;	/* frames carrying a payload, sampled */
 	u32 rxoutfail;	/* host adaptor ring full */
 	u32 txdone;	/* tx done reports consumed */
-	u32 refill[2];	/* rx ring descriptors refilled */
-	u32 lan[2];	/* TDMA rx frames pushed to the WiFi tx ring */
+	u32 refill[3];	/* rx ring descriptors refilled */
+	u32 lan[3];	/* TDMA rx frames pushed to the WiFi tx ring */
 	u32 lanfail;	/* TDMA rx frames dropped: no token or ring stuck */
 	u32 lanwait;	/* waits for a free WiFi tx slot */
 	u32 lanxband;	/* TDMA rx frames for the other ring's band */
diff --git a/npu_wifi_bufid.c b/npu_wifi_bufid.c
index 79ee5c9..942c91c 100644
--- a/npu_wifi_bufid.c
+++ b/npu_wifi_bufid.c
@@ -126,7 +126,11 @@ void wifi_cnt_add(u32 band, u32 off)
 #define BUFID_POOL_LAST       (BUFID_POOL_ENTRIES - 1)
 #define TX_FREE_RING_ENTRIES  13312
 #define TX_FREE_RING_LAST     (TX_FREE_RING_ENTRIES - 1)
+#if defined(MT7996)
+#define TDMA_RX_ID_ENTRIES    3072
+#else
 #define TDMA_RX_ID_ENTRIES    2048
+#endif
 #define TX_BUF_STATE_IN_RX    3
 
 static u32 bufid_pool_base;
@@ -401,7 +405,14 @@ void bufid_pool_init(void)
 	tx_buf_state_base = sram_buf_alloc(28);
 	npu_memset((void *)tx_buf_state_base, 0, TX_FREE_RING_ENTRIES * 2);
 
+#ifdef EAGLE_DESC_DDR_BASE
+	/* v4: type29 is gone from SRAM.  The TDMA rx ids share the 0x4000
+	 * type26 pool with the MSDU page ids: three 1024-id pools take
+	 * 0x0000..0x1800, the 3072 TDMA ids take 0x1800..0x3000. */
+	tdma_rx_ids_base = sram_buf_alloc(26) + 0x1800;
+#else
 	tdma_rx_ids_base = sram_buf_alloc(29);
+#endif
 
 	bufid_ridx = 0;
 	/* 0 is a full ring: every slot but one holds an id */
diff --git a/npu_wifi_eagle.c b/npu_wifi_eagle.c
index cf3717e..9b2b0a9 100644
--- a/npu_wifi_eagle.c
+++ b/npu_wifi_eagle.c
@@ -42,8 +42,17 @@ static void npu_set_pcie_base_eagle(u32 addr, u32 ring)
 	case EAGLE_RING_RX1:
 		eagle_rx_ring_pcie_base[1] = addr;
 		break;
+	case 2:				/* MT7996 RRO band2 */
+		eagle_rx_ring_pcie_base[2] = addr;
+		break;
 	case EAGLE_RING_MSDU_PG0:
-		eagle_msdu_pg_pcie_base = addr;
+		eagle_msdu_pg_pcie_base[0] = addr;
+		break;
+	case 6:				/* MT7996 MSDU page band1 */
+		eagle_msdu_pg_pcie_base[1] = addr;
+		break;
+	case 7:				/* MT7996 MSDU page band2 */
+		eagle_msdu_pg_pcie_base[2] = addr;
 		break;
 	case EAGLE_RING_IND_CMD0:
 	case EAGLE_RING_IND_CMD1:
@@ -55,12 +64,25 @@ static void npu_set_pcie_base_eagle(u32 addr, u32 ring)
 #endif
 		break;
 	case EAGLE_RING_ALL:
-		/* every base is in, publish the cpu index of each ring */
-		REG32(eagle_rx_ring_pcie_base[0] + 8) = EAGLE_RX_RING_MAX_IDX;
-		REG32(eagle_rx_ring_pcie_base[1] + 8) = EAGLE_RX_RING_MAX_IDX;
-		REG32(eagle_ind_cmd_pcie_base + 8) = EAGLE_RX_RING_MAX_IDX;
+		/* every base is in, publish the cpu index of each ring.
+		 * MT7996 does not use internal band1, so its base stays 0
+		 * and must not be dereferenced. */
+		if (eagle_rx_ring_pcie_base[0] != 0)
+			REG32(eagle_rx_ring_pcie_base[0] + 8) =
+				EAGLE_RX_RING_MAX_IDX;
+		if (eagle_rx_ring_pcie_base[1] != 0)
+			REG32(eagle_rx_ring_pcie_base[1] + 8) =
+				EAGLE_RX_RING_MAX_IDX;
+		if (eagle_rx_ring_pcie_base[2] != 0)
+			REG32(eagle_rx_ring_pcie_base[2] + 8) =
+				EAGLE_RX_RING_MAX_IDX;
+		if (eagle_ind_cmd_pcie_base != 0)
+			REG32(eagle_ind_cmd_pcie_base + 8) =
+				EAGLE_RX_RING_MAX_IDX;
 #ifdef HAS_NPU_WIFI_TX
-		REG32(eagle_txdone_pcie_base + 8) = eagle_txdone_ring_cnt - 1;
+		if (eagle_txdone_pcie_base != 0)
+			REG32(eagle_txdone_pcie_base + 8) =
+				eagle_txdone_ring_cnt - 1;
 #endif
 		npu_printf("[NPU] set RRO ring cpu idx \n");
 		break;
@@ -86,6 +108,10 @@ static void npu_set_pcie_base_for_tx_ring_eagle(u32 addr, u32 ring)
 		eagle_tx_ring_cpu_idx[0] = 0;
 		eagle_tx_ring_cpu_idx[1] = 0;
 		break;
+	case 2:				/* MT7996 tx ring band2 */
+		eagle_tx_ring_pcie_base[2] = addr;
+		eagle_tx_ring_cpu_idx[2] = 0;
+		break;
 	case 3:
 		eagle_tx_ring_pcie_base_r3 = addr;
 		break;
@@ -104,22 +130,51 @@ static void npu_set_rx_ring_for_tx_done_phy_base_eagle(u32 addr, u32 ring)
 		eagle_rx_txdone_desc_base = (addr & 0x3FFFFFFF) | NPU_ADDR_MASK;
 		return;
 	}
-	if (ring != EAGLE_RING_MSDU_PG0) {
+#ifdef EAGLE_DESC_DDR_BASE
+	/* v4 keeps the three MSDU page ring descriptors in the DDR
+	 * arena; a host SET_WAIT of ring 5/6/7 must not replace them. */
+	if (ring >= 5 && ring <= 7) {
+		npu_printf("%s() keep DDR msdu desc base for ring %d\n",
+			   "npu_set_rx_ring_for_tx_done_phy_base_eagle", ring);
+		return;
+	}
+#endif
+	if (ring < 5 || ring > 7) {
 		npu_printf("%s() wrong input value!!!\n",
 			   "npu_set_rx_ring_for_tx_done_phy_base_eagle");
 		return;
 	}
-	npu_printf("%s()[NPU] set 2G msdu desc addr, MSDU_PG_RING_DESC_BASE:%x\n",
-		   "npu_set_rx_ring_for_tx_done_phy_base_eagle",
-		   eagle_msdu_pg_desc_base);
-	eagle_msdu_pg_desc_base = (addr & 0x3FFFFFFF) | NPU_ADDR_MASK;
+	ring -= 5;
+	npu_printf("%s()[NPU] set %dG msdu desc addr, MSDU_PG_RING_DESC_BASE:%x\n",
+		   "npu_set_rx_ring_for_tx_done_phy_base_eagle", ring,
+		   eagle_msdu_pg_desc_base[ring]);
+	eagle_msdu_pg_desc_base[ring] = (addr & 0x3FFFFFFF) | NPU_ADDR_MASK;
 }
 
 /* descriptor base of one eagle ring inside the shared PCIe descriptor
  * block, by the ring's own id. */
 u32 eagle_ring_desc_base(u32 ring_id)
 {
-#if defined(AN7552)
+#if defined(EAGLE_DESC_DDR_BASE)
+	/* eagle v4: the stock v08 ring table at 0x8401dca0, relative to
+	 * the fixed DDR arena base 0x3E8A2000, with ring4 moved from
+	 * 0x26040 to 0x28040 so ring2's 0x6000-byte RRO ring does not
+	 * overlap ring4 (0x22020 + 0x6000 + 0x20 guard = 0x28040). */
+	static const u32 off[9] = {
+		0x00000,	/* ring1: RRO band0 */
+		0x22020,	/* ring2: RRO band2 (host never uses band1) */
+		0x06020,	/* ring3: tx ring band0 */
+		0x28040,	/* ring4: tx ring band2 (after ring2 0x22020+0x6000+0x20) */
+		0x00000,	/* ring5: not in the stock table, never used */
+		0x1F020,	/* ring6: ind cmd */
+		0x18020,	/* ring7: MSDU page band0, 256 x 16 */
+		0x19020,	/* ring8: MSDU page band1, 512 x 16 */
+		0x1B020,	/* ring9: MSDU page band2, 1024 x 16 */
+	};
+
+	if (ring_id == 0 || ring_id > 9 || ring_id == 5)
+		return 0;
+#elif defined(AN7552)
 	/* rx0, rx1, pg, ind; no tx rings 3/4 */
 	static const u32 off[6] = {
 		0x00000, 0x0C080, 0, 0, 0x06000, 0x06080
@@ -166,6 +221,7 @@ void eagle_rx_init(void)
 	counter_init(1);
 	eagle_txq_mutex[0] = 10;
 	eagle_txq_mutex[1] = 0;
+	eagle_txq_mutex[2] = 0;
 #if defined(AN7552)
 	if (eagle_chip_force_cpu())
 		wifi_force_to_cpu = 1;
@@ -173,6 +229,7 @@ void eagle_rx_init(void)
 	eagle_rxdmad_on_core2 = 0;
 	/* type 30 is reserved and never read; keeps the SRAM layout */
 	sram_buf_alloc(30);
+	eagle_rx_ring_init_done[2] = 0;
 	eagle_rx_ring_init_done[1] = 0;
 	eagle_rx_ring_init_done[0] = 0;
 	/* indirect command state, 254 = idle */
@@ -302,14 +359,21 @@ static void eagle_tx_stage_init(u32 band)
 	while (npu_tx_pkt_buf_addr == 0)
 		delay_ms(100);
 
-	if (band != 0) {
-		buf = eagle_stage_buf1;
+	if (band == 2) {
+		/* MT7996: band1's staging block is free, reuse it for band2 */
+		buf = eagle_stage_buf[2];
+		eagle_stage_widx[2] = 0;
+		eagle_stage_ridx[2] = 0;
+		eagle_stage_base[2] = sram_buf_alloc(17);
+		desc = eagle_stage_base[2];
+	} else if (band == 1) {
+		buf = eagle_stage_buf[1];
 		eagle_stage_widx[1] = 0;
 		eagle_stage_ridx[1] = 0;
 		eagle_stage_base[1] = sram_buf_alloc(17);
 		desc = eagle_stage_base[1];
 	} else {
-		buf = eagle_stage_buf0;
+		buf = eagle_stage_buf[0];
 		eagle_stage_widx[0] = 0;
 		eagle_stage_ridx[0] = 0;
 		eagle_stage_base[0] = sram_buf_alloc(16);
@@ -338,6 +402,9 @@ static void npu_set_tx_ring_buf_space_phy_base_eagle(u32 addr, u32 ring)
 	case 1:
 		eagle_txd_space[1] = base;
 		break;
+	case 2:				/* MT7996 band2 txd space */
+		eagle_txd_space[2] = base;
+		break;
 	case EAGLE_RING_MSDU_PG0:
 		eagle_tx_buf_space_pg[0] = base;
 		eagle_tx_buf_space_clear(base);
@@ -346,14 +413,22 @@ static void npu_set_tx_ring_buf_space_phy_base_eagle(u32 addr, u32 ring)
 		eagle_tx_buf_space_pg[1] = base;
 		eagle_tx_buf_space_clear(base);
 		break;
+	case 7:				/* MT7996 band2 tx buffer space */
+		eagle_tx_buf_space_pg[2] = base;
+		eagle_tx_buf_space_clear(base);
+		break;
 	case EAGLE_RING_TXDONE0:
-		eagle_stage_buf0 = base;
+		eagle_stage_buf[0] = base;
 		eagle_tx_stage_init(0);
 		break;
 	case EAGLE_RING_TXDONE1:
-		eagle_stage_buf1 = base;
+		eagle_stage_buf[1] = base;
 		eagle_tx_stage_init(1);
 		break;
+	case 12:			/* MT7996 band2 staging buffer */
+		eagle_stage_buf[2] = base;
+		eagle_tx_stage_init(2);
+		break;
 	default:
 		npu_printf("[error]%s wrong band index:%d !!!!!\n",
 			   "npu_set_tx_ring_buf_space_phy_base_eagle", ring);
@@ -408,14 +483,23 @@ static int eagle_rx_ring_init(u32 ring_size, u32 band)
 		ring_size = EAGLE_RX_RING_MAX_IDX + 1;
 	}
 
+	if (band >= 3) {
+		npu_printf("ERROR! rx ring band = %d\n", band);
+		return 1;
+	}
 	eagle_rx_ring_size[band] = (u16)ring_size;
 	desc_base = eagle_rx_ring_desc_base[band];
+	if (desc_base == 0) {
+		npu_printf("[%s]rx ring has no desc base\n",
+			   band == 0 ? "BAND0" : band == 1 ? "BAND1" : "BAND2");
+		return 1;
+	}
 
 	for (i = 0; i < ring_size; i++) {
 		buf_id = (u32)buf_id_alloc_ring();
 		if (buf_id == (u32)-1) {
 			npu_printf("[%s]rx ring init: alloc buffid fail!\n",
-				   band ? "BAND1" : "BAND0");
+				   band == 0 ? "BAND0" : band == 1 ? "BAND1" : "BAND2");
 			return 1;
 		}
 		dbg.refill[band]++;
@@ -493,66 +577,180 @@ static void eagle_txdone_ring_fill(u32 ring_size)
 	}
 }
 
-/* MSDU page ids: an 8-slot free ring */
-static u16 *msdu_pg_pool;
-static u16 msdu_pg_ridx, msdu_pg_widx;
-static u16 msdu_pg_ids[8];
-static u32 msdu_pg_ring_ridx;
-static u32 msdu_pg_ring_ready;
+/* MSDU page ids: one disjoint per-band pool, ring-sized by the host */
+#define MSDU_PG_MAX_IDS 1024
+/* Disjoint per-band MSDU page ID ranges inside eagle_dram_ba_node_addr
+ * (npu_ba = 0x200000 B = 16384 x 128 B pages; MT7996 uses 256+512+1024).
+ * msdu_pg_desc_fill() maps each id to ba_node + (id << 7), so bands
+ * must not share IDs. */
+#if defined(MT7996)
+static const u16 eagle_msdu_pg_id_base[3] __attribute__((used)) = { 0, 256, 768 };
+static const u16 eagle_msdu_pg_id_limit[3] __attribute__((used)) = { 256, 512, 1024 };
+#else
+static const u16 eagle_msdu_pg_id_base[3] __attribute__((used)) = { 0, 8, 16 };
+static const u16 eagle_msdu_pg_id_limit[3] __attribute__((used)) = { 8, 8, 8 };
+#endif
+static u16 *msdu_pg_pool[3];
+static u16 msdu_pg_ridx[3], msdu_pg_widx[3];
+static u16 msdu_pg_alloc_count[3];
+static u16 msdu_pg_ids[3][MSDU_PG_MAX_IDS];
+static u32 msdu_pg_ring_size[3];
+static u32 msdu_pg_ring_ridx[3];
+static u32 msdu_pg_ring_ready[3];
 
 void eagle_msdu_pg_pool_init(void)
 {
-	u32 i;
+	u32 i, band;
+	u32 pool;
+
+#if defined(EAGLE_DESC_DDR_BASE)
+	pool = sram_buf_alloc(26);
+	/* type26 is one 0x4000 pool: three MSDU page ID pools at
+	 * +0x0000..+0x1800, TDMA rx ids share +0x1800..+0x3000.
+	 * Populate each band with its disjoint [base, base + limit) IDs. */
+	for (band = 0; band < 3; band++) {
+		u16 base = eagle_msdu_pg_id_base[band];
+		u16 count = eagle_msdu_pg_id_limit[band];
+
+		msdu_pg_pool[band] = (u16 *)(pool + 2048 * band);
+		for (i = 0; i < count; i++)
+			msdu_pg_pool[band][i] = (u16)(base + i);
+		msdu_pg_ridx[band] = 0;
+		msdu_pg_widx[band] = 0;
+		msdu_pg_alloc_count[band] = count;
+		msdu_pg_ring_size[band] = 0;
+		msdu_pg_ring_ready[band] = 0;
+	}
 
-	msdu_pg_pool = (u16 *)sram_buf_alloc(26);
-	for (i = 0; i < 8; i++)
-		msdu_pg_pool[i] = (u16)i;
-	msdu_pg_ridx = 0;
-	msdu_pg_widx = 0;
+	/* descriptors: stock v08 ring7/8/9 offsets in the DDR type1
+	 * arena, 256/512/1024 x 16 bytes. */
+	eagle_msdu_pg_desc_base[0] = eagle_ring_desc_base(7);
+	eagle_msdu_pg_desc_base[1] = eagle_ring_desc_base(8);
+	eagle_msdu_pg_desc_base[2] = eagle_ring_desc_base(9);
+#elif defined(MT7996)
+	pool = sram_buf_alloc(26);
+	/* type 26 is 3 x 2048 bytes: one disjoint ID pool per band */
+	for (band = 0; band < 3; band++) {
+		u16 base = eagle_msdu_pg_id_base[band];
+		u16 count = eagle_msdu_pg_id_limit[band];
+
+		msdu_pg_pool[band] = (u16 *)(pool + 2048 * band);
+		for (i = 0; i < count; i++)
+			msdu_pg_pool[band][i] = (u16)(base + i);
+		msdu_pg_ridx[band] = 0;
+		msdu_pg_widx[band] = 0;
+		msdu_pg_alloc_count[band] = count;
+		msdu_pg_ring_size[band] = 0;
+		msdu_pg_ring_ready[band] = 0;
+	}
+
+	/* 0x1000 band0, 0x2000 band1, 0x4000 band2: 0x7000 total.
+	 * ring5 at 0xE020 is only 0x80 bytes, so band0 needs this block. */
+	pool = sram_buf_alloc(44);
+	eagle_msdu_pg_desc_base[0] = pool + 0x6000;
+	eagle_msdu_pg_desc_base[1] = pool + 0x0000;
+	eagle_msdu_pg_desc_base[2] = pool + 0x2000;
+#else
+	/* MT7992 keeps the original 8-id/0x100-byte layout with disjoint
+	 * per-band ID ranges. */
+	pool = sram_buf_alloc(26);
+	for (band = 0; band < 3; band++) {
+		u16 base = eagle_msdu_pg_id_base[band];
+		u16 count = eagle_msdu_pg_id_limit[band];
+
+		msdu_pg_pool[band] = (u16 *)(pool + 16 * band);
+		for (i = 0; i < count; i++)
+			msdu_pg_pool[band][i] = (u16)(base + i);
+		msdu_pg_ridx[band] = 0;
+		msdu_pg_widx[band] = 0;
+		msdu_pg_alloc_count[band] = count;
+		msdu_pg_ring_size[band] = 0;
+		msdu_pg_ring_ready[band] = 0;
+	}
+	pool = sram_buf_alloc(44);
+	eagle_msdu_pg_desc_base[0] = 0;
+	eagle_msdu_pg_desc_base[1] = pool;
+	eagle_msdu_pg_desc_base[2] = pool + 0x80;
+#endif
 }
 
-static s32 msdu_pg_id_alloc(void)
+static s32 msdu_pg_id_alloc(u32 band, u32 ring_size)
 {
-	u16 next = (msdu_pg_ridx + 1 == 8) ? 0 : msdu_pg_ridx + 1;
+	u16 idx = msdu_pg_ridx[band];
+	u16 next;
 	s32 id;
 
-	if (msdu_pg_widx == next)
+	if (msdu_pg_alloc_count[band] == 0)
 		return -1;
-	id = (s16)msdu_pg_pool[msdu_pg_ridx];
-	msdu_pg_ridx = next;
+	next = (idx + 1 == ring_size) ? 0 : idx + 1;
+	id = (s16)msdu_pg_pool[band][idx];
+	msdu_pg_ridx[band] = next;
+	msdu_pg_alloc_count[band]--;
 	return id;
 }
 
 /* npu_rro_msdu_pg_ring_init_eagle */
-static int eagle_msdu_pg_ring_init(u32 ring_size, u32 again)
+static void msdu_pg_desc_fill(u32 desc, s32 id)
+{
+	REG32(desc + 4) = 0;
+	REG32(desc) = ((((u32)id << 7) + eagle_dram_ba_node_addr) &
+		       0x3FFFFFFF) | 0x80000000;
+	REG32(desc + 8) = (u32)id << 16;
+	REG32(desc + 12) = 0;
+	REG32(desc + 4) = 0x00800100;
+}
+
+static int eagle_msdu_pg_ring_init(u32 ring_size, u32 band, u32 again)
 {
 	u32 i, desc;
+	u32 limit;
 	s32 id;
 
-	if (ring_size - 1 > 7)
-		npu_printf("ERROR! rx_ring_size = %d\n", ring_size);
+	if (band >= 3) {
+		npu_printf("ERROR! msdu pg band = %d\n", band);
+		return 1;
+	}
+	limit = eagle_msdu_pg_id_limit[band];
+	if (ring_size == 0 || ring_size > limit) {
+		npu_printf("ERROR! msdu pg band%d ring_size = %d, limit %d\n",
+			   band, ring_size, limit);
+		return 1;
+	}
+	if (eagle_msdu_pg_desc_base[band] == 0) {
+		npu_printf("[%s]msdu pg ring has no desc base\n",
+			   band == 0 ? "BAND0" : band == 1 ? "BAND1" : "BAND2");
+		return 1;
+	}
+
+	/* a re-init of the same ring reuses the ids it already owns */
+	if (again && msdu_pg_ring_ready[band] != 0 &&
+	    msdu_pg_ring_size[band] == ring_size) {
+		for (i = 0; i < ring_size; i++) {
+			desc = eagle_msdu_pg_desc_base[band] + 16 * i;
+			msdu_pg_desc_fill(desc, msdu_pg_ids[band][i]);
+		}
+		return 0;
+	}
 
+	/* fresh ring: take exactly ring_size ids from this band's pool */
+	msdu_pg_ridx[band] = 0;
+	msdu_pg_alloc_count[band] = (u16)ring_size;
 	for (i = 0; i < ring_size; i++) {
-		id = msdu_pg_id_alloc();
+		id = msdu_pg_id_alloc(band, ring_size);
 		if (id == -1) {
-			npu_printf("[%s]rx ring init: alloc buffid fail!\n",
-				   "npu_rro_msdu_pg_ring_init_eagle");
+			npu_printf("[%s]msdu pg ring init: alloc id fail band%d i%d\n",
+				   "npu_rro_msdu_pg_ring_init_eagle", band, i);
 			return 1;
 		}
-		msdu_pg_ids[i] = (u16)id;
-		desc = eagle_msdu_pg_desc_base + 16 * i;
-		REG32(desc + 4) = 0;
-		REG32(desc) = ((((u32)id << 7) + eagle_dram_ba_node_addr) &
-			       0x3FFFFFFF) | 0x80000000;
-		REG32(desc + 8) = (u32)id << 16;
-		REG32(desc + 12) = 0;
-		REG32(desc + 4) = 0x00800100;
+		msdu_pg_ids[band][i] = (u16)id;
+		desc = eagle_msdu_pg_desc_base[band] + 16 * i;
+		msdu_pg_desc_fill(desc, id);
 	}
-
+	msdu_pg_ring_size[band] = ring_size;
 	if (!again) {
-		msdu_pg_ring_ridx = 0;
-		msdu_pg_ring_ready = 1;
-		npu_printf("reset msdu pg ring\n");
+		msdu_pg_ring_ridx[band] = 0;
+		msdu_pg_ring_ready[band] = 1;
+		npu_printf("reset msdu pg ring%d size %d\n", band, ring_size);
 	}
 	return 0;
 }
@@ -571,14 +769,20 @@ static void npu_mbox_init_rxd_wrapper(u32 ring_size, u32 ring)
 		eagle_queue_init(1);
 		eagle_rx_ring_init(ring_size, 1);
 		break;
+	case 2:				/* MT7996 RRO band2 */
+		eagle_queue_init(2);
+		eagle_rx_ring_init(ring_size, 2);
+		break;
 	case EAGLE_RING_MSDU_PG0:
+		/* band0 uses the 0x1000 hole in the type44 block; ring5 at
+		 * 0xE020 is only 0x80 bytes and would collide with ind. */
+		eagle_msdu_pg_ring_init(ring_size, 0, 0);
+		break;
 	case EAGLE_RING_MSDU_PG1:
-		if (ring == EAGLE_RING_MSDU_PG1)
-			npu_printf("%s() wrong input val:%d\n",
-				   "npu_rro_msdu_pg_ring_desc_addr", 1);
-		else
-			eagle_msdu_pg_desc_base = eagle_ring_desc_base(5);
-		eagle_msdu_pg_ring_init(ring_size, ring == EAGLE_RING_MSDU_PG1);
+		eagle_msdu_pg_ring_init(ring_size, 1, 0);
+		break;
+	case 7:				/* MT7996 MSDU page band2 */
+		eagle_msdu_pg_ring_init(ring_size, 2, 0);
 		break;
 	case EAGLE_RING_IND_CMD0:
 		eagle_ind_cmd_desc_base = eagle_ring_desc_base(6);
@@ -989,46 +1193,59 @@ int eagle_mail_get_dbg_counter(u32 *msg)
 int eagle_mail_get_rxdesc_base(u32 *msg)
 {
 	u32 ring = msg[0] & 0xF;
-	u32 base, i;
+	u32 base = 0, i;
 
+	msg[2] = 0;
 	switch (ring) {
 	case EAGLE_RING_RX0:
 	case EAGLE_RING_RX1:
-		msg[2] = eagle_rx_ring_desc_base[ring] & 0x1FFFFFFF;
+		base = eagle_rx_ring_desc_base[ring];
+		break;
+	case 2:				/* MT7996 RRO band2 */
+		base = eagle_rx_ring_desc_base[2];
 		break;
 	case 5:
 	case 6:
+	case 7:
 #ifndef HAS_NPU_WIFI_TX
 		/* no WiFi tx rings without NPU tx */
 		npu_printf("[WARN]%s() TCSUPPORT_NPU_WIFI_TX is not set for %d\n",
 			   "npu_mbox_get_wait_rxdesc_base_wrapper", ring);
-		msg[2] = 0;
-		break;
+		return 0;
 #endif
 		base = eagle_tx_ring_desc[ring - 5];
 		if (base == 0) {
-			npu_printf("[NPU][ERROR] wrong tx ring desc pase !!  band_idx=%d \n",
+			npu_printf("[NPU][ERROR] wrong tx ring desc base !! band_idx=%d\n",
 				   ring - 5);
-			msg[2] = 0;
-			break;
+			return 0;
 		}
 		for (i = 0; i < EAGLE_TX_RING_ENTRIES; i++)
 			REG32(base + 16 * i + 4) = 0x80000000;
-		msg[2] = base & 0x1FFFFFFF;
 		break;
 	case EAGLE_RING_IND_CMD0:
 	case EAGLE_RING_IND_CMD1:
-		msg[2] = eagle_ind_cmd_desc_base & 0x1FFFFFFF;
+		base = eagle_ind_cmd_desc_base;
 		break;
-
 	case EAGLE_RING_TXDONE0:
-		msg[2] = eagle_msdu_pg_desc_base & 0x1FFFFFFF;
+		base = eagle_msdu_pg_desc_base[0];
+		break;
+	case 11:			/* MT7996 MSDU page band1 */
+		base = eagle_msdu_pg_desc_base[1];
+		break;
+	case 12:			/* MT7996 MSDU page band2 */
+		base = eagle_msdu_pg_desc_base[2];
 		break;
 	default:
 		npu_printf("[ERROR]%s() wrong input value %d\n",
 			   "npu_mbox_get_wait_rxdesc_base_wrapper", ring);
-		msg[2] = 0;
-		break;
+		return 0;
+	}
+
+	msg[2] = base & 0x1FFFFFFF;
+	if (msg[2] == 0) {
+		npu_printf("[ERROR]%s() ring %d has no descriptor base\n",
+			   "npu_mbox_get_wait_rxdesc_base_wrapper", ring);
+		return 0;
 	}
 #ifdef NPU_MAIL_TRACE
 	npu_printf("[NPU]rxdesc base ring=%d -> %x\n", ring, msg[2]);
diff --git a/npu_wifi_eagle_dp.c b/npu_wifi_eagle_dp.c
index d5995e3..4a10ec5 100644
--- a/npu_wifi_eagle_dp.c
+++ b/npu_wifi_eagle_dp.c
@@ -576,12 +576,6 @@ void eagle_queue_init(u32 band)
 {
 	u32 i, e;
 
-	if (band == 2) {
-		npu_printf("%s() special handling: band is changed to BAND1\n",
-			   "npu_eagle_rx_init");
-		band = 1;
-	}
-
 	eagle_txq_widx[band] = 0;
 	eagle_txq_ridx[band] = 0;
 	eagle_mseg_widx[band] = 0;
@@ -592,9 +586,12 @@ void eagle_queue_init(u32 band)
 		eagle_mseg_base[0] = sram_buf_alloc(14);
 		eagle_rx_ring_desc_base[0] = eagle_ring_desc_base(1);
 	} else {
-		eagle_txq_base[1] = sram_buf_alloc(3);
-		eagle_mseg_base[1] = sram_buf_alloc(15);
-		eagle_rx_ring_desc_base[1] = eagle_ring_desc_base(2);
+		/* MT7996 uses band2 where MT7992 used band1.  Reuse the
+		 * band1 queue and RRO descriptor blocks: the host never
+		 * programs band1 on MT7996, so they are otherwise idle. */
+		eagle_txq_base[band] = sram_buf_alloc(3);
+		eagle_mseg_base[band] = sram_buf_alloc(15);
+		eagle_rx_ring_desc_base[band] = eagle_ring_desc_base(2);
 	}
 
 	for (i = 0; i < EAGLE_TXQ_ENTRIES; i++) {
@@ -724,6 +721,9 @@ static void eagle_txq_drain(u32 band)
 {
 	u32 base = eagle_txq_base[band];
 	u32 idx = eagle_txq_ridx[band];
+
+	if (base == 0)
+		return;
 	u32 left = EAGLE_DRAIN_BATCH, n = 0, full = 0, e, buf_id, w1, w2;
 	u16 ids[EAGLE_DRAIN_BATCH];
 	u16 seg_len;
@@ -817,6 +817,9 @@ static void eagle_txq_drain(u32 band)
 	u32 e = eagle_txq_base[band] + EAGLE_Q_ENTRY * eagle_txq_ridx[band];
 	u32 buf_id, idx;
 	u8 flags;
+
+	if (eagle_txq_base[band] == 0)
+		return;
 	u16 seg_len;
 
 	if ((*(volatile u8 *)(e + 10) & 1) == 0)
@@ -858,7 +861,11 @@ static void eagle_mseg_drain(u32 band)
 {
 	u32 idx = eagle_mseg_ridx[band];
 	u32 base = eagle_mseg_base[band];
-	u32 e = base + EAGLE_Q_ENTRY * idx;
+	u32 e;
+
+	if (base == 0)
+		return;
+	e = base + EAGLE_Q_ENTRY * idx;
 	u32 waited = 0, segs = 0, count, this_idx, buf_id, spin;
 	u8 flags;
 	int ok;
@@ -1247,7 +1254,8 @@ static int eagle_hostadpt_drain(u32 band)
 	struct sta_q_cfg qc;
 #endif
 
-	if (hostadpt_in_size[band] == 0)
+	if (hostadpt_in_size[band] == 0 || hostadpt_in_base[band] == 0 ||
+	    eagle_stage_base[band] == 0)
 		return 0;
 
 #ifdef EAGLE_HOST_QLIMIT
@@ -1774,14 +1782,21 @@ static NPU_INLINE u32 eagle_tx_ring_room(u32 band, u32 max)
 
 /* core 2: staged frames into the WiFi tx ring, paced by the slots the
  * chip has handed back so it is never overrun */
+#if defined(MT7996)
+/* band2 replaces the unused band1 on MT7996 */
+static const u8 eagle_tx_band_order[2] = { 2, 0 };
+#else
+static const u8 eagle_tx_band_order[2] = { 1, 0 };
+#endif
+
 void __attribute__((noreturn)) eagle_tx_fast_path(void)
 {
 	u8 chaining = 0;
 #ifdef HAS_FAST_POLL
-	u16 dma[2] = { 0, 0 };
+	u16 dma[3] = { 0, 0, 0 };
 	u32 cpu;
 #endif
-	u32 band, free;
+	u32 band, free, bi;
 	int empty;
 
 	while (eagle_init_done == 0 || eagle_fastpath_en == 0 ||
@@ -1809,6 +1824,7 @@ void __attribute__((noreturn)) eagle_tx_fast_path(void)
 			/* no room known: count it again on the first pass */
 			dma[0] = (u16)(eagle_tx_ring_cpu_idx[0] + 1);
 			dma[1] = (u16)(eagle_tx_ring_cpu_idx[1] + 1);
+			dma[2] = (u16)(eagle_tx_ring_cpu_idx[2] + 1);
 #endif
 		}
 		eagle_rx_stopped = 0;
@@ -1826,7 +1842,11 @@ void __attribute__((noreturn)) eagle_tx_fast_path(void)
 		 * frames into the rest of the room, keeping 6 slots free.
 		 * The room comes from the last count of slots the chip handed
 		 * back, which only undercounts; it is counted again when low. */
-		for (band = 1; band != (u32)-1; band--) {
+		for (bi = 0; bi < 2; bi++) {
+			band = eagle_tx_band_order[bi];
+			if (eagle_stage_base[band] == 0 ||
+			    eagle_tx_ring_desc[band] == 0)
+				continue;
 			cpu = eagle_tx_ring_cpu_idx[band];
 			free = (dma[band] - cpu - 1) & EAGLE_TX_RING_MASK;
 			if (free <= EAGLE_TX_RING_ROOM + EAGLE_TX_HOST_BUDGET + 128) {
@@ -1842,12 +1862,17 @@ void __attribute__((noreturn)) eagle_tx_fast_path(void)
 				 free -= eagle_tx_ring_push_n(band,
 					free < EAGLE_TX_HOST_BUDGET ? free :
 					EAGLE_TX_HOST_BUDGET));
-			if (free > 1)
-				NPU_PROF(NP_ELAN, dbg.lan[0] + dbg.lan[1],
+			if (free > 1 && band < TDMA_RX_RINGS)
+				NPU_PROF(NP_ELAN, dbg.lan[0] + dbg.lan[1] +
+						 dbg.lan[2],
 					 eagle_tdma_to_wifi(band, free - 1));
 		}
 #else
-		for (band = 1; band != (u32)-1; band--) {
+		for (bi = 0; bi < 2; bi++) {
+			band = eagle_tx_band_order[bi];
+			if (eagle_stage_base[band] == 0 ||
+			    eagle_tx_ring_desc[band] == 0)
+				continue;
 			free = eagle_tx_ring_room(band, EAGLE_TX_RING_MASK);
 			if (free <= EAGLE_TX_RING_ROOM) {
 				eagle_delay(5000);
@@ -1859,8 +1884,12 @@ void __attribute__((noreturn)) eagle_tx_fast_path(void)
 					 eagle_tx_ring_push_n(band, 1));
 				if (free == EAGLE_TX_RING_ROOM)
 					break;
-				NPU_PROF(NP_ELAN, dbg.lan[0] + dbg.lan[1],
-					 eagle_tdma_to_wifi(band, free - 6));
+				if (band < TDMA_RX_RINGS)
+					NPU_PROF(NP_ELAN,
+						 dbg.lan[0] + dbg.lan[1] +
+						 dbg.lan[2],
+						 eagle_tdma_to_wifi(band,
+								    free - 6));
 				if (free <= 129)
 					break;
 			}
@@ -1905,14 +1934,20 @@ void __attribute__((noreturn)) eagle_core3_loop(void)
 
 #ifdef HAS_NPU_WIFI_TX
 		NPU_PROF(NP_EHIN, dbg.in[0] + dbg.in[1],
-			 eagle_hostadpt_drain(0); eagle_hostadpt_drain(1));
+			 eagle_hostadpt_drain(0); eagle_hostadpt_drain(1);
+			 eagle_hostadpt_drain(2));
 #endif
 		if (eagle_rx_ring_init_done[0] != 0 &&
-		    eagle_rx_ring_init_done[1] != 0 &&
-		    hostadpt_tx_ring_ready == 1)
-			NPU_PROF(NP_EHOUT, dbg.rxout,
-				 eagle_txq_drain(0); eagle_txq_drain(1);
-				 eagle_mseg_drain(1));
+		    (eagle_rx_ring_init_done[1] != 0 ||
+		     eagle_rx_ring_init_done[2] != 0) &&
+		    hostadpt_tx_ring_ready == 1) {
+			NPU_PROF(NP_EHOUT, dbg.rxout, eagle_txq_drain(0));
+			if (eagle_rx_ring_init_done[1] != 0)
+				eagle_txq_drain(1);
+			if (eagle_rx_ring_init_done[2] != 0)
+				eagle_txq_drain(2);
+			eagle_mseg_drain(1);
+		}
 		NPU_PROF(NP_ETXD, dbg.txdone, done = eagle_txdone_poll());
 		if (done == 0)
 			eagle_delay(10);
@@ -1955,7 +1990,9 @@ void __attribute__((noreturn)) eagle_rx_refill_loop(void)
 {
 	npu_dbg_loop(NDBG_TAG('E', 'R', 'F', 'L'));
 	while (eagle_init_done == 0 || eagle_rx_en == 0 || eagle_tx_en == 0 ||
-	       eagle_rx_ring_init_done[0] == 0 || eagle_rx_ring_init_done[1] == 0)
+	       eagle_rx_ring_init_done[0] == 0 ||
+	       (eagle_rx_ring_init_done[1] == 0 &&
+		eagle_rx_ring_init_done[2] == 0))
 		npu_dbg_poll();
 	eagle_delay(10000);
 	npu_printf("start\n");
@@ -1969,8 +2006,16 @@ void __attribute__((noreturn)) eagle_rx_refill_loop(void)
 
 		NPU_PROF(NP_ERFL, dbg.refill[0], eagle_rx_ring_sweep(0));
 		eagle_delay(100);
-		NPU_PROF(NP_ERFL, dbg.refill[1], eagle_rx_ring_sweep(1));
-		eagle_delay(100);
+		if (eagle_rx_ring_init_done[1] != 0) {
+			NPU_PROF(NP_ERFL, dbg.refill[1],
+				 eagle_rx_ring_sweep(1));
+			eagle_delay(100);
+		}
+		if (eagle_rx_ring_init_done[2] != 0) {
+			NPU_PROF(NP_ERFL, dbg.refill[2],
+				 eagle_rx_ring_sweep(2));
+			eagle_delay(100);
+		}
 	}
 }
 
diff --git a/npu_wifi_init.c b/npu_wifi_init.c
index f8abece..89e6965 100644
--- a/npu_wifi_init.c
+++ b/npu_wifi_init.c
@@ -219,8 +219,17 @@ void wifi_ba_node_init(void)
 /* WiFi PCIe desc alloc: allocate PCIe descriptor ring buffer */
 void wifi_pcie_desc_alloc(void)
 {
+#ifdef EAGLE_DESC_DDR_BASE
+	/* v4: the ring descriptor arena is the stock DDR type1 region.
+	 * Nothing is bump-allocated in SRAM for it; the MSDU page ring
+	 * bases are derived from this fixed base in npu_wifi_eagle.c. */
+	wifi_pcie_desc_base = EAGLE_DESC_DDR_BASE;
+	npu_printf("PCIE_TOTAL_DESC_BASE=%x size=%x\n",
+		   wifi_pcie_desc_base, EAGLE_DESC_DDR_SIZE);
+#else
 	wifi_pcie_desc_base = sram_buf_alloc(1);
 	npu_printf("PCIE_TOTAL_DESC_BASE=%x\n", wifi_pcie_desc_base);
+#endif
 }
 
 /* second band's ring: the type 1 block is 0xC000 on AN7552, 0xC040 elsewhere */
EAGLE_V4_PATCH
}

run_verify() {
	python3 - "$OUT_DIR" "$REPO_ROOT" "$CROSS" <<'EAGLE_V4_VERIFY'
#!/usr/bin/env python3
"""Static validation for the AN7581 + MT7996 eagle v4 DDR descriptor build.

Everything here is read-only: it inspects the ELF, the two raw firmware
images and the disassembly produced by build-eagle-v4.sh.  There is no
board, no qemu, no flash path.
"""

import hashlib
import os
import re
import struct
import subprocess
import sys

CROSS = ""
REPO_ROOT = ""
TEXT_BASE = 0x84000000
DATA_BASE = 0x3E900000
SRAM_BASE = 0x3E800000
SRAM_SIZE = 0x78000
SRAM_END = SRAM_BASE + SRAM_SIZE - 2

NPU_PKT_HOST_BASE = 0x8A000000
NPU_PKT_HOST_END = 0x8CC00000          # 0x8A000000 + 0x2C00000, 44 MB
NPU_BA_SIZE = 0x200000                 # an7581-npu-wlan.dtsi npu_ba (2 MiB)
MSDU_PG_ENTRY_SIZE = 128               # msdu_pg_desc_fill(): id << 7
MSDU_PG_MAX_IDS = 1024                 # per-band pool capacity in type26
DESC_BASE = 0x3E8A2000                 # stock v08 type256/0x100
DESC_SIZE = 0x4A040                    # stock v08 type1
DESC_HOST_BASE = 0x8A0A2000
MASK = 0x1FFFFFFF

EXPECTED_RING_OFF = [
    0x00000,   # ring1 RRO band0
    0x22020,   # ring2 RRO band2
    0x06020,   # ring3 tx band0
    0x28040,   # ring4 tx band2 (after ring2 0x22020+0x6000+0x20 guard)
    0x00000,   # ring5 not in the stock table
    0x1F020,   # ring6 ind cmd
    0x18020,   # ring7 MSDU page band0
    0x19020,   # ring8 MSDU page band1
    0x1B020,   # ring9 MSDU page band2
]

RING_EXTENTS = {
    "qid0": 0x6000, "qid2": 0x6000, "qid5": 0x8000, "qid7": 0x8000,
    "qid8": 0x3000, "qid10": 0x1000, "qid11": 0x2000, "qid12": 0x4000,
}

EXPECTED_MSDU_PG_BASES = [0, 256, 768]
EXPECTED_MSDU_PG_LIMITS = [256, 512, 1024]

# v4 SRAM allocation order after tdma_init/bufid_init and core0 init.
# type26 is taken at the point type29 used to be and is shared with the
# MSDU page ids; type1/type44 no longer exist.
SRAM_ORDER = [138, 18, 28, 26, 11, 10, 9, 30, 25, 31, 22,
              132, 133, 129, 2, 14, 3, 15]


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd):
    cmd = [CROSS + cmd[0]] + cmd[1:]
    return subprocess.run(cmd, text=True, capture_output=True,
                          check=True).stdout


def symbol_table(elf):
    syms = {}
    out = run(["nm", elf])
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            try:
                syms[parts[2]] = int(parts[0], 16)
            except ValueError:
                pass
    return syms


def function_body(dis, name):
    m = re.search(r"\n[0-9a-f]+ <%s>:\n(.*?)\n\n" % re.escape(name), dis, re.S)
    if not m:
        raise SystemExit("function %s not found" % name)
    return m.group(1)


def section_table(elf):
    out = run(["readelf", "-S", "-W", elf])
    secs = {}
    for line in out.splitlines():
        m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+(\S+)\s+"
                     r"(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", line)
        if m:
            try:
                secs[m.group(1)] = (int(m.group(3), 16), int(m.group(5), 16))
            except ValueError:
                pass
    return secs


def parse_sram_tables(raw, syms):
    tables = {}
    for name in ("sram_size_lo", "sram_size_hi"):
        addr = syms.get(name)
        if addr is None:
            raise SystemExit("%s symbol missing" % name)
        off = addr - TEXT_BASE
        for _ in range(64):
            typ, _flags, size = struct.unpack_from("<HHI", raw, off)
            if typ == 0:
                break
            tables[typ] = size
            off += 8
    return tables


def find_qid_table(raw, text_end, scan_start):
    """Find the 13-entry qid jump table in .rodata by its shape."""
    for at in range(scan_start, len(raw) - 52, 4):
        vals = [struct.unpack_from("<I", raw, at + 4 * i)[0]
                for i in range(13)]
        if not all(TEXT_BASE <= v < text_end for v in vals):
            continue
        if (vals[0] == vals[1] and vals[3] == vals[4]
                and vals[5] == vals[6] == vals[7] and vals[8] == vals[9]
                and vals[2] != vals[3] and vals[2] != vals[4]
                and len({vals[10], vals[11], vals[12]}) == 3
                and vals[10] != vals[3] and vals[11] != vals[3]
                and vals[12] != vals[3]):
            return at
    return None


def ring_values_from_offs(offs):
    return {
        "qid0": DESC_BASE + offs[0],
        "qid2": DESC_BASE + offs[1],
        "qid5": DESC_BASE + offs[2],
        "qid7": DESC_BASE + offs[3],
        "qid8": DESC_BASE + offs[5],
        "qid10": DESC_BASE + offs[6],
        "qid11": DESC_BASE + offs[7],
        "qid12": DESC_BASE + offs[8],
    }


def check_ring_non_overlap(values, extents):
    """Reject any pairwise-overlapping [base, base + extent) DMA rings."""
    intervals = sorted(
        (addr, addr + extents[name], name)
        for name, addr in values.items()
    )
    for i in range(len(intervals)):
        a_start, a_end, a_name = intervals[i]
        for j in range(i + 1, len(intervals)):
            b_start, b_end, b_name = intervals[j]
            if b_start < a_end:
                overlap = min(a_end, b_end) - b_start
                raise SystemExit(
                    "DMA ring overlap: %s [%#x, %#x) overlaps %s [%#x, %#x) "
                    "by %#x bytes"
                    % (a_name, a_start, a_end, b_name, b_start, b_end, overlap)
                )


def read_image_bytes(addr, size, raw, dbin, data_size):
    """Read `size` bytes at ELF address `addr` from npu_rv32.bin or npu_data.bin."""
    if TEXT_BASE <= addr and addr + size <= TEXT_BASE + len(raw):
        off = addr - TEXT_BASE
        return raw[off:off + size]
    if DATA_BASE <= addr and addr + size <= DATA_BASE + data_size:
        off = addr - DATA_BASE
        return dbin[off:off + size]
    raise SystemExit("symbol address %#x (+%#x) outside .text/.rodata and .data"
                     % (addr, size))


def check_msdu_pg_id_ranges(bases, limits, ba_size=NPU_BA_SIZE):
    """Reject overlapping or out-of-bounds per-band MSDU page ID ranges."""
    if len(bases) != 3 or len(limits) != 3:
        raise SystemExit("expected 3 MSDU page bands, got %d/%d"
                         % (len(bases), len(limits)))
    intervals = []
    for band, (base, lim) in enumerate(zip(bases, limits)):
        if lim <= 0 or lim > MSDU_PG_MAX_IDS:
            raise SystemExit("MSDU page band%d limit %d outside 1..%d"
                             % (band, lim, MSDU_PG_MAX_IDS))
        end = base + lim
        if base < 0 or end > 0x7FFF:
            raise SystemExit("MSDU page band%d ID range [%d, %d) exceeds s16"
                             % (band, base, end))
        if end * MSDU_PG_ENTRY_SIZE > ba_size:
            raise SystemExit(
                "MSDU page band%d DRAM end %#x exceeds npu_ba size %#x"
                % (band, end * MSDU_PG_ENTRY_SIZE, ba_size)
            )
        intervals.append((base, end, band))
    intervals.sort()
    for i in range(len(intervals)):
        a_start, a_end, a_band = intervals[i]
        for j in range(i + 1, len(intervals)):
            b_start, b_end, b_band = intervals[j]
            if b_start < a_end:
                overlap = min(a_end, b_end) - b_start
                raise SystemExit(
                    "MSDU page ID overlap: band%d [%d, %d) overlaps "
                    "band%d [%d, %d) by %d IDs (%#x DRAM bytes)"
                    % (a_band, a_start, a_end, b_band, b_start, b_end,
                       overlap, overlap * MSDU_PG_ENTRY_SIZE)
                )


def main():
    global CROSS, REPO_ROOT
    if len(sys.argv) not in (2, 4):
        raise SystemExit("usage: verify-eagle-v4.py <build-dir> "
                         "[<repo-root> <cross-prefix>]")
    build = sys.argv[1]
    if len(sys.argv) == 4:
        REPO_ROOT = sys.argv[2]
        CROSS = sys.argv[3]
    elf = os.path.join(build, "firmware.elf")
    rv = os.path.join(build, "npu_rv32.bin")
    data = os.path.join(build, "npu_data.bin")
    for f in (elf, rv, data):
        if not os.path.exists(f):
            raise SystemExit("missing %s" % f)

    raw = open(rv, "rb").read()
    dbin = open(data, "rb").read()
    syms = symbol_table(elf)
    dis = run(["objdump", "-d", "-M", "no-aliases", elf])
    secs = section_table(elf)
    text_addr, text_size = secs[".text"]
    text_end = text_addr + text_size
    data_addr, data_size = secs[".data"]

    if text_addr != TEXT_BASE:
        raise SystemExit(".text base %#x, expected %#x" % (text_addr, TEXT_BASE))
    if data_addr != DATA_BASE:
        raise SystemExit(".data base %#x, expected %#x" % (data_addr, DATA_BASE))
    if len(dbin) != data_size:
        raise SystemExit("npu_data.bin %d B but .data is %d B"
                         % (len(dbin), data_size))
    if text_size + secs[".rodata"][1] != len(raw):
        raise SystemExit("npu_rv32.bin is not .text+.rodata")

    # ---- 1. reset vector, entry and eight-way mhartid dispatch ----------
    entry_m = re.search(r"Entry point address:\s+(0x[0-9a-f]+)",
                        run(["readelf", "-h", elf]))
    entry = int(entry_m.group(1), 16)
    if entry != TEXT_BASE:
        raise SystemExit("entry %#x, expected %#x" % (entry, TEXT_BASE))
    if raw[:16] != b"\x01\x00" * 8:
        raise SystemExit("reset vector is not eight 16-bit NOPs")
    if raw[16:20] != b"\x0f\x10\x00\x00" or raw[20:24] != b"\x0f\x00\xf0\x0f":
        raise SystemExit("fence.i/fence pair not at 0x84000010/0x84000014")
    body = function_body(dis, "_start")
    harts = re.findall(r"csrrs\s+t0,mhartid,zero", body)
    branches = re.findall(r"beq\s+t0,t1,", body)
    if len(harts) != 8 or len(branches) != 8:
        raise SystemExit("mhartid dispatch: %d csrr, %d beq"
                         % (len(harts), len(branches)))
    print("PASS entry 0x84000000, 8-way mhartid dispatch")

    # ---- 2. version string ------------------------------------------------
    version = b"TLB7.8.0.0_v003.MT7996.eagle-v4-ddr"
    if version not in raw:
        raise SystemExit("version string %r missing" % version)
    print("PASS version string %s" % version.decode())

    # ---- 3. NDBG block ----------------------------------------------------
    ndbg = syms.get("__ndbg_base")
    if ndbg != 0x3E906800:
        raise SystemExit("__ndbg_base %r, expected 0x3e906800" % ndbg)
    if "lui\ta5,0x4e444" not in dis or "addi\ta5,a5,583" not in dis:
        raise SystemExit("NDBG magic 0x4e444247 not found in disassembly")
    dbg_body = function_body(dis, "npu_dbg_init")
    if "3e906800" not in dbg_body or "3e907800" not in dbg_body:
        raise SystemExit("npu_dbg_init does not cover 0x3e906800..0x7800")
    print("PASS NDBG base 0x3e906800 (host 0x1e906800), magic 0x4e444247")

    # ---- 4. fixed DDR descriptor arena -----------------------------------
    alloc = function_body(dis, "wifi_pcie_desc_alloc")
    if "lui\ta1,0x3e8a2" not in alloc:
        raise SystemExit("descriptor base 0x3e8a2000 not materialised")
    if "addi\ta2,a2,64" not in alloc or "lui\ta2,0x4a" not in alloc:
        raise SystemExit("descriptor size 0x4a040 not materialised")
    sym_base = syms["wifi_pcie_desc_base"]
    if ("# %x <wifi_pcie_desc_base>" % sym_base) not in alloc:
        raise SystemExit("wifi_pcie_desc_base store not found")
    offs_sym = syms.get("off.0")
    if offs_sym is None:
        raise SystemExit("eagle ring offset table symbol missing")
    offs = list(struct.unpack_from("<9I", raw, offs_sym - TEXT_BASE))
    check_ring_non_overlap(ring_values_from_offs(offs), RING_EXTENTS)
    if offs != EXPECTED_RING_OFF:
        raise SystemExit("ring offsets %r, expected %r"
                         % ([hex(x) for x in offs], [hex(x) for x in EXPECTED_RING_OFF]))
    print("PASS DDR arena base 0x3e8a2000, type1 size 0x4a040")

    # ---- 5. MSDU page rings use ring7/8/9 -------------------------------
    pool = function_body(dis, "eagle_msdu_pg_pool_init")
    for lit in ("18020", "19020", "1b020"):
        if lit not in pool:
            raise SystemExit("MSDU page offset %s not in pool init" % lit)
    print("PASS MSDU page bases ring7/8/9 = +0x18020/+0x19020/+0x1b020")

    # ---- 6. qid dispatch table and 0x1fffffff mask ----------------------
    qtab = find_qid_table(raw, text_end, secs[".rodata"][0] - TEXT_BASE)
    if qtab is None:
        raise SystemExit("13-entry qid jump table not found")
    qvals = list(struct.unpack_from("<13I", raw, qtab))
    handler = syms.get("eagle_mail_get_rxdesc_base")
    hbody = function_body(dis, "eagle_mail_get_rxdesc_base")
    if handler is None or not (text_addr <= handler < text_end):
        raise SystemExit("qid handler missing")
    if not re.search(r"c\.slli\s+a5,0x3", hbody) or \
       not re.search(r"c\.srli\s+a5,0x3", hbody):
        raise SystemExit("qid return is not masked with 0x1fffffff")
    if qvals[2] == qvals[3]:
        raise SystemExit("qid2 is not a distinct handler")
    if len({qvals[10], qvals[11], qvals[12]}) != 3:
        raise SystemExit("qid10/11/12 do not have distinct handlers")
    print("PASS qid table at 0x%x, qid2/7/11/12 distinct, return masked" % (qtab + TEXT_BASE))

    # ---- 7. computed qid values and DDR/SRAM bounds ---------------------
    values = ring_values_from_offs(offs)
    extents = RING_EXTENTS
    arena_end = DESC_BASE + DESC_SIZE
    for name, addr in values.items():
        masked = addr & MASK
        if masked == 0:
            raise SystemExit("%s is zero" % name)
        if not (DESC_BASE <= addr < arena_end):
            raise SystemExit("%s=%#x outside DDR arena" % (name, addr))
        if addr + extents[name] > arena_end:
            raise SystemExit("%s ring crosses type1 end" % name)
        host = DESC_HOST_BASE + (addr - DESC_BASE)
        print("PASS %-5s NPU %#010x host %#010x ring 0x%x" %
              (name, addr, masked, extents[name]))
    check_ring_non_overlap(values, extents)
    print("PASS all %d DMA ring intervals pairwise disjoint" % len(values))
    if DESC_HOST_BASE + DESC_SIZE > NPU_PKT_HOST_END:
        raise SystemExit("DDR descriptor arena crosses npu_pkt end")
    if arena_end > DESC_BASE + DESC_SIZE:
        raise SystemExit("arena exceeds type1")
    print("PASS DDR end %#x (host %#x) <= npu_pkt end %#x" %
          (arena_end, DESC_HOST_BASE + DESC_SIZE, NPU_PKT_HOST_END))

    # ---- 8. SRAM ledger replay ------------------------------------------
    sizes = parse_sram_tables(raw, syms)
    for gone in (1, 29, 44):
        if gone in sizes:
            raise SystemExit("type%d still has an SRAM size" % gone)
    if sizes.get(26) != 0x4000:
        raise SystemExit("type26 size %r, expected 0x4000" % sizes.get(26))
    if sizes.get(129) != 0xE5FF or sizes.get(133) != 0x11000:
        raise SystemExit("type129/133 %r/%r, expected 0xe5ff/0x11000"
                         % (sizes.get(129), sizes.get(133)))
    used = 0
    layout = {}
    for typ in SRAM_ORDER:
        size = sizes.get(typ)
        if size is None:
            raise SystemExit("type%d missing from size tables" % typ)
        addr = SRAM_BASE + used
        if used != 0:
            addr = (addr + 0x1F) & ~0x1F
        layout[typ] = addr
        used = addr - SRAM_BASE + size
    if used > SRAM_SIZE:
        raise SystemExit("SRAM ledger over by %#x (v2 regression)" % (used - SRAM_SIZE))
    if SRAM_BASE + used > SRAM_END + 2:
        raise SystemExit("allocator end past SRAM_END")
    t26_end = layout[26] + sizes[26]
    if t26_end > SRAM_BASE + used or t26_end > SRAM_END + 2:
        raise SystemExit("type26 block crosses the ledger")
    print("PASS SRAM ledger end %#x, SRAM_END %#x, free %#x" %
          (SRAM_BASE + used, SRAM_END, SRAM_END + 2 - (SRAM_BASE + used)))
    print("     type26 %#x..%#x (MSDU ids +0x0000, TDMA ids +0x1800)"
          % (layout[26], t26_end))

    # ---- 9. MSDU page ring limits & disjoint per-band ID ranges ---------
    lim_sym = syms.get("eagle_msdu_pg_id_limit")
    if lim_sym is None:
        raise SystemExit("eagle_msdu_pg_id_limit table missing")
    lims = list(struct.unpack_from(
        "<3H", read_image_bytes(lim_sym, 6, raw, dbin, data_size), 0
    ))
    base_sym = syms.get("eagle_msdu_pg_id_base")
    if base_sym is None:
        raise SystemExit("eagle_msdu_pg_id_base table missing")
    bases = list(struct.unpack_from(
        "<3H", read_image_bytes(base_sym, 6, raw, dbin, data_size), 0
    ))
    check_msdu_pg_id_ranges(bases, lims)
    if lims != EXPECTED_MSDU_PG_LIMITS:
        raise SystemExit("MSDU page limits %r, expected %r"
                         % (lims, EXPECTED_MSDU_PG_LIMITS))
    if bases != EXPECTED_MSDU_PG_BASES:
        raise SystemExit("MSDU page ID bases %r, expected %r"
                         % (bases, EXPECTED_MSDU_PG_BASES))
    if ("<eagle_msdu_pg_id_base>" not in pool and
            not (re.search(r",\s*(?:256|0x100)\b", pool) and
                 re.search(r",\s*(?:768|0x300)\b", pool))):
        raise SystemExit(
            "eagle_msdu_pg_pool_init does not apply per-band MSDU page ID bases"
        )
    print("PASS MSDU page limits %s, disjoint ID bases %s (DRAM 0x%x <= 0x%x)"
          % ("/".join(str(x) for x in lims),
             "/".join(str(x) for x in bases),
             max(b + l for b, l in zip(bases, lims)) * MSDU_PG_ENTRY_SIZE,
             NPU_BA_SIZE))

    # ---- 10. get-wait function table ------------------------------------
    ft = syms.get("get_wait_func_table")
    if ft is None or not (DATA_BASE <= ft < DATA_BASE + data_size):
        raise SystemExit("get_wait_func_table missing")
    ptrs = list(struct.unpack_from("<10I", dbin, ft - DATA_BASE))
    if any(not (text_addr <= p < text_end) for p in ptrs):
        raise SystemExit("get-wait table points outside .text")
    if ptrs[4] != handler:
        raise SystemExit("GET_WAIT_RXDESC_BASE does not point at the qid handler")
    print("PASS get-wait table at %#x, %d entries all in .text" % (ft, len(ptrs)))

    # ---- 11. image/bss/NDBG layout --------------------------------------
    img_end = syms.get("__image_end")
    bss_end = syms.get("__bss_end")
    if img_end is None or bss_end is None:
        raise SystemExit("__image_end/__bss_end missing")
    if img_end > TEXT_BASE + 0x200000:
        raise SystemExit("image %#x crosses the 2 MB rv32 limit" % img_end)
    if bss_end >= ndbg:
        raise SystemExit("__bss_end %#x overlaps NDBG %#x" % (bss_end, ndbg))
    if not (DATA_BASE <= ndbg and ndbg + 0x1000 <= DATA_BASE + 0x10000):
        raise SystemExit("NDBG block leaves the 64 KB local SRAM")
    print("PASS image end %#x (< 2 MB), bss end %#x < NDBG %#x" %
          (img_end, bss_end, ndbg))

    # ---- 12. sizes and md5 ----------------------------------------------
    print("ARTIFACT npu_rv32.bin  %d B  md5 %s" % (len(raw), md5(rv)))
    print("ARTIFACT npu_data.bin  %d B  md5 %s" % (len(dbin), md5(data)))
    print("ARTIFACT firmware.elf  %d B  md5 %s" % (os.path.getsize(elf), md5(elf)))

    # ---- 13. stock v08 comparison (optional, only reads repo files) -----
    stock_dir = os.path.join(REPO_ROOT, "package/firmware/linux-firmware/files/airoha")
    for name in ("npu_rv32.bin", "npu_data.bin"):
        stock = os.path.join(stock_dir, "en7581_MT7996_" + name)
        ours = rv if name == "npu_rv32.bin" else data
        if not os.path.exists(stock):
            continue
        ssize = os.path.getsize(stock)
        ssum = md5(stock)
        osum = md5(ours)
        print("STOCK en7581_MT7996_%s %d B md5 %s" % (name, ssize, ssum))
        print("DELTA ours/stock size %.3f, md5 %s" %
              (os.path.getsize(ours) / ssize,
               "same" if osum == ssum else "different"))
        if name == "npu_rv32.bin":
            sraw = open(stock, "rb").read()
            found = [s for s in (b"TLB7.7.0.0_v08", b"TLB7.8.0.0_v003")
                     if s in sraw]
            print("STOCK version string %s" % (found[0].decode() if found
                                               else "not found"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EAGLE_V4_VERIFY
}

print_steps() {
	cat <<EOF
build-eagle-v4.sh --dry-run
  no network access, no compiler, no file writes, no device access

  target:   SOC=AN7581 WIFI=MT7996, datapath WIFI_EAGLE (not kite)
  source:   $CLANKER_URL
  commit:   $CLANKER_COMMIT
  patch:    eagle-v4 source patch (embedded in this script, 11 files)
  worktree: $SRC_DIR
  output:   $OUT_DIR

steps
  1. clone the source at the pinned commit if $SRC_DIR is absent;
     otherwise verify the checkout is at that commit
  2. apply the embedded v4 patch:
       * ring descriptor arena -> DDR 0x3E8A2000, type1 = 0x4A040
       * qid10/11/12 -> stock ring7/8/9 offsets 0x18020/0x19020/0x1B020
       * remove SRAM types 1/29/44; type26=0x4000; type129=0xE5FF;
         type133=0x11000
  3. make -B SOC=AN7581 WIFI=MT7996 CLANKER=0 NPUTX=1 NPUDBG=0 PROF=0 \\
       GITREV=$CLANKER_GITREV CROSS=$CROSS
  4. copy npu_rv32.bin, npu_data.bin, firmware.elf, firmware.map and the
     disassembly to $OUT_DIR and write manifest.txt
  5. run the embedded static validator over the ELF and raw images:
       entry 0x84000000 and the 8-way mhartid dispatch
       version string TLB7.8.0.0_v003.MT7996.$CLANKER_GITREV
       NDBG block 0x3E906800, magic 0x4E444247
       DDR arena 0x3E8A2000..0x3E8EC040; qid10/11/12 at
         0x3E8BA020/0x3E8BB020/0x3E8BD020 (host 0x1E8BA020/...),
         qid2 0x3E8C4020 and qid7 0x3E8CA040
       DDR end <= npu_pkt end 0x8CC00000; every ring fits type1 and all
         DMA ring intervals are pairwise disjoint
       SRAM ledger: types 1/29/44 gone, type26=0x4000, type129=0xE5FF,
         type133=0x11000, allocator end below 0x3E877FFE
       MSDU page ring limits 256/512/1024 x 16 B, spacing 0x1000/0x2000,
         disjoint per-band MSDU page ID bases 0/256/768 (DRAM 0x38000 <= 0x200000)
       get-wait table 10 entries in .text, image below 2 MB,
         __bss_end below NDBG

  hashes and sizes are recorded in manifest.txt after build
  no board, no flash, no device write
EOF
}

gcc_version_line() {
	local out
	out="$("${CROSS}gcc" --version)" || return 1
	[ -n "$out" ] || return 1
	printf '%s\n' "${out%%$'\n'*}"
}

require_tools() {
	local t
	for t in git make python3 md5sum sha256sum stat awk tee \
		 "${CROSS}gcc" "${CROSS}ld" "${CROSS}objcopy" \
		 "${CROSS}objdump" "${CROSS}nm" "${CROSS}readelf"; do
		command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
	done
	gcc_version_line || die "${CROSS}gcc is not usable"
}

fetch_source() {
	local attempt
	if [ -d "$SRC_DIR/.git" ]; then
		say "using existing checkout: $SRC_DIR"
	else
		mkdir -p "$(dirname "$SRC_DIR")"
		for attempt in 1 2 3; do
			if git clone --quiet "$CLANKER_URL" "$SRC_DIR"; then
				break
			fi
			rm -rf "$SRC_DIR"
			if [ "$attempt" -eq 3 ]; then
				die "git clone failed after 3 attempts: $CLANKER_URL"
			fi
			say "clone attempt $attempt failed; retrying"
			sleep 3
		done
	fi
	if ! git -C "$SRC_DIR" cat-file -e "$CLANKER_COMMIT^{commit}" 2>/dev/null; then
		git -C "$SRC_DIR" fetch --quiet origin "$CLANKER_COMMIT" ||
			die "cannot fetch $CLANKER_COMMIT in $SRC_DIR"
	fi
	git -C "$SRC_DIR" checkout --quiet "$CLANKER_COMMIT" ||
		die "cannot check out $CLANKER_COMMIT in $SRC_DIR (dirty worktree?)"
	[ "$(git -C "$SRC_DIR" rev-parse HEAD)" = "$CLANKER_COMMIT" ] ||
		die "source is not at pinned commit $CLANKER_COMMIT"
}

apply_patch() {
	if git -C "$SRC_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
		git -C "$SRC_DIR" apply --whitespace=nowarn "$PATCH_FILE"
		say "applied the embedded eagle-v4 source patch"
	elif git -C "$SRC_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
		say "source already carries the eagle-v4 source patch"
	else
		die "the embedded patch does not apply to $SRC_DIR"
	fi
}

build_firmware() {
	local build_dir="$SRC_DIR/build/AN7581_MT7996"
	local -a make_cmd

	rm -rf "$OUT_DIR"
	mkdir -p "$OUT_DIR"

	make_cmd=(make -B SOC=AN7581 WIFI=MT7996 CLANKER=0 NPUTX=1 NPUDBG=0
		PROF=0 GITREV="$CLANKER_GITREV" CROSS="$CROSS")
	if [ -n "$JOBS" ]; then
		make_cmd+=(-j "$JOBS")
	fi

	say "building: ${make_cmd[*]}"
	(cd "$SRC_DIR" && "${make_cmd[@]}") | tee "$OUT_DIR/build.log"

	[ -s "$build_dir/npu_rv32.bin" ] || die "build produced no npu_rv32.bin"
	[ -s "$build_dir/npu_data.bin" ] || die "build produced no npu_data.bin"
	cp "$build_dir/npu_rv32.bin" "$build_dir/npu_data.bin" \
	   "$build_dir/firmware.elf" "$build_dir/firmware.map" "$OUT_DIR/"
	"${CROSS}objdump" -d -M no-aliases "$build_dir/firmware.elf" \
		> "$OUT_DIR/firmware.dis"
}

write_manifest() {
	local rv="$OUT_DIR/npu_rv32.bin"
	local data="$OUT_DIR/npu_data.bin"
	local elf="$OUT_DIR/firmware.elf"

	{
		echo "source: ClankerConstruction/ClankerNPU @ $CLANKER_COMMIT"
		echo "source_patch_sha256: $(sha256sum "$PATCH_FILE" | awk '{print $1}')"
		echo "build: SOC=AN7581 WIFI=MT7996 CLANKER=0 NPUTX=1 NPUDBG=0 PROF=0 GITREV=$CLANKER_GITREV CROSS=$CROSS"
		echo "toolchain: $(gcc_version_line)"
		echo "npu_rv32.bin: $(stat -c '%s' "$rv") B md5 $(md5sum "$rv" | awk '{print $1}') sha256 $(sha256sum "$rv" | awk '{print $1}')"
		echo "npu_data.bin: $(stat -c '%s' "$data") B md5 $(md5sum "$data" | awk '{print $1}') sha256 $(sha256sum "$data" | awk '{print $1}')"
		echo "firmware.elf: $(stat -c '%s' "$elf") B md5 $(md5sum "$elf" | awk '{print $1}')"
		echo "static_validation: PASS"
		echo "board_or_flash: none"
	} > "$OUT_DIR/manifest.txt"
}

main() {
	local arg

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--src-dir)
			[ "$#" -ge 2 ] || die "--src-dir needs a value"
			SRC_DIR="$2"
			shift 2
			;;
		--out-dir)
			[ "$#" -ge 2 ] || die "--out-dir needs a value"
			OUT_DIR="$2"
			shift 2
			;;
		--jobs)
			[ "$#" -ge 2 ] || die "--jobs needs a value"
			JOBS="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
		esac
	done

	if [ "${DRY_RUN:-0}" -eq 1 ]; then
		print_steps
		exit 0
	fi

	require_tools
	mkdir -p "$BUILD_ROOT"
	write_patch
	fetch_source
	apply_patch
	build_firmware
	run_verify | tee "$OUT_DIR/verify.log"
	write_manifest

	say ""
	say "artifacts: $OUT_DIR"
	say "manifest:  $OUT_DIR/manifest.txt"
	say "not flashed, no device was contacted"
}

main "$@"
