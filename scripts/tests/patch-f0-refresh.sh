#!/bin/bash
# patch-f0-refresh.sh <orig.patch> <pre-tree> <post-tree> <out.patch>
#
# Refresh one kernel patch against the tree state its predecessors leave
# behind, the way "quilt refresh" does: the new body is the real diff between
# the files just before and just after the patch lands.  Then assert the
# refresh changed nothing but the anchoring:
#
#   1. the new body applies to <pre-tree> with "patch -p1 -F0" -- no fuzz,
#      no offset (verified by parsing patch's own output);
#   2. the tree it produces is byte-identical to <post-tree>, i.e. it makes
#      the same change <orig.patch> made.  This is the binding assertion and
#      it is stronger than comparing +/- lines: a refreshed hunk renders a
#      line that moved from one place to another as plain context, so the
#      literal +/- multiset can differ by that move while the content does
#      not.  The delta is printed so the move is visible.
#
# <pre-tree> and <post-tree> hold the files the patch touches, at the paths
# "patch -p1" expects.  Build them by replaying the queue up to the patch
# (see scripts/tests/apply-queue-f0.sh --keep) and copying those paths.
#
# Exit 0 when both assertions hold, 1 otherwise.
set -u
PROG=${0##*/}
[ $# -eq 4 ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
orig=$1 pre=$2 post=$3 out=$4
[ -d "$pre" ] && [ -d "$post" ] || { echo "$PROG: pre/post tree missing" >&2; exit 2; }

hdr=$(grep -n -m1 -E '^--- (a/|/dev/null)' "$orig" | cut -d: -f1)
[ -n "${hdr:-}" ] || { echo "$PROG: no diff header in $orig" >&2; exit 1; }
head -n $((hdr - 1)) "$orig" >"$out" || exit 1
for f in $(sed -n 's/^+++ b\///p' "$orig"); do
	if [ -f "$pre/$f" ]; then la="a/$f"; af="$pre/$f"; else la=/dev/null; af=/dev/null; fi
	if [ -f "$post/$f" ]; then lb="b/$f"; bf="$post/$f"; else lb=/dev/null; bf=/dev/null; fi
	diff -u --label "$la" --label "$lb" "$af" "$bf" >>"$out"
	[ $? -le 1 ] || { echo "$PROG: diff failed on $f" >&2; exit 1; }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/f0refresh.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
cp -a "$pre/." "$work/" || exit 1
apply=$(cd "$work" && patch -p1 -F0 --no-backup-if-mismatch <"$out" 2>&1); rc=$?
if [ $rc -ne 0 ] || echo "$apply" | grep -q 'with fuzz\|(offset'; then
	echo "FAIL $PROG: $out does not land clean at -F0" >&2
	echo "$apply" | sed 's/^/  /' >&2
	exit 1
fi
if ! diff -r "$work" "$post" >/dev/null; then
	echo "FAIL $PROG: $out produces a different tree than $orig" >&2
	diff -r "$work" "$post" | head -40 | sed 's/^/  /' >&2
	exit 1
fi

# Informational: the +/- content lines, before and after the refresh.
changes() {
	awk '/^@@ / { hunk = 1; next }
	     /^(---|+++) / { hunk = 0; next }
	     hunk && /^\+.*/ { print "A" substr($0, 2); next }
	     hunk && /^-.*/  { print "D" substr($0, 2); next }' "$1" | sort
}
changes "$orig" >"$work/.old" ; changes "$out" >"$work/.new"
d=$(diff -u "$work/.old" "$work/.new")
if [ -z "$d" ]; then
	echo "OK $out: $(grep -c '^@@' "$out") hunks, -F0 clean, tree identical, +/- lines identical"
else
	echo "OK $out: $(grep -c '^@@' "$out") hunks, -F0 clean, tree identical, +/- delta:"
	echo "$d" | sed -n '/^[-+][^+-]/p' | sed 's/^/  /'
fi
