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
# Contract v2 (when NC_RECORD_CAUSE is set) writes the record under
# DIR/no-hardware/ with an explicit "cause", "outcome", and "exit" code
# alongside the legacy v1 "schema"/"status" fields (see the cause table
# below at nc_cause_status / nc_cause_exit):
#
#   missing-hardware      exits 3 ("SKIP:" line; legacy status: no-client)
#   missing-tool          exits 2 ("SKIP:" / error; legacy status: no-client)
#   config-block          exits 2 ("BLOCKED:" line; legacy status: blocked)
#   precondition-mismatch exits 4 ("BLOCKED:" line; legacy status: blocked)
#
# Callers that do not set NC_RECORD_CAUSE keep the legacy v1 schema
# (DIR/result.json with status "no-client" or "blocked") so older readers
# and callers continue to work unchanged.
#
# "6ghz-owe-mismatch" is the only blocked key today: a band=6g wifi-iface
# with encryption none/open is upgraded by hostapd to OWE + PMF(2), so an
# open-only client can never associate.  Filing that under
# "6ghz-eht-client" would put a configuration fix on the purchase list.
# Set NC_RECORD_CAUSE=config-block (and NC_RECORD_STATUS=blocked for legacy
# v1 readers) when calling no_client_record for it.
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

# no_hardware_dir BASE: where the v2 records of one run live.  They are kept
# apart from BASE/result.json because that file is the measurement result of a
# run that did measure something; a skip must never overwrite it.
no_hardware_dir() {
	printf '%s/no-hardware' "${1:-}"
}

# The cause vocabulary.  "cause" is the authority: "status" is only the legacy
# v1 spelling kept for existing readers.  A harness sets NC_RECORD_CAUSE and
# then exits with nc_cause_exit for that same cause, so the record and the
# process status can never disagree.
#
#   cause                 status        outcome       exit
#   missing-hardware      no-client     not-measured  3
#   missing-tool          no-client     not-measured  2
#   config-block          blocked       not-measured  2
#   permission            blocked       not-measured  2
#   environment           blocked       not-measured  2
#   output-collision      blocked       not-measured  2
#   precondition-mismatch blocked       not-measured  4
#   internal              failed        measured      1
#   interrupted           interrupted   not-measured  130 (129/143 by signal)

# nc_cause_status CAUSE: the legacy v1 status for CAUSE.  Returns 1 when the
# cause is unknown, so a typo cannot silently become "no-client".
nc_cause_status() {
	case ${1:-} in
	missing-hardware | missing-tool) printf 'no-client\n' ;;
	config-block | permission | environment | output-collision | \
		precondition-mismatch) printf 'blocked\n' ;;
	internal) printf 'failed\n' ;;
	interrupted) printf 'interrupted\n' ;;
	*) return 1 ;;
	esac
}

# nc_cause_outcome CAUSE: "measured" or "not-measured".
nc_cause_outcome() {
	case ${1:-} in
	internal) printf 'measured\n' ;;
	missing-hardware | missing-tool | config-block | permission | \
		environment | output-collision | precondition-mismatch | interrupted)
		printf 'not-measured\n' ;;
	*) return 1 ;;
	esac
}

# nc_cause_exit CAUSE: the process status a harness exits with.  An empty or
# unknown cause is a bug in the caller, not "blocked": it reports 1 and says
# so on stderr instead of guessing.
nc_cause_exit() {
	case ${1:-} in
	missing-hardware) printf '3\n' ;;
	missing-tool) printf '2\n' ;;
	config-block | permission | environment | output-collision)
		printf '2\n' ;;
	precondition-mismatch) printf '4\n' ;;
	internal) printf '1\n' ;;
	interrupted) printf '130\n' ;;
	*)
		printf 'no-client: unknown cause "%s"\n' "${1:-empty}" >&2
		printf '1\n'
		return 1
		;;
	esac
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
	_rec=$(NC_RECORD_CAUSE=config-block NC_RECORD_STATUS=blocked \
		no_client_record "$_dir" "$_ticket" \
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
# NC_RECORD_CAUSE, when set, writes a v2 record under DIR/no-hardware/ with
# the derived status, outcome and exit code.  NC_RECORD_STATUS only overrides
# the legacy status explicitly; it is never inferred back from the cause.
# NC_RECORD_KIND names the file inside that directory (precondition.json);
# NC_RECORD_ARM puts it under no-hardware/arms/<arm>.json instead.  Without
# NC_RECORD_CAUSE the record stays a plain v1 DIR/result.json, so an old tree
# and an old caller keep working unchanged.
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
	_nc_cause=${NC_RECORD_CAUSE:-}
	if [ -z "$_nc_dir" ]; then
		_nc_dir=$(no_client_default_dir "$(basename "$0")")
	fi
	if [ -n "$_nc_cause" ]; then
		_nc_status=$(nc_cause_status "$_nc_cause") || _nc_status=blocked
		_nc_outcome=$(nc_cause_outcome "$_nc_cause") || _nc_outcome=not-measured
		_nc_exit=$(nc_cause_exit "$_nc_cause" 2>/dev/null) || _nc_exit=1
		_nc_dir=$(no_hardware_dir "$_nc_dir")
		_nc_name=${NC_RECORD_KIND:-result}
		_nc_name=$_nc_name.json
		if [ -n "${NC_RECORD_ARM:-}" ]; then
			_nc_arm=$NC_RECORD_ARM
			if printf '%s' "$_nc_arm" | grep -q '[^A-Za-z0-9_.-]'; then
				_nc_arm=unknown
			fi
			_nc_dir=$_nc_dir/arms
			_nc_name=$_nc_arm.json
		fi
	else
		_nc_status=${NC_RECORD_STATUS:-no-client}
		_nc_name=result.json
	fi
	if [ -n "${NC_RECORD_STATUS:-}" ]; then
		_nc_status=$NC_RECORD_STATUS
	fi
	mkdir -p "$_nc_dir" 2>/dev/null || return 0
	_nc_script=$(basename "$0")
	{
		printf '{\n'
		printf '  "schema": "wireless-no-client/v1",\n'
		printf '  "script": %s,\n' "$(nc_json_str "$_nc_script")"
		printf '  "ticket": %s,\n' "$(nc_json_str "$_nc_ticket")"
		printf '  "status": %s,\n' "$(nc_json_str "$_nc_status")"
		if [ -n "$_nc_cause" ]; then
			printf '  "contract": "v2",\n'
			printf '  "cause": %s,\n' "$(nc_json_str "$_nc_cause")"
			printf '  "cause_source": "recorded",\n'
			printf '  "outcome": %s,\n' "$(nc_json_str "$_nc_outcome")"
			printf '  "exit": %s,\n' "$_nc_exit"
		fi
		printf '  "missing": %s,\n' "$(nc_json_str "$_nc_missing")"
		printf '  "command": %s,\n' "$(nc_json_str "$_nc_command")"
		printf '  "reason": %s,\n' "$(nc_json_str "$_nc_reason")"
		printf '  "criteria": %s,\n' "$(nc_json_str_list "$@")"
		printf '  "timestamp": %s\n' \
			"$(nc_json_str "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)")"
		printf '}\n'
	} >"$_nc_dir/$_nc_name.tmp" 2>/dev/null &&
		mv "$_nc_dir/$_nc_name.tmp" "$_nc_dir/$_nc_name" 2>/dev/null
	printf '%s\n' "$_nc_dir/$_nc_name"
	return 0
}
