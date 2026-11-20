#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# pppoe-4path.sh - repeatable PPPoE 1G four-path bench harness.
#
# Freezes the 2026-11-14 PPPoE four-arm reproduction into one script:
#
#   pppoe-tx   host -> device over the PPPoE session (host sends)
#   pppoe-rx   device -> host over the PPPoE session (host receives, -R)
#   raw-tx     host -> device over the same wire without PPPoE (control)
#   raw-rx     device -> host over the same wire without PPPoE (control)
#
# The host runs pppoe-server on --host-if and dials in from the device's
# br-lan, so ppp0 exists on both ends.  The raw arms use a temporary
# 10.99.1.0/24 address pair on the same interfaces and are the control for
# "is the PPPoE path itself the problem".
#
# What this script never does:
#   * it never adds ppp0 to an nft flowtable.  ppp0 is not an Ethernet
#     ingress; a flowtable device must be an Ethernet port, so adding ppp0
#     would be wrong, not an optimization.  The script does not run the
#     flowtable add command either.
#   * it never uses the old CGNAT range.  That range was swallowed by the
#     host Tailscale/UFW rules in the 2026-11-14 run; 10.99.0.0/24 is used.
#   * it never changes /etc/config/network or the persistent firewall.
#     The temporary nft/iptables rules are removed by the EXIT trap.
#
# Preconditions are checked before anything is measured and before the
# output file is created.  A run that cannot dial a PPPoE session prints
# every failed precondition as
#   pppoe-4path.sh: precondition failed: <item>: <detail>
# and exits 2 without writing a single measurement row: an arm that could
# not be reached is not a result.
#
# The device side is reached over SSH.  Only --dry-run works without a
# device, iperf3, pppoe-server or root.
#
# Exit status:
#   0  all four arms produced a result row (or --dry-run)
#   1  a real run started but at least one arm was invalid
#   2  usage error or failed precondition
#
set -u
LC_ALL=C
export LC_ALL

PROG=${0##*/}

HOST_IF=${HOST_IF:-enp3s0}
DEVICE=${DEVICE:-192.168.1.1}
DEVICE_USER=${DEVICE_USER:-root}
PPPOE_USER=${PPPOE_USER:-test}
PPPOE_PASS=${PPPOE_PASS:-test}
DURATION=${DURATION:-15}
IPERF3=${IPERF3:-iperf3}
OUT=${OUT:-pppoe-4path-$(date +%Y%m%d-%H%M%S).tsv}
DRY_RUN=0

HOST_PPP=${HOST_PPP:-ppp0}
HOST_PPP_ADDR=${HOST_PPP_ADDR:-10.99.0.1}
DEV_PPP_ADDR=${DEV_PPP_ADDR:-10.99.0.2}
RAW_HOST_ADDR=${RAW_HOST_ADDR:-10.99.1.1}
RAW_DEV_ADDR=${RAW_DEV_ADDR:-10.99.1.2}
RAW_PREFIX=${RAW_PREFIX:-24}
PORT_BASE=${PORT_BASE:-5300}
SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3}
WAIT_TRIES=${WAIT_TRIES:-50}
WAIT_SLEEP=${WAIT_SLEEP:-0.2}
PPP_PLUGIN=${PPP_PLUGIN:-}

DEV=${DEVICE_USER}@${DEVICE}
TMPDIR_RUN=
SESSION_STARTED=0
PRECOND_COUNT=0
PPPOE_PID=
DEV_PPPD_PID=
DEV_PPP=
DEV_IPERF_PID=
HOST_IPTABLES_ADDED=0
RAW_HOST_ADDED=0
RAW_DEV_ADDED=0
FAILED=0

# One SSH round trip that lists everything the device is missing.  Prints
# "ok", or one token per missing item: pppd iperf3 ppp-plugin ppp-kernel.
DEV_SCAN_CMD='miss=
command -v pppd >/dev/null 2>&1 || miss="$miss pppd"
command -v iperf3 >/dev/null 2>&1 || miss="$miss iperf3"
plug=
for p in rp-pppoe.so pppoe.so; do
  f=$(ls /usr/lib/pppd/*/$p 2>/dev/null | head -1)
  [ -n "$f" ] && { plug=1; break; }
done
[ -n "$plug" ] || miss="$miss ppp-plugin"
[ -r /proc/net/pppoe ] || miss="$miss ppp-kernel"
echo "${miss:-ok}"'

# pppd 2.5.x ships pppoe.so, rp-pppoe based builds ship rp-pppoe.so.  Take
# whichever is on the device instead of hardcoding one name.
DEV_PLUGIN_CMD='for p in rp-pppoe.so pppoe.so; do
                  f=$(ls /usr/lib/pppd/*/$p 2>/dev/null | head -1)
                  [ -n "$f" ] && { echo "$f"; break; }
                done'

usage() {
	cat <<'EOF'
Usage: pppoe-4path.sh [options]

Run the four-arm PPPoE 1G reproduction: pppoe-tx, pppoe-rx, raw-tx, raw-rx.
The host runs pppoe-server; the device dials pppd on br-lan.  One arm runs at
a time and every arm records sender/receiver Mbit/s and retransmits.

Options:
  --host-if NAME       host Ethernet interface facing the device (default enp3s0)
  --device ADDR        device IPv4 address (default 192.168.1.1)
  --device-user USER   SSH user on the device (default root)
  --pppoe-user USER    PPPoE username (default test)
  --pppoe-pass PASS    PPPoE password (default test)
  --ppp-plugin NAME    pppd PPPoE plugin on the device (default: auto-detect
                       rp-pppoe.so or pppoe.so under /usr/lib/pppd/*)
  --duration SEC       iperf3 seconds per arm (default 15)
  --iperf3 PATH        iperf3 binary (default iperf3)
  --out FILE           TSV output (default pppoe-4path-<timestamp>.tsv)
  --dry-run            print every command and the cleanup plan; do not ssh,
                       start a process, touch nft/iptables or require iperf3
  -h, --help           this text

Environment overrides (mainly for the offline test): HOST_PPP, HOST_PPP_ADDR,
DEV_PPP_ADDR, RAW_HOST_ADDR, RAW_DEV_ADDR, RAW_PREFIX, PORT_BASE, SSH_OPTS,
WAIT_TRIES, WAIT_SLEEP, PPP_PLUGIN.

TSV columns: arm, sender_mbps, receiver_mbps, retr, host_cpu_jiffies,
device_cpu_jiffies, note.

Protocol:
  1. preconditions: host ssh/iperf3/pppoe-server/iptables/host-if, device
     pppd/iperf3/pppd-PPPoE-plugin/PPP kernel; any failure exits 2 and writes
     no output file
  2. host: pppoe-server -I HOST_IF -L 10.99.0.1 -R 10.99.0.2
  3. device: pppd plugin <detected> br-lan user ... password ...
  4. temporarily accept ppp0 on both ends (nft/iptables, removed on exit)
  5. if no ppp* netdev appears on either end, exit 2 naming that precondition
  6. run the four arms, one at a time, each with a one-shot iperf3 server that
     is checked on the device before the client starts
  7. EXIT/INT/TERM/HUP cleanup: kill pppd/pppoe-server/iperf3, delete the
     temporary rules, remove the raw addresses, and report the flowtable
     snapshot (the script never edits flowtable devices)

Exit status: 0 all arms valid (or --dry-run), 1 an arm failed, 2 usage or
failed precondition.
EOF
}

say() { printf '%s: %s\n' "$PROG" "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }

# Record one failed precondition.  Never fatal by itself: one run reports the
# whole gap instead of the first symptom only.
precond() {
	PRECOND_COUNT=$((PRECOND_COUNT + 1))
	printf '%s: precondition failed: %s\n' "$PROG" "$*" >&2
}

need_arg() {
	[ "$#" -ge 2 ] || die "$1 needs an argument"
}

while [ "$#" -gt 0 ]; do
	case $1 in
	--host-if) need_arg "$@"; HOST_IF=$2; shift 2 ;;
	--device) need_arg "$@"; DEVICE=$2; DEV=$DEVICE_USER@$DEVICE; shift 2 ;;
	--device-user) need_arg "$@"; DEVICE_USER=$2; DEV=$DEVICE_USER@$DEVICE; shift 2 ;;
	--pppoe-user) need_arg "$@"; PPPOE_USER=$2; shift 2 ;;
	--pppoe-pass) need_arg "$@"; PPPOE_PASS=$2; shift 2 ;;
	--ppp-plugin) need_arg "$@"; PPP_PLUGIN=$2; shift 2 ;;
	--duration) need_arg "$@"; DURATION=$2; shift 2 ;;
	--iperf3) need_arg "$@"; IPERF3=$2; shift 2 ;;
	--out) need_arg "$@"; OUT=$2; shift 2 ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

case $DURATION in
''|*[!0-9]*) die "--duration must be a positive integer" ;;
esac
[ "$DURATION" -gt 0 ] || die "--duration must be positive"

# Print the exact plan.  No command in this function is executed.
dry_run() {
	cat <<EOF
$PROG: dry run; no ssh, no process, no nft/iptables change, no iperf3 needed
host interface : $HOST_IF
device         : $DEV
pppoe user     : $PPPOE_USER
ppp plugin     : ${PPP_PLUGIN:-auto-detect (rp-pppoe.so or pppoe.so)}
duration       : ${DURATION}s per arm
output         : $OUT

Preconditions checked before any measurement (fail => exit 2, no output file):
  host   : ssh, $IPERF3, pppoe-server, iptables, interface "$HOST_IF"
  device : pppd, iperf3, /usr/lib/pppd/*/{rp-pppoe.so,pppoe.so}, /proc/net/pppoe
  then   : a ppp* netdev must appear on both ends; if it does not, no arm runs

Plan:
  1. host: pppoe-server -I "$HOST_IF" -L $HOST_PPP_ADDR -R $DEV_PPP_ADDR
     wait up to $((WAIT_TRIES * 1))x${WAIT_SLEEP}s for $HOST_PPP ($HOST_PPP_ADDR)
  2. device: ssh $DEV "(setsid pppd plugin <plugin> br-lan user $PPPOE_USER \\
        password <hidden> noauth noipdefault defaultroute maxfail 1 ... &)"
     wait for the device ppp interface ($DEV_PPP_ADDR); if no ppp* netdev
     appears, exit 2 with "precondition failed: no ppp* netdev ..."
  3. temporary allow ppp0:
       host   iptables -I INPUT -i ppp0 -j ACCEPT
       host   iptables -I FORWARD -i ppp0 -j ACCEPT
       host   iptables -I FORWARD -o ppp0 -j ACCEPT
       device nft insert rule inet fw4 input iifname "ppp0" accept comment "pppoe4path"
       device nft insert rule inet fw4 forward iifname "ppp0" accept comment "pppoe4path"
       device nft insert rule inet fw4 forward oifname "ppp0" accept comment "pppoe4path"
  4. arm pppoe-tx: device iperf3 -s -1 -p $PORT_BASE -B $DEV_PPP_ADDR
                   host   $IPERF3 -c $DEV_PPP_ADDR -p $PORT_BASE -t $DURATION -J
  5. arm pppoe-rx: device iperf3 -s -1 -p $((PORT_BASE + 1)) -B $DEV_PPP_ADDR
                   host   $IPERF3 -c $DEV_PPP_ADDR -p $((PORT_BASE + 1)) -t $DURATION -R -J
  6. raw addresses: host ip addr add $RAW_HOST_ADDR/$RAW_PREFIX dev "$HOST_IF"
                    device ip addr add $RAW_DEV_ADDR/$RAW_PREFIX dev br-lan
  7. arm raw-tx:   device iperf3 -s -1 -p $((PORT_BASE + 2)) -B $RAW_DEV_ADDR
                   host   $IPERF3 -c $RAW_DEV_ADDR -p $((PORT_BASE + 2)) -t $DURATION -J
  8. arm raw-rx:   device iperf3 -s -1 -p $((PORT_BASE + 3)) -B $RAW_DEV_ADDR
                   host   $IPERF3 -c $RAW_DEV_ADDR -p $((PORT_BASE + 3)) -t $DURATION -R -J
  9. cleanup (EXIT/INT/TERM/HUP): kill pppoe-server on the host, kill the
     tracked pppd/iperf3 pids on the device (busybox there has no pkill, so it
     also sweeps /proc for this run's plugin name and port base); delete the
     temporary iptables rules and nft rules by comment; remove the raw
     addresses; print the saved flowtable listing.  The script never edits
     flowtable devices and never adds ppp0 to a flowtable.

TSV: $OUT
EOF
}

# Execute a command on the device.  -n keeps stdin away from the remote shell.
rsh() { ssh $SSH_OPTS -n "$DEV" "$@"; }

# Snapshot the device state the trap may need to put back.  The flowtable
# listing is kept locally so cleanup can compare it after the run.
snapshot_device() {
	rsh "nft list ruleset >/tmp/pppoe4path-nft.before 2>/dev/null || true;
	     ip -o addr show >/tmp/pppoe4path-addr.before" >/dev/null 2>&1 || warn "cannot snapshot the device ruleset"
	rsh "nft list flowtables 2>/dev/null" >"$TMPDIR_RUN/flowtables.before" 2>/dev/null ||
		warn "cannot read the device flowtable listing"
}

# Delete only rules carrying our comment.  Handles are read with nft -a.
nft_delete_commented() {
	rsh 'for chain in input forward output; do
	       nft list chain inet fw4 "$chain" >/dev/null 2>&1 || continue
	       nft -a list chain inet fw4 "$chain" 2>/dev/null |
	         awk "/comment \"pppoe4path\"/ {for (i=1;i<=NF;i++) if (\$i==\"handle\") print \$i+1}" |
	         while read -r h; do nft delete rule inet fw4 "$chain" handle "$h" 2>/dev/null || true; done
	     done' >/dev/null 2>&1 || true
}

host_rule_present() {
	iptables -C "$@" >/dev/null 2>&1
}

host_rule_add() {
	host_rule_present "$@" && return 0
	iptables -I "$@" >/dev/null 2>&1 || return 1
	HOST_IPTABLES_ADDED=1
}

host_rule_del() {
	host_rule_present "$@" && iptables -D "$@" >/dev/null 2>&1 || true
}

# Kill a tracked device pid.  Empty pid is a no-op.
dev_kill() {
	[ -n "${1:-}" ] || return 0
	rsh "kill $1 2>/dev/null || true" >/dev/null 2>&1 || true
}

# busybox has no pkill on the device, so sweep /proc for this run's own
# processes only: pppd running our plugin, and iperf3 servers on our port base.
dev_sweep() {
	rsh "for d in /proc/[0-9]*; do
	        tr '\000' '\n' < \$d/cmdline 2>/dev/null |
	          grep -qE 'pppd.*$PPP_PLUGIN|iperf3 -s -1 -p $PORT_BASE' &&
	          kill \${d##*/} 2>/dev/null
	     done" >/dev/null 2>&1 || true
}

cleanup() {
	trap - EXIT INT TERM HUP
	if [ "$SESSION_STARTED" != 1 ]; then
		[ -n "${TMPDIR_RUN:-}" ] && rm -rf "$TMPDIR_RUN" 2>/dev/null
		[ -n "${TMPDIR_RUN:-}" ] && TMPDIR_RUN=
		return 0
	fi

	say "cleanup: stopping the processes this run started"
	if [ -n "${PPPOE_PID:-}" ]; then
		kill "$PPPOE_PID" 2>/dev/null
		wait "$PPPOE_PID" 2>/dev/null
	fi
	dev_kill "${DEV_IPERF_PID:-}"
	dev_kill "${DEV_PPPD_PID:-}"
	dev_sweep

	[ "$HOST_IPTABLES_ADDED" = 1 ] && {
		host_rule_del INPUT -i ppp0 -j ACCEPT
		host_rule_del FORWARD -i ppp0 -j ACCEPT
		host_rule_del FORWARD -o ppp0 -j ACCEPT
	}
	[ "$RAW_HOST_ADDED" = 1 ] &&
		ip addr del "$RAW_HOST_ADDR/$RAW_PREFIX" dev "$HOST_IF" >/dev/null 2>&1
	[ "$RAW_DEV_ADDED" = 1 ] &&
		rsh "ip addr del $RAW_DEV_ADDR/$RAW_PREFIX dev br-lan" >/dev/null 2>&1

	nft_delete_commented

	# The script does not edit flowtable devices; prove it by comparing the
	# saved listing.  A difference is reported, never silently accepted.
	if [ -n "${TMPDIR_RUN:-}" ] && [ -f "$TMPDIR_RUN/flowtables.before" ]; then
		if ! rsh "nft list flowtables 2>/dev/null" >"$TMPDIR_RUN/flowtables.after" 2>/dev/null; then
			warn "cleanup: could not re-read flowtables; saved listing: $TMPDIR_RUN/flowtables.before"
		elif ! cmp -s "$TMPDIR_RUN/flowtables.before" "$TMPDIR_RUN/flowtables.after"; then
			warn "cleanup: flowtable listing changed; inspect $TMPDIR_RUN/flowtables.before and .after"
		fi
	fi
	[ -n "${TMPDIR_RUN:-}" ] && [ -d "$TMPDIR_RUN" ] && say "raw logs: $TMPDIR_RUN"
	return 0
}

# Does the device show a LISTEN socket on $1?  ss, netstat or /proc/net/tcp;
# the device image has no ss and busybox kills nothing, so probe all three.
probe_listener() {
	pl_port=$1
	pl_hex=$(printf '%04X' "$pl_port")
	rsh "if command -v ss >/dev/null 2>&1; then
	        ss -ltn 2>/dev/null | grep -Eq ':$pl_port([[:space:]]|\$)';
	     elif command -v netstat >/dev/null 2>&1; then
	        netstat -ltn 2>/dev/null | grep -Eq ':$pl_port([[:space:]]|\$)';
	     else
	        awk -v p=':$pl_hex' '\$4 == \"0A\" && \$2 ~ p \"\$\"' /proc/net/tcp 2>/dev/null | grep -q .;
	     fi"
}

# Wait until the device shows the arm's listener.  A missing server invalidates
# the arm; it is not retried silently.
wait_listener() {
	wl_port=$1
	wl_i=0
	while [ "$wl_i" -lt "$WAIT_TRIES" ]; do
		probe_listener "$wl_port" && return 0
		sleep "$WAIT_SLEEP"
		wl_i=$((wl_i + 1))
	done
	return 1
}

# Read sender/receiver/retr from iperf3 -J.  Prints "sender receiver retr".
parse_iperf() {
	python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    end = d["end"]
    s = end["sum_sent"]
    r = end["sum_received"]
    print("%.3f\t%.3f\t%s" % (s["bits_per_second"] / 1e6,
                               r["bits_per_second"] / 1e6,
                               s.get("retransmits", 0)))
except Exception:
    print("nan\tnan\tnan")
PY
}

cpu_jiffies() {
	awk '/^cpu / { s = 0; for (i = 2; i <= NF; i++) s += $i; print s; exit }' /proc/stat
}

dev_cpu_jiffies() {
	rsh "awk '/^cpu / { s = 0; for (i = 2; i <= NF; i++) s += \$i; print s; exit }' /proc/stat" 2>/dev/null || true
}

# run_arm NAME SERVER_ADDR CLIENT_ADDR PORT REVERSE
run_arm() {
	ra_name=$1
	ra_saddr=$2
	ra_caddr=$3
	ra_port=$4
	ra_reverse=$5
	ra_raw="$TMPDIR_RUN/$ra_name.iperf3.json"
	ra_note=
	ra_s=
	ra_r=
	ra_ret=
	ra_hc=
	ra_dc=
	ra_rev=
	ra_parsed=
	[ "$ra_reverse" = 1 ] && ra_rev=-R
	DEV_IPERF_PID=

	# The device has no nohup and no pkill; setsid plus a tracked pid is the
	# whole story.
	DEV_IPERF_PID=$(rsh "(setsid iperf3 -s -1 -p $ra_port -B $ra_saddr \
		>/tmp/pppoe4path-$ra_name.server.log 2>&1 </dev/null & echo \$!)") ||
		DEV_IPERF_PID=

	if [ -z "${DEV_IPERF_PID:-}" ] || ! wait_listener "$ra_port"; then
		printf '%s\tnan\tnan\tnan\t\t\t%s\n' "$ra_name" \
			"invalid: no listener on the device port $ra_port" >>"$OUT"
		FAILED=1
		dev_kill "${DEV_IPERF_PID:-}"
		return 0
	fi

	ra_hc=$(cpu_jiffies)
	ra_dc_before=$(dev_cpu_jiffies)
	if ! "$IPERF3" -c "$ra_caddr" -p "$ra_port" -t "$DURATION" $ra_rev -J >"$ra_raw" 2>"$TMPDIR_RUN/$ra_name.err"; then
		ra_note="iperf3 client failed"
		FAILED=1
	else
		ra_parsed=$(parse_iperf "$ra_raw")
		set -- $ra_parsed
		ra_s=${1:-nan}
		ra_r=${2:-nan}
		ra_ret=${3:-nan}
		if [ "$ra_s" = nan ] || [ "$ra_r" = nan ]; then
			ra_note="unparsable iperf3 JSON"
			FAILED=1
		fi
	fi
	ra_hc=$(( $(cpu_jiffies) - ra_hc ))
	ra_dc=$(dev_cpu_jiffies)
	case ${ra_dc:-} in
	''|*[!0-9]*) ra_dc=nan ;;
	*) ra_dc=$(( ra_dc - ${ra_dc_before:-0} )) ;;
	esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ra_name" "${ra_s:-nan}" "${ra_r:-nan}" \
		"${ra_ret:-nan}" "$ra_hc" "${ra_dc:-nan}" "$ra_note" >>"$OUT"
	dev_kill "${DEV_IPERF_PID:-}"
}

# Preconditions on the host.  Every failure is recorded, not fatal on the spot.
check_host() {
	command -v ssh >/dev/null 2>&1 ||
		precond "ssh: not found on the host PATH (the harness needs ssh for $DEV)"
	command -v "$IPERF3" >/dev/null 2>&1 ||
		precond "iperf3: '$IPERF3' not found on the host PATH (pass --iperf3)"
	command -v pppoe-server >/dev/null 2>&1 ||
		precond "pppoe-server: not found on the host PATH (rp-pppoe package missing; the host must accept the PPPoE session)"
	command -v iptables >/dev/null 2>&1 ||
		precond "iptables: not found on the host PATH (needed for the temporary ppp0 accept)"
	if command -v ip >/dev/null 2>&1; then
		ip link show "$HOST_IF" >/dev/null 2>&1 ||
			precond "host interface: '$HOST_IF' does not exist on the host (pass --host-if; see 'ip -o link show')"
	else
		precond "ip: not found on the host PATH (iproute2 is required)"
	fi
}

# Preconditions on the device.  One ssh round trip, one line out.
check_device() {
	cd_scan=
	cd_scan=$(rsh "$DEV_SCAN_CMD") || cd_scan=
	if [ -z "$cd_scan" ]; then
		precond "ssh: cannot reach $DEV with BatchMode key auth (check --device/--device-user and the key)"
		return 0
	fi
	for cd_item in $cd_scan; do
		case $cd_item in
		ok) ;;
		pppd) precond "pppd: not installed on $DEVICE (it dials the PPPoE session on br-lan)" ;;
		iperf3) precond "iperf3: not installed on $DEVICE (every arm needs a server on the device)" ;;
		ppp-plugin) precond "ppp-plugin: neither /usr/lib/pppd/*/rp-pppoe.so nor /usr/lib/pppd/*/pppoe.so exists on $DEVICE (pppd cannot dial PPPoE)" ;;
		ppp-kernel) precond "ppp-kernel: $DEVICE has no /proc/net/pppoe (the kernel has no PPPoE support)" ;;
		*) precond "device-scan: unexpected token '$cd_item' from $DEVICE" ;;
		esac
	done

	[ -n "$PPP_PLUGIN" ] && return 0
	PPP_PLUGIN=$(rsh "$DEV_PLUGIN_CMD" 2>/dev/null) || PPP_PLUGIN=
	PPP_PLUGIN=${PPP_PLUGIN##*/}
	[ -n "$PPP_PLUGIN" ] ||
		precond "ppp-plugin: cannot determine the pppd PPPoE plugin name on $DEVICE (pass --ppp-plugin)"
}

# Nothing measured and nothing written: refuse the run, naming every gap.
refuse_run() {
	printf '%s: refusing to measure: %s precondition(s) failed; no arm ran and %s was not written\n' \
		"$PROG" "$PRECOND_COUNT" "$OUT" >&2
	exit 2
}

main() {
	if [ "$DRY_RUN" = 1 ]; then
		dry_run
		exit 0
	fi

	[ -e "$OUT" ] && die "refusing to overwrite existing $OUT"
	TMPDIR_RUN=$(mktemp -d "${TMPDIR:-/tmp}/pppoe-4path.XXXXXX") || die "cannot create temp dir"

	check_device
	check_host
	[ "$PRECOND_COUNT" = 0 ] || refuse_run

	say "host: starting pppoe-server on $HOST_IF ($HOST_PPP_ADDR -> $DEV_PPP_ADDR)"
	SESSION_STARTED=1
	pppoe-server -I "$HOST_IF" -L "$HOST_PPP_ADDR" -R "$DEV_PPP_ADDR" \
		>"$TMPDIR_RUN/pppoe-server.log" 2>&1 &
	PPPOE_PID=$!

	hs=0
	while [ "$hs" -lt "$WAIT_TRIES" ]; do
		ip -o addr show dev "$HOST_PPP" 2>/dev/null | grep -q "$HOST_PPP_ADDR" && break
		sleep "$WAIT_SLEEP"
		hs=$((hs + 1))
	done
	ip -o addr show dev "$HOST_PPP" 2>/dev/null | grep -q "$HOST_PPP_ADDR" ||
		precond "no ppp* netdev on the host: $HOST_PPP ($HOST_PPP_ADDR) did not come up after ${WAIT_TRIES}x${WAIT_SLEEP}s (pppoe-server log: $TMPDIR_RUN/pppoe-server.log)"

	say "device: dialing pppd plugin $PPP_PLUGIN on br-lan"
	DEV_PPPD_PID=$(rsh "(setsid pppd plugin '$PPP_PLUGIN' br-lan user '$PPPOE_USER' password '$PPPOE_PASS' \
		noauth noipdefault defaultroute maxfail 1 ipcp-accept-local ipcp-accept-remote \
		>/tmp/pppoe4path-pppd.log 2>&1 </dev/null & echo \$!)") || DEV_PPPD_PID=

	DEV_PPP=
	ds=0
	while [ "$ds" -lt "$WAIT_TRIES" ]; do
		DEV_PPP=$(rsh "ip -o link show 2>/dev/null | awk -F': ' '\$2 ~ /^ppp/ {print \$2; exit}'") || DEV_PPP=
		if [ -n "$DEV_PPP" ] &&
			rsh "ip -o addr show dev '$DEV_PPP' 2>/dev/null | grep -q '$DEV_PPP_ADDR'"; then
			break
		fi
		DEV_PPP=
		sleep "$WAIT_SLEEP"
		ds=$((ds + 1))
	done
	[ -n "$DEV_PPP" ] ||
		precond "no ppp* netdev on the device: pppd plugin $PPP_PLUGIN produced no ppp interface with $DEV_PPP_ADDR after ${WAIT_TRIES}x${WAIT_SLEEP}s (log: /tmp/pppoe4path-pppd.log)"

	[ "$PRECOND_COUNT" = 0 ] || refuse_run

	# Only now, with a live session on both ends, is there a result to record.
	printf 'arm\tsender_mbps\treceiver_mbps\tretr\thost_cpu_jiffies\tdevice_cpu_jiffies\tnote\n' >"$OUT"
	snapshot_device

	say "temporarily accepting ppp0"
	host_rule_add INPUT -i ppp0 -j ACCEPT || warn "cannot add host INPUT ppp0 rule"
	host_rule_add FORWARD -i ppp0 -j ACCEPT || warn "cannot add host FORWARD i/ppp0 rule"
	host_rule_add FORWARD -o ppp0 -j ACCEPT || warn "cannot add host FORWARD o/ppp0 rule"
	if rsh "nft list chain inet fw4 input >/dev/null 2>&1"; then
		rsh "nft insert rule inet fw4 input iifname 'ppp0' accept comment 'pppoe4path' 2>/dev/null || true;
		     nft insert rule inet fw4 forward iifname 'ppp0' accept comment 'pppoe4path' 2>/dev/null || true;
		     nft insert rule inet fw4 forward oifname 'ppp0' accept comment 'pppoe4path' 2>/dev/null || true" ||
			warn "cannot add device nft ppp0 rules"
	fi

	run_arm pppoe-tx "$DEV_PPP_ADDR" "$DEV_PPP_ADDR" "$PORT_BASE" 0
	run_arm pppoe-rx "$DEV_PPP_ADDR" "$DEV_PPP_ADDR" "$((PORT_BASE + 1))" 1

	say "temporary raw addresses on $HOST_IF and br-lan"
	ip addr add "$RAW_HOST_ADDR/$RAW_PREFIX" dev "$HOST_IF" >/dev/null 2>&1 && RAW_HOST_ADDED=1
	rsh "ip addr add $RAW_DEV_ADDR/$RAW_PREFIX dev br-lan 2>/dev/null && echo added" |
		grep -q added && RAW_DEV_ADDED=1
	[ "$RAW_HOST_ADDED" = 1 ] || warn "host raw address $RAW_HOST_ADDR/$RAW_PREFIX was not added"
	[ "$RAW_DEV_ADDED" = 1 ] || warn "device raw address $RAW_DEV_ADDR/$RAW_PREFIX was not added"

	run_arm raw-tx "$RAW_DEV_ADDR" "$RAW_DEV_ADDR" "$((PORT_BASE + 2))" 0
	run_arm raw-rx "$RAW_DEV_ADDR" "$RAW_DEV_ADDR" "$((PORT_BASE + 3))" 1

	say "result: $OUT"
	[ "$FAILED" = 0 ] && exit 0
	exit 1
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

main "$@"
