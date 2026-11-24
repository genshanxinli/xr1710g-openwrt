#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""`04_set_netdev_label` must survive a name swap between two interfaces.

The preinit script renames interfaces to the label in their device tree node
(`openwrt,netdev-name`).  A single pass that renames ``eth0 -> eth1`` while
``eth1`` still exists is refused by the kernel with -EEXIST, and the script
never checked the result, so the swap silently did not happen and every
`lan`/`wan`/... assignment above it pointed at the wrong port.

Upstream `de3a3f7132` renames in two phases: park every mislabelled interface
under a kernel-assigned ``tmp%d`` name, then give each parked interface its
final name.  After phase 1 none of the affected names is held any more, so
phase 2 cannot collide.

What this test does, without touching a real interface:

  * the script under test is copied and ``/sys/class/net`` is rewritten to a
    temporary directory holding one directory per interface;
  * ``ip`` is a shell stub that renames that directory, refuses a target name
    that already exists (``RTNETLINK answers: File exists``) and expands
    ``%d`` to the lowest free ``tmpN``, like iproute2 does.

Red half: ``RED_SINGLE_PASS`` is the pre-port implementation, kept verbatim in
this file.  ``test_red_...`` runs it and asserts the swap fails; the fixed
script in the tree makes ``test_green_...`` pass.  Point
``SET_NETDEV_LABEL_UNDER_TEST`` at a copy of the old script to watch the green
half fail instead.

Run from the repository root:

    python3 scripts/tests/test_netdev_label_swap.py \\
        && scripts/check-test-cleanup-safety.py scripts/tests/test_netdev_label_swap.py
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
        "SET_NETDEV_LABEL_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/base-files/lib/preinit/04_set_netdev_label",
    )
).resolve()
SH = shutil.which("sh") or "/bin/sh"

# Verbatim pre-de3a3f7132 implementation: one rename per interface, no parking.
RED_SINGLE_PASS = """\
set_netdev_labels() {
\tlocal dir
\tlocal label
\tlocal netdev

\tfor dir in /sys/class/net/*; do
\t\t[ -r "$dir/of_node/openwrt,netdev-name" ] || continue
\t\tread -r label < "$dir/of_node/openwrt,netdev-name"
\t\tnetdev="${dir##*/}"
\t\t[ "$netdev" = "$label" ] && continue
\t\tip link set "$netdev" name "$label"
\tdone
}
"""

# The kernel side: a rename directory = a rename; an occupied target name is
# -EEXIST.  `%d` picks the lowest free tmpN, as iproute2's name expansion does.
IP_STUB = """\
#!/bin/sh
[ "${1:-}" = link ] && [ "${2:-}" = set ] && [ "${4:-}" = name ] || {
\techo "ip: unsupported: $*" >&2
\texit 2
}
dev=$3
new=$5
case "$new" in
*%d*)
\tn=0
\twhile [ -e "$NET_ROOT/tmp$n" ]; do n=$((n + 1)); done
\tnew="tmp$n"
\t;;
esac
echo "$dev->$new" >>"$IP_LOG"
if [ -e "$NET_ROOT/$new" ]; then
\techo "RTNETLINK answers: File exists" >&2
\texit 1
fi
[ -d "$NET_ROOT/$dev" ] || {
\techo "ip: no such device $dev" >&2
\texit 1
}
mv "$NET_ROOT/$dev" "$NET_ROOT/$new"
"""

BOOT_HOOK_STUB = "boot_hook_add() { :; }"


class LabelSandbox:
    """A temporary /sys/class/net plus an `ip` stub that enforces -EEXIST."""

    def __init__(self, create_work):
        self.work = create_work()

    def net(self, labels):
        """labels: {interface name: label}; a value of None means no of_node."""
        net = os.path.join(self.work, "net")
        os.mkdir(net)
        for name, label in labels.items():
            os.mkdir(os.path.join(net, name))
            if label is None:
                continue
            node = os.path.join(net, name, "of_node")
            os.mkdir(node)
            with open(os.path.join(node, "openwrt,netdev-name"), "w") as fh:
                fh.write(label + "\n")
        return net

    def run(self, script_text, net):
        bindir = os.path.join(self.work, "bin")
        os.mkdir(bindir)
        stub = os.path.join(bindir, "ip")
        with open(stub, "w") as fh:
            fh.write(IP_STUB)
        os.chmod(stub, 0o755)

        log = os.path.join(self.work, "ip.log")
        copy = os.path.join(self.work, "04_set_netdev_label")
        with open(copy, "w") as fh:
            fh.write(script_text.replace("/sys/class/net", net))

        env = dict(
            os.environ,
            PATH=bindir + os.pathsep + os.environ.get("PATH", ""),
            NET_ROOT=net,
            IP_LOG=log,
        )
        proc = subprocess.run(
            [
                SH,
                "-c",
                BOOT_HOOK_STUB + '; . "$0"; set_netdev_labels',
                copy,
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        calls = Path(log).read_text().splitlines() if os.path.exists(log) else []
        return proc, calls

    @staticmethod
    def label_of(net, name):
        node = os.path.join(net, name, "of_node", "openwrt,netdev-name")
        return Path(node).read_text().strip() if os.path.exists(node) else None

    @staticmethod
    def names(net):
        return sorted(
            entry
            for entry in os.listdir(net)
            if os.path.isdir(os.path.join(net, entry))
        )


class NetdevLabelSwap(unittest.TestCase):
    def make_sandbox(self):
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work)
        return LabelSandbox(lambda: work)

    def assert_eexist(self, proc):
        self.assertIn("RTNETLINK answers: File exists", proc.stderr)

    def test_red_single_pass_cannot_swap(self):
        """Red: the pre-port script leaves eth0 <-> eth1 exactly as it found it."""
        sandbox = self.make_sandbox()
        net = sandbox.net({"eth0": "eth1", "eth1": "eth0"})
        proc, calls = sandbox.run(RED_SINGLE_PASS, net)

        # Both renames were refused: each asks for a name the other still holds.
        self.assert_eexist(proc)
        self.assertEqual(proc.stderr.count("RTNETLINK answers: File exists"), 2)
        self.assertEqual(len(calls), 2)
        self.assertEqual(sandbox.label_of(net, "eth0"), "eth1")
        self.assertEqual(sandbox.label_of(net, "eth1"), "eth0")

    def test_green_two_phase_swaps(self):
        """Green: park both, then rename; every interface ends on its label."""
        sandbox = self.make_sandbox()
        net = sandbox.net({"eth0": "eth1", "eth1": "eth0"})
        proc, calls = sandbox.run(SCRIPT.read_text(), net)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("RTNETLINK answers: File exists", proc.stderr)
        self.assertEqual(
            calls,
            ["eth0->tmp0", "eth1->tmp1", "tmp0->eth1", "tmp1->eth0"],
        )
        self.assertEqual(sandbox.names(net), ["eth0", "eth1"])
        for name in ("eth0", "eth1"):
            self.assertEqual(sandbox.label_of(net, name), name)

    def test_green_no_rename_when_names_are_right(self):
        """Already-correct names stay silent and untouched."""
        sandbox = self.make_sandbox()
        net = sandbox.net({"eth0": "eth0", "eth1": "eth1"})
        proc, calls = sandbox.run(SCRIPT.read_text(), net)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, [])

    def test_green_empty_label_is_skipped(self):
        """An empty label is nobody's name, so no rename is attempted for it."""
        sandbox = self.make_sandbox()
        net = sandbox.net({"eth0": "", "eth1": None})
        proc, calls = sandbox.run(SCRIPT.read_text(), net)

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, [])

    def test_red_empty_label_attempts_rename(self):
        """Red: the old script read the empty label and asked for a nameless link."""
        sandbox = self.make_sandbox()
        net = sandbox.net({"eth0": ""})
        proc, calls = sandbox.run(RED_SINGLE_PASS, net)

        self.assertIn("eth0->", "\n".join(calls))


if __name__ == "__main__":
    unittest.main()
