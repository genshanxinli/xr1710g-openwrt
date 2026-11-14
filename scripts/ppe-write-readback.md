# Gated single-entry PPE write/readback card (D2)

Companion to `scripts/ppe-write-readback.sh`. The script turns the one
high-risk D2 step into a repeatable card: back up one bound (BND) PPE
entry, write the same 80 bytes back through the SRAM control path
(`REQ|WR`), read it back immediately, restore the original bytes and
record the evidence in `result.json`.

> **WARNING - M0 first.** Do not run the script, not even its read-only
> mode, before M0 is done: a full flash/partition backup plus a tested
> serial-console recovery path (全盘备份 + 串口恢复). A wrong write can
> invalidate a live forwarding entry, corrupt another flow's entry or take
> traffic off the fast path. If M0 is not done, stop.

The card is a lab tool. It is not wired into CI, init scripts or the
image, and this change does not run it on hardware.

## Read-only is the default

Without `--confirm-write` the script only reads. It prints the target
slot's raw 80 bytes, decodes `ib1` (`state`, `packet_type`, `BIND_TTL`)
and recomputes the entry's table hash the way the current tree's
`airoha_ppe_foe_get_entry_hash()` does. Then it exits 0.

```sh
./scripts/ppe-write-readback.sh --slot 0x1234
```

A write needs all three of `--confirm-write`, `--slot` and
`--expected-hash`. `--dry-run` never opens `/dev/mem` and works on a host
without the device, so the plan can be reviewed first:

```sh
./scripts/ppe-write-readback.sh --dry-run --slot 0x1234 --expected-hash 0x4825
```

## Picking the slot and the hash

`--slot` is the hardware table slot, decimal or `0x` hex. It is the first
column of `/sys/kernel/debug/ppe/entries`, which prints hex without the
`0x` prefix. Use `--slot 0x...` when copying from that dump.

The `hash:` line is the table index the current driver computes from the
entry's tuple, folded for the geometry read from `REG_PPE_TB_CFG`. It is
not the raw 32-bit hash (the raw value is printed too). For a correctly
placed entry the hash equals the slot; when the entry's tuple hashes to a
different value, the read-only report prints

```
placement: MISMATCH (entry hashes to 0x... but sits in slot 0x...)
```

That mismatch is exactly the aliasing D2 is trying to explain, and it is
the interesting case for this card. D2 selects a BND entry whose hash is
`>= 0x4000`; the read-only report prints a note when the hash is below
that (it is a hint, not a gate).

The expected hash is the number the read-only run printed, re-typed so a
second run cannot write a different slot by accident:

```sh
# 1. read-only: inspect the slot and copy the hash
./scripts/ppe-write-readback.sh --slot 0x1234

# 2. same value write with the gate open; keep the backup off /tmp
./scripts/ppe-write-readback.sh --slot 0x1234 --expected-hash 0x4825 \
    --backup-dir /root/ppe-write --confirm-write
```

If the entry changes between the two runs, the recomputed hash no longer
matches and the write is refused.

## Requirements

- XR1710G (AN7581, two PPEs). The script reads both `REG_PPE_TB_CFG`
  values and refuses if they disagree, if a field is implausible, or if
  the slot falls in the DRAM window.
- Root, `/dev/mem` and the `devmem` applet for any real run, plus
  `sha256sum` for a write. On images without `/dev/mem`, only `--dry-run`
  works; that is the expected result, not a bug to work around.
- A kernel built with `CONFIG_DEVMEM=y` and the busybox `devmem` applet
  enabled. The current tree does not have either:
  `target/linux/generic/config-7.3` has `# CONFIG_DEVMEM is not set`, the config also sets
  `CONFIG_IO_STRICT_DEVMEM=y`, and `BUSYBOX_DEFAULT_DEVMEM` is `n`. Every
  real run on today's image therefore refuses at the `/dev/mem` check, and
  only `--dry-run` works. Enabling `/dev/mem` (and allowing it to reach the
  FE window the driver has claimed) is a separate build change; this card
  does not make it.
- The hash follows the current tree's fold semantics
  (`patches-7.3/212`). An image that predates that change computes the
  fold differently, so do not reuse an old hand-computed hash.
- Quiesce traffic or detach the flowtable first. The data-word/trigger
  sequence runs from userspace and cannot take the driver's `ppe_lock`;
  the script verifies the bounce registers before triggering, but a
  bind commit that lands in the window can still be corrupted.
- Not executed in CI, by any init script or by the image build.

## Gates and refusals

A write is refused when:

- `/dev/mem` does not exist, or `devmem`/`sha256sum` is missing;
- the slot is outside the SRAM window (the `REQ|WR` path cannot address
  a DRAM entry);
- the entry state is not `BND` (`INV`, `UNB` and `FIN` are refused);
- the packet type is not one the driver hashes for this path (`IPv4
  5T/3T`, `L2B`, `IPv6 3T/5T`; DS-Lite and 6RD are refused);
- the recomputed hash differs from `--expected-hash`;
- the backup cannot be created, written, sized to 80 bytes or hashed;
- `--confirm-write` is absent (nothing is written at all).

Every programmed address is checked against a small allowlist before the
call. The script refuses to write outside it, refuses the
`0x1e900000-0x1ebfffff` window and refuses `0x1fb50284` explicitly.

Register addresses used (AN7581 FE base `0x1fb50000`, PPE1/PPE2 at
`+0x0c00`/`+0x1c00`):

| register | offset | use |
| --- | --- | --- |
| `REG_PPE_TB_CFG` | `+0x21c` | read SRAM/DRAM entry geometry |
| `REG_PPE_RAM_CTRL` | `+0x31c` | entry number (23:8), `WR` (1), `REQ` (0), `ACK` (31) |
| `REG_PPE_RAM_ENTRY` | `+0x320` | 20 x u32, the 80-byte entry |

## What a write run does and leaves behind

Order of operations:

1. read the entry and write `<backup-dir>/backup-<slot>-<UTC>.bin`
   (exactly the 80 little-endian bytes) plus its `sha256sum`;
2. write the same 20 u32 words to `REG_PPE_RAM_ENTRY`, read them back to
   verify the bounce registers;
3. write `REG_PPE_RAM_CTRL = entry << 8 | WR | REQ` exactly once and wait
   for `ACK`;
4. read the entry back immediately;
5. write the original 20 words back (also on write or readback failure)
   and read the restored entry back;
6. write `result.json` in the backup directory.

`result.json` records the timestamp, geometry source, slot/PPE/entry,
target addresses, expected hash, the before/readback/restore entries
(decoded fields and all 20 words), the backup path and sha256, and the
return codes for `backup`, `write`, `readback`, `restore` and `verify`.
`status` is `ok` only when the write, immediate readback, restore write
and restore readback all succeeded and the restored words equal the
before words. A later write run overwrites `result.json` in the chosen
backup directory; keep each run in its own `--backup-dir` when collecting
evidence.

Exit status: `0` report/dry run, or write + verified restore; `1` refused
or a step failed; `2` invalid usage.

## Recovery

If a restore step fails, do not reboot. The original bytes are in the
`backup-*.bin` printed by the script (and in `result.json` as
`before.words`). Read the words back with

```sh
od -An -tx4 -v /root/ppe-write/backup-1234-<UTC>.bin
```

The words are printed without the `0x` prefix that `devmem` wants; add it
when typing them. Replay them through the same registers from `result.json`
(`target.ram_entry_base` and `target.ram_ctrl`), then write the
`REQ|WR` trigger `entry << 8 | 3` once and read `ACK`:

```sh
devmem 0x1fb51f20 32 0x24001234
# ... one write per word, in order ...
devmem 0x1fb51f1c 32 0x00023403   # entry 0x0234, WR|REQ
devmem 0x1fb51f1c 32              # bit 31 = ACK
```

If the entry cannot be restored or the board is unstable, fall back to
the M0 serial recovery path. The 80-byte blob is the only trusted source;
do not reconstruct it from the debugfs text dump.

## Limitations

- SRAM slots only; DRAM entries are refused because the `REQ|WR` control
  path cannot address them.
- No kernel lock is held. The bounce verification catches a concurrent
  writer between the 20 data words and the trigger, but not one that
  lands after the check. Keep new flows off the box for the few seconds
  the run takes.
- `--dry-run` assumes the two known geometries for the offline mapping
  (4096/PPE with flow counters, 8192/PPE without); the real mapping is
  read from `REG_PPE_TB_CFG` before anything is touched.
- Hardware execution is a later step. This change only adds the script
  and this note.
