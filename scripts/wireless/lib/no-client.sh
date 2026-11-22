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
# Two statuses share this schema:
#
#   no-client  the board is reachable; a piece of hardware or a measurement
#              tool is missing.  "missing" names it.  A missing client is a
#              clean skip (exit 0, "SKIP:" line); a missing tool that the run
#              cannot do without is recorded the same way but exits 2, so
#              "nothing was measured" stays distinguishable from "measured".
#   blocked    the board is reachable but the association cannot work until a
#              configuration is fixed; the harness exits non-zero with a
#              "BLOCKED:" line and the record says what to change.
#
# "6ghz-owe-mismatch" is the only blocked key today: a band=6g wifi-iface
# with encryption none/open is upgraded by hostapd to OWE + PMF(2), so an
# open-only client can never associate.  Filing that under
# "6ghz-eht-client" would put a configuration fix on the purchase list.
# Set NC_RECORD_STATUS=blocked when calling no_client_record for it.
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

# nc_live_encryption IFACE: the live Encryption string of an AP interface
# ("OWE (CCMP)", "SAE (CCMP)", "none", ...), read through iwinfo, else ubus.
# Prints nothing and returns 1 when neither can answer.
nc_live_encryption() {
	_iface=${1:-}
	[ -n "$_iface" ] || return 1
	_out=
	if command -v iwinfo >/dev/null 2>&1; then
		_out=$(iwinfo "$_iface" info 2>/dev/null |
			sed -n 's/^[[:space:]]*Encryption:[[:space:]]*//p' | head -n 1)
	fi
	if [ -z "$_out" ] && command -v ubus >/dev/null 2>&1; then
		_out=$(ubus call iwinfo info "{\"device\":\"$_iface\"}" 2>/dev/null |
			tr -d '\n' |
			sed -n 's/.*"encryption":[[:space:]]*"\([^"]*\)".*/\1/p' |
			head -n 1)
	fi
	[ -n "$_out" ] || return 1
	printf '%s\n' "$_out"
}

# nc_6ghz_open_sections: print the UCI wifi-iface sections that are APs on a
# band=6g wifi-device with encryption none/open/unset.  hostapd upgrades each
# of them to OWE + PMF(2) on the air, so the profile and the BSS disagree.
nc_6ghz_open_sections() {
	command -v uci >/dev/null 2>&1 || return 1
	uci show wireless 2>/dev/null | awk -F"'" '
		/=wifi-device$/ {
			s = $1
			sub(/^wireless\./, "", s); sub(/=wifi-device$/, "", s)
			sections[s] = 1
			next
		}
		/=wifi-iface$/ {
			s = $1
			sub(/^wireless\./, "", s); sub(/=wifi-iface$/, "", s)
			ifaces[s] = 1
			next
		}
		/^wireless\.[^.]+\./ {
			k = $1; v = $2
			sub(/^wireless\./, "", k)
			dot = index(k, ".")
			sec = substr(k, 1, dot - 1)
			key = substr(k, dot + 1); sub(/=$/, "", key)
			if (key == "band") band[sec] = v
			else if (key == "device") dev[sec] = v
			else if (key == "mode") mode[sec] = v
			else if (key == "encryption") enc[sec] = v
			else if (key == "disabled") dis[sec] = v
			next
		}
		END {
			for (s in ifaces) {
				if (band[dev[s]] != "6g") continue
				if (mode[s] != "ap") continue
				if (dis[s] == "1") continue
				e = enc[s]
				if (e == "" || e == "none" || e == "open") print s
			}
		}
	'
}

# nc_owe_mismatch IFACE: prints one reason line and returns 0 when IFACE
# advertises OWE on the air while a band=6g AP profile in UCI is still open.
# That pair cannot carry an open-only client: hostapd forces OWE + PMF(2).
# Returns 1 (and prints nothing) whenever the evidence is incomplete.
nc_owe_mismatch() {
	_iface=${1:-}
	[ -n "$_iface" ] || return 1
	_live=$(nc_live_encryption "$_iface") || return 1
	case $_live in
	OWE*|owe*) ;;
	*) return 1 ;;
	esac
	_sections=$(nc_6ghz_open_sections) || return 1
	[ -n "$_sections" ] || return 1
	_sec=$(printf '%s\n' "$_sections" | head -n 1)
	printf '%s: live Encryption %s, but wireless.%s.encryption is open (none); hostapd forces OWE + PMF(2) on 6 GHz, so an open-only client cannot associate\n' \
		"$_iface" "$_live" "$_sec"
	return 0
}

# nc_owe_mismatch_block DIR TICKET DETAIL: write a status "blocked" record for
# "6ghz-owe-mismatch" and print the BLOCKED line, the UCI fix and the record
# path.  DETAIL is the line nc_owe_mismatch printed.  Returns 0; the caller
# exits non-zero so a configuration block never looks like a measured skip.
nc_owe_mismatch_block() {
	_dir=${1:-}
	_ticket=${2:--}
	_detail=${3:-}
	_sec=$(printf '%s\n' "$_detail" |
		sed -n 's/.*wireless\.\([A-Za-z0-9_]*\)\.encryption.*/\1/p' | head -n 1)
	if [ -n "$_sec" ]; then
		_fix="uci set wireless.$_sec.encryption=owe; uci set wireless.$_sec.ieee80211w=2; uci commit wireless; wifi reload"
	else
		_fix="set every band=6g wifi-iface to encryption=owe and ieee80211w=2, then wifi reload"
	fi
	_rec=$(NC_RECORD_STATUS=blocked no_client_record "$_dir" "$_ticket" \
		6ghz-owe-mismatch "$_fix" \
		"${_detail:-6 GHz AP advertises OWE while the UCI profile is open}" \
		"live 6 GHz AP Encryption from iwinfo/ubus" \
		"UCI wifi-iface encryption=none on a band=6g wifi-device" 2>/dev/null)
	printf 'BLOCKED: %s\n' \
		"${_detail:-6 GHz AP advertises OWE while the UCI profile is open}"
	printf '         fix: %s\n' "$_fix"
	[ -n "$_rec" ] && printf '         blocked record: %s\n' "$_rec"
	return 0
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
		printf '  "status": %s,\n' "$(nc_json_str "${NC_RECORD_STATUS:-no-client}")"
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
