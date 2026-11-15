# A-path multi-socket source and CPU profile harness

`a-path-multisocket.sh` runs on the AP and records one arm of an A-path
measurement: a paced multi-socket UDP source plus the station, interrupt,
softirq, CPU, netdev and mt76 token/queue counters around it.  It exists to
separate a source limit from a host softirq limit and a client/air limit,
instead of inferring the cause from a throughput ceiling.

The script itself sends nothing unless `--run` is given.  The default
dry-run reports which prerequisites are missing and exits 0, so the same
command is safe on a build host without the device.

## Build

```
make -C scripts/wireless
```

For the AP, use the tree's target toolchain:

```
CROSS="$PWD/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.4.0_musl/bin"
CROSS="$CROSS/aarch64-openwrt-linux-musl-gcc"
make -C scripts/wireless CC="$CROSS" LDFLAGS=-static
```

An `aarch64-linux-gnu-gcc` static build is a useful compile check, but the
OpenWrt musl toolchain is the one to deploy.

Copy the script and the binary to the AP:

```
ssh root@ap 'mkdir -p /usr/share/a-path'
scp scripts/wireless/a-path-multisocket.sh scripts/wireless/udpblast3 \
    root@ap:/usr/share/a-path/
```

The script looks for `udpblast3` next to itself and in `/usr/bin`,
`/usr/sbin`, `/usr/libexec` and `/tmp`; `--source-bin PATH` overrides the
search.

## One arm

```
sh /usr/share/a-path/a-path-multisocket.sh \
    --iface phy2-ap0 \
    --client 192.168.1.50 \
    --seconds 20 --procs 6 --rate 1340 --run
```

`--rate` is the aggregate UDP payload rate in Mbit/s.  It is split evenly
over `--procs` processes and `--sockets` sockets per process (default 4), so
the default arm offers 1340 Mbit/s over 24 sockets.  `--sockets 1`
reproduces the previous one-socket-per-process source.  `--client` may be the
client IPv4 address or its MAC; when only the MAC is known, add
`--client-ip`, and when only the IP is known the script resolves the MAC
from `ip neigh` (use `--client-mac` if there is no neighbour entry).  For an
MLD client whose neighbour entry carries the MLD address, pass the link
address that `iw dev <iface> station dump` prints for the station.

The source is bound with `SO_BINDTODEVICE` to the **bridge master** of
`--iface` (for example `br-lan`), not to the AP netdev itself.  An AP netdev
such as `phy2-ap0` is a bridge port: binding a socket to it makes
`sendto()` succeed but the packets do not route to the client, which would
manufacture a source that looks fast and an AP tx delta of zero.
`--source-iface NAME` forces another device, and `--source-iface none`
disables the bind and lets the kernel route choose.

A receiver on the client is not required: the AP station and netdev
counters are the measurement.  With a listener such as
`socat -u UDP-RECV:5201 /dev/null`, the same arm also proves end-to-end
delivery.

## Matrix

```
for p in 4 5 6 7 8; do
    sh /usr/share/a-path/a-path-multisocket.sh \
        --iface phy2-ap0 --client 192.168.1.50 \
        --seconds 20 --procs "$p" --rate 1340 --run \
        >> /tmp/a-path.txt
done
```

Each invocation writes one key=value summary line to stdout and an artifact
directory under `/tmp` (or `--out-dir`).  The summary always contains
`procs`, `offered_mbps`, `ap_tx_delta_bytes`, `softirq_net_tx_delta`,
`client_signal_dbm` and `client_tx_nss`, even when a value is
`unavailable`.  It also carries `source_iface`, the device the source was
bound to, so a wrong egress path is visible next to the station delta.

`source_sent_bytes` and `source_mbps` cover the source process lifetime,
which includes the warm-up.  `ap_tx_delta_bytes`, `iface_tx_delta_bytes`,
the softirq/IRQ deltas and `mpstat` cover only the `--seconds` measurement
window; `source_elapsed_ms` is reported so the two windows are not mixed
up.

## Artifacts

Per arm, the artifact directory holds:

- `station.before`, `station.after` - `iw station dump`
- `interrupts.before`, `interrupts.after` - raw `/proc/interrupts`
- `softirqs.before`, `softirqs.after` - raw `/proc/softirqs`
- `mpstat.txt` - `mpstat -P ALL 1 <seconds>` when mpstat is available
- `token_info.before`, `token_info.after` - mt76 debugfs when present
- `hw-queues.before`, `hw-queues.after` - mt76 debugfs when present
- `iface_tx_bytes.*`, `iface_tx_packets.*` - AP netdev counters
- `source.N.out`, `source.N.err` - per-process source summary/progress
- `summary.txt`, `cmdline` - the arm result and invocation

Nothing in this directory modifies UCI, kernel modules, sysctl or firmware.
