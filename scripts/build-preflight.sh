#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Pre-build gate: ASCII TOPDIR, shell/python syntax, BusyBox ash lint, repo hygiene, and --patch-queue.
set -u

TOPDIR=${TOPDIR:-$PWD}
PATCH_BASE_REF=${PATCH_BASE_REF:-db9128c34652317cfbfffdf71e2b813edbe0cf0e}
DRY_RUN=0; DO_DEFAULT=1; DO_PATCHES=0; TARBALL=''; FAILS=0; WORK=''

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

usage() {
	cat <<'EOF'
Usage:
  build-preflight.sh [--dry-run]                      pre-build path, syntax, ash lint, hygiene
  build-preflight.sh --patch-queue [tarball-or-dir]   patch prefix, header, and strict fuzz=0 check
  build-preflight.sh --all [tarball-or-dir]           run both gates
EOF
}

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
ok() { printf 'OK: %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	--dry-run) DRY_RUN=1; shift ;;
	--patch-queue)
		DO_DEFAULT=0; DO_PATCHES=1; shift
		if [ $# -gt 0 ]; then case "$1" in -*) ;; *) TARBALL=$1; shift ;; esac; fi ;;
	--all)
		DO_DEFAULT=1; DO_PATCHES=1; shift
		if [ $# -gt 0 ]; then case "$1" in -*) ;; *) TARBALL=$1; shift ;; esac; fi ;;
	*) usage >&2; exit 2 ;;
	esac
done

WORK=$(mktemp -d 2>/dev/null) || { printf 'ERROR: cannot create temp dir\n' >&2; exit 2; }

check_ascii_topdir() {
	if [ -n "$(printf '%s' "$TOPDIR" | LC_ALL=C tr -d '\000-\177')" ]; then
		if [ "$DRY_RUN" = 1 ] || [ "${SKIP_PATH_CHECK:-0}" = 1 ]; then
			printf 'WARN: non-ASCII bytes in TOPDIR: %s\n' "$TOPDIR" >&2
		else
			fail "TOPDIR contains non-ASCII bytes (breaks host meson): $TOPDIR"
		fi
	else
		ok "TOPDIR is pure ASCII: $TOPDIR"
	fi
}

interp_for() {
	case "$(head -n 1 "$1" 2>/dev/null || true)" in
	'#!'*bash*) echo bash ;;
	'#!'*'/sh'*|'#!'*' sh'*|'#!'*dash*|'#!'*ash*) echo sh ;;
	'#!'*) echo skip ;;
	*) echo sh ;;
	esac
}

ash_lint_file() {
	awk '
		/^[ \t]*#/ { next }
		{
			if (match($0, /(^|[;&|(! \t])flock[ \t]+[^;&|]*/)) {
				seg = substr($0, RSTART, RLENGTH); sub(/^.*flock[ \t]+/, "", seg)
				n = split(seg, tok, /[ \t]+/)
				for (k = 1; k <= n; k++) {
					if (tok[k] == "--") break
					if (tok[k] ~ /^--/ || (tok[k] ~ /^-/ && tok[k] !~ /^-[sxun]+$/)) {
						printf "%s:%d: BusyBox flock rejects flag %s\n", FILENAME, FNR, tok[k]; e = 1
					}
					if (tok[k] !~ /^-/) break
				}
			}
		}
		/(^|[;&|(! \t])tr[ \t]+[^|;&]*\[[:][a-z]+[:]\]/ { printf "%s:%d: BusyBox tr rejects POSIX class\n", FILENAME, FNR; e=1 }
		/(^|[;&|(! \t])\[[\[][ \t]/ { printf "%s:%d: bashism double-bracket\n", FILENAME, FNR; e=1 }
		{
			ln = $0; gsub(/\047[^\047]*\047/, "", ln); gsub(/\$\([^)]*\)/, "()", ln)
			if (ln ~ /(^|[;&|(! \t])\[[ \t][^]]*[ \t]=[=][ \t]/ || ln ~ /(^|[;&|(! \t])test[ \t]+[^;&|]*[ \t]=[=][ \t]/) {
				printf "%s:%d: bashism == in test\n", FILENAME, FNR; e=1
			}
		}
		/(^|[;&|])[ \t]*source[ \t]+/ { printf "%s:%d: bashism source\n", FILENAME, FNR; e=1 }
		/(^|[;&| \t])echo[ \t]+-[A-Za-z]*e([ \t]|$)/ { printf "%s:%d: non-POSIX echo flag -e\n", FILENAME, FNR; e=1 }
		/(^|[;&| \t])local[ \t]+-[A-Za-z]*a([ \t]|$)/ { printf "%s:%d: bashism local array flag\n", FILENAME, FNR; e=1 }
		END { exit e+0 }
	' "$1"
}

check_scripts() {
	list="$WORK/scripts.list"; : > "$list"
	if [ -d "$TOPDIR/target/linux/airoha/an7581/base-files" ]; then
		find "$TOPDIR/target/linux/airoha/an7581/base-files" -type f | sort | while read -r f; do
			case "$f" in *.conf|*.json|*.txt|*/etc/sysctl.d/*|*/etc/config/*) continue ;; esac
			printf '%s\n' "$f" >> "$list"
		done
	fi
	for f in \
		"$TOPDIR/package/base-files/files/lib/upgrade/fwtool.sh" \
		"$TOPDIR/package/base-files/files/usr/libexec/validate_firmware_image" \
		"$TOPDIR/package/base-files/files/lib/preinit/70_initramfs_test" \
		"$TOPDIR/package/boot/uboot-tools/uboot-envtools/files/airoha_an7581" \
		"$TOPDIR/package/boot/uboot-tools/uboot-envtools/files/uboot-envtools.sh" \
		"$TOPDIR/scripts/flash-gate.sh" "$TOPDIR/scripts/build-preflight.sh"; do
		[ -f "$f" ] && printf '%s\n' "$f" >> "$list"
	done
	for d in "$TOPDIR"/package/luci-app-airoha-*; do
		[ -d "$d" ] || continue
		find "$d" -type f | sort | while read -r f; do
			case "$f" in *.sh) printf '%s\n' "$f" >> "$list"; continue ;; esac
			case "$(head -n 1 "$f" 2>/dev/null || true)" in '#!'*sh*|'#!'*bash*) printf '%s\n' "$f" >> "$list" ;; esac
		done
	done

	checked=0
	while read -r f; do
		[ -n "$f" ] || continue
		shbin=$(interp_for "$f"); [ "$shbin" = skip ] && continue
		"$shbin" -n "$f" 2>"$WORK/syn.err" || fail "$shbin -n failed: $f: $(head -n 1 "$WORK/syn.err")"
		[ "$shbin" = sh ] && { out=$(ash_lint_file "$f") || fail "ash lint: $out"; }
		checked=$((checked + 1))
	done < "$list"
	ok "checked $checked shell scripts (syntax + BusyBox ash lint)"

	py_n=0
	for py in "$TOPDIR"/scripts/check-*.py; do
		[ -f "$py" ] || continue
		PYTHONPYCACHEPREFIX="$WORK/pyc" python3 -m py_compile "$py" 2>"$WORK/py.err" || fail "py_compile: $py: $(head -n 1 "$WORK/py.err")"
		py_n=$((py_n + 1))
	done
	ok "compiled $py_n Python gate script(s)"
}

check_hygiene() {
	[ ! -e "$TOPDIR/docs" ] || fail "forbidden docs/ path exists"
	[ ! -e "$TOPDIR/.github/upstream" ] || fail "forbidden .github/upstream/ path exists"
	for md in "$TOPDIR"/*.md; do
		[ -f "$md" ] || continue
		case "${md##*/}" in README.md|SECURITY.md) ;; *) fail "forbidden extra root markdown: ${md##*/}" ;; esac
	done
	for sub in scripts target/linux/airoha package/boot/uboot-airoha; do
		[ -d "$TOPDIR/$sub" ] || continue
		bad=$(find "$TOPDIR/$sub" -name '*.md' 2>/dev/null)
		[ -z "$bad" ] || fail "forbidden markdown under $sub: $bad"
	done
	ok "repository hygiene verified"
}

check_patch_queue() {
	for d in target/linux/airoha/patches-7.4 package/kernel/mt76/patches; do
		[ -d "$TOPDIR/$d" ] || continue
		dups=$(find "$TOPDIR/$d" -maxdepth 1 -name '*.patch' -exec basename {} \; |
			sed -n 's/^\([0-9][0-9]*\(-[0-9][0-9]*\)*\)-.*/\1/p' | sort | uniq -d)
		[ -z "$dups" ] || fail "$d duplicate numeric prefix(es): $(printf '%s' "$dups" | tr '\n' ' ')"
		for p in "$TOPDIR/$d"/*.patch; do
			[ -f "$p" ] || continue
			awk '/^(diff --git |--- (a\/|\/dev\/null))/{exit} /example\.org|\.local>/{exit 1}' "$p" || fail "$p header contains placeholder email"
			dc=$(awk '/^(diff --git |--- (a\/|\/dev\/null))/{exit} /[0-9]+ files? changed/{c++} END{print c+0}' "$p")
			[ "$dc" -le 1 ] || fail "$p has $dc duplicate diffstat blocks"
		done
	done

	if git -C "$TOPDIR" rev-parse --verify -q "$PATCH_BASE_REF" >/dev/null 2>&1; then
		pdirs='target/linux/airoha/patches-7.4 target/linux/generic/backport-7.4 target/linux/generic/pending-7.4 target/linux/generic/hack-7.4 package/kernel/mt76/patches package/boot/uboot-airoha/patches'
		{ git -C "$TOPDIR" diff --name-only --diff-filter=AM "$PATCH_BASE_REF"..HEAD -- $pdirs
		  git -C "$TOPDIR" diff --cached --name-only --diff-filter=AM -- $pdirs
		  git -C "$TOPDIR" diff --name-only --diff-filter=AM -- $pdirs
		  git -C "$TOPDIR" ls-files --others --exclude-standard -- $pdirs; } | sort -u > "$WORK/changed_patches"
		while read -r rel; do
			[ -f "$TOPDIR/$rel" ] || continue
			case "$rel" in *.patch) ;; *) continue ;; esac
			awk '/^(diff --git |--- (a\/|\/dev\/null))/{exit} /^From: /{f=1} /^Subject: /{s=1} /^Origin: /{o=1}
			     END{ if(!f) print "From:"; if(!s) print "Subject:"; if(!o) print "Origin:" }' "$TOPDIR/$rel" > "$WORK/hdr.miss"
			[ ! -s "$WORK/hdr.miss" ] || fail "$rel missing header(s): $(tr '\n' ' ' < "$WORK/hdr.miss")"
		done < "$WORK/changed_patches"
	fi
	ok "patch-queue prefixes and headers verified"

	src="${TARBALL:-${LINUX_TARBALL:-}}"; ksuf=''
	if [ -z "$src" ]; then
		ksuf=$(awk -F= '/^LINUX_VERSION-7\.4[ \t]*=/{gsub(/[ \t]/,"",$2); print $2; exit}' "$TOPDIR/target/linux/generic/kernel-7.4" 2>/dev/null || true)
		dldir=${DL_DIR:-$TOPDIR/dl}
		for cand in "$dldir/linux-7.4${ksuf}.tar.gz" "$dldir/linux-7.4${ksuf}.tar.xz" "$dldir/linux-7.4${ksuf}.tar.zst" "$dldir/linux-7.4${ksuf}.tar.bz2"; do
			[ -f "$cand" ] && { src=$cand; break; }
		done
	elif [ ! -e "$src" ]; then
		fail "patch-queue source not found: $src"; return
	fi
	[ -n "$src" ] || { printf 'SKIP: Linux 7.4%s tarball not found in %s; pass --patch-queue <tarball-or-dir>\n' "$ksuf" "${DL_DIR:-$TOPDIR/dl}"; return; }

	mkdir -p "$WORK/src"
	if [ -d "$src" ]; then tar -C "$src" -cf - . | tar -C "$WORK/src" -xf - || { fail "copying $src failed"; return; }
	else tar -xf "$src" -C "$WORK/src" --strip-components=1 || { fail "extracting $src failed"; return; }; fi
	for fd in target/linux/generic/files target/linux/generic/files-7.4 target/linux/airoha/files target/linux/airoha/files-7.4; do
		[ -d "$TOPDIR/$fd" ] && cp -a "$TOPDIR/$fd"/. "$WORK/src/"
	done
	applied=0
	for pdir in target/linux/generic/backport-7.4 target/linux/generic/pending-7.4 target/linux/generic/hack-7.4 target/linux/airoha/patches-7.4; do
		[ -d "$TOPDIR/$pdir" ] || continue
		for p in "$TOPDIR/$pdir"/*.patch; do
			[ -f "$p" ] || continue
			if ! ( cd "$WORK/src" && patch -p1 -f -F0 --dry-run -s < "$p" >/dev/null && patch -p1 -f -F0 -s < "$p" >/dev/null ) 2>"$WORK/p.err"; then
				fail "strict fuzz=0 patch failed: ${p#"$TOPDIR"/}: $(head -n 1 "$WORK/p.err")"; return
			fi
			applied=$((applied + 1))
		done
	done
	ok "applied $applied Linux 7.4 patches cleanly with strict fuzz=0 against $src"
}

[ "$DO_DEFAULT" = 1 ] && { check_ascii_topdir; check_scripts; check_hygiene; }
[ "$DO_PATCHES" = 1 ] && check_patch_queue
[ "$FAILS" -eq 0 ] || { printf 'build-preflight: %d failure(s)\n' "$FAILS" >&2; exit 1; }
exit 0
