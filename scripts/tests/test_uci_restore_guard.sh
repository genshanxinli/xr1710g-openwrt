#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Offline regression for scripts/lib/uci-restore-guard.sh.
#
#   sh scripts/tests/test_uci_restore_guard.sh                 # green run
#   UNDER_TEST=/path/to/copy sh scripts/tests/test_uci_restore_guard.sh
#
# UNDER_TEST points the test at another copy of the library - the red half of
# a red/green check.  Delete the restore branch (the cp back to the config, or
# urg_restore_delta) from that copy and this test must FAIL: the config and
# the pending UCI delta would stay as the run left them.
#
# No device, no uci, no wifi: the bench is a staged config file, a staged
# delta file and a fake "wifi" on PATH that records every reload.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LIB=${UNDER_TEST:-$REPO_ROOT/scripts/lib/uci-restore-guard.sh}

printf 'lib under test: %s\n' "$LIB"

if [ ! -f "$LIB" ]; then
	printf 'FAIL: no library at %s\n' "$LIB"
	exit 1
fi

FAILED=0
CHECKS=0

check() {
	CHECKS=$((CHECKS + 1))
	shift_desc=$1
	shift
	if "$@"; then
		printf 'ok   %s\n' "$shift_desc"
	else
		printf 'FAIL %s\n' "$shift_desc"
		FAILED=1
	fi
}

same() {
	cmp -s "$1" "$2"
}

absent() {
	[ ! -e "$1" ]
}

TMP=${TMPDIR:-/tmp}/uci-restore-guard-test.$$
rm -rf "$TMP"
mkdir -p "$TMP/bin" "$TMP/case" || exit 1
trap 'rm -rf "$TMP"' EXIT

# A fake "wifi" that only records the reload.
cat >"$TMP/bin/wifi" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${WIFI_LOG:?}"
exit 0
EOF
chmod +x "$TMP/bin/wifi"

write_config() {
	cat >"$1" <<'EOF'
config wifi-device 'radio2'
	option band '6g'
	option channel '37'
	option htmode 'EHT320'

config wifi-iface 'default_radio2'
	option device 'radio2'
	option ssid 'OpenWrt'
EOF
}

# run_case <driver-body-file> ; the driver gets CFG, DELTA, LIB in its env.
run_case() {
	WIFI_LOG=$TMP/wifi.log
	: >"$WIFI_LOG"
	export WIFI_LOG
	PATH=$TMP/bin:$PATH
	export PATH
	CFG=$TMP/case/wireless
	DELTA=$TMP/case/delta
	URG_DIR=$TMP/case/restore
	URG_DELTA=$DELTA
	export CFG DELTA URG_DIR URG_DELTA
	sh "$1"
	return $?
}

# --- case 1: a run that dies after uci set/commit leaves a delta ----------
write_config "$TMP/case/wireless"
DELTA_SAVED=$TMP/case/delta.orig
: >"$DELTA_SAVED"
rm -f "$TMP/case/delta"
cp -p "$TMP/case/wireless" "$TMP/case/wireless.orig"

cat >"$TMP/case1.sh" <<'EOF'
. "$LIB"
urg_init trap-restore "$CFG"
urg_arm
urg_mark_dirty
printf "\nconfig wifi-iface 'rx6g_1234'\n\toption encryption 'owe'\n" >>"$CFG"
printf "wireless.rx6g_1234=wifi-iface\n" >>"$DELTA"
exit 1
EOF
LIB=$LIB run_case "$TMP/case1.sh"
RC=$?
check 'die after commit keeps the failing exit status' [ "$RC" -eq 1 ]
check 'config file restored byte-for-byte' same "$TMP/case/wireless" "$TMP/case/wireless.orig"
check 'pending UCI delta removed' absent "$TMP/case/delta"
check 'wifi reloaded once from the restore path' \
	[ "$(grep -c reload "$TMP/wifi.log")" -eq 1 ]
check 'snapshot dropped after a verified restore' absent "$TMP/case/restore"

# --- case 2: a delta that existed before the run is put back --------------
cp -p "$TMP/case/wireless.orig" "$TMP/case/wireless"
printf "wireless.stale=wifi-iface\n" >"$TMP/case/delta"
cp -p "$TMP/case/delta" "$TMP/case/delta.orig"

cat >"$TMP/case2.sh" <<'EOF'
. "$LIB"
urg_init trap-restore "$CFG"
urg_arm
urg_mark_dirty
printf "wireless.other=wifi-iface\n" >"$DELTA"
exit 1
EOF
LIB=$LIB run_case "$TMP/case2.sh"
check 'pre-existing delta content restored' same "$TMP/case/delta" "$TMP/case/delta.orig"

# --- case 3: a clean run (urg_disarm) keeps the write and the delta -------
cp -p "$TMP/case/wireless.orig" "$TMP/case/wireless"
rm -f "$TMP/case/delta"
cat >"$TMP/case3.sh" <<'EOF'
. "$LIB"
urg_init clean-run "$CFG"
urg_arm
urg_mark_dirty
printf "\nconfig wifi-iface 'kept'\n" >>"$CFG"
urg_disarm
exit 0
EOF
LIB=$LIB run_case "$TMP/case3.sh"
RC=$?
check 'clean run exits 0' [ "$RC" -eq 0 ]
check 'clean run keeps its own write' \
	grep -q "config wifi-iface 'kept'" "$TMP/case/wireless"
check 'clean run does not reload' [ ! -s "$TMP/wifi.log" ]

# --- case 4: no write, no restore, no reload -----------------------------
cp -p "$TMP/case/wireless.orig" "$TMP/case/wireless"
cat >"$TMP/case4.sh" <<'EOF'
. "$LIB"
urg_init untouched "$CFG"
urg_arm
exit 0
EOF
LIB=$LIB run_case "$TMP/case4.sh"
RC=$?
check 'untouched run exits 0' [ "$RC" -eq 0 ]
check 'untouched run does not reload' [ ! -s "$TMP/wifi.log" ]
check 'untouched run leaves the config alone' same "$TMP/case/wireless" "$TMP/case/wireless.orig"

# --- case 5: a failed snapshot must not destroy the previous restore point
# $URG_DIR is deliberately persistent: it is the evidence a crashed run left
# behind, and the library promises to keep it when a restore fails.  A later
# urg_init that cannot snapshot used to run "rm -rf $URG_DIR" *before* the
# mkdir/cp, so an ENOSPC left neither the old restore point nor a new one.
cp -p "$TMP/case/wireless.orig" "$TMP/case/wireless"
rm -rf "$TMP/case/restore"
mkdir -p "$TMP/case/restore"
printf 'previous restore point\n' >"$TMP/case/restore/wireless.bak"
printf 'deadbeef\n' >"$TMP/case/restore/wireless.md5"
cp -p "$TMP/case/restore/wireless.bak" "$TMP/case/restore.bak"

mkdir -p "$TMP/bin-failcp"
REAL_CP=$(command -v cp)
cat >"$TMP/bin-failcp/cp" <<EOF
#!/bin/sh
case \$* in
*"$TMP/case/wireless"*) printf 'cp: simulated ENOSPC\n' >&2; exit 1 ;;
esac
exec "$REAL_CP" "\$@"
EOF
chmod +x "$TMP/bin-failcp/cp"

no_leftovers() {
	[ -z "$(ls -d "$1".new.* "$1".old.* 2>/dev/null)" ]
}

cat >"$TMP/case5.sh" <<'EOF'
. "$LIB"
urg_init trap-restore "$CFG"
printf 'init_rc=%s\n' "$?"
EOF
CFG=$TMP/case/wireless DELTA=$TMP/case/delta URG_DIR=$TMP/case/restore \
	URG_DELTA=$DELTA LIB=$LIB PATH=$TMP/bin-failcp:$PATH \
	sh "$TMP/case5.sh" >"$TMP/case5.out" 2>"$TMP/case5.err"
check 'a failed snapshot fails urg_init' \
	grep -q 'init_rc=1' "$TMP/case5.out"
check 'a failed snapshot keeps the previous restore point' \
	same "$TMP/case/restore/wireless.bak" "$TMP/case/restore.bak"
check 'a failed snapshot leaves no staging directory behind' \
	no_leftovers "$TMP/case/restore"
check 'the failed snapshot says why' grep -q 'cannot snapshot' "$TMP/case5.err"

# --- case 6: a successful snapshot replaces the previous restore point -----
printf 'stale\n' >"$TMP/case/restore/wireless.bak"
rm -f "$TMP/case/restore/wireless.md5"
cat >"$TMP/case6.sh" <<'EOF'
. "$LIB"
urg_init replacement "$CFG"
printf 'init_rc=%s\n' "$?"
EOF
CFG=$TMP/case/wireless DELTA=$TMP/case/delta URG_DIR=$TMP/case/restore \
	URG_DELTA=$DELTA LIB=$LIB \
	sh "$TMP/case6.sh" >"$TMP/case6.out" 2>&1
check 'a clean snapshot succeeds over an old restore point' \
	grep -q 'init_rc=0' "$TMP/case6.out"
check 'the new restore point holds the current config' \
	same "$TMP/case/restore/wireless.bak" "$TMP/case/wireless"
check 'the new restore point carries its md5 file' \
	[ -s "$TMP/case/restore/wireless.md5" ]
check 'a clean snapshot leaves no staging directory behind' \
	no_leftovers "$TMP/case/restore"


# --- the callers must keep the wiring --------------------------------------
# A script that drops the ". .../uci-restore-guard.sh" line, or stops calling
# urg_init / urg_restore_delta, silently goes back to restoring the file only.
wired() {
	_script=$REPO_ROOT/scripts/wireless/$1
	[ -f "$_script" ] || { printf '      missing %s\n' "$_script"; return 1; }
	grep -q 'uci-restore-guard\.sh' "$_script" || {
		printf '      %s does not source the guard\n' "$_script"
		return 1
	}
	grep -q 'urg_init' "$_script" && grep -q 'urg_restore_delta' "$_script"
}

check '6g-rx.sh restores the pending UCI delta' wired 6g-rx.sh
check 'edca-6g-ab.sh restores the pending UCI delta' wired edca-6g-ab.sh

printf '\n%d checks, %s\n' "$CHECKS" \
	"$([ "$FAILED" -eq 0 ] && echo PASSED || echo FAILED)"
[ "$FAILED" -eq 0 ]
