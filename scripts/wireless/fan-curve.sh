#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC3043,SC2329
#
# fan-curve.sh - fan-curve and thermal-headroom A/B harness for the XR1710G.
#
# The XR1710G has a dual fan driven by an NCT7802.  The curve is a five-point
# temperature -> PWM table in /etc/config/fan, applied to the NCT7802 hwmon
# attributes pwm1_auto_point{1..5}_{temp,pwm} by /etc/init.d/fan (the
# luci-app-airoha-fancontrol owner) or by /etc/init.d/airoha_fan (the stock
# curve on minimal images).  There is no fan curve or thermal-headroom data
# for the 6 GHz 4SS load yet, so this harness runs the same fixed load at
# three fan points and records what the SoC does:
#
#   current     the fan configuration that is already in /etc/config/fan
#   aggressive  the performance curve, which ramps earlier and harder
#   quiet       the quiet curve, which allows higher temperatures
#
# Every point runs DURATION seconds of fixed load (CPU workers and,
# optionally, iperf3 streams) and samples the cpu-thermal zone, the fan
# PWM/RPM, cpufreq, interface/station throughput and the throttle signals.
# One row per sample is printed and written to samples.csv, and summary.txt
# holds the per-point curve with the restore proof.
#
# Default is read-only: the script prints the fan configuration, the live
# hwmon state, the curve each point would apply and the load plan, and
# creates nothing.  Nothing is written to sysfs or UCI, and no load is
# started, unless --apply is passed.  With --apply the original
# /etc/config/fan is copied to the evidence directory and the original
# live pwm1_* state is snapshotted before the first write; the
# EXIT/INT/TERM/HUP trap restores both and the summary compares the hashes
# and the attributes afterwards.
#
# The NCT7802 steps its output towards the curve target at one PWM step per
# second (step_up_time/step_down_time are 1000 ms on the XR1710G), so a point
# that starts far from its target can spend most of its load window ramping.
# Applying a curve therefore preloads pwm1, in manual mode, with the curve
# target for the current board temperature before SmartFan is re-enabled.
#
# No fan firmware or kernel module is reloaded.  Only the documented
# nct7802 hwmon attributes are written (the same ones /etc/init.d/fan
# writes, plus that pwm1 preload), and only while --apply is in effect.
#
# Data sources (found by device name, never by a fixed hwmon index):
#   cpu temp   /sys/class/thermal/thermal_zone*/type == cpu-thermal
#   board temp /sys/class/hwmon/hwmon*/name == nct7802 temp1_input
#   fan        /sys/class/hwmon/hwmon*/name == nct7802 pwm1..3, fan1_input,
#              pwm1_auto_point{1..5}_{temp,pwm}
#   radio temp /sys/class/hwmon/hwmon*/name == mt7996_phy* temp1_input
#   cpufreq    /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
#   throttle   cpufreq/mt7996 cooling_device* cur_state, mt7996 throttle1,
#              new dmesg lines matching the throttle set, and a frequency
#              drop below the cap while the load is running
#   throughput /sys/class/net/IFACE/statistics/{rx,tx}_bytes (br-lan by
#              default), or the rx/tx bytes of --client from iw station dump
#   load       "yes" workers for --cpu-load, plus optional iperf3 streams
#
# Exit status:
#   0  completed, or a read-only/dry run
#   1  setup or run failure (the trap still restores what it changed)
#   2  invalid arguments
#   130 / 143 / 129  interrupted by INT / TERM / HUP
#
# POSIX sh (busybox ash on OpenWrt).  Verified with sh -n, shellcheck -s sh,
# read-only runs and real --apply runs on an XR1710G.
#
# Examples:
#   # Read-only: print the fan config, the curves and the plan.
#   sh scripts/wireless/fan-curve.sh
#   sh scripts/wireless/fan-curve.sh --dry-run
#
#   # Real A/B: 60 s per point, 5 s samples, 20 s cool-down, backup+restore.
#   sh scripts/wireless/fan-curve.sh --apply --duration 60 --interval 5
#
#   # 6 GHz 4SS point on a client with iperf3 and a complete station MAC.
#   sh scripts/wireless/fan-curve.sh --apply --duration 300 \
#       --iface phy0.2-ap0 --client 00:11:22:33:44:55 \
#       --iperf-server 192.168.1.50 --streams 4
#
#   # Only two points, no network load.
#   sh scripts/wireless/fan-curve.sh --apply --points current,aggressive \
#       --duration 120
#
#   # Interrupt test: TERM runs the trap and prints the restore proof.
#   sh scripts/wireless/fan-curve.sh --apply --duration 600 &
#   kill -TERM %1

set -u

PROG=${0##*/}
FAN_CONFIG=/etc/config/fan
FAN_HWMON_NAME=nct7802

# ---------------------------------------------------------------------------
# Defaults.  Kept as plain variables so the script works on busybox ash.
# ---------------------------------------------------------------------------
APPLY=0
DRY_RUN=0
POINTS=current,aggressive,quiet
DURATION=120
INTERVAL=5
COOLDOWN=20
SETTLE=5
CPU_LOAD=100
IPERF_SERVER=
IPERF_PORT=5201
STREAMS=1
DIRECTION=down
THRU_IFACE=
CLIENT=
OUT=

# Runtime state.
RUN=
RUN_ID=
POINT_INDEX=0
POINT_COUNT=0
CURRENT_POINT=
CURRENT_PRESET=
SAMPLES=0
CLEANED=0
INTERRUPTED=
LOAD_PIDS=
LOAD_ACTIVE=0
IPERF_PID=
THR_EVENTS=0
DMESG_OK=0
DMESG_THR_BASE=0
THERMAL=
THERMAL_TYPE=
FAN=
WIFI_HWMONS=
CPU_CDEVS=
WIFI_CDEVS=
FAN_CFG_PRESENT=0
FAN_CFG_SHA_BEFORE=
FAN_CFG_SHA_AFTER=
UCI_SHA_BEFORE=
UCI_SHA_AFTER=
FAN_TOUCHED=0
FAN_CONFIG_TOUCHED=0
FAN_RESTORE=none
PREV_IF_BYTES=na
PREV_STA_BYTES=na
PREV_TS=na
IPERF3_BIN=

# Throttle dmesg pattern.  Keep it narrow: a new line here is evidence of the
# kernel reacting to temperature, not ordinary driver chatter.
THR_RE='(throttl|over.?temperature|thermal.*(critical|hot)|cpu.*limited|clock.*limited)'

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
	printf 'Try %s --help\n' "$PROG" >&2
	exit 2
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

now_epoch() {
	date +%s
}

iso_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

hms_utc() {
	date -u '+%H:%M:%S'
}

is_uint() {
	case ${1-} in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

# Normalise a validated integer so busybox ash never treats "08" as octal.
norm_uint() {
	awk -v v="$1" 'BEGIN { printf "%d", v }'
}

# Read a signed integer attribute; anything else becomes "na".
read_num_or_na() {
	if [ -r "$1" ]; then
		v=$(cat "$1" 2>/dev/null)
		case $v in
		'' | *[!0-9-]*) printf 'na\n' ;;
		*) printf '%s\n' "$v" ;;
		esac
	else
		printf 'na\n'
	fi
}

# Read an unsigned attribute such as a PWM or RPM.
read_uint_or_na() {
	if [ -r "$1" ]; then
		v=$(cat "$1" 2>/dev/null)
		case $v in
		'' | *[!0-9]*) printf 'na\n' ;;
		*) printf '%s\n' "$v" ;;
		esac
	else
		printf 'na\n'
	fi
}

# Millidegrees Celsius -> "56.6", or "na".
read_temp_c_or_na() {
	if [ -r "$1" ]; then
		v=$(cat "$1" 2>/dev/null)
		case $v in
		'' | *[!0-9-]*) printf 'na\n' ;;
		*) awk -v m="$v" 'BEGIN { printf "%.1f", m / 1000 }' ;;
		esac
	else
		printf 'na\n'
	fi
}

csv_clean() {
	printf '%s' "${1-}" | tr -d '\r\n' | tr ',' ';' | cut -c1-120
}

# Print a float Mbps value for a byte delta over a second delta.  The caller
# validates both numbers; a zero/negative interval is clamped to one second.
mbps_of() {
	awk -v b="$1" -v s="$2" 'BEGIN {
		if (s <= 0) s = 1
		if (b < 0) b = 0
		printf "%.3f", b * 8 / s / 1000000
	}'
}

# ---------------------------------------------------------------------------
# Usage.
# ---------------------------------------------------------------------------
usage() {
	cat <<'EOF'
Usage: fan-curve.sh [options]

Fan-curve and thermal-headroom A/B harness for the XR1710G (NCT7802 fan).
The script runs the same fixed load at three fan points and records the
thermal, cpufreq, throughput and throttle response of each.

Read-only by default: it prints the fan configuration, the live hwmon state,
the curve each point would apply and the load plan, and changes nothing.
--apply is required to run the load, write the fan curve and restore it.

Fan points (--points, default: current,aggressive,quiet):
  current     leave the fan configuration that is already in /etc/config/fan
              in place; a later point restores it first when the order puts
              current after a curve point
  aggressive  the fan.performance curve (35/45/55/65/75 C ->
              69/95/150/199/255), which ramps earlier and harder
  quiet       the fan.quiet curve (45/55/65/75/85 C ->
              54/69/95/199/255), which allows higher temperatures

Common options:
  --apply               Run the A/B for real: write the fan curve, run the
                        load, and restore the original fan config and hwmon
                        state in the EXIT/INT/TERM/HUP trap.  Requires root.
  --dry-run             Resolve and print the plan only (same as the default
                        read-only mode).  Cannot be combined with --apply.
  --duration SEC        Load time per fan point.  Default 120.
  --interval SEC        Sensor sample period.  Default 5.
  --cooldown SEC        Idle time between points, so the next point starts
                        near the same temperature.  Default 20.
  --settle SEC          Wait after applying a curve before the load starts,
                        so the fan reaches the preloaded PWM.  Default 5.
  --cpu-load PCT        Fixed CPU load, 0..100.  Default 100.  One "yes"
                        worker per whole core step on this 4-core SoC
                        (100 -> 4, 50 -> 2, 10 -> 1, 0 -> none).
  --iperf-server IP     Optional iperf3 server on a client; adds iperf3
                        streams for each point.  Requires iperf3 on the AP.
  --iperf-port PORT     iperf3 server port.  Default 5201.
  --streams N           iperf3 parallel streams per point.  Default 1; use 4
                        for a 6 GHz 4SS run.
  --direction down|up   down = AP transmits (the default); up = AP receives.
  --iface NAME          Throughput interface.  Default br-lan when present,
                        else the first phy*-ap* AP interface.  For a radio
                        test, name the AP interface, e.g. phy0.2-ap0.
  --client MAC          Report the throughput of one station (rx+tx bytes
                        from iw station dump) instead of the whole
                        interface.  Requires --iface.
  --out DIR             Evidence directory.  Default
                        /root/fan-curve.<UTC timestamp>.<pid> (falls back to /tmp
                        when /root is not writable).  The directory must be
                        absent or empty.
  --help, -h            This help.

What --apply writes:
  /etc/config/fan       The selected curve preset and mode=auto, via uci.
                        The original file is copied to
                        <out>/fan.config.orig before the first write.
  nct7802 hwmon         pwm1, pwm1_auto_point{1..4}_pwm,
                        pwm1_auto_point{1..5}_temp and pwm1_enable; the
                        attributes /etc/init.d/fan writes, plus pwm1 in
                        manual mode so the point starts at the curve target
                        for the current board temperature instead of ramping
                        there at one PWM step per second.  The original
                        values are snapshotted to <out>/fan.sysfs.orig.
  Nothing else is written.  No module, firmware or permanent configuration
  change is made; the trap restores both files/attributes and prints the
  before/after hashes.

Evidence files (real run):
  samples.csv           point, phase, time, thermal, cpufreq, fan PWM/RPM,
                        interface and station throughput, throttle flags.
  summary.txt           per-point statistics and the fan restore proof.
  events.log            apply/restore/cooldown/throttle events.
  dmesg.log             new throttle lines from dmesg.
  fan.config.orig       byte copy of the original /etc/config/fan.
  fan.sysfs.orig        original pwm1_* attributes.
  iperf.<point>.log     iperf3 output when --iperf-server is used.

Output columns: point, phase, elapsed, time(UTC), cpuC, boardC, wifiC, MHz,
pwm1, rpm, Mbps, thr.  "thr" is 1 when any throttle source is active
(cpufreq cooling device, mt7996 throttle, a new throttle dmesg line, or a
frequency drop below the cap while the load runs).

Examples:
  sh fan-curve.sh
  sh fan-curve.sh --dry-run
  sh fan-curve.sh --apply --duration 60
  sh fan-curve.sh --apply --points quiet,current --duration 300
  sh fan-curve.sh --apply --duration 300 --iface phy0.2-ap0 \
      --client 00:11:22:33:44:55 --iperf-server 192.168.1.50 --streams 4
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
		--apply)
			APPLY=1
			;;
		--dry-run)
			DRY_RUN=1
			;;
		--points)
			need_arg "$@"
			POINTS=$2
			shift
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
		--cooldown)
			need_arg "$@"
			COOLDOWN=$2
			shift
			;;
		--settle)
			need_arg "$@"
			SETTLE=$2
			shift
			;;
		--cpu-load)
			need_arg "$@"
			CPU_LOAD=$2
			shift
			;;
		--iperf-server)
			need_arg "$@"
			IPERF_SERVER=$2
			shift
			;;
		--iperf-port)
			need_arg "$@"
			IPERF_PORT=$2
			shift
			;;
		--streams)
			need_arg "$@"
			STREAMS=$2
			shift
			;;
		--direction)
			need_arg "$@"
			DIRECTION=$2
			shift
			;;
		--iface)
			need_arg "$@"
			THRU_IFACE=$2
			shift
			;;
		--client)
			need_arg "$@"
			CLIENT=$2
			shift
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

# Validate --points and leave it as a normalised comma-separated list.
normalise_points() {
	seen=
	result=
	old_ifs=$IFS
	IFS=,
	for p in $POINTS; do
		case $p in
		current | aggressive | quiet) ;;
		*) usage_error "--points accepts current, aggressive and quiet, got '$p'" ;;
		esac
		case " $seen " in
		*" $p "*) usage_error "--points names '$p' twice" ;;
		esac
		seen="$seen $p"
		if [ -z "$result" ]; then
			result=$p
		else
			result="$result,$p"
		fi
	done
	IFS=$old_ifs
	[ -n "$result" ] || usage_error "--points must not be empty"
	POINTS=$result
}

is_mac() {
	printf '%s' "${1-}" | grep -Eiq \
		'^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$'
}

validate() {
	[ "$APPLY" -eq 1 ] && [ "$DRY_RUN" -eq 1 ] &&
		usage_error "--apply and --dry-run are mutually exclusive"

	normalise_points

	for pair in \
		"duration:$DURATION" \
		"interval:$INTERVAL" \
		"cooldown:$COOLDOWN" \
		"settle:$SETTLE" \
		"cpu-load:$CPU_LOAD" \
		"iperf-port:$IPERF_PORT" \
		"streams:$STREAMS"; do
		key=${pair%%:*}
		val=${pair#*:}
		is_uint "$val" || usage_error "--$key must be an unsigned integer, got '$val'"
		val=$(norm_uint "$val")
		case $key in
		duration) DURATION=$val ;;
		interval) INTERVAL=$val ;;
		cooldown) COOLDOWN=$val ;;
		settle) SETTLE=$val ;;
		cpu-load) CPU_LOAD=$val ;;
		iperf-port) IPERF_PORT=$val ;;
		streams) STREAMS=$val ;;
		esac
	done

	[ "$DURATION" -gt 0 ] || usage_error "--duration must be greater than 0"
	[ "$INTERVAL" -gt 0 ] || usage_error "--interval must be greater than 0"
	[ "$STREAMS" -gt 0 ] || usage_error "--streams must be greater than 0"
	[ "$IPERF_PORT" -gt 0 ] && [ "$IPERF_PORT" -le 65535 ] ||
		usage_error "--iperf-port must be 1..65535"
	[ "$CPU_LOAD" -le 100 ] || usage_error "--cpu-load must be 0..100"

	case "$DIRECTION" in
	down | up) ;;
	*) usage_error "--direction must be down or up, got '$DIRECTION'" ;;
	esac

	if [ -n "$CLIENT" ]; then
		is_mac "$CLIENT" || usage_error "--client is not a MAC address: '$CLIENT'"
		[ -n "$THRU_IFACE" ] || usage_error "--client needs --iface"
	fi

	if [ -n "$THRU_IFACE" ] && [ ! -d "/sys/class/net/$THRU_IFACE" ]; then
		usage_error "--iface $THRU_IFACE does not exist"
	fi

	if [ "$APPLY" -eq 1 ]; then
		[ "$(id -u 2>/dev/null)" = 0 ] || usage_error "--apply needs root"
		command_exists uci || usage_error "--apply needs uci"
		[ -f "$FAN_CONFIG" ] ||
			usage_error "--apply needs the fan config $FAN_CONFIG (luci-app-airoha-fancontrol)"
		[ "$CPU_LOAD" -gt 0 ] || [ -n "$IPERF_SERVER" ] ||
			usage_error "--apply needs a load: set --cpu-load > 0 or --iperf-server"
	fi

	if [ -z "$OUT" ]; then
		if [ -d /root ] && [ -w /root ]; then
			OUT=/root/fan-curve.$(date -u '+%Y%m%dT%H%M%S').$$
		else
			OUT=/tmp/fan-curve.$(date -u '+%Y%m%dT%H%M%S').$$
		fi
	fi
	if [ -e "$OUT" ] && [ ! -d "$OUT" ]; then
		usage_error "--out $OUT exists and is not a directory"
	fi
	if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
		usage_error "--out $OUT is not empty; use a fresh directory"
	fi
}

# ---------------------------------------------------------------------------
# Hardware discovery.
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
		[ "$(cat "$h/name" 2>/dev/null)" = "$FAN_HWMON_NAME" ] || continue
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
		case "$(cat "$h/name" 2>/dev/null)" in
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
		case "$(cat "$c/type" 2>/dev/null)" in
		cpufreq*) CPU_CDEVS="$CPU_CDEVS $c" ;;
		mt7996* | mt76*) WIFI_CDEVS="$WIFI_CDEVS $c" ;;
		esac
	done
}

find_fan_owner() {
	owner=
	for s in /etc/init.d/fan /etc/init.d/airoha_fan; do
		[ -x "$s" ] || continue
		state=present
		[ -L "/etc/rc.d/S99${s##*/}" ] && state=enabled
		if [ -z "$owner" ]; then
			owner="$s($state)"
		else
			owner="$owner $s($state)"
		fi
	done
	[ -n "$owner" ] || owner=none
	printf '%s\n' "$owner"
}

find_iperf3() {
	IPERF3_BIN=$(command -v iperf3 2>/dev/null || true)
}

setup_sensors() {
	find_thermal_zone || true
	find_fan_hwmon || true
	find_wifi_hwmons || true
	find_cooling_devices || true
	find_iperf3 || true
	[ -f "$FAN_CONFIG" ] && FAN_CFG_PRESENT=1
}

# ---------------------------------------------------------------------------
# Fan config (UCI) and curve helpers.
# ---------------------------------------------------------------------------
uci_get() {
	command_exists uci || return 0
	uci -q get "$1" 2>/dev/null || true
}

fan_mode() {
	uci_get fan.settings.mode
}

fan_preset() {
	uci_get fan.settings.curve_preset
}

fan_manual_pwm() {
	uci_get fan.settings.manual_pwm
}

# Built-in fallback points, used when /etc/config/fan does not carry a preset
# (a minimal image, or a config that only overrides some of the points).  The
# values are the ones shipped by luci-app-airoha-fancontrol.
builtin_point() {
	preset=$1
	idx=$2
	case "$preset" in
	performance) set -- 35 69 45 95 55 150 65 199 75 255 ;;
	quiet) set -- 45 54 55 69 65 95 75 199 85 255 ;;
	balanced) set -- 40 54 50 69 60 95 70 199 80 255 ;;
	*) return 1 ;;
	esac
	while [ "$idx" -gt 1 ]; do
		shift 2
		idx=$((idx - 1))
	done
	printf '%s %s\n' "$1" "$2"
}

point_temp() {
	preset=$1
	idx=$2
	v=$(uci_get "fan.$preset.point${idx}_temp")
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
	else
		p=$(builtin_point "$preset" "$idx" 2>/dev/null || true)
		[ -n "$p" ] && printf '%s\n' "${p%% *}"
	fi
}

point_pwm() {
	preset=$1
	idx=$2
	v=$(uci_get "fan.$preset.point${idx}_pwm")
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
	else
		p=$(builtin_point "$preset" "$idx" 2>/dev/null || true)
		[ -n "$p" ] && printf '%s\n' "${p##* }"
	fi
}

# Print "35C->69 45C->95 ..." for a preset.  Missing UCI points come from the
# built-in table, so a partial config is still displayed completely.
curve_string() {
	preset=$1
	i=1
	out=
	while [ "$i" -le 5 ]; do
		t=$(point_temp "$preset" "$i")
		p=$(point_pwm "$preset" "$i")
		[ -n "$t" ] && [ -n "$p" ] || {
			i=$((i + 1))
			continue
		}
		if [ -z "$out" ]; then
			out="${t}C->${p}"
		else
			out="$out ${t}C->${p}"
		fi
		i=$((i + 1))
	done
	printf '%s\n' "$out"
}

# True when every point of the curve exists in UCI.
curve_in_uci() {
	preset=$1
	i=1
	while [ "$i" -le 5 ]; do
		[ -n "$(uci_get "fan.$preset.point${i}_temp")" ] || return 1
		[ -n "$(uci_get "fan.$preset.point${i}_pwm")" ] || return 1
		i=$((i + 1))
	done
	return 0
}

curve_label() {
	preset=$1
	if curve_in_uci "$preset"; then
		printf 'UCI fan.%s' "$preset"
	else
		printf 'built-in %s (missing UCI points)' "$preset"
	fi
}

# Fill a curve preset from the built-in table when UCI is incomplete.  Only
# called with --apply, and only the missing attributes are added.
ensure_curve_uci() {
	preset=$1
	[ "$FAN_CFG_PRESENT" -eq 1 ] || die "no $FAN_CONFIG to write the $preset curve"
	uci -q get "fan.$preset" >/dev/null 2>&1 || uci set "fan.$preset=curve" ||
		die "uci set fan.$preset failed"
	i=1
	while [ "$i" -le 5 ]; do
		bp=$(builtin_point "$preset" "$i" 2>/dev/null || true)
		bt=${bp%% *}
		bpw=${bp##* }
		if [ -z "$(uci_get "fan.$preset.point${i}_temp")" ] && [ -n "$bt" ]; then
			uci set "fan.$preset.point${i}_temp=$bt" || die "uci set $preset point${i}_temp failed"
		fi
		if [ -z "$(uci_get "fan.$preset.point${i}_pwm")" ] && [ -n "$bpw" ]; then
			uci set "fan.$preset.point${i}_pwm=$bpw" || die "uci set $preset point${i}_pwm failed"
		fi
		i=$((i + 1))
	done
}

# PWM the selected curve maps to at the current board temperature.  The
# NCT7802 steps its output towards the curve target at only one PWM step per
# step_up_time/step_down_time (1 s on this board), so a point that starts far
# from its target would spend most of its load window ramping.  Preload the
# target in manual mode when applying the curve.
curve_target_pwm() {
	preset=$1
	raw=$(read_num_or_na "$FAN/temp1_input")
	[ "$raw" != na ] || return 0
	pts=
	i=1
	while [ "$i" -le 5 ]; do
		t=$(point_temp "$preset" "$i")
		p=$(point_pwm "$preset" "$i")
		[ -n "$t" ] && [ -n "$p" ] || {
			i=$((i + 1))
			continue
		}
		pts="$pts $t:$p"
		i=$((i + 1))
	done
	[ -n "$pts" ] || return 0
	awk -v m="$raw" -v pts="$pts" 'BEGIN {
		n = split(pts, a, " ")
		for (i = 1; i <= n; i++) {
			split(a[i], b, ":")
			T[i] = b[1] + 0
			P[i] = b[2] + 0
		}
		t = m / 1000
		if (t <= T[1]) { printf "%d", P[1]; exit }
		if (t >= T[n]) { printf "%d", P[n]; exit }
		for (i = 1; i < n; i++) {
			if (t >= T[i] && t <= T[i + 1]) {
				v = P[i] + (P[i + 1] - P[i]) * (t - T[i]) / (T[i + 1] - T[i])
				printf "%d", v + 0.5
				exit
			}
		}
		printf "%d", P[n]
	}'
}

# Read the effective curve values from UCI (already guaranteed complete by
# ensure_curve_uci) and write them to the NCT7802 auto-point attributes.
write_curve_sysfs() {
	preset=$1
	[ -n "$FAN" ] || die "no fan hwmon to apply the $preset curve"
	[ -w "$FAN/pwm1_enable" ] || die "$FAN/pwm1_enable is not writable"
	printf '1\n' >"$FAN/pwm1_enable" 2>/dev/null ||
		die "cannot put $FAN/pwm1_enable into manual mode"
	# Latch the target PWM while manual.  This gives the SmartFan a defined
	# starting point instead of a 1 step/s ramp from the previous curve.
	target=$(curve_target_pwm "$preset")
	if [ -n "$target" ] && [ -e "$FAN/pwm1" ]; then
		printf '%s\n' "$target" >"$FAN/pwm1" 2>/dev/null ||
			note "warning: could not preload pwm1=$target"
	fi
	i=1
	while [ "$i" -le 5 ]; do
		t=$(point_temp "$preset" "$i")
		p=$(point_pwm "$preset" "$i")
		case $t in
		'' | *[!0-9]*) die "fan.$preset.point${i}_temp is not an integer: '$t'" ;;
		esac
		case $p in
		'' | *[!0-9]*) die "fan.$preset.point${i}_pwm is not an integer: '$p'" ;;
		esac
		[ "$p" -le 255 ] || die "fan.$preset.point${i}_pwm is out of range: $p"
		if [ -n "$t" ] && [ -e "$FAN/pwm1_auto_point${i}_temp" ]; then
			printf '%s\n' "$((t * 1000))" >"$FAN/pwm1_auto_point${i}_temp" 2>/dev/null ||
				note "warning: could not write pwm1_auto_point${i}_temp"
		fi
		# point 5 PWM is fixed at 255 by the chip; only points 1-4 are writable.
		if [ -n "$p" ] && [ "$i" -lt 5 ] && [ -e "$FAN/pwm1_auto_point${i}_pwm" ]; then
			printf '%s\n' "$p" >"$FAN/pwm1_auto_point${i}_pwm" 2>/dev/null ||
				note "warning: could not write pwm1_auto_point${i}_pwm"
		fi
		i=$((i + 1))
	done
	printf '2\n' >"$FAN/pwm1_enable" 2>/dev/null ||
		die "cannot re-enable automatic mode on $FAN/pwm1_enable"
	echo "[$(iso_utc)] apply: curve $preset -> $FAN (preload pwm1=${target:-na})" >>"$RUN/events.log"
}

# Switch to one of the curve points.  Marks the config and sysfs as dirty
# before the first write so the trap restores them even on a signal.
apply_fan_point() {
	preset=$1
	# Mark both as dirty before the first uci/sysfs write: a signal or an
	# error inside ensure_curve_uci must still run the restore.
	FAN_CONFIG_TOUCHED=1
	FAN_TOUCHED=1
	ensure_curve_uci "$preset"
	cur_mode=$(fan_mode)
	cur_preset=$(fan_preset)
	[ "$cur_mode" = auto ] || uci set 'fan.settings.mode=auto' ||
		die "uci set fan.settings.mode failed"
	[ "$cur_preset" = "$preset" ] || uci set "fan.settings.curve_preset=$preset" ||
		die "uci set fan.settings.curve_preset failed"
	uci commit fan || die "uci commit fan failed"
	write_curve_sysfs "$preset"
}

# ---------------------------------------------------------------------------
# Fan state snapshot, restore and proof.
# ---------------------------------------------------------------------------
fan_sysfs_orig() {
	sed -n "s/^$1=//p" "$RUN/fan.sysfs.orig" 2>/dev/null | head -1
}

snapshot_fan() {
	if [ "$FAN_CFG_PRESENT" -eq 1 ]; then
		cp -p "$FAN_CONFIG" "$RUN/fan.config.orig" ||
			die "cannot copy $FAN_CONFIG to $RUN/fan.config.orig"
		FAN_CFG_SHA_BEFORE=$(sha256sum "$FAN_CONFIG" 2>/dev/null | awk '{ print $1 }')
	else
		FAN_CFG_SHA_BEFORE=absent
	fi
	if command_exists uci; then
		UCI_SHA_BEFORE=$(uci -q show fan 2>/dev/null | sort | md5sum | awk '{ print $1 }')
		UCI_SHA_AFTER=$UCI_SHA_BEFORE
	fi
	FAN_CFG_SHA_AFTER=$FAN_CFG_SHA_BEFORE
	: >"$RUN/fan.sysfs.orig"
	[ -n "$FAN" ] || return 0
	for k in pwm1 pwm1_enable pwm2 pwm2_enable pwm3 pwm3_enable fan1_input temp1_input; do
		printf '%s=%s\n' "$k" "$(read_num_or_na "$FAN/$k")" >>"$RUN/fan.sysfs.orig"
	done
	i=1
	while [ "$i" -le 5 ]; do
		printf 'pwm1_auto_point%s_temp=%s\n' "$i" \
			"$(read_num_or_na "$FAN/pwm1_auto_point${i}_temp")" >>"$RUN/fan.sysfs.orig"
		printf 'pwm1_auto_point%s_pwm=%s\n' "$i" \
			"$(read_num_or_na "$FAN/pwm1_auto_point${i}_pwm")" >>"$RUN/fan.sysfs.orig"
		i=$((i + 1))
	done
}

# Put the sysfs attributes back.  Disable auto mode on each channel first so
# the PWM values and auto points can be written, then restore auto mode last.
write_sysfs_snapshot() {
	[ -n "$FAN" ] || return 0
	for i in 1 2 3; do
		en=$(fan_sysfs_orig "pwm${i}_enable")
		if [ "$en" = na ] || [ -z "$en" ]; then
			continue
		fi
		printf '1\n' >"$FAN/pwm${i}_enable" 2>/dev/null || true
	done
	i=1
	while [ "$i" -le 5 ]; do
		t=$(fan_sysfs_orig "pwm1_auto_point${i}_temp")
		p=$(fan_sysfs_orig "pwm1_auto_point${i}_pwm")
		[ "$t" != na ] && [ -n "$t" ] &&
			printf '%s\n' "$t" >"$FAN/pwm1_auto_point${i}_temp" 2>/dev/null || true
		if [ "$i" -lt 5 ] && [ "$p" != na ] && [ -n "$p" ]; then
			printf '%s\n' "$p" >"$FAN/pwm1_auto_point${i}_pwm" 2>/dev/null || true
		fi
		i=$((i + 1))
	done
	for i in 1 2 3; do
		en=$(fan_sysfs_orig "pwm${i}_enable")
		v=$(fan_sysfs_orig "pwm$i")
		[ "$v" != na ] && [ -n "$v" ] &&
			printf '%s\n' "$v" >"$FAN/pwm$i" 2>/dev/null || true
		[ "$en" != na ] && [ -n "$en" ] &&
			printf '%s\n' "$en" >"$FAN/pwm${i}_enable" 2>/dev/null || true
	done
}

# Compare the live fan config and sysfs state with the snapshot.  Reports
# "ok", "config-mismatch", "sysfs-mismatch:..." or "none".
verify_fan_restore() {
	if [ "$FAN_TOUCHED" -eq 0 ] && [ "$FAN_CONFIG_TOUCHED" -eq 0 ]; then
		FAN_RESTORE=none
		return 0
	fi
	bad=
	if [ "$FAN_CFG_PRESENT" -eq 1 ]; then
		FAN_CFG_SHA_AFTER=$(sha256sum "$FAN_CONFIG" 2>/dev/null | awk '{ print $1 }')
		[ "$FAN_CFG_SHA_BEFORE" = "$FAN_CFG_SHA_AFTER" ] || bad="$bad config-sha"
	else
		[ -f "$FAN_CONFIG" ] && bad="$bad config-created"
		FAN_CFG_SHA_AFTER=absent
	fi
	if command_exists uci; then
		UCI_SHA_AFTER=$(uci -q show fan 2>/dev/null | sort | md5sum | awk '{ print $1 }')
		[ -z "$UCI_SHA_BEFORE" ] || [ "$UCI_SHA_BEFORE" = "$UCI_SHA_AFTER" ] ||
			bad="$bad uci-sha"
	fi
	[ -n "$FAN" ] || {
		[ -n "$bad" ] && FAN_RESTORE=${bad# } || FAN_RESTORE=ok
		return 0
	}
	k=pwm1_enable
	want=$(fan_sysfs_orig "$k")
	have=$(read_uint_or_na "$FAN/$k")
	[ "$want" = na ] || [ "$want" = "$have" ] || bad="$bad $k=$want->$have"
	i=1
	while [ "$i" -le 5 ]; do
		for suffix in temp pwm; do
			k="pwm1_auto_point${i}_${suffix}"
			want=$(fan_sysfs_orig "$k")
			have=$(read_num_or_na "$FAN/$k")
			[ "$want" = na ] || [ "$want" = "$have" ] || bad="$bad $k=$want->$have"
		done
		i=$((i + 1))
	done
	for k in pwm2 pwm3 pwm2_enable pwm3_enable; do
		want=$(fan_sysfs_orig "$k")
		have=$(read_uint_or_na "$FAN/$k")
		[ "$want" = na ] || [ "$want" = "$have" ] || bad="$bad $k=$want->$have"
	done
	if [ -z "$bad" ]; then
		FAN_RESTORE=ok
	else
		FAN_RESTORE="mismatch:${bad}"
	fi
}

restore_fan() {
	[ "$FAN_TOUCHED" -eq 1 ] || {
		verify_fan_restore
		return 0
	}
	echo "[$(iso_utc)] restore: fan config and sysfs" >>"$RUN/events.log"
	if [ "$FAN_CFG_PRESENT" -eq 1 ]; then
		cp -p "$RUN/fan.config.orig" "$FAN_CONFIG" 2>/dev/null ||
			note "warning: could not restore $FAN_CONFIG"
	else
		rm -f "$FAN_CONFIG" 2>/dev/null || true
	fi
	# Discard any staged uci delta left by a signal between uci set and
	# uci commit, then reload the restored file.
	if command_exists uci; then
		uci revert fan >/dev/null 2>&1 || true
	fi
	rm -f /tmp/.uci/fan 2>/dev/null || true
	write_sysfs_snapshot
	FAN_TOUCHED=0
	verify_fan_restore
	echo "[$(iso_utc)] restore: $FAN_RESTORE" >>"$RUN/events.log"
}

# Restore whatever a previous point left in place, e.g. before the "current"
# point when it follows a curve point in --points.
restore_for_current() {
	[ "$FAN_TOUCHED" -eq 1 ] || return 0
	restore_fan
}

# ---------------------------------------------------------------------------
# Load management.
# ---------------------------------------------------------------------------
cpu_count() {
	n=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
	case $n in
	'' | *[!0-9]*) n=1 ;;
	esac
	[ "$n" -gt 0 ] || n=1
	printf '%s\n' "$n"
}

cpu_workers() {
	ncpu=$(cpu_count)
	if [ "$CPU_LOAD" -le 0 ]; then
		printf '0\n'
		return 0
	fi
	printf '%s\n' "$(((CPU_LOAD * ncpu + 99) / 100))"
}

start_cpu_load() {
	workers=$1
	i=0
	while [ "$i" -lt "$workers" ]; do
		if command_exists yes; then
			yes >/dev/null 2>&1 &
		else
			dd if=/dev/zero of=/dev/null >/dev/null 2>&1 &
		fi
		LOAD_PIDS="$LOAD_PIDS $!"
		i=$((i + 1))
	done
}

start_iperf() {
	[ -n "$IPERF_SERVER" ] || return 0
	[ -n "$IPERF3_BIN" ] ||
		die "--iperf-server needs iperf3 on the AP, but iperf3 was not found"
	set --
	if [ "$DIRECTION" = up ]; then
		set -- -R
	fi
	# shellcheck disable=SC2086
	"$IPERF3_BIN" -c "$IPERF_SERVER" -p "$IPERF_PORT" -t "$DURATION" \
		-P "$STREAMS" -i 5 -f m "$@" >"$RUN/iperf.$CURRENT_POINT.log" 2>&1 &
	IPERF_PID=$!
	LOAD_PIDS="$LOAD_PIDS $IPERF_PID"
}

start_load() {
	LOAD_ACTIVE=1
	workers=$(cpu_workers)
	CPU_WORKERS=$workers
	if [ "$workers" -gt 0 ]; then
		start_cpu_load "$workers"
	fi
	start_iperf
	# The load must be visible in the next sample, not the one that started it.
	sleep 1
}

stop_load() {
	[ "$LOAD_ACTIVE" -eq 1 ] || return 0
	# Give iperf3 a moment to finish its final summary when it was due to end
	# at the same time as the point; then stop everything that remains.
	if [ -n "$IPERF_PID" ]; then
		n=0
		while [ "$n" -lt 3 ] && kill -0 "$IPERF_PID" 2>/dev/null; do
			sleep 1
			n=$((n + 1))
		done
	fi
	for pid in $LOAD_PIDS; do
		kill "$pid" 2>/dev/null || true
	done
	sleep 1
	for pid in $LOAD_PIDS; do
		kill -9 "$pid" 2>/dev/null || true
	done
	if [ -n "$IPERF_PID" ]; then
		wait "$IPERF_PID" 2>/dev/null || true
	fi
	for pid in $LOAD_PIDS; do
		wait "$pid" 2>/dev/null || true
	done
	LOAD_PIDS=
	LOAD_ACTIVE=0
	IPERF_PID=
}

# Final iperf3 number from the log: the last "Mbits/sec" line, which is the
# receiver summary when iperf3 completed and the last interval otherwise.
iperf_last_mbps() {
	file=$1
	[ -s "$file" ] || return 0
	awk '
		/Mbits\/sec/ {
			for (i = 1; i <= NF; i++)
				if ($i == "Mbits/sec") v = $(i - 1)
		}
		END { if (v != "") printf "%.3f", v + 0 }
	' "$file"
}

# ---------------------------------------------------------------------------
# Sampling.
# ---------------------------------------------------------------------------
sample_thermal() {
	S_CPU=na
	S_BOARD=na
	if [ -n "$THERMAL" ]; then
		S_CPU=$(read_temp_c_or_na "$THERMAL/temp")
	fi
	if [ -n "$FAN" ]; then
		S_BOARD=$(read_temp_c_or_na "$FAN/temp1_input")
	fi
}

S_WMAX=na
sample_wifi() {
	S_WMAX=na
	S_WIFI_THR=0
	S_WIFI_CDEV=0
	best=
	for h in $WIFI_HWMONS; do
		raw=$(read_num_or_na "$h/temp1_input")
		if [ "$raw" != na ]; then
			if [ -z "$best" ] || [ "$raw" -gt "$best" ]; then
				best=$raw
			fi
		fi
		thr=$(read_uint_or_na "$h/throttle1")
		if [ "$thr" != na ] && [ "$thr" -gt "$S_WIFI_THR" ]; then
			S_WIFI_THR=$thr
		fi
	done
	if [ -n "$best" ]; then
		S_WMAX=$(awk -v m="$best" 'BEGIN { printf "%.1f", m / 1000 }')
	fi
	for c in $WIFI_CDEVS; do
		st=$(read_uint_or_na "$c/cur_state")
		if [ "$st" != na ] && [ "$st" -gt "$S_WIFI_CDEV" ]; then
			S_WIFI_CDEV=$st
		fi
	done
}

S_FREQ=na
S_FREQMAX=na
S_GOV=na
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
	[ "$found" -eq 1 ] && S_FREQ=$((max_cur / 1000))
	for f in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq \
		/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
		[ -r "$f" ] || continue
		v=$(cat "$f" 2>/dev/null)
		case $v in '' | *[!0-9]*) continue ;; esac
		[ "$v" -gt "$max_cap" ] && max_cap=$v
	done
	[ "$max_cap" -gt 0 ] && S_FREQMAX=$((max_cap / 1000))
	if [ -r /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ]; then
		S_GOV=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
	elif [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
		S_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
	fi
	[ -n "$S_GOV" ] || S_GOV=na
}

S_PWM1=na
S_PWM1E=na
S_PWM2=na
S_PWM3=na
S_RPM=na
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

S_CDEVCPU=na
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

dmesg_throttle_lines() {
	dmesg 2>/dev/null | grep -iE "$THR_RE"
}

init_dmesg() {
	DMESG_OK=0
	DMESG_THR_BASE=0
	if dmesg >/dev/null 2>&1; then
		DMESG_OK=1
		DMESG_THR_BASE=$(dmesg_throttle_lines | wc -l | tr -d ' ')
		[ -n "$DMESG_THR_BASE" ] || DMESG_THR_BASE=0
	fi
}

# Append any new throttle lines to dmesg.log and set S_DMESG_THR.
S_DMESG_THR=0
scan_dmesg() {
	S_DMESG_THR=0
	[ "$DMESG_OK" -eq 1 ] || return 0
	cur=$(dmesg_throttle_lines | wc -l | tr -d ' ')
	[ -n "$cur" ] || cur=0
	if [ "$cur" -lt "$DMESG_THR_BASE" ]; then
		# The ring buffer wrapped; the new count is the new baseline rather
		# than evidence of a throttle.
		DMESG_THR_BASE=$cur
		return 0
	fi
	[ "$cur" -gt "$DMESG_THR_BASE" ] || return 0
	n=$((cur - DMESG_THR_BASE))
	dmesg_throttle_lines | tail -n "$n" >>"$RUN/dmesg.log"
	THR_EVENTS=$((THR_EVENTS + n))
	echo "[$(iso_utc)] dmesg: $n new throttle line(s)" >>"$RUN/events.log"
	DMESG_THR_BASE=$cur
	S_DMESG_THR=1
}

iface_bytes() {
	if [ -n "$THRU_IFACE" ] && [ -r "/sys/class/net/$THRU_IFACE/statistics/rx_bytes" ]; then
		rx=$(cat "/sys/class/net/$THRU_IFACE/statistics/rx_bytes" 2>/dev/null)
		tx=$(cat "/sys/class/net/$THRU_IFACE/statistics/tx_bytes" 2>/dev/null)
		case $rx in '' | *[!0-9]*) return 1 ;; esac
		case $tx in '' | *[!0-9]*) return 1 ;; esac
		printf '%s\n' "$((rx + tx))"
		return 0
	fi
	return 1
}

station_bytes() {
	[ -n "$THRU_IFACE" ] && [ -n "$CLIENT" ] || return 1
	command_exists iw || return 1
	iw dev "$THRU_IFACE" station get "$CLIENT" 2>/dev/null | awk '
		/rx bytes:/ { rx = $3 }
		/tx bytes:/ { tx = $3 }
		END {
			gsub(/[^0-9]/, "", rx)
			gsub(/[^0-9]/, "", tx)
			if (rx == "" && tx == "") exit 1
			printf "%d", rx + tx
		}'
}

S_IF_MBPS=na
S_STA_MBPS=na
S_MBPS=na
sample_throughput() {
	now=$(now_epoch)
	S_IF_MBPS=na
	S_STA_MBPS=na
	S_MBPS=na
	if b=$(iface_bytes); then
		if [ "$PREV_IF_BYTES" != na ]; then
			S_IF_MBPS=$(mbps_of "$((b - PREV_IF_BYTES))" "$((now - PREV_TS))")
		fi
		PREV_IF_BYTES=$b
	fi
	if b=$(station_bytes); then
		if [ "$PREV_STA_BYTES" != na ]; then
			S_STA_MBPS=$(mbps_of "$((b - PREV_STA_BYTES))" "$((now - PREV_TS))")
		fi
		PREV_STA_BYTES=$b
	fi
	PREV_TS=$now
	if [ -n "$CLIENT" ]; then
		S_MBPS=$S_STA_MBPS
	else
		S_MBPS=$S_IF_MBPS
	fi
}

S_THROTTLE=0
S_THR_SRC=
sample_throttle() {
	S_THROTTLE=0
	S_THR_SRC=
	[ "$LOAD_ACTIVE" -eq 1 ] && [ "$S_CDEVCPU" != na ] && [ "$S_CDEVCPU" -gt 0 ] &&
		S_THR_SRC="${S_THR_SRC}cpu-cdev"
	[ "$S_WIFI_CDEV" -gt 0 ] 2>/dev/null &&
		S_THR_SRC="${S_THR_SRC:+$S_THR_SRC+}wifi-cdev"
	[ "$S_WIFI_THR" -gt 0 ] 2>/dev/null &&
		S_THR_SRC="${S_THR_SRC:+$S_THR_SRC+}wifi-throttle"
	[ "$S_DMESG_THR" -eq 1 ] && S_THR_SRC="${S_THR_SRC:+$S_THR_SRC+}dmesg"
	if [ "$LOAD_ACTIVE" -eq 1 ] && [ "$S_FREQ" != na ] && [ "$S_FREQMAX" != na ] &&
		[ "$S_FREQ" -gt 0 ] && [ "$S_FREQMAX" -gt 0 ] &&
		[ $((S_FREQ * 100)) -lt $((S_FREQMAX * 95)) ]; then
		S_THR_SRC="${S_THR_SRC:+$S_THR_SRC+}freq-low"
	fi
	[ -n "$S_THR_SRC" ] && S_THROTTLE=1
	[ -n "$S_THR_SRC" ] || S_THR_SRC=-
}

S_TIME=
S_EPOCH=
S_ELAPSED=
S_PHASE=
S_WORKERS=0
sample_once() {
	S_PHASE=$1
	S_EPOCH=$(now_epoch)
	S_TIME=$(hms_utc)
	S_ELAPSED=$((S_EPOCH - POINT_START))
	if [ "$LOAD_ACTIVE" -eq 1 ]; then
		S_WORKERS=${CPU_WORKERS:-0}
	else
		S_WORKERS=0
	fi
	sample_thermal
	sample_wifi
	sample_cpufreq
	sample_fan
	sample_cdev_cpu
	scan_dmesg
	sample_throughput
	sample_throttle
	SAMPLES=$((SAMPLES + 1))
	append_sample
	print_sample
}

csv_mode() {
	fan_mode
}

csv_preset() {
	fan_preset
}

append_sample() {
	[ -n "$RUN" ] || return 0
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$CURRENT_POINT" "$S_PHASE" "$S_ELAPSED" "$S_TIME" \
		"$S_CPU" "$S_BOARD" "$S_WMAX" \
		"$S_FREQ" "$S_FREQMAX" \
		"$S_PWM1" "$S_PWM1E" "$S_PWM2" "$S_PWM3" "$S_RPM" \
		"$(csv_mode)" "$(csv_preset)" \
		"$S_IF_MBPS" "$S_STA_MBPS" "$S_MBPS" \
		"$S_THROTTLE" "$S_THR_SRC" \
		"$S_CDEVCPU" "$S_WIFI_THR" "$S_WORKERS" >>"$RUN/samples.csv"
}

print_header() {
	printf 'point       phase elapsed time(UTC)   cpuC boardC  wifiC    MHz  pwm1    rpm     Mbps thr\n'
}

print_sample() {
	printf '%-11s %-5s %5ss %s %6s %6s %6s %6s %5s %6s %8s %3s\n' \
		"$CURRENT_POINT" "$S_PHASE" "$S_ELAPSED" "$S_TIME" \
		"$S_CPU" "$S_BOARD" "$S_WMAX" "$S_FREQ" \
		"$S_PWM1" "$S_RPM" "$S_MBPS" "$S_THROTTLE"
}

# ---------------------------------------------------------------------------
# Per-point statistics and the final summary.
# ---------------------------------------------------------------------------
point_stats() {
	point=$1
	preset=$2
	awk -F, -v point="$point" -v preset="$preset" '
		function num(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ ? v + 0 : "" }
		NR == 1 { next }
		$1 != point || $2 != "load" { next }
		{
			samples++
			v = num($5); if (v != "") { if (tn == 0 || v < tmin) tmin = v; if (tn == 0 || v > tmax) tmax = v; tsum += v; tn++ }
			v = num($8); if (v != "") { if (fn == 0 || v < fmin) fmin = v; if (fn == 0 || v > fmax) fmax = v; fn++ }
			v = num($10); if (v != "") { if (pn == 0 || v < pmin) pmin = v; if (pn == 0 || v > pmax) pmax = v; pn++ }
			v = num($14); if (v != "") { if (rn == 0 || v < rmin) rmin = v; if (rn == 0 || v > rmax) rmax = v; rn++ }
			v = num($19); if (v != "") { if (mn == 0 || v > mmax) mmax = v; if (mn == 0 || v < mmin) mmin = v; msum += v; mn++ }
			if ($20 == 1) thr++
		}
		END {
			if (samples == 0) {
				printf "point %s (%s): no load samples\n", point, preset
				exit 0
			}
			printf "point %s (%s): cpu %s..%s C avg %s | pwm %s..%s rpm %s..%s | freq %s..%s MHz | thr %d/%d | Mbps avg %s max %s\n",
				point, preset,
				(tn ? sprintf("%.1f", tmin) : "na"), (tn ? sprintf("%.1f", tmax) : "na"),
				(tn ? sprintf("%.1f", tsum / tn) : "na"),
				(pn ? pmin : "na"), (pn ? pmax : "na"),
				(rn ? rmin : "na"), (rn ? rmax : "na"),
				(fn ? fmin : "na"), (fn ? fmax : "na"),
				thr, samples,
				(mn ? sprintf("%.3f", msum / mn) : "na"),
				(mn ? sprintf("%.3f", mmax) : "na")
		}
	' "$RUN/samples.csv"
}

summary_point() {
	point=$1
	preset=$2
	point_stats "$point" "$preset"
	if [ -n "$IPERF_SERVER" ]; then
		f="$RUN/iperf.$point.log"
		if [ -s "$f" ]; then
			v=$(iperf_last_mbps "$f")
			printf 'point %s: iperf3 last Mbits/sec: %s\n' "$point" "${v:-na}"
		else
			printf 'point %s: iperf3 log absent\n' "$point"
		fi
	fi
}

write_summary() {
	[ -n "$RUN" ] && [ -d "$RUN" ] || return 0
	reason=${INTERRUPTED:+signal:}${INTERRUPTED:-duration}
	{
		printf '%s summary\n' "$(iso_utc)"
		printf 'run=%s reason=%s duration=%ss interval=%ss cooldown=%ss settle=%ss samples=%s\n' \
			"$RUN_ID" "$reason" "$DURATION" "$INTERVAL" "$COOLDOWN" "$SETTLE" "$SAMPLES"
		printf 'points=%s load=cpu:%s%%(%s worker(s)) iperf_server=%s streams=%s direction=%s\n' \
			"$POINTS" "$CPU_LOAD" "${CPU_WORKERS:-0}" "${IPERF_SERVER:-none}" \
			"$STREAMS" "$DIRECTION"
		printf 'throughput_iface=%s client=%s\n' "${THRU_IFACE:-auto}" "${CLIENT:-none}"
		printf 'fan config=%s\n' "$FAN_CONFIG"
		printf 'fan hwmon=%s owner=%s\n' "${FAN:-none}" "$(find_fan_owner)"
		printf 'fan config sha256 before=%s after=%s\n' "${FAN_CFG_SHA_BEFORE:-na}" \
			"${FAN_CFG_SHA_AFTER:-na}"
		printf 'uci show fan md5 before=%s after=%s\n' "${UCI_SHA_BEFORE:-na}" \
			"${UCI_SHA_AFTER:-na}"
		printf 'fan restore=%s (config file + pwm1_* attributes)\n' "$FAN_RESTORE"
		for p in $(printf '%s' "$POINTS" | tr ',' ' '); do
			case $p in
			current) say "curve current: $([ -n "$(fan_preset)" ] && curve_string "$(fan_preset)" || echo 'as configured')" ;;
			aggressive) say "curve aggressive: $(curve_string performance)" ;;
			quiet) say "curve quiet: $(curve_string quiet)" ;;
			esac
		done
		dmesg=no
		[ "$DMESG_OK" -eq 1 ] && dmesg=yes
		printf 'dmesg: readable=%s new_throttle_lines=%s\n' "$dmesg" "$THR_EVENTS"
		for p in $(printf '%s' "$POINTS" | tr ',' ' '); do
			case $p in
			current) summary_point "$p" "$(fan_preset)" ;;
			aggressive) summary_point "$p" performance ;;
			quiet) summary_point "$p" quiet ;;
			esac
		done
		printf 'data: %s\n' "$RUN"
	} >"$RUN/summary.txt"
	cat "$RUN/summary.txt" || true
}

cleanup() {
	[ "$CLEANED" -eq 1 ] && return 0
	CLEANED=1
	trap '' INT TERM HUP
	stop_load
	if [ -n "$RUN" ] && [ -d "$RUN" ]; then
		echo "[$(iso_utc)] cleanup: reason=${INTERRUPTED:-duration}" >>"$RUN/events.log"
		restore_fan
		write_summary
	fi
	:
}

# ---------------------------------------------------------------------------
# Plan (read-only and dry run).
# ---------------------------------------------------------------------------
plan_point() {
	point=$1
	case $point in
	current)
		mode=$(fan_mode)
		preset=$(fan_preset)
		if [ "$mode" = manual ]; then
			say "point current: mode=manual pwm=$(fan_manual_pwm) (no auto curve)"
		else
			say "point current: mode=${mode:-auto} preset=${preset:-unknown} (kept as configured)"
			[ -n "$preset" ] && say "  curve $preset: $(curve_string "$preset") [$(curve_label "$preset")]"
		fi
		;;
	aggressive)
		say "point aggressive: mode=auto preset=performance"
		say "  curve performance: $(curve_string performance) [$(curve_label performance)]"
		;;
	quiet)
		say "point quiet: mode=auto preset=quiet"
		say "  curve quiet: $(curve_string quiet) [$(curve_label quiet)]"
		;;
	esac
}

print_plan() {
	workers=$(cpu_workers)
	ncpu=$(cpu_count)
	if [ "$APPLY" -eq 1 ]; then
		say "$PROG: plan for an --apply run"
	else
		say "$PROG: read-only; no load, no sysfs/UCI write, no files"
	fi
	printf 'fan config: %s (%s)\n' "$FAN_CONFIG" \
		"$([ "$FAN_CFG_PRESENT" -eq 1 ] && echo present || echo missing)"
	if [ "$FAN_CFG_PRESENT" -eq 1 ]; then
		printf 'config sha256: %s\n' "$(sha256sum "$FAN_CONFIG" 2>/dev/null | awk '{ print $1 }')"
	fi
	if command_exists uci; then
		printf 'uci show fan md5: %s\n' "$(uci -q show fan 2>/dev/null | sort | md5sum | awk '{ print $1 }')"
	fi
	printf 'fan owner: %s\n' "$(find_fan_owner)"
	if [ -n "$FAN" ]; then
		printf 'fan hwmon: %s name=%s pwm1=%s enable=%s pwm2=%s pwm3=%s rpm=%s board=%sC\n' \
			"$FAN" "$(cat "$FAN/name" 2>/dev/null)" \
			"$(read_uint_or_na "$FAN/pwm1")" "$(read_uint_or_na "$FAN/pwm1_enable")" \
			"$(read_uint_or_na "$FAN/pwm2")" "$(read_uint_or_na "$FAN/pwm3")" \
			"$(read_uint_or_na "$FAN/fan1_input")" "$(read_temp_c_or_na "$FAN/temp1_input")"
		printf 'fan auto points:'
		i=1
		while [ "$i" -le 5 ]; do
			printf ' %s/%s' "$(read_num_or_na "$FAN/pwm1_auto_point${i}_temp")" \
				"$(read_num_or_na "$FAN/pwm1_auto_point${i}_pwm")"
			i=$((i + 1))
		done
		printf '\n'
	else
		say 'fan hwmon: none (no nct7802 found)'
	fi
	if [ -n "$THERMAL" ]; then
		say "sensor thermal: $THERMAL type=$THERMAL_TYPE temp=$(read_temp_c_or_na "$THERMAL/temp") C"
	else
		say 'sensor thermal: none (cpu-thermal absent)'
	fi
	say "sensor cpufreq: $([ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ] && echo present || echo absent) governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo na)"
	say "sensor radios:$(printf '%s' "$WIFI_HWMONS")"
	say "sensor cooling:$(printf '%s' "$CPU_CDEVS")$(printf '%s' "$WIFI_CDEVS")"
	if [ -n "$THRU_IFACE" ]; then
		if [ -n "$CLIENT" ]; then
			say "throughput: $THRU_IFACE station $CLIENT (rx+tx bytes)"
		else
			say "throughput: $THRU_IFACE (interface counters)"
		fi
	else
		say "throughput: auto-selected interface"
	fi
	say "load: cpu ${CPU_LOAD}% -> ${workers}/${ncpu} worker(s)"
	if [ -n "$IPERF_SERVER" ]; then
		if [ -n "$IPERF3_BIN" ]; then
			say "iperf3: $IPERF3_BIN -> ${IPERF_SERVER}:${IPERF_PORT} ${STREAMS} stream(s) ${DIRECTION} (${DURATION}s)"
		else
			say "iperf3: MISSING on the AP; --apply with --iperf-server would fail"
		fi
	else
		say 'iperf3: not requested (no --iperf-server); interface/station throughput only'
	fi
	say "timing: duration=${DURATION}s interval=${INTERVAL}s cooldown=${COOLDOWN}s settle=${SETTLE}s"
	say "points: $(printf '%s' "$POINTS" | tr ',' ' ')"
	for p in $(printf '%s' "$POINTS" | tr ',' ' '); do
		plan_point "$p"
	done
	if [ "$APPLY" -eq 1 ]; then
		if [ -e "$OUT" ] && [ -d "$OUT" ] && [ -z "$(ls -A "$OUT" 2>/dev/null)" ]; then
			say "out: $OUT (empty directory, would be used)"
		elif [ -d "$OUT" ]; then
			say "out: $OUT (not empty; a real run refuses it)"
		else
			say "out: $OUT (would be created)"
		fi
		say "backup: $OUT/fan.config.orig and $OUT/fan.sysfs.orig before the first write"
		say 'restore: EXIT/INT/TERM/HUP trap restores both and prints the hashes'
	else
		say "out: $OUT (would be created by --apply)"
		say 'pass --apply to run the A/B; without it nothing is written or loaded'
	fi
	say 'sample columns:'
	print_header
}

# ---------------------------------------------------------------------------
# Real run.
# ---------------------------------------------------------------------------
prepare_run_dir() {
	[ -e "$OUT" ] && [ ! -d "$OUT" ] && die "$OUT exists and is not a directory"
	mkdir -p "$OUT" || die "cannot create $OUT"
	[ -z "$(ls -A "$OUT" 2>/dev/null)" ] || die "$OUT is not empty; use a fresh directory"
	RUN=$OUT
	RUN_ID=$(date -u '+%Y%m%dT%H%M%SZ').$$
	printf 'point,phase,elapsed_s,time_utc,cpu_c,board_c,wifi_max_c,freq_mhz,freq_max_mhz,pwm1,pwm1_enable,pwm2,pwm3,rpm,fan_mode,fan_preset,if_mbps,sta_mbps,mbps,throttle,throttle_src,cpu_cdev,wifi_throttle,workers\n' \
		>"$RUN/samples.csv"
	printf '%s\n' "# $PROG run $RUN_ID started $(iso_utc)" >"$RUN/runs.log"
	printf '%s\n' "[$(iso_utc)] run start id=$RUN_ID points=$POINTS duration=$DURATION interval=$INTERVAL cpu_load=$CPU_LOAD" \
		>"$RUN/events.log"
	: >"$RUN/dmesg.log"
	: >"$RUN/points.log"
}

select_throughput_iface() {
	if [ -n "$THRU_IFACE" ]; then
		return 0
	fi
	if [ -d /sys/class/net/br-lan ]; then
		THRU_IFACE=br-lan
		return 0
	fi
	for i in /sys/class/net/phy*-ap*; do
		[ -d "$i" ] || continue
		THRU_IFACE=${i##*/}
		return 0
	done
	THRU_IFACE=
	return 0
}

print_point_intro() {
	point=$1
	preset=$2
	say ""
	say "=== point $POINT_INDEX/$POINT_COUNT: $point ($preset) ==="
	if [ -n "$FAN" ]; then
		say "fan target: $FAN curve=$preset mode=$(fan_mode)"
	fi
}

run_point() {
	point=$1
	CURRENT_POINT=$point
	POINT_INDEX=$((POINT_INDEX + 1))
	PREV_IF_BYTES=na
	PREV_STA_BYTES=na
	PREV_TS=na
	case $point in
	current)
		restore_for_current
		CURRENT_PRESET=$(fan_preset)
		print_point_intro "$point" "${CURRENT_PRESET:-as configured}"
		;;
	aggressive)
		CURRENT_PRESET=performance
		print_point_intro "$point" performance
		apply_fan_point performance
		;;
	quiet)
		CURRENT_PRESET=quiet
		print_point_intro "$point" quiet
		apply_fan_point quiet
		;;
	esac
	if [ -n "$CURRENT_PRESET" ]; then
		say "curve: $(curve_string "$CURRENT_PRESET") [$(curve_label "$CURRENT_PRESET")]"
	fi
	if [ "$SETTLE" -gt 0 ]; then
		say "settle ${SETTLE}s before the load"
		sleep "$SETTLE"
	fi
	# One pre-load sample gives the starting thermal state of the point.
	POINT_START=$(now_epoch)
	print_header
	sample_once idle
	start_load
	POINT_START=$(now_epoch)
	sample_once load
	while :; do
		elapsed=$(( $(now_epoch) - POINT_START ))
		remaining=$((DURATION - elapsed))
		[ "$remaining" -le 0 ] && break
		[ "$remaining" -gt "$INTERVAL" ] && remaining=$INTERVAL
		sleep "$remaining"
		sample_once load
	done
	stop_load
	point_stats "$point" "$CURRENT_PRESET" | tee -a "$RUN/points.log"
	if [ -n "$IPERF_SERVER" ]; then
		v=$(iperf_last_mbps "$RUN/iperf.$point.log" 2>/dev/null || true)
		[ -n "$v" ] && say "iperf3 ${point}: ${v} Mbits/sec (last log line)"
	fi
	return 0
}

cooldown() {
	[ "$COOLDOWN" -gt 0 ] || return 0
	POINT_INDEX=${POINT_INDEX:-0}
	say "cool-down ${COOLDOWN}s before the next point"
	sleep "$COOLDOWN"
}

run_apply() {
	command_exists uci || die "--apply needs uci"
	[ -f "$FAN_CONFIG" ] || die "--apply needs $FAN_CONFIG"
	[ -n "$FAN" ] || die "--apply needs the nct7802 fan hwmon"
	[ "$(cat "$FAN/name" 2>/dev/null)" = "$FAN_HWMON_NAME" ] ||
		die "--apply needs the nct7802 fan hwmon, found ${FAN:-none} ($(cat "$FAN/name" 2>/dev/null || echo unknown))"
	[ -n "$IPERF_SERVER" ] && [ -z "$IPERF3_BIN" ] &&
		die "--iperf-server needs iperf3 on the AP, but iperf3 was not found"
	prepare_run_dir
	trap cleanup EXIT
	trap 'INTERRUPTED=INT; exit 130' INT
	trap 'INTERRUPTED=TERM; exit 143' TERM
	trap 'INTERRUPTED=HUP; exit 129' HUP
	snapshot_fan
	init_dmesg
	select_throughput_iface

	say "$PROG: apply run $POINT_COUNT point(s) x ${DURATION}s; evidence in $RUN"
	say "fan config: $FAN_CONFIG -> $RUN/fan.config.orig"
	say "fan hwmon: $FAN; original sysfs -> $RUN/fan.sysfs.orig"
	if [ "$CPU_LOAD" -gt 0 ]; then
		say "load: cpu ${CPU_LOAD}% -> $(cpu_workers)/$(cpu_count) worker(s)"
	fi
	if [ -n "$IPERF_SERVER" ]; then
		say "load: iperf3 -> $IPERF_SERVER:$IPERF_PORT, $STREAMS stream(s), $DIRECTION, ${DURATION}s"
	fi
	say "throughput interface: ${THRU_IFACE:-none}${CLIENT:+ station $CLIENT}"
	say ""

	for p in $(printf '%s' "$POINTS" | tr ',' ' '); do
		run_point "$p"
		remaining=$((POINT_COUNT - POINT_INDEX))
		[ "$remaining" -gt 0 ] && cooldown
	done
	say ""
	say "run finished; restoring the fan in the trap"
	exit 0
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
main() {
	parse_args "$@"
	validate
	setup_sensors
	select_throughput_iface
	POINT_COUNT=$(printf '%s' "$POINTS" | tr ',' '\n' | grep -c .)
	if [ "$APPLY" -eq 1 ]; then
		run_apply
	else
		print_plan
	fi
}

main "$@"
