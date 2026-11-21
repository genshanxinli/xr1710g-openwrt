#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Assemble the distfeeds tree that gets published next to the images.
#
# The tree mirrors the URL layout that include/feeds.mk writes into
# /etc/apk/repositories.d/distfeeds.list, so any static server (or a
# file:// path, or an extracted tarball) can be used as the feed base:
#
#   targets/<board>/<subtarget>/packages/packages.adb     core: base-files, kernel, all kmods
#   packages/<arch>/<feed>/packages.adb                   base, luci, packages, routing, ...
#
# In the apk era the kmods are built into the target's packages/ directory
# (PACKAGE_DIR == BIN_DIR/packages, see rules.mk) and indexed there, so no
# CONFIG_BUILDBOT-style split kmod feed is needed; this script fails if that
# index turns out to carry no kernel package.
#
# Usage: scripts/build-distfeeds.sh [OUTDIR]   (default: <topdir>/distfeeds)
#        scripts/build-distfeeds.sh --emit-build-patch [PATCHFILE]
#
# --emit-build-patch prints the one-hunk patch that adds the "Collect
# distfeeds" step to genshanxinli/xr1710g-builds' .github/workflows/build.yml,
# or writes it to PATCHFILE.  The patch belongs to the build repo, not to this
# tree: stored here as a file it would silently rot against a workflow this
# repo cannot see, and the build repo cannot merge it without burning a
# 350-minute image build.  Generating it from the script that produces the
# feeds keeps the inserted command and the patch in the same file, so anyone
# holding this branch can regenerate the handoff against the current script.

set -eu

# The patch is emitted verbatim: context lines are what `git apply` matches on,
# so this heredoc is the artifact and editing it means re-checking it against
# build.yml in the build repo (git apply --check).
emit_build_patch() {
	cat <<'PATCH'
--- a/.github/workflows/build.yml
+++ b/.github/workflows/build.yml
@@ -73,6 +73,13 @@
             -exec cp {} ../out/ \;
           ls -la ../out
 
+      - name: Collect distfeeds
+        run: |
+          cd openwrt
+          ./scripts/build-distfeeds.sh ../distfeeds
+          tar -czf ../out/distfeeds-${{ env.source }}.tar.gz -C .. distfeeds
+          ls -la ../out
+
       - name: Upload artifacts
         uses: actions/upload-artifact@v4
         with:
PATCH
}

emit_build_patch_to() {
	mkdir -p "$(dirname -- "$1")"
	emit_build_patch >"$1"
	printf 'build patch written to %s\n' "$1" >&2
	printf 'handoff: in the xr1710g-builds checkout run\n' >&2
	printf '  git apply --check %s && git apply %s\n' "$1" "$1" >&2
}

# -h/--help must not fall through to OUTDIR: `rm -rf --help` treats it as an
# option, prints rm's usage and aborts with exit 1 instead of showing the
# usage text above.
case ${1:-} in
--emit-build-patch)
	if [ -n "${2:-}" ]; then
		emit_build_patch_to "$2"
	else
		emit_build_patch
	fi
	exit 0
	;;
-h | --help)
	sed -n '4,/^$/p' "$0" | sed -e 's/^#\s*//'
	exit 0
	;;
esac

topdir=${TOPDIR:-$(cd "$(dirname "$0")/.." && pwd)}
out=${1:-$topdir/distfeeds}
bin=$topdir/bin

# Everything this script publishes was copied out of bin/ while it ran. If bin/
# gained build output after this moment, a build was still writing and the copy
# may hold an index that already names a version whose .apk had not landed yet
# (that is how base-files 1722~23751e1da6 got published against a
# 1722~1226d64f38.apk). Checked again at the end; see the find below.
# Sub-second precision, else a file written just before this line looks newer
# than the run itself; %N is GNU-only, so fall back to whole seconds.
start_epoch=$(date +%s.%N 2>/dev/null || true)
case $start_epoch in
'' | *N*) start_epoch=$(date +%s) ;;
esac

if [ ! -d "$bin/packages" ] && [ ! -d "$bin/targets" ]; then
	printf '%s: no build output under %s, run make first\n' "$0" "$bin" >&2
	exit 1
fi

rm -rf "$out"
mkdir -p "$out"

# Copy every directory that holds a repository index. Same shape as the
# build output, so relative paths stay stable between build and release.
for d in "$bin"/targets/*/*/packages "$bin"/packages/*/*; do
	[ -d "$d" ] || continue
	[ -f "$d/packages.adb" ] || continue
	rel=${d#"$bin"/}
	mkdir -p "$out/$rel"
	cp -a "$d"/*.apk "$d/packages.adb" "$d/index.json" "$out/$rel/"
done

if [ ! -f "$out/distfeeds.list" ]; then
	: >"$out/distfeeds.list"
	for f in $(cd "$out" && find . -name packages.adb | LC_ALL=C sort); do
		printf '%s\n' "${f#./}" >>"$out/distfeeds.list"
	done
fi

# Verify the indexes really describe the packages we are about to publish,
# and that the core feed carries kernel + kmods. python3 because jq is not
# guaranteed on the build hosts.
python3 - "$out" <<'EOF'
import json, os, sys

out = sys.argv[1]
total = kmods = 0
rows = []
stale = []
for root, _, files in os.walk(out):
    if "index.json" not in files:
        continue
    path = os.path.join(root, "index.json")
    data = json.load(open(path))
    pkgs = data.get("packages", data)
    names = list(pkgs)
    n = len(names)
    k = len([p for p in names if p.startswith(("kmod-", "kernel"))])
    total += n
    kmods += k
    rel = os.path.relpath(path, out)
    rows.append((rel, n, k))
    if not os.path.exists(os.path.join(root, "packages.adb")):
        sys.exit("%s: index.json without packages.adb" % root)

    # The index is what a client installs from, so every version it names must
    # have its .apk in this same directory. The published tree is only ever a
    # copy, and the copy races a running build: the index can be written before
    # the .apk it describes. A missing apk here is a stale index, not a warning.
    stems = [f[:-4] for f in files if f.endswith(".apk")]
    for name, ver in sorted(pkgs.items()):
        # A real apk index maps name -> version string. Anything else has no
        # version to match a file name against (the shell test's shape-only
        # fixtures use {}), so it cannot be checked here.
        if not isinstance(ver, str):
            continue
        if name + "-" + ver in stems:
            continue
        # Some packages put an extra token in the file name (index "libatomic"
        # -> libatomic1-14.4.0-r5.apk), so the version suffix is the anchor.
        if any(s.startswith(name) and s.endswith("-" + ver) for s in stems):
            continue
        stale.append((rel, name, ver))

if not rows:
    sys.exit("no repository index found under %s" % out)

core = [r for r in rows if r[0].startswith("targets/")]
if not core or not core[0][2]:
    sys.exit("core feed carries no kernel/kmod entries: %r" % (rows,))

if stale:
    for rel, name, ver in stale:
        sys.stderr.write(
            "%s: stale-index: declares %s %s but no .apk on disk\n"
            % (rel, name, ver)
        )
    sys.exit(
        "stale-index: %d declared package(s) missing from the copied tree; "
        "bin/ was likely being written while this ran, refusing to publish"
        % len(stale)
    )

for rel, n, k in sorted(rows):
    print("%-52s %4d packages %4d kmod/kernel" % (rel, n, k))

manifest = {
    "packages": total,
    "kmods": kmods,
    "feeds": [{"index": r[0], "packages": r[1], "kmods": r[2]} for r in sorted(rows)],
}
with open(os.path.join(out, "MANIFEST.json"), "w") as f:
    json.dump(manifest, f, indent=1, sort_keys=True)
    f.write("\n")
print("total: %d packages, %d kmod/kernel" % (total, kmods))
EOF

# The device trusts the key that signed the indexes it booted with; publish
# the public half only so a feed from another build tree can be verified.
if [ -f "$topdir/public-key.pem" ]; then
	cp "$topdir/public-key.pem" "$out/public-key.pem"
fi

# Nothing above writes into bin/, so any build output newer than start_epoch is
# a build that was still running: the tree we just packed may be a half-written
# snapshot even when the index happened to agree at copy time. Refuse it rather
# than publish a batch that cannot be reinstalled.
newer=$(find "$bin" -newermt "@$start_epoch" \
	\( -name '*.apk' -o -name 'index.json' -o -name '*.itb' \) -print 2>/dev/null | head -n 5)
if [ -n "$newer" ]; then
	printf '%s: bin/ changed while this ran (a build is writing it), refusing to publish:\n' "$0" >&2
	printf '%s\n' "$newer" | sed -e 's/^/  /' >&2
	exit 1
fi

printf 'distfeeds written to %s\n' "$out"
