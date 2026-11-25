#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Shared bridge detach/restore for the wired harnesses (issue #70).
#
# A 2.5G data port on a base tree sits in br-lan, so the harness stops at
# "BLOCKED: <port> is in br-lan" and prints the two "ip link set" commands an
# operator has to type.  This library is the same two commands, run by the
# harness itself when --detach-port asked for it, plus the restore that must
# happen on every exit path.
#
# Contract:
#
#   PD_EXEC    runner for one remote command string.  Harnesses set
#              PD_EXEC=ssh_dev so every read and every write goes to the
#              device; unset means "run it here" (sh -c), which is what the
#              netns test in scripts/tests/test_2g5_detach_port.py uses to
#              drive a real veth + bridge.
#   PD_SYSFS   device sysfs root (default /sys; the harnesses pass DEV_SYSFS).
#   PROG       name used in messages (the harness sets it).
#
#   pd_detach PORT   record PORT's current master and state, then
#                    `ip link set PORT nomaster`, then wait until the port is
#                    gone from the bridge's brif list.  Returns non-zero with
#                    a message on stderr when the port is absent, the
#                    nomaster call fails, or the port is still in brif.  The
#                    restore is armed before the write, so a failed call
#                    still leaves PD_DETACHED=1 for the EXIT trap to re-probe.
#   pd_restore       put PORT back into the recorded master and verify it.
#                    Idempotent, safe to call twice (EXIT trap after an
#                    explicit restore), and it reports the exact command to
#                    run by hand when it cannot restore.  A failure sets
#                    PD_RESTORE_FAILED=1 and returns non-zero; callers must
#                    turn that into a non-zero exit status, never swallow it.
#   pd_detached      true when this library currently holds a detached port.
#
# shellcheck disable=SC3043  # "local" is used by every harness in this tree
#
# The link itself is not bounced and carrier/speed are unchanged, but on the
# real board the bridge does re-run its state machine for the port: detaching
# lan2 on the XR1710G logs "port 1(lan2) entered blocking state ... disabled
# state" and then "blocking state ... forwarding state" again on the restore
# (uptime 54340, 2026-11-22).  That window is sub-second and the 20 x 0.1 s
# waits below cover it, so the arm starts from the same carrier and speed the
# pre-detach probe recorded.  Whether the peer NIC renegotiates is unproven;
# it does not have to, because the detach never touches the PHY.  The
# operator-facing plan in the harness still prints down/nomaster/up, which
# is the conservative manual recipe.

PD_SYSFS=${PD_SYSFS:-/sys}
PD_PORT=
PD_MASTER=
PD_PRE_OPERSTATE=
PD_PRE_SPEED=
PD_DETACHED=0
# Callers read this after pd_restore/pd_detach; here it is only written.
# shellcheck disable=SC2034
PD_RESTORE_FAILED=0
PD_RESTORE_HINT=

pd_note() {
	printf '%s: %s\n' "${PROG:-port-detach}" "$1" >&2
}

pd_error() {
	printf '%s: error: %s\n' "${PROG:-port-detach}" "$1" >&2
}

pd_exec() {
	# One command string, run on the device (PD_EXEC=ssh_dev) or here.
	case ${PD_EXEC-} in
	'') sh -c "$1" ;;
	*) "$PD_EXEC" "$1" ;;
	esac
}

pd_field() {
	# pd_field KEY PROBE-OUTPUT: the value of one KEY= line, empty if absent.
	printf '%s\n' "$2" | sed -n "s/^$1=//p" | sed -n '1p'
}

pd_probe() {
	# pd_probe PORT -> master=, operstate=, speed=, carrier= lines, or
	# absent=1 when the netdev does not exist.  One round trip: the pre-state
	# and the post-detach verification read the same four files.
	local _pd_port=$1
	# shellcheck disable=SC2029  # $PD_SYSFS expands here on purpose
	pd_exec "d=$PD_SYSFS/class/net/$_pd_port
if [ -d \"\$d\" ]; then
	printf 'master=%s\n' \"\$(readlink \"\$d/master\" 2>/dev/null | sed 's#.*/##')\"
	printf 'operstate=%s\n' \"\$(cat \"\$d/operstate\" 2>/dev/null)\"
	printf 'speed=%s\n' \"\$(cat \"\$d/speed\" 2>/dev/null)\"
	printf 'carrier=%s\n' \"\$(cat \"\$d/carrier\" 2>/dev/null)\"
else
	printf 'absent=1\n'
fi"
}

pd_sleep() {
	# Bridge membership changes land synchronously, so this is a safety net
	# for a slow device, not the mechanism.  busybox sleep may reject "0.1".
	sleep 0.1 2>/dev/null || sleep 1
}

pd_ssh_ingress_port() {
	# pd_ssh_ingress_port BRIDGE: the bridge port that carries the SSH
	# client's MAC, or empty when that cannot be resolved.  "ip route get"
	# answers "dev br-lan" for every bridged client, so it cannot tell lan2
	# from lan3; the fdb entry can.  An empty answer is a note, not a
	# refusal, because the "bridge" tool is not on every image; callers
	# decide what to do with it.
	local bridge=$1 ip mac
	# shellcheck disable=SC2016  # SSH_CLIENT must expand on the device
	ip=$(pd_exec 'printf "%s" "${SSH_CLIENT%% *}"' 2>/dev/null) || return 0
	ip=${ip%%\%*}
	case ${ip-} in
	''|*[!0-9a-fA-F.:]*) return 0 ;;
	*.*|*:*) ;;
	*) return 0 ;;
	esac
	mac=$(pd_exec "ip neigh show \"$ip\" dev \"$bridge\" 2>/dev/null" | awk '{
			for (i = 1; i <= NF; i++)
				if ($i == "lladdr") {
					print $(i + 1)
					exit
				}
		}')
	[ -n "$mac" ] || return 0
	pd_exec "command -v bridge >/dev/null 2>&1" || return 0
	pd_exec "bridge fdb show br $bridge 2>/dev/null" | awk \
		-v m="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')" '
		tolower($1) == m {
			for (i = 1; i <= NF; i++)
				if ($i == "dev") {
					print $(i + 1)
					exit
				}
		}'
}

pd_wait_master() {
	# pd_wait_master PORT WANT: wait until PORT's master reads WANT ("" for
	# none).  A port that never loses its master must not be measured on.
	local port=$1 want=$2 i=0 got=
	while [ "$i" -lt 20 ]; do
		got=$(pd_field master "$(pd_probe "$port")")
		if [ "$got" = "$want" ]; then
			return 0
		fi
		i=$((i + 1))
		pd_sleep
	done
	pd_error "port $port master is '${got:-none}', expected '${want:-none}' after 20 polls"
	return 1
}

pd_wait_brif_gone() {
	# pd_wait_brif_gone PORT BRIDGE: the master symlink can be gone while the
	# bridge still lists the port in brif, and a switch that still lists it
	# keeps forwarding.  Both have to be clear before the arm runs.
	local port=$1 bridge=$2 i=0
	while [ "$i" -lt 20 ]; do
		if ! pd_exec "test -e $PD_SYSFS/class/net/$bridge/brif/$port"; then
			return 0
		fi
		i=$((i + 1))
		pd_sleep
	done
	pd_error "port $port is still listed in $bridge/brif after 20 polls"
	return 1
}

pd_wait_brif_present() {
	# pd_wait_brif_present PORT BRIDGE: mirror pd_wait_brif_gone on restore.
	local port=$1 bridge=$2 i=0
	while [ "$i" -lt 20 ]; do
		if pd_exec "test -e $PD_SYSFS/class/net/$bridge/brif/$port"; then
			return 0
		fi
		i=$((i + 1))
		pd_sleep
	done
	pd_error "port $port is not listed in $bridge/brif after 20 polls"
	return 1
}

pd_detached() {
	[ "$PD_DETACHED" = 1 ]
}

pd_detach() {
	local port=$1 state master

	state=$(pd_probe "$port")
	if [ -n "$(pd_field absent "$state")" ]; then
		pd_error "port $port does not exist under $PD_SYSFS/class/net"
		return 1
	fi
	master=$(pd_field master "$state")
	if [ -z "$master" ]; then
		pd_note "port $port is not in a bridge; nothing to detach"
		PD_PORT=$port
		PD_MASTER=
		return 0
	fi

	PD_PORT=$port
	PD_MASTER=$master
	PD_PRE_OPERSTATE=$(pd_field operstate "$state")
	PD_PRE_SPEED=$(pd_field speed "$state")
	# Armed *before* the write: the remote call can fail after the netlink
	# change already landed (ssh drops, the device reboots mid-command), so
	# "failed" does not mean "untouched".  pd_restore re-probes and is
	# idempotent when the port never moved.
	PD_DETACHED=1
	PD_RESTORE_HINT="ip link set $port master $master"
	pd_note "detach: $port is in $master; pre-state operstate=${PD_PRE_OPERSTATE:-unknown} speed=${PD_PRE_SPEED:-unknown} Mb/s carrier=$(pd_field carrier "$state")"

	if ! pd_exec "ip link set $port nomaster"; then
		pd_error "ip link set $port nomaster failed; $port's state is unknown - the exit trap will re-probe and restore it from $master"
		return 1
	fi
	pd_wait_master "$port" "" || return 1
	pd_wait_brif_gone "$port" "$master" || return 1
	pd_note "detached: $port is out of $master; on exit: $PD_RESTORE_HINT"
	return 0
}

pd_restore() {
	local got

	[ "$PD_DETACHED" = 1 ] || return 0

	if [ -z "$PD_MASTER" ]; then
		# shellcheck disable=SC2034
		PD_RESTORE_FAILED=1
		pd_error "no recorded master for $PD_PORT; check the device by hand"
		return 1
	fi

	# Rebuilt here, not only in pd_detach: a restore has to be able to name
	# its own command even when the detach ran in an earlier shell.
	PD_RESTORE_HINT="ip link set $PD_PORT master $PD_MASTER"

	# Probe first so restore is idempotent when the port never left its
	# master (e.g. nomaster failed before changing netlink state).
	got=$(pd_field master "$(pd_probe "$PD_PORT")")
	if [ "$got" = "$PD_MASTER" ] &&
		pd_exec "test -e $PD_SYSFS/class/net/$PD_MASTER/brif/$PD_PORT"; then
		PD_DETACHED=0
		pd_note "restored: $PD_PORT is already in $PD_MASTER"
		return 0
	fi

	pd_note "restore: $PD_RESTORE_HINT"
	if ! pd_exec "$PD_RESTORE_HINT"; then
		# shellcheck disable=SC2034
		PD_RESTORE_FAILED=1
		pd_error "could not put $PD_PORT back into $PD_MASTER (bridge gone?); the port is still out of it - run on the device: $PD_RESTORE_HINT (a reboot or 'ifup ${PD_MASTER#br-}' also re-attaches it)"
		return 1
	fi
	if ! pd_wait_master "$PD_PORT" "$PD_MASTER"; then
		# shellcheck disable=SC2034
		PD_RESTORE_FAILED=1
		pd_error "restored $PD_PORT but its master did not settle to '$PD_MASTER' - run on the device: $PD_RESTORE_HINT"
		return 1
	fi
	if ! pd_wait_brif_present "$PD_PORT" "$PD_MASTER"; then
		# shellcheck disable=SC2034
		PD_RESTORE_FAILED=1
		pd_error "restored $PD_PORT but $PD_MASTER/brif/$PD_PORT is absent - run on the device: $PD_RESTORE_HINT"
		return 1
	fi
	PD_DETACHED=0
	pd_note "restored: $PD_PORT is back in $PD_MASTER"
	return 0
}
