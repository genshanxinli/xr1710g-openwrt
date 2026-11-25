#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Offline tests for scripts/check-release-image-features.py.

The tests build small fixtures (patches, a fake kernel tree with a stub vmlinux,
a synthetic FIT image and capture files) and run the real CLI against them.
The first section pins the kernel-version resolution down: the patch queue and
the ``linux-<ver>`` tree name the gate uses must follow the version declared in
the subtarget, never a hardcoded 7.3.  They need python3 and, for the
build/image cases, a host C compiler.

Run with::

    python3 scripts/tests/check-release-image-features.py

The kernel-version cases are also collected by unittest::

    python3 -m unittest scripts/tests/check-release-image-features.py -v
"""

from __future__ import annotations

import gzip
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
GATE = Path(
    os.environ.get("RELEASE_GATE_UNDER_TEST")
    or TESTS.parent / "check-release-image-features.py"
)
CC = shutil.which("cc") or shutil.which("gcc")

PATCH_968 = """--- a/drivers/net/ethernet/airoha/airoha_eth.c
+++ b/drivers/net/ethernet/airoha/airoha_eth.c
@@ -1,3 +1,3 @@
-	if (done < budget && napi_complete(napi)) {
+	if (done < budget && napi_complete_done(napi, done)) {
@@ -2,3 +2,3 @@
-	if (done < budget && napi_complete(napi))
+	if (done < budget && napi_complete_done(napi, done))
"""

PATCH_974 = """--- a/drivers/net/ethernet/airoha/airoha_eth.c
+++ b/drivers/net/ethernet/airoha/airoha_eth.c
@@ -1,3 +1,5 @@
+static void airoha_qdma_tx_bql_add(struct airoha_gdm_dev *dev, u16 qidx, unsigned int bytes)
+static void airoha_qdma_tx_bql_flush(struct airoha_eth *eth)
+	netdev_tx_completed_queue(txq, pkts, bytes);
"""

SOURCE_968_974 = """static int airoha_qdma_rx_poll(struct napi_struct *napi, int budget)
{
	if (done < budget && napi_complete_done(napi, done))
		return 1;
	return 0;
}
static int airoha_qdma_tx_poll(struct napi_struct *napi, int budget)
{
	if (done < budget && napi_complete_done(napi, done))
		return 1;
	return 0;
}
static void airoha_qdma_tx_bql_add(struct airoha_gdm_dev *dev, u16 qidx, unsigned int bytes) { }
static void airoha_qdma_tx_bql_flush(struct airoha_eth *eth)
{
	netdev_tx_completed_queue(txq, pkts, bytes);
}
"""

SOURCE_NO_974 = """static int airoha_qdma_rx_poll(struct napi_struct *napi, int budget)
{
	if (done < budget && napi_complete_done(napi, done))
		return 1;
	return 0;
}
static int airoha_qdma_tx_poll(struct napi_struct *napi, int budget)
{
	if (done < budget && napi_complete_done(napi, done))
		return 1;
	return 0;
}
"""

HEADER_BQL = """struct airoha_gdm_dev {
	struct { unsigned int pkts; unsigned int bytes; } bql[16];
	unsigned long bql_dirty;
};
"""

STUB_C = r"""
const char kernel_version[] = "Linux version 7.3 test-build";
static void airoha_qdma_tx_bql_add(unsigned int *bytes, unsigned int n)
{
	*bytes += n;
}
static void airoha_qdma_tx_bql_flush(unsigned int *bytes)
{
	(void)bytes;
}
int airoha_qdma_tx_round(unsigned int n)
{
	unsigned int bytes = 0;
	airoha_qdma_tx_bql_add(&bytes, n);
	airoha_qdma_tx_bql_flush(&bytes);
	return (int)bytes;
}
int main(void) { return airoha_qdma_tx_round(1); }
"""

STUB_NO_BQL = r"""
const char kernel_version[] = "Linux version 7.3 test-build";
int main(void) { return 0; }
"""

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS: {name}")
    else:
        print(f"  FAIL: {name}{(': ' + detail) if detail else ''}")
        FAILURES.append(name)


def run_gate(*args: str) -> tuple[int, str]:
    result = subprocess.run(
        [sys.executable, str(GATE), *args], capture_output=True, text=True, timeout=180
    )
    return result.returncode, result.stdout + result.stderr


def write(path: Path, text: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(text, bytes):
        path.write_bytes(text)
    else:
        path.write_text(text)


def write_patch_queue(repo: Path, kver: str, bad: bool = False) -> None:
    patch_dir = repo / f"target/linux/airoha/patches-{kver}"
    patch_dir.mkdir(parents=True, exist_ok=True)
    write(patch_dir / "968-net-airoha-pass-the-real-work-done.patch",
          "not the expected hunk\n" if bad else PATCH_968)
    write(patch_dir / "974-net-airoha-report-tx-completions.patch",
          "not the expected hunk\n" if bad else PATCH_974)


def make_repo(root: Path, patches: bool = True, bad_patches: bool = False,
              kver: str = "7.3", patchver: str | None = None) -> Path:
    """A repo whose subtarget declares ``patchver`` (default: ``kver``)."""
    repo = root / "repo"
    write(repo / "target/linux/airoha/an7581/target.mk",
          f"KERNEL_PATCHVER:={patchver or kver}\n")
    if patches:
        write_patch_queue(repo, kver, bad_patches)
    return repo


def make_build(root: Path, source: str = SOURCE_968_974, header: str = HEADER_BQL,
               stale: bool = False, bql_symbols: bool = True,
               image_before_vmlinux: bool = False,
               vmlinux_version: str | None = None,
               kver: str = "7.3", dirname: str | None = None) -> Path:
    if CC is None:
        raise RuntimeError("a C compiler is needed for the build fixture")
    build = root / "build"
    kernel = build / (dirname or f"linux-{kver}")
    driver = kernel / "drivers/net/ethernet/airoha"
    write(driver / "airoha_eth.c", source)
    write(driver / "airoha_eth.h", header)
    write(kernel / ".config", "CONFIG_BQL=y\n")
    stub = (STUB_C if bql_symbols else STUB_NO_BQL).replace("7.3", kver)
    write(root / "stub.c", stub)
    # Compile the way the kernel does: -O2 -g.  The 974 helpers are `static`
    # with one caller each, so they are inlined and never reach .symtab; only
    # the debug strings remember their names.  That is exactly the shape the
    # gate has to accept, so the fixture must produce it.
    flags = ["-O2", "-g", "-c"]
    subprocess.run([CC, *flags, str(root / "stub.c"), "-o", str(driver / "airoha_eth.o")],
                   check=True, capture_output=True)
    # ``vmlinux_version`` gives the vmlinux a different build string than the
    # Image, i.e. two binaries from different compiles that sit in one build
    # directory with a healthy-looking mtime order.
    vmlinux_src = root / "stub.c"
    if vmlinux_version is not None:
        vmlinux_src = root / "stub-vmlinux.c"
        write(vmlinux_src, stub.replace(
            f"Linux version {kver} test-build", f"Linux version {kver} {vmlinux_version}"))
    subprocess.run([CC, "-O2", "-g", str(vmlinux_src), "-o", str(kernel / "vmlinux")],
                   check=True, capture_output=True)
    write(build / "Image", f"Linux version {kver} test-build\n".encode() + b"K" * 64)
    # A healthy build: source oldest, then object, vmlinux, Image.
    base = 1_700_000_000
    os.utime(driver / "airoha_eth.c", (base, base))
    os.utime(driver / "airoha_eth.h", (base, base))
    os.utime(kernel / ".config", (base, base))
    os.utime(driver / "airoha_eth.o", (base + 10, base + 10))
    if stale:
        os.utime(kernel / "vmlinux", (base + 5, base + 5))
    elif image_before_vmlinux:
        os.utime(build / "Image", (base + 15, base + 15))
        os.utime(kernel / "vmlinux", (base + 20, base + 20))
    else:
        os.utime(kernel / "vmlinux", (base + 20, base + 20))
    if not image_before_vmlinux:
        os.utime(build / "Image", (base + 30, base + 30))
    return build


def fdt_node(name: str, props: dict[str, bytes], children: list[dict]) -> dict:
    return {"name": name, "props": props, "children": children}


def build_fdt(root: dict) -> bytes:
    strings = bytearray()
    offsets: dict[str, int] = {}
    struct_block = bytearray()

    def name_offset(name: str) -> int:
        if name not in offsets:
            offsets[name] = len(strings)
            strings.extend(name.encode() + b"\0")
        return offsets[name]

    def pad4(value: bytes) -> bytes:
        return value + b"\0" * ((4 - len(value) % 4) % 4)

    def emit(node: dict) -> None:
        struct_block.extend(struct.pack(">I", 1))  # FDT_BEGIN_NODE
        struct_block.extend(pad4(node["name"].encode() + b"\0"))
        for name, value in node["props"].items():
            struct_block.extend(struct.pack(">III", 3, len(value), name_offset(name)))
            struct_block.extend(pad4(value))
        for child in node["children"]:
            emit(child)
        struct_block.extend(struct.pack(">I", 2))  # FDT_END_NODE

    emit(root)
    struct_block.extend(struct.pack(">I", 9))  # FDT_END
    reserve = struct.pack(">QQ", 0, 0)
    off_struct = 40
    off_rsv = off_struct + len(struct_block)
    off_strings = off_rsv + len(reserve)
    total = off_strings + len(strings)
    header = struct.pack(
        ">10I",
        0xD00DFEED,
        total,
        off_struct,
        off_strings,
        off_rsv,
        17,
        16,
        0,
        len(strings),
        len(struct_block),
    )
    return header + bytes(struct_block) + reserve + bytes(strings)


DEFAULT_MANIFEST = {"ip-bridge": "6.18.0-r2", "coreutils-base64": "9.11-r1"}


def make_image(root: Path, build: Path, corrupt: bool = False, no_kernel: bool = False,
               manifest: dict[str, str] | None = None,
               with_manifest: bool = True) -> Path:
    image_dir = root / "images"
    image_dir.mkdir(parents=True, exist_ok=True)
    if with_manifest:
        lines = ["# pkg - version"] + [
            f"{pkg} - {ver}" for pkg, ver in (DEFAULT_MANIFEST if manifest is None else manifest).items()
        ]
        (image_dir / "openwrt-airoha-an7581-gemtek_xr1710g-ubi.manifest").write_text(
            "\n".join(lines) + "\n"
        )
    kernel_bytes = (build / "Image").read_bytes()
    payload = gzip.compress(kernel_bytes if not corrupt else kernel_bytes + b"different")
    props = {
        "data-size": struct.pack(">I", len(payload)),
        "data-position": struct.pack(">I", 0x1000),
        "compression": b"gzip\0",
        "type": b"kernel\0",
        "arch": b"arm64\0",
        "os": b"linux\0",
    }
    images = [] if no_kernel else [fdt_node("kernel-1", props, [])]
    root_node = fdt_node(
        "",
        {"description": b"test FIT\0"},
        [
            fdt_node("images", {}, images),
            fdt_node("configurations", {"default": b"config-1\0"}, [
                fdt_node("config-1", {"kernel": b"kernel-1\0"}, []),
            ]),
        ],
    )
    dtb = build_fdt(root_node)
    blob = dtb + b"\0" * (0x1000 - len(dtb)) + payload
    path = image_dir / "openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb"
    path.write_bytes(blob)
    return image_dir


def test_source() -> None:
    print("source checks")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        repo = make_repo(root, patches=False)
        rc, out = run_gate("--repo", str(repo), "--skip-build", "--skip-image")
        check("missing patches fail", rc == 1 and "968" in out and "974" in out, out[-300:])

        repo = make_repo(root / "ok")
        rc, out = run_gate("--repo", str(repo), "--skip-build", "--skip-image")
        check("real patch shapes pass", rc == 0, out[-300:])

        repo = make_repo(root / "bad", bad_patches=True)
        rc, out = run_gate("--repo", str(repo), "--skip-build", "--skip-image")
        check("wrong patch contents fail", rc == 1, out[-300:])


def test_build() -> None:
    print("build checks")
    if CC is None:
        print("  SKIP: no C compiler")
        return
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        repo = make_repo(root)
        build = make_build(root)
        rc, out = run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        check("healthy build passes", rc == 0, out[-400:])

        build = make_build(root / "stale", stale=True)
        rc, out = run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        check("stale vmlinux fails", rc == 1 and "older" in out, out[-400:])

        build = make_build(root / "nosym", source=SOURCE_NO_974)
        rc, out = run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        check("missing 974 source fails", rc == 1 and "974" in out, out[-400:])

        # Source carries the code, but the compiled object does not: this is a
        # kernel that was not rebuilt after the patch was added.
        build = make_build(root / "nosymobj", bql_symbols=False)
        rc, out = run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        check("974 symbols missing from the object fail",
              rc == 1 and "missing symbol" in out, out[-400:])

        # The shape every real OpenWrt build has: Kernel/CompileImage/Default
        # writes Image first, then Kernel/CompileImage/Initramfs re-links
        # vmlinux.  Image is therefore older than vmlinux while both describe
        # the same kernel, and that must not be reported as a stale image.
        build = make_build(root / "initramfs-relink", image_before_vmlinux=True)
        rc, out = run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        check("Image older than vmlinux is not a failure", rc == 0, out[-400:])

        # The converse: the mtimes look healthy but the two binaries describe
        # different builds.  The build string is the judgement, so this must
        # fail instead of passing on timestamps.
        build = make_build(root / "buildid", vmlinux_version="test-build-other")
        rc, out = run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        check("Image and vmlinux from different builds fail",
              rc == 1 and "different builds" in out, out[-400:])

        # A non-ELF file containing the symbol names as raw text must never pass
        # require_symbols() just because the byte substrings appear in the file.
        build = make_build(root / "nonelf")
        obj = build / "linux-7.3/drivers/net/ethernet/airoha/airoha_eth.o"
        obj.write_bytes(b"NOT_ELF airoha_qdma_tx_bql_add airoha_qdma_tx_bql_flush\n")
        base = 1_700_000_000
        os.utime(obj, (base + 10, base + 10))
        rc, out = run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        check("non-ELF object carrying symbol text fails",
              rc == 1 and "ELF" in out, out[-400:])


def test_image() -> None:
    print("image checks")
    if CC is None:
        print("  SKIP: no C compiler")
        return
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        repo = make_repo(root)
        build = make_build(root)
        image_dir = make_image(root, build)
        rc, out = run_gate(
            "--repo", str(repo), "--build-dir", str(build), "--image-dir", str(image_dir)
        )
        check("FIT kernel hash matches", rc == 0 and "sha256 matches" in out, out[-400:])

        image_dir = make_image(root / "bad", build, corrupt=True)
        rc, out = run_gate(
            "--repo", str(repo), "--build-dir", str(build), "--image-dir", str(image_dir)
        )
        check("different FIT kernel fails", rc == 1 and "not Image" in out, out[-400:])

        image_dir = make_image(root / "nokernel", build, no_kernel=True)
        rc, out = run_gate(
            "--repo", str(repo), "--build-dir", str(build), "--image-dir", str(image_dir)
        )
        check("FIT without kernel node fails", rc != 0, out[-300:])


def test_image_tooling() -> None:
    print("image CLI tooling checks")
    if CC is None:
        print("  SKIP: no C compiler")
        return
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        repo = make_repo(root)
        build = make_build(root)

        image_dir = make_image(root / "ok", build)
        rc, out = run_gate(
            "--repo", str(repo), "--build-dir", str(build), "--image-dir", str(image_dir)
        )
        check(
            "manifest with both providers passes",
            rc == 0 and "required CLI packages present: coreutils-base64, ip-bridge" in out,
            out[-400:],
        )

        image_dir = make_image(root / "nopkg", build, manifest={"ip-bridge": "6.18.0-r2"})
        rc, out = run_gate(
            "--repo", str(repo), "--build-dir", str(build), "--image-dir", str(image_dir)
        )
        check(
            "missing coreutils-base64 fails",
            rc == 1 and "missing required CLI package(s): coreutils-base64" in out,
            out[-400:],
        )

        image_dir = make_image(root / "nomanifest", build, with_manifest=False)
        rc, out = run_gate(
            "--repo", str(repo), "--build-dir", str(build), "--image-dir", str(image_dir)
        )
        check("missing manifest is exit 3", rc == 3 and "manifest" in out, out[-400:])

        # rootfs-1 without data-position warns specifically about missing
        # data-position rather than blaming missing unsquashfs.
        def write_fit_with_rootfs(dest_dir: Path, rootfs_props: dict[str, bytes]) -> Path:
            dest_dir.mkdir(parents=True, exist_ok=True)
            lines = ["# pkg - version"] + [f"{k} - {v}" for k, v in DEFAULT_MANIFEST.items()]
            (dest_dir / "openwrt-airoha-an7581-gemtek_xr1710g-ubi.manifest").write_text(
                "\n".join(lines) + "\n"
            )
            kernel_bytes = (build / "Image").read_bytes()
            payload = gzip.compress(kernel_bytes)
            kprops = {
                "data-size": struct.pack(">I", len(payload)),
                "data-position": struct.pack(">I", 0x1000),
                "compression": b"gzip\0",
                "type": b"kernel\0",
                "arch": b"arm64\0",
                "os": b"linux\0",
            }
            root_node = fdt_node(
                "",
                {"description": b"test FIT\0"},
                [
                    fdt_node("images", {}, [
                        fdt_node("kernel-1", kprops, []),
                        fdt_node("rootfs-1", rootfs_props, []),
                    ]),
                    fdt_node("configurations", {"default": b"config-1\0"}, [
                        fdt_node("config-1", {"kernel": b"kernel-1\0"}, []),
                    ]),
                ],
            )
            dtb = build_fdt(root_node)
            blob = dtb + b"\0" * (0x1000 - len(dtb)) + payload
            (dest_dir / "openwrt-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb").write_bytes(blob)
            return dest_dir

        nopos_dir = write_fit_with_rootfs(root / "rootfs-nopos", {"type": b"filesystem\0"})
        rc, out = run_gate(
            "--repo", str(repo), "--build-dir", str(build), "--image-dir", str(nopos_dir)
        )
        check(
            "rootfs-1 without data-position names data-position (not unsquashfs)",
            rc == 0 and "no data-position" in out and "unsquashfs unavailable" not in out,
            out[-400:],
        )

        # Fake unsquashfs listing a decoy suffix path squashfs-root/tmp/fake/bin/base64
        # must fail exact squashfs-root{path} matching.
        pos_dir = write_fit_with_rootfs(
            root / "rootfs-pos",
            {"type": b"filesystem\0", "data-position": struct.pack(">I", 0x2000)},
        )
        fake_bin = root / "fake-unsquashfs"
        fake_bin.mkdir()
        fake_usq = fake_bin / "unsquashfs"
        fake_usq.write_text(
            "#!/bin/sh\nprintf 'squashfs-root/usr/sbin/bridge\\nsquashfs-root/tmp/fake/bin/base64\\n'\n"
        )
        fake_usq.chmod(0o755)
        decoy_proc = subprocess.run(
            [sys.executable, str(GATE), "--repo", str(repo),
             "--build-dir", str(build), "--image-dir", str(pos_dir)],
            env=dict(os.environ, PATH=f"{fake_bin}:{os.environ.get('PATH', '')}"),
            capture_output=True, text=True, timeout=180,
        )
        decoy_out = decoy_proc.stdout + decoy_proc.stderr
        check(
            "decoy suffix squashfs-root/tmp/fake/bin/base64 does not satisfy /bin/base64",
            decoy_proc.returncode == 1 and "/bin/base64" in decoy_out,
            decoy_out[-400:],
        )


class KernelVersionResolution(unittest.TestCase):
    """The gate must judge the image with its own version's patch queue.

    PR #277 moved the an7581 testing kernel to 7.4 while the gate still said
    linux-7.3 and patches-7.3, so a real 7.4 tree was rejected outright and a
    7.4 image would have been judged by 7.3's 968/974.  The last case is the
    dangerous half: it fails only if PATCHES_REL follows the resolved version.
    """

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_gate(self, *args: str) -> tuple[int, str]:
        rc, out = run_gate(*args)
        return rc, out

    def test_74_target_mk_and_rc_tree_resolve_to_patches_74(self) -> None:
        # The shape PR #277 produces: target.mk says 7.4, the build dir holds
        # linux-7.4-rc3 only.  linux-7.40 is a decoy that must not be mistaken
        # for 7.4 (it has no vmlinux, so picking it would fail loudly).
        repo = make_repo(self.root, kver="7.4", patchver="7.4")
        build = make_build(self.root, kver="7.4", dirname="linux-7.4-rc3")
        write(build / "linux-7.40/drivers/net/ethernet/airoha/airoha_eth.c", SOURCE_968_974)
        rc, out = self.run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        self.assertEqual(rc, 0, out[-500:])
        self.assertIn("patches: patches-7.4", out)
        self.assertIn("linux-7.4-rc3", out)
        self.assertNotIn("linux-7.40", out)

    def test_73_tree_still_resolves_to_patches_73(self) -> None:
        repo = make_repo(self.root, kver="7.3", patchver="7.3")
        build = make_build(self.root, kver="7.3")
        rc, out = self.run_gate("--repo", str(repo), "--build-dir", str(build), "--skip-image")
        self.assertEqual(rc, 0, out[-500:])
        self.assertIn("patches: patches-7.3", out)
        self.assertIn("kernel build: " + str(build / "linux-7.3"), out)

    def test_missing_974_in_patches_74_is_a_failure(self) -> None:
        # patches-7.3 keeps 974, so reading 7.3 instead would print PASS.
        repo = make_repo(self.root, kver="7.4", patchver="7.4")
        write_patch_queue(repo, "7.3")
        (repo / "target/linux/airoha/patches-7.4/"
                 "974-net-airoha-report-tx-completions.patch").unlink()
        rc, out = self.run_gate("--repo", str(repo), "--skip-build", "--skip-image")
        self.assertEqual(rc, 1, out[-500:])
        self.assertIn("974: no patch in target/linux/airoha/patches-7.4", out)
        self.assertNotIn("patches-7.3", out)

    def test_explicit_kver_selects_the_old_queue(self) -> None:
        repo = make_repo(self.root, kver="7.3", patchver="7.4")
        rc, out = self.run_gate("--repo", str(repo), "--kver", "7.3",
                                "--skip-build", "--skip-image")
        self.assertEqual(rc, 0, out[-500:])
        self.assertIn("patches: patches-7.3", out)

    def test_target_makefile_reads_kernel_testing_patchver_not_kernel_patchver(self) -> None:
        # When subtarget target.mk has no KERNEL_PATCHVER, target/linux/airoha/Makefile
        # declares both KERNEL_PATCHVER:=6.18 and KERNEL_TESTING_PATCHVER:=7.4.
        # The fallback targets KERNEL_TESTING_PATCHVER specifically, not 6.18.
        repo = self.root / "repo-testing"
        write(
            repo / "target/linux/airoha/Makefile",
            "KERNEL_PATCHVER:=6.18\nKERNEL_TESTING_PATCHVER:=7.4\n",
        )
        write_patch_queue(repo, "7.4")
        rc, out = self.run_gate("--repo", str(repo), "--skip-build", "--skip-image")
        self.assertEqual(rc, 0, out[-500:])
        self.assertIn("patches: patches-7.4", out)
        self.assertNotIn("patches-6.18", out)


def _flatten(suite) -> list:
    flat = []
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            flat.extend(_flatten(item))
        else:
            flat.append(item)
    return flat


def test_kernel_version() -> None:
    print("kernel version resolution")
    if CC is None:
        print("  SKIP: no C compiler")
        return
    tests = _flatten(unittest.defaultTestLoader.loadTestsFromTestCase(KernelVersionResolution))
    result = unittest.TestResult()
    unittest.TestSuite(tests).run(result)
    broken = {test.id(): text for test, text in result.failures + result.errors}
    for test in tests:
        name = test.id().rsplit(".", 1)[-1]
        detail = broken.get(test.id(), "")
        if detail:
            detail = detail.strip().splitlines()[-1]
        check(name, test.id() not in broken, detail)


def test_usage() -> None:
    print("usage checks")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        repo = make_repo(root)
        rc, out = run_gate("--repo", str(repo), "--image-dir", str(root / "none"))
        check("missing image directory is a usage error", rc == 2, out[-300:])

        rc, out = run_gate("--repo", str(repo), "--skip-source", "--skip-build", "--skip-image")
        check("no requested check is a usage error", rc == 2, out[-300:])


def test_capture() -> None:
    print("capture checks")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        good = root / "good.txt"
        # The probe script emits "max_inflight = 116038" with spaces; keep that
        # exact shape so the parser is tested against the real capture format.
        good.write_text(
            "@@@BQL shrink\n"
            "cpu/tx-16   min_limit = 210290   max_limit = 529246   max_inflight = 116038\n"
        )
        rc, out = run_gate("--capture", str(good), "--skip-source", "--skip-build", "--skip-image")
        # The probe prints the sysfs field names (min_limit/max_limit), not "limit".
        # The note is the only observable that separates "limit was read" from
        # "limit was skipped", so assert its value, not just the exit code.
        check(
            "inflight >= 64 KiB passes and reports the observed BQL limit",
            rc == 0 and "observed BQL limit up to 529246 bytes" in out,
            out[-300:],
        )

        # A BQL cap below 64 KiB can never hold 64 KiB in flight, so a high
        # inflight sample alone must not pass: the limit has to be checked too.
        capped = root / "capped.txt"
        capped.write_text(
            "@@@BQL shrink\n"
            "cpu/tx-16   min_limit = 20000   max_limit = 40000   max_inflight = 116038\n"
        )
        rc, out = run_gate("--capture", str(capped), "--skip-source", "--skip-build", "--skip-image")
        check("BQL limit below 64 KiB fails", rc == 1 and "below" in out, out[-300:])

        # Static sysfs limit_max (~1.8 GiB) must NOT mask a dynamic limit below
        # 64 KiB (P1-7): only dynamic limit / min_limit / max_limit count.
        static_max = root / "static_max.txt"
        static_max.write_text(
            "cpu/tx-16   limit_max=1879048192   limit=40000   max_inflight=116038\n"
        )
        rc, out = run_gate(
            "--capture", str(static_max), "--skip-source", "--skip-build", "--skip-image"
        )
        check(
            "static limit_max does not mask dynamic limit below 64 KiB",
            rc == 1 and "40000" in out and "below" in out and "1879048192" not in out,
            out[-300:],
        )

        low = root / "low.txt"
        low.write_text("cpu/tx-16 l=2908 i=2884\n")
        rc, out = run_gate("--capture", str(low), "--skip-source", "--skip-build", "--skip-image")
        check("inflight below 64 KiB fails", rc == 1 and "below" in out, out[-300:])

        empty = root / "empty.txt"
        empty.write_text("ethtool -S only, no BQL samples\n")
        rc, out = run_gate("--capture", str(empty), "--skip-source", "--skip-build", "--skip-image")
        check("capture without samples fails", rc == 1 and "no byte_queue_limits" in out, out[-300:])


def main() -> int:
    test_source()
    test_build()
    test_image()
    test_image_tooling()
    test_kernel_version()
    test_usage()
    test_capture()
    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} test(s): {', '.join(FAILURES)}")
        return 1
    print("all tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
