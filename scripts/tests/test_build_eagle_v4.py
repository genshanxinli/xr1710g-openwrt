#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline regression tests for tools/npu-firmware/build-eagle-v4.sh.

Covers three root-cause defects audited in tools/npu-firmware/build-eagle-v4.sh:

  1. P0-1 (DMA ring overlap): ring2 (RRO band2 / qid2 at +0x22020, size 0x6000
     -> 0x28020) overlapped ring4 (TX band2 / qid7 at +0x26040, size 0x8000) by
     0x1FE0 bytes (8,160 B / 510 descriptors), and run_verify() only checked
     individual arena bounds without checking pairwise ring disjointness.
  2. P0-2 (MSDU page ID aliasing): eagle_msdu_pg_pool_init() filled every band
     (0, 1, 2) with identical IDs 0..1023 while msdu_pg_desc_fill() addressed
     DRAM as eagle_dram_ba_node_addr + (id << 7) with no per-band offset, so
     all three bands overwrote each other's 128-byte MSDU page buffers.
  3. P2-4 (SIGPIPE under set -euo pipefail): require_tools() and
     write_manifest() piped `"${CROSS}gcc" --version | head -n 1`, aborting
     with exit 141 whenever gcc --version outlived head closing the pipe.

Point BUILD_EAGLE_V4_UNDER_TEST at a saved pre-fix copy to reproduce the red
run:

    BUILD_EAGLE_V4_UNDER_TEST=/tmp/build-eagle-v4.buggy.sh \\
        python3 -m unittest -v scripts/tests/test_build_eagle_v4.py

Run from the repository root:

    python3 -m unittest -v scripts/tests/test_build_eagle_v4.py
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "BUILD_EAGLE_V4_UNDER_TEST",
        REPO_ROOT / "tools/npu-firmware/build-eagle-v4.sh",
    )
)
SHELL_SYNTAX_GATE = REPO_ROOT / "scripts/check-shell-syntax.py"

DESC_BASE = 0x3E8A2000
DESC_SIZE = 0x4A040
NPU_BA_SIZE = 0x200000
MSDU_PG_ENTRY_SIZE = 128
TEXT_BASE = 0x84000000
DATA_BASE = 0x3E900000

RING_SPECS = (
    ("qid0", 0, 0x6000),   # ring1: RRO band0 (1536 x 16 B)
    ("qid2", 1, 0x6000),   # ring2: RRO band2 (1536 x 16 B)
    ("qid5", 2, 0x8000),   # ring3: TX band0 (2048 x 16 B)
    ("qid7", 3, 0x8000),   # ring4: TX band2 (2048 x 16 B)
    ("qid8", 5, 0x3000),   # ring6: ind cmd (1536 x 8 B)
    ("qid10", 6, 0x1000),  # ring7: MSDU page band0 (256 x 16 B)
    ("qid11", 7, 0x2000),  # ring8: MSDU page band1 (512 x 16 B)
    ("qid12", 8, 0x4000),  # ring9: MSDU page band2 (1024 x 16 B)
)

SRAM_SIZE_LO = (
    (2, 0x01818), (3, 0x01818), (9, 0x003E8), (10, 0x003E8),
    (11, 0x00078), (14, 0x00600), (15, 0x00600), (22, 0x01008),
    (25, 0x00040), (26, 0x04000), (30, 0x00100), (31, 0x00601),
    (18, 0x06800), (16, 0x02020), (17, 0x02020), (28, 0x06800),
    (23, 0x00800), (42, 0x01800), (43, 0x00600),
)

SRAM_SIZE_HI = (
    (138, 0x06000), (129, 0x0E5FF), (132, 0x11000), (133, 0x11000),
    (130, 0x00004), (137, 0x00004),
)


def extract_heredoc(script_text: str, marker: str) -> str:
    pattern = rf"<<'{re.escape(marker)}'\n(.*?)\n{re.escape(marker)}\n"
    match = re.search(pattern, script_text, re.S)
    if not match:
        raise AssertionError(f"heredoc {marker!r} not found in {SCRIPT}")
    return match.group(1)


def parse_c_ring_offsets(patch_text: str) -> list[int]:
    match = re.search(
        r"static const u32 off\[9\] = \{\n(.*?)\n\+?\t\};",
        patch_text,
        re.S,
    )
    if not match:
        raise AssertionError("eagle_ring_desc_base DDR off[9] table not found")
    vals = [
        int(tok, 16)
        for tok in re.findall(r"^\+\t\t(0x[0-9A-Fa-f]+),", match.group(1), re.M)
    ]
    if len(vals) != 9:
        raise AssertionError(f"expected 9 ring offsets in patch, got {len(vals)}")
    return vals


def parse_u16_array_from_patch(patch_text: str, name: str) -> list[int] | None:
    pattern = (
        rf"^\+[^\n]*\b{re.escape(name)}\[3\][^\n]*=\s*\{{([^}}]+)\}};"
    )
    match = re.search(pattern, patch_text, re.M)
    if not match:
        return None
    return [int(tok.strip(), 0) for tok in match.group(1).split(",")]


def make_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def build_synthetic_artifacts(
    workdir: Path,
    ring_offs: list[int],
    msdu_bases: tuple[int, int, int] = (0, 256, 768),
    msdu_limits: tuple[int, int, int] = (256, 512, 1024),
    pool_init_uses_bases: bool = True,
    cross_prefix: str = "fake-",
) -> tuple[Path, Path]:
    """Create a synthetic ELF/bin output dir + fake cross-binutils toolchain.

    Returns (out_dir, bin_dir) inside ``workdir``.
    """
    out_dir = workdir / "out"
    bin_dir = workdir / "bin"
    out_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)

    text_size = 0x1000
    rodata_size = 0x1000
    data_size = 0x100

    raw = bytearray(text_size + rodata_size)
    dbin = bytearray(data_size)

    # Reset vector + fence.i/fence pair at TEXT_BASE..+24.
    raw[0:16] = b"\x01\x00" * 8
    raw[16:20] = b"\x0f\x10\x00\x00"
    raw[20:24] = b"\x0f\x00\xf0\x0f"

    # .rodata contents (offsets relative to TEXT_BASE).
    ver = b"TLB7.8.0.0_v003.MT7996.eagle-v4-ddr\x00"
    raw[0x1000 : 0x1000 + len(ver)] = ver

    offs_off = 0x1100
    struct.pack_into("<9I", raw, offs_off, *ring_offs)

    qid_off = 0x1200
    qid_vals = [
        TEXT_BASE + 0x220,  # qid0 == qid1
        TEXT_BASE + 0x220,
        TEXT_BASE + 0x230,  # qid2 distinct from qid3/4
        TEXT_BASE + 0x240,  # qid3 == qid4 (default)
        TEXT_BASE + 0x240,
        TEXT_BASE + 0x250,  # qid5 == qid6 == qid7
        TEXT_BASE + 0x250,
        TEXT_BASE + 0x250,
        TEXT_BASE + 0x260,  # qid8 == qid9
        TEXT_BASE + 0x260,
        TEXT_BASE + 0x270,  # qid10, qid11, qid12 all distinct
        TEXT_BASE + 0x280,
        TEXT_BASE + 0x290,
    ]
    struct.pack_into("<13I", raw, qid_off, *qid_vals)

    sram_lo_off = 0x1300
    cur = sram_lo_off
    for typ, size in SRAM_SIZE_LO:
        struct.pack_into("<HHI", raw, cur, typ, 0, size)
        cur += 8
    struct.pack_into("<HHI", raw, cur, 0, 0, 0)

    sram_hi_off = 0x1500
    cur = sram_hi_off
    for typ, size in SRAM_SIZE_HI:
        struct.pack_into("<HHI", raw, cur, typ, 0, size)
        cur += 8
    struct.pack_into("<HHI", raw, cur, 0, 0, 0)

    # .data contents (offsets relative to DATA_BASE).
    lim_off = 0x20
    struct.pack_into("<3H", dbin, lim_off, *msdu_limits)

    base_off = 0x40
    struct.pack_into("<3H", dbin, base_off, *msdu_bases)

    handler_addr = TEXT_BASE + 0x200
    ft_off = 0x80
    ft_ptrs = [TEXT_BASE + 0x300 + 4 * i for i in range(10)]
    ft_ptrs[4] = handler_addr
    struct.pack_into("<10I", dbin, ft_off, *ft_ptrs)

    (out_dir / "npu_rv32.bin").write_bytes(raw)
    (out_dir / "npu_data.bin").write_bytes(dbin)
    (out_dir / "firmware.elf").write_bytes(b"\x7fELF" + b"\x00" * 60)

    sym_table = {
        "__ndbg_base": 0x3E906800,
        "wifi_pcie_desc_base": 0x3E901000,
        "off.0": TEXT_BASE + offs_off,
        "eagle_mail_get_rxdesc_base": handler_addr,
        "sram_size_lo": TEXT_BASE + sram_lo_off,
        "sram_size_hi": TEXT_BASE + sram_hi_off,
        "CSWTCH.60": DATA_BASE + lim_off,
        "eagle_msdu_pg_id_limit": DATA_BASE + lim_off,
        "eagle_msdu_pg_id_base": DATA_BASE + base_off,
        "get_wait_func_table": DATA_BASE + ft_off,
        "__image_end": TEXT_BASE + len(raw),
        "__bss_end": 0x3E902000,
    }
    nm_lines = "\n".join(
        f"{addr:08x} T {name}" for name, addr in sym_table.items()
    )

    start_body = "\n".join(
        f"840000{i*8:02x}:\tcsrrs\tt0,mhartid,zero\n"
        f"840000{i*8+4:02x}:\tbeq\tt0,t1,84000100"
        for i in range(8)
    )
    pool_base_insn = (
        f"84000518:\taddi\ta4,a4,64 # {DATA_BASE + base_off:x} <eagle_msdu_pg_id_base>"
        if pool_init_uses_bases
        else "84000518:\taddi\ta4,zero,0"
    )
    dis_text = (
        "\n84000000 <_start>:\n"
        f"{start_body}\n"
        "\n"
        "84000100 <npu_dbg_init>:\n"
        "84000100:\tlui\ta5,0x4e444\n"
        "84000104:\taddi\ta5,a5,583\n"
        "84000108:\tlui\ta0,0x3e907 # 3e906800\n"
        "8400010c:\tlui\ta1,0x3e908 # 3e907800\n"
        "\n"
        "84000200 <eagle_mail_get_rxdesc_base>:\n"
        "84000200:\tc.slli\ta5,0x3\n"
        "84000202:\tc.srli\ta5,0x3\n"
        "\n"
        "84000400 <wifi_pcie_desc_alloc>:\n"
        "84000400:\tlui\ta1,0x3e8a2\n"
        "84000404:\tlui\ta2,0x4a\n"
        "84000408:\taddi\ta2,a2,64\n"
        "8400040c:\tsw\ta1,0(a5) # 3e901000 <wifi_pcie_desc_base>\n"
        "\n"
        "84000500 <eagle_msdu_pg_pool_init>:\n"
        "84000500:\taddi\ta1,a0,18020\n"
        "84000504:\taddi\ta2,a0,19020\n"
        "84000508:\taddi\ta3,a0,1b020\n"
        f"{pool_base_insn}\n"
        "\n"
    )

    readelf_h = "ELF Header:\n  Entry point address:               0x84000000\n"
    readelf_s = textwrap.dedent(
        """\
        Section Headers:
          [Nr] Name              Type            Addr     Off    Size   ES Flg Lk Inf Al
          [ 1] .text             PROGBITS        84000000 001000 001000 00  AX  0   0  4
          [ 2] .rodata           PROGBITS        84001000 002000 001000 00   A  0   0  4
          [ 3] .data             PROGBITS        3e900000 003000 000100 00  WA  0   0  4
        """
    )

    (workdir / "nm.out").write_text(nm_lines + "\n", encoding="utf-8")
    (workdir / "dis.out").write_text(dis_text, encoding="utf-8")
    (workdir / "readelf_h.out").write_text(readelf_h, encoding="utf-8")
    (workdir / "readelf_s.out").write_text(readelf_s, encoding="utf-8")

    make_executable(
        bin_dir / f"{cross_prefix}nm",
        f"#!/bin/sh\ncat '{workdir / 'nm.out'}'\n",
    )
    make_executable(
        bin_dir / f"{cross_prefix}objdump",
        f"#!/bin/sh\ncat '{workdir / 'dis.out'}'\n",
    )
    make_executable(
        bin_dir / f"{cross_prefix}readelf",
        textwrap.dedent(
            f"""\
            #!/bin/sh
            case "$1" in
            -h) cat '{workdir / "readelf_h.out"}' ;;
            -S) cat '{workdir / "readelf_s.out"}' ;;
            *) exit 1 ;;
            esac
            """
        ),
    )
    make_executable(bin_dir / f"{cross_prefix}ld", "#!/bin/sh\nexit 0\n")
    make_executable(bin_dir / f"{cross_prefix}objcopy", "#!/bin/sh\nexit 0\n")
    # Spam >200 KB on --version with default SIGPIPE (matching C gcc) so any
    # early-closing `| head -n 1` terminates fake-gcc with SIGPIPE (exit 141).
    make_executable(
        bin_dir / f"{cross_prefix}gcc",
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import signal, sys
            signal.signal(signal.SIGPIPE, signal.SIG_DFL)
            if "--version" in sys.argv:
                sys.stdout.write("fake-gcc (GCC) 16.2.0\\n")
                chunk = ("copyright-banner-padding-" * 4 + "\\n") * 64
                for _ in range(40):
                    sys.stdout.write(chunk)
                sys.stdout.flush()
            """
        ),
    )

    return out_dir, bin_dir


class BuildEagleV4Test(unittest.TestCase):
    def setUp(self):
        self.script_text = SCRIPT.read_text(encoding="utf-8")
        self.patch_text = extract_heredoc(self.script_text, "EAGLE_V4_PATCH")
        self.verify_src = extract_heredoc(self.script_text, "EAGLE_V4_VERIFY")

    def _run_verify_script(
        self,
        verify_code: str,
        out_dir: Path,
        bin_dir: Path,
        cross_prefix: str = "fake-",
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        return subprocess.run(
            ["python3", "-", str(out_dir), str(REPO_ROOT), cross_prefix],
            input=verify_code,
            text=True,
            capture_output=True,
            env=env,
            timeout=30,
            check=False,
        )

    def test_p0_1_embedded_patch_rings_are_pairwise_disjoint_and_in_arena(self):
        offs = parse_c_ring_offsets(self.patch_text)
        intervals: list[tuple[int, int, str]] = []
        for name, idx, extent in RING_SPECS:
            start = offs[idx]
            end = start + extent
            self.assertGreaterEqual(start, 0, f"{name} negative offset")
            self.assertLessEqual(
                end,
                DESC_SIZE,
                f"{name} [{start:#x}, {end:#x}) exceeds arena {DESC_SIZE:#x}",
            )
            intervals.append((start, end, name))

        intervals.sort()
        for i in range(len(intervals)):
            a_start, a_end, a_name = intervals[i]
            for j in range(i + 1, len(intervals)):
                b_start, b_end, b_name = intervals[j]
                self.assertGreaterEqual(
                    b_start,
                    a_end,
                    f"DMA ring overlap: {a_name} [{a_start:#x}, {a_end:#x}) "
                    f"overlaps {b_name} [{b_start:#x}, {b_end:#x}) "
                    f"by {min(a_end, b_end) - b_start:#x} bytes",
                )

    def test_p0_1_verifier_rejects_overlapping_dma_rings(self):
        tmpdir = tempfile.mkdtemp(prefix="eagle-v4-ring-overlap-")
        self.addCleanup(shutil.rmtree, tmpdir, True)

        # Buggy layout: ring2 at 0x22020 (size 0x6000 -> 0x28020) overlaps
        # ring4 at 0x26040 (size 0x8000 -> 0x2E040) by 0x1FE0 bytes.
        buggy_offs = [
            0x00000, 0x22020, 0x06020, 0x26040,
            0x00000, 0x1F020, 0x18020, 0x19020, 0x1B020,
        ]
        out_dir, bin_dir = build_synthetic_artifacts(Path(tmpdir), buggy_offs)

        # Even if EXPECTED_RING_OFF itself is mutated to the overlapping table,
        # run_verify() must STILL fail on the pairwise interval overlap check.
        mutated_verify = re.sub(
            r"0x28040,\s*#\s*ring4[^\n]*",
            "0x26040,   # mutated overlapping ring4",
            self.verify_src,
        )
        res = self._run_verify_script(mutated_verify, out_dir, bin_dir)
        combined = res.stdout + res.stderr
        self.assertNotEqual(
            res.returncode,
            0,
            f"run_verify() accepted overlapping ring2/ring4 DMA layout:\n{combined}",
        )
        self.assertRegex(
            combined.lower(),
            r"overlap",
            f"expected overlap diagnostic from run_verify(), got:\n{combined}",
        )

    def test_p0_2_embedded_patch_partitions_msdu_pg_ids_disjointly(self):
        # The buggy loop `msdu_pg_pool[band][i] = (u16)i;` aliased all 3 bands
        # onto the same 128 B DRAM pages at eagle_dram_ba_node_addr + (id << 7).
        self.assertIsNone(
            re.search(r"msdu_pg_pool\[band\]\[i\]\s*=\s*\(u16\)i\s*;", self.patch_text),
            "eagle_msdu_pg_pool_init() still assigns identical 0..N-1 IDs per band",
        )

        bases = parse_u16_array_from_patch(self.patch_text, "eagle_msdu_pg_id_base")
        limits = parse_u16_array_from_patch(self.patch_text, "eagle_msdu_pg_id_limit")
        self.assertIsNotNone(
            bases, "eagle_msdu_pg_id_base[3] table missing from embedded patch"
        )
        self.assertIsNotNone(
            limits, "eagle_msdu_pg_id_limit[3] table missing from embedded patch"
        )
        self.assertEqual(limits, [256, 512, 1024])

        intervals = []
        for band, (base, lim) in enumerate(zip(bases, limits)):
            end = base + lim
            self.assertGreaterEqual(base, 0)
            self.assertLessEqual(end, 0x7FFF, f"band{band} IDs overflow s16")
            self.assertLessEqual(
                end * MSDU_PG_ENTRY_SIZE,
                NPU_BA_SIZE,
                f"band{band} MSDU DRAM end exceeds npu_ba ({NPU_BA_SIZE:#x})",
            )
            intervals.append((base, end, band))

        intervals.sort()
        for i in range(len(intervals)):
            a_start, a_end, a_band = intervals[i]
            for j in range(i + 1, len(intervals)):
                b_start, b_end, b_band = intervals[j]
                self.assertGreaterEqual(
                    b_start,
                    a_end,
                    f"MSDU page ID overlap: band{a_band} [{a_start}, {a_end}) "
                    f"overlaps band{b_band} [{b_start}, {b_end})",
                )

    def test_p0_2_verifier_rejects_overlapping_or_oob_msdu_pg_ids(self):
        tmpdir = tempfile.mkdtemp(prefix="eagle-v4-msdu-overlap-")
        self.addCleanup(shutil.rmtree, tmpdir, True)
        script_offs = parse_c_ring_offsets(self.patch_text)

        # Case 1: overlapping bases [0, 0, 0] even if EXPECTED_MSDU_PG_BASES matches.
        out_overlap, bin_overlap = build_synthetic_artifacts(
            Path(tmpdir) / "overlap", script_offs, msdu_bases=(0, 0, 0)
        )
        mutated = re.sub(
            r"EXPECTED_MSDU_PG_BASES\s*=\s*\[[^\]]+\]",
            "EXPECTED_MSDU_PG_BASES = [0, 0, 0]",
            self.verify_src,
        )
        res = self._run_verify_script(mutated, out_overlap, bin_overlap)
        combined = res.stdout + res.stderr
        self.assertNotEqual(
            res.returncode,
            0,
            f"run_verify() accepted overlapping MSDU page ID bases [0, 0, 0]:\n{combined}",
        )
        self.assertRegex(
            combined.lower(),
            r"overlap",
            f"expected MSDU ID overlap error, got:\n{combined}",
        )

        # Case 2: out-of-bounds DRAM offset (> npu_ba 0x200000 / 128 = 16384).
        out_oob, bin_oob = build_synthetic_artifacts(
            Path(tmpdir) / "oob", script_offs, msdu_bases=(0, 256, 16000)
        )
        mutated_oob = re.sub(
            r"EXPECTED_MSDU_PG_BASES\s*=\s*\[[^\]]+\]",
            "EXPECTED_MSDU_PG_BASES = [0, 256, 16000]",
            self.verify_src,
        )
        res_oob = self._run_verify_script(mutated_oob, out_oob, bin_oob)
        combined_oob = res_oob.stdout + res_oob.stderr
        self.assertNotEqual(
            res_oob.returncode,
            0,
            f"run_verify() accepted out-of-bounds MSDU page bases:\n{combined_oob}",
        )

        # Case 3: dead/unwired base table (not referenced by eagle_msdu_pg_pool_init).
        out_dead, bin_dead = build_synthetic_artifacts(
            Path(tmpdir) / "dead",
            script_offs,
            msdu_bases=(0, 256, 768),
            pool_init_uses_bases=False,
        )
        res_dead = self._run_verify_script(self.verify_src, out_dead, bin_dead)
        self.assertNotEqual(
            res_dead.returncode,
            0,
            "run_verify() accepted eagle_msdu_pg_pool_init without per-band base usage",
        )

    def test_p2_4_no_sigpipe_abort_in_require_tools_and_write_manifest(self):
        tmpdir = tempfile.mkdtemp(prefix="eagle-v4-sigpipe-")
        self.addCleanup(shutil.rmtree, tmpdir, True)
        work = Path(tmpdir)

        valid_offs = [
            0x00000, 0x22020, 0x06020, 0x28040,
            0x00000, 0x1F020, 0x18020, 0x19020, 0x1B020,
        ]
        synth_out, bin_dir = build_synthetic_artifacts(work, valid_offs)

        # Fake src checkout + fake git/make so the entire script runs end-to-end
        # through require_tools -> write_patch -> fetch_source -> apply_patch ->
        # build_firmware -> run_verify -> write_manifest with a high-volume
        # fake-gcc --version that triggers SIGPIPE on any `| head -n 1` pipe.
        src_dir = work / "ClankerNPU"
        (src_dir / ".git").mkdir(parents=True)
        out_dir = work / "final-out"
        build_root = work / "build-root"

        pinned = re.search(r'CLANKER_COMMIT:-([0-9a-f]{40})', self.script_text)
        self.assertIsNotNone(pinned)
        commit_sha = pinned.group(1)

        make_executable(
            bin_dir / "git",
            textwrap.dedent(
                f"""\
                #!/bin/sh
                for arg in "$@"; do
                    if [ "$arg" = "rev-parse" ]; then
                        echo "{commit_sha}"
                        exit 0
                    fi
                done
                exit 0
                """
            ),
        )
        make_executable(
            bin_dir / "make",
            textwrap.dedent(
                f"""\
                #!/bin/sh
                mkdir -p build/AN7581_MT7996
                cp '{synth_out / "npu_rv32.bin"}' build/AN7581_MT7996/
                cp '{synth_out / "npu_data.bin"}' build/AN7581_MT7996/
                cp '{synth_out / "firmware.elf"}' build/AN7581_MT7996/
                echo "map" > build/AN7581_MT7996/firmware.map
                """
            ),
        )

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["CROSS"] = "fake-"
        env["BUILD_ROOT"] = str(build_root)

        res = subprocess.run(
            [
                "bash",
                str(SCRIPT),
                "--src-dir",
                str(src_dir),
                "--out-dir",
                str(out_dir),
            ],
            text=True,
            capture_output=True,
            env=env,
            timeout=60,
            check=False,
        )
        combined = res.stdout + res.stderr
        self.assertEqual(
            res.returncode,
            0,
            f"build-eagle-v4.sh aborted (rc={res.returncode}):\n{combined}",
        )
        manifest = (out_dir / "manifest.txt").read_text(encoding="utf-8")
        self.assertIn("toolchain: fake-gcc (GCC) 16.2.0\n", manifest)
        self.assertIn("static_validation: PASS\n", manifest)

    def test_embedded_patch_unified_diff_hunk_counts_are_exact(self):
        lines = self.patch_text.splitlines()
        cur_file = None
        cum_delta = 0
        i = 0
        hunks = 0
        while i < len(lines):
            line = lines[i]
            if line.startswith("diff --git "):
                cur_file = line.split()[-1]
                cum_delta = 0
            elif line.startswith("@@ "):
                hunks += 1
                hm = re.match(r"@@ -(\d+),(\d+) \+(\d+),(\d+) @@", line)
                self.assertIsNotNone(hm, f"malformed hunk header in {cur_file}: {line}")
                old_start, old_cnt, new_start, new_cnt = map(int, hm.groups())
                self.assertEqual(
                    new_start,
                    old_start + cum_delta,
                    f"{cur_file}: hunk new_start {new_start} != "
                    f"old_start({old_start}) + delta({cum_delta})",
                )
                j = i + 1
                act_old = 0
                act_new = 0
                while j < len(lines) and not lines[j].startswith(("diff --git ", "@@ ")):
                    body_line = lines[j]
                    if body_line.startswith("+"):
                        act_new += 1
                    elif body_line.startswith("-"):
                        act_old += 1
                    elif body_line.startswith(" ") or body_line == "":
                        act_old += 1
                        act_new += 1
                    j += 1
                self.assertEqual(
                    (act_old, act_new),
                    (old_cnt, new_cnt),
                    f"{cur_file}: {line} actual=({act_old},{act_new})",
                )
                cum_delta += new_cnt - old_cnt
                i = j
                continue
            i += 1
        self.assertGreater(hunks, 20, "expected >20 hunks in embedded patch")

    def test_dry_run_and_shell_syntax_clean(self):
        dry = subprocess.run(
            ["bash", str(SCRIPT), "--dry-run"],
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("qid2 0x3E8C4020 and qid7 0x3E8CA040", dry.stdout)
        self.assertNotIn("0x3E8C8040", dry.stdout)

        syn = subprocess.run(
            ["python3", str(SHELL_SYNTAX_GATE), str(SCRIPT)],
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(syn.returncode, 0, syn.stdout + syn.stderr)
        self.assertIn("0 failed", syn.stdout)


if __name__ == "__main__":
    unittest.main()
