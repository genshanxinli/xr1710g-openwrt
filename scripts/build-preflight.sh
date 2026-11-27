#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Pre-build gate: ASCII TOPDIR, shell/python syntax, BusyBox ash lint, LuCI ACL, repo hygiene, and --patch-queue.
set -u

TOPDIR=${TOPDIR:-$PWD}
PATCH_BASE_REF=${PATCH_BASE_REF:-db9128c34652317cfbfffdf71e2b813edbe0cf0e}
PATCH_FORMAT_BASE_REF=${PATCH_FORMAT_BASE_REF:-a0d2179730edacfd6791a5e341936134b61c43b3}
DRY_RUN=0; DO_DEFAULT=1; DO_PATCHES=0; REQUIRE_TARBALL=0; TARBALL=''; FAILS=0; WORK=''

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

usage() {
	cat <<'EOF'
Usage:
  build-preflight.sh [--dry-run]                                         pre-build PATH, ASCII TOPDIR, syntax, ash lint, hygiene
  build-preflight.sh --patch-queue [--require-tarball] [tarball-or-dir]  patch prefix, header, and strict fuzz=0 check
  build-preflight.sh --all [--require-tarball] [tarball-or-dir]          run both gates
EOF
}

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
ok() { printf 'OK: %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	--dry-run) DRY_RUN=1; shift ;;
	--require-tarball) REQUIRE_TARBALL=1; shift ;;
	--patch-queue) DO_DEFAULT=0; DO_PATCHES=1; shift ;;
	--all) DO_DEFAULT=1; DO_PATCHES=1; shift ;;
	-*) usage >&2; exit 2 ;;
	*) [ "$DO_PATCHES" = 1 ] && [ -z "$TARBALL" ] && { TARBALL=$1; shift; } || { usage >&2; exit 2; } ;;
	esac
done

check_path() {
	_p=${PATH:-}
	_bad=''
	if [ -z "$_p" ]; then
		_bad='PATH is empty'
	else
		_tab=$(printf '\t')
		_cr=$(printf '\r')
		_nl='
'
		_rest="${_p}:"
		while [ -n "$_rest" ]; do
			_seg=${_rest%%:*}
			_rest=${_rest#*:}
			case "$_seg" in
			'') _bad='empty PATH segment (leading/trailing or ::)'; break ;;
			*' '*|*"$_tab"*|*"$_cr"*|*"$_nl"*) _bad="whitespace in PATH entry: '$_seg'"; break ;;
			/*) ;;
			*) _bad="relative PATH entry: '$_seg'"; break ;;
			esac
		done
	fi
	if [ -n "$_bad" ]; then
		_hint='export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
		if [ -n "$_p" ] && { [ "$DRY_RUN" = 1 ] || [ "${SKIP_PATH_CHECK:-0}" = 1 ]; }; then
			printf 'WARN: %s (run: %s)\n' "$_bad" "$_hint" >&2
		else
			fail "$_bad (breaks find -execdir in package/install; run: $_hint)"
			exit 1
		fi
	else
		ok "PATH is clean POSIX"
	fi
}

[ "$DO_DEFAULT" = 1 ] && check_path

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
	for bd in "$TOPDIR/target/linux/airoha/base-files" "$TOPDIR/target/linux/airoha/an7581/base-files"; do
		[ -d "$bd" ] || continue
		find "$bd" -type f | LC_ALL=C sort | while read -r f; do
			case "$f" in *.conf|*.json|*.txt|*/etc/sysctl.d/*|*/etc/config/*) continue ;; esac
			printf '%s\n' "$f" >> "$list"
		done
	done
	for f in \
		"$TOPDIR/package/base-files/files/lib/upgrade/fwtool.sh" \
		"$TOPDIR/package/base-files/files/usr/libexec/validate_firmware_image" \
		"$TOPDIR/package/base-files/files/lib/preinit/70_initramfs_test" \
		"$TOPDIR/package/boot/uboot-tools/uboot-envtools/files/airoha_an7581" \
		"$TOPDIR/package/boot/uboot-tools/uboot-envtools/files/uboot-envtools.sh" \
		"$TOPDIR/package/network/services/hostapd/files/wpad.init" \
		"$TOPDIR/package/network/config/netifd/files/etc/init.d/network" \
		"$TOPDIR/scripts/flash-gate.sh" "$TOPDIR/scripts/build-preflight.sh"; do
		[ -f "$f" ] && printf '%s\n' "$f" >> "$list"
	done
	for d in "$TOPDIR"/package/luci-app-*; do
		[ -d "$d" ] || continue
		find "$d" -type f | LC_ALL=C sort | while read -r f; do
			case "$f" in *.sh) printf '%s\n' "$f" >> "$list"; continue ;; esac
			case "$(head -n 1 "$f" 2>/dev/null || true)" in '#!'*sh*) printf '%s\n' "$f" >> "$list" ;; esac
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
	# Upstream scripts using BusyBox-specific constructs (e.g., dnsmasq.init echo -e): syntax-check only.
	for f in \
		"$TOPDIR/package/network/config/wifi-scripts/files/lib/netifd/hostapd.sh" \
		"$TOPDIR/package/network/config/wifi-scripts/files/lib/netifd/wireless/mac80211.sh" \
		"$TOPDIR/package/network/services/dnsmasq/files/dnsmasq.init"; do
		[ -f "$f" ] || continue
		sh -n "$f" 2>"$WORK/syn.err" || fail "sh -n failed: $f: $(head -n 1 "$WORK/syn.err")"
		checked=$((checked + 1))
	done
	ok "checked $checked shell scripts (syntax + BusyBox ash lint)"

	if menu_out=$(python3 - "$TOPDIR" 2>&1 <<'PY'
import glob, json, os, sys
top, bad = sys.argv[1], []
files = sorted(glob.glob(os.path.join(top, "package/luci-app-*/root/usr/share/luci/menu.d/*.json")))
for p in files:
    rel = os.path.relpath(p, top)
    try:
        with open(p, encoding="utf-8") as f:
            obj = json.load(f)
        if not isinstance(obj, dict):
            bad.append(f"{rel}: top-level JSON must be object")
    except Exception as e:
        bad.append(f"{rel}: invalid JSON ({e})")
if bad:
    print("; ".join(bad)); sys.exit(1)
print(len(files))
PY
	); then
		ok "validated $menu_out LuCI menu JSON file(s)"
	else
		fail "LuCI menu JSON syntax: $menu_out"
	fi

	py_n=0
	for py in "$TOPDIR"/scripts/check-*.py; do
		[ -f "$py" ] || continue
		PYTHONPYCACHEPREFIX="$WORK/pyc" python3 -m py_compile "$py" 2>"$WORK/py.err" || fail "py_compile: $py: $(head -n 1 "$WORK/py.err")"
		py_n=$((py_n + 1))
	done
	ok "compiled $py_n Python gate script(s)"
}

check_hygiene() {
	hyg_before=$FAILS
	if [ -e "$TOPDIR/.git" ] && git -C "$TOPDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$TOPDIR" -c core.quotepath=false ls-files --cached --others --exclude-standard > "$WORK/hygiene.files"
	else
		( cd "$TOPDIR" && find . \( -path './.git' -o -path './.scratch' -o -path './build_dir' -o -path './staging_dir' -o -path './dl' -o -path './bin' -o -path './tmp' -o -path './logs' -o -path './feeds' \) -prune -o -print 2>/dev/null ) |
			sed '/^\.$/d; s|^\./||' > "$WORK/hygiene.files"
	fi
	while IFS= read -r p; do
		case "$p" in
		docs|docs/*|.github/upstream|.github/upstream/*|.scratch|.scratch/*|AGENTS.md|serial|serial/*|bench-*|pppoe-4path*)
			fail "forbidden path: $p" ;;
		scripts/wireless|scripts/wireless/*|scripts/claims.yaml|scripts/claims-verify.py|scripts/check-claims.py|scripts/bench-*|scripts/pppoe-4path*|scripts/serial|scripts/serial/*)
			fail "forbidden path: $p" ;;
		target/linux/*/patches-7.3|target/linux/*/patches-7.3/*|target/linux/*/config-7.3|target/linux/*/config-7.3/*)
			fail "forbidden path: $p" ;;
		scripts/*.md|target/linux/airoha/*.md|package/boot/uboot-airoha/*.md)
			fail "forbidden path: $p" ;;
		*/*|README.md|SECURITY.md) ;;
		*.md) fail "forbidden path: $p" ;;
		esac
	done < "$WORK/hygiene.files"
	if acl_out=$(python3 - "$TOPDIR" 2>&1 <<'PY'
import fnmatch, glob, json, os, posixpath, re, sys
top, bad = sys.argv[1], []
FORBID_SUBSTR = ("/bin/sh", "/bin/ash", "/bin/busybox", "/dev/mem")
SENSITIVE_PFX = ("/etc/sysctl.d", "/dev", "/bin", "/sbin", "/usr")
UC_TOK = re.compile(r"""'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`|/\*.*?\*/|//[^\n]*""", re.DOTALL)
SH_TOK = re.compile(r"""'[^']*'|"(?:\\.|[^"\\])*"|\\.|(?:^|(?<=[\s;&|()]))#[^\n]*""", re.MULTILINE)
DEVMEM_RE = re.compile(r"/dev/mem|\bdevmem\b")
def norm_path(p):
    return re.sub(r"/+", "/", posixpath.normpath(p.strip()))
def is_sensitive(p):
    n = norm_path(p)
    return any(n == x or n.startswith(x + "/") for x in SENSITIVE_PFX)
def walk(o):
    if isinstance(o, dict): return [x for kv in o.items() for c in kv for x in walk(c)]
    if isinstance(o, list): return [x for v in o for x in walk(v)]
    return [o] if isinstance(o, str) else []
def strip_comments(txt, is_uc):
    if is_uc:
        return UC_TOK.sub(lambda m: "" if m.group(0).startswith(("/*", "//")) else m.group(0), txt)
    return SH_TOK.sub(lambda m: "" if m.group(0).startswith("#") else m.group(0), txt)

files = sorted(glob.glob(os.path.join(top, "package/luci-app-*/root/usr/share/rpcd/acl.d/*.json")))
if not files:
    print("no LuCI ACL files found"); sys.exit(1)
for p in files:
    rel = os.path.relpath(p, top)
    try:
        with open(p, encoding="utf-8") as f: data = json.load(f)
    except Exception as e:
        bad.append(f"{rel}: invalid JSON ({e})"); continue
    if not isinstance(data, dict):
        bad.append(f"{rel}: ACL root must be JSON object"); continue
    toks = walk(data)
    hits = [t for t in FORBID_SUBSTR if any(t in s for s in toks)]
    if "exec" in toks: hits.append("exec")
    for entry in data.values():
        if not isinstance(entry, dict): continue
        for sec, block in entry.items():
            if not isinstance(block, dict): continue
            ubus = block.get("ubus")
            if isinstance(ubus, dict):
                for obj, meths in ubus.items():
                    if "*" in str(obj): hits.append(f"wildcard ubus object {obj!r}")
                    if isinstance(meths, list):
                        for m in meths:
                            if "*" in str(m): hits.append(f"wildcard ubus method {obj}.{m}")
            uci = block.get("uci")
            if isinstance(uci, (list, dict)):
                for c in uci:
                    if "*" in str(c): hits.append(f"wildcard uci {c!r}")
            fmap = block.get("file")
            if isinstance(fmap, dict):
                for fpath, perms in fmap.items():
                    sp = str(fpath).strip()
                    np = norm_path(sp)
                    if sp in ("*", "/*") or np in ("*", "/", "/*", "/**"):
                        hits.append(f"wildcard file {sp!r}")
                    for t in FORBID_SUBSTR:
                        if t == np or t in np or fnmatch.fnmatchcase(t, np):
                            hits.append(f"forbidden file pattern {sp!r}")
                    plist = perms if isinstance(perms, list) else [perms]
                    if any(str(pm) == "*" for pm in plist): hits.append(f"wildcard file perm on {sp!r}")
                    if is_sensitive(sp) and (sec == "write" or any(str(pm) in ("write", "exec") for pm in plist)):
                        hits.append(f"write/exec on sensitive path {sp!r}")
    if hits: bad.append(f"{rel}: forbidden {', '.join(dict.fromkeys(hits))}")

rpcd_files = sorted(
    p for p in (
        glob.glob(os.path.join(top, "package/luci-app-*/root/usr/share/rpcd/ucode/*")) +
        glob.glob(os.path.join(top, "package/luci-app-*/root/usr/libexec/rpcd/*"))
    ) if os.path.isfile(p)
)
for p in rpcd_files:
    rel = os.path.relpath(p, top)
    with open(p, encoding="utf-8", errors="replace") as f:
        code = strip_comments(f.read(), p.endswith(".uc"))
    if DEVMEM_RE.search(code):
        bad.append(f"{rel}: forbidden devmem or /dev/mem invocation")

if bad: print("; ".join(bad)); sys.exit(1)
print(f"{len(files)} ACL + {len(rpcd_files)} RPCD")
PY
	); then
		ok "checked $acl_out file(s)"
	else
		fail "LuCI ACL/RPCD security: $acl_out"
	fi
	[ "$FAILS" -eq "$hyg_before" ] && ok "repository hygiene verified"
}

check_luci_conffiles() {
	lc_before=$FAILS
	lc_checked=0
	for d in "$TOPDIR"/package/luci-app-*; do
		[ -d "$d" ] || continue
		mk="$d/Makefile"
		[ -f "$mk" ] || continue
		lc_checked=$((lc_checked + 1))
		rel=${mk#"$TOPDIR"/}
		printf '#cfgs\n' > "$WORK/luci_cfgs"
		if [ -d "$d/root/etc/config" ]; then
			( cd "$d/root" && find etc/config \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort | sed 's|^|/|' ) >> "$WORK/luci_cfgs"
		fi
		if ! awk -v rel="$rel" '
			NR == FNR {
				if (FNR > 1 && $0 != "") cfg[++n_cfg] = $0
				next
			}
			{ sub(/\r$/, "") }
			/^[ \t]*#/ { next }
			in_conf {
				if (/^[ \t]*endef([ \t#]|$)/) {
					in_conf = 0
					next
				}
				line = $0
				sub(/[ \t]*#.*$/, "", line)
				sub(/^[ \t]+/, "", line)
				sub(/[ \t]+$/, "", line)
				if (line != "") decl[line] = 1
				next
			}
			!inc && /^[ \t]*PKG_NAME[ \t]*[:+?]?=/ { pkg_set = 1 }
			!inc && /^[ \t]*LUCI_NAME[ \t]*[:+?]?=/ { luci_set = 1 }
			!inc && /^[ \t]*(-|s)?include[ \t]+.*luci\.mk([ \t#]|$)/ {
				inc = FNR
				next
			}
			/^[ \t]*(override[ \t]+)?define[ \t]+Package\/[^ \t#=:+?]+\/conffiles([ \t#=:+?]|$)/ {
				if (inc > 0) {
					printf "%s:%d: define Package/.../conffiles after include luci.mk (line %d)\n", rel, FNR, inc
					e = 1
					next
				}
				if (!pkg_set && ($0 ~ /Package\/\$\(PKG_NAME\)\/conffiles/ || $0 ~ /Package\/\$\{PKG_NAME\}\/conffiles/)) {
					printf "%s:%d: Package/$(PKG_NAME)/conffiles used before PKG_NAME is set\n", rel, FNR
					e = 1
				}
				if (!luci_set && ($0 ~ /Package\/\$\(LUCI_NAME\)\/conffiles/ || $0 ~ /Package\/\$\{LUCI_NAME\}\/conffiles/)) {
					printf "%s:%d: Package/$(LUCI_NAME)/conffiles used before LUCI_NAME is set\n", rel, FNR
					e = 1
				}
				before = FNR
				in_conf = 1
				next
			}
			END {
				if (in_conf) {
					printf "%s: unterminated define Package/.../conffiles block\n", rel
					e = 1
				}
				if (n_cfg > 0) {
					if (!before) {
						if (inc > 0)
							printf "%s: ships root/etc/config/* without define Package/.../conffiles before include luci.mk (line %d)\n", rel, inc
						else
							printf "%s: ships root/etc/config/* without define Package/.../conffiles\n", rel
						e = 1
					} else {
						for (i = 1; i <= n_cfg; i++) {
							c = cfg[i]
							if (!(c in decl) && !("/etc/config" in decl) && !("/etc/config/" in decl)) {
								printf "%s: conffiles before luci.mk missing %s\n", rel, c
								e = 1
							}
						}
					}
				}
				exit e + 0
			}
		' "$WORK/luci_cfgs" "$mk" > "$WORK/luci_cfgs.err" 2>&1; then
			if [ -s "$WORK/luci_cfgs.err" ]; then
				while IFS= read -r _e; do
					[ -n "$_e" ] && fail "LuCI conffiles: $_e"
				done < "$WORK/luci_cfgs.err"
			else
				fail "LuCI conffiles: check failed on $rel"
			fi
		fi
	done
	if [ "$lc_checked" -eq 0 ]; then
		fail "no package/luci-app-*/Makefile found"
	elif [ "$FAILS" -eq "$lc_before" ]; then
		ok "checked $lc_checked LuCI app Makefile(s) for conffiles ordering"
	fi
}

changed_patches_since() {
	_ref=$1; shift
	{ git -C "$TOPDIR" diff -M --name-only --diff-filter=AMR "$_ref"..HEAD -- "$@"
	  git -C "$TOPDIR" diff -M --cached --name-only --diff-filter=AMR -- "$@"
	  git -C "$TOPDIR" diff -M --name-only --diff-filter=AMR -- "$@"
	  git -C "$TOPDIR" ls-files --others --exclude-standard -- "$@"; } | LC_ALL=C sort -u
}

check_linux_patch_queue() {
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
	if [ -z "$src" ]; then
		if [ "$REQUIRE_TARBALL" = 1 ]; then
			fail "Linux 7.4${ksuf} tarball not found in ${DL_DIR:-$TOPDIR/dl} (--require-tarball)"
		else
			printf 'SKIP: Linux 7.4%s tarball not found in %s; pass --patch-queue <tarball-or-dir>\n' "$ksuf" "${DL_DIR:-$TOPDIR/dl}"
		fi
		return
	fi

	if [ -d "$src" ]; then
		if [ ! -f "$src/Makefile" ] || [ ! -d "$src/drivers" ]; then
			fail "patch-queue source directory is not a Linux kernel tree (missing Makefile or drivers/): $src"
			return
		fi
	fi
	mkdir -p "$WORK/src"
	if [ -d "$src" ]; then tar -C "$src" -cf - . | tar -C "$WORK/src" -xf - || { fail "copying $src failed"; return; }
	else tar -xf "$src" -C "$WORK/src" --strip-components=1 || { fail "extracting $src failed"; return; }; fi
	for fd in target/linux/generic/files target/linux/generic/files-7.4 target/linux/airoha/files target/linux/airoha/files-7.4; do
		[ -d "$TOPDIR/$fd" ] && cp -a "$TOPDIR/$fd"/. "$WORK/src/"
	done
	applied=0
	for pdir in target/linux/generic/backport-7.4 target/linux/generic/pending-7.4 target/linux/generic/hack-7.4 target/linux/airoha/patches-7.4; do
		[ -d "$TOPDIR/$pdir" ] || continue
		find "$TOPDIR/$pdir" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort > "$WORK/pdir_patches"
		while IFS= read -r p; do
			[ -f "$p" ] || continue
			if ! ( cd "$WORK/src" && patch -p1 -f -F0 --dry-run -s < "$p" >/dev/null && patch -p1 -f -F0 -s < "$p" >/dev/null ) 2>"$WORK/p.err"; then
				fail "strict fuzz=0 patch failed: ${p#"$TOPDIR"/}: $(head -n 1 "$WORK/p.err")"; return
			fi
			applied=$((applied + 1))
		done < "$WORK/pdir_patches"
	done
	ok "applied $applied Linux 7.4 patches cleanly with strict fuzz=0 against $src"
}

check_uboot_patch_queue() {
	ubdir="$TOPDIR/package/boot/uboot-airoha/patches"
	[ -d "$ubdir" ] || return
	ubver=$(awk '/^PKG_VERSION[ \t]*:?=/{sub(/^[^=]*=[ \t]*/,""); gsub(/[ \t\r]/,""); print; exit}' "$TOPDIR/package/boot/uboot-airoha/Makefile" 2>/dev/null || true)
	ubsrc=${UBOOT_TARBALL:-}
	if [ -z "$ubsrc" ] && [ -n "$ubver" ]; then
		dldir=${DL_DIR:-$TOPDIR/dl}
		for cand in "$dldir/u-boot-${ubver}.tar.bz2" "$dldir/u-boot-${ubver}.tar.gz" "$dldir/u-boot-${ubver}.tar.xz" "$dldir/u-boot-${ubver}.tar.zst"; do
			[ -f "$cand" ] && { ubsrc=$cand; break; }
		done
	elif [ -n "$ubsrc" ] && [ ! -e "$ubsrc" ]; then
		fail "U-Boot patch-queue source not found: $ubsrc"; return
	fi
	if [ -z "$ubsrc" ]; then
		if [ "$REQUIRE_TARBALL" = 1 ]; then
			fail "U-Boot ${ubver} tarball not found in ${DL_DIR:-$TOPDIR/dl} (--require-tarball; set UBOOT_TARBALL or DL_DIR)"
		else
			printf 'SKIP: U-Boot %s tarball not found in %s; set UBOOT_TARBALL or DL_DIR\n' "$ubver" "${DL_DIR:-$TOPDIR/dl}"
		fi
		return
	fi

	if [ -d "$ubsrc" ]; then
		if [ ! -f "$ubsrc/Makefile" ] || [ ! -d "$ubsrc/cmd" ]; then
			fail "U-Boot patch-queue source directory is not a U-Boot tree (missing Makefile or cmd/): $ubsrc"
			return
		fi
	fi
	mkdir -p "$WORK/uboot-src"
	if [ -d "$ubsrc" ]; then
		tar -C "$ubsrc" -cf - . | tar -C "$WORK/uboot-src" -xf - || { fail "copying $ubsrc failed"; return; }
	else
		tar -xf "$ubsrc" -C "$WORK/uboot-src" --strip-components=1 || { fail "extracting $ubsrc failed"; return; }
	fi
	[ -d "$TOPDIR/package/boot/uboot-airoha/files" ] && cp -a "$TOPDIR/package/boot/uboot-airoha/files"/. "$WORK/uboot-src/"
	ub_applied=0
	find "$ubdir" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort > "$WORK/uboot_patches"
	while IFS= read -r p; do
		[ -f "$p" ] || continue
		if ! ( cd "$WORK/uboot-src" && patch -p1 -f -F0 --dry-run -s < "$p" >/dev/null && patch -p1 -f -F0 -s < "$p" >/dev/null ) 2>"$WORK/ub.err"; then
			fail "strict fuzz=0 U-Boot patch failed: ${p#"$TOPDIR"/}: $(head -n 1 "$WORK/ub.err")"; return
		fi
		ub_applied=$((ub_applied + 1))
	done < "$WORK/uboot_patches"
	ok "applied $ub_applied U-Boot ${ubver} patches cleanly with strict fuzz=0 against $ubsrc"
}

check_patch_dir() {
	_d=$1
	[ -d "$TOPDIR/$_d" ] || return 0
	dups=$(find "$TOPDIR/$_d" -maxdepth 1 -type f -name '*.patch' -exec basename {} \; |
		sed -n 's/^\([0-9][0-9]*\(-[0-9][0-9]*\)*\)-.*/\1/p' | LC_ALL=C sort | uniq -d)
	if [ -n "$dups" ]; then
		_bad=''
		for _pfx in $dups; do
			if [ "${_d#package/kernel/mac80211/patches/}" != "$_d" ] && \
			   git -C "$TOPDIR" rev-parse --verify -q "$PATCH_BASE_REF" >/dev/null 2>&1; then
				_cur=$(find "$TOPDIR/$_d" -maxdepth 1 -type f -name "${_pfx}-*.patch" -exec basename {} \; |
					grep -Ev "^${_pfx}-[0-9]+-" | LC_ALL=C sort || true)
				_base=$(git -C "$TOPDIR" ls-tree --name-only "$PATCH_BASE_REF" "$_d/" 2>/dev/null |
					sed 's|.*/||' | grep -E "^${_pfx}-.*\.patch$" | grep -Ev "^${_pfx}-[0-9]+-" | LC_ALL=C sort || true)
				if [ -n "$_base" ] && [ "$_cur" = "$_base" ]; then
					continue
				fi
			fi
			_bad="${_bad:+$_bad }$_pfx"
		done
		[ -z "$_bad" ] || fail "$_d duplicate numeric prefix(es): $_bad"
	fi
	find "$TOPDIR/$_d" -maxdepth 1 -type f -name '*.patch' -exec awk '
		function flush() {
			if (cur == "") return
			if (ph) printf "%s header contains placeholder email\n", cur
			if (dc > 1) printf "%s has %d duplicate diffstat blocks\n", cur, dc
		}
		FNR == 1 { flush(); cur = FILENAME; in_hdr = 1; ph = 0; dc = 0 }
		!in_hdr { next }
		/^(diff --git |--- (a\/|\/dev\/null))/ { in_hdr = 0; next }
		/example\.org|\.local>/ { ph = 1 }
		/[0-9]+ files? changed/ { dc++ }
		END { flush() }
	' {} + > "$WORK/dir_hdr.err"
	while IFS= read -r _e; do
		[ -n "$_e" ] && fail "$_e"
	done < "$WORK/dir_hdr.err"
}

check_patch_queue() {
	pq_fails=$FAILS
	for d in \
		target/linux/airoha/patches-7.4 \
		package/kernel/mt76/patches \
		package/boot/uboot-airoha/patches \
		package/firmware/wireless-regdb/patches \
		package/libs/libnftnl/patches \
		package/network/utils/nftables/patches \
		package/network/config/firewall4/patches \
		package/network/utils/fullconenat-nft/patches \
		package/system/procd/patches \
		tools/fakeroot/patches \
		package/network/services/hostapd/patches; do
		check_patch_dir "$d"
	done
	for sub in "$TOPDIR"/package/kernel/mac80211/patches/*; do
		[ -d "$sub" ] || continue
		check_patch_dir "${sub#"$TOPDIR"/}"
	done

	set -- \
		target/linux/airoha/patches-7.4 \
		target/linux/generic/backport-7.4 \
		target/linux/generic/pending-7.4 \
		target/linux/generic/hack-7.4 \
		package/kernel/mt76/patches \
		package/boot/uboot-airoha/patches \
		package/firmware/wireless-regdb/patches \
		package/libs/libnftnl/patches \
		package/network/utils/nftables/patches \
		package/network/services/hostapd/patches \
		package/kernel/mac80211/patches \
		package/network/config/firewall4/patches \
		package/network/utils/fullconenat-nft/patches \
		package/system/procd/patches \
		tools/fakeroot/patches
	if git -C "$TOPDIR" rev-parse --verify -q "$PATCH_BASE_REF" >/dev/null 2>&1; then
		changed_patches_since "$PATCH_BASE_REF" "$@" > "$WORK/changed_patches"
		while IFS= read -r rel; do
			[ -f "$TOPDIR/$rel" ] || continue
			case "$rel" in *.patch) ;; *) continue ;; esac
			awk '/^(diff --git |--- (a\/|\/dev\/null))/{exit} /^From: /{f=1} /^Subject: /{s=1} /^Origin: /{o=1}
			     END{ if(!f) print "From:"; if(!s) print "Subject:"; if(!o) print "Origin:" }' "$TOPDIR/$rel" > "$WORK/hdr.miss"
			[ ! -s "$WORK/hdr.miss" ] || fail "$rel missing header(s): $(tr '\n' ' ' < "$WORK/hdr.miss")"
		done < "$WORK/changed_patches"
	fi
	if git -C "$TOPDIR" rev-parse --verify -q "$PATCH_FORMAT_BASE_REF" >/dev/null 2>&1; then
		changed_patches_since "$PATCH_FORMAT_BASE_REF" "$@" > "$WORK/format_patches"
		while IFS= read -r rel; do
			[ -f "$TOPDIR/$rel" ] || continue
			case "$rel" in *.patch) ;; *) continue ;; esac
			bad=$(awk 'NR==1 && /^From [0-9a-f]+ Mon Sep 17/ && length($2)==40 { m=1 }
			           f && /^[0-9]+\.[0-9]+/ { g=1 }
			           { f = ($0 == "-- ") ? 1 : 0 }
			           END { o = (m ? "From-mbox" : ""); if (g) o = (o ? o " " : "") "git-footer"; if (o) print o }' "$TOPDIR/$rel")
			[ -z "$bad" ] || fail "$rel contains git format-patch artifact(s): $bad"
		done < "$WORK/format_patches"
	fi
	[ "$FAILS" -eq "$pq_fails" ] && ok "patch-queue prefixes and headers verified"

	check_linux_patch_queue
	check_uboot_patch_queue
}

[ "$DO_DEFAULT" = 1 ] && { check_ascii_topdir; check_scripts; check_hygiene; check_luci_conffiles; }
[ "$DO_PATCHES" = 1 ] && check_patch_queue
[ "$FAILS" -eq 0 ] || { printf 'build-preflight: %d failure(s)\n' "$FAILS" >&2; exit 1; }
exit 0
