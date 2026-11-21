#!/usr/bin/env bash
# recovb12 — RAM-only load of the recovery ITB into XR1710G RAM + bootm.
# Zero flash writes: no saveenv, no ubi write, no nand erase. `reset` at the end only.
# Unarmed = static gates only (never opens $DEV).
# Armed   = full run; aborts call `reset` to return to stock firmware.
#
# ---- why this script does NOT use kermit/loadb (measured 2026-11-21) ----------------
# The board's own U-Boot (U-Boot 2014.04-rc1 AXON 1.6, prompt `ECNT>`) has all three
# loaders: `loadb` (kermit), `loadx` (xmodem), `loady` (ymodem). `loadb` was tried and
# is dead *on the host side*: C-Kermit 10.0.416 first writes the literal text
# `kermit -ir\r` to the wire (debug.log: `HEXDUMP: ttol s (11 bytes) = 6b 65 72 6d 69
# 74 20 2d 69 72 0d`), the board eats it as a command, then kermit loops on
# `input send resending winlo=2` and exits rc=2 with 0 bytes delivered. The board never
# refused anything. So the transfer channel is `loady` on the board + `sb` on the host.
#
# ---- two traps that already cost a 12-minute run ------------------------------------
# 1. `sb` talks to the modem on BOTH stdin and stdout. Redirecting stdout to a log file
#    sends the protocol frames into the log and the board sees nothing but NAKs. stdout
#    MUST be the tty itself:   sb -b <itb> < "$DEV" > "$DEV" 2>"$OUT/sb.err"
#    Note: lrzsz 0.12.21rc has no `--ymodem` flag — `sb` ("send batch") already IS the
#    YMODEM sender, `-b/--binary` is the only switch needed. `sb --help` line: "-b, --binary
#    binary transfer"; the word "ymodem" appears only in `-4/-8` block-size notes.
# 2. Under WSL memory pressure the usbip bulk-IN pipe dies mid-transfer
#    (`vhci_hcd: urb->status -104` floods, `page allocation failure: order:7`), and the
#    host only notices ~12 minutes later via `Retry Count Exceeded`. Hence the watchdog
#    below: sample that counter every 30 s and abort the transfer on the first increment.
#
# ---- YMODEM budget (measured, not guessed) ------------------------------------------
# 128-byte blocks, 66.9 blocks/s = 8.56 kB/s. 14417920 B / 8563 B/s = 1684 s = 28.1 min.
# `sb -k` does NOT help: lrzsz documents -k as XMODEM-only "(X)", so YMODEM stays at 128 B
# blocks. Add ~8 min for iminfo/bootm/probes/reset => ask for a 40-minute window.
set -uo pipefail

DEV=${DEV:-/dev/ttyUSB0}
ITB=${ITB:-/home/l1n/projects/xr1710g-openwrt/bin/targets/airoha/an7581/openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb}
SIZE=14417920
SHA=1847baefbe5bf6e647e7c8a9c0bc68c2a0f316520ee823b6fde96956fbc372ca
OUT=${OUT:-/home/l1n/projects/.scratch/recovb12}
ADDR=${ADDR:-0x85000000}          # free System RAM 0x84a00000-0x86feffff, ends 0x85dc0000
CONF=${CONF:-config-1}
GATEWAY=${GATEWAY:-192.168.1.1}
# production bootargs verbatim from target/linux/airoha/dts/an7581-xr1710g-ubi.dts:26, NO rdinit:
# the ITB's own /init exports INITRAMFS=1 and switch_roots to tmpfs; rdinit=/sbin/init would skip it.
BOOTARGS=${BOOTARGS:-"console=ttyS0,115200 earlycon ubi.block=0,fit root=/dev/fit0 rootwait"}
REV_EXPECT=${REV_EXPECT:-r38203-a0078bf520}
KREL_EXPECT=${KREL_EXPECT:-7.4-rc3}
XFER_TIMEOUT=${XFER_TIMEOUT:-2100}   # 35 min hard cap, > the 28.1 min measured need
LOG=$OUT/recovery-boot.log
PIDF=$OUT/.cap.pid
DMESG="sudo -n dmesg"

say(){ echo "$*" | tee -a "$LOG" >&2; }
# NOTE: `pkill -f "dd if=$DEV"` is a self-kill trap — this script's own command line contains
# that string, so pkill would SIGTERM the script itself. Kill the process *group* instead
# (setsid gives timeout+dd a private pgid == its pid).
capstop(){ [ -f "$PIDF" ] && kill -- -"$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; }
cap(){ setsid timeout "$1" dd if="$DEV" of="$LOG" bs=1 conv=notrunc oflag=append status=none >/dev/null 2>&1 & echo $! >"$PIDF"; sleep 0.3; }
send(){ printf '%s\r' "$1" >"$DEV"; }
waitfor(){ local i=0; while [ $i -lt "$2" ]; do grep -q "$1" "$LOG" 2>/dev/null && return 0; sleep 1; i=$((i+1)); done; return 1; }
sshq(){ ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "root@$GATEWAY" "$@" 2>/dev/null; }
wait_ssh(){ local i=0; while [ $i -lt "$1" ]; do sshq true && return 0; sleep 3; i=$((i+3)); done; return 1; }
urb104(){ $DMESG 2>/dev/null | grep -c 'urb->status -104'; }

# abort AFTER we have touched the board: always try to leave it in stock firmware
bail(){ say "ABORT: $*"; say "--- reset to stock firmware ---"; cap 30; send "reset"; sleep 20; capstop; wait_ssh 180 && say "stock firmware back: $(sshq 'grep -h DISTRIB_REVISION /etc/openwrt_release; uname -r' | tr '\n' ' ')" || say "stock SSH not back yet — inspect $LOG"; exit 1; }

# ---------- static gates (never open $DEV) ----------
[ -c "$DEV" ] || { echo "ABORT gate1: $DEV missing" >&2; exit 1; }
if command -v fuser >/dev/null && fuser "$DEV" >/dev/null 2>&1; then echo "ABORT gate1b: $DEV held: $(fuser -v "$DEV" 2>&1)" >&2; exit 1; fi
[ "$(stat -c%s "$ITB")" = "$SIZE" ] || { echo "ABORT gate2: itb size != $SIZE" >&2; exit 1; }
[ "$(sha256sum "$ITB" | cut -d' ' -f1)" = "$SHA" ] || { echo "ABORT gate2b: itb sha256 mismatch" >&2; exit 1; }
command -v sb >/dev/null || { echo "ABORT gate3: lrzsz 'sb' not installed (apt-get install -y lrzsz)" >&2; exit 1; }

if [ "${1:-}" != "--arm" ]; then
  echo "STATIC GATES PASSED: $DEV free, itb $SIZE B, sha256 $SHA, sb present."
  echo "armed run: $0 --arm   # only after Lead says the serial is released"
  exit 0
fi

mkdir -p "$OUT"; : >"$LOG"

# ---------- P: link health, 4 gates, all before the board is touched ----------
# (a 43%-of-the-way transfer was already wasted once because none of this was checked)
say "=== $(date -Is) armed; itb=$ITB addr=$ADDR log=$LOG"
grep -q 'vhci_hcd' /proc/modules || { say "ABORT gateH3: vhci_hcd not loaded (usbip link gone)"; exit 1; }
say "[H3] vhci_hcd loaded"
stty -F "$DEV" 115200 cs8 -cstopb -parenb raw -echo || { say "ABORT gateH2: stty on $DEV failed"; exit 1; }
say "[H2] stty 115200 8N1 raw ok"
: >"$OUT/echo-probe.bin"
printf '\r' >"$DEV"
timeout 3 dd if="$DEV" of="$OUT/echo-probe.bin" bs=1 count=64 status=none 2>/dev/null
probe=$(stat -c%s "$OUT/echo-probe.bin")
[ "${probe:-0}" -ge 1 ] || { say "ABORT gateH4: console silent — wrote CR, read back 0 bytes (usbip bulk-IN dead)"; exit 1; }
say "[H4] echo probe ok ($probe bytes back)"
say "[H1] device node present, 4/4 health gates passed"

# ---------- A: prompt ----------
cap 8; send ""; sleep 2; capstop
grep -qE 'ECNT>|U-Boot>|XR1710G>' "$LOG" || bail "no bootloader prompt (want ECNT>) — power-cycle and interrupt autoboot"
say "[A] prompt seen: $(grep -oE 'ECNT>|U-Boot>|XR1710G>' "$LOG" | tail -1)"

# ---------- A2: which loaders exist on THIS bootloader (Lead hard requirement) ----------
cap 25; send "help"; sleep 6; capstop
say "[A2] help | grep -i load (board's own words):"
grep -iE 'load[bsxy]' "$LOG" | sed 's/^/    /' | tee -a "$LOG"
for c in loadb loadx loady; do grep -qiE "(^|[[:space:]])$c([[:space:]]|$)" "$LOG" && say "    => $c PRESENT" || say "    => $c absent"; done
grep -qiE '(^|[[:space:]])loady([[:space:]]|$)' "$LOG" || bail "board bootloader has no loady — fall back to loadx + sx (128 B blocks, slower)"

# ---------- B: bootargs + ymodem download mode ----------
send "printenv loadaddr"; sleep 1
send "printenv bootargs"; sleep 1
send "setenv bootargs $BOOTARGS"; sleep 1
send "printenv bootargs"; sleep 2
say "[B] bootargs set (RAM only, no saveenv)"
cap 20; send "loady $ADDR"
waitfor 'Ready for binary' 18 || bail "U-Boot never printed '## Ready for binary (ymodem)'"
capstop
say "[B] ymodem download mode armed at $ADDR"

# ---------- C: transfer (YMODEM) + link watchdog ----------
# stdout of sb MUST be the tty (see header trap 1). stderr carries the progress log.
base104=$(urb104)
say "=== sb start $(date -Is) (urb-104 baseline=$base104) ==="
t0=$(date +%s)
sb -b "$ITB" <"$DEV" >"$DEV" 2>"$OUT/sb.err" &
SBPID=$!
linkdead=0
while kill -0 "$SBPID" 2>/dev/null; do
  sleep 30
  kill -0 "$SBPID" 2>/dev/null || break
  now104=$(urb104)
  if [ "${now104:-0}" -gt "${base104:-0}" ]; then
    say "[C] WATCHDOG: urb->status -104 went $base104 -> $now104 (usbip bulk-IN died) — killing sb"
    kill "$SBPID" 2>/dev/null; linkdead=1; break
  fi
  if [ $(( $(date +%s) - t0 )) -gt "$XFER_TIMEOUT" ]; then
    say "[C] WATCHDOG: transfer exceeded ${XFER_TIMEOUT}s — killing sb"
    kill "$SBPID" 2>/dev/null; break
  fi
done
wait "$SBPID" 2>/dev/null; sbrc=$?
say "=== sb exit rc=$sbrc after $(( $(date +%s) - t0 ))s $(date -Is) ==="
tr '\r' '\n' <"$OUT/sb.err" 2>/dev/null | grep -vE '^(Ymodem sectors|$)' | tail -12 >>"$LOG"
tr '\r' '\n' <"$OUT/sb.err" 2>/dev/null | grep -oE 'Ymodem sectors/kbytes sent: *[0-9]+/[ 0-9]+k' | tail -1 >>"$LOG"
[ "$linkdead" = 1 ] && bail "transfer aborted by watchdog: host usbip link died mid-transfer (not a board fault)"

cap 30; waitfor 'Total Size' 25 || true; capstop
got=$(grep -oE 'Total Size  *= 0x[0-9a-fA-F]+ = [0-9]+ Bytes' "$LOG" | tail -1 | grep -oE '[0-9]+ Bytes' | grep -oE '^[0-9]+')
[ "$got" = "$SIZE" ] || bail "U-Boot reports ${got:-nothing} bytes, expected $SIZE — truncated, must not bootm"
say "[C] transfer verified: $got bytes"

# ---------- D: iminfo must validate BEFORE bootm (Lead hard requirement) ----------
cap 25; send "iminfo $ADDR"; sleep 5; capstop
grep -qiE 'FIT.*(image|description)|Configuration 0|config-1' "$LOG" || bail "iminfo did not show a FIT header at $ADDR"
grep -qiE 'config-1|conf-1' "$LOG" || bail "iminfo shows no config-1 in the FIT"
say "[D] iminfo OK (FIT + config-1)"

# ---------- E: boot ----------
cap 600
send "bootm $ADDR#$CONF"
sleep 60
if wait_ssh 240; then say "[E] recovery reachable over ssh"; else say "[E] no ssh within 300 s — recovery may be serial-only; continuing capture"; fi
capstop
tail -n 100 "$LOG" | sed 's/^/    /' | tee -a "$LOG" >/dev/null

# ---------- F: acceptance probes (issue #12 real checkpoints) ----------
if sshq true; then
  {
    echo "===== recovery probes $(date -Is) ====="
    echo "--- uname -a";            sshq 'uname -a'
    echo "--- /proc/cmdline";       sshq 'cat /proc/cmdline'
    echo "--- rootfs mount";        sshq "grep -E ' / (rootfs|tmpfs|ext4|ubifs) ' /proc/mounts; mount | head -3"
    echo "--- INITRAMFS var";       sshq 'grep -h INITRAMFS /etc/openwrt_release; cat /proc/1/cmdline | tr "\0" " "'
    echo "--- ppe debugfs entries"; sshq 'mount -t debugfs none /sys/kernel/debug 2>/dev/null; ls /sys/kernel/debug/ppe/ 2>/dev/null | wc -l'
    echo "--- UBIFS recovery hits"; sshq 'dmesg | grep -ci "UBIFS recovery"'
    echo "--- links";               sshq 'ip -br link'
  } | tee -a "$LOG"
else
  say "[F] ssh unreachable — run the four probes by hand on the serial console (see report §6.4)"
fi

# ---------- G: always return to stock firmware ----------
# "back on stock firmware" is judged by THREE things together, NOT by uname -r:
#   (a) /proc/mounts root line is no longer tmpfs/rootfs but the ubi/dev/fit0 stack
#   (b) uptime reset to a few seconds (fresh boot after `reset`)
#   (c) DISTRIB_REVISION == r38203-a0078bf520
# uname -r is useless as a discriminator: recovery ITB and stock firmware are built from
# the same tree, so both report 7.4-rc3 and both carry DISTRIB_REVISION r38203-a0078bf520.
# It is recorded only as corroboration (Lead, 2026-11-21 13:31).
# `dmesg | grep -c "UBIFS recovery"` is likewise NOT a criterion (a clean reboot also hits it).
say "[G] reset to stock firmware"
cap 30; send "reset"; sleep 20; capstop
if wait_ssh 240; then
  rev=$(sshq 'grep -h DISTRIB_REVISION /etc/openwrt_release' | tr -d "'" | awk '{print $NF}')
  krel=$(sshq 'uname -r' | tr -d '\r')
  rootline=$(sshq "awk '\$2==\"/\"{print \$1, \$3}' /proc/mounts" | tr -d '\r')
  up=$(sshq 'cut -d. -f1 /proc/uptime' | tr -d '\r')
  say "[G] root mount = ${rootline:-?} | uptime = ${up:-?}s | DISTRIB_REVISION=$rev | uname -r=$krel"
  if printf '%s' "$rootline" | grep -qiE 'tmpfs|rootfs'; then
    say "[G] FAIL(a): still on an initramfs root ($rootline) — not back on stock firmware"
  else
    say "[G] OK(a): root is the stock stack ($rootline)"
  fi
  [ "${up:-9999}" -lt 120 ] 2>/dev/null && say "[G] OK(b): uptime ${up}s => fresh boot" || say "[G] WARN(b): uptime ${up}s, expected < 120 s"
  [ "$rev" = "$REV_EXPECT" ] && say "[G] OK(c): REVISION $REV_EXPECT" || say "[G] FAIL(c): REVISION $rev != $REV_EXPECT"
  say "[G] corroboration only: uname -r=$krel (expected $KREL_EXPECT; same version in both images)"
else
  say "[G] FAIL: stock firmware SSH not back — full log: $LOG"
fi
