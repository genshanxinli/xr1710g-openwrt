# MTU policy: 1500 on `lan2` (GDM4) and `wan` (GDM2)

This is a policy document. It changes no code, package or image. Cite it
when a proposal treats jumbo frames as a performance switch.

Every factual line below carries a marker: `实测` was read from the running
device (image `r38047-a86ce12e27`, kernel 7.3), `代码` was read in this tree
or in the prepared kernel tree, `推断` is reasoning that has no direct
measurement or source line.

## Netdev names on this board

The lab and the older perf notes call the two USXGMII ports `lan10g` and
`wan10g`. Those are **lab aliases, not netdevs**: nothing in
`ls /sys/class/net/` carries them (`实测`, 2026-11-20). The only in-tree
place that still uses the alias names maps them to the board's ports
explicitly:

    lan10g -> lan2      wan10g -> wan
    target/linux/airoha/an7581/base-files/usr/sbin/xr1710g-lan10g-diag:16-17, :83

| Lab alias | Netdev | GDM / PHY | Devicetree node | phy-mode | Citation (`代码`) |
|---|---|---|---|---|---|
| `lan10g` | `lan2` | GDM4 / `phy5` | `&gdm4` | `usxgmii` | `target/linux/airoha/dts/an7581-xr1710g-ubi.dts:338-347` |
| `wan10g` | `wan` | GDM2 / `phy8` | `&gdm2` | `usxgmii` | `target/linux/airoha/dts/an7581-xr1710g-ubi.dts:323-331` |

`cpu` is the DSA conduit of the switch
(`target/linux/airoha/dts/an7581-xr1710g-ubi.dts:315`,
`openwrt,netdev-name = "cpu"`); `lan3` and `lan4` are the GSW 1G user ports
(`target/linux/airoha/an7581/base-files/etc/board.d/02_network:20-21`).

`实测` netdev list, 2026-11-20:

    cpu lan2 lan3 lan4 wan br-lan phy0.0-ap0 phy0.1-ap0 phy0.2-ap0 lo
    (plus ib1 ib2 monl mon6, which are bench/monitor interfaces, not board ports)

Do **not** assert a 10 Gbit/s link rate for these ports in this document.
`wan` is nominally 10G but its negotiated rate is unmeasured, and the `phy5`
comment describes `lan2` as the 2.5G USXGMII link
(`docs/wan-productization.md:21-36`). `ethtool lan2` / `ethtool wan` on the
current image report `Speed: Unknown!` with no carrier (`实测`) — the speed
claim stays `UNVERIFIED`.

## Default value

| Netdev | Role | Default MTU |
|---|---|---|
| `lan2` (lab `lan10g`) | GDM4 USXGMII LAN port | 1500 |
| `wan` (lab `wan10g`) | GDM2 USXGMII WAN port | 1500 |
| `br-lan` | bridge over `lan2 lan3 lan4` + AP netdevs | 1500 |
| `cpu` | DSA conduit | 1504 |

1500 bytes is the default and the value to keep. The Airoha driver accepts
larger MTUs for DSA jumbo frames (`AIROHA_MAX_MTU` is 9220,
`target/linux/airoha/patches-6.18/122-v7.0-net-airoha_eth-increase-max-MTU-to-9220-for-DSA-jumb.patch:33-34`;
the 7.3 kernel we build already carries that value upstream, see the limits
section), but that capability is not a reason to raise the MTU of these
ports.

No MTU option is written to the device configuration: `grep -n mtu
/etc/config/network` returns nothing (`实测`), so the 1500 comes from the
`ETH_DATA_LEN` default and not from UCI.

### Why `cpu` is 1504 and the user ports are 1500

The 4-byte difference is the DSA tag header, not headroom for user traffic
(`代码`):

- the tag driver declares `MTK_HDR_LEN` 4 as its needed headroom
  (`net/dsa/tag_mtk.c:15`, `.needed_headroom = MTK_HDR_LEN` at `:114`
  in the prepared 7.3 tree),
- DSA sizes the conduit from the largest user port:
  `overhead = dsa_tag_protocol_overhead(cpu_dp->tag_ops);
  new_conduit_mtu = largest_mtu + overhead;`
  (`net/dsa/user.c:2142`, `:2145` in the prepared 7.3 tree),
- the Airoha driver expects that protocol
  (`dev->dsa_ptr->tag_ops->proto != DSA_TAG_PROTO_MTK`,
  `airoha_eth.c:2931` in the prepared 7.3 tree).

So `cpu` = 1500 + 4 = 1504 (`实测`). It carries one extra 4-byte tag per
frame between the switch and the CPU; it does not mean the ports can pass
1504-byte payloads.

## Driver and hardware limits (capacity, not policy)

- `#define AIROHA_MAX_MTU 9220`
  (`drivers/net/ethernet/airoha/airoha_eth.h:25` in the prepared kernel tree
  `/home/l1n/projects/xr1710g-openwrt/build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581/linux-7.3/`; `代码`).
  This value is upstream 7.3, not a local patch; the 6.18 series got the
  same value from the patch cited above.
- `netdev->max_mtu = AIROHA_MAX_MTU;`
  (`drivers/net/ethernet/airoha/airoha_eth.c:4430` in the same tree; `代码`,
  also a context line of
  `target/linux/airoha/patches-7.3/194-v7.2-net-airoha-add-LRO-offload-support.patch:595`).
- The PPE egress MTU register and the WAN MTU register compare against the
  **L2 frame length without FCS**, reset value `0x05EA`
  (= 1514 = `ETH_HLEN` + 1500), and are programmed with `netdev->mtu +
  VLAN_ETH_HLEN`
  (`target/linux/airoha/patches-7.3/920-16-net-airoha-Account-for-L2-overhead-in-PPE-MTU-configuration.patch:6-11`;
  `airoha_eth.c:2560-2568` in the prepared tree; `代码`). The hardware drop
  threshold is therefore 1518 bytes at MTU 1500, and a VLAN-tagged frame
  uses the extra 4 bytes of that margin.
- `target/linux/airoha/an7581/config-7.3` exposes **no** MTU, jumbo or LRO
  Kconfig knob: the file is 465 lines and `grep -n 'MTU'` has no match
  (`实测` on this tree); the only related symbol is `CONFIG_NET_AIROHA=y`
  (`target/linux/airoha/an7581/config-7.3:278`). MTU is a runtime netdev
  attribute bounded by the driver, not a build option.

## How to verify the default

Read the effective value on the running device (read-only; `实测` works on
the current image):

    for i in cpu lan2 lan3 lan4 wan br-lan phy0.0-ap0; do
        printf '%-12s ' "$i"; cat "/sys/class/net/$i/mtu"
    done

Expected: `cpu 1504`, everything else `1500`, `lo 65536`.

Prove the end-to-end path with a DF probe. `ping -M do` is **not** available
on the router: the image ships BusyBox `ping` 1.38.0, whose option parser
rejects `-M` (`实测`: `ping: unrecognized option: h` / no `-M` in its usage
list). Run the DF probe from a full iputils host instead, so the router
itself needs no changes:

    ping -M do -s 1472 -c 3 <peer>     # 1500-byte IPv4 packet: must get replies
    ping -M do -s 1473 -c 3 <peer>     # 1501-byte IPv4 packet: must fail

    ping -6 -M do -s 1452 -c 3 <peer>  # 1500-byte IPv6 packet: must get replies
    ping -6 -M do -s 1453 -c 3 <peer>  # 1501-byte IPv6 packet: must fail

A pass at 1472 and a failure at 1473 show that both ends and the path
accept 1500-byte packets. A failure at 1472 means the path cannot carry
1500-byte packets, regardless of the local MTU setting. From the router
itself only the unqualified form is possible (`ping -s 1472 -c 3 <peer>`),
which does not set DF, so it proves reachability and not the MTU.

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
- The USXGMII ports must interoperate at 1500 with switches, peers and the
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
one unidirectional TCP flow on the lab `lan10g` port (that is netdev
`lan2`, see the naming table), records:

| Round | Vol | MTU | Mbit/s | offload |
|---|---|---|---|---|
| M9a | `lan10g` (= `lan2`) | 9000 | 1580 | 12.56% |
| M15a | `lan10g` (= `lan2`) | 1500 | 2420 | 99.97% |
| M9b | `lan10g` (= `lan2`) | 9000 | 1560 | 13.71% |
| M15b | `lan10g` (= `lan2`) | 1500 | 2440 | 99.98% |

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

    ip link set dev lan2 mtu 1500
    ip link set dev wan mtu 1500

Then repeat the verification commands above (the DSA conduit returns to
1504 by itself once the largest user port is back at 1500; `推断` — the
conduit value is recomputed from the user ports by `net/dsa/user.c:2145`,
which makes it a consequence of the user-port MTU rather than a separate
knob).

If the value was also written to the device configuration, revert that
option (or restore the previous configuration), commit it, and reload the
configuration; a reboot is the safe fallback. A fresh boot with no
explicit MTU option uses 1500 (`实测`: no `mtu` option exists in
`/etc/config/network` today, and every port reads 1500).

Until the rollback is verified, the experiment is not finished.

## References

- `target/linux/airoha/dts/an7581-xr1710g-ubi.dts:315`, `:323-331`,
  `:338-347` — conduit `cpu`, and the `wan`/`lan2` port nodes.
- `target/linux/airoha/an7581/base-files/etc/board.d/02_network:20-21` —
  LAN/WAN netdev assignment for this board.
- `target/linux/airoha/an7581/base-files/usr/sbin/xr1710g-lan10g-diag:16-17`,
  `:83` — the `lan10g`/`wan10g` lab aliases and their `lan2`/`wan` mapping.
- `target/linux/airoha/patches-6.18/122-v7.0-net-airoha_eth-increase-max-MTU-to-9220-for-DSA-jumb.patch:33-34`
  — driver limit (`AIROHA_MAX_MTU` 9220) in the 6.18 series; not a policy.
- `target/linux/airoha/patches-7.3/920-13-net-airoha-Rework-MTU-configuration.patch`
  and `.../920-16-net-airoha-Account-for-L2-overhead-in-PPE-MTU-configuration.patch:6-11`
  — per-port MTU rework and the L2-overhead programming in the 7.3 series.
- `target/linux/airoha/an7581/config-7.3:278` — the driver is built in;
  the file has no MTU knob.
- Issue #100 / roadmap item I9 — the decision to keep 1500 and treat
  jumbo as a non-goal.
