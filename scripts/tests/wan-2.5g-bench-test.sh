#!/bin/sh
#
# wan-2.5g-bench-test.sh - offline self-test for tools/wan-bench/2.5g.sh.
#
# Builds a fake sysfs tree plus fake iperf3/ssh/ethtool/nft/uci commands in a
# temp dir and asserts the two things the 2.5G decision gate rests on:
#
#   - with a 1000 Mb/s link the script refuses before any iperf3 traffic, exits
#     1, and still leaves the pre ethtool snapshot as its own evidence;
#   - with 2500 Mb/s on both ends both arms are valid, result.json carries the
#     pass verdict, and the pre/tx/rx snapshots exist and are named in it.
#
# Usage: scripts/tests/wan-2.5g-bench-test.sh

set -eu

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT=${WAN_25G_SCRIPT:-$ROOT/tools/wan-bench/2.5g.sh}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

BIN=$TMP/bin
SYS=$TMP/sys
mkdir -p "$BIN" "$SYS/class/net/bench0" "$SYS/class/net/peer0"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# One netdev in fake sysfs; $1 iface, $2 speed.
mknic() {
	mkdir -p "$SYS/class/net/$1"
	printf '%s\n' "$2" >"$SYS/class/net/$1/speed"
	printf '1500\n' >"$SYS/class/net/$1/mtu"
}

# --- fakes ---------------------------------------------------------------
cat >"$BIN/ethtool" <<'EOF'
#!/bin/sh
case "$1" in
-i) printf 'driver: r8152\nversion: v1.12.13\n' ;;
-S) printf '     tx_packets: 1\ntx_packets: 1\n     rx_packets: 1\n' ;;
*)
	# Real ethtool wraps mode lists onto indented lines with no label; keep that
	# shape so snap_field's continuation handling is actually exercised.
	printf 'Settings for %s:\n' "$1"
	printf '\tSupported link modes:   1000baseT/Full\n'
	printf '\t                        2500baseT/Full\n'
	printf '\tAdvertised link modes:  1000baseT/Full\n'
	printf '\t                        2500baseT/Full\n'
	printf '\tSpeed: 2500Mb/s\n'
	printf '\tDuplex: Full\n'
	;;
esac
EOF

cat >"$BIN/iperf3" <<'EOF'
#!/bin/sh
printf 'iperf3 %s\n' "$*" >>"$FAKE_CALLS"
# Emit just enough iperf3 -J JSON for parse_arm.
printf '{"end":{"sum_sent":{"bits_per_second":2400000000,"retransmits":3},'
printf '"sum_received":{"bits_per_second":2350000000}}}\n'
EOF

cat >"$BIN/ssh" <<'EOF'
#!/bin/sh
printf 'ssh %s\n' "$*" >>"$FAKE_CALLS"
# The remote command is always the last argument (options come first).
for cmd in "$@"; do :; done
case "$cmd" in
*listener*|*'ss -ltnp'*) printf 'LISTEN 0 128 *:5201 *:*\n'; exit 0 ;;
*speed*) cat "$FAKE_SYS/class/net/peer0/speed"; exit 0 ;;
esac
# Anything else runs like a remote shell would, with the fakes on PATH.
PATH=$FAKE_BIN:$PATH exec sh -c "$cmd"
EOF

cat >"$BIN/pkill" <<'EOF'
#!/bin/sh
printf 'pkill %s\n' "$*" >>"$FAKE_CALLS"
EOF

cat >"$BIN/nft" <<'EOF'
#!/bin/sh
printf 'table inet fw4 {\n\tflowtable ft {\n\t\tdevices = { "lan2", "wan" }\n\t\tflags offload\n\t}\n}\n'
EOF

cat >"$BIN/uci" <<'EOF'
#!/bin/sh
printf "firewall.@defaults[0].flow_offloading='1'\n"
EOF

chmod +x "$BIN"/*

export FAKE_CALLS="$TMP/calls.log" FAKE_BIN="$BIN" FAKE_SYS="$SYS"
: >"$FAKE_CALLS"

# The peer NIC is 2.5G throughout; only the local one changes per case.
mknic peer0 2500

# --- case 1: 1 Gb/s link must refuse --------------------------------------
mknic bench0 1000
rc=0
OUT="$TMP/a.json" SYSFS="$SYS" PATH="$BIN:$PATH" \
	"$SCRIPT" --iface bench0 --peer 192.0.2.10 --peer-if peer0 --out "$TMP/a.json" \
	>"$TMP/a.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "1G link: expected exit 1, got $rc"
grep -q 'expected 2500' "$TMP/a.log" || fail "1G link: no refusal message"
grep -q iperf3 "$FAKE_CALLS" && fail "1G link: iperf3 ran despite refusal"
[ -f "$TMP/2.5g-pre.bench0.txt" ] || fail "1G link: pre ethtool snapshot missing"
grep -q 'Advertised link modes' "$TMP/2.5g-pre.bench0.txt" ||
	fail "1G link: snapshot lacks link modes"

# --- case 2: 2.5G both ends must pass ------------------------------------
mknic bench0 2500
rm -f "$TMP/a.json"
: >"$FAKE_CALLS"
rc=0
SYSFS="$SYS" PATH="$BIN:$PATH" \
	"$SCRIPT" --iface bench0 --peer 192.0.2.10 --peer-if peer0 \
	--router root@192.0.2.1 --duration 1 --parallel 1 --out "$TMP/b.json" \
	>"$TMP/b.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { sed 's/^/  /' "$TMP/b.log" >&2; fail "2.5G: expected exit 0, got $rc"; }

for f in 2.5g-pre.bench0.txt 2.5g-tx.bench0.txt 2.5g-rx.bench0.txt 2.5g-pre.router.txt; do
	[ -f "$TMP/$f" ] || fail "2.5G: missing snapshot $f"
done

python3 - "$TMP/b.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
assert d["gate"]["verdict"] == "pass", d["gate"]
assert d["iface"]["speed_mbps"] == 2500, d["iface"]
assert d["iface"]["advertised_link_modes"] == "1000baseT/Full 2500baseT/Full", d["iface"]
assert d["iface"]["supported_link_modes"] == "1000baseT/Full 2500baseT/Full", d["iface"]
assert d["iface"]["duplex"] == "Full", d["iface"]
assert [a["valid"] for a in d["arms"]] == [True, True], d["arms"]
assert all(a["receiver_mbps"] == 2350.0 for a in d["arms"]), d["arms"]
snaps = d["snapshots"]
assert snaps["pre"]["local"].endswith("2.5g-pre.bench0.txt"), snaps
assert snaps["pre"]["router"].endswith("2.5g-pre.router.txt"), snaps
assert snaps["rx"]["peer"].endswith("2.5g-rx.peer0.txt"), snaps
print("result.json ok")
PY

grep -q 'iperf3 -c 192.0.2.10' "$FAKE_CALLS" || fail "2.5G: TX arm never ran"
grep -q -- '-R' "$FAKE_CALLS" || fail "2.5G: RX arm (iperf3 -R) never ran"
grep -q 'flags offload' "$TMP/2.5g-pre.router.txt" ||
	fail "2.5G: router snapshot lacks the flowtable body"
grep -q 'flow_offloading' "$TMP/2.5g-pre.router.txt" ||
	fail "2.5G: router snapshot lacks the flow_offloading setting"
grep -q 'Advertised link modes' "$TMP/2.5g-pre.peer0.txt" ||
	fail "2.5G: peer snapshot lacks link modes"

printf 'ok: wan-2.5g-bench-test.sh\n'
