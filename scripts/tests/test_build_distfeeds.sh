#!/bin/sh
# Smoke test for scripts/build-distfeeds.sh.  Runs against synthetic feed
# trees only (the script copies and parses indexes, it does not build), so
# it needs nothing from a real build:
#
#   sh scripts/tests/test_build_distfeeds.sh

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/build-distfeeds.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

ok() { printf 'ok   %s\n' "$1"; }
no() { printf 'FAIL %s\n' "$1"; fail=1; }

# --help must print usage and exit 0 without touching the cwd.
mkdir -p "$tmp/help"
if (cd "$tmp/help" && sh "$script" --help >/dev/null); then
	ok "--help exits 0"
else
	no "--help exits 0"
fi
if [ -z "$(ls -A "$tmp/help")" ]; then
	ok "--help writes nothing"
else
	no "--help writes nothing"
fi

# Synthetic tree: one target feed, one feed package, a fake .apk each.
tree=$tmp/tree
mkdir -p "$tree/bin/targets/board/sub/packages" \
	"$tree/bin/packages/arch/feed"
: >"$tree/bin/targets/board/sub/packages/fake.apk"
: >"$tree/bin/packages/arch/feed/fake.apk"
: >"$tree/bin/targets/board/sub/packages/packages.adb"
: >"$tree/bin/packages/arch/feed/packages.adb"

# Core index without kernel/kmod must be rejected.
cat >"$tree/bin/targets/board/sub/packages/index.json" <<'EOF'
{"packages": {"base-files-1": {}, "fake-1": {}}}
EOF
cat >"$tree/bin/packages/arch/feed/index.json" <<'EOF'
{"packages": {"fake-1": {}}}
EOF
if TOPDIR=$tree sh "$script" "$tmp/out-bad" 2>"$tmp/bad.log"; then
	no "rejects core index without kernel/kmod"
elif grep -q 'core feed carries no kernel/kmod' "$tmp/bad.log"; then
	ok "rejects core index without kernel/kmod"
else
	no "rejects core index without kernel/kmod"
fi

# Core index with kernel + kmod must produce the tree and the manifest.
cat >"$tree/bin/targets/board/sub/packages/index.json" <<'EOF'
{"packages": {"kernel-7.3-r1": {}, "kmod-fake-7.3-r1": {}, "fake-1": {}}}
EOF
if TOPDIR=$tree sh "$script" "$tmp/out" >"$tmp/good.log"; then
	ok "accepts core index with kernel/kmod"
else
	no "accepts core index with kernel/kmod"
fi
if [ -f "$tmp/out/MANIFEST.json" ] &&
	python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
sys.exit(0 if (m['packages'], m['kmods']) == (4, 2) else 1)
" "$tmp/out/MANIFEST.json"; then
	ok "MANIFEST counts packages and kmods"
else
	no "MANIFEST counts packages and kmods"
fi
if [ -f "$tmp/out/distfeeds.list" ] &&
	[ "$(wc -l <"$tmp/out/distfeeds.list")" -eq 2 ]; then
	ok "distfeeds.list lists both indexes"
else
	no "distfeeds.list lists both indexes"
fi

[ "$fail" -eq 0 ] && printf 'all checks passed\n'
exit "$fail"
