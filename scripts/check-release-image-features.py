#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Check that the 974 (BQL) and 968 (napi_complete_done) changes are really in
the XR1710G release image.

A patch file living in ``target/linux/airoha/patches-7.3`` proves nothing about
the image that is published: the release builder may use another branch, the
kernel may not have been rebuilt after the patch was added, or the image may
have been assembled from an older ``Image`` than the one in ``build_dir``.
This script reads the build tree and the image and says which of those is the
case.  It is offline and read-only: it never flashes, reboots, downloads
anything or writes to the tree.

Checks, in order:

  source   the kernel build source carries both changes; if no build tree is
           given, the patch files in ``patches-7.3`` are checked instead.
  build    the kernel was compiled after the source changed (mtime chain),
           ``CONFIG_BQL=y`` is set, and the 974 accumulator functions are in
           ``airoha_eth.o``/``vmlinux``.
  image    the FIT image embeds exactly the kernel in ``$(KDIR)/Image`` (the
           sha256 of the extracted payload must match), so a new rootfs
           cannot be shipped with an old kernel again.
  capture  an offline capture of ``byte_queue_limits`` proves the running
           image lets BQL fill the queue: max ``inflight`` >= 64 KiB under
           sustained TX load.

The command exits non-zero when a requested check fails, and prints what to
rebuild and what to do next.  Exit codes: 0 pass, 1 gate failure, 2 usage or
unreadable input, 3 cannot verify (incomplete artifacts or unsupported
format).

Examples::

    # From the release branch, before building: are the patches even here?
    scripts/check-release-image-features.py --repo .

    # After a build: verify the kernel and the images it produced.
    scripts/check-release-image-features.py --repo . \\
        --build-dir build_dir --image-dir bin/targets/airoha/an7581

    # After flashing the rebuilt image: verify the running system offline.
    scripts/check-release-image-features.py --capture /tmp/bql-capture.txt

See docs/release-image-features-gate.md for the criteria, how to collect a
capture, and the rollback procedure.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import lzma
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

# The 968 change is two hunks in airoha_eth.c: the RX poll and the TX poll.
SIG_968 = re.compile(r"napi_complete_done\s*\(\s*napi\s*,\s*done\s*\)")
SIG_968_OLD = re.compile(r"napi_complete\s*\(\s*napi\s*\)")
# The 974 change adds these two helpers and reports TX completions once per
# NAPI round through netdev_tx_completed_queue().
SIG_974_ADD = "airoha_qdma_tx_bql_add"
SIG_974_FLUSH = "airoha_qdma_tx_bql_flush"
SIG_974_CALL = "netdev_tx_completed_queue"

PATCHES_REL = Path("target/linux/airoha/patches-7.3")
KERNEL_DIR = "linux-7.3"
KERNEL_KDIR_GLOB = "build_dir/target-*/linux-airoha_an7581/linux-7.3"
IMAGE_DIR_REL = Path("bin/targets/airoha/an7581")
MIN_INFLIGHT_DEFAULT = 64 * 1024
MTIME_TOLERANCE = 2.0

VERSION_RE = re.compile(rb"Linux version [^\x00\n\r]{1,200}")
INFLIGHT_RE = re.compile(r"(?i)\b(?:max_)?inflight\b\s*[:=]?\s*(\d+)")
INFLIGHT_I_RE = re.compile(r"(?i)\bi\s*=\s*(\d+)")
LIMIT_RE = re.compile(r"(?i)\blimit(?:_max)?\s*[:=]\s*(\d+)")
BQL_STAT_RE = re.compile(r"(?i)\b(?:bql|byte_queue|inflight|dql)\b")


class GateError(Exception):
    """A problem that stops the gate, with the exit code to use."""

    def __init__(self, message: str, code: int = 3):
        super().__init__(message)
        self.code = code


class Report:
    """Collects the outcome of the individual checks."""

    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []

    def ok(self, message: str) -> None:
        print(f"  ok: {message}")

    def warn(self, message: str) -> None:
        print(f"  warn: {message}")
        self.warnings.append(message)

    def fail(self, message: str) -> None:
        print(f"  FAIL: {message}")
        self.failures.append(message)

    def note(self, message: str) -> None:
        print(f"  --: {message}")


def read_bytes(path: Path, what: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise GateError(f"cannot read {what} {path}: {exc}", 2) from exc


def read_text(path: Path, what: str) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError as exc:
        raise GateError(f"cannot read {what} {path}: {exc}", 2) from exc


def count_calls(text: str, name: str) -> int:
    """Count real calls to ``name(...)``, ignoring comments.

    The 974 patch comments mention netdev_tx_completed_queue() twice; a plain
    string count would report three occurrences instead of one call.
    """
    count = 0
    pattern = re.compile(re.escape(name) + r"\s*\(")
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(("*", "/*", "//")):
            continue
        count += len(pattern.findall(line))
    return count


# --------------------------------------------------------------------------
# ELF symbol reading (no nm/readelf dependency)


def elf_symbols(data: bytes) -> set[str] | None:
    """Return the .symtab names of an ELF64 little-endian file, if present."""
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return None
    try:
        (e_shoff,) = struct.unpack_from("<Q", data, 0x28)
        e_shentsize, e_shnum, _e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        if not e_shoff or not e_shnum or not e_shentsize:
            return None
        sections = []
        for index in range(e_shnum):
            offset = e_shoff + index * e_shentsize
            sections.append(struct.unpack_from("<IIQQQQIIQQ", data, offset))
        symtab = next((s for s in sections if s[1] == 2), None)  # SHT_SYMTAB
        if symtab is None:
            symtab = next((s for s in sections if s[1] == 11), None)  # SHT_DYNSYM
        if symtab is None:
            return None
        link = sections[symtab[6]]
        strings = data[link[4] : link[4] + link[5]]
        entsize = symtab[9] or 24
        names: set[str] = set()
        end = symtab[4] + symtab[5]
        for offset in range(symtab[4], end, entsize):
            (name_off,) = struct.unpack_from("<I", data, offset)
            if not name_off or name_off >= len(strings):
                continue
            name_end = strings.find(b"\0", name_off)
            if name_end < 0:
                continue
            names.add(strings[name_off:name_end].decode("latin-1"))
        return names
    except (struct.error, IndexError):
        return None


def kernel_version(data: bytes) -> str | None:
    match = VERSION_RE.search(data)
    return match.group(0).decode("latin-1", "replace") if match else None


# --------------------------------------------------------------------------
# Flattened device tree (FIT image) reading


def _align4(value: int) -> int:
    return (value + 3) & ~3


def _dt_string(data: bytes, offset: int) -> str:
    end = data.find(b"\0", offset)
    if end < 0:
        raise GateError("malformed device tree: unterminated property name")
    return data[offset:end].decode("latin-1")


def parse_fdt(data: bytes) -> dict:
    """Parse a flattened device tree into {name, props, children}."""
    if len(data) < 40:
        raise GateError("image is too small to be a FIT image")
    fields = struct.unpack_from(">10I", data, 0)
    magic, _total, off_struct, off_strings, _off_rsv, _ver, _last, _cpu, _sz_str, sz_struct = fields
    if magic != 0xD00DFEED:
        raise GateError("image is not a FIT/device-tree image (bad magic)")
    root = None
    stack: list[dict] = []
    offset = off_struct
    end = off_struct + sz_struct
    while offset + 4 <= end:
        (token,) = struct.unpack_from(">I", data, offset)
        offset += 4
        if token == 1:  # FDT_BEGIN_NODE
            name_end = data.find(b"\0", offset)
            if name_end < 0:
                raise GateError("malformed device tree: unterminated node name")
            name = data[offset:name_end].decode("latin-1")
            offset = _align4(name_end + 1)
            node = {"name": name, "props": {}, "children": []}
            if stack:
                stack[-1]["children"].append(node)
            elif root is None:
                root = node
            else:
                raise GateError("malformed device tree: more than one root node")
            stack.append(node)
        elif token == 2:  # FDT_END_NODE
            if not stack:
                raise GateError("malformed device tree: unbalanced end node")
            stack.pop()
        elif token == 3:  # FDT_PROP
            (length, name_off) = struct.unpack_from(">II", data, offset)
            offset += 8
            value = data[offset : offset + length]
            offset = _align4(offset + length)
            stack[-1]["props"][_dt_string(data, off_strings + name_off)] = value
        elif token == 4:  # FDT_NOP
            continue
        elif token == 9:  # FDT_END
            break
        else:
            raise GateError(f"malformed device tree: unknown token {token}")
    if stack or root is None:
        raise GateError("malformed device tree: truncated tree")
    return root


def fdt_child(node: dict, name: str) -> dict | None:
    for child in node["children"]:
        if child["name"] == name:
            return child
    return None


def fdt_u32(node: dict, name: str) -> int | None:
    value = node["props"].get(name)
    if value is None or len(value) != 4:
        return None
    return struct.unpack(">I", value)[0]


def fdt_string(node: dict, name: str) -> str:
    value = node["props"].get(name, b"")
    return value.rstrip(b"\0").decode("latin-1")


# --------------------------------------------------------------------------
# Source / patch checks


def patch_has_968(text: str) -> bool:
    """The 968 patch converts the two poll sites; require both conversions."""
    added = [line for line in text.splitlines() if line.startswith("+") and SIG_968.search(line)]
    removed = [line for line in text.splitlines() if line.startswith("-") and SIG_968_OLD.search(line)]
    return len(added) >= 2 and len(removed) >= 2


def patch_has_974(text: str) -> bool:
    added = "\n".join(line for line in text.splitlines() if line.startswith("+"))
    return all(sig in added for sig in (SIG_974_ADD, SIG_974_FLUSH, SIG_974_CALL))


def find_patch(patch_dir: Path, number: str, predicate) -> tuple[Path | None, bool]:
    """Find the patch carrying a change.

    Prefer ``<number>-*.patch``; if it exists but does not carry the change,
    say so.  Fall back to scanning the directory so a renamed patch is still
    recognised.
    """
    numbered = sorted(patch_dir.glob(f"{number}-*.patch"))
    for path in numbered:
        if predicate(read_text(path, "patch")):
            return path, True
    if numbered:
        return numbered[0], False
    for path in sorted(patch_dir.glob("*.patch")):
        if predicate(read_text(path, "patch")):
            return path, True
    return None, False


def scan_patches(repo: Path) -> dict[str, tuple[Path | None, bool]]:
    patch_dir = repo / PATCHES_REL
    if not patch_dir.is_dir():
        return {"968": (None, False), "974": (None, False)}
    return {
        "968": find_patch(patch_dir, "968", patch_has_968),
        "974": find_patch(patch_dir, "974", patch_has_974),
    }


def check_kernel_source(kernel_dir: Path, report: Report) -> bool:
    """Check the applied kernel source for both changes.  Returns True/False."""
    source = kernel_dir / "drivers/net/ethernet/airoha/airoha_eth.c"
    header = kernel_dir / "drivers/net/ethernet/airoha/airoha_eth.h"
    if not source.is_file():
        report.fail(f"kernel source not found: {source}")
        return False
    text = read_text(source, "kernel source")
    ok = True

    new_calls = len(SIG_968.findall(text))
    old_calls = len(SIG_968_OLD.findall(text))
    if new_calls >= 2 and old_calls == 0:
        report.ok(f"968: napi_complete_done(napi, done) in {source.name} ({new_calls} sites)")
    else:
        report.fail(
            f"968: {source.name} has {new_calls} napi_complete_done(napi, done) site(s) "
            f"and {old_calls} old napi_complete(napi) site(s); expected 2 and 0"
        )
        ok = False

    header_text = read_text(header, "kernel header") if header.is_file() else ""
    calls = count_calls(text, SIG_974_CALL)
    has_add = SIG_974_ADD in text
    has_flush = SIG_974_FLUSH in text
    has_state = "bql[" in header_text and "bql_dirty" in header_text
    if has_add and has_flush and calls == 1 and has_state:
        report.ok(f"974: BQL accumulator in {source.name} and {header.name}")
    else:
        report.fail(
            "974: expected airoha_qdma_tx_bql_add/_flush, one "
            f"netdev_tx_completed_queue() call and the bql state; got add={has_add} "
            f"flush={has_flush} calls={calls} state={has_state}"
        )
        ok = False

    return ok


def check_source_stage(repo: Path, kernel_dir: Path | None, report: Report) -> bool:
    """Check where the image's kernel comes from.

    With a build tree, the applied kernel source is authoritative (a patch may
    have been renamed or upstreamed); without one, the patch files are all we
    have.  Patch files that are missing next to a patched build tree are
    reported as a warning, not a failure: the question is what the image was
    built from.
    """
    patches = scan_patches(repo)

    if kernel_dir is not None:
        ok = check_kernel_source(kernel_dir, report)
        missing = [name for name, (path, good) in patches.items() if not (path and good)]
        if missing:
            report.warn(
                "patch file(s) "
                + ", ".join(missing)
                + f" not found in {repo / PATCHES_REL}; the kernel build tree has the "
                "code, so this is only a warning"
            )
        return ok

    patch_dir = repo / PATCHES_REL
    if not patch_dir.is_dir():
        report.fail(
            f"{patch_dir} does not exist; this branch does not carry the 968/974 changes"
        )
        return False

    ok = True
    for number, (path, good) in patches.items():
        if good:
            report.ok(f"{number}: {path.name}")
        elif path is not None:
            report.fail(f"{number}: {path.name} exists but does not carry the expected change")
            ok = False
        else:
            report.fail(f"{number}: no patch in {PATCHES_REL} carries the expected change")
            ok = False
    return ok


# --------------------------------------------------------------------------
# Build checks


def resolve_kernel_dir(build: Path) -> tuple[Path, Path] | None:
    """Return (kernel source dir, KDIR) for a build tree or one of its parents."""
    build = build.resolve()
    candidates = []
    if (build / "drivers/net/ethernet/airoha/airoha_eth.c").is_file():
        candidates.append(build)
    candidates.append(build / KERNEL_DIR)
    candidates.extend(sorted(build.glob("target-*/linux-airoha_an7581/linux-7.3")))
    candidates.extend(sorted(build.glob("linux-7.3")))
    for cand in candidates:
        if (cand / "drivers/net/ethernet/airoha/airoha_eth.c").is_file():
            return cand, cand.parent
    return None


def find_kernel_image(kdir: Path) -> Path | None:
    for name in ("Image", "Image-initramfs"):
        candidate = kdir / name
        if candidate.is_file():
            return candidate
    candidate = kdir / "linux-7.3/arch/arm64/boot/Image"
    return candidate if candidate.is_file() else None


def require_symbols(path: Path, label: str, symbols: set[str], report: Report) -> bool:
    data = read_bytes(path, label)
    names = elf_symbols(data)
    if names is None:
        report.fail(f"{label} {path.name} has no ELF symbol table; cannot verify the compiled 974 code")
        return False
    missing = sorted(symbols - names)
    if missing:
        report.fail(f"{label} {path.name} is missing symbol(s): {', '.join(missing)}")
        return False
    report.ok(f"{label} {path.name} contains {', '.join(sorted(symbols))}")
    return True


def newer_or_equal(newer: Path, older: Path) -> bool:
    try:
        return newer.stat().st_mtime + MTIME_TOLERANCE >= older.stat().st_mtime
    except OSError:
        return False


def check_build_stage(kdir: Path, kernel_dir: Path, report: Report) -> bool:
    ok = True

    config = kernel_dir / ".config"
    if not config.is_file():
        report.fail(f"kernel config not found: {config}")
        ok = False
    else:
        text = read_text(config, "kernel config")
        if re.search(r"(?m)^CONFIG_BQL=y$", text):
            report.ok("CONFIG_BQL=y")
        else:
            report.fail("CONFIG_BQL is not enabled in the kernel config")
            ok = False

    source = kernel_dir / "drivers/net/ethernet/airoha/airoha_eth.c"
    header = kernel_dir / "drivers/net/ethernet/airoha/airoha_eth.h"
    obj = kernel_dir / "drivers/net/ethernet/airoha/airoha_eth.o"
    vmlinux = kernel_dir / "vmlinux"
    image = find_kernel_image(kdir)

    if obj.is_file():
        if not newer_or_equal(obj, source) or (header.is_file() and not newer_or_equal(obj, header)):
            report.fail(
                f"{obj.name} is older than airoha_eth.c/.h; the kernel was not rebuilt "
                "after the source changed"
            )
            ok = False
        else:
            report.ok(f"{obj.name} is newer than airoha_eth.c/.h")
        ok = require_symbols(obj, "object", {SIG_974_ADD, SIG_974_FLUSH}, report) and ok
    else:
        report.warn(f"{obj.name} not found; relying on vmlinux for the compiled-code check")

    if not vmlinux.is_file():
        report.fail(f"{vmlinux} not found; the kernel build is incomplete")
        return False

    vmlinux_data = read_bytes(vmlinux, "vmlinux")
    vmlinux_names = elf_symbols(vmlinux_data)
    if vmlinux_names is None:
        report.fail("vmlinux has no ELF symbol table; cannot verify the compiled 974 code")
        ok = False
    else:
        missing = sorted({SIG_974_ADD, SIG_974_FLUSH} - vmlinux_names)
        if missing:
            report.fail(f"vmlinux is missing symbol(s): {', '.join(missing)}")
            ok = False
        else:
            report.ok("vmlinux contains the 974 BQL helpers")

    if obj.is_file():
        newer_than = obj
    else:
        newer_than = max(
            source,
            header,
            key=lambda path: path.stat().st_mtime if path.exists() else 0,
        )
    if not newer_or_equal(vmlinux, newer_than):
        report.fail(
            "vmlinux is older than the driver object/source it should contain; "
            "run a kernel rebuild (the image would embed a stale kernel)"
        )
        ok = False
    else:
        report.ok("vmlinux is newer than the driver object/source")

    if image is None:
        report.fail(f"no kernel Image found under {kdir}; the kernel build is incomplete")
        return False

    if not newer_or_equal(image, vmlinux):
        report.fail(
            f"{image.name} is older than vmlinux; the image step would embed a stale kernel"
        )
        ok = False
    else:
        report.ok(f"{image.name} is newer than vmlinux")

    vmlinux_version = kernel_version(vmlinux_data)
    image_version = kernel_version(read_bytes(image, "kernel Image"))
    if vmlinux_version and image_version and vmlinux_version != image_version:
        report.fail(
            f"{image.name} and vmlinux come from different builds:\n"
            f"      Image:   {image_version}\n"
            f"      vmlinux: {vmlinux_version}"
        )
        ok = False
    elif vmlinux_version and image_version:
        report.ok(f"{image.name} and vmlinux report the same kernel build")

    return ok


# --------------------------------------------------------------------------
# Image checks


def select_release_image(image_dir: Path) -> Path:
    candidates = [
        path
        for pattern in ("*gemtek*xr1710g*sysupgrade*.itb", "*gemtek*xr1710g*.itb")
        for path in sorted(image_dir.glob(pattern))
        if "chainload" not in path.name
    ]
    if not candidates:
        raise GateError(
            f"no XR1710G sysupgrade image found in {image_dir}; build the image before releasing",
            1,
        )
    for path in candidates:
        if "squashfs-sysupgrade" in path.name:
            return path
    return candidates[0]


def extract_fit_kernel(image: Path, report: Report) -> bytes:
    data = read_bytes(image, "image")
    root = parse_fdt(data)
    images = fdt_child(root, "images")
    kernel = fdt_child(images, "kernel-1") if images else None
    if kernel is None:
        raise GateError("image FIT has no /images/kernel-1 node")

    compression = fdt_string(kernel, "compression") or "none"
    if "data" in kernel["props"]:
        payload = kernel["props"]["data"]
        source = "inline"
    else:
        position = fdt_u32(kernel, "data-position")
        size = fdt_u32(kernel, "data-size")
        if position is None or size is None:
            raise GateError("image FIT kernel has neither inline data nor data-position/data-size")
        if position + size > len(data):
            raise GateError("image FIT kernel data lies outside the image file")
        payload = data[position : position + size]
        source = f"offset 0x{position:x}"
    report.note(f"FIT kernel-1: compression={compression} {source} size={len(payload)}")

    try:
        if compression in ("none", ""):
            return payload
        if compression == "gzip":
            return gzip.decompress(payload)
        if compression == "lzma":
            return lzma.decompress(payload)
        if compression == "zstd":
            if not shutil.which("zstd"):
                raise GateError("FIT kernel is zstd-compressed but zstd is not installed", 3)
            result = subprocess.run(
                ["zstd", "-dc"], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            if result.returncode:
                raise GateError(f"zstd failed to decompress the FIT kernel: {result.stderr.decode()}")
            return result.stdout
    except (OSError, EOFError, lzma.LZMAError, gzip.BadGzipFile) as exc:
        raise GateError(f"cannot decompress the FIT kernel ({compression}): {exc}") from exc
    raise GateError(f"unsupported FIT kernel compression: {compression}")


def check_image_stage(image_dir: Path, kdir: Path, report: Report) -> bool:
    image = select_release_image(image_dir)
    report.note(f"release image: {image}")
    kernel_dir = kdir / KERNEL_DIR
    vmlinux = kernel_dir / "vmlinux"
    if not vmlinux.is_file():
        raise GateError(f"kernel build tree not found at {kernel_dir}; cannot verify the image", 3)

    payload = extract_fit_kernel(image, report)
    expected_path = kdir / ("Image-initramfs" if "initramfs" in image.name else "Image")
    if not expected_path.is_file():
        raise GateError(f"cannot find {expected_path} to compare against", 3)
    expected = read_bytes(expected_path, "kernel Image")
    payload_hash = hashlib.sha256(payload).hexdigest()
    expected_hash = hashlib.sha256(expected).hexdigest()
    if payload_hash != expected_hash:
        report.fail(
            f"the image kernel is not {expected_path.name}: sha256 {payload_hash} "
            f"!= {expected_hash}; rebuild the image from the current kernel and do not "
            "flash the old one"
        )
        return False
    report.ok(f"image kernel sha256 matches {expected_path.name} ({payload_hash[:16]}...)")

    image_version = kernel_version(payload)
    vmlinux_version = kernel_version(read_bytes(vmlinux, "vmlinux"))
    if image_version and vmlinux_version and image_version != vmlinux_version:
        report.fail(
            "the image kernel and the current vmlinux come from different builds; rebuild the image"
        )
        return False
    if image_version:
        report.ok(f"image kernel version: {image_version}")
    return True


# --------------------------------------------------------------------------
# Runtime capture checks (offline)


BINARY_SUFFIXES = {".itb", ".bin", ".gz", ".xz", ".zst", ".o", ".elf", ".img", ".ubi"}


def iter_capture_files(capture: Path):
    if capture.is_file():
        yield capture
    elif capture.is_dir():
        for path in sorted(capture.rglob("*")):
            if path.is_file() and path.suffix.lower() not in BINARY_SUFFIXES:
                yield path


def check_capture_stage(capture: Path, min_inflight: int, report: Report) -> bool:
    values: list[tuple[int, str]] = []
    limits: list[int] = []
    ethtool_hits: list[str] = []

    for path in iter_capture_files(capture):
        try:
            if path.stat().st_size > 32 * 1024 * 1024:
                report.warn(f"skipping large file {path}")
                continue
            raw = path.read_text(errors="replace")
        except OSError as exc:
            report.warn(f"cannot read capture {path}: {exc}")
            continue
        label = str(path)
        if path.name.lower() == "inflight":
            try:
                values.append((int(raw.strip()), label))
            except ValueError:
                report.warn(f"{path} does not contain a single inflight value")
            continue
        for match in INFLIGHT_RE.finditer(raw):
            values.append((int(match.group(1)), label))
        for match in INFLIGHT_I_RE.finditer(raw):
            values.append((int(match.group(1)), label))
        for match in LIMIT_RE.finditer(raw):
            limits.append(int(match.group(1)))
        if "ethtool" in path.name.lower() or "NIC statistics" in raw:
            for line in raw.splitlines():
                if BQL_STAT_RE.search(line):
                    ethtool_hits.append(f"{path.name}: {line.strip()}")

    if not values:
        report.fail(
            "capture has no byte_queue_limits/inflight samples; collect "
            "/sys/class/net/<dev>/queues/tx-*/byte_queue_limits/inflight under sustained TX load"
        )
        return False

    maximum, where = max(values, key=lambda item: item[0])
    if limits:
        report.note(f"observed BQL limit up to {max(limits)} bytes")
    if ethtool_hits:
        report.note(f"ethtool -S BQL-looking counters: {len(ethtool_hits)} (e.g. {ethtool_hits[0]})")
    else:
        report.note(
            "no BQL counter in the ethtool -S capture; this driver exposes BQL in sysfs, "
            "which is the authoritative signal used below"
        )
    if maximum < min_inflight:
        report.fail(
            f"max inflight {maximum} bytes ({where}) is below {min_inflight} bytes "
            f"({min_inflight // 1024} KiB); 974/968 are not proven on the running image, "
            "or the capture was idle. Capture under sustained TX load and reflash a rebuilt image "
            "if it stays low"
        )
        return False

    report.ok(
        f"max inflight {maximum} bytes (>= {min_inflight}) observed in {where}; "
        "974 BQL is live on the running image"
    )
    return True


# --------------------------------------------------------------------------
# Driver


def print_guidance() -> None:
    print()
    print("The gate is read-only: it did not flash, reboot or change anything.")
    print("To get an image that passes:")
    print("  1. Build from a tree that carries both changes (968 first, then 974).")
    print("     If the branch has no 968/974 in patches-7.3, it will never be in the image.")
    print("  2. Rebuild the kernel and the image in one run, for example:")
    print("       make target/linux/clean")
    print("       make target/linux/compile")
    print("       make -j\"$(nproc)\"")
    print("  3. Re-run this check with --build-dir and --image-dir, then flash the")
    print("     new sysupgrade image through the normal procedure.")
    print("  4. After booting the new image, capture")
    print("       /sys/class/net/<dev>/queues/tx-*/byte_queue_limits/inflight")
    print("     under sustained TX load and re-run with --capture.")
    print("See docs/release-image-features-gate.md for the criteria and rollback.")


def autodetect_build_dir(repo: Path) -> Path | None:
    matches = sorted(repo.glob(KERNEL_KDIR_GLOB))
    if len(matches) == 1:
        return matches[0]
    return None


def resolve_build_dir(args, repo: Path, report: Report) -> Path | None:
    if args.skip_build:
        return None
    if args.build_dir:
        path = Path(args.build_dir).resolve()
        resolved = resolve_kernel_dir(path)
        if resolved is None:
            raise GateError(f"{path} is not a linux-7.3 kernel build tree", 2)
        return path
    auto = autodetect_build_dir(repo)
    if auto is not None:
        report.note(f"auto-detected kernel build tree: {auto}")
        return auto
    return None


def resolve_image_dir(args, repo: Path, report: Report) -> Path | None:
    if args.skip_image:
        return None
    if args.image_dir:
        path = Path(args.image_dir).resolve()
        if not path.is_dir():
            raise GateError(f"image directory not found: {path}", 2)
        return path
    auto = repo / IMAGE_DIR_REL
    if auto.is_dir():
        report.note(f"auto-detected image directory: {auto}")
        return auto
    return None


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Verify that 974 (BQL) and 968 (napi_complete_done) are in the "
        "XR1710G release image.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="The check is offline and read-only; it never flashes or reboots.\n"
        "Exit codes: 0 pass, 1 gate failure, 2 usage/input error, 3 cannot verify.",
    )
    parser.add_argument("--repo", default=None, help="repository root (default: parent of this script)")
    parser.add_argument("--build-dir", default=None, help="OpenWrt build_dir or the linux-7.3 tree")
    parser.add_argument("--image-dir", default=None, help="directory with the built images")
    parser.add_argument("--capture", default=None, help="offline capture file or directory")
    parser.add_argument(
        "--min-inflight",
        type=int,
        default=MIN_INFLIGHT_DEFAULT,
        help=f"minimum BQL inflight in bytes (default: {MIN_INFLIGHT_DEFAULT})",
    )
    parser.add_argument("--skip-source", action="store_true", help="do not check the source/patches")
    parser.add_argument("--skip-build", action="store_true", help="do not check the kernel build")
    parser.add_argument("--skip-image", action="store_true", help="do not check the image")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    report = Report()

    if args.capture is None and args.skip_source and args.skip_build and args.skip_image:
        print("nothing to check: all stages were skipped", file=sys.stderr)
        return 2

    repo = Path(args.repo).resolve() if args.repo else Path(__file__).resolve().parent.parent
    print(f"repository: {repo}")

    try:
        build_dir = resolve_build_dir(args, repo, report)
        kernel_dir = None
        kdir = None
        if build_dir is not None:
            resolved = resolve_kernel_dir(build_dir)
            if resolved is None:
                raise GateError(f"{build_dir} has no linux-7.3 kernel source", 3)
            kernel_dir, kdir = resolved
            print(f"kernel build: {kernel_dir}")
        image_dir = resolve_image_dir(args, repo, report)
        if image_dir is not None:
            print(f"image directory: {image_dir}")

        if not args.skip_source:
            print()
            print("source:")
            check_source_stage(repo, kernel_dir, report)

        if kernel_dir is not None and not args.skip_build:
            print()
            print("build:")
            check_build_stage(kdir, kernel_dir, report)

        if image_dir is not None and not args.skip_image:
            print()
            print("image:")
            if kdir is None:
                raise GateError("the image check needs --build-dir to locate $(KDIR)/Image", 3)
            check_image_stage(image_dir, kdir, report)

        if args.capture is not None:
            print()
            print("capture:")
            capture = Path(args.capture)
            if not capture.exists():
                raise GateError(f"capture not found: {capture}", 2)
            if args.min_inflight < MIN_INFLIGHT_DEFAULT:
                report.warn(
                    f"--min-inflight {args.min_inflight} is below the release criterion "
                    f"{MIN_INFLIGHT_DEFAULT} bytes; use the default for a release check"
                )
            check_capture_stage(capture, args.min_inflight, report)
    except GateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        if exc.code != 2:
            print_guidance()
        return exc.code

    print()
    if report.failures:
        print(f"FAILED: {len(report.failures)} check(s) failed.")
        print_guidance()
        return 1
    print("PASS: 974 (BQL) and 968 (napi_complete_done) are accounted for.")
    if report.warnings:
        print(f"({len(report.warnings)} warning(s) above do not affect the result.)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
