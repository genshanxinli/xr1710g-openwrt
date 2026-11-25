#!/bin/sh
#
# 6g320-matrix.sh - 6 GHz 320 MHz client throughput matrix harness.
#
# Why this exists: every 6 GHz 320 MHz result so far is a hand-assembled
# iperf3 number with no record of the client, the negotiated width or NSS,
# the regulatory country, the source path, or the station retry counters.
# Two runs cannot be compared, and a link that quietly dropped from 320 MHz
# to 160 MHz still produced a number that looked like a result.  This script
# runs the same two arms for every client and emits one machine-readable row
# per run.
#
# Requirements:
#   - On the AP: iw, iperf3, a POSIX shell (busybox ash is fine), and
#     either ssh or dbclient.  ip is needed only for automatic AP address
#     detection; `timeout` is used when available.
#   - A 6 GHz 320 MHz AP BSS.  The script discovers it with
#     "iw dev" + "iw dev IFACE info" (type AP*, 5945-7125 MHz, width 320).
#   - A client associated to that BSS at 320 MHz.  It is discovered from
#     "iw dev IFACE station dump"; a station with no 320 MHz rate in
#     either direction is not a 320 client.
#   - SSH access to the client, with key auth and iperf3 installed.  The
#     client does not need this script; the AP drives it over SSH.
#   - The client's route to the AP address must use the 6 GHz link.  Do not
#     connect the client through Ethernet at the same time; a wired route
#     would bypass the radio under test.
#   - The AP firewall must allow the client to reach AP_ADDR on the iperf3
#     port; the default LAN zone does.  A separate 6 GHz zone needs a
#     matching input rule.  Disable or allow the client's own firewall for
#     the same port.
#
# Fixed protocol (two arms, always sequential, never concurrent):
#
#   Arm 1, ap_to_sta ("local-source"):
#     iperf3 -s -1 -p PORT                       (on the AP; local source)
#     ssh CLIENT "iperf3 -c AP -p PORT -t D -O O -P S -i 0 -R -J"
#   Arm 2, sta_to_ap ("fixed RX"):
#     iperf3 -s -1 -p PORT                       (on the AP; AP receives)
#     ssh CLIENT "iperf3 -c AP -p PORT -t D -O O -P S -i 0 -J"
#
# AP->STA is reverse mode from the client, so the AP's iperf3 server sends
# data generated locally on the AP; no wired feed is in the path.  STA->AP
# is normal mode from the client, so the AP receives.  D is --duration, O
# is --omit, S is --streams.  Before and after each arm the AP's station
# entry is snapshotted.  Width and NSS are read from the direction under
# test: AP tx for AP->STA and AP rx for STA->AP, so a 1SS ACK path does not
# invalidate a 2SS data direction.  The arm is marked invalid when that
# direction's width is not 320 MHz, when its NSS is below --expected-nss,
# when the station re-associated during the arm, or when the station
# disappeared.  The measured throughput stays in the arm record but is not
# promoted to the row's valid AP->STA / STA->AP fields.  Validity is
# sampled before and after each arm; a downgrade that recovers between
# those two snapshots is not detected.
#
# Output streams:
#   stdout   one JSON object per line (JSONL), schema 6g320-matrix/v1.
#            On a hardware skip stdout contains "SKIP: no 320 client" (plus
#            the missing-hardware hint) and exit status is 3 (missing-hardware).
#            With --dry-run, stdout contains the plan instead of a row and exits 0.
#   stderr   progress, diagnostics, warnings, and the human summary table.
#
# Machine-readable schema:
#   scripts/wireless/6g320-matrix.schema.json (JSON Schema draft-07).
#   A row is:
#     schema                 const "6g320-matrix/v1"
#     record_type            const "row"
#     timestamp              UTC ISO 8601
#     ap.hostname            AP hostname
#     ap.model               /tmp/sysinfo/model, device-tree model, or "unknown"
#     ap.interface           6 GHz AP BSS interface
#     ap.channel             primary channel, integer
#     ap.frequency_mhz       primary frequency, integer, 5945..7125
#     ap.width_mhz           const 320
#     ap.center1_mhz         center1 frequency, integer or null
#     ap.ssid                BSS SSID, possibly ""
#     client.mac             station MAC, lower case
#     client.model           --client-model
#     client.driver          --client-driver
#     client.firmware        --client-firmware
#     country                AP regulatory alpha-2, upper case, "00" = world
#     association.width_mhz  minimum tested-direction width across the
#                            non-error arms: AP tx for AP->STA, AP rx for
#                            STA->AP; one of 20/40/80/160/320
#     association.nss        minimum tested-direction NSS across the
#                            non-error arms, integer or null
#     association.signal_dbm signal at selection, integer or null
#     source_path            "local" (the fixed arms are local-source)
#     ap_to_sta_gbit_s       valid AP->STA throughput, number or null
#     sta_to_ap_gbit_s       valid STA->AP throughput, number or null
#     retries                sum of AP station "tx retries" deltas over the
#                            non-error arm windows, integer or null
#     target_gbit_s          target, default 2.5
#     target_met             true iff ap_to_sta is ok and >= target
#     duration_s             iperf3 seconds per arm
#     streams                iperf3 streams per arm
#     iperf3.server          AP iperf3 version string
#     iperf3.client          client iperf3 version string or null
#     arms.ap_to_sta         arm object, documented below
#     arms.sta_to_ap         arm object
#     warnings               array of strings
#     raw_dir                directory holding the raw logs and JSON
#
#   Arm object:
#     status                 "ok" | "invalid" | "error"
#     gbit_s                 measured throughput in Gbit/s, number or null
#     bytes                  iperf3 bytes, integer or null
#     seconds                iperf3 seconds, number or null
#     tcp_retransmits        sender TCP retransmits, integer or null
#     station.width_mhz      tested-direction width at the arm end
#                            (AP tx for AP->STA, AP rx for STA->AP)
#     station.nss            tested-direction NSS at the arm end
#     station.signal_dbm     signal at the end of the arm, integer or null
#     station.tx_retries     AP tx retries delta, integer or null
#     station.tx_failed      AP tx failed delta, integer or null
#     invalid_reason         string or null
#     error                  string or null
#     command                exact remote iperf3 command, or ""
#
# source_path is always "local" because these two fixed arms both use an
# AP-local iperf3 endpoint.  The schema also allows "2.5G" for rows from a
# wired-feed run; this harness does not implement that variant.
#
# Hardware gate: if iw finds no 6 GHz 320 MHz AP BSS, or no station with a
# 320 MHz rate width in either direction, the script prints
# "SKIP: no 320 client" on stdout and exits 3 (missing-hardware).  A station
# whose rate width is 160 MHz in both directions is not a 320 client.  With an
# explicit --iface that is not a 6 GHz 320 MHz AP BSS, the script exits 1
# instead, because the caller asked for a specific interface.
#
# No UCI write, no module load/unload, no firmware change: the script only
# reads iw state, runs iperf3, and writes under --raw-dir.  The AP's iperf3
# server binds the port for the duration of one arm and is always killed.
#
# Exit status:
#   0  both arms ok, or --dry-run
#   1  a 320 MHz client was found, but an arm was invalid or failed, or
#      the setup needed for the run was incomplete
#   2  invalid arguments, missing required tool (missing-tool, e.g. iw), or
#      OWE configuration block (config-block)
#   3  clean hardware skip (missing-hardware: no 6 GHz 320 MHz AP BSS or no
#      320 MHz station)
#
# Examples:
#   # dry run: print the plan, execute nothing
#   sh scripts/wireless/6g320-matrix.sh --dry-run
#
#   # one real BE200 row, appended to a JSONL file
#   sh scripts/wireless/6g320-matrix.sh \
#       --client-ssh root@192.168.1.50 \
#       --client-mac 3c:58:c2:11:22:33 \
#       --client-model "Intel Wi-Fi 7 BE200" \
#       --client-driver iwlwifi \
#       --client-firmware "iwlwifi-BE200-b0-..." \
#       --duration 30 --streams 2 | tee -a /tmp/6g320.jsonl
#
#   # MEDIATEK MT7927 / Filogic 380 (mt7925e) works the same way.
#
# Expected clients: Intel Wi-Fi 7 BE200 (8086:272b, iwlwifi) and MediaTek
# MT7927 / Filogic 380 (14c3:7927, mt7925e).  Both are 2x2 EHT parts.

set -u
set -f
umask 077
LC_ALL=C
export LC_ALL

PROG=${0##*/}

# Shared no-client record: a skip for missing hardware writes a structured
# result.json (scripts/wireless/lib/no-client.sh) instead of a bare SKIP.
NO_CLIENT_LIB=$(dirname "$0")/lib/no-client.sh
# shellcheck source=lib/no-client.sh
[ -r "$NO_CLIENT_LIB" ] && . "$NO_CLIENT_LIB"
if ! command -v nc_cause_exit >/dev/null 2>&1; then
	nc_cause_exit() {
		case ${1:-} in
		missing-hardware) printf '3\n' ;;
		missing-tool | config-block | permission | environment | output-collision)
			printf '2\n' ;;
		precondition-mismatch) printf '4\n' ;;
		interrupted) printf '130\n' ;;
		*) printf '1\n' ;;
		esac
	}
fi
SCHEMA_ID=6g320-matrix/v1

IFACE=
CLIENT_SSH=
CLIENT_MAC=
CLIENT_MODEL=
CLIENT_DRIVER=
CLIENT_FIRMWARE=
COUNTRY=
AP_ADDR=
DURATION=10
OMIT=2
OMIT_SET=0
STREAMS=2
PORT=5201
EXPECTED_NSS=2
TARGET_GBIT=2.5
RAW_DIR=
DRY_RUN=0
CHECK_ROWS=
RESULT_JSON=
SEL_W=
PLAN_REASON=

SERVER_PID=
WATCH_PID=
WATCH_SLEEP_PIDFILE=
SERVER_ERR=
SSH_BIN=

# Snapshot state from load_station.
S_SIG=
S_TXW=
S_TXN=
S_RXW=
S_RXN=
S_RETR=
S_FAIL=
S_CONN=

# Arm results, filled by finish_arm.
R1_STATUS=
R1_GBIT=
R1_RETRIES=
R1_WIDTH=
R1_NSS=
R1_SIG=
R1_JSON=
R2_STATUS=
R2_GBIT=
R2_RETRIES=
R2_WIDTH=
R2_NSS=
R2_SIG=
R2_JSON=

I_WIDTH=
I_NSS=
I_TXW=
I_TXN=
I_RXW=
I_RXN=
I_SIG=
CLIENT_IPERF_VERSION=
WARNINGS=

usage() {
	cat <<'EOF'
Usage: 6g320-matrix.sh [options]

Run the fixed 6 GHz 320 MHz AP->STA and STA->AP iperf3 arms for one
associated client and print a JSONL row plus a summary table.

The AP needs iw, iperf3 and ssh (or dbclient); ip is needed only when
--ap-addr is not supplied.  The client needs iperf3 and non-interactive
SSH access; the client must reach the AP over the 6 GHz link, not over
Ethernet.  Both firewalls must allow the iperf3 port between AP and
client.

Hardware gate: when no 6 GHz 320 MHz AP BSS or no station with a
320 MHz rate width in either direction is found, the script prints
"SKIP: no 320 client" on stdout and exits 3 (missing-hardware); missing
required tools (iw) or an OWE configuration mismatch exit 2.

Required inputs for a real run, once a 320 MHz client is found:
  --client-ssh USER@HOST   SSH target for the client (key auth, no prompt)
  --client-mac MAC         station to test; optional when exactly one
                           320 MHz station is associated
  --client-model STR       e.g. "Intel Wi-Fi 7 BE200"
  --client-driver STR      e.g. iwlwifi, mt7925e
  --client-firmware STR    exact firmware version/revision

Options:
  --iface NAME             restrict discovery to one AP interface
  --country CC             record this regulatory country instead of
                           reading it from "iw reg get"
  --ap-addr ADDR           AP address the client connects to; by default
                           the IPv4 address on the 6 GHz BSS or br-lan
  --duration SEC           iperf3 seconds per arm (default 10)
  --omit SEC               skip the first SEC seconds (default 2;
                           0 disables omission; when set explicitly it
                           must be < --duration)
  --streams N              iperf3 streams per arm (default 2)
  --port N                 iperf3 server port (default 5201)
  --expected-nss N         smallest valid NSS (default 2)
  --target-gbit-s G        AP->STA target in Gbit/s (default 2.5)
  --raw-dir DIR            keep raw logs there (default
                           /tmp/6g320-matrix.PID); never deleted
  --dry-run                print the plan and exit 0; no iw, ssh or
                           iperf3 command is run and no file is created
  -h, --help               this text

Arm 1 (local-source, AP->STA):
  iperf3 -s -1 -p PORT on the AP, then over SSH:
  iperf3 -c AP -p PORT -t D -O O -P S -i 0 -R -J
Arm 2 (fixed RX, STA->AP):
  iperf3 -s -1 -p PORT on the AP, then over SSH:
  iperf3 -c AP -p PORT -t D -O O -P S -i 0 -J

An arm is invalid when the direction under test (AP tx for AP->STA, AP
rx for STA->AP) is not 320 MHz or has an NSS below --expected-nss, when
the station re-associated during the arm, or when it disappeared.
A measured but invalid throughput stays in arms.*.gbit_s and is not
copied to ap_to_sta_gbit_s / sta_to_ap_gbit_s.  Exit 1 if any arm is not
ok.

Output:
  stdout   JSONL rows, schema 6g320-matrix/v1 (one object per run);
           on a skip, the single line "SKIP: no 320 client"; with
           --dry-run, the plan
  stderr   progress, warnings and the summary table
  --raw-dir keeps raw iperf3 JSON, stderr and server logs

Result schema: scripts/wireless/6g320-matrix.schema.json.
No UCI, module or firmware change is made.

Examples:
  sh scripts/wireless/6g320-matrix.sh --dry-run
  sh scripts/wireless/6g320-matrix.sh \
      --client-ssh root@192.168.1.50 \
      --client-mac 3c:58:c2:11:22:33 \
      --client-model "Intel Wi-Fi 7 BE200" \
      --client-driver iwlwifi \
      --client-firmware "iwlwifi-BE200-b0-..." \
      --duration 30 --streams 2
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

say() {
	printf '%s: %s\n' "$PROG" "$*" >&2
}

add_warning() {
	if [ -n "$WARNINGS" ]; then
		WARNINGS="$WARNINGS
$*"
	else
		WARNINGS=$*
	fi
}

now_ts() {
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || _ts=
	case $_ts in
	????-??-??T??:??:??Z) printf '%s' "$_ts" ;;
	*) printf '1970-01-01T00:00:00Z' ;;
	esac
}

one_line() {
	printf '%s' "$1" | tr '\n\r\t' '   '
}

json_escape() {
	printf '%s' "$1" | tr '\n\r\t' '   ' |
		sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]/ /g'
}

json_string() {
	printf '"%s"' "$(json_escape "$1")"
}

json_string_or_null() {
	case $1 in
	'') printf 'null' ;;
	*) json_string "$1" ;;
	esac
}

json_number_or_null() {
	case $1 in
	''|null) printf 'null' ;;
	*) printf '%s' "$1" ;;
	esac
}

json_int_or_null() {
	case $1 in
	''|null) printf 'null' ;;
	*[!0-9]*) printf 'null' ;;
	*) printf '%s' "$1" ;;
	esac
}

json_signed_int_or_null() {
	case $1 in
	''|null) printf 'null' ;;
	-[0-9]*) printf '%s' "$1" ;;
	[0-9]*) printf '%s' "$1" ;;
	*) printf 'null' ;;
	esac
}

gbit() {
	awk -v b="$1" 'BEGIN { printf "%.3f", b / 1000000000.0 }'
}

first_line() {
	[ -r "$1" ] || return 0
	sed -n '1p' "$1" 2>/dev/null | cut -c1-160
}

clip() {
	printf '%s' "$1" | cut -c1-200
}

require_uint() {
	# require_uint <option> <value> <minimum> [maximum]
	case $2 in
	''|*[!0-9]*)
		usage_error "$1 must be a non-negative integer, got '$2'"
		;;
	esac
	case $2 in
	0) ;;
	0*) usage_error "$1 must not have leading zeros" ;;
	esac
	if [ "$2" -lt "$3" ]; then
		usage_error "$1 must be at least $3"
	fi
	if [ $# -ge 4 ] && [ "$2" -gt "$4" ]; then
		usage_error "$1 must be at most $4"
	fi
}

require_positive_number() {
	case $1 in
	''|.|*[!0-9.]*|*.*.*)
		usage_error "target must be a positive number, got '$1'"
		;;
	esac
	case $1 in
	.*|*.)
		usage_error "target must be a positive number, got '$1'"
		;;
	esac
	awk -v v="$1" 'BEGIN { exit !(v > 0) }' ||
		usage_error "target must be greater than zero"
}

normalize_mac() {
	case $1 in
	[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
		printf '%s' "$1" | tr 'A-F' 'a-f'
		;;
	*)
		usage_error "--client-mac must be xx:xx:xx:xx:xx:xx"
		;;
	esac
}

normalize_country() {
	_cc=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
	case $_cc in
	??) ;;
	*) usage_error "--country must be a two-character code" ;;
	esac
	case $_cc in
	*[!A-Z0-9]*) usage_error "--country must be a two-character code" ;;
	esac
	printf '%s' "$_cc"
}

safe_chars() {
	# safe_chars <value> <characters allowed>
	[ -z "$(printf '%s' "$1" | tr -d "$2")" ]
}

# shellcheck disable=SC2329  # invoked by the EXIT/INT/TERM traps
cleanup() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || :
		wait "$SERVER_PID" 2>/dev/null || :
		SERVER_PID=
	fi
	if command -v stop_watch >/dev/null 2>&1; then
		stop_watch
	elif [ -n "$WATCH_PID" ]; then
		kill "$WATCH_PID" 2>/dev/null || :
		wait "$WATCH_PID" 2>/dev/null || :
		WATCH_PID=
	fi
}

trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --------------------------------------------------------------------------
# iperf3 JSON helpers.  The device does not depend on jq or python; iperf3's
# pretty-printed JSON is read with awk.  Only the end.sum_sent and
# end.sum_received blocks are used, so per-interval sums cannot be mistaken
# for the total.
# --------------------------------------------------------------------------

iperf_summary() {
	awk '
	BEGIN {
		cur = ""
		sbps = "null"; sbytes = "null"; ssecs = "null"; sretr = "null"
		rbps = "null"; rbytes = "null"; rsecs = "null"; rretr = "null"
	}
	{
		line = $0
		sub(/^[[:space:]]+/, "", line)
		if (index(line, "\"sum_sent\":") == 1) { cur = "s"; next }
		if (index(line, "\"sum_received\":") == 1) { cur = "r"; next }
		if (cur != "" && (line == "}," || line == "}")) { cur = ""; next }
		if (cur == "") next
		sub(/,$/, "", line)
		if (index(line, "\"bits_per_second\":") == 1) {
			v = line
			sub(/^"bits_per_second":[[:space:]]*/, "", v)
			if (cur == "s") sbps = v; else rbps = v
		} else if (index(line, "\"bytes\":") == 1) {
			v = line
			sub(/^"bytes":[[:space:]]*/, "", v)
			if (cur == "s") sbytes = v; else rbytes = v
		} else if (index(line, "\"seconds\":") == 1) {
			v = line
			sub(/^"seconds":[[:space:]]*/, "", v)
			if (cur == "s") ssecs = v; else rsecs = v
		} else if (index(line, "\"retransmits\":") == 1) {
			v = line
			sub(/^"retransmits":[[:space:]]*/, "", v)
			if (cur == "s") sretr = v; else rretr = v
		}
	}
	END {
		printf "%s %s %s %s %s %s %s %s\n", \
			sbps, sbytes, ssecs, sretr, rbps, rbytes, rsecs, rretr
	}
	' "$1"
}

iperf_error() {
	awk '
	{
		line = $0
		sub(/^[[:space:]]+/, "", line)
		if (index(line, "\"error\":") == 1) {
			v = line
			sub(/^"error":[[:space:]]*"/, "", v)
			sub(/"$/, "", v)
			print v
			exit
		}
	}
	' "$1"
}

# --------------------------------------------------------------------------
# AP and station discovery.
# --------------------------------------------------------------------------

iface_info_type() {
	printf '%s\n' "$1" | sed -n 's/^[[:space:]]*type \(.*\)$/\1/p' | head -1
}

iface_info_channel() {
	# prints "channel|frequency|width|center1"; one line, numeric fields.
	printf '%s\n' "$1" | awk '
	/^[[:space:]]*channel / {
		ch = ""; freq = ""; width = ""; center = ""
		for (i = 1; i <= NF; i++) {
			if ($i == "channel") ch = $(i + 1)
			else if (substr($i, 1, 1) == "(") {
				freq = substr($i, 2)
				sub(/[^0-9].*/, "", freq)
			} else if ($i == "width:") width = $(i + 1)
			else if ($i == "center1:") center = $(i + 1)
		}
		printf "%s|%s|%s|%s\n", ch, freq, width, center
	}
	'
}

iface_ssid() {
	iw dev "$1" info 2>/dev/null |
		sed -n 's/^[[:space:]]*ssid \(.*\)$/\1/p' | head -1
}

# --------------------------------------------------------------------------
# Channel plan validity.  A row is only a legal 6 GHz block when the whole
# width fits inside the band, not merely when its centre frequency is inside
# it: a 320 MHz block centred on 7115 MHz reaches 7275 MHz, past the 7125 MHz
# upper edge.  Before this check the discovery range alone accepted
# ch233/7115 MHz/320 MHz and the row was printed as ok.
#
# 5945 MHz is the lower edge of the 6 GHz band (the first 20 MHz channel,
# ch1, is centred on 5955 MHz); 7125 MHz is the upper edge.
CH_BAND_LO=5945
CH_BAND_HI=7125

# 320 MHz blocks are not free-running in 6 GHz.  hostapd derives
# eht_oper_centr_freq_seg0_idx from the primary channel with the table in
# package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/hostapd.uc
# (eht_center_seg0_map, the 6 GHz branch of the EHT320 case):
#
#	primary channel <=  61 -> centre index  31
#	primary channel <= 125 -> centre index  95
#	primary channel <= 189 -> centre index 159
#	primary channel <= 221 -> centre index 191
#
# The index is a 5 MHz step from 5950 MHz, so those four centres are
# 6105/6425/6745/6905 MHz, and a primary channel above 221 has no 320 MHz
# block at all (the loop falls through and leaves the 160 MHz value in
# place).  A 320 MHz row whose center1 is not the centre this table picks
# for its primary channel is not a block this tree can bring up.  Widths
# below 320 MHz are not tied to the table.
EHT320_PRIMARY_MAX_CH=221
EHT320_CH_BASE_MHZ=5950
EHT320_CH_STEP_MHZ=5

# eht320_centre_mhz PRIMARY_CH: the 320 MHz block centre the table above
# picks for a primary channel, or nothing (status 1) when that channel has
# no 320 MHz block.
eht320_centre_mhz() {
	case ${1-} in
	'' | *[!0-9]*) return 1 ;;
	esac
	if [ "$1" -le 61 ]; then
		echo 6105
	elif [ "$1" -le 125 ]; then
		echo 6425
	elif [ "$1" -le 189 ]; then
		echo 6745
	elif [ "$1" -le "$EHT320_PRIMARY_MAX_CH" ]; then
		echo 6905
	else
		return 1
	fi
}

# channel_block_reason CENTRE WIDTH [CENTER1 [CENTER2]]
#
# Prints the reason the block is not a legal 6 GHz channel block, one line,
# or nothing when it is legal.  CENTRE is the centre frequency of the block
# (channel1 of a 320 MHz block, i.e. center1, when the caller knows it; the
# primary channel frequency otherwise).  Every frequency that is given must
# lie inside the band, and the block extent CENTRE +/- WIDTH/2 must lie
# inside the band as well.  A 320 MHz block is additionally checked against
# the EHT320 table above: band geometry alone accepts a centre no hostapd in
# this tree would configure.
channel_block_reason() {
	_cbr_centre=$1
	_cbr_width=$2
	_cbr_c1=${3:-}
	_cbr_c2=${4:-}

	case $_cbr_width in
	'' | *[!0-9]*) printf 'width missing or not an integer' ; return 0 ;;
	esac
	case $_cbr_width in
	20 | 40 | 80 | 160 | 320) ;;
	*) printf 'width %s MHz is not a 6 GHz channel width' "$_cbr_width" ; return 0 ;;
	esac
	case $_cbr_centre in
	'' | *[!0-9]*) printf 'centre frequency missing or not an integer' ; return 0 ;;
	esac
	_cbr_half=$((_cbr_width / 2))
	for _cbr_f in "$_cbr_centre" "$_cbr_c1" "$_cbr_c2"; do
		[ -n "$_cbr_f" ] || continue
		case $_cbr_f in
		*[!0-9]*) printf '%s is not an integer frequency' "$_cbr_f" ; return 0 ;;
		esac
		if [ "$_cbr_f" -lt "$CH_BAND_LO" ] || [ "$_cbr_f" -gt "$CH_BAND_HI" ]; then
			printf '%s MHz is outside the 6 GHz band (%s-%s MHz)' \
				"$_cbr_f" "$CH_BAND_LO" "$CH_BAND_HI"
			return 0
		fi
	done
	if [ $((_cbr_centre - _cbr_half)) -lt "$CH_BAND_LO" ]; then
		printf '%s MHz - %s MHz = %s MHz is below the 6 GHz band edge %s MHz' \
			"$_cbr_centre" "$_cbr_half" "$((_cbr_centre - _cbr_half))" "$CH_BAND_LO"
		return 0
	fi
	if [ $((_cbr_centre + _cbr_half)) -gt "$CH_BAND_HI" ]; then
		printf '%s MHz + %s MHz = %s MHz is above the 6 GHz band edge %s MHz' \
			"$_cbr_centre" "$_cbr_half" "$((_cbr_centre + _cbr_half))" "$CH_BAND_HI"
		return 0
	fi
	if [ "$_cbr_width" -eq 320 ]; then
		if [ -z "$_cbr_c1" ] || [ "$_cbr_centre" = "$_cbr_c1" ]; then
			printf '320 MHz row gives only one of center1 and the primary channel; the block cannot be checked against the EHT320 table'
			return 0
		fi
		_cbr_ch=$(((_cbr_c1 - EHT320_CH_BASE_MHZ) / EHT320_CH_STEP_MHZ))
		if [ "$_cbr_ch" -lt 1 ] || [ "$_cbr_ch" -gt 233 ] ||
			[ $((EHT320_CH_BASE_MHZ + _cbr_ch * EHT320_CH_STEP_MHZ)) -ne "$_cbr_c1" ]; then
			printf 'primary %s MHz is not on the 6 GHz channel raster (%s + %s*n MHz)' \
				"$_cbr_c1" "$EHT320_CH_BASE_MHZ" "$EHT320_CH_STEP_MHZ"
			return 0
		fi
		_cbr_want=$(eht320_centre_mhz "$_cbr_ch")
		if [ -z "$_cbr_want" ]; then
			printf 'primary channel %s (%s MHz) has no 320 MHz block: the EHT320 table stops at channel %s' \
				"$_cbr_ch" "$_cbr_c1" "$EHT320_PRIMARY_MAX_CH"
			return 0
		fi
		if [ "$_cbr_want" != "$_cbr_centre" ]; then
			printf 'center1 %s MHz does not match the EHT320 table: primary channel %s (%s MHz) takes centre %s MHz, %s MHz off' \
				"$_cbr_centre" "$_cbr_ch" "$_cbr_c1" "$_cbr_want" \
				"$((_cbr_centre - _cbr_want))"
			return 0
		fi
	fi
	return 0
}

# row_num LINE KEY...: the first integer value of any of KEY in one flat
# JSON object.  The plan rows handed to --check-rows are flat and one object
# per line, and the device has no jq, so sed is enough.
row_num() {
	_rn_line=$1
	shift
	for _rn_key in "$@"; do
		_rn_v=$(printf '%s\n' "$_rn_line" |
			sed -n "s/.*\"$_rn_key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p")
		if [ -n "$_rn_v" ]; then
			printf '%s' "$_rn_v"
			return 0
		fi
	done
	return 0
}

# check_rows SOURCE: validate a plan file ("-" for stdin) and print one
# JSONL verdict per row on stdout.  Exits 0 when every row is a legal 6 GHz
# block, 1 when at least one row is not.  --result-json writes a summary
# with invalid_rows, so a caller can gate on a file instead of on stdout.
check_rows() {
	_cr_input=$1
	_cr_n=0
	_cr_bad=0
	_cr_first=1
	_cr_invalid_json=
	if [ "$_cr_input" = - ]; then
		_cr_input=/dev/stdin
	elif [ ! -r "$_cr_input" ]; then
		usage_error "cannot read --check-rows file $1"
	fi
	while IFS= read -r _cr_row; do
		[ -n "$_cr_row" ] || continue
		_cr_n=$((_cr_n + 1))
		_cr_ch=$(row_num "$_cr_row" channel ch)
		_cr_freq=$(row_num "$_cr_row" center_freq freq_mhz freq)
		_cr_w=$(row_num "$_cr_row" width width_mhz)
		_cr_c1=$(row_num "$_cr_row" center1 center1_mhz)
		_cr_c2=$(row_num "$_cr_row" center2 center2_mhz)
		# The block is centred on center1 when the row names it, and on
		# the primary frequency otherwise.
		if [ -z "${_cr_c1:-}" ] && [ -z "${_cr_freq:-}" ]; then
			_cr_reason='row has no centre frequency'
		else
			_cr_reason=$(channel_block_reason "${_cr_c1:-${_cr_freq:-}}" \
				"${_cr_w:-}" "${_cr_freq:-}" "${_cr_c2:-}")
		fi
		if [ -n "$_cr_reason" ]; then
			_cr_bad=$((_cr_bad + 1))
			_cr_status=invalid
			printf 'INVALID: row %s ch%s center %s MHz width %s MHz: %s\n' \
				"$_cr_n" "${_cr_ch:-?}" "${_cr_c1:-${_cr_freq:-?}}" \
				"${_cr_w:-?}" "$_cr_reason" >&2
		else
			_cr_status=ok
		fi
		printf '{"row":%s,"channel":%s,"center_freq":%s,"width":%s,"center1":%s,"center2":%s,"status":"%s","invalid_reason":%s}\n' \
			"$_cr_n" "$(json_number_or_null "${_cr_ch:-}")" \
			"$(json_number_or_null "${_cr_freq:-}")" \
			"$(json_number_or_null "${_cr_w:-}")" \
			"$(json_number_or_null "${_cr_c1:-}")" \
			"$(json_number_or_null "${_cr_c2:-}")" \
			"$_cr_status" "$(json_string_or_null "$_cr_reason")"
		if [ -n "$_cr_reason" ]; then
			if [ "$_cr_first" = 1 ]; then
				_cr_first=0
			else
				_cr_invalid_json="$_cr_invalid_json,"
			fi
			_cr_invalid_json="$_cr_invalid_json{\"row\":$_cr_n,\"channel\":$(json_number_or_null "${_cr_ch:-}"),\"center1\":$(json_number_or_null "${_cr_c1:-}"),\"width\":$(json_number_or_null "${_cr_w:-}"),\"invalid_reason\":$(json_string_or_null "$_cr_reason")}"
		fi
	done <"$_cr_input"

	if [ -n "$RESULT_JSON" ]; then
		case $RESULT_JSON in
		-*) usage_error "--result-json must not start with '-'" ;;
		esac
		_cr_ok=false
		[ "$_cr_bad" -eq 0 ] && _cr_ok=true
		{
			printf '{\n'
			printf '  "schema": "6g320-matrix/check/v1",\n'
			printf '  "checked_rows": %s,\n' "$_cr_n"
			printf '  "invalid_rows": %s,\n' "$_cr_bad"
			printf '  "ok": %s,\n' "$_cr_ok"
			printf '  "invalid": [%s]\n' "$_cr_invalid_json"
			printf '}\n'
		} >"$RESULT_JSON.tmp" 2>/dev/null &&
			mv "$RESULT_JSON.tmp" "$RESULT_JSON" 2>/dev/null ||
			die "cannot write $RESULT_JSON"
	fi
	say "$_cr_n row(s) checked, $_cr_bad invalid"
	[ "$_cr_bad" -eq 0 ] || exit 1
	exit 0
}

discover_candidates() {
	# prints "iface|channel|frequency|width|center1" for every AP BSS on
	# 5945-7125 MHz with width 320.
	_ifaces=$(iw dev 2>/dev/null | sed -n 's/^[[:space:]]*Interface //p')
	[ -n "$_ifaces" ] || return 0
	for _if in $_ifaces; do
		safe_chars "$_if" 'A-Za-z0-9._-' || continue
		_info=$(iw dev "$_if" info 2>/dev/null) || continue
		_type=$(iface_info_type "$_info")
		case $_type in
		AP*) ;;
		*) continue ;;
		esac
		_chan=$(iface_info_channel "$_info")
		[ -n "$_chan" ] || continue
		_ch=
		_freq=
		_width=
		_center=
		IFS='|' read -r _ch _freq _width _center <<EOF
$_chan
EOF
		case $_freq in
		''|*[!0-9]*) continue ;;
		esac
		[ "$_freq" -ge 5945 ] && [ "$_freq" -le 7125 ] || continue
		case $_ch in
		''|*[!0-9]*) continue ;;
		esac
		[ "$_ch" -ge 1 ] && [ "$_ch" -le 233 ] || continue
		[ "$_width" = 320 ] || continue
		case $_center in
		''|*[!0-9]*) _center= ;;
		esac
		# centre1 is the centre of the 320 MHz block; without it the
		# primary frequency is the best available anchor.
		[ -z "$(channel_block_reason "${_center:-$_freq}" "$_width" "$_freq" "$_center")" ] ||
			continue
		printf '%s|%s|%s|%s|%s\n' \
			"$_if" "$_ch" "$_freq" "$_width" "$_center"
	done
}

parse_station_dump() {
	awk '
	function flush() {
		if (mac == "") return
		_sig = (sigavg != "") ? sigavg : sig
		printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", \
			mac, _sig, txw, txn, rxw, rxn, txrate, rxrate, retr, fail, conn
	}
	function parse_rate(line, dir,   n, a, i, w, ns) {
		sub(/^[[:space:]]+/, "", line)
		n = split(line, a, /[[:space:]]+/)
		w = ""; ns = ""
		for (i = 4; i <= n; i++) {
			if (a[i] ~ /^[0-9]+MHz$/) {
				w = a[i]
				sub(/MHz$/, "", w)
			} else if (a[i] ~ /NSS$/) {
				ns = a[i + 1]
			}
		}
		if (dir == "tx") { txw = w; txn = ns; txrate = a[3] }
		else { rxw = w; rxn = ns; rxrate = a[3] }
	}
	/^Station / {
		flush()
		mac = tolower($2)
		sig = ""; sigavg = ""
		txw = ""; txn = ""; rxw = ""; rxn = ""
		txrate = ""; rxrate = ""
		retr = ""; fail = ""; conn = ""
		next
	}
	/^[[:space:]]*signal avg:/ { sigavg = $3; next }
	/^[[:space:]]*signal:/ { sig = $2; next }
	/^[[:space:]]*tx bitrate:/ { parse_rate($0, "tx"); next }
	/^[[:space:]]*rx bitrate:/ { parse_rate($0, "rx"); next }
	/^[[:space:]]*tx retries:/ { retr = $3; next }
	/^[[:space:]]*tx failed:/ { fail = $3; next }
	/^[[:space:]]*connected time:/ { conn = $3; next }
	END { flush() }
	'
}

station_rows() {
	iw dev "$1" station dump 2>/dev/null | parse_station_dump
}

read_station() {
	# read_station <iface> <mac>: one parsed row or nothing.
	station_rows "$1" | awk -F'|' -v mac="$2" '$1 == mac { print; exit }'
}

snapshot_station() {
	# snapshot_station <iface> <mac> <outfile>; retries once after 1 s.
	_out=$3
	_i=0
	while [ "$_i" -lt 2 ]; do
		_row=$(read_station "$1" "$2")
		if [ -n "$_row" ]; then
			printf '%s\n' "$_row" >"$_out"
			return 0
		fi
		_i=$((_i + 1))
		if [ "$_i" -lt 2 ]; then
			sleep 1
		fi
	done
	: >"$_out"
	return 1
}

load_station() {
	S_SIG=
	S_TXW=
	S_TXN=
	S_RXW=
	S_RXN=
	S_RETR=
	S_FAIL=
	S_CONN=
	[ -s "$1" ] || return 1
	IFS='|' read -r _s_mac S_SIG S_TXW S_TXN S_RXW S_RXN \
		_s_txrate _s_rxrate S_RETR S_FAIL S_CONN <"$1"
	return 0
}

eff_width() {
	# Minimum of the tx and rx widths, or the one that is present.
	_w=
	case $1 in
	''|*[!0-9]*) ;;
	*) _w=$1 ;;
	esac
	case $2 in
	''|*[!0-9]*) ;;
	*)
		if [ -z "$_w" ] || [ "$2" -lt "$_w" ]; then
			_w=$2
		fi
		;;
	esac
	printf '%s' "$_w"
}

eff_nss() {
	_n=
	case $1 in
	''|*[!0-9]*) ;;
	*) _n=$1 ;;
	esac
	case $2 in
	''|*[!0-9]*) ;;
	*)
		if [ -z "$_n" ] || [ "$2" -lt "$_n" ]; then
			_n=$2
		fi
		;;
	esac
	printf '%s' "$_n"
}

dir_width() {
	# dir_width <reverse 1/0> <tx width> <rx width>
	# AP->STA exercises the AP's tx rate; STA->AP exercises the AP's rx rate.
	if [ "$1" = 1 ]; then
		printf '%s' "$2"
	else
		printf '%s' "$3"
	fi
}

dir_nss() {
	# dir_nss <reverse 1/0> <tx nss> <rx nss>
	if [ "$1" = 1 ]; then
		printf '%s' "$2"
	else
		printf '%s' "$3"
	fi
}

arm_min() {
	# arm_min <status1> <width-or-nss1> <status2> <width-or-nss2>
	# Error arms do not contribute; invalid arms do, because a downgrade
	# must stay visible in the consolidated association fields.
	_m=
	if [ "$1" != error ]; then
		_m=$2
	fi
	if [ "$3" != error ]; then
		case $4 in
		''|*[!0-9]*) ;;
		*)
			if [ -z "$_m" ] || [ "$4" -lt "$_m" ]; then
				_m=$4
			fi
			;;
		esac
	fi
	printf '%s' "$_m"
}


detect_ap_addr() {
	# Prefer an address on the 6 GHz BSS itself, then br-lan.
	for _dev in "$IFACE" br-lan; do
		[ -n "$_dev" ] || continue
		_addr=$(ip -4 addr show dev "$_dev" 2>/dev/null |
			awk '$1 == "inet" { sub(/\/.*/, "", $2); print $2; exit }')
		if [ -n "$_addr" ]; then
			printf '%s' "$_addr"
			return 0
		fi
	done
	return 1
}

detect_country() {
	# Prefer the regulatory country of this interface's wiphy over another
	# radio's country.  iw reg get prints a global block followed by
	# "phy#N" blocks; "iw dev IFACE info" gives the wiphy number.
	_wiphy=$(iw dev "$IFACE" info 2>/dev/null |
		sed -n 's/^[[:space:]]*wiphy //p' | head -1)
	iw reg get 2>/dev/null | awk -v want="phy#${_wiphy}" '
	/^phy#/ {
		seen_phy = 1
		inphy = (want != "phy#" && index($0, want) == 1)
		next
	}
	/^country [A-Z0-9][A-Z0-9]:/ {
		c = substr($2, 1, 2)
		if (inphy) {
			print c
			found = 1
			exit
		}
		if (!seen_phy && global == "") global = c
	}
	END {
		if (!found) print (global == "" ? "00" : global)
	}
	'
}

detect_ap_model() {
	for _f in /tmp/sysinfo/model /proc/device-tree/model; do
		[ -r "$_f" ] || continue
		_m=$(tr -d '\000' <"$_f" | sed -n '1p')
		[ -n "$_m" ] || continue
		printf '%s' "$_m"
		return 0
	done
	printf 'unknown'
}

# --------------------------------------------------------------------------
# Client selection.  A station with a 320 MHz rate in either direction on a
# 6 GHz 320 MHz AP BSS is the hardware gate.  Nothing is written before it
# passes.
# --------------------------------------------------------------------------

select_client() {
	_found=
	_seen=0
	while IFS='|' read -r _c_if _c_ch _c_freq _c_width _c_center; do
		[ -n "$_c_if" ] || continue
		_rows=$(station_rows "$_c_if")
		while IFS='|' read -r _m _sig _txw _txn _rxw _rxn \
			_txr _rxr _retr _fail _conn; do
			[ -n "$_m" ] || continue
			_seen=$((_seen + 1))
			_w320=0
			[ "$_txw" = 320 ] && _w320=1
			[ "$_rxw" = 320 ] && _w320=1
			# An automatic pick must negotiate 320 MHz.  An explicitly
			# named client is kept whatever its width: dropping it here
			# made every 160-only row unreachable, so a downgrade looked
			# like an absent station instead of a measured result.
			if [ "$_w320" = 0 ] && [ "$_m" != "$CLIENT_MAC" ]; then
				continue
			fi
			_w=$(eff_width "$_txw" "$_rxw")
			_n=$(eff_nss "$_txn" "$_rxn")
			if [ -n "$_found" ]; then
				_found="$_found
$_c_if|$_m|$_sig|$_w|$_n|$_c_ch|$_c_freq|$_c_center"
			else
				_found="$_c_if|$_m|$_sig|$_w|$_n|$_c_ch|$_c_freq|$_c_center"
			fi
		done <<EOF
$_rows
EOF
	done <<EOF
$CANDIDATES
EOF

	if [ -n "$CLIENT_MAC" ]; then
		_row=$(printf '%s\n' "$_found" |
			awk -F'|' -v m="$CLIENT_MAC" '$2 == m { print; exit }')
		if [ -z "$_row" ]; then
			say "client $CLIENT_MAC is not associated at 320 MHz on a 6 GHz 320 MHz BSS"
			if [ "$_seen" -gt 0 ]; then
				say "there are $_seen station(s) on the 6 GHz BSS, but none at 320 MHz"
			fi
			skip_no_client
		fi
	else
		_macs=$(printf '%s\n' "$_found" |
			awk -F'|' 'NF && !seen[$2]++ { print $2 }')
		_count=$(printf '%s\n' "$_macs" |
			awk 'NF { n++ } END { print n + 0 }')
		case $_count in
		0)
			if [ "$_seen" -eq 0 ]; then
				say "no station is associated to the 6 GHz 320 MHz BSS"
			else
				say "there are $_seen station(s) on the 6 GHz BSS, but none at 320 MHz"
			fi
			skip_no_client
			;;
		1) ;;
		*)
			_macs_csv=$(printf '%s\n' "$_macs" |
				awk 'NF { printf "%s%s", sep, $0; sep = ", " }')
			usage_error "multiple 320 MHz clients are associated ($_macs_csv); pass --client-mac"
			;;
		esac
		CLIENT_MAC=$_macs
		_row=$(printf '%s\n' "$_found" |
			awk -F'|' -v m="$CLIENT_MAC" '$2 == m { print; exit }')
	fi

	IFACE=
	CLIENT_MAC=
	_sig=
	_w=
	_n=
	_ch=
	_freq=
	_center=
	IFS='|' read -r IFACE CLIENT_MAC _sig _w _n _ch _freq _center <<EOF
$_row
EOF

	AP_CHANNEL=$_ch
	AP_FREQ=$_freq
	AP_CENTER=$_center
	# The width the client had at selection time.  The later pre-arm gate
	# compares against this instead of against a bare "must be 320 MHz": an
	# explicitly named 160-only client was selected on purpose, so it is
	# measured rather than skipped, while a client that was at 320 MHz and
	# dropped must still stop the run.
	SEL_W=$_w
	# The AP's own block must be a legal 6 GHz block; when it is not, every
	# arm of this row is invalid whatever the throughput says.
	PLAN_REASON=$(channel_block_reason "${AP_CENTER:-$AP_FREQ}" 320 "$AP_FREQ" "$AP_CENTER")
	# The client's own rate width can be below the AP's 320 MHz.  Say it:
	# the row then measures a narrower channel than its title claims.
	case $_w in
	''|*[!0-9]*) ;;
	*) [ "$_w" -lt 320 ] &&
		add_warning "client $CLIENT_MAC negotiated ${_w} MHz, not 320 MHz" ;;
	esac
	# Every candidate is a 320 MHz BSS; this is the AP width, not the
	# client's direction-specific rate width.
	AP_WIDTH=320
}

# record_dir LABEL: where a record goes when --result-json was not given.
# An explicit --result-json still decides its own directory, as before.  With
# no --result-json the old fallback was `dirname /tmp/x` = /tmp, so every run
# wrote the same /tmp/result.json: two matrix runs overwrote each other's
# record and hw-gap-report.sh, which scans /tmp, picked up whoever else's
# record happened to be there.  Each run now gets its own directory under /tmp
# (no_client_default_dir), and LABEL keeps the blocked and no-client records
# of one run apart even though they are mutually exclusive branches.
record_dir() {
	if [ -n "$RESULT_JSON" ]; then
		dirname "$RESULT_JSON"
		return 0
	fi
	if command -v no_client_default_dir >/dev/null 2>&1; then
		_rd_dir=$(no_client_default_dir "$PROG")/${1:-record}
	else
		_rd_dir=${TMPDIR:-/tmp}/${PROG%.sh}-no-client.$$/${1:-record}
	fi
	mkdir -p "$_rd_dir" 2>/dev/null || :
	printf '%s\n' "$_rd_dir"
}

skip_no_tool() {
	_nt_tool=${1:-iw}
	_nt_reason=${2:-$_nt_tool is not installed}
	_nc_run='sh scripts/wireless/6g320-matrix.sh --iface <6GHZ_320_AP_IFACE> --client-ssh <ROOT@HOST> --client-model <MODEL> --client-driver <DRIVER> --client-firmware <FIRMWARE> --result-json <DIR>/result.json'
	_rec=$(NC_RECORD_CAUSE=missing-tool \
		no_client_record "$(record_dir no-client)" 47 "$_nt_tool" \
		"$_nc_run" "$_nt_reason" \
		"per-arm TX/RX width (320 MHz) and NSS from iw station dump" \
		"per-arm throughput, retries and failed frames" \
		"width/NSS downgrade and re-association invalidation" 2>/dev/null)
	printf 'SKIP: %s\n' "$_nt_reason"
	printf '      missing %s; install it and run: %s\n' "$_nt_tool" "$_nc_run"
	[ -n "$_rec" ] && printf '      no-client record: %s\n' "$_rec"
	exit "$(nc_cause_exit missing-tool)"
}

# skip_no_client [MISSING] [REASON]: no usable 320 MHz client, so the matrix
# has nothing to measure.  The skip line stays "SKIP: no 320 client"; the two
# lines after it name the missing hardware and the command to run once it
# exists, and result.json carries the same facts for hw-gap-report.sh.
skip_no_client() {
	_nc_missing=${1:-6ghz-eht320-client}
	_nc_reason=${2:-no 320 client}
	# A 320 MHz client that cannot associate to an OWE-upgraded open 6 GHz
	# AP is a configuration block, not a missing client (#347).  Use the
	# explicitly selected interface, else the first discovered candidate.
	_owe_iface=${IFACE:-}
	if [ -z "$_owe_iface" ] && [ -n "${CANDIDATES:-}" ]; then
		_owe_iface=$(printf '%s\n' "$CANDIDATES" | awk -F'|' 'NF { print $1; exit }')
	fi
	if [ -n "$_owe_iface" ] && command -v nc_owe_mismatch >/dev/null 2>&1 &&
		_mm=$(nc_owe_mismatch "$_owe_iface"); then
		nc_owe_mismatch_block "$(record_dir blocked)" 47 "$_mm"
		exit "$(nc_cause_exit config-block)"
	fi
	_nc_run='sh scripts/wireless/6g320-matrix.sh --iface <6GHZ_320_AP_IFACE> --client-ssh <ROOT@HOST> --client-model <MODEL> --client-driver <DRIVER> --client-firmware <FIRMWARE> --result-json <DIR>/result.json'
	_rec=$(NC_RECORD_CAUSE=missing-hardware \
		no_client_record "$(record_dir no-client)" 47 "$_nc_missing" \
		"$_nc_run" "$_nc_reason" \
		"per-arm TX/RX width (320 MHz) and NSS from iw station dump" \
		"per-arm throughput, retries and failed frames" \
		"width/NSS downgrade and re-association invalidation" 2>/dev/null)
	printf 'SKIP: no 320 client\n'
	printf '      missing %s; once it is available run: %s\n' "$_nc_missing" "$_nc_run"
	[ -n "$_rec" ] && printf '      no-client record: %s\n' "$_rec"
	exit "$(nc_cause_exit missing-hardware)"
}

# --------------------------------------------------------------------------
# Arm execution.
# --------------------------------------------------------------------------

start_server() {
	# start_server <arm>: start iperf3 -s -1 on the AP and a watchdog.
	_arm=$1
	_timeout_file=$RAW_DIR/$_arm.server.timeout
	_log=$RAW_DIR/$_arm.server.log
	SERVER_ERR=
	rm -f "$_timeout_file"
	: >"$_log"
	iperf3 -s -1 -p "$PORT" >"$_log" 2>&1 &
	SERVER_PID=$!
	WATCH_SLEEP_PIDFILE=$RAW_DIR/$_arm.watch.sleep.pid
	rm -f "$WATCH_SLEEP_PIDFILE"
	(
		_sp=
		trap '[ -n "$_sp" ] && kill "$_sp" 2>/dev/null || :; exit 0' TERM INT HUP
		sleep $((DURATION + 30)) &
		_sp=$!
		printf '%s\n' "$_sp" >"$WATCH_SLEEP_PIDFILE"
		wait "$_sp" 2>/dev/null || exit 0
		if kill -0 "$SERVER_PID" 2>/dev/null; then
			kill "$SERVER_PID" 2>/dev/null
			: >"$_timeout_file"
		fi
	) &
	WATCH_PID=$!
	sleep 1
	if grep -qi 'iperf3: error' "$_log" 2>/dev/null; then
		SERVER_ERR="iperf3 server: $(first_line "$_log")"
		stop_server
		return 1
	fi
	if command -v netstat >/dev/null 2>&1; then
		_ns_out=$(netstat -ltn 2>/dev/null)
		_ns_st=$?
		if [ "$_ns_st" -eq 0 ] && [ -n "$_ns_out" ]; then
			if ! printf '%s\n' "$_ns_out" |
				grep -q "[:.]${PORT}[[:space:]]"; then
				SERVER_ERR="iperf3 server is not listening on port $PORT"
				stop_server
				return 1
			fi
		fi
	fi
	return 0
}

stop_watch() {
	if [ -n "$WATCH_PID" ]; then
		kill "$WATCH_PID" 2>/dev/null || :
	fi
	if [ -n "$WATCH_SLEEP_PIDFILE" ] && [ -r "$WATCH_SLEEP_PIDFILE" ]; then
		_sp=$(head -n 1 "$WATCH_SLEEP_PIDFILE" 2>/dev/null)
		case $_sp in
		''|*[!0-9]*) ;;
		*) kill "$_sp" 2>/dev/null || : ;;
		esac
		rm -f "$WATCH_SLEEP_PIDFILE"
	fi
	if [ -n "$WATCH_PID" ]; then
		wait "$WATCH_PID" 2>/dev/null || :
		WATCH_PID=
	fi
	WATCH_SLEEP_PIDFILE=
}

stop_server() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || :
		wait "$SERVER_PID" 2>/dev/null || :
		SERVER_PID=
	fi
	stop_watch
}

wait_server() {
	# The watchdog bounds this wait.  A successful client run makes the
	# -1 server exit on its own; a hung server is killed at DURATION+30.
	_arm=$1
	[ -n "$SERVER_PID" ] || return 0
	wait "$SERVER_PID"
	_st=$?
	SERVER_PID=
	stop_watch
	if [ -e "$RAW_DIR/$_arm.server.timeout" ]; then
		SERVER_ERR="iperf3 server timed out after the client run"
		return 1
	fi
	if [ "$_st" -ne 0 ]; then
		SERVER_ERR="iperf3 server exited $_st"
		_line=$(first_line "$RAW_DIR/$_arm.server.log")
		if [ -n "$_line" ]; then
			SERVER_ERR="$SERVER_ERR: $_line"
		fi
		return 1
	fi
	return 0
}

arm_remote_cmd() {
	_rev=$1
	_revopt=
	if [ "$_rev" = 1 ]; then
		_revopt=' -R'
	fi
	printf 'iperf3 -c %s -p %s -t %s -O %s -P %s -i 0%s -J' \
		"$AP_ADDR" "$PORT" "$DURATION" "$OMIT" "$STREAMS" "$_revopt"
}

run_client_cmd() {
	_cmd=$1
	_out=$2
	_err=$3
	if command -v timeout >/dev/null 2>&1; then
		timeout $((DURATION + 30)) "$SSH_BIN" "$CLIENT_SSH" "$_cmd" \
			>"$_out" 2>"$_err"
	else
		"$SSH_BIN" "$CLIENT_SSH" "$_cmd" >"$_out" 2>"$_err"
	fi
}

note_invalid() {
	if [ -n "$_invalid" ]; then
		_invalid="$_invalid; $*"
	else
		_invalid=$*
	fi
}

note_error() {
	if [ -n "$_error" ]; then
		_error="$_error; $*"
	else
		_error=$*
	fi
}

finish_arm() {
	_arm=$1
	if [ -n "$_error" ]; then
		_status=error
		_invalid=
	elif [ -n "$_invalid" ]; then
		_status=invalid
	else
		_status=ok
	fi
	if [ "$_status" = ok ] && [ -z "$_gbit" ]; then
		_status=error
		_error='iperf3 produced no usable throughput'
	fi
	if [ -n "$_error" ]; then
		_error=$(one_line "$_error")
	fi
	if [ -n "$_invalid" ]; then
		_invalid=$(one_line "$_invalid")
	fi
	_obj=$(printf '{"status":%s,"gbit_s":%s,"bytes":%s,"seconds":%s,"tcp_retransmits":%s,"station":{"width_mhz":%s,"nss":%s,"signal_dbm":%s,"tx_retries":%s,"tx_failed":%s},"invalid_reason":%s,"error":%s,"command":%s}' \
		"$(json_string "$_status")" \
		"$(json_number_or_null "$_gbit")" \
		"$(json_int_or_null "$_bytes")" \
		"$(json_number_or_null "$_secs")" \
		"$(json_int_or_null "$_tcp_retr")" \
		"$(json_int_or_null "$_st_width")" \
		"$(json_int_or_null "$_st_nss")" \
		"$(json_signed_int_or_null "$_st_sig")" \
		"$(json_int_or_null "$_st_retr")" \
		"$(json_int_or_null "$_st_fail")" \
		"$(json_string_or_null "$_invalid")" \
		"$(json_string_or_null "$_error")" \
		"$(json_string "$_cmd")")
	_suffix=
	[ -n "$_invalid" ] && _suffix=" ($_invalid)"
	[ -n "$_error" ] && _suffix=" ($_error)"
	case $_arm in
	ap_to_sta)
		R1_STATUS=$_status
		R1_GBIT=$_gbit
		R1_RETRIES=$_st_retr
		R1_WIDTH=$_st_width
		R1_NSS=$_st_nss
		R1_SIG=$_st_sig
		R1_JSON=$_obj
		;;
	sta_to_ap)
		R2_STATUS=$_status
		R2_GBIT=$_gbit
		R2_RETRIES=$_st_retr
		R2_WIDTH=$_st_width
		R2_NSS=$_st_nss
		R2_SIG=$_st_sig
		R2_JSON=$_obj
		;;
	esac
	say "$_arm: $_status$_suffix"
}

run_arm() {
	_arm=$1
	_rev=$2
	_before=$RAW_DIR/$_arm.before
	_after=$RAW_DIR/$_arm.after
	_json=$RAW_DIR/$_arm.client.json
	_err=$RAW_DIR/$_arm.client.err

	_status=
	_invalid=
	_error=
	_gbit=
	[ -n "$PLAN_REASON" ] &&
		note_invalid "AP channel plan is not a legal 6 GHz 320 MHz block: $PLAN_REASON"
	_bytes=
	_secs=
	_tcp_retr=
	_cmd=
	_st_width=$(dir_width "$_rev" "$I_TXW" "$I_RXW")
	_st_nss=$(dir_nss "$_rev" "$I_TXN" "$I_RXN")
	_st_sig=$I_SIG
	_st_retr=
	_st_fail=
	B_SIG=
	B_TXW=
	B_TXN=
	B_RXW=
	B_RXN=
	B_RETR=
	B_FAIL=
	B_CONN=
	E_SIG=
	E_TXW=
	E_TXN=
	E_RXW=
	E_RXN=
	E_RETR=
	E_FAIL=
	E_CONN=

	say "$_arm: snapshot before"
	if ! snapshot_station "$IFACE" "$CLIENT_MAC" "$_before"; then
		note_error "client $CLIENT_MAC is not visible before the arm"
		finish_arm "$_arm"
		return 0
	fi
	load_station "$_before" || :
	B_SIG=$S_SIG
	B_TXW=$S_TXW
	B_TXN=$S_TXN
	B_RXW=$S_RXW
	B_RXN=$S_RXN
	B_RETR=$S_RETR
	B_FAIL=$S_FAIL
	B_CONN=$S_CONN
	_pre_width=$(dir_width "$_rev" "$B_TXW" "$B_RXW")
	_pre_nss=$(dir_nss "$_rev" "$B_TXN" "$B_RXN")
	_st_width=$_pre_width
	_st_nss=$_pre_nss
	_st_sig=$B_SIG

	if [ "$_pre_width" != 320 ]; then
		note_invalid "association width ${_pre_width:-unknown} MHz at arm start, expected 320 MHz"
		finish_arm "$_arm"
		return 0
	fi
	_cmd=$(arm_remote_cmd "$_rev")
	say "$_arm: iperf3 server on AP port $PORT"
	if ! start_server "$_arm"; then
		note_error "$SERVER_ERR"
		finish_arm "$_arm"
		return 0
	fi
	say "$_arm: client iperf3 over ssh"
	run_client_cmd "$_cmd" "$_json" "$_err"
	_ssh_st=$?
	if [ "$_ssh_st" -ne 0 ]; then
		note_error "client iperf3 failed (ssh exit $_ssh_st)"
		_line=$(first_line "$_err")
		if [ -n "$_line" ]; then
			note_error "client stderr: $(clip "$_line")"
		fi
		stop_server
	else
		if ! wait_server "$_arm"; then
			note_error "$SERVER_ERR"
		fi
	fi

	say "$_arm: snapshot after"
	if snapshot_station "$IFACE" "$CLIENT_MAC" "$_after"; then
		load_station "$_after" || :
		E_SIG=$S_SIG
		E_TXW=$S_TXW
		E_TXN=$S_TXN
		E_RXW=$S_RXW
		E_RXN=$S_RXN
		E_RETR=$S_RETR
		E_FAIL=$S_FAIL
		E_CONN=$S_CONN
		_post_width=$(dir_width "$_rev" "$E_TXW" "$E_RXW")
		_post_nss=$(dir_nss "$_rev" "$E_TXN" "$E_RXN")
		_st_width=$_post_width
		_st_nss=$_post_nss
		_st_sig=$E_SIG
		if [ -n "$E_RETR" ] && [ -n "$B_RETR" ] &&
			[ "$E_RETR" -ge "$B_RETR" ]; then
			_st_retr=$((E_RETR - B_RETR))
		fi
		if [ -n "$E_FAIL" ] && [ -n "$B_FAIL" ] &&
			[ "$E_FAIL" -ge "$B_FAIL" ]; then
			_st_fail=$((E_FAIL - B_FAIL))
		fi
		if [ "$_post_width" != 320 ]; then
			note_invalid "association width ${_post_width:-unknown} MHz after the arm, expected 320 MHz"
		fi
		if [ -z "$_post_nss" ]; then
			note_invalid "association NSS unavailable after the arm, expected $EXPECTED_NSS"
		elif [ "$_post_nss" -lt "$EXPECTED_NSS" ]; then
			note_invalid "association NSS $_post_nss after the arm, expected $EXPECTED_NSS"
		fi
		if [ -n "$E_CONN" ] && [ -n "$B_CONN" ] &&
			[ "$E_CONN" -lt "$B_CONN" ]; then
			note_invalid "station re-associated during the arm"
		fi
		if [ -n "$E_RETR" ] && [ -n "$B_RETR" ] &&
			[ "$E_RETR" -lt "$B_RETR" ]; then
			note_invalid "station TX retry counter reset during the arm"
		fi
	else
		note_invalid "client not visible after the arm"
	fi

	if [ -s "$_json" ]; then
		_sbps=
		_sbytes=
		_ssecs=
		_sretr=
		_rbps=
		_rbytes=
		_rsecs=
		_rretr=
		read -r _sbps _sbytes _ssecs _sretr _rbps _rbytes _rsecs _rretr <<EOF
$(iperf_summary "$_json")
EOF
		if [ "$_rev" = 1 ]; then
			_bps=$_rbps
			_jbytes=$_rbytes
			_jsecs=$_rsecs
		else
			_bps=$_sbps
			_jbytes=$_sbytes
			_jsecs=$_ssecs
		fi
		case $_bps in
		''|null) ;;
		*) _gbit=$(gbit "$_bps") ;;
		esac
		case $_jbytes in
		''|null) ;;
		*) _bytes=$_jbytes ;;
		esac
		case $_jsecs in
		''|null) ;;
		*) _secs=$_jsecs ;;
		esac
		case $_sretr in
		''|null) ;;
		*) _tcp_retr=$_sretr ;;
		esac
		_ierr=$(iperf_error "$_json")
		if [ -n "$_ierr" ]; then
			note_error "iperf3: $(clip "$_ierr")"
		fi
		_ver=$(sed -n \
			's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
			"$_json" | head -1)
		if [ -n "$_ver" ]; then
			CLIENT_IPERF_VERSION=$(one_line "$_ver")
		fi
	else
		[ -n "$_error" ] || note_error 'client returned no iperf3 JSON'
	fi
	if [ -z "$_error" ] && [ -z "$_gbit" ]; then
		note_error 'iperf3 result has no usable throughput'
	fi
	finish_arm "$_arm"
}

# --------------------------------------------------------------------------
# Output.
# --------------------------------------------------------------------------


format_or_dash() {
	case $1 in
	'') printf '%s' '-' ;;
	*) printf '%s' "$1" ;;
	esac
}

emit_warnings_json() {
	_first=1
	while IFS= read -r _w; do
		[ -n "$_w" ] || continue
		if [ "$_first" = 1 ]; then
			_first=0
		else
			printf ','
		fi
		printf '%s' "$(json_string "$_w")"
	done <<EOF
$WARNINGS
EOF
}

emit_row() {
	_ts=$(now_ts)
	_asm_width=$(arm_min "$R1_STATUS" "$R1_WIDTH" "$R2_STATUS" "$R2_WIDTH")
	[ -n "$_asm_width" ] || _asm_width=$I_WIDTH
	_asm_nss=$(arm_min "$R1_STATUS" "$R1_NSS" "$R2_STATUS" "$R2_NSS")
	[ -n "$_asm_nss" ] || _asm_nss=$I_NSS
	_asm_sig=$I_SIG
	if [ -z "$_asm_sig" ]; then
		_asm_sig=$R1_SIG
	fi
	if [ -z "$_asm_sig" ]; then
		_asm_sig=$R2_SIG
	fi
	_ap_to_sta=
	if [ "$R1_STATUS" = ok ]; then
		_ap_to_sta=$R1_GBIT
	fi
	_sta_to_ap=
	if [ "$R2_STATUS" = ok ]; then
		_sta_to_ap=$R2_GBIT
	fi
	_retries=
	_have_retr=0
	_r1=$R1_RETRIES
	_r2=$R2_RETRIES
	[ "$R1_STATUS" = error ] && _r1=
	[ "$R2_STATUS" = error ] && _r2=
	for _r in "$_r1" "$_r2"; do
		case $_r in
		''|*[!0-9]*) continue ;;
		esac
		if [ "$_have_retr" = 0 ]; then
			_retries=$_r
			_have_retr=1
		else
			_retries=$((_retries + _r))
		fi
	done
	_target_met=false
	if [ "$R1_STATUS" = ok ] && [ -n "$_ap_to_sta" ]; then
		if awk -v g="$_ap_to_sta" -v t="$TARGET_GBIT" \
			'BEGIN { exit !(g >= t) }'; then
			_target_met=true
		fi
	fi
	_client_ver=$(json_string_or_null "$CLIENT_IPERF_VERSION")

	printf '{'
	printf '"schema":%s,' "$(json_string "$SCHEMA_ID")"
	printf '"record_type":"row",'
	printf '"timestamp":%s,' "$(json_string "$_ts")"
	printf '"ap":{"hostname":%s,"model":%s,"interface":%s,"channel":%s,"frequency_mhz":%s,"width_mhz":320,"center1_mhz":%s,"ssid":%s},' \
		"$(json_string "$AP_HOSTNAME")" \
		"$(json_string "$AP_MODEL")" \
		"$(json_string "$IFACE")" \
		"$(json_int_or_null "$AP_CHANNEL")" \
		"$(json_int_or_null "$AP_FREQ")" \
		"$(json_int_or_null "$AP_CENTER")" \
		"$(json_string "$AP_SSID")"
	printf '"client":{"mac":%s,"model":%s,"driver":%s,"firmware":%s},' \
		"$(json_string "$CLIENT_MAC")" \
		"$(json_string "$CLIENT_MODEL")" \
		"$(json_string "$CLIENT_DRIVER")" \
		"$(json_string "$CLIENT_FIRMWARE")"
	printf '"country":%s,' "$(json_string "$COUNTRY")"
	printf '"association":{"width_mhz":%s,"nss":%s,"signal_dbm":%s},' \
		"$(json_int_or_null "$_asm_width")" \
		"$(json_int_or_null "$_asm_nss")" \
		"$(json_signed_int_or_null "$_asm_sig")"
	printf '"source_path":"local",'
	printf '"ap_to_sta_gbit_s":%s,' \
		"$(json_number_or_null "$_ap_to_sta")"
	printf '"sta_to_ap_gbit_s":%s,' \
		"$(json_number_or_null "$_sta_to_ap")"
	printf '"retries":%s,' "$(json_int_or_null "$_retries")"
	printf '"target_gbit_s":%s,' "$(json_number_or_null "$TARGET_GBIT")"
	printf '"target_met":%s,' "$_target_met"
	printf '"duration_s":%s,' "$(json_int_or_null "$DURATION")"
	printf '"streams":%s,' "$(json_int_or_null "$STREAMS")"
	printf '"iperf3":{"server":%s,"client":%s},' \
		"$(json_string "$SERVER_IPERF")" "$_client_ver"
	printf '"arms":{"ap_to_sta":%s,"sta_to_ap":%s},' \
		"$R1_JSON" "$R2_JSON"
	printf '"warnings":['
	emit_warnings_json
	printf '],'
	printf '"raw_dir":%s' "$(json_string "$RAW_DIR")"
	printf '}\n'
}

print_table() {
	_asm_width=$(arm_min "$R1_STATUS" "$R1_WIDTH" "$R2_STATUS" "$R2_WIDTH")
	[ -n "$_asm_width" ] || _asm_width=$I_WIDTH
	_asm_nss=$(arm_min "$R1_STATUS" "$R1_NSS" "$R2_STATUS" "$R2_NSS")
	[ -n "$_asm_nss" ] || _asm_nss=$I_NSS
	_asm_sig=$I_SIG
	if [ -z "$_asm_sig" ]; then
		_asm_sig=$R1_SIG
	fi
	if [ -z "$_asm_sig" ]; then
		_asm_sig=$R2_SIG
	fi
	_ap_to_sta=
	if [ "$R1_STATUS" = ok ]; then
		_ap_to_sta=$R1_GBIT
	fi
	_sta_to_ap=
	if [ "$R2_STATUS" = ok ]; then
		_sta_to_ap=$R2_GBIT
	fi
	_retries=
	_have_retr=0
	_r1=$R1_RETRIES
	_r2=$R2_RETRIES
	[ "$R1_STATUS" = error ] && _r1=
	[ "$R2_STATUS" = error ] && _r2=
	for _r in "$_r1" "$_r2"; do
		case $_r in
		''|*[!0-9]*) continue ;;
		esac
		if [ "$_have_retr" = 0 ]; then
			_retries=$_r
			_have_retr=1
		else
			_retries=$((_retries + _r))
		fi
	done
	_overall=
	if [ "$R1_STATUS" = error ] || [ "$R2_STATUS" = error ]; then
		_overall=error
	elif [ "$R1_STATUS" = ok ] && [ "$R2_STATUS" = ok ]; then
		_overall=ok
	else
		_overall=invalid
	fi
	{
		printf '\n'
		printf '%-26s %-8s %-16s %-3s %-5s %-3s %-5s %-8s %-8s %-7s %-6s %s\n' \
			'CLIENT' 'DRIVER' 'FIRMWARE' 'CC' 'WIDTH' 'NSS' 'SIG' \
			'AP->STA' 'STA->AP' 'RETRIES' 'SOURCE' 'STATUS'
		printf '%-26.26s %-8.8s %-16.16s %-3.3s %-5.5s %-3.3s %-5.5s %-8.8s %-8.8s %-7.7s %-6.6s %s\n' \
			"$CLIENT_MODEL" "$CLIENT_DRIVER" "$CLIENT_FIRMWARE" \
			"$COUNTRY" "$(format_or_dash "$_asm_width")" \
			"$(format_or_dash "$_asm_nss")" \
			"$(format_or_dash "$_asm_sig")" \
			"$(format_or_dash "$_ap_to_sta")" \
			"$(format_or_dash "$_sta_to_ap")" \
			"$(format_or_dash "$_retries")" 'local' "$_overall"
		printf '\nclient mac: %s\n' "$CLIENT_MAC"
		printf 'target: %s Gbit/s AP->STA; target_met: ' "$TARGET_GBIT"
		if [ "$R1_STATUS" = ok ] && [ -n "$_ap_to_sta" ]; then
			if awk -v g="$_ap_to_sta" -v t="$TARGET_GBIT" \
				'BEGIN { exit !(g >= t) }'; then
				printf 'yes\n'
			else
				printf 'no\n'
			fi
		else
			printf 'no (AP->STA arm not valid)\n'
		fi
		printf 'raw: %s\n' "$RAW_DIR"
		if [ -n "$WARNINGS" ]; then
			printf 'warnings:\n'
			printf '%s\n' "$WARNINGS" | sed 's/^/  /'
		fi
	} >&2
}

# --------------------------------------------------------------------------
# Argument parsing.
# --------------------------------------------------------------------------

while [ $# -gt 0 ]; do
	case $1 in
	-h|--help)
		usage
		exit 0
		;;
	--dry-run)
		DRY_RUN=1
		;;
	--iface)
		[ $# -ge 2 ] || usage_error "--iface needs a value"
		IFACE=$2
		shift
		;;
	--iface=*)
		IFACE=${1#*=}
		;;
	--client-ssh)
		[ $# -ge 2 ] || usage_error "--client-ssh needs a value"
		CLIENT_SSH=$2
		shift
		;;
	--client-ssh=*)
		CLIENT_SSH=${1#*=}
		;;
	--client-mac)
		[ $# -ge 2 ] || usage_error "--client-mac needs a value"
		CLIENT_MAC=$2
		shift
		;;
	--client-mac=*)
		CLIENT_MAC=${1#*=}
		;;
	--client-model)
		[ $# -ge 2 ] || usage_error "--client-model needs a value"
		CLIENT_MODEL=$2
		shift
		;;
	--client-model=*)
		CLIENT_MODEL=${1#*=}
		;;
	--client-driver)
		[ $# -ge 2 ] || usage_error "--client-driver needs a value"
		CLIENT_DRIVER=$2
		shift
		;;
	--client-driver=*)
		CLIENT_DRIVER=${1#*=}
		;;
	--client-firmware)
		[ $# -ge 2 ] || usage_error "--client-firmware needs a value"
		CLIENT_FIRMWARE=$2
		shift
		;;
	--client-firmware=*)
		CLIENT_FIRMWARE=${1#*=}
		;;
	--country)
		[ $# -ge 2 ] || usage_error "--country needs a value"
		COUNTRY=$2
		shift
		;;
	--country=*)
		COUNTRY=${1#*=}
		;;
	--ap-addr)
		[ $# -ge 2 ] || usage_error "--ap-addr needs a value"
		AP_ADDR=$2
		shift
		;;
	--ap-addr=*)
		AP_ADDR=${1#*=}
		;;
	--duration)
		[ $# -ge 2 ] || usage_error "--duration needs a value"
		DURATION=$2
		shift
		;;
	--duration=*)
		DURATION=${1#*=}
		;;
	--omit)
		[ $# -ge 2 ] || usage_error "--omit needs a value"
		OMIT=$2
		OMIT_SET=1
		shift
		;;
	--omit=*)
		OMIT=${1#*=}
		OMIT_SET=1
		;;
	--streams)
		[ $# -ge 2 ] || usage_error "--streams needs a value"
		STREAMS=$2
		shift
		;;
	--streams=*)
		STREAMS=${1#*=}
		;;
	--port)
		[ $# -ge 2 ] || usage_error "--port needs a value"
		PORT=$2
		shift
		;;
	--port=*)
		PORT=${1#*=}
		;;
	--expected-nss)
		[ $# -ge 2 ] || usage_error "--expected-nss needs a value"
		EXPECTED_NSS=$2
		shift
		;;
	--expected-nss=*)
		EXPECTED_NSS=${1#*=}
		;;
	--target-gbit-s)
		[ $# -ge 2 ] || usage_error "--target-gbit-s needs a value"
		TARGET_GBIT=$2
		shift
		;;
	--target-gbit-s=*)
		TARGET_GBIT=${1#*=}
		;;
	--raw-dir)
		[ $# -ge 2 ] || usage_error "--raw-dir needs a value"
		RAW_DIR=$2
		shift
		;;
	--raw-dir=*)
		RAW_DIR=${1#*=}
		;;
	--check-rows)
		[ $# -ge 2 ] || usage_error "--check-rows needs a value"
		CHECK_ROWS=$2
		shift
		;;
	--check-rows=*)
		CHECK_ROWS=${1#*=}
		;;
	--result-json)
		[ $# -ge 2 ] || usage_error "--result-json needs a value"
		RESULT_JSON=$2
		shift
		;;
	--result-json=*)
		RESULT_JSON=${1#*=}
		;;
	--)
		shift
		[ $# -eq 0 ] || usage_error "unexpected argument: $1"
		break
		;;
	-*)
		usage_error "unknown option: $1"
		;;
	*)
		usage_error "unexpected argument: $1"
		;;
	esac
	shift
done

require_uint "--duration" "$DURATION" 1
require_uint "--streams" "$STREAMS" 1
require_uint "--port" "$PORT" 1 65535
require_uint "--expected-nss" "$EXPECTED_NSS" 1 8
require_uint "--omit" "$OMIT" 0
require_positive_number "$TARGET_GBIT"

if [ "$OMIT" -ge "$DURATION" ]; then
	if [ "$OMIT_SET" = 1 ]; then
		usage_error "--omit must be less than --duration"
	fi
	OMIT=0
fi

# Make the target a canonical JSON number, and reject a value that would
# round down to zero.
TARGET_GBIT=$(awk -v v="$TARGET_GBIT" 'BEGIN { printf "%.3f", v }')
awk -v v="$TARGET_GBIT" 'BEGIN { exit !(v > 0) }' ||
	usage_error "--target-gbit-s must be at least 0.001"

if [ -n "$IFACE" ]; then
	case $IFACE in
	-*) usage_error "--iface must not start with '-'" ;;
	esac
	safe_chars "$IFACE" 'A-Za-z0-9._-' ||
		usage_error "--iface contains unsupported characters"
fi
if [ -n "$CLIENT_SSH" ]; then
	case $CLIENT_SSH in
	-*) usage_error "--client-ssh must not start with '-'" ;;
	esac
	safe_chars "$CLIENT_SSH" 'A-Za-z0-9._@:%[]-' ||
		usage_error "--client-ssh contains unsupported characters"
fi
if [ -n "$AP_ADDR" ]; then
	case $AP_ADDR in
	-*) usage_error "--ap-addr must not start with '-'" ;;
	esac
	safe_chars "$AP_ADDR" 'A-Za-z0-9.:%_[]-' ||
		usage_error "--ap-addr contains unsupported characters"
fi
if [ -n "$RAW_DIR" ]; then
	case $RAW_DIR in
	-*) usage_error "--raw-dir must not start with '-'" ;;
	esac
fi
if [ -n "$CLIENT_MAC" ]; then
	CLIENT_MAC=$(normalize_mac "$CLIENT_MAC") || exit 2
fi
if [ -n "$COUNTRY" ]; then
	COUNTRY=$(normalize_country "$COUNTRY") || exit 2
fi
if [ -n "$CLIENT_MODEL" ]; then
	CLIENT_MODEL=$(one_line "$CLIENT_MODEL")
fi
if [ -n "$CLIENT_DRIVER" ]; then
	CLIENT_DRIVER=$(one_line "$CLIENT_DRIVER")
fi
if [ -n "$CLIENT_FIRMWARE" ]; then
	CLIENT_FIRMWARE=$(one_line "$CLIENT_FIRMWARE")
fi

# --------------------------------------------------------------------------
# --check-rows: offline channel plan check.  Runs before anything reads the
# radio, so a caller can validate saved rows on any machine.
# --------------------------------------------------------------------------

if [ -n "$CHECK_ROWS" ]; then
	check_rows "$CHECK_ROWS"
fi

# --------------------------------------------------------------------------
# Dry run.
# --------------------------------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
	cat <<EOF
$PROG: dry run; no iw, ssh or iperf3 command will be executed and no
directory will be created.

Environment:
  AP interface   : ${IFACE:-<auto: a 6 GHz 320 MHz AP BSS>}
  AP address     : ${AP_ADDR:-<auto: IPv4 on the BSS or br-lan>}
  client ssh     : ${CLIENT_SSH:-<required once a client is found>}
  client mac     : ${CLIENT_MAC:-<auto: the only 320 MHz station>}
  client model   : ${CLIENT_MODEL:-<required>}
  client driver  : ${CLIENT_DRIVER:-<required>}
  client firmware: ${CLIENT_FIRMWARE:-<required>}
  country        : ${COUNTRY:-<auto: iw reg get>}
  duration/omit  : ${DURATION} s / ${OMIT} s
  streams        : ${STREAMS}
  expected NSS   : ${EXPECTED_NSS}
  target         : ${TARGET_GBIT} Gbit/s AP->STA
  raw dir        : ${RAW_DIR:-${TMPDIR:-/tmp}/6g320-matrix.$$}

Plan:
  1. iw dev; for each interface: iw dev IFACE info
     require type AP*, frequency 5945-7125 MHz, width 320 MHz
  2. iw dev IFACE station dump
     require a station whose tx or rx rate width is 320 MHz
     skip when there is no such station: "SKIP: no 320 client", exit 3 (missing-hardware)
  3. read country from iw reg get and AP address from the BSS or br-lan
  4. snapshot the station, then run arm 1 (local-source, AP->STA):
       iperf3 -s -1 -p $PORT
       ssh ${CLIENT_SSH:-<client-ssh>} "iperf3 -c ${AP_ADDR:-<ap-addr>} -p $PORT -t $DURATION -O $OMIT -P $STREAMS -i 0 -R -J"
     snapshot the station after the arm
  5. snapshot the station, then run arm 2 (fixed RX, STA->AP):
       iperf3 -s -1 -p $PORT
       ssh ${CLIENT_SSH:-<client-ssh>} "iperf3 -c ${AP_ADDR:-<ap-addr>} -p $PORT -t $DURATION -O $OMIT -P $STREAMS -i 0 -J"
     snapshot the station after the arm
  6. mark an arm invalid on a width/NSS downgrade, re-association or a
     vanished station; print one JSONL row on stdout and a table on stderr

Result schema: $SCHEMA_ID (scripts/wireless/6g320-matrix.schema.json)
EOF
	exit 0
fi

# --------------------------------------------------------------------------
# Hardware gate.  Nothing is written until a 320 MHz client is found.
# --------------------------------------------------------------------------

if ! command -v iw >/dev/null 2>&1; then
	if [ -n "$IFACE" ]; then
		say "iw is not installed; cannot validate --iface $IFACE"
		skip_no_tool iw "iw is not installed; cannot validate --iface $IFACE"
	fi
	say "iw is not installed; no 6 GHz 320 MHz AP can be validated"
	skip_no_tool iw "iw is not installed"
fi

CANDIDATES=$(discover_candidates)
if [ -z "$CANDIDATES" ]; then
	if [ -n "$IFACE" ]; then
		die "$IFACE is not a 6 GHz (5945-7125 MHz) 320 MHz AP BSS"
	fi
	say "no 6 GHz 320 MHz AP BSS found"
	skip_no_client 6ghz-320mhz-ap-bss "no 6 GHz 320 MHz AP BSS found"
fi

if [ -n "$IFACE" ]; then
	CANDIDATES=$(printf '%s\n' "$CANDIDATES" |
		awk -F'|' -v i="$IFACE" '$1 == i')
	if [ -z "$CANDIDATES" ]; then
		die "$IFACE is not a 6 GHz (5945-7125 MHz) 320 MHz AP BSS"
	fi
fi

select_client

# Re-read immediately before needing the operator-supplied identity; a
# station that vanished or downgraded between discovery and here is a
# hardware skip, not a usage error.  Nothing under the repository is
# written: this snapshot goes to a temporary file.
_initial=$(mktemp "${TMPDIR:-/tmp}/6g320-matrix.XXXXXX") ||
	die "cannot create a temporary station snapshot"
if ! snapshot_station "$IFACE" "$CLIENT_MAC" "$_initial"; then
	say "client $CLIENT_MAC left before the arms could start"
	rm -f "$_initial"
	skip_no_client
fi
load_station "$_initial" || :
rm -f "$_initial"
I_WIDTH=$(eff_width "$S_TXW" "$S_RXW")
I_NSS=$(eff_nss "$S_TXN" "$S_RXN")
I_TXW=$S_TXW
I_TXN=$S_TXN
I_RXW=$S_RXW
I_RXN=$S_RXN
I_SIG=$S_SIG
I_W320=0
[ "$I_TXW" = 320 ] && I_W320=1
[ "$I_RXW" = 320 ] && I_W320=1
# Only a client that was at 320 MHz when it was selected and has since
# dropped below it is a hardware skip.  A client selected at 160 MHz on
# purpose (--client-mac naming a 160-only station) is measured: gating on
# I_W320 alone made every such row unreachable.
if [ "$I_W320" != 1 ] && [ "${SEL_W:-}" = 320 ]; then
	say "client $CLIENT_MAC dropped from 320 MHz to ${I_WIDTH:-?} MHz before the arms (tx ${I_TXW:-?}, rx ${I_RXW:-?} MHz)"
	skip_no_client
fi
if [ "$I_W320" != 1 ]; then
	add_warning "client $CLIENT_MAC measures at ${I_WIDTH:-?} MHz, not 320 MHz; this row is a sub-320 MHz result"
fi
if [ -z "$I_SIG" ]; then
	add_warning "station signal unavailable"
fi

if [ -z "$CLIENT_SSH" ] || [ -z "$CLIENT_MODEL" ] ||
	[ -z "$CLIENT_DRIVER" ] || [ -z "$CLIENT_FIRMWARE" ]; then
	usage_error "a 320 MHz client is associated; pass --client-ssh, --client-model, --client-driver and --client-firmware"
fi

command -v iperf3 >/dev/null 2>&1 ||
	die "iperf3 is not installed on the AP"
if command -v ssh >/dev/null 2>&1; then
	SSH_BIN=ssh
elif command -v dbclient >/dev/null 2>&1; then
	SSH_BIN=dbclient
else
	die "neither ssh nor dbclient is installed on the AP"
fi
if [ -z "$COUNTRY" ]; then
	COUNTRY=$(detect_country | tr 'a-z' 'A-Z')
	case $COUNTRY in
	??)
		case $COUNTRY in
		*[!A-Z0-9]*) COUNTRY=00 ;;
		esac
		;;
	*) COUNTRY=00 ;;
	esac
	if [ "$COUNTRY" = 00 ]; then
		add_warning "AP regulatory country is 00 (world); 6 GHz 320 MHz may not be valid"
	fi
fi

if [ -z "$AP_ADDR" ]; then
	command -v ip >/dev/null 2>&1 ||
		die "ip is not installed on the AP; cannot determine the AP address"
	if ! AP_ADDR=$(detect_ap_addr); then
		die "cannot find an IPv4 address on $IFACE or br-lan; pass --ap-addr"
	fi
fi

AP_HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null ||
	hostname 2>/dev/null)
[ -n "$AP_HOSTNAME" ] || AP_HOSTNAME=unknown
AP_HOSTNAME=$(one_line "$AP_HOSTNAME")
AP_MODEL=$(detect_ap_model)
AP_MODEL=$(one_line "$AP_MODEL")
AP_SSID=$(iface_ssid "$IFACE")
AP_SSID=$(one_line "$AP_SSID")
SERVER_IPERF=$(iperf3 --version 2>/dev/null | head -1)
[ -n "$SERVER_IPERF" ] || SERVER_IPERF=unknown
SERVER_IPERF=$(one_line "$SERVER_IPERF")
if [ -z "$AP_CENTER" ]; then
	add_warning "AP center1 frequency unavailable"
fi

if [ -z "$RAW_DIR" ]; then
	RAW_DIR=${TMPDIR:-/tmp}/6g320-matrix.$$
fi
(umask 077; mkdir -p "$RAW_DIR") ||
	die "cannot create raw directory $RAW_DIR"
[ -w "$RAW_DIR" ] || die "raw directory $RAW_DIR is not writable"

say "client: $CLIENT_MAC on $IFACE (ch $AP_CHANNEL, $AP_FREQ MHz, $AP_WIDTH MHz)"
say "client identity: $CLIENT_MODEL / $CLIENT_DRIVER / $CLIENT_FIRMWARE"
say "country: $COUNTRY; AP address: $AP_ADDR; raw: $RAW_DIR"

run_arm ap_to_sta 1
run_arm sta_to_ap 0

if [ -z "$R1_STATUS" ] || [ -z "$R2_STATUS" ]; then
	die "internal error: an arm produced no result"
fi

emit_row >"$RAW_DIR/row.json" ||
	die "cannot write $RAW_DIR/row.json"
if command -v jq >/dev/null 2>&1; then
	if ! jq -e . "$RAW_DIR/row.json" >/dev/null 2>&1; then
		die "generated row is not valid JSON; kept as $RAW_DIR/row.json"
	fi
fi
cat "$RAW_DIR/row.json"
print_table

if [ "$R1_STATUS" = ok ] && [ "$R2_STATUS" = ok ]; then
	exit 0
fi
say "one or more arms were invalid or failed; the row records why"
exit 1
