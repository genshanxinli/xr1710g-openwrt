#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Recovery images must end in a well-formed fwtool trailer, and the recipes
must produce one.

``target/linux/airoha/*/base-files/lib/upgrade/platform.sh`` sets
``REQUIRE_IMAGE_METADATA=1``, so fwtool refuses a recovery image whose last 16
bytes are not a ``FWx0`` trailer.  Two independent halves are asserted:

  * product: each built ``*-initramfs-recovery.itb`` under an airoha subtarget
    that requires metadata ends in a valid trailer -- magic, ``type`` in
    {0 SIGNATURE, 1 INFO} (``CONFIG_SIGN_FIRMWARE=y`` turns the tail into a
    SIGNATURE once ``key-build`` exists, so pinning INFO would reject a correct
    image), zero pad bytes, ``size`` within fwtool's own limits, and -- when the
    tail is a SIGNATURE -- an INFO trailer immediately in front of it;
  * recipe: every device block whose ``KERNEL_INITRAMFS_SUFFIX`` is
    ``-recovery.itb`` ends its ``KERNEL_INITRAMFS`` recipe with
    ``append-metadata``.  This half needs no build, so it still fires on a
    fresh clone and catches the an7583-style omission.

When ``staging_dir/host/bin/fwtool`` exists, the product half also runs
``fwtool -i - <itb>`` and requires exit 0 plus JSON on stdout: the trailer must
be extractable, not merely look plausible.

The product build is a local witness, not a CI gate: with no ``bin/targets``
(or no recovery image at all) that half skips and says so -- the recipe half
still runs.

Red half (three injections; each verified against the pre-fix inputs below):

  1. product shape -- copy the built recovery image without its last 838 bytes
     (the pre-fix product): ``BIN_TARGETS_UNDER_TEST=<fixture>/bin/targets``
     ``AssertionError: b'\\x00\\x00\\x00\\x00' != b'FWx0' : ... last 16 bytes are
     not a FWx0 trailer``.
  2. trailer fields -- keep the ``FWx0`` magic, rewrite the last 16 bytes with
     type 7, then with type 1 and size 60000: ``unknown trailer type 7
     (0=SIGNATURE, 1=INFO)`` and ``implausible trailer size 60000 (expected
     24..30744)``.
  3. recipe -- ``an7583.mk`` with `` | append-metadata`` removed from the
     ``KERNEL_INITRAMFS`` line, copied under ``TARGET_LINUX_UNDER_TEST``:
     ``AssertionError: ["an7583.mk Device/nokia_xg-040g-mf-ubi: KERNEL_INITRAMFS
     recipe does not end with append-metadata ..."]``.

Against the unmodified tree both halves pass.
"""

from __future__ import annotations

import os
import pathlib
import re
import struct
import subprocess
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN_TARGETS = pathlib.Path(
    os.environ.get("BIN_TARGETS_UNDER_TEST") or REPO_ROOT / "bin" / "targets"
)
TARGET_LINUX = pathlib.Path(
    os.environ.get("TARGET_LINUX_UNDER_TEST") or REPO_ROOT / "target" / "linux"
)
FWTOOL = pathlib.Path(
    os.environ.get("FWTOOL_UNDER_TEST") or REPO_ROOT / "staging_dir" / "host" / "bin" / "fwtool"
)

# struct fwimage_trailer: magic, crc32, type, __pad[3], size -- all big endian.
TRAILER = struct.Struct(">IIB3sI")
FWX0 = b"FWx0"
SIGNATURE, INFO = 0, 1
METADATA_MAXLEN = 30 * 1024  # fwtool.c:25
SIGNATURE_MAXLEN = 1 * 1024  # fwtool.c:26
INFO_HEADER_LEN = 8  # struct fwimage_header
TRAILER_LEN = TRAILER.size

REQUIRE_RE = re.compile(r"^\s*REQUIRE_IMAGE_METADATA=1\b", re.MULTILINE)
BLOCK_RE = re.compile(r"(?m)^define Device/(\S+)\n(.*?)^endef$", re.S)
SUFFIX_RE = re.compile(r"KERNEL_INITRAMFS_SUFFIX\s*(?::=|\+=|=)\s*(\S*)")
RECIPE_RE = re.compile(r"(?m)^\s*KERNEL_INITRAMFS\s*(?::=|\+=|=)\s*([^\n]*)")


def _requires_image_metadata(target: str, subtarget: str) -> bool:
    candidates = [
        TARGET_LINUX / target / subtarget / "base-files" / "lib" / "upgrade" / "platform.sh",
        TARGET_LINUX / target / "base-files" / "lib" / "upgrade" / "platform.sh",
    ]
    for path in candidates:
        if path.is_file():
            text = path.read_text(encoding="utf-8", errors="replace")
            if REQUIRE_RE.search(text):
                return True
    return False


def _metadata_subtargets() -> list[tuple[str, str]]:
    """Airoha subtargets whose platform.sh requires fwtool metadata.

    Only airoha: elsewhere ``REQUIRE_IMAGE_METADATA=1`` gates TFTP/ramboot
    products that never pass through ``sysupgrade``.  Here the recovery FIT is
    the sysupgrade payload (``scripts/recovery-boot-dryrun.sh`` says why).
    """
    found: list[tuple[str, str]] = []
    for platform in sorted(
        (TARGET_LINUX / "airoha").glob("*/base-files/lib/upgrade/platform.sh")
    ):
        if REQUIRE_RE.search(platform.read_text(encoding="utf-8", errors="replace")):
            # .../airoha/<subtarget>/base-files/lib/upgrade/platform.sh
            found.append(("airoha", platform.parents[3].name))
    return found


def _device_blocks(text: str) -> list[tuple[str, str]]:
    """(name, block) for every ``define Device/...``; continuations joined."""
    joined = re.sub(r"\\\n", " ", text)
    return [(match.group(1), match.group(2)) for match in BLOCK_RE.finditer(joined)]


def _trailer_at(data: bytes, end: int) -> dict:
    if end < TRAILER_LEN:
        raise AssertionError(
            f"only {end} bytes before the tail: no room for a {TRAILER_LEN}-byte trailer"
        )
    magic, crc, kind, pad, size = TRAILER.unpack_from(data, end - TRAILER_LEN)
    return {
        "magic": magic.to_bytes(4, "big"),
        "crc": crc,
        "type": kind,
        "pad": pad,
        "size": size,
        "end": end,
    }


class RecoveryMetadataTrailerTests(unittest.TestCase):
    def _assert_trailer(self, data: bytes, end: int, label: str, want_type: int | None = None) -> dict:
        trailer = _trailer_at(data, end)
        self.assertEqual(trailer["magic"], FWX0, f"{label}: last 16 bytes are not a FWx0 trailer")
        if want_type is None:
            self.assertIn(
                trailer["type"],
                (SIGNATURE, INFO),
                f"{label}: unknown trailer type {trailer['type']} (0=SIGNATURE, 1=INFO)",
            )
        else:
            self.assertEqual(trailer["type"], want_type, f"{label}: expected trailer type {want_type}")
        self.assertEqual(trailer["pad"], b"\0\0\0", f"{label}: trailer pad bytes must be zero")
        size = trailer["size"]
        self.assertLessEqual(size, end, f"{label}: trailer size {size} exceeds the {end} bytes before it")
        if trailer["type"] == INFO:
            minimum = TRAILER_LEN + INFO_HEADER_LEN
            maximum = METADATA_MAXLEN + INFO_HEADER_LEN + TRAILER_LEN
        else:
            minimum, maximum = TRAILER_LEN, SIGNATURE_MAXLEN + TRAILER_LEN
        self.assertTrue(
            minimum <= size <= maximum,
            f"{label}: implausible trailer size {size} (expected {minimum}..{maximum})",
        )
        if trailer["type"] == SIGNATURE:
            # A signed build appends SIGNATURE after INFO; fwtool walks back.
            info_end = end - size
            self._assert_trailer(data, info_end, f"{label} (behind the signature)", want_type=INFO)
        return trailer

    def test_built_recovery_images_have_a_valid_fwtool_trailer_when_metadata_required(self) -> None:
        if not BIN_TARGETS.is_dir():
            self.skipTest(
                "bin/targets is not present: no build to inspect; "
                "the recipe test still guards the image recipes"
            )

        checked = 0
        for subtarget_dir in sorted(BIN_TARGETS.glob("*/*")):
            if not subtarget_dir.is_dir():
                continue
            if not _requires_image_metadata(subtarget_dir.parent.name, subtarget_dir.name):
                continue

            for recovery_img in sorted(subtarget_dir.glob("*-initramfs-recovery.itb")):
                checked += 1
                data = recovery_img.read_bytes()
                self.assertGreaterEqual(
                    len(data), TRAILER_LEN, f"{recovery_img} is smaller than {TRAILER_LEN} bytes"
                )
                self._assert_trailer(data, len(data), str(recovery_img))

        if checked == 0:
            self.skipTest(
                "no built *-initramfs-recovery.itb under bin/targets/*/*: "
                "run make image to get a product witness; the recipe test still runs"
            )

    def test_fwtool_extracts_the_metadata_from_the_built_recovery_image(self) -> None:
        if not BIN_TARGETS.is_dir():
            self.skipTest("bin/targets is not present: no build to inspect")
        images = [
            path
            for subtarget_dir in sorted(BIN_TARGETS.glob("*/*"))
            if subtarget_dir.is_dir()
            and _requires_image_metadata(subtarget_dir.parent.name, subtarget_dir.name)
            for path in sorted(subtarget_dir.glob("*-initramfs-recovery.itb"))
        ]
        if not images:
            self.skipTest("no built *-initramfs-recovery.itb to feed to fwtool")
        if not FWTOOL.is_file():
            self.skipTest(
                f"{FWTOOL} is not built; staging_dir/host/bin/fwtool is the extractor"
            )

        for image in images:
            # ``-i -`` writes the metadata to the FILE that ``-`` names (stdout);
            # ``-i /dev/stdout`` fails silently when stdout is a socketpair.
            result = subprocess.run(
                [str(FWTOOL), "-i", "-", str(image)],
                capture_output=True,
                timeout=60,
            )
            self.assertEqual(
                result.returncode, 0,
                f"fwtool -i - {image} exited {result.returncode}: "
                f"{result.stderr.decode(errors='replace').strip()[:300]}",
            )
            self.assertTrue(
                result.stdout.lstrip().startswith(b"{"),
                f"fwtool -i - {image} did not print metadata JSON: "
                f"{result.stdout[:120]!r}",
            )

    def test_recovery_recipes_end_with_append_metadata(self) -> None:
        subtargets = _metadata_subtargets()
        self.assertTrue(
            subtargets,
            f"no airoha subtarget sets REQUIRE_IMAGE_METADATA=1 under {TARGET_LINUX / 'airoha'}",
        )

        checked = 0
        problems: list[str] = []
        for target, subtarget in subtargets:
            image_mk = TARGET_LINUX / target / "image" / f"{subtarget}.mk"
            self.assertTrue(
                image_mk.is_file(),
                f"{target}/{subtarget} requires image metadata but {image_mk} is missing",
            )
            for device, block in _device_blocks(image_mk.read_text(encoding="utf-8")):
                suffix = SUFFIX_RE.search(block)
                if suffix is None or "-recovery.itb" not in suffix.group(1):
                    continue
                checked += 1
                recipe = RECIPE_RE.search(block)
                if recipe is None:
                    problems.append(f"{image_mk.name} Device/{device}: no KERNEL_INITRAMFS recipe")
                    continue
                if not recipe.group(1).strip().endswith("append-metadata"):
                    problems.append(
                        f"{image_mk.name} Device/{device}: KERNEL_INITRAMFS recipe does not "
                        f"end with append-metadata ({recipe.group(1).strip()[:80]!r})"
                    )

        self.assertTrue(checked, "no device block produces a -recovery.itb; the parser went stale")
        self.assertFalse(problems, "\n".join(problems))


if __name__ == "__main__":
    unittest.main()
