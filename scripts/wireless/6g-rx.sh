#!/bin/sh
#
# 6g-rx.sh - fixed-window 6G STA->AP RX harness with AP-side counters and
# a PCIe0-vs-hif2 direction verdict.
#
# Why this exists: the 6G RX path has no reproducible measurement.  A
# hand-run iperf3 leaves no record of which counters were sampled, how the
# IRQ deltas moved, or whether the 6G data plane was on PCIe0 or hif2.  This
# harness fixes that protocol:
#
#   1. select a 6G-only AP BSS and one associated 6G STA (or wait for one
#      after an optional temporary BSS bring-up, --add-bss);
#   2. snapshot iw station counters, AP ethtool -S MIB counters,
#      /proc/interrupts, mt76 token_info / band_bytes and the AP netdev RX
#      counters;
#   3. run one STA->AP UDP/TCP source for a fixed --seconds window;
#   4. snapshot again, print the deltas and one verdict:
#      PCIe0, hif2, or undetermined with the counter evidence.
#
# The AP cannot make a STA transmit by itself, so there are two source
# modes, both with the AP as the fixed window's receiver:
#
#   listen (default)  the AP runs "iperf3 -s -1" and prints the exact
#                     iperf3 client command the 6G STA must run.  This works
#                     with a phone or any STA that has an iperf3 client.
#   reverse           with --sta-ip, the AP runs "iperf3 -c <sta> -R"
#                     against an iperf3 server on the STA, so the STA is the
#                     sender.  The STA must run "iperf3 -s -p <port>".
#
# Counters read (exact names):
#   iw dev IFACE station dump : "rx bytes", "rx packets", "rx bitrate"
#   ethtool -S IFACE          : rx_ampdu_bytes_cnt, rx_ampdu_cnt,
#                               rx_mpdu_cnt, rx_ba_cnt
#   /proc/interrupts          : lines matching pcie|hif|mt7996 (configurable
#                               with --irq-pattern); the PCIe0 group is
#                               pcie*/mt7996*, the hif2 group is *hif*
#   mt76 token_info           : token_count, wed_token_count, rx_token_size,
#                               npu_rx0/npu_rx1 "queued"
#   mt76 band_bytes           : "Phy band 2" rx_ampdu_bytes
#   /sys/class/net/IFACE/statistics/rx_bytes
#
# Verdict rule: after a successful source, if the PCIe0 IRQ delta is larger
# than the hif2 IRQ delta the data plane is PCIe0; if hif2 is larger it is
# hif2; if neither moved, or the station RX bytes did not grow, the verdict
# is undetermined and the evidence is printed anyway.
#
# No module/firmware change.  A normal run changes no configuration.  The
# optional --add-bss path writes a temporary wifi-iface, backs up
# /etc/config/wireless first, and always restores the backup from an EXIT /
# INT / TERM / HUP trap.  --add-bss needs root and briefly reloads Wi-Fi.
#
# POSIX sh only (busybox ash on the device).
#
# Test/offline overrides (not needed in normal use):
#   WIRELESS_CONFIG  path to the wireless UCI file   (default /etc/config/wireless)
#   PROC_INTERRUPTS  path to an interrupts snapshot  (default /proc/interrupts)
#   DEBUGFS          debugfs mount point             (default /sys/kernel/debug)
#
# Exit status: 0 measurement ran or the run was a clean SKIP; 1 the source
# or measurement failed, or the config restore failed; 2 invalid arguments
# or an impossible setup.

set -u
umask 077
LC_ALL=C
export LC_ALL

PROG=${0##*/}

# --- defaults ---------------------------------------------------------

IFACE=
SSID=
STA_MAC=
AP_IP=
STA_IP=
PROTO=tcp
WINDOW=10
PARALLEL=4
PORT=5201
UDP_RATE=4G
SOURCE_WAIT=120
BSS_WAIT=30
STA_WAIT=
STA_WAIT_SET=0
ADD_BSS=0
RADIO=
OUT=
ETHTOOL_IFACE=
IRQ_PATTERN=${IRQ_PATTERN:-pcie|hif|mt7996}
DRY_RUN=0

WIRELESS_CONFIG=${WIRELESS_CONFIG:-/etc/config/wireless}
PROC_INTERRUPTS=${PROC_INTERRUPTS:-/proc/interrupts}
DEBUGFS=${DEBUGFS:-/sys/kernel/debug}

# Runtime state.
RAW_LOG=
OUT_CREATED=0
TRAP_SET=0
TMP_TABLE=
BSS_TABLE=
SEL_IFACE=
SEL_PHY=
SEL_FREQ=
SEL_SSID=
CANDIDATES=
CANDIDATE_COUNT=0
BSS_CHANGED=0
TEMP_SSID=
WIRELESS_BACKUP=
ORIG_DIGEST=
DIGEST_ALGO=
SRC_PID=
TOKEN_INFO_PATH=
BAND_BYTES_PATH=
SIXG_BAND=2

# Result values.
RX_BYTES_BEFORE=
RX_BYTES_AFTER=
RX_BYTES_DELTA=
RX_PACKETS_BEFORE=
RX_PACKETS_AFTER=
RX_PACKETS_DELTA=
TX_BYTES_BEFORE=
TX_BYTES_AFTER=
TX_BYTES_DELTA=
RX_BITRATE=
TX_BITRATE=
STA_SIGNAL=
STA_CONNECTED=
AP_RX_BYTES_BEFORE=
AP_RX_BYTES_AFTER=
AP_RX_BYTES_DELTA=
AMPDU_BYTES_BEFORE=
AMPDU_BYTES_AFTER=
AMPDU_BYTES_DELTA=
AMPDU_CNT_BEFORE=
AMPDU_CNT_AFTER=
AMPDU_CNT_DELTA=
MPDU_CNT_BEFORE=
MPDU_CNT_AFTER=
MPDU_CNT_DELTA=
BA_CNT_BEFORE=
BA_CNT_AFTER=
BA_CNT_DELTA=
BAND_AMPDU_BEFORE=
BAND_AMPDU_AFTER=
BAND_AMPDU_DELTA=
IRQ_PCIE0_DELTA=0
IRQ_HIF2_DELTA=0
IRQ_LINE_COUNT=0
TOKEN_BEFORE=
TOKEN_AFTER=
WED_TOKEN_BEFORE=
WED_TOKEN_AFTER=
RX_TOKEN_SIZE_BEFORE=
RX_TOKEN_SIZE_AFTER=
NPU0_QUEUED_BEFORE=
NPU0_QUEUED_AFTER=
NPU1_QUEUED_BEFORE=
NPU1_QUEUED_AFTER=
IPERF_RX_BPS=
IPERF_RX_BYTES=
IPERF_SECONDS=
IPERF_RETRANSMITS=
IPERF_LOST=
IPERF_LOST_PCT=
IPERF_JITTER=
COUNTER_SECONDS=
RX_MBIT_S=
RATE_SECONDS=
VERDICT=
VERDICT_REASON=
SOURCE_STATUS=0

# --- small helpers ----------------------------------------------------

usage_error() {
	cleanup_tmp
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf 'Try "%s --help" for usage.\n' "$PROG" >&2
	exit 2
}

die() {
	cleanup_tmp
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	exit 1
}

warn() {
	printf '%s: warning: %s\n' "$PROG" "$1" >&2
}

skip() {
	cleanup_tmp
	printf 'SKIP: %s\n' "$*"
	exit 0
}

cleanup_tmp() {
	if [ -n "${TMP_TABLE:-}" ]; then
		rm -f "$TMP_TABLE" "$TMP_TABLE.resolved" "$TMP_TABLE.candidates" 2>/dev/null
	fi
}

need_value() {
	[ "$2" -ge 2 ] || usage_error "$1 requires a value"
}

is_uint() {
	case ${1:-} in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

check_uint() {
	# $1 name, $2 value, $3 min, $4 max
	is_uint "$2" || usage_error "$1 must be an unsigned integer, got '$2'"
	[ "$2" -ge "$3" ] && [ "$2" -le "$4" ] ||
		usage_error "$1 must be between $3 and $4, got '$2'"
}

now_s() {
	awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null
}

set_digest_algo() {
	# Choose the digest command once, in the parent shell.  Calling
	# file_digest in a command substitution must not be the only place
	# that sets this, or the parent would fall back to cmp.
	if command -v md5sum >/dev/null 2>&1; then
		DIGEST_ALGO=md5
	elif command -v sha256sum >/dev/null 2>&1; then
		DIGEST_ALGO=sha256
	elif command -v cksum >/dev/null 2>&1; then
		DIGEST_ALGO='cksum'
	else
		DIGEST_ALGO='cmp'
	fi
}

file_digest() {
	# Prints the digest selected by set_digest_algo.
	case $DIGEST_ALGO in
	md5) md5sum "$1" 2>/dev/null | awk '{ print $1 }' ;;
	sha256) sha256sum "$1" 2>/dev/null | awk '{ print $1 }' ;;
	cksum) cksum "$1" 2>/dev/null | awk '{ print $1 ":" $2 }' ;;
	*) printf '' ;;
	esac
}

# shellcheck disable=SC2329  # called only from cleanup
digest_matches() {
	# $1 file, $2 expected digest (cmp compares against the backup file)
	case $DIGEST_ALGO in
	md5|sha256|cksum)
		[ "$(file_digest "$1")" = "$2" ]
		;;
	*)
		cmp -s "$1" "${WIRELESS_BACKUP:-$2}" 2>/dev/null
		;;
	esac
}

log_line() {
	if [ -n "$RAW_LOG" ]; then
		printf '%s\n' "$*" >>"$RAW_LOG"
	fi
}

log_cmd() {
	log_line "+ $*"
}

capture() {
	# $1 destination, rest the command.  Optional commands never abort the
	# harness; a failed capture records the failure next to the data.
	_capture_dest=$1
	shift
	log_cmd "$* > $_capture_dest"
	if "$@" >"$_capture_dest" 2>"$_capture_dest.err"; then
		rm -f "$_capture_dest.err"
	else
		printf 'capture failed: %s\n' "$*" >>"$_capture_dest"
		if [ -s "$_capture_dest.err" ]; then
			cat "$_capture_dest.err" >>"$_capture_dest"
		fi
		rm -f "$_capture_dest.err"
	fi
}

write_note() {
	# $1 destination, $2 text
	printf '%s\n' "$2" >"$1"
}

val_or_na() {
	if [ -n "${1:-}" ]; then
		printf '%s' "$1"
	else
		printf 'n/a'
	fi
}

counter_delta() {
	# $1 before, $2 after.  Empty when either side is not an integer.
	case ${1:-} in ''|*[!0-9]*) return 0 ;; esac
	case ${2:-} in ''|*[!0-9]*) return 0 ;; esac
	awk -v a="$1" -v b="$2" 'BEGIN { printf "%d", b - a }'
}

is_positive() {
	case ${1:-} in
	''|*[!0-9]*) return 1 ;;
	*) [ "$1" -gt 0 ] ;;
	esac
}

# --- usage ------------------------------------------------------------

usage() {
	cat <<'EOF'
Usage: 6g-rx.sh [options]

Fixed-window 6G STA->AP RX harness.  It selects a 6G-only BSS and one
associated 6G STA, runs exactly one STA->AP iperf3 source for --seconds,
and prints AP-side counter deltas plus a PCIe0-vs-hif2 verdict.

Source modes:
  listen (default)
        The AP runs "iperf3 -s -1 -p PORT" and prints the exact client
        command for the STA.  Use this with any STA that has an iperf3
        client.  The AP waits up to --source-wait for a connection; no
        connection is a clean "SKIP: no STA source connected".
  --sta-ip IP
        Reverse mode.  The AP runs "iperf3 -c IP -R", so an iperf3 server
        on the STA is the sender.  Start it first with
        "iperf3 -s -p PORT" on the STA.

Options:
  --iface NAME        AP interface on the 6G BSS.  Default: autodetect a
                      6G-only AP BSS that has a station.
  --ssid SSID         require this SSID (helps choose between 6G BSSes,
                      and names the temporary BSS with --add-bss)
  --sta MAC           station MAC.  Default: the only station on the BSS.
  --ap-ip IP          AP address printed for the listen-mode client.
                      Default: the first IPv4 on br-lan, or on the AP
                      interface's master bridge.
  --sta-ip IP         select reverse mode (STA is the iperf3 server)
  --proto tcp|udp     iperf3 protocol (default tcp)
  --seconds N         fixed source window in seconds (default 10)
  --parallel N        iperf3 streams (default 4)
  --port N            iperf3 port (default 5201)
  --udp-rate RATE     UDP sender rate, iperf3 -b syntax (default 4G)
  --source-wait N     listen mode: seconds to wait for the STA client
                      after printing its command (default 120)
  --add-bss           if no 6G-only BSS exists, create a temporary one on
                      the first wifi-device with "band '6g'", wait for it,
                      and remove it on exit.  Requires root; it backs up
                      /etc/config/wireless and reloads Wi-Fi.  When a
                      6G-only BSS already exists, no config is written.
                      The temporary BSS uses OWE + PMF, so the STA must
                      support OWE/WPA3 (or use an existing BSS instead).
  --radio NAME        wifi-device for --add-bss (default: autodetect the
                      first "band '6g'" wifi-device)
  --bss-wait N        --add-bss: seconds to wait for the new BSS (default 30)
  --sta-wait N        seconds to wait for a 6G STA to associate.  Default 0
                      without --add-bss and 60 with --add-bss.
  --ethtool-iface NAME
                      interface for ethtool -S (default: the AP iface; if
                      the counter is not exposed there, another AP iface on
                      the same phy is tried)
  --irq-pattern REGEX /proc/interrupts line filter (default "pcie|hif|mt7996")
  --out DIR           result directory (default ./6g-rx-<epoch>).  Must not
                      exist; raw snapshots and raw.log are kept there.
  --dry-run           print the planned commands, snapshot paths and
                      counter names; do not touch the device, run iperf3,
                      write config or create files.  Exits 0.
  -h, --help          this text

Measurements:
  station dump    rx bytes, rx packets, tx bytes, rx bitrate, tx bitrate,
                  signal, connected time
  ethtool -S      rx_ampdu_bytes_cnt (the A-MPDU byte counter),
                  rx_ampdu_cnt, rx_mpdu_cnt, rx_ba_cnt
  interrupts      deltas of every /proc/interrupts line matching
                  --irq-pattern; the strict pcie*/mt7996* lines form the
                  PCIe0 group and the *hif* lines form the hif2 group
  token_info      token_count, wed_token_count, rx_token_size and the
                  npu_rx0/npu_rx1 queued depths (NPU/RRO queue evidence)
  band_bytes      rx_ampdu_bytes for Phy band 2 (6 GHz)
  netdev          /sys/class/net/<AP iface>/statistics/rx_bytes

Verdict:
  PCIe0         PCIe0 IRQ delta > hif2 IRQ delta and station rx bytes grew
  hif2          hif2 IRQ delta > PCIe0 IRQ delta and station rx bytes grew
  undetermined  neither IRQ group moved, the two deltas are equal, or the
                station rx bytes did not grow; the evidence is still printed

The station counters are per STA; ethtool's A-MPDU counters and the IRQ
deltas are per phy, so other traffic on the same 6G phy is included.
Keep the 6G BSS quiet during the window for a clean attribution.  Hidden
6G SSIDs are not supported: the 6G-only check needs the SSID.

A normal run changes no configuration and loads no module.  --add-bss is
the only write path; its trap restores /etc/config/wireless from a backup
and reloads Wi-Fi on success, error, INT, TERM and HUP.  SIGKILL cannot be
trapped; the restore command is printed before the BSS is created.

Root is recommended for debugfs token_info and required for --add-bss.
The AP's LAN firewall must allow the iperf3 port from the STA.

Examples:
  ./scripts/wireless/6g-rx.sh --dry-run
  ./scripts/wireless/6g-rx.sh --seconds 30 --proto udp --out /tmp/6g-rx-1
  ./scripts/wireless/6g-rx.sh --add-bss --seconds 30
  ./scripts/wireless/6g-rx.sh --sta-ip 192.168.1.23 --seconds 20

Exit status: 0 ran or clean SKIP, 1 source/measurement or restore failure,
2 invalid arguments or impossible setup.
EOF
}

# --- argument parsing -------------------------------------------------

while [ "$#" -gt 0 ]; do
	case $1 in
	-h|--help)
		usage
		exit 0
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--add-bss)
		ADD_BSS=1
		shift
		;;
	--iface)
		need_value "$1" "$#"
		IFACE=$2
		shift 2
		;;
	--iface=*)
		IFACE=${1#*=}
		shift
		;;
	--ssid)
		need_value "$1" "$#"
		SSID=$2
		shift 2
		;;
	--ssid=*)
		SSID=${1#*=}
		shift
		;;
	--sta)
		need_value "$1" "$#"
		STA_MAC=$2
		shift 2
		;;
	--sta=*)
		STA_MAC=${1#*=}
		shift
		;;
	--ap-ip)
		need_value "$1" "$#"
		AP_IP=$2
		shift 2
		;;
	--ap-ip=*)
		AP_IP=${1#*=}
		shift
		;;
	--sta-ip)
		need_value "$1" "$#"
		STA_IP=$2
		shift 2
		;;
	--sta-ip=*)
		STA_IP=${1#*=}
		shift
		;;
	--proto)
		need_value "$1" "$#"
		PROTO=$2
		shift 2
		;;
	--proto=*)
		PROTO=${1#*=}
		shift
		;;
	--seconds)
		need_value "$1" "$#"
		WINDOW=$2
		shift 2
		;;
	--seconds=*)
		WINDOW=${1#*=}
		shift
		;;
	--parallel)
		need_value "$1" "$#"
		PARALLEL=$2
		shift 2
		;;
	--parallel=*)
		PARALLEL=${1#*=}
		shift
		;;
	--port)
		need_value "$1" "$#"
		PORT=$2
		shift 2
		;;
	--port=*)
		PORT=${1#*=}
		shift
		;;
	--udp-rate)
		need_value "$1" "$#"
		UDP_RATE=$2
		shift 2
		;;
	--udp-rate=*)
		UDP_RATE=${1#*=}
		shift
		;;
	--source-wait)
		need_value "$1" "$#"
		SOURCE_WAIT=$2
		shift 2
		;;
	--source-wait=*)
		SOURCE_WAIT=${1#*=}
		shift
		;;
	--bss-wait)
		need_value "$1" "$#"
		BSS_WAIT=$2
		shift 2
		;;
	--bss-wait=*)
		BSS_WAIT=${1#*=}
		shift
		;;
	--sta-wait)
		need_value "$1" "$#"
		STA_WAIT=$2
		STA_WAIT_SET=1
		shift 2
		;;
	--sta-wait=*)
		STA_WAIT=${1#*=}
		STA_WAIT_SET=1
		shift
		;;
	--radio)
		need_value "$1" "$#"
		RADIO=$2
		shift 2
		;;
	--radio=*)
		RADIO=${1#*=}
		shift
		;;
	--ethtool-iface)
		need_value "$1" "$#"
		ETHTOOL_IFACE=$2
		shift 2
		;;
	--ethtool-iface=*)
		ETHTOOL_IFACE=${1#*=}
		shift
		;;
	--irq-pattern)
		need_value "$1" "$#"
		IRQ_PATTERN=$2
		shift 2
		;;
	--irq-pattern=*)
		IRQ_PATTERN=${1#*=}
		shift
		;;
	--out)
		need_value "$1" "$#"
		OUT=$2
		shift 2
		;;
	--out=*)
		OUT=${1#*=}
		shift
		;;
	-*)
		usage_error "unknown option: $1"
		;;
	*)
		usage_error "unexpected argument: $1"
		;;
	esac
done

check_uint WINDOW "$WINDOW" 1 3600
check_uint PARALLEL "$PARALLEL" 1 64
check_uint PORT "$PORT" 1 65535
check_uint SOURCE_WAIT "$SOURCE_WAIT" 0 7200
check_uint BSS_WAIT "$BSS_WAIT" 1 600

if [ "$STA_WAIT_SET" = 0 ]; then
	if [ "$ADD_BSS" = 1 ]; then
		STA_WAIT=60
	else
		STA_WAIT=0
	fi
fi
check_uint STA_WAIT "$STA_WAIT" 0 3600

case $PROTO in
tcp|udp) ;;
*) usage_error "PROTO must be tcp or udp, got '$PROTO'" ;;
esac

case $UDP_RATE in
''|*[!0-9kKmMgG]*) usage_error "invalid UDP rate '$UDP_RATE' (iperf3 -b syntax, e.g. 4G)" ;;
esac
is_uint "${UDP_RATE%[kKmMgG]}" && [ "${UDP_RATE%[kKmMgG]}" -gt 0 ] ||
	usage_error "invalid UDP rate '$UDP_RATE'"

if [ -n "$STA_MAC" ]; then
	printf '%s\n' "$STA_MAC" |
		grep -Eiq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' ||
		usage_error "invalid STA MAC '$STA_MAC'"
	STA_MAC=$(printf '%s' "$STA_MAC" | tr 'A-F' 'a-f')
fi

if [ -n "$AP_IP" ]; then
	case $AP_IP in
	*[!0-9a-fA-F:.]*) usage_error "invalid AP IP '$AP_IP'" ;;
	esac
fi
if [ -n "$STA_IP" ]; then
	case $STA_IP in
	*[!0-9a-fA-F:.]*) usage_error "invalid STA IP '$STA_IP'" ;;
	esac
fi

if [ -n "$SSID" ]; then
	[ "${#SSID}" -ge 1 ] && [ "${#SSID}" -le 32 ] ||
		usage_error "SSID must be 1..32 bytes"
	case $SSID in
	*'
'*) usage_error "SSID must not contain a newline" ;;
	esac
fi

if [ -n "$RADIO" ]; then
	case $RADIO in
	*[!A-Za-z0-9_]*) usage_error "invalid radio section name '$RADIO'" ;;
	esac
	[ "$ADD_BSS" = 1 ] || usage_error "--radio only applies to --add-bss"
fi

if [ -n "$ETHTOOL_IFACE" ]; then
	case $ETHTOOL_IFACE in
	*[!A-Za-z0-9_.:-]*) usage_error "invalid --ethtool-iface '$ETHTOOL_IFACE'" ;;
	esac
fi

[ -n "$IRQ_PATTERN" ] || usage_error "--irq-pattern must not be empty"

if [ -z "$OUT" ]; then
	OUT=./6g-rx-$(date +%s)
fi

# --- dry run ----------------------------------------------------------

dry_run_plan() {
	printf '%s: dry run; nothing will be written, reloaded or sent\n' "$PROG"
	if [ -n "$STA_IP" ]; then
		printf '  source mode: reverse (AP runs iperf3 -c %s -R)\n' "$STA_IP"
	else
		printf '  source mode: listen (AP runs iperf3 -s; STA runs the printed client command)\n'
	fi
	printf '  iface: %s\n' "${IFACE:-<autodetect a 6G-only AP BSS with a station>}"
	printf '  ssid: %s\n' "${SSID:-<any 6G-only SSID>}"
	printf '  sta: %s\n' "${STA_MAC:-<the only station on the selected BSS>}"
	printf '  proto=%s seconds=%s parallel=%s port=%s udp_rate=%s\n' \
		"$PROTO" "$WINDOW" "$PARALLEL" "$PORT" "$UDP_RATE"
	printf '  irq_pattern=%s ethtool_iface=%s\n' \
		"$IRQ_PATTERN" "${ETHTOOL_IFACE:-<the AP iface>}"
	printf '  out=%s\n' "$OUT"
	printf '  restore path: WIRELESS_CONFIG=%s PROC_INTERRUPTS=%s DEBUGFS=%s\n' \
		"$WIRELESS_CONFIG" "$PROC_INTERRUPTS" "$DEBUGFS"

	if [ "$ADD_BSS" = 1 ]; then
		printf '\nBSS bring-up (only if no 6G-only BSS exists):\n'
		printf '  radio: %s\n' "${RADIO:-<autodetect the first wifi-device with band 6g>}"
		printf '  cp -p %s %s/wireless.backup\n' "$WIRELESS_CONFIG" "$OUT"
		printf '  uci set wireless.<temporary>=wifi-iface\n'
		printf '  uci set wireless.<temporary>.device=%s\n' "${RADIO:-<radio>}"
		printf '  uci set wireless.<temporary>.mode=ap\n'
		printf '  uci set wireless.<temporary>.ssid=%s\n' "${SSID:-6g-rx-<pid>}"
		printf '  uci set wireless.<temporary>.network=lan\n'
		printf '  uci set wireless.<temporary>.encryption=owe\n'
		printf '  uci set wireless.<temporary>.ieee80211w=2\n'
		printf '  uci commit wireless; wifi reload\n'
		printf '  wait %ss for the BSS; trap restores the backup and reloads Wi-Fi\n' "$BSS_WAIT"
	else
		printf '\nBSS bring-up: disabled (an existing 6G-only BSS is required)\n'
	fi

	printf '\nsnapshot files (before, mid, after):\n'
	printf '  %s/station-{before,mid,after}.txt   iw dev IFACE station dump\n' "$OUT"
	printf '  %s/ethtool-{before,after}.txt        ethtool -S ETHTOOL_IFACE\n' "$OUT"
	printf '  %s/interrupts-{before,after}.txt     cat %s\n' "$OUT" "$PROC_INTERRUPTS"
	printf '  %s/token-info-{before,after}.txt     cat DEBUGFS/ieee80211/phy*/mt76/token_info\n' "$OUT"
	printf '  %s/band-bytes-{before,after}.txt     cat DEBUGFS/ieee80211/phy*/mt76/band_bytes\n' "$OUT"
	printf '  %s/ap-rx-{before,after}.txt          /sys/class/net/IFACE/statistics/rx_bytes\n' "$OUT"
	printf '  %s/uptime-{before,after}.txt         /proc/uptime\n' "$OUT"

	printf '\nsource window commands:\n'
	if [ -n "$STA_IP" ]; then
		if [ "$PROTO" = udp ]; then
			printf '  iperf3 -c %s -R -u -b %s -t %s -p %s -P %s -J > %s/iperf.json\n' \
				"$STA_IP" "$UDP_RATE" "$WINDOW" "$PORT" "$PARALLEL" "$OUT"
		else
			printf '  iperf3 -c %s -R -t %s -p %s -P %s -J > %s/iperf.json\n' \
				"$STA_IP" "$WINDOW" "$PORT" "$PARALLEL" "$OUT"
		fi
		printf '  prerequisite on the STA: iperf3 -s -p %s\n' "$PORT"
	else
		printf '  iperf3 -s -1 -p %s -J > %s/iperf.json &\n' "$PORT" "$OUT"
		printf '  print and wait up to %ss for the STA to run:\n' "$SOURCE_WAIT"
		if [ "$PROTO" = udp ]; then
			printf '    iperf3 -c %s -u -b %s -t %s -p %s -P %s\n' \
				"${AP_IP:-<ap-ip>}" "$UDP_RATE" "$WINDOW" "$PORT" "$PARALLEL"
		else
			printf '    iperf3 -c %s -t %s -p %s -P %s\n' \
				"${AP_IP:-<ap-ip>}" "$WINDOW" "$PORT" "$PARALLEL"
		fi
	fi

	printf '\ncounters used:\n'
	printf '  station: rx bytes, rx packets, tx bytes, rx bitrate, tx bitrate, signal\n'
	printf '  ethtool: rx_ampdu_bytes_cnt, rx_ampdu_cnt, rx_mpdu_cnt, rx_ba_cnt\n'
	printf '  interrupts: PCIe0 group pcie|mt7996, hif2 group hif\n'
	printf '  token_info: token_count, wed_token_count, rx_token_size, npu_rx0/npu_rx1 queued\n'
	printf '  band_bytes: Phy band %s rx_ampdu_bytes\n' "$SIXG_BAND"
	printf '  netdev: rx_bytes\n'

	printf '\nverdict: PCIe0 if the PCIe0 IRQ delta > hif2 IRQ delta; hif2 if the\n'
	printf '         reverse holds; otherwise undetermined with the evidence.\n'
	printf '\nreal-run preconditions not checked by --dry-run: iw, ethtool, iperf3;\n'
	printf 'a 6G-only BSS; a 6G STA; a source endpoint; the AP LAN firewall allows\n'
	printf 'port %s.\n' "$PORT"
}

if [ "$DRY_RUN" = 1 ]; then
	dry_run_plan
	exit 0
fi

# --- real-run setup ---------------------------------------------------

for _cmd in iw ethtool iperf3 awk cat sed grep sleep mkdir cp rm mv cut head tr ip date; do
	command -v "$_cmd" >/dev/null 2>&1 ||
		die "required command not found: $_cmd"
done

if [ "$ADD_BSS" = 1 ]; then
	command -v uci >/dev/null 2>&1 || die "--add-bss requires uci"
	command -v wifi >/dev/null 2>&1 || die "--add-bss requires the wifi command"
	command -v id >/dev/null 2>&1 || die "--add-bss requires id"
	command -v cmp >/dev/null 2>&1 || die "--add-bss requires cmp (or md5sum/sha256sum)"
	[ "$(id -u 2>/dev/null)" = 0 ] || die "--add-bss requires root (uci and wifi reload)"
	[ -f "$WIRELESS_CONFIG" ] || die "$WIRELESS_CONFIG not found"
fi

# A temp file keeps the iw table free of here-doc/backslash surprises.  It
# is created only for parsing and removed by cleanup.
TMP_TABLE=${TMPDIR:-/tmp}/6g-rx.$$.table
: >"$TMP_TABLE" 2>/dev/null || die "cannot create temporary file $TMP_TABLE"

# --- BSS and station discovery ----------------------------------------

bss_table() {
	# Writes "iface<TAB>phy<TAB>freq<TAB>ssid" for every AP interface into
	# TMP_TABLE and prints the table.  An unknown channel is queried with
	# "iw dev IFACE info".
	_iw_out=$(iw dev 2>/dev/null) || _iw_out=
	: >"$TMP_TABLE"
	printf '%s\n' "$_iw_out" | awk '
		function flush() {
			if (iface != "" && type == "AP" && ssid != "")
				printf "%s\t%s\t%s\t%s\n", iface, phy, freq, ssid
			iface = ""; ssid = ""; type = ""; freq = ""
		}
		/^phy#/ { flush(); phy = substr($0, 5); next }
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line ~ /^Interface /) {
				flush()
				iface = substr(line, 11)
				next
			}
			if (line ~ /^ssid /) { ssid = substr(line, 6); next }
			if (line ~ /^type /) { type = substr(line, 6); next }
			if (line ~ /^channel /) {
				n = split(line, a, /[ ()]+/)
				freq = a[3]
				next
			}
		}
		END { flush() }
	' >"$TMP_TABLE"

	# Resolve interfaces whose "iw dev" record had no channel line.
	: >"$TMP_TABLE.resolved"
	while IFS="$(printf '\t')" read -r _if _phy _freq _ssid; do
		[ -n "$_if" ] || continue
		if ! is_uint "$_freq" || [ "$_freq" -eq 0 ]; then
			_freq=$(iw dev "$_if" info 2>/dev/null |
				awk '/^[ \t]*channel / { n = split($0, a, /[ ()]+/); print a[3]; exit }')
			is_uint "$_freq" || _freq=0
		fi
		printf '%s\t%s\t%s\t%s\n' "$_if" "$_phy" "$_freq" "$_ssid" \
			>>"$TMP_TABLE.resolved"
	done <"$TMP_TABLE"
	mv "$TMP_TABLE.resolved" "$TMP_TABLE" 2>/dev/null || true
	BSS_TABLE=$(cat "$TMP_TABLE" 2>/dev/null)
	printf '%s\n' "$BSS_TABLE"
}

is_sixg_freq() {
	is_uint "${1:-}" && [ "$1" -ge 5955 ] && [ "$1" -le 7125 ]
}

off6g_ssids() {
	# SSIDs also (or possibly) used on a non-6G band.  An unresolved
	# channel is treated as non-6G, so the harness never calls a BSS
	# 6G-only when it cannot prove the other copies are absent.
	awk -F"$(printf '\t')" '
		$4 != "" && (!($3 + 0) || $3 + 0 < 5955 || $3 + 0 > 7125) { print $4 }
	' "$TMP_TABLE" 2>/dev/null | awk '!seen[$0]++'
}

ssid_is_off6g() {
	# $1 SSID
	[ -n "$1" ] || return 1
	off6g_ssids | grep -Fxq -e "$1"
}

find_bss_by_ssid() {
	# Prints the first 6G AP record with SSID $1, or nothing.
	[ -n "$1" ] || return 1
	awk -F"$(printf '\t')" -v want="$1" '
		$4 == want && ($3 + 0) >= 5955 && ($3 + 0) <= 7125 {
			printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4
			exit
		}
	' "$TMP_TABLE" 2>/dev/null | head -n 1
}

station_macs() {
	# $1 AP interface.  Prints one MAC per line.
	iw dev "$1" station dump 2>/dev/null | awk '/^Station / { print $2 }'
}

station_count() {
	station_macs "$1" | awk 'NF { n++ } END { print n + 0 }'
}

has_station() {
	# $1 AP interface, $2 MAC
	[ -n "${2:-}" ] || return 1
	station_macs "$1" |
		awk -v want="$2" 'tolower($0) == tolower(want) { found = 1 } END { exit !found }'
}

select_bss() {
	# Fills SEL_IFACE/SEL_PHY/SEL_FREQ/SEL_SSID and CANDIDATE_COUNT.
	# Returns 0 when a candidate was selected, 1 when there is no
	# candidate, 2 when --sta was given but is not on any candidate.
	bss_table >/dev/null 2>&1
	_off=$(off6g_ssids)
	CANDIDATES=
	CANDIDATE_COUNT=0

	while IFS="$(printf '\t')" read -r _if _phy _freq _ssid; do
		[ -n "$_if" ] || continue
		is_sixg_freq "$_freq" || continue
		[ -n "$_ssid" ] || continue
		if [ -n "$IFACE" ] && [ "$_if" != "$IFACE" ]; then
			continue
		fi
		if [ -n "$SSID" ] && [ "$_ssid" != "$SSID" ]; then
			continue
		fi
		if [ -n "$_off" ] && printf '%s\n' "$_off" | grep -Fxq -e "$_ssid"; then
			continue
		fi
		CANDIDATES="${CANDIDATES}${_if}	${_phy}	${_freq}	${_ssid}
"
		CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
	done <"$TMP_TABLE"

	if [ "$CANDIDATE_COUNT" -eq 0 ]; then
		if [ -n "$IFACE" ]; then
			_rec=$(awk -F"$(printf '\t')" -v want="$IFACE" '
				$1 == want { printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4; exit }
			' "$TMP_TABLE")
			[ -n "$_rec" ] || usage_error "interface $IFACE not found in iw dev"
			_rfreq=$(printf '%s' "$_rec" | cut -f3)
			_rssid=$(printf '%s' "$_rec" | cut -f4)
			is_sixg_freq "$_rfreq" ||
				usage_error "interface $IFACE is not on a 6 GHz channel ($_rfreq MHz)"
			if [ -n "$SSID" ] && [ "$_rssid" != "$SSID" ]; then
				usage_error "interface $IFACE has SSID '$_rssid', not '$SSID'"
			fi
			if ssid_is_off6g "$_rssid"; then
				usage_error "SSID '$_rssid' is also used outside 6 GHz; not a 6G-only BSS"
			fi
			usage_error "interface $IFACE is not a usable 6G-only AP BSS"
		fi
		return 1
	fi

	# With --sta, keep only candidates that carry that station.  Without
	# --sta, prefer candidates that already have a station.
	printf '%s' "$CANDIDATES" >"$TMP_TABLE.candidates"
	_first=
	_first_sta=
	_sta_candidates=0
	_ifs_pool=
	while IFS="$(printf '\t')" read -r _if _phy _freq _ssid; do
		[ -n "$_if" ] || continue
		[ -n "$_first" ] || _first="$_if	$_phy	$_freq	$_ssid"
		if [ -n "$STA_MAC" ]; then
			if has_station "$_if" "$STA_MAC"; then
				_sta_candidates=$((_sta_candidates + 1))
				_ifs_pool="${_ifs_pool}${_if}	${_phy}	${_freq}	${_ssid}
"
				_first_sta="$_if	$_phy	$_freq	$_ssid"
			fi
		else
			if [ "$(station_count "$_if")" -gt 0 ]; then
				_sta_candidates=$((_sta_candidates + 1))
				_ifs_pool="${_ifs_pool}${_if}	${_phy}	${_freq}	${_ssid}
"
				_first_sta="$_if	$_phy	$_freq	$_ssid"
			fi
		fi
	done <"$TMP_TABLE.candidates"
	rm -f "$TMP_TABLE.candidates"

	if [ -n "$IFACE" ]; then
		_sel="${_first}"
	elif [ -n "$STA_MAC" ]; then
		if [ "$_sta_candidates" -eq 0 ]; then
			SEL_IFACE=$(printf '%s' "$_first" | cut -f1)
			SEL_PHY=$(printf '%s' "$_first" | cut -f2)
			SEL_FREQ=$(printf '%s' "$_first" | cut -f3)
			SEL_SSID=$(printf '%s' "$_first" | cut -f4)
			return 2
		fi
		if [ "$_sta_candidates" -gt 1 ]; then
			usage_error "--sta $STA_MAC is on more than one 6G BSS; pass --iface"
		fi
		_sel=$_first_sta
	else
		case $_sta_candidates in
		0) _sel=$_first ;;
		1) _sel=$_first_sta ;;
		*)
			printf '%s: 6G-only BSSes with a station:\n' "$PROG" >&2
			printf '%s' "$_ifs_pool" >&2
			usage_error "more than one 6G BSS has a station; pass --iface"
			;;
		esac
	fi

	SEL_IFACE=$(printf '%s' "$_sel" | cut -f1)
	SEL_PHY=$(printf '%s' "$_sel" | cut -f2)
	SEL_FREQ=$(printf '%s' "$_sel" | cut -f3)
	SEL_SSID=$(printf '%s' "$_sel" | cut -f4)
	[ -n "$SEL_IFACE" ] || return 1
	return 0
}

choose_station() {
	# Sets STA_MAC for SEL_IFACE.
	_stas=$(station_macs "$SEL_IFACE")
	if [ -n "$STA_MAC" ]; then
		if has_station "$SEL_IFACE" "$STA_MAC"; then
			return 0
		fi
		return 1
	fi
	_n=$(printf '%s\n' "$_stas" | awk 'NF { n++ } END { print n + 0 }')
	case $_n in
	0) return 1 ;;
	1)
		STA_MAC=$(printf '%s\n' "$_stas" | awk 'NF { print tolower($0); exit }')
		return 0
		;;
	*)
		printf '%s: stations on %s:\n' "$PROG" "$SEL_IFACE" >&2
		printf '%s\n' "$_stas" >&2
		usage_error "more than one 6G STA is associated; pass --sta MAC"
		;;
	esac
}

wait_for_station() {
	# $1 seconds; returns 0 when choose_station succeeds.
	[ "$1" -gt 0 ] || return 1
	printf 'waiting up to %ss for a 6G STA on %s (SSID "%s")\n' \
		"$1" "$SEL_IFACE" "$SEL_SSID"
	_deadline=$(( $(now_s) + $1 ))
	while [ "$(now_s)" -lt "$_deadline" ]; do
		if choose_station 2>/dev/null; then
			return 0
		fi
		sleep 2
	done
	return 1
}

# --- optional temporary BSS -------------------------------------------

detect_6g_radio() {
	_radios=$(uci show wireless 2>/dev/null |
		awk -F'[.=]' '$1 == "wireless" && $3 == "wifi-device" { print $2 }')
	for _r in $_radios; do
		_band=$(uci -q get "wireless.$_r.band" 2>/dev/null) || _band=
		if [ "$_band" = 6g ]; then
			RADIO=$_r
			break
		fi
	done
	[ -n "$RADIO" ] ||
		die "no wifi-device with band '6g'; configure one or pass --radio"
}

check_radio() {
	_type=$(uci -q get "wireless.$RADIO" 2>/dev/null) || _type=
	[ "$_type" = wifi-device ] ||
		die "wireless.$RADIO is not a wifi-device"
	_band=$(uci -q get "wireless.$RADIO.band" 2>/dev/null) || _band=
	[ "$_band" = 6g ] ||
		die "wireless.$RADIO does not have band '6g' (got '${_band:-unset}')"
	_disabled=$(uci -q get "wireless.$RADIO.disabled" 2>/dev/null) || _disabled=
	[ "$_disabled" != 1 ] ||
		die "wireless.$RADIO is disabled; enable it before --add-bss"
}

create_bss() {
	[ -f "$WIRELESS_CONFIG" ] || die "$WIRELESS_CONFIG not found"
	command -v uci >/dev/null 2>&1 || die "uci not found"
	command -v wifi >/dev/null 2>&1 || die "wifi not found"
	[ "$(id -u 2>/dev/null)" = 0 ] || die "--add-bss requires root"

	[ -n "$RADIO" ] || detect_6g_radio
	check_radio

	if [ -z "$SSID" ]; then
		SSID="6g-rx-$$"
	fi
	if ssid_is_off6g "$SSID"; then
		die "SSID '$SSID' is also used outside 6 GHz; pass a unique --ssid"
	fi

	if [ "$OUT_CREATED" = 0 ]; then
		make_out
	fi

	WIRELESS_BACKUP="$OUT/wireless.backup"
	cp -p "$WIRELESS_CONFIG" "$WIRELESS_BACKUP" 2>/dev/null ||
		die "cannot back up $WIRELESS_CONFIG"
	set_digest_algo
	ORIG_DIGEST=$(file_digest "$WIRELESS_CONFIG")
	if [ -z "$ORIG_DIGEST" ]; then
		# The digest tool failed; fall back to a byte compare with the
		# backup that cp just made.
		DIGEST_ALGO='cmp'
	fi
	BSS_CHANGED=1
	printf 'restore after a hard kill (SIGKILL): cat %s > %s && wifi reload\n' \
		"$WIRELESS_BACKUP" "$WIRELESS_CONFIG"

	_sec="rx6g_$$"
	uci -q get "wireless.$_sec" >/dev/null 2>&1 &&
		die "temporary UCI section wireless.$_sec already exists; remove it or restore the config first"
	log_cmd "uci set wireless.$_sec=wifi-iface (backup: $WIRELESS_BACKUP)"
	uci set "wireless.$_sec=wifi-iface" || die "uci set failed"
	uci set "wireless.$_sec.device=$RADIO" || die "uci set failed"
	uci set "wireless.$_sec.mode=ap" || die "uci set failed"
	uci set "wireless.$_sec.ssid=$SSID" || die "uci set failed"
	uci set "wireless.$_sec.network=lan" || die "uci set failed"
	uci set "wireless.$_sec.encryption=owe" || die "uci set failed"
	uci set "wireless.$_sec.ieee80211w=2" || die "uci set failed"
	uci set "wireless.$_sec.disabled=0" || die "uci set failed"
	uci commit wireless || die "uci commit wireless failed"
	TEMP_SSID=$SSID

	printf 'temporary 6G-only BSS "%s" on %s (6 GHz); restore is automatic\n' \
		"$SSID" "$RADIO"
	printf 'associate the 6G STA now; waiting up to %ss for the BSS\n' "$BSS_WAIT"

	wifi reload >>"$RAW_LOG" 2>&1 ||
		warn "wifi reload returned non-zero; checking whether the BSS came up"

	_deadline=$(( $(now_s) + BSS_WAIT ))
	_created=
	while [ "$(now_s)" -lt "$_deadline" ]; do
		bss_table >/dev/null 2>&1
		_created=$(find_bss_by_ssid "$SSID")
		[ -n "$_created" ] && break
		sleep 2
	done
	[ -n "$_created" ] ||
		die "temporary BSS '$SSID' did not appear within ${BSS_WAIT}s"
	SEL_IFACE=$(printf '%s' "$_created" | cut -f1)
	SEL_PHY=$(printf '%s' "$_created" | cut -f2)
	SEL_FREQ=$(printf '%s' "$_created" | cut -f3)
	SEL_SSID=$(printf '%s' "$_created" | cut -f4)
	printf 'BSS ready: %s (phy %s, %s MHz, SSID "%s")\n' \
		"$SEL_IFACE" "$SEL_PHY" "$SEL_FREQ" "$SEL_SSID"
}

# --- output directory and trap ----------------------------------------

make_out() {
	[ "$OUT_CREATED" = 1 ] && return 0
	if [ -e "$OUT" ]; then
		die "output directory already exists: $OUT"
	fi
	mkdir -p "$OUT" 2>/dev/null || die "cannot create output directory $OUT"
	RAW_LOG="$OUT/raw.log"
	: >"$RAW_LOG" 2>/dev/null || die "cannot write $RAW_LOG"
	OUT_CREATED=1
	start_trap
}

start_trap() {
	[ "$TRAP_SET" = 1 ] && return 0
	TRAP_SET=1
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
}

# shellcheck disable=SC2329  # called from the EXIT/HUP/INT/TERM trap
cleanup() {
	_cleanup_rc=$?
	trap - EXIT HUP INT TERM
	if [ -n "${TMP_TABLE:-}" ]; then
		rm -f "$TMP_TABLE" "$TMP_TABLE.resolved" "$TMP_TABLE.candidates" 2>/dev/null
	fi
	if [ -n "${SRC_PID:-}" ] && kill -0 "$SRC_PID" 2>/dev/null; then
		kill "$SRC_PID" 2>/dev/null
		wait "$SRC_PID" 2>/dev/null
	fi
	SRC_PID=
	if [ "${BSS_CHANGED:-0}" = 1 ]; then
		printf '%s: restoring %s from %s\n' \
			"$PROG" "$WIRELESS_CONFIG" "$WIRELESS_BACKUP"
		if cat "$WIRELESS_BACKUP" >"$WIRELESS_CONFIG" 2>/dev/null; then
			_gone=0
			for _try in 1 2 3; do
				wifi reload >>"${RAW_LOG:-/dev/null}" 2>&1 ||
					warn "wifi reload after restore returned non-zero"
				sleep 1
				if [ -z "$TEMP_SSID" ] ||
					! iw dev 2>/dev/null | awk -v s="$TEMP_SSID" '
						{
							sub(/^[ \t]+/, "", $0)
							if (index($0, "ssid ") == 1 && substr($0, 6) == s)
								found = 1
						}
						END { exit !found }
					'; then
					_gone=1
					break
				fi
			done
			if [ "$_gone" != 1 ]; then
				printf '%s: ERROR: temporary BSS "%s" is still present after restore + wifi reload\n' \
					"$PROG" "$TEMP_SSID" >&2
				_cleanup_rc=1
			else
				printf '%s: temporary BSS removed\n' "$PROG"
			fi
			if digest_matches "$WIRELESS_CONFIG" "$ORIG_DIGEST"; then
				printf '%s: config restored (digest %s)\n' \
					"$PROG" "$ORIG_DIGEST"
			else
				printf '%s: ERROR: config digest mismatch after restore (expected %s, now %s)\n' \
					"$PROG" "$ORIG_DIGEST" \
					"$(file_digest "$WIRELESS_CONFIG")" >&2
				_cleanup_rc=1
			fi
		else
			printf '%s: ERROR: could not restore %s; backup is %s\n' \
				"$PROG" "$WIRELESS_CONFIG" "$WIRELESS_BACKUP" >&2
			_cleanup_rc=1
		fi
	fi
	exit "$_cleanup_rc"
}

# --- interface checks and debugfs -------------------------------------

detect_ap_ip() {
	[ -n "$AP_IP" ] && return 0
	_master=$(ip link show dev "$SEL_IFACE" 2>/dev/null |
		awk '{ for (i = 1; i <= NF; i++) if ($i == "master") print $(i + 1) }' |
		head -n 1)
	_devs="br-lan ${_master:-}"
	for _dev in $_devs; do
		[ -n "$_dev" ] || continue
		_ip=$(ip addr show dev "$_dev" 2>/dev/null |
			awk '$1 == "inet" { sub(/\/.*/, "", $2); print $2; exit }')
		if [ -n "$_ip" ]; then
			AP_IP=$_ip
			return 0
		fi
	done
	return 1
}

ethtool_value() {
	awk -v k="$2" '
		{
			key = $1
			sub(/:$/, "", key)
			if (key == k) { print $2; found = 1; exit }
		}
		END { if (!found) print "" }
	' "$1" 2>/dev/null
}

ethtool_has_counter() {
	# $1 interface; requires a numeric rx_ampdu_bytes_cnt value.
	ethtool -S "$1" 2>/dev/null |
		awk '
			{
				key = $1
				sub(/:$/, "", key)
				if (key == "rx_ampdu_bytes_cnt" && $2 ~ /^[0-9]+$/)
					found = 1
			}
			END { exit !found }
		'
}

resolve_ethtool_iface() {
	if [ -n "$ETHTOOL_IFACE" ]; then
		ethtool_has_counter "$ETHTOOL_IFACE" ||
			die "$ETHTOOL_IFACE does not expose rx_ampdu_bytes_cnt"
		return 0
	fi
	if ethtool_has_counter "$SEL_IFACE"; then
		ETHTOOL_IFACE=$SEL_IFACE
		return 0
	fi
	# The MIB counter is per phy, so another AP netdev on the same phy is
	# equivalent for the A-MPDU byte count.
	_alt=
	while IFS="$(printf '\t')" read -r _if _phy _freq _ssid; do
		[ -n "$_if" ] || continue
		[ "$_phy" = "$SEL_PHY" ] || continue
		[ "$_if" = "$SEL_IFACE" ] && continue
		if ethtool_has_counter "$_if"; then
			_alt=$_if
			break
		fi
	done <"$TMP_TABLE"
	if [ -n "$_alt" ]; then
		ETHTOOL_IFACE=$_alt
		warn "rx_ampdu_bytes_cnt is not exposed on $SEL_IFACE; using $ETHTOOL_IFACE on the same phy"
		return 0
	fi
	_names=$(ethtool -S "$SEL_IFACE" 2>/dev/null |
		awk '{ key = $1; sub(/:$/, "", key) } key ~ /^rx_/ { n++; if (n <= 12) printf "%s ", key }')
	die "ethtool -S $SEL_IFACE does not expose rx_ampdu_bytes_cnt; cannot measure the A-MPDU byte delta (RX counters: ${_names:-none}). If ethtool reported a permission error, rerun as root."
}

find_debugfs_file() {
	# $1 filename under DEBUGFS/ieee80211/phy*/mt76
	[ -n "$SEL_PHY" ] && [ -r "$DEBUGFS/ieee80211/phy$SEL_PHY/mt76/$1" ] &&
		{ printf '%s' "$DEBUGFS/ieee80211/phy$SEL_PHY/mt76/$1"; return 0; }
	for _f in "$DEBUGFS"/ieee80211/phy*/mt76/"$1"; do
		[ -r "$_f" ] || continue
		printf '%s' "$_f"
		return 0
	done
	return 1
}

resolve_debugfs() {
	TOKEN_INFO_PATH=$(find_debugfs_file token_info) || TOKEN_INFO_PATH=
	BAND_BYTES_PATH=$(find_debugfs_file band_bytes) || BAND_BYTES_PATH=
	[ -n "$TOKEN_INFO_PATH" ] ||
		warn "mt76 token_info not found under $DEBUGFS; NPU queue evidence will be n/a"
	[ -n "$BAND_BYTES_PATH" ] ||
		warn "mt76 band_bytes not found under $DEBUGFS; 6G band A-MPDU evidence will be n/a"
}

# --- snapshots and parsing --------------------------------------------

snapshot_before() {
	capture "$OUT/station-before.txt" iw dev "$SEL_IFACE" station dump
	capture "$OUT/ethtool-before.txt" ethtool -S "$ETHTOOL_IFACE"
	capture "$OUT/interrupts-before.txt" cat "$PROC_INTERRUPTS"
	if [ -n "$TOKEN_INFO_PATH" ]; then
		capture "$OUT/token-info-before.txt" cat "$TOKEN_INFO_PATH"
	else
		write_note "$OUT/token-info-before.txt" "n/a: token_info not found"
	fi
	if [ -n "$BAND_BYTES_PATH" ]; then
		capture "$OUT/band-bytes-before.txt" cat "$BAND_BYTES_PATH"
	else
		write_note "$OUT/band-bytes-before.txt" "n/a: band_bytes not found"
	fi
	capture "$OUT/ap-rx-before.txt" cat "/sys/class/net/$SEL_IFACE/statistics/rx_bytes"
	capture "$OUT/uptime-before.txt" cat /proc/uptime
}

snapshot_mid() {
	capture "$OUT/station-mid.txt" iw dev "$SEL_IFACE" station dump
	capture "$OUT/ethtool-mid.txt" ethtool -S "$ETHTOOL_IFACE"
	if [ -n "$TOKEN_INFO_PATH" ]; then
		capture "$OUT/token-info-mid.txt" cat "$TOKEN_INFO_PATH"
	fi
}

snapshot_after() {
	capture "$OUT/uptime-after.txt" cat /proc/uptime
	capture "$OUT/station-after.txt" iw dev "$SEL_IFACE" station dump
	capture "$OUT/ethtool-after.txt" ethtool -S "$ETHTOOL_IFACE"
	capture "$OUT/interrupts-after.txt" cat "$PROC_INTERRUPTS"
	if [ -n "$TOKEN_INFO_PATH" ]; then
		capture "$OUT/token-info-after.txt" cat "$TOKEN_INFO_PATH"
	else
		write_note "$OUT/token-info-after.txt" "n/a: token_info not found"
	fi
	if [ -n "$BAND_BYTES_PATH" ]; then
		capture "$OUT/band-bytes-after.txt" cat "$BAND_BYTES_PATH"
	else
		write_note "$OUT/band-bytes-after.txt" "n/a: band_bytes not found"
	fi
	capture "$OUT/ap-rx-after.txt" cat "/sys/class/net/$SEL_IFACE/statistics/rx_bytes"
}

station_value() {
	# $1 station dump file, $2 MAC, $3 exact key (e.g. "rx bytes")
	awk -v want="$(printf '%s' "$2" | tr 'A-F' 'a-f')" -v key="$3" '
		/^Station / { mac = tolower($2); next }
		mac != want { next }
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (index(line, key ":") == 1) {
				v = line
				sub(/^[^:]*:[ \t]*/, "", v)
				print v
				exit
			}
		}
	' "$1" 2>/dev/null
}

token_value() {
	awk -v k="$2" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (index(line, k ":") == 1) {
				v = line
				sub(/^[^:]*:[ \t]*/, "", v)
				print v
				exit
			}
		}
	' "$1" 2>/dev/null
}

token_queue() {
	# $1 token_info file, $2 npu_rx0|npu_rx1
	awk -v q="$2" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			gsub(/\|/, " ", line)
			n = split(line, a, / +/)
			if (a[1] == q) {
				c = 0
				for (i = 2; i <= n; i++)
					if (a[i] ~ /^[0-9]+$/) {
						c++
						if (c == 2) { print a[i]; exit }
					}
			}
		}
	' "$1" 2>/dev/null
}

band_bytes_value() {
	# $1 band_bytes file, $2 band index
	awk -v b="$2" '
		/Phy band [0-9]+/ { band = $3 }
		$1 == "rx_ampdu_bytes:" && band == b { print $2; exit }
	' "$1" 2>/dev/null
}

uptime_delta() {
	[ -r "$1" ] && [ -r "$2" ] || return 0
	awk 'FNR == NR { b = $1; next } { printf "%.3f", $1 - b }' "$1" "$2"
}

iperf_sum_field() {
	# $1 iperf3 JSON, $2 sum_sent|sum_received, $3 field
	awk -v sum="$2" -v key="$3" '
		BEGIN { inblock = 0 }
		{
			if (!inblock && index($0, "\"" sum "\":") > 0) {
				inblock = 1
				next
			}
			if (inblock && $0 ~ /^[ \t]*\}[,]?[ \t]*$/)
				exit
			if (inblock && index($0, "\"" key "\":") > 0) {
				v = $0
				sub(/^.*:[ \t]*/, "", v)
				sub(/[ \t]*[,]?[ \t]*$/, "", v)
				gsub(/"/, "", v)
				print v
				exit
			}
		}
	' "$1" 2>/dev/null
}

iperf_error() {
	awk '
		index($0, "\"error\":") > 0 {
			v = $0
			sub(/^.*:[ \t]*/, "", v)
			sub(/^"/, "", v)
			sub(/".*$/, "", v)
			print v
			exit
		}
	' "$1" 2>/dev/null
}

port_connected() {
	if command -v ss >/dev/null 2>&1; then
		ss -tn 2>/dev/null |
			awk -v p=":$PORT" 'index($0, p) && /ESTAB/ { found = 1 } END { exit !found }'
	elif command -v netstat >/dev/null 2>&1; then
		netstat -tn 2>/dev/null |
			awk -v p=":$PORT" 'index($0, p) && /ESTABLISHED/ { found = 1 } END { exit !found }'
	else
		return 1
	fi
}

# --- source modes -----------------------------------------------------

listen_client_command() {
	_cmd="iperf3 -c $AP_IP -t $WINDOW -p $PORT -P $PARALLEL"
	if [ "$PROTO" = udp ]; then
		_cmd="$_cmd -u -b $UDP_RATE"
	fi
	printf '%s' "$_cmd"
}

run_source_listen() {
	log_cmd "iperf3 -s -1 -p $PORT -J > $OUT/iperf.json"
	iperf3 -s -1 -p "$PORT" -J >"$OUT/iperf.json" 2>"$OUT/iperf.err" &
	SRC_PID=$!
	_client=$(listen_client_command)
	log_line "+ STA command: $_client"
	printf '\nRun this on the 6G STA now (waiting up to %ss):\n  %s\n\n' \
		"$SOURCE_WAIT" "$_client"

	_connected=0
	_start=$(now_s)
	while [ "$(now_s)" -lt $((_start + SOURCE_WAIT)) ]; do
		if ! kill -0 "$SRC_PID" 2>/dev/null; then
			break
		fi
		if port_connected; then
			_connected=1
			break
		fi
		sleep 1
	done

	if [ "$_connected" = 1 ]; then
		_half=$((WINDOW / 2))
		[ "$_half" -ge 1 ] || _half=1
		sleep "$_half"
		snapshot_mid
	elif ! kill -0 "$SRC_PID" 2>/dev/null; then
		# The one-off server already exited.  If it left JSON, a client
		# ran (even if it failed); otherwise there was no source.
		if [ -s "$OUT/iperf.json" ]; then
			_connected=1
		else
			wait "$SRC_PID" 2>/dev/null
			_st=$?
			SRC_PID=
			[ "$_st" -eq 0 ] && return 3
			return 1
		fi
	else
		# No client connected within --source-wait; stop the server.
		kill "$SRC_PID" 2>/dev/null
		wait "$SRC_PID" 2>/dev/null
		SRC_PID=
		return 3
	fi

	_deadline=$(( $(now_s) + WINDOW + 60 ))
	while kill -0 "$SRC_PID" 2>/dev/null && [ "$(now_s)" -lt "$_deadline" ]; do
		sleep 1
	done
	if kill -0 "$SRC_PID" 2>/dev/null; then
		warn "iperf3 server did not exit within $((WINDOW + 60))s; killing it"
		kill "$SRC_PID" 2>/dev/null
		wait "$SRC_PID" 2>/dev/null
		SRC_PID=
		return 1
	fi
	wait "$SRC_PID" 2>/dev/null
	_st=$?
	SRC_PID=
	return "$_st"
}

run_source_reverse() {
	if [ "$PROTO" = udp ]; then
		_proto_args="-u -b $UDP_RATE"
	else
		_proto_args=
	fi
	log_cmd "iperf3 -c $STA_IP -R $_proto_args -t $WINDOW -p $PORT -P $PARALLEL -J > $OUT/iperf.json"
	# shellcheck disable=SC2086
	iperf3 -c "$STA_IP" -R $_proto_args -t "$WINDOW" -p "$PORT" -P "$PARALLEL" -J \
		>"$OUT/iperf.json" 2>"$OUT/iperf.err" &
	SRC_PID=$!
	printf '\nreverse source from STA %s (iperf3 server on port %s), window %ss\n' \
		"$STA_IP" "$PORT" "$WINDOW"
	sleep 1
	if kill -0 "$SRC_PID" 2>/dev/null; then
		_half=$((WINDOW / 2))
		[ "$_half" -ge 1 ] || _half=1
		sleep "$_half"
		snapshot_mid
	fi
	_deadline=$(( $(now_s) + WINDOW + 60 ))
	while kill -0 "$SRC_PID" 2>/dev/null && [ "$(now_s)" -lt "$_deadline" ]; do
		sleep 1
	done
	if kill -0 "$SRC_PID" 2>/dev/null; then
		warn "iperf3 client did not exit within $((WINDOW + 60))s; killing it"
		kill "$SRC_PID" 2>/dev/null
		wait "$SRC_PID" 2>/dev/null
		SRC_PID=
		return 1
	fi
	wait "$SRC_PID" 2>/dev/null
	_st=$?
	SRC_PID=
	return "$_st"
}

# --- IRQ parsing ------------------------------------------------------

irq_deltas() {
	# $1 before, $2 after, $3 pattern.  Prints IRQ/GROUP/MATCHED tab lines.
	awk -v pat="$3" '
		function lc(s) { return tolower(s) }
		BEGIN { first = ARGV[1] }
		FILENAME == first {
			if ($0 ~ /^[ \t]*[0-9]+:/) {
				irq = $1
				sub(/:$/, "", irq)
				sum = 0
				j = 2
				while (j <= NF && $j ~ /^[0-9]+$/) { sum += $j; j++ }
				desc = ""
				for (k = j; k <= NF; k++)
					desc = desc (desc == "" ? "" : " ") $k
				before[irq] = sum
				before_desc[irq] = desc
			}
			next
		}
		{
			if ($0 ~ /^[ \t]*[0-9]+:/) {
				irq = $1
				sub(/:$/, "", irq)
				if (!(irq in before))
					next
				sum = 0
				j = 2
				while (j <= NF && $j ~ /^[0-9]+$/) { sum += $j; j++ }
				desc = ""
				for (k = j; k <= NF; k++)
					desc = desc (desc == "" ? "" : " ") $k
				if (desc == "")
					desc = before_desc[irq]
				if (lc(desc) !~ lc(pat))
					next
				delta = sum - before[irq]
				printf "IRQ\t%s\t%s\t%d\n", irq, desc, delta
				if (lc(desc) ~ /hif/)
					hif2 += delta
				else if (lc(desc) ~ /pcie|mt7996/)
					pcie0 += delta
				matched++
			}
		}
		END {
			printf "GROUP\tpcie0\t%d\n", pcie0 + 0
			printf "GROUP\thif2\t%d\n", hif2 + 0
			printf "MATCHED\t%d\n", matched + 0
		}
	' "$1" "$2" 2>/dev/null
}

# --- final analysis and output ----------------------------------------

analyze() {
	_sb="$OUT/station-before.txt"
	_sm="$OUT/station-mid.txt"
	_sa="$OUT/station-after.txt"

	RX_BYTES_BEFORE=$(station_value "$_sb" "$STA_MAC" "rx bytes")
	RX_BYTES_AFTER=$(station_value "$_sa" "$STA_MAC" "rx bytes")
	RX_BYTES_DELTA=$(counter_delta "$RX_BYTES_BEFORE" "$RX_BYTES_AFTER")
	RX_PACKETS_BEFORE=$(station_value "$_sb" "$STA_MAC" "rx packets")
	RX_PACKETS_AFTER=$(station_value "$_sa" "$STA_MAC" "rx packets")
	RX_PACKETS_DELTA=$(counter_delta "$RX_PACKETS_BEFORE" "$RX_PACKETS_AFTER")
	TX_BYTES_BEFORE=$(station_value "$_sb" "$STA_MAC" "tx bytes")
	TX_BYTES_AFTER=$(station_value "$_sa" "$STA_MAC" "tx bytes")
	TX_BYTES_DELTA=$(counter_delta "$TX_BYTES_BEFORE" "$TX_BYTES_AFTER")
	STA_SIGNAL=$(station_value "$_sb" "$STA_MAC" "signal")
	STA_CONNECTED=$(station_value "$_sa" "$STA_MAC" "connected time")
	RX_BITRATE=$(station_value "$_sm" "$STA_MAC" "rx bitrate")
	[ -n "$RX_BITRATE" ] || RX_BITRATE=$(station_value "$_sa" "$STA_MAC" "rx bitrate")
	TX_BITRATE=$(station_value "$_sa" "$STA_MAC" "tx bitrate")

	AP_RX_BYTES_BEFORE=$(cat "$OUT/ap-rx-before.txt" 2>/dev/null)
	is_uint "$AP_RX_BYTES_BEFORE" || AP_RX_BYTES_BEFORE=
	AP_RX_BYTES_AFTER=$(cat "$OUT/ap-rx-after.txt" 2>/dev/null)
	is_uint "$AP_RX_BYTES_AFTER" || AP_RX_BYTES_AFTER=
	AP_RX_BYTES_DELTA=$(counter_delta "$AP_RX_BYTES_BEFORE" "$AP_RX_BYTES_AFTER")

	AMPDU_BYTES_BEFORE=$(ethtool_value "$OUT/ethtool-before.txt" rx_ampdu_bytes_cnt)
	AMPDU_BYTES_AFTER=$(ethtool_value "$OUT/ethtool-after.txt" rx_ampdu_bytes_cnt)
	AMPDU_BYTES_DELTA=$(counter_delta "$AMPDU_BYTES_BEFORE" "$AMPDU_BYTES_AFTER")
	AMPDU_CNT_BEFORE=$(ethtool_value "$OUT/ethtool-before.txt" rx_ampdu_cnt)
	AMPDU_CNT_AFTER=$(ethtool_value "$OUT/ethtool-after.txt" rx_ampdu_cnt)
	AMPDU_CNT_DELTA=$(counter_delta "$AMPDU_CNT_BEFORE" "$AMPDU_CNT_AFTER")
	MPDU_CNT_BEFORE=$(ethtool_value "$OUT/ethtool-before.txt" rx_mpdu_cnt)
	MPDU_CNT_AFTER=$(ethtool_value "$OUT/ethtool-after.txt" rx_mpdu_cnt)
	MPDU_CNT_DELTA=$(counter_delta "$MPDU_CNT_BEFORE" "$MPDU_CNT_AFTER")
	BA_CNT_BEFORE=$(ethtool_value "$OUT/ethtool-before.txt" rx_ba_cnt)
	BA_CNT_AFTER=$(ethtool_value "$OUT/ethtool-after.txt" rx_ba_cnt)
	BA_CNT_DELTA=$(counter_delta "$BA_CNT_BEFORE" "$BA_CNT_AFTER")

	BAND_AMPDU_BEFORE=$(band_bytes_value "$OUT/band-bytes-before.txt" "$SIXG_BAND")
	BAND_AMPDU_AFTER=$(band_bytes_value "$OUT/band-bytes-after.txt" "$SIXG_BAND")
	BAND_AMPDU_DELTA=$(counter_delta "$BAND_AMPDU_BEFORE" "$BAND_AMPDU_AFTER")

	COUNTER_SECONDS=$(uptime_delta "$OUT/uptime-before.txt" "$OUT/uptime-after.txt")

	IPERF_RX_BPS=$(iperf_sum_field "$OUT/iperf.json" sum_received bits_per_second)
	IPERF_RX_BYTES=$(iperf_sum_field "$OUT/iperf.json" sum_received bytes)
	IPERF_SECONDS=$(iperf_sum_field "$OUT/iperf.json" sum_received seconds)
	IPERF_RETRANSMITS=$(iperf_sum_field "$OUT/iperf.json" sum_received retransmits)
	IPERF_LOST=$(iperf_sum_field "$OUT/iperf.json" sum_received lost_packets)
	IPERF_LOST_PCT=$(iperf_sum_field "$OUT/iperf.json" sum_received lost_percent)
	IPERF_JITTER=$(iperf_sum_field "$OUT/iperf.json" sum_received jitter_ms)

	TOKEN_BEFORE=$(token_value "$OUT/token-info-before.txt" token_count)
	TOKEN_AFTER=$(token_value "$OUT/token-info-after.txt" token_count)
	WED_TOKEN_BEFORE=$(token_value "$OUT/token-info-before.txt" wed_token_count)
	WED_TOKEN_AFTER=$(token_value "$OUT/token-info-after.txt" wed_token_count)
	RX_TOKEN_SIZE_BEFORE=$(token_value "$OUT/token-info-before.txt" rx_token_size)
	RX_TOKEN_SIZE_AFTER=$(token_value "$OUT/token-info-after.txt" rx_token_size)
	NPU0_QUEUED_BEFORE=$(token_queue "$OUT/token-info-before.txt" npu_rx0)
	NPU0_QUEUED_AFTER=$(token_queue "$OUT/token-info-after.txt" npu_rx0)
	NPU1_QUEUED_BEFORE=$(token_queue "$OUT/token-info-before.txt" npu_rx1)
	NPU1_QUEUED_AFTER=$(token_queue "$OUT/token-info-after.txt" npu_rx1)

	_irq=$(irq_deltas "$OUT/interrupts-before.txt" "$OUT/interrupts-after.txt" "$IRQ_PATTERN")
	IRQ_PCIE0_DELTA=$(printf '%s\n' "$_irq" | awk -F"$(printf '\t')" '$1 == "GROUP" && $2 == "pcie0" { print $3 }')
	IRQ_HIF2_DELTA=$(printf '%s\n' "$_irq" | awk -F"$(printf '\t')" '$1 == "GROUP" && $2 == "hif2" { print $3 }')
	IRQ_LINE_COUNT=$(printf '%s\n' "$_irq" | awk -F"$(printf '\t')" '$1 == "MATCHED" { print $2 }')
	is_uint "$IRQ_LINE_COUNT" || IRQ_LINE_COUNT=0
	is_uint "$IRQ_PCIE0_DELTA" || IRQ_PCIE0_DELTA=0
	is_uint "$IRQ_HIF2_DELTA" || IRQ_HIF2_DELTA=0

	# Rate: use the iperf3 receiver window when available because the
	# listen mode may wait for the client before traffic starts.
	RATE_SECONDS=$IPERF_SECONDS
	if ! awk -v v="${RATE_SECONDS:-}" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v > 0) }'; then
		RATE_SECONDS=$COUNTER_SECONDS
	fi
	if is_positive "$RX_BYTES_DELTA" && [ -n "$RATE_SECONDS" ]; then
		RX_MBIT_S=$(awk -v b="$RX_BYTES_DELTA" -v s="$RATE_SECONDS" \
			'BEGIN { printf "%.1f", b * 8 / s / 1000000 }')
	fi

	# Verdict.
	if [ "$SOURCE_STATUS" -ne 0 ]; then
		VERDICT=invalid
		VERDICT_REASON="the iperf3 source did not complete"
	elif ! is_positive "$RX_BYTES_DELTA"; then
		VERDICT=undetermined
		VERDICT_REASON="station rx bytes did not increase"
	elif [ "$IRQ_PCIE0_DELTA" -gt "$IRQ_HIF2_DELTA" ]; then
		VERDICT=PCIe0
		VERDICT_REASON="PCIe0 IRQ delta is larger"
	elif [ "$IRQ_HIF2_DELTA" -gt "$IRQ_PCIE0_DELTA" ]; then
		VERDICT=hif2
		VERDICT_REASON="hif2 IRQ delta is larger"
	elif [ "$IRQ_PCIE0_DELTA" -eq 0 ] && [ "$IRQ_HIF2_DELTA" -eq 0 ]; then
		VERDICT=undetermined
		VERDICT_REASON="no PCIe0/hif2 IRQ delta (possible NPU/RRO path)"
	else
		VERDICT=undetermined
		VERDICT_REASON="PCIe0 and hif2 IRQ deltas are equal"
	fi
	IRQ_OUTPUT=$_irq
}

print_report() {
	printf '\n6G RX uplink result\n'
	printf '  iface: %s (phy %s, %s MHz, SSID "%s")\n' \
		"$SEL_IFACE" "$SEL_PHY" "$SEL_FREQ" "$SEL_SSID"
	printf '  sta:   %s (signal: %s, connected: %s)\n' \
		"$STA_MAC" "$(val_or_na "$STA_SIGNAL")" "$(val_or_na "$STA_CONNECTED")"
	if [ -n "$STA_IP" ]; then
		printf '  source: reverse iperf3 from STA %s (%s, %ss, %s stream(s), port %s)\n' \
			"$STA_IP" "$PROTO" "$WINDOW" "$PARALLEL" "$PORT"
	else
		printf '  source: listen iperf3 from the STA to AP %s (%s, %ss, %s stream(s), port %s)\n' \
			"$AP_IP" "$PROTO" "$WINDOW" "$PARALLEL" "$PORT"
	fi
	printf '  window: requested %ss, iperf3 receiver %ss, counter sample %ss\n' \
		"$WINDOW" "$(val_or_na "$IPERF_SECONDS")" "$(val_or_na "$COUNTER_SECONDS")"
	if [ -n "$IPERF_SECONDS" ] &&
		awk -v a="$WINDOW" -v b="$IPERF_SECONDS" \
			'BEGIN { exit !(b < a * 0.8 || b > a * 1.2 + 1) }'; then
		warn "the STA source ran for ${IPERF_SECONDS}s, requested ${WINDOW}s"
	fi
	printf '  ethtool iface: %s\n' "$ETHTOOL_IFACE"

	printf '\nAP RX counters:\n'
	printf '  station rx bytes       before %-12s after %-12s delta %s\n' \
		"$(val_or_na "$RX_BYTES_BEFORE")" "$(val_or_na "$RX_BYTES_AFTER")" \
		"$(val_or_na "$RX_BYTES_DELTA")"
	printf '  station rx packets     before %-12s after %-12s delta %s\n' \
		"$(val_or_na "$RX_PACKETS_BEFORE")" "$(val_or_na "$RX_PACKETS_AFTER")" \
		"$(val_or_na "$RX_PACKETS_DELTA")"
	printf '  station tx bytes       before %-12s after %-12s delta %s (context)\n' \
		"$(val_or_na "$TX_BYTES_BEFORE")" "$(val_or_na "$TX_BYTES_AFTER")" \
		"$(val_or_na "$TX_BYTES_DELTA")"
	printf '  station rx bitrate     %s\n' "$(val_or_na "$RX_BITRATE")"
	printf '  station tx bitrate     %s (context)\n' "$(val_or_na "$TX_BITRATE")"
	printf '  station rx rate        %s Mbit/s (delta / %ss)\n' \
		"$(val_or_na "$RX_MBIT_S")" "$(val_or_na "$RATE_SECONDS")"
	printf '  AP netdev rx_bytes     before %-12s after %-12s delta %s\n' \
		"$(val_or_na "$AP_RX_BYTES_BEFORE")" "$(val_or_na "$AP_RX_BYTES_AFTER")" \
		"$(val_or_na "$AP_RX_BYTES_DELTA")"

	printf '\nAP ethtool -S deltas (%s):\n' "$ETHTOOL_IFACE"
	printf '  rx_ampdu_bytes_cnt     before %-12s after %-12s delta %s\n' \
		"$(val_or_na "$AMPDU_BYTES_BEFORE")" "$(val_or_na "$AMPDU_BYTES_AFTER")" \
		"$(val_or_na "$AMPDU_BYTES_DELTA")"
	printf '  rx_ampdu_cnt           before %-12s after %-12s delta %s\n' \
		"$(val_or_na "$AMPDU_CNT_BEFORE")" "$(val_or_na "$AMPDU_CNT_AFTER")" \
		"$(val_or_na "$AMPDU_CNT_DELTA")"
	printf '  rx_mpdu_cnt            before %-12s after %-12s delta %s\n' \
		"$(val_or_na "$MPDU_CNT_BEFORE")" "$(val_or_na "$MPDU_CNT_AFTER")" \
		"$(val_or_na "$MPDU_CNT_DELTA")"
	printf '  rx_ba_cnt              before %-12s after %-12s delta %s\n' \
		"$(val_or_na "$BA_CNT_BEFORE")" "$(val_or_na "$BA_CNT_AFTER")" \
		"$(val_or_na "$BA_CNT_DELTA")"
	printf '  mt76 band_bytes Phy band %s rx_ampdu_bytes delta %s (6 GHz MIB, %s)\n' \
		"$SIXG_BAND" "$(val_or_na "$BAND_AMPDU_DELTA")" \
		"$(val_or_na "$BAND_BYTES_PATH")"

	printf '\niperf3 receiver:\n'
	if [ -n "$IPERF_RX_BPS" ]; then
		printf '  %s Mbit/s (%s bytes, %ss' \
			"$(awk -v b="$IPERF_RX_BPS" 'BEGIN { printf "%.1f", b / 1000000 }')" \
			"$(val_or_na "$IPERF_RX_BYTES")" "$(val_or_na "$IPERF_SECONDS")"
		if [ -n "$IPERF_RETRANSMITS" ]; then
			printf ', retransmits %s' "$IPERF_RETRANSMITS"
		fi
		if [ -n "$IPERF_LOST" ]; then
			printf ', lost %s (%s%%)' "$IPERF_LOST" "$(val_or_na "$IPERF_LOST_PCT")"
		fi
		if [ -n "$IPERF_JITTER" ]; then
			printf ', jitter %s ms' \
				"$(awk -v j="$IPERF_JITTER" 'BEGIN { printf "%.2f", j }')"
		fi
		printf ')\n'
	else
		printf '  n/a (see %s)\n' "$OUT/iperf.err"
	fi

	printf '\n/proc/interrupts (pattern "%s"):\n' "$IRQ_PATTERN"
	printf '%s\n' "$IRQ_OUTPUT" |
		awk -F"$(printf '\t')" '$1 == "IRQ" { printf "  irq %-4s %-40s +%s\n", $2, $3, $4 }'
	[ "$IRQ_LINE_COUNT" -gt 0 ] || printf '  (no matching IRQ lines)\n'
	printf '  PCIe0 IRQ delta: %s\n' "$IRQ_PCIE0_DELTA"
	printf '  hif2 IRQ delta:  %s\n' "$IRQ_HIF2_DELTA"

	printf '\nmt76 token_info (%s):\n' "$(val_or_na "$TOKEN_INFO_PATH")"
	printf '  token_count:     %s -> %s\n' \
		"$(val_or_na "$TOKEN_BEFORE")" "$(val_or_na "$TOKEN_AFTER")"
	printf '  wed_token_count: %s -> %s\n' \
		"$(val_or_na "$WED_TOKEN_BEFORE")" "$(val_or_na "$WED_TOKEN_AFTER")"
	printf '  rx_token_size:   %s -> %s\n' \
		"$(val_or_na "$RX_TOKEN_SIZE_BEFORE")" "$(val_or_na "$RX_TOKEN_SIZE_AFTER")"
	printf '  npu_rx0 queued:  %s -> %s\n' \
		"$(val_or_na "$NPU0_QUEUED_BEFORE")" "$(val_or_na "$NPU0_QUEUED_AFTER")"
	printf '  npu_rx1 queued:  %s -> %s\n' \
		"$(val_or_na "$NPU1_QUEUED_BEFORE")" "$(val_or_na "$NPU1_QUEUED_AFTER")"

	if [ "$VERDICT" = undetermined ]; then
		printf '\nverdict: undetermined (%s)\n' "$VERDICT_REASON"
	elif [ "$VERDICT" = invalid ]; then
		printf '\nverdict: invalid (%s)\n' "$VERDICT_REASON"
	else
		printf '\nverdict: 6G RX data plane is on %s\n' "$VERDICT"
	fi
	printf '  evidence: PCIe0 IRQ +%s vs hif2 IRQ +%s; station rx bytes +%s; rx_ampdu_bytes_cnt +%s\n' \
		"$IRQ_PCIE0_DELTA" "$IRQ_HIF2_DELTA" \
		"$(val_or_na "$RX_BYTES_DELTA")" "$(val_or_na "$AMPDU_BYTES_DELTA")"

	printf '\nsummary:\n'
	printf '  RX_BYTES_BEFORE=%s\n' "$(val_or_na "$RX_BYTES_BEFORE")"
	printf '  RX_BYTES_AFTER=%s\n' "$(val_or_na "$RX_BYTES_AFTER")"
	printf '  RX_BYTES_DELTA=%s\n' "$(val_or_na "$RX_BYTES_DELTA")"
	printf '  RX_BITRATE=%s\n' "$(val_or_na "$RX_BITRATE")"
	printf '  RX_MBIT_S=%s\n' "$(val_or_na "$RX_MBIT_S")"
	printf '  RX_AMPDU_BYTES_CNT_DELTA=%s\n' "$(val_or_na "$AMPDU_BYTES_DELTA")"
	printf '  RX_AMPDU_CNT_DELTA=%s\n' "$(val_or_na "$AMPDU_CNT_DELTA")"
	printf '  RX_MPDU_CNT_DELTA=%s\n' "$(val_or_na "$MPDU_CNT_DELTA")"
	printf '  RX_BA_CNT_DELTA=%s\n' "$(val_or_na "$BA_CNT_DELTA")"
	printf '  IPERF_RX_BPS=%s\n' "$(val_or_na "$IPERF_RX_BPS")"
	printf '  IPERF_WINDOW_S=%s\n' "$(val_or_na "$IPERF_SECONDS")"
	printf '  COUNTER_WINDOW_S=%s\n' "$(val_or_na "$COUNTER_SECONDS")"
	printf '  RX_RATE_WINDOW_S=%s\n' "$(val_or_na "$RATE_SECONDS")"
	printf '  IRQ_PCIE0_DELTA=%s\n' "$IRQ_PCIE0_DELTA"
	printf '  IRQ_HIF2_DELTA=%s\n' "$IRQ_HIF2_DELTA"
	printf '  VERDICT=%s\n' "$VERDICT"
	printf '  RESULT_DIR=%s\n' "$OUT"
}

# --- main -------------------------------------------------------------

bss_table >/dev/null 2>&1

select_bss
_sel_rc=$?
if [ "$_sel_rc" -eq 1 ]; then
	if [ "$ADD_BSS" = 1 ]; then
		create_bss
		select_bss
		_sel_rc=$?
	fi
fi
if [ "$_sel_rc" -eq 2 ]; then
	# --sta was given but is not associated yet.
	if [ "$STA_WAIT" -gt 0 ]; then
		choose_station 2>/dev/null || true
		if ! wait_for_station "$STA_WAIT"; then
			skip "no 6G STA $STA_MAC on $SEL_IFACE"
		fi
	else
		skip "no 6G STA $STA_MAC on $SEL_IFACE"
	fi
	_sel_rc=0
fi
if [ "$_sel_rc" -ne 0 ]; then
	if [ "$ADD_BSS" = 1 ]; then
		skip "no 6G-only BSS after --add-bss (SSID ${SSID:-unknown})"
	else
		skip "no 6G-only BSS; pass --add-bss to create a temporary one"
	fi
fi

if ! choose_station; then
	if ! wait_for_station "$STA_WAIT"; then
		skip "no 6G STA on $SEL_IFACE (SSID \"$SEL_SSID\")"
	fi
fi

make_out

printf 'selected 6G BSS %s (phy %s, %s MHz, SSID "%s"), STA %s\n' \
	"$SEL_IFACE" "$SEL_PHY" "$SEL_FREQ" "$SEL_SSID" "$STA_MAC"

resolve_ethtool_iface
resolve_debugfs

if [ -n "$STA_IP" ]; then
	:
elif ! detect_ap_ip; then
	die "no AP IPv4 address found for the listen-mode client command; pass --ap-ip"
fi

snapshot_before

if [ -n "$STA_IP" ]; then
	run_source_reverse
	SOURCE_STATUS=$?
else
	run_source_listen
	SOURCE_STATUS=$?
fi

snapshot_after

if [ "$SOURCE_STATUS" -eq 3 ]; then
	skip "no STA source connected within ${SOURCE_WAIT}s"
fi

analyze
print_report

if [ "$SOURCE_STATUS" -ne 0 ]; then
	_err=$(iperf_error "$OUT/iperf.json")
	printf '\niperf3 source failed (exit %s%s)\n' "$SOURCE_STATUS" \
		"${_err:+: $_err}" >&2
	if [ -s "$OUT/iperf.err" ]; then
		printf 'iperf3 stderr:\n' >&2
		sed -n '1,5p' "$OUT/iperf.err" >&2
	fi
	exit 1
fi

if [ "$VERDICT" = undetermined ] && ! is_positive "$RX_BYTES_DELTA"; then
	printf '\nERROR: the source ran but the station RX bytes did not increase\n' >&2
	exit 1
fi

exit 0
