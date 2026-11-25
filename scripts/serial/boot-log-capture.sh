#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Capture one XR1710G boot log, from serial when the port exists and from
# ssh/dmesg when it does not, then print the boot anchors.
#
# Usage:
#   scripts/serial/boot-log-capture.sh [--device PORT] [--seconds N]
#                                      [--out FILE] [--ssh HOST] [--reboot]
#                                      [--via auto|serial|ssh] [--dry-run]
#
# The serial path records raw bytes for N seconds; --reboot restarts the
# board over ssh first so the capture covers U-Boot and the kernel handoff.
# The ssh path runs dmesg (full ring buffer, or -w for N seconds) and marks
# the file as captured through ssh.

set -eu

prog=${0##*/}
seconds=60
device=''
out=''
ssh_host=root@192.168.1.1
reboot=0
via=auto
dry_run=0

anchors='U-Boot|Starting kernel|airoha|mt7996|panic|Call trace|fw'

usage() {
	cat <<EOF
usage: $prog [--device PORT] [--seconds N] [--out FILE] [--ssh HOST]
              [--reboot] [--via auto|serial|ssh] [--dry-run]

  --device PORT   serial port (default: first existing /dev/ttyUSB0,
                  /dev/ttyUSB1, /dev/ttyACM0)
  --seconds N     capture window (default 60)
  --out FILE      log path (default logs/boot-\$(git rev-parse --short HEAD).log)
  --ssh HOST      ssh target used for the dmesg fallback and --reboot
  --reboot        reboot the board over ssh, then capture from the port
  --via MODE      auto (default) prefers serial, ssh forces dmesg
  --dry-run       print what would run and exit 0
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--device) device=${2:?--device needs a value}; shift 2 ;;
	--seconds) seconds=${2:?--seconds needs a value}; shift 2 ;;
	--out) out=${2:?--out needs a value}; shift 2 ;;
	--ssh) ssh_host=${2:?--ssh needs a value}; shift 2 ;;
	--reboot) reboot=1; shift ;;
	--via) via=${2:?--via needs a value}; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "$prog: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case $via in
auto | serial | ssh) ;;
*) echo "$prog: --via must be auto, serial or ssh" >&2; exit 2 ;;
esac

case $seconds in
'' | *[!0-9]*) echo "$prog: --seconds must be a positive integer" >&2; exit 2 ;;
esac

find_device() {
	for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyACM0; do
		[ -e "$p" ] && { echo "$p"; return 0; }
	done
	return 1
}

if [ -z "$out" ]; then
	rev=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
	out="logs/boot-$rev.log"
fi

have_serial=0
if [ "$via" != ssh ]; then
	[ -n "$device" ] || device=$(find_device) || device=''
	[ -n "$device" ] && [ -e "$device" ] && have_serial=1
fi

if [ "$via" = serial ] && [ "$have_serial" -eq 0 ]; then
	echo "$prog: --via serial but no serial port is present" >&2
	echo "$prog: attach the CH340 first (usbipd list / usbipd attach --wsl), 115200 8N1" >&2
	exit 3
fi

out_dir=$(dirname -- "$out")

if [ "$dry_run" -eq 1 ]; then
	echo "out=$out seconds=$seconds via=$via serial=$have_serial ssh=$ssh_host reboot=$reboot"
	if [ "$have_serial" -eq 1 ]; then
		echo "exec: mkdir -p $out_dir; stty -F $device 115200 cs8 -cstopb -parenb raw -echo; timeout $seconds cat $device > $out"
		[ "$reboot" -eq 1 ] && echo "exec: ssh $ssh_host reboot   (fires just before the capture)"
	else
		echo "exec: mkdir -p $out_dir; ssh $ssh_host 'dmesg' > $out   (serial unavailable, captured via ssh)"
		[ "$reboot" -eq 1 ] && echo "exec: ssh $ssh_host reboot   (then wait and capture dmesg, not U-Boot)"
	fi
	exit 0
fi

mkdir -p "$out_dir"

rebooted=0
old_boot_id=''
if [ "$have_serial" -eq 1 ]; then
	echo "capturing $seconds s of raw serial from $device -> $out"
	if ! stty -F "$device" 115200 cs8 -cstopb -parenb raw -echo; then
		if [ "$via" = serial ]; then
			echo "$prog: stty failed on $device" >&2
			exit 3
		fi
		echo "$prog: stty failed on $device; falling back to ssh dmesg" >&2
		have_serial=0
	fi
fi

if [ "$have_serial" -eq 1 ]; then
	if [ "$reboot" -eq 1 ]; then
		old_boot_id=$(ssh -o ConnectTimeout=5 "$ssh_host" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
		# best effort: rebooting closes the ssh session, that is expected
		ssh -o ConnectTimeout=5 "$ssh_host" 'reboot' >/dev/null 2>&1 || true
		rebooted=1
	fi
	timeout "$seconds" cat "$device" >"$out" 2>/dev/null || true
	if [ ! -s "$out" ]; then
		if [ "$via" = serial ]; then
			echo "$prog: --via serial produced no bytes from $device" >&2
			exit 3
		fi
		echo "$prog: serial produced no bytes; falling back to ssh dmesg" >&2
		have_serial=0
	fi
	if [ "$have_serial" -eq 1 ]; then
		echo "captured $(wc -c <"$out") bytes via serial"
	fi
fi

if [ "$have_serial" -eq 0 ]; then
	echo "$prog: serial unavailable, captured via ssh" >&2
	dmesg_tmp="$out.dmesg"
	rm -f "$dmesg_tmp"
	if [ "$reboot" -eq 1 ]; then
		if [ "$rebooted" -eq 0 ]; then
			old_boot_id=$(ssh -o ConnectTimeout=10 "$ssh_host" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) || old_boot_id=''
			if [ -z "$old_boot_id" ]; then
				echo "$prog: cannot read /proc/sys/kernel/random/boot_id from $ssh_host before reboot" >&2
				exit 4
			fi
			echo "$prog: rebooting $ssh_host over ssh, then waiting up to ${seconds}s for new boot_id and dmesg" >&2
			ssh -o ConnectTimeout=5 "$ssh_host" 'reboot' >/dev/null 2>&1 || true
			rebooted=1
		else
			echo "$prog: waiting up to ${seconds}s for $ssh_host to finish rebooting for ssh dmesg" >&2
		fi
		deadline=$(( $(date +%s) + seconds ))
		dmesg_ok=0
		while :; do
			new_boot_id=$(ssh -o ConnectTimeout=5 "$ssh_host" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
			if [ -n "$new_boot_id" ] && { [ -z "$old_boot_id" ] || [ "$new_boot_id" != "$old_boot_id" ]; }; then
				if ssh -o ConnectTimeout=5 "$ssh_host" 'dmesg' >"$dmesg_tmp" 2>/dev/null && [ -s "$dmesg_tmp" ]; then
					dmesg_ok=1
					break
				fi
			fi
			now=$(date +%s)
			[ "$now" -lt "$deadline" ] || break
			rem=$((deadline - now))
			[ "$rem" -gt 2 ] && rem=2
			sleep "$rem"
		done
		if [ "$dmesg_ok" -ne 1 ]; then
			rm -f "$dmesg_tmp"
			echo "$prog: ssh dmesg failed after reboot (new boot_id not observed within ${seconds}s)" >&2
			exit 4
		fi
	else
		ssh -o ConnectTimeout=10 "$ssh_host" 'dmesg' >"$dmesg_tmp" 2>/dev/null || {
			rm -f "$dmesg_tmp"
			echo "$prog: ssh dmesg failed" >&2
			exit 4
		}
	fi
	printf '# serial unavailable, captured via ssh %s, %s\n' "$ssh_host" "$(date -Is)" >"$out"
	cat "$dmesg_tmp" >>"$out"
	rm -f "$dmesg_tmp"
	echo "captured $(wc -l <"$out") lines via ssh dmesg -> $out"
fi

echo "--- boot anchors ($out)"
anchor_hits=$(grep -nE "$anchors" "$out" 2>/dev/null | head -n 40 || true)
if [ -n "$anchor_hits" ]; then
	printf '%s\n' "$anchor_hits"
else
	echo "no anchors matched"
fi
echo "--- first lines"
head -n 20 "$out"
