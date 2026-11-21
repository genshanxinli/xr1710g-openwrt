#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# check-mt76-pin.sh -- turn "should the mt76 pin move?" into one verdict (#9).
#
# The pin lives in package/kernel/mt76/Makefile.  Moving it is not a one-line
# edit: every local patch under package/kernel/mt76/patches/ is anchored to the
# pinned tree, so a bump re-opens the whole patch set.  That is why the tree
# needs a *decision*, not a reminder: the answer is keep, bump or blocked, each
# with a reason and a stable exit status.
#
# The three states:
#
#   keep     upstream has not moved past the pin, or moved by less than
#            MT76_BUMP_MIN_COMMITS commits (default 10).  A short drift is not
#            worth re-anchoring the patch set.
#   bump     upstream is at least MT76_BUMP_MIN_COMMITS ahead: re-anchoring is
#            the known cost of following upstream, so the next maintainer has
#            nothing left to decide -- only to execute.
#   blocked  the question cannot be answered, or the answer is not actionable:
#            no upstream data (offline and no cache), the pinned commit is not
#            in upstream history (rewritten branch), or the local patch set
#            exceeds MT76_LOCAL_PATCH_LIMIT (default 50), which means a bump is
#            a re-write rather than a re-anchor.
#
# "blocked" exits non-zero on purpose.  A silent "keep" when upstream is
# unreadable is the failure this contract prevents: it looks like agreement
# while nothing was compared.
#
# Usage:
#   scripts/check-mt76-pin.sh [--fetch] [--offline]
#                             [--repo DIR] [--ref REF]
#                             [--pin-file FILE] [--patch-dir DIR]
#                             [-h|--help]
#
# Output: "key value" rows, then "verdict keep|bump|blocked".
#
# Exit status:
#   0  keep       the pin still describes a reasonable upstream point
#   1  bump       upstream is far enough ahead to justify re-anchoring
#   2  blocked    not decidable / not actionable, with the reason on stdout
#
# Environment:
#   MT76_PIN_FILE          default package/kernel/mt76/Makefile
#   MT76_PATCH_DIR         default package/kernel/mt76/patches
#   MT76_UPSTREAM_REPO     default <git-common-dir>/mt76-upstream.git
#   MT76_UPSTREAM_REF      default main
#   MT76_SOURCE_URL        default PKG_SOURCE_URL from the pin file
#   MT76_BUMP_MIN_COMMITS  default 10
#   MT76_LOCAL_PATCH_LIMIT default 50
#
# The upstream clone is a cache, not an input: --fetch refreshes it, --offline
# never touches the network.  The default is --offline so a CI run cannot
# depend on github being reachable.

set -eu

usage() {
	sed -n '/^# Usage:/,/^# The upstream clone/p' "$0" | sed 's/^#//'
}

topdir=${TOPDIR:-$(cd "$(dirname "$0")/.." && pwd)}

FETCH=0
PIN_FILE=${MT76_PIN_FILE:-$topdir/package/kernel/mt76/Makefile}
PATCH_DIR=${MT76_PATCH_DIR:-$topdir/package/kernel/mt76/patches}
REF=${MT76_UPSTREAM_REF:-main}
REPO=${MT76_UPSTREAM_REPO:-}
BUMP_MIN=${MT76_BUMP_MIN_COMMITS:-10}
PATCH_LIMIT=${MT76_LOCAL_PATCH_LIMIT:-50}

need_value() {
	if [ $# -lt 2 ]; then
		echo "check-mt76-pin: $1 needs a value" >&2
		exit 2
	fi
}

while [ $# -gt 0 ]; do
	case "$1" in
	--fetch)
		FETCH=1
		shift
		;;
	--offline)
		FETCH=0
		shift
		;;
	--repo)
		need_value "$@"
		REPO=$2
		shift 2
		;;
	--ref)
		need_value "$@"
		REF=$2
		shift 2
		;;
	--pin-file)
		need_value "$@"
		PIN_FILE=$2
		shift 2
		;;
	--patch-dir)
		need_value "$@"
		PATCH_DIR=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "check-mt76-pin: unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

[ -f "$PIN_FILE" ] || {
	echo "check-mt76-pin: no pin file: $PIN_FILE" >&2
	exit 2
}

pin_date=$(sed -n 's/^PKG_SOURCE_DATE:=//p' "$PIN_FILE" | head -n 1)
pin_sha=$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "$PIN_FILE" | head -n 1)
source_url=$(sed -n 's/^PKG_SOURCE_URL:=//p' "$PIN_FILE" | head -n 1)
if [ -n "${MT76_SOURCE_URL:-}" ]; then
	source_url=$MT76_SOURCE_URL
fi

[ -n "$pin_sha" ] || {
	echo "check-mt76-pin: $PIN_FILE has no PKG_SOURCE_VERSION" >&2
	exit 2
}

patch_count=0
if [ -d "$PATCH_DIR" ]; then
	patch_count=$(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' | wc -l | tr -d ' ')
fi

row() {
	printf '%-16s %s\n' "$1" "$2"
}

short() {
	printf '%s' "$1" | cut -c1-8
}

# Dates as YYYY-MM-DD to whole days; blank when the platform date tool cannot
# parse one of them, so a missing row never turns into a wrong number.
days_between() {
	a=$(date -d "$1" +%s 2>/dev/null) || return 0
	b=$(date -d "$2" +%s 2>/dev/null) || return 0
	printf '%s' $(((b - a) / 86400))
}

row pin.date "$pin_date"
row pin.sha "$(short "$pin_sha")"
row local.patches "$patch_count"
row local.limit "$PATCH_LIMIT"
row upstream.ref "$REF"

verdict=''
reason=''
block() {
	if [ -z "$reason" ]; then
		verdict=blocked
		reason=$1
		row blocked.reason "$1"
	else
		row blocked.also "$1"
	fi
}

if [ "$patch_count" -gt "$PATCH_LIMIT" ]; then
	block "local patch set is $patch_count > limit $PATCH_LIMIT; a bump rewrites patches instead of re-anchoring them"
fi

# --- upstream cache ----------------------------------------------------------

if [ -z "$REPO" ]; then
	common=''
	if git -C "$topdir" rev-parse --show-toplevel >/dev/null 2>&1; then
		common=$(git -C "$topdir" rev-parse --path-format=absolute --git-common-dir)
	fi
	if [ -n "$common" ]; then
		REPO=${common%/}/mt76-upstream.git
	else
		REPO=${TMPDIR:-/tmp}/mt76-upstream.git
	fi
fi
row upstream.repo "$REPO"

if [ ! -d "$REPO" ]; then
	if [ "$FETCH" = 1 ] && [ -n "$source_url" ]; then
		echo "check-mt76-pin: cloning $source_url -> $REPO" >&2
		if ! git clone -q --bare "$source_url" "$REPO"; then
			rm -rf "$REPO"
			block "clone failed: $source_url"
		fi
	elif [ "$FETCH" = 1 ]; then
		block "no PKG_SOURCE_URL in $PIN_FILE and MT76_SOURCE_URL unset, cannot clone"
	else
		block "no upstream cache at $REPO; run once with --fetch to create it"
	fi
elif [ "$FETCH" = 1 ]; then
	if ! git -C "$REPO" fetch -q --prune origin; then
		block "fetch failed in $REPO"
	fi
fi

if [ -d "$REPO" ]; then
	up_sha=$(git -C "$REPO" rev-parse -q --verify "refs/heads/$REF^{commit}" 2>/dev/null) || up_sha=''
	if [ -z "$up_sha" ]; then
		up_sha=$(git -C "$REPO" rev-parse -q --verify "$REF^{commit}" 2>/dev/null) || up_sha=''
	fi
	if [ -z "$up_sha" ]; then
		block "ref $REF is not in $REPO"
	else
		up_date=$(git -C "$REPO" log -1 --format=%cs "$up_sha")
		row upstream.sha "$(short "$up_sha")"
		row upstream.date "$up_date"
		if ! git -C "$REPO" cat-file -e "$pin_sha^{commit}" >/dev/null 2>&1; then
			block "pinned commit $pin_sha is not in upstream (rewritten branch or wrong URL)"
		elif ! git -C "$REPO" merge-base --is-ancestor "$pin_sha" "$up_sha" >/dev/null 2>&1; then
			# The pin sits on a branch that $REF never took.  The commit count
			# from here is not an "ahead" count -- it counts the other lineage --
			# so it is evidence, never the verdict.
			on_branches=$(git -C "$REPO" for-each-ref --format='%(refname:short)' \
				--contains "$pin_sha" refs/heads 2>/dev/null | tr '\n' ' ')
			on_branches=${on_branches% }
			row pin.branches "${on_branches:-none}"
			diverged=$(git -C "$REPO" rev-list --count "$pin_sha..$up_sha")
			row diverged.commits "$diverged"
			block "pin $(short "$pin_sha") is not an ancestor of $REF (it is on ${on_branches:-no branch}); $REF carries $diverged commits on another lineage, so a bump is a lineage switch, not a catch-up"
		else
			behind=$(git -C "$REPO" rev-list --count "$pin_sha..$up_sha")
			row behind.commits "$behind"
			days=$(days_between "$pin_date" "$up_date")
			if [ -n "$days" ]; then
				row behind.days "$days"
			fi
			row bump.min "$BUMP_MIN"
			if [ -z "$verdict" ]; then
				if [ "$behind" -ge "$BUMP_MIN" ]; then
					verdict=bump
				else
					verdict=keep
				fi
			fi
		fi
	fi
fi

if [ -z "$verdict" ]; then
	verdict=keep
fi
row verdict "$verdict"
if [ -n "$reason" ]; then
	row reason "$reason"
fi

case "$verdict" in
keep) exit 0 ;;
bump) exit 1 ;;
*) exit 2 ;;
esac
