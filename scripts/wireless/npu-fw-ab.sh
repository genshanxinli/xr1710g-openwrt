#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# npu-fw-ab.sh - reversible A/B harness for the EN7581+MT7996 NPU firmware
# used by the XR1710G.
#
# The A/B compares the firmware installed on the board with a candidate image
# supplied by the operator (copy it to the board first; this script never
# downloads firmware).  The only file it replaces is
# /lib/firmware/airoha/en7581_MT7996_npu_rv32.bin, after saving the previous
# image and its hashes in a timestamped backup directory.  It never touches
# UBI volumes, the bootloader or partition data; the only system action is the
# reboot explicitly requested by --run --i-understand-reboot.
#
# Writes are restricted to the firmware directory (default
# /lib/firmware/airoha) and the backup root (default /root/npu-fw-ab).  The
# --firmware-dir and --backup-root options exist for host-side dry runs and
# tests; do not override them on the board.
#
# Typical session:
#   # scp candidate.bin root@board:/root/npu-fw-ab/MT7996-candidate.bin
#   npu-fw-ab.sh --inspect --candidate /root/npu-fw-ab/MT7996-candidate.bin
#   npu-fw-ab.sh --stage   --candidate /root/npu-fw-ab/MT7996-candidate.bin
#   npu-fw-ab.sh --run --i-understand-reboot
#   # ... board reboots ...
#   npu-fw-ab.sh --sample
#   npu-fw-ab.sh --restore                # back to the previous image
#
# The board must be rebooted for the NPU driver to load the new image: the
# script cannot sample after the reboot by itself, so --sample is a separate
# invocation, and it refuses to report a sample unless the boot id changed.
#
# Exit status:
#   0 - action completed (or dry run printed what would happen)
#   2 - invalid usage, a missing or unusable image, or an integrity check
#       that refused to proceed

set -u

PROG=${0##*/}
SELF=$0
# A printed rollback/sample command must still work after a reboot and after
# a change of directory, so use an absolute script path when possible.
case $SELF in
/*) ;;
*/*) SELF=${PWD:-.}/$SELF ;;
*)
	_resolved=$(command -v "$SELF" 2>/dev/null) && SELF=$_resolved
	;;
esac
FW_NAME=en7581_MT7996_npu_rv32.bin
DEFAULT_FW_DIR=/lib/firmware/airoha
DEFAULT_BACKUP_ROOT=/root/npu-fw-ab
VERSION_RE='TLB[0-9]+(\.[0-9]+)+(_v[0-9]+)?'

mode=
dry_run=0
understood=0
current=
current_explicit=0
candidate=
firmware_dir=$DEFAULT_FW_DIR
backup_root=$DEFAULT_BACKUP_ROOT
backup=
tmpfile=

usage() {
	cat <<EOF
Usage: $PROG [MODE] [options]

Reversible A/B harness for the Airoha EN7581+MT7996 NPU rv32 firmware.
Without a mode, --inspect is used.  No mode writes anything except --stage,
--restore and --run, and --run needs the explicit reboot acknowledgement.

Modes (choose one):
  --inspect            print path, size, SHA256, md5 and TLB version markers
                       of both images; reads only
  --stage              copy the current image to a timestamped backup, then
                       install the candidate; does not reboot
  --restore            restore a backup (newest by default) and verify that
                       the installed file is byte-identical to it
  --run                verify the staged A/B, print the rollback command,
                       then reboot; requires --i-understand-reboot
  --sample             after the reboot, capture the NPU version/dmesg
                       evidence and the installed image hash

Options:
  --candidate FILE     candidate image (required by --inspect and --stage;
                       \$NPU_FW_CANDIDATE is used when omitted)
  --current FILE       image to inspect (--inspect only; default is
                       FW_DIR/$FW_NAME)
  --firmware-dir DIR   firmware directory (default $DEFAULT_FW_DIR)
  --backup-root DIR    backup root (default $DEFAULT_BACKUP_ROOT)
  --backup DIR         use a specific backup directory (--restore, --run,
                       --sample; default is the newest under --backup-root)
  --i-understand-reboot
                       required by --run; the board will reboot
  --dry-run, -n        print what would be done, write nothing, never reboot
  -h, --help           show this help

Backups are stored as:
  \$BACKUP_ROOT/backup-UTCSTAMP/en7581_MT7996_npu_rv32.bin
  \$BACKUP_ROOT/backup-UTCSTAMP/manifest

Exit status: 0 ok, 2 usage/precondition error.
EOF
}

say() {
	printf '%s\n' "$*"
}

warn() {
	printf '%s: warning: %s\n' "$PROG" "$*" >&2
}

die() {
	printf '%s: error: %s\n' "$PROG" "$*" >&2
	exit 2
}

cleanup() {
	if [ -n "$tmpfile" ]; then
		rm -f "$tmpfile"
		tmpfile=
	fi
}

trap 'cleanup' 0

set_mode() {
	if [ -n "$mode" ] && [ "$mode" != "$1" ]; then
		die "only one mode may be selected (already --$mode)"
	fi
	mode=$1
}

need_value() {
	# $1 is the option name, $2 its prospective value.
	[ "$#" -ge 2 ] || die "option $1 requires a value"
	[ -n "$2" ] || die "option $1 requires a non-empty value"
}

sha256_of() {
	[ -f "$1" ] || return 1
	if command -v sha256sum >/dev/null 2>&1; then
		_sha_out=$(sha256sum "$1") || return 1
	elif command -v shasum >/dev/null 2>&1; then
		_sha_out=$(shasum -a 256 "$1") || return 1
	else
		return 1
	fi
	printf '%s\n' "${_sha_out%% *}"
}

md5_of() {
	[ -f "$1" ] || return 1
	if command -v md5sum >/dev/null 2>&1; then
		_md5_out=$(md5sum "$1") || return 1
		printf '%s\n' "${_md5_out%% *}"
	elif command -v md5 >/dev/null 2>&1; then
		md5 -q "$1"
	elif command -v openssl >/dev/null 2>&1; then
		_md5_out=$(openssl dgst -md5 "$1") || return 1
		printf '%s\n' "${_md5_out##* }"
	else
		return 1
	fi
}

size_of() {
	[ -f "$1" ] || return 1
	wc -c < "$1" | tr -d '[:space:]'
}

# Print every TLB version marker in the image, one per line.  The rv32 image
# carries strings such as TLB7.7.0.0_v08; the companion data image has none.
markers_of() {
	[ -f "$1" ] || return 1
	if command -v strings >/dev/null 2>&1; then
		strings -a "$1" | grep -E -o "$VERSION_RE" | sort -u
	else
		grep -a -o -E "$VERSION_RE" "$1" | sort -u
	fi
}

markers_line() {
	_mk=$(markers_of "$1")
	if [ -n "$_mk" ]; then
		printf '%s\n' "$_mk" | tr '\n' ' ' | sed 's/ *$//'
	else
		printf 'none'
	fi
}

shquote() {
	case $1 in
	*\'*)
		printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
		;;
	*[!A-Za-z0-9_./:@%+=-]*)
		printf "'%s'" "$1"
		;;
	*)
		printf '%s' "$1"
		;;
	esac
}

require_file() {
	[ -e "$1" ] || return 1
	[ -f "$1" ] || return 1
	[ -r "$1" ] || return 1
	return 0
}

show_image() {
	_img_label=$1
	_img_file=$2
	require_file "$_img_file" ||
		die "$_img_label image not found or not readable: $_img_file"

	_img_size=$(size_of "$_img_file") ||
		die "cannot read size of $_img_label image: $_img_file"
	_img_sha=$(sha256_of "$_img_file") ||
		die "cannot compute SHA256 of $_img_label image (sha256sum/shasum missing?)"

	say "$_img_label: $_img_file"
	say "  size:   $_img_size bytes"
	say "  sha256: $_img_sha"
	if _img_md5=$(md5_of "$_img_file"); then
		say "  md5:    $_img_md5"
	else
		say "  md5:    (md5sum/md5/openssl not available)"
	fi
	say "  version markers:"
	_img_markers=$(markers_of "$_img_file")
	if [ -n "$_img_markers" ]; then
		printf '%s\n' "$_img_markers" | sed 's/^/    /'
	else
		say "    (no TLB version marker found)"
	fi
}

manifest_get() {
	# $1 manifest file, $2 key.  Values are read literally; the manifest is
	# never sourced, so a crafted value cannot execute code.
	[ -f "$1" ] || return 1
	sed -n "s/^$2=//p" "$1" | head -n 1
}

resolve_backup() {
	if [ -n "$backup" ]; then
		[ -d "$backup" ] || die "backup directory not found: $backup"
		printf '%s\n' "$backup"
		return 0
	fi
	[ -d "$backup_root" ] || die "backup root not found: $backup_root"
	_latest=
	for _d in "$backup_root"/backup-*; do
		[ -d "$_d" ] || continue
		_latest=$_d
	done
	[ -n "$_latest" ] || die "no backup found under $backup_root"
	printf '%s\n' "$_latest"
}

inspect() {
	[ -n "$candidate" ] ||
		die "--inspect requires --candidate FILE (or \$NPU_FW_CANDIDATE)"
	require_file "$current" ||
		die "current image not found or not readable: $current"

	show_image "current" "$current"
	say ""
	show_image "candidate" "$candidate"
	say ""

	_cur_sha=$(sha256_of "$current")
	_can_sha=$(sha256_of "$candidate")
	if [ "$_cur_sha" = "$_can_sha" ]; then
		say "identity: current and candidate have the same SHA256; staging would be a no-op"
	else
		say "identity: current and candidate differ"
	fi
	say "current version:   $(markers_line "$current")"
	say "candidate version: $(markers_line "$candidate")"
}

stage() {
	[ -n "$candidate" ] ||
		die "--stage requires --candidate FILE (or \$NPU_FW_CANDIDATE)"
	require_file "$candidate" ||
		die "candidate image not found or not readable: $candidate"

	_target=$firmware_dir/$FW_NAME
	require_file "$_target" ||
		die "current image not found or not readable: $_target"
	[ -d "$firmware_dir" ] ||
		die "firmware directory not found: $firmware_dir"
	[ -L "$_target" ] &&
		die "refusing to replace a symlink: $_target"
	[ -w "$firmware_dir" ] ||
		die "firmware directory is not writable: $firmware_dir (run as root)"

	_cur_sha=$(sha256_of "$_target") ||
		die "cannot compute SHA256 of current image: $_target"
	_can_sha=$(sha256_of "$candidate") ||
		die "cannot compute SHA256 of candidate: $candidate"
	[ "$_cur_sha" = "$_can_sha" ] &&
		die "candidate is identical to the current image; nothing to stage"
	_cur_size=$(size_of "$_target") ||
		die "cannot read size of current image: $_target"
	_can_size=$(size_of "$candidate") ||
		die "cannot read size of candidate: $candidate"
	_cur_ver=$(markers_line "$_target")
	_can_ver=$(markers_line "$candidate")

	# Staging on top of a previously staged candidate is still a valid
	# backup of the current state, but the newest rollback then returns to
	# that candidate.  Warn so the stock image is not mistaken for it.
	for _m in "$backup_root"/backup-*/manifest; do
		[ -f "$_m" ] || continue
		_prev_cand=$(manifest_get "$_m" candidate_sha256)
		if [ -n "$_prev_cand" ] && [ "$_prev_cand" = "$_cur_sha" ]; then
			warn "current image is the candidate recorded in ${_m%/manifest}; this stage backs up that candidate, not the stock image (run --restore --backup <dir> first to keep the stock rollback point)"
			break
		fi
	done

	_stamp=$(date -u +%Y%m%dT%H%M%SZ) ||
		die "cannot create a backup timestamp"
	_bdir_base=$backup_root/backup-$_stamp
	_bdir=$_bdir_base
	_n=0
	while [ -e "$_bdir" ]; do
		_n=$((_n + 1))
		[ "$_n" -le 100 ] ||
			die "cannot find a free backup directory name under $backup_root"
		_bdir=$_bdir_base-$_n
	done
	if [ -d "$backup_root" ] && [ -L "$backup_root" ]; then
		die "refusing to use a symlinked backup root: $backup_root"
	fi

	if [ "$dry_run" = 1 ]; then
		say "dry-run: would create $_bdir"
		say "dry-run: would copy $_target ($_cur_sha, $_cur_size bytes) there"
		say "dry-run: would verify backup SHA256 against current SHA256 ($_cur_sha)"
		say "dry-run: would install $candidate ($_can_sha, $_can_size bytes) as $_target"
		say "dry-run: would verify the installed image against the candidate SHA256"
		say "dry-run: would not reboot"
		return 0
	fi

	umask 022
	mkdir -p "$backup_root" ||
		die "cannot create backup root: $backup_root"
	chmod 700 "$backup_root" 2>/dev/null || true
	mkdir "$_bdir" ||
		die "cannot create backup directory: $_bdir"
	chmod 700 "$_bdir" 2>/dev/null || true

	cp -p "$_target" "$_bdir/$FW_NAME" || {
		rm -rf "$_bdir"
		die "cannot copy current image to backup: $_bdir/$FW_NAME"
	}

	_backup_sha=$(sha256_of "$_bdir/$FW_NAME") || {
		rm -rf "$_bdir"
		die "cannot compute SHA256 of the backup copy"
	}
	if [ "$_backup_sha" != "$_cur_sha" ]; then
		rm -rf "$_bdir"
		die "backup SHA256 $_backup_sha does not match current image SHA256 $_cur_sha; nothing was installed"
	fi

	{
		printf 'created=%s\n' "$_stamp"
		printf 'firmware=%s\n' "$FW_NAME"
		printf 'current_path=%s\n' "$_target"
		printf 'current_size=%s\n' "$_cur_size"
		printf 'current_sha256=%s\n' "$_cur_sha"
		printf 'current_version=%s\n' "$_cur_ver"
		printf 'candidate_path=%s\n' "$candidate"
		printf 'candidate_size=%s\n' "$_can_size"
		printf 'candidate_sha256=%s\n' "$_can_sha"
		printf 'candidate_version=%s\n' "$_can_ver"
	} > "$_bdir/manifest" || {
		die "backup is at $_bdir but its manifest could not be written; nothing was installed"
	}
	chmod 600 "$_bdir/manifest" 2>/dev/null || true

	tmpfile=$firmware_dir/.$FW_NAME.ab.$$
	cp "$candidate" "$tmpfile" || {
		rm -f "$tmpfile"
		tmpfile=
		die "cannot copy candidate into $firmware_dir; the current image is unchanged"
	}
	chmod 0644 "$tmpfile" 2>/dev/null || true

	_tmp_sha=$(sha256_of "$tmpfile") || {
		rm -f "$tmpfile"
		tmpfile=
		die "cannot verify the copied candidate; the current image is unchanged"
	}
	if [ "$_tmp_sha" != "$_can_sha" ]; then
		rm -f "$tmpfile"
		tmpfile=
		die "copied candidate hash $_tmp_sha does not match $_can_sha; the current image is unchanged"
	fi

	mv -f "$tmpfile" "$_target" || {
		rm -f "$tmpfile"
		tmpfile=
		die "cannot install the candidate over $_target"
	}
	tmpfile=

	_installed_sha=$(sha256_of "$_target") || {
		die "candidate installed but its SHA256 could not be verified"
	}
	[ "$_installed_sha" = "$_can_sha" ] || {
		die "installed image SHA256 $_installed_sha does not match the candidate $_can_sha"
	}

	say "backup:    $_bdir"
	say "  image:   $_bdir/$FW_NAME"
	say "  sha256:  $_backup_sha"
	say "installed: $candidate"
	say "  target:  $_target"
	say "  sha256:  $_installed_sha"
	say "  version: $_can_ver"
	say ""
	say "No reboot was performed.  Next: $PROG --run --i-understand-reboot"
	_stage_rollback="$(shquote "$SELF") --restore --backup $(shquote "$_bdir")"
	if [ "$firmware_dir" != "$DEFAULT_FW_DIR" ]; then
		_stage_rollback="$_stage_rollback --firmware-dir $(shquote "$firmware_dir")"
	fi
	say "Rollback without testing: $_stage_rollback"
}

restore() {
	_bdir=$(resolve_backup) || exit 2
	_manifest=$_bdir/manifest
	[ -f "$_manifest" ] ||
		die "no manifest in $_bdir; refusing to restore without integrity data"

	_origin_sha=$(manifest_get "$_manifest" current_sha256)
	_origin_size=$(manifest_get "$_manifest" current_size)
	_candidate_sha=$(manifest_get "$_manifest" candidate_sha256)
	[ -n "$_origin_sha" ] ||
		die "manifest in $_bdir has no current_sha256; refusing to restore"
	[ -n "$_origin_size" ] ||
		die "manifest in $_bdir has no current_size; refusing to restore"

	_bfile=$_bdir/$FW_NAME
	require_file "$_bfile" ||
		die "backup image not found or not readable: $_bfile"
	_bsha=$(sha256_of "$_bfile") ||
		die "cannot compute SHA256 of the backup image: $_bfile"
	_bsize=$(size_of "$_bfile") ||
		die "cannot read size of the backup image: $_bfile"

	if [ "$_bsha" != "$_origin_sha" ]; then
		die "backup SHA256 $_bsha does not match the recorded original $_origin_sha; refusing to restore"
	fi
	if [ "$_bsize" != "$_origin_size" ]; then
		die "backup size $_bsize does not match the recorded original $_origin_size; refusing to restore"
	fi

	_target=$firmware_dir/$FW_NAME
	[ -d "$firmware_dir" ] ||
		die "firmware directory not found: $firmware_dir"
	[ -L "$_target" ] &&
		die "refusing to replace a symlink: $_target"
	[ -w "$firmware_dir" ] ||
		die "firmware directory is not writable: $firmware_dir (run as root)"

	_cur_sha=
	if require_file "$_target"; then
		_cur_sha=$(sha256_of "$_target") || _cur_sha=
	fi

	say "backup:  $_bfile"
	say "  sha256: $_bsha (matches the recorded original)"
	say "current: $_target"
	if [ -n "$_cur_sha" ]; then
		say "  sha256: $_cur_sha"
		if [ -n "$_candidate_sha" ] && [ "$_cur_sha" = "$_candidate_sha" ]; then
			say "  state:  the staged candidate is installed"
		elif [ "$_cur_sha" = "$_origin_sha" ]; then
			say "  state:  already the original image"
		else
			warn "current image is neither the original nor the staged candidate"
		fi
	else
		say "  (missing)"
	fi

	if [ "$_cur_sha" = "$_origin_sha" ]; then
		say "already restored; no write needed"
		if [ "$dry_run" != 1 ]; then
			rm -f "$_bdir/pending-sample"
		fi
		return 0
	fi

	if [ "$dry_run" = 1 ]; then
		say "dry-run: would copy $_bfile to $_target and verify its SHA256"
		return 0
	fi

	tmpfile=$firmware_dir/.$FW_NAME.ab.$$
	cp -p "$_bfile" "$tmpfile" || {
		rm -f "$tmpfile"
		tmpfile=
		die "cannot copy the backup image into $firmware_dir"
	}
	_tmp_sha=$(sha256_of "$tmpfile") || {
		rm -f "$tmpfile"
		tmpfile=
		die "cannot verify the copied backup image"
	}
	if [ "$_tmp_sha" != "$_origin_sha" ]; then
		rm -f "$tmpfile"
		tmpfile=
		die "copied backup hash $_tmp_sha does not match the recorded original $_origin_sha"
	fi
	mv -f "$tmpfile" "$_target" || {
		rm -f "$tmpfile"
		tmpfile=
		die "cannot restore the backup over $_target"
	}
	tmpfile=

	_installed_sha=$(sha256_of "$_target") ||
		die "backup restored but its SHA256 could not be verified"
	[ "$_installed_sha" = "$_origin_sha" ] || {
		die "restored image SHA256 $_installed_sha does not match the recorded original $_origin_sha"
	}
	if command -v cmp >/dev/null 2>&1; then
		cmp -s "$_bfile" "$_target" ||
			die "restored image is not byte-identical to the backup"
	fi
	rm -f "$_bdir/pending-sample"

	say "restored: $_target"
	say "  sha256: $_installed_sha (byte-identical to the backup)"
	say "Reboot for the NPU driver to load the restored image again."
}

run() {
	[ "$understood" = 1 ] ||
		die "--run refuses to reboot without --i-understand-reboot"

	_bdir=$(resolve_backup) || exit 2
	_manifest=$_bdir/manifest
	[ -f "$_manifest" ] ||
		die "no manifest in $_bdir; run --stage first"

	_origin_sha=$(manifest_get "$_manifest" current_sha256)
	_candidate_sha=$(manifest_get "$_manifest" candidate_sha256)
	_candidate_ver=$(manifest_get "$_manifest" candidate_version)
	[ -n "$_origin_sha" ] ||
		die "manifest in $_bdir has no current_sha256; refusing to run"
	[ -n "$_candidate_sha" ] ||
		die "manifest in $_bdir has no candidate_sha256; re-run --stage"

	_bfile=$_bdir/$FW_NAME
	require_file "$_bfile" ||
		die "backup image not found or not readable: $_bfile"
	_bsha=$(sha256_of "$_bfile") ||
		die "cannot compute SHA256 of the backup image: $_bfile"
	if [ "$_bsha" != "$_origin_sha" ]; then
		die "backup SHA256 $_bsha does not match the recorded original $_origin_sha; refusing to run"
	fi

	_target=$firmware_dir/$FW_NAME
	require_file "$_target" ||
		die "current image not found or not readable: $_target"
	_cur_sha=$(sha256_of "$_target") ||
		die "cannot compute SHA256 of the current image: $_target"
	if [ "$_cur_sha" != "$_candidate_sha" ]; then
		die "the staged candidate is not installed (current SHA256 $_cur_sha, candidate $_candidate_sha); run --stage first"
	fi

	_rollback="$(shquote "$SELF") --restore --backup $(shquote "$_bdir")"
	_sample="$(shquote "$SELF") --sample --backup $(shquote "$_bdir")"
	if [ "$firmware_dir" != "$DEFAULT_FW_DIR" ]; then
		_rollback="$_rollback --firmware-dir $(shquote "$firmware_dir")"
		_sample="$_sample --firmware-dir $(shquote "$firmware_dir")"
	fi

	say "Rollback command (run after boot if the candidate must be reverted):"
	say "  $_rollback"
	say ""
	say "backup:    $_bfile"
	say "  sha256:  $_bsha (matches the recorded original)"
	say "staged:    $_target"
	say "  sha256:  $_cur_sha (matches the recorded candidate)"
	say "  version: ${_candidate_ver:-none}"

	if [ "$dry_run" = 1 ]; then
		say ""
		say "dry-run: would write $_bdir/pending-sample and reboot; not rebooting"
		return 0
	fi

	[ "$(id -u)" = 0 ] ||
		die "--run must be executed as root"
	command -v reboot >/dev/null 2>&1 ||
		die "reboot command not found"

	_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) ||
		_boot_id=unknown
	{
		printf 'staged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'boot_id_before=%s\n' "$_boot_id"
		printf 'candidate_sha256=%s\n' "$_candidate_sha"
		printf 'candidate_version=%s\n' "$_candidate_ver"
		printf 'target=%s\n' "$_target"
	} > "$_bdir/pending-sample" ||
		die "cannot write the post-boot marker in $_bdir; not rebooting"
	chmod 600 "$_bdir/pending-sample" 2>/dev/null || true

	say ""
	say "Rebooting in 5 seconds.  After the board is back, run:"
	say "  $_sample"
	sync
	sleep 5
	reboot
}

sample_body() {
	printf 'Post-boot NPU firmware sample at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'kernel: %s\n' "$(uname -r 2>/dev/null || printf 'unknown')"
	if [ -r /proc/uptime ]; then
		printf 'uptime: %s seconds\n' "$(cut -d' ' -f1 /proc/uptime)"
	fi
	printf 'boot id: %s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown')"
	printf '\n'

	_target=$firmware_dir/$FW_NAME
	if require_file "$_target"; then
		_sha=$(sha256_of "$_target") || _sha=unknown
		_size=$(size_of "$_target") || _size=unknown
		printf 'firmware: %s\n' "$_target"
		printf '  size:   %s bytes\n' "$_size"
		printf '  sha256: %s\n' "$_sha"
		if [ "$_sha" = "$_candidate_sha" ]; then
			printf '  staged candidate: MATCH\n'
		else
			printf '  staged candidate: MISMATCH (expected %s)\n' "$_candidate_sha"
		fi
		printf '  version markers: %s\n' "$(markers_line "$_target")"
	else
		printf 'firmware: %s (missing)\n' "$_target"
	fi
	printf '\n'

	printf 'dmesg NPU lines:\n'
	_dmesg=$(dmesg 2>/dev/null | grep -i -E 'npu.*version|version.*npu|mt7996.*npu|airoha-npu' | tail -n 30) || _dmesg=
	if [ -n "$_dmesg" ]; then
		printf '%s\n' "$_dmesg" | sed 's/^/  /'
	elif command -v dmesg >/dev/null 2>&1; then
		printf '  (no matching lines; dmesg may be restricted)\n'
	else
		printf '  (dmesg not available)\n'
	fi
	printf '\n'

	printf 'PPE bind (first lines, if readable):\n'
	_bind=$(head -n 8 /sys/kernel/debug/ppe/bind 2>/dev/null) || _bind=
	if [ -n "$_bind" ]; then
		printf '%s\n' "$_bind" | sed 's/^/  /'
	else
		printf '  (not readable)\n'
	fi
}

sample() {
	_bdir=$(resolve_backup) || exit 2
	_pending=$_bdir/pending-sample
	[ -f "$_pending" ] ||
		die "no pending boot sample in $_bdir; start one with --run --i-understand-reboot"

	_before=$(manifest_get "$_pending" boot_id_before)
	_candidate_sha=$(manifest_get "$_pending" candidate_sha256)
	[ -n "$_candidate_sha" ] ||
		die "pending marker in $_bdir has no candidate_sha256; re-run --stage and --run"
	_now=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || _now=
	[ -n "$_now" ] ||
		die "cannot read /proc/sys/kernel/random/boot_id; cannot prove that a reboot happened"
	if [ -n "$_before" ] && [ "$_before" != unknown ] && [ "$_before" = "$_now" ]; then
		die "boot id is unchanged ($_now); reboot the board and run --sample afterwards"
	fi

	_text=$(sample_body)
	printf '%s\n' "$_text"
	say ""

	if [ "$dry_run" = 1 ]; then
		say "dry-run: would write the sample to $_bdir and clear the pending marker"
		return 0
	fi

	_report=$_bdir/post-boot-$(date -u +%Y%m%dT%H%M%SZ).txt
	printf '%s\n' "$_text" > "$_report" ||
		die "cannot write the post-boot report: $_report"
	chmod 600 "$_report" 2>/dev/null || true
	mv -f "$_pending" "$_bdir/post-boot.done" ||
		die "sample written to $_report but the pending marker could not be cleared"
	say "report: $_report"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
	case $1 in
	--inspect) set_mode inspect ;;
	--stage) set_mode stage ;;
	--restore) set_mode restore ;;
	--run) set_mode run ;;
	--sample) set_mode sample ;;
	--i-understand-reboot) understood=1 ;;
	--dry-run|-n) dry_run=1 ;;
	--current)
		need_value "$@"
		current=$2
		current_explicit=1
		shift
		;;
	--candidate)
		need_value "$@"
		candidate=$2
		shift
		;;
	--firmware-dir)
		need_value "$@"
		firmware_dir=$2
		shift
		;;
	--backup-root)
		need_value "$@"
		backup_root=$2
		shift
		;;
	--backup)
		need_value "$@"
		backup=$2
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		die "unknown option: $1 (try --help)"
		;;
	*)
		die "unexpected argument: $1 (try --help)"
		;;
	esac
	shift
done

[ "$#" -eq 0 ] || die "unexpected argument: $1 (try --help)"

[ -n "$mode" ] || mode=inspect
[ -n "$candidate" ] || candidate=${NPU_FW_CANDIDATE:-}
[ -n "$current" ] || current=$firmware_dir/$FW_NAME

[ "$firmware_dir" != / ] || die "--firmware-dir must not be /"
[ "$backup_root" != / ] || die "--backup-root must not be /"

if [ "$current_explicit" = 1 ] && [ "$mode" != inspect ]; then
	die "--current is only valid with --inspect; use --firmware-dir for the other modes"
fi
if [ "$understood" = 1 ] && [ "$mode" != run ]; then
	die "--i-understand-reboot is only valid with --run"
fi
case $mode in
restore|run|sample) ;;
*)
	[ -z "$backup" ] || die "--backup is only valid with --restore, --run or --sample"
	;;
esac

case $mode in
inspect) inspect ;;
stage) stage ;;
restore) restore ;;
run) run ;;
sample) sample ;;
*) die "unknown mode: $mode" ;;
esac
