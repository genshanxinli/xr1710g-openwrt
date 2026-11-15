# MTU policy: 1500 on `lan10g` and `wan10g`

This is a policy document. It changes no code, package or image. Cite it
when a proposal treats jumbo frames as a performance switch.

## Default value

| Interface | Role | Default MTU |
|---|---|---|
| `lan10g` | 10G LAN (GDM4) | 1500 |
| `wan10g` | 10G WAN (GDM2) | 1500 |

1500 bytes is the default on both ports and the value to keep. The
Airoha driver accepts larger MTUs for DSA jumbo frames
(`AIROHA_MAX_MTU` is 9220,
`target/linux/airoha/patches-6.18/122-v7.0-net-airoha_eth-increase-max-MTU-to-9220-for-DSA-jumb.patch:33-34`),
but that capability is not a reason to raise the MTU of these ports.

## How to verify the default

Read the effective value on the running device (read-only):

    for i in lan10g wan10g; do printf '%-7s ' "$i"; cat "/sys/class/net/$i/mtu"; done

Prove the end-to-end path with `ping -M do`, which refuses to fragment:

    ping -M do -s 1472 -c 3 <peer>     # 1500-byte IPv4 packet: must get replies
    ping -M do -s 1473 -c 3 <peer>     # 1501-byte IPv4 packet: must fail

    ping -6 -M do -s 1452 -c 3 <peer>  # 1500-byte IPv6 packet: must get replies
    ping -6 -M do -s 1453 -c 3 <peer>  # 1501-byte IPv6 packet: must fail

A pass at 1472 and a failure at 1473 show that both ends and the path
accept 1500-byte packets. A failure at 1472 means the path cannot carry
1500-byte packets, regardless of the local MTU setting.

## Why jumbo is not a forwarding goal

- The forwarding path is offloaded: the PPE/flowtable forwards packets,
  and the fixed per-frame descriptor, header and bus cost is not removed
  by making frames larger. Roadmap item I9 records the result: jumbo
  amplifies the transaction/memory account and gives no forwarding gain.
  The A-B-A-B measurement below makes it concrete: the MTU 9000 arms lost
  most of the offload and about a third of the measured rate.
- The one benefit is UDP self-termination. When the router itself is the
  endpoint, larger datagrams mean fewer stack operations for the same
  bytes. Traffic that terminates on the router is not the forwarding
  objective and does not justify a device-wide jumbo default.
- The 10G ports must interoperate at 1500 with switches, peers and the
  WAN. A larger local MTU does not raise the path MTU; packets above 1500
  bytes are fragmented or dropped at the first 1500-MTU hop.
- This policy makes no throughput promise. It reports a measured
  comparison only to justify keeping 1500, and it cannot conflict with
  the #13 performance baseline: a baseline run must use this 1500
  default, and a result measured at another MTU is not comparable.

## Measurement basis: 2440 vs 1580

This policy implements the decision recorded in issue #100 (roadmap item
I9). The comparison comes from a local, non-versioned research tree, not
from this repository. In
`/home/lishujun/项目/xr1710g/xr1710g-openwrt/docs/perf-master.md:340-355`
(section 6.4), an A-B-A-B reversal on the same bench and session, with
one unidirectional TCP flow on `lan10g`, records:

| Round | `lan10g` MTU | Mbit/s | offload |
|---|---|---|---|
| M9a | 9000 | 1580 | 12.56% |
| M15a | 1500 | 2420 | 99.97% |
| M9b | 9000 | 1560 | 13.71% |
| M15b | 1500 | 2440 | 99.98% |

The raw iperf3 `SUM` lines are in
`.research/results/wan/m1-mtu-reversibility.log:7,14,21,28` under the
same tree; an independent rerun measured 2340, 2400 and 2450 Mbit/s in
`.research/results/wan/m1-out-reps.log:7,14,21`. The four alternating
rounds reverse with the MTU change and the rerun agrees, so the 2440 vs
1580 difference is not a one-off. The source also records the
forwarded/CPU frame counts and bytes per frame; those are not repeated
here.

The research tree excludes `/docs/` and `/.research/` via its
`.gitignore:41-42`, so these records are not versioned in this repository
and cannot be linked from it. The numbers are a measurement on that
bench, not a product throughput promise. They are the concrete evidence
for the policy: MTU 1500 measured 2.42-2.45 Gbit/s with 99.97-99.98%
offload in the A-B-A-B run, while MTU 9000 measured 1.56-1.58 Gbit/s
with 12.56-13.71% offload.

## Rollback

If an experiment changed the MTU at runtime:

    ip link set dev lan10g mtu 1500
    ip link set dev wan10g mtu 1500

Then repeat the verification commands. If the value was also written to
the device configuration, revert that option (or restore the previous
configuration), commit it, and reload the configuration; a reboot is the
safe fallback. A fresh boot with no explicit MTU option uses 1500.

Until the rollback is verified, the experiment is not finished.

## References

- `target/linux/airoha/patches-6.18/122-v7.0-net-airoha_eth-increase-max-MTU-to-9220-for-DSA-jumb.patch`
  - driver limit (`AIROHA_MAX_MTU`), not a policy.
- `target/linux/airoha/patches-6.18/920-13-net-airoha-Rework-MTU-configuration.patch`
  - per-port MTU rework.
- Issue #100 / roadmap item I9 - the decision to keep 1500 and treat
  jumbo as a non-goal.
