# FLOW_STATS_SETUP for ClankerNPU

`flow-stats.patch` adds the missing firmware-side handler for
`FLOW_STATS_SETUP` (HWNAT function id 4) to ClankerNPU's `npu_ppe.c`.
Before this patch the handler is a stub that returns 0, so the Linux
`airoha_npu` driver's `airoha_npu_ppe_stats_setup()` fails with `-EINVAL`
(`-22`) and the PPE falls back to flow offload without counters.

This is the roadmap D8 minimal step: reserve a counter area, return its
base and capacity, and make repeated requests idempotent. It does **not**
count packets, start per-STA AQM, or change the host driver. See
[What this does not do](#what-this-does-not-do) before building an image
from it.

## Apply and build

The patch is relative to ClankerNPU `main` at commit `735529c` (`npu_ppe.c`
md5 `b778e3fef3103cf6d5eba97e0b0b0e42`) and applies with the default
`git apply -p1` paths:

```sh
git -C ClankerNPU apply --check /path/to/tools/npu-firmware/flow-stats.patch
git -C ClankerNPU apply /path/to/tools/npu-firmware/flow-stats.patch
```

Built here with `riscv64-elf-gcc 16.2.0`:

```sh
make CROSS=riscv64-elf- SOC=AN7581 WIFI=MT7996
make CROSS=riscv64-elf- all-variants
```

The change is inside `#ifdef HAS_TUNNEL` (AN7581 and AN7583), as the
HWNAT mail handler already is.

## Host request and reply

The mailbox payload is the 28-byte `struct ppe_mbox_data` from
`drivers/net/ethernet/airoha/airoha_npu.c`. Function 4 takes no
additional request structure: the host puts its DMA address in word 3
and reads the reply address from word 2.

| offset | field | direction | meaning |
|---:|---|---|---|
| +0 | `func_type` | host to NPU | must be 1 (`NPU_OP_SET`) |
| +4 | `func_id` | host to NPU | must be 4 (`PPE_FUNC_SET_WAIT_FLOW_STATS_SETUP`) |
| +8 | `npu_stats_addr` | NPU to host | zero in the request; physical base of the counter array in the reply |
| +12 | `foe_stats_addr` | host to NPU | the host's coherent DMA buffer for the high 32 bits; preserved as-is |
| +16 | `version` | NPU to host | `1`; extension, the current host does not read it |
| +20 | `capacity` | NPU to host | `24576` counter slots; extension, the current host does not read it |
| +24 | reserved | — | left untouched |

The current host only reads `npu_stats_addr` at +8. It treats a zero
address as a refusal (`-ENOSPC`), otherwise it maps the returned physical
range with `devm_ioremap()` and reads counters through it. The version
and capacity words are returned for the host side to grow into; no host
change is part of this issue.

Each counter slot is the two-`u32` layout of `struct airoha_foe_stats`:

| offset | field |
|---:|---|
| +0 | `bytes` (low 32 bits) |
| +4 | `packets` (low 32 bits) |

The host combines them with the high 32 bits it keeps in `foe_stats_addr`:
`packets` and `bytes` become `high << 32 | low`. The firmware in this
patch leaves both halves at their initial zeroes.

## Fixed layout and sizing

The NPU SRAM ledger has no room for another 192 KiB without displacing
the WiFi rings and tables, so the array is a fixed carve-out in the
reserved NPU binary DRAM window instead of an `sram_buf_alloc()` block:

| property | value |
|---|---:|
| `FLOW_STATS_BASE` (physical) | `0x84800000` |
| `FLOW_STATS_LIMIT` | `0x84A00000` |
| slot size | 8 bytes |
| capacity | 24,576 slots |
| array size | 196,608 bytes (`0x30000`) |
| end | `0x84830000` |

Every AN7581/AN7583 board reserves 10 MiB at `0x84000000` for the NPU
binary (`npu_binary` in the OpenWrt device tree); the host loads at most
a 2 MiB RV32 image there and the per-hart stacks follow the image in the
same window. `0x84800000` is far above both and still below the
`0x84A00000` end of the reservation. The build-time checks reject an
array or a capacity that would cross either bound.

The current host requests `num_stats_entries * 8` bytes, where
`num_stats_entries = PPE_STATS_NUM_ENTRIES * num_ppe`; on AN7581 with the
tree's `CONFIG_NET_AIROHA_FLOW_STATS` that is 8,192 slots (65,536 bytes).
The reservation is larger on purpose, to the 24,576-slot ceiling in this
issue; the host maps only the part it asks for.

This is a reservation, not a runtime allocation: no state is kept, and
every valid request returns the same base and capacity. The handler does
not zero the area. The host resets the range it maps with
`memset_io()` immediately after a successful setup, before any flow can
read it.

## Validation and failure

The handler rejects:

- a request whose `func_type` is not 1 or whose `func_id` is not 4
  (failure at the mail layer, so the host sees `-EINVAL`);
- a non-zero `npu_stats_addr` that is not the fixed base (an earlier
  reply from this handler is accepted, a foreign value is not);
- a zero or not 8-byte-aligned `foe_stats_addr` (failure at the mail
  layer again).

Compile-time checks fail the build if the area would not fit
`0x84800000..0x84A00000`, or if `FLOW_STATS_CAPACITY` ever exceeds 24,576.

## What this does not do

- **No counting.** No `FCNT` register is written. The returned array
  stays zero, so reports show zero counters until the counting work
  lands.
- **No CDM3 data path.** Once the host is told counters exist, it sets
  `foe_stats_enabled` and steers counted flows to PSE port 6 (CDM3) in
  `airoha_ppe_foe_flow_stats_update()`. ClankerNPU does not yet receive,
  count, and return those packets. Do not deploy an image built from this
  patch: it makes the host enter a data path the firmware cannot serve.
  This is a source-only, build-verified step.
- **No per-STA AQM**, no host driver change, no PPE table geometry
  change, no `BND_AGE` change.
- **No on-board run.** Nothing was flashed and no device was attached.

## Verification performed

- `git apply --check` on pristine ClankerNPU `main` (`735529c`): passes.
- `make CROSS=riscv64-elf- SOC=AN7581 WIFI=MT7996`: builds with no
  warnings.
- `make CROSS=riscv64-elf- all-variants`: all 11 images build with no
  warnings.
- Disassembly of the AN7581/MT7996 image shows the new case storing
  `0x84800000` at +8, `1` at +16, and `24576` at +20.
