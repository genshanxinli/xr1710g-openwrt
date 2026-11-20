# wan-path fixtures — XR1710G, r38047-a86ce12e27

Every file here is the unmodified output of a read-only command on the test
device (`ssh root@192.168.1.1`, kernel 7.3, image `r38047-a86ce12e27`,
nftables v1.1.7 "Commodore Bullmoose #8"), captured on 2026-11-20.  Nothing was
reformatted, re-indented or trimmed: the point of these files is that they carry
the bytes the parsers have to survive, including the tab indentation and the
pretty-printed JSON.

| file | command it came from | what it pins down |
| --- | --- | --- |
| `nft-list-flowtables.txt` | `nft list flowtables` | the `flowtable` line is tab-indented (`^Iflowtable ft {`), so a matcher anchored at column 0 finds nothing while `/^table /` still works |
| `nft-j-list-flowtables.json` | `nft -j list flowtables` | the document is pretty-printed (`"flowtable": {` with a space) and names the device list `dev`, not `devices` |
| `proc-net-pppoe.txt` | `cat /proc/net/pppoe` | this box has no session: header line only |
| `uci-network-wan.txt` | `uci show network.wan` | `proto='dhcp'`, `device='wan'`, no PPPoE |
| `ubus-wan-status.json` | `ubus call network.interface.wan status` | the netifd fallback when `network.wan.device` is unset |
| `ethtool-wan.txt` | `ethtool wan` | `Speed: Unknown!`, `Duplex: Unknown! (255)`, `Link detected: no` |
| `ppe-usage.txt` | `cat /sys/kernel/debug/ppe/usage` | `entries 32768`, `bound 0`, `unbound 0`, with the `ipv4_bound` lines that must not be mistaken for `bound` |

The PPE bind table is empty on this box (`cat /sys/kernel/debug/ppe/bind` prints
nothing), so there is no fixture for it — the test creates an empty file, which
is what the device produces.

There is no `ip` fixture on purpose: `wan-path` never invokes `ip`.  It reads
the netdev state from `/sys/class/net/<dev>/{carrier,speed,duplex}` and the
PPPoE session table from `/proc/net/pppoe`, and neither is an `ip` output.

`scripts/tests/wan-path-test.sh` replays these through the same fake
`uci`/`ubus`/`ethtool`/`nft` commands and fake tree the earlier scenarios use,
so no device is needed to run the test.
