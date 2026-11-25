#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""qdma-irq-affinity must not fail silently on the IRQs it cannot move.

On the live board (r38269-42c216064b, 7.4-rc3) both mt7996e vectors sit on
cpu0 with ``/proc/irq/49/effective_affinity=0`` and
``/proc/irq/49/affinity_hint=0`` while ``smp_affinity=f``, and every write to
that file comes back ``-EPERM``: ``pcie-mediatek-gen3`` asks the MSI
allocator for ``MSI_FLAG_NO_AFFINITY``, so the IRQ chip has no
``->irq_set_affinity`` and ``__irq_can_set_affinity()`` refuses the write.
The script only ever spoke on success:

    if echo "$mask" > "/proc/irq/$irq/smp_affinity" 2>/dev/null; then
        log "irq $irq pinned to cpu$cpu"
    fi

so a run that could not move the Wi-Fi lines looked exactly like a run that
had nothing to do.

What is asserted here, offline, against a fixture ``/proc`` and ``/sys``:

  * a PCI function whose MSI vectors reject the affinity write is named once
    per vector, with ``MSI_FLAG_NO_AFFINITY`` and the reason, and its
    ``smp_affinity`` is left exactly as it was;
  * a line outside an MSI domain still fails loudly when the write is
    rejected: the log carries the IRQ, the mask it tried and the shell's own
    message, and the run carries on to the next line instead of stopping;
  * a movable MSI domain is not mistaken for an immovable one: its vector is
    pinned as before;
  * a rejected write on the *last* line does not turn the boot into
    "failed": main() feeds pin_irq from a pipe, so the last status is the
    service status;
  * the QDMA policy is unchanged: bank0 of qdma0 -> cpu0, bank0 of qdma1 ->
    cpu1, the remaining banks and the NPU lines round-robin over cpu2/cpu3.

Red half: run this file with ``QDMA_IRQ_AFFINITY_UNDER_TEST`` pointing at the
pre-fix script (``git show HEAD:target/linux/airoha/an7581/base-files/etc/init.d/qdma-irq-affinity``).
The rejected writes leave the log empty, so
``test_rejection_is_named_and_the_mask_is_left_alone`` fails with no
``MSI_FLAG_NO_AFFINITY`` line,
``test_rejection_carries_irq_and_mask_and_the_loop_goes_on`` and
``test_rejected_last_line_does_not_fail_the_boot`` fail with no ``rejected``
line at all.  The other two tests pass before the fix: the movable domain is
pinned with or without the change, and the QDMA policy is untouched.

Run from the repository root:

    python3 -m unittest scripts.tests.test_qdma_irq_affinity
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "QDMA_IRQ_AFFINITY_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/an7581/base-files/etc/init.d/qdma-irq-affinity",
    )
).resolve()

# Absolute shell path: the harness runs the script with a PATH of its own.
SH = shutil.which("sh") or "/bin/sh"

HEADER = "           CPU0       CPU1       CPU2       CPU3\n"

# The board's own rows, trimmed: two banks per QDMA, the two NPU lines and the
# two mt7996e MSI vectors. Counts are from the r20 read and only need to be
# distinguishable, not accurate.
INTERRUPTS = HEADER + (
    " 23:       1000          0          0          0  GICv3 120 Level     airoha_eth.0\n"
    " 24:        500          0          0          0  GICv3 121 Level     airoha_eth.1\n"
    " 25:        400          0          0          0  GICv3 122 Level     airoha_eth.2\n"
    " 26:        300          0          0          0  GICv3 123 Level     airoha_eth.3\n"
    " 27:        200          0          0          0  GICv3 124 Level     airoha_eth.4\n"
    " 28:        100          0          0          0  GICv3 125 Level     airoha_eth.5\n"
    " 29:         90          0          0          0  GICv3 126 Level     airoha_eth.6\n"
    " 30:         80          0          0          0  GICv3 127 Level     airoha_eth.7\n"
    " 40:         50          0          0          0  GICv3  90 Level     mt76-npu\n"
    " 41:         40          0          0          0  GICv3  91 Level     mt76-npu\n"
    " 49:    4380546          0          0          0  MTK3-PCI-MSI-0000:01:00.0"
    "   0 Edge      mt7996e\n"
    " 50:          0          0          0          0  MTK3-PCI-MSI-0000:01:00.0"
    "   0 Edge      mt7996e-hif\n"
)

# The mask the kernel leaves behind: every CPU allowed, the interrupt lands on
# cpu0 anyway.  A file that already holds the mask pin_irq wants is skipped by
# the early return, so start one line there to keep that path covered too.
AFFINITIES = {
    "23": "0000000f",
    "24": "0000000f",
    "25": "0000000f",
    "26": "0000000f",
    "27": "0000000f",
    "28": "0000000f",
    "29": "0000000f",
    "30": "0000000f",
    "40": "0000000f",
    "41": "0000000f",
    "49": "0000000f",
    "50": "0000000f",
}


def mask(root, irq):
    return (root / "proc/irq" / irq / "smp_affinity").read_text().strip()


class QdmaSandboxTestCase(unittest.TestCase):
    def build_sandbox(self, *, rejected=(), msi_vectors=None, affinities=None):
        """Write a fixture /proc and /sys, rewrite the script into it, and run it.

        ``rejected`` lists IRQ numbers whose ``smp_affinity`` must refuse every
        write.  A directory is used as the pseudo-file: opening it for write
        fails with EISDIR for any uid, so the fixture cannot be defeated by a
        root test run, which ``chmod 0444`` would be.

        ``msi_vectors`` maps a PCI function name to the IRQ numbers it owns, as
        ``/sys/bus/pci/devices/<fn>/msi_irqs/<irq>`` would list them.

        Returns (root, log) with the log read back from the mock ``logger``.
        """
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        root = Path(tmpdir.name)
        proc = root / "proc"
        (proc / "irq").mkdir(parents=True)
        (proc / "interrupts").write_text(INTERRUPTS)

        initial = AFFINITIES if affinities is None else affinities
        for irq, value in initial.items():
            target = proc / "irq" / irq
            target.mkdir()
            if irq in rejected:
                (target / "smp_affinity").mkdir()
            else:
                (target / "smp_affinity").write_text(value + "\n")

        cpu = root / "sys/devices/system/cpu"
        cpu.mkdir(parents=True)
        (cpu / "online").write_text("0-3\n")

        for function, vectors in (msi_vectors or {}).items():
            msi = root / "sys/bus/pci/devices" / function / "msi_irqs"
            msi.mkdir(parents=True)
            for irq in vectors:
                (msi / irq).write_text("")

        bindir = root / "bin"
        bindir.mkdir()
        logger = bindir / "logger"
        logger.write_text(
            "#!/bin/sh\n"
            'tag=-; while [ $# -gt 1 ]; do case "$1" in -t) tag=$2; shift 2 ;;'
            ' *) break ;; esac; done\n'
            'printf \'%s: %s\\n\' "$tag" "$*" >> "$QDMA_TEST_LOG"\n'
        )
        logger.chmod(0o755)

        script = root / "init.d" / "qdma-irq-affinity"
        script.parent.mkdir()
        text = SCRIPT.read_text()
        for real, fake in (
            ("/proc/interrupts", proc / "interrupts"),
            ("/proc/irq", proc / "irq"),
            ("/sys/devices/system/cpu/online", cpu / "online"),
            ("/sys/bus/pci/devices", root / "sys/bus/pci/devices"),
        ):
            text = text.replace(real, str(fake))
        script.write_text(text)

        log = root / "qdma.log"
        log.write_text("")
        env = os.environ.copy()
        env["PATH"] = f"{bindir}{os.pathsep}{env.get('PATH', '')}"
        env["QDMA_TEST_LOG"] = str(log)
        proc_run = subprocess.run(
            [SH, "-c", '. "$1"; main', "sh", str(script)],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        if proc_run.returncode != 0:
            raise AssertionError(
                f"qdma-irq-affinity exited {proc_run.returncode}: {proc_run.stderr}"
            )

        return root, log.read_text()


class MsiWithoutAffinity(QdmaSandboxTestCase):
    """N7: the mediatek-gen3 MSI domain cannot be moved; say so, once."""

    def test_rejection_is_named_and_the_mask_is_left_alone(self):
        root, log = self.build_sandbox(
            rejected=("49", "50"), msi_vectors={"0000:01:00.0": ["49", "50"]}
        )

        self.assertEqual(
            log.count("MSI_FLAG_NO_AFFINITY"),
            2,
            "one line per mt7996e vector, both naming the missing MSI affinity:\n" + log,
        )
        for irq in ("49", "50"):
            lines = [line for line in log.splitlines() if f"irq {irq}:" in line]
            self.assertEqual(len(lines), 1, f"irq {irq} must be reported once:\n{log}")
            self.assertIn("MSI_FLAG_NO_AFFINITY", lines[0])
            self.assertNotIn("pinned", lines[0])
        self.assertIn("0000:01:00.0", log)
        # The pseudo-file is untouched: no silent partial write.
        self.assertTrue((root / "proc/irq/49/smp_affinity").is_dir())
        self.assertTrue((root / "proc/irq/50/smp_affinity").is_dir())

    def test_movable_msi_domain_is_still_pinned(self):
        root, log = self.build_sandbox(msi_vectors={"0000:02:00.0": ["49"]})

        self.assertNotIn("MSI_FLAG_NO_AFFINITY", log)
        self.assertIn("irq 49 pinned", log)
        self.assertNotEqual(mask(root, "49"), AFFINITIES["49"])


class NonMsiRejection(QdmaSandboxTestCase):
    """A rejected write outside an MSI domain is a surprise; log it."""

    def test_rejection_carries_irq_and_mask_and_the_loop_goes_on(self):
        root, log = self.build_sandbox(rejected=("40",))

        lines = [line for line in log.splitlines() if "irq 40:" in line]
        self.assertEqual(len(lines), 1, "irq 40 must be reported once:\n" + log)
        self.assertIn("rejected", lines[0])
        self.assertIn("00000004", lines[0])
        self.assertNotIn("pinned", lines[0])
        # 41 comes after 40 in /proc/interrupts; a failed write must not end
        # the walk.
        self.assertIn("irq 41 pinned", log)
        self.assertEqual(mask(root, "41"), "00000008")

    def test_rejected_last_line_does_not_fail_the_boot(self):
        # main() feeds pin_irq from a pipe, so the status of its last line
        # becomes the service status: a refusal there must not turn the boot
        # into "failed". build_sandbox() raises on a non-zero exit. irq 50 is
        # the last row of the fixture, and with no msi_irqs tree it is not
        # recognised as MSI, so the write is really attempted.
        _, log = self.build_sandbox(rejected=("50",))

        self.assertIn("irq 50: smp_affinity write to 00000008 rejected", log)


class QdmaPolicy(QdmaSandboxTestCase):
    """The reason the script exists: bank0 gets a core of its own."""

    def test_bank0_cores_and_round_robin(self):
        root, log = self.build_sandbox()

        # No MSI domain in this fixture, so the two vectors the board cannot
        # move are movable here and the round-robin reaches them too: 8 QDMA
        # banks + 2 NPU lines + 2 vectors.
        self.assertEqual(log.count("pinned to cpu"), 12, log)
        self.assertEqual(mask(root, "23"), "00000001")  # qdma0 bank0
        self.assertEqual(mask(root, "27"), "00000002")  # qdma1 bank0
        self.assertEqual(mask(root, "24"), "00000004")  # qdma0 bank1
        self.assertEqual(mask(root, "25"), "00000008")  # qdma0 bank2
        self.assertEqual(mask(root, "28"), "00000008")  # qdma1 bank1
        self.assertEqual(mask(root, "40"), "00000004")  # mt76-npu
        self.assertEqual(mask(root, "41"), "00000008")  # mt76-npu

    def test_single_digit_kernel_affinity_short_circuits_on_restart(self):
        # On a 4-core AN7581 (NR_CPUS=4), the kernel formats smp_affinity as a
        # single hex digit ("1", "2", "4", "8") rather than zero-padded 8-digit
        # hex ("00000001").  A restart when every IRQ is already pinned must
        # short-circuit cleanly with zero writes and zero log lines.
        already_pinned = {
            "23": "1",
            "24": "4",
            "25": "8",
            "26": "4",
            "27": "2",
            "28": "8",
            "29": "4",
            "30": "8",
            "40": "4",
            "41": "8",
            "49": "4",
            "50": "8",
        }
        root, log = self.build_sandbox(affinities=already_pinned)

        self.assertEqual(
            log,
            "",
            f"already-pinned 1-digit kernel masks were not recognised:\n{log}",
        )
        self.assertEqual(mask(root, "23"), "1")
        self.assertEqual(mask(root, "27"), "2")
        self.assertEqual(mask(root, "40"), "4")
        self.assertEqual(mask(root, "41"), "8")


if __name__ == "__main__":
    unittest.main()
