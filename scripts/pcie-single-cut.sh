#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# pcie-single-cut.sh - opt-in, reversible pcie_single_cut bench switch
#
# The vendor documentation says turning pcie_single_cut off improves
# latency.  On the XR1710G (AN7581) the 32-bit register at 0x1fbe3418 reads
# 0x7 after boot; this switch writes 0x0 to turn the cut off.  It is a
# single-register experiment, not a throughput promise: judge it by P99
# latency and throughput, not by this script's own output.
#
# The switch is not part of the boot path.  No init script, uci-defaults
# file, image recipe or CI job calls it, and it does nothing unless a
# person runs it by hand.  It is not installed into the image.
#
# Commands:
#
#   status          read 0x1fbe3418 through devmem and print the value.
#                   Nothing is written, no backup or result file is made.
#   apply --confirm back up the current value to
#                   /tmp/pcie-single-cut/backup.txt, write 0x0, read the
#                   register back immediately, print the before value and
#                   the readback, and write /tmp/pcie-single-cut/result.json.
#                   --confirm is mandatory; without it this script does not
#                   access the register at all.
#   restore         write the value saved by apply back, read it back,
#                   verify it, print the values and update result.json.
#
# Safety:
#
#   - 0x1fbe3418 is outside the A53 forbidden window 0x1e900000-0x1ebfffff.
#   - Only this one address, only 32-bit accesses.  apply refuses to write
#     when the register reads outside the documented low three bits, so the
#     script can never clear an unknown field by writing 0x0.
#   - apply refuses to overwrite a backup that differs from the current
#     value, so a second apply cannot lose the original 0x7 captured first.
#   - apply and restore check /dev/mem and devmem before touching the
#     register.  The stock XR1710G kernel has CONFIG_DEVMEM unset and the
#     busybox devmem applet disabled, so a real run refuses on today's
#     image; enabling both is a separate kernel/busybox change and
#     deliberately not part of this script.
#   - apply writes 0x0 only.  restore writes only the value in backup.txt.
#
# Exit status: 0 success (including status and help), 1 access, readback or
# verification failure, 2 invalid usage (including apply without --confirm).
#
# This is plain POSIX sh and is shellcheck-clean.

set -u
umask 077

PROG=${0##*/}

ADDR=0x1fbe3418
ADDR_WIDTH=32
CUT_OFF=0

FORBIDDEN_LO=0x1e900000
FORBIDDEN_HI=0x1ebfffff

MEM_DEV=/dev/mem
BACKUP_DIR=/tmp/pcie-single-cut
BACKUP_FILE=$BACKUP_DIR/backup.txt
RESULT_FILE=$BACKUP_DIR/result.json

# State recorded by apply and restore, used by write_result().
ACTION=
ORIGINAL=
TARGET=
READBACK=
WRITE_RC=
READBACK_RC=
RESULT_VERIFIED=0

# Parsed values.
REG_VALUE=
HEX_VALUE=
BACKUP_VALUE=

usage() {
	cat <<EOF
Usage: $PROG <command>

Opt-in, reversible switch for pcie_single_cut at $ADDR on the XR1710G.
It does not run at boot and does nothing unless invoked by hand.

Commands:
  status           print the current 32-bit value; changes nothing
  apply --confirm  back up the value, write 0x0, read it back and verify it
  restore          write the backed-up value back, read it back and verify
  -h, --help       show this help

No argument prints this help and touches no register.

apply needs --confirm; without it no register access happens.  Both apply
and restore refuse when $MEM_DEV is missing or devmem is not in PATH.

Files:
  $BACKUP_FILE   original value saved by apply
  $RESULT_FILE   timestamp, original/new/readback values and return code

Exit status: 0 success or help, 1 access/readback/verify failure,
2 invalid usage.

The vendor says turning the cut off improves latency.  This is only an
experiment switch; judge it by P99 latency and throughput, not by this
script's output.
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

json_hex_or_null() {
	if [ -n "$1" ]; then
		printf '"%s"' "$(hex32 "$1")"
	else
		printf 'null'
	fi
}

json_int_or_null() {
	if [ -n "$1" ]; then
		printf '%d' "$1"
	else
		printf 'null'
	fi
}

# Parse a "0x..." 32-bit value.  Prints nothing; on success the numeric
# value is in HEX_VALUE and the function returns 0.
parse_hex32() {
	_ph_in=$1
	case "$_ph_in" in
	0x*|0X*) ;;
	*) return 1 ;;
	esac
	_ph_digits=${_ph_in#0x}
	_ph_digits=${_ph_digits#0X}
	case "$_ph_digits" in
	''|*[!0-9a-fA-F]*) return 1 ;;
	esac
	if [ "${#_ph_digits}" -gt 8 ]; then
		return 1
	fi
	HEX_VALUE=$((0x$_ph_digits))
	return 0
}

read_reg() {
	_rr_out=
	if ! _rr_out=$(devmem "$ADDR" "$ADDR_WIDTH" 2>&1); then
		warn "devmem read failed at $ADDR${_rr_out:+: $_rr_out}"
		return 1
	fi
	_rr_out=$(printf '%s' "$_rr_out" | tr -d '[:space:]')
	if ! parse_hex32 "$_rr_out"; then
		warn "devmem returned an unexpected value at $ADDR: '$_rr_out'"
		return 1
	fi
	REG_VALUE=$HEX_VALUE
	return 0
}

write_reg() {
	_wr_value=$1
	_wr_err=
	if ! _wr_err=$(devmem "$ADDR" "$ADDR_WIDTH" "$(hex32 "$_wr_value")" 2>&1 >/dev/null); then
		warn "devmem write of $(hex32 "$_wr_value") to $ADDR failed${_wr_err:+: $_wr_err}"
		return 1
	fi
	return 0
}

check_device() {
	# 0x1fbe3418 is word aligned and outside the A53 forbidden window; the
	# two checks keep a careless edit of ADDR from reaching the register.
	if [ $((ADDR % (ADDR_WIDTH / 8))) -ne 0 ]; then
		warn "refusing: $ADDR is not aligned for a $ADDR_WIDTH-bit access"
		return 1
	fi
	if [ $((ADDR)) -ge $((FORBIDDEN_LO)) ] && [ $((ADDR)) -le $((FORBIDDEN_HI)) ]; then
		warn "refusing: $ADDR is inside the A53 forbidden window $FORBIDDEN_LO-$FORBIDDEN_HI"
		return 1
	fi
	if [ ! -e "$MEM_DEV" ]; then
		warn "refusing: $MEM_DEV does not exist (kernel CONFIG_DEVMEM is off?)"
		return 1
	fi
	if ! command -v devmem >/dev/null 2>&1; then
		warn "refusing: devmem not found in PATH (busybox devmem applet off?)"
		return 1
	fi
	return 0
}

store_backup() {
	if ! printf '%s\n' "$(hex32 "$1")" > "$BACKUP_FILE"; then
		warn "could not write backup to $BACKUP_FILE"
		return 1
	fi
	return 0
}

load_backup() {
	if [ ! -f "$BACKUP_FILE" ]; then
		warn "no backup at $BACKUP_FILE; run '$PROG apply --confirm' first"
		return 1
	fi
	_lb_line=
	IFS= read -r _lb_line < "$BACKUP_FILE" || true
	_lb_line=$(printf '%s' "$_lb_line" | tr -d '[:space:]')
	if [ -z "$_lb_line" ]; then
		warn "backup at $BACKUP_FILE is empty or unreadable"
		return 1
	fi
	if ! parse_hex32 "$_lb_line"; then
		warn "backup at $BACKUP_FILE does not hold a 32-bit hex value: '$_lb_line'"
		return 1
	fi
	if [ "$HEX_VALUE" -gt 7 ]; then
		warn "backup at $BACKUP_FILE holds $(hex32 "$HEX_VALUE"), outside the documented 0x7 field"
		return 1
	fi
	BACKUP_VALUE=$HEX_VALUE
	return 0
}

write_result() {
	_res_rc=$1
	_res_verified=false
	if [ "$RESULT_VERIFIED" -eq 1 ]; then
		_res_verified=true
	fi
	_res_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || _res_timestamp=unknown
	_res_tmp=$RESULT_FILE.tmp
	{
		printf '{\n'
		printf '  "tool": "pcie-single-cut.sh",\n'
		printf '  "schema": 1,\n'
		printf '  "action": "%s",\n' "$ACTION"
		printf '  "timestamp_utc": "%s",\n' "$_res_timestamp"
		printf '  "address": "%s",\n' "$ADDR"
		printf '  "width": %d,\n' "$ADDR_WIDTH"
		printf '  "mem_dev": "%s",\n' "$MEM_DEV"
		printf '  "original": %s,\n' "$(json_hex_or_null "$ORIGINAL")"
		printf '  "new": %s,\n' "$(json_hex_or_null "$TARGET")"
		printf '  "readback": %s,\n' "$(json_hex_or_null "$READBACK")"
		printf '  "write_rc": %s,\n' "$(json_int_or_null "$WRITE_RC")"
		printf '  "readback_rc": %s,\n' "$(json_int_or_null "$READBACK_RC")"
		printf '  "verified": %s,\n' "$_res_verified"
		printf '  "backup_file": "%s",\n' "$BACKUP_FILE"
		printf '  "exit_code": %d\n' "$_res_rc"
		printf '}\n'
	} > "$_res_tmp" || {
		warn "could not write $_res_tmp"
		return 1
	}
	if ! mv -f "$_res_tmp" "$RESULT_FILE"; then
		warn "could not move result.json into place"
		return 1
	fi
	msg "result.json: $RESULT_FILE"
	return 0
}

do_status() {
	if ! check_device; then
		return 1
	fi
	if ! read_reg; then
		return 1
	fi
	msg "$ADDR = $(hex32 "$REG_VALUE")"
	return 0
}

do_apply() {
	ACTION=apply

	if ! mkdir -p "$BACKUP_DIR"; then
		die "could not create $BACKUP_DIR"
	fi
	if ! check_device; then
		warn "apply refused; the register was not accessed"
		write_result 1
		exit 1
	fi
	if ! read_reg; then
		warn "apply refused; the register was not written"
		write_result 1
		exit 1
	fi
	ORIGINAL=$REG_VALUE
	msg "before:  $ADDR = $(hex32 "$ORIGINAL")"

	if [ "$ORIGINAL" -gt 7 ]; then
		warn "refusing: $ADDR reads $(hex32 "$ORIGINAL"), outside the documented 0x7"
		warn "single-cut field; writing 0x0 could clear unrelated bits"
		write_result 1
		exit 1
	fi

	# Never replace a backup that does not describe the value in the
	# register: a second apply after a successful one must not turn the
	# saved 0x7 baseline into 0x0.
	if [ -e "$BACKUP_FILE" ]; then
		if ! load_backup; then
			warn "refusing: the existing backup could not be read; not overwriting it"
			write_result 1
			exit 1
		fi
		if [ "$BACKUP_VALUE" -ne "$ORIGINAL" ]; then
			warn "refusing: $BACKUP_FILE holds $(hex32 "$BACKUP_VALUE")"
			warn "but the register reads $(hex32 "$ORIGINAL")"
			warn "run '$PROG restore' or remove the stale backup first"
			write_result 1
			exit 1
		fi
	fi

	if ! store_backup "$ORIGINAL"; then
		warn "apply refused; the register was not written"
		write_result 1
		exit 1
	fi
	msg "backup:  $BACKUP_FILE = $(hex32 "$ORIGINAL")"

	TARGET=$CUT_OFF
	if ! write_reg "$TARGET"; then
		WRITE_RC=1
		if read_reg; then
			READBACK=$REG_VALUE
			READBACK_RC=0
			msg "after:   $ADDR = $(hex32 "$READBACK")"
		else
			READBACK_RC=1
		fi
		warn "apply failed at the write; backup is intact"
		warn "run '$PROG restore' to put $(hex32 "$ORIGINAL") back"
		write_result 1
		exit 1
	fi
	WRITE_RC=0

	if ! read_reg; then
		READBACK_RC=1
		warn "apply failed at the readback; backup is intact"
		warn "run '$PROG restore' to put $(hex32 "$ORIGINAL") back"
		write_result 1
		exit 1
	fi
	READBACK_RC=0
	READBACK=$REG_VALUE
	msg "after:   $ADDR = $(hex32 "$READBACK")"

	if [ "$READBACK" -eq "$TARGET" ]; then
		RESULT_VERIFIED=1
		msg "verified: pcie_single_cut is off (0x0)"
		if ! write_result 0; then
			warn "the register was changed but result.json could not be written"
			exit 1
		fi
		msg "roll back with: $PROG restore"
		exit 0
	fi

	warn "apply failed: readback $(hex32 "$READBACK") does not match $(hex32 "$TARGET")"
	warn "backup is intact; run '$PROG restore' to put $(hex32 "$ORIGINAL") back"
	write_result 1
	exit 1
}

do_restore() {
	ACTION=restore

	if ! mkdir -p "$BACKUP_DIR"; then
		die "could not create $BACKUP_DIR"
	fi
	if ! check_device; then
		warn "restore refused; the register was not accessed"
		write_result 1
		exit 1
	fi
	if ! load_backup; then
		write_result 1
		exit 1
	fi

	if ! read_reg; then
		warn "restore refused; the register was not written"
		write_result 1
		exit 1
	fi
	ORIGINAL=$REG_VALUE
	msg "before:  $ADDR = $(hex32 "$ORIGINAL")"

	TARGET=$BACKUP_VALUE
	if ! write_reg "$TARGET"; then
		WRITE_RC=1
		if read_reg; then
			READBACK=$REG_VALUE
			READBACK_RC=0
			msg "after:   $ADDR = $(hex32 "$READBACK")"
		else
			READBACK_RC=1
		fi
		warn "restore failed at the write; the backup is still at $BACKUP_FILE"
		write_result 1
		exit 1
	fi
	WRITE_RC=0

	if ! read_reg; then
		READBACK_RC=1
		warn "restore failed at the readback; the backup is still at $BACKUP_FILE"
		write_result 1
		exit 1
	fi
	READBACK_RC=0
	READBACK=$REG_VALUE
	msg "after:   $ADDR = $(hex32 "$READBACK")"

	if [ "$READBACK" -eq "$TARGET" ]; then
		RESULT_VERIFIED=1
		msg "verified: restored $(hex32 "$TARGET")"
		if ! write_result 0; then
			warn "the register was restored but result.json could not be written"
			exit 1
		fi
		exit 0
	fi

	warn "restore failed: readback $(hex32 "$READBACK") does not match $(hex32 "$TARGET")"
	warn "the backup is still at $BACKUP_FILE"
	write_result 1
	exit 1
}

main() {
	if [ "$#" -eq 0 ]; then
		usage
		exit 0
	fi

	_command=$1
	shift

	case "$_command" in
	status)
		if [ "$#" -ne 0 ]; then
			die_usage "status takes no arguments"
		fi
		do_status
		exit $?
		;;
	apply)
		_confirm=0
		while [ "$#" -gt 0 ]; do
			case "$1" in
			--confirm) _confirm=1 ;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die_usage "apply: unknown argument: $1"
				;;
			esac
			shift
		done
		if [ "$_confirm" -ne 1 ]; then
			die_usage "apply requires --confirm; no register was touched"
		fi
		do_apply
		;;
	restore)
		if [ "$#" -ne 0 ]; then
			die_usage "restore takes no arguments"
		fi
		do_restore
		;;
	-h|--help)
		usage
		;;
	*)
		die_usage "unknown command: $_command"
		;;
	esac
}

main "$@"
