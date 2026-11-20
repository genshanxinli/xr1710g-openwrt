# baseline lan4-1g-2026-11-20

Recorded by scripts/bench-10g-unidirectional.sh --baseline on 2026-11-20T05:17:20Z.
This file is the citable record: every number below was read back
out of the capture files of this run, and every qualifier next to it
comes from the same capture.

| field | value |
| --- | --- |
| label | lan4-1g-2026-11-20 |
| recorded at (UTC) | 2026-11-20T05:17:20Z |
| role | server |
| interface under test | br-lan (MTU 1500) |
| link speed | 1000 Mb/s |
| duplex (as br-lan reports it) | unknown |
| links with a positive speed | br-lan 1000/unknown up; cpu 10000/full up; lan4 1000/full up |
| driver | bridge 2.3 |
| kernel | 7.3 |
| kernel build | Linux version 7.3 (l1n@localhost) (aarch64-openwrt-linux-musl-gcc (OpenWrt GCC 14.4.0 toolchain-582d2181ab) 14.4.0, GNU ld (GNU Binutils) 2.46.1) #0 SMP PREEMPT Fri Nov 20 04:04:01 2026 |
| CPUs | 4 (0xd03) |
| iperf3 | iperf 3.22 (cJSON 1.7.15) |
| duration / streams | 5 s / 4 |
| flowtable devices | lan2, lan3, lan4, wan |
| flowtable hw offload flag | on |
| iface offload state | tso=on gro=on gso=on rx-csum=off tx-csum=on |
| git | unknown |
| environment | peer=WSL2 host behind NAT shim, MTU 1280; device=XR1710G lan4 1000Mb/s; iperf3 from /tmp |

Flowtable stanza as captured:

```
	flowtable ft {
		hook ingress priority filter
		devices = { "lan2", "lan3", "lan4", "wan" }
		flags offload
		counter
	}
	flowtable fb {
		hook ingress priority filter
		devices = { "lan2", "lan3", "lan4" }
		flags offload
		counter
	}
```

## throughput and cost per direction

TX = traffic from this box to the peer, RX = traffic from the peer
to this box; the two are separate runs, never concurrent.

In passive role the peer-side counters are not in this
record: this box holds only its own iperf3 JSON, so the peer
column is "-" rather than a number the harness did not see.

| direction | Gbit/s | peer Gbit/s (passive: -) | pps | retransmits | CPU busy s | CPU busy % of wall | idle % |
| --- | --- | --- | --- | --- | --- | --- | --- |
| tx | 0.704 | - | 2854 | 87 | 2.94 | 9.5 | 90.49 |
| rx | 0.887 | - | 26372 | - | 11.44 | 37.9 | 62.08 |

## what this record does and does not establish

The link under test reports **1000 Mb/s**, so 1000 Mb/s is this runs
hard ceiling and no number here can describe a 10G path.

A stock-firmware side is **not** part of this record: this script
measures the firmware it is run on, and no stock unit was attached.
A stock-vs-OpenWrt comparison needs the same harness run on the
stock firmware over the same link, and stays unmeasured until that
exists.

## captures behind this record

- `snapshots/env/ethtool-iface.txt`
- `snapshots/env/ethtool-driver.txt`
- `snapshots/env/ethtool-features.txt`
- `snapshots/env/sysfs-link.txt`
- `snapshots/env/nft-flowtable.txt`
- `snapshots/env/nft-ruleset-full.txt`
- `snapshots/env/link-ports.txt`
- `snapshots/env/kernel.txt`
- `snapshots/env/cpuinfo.txt`
- `snapshots/env/topology.txt`
- `iperf3-tx.json`, `iperf3-rx.json` (raw iperf3 JSON)
- `result.json` (parsed result, schema bench-10g-unidirectional/v1)
- `raw.log` (every command, in order)

## paste-ready claims.yaml entry

Commit this file as `scripts/perf-baselines/lan4-1g-2026-11-20.md` before citing it;
`source` must point at a committed line.

```yaml
  - id: baseline-lan4-1g-2026-11-20
    claim: "在本仓库 iperf3 基线上（1000 Mb/s 链路，bridge 驱动，flowtable
      硬件 offload on），本移植单向吞吐为 TX 0.704 Gbit/s、RX 0.887 Gbit/s，
      对应 CPU busy 见记录。"
    source:
      - "scripts/perf-baselines/lan4-1g-2026-11-20.md:1"
    evidence: 实测
    date: "2026-11-20"
    status: supported
    notes: "单机、单次、1000 链路，不代表 10G 能力，也不能与 stock 固件
      的数字并列当作对比；stock 侧仍无测量。"
```

## repeat runs and provenance (written by hand when committing this record)

Three separate `--baseline --peer-connects` invocations, same box, same
1 s snapshots cadence, 5 s / 4 streams each:

| run | TX Gbit/s | RX Gbit/s |
| --- | --- | --- |
| 1 | 0.756 | 0.917 |
| 2 | 0.692 | 0.852 |
| 3 (this record) | 0.704 | 0.887 |

Spread is about ±6%, which is the honest resolution of this setup; the
record above is run 3.

The device run directory also keeps the per-direction before/after
snapshots (`proc-stat.txt`, `proc-interrupts.txt`, `ethtool -S br-lan`,
`nft list ruleset`, PPE usage). Only the environment captures and the raw
iperf3 JSON are committed here; the deltas computed from the rest are in
`result.json`.

The peer was the WSL2 host behind a NAT shim (MTU 1280, not reachable
from the device), so the 87 TX retransmits belong to that path and say
nothing about the driver. All traffic was handled in the software path:
`ppe.bound_delta` is 0 in both directions even though the flowtable
stanzas carry `flags offload`.
