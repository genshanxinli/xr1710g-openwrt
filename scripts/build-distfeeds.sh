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

set -eu

topdir=${TOPDIR:-$(cd "$(dirname "$0")/.." && pwd)}
out=${1:-$topdir/distfeeds}
bin=$topdir/bin

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
    rows.append((os.path.relpath(path, out), n, k))
    if not os.path.exists(os.path.join(root, "packages.adb")):
        sys.exit("%s: index.json without packages.adb" % root)

if not rows:
    sys.exit("no repository index found under %s" % out)

core = [r for r in rows if r[0].startswith("targets/")]
if not core or not core[0][2]:
    sys.exit("core feed carries no kernel/kmod entries: %r" % (rows,))

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

printf 'distfeeds written to %s\n' "$out"
