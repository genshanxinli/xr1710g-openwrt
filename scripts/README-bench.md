# 10G unidirectional bench

`bench-10g-unidirectional.sh` is the fixed measurement protocol for the
10G ceiling work. It runs one direction at a time, snapshots the counters
before and after, and writes `result.json` so two builds can be compared
field by field instead of by hand-copied notes.

## Peer setup

The peer named by `TARGET` must run an iperf3 server:

```sh
iperf3 -s
```

The harness is the client in both directions (it adds `-R` for RX), so
one server handles both runs. On the OpenWrt device, install the iperf3
package first (`opkg install iperf3`, or `apk add iperf3` on newer images).

## Requirements

Required: a POSIX sh (busybox ash on the device), `iperf3`, and `ip`
(busybox applet or iproute2) to check that `IFACE` has an address.
`ethtool`, `nft`, `tc`, git and root access to debugfs are optional; when
one is unavailable the corresponding snapshot says so, and the run still
completes.

## Run

```sh
IFACE=wan TARGET=192.168.1.2 ./scripts/bench-10g-unidirectional.sh
./scripts/bench-10g-unidirectional.sh --iface wan --target 192.168.1.2 \
    --duration 60 --parallel 4 --result-dir /tmp/bench-1
```

Run it as root. `nft list ruleset`, `tc` and the PPE debugfs files are
unreadable otherwise; the run still completes, but those snapshots
contain a note instead of counters.

`--dry-run` prints the iperf3 commands and every snapshot path without
creating files, starting iperf3 or contacting the peer. An unset `TARGET`
or `IFACE` is printed as `<required>`; a real run refuses to start
without both, but the live interface is not validated by the dry run.

`DUMP_FOE=1` additionally snapshots `/sys/kernel/debug/ppe/entries`, the
full FOE table (about 32768 lines per snapshot); it is off by default.

## Protocol

TX then RX, never concurrent:

```text
TX: before snapshots -> iperf3 -c TARGET -t D -P P -J     -> after snapshots
RX: before snapshots -> iperf3 -c TARGET -t D -P P -R -J  -> after snapshots
```

`/proc/stat` and `/proc/interrupts` are the last captures before a run and
the first captures after it, so their deltas cover the iperf3 window.
`iface-counters.txt` and `uptime.txt` bound the pps window; the remaining
snapshots describe the state around the run.

## result.json

Top level: `timestamp`, `git_describe`, `kernel_release`, `hostname`,
`iperf3_version`, `iface`, `target`, `mtu`, `duration_s`, `parallel`,
`dump_foe`, `raw_log` and `directions`.

Each direction (`directions.tx`, `directions.rx`) has:

| Field | Meaning |
|---|---|
| `iperf3` | chosen throughput for that direction: `sum_sent` for TX, `sum_received` for RX, in bit/s and Gbit/s, plus the peer's value and the sender's retransmits |
| `pps` | interface packet delta over `iface_counters.elapsed_s`; `pps_source` says which counter was used |
| `cpu_idle` | `idle` and `iowait` tick deltas from `/proc/stat`, idle percent, and the same values per CPU |
| `irq` | delta of every numeric `/proc/interrupts` line over the run, plus the total |
| `ppe` | before/after `ppe/usage` fields (`entries`, `sram`, `dram`, `bound`, `bound_pct`, `unbound`, `l2b_bound`, `l2_flows_sw`) and deltas for `bound`, `l2b_bound` and `l2_flows_sw` |
| `snapshots` | relative paths to the before/after snapshot directories and the raw iperf3 JSON |

`snapshots/*/iface-counters.txt` and `uptime.txt` keep the raw numbers the
`pps` and `elapsed_s` fields were computed from; the JSON can be checked
or recomputed from those files.

## Comparing runs

```sh
jq '.directions | map_values({
  gbps: .iperf3.gbps,
  pps: .pps,
  idle_pct: .cpu_idle.idle_pct,
  bound_delta: .ppe.bound_delta
})' run1/result.json
```

Run the same command on `run2/result.json` and diff the two outputs.

Two cautions when reading the numbers:

* `pps` comes from the kernel netdev counters. On an interface with TSO,
  `tx_packets` counts skbs rather than wire packets, so a TX pps is a
  stack-side rate. RX is closer to the wire. This is still comparable
  across builds running the same protocol.
* `ppe.l2b_bound` counts only entries of type `PPE_PKT_TYPE_BRIDGE`
  (see `target/linux/airoha/an7581/target.mk`); on this target bridged
  flows are encoded as IPv4/IPv6 5-tuple entries and counted in `bound`.
  With no per-flow NPU counters, `packets`/`bytes` are `n/a` for many
  entries, so use the interface counters and the PPE deltas instead.
