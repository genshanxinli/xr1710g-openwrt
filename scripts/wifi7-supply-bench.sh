#!/bin/sh
#
# wifi7-supply-bench.sh - Wi-Fi 7 supply-limited A-MPDU/MLO bench (D11).
#
# The question this harness answers is *why* a Wi-Fi 7 throughput number
# stopped where it did: is the feed into the AP the limit (the host NIC,
# usually 1GbE at ~940 Mbit/s), or is the air/AP/STA path the limit?
#
# Topology (the host runs this script):
#
#     host  --feed NIC-->  AP (MT7996)  --- Wi-Fi 7 --->  real STA
#     ^                     ^                                ^
#     |                     |                                |
#   --host-if          --device (ssh)                  iperf3 server
#
# The host sends a TCP flow to the STA through the AP.  It samples the
# AP's read-only debugfs counters around the run and records the feed
# link rate.  The 1GbE host NIC is the most likely supply bottleneck on
# this board: a number measured while the AP is fed at 1GbE is the feed
# limit, not the Wi-Fi limit.  When 2.5G/10G is not present the script
# prints SUPPLY-LIMITED and stamps it on every throughput row.
#
# The feed may also be a USB MT7925 (or another Wi-Fi 7 STA) on the host:
# --host-if is then a wireless netdev and the script records the STA link
# instead of an ethtool speed ("SUPPLY-WIFI").  That path shares the air,
# so it is labelled separately from a wired 2.5G/10G feed.
#
# Everything the script reads from the device is read-only:
#
#   - iw dev <sta> station dump            (associated STA, per-link rates,
#                                           signal, retries, A-MPDU counters)
#   - /sys/kernel/debug/ieee80211/*/mt76/hw-queues
#                                          (PLE/PSE queue depth and per-STA
#                                           AC queue depth: the "is the
#                                           driver not feeding the air?"
#                                           discriminator)
#   - /sys/kernel/debug/ieee80211/*/mt76/tx_stats
#                                          (per-phy A-MPDU length histogram,
#                                           BA miss count; skipped with a
#                                           "unavailable" row when absent)
#   - hostapd_cli -i <sta> get_config      (current EDCA tx_queue_data0..3
#                                           TXOP/burst values, i.e. the
#                                           applied 6G/5G EDCA state)
#   - any /sys/kernel/debug/ieee80211/*/mt76/edca* debugfs node
#                                          (read if a future EDCA TXOP patch,
#                                           e.g. 0016, exposes one)
#   - ethtool / sysfs speed of --host-if   (feed rate)
#
# The script never writes a debugfs node or rewrites EDCA parameters,
# never loads a module, never edits UCI, DTS or a patch, and never applies
# or reverts the EDCA TXOP patch.  It only runs iperf3 (traffic, no config)
# and writes the local TSV named by --out.
#
# A/B record for the EDCA TXOP patch (0016 and friends): this script is the
# recording half, not the patch driver.  Run it once per image/arm and diff
# the TSVs:
#
#     BENCH_LABEL=base ./scripts/wifi7-supply-bench.sh --host-if eth0 ...
#     BENCH_LABEL=0016 ./scripts/wifi7-supply-bench.sh --host-if eth0 ...
#
# The EDCA txop rows, the tx_stats histogram, hw-queues and the station dump
# are the comparison fields; a change in EDCA is visible without touching
# the device.
#
# Output: one TSV (tab separated) at --out with the header
#
#     timestamp  phase  source  item  value  unit  note
#
# phase is pre/run/post; source is supply, device, station dump, hw-queues,
# tx_stats, EDCA txop, iperf3 or meta.  Raw device text is emitted one line
# per row (item=line), with tabs and CRs replaced by spaces, so the file is
# diffable between arms and greppable for hw-queues / station dump /
# EDCA txop / SUPPLY-LIMITED.
#
# Usage:
#     ./scripts/wifi7-supply-bench.sh --host-if eth0 --device root@192.168.1.1 \
#         --sta phy0-ap0 --duration 60 --out run.tsv
#     ./scripts/wifi7-supply-bench.sh --dry-run
#
# --sta is the *device-side* wireless interface whose station dump is read
# (OpenWrt names are e.g. phy0-ap0, phy1-ap0 or wlan0), not the station MAC.
# The associated station MAC is taken from that dump; if several stations
# are associated, the first one with an IP in the AP's ARP/neigh/DHCP table
# is used.  STA_MAC=<mac> selects one explicitly; STA_IP=<ipv4> overrides
# the looked-up address (needed when the STA has no ARP entry yet).
#
# SSH must work non-interactively (key or agent; BatchMode=yes) and the
# login must be able to read debugfs (root on OpenWrt).  hostapd_cli is
# optional: without it the EDCA rows say HOSTAPD_CLI_MISSING, and the rest
# of the run still completes.
#
# Environment (all optional):
#   BENCH_LABEL    arm label recorded in the meta rows (e.g. base, 0016)
#   STA_MAC        select this associated station (lower/upper case hex)
#   STA_IP         override the station IPv4 used as the iperf3 target
#   IPERF3_EXTRA   extra iperf3 arguments, word-split, appended as-is
#                  (e.g. "-P 4" or "-R" for STA->host); -J/--json is refused
#
# Exit status: 0 success or clean SKIP (no associated STA), 1 runtime
# failure (ssh, missing local tool, no station IP, iperf3 failure), 2 bad
# arguments.  --dry-run always exits 0 and never contacts the device.

set -u
set -f
LC_ALL=C
export LC_ALL

PROG=${0##*/}
HOST_IF=
DEVICE=192.168.1.1
STA=
DURATION=60
OUT=
DRY_RUN=0
SCHEMA=wifi7-supply-bench/v1

# Shared "no client" record (scripts/wireless/lib/no-client.sh).  Best effort:
# a harness must still skip, and still exit 0, when the record cannot be
# written.
NO_CLIENT_LIB=$(dirname "$0")/wireless/lib/no-client.sh
# shellcheck source=wireless/lib/no-client.sh
[ -r "$NO_CLIENT_LIB" ] && . "$NO_CLIENT_LIB"

# Populated during the run.
STA_DUMP=
STA_MACS=
SEL_MAC=
TARGET_IP=
IP_SOURCE=
SUPPLY_CLASS=
SUPPLY_SPEED=
IPERF_LOG=

usage() {
	cat <<'EOF'
Usage: wifi7-supply-bench.sh [options]

Wi-Fi 7 supply-limited A-MPDU/MLO bench.  Run on the host that feeds the AP.
A TCP iperf3 flow is sent from this host to a real station through the AP;
the AP's read-only mt76/hostapd state is sampled before and after the run.
The TSV records the feed rate and the air/queue counters so a 1GbE feed can
never be mistaken for the Wi-Fi limit.

Options:
  --host-if IFACE    host feed interface (required for a real run).  A wired
                    2.5G/10G NIC is the intended path; a USB MT7925/other
                    Wi-Fi 7 STA netdev is accepted and labelled SUPPLY-WIFI.
  --device HOST      AP ssh target (default: 192.168.1.1)
  --sta IFACE        device-side wireless interface whose station dump is
                     read, e.g. phy0-ap0 (required for a real run)
  --duration SEC     iperf3 duration in seconds (default: 60)
  --out FILE         output TSV (default: wifi7-supply-bench-<UTC>.tsv);
                     an existing file is never overwritten
  --dry-run          print the planned read-only commands and prerequisites,
                     then exit 0; does not ssh, does not run iperf3 and does
                     not create a file
  -h, --help         this text

Required for a real run: a 2.5G/10G (or USB MT7925 Wi-Fi 7) feed on
--host-if, a real associated STA on --sta, non-interactive ssh to --device,
and an iperf3 server on the station.  debugfs must be mounted and readable
by the ssh user (root on OpenWrt); hostapd_cli is optional.

What is read (never written):
  ssh <device> iw dev <sta> station dump
  cat /sys/kernel/debug/ieee80211/*/mt76/hw-queues
  cat /sys/kernel/debug/ieee80211/*/*/stations/<sta-mac>/hw-queues
  cat /sys/kernel/debug/ieee80211/*/mt76/tx_stats        (A-MPDU histogram)
  hostapd_cli -i <sta> get_config                         (EDCA txop values)
  cat /sys/kernel/debug/ieee80211/*/mt76/edca*            (if a patch adds it)
  ethtool <host-if> / sysfs speed / iw dev <host-if> link

The script never writes a debugfs node or changes EDCA parameters,
never loads a module, never edits UCI/DTS/patches and never applies or
reverts an EDCA patch.  It runs iperf3 (traffic only) and writes the TSV.

Environment overrides:
  BENCH_LABEL    arm label for the meta rows (default: unlabeled)
  STA_MAC        select one associated station instead of the first with IP
  STA_IP         override the station IPv4 used as the iperf3 target
  IPERF3_EXTRA   extra iperf3 args (word-split), e.g. "-P 4" or "-R";
                 -J/--json is refused because the TSV parses text output

Examples:
  ./scripts/wifi7-supply-bench.sh --host-if eth0 --device root@192.168.1.1 \
      --sta phy0-ap0 --duration 60 --out run.tsv
  BENCH_LABEL=base ./scripts/wifi7-supply-bench.sh --host-if eth0 \
      --device root@192.168.1.1 --sta phy0-ap0 --out base.tsv
  ./scripts/wifi7-supply-bench.sh --dry-run

Exit status: 0 ok or clean SKIP (no associated STA), 1 runtime failure,
2 bad arguments.  --dry-run always exits 0.
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf 'Try "%s --help" for usage.\n' "$PROG" >&2
	exit 2
}

die() {
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	exit 1
}

warn() {
	printf '%s: warning: %s\n' "$PROG" "$1" >&2
}

note() {
	printf '%s: %s\n' "$PROG" "$1"
}

now_ts() {
	_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || _ts=unknown
	printf '%s' "$_ts"
}

# Replace the characters that would break the TSV one-record-per-line shape.
tsv_sanitize() {
	printf '%s' "$1" | tr '\t\r\n' '   '
}

emit_row() {
	_ts=$(now_ts)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$_ts" "$(tsv_sanitize "$1")" "$(tsv_sanitize "$2")" \
		"$(tsv_sanitize "$3")" "$(tsv_sanitize "$4")" \
		"$(tsv_sanitize "$5")" "$(tsv_sanitize "$6")" >>"$OUT"
}

emit_text() {
	# $1 phase, $2 source, $3 multi-line text; one TSV row per non-empty line.
	printf '%s\n' "$3" | while IFS= read -r _line; do
		_line=$(printf '%s' "$_line" | tr '\t\r' '  ')
		[ -n "$_line" ] || continue
		emit_row "$1" "$2" line "$_line" - -
	done
}

valid_iface() {
	case $1 in
	''|*[!A-Za-z0-9_.:@+-]*) return 1 ;;
	esac
	return 0
}

valid_mac() {
	printf '%s' "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}

valid_ipv4() {
	case $1 in
	''|*[!0-9.]*) return 1 ;;
	esac
	_octets=$(printf '%s' "$1" | awk -F. 'NF == 4 { n = 0; for (i = 1; i <= 4; i++) if ($i ~ /^[0-9]+$/ && $i >= 0 && $i <= 255) n++; print n }')
	[ "$_octets" = 4 ]
}

valid_duration() {
	case $1 in
	''|*[!0-9]*) return 1 ;;
	esac
	[ "$1" -gt 0 ]
}

dev_ssh() {
	# Read-only remote command.  BatchMode fails instead of prompting; the
	# explicit PATH finds iw/hostapd_cli on a non-interactive dropbear login.
	ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
		"$DEVICE" "export PATH=/usr/sbin:/usr/bin:/sbin:/bin:\$PATH; $1"
}

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
	case $1 in
	--host-if)
		[ $# -ge 2 ] || usage_error "--host-if needs an interface name"
		HOST_IF=$2
		shift 2
		;;
	--host-if=*)
		HOST_IF=${1#*=}
		shift
		;;
	--device)
		[ $# -ge 2 ] || usage_error "--device needs an ssh target"
		DEVICE=$2
		shift 2
		;;
	--device=*)
		DEVICE=${1#*=}
		shift
		;;
	--sta)
		[ $# -ge 2 ] || usage_error "--sta needs a device-side wireless interface"
		STA=$2
		shift 2
		;;
	--sta=*)
		STA=${1#*=}
		shift
		;;
	--duration)
		[ $# -ge 2 ] || usage_error "--duration needs a value in seconds"
		DURATION=$2
		shift 2
		;;
	--duration=*)
		DURATION=${1#*=}
		shift
		;;
	--out)
		[ $# -ge 2 ] || usage_error "--out needs a file name"
		OUT=$2
		shift 2
		;;
	--out=*)
		OUT=${1#*=}
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--help|-h)
		usage
		exit 0
		;;
	--)
		shift
		[ $# -eq 0 ] || usage_error "unexpected argument: $1"
		;;
	-*)
		usage_error "unknown option: $1"
		;;
	*)
		usage_error "unexpected argument: $1"
		;;
	esac
done

# -------------------------------------------------------------- dry-run mode

# Every value in the printed plan is either the user's argument or a
# placeholder; nothing is executed and nothing is written.
dry_run() {
	_hostif=${HOST_IF:-<host-if>}
	_device=${DEVICE:-<device>}
	_sta=${STA:-<sta>}
	_out=${OUT:-wifi7-supply-bench-<UTC>.tsv}
	_label=${BENCH_LABEL:-unlabeled}

	cat <<EOF
$PROG --dry-run
schema: $SCHEMA

Planned read-only commands (not executed):

[1/6] feed path (host, local)
  ethtool $_hostif || cat /sys/class/net/$_hostif/speed
  iw dev $_hostif link                       # only when $_hostif is wireless
  classify: 2500/10000 Mb/s -> SUPPLY-OK; 1GbE or unverified -> SUPPLY-LIMITED
  SUPPLY-LIMITED: air numbers measured through a 1GbE feed are the feed
  limit, not the Wi-Fi limit.

[2/6] device identity (ssh, read-only)
  ssh $_device 'uname -a; cat /etc/openwrt_release; iw --version'
  ssh $_device 'iw dev $_sta info'           # interface/channel/width/type

[3/6] station dump (ssh, read-only)
  ssh $_device 'iw dev $_sta station dump'
  -> associated STA MAC(s), signal, tx/rx rates, retries, A-MPDU counters,
     per-link MLO lines

[4/6] queue and EDCA evidence (ssh, read-only)
  ssh $_device 'cat /sys/kernel/debug/ieee80211/*/*/stations/<sta-mac>/hw-queues'
  ssh $_device 'cat /sys/kernel/debug/ieee80211/*/mt76/hw-queues'
  ssh $_device 'cat /sys/kernel/debug/ieee80211/*/mt76/tx_stats'
  ssh $_device 'hostapd_cli -i $_sta get_config | grep tx_queue_data'
  ssh $_device 'cat /sys/kernel/debug/ieee80211/*/mt76/edca*'
  EDCA txop: current hostapd tx_queue_data0..3 burst values; a future EDCA
  TXOP debugfs node (patch 0016 and friends) is read if present.
  tx_stats is the A-MPDU length histogram; if absent an "unavailable" row is
  written and the run continues.

[5/6] throughput
  iperf3 -c <sta-ip> -t $DURATION -B <host-if-ip> -f m
  target IPv4 comes from the AP ARP/neigh/DHCP table for the station MAC,
  or from STA_IP=<ipv4>; STA_MAC=<mac> selects between several stations.

[6/6] output
  $_out   (TSV: timestamp phase source item value unit note; label=$_label)

Prerequisites:
  - 2.5G/10G feed on --host-if, or a USB MT7925/Wi-Fi 7 STA feed
  - a real associated STA visible in \`iw dev <sta> station dump\`
  - non-interactive ssh to --device and root-readable debugfs
  - an iperf3 server on the station
  - hostapd_cli on the device for EDCA txop (optional; otherwise an
    "unavailable" row is recorded)

Not run by --dry-run: no ssh, no iperf3, no device read, no file written.
EOF
}

# ------------------------------------------------------ syntax validation

# Argument syntax is checked even for --dry-run, so a typo in a planned run
# is visible without contacting anything.  Required values (--host-if,
# --sta, tools, interface existence) are only enforced for a real run.
[ -n "$DEVICE" ] || usage_error "--device must not be empty"
valid_duration "$DURATION" || usage_error "--duration must be a positive integer, got '$DURATION'"

case $DEVICE in
-[!-]*) usage_error "invalid --device: must not start with '-'" ;;
*[[:space:]]*) usage_error "invalid --device (whitespace): $DEVICE" ;;
esac

[ -z "$HOST_IF" ] || valid_iface "$HOST_IF" || usage_error "invalid --host-if: $HOST_IF"
[ -z "$STA" ] || valid_iface "$STA" || usage_error "invalid --sta: $STA"

if [ -n "${STA_MAC:-}" ]; then
	valid_mac "$STA_MAC" || usage_error "invalid STA_MAC: $STA_MAC"
	STA_MAC=$(printf '%s' "$STA_MAC" | tr 'A-F' 'a-f')
fi
if [ -n "${STA_IP:-}" ]; then
	valid_ipv4 "$STA_IP" || usage_error "invalid STA_IP (IPv4 expected): $STA_IP"
fi
if [ -n "${IPERF3_EXTRA:-}" ]; then
	case $IPERF3_EXTRA in
	*-J*|*--json*) usage_error "IPERF3_EXTRA must not use -J/--json; the TSV parses text output" ;;
	esac
fi

if [ "$DRY_RUN" -eq 1 ]; then
	dry_run
	exit 0
fi

# --------------------------------------------------------------- validation

[ -n "$HOST_IF" ] || usage_error "--host-if is required for a real run"
[ -n "$STA" ] || usage_error "--sta is required for a real run"

command -v ssh >/dev/null 2>&1 || die "ssh not found on this host"
command -v iperf3 >/dev/null 2>&1 || die "iperf3 not found on this host"
command -v ip >/dev/null 2>&1 || die "ip not found on this host"

[ -e "/sys/class/net/$HOST_IF" ] || die "host interface '$HOST_IF' does not exist"

case $OUT in
'') OUT=$(printf './wifi7-supply-bench-%s.tsv' "$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || printf '%s' "$$")") ;;
esac
[ -e "$OUT" ] && die "refusing to overwrite existing --out: $OUT"
case $OUT in
*/*) _outdir=${OUT%/*} ;;
*) _outdir=. ;;
esac
[ -d "$_outdir" ] || die "output directory does not exist: $_outdir"

# ------------------------------------------------------------------- device

dev_ssh 'true' >/dev/null 2>&1 || die "cannot ssh to '$DEVICE' non-interactively (BatchMode=yes); check the key/agent and the host key"
dev_ssh 'command -v iw >/dev/null 2>&1 && command -v cat >/dev/null 2>&1' ||
	die "the device at '$DEVICE' is missing iw or cat; cannot read the station/queue state"

DEVICE_ID=$(dev_ssh 'uname -a; echo "--- /etc/openwrt_release"; cat /etc/openwrt_release 2>/dev/null; echo "--- iw"; iw --version 2>&1; true' 2>&1) ||
	die "failed to read the device identity over ssh"

STA_INFO=$(dev_ssh "iw dev $STA info 2>&1") ||
	die "iw dev $STA info failed on $DEVICE (is '$STA' the device-side wireless interface?)"

# ------------------------------------------------------------- feed interface

SUPPLY_ETHTOOL=
if command -v ethtool >/dev/null 2>&1; then
	SUPPLY_ETHTOOL=$(ethtool "$HOST_IF" 2>&1) || SUPPLY_ETHTOOL=
fi

SPEED_SYSFS=
if [ -r "/sys/class/net/$HOST_IF/speed" ]; then
	SPEED_SYSFS=$(cat "/sys/class/net/$HOST_IF/speed" 2>/dev/null) || SPEED_SYSFS=
fi
case $SPEED_SYSFS in
''|*[!0-9]*) SPEED_SYSFS= ;;
esac
# 0, -1 (printed as 4294967295 by some drivers) and absurd values mean
# "unknown": do not let them pass the 2.5G/10G check.
if [ -n "$SPEED_SYSFS" ]; then
	if [ "$SPEED_SYSFS" -le 0 ] 2>/dev/null || [ "$SPEED_SYSFS" -gt 1000000 ] 2>/dev/null; then
		SPEED_SYSFS=
	fi
fi

SPEED_ETHTOOL=
if [ -n "$SUPPLY_ETHTOOL" ]; then
	SPEED_ETHTOOL=$(printf '%s\n' "$SUPPLY_ETHTOOL" |
		sed -n 's/^[[:space:]]*Speed:[[:space:]]*\([0-9][0-9]*\)Mb\/s.*/\1/p' |
		head -n 1)
fi

SUPPLY_SPEED=${SPEED_ETHTOOL:-$SPEED_SYSFS}
case $SUPPLY_SPEED in
''|*[!0-9]*) SUPPLY_SPEED= ;;
esac
if [ -n "$SUPPLY_SPEED" ] && { [ "$SUPPLY_SPEED" -le 0 ] || [ "$SUPPLY_SPEED" -gt 1000000 ]; }; then
	SUPPLY_SPEED=
fi

SUPPLY_WIRELESS=0
[ -e "/sys/class/net/$HOST_IF/wireless" ] && SUPPLY_WIRELESS=1

WIFI_LINK=
if [ "$SUPPLY_WIRELESS" -eq 1 ] && command -v iw >/dev/null 2>&1; then
	WIFI_LINK=$(iw dev "$HOST_IF" link 2>&1) || WIFI_LINK=
fi

if [ "$SUPPLY_WIRELESS" -eq 1 ]; then
	SUPPLY_CLASS=SUPPLY-WIFI
elif [ -n "$SUPPLY_SPEED" ] && [ "$SUPPLY_SPEED" -ge 2500 ]; then
	SUPPLY_CLASS=SUPPLY-OK
else
	SUPPLY_CLASS=SUPPLY-LIMITED
fi

# -------------------------------------------------------------- station dump

STA_DUMP=$(dev_ssh "iw dev $STA station dump 2>&1") ||
	die "iw dev $STA station dump failed on $DEVICE"

STA_MACS=$(printf '%s\n' "$STA_DUMP" |
	sed -n 's/^Station \([0-9A-Fa-f:][0-9A-Fa-f:]*\).*/\1/p' |
	tr 'A-F' 'a-f' |
	awk '!seen[$0]++')

if [ -z "$STA_MACS" ]; then
	# No associated station: the feed/air split cannot be measured.  The
	# record names the missing client so hw-gap-report.sh lists it under #4;
	# the SKIP line stays the only thing on stdout.
	_rec=$(no_client_record "" 4 eht-client \
		'sh scripts/wifi7-supply-bench.sh --device <USER@DEVICE_IP> --host-if <HOST_IF> --sta <AP_STA_IFACE> --duration 60 --out <OUT.tsv>' \
		"no station associated on $STA" \
		"iw dev <sta> station dump lists one associated EHT station with an IPv4" \
		"supply classification row is SUPPLY-OK (>=2500 Mb/s) or SUPPLY-WIFI" \
		"iperf3 throughput and the AP tx/A-MPDU deltas land in the TSV" 2>/dev/null)
	note "SKIP: no station associated on $STA (empty station dump); nothing changed"
	if [ -n "$_rec" ]; then
		warn "missing eht-client #4; once it is available run: sh scripts/wifi7-supply-bench.sh --device <USER@DEVICE_IP> --host-if <HOST_IF> --sta <AP_STA_IFACE> --duration 60 --out <OUT.tsv>"
		warn "no-client record: $_rec"
	fi
	exit 0
fi

# Pick the station MAC and its IPv4.  Tables are read once and only when
# the previous one did not resolve.
ARP_TABLE=$(dev_ssh 'cat /proc/net/arp 2>/dev/null') || ARP_TABLE=
NEIGH_TABLE=
LEASES=

mac_in_list() {
	printf '%s\n' "$STA_MACS" | grep -qx -- "$1"
}

mac_ip() {
	# $1 MAC -> prints an IPv4 or nothing; uses the tables fetched above.
	printf '%s\n' "$ARP_TABLE" |
		awk -v m="$1" 'tolower($4) == m && $3 != "0x0" { print $1; exit }'
}

if [ -n "${STA_MAC:-}" ]; then
	mac_in_list "$STA_MAC" || die "STA_MAC $STA_MAC is not associated on $STA"
	SEL_MAC=$STA_MAC
else
	# Prefer a station whose IP is already in the AP's ARP table; otherwise
	# fall back to the first associated MAC and try neigh/DHCP afterwards.
	SEL_MAC=
	for _m in $STA_MACS; do
		if [ -n "$(mac_ip "$_m")" ]; then
			SEL_MAC=$_m
			break
		fi
	done
	[ -n "$SEL_MAC" ] || SEL_MAC=$(printf '%s\n' "$STA_MACS" | head -n 1)
	[ "$(printf '%s\n' "$STA_MACS" | wc -l | tr -d ' ')" -gt 1 ] &&
		warn "several stations associated on $STA; using $SEL_MAC (set STA_MAC=<mac> to choose)"
fi

if [ -n "${STA_IP:-}" ]; then
	TARGET_IP=$STA_IP
	IP_SOURCE=override
else
	TARGET_IP=$(mac_ip "$SEL_MAC")
	IP_SOURCE=arp
	if [ -z "$TARGET_IP" ]; then
		NEIGH_TABLE=$(dev_ssh 'ip neigh show 2>/dev/null') || NEIGH_TABLE=
		TARGET_IP=$(printf '%s\n' "$NEIGH_TABLE" |
			awk -v m="$SEL_MAC" 'tolower($3) == m { print $1; exit }')
		IP_SOURCE=neigh
	fi
	if [ -z "$TARGET_IP" ]; then
		LEASES=$(dev_ssh 'cat /tmp/dhcp.leases 2>/dev/null') || LEASES=
		TARGET_IP=$(printf '%s\n' "$LEASES" |
			awk -v m="$SEL_MAC" 'tolower($2) == m { print $3; exit }')
		IP_SOURCE=dhcp-leases
	fi
	if [ -z "$TARGET_IP" ]; then
		HOST_NEIGH=$(ip neigh show 2>/dev/null) || HOST_NEIGH=
		TARGET_IP=$(printf '%s\n' "$HOST_NEIGH" |
			awk -v m="$SEL_MAC" 'tolower($3) == m { print $1; exit }')
		IP_SOURCE=host-neigh
	fi
fi

if [ -z "$TARGET_IP" ]; then
	die "no IPv4 for station $SEL_MAC on $DEVICE; set STA_IP=<ipv4> (or make the AP see an ARP/neigh entry)"
fi
valid_ipv4 "$TARGET_IP" || die "resolved station address is not IPv4: $TARGET_IP"

SRC_IP=$(ip -4 -o addr show dev "$HOST_IF" 2>/dev/null |
	awk '$3 == "inet" { sub(/\/.*/, "", $4); print $4; exit }')
[ -n "$SRC_IP" ] || die "no IPv4 address on --host-if $HOST_IF; iperf3 cannot bind the feed interface"

ROUTE_LINE=$(ip route get "$TARGET_IP" 2>/dev/null | head -n 1) || ROUTE_LINE=
case $ROUTE_LINE in
*" local "*)
	die "$TARGET_IP is a local address; the host is the STA. Use STA_IP=<AP-IP> for the host-as-STA (USB MT7925) feed mode."
	;;
*" dev $HOST_IF "*) ;;
*) warn "route to $TARGET_IP does not use $HOST_IF; iperf3 -B $SRC_IP may fail or use another path" ;;
esac

# ------------------------------------------------------------------- output

: >"$OUT" || die "cannot write $OUT"
printf 'timestamp\tphase\tsource\titem\tvalue\tunit\tnote\n' >>"$OUT"

emit_row meta meta schema "$SCHEMA" - "one TSV row per observed line"
emit_row meta meta label "${BENCH_LABEL:-unlabeled}" - "arm label from BENCH_LABEL"
emit_row meta meta host "$(uname -n 2>/dev/null)" - "host running the bench"
emit_row meta meta host_if "$HOST_IF" - "feed interface"
emit_row meta meta device "$DEVICE" - "AP ssh target"
emit_row meta meta sta_iface "$STA" - "device-side wireless interface"
emit_row meta meta sta_mac "$SEL_MAC" - "associated station used for the run"
emit_row meta meta sta_ip "$TARGET_IP" - "iperf3 target; source=$IP_SOURCE"
emit_row meta meta host_ip "$SRC_IP" - "iperf3 -B source address"
emit_row meta meta duration "$DURATION" s "iperf3 duration"
emit_row meta meta supply_rule SUPPLY-LIMITED - "a 1GbE feed is not a Wi-Fi limit; missing 2.5G/10G is marked SUPPLY-LIMITED"
emit_row pre supply iface "$HOST_IF" - "host feed interface"
emit_row pre supply speed "${SUPPLY_SPEED:-unknown}" Mb/s "ethtool/sysfs link rate"
emit_row pre supply classification "$SUPPLY_CLASS" - "SUPPLY-OK needs a verified 2.5G/10G wired link"
if [ "$SUPPLY_CLASS" = "SUPPLY-LIMITED" ]; then
	emit_row pre supply limit "SUPPLY-LIMITED" - "1GbE/unverified feed: do not treat the throughput as the Wi-Fi limit"
elif [ "$SUPPLY_CLASS" = "SUPPLY-WIFI" ]; then
	emit_row pre supply limit "SUPPLY-WIFI" - "feed shares the air (USB MT7925-class STA), not a 1GbE wired cap"
else
	emit_row pre supply limit "SUPPLY-OK" - "verified 2.5G/10G wired feed"
fi
if [ -n "$SUPPLY_ETHTOOL" ]; then
	emit_text pre supply "ethtool: $HOST_IF
$SUPPLY_ETHTOOL"
else
	emit_row pre supply ethtool unavailable - "ethtool unavailable or failed; speed came from sysfs"
fi
[ -n "$WIFI_LINK" ] && emit_text pre supply "iw dev $HOST_IF link
$WIFI_LINK"

emit_text pre device "$DEVICE_ID"
emit_text pre device "$STA_INFO"
emit_text pre "station dump" "$STA_DUMP"
emit_row pre "station dump" stations "$(printf '%s\n' "$STA_MACS" | wc -l | tr -d ' ')" - "associated stations on $STA"

# --------------------------------------------------- throttle/queue evidence

hw_queue_cmd() {
	# $1 phase; reads per-STA queue depth for the selected MAC and the
	# global PLE/PSE queue state.  Both files are 0400 debugfs, read-only.
	_hwq=$(dev_ssh "iface='$STA'; macs='$SEL_MAC'; for mac in \$macs; do for f in /sys/kernel/debug/ieee80211/*/*/stations/\"\$mac\"/hw-queues; do [ -r \"\$f\" ] && { echo \"### \$f\"; cat \"\$f\"; }; done; done; for f in /sys/kernel/debug/ieee80211/*/mt76/hw-queues; do [ -r \"\$f\" ] && { echo \"### \$f\"; cat \"\$f\"; }; done" 2>&1) || _hwq=
	if [ -z "$_hwq" ]; then
		emit_row "$1" "hw-queues" unavailable - - "debugfs not mounted/readable, or no mt7996 mt76/hw-queues"
	else
		emit_text "$1" "hw-queues" "$_hwq"
	fi
}

tx_stats_cmd() {
	# $1 phase; read-only A-MPDU length histogram, if the driver exposes it.
	# Single quotes are intentional: $f is expanded by the remote shell.
	# shellcheck disable=SC2016
	_tx=$(dev_ssh 'for f in /sys/kernel/debug/ieee80211/*/mt76/tx_stats; do [ -r "$f" ] && { echo "### $f"; cat "$f"; }; done' 2>&1) || _tx=
	if [ -z "$_tx" ]; then
		emit_row "$1" tx_stats unavailable - - "tx_stats not readable on this build"
		return
	fi
	emit_text "$1" tx_stats "$_tx"
	_len=$(printf '%s\n' "$_tx" | sed -n 's/^Length:[[:space:]]*//p')
	_cnt=$(printf '%s\n' "$_tx" | sed -n 's/^Count:[[:space:]]*//p')
	_miss=$(printf '%s\n' "$_tx" | sed -n 's/^BA miss count:[[:space:]]*//p')
	[ -n "$_len" ] && emit_row "$1" tx_stats ampdu_lengths "$_len" - "A-MPDU length buckets"
	[ -n "$_cnt" ] && emit_row "$1" tx_stats ampdu_counts "$_cnt" - "A-MPDU bucket counts"
	[ -n "$_miss" ] && emit_row "$1" tx_stats ba_miss "$_miss" - "BA miss count"
}

edca_cmd() {
	# $1 phase; current applied EDCA TXOP/burst values plus any debugfs node
	# a future EDCA patch (0016) exposes.  Never writes.
	_edca=$(dev_ssh "if command -v hostapd_cli >/dev/null 2>&1; then hostapd_cli -i $STA get_config 2>&1 | grep -E '^[[:space:]]*tx_queue_data[0-3]_' || echo NO_TX_QUEUE_LINES; else echo HOSTAPD_CLI_MISSING; fi" 2>&1) || _edca=
	case $_edca in
	'') emit_row "$1" "EDCA txop" unavailable - - "hostapd_cli read failed" ;;
	*HOSTAPD_CLI_MISSING*) emit_row "$1" "EDCA txop" unavailable - - "hostapd_cli not installed on the device" ;;
	*NO_TX_QUEUE_LINES*) emit_row "$1" "EDCA txop" unavailable - - "hostapd get_config has no tx_queue_data lines" ;;
	*) emit_text "$1" "EDCA txop" "$_edca" ;;
	esac

	_edca_dbg=$(dev_ssh "found=0; for f in /sys/kernel/debug/ieee80211/*/mt76/edca* /sys/kernel/debug/ieee80211/*/netdev:$STA/edca* /sys/kernel/debug/ieee80211/*/netdev:$STA/*/edca*; do [ -r \"\$f\" ] && { found=1; echo \"### \$f\"; cat \"\$f\"; }; done; [ \"\$found\" = 1 ] || echo EDCA_DEBUGFS_ABSENT" 2>&1) || _edca_dbg=
	case $_edca_dbg in
	*EDCA_DEBUGFS_ABSENT*|'')
		emit_row "$1" "EDCA txop" debugfs absent - "no edca* debugfs node (patch 0016 not present or not exposing one)" ;;
	*) emit_text "$1" "EDCA txop" "$_edca_dbg" ;;
	esac
}

hw_queue_cmd pre
tx_stats_cmd pre
edca_cmd pre

# ---------------------------------------------------------------- throughput

IPERF_LOG=$(mktemp "${TMPDIR:-/tmp}/wifi7-supply-bench.XXXXXX") ||
	die "cannot create a local iperf3 log"
trap 'if [ -n "${IPERF_LOG:-}" ]; then rm -f "$IPERF_LOG"; fi' EXIT

case ${IPERF3_EXTRA:-} in
*-R*) IPERF_DIR='STA-to-host' ;;
*) IPERF_DIR='host-to-STA' ;;
esac

if [ -n "${IPERF3_EXTRA:-}" ]; then
	# Word splitting is intentional: IPERF3_EXTRA is a whitespace-separated
	# list of arguments.  set -f is active, so it is never glob-expanded.
	# shellcheck disable=SC2086
	iperf3 -c "$TARGET_IP" -t "$DURATION" -B "$SRC_IP" -f m $IPERF3_EXTRA >"$IPERF_LOG" 2>&1
else
	iperf3 -c "$TARGET_IP" -t "$DURATION" -B "$SRC_IP" -f m >"$IPERF_LOG" 2>&1
fi
IPERF_STATUS=$?

IPERF_OUT=$(cat "$IPERF_LOG" 2>/dev/null) || IPERF_OUT=
emit_text run iperf3 "$IPERF_OUT"

IPERF_MBIT=$(awk '
	/\[SUM\].* sender$/ {
		for (i = 1; i <= NF; i++)
			if ($i == "Mbits/sec") { print $(i - 1); exit }
	}
' "$IPERF_LOG")
[ -n "$IPERF_MBIT" ] || IPERF_MBIT=$(awk '
	/ sender$/ {
		for (i = 1; i <= NF; i++)
			if ($i == "Mbits/sec") v = $(i - 1)
	}
	END { if (v != "") print v }
' "$IPERF_LOG")
IPERF_RETR=$(awk '
	/ sender$/ { v = $(NF - 1) }
	END { if (v != "") print v }
' "$IPERF_LOG")

IPERF_NOTE=$SUPPLY_CLASS
[ "$SUPPLY_CLASS" = "SUPPLY-LIMITED" ] &&
	IPERF_NOTE="SUPPLY-LIMITED: 1GbE/unverified feed; this number is not a Wi-Fi limit"

emit_row run iperf3 target "$TARGET_IP" - "source=$IP_SOURCE"
emit_row run iperf3 source "$SRC_IP" - "bound with -B on $HOST_IF"
emit_row run iperf3 direction "$IPERF_DIR" - "set IPERF3_EXTRA=-R for the reverse direction"
emit_row run iperf3 duration "$DURATION" s "requested duration"
if [ -n "$IPERF_MBIT" ]; then
	emit_row run iperf3 Mbits_per_sec "$IPERF_MBIT" Mbit/s "$IPERF_NOTE"
else
	emit_row run iperf3 Mbits_per_sec unavailable - "$IPERF_NOTE"
fi
[ -n "$IPERF_RETR" ] && emit_row run iperf3 retransmits "$IPERF_RETR" - "sender retransmits"
emit_row run iperf3 exit_status "$IPERF_STATUS" - "iperf3 client exit code"

# ----------------------------------------------------------------- snapshots

if STA_DUMP_POST=$(dev_ssh "iw dev $STA station dump 2>&1"); then
	emit_text post "station dump" "$STA_DUMP_POST"
else
	STA_DUMP_POST=
	emit_row post "station dump" error - - "post-run station dump failed"
fi
hw_queue_cmd post
tx_stats_cmd post
edca_cmd post

# ---------------------------------------------------------------------- report

printf '%s: out=%s\n' "$PROG" "$OUT"
printf '%s: feed %s: %s Mb/s (%s)\n' "$PROG" "$HOST_IF" "${SUPPLY_SPEED:-unknown}" "$SUPPLY_CLASS"
case $SUPPLY_CLASS in
SUPPLY-LIMITED)
	printf 'SUPPLY-LIMITED: the AP is fed through %s at %s Mb/s; do not treat the air number as the Wi-Fi limit (need 2.5G/10G for that).\n' \
		"$HOST_IF" "${SUPPLY_SPEED:-unknown}"
	;;
SUPPLY-WIFI)
	printf 'SUPPLY-WIFI: the feed is a Wi-Fi STA (%s), not a 1GbE wired cap; the air path is shared with the measurement.\n' "$HOST_IF"
	;;
SUPPLY-OK)
	printf 'SUPPLY-OK: %s Mb/s wired feed; the air number is valid for this feed class only.\n' "$SUPPLY_SPEED"
	;;
esac
printf '%s: STA %s (%s) -> %s\n' "$PROG" "$SEL_MAC" "$STA" "$TARGET_IP"
if [ -n "$IPERF_MBIT" ]; then
	printf '%s: iperf3 %s: %s Mbit/s over %ss\n' "$PROG" "$IPERF_DIR" "$IPERF_MBIT" "$DURATION"
else
	printf '%s: iperf3 failed (exit %s); raw output is in %s\n' "$PROG" "$IPERF_STATUS" "$OUT" >&2
	exit 1
fi

if [ "$IPERF_STATUS" -ne 0 ]; then
	printf '%s: iperf3 exited %s; partial result recorded in %s\n' "$PROG" "$IPERF_STATUS" "$OUT" >&2
	exit 1
fi

exit 0
