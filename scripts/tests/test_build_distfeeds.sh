#!/bin/sh
# Smoke test for scripts/build-distfeeds.sh.  Runs against synthetic feed
# trees only (the script copies and parses indexes, it does not build), so
# it needs nothing from a real build:
#
#   sh scripts/tests/test_build_distfeeds.sh

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
script=${BUILD_DISTFEEDS_UNDER_TEST:-$here/build-distfeeds.sh}
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


# --emit-build-patch: the xr1710g-builds handoff is a runtime product, never a
# stored file.  These assertions pin its shape so a regenerated patch cannot
# drift into something the build repo's workflow will not accept.
if sh "$script" --help | grep -q -- '--emit-build-patch'; then
	ok "--help documents --emit-build-patch"
else
	no "--help documents --emit-build-patch"
fi

sh "$script" --emit-build-patch >"$tmp/p1.patch" 2>"$tmp/p1.err"
sh "$script" --emit-build-patch >"$tmp/p2.patch" 2>/dev/null
if [ "$(wc -l <"$tmp/p1.patch")" -eq 16 ]; then
	ok "emit prints the 16-line hunk"
else
	no "emit prints the 16-line hunk (got $(wc -l <"$tmp/p1.patch"))"
fi
if grep -q '^+++ b/.github/workflows/build.yml$' "$tmp/p1.patch" &&
	grep -q '^@@ -73,6 +73,13 @@$' "$tmp/p1.patch" &&
	grep -q '^+      - name: Collect distfeeds$' "$tmp/p1.patch" &&
	grep -q './scripts/build-distfeeds.sh ../distfeeds' "$tmp/p1.patch" &&
	grep -qF 'distfeeds-${{ env.source }}' "$tmp/p1.patch"; then
	ok "emit carries the step, the script call and the artifact name"
else
	no "emit carries the step, the script call and the artifact name"
fi
if cmp -s "$tmp/p1.patch" "$tmp/p2.patch"; then
	ok "emit is byte-identical across runs"
else
	no "emit is byte-identical across runs"
fi

# It must apply to a workflow that has the anchor lines, and it must not need a
# build tree: this runs with no TOPDIR and no bin/ anywhere.
mkdir -p "$tmp/buildrepo/.github/workflows"
cat >"$tmp/buildrepo/.github/workflows/build.yml" <<'EOF'
      - name: Collect images
        run: |
          cd openwrt
          find bin/targets -type f -name '*.bin' -o -name '*.itb' \
            -exec cp {} ../out/ \;
          ls -la ../out

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: images
          path: ../out
EOF
if (cd "$tmp/buildrepo" && patch -p1 --dry-run -s <"$tmp/p1.patch"); then
	ok "emit applies to a workflow with the anchor lines"
	(cd "$tmp/buildrepo" && patch -p1 -s <"$tmp/p1.patch")
	if grep -q 'Collect distfeeds' "$tmp/buildrepo/.github/workflows/build.yml"; then
		ok "applied patch adds the distfeeds step"
	else
		no "applied patch adds the distfeeds step"
	fi
else
	no "emit applies to a workflow with the anchor lines"
fi

# PATCHFILE form: stdout stays empty so a caller can tee, the file is created.
mkdir -p "$tmp/emit"
sh "$script" --emit-build-patch "$tmp/emit/build.yml.patch" >"$tmp/emit/out.txt" 2>"$tmp/emit/err.txt"
if [ -s "$tmp/emit/build.yml.patch" ] && [ ! -s "$tmp/emit/out.txt" ] &&
	grep -q 'git apply --check' "$tmp/emit/err.txt"; then
	ok "emit PATCHFILE writes the file, not stdout, and prints the handoff"
else
	no "emit PATCHFILE writes the file, not stdout, and prints the handoff"
fi

# And nothing like it is stored in the tree: the patch is not a repository
# artifact, so there must be no build.yml.patch under version control.
if [ -z "$(git -C "$here/.." ls-files | grep 'build.yml.patch')" ]; then
	ok "no stored copy of the build patch"
else
	no "no stored copy of the build patch"
fi

[ "$fail" -eq 0 ] && printf 'all checks passed\n'
exit "$fail"
