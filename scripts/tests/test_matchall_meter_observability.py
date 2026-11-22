#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guards for the matchall police meter landing (issue #369).

tc matchall police never allocates a ppe->meter[] group: it arms the QDMA RX
TRTCM of the whole block instead (airoha_qdma_set_rx_meter()).  The fix that
makes that path observable is a patch, not code in this tree, so these
assertions read the patch post-image -- context and '+' lines -- and check
the three things the patch is supposed to keep true:

  * the reason matchall takes no group is written down next to the
    function, so an empty ppe/meter dump is not read as a missing
    allocation;
  * the request is recorded in software in both REPLACE and DESTROY, i.e.
    a rule delete clears it back to 0;
  * qdma/rx_meter is read-only, prints the arming it can read back
    (TRTCM_MISC_MODE) and does not print a token rate the driver never
    reads back.

Set MATCHALL_METER_PATCH to a copy of the 7.4 patch to run the red proof
against a damaged copy (the copies put the fabricated readback back, drop
the comment, or drop the software record).

Limit: the TRTCM_* bit values live in the base airoha_eth.h, which is not in
this tree, so the decode below assumes the enum stays TICK_SEL=BIT(0),
PKT_MODE=BIT(1), METER_MODE=BIT(2); the assertion that matters here is the
field-to-mask mapping in the patch, not those numbers.
"""

import os
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PATCHES = {
    ver: Path(
        os.environ.get("MATCHALL_METER_PATCH")
        if ver == "7.4" and os.environ.get("MATCHALL_METER_PATCH")
        else REPO_ROOT
        / f"target/linux/airoha/patches-{ver}"
        / "99993-net-airoha-make-the-matchall-police-meter-observable.patch"
    )
    for ver in ("7.4", "7.3")
}
NODE = 'debugfs_create_file("rx_meter", 0444, eth->qdma_debugfs_dir, eth,'
COMMENT = "deliberately takes no ppe->meter[]"
RECORD = ("qdma->rx_meter_rate = rate;",
          "qdma->rx_meter_burst = bucket_size;",
          "qdma->rx_meter_unit = unit_type;")
SHOW_BEGIN = "static int airoha_qdma_debugfs_rx_meter_show("
SHOW_END = "DEFINE_SHOW_ATTRIBUTE(airoha_qdma_debugfs_rx_meter);"
FIELDS = (("meter_en", "TRTCM_METER_MODE"),
          ("pps", "TRTCM_PKT_MODE"),
          ("tick_sel", "TRTCM_TICK_SEL"))
RATE_LINE = re.compile(r'qdma %d requested rate %u (\w+) burst %u unit %s\\n')
RATE_UNIT = "kbps"
TRUNCATION = ("div_u64(rate_bytes_ps, 1000)", "8 kbit/s", "rate_pkt_ps")


def post_image(text):
    lines = []
    for line in text.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            lines.append(line[1:])
        elif line.startswith(" "):
            lines.append(line[1:])
    return "\n".join(lines)


def show_body(post):
    """The rx_meter show function, from its signature to its fops."""
    start = post.index(SHOW_BEGIN)
    end = post.index(SHOW_END, start)
    return post[start:end]


def ring_format(body):
    """The per-ring seq_printf format and the masks it is fed, in order."""
    match = re.search(r'qdma %d ring %2d mode %08x([^"]*?)\\n', body)
    if not match:
        raise AssertionError("per-ring seq_printf format not found")
    fields = re.findall(r"(\w+) %u", match.group(1))
    masks = re.findall(r"!!\(mode & (TRTCM_\w+)\)", body)
    return match.group(0), fields, masks


class MatchallMeterObservability(unittest.TestCase):
    def each_patch(self):
        for ver, path in PATCHES.items():
            yield ver, post_image(path.read_text())

    def test_node_is_read_only_qdma_file(self):
        for ver, post in self.each_patch():
            self.assertEqual(
                post.count(NODE), 1,
                f"{ver}: qdma/rx_meter must be created exactly once, 0444, "
                "on the qdma debugfs dir",
            )
            self.assertNotIn(
                'debugfs_create_file("rx_meter", 0644', post,
                f"{ver}: rx_meter is a read-only dump, not a knob",
            )

    def test_matchall_takes_no_ppe_group(self):
        for ver, post in self.each_patch():
            self.assertIn(
                COMMENT, post,
                f"{ver}: the comment above airoha_qdma_set_rx_meter() must "
                "say matchall deliberately takes no ppe->meter[] group; "
                "without it ppe/meter reads as a missing allocation",
            )
            self.assertIn("AIROHA_PPE_METER_NUM (63)", post,
                          f"{ver}: the comment must name the 63-group limit "
                          "that makes a group a per-flow resource")
            self.assertNotIn(
                "airoha_ppe_meter_alloc", post,
                f"{ver}: the matchall path must not allocate a PPE group",
            )

    def test_request_is_recorded(self):
        for ver, post in self.each_patch():
            for line in RECORD:
                self.assertIn(
                    line, post,
                    f"{ver}: airoha_qdma_set_rx_meter() must record the "
                    "request even when rate is 0 (that is the delete path), "
                    f"missing {line!r}",
                )
            self.assertIn("qdma->rx_meter_rate, qdma->rx_meter_burst,", post,
                          f"{ver}: the dump must print the recorded request")

    def test_no_fabricated_rate_readback(self):
        for ver, post in self.each_patch():
            body = show_body(post)
            self.assertNotIn(
                "TRTCM_TOKEN_RATE_MODE", body,
                f"{ver}: nothing reads the token rate back; printing it "
                "would dress the software record up as a register value",
            )
            self.assertNotIn(
                "TRTCM_BUCKETSIZE_SHIFT_MODE", body,
                f"{ver}: same for the bucket shift",
            )
            self.assertIn(
                "TRTCM_MISC_MODE", body,
                f"{ver}: the arming must be read back through "
                "TRTCM_MISC_MODE, the parameter the driver already reads",
            )
            self.assertIn(
                "mode unreadable", body,
                f"{ver}: a failed readback must be reported, not printed "
                "as a zero",
            )

    def test_requested_rate_unit_is_kbps(self):
        """The recorded rate is Kbps, not bps; the label must say so.

        A device run showed "requested rate 1248 bps" for tc's
        "rate 1250000bit": airoha_eth.c divides rate_bytes_ps by 1000 and
        shifts left 3 before calling airoha_qdma_set_rx_meter(), so the
        number is Kbps.  The packet-unit branch passes rate_pkt_ps
        unchanged, so a bare "bps" is wrong there too.
        """
        for ver, post in self.each_patch():
            body = show_body(post)
            match = RATE_LINE.search(body)
            self.assertIsNotNone(
                match,
                f"{ver}: the request line must print rate, burst and unit as "
                "'qdma %d requested rate %u <unit> burst %u unit %s\\n'",
            )
            self.assertEqual(
                match.group(1), RATE_UNIT,
                f"{ver}: the recorded rate is Kbps, so the label must be "
                "'kbps'; 'bps' reads as 1/1000 of the real value",
            )
            self.assertNotIn(
                "requested rate %u bps", body,
                f"{ver}: a bare 'bps' label must not survive anywhere",
            )
            for text in TRUNCATION:
                self.assertIn(
                    text, body,
                    f"{ver}: the comment beside the line must say the byte "
                    f"branch truncates at {text!r} and that packet units "
                    "are pps, so the number is what the driver received",
                )

    def test_field_order_matches_masks(self):
        for ver, post in self.each_patch():
            fmt, fields, masks = ring_format(show_body(post))
            self.assertEqual(
                tuple(fields), tuple(name for name, _ in FIELDS),
                f"{ver}: {fmt!r} must label the three decoded bits "
                "meter_en/pps/tick_sel in that order",
            )
            self.assertEqual(
                tuple(masks), tuple(mask for _, mask in FIELDS),
                f"{ver}: {fmt!r} must feed TRTCM_METER_MODE, TRTCM_PKT_MODE "
                "and TRTCM_TICK_SEL in the order the format prints them",
            )

    def test_ring_line_with_fake_data(self):
        """Render the patch's own format with made-up mode words."""
        bits = {"TRTCM_METER_MODE": 1 << 2,
                "TRTCM_PKT_MODE": 1 << 1,
                "TRTCM_TICK_SEL": 1 << 0}
        for ver, post in self.each_patch():
            fmt, fields, masks = ring_format(show_body(post))
            # Python's % takes %u for %d and the literal text as-is.
            for mode, expected in (
                (0x5, "meter_en 1 pps 0 tick_sel 1"),
                (0x2, "meter_en 0 pps 1 tick_sel 0"),
                (0x0, "meter_en 0 pps 0 tick_sel 0"),
            ):
                values = [1 if mode & bits[mask] else 0 for mask in masks]
                # the patch's format carries a literal C "\\n": unescape it
                rendered = (fmt.replace("\\n", "\n")
                            % ((0, 3, mode) + tuple(values))).rstrip("\n")
                self.assertEqual(
                    rendered,
                    f"qdma 0 ring  3 mode {mode:08x} {expected}",
                    f"{ver}: ring {3} mode {mode:#04x} renders wrong",
                )


if __name__ == "__main__":
    unittest.main()
