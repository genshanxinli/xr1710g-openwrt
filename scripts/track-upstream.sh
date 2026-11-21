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
# README.md records the measurement as one <!-- upstream-record: ... --> line
# instead of prose no build can contradict. --check turns that line into an
# assertion: the recorded ancestor/merge-base/mirror-tree facts are recomputed
# from the refs and a mismatch is exit 1. Moving counters (tips, ahead/behind)
# are deliberately NOT recorded there - they change with every upstream push -
# they are the table this script prints and the numbers quoted in issue #189.
#
# Usage: scripts/track-upstream.sh [options]
#   --fetch            git fetch --prune REMOTE first; without it the report is
#                      computed from the refs as they are (offline, repeatable)
#   --local REF        local branch/ref to compare against (default: HEAD)
#   --remote REMOTE    remote whose refs/remotes/REMOTE/* are read (default: upstream)
#   --track "A B ..."  upstream branches to report (default: "kernel73 kernel74 main")
#   --mirror REF       local mirror of upstream/kernel73 (default: origin/kernel73)
#   --check            verify the README record against the refs; 0 match,
#                      1 stale, 2 not enough refs to judge (prints the fix)
#   --static           with --check: verify only the record's shape and that its
#                      constants match this script's defaults; needs no refs,
#                      which is what a shallow CI checkout can do
#   --record           print a README record line for the refs as they are now
#   --quiet            print only the verdict line
#   -h, --help         this text

set -eu

REMOTE=upstream
LOCAL=HEAD
TRACK="kernel73 kernel74 main"
MIRROR=origin/kernel73
FETCH=0
QUIET=0
CHECK=0
STATIC=0
RECORD=0
RECFILE=README.md
DEFECT=0

usage() {
	sed -n '2,/^set -eu$/p' "$0" | sed -e '/^set -eu$/d' -e 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case $1 in
	--fetch) FETCH=1 ;;
	--local) LOCAL=${2:?--local needs a ref}; shift ;;
	--remote) REMOTE=${2:?--remote needs a name}; shift ;;
	--track) TRACK=${2:?--track needs a branch list}; shift ;;
	--mirror) MIRROR=${2:?--mirror needs a ref}; shift ;;
	--check) CHECK=1 ;;
	--static) CHECK=1; STATIC=1 ;;
	--record) RECORD=1 ;;
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

record_line() { sed -n 's/.*<!-- *upstream-record: *\(.*\) *-->.*/\1/p' "$RECFILE" | head -n 1; }
record_get() { printf '%s\n' "$REC_FIELDS" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1; }

# Shape and constants only: no refs, so a shallow checkout can run it. A record
# that describes a different comparison cannot be checked against these refs.
record_static() {
	REC_FIELDS=$(record_line)
	if [ -z "$REC_FIELDS" ]; then
		echo "track-upstream: $RECFILE has no <!-- upstream-record: ... --> line" >&2
		return 1
	fi
	for k in checked merge_base ancestor mirror_tree branches mirror local; do
		case " $REC_FIELDS " in
		*" $k="*) ;;
		*) echo "track-upstream: record is missing $k=" >&2; DEFECT=1 ;;
		esac
	done
	if ! printf '%s' "$(record_get checked)" | grep -Eqx '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
		echo "track-upstream: record checked= is not YYYY-MM-DD" >&2
		DEFECT=1
	fi
	case $(record_get ancestor) in
	yes | no) ;;
	*) echo "track-upstream: record ancestor= must be yes or no" >&2; DEFECT=1 ;;
	esac
	case $(record_get mirror_tree) in
	identical | different | unknown) ;;
	*) echo "track-upstream: record mirror_tree= must be identical|different|unknown" >&2; DEFECT=1 ;;
	esac
	[ "$(record_get branches)" = "$(printf '%s' "$TRACK" | tr ' ' ',')" ] ||
		{ echo "track-upstream: record branches= disagrees with the --track default ($TRACK)" >&2; DEFECT=1; }
	[ "$(record_get mirror)" = "$MIRROR" ] ||
		{ echo "track-upstream: record mirror= disagrees with the --mirror default ($MIRROR)" >&2; DEFECT=1; }
	[ "$(record_get local)" = "$LOCAL" ] ||
		{ echo "track-upstream: record local= disagrees with the --local default ($LOCAL)" >&2; DEFECT=1; }
	[ "$DEFECT" = 0 ]
}

# The three facts in the record that a commit cannot quietly change. Tips and
# ahead/behind are not among them: they move with every upstream push.
record_facts() {
	umirror="refs/remotes/$REMOTE/kernel73"
	if ! has_ref "$umirror"; then
		echo "track-upstream: cannot judge the record: missing $umirror (run with --fetch)" >&2
		exit 2
	fi
	act_anc=no
	git merge-base --is-ancestor "$umirror" "$LOCAL_SHA" 2>/dev/null && act_anc=yes
	act_mb=$(git merge-base "$umirror" "$LOCAL_SHA" 2>/dev/null || true)
	if [ -n "$act_mb" ]; then act_mb=$(short "$act_mb"); else act_mb=-; fi
	if has_ref "$MIRROR"; then
		if git diff --quiet "$umirror" "$MIRROR" 2>/dev/null; then
			act_tree=identical
		else
			act_tree=different
		fi
	else
		act_tree=unknown
	fi
}

if [ "$STATIC" = 1 ]; then
	record_static || {
		echo "verdict: record malformed" >&2
		exit 1
	}
	say "record  $RECFILE shape ok; constants match --track/--mirror/--local"
	say "verdict: record in sync (static)"
	exit 0
fi

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

if [ "$CHECK" = 1 ]; then
	record_static || {
		echo "verdict: record malformed" >&2
		exit 1
	}
	record_facts
	bad=0
	expect() {
		rec=$(record_get "$1")
		[ "$rec" = "$2" ] || {
			echo "track-upstream: record says $1=$rec, refs say $1=$2" >&2
			bad=1
		}
	}
	expect ancestor "$act_anc"
	expect merge_base "$act_mb"
	expect mirror_tree "$act_tree"
	if [ "$bad" = 1 ]; then
		say "  refresh that one README line with: scripts/track-upstream.sh --record"
		say "  (the moving tips and ahead/behind stay in issue #189, not in README)"
		say "verdict: record stale"
		exit 1
	fi
	say "record  $RECFILE: ancestor=$act_anc merge_base=$act_mb mirror_tree=$act_tree"
	say "verdict: record in sync"
	exit 0
fi

if [ "$RECORD" = 1 ]; then
	record_facts
	printf '<!-- upstream-record: checked=%s merge_base=%s ancestor=%s mirror_tree=%s branches=%s mirror=%s local=%s -->\n' \
		"$(date +%F)" "$act_mb" "$act_anc" "$act_tree" \
		"$(printf '%s' "$TRACK" | tr ' ' ',')" "$MIRROR" "$LOCAL"
	exit 0
fi

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
