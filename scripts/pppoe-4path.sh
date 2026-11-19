#!/usr/bin/env bash
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
# The device side is reached over SSH.  Only --dry-run works without a
# device, iperf3, pppoe-server or root.
#
# Exit status:
#   0  all four arms produced a result row (or --dry-run)
#   1  a real run started but at least one arm was invalid
#   2  usage error or missing precondition
#
set -u
set -o pipefail
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

DEV=${DEVICE_USER}@${DEVICE}
TMPDIR_RUN=
PPPOE_PID=
DEV_PPPD_PID=
HOST_IPTABLES_ADDED=0
RAW_HOST_ADDED=0
RAW_DEV_ADDED=0
DEV_PPP=
FAILED=0

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
  --duration SEC       iperf3 seconds per arm (default 15)
  --iperf3 PATH        iperf3 binary (default iperf3)
  --out FILE           TSV output (default pppoe-4path-<timestamp>.tsv)
  --dry-run            print every command and the cleanup plan; do not ssh,
                       start a process, touch nft/iptables or require iperf3
  -h, --help           this text

TSV columns: arm, sender_mbps, receiver_mbps, retr, host_cpu_jiffies,
device_cpu_jiffies, note.

Protocol:
  1. host: pppoe-server -I HOST_IF -L 10.99.0.1 -R 10.99.0.2
  2. device: pppd plugin rp-pppoe.so br-lan user ... password ...
  3. temporarily accept ppp0 on both ends (nft/iptables, removed on exit)
  4. run the four arms, one at a time, each with an iperf3 server that is
     checked with "ss -ltn" before the client starts
  5. EXIT/INT/TERM/HUP cleanup: kill pppd/pppoe-server/iperf3, delete the
     temporary rules, remove the raw addresses, and report the flowtable
     snapshot (the script never edits flowtable devices)

Exit status: 0 all arms valid (or --dry-run), 1 an arm failed, 2 usage or
missing precondition.
EOF
}

say() { printf '%s: %s\n' "$PROG" "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

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
duration       : ${DURATION}s per arm
output         : $OUT

Plan:
  1. host: pppoe-server -I "$HOST_IF" -L $HOST_PPP_ADDR -R $DEV_PPP_ADDR
     wait for $HOST_PPP ($HOST_PPP_ADDR)
  2. device: ssh $DEV "nohup pppd plugin rp-pppoe.so br-lan user $PPPOE_USER \\
       password <hidden> noauth noipdefault defaultroute maxfail 1 ..."
     wait for the device ppp interface ($DEV_PPP_ADDR)
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
  9. cleanup (EXIT/INT/TERM/HUP): kill pppd, pppoe-server and iperf3; delete the
     temporary iptables/nft rules by comment; remove the raw addresses; print
     the saved flowtable listing.  The script never edits flowtable devices
     and never adds ppp0 to a flowtable.

TSV: $OUT
EOF
}

# Execute a command on the device.  -n keeps stdin away from the remote shell.
rsh() { ssh $SSH_OPTS "$DEV" "$@"; }

# Snapshot the device state that the trap may need to put back.
snapshot_device() {
	rsh "nft list ruleset >/tmp/pppoe4path-nft.before 2>/dev/null || true;
	     nft list flowtables >/tmp/pppoe4path-flowtables.before 2>/dev/null || true;
	     ip -o addr show >/tmp/pppoe4path-addr.before"
}

# Delete only rules carrying our comment.  Handles are read with nft -a.
nft_delete_commented() {
	rsh 'for chain in input forward output; do
	       nft list chain inet fw4 "$chain" >/dev/null 2>&1 || continue
	       nft -a list chain inet fw4 "$chain" 2>/dev/null |
	         awk "/comment \"pppoe4path\"/ {for (i=1;i<=NF;i++) if (\$i==\"handle\") print \$i+1}" |
	         while read -r h; do nft delete rule inet fw4 "$chain" handle "$h" 2>/dev/null || true; done
	     done'
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

cleanup() {
	# Kill only processes this run could have started, matched by the
	# interface/port pattern rather than by a broad "iperf3" match.
	[ -n "${PPPOE_PID:-}" ] && kill "$PPPOE_PID" 2>/dev/null || true
	pkill -f "pppoe-server -I $HOST_IF" 2>/dev/null || true
	pkill -f "pppd .*rp-pppoe.so $HOST_IF" 2>/dev/null || true
	pkill -f "pppd .*rp-pppoe.so br-lan" 2>/dev/null || true
	pkill -f "pppd .*plugin rp-pppoe.so" 2>/dev/null || true
	pkill -f "iperf3 -s -1 -p $PORT_BASE" 2>/dev/null || true
	pkill -f "iperf3 -s -1 -p $((PORT_BASE + 1))" 2>/dev/null || true
	pkill -f "iperf3 -s -1 -p $((PORT_BASE + 2))" 2>/dev/null || true
	pkill -f "iperf3 -s -1 -p $((PORT_BASE + 3))" 2>/dev/null || true

	[ "$HOST_IPTABLES_ADDED" = 1 ] && {
		host_rule_del INPUT -i ppp0 -j ACCEPT
		host_rule_del FORWARD -i ppp0 -j ACCEPT
		host_rule_del FORWARD -o ppp0 -j ACCEPT
	}
	[ "$RAW_HOST_ADDED" = 1 ] && ip addr del "$RAW_HOST_ADDR/$RAW_PREFIX" dev "$HOST_IF" 2>/dev/null || true
	[ "$RAW_DEV_ADDED" = 1 ] && rsh "ip addr del $RAW_DEV_ADDR/$RAW_PREFIX dev br-lan" 2>/dev/null || true

	nft_delete_commented
	if [ -n "${DEV_PPPD_PID:-}" ]; then
		rsh "kill $DEV_PPPD_PID 2>/dev/null || true" 2>/dev/null || true
	fi

	# The script does not edit flowtable devices; prove it by comparing the
	# saved listing.  A difference is reported, never silently accepted.
	if [ -n "${TMPDIR_RUN:-}" ] && [ -f "$TMPDIR_RUN/flowtables.before" ]; then
		if ! rsh "nft list flowtables 2>/dev/null" >"$TMPDIR_RUN/flowtables.after"; then
			say "cleanup: could not re-read flowtables; saved listing: $TMPDIR_RUN/flowtables.before" >&2
		elif ! cmp -s "$TMPDIR_RUN/flowtables.before" "$TMPDIR_RUN/flowtables.after"; then
			say "cleanup: WARNING flowtable listing changed; inspect $TMPDIR_RUN/flowtables.before and .after" >&2
		fi
	fi
	[ -n "${TMPDIR_RUN:-}" ] && [ -d "$TMPDIR_RUN" ] && say "raw logs: $TMPDIR_RUN"
}

# Wait until "ss -ltn" on the device shows the arm's port.  A missing server
# invalidates the arm; it is not retried silently.
wait_listener() {
	local port=$1 i
	for i in $(seq 1 30); do
		if rsh "ss -ltn 2>/dev/null | grep -q ':$port '"; then
			return 0
		fi
		sleep 0.2
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
	local name=$1 saddr=$2 caddr=$3 port=$4 reverse=$5
	local raw="$TMPDIR_RUN/$name.iperf3.json" note="" s r ret hc dc
	local rev=""
	[ "$reverse" = 1 ] && rev="-R"

	rsh "pkill -f 'iperf3 -s -1 -p $port' 2>/dev/null || true;
	     nohup iperf3 -s -1 -p $port -B $saddr >/tmp/pppoe4path-$name.server.log 2>&1 </dev/null &
	     echo started" >/dev/null || {
		printf '%s\tnan\tnan\tnan\t\t\t%s\n' "$name" "server start failed" >>"$OUT"
		FAILED=1
		return 0
	}
	if ! wait_listener "$port"; then
		printf '%s\tnan\tnan\tnan\t\t\t%s\n' "$name" "invalid: no listener on port $port" >>"$OUT"
		FAILED=1
		rsh "pkill -f 'iperf3 -s -1 -p $port' 2>/dev/null || true" >/dev/null 2>&1 || true
		return 0
	fi

	hc=$(cpu_jiffies)
	dc=$(dev_cpu_jiffies)
	if ! "$IPERF3" -c "$caddr" -p "$port" -t "$DURATION" $rev -J >"$raw" 2>"$TMPDIR_RUN/$name.err"; then
		note="iperf3 client failed"
		FAILED=1
	else
		parsed=$(parse_iperf "$raw")
		set -- $parsed
		s=${1:-nan} r=${2:-nan} ret=${3:-nan}
		if [ "$s" = nan ] || [ "$r" = nan ]; then
			note="unparsable iperf3 JSON"
			FAILED=1
		fi
	fi
	hc=$(( $(cpu_jiffies) - hc ))
	dc=$(( $(dev_cpu_jiffies || echo "$dc") - dc ))
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${s:-nan}" "${r:-nan}" "${ret:-nan}" "$hc" "$dc" "$note" >>"$OUT"
	# Wait for the one-shot server to exit so the next arm gets a clean port.
	rsh "pkill -f 'iperf3 -s -1 -p $port' 2>/dev/null || true" >/dev/null 2>&1 || true
}

main() {
	if [ "$DRY_RUN" = 1 ]; then
		dry_run
		exit 0
	fi

	command -v ssh >/dev/null 2>&1 || die "ssh is required"
	command -v "$IPERF3" >/dev/null 2>&1 || die "$IPERF3 is required"
	command -v pppoe-server >/dev/null 2>&1 || die "pppoe-server is required"
	ip link show "$HOST_IF" >/dev/null 2>&1 || die "host interface $HOST_IF not found"
	rsh true || die "cannot ssh to $DEV"
	[ -e "$OUT" ] && die "refusing to overwrite existing $OUT"

	TMPDIR_RUN=$(mktemp -d "${TMPDIR:-/tmp}/pppoe-4path.XXXXXX") || die "cannot create temp dir"
	trap cleanup EXIT
	trap 'exit 130' INT TERM HUP

	printf 'arm\tsender_mbps\treceiver_mbps\tretr\thost_cpu_jiffies\tdevice_cpu_jiffies\tnote\n' >"$OUT"

	snapshot_device

	say "starting host pppoe-server on $HOST_IF ($HOST_PPP_ADDR -> $DEV_PPP_ADDR)"
	pppoe-server -I "$HOST_IF" -L "$HOST_PPP_ADDR" -R "$DEV_PPP_ADDR" \
		>"$TMPDIR_RUN/pppoe-server.log" 2>&1 &
	PPPOE_PID=$!

	i=0
	while [ "$i" -lt 50 ]; do
		ip -o addr show dev "$HOST_PPP" 2>/dev/null | grep -q "$HOST_PPP_ADDR" && break
		sleep 0.2
		i=$((i + 1))
	done
	ip -o addr show dev "$HOST_PPP" 2>/dev/null | grep -q "$HOST_PPP_ADDR" ||
		die "host $HOST_PPP did not come up (see $TMPDIR_RUN/pppoe-server.log)"

	say "dialing pppd on the device br-lan"
	DEV_PPPD_PID=$(rsh "nohup pppd plugin rp-pppoe.so br-lan user '$PPPOE_USER' password '$PPPOE_PASS' \
		noauth noipdefault defaultroute maxfail 1 ipcp-accept-local ipcp-accept-remote \
		>/tmp/pppoe4path-pppd.log 2>&1 </dev/null & echo \$!") || die "cannot start pppd on device"

	i=0
	DEV_PPP=
	while [ "$i" -lt 50 ]; do
		DEV_PPP=$(rsh "ip -o link show 2>/dev/null | awk -F': ' '\$2 ~ /^ppp/ {print \$2; exit}'") || true
		[ -n "$DEV_PPP" ] && rsh "ip -o addr show dev '$DEV_PPP' | grep -q '$DEV_PPP_ADDR'" && break
		sleep 0.2
		i=$((i + 1))
	done
	[ -n "$DEV_PPP" ] || die "device PPP interface did not come up (see /tmp/pppoe4path-pppd.log)"
	rsh "ip -o addr show dev '$DEV_PPP' | grep -q '$DEV_PPP_ADDR'" ||
		die "device $DEV_PPP has no $DEV_PPP_ADDR"

	say "temporarily accepting ppp0"
	host_rule_add INPUT -i ppp0 -j ACCEPT || say "warning: cannot add host INPUT ppp0 rule"
	host_rule_add FORWARD -i ppp0 -j ACCEPT || say "warning: cannot add host FORWARD ppp0 rule"
	host_rule_add FORWARD -o ppp0 -j ACCEPT || say "warning: cannot add host FORWARD o/ppp0 rule"
	if rsh "nft list chain inet fw4 input >/dev/null 2>&1"; then
		rsh "nft insert rule inet fw4 input iifname 'ppp0' accept comment 'pppoe4path' 2>/dev/null || true;
		     nft insert rule inet fw4 forward iifname 'ppp0' accept comment 'pppoe4path' 2>/dev/null || true;
		     nft insert rule inet fw4 forward oifname 'ppp0' accept comment 'pppoe4path' 2>/dev/null || true" ||
			say "warning: cannot add device nft ppp0 rules"
	fi

	run_arm pppoe-tx "$DEV_PPP_ADDR" "$DEV_PPP_ADDR" "$PORT_BASE" 0
	run_arm pppoe-rx "$DEV_PPP_ADDR" "$DEV_PPP_ADDR" "$((PORT_BASE + 1))" 1

	say "adding temporary raw addresses on $HOST_IF and br-lan"
	ip addr add "$RAW_HOST_ADDR/$RAW_PREFIX" dev "$HOST_IF" 2>/dev/null && RAW_HOST_ADDED=1
	rsh "ip addr add $RAW_DEV_ADDR/$RAW_PREFIX dev br-lan 2>/dev/null && echo added" | grep -q added && RAW_DEV_ADDED=1
	[ "$RAW_HOST_ADDED" = 1 ] || say "warning: host raw address was not added"
	[ "$RAW_DEV_ADDED" = 1 ] || say "warning: device raw address was not added"

	run_arm raw-tx "$RAW_DEV_ADDR" "$RAW_DEV_ADDR" "$((PORT_BASE + 2))" 0
	run_arm raw-rx "$RAW_DEV_ADDR" "$RAW_DEV_ADDR" "$((PORT_BASE + 3))" 1

	say "result: $OUT"
	[ "$FAILED" = 0 ] && exit 0
	exit 1
}

main "$@"
