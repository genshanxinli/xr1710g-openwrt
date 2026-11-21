"""Recovery image facts and the rdinit gap (#12).

What this pins, without hardware:

* the built ``initramfs-recovery.itb`` is a FIT whose kernel sub-image carries
  a newc cpio holding both the ``/init`` shim and ``/sbin/init`` (procd);
* nothing in the image generation path sets ``rdinit``: the board command line
  ``... rdinit=/sbin/init`` comes from the vendor U-Boot environment, which is
  not built by this tree;
* because that bypasses ``/init`` (the only place that exported ``INITRAMFS=1``),
  ``lib/preinit/70_initramfs_test`` has to recover the flag itself, at source
  time, when ``/`` is still the kernel rootfs.
"""
from __future__ import annotations

import lzma
import os
import struct
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
IMAGE_DIR = "target/linux/airoha/image"
KERNEL_DEFAULTS = "include/kernel-defaults.mk"
INIT_SHIM = "target/linux/generic/other-files/init"
DTB = "target/linux/airoha/dts/an7581-xr1710g-ubi.dts"
PREINIT_HOOK = "package/base-files/files/lib/preinit/70_initramfs_test"
RDINIT_SCOPE = (
    IMAGE_DIR,
    KERNEL_DEFAULTS,
    INIT_SHIM,
    DTB,
    "package/base-files/files",
    "package/boot/uboot-airoha",
)
NEWC_MAGIC = b"070701"
NEWC_HEADER = 110


def _align4(offset: int) -> int:
    return (offset + 3) // 4 * 4


def _fit_props(data: bytes) -> list[tuple[str, str, bytes]]:
    """Walk the FIT's FDT struct block: (node path, property, value)."""
    _, _, off_struct, off_strings, _, _, _, _, size_strings, _ = struct.unpack(
        ">10I", data[:40]
    )
    strings = data[off_strings : off_strings + size_strings]
    pos, path, props = off_struct, [], []
    while True:
        token = struct.unpack(">I", data[pos : pos + 4])[0]
        pos += 4
        if token == 1:  # BEGIN_NODE: inline NUL-terminated name
            end = data.index(b"\0", pos)
            name = data[pos:end].decode()
            pos = pos + _align4(end - pos + 1)
            path.append(name)
        elif token == 2:  # END_NODE
            path.pop()
        elif token == 3:  # PROP: length + name offset, then padded value
            length, name_off = struct.unpack(">II", data[pos : pos + 8])
            pos += 8
            prop = strings[name_off:].split(b"\0", 1)[0].decode()
            props.append(("/".join(path), prop, data[pos : pos + length]))
            pos += _align4(length)
        elif token == 4:  # NOP
            continue
        elif token == 9:  # END
            return props
        else:
            raise AssertionError(f"bad FDT token {token} at {pos - 4}")


def _kernel_image(itb: bytes) -> bytes:
    kernel = next(
        value
        for node, prop, value in _fit_props(itb)
        if node == "/images/kernel-1" and prop == "data"
    )
    return lzma.decompress(kernel)


def _cpio_entries(blob: bytes) -> list[tuple[str, int, bytes]]:
    """Find and walk the newc cpio embedded in the decompressed kernel."""
    found = None
    start = 0
    while True:
        start = blob.find(NEWC_MAGIC, start)
        if start < 0:
            raise AssertionError("no newc cpio in the recovery kernel")
        try:
            found = _walk(blob, start)
            break
        except (AssertionError, ValueError, UnicodeDecodeError):
            start += 1
    return found


def _walk(blob: bytes, start: int) -> list[tuple[str, int, bytes]]:
    entries, pos = [], start
    while True:
        header = blob[pos : pos + NEWC_HEADER]
        if header[:6] != NEWC_MAGIC:
            raise AssertionError("not a cpio header")
        mode = int(header[14:22], 16)
        size = int(header[54:62], 16)
        name_size = int(header[94:102], 16)
        name = blob[pos + NEWC_HEADER : pos + NEWC_HEADER + name_size - 1].decode()
        body = blob[pos + NEWC_HEADER + name_size : pos + NEWC_HEADER + name_size + size]
        entries.append((name, mode, body))
        pos = _align4(_align4(pos + NEWC_HEADER + name_size) + size)
        if name == "TRAILER!!!":
            return entries
        if len(entries) > 20000:
            raise AssertionError("cpio walk ran away")


def _recovery_itb() -> Path | None:
    search = []
    if os.environ.get("OPENWRT_BIN_DIR"):
        search.append(Path(os.environ["OPENWRT_BIN_DIR"]))
    search.append(REPO / "bin/targets/airoha/an7581")
    for directory in search:
        for itb in sorted(directory.glob("*initramfs-recovery.itb")):
            return itb
    return None


class RecoveryKernelCpioTest(unittest.TestCase):
    def test_recovery_cpio_carries_init_and_sbin_init(self):
        itb = _recovery_itb()
        if itb is None:
            self.skipTest(
                "no *initramfs-recovery.itb; run "
                "`make image PROFILE=gemtek_xr1710g-ubi` or set OPENWRT_BIN_DIR"
            )
        entries = _cpio_entries(_kernel_image(itb.read_bytes()))
        names = [name for name, _, _ in entries]
        self.assertGreater(len(names), 1000, "recovery cpio looks empty")
        self.assertNotIn("/", names[0], "first cpio entry is not top-level")
        self.assertIn("init", names, "recovery cpio has no /init shim")
        self.assertIn("sbin/init", names, "recovery cpio has no /sbin/init")
        bodies = {name: body for name, _, body in entries}
        self.assertTrue(
            bodies["sbin/init"].startswith(b"\x7fELF"),
            "/sbin/init is not an executable (procd expected)",
        )
        self.assertIn(b"INITRAMFS", bodies["init"], "/init shim sets no INITRAMFS")
        self.assertIn(b"switch_root", bodies["init"], "/init shim does not switch_root")


class RdinitGapTest(unittest.TestCase):
    def test_no_rdinit_in_the_image_generation_path(self):
        offenders = []
        for target in RDINIT_SCOPE:
            path = REPO / target
            files = [path] if path.is_file() else list(path.rglob("*"))
            for item in files:
                if not item.is_file() or item.is_symlink():
                    continue
                try:
                    text = item.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                for line in text.splitlines():
                    stripped = line.lstrip("+-")
                    if stripped.startswith("#"):
                        continue  # a comment may name rdinit without setting it
                    if "rdinit" in stripped:
                        offenders.append(
                            f"{item.relative_to(REPO).as_posix()}: {stripped.strip()}"
                        )
                        break
        self.assertEqual([], offenders, "rdinit is set by the tree after all")

    def test_bootargs_come_from_the_devicetree_without_rdinit(self):
        dts = (REPO / DTB).read_text(encoding="utf-8")
        self.assertIn('bootargs = "console=ttyS0,115200 earlycon', dts)
        self.assertNotIn("rdinit", dts)

    def test_kernel_build_embeds_the_shim_as_init(self):
        defaults = (REPO / KERNEL_DEFAULTS).read_text(encoding="utf-8").splitlines()
        self.assertIn("INITRAMFS_INIT_FILE", defaults[11], defaults[11])
        self.assertIn("file /init", defaults[54], defaults[54])
        shim = (REPO / INIT_SHIM).read_text(encoding="utf-8")
        self.assertIn("export INITRAMFS=1", shim)
        self.assertIn("switch_root", shim)

    def test_bystander_rdinit_boot_still_sets_initramfs(self):
        hook = (REPO / PREINIT_HOOK).read_text(encoding="utf-8")
        marker = "grep -q '^rootfs / rootfs ' /proc/mounts"
        self.assertIn(
            marker,
            hook,
            "a boot that starts /sbin/init directly (rdinit from the vendor "
            "U-Boot) leaves INITRAMFS unset and falls through to the flash rootfs",
        )
        self.assertLess(
            hook.index(marker),
            hook.index("initramfs_test() {"),
            "the flag must be set while the hook files are sourced, before "
            "80_mount_root decides whether to register do_mount_root",
        )


if __name__ == "__main__":
    unittest.main()
