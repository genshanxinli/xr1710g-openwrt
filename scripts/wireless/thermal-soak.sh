#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC3043,SC2329
#
# thermal-soak.sh - thermal/throughput curve and 24 h soak harness.
#
# Two modes share one sampling core:
#
#   --thermal  Run the configured load for DURATION (default 600 s, 10 min)
#              and sample the CPU thermal zone, the three MT7996 radios,
#              cpufreq, the NCT7802 fan PWM/tach, AP txpower, the station
#              counters and new thermal dmesg lines.  Prints one row per
#              sample with a temperature bar, writes sensors.csv, and prints
#              a summary of the curve.
#
#   --soak     Run two concurrent iperf3 loops, one per band/client, for
#              DURATION (default 86400 s, 24 h).  Record per-cycle
#              throughput, tx retries, PER, new firmware SER lines and
#              reconnects; a leg whose client drops keeps waiting and resumes
#              when the station reassociates.  An AP reboot ends the run
#              because the harness lives on the AP; re-running with the same
#              --out records the new boot id and the gap in the data.
#
# Load:
#   --thermal  iperf3 from the AP to --client-ip (--streams, default 1; use
#              --streams 4 for a 4SS full-load run) and/or --cpu-load PCT.
#              With neither, the thermal path samples the ambient state and
#              prints throughput 0.
#   --soak     iperf3 only, both clients concurrently, --direction down
#              (AP transmits) by default.
#
# Data sources (found by device name, never by a fixed hwmon index):
#   cpu temp   /sys/class/thermal/thermal_zone*/type == cpu-thermal
#   radio temp /sys/class/hwmon/hwmon*/name == mt7996_phy* (temp1_input)
#   fan        /sys/class/hwmon/hwmon*/name == nct7802 (pwm1..3, fan1_input)
#   cpufreq    /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
#   throttle   cpufreq/mt7996 cooling_device* cur_state, mt7996 throttle1,
#              and new dmesg lines matching the throttle set
#   txpower    iw dev IFACE info
#   retries    iw dev IFACE station dump: tx retries / tx failed / tx packets
#   SER        new dmesg lines matching the MT7996 recovery set
#   reboot     /proc/sys/kernel/random/boot_id and /proc/uptime
#
# Definitions:
#   PER is tx failed / tx packets * 100 from the mac80211 station counters.
#   tx failed is "dropped after the retry limit"; tx retries is not an error
#   and is reported as a retry rate.  Both are AP-side counters, so they are
#   most meaningful with --direction down.  A client reboot cannot be told
#   apart from a plain disconnect: both appear as an association outage, a
#   failed cycle and a resumed leg.
#
# Safety:
#   * Default is read-only.  No sysfs, UCI, module or firmware write happens
#     unless --apply is passed together with --fan-pwm or --txpower.  The
#     harness never writes UCI, loads modules or touches firmware.
#   * --apply writes are snapshotted first and restored from the
#     EXIT/INT/TERM/HUP trap.  The summary compares before and after and
#     names any mismatch.
#   * netwatchdog: an already-active hold is left active; otherwise the
#     harness takes the hold for the run and releases it on exit.  The hold
#     file is the watchdog's own /tmp/netwatchdog.hold state.
#   * Every load process and iperf3 client is tracked in a pid file and
#     killed by the trap.
#   * --dry-run resolves and prints the plan without sampling, sending
#     traffic, changing the hold, applying writes or creating files.
#
# Exit status:
#   0  completed, or a dry run
#   1  setup/run failure (the trap still restores what it changed)
#   2  invalid arguments
#   130 / 143 / 129  interrupted by INT / TERM / HUP
#
# POSIX sh (busybox ash on OpenWrt).  Verified with sh -n, shellcheck -s sh,
# dry runs and short runs on an XR1710G, plus deterministic iw/iperf3 stubs.
#
# Examples:
#   # 60 s dry run: resolves everything, changes nothing.
#   sh scripts/wireless/thermal-soak.sh --thermal --duration 60 --dry-run
#
#   # 10 min read-only curve with 4 iperf3 streams and 50% CPU load.
#   sh scripts/wireless/thermal-soak.sh --thermal --duration 600 \
#       --iface phy0.2-ap0 --client f8:fe:5e:a1:6f:a8 \
#       --client-ip 192.168.1.236 --streams 4 --cpu-load 50
#
#   # 24 h soak, 2.4 GHz and 5 GHz clients (or 5 GHz + 6 GHz on a board
#   # whose 2.4 GHz radio is disabled).
#   sh scripts/wireless/thermal-soak.sh --soak \
#       --iface-a phy0-ap0 --client-a 00:11:22:33:44:55 \
#       --client-ip-a 192.168.1.50 \
#       --iface-b phy0.1-ap0 --client-b 66:77:88:99:aa:bb \
#       --client-ip-b 192.168.1.51
#
#   # Two-minute soak smoke test.
#   sh scripts/wireless/thermal-soak.sh --soak --duration 120 \
#       --iperf-time 20 --iface-a ... --client-ip-a ... \
#       --iface-b ... --client-ip-b ...
#
#   # Fan/txpower writes need --apply; both are restored by the trap.
#   sh scripts/wireless/thermal-soak.sh --thermal --duration 300 --apply \
#       --fan-pwm 255 --txpower 20 --client-ip 192.168.1.236

set -u

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Defaults.  Every value can also come from the environment.
# ---------------------------------------------------------------------------
MODE=
DURATION=
INTERVAL=${INTERVAL:-10}
IPERF_TIME=
IPERF_GAP=${IPERF_GAP:-5}
STREAMS=${STREAMS:-1}
CPU_LOAD=${CPU_LOAD:-0}
DIRECTION=${DIRECTION:-down}
ASSOC_POLL=${ASSOC_POLL:-5}

IFACE_A=${IFACE_A:-}
IFACE_B=${IFACE_B:-}
BAND_A=${BAND_A:-}
BAND_B=${BAND_B:-}
CLIENT_A=${CLIENT_A:-}
CLIENT_B=${CLIENT_B:-}
IP_A=${IP_A:-}
IP_B=${IP_B:-}

FAN_PWM=${FAN_PWM:-}
TXPOWER=${TXPOWER:-}
APPLY=${APPLY:-0}
DRY_RUN=${DRY_RUN:-0}
OUT=${OUT:-}

# Runtime state.
RUN=
RUN_ID=
RUN_BOOT=
START_EPOCH=0
RUN_END=0
INTERRUPTED=
CLEANED=0
REBOOTS=0
SAMPLES=0

THERMAL=
THERMAL_TYPE=
FAN=
CPU_CDEVS=
WIFI_CDEVS=
WIFI_HWMONS=

IPERF3_BIN=
IPERF3_CONNECT_TIMEOUT=0

HOLD_PRIOR=
HOLD_TAKEN=0
HOLD_TOOK=0
HOLD_FAILED=0
FAN_APPLIED=0
TXP_APPLIED=0

DMESG_OK=0
DMESG_BASE_THR=0
DMESG_BASE_SER=0
LAST_TS=0
THR_DMESG_TOTAL=0
SER_TOTAL=0

# Previous station-counter state for the per-sample throughput column.
PRE_A_BYTES=
PRE_A_TS=
PRE_B_BYTES=
PRE_B_TS=
MAC_A=
MAC_B=

# Values filled by sample_sensors().
S_TIME=na
S_EPOCH=na
S_ELAPSED=na
S_UPTIME=na
S_BOOT=na
S_TCPU=na
S_TW0=na
S_TW1=na
S_TW2=na
S_FREQ=na
S_FREQMAX=na
S_GOV=na
S_PWM1=na
S_PWM1E=na
S_PWM2=na
S_PWM3=na
S_RPM=na
S_TXPA=na
S_TXPB=na
S_RATE_A=na
S_RATE_B=na
S_ASSOC_A=na
S_ASSOC_B=na
S_CDEVCPU=na
S_WIFITHR=na
S_WIFI_CDEV=0
S_THRCPU=0
S_THRWIFI=0
S_THRDMESG=0
S_THROTTLE=0
S_NEW_THR=0
S_NEW_SER=0

SENSORS_HEADER='time,epoch,elapsed_s,uptime_s,boot_id,t_cpu_c,t_wifi0_c,t_wifi1_c,t_wifi2_c,freq_mhz,freq_max_mhz,governor,fan_pwm1,fan_pwm1_enable,fan_pwm2,fan_pwm3,fan_rpm,txpower_a_dbm,throughput_a_mbps,assoc_a,txpower_b_dbm,throughput_b_mbps,assoc_b,cdev_cpu,wifi_throttle,thr_cpu,thr_wifi,thr_dmesg,throttle,ser_total,hold,run'
CYCLES_HEADER='time,epoch,elapsed_s,leg,iface,client,cycle,ok,assoc,throughput_mbps,src,seconds,retries,tx_packets,tx_failed,per_pct,retry_pct,outage_s,err,run'

# dmesg classifiers.  Both are POSIX ERE and deliberately narrow: a soak log
# must not fill with unrelated warnings.
THROTTLE_RE='throttl|thermal.*(trip|critical|hot)|over.?temp|temperature.*(high|critical)|cpufreq.*(cool|limit)|cooling.*(state|device)'
SER_RE='SER recovery|system error recovery|chip full reset|HW recovery|fw recovery|firmware recovery|firmware.*(assert|failed|timeout)|Timeout for (initializing )?firmware'

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------
say() {
	printf '%s\n' "$*"
}

note() {
	printf '%s: %s\n' "$PROG" "$*" >&2
}

die() {
	note "$*"
	exit 1
}

usage_error() {
	note "$*"
	note "run '$PROG --help' for usage"
	exit 2
}

is_uint() {
	case ${1-} in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

is_mac() {
	printf '%s' "${1-}" | grep -Eiq \
		'^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$'
}

# Normalise a validated unsigned integer so later arithmetic never treats it
# as octal.  (busybox ash expands "08" as an invalid octal number.)
norm_uint() {
	awk -v v="$1" 'BEGIN { printf "%d", v }'
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

iso_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

hms_utc() {
	date -u '+%H:%M:%S'
}

now_epoch() {
	date +%s
}

read_uint_or_na() {
	if [ -r "$1" ]; then
		v=$(cat "$1" 2>/dev/null)
		case $v in
		'' | *[!0-9]*) echo na ;;
		*) echo "$v" ;;
		esac
	else
		echo na
	fi
}

read_temp_c_or_na() {
	if [ -r "$1" ]; then
		v=$(cat "$1" 2>/dev/null)
		case $v in
		'' | *[!0-9-]*) echo na ;;
		*) awk -v m="$v" 'BEGIN { printf "%.1f", m / 1000 }' ;;
		esac
	else
		echo na
	fi
}

csv_clean() {
	printf '%s' "${1-}" | tr -d '\r\n' | tr ',' ';' | cut -c1-200
}

# ---------------------------------------------------------------------------
# Usage.
# ---------------------------------------------------------------------------
usage() {
	cat <<'EOF'
Usage: thermal-soak.sh --thermal|--soak [options]

Thermal/throughput curve and 24 h soak harness for the XR1710G (MT7996).
Read-only by default: no sysfs, UCI, module or firmware write is made unless
--apply is passed with --fan-pwm or --txpower.

Modes (exactly one is required):
  --thermal             Run the configured load and print a thermal curve.
  --soak                Run two concurrent iperf3 loops, one per band/client.

Common options:
  --duration SEC        Run window.  Default 600 (thermal) / 86400 (soak).
  --interval SEC        Sensor sample period.  Default 10.
  --iperf-time SEC      iperf3 cycle length.  Default 30 thermal / 60 soak.
  --iperf-gap SEC       Idle gap between iperf3 cycles.  Default 5.
  --streams N           iperf3 parallel streams per leg.  Default 1.  Use 4
                        for a 4SS full-load run.
  --direction down|up   down = AP transmits (iperf3 default, the default
                        here); up = AP receives (iperf3 -R).  Down is the
                        direction whose AP-side retries/PER are meaningful.
  --assoc-poll SEC      Reconnect poll interval.  Default 5.
  --out DIR             Evidence directory.  Default
                        /root/thermal-soak.<mode>.<UTC timestamp> (falls back
                        to /tmp when /root is not writable).  Reusing a
                        directory appends a new session and records a changed
                        boot id; a live run's directory is refused.
  --dry-run             Resolve and print the plan only.  No sampling, no
                        traffic, no hold change, no sysfs/UCI write, no files.
  --apply               Allow fan/txpower writes.  Required for --fan-pwm and
                        --txpower.  Writes are snapshotted and restored by the
                        trap.  Requires root.
  --fan-pwm N           With --apply: force nct7802 pwm1..3 to N (0..255) in
                        manual mode for the run, then restore the original
                        PWM values and enable modes.
  --txpower DBM         With --apply: fix the tested interface(s) at DBM,
                        then restore the original value (or "auto" when the
                        original was not a number).  This is a live iw
                        setting, not a UCI change.
  --help                This help.

Thermal load (mode --thermal):
  --iface NAME          AP interface under test.  Default: first up AP,
                        preferring 6 GHz, then 5 GHz, then 2.4 GHz.
  --band NAME           Pick the interface by band (2g, 5g, 6g) instead of
                        naming it.  --iface wins when both are given.
  --client MAC          Station MAC for the counter deltas.
  --client-ip IP        iperf3 server on the client; enables the traffic load.
                        Without --client/--client-ip the thermal run samples
                        ambient state and reports throughput 0.
  --cpu-load PCT        Add PCT (0..100) of CPU load with "yes" workers,
                        one per core step (on a 4-core AP, 10..24 => 0
                        workers, 25 => 1, 50 => 2, 75 => 3, 100 => 4).

Soak legs (mode --soak, both legs are concurrent; one per band/client):
  --iface-a NAME        Leg A AP interface (alias: --iface).
  --iface-b NAME        Leg B AP interface.
  --band-a NAME         Resolve leg A by band (2g, 5g, 6g).
  --band-b NAME         Resolve leg B by band.
  --client-a MAC        Leg A station MAC (alias: --client).
  --client-b MAC        Leg B station MAC.
  --client-ip-a IP      Leg A iperf3 server (required).
  --client-ip-b IP      Leg B iperf3 server (required).

Soak behaviour:
  * Each leg runs iperf3 -c IP -t IPERF_TIME -P STREAMS, waits a gap and
    repeats.  A failed cycle is recorded and retried; if the station has
    disappeared the leg waits (polling --assoc-poll) until it reassociates,
    then resumes.  The other leg keeps running.
  * cycles-a.csv / cycles-b.csv hold one row per cycle: throughput, source,
    tx retries, tx packets, tx failed, PER, retry rate, outage and error.
  * sensors.csv holds the one-per-interval sensor row, including new throttle
    dmesg lines, cumulative new SER lines and the boot id.  New SER lines are
    also copied to ser.log.
  * An AP reboot ends the process.  Restart with the same --out to append a
    new session with a different boot id; the gap and the boot change remain
    visible in the evidence.

Output (all modes):
  sensors.csv           time, thermal, cpufreq, fan PWM/RPM, txpower,
                        throughput, station association, throttle flag,
                        cdev state, SER count, hold state, run id.
  cycles-a.csv         per-cycle traffic record (thermal with --client-ip or
                       soak leg A): throughput, retries, PER and errors.
  cycles-b.csv         soak leg B per-cycle traffic record.
  events.log            holds, reconnects, SER lines, throttle lines, errors.
  ser.log               new firmware recovery dmesg lines.
  summary.txt           final curve/soak summary and restore proof.

Examples:
  sh thermal-soak.sh --thermal --duration 60 --dry-run
  sh thermal-soak.sh --thermal --duration 600 --cpu-load 100
  sh thermal-soak.sh --thermal --duration 600 --iface phy0.2-ap0 \
      --client f8:fe:5e:a1:6f:a8 --client-ip 192.168.1.236 --streams 4
  sh thermal-soak.sh --soak --duration 120 --iperf-time 20 \
      --iface-a phy0.1-ap0 --client-ip-a 192.168.1.50 \
      --iface-b phy0.2-ap0 --client-ip-b 192.168.1.51
  sh thermal-soak.sh --thermal --apply --fan-pwm 255 --txpower 20 \
      --client-ip 192.168.1.236

Exit status: 0 ok/dry run, 1 setup or run failure, 2 usage error,
130/143/129 interrupted by INT/TERM/HUP.

Notes:
  * A 24 h soak writes a few MB to the evidence directory.  Use --out on the
    overlay (/root) so the data survives an AP reboot.
  * Each traffic client must run "iperf3 -s" (TCP 5201 by default).  The
    harness starts the client side on the AP; it does not start servers.
  * The harness reads dmesg; on a system with kernel.dmesg_restrict=1 it must
    run as root, otherwise it warns and records throttle/SER counts as 0.
  * No module, firmware, UCI or permanent configuration change is made.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
need_arg() {
	[ "$#" -ge 2 ] || usage_error "option $1 needs an argument"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--thermal)
			[ -z "$MODE" ] || usage_error "only one of --thermal/--soak"
			MODE=thermal
			;;
		--soak)
			[ -z "$MODE" ] || usage_error "only one of --thermal/--soak"
			MODE=soak
			;;
		--duration)
			need_arg "$@"
			DURATION=$2
			shift
			;;
		--interval)
			need_arg "$@"
			INTERVAL=$2
			shift
			;;
		--iperf-time)
			need_arg "$@"
			IPERF_TIME=$2
			shift
			;;
		--iperf-gap)
			need_arg "$@"
			IPERF_GAP=$2
			shift
			;;
		--streams)
			need_arg "$@"
			STREAMS=$2
			shift
			;;
		--cpu-load)
			need_arg "$@"
			CPU_LOAD=$2
			shift
			;;
		--direction)
			need_arg "$@"
			DIRECTION=$2
			shift
			;;
		--assoc-poll)
			need_arg "$@"
			ASSOC_POLL=$2
			shift
			;;
		--iface)
			need_arg "$@"
			IFACE_A=$2
			shift
			;;
		--iface-a)
			need_arg "$@"
			IFACE_A=$2
			shift
			;;
		--iface-b)
			need_arg "$@"
			IFACE_B=$2
			shift
			;;
		--band)
			need_arg "$@"
			BAND_A=$2
			shift
			;;
		--band-a)
			need_arg "$@"
			BAND_A=$2
			shift
			;;
		--band-b)
			need_arg "$@"
			BAND_B=$2
			shift
			;;
		--client)
			need_arg "$@"
			CLIENT_A=$2
			shift
			;;
		--client-a)
			need_arg "$@"
			CLIENT_A=$2
			shift
			;;
		--client-b)
			need_arg "$@"
			CLIENT_B=$2
			shift
			;;
		--client-ip)
			need_arg "$@"
			IP_A=$2
			shift
			;;
		--client-ip-a)
			need_arg "$@"
			IP_A=$2
			shift
			;;
		--client-ip-b)
			need_arg "$@"
			IP_B=$2
			shift
			;;
		--fan-pwm)
			need_arg "$@"
			FAN_PWM=$2
			shift
			;;
		--txpower)
			need_arg "$@"
			TXPOWER=$2
			shift
			;;
		--apply)
			APPLY=1
			;;
		--dry-run)
			DRY_RUN=1
			;;
		--out)
			need_arg "$@"
			OUT=$2
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			usage_error "unknown option: $1"
			;;
		esac
		shift
	done
}

# ---------------------------------------------------------------------------
# Validation.
# ---------------------------------------------------------------------------
validate() {
	[ -n "$MODE" ] || usage_error "one of --thermal or --soak is required"

	# Defaults that depend on the mode.
	if [ -z "$DURATION" ]; then
		if [ "$MODE" = thermal ]; then
			DURATION=600
		else
			DURATION=86400
		fi
	fi
	if [ -z "$IPERF_TIME" ]; then
		if [ "$MODE" = thermal ]; then
			IPERF_TIME=30
		else
			IPERF_TIME=60
		fi
	fi

	for pair in \
		"duration:$DURATION" \
		"interval:$INTERVAL" \
		"iperf-time:$IPERF_TIME" \
		"iperf-gap:$IPERF_GAP" \
		"streams:$STREAMS" \
		"cpu-load:$CPU_LOAD" \
		"assoc-poll:$ASSOC_POLL"; do
		key=${pair%%:*}
		val=${pair#*:}
		is_uint "$val" || usage_error "--$key must be an unsigned integer, got '$val'"
		val=$(norm_uint "$val")
		case $key in
		duration) DURATION=$val ;;
		interval) INTERVAL=$val ;;
		iperf-time) IPERF_TIME=$val ;;
		iperf-gap) IPERF_GAP=$val ;;
		streams) STREAMS=$val ;;
		cpu-load) CPU_LOAD=$val ;;
		assoc-poll) ASSOC_POLL=$val ;;
		esac
	done

	[ "$DURATION" -gt 0 ] || usage_error "--duration must be greater than 0"
	[ "$INTERVAL" -gt 0 ] || usage_error "--interval must be greater than 0"
	[ "$IPERF_TIME" -gt 0 ] || usage_error "--iperf-time must be greater than 0"
	[ "$STREAMS" -gt 0 ] || usage_error "--streams must be greater than 0"
	[ "$ASSOC_POLL" -gt 0 ] || usage_error "--assoc-poll must be greater than 0"
	[ "$CPU_LOAD" -le 100 ] || usage_error "--cpu-load must be 0..100"

	case "$DIRECTION" in
	down | up) ;;
	*) usage_error "--direction must be down or up, got '$DIRECTION'" ;;
	esac

	for pair in "band-a:$BAND_A" "band-b:$BAND_B"; do
		case ${pair#*:} in
		'' | 2g | 5g | 6g) ;;
		*) usage_error "--${pair%%:*} must be 2g, 5g or 6g" ;;
		esac
	done

	for pair in "client-a:$CLIENT_A" "client-b:$CLIENT_B"; do
		val=${pair#*:}
		[ -z "$val" ] || is_mac "$val" ||
			usage_error "--${pair%%:*} is not a MAC address: '$val'"
	done

	if [ -n "$FAN_PWM" ]; then
		is_uint "$FAN_PWM" || usage_error "--fan-pwm must be 0..255"
		FAN_PWM=$(norm_uint "$FAN_PWM")
		[ "$FAN_PWM" -le 255 ] || usage_error "--fan-pwm must be 0..255"
		if [ "$APPLY" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
			usage_error "--fan-pwm needs --apply; refusing to write"
		fi
	fi
	if [ -n "$TXPOWER" ]; then
		is_uint "$TXPOWER" || usage_error "--txpower must be a whole dBm value"
		TXPOWER=$(norm_uint "$TXPOWER")
		[ "$TXPOWER" -le 40 ] || usage_error "--txpower must be 0..40 dBm"
		if [ "$APPLY" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
			usage_error "--txpower needs --apply; refusing to write"
		fi
	fi
	if [ "$APPLY" -eq 1 ] && [ "$(id -u)" != 0 ]; then
		usage_error "--apply needs root"
	fi

	if [ "$MODE" = thermal ]; then
		[ -z "$IP_B" ] || usage_error "--client-ip-b is soak-only"
		[ -z "$CLIENT_B" ] || usage_error "--client-b is soak-only"
		[ -z "$IFACE_B" ] || usage_error "--iface-b is soak-only"
		[ -z "$BAND_B" ] || usage_error "--band-b is soak-only"
		if [ "$CPU_LOAD" -eq 0 ] && [ -z "$IP_A" ] && [ -z "$FAN_PWM" ] && [ -z "$TXPOWER" ]; then
			note "no traffic (--client-ip) and no --cpu-load: thermal run samples ambient state only"
		fi
	else
		if [ "$CPU_LOAD" -ne 0 ]; then
			usage_error "--cpu-load is thermal-only"
		fi
		if [ "$DRY_RUN" -eq 0 ]; then
			[ -n "$IP_A" ] || usage_error "--soak needs --client-ip-a (leg A)"
			[ -n "$IP_B" ] || usage_error "--soak needs --client-ip-b (leg B)"
		fi
	fi

	if [ -z "$OUT" ]; then
		if [ -d /root ] && [ -w /root ]; then
			OUT=/root/thermal-soak.$MODE.$(date -u '+%Y%m%dT%H%M%S').$$
		else
			OUT=/tmp/thermal-soak.$MODE.$(date -u '+%Y%m%dT%H%M%S').$$
		fi
	fi
}

# ---------------------------------------------------------------------------
# Sensor discovery.
# ---------------------------------------------------------------------------
find_thermal_zone() {
	THERMAL=
	THERMAL_TYPE=
	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/type" ] || continue
		t=$(cat "$z/type" 2>/dev/null)
		if [ "$t" = cpu-thermal ]; then
			THERMAL=$z
			THERMAL_TYPE=$t
			return 0
		fi
		if [ -z "$THERMAL" ]; then
			THERMAL=$z
			THERMAL_TYPE=$t
		fi
	done
	[ -n "$THERMAL" ]
}

find_fan_hwmon() {
	FAN=
	for h in /sys/class/hwmon/hwmon*; do
		[ -r "$h/name" ] || continue
		[ "$(cat "$h/name" 2>/dev/null)" = nct7802 ] || continue
		FAN=$h
		return 0
	done
	# Fallback: any hwmon that exposes both a PWM and a tach.
	for h in /sys/class/hwmon/hwmon*; do
		[ -r "$h/pwm1" ] && [ -r "$h/fan1_input" ] || continue
		FAN=$h
		return 0
	done
	return 1
}

find_wifi_hwmons() {
	WIFI_HWMONS=
	for h in /sys/class/hwmon/hwmon*; do
		[ -r "$h/name" ] || continue
		n=$(cat "$h/name" 2>/dev/null)
		case "$n" in
		mt7996* | mt76*) WIFI_HWMONS="$WIFI_HWMONS $h" ;;
		esac
	done
	[ -n "$WIFI_HWMONS" ]
}

find_cooling_devices() {
	CPU_CDEVS=
	WIFI_CDEVS=
	for c in /sys/class/thermal/cooling_device*; do
		[ -r "$c/type" ] || continue
		t=$(cat "$c/type" 2>/dev/null)
		case "$t" in
		cpufreq*) CPU_CDEVS="$CPU_CDEVS $c" ;;
		mt7996* | mt76*) WIFI_CDEVS="$WIFI_CDEVS $c" ;;
		esac
	done
}

setup_sensors() {
	find_thermal_zone || true
	find_fan_hwmon || true
	find_wifi_hwmons || true
	find_cooling_devices || true
}

# ---------------------------------------------------------------------------
# Interface and station helpers.
# ---------------------------------------------------------------------------
iw_present() {
	command_exists iw
}

all_ap_ifaces() {
	iw dev 2>/dev/null | awk '
		/^[ \t]*Interface / { iface = $2 }
		/^[ \t]+type AP/ { if (iface != "") print iface }
	' | sort -u
}

iface_freq_mhz() {
	iw dev "$1" info 2>/dev/null |
		sed -n 's/.*(\([0-9][0-9]*\) MHz).*/\1/p' |
		head -1
}

band_of_freq() {
	f=$1
	if [ "$f" -lt 3000 ]; then
		echo 2g
	elif [ "$f" -lt 5925 ]; then
		echo 5g
	else
		echo 6g
	fi
}

iface_band() {
	f=$(iface_freq_mhz "$1")
	[ -n "$f" ] || {
		echo unknown
		return 0
	}
	band_of_freq "$f"
}

iface_is_ap() {
	iw dev "$1" info 2>/dev/null | grep -q 'type AP'
}

iface_txpower_dbm() {
	v=$(iw dev "$1" info 2>/dev/null | awk '/txpower/ { print $2; exit }')
	case "$v" in
	'' | off) echo na ;;
	*) echo "$v" ;;
	esac
}

resolve_iface_by_band() {
	band=$1
	for i in $(all_ap_ifaces); do
		[ "$(iface_band "$i")" = "$band" ] || continue
		echo "$i"
		return 0
	done
	return 1
}

pick_thermal_iface() {
	for b in 6g 5g 2g; do
		i=$(resolve_iface_by_band "$b") || continue
		echo "$i"
		return 0
	done
	return 1
}

pick_soak_a_iface() {
	for b in 2g 5g 6g; do
		i=$(resolve_iface_by_band "$b") || continue
		echo "$i"
		return 0
	done
	return 1
}

pick_soak_b_iface() {
	skip_band=$1
	for b in 6g 5g 2g; do
		[ "$b" = "$skip_band" ] && continue
		i=$(resolve_iface_by_band "$b") || continue
		echo "$i"
		return 0
	done
	return 1
}

# Resolve the configured interfaces before the run and fill BAND_A/BAND_B.
resolve_interfaces() {
	if [ -z "$IFACE_A" ]; then
		if [ -n "$BAND_A" ] && iw_present; then
			IFACE_A=$(resolve_iface_by_band "$BAND_A") ||
				note "warning: no AP interface on band $BAND_A"
		elif iw_present; then
			if [ "$MODE" = thermal ]; then
				IFACE_A=$(pick_thermal_iface) || note "warning: no AP interface found"
			else
				IFACE_A=$(pick_soak_a_iface) || note "warning: no AP interface found"
			fi
		fi
	fi
	if [ -n "$IFACE_A" ]; then
		if iw_present && ! iface_is_ap "$IFACE_A"; then
			note "warning: $IFACE_A is not an AP interface"
		fi
		[ -n "$BAND_A" ] || BAND_A=$(iface_band "$IFACE_A")
	fi

	if [ "$MODE" = soak ]; then
		if [ -z "$IFACE_B" ]; then
			if [ -n "$BAND_B" ] && iw_present; then
				IFACE_B=$(resolve_iface_by_band "$BAND_B") ||
					note "warning: no AP interface on band $BAND_B"
			elif iw_present; then
				IFACE_B=$(pick_soak_b_iface "${BAND_A:-unknown}") ||
					note "warning: no second-band AP interface found"
			fi
		fi
		if [ -n "$IFACE_B" ]; then
			[ -n "$BAND_B" ] || BAND_B=$(iface_band "$IFACE_B")
		fi
	fi

	if [ "$MODE" = soak ] && [ -n "$IFACE_A" ] && [ -n "$IFACE_B" ] &&
		[ "$IFACE_A" = "$IFACE_B" ]; then
		usage_error "soak legs A and B resolve to the same interface ($IFACE_A)"
	fi
	if [ "$MODE" = soak ] && [ -n "$BAND_A" ] && [ -n "$BAND_B" ] &&
		[ "$BAND_A" != unknown ] && [ "$BAND_B" != unknown ] &&
		[ "$BAND_A" = "$BAND_B" ]; then
		if [ "$DRY_RUN" -eq 0 ]; then
			usage_error "soak needs two different bands; both legs are $BAND_A"
		else
			note "warning: soak legs are both on band $BAND_A"
		fi
	fi
}

station_field() {
	iface=$1
	mac=$2
	field=$3
	iw dev "$iface" station dump 2>/dev/null | awk -v mac="$mac" -v field="$field" '
		BEGIN { want = tolower(mac) }
		$1 == "Station" {
			cur = tolower($2)
			on = (cur == want)
		}
		on && $0 ~ field {
			sub(/^[^:]*:[ \t]*/, "")
			print
			exit
		}
	'
}

station_present() {
	iface=$1
	mac=$2
	[ -n "$mac" ] || return 1
	iw dev "$iface" station dump 2>/dev/null | awk -v mac="$mac" '
		BEGIN { want = tolower(mac) }
		$1 == "Station" && tolower($2) == want { found = 1 }
		END { exit(found ? 0 : 1) }
	'
}

resolve_mac_for_ip() {
	ip=$1
	[ -n "$ip" ] || return 1
	command_exists ip || return 1
	ip neigh show "$ip" 2>/dev/null | awk '
		{ for (i = 1; i <= NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }
	'
}

refresh_macs() {
	if [ -z "$MAC_A" ] && [ -n "$IP_A" ]; then
		MAC_A=$(resolve_mac_for_ip "$IP_A") || MAC_A=
	fi
	if [ -z "$MAC_B" ] && [ -n "$IP_B" ]; then
		MAC_B=$(resolve_mac_for_ip "$IP_B") || MAC_B=
	fi
}

# ---------------------------------------------------------------------------
# netwatchdog hold.
# ---------------------------------------------------------------------------
netwatchdog_present() {
	command_exists netwatchdog
}

nw_hold_state() {
	if [ -e /tmp/netwatchdog.hold ]; then
		echo on
	elif netwatchdog_present; then
		echo off
	else
		echo missing
	fi
}

nw_hold_on() {
	if ! netwatchdog_present; then
		note "warning: netwatchdog not found; cannot hold the reboot watchdog"
		HOLD_FAILED=1
		return 1
	fi
	if [ "$(nw_hold_state)" = on ]; then
		HOLD_TOOK=0
		return 0
	fi
	# Set the taken flag before the command so an interrupt between the write
	# and the next line still leads cleanup to release the hold.
	HOLD_TAKEN=1
	if ! netwatchdog hold on >/dev/null 2>&1; then
		HOLD_TAKEN=0
		note "warning: netwatchdog hold on failed"
		HOLD_FAILED=1
		return 1
	fi
	HOLD_TOOK=1
	echo "[$(iso_utc)] hold: taken (was off)" >>"$RUN/events.log"
	return 0
}

nw_hold_release() {
	[ "$HOLD_TAKEN" -eq 1 ] || return 0
	if netwatchdog_present && netwatchdog hold off >/dev/null 2>&1; then
		echo "[$(iso_utc)] hold: released (restored to off)" >>"$RUN/events.log"
	else
		note "warning: netwatchdog hold off failed"
		echo "[$(iso_utc)] hold: release FAILED" >>"$RUN/events.log"
	fi
	HOLD_TAKEN=0
}

# ---------------------------------------------------------------------------
# Optional --apply writes (fan and txpower), always restored by the trap.
# ---------------------------------------------------------------------------
fan_snapshot() {
	[ -n "$FAN" ] || die "--apply needs an nct7802 fan hwmon; none found"
	: >"$RUN/fan.orig"
	for k in pwm1 pwm1_enable pwm2 pwm2_enable pwm3 pwm3_enable; do
		v=$(read_uint_or_na "$FAN/$k")
		printf '%s=%s\n' "$k" "$v" >>"$RUN/fan.orig"
	done
}

fan_orig() {
	sed -n "s/^$1=//p" "$RUN/fan.orig" 2>/dev/null | head -1
}

fan_apply() {
	[ -n "$FAN_PWM" ] || return 0
	fan_snapshot
	# Set the flag before the first write: if a signal arrives mid-apply the
	# trap still knows it has to restore.
	FAN_APPLIED=1
	for i in 1 2 3; do
		[ -e "$FAN/pwm$i" ] || continue
		printf '%s\n' 1 >"$FAN/pwm${i}_enable" 2>/dev/null || true
		printf '%s\n' "$FAN_PWM" >"$FAN/pwm$i" 2>/dev/null || true
	done
	echo "[$(iso_utc)] apply: fan pwm=$FAN_PWM" >>"$RUN/events.log"
}

fan_restore() {
	[ "$FAN_APPLIED" -eq 1 ] || return 0
	for i in 1 2 3; do
		v=$(fan_orig "pwm$i")
		[ -n "$v" ] && [ "$v" != na ] && [ -e "$FAN/pwm$i" ] &&
			printf '%s\n' "$v" >"$FAN/pwm$i" 2>/dev/null
	done
	for i in 1 2 3; do
		v=$(fan_orig "pwm${i}_enable")
		[ -n "$v" ] && [ "$v" != na ] && [ -e "$FAN/pwm${i}_enable" ] &&
			printf '%s\n' "$v" >"$FAN/pwm${i}_enable" 2>/dev/null
	done
	echo "[$(iso_utc)] apply: fan restored" >>"$RUN/events.log"
}

txp_snapshot() {
	iface=$1
	file=$2
	txpower_dbm=$(iface_txpower_dbm "$iface")
	printf '%s\n' "$txpower_dbm" >"$file"
}

txp_apply() {
	[ -n "$TXPOWER" ] || return 0
	for pair in "a:$IFACE_A" "b:$IFACE_B"; do
		tag=${pair%%:*}
		iface=${pair#*:}
		[ -n "$iface" ] || continue
		[ "$MODE" = thermal ] && [ "$tag" = b ] && continue
		txp_snapshot "$iface" "$RUN/txp.$tag.orig"
		TXP_APPLIED=1
		if ! iw dev "$iface" set txpower fixed "$((TXPOWER * 100))" >/dev/null 2>&1; then
			die "iw dev $iface set txpower fixed ${TXPOWER}00 failed"
		fi
		echo "[$(iso_utc)] apply: txpower $iface fixed $TXPOWER dBm" >>"$RUN/events.log"
	done
}

txp_restore() {
	[ "$TXP_APPLIED" -eq 1 ] || return 0
	for pair in "a:$IFACE_A" "b:$IFACE_B"; do
		tag=${pair%%:*}
		iface=${pair#*:}
		file=$RUN/txp.$tag.orig
		[ -n "$iface" ] && [ -f "$file" ] || continue
		v=$(head -1 "$file")
		if [ "$v" = na ]; then
			iw dev "$iface" set txpower auto >/dev/null 2>&1 || true
		else
			iw dev "$iface" set txpower fixed "$(awk -v d="$v" 'BEGIN { printf "%d", d * 100 }')" \
				>/dev/null 2>&1 || true
		fi
	done
	echo "[$(iso_utc)] apply: txpower restored" >>"$RUN/events.log"
}

# Report whether the fan and txpower values actually came back.
restore_check() {
	FAN_RESTORE=na
	TXP_RESTORE=na
	if [ "$FAN_APPLIED" -eq 1 ]; then
		FAN_RESTORE=ok
		# For an automatic channel the live PWM follows the temperature, so
		# only its enable mode is comparable; manual channels keep their PWM.
		for k in pwm1 pwm2 pwm3; do
			en_want=$(fan_orig "${k}_enable")
			en_have=$(read_uint_or_na "$FAN/${k}_enable")
			if [ -n "$en_want" ] && [ "$en_want" != na ] && [ "$en_want" != "$en_have" ]; then
				FAN_RESTORE="mismatch:${k}_enable=$en_want->$en_have"
			fi
			if [ "$en_want" = 1 ]; then
				want=$(fan_orig "$k")
				have=$(read_uint_or_na "$FAN/$k")
				if [ -n "$want" ] && [ "$want" != na ] && [ "$want" != "$have" ]; then
					FAN_RESTORE="mismatch:$k=$want->$have"
				fi
			fi
		done
	fi
	if [ "$TXP_APPLIED" -eq 1 ]; then
		TXP_RESTORE=ok
		for pair in "a:$IFACE_A" "b:$IFACE_B"; do
			tag=${pair%%:*}
			iface=${pair#*:}
			file=$RUN/txp.$tag.orig
			[ -n "$iface" ] && [ -f "$file" ] || continue
			want=$(head -1 "$file")
			have=$(iface_txpower_dbm "$iface")
			if [ "$want" != na ] && [ "$want" != "$have" ]; then
				TXP_RESTORE="mismatch:$iface=$want->$have"
			fi
		done
	fi
}

# ---------------------------------------------------------------------------
# dmesg scanning.
# ---------------------------------------------------------------------------
dmesg_readable() {
	dmesg >/dev/null 2>&1
}

init_dmesg_marker() {
	DMESG_OK=0
	LAST_TS=0
	if ! dmesg_readable; then
		note "warning: dmesg is not readable (kernel.dmesg_restrict?); throttle/SER dmesg counts will stay 0"
		return 1
	fi
	DMESG_OK=1
	DMESG_BASE_THR=$(dmesg 2>/dev/null | grep -Eic "$THROTTLE_RE" || true)
	DMESG_BASE_SER=$(dmesg 2>/dev/null | grep -Eic "$SER_RE" || true)
	[ -n "$DMESG_BASE_THR" ] || DMESG_BASE_THR=0
	[ -n "$DMESG_BASE_SER" ] || DMESG_BASE_SER=0
	LAST_TS=$(dmesg 2>/dev/null | awk '
		match($0, /^\[ *[0-9]+\.[0-9]+\]/) {
			ts = substr($0, 2, RLENGTH - 2) + 0
			if (ts > mx) mx = ts
		}
		END { printf "%.6f", mx }
	')
	[ -n "$LAST_TS" ] || LAST_TS=0
	return 0
}

# Read only lines newer than LAST_TS; update LAST_TS; count and log matches.
scan_dmesg_new() {
	S_NEW_THR=0
	S_NEW_SER=0
	[ "$DMESG_OK" -eq 1 ] || return 0

	newfile=$RUN/dmesg.new
	tsfile=$RUN/dmesg.ts
	dmesg 2>/dev/null | awk -v last="$LAST_TS" -v tsf="$tsfile" '
		BEGIN { mx = last }
		match($0, /^\[ *[0-9]+\.[0-9]+\]/) {
			ts = substr($0, 2, RLENGTH - 2) + 0
			if (ts > last + 0.0000005) {
				print
				if (ts > mx) mx = ts
			}
			next
		}
		{ if (last == 0) print }
		END { printf "%.6f", mx > tsf }
	' >"$newfile"
	LAST_TS=$(cat "$tsfile" 2>/dev/null)
	[ -n "$LAST_TS" ] || LAST_TS=0

	if [ -s "$newfile" ]; then
		S_NEW_THR=$(grep -Eic "$THROTTLE_RE" "$newfile" || true)
		S_NEW_SER=$(grep -Eic "$SER_RE" "$newfile" || true)
		[ -n "$S_NEW_THR" ] || S_NEW_THR=0
		[ -n "$S_NEW_SER" ] || S_NEW_SER=0
		if [ "$S_NEW_THR" -gt 0 ]; then
			THR_DMESG_TOTAL=$((THR_DMESG_TOTAL + S_NEW_THR))
			grep -Ei "$THROTTLE_RE" "$newfile" |
				sed "s/^/$(iso_utc) throttle-dmesg: /" >>"$RUN/events.log" || true
		fi
		if [ "$S_NEW_SER" -gt 0 ]; then
			SER_TOTAL=$((SER_TOTAL + S_NEW_SER))
			grep -Ei "$SER_RE" "$newfile" >>"$RUN/ser.log" || true
			grep -Ei "$SER_RE" "$newfile" |
				sed "s/^/$(iso_utc) SER: /" >>"$RUN/events.log" || true
		fi
	fi
	rm -f "$newfile" "$tsfile"
}

# ---------------------------------------------------------------------------
# Sensor sampling.
# ---------------------------------------------------------------------------
sample_thermal() {
	S_TCPU=na
	if [ -n "$THERMAL" ]; then
		S_TCPU=$(read_temp_c_or_na "$THERMAL/temp")
	fi
}

sample_wifi() {
	S_TW0=na
	S_TW1=na
	S_TW2=na
	S_WIFITHR=na
	S_WIFI_CDEV=0
	idx=0
	max_thr=0
	found_thr=0
	for h in $WIFI_HWMONS; do
		t=$(read_temp_c_or_na "$h/temp1_input")
		thr=$(read_uint_or_na "$h/throttle1")
		case $idx in
		0) S_TW0=$t ;;
		1) S_TW1=$t ;;
		2) S_TW2=$t ;;
		esac
		if [ "$thr" != na ]; then
			found_thr=1
			[ "$thr" -gt "$max_thr" ] && max_thr=$thr
		fi
		idx=$((idx + 1))
	done
	[ "$found_thr" -eq 1 ] && S_WIFITHR=$max_thr
	# The cooling-device state is a second, driver-independent signal.
	for c in $WIFI_CDEVS; do
		st=$(read_uint_or_na "$c/cur_state")
		if [ "$st" != na ] && [ "$st" -gt "$S_WIFI_CDEV" ]; then
			S_WIFI_CDEV=$st
		fi
	done
}

sample_cpufreq() {
	S_FREQ=na
	S_FREQMAX=na
	S_GOV=na
	max_cur=0
	max_cap=0
	found=0
	for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
		[ -r "$f" ] || continue
		v=$(cat "$f" 2>/dev/null)
		case $v in '' | *[!0-9]*) continue ;; esac
		found=1
		[ "$v" -gt "$max_cur" ] && max_cur=$v
	done
	if [ "$found" -eq 1 ]; then
		S_FREQ=$((max_cur / 1000))
	fi
	for f in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq \
		/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
		[ -r "$f" ] || continue
		v=$(cat "$f" 2>/dev/null)
		case $v in '' | *[!0-9]*) continue ;; esac
		[ "$v" -gt "$max_cap" ] && max_cap=$v
	done
	if [ "$max_cap" -gt 0 ]; then
		S_FREQMAX=$((max_cap / 1000))
	fi
	if [ -r /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ]; then
		S_GOV=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
	elif [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
		S_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
	fi
	[ -n "$S_GOV" ] || S_GOV=na
}

sample_fan() {
	S_PWM1=na
	S_PWM1E=na
	S_PWM2=na
	S_PWM3=na
	S_RPM=na
	[ -n "$FAN" ] || return 0
	S_PWM1=$(read_uint_or_na "$FAN/pwm1")
	S_PWM1E=$(read_uint_or_na "$FAN/pwm1_enable")
	S_PWM2=$(read_uint_or_na "$FAN/pwm2")
	S_PWM3=$(read_uint_or_na "$FAN/pwm3")
	S_RPM=$(read_uint_or_na "$FAN/fan1_input")
}

sample_cdev_cpu() {
	S_CDEVCPU=0
	any=0
	for c in $CPU_CDEVS; do
		st=$(read_uint_or_na "$c/cur_state")
		[ "$st" = na ] && continue
		any=1
		[ "$st" -gt "$S_CDEVCPU" ] && S_CDEVCPU=$st
	done
	[ "$any" -eq 1 ] || S_CDEVCPU=na
}

sample_sensors() {
	now=$(now_epoch)
	S_TIME=$(iso_utc)
	S_EPOCH=$now
	if [ "$START_EPOCH" -gt 0 ]; then
		S_ELAPSED=$((now - START_EPOCH))
	else
		S_ELAPSED=0
	fi
	S_UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo na)
	S_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo na)

	sample_thermal
	sample_wifi
	sample_cpufreq
	sample_fan
	sample_cdev_cpu

	S_TXPA=na
	[ -n "$IFACE_A" ] && S_TXPA=$(iface_txpower_dbm "$IFACE_A")
	S_TXPB=na
	[ -n "$IFACE_B" ] && S_TXPB=$(iface_txpower_dbm "$IFACE_B")

	S_THRCPU=0
	if [ "$S_CDEVCPU" != na ] && [ "$S_CDEVCPU" -gt 0 ]; then
		S_THRCPU=1
	elif [ "$S_GOV" = performance ] && [ "$S_FREQ" != na ] &&
		[ "$S_FREQMAX" != na ] && [ "$S_FREQ" -lt "$S_FREQMAX" ]; then
		S_THRCPU=1
	fi
	S_THRWIFI=0
	if [ "$S_WIFITHR" != na ] && [ "$S_WIFITHR" -gt 0 ]; then
		S_THRWIFI=1
	fi
	if [ "$S_WIFI_CDEV" -gt 0 ]; then
		S_THRWIFI=1
	fi
	S_THRDMESG=$S_NEW_THR
	S_THROTTLE=0
	if [ "$S_THRCPU" -eq 1 ] || [ "$S_THRWIFI" -eq 1 ] || [ "$S_THRDMESG" -gt 0 ]; then
		S_THROTTLE=1
	fi

	REBOOTS_CHECK
}

# A changed boot id or a non-monotonic uptime is a reboot.  A reboot normally
# kills this process, so this mostly protects against a weird suspend/restore.
REBOOTS_CHECK() {
	if [ -n "$RUN_BOOT" ] && [ "$S_BOOT" != na ] && [ "$S_BOOT" != "$RUN_BOOT" ]; then
		REBOOTS=$((REBOOTS + 1))
		echo "[$(iso_utc)] reboot: boot_id changed $RUN_BOOT -> $S_BOOT" >>"$RUN/events.log"
		RUN_BOOT=$S_BOOT
	fi
}

# Per-sample station throughput.  Counters are the AP's; down uses tx bytes,
# up uses rx bytes.  assoc=0 (no station) reports 0.000, which is what the
# radio is actually carrying.
sample_station() {
	leg=$1
	iface=$2
	mac=$3
	[ -n "$iface" ] || {
		set_station_result "$leg" 0 0.000
		return 0
	}
	[ -n "$mac" ] || mac=$(resolve_mac_for_ip "$( [ "$leg" = a ] && echo "$IP_A" || echo "$IP_B" )")
	case $leg in
	a) MAC_A=$mac ;;
	b) MAC_B=$mac ;;
	esac

	if ! station_present "$iface" "$mac"; then
		set_station_prev "$leg" "" ""
		set_station_result "$leg" 0 0.000
		return 0
	fi

	key='^[ \t]*tx bytes:'
	[ "$DIRECTION" = up ] && key='^[ \t]*rx bytes:'
	cur=$(station_field "$iface" "$mac" "$key" | awk '{ print $1 }')
	now=$(now_epoch)
	prev=$(get_station_prev_bytes "$leg")
	prevt=$(get_station_prev_ts "$leg")

	rate=0.000
	if [ -n "$cur" ] && [ -n "$prev" ] && [ "$cur" -ge "$prev" ] && [ "$now" -gt "$prevt" ]; then
		rate=$(awk -v d=$((cur - prev)) -v s=$((now - prevt)) 'BEGIN { printf "%.3f", d * 8 / s / 1000000 }')
	fi
	set_station_prev "$leg" "$cur" "$now"
	set_station_result "$leg" 1 "$rate"
}

set_station_prev() {
	case $1 in
	a) PRE_A_BYTES=$2 PRE_A_TS=$3 ;;
	b) PRE_B_BYTES=$2 PRE_B_TS=$3 ;;
	esac
}

get_station_prev_bytes() {
	case $1 in
	a) echo "$PRE_A_BYTES" ;;
	b) echo "$PRE_B_BYTES" ;;
	esac
}

get_station_prev_ts() {
	case $1 in
	a) echo "$PRE_A_TS" ;;
	b) echo "$PRE_B_TS" ;;
	esac
}

set_station_result() {
	case $1 in
	a)
		S_ASSOC_A=$2
		S_RATE_A=$3
		;;
	b)
		S_ASSOC_B=$2
		S_RATE_B=$3
		;;
	esac
}

# ---------------------------------------------------------------------------
# CSV writing.
# ---------------------------------------------------------------------------
ensure_csv() {
	file=$1
	header=$2
	if [ -s "$file" ]; then
		first=$(head -1 "$file")
		[ "$first" = "$header" ] ||
			die "column mismatch in $file; use a fresh --out"
	else
		printf '%s\n' "$header" >"$file"
	fi
}

append_sensors() {
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$S_TIME" "$S_EPOCH" "$S_ELAPSED" "$S_UPTIME" "$S_BOOT" \
		"$S_TCPU" "$S_TW0" "$S_TW1" "$S_TW2" \
		"$S_FREQ" "$S_FREQMAX" "$S_GOV" \
		"$S_PWM1" "$S_PWM1E" "$S_PWM2" "$S_PWM3" "$S_RPM" \
		"$S_TXPA" "$S_RATE_A" "$S_ASSOC_A" \
		"$S_TXPB" "$S_RATE_B" "$S_ASSOC_B" \
		"$S_CDEVCPU" "$S_WIFITHR" \
		"$S_THRCPU" "$S_THRWIFI" "$S_THRDMESG" "$S_THROTTLE" "$SER_TOTAL" \
		"$(nw_hold_state)" "$RUN_ID" \
		>>"$RUN/sensors.csv"
}

append_cycle() {
	# time, epoch, elapsed, leg, iface, client, cycle, ok, assoc,
	# throughput, src, seconds, retries, tx_packets, tx_failed, per,
	# retry, outage, err, run
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" \
		"${11}" "${12}" "${13}" "${14}" "${15}" "${16}" "${17}" "${18}" \
		"${19}" "${20}" >>"$RUN/cycles-$4.csv"
}

# ---------------------------------------------------------------------------
# Printing.
# ---------------------------------------------------------------------------
print_thermal_header() {
	printf 'elapsed time(UTC)   cpuC  wifi0  wifi1  wifi2    MHz  pwm1 pwm2 pwm3    rpm  txdBm   Mbps  T  curve(40..100C)\n'
}

print_thermal_row() {
	if [ "$S_TCPU" = na ]; then
		bar=
	else
		n=$(awk -v t="$S_TCPU" 'BEGIN { n = int((t - 40) * 30 / 60); if (n < 0) n = 0; if (n > 30) n = 30; print n }')
		bar=$(printf '%*s' "$n" '' | tr ' ' '#')
	fi
	printf '%6ss %s %6s %6s %6s %6s %6s %5s %4s %4s %6s %6s %6s %2s |%s\n' \
		"$S_ELAPSED" "$(hms_utc)" "$S_TCPU" "$S_TW0" "$S_TW1" "$S_TW2" \
		"$S_FREQ" "$S_PWM1" "$S_PWM2" "$S_PWM3" "$S_RPM" "$S_TXPA" \
		"$S_RATE_A" "$S_THROTTLE" "$bar"
}

print_soak_header() {
	printf 'elapsed time(UTC)   cpuC wifiMax    MHz    rpm  txA/txB     MbpsA/B  assocA/B  thr SER\n'
}

print_soak_row() {
	wmax=$S_TW0
	if [ "$S_TW1" != na ] && { [ "$wmax" = na ] || [ "$S_TW1" -gt "$wmax" ]; }; then wmax=$S_TW1; fi
	if [ "$S_TW2" != na ] && { [ "$wmax" = na ] || [ "$S_TW2" -gt "$wmax" ]; }; then wmax=$S_TW2; fi
	printf '%6ss %s %6s %6s %6s %6s %7s/%7s %6s/%6s %4s/%4s %3s %s\n' \
		"$S_ELAPSED" "$(hms_utc)" "$S_TCPU" "$wmax" "$S_FREQ" "$S_RPM" \
		"$S_TXPA" "$S_TXPB" "$S_RATE_A" "$S_RATE_B" "$S_ASSOC_A" "$S_ASSOC_B" \
		"$S_THROTTLE" "$SER_TOTAL"
}

# ---------------------------------------------------------------------------
# Child process tracking.  Every background child is written to a pid file so
# the trap can kill it even when the shell is interrupted.
# ---------------------------------------------------------------------------
bg_start() {
	tag=$1
	shift
	"$@" &
	BG_PID=$!
	mkdir -p "$RUN/pids" 2>/dev/null || true
	printf '%s\n' "$BG_PID" >"$RUN/pids/$tag.$BG_PID"
}

bg_start_redir() {
	tag=$1
	out=$2
	err=$3
	shift 3
	"$@" >"$out" 2>"$err" &
	BG_PID=$!
	mkdir -p "$RUN/pids" 2>/dev/null || true
	printf '%s\n' "$BG_PID" >"$RUN/pids/$tag.$BG_PID"
}

bg_wait() {
	pid=$1
	wait "$pid"
	rc=$?
	return "$rc"
}

# Sleep in the background so a signal is delivered immediately instead of
# after a long integer sleep returns.
sleep_int() {
	secs=$1
	bg_start sleep sleep "$secs"
	bg_wait "$BG_PID"
	rm -f "$RUN/pids/sleep.$BG_PID"
}

stop_children() {
	[ -n "$RUN" ] && [ -d "$RUN/pids" ] || return 0
	killed=0
	for f in "$RUN"/pids/*; do
		[ -f "$f" ] || continue
		pid=$(cat "$f" 2>/dev/null)
		case $pid in '' | *[!0-9]*) continue ;; esac
		if kill "$pid" 2>/dev/null; then
			killed=$((killed + 1))
		fi
	done
	[ "$killed" -gt 0 ] && sleep 1
	# A second pass catches children started just before the first sweep and
	# any TERM-ignoring process (iperf3 does not ignore TERM; this is belt and
	# braces for a stuck shell child).
	for f in "$RUN"/pids/*; do
		[ -f "$f" ] || continue
		pid=$(cat "$f" 2>/dev/null)
		case $pid in '' | *[!0-9]*) continue ;; esac
		kill -9 "$pid" 2>/dev/null || true
	done
	rm -f "$RUN/pids"/*
	STOPPED_CHILDREN=$killed
}

# ---------------------------------------------------------------------------
# iperf3 helpers.
# ---------------------------------------------------------------------------
station_counter() {
	station_field "$1" "$2" "$3" | awk '{ print $1 }'
}

iperf_check() {
	IPERF3_BIN=$(command -v iperf3 2>/dev/null || true)
	[ -n "$IPERF3_BIN" ] || return 1
	if iperf3 --help 2>&1 | grep -q 'connect-timeout'; then
		IPERF3_CONNECT_TIMEOUT=1
	fi
	return 0
}

# Parse the first bits_per_second after the named sum object in iperf3 -J.
json_bps() {
	file=$1
	key=$2
	awk -v key="$key" '
		$0 ~ "\"" key "\"[ \t]*:" { blk = 1; next }
		blk && /"bits_per_second"[ \t]*:/ {
			s = $0
			sub(/.*"bits_per_second"[ \t]*:[ \t]*/, "", s)
			sub(/[,}\)].*/, "", s)
			if (s ~ /^[0-9]/) { printf "%.3f", s + 0; found = 1; exit }
		}
		blk && /^[ \t]*\}/ { blk = 0 }
		END { if (!found) exit 1 }
	' "$file"
}

leg_loop() {
	# Run in a subshell; never let the main shell's EXIT trap run here.
	trap - EXIT INT TERM HUP
	leg=$1
	iface=$2
	mac=$3
	ip=$4
	cycle=0

	while :; do
		now=$(now_epoch)
		[ "$now" -lt "$RUN_END" ] || break
		cycle=$((cycle + 1))

		[ -n "$mac" ] || mac=$(resolve_mac_for_ip "$ip")

		if [ -n "$mac" ] && ! station_present "$iface" "$mac"; then
			out_start=$(now_epoch)
			echo "[$(iso_utc)] leg $leg: station $mac not on $iface; waiting for reconnect" >>"$RUN/events.log"
			while [ "$(now_epoch)" -lt "$RUN_END" ]; do
				sleep_int "$ASSOC_POLL"
				station_present "$iface" "$mac" && break
			done
			outage=$(( $(now_epoch) - out_start ))
			echo "[$(iso_utc)] leg $leg: station back after ${outage}s" >>"$RUN/events.log"
			append_cycle "$(iso_utc)" "$(now_epoch)" "$(( $(now_epoch) - START_EPOCH ))" \
				"$leg" "$iface" "$mac" "$cycle" 0 0 na na "$outage" na na na na na "$outage" \
				"association lost" "$RUN_ID"
			continue
		fi

		key='^[ \t]*tx bytes:'
		[ "$DIRECTION" = up ] && key='^[ \t]*rx bytes:'
		pre_time=$(now_epoch)
		pre_bytes=
		pre_retries=
		pre_pkts=
		pre_failed=
		if [ -n "$mac" ]; then
			pre_bytes=$(station_counter "$iface" "$mac" "$key")
			pre_retries=$(station_counter "$iface" "$mac" '^[ \t]*tx retries:')
			pre_pkts=$(station_counter "$iface" "$mac" '^[ \t]*tx packets:')
			pre_failed=$(station_counter "$iface" "$mac" '^[ \t]*tx failed:')
		fi

		t=$IPERF_TIME
		remaining=$((RUN_END - now))
		[ "$t" -gt "$remaining" ] && t=$remaining
		[ "$t" -ge 1 ] || break

		jf="$RUN/raw/$RUN_ID-$leg-$cycle.json"
		ef="$RUN/raw/$RUN_ID-$leg-$cycle.err"
		set -- iperf3 -c "$ip" -t "$t" -P "$STREAMS" -J
		[ "$DIRECTION" = up ] && set -- "$@" -R
		[ "$IPERF3_CONNECT_TIMEOUT" -eq 1 ] && set -- "$@" --connect-timeout 5

		bg_start_redir "iperf-$leg" "$jf" "$ef" "$@"
		pid=$BG_PID
		bg_wait "$pid"
		rc=$?
		rm -f "$RUN/pids/iperf-$leg.$pid"

		post_time=$(now_epoch)
		secs=$((post_time - pre_time))
		[ "$secs" -ge 1 ] || secs=1

		if [ "$DIRECTION" = up ]; then
			bps=$(json_bps "$jf" sum_received) || bps=
		else
			bps=$(json_bps "$jf" sum_sent) || bps=
		fi
		throughput=na
		src=na
		if [ -n "$bps" ] && [ "$bps" != 0 ]; then
			throughput=$(awk -v b="$bps" 'BEGIN { printf "%.3f", b / 1000000 }')
			src=iperf
		fi

		# L2 fallback from the AP-side byte counter when the JSON is
		# unavailable; throughput stays "na" without an association.
		post_bytes=
		assoc=0
		if [ -n "$mac" ] && station_present "$iface" "$mac"; then
			assoc=1
			post_bytes=$(station_counter "$iface" "$mac" "$key")
			if [ "$throughput" = na ] && [ -n "$pre_bytes" ] && [ -n "$post_bytes" ] &&
				[ "$post_bytes" -ge "$pre_bytes" ]; then
				throughput=$(awk -v d=$((post_bytes - pre_bytes)) -v s="$secs" \
					'BEGIN { printf "%.3f", d * 8 / s / 1000000 }')
				src=sta
			fi
		fi

		# Per-cycle deltas.  Counters reset when a station reconnects, so a
		# decrease is reported as "na" instead of a negative rate.
		retries=na
		pkts=na
		failed=na
		per=na
		retry_pct=na
		if [ "$assoc" -eq 1 ] && [ -n "$pre_retries" ] && [ -n "$pre_pkts" ] &&
			[ -n "$pre_failed" ]; then
			post_retries=$(station_counter "$iface" "$mac" '^[ \t]*tx retries:')
			post_pkts=$(station_counter "$iface" "$mac" '^[ \t]*tx packets:')
			post_failed=$(station_counter "$iface" "$mac" '^[ \t]*tx failed:')
			if [ -n "$post_retries" ] && [ -n "$post_pkts" ] && [ -n "$post_failed" ] &&
				[ "$post_retries" -ge "$pre_retries" ] &&
				[ "$post_pkts" -ge "$pre_pkts" ] &&
				[ "$post_failed" -ge "$pre_failed" ]; then
				retries=$((post_retries - pre_retries))
				pkts=$((post_pkts - pre_pkts))
				failed=$((post_failed - pre_failed))
				per=$(awk -v f="$failed" -v p="$pkts" \
					'BEGIN { if (p > 0) printf "%.3f", 100 * f / p; else printf "na" }')
				retry_pct=$(awk -v r="$retries" -v p="$pkts" \
					'BEGIN { if (p > 0) printf "%.3f", 100 * r / p; else printf "na" }')
			fi
		fi

		ok=0
		err=
		if [ "$rc" -eq 0 ] && [ "$src" = iperf ]; then
			ok=1
		else
			if [ -s "$ef" ]; then
				err=$(sed -n '1p' "$ef" | cut -c1-160)
			fi
			[ -n "$err" ] || err="iperf3 rc=$rc"
			err=$(csv_clean "$err")
			echo "[$(iso_utc)] leg $leg cycle $cycle failed: $err" >>"$RUN/events.log"
		fi

		append_cycle "$(iso_utc)" "$post_time" "$((post_time - START_EPOCH))" \
			"$leg" "$iface" "$mac" "$cycle" "$ok" "$assoc" \
			"$throughput" "$src" "$secs" "$retries" "$pkts" "$failed" \
			"$per" "$retry_pct" "" "$err" "$RUN_ID"

		if [ "$ok" -eq 1 ]; then
			rm -f "$jf" "$ef"
		else
			rm -f "$jf"
		fi

		sleep_int "$IPERF_GAP"
	done
}

start_cpu_load() {
	[ "$CPU_LOAD" -gt 0 ] || return 0
	ncpu=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
	[ -n "$ncpu" ] && [ "$ncpu" -gt 0 ] || ncpu=1
	workers=$((CPU_LOAD * ncpu / 100))
	i=0
	while [ "$i" -lt "$workers" ]; do
		if command_exists yes; then
			bg_start_redir cpu /dev/null /dev/null yes
		else
			bg_start_redir cpu /dev/null /dev/null sh -c 'while :; do :; done'
		fi
		i=$((i + 1))
	done
	echo "[$(iso_utc)] load: cpu $CPU_LOAD% (${workers}/${ncpu} workers)" >>"$RUN/events.log"
}

# ---------------------------------------------------------------------------
# Run setup and cleanup.
# ---------------------------------------------------------------------------
prepare_run_dir() {
	mkdir -p "$OUT/raw" "$OUT/pids" 2>/dev/null ||
		die "cannot create output directory $OUT"
	# Refuse to share a directory with a live run.
	for f in "$OUT"/pids/*; do
		[ -f "$f" ] || continue
		pid=$(cat "$f" 2>/dev/null)
		case $pid in '' | *[!0-9]*) continue ;; esac
		if kill -0 "$pid" 2>/dev/null; then
			die "$OUT is in use by live pid $pid; use a fresh --out"
		fi
	done
	rm -f "$OUT"/pids/*
	RUN=$OUT
}

setup_run() {
	START_EPOCH=$(now_epoch)
	RUN_ID="$START_EPOCH-$$"
	RUN_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo na)
	RUN_END=$((START_EPOCH + DURATION))

	if [ -f "$RUN/runs.log" ]; then
		prev_boot=$(sed -n 's/.*boot_id=\([^ ]*\).*/\1/p' "$RUN/runs.log" | tail -1)
		if [ -n "$prev_boot" ] && [ "$prev_boot" != "$RUN_BOOT" ]; then
			echo "[$(iso_utc)] reboot: new session boot_id $prev_boot -> $RUN_BOOT (previous run ended)" \
				>>"$RUN/events.log"
		fi
	fi
	printf 'run=%s start=%s mode=%s boot_id=%s uptime=%s iface_a=%s iface_b=%s duration=%s\n' \
		"$RUN_ID" "$(iso_utc)" "$MODE" "$RUN_BOOT" \
		"$(cut -d. -f1 /proc/uptime 2>/dev/null || echo na)" \
		"${IFACE_A:--}" "${IFACE_B:--}" "$DURATION" >>"$RUN/runs.log"

	ensure_csv "$RUN/sensors.csv" "$SENSORS_HEADER"
	if [ -n "$IP_A" ]; then
		ensure_csv "$RUN/cycles-a.csv" "$CYCLES_HEADER"
	fi
	if [ "$MODE" = soak ]; then
		ensure_csv "$RUN/cycles-b.csv" "$CYCLES_HEADER"
	fi
	: >>"$RUN/events.log"
	: >>"$RUN/ser.log"
}

print_hold_report() {
	before=${1-}
	after=$(nw_hold_state)
	case "$before" in
	on) say "hold: before=on after=$after (already held; left unchanged)" ;;
	off)
		if [ "$HOLD_TOOK" -eq 1 ]; then
			if [ "$after" = off ]; then
				say "hold: before=off after=off (taken for the run and released)"
			else
				say "hold: before=off after=$after (WARNING: not back to off)"
			fi
		elif [ "$HOLD_FAILED" -eq 1 ]; then
			say "hold: before=off after=$after (WARNING: hold could not be taken)"
		else
			say "hold: before=off after=$after"
		fi
		;;
	missing) say "hold: netwatchdog not present (nothing to hold or restore)" ;;
	*) say "hold: before=$before after=$after" ;;
	esac
}

apply_restore_report() {
	restore_check
	if [ "$FAN_APPLIED" -eq 1 ]; then
		say "apply fan: pwm=$FAN_PWM; restore=$FAN_RESTORE"
	fi
	if [ "$TXP_APPLIED" -eq 1 ]; then
		say "apply txpower: restore=$TXP_RESTORE"
	fi
	if [ "$FAN_APPLIED" -eq 0 ] && [ "$TXP_APPLIED" -eq 0 ]; then
		say "apply: none (read-only run)"
	fi
}

summary_window() {
	file=$1
	run=$2
	first=$(awk -F, -v run="$run" 'NR > 1 && $32 == run { print $2; exit }' "$file" 2>/dev/null)
	last=$(awk -F, -v run="$run" '$32 == run { last = $2 } END { print last }' "$file" 2>/dev/null)
	if is_uint "$first" && is_uint "$last" && [ "$last" -ge "$first" ]; then
		echo $((last - first))
	else
		echo 0
	fi
}

thermal_summary() {
	sensors=$RUN/sensors.csv
	window=$(summary_window "$sensors" "$RUN_ID")

	awk -F, -v window="$window" -v run="$RUN_ID" '
		function num(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ ? v + 0 : "" }
		NR == 1 { next }
		$32 != run { next }
		{
			v = num($6); if (v != "") { if (tn == 0 || v < tmin) tmin = v; if (tn == 0 || v > tmax) tmax = v; tsum += v; tn++ }
			for (i = 7; i <= 9; i++) { v = num($i); if (v != "") { if (wn == 0 || v > wmax) wmax = v; wn++ } }
			v = num($10); if (v != "") { if (fn == 0 || v < fmin) fmin = v; if (fn == 0 || v > fmax) fmax = v; fn++ }
			v = num($11); if (v != "") { if (cn == 0 || v > cap) cap = v; cn++ }
			v = num($17); if (v != "") { if (rn == 0 || v < rmin) rmin = v; if (rn == 0 || v > rmax) rmax = v; rn++ }
			v = num($13); if (v != "") { if (pn == 0 || v < pmin) pmin = v; if (pn == 0 || v > pmax) pmax = v; pn++ }
			v = num($19); if (v != "") { qsum += v; qn++; if (v > qmax) qmax = v }
			if ($29 == 1) thr++
			ser = $30
			samples++
		}
		END {
			printf "samples: %d over %ds\n", samples, window
			if (tn) printf "cpu-thermal: min %.1f C max %.1f C avg %.1f C\n", tmin, tmax, tsum / tn
			else print "cpu-thermal: na"
			if (wn) printf "mt7996: max %.1f C\n", wmax
			else print "mt7996: na"
			if (fn) printf "cpufreq: min %d MHz max %d MHz (cap %d MHz)\n", fmin, fmax, (cn ? cap : fmax)
			else print "cpufreq: na"
			if (rn) printf "fan: min %d RPM max %d RPM\n", rmin, rmax
			else print "fan: na"
			if (pn) printf "fan pwm1: min %d max %d\n", pmin, pmax
			if (qn) printf "throughput (station): avg %.1f Mbps max %.1f Mbps\n", qsum / qn, qmax
			else print "throughput (station): na"
			printf "throttle: %d/%d samples had the flag\n", thr, samples
			printf "firmware SER: %d new line(s)\n", ser
		}
	' "$sensors"
	if [ -n "$IP_A" ]; then
		cycles_summary a
	fi
}

cycles_summary() {
	leg=$1
	file=$RUN/cycles-$leg.csv
	[ -f "$file" ] || {
		say "leg $leg: no cycles"
		return 0
	}
	awk -F, -v leg="$leg" -v run="$RUN_ID" '
		function num(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ ? v + 0 : "" }
		NR == 1 { next }
		$20 != run { next }
		NF >= 19 {
			c++
			if ($8 == 1) {
				ok++
				v = num($10); if (v != "") { qsum += v; qn++; if (v > qmax) qmax = v }
				s = num($12); if (s != "") secs += s
			} else {
				bad++
			}
			if ($9 == 1) {
				r = num($13); if (r != "") retries += r
				p = num($14); if (p != "") pkts += p
				f = num($15); if (f != "") failed += f
			} else {
				outages++
				o = num($18); if (o != "") outage += o
			}
			if ($11 == "sta") stas++
		}
		END {
			printf "leg %s: cycles=%d ok=%d fail=%d", leg, c, ok, bad
			if (qn) printf " avg=%.1f Mbps max=%.1f", qsum / qn, qmax
			else printf " avg=na max=na"
			printf " seconds=%d retries=%d tx_packets=%d tx_failed=%d", secs, retries, pkts, failed
			if (pkts > 0) printf " PER=%.3f%% retry=%.3f%%", 100 * failed / pkts, 100 * retries / pkts
			else printf " PER=na retry=na"
			if (outages) printf " outages=%d outage_s=%d", outages, outage
			else printf " outages=0 outage_s=0"
			if (stas) printf " sta_fallback=%d", stas
			printf "\n"
		}
	' "$file"
}

soak_summary() {
	sensors=$RUN/sensors.csv
	window=$(summary_window "$sensors" "$RUN_ID")

	awk -F, -v window="$window" -v run="$RUN_ID" '
		function num(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ ? v + 0 : "" }
		NR == 1 { next }
		$32 != run { next }
		{
			v = num($6); if (v != "") { if (tn == 0 || v < tmin) tmin = v; if (tn == 0 || v > tmax) tmax = v; tsum += v; tn++ }
			for (i = 7; i <= 9; i++) { v = num($i); if (v != "") { if (wn == 0 || v > wmax) wmax = v; wn++ } }
			v = num($10); if (v != "") { if (fn == 0 || v < fmin) fmin = v; if (fn == 0 || v > fmax) fmax = v; fn++ }
			v = num($11); if (v != "") { if (cn == 0 || v > cap) cap = v; cn++ }
			v = num($17); if (v != "") { if (rn == 0 || v < rmin) rmin = v; if (rn == 0 || v > rmax) rmax = v; rn++ }
			if ($29 == 1) thr++
			ser = $30
			boot = $5
			samples++
		}
		END {
			printf "samples: %d over %ds\n", samples, window
			if (tn) printf "cpu-thermal: min %.1f C max %.1f C avg %.1f C\n", tmin, tmax, tsum / tn
			else print "cpu-thermal: na"
			if (wn) printf "mt7996: max %.1f C\n", wmax
			if (fn) printf "cpufreq: min %d MHz max %d MHz (cap %d MHz)\n", fmin, fmax, (cn ? cap : fmax)
			if (rn) printf "fan: min %d RPM max %d RPM\n", rmin, rmax
			printf "throttle: %d/%d samples had the flag\n", thr, samples
			printf "firmware SER: %d new line(s)\n", ser
			printf "last boot_id: %s\n", boot
		}
	' "$sensors"
	say "reboots: $REBOOTS in-run (an AP reboot ends the harness; restart with the same --out to record the new boot id)"
	cycles_summary a
	if [ "$MODE" = soak ]; then
		cycles_summary b
	fi
}

write_summary() {
	[ -n "$RUN" ] && [ -d "$RUN" ] || return 0
	reason=${INTERRUPTED:+signal:}${INTERRUPTED:-duration}
	{
		printf '%s summary\n' "$(iso_utc)"
		printf 'mode=%s duration=%ss run=%s reason=%s\n' "$MODE" "$DURATION" "$RUN_ID" "$reason"
		printf 'iface_a=%s band_a=%s client_a=%s ip_a=%s\n' "${IFACE_A:--}" "${BAND_A:--}" "${CLIENT_A:--}" "${IP_A:--}"
		if [ "$MODE" = soak ]; then
			printf 'iface_b=%s band_b=%s client_b=%s ip_b=%s\n' "${IFACE_B:--}" "${BAND_B:--}" "${CLIENT_B:--}" "${IP_B:--}"
		fi
		printf 'interval=%ss iperf_time=%ss iperf_gap=%ss streams=%s direction=%s cpu_load=%s%%\n' \
			"$INTERVAL" "$IPERF_TIME" "$IPERF_GAP" "$STREAMS" "$DIRECTION" "$CPU_LOAD"
		printf 'dmesg: readable=%s baseline_throttle=%s baseline_ser=%s new_throttle=%s new_ser=%s\n' \
			"$DMESG_OK" "$DMESG_BASE_THR" "$DMESG_BASE_SER" "$THR_DMESG_TOTAL" "$SER_TOTAL"
		if [ "$MODE" = thermal ]; then
			thermal_summary
		else
			soak_summary
		fi
		apply_restore_report
		if [ "$HOLD_TOOK" -eq 1 ]; then
			if [ "$(nw_hold_state)" = off ]; then
				hold_action=took-and-released
			else
				hold_action=took-release-failed
			fi
		elif [ "$HOLD_PRIOR" = missing ]; then
			hold_action=netwatchdog-missing
		elif [ "$HOLD_FAILED" -eq 1 ]; then
			hold_action=take-failed
		else
			hold_action=unchanged
		fi
		printf 'hold: before=%s after=%s action=%s\n' "${HOLD_PRIOR:-unknown}" \
			"$(nw_hold_state)" "$hold_action"
		printf 'streams killed by trap: %s\n' "${STOPPED_CHILDREN:-0}"
		printf 'data: %s\n' "$RUN"
	} >"$RUN/summary.txt"
	cat "$RUN/summary.txt"

	printf 'run=%s end=%s reason=%s samples=%s new_ser=%s\n' \
		"$RUN_ID" "$(iso_utc)" "$reason" "$SAMPLES" "$SER_TOTAL" >>"$RUN/runs.log"
}

cleanup() {
	[ "$CLEANED" -eq 1 ] && return 0
	CLEANED=1
	trap '' INT TERM HUP

	[ -n "$RUN" ] && [ -d "$RUN" ] &&
		echo "[$(iso_utc)] cleanup: reason=${INTERRUPTED:-duration}" >>"$RUN/events.log"
	stop_children
	fan_restore
	txp_restore
	nw_hold_release

	if [ -n "$RUN" ] && [ -d "$RUN" ]; then
		write_summary
		print_hold_report "${HOLD_PRIOR:-unknown}"
	fi
}

# ---------------------------------------------------------------------------
# Dry-run plan.
# ---------------------------------------------------------------------------
plan_common_sensors() {
	if [ -n "$THERMAL" ]; then
		say "sensor thermal: $THERMAL type=$THERMAL_TYPE temp=$(read_temp_c_or_na "$THERMAL/temp") C"
	else
		say "sensor thermal: none (cpu-thermal absent)"
	fi
	if [ -n "$FAN" ]; then
		say "sensor fan: $FAN pwm1=$(read_uint_or_na "$FAN/pwm1") enable=$(read_uint_or_na "$FAN/pwm1_enable") pwm2=$(read_uint_or_na "$FAN/pwm2") pwm3=$(read_uint_or_na "$FAN/pwm3") rpm=$(read_uint_or_na "$FAN/fan1_input")"
	else
		say "sensor fan: none"
	fi
	# shellcheck disable=SC2086
	set -- $WIFI_HWMONS
	say "sensor mt7996: $# hwmon(s)${WIFI_HWMONS:+ ->}${WIFI_HWMONS}"
	say "sensor cpufreq: $([ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ] && echo present || echo absent)"
}

plan_load() {
	if [ "$MODE" = thermal ]; then
		if [ -n "$IP_A" ]; then
			say "load traffic: iperf3 $STREAMS stream(s) $DIRECTION to $IP_A (${IPERF_TIME}s cycles, ${IPERF_GAP}s gap)"
		else
			say "load traffic: none (no --client-ip; sensor-only run)"
		fi
		ncpu=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
		say "load cpu: ${CPU_LOAD}% -> $((CPU_LOAD * ncpu / 100))/${ncpu} worker(s)"
	else
		say "load traffic: iperf3 $STREAMS stream(s) $DIRECTION, both legs (${IPERF_TIME}s cycles, ${IPERF_GAP}s gap)"
	fi
}

print_plan() {
	say "$PROG: dry run; no sampling, no traffic, no hold change, no writes"
	say "mode=$MODE duration=${DURATION}s interval=${INTERVAL}s"
	if [ -f "$OUT" ]; then
		say "out=$OUT (exists and is not a directory: a real run would fail)"
	elif [ -d "$OUT" ]; then
		say "out=$OUT (would append to the existing evidence)"
	else
		say "out=$OUT (would be created)"
	fi
	plan_common_sensors
	say "iface a: ${IFACE_A:-none} band=${BAND_A:-unknown} freq=$( [ -n "$IFACE_A" ] && iface_freq_mhz "$IFACE_A" || echo na)MHz txpower=$( [ -n "$IFACE_A" ] && iface_txpower_dbm "$IFACE_A" || echo na)dBm"
	if [ "$MODE" = soak ]; then
		say "iface b: ${IFACE_B:-none} band=${BAND_B:-unknown} freq=$( [ -n "$IFACE_B" ] && iface_freq_mhz "$IFACE_B" || echo na)MHz txpower=$( [ -n "$IFACE_B" ] && iface_txpower_dbm "$IFACE_B" || echo na)dBm"
	fi
	plan_load
	if [ -n "$IP_A" ]; then
		say "client a: mac=${CLIENT_A:-auto} ip=$IP_A assoc=$( [ -n "$IFACE_A" ] && [ -n "${CLIENT_A:-}" ] && station_present "$IFACE_A" "$CLIENT_A" && echo yes || echo no/unknown)"
	fi
	if [ "$MODE" = soak ]; then
		[ -n "$IP_B" ] && say "client b: mac=${CLIENT_B:-auto} ip=$IP_B assoc=$( [ -n "$IFACE_B" ] && [ -n "${CLIENT_B:-}" ] && station_present "$IFACE_B" "$CLIENT_B" && echo yes || echo no/unknown)"
	fi
	if [ -n "$IPERF3_BIN" ]; then
		say "iperf3: $IPERF3_BIN (connect-timeout=$IPERF3_CONNECT_TIMEOUT)"
	else
		say "iperf3: MISSING (a real run with traffic would fail)"
	fi
	HOLD_PRIOR=$(nw_hold_state)
	case "$HOLD_PRIOR" in
	on) say "hold: ACTIVE (/tmp/netwatchdog.hold); a real run would leave it active" ;;
	off) say "hold: off; a real run would take netwatchdog hold and release it on exit" ;;
	missing) say "hold: netwatchdog not present; nothing to take or restore" ;;
	esac
	if [ -n "$FAN_PWM" ] || [ -n "$TXPOWER" ]; then
		if [ "$APPLY" -eq 1 ]; then
			say "apply: fan=${FAN_PWM:-unchanged} txpower=${TXPOWER:-unchanged} dBm with --apply (dry run writes nothing)"
		else
			say "apply: fan=${FAN_PWM:-unchanged} txpower=${TXPOWER:-unchanged} dBm without --apply; a real run refuses these and writes nothing"
		fi
	fi
	say "dmesg: readable=$DMESG_OK baseline_throttle=$DMESG_BASE_THR baseline_ser=$DMESG_BASE_SER"
	if [ "$MODE" = soak ] && { [ -z "$IP_A" ] || [ -z "$IP_B" ]; }; then
		say "note: a real soak needs --client-ip-a and --client-ip-b"
	fi
	say "rerun without --dry-run to execute this plan"
}

# ---------------------------------------------------------------------------
# Modes.
# ---------------------------------------------------------------------------
start_traffic() {
	[ -n "$IP_A" ] || return 0
	bg_start_redir "leg-a" "$RUN/raw/leg-a.out" "$RUN/raw/leg-a.err" \
		leg_loop a "$IFACE_A" "$MAC_A" "$IP_A"
	if [ "$MODE" = soak ] && [ -n "$IP_B" ]; then
		bg_start_redir "leg-b" "$RUN/raw/leg-b.out" "$RUN/raw/leg-b.err" \
			leg_loop b "$IFACE_B" "$MAC_B" "$IP_B"
	fi
	return 0
}

sample_iteration() {
	SAMPLES=$((SAMPLES + 1))
	refresh_macs
	scan_dmesg_new
	sample_sensors
	sample_station a "$IFACE_A" "$MAC_A"
	if [ "$MODE" = soak ]; then
		sample_station b "$IFACE_B" "$MAC_B"
	fi
	append_sensors
	if [ "$MODE" = thermal ]; then
		print_thermal_row
	elif [ $((SAMPLES % PRINT_EVERY)) -eq 1 ]; then
		print_soak_row
	fi
}

sample_loop() {
	SAMPLES=0
	PRINT_EVERY=1
	if [ "$MODE" = soak ]; then
		PRINT_EVERY=$((60 / INTERVAL))
		[ "$PRINT_EVERY" -ge 1 ] || PRINT_EVERY=1
	fi

	if [ "$MODE" = thermal ]; then
		print_thermal_header
	else
		print_soak_header
	fi

	sample_iteration
	if [ "$MODE" = thermal ]; then
		start_cpu_load
	fi
	start_traffic

	while [ "$(now_epoch)" -lt "$RUN_END" ]; do
		remaining=$((RUN_END - $(now_epoch)))
		[ "$remaining" -gt 0 ] || break
		[ "$remaining" -gt "$INTERVAL" ] && remaining=$INTERVAL
		sleep_int "$remaining"
		[ "$(now_epoch)" -lt "$RUN_END" ] || break
		sample_iteration
	done
	# Capture the final state at the end of the window before the trap kills
	# the load; this also gives a clean last row for the curve.
	sample_iteration
}

run() {
	if [ "$DRY_RUN" -eq 1 ]; then
		print_plan
		exit 0
	fi

	# Real-run prerequisites.
	[ -n "$IFACE_A" ] || die "no AP interface resolved; pass --iface"
	iw_present || die "iw is required"
	iw dev "$IFACE_A" info >/dev/null 2>&1 ||
		die "interface $IFACE_A not found"
	iface_is_ap "$IFACE_A" || die "$IFACE_A is not an AP interface"
	if [ "$MODE" = soak ]; then
		[ -n "$IFACE_B" ] || die "no second AP interface resolved for soak leg B; pass --iface-b"
		iw dev "$IFACE_B" info >/dev/null 2>&1 ||
			die "interface $IFACE_B not found"
		iface_is_ap "$IFACE_B" || die "$IFACE_B is not an AP interface"
	fi
	if [ -n "$IP_A" ] || [ -n "$IP_B" ]; then
		iperf_check || die "iperf3 is required for the traffic load but was not found"
	fi
	if [ -n "$FAN_PWM" ] || [ -n "$TXPOWER" ]; then
		command_exists iw || die "iw is required for txpower writes"
	fi

	prepare_run_dir
	trap cleanup EXIT
	trap 'INTERRUPTED=INT; exit 130' INT
	trap 'INTERRUPTED=TERM; exit 143' TERM
	trap 'INTERRUPTED=HUP; exit 129' HUP

	setup_run
	HOLD_PRIOR=$(nw_hold_state)
	nw_hold_on || true
	if [ "$HOLD_TAKEN" -eq 1 ]; then
		say "hold: taken for the run (was off); will release at exit"
	elif [ "$HOLD_PRIOR" = on ]; then
		say "hold: ACTIVE before the run; left active"
	elif [ "$HOLD_PRIOR" = missing ]; then
		say "hold: netwatchdog not present"
	elif [ "$HOLD_FAILED" -eq 1 ]; then
		say "hold: WARNING: netwatchdog hold failed; the run is not protected from a watchdog reboot"
	fi

	fan_apply
	txp_apply

	say "$PROG: $MODE run $DURATION s; evidence in $OUT"
	sample_loop
	exit 0
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
main() {
	parse_args "$@"
	validate
	MAC_A=$CLIENT_A
	MAC_B=$CLIENT_B
	setup_sensors
	# Read-only dmesg baseline used by both the dry-run plan and the run.
	init_dmesg_marker || true
	iperf_check || true
	resolve_interfaces
	run
}

main "$@"
