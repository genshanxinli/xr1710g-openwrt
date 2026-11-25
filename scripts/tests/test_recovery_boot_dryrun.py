#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The recovery image must never be booted from the production load address,
and the dry-run script must hash the UBI volume named ``fit``, not volume 0.

Two defects, both proved on paper before hardware:

P0  ``loadaddr=0x81800000``.  The recovery ITB's kernel-1 is an lzma payload
    that decompresses from 0x80200000 to 0x82AB0000 (42,663,936 B by the
    arm64 header).  ``boot_production`` reads the FIT to ``$loadaddr`` and ``bootm``
    then decompresses that kernel *on top of the FIT copy*; U-Boot stops with
    ``ERROR: new format image overwritten - must RESET the board to recover``
    (``boot/bootm.c``).  The production sysupgrade kernel ends at 0x81166808,
    so 0x81800000 was fine for production and impossible for recovery.

    The safe window is between ``npu-binary@84000000`` (10 MiB, so
    ..0x84A00000) and ``ramoops@86ff0000`` (64 KiB): ``loadaddr=0x85000000``
    leaves the FIT copy at 0x85000000..0x85DC0000 (14.3 MiB image + slack)
    entirely below ramoops and entirely above the kernel end.

P1-6  ``/dev/ubi0_0``.  The DTS volume order is ubootenv(0), ubootenv2(1),
    fit(2), factory(3); volume 0 is the 128 KiB U-Boot environment.  The
    script hashed and backed up volume 0 and then compared that hash with
    itself, so a "verified restore point" was 128 KiB of env.

F2  The trailer probe piped through ``od``.  The XR1710G image ships BusyBox
    with ``CONFIG_HEXDUMP=y`` and no ``od`` applet, so the live run printed
    ``recovery-boot-dryrun.sh: line 279: od: not found`` and ``TRAILER_MAGIC``
    came out empty: every image, metadata-bearing or not, read as "no
    trailer".  The probe now uses ``hexdump -v -e '1/1 "%02x"'``, which is the
    same bytes on GNU/BSD hexdump and on BusyBox 1.38
    (``util-linux/hexdump.c`` usage: ``[-bcdoxCv] [-e FMT] [-f FMT_FILE]``).

N1 (second half)  The dry-run reported a metadata-free recovery ITB PASS
    ("no fwtool trailer (needs -F)") and planned ``sysupgrade -F -n``.  On a
    ``REQUIRE_IMAGE_METADATA=1`` board absent metadata is rc 74
    (fwtool.sh:39-42), validate_firmware_image:55-60 makes it non-forceable,
    and sysupgrade:407-414 exits 1 before any write: -F does not override it.
    The row now FAILs with that reason, and the script never arms ``-F``
    (planning plain ``sysupgrade -n`` only, never ``sysupgrade -F``).

``RECOVERY_DRYRUN_UNDER_TEST`` and ``XR1710G_UBOOT_PATCH_UNDER_TEST`` name
copies, the same convention scripts/tests/test_recovery_transfer.py:47 and
scripts/tests/test_recovery_tmp_cleanup.py:49 already use.  Red proof:

    git show HEAD:scripts/recovery-boot-dryrun.sh > /tmp/old-dryrun.sh
    git show HEAD:package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch \\
        > /tmp/old-999.patch
    RECOVERY_DRYRUN_UNDER_TEST=/tmp/old-dryrun.sh \\
    XR1710G_UBOOT_PATCH_UNDER_TEST=/tmp/old-999.patch \\
        python3 scripts/tests/test_recovery_boot_dryrun.py

The N1 half alone goes red against the pre-fix script:

    RECOVERY_DRYRUN_UNDER_TEST=/tmp/red-n1-opt2-dryrun.sh \\
        python3 scripts/tests/test_recovery_boot_dryrun.py
"""

from __future__ import annotations

import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("RECOVERY_DRYRUN_UNDER_TEST")
    or REPO_ROOT / "scripts/recovery-boot-dryrun.sh"
)
PATCH = Path(
    os.environ.get("XR1710G_UBOOT_PATCH_UNDER_TEST")
    or REPO_ROOT / "package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch"
)

# Recovery ITB layout facts measured from the 2026-11-23 recovery artifact.
KERNEL_LOAD = 0x80200000
KERNEL_IMAGE_SIZE = 0x28B0000  # arm64 header image_size of the recovery kernel-1
KERNEL_END = KERNEL_LOAD + KERNEL_IMAGE_SIZE  # 0x82AB0000
FIT_BYTES = 0x1000000  # 16 MiB ceiling: the ITB is 14,417,920 B today

# target/linux/airoha/dts/an7581.dtsi reserved-memory, in the boot window.
RESERVED = (
    ("npu-binary", 0x84000000, 0x84A00000),
    ("ramoops", 0x86FF0000, 0x87000000),
)

DEFENV_HEADER = "+++ b/defenvs/an7581_xr1710g_env"


def defenv(text: str) -> dict[str, str]:
    """Environment variables from the defenv added by the xr1710g patch."""
    out: dict[str, str] = {}
    inside = False
    for line in text.splitlines():
        if line.startswith("+++ "):
            inside = line == DEFENV_HEADER
            continue
        if not inside or not line.startswith("+"):
            continue
        body = line[1:].strip()
        if not body or body.startswith("#") or "=" not in body:
            continue
        key, _, value = body.partition("=")
        out[key.strip()] = value.strip()
    return out


class LoadAddr(unittest.TestCase):
    def setUp(self) -> None:
        self.env = defenv(PATCH.read_text())

    def test_loadaddr_clears_the_recovery_kernel(self) -> None:
        loadaddr = int(self.env["loadaddr"], 0)
        self.assertGreaterEqual(
            loadaddr,
            KERNEL_END,
            "loadaddr %#x sits inside the recovery decompression window "
            "0x80200000..%#x; bootm ends in BOOTM_ERR_RESET" % (loadaddr, KERNEL_END),
        )
        self.assertLessEqual(
            loadaddr + FIT_BYTES,
            0x100000000,
            "loadaddr %#x + %#x leaves 32-bit address space" % (loadaddr, FIT_BYTES),
        )

    def test_fit_copy_stays_out_of_reserved_memory(self) -> None:
        loadaddr = int(self.env["loadaddr"], 0)
        for name, start, end in RESERVED:
            self.assertFalse(
                start < loadaddr + FIT_BYTES and end > loadaddr,
                "the FIT copy at %#x..%#x overlaps %s@%#x..%#x"
                % (loadaddr, loadaddr + FIT_BYTES, name, start, end),
            )

    def test_tftp_initaddr_stays_out_of_reserved_memory(self) -> None:
        initaddr = int(self.env["initaddr"], 0)
        self.assertGreaterEqual(initaddr, KERNEL_END)
        self.assertLessEqual(initaddr + FIT_BYTES, 0x8A000000)  # npu-pkt

    def test_boot_production_reads_the_fit_at_loadaddr(self) -> None:
        self.assertIn("ubi read $loadaddr fit", self.env["ubi_read_production"])
        self.assertIn("bootm $loadaddr#$bootconf", self.env["boot_production"])

    def test_bootcmd_and_bootmenu_are_well_formed(self) -> None:
        self.assertEqual(self.env["bootcmd"], "run boot_ubi")
        self.assertIn("ubi part ubi", self.env["bootmenu_0"])
        self.assertIn("run boot_production", self.env["bootmenu_0"])
        self.assertLess(
            self.env["bootmenu_0"].index("ubi part ubi"),
            self.env["bootmenu_0"].index("run boot_production"),
        )
        self.assertNotIn("34m", self.env["bootmenu_title"])
        self.assertNotIn("mOpenWrt", self.env["bootmenu_title"])
        # CONFIG_SYS_MAXARGS=8: boot_recovery's echo message must be quoted
        # so U-Boot receives 2 args instead of 14.
        self.assertTrue(
            self.env["boot_recovery"].startswith('echo "')
            and self.env["boot_recovery"].endswith('"'),
            f"boot_recovery exceeds CONFIG_SYS_MAXARGS=8 unless quoted: {self.env['boot_recovery']!r}",
        )


class FitVolume(unittest.TestCase):
    """P1-6: the script must hash the volume named ``fit``, whatever its id."""

    def setUp(self) -> None:
        self.text = SCRIPT.read_text()

    def test_no_hardcoded_ubi0_0(self) -> None:
        self.assertNotIn(
            "ubi0_0",
            self.text,
            "the FIT volume is id 2 in the four-volume layout; volume 0 is "
            "the 128 KiB ubootenv",
        )

    def test_every_ubi_device_uses_the_resolved_id(self) -> None:
        self.assertIn("ubi_volume_id", self.text)
        for line in self.text.splitlines():
            if line.lstrip().startswith("#") or "/dev/ubi0_" not in line:
                continue
            for chunk in line.split("/dev/ubi0_")[1:]:
                head = chunk.split()[0]
                self.assertTrue(
                    head.startswith(("${FIT_ID}", "$FIT_ID", "${fit_id}", "$fit_id")),
                    "%s: /dev/ubi0_%s is not the resolved volume id" % (line.strip(), head),
                )

    def test_self_test_passes(self) -> None:
        run = subprocess.run(
            ["sh", str(SCRIPT), "--self-test"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("parser checks OK", run.stdout)

    def test_self_test_catches_a_zero_id_fit(self) -> None:
        """A copy that hands out volume 0 for every name must fail --self-test."""
        bad = self.text.replace("id = $3", "id = 0")
        if bad == self.text:  # the awk body changed shape: keep the case honest
            self.skipTest("ubi_volume_id no longer reads $3 on the Volume ID line")
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "dryrun.sh"
            copy.write_text(bad)
            run = subprocess.run(
                ["sh", str(copy), "--self-test"], capture_output=True, text=True
            )
        self.assertNotEqual(run.returncode, 0, "self-test accepted fit==0")


FWTOOL_BIN = REPO_ROOT / "staging_dir/host/bin/fwtool"
MAGIC = b"FWx0"  # fwimage.h FWIMAGE_MAGIC 0x46577830, written with cpu_to_be32
REVERSED = b"0xwF"  # the byte order finding N1 predicted; fwtool does not write it
MAGIC_HEX = "46577830"  # od -An -tx1 of MAGIC
REVERSED_HEX = "30787746"  # od -An -tx1 of REVERSED


def synthetic_trailer(payload: bytes = b'{"compat_version":"1.0"}') -> bytes:
    """The bytes fwtool appends for ``-I``, per fwtool.c and fwimage.h.

    On-disk order is fwimage_header, payload, fwimage_trailer
    (fwtool.c:146-160); fwtool.c:192 writes ``tr.magic = cpu_to_be32(...)``,
    so the trailer's first four bytes are always big-endian.
    """
    header = struct.pack(">II", 0, 0)
    body = header + payload
    trailer = struct.pack(">IIB3xI", 0x46577830, 0, 1, 16 + len(body))
    return body + trailer


class FwtoolTrailer(unittest.TestCase):
    """N1: pin the trailer magic's byte order, the probe's position, and what
    the absence of a trailer actually costs on this board.

    fwtool writes ``fwimage_trailer.magic`` with ``cpu_to_be32``
    (fwtool.c:192; fwimage.h:18 is ``FWIMAGE_MAGIC 0x46577830 /* FWx0 */``),
    so a metadata-bearing image ends in a 16-byte trailer that starts with
    the bytes ``46 57 78 30``.  Finding N1 of commit_audit_08b.md calls that
    little-endian and prescribes ``... | grep -q 30787746``; that hex is the
    reversed bytes and matches no real trailer.  The probe compares the
    trailer position exactly instead of grepping 4096, so a literal ``FWx0``
    inside the FIT payload is ignored.

    The second half of N1: absent metadata is rc 74 on a
    ``REQUIRE_IMAGE_METADATA=1`` board (fwtool.sh:39-42), which
    validate_firmware_image:55-60 turns into ``forceable=0`` and sysupgrade:407-414
    refuses even with ``-F``.  The old script reported that image PASS
    ("no fwtool trailer (needs -F)") and printed a plan ending in
    ``sysupgrade -F -n``, i.e. it promised a flash the firmware rejects.
    """

    def fixture(self, directory: Path, trailer: bool) -> Path:
        image = directory / "recovery.itb"
        image.write_bytes(b"\x00" * 65536)
        if not trailer:
            return image
        metadata = directory / "metadata.json"
        metadata.write_text('{"compat_version":"1.0"}')
        if FWTOOL_BIN.exists():
            run = subprocess.run(
                [str(FWTOOL_BIN), "-I", str(metadata), str(image)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        else:
            image.write_bytes(image.read_bytes() + synthetic_trailer())
        return image

    def board(self, root: Path, require_metadata: bool) -> Path:
        """A copy of the script under its own TOP, with a platform.sh of our
        choosing: the only thing the metadata row reads from the tree."""
        copy = root / "scripts" / "recovery-boot-dryrun.sh"
        copy.parent.mkdir(parents=True)
        copy.write_text(SCRIPT.read_text())
        platform = root / "target/linux/airoha/an7581/base-files/lib/upgrade/platform.sh"
        platform.parent.mkdir(parents=True)
        platform.write_text("REQUIRE_IMAGE_METADATA=1\n" if require_metadata else "# nothing\n")
        return copy

    def plan(self, image: Path, work: Path, script: Path | None = None, shadow: tuple = ()):
        """Run the read-only plan far enough to print the image.metadata row."""
        stub = work / "bin"
        stub.mkdir()
        ssh = stub / "ssh"
        ssh.write_text("#!/bin/sh\nexit 1\n")
        ssh.chmod(0o755)
        for name in shadow:  # a tool the target image does not ship, e.g. od
            fake = stub / name
            fake.write_text('#!/bin/sh\necho "%s: not found" >&2\nexit 127\n' % name)
            fake.chmod(0o755)
        env = dict(os.environ)
        env["PATH"] = "%s:%s" % (stub, env.get("PATH", ""))
        return subprocess.run(
            ["sh", str(script or SCRIPT), "-i", str(image), "-H", "root@127.0.0.1"],
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
        )

    @staticmethod
    def metadata_line(stdout: str) -> str:
        for line in stdout.splitlines():
            if line.startswith("image.metadata"):
                return line
        return ""

    def verdict(self, stdout: str) -> str:
        line = self.metadata_line(stdout)
        return line.split()[-1] if line else ""

    def test_trailer_magic_on_disk_is_big_endian_fwx0(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            image = self.fixture(Path(tmp), trailer=True)
            data = image.read_bytes()
            tail = data[-16:]
        self.assertEqual(tail[:4], MAGIC, "trailer magic is not the FWx0 bytes")
        self.assertNotIn(REVERSED, data[-4096:])

    def test_synthetic_layout_matches_the_real_fwtool(self) -> None:
        if not FWTOOL_BIN.exists():
            self.skipTest("staging_dir/host/bin/fwtool not built")
        with tempfile.TemporaryDirectory() as tmp:
            real = self.fixture(Path(tmp), trailer=True)
            tail = real.read_bytes()[-16:]
        mine = synthetic_trailer()[-16:]
        self.assertEqual(tail[:4], mine[:4])
        self.assertEqual(tail[8:9], mine[8:9])  # FWIMAGE_INFO
        self.assertEqual(tail[12:], mine[12:])  # size covers header+payload+trailer

    def test_plan_reports_metadata_present_for_a_real_trailer(self) -> None:
        """A real ``fwtool -I`` trailer is the state that flashes cleanly."""
        with tempfile.TemporaryDirectory() as tmp:
            image = self.fixture(Path(tmp), trailer=True)
            run = self.plan(image, Path(tmp))
        self.assertEqual(self.verdict(run.stdout), "PASS", run.stdout + run.stderr)

    def test_metadata_free_image_is_refused_not_reported_as_needs_force(self) -> None:
        """N1: no trailer + REQUIRE_IMAGE_METADATA=1 is rc 74, not "needs -F"."""
        with tempfile.TemporaryDirectory() as tmp:
            image = self.fixture(Path(tmp), trailer=False)
            run = self.plan(image, Path(tmp))
        self.assertEqual(self.verdict(run.stdout), "FAIL", run.stdout + run.stderr)
        self.assertIn("rc 74", run.stdout, run.stdout + run.stderr)
        self.assertIn("not forceable", run.stdout, run.stdout + run.stderr)
        self.assertNotIn(
            "needs -F",
            run.stdout,
            "the dry-run still promises that -F is the way past absent metadata",
        )

    def test_refused_image_prints_no_flash_plan(self) -> None:
        """The plan ends in ``sysupgrade -F -n``; printing it for a refused
        image is the false promise N1 calls out."""
        with tempfile.TemporaryDirectory() as tmp:
            image = self.fixture(Path(tmp), trailer=False)
            run = self.plan(image, Path(tmp))
        self.assertIn("-F cannot override 74", run.stderr, run.stdout + run.stderr)
        self.assertNotIn("plan (each step", run.stdout, run.stdout + run.stderr)
        self.assertNotIn("sysupgrade -F -n", run.stdout, run.stdout + run.stderr)

    def test_board_without_the_requirement_accepts_no_trailer_without_force(self) -> None:
        """REQUIRE_IMAGE_METADATA unset: fwtool.sh:43-46 returns 0 without -F."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = self.fixture(root, trailer=False)
            script = self.board(root / "tree", require_metadata=False)
            run = self.plan(image, root, script=script)
        self.assertEqual(self.verdict(run.stdout), "PASS", run.stdout + run.stderr)

    def test_sysupgrade_force_and_metadata_bypass_are_removed(self) -> None:
        """P0-1: recovery-boot-dryrun.sh must never invoke sysupgrade -F or bypass metadata."""
        text = SCRIPT.read_text()
        self.assertNotIn(
            "no fwtool trailer (needs -F)",
            text,
            "the stale PASS verdict N1 quotes is back in the script",
        )
        self.assertNotIn("FORCE_FLAG=-F", text, "FORCE_FLAG=-F must not be armed")
        self.assertNotIn("METADATA_REFUSED", text, "METADATA_REFUSED bypass must not exist")
        self.assertNotIn("sysupgrade -T -F", text, "sysupgrade -T -F must not be invoked")
        self.assertNotIn("sysupgrade -F", text, "sysupgrade -F must not be invoked")
        self.assertIn("sysupgrade -n /tmp/$NAME", text)
        self.assertNotIn("/home/l1n/", text, "hardcoded personal home path remains")
        self.assertNotIn("ubiupdatevol /dev/ubi0_${FIT_ID} < fit-slot.bin", text)

    def test_payload_word_fwx0_is_not_a_trailer(self) -> None:
        """A literal "FWx0" inside the FIT payload must not read as metadata.

        A probe that greps the last 4096 bytes calls this image "trailer
        present"; only the four bytes at the trailer position count, which
        here means "tail is 0x00" (and, on this board, the refusal of the
        metadata-free image below).
        """
        with tempfile.TemporaryDirectory() as tmp:
            image = self.fixture(Path(tmp), trailer=False)
            data = bytearray(image.read_bytes())
            data[-100:-96] = MAGIC
            image.write_bytes(bytes(data))
            run = self.plan(image, Path(tmp))
        line = self.metadata_line(run.stdout)
        self.assertIn("rc 74", line, run.stdout + run.stderr)  # absent, not present
        self.assertNotIn("trailer present", line, run.stdout + run.stderr)

    def test_probe_reads_the_trailer_position(self) -> None:
        text = SCRIPT.read_text()
        self.assertTrue(
            "tail -c 16" in text,
            "the probe no longer reads the 16-byte trailer fwtool appends",
        )
        self.assertTrue(MAGIC_HEX in text, "the probe lost the big-endian FWx0 hex")
        self.assertFalse(
            REVERSED_HEX in text,
            "the probe greps the reversed hex, which no fwtool trailer carries",
        )

    def test_probe_does_not_shell_out_to_od(self) -> None:
        """F2: the probe must not depend on an applet the image does not ship."""
        text = SCRIPT.read_text()
        self.assertNotIn("od -An", text, "the trailer probe pipes through od again")
        self.assertIn(
            "hexdump -v -e",
            text,
            "the probe no longer dumps the four trailer bytes with hexdump",
        )

    def test_trailer_is_still_found_when_od_is_missing(self) -> None:
        """F2 red case: with od absent (as on the XR1710G) a real trailer must
        still read as present.  Against the od-based probe TRAILER_MAGIC is
        empty and the row turns FAIL."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = self.fixture(root, trailer=True)
            run = self.plan(image, root, shadow=("od",))
        self.assertEqual(self.verdict(run.stdout), "PASS", run.stdout + run.stderr)
        self.assertIn(
            "trailer present",
            self.metadata_line(run.stdout),
            "the row did not see the trailer; a missing probe tool is the F2 bug",
        )

    def test_audit_hex_probe_would_miss_the_real_magic(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            image = self.fixture(Path(tmp), trailer=True)
            self.assertNotEqual(
                subprocess.run(
                    ["sh", "-c",
                     'tail -c 4096 "$1" | od -An -tx1 | tr -d " \\n" | grep -q ' + REVERSED_HEX,
                     "sh", str(image)],
                ).returncode,
                0,
                "the audit's reversed hex probe matched a real trailer",
            )
            self.assertEqual(
                subprocess.run(
                    ["sh", "-c",
                     'tail -c 4096 "$1" | od -An -tx1 | tr -d " \\n" | grep -q ' + MAGIC_HEX,
                     "sh", str(image)],
                ).returncode,
                0,
                "the on-disk magic is not the big-endian hex",
            )


if __name__ == "__main__":
    unittest.main()
