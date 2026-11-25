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

# row_is KEY VALUE MESSAGE: the script prints "%-16s %s" rows, so one literal
# padded line is the whole assertion.  grep -F keeps a mktemp path's '.' and
# '*' from being read as a pattern.
row_is() {
	printf '%s\n' "$OUT" | grep -qF "$(printf '%-16s %s' "$1" "$2")" ||
		fail "$3; output: $OUT"
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
sh "$SCRIPT" --help 2>&1 | grep -qF 'mirror.moved' ||
	fail "--help does not document the mirror.moved row"
sh "$SCRIPT" --help 2>&1 | grep -qF 'unknown' ||
	fail "--help does not document the unknown value"

# --- 9: mirror.moved -- the reader is allowed to be the thing that stopped ---
#
# The default reader is the fork mirror in PKG_SOURCE_URL, which is frozen on
# purpose (it is the reproducible source of the pin).  A check that fired by
# default would therefore turn every default-path run into "blocked", so the
# reader audit is opt-in: MT76_MIRROR_REF names the reader that is supposed to
# move.  The judgement is commit ancestry against the pin sha (yes / no /
# unknown), not a date: up-0's only commit is byte-identical to the pin commit
# (same tree, author, message and date, so the same sha), which is a proven
# "no" -- "keep" would be a claim nobody measured.

run_case mirror-default 0 keep \
	MT76_PIN_FILE="$PIN_AT_TIP" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-0" MT76_UPSTREAM_REF=main
printf '%s\n' "$OUT" | grep -q '^mirror.moved *unknown$' ||
	fail "mirror-default: an unset MT76_MIRROR_REF must not audit a reader; output: $OUT"

run_case mirror-parked 2 blocked \
	MT76_PIN_FILE="$PIN_QUIET" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-3" MT76_UPSTREAM_REF=main \
	MT76_MIRROR_REF="$WORK/up-0"
printf '%s\n' "$OUT" | grep -q '^mirror.moved *no$' ||
	fail "mirror-parked: mirror.moved is not no; output: $OUT"
printf '%s\n' "$OUT" | grep -q '^mirror.date *2026-10-08$' ||
	fail "mirror-parked: mirror.date does not name the day the reader stopped; output: $OUT"
printf '%s\n' "$OUT" | grep -q '^behind.commits *3$' ||
	fail "mirror-parked: the upstream comparison itself must still be reported; output: $OUT"
printf '%s\n' "$OUT" | grep -q 'keep is not evidence' ||
	fail "mirror-parked: reason does not say why keep was withdrawn; output: $OUT"

# the same reader once it is moving again: keep stands
run_case mirror-advancing 0 keep \
	MT76_PIN_FILE="$PIN_QUIET" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-3" MT76_UPSTREAM_REF=main \
	MT76_MIRROR_REF=main
printf '%s\n' "$OUT" | grep -q '^mirror.moved *yes$' ||
	fail "mirror-advancing: mirror.moved is not yes; output: $OUT"

# an unreadable reader ref is unknown, never a silent "no"
run_case mirror-typo 0 keep \
	MT76_PIN_FILE="$PIN_QUIET" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-3" MT76_UPSTREAM_REF=main \
	MT76_MIRROR_REF=no-such-branch
printf '%s\n' "$OUT" | grep -q '^mirror.moved *unknown$' ||
	fail "mirror-typo: an unreadable reader must be unknown; output: $OUT"

# --- 9b: same calendar day, different sha --------------------------------
#
# The original predicate compared %cs: a reader whose tip lands on the pin's
# day was called parked even when it carried later commits.  That is the real
# shape of the mt76 reader (pin 46b67e5b and upstream main 0936617d are both
# 2026-10-28 and 8 commits apart), so it is the case the sha test must catch.
SAME="$WORK/up-sameday"
rm -rf "$SAME"
git init -q -b main "$SAME"
git -C "$SAME" config user.name t
git -C "$SAME" config user.email t@t
GIT_COMMITTER_DATE='2026-10-07T00:00:00+0000' git -C "$SAME" commit -q --allow-empty \
	-m base --date '2026-10-07T00:00:00+0000' --author 't <t@t>'
same_base=$(git -C "$SAME" rev-parse HEAD)
GIT_COMMITTER_DATE='2026-10-08T00:00:00+0000' git -C "$SAME" commit -q --allow-empty \
	-m pin --date '2026-10-08T00:00:00+0000' --author 't <t@t>'
same_pin=$(git -C "$SAME" rev-parse HEAD)
git -C "$SAME" branch at-pin "$same_pin"
git -C "$SAME" branch behind "$same_base"
git -C "$SAME" branch rewritten "$same_base"
git -C "$SAME" checkout -q rewritten
GIT_COMMITTER_DATE='2026-10-08T00:00:00+0000' git -C "$SAME" commit -q --allow-empty \
	-m rewritten --date '2026-10-08T00:00:00+0000' --author 't <t@t>'
git -C "$SAME" checkout -q main
GIT_COMMITTER_DATE='2026-10-08T00:00:00+0000' git -C "$SAME" commit -q --allow-empty \
	-m same-day --date '2026-10-08T00:00:00+0000' --author 't <t@t>'
PIN_SAME="$WORK/pin-same"
write_pin "$PIN_SAME" 2026-10-08 "$same_pin"

# one commit past the pin, committed the same day: the reader moved
run_case mirror-same-day 0 keep \
	MT76_PIN_FILE="$PIN_SAME" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$SAME" MT76_UPSTREAM_REF=main \
	MT76_MIRROR_REF=main
printf '%s\n' "$OUT" | grep -q '^mirror.moved *yes$' ||
	fail "mirror-same-day: a tip one commit past the pin must be yes even on the pin's day; output: $OUT"

# the reader tip is the pin itself: proven parked, keep withdrawn
run_case mirror-at-pin 2 blocked \
	MT76_PIN_FILE="$PIN_SAME" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$SAME" MT76_UPSTREAM_REF=main \
	MT76_MIRROR_REF=at-pin
printf '%s\n' "$OUT" | grep -q '^mirror.moved *no$' ||
	fail "mirror-at-pin: a reader tip equal to the pin is no; output: $OUT"
printf '%s\n' "$OUT" | grep -q 'keep is not evidence' ||
	fail "mirror-at-pin: reason does not say why keep was withdrawn; output: $OUT"

# the reader stops before the pin: still proven parked
run_case mirror-behind 2 blocked \
	MT76_PIN_FILE="$PIN_SAME" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$SAME" MT76_UPSTREAM_REF=main \
	MT76_MIRROR_REF=behind
printf '%s\n' "$OUT" | grep -q '^mirror.moved *no$' ||
	fail "mirror-behind: a reader tip that is an ancestor of the pin is no; output: $OUT"

# a rewritten reader on a sibling lineage: nothing was compared
run_case mirror-diverged 0 keep \
	MT76_PIN_FILE="$PIN_SAME" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$SAME" MT76_UPSTREAM_REF=main \
	MT76_MIRROR_REF=rewritten
printf '%s\n' "$OUT" | grep -q '^mirror.moved *unknown$' ||
	fail "mirror-diverged: a reader that shares no lineage with the pin must be unknown; output: $OUT"

# a separate reader repo that does not contain the pin commit at all:
# ancestry cannot be proved either way, so mirror.moved stays unknown and
# keep stands (rc 0).
MISSING_PIN="$WORK/mirror-missing-pin"
rm -rf "$MISSING_PIN"
git init -q -b main "$MISSING_PIN"
git -C "$MISSING_PIN" config user.name t
git -C "$MISSING_PIN" config user.email t@t
GIT_COMMITTER_DATE='2026-10-12T00:00:00+0000' git -C "$MISSING_PIN" commit -q --allow-empty \
	-m 'unrelated-mirror' --date '2026-10-12T00:00:00+0000' --author 't <t@t>'
run_case mirror-missing-pin 0 keep \
	MT76_PIN_FILE="$PIN_SAME" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$SAME" MT76_UPSTREAM_REF=main \
	MT76_MIRROR_REF="$MISSING_PIN"
printf '%s\n' "$OUT" | grep -q '^mirror.moved *unknown$' ||
	fail "mirror-missing-pin: a separate reader repo without the pin commit must be unknown; output: $OUT"

# --- 10: blocked.by -- a real count of commits this tree cannot absorb -------

write_pin_blocked() {
	write_pin "$1" "$2" "$3"
	printf 'PKG_MIRROR_BLOCKED_BY:=cfg80211_scs_desc, cfg80211_dscp_to_up\n' >>"$1"
}

PIN_BLOCKED_QUIET="$WORK/pin-blocked-quiet"
write_pin_blocked "$PIN_BLOCKED_QUIET" 2026-10-08 "$pin3"
# below the bump threshold the symbol list is a note, not a verdict
run_case blocked-by-keep 0 keep \
	MT76_PIN_FILE="$PIN_BLOCKED_QUIET" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-3" MT76_UPSTREAM_REF=main
printf '%s\n' "$OUT" | grep -q '^blocked.by *cfg80211_scs_desc,cfg80211_dscp_to_up$' ||
	fail "blocked-by-keep: blocked.by is not the normalised list; output: $OUT"

PIN_BLOCKED_DRIFT="$WORK/pin-blocked-drift"
write_pin_blocked "$PIN_BLOCKED_DRIFT" 2026-10-08 "$pin12"
# 12 commits ahead would be "bump", but acting on it means writing those
# symbols into a kernel this tree does not have: blocked, with the count.
run_case blocked-by-bump 2 blocked \
	MT76_PIN_FILE="$PIN_BLOCKED_DRIFT" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-12" MT76_UPSTREAM_REF=main
printf '%s\n' "$OUT" | grep -q '^behind.commits *12$' ||
	fail "blocked-by-bump: behind.commits is not 12; output: $OUT"
printf '%s\n' "$OUT" | grep -q '^reason *upstream needs 2 cfg80211/nl80211 symbols' ||
	fail "blocked-by-bump: reason does not name the missing symbols; output: $OUT"

# --- 11: the cache this verdict read is named, not implied -------------------
#
# Two local caches are in play in this tree (mt76-upstream.git and
# mt76-openwrt.git), and each answers a different question.  A "keep" from one
# cache and a "backlog" from the other must never look like a contradiction,
# so the verdict row has to sit next to the exact repo, ref, origin and age it
# was computed from.
#
git -C "$WORK/up-3" remote add origin https://example.invalid/mt76-upstream.git \
	2>/dev/null || true

run_case cache-provenance 0 keep \
	MT76_PIN_FILE="$PIN_QUIET" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-3" MT76_UPSTREAM_REF=main
row_is cache.repo "$WORK/up-3" \
	"cache-provenance: cache.repo does not name the repo that was read"
row_is cache.ref main \
	"cache-provenance: cache.ref does not name the ref that was read"
row_is cache.origin https://example.invalid/mt76-upstream.git \
	"cache-provenance: cache.origin does not name the remote"
row_is cache.source env \
	"cache-provenance: cache.source does not say how the path was chosen"
row_is cache.mode offline \
	"cache-provenance: cache.mode does not say whether a fetch happened"
printf '%s\n' "$OUT" | grep -q '^cache.fetched *20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]$' ||
	fail "cache-provenance: cache.fetched is not a date; output: $OUT"
printf '%s\n' "$OUT" | grep -q '^cache.age.days *[0-9][0-9]*$' ||
	fail "cache-provenance: cache.age.days is not a number; output: $OUT"

# the same cache selected with --repo is labelled differently from the env var
OUT=$(env MT76_PIN_FILE="$PIN_QUIET" MT76_PATCH_DIR="$PATCHES" \
	sh "$SCRIPT" --repo "$WORK/up-3" --ref main 2>&1)
RC=$?
printf '%-16s rc=%s verdict=%s\n' cache-flag "$RC" \
	"$(printf '%s\n' "$OUT" | awk '$1 == "verdict" { print $2; exit }')"
printf '%s\n' "$OUT"
[ "$RC" = 0 ] || fail "cache-flag: rc=$RC, wanted 0; output: $OUT"
row_is cache.source flag \
	"cache-flag: --repo must be labelled flag, not env/default"

# a cache with no origin remote says none instead of an empty row
run_case cache-no-origin 0 keep \
	MT76_PIN_FILE="$PIN_AT_TIP" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$WORK/up-0" MT76_UPSTREAM_REF=main
row_is cache.origin none \
	"cache-no-origin: an origin-less cache must say none"

# --- 12: an empty --repo and a cache dated in the future ---------------------
#
# Two provenance labels that used to lie: --repo "" fell back to the default
# path while still printing cache.source flag, and a cache file stamped after
# "now" printed a negative cache.age.days where mt76-pin-age.py clamps the
# same number to 0.

OUT=$(env MT76_PIN_FILE="$PIN_QUIET" MT76_PATCH_DIR="$PATCHES" \
	sh "$SCRIPT" --offline --repo "" 2>&1)
RC=$?
printf '%-16s rc=%s verdict=%s\n' cache-empty-repo "$RC" \
	"$(printf '%s\n' "$OUT" | awk '$1 == "verdict" { print $2; exit }')"
printf '%s\n' "$OUT"
case "$RC" in
0 | 1 | 2) ;;
*) fail "cache-empty-repo: rc=$RC is not one of 0/1/2; output: $OUT" ;;
esac
row_is cache.source default \
	"cache-empty-repo: --repo \"\" must be labelled default, not flag"

# A cache file dated in the future: clock skew or a shared cache, not a
# negative age.  The fixture is small on purpose -- one commit at the pin.
FUTURE="$WORK/up-future"
rm -rf "$FUTURE"
git init -q -b main "$FUTURE"
git -C "$FUTURE" config user.name t
git -C "$FUTURE" config user.email t@t
GIT_COMMITTER_DATE='2026-10-08T00:00:00+0000' git -C "$FUTURE" commit -q --allow-empty \
	-m pin --date '2026-10-08T00:00:00+0000' --author 't <t@t>'
touch -t 203001010000 "$FUTURE/.git/refs/heads/main"
future_pin=$(git -C "$FUTURE" rev-parse HEAD)
PIN_FUTURE="$WORK/pin-future"
write_pin "$PIN_FUTURE" 2026-10-08 "$future_pin"
run_case cache-future-mtime 0 keep \
	MT76_PIN_FILE="$PIN_FUTURE" MT76_PATCH_DIR="$PATCHES" \
	MT76_UPSTREAM_REPO="$FUTURE" MT76_UPSTREAM_REF=main
row_is cache.age.days 0 \
	"cache-future-mtime: a future-dated cache is 0 days old, not negative"

[ "$FAILED" = 0 ] || {
	printf 'check-mt76-pin cases failed\n' >&2
	exit 1
}
printf 'all check-mt76-pin cases passed\n'
