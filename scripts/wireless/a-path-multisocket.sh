#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC3043
#
# a-path-multisocket.sh - reproducible A-path source and CPU profile harness.
#
# Runs on the AP, not the client.  One invocation is one arm: it starts a
# paced multi-socket UDP source on the AP, waits for the link to settle, and
# records the counters that separate a source limit, a host softirq limit and
# a client/air limit:
#
#   - iw station dump before and after (client signal, rate, NSS, tx/retry
#     counters),
#   - /proc/interrupts and /proc/softirqs deltas,
#   - mpstat -P ALL 1 output when sysstat is installed,
#   - AP tx bytes from the station dump and the netdev counters,
#   - token_info and hw-queues snapshots when the mt76 debugfs files exist.
#
# The last line on stdout is a single key=value summary for the arm.  All
# progress and prerequisite diagnostics go to stderr.  The default is a
# dry-run; traffic is only sent with --run.
#
# No UCI, module, firmware or sysctl state is changed.

set -u

PROG="a-path-multisocket"

usage() {
	cat <<'EOF'
Usage: a-path-multisocket.sh --iface NAME --client ADDR [options]

One arm: start a paced multi-socket UDP source on the AP, then record the
station, interrupt, softirq, CPU and token/queue counters around it.

Required for --run:
  --iface NAME        AP netdev under test, e.g. phy2-ap0
  --client ADDR       client IPv4 address, or client MAC

Options:
  --client-ip ADDR    explicit client IPv4 when --client is a MAC
  --client-mac MAC    explicit client MAC when --client is an IPv4
  --seconds N         measurement window in seconds (default 20)
  --procs N           source processes (default 6)
  --sockets N         sockets per source process (default 4)
  --rate MBPS         aggregate offered UDP payload rate (default 1340)
  --port N            destination UDP port (default 5201)
  --pkt-size N        UDP payload bytes (default 1472)
  --warmup N          seconds before the baselines (default 1)
  --out-dir DIR       artifact directory (default /tmp/a-path.<time>-<pid>)
  --source-bin PATH   udpblast3 binary (default: auto-detect)
  --source-iface NAME force the source egress device; "auto" uses the
                      bridge master of --iface, "none" disables the bind
  --run               actually send traffic; default is a dry run
  --help              this help

The source rate is UDP payload, split evenly over --procs processes and
--sockets sockets per process.  IP/UDP and 802.11 headers are on top, so
ap_tx_delta_bytes is normally a few percent above source_sent_bytes.

The source is bound to the bridge master of --iface (for example br-lan)
rather than to the AP netdev itself: an AP netdev is a bridge port, and
SO_BINDTODEVICE on a bridge port does not route to the client.  Use
--source-iface to override this, or --source-iface none to let the kernel
route pick the path.

A receiver is not required: the AP-side counters are the measurement.  With
a listener on the client (for example `socat -u UDP-RECV:5201 /dev/null`),
the same arm also proves end-to-end delivery.

Examples:
  # Validate prerequisites on a host without the device (always exits 0).
  sh scripts/wireless/a-path-multisocket.sh --iface phy2-ap0 \
      --client 192.168.1.50 --seconds 20 --procs 6 --rate 1340

  # Actual arm on the AP.
  sh /usr/share/a-path/a-path-multisocket.sh --iface phy2-ap0 \
      --client 192.168.1.50 --seconds 20 --procs 6 --rate 1340 --run

  # Reproduce the 4P..8P matrix, one summary line per arm.
  for p in 4 5 6 7 8; do
      sh /usr/share/a-path/a-path-multisocket.sh --iface phy2-ap0 \
          --client 192.168.1.50 --seconds 20 --procs "$p" \
          --rate 1340 --run >> /tmp/a-path.txt
  done
EOF
}

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 2
}

note() {
	printf '%s: %s\n' "$PROG" "$*" >&2
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
	printf '%s' "${1-}" | tr 'A-Z' 'a-z'
}

as_uint() {
	if is_uint "${1-}"; then
		printf '%s' "$1"
	else
		printf '0'
	fi
}

field_or_unavail() {
	if [ -n "${1-}" ]; then
		printf '%s' "$1"
	else
		printf 'unavailable'
	fi
}

num_or_unavail() {
	if is_uint "${1-}"; then
		printf '%s' "$1"
	else
		printf 'unavailable'
	fi
}

sta_field_or_unavail() {
	field_or_unavail "$(sta_field "${1-}" "${2-}" "${3-}")"
}

sta_nss_or_unavail() {
	field_or_unavail "$(sta_nss "${1-}" "${2-}" "${3-}")"
}

add_missing() {
	if [ -z "$missing" ]; then
		missing=$1
	else
		missing="$missing,$1"
	fi
	missing_n=$((missing_n + 1))
}

add_optional() {
	if [ -z "$optional" ]; then
		optional=$1
	else
		optional="$optional,$1"
	fi
	optional_n=$((optional_n + 1))
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

# Like delta_uint, but preserve "field was not printed" instead of turning
# it into a plausible looking zero.
delta_field_or_unavail() {
	if is_uint "${1-}" && is_uint "${2-}"; then
		delta_uint "$1" "$2"
	else
		printf 'unavailable'
	fi
}

# Return the "iw station dump" block for one MAC.  The block starts at
# "Station MAC ..." and ends at the next "Station" line or EOF.
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

# First field after a station key, for example "signal:" or "tx bytes:".
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

# NSS as printed inside the rate line: "... HE-NSS 2 ...".
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

kv_get() {
	[ -f "${1-}" ] || return 0
	awk -v key="${2-}" '
		{
			for (i = 1; i <= NF; i++) {
				p = index($i, "=")
				if (p > 1 && substr($i, 1, p - 1) == key) {
					print substr($i, p + 1)
					exit
				}
			}
		}
	' "$1"
}

# Sum all per-CPU counters of every "name:" line in an interrupts or
# softirqs snapshot.
proc_total() {
	[ -f "${1-}" ] || { printf '0'; return; }
	awk '
		{
			if ($1 !~ /:$/)
				next
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				total += $i
			}
		}
		END { printf "%d", total + 0 }
	' "$1"
}

# Sum the /proc/interrupts lines whose description looks like a network
# source: mt76/mt7996/WED, airoha/qdma/ethernet, NPU or PCIe.
irq_net_total() {
	[ -f "${1-}" ] || { printf '0'; return; }
	awk '
		{
			if ($1 !~ /:$/)
				next
			line = tolower($0)
			if (line !~ /(mt76|mt7996|wed|wifi|wlan|airoha|qdma|ethernet|pcie)/ &&
			    line !~ /(^|[^a-z])npu([^a-z]|$)/)
				next
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				total += $i
			}
		}
		END { printf "%d", total + 0 }
	' "$1"
}

softirq_label_total() {
	[ -f "${1-}" ] || { printf '0'; return; }
	awk -v label="${2-}" '
		{
			if ($1 != label && $1 != label ":")
				next
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				total += $i
			}
		}
		END { printf "%d", total + 0 }
	' "$1"
}

# Comma-separated per-CPU delta for one softirq label (NET_TX, NET_RX).
softirq_delta_percpu() {
	[ -f "${1-}" ] && [ -f "${2-}" ] || { printf ''; return; }
	awk -v label="${3-}" '
		FNR == NR {
			if ($1 == label || $1 == label ":")
				for (i = 2; i <= NF; i++)
					before[i] = $i
			next
		}
		$1 == label || $1 == label ":" {
			sep = ""
			for (i = 2; i <= NF; i++) {
				if ($i !~ /^[0-9]+$/)
					break
				d = $i - before[i]
				if (d < 0)
					d = 0
				printf "%s%d", sep, d
				sep = ","
			}
			print ""
			exit
		}
	' "$1" "$2"
}

token_count() {
	[ -f "${1-}" ] || return 0
	awk '
		/token_count:/ {
			for (i = 1; i <= NF; i++)
				if ($i == "token_count:") {
					print $(i + 1)
					exit
				}
		}
	' "$1"
}

token_max() {
	[ -f "${1-}" ] || return 0
	awk '
		/token_count:/ {
			for (i = 1; i <= NF; i++)
				if ($i == "token_count:") {
					print $(i + 3)
					exit
				}
		}
	' "$1"
}

hwq_field() {
	[ -f "${1-}" ] || return 0
	case ${2-} in
	ple)
		sed -n 's/.*Total free page:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
			"$1" | head -n 1
		;;
	hif_reserved)
		awk '
			/HIF free page:/ {
				for (i = 1; i <= NF; i++)
					if ($i == "page:") {
						print $(i + 3)
						exit
					}
			}
		' "$1"
		;;
	hif_used)
		awk '
			/HIF free page:/ {
				for (i = 1; i <= NF; i++)
					if ($i == "page:") {
						print $(i + 5)
						exit
					}
			}
		' "$1"
		;;
	esac
}

read_uint_file() {
	if [ -f "${1-}" ]; then
		as_uint "$(cat "$1" 2>/dev/null)"
	else
		printf '0'
	fi
}

resolve_source() {
	source_ok=0
	if [ -n "$source_bin_opt" ]; then
		if [ -x "$source_bin_opt" ]; then
			source_bin=$source_bin_opt
			source_ok=1
		fi
		return
	fi
	for p in "$script_dir/udpblast3" /usr/bin/udpblast3 \
		 /usr/sbin/udpblast3 /usr/libexec/udpblast3 /tmp/udpblast3
	do
		if [ -x "$p" ]; then
			source_bin=$p
			source_ok=1
			return
		fi
	done
	p=$(command -v udpblast3 2>/dev/null || :)
	if [ -n "$p" ] && [ -x "$p" ]; then
		source_bin=$p
		source_ok=1
	fi
}

find_mt76_dir() {
	mt76dir=
	if [ -n "$wiphy" ] &&
	   [ -d "/sys/kernel/debug/ieee80211/phy$wiphy/mt76" ]; then
		mt76dir="/sys/kernel/debug/ieee80211/phy$wiphy/mt76"
		return
	fi
	for d in /sys/kernel/debug/ieee80211/phy*/mt76; do
		[ -d "$d" ] || continue
		if [ -r "$d/token_info" ] || [ -r "$d/hw-queues" ]; then
			mt76dir=$d
			return
		fi
		[ -n "$mt76dir" ] || mt76dir=$d
	done
}

resolve_client() {
	client_mac=$client_mac_opt
	client_ip=$client_ip_opt

	if is_mac "$client_arg"; then
		[ -n "$client_mac" ] || client_mac=$client_arg
		if [ -z "$client_ip" ] && [ -n "$client_mac" ]; then
			client_ip=$(ip neigh show 2>/dev/null | awk -v m="$(lower "$client_mac")" '
				tolower($0) ~ m { print $1; exit }')
		fi
	else
		[ -n "$client_ip" ] || client_ip=$client_arg
		if [ -z "$client_mac" ] && [ -n "$client_ip" ]; then
			client_mac=$(ip neigh show 2>/dev/null | awk -v ip="$client_ip" '
				$1 == ip {
					for (i = 1; i <= NF; i++)
						if ($i == "lladdr") {
							print $(i + 1)
							exit
						}
				}')
		fi
	fi
	[ -n "$client_mac" ] && client_mac=$(lower "$client_mac")
}

preflight_station() {
	pre_tmp="${TMPDIR:-/tmp}/a-path-station.$$"
	: > "$pre_tmp" 2>/dev/null || :
	iw dev "$iface" station dump > "$pre_tmp" 2>/dev/null || :
	if [ -n "$client_mac" ] &&
	   [ -n "$(sta_block "$pre_tmp" "$client_mac")" ]; then
		station_ok=1
	fi
}

check_prereqs() {
	local hops next

	missing=
	missing_n=0
	optional=
	optional_n=0
	iw_ok=0
	iface_ok=0
	station_ok=0
	token_info_ok=0
	hw_queues_ok=0
	wiphy=
	mt76dir=
	source_bin=
	source_ok=0
	mpstat_cmd=
	mpstat_ok=0

	if command -v iw >/dev/null 2>&1; then
		iw_ok=1
	else
		add_missing iw
	fi
	command -v ip >/dev/null 2>&1 || add_optional ip
	command -v awk >/dev/null 2>&1 || add_missing awk

	[ -r /proc/interrupts ] || add_missing proc-interrupts
	[ -r /proc/softirqs ] || add_missing proc-softirqs
	[ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] || add_missing root

	resolve_source
	[ "$source_ok" -eq 1 ] || add_missing udpblast3

	mpstat_cmd=$(command -v mpstat 2>/dev/null || :)
	if [ -n "$mpstat_cmd" ]; then
		mpstat_ok=1
	else
		add_optional mpstat
	fi

	if [ -z "$iface" ]; then
		add_missing iface-arg
	elif [ ! -e "/sys/class/net/$iface" ]; then
		add_missing "iface-$iface"
	elif [ "$iw_ok" -eq 1 ]; then
		if iw dev "$iface" info >/dev/null 2>&1; then
			iface_ok=1
			wiphy=$(iw dev "$iface" info 2>/dev/null |
				awk '$1 == "wiphy" { print $2; exit }')
			if [ -z "$wiphy" ]; then
				wiphy=$(iw dev 2>/dev/null | awk -v ifc="$iface" '
					/^phy#/ { p = substr($1, 5) }
					$1 == "Interface" && $2 == ifc {
						print p
						exit
					}')
			fi
			find_mt76_dir
		else
			add_missing "iw-iface-$iface"
		fi
	fi

	# SO_BINDTODEVICE on a bridge port does not route: bind the source to
	# the bridge master instead, or explicitly to the requested device.
	bind_iface=
	if [ "$source_iface_opt" != none ]; then
		if [ "$source_iface_opt" = auto ]; then
			if [ "$iface_ok" -eq 1 ]; then
				bind_iface=$iface
				# Walk up to the topmost master: an AP netdev is
				# normally a bridge port, and a bridge port does not
				# route with SO_BINDTODEVICE.
				hops=0
				while [ -n "$bind_iface" ] &&
				      [ -e "/sys/class/net/$bind_iface/master" ] &&
				      [ "$hops" -lt 8 ]; do
					next=$(readlink \
						"/sys/class/net/$bind_iface/master" \
						2>/dev/null || :)
					next=${next##*/}
					[ -n "$next" ] || break
					[ "$next" = "$bind_iface" ] && break
					bind_iface=$next
					hops=$((hops + 1))
				done
			fi
		else
			bind_iface=$source_iface_opt
		fi
		if [ -n "$bind_iface" ] &&
		   [ ! -e "/sys/class/net/$bind_iface" ]; then
			add_missing "source-iface-$bind_iface"
			bind_iface=
		elif [ -n "$bind_iface" ] &&
		     [ -e "/sys/class/net/$bind_iface/master" ]; then
			# Binding to a bridge port does not route; refuse it
			# instead of producing a fast source with no AP tx.
			add_missing "source-iface-is-a-bridge-port-$bind_iface"
			bind_iface=
		fi
	fi

	if [ -n "$mt76dir" ]; then
		if [ -r "$mt76dir/token_info" ]; then
			token_info_ok=1
		else
			add_optional token_info
		fi
		if [ -r "$mt76dir/hw-queues" ]; then
			hw_queues_ok=1
		else
			add_optional hw-queues
		fi
	else
		add_optional debugfs
		add_optional token_info
		add_optional hw-queues
	fi

	if [ "$iface_ok" -eq 1 ] &&
	   [ ! -r "/sys/class/net/$iface/statistics/tx_bytes" ]; then
		add_optional iface-stats
	fi

	if [ -z "$client_arg" ]; then
		add_missing client-arg
	else
		resolve_client
		[ -n "$client_mac" ] || add_missing client-mac
		[ -n "$client_ip" ] || add_missing client-ip
		if [ "$iface_ok" -eq 1 ] && [ -n "$client_mac" ]; then
			preflight_station
			[ "$station_ok" -eq 1 ] ||
				add_missing "station-$client_mac"
		fi
	fi
}

report_checks() {
	note "iface=${iface:-none} wiphy=${wiphy:-none}"
	note "source=${source_bin:-none} bind=${bind_iface:-none} mpstat=${mpstat_cmd:-none}"
	if [ "$missing_n" -gt 0 ]; then
		note "missing: $(printf '%s' "$missing" | tr ',' ' ')"
	fi
	if [ "$optional_n" -gt 0 ]; then
		note "optional missing: $(printf '%s' "$optional" | tr ',' ' ')"
	fi
}

source_hint() {
	note "build udpblast3 from source and copy it to the AP, or pass --source-bin:"
	note "  make -C scripts/wireless CC=aarch64-openwrt-linux-musl-gcc LDFLAGS=-static"
	note "  scp scripts/wireless/udpblast3 root@ap:/usr/bin/"
}

init_measurement() {
	source_bytes=0
	source_pkts=0
	source_errors=0
	source_elapsed_ms=0
	source_fail=0
	source_mbps=0
	ap_tx_delta_bytes=0
	ap_tx_delta_packets=0
	ap_tx_retries_delta=0
	ap_tx_failed_delta=0
	ap_rx_delta_bytes=0
	iface_tx_delta_bytes=0
	iface_tx_delta_packets=0
	softirq_total_delta=0
	softirq_net_tx_delta=0
	softirq_net_rx_delta=0
	softirq_net_delta=0
	softirq_net_tx_percpu=
	softirq_net_rx_percpu=
	irq_total_delta=0
	irq_net_delta=0
	client_signal_dbm=unavailable
	client_signal_avg_dbm=unavailable
	client_tx_nss=unavailable
	client_rx_nss=unavailable
	client_tx_rate_mbps=unavailable
	client_rx_rate_mbps=unavailable
	client_station=missing
	token_info_state=missing
	token_count_before=unavailable
	token_count_after=unavailable
	token_count_max=unavailable
	hw_queues_state=missing
	ple_free_before=unavailable
	ple_free_after=unavailable
	hif_reserved=unavailable
	hif_used=unavailable
	mpstat_state=missing
	mpstat_avg_busy_pct=unavailable
}

populate_dry_client() {
	if [ "$station_ok" -ne 1 ]; then
		return
	fi
	client_station=preflight
	client_signal_dbm=$(sta_field_or_unavail "$pre_tmp" "$client_mac" "signal:")
	client_signal_avg_dbm=$(sta_field_or_unavail "$pre_tmp" "$client_mac" "signal avg:")
	client_tx_nss=$(sta_nss_or_unavail "$pre_tmp" "$client_mac" "tx bitrate:")
	client_rx_nss=$(sta_nss_or_unavail "$pre_tmp" "$client_mac" "rx bitrate:")
	client_tx_rate_mbps=$(sta_field_or_unavail "$pre_tmp" "$client_mac" "tx bitrate:")
	client_rx_rate_mbps=$(sta_field_or_unavail "$pre_tmp" "$client_mac" "rx bitrate:")
}

snapshot() {
	local tag

	tag=$1
	: > "$out_dir/station.$tag" 2>/dev/null || :
	if [ "$iw_ok" -eq 1 ]; then
		iw dev "$iface" station dump > "$out_dir/station.$tag" \
			2> "$out_dir/station.$tag.err" || :
	fi
	: > "$out_dir/interrupts.$tag" 2>/dev/null || :
	: > "$out_dir/softirqs.$tag" 2>/dev/null || :
	: > "$out_dir/token_info.$tag" 2>/dev/null || :
	: > "$out_dir/hw-queues.$tag" 2>/dev/null || :
	: > "$out_dir/iface_tx_bytes.$tag" 2>/dev/null || :
	: > "$out_dir/iface_tx_packets.$tag" 2>/dev/null || :
	cat /proc/interrupts > "$out_dir/interrupts.$tag" 2>/dev/null || :
	cat /proc/softirqs > "$out_dir/softirqs.$tag" 2>/dev/null || :
	if [ "$token_info_ok" -eq 1 ]; then
		cat "$mt76dir/token_info" > "$out_dir/token_info.$tag" \
			2>/dev/null || :
	fi
	if [ "$hw_queues_ok" -eq 1 ]; then
		cat "$mt76dir/hw-queues" > "$out_dir/hw-queues.$tag" \
			2>/dev/null || :
	fi
	if [ "$iface_ok" -eq 1 ]; then
		cat "/sys/class/net/$iface/statistics/tx_bytes" \
			> "$out_dir/iface_tx_bytes.$tag" 2>/dev/null || :
		cat "/sys/class/net/$iface/statistics/tx_packets" \
			> "$out_dir/iface_tx_packets.$tag" 2>/dev/null || :
	fi
}

start_senders() {
	local per_proc run_seconds i

	per_proc=$(awk -v r="$rate" -v p="$procs" \
		'BEGIN { printf "%.3f", r / p }')
	run_seconds=$((warmup + seconds + 5))
	pids=
	i=0
	while [ "$i" -lt "$procs" ]; do
		i=$((i + 1))
		if [ -n "$bind_iface" ]; then
			"$source_bin" -d "$client_ip" -p "$port" -r "$per_proc" \
				-t "$run_seconds" -s "$sockets" -b "$pkt_size" \
				-i "$bind_iface" > "$out_dir/source.$i.out" \
				2> "$out_dir/source.$i.err" &
		else
			"$source_bin" -d "$client_ip" -p "$port" -r "$per_proc" \
				-t "$run_seconds" -s "$sockets" -b "$pkt_size" \
				> "$out_dir/source.$i.out" \
				2> "$out_dir/source.$i.err" &
		fi
		pids="$pids $!"
	done
}

stop_senders() {
	local p

	source_fail=0
	if [ -n "$pids" ]; then
		for p in $pids; do
			kill -TERM "$p" 2>/dev/null || :
		done
		for p in $pids; do
			if wait "$p" 2>/dev/null; then
				:
			else
				source_fail=$((source_fail + 1))
			fi
		done
		pids=
	fi
}

start_mpstat() {
	if [ "$mpstat_ok" -eq 1 ]; then
		"$mpstat_cmd" -P ALL 1 "$seconds" > "$out_dir/mpstat.txt" \
			2> "$out_dir/mpstat.err" &
		mpstat_pid=$!
	fi
}

stop_mpstat() {
	if [ -n "${mpstat_pid-}" ]; then
		wait "$mpstat_pid" 2>/dev/null || :
		mpstat_pid=
	fi
}

collect_source() {
	local i f bytes pkts errs ms

	source_bytes=0
	source_pkts=0
	source_errors=0
	source_elapsed_ms=0
	i=0
	while [ "$i" -lt "$procs" ]; do
		i=$((i + 1))
		f="$out_dir/source.$i.out"
		[ -f "$f" ] || continue
		bytes=$(as_uint "$(kv_get "$f" sent_bytes)")
		pkts=$(as_uint "$(kv_get "$f" sent_pkts)")
		errs=$(as_uint "$(kv_get "$f" send_errors)")
		ms=$(as_uint "$(kv_get "$f" duration_ms)")
		source_bytes=$((source_bytes + bytes))
		source_pkts=$((source_pkts + pkts))
		source_errors=$((source_errors + errs))
		[ "$ms" -gt "$source_elapsed_ms" ] && source_elapsed_ms=$ms
	done
	if [ "$source_elapsed_ms" -gt 0 ]; then
		source_mbps=$((source_bytes * 8 * 1000 /
			(source_elapsed_ms * 1000000)))
	else
		source_mbps=0
	fi
}

collect_client() {
	local block_a block_b pick

	block_a=
	block_b=
	if [ -n "$client_mac" ]; then
		block_a=$(sta_block "$out_dir/station.after" "$client_mac")
		block_b=$(sta_block "$out_dir/station.before" "$client_mac")
	fi
	if [ -n "$block_a" ]; then
		pick=after
	elif [ -n "$block_b" ]; then
		pick=before
	else
		client_station=missing
		return
	fi
	client_station=$pick
	client_signal_dbm=$(sta_field_or_unavail "$out_dir/station.$pick" "$client_mac" "signal:")
	client_signal_avg_dbm=$(sta_field_or_unavail "$out_dir/station.$pick" "$client_mac" "signal avg:")
	client_tx_nss=$(sta_nss_or_unavail "$out_dir/station.$pick" "$client_mac" "tx bitrate:")
	client_rx_nss=$(sta_nss_or_unavail "$out_dir/station.$pick" "$client_mac" "rx bitrate:")
	client_tx_rate_mbps=$(sta_field_or_unavail "$out_dir/station.$pick" "$client_mac" "tx bitrate:")
	client_rx_rate_mbps=$(sta_field_or_unavail "$out_dir/station.$pick" "$client_mac" "rx bitrate:")

	if [ -n "$block_a" ] && [ -n "$block_b" ]; then
		ap_tx_delta_bytes=$(delta_field_or_unavail \
			"$(sta_field "$out_dir/station.before" "$client_mac" "tx bytes:")" \
			"$(sta_field "$out_dir/station.after" "$client_mac" "tx bytes:")")
		ap_tx_delta_packets=$(delta_field_or_unavail \
			"$(sta_field "$out_dir/station.before" "$client_mac" "tx packets:")" \
			"$(sta_field "$out_dir/station.after" "$client_mac" "tx packets:")")
		ap_tx_retries_delta=$(delta_field_or_unavail \
			"$(sta_field "$out_dir/station.before" "$client_mac" "tx retries:")" \
			"$(sta_field "$out_dir/station.after" "$client_mac" "tx retries:")")
		ap_tx_failed_delta=$(delta_field_or_unavail \
			"$(sta_field "$out_dir/station.before" "$client_mac" "tx failed:")" \
			"$(sta_field "$out_dir/station.after" "$client_mac" "tx failed:")")
		ap_rx_delta_bytes=$(delta_field_or_unavail \
			"$(sta_field "$out_dir/station.before" "$client_mac" "rx bytes:")" \
			"$(sta_field "$out_dir/station.after" "$client_mac" "rx bytes:")")
	fi
}

collect_counters() {
	local tx_before tx_after

	tx_before=$(read_uint_file "$out_dir/iface_tx_bytes.before")
	tx_after=$(read_uint_file "$out_dir/iface_tx_bytes.after")
	iface_tx_delta_bytes=$(delta_uint "$tx_before" "$tx_after")
	iface_tx_delta_packets=$(delta_uint \
		"$(read_uint_file "$out_dir/iface_tx_packets.before")" \
		"$(read_uint_file "$out_dir/iface_tx_packets.after")")

	softirq_total_delta=$(delta_uint \
		"$(proc_total "$out_dir/softirqs.before")" \
		"$(proc_total "$out_dir/softirqs.after")")
	softirq_net_tx_delta=$(delta_uint \
		"$(softirq_label_total "$out_dir/softirqs.before" NET_TX)" \
		"$(softirq_label_total "$out_dir/softirqs.after" NET_TX)")
	softirq_net_rx_delta=$(delta_uint \
		"$(softirq_label_total "$out_dir/softirqs.before" NET_RX)" \
		"$(softirq_label_total "$out_dir/softirqs.after" NET_RX)")
	softirq_net_delta=$((softirq_net_tx_delta + softirq_net_rx_delta))
	softirq_net_tx_percpu=$(softirq_delta_percpu \
		"$out_dir/softirqs.before" "$out_dir/softirqs.after" NET_TX)
	softirq_net_rx_percpu=$(softirq_delta_percpu \
		"$out_dir/softirqs.before" "$out_dir/softirqs.after" NET_RX)

	irq_total_delta=$(delta_uint \
		"$(proc_total "$out_dir/interrupts.before")" \
		"$(proc_total "$out_dir/interrupts.after")")
	irq_net_delta=$(delta_uint \
		"$(irq_net_total "$out_dir/interrupts.before")" \
		"$(irq_net_total "$out_dir/interrupts.after")")
}

collect_token() {
	local token_f hwq_f

	token_info_state=missing
	token_f=
	if [ -s "$out_dir/token_info.after" ]; then
		token_f="$out_dir/token_info.after"
	elif [ -s "$out_dir/token_info.before" ]; then
		token_f="$out_dir/token_info.before"
	fi
	if [ -n "$token_f" ]; then
		token_info_state=available
		token_count_before=$(num_or_unavail \
			"$(token_count "$out_dir/token_info.before")")
		token_count_after=$(num_or_unavail \
			"$(token_count "$out_dir/token_info.after")")
		token_count_max=$(num_or_unavail "$(token_max "$token_f")")
	fi

	hw_queues_state=missing
	hwq_f=
	if [ -s "$out_dir/hw-queues.after" ]; then
		hwq_f="$out_dir/hw-queues.after"
	elif [ -s "$out_dir/hw-queues.before" ]; then
		hwq_f="$out_dir/hw-queues.before"
	fi
	if [ -n "$hwq_f" ]; then
		hw_queues_state=available
		ple_free_before=$(field_or_unavail \
			"$(hwq_field "$out_dir/hw-queues.before" ple)")
		ple_free_after=$(field_or_unavail \
			"$(hwq_field "$out_dir/hw-queues.after" ple)")
		hif_reserved=$(field_or_unavail "$(hwq_field "$hwq_f" hif_reserved)")
		hif_used=$(field_or_unavail "$(hwq_field "$hwq_f" hif_used)")
	fi
}

collect_mpstat() {
	local idle

	if [ "$mpstat_ok" -ne 1 ]; then
		mpstat_state=missing
		return
	fi
	if [ ! -s "$out_dir/mpstat.txt" ]; then
		mpstat_state=failed
		return
	fi
	idle=$(awk '
		/^Average:/ && $2 == "all" { idle = $NF }
		END {
			if (idle ~ /^[0-9]+([.][0-9]+)?$/)
				printf "%.1f", 100 - idle
		}
	' "$out_dir/mpstat.txt")
	mpstat_state=available
	mpstat_avg_busy_pct=$(field_or_unavail "$idle")
}

build_summary() {
	local s

	s="arm=${arm_name} run=${run} status=${1} procs=${procs}"
	s="$s sockets=${sockets} offered_mbps=${rate} seconds=${seconds}"
	s="$s warmup=${warmup} iface=${iface:-none}"
	s="$s wiphy=${wiphy:-unavailable} client_arg=${client_arg:-none}"
	s="$s client_ip=${client_ip:-unavailable}"
	s="$s client_mac=${client_mac:-unavailable}"
	s="$s source_bin=${source_bin:-unavailable}"
	s="$s source_iface=${bind_iface:-none}"
	s="$s source_sent_bytes=${source_bytes} source_sent_pkts=${source_pkts}"
	s="$s source_elapsed_ms=${source_elapsed_ms} source_mbps=${source_mbps}"
	s="$s source_errors=${source_errors}"
	s="$s ap_tx_delta_bytes=${ap_tx_delta_bytes}"
	s="$s ap_tx_delta_packets=${ap_tx_delta_packets}"
	s="$s ap_tx_retries_delta=${ap_tx_retries_delta}"
	s="$s ap_tx_failed_delta=${ap_tx_failed_delta}"
	s="$s ap_rx_delta_bytes=${ap_rx_delta_bytes}"
	s="$s iface_tx_delta_bytes=${iface_tx_delta_bytes}"
	s="$s iface_tx_delta_packets=${iface_tx_delta_packets}"
	s="$s softirq_total_delta=${softirq_total_delta}"
	s="$s softirq_net_tx_delta=${softirq_net_tx_delta}"
	s="$s softirq_net_rx_delta=${softirq_net_rx_delta}"
	s="$s softirq_net_delta=${softirq_net_delta}"
	s="$s softirq_net_tx_percpu=${softirq_net_tx_percpu:-none}"
	s="$s softirq_net_rx_percpu=${softirq_net_rx_percpu:-none}"
	s="$s irq_total_delta=${irq_total_delta} irq_net_delta=${irq_net_delta}"
	s="$s client_signal_dbm=${client_signal_dbm}"
	s="$s client_signal_avg_dbm=${client_signal_avg_dbm}"
	s="$s client_tx_nss=${client_tx_nss} client_rx_nss=${client_rx_nss}"
	s="$s client_tx_rate_mbps=${client_tx_rate_mbps}"
	s="$s client_rx_rate_mbps=${client_rx_rate_mbps}"
	s="$s client_station=${client_station}"
	s="$s token_info=${token_info_state}"
	s="$s token_count_before=${token_count_before}"
	s="$s token_count_after=${token_count_after}"
	s="$s token_count_max=${token_count_max}"
	s="$s hw_queues=${hw_queues_state}"
	s="$s ple_free_before=${ple_free_before} ple_free_after=${ple_free_after}"
	s="$s hif_reserved=${hif_reserved} hif_used=${hif_used}"
	s="$s mpstat=${mpstat_state}"
	s="$s mpstat_avg_busy_pct=${mpstat_avg_busy_pct}"
	s="$s missing=${missing:-none} optional_missing=${optional:-none}"
	s="$s artifacts=${out_dir:-none}"
	printf '%s' "$s"
}

print_summary() {
	local summary

	summary=$(build_summary "$1")
	if [ -n "$out_dir" ] && [ -d "$out_dir" ]; then
		printf '%s\n' "$summary" > "$out_dir/summary.txt" 2>/dev/null || :
	fi
	printf '%s\n' "$summary"
}

# Invoked from the EXIT/INT/TERM traps below.
# shellcheck disable=SC2329
cleanup() {
	local p

	if [ -n "${pids-}" ]; then
		for p in $pids; do
			kill -TERM "$p" 2>/dev/null || :
		done
	fi
	if [ -n "${mpstat_pid-}" ]; then
		kill -TERM "$mpstat_pid" 2>/dev/null || :
	fi
	if [ -n "${pre_tmp-}" ] && [ -f "$pre_tmp" ]; then
		rm -f "$pre_tmp" 2>/dev/null || :
	fi
}

main() {
	local status cmdline a

	iface=
	client_arg=
	client_ip_opt=
	client_mac_opt=
	seconds=20
	procs=6
	sockets=4
	rate=1340
	port=5201
	pkt_size=1472
	warmup=1
	run=0
	out_dir=
	out_dir_opt=
	source_bin_opt=
	source_iface_opt=auto
	arm_name=
	pids=
	mpstat_pid=
	pre_tmp=
	missing=
	optional=
	missing_n=0
	optional_n=0
	wiphy=
	mt76dir=
	source_bin=
	bind_iface=
	iw_ok=0
	iface_ok=0
	station_ok=0
	token_info_ok=0
	hw_queues_ok=0
	mpstat_ok=0
	mpstat_cmd=
	client_mac=
	client_ip=
	cmdline="$0"
	for a in "$@"; do
		cmdline="$cmdline $a"
	done

	for a in "$@"; do
		case $a in
		--help|-h)
			usage
			exit 0
			;;
		esac
	done

	while [ $# -gt 0 ]; do
		case $1 in
		--iface)
			[ $# -ge 2 ] || die "--iface needs a value"
			iface=$2
			shift 2
			;;
		--iface=*)
			iface=${1#*=}
			shift
			;;
		--client)
			[ $# -ge 2 ] || die "--client needs a value"
			client_arg=$2
			shift 2
			;;
		--client=*)
			client_arg=${1#*=}
			shift
			;;
		--client-ip)
			[ $# -ge 2 ] || die "--client-ip needs a value"
			client_ip_opt=$2
			shift 2
			;;
		--client-ip=*)
			client_ip_opt=${1#*=}
			shift
			;;
		--client-mac)
			[ $# -ge 2 ] || die "--client-mac needs a value"
			client_mac_opt=$2
			shift 2
			;;
		--client-mac=*)
			client_mac_opt=${1#*=}
			shift
			;;
		--seconds)
			[ $# -ge 2 ] || die "--seconds needs a value"
			seconds=$2
			shift 2
			;;
		--seconds=*)
			seconds=${1#*=}
			shift
			;;
		--procs)
			[ $# -ge 2 ] || die "--procs needs a value"
			procs=$2
			shift 2
			;;
		--procs=*)
			procs=${1#*=}
			shift
			;;
		--sockets)
			[ $# -ge 2 ] || die "--sockets needs a value"
			sockets=$2
			shift 2
			;;
		--sockets=*)
			sockets=${1#*=}
			shift
			;;
		--rate)
			[ $# -ge 2 ] || die "--rate needs a value"
			rate=$2
			shift 2
			;;
		--rate=*)
			rate=${1#*=}
			shift
			;;
		--port)
			[ $# -ge 2 ] || die "--port needs a value"
			port=$2
			shift 2
			;;
		--port=*)
			port=${1#*=}
			shift
			;;
		--pkt-size)
			[ $# -ge 2 ] || die "--pkt-size needs a value"
			pkt_size=$2
			shift 2
			;;
		--pkt-size=*)
			pkt_size=${1#*=}
			shift
			;;
		--warmup)
			[ $# -ge 2 ] || die "--warmup needs a value"
			warmup=$2
			shift 2
			;;
		--warmup=*)
			warmup=${1#*=}
			shift
			;;
		--out-dir)
			[ $# -ge 2 ] || die "--out-dir needs a value"
			out_dir_opt=$2
			shift 2
			;;
		--out-dir=*)
			out_dir_opt=${1#*=}
			shift
			;;
		--source-bin)
			[ $# -ge 2 ] || die "--source-bin needs a value"
			source_bin_opt=$2
			shift 2
			;;
		--source-bin=*)
			source_bin_opt=${1#*=}
			shift
			;;
		--source-iface)
			[ $# -ge 2 ] || die "--source-iface needs a value"
			source_iface_opt=$2
			shift 2
			;;
		--source-iface=*)
			source_iface_opt=${1#*=}
			shift
			;;
		--run)
			run=1
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			die "unknown option: $1 (try --help)"
			;;
		*)
			die "unexpected argument: $1 (try --help)"
			;;
		esac
	done
	[ $# -eq 0 ] || die "unexpected argument: $1 (try --help)"

	is_uint "$seconds" || die "--seconds must be an integer"
	[ "$seconds" -ge 1 ] || die "--seconds must be at least 1"
	is_uint "$procs" || die "--procs must be an integer"
	[ "$procs" -ge 1 ] && [ "$procs" -le 64 ] ||
		die "--procs must be 1..64"
	is_uint "$sockets" || die "--sockets must be an integer"
	[ "$sockets" -ge 1 ] && [ "$sockets" -le 64 ] ||
		die "--sockets must be 1..64"
	is_uint "$rate" || die "--rate must be an integer Mbit/s"
	[ "$rate" -ge 1 ] || die "--rate must be at least 1"
	is_uint "$port" || die "--port must be an integer"
	[ "$port" -ge 1 ] && [ "$port" -le 65535 ] ||
		die "--port must be 1..65535"
	is_uint "$pkt_size" || die "--pkt-size must be an integer"
	[ "$pkt_size" -ge 18 ] && [ "$pkt_size" -le 65507 ] ||
		die "--pkt-size must be 18..65507"
	is_uint "$warmup" || die "--warmup must be an integer"
	[ "$warmup" -le 60 ] || die "--warmup must be 0..60"
	if [ -n "$client_mac_opt" ] && ! is_mac "$client_mac_opt"; then
		die "--client-mac must be a MAC address"
	fi

	case $0 in
	*/*) script_dir=${0%/*} ;;
	*) script_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) ;;
	esac
	[ -n "$script_dir" ] || script_dir=.

	trap cleanup EXIT
	trap 'cleanup; exit 130' INT TERM

	check_prereqs
	init_measurement
	arm_name=${iface:-noiface}-${procs}p-${rate}M-${sockets}s

	if [ "$run" -eq 0 ]; then
		note "dry-run: no traffic will be sent (pass --run to start the source)"
		report_checks
		populate_dry_client
		if [ "$mpstat_ok" -eq 1 ]; then
			mpstat_state=available
		fi
		if [ "$token_info_ok" -eq 1 ]; then
			token_info_state=available
		fi
		if [ "$hw_queues_ok" -eq 1 ]; then
			hw_queues_state=available
		fi
		print_summary dry-run
		exit 0
	fi

	if [ "$missing_n" -gt 0 ]; then
		note "refusing to run: missing required prerequisites"
		report_checks
		[ "$source_ok" -eq 1 ] || source_hint
		print_summary missing-prereqs
		exit 1
	fi

	if [ -n "$out_dir_opt" ]; then
		out_dir=$out_dir_opt
	else
		out_dir="/tmp/a-path.$(date +%Y%m%d-%H%M%S)-$$"
	fi
	if ! mkdir -p "$out_dir"; then
		note "cannot create artifact directory: $out_dir"
		out_dir=
		print_summary failed
		exit 1
	fi
	printf '%s\n' "$cmdline" > "$out_dir/cmdline" 2>/dev/null || :

	note "source=${source_bin} iface=${iface} client=${client_ip}/${client_mac}"
	note "measurement: ${seconds}s after ${warmup}s warm-up," \
		"rate=${rate} Mbit/s in ${procs}x${sockets} sockets"

	start_senders
	sleep "$warmup"
	snapshot before
	start_mpstat
	sleep "$seconds"
	snapshot after
	stop_senders
	stop_mpstat

	collect_source
	collect_client
	collect_counters
	collect_token
	collect_mpstat

	if [ "$source_bytes" -gt 0 ] && [ "$ap_tx_delta_bytes" = 0 ]; then
		note "warning: source sent ${source_bytes} bytes but the" \
			"station tx delta is zero; check --source-iface and the client MAC"
	fi

	if [ "$source_bytes" -eq 0 ]; then
		status=failed
	elif [ "$source_fail" -gt 0 ] || [ "$source_errors" -gt 0 ] ||
	     [ "$client_station" != after ] ||
	     [ "$client_signal_dbm" = unavailable ] ||
	     [ "$client_tx_nss" = unavailable ] ||
	     ! is_uint "$ap_tx_delta_bytes"; then
		status=degraded
	else
		status=ok
	fi
	print_summary "$status"
	[ "$status" = failed ] && exit 1
	exit 0
}

main "$@"
