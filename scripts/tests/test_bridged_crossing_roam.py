#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regression guard for issue #334: a 5 GHz <-> 6 GHz roam is not a crossing.

675-05 records the first bridge ingress port of each conntrack direction and
675-06 tears the flow down once a second ingress port shows up in the same
direction.  A station roaming between two access points of the same bridge
changes exactly that: the ingress port changes, the direction does not, and
the station never crossed a second bridge.  The flow is torn down and the
conntrack is barred from offload for the rest of its life.

The fix records the egress port (nf_bridge_get_physoutif()) of each direction
as well and only treats a new ingress port as a second crossing when it is
the peer direction's egress port.

This test replays the two shapes on the running kernel with
scripts/tests/bridged-crossing-roam.sh (bridge + netns, no patched kernel
needed: iptables `physdev` reads the same nf_bridge fields the patches
record), feeds the observed port pairs through both discriminators, and
checks the patches themselves.  Set BRXING_PATCH_DIRS (colon separated) to
run the patch check against a copy; that is the red proof.
"""

import os
import re
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "tests" / "bridged-crossing-roam.sh"
PATCH_DIRS = [
    Path(p)
    for p in os.environ.get(
        "BRXING_PATCH_DIRS",
        ":".join(
            str(REPO_ROOT / "target" / "linux" / "generic" / f"pending-{ver}")
            for ver in ("7.4", "7.3", "6.18")
        ),
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


def guard_uses_peer_egress(directory):
    """True when the delivered discriminator gates multi on the peer egress."""
    return "outif[peer]" in patch_of(directory).read_text()


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
    if not _TRACE:
        _TRACE.extend(trace())
    return [
        (direction, iif, oif)
        for name, direction, iif, oif, _ in _TRACE
        if name == scenario
    ]


def replay(events, peer_egress):
    """One pass of nft_flow_offload_bridge_record over the observed pairs.

    Repeated packets on the same pair are no-ops in the kernel (cmpxchg keeps
    the first port, `old == iif` returns), so one entry per pair is enough.
    peer_egress=False is the old discriminator, kept so the false positive
    stays documented by a test rather than by a report.
    """
    iif, outif, multi = {}, {}, False
    for direction, in_port, out_port in events:
        peer = "rev" if direction == "orig" else "orig"
        if direction not in iif:
            iif[direction], outif[direction] = in_port, out_port
            continue
        if in_port == iif[direction]:
            continue
        if peer_egress and in_port != outif.get(peer, 0):
            continue
        multi = True
    return multi


class BridgedCrossingRoam(unittest.TestCase):
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
            replay(roam, peer_egress=False),
            "the old discriminator no longer flags the roam; the shape of the "
            "bug changed, re-read the trace",
        )
        self.assertFalse(
            replay(roam, peer_egress=guard_uses_peer_egress(PATCH_DIRS[0])),
            "a roam between two ports of one bridge must not be torn down: "
            "the delivered guard has to compare the new ingress port with the "
            "peer direction's egress port",
        )

    def test_routed_connection_is_still_flagged(self):
        self.assertTrue(
            replay(pairs("double"), peer_egress=guard_uses_peer_egress(PATCH_DIRS[0])),
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


if __name__ == "__main__":
    unittest.main()
