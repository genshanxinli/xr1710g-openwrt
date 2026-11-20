#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC3043
#
# irq-napi-ab.sh - reproducible IRQ-affinity and threaded-NAPI A/B harness.
#
# What this answers: the A path tops out at about 1.34 Gbit/s while the NPU
# token count and the PLE are not exhausted.  The remaining host-side
# candidate is %soft, concentrated on one A53 because the kernel leaves the
# Wi-Fi MSI lines on the boot CPU.  The tree already carries IRQ-affinity
# policy (qdma-irq-affinity and, in some images, qdma-irq-repin) but no
# reproducible A/B.
#
# This script runs four arms around one fixed traffic source, client and
# measurement window:
#
#   baseline   no state change at all
#   split      the candidate IRQs are pinned to CPUs (round-robin, or the
#              mapping given with --irq-map)
#   threaded   the mt76 debugfs napi_threaded value is set (default 1)
#   combined   split and threaded together
#
# One invocation runs the arms in that order.  The baseline state is
# restored before every arm and again after every arm, so the only
# difference between two arms is the arm's own intervention.  A trap
# (EXIT/INT/TERM/HUP) restores the saved /proc/irq/N/smp_affinity masks and
# the saved napi_threaded value even when an arm fails.
#
# What is sampled for every arm (all read-only except the intervention):
#   - iw station dump before/after: tx bytes, packets, retries, failed,
#     signal and the TX rate/NSS line,
#   - per-CPU /proc/softirqs deltas (NET_TX, NET_RX and total per CPU),
#   - per-CPU %soft and %irq from /proc/stat deltas,
#   - mpstat -P ALL per-CPU %soft when sysstat is installed,
#   - per-CPU deltas for every candidate IRQ line, so the affinity change
#     can be seen in the interrupt counters as well as in the softirqs,
#   - AP netdev tx counters as a second throughput view.
#
# Throughput is the station tx-byte delta over the measured window, the
# same L2 measure the other A-path harnesses use.  It includes
# retransmissions; read retries_delta and the source's own summary before
# treating it as air throughput.
#
# Safety: no module load/unload, no firmware, no UCI, no reboot.  The only
# system writes are /proc/irq/N/smp_affinity, the mt76
# .../mt76/napi_threaded debugfs file, and files under --out-dir.  The
# script refuses a real run as non-root and prints a plan unless --run is
# given.  Do not run it concurrently with another experiment on the same
# board: it temporarily owns the candidate IRQ affinities and the NAPI
# threading knob.
#
# POSIX sh only (busybox ash on the AP).  Verified with sh -n, busybox
# sh -n, shellcheck -s sh, --help, host and device dry-runs, and fixture
# runs that check the trap restores the saved state.
#
# Exit status:
#   0  all requested arms ran and the saved state was restored, or a clean
#      dry run (even when prerequisites are missing)
#   1  setup/run/rollback failure (the trap has still tried to restore)
#   2  invalid arguments
#
# Examples:
#   # read-only plan, safe on a build host (always exits 0)
#   sh scripts/wireless/irq-napi-ab.sh --iface phy0.1-ap0 \
#       --client 192.168.1.236
#
#   # real A/B on the AP, same client/source/window for all four arms
#   sh /usr/share/irq-napi-ab/irq-napi-ab.sh --iface phy0.1-ap0 \
#       --client 192.168.1.236 --seconds 20 --warmup 3 --procs 6 \
#       --source '/usr/bin/udpblast3 -d "$CLIENT_IP" -p 5201 \
#                 -r "$PER_PROC_MBPS" -t "$SOURCE_SECS" -s 4 \
#                 -i "$BIND_IFACE"' --run
#
#   # reproduce the tree's qdma-irq-repin policy as the split arm
#   sh /usr/share/irq-napi-ab/irq-napi-ab.sh --iface phy0.1-ap0 \
#       --client 192.168.1.236 --irq-map 50:2,51:3 --run

set -u
LC_ALL=C
export LC_ALL

PROG=${0##*/}

# Defaults.  Every value can also be set from the environment; the command
# line wins.  WINDOW is seconds, not the bash SECONDS variable.
IFACE=${IFACE:-}
CLIENT=${CLIENT:-}
CLIENT_IP_OPT=${CLIENT_IP:-}
CLIENT_MAC_OPT=${CLIENT_MAC:-}
WINDOW=${WINDOW:-20}
WARMUP=${WARMUP:-3}
PROCS=${PROCS:-6}
RATE=${RATE:-1340}
SOURCE=${SOURCE:-}
SOURCE_IFACE=${SOURCE_IFACE:-auto}
IRQ_NAMES=${IRQ_NAMES:-mt76-npu mt7996e-hif mt7996e}
IRQ_ARG=${IRQ:-}
IRQ_MAP_OPT=${IRQ_MAP:-}
CPUS_OPT=${CPUS:-}
THREADED_VALUE=${THREADED_VALUE:-1}
NAPI_PATH_OPT=${NAPI_PATH:-}
ARMS=${ARMS:-baseline,split,threaded,combined}
OUT_DIR_OPT=${OUT_DIR:-}
PROC_ROOT=${PROC_ROOT:-/proc}
DEBUGFS_ROOT=${DEBUGFS_ROOT:-/sys/kernel/debug}
RUN=${RUN:-0}

# Internal state.
CPUS=
IRQ_RECORDS=
IRQ_COUNT=0
IRQ_WRITABLE=
IRQ_EXCLUDED=
SAVED_AFF=
SPLIT_MAP=
NEED_SPLIT=0
NEED_NAPI=0
NAPI_PATH=
NAPI_SAVED=
NAPI_WRITABLE=0
MISSING=
OPTIONAL=
MISSING_N=0
OPTIONAL_N=0
WIPHY=
IFACE_OK=0
IW_OK=0
STATION_OK=0
CLIENT_MAC=
CLIENT_IP=
BIND_IFACE=
SOURCE_KIND=
MPSTAT_CMD=
MPSTAT_OK=0
TMP_FILES=
WRITE_COUNT=0
RESTORE_FAILED=0
RESULT_RECORDS=
OUT_DIR=
ARM_DIR=
CURRENT_ARM=
ARM_STATUS=ok
ARM_REASON=
APPLIED_SPLIT=
APPLIED_AFF=
APPLIED_NAPI=
SOURCE_PIDS=
MPSTAT_PID=
SOURCE_EXIT=
SOURCE_SECS=
PER_PROC_MBPS=
WINDOW_S=0
ARM_WRITES=0
NAPI_CHANGED=0
SPLIT_CHANGED=0
BASELINE_UNCHANGED=n/a

note() {
	printf '%s: %s\n' "$PROG" "$*" >&2
}

say() {
	printf '%s\n' "$*"
}

die() {
	note "$*"
	exit 2
}

is_uint() {
	case ${1-} in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

is_mac() {
	printf '%s\n' "${1-}" |
		grep -Eq '^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$'
}

lower() {
	printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'
}

as_uint() {
	if is_uint "${1-}"; then
		printf '%s' "$1"
	else
		printf '0'
	fi
}

# "0-3,5" -> "0 1 2 3 5".  Fail on anything else so a typo does not turn
# into a silently empty CPU pool.
parse_cpu_list() {
	local list item a b i out=''

	list=$(printf '%s' "${1-}" | tr ',' ' ')
	for item in $list; do
		case $item in
		*-*)
			a=${item%-*}
			b=${item#*-}
			is_uint "$a" && is_uint "$b" || return 1
			[ "$a" -le "$b" ] || return 1
			i=$a
			while [ "$i" -le "$b" ]; do
				out="$out $i"
				i=$((i + 1))
			done
			;;
		'')
			;;
		*)
			is_uint "$item" || return 1
			out="$out $item"
			;;
		esac
	done
	printf '%s' "${out# }"
}

arm_requested() {
	local want="$1" a

	for a in $ARMS; do
		[ "$a" = "$want" ] && return 0
	done
	return 1
}

# Contains a space-separated list member?  Keeps intentional list splitting
# out of quoted printf hands.
contains_word() {
	case " ${2-} " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

add_missing() {
	if [ -z "$MISSING" ]; then
		MISSING=$1
	else
		MISSING="$MISSING,$1"
	fi
	MISSING_N=$((MISSING_N + 1))
}

add_optional() {
	if [ -z "$OPTIONAL" ]; then
		OPTIONAL=$1
	else
		OPTIONAL="$OPTIONAL,$1"
	fi
	OPTIONAL_N=$((OPTIONAL_N + 1))
}

usage() {
	cat <<'EOF'
Usage: irq-napi-ab.sh --iface NAME --client ADDR [options]

IRQ-affinity and mt76 threaded-NAPI A/B harness for the A path.  One
invocation runs these arms, in order, around the same source, client and
measurement window:

  baseline   no affinity or napi_threaded change
  split      candidate IRQs pinned to CPUs
  threaded   mt76 debugfs napi_threaded set to --threaded-value (default 1)
  combined   split and threaded together

The saved /proc/irq/N/smp_affinity masks and napi_threaded value are
restored before and after every arm and from an EXIT/INT/TERM/HUP trap.
No module reload, firmware or UCI write is used.

Required for a real run (--run):
  --iface NAME          AP netdev under test, e.g. phy0.1-ap0
  --client ADDR         client IPv4 address or MAC; it must be associated
  --source 'COMMAND'    traffic source; without it the default is one
                        "iperf3 -c CLIENT_IP -t SOURCE_SECS" per process
                        (iperf3 is needed on the AP, -s on the client)

Options:
  --client-ip IP        explicit client IPv4 when --client is a MAC
  --client-mac MAC      explicit client MAC when --client is an IPv4
  --seconds N           measured window in seconds (default 20);
                        --window is an alias
  --warmup N            warm-up before the window in seconds (default 3)
  --procs N             source copies started per arm (default 6)
  --rate MBPS           aggregate offered UDP payload rate, exported to
                        the source as RATE (default 1340)
  --source 'COMMAND'    shell command run PROCS times per arm.  It must
                        keep sending for SOURCE_SECS and terminate within
                        it.  Exported: ARM IFACE CLIENT CLIENT_IP
                        CLIENT_MAC WINDOW WARMUP SOURCE_SECS PROCS INDEX
                        RATE PER_PROC_MBPS BIND_IFACE OUT.  CLIENT is the
                        --client argument; CLIENT_IP/CLIENT_MAC are the
                        resolved addresses.
  --source-iface NAME   source egress bind: auto (bridge master of
                        --iface, the default), none, or a device name
  --irq N[,N...]        explicit candidate IRQs; default discovers them
                        from /proc/interrupts by --irq-names
  --irq-names 'LIST'    space-separated handler names to discover (default
                        "mt76-npu mt7996e-hif mt7996e")
  --cpus LIST           CPU pool for the automatic split, e.g. 0-3
                        (default: online CPUs)
  --irq-map IRQ:CPU,..  explicit split mapping; only the listed IRQs are
                        moved.  Example: --irq-map 50:2,51:3
  --threaded-value N    value written by the threaded arm, 0 or 1
                        (default 1; 0 gives the unthreaded contrast when
                        the board already runs threaded)
  --napi-path PATH      mt76 napi_threaded debugfs file; default
                        /sys/kernel/debug/ieee80211/phy*/mt76/napi_threaded
  --arms LIST           arms to run, default baseline,split,threaded,combined
  --out-dir DIR         artifact directory
                        (default /tmp/irq-napi-ab.<date>-<pid>)
  --proc-root DIR       alternate /proc mount (default /proc; for tests)
  --debugfs-root DIR    alternate debugfs mount (default /sys/kernel/debug)
  --run                 really change state and start the source
  --dry-run             read-only plan; this is the default without --run
  --help                this help

Arms whose prerequisite is missing are reported and skipped: threaded and
combined need a writable napi_threaded file, split needs at least one
writable candidate IRQ.  A real run with missing mandatory prerequisites
exits 1; a dry run still exits 0 on a build host without the board.

Throughput is the station tx-byte delta over the measured window:
gbps = tx_delta_bytes * 8 / measured_seconds / 1e9.  It counts L2 bytes
and retransmissions, so compare retries_delta between arms.

Examples:
  # safe read-only plan on a build host (no writes, no traffic, exit 0)
  sh scripts/wireless/irq-napi-ab.sh --iface phy0.1-ap0 \
      --client 192.168.1.236

  # real A/B on the AP, same source/client/window for all arms
  sh /usr/share/irq-napi-ab/irq-napi-ab.sh --iface phy0.1-ap0 \
      --client 192.168.1.236 --seconds 20 --warmup 3 --procs 6 \
      --source '/usr/bin/udpblast3 -d "$CLIENT_IP" -p 5201 \
                -r "$PER_PROC_MBPS" -t "$SOURCE_SECS" -s 4 \
                -i "$BIND_IFACE"' --run

  # reproduce the qdma-irq-repin policy as the split arm
  sh /usr/share/irq-napi-ab/irq-napi-ab.sh --iface phy0.1-ap0 \
      --client 192.168.1.236 --irq-map 50:2,51:3 --run
EOF
}

# ---------------------------------------------------------------- arguments

parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
		--iface)		[ $# -ge 2 ] || die "$1 needs a value"; IFACE=$2; shift 2 ;;
		--client)		[ $# -ge 2 ] || die "$1 needs a value"; CLIENT=$2; shift 2 ;;
		--client-ip)		[ $# -ge 2 ] || die "$1 needs a value"; CLIENT_IP_OPT=$2; shift 2 ;;
		--client-mac)		[ $# -ge 2 ] || die "$1 needs a value"; CLIENT_MAC_OPT=$2; shift 2 ;;
		--seconds|--window)	[ $# -ge 2 ] || die "$1 needs a value"; WINDOW=$2; shift 2 ;;
		--warmup)		[ $# -ge 2 ] || die "$1 needs a value"; WARMUP=$2; shift 2 ;;
		--procs)		[ $# -ge 2 ] || die "$1 needs a value"; PROCS=$2; shift 2 ;;
		--rate)			[ $# -ge 2 ] || die "$1 needs a value"; RATE=$2; shift 2 ;;
		--source)		[ $# -ge 2 ] || die "$1 needs a value"; SOURCE=$2; shift 2 ;;
		--source-iface)		[ $# -ge 2 ] || die "$1 needs a value"; SOURCE_IFACE=$2; shift 2 ;;
		--irq)			[ $# -ge 2 ] || die "$1 needs a value"; IRQ_ARG=$2; shift 2 ;;
		--irq-names)		[ $# -ge 2 ] || die "$1 needs a value"; IRQ_NAMES=$2; shift 2 ;;
		--cpus)			[ $# -ge 2 ] || die "$1 needs a value"; CPUS_OPT=$2; shift 2 ;;
		--irq-map)		[ $# -ge 2 ] || die "$1 needs a value"; IRQ_MAP_OPT=$2; shift 2 ;;
		--threaded-value)	[ $# -ge 2 ] || die "$1 needs a value"; THREADED_VALUE=$2; shift 2 ;;
		--napi-path)		[ $# -ge 2 ] || die "$1 needs a value"; NAPI_PATH_OPT=$2; shift 2 ;;
		--arms)			[ $# -ge 2 ] || die "$1 needs a value"; ARMS=$2; shift 2 ;;
		--out-dir)		[ $# -ge 2 ] || die "$1 needs a value"; OUT_DIR_OPT=$2; shift 2 ;;
		--proc-root)		[ $# -ge 2 ] || die "$1 needs a value"; PROC_ROOT=$2; shift 2 ;;
		--debugfs-root)		[ $# -ge 2 ] || die "$1 needs a value"; DEBUGFS_ROOT=$2; shift 2 ;;
		--run)			RUN=1; shift ;;
		--dry-run)		RUN=0; shift ;;
		--help|-h)		usage; exit 0 ;;
		*)			die "unknown option '$1' (try --help)" ;;
		esac
	done

	is_uint "$WINDOW" && [ "$WINDOW" -ge 1 ] && [ "$WINDOW" -le 3600 ] ||
		die "--seconds must be 1..3600"
	is_uint "$WARMUP" && [ "$WARMUP" -ge 1 ] && [ "$WARMUP" -le 3600 ] ||
		die "--warmup must be 1..3600"
	is_uint "$PROCS" && [ "$PROCS" -ge 1 ] && [ "$PROCS" -le 64 ] ||
		die "--procs must be 1..64"
	is_uint "$RATE" && [ "$RATE" -ge 1 ] ||
		die "--rate must be a positive integer (Mbit/s)"
	case $THREADED_VALUE in
	0|1) ;;
	*) die "--threaded-value must be 0 or 1" ;;
	esac
	[ -n "$PROC_ROOT" ] || die "--proc-root must not be empty"
	[ -n "$DEBUGFS_ROOT" ] || die "--debugfs-root must not be empty"
	[ -d "$PROC_ROOT" ] || die "proc root '$PROC_ROOT' is not a directory"

	IRQ_NAMES=$(printf '%s' "$IRQ_NAMES" | tr ',' ' ')
	[ -n "$(printf '%s' "$IRQ_NAMES" | tr -d ' ')" ] ||
		die "--irq-names must not be empty"

	# Arms, deduplicated but in the requested order.
	ARMS=$(printf '%s' "$ARMS" | tr ',' ' ')
	local arms_norm='' a s seen
	for a in $ARMS; do
		case $a in
		baseline|split|threaded|combined) ;;
		*) die "unknown arm '$a' (baseline, split, threaded, combined)" ;;
		esac
		seen=0
		for s in $arms_norm; do
			[ "$s" = "$a" ] && seen=1
		done
		[ "$seen" -eq 1 ] && continue
		arms_norm="$arms_norm $a"
	done
	[ -n "$arms_norm" ] || die "--arms must name at least one arm"
	ARMS=${arms_norm# }
	arm_requested split && NEED_SPLIT=1
	arm_requested combined && NEED_SPLIT=1
	arm_requested threaded && NEED_NAPI=1
	arm_requested combined && NEED_NAPI=1

	# Explicit IRQ list: comma or space separated; the discovery awk takes
	# commas, the validation loop takes words.
	if [ -n "$IRQ_ARG" ]; then
		IRQ_ARG=$(printf '%s' "$IRQ_ARG" | tr ',' ' ')
		local list='' item
		for item in $IRQ_ARG; do
			is_uint "$item" || die "--irq '$item' is not an IRQ number"
			list="$list $item"
		done
		IRQ_ARG=$(printf '%s' "${list# }" | tr ' ' ',')
	fi

	# Explicit split map: space-separated "IRQ:CPU" records.
	if [ -n "$IRQ_MAP_OPT" ]; then
		local map='' rec irq cpu
		IRQ_MAP_OPT=$(printf '%s' "$IRQ_MAP_OPT" | tr ',' ' ')
		for rec in $IRQ_MAP_OPT; do
			case $rec in
			*:*)	irq=${rec%%:*}; cpu=${rec#*:} ;;
			*)	die "--irq-map '$rec' is not IRQ:CPU" ;;
			esac
			is_uint "$irq" || die "--irq-map IRQ '$irq' is not a number"
			is_uint "$cpu" || die "--irq-map CPU '$cpu' is not a number"
			map="$map $irq:$cpu"
		done
		SPLIT_MAP=${map# }
	fi

	SOURCE_SECS=$((WARMUP + WINDOW + 2))
	PER_PROC_MBPS=$(awk -v r="$RATE" -v p="$PROCS" \
		'BEGIN { printf "%.3f", r / p }')

	if [ -z "$SOURCE" ]; then
		SOURCE_KIND=default
		# Single quotes are deliberate: CLIENT_IP/SOURCE_SECS are
		# expanded by the per-arm source shell from the exported env.
		# shellcheck disable=SC2016
		SOURCE='iperf3 -c "$CLIENT_IP" -t "$SOURCE_SECS" -f m'
	else
		SOURCE_KIND=custom
	fi

	if [ -z "$OUT_DIR_OPT" ]; then
		OUT_DIR=/tmp/irq-napi-ab.$(date +%Y%m%d-%H%M%S).$$
	else
		OUT_DIR=$OUT_DIR_OPT
	fi
}

# ------------------------------------------------------------------- helpers

read_uint_file() {
	if [ -f "$1" ] && [ -r "$1" ]; then
		as_uint "$(cat "$1" 2>/dev/null)"
	else
		printf '0'
	fi
}

delta_uint() {
	local before after

	before=$(as_uint "${1-}")
	after=$(as_uint "${2-}")
	if [ "$after" -ge "$before" ]; then
		printf '%s' "$((after - before))"
	else
		printf '0'
	fi
}

# Preserve "not printed" instead of converting it to a plausible zero.
delta_or_unavail() {
	if is_uint "${1-}" && is_uint "${2-}"; then
		delta_uint "$1" "$2"
	else
		printf 'unavailable'
	fi
}

field_or_unavail() {
	if [ -n "${1-}" ]; then
		printf '%s' "$1"
	else
		printf 'unavailable'
	fi
}

read_file() {
	[ -f "$1" ] && [ -r "$1" ] || return 1
	tr -d '\r' < "$1" 2>/dev/null | sed 's/[[:space:]]*$//'
}

online_cpus() {
	local cpus=''

	if [ -r /sys/devices/system/cpu/online ]; then
		cpus=$(parse_cpu_list "$(cat /sys/devices/system/cpu/online)")
	fi
	if [ -z "$cpus" ]; then
		cpus=$(interrupt_cpus)
	fi
	printf '%s' "$cpus"
}

# CPU ids from the /proc/interrupts header, in column order.
interrupt_cpus() {
	[ -r "$PROC_ROOT/interrupts" ] || return 1
	awk '
		NR == 1 {
			out = ""
			sep = ""
			for (i = 1; i <= NF; i++) {
				c = $i
				sub(/^CPU/, "", c)
				if (c !~ /^[0-9]+$/)
					continue
				out = out sep c
				sep = " "
			}
			print out
			exit
		}
	' "$PROC_ROOT/interrupts"
}

# Candidate IRQ lines: "irq|matched-name|action" for every /proc/interrupts
# line whose text mentions one of IRQ_NAMES, or every line in the --irq
# list.  IRQ numbers are resolved at run time because the kernel renumbers
# them between builds; the handler names are the stable part.
discover_irqs() {
	[ -r "$PROC_ROOT/interrupts" ] || return 1
	awk -v names="$IRQ_NAMES" -v explicit="$IRQ_ARG" '
		BEGIN {
			n = split(names, name, " ")
			m = split(explicit, want, ",")
		}
		/^[ \t]*[0-9]+:/ {
			irq = $1
			sub(/:$/, "", irq)

			if (explicit != "") {
				found = 0
				for (i = 1; i <= m; i++)
					if (want[i] == irq)
						found = 1
				if (!found)
					next
				tag = "explicit"
			} else {
				line = tolower($0)
				tag = ""
				for (i = 1; i <= n; i++) {
					if (index(line, tolower(name[i]))) {
						tag = name[i]
						break
					}
				}
				if (tag == "")
					next
			}

			# The CPU counts come right after the IRQ field; the
			# first non-numeric field starts the controller and
			# action description.
			j = 2
			while (j <= NF && $j ~ /^[0-9]+$/)
				j++
			action = ""
			for (k = j; k <= NF; k++)
				action = action (k > j ? " " : "") $k
			print irq "|" tag "|" action
		}
	' "$PROC_ROOT/interrupts" 2>/dev/null
}

irq_count() {
	printf '%s\n' "$1" | awk 'NF { n++ } END { print n + 0 }'
}

# Per-CPU counts for one IRQ line, "cpu:count,..." in header order.
irq_counts() {
	[ -f "$1" ] || return 1
	awk -v irq="$2" '
		FNR == 1 {
			for (i = 1; i <= NF; i++) {
				c = $i
				sub(/^CPU/, "", c)
				cpu[i] = c
			}
			next
		}
		/^[ \t]*[0-9]+:/ {
			n = $1
			sub(/:$/, "", n)
			if (n != irq)
				next
			out = ""
			sep = ""
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				out = out sep cpu[i - 1] ":" $i
				sep = ","
			}
			print out
			exit
		}
	' "$1"
}

irq_delta_percpu() {
	[ -f "$1" ] && [ -f "$2" ] || return 1
	awk -v irq="$3" '
		FNR == NR {
			if (FNR == 1) {
				for (i = 1; i <= NF; i++) {
					c = $i
					sub(/^CPU/, "", c)
					cpu[i] = c
				}
			}
			if ($1 ~ /^[0-9]+:$/) {
				n = $1
				sub(/:$/, "", n)
				if (n == irq)
					for (i = 2; i <= NF; i++) {
						if ($i !~ /^[0-9]+$/)
							break
						before[i] = $i
					}
			}
			next
		}
		$1 ~ /^[0-9]+:$/ {
			n = $1
			sub(/:$/, "", n)
			if (n != irq)
				next
			out = ""
			sep = ""
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				d = $i - before[i]
				if (d < 0)
					d = 0
				out = out sep cpu[i - 1] ":" d
				sep = ","
			}
			print out
			exit
		}
	' "$1" "$2"
}

irq_total_delta() {
	[ -f "$1" ] && [ -f "$2" ] || {
		printf '0'
		return
	}
	awk -v irq="$3" '
		FNR == NR {
			if ($1 ~ /^[0-9]+:$/) {
				n = $1
				sub(/:$/, "", n)
				if (n == irq)
					for (i = 2; i <= NF; i++) {
						if ($i !~ /^[0-9]+$/)
							break
						b += $i
					}
			}
			next
		}
		$1 ~ /^[0-9]+:$/ {
			n = $1
			sub(/:$/, "", n)
			if (n != irq)
				next
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				a += $i
			}
			printf "%d", (a >= b) ? a - b : 0
			exit
		}
	' "$1" "$2"
}

softirq_label_percpu() {
	[ -f "$1" ] && [ -f "$2" ] || return 1
	awk -v label="$3" '
		FNR == NR {
			if (FNR == 1) {
				for (i = 1; i <= NF; i++) {
					c = $i
					sub(/^CPU/, "", c)
					cpu[i] = c
				}
			}
			if ($1 == label ":" || $1 == label)
				for (i = 2; i <= NF; i++) {
					if ($i !~ /^[0-9]+$/)
						break
					before[i] = $i
				}
			next
		}
		$1 == label ":" || $1 == label {
			out = ""
			sep = ""
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				d = $i - before[i]
				if (d < 0)
					d = 0
				out = out sep cpu[i - 1] ":" d
				sep = ","
			}
			print out
			exit
		}
	' "$1" "$2"
}

softirq_label_total() {
	[ -f "$1" ] || {
		printf '0'
		return
	}
	awk -v label="$2" '
		$1 == label ":" || $1 == label {
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				s += $i
			}
			printf "%d", s + 0
			exit
		}
	' "$1"
}

softirq_total_percpu() {
	[ -f "$1" ] && [ -f "$2" ] || return 1
	awk '
		FNR == NR {
			if (FNR == 1) {
				ncpu = NF
				for (i = 1; i <= NF; i++) {
					c = $i
					sub(/^CPU/, "", c)
					cpu[i] = c
				}
			}
			if ($1 ~ /:$/)
				for (i = 2; i <= NF; i++) {
					if ($i !~ /^[0-9]+$/)
						break
					before[i] += $i
				}
			next
		}
		$1 ~ /:$/ {
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				after[i] += $i
			}
		}
		END {
			out = ""
			sep = ""
			for (i = 2; i <= ncpu + 1; i++) {
				d = after[i] - before[i]
				if (d < 0)
					d = 0
				out = out sep cpu[i - 1] ":" d
				sep = ","
			}
			print out
		}
	' "$1" "$2"
}

softirq_total_delta() {
	[ -f "$1" ] && [ -f "$2" ] || {
		printf '0'
		return
	}
	awk '
		FNR == NR {
			if ($1 ~ /:$/)
				for (i = 2; i <= NF; i++) {
					if ($i !~ /^[0-9]+$/)
						break
					b += $i
				}
			next
		}
		$1 ~ /:$/ {
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				a += $i
			}
		}
		END { printf "%d", (a >= b) ? a - b : 0 }
	' "$1" "$2"
}

# Per-CPU softirq or hard-IRQ share from /proc/stat deltas.  $3 is the
# 1-based field: 7 = irq, 8 = softirq.
procstat_pct_percpu() {
	[ -f "$1" ] && [ -f "$2" ] || return 1
	awk -v col="$3" '
		FNR == NR {
			if ($1 ~ /^cpu[0-9]+$/) {
				t = 0
				for (i = 2; i <= 9; i++)
					t += $i
				bt[$1] = t
				bv[$1] = $col
			}
			next
		}
		$1 ~ /^cpu[0-9]+$/ {
			t = 0
			for (i = 2; i <= 9; i++)
				t += $i
			dt = t - bt[$1]
			dv = $col - bv[$1]
			if (dt <= 0)
				next
			out = out sep substr($1, 4) ":" sprintf("%.2f", dv * 100 / dt)
			sep = ","
		}
		END { print out }
	' "$1" "$2"
}

# mpstat -P ALL average %soft per CPU, "cpu:value,...".
mpstat_soft_percpu() {
	[ -f "$1" ] || return 1
	awk '
		/Average:/ && $2 == "CPU" {
			for (i = 3; i <= NF; i++)
				if ($i == "%soft")
					col = i
			next
		}
		/Average:/ && $2 ~ /^[0-9]+$/ {
			if (col > 0) {
				ok = 1
				out = out sep $2 ":" $(col)
				sep = ","
			}
		}
		END {
			if (!ok)
				exit 1
			print out
		}
	' "$1"
}

# Station block / field helpers, same format as the other A-path harnesses.
sta_block() {
	[ -f "${1-}" ] || return 0
	awk -v mac="$(lower "${2-}")" '
		BEGIN { found = 0 }
		/^Station / {
			if (found)
				exit
			if (tolower($2) == mac) {
				found = 1
				next
			}
		}
		found { print }
	' "$1"
}

sta_field() {
	sta_block "${1-}" "${2-}" | awk -v key="${3-}" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (index(line, key) != 1)
				next
			rest = substr(line, length(key) + 1)
			sub(/^[ \t]+/, "", rest)
			split(rest, a, /[ \t]+/)
			print a[1]
			exit
		}
	'
}

sta_nss() {
	sta_block "${1-}" "${2-}" | awk -v key="${3-}" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (index(line, key) != 1)
				next
			n = split(line, a, /[ \t]+/)
			for (i = 1; i <= n; i++)
				if (a[i] ~ /-NSS$/ || a[i] == "NSS") {
					print a[i + 1]
					exit
				}
		}
	'
}

# -------------------------------------------------------------- preflight

resolve_client() {
	local mac ip

	mac=$CLIENT_MAC_OPT
	ip=$CLIENT_IP_OPT

	if is_mac "$CLIENT"; then
		[ -n "$mac" ] || mac=$CLIENT
		if [ -z "$ip" ] && [ -n "$mac" ]; then
			ip=$(ip neigh show 2>/dev/null | awk -v m="$(lower "$mac")" '
				tolower($0) ~ m {
					for (i = 1; i <= NF; i++)
						if ($i == "lladdr") {
							print $1
							exit
						}
				}')
		fi
	else
		[ -n "$ip" ] || ip=$CLIENT
		if [ -z "$mac" ] && [ -n "$ip" ]; then
			mac=$(ip neigh show 2>/dev/null | awk -v want="$ip" '
				$1 == want {
					for (i = 1; i <= NF; i++)
						if ($i == "lladdr") {
							print $(i + 1)
							exit
						}
				}')
		fi
	fi
	[ -n "$mac" ] && mac=$(lower "$mac")
	CLIENT_MAC=$mac
	CLIENT_IP=$ip
}

resolve_source_bind() {
	local hops next

	BIND_IFACE=
	case $SOURCE_IFACE in
	none)
		return 0
		;;
	auto)
		[ "$IFACE_OK" -eq 1 ] || return 0
		BIND_IFACE=$IFACE
		hops=0
		while [ -n "$BIND_IFACE" ] &&
		      [ -e "/sys/class/net/$BIND_IFACE/master" ] &&
		      [ "$hops" -lt 8 ]; do
			next=$(readlink "/sys/class/net/$BIND_IFACE/master" 2>/dev/null || :)
			next=${next##*/}
			[ -n "$next" ] || break
			[ "$next" = "$BIND_IFACE" ] && break
			BIND_IFACE=$next
			hops=$((hops + 1))
		done
		;;
	*)
		BIND_IFACE=$SOURCE_IFACE
		;;
	esac

	[ -n "$BIND_IFACE" ] || return 0
	if [ ! -e "/sys/class/net/$BIND_IFACE" ]; then
		add_missing "source-iface-$BIND_IFACE"
		BIND_IFACE=
	elif [ -e "/sys/class/net/$BIND_IFACE/master" ]; then
		# SO_BINDTODEVICE on a bridge port does not route; refuse it
		# instead of producing a fast source with no AP tx delta.
		add_missing "source-iface-is-a-bridge-port-$BIND_IFACE"
		BIND_IFACE=
	fi
}

find_napi_path() {
	local f first=''

	if [ -n "$NAPI_PATH_OPT" ]; then
		NAPI_PATH=$NAPI_PATH_OPT
		return 0
	fi
	if [ -n "$WIPHY" ] &&
	   [ -e "$DEBUGFS_ROOT/ieee80211/phy$WIPHY/mt76/napi_threaded" ]; then
		NAPI_PATH="$DEBUGFS_ROOT/ieee80211/phy$WIPHY/mt76/napi_threaded"
		return 0
	fi
	for f in "$DEBUGFS_ROOT"/ieee80211/phy*/mt76/napi_threaded; do
		[ -e "$f" ] || continue
		if [ -n "$first" ]; then
			note "multiple napi_threaded files; using $first"
			break
		fi
		first=$f
	done
	NAPI_PATH=$first
}

read_napi_value() {
	[ -n "$NAPI_PATH" ] || return 1
	read_file "$NAPI_PATH" 2>/dev/null
}

preflight() {
	local tmp irq name action aff f

	CPUS=$(online_cpus)
	if [ -n "$CPUS_OPT" ]; then
		CPUS=$(parse_cpu_list "$CPUS_OPT") ||
			die "--cpus '$CPUS_OPT' is not a CPU list"
	fi
	[ -n "$CPUS" ] || add_missing "online-cpus"
	for irq in $CPUS; do
		[ "$irq" -le 31 ] || add_missing "cpu-$irq-above-mask-width"
	done

	command -v awk >/dev/null 2>&1 || add_missing awk
	[ -r "$PROC_ROOT/interrupts" ] || add_missing proc-interrupts
	[ -r "$PROC_ROOT/softirqs" ] || add_missing proc-softirqs
	[ -r "$PROC_ROOT/stat" ] || add_missing proc-stat
	[ -r "$PROC_ROOT/uptime" ] || add_missing proc-uptime

	IRQ_RECORDS=$(discover_irqs) || :
	IRQ_COUNT=$(irq_count "$IRQ_RECORDS")
	if [ -n "$IRQ_ARG" ]; then
		for irq in $(printf '%s' "$IRQ_ARG" | tr ',' ' '); do
			printf '%s\n' "$IRQ_RECORDS" | grep -q "^$irq|" ||
				add_missing "irq-$irq"
		done
	fi
	if [ "$NEED_SPLIT" -eq 1 ] && [ "$IRQ_COUNT" -eq 0 ]; then
		add_missing "irq-candidates"
	fi

	# Save the affinity of every candidate that can actually be
	# re-pinned.  A managed IRQ exposes smp_affinity read-only; root's
	# "test -w" is true even then, so the mode and a real same-value
	# write probe are what decide.  The probe writes the current mask,
	# so it changes nothing; it is skipped in a dry run.
	SAVED_AFF=
	IRQ_WRITABLE=
	IRQ_EXCLUDED=
	if [ "$IRQ_COUNT" -gt 0 ]; then
		while IFS='|' read -r irq name action; do
			[ -n "$irq" ] || continue
			aff=$(read_affinity "$irq")
			if [ -z "$aff" ]; then
				IRQ_EXCLUDED="$IRQ_EXCLUDED $irq:no-affinity"
				note "irq $irq: no readable smp_affinity; excluded"
				continue
			fi
			if ! affinity_mode_writable "$irq"; then
				IRQ_EXCLUDED="$IRQ_EXCLUDED $irq:read-only"
				note "irq $irq: smp_affinity is read-only (managed IRQ?); excluded"
				continue
			fi
			if [ "$RUN" -eq 1 ] && ! probe_affinity "$irq" "$aff"; then
				IRQ_EXCLUDED="$IRQ_EXCLUDED $irq:probe-failed"
				note "irq $irq: same-value write probe failed; excluded"
				continue
			fi
			SAVED_AFF="$SAVED_AFF $irq:$aff"
			IRQ_WRITABLE="$IRQ_WRITABLE $irq"
		done <<EOF
$IRQ_RECORDS
EOF
	fi
	if [ "$NEED_SPLIT" -eq 1 ] && [ -z "$IRQ_WRITABLE" ]; then
		add_missing irq-writable
	fi

	# Interface, wiphy and the mt76 threaded-NAPI knob.  All of this is
	# read-only; the debugfs file is only written by the threaded and
	# combined arms.
	command -v iw >/dev/null 2>&1 && IW_OK=1
	[ "$IW_OK" -eq 1 ] || add_missing iw
	command -v ip >/dev/null 2>&1 || add_optional ip
	[ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] || add_missing root

	if [ -z "$IFACE" ]; then
		add_missing iface-arg
	elif [ ! -e "/sys/class/net/$IFACE" ]; then
		add_missing "iface-$IFACE"
	elif [ "$IW_OK" -eq 1 ] && iw dev "$IFACE" info >/dev/null 2>&1; then
		IFACE_OK=1
		WIPHY=$(iw dev "$IFACE" info 2>/dev/null |
			awk '$1 == "wiphy" { print $2; exit }')
	elif [ "$IW_OK" -eq 1 ]; then
		add_missing "iw-iface-$IFACE"
	fi

	NAPI_PATH=
	NAPI_SAVED=
	NAPI_WRITABLE=0
	[ -n "$NAPI_PATH_OPT" ] && NAPI_PATH=$NAPI_PATH_OPT
	if [ -z "$NAPI_PATH" ] && [ "$IW_OK" -eq 1 ]; then
		find_napi_path
	fi
	if [ -n "$NAPI_PATH" ]; then
		NAPI_SAVED=$(read_napi_value 2>/dev/null || :)
		if [ -z "$NAPI_SAVED" ]; then
			note "napi_threaded at $NAPI_PATH is not readable"
			NAPI_PATH=
		elif [ -w "$NAPI_PATH" ]; then
			NAPI_WRITABLE=1
		else
			note "napi_threaded at $NAPI_PATH is not writable"
		fi
	fi
	if [ "$NEED_NAPI" -eq 1 ] && [ "$NAPI_WRITABLE" -ne 1 ]; then
		add_optional napi_threaded
	fi

	command -v mpstat >/dev/null 2>&1 && MPSTAT_OK=1
	[ "$MPSTAT_OK" -eq 1 ] || add_optional mpstat
	if [ "$MPSTAT_OK" -eq 1 ]; then
		MPSTAT_CMD=$(command -v mpstat)
	fi

	# Client address resolution and one station-dump read.  The read is
	# also what proves the client is associated.
	if [ -z "$CLIENT" ]; then
		add_missing client-arg
	else
		resolve_client
		if [ -z "$CLIENT_MAC" ]; then
			add_missing client-mac
		fi
		if [ "$IW_OK" -eq 1 ] && [ "$IFACE_OK" -eq 1 ] &&
		   [ -n "$CLIENT_MAC" ]; then
			tmp=${TMPDIR:-/tmp}/irq-napi-ab.$$.station
			TMP_FILES="$TMP_FILES $tmp"
			: > "$tmp" 2>/dev/null || :
			iw dev "$IFACE" station dump > "$tmp" 2>/dev/null || :
			if [ -n "$(sta_block "$tmp" "$CLIENT_MAC")" ]; then
				STATION_OK=1
			else
				add_missing "station-$CLIENT_MAC"
			fi
		fi
		if [ "$SOURCE_KIND" = default ] && [ -z "$CLIENT_IP" ]; then
			add_missing client-ip
		fi
	fi

	if [ "$SOURCE_KIND" = default ]; then
		command -v iperf3 >/dev/null 2>&1 || add_missing iperf3
	fi

	resolve_source_bind

	# Build or validate the split map.  An explicit map is used as-is
	# (only those IRQs move); the automatic map round-robins the writable
	# candidates over CPUS in /proc/interrupts order.
	if [ -n "$SPLIT_MAP" ]; then
		local map_ok='' rec m_irq m_cpu
		for rec in $SPLIT_MAP; do
			m_irq=${rec%%:*}
			m_cpu=${rec#*:}
			if ! contains_word "$m_irq" "$IRQ_WRITABLE"; then
				add_missing "irq-map-$m_irq-not-writable"
				continue
			fi
			if ! contains_word "$m_cpu" "$CPUS"; then
				add_missing "irq-map-cpu-$m_cpu-not-in-cpus"
				continue
			fi
			map_ok="$map_ok $rec"
		done
		SPLIT_MAP=${map_ok# }
	else
		local i=0 ncpu=0 cpu c k targets=
		# cpu0 is the boot CPU: arch_timer (~2.5M IRQs/s) and the
		# housekeeping IRQs already saturate it, so moving a candidate
		# IRQ there changes nothing and the split arm reads as a no-op.
		# Round-robin over the remaining online CPUs, and fall back to
		# the full list on a single-CPU system.
		for cpu in $CPUS; do
			[ "$cpu" -eq 0 ] || targets="$targets $cpu"
		done
		[ -n "$targets" ] || targets=$CPUS
		for cpu in $targets; do
			ncpu=$((ncpu + 1))
		done
		SPLIT_MAP=
		if [ -n "$IRQ_WRITABLE" ] && [ "$ncpu" -gt 0 ]; then
			for irq in $IRQ_WRITABLE; do
				i=$((i + 1))
				k=$(( (i - 1) % ncpu + 1 ))
				cpu=
				for c in $targets; do
					k=$((k - 1))
					if [ "$k" -eq 0 ]; then
						cpu=$c
						break
					fi
				done
				[ -n "$cpu" ] || continue
				SPLIT_MAP="$SPLIT_MAP $irq:$cpu"
			done
			SPLIT_MAP=${SPLIT_MAP# }
		fi
	fi

	if [ "$NEED_SPLIT" -eq 1 ] && [ -z "$SPLIT_MAP" ]; then
		add_missing split-map
	fi
	if [ "$NEED_NAPI" -eq 1 ] && [ "$NAPI_WRITABLE" -ne 1 ]; then
		note "no writable napi_threaded; threaded/combined arms will be skipped"
	fi
}

report_plan() {
	local irq name action aff counts rec cpu

	say "$PROG: dry-run: no state is written and no traffic is sent"
	say "$PROG: iface=${IFACE:-none} wiphy=${WIPHY:-none} iw=$([ "$IW_OK" -eq 1 ] && echo yes || echo no) mpstat=$([ "$MPSTAT_OK" -eq 1 ] && echo yes || echo no)"
	say "$PROG: client=${CLIENT:-none} ip=${CLIENT_IP:-unavailable} mac=${CLIENT_MAC:-unavailable} station=$([ "$STATION_OK" -eq 1 ] && echo associated || echo missing)"
	say "$PROG: source=$SOURCE_KIND bind_iface=${BIND_IFACE:-none} procs=$PROCS rate=$RATE window=$WINDOW warmup=$WARMUP source_secs=$SOURCE_SECS"
	say "$PROG: cpus=$(printf '%s' "$CPUS" | tr ' ' ',')"
	if [ "$IRQ_COUNT" -gt 0 ]; then
		say "$PROG: candidate IRQs from $PROC_ROOT/interrupts:"
		while IFS='|' read -r irq name action; do
			[ -n "$irq" ] || continue
			aff=$(read_affinity "$irq")
			counts=$(irq_counts "$PROC_ROOT/interrupts" "$irq")
			if contains_word "$irq" "$IRQ_WRITABLE"; then
				writable=mode-writable
			else
				writable=no
			fi
			say "  irq $irq $name mode=$(affinity_perm "$irq") affinity=${aff:-unavailable} writable=$writable counts=${counts:-unavailable} action=\"$action\""
		done <<EOF
$IRQ_RECORDS
EOF
	else
		say "$PROG: candidate IRQs: none (names: $IRQ_NAMES; use --irq/--irq-names)"
	fi
	if [ -n "$SPLIT_MAP" ]; then
		say "$PROG: planned split:"
		for rec in $SPLIT_MAP; do
			irq=${rec%%:*}
			cpu=${rec#*:}
			say "  irq $irq -> cpu$cpu"
		done
	else
		say "$PROG: planned split: none (no writable candidate IRQ)"
	fi
	if [ -n "$IRQ_EXCLUDED" ]; then
		say "$PROG: excluded IRQs: ${IRQ_EXCLUDED# }"
	fi
	if [ -n "$NAPI_PATH" ]; then
		say "$PROG: napi_threaded=$NAPI_PATH value=${NAPI_SAVED:-unavailable} writable=$([ "$NAPI_WRITABLE" -eq 1 ] && echo yes || echo no) arm_value=$THREADED_VALUE"
	else
		say "$PROG: napi_threaded: not found (threaded/combined arms will be skipped)"
	fi
	say "$PROG: arms=$ARMS"
	if [ "$MISSING_N" -gt 0 ]; then
		say "$PROG: missing: $(printf '%s' "$MISSING" | tr ',' ' ')"
	fi
	if [ "$OPTIONAL_N" -gt 0 ]; then
		say "$PROG: optional missing: $(printf '%s' "$OPTIONAL" | tr ',' ' ')"
	fi
	say "$PROG: dry-run OK"
}

# -------------------------------------------------------------------- state

read_affinity() {
	cat "$PROC_ROOT/irq/$1/smp_affinity" 2>/dev/null |
		tr -d ' \t\r\n'
}

# Kernel masks are hex; compare without leading zeros because a written
# "00000004" can read back as "4".
norm_mask() {
	local m

	m=$(printf '%s' "${1-}" | tr 'A-F' 'a-f' | tr -d ' \t\r\n')
	m=$(printf '%s' "$m" | sed 's/^0*//')
	[ -n "$m" ] || m=0
	printf '%s' "$m"
}

mask_equal() {
	[ "$(norm_mask "$1")" = "$(norm_mask "$2")" ]
}

affinity_perm() {
	# OpenWrt's busybox has no stat applet; ls -l is the portable read.
	# shellcheck disable=SC2012
	ls -l "$PROC_ROOT/irq/$1/smp_affinity" 2>/dev/null |
		awk 'NR == 1 { print $1; exit }'
}

# Owner write bit in the mode.  Managed IRQs expose the file as 0444 even
# for root, and "test -w" is not enough because root bypasses DAC.
affinity_mode_writable() {
	case $(affinity_perm "$1") in
	-?w*) return 0 ;;
	esac
	return 1
}

# Write a mask and verify the readback.  Retry once or twice: an IRQ can
# be briefly busy while a previous move completes.
write_affinity() {
	local irq="$1" mask="$2" i=0 cur

	while [ "$i" -lt 3 ]; do
		if printf '%s\n' "$mask" > "$PROC_ROOT/irq/$irq/smp_affinity" \
			2>/dev/null; then
			cur=$(read_affinity "$irq")
			mask_equal "$cur" "$mask" && return 0
		fi
		i=$((i + 1))
		[ "$i" -lt 3 ] && sleep 1
	done
	return 1
}

# Same-value write, used to prove a candidate can be moved at all.  The
# value does not change, so no state is modified.
probe_affinity() {
	write_affinity "$1" "$2"
}

set_affinity() {
	local irq="$1" cpu="$2" mask cur

	# A single CPU fits in one 32-bit mask word; --cpus rejects cpu >= 32.
	mask=$(printf '%x' "$((1 << cpu))")
	cur=$(read_affinity "$irq")
	[ -z "$cur" ] && return 1
	mask_equal "$cur" "$mask" && return 0
	if ! write_affinity "$irq" "$mask"; then
		return 1
	fi
	WRITE_COUNT=$((WRITE_COUNT + 1))
	return 0
}

set_napi() {
	local value="$1" cur

	[ -n "$NAPI_PATH" ] || return 1
	cur=$(read_napi_value 2>/dev/null || :)
	[ "$cur" = "$value" ] && return 0
	if printf '%s\n' "$value" > "$NAPI_PATH" 2>/dev/null; then
		WRITE_COUNT=$((WRITE_COUNT + 1))
	else
		return 1
	fi
	cur=$(read_napi_value 2>/dev/null || :)
	[ "$cur" = "$value" ]
}

restore_state() {
	local rec irq mask cur rc=0

	for rec in $SAVED_AFF; do
		irq=${rec%%:*}
		mask=${rec#*:}
		cur=$(read_affinity "$irq")
		[ -z "$cur" ] && {
			rc=1
			continue
		}
		mask_equal "$cur" "$mask" && continue
		if write_affinity "$irq" "$mask"; then
			WRITE_COUNT=$((WRITE_COUNT + 1))
		else
			note "failed to restore irq $irq affinity $mask"
			rc=1
		fi
	done

	if [ -n "$NAPI_PATH" ] && [ -n "$NAPI_SAVED" ]; then
		cur=$(read_napi_value 2>/dev/null || :)
		if [ "$cur" != "$NAPI_SAVED" ]; then
			if printf '%s\n' "$NAPI_SAVED" > "$NAPI_PATH" 2>/dev/null; then
				WRITE_COUNT=$((WRITE_COUNT + 1))
			else
				note "failed to restore napi_threaded to $NAPI_SAVED"
				rc=1
			fi
			cur=$(read_napi_value 2>/dev/null || :)
			[ "$cur" = "$NAPI_SAVED" ] || rc=1
		fi
	fi

	RESTORE_FAILED=$rc
	return $rc
}

applied_state() {
	local rec irq

	APPLIED_AFF=
	for rec in $SAVED_AFF; do
		irq=${rec%%:*}
		APPLIED_AFF="$APPLIED_AFF $irq:$(read_affinity "$irq")"
	done
	APPLIED_AFF=${APPLIED_AFF# }
	{
		printf 'split_map=%s\n' "${APPLIED_SPLIT:-none}"
		printf 'napi_threaded=%s\n' "${APPLIED_NAPI:-none}"
		printf 'affinity=%s\n' "${APPLIED_AFF:-none}"
	} > "$ARM_DIR/state.applied" 2>/dev/null || :
}

# --------------------------------------------------------------- artifacts

snapshot() {
	local tag="$1" rec irq

	[ -n "$ARM_DIR" ] || return 0
	if [ "$IW_OK" -eq 1 ]; then
		iw dev "$IFACE" station dump > "$ARM_DIR/station.$tag" \
			2> "$ARM_DIR/station.$tag.err" || :
	else
		: > "$ARM_DIR/station.$tag"
	fi
	cat "$PROC_ROOT/interrupts" > "$ARM_DIR/interrupts.$tag" 2>/dev/null || :
	cat "$PROC_ROOT/softirqs" > "$ARM_DIR/softirqs.$tag" 2>/dev/null || :
	cat "$PROC_ROOT/stat" > "$ARM_DIR/procstat.$tag" 2>/dev/null || :
	if [ "$IFACE_OK" -eq 1 ]; then
		cat "/sys/class/net/$IFACE/statistics/tx_bytes" \
			> "$ARM_DIR/iface_tx_bytes.$tag" 2>/dev/null || :
		cat "/sys/class/net/$IFACE/statistics/tx_packets" \
			> "$ARM_DIR/iface_tx_packets.$tag" 2>/dev/null || :
	fi
	{
		for rec in $SAVED_AFF; do
			irq=${rec%%:*}
			printf 'irq %s %s\n' "$irq" "$(read_affinity "$irq")"
		done
		[ -n "$NAPI_PATH" ] &&
			printf 'napi_threaded %s\n' "$(read_napi_value 2>/dev/null || :)"
	} > "$ARM_DIR/state.$tag" 2>/dev/null || :
}

# ---------------------------------------------------------------- source

start_source() {
	local i=0 pid

	SOURCE_PIDS=
	export ARM="$CURRENT_ARM"
	export IFACE CLIENT_IP CLIENT_MAC WINDOW WARMUP SOURCE_SECS PROCS RATE
	export PER_PROC_MBPS BIND_IFACE OUT="$ARM_DIR"
	while [ "$i" -lt "$PROCS" ]; do
		i=$((i + 1))
		export INDEX="$i"
		(
			cd "$ARM_DIR" 2>/dev/null || exit 1
			sh -c "$SOURCE"
		) > "$ARM_DIR/source.$i.out" 2> "$ARM_DIR/source.$i.err" &
		pid=$!
		SOURCE_PIDS="$SOURCE_PIDS $pid"
	done
}

sources_alive() {
	local pid

	for pid in $SOURCE_PIDS; do
		kill -0 "$pid" 2>/dev/null || return 1
	done
	return 0
}

stop_sources() {
	local pid alive=0 i=0

	for pid in $SOURCE_PIDS; do
		kill -0 "$pid" 2>/dev/null && alive=1
	done
	# The source contract is "terminate within SOURCE_SECS"; give it the
	# margin before terminating the top-level shells.
	while [ "$alive" -eq 1 ] && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
		alive=0
		for pid in $SOURCE_PIDS; do
			kill -0 "$pid" 2>/dev/null && alive=1
		done
	done
	if [ "$alive" -eq 1 ]; then
		for pid in $SOURCE_PIDS; do
			kill -TERM "$pid" 2>/dev/null || :
		done
		i=0
		while [ "$i" -lt 3 ]; do
			sleep 1
			i=$((i + 1))
			alive=0
			for pid in $SOURCE_PIDS; do
				kill -0 "$pid" 2>/dev/null && alive=1
			done
			[ "$alive" -eq 0 ] && break
		done
	fi
	SOURCE_EXIT=ok
	if [ "$alive" -eq 1 ]; then
		for pid in $SOURCE_PIDS; do
			kill -KILL "$pid" 2>/dev/null || :
		done
		SOURCE_EXIT=lingering
	fi
	for pid in $SOURCE_PIDS; do
		wait "$pid" 2>/dev/null || :
	done
	SOURCE_PIDS=
}

stop_sources_quiet() {
	[ -n "$SOURCE_PIDS" ] || return 0
	stop_sources >/dev/null 2>&1 || :
}

start_mpstat() {
	MPSTAT_PID=
	[ "$MPSTAT_OK" -eq 1 ] || return 0
	"$MPSTAT_CMD" -P ALL 1 "$WINDOW" > "$ARM_DIR/mpstat.txt" \
		2> "$ARM_DIR/mpstat.err" &
	MPSTAT_PID=$!
}

stop_mpstat() {
	[ -n "$MPSTAT_PID" ] || return 0
	wait "$MPSTAT_PID" 2>/dev/null || :
	MPSTAT_PID=
}

# --------------------------------------------------------------- measurement

measure_arm() {
	local arm="$1" writes_start split_writes_start rec irq cpu cur
	local napi_changed=0 split_changed=0

	CURRENT_ARM=$arm
	ARM_DIR="$OUT_DIR/$arm"
	ARM_STATUS=ok
	ARM_REASON=
	APPLIED_SPLIT=
	APPLIED_NAPI=
	APPLIED_AFF=
	BASELINE_UNCHANGED=n/a
	mkdir -p "$ARM_DIR" 2>/dev/null || {
		note "cannot create $ARM_DIR"
		ARM_STATUS=fail
		ARM_REASON=mkdir-failed
		return 1
	}

	# Always start an arm from the saved state.  On the first arm this is
	# a read-only verification; after a previous arm it undoes that arm's
	# intervention.
	if ! restore_state; then
		note "$arm: could not restore the baseline state before the arm"
		ARM_STATUS=fail
		ARM_REASON=restore-before-arm
		return 1
	fi
	writes_start=$WRITE_COUNT
	split_writes_start=$WRITE_COUNT

	case $arm in
	split|combined)
		if [ -z "$SPLIT_MAP" ]; then
			ARM_STATUS=skipped
			ARM_REASON=no-writable-irq
			return 2
		fi
		for rec in $SPLIT_MAP; do
			irq=${rec%%:*}
			cpu=${rec#*:}
			if ! set_affinity "$irq" "$cpu"; then
				note "$arm: failed to pin irq $irq to cpu$cpu"
				restore_state >/dev/null 2>&1 || :
				ARM_STATUS=fail
				ARM_REASON=affinity-write
				return 1
			fi
			APPLIED_SPLIT="$APPLIED_SPLIT $irq:$cpu"
		done
		APPLIED_SPLIT=${APPLIED_SPLIT# }
		[ "$WRITE_COUNT" -gt "$split_writes_start" ] && split_changed=1
		;;
	esac

	case $arm in
	threaded|combined)
		if [ "$NAPI_WRITABLE" -ne 1 ] || [ -z "$NAPI_PATH" ]; then
			[ "$arm" = combined ] && restore_state >/dev/null 2>&1 || :
			ARM_STATUS=skipped
			ARM_REASON=napi-not-writable
			return 2
		fi
		cur=$(read_napi_value 2>/dev/null || :)
		if ! set_napi "$THREADED_VALUE"; then
			note "$arm: failed to write napi_threaded=$THREADED_VALUE"
			restore_state >/dev/null 2>&1 || :
			ARM_STATUS=skipped
			ARM_REASON=napi-write-failed
			return 2
		fi
		APPLIED_NAPI=$THREADED_VALUE
		[ "$cur" != "$THREADED_VALUE" ] && napi_changed=1
		;;
	esac

	NAPI_CHANGED=$napi_changed
	SPLIT_CHANGED=$split_changed
	if [ -n "$APPLIED_NAPI" ] && [ "$napi_changed" -eq 0 ]; then
		note "$arm: napi_threaded is already $THREADED_VALUE; no NAPI contrast"
	fi
	if [ -n "$APPLIED_SPLIT" ] && [ "$split_changed" -eq 0 ]; then
		note "$arm: every mapped IRQ already had its target mask; no affinity contrast"
	fi
	applied_state

	start_source
	sleep "$WARMUP"
	if ! sources_alive; then
		note "$arm: source process exited during warm-up"
		stop_sources_quiet
		restore_state >/dev/null 2>&1 || :
		ARM_STATUS=fail
		ARM_REASON=source-died
		return 1
	fi

	snapshot before
	local up_before
	up_before=$(awk '{ print $1 }' "$PROC_ROOT/uptime" 2>/dev/null || :)
	start_mpstat
	sleep "$WINDOW"
	stop_mpstat
	local up_after
	up_after=$(awk '{ print $1 }' "$PROC_ROOT/uptime" 2>/dev/null || :)
	snapshot after

	if ! sources_alive; then
		note "$arm: source process exited before the window ended"
		stop_sources_quiet
		restore_state >/dev/null 2>&1 || :
		ARM_STATUS=fail
		ARM_REASON=source-early
		return 1
	fi

	stop_sources
	if [ "$SOURCE_EXIT" = lingering ]; then
		note "$arm: a source ignored SOURCE_SECS and had to be killed"
	fi
	WINDOW_S=$(awk -v a="$up_before" -v b="$up_after" \
		'BEGIN { if (a != "" && b != "" && b >= a) printf "%.2f", b - a; else print "0" }')
	# The value above is "%.2f", so a string compare against 0 never matched
	# and WINDOW_S stayed "0.00"; every later rate divided by it.  Compare
	# numerically and fall back to the requested window when it is zero.
	awk -v s="$WINDOW_S" 'BEGIN { exit !(s + 0 > 0) }' || WINDOW_S=$WINDOW

	collect_arm
	if [ "$AP_TX_DELTA_BYTES" = unavailable ]; then
		note "$arm: no station tx-byte delta (client left?)"
		restore_state >/dev/null 2>&1 || :
		ARM_STATUS=fail
		ARM_REASON=station-missing
		return 1
	fi

	# Undo the intervention before reporting, so a report failure cannot
	# leave the board changed and the next arm starts from the baseline.
	if ! restore_state; then
		note "$arm: failed to restore the saved state"
		ARM_STATUS=fail
		ARM_REASON=restore-failed
		return 1
	fi
	ARM_WRITES=$((WRITE_COUNT - writes_start))

	if [ "$arm" = baseline ]; then
		local cur2 aff2 napi2 unchanged=1
		[ "$ARM_WRITES" -eq 0 ] || unchanged=0
		for rec in $SAVED_AFF; do
			irq=${rec%%:*}
			aff2=${rec#*:}
			cur2=$(read_affinity "$irq")
			mask_equal "$cur2" "$aff2" || unchanged=0
		done
		if [ -n "$NAPI_PATH" ] && [ -n "$NAPI_SAVED" ]; then
			napi2=$(read_napi_value 2>/dev/null || :)
			[ "$napi2" = "$NAPI_SAVED" ] || unchanged=0
		fi
		BASELINE_UNCHANGED=$unchanged
	fi

	print_arm_summary
	return 0
}

collect_arm() {
	local be="$ARM_DIR/softirqs.before" ae="$ARM_DIR/softirqs.after"
	local bi="$ARM_DIR/interrupts.before" ai="$ARM_DIR/interrupts.after"
	local bs="$ARM_DIR/station.before" as="$ARM_DIR/station.after"
	local bp="$ARM_DIR/procstat.before" ap="$ARM_DIR/procstat.after"
	local txb txa txpb txpa retb reta failb faila

	AP_TX_DELTA_BYTES=unavailable
	AP_TX_DELTA_PACKETS=unavailable
	AP_TX_RETRIES_DELTA=unavailable
	AP_TX_FAILED_DELTA=unavailable
	RETRIES_PCT=unavailable
	GBPS=unavailable
	IFACE_GBPS=unavailable
	CLIENT_SIGNAL=unavailable
	CLIENT_TX_NSS=unavailable
	CLIENT_TX_RATE=unavailable
	IRQ_TOTALS=

	if [ -n "$CLIENT_MAC" ] &&
	   [ -n "$(sta_block "$bs" "$CLIENT_MAC")" ] &&
	   [ -n "$(sta_block "$as" "$CLIENT_MAC")" ]; then
		txb=$(sta_field "$bs" "$CLIENT_MAC" "tx bytes:")
		txa=$(sta_field "$as" "$CLIENT_MAC" "tx bytes:")
		txpb=$(sta_field "$bs" "$CLIENT_MAC" "tx packets:")
		txpa=$(sta_field "$as" "$CLIENT_MAC" "tx packets:")
		retb=$(sta_field "$bs" "$CLIENT_MAC" "tx retries:")
		reta=$(sta_field "$as" "$CLIENT_MAC" "tx retries:")
		failb=$(sta_field "$bs" "$CLIENT_MAC" "tx failed:")
		faila=$(sta_field "$as" "$CLIENT_MAC" "tx failed:")
		AP_TX_DELTA_BYTES=$(delta_or_unavail "$txb" "$txa")
		AP_TX_DELTA_PACKETS=$(delta_or_unavail "$txpb" "$txpa")
		AP_TX_RETRIES_DELTA=$(delta_or_unavail "$retb" "$reta")
		AP_TX_FAILED_DELTA=$(delta_or_unavail "$failb" "$faila")
		if is_uint "$AP_TX_RETRIES_DELTA" &&
		   is_uint "$AP_TX_DELTA_PACKETS" &&
		   [ "$AP_TX_DELTA_PACKETS" -gt 0 ]; then
			RETRIES_PCT=$(awk -v r="$AP_TX_RETRIES_DELTA" \
				-v p="$AP_TX_DELTA_PACKETS" \
				'BEGIN { printf "%.2f", r * 100 / p }')
		fi
		if is_uint "$AP_TX_DELTA_BYTES" && [ "$AP_TX_DELTA_BYTES" -gt 0 ]; then
			GBPS=$(awk -v b="$AP_TX_DELTA_BYTES" -v s="$WINDOW_S" \
				'BEGIN { printf "%.3f", b * 8 / s / 1000000000 }')
		fi
		CLIENT_SIGNAL=$(field_or_unavail \
			"$(sta_field "$as" "$CLIENT_MAC" "signal:")")
		CLIENT_TX_NSS=$(field_or_unavail \
			"$(sta_nss "$as" "$CLIENT_MAC" "tx bitrate:")")
		CLIENT_TX_RATE=$(field_or_unavail \
			"$(sta_field "$as" "$CLIENT_MAC" "tx bitrate:")")
	fi

	IFACE_TX_DELTA_BYTES=$(delta_uint \
		"$(read_uint_file "$ARM_DIR/iface_tx_bytes.before")" \
		"$(read_uint_file "$ARM_DIR/iface_tx_bytes.after")")
	IFACE_TX_DELTA_PACKETS=$(delta_uint \
		"$(read_uint_file "$ARM_DIR/iface_tx_packets.before")" \
		"$(read_uint_file "$ARM_DIR/iface_tx_packets.after")")
	if [ "$IFACE_TX_DELTA_BYTES" -gt 0 ]; then
		IFACE_GBPS=$(awk -v b="$IFACE_TX_DELTA_BYTES" -v s="$WINDOW_S" \
			'BEGIN { printf "%.3f", b * 8 / s / 1000000000 }')
	fi

	SOFTIRQ_NET_TX_DELTA=$(delta_uint \
		"$(softirq_label_total "$be" NET_TX)" \
		"$(softirq_label_total "$ae" NET_TX)")
	SOFTIRQ_NET_RX_DELTA=$(delta_uint \
		"$(softirq_label_total "$be" NET_RX)" \
		"$(softirq_label_total "$ae" NET_RX)")
	SOFTIRQ_TOTAL_DELTA=$(softirq_total_delta "$be" "$ae")
	SOFTIRQ_NET_TX_PERCPU=$(softirq_label_percpu "$be" "$ae" NET_TX \
		2>/dev/null || :)
	SOFTIRQ_NET_RX_PERCPU=$(softirq_label_percpu "$be" "$ae" NET_RX \
		2>/dev/null || :)
	SOFTIRQ_TOTAL_PERCPU=$(softirq_total_percpu "$be" "$ae" 2>/dev/null || :)
	SOFTIRQ_PCT_PERCPU=$(procstat_pct_percpu "$bp" "$ap" 8 2>/dev/null || :)
	IRQ_PCT_PERCPU=$(procstat_pct_percpu "$bp" "$ap" 7 2>/dev/null || :)

	MPSTAT_SOFT_PERCPU=
	MPSTAT_STATE=missing
	if [ "$MPSTAT_OK" -eq 1 ]; then
		MPSTAT_STATE=failed
		if [ -s "$ARM_DIR/mpstat.txt" ]; then
			MPSTAT_SOFT_PERCPU=$(mpstat_soft_percpu "$ARM_DIR/mpstat.txt" \
				2>/dev/null || :)
			[ -n "$MPSTAT_SOFT_PERCPU" ] && MPSTAT_STATE=available
		fi
	fi

	while IFS='|' read -r irq _name _action; do
		[ -n "$irq" ] || continue
		IRQ_TOTALS="$IRQ_TOTALS$irq:$(irq_total_delta "$bi" "$ai" "$irq"),"
	done <<EOF
$IRQ_RECORDS
EOF
	IRQ_TOTALS=${IRQ_TOTALS%,}
}

print_arm_summary() {
	local rec irq name action delta percpu s

	s="arm=$CURRENT_ARM status=$ARM_STATUS"
	[ -n "$ARM_REASON" ] && s="$s reason=$ARM_REASON"
	s="$s window=$WINDOW_S warmup=$WARMUP procs=$PROCS rate=$RATE"
	s="$s iface=${IFACE:-none} client_ip=${CLIENT_IP:-unavailable}"
	s="$s client_mac=${CLIENT_MAC:-unavailable} source=$SOURCE_KIND"
	s="$s bind_iface=${BIND_IFACE:-none}"
	s="$s napi_path=${NAPI_PATH:-missing} napi_before=${NAPI_SAVED:-unavailable}"
	s="$s napi_value=${APPLIED_NAPI:-none} napi_changed=$NAPI_CHANGED"
	s="$s napi_writable=$NAPI_WRITABLE"
	s="$s split_map=${APPLIED_SPLIT:-none} split_changed=$SPLIT_CHANGED"
	s="$s irq_excluded=${IRQ_EXCLUDED# }"
	s="$s affinity=${APPLIED_AFF:-none} writes=$ARM_WRITES"
	s="$s tx_delta_bytes=$AP_TX_DELTA_BYTES"
	s="$s tx_delta_packets=$AP_TX_DELTA_PACKETS"
	s="$s retries_delta=$AP_TX_RETRIES_DELTA failed_delta=$AP_TX_FAILED_DELTA"
	s="$s retries_pct=$RETRIES_PCT gbps=$GBPS"
	s="$s iface_gbps=$IFACE_GBPS iface_tx_delta_bytes=$IFACE_TX_DELTA_BYTES iface_tx_delta_packets=$IFACE_TX_DELTA_PACKETS"
	s="$s softirq_net_tx_delta=$SOFTIRQ_NET_TX_DELTA"
	s="$s softirq_net_rx_delta=$SOFTIRQ_NET_RX_DELTA"
	s="$s softirq_total_delta=$SOFTIRQ_TOTAL_DELTA"
	s="$s softirq_net_tx_percpu=${SOFTIRQ_NET_TX_PERCPU:-none}"
	s="$s softirq_net_rx_percpu=${SOFTIRQ_NET_RX_PERCPU:-none}"
	s="$s softirq_total_percpu=${SOFTIRQ_TOTAL_PERCPU:-none}"
	s="$s softirq_pct_percpu=${SOFTIRQ_PCT_PERCPU:-none}"
	s="$s irq_pct_percpu=${IRQ_PCT_PERCPU:-none}"
	s="$s mpstat=$MPSTAT_STATE mpstat_soft_pct_percpu=${MPSTAT_SOFT_PERCPU:-none}"
	s="$s client_signal_dbm=$CLIENT_SIGNAL client_tx_nss=$CLIENT_TX_NSS"
	s="$s client_tx_rate_mbps=$CLIENT_TX_RATE"
	s="$s irq_totals=${IRQ_TOTALS:-none}"
	s="$s baseline_unchanged=$BASELINE_UNCHANGED"
	s="$s restore=$([ "$RESTORE_FAILED" -eq 0 ] && echo ok || echo failed)"
	s="$s source_exit=${SOURCE_EXIT:-none} artifacts=$ARM_DIR"

	say "$s"

	while IFS='|' read -r irq name action; do
		[ -n "$irq" ] || continue
		percpu=$(irq_delta_percpu "$ARM_DIR/interrupts.before" \
			"$ARM_DIR/interrupts.after" "$irq" 2>/dev/null || :)
		delta=$(irq_total_delta "$ARM_DIR/interrupts.before" \
			"$ARM_DIR/interrupts.after" "$irq")
		if contains_word "$irq" "$IRQ_WRITABLE"; then
			wstate=writable
		else
			wstate=read-only
		fi
		say "irq $irq $name affinity=$(affinity_of "$irq" "$(read_affinity "$irq")") writable=$wstate delta=$delta percpu=${percpu:-unavailable}"
	done <<EOF
$IRQ_RECORDS
EOF
	say ""

	RESULT_RECORDS="$RESULT_RECORDS$CURRENT_ARM|$GBPS|$AP_TX_RETRIES_DELTA|${SOFTIRQ_PCT_PERCPU:-none}|$SOFTIRQ_NET_TX_DELTA|$SOFTIRQ_NET_RX_DELTA
"
}

affinity_of() {
	local rec

	for rec in $APPLIED_AFF; do
		[ "${rec%%:*}" = "$1" ] && {
			printf '%s' "${rec#*:}"
			return 0
		}
	done
	printf '%s' "${2:-unavailable}"
}

print_results() {
	local rec arm gbps retries soft nettx netrx

	[ -n "$RESULT_RECORDS" ] || return 0
	say "$PROG: results (station tx bytes over the measured window)"
	printf '%-10s %8s %9s %-28s %12s %12s\n' \
		arm gbps retries "soft% per cpu" net_tx net_rx
	while IFS='|' read -r arm gbps retries soft nettx netrx; do
		[ -n "$arm" ] || continue
		printf '%-10s %8s %9s %-28s %12s %12s\n' \
			"$arm" "$gbps" "$retries" "$soft" "$nettx" "$netrx"
	done <<EOF
$RESULT_RECORDS
EOF
}

# -------------------------------------------------------------------- run

run_all() {
	local arm rc ran=0

	mkdir -p "$OUT_DIR" 2>/dev/null || {
		note "cannot create output directory $OUT_DIR"
		exit 1
	}
	{
		printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || :)"
		printf 'uname=%s\n' "$(uname -a 2>/dev/null || :)"
		printf 'iface=%s\n' "$IFACE"
		printf 'client=%s client_ip=%s client_mac=%s\n' \
			"$CLIENT" "${CLIENT_IP:-}" "${CLIENT_MAC:-}"
		printf 'cpus=%s\n' "$CPUS"
		printf 'irq_names=%s\n' "$IRQ_NAMES"
		printf 'napi_path=%s napi_before=%s\n' "${NAPI_PATH:-}" "${NAPI_SAVED:-}"
		printf 'arms=%s window=%s warmup=%s procs=%s rate=%s\n' \
			"$ARMS" "$WINDOW" "$WARMUP" "$PROCS" "$RATE"
		printf 'source_kind=%s source=%s\n' "$SOURCE_KIND" "$SOURCE"
		printf 'proc_root=%s debugfs_root=%s\n' "$PROC_ROOT" "$DEBUGFS_ROOT"
	} > "$OUT_DIR/run.info" 2>/dev/null || :

	trap 'on_exit' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP

	for arm in $ARMS; do
		measure_arm "$arm" && {
			ran=$((ran + 1))
			continue
		}
		rc=$?
		if [ "$rc" -eq 2 ]; then
			note "$arm: skipped (${ARM_REASON:-prerequisite missing})"
			say "arm=$arm status=skipped reason=${ARM_REASON:-prerequisite-missing}"
			continue
		fi
		note "$arm: failed (${ARM_REASON:-run-failure}); restoring and stopping"
		print_results
		exit 1
	done

	if [ "$ran" -eq 0 ]; then
		note "no arm could run; nothing was measured"
		exit 1
	fi

	# The per-arm restore already undid the last intervention; this is
	# the final idempotent check and the thing the trap repeats.
	if ! restore_state; then
		note "final restore failed"
		print_results
		exit 1
	fi
	print_results
	note "artifacts: $OUT_DIR"
	note "saved state restored"
}

on_exit() {
	local rc=$? f

	stop_sources_quiet
	stop_mpstat
	restore_state >/dev/null 2>&1 || :
	if [ "$RESTORE_FAILED" -ne 0 ] && [ "$rc" -eq 0 ]; then
		rc=1
	fi
	for f in $TMP_FILES; do
		rm -f "$f" 2>/dev/null || :
	done
	exit "$rc"
}

cleanup_temps() {
	local f

	for f in $TMP_FILES; do
		rm -f "$f" 2>/dev/null || :
	done
}

# ------------------------------------------------------------------- main

main() {
	parse_args "$@"
	preflight

	if [ "$RUN" -ne 1 ]; then
		trap cleanup_temps EXIT
		report_plan
		exit 0
	fi

	if [ "$MISSING_N" -gt 0 ]; then
		note "missing for a real run: $(printf '%s' "$MISSING" | tr ',' ' ')"
		note "refusing to run; nothing was changed"
		exit 1
	fi

	run_all
}

main "$@"
