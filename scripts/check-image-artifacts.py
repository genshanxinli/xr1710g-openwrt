#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Post-build XR1710G image, FWx0 metadata, dumpimage, sha256sums, and manifest gate."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_IMAGE_DIR = Path("bin/targets/airoha/an7581")
FIT_MAGIC = b"\xd0\x0d\xfe\xed"
TRAILER_STRUCT = struct.Struct(">IIB3sI")
FWX0_MAGIC = 0x46577830
TRAILER_SIG, TRAILER_INFO = 0, 1
INFO_HDR_LEN = 8
META_MAX = 30 * 1024
SIG_MAX = 1024

BOARD_COMPAT = "gemtek,xr1710g-ubi"
FDT_DESC_NEEDLE = "OpenWrt gemtek_xr1710g-ubi device tree blob"
REQUIRED_PKGS = (
    "dumpimage",
    "fitblk",
    "kmod-hwmon-nct7802",
    "airoha-en7581-mt7996-npu-firmware",
    "kmod-mt7996-firmware",
    "rtl826x-firmware",
    "rtl8261c-firmware",
    "luci-app-airoha-fancontrol",
    "luci-app-mlo",
    "luci-app-airoha-flowsense",
)
BANNED_PKGS = (
    "luci-app-wifi7",
    "luci-app-airoha-npu",
    "luci-app-netspeedtest",
    "luci-app-traffic-chart",
    "luci-app-appflow",
    "netifyd",
    "fastfetch",
)


def parse_fwx0_metadata(data: bytes, label: str) -> dict:
    """Validate 16-byte big-endian FWx0 trailer(s) and return decoded metadata JSON."""
    tlen = TRAILER_STRUCT.size
    end = len(data)
    if end < tlen:
        raise ValueError(f"{label}: image smaller than {tlen}B")

    def read_trailer(pos: int, expect_kind: int | None = None) -> tuple[int, int]:
        if pos < tlen:
            raise ValueError(f"{label}: truncated before FWx0 trailer at {pos}")
        magic, crc, kind, pad, size = TRAILER_STRUCT.unpack_from(data, pos - tlen)
        if magic != FWX0_MAGIC:
            raise ValueError(f"{label}: last 16B magic {magic:#010x} != FWx0 (0x46577830)")
        if pad != b"\x00\x00\x00":
            raise ValueError(f"{label}: non-zero FWx0 pad bytes {pad!r}")
        if expect_kind is not None and kind != expect_kind:
            raise ValueError(f"{label}: expected FWx0 type {expect_kind}, got {kind}")
        if kind == TRAILER_INFO:
            lo, hi = tlen + INFO_HDR_LEN, META_MAX + INFO_HDR_LEN + tlen
        elif kind == TRAILER_SIG:
            lo, hi = tlen, SIG_MAX + tlen
        else:
            raise ValueError(f"{label}: unknown FWx0 trailer type {kind}")
        if not (lo <= size <= hi) or size > pos:
            raise ValueError(f"{label}: implausible FWx0 size {size} (bounds {lo}..{min(hi, pos)})")
        want_crc = (~zlib.crc32(data[: pos - tlen], 0)) & 0xFFFFFFFF
        if crc != want_crc:
            raise ValueError(f"{label}: FWx0 CRC32 mismatch {crc:#010x} != {want_crc:#010x}")
        return kind, size

    kind, size = read_trailer(end)
    info_end, info_size = end, size
    if kind == TRAILER_SIG:
        info_end = end - size
        _, info_size = read_trailer(info_end, expect_kind=TRAILER_INFO)

    info_start = info_end - info_size
    hdr_ver, _hdr_flags = struct.unpack_from(">II", data, info_start)
    if hdr_ver != 0:
        raise ValueError(f"{label}: unsupported fwimage_header version {hdr_ver} (expected 0)")
    payload = data[info_start + INFO_HDR_LEN : info_end - tlen].rstrip(b"\x00")
    try:
        meta = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"{label}: invalid FWx0 metadata JSON: {exc}") from exc
    if not isinstance(meta, dict):
        raise ValueError(f"{label}: FWx0 metadata JSON is not an object")
    return meta


def check_image(path: Path, dumpimage: str | None, require_dumpimage: bool) -> list[str]:
    errs: list[str] = []
    name = path.name
    data = path.read_bytes()

    if len(data) < 8 or data[:4] != FIT_MAGIC:
        return [f"{name}: missing FIT magic d00dfeed"]
    fit_total = struct.unpack_from(">I", data, 4)[0]
    if fit_total < 8 or len(data) < fit_total:
        errs.append(f"{name}: truncated FIT (size={len(data)} < totalsize={fit_total})")

    try:
        meta = parse_fwx0_metadata(data, name)
    except ValueError as exc:
        errs.append(str(exc))
        meta = None

    if meta is not None:
        raw_meta = json.dumps(meta).lower()
        if "w1700k" in raw_meta:
            errs.append(f"{name}: metadata contains forbidden 'w1700k'")
        if meta.get("compat_version") != "2.0":
            errs.append(f"{name}: compat_version={meta.get('compat_version')!r}, expected '2.0'")
        new_devs = meta.get("new_supported_devices")
        sup_devs = meta.get("supported_devices")
        if isinstance(new_devs, list):
            if BOARD_COMPAT not in new_devs:
                errs.append(f"{name}: new_supported_devices missing {BOARD_COMPAT!r}: {new_devs!r}")
        elif isinstance(sup_devs, list):
            errs.append(f"{name}: compat_version 2.0 image missing new_supported_devices")
        if isinstance(sup_devs, list):
            base_devs = [str(d).split(" - ", 1)[0].strip() for d in sup_devs]
            if BOARD_COMPAT not in base_devs:
                errs.append(f"{name}: supported_devices missing {BOARD_COMPAT!r}: {sup_devs!r}")
        elif not isinstance(new_devs, list):
            errs.append(f"{name}: neither new_supported_devices nor supported_devices present")

    if dumpimage:
        proc = subprocess.run([dumpimage, "-l", str(path)], capture_output=True, text=True, timeout=60, check=False)
        out = (proc.stdout or "") + "\n" + (proc.stderr or "")
        if proc.returncode != 0:
            errs.append(f"{name}: dumpimage -l exited {proc.returncode}")
        else:
            if FDT_DESC_NEEDLE not in out:
                errs.append(f"{name}: dumpimage -l missing FDT description {FDT_DESC_NEEDLE!r}")
            if "w1700k" in out.lower():
                errs.append(f"{name}: dumpimage -l references forbidden 'w1700k'")
    elif require_dumpimage:
        errs.append(f"{name}: dumpimage not found (--require-dumpimage)")
    else:
        print(f"SKIP: {name}: dumpimage not installed")
    return errs


def find_single(image_dir: Path, pattern: str) -> Path:
    matches = sorted(image_dir.glob(pattern))
    if len(matches) != 1:
        raise FileNotFoundError(f"expected 1 match for {pattern} in {image_dir}, found {len(matches)}")
    return matches[0]


def check_sha256sums(image_dir: Path, images: list[Path]) -> list[str]:
    sums_path = image_dir / "sha256sums"
    if not sums_path.is_file():
        return [f"missing {sums_path}"]
    entries: dict[str, str] = {}
    for line in sums_path.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            entries[parts[1].lstrip("*")] = parts[0].lower()
    errs: list[str] = []
    for img in images:
        want = entries.get(img.name)
        if not want:
            errs.append(f"sha256sums missing entry for {img.name}")
            continue
        got = hashlib.sha256(img.read_bytes()).hexdigest().lower()
        if got != want:
            errs.append(f"sha256 mismatch for {img.name}: expected {want}, got {got}")
    return errs


def check_manifest(image_dir: Path) -> list[str]:
    manifests = sorted(image_dir.glob("*gemtek_xr1710g-ubi*.manifest"))
    if len(manifests) != 1:
        return [f"expected 1 *gemtek_xr1710g-ubi*.manifest in {image_dir}, found {len(manifests)}"]
    pkgs: set[str] = set()
    for line in manifests[0].read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s:
            pkgs.add(s.split()[0])
    errs: list[str] = []
    missing = [p for p in REQUIRED_PKGS if p not in pkgs]
    present_banned = [p for p in BANNED_PKGS if p in pkgs]
    if missing:
        errs.append(f"{manifests[0].name}: missing required packages: {', '.join(missing)}")
    if present_banned:
        errs.append(f"{manifests[0].name}: banned packages present: {', '.join(present_banned)}")
    return errs


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image_dir", nargs="?", type=Path, help=f"build output dir (default: {DEFAULT_IMAGE_DIR})")
    ap.add_argument("--repo", type=Path, default=REPO_ROOT, help="repository root")
    ap.add_argument("--require-dumpimage", action="store_true", help="fail if dumpimage is unavailable")
    args = ap.parse_args(argv)

    repo = args.repo.resolve()
    image_dir = (args.image_dir if args.image_dir else repo / DEFAULT_IMAGE_DIR).resolve()
    if not image_dir.is_dir():
        print(f"ERROR: image directory not found: {image_dir}", file=sys.stderr)
        return 2

    host_di = repo / "staging_dir/host/bin/dumpimage"
    dumpimage = str(host_di) if host_di.is_file() else shutil.which("dumpimage")

    try:
        sysupgrade = find_single(image_dir, "*gemtek_xr1710g-ubi-squashfs-sysupgrade.itb")
        recovery = find_single(image_dir, "*gemtek_xr1710g-ubi-initramfs-recovery.itb")
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    fails: list[str] = []
    for img in (sysupgrade, recovery):
        fails.extend(check_image(img, dumpimage, args.require_dumpimage))
    fails.extend(check_sha256sums(image_dir, [sysupgrade, recovery]))
    fails.extend(check_manifest(image_dir))

    if fails:
        for f in fails:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print(f"OK: {sysupgrade.name}, {recovery.name}, sha256sums, and manifest verified")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
