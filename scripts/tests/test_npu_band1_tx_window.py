#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline contract test for the band1 NPU TX buffer window (issue #98).

The MT7996 NPU TX window setup derives three window addresses per band from
the interface IDs ``band, band + 5, band + 10``.  Band0 and band2 get theirs
from ``dev->npu_txd_addr[]``; band1 gets a separate set only when the
``npu_band1_tx`` module parameter is on, because the firmware acceptance of a
third band is not verified.

That means the whole issue can only be checked statically in a fresh tree:
the mt76 sources are a downloaded package, not a file in this repository, and
the target has no 6 GHz station while its 5 GHz radio never transmits (see the
device evidence for #98), so no band1 throughput or NPU-usage measurement is
available.  What *is* checkable here is the compiled source that the package
patch produces:

  * the derivation really addresses MT_BAND1 (interface IDs 1/6/11) and not
    the band0/band2 slots,
  * a failed NPU message keeps the host injection path,
  * the ``npu_band1_tx`` debugfs file prints the band1 window addresses and
    the band0/band2 reference addresses, so "window present" is observable on
    a device that boots with the parameter at its default of 0.

The test parses the patch text and fails if any of those lines disappear.  Set
``MT76_BAND1_PATCH`` to an older patch to reproduce the red run, e.g.:

    git show <pre-debugfs-addresses>:package/kernel/mt76/patches/0016-... \\
        > /tmp/before.patch
    MT76_BAND1_PATCH=/tmp/before.patch \\
        python3 -m unittest scripts/tests/test_npu_band1_tx_window.py

Run from the repository root:

    python3 -m unittest scripts/tests/test_npu_band1_tx_window.py
"""

import os
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PATCH = Path(os.environ.get(
    "MT76_BAND1_PATCH",
    REPO / "package/kernel/mt76/patches"
    / "0016-wifi-mt76-mt7996-give-band1-its-own-NPU-TX-buffer-space.patch"))

BAND0, BAND1, BAND2 = 0, 1, 2


def added_lines():
    """Return the source lines the patch adds, without the patch markers."""
    return [line[1:] for line in PATCH.read_text().splitlines()
            if line.startswith("+") and not line.startswith("+++")]


def compact(lines):
    return re.sub(r"\s+", " ", " ".join(lines))


class Band1WindowTest(unittest.TestCase):
    def setUp(self):
        self.added = added_lines()
        self.text = compact(self.added)

    def test_band1_derivation_uses_its_own_window_slots(self):
        # The derivation must send band1, band1 + 5 and band1 + 10, each with
        # the address of its own band1 slot, not a band0/band2 slot.  Scope
        # the negative check to the derivation; the debugfs body legitimately
        # reads npu_txd_addr[i] for the band0 reference lines.
        start = self.text.index("static void mt7996_npu_txd_band1_init")
        end = self.text.index("if (dev->npu_band1_tx.allocated)")
        derivation = self.text[start:end]
        self.assertIn("MT_BAND1 + 5 * i", derivation)
        self.assertIn("WLAN_FUNC_SET_WAIT_TX_BUF_SPACE_HW_BASE", derivation)
        self.assertIn("dev->npu_band1_tx.addr[i]", derivation)
        self.assertNotIn("dev->npu_txd_addr", derivation)

        # The three interface IDs are exactly the ones band0/band2 never use:
        # band0 is 0/5/10 and band2 is 2/7/12.
        ids = {BAND1 + 5 * i for i in range(3)}
        self.assertEqual(ids, {1, 6, 11})
        self.assertTrue(ids.isdisjoint({BAND0 + 5 * i for i in range(3)}))
        self.assertTrue(ids.isdisjoint({BAND2 + 5 * i for i in range(3)}))

    def test_band1_window_is_opt_in_and_falls_back(self):
        # Default off: the module parameter has no initializer.
        self.assertIn("static bool npu_band1_tx;", self.text)
        self.assertRegex(self.text, r"module_param\(npu_band1_tx, bool, 0644\)")
        # The allocation is gated on the parameter, the mt7996 device and a
        # live NPU; an mt7992 keeps using band1 as its second band already.
        self.assertIn("npu_band1_tx && is_mt7996(&dev->mt76)", self.text)
        self.assertIn("mt76_npu_device_active(&dev->mt76)", self.text)
        # A rejected window must leave the host injection path intact and be
        # reported once, not per frame.
        self.assertIn("dev->npu_band1_tx.present = false;", self.text)
        self.assertIn("band1 NPU TX buffer window rejected", self.text)
        self.assertIn("dev_warn_ratelimited", self.text)

    def test_debugfs_prints_band1_and_the_reference_windows(self):
        # Band1 window addresses: the field the issue asks for.
        self.assertIn(
            'seq_printf(s, "window%d_addr: 0x%llx\\n", i, '
            '(unsigned long long)dev->npu_band1_tx.addr[i]);', self.text)
        # Band0/band2 addresses must be the comparison, taken from the shared
        # npu_txd_addr[] array.  A band1 readout alone could not distinguish
        # "not allocated" from "allocated but not printed".
        self.assertIn(
            'seq_printf(s, "band0_window%d_addr: 0x%llx\\n", i, '
            '(unsigned long long)dev->npu_txd_addr[i]);', self.text)
        self.assertIn(
            'seq_printf(s, "band2_window%d_addr: 0x%llx\\n", i, '
            '(unsigned long long) dev->npu_txd_addr[MT7996_NPU_TXD_SIZE + i]);',
            self.text)
        self.assertIn(
            'debugfs_create_file("npu_band1_tx", 0400, dir, dev, '
            '&mt7996_npu_band1_tx_fops);', self.text)
        # The window size/state must stay visible too.
        self.assertIn('seq_printf(s, "present: %d\\n", dev->npu_band1_tx.present);',
                      self.text)
        self.assertIn('seq_printf(s, "window%d_size: %u\\n", i, '
                      'dev->npu_band1_tx.size[i]);', self.text)

    def test_window_sizes_match_the_band0_band2_layout(self):
        # Two TX rings and one 256 KiB space, same encoding band2 uses:
        # 256 * MT7996_NPU_TX_RING_SIZE for the first two windows and
        # 256 * 1024 for the last one.  Do not invent a new size.
        self.assertIn("i == MT7996_NPU_TXD_SIZE - 1 ? 256 * 1024 : "
                      "256 * MT7996_NPU_TX_RING_SIZE", self.text)
        self.assertIn("dmam_alloc_coherent(dev->mt76.dma_dev, size, "
                      "&dev->npu_band1_tx.addr[i], GFP_KERNEL)", self.text)


if __name__ == "__main__":
    unittest.main()
