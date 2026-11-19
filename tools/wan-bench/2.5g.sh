#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# wan-bench/2.5g.sh - repeatable 2.5G WAN/LAN gate for the XR1710G.
#
# Topology (the script measures, it does not build the bed):
#
#   bench host (this script)                 peer (LAN side)
#   +---------------------+   XR1710G   +---------------------+
#   | USB 2.5G NIC        |<----------->| USB 2.5G NIC        |
#   | --iface, WAN port   |  forward    | --peer-if, LAN port |
#   +---------------------+             +---------------------+
#
# One arm sends (TX, host -> peer), the next receives (RX, peer -> host).
# They are separate iperf3 runs, never one bidirectional run.  A listener
# check runs on the peer before every arm; if the server is not listening the
# arm is invalid and the script exits nonzero.
#
# Exit status:
#   0  both directions >= 2.2 Gbit/s (gate pass)
#   3  the slower valid direction is 1.5-2.2 Gbit/s (2.5G-only)
#   4  the slower valid direction is < 1.5 Gbit/s (close the 10G line)
#   1  an arm was invalid (listener, link speed, iperf3, parse)
#   2  usage or missing local prerequisite
#

set -u

IFACE=${IFACE:-}
PEER=${PEER:-}
PEER_SSH=${PEER_SSH:-}
PEER_IF=${PEER_IF:-}
PORT=${PORT:-5201}
DURATION=${DURATION:-60}
PARALLEL=${PARALLEL:-4}
OUT=${OUT:-}
DRY_RUN=0
SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3}
SERVER_LOG=${SERVER_LOG:-/tmp/wan-bench-2.5g-server.log}

# Gate thresholds, Mbit/s.
PASS_MBPS=2200
FLOOR_MBPS=1500

usage() {
	cat <<'EOF'
Usage: 2.5g.sh --iface IFACE --peer IP [options]

Measure a 2.5G WAN/LAN path with two RTL8156B-class USB NICs, one on the
WAN side and one on the LAN side.  TX and RX are separate iperf3 runs.

Required:
  --iface NAME        local 2.5G NIC connected to the router WAN port
  --peer IPv4         peer address on the LAN side

Options:
  --peer-ssh USER@HOST  SSH target for the peer (default root@PEER)
  --peer-if NAME        peer 2.5G NIC; its link speed is recorded and gated
  --port N              iperf3 port (default 5201)
  --duration N          seconds per arm (default 60)
  --parallel N          iperf3 streams (default 4)
  --out FILE            result.json path (default wan-2.5g-<UTC>.json)
  --dry-run             print commands and result path; run nothing
  -h, --help            this text

Exit: 0 pass, 3 2.5G-only, 4 close 10G line, 1 invalid arm, 2 usage.
EOF
}

die() {
	printf 'ERROR: %s\n' "$1" >&2
	exit "${2:-2}"
}

say() {
	printf '%s\n' "$1"
}

need_arg() {
	[ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value" 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--iface) need_arg "$1" "${2:-}"; IFACE=$2; shift 2 ;;
	--peer) need_arg "$1" "${2:-}"; PEER=$2; shift 2 ;;
	--peer-ssh) need_arg "$1" "${2:-}"; PEER_SSH=$2; shift 2 ;;
	--peer-if) need_arg "$1" "${2:-}"; PEER_IF=$2; shift 2 ;;
	--port) need_arg "$1" "${2:-}"; PORT=$2; shift 2 ;;
	--duration) need_arg "$1" "${2:-}"; DURATION=$2; shift 2 ;;
	--parallel) need_arg "$1" "${2:-}"; PARALLEL=$2; shift 2 ;;
	--out) need_arg "$1" "${2:-}"; OUT=$2; shift 2 ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) die "unknown option: $1" 2 ;;
	esac
done

[ -n "$IFACE" ] || die "--iface is required" 2
[ -n "$PEER" ] || die "--peer is required" 2
[ -n "$PEER_SSH" ] || PEER_SSH="root@$PEER"
[ -n "$OUT" ] || OUT="wan-2.5g-$(date -u +%Y%m%dT%H%M%SZ).json"
OUTDIR=${OUT%/*}
[ "$OUTDIR" = "$OUT" ] && OUTDIR=.
RAWTX="$OUTDIR/2.5g-tx.raw.json"
RAWRX="$OUTDIR/2.5g-rx.raw.json"

if [ "$DRY_RUN" = 1 ]; then
	say "DRY-RUN wan-bench/2.5g.sh"
	say "  local NIC:  $IFACE"
	say "  peer:       $PEER ($PEER_SSH)"
	say "  peer NIC:   ${PEER_IF:-not recorded}"
	say "  result:     $OUT"
	say "  raw TX/RX:  $RAWTX / $RAWRX"
	say "  listener:   ssh $PEER_SSH 'ss -ltnp | grep :$PORT '"
	say "  TX command: iperf3 -c $PEER -p $PORT -t $DURATION -P $PARALLEL -J"
	say "  RX command: iperf3 -c $PEER -p $PORT -t $DURATION -P $PARALLEL -R -J"
	say "  gate: min(valid receiver Mbit/s) >= $PASS_MBPS pass; >= $FLOOR_MBPS 2.5G-only; else close 10G line"
	exit 0
fi

[ -d "/sys/class/net/$IFACE" ] || die "local NIC $IFACE does not exist" 2
command -v iperf3 >/dev/null 2>&1 || die "iperf3 is not installed locally" 2
command -v ssh >/dev/null 2>&1 || die "ssh is not installed locally" 2
command -v python3 >/dev/null 2>&1 || die "python3 is not installed locally" 2
mkdir -p "$OUTDIR" || die "cannot create $OUTDIR" 2

local_speed() {
	cat "/sys/class/net/$IFACE/speed" 2>/dev/null || printf 'unknown'
}

local_driver() {
	readlink "/sys/class/net/$IFACE/device/driver" 2>/dev/null | sed 's#.*/##'
}

cpu_total() {
	awk '/^cpu /{for (i=2; i<=NF; i++) s+=$i} END{print s+0}' /proc/stat
}

peer_speed() {
	[ -n "$PEER_IF" ] || { printf 'unknown'; return 0; }
	# shellcheck disable=SC2029
	ssh $SSH_OPTS "$PEER_SSH" "cat /sys/class/net/$PEER_IF/speed 2>/dev/null" 2>/dev/null ||
		printf 'unknown'
}

server_start() {
	# shellcheck disable=SC2029
	ssh $SSH_OPTS "$PEER_SSH" \
		"pkill -f 'iperf3 -s -p $PORT' >/dev/null 2>&1 || true; nohup iperf3 -s -1 -p $PORT >$SERVER_LOG 2>&1 &" ||
		die "cannot start iperf3 server on $PEER_SSH" 1
	# Wait until the listener is visible; do not race the first arm.
	i=0
	while [ "$i" -lt 10 ]; do
		# shellcheck disable=SC2029
		if ssh $SSH_OPTS "$PEER_SSH" "ss -ltnp | grep ':$PORT '" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

listener_check() {
	# shellcheck disable=SC2029
	ssh $SSH_OPTS "$PEER_SSH" "ss -ltnp | grep ':$PORT '" 2>&1
}

parse_arm() {
	# $1 raw json, $2 arm name; prints "sender receiver retr" or "nan nan nan"
	python3 - "$1" <<'PY' 2>/dev/null || printf 'nan nan nan\n'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    s = d["end"]["sum_sent"]
    r = d["end"]["sum_received"]
    print("%.3f %.3f %s" % (s["bits_per_second"] / 1e6,
                            r["bits_per_second"] / 1e6,
                            s.get("retransmits", "nan")))
except Exception:
    print("nan nan nan")
PY
}

record_env() {
	# $1 arm name; environment snapshot next to the raw log
	f=$OUTDIR/2.5g-$1.env.txt
	{
		printf 'utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'iface=%s\n' "$IFACE"
		printf 'speed_mbps=%s\n' "$(local_speed)"
		printf 'driver=%s\n' "$(local_driver)"
		printf 'peer=%s\n' "$PEER"
		printf 'peer_if=%s\n' "${PEER_IF:-}"
		printf 'peer_speed_mbps=%s\n' "$(peer_speed)"
		printf 'mtu=%s\n' "$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null || echo unknown)"
		printf 'iperf3=%s\n' "$(iperf3 --version 2>/dev/null | head -1)"
	} >"$f"
}

TX_S=nan TX_R=nan TX_RETR=nan TX_CPU=nan TX_VALID=0 TX_NOTE=
RX_S=nan RX_R=nan RX_RETR=nan RX_CPU=nan RX_VALID=0 RX_NOTE=

say "wan-bench/2.5g: local=$IFACE peer=$PEER port=$PORT ${DURATION}s P$PARALLEL"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Preconditions: both link speeds must be 2500 when the peer NIC is named.
lspeed=$(local_speed)
[ "$lspeed" = 2500 ] || die "local link speed is $lspeed Mb/s, expected 2500" 1
pspeed=$(peer_speed)
if [ -n "$PEER_IF" ] && [ "$pspeed" != 2500 ]; then
	die "peer link speed is $pspeed Mb/s, expected 2500" 1
fi

# ---- TX arm -------------------------------------------------------------
record_env tx
server_start || { TX_NOTE="server not listening before TX"; }
if [ -z "$TX_NOTE" ]; then
	cpu0=$(cpu_total)
	# shellcheck disable=SC2029
	iperf3 -c "$PEER" -p "$PORT" -t "$DURATION" -P "$PARALLEL" -J \
		>"$RAWTX" 2>"$OUTDIR/2.5g-tx.err"
	rc=$?
	cpu1=$(cpu_total)
	TX_CPU=$((cpu1 - cpu0))
	set -- $(parse_arm "$RAWTX" tx)
	TX_S=$1 TX_R=$2 TX_RETR=$3
	if [ "$rc" -eq 0 ] && [ "$TX_R" != nan ]; then
		TX_VALID=1
	else
		TX_NOTE="iperf3 rc=$rc or unparsable JSON"
	fi
fi

# ---- RX arm -------------------------------------------------------------
record_env rx
server_start || { RX_NOTE="server not listening before RX"; }
if [ -z "$RX_NOTE" ]; then
	cpu0=$(cpu_total)
	# shellcheck disable=SC2029
	iperf3 -c "$PEER" -p "$PORT" -t "$DURATION" -P "$PARALLEL" -R -J \
		>"$RAWRX" 2>"$OUTDIR/2.5g-rx.err"
	rc=$?
	cpu1=$(cpu_total)
	RX_CPU=$((cpu1 - cpu0))
	set -- $(parse_arm "$RAWRX" rx)
	RX_S=$1 RX_R=$2 RX_RETR=$3
	if [ "$rc" -eq 0 ] && [ "$RX_R" != nan ]; then
		RX_VALID=1
	else
		RX_NOTE="iperf3 rc=$rc or unparsable JSON"
	fi
fi

# ---- gate ---------------------------------------------------------------
verdict=invalid
gate_mbps=nan
if [ "$TX_VALID" = 1 ] && [ "$RX_VALID" = 1 ]; then
	gate_mbps=$(python3 - "$TX_R" "$RX_R" <<'PY'
import sys
print("%.3f" % min(float(sys.argv[1]), float(sys.argv[2])))
PY
)
	verdict=$(python3 - "$gate_mbps" "$PASS_MBPS" "$FLOOR_MBPS" <<'PY'
import sys
m, hi, lo = map(float, sys.argv[1:4])
print("pass" if m >= hi else ("2.5g-only" if m >= lo else "close-10g-line"))
PY
)
fi

export OUT IFACE PEER PEER_IF PORT DURATION PARALLEL STARTED="$started"
export LS_SPEED="$lspeed" PS_SPEED="$pspeed"
export TX_S TX_R TX_RETR TX_CPU TX_VALID TX_NOTE RAWTX
export RX_S RX_R RX_RETR RX_CPU RX_VALID RX_NOTE RAWRX
export GATE_MBPS="$gate_mbps" VERDICT="$verdict" PASS_MBPS FLOOR_MBPS

python3 - "$OUT" <<'PY'
import json, os, sys

def num(v):
    return None if v == "nan" else float(v)

def integer(v):
    return None if v == "nan" else int(v)

out = {
    "schema": "wan-bench-2.5g/v1",
    "started_utc": os.environ["STARTED"],
    "iface": {
        "name": os.environ["IFACE"],
        "speed_mbps": num(os.environ.get("LS_SPEED", "nan")),
        "driver": os.popen("readlink /sys/class/net/%s/device/driver 2>/dev/null" %
                           os.environ["IFACE"]).read().strip().split("/")[-1] or None,
    },
    "peer": {
        "host": os.environ["PEER"],
        "iface": os.environ.get("PEER_IF") or None,
        "speed_mbps": num(os.environ.get("PS_SPEED", "nan")),
    },
    "config": {
        "port": int(os.environ["PORT"]),
        "duration_s": int(os.environ["DURATION"]),
        "parallel": int(os.environ["PARALLEL"]),
        "directions": ["tx", "rx"],
    },
    "arms": [
        {
            "name": "tx",
            "valid": os.environ["TX_VALID"] == "1",
            "sender_mbps": num(os.environ["TX_S"]),
            "receiver_mbps": num(os.environ["TX_R"]),
            "retransmits": os.environ["TX_RETR"],
            "cpu_jiffies_delta": integer(os.environ["TX_CPU"]),
            "raw_log": os.environ["RAWTX"],
            "note": os.environ["TX_NOTE"],
        },
        {
            "name": "rx",
            "valid": os.environ["RX_VALID"] == "1",
            "sender_mbps": num(os.environ["RX_S"]),
            "receiver_mbps": num(os.environ["RX_R"]),
            "retransmits": os.environ["RX_RETR"],
            "cpu_jiffies_delta": integer(os.environ["RX_CPU"]),
            "raw_log": os.environ["RAWRX"],
            "note": os.environ["RX_NOTE"],
        },
    ],
    "gate": {
        "basis": "min(receiver_mbps of both valid arms)",
        "min_receiver_mbps": num(os.environ["GATE_MBPS"]),
        "pass_mbps": float(os.environ["PASS_MBPS"]),
        "floor_mbps": float(os.environ["FLOOR_MBPS"]),
        "verdict": os.environ["VERDICT"],
    },
}
with open(sys.argv[1], "w") as f:
    json.dump(out, f, indent=2, sort_keys=True)
    f.write("\n")
PY

say "result: $OUT"
say "TX: sender=$TX_S receiver=$TX_R retr=$TX_RETR cpu_jiffies=$TX_CPU valid=$TX_VALID"
say "RX: sender=$RX_S receiver=$RX_R retr=$RX_RETR cpu_jiffies=$RX_CPU valid=$RX_VALID"
say "gate: $verdict (min receiver ${gate_mbps} Mbit/s; pass >= $PASS_MBPS, floor >= $FLOOR_MBPS)"

case "$verdict" in
pass) exit 0 ;;
2.5g-only) exit 3 ;;
close-10g-line) exit 4 ;;
*) exit 1 ;;
esac
