#!/bin/sh
# Copy this tree into a Linux build tree with sane file modes.
#
# The repository normally lives on a Windows drive mounted through WSL
# (/mnt/d and friends) or on a CIFS share. On those filesystems chmod() is a
# no-op and every file reports 0777 regardless of what is stored in git. A
# plain `rsync -a` therefore copies that 0777 into the build tree, and the
# world-writable bit is not cosmetic:
#
#   - rpcd refuses to load a ucode plugin that is world writable
#     ("Ignoring ucode script ... because it is world writable"), so the RPC
#     object is never registered and LuCI fails with
#     "RPC call to luci.airoha_flowsense/getStatus failed ... Object not found"
#   - init scripts, hotplug handlers and rpcd backends need their executable
#     bit, which git records but the source filesystem cannot express
#
# So instead of trusting the source modes, restore the modes recorded in the
# git index (100644 -> 0644, 100755 -> 0755) after the copy.
#
# Usage: scripts/sync-to-buildtree.sh /path/to/openwrt-build-tree

set -e

DEST="${1:?usage: $0 /path/to/openwrt-build-tree}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

[ -d "$DEST" ] || { echo "no such directory: $DEST" >&2; exit 1; }
[ -d "$DEST/.git" ] || echo "note: $DEST is not a git tree, only modes will be fixed" >&2

echo "syncing $SRC -> $DEST"

rsync -a --delete \
	--exclude=/.git \
	--exclude=/build_dir \
	--exclude=/staging_dir \
	--exclude=/bin \
	--exclude=/tmp \
	--exclude=/dl \
	--exclude=/feeds \
	--exclude=/package/feeds \
	--exclude=/logs \
	--exclude=/.config \
	--exclude=/.config.old \
	"$SRC"/ "$DEST"/

# Restore the modes git recorded. This is the part a chmod on the source
# filesystem could not do.
echo "restoring file modes from the git index"
git -C "$SRC" ls-files -s | while read -r mode _ _ path; do
	case "$mode" in
	100755) perm=0755 ;;
	100644) perm=0644 ;;
	*) continue ;;
	esac

	[ -e "$DEST/$path" ] || continue
	chmod "$perm" "$DEST/$path"
done

# Directories must stay traversable even if the copy inherited 0700.
find "$DEST" -path "$DEST/.git" -prune -o -type d -print0 2>/dev/null |
	xargs -0 -r chmod 0755

echo "done"
