#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# check-npu-firmware.sh - read-only audit of the Airoha NPU firmware images
# used by AN7581/AN7583 boards against CVE-2026-89142.
#
# The CVE affects Wi-Fi NPU firmware versions up to and including
# TLB7.8.0.0_v006.  This script only reads the candidate files and writes
# the optional report; it does not change the NPU firmware or the running
# system.
#
# Usage:
#   scripts/check-npu-firmware.sh
#   scripts/check-npu-firmware.sh --rootfs /path/to/rootfs
#   scripts/check-npu-firmware.sh --firmware-dir /path/to/airoha
#   scripts/check-npu-firmware.sh --out report.txt
#   scripts/check-npu-firmware.sh --dry-run
#
# Exit status:
#   0 - the check ran and produced a verdict (OK, VULNERABLE-RANGE or UNKNOWN)
#   1 - no candidate firmware file was found
#   2 - invalid usage or an unwritable report path

set -u

PROG=${0##*/}
CVE_ID=CVE-2026-89142
CVE_MAX_VERSION=TLB7.8.0.0_v006
VERSION_RE='TLB[0-9]+(\.[0-9]+)+(_v[0-9]+)?'

# Names shipped by the Airoha NPU firmware packages.  The rv32 images carry
# the TLB version string; the data images are reported for completeness.
FIRMWARE_NAMES='
en7581_MT7996_npu_rv32.bin
en7581_MT7996_npu_data.bin
en7581_npu_rv32.bin
en7581_npu_data.bin
an7583_npu_rv32.bin
an7583_npu_data.bin
'

# Keep string handling byte-oriented so the version regex and the known
# hashes do not depend on the host locale.
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
Usage: $PROG [options]

Check the Airoha NPU firmware against $CVE_ID.
Affected range: $CVE_MAX_VERSION and earlier.

Options:
  --rootfs DIR        scan a root filesystem tree instead of the running /
  --firmware-dir DIR  scan one directory (overrides --rootfs)
  --out FILE          also write the report to FILE
  --dry-run           print the paths that would be checked, read nothing
  -h, --help          show this help

Exit status: 0 check completed, 1 no firmware found, 2 usage error.
EOF
}

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 2
}

emit() {
	printf '%s\n' "$*"
	if [ -n "$out" ]; then
		printf '%s\n' "$*" >> "$out"
	fi
}

# Map a known firmware md5 to its release label.  Add an entry only after
# the image has been verified against a trusted source and its provenance
# has been recorded in issue #87.
known_hash() {
	case "$1" in
	550a8b3bf967a1e83bb1aaeca030ec7b)
		printf '%s\n' "TLB7.7.0.0_v08"
		;;
	210375f102c7c8a7c41f7a60c83d7652)
		printf '%s\n' "TLB7.7.0.0_v08 data"
		;;
	*)
		return 1
		;;
	esac
}

# Return 0 when the TLB version $1 is less than or equal to $2.
version_le() {
	awk -v a="$1" -v b="$2" '
	function parse(s, out,   n, p, i) {
		sub(/^TLB/, "", s)
		if (sub(/_v/, ".", s) == 0)
			s = s ".0"
		n = split(s, p, ".")
		for (i = 1; i <= 6; i++)
			out[i] = 0
		for (i = 1; i <= n && i <= 6; i++)
			out[i] = p[i] + 0
	}
	BEGIN {
		parse(a, x)
		parse(b, y)
		for (i = 1; i <= 6; i++) {
			if (x[i] < y[i])
				exit 0
			if (x[i] > y[i])
				exit 1
		}
		exit 0
	}'
}

check_file() {
	_file=$1
	_versions=
	_verdict=
	_known=
	_size=
	_md5=

	found=$((found + 1))
	emit "Firmware: $_file"

	_size=$(wc -c 2>/dev/null < "$_file") || _size=
	[ -n "$_size" ] || _size=unknown
	emit "  size: $_size bytes"

	_md5=$(md5sum "$_file" 2>/dev/null) || _md5=
	[ -n "$_md5" ] || _md5=unknown
	_md5=${_md5%% *}
	emit "  md5: $_md5"

	if [ "$_md5" != unknown ]; then
		_known=$(known_hash "$_md5") || _known=
	fi
	if [ -n "$_known" ]; then
		emit "  known-hash: MATCH"
		emit "  known-release: $_known"
	else
		emit "  known-hash: no match"
	fi

	if command -v strings >/dev/null 2>&1; then
		_versions=$(strings "$_file" 2>/dev/null |
			grep -oE "$VERSION_RE" 2>/dev/null)
	else
		_versions=$(tr -c '\040-\176' '\n' 2>/dev/null < "$_file" |
			grep -oE "$VERSION_RE" 2>/dev/null)
	fi
	_versions=$(printf '%s\n' "$_versions" | sort -u)

	if [ -z "$_versions" ]; then
		emit "  version: none found"
		emit "  note: no TLB version string"
		emit "  verdict: UNKNOWN"
		unknown=$((unknown + 1))
		return
	fi

	_verdict=OK
	while IFS= read -r _ver; do
		[ -n "$_ver" ] || continue
		emit "  version: $_ver"
		version_le "$_ver" "$CVE_MAX_VERSION"
		_rc=$?
		if [ "$_rc" -eq 0 ]; then
			_verdict=VULNERABLE-RANGE
		elif [ "$_rc" -ne 1 ] && [ "$_verdict" != VULNERABLE-RANGE ]; then
			_verdict=UNKNOWN
		fi
	done <<EOF
$_versions
EOF

	case "$_verdict" in
	VULNERABLE-RANGE)
		vulnerable=$((vulnerable + 1))
		;;
	UNKNOWN)
		unknown=$((unknown + 1))
		;;
	*)
		ok=$((ok + 1))
		;;
	esac
	emit "  verdict: $_verdict"
}

rootfs=
firmware_dir=
out=
dry_run=0

while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs)
		[ $# -ge 2 ] || die "--rootfs requires a directory"
		rootfs=$2
		shift 2
		;;
	--rootfs=*)
		rootfs=${1#*=}
		shift
		;;
	--firmware-dir)
		[ $# -ge 2 ] || die "--firmware-dir requires a directory"
		[ -n "$2" ] || die "--firmware-dir requires a directory"
		firmware_dir=$2
		shift 2
		;;
	--firmware-dir=*)
		firmware_dir=${1#*=}
		[ -n "$firmware_dir" ] || die "--firmware-dir requires a directory"
		shift
		;;
	--out)
		[ $# -ge 2 ] || die "--out requires a file"
		out=$2
		[ -n "$out" ] || die "--out requires a file"
		shift 2
		;;
	--out=*)
		out=${1#*=}
		[ -n "$out" ] || die "--out requires a file"
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
		die "unknown argument: $1"
		;;
	esac
done

if [ -n "$firmware_dir" ]; then
	scan_dirs=$firmware_dir
elif [ -n "$rootfs" ]; then
	scan_dirs="$rootfs/lib/firmware/airoha
$rootfs/usr/lib/firmware/airoha
$rootfs/lib/firmware
$rootfs/usr/lib/firmware"
else
	scan_dirs="/lib/firmware/airoha
/lib/firmware"
fi

if [ "$dry_run" -eq 1 ]; then
	if [ -n "$out" ]; then
		if ! ( : > "$out" ) 2>/dev/null; then
			printf '%s: warning: cannot write report: %s\n' \
				"$PROG" "$out" >&2
			out=
		fi
	fi
	emit "$CVE_ID NPU firmware check (dry run)"
	emit "Affected range: <= $CVE_MAX_VERSION"
	emit ""
	while IFS= read -r _dir; do
		[ -n "$_dir" ] || continue
		emit "scan dir: $_dir"
		while IFS= read -r _name; do
			[ -n "$_name" ] || continue
			emit "  $_dir/$_name"
		done <<EOF
$FIRMWARE_NAMES
EOF
	done <<EOF
$scan_dirs
EOF
	emit ""
	emit "No file was opened."
	exit 0
fi

command -v awk >/dev/null 2>&1 || die "awk is required"

if [ -n "$firmware_dir" ]; then
	[ -d "$firmware_dir" ] || die "not a directory: $firmware_dir"
elif [ -n "$rootfs" ]; then
	[ -d "$rootfs" ] || die "not a directory: $rootfs"
fi

if [ -n "$out" ]; then
	( : > "$out" ) 2>/dev/null || die "cannot write report: $out"
fi

emit "$CVE_ID NPU firmware check"
emit "Affected range: <= $CVE_MAX_VERSION"
emit ""

found=0
vulnerable=0
ok=0
unknown=0

_printed_dirs=
while IFS= read -r _dir; do
	[ -n "$_dir" ] || continue
	[ -d "$_dir" ] || continue
	case "|$_printed_dirs|" in
	*"|$_dir|"*)
		continue
		;;
	esac
	_printed_dirs="$_printed_dirs|$_dir"
	emit "Scan dir: $_dir"
done <<EOF
$scan_dirs
EOF

_seen=
while IFS= read -r _dir; do
	[ -n "$_dir" ] || continue
	[ -d "$_dir" ] || continue
	while IFS= read -r _name; do
		[ -n "$_name" ] || continue
		_file=$_dir/$_name
		[ -f "$_file" ] || continue
		_canon=$(readlink -f "$_file" 2>/dev/null) || _canon=$_file
		case "|$_seen|" in
		*"|$_canon|"*)
			continue
			;;
		esac
		_seen="$_seen|$_canon"
		check_file "$_file"
	done <<EOF
$FIRMWARE_NAMES
EOF
done <<EOF
$scan_dirs
EOF

emit ""
if [ "$found" -eq 0 ]; then
	emit "No candidate NPU firmware found in the scan dirs above."
	exit 1
fi

if [ "$vulnerable" -gt 0 ]; then
	_result=VULNERABLE-RANGE
elif [ "$ok" -gt 0 ]; then
	_result=OK
else
	_result=UNKNOWN
fi

emit "Result: $_result"
emit "Checked $found file(s): $vulnerable vulnerable, $ok ok, $unknown unknown."
