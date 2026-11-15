#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# txpower-audit.sh - read-only txpower / regulatory-database audit.
#
# The XR1710G defaults to 5 GHz ch36 at 23 dBm and 6 GHz ch37 at 30 dBm.
# Those numbers are the intersection of the board SKU/EEPROM limits, the
# per-channel 'iw phy' limit and the active wireless-regdb rules, but
# nothing checked them automatically.  This script does that on the live
# AP and prints a PASS/FAIL line that names the band, channel, width,
# txpower and the regdb rule that applies, plus a machine-readable JSON
# summary.
#
# What is checked, per active channel (including each link of an MLD):
#
#   1. The occupied bandwidth (center1 +/- width/2) is covered by the
#      union of the active regdb rules.  Wide channels may span more than
#      one rule (5 GHz ch36/160 MHz spans the 5150-5250 and 5250-5350
#      rules), so the union is checked rather than one rule only.  The
#      ceiling is the smallest EIRP of all rules that intersect the span.
#   2. The primary frequency is listed by 'iw phy' and is not disabled.
#      An AP/mesh/IBSS interface also fails if the channel is NO-IR.
#   3. The per-channel 'iw phy' limit (regdb clamped by the board
#      SKU/EEPROM) does not exceed the regdb EIRP rule.
#   4. The runtime 'iw dev' txpower does not exceed that board limit.
#   5. For 6 GHz, txpower, the board limit and the effective ceiling are
#      additionally capped at the FCC LPI value of 30 dBm.  A 6 GHz
#      channel outside the regdb rules therefore fails even if a vendor
#      EEPROM would allow it.
#
# "Runtime txpower" is the 'iw dev' value.  On mt7996, get_txpower()
# reports the default link phy for every MLO link, so all links of an
# MLD can show the same value (e.g. 5 GHz link reporting the 6 GHz 30 dBm
# limit).  For an MLD link this script uses the single-link AP on the
# same band as the runtime source when one exists, records the link's
# reported value as well, and prints a NOTE.  If no single-link AP exists
# on that band, a reported value above the board limit is not trusted as
# that link's power: the board limit is used as the verifiable ceiling and
# the check is marked unverified.  It never writes anything: it only runs
# 'iw dev', 'iw phy', 'iw reg get' and reads board metadata.
#
# Usage:
#   scripts/wireless/txpower-audit.sh
#   scripts/wireless/txpower-audit.sh --json
#   scripts/wireless/txpower-audit.sh --dry-run
#   scripts/wireless/txpower-audit.sh --input DIR
#   scripts/wireless/txpower-audit.sh --verbose
#
# --dry-run audits a built-in XR1710G sample fixture (5 GHz ch36/160 MHz 23 dBm,
# 6 GHz ch37/320 MHz 30 dBm, 2.4 GHz disabled) and needs no wireless
# device.  --input audits previously captured files in DIR:
# iw-dev.txt, iw-reg-get.txt and iw-phy.txt.
#
# Exit status: 0 PASS or SKIP, 1 FAIL, 2 usage or environment error.
#
# POSIX sh and busybox awk only.  The script creates no temporary files.

set -u

PROG=${0##*/}
MODE=live
JSON_ONLY=0
DRY_RUN=0
VERBOSE=0
INPUT_DIR=

usage() {
	cat <<EOF
Usage: $PROG [options]

Read-only audit of the runtime Wi-Fi txpower against the board's
per-channel limits and the active regulatory database.

Options:
  --json            print only the JSON summary on stdout
  --dry-run         audit a built-in XR1710G sample fixture; no device
  --input DIR       audit captured files in DIR instead of the live device
                    (iw-dev.txt, iw-reg-get.txt, iw-phy.txt; optional
                    board-name.txt, board-model.txt, default-country.txt,
                    kernel.txt and regdb-md5.txt add report metadata)
  --verbose         include the full raw 'iw dev' and 'iw phy' dumps
  -h, --help        show this help

Default output is a human-readable report with a compact dump of
'iw reg get', 'iw dev' txpower and the 'iw phy' per-band power plus one
PASS/FAIL line per active channel.  '--json' prints only the
machine-readable JSON object instead.

The audit is read-only: it runs 'iw dev', 'iw phy' and 'iw reg get',
reads /tmp/sysinfo/board_name, /etc/board.json and the regulatory.db
md5, and never calls 'iw set', 'uci set/commit' or writes a file.

Exit status: 0 PASS or SKIP, 1 FAIL, 2 usage or environment error.

Examples:
  # live audit, human output
  ./scripts/wireless/txpower-audit.sh

  # feed it to jq
  ./scripts/wireless/txpower-audit.sh --json | jq .

  # reproduce the sample output without a wireless device
  ./scripts/wireless/txpower-audit.sh --dry-run

  # audit a capture taken over ssh
  ./scripts/wireless/txpower-audit.sh --input /tmp/xr1710g-iw
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	printf "Try '%s --help'.\n" "$PROG" >&2
	exit 2
}

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 2
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ---- built-in fixture used by --dry-run --------------------------------

fixture_dev() {
	cat <<'EOF'
phy#0
	Interface phy0.1-ap0
		ifindex 43
		wdev 0xf
		addr 00:58:28:d7:44:60
		ssid XR1710G
		type AP
		channel 36 (5180 MHz), width: 160 MHz, center1: 5250 MHz
		txpower 23.00 dBm
	Interface phy0.2-ap0
		ifindex 9
		wdev 0x2
		addr 00:58:28:d7:44:61
		ssid XR1710G-6G
		type AP
		channel 37 (6135 MHz), width: 320 MHz, center1: 6105 MHz
		txpower 30.00 dBm
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

fixture_phy() {
	cat <<'EOF'
Wiphy phy0
	wiphy index: 0
	Band 1:
		Frequencies:
			* 2412.0 MHz [1] (28.0 dBm)
			* 2437.0 MHz [6] (28.0 dBm)
			* 2467.0 MHz [12] (disabled)
			* 2472.0 MHz [13] (disabled)
			* 2484.0 MHz [14] (disabled)
	Band 2:
		Frequencies:
			* 5180.0 MHz [36] (23.0 dBm)
			* 5200.0 MHz [40] (23.0 dBm)
			* 5220.0 MHz [44] (23.0 dBm)
			* 5240.0 MHz [48] (23.0 dBm)
			* 5260.0 MHz [52] (24.0 dBm) (radar detection)
			* 5280.0 MHz [56] (24.0 dBm) (radar detection)
			* 5300.0 MHz [60] (24.0 dBm) (radar detection)
			* 5320.0 MHz [64] (24.0 dBm) (radar detection)
			* 5500.0 MHz [100] (24.0 dBm) (radar detection)
			* 5745.0 MHz [149] (28.0 dBm)
			* 5765.0 MHz [153] (28.0 dBm)
			* 5785.0 MHz [157] (28.0 dBm)
			* 5805.0 MHz [161] (28.0 dBm)
			* 5825.0 MHz [165] (28.0 dBm)
			* 5845.0 MHz [169] (28.0 dBm)
			* 5865.0 MHz [173] (28.0 dBm)
			* 5885.0 MHz [177] (28.0 dBm)
	Band 4:
		Frequencies:
			* 5955.0 MHz [1] (28.0 dBm)
			* 5975.0 MHz [5] (28.0 dBm)
			* 5995.0 MHz [9] (28.0 dBm)
			* 6015.0 MHz [13] (28.0 dBm)
			* 6035.0 MHz [17] (28.0 dBm)
			* 6055.0 MHz [21] (28.0 dBm)
			* 6075.0 MHz [25] (28.0 dBm)
			* 6095.0 MHz [29] (28.0 dBm)
			* 6115.0 MHz [33] (28.0 dBm)
			* 6135.0 MHz [37] (30.0 dBm)
			* 6155.0 MHz [41] (30.0 dBm)
			* 6175.0 MHz [45] (30.0 dBm)
			* 6195.0 MHz [49] (30.0 dBm)
			* 6215.0 MHz [53] (30.0 dBm)
			* 6235.0 MHz [57] (30.0 dBm)
			* 6255.0 MHz [61] (30.0 dBm)
			* 6275.0 MHz [65] (30.0 dBm)
			* 6295.0 MHz [69] (30.0 dBm)
			* 6315.0 MHz [73] (30.0 dBm)
			* 6335.0 MHz [77] (30.0 dBm)
			* 6355.0 MHz [81] (30.0 dBm)
			* 6375.0 MHz [85] (30.0 dBm)
			* 6395.0 MHz [89] (30.0 dBm)
			* 6415.0 MHz [93] (30.0 dBm)
			* 6435.0 MHz [97] (30.0 dBm)
			* 6455.0 MHz [101] (30.0 dBm)
			* 6475.0 MHz [105] (30.0 dBm)
			* 6495.0 MHz [109] (30.0 dBm)
			* 6515.0 MHz [113] (30.0 dBm)
			* 6535.0 MHz [117] (30.0 dBm)
			* 6555.0 MHz [121] (30.0 dBm)
			* 6575.0 MHz [125] (30.0 dBm)
			* 6595.0 MHz [129] (30.0 dBm)
			* 6615.0 MHz [133] (30.0 dBm)
			* 6635.0 MHz [137] (30.0 dBm)
			* 6655.0 MHz [141] (30.0 dBm)
			* 6675.0 MHz [145] (30.0 dBm)
			* 6695.0 MHz [149] (30.0 dBm)
			* 6715.0 MHz [153] (30.0 dBm)
			* 6735.0 MHz [157] (30.0 dBm)
			* 6755.0 MHz [161] (30.0 dBm)
			* 6775.0 MHz [165] (30.0 dBm)
			* 6795.0 MHz [169] (30.0 dBm)
			* 6815.0 MHz [173] (30.0 dBm)
			* 6835.0 MHz [177] (30.0 dBm)
			* 6855.0 MHz [181] (30.0 dBm)
			* 6875.0 MHz [185] (30.0 dBm)
			* 6895.0 MHz [189] (30.0 dBm)
			* 6915.0 MHz [193] (30.0 dBm)
			* 6935.0 MHz [197] (30.0 dBm)
			* 6955.0 MHz [201] (30.0 dBm)
			* 6975.0 MHz [205] (30.0 dBm)
			* 6995.0 MHz [209] (30.0 dBm)
			* 7015.0 MHz [213] (30.0 dBm)
			* 7035.0 MHz [217] (30.0 dBm)
			* 7055.0 MHz [221] (30.0 dBm)
			* 7075.0 MHz [225] (30.0 dBm)
			* 7115.0 MHz [233] (30.0 dBm)
EOF
}

# ---- argument handling -------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
	--json)
		JSON_ONLY=1
		;;
	--dry-run)
		DRY_RUN=1
		MODE=dry-run
		;;
	--input)
		[ $# -ge 2 ] || usage_error "--input needs a directory"
		INPUT_DIR=$2
		MODE=input
		shift
		;;
	--input=*)
		INPUT_DIR=${1#*=}
		MODE=input
		;;
	--verbose|-v)
		VERBOSE=1
		;;
	-h|--help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		usage_error "unknown option: $1"
		;;
	*)
		usage_error "unexpected argument: $1"
		;;
	esac
	shift
done

[ $# -eq 0 ] || usage_error "unexpected argument: $1"

if [ "$DRY_RUN" = 1 ] && [ -n "$INPUT_DIR" ]; then
	usage_error "--dry-run and --input are mutually exclusive"
fi

LC_ALL=C
export LC_ALL

need_cmd awk

# ---- input -------------------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
	DEV_OUT=$(fixture_dev)
	REG_OUT=$(fixture_reg)
	PHY_OUT=$(fixture_phy)
	BOARD_NAME=gemtek,xr1710g-ubi
	BOARD_MODEL=
	DEFAULT_COUNTRY=US
	KERNEL=
	REGDB_MD5=
elif [ -n "$INPUT_DIR" ]; then
	[ -d "$INPUT_DIR" ] || die "not a directory: $INPUT_DIR"
	for f in iw-dev.txt iw-reg-get.txt iw-phy.txt; do
		[ -r "$INPUT_DIR/$f" ] || die "missing input file: $INPUT_DIR/$f"
	done
	DEV_OUT=$(cat "$INPUT_DIR/iw-dev.txt") || die "cannot read $INPUT_DIR/iw-dev.txt"
	REG_OUT=$(cat "$INPUT_DIR/iw-reg-get.txt") || die "cannot read $INPUT_DIR/iw-reg-get.txt"
	PHY_OUT=$(cat "$INPUT_DIR/iw-phy.txt") || die "cannot read $INPUT_DIR/iw-phy.txt"
	BOARD_NAME=
	BOARD_MODEL=
	DEFAULT_COUNTRY=
	KERNEL=
	REGDB_MD5=
	if [ -r "$INPUT_DIR/board-name.txt" ]; then
		BOARD_NAME=$(cat "$INPUT_DIR/board-name.txt")
	fi
	if [ -r "$INPUT_DIR/board-model.txt" ]; then
		BOARD_MODEL=$(cat "$INPUT_DIR/board-model.txt")
	fi
	if [ -r "$INPUT_DIR/default-country.txt" ]; then
		DEFAULT_COUNTRY=$(cat "$INPUT_DIR/default-country.txt")
	fi
	if [ -r "$INPUT_DIR/kernel.txt" ]; then
		KERNEL=$(cat "$INPUT_DIR/kernel.txt")
	fi
	if [ -r "$INPUT_DIR/regdb-md5.txt" ]; then
		REGDB_MD5=$(cat "$INPUT_DIR/regdb-md5.txt")
	fi
else
	need_cmd iw
	need_cmd awk
	DEV_OUT=$(iw dev 2>&1) || die "'iw dev' failed: $DEV_OUT"
	REG_OUT=$(iw reg get 2>&1) || die "'iw reg get' failed: $REG_OUT"
	PHY_OUT=$(iw phy 2>&1) || die "'iw phy' failed: $PHY_OUT"
	BOARD_NAME=
	BOARD_MODEL=
	DEFAULT_COUNTRY=
	KERNEL=
	REGDB_MD5=
	if [ -r /tmp/sysinfo/board_name ]; then
		BOARD_NAME=$(cat /tmp/sysinfo/board_name)
	fi
	if [ -r /proc/device-tree/model ]; then
		BOARD_MODEL=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null)
	fi
	if [ -r /etc/board.json ]; then
		DEFAULT_COUNTRY=$(sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([A-Z][A-Z]\)".*/\1/p' \
			/etc/board.json 2>/dev/null | head -n 1)
	fi
	if [ -r /lib/firmware/regulatory.db ] && command -v md5sum >/dev/null 2>&1; then
		REGDB_MD5=$(md5sum /lib/firmware/regulatory.db 2>/dev/null | awk '{ print $1 }')
	fi
	KERNEL=$(uname -srm 2>/dev/null)
fi

[ -n "$DEV_OUT" ] || die "empty 'iw dev' input"
[ -n "$REG_OUT" ] || die "empty 'iw reg get' input"
[ -n "$PHY_OUT" ] || die "empty 'iw phy' input"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
[ -n "$NOW" ] || NOW=unknown

# ---- audit -------------------------------------------------------------

report=$(
	{
		printf '@@IW-DEV@@\n%s\n' "$DEV_OUT"
		printf '@@IW-REG@@\n%s\n' "$REG_OUT"
		printf '@@IW-PHY@@\n%s\n' "$PHY_OUT"
		printf '@@END@@\n'
	} | awk \
		-v mode="$MODE" \
		-v board="$BOARD_NAME" \
		-v model="$BOARD_MODEL" \
		-v kernel="$KERNEL" \
		-v default_country="$DEFAULT_COUNTRY" \
		-v regdb_md5="$REGDB_MD5" \
		-v generated="$NOW" \
		-v json_only="$JSON_ONLY" \
		-v verbose="$VERBOSE" '
BEGIN {
	NA = -999999
	if (!json_only) {
		print "txpower/regdb audit (read-only)"
		print "mode:    " mode
		if (board != "")
			print "board:   " board
		if (model != "")
			print "model:   " model
		if (kernel != "")
			print "kernel:  " kernel
		if (default_country != "")
			print "board country default: " default_country
		if (regdb_md5 != "")
			print "regulatory.db md5: " regdb_md5
	}
	RULE_N = 0
	SCOPE_N = 0
	IF_N = 0
	F_N = 0
	PHY_N = 0
	CHECK_N = 0
	FAIL_N = 0
	WARN_N = 0
	SKIP_N = 0
	ERROR_N = 0
	section = ""
	cur_scope = ""
	cur_phy = ""
	cur_name = ""
	cur_type = ""
	cur_chan = NA
	cur_freq = NA
	cur_width = NA
	cur_center = NA
	cur_tx = NA
	in_link = 0
	LINK_N = 0
	cur_wiphy = ""
	dev_header = 0
	phy_header = 0
}

function trim(s) {
	sub(/^[ \t]+/, "", s)
	sub(/[ \t]+$/, "", s)
	return s
}

# Convert a decimal dBm string to hundredths of a dBm.
function dbm_to_cents(s,   neg, a, frac, whole, c) {
	neg = 0
	if (substr(s, 1, 1) == "-") {
		neg = 1
		s = substr(s, 2)
	} else if (substr(s, 1, 1) == "+") {
		s = substr(s, 2)
	}
	split(s, a, ".")
	whole = a[1] + 0
	frac = 0
	if (a[2] != "") {
		if (length(a[2]) == 1)
			frac = (a[2] + 0) * 10
		else
			frac = substr(a[2], 1, 2) + 0
	}
	c = whole * 100 + frac
	return neg ? -c : c
}

function cents_to_str(c,   sign) {
	if (c == NA)
		return "N/A"
	sign = ""
	if (c < 0) {
		sign = "-"
		c = -c
	}
	return sprintf("%s%d.%02d", sign, int(c / 100), c % 100)
}

function jstr(s,   out, i, c) {
	out = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c == "\\")
			out = out "\\\\"
		else if (c == "\"")
			out = out "\\\""
		else if (c == "\n")
			out = out "\\n"
		else if (c == "\r")
			out = out "\\r"
		else if (c == "\t")
			out = out "\\t"
		else
			out = out c
	}
	return "\"" out "\""
}

function jnotes(s) {
	# The internal separator is not valid raw JSON; use "; " in the
	# machine-readable copy.  Human output splits on it instead.
	gsub(/\034/, "; ", s)
	return jstr(s)
}

function jnum(c) {
	if (c == NA)
		return "null"
	return sprintf("%.2f", c / 100)
}

function jint(v) {
	if (v == NA)
		return "null"
	return sprintf("%d", v)
}

function jbool(v) {
	return v ? "true" : "false"
}

function band_of(f) {
	if (f >= 2400 && f < 2500)
		return "2.4G"
	if (f >= 4900 && f < 5925)
		return "5G"
	if (f >= 5925 && f <= 7125)
		return "6G"
	if (f >= 902 && f <= 928)
		return "Sub-1G"
	if (f >= 57000)
		return "60G"
	return "unknown"
}

function band_rank(b) {
	if (b == "2.4G")
		return 1
	if (b == "5G")
		return 2
	if (b == "6G")
		return 3
	if (b == "Sub-1G")
		return 4
	if (b == "60G")
		return 5
	return 9
}

function is_ap_type(t) {
	return t == "AP" || t == "mesh point" || t == "IBSS" || t == "P2P-GO"
}

function note_scope(s) {
	if (!(s in SCOPE_SEEN)) {
		SCOPE_SEEN[s] = 1
		SCOPE_ORDER[++SCOPE_N] = s
	}
}

function add_rule(scope, line,   p, n, i, q, head, g, rest, sep, flags) {
	n = split(line, p, /\), \(/)
	if (n < 3)
		return
	head = p[1]
	sub(/^[ \t]*\(/, "", head)
	sub(/[ \t]+$/, "", head)
	split(head, q, " ")
	if (q[1] !~ /^[0-9]+$/ || q[3] !~ /^[0-9]+$/ || q[5] !~ /^[0-9]+$/)
		return
	RULE_N++
	RL_SCOPE[RULE_N] = scope
	RL_START[RULE_N] = q[1] + 0
	RL_END[RULE_N] = q[3] + 0
	RL_BW[RULE_N] = q[5] + 0
	split(p[2], g, ",")
	RL_GAIN[RULE_N] = trim(g[1])
	RL_EIRP[RULE_N] = trim(g[2]) + 0
	# The third tuple is "(CAC time), FLAGS" or "(CAC time)".  p[3]
	# starts after the "), (" separator, so split off the flags.
	rest = p[3]
	sep = index(rest, "), ")
	if (sep > 0) {
		RL_CAC[RULE_N] = substr(rest, 1, sep - 1)
		flags = substr(rest, sep + 3)
	} else {
		RL_CAC[RULE_N] = rest
		sub(/\)$/, "", RL_CAC[RULE_N])
		flags = ""
	}
	RL_CAC[RULE_N] = trim(RL_CAC[RULE_N])
	for (i = 4; i <= n; i++)
		flags = flags (flags == "" ? "" : ", ") p[i]
	RL_FLAGS[RULE_N] = flags
	RL_NOIR[RULE_N] = (flags ~ /NO-IR/) ? 1 : 0
	RL_DFS[RULE_N] = (flags ~ /DFS/) ? 1 : 0
	RL_NOOUT[RULE_N] = (flags ~ /NO-OUTDOOR/) ? 1 : 0
}

function parse_reg(line) {
	if (line == "global") {
		cur_scope = "global"
		note_scope(cur_scope)
		return
	}
	if (line ~ /^phy#[0-9]+ \(self-managed\)/) {
		cur_scope = line
		sub(/ .*/, "", cur_scope)
		gsub(/#/, "", cur_scope)
		note_scope(cur_scope)
		return
	}
	if (line ~ /^country [A-Z0-9][A-Z0-9]: /) {
		if (cur_scope != "") {
			SCOPE_COUNTRY[cur_scope] = substr(line, 9, 2)
			SCOPE_DFSNAME[cur_scope] = substr(line, 13)
		}
		return
	}
	if (line ~ /^[ \t]*\(/ && cur_scope != "")
		add_rule(cur_scope, line)
}

function parse_channel(line,   s, a) {
	P_CHAN = NA
	P_FREQ = NA
	P_WIDTH = NA
	P_CENTER = NA
	if (!match(line, /channel [0-9]+ \([0-9]+ MHz\)/))
		return
	s = substr(line, RSTART, RLENGTH)
	split(s, a, " ")
	P_CHAN = a[2] + 0
	P_FREQ = a[3]
	gsub(/[^0-9]/, "", P_FREQ)
	P_FREQ += 0
	if (match(line, /width: [0-9]+\+?[0-9]* MHz/)) {
		s = substr(line, RSTART, RLENGTH)
		sub(/width: /, "", s)
		if (s ~ /\+/)
			P_WIDTH = -2
		else {
			split(s, a, " ")
			P_WIDTH = a[1] + 0
		}
	} else {
		P_WIDTH = 20
	}
	if (match(line, /center1: [0-9]+ MHz/)) {
		s = substr(line, RSTART, RLENGTH)
		sub(/center1: /, "", s)
		split(s, a, " ")
		P_CENTER = a[1] + 0
	} else {
		P_CENTER = P_FREQ
	}
}

function parse_txpower(line,   s) {
	P_TX = NA
	s = line
	sub(/^[ \t]*txpower[ \t]+/, "", s)
	sub(/[ \t]*dBm.*$/, "", s)
	if (s ~ /^[-+]?[0-9]+(\.[0-9]+)?$/)
		P_TX = dbm_to_cents(s)
}

function add_iface(name, phy, type, link, chan, freq, width, center, tx, islink) {
	IF_N++
	IF_NAME[IF_N] = name
	IF_PHY[IF_N] = phy
	IF_TYPE[IF_N] = type
	IF_LINK[IF_N] = link
	IF_CHAN[IF_N] = chan
	IF_FREQ[IF_N] = freq
	IF_WIDTH[IF_N] = width
	IF_CENTER[IF_N] = center
	IF_TX[IF_N] = tx
	IF_ISLINK[IF_N] = islink
}

function flush_dev(   i) {
	if (cur_name == "")
		return
	if (cur_chan != NA)
		add_iface(cur_name, cur_phy, cur_type, "", cur_chan, cur_freq,
			  cur_width, cur_center, cur_tx, 0)
	for (i = 1; i <= LINK_N; i++)
		if (LINK_CHAN[i] != NA)
			add_iface(cur_name, cur_phy, cur_type, LINK_ID[i],
				  LINK_CHAN[i], LINK_FREQ[i], LINK_WIDTH[i],
				  LINK_CENTER[i], LINK_TX[i], 1)
	cur_name = ""
	cur_type = ""
	cur_chan = NA
	cur_freq = NA
	cur_width = NA
	cur_center = NA
	cur_tx = NA
	in_link = 0
	LINK_N = 0
}

function parse_dev(line,   s) {
	if (line ~ /^phy#[0-9]+/) {
		flush_dev()
		cur_phy = line
		sub(/#/, "", cur_phy)
		cur_phy = trim(cur_phy)
		return
	}
	if (match(line, /^[ \t]*Interface /)) {
		flush_dev()
		cur_name = substr(line, RSTART + RLENGTH)
		cur_name = trim(cur_name)
		cur_type = ""
		cur_chan = NA
		cur_freq = NA
		cur_width = NA
		cur_center = NA
		cur_tx = NA
		in_link = 0
		LINK_N = 0
		return
	}
	if (match(line, /^[ \t]*type /)) {
		cur_type = substr(line, RSTART + RLENGTH)
		cur_type = trim(cur_type)
		return
	}
	if (line ~ /^[ \t]*MLD with links:/) {
		in_link = 0
		return
	}
	if (match(line, /- link ID[ \t]+[0-9]+/)) {
		in_link = 1
		s = substr(line, RSTART, RLENGTH)
		sub(/.*- link ID[ \t]+/, "", s)
		LINK_N++
		LINK_ID[LINK_N] = s + 0
		LINK_CHAN[LINK_N] = NA
		LINK_FREQ[LINK_N] = NA
		LINK_WIDTH[LINK_N] = NA
		LINK_CENTER[LINK_N] = NA
		LINK_TX[LINK_N] = NA
		return
	}
	if (match(line, /^[ \t]*channel /)) {
		parse_channel(line)
		if (in_link) {
			LINK_CHAN[LINK_N] = P_CHAN
			LINK_FREQ[LINK_N] = P_FREQ
			LINK_WIDTH[LINK_N] = P_WIDTH
			LINK_CENTER[LINK_N] = P_CENTER
		} else {
			cur_chan = P_CHAN
			cur_freq = P_FREQ
			cur_width = P_WIDTH
			cur_center = P_CENTER
		}
		return
	}
	if (match(line, /^[ \t]*txpower /)) {
		parse_txpower(line)
		if (in_link)
			LINK_TX[LINK_N] = P_TX
		else
			cur_tx = P_TX
	}
}

function parse_freq(line,   s, a, p) {
	P_FREQ = NA
	P_CHAN = NA
	P_DBM = NA
	P_DISABLED = 0
	P_NOIR = 0
	P_DFS = 0
	P_PASSIVE = 0
	s = line
	sub(/^[ \t]*\* /, "", s)
	split(s, a, " ")
	P_FREQ = a[1]
	sub(/\..*/, "", P_FREQ)
	P_FREQ += 0
	if (match(s, /\[[0-9]+\]/)) {
		p = substr(s, RSTART, RLENGTH)
		gsub(/[^0-9]/, "", p)
		P_CHAN = p + 0
	}
	if (match(s, /[-+]?[0-9]+(\.[0-9]+)? dBm/)) {
		p = substr(s, RSTART, RLENGTH)
		sub(/ dBm/, "", p)
		P_DBM = dbm_to_cents(p)
	}
	if (s ~ /\(disabled\)/)
		P_DISABLED = 1
	if (s ~ /\(no IR\)/ || s ~ /\(passive scan\)/)
		P_NOIR = 1
	if (s ~ /\(passive scan\)/)
		P_PASSIVE = 1
	if (s ~ /\(radar detection\)/)
		P_DFS = 1
}

function add_freq() {
	if (cur_wiphy == "" || P_FREQ == NA || P_FREQ <= 0)
		return
	F_N++
	F_PHY[F_N] = cur_wiphy
	F_BAND[F_N] = band_of(P_FREQ)
	F_FREQ[F_N] = P_FREQ
	F_CHAN[F_N] = P_CHAN
	F_DBM[F_N] = P_DBM
	F_DISABLED[F_N] = P_DISABLED
	F_NOIR[F_N] = P_NOIR
	F_DFS[F_N] = P_DFS
}

function parse_phy(line,   s) {
	if (match(line, /^Wiphy phy[0-9]+/)) {
		s = substr(line, RSTART, RLENGTH)
		sub(/^Wiphy /, "", s)
		cur_wiphy = s
		if (!(s in PHY_SEEN)) {
			PHY_SEEN[s] = 1
			PHY_NAME[++PHY_N] = s
		}
		return
	}
	if (line ~ /^[ \t]*\* /) {
		parse_freq(line)
		add_freq()
	}
}

function scope_for(phy) {
	if (phy in SCOPE_SEEN)
		return phy
	if ("global" in SCOPE_SEEN)
		return "global"
	return ""
}

function rule_str(r) {
	return sprintf("%d - %d @ %d", RL_START[r], RL_END[r], RL_BW[r])
}

function primary_rule(scope, freq,   r, best, bestspan, span) {
	best = 0
	bestspan = 999999
	for (r = 1; r <= RULE_N; r++) {
		if (RL_SCOPE[r] != scope)
			continue
		if (freq < RL_START[r] || freq > RL_END[r])
			continue
		span = RL_END[r] - RL_START[r]
		if (best == 0 || span < bestspan) {
			best = r
			bestspan = span
		}
	}
	return best
}

# Is [lo, hi] fully covered by the union of rules in scope?
function span_covered(scope, lo, hi,   pos, best, r, found, guard) {
	pos = lo
	guard = 0
	while (pos < hi && guard++ < 10000) {
		best = pos
		found = 0
		for (r = 1; r <= RULE_N; r++) {
			if (RL_SCOPE[r] != scope)
				continue
			if (RL_END[r] <= pos)
				continue
			if (RL_START[r] > pos)
				continue
			found = 1
			if (RL_END[r] > best)
				best = RL_END[r]
		}
		if (!found)
			return 0
		if (best == pos)
			return 0
		pos = best
	}
	return pos >= hi
}

# Fill S_* for the rules intersecting the occupied span.
function summarize_rules(scope, lo, hi,   r, cnt, min, no_ir, dfs, noout) {
	cnt = 0
	min = 9999
	no_ir = 0
	dfs = 0
	noout = 0
	for (r = 1; r <= RULE_N; r++) {
		if (RL_SCOPE[r] != scope)
			continue
		if (RL_END[r] <= lo || RL_START[r] >= hi)
			continue
		cnt++
		if (RL_EIRP[r] < min)
			min = RL_EIRP[r]
		if (RL_NOIR[r])
			no_ir = 1
		if (RL_DFS[r])
			dfs = 1
		if (RL_NOOUT[r])
			noout = 1
	}
	S_CNT = cnt
	S_MIN = min
	S_NOIR = no_ir
	S_DFS = dfs
	S_NOOUT = noout
	return cnt
}

function find_freq(phy, freq, band,   i) {
	for (i = 1; i <= F_N; i++)
		if (F_PHY[i] == phy && F_FREQ[i] == freq && F_BAND[i] == band)
			return i
	return 0
}

function add_warning(text) {
	WARN_N++
	W_TEXT[WARN_N] = text
}

function add_skip(text) {
	SKIP_N++
	SK_TEXT[SKIP_N] = text
}

function add_error(text) {
	ERROR_N++
	E_TEXT[ERROR_N] = text
}

function check_add(ifname, phy, type, link, band, chan, freq, width, center,
		   reported, runtime, source, board_max, regdb_max, effective,
		   rule, scope, country, permitted, dfs, no_ir, noout,
		   status, reason, notes, verified,   i) {
	CHECK_N++
	C_IFNAME[CHECK_N] = ifname
	C_PHY[CHECK_N] = phy
	C_TYPE[CHECK_N] = type
	C_LINK[CHECK_N] = link
	C_BAND[CHECK_N] = band
	C_CHAN[CHECK_N] = chan
	C_FREQ[CHECK_N] = freq
	C_WIDTH[CHECK_N] = width
	C_CENTER[CHECK_N] = center
	C_REPORTED[CHECK_N] = reported
	C_RUNTIME[CHECK_N] = runtime
	C_SOURCE[CHECK_N] = source
	C_BOARD[CHECK_N] = board_max
	C_REGDB[CHECK_N] = regdb_max
	C_EFFECTIVE[CHECK_N] = effective
	C_RULE[CHECK_N] = rule
	C_SCOPE[CHECK_N] = scope
	C_COUNTRY[CHECK_N] = country
	C_PERMITTED[CHECK_N] = permitted
	C_DFS[CHECK_N] = dfs
	C_NOIR[CHECK_N] = no_ir
	C_NOOUT[CHECK_N] = noout
	C_STATUS[CHECK_N] = status
	C_REASON[CHECK_N] = reason
	C_NOTES[CHECK_N] = notes
	C_VERIFIED[CHECK_N] = verified
	if (status == "FAIL")
		FAIL_N++
}

function print_check(i,   n, k, notes) {
	if (C_STATUS[i] == "PASS") {
		printf "PASS %s ch%d %s MHz txpower %s dBm",
			C_BAND[i], C_CHAN[i], C_WIDTH[i],
			cents_to_str(C_RUNTIME[i])
		if (C_BOARD[i] != NA)
			printf " <= board %s dBm", cents_to_str(C_BOARD[i])
		printf " <= regdb %d dBm (%s)", C_REGDB[i], C_RULE[i]
		if (C_BAND[i] == "6G")
			printf " <= LPI 30 dBm"
	} else {
		printf "FAIL %s ch%d %s MHz txpower %s dBm (board %s, regdb %d dBm, %s)",
			C_BAND[i], C_CHAN[i], C_WIDTH[i],
			cents_to_str(C_RUNTIME[i]),
			(C_BOARD[i] == NA ? "N/A" : cents_to_str(C_BOARD[i]) " dBm"),
			C_REGDB[i], C_RULE[i]
		if (C_BAND[i] == "6G")
			printf " [LPI 30 dBm]"
	}
	printf " [country %s, %s]", C_COUNTRY[i], C_SCOPE[i]
	if (C_LINK[i] != "")
		printf " (%s link %s)", C_IFNAME[i], C_LINK[i]
	else
		printf " (%s)", C_IFNAME[i]
	if (!C_VERIFIED[i])
		printf " [power unverified]"
	if (C_STATUS[i] == "FAIL")
		printf ": %s", C_REASON[i]
	print ""
	if (C_NOTES[i] != "") {
		n = split(C_NOTES[i], notes, "\034")
		for (k = 1; k <= n; k++)
			print "  NOTE " notes[k]
	}
}

function print_dev_dump(   i) {
	print "== iw dev (txpower) =="
	for (i = 1; i <= IF_N; i++) {
		printf "  %s %s", IF_PHY[i], IF_NAME[i]
		if (IF_LINK[i] != "")
			printf " link %s", IF_LINK[i]
		printf " type=%s", (IF_TYPE[i] == "" ? "?" : IF_TYPE[i])
		if (IF_CHAN[i] == NA) {
			printf " no-channel"
		} else if (IF_WIDTH[i] == -2) {
			printf " ch%d (%d MHz) width=80+80MHz",
				IF_CHAN[i], IF_FREQ[i]
		} else {
			printf " ch%d (%d MHz) width=%dMHz center1=%dMHz",
				IF_CHAN[i], IF_FREQ[i], IF_WIDTH[i], IF_CENTER[i]
		}
		printf " txpower=%s dBm\n", cents_to_str(IF_TX[i])
	}
}

function print_phy_dump(   p, b, i, band, cnt, minf, maxf, maxd, maxfreq, dfs) {
	print "== iw phy per-band power =="
	for (p = 1; p <= PHY_N; p++) {
		for (b = 1; b <= 3; b++) {
			band = (b == 1 ? "2.4G" : b == 2 ? "5G" : "6G")
			cnt = 0
			minf = 0
			maxf = 0
			maxd = NA
			maxfreq = 0
			dfs = 0
			for (i = 1; i <= F_N; i++) {
				if (F_PHY[i] != PHY_NAME[p] || F_BAND[i] != band)
					continue
				cnt++
				if (minf == 0 || F_FREQ[i] < minf)
					minf = F_FREQ[i]
				if (F_FREQ[i] > maxf)
					maxf = F_FREQ[i]
				if (F_DBM[i] != NA && (maxd == NA || F_DBM[i] > maxd)) {
					maxd = F_DBM[i]
					maxfreq = F_FREQ[i]
				}
				if (F_DFS[i])
					dfs = 1
			}
			if (cnt == 0)
				continue
			printf "  %s %s: %d-%d MHz, %d channels, max %s dBm",
				PHY_NAME[p], band, minf, maxf, cnt,
				cents_to_str(maxd)
			if (maxd != NA)
				printf " at %d MHz", maxfreq
			if (dfs)
				printf " (DFS)"
			print ""
		}
	}
}

function audit(   i, j, band, scope, pri, lo, hi, fi, board_max, regdb_max,
		  effective, runtime, reported, source, permitted, status, reason,
		  notes, direct, direct_name, unverified,
		  c_2g, c_5g, c_6g, country, country_scope, global_country,
		  rule) {
	# Effective country and board default.
	global_country = ""
	if ("global" in SCOPE_SEEN)
		global_country = SCOPE_COUNTRY["global"]
	country = global_country
	country_scope = "global"
	if (country == "" || country == "00") {
		for (i = 1; i <= SCOPE_N; i++) {
			if (SCOPE_COUNTRY[SCOPE_ORDER[i]] != "" &&
			    SCOPE_COUNTRY[SCOPE_ORDER[i]] != "00") {
				country = SCOPE_COUNTRY[SCOPE_ORDER[i]]
				country_scope = SCOPE_ORDER[i]
				break
			}
		}
	}

	if (!json_only) {
		print ""
		print "regdb:   country " (country == "" ? "unknown" : country) \
			" (" (country_scope in SCOPE_DFSNAME ? SCOPE_DFSNAME[country_scope] : "no rules") \
			", scope " country_scope ")"
	}

	if (RULE_N == 0) {
		add_error("no regulatory rules parsed from iw reg get")
	}

	c_2g = 0
	c_5g = 0
	c_6g = 0

	for (i = 1; i <= IF_N; i++) {
		if (IF_CHAN[i] == NA) {
			add_skip(IF_NAME[i] ": no channel (interface down or not started)")
			continue
		}
		band = band_of(IF_FREQ[i])
		if (band == "Sub-1G" || band == "60G" || band == "unknown") {
			add_skip(IF_NAME[i] ": band " band " is not audited")
			continue
		}
		scope = scope_for(IF_PHY[i])
		if (scope == "") {
			reason = "no regulatory scope for " IF_PHY[i]
			check_add(IF_NAME[i], IF_PHY[i], IF_TYPE[i], IF_LINK[i],
				  band, IF_CHAN[i], IF_FREQ[i], IF_WIDTH[i],
				  IF_CENTER[i], IF_TX[i], IF_TX[i], "none",
				  NA, 0, 0, "", "", "", 0, 0, 0, 0,
				  "FAIL", reason, "", 0)
			c_2g += (band == "2.4G")
			c_5g += (band == "5G")
			c_6g += (band == "6G")
			continue
		}
		if (IF_WIDTH[i] == -2) {
			reason = "unsupported split width 80+80 MHz"
			check_add(IF_NAME[i], IF_PHY[i], IF_TYPE[i], IF_LINK[i],
				  band, IF_CHAN[i], IF_FREQ[i], 0,
				  IF_CENTER[i], IF_TX[i], IF_TX[i], "none",
				  NA, 0, 0, "", scope, SCOPE_COUNTRY[scope],
				  0, 0, 0, 0, "FAIL", reason, "", 0)
			c_2g += (band == "2.4G")
			c_5g += (band == "5G")
			c_6g += (band == "6G")
			continue
		}
		status = ""
		reason = ""
		notes = ""
		permitted = 1
		effective = 0
		lo = IF_CENTER[i] - IF_WIDTH[i] / 2
		hi = IF_CENTER[i] + IF_WIDTH[i] / 2
		pri = primary_rule(scope, IF_FREQ[i])
		if (pri == 0) {
			rule = "no rule covers " IF_FREQ[i] " MHz"
			regdb_max = 0
		} else {
			rule = rule_str(pri)
			regdb_max = RL_EIRP[pri]
		}
		if (summarize_rules(scope, lo, hi) > 0 && pri != 0) {
			if (S_MIN < regdb_max)
				regdb_max = S_MIN
			if (S_CNT > 1)
				notes = notes (notes == "" ? "" : "\034") \
					IF_WIDTH[i] " MHz spans " S_CNT \
					" regdb rules; ceiling is the lowest EIRP (" \
					regdb_max " dBm)"
		}
		if (pri == 0) {
			permitted = 0
			reason = "primary channel not permitted by regdb"
		}
		if (!span_covered(scope, lo, hi)) {
			permitted = 0
			reason = reason (reason == "" ? "" : "; ") \
				"occupied span " lo "-" hi " MHz is not covered by regdb"
		}
		if (pri != 0 && S_NOIR && is_ap_type(IF_TYPE[i])) {
			permitted = 0
			reason = reason (reason == "" ? "" : "; ") \
				"regdb NO-IR rule does not permit an AP"
		}

		fi = find_freq(IF_PHY[i], IF_FREQ[i], band)
		board_max = NA
		if (fi == 0) {
			permitted = 0
			reason = reason (reason == "" ? "" : "; ") \
				"channel " IF_CHAN[i] " is not listed by iw phy"
		} else {
			board_max = F_DBM[fi]
			if (F_DISABLED[fi]) {
				permitted = 0
				reason = reason (reason == "" ? "" : "; ") \
					"channel " IF_CHAN[i] " is disabled"
			}
			if (F_NOIR[fi] && is_ap_type(IF_TYPE[i])) {
				permitted = 0
				reason = reason (reason == "" ? "" : "; ") \
					"iw phy marks channel " IF_CHAN[i] " NO-IR"
			}
			if (board_max == NA) {
				permitted = 0
				reason = reason (reason == "" ? "" : "; ") \
					"iw phy reports no power for channel " IF_CHAN[i]
			}
		}

		# Runtime power: per-band single-link AP is authoritative for an
		# MLD link on mt7996, because get_txpower() uses the default link.
		reported = IF_TX[i]
		runtime = reported
		source = IF_NAME[i]
		unverified = 0
		if (IF_LINK[i] != "") {
			direct = NA
			direct_name = ""
			for (j = 1; j <= IF_N; j++) {
				if (IF_ISLINK[j])
					continue
				if (IF_TYPE[j] != "AP")
					continue
				if (IF_FREQ[j] == NA)
					continue
				if (band_of(IF_FREQ[j]) != band)
					continue
				if (IF_FREQ[j] != IF_FREQ[i])
					continue
				if (IF_TX[j] == NA)
					continue
				direct = IF_TX[j]
				direct_name = IF_NAME[j]
				break
			}
			if (direct != NA) {
				runtime = direct
				source = direct_name
				if (reported != NA && reported != direct)
					notes = notes (notes == "" ? "" : "\034") \
						"link reports " cents_to_str(reported) \
						" dBm; using per-band runtime " \
						cents_to_str(direct) " dBm from " direct_name \
						" (mt7996 reports the default link for every MLO link)"
			} else {
				unverified = 1
				source = IF_NAME[i] " link " IF_LINK[i]
				notes = notes (notes == "" ? "" : "\034") \
					"no single-link AP on this band to cross-check the MLO link power"
				# mt7996 returns the default link phy for every MLO
				# link, so a reported value above this band board
				# limit must not be trusted as this link power.
				# The board limit itself is the verifiable ceiling;
				# keep the 6 GHz hard cap on the reported value.
				if (reported != NA && board_max != NA &&
				    reported > board_max &&
				    !(band == "6G" && reported > 3000)) {
					notes = notes (notes == "" ? "" : "\034") \
						"reported link power " cents_to_str(reported) \
						" dBm is above the board limit; using the board limit " \
						cents_to_str(board_max) \
						" dBm as the verifiable ceiling"
					runtime = board_max
					source = "board-limit"
				}
				add_warning(IF_NAME[i] " link " IF_LINK[i] \
					": link power is not independently verified")
			}
		}

		if (runtime == NA) {
			status = "FAIL"
			reason = reason (reason == "" ? "" : "; ") \
				"no runtime txpower reported by iw dev"
		}

		effective = regdb_max * 100
		if (board_max != NA && board_max < effective)
			effective = board_max
		if (band == "6G" && effective > 3000)
			effective = 3000

		if (board_max != NA && regdb_max > 0 && board_max > regdb_max * 100) {
			status = "FAIL"
			reason = reason (reason == "" ? "" : "; ") \
				"iw phy board limit " cents_to_str(board_max) \
				" dBm exceeds regdb " regdb_max " dBm"
		}
		if (board_max != NA && band == "6G" && board_max > 3000) {
			status = "FAIL"
			reason = reason (reason == "" ? "" : "; ") \
				"6G board limit " cents_to_str(board_max) \
				" dBm exceeds FCC LPI 30 dBm"
		}
		if (runtime != NA && band == "6G" && runtime > 3000) {
			status = "FAIL"
			reason = reason (reason == "" ? "" : "; ") \
				"6G txpower " cents_to_str(runtime) \
				" dBm exceeds FCC LPI 30 dBm"
		}
		if (runtime != NA && pri != 0) {
			if (runtime > effective) {
				status = "FAIL"
				reason = reason (reason == "" ? "" : "; ") \
					"txpower " cents_to_str(runtime) \
					" dBm exceeds ceiling " \
					cents_to_str(effective) " dBm"
			}
			if (board_max != NA && runtime > board_max) {
				status = "FAIL"
				reason = reason (reason == "" ? "" : "; ") \
					"txpower " cents_to_str(runtime) \
					" dBm exceeds board limit " \
					cents_to_str(board_max) " dBm"
			}
		}
		if (permitted == 0 && status != "FAIL")
			status = "FAIL"
		if (status == "" && reason != "")
			status = "FAIL"
		if (status == "")
			status = "PASS"

		if (S_DFS || (fi != 0 && F_DFS[fi]))
			notes = notes (notes == "" ? "" : "\034") "DFS channel; CAC is required before beaconing"
		if (S_NOOUT)
			notes = notes (notes == "" ? "" : "\034") "regdb rule is NO-OUTDOOR; this is an indoor AP"

		check_add(IF_NAME[i], IF_PHY[i], IF_TYPE[i], IF_LINK[i], band,
			  IF_CHAN[i], IF_FREQ[i], IF_WIDTH[i], IF_CENTER[i],
			  reported, runtime, source, board_max, regdb_max,
			  effective, rule, scope, SCOPE_COUNTRY[scope], permitted,
			  (S_DFS || (fi != 0 && F_DFS[fi])), S_NOIR,
			  S_NOOUT, status, reason, notes, (unverified ? 0 : 1))
		c_2g += (band == "2.4G")
		c_5g += (band == "5G")
		c_6g += (band == "6G")
	}

	if (c_2g == 0)
		add_warning("2.4G: no active interface (radio disabled or not started)")
	if (c_5g == 0)
		add_warning("5G: no active interface; 5G power not verified")
	if (c_6g == 0)
		add_warning("6G: no active interface; 6G power not verified")

	if (!json_only) {
		print ""
		print_dev_dump()
		print ""
		print_phy_dump()
		print ""
		print "== checks =="
		for (i = 1; i <= CHECK_N; i++)
			print_check(i)
		for (i = 1; i <= SKIP_N; i++)
			print "SKIP " SK_TEXT[i]
		for (i = 1; i <= WARN_N; i++)
			print "WARN " W_TEXT[i]
		for (i = 1; i <= ERROR_N; i++)
			print "ERROR " E_TEXT[i]
	}

	if (ERROR_N > 0)
		result = "ERROR"
	else if (CHECK_N == 0)
		result = "SKIP"
	else if (FAIL_N > 0)
		result = "FAIL"
	else
		result = "PASS"

	if (!json_only) {
		print ""
		printf "RESULT: %s (%d checks, %d failed, %d warnings, %d skipped)\n",
			result, CHECK_N, FAIL_N, WARN_N, SKIP_N
	}

	if (json_only)
		printf "%s\n", build_json(result, country)

	if (result == "ERROR")
		exit 2
	exit (result == "FAIL" ? 1 : 0)
}

function build_json(result, country,   s, i, j, p, b, r, sep, first, maxd,
		    minf, maxf, cnt, band) {
	s = "{"
	s = s "\"schema\":\"txpower-audit/1\""
	s = s ",\"generated_at\":" jstr(generated)
	s = s ",\"mode\":" jstr(mode)
	s = s ",\"read_only\":true"
	s = s ",\"board\":{\"name\":" jstr(board) ",\"model\":" jstr(model) "}"
	s = s ",\"kernel\":" jstr(kernel)
	s = s ",\"default_country\":" jstr(default_country)
	s = s ",\"effective_country\":" jstr(country)
	s = s ",\"country_match\":"
	if (default_country == "" || country == "")
		s = s "null"
	else
		s = s jbool(default_country == country)
	s = s ",\"regulatory_db_md5\":" jstr(regdb_md5)
	s = s ",\"result\":" jstr(result)
	s = s ",\"checks_total\":" CHECK_N
	s = s ",\"checks_failed\":" FAIL_N
	s = s ",\"warnings_total\":" WARN_N
	s = s ",\"skipped_total\":" SKIP_N

	# checks
	s = s ",\"checks\":["
	sep = ""
	for (i = 1; i <= CHECK_N; i++) {
		s = s sep "{"
		s = s "\"ifname\":" jstr(C_IFNAME[i])
		s = s ",\"phy\":" jstr(C_PHY[i])
		if (C_LINK[i] == "")
			s = s ",\"link_id\":null"
		else
			s = s ",\"link_id\":" jint(C_LINK[i])
		s = s ",\"type\":" jstr(C_TYPE[i])
		s = s ",\"band\":" jstr(C_BAND[i])
		s = s ",\"channel\":" jint(C_CHAN[i])
		s = s ",\"frequency_mhz\":" jint(C_FREQ[i])
		s = s ",\"width_mhz\":" jint(C_WIDTH[i])
		s = s ",\"center_mhz\":" jint(C_CENTER[i])
		s = s ",\"occupied_mhz\":["
		s = s sprintf("%d", C_CENTER[i] - C_WIDTH[i] / 2) ","
		s = s sprintf("%d", C_CENTER[i] + C_WIDTH[i] / 2) "]"
		s = s ",\"txpower_dbm\":" jnum(C_RUNTIME[i])
		s = s ",\"reported_txpower_dbm\":" jnum(C_REPORTED[i])
		s = s ",\"txpower_source\":" jstr(C_SOURCE[i])
		s = s ",\"power_verified\":" jbool(C_VERIFIED[i])
		s = s ",\"board_max_dbm\":" jnum(C_BOARD[i])
		s = s ",\"regdb_max_dbm\":" jint(C_REGDB[i])
		s = s ",\"effective_max_dbm\":" jnum(C_EFFECTIVE[i])
		s = s ",\"regdb_rule\":" jstr(C_RULE[i])
		s = s ",\"regdb_scope\":" jstr(C_SCOPE[i])
		s = s ",\"regdb_country\":" jstr(C_COUNTRY[i])
		s = s ",\"channel_permitted\":" jbool(C_PERMITTED[i])
		s = s ",\"dfs\":" jbool(C_DFS[i])
		s = s ",\"no_ir\":" jbool(C_NOIR[i])
		s = s ",\"no_outdoor\":" jbool(C_NOOUT[i])
		s = s ",\"status\":" jstr(C_STATUS[i])
		s = s ",\"reason\":" jstr(C_REASON[i])
		s = s ",\"notes\":" jnotes(C_NOTES[i])
		s = s "}"
		sep = ","
	}
	s = s "]"

	# interfaces
	s = s ",\"interfaces\":["
	sep = ""
	for (i = 1; i <= IF_N; i++) {
		s = s sep "{"
		s = s "\"ifname\":" jstr(IF_NAME[i])
		s = s ",\"phy\":" jstr(IF_PHY[i])
		if (IF_LINK[i] == "")
			s = s ",\"link_id\":null"
		else
			s = s ",\"link_id\":" jint(IF_LINK[i])
		s = s ",\"type\":" jstr(IF_TYPE[i])
		s = s ",\"has_channel\":" jbool(IF_CHAN[i] != NA)
		if (IF_CHAN[i] == NA) {
			s = s ",\"channel\":null,\"width_mhz\":null"
		} else {
			s = s ",\"channel\":" jint(IF_CHAN[i])
			s = s ",\"width_mhz\":" jint(IF_WIDTH[i])
		}
		s = s ",\"txpower_dbm\":" jnum(IF_TX[i])
		s = s "}"
		sep = ","
	}
	s = s "]"

	# phy_bands
	s = s ",\"phy_bands\":["
	sep = ""
	for (p = 1; p <= PHY_N; p++) {
		for (b = 1; b <= 5; b++) {
			band = (b == 1 ? "2.4G" : b == 2 ? "5G" : b == 3 ? "6G" : b == 4 ? "Sub-1G" : "60G")
			cnt = 0
			maxd = NA
			minf = 0
			maxf = 0
			for (i = 1; i <= F_N; i++) {
				if (F_PHY[i] != PHY_NAME[p] || F_BAND[i] != band)
					continue
				cnt++
				if (minf == 0 || F_FREQ[i] < minf)
					minf = F_FREQ[i]
				if (F_FREQ[i] > maxf)
					maxf = F_FREQ[i]
				if (F_DBM[i] != NA && (maxd == NA || F_DBM[i] > maxd))
					maxd = F_DBM[i]
			}
			if (cnt == 0)
				continue
			s = s sep "{"
			s = s "\"phy\":" jstr(PHY_NAME[p])
			s = s ",\"band\":" jstr(band)
			s = s ",\"freq_min_mhz\":" jint(minf)
			s = s ",\"freq_max_mhz\":" jint(maxf)
			s = s ",\"channels\":" cnt
			s = s ",\"max_dbm\":" jnum(maxd)
			s = s "}"
			sep = ","
		}
	}
	s = s "]"

	# regdb
	s = s ",\"regdb\":{\"scopes\":["
	sep = ""
	for (i = 1; i <= SCOPE_N; i++) {
		s = s sep "{"
		s = s "\"name\":" jstr(SCOPE_ORDER[i])
		s = s ",\"country\":" jstr(SCOPE_COUNTRY[SCOPE_ORDER[i]])
		s = s ",\"dfs_region\":" jstr(SCOPE_DFSNAME[SCOPE_ORDER[i]])
		s = s ",\"rules\":["
		first = ""
		for (r = 1; r <= RULE_N; r++) {
			if (RL_SCOPE[r] != SCOPE_ORDER[i])
				continue
			s = s first "{"
			s = s "\"start_mhz\":" RL_START[r]
			s = s ",\"end_mhz\":" RL_END[r]
			s = s ",\"bw_mhz\":" RL_BW[r]
			s = s ",\"max_gain_dbm\":" jstr(RL_GAIN[r])
			s = s ",\"eirp_dbm\":" RL_EIRP[r]
			s = s ",\"cac\":" jstr(RL_CAC[r])
			s = s ",\"flags\":" jstr(RL_FLAGS[r])
			s = s ",\"no_ir\":" jbool(RL_NOIR[r])
			s = s ",\"dfs\":" jbool(RL_DFS[r])
			s = s ",\"no_outdoor\":" jbool(RL_NOOUT[r])
			s = s "}"
			first = ","
		}
		s = s "]}"
		sep = ","
	}
	s = s "]}"

	# warnings / skipped / errors
	s = s ",\"warnings\":["
	sep = ""
	for (i = 1; i <= WARN_N; i++) {
		s = s sep jstr(W_TEXT[i])
		sep = ","
	}
	s = s "]"
	s = s ",\"skipped\":["
	sep = ""
	for (i = 1; i <= SKIP_N; i++) {
		s = s sep jstr(SK_TEXT[i])
		sep = ","
	}
	s = s "]"
	s = s ",\"errors\":["
	sep = ""
	for (i = 1; i <= ERROR_N; i++) {
		s = s sep jstr(E_TEXT[i])
		sep = ","
	}
	s = s "]}"
	return s
}

$0 == "@@IW-DEV@@" {
	if (section == "dev")
		flush_dev()
	section = "dev"
	if (!json_only && verbose) {
		print ""
		print "== iw dev (full) =="
	}
	next
}

$0 == "@@IW-REG@@" {
	if (section == "dev")
		flush_dev()
	section = "reg"
	if (!json_only) {
		print ""
		print "== iw reg get =="
	}
	next
}

$0 == "@@IW-PHY@@" {
	section = "phy"
	if (!json_only && verbose) {
		print ""
		print "== iw phy (full) =="
	}
	next
}

$0 == "@@END@@" {
	if (section == "dev")
		flush_dev()
	section = ""
	next
}

section == "dev" {
	if (!json_only && verbose)
		print
	parse_dev($0)
	next
}

section == "reg" {
	if (!json_only)
		print
	parse_reg($0)
	next
}

section == "phy" {
	if (!json_only && verbose)
		print
	parse_phy($0)
	next
}

END {
	if (section == "dev")
		flush_dev()
	audit()
}
'
)
rc=$?
if [ -z "$report" ]; then
	die "internal error: empty audit output"
fi
printf '%s\n' "$report"
exit "$rc"
