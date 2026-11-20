# Airoha TX ring hash (`airoha_eth.tx_ring_hash`)

Status: opt-in, off by default. Patch:
`target/linux/airoha/patches-7.3/9906-net-airoha-hash-offloaded-flows-across-tx-rings.patch`.

## What it changes

`airoha_dev_select_queue()` used to pick the QDMA channel from `port->id`,
so every flow leaving one port landed on the same channel, i.e. on the same
eight of the 32 TX rings.  With this knob on, the channel comes from
`skb_get_hash()` — the flow's 5-tuple — and unrelated flows spread over the
four HW QoS channels (4 channels x 8 priority queues = 32 rings).

Not changed: ring count, the queue inside the channel
(`skb->priority % 8`, so DSCP/QoS still picks among eight queues), IRQ
affinity, HTTPS/QoS configuration.

## Turning it on

The parameter is `0444`, so it has to be set before the driver binds:

    # /etc/modules.d/ or the kernel command line
    airoha_eth.tx_ring_hash=1

There is no runtime write path on purpose: the channel binding is a property
of the device's lifetime, not something to flip under flows already
enqueued.

## When it stays inert

* **HTB / any claimed QoS channel.**  While any QoS channel of a QDMA is
  claimed by an HTB leaf (`qos_channel_map`), the port-derived channel is
  used as before: channels are a shared per-QDMA resource and a hashed packet
  on a shaped channel would be scheduled by another port's shaper.
* **No 5-tuple to hash.**  Non-IP frames and frames the flow dissector cannot
  read keep the port-derived channel and are counted as
  `unhashed_fallback`.

## Observing the distribution

    cat /sys/kernel/debug/qdma/tx_ring_hist

Prints `tx_ring_hash <0|1>`, then one line per QDMA and ring
(`qdma ring channel queue pkts bytes`), then `qdma N unhashed_fallback X`.
The counters are filled only while the knob is on, and they are per QDMA —
the rings belong to the QDMA block, not to a net_device, so this is a debugfs
file rather than `ethtool -S` (which would report the same 32 rings once per
netdev sharing the block).

Reading a *distribution* requires flows that actually cross the CPU: a flow
the PPE has offloaded never reaches `ndo_select_queue()`.  A box with
`bound 0` and no WAN carrier will show empty counters no matter what.
