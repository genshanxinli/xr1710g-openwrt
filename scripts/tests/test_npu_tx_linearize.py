#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline contract test for the NPU TX linearize accounting (issue #96).

Issue #96 asks the driver to stop linearizing every NPU TX skb.  It cannot:
the NPU TX descriptor has a single address and a single length field and no
"last buffer" bit, so a frame spread over fragments can only be handed over
contiguous.  What the stack hands over is already contiguous, because the
driver advertises no NETIF_F_SG/TNETdev features, and net/core/dev.c runs
skb_needs_linearize() before ndo_start_xmit().  The linearize in the NPU
path therefore only ever sees a linear skb, where skb_linearize() returns 0
without copying a byte.

The only thing left to assert statically is the accounting that replaces the
old opt-in npu_tx_sg knob: it must classify the skb shape itself, so the
read-only "npu-tx" debugfs file says whether the driver ever sees a frame
that needs the copy, and it must not change behaviour (a linear skb still
never takes the copy branch, a nonlinear one still does).

Set ``MT76_NPU_TX_PATCH`` to the patch from before this change to reproduce
the red run:

    git show <old>:package/kernel/mt76/patches/0021-... > /tmp/old.patch
    MT76_NPU_TX_PATCH=/tmp/old.patch \\
        python3 -m unittest scripts/tests/test_npu_tx_linearize.py

Run from the repository root:

    python3 -m unittest scripts/tests/test_npu_tx_linearize.py
"""

import os
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PATCH_DIR = REPO / "package/kernel/mt76/patches"
PATCH = Path(os.environ.get(
    "MT76_NPU_TX_PATCH",
    PATCH_DIR / "0021-wifi-mt76-skip-redundant-NPU-TX-linearize.patch"))


def added_lines(path):
    """Return the source lines a patch adds, without the patch markers."""
    return [line[1:] for line in path.read_text().splitlines()
            if line.startswith("+") and not line.startswith("+++")]


def squash(lines):
    return re.sub(r"\s+", " ", " ".join(lines))


def strip_comments(lines):
    """Drop C comments so a comment about NETIF_F_SG is not read as code."""
    out, text = [], "\n".join(lines)
    while text:
        start = text.find("/*")
        if start < 0:
            out.append(text)
            break
        out.append(text[:start])
        end = text.find("*/", start)
        if end < 0:
            break
        text = text[end + 2:]
    return "\n".join(out)


class NpuTxLinearizeTest(unittest.TestCase):
    def setUp(self):
        self.added = added_lines(PATCH)
        self.text = squash(self.added)

    def test_no_opt_in_knob(self):
        # The opt-in knob measured a branch, not a copy: with it set, a linear
        # frame was counted as "passthrough" without proving anything about
        # the frame the driver actually receives.  It is gone.
        self.assertNotIn("npu_tx_sg", self.text)
        self.assertNotIn("module_param(npu_tx_sg", self.text)

    def test_classifies_the_skb_shape(self):
        # A linear skb must not reach skb_linearize(); a nonlinear one still
        # must, or the NPU gets a frame it cannot gather.
        self.assertIn("if (skb_is_nonlinear(skb)) {", self.text)
        inner = self.text.split("if (skb_is_nonlinear(skb)) {", 1)[1]
        inner, tail = inner.split("} else {", 1)
        self.assertIn("skb_linearize(skb)", inner)
        self.assertIn("atomic64_inc(&dev->npu_tx.linearized)", inner)
        self.assertIn("atomic64_inc(&dev->npu_tx.linearize_failed)", inner)
        self.assertIn("atomic64_inc(&dev->npu_tx.passthrough)", tail)

    def test_oversize_keeps_the_13_bit_descriptor_limit(self):
        # FIELD_PREP() truncates a frame above the descriptor length silently;
        # the counter is the only evidence that it happened.
        self.assertIn("#define NPU_TX_MAX_FRAME_LEN 0x1fff", self.text)
        self.assertIn("if (skb->len > NPU_TX_MAX_FRAME_LEN)", self.text)
        self.assertIn("atomic64_inc(&dev->npu_tx.oversize)", self.text)

    def test_call_site_keeps_the_npu_gate(self):
        # Without the NPU the frames go out through the host path and the
        # accounting must not run there.
        #
        # The helper reports why it could not prepare the frame (-ENOMEM from
        # skb_linearize(), -EMSGSIZE above the 13-bit descriptor length), so
        # the gate is a block that keeps the value and aborts the transmit.
        # The one-liner it replaced ("... && mt76_npu_tx_prepare(dev, skb)")
        # only propagated a negative return by accident of C's short-circuit
        # result and said nothing about which failure happened.
        self.assertIn("if (mt76_npu_device_active(dev)) {", self.text)
        gate = self.text.split("if (mt76_npu_device_active(dev)) {", 1)[1]
        self.assertIn("ret = mt76_npu_tx_prepare(dev, skb);", gate.split("}", 1)[0])
        self.assertIn("if (ret)", gate.split("}", 1)[0])
        self.assertIn("goto free_skb;", gate.split("}", 1)[0])
        self.assertNotIn("mt76_npu_device_active(dev) && "
                         "mt76_npu_tx_prepare(dev, skb)", self.text)

    def test_npu_tx_debugfs_reports_the_counters(self):
        for line in ("passthrough: %llu", "linearized: %llu",
                     "linearize_failed: %llu", "oversize: %llu"):
            self.assertIn('seq_printf(s, "%s' % line, self.text)
        self.assertIn('debugfs_create_devm_seqfile(dev->dev, "npu-tx", dir, '
                      'mt76_npu_tx_read)', self.text)

    def test_driver_never_advertises_a_gathering_interface(self):
        # The premise of the whole issue: the driver never tells the stack it
        # can gather, so the stack linearizes before the driver sees the skb.
        # If a patch ever adds NETIF_F_SG (or TSO, which implies it), the
        # linearize question has to be reopened and this test says so.
        for patch in sorted(PATCH_DIR.glob("*.patch")):
            added = squash(strip_comments(added_lines(patch)).splitlines())
            for feature in ("NETIF_F_SG", "NETIF_F_TSO", "NETIF_F_TSO6",
                            "NETIF_F_GSO"):
                self.assertNotIn(feature, added, "%s adds %s"
                                 % (patch.name, feature))


if __name__ == "__main__":
    unittest.main()
