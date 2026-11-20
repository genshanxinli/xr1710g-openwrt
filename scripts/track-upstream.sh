#!/bin/sh
#
# track-upstream.sh - read-only drift report against the fork parent.
#
# Issue #189 asks for the fork parent (OpenWRT-fanboy/OpenW1700k) to be
# tracked. This is the tracking half only: resolve the upstream refs, print
# tips, merge-base and ahead/behind for a few branches, and say whether the
# local kernel73 mirror is still byte-identical to upstream/kernel73. It never
# writes a ref, a branch, an index entry or a work-tree file.
#
# Why there is no automatic sync here: upstream force-pushes kernel73,
# kernel74, ubi2, snapshot, w1701k and failsafe2 (same subjects, new SHAs), so
# a pin recorded last week stops meaning anything and a scheduled merge would
# replay rewritten history on top of 400+ local commits. The merge stays a
# human call; this script and the weekly workflow only make the drift visible.
#
# Exit status is the whole point, and "unknown" is deliberately not "behind":
#   0  in sync   - every tracked upstream branch is contained in --local and
#                  the kernel73 mirror has the same tree as upstream
#   1  drift     - something is behind or the mirror content differs
#   2  unknown   - upstream refs absent/unreadable, no merge-base, fetch failed
# A cron run that cannot see upstream must not look like a clean run, and a
# branch that is behind must not look like a broken checkout.
#
# Usage: scripts/track-upstream.sh [options]
#   --fetch            git fetch --prune REMOTE first; without it the report is
#                      computed from the refs as they are (offline, repeatable)
#   --local REF        local branch/ref to compare against (default: HEAD)
#   --remote REMOTE    remote whose refs/remotes/REMOTE/* are read (default: upstream)
#   --track "A B ..."  upstream branches to report (default: "kernel73 kernel74 main")
#   --mirror REF       local mirror of upstream/kernel73 (default: origin/kernel73)
#   --quiet            print only the verdict line
#   -h, --help         this text

set -eu

REMOTE=upstream
LOCAL=HEAD
TRACK="kernel73 kernel74 main"
MIRROR=origin/kernel73
FETCH=0
QUIET=0

usage() {
	sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case $1 in
	--fetch) FETCH=1 ;;
	--local) LOCAL=${2:?--local needs a ref}; shift ;;
	--remote) REMOTE=${2:?--remote needs a name}; shift ;;
	--track) TRACK=${2:?--track needs a branch list}; shift ;;
	--mirror) MIRROR=${2:?--mirror needs a ref}; shift ;;
	--quiet) QUIET=1 ;;
	-h | --help) usage; exit 0 ;;
	*)
		echo "track-upstream: unknown argument: $1 (try --help)" >&2
		exit 2
		;;
	esac
	shift
done

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
short() { printf '%s' "$1" | cut -c1-10; }
when() { git log -1 --format=%cs "$1" 2>/dev/null || printf '?'; }
has_ref() { git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

git rev-parse --git-dir >/dev/null 2>&1 || {
	echo "track-upstream: not inside a git checkout" >&2
	exit 2
}

if [ "$FETCH" = 1 ]; then
	if ! git fetch --prune --quiet "$REMOTE" 2>/dev/null; then
		echo "track-upstream: git fetch $REMOTE failed" >&2
		exit 2
	fi
fi

LOCAL_SHA=$(git rev-parse --verify --quiet "$LOCAL^{commit}" 2>/dev/null) || {
	echo "track-upstream: cannot resolve --local $LOCAL" >&2
	exit 2
}

resolved=0
drift=0
unknown=0

say "upstream $REMOTE vs $LOCAL = $(short "$LOCAL_SHA") ($(when "$LOCAL_SHA"))"
say ""
say "branch        upstream      tip-date    merge-base    behind  ahead  state"

for b in $TRACK; do
	ref="refs/remotes/$REMOTE/$b"
	if ! has_ref "$ref"; then
		# A branch upstream deleted is a real signal, not a missing ref.
		say "$(printf '%-13s %-13s %-11s %-13s %6s %6s  %s' \
			"$b" - - - - - gone)"
		drift=1
		continue
	fi
	resolved=$((resolved + 1))
	us=$(git rev-parse "$ref^{commit}")
	if ! mb=$(git merge-base "$ref" "$LOCAL_SHA" 2>/dev/null); then
		say "$(printf '%-13s %-13s %-11s %-13s %6s %6s  %s' \
			"$b" "$(short "$us")" "$(when "$us")" - - - unrelated)"
		unknown=1
		continue
	fi
	behind=$(git rev-list --count "$LOCAL_SHA..$ref")
	ahead=$(git rev-list --count "$ref..$LOCAL_SHA")
	state=in-sync
	if [ "$behind" -gt 0 ]; then
		state=behind
		drift=1
	fi
	say "$(printf '%-13s %-13s %-11s %-13s %6s %6s  %s' \
		"$b" "$(short "$us")" "$(when "$us")" "$(short "$mb")" \
		"$behind" "$ahead" "$state")"
done

# kernel73 is meant to be a content mirror of upstream/kernel73 (README), so
# compare trees rather than SHAs: equal trees is the byte-identical property.
say ""
umirror="refs/remotes/$REMOTE/kernel73"
if has_ref "$umirror" && has_ref "$MIRROR"; then
	resolved=$((resolved + 1))
	us=$(git rev-parse "$umirror^{commit}")
	ms=$(git rev-parse "$MIRROR^{commit}")
	behind=$(git rev-list --count "$ms..$umirror")
	ahead=$(git rev-list --count "$umirror..$ms")
	if git diff --quiet "$umirror" "$MIRROR" 2>/dev/null; then
		mstate="IDENTICAL (tree $(short "$(git rev-parse "$umirror^{tree}")"))"
	else
		files=$(git diff --name-only "$umirror" "$MIRROR" | wc -l | tr -d ' ')
		mstate="DIFFERENT ($files files)"
		drift=1
	fi
	say "mirror  $MIRROR = $(short "$ms") vs upstream/kernel73 = $(short "$us"): $ahead ahead / $behind behind, $mstate"
else
	say "mirror  $MIRROR vs upstream/kernel73: UNKNOWN (missing ref)"
	unknown=1
fi

say ""
if [ "$resolved" -eq 0 ]; then
	say "verdict: unknown - no refs/remotes/$REMOTE/*; run with --fetch"
	exit 2
fi
if [ "$unknown" -eq 1 ]; then
	say "verdict: unknown - cannot judge every branch above"
	exit 2
fi
if [ "$drift" -eq 1 ]; then
	say "verdict: drift"
	exit 1
fi
say "verdict: in-sync"
exit 0
