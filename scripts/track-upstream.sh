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
#   --gate-branch B    branch the sync verdict is measured on (default: the
#                      branch matching target/linux/airoha/an7581/target.mk's
#                      KERNEL_PATCHVER, else the first --track entry)
#   --verdict          print ok|review|must-act for the gate branch and exit
#                      0 ok / 1 review / 2 must-act / 3 unknown.  These codes
#                      belong to this mode only; the drift report below keeps
#                      0 in-sync / 1 drift / 2 unknown.  Axes are commits
#                      behind, files differing from the gate tip, and pending
#                      commits touching the paths the fork actually builds.
#   --list-hot         print the pending hot-path commits and exit
#   --review-behind N  --act-behind N   commit thresholds (default 100 / 400)
#   --review-files N   --act-files N    file thresholds   (default 400 / 1200)
#   --review-hot N     --act-hot N      hot-commit thresholds (default 25 / 80)
#   --check            verify the README record against the refs; 0 match,
#                      1 stale, 2 not enough refs to judge (prints the fix)
#   --strict-drift     with --check/--static: exit 1 when the record matches
#                      reality but the reality it records is a drift
#                      (ancestor=no or mirror_tree=different).  Off by default:
#                      README.md records the drift on purpose, so a default
#                      failure would be permanently red until a sync #189 calls
#                      infeasible.  CI that wants drift to fail opts in.
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
GATE=
# Triage thresholds, measured on 2026-11-21: the fork is ~880-883 commits and
# ~2800 files behind upstream, after four weeks without an absorption, and
# ~110 of the missing commits touch the paths this fork actually builds.
# review fires at roughly three days of upstream churn (100 commits / 400
# files), must-act at roughly two weeks (400 / 1200).  The hot-commit axis is
# the actionable one: it is the list a human has to cherry-pick, and it is
# what makes `must-act` mean "schedule the pick session", not "rebase".
REVIEW_BEHIND=100
ACT_BEHIND=400
REVIEW_FILES=400
ACT_FILES=1200
REVIEW_HOT=25
ACT_HOT=80
HOT_PATHS="target/linux/airoha target/linux/generic/pending-7.3 target/linux/generic/pending-7.4 package/kernel/mac80211 package/kernel/mt76 package/firmware/linux-firmware tools/npu-firmware"
FETCH=0
QUIET=0
CHECK=0
STATIC=0
STRICT_DRIFT=0
RECORD=0
VERDICT=0
LISTHOT=0
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
	--gate-branch) GATE=${2:?--gate-branch needs a branch}; shift ;;
	--verdict) VERDICT=1 ;;
	--list-hot) LISTHOT=1 ;;
	--review-behind) REVIEW_BEHIND=${2:?--review-behind needs a number}; shift ;;
	--act-behind) ACT_BEHIND=${2:?--act-behind needs a number}; shift ;;
	--review-files) REVIEW_FILES=${2:?--review-files needs a number}; shift ;;
	--act-files) ACT_FILES=${2:?--act-files needs a number}; shift ;;
	--review-hot) REVIEW_HOT=${2:?--review-hot needs a number}; shift ;;
	--act-hot) ACT_HOT=${2:?--act-hot needs a number}; shift ;;
	--check) CHECK=1 ;;
	--strict-drift) STRICT_DRIFT=1 ;;
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

# --check asserts the record, not the tree.  A record that says ancestor=no /
# mirror_tree=different is *accurate* while the tree is drifted, and README.md
# documents that state on purpose.  Only --strict-drift turns a recorded drift
# into exit 1, so CI decides; the wording never claims the tree is in sync.
#
# --static compares nothing: it has no refs.  Saying "matches reality" there
# would report a shape check as a verified comparison, and --static is the only
# path CI runs.  It says what it did: the record is well formed, and here is
# the drift it records.
#   $1 mode: check|static   $2 drift 0/1   $3 ancestor   $4 mirror_tree
record_verdict() {
	if [ "$1" = check ]; then
		if [ "$2" = 1 ]; then
			say "verdict: record matches reality (drift recorded: ancestor=$3 mirror_tree=$4)"
			if [ "$STRICT_DRIFT" = 1 ]; then
				exit 1
			fi
			exit 0
		fi
		say "verdict: record matches reality (no drift recorded)"
		exit 0
	fi
	if [ "$2" = 1 ]; then
		say "verdict: record shape ok (static; drift recorded: ancestor=$3 mirror_tree=$4)"
		if [ "$STRICT_DRIFT" = 1 ]; then
			exit 1
		fi
		exit 0
	fi
	say "verdict: record shape ok (static; no drift recorded)"
	exit 0
}

if [ "$STATIC" = 1 ]; then
	record_static || {
		echo "verdict: record malformed" >&2
		exit 1
	}
	static_drift=0
	if [ "$(record_get ancestor)" = no ] || [ "$(record_get mirror_tree)" = different ]; then
		static_drift=1
	fi
	say "record  $RECFILE shape ok; constants match --track/--mirror/--local"
	record_verdict static "$static_drift" "$(record_get ancestor)" "$(record_get mirror_tree)"
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

# The branch a sync verdict is measured on is the one the target actually
# builds, not the oldest tracked branch: an7581 flipped to KERNEL_PATCHVER 7.4
# on 2026-11-20 while the README record still names kernel73.  Reading the
# pin keeps the verdict honest across that kind of flip without editing the
# record (which --static would then reject).
gate_branch() {
	if [ -n "$GATE" ]; then
		printf '%s\n' "$GATE"
		return
	fi
	# Read from the checkout root, not the caller's cwd: the pin file decides
	# which upstream branch the device builds, and a run from scripts/ must
	# not silently fall back to the first --track entry.
	top=$(git rev-parse --show-toplevel 2>/dev/null) || top=.
	pv=$(sed -n 's/^KERNEL_PATCHVER:=//p' \
		"$top/target/linux/airoha/an7581/target.mk" 2>/dev/null | head -n 1)
	if [ -n "$pv" ]; then
		b="kernel$(printf '%s' "$pv" | tr -d '.')"
		case " $TRACK " in
		*" $b "*)
			printf '%s\n' "$b"
			return
			;;
		esac
	fi
	printf '%s\n' "$TRACK" | tr ' ' '\n' | head -n 1
}
GATE=$(gate_branch)
gate_ref="refs/remotes/$REMOTE/$GATE"
gate_behind=

# --list-hot is the worklist behind a must-act verdict: the pending commits
# that touch what this fork builds.  Read the list, not the diff: the diff is
# ~2800 files of upstream churn the fork intentionally does not carry.
if [ "$LISTHOT" = 1 ]; then
	has_ref "$gate_ref" || {
		echo "track-upstream: gate branch $GATE is not a resolved ref" >&2
		exit 3
	}
	# shellcheck disable=SC2086 # HOT_PATHS is a deliberate pathspec list
	git log --oneline "$LOCAL_SHA..$gate_ref" -- $HOT_PATHS
	exit 0
fi

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
	rec_drift=0
	if [ "$act_anc" = no ] || [ "$act_tree" = different ]; then
		rec_drift=1
	fi
	record_verdict check "$rec_drift" "$act_anc" "$act_tree"
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
	if [ "$b" = "$GATE" ]; then
		gate_behind=$behind
		gate_ref=$ref
	fi
	state=in-sync
	if [ "$behind" -gt 0 ]; then
		state=behind
		drift=1
	fi
	say "$(printf '%-13s %-13s %-11s %-13s %6s %6s  %s' \
		"$b" "$(short "$us")" "$(when "$us")" "$(short "$mb")" \
		"$behind" "$ahead" "$state")"
done

# A08-F7: --gate-branch accepts any upstream ref, but the loop above only
# assigns gate_behind for branches listed in --track.  A resolved ref outside
# that list used to leave the count empty and the verdict at unknown(3) even
# though the count is well defined.  Count it directly here.  An in-track
# branch with no merge base stays unknown: nothing was compared.
if [ -z "$gate_behind" ]; then
	case " $TRACK " in
	*" $GATE "*) ;;
	*)
		if has_ref "$gate_ref" &&
			git merge-base "$gate_ref" "$LOCAL_SHA" >/dev/null 2>&1; then
			gate_behind=$(git rev-list --count "$LOCAL_SHA..$gate_ref")
		fi
		;;
	esac
fi

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

# --verdict turns the drift report into a decision with an expiry date: three
# axes (commits behind, files differing, pending hot-path commits) each hatch
# at review and at must-act.  The report above answers "are we behind"; this
# answers "does it matter yet", which is the question a periodic run asks.
if [ "$VERDICT" = 1 ]; then
	if ! has_ref "$gate_ref"; then
		printf '%s\n' "verdict: unknown - gate branch $GATE is not a resolved ref"
		exit 3
	fi
	if [ -z "$gate_behind" ]; then
		printf '%s\n' "verdict: unknown - gate branch $GATE shares no base with $LOCAL"
		exit 3
	fi
	gate_files=$(git diff --name-only "$LOCAL_SHA" "$gate_ref" | wc -l | tr -d ' ')
	# shellcheck disable=SC2086 # HOT_PATHS is a deliberate pathspec list
	gate_hot=$(git rev-list --count "$LOCAL_SHA..$gate_ref" -- $HOT_PATHS)
	if [ "$gate_behind" -ge "$ACT_BEHIND" ] || [ "$gate_files" -ge "$ACT_FILES" ] ||
		[ "$gate_hot" -ge "$ACT_HOT" ]; then
		v=must-act
		code=2
	elif [ "$gate_behind" -ge "$REVIEW_BEHIND" ] || [ "$gate_files" -ge "$REVIEW_FILES" ] ||
		[ "$gate_hot" -ge "$REVIEW_HOT" ]; then
		v=review
		code=1
	else
		v=ok
		code=0
	fi
	# The verdict line is the output of this mode, so --quiet (added for the
	# report table) must not eat it: a CI job reads the code and the line.
	printf '%s\n' "verdict: $v (branch=$GATE behind=$gate_behind files=$gate_files hot=$gate_hot)"
	printf '%s\n' "         review >= $REVIEW_BEHIND/$REVIEW_FILES/$REVIEW_HOT, must-act >= $ACT_BEHIND/$ACT_FILES/$ACT_HOT"
	exit "$code"
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
