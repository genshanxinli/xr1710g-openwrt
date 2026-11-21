# SPDX-License-Identifier: GPL-2.0-or-later
# Shared "no client" record for the wireless harnesses.
#
# A harness that cannot measure because the board has no client used to print
# a bare "SKIP:" line and exit 0.  Nothing was left behind, so a later reader
# could not tell "no hardware" from "the tool was never run", and the tickets
# blocked on one missing radio stayed blocked forever.  Every harness now
# writes the same structured record instead:
#
#   {
#     "schema": "wireless-no-client/v1",
#     "script": "6g-rx.sh",
#     "ticket": "48",
#     "status": "no-client",
#     "missing": "6ghz-eht-client",
#     "command": "sh scripts/wireless/6g-rx.sh --sta-ip <STA_IP>",
#     "reason": "no 6G-only BSS with an associated station",
#     "criteria": ["ethtool rx_ampdu_bytes_cnt delta", "..."]
#   }
#
# scripts/wireless/hw-gap-report.sh merges these records by "missing", so
# one run answers "which single piece of hardware unblocks the most tickets".
#
# The record is best effort: a harness must still report its skip even when
# the record cannot be written (read-only /tmp, no room, ...).

# json_str VALUE: print VALUE as a JSON string, backslash and quote escaped.
nc_json_str() {
	printf '%s' "${1:-}" | awk '
		BEGIN { ORS = ""; printf "\"" }
		{
			if (NR > 1) printf "\\n"
			gsub(/\\/, "\\\\")
			gsub(/"/, "\\\"")
			gsub(/\t/, "\\t")
			gsub(/\r/, "\\r")
			printf "%s", $0
		}
		END { printf "\"" }
	'
}

# nc_json_str_list ARG...: print a JSON array of the arguments.
nc_json_str_list() {
	printf '['
	_sep=
	for _item in "$@"; do
		printf '%s%s' "$_sep" "$(nc_json_str "$_item")"
		_sep=', '
	done
	printf ']'
}

# no_client_default_dir SCRIPT: the fallback directory when the harness has
# no output directory yet.  Kept under /tmp because a skip writes no results
# of its own, and hw-gap-report.sh scans /tmp by default.
no_client_default_dir() {
	_stamp=$(date -u '+%Y%m%dT%H%M%S' 2>/dev/null) || _stamp=$$
	printf '/tmp/%s-no-client.%s.%s' "${1%.sh}" "$_stamp" "$$"
}

# no_client_record DIR TICKET MISSING COMMAND REASON CRITERION...
#
# DIR      output directory; empty means a /tmp fallback (created here)
# TICKET   issue number the record unblocks ("48"), or "-" when none
# MISSING  one word naming the hardware, e.g. 6ghz-eht-client
# COMMAND  the exact command to run once that hardware is available
# REASON   one line saying why this run stopped
#
# Prints the record path on stdout; the caller prints the SKIP line.  Always
# returns 0 so a record failure never turns a skip into an error.
no_client_record() {
	_nc_dir=${1:-}
	_nc_ticket=${2:--}
	_nc_missing=${3:-unknown}
	_nc_command=${4:-}
	_nc_reason=${5:-}
	shift 5 2>/dev/null || :
	if [ -z "$_nc_dir" ]; then
		_nc_dir=$(no_client_default_dir "$(basename "$0")")
	fi
	mkdir -p "$_nc_dir" 2>/dev/null || return 0
	_nc_script=$(basename "$0")
	{
		printf '{\n'
		printf '  "schema": "wireless-no-client/v1",\n'
		printf '  "script": %s,\n' "$(nc_json_str "$_nc_script")"
		printf '  "ticket": %s,\n' "$(nc_json_str "$_nc_ticket")"
		printf '  "status": "no-client",\n'
		printf '  "missing": %s,\n' "$(nc_json_str "$_nc_missing")"
		printf '  "command": %s,\n' "$(nc_json_str "$_nc_command")"
		printf '  "reason": %s,\n' "$(nc_json_str "$_nc_reason")"
		printf '  "criteria": %s,\n' "$(nc_json_str_list "$@")"
		printf '  "timestamp": %s\n' \
			"$(nc_json_str "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)")"
		printf '}\n'
	} >"$_nc_dir/result.json.tmp" 2>/dev/null &&
		mv "$_nc_dir/result.json.tmp" "$_nc_dir/result.json" 2>/dev/null
	printf '%s\n' "$_nc_dir/result.json"
	return 0
}
