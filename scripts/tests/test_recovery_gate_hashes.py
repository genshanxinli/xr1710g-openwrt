#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The two flash gates must not read "no evidence" as "checked".

Four findings, each one an already-written guard that the code did not have:

W28-CI-01  ``recovery-boot-dryrun.sh`` compared the pushed copy's digest with
    ``[ "$GOT_REMOTE" = "$WANT" ]``.  When the local ``sha256sums`` has no
    entry for the image *and* the remote ``sha256sum`` says nothing, both sides
    are empty, the comparison is true, the row prints PASS, and ``--execute``
    goes on to ``sysupgrade -T`` and the flash.  The row whose only job is
    "prove the bytes that arrived are the image" passed in exactly the state
    where nothing was proved.  The same file's ``image.sha256`` row already had
    the ``[ -n "$WANT" ]`` guard (line 235 then); the push row did not.

W28-CI-02  The ``METADATA_REFUSED`` escape hatch cleared ``CHECK_FAILED`` when
    ``CHECK_FAILED -le 1``, i.e. it counted rows instead of identifying which
    row failed.  A digest FAIL is one row too, so "the image has no fwtool
    trailer, --execute will ask the device" also forgave "the image does not
    match its digest".  The verdict must name the row it forgives.

W28-CI-03  Neither gate looked at mtimes, so an incremental build that rewrote
    the ``.itb`` without rewriting ``sha256sums`` was reported as a digest
    mismatch with no hint that the list was stale.  The fix is that hint: a
    stale list is a row of its own, and it only FAILs when its digest
    disagrees.  An mtime alone cannot refuse an image whose bytes the digest
    already proved -- ``cp -p``/``rsync -t`` keep the list's timestamp while
    copying both files byte-for-byte, and a stale-list-forgiveness *switch* is
    what r28 §4.1 ruled out.

r05  ``fw_printenv`` on an uninitialized U-Boot environment prints
    ``Bad CRC, using default environment`` and then the *host tool's*
    compile-time defaults: ``bootcmd=run distro_bootcmd``, ``loadaddr=0x0``.
    The dry run parsed that and FAILed ``bootenv.loadaddr`` ("0x0 is below the
    recovery kernel end"), telling the operator that the board's environment is
    too old to rescue from -- when the board's environment is simply empty
    (a legal state) and ``0x0`` was never a value stored on it.

The device is a stub ``ssh``: read-only probes answer from fixtures, everything
else is the script's own remote command line run locally with ``/tmp`` re-rooted
into the case's directory, so tar/mv/sha256sum do the real work.  Red proof:

    git show HEAD:scripts/recovery-boot-dryrun.sh > /tmp/old-dryrun.sh
    git show HEAD:scripts/flash-gate.sh > /tmp/old-flash-gate.sh
    RECOVERY_DRYRUN_UNDER_TEST=/tmp/old-dryrun.sh \\
    FLASH_GATE_UNDER_TEST=/tmp/old-flash-gate.sh \\
        python3 scripts/tests/test_recovery_gate_hashes.py

Run from the repository root:

    python3 scripts/tests/test_recovery_gate_hashes.py
"""

from __future__ import annotations

import hashlib
import os
import shutil
import struct
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RECOVERY = Path(
    os.environ.get("RECOVERY_DRYRUN_UNDER_TEST")
    or REPO_ROOT / "scripts/recovery-boot-dryrun.sh"
)
FLASH_GATE = Path(
    os.environ.get("FLASH_GATE_UNDER_TEST") or REPO_ROOT / "scripts/flash-gate.sh"
)

IMG_NAME = "openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb"
NAME = "initramfs-recovery.itb"
HOST = "root@192.168.1.1"
BOARD = "gemtek,xr1710g-ubi"
EXIT_USAGE = 2
EXIT_CHECK = 4
EXIT_IMAGE = 6

# The board's stored environment, as fw_printenv prints it when the CRC checks
# out.  loadaddr is this tree's defenv value (patch 999): it clears the recovery
# kernel's decompression window (0x80200000..0x82ab0000).
ENV_STORED = (
    "bootargs=console=ttyS0,115200 ubi.block=0,fit\n"
    "bootcmd=run boot_ubi || http_recovery\n"
    "loadaddr=0x85000000\n"
)

# What the same command prints on a box whose env volume is empty: one warning
# and then uboot-tools' compile-time default env (bootcmd=run distro_bootcmd,
# loadaddr=0x0).  None of these values is stored on the board.
ENV_DEFAULT = (
    "Warning: Bad CRC, using default environment\n"
    "bootargs=\n"
    "bootcmd=run distro_bootcmd\n"
    "loadaddr=0x0\n"
)

FW_ENV_GOOD = (
    "/dev/ubi0_0 0x0 0x4000 0x1f000 1\n"
    "/dev/ubi0_1 0x0 0x4000 0x1f000 1\n"
)

FW_ENV_ALT_GOOD = (
    "/dev/ubi0_0 0x0 0x00004000 0x1f000 1\n"
    "/dev/ubi0_1 0x0 16384 0x1f000 1\n"
)

FW_ENV_BAD = (
    "/dev/ubi0_0 0x0 0x1f000 0x1f000 1\n"
    "/dev/ubi0_1 0x0 0x1f000 0x1f000 1\n"
)

PROBE = """\
gemtek,xr1710g-ubi
--- cmdline
console=ttyS0,115200 ubi.block=0,fit root=/dev/ubiblock0_0
--- mtd
dev:    size   erasesize  name
mtd0: 10000000 00020000 "ubi"
--- ubiinfo
Volume ID:   0 (on ubi0)
Alignment:   1
Size:        132 LEBs (16760832 bytes, 15.9 MiB)
State:       OK
Name:        fit
Volume ID:   4 (on ubi0)
Alignment:   1
Size:        3267 LEBs (414830592 bytes, 395.6 MiB)
State:       OK
Name:        rootfs_data
Logical eraseblock size:   126976 bytes
Amount of available logical eraseblocks: 0
--- env
%ENV%--- fw_env
%FW_ENV%--- fitblk
E
E fit
W factory
--- slot
fit_id 2
%SLOT_SHA%  /dev/ubi0_2
%SLOT_LEN%
--- kexec
none
"""

META = """\
console=ttyS0,115200 ubi.block=0,fit root=/dev/ubiblock0_0
dev:    size   erasesize  name
mtd0: 10000000 00020000 "ubi"
"""

# A device-shaped ssh.  Probes answer from fixtures; every other command is the
# script's own remote line, run locally with /tmp re-rooted into $SSH_DEVICE.
# SSH_REMOTE_SUMS_FAIL=1 makes the remote `sha256sum` say nothing at all -- the
# state W28-CI-01 was found in ("ssh 的 sha256sum 失败").
SSH_STUB = """\
#!/bin/sh
dev=${SSH_DEVICE:?}
fix=${SSH_FIXTURES:?}
printf 'ssh %s\\n' "$*" >> "$fix/ssh.log"
while [ $# -gt 0 ]; do
\tcase "$1" in
\t-o|-i|-p|-l|-F|-c) shift 2 ;;
\t-*) shift ;;
\t*) break ;;
\tesac
done
[ $# -ge 2 ] || exit 255
shift
cmd=$*
case "$cmd" in
*board_name*) cat "$fix/probe.txt"; exit 0 ;;
*"dd if=/dev/ubi0_2"*) cat "$fix/slot.bin"; exit 0 ;;
*"cat /proc/cmdline; cat /proc/mtd"*) cat "$fix/meta.txt"; exit 0 ;;
esac
if [ -n "${SSH_REMOTE_SUMS_FAIL:-}" ]; then
\tcase "$cmd" in
\t*sha256sum*) exit 1 ;;
\tesac
fi
if [ -f "$fix/remote_sha" ]; then
\tcase "$cmd" in
\t*"sha256sum /tmp/initramfs-recovery.itb"*)
\t\tprintf '%s  /tmp/initramfs-recovery.itb\\n' "$(cat "$fix/remote_sha")"
\t\texit 0 ;;
\tesac
fi
rewritten=$(printf '%s\\n' "$cmd" | sed "s#/tmp#$dev#g")
exec sh -c "$rewritten"
"""

SYSUPGRADE_STUB = """\
#!/bin/sh
printf 'sysupgrade %s\\n' "$*" >> "${SSH_FIXTURES}/sysupgrade.log"
if [ "${1:-}" = "-T" ]; then
\texit 0
fi
if [ -n "${SSH_SYSUPGRADE_FAIL:-}" ]; then
\tprintf 'sysupgrade: write failed\\n' >&2
\texit 1
fi
exit 0
"""

DUMPIMAGE_STUB = """\
#!/bin/sh
cat <<'EOF'
 Image 0 (kernel-1)
  Description:  ARM64 OpenWrt Linux-7.4-rc3
  Compression:  lzma compressed
  Data Size:    14273370 Bytes = 13938.84 KiB = 13.61 MiB
  Load Address: 0x80200000
 Image 1 (fdt-1)
  Description:  ARM64 OpenWrt gemtek_xr1710g-ubi device tree blob
  Default Configuration: 'config-1'
EOF
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class RecoveryGate(unittest.TestCase):
    """--execute path of scripts/recovery-boot-dryrun.sh with a stub device."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="recovgate-hashes-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.fix = self.tmp / "fixtures"
        self.dev = self.tmp / "device"
        self.imgdir = self.tmp / "image"
        self.restore = self.tmp / "restore"
        self.tree = self.tmp / "tree"
        for d in (self.bin, self.fix, self.dev, self.imgdir):
            d.mkdir()

        # 1 MiB of non-zero bytes; no "FWx0" tail unless a case asks for one.
        self.image = bytes(range(0x41, 0x41 + 26)) * 40330
        self.image = self.image[: 1024 * 1024]
        self.image_sha = sha256(self.image)

        slot = bytes(range(64)) * 16384
        self.slot_sha = sha256(slot)
        (self.fix / "slot.bin").write_bytes(slot)
        (self.fix / "meta.txt").write_text(META)
        self.write_probe(ENV_STORED)

        for name, body in (
            ("ssh", SSH_STUB),
            ("sysupgrade", SYSUPGRADE_STUB),
            ("dumpimage", DUMPIMAGE_STUB),
        ):
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)

    # -- fixtures ----------------------------------------------------------

    def write_probe(self, env: str, fw_env: str = FW_ENV_GOOD) -> None:
        (self.fix / "probe.txt").write_text(
            PROBE.replace("%ENV%", env)
            .replace("%FW_ENV%", fw_env)
            .replace("%SLOT_SHA%", self.slot_sha)
            .replace("%SLOT_LEN%", str(len(bytes(range(64)) * 16384)))
        )

    def tree_with(self, require_metadata: bool = True) -> Path:
        """A copy of the script under its own TOP, with a platform.sh of ours.

        REQUIRE_IMAGE_METADATA is the only thing the metadata row reads from
        the tree, and it decides whether an image without a trailer is a
        refusal (this board) or a forceable case.
        """
        copy = self.tree / "scripts" / "recovery-boot-dryrun.sh"
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_text(RECOVERY.read_text())
        platform = self.tree / "target/linux/airoha/an7581/base-files/lib/upgrade/platform.sh"
        platform.parent.mkdir(parents=True, exist_ok=True)
        platform.write_text(
            "REQUIRE_IMAGE_METADATA=1\n" if require_metadata else "# nothing\n"
        )
        return copy

    def put_image(
        self, trailer: bool = False, sums: str = "match", stale: bool = False
    ) -> Path:
        """Write the image, then (or before) a sha256sums with `sums` inside.

        sums="match"|"mismatch"|"absent" -- absent writes no sha256sums at all.
        stale=True writes the list first and then stamps the image strictly
        newer, which is what an incremental build leaves behind.
        """
        data = self.image
        if trailer:  # 16-byte fwtool trailer: magic, 0, 1, size
            data = data + struct.pack(">IIB3xI", 0x46577830, 0, 1, 16 + len(data))
        self.image_sha = sha256(data)
        digest = self.image_sha if sums == "match" else "0" * 64
        if sums == "absent" and stale:
            raise AssertionError("absent sums have no mtime to be stale")

        if stale:
            (self.imgdir / "sha256sums").write_text("%s *%s\n" % (digest, IMG_NAME))
            t_old = time.time() - 3600
            os.utime(self.imgdir / "sha256sums", (t_old, t_old))
            (self.imgdir / IMG_NAME).write_bytes(data)
            t_new = t_old + 1800  # strictly later, not a same-second tie
            os.utime(self.imgdir / IMG_NAME, (t_new, t_new))
        else:
            (self.imgdir / IMG_NAME).write_bytes(data)
            if sums != "absent":
                (self.imgdir / "sha256sums").write_text(
                    "%s *%s\n" % (digest, IMG_NAME)
                )
        return self.imgdir / IMG_NAME

    # -- runner ------------------------------------------------------------

    def run_script(self, *extra: str, **env_extra: str) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = "%s:%s" % (self.bin, env.get("PATH", ""))
        env["SSH_DEVICE"] = str(self.dev)
        env["SSH_FIXTURES"] = str(self.fix)
        env.update(env_extra)
        return subprocess.run(
            [shutil.which("sh"), str(self.tree_with()), "-H", HOST, *extra],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
        )

    def execute(self, image: Path, **env_extra: str) -> subprocess.CompletedProcess:
        return self.run_script(
            "--execute", "-i", str(image), "-d", str(self.restore), **env_extra
        )

    def rows(self, stdout: str, key: str) -> list[str]:
        return [line for line in stdout.splitlines() if line.startswith(key)]

    def verdict_of(self, line: str) -> str:
        return line.split()[-1] if line.split() else ""

    @property
    def sysupgrade_log(self) -> Path:
        return self.fix / "sysupgrade.log"

    # -- W28-CI-01 ---------------------------------------------------------

    def test_no_digest_anywhere_cannot_become_a_passing_push(self) -> None:
        """WANT empty and the remote sha256sum silent is not a passing push.

        On this image the row above (``image.sha256``) already aborts when the
        list has no entry, which is why the old code's empty-vs-empty PASS was
        not reached here; the point of the test is that the *push* row cannot
        become the weak link if that earlier abort ever moves or stops firing.
        """
        image = self.put_image(trailer=False, sums="absent")
        run = self.execute(image, SSH_REMOTE_SUMS_FAIL="1")
        self.assertNotEqual(
            run.returncode,
            0,
            "a run with no digest on either side must not succeed (rc 0):\n%s%s"
            % (run.stdout, run.stderr),
        )
        passed = [
            line for line in self.rows(run.stdout, "pushed.sha256")
            if self.verdict_of(line) == "PASS"
        ]
        self.assertEqual(
            passed,
            [],
            "pushed.sha256 PASSed with no digest on either side:\n%s" % run.stdout,
        )
        self.assertFalse(
            self.sysupgrade_log.exists(),
            "the flash path was entered with zero digest evidence:\n%s"
            % self.sysupgrade_log.read_text()
            if self.sysupgrade_log.exists()
            else "the flash path was entered with zero digest evidence",
        )

    def test_push_row_keeps_the_guard_the_image_row_has(self) -> None:
        """Textual companion: the row itself must carry the empty-WANT guard."""
        lines = []
        pending = ""
        for line in RECOVERY.read_text().splitlines():
            if pending or line.lstrip().startswith("row pushed.sha256"):
                pending += line.strip() + " "
                if not line.rstrip().endswith("\\"):
                    lines.append(pending)
                    pending = ""
        self.assertTrue(lines, "no `row pushed.sha256` line in the script")
        for line in lines:
            self.assertIn(
                '[ -n "$WANT" ]',
                line,
                "the pushed-copy row compares digests without the empty guard "
                "image.sha256 has: %s" % line.strip(),
            )
            self.assertIn(
                '[ -n "$GOT_REMOTE" ]',
                line,
                "the pushed-copy row does not fail when the remote digest is "
                "empty: %s" % line.strip(),
            )

    # -- W28-CI-02 ---------------------------------------------------------

    def test_a_second_failing_row_is_not_forgiven_by_the_metadata_refusal(self) -> None:
        """The escape hatch counted rows: any other single FAIL rode along.

        A stale list whose digest disagrees is the cheapest second FAIL to
        reach: the old script emitted no row for it at all, so `CHECK_FAILED`
        stayed at 1 (the metadata row) and --execute forgave the list, pushed,
        and asked the device about an image whose digest list describes a
        different build.
        """
        image = self.put_image(trailer=False, sums="mismatch", stale=True)
        run = self.execute(image, SSH_REMOTE_SUMS_FAIL="1")
        self.assertNotEqual(
            run.returncode,
            0,
            "a stale digest list that disagrees with the image was forgiven:\n%s%s"
            % (run.stdout, run.stderr),
        )
        self.assertNotIn("plan (each step", run.stdout, run.stdout)
        self.assertFalse(
            self.sysupgrade_log.exists(),
            "sysupgrade ran although the digest list was stale: %s"
            % (self.sysupgrade_log.read_text() if self.sysupgrade_log.exists() else "no log"),
        )

    def test_no_metadata_bypass_or_force_flag_remains(self) -> None:
        """P0-1: REQUIRE_IMAGE_METADATA=1 must never arm -F or clear CHECK_FAILED.

        Now that recovery images carry a FWx0 append-metadata trailer (#387),
        any missing-metadata refusal is final on both dry-run and --execute,
        and sysupgrade must never be invoked with -F.
        """
        text = RECOVERY.read_text()
        self.assertNotIn("FORCE_FLAG=-F", text, "FORCE_FLAG=-F is still armed")
        self.assertNotIn("METADATA_REFUSED", text, "METADATA_REFUSED bypass is still present")
        self.assertNotIn("sysupgrade -T -F", text, "sysupgrade -T -F is still present")
        self.assertNotIn("sysupgrade -F", text, "sysupgrade -F is still present")

    def test_a_digest_mismatch_next_to_a_refused_trailer_aborts(self) -> None:
        """Two FAILs abort with EXIT_CHECK and push nothing."""
        image = self.put_image(trailer=False, sums="mismatch")
        run = self.execute(image)
        self.assertEqual(
            run.returncode,
            EXIT_CHECK,
            "a digest mismatch next to a refused trailer must still exit %d, "
            "got %d:\n%s%s" % (EXIT_CHECK, run.returncode, run.stdout, run.stderr),
        )
        self.assertIn("cannot run as-is", run.stderr, run.stdout + run.stderr)
        self.assertEqual(
            sorted(p.name for p in self.dev.iterdir()),
            [],
            "the image was pushed although the digest did not match",
        )
        self.assertFalse(self.sysupgrade_log.exists())

    def test_missing_trailer_is_refused_even_on_execute(self) -> None:
        """P0-1: absent FWx0 trailer aborts --execute without pushing or forcing."""
        image = self.put_image(trailer=False, sums="match")
        run = self.execute(image)
        self.assertEqual(
            run.returncode,
            EXIT_CHECK,
            "missing metadata trailer was bypassed on --execute (rc %d):\n%s%s"
            % (run.returncode, run.stdout, run.stderr),
        )
        self.assertEqual(
            sorted(p.name for p in self.dev.iterdir()),
            [],
            "a trailer-less image was pushed to the device",
        )
        self.assertFalse(
            self.sysupgrade_log.exists(),
            "sysupgrade ran for a trailer-less image on REQUIRE_IMAGE_METADATA=1",
        )

    def test_trailer_bearing_image_executes_without_force(self) -> None:
        """Happy path: trailer-bearing image executes sysupgrade -n (never -F)."""
        image = self.put_image(trailer=True, sums="match")
        run = self.execute(image)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertTrue(self.sysupgrade_log.exists(), "sysupgrade never ran")
        log = self.sysupgrade_log.read_text()
        self.assertIn("sysupgrade -T ", log)
        self.assertIn("sysupgrade -n ", log)
        self.assertNotIn("-F", log, "sysupgrade was invoked with -F:\n%s" % log)
        pushed = [
            line for line in self.rows(run.stdout, "pushed.sha256")
            if self.verdict_of(line) == "PASS"
        ]
        self.assertEqual(len(pushed), 1, run.stdout)

    def test_execute_exits_nonzero_when_sysupgrade_fails(self) -> None:
        """A failed sysupgrade -n must exit non-zero, never 0."""
        image = self.put_image(trailer=True, sums="match")
        run = self.execute(image, SSH_SYSUPGRADE_FAIL="1")
        self.assertNotEqual(
            run.returncode,
            0,
            "--execute exited 0 after sysupgrade -n failed:\n%s%s"
            % (run.stdout, run.stderr),
        )
        sys_rows = self.rows(run.stdout, "sysupgrade ")
        self.assertTrue(sys_rows, "no failing sysupgrade row:\n%s" % run.stdout)
        self.assertEqual(self.verdict_of(sys_rows[0]), "FAIL", sys_rows[0])

    def test_remote_digest_mismatch_stops_before_sysupgrade(self) -> None:
        image = self.put_image(trailer=True, sums="match")
        # The pushed copy lands byte-identical; lie about the local list instead
        # by making the remote answer a different digest.
        (self.fix / "remote_sha").write_text("f" * 64 + "\n")
        run = self.execute(image)
        self.assertEqual(run.returncode, EXIT_IMAGE, run.stdout + run.stderr)
        self.assertFalse(
            self.sysupgrade_log.exists(),
            "sysupgrade -T ran although the pushed bytes did not verify",
        )

    # -- W28-CI-03 (recovery half) ----------------------------------------

    def test_stale_sums_that_still_match_the_digest_are_reported_not_refused(self) -> None:
        """An older list is a diagnosis, not a verdict, when its digest matches.

        ``cp -p``, ``rsync -t`` and a CI artifact download copy both files
        byte-for-byte and keep the list's mtime, so its age must not keep a
        good image out: the bytes are already proved by the digest row.
        """
        image = self.put_image(trailer=True, sums="match", stale=True)
        run = self.run_script("-i", str(image))
        self.assertEqual(
            run.returncode,
            0,
            "a stale list whose digest matches must not refuse the image:\n%s%s"
            % (run.stdout, run.stderr),
        )
        fresh = self.rows(run.stdout, "image.sums.fresh")
        self.assertTrue(fresh, "no image.sums.fresh row:\n%s" % run.stdout)
        self.assertEqual(self.verdict_of(fresh[0]), "SKIP", fresh[0])
        self.assertIn("stale, digest matches", fresh[0])
        self.assertIn("plan (each step", run.stdout)

    def test_the_allow_stale_switch_is_gone(self) -> None:
        """r28 §4.1: the gates get evidence, not an mtime-forgiveness switch."""
        image = self.put_image(trailer=True, sums="match", stale=True)
        run = self.run_script("-i", str(image), "--allow-stale-sums")
        self.assertEqual(
            run.returncode,
            EXIT_USAGE,
            "the removed --allow-stale-sums switch is still accepted (rc %d):\n%s%s"
            % (run.returncode, run.stdout, run.stderr),
        )
        self.assertIn("unknown option", run.stderr, run.stderr)

    def test_stale_sums_that_disagree_are_refused_with_the_reason(self) -> None:
        """The real red half: stale *and* a different digest is still a FAIL."""
        image = self.put_image(trailer=True, sums="mismatch", stale=True)
        run = self.run_script("-i", str(image))
        self.assertEqual(
            run.returncode,
            EXIT_CHECK,
            "a stale list whose digest disagrees must refuse with %d, got "
            "%d:\n%s%s" % (EXIT_CHECK, run.returncode, run.stdout, run.stderr),
        )
        digest = self.rows(run.stdout, "image.sha256")
        self.assertTrue(digest, "no image.sha256 row:\n%s" % run.stdout)
        self.assertEqual(self.verdict_of(digest[0]), "FAIL", digest[0])
        fresh = self.rows(run.stdout, "image.sums.fresh")
        self.assertTrue(fresh, "no image.sums.fresh row:\n%s" % run.stdout)
        self.assertEqual(self.verdict_of(fresh[0]), "FAIL", fresh[0])
        self.assertIn("stale", run.stderr, run.stderr)
        self.assertIn("sha256sums", run.stderr, run.stderr)
        self.assertIn("recompute", run.stderr, run.stderr)

    def test_fresh_sums_are_not_reported_as_stale(self) -> None:
        image = self.put_image(trailer=True, sums="match")
        run = self.run_script("-i", str(image))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        fresh = self.rows(run.stdout, "image.sums.fresh")
        self.assertTrue(fresh, "no image.sums.fresh row:\n%s" % run.stdout)
        self.assertEqual(self.verdict_of(fresh[0]), "PASS", fresh[0])

    # -- r05 ---------------------------------------------------------------

    def test_bad_crc_does_not_turn_the_tool_default_into_a_board_failure(self) -> None:
        self.write_probe(ENV_DEFAULT)
        image = self.put_image(trailer=True, sums="match")
        run = self.run_script("-i", str(image))
        loadaddr = self.rows(run.stdout, "bootenv.loadaddr")
        self.assertTrue(loadaddr, "no bootenv.loadaddr row:\n%s" % run.stdout)
        self.assertNotEqual(
            self.verdict_of(loadaddr[0]),
            "FAIL",
            "loadaddr=0x0 from fw_printenv's default env was reported as a "
            "board failure: %s" % loadaddr[0],
        )
        self.assertIn("unknown", loadaddr[0].lower(), loadaddr[0])
        self.assertIn("uninitialized", run.stderr, run.stderr)
        self.assertEqual(
            run.returncode,
            0,
            "a fresh board with an empty env must still produce a plan:\n%s%s"
            % (run.stdout, run.stderr),
        )

    def test_a_readable_env_still_judges_loadaddr(self) -> None:
        """The check is not gone: a stored loadaddr below the kernel end FAILs."""
        self.write_probe(ENV_STORED.replace("loadaddr=0x85000000", "loadaddr=0x81800000"))
        image = self.put_image(trailer=True, sums="match")
        run = self.run_script("-i", str(image))
        loadaddr = self.rows(run.stdout, "bootenv.loadaddr")
        self.assertTrue(loadaddr, run.stdout)
        self.assertEqual(self.verdict_of(loadaddr[0]), "FAIL", loadaddr[0])
        self.assertEqual(run.returncode, EXIT_CHECK, run.stdout + run.stderr)

    def test_bad_crc_with_wrong_fw_env_size_fails_bootenv_envsize(self) -> None:
        """Bad CRC + fw_env.config != 0x4000 must FAIL bootenv.envsize, not SKIP loadaddr."""
        self.write_probe(ENV_DEFAULT, fw_env=FW_ENV_BAD)
        image = self.put_image(trailer=True, sums="match")
        run = self.run_script("-i", str(image))
        self.assertEqual(
            run.returncode,
            EXIT_CHECK,
            "Bad CRC with envsize=0x1f000 was waved through (rc %d):\n%s%s"
            % (run.returncode, run.stdout, run.stderr),
        )
        envsize = self.rows(run.stdout, "bootenv.envsize")
        self.assertTrue(envsize, "no bootenv.envsize row:\n%s" % run.stdout)
        self.assertEqual(self.verdict_of(envsize[0]), "FAIL", envsize[0])
        loadaddr_skip = [
            line for line in self.rows(run.stdout, "bootenv.loadaddr")
            if self.verdict_of(line) == "SKIP"
        ]
        self.assertEqual(
            loadaddr_skip,
            [],
            "bootenv.loadaddr was SKIPped despite wrong fw_env.config envsize:\n%s"
            % run.stdout,
        )

    def test_fw_env_accepts_padded_hex_and_decimal_16384_without_globbing(self) -> None:
        """0x00004000 and 16384 equal 0x4000; a glob '*' envsize fails without expanding."""
        self.write_probe(ENV_STORED, fw_env=FW_ENV_ALT_GOOD)
        image = self.put_image(trailer=True, sums="match")
        run = self.run_script("-i", str(image))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        envsize = self.rows(run.stdout, "bootenv.envsize")
        self.assertTrue(envsize, run.stdout)
        self.assertEqual(self.verdict_of(envsize[0]), "PASS", envsize[0])

        self.write_probe(ENV_DEFAULT, fw_env="/dev/ubi0_0 0x0 * 0x1f000 1\n")
        run_glob = self.run_script("-i", str(image))
        self.assertEqual(run_glob.returncode, EXIT_CHECK, run_glob.stdout + run_glob.stderr)
        envsize_glob = self.rows(run_glob.stdout, "bootenv.envsize")
        self.assertTrue(envsize_glob, run_glob.stdout)
        self.assertEqual(self.verdict_of(envsize_glob[0]), "FAIL", envsize_glob[0])
        self.assertIn("actual=*", envsize_glob[0])

    def test_tiny_image_under_16_bytes_is_not_treated_as_trailer(self) -> None:
        """An image shorter than the 16-byte trailer cannot pass image.metadata."""
        tiny = self.imgdir / IMG_NAME
        data = b"FWx0" + b"\x00" * 4  # 8 bytes: starts with FWx0, too short for 16B trailer
        tiny.write_bytes(data)
        (self.imgdir / "sha256sums").write_text("%s *%s\n" % (sha256(data), IMG_NAME))
        run = self.run_script("-i", str(tiny))
        self.assertEqual(run.returncode, EXIT_CHECK, run.stdout + run.stderr)
        meta = self.rows(run.stdout, "image.metadata")
        self.assertTrue(meta, run.stdout)
        self.assertEqual(self.verdict_of(meta[0]), "FAIL", meta[0])

    def test_malformed_loadaddr_fails_cleanly_without_arithmetic_error(self) -> None:
        """Non-numeric or 64-bit-overflowing loadaddr must fail cleanly without crashing $((...))."""
        for bad_val in (
            "0xZZ_bad",
            "0850",
            "1+1",
            "0x8000000000000000",
            "0x10000000000000000",
            "99999999999999999999",
        ):
            with self.subTest(loadaddr=bad_val):
                self.write_probe(
                    ENV_STORED.replace("loadaddr=0x85000000", f"loadaddr={bad_val}")
                )
                image = self.put_image(trailer=True, sums="match")
                run = self.run_script("-i", str(image))
                self.assertEqual(run.returncode, EXIT_CHECK, run.stdout + run.stderr)
                loadaddr = self.rows(run.stdout, "bootenv.loadaddr")
                self.assertTrue(
                    loadaddr,
                    "script crashed before printing bootenv.loadaddr:\n%s%s"
                    % (run.stdout, run.stderr),
                )
                self.assertEqual(self.verdict_of(loadaddr[0]), "FAIL", loadaddr[0])
                self.assertNotIn("Illegal number", run.stderr, run.stderr)
                self.assertNotIn("Arithmetic", run.stderr, run.stderr)

    def test_default_dir_uses_repo_scratch_and_rollback_command_is_valid(self) -> None:
        """Default restore dir uses $TOP/.scratch/recovery and rollback chains && without '<'."""
        image = self.put_image(trailer=True, sums="match")
        run = self.run_script("-i", str(image))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("/home/l1n/", run.stdout, run.stdout)
        self.assertIn(str(self.tree / ".scratch/recovery/recovery-boot-"), run.stdout)
        self.assertIn(
            "ubirmvol /dev/ubi0 -N rootfs_data; ubirmvol /dev/ubi0 -N fit && "
            "ubimkvol /dev/ubi0 -N fit -n 2 -s 16760832 &&",
            run.stdout,
            run.stdout,
        )
        self.assertIn(
            "ubimkvol /dev/ubi0 -N rootfs_data -m && ubiupdatevol /dev/ubi0_2 fit-slot.bin",
            run.stdout,
            run.stdout,
        )
        self.assertNotIn(
            "ubiupdatevol /dev/ubi0_2 < fit-slot.bin", run.stdout, run.stdout
        )


class FlashGateDigest(unittest.TestCase):
    """scripts/flash-gate.sh: the same stale-list row, one gate over."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="flashgate-hashes-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.imgdir = self.tmp / "image"
        self.imgdir.mkdir()
        self.image = self.imgdir / "image.itb"

    def put_image(self, stale: bool, digest_matches: bool = True) -> Path:
        data = (
            b"\xd0\x0d\xfe\xed"
            + struct.pack(">I", 4096)
            + b"\x00" * 4096
            + b'{"compat_version":"2.0","supported_devices":["%s"]}' % BOARD.encode()
        )
        sums = self.imgdir / "sha256sums"
        digest = sha256(data) if digest_matches else "0" * 64
        if stale:
            sums.write_text("%s *image.itb\n" % digest)
            t_old = time.time() - 3600
            os.utime(sums, (t_old, t_old))
            self.image.write_bytes(data)
            t_new = t_old + 1800
            os.utime(self.image, (t_new, t_new))
        else:
            self.image.write_bytes(data)
            sums.write_text("%s *image.itb\n" % digest)
        return self.image

    def run_gate(self, *extra: str, **env_extra: str) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = "%s:%s" % (self.bin, env.get("PATH", ""))
        env["FG_BOARD_NAME"] = BOARD
        env.update(env_extra)
        return subprocess.run(
            [
                shutil.which("sh"),
                str(FLASH_GATE),
                "--image",
                str(self.image),
                "--no-layout",
                "--no-backup",
                "--no-sysupgrade",
                *extra,
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )

    def test_stale_sums_that_match_are_a_warning_not_a_refusal(self) -> None:
        """A stale list that still names this file's digest proved the bytes."""
        self.put_image(stale=True)
        run = self.run_gate()
        self.assertEqual(
            run.returncode,
            0,
            "a stale list whose digest matches must not keep the image out:\n%s%s"
            % (run.stdout, run.stderr),
        )
        stale = [line for line in run.stdout.splitlines() if "image.sums.fresh" in line]
        self.assertTrue(stale, "no image.sums.fresh row:\n%s" % run.stdout)
        self.assertEqual(stale[0].split()[-1], "SKIP", stale[0])
        self.assertIn("stale, digest matches", stale[0])
        self.assertIn("GATE PASS", run.stdout)

    def test_stale_sums_that_disagree_are_refused_with_the_reason(self) -> None:
        self.put_image(stale=True, digest_matches=False)
        run = self.run_gate()
        self.assertEqual(
            run.returncode,
            EXIT_CHECK,
            "a stale list whose digest disagrees must exit %d, got %d:\n%s%s"
            % (EXIT_CHECK, run.returncode, run.stdout, run.stderr),
        )
        self.assertIn("sha256 mismatch", run.stderr, run.stderr)
        self.assertIn("older than", run.stderr, run.stderr)
        self.assertIn("recompute", run.stderr, run.stderr)
        self.assertNotIn("GATE PASS", run.stdout)

    def test_fresh_sums_pass(self) -> None:
        self.put_image(stale=False)
        run = self.run_gate()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("GATE PASS", run.stdout)

    def test_the_explicit_digest_is_the_way_past_stale_sums(self) -> None:
        """FG_IMAGE_SHA256 is the documented escape valve: it names the digest
        for this file, so the age of the list is no longer evidence about it."""
        self.put_image(stale=True)
        digest = sha256(self.image.read_bytes())
        run = self.run_gate(FG_IMAGE_SHA256=digest)
        self.assertEqual(
            run.returncode,
            0,
            "FG_IMAGE_SHA256 did not get past a stale list:\n%s%s"
            % (run.stdout, run.stderr),
        )


if __name__ == "__main__":
    unittest.main()
