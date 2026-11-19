# SOE read-only probe skeleton (D10)

Status: compile-ready on the Airoha 7.3 target, **read-only**, **default off**.
This is the first step of roadmap D10 (SOE IPsec offload). It is not an IPsec
data path and makes no performance claim.

## What this change adds

- `target/linux/airoha/patches-7.4/970-net-airoha-soe-readonly-probe.patch`
  - `drivers/net/ethernet/airoha/airoha_soe_probe.c`: a platform driver bound
    by `compatible = "airoha,en7581-soe"`.
  - `drivers/net/ethernet/airoha/Kconfig`: `NET_AIROHA_SOE` (tristate,
    `default n`, depends on `NET_AIROHA`).
  - `drivers/net/ethernet/airoha/Makefile`: builds `airoha_soe_probe.o`.
- No DTS change, no package, no default image change.

When the driver is enabled and a matching DT node is present, probe maps the
register window and logs one line, then returns. It never writes a register,
never programs an SA, never submits ESP, never requests the SOE interrupt and
never registers an XFRM or netdev offload provider. All register accesses in
the probe body are `readl()`.

## Hardware and register offsets

The EN7581 E2 exposes the packet/IPsec SOE window at `0x1fbfa000` (length
`0x268`) with interrupt `GIC_SPI 79`. It is a packet engine, not a standalone
crypto engine. The EIP93 block has no GCM; SOE has `SA_CMD.GCM_ICV_LEN`
(bits 25:24). That is one reason SOE is the target for ESP offload while EIP93
covers classic ESP only.

Offsets used by the probe (from the RFC driver, not a complete datasheet):

| Offset | Name | Probe use |
| --- | --- | --- |
| `0x000` | `GLB_CFG` | read; bit 0 `ENC_EN`, bit 1 `DEC_EN` |
| `0x020` | `INT_EN` | read |
| `0x024` | `INT_STS` | read (IRQ status) |
| `0x100` | `SA_CTRL` | read; bit 0 `WR`, bits 15:8 `IDX` |
| `0x104` | `SA_DONE` | read; bit 0 `W1C` (write-1-to-clear in the full driver, never written here) |

Related fields that are documented but deliberately **not** programmed by this
skeleton: `SA_CMD` at `0x110` (cipher/hash/key length, ESN, IPv6, tunnel vs
transport, NAT-T, anti-replay, drop controls, `GCM_ICV_LEN` bits 25:24,
`VLD` bit 31), QDMA hop descriptors (patch 5/7 of the RFC), and PPE flow
binding (patch 6/7). They belong to the full provider.

## Sources

- RFC "net: airoha: add EN7581 SOE ESP packet offload", 7 patches, Jihong Min,
  June 2026:
  [series on patchew](https://patchew.org/linux/20260614040032.1567994-1-hurryman2212@gmail.com/),
  [patch 4/7: SOE registers and driver state](https://patchew.org/linux/20260614040032.1567994-5-hurryman2212@gmail.com/),
  [patch 7/7: SOE XFRM packet offload](https://patchew.org/linux/20260614040032.1567994-8-hurryman2212@gmail.com/).
- Reference branch: `hurryman2212/OpenW1700k-test`, branch `offload-oc`.
- Task and constraints: [issue #38](https://github.com/genshanxinli/xr1710g-openwrt/issues/38).

The offsets above were cross-checked against the RFC patches 4/7 (register
definitions), 5/7 (QDMA hop descriptors) and 6/7 (PPE flow). The RFC is the
authoritative public source.

## Build

The symbol is default `n` and no package or target selects it, so a default
image does not compile the object. To compile it explicitly:

```sh
echo 'CONFIG_NET_AIROHA_SOE=y' >> target/linux/airoha/an7581/config-7.4
make target/linux/compile
```

Alternatively select it through `make kernel_menuconfig`. Do not enable it in
a default image. The expected artifact is
`build_dir/target-*/linux-*/drivers/net/ethernet/airoha/airoha_soe_probe.o`
(built-in) or `airoha_soe_probe.ko` when built as a module.

Patch applicability check, in a prepared 7.4 kernel source tree:

```sh
git apply --check target/linux/airoha/patches-7.4/970-net-airoha-soe-readonly-probe.patch
```

## Read-only check

Static check of the added driver lines:

```sh
grep -nE 'writel|writew|writeb|regmap_write|request_irq|xfrm|esp' \
	target/linux/airoha/patches-7.4/970-net-airoha-soe-readonly-probe.patch
```

Matches in comments are expected; there must be no match in executable code.
Manual review should confirm that `airoha_soe_probe()` contains only `readl()`
accesses to the block and that `airoha_soe_remove()` is empty.

## Enabling the probe on hardware (not part of this change)

No DTS node is added by this patch, so the probe does not bind on current
images. A later change can add the node from RFC patch 3/7, initially disabled:

```dts
soe: soe@1fbfa000 {
	compatible = "airoha,en7581-soe";
	reg = <0x0 0x1fbfa000 0x0 0x268>;
	interrupts = <GIC_SPI 79 IRQ_TYPE_LEVEL_HIGH>;
	status = "disabled";
};
```

Flipping `status` to `okay` for a read-only bring-up does not enable IPsec:
this skeleton has no SA, ESP, QDMA hop-descriptor or PPE flow code.

## Known gaps

- No DT node in this change, so the probe is compile/static-checked only and
  is not bound on any current image.
- Not run on hardware. No register values are claimed.
- No SA programming, ESP TX/RX, QDMA hop-descriptor submission, PPE flow
  binding, or XFRM state/policy registration.
- RFC 7 defines no SOE silicon-revision register. The probe reports its driver
  version (`MODULE_VERSION`, `0.1`) and the DT IRQ instead of guessing a `REV`
  offset; a real revision read needs authoritative register documentation.
- SOE GCM is neither enabled nor tested; EIP93 has no GCM.
- Not proposed upstream. The RFC series remains the upstream reference, and
  the full provider is much larger than this skeleton.
