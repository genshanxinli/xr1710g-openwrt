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

`--peer-connects` is the other way round: the box under test runs
`iperf3 -s -1 -J -p PORT` twice and the peer dials it. Use it when the box
cannot open a connection towards the peer (no default route, or the peer
only accepts inbound). The harness prints the exact command the peer has
to run for each direction and waits `--peer-wait` seconds (default 120,
must exceed `--duration + 10`) for that test to arrive. `TX` still means
traffic from the box to the peer, so the peer adds `-R` for TX and omits
it for RX. In this role the peer's own counters are not in the local
iperf3 JSON, so the peer-side column reads `-`.

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

`--baseline` is the mode that makes a number citable: besides the usual
snapshots it records `snapshots/env/` (link speed, duplex, driver, offload
features, flowtable stanzas, every link with a positive speed, kernel,
CPU count, ip addr/route) and writes `baseline.md` next to `result.json`.
`--label` names the record, `--env-note` describes the peer and the path
in between. Example:

```sh
./scripts/bench-10g-unidirectional.sh --baseline --peer-connects \
    --iface br-lan --label lan4-1g --env-note "peer behind NAT, 1000Mb/s" \
    --duration 5 --parallel 4 --port 5201
```

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

## Quoting a number

A number is only a result when it sits next to the link it ran over. The
ledger (`scripts/claims.yaml`) must not carry a figure that no record
supports, and `--baseline` output is what a record looks like:

* `evidence: 实测` + `status: supported` only with a committed record;
* `source` points at the record line in `scripts/perf-baselines/`;
* the record names the link speed, and a 1000 Mb/s record can never be
  quoted as a 10G or a stock-vs-OpenWrt result.

`scripts/perf-baselines/lan4-1g-2026-11-20/record.md` is the first such
record (1G link, software path, no stock side).

## result.json

Top level: `timestamp`, `git_describe`, `kernel_release`, `hostname`,
`iperf3_version`, `iface`, `target`, `role`, `port`, `baseline`, `label`,
`env_note`, `mtu`, `duration_s`, `parallel`, `dump_foe`, `environment`,
`raw_log` and `directions`. `environment` is `null` unless `--baseline`
ran; it carries `link_speed_mbps`, `duplex`, `driver`,
`flowtable_hw_offload` and the capture directory.

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
