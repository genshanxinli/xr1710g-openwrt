#!/bin/bash
# apply-queue-f0.sh - audit an OpenWrt kernel patch queue for fuzz-free application.
#
# The build applies each queue directory through scripts/patch-kernel.sh, which
# passes "-f" to patch.  "-f" only means "do not ask questions"; it does not
# turn off fuzz, so GNU patch still accepts a hunk that matched with fuzz 2.
# A queue that "applies" can therefore still land two lines away from where it
# was written (issue #275).  This script re-extracts the kernel tree and asks,
# patch by patch, whether "patch -p1 -F0" would take it at the exact position
# in the file the previous patches left behind.
#
# Order is the order include/quilt.mk uses (generic backport, generic pending,
# generic hack, platform patches) and inside each directory the shell glob
# order patch-kernel.sh sees.  Nothing here touches the network.
#
# usage:
#   apply-queue-f0.sh <repo-root> [--ver 7.3] [--tarball FILE] [--tree DIR]
#                                 [--workroot DIR] [--keep] [--verbose]
#
#   <repo-root>   checkout that holds target/linux
#   --ver V       kernel patch version: dirs backport-V, pending-V, hack-V,
#                 target/linux/airoha/patches-V (default 7.3)
#   --tarball F   kernel tarball to extract (default <repo-root>/dl/linux-V.tar.xz)
#   --tree DIR    audit an already extracted pristine tree instead of extracting
#   --workroot D  parent for the fresh extraction (default
#                 $HOME/projects/.scratch); never /tmp, a kernel tree does not
#                 fit in a tmpfs
#   --keep        keep the extracted tree and print its path
#   --verbose     also print patch's own output for every non-zero offset
#
# Output: one line per patch "<name> ok|fuzz-needed", then
#   TOTAL ok=N fuzz=M offset_max=K
# Exit status 0 only when no patch needs fuzz and every patch applied.
#
# How it measures: every patch is first tried with --dry-run -F0 against the
# tree state the earlier patches produced.  If that succeeds it is applied with
# -F0, so the next patch sees the same tree the build would have.  If it
# fails, the patch is applied with the build's default fuzz before moving on,
# otherwise every following patch would be measured against a tree the build
# never reaches.
set -u

PROG=${0##*/}
die() { echo "$PROG: $*" >&2; exit 2; }

REPO=""
VER=7.3
TARBALL=""
TREE=""
WORKROOT="${HOME}/projects/.scratch"
KEEP=0
VERBOSE=0

while [ $# -gt 0 ]; do
	case "$1" in
	--ver) VER=$2; shift 2 ;;
	--tarball) TARBALL=$2; shift 2 ;;
	--tree) TREE=$2; shift 2 ;;
	--workroot) WORKROOT=$2; shift 2 ;;
	--keep) KEEP=1; shift ;;
	--verbose) VERBOSE=1; shift ;;
	-h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) die "unknown option $1" ;;
	*) [ -z "$REPO" ] || die "unexpected argument $1"; REPO=$1; shift ;;
	esac
done

[ -n "$REPO" ] || die "<repo-root> is required"
[ -d "$REPO/target/linux" ] || die "$REPO/target/linux is not a directory"
REPO=$(cd "$REPO" && pwd) || die "cannot resolve $REPO"
TARBALL_DIR=$REPO/dl

DIRS="target/linux/generic/backport-$VER target/linux/generic/pending-$VER \
target/linux/generic/hack-$VER target/linux/airoha/patches-$VER"
n=0
for d in $DIRS; do
	[ -e "$REPO/$d" ] || die "missing queue directory $d"
	[ -n "$(echo "$REPO/$d"/*.patch 2>/dev/null)" ] || die "no patches in $d"
	n=$((n + $(echo "$REPO/$d"/*.patch | wc -w)))
done
echo "# queue $VER: $n patches in $(echo $DIRS | wc -w) directories"

RM_TREE=0
if [ -z "$TREE" ]; then
	[ -n "$TARBALL" ] || TARBALL="$TARBALL_DIR/linux-$VER.tar.xz"
	[ -f "$TARBALL" ] || die "no tarball at $TARBALL (pass --tarball)"
	case "${WORKROOT%/}" in
	/tmp|/tmp/*|/dev/shm|/dev/shm/*) die "WORKROOT $WORKROOT is a tmpfs; a kernel tree does not fit there" ;;
	esac
	mkdir -p "$WORKROOT" || die "cannot create $WORKROOT"
	WORK=$WORKROOT/f0-$VER-$$
	mkdir -p "$WORK" || die "cannot create $WORK"
	tar -xf "$TARBALL" -C "$WORK" || die "cannot extract $TARBALL"
	TOP=$(ls -1 "$WORK")
	[ -n "$TOP" ] && [ -d "$WORK/$TOP" ] || die "unexpected tarball layout in $TARBALL"
	TREE="$WORK/$TOP"
	RM_TREE=1
fi
cd "$TREE" || die "cannot cd to $TREE"
[ -e Makefile ] && [ -d drivers ] || die "$TREE does not look like a kernel tree"

cleanup() {
	[ "$RM_TREE" = 1 ] && [ "$KEEP" = 0 ] && rm -rf "$WORK"
}
trap cleanup EXIT

ok=0 fuzz=0 offset_max=0 applied=0 failed=0
for d in $DIRS; do
	for p in "$REPO/$d"/*.patch; do
		name=$(basename "$p")
		out=$(patch -p1 -f -F0 --dry-run --no-backup-if-mismatch <"$p" 2>&1)
		rc=$?
		if [ $rc -eq 0 ]; then
			ok=$((ok + 1))
			echo "$name ok"
			applied=$((applied + 1))
			# -f keeps patch from asking, -F0 keeps it from guessing.
			patch -p1 -f -F0 --no-backup-if-mismatch <"$p" >/dev/null 2>&1 || {
				echo "$PROG: $name passed -F0 dry-run but failed to apply" >&2
				failed=$((failed + 1))
			}
		else
			fuzz=$((fuzz + 1))
			echo "$name fuzz-needed"
			[ "$VERBOSE" = 1 ] && echo "$out" | sed 's/^/#   /'
			applied=$((applied + 1))
			# Same command the build runs, so the next patch is measured
			# against the tree the build actually reaches.
			patch -p1 -f --no-backup-if-mismatch <"$p" >/dev/null 2>&1 || {
				echo "$PROG: $name needs fuzz and does not apply even with it" >&2
				failed=$((failed + 1))
			}
		fi
		# Offset of the hunks that did apply: a non-zero offset means the
		# hunk landed somewhere else in the file even without fuzz.
		for o in $(echo "$out" |
			sed -n 's/.*(offset \(-\{0,1\}\)[0-9]\+ lines).*/\1/p' | head -40); do
			o=${o#-}
			[ "${o:-0}" -gt "$offset_max" ] && offset_max=$o
		done
	done
done

echo "TOTAL ok=$ok fuzz=$fuzz offset_max=$offset_max"
[ "$KEEP" = 1 ] && echo "# tree kept at $TREE"

if [ "$fuzz" -ne 0 ] || [ "$failed" -ne 0 ]; then
	exit 1
fi
exit 0
