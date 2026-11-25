#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Open a 115200 8N1 console on the XR1710G serial port.
#
# Picks whichever of picocom / minicom / screen / cu is installed, in that
# order, and passes the port plus optional raw log through to it.
#
# Usage:
#   scripts/serial/xr1710g-console.sh [--device PORT] [--log FILE] [--dry-run]
#
# Exit codes: 0 ok, 2 bad usage, 3 no serial port / no console tool.

set -eu

prog=${0##*/}
baud=115200
device=''
logfile=''
dry_run=0

usage() {
	cat <<EOF
usage: $prog [--device PORT] [--log FILE] [--dry-run]

  --device PORT   serial port (default: first of /dev/ttyUSB0, /dev/ttyUSB1,
                  /dev/ttyACM0 that exists)
  --log FILE      write raw console bytes to FILE (picocom/minicom/screen;
                  cu cannot log, use screen when a log is required)
  --dry-run       print the resolved command and exit 0
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--device) device=${2:?--device needs a value}; shift 2 ;;
	--log) logfile=${2:?--log needs a value}; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "$prog: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

find_device() {
	for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyACM0; do
		[ -e "$p" ] && { echo "$p"; return 0; }
	done
	return 1
}

find_tool() {
	for t in picocom minicom screen cu; do
		command -v "$t" >/dev/null 2>&1 && { echo "$t"; return 0; }
	done
	return 1
}

if [ -z "$device" ]; then
	device=$(find_device) || {
		if [ "$dry_run" -eq 1 ]; then
			echo "tool=none device=none (no /dev/ttyUSB* found; would exit 3)"
			echo "hint: attach the CH340 (usbipd list -> usbipd attach --wsl), 115200 8N1"
			exit 0
		fi
		echo "$prog: no /dev/ttyUSB* or /dev/ttyACM* present." >&2
		echo "$prog: check the CH340 is attached (usbipd list / usbipd attach --wsl), 115200 8N1" >&2
		exit 3
	}
fi

if [ ! -e "$device" ] && [ "$dry_run" -eq 0 ]; then
	echo "$prog: $device does not exist" >&2
	exit 3
fi

tool=$(find_tool) || {
	echo "$prog: none of picocom, minicom, screen, cu is installed" >&2
	echo "$prog: apt install -y picocom  (or use screen, already present)" >&2
	exit 3
}

case $tool in
picocom)
	set -- picocom -b "$baud" -d 8 -y n -p 1 -l
	[ -n "$logfile" ] && set -- "$@" -g "$logfile"
	set -- "$@" "$device"
	;;
minicom)
	set -- minicom -D "$device" -b "$baud"
	[ -n "$logfile" ] && set -- "$@" -C "$logfile"
	;;
screen)
	set -- screen -L -Logfile "${logfile:-/tmp/xr1710g-console.log}" "$device" "$baud,cs8"
	;;
cu)
	if [ -n "$logfile" ]; then
		echo "$prog: cu cannot log raw bytes; install picocom or use screen" >&2
		exit 2
	fi
	set -- cu -l "$device" -s "$baud"
	;;
esac

if [ "$dry_run" -eq 1 ]; then
	echo "tool=$tool device=$device baud=$baud data=8 parity=N stop=1"
	printf 'exec:'
	printf ' %s' "$@"
	printf '\n'
	exit 0
fi

if [ ! -r "$device" ] || [ ! -w "$device" ]; then
	echo "$prog: $device is not read/write for $USER" >&2
	echo "$prog: sudo usermod -aG dialout $USER   (then log out and back in)" >&2
	echo "$prog: or run once with: sudo chmod 660 $device" >&2
fi

exec "$@"
