#!/bin/sh
# device-hw-probe.sh — XR1710G 硬件驱动深度测试（灯光 / 网口 / 网口灯光）
#
# 用法：
#   ./scripts/device-hw-probe.sh                 # 默认 4 路并行，只读为主（LED 会写并恢复）
#   TOGGLE_10G=1 ./scripts/device-hw-probe.sh     # 追加 10G 口 admin down/up 循环（注意会污染 lan1 计数器，见 FIXES HD-3）
#   DEVICE_HOST=root@192.168.123.1 ./scripts/device-hw-probe.sh
#
# 说明：
#   - 测试期间会短暂改写 LED brightness/trigger，每路结束后恢复原状。
#   - 不会 down/up wan 与 lan3（SSH 所在网段），不会破坏 WAN/PPPoE。
#   - 输出写入 /tmp/device-hw-probe-<route>.log，并打印每路尾部摘要。
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST=${DEVICE_HOST:-root@192.168.123.1}
OUT_PREFIX=${OUT_PREFIX:-/tmp/device-hw-probe}
SSH_CMD=""

if [ -x "$REPO_DIR/.ssh/ssh-device" ]; then
    SSH_CMD="$REPO_DIR/.ssh/ssh-device"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$REPO_DIR/.ssh/known_hosts -i $REPO_DIR/.ssh/id_ed25519 $HOST"
fi

# shellcheck disable=SC2029
# (ssh quoting is intentionally explicit per route)
route_a() {
    $SSH_CMD '
set -e
echo "===== ROUTE A: STATUS LED SUBSYSTEM DEEP TEST ====="
echo "--- A1 inventory ---"
for l in /sys/class/leds/*; do
  n=$(basename "$l")
  printf "%-32s brightness=%-2s max=%-2s trigger=%s\n" "$n" "$(cat "$l/brightness")" "$(cat "$l/max_brightness")" "$(sed -n "s/^.*\[\(.*\)\].*$/\1/p" "$l/trigger")"
done
echo "--- A2 brightness write/readback/restore (all status LEDs) ---"
for l in /sys/class/leds/*status*; do
  [ -e "$l/brightness" ] || continue
  n=$(basename "$l"); orig=$(cat "$l/brightness")
  echo 1 > "$l/brightness"; one=$(cat "$l/brightness")
  echo 0 > "$l/brightness"; zero=$(cat "$l/brightness")
  echo "$orig" > "$l/brightness"; rest=$(cat "$l/brightness")
  printf "%-32s orig=%s one=%s zero=%s restored=%s\n" "$n" "$orig" "$one" "$zero" "$rest"
done
echo "--- A3 trigger cycle on blue:status (safe) ---"
l=/sys/class/leds/blue:status
orig_b=$(cat "$l/brightness")
for trg in none default-on heartbeat timer; do
  echo "$trg" > "$l/trigger"; sleep 1
  printf "trigger=%-10s brightness=%s\n" "$trg" "$(cat "$l/brightness")"
done
echo none > "$l/trigger"; echo "$orig_b" > "$l/brightness"
echo "--- A4 timer sampling on red:status ---"
l=/sys/class/leds/red:status
orig_b=$(cat "$l/brightness")
echo timer > "$l/trigger"
i=1; while [ "$i" -le 6 ]; do printf "t=%s brightness=%s\n" "$i" "$(cat "$l/brightness")"; i=$((i+1)); sleep 1; done
echo none > "$l/trigger"; echo "$orig_b" > "$l/brightness"
echo "--- A5 netdev trigger probe on blue:status with wan/lan3 ---"
l=/sys/class/leds/blue:status
orig_b=$(cat "$l/brightness")
echo netdev > "$l/trigger"; sleep 1
for dev in wan lan3 eth0; do
  echo "$dev" > "$l/device_name" 2>/dev/null || continue
  echo 1 > "$l/link" 2>/dev/null || true
  sleep 1
  printf "dev=%-6s brightness=%s link=%s rx=%s tx=%s\n" "$dev" "$(cat "$l/brightness")" "$(cat "$l/link" 2>/dev/null)" "$(cat "$l/rx" 2>/dev/null)" "$(cat "$l/tx" 2>/dev/null)"
  echo 0 > "$l/link" 2>/dev/null || true
done
echo none > "$l/trigger"; echo "$orig_b" > "$l/brightness"
echo "--- A6 final restore inventory ---"
for l in /sys/class/leds/*; do
  n=$(basename "$l")
  printf "%-32s brightness=%s trigger=%s\n" "$n" "$(cat "$l/brightness")" "$(sed -n "s/^.*\[\(.*\)\].*$/\1/p" "$l/trigger")"
done
'
}

route_b() {
    $SSH_CMD '
echo "===== ROUTE B: ETHERNET PORT DRIVER DEEP TEST ====="
echo "--- B1 netdev sysfs electrical ---"
for i in eth0 lan1 lan2 wan lan3 br-lan; do
  echo "== $i =="
  for f in speed duplex carrier operstate link_mode carrier_changes carrier_up_count carrier_down_count mtu flags ifindex iflink addr_len; do
    [ -e "/sys/class/net/$i/$f" ] && printf "  %-20s %s\n" "$f" "$(cat "/sys/class/net/$i/$f" 2>/dev/null)"
  done
  echo "  address=$(cat "/sys/class/net/$i/address" 2>/dev/null)"
  echo "  of_node=$(readlink "/sys/class/net/$i/of_node" 2>/dev/null)"
  echo "  phys_port_name=$(cat "/sys/class/net/$i/phys_port_name" 2>/dev/null)"
  echo "  phys_switch_id=$(cat "/sys/class/net/$i/phys_switch_id" 2>/dev/null)"
done
echo "--- B2 PHY device inventory ---"
for p in 05 08 09 0a; do
  d="/sys/devices/platform/soc/1fb58000.switch/mdio_bus/mt7530_dsa-0/mt7530_dsa-0:$p"
  echo "== phy $p =="
  for f in phy_id phy_interface phy_dev_flags phy_has_fixups; do
    [ -f "$d/$f" ] && printf "  %-16s %s\n" "$f" "$(cat "$d/$f" 2>/dev/null)"
  done
  echo "  c45:"
  for f in "$d"/c45_phy_ids/*; do
    [ -f "$f" ] && printf "    %-16s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
  done
  echo "  hwmon:"
  for f in "$d"/hwmon/*; do
    [ -f "$f" ] && case "$(basename "$f")" in temp*|name) printf "    %-16s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)";; esac
  done
  echo "  statistics:"
  for f in "$d"/statistics/*; do
    [ -f "$f" ] && printf "    %-16s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
  done
done
echo "--- B3 baseline counters ---"
for i in eth0 lan1 lan2 wan lan3; do
  echo "$i rx_bytes=$(cat "/sys/class/net/$i/statistics/rx_bytes") tx_bytes=$(cat "/sys/class/net/$i/statistics/tx_bytes") rx_errors=$(cat "/sys/class/net/$i/statistics/rx_errors") tx_errors=$(cat "/sys/class/net/$i/statistics/tx_errors") rx_dropped=$(cat "/sys/class/net/$i/statistics/rx_dropped") tx_dropped=$(cat "/sys/class/net/$i/statistics/tx_dropped")"
done
if [ "${TOGGLE_10G:-0}" = "1" ]; then
  echo "--- B4 lan1/lan2 admin down/up cycle (explicitly enabled) ---"
  for i in lan1 lan2; do
    before_err=$(cat "/sys/class/net/$i/statistics/rx_errors")
    echo "$i before: rx_errors=$before_err"
    ip link set "$i" down; sleep 2
    echo "$i after down: flags=$(cat "/sys/class/net/$i/flags") operstate=$(cat "/sys/class/net/$i/operstate")"
    ip link set "$i" up; sleep 3
    after_err=$(cat "/sys/class/net/$i/statistics/rx_errors")
    echo "$i after up: rx_errors=$after_err delta=$((after_err-before_err))"
  done
else
  echo "--- B4 10G admin toggle skipped (set TOGGLE_10G=1 to enable; pollutes lan1 rx_errors) ---"
fi
echo "--- B5 disabled switch ports / phys ---"
for p in /proc/device-tree/soc/switch@1fb58000/ports/port@3 /proc/device-tree/soc/switch@1fb58000/ports/port@4 /proc/device-tree/soc/switch@1fb58000/mdio/ethernet-phy@b /proc/device-tree/soc/switch@1fb58000/mdio/ethernet-phy@c; do
  echo "$p status=$(cat "$p/status" 2>/dev/null)"
done
echo "--- B6 MDIO bus statistics/errors ---"
d=/sys/devices/platform/soc/1fb58000.switch/mdio_bus/mt7530_dsa-0/statistics
for f in "$d"/errors "$d"/errors_*; do
  [ -f "$f" ] && printf "%s=%s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
done
'
}

route_c() {
    $SSH_CMD '
echo "===== ROUTE C: ETHERNET PORT LED SUBSYSTEM DEEP TEST ====="
echo "--- C1 port LED inventory ---"
for l in /sys/class/leds/mt7530_dsa-0:*; do
  n=$(basename "$l")
  printf "%-32s brightness=%s max=%s trigger=%s\n" "$n" "$(cat "$l/brightness")" "$(cat "$l/max_brightness")" "$(sed -n "s/^.*\[\(.*\)\].*$/\1/p" "$l/trigger")"
done
echo "--- C2 brightness write/readback/restore ---"
for l in /sys/class/leds/mt7530_dsa-0:*; do
  n=$(basename "$l"); orig=$(cat "$l/brightness")
  echo 1 > "$l/brightness"; one=$(cat "$l/brightness")
  echo 0 > "$l/brightness"; zero=$(cat "$l/brightness")
  echo "$orig" > "$l/brightness"
  printf "%-32s orig=%s one=%s zero=%s restored=%s\n" "$n" "$orig" "$one" "$zero" "$(cat "$l/brightness")"
done
echo "--- C3 netdev offload probe (wan then lan3) ---"
w=/sys/class/leds/mt7530_dsa-0:09:green:lan
l=/sys/class/leds/mt7530_dsa-0:0a:green:lan
echo none > "$w/trigger"; echo 0 > "$w/brightness"; echo none > "$l/trigger"; echo 0 > "$l/brightness"
echo netdev > "$w/trigger"; echo wan > "$w/device_name"
echo 1 > "$w/link" 2>/dev/null; echo 1 > "$w/rx" 2>/dev/null; echo 1 > "$w/tx" 2>/dev/null
echo "wan after mode: link=$(cat "$w/link") rx=$(cat "$w/rx") tx=$(cat "$w/tx") offloaded=$(cat "$w/offloaded" 2>/dev/null)"
echo netdev > "$l/trigger"; echo lan3 > "$l/device_name"
echo 1 > "$l/link" 2>/dev/null; echo 1 > "$l/rx" 2>/dev/null; echo 1 > "$l/tx" 2>/dev/null
echo "lan3 after mode: link=$(cat "$l/link") rx=$(cat "$l/rx") tx=$(cat "$l/tx") offloaded=$(cat "$l/offloaded" 2>/dev/null)"
echo "--- C4 10G port LED gap audit ---"
echo "sysfs 10G-port LED count: $(ls /sys/class/leds | grep -c "mt7530_dsa-0:0[58]:" || true)"
for p in 5 8 9 a; do
  d="/proc/device-tree/soc/switch@1fb58000/mdio/ethernet-phy@$p"
  echo "ethernet-phy@$p leds-dir-count: $(ls "$d" 2>/dev/null | grep -c leds || true)"
done
echo "--- C5 restore and final inventory ---"
for l in /sys/class/leds/mt7530_dsa-0:*; do
  echo none > "$l/trigger" 2>/dev/null || true
  echo 0 > "$l/brightness" 2>/dev/null || true
done
for l in /sys/class/leds/mt7530_dsa-0:*; do
  n=$(basename "$l")
  printf "%-32s brightness=%s trigger=%s\n" "$n" "$(cat "$l/brightness")" "$(sed -n "s/^.*\[\(.*\)\].*$/\1/p" "$l/trigger")"
done
'
}

route_d() {
    $SSH_CMD '
echo "===== ROUTE D: THERMAL / HWMON / FAN / ERROR-LOG AUDIT ====="
echo "--- D1 hwmon devices ---"
for d in /sys/class/hwmon/hwmon*; do
  echo "== $(basename "$d") name=$(cat "$d/name" 2>/dev/null) =="
  for f in "$d"/temp*_input "$d"/temp*_max "$d"/fan*_input "$d"/pwm*; do
    [ -f "$f" ] && printf "  %-16s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
  done
done
echo "--- D2 thermal zones ---"
for t in /sys/class/thermal/thermal_zone*; do
  echo "== $(basename "$t") type=$(cat "$t/type" 2>/dev/null) temp=$(cat "$t/temp" 2>/dev/null) =="
done
echo "--- D3 fan service ---"
ps w | grep -E "fan|nct" | grep -v grep || echo "no fan process visible"
/etc/init.d/fan status 2>&1 || true
echo "--- D4 error log audit ---"
dmesg | grep -i -E "error|fail|warn|timeout|deferred|unable|call trace|hung|oops|panic|BUG" | head -200 || echo "no matching kernel errors"
echo "--- D5 network carrier flap audit ---"
for i in eth0 lan1 lan2 wan lan3 br-lan; do
  printf "%-8s carrier_changes=%s up=%s down=%s rx_errors=%s tx_errors=%s\n" "$i" "$(cat "/sys/class/net/$i/carrier_changes" 2>/dev/null)" "$(cat "/sys/class/net/$i/carrier_up_count" 2>/dev/null)" "$(cat "/sys/class/net/$i/carrier_down_count" 2>/dev/null)" "$(cat "/sys/class/net/$i/statistics/rx_errors" 2>/dev/null)" "$(cat "/sys/class/net/$i/statistics/tx_errors" 2>/dev/null)"
done
echo "--- D6 devices_deferred ---"
cat /sys/kernel/debug/devices_deferred 2>/dev/null || echo "none"
echo "--- D7 relevant modules ---"
lsmod | grep -E "mt76|mt7996|realtek|nct7802|mt7530|airoha_eth"
'
}

# 多路齐发：4 条路由同时执行
: > "$OUT_PREFIX.route_a.log"
: > "$OUT_PREFIX.route_b.log"
: > "$OUT_PREFIX.route_c.log"
: > "$OUT_PREFIX.route_d.log"

( route_a > "$OUT_PREFIX.route_a.log" 2>&1 ) &
pid_a=$!
( route_b > "$OUT_PREFIX.route_b.log" 2>&1 ) &
pid_b=$!
( route_c > "$OUT_PREFIX.route_c.log" 2>&1 ) &
pid_c=$!
( route_d > "$OUT_PREFIX.route_d.log" 2>&1 ) &
pid_d=$!

wait $pid_a; echo "route_a done (rc=$?)"
wait $pid_b; echo "route_b done (rc=$?)"
wait $pid_c; echo "route_c done (rc=$?)"
wait $pid_d; echo "route_d done (rc=$?)"

for r in a b c d; do
  echo "===== $OUT_PREFIX.route_$r.log tail ====="
  tail -8 "$OUT_PREFIX.route_$r.log"
done
