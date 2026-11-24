#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regression guard for issue #334: a 5 GHz <-> 6 GHz roam is not a crossing.

675-05 records the first bridge ingress port of each conntrack direction and
675-06 tears the flow down once a second ingress port shows up in the same
direction.  A station roaming between two access points of the same bridge
changes exactly that: the ingress port changes, the direction does not, and
the station never crossed a second bridge.  The flow is torn down and the
conntrack is barred from offload for the rest of its life.

The fix records the egress port (nf_bridge_get_physoutif()) and the sighting
order of each direction as well and only treats a new ingress port as a
second crossing when it is the peer direction's egress port, sighted before
the direction that shows up on it.

This test replays the two shapes on the running kernel with
scripts/tests/bridged-crossing-roam.sh (bridge + netns, no patched kernel
needed: iptables `physdev` reads the same nf_bridge fields the patches
record), feeds the observed port pairs through both discriminators, and
checks the patches themselves.  Set BRXING_PATCH_DIRS (colon separated) to
run the patch check against a copy; that is the red proof.
"""

import os
import shutil
import re
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "tests" / "bridged-crossing-roam.sh"
# Only the live 7.4 queue carries this patch.  The 7.3 and 6.18 copies are
# not built by this tree (KERNEL_TESTING_PATCHVER is 7.4) and were left
# untouched, so checking them here would assert on files nobody ships.
PATCH_DIRS = [
    Path(p)
    for p in os.environ.get(
        "BRXING_PATCH_DIRS",
        str(REPO_ROOT / "target" / "linux" / "generic" / "pending-7.4"),
    ).split(":")
]

PATCH_NAME = (
    "675-05-netfilter-nft_flow_offload-bridged-connections-crossing-twice.patch"
)

EVENT = re.compile(r"^EVENT (\w+) (orig|rev) ([^:\s]+):([^:\s]+) (\d+)$")


def patch_of(directory):
    patch = directory / PATCH_NAME
    if not patch.exists():
        patch = sorted(directory.glob("675-05-*.patch"))[0]
    return patch


def delivered_rule(directory):
    """Which discriminator the patch carries: oldest, peer egress, or ordered."""
    text = patch_of(directory).read_text()
    if "outif[peer]" not in text:
        return "ingress"
    if "order[peer]" in text:
        return "ordered"
    return "peer_egress"


def _missing_dependency():
    """Name the tool the kernel replay needs, or None when it can run."""
    if not SCRIPT.exists():
        return f"{SCRIPT} is missing"
    for tool in ("ip", "unshare", "iptables-legacy"):
        if shutil.which(tool) is None:
            return tool
    probe = subprocess.run(["unshare", "-Urnm", "true"], capture_output=True)
    if probe.returncode != 0:
        return "unshare -Urnm (user namespaces are not permitted here)"
    return None


def trace():
    """(scenario, dir, ingress, egress) for every port pair that saw traffic."""
    out = subprocess.run(
        ["sh", str(SCRIPT)], capture_output=True, text=True, timeout=600
    )
    events = []
    for line in out.stdout.splitlines():
        match = EVENT.match(line.strip())
        if match:
            scenario, direction, iif, oif, packets = match.groups()
            events.append((scenario, direction, iif, oif, int(packets)))
    if not events:
        raise AssertionError(
            "bridged-crossing-roam.sh printed no EVENT lines\n"
            "stdout:\n%s\nstderr:\n%s" % (out.stdout, out.stderr)
        )
    return events


_TRACE = []


def pairs(scenario):
    missing = _missing_dependency()
    if missing is not None:
        raise unittest.SkipTest(f"cannot replay the kernel here: {missing}")
    if not _TRACE:
        _TRACE.extend(trace())
    return [
        (direction, iif, oif)
        for name, direction, iif, oif, _ in _TRACE
        if name == scenario
    ]


# A station roams before its first reply left the bridge: the reply then
# leaves through the port it roamed to, so that port is recorded after the
# direction it is later compared with.  The peer-egress discriminator marks
# this connection anyway, which is the false positive of #334.
ROAM_BEFORE_REPLY = [("orig", "a1", "b1"), ("rev", "b1", "a2"), ("orig", "a2", "b1")]


def replay(events, rule):
    """One pass of nft_flow_offload_bridge_record over the observed pairs.

    Repeated packets on the same pair are no-ops in the kernel (cmpxchg keeps
    the first port, `old == iif` returns), so one entry per pair is enough.
    rule is the discriminator the patch carries:

    ingress      only the ingress port is compared (the oldest variant),
    peer_egress  the new ingress port has to be the peer's egress port,
    ordered      and the peer direction has to be the one sighted first.

    The older variants stay here so the false positives of #334 remain
    documented by a test rather than by a report.
    """
    iif, outif, order, multi = {}, {}, {}, False
    for direction, in_port, out_port in events:
        peer = "rev" if direction == "orig" else "orig"
        if direction not in iif:
            iif[direction], outif[direction] = in_port, out_port
            if rule == "ordered":
                order[direction] = 1 + (1 if peer in order else 0)
            continue
        if in_port == iif[direction] or multi:
            continue
        if rule != "ingress" and in_port != outif.get(peer, 0):
            continue
        if rule == "ordered" and order.get(peer, 0) >= order.get(direction, 0):
            continue
        multi = True
    return multi


class BridgedCrossingRoam(unittest.TestCase):
    def delivered(self):
        return delivered_rule(PATCH_DIRS[0])

    def test_roam_moves_the_ingress_port(self):
        """Precondition: the station's frames arrive on a new bridge port."""
        roam = pairs("roam")
        self.assertIn(("orig", "a1", "b1"), roam)
        self.assertIn(("rev", "b1", "a1"), roam)
        self.assertIn(("orig", "a2", "b1"), roam)
        self.assertIn(("rev", "b1", "a2"), roam)

    def test_routed_connection_crosses_twice(self):
        """Precondition: one connection can really cross the bridge twice."""
        double = pairs("double")
        self.assertIn(("orig", "a1", "r1"), double)
        self.assertIn(("orig", "s1", "b1"), double)
        self.assertIn(("rev", "b1", "s1"), double)
        self.assertIn(("rev", "r1", "a1"), double)

    def test_roam_is_not_a_second_crossing(self):
        roam = pairs("roam")
        self.assertTrue(
            replay(roam, "ingress"),
            "the oldest discriminator no longer flags the roam; the shape of "
            "the bug changed, re-read the trace",
        )
        self.assertFalse(
            replay(roam, self.delivered()),
            "a roam between two ports of one bridge must not be torn down: "
            "the delivered guard has to compare the new ingress port with the "
            "peer direction's egress port",
        )

    def test_roam_before_the_first_reply_is_not_a_second_crossing(self):
        """Red: peer egress alone marks a roam whose reply followed it."""
        self.assertTrue(
            replay(ROAM_BEFORE_REPLY, "peer_egress"),
            "the peer-egress discriminator no longer marks the roam before "
            "the first reply; if that is now true the second shape of #334 "
            "changed and the review needs re-reading",
        )
        self.assertFalse(
            replay(ROAM_BEFORE_REPLY, "ordered"),
            "a port the peer direction recorded after this direction was "
            "first sighted cannot be where this direction came in",
        )

    def test_routed_connection_is_still_flagged(self):
        self.assertTrue(
            replay(pairs("double"), self.delivered()),
            "a connection that really crosses twice must still be refused "
            "offload",
        )

    def test_patches_gate_multi_on_the_peer_egress_port(self):
        for directory in PATCH_DIRS:
            patch = patch_of(directory)
            text = re.sub(r"\s+", " ", patch.read_text())
            self.assertIn("int outif[IP_CT_DIR_MAX];", text, patch)
            gate = "if (iif != READ_ONCE(rec->outif[peer]))"
            self.assertIn(gate, text, f"{patch}: multi must wait for the peer egress")
            self.assertLess(
                text.index(gate),
                text.index("WRITE_ONCE(rec->multi"),
                f"{patch}: the comparison has to come before multi is set",
            )

    def test_patches_stamp_the_sighting_order(self):
        for directory in PATCH_DIRS:
            patch = patch_of(directory)
            text = re.sub(r"\s+", " ", patch.read_text())
            self.assertIn("u8 order[IP_CT_DIR_MAX];", text, patch)
            stamp = "WRITE_ONCE(rec->order[dir], 1 + !!READ_ONCE(rec->order[peer]))"
            order_gate = (
                "if (READ_ONCE(rec->order[peer]) >= READ_ONCE(rec->order[dir]))"
            )
            self.assertIn(stamp, text, f"{patch}: the order byte has to be stamped")
            self.assertIn(order_gate, text, f"{patch}: the order gate is missing")
            self.assertLess(
                text.index(stamp),
                text.index(order_gate),
                f"{patch}: a direction has to be stamped before it is compared",
            )
            self.assertLess(
                text.index(order_gate),
                text.index("WRITE_ONCE(rec->multi"),
                f"{patch}: the order gate has to come before multi is set",
            )


if __name__ == "__main__":
    unittest.main()
