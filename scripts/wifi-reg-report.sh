#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# wifi-reg-report.sh - report the regulatory decision and the widths that
# actually came up on the XR1710G.
#
# radio1 (5 GHz) and radio2 (6 GHz) share one MT7996 wiphy and therefore one
# cfg80211 regulatory domain.  UCI can ask for one width and the kernel can
# bring up another: with radio1=CN and radio2=US only the domain of the
# radio netifd applied last is in force for both bands.  This script prints
# a JSON snapshot so that the UCI request, the effective domain and the live
# width/center1 of every interface can be compared side by side.
#
# It is read-only: no 'iw reg set', no 'uci set' and no commit.  Run it on
# the AP after wifi starts:
#
#   scp scripts/wifi-reg-report.sh root@xr1710g:/tmp/
#   ssh root@xr1710g sh /tmp/wifi-reg-report.sh | jq .
#
# --dry-run uses a built-in XR1710G sample and needs no device.  That sample
# is not a hardware result: it only exercises the report format.
#
# POSIX sh and busybox awk only.  No temporary files.
#
# Usage:
#   scripts/wifi-reg-report.sh
#   scripts/wifi-reg-report.sh --dry-run
#   scripts/wifi-reg-report.sh --help
#
# Exit status: 0 okay, 2 usage error or a missing required tool.

set -u

PROG=${0##*/}
MODE=live

usage() {
	cat <<EOF
Usage: $PROG [--dry-run]

Print a JSON snapshot of the XR1710G regulatory decision:
  - 'iw reg get' (raw and the parsed global country),
  - the UCI band/country/channel/htmode of radio1 and radio2,
  - every 'iw dev' interface that has a channel, with its width and
    center1 and the band inferred from the frequency.

  --dry-run   use the built-in XR1710G sample instead of the live device
  -h, --help  show this help

The script is read-only: it runs no 'iw set', 'uci set' or commit.
EOF
}

for arg in "$@"; do
	case "$arg" in
	--dry-run) MODE=dry-run ;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		printf '%s: unknown option: %s\n' "$PROG" "$arg" >&2
		usage >&2
		exit 2
		;;
	esac
done

if [ "$MODE" = live ]; then
	for tool in iw uci; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			printf '%s: required command not found: %s\n' "$PROG" "$tool" >&2
			exit 2
		fi
	done
fi

# Built-in sample for --dry-run.  Keep the 'iw dev' text in the format the
# kernel uses: one phy# header, then one interface block per radio.
fixture_dev() {
	cat <<'EOF'
phy#0
	Interface phy0.1-ap0
		ifindex 43
		wdev 0xf
		addr 00:58:28:d7:44:60
		ssid XR1710G
		type AP
		channel 149 (5745 MHz), width: 80 MHz, center1: 5775 MHz
	Interface phy0.2-ap0
		ifindex 9
		wdev 0x2
		addr 00:58:28:d7:44:61
		ssid XR1710G-6G
		type AP
		channel 37 (6135 MHz), width: 320 MHz, center1: 6105 MHz
EOF
}

fixture_reg() {
	cat <<'EOF'
global
country US: DFS-FCC
	(902 - 904 @ 2), (N/A, 30), (N/A)
	(904 - 920 @ 16), (N/A, 30), (N/A)
	(920 - 928 @ 8), (N/A, 30), (N/A)
	(2400 - 2472 @ 40), (N/A, 30), (N/A)
	(5150 - 5250 @ 80), (N/A, 23), (N/A), AUTO-BW
	(5250 - 5350 @ 80), (N/A, 24), (0 ms), DFS, AUTO-BW
	(5470 - 5730 @ 160), (N/A, 24), (0 ms), DFS
	(5730 - 5895 @ 160), (N/A, 30), (N/A), AUTO-BW
	(5925 - 7125 @ 320), (N/A, 30), (N/A), NO-OUTDOOR
	(57240 - 71000 @ 2160), (N/A, 40), (N/A)
EOF
}

fixture_uci() {
	case "$1.$2" in
	radio1.band) printf '5g' ;;
	radio1.country) printf 'CN' ;;
	radio1.channel) printf '149' ;;
	radio1.htmode) printf 'EHT80' ;;
	radio2.band) printf '6g' ;;
	radio2.country) printf 'US' ;;
	radio2.channel) printf '37' ;;
	radio2.htmode) printf 'EHT320' ;;
	esac
}

read_uci() {
	if [ "$MODE" = dry-run ]; then
		fixture_uci "$1" "$2"
	else
		uci -q get "wireless.$1.$2" 2>/dev/null || true
	fi
}

if [ "$MODE" = dry-run ]; then
	board=gemtek,xr1710g-ubi
	origin='built-in sample (not a hardware result)'
	iw_dev=$(fixture_dev)
	reg_raw=$(fixture_reg)
else
	board=$(cat /tmp/sysinfo/board_name 2>/dev/null || true)
	origin=live
	iw_dev=$(iw dev 2>/dev/null || true)
	reg_raw=$(iw reg get 2>/dev/null || true)
fi

reg_global=$(printf '%s\n' "$reg_raw" | awk '
	/^country [A-Za-z0-9][A-Za-z0-9]:/ {
		country = $2
		sub(/:$/, "", country)
		print country
		exit
	}')

# Case folding uses the ASCII range 'a-z' 'A-Z' on purpose.  The tr on this
# image (BusyBox v1.38.0) does not implement the [:lower:]/[:upper:] classes:
# it copies them through unchanged, so `echo cn | tr '[:lower:]' '[:upper:]'`
# prints `cn` and the report would compare `cn` against `CN`.
norm_country() {
	case "${1:-}" in
	[A-Za-z][A-Za-z])
		# BusyBox tr has no [:lower:]/[:upper:] classes; keep the range.
		# shellcheck disable=SC2018,SC2019
		printf '%s' "$1" | tr 'a-z' 'A-Z'
		;;
	esac
}

country1=$(norm_country "$(read_uci radio1 country)")
country2=$(norm_country "$(read_uci radio2 country)")
if [ -n "$country1" ] && [ -n "$country2" ] && [ "$country1" != "$country2" ]; then
	conflict=true
else
	conflict=false
fi

# 'iw dev' groups interfaces under a phy# header.  Emit one tab-separated
# record per interface that has a channel line; the width and center1 are
# numbers in MHz, and center1 is absent for 20 MHz.
parse_iw_dev() {
	awk '
	/^phy#/ {
		phy = "phy" substr($0, 5)
		next
	}
	/^[ \t]*Interface / {
		ifname = $2
		next
	}
	/^[ \t]*channel [0-9]/ {
		channel = $2
		freq = $3
		gsub(/[()]/, "", freq)
		# Force a numeric comparison below; awk would compare the
		# remaining string lexically against the numeric literals.
		freq += 0
		width = ""
		center1 = ""
		for (i = 4; i <= NF; i++) {
			if ($i == "width:")
				width = $(i + 1)
			else if ($i == "center1:")
				center1 = $(i + 1)
		}
		if (freq >= 2400 && freq < 2500)
			band = "2g"
		else if (freq >= 4900 && freq < 5925)
			band = "5g"
		else if (freq >= 5925 && freq <= 7125)
			band = "6g"
		else if (freq >= 57000)
			band = "60g"
		else
			band = "unknown"
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", phy, ifname, channel, freq, band, width, center1
	}'
}

iface_lines=$(printf '%s\n' "$iw_dev" | parse_iw_dev)

# Escape one JSON string body.  This walks the string byte by byte instead of
# using gsub() on purpose.  BusyBox v1.38.0 awk processes backslash escapes in
# a gsub() *replacement*, while gawk/mawk copy them through: measured on the
# device, `gsub(/\t/, "\\t")` emits a bare `t` (the reg.raw tabs turned into
# "t(902 - ..."), so the same replacement cannot be correct on both.  String
# literals are parsed identically everywhere, so building the output with
# literal concatenation needs no per-awk branch.  Input is ASCII (iw/uci).
json_escape() {
	awk 'BEGIN { ORS = "" }
	function escape(s,   out, i, c) {
		out = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\\")
				out = out "\\\\"
			else if (c == "\"")
				out = out "\\\""
			else if (c == "\t")
				out = out "\\t"
			else if (c == "\r")
				out = out "\\r"
			else
				out = out c
		}
		return out
	}
	{
		if (NR > 1)
			printf "\\n"
		printf "%s", escape($0)
	}'
}

json_str() {
	printf '"'
	printf '%s' "${1:-}" | json_escape
	printf '"'
}

json_str_or_null() {
	if [ -z "${1:-}" ]; then
		printf 'null'
	else
		json_str "$1"
	fi
}

json_num() {
	case "${1:-}" in
	''|*[!0-9]*) printf 'null' ;;
	*) printf '%s' "$1" ;;
	esac
}

printf '{\n'
printf '  "generated_at": %s,\n' "$(json_str "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
printf '  "source": %s,\n' "$(json_str "$origin")"
printf '  "board": %s,\n' "$(json_str_or_null "$board")"
printf '  "uci_country_conflict": %s,\n' "$conflict"
printf '  "uci": {\n'
first=1
for radio in radio1 radio2; do
	[ "$first" -eq 1 ] || printf ',\n'
	first=0
	printf '    "%s": {"band": %s, "country": %s, "channel": %s, "htmode": %s}' \
		"$radio" \
		"$(json_str_or_null "$(read_uci "$radio" band)")" \
		"$(json_str_or_null "$(read_uci "$radio" country)")" \
		"$(json_str_or_null "$(read_uci "$radio" channel)")" \
		"$(json_str_or_null "$(read_uci "$radio" htmode)")"
done
printf '\n  },\n'
printf '  "reg": {\n'
printf '    "global": %s,\n' "$(json_str_or_null "$reg_global")"
printf '    "raw": %s\n' "$(json_str "$reg_raw")"
printf '  },\n'
printf '  "interfaces": ['
first=1
while IFS='	' read -r phy ifname channel freq band width center1; do
	[ -n "$phy" ] || continue
	[ "$first" -eq 1 ] || printf ','
	first=0
	printf '\n    {"phy": %s, "ifname": %s, "band": %s, "channel": %s, "freq_mhz": %s, "width_mhz": %s, "center1_mhz": %s}' \
		"$(json_str "$phy")" \
		"$(json_str_or_null "$ifname")" \
		"$(json_str "$band")" \
		"$(json_num "$channel")" \
		"$(json_num "$freq")" \
		"$(json_num "$width")" \
		"$(json_num "$center1")"
done <<EOF
$iface_lines
EOF
printf '\n  ]\n'
printf '}\n'
