#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# eip93-ipsec-smoke.sh - reproducible classic-ESP smoke test for EIP93.
#
# The EIP93 block in MediaTek/Airoha SoCs only accelerates classic ESP:
#
#     authenc(hmac(sha1|sha256|md5),cbc(aes|des|des3_ede))
#
# It has no GCM and no ChaCha20-Poly1305 offload.  This script therefore
# refuses those proposals instead of silently measuring software crypto,
# and it tests the manual "ip xfrm" path first - the IPsec daemon
# (strongSwan) is a separate, later step.
#
# What one run does:
#   1. Verifies that both ends can run "ip xfrm", that kmod-crypto-hw-eip93
#      is loaded, and that /proc/crypto reports the eip93 implementation of
#      the requested authenc transform.
#   2. Installs one transport-mode ESP SA per direction on both ends
#      (static keys, generated at run time) and a pair of narrow TCP
#      policies that only match the iperf3 port, so the SSH control
#      connection and every other flow are left alone.
#   3. Reads /sys/module/crypto_hw_eip93/refcnt on both ends before the SAs,
#      after the SAs and after the run.  The EIP93 module refcount must go
#      up when the SAs are installed; a zero delta means the ESP transform
#      selected a software implementation.
#   4. Starts a one-shot "iperf3 -s" on the peer over SSH, runs a single
#      client-to-server TCP stream for the requested duration, and records
#      the reported throughput.
#   5. Reads the kernel's per-SA packet counters ("ip -s xfrm state list",
#      'lifetime current: ... (packets)') for both SPIs on the local end and
#      fails when either SA carried no packet.  A refcount that only proves
#      the SA was allocated says nothing about the data path: a selector
#      typo, a policy that lost to SNAT, or an iperf3 flow that never left
#      the host keeps the stream in cleartext with the refcount still high.
#   6. Writes result.json (refcounts, ESP packet counters, throughput, the
#      exact ESP parameters, and the failure reason when something goes
#      wrong), removes the xfrm state again, and exits non-zero on failure.
#
# The script never adds routes or firewall rules and never touches the
# default routing table.  The only persistent changes are the two ESP SAs
# and the two port-scoped policies per side, and they are deleted on exit
# unless --keep is given.
#
# Requirements, on both ends:
#   - kmod-crypto-hw-eip93 installed and loaded
#   - ip-full ("ip xfrm" is not in ip-tiny)
#   - iperf3 3.x
#   - SSH from the local end to the peer (key-based, no password prompt)
# The local end must run as root.
#
# Exit status: 0 the smoke test passed, 1 the test failed (result.json has
# the reason), 2 invalid arguments or an unsupported ESP proposal.

set -u
set -f
LC_ALL=C
export LC_ALL

PROG=${0##*/}
MODULE=crypto_hw_eip93
MODPATH="/sys/module/$MODULE/refcnt"
PROC_CRYPTO=/proc/crypto

LOCAL=${LOCAL:-}
PEER=${PEER:-}
PEER_SSH=${PEER_SSH:-}
DURATION=${DURATION:-10}
PORT=${PORT:-5201}
CIPHER=${CIPHER:-cbc(aes)}
AUTH=${AUTH:-hmac(sha1)}
REQID=${REQID:-0xE193}
SPI_OUT=${SPI_OUT:-0xe1930001}
SPI_IN=${SPI_IN:-0xe1930002}
OUT=${OUT:-}
KEEP=0
DRY_RUN=0
PRINT_ONLY=0
XFRM_TOUCHED=0
XFRM_SETUP_DONE=0

# Filled in as the run progresses; empty means "unknown" in result.json.
ERROR=
RESULT=fail
RAW_LOG=
IPERF_JSON=
IPERF_SSH_PID=
LOCAL_RC_BEFORE=
LOCAL_RC_AFTER_SETUP=
LOCAL_RC_AFTER_RUN=
PEER_RC_BEFORE=
PEER_RC_AFTER_SETUP=
PEER_RC_AFTER_RUN=
SEL_DRIVER=
SEL_PRIO=
ESP_OUT_PACKETS=
ESP_OUT_BYTES=
ESP_IN_PACKETS=
ESP_IN_BYTES=
BPS=
GBPS=
IPERF_BYTES=
IPERF_SECONDS=
IPERF_RETRANSMITS=
ENC_KEY_OUT=
AUTH_KEY_OUT=
ENC_KEY_IN=
AUTH_KEY_IN=
ENC_KEY_BITS=
AUTH_KEY_BITS=

usage() {
	cat <<'EOF'
Usage: eip93-ipsec-smoke.sh [options]

Reproducible classic-ESP smoke test for the EIP93 crypto engine.  The
script configures one transport-mode ESP SA per direction with static
keys on both ends, sends a single unidirectional iperf3 TCP stream
(local -> peer), and records the ESP parameters, the EIP93 module
refcount on both ends and the measured throughput in result.json.

EIP93 has no GCM and no ChaCha20-Poly1305 offload.  Only classic ESP is
accepted: cbc(aes)/cbc(des)/cbc(des3_ede) with hmac(sha1)/hmac(sha256)/
hmac(md5).  Any GCM, CCM, RFC4106 or ChaCha20 proposal is rejected.

Required for a real run (environment variable or flag):
  LOCAL / --local ADDR        IPv4 address of this end of the test link
  PEER / --peer ADDR          IPv4 address of the peer end
  PEER_SSH / --peer-ssh TARGET
                              ssh target for the peer, e.g.
                              root@10.0.0.2; key-based login, the script
                              runs with BatchMode=yes and never prompts

Optional inputs (environment variable or flag):
  DURATION / --duration SEC   iperf3 run length (default 10)
  PORT / --port PORT          iperf3 TCP port (default 5201)
  CIPHER / --cipher NAME      ESP cipher (default cbc(aes)); classic only
  AUTH / --auth NAME          ESP auth (default hmac(sha1)); classic only
  REQID / --reqid N           xfrm reqid, decimal or 0x hex (default 0xE193)
  SPI_OUT / --spi-out SPI     SPI for local -> peer (default 0xe1930001)
  SPI_IN / --spi-in SPI       SPI for peer -> local (default 0xe1930002)
  OUT / --out FILE            result.json path
                              (default ./eip93-ipsec-smoke-<epoch>.json)

Options:
  --keep                      leave the xfrm SAs and policies installed for
                              inspection; the script prints the exact delete
                              commands and exits with the test status
  --dry-run                   print every command a real run would execute
                              (local and peer), then exit 0 without changing
                              anything and without contacting the peer.
                              Missing LOCAL/PEER/PEER_SSH appear as
                              placeholders; keys are shown as <enc-key> /
                              <auth-key> because they are generated at run
                              time and are never printed or logged.
  -h, --help                  this text

How the test proves that the hardware was used:
  /sys/module/crypto_hw_eip93/refcnt counts the references the crypto API
  holds on the EIP93 module.  Installing each ESP SA allocates an
  authenc(hmac(...),cbc(...)) transform from the highest-priority
  implementation, so the refcount must increase when the SAs are added.
  The script reads it before setup, after setup and after the iperf3 run
  on both ends; a zero delta fails the test.  /proc/crypto must also list
  the eip93 driver for the selected authenc transform (driver names look
  like "authenc(hmac(sha1-eip93),cbc(aes-eip93))", priority 1500).

Why the policies are port-scoped:
  The policies select only "proto tcp dport PORT" (outbound) and
  "proto tcp sport PORT" (inbound), so the SSH connection that configures
  the peer and every unrelated packet keep using the normal stack.  The
  script does not add routes or firewall rules and does not change the
  default policy.

Preconditions checked by a real run:
  - running as root, with "ip" that supports xfrm (ip-full)
  - iperf3 3.x locally and on the peer
  - passwordless SSH to the peer (BatchMode); the peer is not contacted
    by --dry-run
  - kmod-crypto-hw-eip93 loaded on both ends
  - /proc/crypto lists an eip93 implementation of authenc(AUTH,CIPHER)

Output:
  FILE                       result.json
  FILE.log                   chronological command log (keys are redacted)
  FILE.iperf3.json           raw iperf3 JSON
  FILE.iperf3.json.err       iperf3 stderr

Examples:
  ./scripts/eip93-ipsec-smoke.sh --local 10.93.0.1 --peer 10.93.0.2 \
      --peer-ssh root@10.93.0.2
  DURATION=30 ./scripts/eip93-ipsec-smoke.sh --local 10.93.0.1 \
      --peer 10.93.0.2 --peer-ssh root@10.93.0.2 --keep
  ./scripts/eip93-ipsec-smoke.sh --dry-run --local 10.93.0.1 \
      --peer 10.93.0.2 --peer-ssh root@10.93.0.2
EOF
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf 'Try "%s --help" for usage.\n' "$PROG" >&2
	exit 2
}

die() {
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	exit 1
}

now_ts() {
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || _ts=
	if [ -z "$_ts" ]; then
		_ts=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) || _ts=unknown
	fi
	printf '%s' "$_ts"
}

json_escape() {
	printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
		-e 's/[[:cntrl:]]/ /g'
}

# Yields JSON null when the value is empty or not numeric, the value
# itself otherwise.  Used for every number in result.json.
json_num() {
	case $1 in
	''|null) printf 'null' ;;
	*[!0-9.eE+-]*) printf 'null' ;;
	*) printf '%s' "$1" ;;
	esac
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++) {
				if ($i !~ /^[0-9]+$/ || length($i) > 3)
					exit 1
				if (length($i) > 1 && $i ~ /^0/)
					exit 1
				if ($i < 0 || $i > 255)
					exit 1
			}
		}'
}

valid_hex() {
	_hex=$1
	case $_hex in
	0x*|0X*) _hex=${_hex#0[xX]} ;;
	esac
	case $_hex in
	''|*[!0-9a-fA-F]*) return 1 ;;
	esac
	[ $((${#_hex} % 2)) -eq 0 ]
}

gen_hex() {
	# BusyBox on OpenWrt ships CONFIG_HEXDUMP=y without od; -v prevents '*'
	# squashing on identical 16-byte blocks and 1/1 "%02x" emits lowercase
	# byte-order hex identical on BusyBox and GNU/BSD hexdump.
	dd if=/dev/urandom bs="$1" count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

log_cmd() {
	[ -n "$RAW_LOG" ] || return 0
	printf '%s + %s\n' "$(now_ts)" "$*" >>"$RAW_LOG"
}

log_note() {
	[ -n "$RAW_LOG" ] || return 0
	printf '%s %s\n' "$(now_ts)" "$*" >>"$RAW_LOG"
}

ssh_peer() {
	ssh -n -T -o BatchMode=yes -o ConnectTimeout=5 "$PEER_SSH" "$1"
}

# Run one command string.  $1 is local or peer, $2 the redacted form used
# for the command log / --dry-run, $3 the command with real key material.
run_cmd() {
	if [ "$DRY_RUN" = 1 ] || [ "$PRINT_ONLY" = 1 ]; then
		printf '[%s] %s\n' "$1" "$2"
		return 0
	fi
	if [ "$1" = peer ]; then
		log_cmd "[peer] $2"
		ssh_peer "$3"
	else
		log_cmd "[local] $2"
		sh -c "$3"
	fi
}

# Local/peer helpers for commands without secrets (policy and delete).
run_simple() {
	# $1 role, $2 command string
	run_cmd "$1" "$2" "$2"
}

local_refcnt() {
	[ -r "$MODPATH" ] || return 1
	IFS= read -r _rc <"$MODPATH" || _rc=
	case $_rc in
	''|*[!0-9]*) return 1 ;;
	esac
	printf '%s' "$_rc"
}

peer_refcnt() {
	_out=$(ssh_peer "head -n 1 $MODPATH" 2>/dev/null) || return 1
	case $_out in
	''|*[!0-9]*) return 1 ;;
	esac
	printf '%s' "$_out"
}

# The kernel's per-SA counters, as "PACKETS BYTES" for one SPI, from the text
# of `ip -s xfrm state list`.  Empty when the SA is not there or the line does
# not carry a packets counter; bytes is "unknown" when the kernel printed
# packets but no byte count.
#
# Two things about that text are easy to get wrong, and both were (board run,
# 2026-11-24): `ip -s` prints the SPI as "0x%08x(%u)", and it prints the
# counters on the line *under* "lifetime current:", not on that line -
# iproute2 6.18 ip/ipxfrm.c:403-407 writes the label, then
# "  %llu(bytes), %llu(packets)" on the next line.  So the SPI is compared
# after normalising (drop the decimal suffix, the 0x and the leading zeros)
# and the counters are recognised by their own shape, on whatever line they
# land.  "lifetime config:" prints "(INF)(bytes), (INF)(packets)" and matches
# neither pattern.
esp_parse() {
	printf '%s\n' "$1" | awk -v want="$2" '
		function norm(s) {
			sub(/\(.*/, "", s)
			sub(/^0[xX]/, "", s)
			sub(/^0+/, "", s)
			return tolower(s)
		}
		BEGIN { want = norm(want) }
		$1 == "proto" && $2 == "esp" && $3 == "spi" { spi = norm($4); next }
		spi == want && /[0-9]+\(bytes\)/ && /[0-9]+\(packets\)/ {
			if (match($0, /[0-9]+\(bytes\)/))
				bytes = substr($0, RSTART, RLENGTH - 7)
			if (match($0, /[0-9]+\(packets\)/))
				packets = substr($0, RSTART, RLENGTH - 9)
		}
		END {
			if (packets == "")
				exit
			if (bytes == "")
				bytes = "unknown"
			print packets " " bytes
		}'
}

esp_state() {
	log_cmd "[local] ip -s xfrm state list"
	ip -s xfrm state list 2>/dev/null
}

# Print the highest-priority implementation of authenc(AUTH,CIPHER) as
# "driver<TAB>priority", using only the kernels' /proc/crypto text.
proc_crypto_selected() {
	awk -v want="authenc($AUTH,$CIPHER)" '
		BEGIN { best = -1 }
		/^name[ \t]*:/ {
			name = $0
			sub(/^name[ \t]*:[ \t]*/, "", name)
			driver = ""
			prio = -1
			next
		}
		/^driver[ \t]*:/ {
			driver = $0
			sub(/^driver[ \t]*:[ \t]*/, "", driver)
			next
		}
		/^priority[ \t]*:/ {
			prio = $0
			sub(/^priority[ \t]*:[ \t]*/, "", prio)
			prio += 0
			if (name == want && driver != "" && prio >= best) {
				best = prio
				bestdrv = driver
			}
			next
		}
		END {
			if (bestdrv != "")
				printf "%s\t%s\n", bestdrv, best
		}' "$PROC_CRYPTO"
}

xfrm_state_add() {
	# $1 role, $2 src, $3 dst, $4 spi, $5 enc key, $6 auth key
	_real="ip xfrm state add src $2 dst $3 proto esp spi $4 reqid $REQID_DEC mode transport enc '$CIPHER' $5 auth '$AUTH' $6"
	_redacted="ip xfrm state add src $2 dst $3 proto esp spi $4 reqid $REQID_DEC mode transport enc '$CIPHER' <enc-key> auth '$AUTH' <auth-key>"
	run_cmd "$1" "$_redacted" "$_real"
}

xfrm_state_del() {
	run_simple "$1" "ip xfrm state delete src $2 dst $3 proto esp spi $4"
}

xfrm_policy_add() {
	# $1 role, $2 dir, $3 src, $4 dst, $5 port selector
	run_simple "$1" "ip xfrm policy add src $3/32 dst $4/32 proto tcp $5 dir $2 tmpl src $3 dst $4 proto esp reqid $REQID_DEC mode transport"
}

xfrm_policy_del() {
	run_simple "$1" "ip xfrm policy delete src $3/32 dst $4/32 proto tcp $5 dir $2"
}

xfrm_setup() {
	xfrm_state_add local "$LOCAL" "$PEER" "$SPI_OUT" "$ENC_KEY_OUT" "$AUTH_KEY_OUT" || return 1
	xfrm_state_add peer "$LOCAL" "$PEER" "$SPI_OUT" "$ENC_KEY_OUT" "$AUTH_KEY_OUT" || return 1
	xfrm_state_add local "$PEER" "$LOCAL" "$SPI_IN" "$ENC_KEY_IN" "$AUTH_KEY_IN" || return 1
	xfrm_state_add peer "$PEER" "$LOCAL" "$SPI_IN" "$ENC_KEY_IN" "$AUTH_KEY_IN" || return 1
	xfrm_policy_add local out "$LOCAL" "$PEER" "dport $PORT" || return 1
	xfrm_policy_add local in "$PEER" "$LOCAL" "sport $PORT" || return 1
	xfrm_policy_add peer out "$PEER" "$LOCAL" "sport $PORT" || return 1
	xfrm_policy_add peer in "$LOCAL" "$PEER" "dport $PORT" || return 1
	return 0
}

xfrm_teardown() {
	xfrm_policy_del local out "$LOCAL" "$PEER" "dport $PORT"
	xfrm_policy_del local in "$PEER" "$LOCAL" "sport $PORT"
	xfrm_state_del local "$LOCAL" "$PEER" "$SPI_OUT"
	xfrm_state_del local "$PEER" "$LOCAL" "$SPI_IN"
	xfrm_policy_del peer out "$PEER" "$LOCAL" "sport $PORT"
	xfrm_policy_del peer in "$LOCAL" "$PEER" "dport $PORT"
	xfrm_state_del peer "$PEER" "$LOCAL" "$SPI_IN"
	xfrm_state_del peer "$LOCAL" "$PEER" "$SPI_OUT"
}

# cleanup runs from the EXIT/INT/TERM traps below; shellcheck 0.11 does
# not treat trap handlers as callers (SC2329).
# shellcheck disable=SC2329
cleanup() {
	_rc=$?
	trap - EXIT INT TERM
	if [ -n "$IPERF_SSH_PID" ]; then
		kill "$IPERF_SSH_PID" 2>/dev/null || true
		wait "$IPERF_SSH_PID" 2>/dev/null || true
	fi
	if [ "$DRY_RUN" = 1 ]; then
		exit "$_rc"
	fi
	if [ "$XFRM_TOUCHED" != 1 ]; then
		exit "$_rc"
	fi
	if [ "$KEEP" = 1 ]; then
		printf '%s: xfrm state left in place (--keep); delete it with:\n' "$PROG" >&2
		PRINT_ONLY=1
		xfrm_teardown >&2
		PRINT_ONLY=0
		exit "$_rc"
	fi
	log_note "teardown"
	if ! xfrm_teardown >/dev/null 2>&1; then
		if [ "$XFRM_SETUP_DONE" = 1 ]; then
			printf '%s: warning: could not remove every xfrm state/policy; check "ip xfrm state list" and "ip xfrm policy list" on both ends\n' "$PROG" >&2
		fi
	fi
	exit "$_rc"
}

iperf_field() {
	# $1 file, $2 end object (sum_sent), $3 field name
	awk -v obj="$2" -v field="$3" '
		$0 ~ ("^[ \t]*\"" obj "\"[ \t]*:") { in_obj = 1; next }
		in_obj && $0 ~ ("^[ \t]*\"" field "\"[ \t]*:") {
			line = $0
			sub(/^[^:]*:[ \t]*/, "", line)
			sub(/[ \t]*,?[ \t]*$/, "", line)
			print line
			exit
		}' "$1"
}

write_result() {
	_ts=$(now_ts)
	_host=$(uname -n 2>/dev/null) || _host=unknown
	_krel=$(uname -r 2>/dev/null) || _krel=unknown
	_tmp=$OUT.tmp

	{
		printf '{\n'
		printf '  "schema": "eip93-ipsec-smoke/v1",\n'
		printf '  "timestamp": "%s",\n' "$(json_escape "$_ts")"
		if [ "$RESULT" = pass ]; then
			printf '  "ok": true,\n'
		else
			printf '  "ok": false,\n'
		fi
		if [ -n "$ERROR" ]; then
			printf '  "error": "%s",\n' "$(json_escape "$ERROR")"
		else
			printf '  "error": null,\n'
		fi
		printf '  "host": {"hostname": "%s", "kernel": "%s"},\n' \
			"$(json_escape "$_host")" "$(json_escape "$_krel")"
		printf '  "config": {\n'
		printf '    "local": "%s",\n' "$(json_escape "$LOCAL")"
		printf '    "peer": "%s",\n' "$(json_escape "$PEER")"
		printf '    "peer_ssh": "%s",\n' "$(json_escape "$PEER_SSH")"
		printf '    "transport": "tcp",\n'
		printf '    "duration_s": %s,\n' "$(json_num "$DURATION")"
		printf '    "iperf3_port": %s,\n' "$(json_num "$PORT")"
		if [ "$KEEP" = 1 ]; then
			printf '    "keep": true\n'
		else
			printf '    "keep": false\n'
		fi
		printf '  },\n'
		printf '  "esp": {\n'
		printf '    "proto": "esp",\n'
		printf '    "mode": "transport",\n'
		printf '    "cipher": "%s",\n' "$(json_escape "$CIPHER")"
		printf '    "auth": "%s",\n' "$(json_escape "$AUTH")"
		printf '    "reqid": %s,\n' "$(json_num "$REQID_DEC")"
		printf '    "spi_out": "%s",\n' "$(json_escape "$SPI_OUT")"
		printf '    "spi_in": "%s",\n' "$(json_escape "$SPI_IN")"
		printf '    "enc_key_bits": %s,\n' "$(json_num "$ENC_KEY_BITS")"
		printf '    "auth_key_bits": %s,\n' "$(json_num "$AUTH_KEY_BITS")"
		printf '    "packets_out": %s,\n' "$(json_num "$ESP_OUT_PACKETS")"
		printf '    "bytes_out": %s,\n' "$(json_num "$ESP_OUT_BYTES")"
		printf '    "packets_in": %s,\n' "$(json_num "$ESP_IN_PACKETS")"
		printf '    "bytes_in": %s,\n' "$(json_num "$ESP_IN_BYTES")"
		printf '    "policy_out": "%s/32 -> %s/32 proto tcp dport %s",\n' \
			"$(json_escape "$LOCAL")" "$(json_escape "$PEER")" "$PORT"
		printf '    "policy_in": "%s/32 -> %s/32 proto tcp sport %s"\n' \
			"$(json_escape "$PEER")" "$(json_escape "$LOCAL")" "$PORT"
		printf '  },\n'
		printf '  "eip93": {\n'
		printf '    "module": "%s",\n' "$MODULE"
		printf '    "refcnt_path": "%s",\n' "$MODPATH"
		printf '    "local": {"before_setup": %s, "after_setup": %s, "after_run": %s},\n' \
			"$(json_num "$LOCAL_RC_BEFORE")" "$(json_num "$LOCAL_RC_AFTER_SETUP")" \
			"$(json_num "$LOCAL_RC_AFTER_RUN")"
		printf '    "peer": {"before_setup": %s, "after_setup": %s, "after_run": %s},\n' \
			"$(json_num "$PEER_RC_BEFORE")" "$(json_num "$PEER_RC_AFTER_SETUP")" \
			"$(json_num "$PEER_RC_AFTER_RUN")"
		printf '    "proc_crypto": {"alg": "authenc(%s,%s)", "selected_driver": ' \
			"$(json_escape "$AUTH")" "$(json_escape "$CIPHER")"
		if [ -n "$SEL_DRIVER" ]; then
			printf '"%s", "priority": %s}\n' "$(json_escape "$SEL_DRIVER")" "$(json_num "$SEL_PRIO")"
		else
			printf 'null, "priority": null}\n'
		fi
		printf '  },\n'
		printf '  "throughput": {\n'
		printf '    "tool": "iperf3",\n'
		printf '    "direction": "local-to-peer",\n'
		printf '    "bits_per_second": %s,\n' "$(json_num "$BPS")"
		printf '    "gbps": %s,\n' "$(json_num "$GBPS")"
		printf '    "bytes": %s,\n' "$(json_num "$IPERF_BYTES")"
		printf '    "seconds": %s,\n' "$(json_num "$IPERF_SECONDS")"
		printf '    "retransmits": %s\n' "$(json_num "$IPERF_RETRANSMITS")"
		printf '  },\n'
		printf '  "files": {"raw_log": "%s", "iperf3_json": "%s"}\n' \
			"$(json_escape "$RAW_LOG")" "$(json_escape "$IPERF_JSON")"
		printf '}\n'
	} >"$_tmp" || {
		printf '%s: error: cannot write %s\n' "$PROG" "$_tmp" >&2
		return 1
	}

	if command -v jq >/dev/null 2>&1; then
		if ! jq -e . "$_tmp" >/dev/null 2>&1; then
			printf '%s: error: generated %s is not valid JSON\n' "$PROG" "$_tmp" >&2
			return 1
		fi
	fi
	mv "$_tmp" "$OUT" || {
		printf '%s: error: cannot move result.json into place at %s\n' "$PROG" "$OUT" >&2
		return 1
	}
	return 0
}

fail_run() {
	ERROR=$1
	RESULT=fail
	log_note "FAIL: $1"
	printf '%s: error: %s\n' "$PROG" "$1" >&2
	write_result || true
	exit 1
}

print_summary() {
	printf '\n%s: PASS\n' "$PROG"
	printf '  ESP: transport esp %s + %s, reqid %s, spi %s / %s\n' \
		"$CIPHER" "$AUTH" "$REQID_DEC" "$SPI_OUT" "$SPI_IN"
	printf '  eip93 refcnt local: %s -> %s (after SAs), %s (after run)\n' \
		"$LOCAL_RC_BEFORE" "$LOCAL_RC_AFTER_SETUP" "$LOCAL_RC_AFTER_RUN"
	printf '  eip93 refcnt peer:  %s -> %s (after SAs), %s (after run)\n' \
		"$PEER_RC_BEFORE" "$PEER_RC_AFTER_SETUP" "$PEER_RC_AFTER_RUN"
	printf '  ESP packets: %s out (%s bytes), %s in (%s bytes)\n' \
		"$ESP_OUT_PACKETS" "$ESP_OUT_BYTES" "$ESP_IN_PACKETS" "$ESP_IN_BYTES"
	printf '  driver: %s (priority %s)\n' "$SEL_DRIVER" "$SEL_PRIO"
	printf '  throughput: %s Gbit/s (%s bit/s, iperf3 local -> peer)\n' \
		"$GBPS" "$BPS"
	printf '  result: %s\n' "$OUT"
}

# Print the planned protocol without contacting either end.  Unexecuted
# commands are printed by xfrm_*()/run_cmd() because DRY_RUN is 1.
dry_run_plan() {
	printf '%s: dry run; nothing will be created, changed or contacted\n' "$PROG"
	printf '  LOCAL=%s PEER=%s PEER_SSH=%s\n' "$LOCAL" "$PEER" "$PEER_SSH"
	printf '  ESP: transport esp %s + %s, reqid %s, spi %s / %s\n' \
		"$CIPHER" "$AUTH" "$REQID" "$SPI_OUT" "$SPI_IN"
	printf '  keys: random %s/%s bit keys per direction, generated at run time\n' \
		"$ENC_KEY_BITS" "$AUTH_KEY_BITS"
	printf '  result: %s\n' "$OUT"
	printf '\nreal-run preconditions (not checked by --dry-run):\n'
	printf '  id -u                     # must be 0\n'
	printf '  ip xfrm state list        # ip-full, not ip-tiny\n'
	printf '  iperf3 --version          # must be iperf 3.x\n'
	printf '  %s   # local module refcnt\n' "$MODPATH"
	printf '  %s   # must list the eip93 authenc(%s,%s) driver\n' \
		"$PROC_CRYPTO" "$AUTH" "$CIPHER"
	printf '  ssh %s true          # key-based, BatchMode\n' "$PEER_SSH"
	printf '  ssh %s "cat %s"\n' "$PEER_SSH" "$MODPATH"
	printf '\ncommands, in order:\n'
	xfrm_setup
	printf '  [local] cat %s\n' "$MODPATH"
	printf '  [peer] cat %s\n' "$MODPATH"
	printf '  [peer] iperf3 -s -1 -p %s   (background over ssh)\n' "$PORT"
	printf '  [local] iperf3 -c %s -p %s -t %s -4 -J\n' \
		"$PEER" "$PORT" "$DURATION"
	if [ "$KEEP" = 1 ]; then
		printf '\ncleanup: --keep, the SAs and policies stay installed\n'
	else
		printf '\ncleanup, in order:\n'
		xfrm_teardown
	fi
}

# ---------------------------------------------------------------------
# arguments

while [ "$#" -gt 0 ]; do
	case $1 in
	-h|--help)
		usage
		exit 0
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--keep)
		KEEP=1
		shift
		;;
	--local)
		[ "$#" -ge 2 ] || usage_error "--local requires a value"
		LOCAL=$2
		shift 2
		;;
	--local=*)
		LOCAL=${1#--local=}
		shift
		;;
	--peer)
		[ "$#" -ge 2 ] || usage_error "--peer requires a value"
		PEER=$2
		shift 2
		;;
	--peer=*)
		PEER=${1#--peer=}
		shift
		;;
	--peer-ssh)
		[ "$#" -ge 2 ] || usage_error "--peer-ssh requires a value"
		PEER_SSH=$2
		shift 2
		;;
	--peer-ssh=*)
		PEER_SSH=${1#--peer-ssh=}
		shift
		;;
	--duration)
		[ "$#" -ge 2 ] || usage_error "--duration requires a value"
		DURATION=$2
		shift 2
		;;
	--duration=*)
		DURATION=${1#--duration=}
		shift
		;;
	--port)
		[ "$#" -ge 2 ] || usage_error "--port requires a value"
		PORT=$2
		shift 2
		;;
	--port=*)
		PORT=${1#--port=}
		shift
		;;
	--cipher)
		[ "$#" -ge 2 ] || usage_error "--cipher requires a value"
		CIPHER=$2
		shift 2
		;;
	--cipher=*)
		CIPHER=${1#--cipher=}
		shift
		;;
	--auth)
		[ "$#" -ge 2 ] || usage_error "--auth requires a value"
		AUTH=$2
		shift 2
		;;
	--auth=*)
		AUTH=${1#--auth=}
		shift
		;;
	--reqid)
		[ "$#" -ge 2 ] || usage_error "--reqid requires a value"
		REQID=$2
		shift 2
		;;
	--reqid=*)
		REQID=${1#--reqid=}
		shift
		;;
	--spi-out)
		[ "$#" -ge 2 ] || usage_error "--spi-out requires a value"
		SPI_OUT=$2
		shift 2
		;;
	--spi-out=*)
		SPI_OUT=${1#--spi-out=}
		shift
		;;
	--spi-in)
		[ "$#" -ge 2 ] || usage_error "--spi-in requires a value"
		SPI_IN=$2
		shift 2
		;;
	--spi-in=*)
		SPI_IN=${1#--spi-in=}
		shift
		;;
	--out)
		[ "$#" -ge 2 ] || usage_error "--out requires a value"
		OUT=$2
		shift 2
		;;
	--out=*)
		OUT=${1#--out=}
		shift
		;;
	-*)
		usage_error "unknown option: $1"
		;;
	*)
		usage_error "unexpected argument: $1"
		;;
	esac
done

# Reject GCM/ChaCha (and any other AEAD) before doing anything else: the
# EIP93 hardware cannot offload them, so a test that accepted them would
# silently measure the software implementation.
case $CIPHER in
'cbc(aes)'|'cbc(des)'|'cbc(des3_ede)') ;;
*gcm*|*GCM*|*ccm*|*CCM*|*chacha*|*ChaCha*|*CHACHA*|*rfc4106*|*rfc4543*)
	usage_error "EIP93 has no GCM/CCM or ChaCha20-Poly1305 offload (hardware limitation); classic ESP only: cbc(aes), cbc(des), cbc(des3_ede)" ;;
*)
	usage_error "unsupported ESP cipher '$CIPHER'; EIP93 classic ESP supports cbc(aes), cbc(des), cbc(des3_ede)" ;;
esac
case $AUTH in
'hmac(sha1)'|'hmac(sha256)'|'hmac(md5)') ;;
*gcm*|*GCM*|*chacha*|*ChaCha*|*CHACHA*)
	usage_error "EIP93 has no GCM/ChaCha offload (hardware limitation); use classic ESP auth hmac(sha1), hmac(sha256) or hmac(md5)" ;;
*)
	usage_error "unsupported ESP auth '$AUTH'; EIP93 classic ESP supports hmac(sha1), hmac(sha256), hmac(md5)" ;;
esac

case $DURATION in
''|*[!0-9]*) usage_error "duration must be a positive integer, got '$DURATION'" ;;
esac
[ "$DURATION" -ge 1 ] || usage_error "duration must be greater than zero"
case $PORT in
''|*[!0-9]*) usage_error "port must be an integer, got '$PORT'" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] ||
	usage_error "port must be between 1 and 65535, got '$PORT'"

case $REQID in
0x*|0X*)
	_reqid_hex=${REQID#0[xX]}
	case $_reqid_hex in
	''|*[!0-9a-fA-F]*) usage_error "reqid must be a decimal or 0x hex integer, got '$REQID'" ;;
	esac
	[ ${#_reqid_hex} -le 8 ] || usage_error "reqid does not fit in 32 bits"
	REQID_DEC=$((0x$_reqid_hex))
	;;
*)
	case $REQID in
	''|*[!0-9]*) usage_error "reqid must be a decimal or 0x hex integer, got '$REQID'" ;;
	esac
	REQID_DEC=$(printf '%s\n' "$REQID" | awk '{ printf "%d", $1 + 0 }')
	[ "$REQID_DEC" -le 4294967295 ] || usage_error "reqid does not fit in 32 bits"
	;;
esac

normalize_spi() {
	_spi=$1
	case $_spi in
	0x*|0X*) _spi=${_spi#0[xX]} ;;
	*) return 1 ;;
	esac
	case $_spi in
	''|*[!0-9a-fA-F]*) return 1 ;;
	esac
	[ ${#_spi} -le 8 ] || return 1
	printf '0x%s' "$(printf '%s' "$_spi" | tr 'A-F' 'a-f')"
}

_spi_norm=$(normalize_spi "$SPI_OUT") ||
	usage_error "SPI_OUT must be a 0x-prefixed hex SPI up to 32 bits, got '$SPI_OUT'"
SPI_OUT=$_spi_norm
_spi_norm=$(normalize_spi "$SPI_IN") ||
	usage_error "SPI_IN must be a 0x-prefixed hex SPI up to 32 bits, got '$SPI_IN'"
SPI_IN=$_spi_norm
[ "$SPI_OUT" != "$SPI_IN" ] || usage_error "SPI_OUT and SPI_IN must differ"

# Validate anything the caller supplied even for --dry-run; only the
# required-value check below is skipped there.
if [ -n "$LOCAL" ]; then
	valid_ipv4 "$LOCAL" || usage_error "LOCAL is not an IPv4 address: '$LOCAL'"
fi
if [ -n "$PEER" ]; then
	valid_ipv4 "$PEER" || usage_error "PEER is not an IPv4 address: '$PEER'"
fi
if [ -n "$LOCAL" ] && [ -n "$PEER" ] && [ "$LOCAL" = "$PEER" ]; then
	usage_error "LOCAL and PEER must differ"
fi

# Key sizes follow the selected classic algorithm; --dry-run needs the
# numbers only for display.
case $CIPHER in
'cbc(aes)') _enc_bytes=16 ;;
'cbc(des3_ede)') _enc_bytes=24 ;;
'cbc(des)') _enc_bytes=8 ;;
esac
case $AUTH in
'hmac(sha1)') _auth_bytes=20 ;;
'hmac(sha256)') _auth_bytes=32 ;;
'hmac(md5)') _auth_bytes=16 ;;
esac
ENC_KEY_BITS=$((_enc_bytes * 8))
AUTH_KEY_BITS=$((_auth_bytes * 8))

if [ "$DRY_RUN" = 1 ]; then
	LOCAL=${LOCAL:-<local-ipv4>}
	PEER=${PEER:-<peer-ipv4>}
	PEER_SSH=${PEER_SSH:-<peer-ssh>}
	OUT=${OUT:-./eip93-ipsec-smoke-<epoch>.json}
	dry_run_plan
	exit 0
fi

# ---------------------------------------------------------------------
# real run

[ -n "$LOCAL" ] || usage_error "LOCAL is required (local IPv4 test address)"
[ -n "$PEER" ] || usage_error "PEER is required (peer IPv4 test address)"
[ -n "$PEER_SSH" ] || usage_error "PEER_SSH is required (ssh target of the peer)"
valid_ipv4 "$LOCAL" || usage_error "LOCAL is not an IPv4 address: '$LOCAL'"
valid_ipv4 "$PEER" || usage_error "PEER is not an IPv4 address: '$PEER'"

if [ -z "$OUT" ]; then
	OUT=./eip93-ipsec-smoke-$(date +%s).json
fi
if [ -e "$OUT" ]; then
	die "refusing to overwrite $OUT (pick another --out)"
fi
_outdir=$(dirname "$OUT")
mkdir -p "$_outdir" || die "cannot create output directory $_outdir"
RAW_LOG=$OUT.log
IPERF_JSON=$OUT.iperf3.json
: >"$RAW_LOG" || die "cannot write $RAW_LOG"

trap cleanup EXIT
trap 'exit 1' INT TERM

log_note "start $PROG"
log_note "local=$LOCAL peer=$PEER peer_ssh=$PEER_SSH duration=$DURATION port=$PORT"
log_note "esp transport cipher=$CIPHER auth=$AUTH reqid=$REQID_DEC"
log_note "keys: $ENC_KEY_BITS-bit enc, $AUTH_KEY_BITS-bit auth (not logged)"

[ "$(id -u 2>/dev/null)" = 0 ] ||
	fail_run "must run as root on the local end to install xfrm state"

command -v ip >/dev/null 2>&1 || fail_run "'ip' not found in PATH"
if ! ip xfrm state list >/dev/null 2>&1; then
	if ip xfrm help >/dev/null 2>&1; then
		fail_run "the kernel has no XFRM support; install kmod-ipsec4 (or kmod-ipsec4 is not loaded)"
	fi
	fail_run "'ip' does not support xfrm; this script needs ip-full, not ip-tiny"
fi
command -v iperf3 >/dev/null 2>&1 || fail_run "iperf3 not found on the local end"
_iperf_ver=$(iperf3 --version 2>/dev/null | head -n 1)
case $_iperf_ver in
iperf\ 3*) ;;
*) fail_run "iperf3 3.x is required on the local end, found '$_iperf_ver'" ;;
esac
command -v ssh >/dev/null 2>&1 || fail_run "ssh not found on the local end"
command -v hexdump >/dev/null 2>&1 || fail_run "hexdump not found on the local end"

# Key material is generated per run (after confirming hexdump exists) and never
# shown or logged: it only protects the lab link for the measurement duration.
ENC_KEY_OUT=$(gen_hex "$_enc_bytes")
AUTH_KEY_OUT=$(gen_hex "$_auth_bytes")
ENC_KEY_IN=$(gen_hex "$_enc_bytes")
AUTH_KEY_IN=$(gen_hex "$_auth_bytes")
valid_hex "$ENC_KEY_OUT" || fail_run "could not generate a random ESP key (is /dev/urandom readable?)"
valid_hex "$AUTH_KEY_OUT" || fail_run "could not generate a random ESP auth key (is /dev/urandom readable?)"
valid_hex "$ENC_KEY_IN" || fail_run "could not generate a random ESP key (is /dev/urandom readable?)"
valid_hex "$AUTH_KEY_IN" || fail_run "could not generate a random ESP auth key (is /dev/urandom readable?)"
ENC_KEY_BITS=$((${#ENC_KEY_OUT} * 4))
AUTH_KEY_BITS=$((${#AUTH_KEY_OUT} * 4))

# The module autoloads at boot on OpenWrt; try it once in case only the
# package was installed without a reboot.
if [ ! -e "$MODPATH" ]; then
	log_note "modprobe crypto-hw-eip93"
	modprobe crypto-hw-eip93 2>/dev/null || true
fi
[ -e "$MODPATH" ] ||
	fail_run "kmod-crypto-hw-eip93 is not loaded on the local end (no $MODPATH); install the module and reboot, or modprobe crypto-hw-eip93"

LOCAL_RC_BEFORE=$(local_refcnt) ||
	fail_run "cannot read $MODPATH on the local end"

# Verify that the ESP transform will actually pick the hardware driver
# before installing any SA.  This is the "esp4 ... priority1500" check:
# /proc/crypto lists the eip93 authenc implementation at priority 1500.
if [ -r "$PROC_CRYPTO" ]; then
	_sel=$(proc_crypto_selected) || _sel=
	if [ -z "$_sel" ]; then
		fail_run "$PROC_CRYPTO has no authenc($AUTH,$CIPHER) implementation; the EIP93 driver did not register it (check dmesg for eip93 probe errors)"
	fi
	SEL_DRIVER=$(printf '%s' "$_sel" | cut -f 1)
	SEL_PRIO=$(printf '%s' "$_sel" | cut -f 2)
	case $SEL_DRIVER in
	*eip93*) ;;
	*) fail_run "$PROC_CRYPTO selected '$SEL_DRIVER' (priority $SEL_PRIO) for authenc($AUTH,$CIPHER), not an eip93 driver; the ESP transform would run in software" ;;
	esac
	log_note "proc_crypto selected driver=$SEL_DRIVER priority=$SEL_PRIO"
else
	log_note "warning: $PROC_CRYPTO is not readable; relying on the refcount check only"
fi

log_note "checking peer $PEER_SSH over ssh"
ssh_peer true ||
	fail_run "cannot run a command on peer $PEER_SSH over ssh (key-based login, BatchMode=yes)"
if [ -z "$(ssh_peer "head -n 1 $MODPATH" 2>/dev/null)" ]; then
	log_note "peer modprobe crypto-hw-eip93"
	ssh_peer "modprobe crypto-hw-eip93" >/dev/null 2>&1 || true
fi
PEER_RC_BEFORE=$(peer_refcnt) ||
	fail_run "cannot read $MODPATH on peer $PEER_SSH; install and load kmod-crypto-hw-eip93 on the peer"
_peer_iperf_ver=$(ssh_peer "iperf3 --version" 2>/dev/null | head -n 1)
case $_peer_iperf_ver in
iperf\ 3*) ;;
*) fail_run "iperf3 3.x is required on peer $PEER_SSH, found '$_peer_iperf_ver'" ;;
esac
log_note "peer eip93 refcnt before setup: $PEER_RC_BEFORE"

log_note "installing xfrm state and policies"
XFRM_TOUCHED=1
xfrm_setup || fail_run "failed to install the ESP SAs/policies; see $RAW_LOG and 'ip xfrm state list' on both ends"
XFRM_SETUP_DONE=1

LOCAL_RC_AFTER_SETUP=$(local_refcnt) ||
	fail_run "cannot read $MODPATH on the local end after installing the SAs"
PEER_RC_AFTER_SETUP=$(peer_refcnt) ||
	fail_run "cannot read $MODPATH on peer $PEER_SSH after installing the SAs"
log_note "local eip93 refcnt after setup: $LOCAL_RC_AFTER_SETUP"
log_note "peer eip93 refcnt after setup: $PEER_RC_AFTER_SETUP"

if [ "$LOCAL_RC_AFTER_SETUP" -le "$LOCAL_RC_BEFORE" ]; then
	fail_run "local eip93 refcount did not increase when the ESP SAs were installed ($LOCAL_RC_BEFORE -> $LOCAL_RC_AFTER_SETUP); the ESP transform did not use crypto_hw_eip93"
fi
if [ "$PEER_RC_AFTER_SETUP" -le "$PEER_RC_BEFORE" ]; then
	fail_run "peer eip93 refcount did not increase when the ESP SAs were installed ($PEER_RC_BEFORE -> $PEER_RC_AFTER_SETUP); the peer ESP transform did not use crypto_hw_eip93"
fi

printf 'starting one-shot iperf3 server on %s...\n' "$PEER_SSH"
log_cmd "[peer] iperf3 -s -1 -p $PORT (background)"
ssh -n -T -o BatchMode=yes -o ConnectTimeout=5 "$PEER_SSH" \
	"iperf3 -s -1 -p $PORT" >>"$RAW_LOG" 2>&1 &
IPERF_SSH_PID=$!
sleep 1

_attempt=1
while :; do
	log_cmd "[local] iperf3 -c $PEER -p $PORT -t $DURATION -4 -J"
	if iperf3 -c "$PEER" -p "$PORT" -t "$DURATION" -4 -J \
		>"$IPERF_JSON" 2>"$IPERF_JSON.err"; then
		break
	fi
	if [ "$_attempt" -lt 3 ] && grep -qi 'connection refused' "$IPERF_JSON.err" 2>/dev/null; then
		log_note "iperf3 connection refused, retrying (attempt $_attempt)"
		_attempt=$((_attempt + 1))
		sleep 1
		continue
	fi
	_iperf_err=$(tail -n 3 "$IPERF_JSON.err" 2>/dev/null | tr '\n' ' ')
	fail_run "iperf3 failed after ${_attempt} attempt(s): ${_iperf_err:-no error output}; raw iperf3 JSON/err is in ${IPERF_JSON} and the command log in ${RAW_LOG}"
done

kill "$IPERF_SSH_PID" 2>/dev/null || true
wait "$IPERF_SSH_PID" 2>/dev/null || true
IPERF_SSH_PID=

BPS=$(iperf_field "$IPERF_JSON" sum_sent bits_per_second)
IPERF_BYTES=$(iperf_field "$IPERF_JSON" sum_sent bytes)
IPERF_SECONDS=$(iperf_field "$IPERF_JSON" sum_sent seconds)
IPERF_RETRANSMITS=$(iperf_field "$IPERF_JSON" sum_sent retransmits)
[ -n "$BPS" ] ||
	fail_run "could not parse bits_per_second from ${IPERF_JSON}; the iperf3 JSON format is unexpected"
awk -v b="$BPS" 'BEGIN { exit !(b > 0) }' ||
	fail_run "iperf3 reported a non-positive bitrate (${BPS} bit/s)"
GBPS=$(awk -v b="$BPS" 'BEGIN { printf "%.3f", b / 1000000000.0 }')
log_note "throughput: ${BPS} bit/s (${GBPS} Gbit/s)"

LOCAL_RC_AFTER_RUN=$(local_refcnt) ||
	fail_run "cannot read $MODPATH on the local end after the run"
PEER_RC_AFTER_RUN=$(peer_refcnt) ||
	fail_run "cannot read $MODPATH on peer $PEER_SSH after the run"
log_note "local eip93 refcnt after run: $LOCAL_RC_AFTER_RUN"
log_note "peer eip93 refcnt after run: $PEER_RC_AFTER_RUN"

# The module refcount can only fall like this when the transform was released
# while the test ran; an equal or higher count keeps the "still allocated"
# evidence meaningful.
if [ "$LOCAL_RC_AFTER_RUN" -lt "$LOCAL_RC_AFTER_SETUP" ]; then
	fail_run "local eip93 refcount fell after the run ($LOCAL_RC_AFTER_SETUP -> $LOCAL_RC_AFTER_RUN); the ESP transform did not stay allocated for the whole flow"
fi
if [ "$PEER_RC_AFTER_RUN" -lt "$PEER_RC_AFTER_SETUP" ]; then
	fail_run "peer eip93 refcount fell after the run ($PEER_RC_AFTER_SETUP -> $PEER_RC_AFTER_RUN); the peer ESP transform did not stay allocated for the whole flow"
fi

# A high refcount only says the SAs exist.  The counters say the iperf3 flow
# actually went through them.
_state=$(esp_state) || _state=
ESP_OUT_COUNTERS=$(esp_parse "$_state" "$SPI_OUT") || ESP_OUT_COUNTERS=
ESP_IN_COUNTERS=$(esp_parse "$_state" "$SPI_IN") || ESP_IN_COUNTERS=
ESP_OUT_PACKETS=${ESP_OUT_COUNTERS% *}
ESP_OUT_BYTES=${ESP_OUT_COUNTERS#* }
ESP_IN_PACKETS=${ESP_IN_COUNTERS% *}
ESP_IN_BYTES=${ESP_IN_COUNTERS#* }
log_note "esp spi $SPI_OUT packets=$ESP_OUT_PACKETS bytes=$ESP_OUT_BYTES"
log_note "esp spi $SPI_IN packets=$ESP_IN_PACKETS bytes=$ESP_IN_BYTES"

case $ESP_OUT_PACKETS in
''|*[!0-9]*)
	fail_run "cannot read the ESP packet counter for spi $SPI_OUT from 'ip -s xfrm state list'; the SA is gone or 'ip' printed an unexpected format"
	;;
esac
case $ESP_IN_PACKETS in
''|*[!0-9]*)
	fail_run "cannot read the ESP packet counter for spi $SPI_IN from 'ip -s xfrm state list'; the SA is gone or 'ip' printed an unexpected format"
	;;
esac
if [ "$ESP_OUT_PACKETS" -eq 0 ]; then
	fail_run "no ESP packet on SPI $SPI_OUT; the iperf3 flow bypassed the IPsec policy (cleartext). Check the selector, the policy priority against any NAT/firewall rule, and that iperf3 connected to $PEER directly"
fi
if [ "$ESP_IN_PACKETS" -eq 0 ]; then
	fail_run "no ESP packet on SPI $SPI_IN; the peer sent nothing back through the policy (cleartext). Check the peer-side policy and that the peer's iperf3 server ran"
fi

RESULT=pass
ERROR=
write_result || fail_run "could not write $OUT"
print_summary
exit 0
