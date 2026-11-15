#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Build preflight: refuse a build from a worktree path with non-ASCII bytes.
#
# The build writes the absolute worktree path into the host staging
# pkg-config files. A non-ASCII byte in that path makes meson fail while it
# parses the expanded includedir, in an unrelated host package, before the
# requested target is built.
#
# Usage: scripts/build-preflight.sh [--dry-run]
#
# Environment:
#   TOPDIR           worktree to check (default: $PWD)
#   SKIP_PATH_CHECK  set to 1 to warn instead of failing

dry_run=0
for arg in "$@"; do
	case "$arg" in
	--dry-run)
		dry_run=1
		;;
	*)
		printf 'usage: %s [--dry-run]\n' "$0" >&2
		exit 2
		;;
	esac
done

topdir=${TOPDIR:-$PWD}

# LC_ALL=C makes tr work on raw bytes: deleting the ASCII range leaves the
# bytes >= 0x80, which are exactly what meson cannot decode.
if [ -n "$(printf '%s' "$topdir" | LC_ALL=C tr -d '\000-\177')" ]; then
	path_non_ascii=1
else
	path_non_ascii=0
fi

if [ "$path_non_ascii" -eq 0 ]; then
	printf 'build-preflight: OK: worktree path is pure ASCII: %s\n' "$topdir"
	exit 0
fi

if [ "$dry_run" -eq 1 ]; then
	printf 'build-preflight: worktree path contains non-ASCII bytes (dry run)\n' >&2
elif [ "${SKIP_PATH_CHECK:-0}" = 1 ]; then
	printf 'build-preflight: warning: worktree path contains non-ASCII bytes\n' >&2
else
	printf 'build-preflight: error: worktree path contains non-ASCII bytes\n' >&2
fi

cat >&2 <<EOF
  path: $topdir

The build expands this path into the host staging pkg-config files
(includedir). meson cannot decode the non-ASCII bytes, so the build dies
in an unrelated host package (for example package/system/apk [host])
before the requested target is built, with:

  'utf-8' codec can't decode byte 0xe9 in position 18: invalid continuation byte

Byte 0xe9 is the first UTF-8 byte of U+9879. Build from a pure ASCII path:

Fix 1 - rebuild the worktree at a pure ASCII path, for example /xr/xr1710g:
  sudo mkdir -p /xr && sudo chown $(id -un) /xr
  git clone -b xr1710g https://github.com/genshanxinli/xr1710g-openwrt.git /xr/xr1710g
  cd /xr/xr1710g

Fix 2 - keep this checkout and bind-mount it at a pure ASCII path:
  sudo mkdir -p /xr/xr1710g
  sudo mount --bind '$topdir' /xr/xr1710g
  cd /xr/xr1710g
  (a symlink is not enough: make resolves the real path of the worktree)

Keep this check as a warning only: SKIP_PATH_CHECK=1
Report without changing the exit code: --dry-run
EOF

if [ "$dry_run" -eq 1 ] || [ "${SKIP_PATH_CHECK:-0}" = 1 ]; then
	exit 0
fi

exit 1
