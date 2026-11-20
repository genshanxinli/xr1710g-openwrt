#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Offline test for scripts/pppoe-4path.sh.
#
# Nothing here touches a device, a PPPoE peer or the real network: ssh, ip,
# iptables, nft, pppoe-server and iperf3 are replaced by fakes in a temporary
# PATH prefix, and the fake "device" is driven by FAKE_SCENARIO:
#
#   ppp        a ppp* netdev appears, all four arms run, cleanup must kill
#   noppp      no ppp* netdev ever appears -> refuse, no numbers
#   preflight  the device reports iperf3 missing -> refuse before dialing
#   nolisten   session comes up but the arm's listener never does -> arm invalid
#
# It asserts:
#   (a) refusal when no ppp* netdev exists, naming that precondition
#   (b) the four arms are emitted in order with the right labels
#   (c) cleanup kills the iperf3 servers it started (EXIT, INT, TERM)
#   (d) --dry-run exits 0 and needs no ssh/iperf3
# `sh scripts/tests/test_pppoe_4path.sh` must not quietly change the semantics:
# job control (`set -m`) is what gives the harness a real SIGINT disposition,
# and /bin/sh cannot do that without a tty.  Re-exec instead of guessing.
case ${BASH_VERSION:-} in
'') exec bash "$0" "$@" ;;
esac
set -u
LC_ALL=C
export LC_ALL
MAIN_PID=$$

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${PPPOE4PATH_SCRIPT:-$HERE/../pppoe-4path.sh}
[ -x "$SCRIPT" ] || { printf 'not executable: %s\n' "$SCRIPT" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pppoe-4path-test.XXXXXX") || exit 1
BIN=$TMP/bin
STATE=$TMP/state
PORT_BASE=5531

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

# Kill whatever a failed assertion left running, then remove the scratch dir.
kill_survivors() {
	for f in "$STATE"/host-procs "$STATE"/dev-procs; do
		[ -f "$f" ] || continue
		while read -r p; do
			[ -n "$p" ] && kill "$p" 2>/dev/null
		done <"$f"
	done
	[ -f "$TMP/run.pid" ] && kill "$(cat "$TMP/run.pid")" 2>/dev/null
}
# bash runs an EXIT trap in every $(...) subshell and every background job, so
# an unguarded trap would delete this scratch dir and kill these servers halfway
# through the run.  BASHPID differs in a subshell; $$ does not.
trap 'if [ "${BASHPID:-}" = "$MAIN_PID" ]; then kill_survivors; [ "${KEEP_TMP:-}" = 1 ] || rm -rf "$TMP"; fi' EXIT

mkdir -p "$BIN" "$STATE"
: >"$STATE/ssh.log"
: >"$STATE/dev-procs"
: >"$STATE/host-procs"
printf 'table inet fw4 {\n\tflowtable ft {\n\t\tdevices = { "lan2", "lan3", "lan4", "wan" }\n\t}\n}\n' \
	>"$STATE/flowtables.txt"

# ---------------------------------------------------------------- fake tools

cat >"$BIN/ssh" <<'FAKE'
#!/bin/sh
# Every call carries the remote command as its last argument.
cmd=
for a in "$@"; do cmd=$a; done
printf '%s\n' "$cmd" >>"$FAKE_STATE/ssh.log"
case $cmd in
*'${miss:-ok}'*)
	if [ "${FAKE_SCENARIO:-}" = preflight ]; then echo 'MISSING iperf3'; else echo ok; fi
	;;
*'rp-pppoe.so pppoe.so'*)
	echo /usr/lib/pppd/2.5.4/pppoe.so
	;;
*'setsid pppd'*)
	echo 4242
	;;
*'setsid iperf3 -s -1 -p'*)
	# A real server that outlives this ssh call: only cleanup can kill it.
	sleep 3600 >/dev/null 2>&1 &
	echo $! >>"$FAKE_STATE/dev-procs"
	echo $!
	;;
*'ip -o link show'*)
	[ "${FAKE_SCENARIO:-}" = ppp ] && [ "${FAKE_SCENARIO:-}" = nolisten ] || true
	case ${FAKE_SCENARIO:-} in ppp|nolisten) echo ppp0 ;; esac
	;;
*'ip -o addr show dev'*)
	case ${FAKE_SCENARIO:-} in ppp|nolisten) exit 0 ;; *) exit 1 ;; esac
	;;
*'ss -ltn'*)
	case ${FAKE_SCENARIO:-} in ppp) exit 0 ;; *) exit 1 ;; esac
	;;
*'ip addr add'*)
	echo added
	;;
*'ip addr del'*|*'ip addr'*)
	exit 0
	;;
*'nft list flowtables'*)
	cat "$FAKE_STATE/flowtables.txt"
	;;
*'nft -a list chain'*)
	exit 0
	;;
*'nft list chain'*|*'nft list ruleset'*|*'nft insert rule'*)
	exit 0
	;;
*'for d in /proc'*)
	# busybox has no pkill; emulate the /proc sweep by killing this run's pids.
	for p in $(cat "$FAKE_STATE/dev-procs" 2>/dev/null) 4242; do
		kill "$p" 2>/dev/null
	done
	;;
*'kill '*)
	set -- $cmd
	kill "$2" 2>/dev/null
	;;
*'/proc/stat'*)
	echo 1000
	;;
*'true'*)
	exit 0
	;;
*)
	exit 0
	;;
esac
FAKE

cat >"$BIN/ip" <<'FAKE'
#!/bin/sh
case "$*" in
"-o addr show dev ppp0"*)
	case ${FAKE_SCENARIO:-} in ppp|nolisten) ;; *) exit 1 ;; esac
	echo '9: ppp0    inet 10.99.0.1 peer 10.99.0.2/32 scope global ppp0'
	;;
"link show "*)
	exit 0
	;;
"addr add "*|"addr del "*)
	exit 0
	;;
*)
	exit 0
	;;
esac
FAKE

cat >"$BIN/iptables" <<'FAKE'
#!/bin/sh
case $1 in
-C) exit 1 ;;
-I) echo "add $*" >>"$FAKE_STATE/host-iptables.log"; exit 0 ;;
-D) echo "del $*" >>"$FAKE_STATE/host-iptables.log"; exit 0 ;;
*) exit 0 ;;
esac
FAKE

cat >"$BIN/pppoe-server" <<'FAKE'
#!/bin/sh
echo $$ >>"$FAKE_STATE/host-procs"
exec sleep 3600
FAKE

cat >"$BIN/iperf3" <<'FAKE'
#!/bin/sh
case "$*" in
*"-c "*)
	[ -n "${FAKE_CLIENT_DELAY:-}" ] && sleep "$FAKE_CLIENT_DELAY"
	cat <<'JSON'
{"end":{"sum_sent":{"bits_per_second":941234567,"retransmits":3},"sum_received":{"bits_per_second":938765432}}}
JSON
	exit 0
	;;
*)
	exit 0
	;;
esac
FAKE

chmod +x "$BIN"/*

# Launcher: exec'd so the pid the test signals is the script's own pid.
cat >"$TMP/run.sh" <<'RUN'
#!/bin/sh
FAKE_SCENARIO=$1
shift
exec env PATH="$FAKE_BIN:$PATH" FAKE_STATE="$FAKE_STATE" FAKE_SCENARIO="$FAKE_SCENARIO" \
	FAKE_CLIENT_DELAY="${FAKE_CLIENT_DELAY:-}" \
	HOST_IF=e-fake DEVICE=127.0.0.1 DEVICE_USER=root DURATION=1 \
	IPERF3="$FAKE_BIN/iperf3" PORT_BASE="$FAKE_PORT_BASE" \
	WAIT_TRIES=3 WAIT_SLEEP=0.1 PPP_PLUGIN= \
	"$FAKE_SCRIPT" "$@"
RUN
chmod +x "$TMP/run.sh"

run() { # run <scenario> [script args...]
	FAKE_BIN="$BIN" FAKE_STATE="$STATE" FAKE_SCRIPT="$SCRIPT" \
		FAKE_PORT_BASE="$PORT_BASE" "$TMP/run.sh" "$@"
}

start() { # start <scenario> <stdout-file> [script args...] -> sets RUN_PID
	scenario=$1
	out=$2
	shift 2
	FAKE_BIN="$BIN" FAKE_STATE="$STATE" FAKE_SCRIPT="$SCRIPT" \
		FAKE_PORT_BASE="$PORT_BASE" FAKE_CLIENT_DELAY="${START_DELAY:-}" \
		"$TMP/run.sh" "$scenario" "$@" >"$out" 2>&1 &
	RUN_PID=$!
	echo "$RUN_PID" >"$TMP/run.pid"
}

servers_dead() {
	alive=0
	while read -r p; do
		[ -n "$p" ] || continue
		kill -0 "$p" 2>/dev/null && alive=$((alive + 1))
	done <"$STATE/dev-procs"
	[ "$alive" = 0 ]
}

arm_rows() { awk -F'\t' 'NR > 1 && $1 != "" { n++ } END { print n + 0 }' "$1"; }
arm_order() { awk -F'\t' 'NR > 1 && $1 != "" { printf "%s%s", sep, $1; sep = "," }' "$1"; }

# ------------------------------------------------------------------- (lint)
sh -n "$SCRIPT" && ok "sh -n scripts/pppoe-4path.sh" || no "sh -n scripts/pppoe-4path.sh"

# --------------------------------------------------------------- (d) dry-run
DRY=$TMP/dry.out
run noppp --dry-run --out "$TMP/dry.tsv" >"$DRY" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "--dry-run exits 0" || no "--dry-run exits 0 (rc=$rc)"
for want in pppoe-tx pppoe-rx raw-tx raw-rx 10.99.0.1 pppoe-server ppp0 cleanup; do
	grep -q -- "$want" "$DRY" && ok "dry-run mentions $want" || no "dry-run mentions $want"
done
[ ! -s "$STATE/ssh.log" ] && ok "dry-run made no ssh call" || no "dry-run made no ssh call"
[ ! -e "$TMP/dry.tsv" ] && ok "dry-run wrote no TSV" || no "dry-run wrote no TSV"

# Interrupt a dry-run: whichever side of the race wins, it must leave nothing.
rm -f "$STATE/ssh.log"
FAKE_BIN="$BIN" FAKE_STATE="$STATE" FAKE_SCRIPT="$SCRIPT" FAKE_PORT_BASE="$PORT_BASE" \
	"$TMP/run.sh" ppp --dry-run --out "$TMP/dry-int.tsv" >"$TMP/dry-int.out" 2>&1 &
pid=$!
kill -INT "$pid" 2>/dev/null
wait "$pid"
rc=$?
case $rc in
0|130) ok "SIGINT during --dry-run ends cleanly (rc=$rc)";;
*) no "SIGINT during --dry-run ends cleanly (rc=$rc)";;
esac
[ ! -s "$STATE/ssh.log" ] && ok "SIGINT during --dry-run made no ssh call" || no "SIGINT during --dry-run made no ssh call"
[ ! -e "$TMP/dry-int.tsv" ] && ok "SIGINT during --dry-run wrote no TSV" || no "SIGINT during --dry-run wrote no TSV"

# ------------------------------------------------- (a) preflight refusal
rm -f "$STATE/ssh.log"
run preflight --duration 1 --out "$TMP/pf.tsv" >"$TMP/pf.out" 2>&1
rc=$?
[ "$rc" = 2 ] && ok "missing device iperf3 exits 2" || no "missing device iperf3 exits 2 (rc=$rc)"
grep -q 'precondition failed: iperf3:' "$TMP/pf.out" &&
	ok "refusal names the failed precondition (iperf3)" || no "refusal names the failed precondition (iperf3)"
grep -q 'refusing to measure' "$TMP/pf.out" && ok "refusal says it refuses to measure" || no "refusal says it refuses to measure"
[ ! -e "$TMP/pf.tsv" ] && ok "no TSV written on refusal" || no "no TSV written on refusal"

# --------------------------------------------- (a) no ppp netdev -> refuse
rm -f "$STATE/ssh.log"
: >"$STATE/host-procs"
run noppp --duration 1 --out "$TMP/np.tsv" >"$TMP/np.out" 2>&1
rc=$?
[ "$rc" = 2 ] && ok "no ppp* netdev exits 2" || no "no ppp* netdev exits 2 (rc=$rc)"
grep -q 'precondition failed: no ppp\* netdev on the host' "$TMP/np.out" &&
	ok "refusal names 'no ppp* netdev on the host'" || no "refusal names 'no ppp* netdev on the host'"
grep -q 'precondition failed: no ppp\* netdev on the device' "$TMP/np.out" &&
	ok "refusal names 'no ppp* netdev on the device'" || no "refusal names 'no ppp* netdev on the device'"
[ ! -e "$TMP/np.tsv" ] && ok "refusal left no TSV behind" || no "refusal left no TSV behind"
[ -s "$STATE/host-procs" ] && ok "host pppoe-server was started before the refusal" || no "host pppoe-server was started before the refusal"
alive=0
while read -r p; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done <"$STATE/host-procs"
[ "$alive" = 0 ] && ok "cleanup killed the pppoe-server it started" || no "cleanup killed the pppoe-server it started"

# ------------------------------------------------ (b)(c) the four arms
: >"$STATE/ssh.log"
: >"$STATE/dev-procs"
: >"$STATE/host-procs"
run ppp --duration 1 --out "$TMP/full.tsv" >"$TMP/full.out" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "full simulated run exits 0" || no "full simulated run exits 0 (rc=$rc)"
[ "$(arm_rows "$TMP/full.tsv")" = 4 ] && ok "TSV has exactly 4 arm rows" || no "TSV has exactly 4 arm rows (got $(arm_rows "$TMP/full.tsv"))"
[ "$(arm_order "$TMP/full.tsv")" = "pppoe-tx,pppoe-rx,raw-tx,raw-rx" ] &&
	ok "arms emitted in order pppoe-tx,pppoe-rx,raw-tx,raw-rx" ||
	no "arms emitted in order (got $(arm_order "$TMP/full.tsv"))"
awk -F'\t' 'NR > 1 && NF != 7 { bad = 1 } END { exit bad ? 1 : 0 }' "$TMP/full.tsv" &&
	ok "every row has the 7 documented columns" || no "every row has the 7 documented columns"
awk -F'\t' 'NR > 1 && ($2 + 0) > 0 && ($3 + 0) > 0 && $4 ~ /^[0-9]+$/ { g++ } END { exit g == 4 ? 0 : 1 }' "$TMP/full.tsv" &&
	ok "all four rows carry numeric mbps and retr" || no "all four rows carry numeric mbps and retr"
! grep -q 'flowtable listing changed' "$TMP/full.out" &&
	ok "flowtable devices untouched (no change warning)" || no "flowtable devices untouched (no change warning)"
[ "$(wc -l <"$STATE/dev-procs")" = 4 ] &&
	ok "four device iperf3 servers were really started" || no "four device iperf3 servers were really started"
servers_dead && ok "cleanup killed all device iperf3 servers on exit" || no "cleanup killed all device iperf3 servers on exit"
grep -q 'cleanup: stopping the processes this run started' "$TMP/full.out" &&
	ok "cleanup ran on normal exit" || no "cleanup ran on normal exit"

# ------------------------------------------ (c) SIGINT / SIGTERM cleanup
#
# The signal must arrive the way Ctrl-C arrives.  A background child of a
# non-interactive shell inherits SIGINT as SIG_IGN, and a POSIX shell can never
# trap a signal that was ignored on entry, so "interrupt" tests written that way
# are decorative: the harness simply runs to completion and exits 0.  Job
# control (`set -m`) gives the job its own process group and the default
# disposition.  The signal is sent once an arm is demonstrably in flight, not
# after a guessed sleep, and the target is checked to be the harness itself.
set -m
for sig in INT TERM; do
	: >"$STATE/dev-procs"
	: >"$STATE/host-procs"
	rm -f "$TMP/sig-$sig.tsv" "$TMP/sig-$sig.out"
	START_DELAY=1 start ppp "$TMP/sig-$sig.out" --duration 5 --out "$TMP/sig-$sig.tsv"
	pid=$RUN_PID
	i=0
	while [ ! -s "$STATE/dev-procs" ] && [ "$i" -lt 400 ]; do
		sleep 0.05
		i=$((i + 1))
	done
	target_cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
	printf '# SIG%s target pid=%s cmd=%s\n' "$sig" "$pid" "$target_cmd"
	pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
	if [ -n "$pgid" ]; then
		printf '# SIG%s process tree at signal time:\n' "$sig"
		ps -o pid=,ppid=,pgid=,args= 2>/dev/null | awk -v g="$pgid" '
			NR == 1 { next }
			$3 == g { print "#   " $0 }'
	fi
	case $target_cmd in
	*pppoe-4path.sh*) ok "SIG$sig target is the harness itself, not a wrapper" ;;
	*) no "SIG$sig target is the harness itself, not a wrapper (cmd=$target_cmd)" ;;
	esac
	kill -"$sig" "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rc=$?
	case $sig in
	INT) want=130 ;;
	TERM) want=143 ;;
	esac
	[ "$rc" = "$want" ] && ok "SIG$sig exits $want" || no "SIG$sig exits $want (rc=$rc)"
	# Proves the interrupt was real: a harness that ignored it would finish the
	# four arms and exit 0.
	n=$(arm_rows "$TMP/sig-$sig.tsv" 2>/dev/null)
	n=${n:-0}
	[ "$n" -lt 4 ] && ok "SIG$sig interrupted the arm loop before four arms (rows=$n)" ||
		no "SIG$sig interrupted the arm loop before four arms (rows=$n)"
	grep -q 'temporarily accepting ppp0' "$TMP/sig-$sig.out" &&
		ok "SIG$sig arrived after the arm phase started" || no "SIG$sig arrived after the arm phase started"
	grep -q 'cleanup: stopping the processes this run started' "$TMP/sig-$sig.out" &&
		ok "SIG$sig ran the cleanup trap" || no "SIG$sig ran the cleanup trap"
	servers_dead && ok "SIG$sig cleanup killed the device iperf3 servers" ||
		no "SIG$sig cleanup killed the device iperf3 servers"
	alive=0
	while read -r p; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done <"$STATE/host-procs"
	[ "$alive" = 0 ] && ok "SIG$sig cleanup killed the host pppoe-server" || no "SIG$sig cleanup killed the host pppoe-server"
done
set +m

# ------------------------------------- no listener -> invalid rows, not numbers
: >"$STATE/dev-procs"
: >"$STATE/host-procs"
run nolisten --duration 1 --out "$TMP/nl.tsv" >"$TMP/nl.out" 2>&1
rc=$?
[ "$rc" = 1 ] && ok "missing listener exits 1" || no "missing listener exits 1 (rc=$rc)"
[ "$(arm_rows "$TMP/nl.tsv")" = 4 ] && ok "missing listener still records all four arms" || no "missing listener still records all four arms"
awk -F'\t' 'NR > 1 && ($2 == "nan" && $3 == "nan") && $7 ~ /no listener/ { g++ } END { exit g == 4 ? 0 : 1 }' "$TMP/nl.tsv" &&
	ok "invalid arms are nan with a 'no listener' note, not invented numbers" ||
	no "invalid arms are nan with a 'no listener' note, not invented numbers"

[ "${KEEP_TMP:-}" = 1 ] && printf 'scratch: %s\n' "$TMP"
printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
