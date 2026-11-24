#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The --execute push must not need sftp (issue #12).

The defect, measured on the board itself:

    $ ssh root@192.168.1.1 'ls /usr/libexec/sftp-server'
    ls: /usr/libexec/sftp-server: No such file or directory
    $ ssh root@192.168.1.1 'readlink -f /usr/bin/ssh'
    /usr/bin/dropbear

so ``scp`` in its default (SFTP) mode dies at ``subsystem request failed``, and
``scp -O`` needs a remote ``scp`` binary that busybox does not ship either.
busybox ``tar`` does exist, so the transfer is ``tar -cf - | ssh ... tar -xf -``
and nothing on the device has to change.

These cases run the real script with the device replaced by a stub ``ssh`` (the
same shape as scripts/tests/test_2g5_ssh_unreachable.py): read-only probes
answer from fixtures, everything else runs locally with ``/tmp`` re-rooted into
a temporary directory, so the script's own ``tar``/``mv``/``sha256sum`` do the
actual work.  There is also a stub ``scp`` that fails exactly the way the
device does, so a copy of the script that still pushes with scp cannot pass by
accident.

Run from the repository root:

    python3 scripts/tests/test_recovery_transfer.py

RECOVERY_DRYRUN_UNDER_TEST=/path/to/copy runs the same cases against another
copy of the script -- that env var is how the red proof is taken:

    git -C . show 83aeaa84c9:scripts/recovery-boot-dryrun.sh > /tmp/bad.sh
    RECOVERY_DRYRUN_UNDER_TEST=/tmp/bad.sh \\
        python3 scripts/tests/test_recovery_transfer.py
"""

import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("RECOVERY_DRYRUN_UNDER_TEST")
    or REPO_ROOT / "scripts/recovery-boot-dryrun.sh"
)

IMG_NAME = "openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb"
NAME = "initramfs-recovery.itb"
HOST = "root@192.168.1.1"
EXIT_IMAGE = 6

# A device-shaped ssh.  The read-only probes answer from fixtures; every other
# command is the script's own remote command line, run locally with /tmp
# rewritten into $SSH_DEVICE, so tar/mv/sha256sum behave exactly as on the box.
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
[ $# -ge 2 ] || { printf 'ssh: no command\\n' >&2; exit 255; }
shift
cmd=$*
case "$cmd" in
*board_name*) cat "$fix/probe.txt"; exit 0 ;;
*"dd if=/dev/ubi0_2"*) cat "$fix/slot.bin"; exit 0 ;;
*"cat /proc/cmdline; cat /proc/mtd"*) cat "$fix/meta.txt"; exit 0 ;;
esac
# An interrupted session: tar has written part of the file when the link dies.
if [ -n "${SSH_TRUNCATE:-}" ] && printf '%s' "$cmd" | grep -q 'tar -C'; then
\thead -c 100 > "$dev/$SSH_TRUNCATE"
\tprintf 'Connection to %s closed.\\n' "$SSH_TRUNCATE" >&2
\texit 1
fi
# Every /tmp the remote command mentions is re-rooted into the stub's device
# directory, bare path included (``tar -C /tmp``), so the case can never write
# to the host's /tmp.
rewritten=$(printf '%s\\n' "$cmd" | sed "s#/tmp#$dev#g")
exec sh -c "$rewritten"
"""

# The device's scp in default mode: OpenSSH >= 9 asks for the sftp subsystem,
# dropbear has none to offer.  Same two lines a real run printed on the board.
SCP_STUB = """\
#!/bin/sh
printf 'scp %s\\n' "$*" >> "${SSH_FIXTURES}/scp.log"
printf 'subsystem request failed on channel 0\\n' >&2
printf 'scp: Connection closed\\n' >&2
exit 1
"""

SYSUPGRADE_STUB = """\
#!/bin/sh
printf 'sysupgrade %s\\n' "$*" >> "${SSH_FIXTURES}/sysupgrade.log"
printf 'Image check failed.\\n'
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

META = """\
console=ttyS0,115200 ubi.block=0,fit root=/dev/ubiblock0_0
dev:    size   erasesize  name
mtd0: 10000000 00020000 "ubi"
"""

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
bootargs=console=ttyS0,115200 ubi.block=0,fit
bootcmd=run boot_ubi || http_recovery
loadaddr=0x85000000
--- fitblk
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


class TransferTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="recovfix-transfer-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.fix = self.tmp / "fixtures"
        self.dev = self.tmp / "device"
        self.imgdir = self.tmp / "image"
        self.restore = self.tmp / "restore"
        for d in (self.bin, self.fix, self.dev, self.imgdir):
            d.mkdir()

        self.sh = shutil.which("sh")
        self.assertIsNotNone(self.sh)

        # 1 MiB of bytes that are neither 0x00 nor the "FWx0" tail marker.
        image = bytes(range(0x41, 0x41 + 26)) * 40330
        image = image[: 1024 * 1024]
        self.image_sha = hashlib.sha256(image).hexdigest()
        (self.imgdir / IMG_NAME).write_bytes(image)
        (self.imgdir / "sha256sums").write_text(
            "%s *%s\n" % (self.image_sha, IMG_NAME)
        )

        slot = bytes(range(64)) * 16384
        self.slot_sha = hashlib.sha256(slot).hexdigest()
        (self.fix / "slot.bin").write_bytes(slot)
        (self.fix / "meta.txt").write_text(META)
        (self.fix / "probe.txt").write_text(
            PROBE.replace("%SLOT_SHA%", self.slot_sha).replace(
                "%SLOT_LEN%", str(len(slot))
            )
        )

        for name, body in (
            ("ssh", SSH_STUB),
            ("scp", SCP_STUB),
            ("sysupgrade", SYSUPGRADE_STUB),
            ("dumpimage", DUMPIMAGE_STUB),
        ):
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)

    def env(self, **extra):
        env = dict(os.environ)
        env["PATH"] = "%s:%s" % (self.bin, env.get("PATH", ""))
        env["SSH_DEVICE"] = str(self.dev)
        env["SSH_FIXTURES"] = str(self.fix)
        env.update(extra)
        return env

    def run_script(self, **extra):
        return subprocess.run(
            [
                self.sh,
                str(SCRIPT),
                "--execute",
                "--image",
                str(self.imgdir / IMG_NAME),
                "--host",
                HOST,
                "--dir",
                str(self.restore),
            ],
            capture_output=True,
            text=True,
            env=self.env(**extra),
            timeout=120,
        )

    def assert_no_scp(self):
        scp_log = self.fix / "scp.log"
        self.assertFalse(
            scp_log.exists(),
            "the transfer must not need sftp (nor a remote scp binary), "
            "but scp was called:\n%s"
            % (scp_log.read_text() if scp_log.exists() else ""),
        )

    def test_push_does_not_need_sftp(self):
        result = self.run_script()
        pushed = self.dev / NAME
        self.assertTrue(
            pushed.exists(),
            "the transfer must not need sftp: the device has no "
            "/usr/libexec/sftp-server, so a scp push cannot reach it; "
            "script said:\n%s%s"
            % (result.stdout, result.stderr),
        )
        self.assertEqual(
            hashlib.sha256(pushed.read_bytes()).hexdigest(),
            self.image_sha,
            "the pushed bytes must be the image, not a truncated copy",
        )
        self.assert_no_scp()
        self.assertEqual(
            sorted(p.name for p in self.dev.iterdir()),
            [NAME],
            "the device side must end with exactly the pushed name",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "sysupgrade -F -n",
            (self.fix / "sysupgrade.log").read_text(),
        )

    def test_interrupted_push_leaves_no_half_image(self):
        result = self.run_script(SSH_TRUNCATE=NAME)
        self.assert_no_scp()
        self.assertEqual(
            result.returncode,
            EXIT_IMAGE,
            "a broken push must exit %d, got %d:\n%s%s"
            % (EXIT_IMAGE, result.returncode, result.stdout, result.stderr),
        )
        self.assertIn("transfer failed", result.stdout)
        self.assertIn(
            NAME,
            (self.fix / "ssh.log").read_text(),
            "the failure path must clean up the device copies",
        )
        self.assertEqual(
            sorted(p.name for p in self.dev.iterdir()),
            [],
            "a broken push must not leave half an image on the device",
        )
        self.assertFalse(
            (self.fix / "sysupgrade.log").exists(),
            "nothing may be flashed when the image did not arrive",
        )


if __name__ == "__main__":
    unittest.main()
