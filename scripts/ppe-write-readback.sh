#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# ppe-write-readback.sh - gated single-entry PPE write/readback card (D2)
#
# ===========================================================================
#  WARNING - READ THIS BEFORE RUNNING ANYTHING
#
#  This card writes one live PPE SRAM entry through /dev/mem.  It is
#  FORBIDDEN on a board that has not passed M0:
#
#      M0 = full flash/partition backup (全盘备份)
#           + a tested serial-console recovery path (串口恢复)
#
#  If M0 is not done, STOP.  Do not run this script, not even its read-only
#  mode.  A wrong write can invalidate a live forwarding entry, corrupt
#  another flow's entry or take traffic off the fast path, and a board
#  without a tested recovery path may not come back.
# ===========================================================================
#
# Purpose
#
#   D2 has not explained why the 8192-16383 window reads back as zero nor
#   how many of the table's slots are aliases.  The one high-risk step is
#   to pick one known bound (BND) entry, back up its 80 bytes, write the
#   same 80 bytes back through the SRAM control path (REQ|WR), observe
#   whether the entry still hits and roll back.  This script makes that
#   step repeatable without inventing a new protocol each time.
#
#   The read-only path prints the raw 80 bytes, decodes ib1 (state, packet
#   type, BIND_TTL) and recomputes the entry's table hash with the current
#   tree's semantics.  The write path additionally keeps a byte-exact
#   backup, reads the entry back immediately, restores the original value
#   whatever happened, verifies the restore and records before/after
#   values, timestamps and return codes in result.json.
#
# Gates
#
#   A write needs all three of --confirm-write, --slot and --expected-hash.
#   Without --confirm-write no write command is ever issued.  --dry-run
#   never touches the device and works on a host without /dev/mem.
#
#   Refusals: /dev/mem missing, slot outside the SRAM window, state not
#   BND, hash != --expected-hash, backup write failure, no --confirm-write,
#   and any address outside the small allowlist this card programs.
#
#   Note: this tree's stock kernel config has CONFIG_DEVMEM unset and the
#   busybox devmem applet is disabled, so every real run refuses on today's
#   image; only --dry-run works there.  Enabling /dev/mem and devmem is a
#   separate kernel/busybox change and is deliberately not part of this card.
#
# Register map (drivers/net/ethernet/airoha/airoha_regs.h, FE base from the
# ethernet node in target/linux/airoha/dts/an7581.dtsi):
#
#   FE base            0x1fb50000
#   PPE1/PPE2 offset   0x0c00 / 0x1c00
#   REG_PPE_TB_CFG     + 0x21c      PPE_SRAM_TB_NUM_ENTRY_MASK (26:24)
#                                  PPE_DRAM_TB_NUM_ENTRY_MASK (2:0)
#   REG_PPE_RAM_CTRL   + 0x31c      ENTRY (23:8), WR (1), REQ (0), ACK (31)
#   REG_PPE_RAM_ENTRY  + 0x320      20 x u32, one 80-byte entry
#
# Entry geometry follows PPE_RAM_NUM_ENTRIES_SHIFT(): 1024 << field.  The
# hash is the current tree's airoha_ppe_foe_get_entry_hash(): the tuple is
# hashed exactly as the driver does and folded with airoha_ppe_fold_hash()
# for the geometry read from REG_PPE_TB_CFG.  Hash and slot are different
# things: a healthy entry sits in the slot its hash names, and an entry
# whose hash differs from its slot is the aliasing D2 is looking for.
#
# Usage:
#   scripts/ppe-write-readback.sh --dry-run
#   scripts/ppe-write-readback.sh --dry-run --slot 0x2004 --expected-hash 0x...
#   scripts/ppe-write-readback.sh --slot 0x2004
#   scripts/ppe-write-readback.sh --slot 0x2004 --expected-hash 0x4e2a \
#       --backup-dir /root/ppe-write --confirm-write
#
# Exit status:
#   0 - read-only report or dry run completed, or the write and its
#       verified restore both succeeded
#   1 - refused, or a write/readback/restore step failed
#   2 - invalid usage

set -u

PROG=${0##*/}

FE_BASE=$((0x1fb50000))
PPE1_OFF=$((0x0c00))
PPE2_OFF=$((0x1c00))
NUM_PPE=2
ENTRY_SIZE=80
ENTRY_NWORDS=20

OFF_TB_CFG=$((0x21c))
OFF_RAM_CTRL=$((0x31c))
OFF_RAM_ENTRY=$((0x320))

CTRL_WR=2
CTRL_REQ=1

DEFAULT_SRAM_PER_PPE=4096
NOSTATS_SRAM_PER_PPE=8192
DEFAULT_DRAM_ENTRIES=16384
DEFAULT_BACKUP_DIR=/tmp/ppe-write-readback

FORBIDDEN_LO=$((0x1e900000))
FORBIDDEN_HI=$((0x1ebfffff))
FORBIDDEN_SINGLE=$((0x1fb50284))

PPE1_BASE_ADDR=$((FE_BASE + PPE1_OFF))
PPE2_BASE_ADDR=$((FE_BASE + PPE2_OFF))
TBCFG0_ADDR=$((PPE1_BASE_ADDR + OFF_TB_CFG))
TBCFG1_ADDR=$((PPE2_BASE_ADDR + OFF_TB_CFG))
CTRL0_ADDR=$((PPE1_BASE_ADDR + OFF_RAM_CTRL))
CTRL1_ADDR=$((PPE2_BASE_ADDR + OFF_RAM_CTRL))
ENTRY0_BASE_ADDR=$((PPE1_BASE_ADDR + OFF_RAM_ENTRY))
ENTRY1_BASE_ADDR=$((PPE2_BASE_ADDR + OFF_RAM_ENTRY))

slot_arg=
expected_arg=
backup_dir=$DEFAULT_BACKUP_DIR
confirm_write=0
dry_run=0

slot=
expected_hash=
mem_dev=/dev/mem

SRAM_PER_PPE=
DRAM_ENTRIES=
SRAM_TOTAL=
TOTAL_ENTRIES=
GEOMETRY_NOTE=

PPE_INDEX=
ENTRY_INDEX=
CTRL_ADDR=
ENTRY_BASE=

BEFORE_WORDS=
AFTER_WORDS=
RESTORE_WORDS=

BACKUP_RC=0
WRITE_RC=0
READBACK_RC=0
RESTORE_RC=0
VERIFY_RC=0

BACKUP_FILE=
BACKUP_SHA=
WRITE_ATTEMPTED=0
TRIGGER_ATTEMPTED=0
RESTORE_NEEDED=0
RESULT_WRITTEN=0
RESULT_STATUS=
TIMESTAMP=

READ32_VALUE=
READ32_ERROR=

usage() {
	cat <<EOF
Usage: $PROG [options]

Gated single-entry PPE write/readback card for the XR1710G (AN7581).
Read-only unless --confirm-write is given together with --slot and
--expected-hash.

    M0 = full flash/partition backup + a tested serial-console recovery
    path.  M0 must be done before this script is run at all.

Options:
  --slot N            table slot to inspect, decimal or 0x hex
  --expected-hash H   expected table hash of the entry, decimal or 0x hex.
                      Take it from the "hash:" line of a read-only run;
                      a write is refused when the recomputed hash differs.
  --backup-dir DIR    where the 80-byte backup and result.json go
                      (default: $DEFAULT_BACKUP_DIR)
  --confirm-write     open the write gate; requires --slot and
                      --expected-hash.  Without it no write is issued.
  --dry-run           print the plan only: no device access, no write,
                      works without /dev/mem
  -h, --help          show this help

Read-only mode (default) prints the 80 raw bytes, ib1 state/packet type/
BIND_TTL, the recomputed hash and the slot placement, then exits 0.

The write path performs, in order: backup to <backup-dir>/backup-*.bin and
sha256, one REQ|WR of the same 80 bytes, an immediate readback, a restore
of the original 80 bytes, a restore readback, and result.json.  The restore
is attempted whatever the write and readback did.

Exit status: 0 report/dry run, or write+restore verified; 1 refused or a
step failed; 2 invalid usage.
EOF
}

msg() {
	printf '%s\n' "$*"
}

warn() {
	printf '%s: %s\n' "$PROG" "$*" >&2
}

die() {
	warn "error: $*"
	exit 1
}

die_usage() {
	warn "error: $*"
	printf 'Try "%s --help".\n' "$PROG" >&2
	exit 2
}

hex32() {
	printf '0x%08x' "$1"
}

hex4() {
	printf '0x%04x' "$1"
}

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ppe_base() {
	if [ "$1" -eq 0 ]; then
		printf '%s' "$PPE1_BASE_ADDR"
	else
		printf '%s' "$PPE2_BASE_ADDR"
	fi
}

tb_cfg_addr() {
	if [ "$1" -eq 0 ]; then
		printf '%s' "$TBCFG0_ADDR"
	else
		printf '%s' "$TBCFG1_ADDR"
	fi
}

ram_ctrl_addr() {
	if [ "$1" -eq 0 ]; then
		printf '%s' "$CTRL0_ADDR"
	else
		printf '%s' "$CTRL1_ADDR"
	fi
}

ram_entry_addr() {
	_base=$(ppe_base "$1")
	printf '%s' "$((_base + OFF_RAM_ENTRY + $2 * 4))"
}

# Only the registers this card is documented to touch are accepted.  A
# write outside this set is a bug in the script, not an operator mistake.
guard_addr() {
	_addr=$1
	_kind=$2
	case "$_addr" in
	''|*[!0-9]*)
		die "internal error: non-numeric address '$_addr'"
		;;
	esac
	if [ "$_addr" -ge "$FORBIDDEN_LO" ] && [ "$_addr" -le "$FORBIDDEN_HI" ]; then
		die "refusing $_kind at $(hex32 "$_addr"): the 0x1e900000-0x1ebfffff window is off limits"
	fi
	if [ "$_addr" -eq "$FORBIDDEN_SINGLE" ]; then
		die "refusing $_kind at $(hex32 "$_addr"): that register is on the deadbeef blocklist"
	fi
	if [ "$_addr" -eq "$TBCFG0_ADDR" ] || [ "$_addr" -eq "$TBCFG1_ADDR" ]; then
		return 0
	fi
	if [ "$_addr" -eq "$CTRL0_ADDR" ] || [ "$_addr" -eq "$CTRL1_ADDR" ]; then
		return 0
	fi
	if [ "$_addr" -ge "$ENTRY0_BASE_ADDR" ] && \
	   [ "$_addr" -lt $((ENTRY0_BASE_ADDR + ENTRY_SIZE)) ] && \
	   [ $(( (_addr - ENTRY0_BASE_ADDR) % 4 )) -eq 0 ]; then
		return 0
	fi
	if [ "$_addr" -ge "$ENTRY1_BASE_ADDR" ] && \
	   [ "$_addr" -lt $((ENTRY1_BASE_ADDR + ENTRY_SIZE)) ] && \
	   [ $(( (_addr - ENTRY1_BASE_ADDR) % 4 )) -eq 0 ]; then
		return 0
	fi
	die "refusing $_kind at $(hex32 "$_addr"): address is not in the PPE allowlist"
}

read32() {
	_r_addr=$1
	guard_addr "$_r_addr" read
	if ! _r_out=$(devmem "$_r_addr" 32 2>/dev/null); then
		READ32_ERROR="devmem read failed at $(hex32 "$_r_addr")"
		return 1
	fi
	case "$_r_out" in
	0x*|0X*) ;;
	*)
		READ32_ERROR="devmem returned non-hex output '$_r_out' at $(hex32 "$_r_addr")"
		return 1
		;;
	esac
	READ32_VALUE=$((_r_out & 0xffffffff))
	return 0
}

write32() {
	_w_addr=$1
	_w_value=$2
	guard_addr "$_w_addr" write
	devmem "$_w_addr" 32 "$(hex32 "$_w_value")" >/dev/null 2>&1
}

# Wait for PPE_SRAM_CTRL_ACK.  The hardware raises it immediately; there is
# no usleep in busybox ash, so poll a bounded number of times instead.
poll_ack() {
	_p_addr=$1
	_p_i=0
	while [ "$_p_i" -lt 200 ]; do
		if read32 "$_p_addr"; then
			if [ $(( (READ32_VALUE >> 31) & 1 )) -eq 1 ]; then
				return 0
			fi
		fi
		_p_i=$((_p_i + 1))
	done
	return 1
}

check_device() {
	if [ ! -e "$mem_dev" ]; then
		die "refusing: $mem_dev does not exist (needed for devmem)"
	fi
	if ! command -v devmem >/dev/null 2>&1; then
		die "refusing: devmem not found in PATH"
	fi
}

read_geometry() {
	if ! read32 "$(tb_cfg_addr 0)"; then
		die "cannot read PPE1 REG_PPE_TB_CFG: $READ32_ERROR"
	fi
	_g_cfg0=$READ32_VALUE
	if ! read32 "$(tb_cfg_addr 1)"; then
		die "cannot read PPE2 REG_PPE_TB_CFG: $READ32_ERROR"
	fi
	_g_cfg1=$READ32_VALUE

	_g_sram0=$(( (_g_cfg0 >> 24) & 7 ))
	_g_sram1=$(( (_g_cfg1 >> 24) & 7 ))
	_g_dram0=$(( _g_cfg0 & 7 ))
	_g_dram1=$(( _g_cfg1 & 7 ))

	if [ "$_g_sram0" -gt 4 ] || [ "$_g_sram1" -gt 4 ] || \
	   [ "$_g_dram0" -gt 4 ] || [ "$_g_dram1" -gt 4 ]; then
		die "implausible table geometry (PPE1 $(hex32 "$_g_cfg0"), PPE2 $(hex32 "$_g_cfg1"))"
	fi
	if [ $(( _g_cfg0 & 8 )) -ne 0 ] || [ $(( _g_cfg1 & 8 )) -ne 0 ]; then
		die "REG_PPE_TB_CFG selects a non-80-byte entry size; this card assumes 80"
	fi
	if [ "$_g_sram0" -ne "$_g_sram1" ]; then
		die "PPE1/PPE2 SRAM entry counts differ ($_g_sram0 vs $_g_sram1); refusing"
	fi
	if [ "$_g_dram0" -ne "$_g_dram1" ]; then
		die "PPE1/PPE2 DRAM entry counts differ ($_g_dram0 vs $_g_dram1); refusing"
	fi

	SRAM_PER_PPE=$((1024 << _g_sram0))
	DRAM_ENTRIES=$((1024 << _g_dram0))
	SRAM_TOTAL=$((SRAM_PER_PPE * NUM_PPE))
	TOTAL_ENTRIES=$((SRAM_TOTAL + DRAM_ENTRIES))
	GEOMETRY_NOTE="TB_CFG PPE1=$(hex32 "$_g_cfg0") PPE2=$(hex32 "$_g_cfg1")"

	msg "geometry: PPE1 $SRAM_PER_PPE + PPE2 $SRAM_PER_PPE SRAM +" \
	    "$DRAM_ENTRIES DRAM = $TOTAL_ENTRIES entries"
	msg "          ($GEOMETRY_NOTE)"
}

map_slot() {
	if [ "$slot" -ge "$TOTAL_ENTRIES" ]; then
		die "refusing slot $(hex32 "$slot"): table has only $TOTAL_ENTRIES entries"
	fi
	if [ "$slot" -lt "$SRAM_PER_PPE" ]; then
		PPE_INDEX=0
		ENTRY_INDEX=$slot
	elif [ "$slot" -lt "$SRAM_TOTAL" ]; then
		PPE_INDEX=1
		ENTRY_INDEX=$((slot - SRAM_PER_PPE))
	else
		die "refusing slot $(hex32 "$slot"): it is in the DRAM window" \
		    "[$SRAM_TOTAL, $TOTAL_ENTRIES). The REQ|WR SRAM path cannot" \
		    "address it; this card only writes SRAM slots."
	fi
	CTRL_ADDR=$(ram_ctrl_addr "$PPE_INDEX")
	ENTRY_BASE=$(ram_entry_addr "$PPE_INDEX" 0)
}

hw_read_entry() {
	_hr_ppe=$1
	_hr_entry=$2
	_hr_ctrl=$(ram_ctrl_addr "$_hr_ppe")
	if ! write32 "$_hr_ctrl" $(( (_hr_entry << 8) | CTRL_REQ )); then
		return 1
	fi
	if ! poll_ack "$_hr_ctrl"; then
		return 2
	fi
	_hr_words=
	_hr_i=0
	while [ "$_hr_i" -lt "$ENTRY_NWORDS" ]; do
		if ! read32 "$(ram_entry_addr "$_hr_ppe" "$_hr_i")"; then
			return 3
		fi
		_hr_words="$_hr_words $READ32_VALUE"
		_hr_i=$((_hr_i + 1))
	done
	ENTRY_READ_WORDS=${_hr_words# }
	return 0
}

# Write one entry with the SRAM control path: 20 data words, a bounce
# readback to catch a concurrent writer between the words and the trigger,
# then exactly one REQ|WR trigger.  Returns 1..6 so the caller can record
# which step failed.
hw_write_entry() {
	_hw_ppe=$1
	_hw_entry=$2
	_hw_words=$3
	_hw_ctrl=$(ram_ctrl_addr "$_hw_ppe")

	# shellcheck disable=SC2086
	set -- $_hw_words
	if [ $# -ne "$ENTRY_NWORDS" ]; then
		return 1
	fi

	_hw_i=0
	for _hw_w in "$@"; do
		if ! write32 "$(ram_entry_addr "$_hw_ppe" "$_hw_i")" "$_hw_w"; then
			return 2
		fi
		_hw_i=$((_hw_i + 1))
	done

	_hw_i=0
	for _hw_w in "$@"; do
		if ! read32 "$(ram_entry_addr "$_hw_ppe" "$_hw_i")"; then
			return 3
		fi
		if [ "$READ32_VALUE" -ne "$_hw_w" ]; then
			return 4
		fi
		_hw_i=$((_hw_i + 1))
	done

	TRIGGER_ATTEMPTED=1
	if ! write32 "$_hw_ctrl" $(( (_hw_entry << 8) | CTRL_WR | CTRL_REQ )); then
		return 5
	fi
	if ! poll_ack "$_hw_ctrl"; then
		return 6
	fi
	return 0
}

state_name() {
	case "$1" in
	0) printf 'INV' ;;
	1) printf 'UNB' ;;
	2) printf 'BND' ;;
	3) printf 'FIN' ;;
	*) printf 'UNKNOWN' ;;
	esac
}

ptype_name() {
	case "$1" in
	0) printf 'IPv4 5T (HNAPT)' ;;
	1) printf 'IPv4 3T (route)' ;;
	2) printf 'L2B (bridge)' ;;
	3) printf 'IPv4 DS-Lite' ;;
	4) printf 'IPv6 3T' ;;
	5) printf 'IPv6 5T' ;;
	6) printf 'reserved' ;;
	7) printf 'IPv6 6RD' ;;
	*) printf 'unknown' ;;
	esac
}

# airoha_ppe_fold_hash() from patches-7.3/212, including the 24576 special
# case the tree uses once flow counters carve the SRAM in half.
fold_hash() {
	if [ $(( $2 & ($2 - 1) )) -eq 0 ]; then
		printf '%s' "$(( $1 & ($2 - 1) ))"
	elif [ "$2" -eq 24576 ]; then
		printf '%s' "$(( ((($1 >> 13) % 3) * 8192) + ($1 & 8191) ))"
	else
		printf '%s' "$(( $1 % $2 ))"
	fi
}

# Recompute airoha_ppe_foe_get_entry_hash() for the 80-byte entry in $1.
# Sets E_RAW, E_HASH and E_HASH_OK.
compute_hash() {
	# shellcheck disable=SC2086
	set -- $1
	if [ $# -ne "$ENTRY_NWORDS" ]; then
		E_HASH_OK=0
		return
	fi
	_c_ib1=$1
	_c_type=$(( (_c_ib1 >> 25) & 7 ))

	case "$_c_type" in
	0|1)
		_c_hv1=$(( ${4} & 0xffffffff ))
		_c_hv2=$(( ${3} & 0xffffffff ))
		_c_hv3=$(( ${2} & 0xffffffff ))
		;;
	2)
		# src_mac_hi (u32) and src_mac_lo (u16) of the bridge l2 block
		_c_hv1=$(( (((${15}) & 0xffff) << 16) | (((${16}) >> 16) & 0xffff) ))
		_c_hv2=$(( ((${14}) & 0xffff0000) | (((${15}) >> 16) & 0xffff) ))
		_c_hv3=$(( ${13} & 0xffffffff ))
		;;
	4|5)
		_c_hv1=$(( (${5} ^ ${9} ^ ${10}) & 0xffffffff ))
		_c_hv2=$(( (${4} ^ ${8} ^ ${6}) & 0xffffffff ))
		_c_hv3=$(( (${3} ^ ${7} ^ ${2}) & 0xffffffff ))
		;;
	*)
		E_HASH_OK=0
		E_RAW=
		E_HASH=
		return
		;;
	esac

	_c_h=$(( (_c_hv1 & _c_hv2) | ((~_c_hv1 & 0xffffffff) & _c_hv3) ))
	_c_h=$(( ((_c_h >> 24) | ((_c_h & 0xffffff) << 8)) & 0xffffffff ))
	_c_h=$(( (_c_h ^ _c_hv1 ^ _c_hv2 ^ _c_hv3) & 0xffffffff ))
	_c_h=$(( (_c_h ^ (_c_h >> 16)) & 0xffffffff ))

	E_RAW=$_c_h
	E_HASH=$(fold_hash "$_c_h" "$TOTAL_ENTRIES")
	E_HASH_OK=1
}

decode_entry() {
	_d_words=$1
	# shellcheck disable=SC2086
	set -- $_d_words
	if [ $# -ne "$ENTRY_NWORDS" ]; then
		E_IB1=0
		E_STATE=0
		E_STATE_NAME=UNKNOWN
		E_PTYPE=0
		E_PTYPE_NAME=unknown
		E_TTL=0
		E_HASH_OK=0
		return
	fi
	E_IB1=$1
	E_STATE=$(( (E_IB1 >> 28) & 3 ))
	E_PTYPE=$(( (E_IB1 >> 25) & 7 ))
	E_TTL=$(( (E_IB1 >> 24) & 1 ))
	E_STATE_NAME=$(state_name "$E_STATE")
	E_PTYPE_NAME=$(ptype_name "$E_PTYPE")
	compute_hash "$_d_words"
}

print_words() {
	_p_label=$1
	_p_words=$2
	# shellcheck disable=SC2086
	set -- $_p_words
	printf '%s (80 bytes, 20 x u32, register order):\n' "$_p_label"
	_p_i=0
	_p_line=
	for _p_w in "$@"; do
		_p_line="$_p_line $(hex32 "$_p_w")"
		_p_i=$((_p_i + 1))
		if [ $((_p_i % 4)) -eq 0 ]; then
			printf '  +%02x:%s\n' $(( (_p_i - 4) * 4 )) "$_p_line"
			_p_line=
		fi
	done
	if [ $((_p_i % 4)) -ne 0 ]; then
		printf '  +%02x:%s\n' $(( (_p_i - (_p_i % 4)) * 4 )) "$_p_line"
	fi
}

print_decode() {
	printf 'ib1: %s state=%s packet_type=0x%x (%s) bind_ttl=%d\n' \
		"$(hex32 "$E_IB1")" "$E_STATE_NAME" "$E_PTYPE" "$E_PTYPE_NAME" "$E_TTL"
	if [ "$E_HASH_OK" -eq 1 ]; then
		printf 'hash: %s (raw %s, folded for %d entries)\n' \
			"$(hex32 "$E_HASH")" "$(hex32 "$E_RAW")" "$TOTAL_ENTRIES"
		if [ "$E_HASH" -eq "$slot" ]; then
			printf 'placement: MATCH (hash == slot)\n'
		else
			printf 'placement: MISMATCH (entry hashes to %s but sits in slot %s)\n' \
				"$(hex32 "$E_HASH")" "$(hex32 "$slot")"
		fi
		if [ "$E_HASH" -lt $((0x4000)) ]; then
			printf 'note: hash is below 0x4000; D2 is about the high-hash region\n'
		fi
	else
		printf 'hash: n/a (packet type 0x%x is not hashed by the driver)\n' "$E_PTYPE"
	fi
}

print_target() {
	printf 'slot: %s (decimal %d) -> PPE%d entry %s\n' \
		"$(hex32 "$slot")" "$slot" "$((PPE_INDEX + 1))" "$(hex4 "$ENTRY_INDEX")"
	printf 'registers: RAM_CTRL %s, RAM_ENTRY base %s\n' \
		"$(hex32 "$CTRL_ADDR")" "$(hex32 "$ENTRY_BASE")"
}

# ---------------------------------------------------------------------------
# dry run
# ---------------------------------------------------------------------------

plan_one_geometry() {
	_g_per_ppe=$1
	_g_dram=$2
	_g_total=$(( _g_per_ppe * NUM_PPE + _g_dram ))
	_g_sram_total=$(( _g_per_ppe * NUM_PPE ))
	if [ -z "$slot" ]; then
		printf '  geometry %d/PPE + %d DRAM = %d entries: PPE1 entries 0..%d, PPE2 0..%d, DRAM from %s\n' \
			"$_g_per_ppe" "$_g_dram" "$_g_total" \
			$((_g_per_ppe - 1)) $((_g_per_ppe - 1)) "$(hex32 "$_g_sram_total")"
		return
	fi
	if [ "$slot" -ge "$_g_total" ]; then
		printf '  geometry %d/PPE + %d DRAM: slot %s is out of range\n' \
			"$_g_per_ppe" "$_g_dram" "$(hex32 "$slot")"
		return
	fi
	if [ "$slot" -lt "$_g_per_ppe" ]; then
		printf '  geometry %d/PPE + %d DRAM: slot %s -> PPE1 entry %s, RAM_CTRL %s\n' \
			"$_g_per_ppe" "$_g_dram" "$(hex32 "$slot")" \
			"$(hex4 "$slot")" "$(hex32 "$(ram_ctrl_addr 0)")"
	elif [ "$slot" -lt "$_g_sram_total" ]; then
		printf '  geometry %d/PPE + %d DRAM: slot %s -> PPE2 entry %s, RAM_CTRL %s\n' \
			"$_g_per_ppe" "$_g_dram" "$(hex32 "$slot")" \
			"$(hex4 $((slot - _g_per_ppe)))" "$(hex32 "$(ram_ctrl_addr 1)")"
	else
		printf '  geometry %d/PPE + %d DRAM: slot %s is DRAM, unsupported by the REQ|WR path\n' \
			"$_g_per_ppe" "$_g_dram" "$(hex32 "$slot")"
	fi
}

print_plan() {
	msg "mode: dry-run (no device access, no write)"
	msg "device: $mem_dev (not opened)"
	msg "backup dir: $backup_dir"
	msg "M0 prerequisite: not verified by this script (full backup + tested serial recovery)"
	printf '\n'
	msg "geometry is read from REG_PPE_TB_CFG on a real run; offline plan for the two"
	msg "known configurations (PPE1/PPE2 + DRAM):"
	plan_one_geometry "$DEFAULT_SRAM_PER_PPE" "$DEFAULT_DRAM_ENTRIES"
	plan_one_geometry "$NOSTATS_SRAM_PER_PPE" "$DEFAULT_DRAM_ENTRIES"
	printf '\n'
	if [ -n "$slot" ]; then
		msg "checks a real run would perform on slot $(hex32 "$slot"):"
	else
		msg "checks a real run would perform (give --slot to include the register plan):"
	fi
	msg "  1. /dev/mem exists and devmem is available"
	msg "  2. state is BND (any other state is refused for writing)"
	msg "  3. recomputed hash equals --expected-hash (write gate)"
	msg "  4. backup directory is writable and the 80-byte backup survives sha256"
	printf '\n'
	msg "write sequence if the gate is open (never executed by --dry-run):"
	msg "  1. read the 80-byte entry and write <backup-dir>/backup-*.bin"
	msg "  2. write the same 20 u32 words to REG_PPE_RAM_ENTRY"
	msg "  3. write REG_PPE_RAM_CTRL = entry<<8 | WR | REQ once, poll ACK"
	msg "  4. read the entry back immediately"
	msg "  5. write the original 20 words back and read them back"
	msg "  6. write before/after values, timestamps and return codes to result.json"
	printf '\n'
	if [ "$confirm_write" -eq 1 ]; then
		msg "note: --confirm-write was given together with --dry-run; dry-run wins and nothing is written"
	fi
	msg "dry-run complete: no write command was issued"
}

# ---------------------------------------------------------------------------
# backup and result.json
# ---------------------------------------------------------------------------

sha256_file() {
	if ! _s_sum=$(sha256sum "$1" 2>/dev/null); then
		return 1
	fi
	if [ -z "$_s_sum" ]; then
		return 1
	fi
	# shellcheck disable=SC2086
	set -- $_s_sum
	printf '%s' "$1"
}

# Write the 20 u32 words as the exact 80-byte little-endian blob the PPE
# holds, so the backup can be replayed with devmem word by word later.
write_words_blob() {
	_b_file=$1
	_b_words=$2
	_b_fmt=
	# shellcheck disable=SC2086
	set -- $_b_words
	if [ $# -ne "$ENTRY_NWORDS" ]; then
		return 1
	fi
	for _b_w in "$@"; do
		_b_b0=$(( _b_w & 0xff ))
		_b_b1=$(( (_b_w >> 8) & 0xff ))
		_b_b2=$(( (_b_w >> 16) & 0xff ))
		_b_b3=$(( (_b_w >> 24) & 0xff ))
		_b_fmt="$_b_fmt\\0$(printf '%03o' "$_b_b0")"
		_b_fmt="$_b_fmt\\0$(printf '%03o' "$_b_b1")"
		_b_fmt="$_b_fmt\\0$(printf '%03o' "$_b_b2")"
		_b_fmt="$_b_fmt\\0$(printf '%03o' "$_b_b3")"
	done
	printf '%b' "$_b_fmt" > "$_b_file"
}

create_backup() {
	if ! mkdir -p "$backup_dir" 2>/dev/null; then
		warn "refusing: cannot create backup directory $backup_dir; nothing was written"
		return 1
	fi
	if [ ! -d "$backup_dir" ]; then
		warn "refusing: backup path $backup_dir is not a directory; nothing was written"
		return 1
	fi
	BACKUP_FILE="$backup_dir/backup-$(printf '%04x' "$slot")-$TIMESTAMP.bin"
	if ! write_words_blob "$BACKUP_FILE" "$BEFORE_WORDS"; then
		warn "refusing: cannot write backup $BACKUP_FILE; nothing was written"
		return 1
	fi
	_b_size=$(wc -c < "$BACKUP_FILE" 2>/dev/null)
	if [ "$_b_size" != "$ENTRY_SIZE" ]; then
		warn "refusing: backup $BACKUP_FILE is $_b_size bytes, expected $ENTRY_SIZE; nothing was written"
		return 1
	fi
	if ! BACKUP_SHA=$(sha256_file "$BACKUP_FILE"); then
		warn "refusing: cannot sha256 backup $BACKUP_FILE; nothing was written"
		BACKUP_SHA=
		return 1
	fi
	return 0
}

entry_json() {
	_j_words=$1
	if [ -z "$_j_words" ]; then
		printf 'null'
		return
	fi
	decode_entry "$_j_words"

	if [ "$E_HASH_OK" -eq 1 ]; then
		_j_hash="\"$(hex32 "$E_HASH")\""
		_j_raw="\"$(hex32 "$E_RAW")\""
		_j_supported=true
	else
		_j_hash=null
		_j_raw=null
		_j_supported=false
	fi
	printf '{"ib1": "%s", "state": "%s", "packet_type": %d, "packet_type_name": "%s", "bind_ttl": %d, "hash": %s, "raw_hash": %s, "hash_supported": %s, "words": %s}' \
		"$(hex32 "$E_IB1")" "$E_STATE_NAME" "$E_PTYPE" "$E_PTYPE_NAME" "$E_TTL" \
		"$_j_hash" "$_j_raw" "$_j_supported" "$(words_json "$_j_words")"
}

words_json() {
	_q_first=1
	printf '['
	# shellcheck disable=SC2086
	set -- $1
	for _q_w in "$@"; do
		if [ "$_q_first" -eq 0 ]; then
			printf ', '
		fi
		printf '"%s"' "$(hex32 "$_q_w")"
		_q_first=0
	done
	printf ']'
}

write_result() {
	_r_status=$1
	_r_json=$backup_dir/result.json
	_r_tmp=$backup_dir/result.json.tmp

	_r_before=$(entry_json "$BEFORE_WORDS")
	_r_readback=$(entry_json "$AFTER_WORDS")
	_r_restore=$(entry_json "$RESTORE_WORDS")

	if [ "$TRIGGER_ATTEMPTED" -eq 1 ]; then
		_r_triggered=true
	else
		_r_triggered=false
	fi
	if [ "$WRITE_RC" -eq 0 ]; then
		_r_ack=true
	else
		_r_ack=false
	fi
	if [ -z "$AFTER_WORDS" ]; then
		_r_matches=null
	elif [ "$AFTER_WORDS" = "$BEFORE_WORDS" ]; then
		_r_matches=true
	else
		_r_matches=false
	fi
	if [ "$RESTORE_RC" -eq 0 ] && [ "$VERIFY_RC" -eq 0 ] && \
	   [ "$RESTORE_WORDS" = "$BEFORE_WORDS" ]; then
		_r_verified=true
	else
		_r_verified=false
	fi

	cat > "$_r_tmp" <<EOF
{
  "tool": "ppe-write-readback.sh",
  "schema": 1,
  "mode": "write",
  "status": "$_r_status",
  "timestamp_utc": "$TIMESTAMP",
  "hostname": "$(json_escape "$(uname -n 2>/dev/null)")",
  "kernel": "$(json_escape "$(uname -r 2>/dev/null)")",
  "m0_prerequisite": "not verified by this script; full backup and tested serial recovery required",
  "mem_dev": "$(json_escape "$mem_dev")",
  "fe_base": "$(hex32 "$FE_BASE")",
  "geometry": {"sram_per_ppe": $SRAM_PER_PPE, "num_ppe": $NUM_PPE, "sram_total": $SRAM_TOTAL, "dram": $DRAM_ENTRIES, "total": $TOTAL_ENTRIES, "source": "$GEOMETRY_NOTE"},
  "slot": $slot,
  "slot_hex": "$(hex32 "$slot")",
  "target": {"ppe": $((PPE_INDEX + 1)), "entry": $ENTRY_INDEX, "entry_hex": "$(hex4 "$ENTRY_INDEX")", "ram_ctrl": "$(hex32 "$CTRL_ADDR")", "ram_entry_base": "$(hex32 "$ENTRY_BASE")"},
  "expected_hash": "$(hex32 "$expected_hash")",
  "before": $_r_before,
  "backup": {"file": "$(json_escape "$BACKUP_FILE")", "sha256": "$BACKUP_SHA", "size": $ENTRY_SIZE},
  "write": {"attempted": true, "trigger_attempted": $_r_triggered, "trigger_value": "$(hex32 "$(( (ENTRY_INDEX << 8) | CTRL_WR | CTRL_REQ ))")", "rc": $WRITE_RC, "ack": $_r_ack},
  "readback": {"rc": $READBACK_RC, "matches_before": $_r_matches, "entry": $_r_readback},
  "restore": {"rc": $RESTORE_RC, "verify_rc": $VERIFY_RC, "verified": $_r_verified, "entry": $_r_restore},
  "return_codes": {"backup": $BACKUP_RC, "write": $WRITE_RC, "readback": $READBACK_RC, "restore": $RESTORE_RC, "verify": $VERIFY_RC}
}
EOF
	if ! mv "$_r_tmp" "$_r_json"; then
		warn "could not move result.json into place"
		return 1
	fi
	RESULT_WRITTEN=1
	msg "result.json: $_r_json"
}

# ---------------------------------------------------------------------------
# exit/signal handling
# ---------------------------------------------------------------------------

# shellcheck disable=SC2329 # invoked through trap
finish() {
	_f_rc=$?
	trap - EXIT INT TERM HUP
	if [ "$RESTORE_NEEDED" -eq 1 ]; then
		warn "interrupted during the write path; attempting to restore the saved 80 bytes"
		hw_write_entry "$PPE_INDEX" "$ENTRY_INDEX" "$BEFORE_WORDS"
		RESTORE_RC=$?
		if [ "$RESTORE_RC" -eq 0 ]; then
			hw_read_entry "$PPE_INDEX" "$ENTRY_INDEX"
			VERIFY_RC=$?
			if [ "$VERIFY_RC" -eq 0 ]; then
				RESTORE_WORDS=$ENTRY_READ_WORDS
				warn "restore command accepted; the readback is recorded in result.json"
			else
				warn "restore command accepted but the readback failed (rc=$VERIFY_RC)"
			fi
		else
			warn "AUTOMATIC RESTORE FAILED (rc=$RESTORE_RC); backup: ${BACKUP_FILE:-none}"
		fi
		RESTORE_NEEDED=0
	fi
	if [ "$WRITE_ATTEMPTED" -eq 1 ] && [ "$RESULT_WRITTEN" -eq 0 ]; then
		if [ "$_f_rc" -eq 0 ]; then
			_f_rc=1
		fi
		case "$RESULT_STATUS" in
		''|refused)
			RESULT_STATUS=interrupted
			;;
		esac
		write_result "$RESULT_STATUS" || warn "could not write result.json"
	fi
	exit "$_f_rc"
}

# ---------------------------------------------------------------------------
# write path
# ---------------------------------------------------------------------------

write_gate() {
	if [ -z "$expected_hash" ]; then
		die "refusing write: --expected-hash was not given"
	fi
	if [ ! -e "$mem_dev" ]; then
		die "refusing write: $mem_dev does not exist"
	fi
	if ! command -v devmem >/dev/null 2>&1; then
		die "refusing write: devmem not found in PATH"
	fi
	if ! command -v sha256sum >/dev/null 2>&1; then
		die "refusing write: sha256sum not found in PATH"
	fi
	if [ "$E_STATE" -ne 2 ]; then
		die "refusing write: slot $(hex32 "$slot") is $E_STATE_NAME, not BND"
	fi
	if [ "$E_HASH_OK" -ne 1 ]; then
		die "refusing write: cannot recompute the hash for packet type 0x$E_PTYPE"
	fi
	if [ "$E_HASH" -ne "$expected_hash" ]; then
		die "refusing write: hash $(hex32 "$E_HASH") != --expected-hash $(hex32 "$expected_hash")"
	fi
	msg "write gate: OPEN (state BND, hash == --expected-hash)"
}

do_write_path() {
	RESULT_STATUS=refused

	warn "M0 gate: a full flash backup and a tested serial recovery path must already be done"
	if ! create_backup; then
		die "refusing write: backup failed; nothing was written"
	fi
	BACKUP_RC=0
	msg "backup: $BACKUP_FILE ($ENTRY_SIZE bytes, sha256 $BACKUP_SHA)"

	WRITE_ATTEMPTED=1
	RESTORE_NEEDED=1

	hw_write_entry "$PPE_INDEX" "$ENTRY_INDEX" "$BEFORE_WORDS"
	WRITE_RC=$?
	msg "write REQ|WR: rc=$WRITE_RC"

	hw_read_entry "$PPE_INDEX" "$ENTRY_INDEX"
	READBACK_RC=$?
	if [ "$READBACK_RC" -eq 0 ]; then
		AFTER_WORDS=$ENTRY_READ_WORDS
	fi
	msg "readback: rc=$READBACK_RC"

	hw_write_entry "$PPE_INDEX" "$ENTRY_INDEX" "$BEFORE_WORDS"
	RESTORE_RC=$?
	msg "restore: rc=$RESTORE_RC"

	hw_read_entry "$PPE_INDEX" "$ENTRY_INDEX"
	VERIFY_RC=$?
	if [ "$VERIFY_RC" -eq 0 ]; then
		RESTORE_WORDS=$ENTRY_READ_WORDS
	fi
	RESTORE_NEEDED=0
	msg "restore readback: rc=$VERIFY_RC"

	if [ "$WRITE_RC" -ne 0 ]; then
		RESULT_STATUS=write-failed
	elif [ "$READBACK_RC" -ne 0 ]; then
		RESULT_STATUS=readback-failed
	elif [ "$AFTER_WORDS" != "$BEFORE_WORDS" ]; then
		RESULT_STATUS=readback-mismatch
	elif [ "$RESTORE_RC" -ne 0 ]; then
		RESULT_STATUS=restore-write-failed
	elif [ "$VERIFY_RC" -ne 0 ]; then
		RESULT_STATUS=restore-readback-failed
	elif [ "$RESTORE_WORDS" != "$BEFORE_WORDS" ]; then
		RESULT_STATUS=restore-mismatch
	else
		RESULT_STATUS=ok
	fi

	write_result "$RESULT_STATUS"

	case "$RESULT_STATUS" in
	ok)
		msg "result: OK - same value written back, read back, restored and verified"
		exit 0
		;;
	*)
		warn "result: $RESULT_STATUS"
		if [ "$RESTORE_RC" -ne 0 ] || [ "$VERIFY_RC" -ne 0 ] || \
		   [ "$RESTORE_WORDS" != "$BEFORE_WORDS" ]; then
			warn "restore was not fully confirmed.  Original 80 bytes: ${BACKUP_FILE:-none}"
			if [ "$VERIFY_RC" -eq 0 ] && [ "$RESTORE_WORDS" = "$BEFORE_WORDS" ]; then
				warn "the readback already equals the original, but the" \
				    "restore command was not acknowledged; verify the" \
				    "slot before resuming traffic."
			else
				warn "Do not reboot before reading the recovery section of scripts/ppe-write-readback.md."
			fi
		fi
		exit 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# argument parsing and main
# ---------------------------------------------------------------------------

parse_u32() {
	_v_in=$1
	case "$_v_in" in
	'')
		return 1
		;;
	0x*|0X*)
		case "${_v_in#??}" in
		''|*[!0-9a-fA-F]*)
			return 1
			;;
		esac
		_v=$((_v_in))
		;;
	*[!0-9]*)
		return 1
		;;
	*)
		# strip leading zeros so 010 is decimal 10, not octal
		_v=$_v_in
		while [ "${_v#0}" != "$_v" ]; do
			_v=${_v#0}
		done
		[ -n "$_v" ] || _v=0
		;;
	esac
	if [ "$_v" -lt 0 ] || [ "$_v" -gt 4294967295 ]; then
		return 1
	fi
	printf '%s' "$_v"
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--slot)
			[ $# -ge 2 ] || die_usage "--slot needs a value"
			slot_arg=$2
			shift 2
			;;
		--expected-hash)
			[ $# -ge 2 ] || die_usage "--expected-hash needs a value"
			expected_arg=$2
			shift 2
			;;
		--backup-dir)
			[ $# -ge 2 ] || die_usage "--backup-dir needs a value"
			backup_dir=$2
			[ -n "$backup_dir" ] || die_usage "--backup-dir cannot be empty"
			shift 2
			;;
		--confirm-write)
			confirm_write=1
			shift
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die_usage "unknown argument '$1'"
			;;
		esac
	done

	if [ -n "$slot_arg" ]; then
		if ! slot=$(parse_u32 "$slot_arg"); then
			die_usage "--slot '$slot_arg' is not a decimal or 0x hex u32"
		fi
	fi
	if [ -n "$expected_arg" ]; then
		if ! expected_hash=$(parse_u32 "$expected_arg"); then
			die_usage "--expected-hash '$expected_arg' is not a decimal or 0x hex u32"
		fi
	fi
	if [ "$confirm_write" -eq 1 ] && [ -z "$slot" ] && [ "$dry_run" -eq 0 ]; then
		die "refusing write: --confirm-write requires --slot"
	fi
	if [ "$confirm_write" -eq 1 ] && [ -z "$expected_hash" ] && [ "$dry_run" -eq 0 ]; then
		die "refusing write: --confirm-write requires --expected-hash"
	fi
}

main() {
	parse_args "$@"
	TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)
	if [ -z "$TIMESTAMP" ]; then
		TIMESTAMP=$(date +%Y%m%dT%H%M%SZ 2>/dev/null)
	fi
	[ -n "$TIMESTAMP" ] || TIMESTAMP=unknown

	trap finish EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP

	if [ "$dry_run" -eq 1 ]; then
		print_plan
		exit 0
	fi

	if [ -z "$slot" ]; then
		die_usage "read-only mode needs --slot (or use --dry-run for the plan)"
	fi

	check_device
	read_geometry
	map_slot

	if ! hw_read_entry "$PPE_INDEX" "$ENTRY_INDEX"; then
		die "cannot read slot $(hex32 "$slot") from the PPE"
	fi
	BEFORE_WORDS=$ENTRY_READ_WORDS

	print_target
	printf '\n'
	print_words "before" "$BEFORE_WORDS"
	decode_entry "$BEFORE_WORDS"
	print_decode

	if [ -n "$expected_hash" ] && [ "$E_HASH_OK" -eq 1 ]; then
		if [ "$E_HASH" -eq "$expected_hash" ]; then
			printf 'expected-hash: %s -> MATCH\n' "$(hex32 "$expected_hash")"
		else
			printf 'expected-hash: %s -> MISMATCH (recomputed %s)\n' \
				"$(hex32 "$expected_hash")" "$(hex32 "$E_HASH")"
		fi
	fi

	if [ "$confirm_write" -eq 0 ]; then
		printf '\n'
		msg "read-only: no write command was issued"
		msg "write gate: CLOSED (--confirm-write not given)"
		exit 0
	fi

	printf '\n'
	write_gate
	do_write_path
}

main "$@"
