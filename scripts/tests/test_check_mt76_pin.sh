#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Offline cases for scripts/check-mt76-pin.sh (issue #9).
#
# The script answers one question -- "should this tree move its mt76 pin?" --
# and the answer is a verdict plus an exit status.  Every case here builds a
# throw-away upstream repository and a throw-away pin file, so the case fixes
# the *decision*, not a date that drifts under it:
#
#   keep      upstream has not moved past the pin, or moved by less than the
#             quiet window (< MT76_BUMP_MIN_COMMITS)
#   bump      upstream is >= MT76_BUMP_MIN_COMMITS ahead; re-anchoring the
#             local patches is a known cost, not a blocker
#   blocked   no upstream data, the pin is not in upstream history (rewritten),
#             or the local patch set is larger than MT76_LOCAL_PATCH_LIMIT, so
#             "bump" is not a one-command change
#
# Exit status must match the verdict: 0 keep, 1 bump, 2 blocked.  A silent
# "keep" when upstream is unreadable is the failure this contract prevents.
#
# Usage: scripts/tests/test_check_mt76_pin.sh

set -u

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="${MT76_PIN_CHECK_UNDER_TEST:-$REPO_ROOT/scripts/check-mt76-pin.sh}"

FAILED=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	FAILED=1
}

ok() {
	printf 'ok   %s\n' "$1"
}

[ -f "$SCRIPT" ] || {
	fail "$SCRIPT is missing"
	printf 'check-mt76-pin cases failed\n' >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_CONFIG_NOSYSTEM=1
export HOME="$WORK/home"
mkdir -p "$HOME"

# upstream_pin_plus N: a synthetic upstream whose first commit (2026-10-08) is
# the pin, followed by N commits dated one day apart.  Echoes "PIN_SHA TIP_SHA".
upstream_pin_plus() {
	n=$1
	repo="$WORK/up-$n"
	rm -rf "$repo"
	git init -q -b main "$repo" || return 1
	git -C "$repo" config user.name t
	git -C "$repo" config user.email t@t
	GIT_COMMITTER_DATE='2026-10-08T00:00:00+0000' \
		git -C "$repo" commit -q --allow-empty -m pin \
		--date '2026-10-08T00:00:00+0000' --author 't <t@t>'
	i=0
	while [ "$i" -lt "$n" ]; do
		i=$((i + 1))
		d=$((8 + i))
		GIT_COMMITTER_DATE="$(printf '2026-10-%02dT00:00:00+0000' "$d")" \
			git -C "$repo" commit -q --allow-empty -m "c$i" \
			--date "$(printf '2026-10-%02dT00:00:00+0000' "$d")" \
			--author 't <t@t>'
	done
	pin=$(git -C "$repo" rev-list --max-parents=0 HEAD)
	tip=$(git -C "$repo" rev-parse HEAD)
	printf '%s %s\n' "$pin" "$tip"
}

write_pin() {
	file=$1
	date=$2
	sha=$3
	mkdir -p "$(dirname "$file")"
	cat >"$file" <<EOF
PKG_SOURCE_URL:=https://github.com/OpenWRT-fanboy/mt76-firmware
PKG_SOURCE_PROTO:=git
PKG_SOURCE_DATE:=$date
PKG_SOURCE_VERSION:=$sha
EOF
}

# run_case NAME EXPECT_RC EXPECT_VERDICT ENV=value...
# Prints the verdict line the script produced, then the whole output.
run_case() {
	name=$1
	want_rc=$2
	want_verdict=$3
	shift 3
	OUT=$(env "$@" sh "$SCRIPT" 2>&1)
	RC=$?
	v=$(printf '%s\n' "$OUT" | awk '$1 == "verdict" { print $2; exit }')
	printf '%-16s rc=%s verdict=%s\n' "$name" "$RC" "$v"
	printf '%s\n' "$OUT"
	[ "$RC" = "$want_rc" ] || fail "$name: rc=$RC, wanted $want_rc; output: $OUT"
	[ "$v" = "$want_verdict" ] || fail "$name: verdict '$v', wanted '$want_verdict'"
}

# --- fixtures ----------------------------------------------------------------

PATCHES="$WORK/patches"
mkdir -p "$PATCHES"
for i in 1 2 3; do : >"$PATCHES/900$i-local.patch"; done

read -r pin _ <<EOF
$(upstream_pin_plus 0)
EOF

# --- 1: pin is the tip -> keep (rc 0) ----------------------------------------

PIN_AT_TIP="$WORK/pin-at-tip"
write_pin "$PIN_AT_TIP" 2026-10-08 "$pin"
run_case pin-is-tip 0 keep \
	MT76_PIN_FILE="$PIN_AT_TIP" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-0" MT76_UPSTREAM_REF=main
printf '%s\n' "$OUT" | grep -q '^behind.commits *0$' ||
	fail "pin-is-tip: behind.commits is not 0; output: $OUT"
printf '%s\n' "$OUT" | grep -q '^local.patches *3$' ||
	fail "pin-is-tip: local.patches is not 3; output: $OUT"

# --- 2: quiet drift (3 commits) -> keep (rc 0) --------------------------------

read -r pin3 _ <<EOF
$(upstream_pin_plus 3)
EOF
PIN_QUIET="$WORK/pin-quiet"
write_pin "$PIN_QUIET" 2026-10-08 "$pin3"
run_case quiet-drift 0 keep \
	MT76_PIN_FILE="$PIN_QUIET" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-3" MT76_UPSTREAM_REF=main
printf '%s\n' "$OUT" | grep -q '^behind.commits *3$' ||
	fail "quiet-drift: behind.commits is not 3; output: $OUT"

# --- 3: 12 commits behind -> bump (rc 1) --------------------------------------

read -r pin12 _ <<EOF
$(upstream_pin_plus 12)
EOF
PIN_DRIFT="$WORK/pin-drift"
write_pin "$PIN_DRIFT" 2026-10-08 "$pin12"
run_case drift-12 1 bump \
	MT76_PIN_FILE="$PIN_DRIFT" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-12" MT76_UPSTREAM_REF=main
printf '%s\n' "$OUT" | grep -q '^behind.commits *12$' ||
	fail "drift-12: behind.commits is not 12; output: $OUT"
printf '%s\n' "$OUT" | grep -q '^behind.days *12$' ||
	fail "drift-12: behind.days is not 12; output: $OUT"

# --- 3b: pin on a side branch that main never took -> blocked (rc 2) ----------

# A pin can be the tip of a release branch while the default branch kept its
# own history: the commit count across the two is not an "ahead" count.
SIDE="$WORK/up-side"
rm -rf "$SIDE"
git init -q -b main "$SIDE"
git -C "$SIDE" config user.name t
git -C "$SIDE" config user.email t@t
GIT_COMMITTER_DATE='2026-10-07T00:00:00+0000' git -C "$SIDE" commit -q --allow-empty \
	-m base --date '2026-10-07T00:00:00+0000' --author 't <t@t>'
git -C "$SIDE" checkout -q -b rel
GIT_COMMITTER_DATE='2026-10-08T00:00:00+0000' git -C "$SIDE" commit -q --allow-empty \
	-m 'release firmware' --date '2026-10-08T00:00:00+0000' --author 't <t@t>'
side_pin=$(git -C "$SIDE" rev-parse HEAD)
git -C "$SIDE" checkout -q main
for i in 1 2 3 4 5; do
	GIT_COMMITTER_DATE="2026-10-1$i"T00:00:00+0000 git -C "$SIDE" commit -q --allow-empty \
		-m "m$i" --date "2026-10-1$i"T00:00:00+0000 --author 't <t@t>'
done
PIN_SIDE="$WORK/pin-side"
write_pin "$PIN_SIDE" 2026-10-08 "$side_pin"
run_case pin-on-side-branch 2 blocked \
	MT76_PIN_FILE="$PIN_SIDE" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$SIDE" MT76_UPSTREAM_REF=main
printf '%s\n' "$OUT" | grep -q '^pin.branches *rel' ||
	fail "pin-on-side-branch: pin.branches does not name the release branch; output: $OUT"
printf '%s\n' "$OUT" | grep -q '^diverged.commits *5$' ||
	fail "pin-on-side-branch: diverged.commits is not 5; output: $OUT"
printf '%s\n' "$OUT" | grep -q 'lineage switch' ||
	fail "pin-on-side-branch: reason does not say why the count is not a bump"
# the same pin against the branch that does contain it is a clean comparison
run_case pin-on-side-branch-rel 0 keep \
	MT76_PIN_FILE="$PIN_SIDE" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$SIDE" MT76_UPSTREAM_REF=rel
printf '%s\n' "$OUT" | grep -q '^behind.commits *0$' ||
	fail "pin-on-side-branch-rel: behind.commits is not 0; output: $OUT"

# --- 4: pin sha not in upstream history -> blocked (rc 2) ---------------------

PIN_REWRITTEN="$WORK/pin-rewritten"
write_pin "$PIN_REWRITTEN" 2026-10-08 1111111111111111111111111111111111111111
run_case pin-rewritten 2 blocked \
	MT76_PIN_FILE="$PIN_REWRITTEN" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-12" MT76_UPSTREAM_REF=main

# --- 5: patch set over the re-anchor budget -> blocked (rc 2) -----------------

BIG="$WORK/patches-big"
mkdir -p "$BIG"
i=0
while [ "$i" -lt 51 ]; do
	i=$((i + 1))
	: >"$BIG/9$i-big.patch"
done
run_case patch-budget 2 blocked \
	MT76_PIN_FILE="$PIN_DRIFT" MT76_PATCH_DIR="$BIG" \
	MT76_UPSTREAM_REPO="$WORK/up-12" MT76_UPSTREAM_REF=main
printf '%s\n' "$OUT" | grep -q '^local.patches *51$' ||
	fail "patch-budget: local.patches is not 51; output: $OUT"

# --- 6: no upstream repository -> blocked (rc 2) ------------------------------

run_case no-upstream 2 blocked \
	MT76_PIN_FILE="$PIN_DRIFT" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/does-not-exist" MT76_UPSTREAM_REF=main

# --- 7: the real tree: pin, patch count and a verdict are always reported -----

OUT=$(sh "$SCRIPT" --offline 2>&1)
RC=$?
printf '%-16s rc=%s verdict=%s\n' real-tree "$RC" \
	"$(printf '%s\n' "$OUT" | awk '$1 == "verdict" { print $2; exit }')"
case "$RC" in
0 | 1 | 2) ;;
*) fail "real-tree: rc=$RC is not one of 0/1/2; output: $OUT" ;;
esac
printf '%s\n' "$OUT" | grep -q '^pin.date *20' ||
	fail "real-tree: no pin.date; output: $OUT"
printf '%s\n' "$OUT" | grep -q '^local.patches *[0-9]' ||
	fail "real-tree: no local.patches; output: $OUT"

# --- 8: --help is a usage screen, not a run -----------------------------------

if sh "$SCRIPT" --help >/dev/null 2>&1; then
	ok "--help exits 0"
else
	fail "--help exits non-zero"
fi

[ "$FAILED" = 0 ] || {
	printf 'check-mt76-pin cases failed\n' >&2
	exit 1
}
printf 'all check-mt76-pin cases passed\n'
